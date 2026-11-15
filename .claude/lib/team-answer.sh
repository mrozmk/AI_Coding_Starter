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
#   --session <Role>: a supervision role session (no clone; supervisor-sessions.sh answer passes
#   it): <team> <role> must be its tmux name's halves, keys go to tw_tmux_name <Role>, the binding
#   is <main>/.agents/team/watch/sessions/<Role>/session.json; pick|other only, never with --clone.
#   (--tier 1 adds --classes to the yes policy check: a class prints policy-class: <name>)
#   --expect-fp --expect-pane --expect-event --expect-session --expect-run --expect-attempt
#   --expect-record --expect-anchor.
#   --authority class|teamlead|operator --why "<line>" [--decision <answered d-<n>.md>] — the
#   per-run TeamLead path (team-answer-lead.sh, team-lead.md §6); excludes --tier.
# Exit: 0 sent · 2 usage · 3 not sent, stale · 4 partial (keys sent, then a failure) · 5 not sent,
#   unreadable · 6 not sent, changed · 7 not sent, policy · 8 not sent, mode (team-mode.md §10)
#   or a lead-owned run given --tier · 9 not sent, human-only (a pending decision).
set -euo pipefail

usage() { sed -n '2,23p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
[ $# -ge 3 ] || usage
TEAM="$1"; ROLE="$2"; action="$3"; shift 3; text=""; have_text=""
if [ $(( $# % 2 )) = 1 ]; then text="$1"; have_text=1; shift; fi
CLONE=""; ROOT=""; SESSION=""; QID=""; ATTEMPT=""; JOURNAL=""; TIER=""; SEND=""
AUTH=""; WHY=""; DECISION=""; DEC_ID=""; DEC_FILE=""
E_FP=""; E_PANE=""; E_EVENT=""; E_SESSION=""; E_RUN=""; E_ATTEMPT=""; E_RECORD=""; E_ANCHOR=""
while [ $# -gt 0 ]; do
  case "$1" in
    --clone) CLONE="$2" ;; --root) ROOT="$2" ;; --session) SESSION="$2" ;; --q) QID="$2" ;; --attempt) ATTEMPT="$2" ;;
    --journal) JOURNAL="$2" ;; --tier) TIER="$2" ;; --send) SEND="$2" ;;
    --expect-fp) E_FP="$2" ;; --expect-pane) E_PANE="$2" ;; --expect-event) E_EVENT="$2" ;;
    --expect-session) E_SESSION="$2" ;; --expect-run) E_RUN="$2" ;;
    --expect-attempt) E_ATTEMPT="$2" ;; --expect-record) E_RECORD="$2" ;;
    --expect-anchor) E_ANCHOR="$2" ;;
    --authority) AUTH="$2" ;; --why) WHY="$2" ;; --decision) DECISION="$2" ;;
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
. "$LIB/team-answer-lead.sh"
name="$TEAM-$ROLE"
[ -n "$ROOT" ] || ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
if [ -n "$SESSION" ]; then
  # A supervision role session: no clone, its binding lives in the main checkout's watch dir.
  [ -z "$CLONE" ] || { echo "error: --session and --clone exclude each other" >&2; exit 2; }
  case "$action" in pick|other) ;;
    *) echo "error: --session answers pick|other only (supervisor-sessions.sh answer)" >&2; exit 2 ;;
  esac
  . "$LIB/team-channel.sh"; . "$LIB/team-watch-route.sh"
  tw_session_role_ok "$SESSION" || { echo "error: --session: unknown role $SESSION" >&2; exit 2; }
  team_channel_names "$ROOT" || exit 2
  [ "$name" = "$(tw_session_name "$SESSION")" ] \
    || { echo "error: --session $SESSION is tmux $(tw_session_name "$SESSION"), not $name" >&2; exit 2; }
  ROLE="$SESSION"; CLONE="$ROOT"; name="$SESSION"; TD="$ROOT/.agents/team/watch/sessions/$SESSION"
  [ -r "$TD/session.json" ] && [ -n "$(jq -r '.session_id // empty' "$TD/session.json" 2>/dev/null)" ] \
    || { echo "error: Operator action: no readable session.json for $SESSION (start it with supervisor-sessions.sh) — nothing sent" >&2; exit 5; }
