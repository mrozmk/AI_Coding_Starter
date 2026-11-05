#!/usr/bin/env bash
# Question ledger for /monitor: record a team role's question, deliver a bound answer, revoke it.
#
# Usage: bash .claude/lib/team-question.sh <team> open <role> --kind blocked|menu|permission|idle
#          [--anchor "<text on screen>"] --summary "<5–10 lines>"
#        bash .claude/lib/team-question.sh <team> answer <q-id> --tier 1|2|3 --author <name>
#          --why "<one line>" [--text "<answer>"] --send <action> [--run <run>]
# Actions: yes|no|say|other|pick:<n>|picks:<n,n|none>|none (recorded only).
# Refused while tiers are off (tier 1/2) or answering is off (all but --tier 3 --send none).
# A recorded reviewer-fallback is answered only with --tier 2 --author TeamLead-fallback and its
#   recorded send/text/Reviewer id, or at tier 3.
#        bash .claude/lib/team-question.sh <team> retry <q-id> --run <run>   (not-sent-stale only)
#        bash .claude/lib/team-question.sh <team> finish <q-id> --run <run>   (sent unconfirmed /
#          unknown say|other, once: sends the missing text or Enter)
#        bash .claude/lib/team-question.sh <team> revoke <q-id> --why "<one line>"
#        bash .claude/lib/team-question.sh <team> show <q-id> | list | policy [<role>]
#          | screen <role>
#        bash .claude/lib/team-question.sh <team> orphans
#        bash .claude/lib/team-question.sh <team> unlock <q-id>|open   (stale lock of a killed call)
#        bash .claude/lib/team-question.sh <team> unlock-send <role>   (stale send lock)
#   e.g. bash .claude/lib/team-question.sh alfa answer q-3 --tier 1 --author supervisor \
#          --why "inside the plan" --text "Counter + backoff." --send say
# answer/retry exit: 0 sent|consumed|recorded · 1 refused, q unchanged · 3 not-sent-stale (retry) ·
#   4 unknown · 5 not-sent|failed; the last line is "q-<n> state=<state> — <delivery>".
# list: tierN counts sent/consumed/recorded answers of tier N (fallback= the TeamLead-fallback
#   ones of tier 2); failed= counts failed/not-sent*, pending= pending/unknown; the other counters
#   count questions in that state; all add up to total.
# orphans: escalations with no live waiter that need a --resume (dead waiter, no-reply,
#   cancelled, staged reply).
# Contract: .agents/reference/team-mode.md §10.
set -euo pipefail

