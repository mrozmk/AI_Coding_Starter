#!/usr/bin/env bash
# Question ledger for /monitor: record a team role's question, deliver a bound answer, revoke it.
#
# Usage: bash .claude/lib/team-question.sh <team> open <role> --kind blocked|menu|permission|idle
#          [--anchor "<text on screen>"] --summary "<5–10 lines>"
#        bash .claude/lib/team-question.sh <team> answer <q-id> --tier 1|2|3 --author <name>
#          --why "<one line>" [--text "<answer>"] --send <action> [--run <run>]
# Actions: yes|no|say|other|pick:<n>|picks:<n,n|none>|none (recorded only).
#        bash .claude/lib/team-question.sh <team> revoke <q-id> --why "<one line>"
#        bash .claude/lib/team-question.sh <team> show <q-id> | list | policy | screen <role>
#        bash .claude/lib/team-question.sh <team> unlock <q-id>   (stale lock of a killed answer)
#   e.g. bash .claude/lib/team-question.sh alfa answer q-3 --tier 1 --author supervisor \
#          --why "inside the plan" --text "Counter + backoff." --send say
# list: tierN counts sent/recorded answers of tier N; the other counters count questions in that
#   state; together they add up to total.
# Contract: .agents/reference/team-mode.md §10.
set -euo pipefail

