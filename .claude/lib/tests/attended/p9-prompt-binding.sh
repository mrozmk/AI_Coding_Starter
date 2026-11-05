#!/usr/bin/env bash
# Attended acceptance check E21 — prompt binding. The Operator runs it himself, in the scratch
# checkout, as `! bash .claude/lib/tests/attended/p9-prompt-binding.sh`; no agent runs it.
# A planner asks permission for a harmless `echo p9-binding` (an ask rule in the scratch clone's
# local settings). The q is opened, then the Operator resizes the attached window so everything
# above the prompt re-renders; the answer must still bind (content-only fingerprint) and land once.
# It never types into a pane. Prints one evidence line at the end.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/p9-common.sh"
T=p9b
trap 'p9_cleanup $T' EXIT
clone="$(p9_provision "$T" 'Run exactly this Bash command once: echo p9-binding. Then stop and wait. Do nothing else.')"
printf '{"permissions":{"ask":["Bash(echo p9-binding*)"]}}\n' > "$clone/.claude/settings.local.json"
p9_start "$T"
printf 'Attach in a separate window: tmux attach -t %s-planner\n' "$T"
read -r -p "Is the permission prompt for \"echo p9-binding\" visible? [enter = yes] " _

q="$(bash .claude/lib/team-question.sh "$T" open planner --kind permission --summary "P9 attended: echo p9-binding" | awk 'NR==1{print $1}')"
[ -n "$q" ] || p9_die "open gave no q id"
fp1="$(p9_field "$T" "$q" fingerprint)"
read -r -p "Now resize the attached window (the text above the prompt re-renders, the prompt stays). Done? [enter] " _

# The answer's last line is "q-<n> state=<state> — <delivery>".
last="$(bash .claude/lib/team-question.sh "$T" answer "$q" --tier 3 --author operator --why "P9 attended" --send yes | tail -n 1)"
printf '%s\n' "$last"
st="$(printf '%s\n' "$last" | sed -n 's/.* state=\([^ ]*\).*/\1/p')"
c="$(p9_field "$T" "$q" confirmed)"; fp2="$(p9_field "$T" "$q" fingerprint)"
again="$(bash .claude/lib/team-question.sh "$T" answer "$q" --tier 3 --author operator --why "P9 attended" --send yes 2>&1 | tail -n 1)"
printf 'state=%s confirmed=%s fp equal=%s second answer: %s\n' "$st" "$c" "$([ "$fp1" = "$fp2" ] && echo yes || echo no)" "$again"

ok=FAIL
case "$c" in yes*) [ "$fp1" = "$fp2" ] && [[ "$again" == *"already answered"* ]] && ok=PASS ;; esac
printf 'E21 prompt-binding | attended | p9-prompt-binding.sh (resize, yes, yes again) | %s: confirmed=%s, fingerprint equal=%s, second: %s | %s | %s\n' \
  "$ok" "$c" "$([ "$fp1" = "$fp2" ] && echo yes || echo no)" "$again" "$(p9_utc)" "$P9_SHA"
