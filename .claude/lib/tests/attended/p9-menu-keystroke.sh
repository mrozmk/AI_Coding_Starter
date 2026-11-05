#!/usr/bin/env bash
# Attended acceptance check E20 — the menu keystroke path. The Operator runs it himself, in the
# scratch checkout, as `! bash .claude/lib/tests/attended/p9-menu-keystroke.sh`; no agent runs it
# (it needs a human to see the menu). It never types into a pane: every key goes through
# team-question.sh answer, which is the path under test. Prints one evidence line at the end.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/p9-common.sh"
T=p9m
trap 'p9_cleanup $T' EXIT
p9_provision "$T" 'Use the AskUserQuestion tool exactly once with one question "P9 menu one" and three options A, B, C. After the answer, use it once more with one question "P9 menu two" and options D, E, F. Then stop and wait. Do nothing else.' >/dev/null
p9_start "$T"
printf 'Watch the planner: tmux attach -t %s-planner (detach with Ctrl-b d).\n' "$T"
read -r -p "Is the menu \"P9 menu one\" (A/B/C) visible? [enter = yes, Ctrl-C = abort] " _

q1="$(bash .claude/lib/team-question.sh "$T" open planner --kind menu --summary "P9 attended: menu one, A/B/C" | awk 'NR==1{print $1}')"
[ -n "$q1" ] || p9_die "open gave no q id"
bash .claude/lib/team-question.sh "$T" answer "$q1" --tier 3 --author operator --why "P9 attended" --send pick:2
c1="$(p9_field "$T" "$q1" confirmed)"; d1="$(p9_field "$T" "$q1" delivery)"
printf 'q1 %s: delivery=%s confirmed=%s\n' "$q1" "$d1" "$c1"

read -r -p "Is the menu \"P9 menu two\" (D/E/F) visible? [enter = yes] " _
q2="$(bash .claude/lib/team-question.sh "$T" open planner --kind menu --summary "P9 attended: menu two, D/E/F" | awk 'NR==1{print $1}')"
[ -n "$q2" ] || p9_die "open gave no q id"
bash .claude/lib/team-question.sh "$T" answer "$q2" --tier 3 --author operator --why "P9 attended" --text x --send other
c2="$(p9_field "$T" "$q2" confirmed)"; d2="$(p9_field "$T" "$q2" delivery)"
printf 'q2 %s: delivery=%s confirmed=%s\n' "$q2" "$d2" "$c2"
read -r -p "Did the planner receive B for menu one and the Other answer \"x\" for menu two? [y/n] " seen

ok=FAIL
case "$c1:$c2:$seen" in yes*:yes*:y*) ok=PASS ;; esac
printf 'E20 menu-keystroke | attended | p9-menu-keystroke.sh (pick:2, other "x") | %s: q1 confirmed=%s, q2 confirmed=%s, Operator saw B and x: %s | %s | %s\n' \
  "$ok" "$c1" "$c2" "$seen" "$(p9_utc)" "$P9_SHA"