usage() { sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
die() { echo "error: $*" >&2; exit 1; }
[ $# -ge 2 ] || usage
TEAM="$1"; CMD="$2"; shift 2
LIB="$(cd "$(dirname "$0")" && pwd)"
. "$LIB/team-lib.sh"
. "$LIB/team-question-lib.sh"
. "$LIB/team-escalate-lib.sh"
team_check_name "$TEAM" || exit 2
root="$(git rev-parse --show-toplevel)"
CLONE="$(team_clone_dir "$TEAM" "$root")"
[ -f "$CLONE/.agents/team/team.json" ] || die "no team clone at $CLONE"
cd "$CLONE"
TD="$CLONE/.agents/team"
[ -f "$TD/run" ] || die "no run in $TD"
RUN="$(cat "$TD/run")"
QD="$TD/runs/$RUN/questions"
LOCKED=()
trap 'for l in ${LOCKED[@]+"${LOCKED[@]}"}; do rm -rf "$l" 2>/dev/null || true; done' EXIT

artifact() { jq -r --arg p "$2" '[.artifacts[] | select(startswith($p))][0] // empty' "$1"; }
qpath() { [[ "$1" =~ ^q-[0-9]+$ ]] || die "question id must look like q-3"; echo "$QD/$1.md"; }
one_line() { case "$2" in *$'\n'*) die "$1 must be one line" ;; esac; }
pane() { team_pane "$TEAM-$1" "${2:-40}"; }

q_lock() { team_q_lock "$1" "$TEAM" || exit 1; LOCKED+=("$1.lock"); }
q_release() {
  local l keep=()
  rm -rf "$1.lock"
  for l in ${LOCKED[@]+"${LOCKED[@]}"}; do [ "$l" = "$1.lock" ] || keep+=("$l"); done
  LOCKED=(${keep[@]+"${keep[@]}"})
}

# set_delivery <q file> <value> [<confirmed line>] — rewrites the last "delivery: pending" line
set_delivery() {
  V="$2" C="${3:-}" awk '{ l[NR] = $0; if ($0 == "delivery: pending") at = NR }
    END { for (i = 1; i <= NR; i++) { if (i != at) { print l[i]; continue }
      print "delivery: " ENVIRON["V"]; if (ENVIRON["C"] != "") print ENVIRON["C"] } }' \
    "$1" > "$1.tmp.$$"
  mv "$1.tmp.$$" "$1"
}

notes_add() {
  local f
  f="$(team_notes_init "$RUN")"
  grep -qx '## Supervised decisions' "$f" || grep -qx '## Blockers' "$f" \
    || echo "warn: notes has no ## Blockers" >&2
  # ENVIRON, not -v: awk -v would expand backslash escapes in the answer text.
  NOTE="$1" awk '
    { l[NR] = $0 }
    $0 == "## Supervised decisions" && !s { s = NR }
    $0 == "## Blockers" && !b { b = NR }
    END {
      if (s) { at = s
        for (i = s + 1; i <= NR && l[i] !~ /^## /; i++) if (l[i] ~ /[^[:space:]]/) at = i }
      for (i = 1; i <= NR; i++) {
        if (!s && b == i) { print "## Supervised decisions"; print ENVIRON["NOTE"]; print "" }
        print l[i]
        if (s && i == at) print ENVIRON["NOTE"]
      }
      if (!s && !b) { print ""; print "## Supervised decisions"; print ENVIRON["NOTE"] }
    }' "$f" > "$f.tmp.$$"
  mv "$f.tmp.$$" "$f"
}

# role_live <q file> → rc 0, or prints why the question's role is not the session waiting on it.
# Busy and open-prompt screens are the sender's to refuse (team_prompt.py), not a second reader.
role_live() {
  [ -f "$TD/session.json" ] || { echo "no live role session"; return 1; }
  [ "$(session_json role)" = "$(field "$1" role)" ] \
    && [ "$(session_json attempt)" = "$(field "$1" attempt)" ] \
    || { echo "role or attempt changed"; return 1; }
}

cmd_open() {
  local role="${1:-}" kind="" anchor="" summary="" attempt record="-" q n tries=0 planner
  local busy="" defer="" st note="" ol="$QD/.open" first
  [ -n "$role" ] || usage; shift
  while [ $# -gt 0 ]; do
    [ $# -ge 2 ] || usage
    case "$1" in
      --kind) kind="$2" ;; --anchor) anchor="$2" ;; --summary) summary="$2" ;; *) usage ;;
    esac
    shift 2
  done
  case " $TEAM_ROLES cli " in *" $role "*) ;; *) die "unknown role $role" ;; esac
  [ -f "$TD/session.json" ] && [ "$(session_json role)" = "$role" ] \
    || die "$role is not the live role session"
  [ -n "$summary" ] || die "--summary is required"
  case "$kind" in blocked|menu|permission|idle) ;;
    *) die "--kind must be blocked, menu, permission or idle" ;; esac
  attempt="$(session_json attempt)"
  qb_capture "$role" "$kind"
  busy="$QB_BUSY"
  case "$kind" in
    blocked)
      record="$(newest_record "$role" "$attempt")"
      [ -n "$record" ] || die "no record for $role $attempt" ;;
    *)
      [ -n "$anchor" ] || die "--anchor is required for --kind $kind"; one_line --anchor "$anchor"
      [ -z "$busy" ] || die "$role is busy — not a question yet"
      [ -z "$QB_TRANSIENT" ] || die "$role prompt is still rendering — not a question yet"
      grep -qF -- "$anchor" <<<"$QB_TEXT" || die "anchor not on screen" ;;
  esac
  # A busy pane is no stable binding; a blocked q is keyed on its record, so defer the screen.
  if [ -n "$busy" ]; then
    QB_FP="-"; QB_UNREADABLE=""; note=" (fingerprint deferred: role is busy)"; defer=1
  elif [ -n "$QB_TRANSIENT" ]; then
    QB_FP="-"; QB_UNREADABLE=""; note=" (fingerprint deferred: prompt still rendering)"; defer=1
  fi
  mkdir -p "$QD"
  q_lock "$ol"
  q="$(qb_find_existing "$role" "$attempt" "$kind" "$record" "${anchor:--}")"
  if [ -n "$q" ]; then
    q_release "$ol"
    if [ "$kind" = blocked ]; then q_lock "$q"; fi
    st="$(team_q_state "$q" | cut -f1)"
    case "$kind:$st" in
      blocked:open) [ -n "$defer" ] || qb_set_binding "$q" ;;
      # Still unanswered, but only a deferred binding is filled: a changed screen stays stale.
      blocked:escalating|blocked:escalated|blocked:waiting-operator)
        [ -n "$defer" ] || [ "$(field "$q" fingerprint)" != - ] || qb_set_binding "$q" ;;
      *) note="" ;;
    esac
    echo "$(basename "$q" .md) $q (existing, state=$st)$note"; cat "$q"; return 0
  fi
  n=$(( $(ls -1 "$QD" | grep -c '^q-[0-9]*\.md$' || true) + 1 ))
  until ( set -o noclobber; : > "$QD/q-$n.md" ) 2>/dev/null; do
    tries=$((tries + 1)); [ "$tries" -lt 20 ] || die "could not allocate a question id"; n=$((n + 1))
  done
  q="$QD/q-$n.md"; planner="$(team_accepted_record "$RUN" planner)"
  {
    printf '# q-%s — %s %s attempt %s\n' "$n" "$TEAM" "$role" "$attempt"
    printf 'role: %s\nattempt: %s\nrun: %s\nkind: %s\nrecord: %s\n' \
      "$role" "$attempt" "$RUN" "$kind" "$record"
    printf 'anchor: %s\nfingerprint: %s\nopened: %s\n\n## Summary\n' \
      "${anchor:--}" "$QB_FP" "$(team_utc)"
    # A summary line that looks like a heading would be read as a ledger section.
    printf '%s\n' "$summary" | sed 's/^## / ## /'
    printf '\n## Context\n- last blocker: %s\n' "$(awk '/^## Blockers/{b=1; next} /^## /{b=0}
      b && /^- /{l=$0} END{print (l == "" ? "-" : l)}' "$TD/runs/$RUN/notes.md" 2>/dev/null || echo -)"
    printf -- '- spec: %s\n' "$([ -z "$planner" ] || artifact "$planner" .agents/specs/)"
    printf -- '- plan: %s\n\n## Screen\n' "$([ -z "$planner" ] || artifact "$planner" .agents/plans/)"
    printf '%s\n' "$QB_TEXT" | tail -n 40 | sed 's/^/    /'
  } >| "$q"
  qb_set_binding "$q"
  q_release "$ol"
  first="q-$n $q$note"
  [ "$QB_FP" != v2:unreadable ] || first="$first (unreadable: $QB_UNREADABLE)"
  echo "$first"; cat "$q"
}

