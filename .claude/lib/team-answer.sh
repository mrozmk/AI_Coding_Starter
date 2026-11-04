#!/usr/bin/env bash
# Answer a team role from the supervisor: approve or reject its open permission prompt, or type a reply.
#
# Usage: bash .claude/lib/team-answer.sh <team> <role> <action> [<text>|<n>|<n,n>|none] [<option> <v>]…
# Actions: yes|no|say|pick|other|picks|finish
#   e.g. bash .claude/lib/team-answer.sh alfa coder yes
#        bash .claude/lib/team-answer.sh alfa coder say "Use the existing endpoint, no new route."
#        bash .claude/lib/team-answer.sh alfa planner pick 2
#        bash .claude/lib/team-answer.sh alfa planner other "Use the counter."
# picks answers one checkbox question; none sends explicit "none - skip all", not an empty answer.
# finish <text> --send say|other — ledger-driven, see team-question.sh finish.
# Options (team-question.sh passes them): --clone --root --q --attempt --journal --tier --send
#   (--tier 1 adds --classes to the yes policy check: a class prints policy-class: <name>)
#   --expect-fp --expect-pane --expect-event --expect-session --expect-run --expect-attempt
#   --expect-record --expect-anchor.
# Exit: 0 sent · 2 usage · 3 not sent, stale · 4 partial (keys sent, then a failure) · 5 not sent,
#   unreadable · 6 not sent, changed · 7 not sent, policy · 8 not sent, mode (team-mode.md §10).
set -euo pipefail

usage() { sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
[ $# -ge 3 ] || usage
TEAM="$1"; ROLE="$2"; action="$3"; shift 3; text=""; have_text=""
if [ $(( $# % 2 )) = 1 ]; then text="$1"; have_text=1; shift; fi
CLONE=""; ROOT=""; QID=""; ATTEMPT=""; JOURNAL=""; TIER=""; SEND=""
E_FP=""; E_PANE=""; E_EVENT=""; E_SESSION=""; E_RUN=""; E_ATTEMPT=""; E_RECORD=""; E_ANCHOR=""
while [ $# -gt 0 ]; do
  case "$1" in
    --clone) CLONE="$2" ;; --root) ROOT="$2" ;; --q) QID="$2" ;; --attempt) ATTEMPT="$2" ;;
    --journal) JOURNAL="$2" ;; --tier) TIER="$2" ;; --send) SEND="$2" ;;
    --expect-fp) E_FP="$2" ;; --expect-pane) E_PANE="$2" ;; --expect-event) E_EVENT="$2" ;;
    --expect-session) E_SESSION="$2" ;; --expect-run) E_RUN="$2" ;;
    --expect-attempt) E_ATTEMPT="$2" ;; --expect-record) E_RECORD="$2" ;;
    --expect-anchor) E_ANCHOR="$2" ;;
    *) usage ;;
  esac
  shift 2
done
case "$action" in pick|other|picks|finish) [ -n "$have_text" ] || usage ;; esac
case "$action" in
  yes|no) ;;
  say|other) [ -n "$text" ] || { echo "error: $action needs the text to type" >&2; exit 2; } ;;
  finish) [ -n "$text" ] && [ -n "$QID" ] && { [ "$SEND" = say ] || [ "$SEND" = other ]; } \
            || { echo "error: finish needs the text, --q and --send say|other" >&2; exit 2; } ;;
  pick) [[ "$text" =~ ^[1-9][0-9]?$ ]] || { echo "error: pick needs an option number 1-99" >&2; exit 2; } ;;
  picks) [[ "$text" = none || "$text" =~ ^[1-9][0-9]?(,[1-9][0-9]?)*$ ]] \
           || { echo "error: picks needs option numbers separated by commas, or none" >&2; exit 2; } ;;
  *) echo "error: action must be yes, no, say, pick, other, picks or finish" >&2; exit 2 ;;
esac
LIB="$(cd "$(dirname "$0")" && pwd)"
. "$LIB/team-lib.sh"
. "$LIB/team-send-lock.sh"
name="$TEAM-$ROLE"
[[ "$name" =~ ^[a-z0-9-]+$ ]] || { echo "error: bad session name $name" >&2; exit 2; }
[ -n "$ROOT" ] || ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
# team-question.sh always passes --clone: it runs inside the clone, where this derivation breaks.
[ -n "$CLONE" ] || CLONE="$(team_clone_dir "$TEAM" "$ROOT")"
TD="$CLONE/.agents/team"
# A role session of the supervision layer has no clone: lock in this checkout.
[ -d "$TD" ] || { TD="$ROOT/.agents/team"; mkdir -p "$TD"; }
KEYS=0; DRAFT0=""