usage() { sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
die() { echo "error: $*" >&2; exit 1; }
[ $# -ge 2 ] || usage
TEAM="$1"; CMD="$2"; shift 2
LIB="$(cd "$(dirname "$0")" && pwd)"
. "$LIB/team-lib.sh"
team_check_name "$TEAM" || exit 2
root="$(git rev-parse --show-toplevel)"
CLONE="$(dirname "$root")/$(basename "$root")-$TEAM"
[ -f "$CLONE/.agents/team/team.json" ] || die "no team clone at $CLONE"
cd "$CLONE"
TD="$CLONE/.agents/team"
[ -f "$TD/run" ] || die "no run in $TD"
RUN="$(cat "$TD/run")"
QD="$TD/runs/$RUN/questions"
LOCKED=""
trap '[ -z "$LOCKED" ] || rm -rf "$LOCKED" 2>/dev/null || true' EXIT

artifact() { jq -r --arg p "$2" '[.artifacts[] | select(startswith($p))][0] // empty' "$1"; }
qpath() { [[ "$1" =~ ^q-[0-9]+$ ]] || die "question id must look like q-3"; echo "$QD/$1.md"; }
one_line() { case "$2" in *$'\n'*) die "$1 must be one line" ;; esac; }
pane() { team_pane "$TEAM-$1" "${2:-40}"; }
fp_of() { printf '%s\n' "$1" | shasum -a 1 | cut -d' ' -f1; }
newest_record() {
  local r; r="$(team_records "$RUN" "$1" "$2" | tail -n 1)"; [ -z "$r" ] || basename "$r"
}
# Header fields sit above the first heading; the summary below may hold arbitrary text.
field() {
  awk -v k="$2: " '/^## /{exit} index($0, k) == 1 {print substr($0, length(k) + 1); exit}' "$1"
}

q_lock() { team_q_lock "$1" "$TEAM" || exit 1; LOCKED="$1.lock"; }

set_delivery() {  # set_delivery <q file> <value> — rewrites the last "delivery: pending" line
  awk -v v="$2" '{ l[NR] = $0; if ($0 == "delivery: pending") at = NR }
    END { for (i = 1; i <= NR; i++) print (i == at ? "delivery: " v : l[i]) }' "$1" > "$1.tmp.$$"
  mv "$1.tmp.$$" "$1"
}

set_fingerprint() {  # set_fingerprint <q file> <fp> — rewrites the header's fingerprint line
  awk -v v="$2" '/^## /{h=1} !h && !d && index($0, "fingerprint: ") == 1 {
    print "fingerprint: " v; d = 1; next } { print }' "$1" > "$1.tmp.$$"
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
role_live() {
  [ -f "$TD/session.json" ] || { echo "no live role session"; return 1; }
  [ "$(session_json role)" = "$(field "$1" role)" ] \
    && [ "$(session_json attempt)" = "$(field "$1" attempt)" ] \
    || { echo "role or attempt changed"; return 1; }
  ! pane "$(field "$1" role)" | grep -qF 'esc to interrupt' || { echo "role is busy"; return 1; }
}

# binding_ok <q file> → rc 0, or prints the reason the question is no longer the one on screen.
binding_ok() {
  local q="$1" role p
  role_live "$q" || return 1
  role="$(field "$q" role)"; p="$(pane "$role")"
  [ "$(field "$q" fingerprint)" != - ] \
    || { echo "fingerprint not recorded (role was busy at open) — open again"; return 1; }
  [ "$(fp_of "$p")" = "$(field "$q" fingerprint)" ] \
    || { echo "screen changed since open"; return 1; }
  if [ "$(field "$q" kind)" = blocked ]; then
    [ "$(newest_record "$role" "$(field "$q" attempt)")" = "$(field "$q" record)" ] \
      || { echo "a newer record exists"; return 1; }
  else
    grep -qF -- "$(field "$q" anchor)" <<<"$p" || { echo "anchor no longer on screen"; return 1; }
  fi
}

find_existing() {  # find_existing <role> <attempt> <kind> <record> <anchor> <fingerprint>
  local q
  for q in "$QD"/q-*.md; do
    [ -f "$q" ] || continue
    [ "$(field "$q" role)" = "$1" ] && [ "$(field "$q" attempt)" = "$2" ] \
      && [ "$(field "$q" kind)" = "$3" ] || continue
    if [ "$3" = blocked ]; then [ "$(field "$q" record)" = "$4" ] || continue
    else [ "$(field "$q" anchor)" = "$5" ] && [ "$(field "$q" fingerprint)" = "$6" ] || continue; fi
    echo "$q"; return 0
  done
}

cmd_open() {
  local role="${1:-}" kind="" anchor="" summary="" attempt record="-" fp q n tries=0 planner
  local p busy="" st note=""
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
  attempt="$(session_json attempt)"
  p="$(pane "$role")"
  ! grep -qF 'esc to interrupt' <<<"$p" || busy=1
  case "$kind" in
    blocked)
      record="$(newest_record "$role" "$attempt")"
      [ -n "$record" ] || die "no record for $role $attempt" ;;
    menu|permission|idle)
      [ -n "$anchor" ] || die "--anchor is required for --kind $kind"; one_line --anchor "$anchor"
      [ -z "$busy" ] || die "$role is busy — not a question yet"
      grep -qF -- "$anchor" <<<"$p" || die "anchor not on screen" ;;
    *) die "--kind must be blocked, menu, permission or idle" ;;
  esac
  # A busy pane is no stable binding; a blocked q is keyed on its record, so defer the screen.
  if [ -n "$busy" ]; then fp="-"; note=" (fingerprint deferred: role is busy)"
  else fp="$(fp_of "$p")"; fi
  q="$(find_existing "$role" "$attempt" "$kind" "$record" "${anchor:--}" "$fp")"
  if [ -n "$q" ]; then
    if [ "$kind" = blocked ]; then q_lock "$q"; fi
    st="$(team_q_state "$q" | cut -f1)"
    case "$kind:$st" in
      blocked:open) [ -n "$busy" ] || set_fingerprint "$q" "$fp" ;;
      # Still unanswered, but only a deferred binding is filled: a changed screen stays stale.
      blocked:escalating|blocked:escalated|blocked:waiting-operator)
        [ -n "$busy" ] || [ "$(field "$q" fingerprint)" != - ] || set_fingerprint "$q" "$fp" ;;
      *) note="" ;;
    esac
    echo "$(basename "$q" .md) $q (existing, state=$st)$note"; cat "$q"; return 0
  fi
  mkdir -p "$QD"
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
      "${anchor:--}" "$fp" "$(team_utc)"
    # A summary line that looks like a heading would be read as a ledger section.
    printf '%s\n' "$summary" | sed 's/^## / ## /'
    printf '\n## Context\n- last blocker: %s\n' "$(awk '/^## Blockers/{b=1; next} /^## /{b=0}
      b && /^- /{l=$0} END{print (l == "" ? "-" : l)}' "$TD/runs/$RUN/notes.md" 2>/dev/null || echo -)"
    printf -- '- spec: %s\n' "$([ -z "$planner" ] || artifact "$planner" .agents/specs/)"
    printf -- '- plan: %s\n\n## Screen\n' "$([ -z "$planner" ] || artifact "$planner" .agents/plans/)"
    printf '%s\n' "$p" | sed 's/^/    /'
  } >| "$q"
  echo "q-$n $q$note"; cat "$q"
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