answer_args_ok() {  # answer_args_ok <q file> — validates the flags (globals set by cmd_answer)
  case "$TIER" in 1|2|3) ;; *) die "--tier must be 1, 2 or 3" ;; esac
  [ -n "$AUTHOR" ] && [ -n "$WHY" ] && [ -n "$SEND" ] \
    || die "--author, --why and --send are required"
  one_line --author "$AUTHOR"; one_line --why "$WHY"; one_line --text "$TEXT"
  case "$SEND" in
    none) [ "$TIER" = 3 ] || die "--send none is tier 3 only" ;;
    say|other|no) [ -n "$TEXT" ] || die "--send $SEND needs --text" ;;
    yes) ;;
    picks:*) [[ "${SEND#picks:}" = none || "${SEND#picks:}" =~ ^[1-9][0-9]?(,[1-9][0-9]?)*$ ]] \
               || die "--send picks needs option numbers separated by commas, or none" ;;
    *) [[ "$SEND" =~ ^pick:[1-9][0-9]?$ ]] \
         || die "--send must be yes, no, say, other, pick:<n>, picks:<n,n|none> or none" ;;
  esac
  # A say on a menu or prompt ends with Enter, which confirms the focused option.
  case "$(field "$1" kind):$SEND" in
    blocked:none|menu:none|permission:none|idle:none|menu:pick:*|menu:picks:*|menu:other|\
    permission:yes|permission:no|blocked:say|idle:say) ;;
    *) die "--send $SEND does not fit a $(field "$1" kind) question" ;;
  esac
}