refuse() { local rc="$1"; shift; echo "error: $* — nothing sent" >&2; exit "$rc"; }
stop() {  # stop <rc if nothing was sent> <reason> — a failure after a key is always partial (4)
  local rc="$1"; shift
  [ "$KEYS" = 0 ] || { echo "error: $* — $KEYS keys sent" >&2; exit 4; }
  refuse "$rc" "$@"
}
multi_error() { stop 5 "$* — answer in the window (tier 3)"; }
sj() { jq -r --arg f "$1" '.[$f] // empty | tostring' "$TD/session.json" 2>/dev/null || true; }
real_event() { case "$1" in ""|-|ambiguous) return 1 ;; esac; }
# With -e: a dim prompt suggestion on the input line is not a draft (team_prompt.py).
capture() { tmux capture-pane -p -e -J -S -200 -t "$PANE_ID" 2>/dev/null || true; }
parse() { printf '%s\n' "$1" | python3 -I "$LIB/team_prompt.py" parse --transcript "${T:--}"; }
plain() { python3 -I "$LIB/team_prompt.py" strip; }
is_typed() { [ "$(printf '%s\n' "$2" | python3 -I "$LIB/team_prompt.py" typed "$1")" = yes ]; }
fields() {  # fields <parse json> → KIND COMPLETE REASON FP CURSOR OTHER BUSY EMPTY OPT1 INPUT
  IFS=$'\x1f' read -r KIND COMPLETE REASON FP CURSOR OTHER BUSY EMPTY OPT1 INPUT \
    <<<"$(jq -r '[.kind, .complete, .reason, .fp, (.cursor // "-"), (.other // "-"), .busy,
    (.input_empty // "-"), (.options[0].label // ""), (.input // "")] | map(tostring)
    | join("\u001f")' <<<"$1")"
}
draft_why() {  # draft_why <input> → why a human draft is not recoverable, or nothing
  case "$1" in
    *"[Pasted text #"*) echo "paste chip" ;;
    *"[Image #"*) echo "image chip" ;;
  esac
}
newest_record() { team_newest_record "$TD" "$(cat "$TD/run" 2>/dev/null)" "$ROLE" "$(sj attempt)"; }
identity() {
  local s; s="$(sj session_id)"
  [ -z "$E_SESSION" ] || [ "$E_SESSION" = "${s:--}" ] || refuse 6 "session changed"
  [ -z "$E_RUN" ] || [ "$E_RUN" = "$(cat "$TD/run" 2>/dev/null)" ] || refuse 6 "run changed"
  [ -z "$E_ATTEMPT" ] || { [ "$E_ATTEMPT" = "$(sj attempt)" ] && [ "$ROLE" = "$(sj role)" ]; } \
    || refuse 6 "role or attempt changed"
}

send_key() {
  local i=$((KEYS + 1))
  [ -z "$JOURNAL" ] || echo "$ATTEMPT try $i $*" >> "$JOURNAL"
  if tmux send-keys -t "$PANE_ID" "$@" 2>/dev/null; then
    KEYS=$i; [ -z "$JOURNAL" ] || echo "$ATTEMPT ok $i" >> "$JOURNAL"
    return 0
  fi
  [ "$KEYS" -gt 0 ] || refuse 6 "pane gone"
  echo "error: send-keys failed at key $i — $KEYS keys sent" >&2; exit 4
}
type_text() { send_key -l -- "$1"; await_typed "$1"; send_key Enter; }
# An Enter sent before Claude Code took in the text is swallowed: wait for a settled frame with it.
await_typed() {
  local i=0 max prev="" cur
  max=$(( ${TEAM_TYPED_SECS:-5} * 5 ))
  while [ "$i" -lt "$max" ]; do
    cur="$(capture)"
    if is_typed "$1" "$cur"; then [ "$cur" != "$prev" ] || return 0; prev="$cur"; else prev=""; fi
    sleep 0.2; i=$((i + 1))
  done
  stop 6 "typed text not on screen — Enter not sent"
}
clear_draft() {  # clear_draft <draft> — save it before any clearing key, then verify an empty line
  local run dir f i=0 a
  run="$(cat "$TD/run" 2>/dev/null || true)"; a="$(sj attempt)"
  dir="$TD/drafts"; [ -z "$run" ] || dir="$TD/runs/$run/drafts"
  f="$dir/$ROLE-${a:-x}-$(team_utc | tr -d :).txt"
  { mkdir -p "$dir" && printf '%s\n' "$1" > "$f" && [ "$(cat "$f")" = "$1" ]; } 2>/dev/null \
    || stop 6 "draft not saved"
  echo "draft saved: $f"
  send_key C-e; send_key C-u
  while [ "$i" -lt 10 ]; do
    sleep 0.2
    fields "$(parse "$(capture)")"
    [ "$COMPLETE:$KIND:$BUSY:$EMPTY" != true:none:false:true ] || return 0
    i=$((i + 1))
  done
  stop 6 "draft not cleared (saved in $f)"
}
press_down() {
  local i=1
  while [ "$i" -lt "$1" ]; do send_key Down; i=$((i + 1)); done
}