else
  [[ "$name" =~ ^[a-z0-9-]+$ ]] || { echo "error: bad session name $name" >&2; exit 2; }
  # team-question.sh always passes --clone: it runs inside the clone, where this derivation breaks.
  [ -n "$CLONE" ] || CLONE="$(team_clone_dir "$TEAM" "$ROOT")"
  TD="$CLONE/.agents/team"
  # A clone-less caller without --session: lock in this checkout.
  [ -d "$TD" ] || { TD="$ROOT/.agents/team"; mkdir -p "$TD"; }
fi
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
capture() { sh_read_target "$PANE_ID" --history 200 --escapes 2>/dev/null || true; }
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
newest_record() { team_newest_record "$TD" "$(team_run_ref "$TD" "$(cat "$TD/run" 2>/dev/null)")" "$ROLE" "$(sj attempt)"; }
identity() {
  local s; s="$(sj session_id)"
  [ -z "$E_SESSION" ] || [ "$E_SESSION" = "${s:--}" ] || refuse 6 "session changed"
  [ -z "$E_RUN" ] || [ "$E_RUN" = "$(cat "$TD/run" 2>/dev/null)" ] || refuse 6 "run changed"
  [ -z "$E_ATTEMPT" ] || { [ "$E_ATTEMPT" = "$(sj attempt)" ] && [ "$ROLE" = "$(sj role)" ]; } \
    || refuse 6 "role or attempt changed"
}