mode_refuse() {  # mode_refuse — before anything is written, so a refusal leaves the q unchanged
  local m
  m="$(team_mode_ok "$root" "$TIER" "$SEND")" || die "refused: $m — nothing sent"
}

shown_answer() {
  local shown
  case "$SEND" in
    picks:none) shown="(skip all: none - skip all)" ;;
    picks:*) shown="(menu options ${SEND#picks:})" ;;
    pick:*) shown="(menu option ${SEND#pick:})" ;; yes) shown="(approve)" ;; *) shown="" ;;
  esac
  if [ -n "$TEXT" ]; then
    case "$SEND" in picks:*) shown="$shown — $TEXT" ;; *) shown="$TEXT" ;; esac
  fi
  echo "$shown"
}

journal_answer() {  # journal_answer <q> <attempt> <shown> [<retry-of>]
  printf '\n## Answer\ntier: %s\nauthor: %s\nanswer: %s\nwhy: %s\nanswered: %s\nattempt: %s\n' \
    "$TIER" "$AUTHOR" "$3" "$WHY" "$(team_utc)" "$2" >> "$1"
  printf 'send: %s\ntext: %s\n' "$SEND" "${TEXT:--}" >> "$1"
  [ -z "${4:-}" ] || printf 'retry-of: %s\n' "$4" >> "$1"
  printf 'delivery: pending\n' >> "$1"
}

# sender_args <q> <id> <attempt> — the sender's binding options of q, into the array SA
sender_args() {
  local ev; ev="$(field "$1" event)"
  SA=(--clone "$CLONE" --root "$root" --q "$2" --attempt "$3" --journal "$1.keys"
      --tier "$TIER" --send "$SEND" --expect-fp "$(field "$1" fingerprint)"
      --expect-pane "$(field "$1" pane)" --expect-event "${ev:--}"
      --expect-session "$(field "$1" session)" --expect-run "$RUN"
      --expect-attempt "$(field "$1" attempt)")
  case "$(field "$1" kind)" in
    blocked) SA+=(--expect-record "$(field "$1" record)") ;;
    idle) SA+=(--expect-anchor "$(field "$1" anchor)") ;;
  esac
}

# deliver <q> <id> <attempt> <shown> — sender call, delivery mapping, notes; exits with qb_exit.
deliver() {
  local q="$1" id="$2" att="$3" role out rc st first notes ev cls
  local -a a
  role="$(field "$q" role)"; sender_args "$q" "$id" "$att"; a=("${SA[@]}")
  set +e
  case "$SEND" in
    picks:*|pick:*) out="$(bash "$LIB/team-answer.sh" "$TEAM" "$role" "${SEND%%:*}" "${SEND#*:}" \
                      "${a[@]}" 2>&1)" ;;
    yes) out="$(bash "$LIB/team-answer.sh" "$TEAM" "$role" yes "${a[@]}" 2>&1)" ;;
    *) out="$(bash "$LIB/team-answer.sh" "$TEAM" "$role" "$SEND" "$TEXT" "${a[@]}" 2>&1)" ;;
  esac
  rc=$?; set -e
  printf '%s\n' "$out"
  qb_outcome "$rc" "$out" "$q" "$id" "$att" "$role"
  set_delivery "$q" "$QB_DELIVERY" "$QB_CONFIRMED"
  st="$(team_q_state "$q" | cut -f1)"
  cls="$(sed -n 's/^policy-class: //p' <<<"$out" | tail -n 1)"
  notes="$TD/runs/$RUN/notes.md"
  case "$st" in
    sent|consumed|unknown)
      [ -z "$cls" ] || printf 'class: %s\n' "$cls" >> "$q"
      if [ "$TIER" != 3 ] && ! grep -qF -- "- $id [" "$notes" 2>/dev/null; then
        first="$(awk '/^## Summary$/{s=1; next} s && NF {print; exit}' "$q")"
        notes_add "- $id [tier $TIER, $AUTHOR${cls:+, class $cls}] $first → $4 — $WHY"
      fi ;;
  esac
  echo "$id state=$st — $QB_DELIVERY"
  exit "$(qb_exit "$st")"
}