multi_ready() {
  local n seen=',' requests
  [ "$CURSOR" = 1 ] || stop 6 "menu cursor is not on option 1 — answer in the window (tier 3)"
  TITLE="$(jq -r .title <<<"$P")"
  [ "$text" != none ] || return 0
  IFS=',' read -r -a requests <<<"$text"
  for n in "${requests[@]}"; do
    [ "$n" -lt "$OTHER" ] || multi_error "option $n is not a real option on screen"
    [[ "$seen" != *",$n,"* ]] || multi_error "duplicate option $n"
    seen="$seen$n,"
  done
}

# Capture the actual review before the final Enter; never submit an unanswered question.
multi_review() {
  local i=0 r k why=""
  while [ "$i" -lt 20 ]; do
    r="$(parse "$(capture)")"; k="$(jq -r .kind <<<"$r")"
    if [ "$k" = review ]; then
      jq -e --arg t "$TITLE" --arg e "$EXPECTED" '.review | .title == $t and .ready
        and .submit_cursor and .bullets == 1 and (.unanswered | not)
        and any(.answers[]; . == $e)' <<<"$r" >/dev/null \
        || multi_error "unexpected review or answer; final Enter not sent"
      # Polling outlives intermediate frames: submit only the still-open call's own review.
      if real_event "$EVENT" \
          && [ "$(python3 -I "$LIB/team_prompt.py" pending "$T" "$EVENT")" != yes ]; then
        multi_error "prompt event closed before review; final Enter not sent"
      fi
      return 0
    fi
    # Frames between the checkbox keys and the review (cursor on Submit, redraw) are transient.
    case "$k:$(jq -r .reason <<<"$r")" in
      checkbox:*|menu:*|*:incomplete:*|unreadable:*)
        r="$(jq -r '.reason | sub("^unreadable: "; "")' <<<"$r")"; [ -z "$r" ] || why="$r" ;;
      *) multi_error "review screen unavailable" ;;
    esac
    sleep 0.1; i=$((i + 1))
  done
  multi_error "review screen did not appear${why:+ (last: $why)}; final Enter not sent"
}

multi_send() {
  local i=1 want mark
  EXPECTED=''
  while [ "$i" -lt "$OTHER" ]; do
    want=' '; [[ ",$text," != *",$i,"* ]] || want='✔'
    mark="$(jq -r --argjson n "$i" '.options[] | select(.n == $n)
      | if .checked then "✔" else " " end' <<<"$P")"
    [ "$want" = "$mark" ] || send_key Enter
    if [ "$want" = '✔' ]; then
      EXPECTED="${EXPECTED:+$EXPECTED, }$(jq -r --argjson n "$i" \
        '.options[] | select(.n == $n) | .label' <<<"$P")"
    fi
    send_key Down; i=$((i + 1))
  done
  if [ "$text" = none ]; then
    EXPECTED='none - skip all'
    send_key Enter
    send_key -l -- "$EXPECTED"
  fi
  send_key Down
  send_key Enter
  multi_review
  send_key Enter
}

