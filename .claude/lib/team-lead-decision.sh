#!/usr/bin/env bash
# Pending human decisions of the per-run TeamLead: runs/<run>/decisions/d-<n>.md. Sourced by
# team-lead.sh after resolve (TD, RUN, MAIN, LIB set), never executed. Bash 3.2.
#   decision open <team> --source <run file|attention:<n>> --question "<text>" [--options "<a|b>"]
#     [--recommend "<text>"] [--notify human_decision|abandon_decision] [--gate spec|plan]
#   decision open <team> --request req-<n>      (the runner's human-only request: binding copied)
#   decision answer <team> d-<n> --text "<Operator answer>" [--outcome continue|close|more-revise|approve]
#   decision withdraw <team> d-<n> --why "<line>"     decision list <team> [--pending]
# open writes the file (status pending), then the escalate verdict with --notify, so the runner
# notifies the Operator once. answer asks for a human: from a terminal (a TTY, the id typed to
# confirm), or from the TeamLead window, where the lead's own transcript must hold a typed Operator
# message (not a doorbell, after created_at) containing the answer text. Both raise the bar; neither
# is proof (team-lead.md §7, "Limit of the human binding").

dfm() { sed -n '/^---$/,/^---$/p' "$1" | sed -n "s/^$2: *//p" | head -n 1; }
dfm_set() {  # dfm_set <file> <key> <value> — replace or add one frontmatter key, atomically
  awk -v k="$2" -v v="$3" '/^---$/ { n++; if (n == 2 && !done) print k ": " v; print; next }
    n == 1 && index($0, k ": ") == 1 { print k ": " v; done = 1; next } { print }' "$1" > "$1.tmp"
  mv "$1.tmp" "$1"
}
d_bad() { echo "error: $2" >&2; exit "$1"; }
d_file() {  # d_file <d-n> → path, or exit 2/4
  [[ "$1" =~ ^d-[0-9]+$ ]] || d_bad 2 "decision id must be d-<n>"
  [ -f "$DD/$1.md" ] || d_bad 4 "no decision $1 in runs/$RUN/decisions/"
  echo "$DD/$1.md"
}
one_line() { [ -n "$1" ] && [[ "$1" != *$'\n'* ]]; }

decision_open() {
  local src="" q="" opts="" rec="" notify=human_decision gate="" req="" n f tmp v rel bind=""
  while [ $# -gt 0 ]; do
    [ $# -ge 2 ] || usage
    case "$1" in
      --source) src="$2" ;; --question) q="$2" ;; --options) opts="$2" ;; --recommend) rec="$2" ;;
      --notify) notify="$2" ;; --gate) gate="$2" ;; --request) req="$2" ;; *) usage ;;
    esac
    shift 2
  done
  team_lead_caller || d_bad 3 "only this run's TeamLead opens decisions"
  case "$notify" in human_decision|abandon_decision) ;; *) d_bad 2 "--notify human_decision|abandon_decision" ;; esac
  case "$gate" in ""|spec|plan) ;; *) d_bad 2 "--gate spec|plan" ;; esac
  if [ -n "$req" ]; then
    [[ "$req" =~ ^req-[0-9]+$ ]] && [ -f "$DD/$req.json" ] || d_bad 4 "no request $req in runs/$RUN/decisions/"
    src="decisions/$req.json"
    [ -n "$q" ] || q="$(jq -r '"\(.role): \(.tool) \(.command)"' "$DD/$req.json")"
    bind="$(jq -r '.binding // {} | to_entries[] | "bind_\(.key): \(.value)"' "$DD/$req.json")"
  fi
  [ -n "$src" ] && one_line "$q" || d_bad 2 "decision open needs --source and a one-line --question"
  mkdir -p "$DD"
  n="$(ls "$DD" 2>/dev/null | sed -n 's/^d-\([0-9]*\)\.md$/\1/p' | sort -n | tail -n 1)"
  n=$(( ${n:-0} + 1 )); f="$DD/d-$n.md"; tmp="$DD/.d-$n.md.tmp"
  { echo "---"; echo "id: d-$n"; echo "status: pending"
    echo "stage: $(jq -r '.role // "-"' "$TD/session.json" 2>/dev/null || echo -)"
    echo "attempt: $(jq -r '.attempt // "-"' "$TD/session.json" 2>/dev/null || echo -)"
    echo "source: $src"; echo "created_at: $(team_utc)"; echo "notify: $notify"
    [ -z "$gate" ] || echo "gate: $gate"
    [ -z "$bind" ] || printf '%s\n' "$bind"
    echo "---"; echo "## Question"; echo "$q"
    [ -z "$opts" ] || { echo; echo "## Options"; tr '|' '\n' <<<"$opts" | sed 's/^/- /'; }
    [ -z "$rec" ] || { echo; echo "## Recommendation"; echo "$rec"; }
  } > "$tmp"
  [ ! -e "$f" ] || { rm -f "$tmp"; d_bad 1 "$f already exists"; }
  mv "$tmp" "$f"
  rel="${src#.agents/team/runs/"$RUN"/}"
  v="$( (cd "${TD%/.agents/team}" && bash "$LIB/team-verdict.sh" decision escalate --for "$rel" \
    --ref "$f" --notify "$notify" --message "d-$n: ${q:0:120}") )" \
    || d_bad 1 "decision d-$n written, but its escalate verdict was refused — see above"
  echo "[d-$n] $q"
  echo "file: $f"; echo "verdict: $v"
}