fallback_guard() {  # under the q lock, before the journal: a refusal leaves the q unchanged
  local last send reviewer text
  last="$(esc_last_outcome "$1")"
  if [ "$AUTHOR" = TeamLead-fallback ]; then
    [ "$TIER" = 2 ] && [ "$last" = reviewer-fallback ] \
      && [[ "$WHY" == "$ESC_FALLBACK_WHY"* ]] \
      || die "refused: TeamLead-fallback needs a recorded reviewer-fallback outcome"
    # The delivery is the one try_fallback recorded, field for field.
    IFS=$'\t' read -r send reviewer text <<<"$(esc_fallback_block "$1")" || true
    [ -n "$send" ] || die "refused: the recorded fallback has no send/reviewer/text block"
    [ "$SEND" = "$send" ] || die "refused: --send $SEND differs from the recorded fallback ($send)"
    [ "$(esc_one_line "$TEXT")" = "$text" ] \
      || die "refused: --text differs from the recorded fallback"
    [ "${WHY#"$ESC_FALLBACK_WHY"}" = "$reviewer" ] \
      || die "refused: --why must name the recorded Reviewer #$reviewer"
    TEXT="$text"
  elif [ "$last" = reviewer-fallback ] && [ "$TIER" != 3 ]; then
    die "refused: a recorded fallback is answered with --author TeamLead-fallback (or tier 3)"
  fi
}

cmd_answer() {
  local id="${1:-}" q st reason shown
  [ -n "$id" ] || usage; shift; q="$(qpath "$id")"; [ -f "$q" ] || die "$id not found"
  TIER=""; AUTHOR=""; WHY=""; TEXT=""; SEND=""; ARUN=""
  while [ $# -gt 0 ]; do
    [ $# -ge 2 ] || usage
    case "$1" in
      --tier) TIER="$2" ;; --author) AUTHOR="$2" ;; --why) WHY="$2" ;; --text) TEXT="$2" ;;
      --send) SEND="$2" ;; --run) ARUN="$2" ;; *) usage ;;
    esac
    shift 2
  done
  q_lock "$q"
  [ -z "$ARUN" ] || [ "$ARUN" = "$RUN" ] || die "stale: run changed — nothing sent"
  fallback_guard "$q"
  st="$(team_q_state "$q" | cut -f1)"
  case "$st" in
    sent|consumed|recorded) die "$id already answered" ;;
    failed) [ "$TIER" = 3 ] || die "$id delivery failed — tier 3 only" ;;
    not-sent) [ "$TIER" = 3 ] || die "$id was not delivered — tier 3 only" ;;
    not-sent-stale) [ "$TIER" = 3 ] \
                      || die "$id was not delivered (stale): use retry — tier 3 only otherwise" ;;
    pending|unknown) [ "$TIER" = 3 ] && [ "$SEND" = none ] \
               || die "$id delivery unknown — tier 3, --send none only" ;;
    revoked) [ "$TIER" = 3 ] || die "$id was revoked — tier 3 only" ;;
  esac
  answer_args_ok "$q"
  mode_refuse
  if [ "$SEND" != none ]; then
    reason="$(qb_identity "$q")" || die "stale: $reason — nothing sent"
  fi
  # Re-read after the identity checks, before anything is written: a refusal leaves the q open.
  team_mode_ok "$root" "$TIER" "$SEND" >/dev/null \
    || die "refused: mode switched off — nothing sent"
  shown="$(shown_answer)"
  journal_answer "$q" "$(( $(qb_answer_count "$q") + 1 ))" "$shown"
  if [ "$SEND" = none ]; then
    set_delivery "$q" "recorded only"; echo "$id recorded (tier $TIER)"; return 0
  fi
  deliver "$q" "$id" "$(qb_answer_count "$q")" "$shown"
}