# Positive evidence only: an empty, mid-render or merely resized capture proves nothing.
confirm() {  # confirm <say|other|…>
  local mode="$1" n=0 max
  max=$(( ${TEAM_CONFIRM_SECS:-5} * 2 ))
  while :; do
    if [ "$mode" = say ]; then
      if real_event "$SAY_EVENT" && [ "$(python3 -I "$LIB/team_prompt.py" user-after "$T" \
          "$SAY_EVENT" "$text")" = yes ]; then echo "confirmed: yes (transcript)"; return; fi
    elif real_event "$EVENT" \
        && [ "$(python3 -I "$LIB/team_prompt.py" result "$T" "$EVENT")" = yes ]; then
      echo "confirmed: yes (tool_result)"; return
    fi
    fields "$(parse "$(capture)")"
    if [ "$COMPLETE:$KIND:$BUSY" = true:none:true ]; then
      [ "$mode" = say ] && echo "confirmed: yes (role busy)" \
        || echo "confirmed: yes (prompt gone, role busy)"
      return
    fi
    if [ "$mode" != say ] && ! real_event "$EVENT" && [ "$COMPLETE" = true ] \
        && [ "$KIND" != "$ORIG_KIND" ]; then
      case "$KIND" in
        permission|menu|checkbox) echo "confirmed: yes (successor screen)"; return ;;
      esac
    fi
    n=$((n + 1)); [ "$n" -lt "$max" ] || break
    sleep 0.5
  done
  if [ "$mode" != say ] && [ "$COMPLETE" = true ] && [ "$FP" = "$ORIG_FP" ]; then
    echo "confirmed: no — prompt still open"
  else
    echo "confirmed: no — no positive evidence"
  fi
}
report_sent() {  # report_sent <confirm mode> <label>
  confirm "$1"
  echo "sent $2 to $name; screen now:"
  capture | plain | sed '/^[[:space:]]*$/d' | tail -n 8 | sed 's/^/  | /'
}

# Last gate, immediately before the first key: a stop or mode switch during preflight wins.
last_gate() {
  if [ -n "$TIER" ]; then
    MODE_WHY="$(team_mode_ok "$ROOT" "$TIER" "$SEND")" || refuse 8 "$MODE_WHY"
  fi
  [ ! -e "$TD/cancel" ] || refuse 6 "team stopped"
  identity
}
reserve_dispatch() {  # reserve_dispatch <instance key> — one dispatch per instance, before keys
  local h hit log="$TD/send-$ROLE.log"
  h="$(printf '%s' "$1" | shasum -a 1 | cut -d' ' -f1)"
  if hit="$(grep -F " $h " "$log" 2>/dev/null | tail -n 1)"; then
    refuse 6 "instance already dispatched by $(sed -n 's/.* \(q=[^ ]*\) .*/\1/p' <<<"$hit")"
  fi
  [ -z "$QID" ] || echo "dispatch $(team_utc) $h q=$QID attempt=$ATTEMPT pid=$$" >> "$log"
}

finish_act() {  # finish_act — ACT/WHY from the screen, or exits: delivered, closed, refused
  local py="$LIB/team_prompt.py" typed=""
  ! is_typed "$text" "$PANE" || typed=1
  if [ "$SEND" = say ]; then
    if [ "$(python3 -I "$py" user-after "$T" "$E_EVENT" "$text")" = yes ]; then
      echo "finish: none — delivered (transcript)"; exit 0
    fi
    [ "$BUSY" = false ] || refuse 3 "role is busy"
    # A wrapped draft leaves no one-line input box, so the parse is unreadable only for that reason.
    if [ -n "$typed" ] \
        && { [ "$KIND" = none ] || [ "$REASON" = "unreadable: no idle input surface" ]; }; then
      ACT=enter; WHY="the text is in the input field"
    elif [ "$KIND" != none ]; then refuse 6 "a menu or permission prompt is open"
    elif [ "$EMPTY" = true ]; then ACT=text; WHY="the input field is empty"
    else refuse 6 "foreign draft in the field"; fi
    return 0
  fi
  if [ "$(python3 -I "$py" result "$T" "$E_EVENT")" = yes ]; then
    echo "finish: none — delivered (tool_result)"; exit 0
  fi
  case "$(python3 -I "$py" pending "$T" "$E_EVENT")" in
    yes) ;; unknown) refuse 3 "transcript unreadable" ;;
    *) echo "finish: none — question closed"; exit 0 ;;
  esac
  if [ "$KIND" = menu ] && [ -n "$typed" ]; then ACT=enter; WHY="the text is in the Other field"
  elif [ "$KIND" = menu ] && [ "$CURSOR" = 1 ] && [ "$OTHER" != - ]; then
    ACT=text; WHY="the menu is open, Other is empty"
  else refuse 6 "screen does not match the question"; fi
}