# The Operator's message in the lead's own transcript: a typed user entry after created_at that is
# not a doorbell or a runner line, containing the answer text → its uuid. A message already used as
# another decision's evidence counts again only when it names this decision's id.
d_evidence() {
  local sid t f used=""
  sid="$(jq -r '.session_id // empty' "$TD/teamlead.json" 2>/dev/null)"
  t="$(team_role_transcript "${TD%/.agents/team}" "${sid:--}")"
  [ "$t" != - ] && [ -f "$t" ] || return 1
  for f in "$DD"/d-*.md; do
    [ -f "$f" ] && [ "$f" != "$1" ] || continue
    used="$used $(dfm "$f" answered_via | sed -n 's/^teamlead-window //p')"
  done
  jq -r --arg x "$2" --arg since "$(dfm "$1" created_at)" --arg id "$(basename "$1" .md)" \
    --arg used "$used" '
    ($used | split(" ") | map(select(. != ""))) as $u
    | select(.type == "user" and ((.isMeta // false) | not) and ((.timestamp // "") >= $since))
    | (.uuid // "?") as $uid
    | (.message.content | if type == "string" then .
        elif type == "array" then (map(select(.type == "text") | .text) | join(" ")) else "" end) as $m
    | select($m != "" and ($m | contains($x))
        and ($m | test("^(stop |gate |prompt |inbox: |relaunched: |human-only |\\[team-run\\])") | not))
    | select((($u | index($uid)) == null) or ($m | test("(^|[^A-Za-z0-9-])" + $id + "([^0-9]|$)")))
    | $uid' "$t" 2>/dev/null | tail -n 1
}

decision_answer() {
  local id="${1:-}" text="" outcome="" f how ev c
  [ -n "$id" ] || usage; shift
  while [ $# -gt 0 ]; do
    [ $# -ge 2 ] || usage
    case "$1" in --text) text="$2" ;; --outcome) outcome="$2" ;; *) usage ;; esac
    shift 2
  done
  one_line "$text" || d_bad 2 "decision answer needs a one-line --text"
  case "$outcome" in ""|continue|close|more-revise|approve) ;;
    *) d_bad 2 "--outcome continue|close|more-revise|approve" ;; esac
  f="$(d_file "$id")"
  [ "$(dfm "$f" status)" = pending ] || d_bad 4 "$id is $(dfm "$f" status), not pending — nothing applied"
  if [ -t 0 ] && [ -r /dev/tty ]; then
    printf 'Operator answer to %s: %s\nconfirm by typing %s: ' "$id" "$text" "$id" > /dev/tty
    IFS= read -r c < /dev/tty || c=""
    [ "$c" = "$id" ] || d_bad 7 "not confirmed — nothing applied"
    how="terminal"
  else
    ev="$(d_evidence "$f" "$text")" || ev=""
    [ -n "$ev" ] || d_bad 7 "no Operator message in the TeamLead window after $(dfm "$f" created_at) contains this answer — answer from a terminal, or relay the Operator's own words"
    how="teamlead-window $ev"
  fi
  dfm_set "$f" status answered; dfm_set "$f" answered_at "$(team_utc)"; dfm_set "$f" answered_via "$how"
  [ -z "$outcome" ] || dfm_set "$f" answer_outcome "$outcome"
  printf '\n## Answer\n%s\n' "$text" >> "$f"
  echo "answered: $id${outcome:+ ($outcome)} via ${how%% *}"
}

decision_withdraw() {
  local id="${1:-}" why="" f
  [ -n "$id" ] || usage; shift
  [ $# -eq 2 ] && [ "$1" = --why ] && one_line "$2" || usage; why="$2"
  team_lead_caller || d_bad 3 "only this run's TeamLead withdraws decisions"
  f="$(d_file "$id")"
  [ "$(dfm "$f" status)" = pending ] || d_bad 4 "$id is $(dfm "$f" status), not pending"
  dfm_set "$f" status withdrawn; dfm_set "$f" withdrawn_at "$(team_utc)"
  printf '\n## Withdrawn\n%s\n' "$why" >> "$f"
  echo "withdrawn: $id"
}

decision_list() {
  local f st
  for f in "$DD"/d-*.md; do
    [ -f "$f" ] || continue
    st="$(dfm "$f" status)"
    [ "${1:-}" != --pending ] || [ "$st" = pending ] || continue
    echo "$(dfm "$f" id) $st — $(sed -n '/^## Question$/{n;p;q;}' "$f")"
  done | sort -t- -k2,2n
}

decision_main() {  # decision_main <op> <team> …
  local op="${1:-}"; shift || true
  [ $# -ge 1 ] || usage
  resolve "$1"; shift
  [ -n "$RUN" ] || d_bad 4 "no current run"
  DD="$TD/runs/$RUN/decisions"
  case "$op" in
    open) decision_open "$@" ;; answer) decision_answer "$@" ;;
    withdraw) decision_withdraw "$@" ;; list) decision_list "$@" ;; *) usage ;;
  esac
}