cmd_retry() {
  local id="${1:-}" q st n first reason
  [ -n "$id" ] || usage; shift; q="$(qpath "$id")"; [ -f "$q" ] || die "$id not found"
  [ $# = 2 ] && [ "$1" = --run ] || usage
  q_lock "$q"
  [ "$2" = "$RUN" ] || die "stale: run changed — nothing sent"
  st="$(team_q_state "$q" | cut -f1)"
  [ "$st" = not-sent-stale ] || die "refused: $id is $st — nothing to retry"
  case "$(field "$q" event)" in
    ""|-|ambiguous) die "refused: no proof of instance continuity — Operator" ;;
  esac
  # The latest block is the decision in force: a later tier-3 answer supersedes earlier ones.
  n="$(qb_answer_count "$q")"
  first="$(qb_block_field "$q" "$n" retry-of)"
  [ -n "$first" ] || first="$(qb_block_field "$q" "$n" answered)"
  [ "$(qb_chain "$q" "$first")" -lt 3 ] || die "refused: retry limit (3) — Operator"
  [ ! -e "$TD/cancel" ] || die "refused: team stopped"
  TIER="$(qb_block_field "$q" "$n" tier)"; AUTHOR="$(qb_block_field "$q" "$n" author)"
  WHY="$(qb_block_field "$q" "$n" why)"; SEND="$(qb_block_field "$q" "$n" send)"
  TEXT="$(qb_block_field "$q" "$n" text)"; [ "$TEXT" != - ] || TEXT=""
  [ -n "$SEND" ] || die "refused: $id has no recorded send action — Operator"
  mode_refuse
  reason="$(qb_identity "$q")" || die "stale: $reason — nothing sent"
  journal_answer "$q" "$((n + 1))" "$(qb_block_field "$q" "$n" answer)" "$first"
  deliver "$q" "$id" "$((n + 1))" "$(qb_block_field "$q" "$n" answer)"
}

# finish_record <q> <n> <sender rc> <sender output> — the outcome lines of a finish (cmd_finish)
finish_record() {
  local q="$1" fin
  fin="$(grep -m 1 '^finish: ' <<<"$4" | sed 's/^finish: //' || true)"
  qb_outcome "$3" "$4" "$q" "$(basename "$q" .md)" "${2}f" "$(field "$q" role)"
  if [ "$3" != 0 ] && ! grep -q "^${2}f try " "$q.keys" 2>/dev/null; then
    die "refused: finish ${QB_DELIVERY#not sent — } — q unchanged"
  fi
  printf 'finished: %s\n' "$(team_utc)" >> "$q"
  if [ "$3" != 0 ] || [ -z "$fin" ]; then
    printf 'finish: failed — %s\ndelivery: %s\n' "$QB_DELIVERY" "$QB_DELIVERY" >> "$q"
    FIN="failed — $QB_DELIVERY"; return 0
  fi
  printf 'finish: %s\n' "$fin" >> "$q"; FIN="$fin"
  case "$fin" in
    "none — question closed") FIN="$fin — state unchanged, Operator" ;;
    "none — delivered "*)
      printf 'delivery: sent\nconfirmed: yes %s\n' "${fin#none — delivered }" >> "$q" ;;
    *) printf 'delivery: %s\n' "$QB_DELIVERY" >> "$q"
       [ -z "$QB_CONFIRMED" ] || printf '%s\n' "$QB_CONFIRMED" >> "$q" ;;
  esac
}

cmd_finish() {
  local id="${1:-}" q st n out rc reason
  [ -n "$id" ] || usage; shift; q="$(qpath "$id")"; [ -f "$q" ] || die "$id not found"
  [ $# = 2 ] && [ "$1" = --run ] || usage
  q_lock "$q"
  [ "$2" = "$RUN" ] || die "stale: run changed — nothing sent"
  st="$(team_q_state "$q" | cut -f1)"
  case "$st" in sent|unknown) ;; *) die "refused: $id is $st — nothing to finish" ;; esac
  [ "$(grep '^## ' "$q" | tail -n 1)" = "## Answer" ] \
    || die "refused: $id has a section after its answer — Operator"
  n="$(qb_answer_count "$q")"
  SEND="$(qb_block_field "$q" "$n" send)"
  case "$SEND" in say|other) ;; *) die "refused: $id was sent with ${SEND:--}, not say/other" ;;
  esac
  [ -z "$(qb_block_field "$q" "$n" finished)" ] \
    || die "refused: $id already finished once — Operator"
  TIER="$(qb_block_field "$q" "$n" tier)"; TEXT="$(qb_block_field "$q" "$n" text)"
  mode_refuse
  reason="$(qb_identity "$q")" || die "stale: $reason — nothing sent"
  [ ! -e "$TD/cancel" ] || die "refused: team stopped"
  # Own attempt "<n>f": the .keys journal and qb_outcome count the finish keys apart.
  sender_args "$q" "$id" "${n}f"
  set +e
  out="$(bash "$LIB/team-answer.sh" "$TEAM" "$(field "$q" role)" finish "$TEXT" "${SA[@]}" 2>&1)"
  rc=$?; set -e
  printf '%s\n' "$out"
  finish_record "$q" "$n" "$rc" "$out"
  st="$(team_q_state "$q" | cut -f1)"
  echo "$id state=$st — finish $FIN"
  exit "$(qb_exit "$st")"
}