answer_deliver() {
  case "$SEND" in
    picks:*|pick:*) bash "$LIB/team-answer.sh" "$TEAM" "$1" "${SEND%%:*}" "${SEND#*:}" ;;
    yes) bash "$LIB/team-answer.sh" "$TEAM" "$1" yes ;;
    *) bash "$LIB/team-answer.sh" "$TEAM" "$1" "$SEND" "$TEXT" ;;
  esac
}

cmd_answer() {
  local id="${1:-}" q role st reason shown rc out first
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
  st="$(team_q_state "$q" | cut -f1)"
  case "$st" in
    failed) [ "$TIER" = 3 ] || die "$id delivery failed — tier 3 only" ;;
    pending) [ "$TIER" = 3 ] && [ "$SEND" = none ] \
               || die "$id delivery unknown — tier 3, --send none only" ;;
    sent|recorded) die "$id already answered" ;;
    revoked) [ "$TIER" = 3 ] || die "$id was revoked — tier 3 only" ;;
  esac
  answer_args_ok "$q"
  role="$(field "$q" role)"
  if [ "$SEND" != none ]; then reason="$(binding_ok "$q")" || die "stale: $reason — nothing sent"; fi
  case "$SEND" in
    picks:none) shown="(skip all: none - skip all)" ;;
    picks:*) shown="(menu options ${SEND#picks:})" ;;
    pick:*) shown="(menu option ${SEND#pick:})" ;; yes) shown="(approve)" ;; *) shown="" ;;
  esac
  if [ -n "$TEXT" ]; then
    case "$SEND" in picks:*) shown="$shown — $TEXT" ;; *) shown="$TEXT" ;; esac
  fi
  printf '\n## Answer\ntier: %s\nauthor: %s\nanswer: %s\nwhy: %s\nanswered: %s\ndelivery: pending\n' \
    "$TIER" "$AUTHOR" "$shown" "$WHY" "$(team_utc)" >> "$q"
  if [ "$TIER" != 3 ]; then
    first="$(awk '/^## Summary$/{s=1; next} s && NF {print; exit}' "$q")"
    notes_add "- $id [tier $TIER, $AUTHOR] $first → $shown — $WHY"
  fi
  if [ "$SEND" = none ]; then
    set_delivery "$q" "recorded only"; echo "$id recorded (tier $TIER)"; return 0
  fi
  set +e
  out="$(answer_deliver "$role" 2>&1)"
  rc=$?; set -e
  printf '%s\n' "$out"
  [ "$rc" = 0 ] \
    || { set_delivery "$q" "failed (rc $rc)"; die "delivery failed — ask the Operator (tier 3)"; }
  set_delivery "$q" sent
}

cmd_revoke() {
  local id="${1:-}" q why="" role reason="" rc out msg
  [ -n "$id" ] || usage; shift; q="$(qpath "$id")"; [ -f "$q" ] || die "$id not found"
  [ $# = 2 ] && [ "$1" = --why ] || usage
  why="$2"; [ -n "$why" ] || die "--why is required"; one_line --why "$why"
  q_lock "$q"
  case "$(team_q_state "$q" | cut -f1,2)" in
    sent$'\t'[12]|recorded$'\t'[12]|failed$'\t'[12]|pending$'\t'[12]) ;;
    *) die "$id has no tier 1/2 answer to revoke" ;;
  esac
  printf '\n## Revoked\nrevoked: %s\nwhy: %s\ndelivery: pending\n' "$(team_utc)" "$why" >> "$q"
  role="$(field "$q" role)"
  if ! reason="$(role_live "$q")"; then :
  elif pane "$role" | grep -qF 'Enter to select' || team_prompt_open "$TEAM-$role"; then
    reason="a menu or permission prompt is open"
  fi
  if [ -n "$reason" ]; then
    set_delivery "$q" "not sent — $reason"
    die "revoke recorded, not delivered ($reason) — tell the Operator"
  fi
  set +e
  msg="The supervisor's answer to $id is revoked by the Operator: $why. Undo what you did on it,"
  msg="$msg treat the question as material (team-mode.md §4) and wait for the Operator's answer."
  out="$(bash "$LIB/team-answer.sh" "$TEAM" "$role" say "$msg" 2>&1)"
  rc=$?; set -e
  printf '%s\n' "$out"
  [ "$rc" = 0 ] || { set_delivery "$q" "failed (rc $rc)"
    die "revoke recorded, delivery failed — tell the Operator"; }
  set_delivery "$q" sent
}