# finish_main — completes one unconfirmed say/other answer; reserved like an answer, own key.
finish_main() {
  identity
  [ -z "$E_RECORD" ] || [ "$E_RECORD" = "$(newest_record)" ] || refuse 6 "a newer record exists"
  real_event "$E_EVENT" || refuse 5 "no prompt event"
  T="$(team_role_transcript "$CLONE" "$(sj session_id)")"
  [ "$T" != - ] || refuse 3 "transcript unreadable"
  EVENT="$E_EVENT"; SAY_EVENT="$E_EVENT"; ORIG_KIND="$KIND"; ORIG_FP="$FP"
  finish_act
  last_gate
  reserve_dispatch "finish|$E_RUN|$QID|$ATTEMPT"
  case "$ACT:$SEND" in
    enter:*) send_key Enter ;;
    text:say) type_text "$text" ;;
    text:other) press_down "$OTHER"; type_text "$text" ;;
  esac
  echo "finish: $ACT — $WHY"
  report_sent "$SEND" finish
  exit 0
}

tmux has-session -t "=$name" 2>/dev/null || refuse 6 "session gone"
OWNER="direct pid=$$"; [ -z "$QID" ] || OWNER="q=$QID attempt=$ATTEMPT pid=$$"
HELD="$(team_send_lock "$TD" "$ROLE" "${TEAM_SEND_LOCK_WAIT_SENDER:-2}" "$OWNER")" \
  || refuse 3 "target busy ($HELD)"
trap 'team_send_unlock "$TD" "$ROLE"' EXIT

GEN="$(team_pane_gen "$name")" || refuse 6 "pane not found"
PANE_ID="${GEN%@*}"
[ -z "$E_PANE" ] || [ "$E_PANE" = "$GEN" ] || refuse 6 "pane generation changed"
T="$(team_role_transcript "$CLONE" "$(sj session_id)")"
PANE="$(capture)"; [ -n "$PANE" ] || refuse 3 "capture empty"
P="$(parse "$PANE")"; fields "$P"
[ "$action" != finish ] || finish_main
if [ "$COMPLETE" != true ]; then
  case "$REASON" in incomplete:*) refuse 3 "$REASON" ;; esac
  refuse 5 "${REASON#unreadable: }"
fi
ORIG_KIND="$KIND"; ORIG_FP="$FP"
case "$action" in
  yes|no) [ "$KIND" = permission ] || refuse 6 "no permission prompt on screen"
    [ "$action" = no ] || { [ "$CURSOR" = 1 ] && [ "$OPT1" = Yes ]; } \
      || refuse 6 "permission cursor is not on Yes" ;;
  pick|other) [ "$KIND" = menu ] && [ "$OTHER" != - ] || refuse 6 "no single-question menu on screen"
    [ "$CURSOR" = 1 ] || refuse 6 "menu cursor is not on option 1" ;;
  picks) [ "$KIND" = checkbox ] || refuse 6 "no single-question checkbox menu on screen"
    multi_ready ;;
  say) [ "$KIND" = none ] || refuse 6 "a menu or permission prompt is open"
    [ "$BUSY" = false ] || refuse 3 "role is busy"
    if [ "$EMPTY" != true ]; then
      WHY="$(draft_why "$INPUT")"
      [ -z "$WHY" ] || refuse 5 "draft not recoverable ($WHY) — clear the line in the window"
      DRAFT0="$INPUT"
    fi
    [ -z "$E_ANCHOR" ] || plain <<<"$PANE" | grep -F -- "$E_ANCHOR" >/dev/null \
      || refuse 6 "anchor no longer on screen" ;;
esac
if [ "$action" = pick ]; then
  jq -e --argjson n "$text" 'any(.options[]; .n == $n)' <<<"$P" >/dev/null \
    || refuse 6 "option $text not on screen"
fi

[ -z "$E_FP" ] || [ "$E_FP" = "$FP" ] || refuse 6 "prompt content changed"
identity
[ -z "$E_RECORD" ] || [ "$E_RECORD" = "$(newest_record)" ] || refuse 6 "a newer record exists"
case "$KIND" in permission) EVKIND=permission ;; none) EVKIND=blocked ;; *) EVKIND=menu ;; esac
EVENT=-
[ "$T" = - ] || EVENT="$(printf '%s' "$P" | python3 -I "$LIB/team_prompt.py" event "$T" "$EVKIND")"
if [ "$action" != say ]; then
  if [ -n "$QID" ]; then
    real_event "$E_EVENT" || refuse 5 "no prompt event"
    case "$EVENT" in ambiguous) refuse 5 "ambiguous event" ;; -) refuse 3 "transcript unreadable" ;; esac
    [ "$EVENT" = "$E_EVENT" ] || refuse 6 "new prompt event"
  fi