cmd_revoke() {
  local id="${1:-}" q why="" role reason="" rc out msg
  [ -n "$id" ] || usage; shift; q="$(qpath "$id")"; [ -f "$q" ] || die "$id not found"
  [ $# = 2 ] && [ "$1" = --why ] || usage
  why="$2"; [ -n "$why" ] || die "--why is required"; one_line --why "$why"
  q_lock "$q"
  case "$(team_q_state "$q" | cut -f1,2)" in
    sent$'\t'[12]|consumed$'\t'[12]|recorded$'\t'[12]|failed$'\t'[12]|pending$'\t'[12]) ;;
    unknown$'\t'[12]|not-sent$'\t'[12]|not-sent-stale$'\t'[12]) ;;
    *) die "$id has no tier 1/2 answer to revoke" ;;
  esac
  printf '\n## Revoked\nrevoked: %s\nwhy: %s\ndelivery: pending\n' "$(team_utc)" "$why" >> "$q"
  role="$(field "$q" role)"
  if ! reason="$(role_live "$q")"; then
    set_delivery "$q" "not sent — $reason"
    die "revoke recorded, not delivered ($reason) — tell the Operator"
  fi
  set +e
  msg="The supervisor's answer to $id is revoked by the Operator: $why. Undo what you did on it,"
  msg="$msg treat the question as material (team-mode.md §4) and wait for the Operator's answer."
  out="$(bash "$LIB/team-answer.sh" "$TEAM" "$role" say "$msg" --clone "$CLONE" --root "$root" \
    --attempt r --journal "$q.keys" 2>&1)"
  rc=$?; set -e
  printf '%s\n' "$out"
  qb_outcome "$rc" "$out" "$q" "$id" r "$role"
  set_delivery "$q" "$QB_DELIVERY"
  [ "$rc" = 0 ] || die "revoke recorded, $QB_DELIVERY — tell the Operator"
}

cmd_list() {
  local n q st tier author cls total=0 t1=0 t2=0 t3=0 rv=0 fl=0 pd=0 op=0 eg=0 ed=0 wo=0 fb=0
  for n in $(ls -1 "$QD" 2>/dev/null | sed -n 's/^q-\([0-9][0-9]*\)\.md$/\1/p' | sort -n); do
    q="$QD/q-$n.md"
    IFS=$'\t' read -r st tier author <<<"$(team_q_state "$q")"
    # Only ## Answer blocks: the free-text ## Summary may hold a `class: ` line too.
    cls="$(awk '/^## / { a = ($0 == "## Answer"); next }
      a && /^class: / { c = substr($0, 8) } END { print c }' "$q")"
    echo "q-$n $(field "$q" role) $(field "$q" kind) tier=$tier author=$author" \
      "state=$st${cls:+ class=$cls}"
    total=$((total + 1))
    [ "$author:$tier" != TeamLead-fallback:2 ] || tier=fallback
    case "$st:$tier" in
      sent:1|consumed:1|recorded:1) t1=$((t1 + 1)) ;;
      sent:fallback|consumed:fallback|recorded:fallback) fb=$((fb + 1)) ;;
      sent:2|consumed:2|recorded:2) t2=$((t2 + 1)) ;;
      sent:*|consumed:*|recorded:*) t3=$((t3 + 1)) ;; revoked:*) rv=$((rv + 1)) ;;
      failed:*|not-sent:*|not-sent-stale:*) fl=$((fl + 1)) ;;
      pending:*|unknown:*) pd=$((pd + 1)) ;; open:*) op=$((op + 1)) ;;
      escalating:*) eg=$((eg + 1)) ;; escalated:*) ed=$((ed + 1)) ;;
      waiting-operator:*) wo=$((wo + 1)) ;;
    esac
  done
  echo "total=$total tier1=$t1 tier2=$t2 tier3=$t3 revoked=$rv failed=$fl pending=$pd" \
    "open=$op escalating=$eg escalated=$ed waiting=$wo fallback=$fb"
}