# HB: the target's backend (its registry record). Herdr is driven through the driver's lib calls on
# the handle (PANE_ID), under this script's own send lock, as tmux is through send-keys.
send_key() {
  local i=$((KEYS + 1)) rc=0
  [ -z "$JOURNAL" ] || echo "$ATTEMPT try $i $*" >> "$JOURNAL"
  if [ "$HB" = herdr ]; then
    # hc types text only by pasting and submitting it, which would answer an open prompt.
    [ "$1" != -l ] || stop 5 "typing into an open prompt is not supported under herdr — answer in the window"
    sh_herdr_keys "$PANE_ID" "$@" 2>/dev/null || rc=$?
  else
    sh_tmux send-keys -t "$PANE_ID" "$@" 2>/dev/null || rc=$?
  fi
  if [ "$rc" = 0 ]; then
    KEYS=$i; [ -z "$JOURNAL" ] || echo "$ATTEMPT ok $i" >> "$JOURNAL"
    return 0
  fi
  [ "$KEYS" -gt 0 ] || refuse 6 "pane gone"
  echo "error: send-keys failed at key $i — $KEYS keys sent" >&2; exit 4
}
type_text() {
  if [ "$HB" = herdr ]; then herdr_type "$1"; return; fi
  send_key -l -- "$1"; await_typed "$1"; send_key Enter
}
# herdr_type <text> — hc send pastes and submits in one step (the driver prints typed+submitted), so
# there is no typed-text check and no Enter; delivery is confirmed from the transcript instead: a
# new user message holding the text (hc may wrap it in an <hc from=…> tag).
herdr_type() {
  local i=$((KEYS + 1)) out size=0 n=0 max
  [ -z "$JOURNAL" ] || echo "$ATTEMPT try $i type (herdr)" >> "$JOURNAL"
  [ "$T" = - ] || [ ! -f "$T" ] || size="$(wc -c < "$T" | tr -d ' ')"
  # Refused (9) on an open prompt or an empty status (a startup dialog may be open): the driver's
  # one-line reason lands in the refuse/stop message below.
  out="$(sh_herdr_type "$PANE_ID" "$1" "$(sh_record_get "$(team_main)" "$name" cli 2>/dev/null)" "$name" 2>&1)" || true
  if [ "$out" != typed+submitted ]; then
    [ "$KEYS" -gt 0 ] || refuse 6 "type failed: ${out:-no answer}"
    echo "error: type failed at key $i (${out:-no answer}) — $KEYS keys sent" >&2; exit 4
  fi
  KEYS=$i; [ -z "$JOURNAL" ] || echo "$ATTEMPT ok $i" >> "$JOURNAL"
  [ "$T" != - ] || { echo "typed+submitted (no transcript to confirm)"; return 0; }
  max=$(( ${TEAM_TYPED_SECS:-5} * 5 ))
  while [ "$n" -lt "$max" ]; do
    [ "$(python3 -I -c 'import json, sys
f = open(sys.argv[1], "rb"); f.seek(int(sys.argv[2])); t = sys.argv[3]; hit = "no"
for l in f:
    try: o = json.loads(l)
    except ValueError: continue
    if o.get("type") != "user": continue
    c = (o.get("message") or {}).get("content")
    s = c if isinstance(c, str) else " ".join(x.get("text", "") for x in c or [] if isinstance(x, dict))
    if t in s: hit = "yes"; break
print(hit)' "$T" "$size" "$1" 2>/dev/null)" != yes ] || { echo "typed+submitted (transcript)"; return 0; }
    sleep 0.2; n=$((n + 1))
  done
  stop 6 "typed text not in the transcript after submit"
}
# herdr_other <text> — `other` under herdr (owner, 2026-11-15): typing into the open menu is not
# possible, so deny it (esc, as `no`), wait until the prompt is gone, then the text on the idle input.
herdr_other() {
  local n=0 max=$(( ${TEAM_TYPED_SECS:-5} * 5 ))
  [ -z "$JOURNAL" ] || echo "$ATTEMPT other→deny+message (herdr)" >> "$JOURNAL"
  echo "other→deny+message (herdr)"
  send_key Escape
  while [ "$(sh_herdr_state "$PANE_ID")" = blocked ]; do
    n=$((n + 1)); [ "$n" -lt "$max" ] || stop 6 "prompt still open after Escape"
    sleep 0.2
  done
  type_text "$1"
}
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
  local who="$QID"; [ -n "$who" ] || [ -z "$AUTH" ] || who="authority:$AUTH"
  [ -z "$who" ] || echo "dispatch $(team_utc) $h q=$who attempt=$ATTEMPT pid=$$" >> "$log"
}

finish_act() {  # finish_act — ACT/WHY from the screen, or exits: delivered, closed, refused
  local py="$LIB/team_prompt.py" typed="" ev
  ! is_typed "$text" "$PANE" || typed=1
  if [ "$SEND" = say ]; then
    ev="$(python3 -I "$py" event "$T" blocked)"
    [ "$ev" != - ] || refuse 6 "new prompt event (transcript unreadable)"
    if [ "$(python3 -I "$py" user-after "$T" "$E_EVENT" "$text")" = yes ]; then
      echo "finish: none — delivered (transcript)"; exit 0
    fi
    # Only after the delivered check: a say the role already took has a newer assistant event.
    [ "$ev" = "$E_EVENT" ] || refuse 6 "new prompt event"
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
  [ "$KIND" = menu ] || refuse 6 "screen does not match the question"
  ev="$(printf '%s' "$P" | python3 -I "$py" event "$T" menu)"
  case "$ev" in
    "$E_EVENT") ;; ambiguous) refuse 5 "ambiguous event" ;;
    -) refuse 3 "transcript unreadable" ;; *) refuse 6 "new prompt event" ;;
  esac
  if [ -n "$typed" ]; then ACT=enter; WHY="the text is in the Other field"
  elif [ "$CURSOR" = 1 ] && [ "$OTHER" != - ]; then
    ACT=text; WHY="the menu is open, Other is empty"
  else refuse 6 "screen does not match the question"; fi
}