elif real_event "$E_EVENT"; then
  [ "$EVENT" != - ] || refuse 3 "transcript unreadable"
  [ "$EVENT" = "$E_EVENT" ] || refuse 6 "new prompt event"
fi
SAY_EVENT="$EVENT"

CLASS=""
if [ "$action" = yes ]; then
  POL=("$CLONE" --strict --main "$ROOT"); [ -z "$QID" ] || POL+=(--transcript "$T")
  # Only TeamLead's tier-1 answer may take a class; tier 3 is the Operator's own click.
  [ "$TIER" != 1 ] || [ -z "$QID" ] || POL+=(--classes)
  # Tier 1 only: ask/deny, SQL writes and egress are the Operator's to answer in the window.
  if ! PERR="$(printf '%s\n' "$PANE" | python3 -I "$LIB/team_prompt_check.py" "${POL[@]}" 2>&1)"; then
    case "$PERR" in
      *"could not read"*) refuse 5 "$PERR" ;;
      *) refuse 7 "$PERR — Operator answers in the window (tier 3)" ;;
    esac
  fi
  CLASS="$(sed -n 's/^policy-class: //p' <<<"$PERR" | tail -n 1)"
  [ -z "$CLASS" ] || echo "policy-class: $CLASS"
fi

case "$action" in
  say) if [ -n "$E_RECORD" ]; then KEY="$GEN|record:$E_RECORD|$EVENT"
       elif [ -n "$E_ANCHOR" ]; then KEY="$GEN|anchor:$E_ANCHOR|$EVENT"
       else KEY="$GEN|say:$(printf '%s' "$text" | shasum -a 1 | cut -d' ' -f1)|$EVENT"; fi ;;
  *) KEY="$GEN|$FP|$EVENT" ;;
esac

# Idle inputs all fingerprint v2:none and the send lock cannot stop a human typing: re-read it.
if [ -n "$DRAFT0" ]; then
  fields "$(parse "$(capture)")"
  { [ "$COMPLETE:$KIND:$BUSY" = true:none:false ] && [ "$INPUT" = "$DRAFT0" ]; } \
    || refuse 6 "draft changed"
fi

last_gate
if [ -n "$CLASS" ]; then
  team_class_on "$ROOT" "$CLASS" \
    || refuse 7 "class $CLASS off or not enabled — Operator answers in the window (tier 3)"
  # The classification widened the decision and took time: the prompt must be the one classified.
  fields "$(parse "$(capture)")"
  { [ "$COMPLETE:$KIND:$CURSOR:$OPT1" = true:permission:1:Yes ] && [ "$FP" = "$ORIG_FP" ] \
    && [ "$(python3 -I "$LIB/team_prompt.py" pending "$T" "$EVENT")" = yes ]; } \
    || refuse 6 "prompt changed during classification"
fi
reserve_dispatch "$KEY"

case "$action" in
  yes) send_key Enter ;;
  no)
    send_key Escape
    i=0; idle=""
    while [ "$i" -lt 10 ]; do
      sleep 0.2
      fields "$(parse "$(capture)")"
      if [ "$COMPLETE:$KIND:$EMPTY" = true:none:true ]; then idle=1; break; fi
      if [ "$COMPLETE:$KIND:$BUSY" = true:none:false ]; then
        WHY="$(draft_why "$INPUT")"
        [ -z "$WHY" ] || stop 6 "draft not recoverable ($WHY) after Escape"
        idle=1; break
      fi
      i=$((i + 1))
    done
    [ -n "$idle" ] || stop 6 "screen after Escape is not idle input"
    [ "$EMPTY" = true ] || clear_draft "$INPUT"
    type_text "Rejected by the developer${text:+: $text}. Treat it as a material question (team-mode.md §4): write a blocked record and wait." ;;
  say) [ -z "$DRAFT0" ] || clear_draft "$DRAFT0"; type_text "$text" ;;
  pick) press_down "$text"; send_key Enter ;;
  other) press_down "$OTHER"; type_text "$text" ;;
  picks) multi_send ;;
esac
report_sent "$action" "$action"