cmd_orphans() {
  local q st last why
  for q in "$QD"/q-*.md; do
    [[ "$(basename "$q")" =~ ^q-[0-9]+\.md$ ]] || continue
    [ "$(esc_waiter "$q")" != live ] || continue
    st="$(team_q_state "$q" | cut -f1)"; last="$(esc_last_outcome "$q")"; why=""
    case "$st:$last" in
      escalating:*|waiting-operator:*) why=dead-waiter ;;
      escalated:no-reply*) why=no-reply ;;
      escalated:cancelled) why=cancelled ;;
    esac
    [ -z "$(esc_staged_unconsumed "$q")" ] || why=staged-reply
    [ -n "$why" ] || continue
    echo "$(basename "$q" .md) role=$(field "$q" role) tier=$(esc_tier "$q") state=$st" \
      "outcome=${last:--} reason=$why path=$q"
  done
}

cmd_policy() {  # cmd_policy [<role>] — with a role, the class of its open prompt
  local rel role="${1:-}" gen t
  for rel in .claude/settings.json .claude/settings.local.json; do
    if [ ! -f "$CLONE/$rel" ]; then echo "missing: $rel"; continue; fi
    jq -r --arg r "$rel" '.permissions.ask[]? | "ask  " + $r + ": " + .' "$CLONE/$rel"
    jq -r --arg r "$rel" '.permissions.deny[]? | "deny  " + $r + ": " + .' "$CLONE/$rel"
  done
  echo "classes: $(python3 -I "$LIB/team_prompt_classes.py" switches "$root")"
  [ -n "$role" ] || return 0
  team_check_name "$role" || exit 2
  [ -f "$TD/session.json" ] && [ "$(session_json role)" = "$role" ] \
    || die "$role is not the live role session"
  gen="$(team_pane_gen "$TEAM-$role")" || die "no pane for $TEAM-$role"
  t="$(team_role_transcript "$CLONE" "$(session_json session_id)")"
  # The main checkout's classifier, never the clone's (role-writable) copy.
  team_pane_scroll "${gen%@*}" | python3 -I "$LIB/team_prompt_check.py" "$CLONE" --strict \
    --transcript "$t" --classes --report --main "$root"
}

unlock_dir() {  # unlock_dir <lock dir> <label> — only a dead holder's lock older than 10 s
  local pid age
  [ -d "$1" ] || die "no lock to remove"
  pid="$(cat "$1/pid" 2>/dev/null || true)"
  [[ "$pid" =~ ^[0-9]+$ ]] || die "lock is not stale — no pid recorded"
  ! kill -0 "$pid" 2>/dev/null || die "lock is not stale — pid $pid is alive"
  age=$(( $(date +%s) - $(stat -f %m "$1") ))
  [ "$age" -gt 10 ] || die "lock is not stale — created ${age}s ago"
  rm -rf "$1"
  echo "removed stale lock of $2 (pid $pid dead)"
}

case "$CMD" in
  open) cmd_open "$@" ;;
  answer) cmd_answer "$@" ;;
  retry) cmd_retry "$@" ;;
  finish) cmd_finish "$@" ;;
  revoke) cmd_revoke "$@" ;;
  show) [ $# = 1 ] || usage; q="$(qpath "$1")"; [ -f "$q" ] || die "$1 not found"; cat "$q" ;;
  list) cmd_list ;;
  orphans) [ $# = 0 ] || usage; cmd_orphans ;;
  policy) [ $# -le 1 ] || usage; cmd_policy "$@" ;;
  screen) [ $# = 1 ] || usage; team_check_name "$1" || exit 2; pane "$1" 25 ;;
  unlock) [ $# = 1 ] || usage
    if [ "$1" = open ]; then unlock_dir "$QD/.open.lock" open
    else unlock_dir "$(qpath "$1").lock" "$1"; fi ;;
  unlock-send) [ $# = 1 ] || usage; team_check_name "$1" || exit 2
    unlock_dir "$TD/send-$1.lock" "send-$1" ;;
  *) usage ;;
esac