# finish_main — completes one unconfirmed say/other answer; reserved like an answer, own key.
finish_main() {
  identity
  [ -z "$E_RECORD" ] || [ "$E_RECORD" = "$(newest_record)" ] || refuse 6 "a newer record exists"
  real_event "$E_EVENT" || refuse 5 "no prompt event"
  T="$(team_role_transcript "$CLONE" "$(sj session_id)" "$(sj claude_config_dir)")"
  [ "$T" != - ] || refuse 3 "transcript unreadable"
  EVENT="$E_EVENT"; SAY_EVENT="$E_EVENT"; ORIG_KIND="$KIND"; ORIG_FP="$FP"
  finish_act
  last_gate
  reserve_dispatch "finish|$E_RUN|$QID|$ATTEMPT"
  case "$ACT:$SEND" in
    enter:*) send_key Enter ;;
    text:say) type_text "$text" ;;
    text:other) if [ "$HB" = herdr ]; then herdr_other "$text"
                else press_down "$OTHER"; type_text "$text"; fi ;;
  esac
  echo "finish: $ACT — $WHY"
  report_sent "$SEND" finish
  exit 0
}

auth_preflight
team_tmux_alive "$name" || refuse 6 "session gone"
OWNER="direct pid=$$"; [ -z "$QID" ] || OWNER="q=$QID attempt=$ATTEMPT pid=$$"
HELD="$(team_send_lock "$TD" "$ROLE" "${TEAM_SEND_LOCK_WAIT_SENDER:-2}" "$OWNER")" \
  || refuse 3 "target busy ($HELD)"
trap 'team_send_unlock "$TD" "$ROLE"' EXIT

GEN="$(team_pane_gen "$name")" || refuse 6 "pane not found"
HB="$(sh_record_get "$(team_main)" "$name" backend 2>/dev/null)"
PANE_ID="${GEN%@*}"
[ -z "$E_PANE" ] || [ "$E_PANE" = "$GEN" ] || refuse 6 "pane generation changed"
T="$(team_role_transcript "$CLONE" "$(sj session_id)" "$(sj claude_config_dir)")"
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
auth_event
SAY_EVENT="$EVENT"

CLASS=""
if [ "$action" = yes ]; then
  POL=("$CLONE" --strict --main "$ROOT"); [ -z "$QID" ] || POL+=(--transcript "$T")
  # Only TeamLead's tier-1 answer may take a class; tier 3 is the Operator's own click.
  [ "$TIER" != 1 ] || [ -z "$QID" ] || POL+=(--classes)
  [ -z "$AUTH" ] || POL+=(--transcript "$T" --authority "$AUTH")
  # Tier 1 only: ask/deny, SQL writes and egress are the Operator's to answer in the window.
  if ! PERR="$(printf '%s\n' "$PANE" | python3 -I "$LIB/team_prompt_check.py" "${POL[@]}" 2>&1)"; then
    case "$PERR" in
      *"could not read"*) refuse 5 "$PERR" ;;
      *"human-only:"*) refuse 9 "$PERR" ;;
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
if [ -n "$CLASS" ] || { [ -n "$AUTH" ] && [ "$action" = yes ]; }; then
  [ -z "$CLASS" ] || team_class_on "$ROOT" "$CLASS" \
    || refuse 7 "class $CLASS off or not enabled — Operator answers in the window (tier 3)"
  # The classification widened the decision and took time: the prompt must be the one classified.
  fields "$(parse "$(capture)")"
  { [ "$COMPLETE:$KIND:$CURSOR:$OPT1" = true:permission:1:Yes ] && [ "$FP" = "$ORIG_FP" ] \
    && [ "$(python3 -I "$LIB/team_prompt.py" pending "$T" "$EVENT")" = yes ]; } \
    || refuse 6 "prompt changed during classification"
fi
reserve_dispatch "$KEY"; auth_dispatch

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
  other) if [ "$HB" = herdr ]; then herdr_other "$text"
         else press_down "$OTHER"; type_text "$text"; fi ;;
  picks) multi_send ;;
esac
report_sent "$action" "$action"
auth_after