cmd_list() {
  local n q st tier author total=0 t1=0 t2=0 t3=0 rv=0 fl=0 pd=0 op=0 eg=0 ed=0 wo=0
  for n in $(ls -1 "$QD" 2>/dev/null | sed -n 's/^q-\([0-9][0-9]*\)\.md$/\1/p' | sort -n); do
    q="$QD/q-$n.md"
    IFS=$'\t' read -r st tier author <<<"$(team_q_state "$q")"
    echo "q-$n $(field "$q" role) $(field "$q" kind) tier=$tier author=$author state=$st"
    total=$((total + 1))
    case "$st:$tier" in
      sent:1|recorded:1) t1=$((t1 + 1)) ;; sent:2|recorded:2) t2=$((t2 + 1)) ;;
      sent:*|recorded:*) t3=$((t3 + 1)) ;; revoked:*) rv=$((rv + 1)) ;; failed:*) fl=$((fl + 1)) ;;
      pending:*) pd=$((pd + 1)) ;; open:*) op=$((op + 1)) ;; escalating:*) eg=$((eg + 1)) ;;
      escalated:*) ed=$((ed + 1)) ;; waiting-operator:*) wo=$((wo + 1)) ;;
    esac
  done
  echo "total=$total tier1=$t1 tier2=$t2 tier3=$t3 revoked=$rv failed=$fl pending=$pd" \
    "open=$op escalating=$eg escalated=$ed waiting=$wo"
}

cmd_policy() {
  local rel
  for rel in .claude/settings.json .claude/settings.local.json; do
    if [ ! -f "$CLONE/$rel" ]; then echo "missing: $rel"; continue; fi
    jq -r --arg r "$rel" '.permissions.ask[]? | "ask  " + $r + ": " + .' "$CLONE/$rel"
    jq -r --arg r "$rel" '.permissions.deny[]? | "deny  " + $r + ": " + .' "$CLONE/$rel"
  done
}

cmd_unlock() {
  local q pid age
  q="$(qpath "${1:-}")"
  [ -d "$q.lock" ] || die "no lock to remove"
  pid="$(cat "$q.lock/pid" 2>/dev/null || true)"
  [[ "$pid" =~ ^[0-9]+$ ]] || die "lock is not stale — no pid recorded"
  ! kill -0 "$pid" 2>/dev/null || die "lock is not stale — pid $pid is alive"
  age=$(( $(date +%s) - $(stat -f %m "$q.lock") ))
  [ "$age" -gt 10 ] || die "lock is not stale — created ${age}s ago"
  rm -rf "$q.lock"
  echo "removed stale lock of $1 (pid $pid dead)"
}

case "$CMD" in
  open) cmd_open "$@" ;;
  answer) cmd_answer "$@" ;;
  revoke) cmd_revoke "$@" ;;
  show) [ $# = 1 ] || usage; q="$(qpath "$1")"; [ -f "$q" ] || die "$1 not found"; cat "$q" ;;
  list) cmd_list ;;
  policy) cmd_policy ;;
  screen) [ $# = 1 ] || usage; team_check_name "$1" || exit 2; pane "$1" 25 ;;
  unlock) [ $# = 1 ] || usage; cmd_unlock "$1" ;;
  *) usage ;;
esac
