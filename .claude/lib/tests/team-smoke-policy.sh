#!/usr/bin/env bash
# Permission classes are project policy and off until the profile enables them: the two readers of
# the predicate (team_prompt_classes.py class_on / switches, team-lib.sh team_class_on) agree on
# every profile shape, and the runtime switch can only narrow an enabled class, never widen.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/team-smoke-lib.sh"
smoke_init
L="$MAIN/.claude/lib"
P="$MAIN/.claude/project-profile.json"; cp "$P" "$WORK/prof.bak"
W="$MAIN/.agents/team/watch/state.json"
prof() { jq "$1" "$WORK/prof.bak" > "$P"; }
both() {  # both <class> <python switches word> <bash on|off> <label>
  local py sh=off
  py="$(python3 -I "$L/team_prompt_classes.py" switches "$MAIN" | tr ' ' '\n' | sed -n "s/^$1=//p")"
  (. "$L/team-lib.sh"; team_class_on "$MAIN" "$1") && sh=on
  [ "$py:$sh" = "$2:$3" ] || fail "$4: python $py, bash $sh, expected $2/$3"
}
rm -f "$W"

prof 'del(.teams.policy)'
for c in merge-line allow-offline add-ask prod-diagnose; do both "$c" disabled off "absent policy: $c"; done
prof '.teams.policy.classes.merge_line = {enabled: true}'
both merge-line on on "enabled, no state file"
both allow-offline disabled off "a sibling class stays off"
prof '.teams.policy.classes.merge_line = {enabled: "yes"}'; both merge-line disabled off "enabled must be exactly true"
prof '.teams.policy.classes.merge_line = {enabled: false}'; both merge-line disabled off "enabled false"
prof '.teams.policy.classes.prod_diagnose = {enabled: true}'
both prod-diagnose disabled off "prod-diagnose without dir/privileged"
prof '.teams.policy.classes.prod_diagnose = {enabled: true, dir: "scripts/ops/", privileged: "write\\.sh"}'
both prod-diagnose on on "prod-diagnose configured"
prof '.teams.policy.classes.prod_diagnose = {dir: "scripts/ops/", privileged: "write\\.sh"}'
both prod-diagnose disabled off "prod-diagnose configured but not enabled"
# the switch narrows an enabled class and never widens a disabled one
prof '.teams.policy.classes = {merge_line: {enabled: true}}'
mkdir -p "$(dirname "$W")"; echo '{"classes": {"merge-line": "off", "add-ask": "on"}}' > "$W"
both merge-line off off "enabled + switched off"
both add-ask disabled off "switched on but not enabled"
echo 'not json' > "$W"; both merge-line off off "enabled + unreadable state"
# Ticket labels are policy too: the contracts the agents follow name no label of their own and no
# fixed recommendation line in another language; they defer to teams.policy.tickets.
for f in "$SRC/.agents/reference/team-decision-model.md" "$SRC/.agents/reference/team-mode.md"; do
  ! grep -qE 'auto-created|Utworzony' "$f" || { echo "team-smoke-policy: FAIL — $f orders a fixed ticket label"; exit 1; }
done
grep -qF 'teams.policy.tickets.recommendation_line' "$SRC/.agents/reference/team-decision-model.md" \
  || { echo "team-smoke-policy: FAIL — the ticket rule does not defer to teams.policy.tickets"; exit 1; }
# PR-host policy: self-approval is opt-in, and the --bypass-policy the command forbids is denied.
jq -e '.permissions.deny | any(. == "Bash(az repos pr * --bypass-policy*)")' "$SRC/.claude/settings.json" >/dev/null \
  || { echo "team-smoke-policy: FAIL — settings.json does not deny --bypass-policy"; exit 1; }
grep -qF 'teams.policy.pr.self_approve is off' "$SRC/.claude/commands/pr-merge.md" \
  || { echo "team-smoke-policy: FAIL — /pr-merge self-approves without the profile switch"; exit 1; }
# The Branch model the merge-line class reads (team_prompt_classes.branch_model) is parsed from a
# block filled from the real CLAUDE-template.md, whose first line combines Preset · Trunk ·
# Integration, and from the one-field-per-line layout; a blockquote naming a field is ignored.
BM="$WORK/bm"; mkdir -p "$BM"
bm() {  # bm → the parsed model as compact JSON
  python3 -I -c 'import json, sys; sys.path.insert(0, sys.argv[1]); import team_prompt_classes as t
print(json.dumps(t.branch_model(sys.argv[2]), sort_keys=True, separators=(",", ":")))' "$L" "$BM"
}
WANT='{"Integration":["develop"],"Maintenance":["rc/1"],"Protected":["main","develop","old/x"],"Retired":["old/x"]}'
{ echo '> A note that names **Integration:** `wrong` is not the field.'
  sed -n '/^### Branch model$/,/^## /p' "$SRC/.claude/templates/CLAUDE-template.md" \
    | sed -e '1,/{branch}/s/`{branch}`/`main`/' -e 's/`{branch}`/`develop`/' \
      -e 's/^\*\*Protected:\*\* .*/**Protected:** `main`, `develop`, `old\/x`/' \
      -e 's/^\*\*Maintenance:\*\* .*/**Maintenance:** `rc\/1` — the 1.x line/' \
      -e 's/^\*\*Retired:\*\* .*/**Retired:** `old\/x` — merged, locked/'
} > "$BM/CLAUDE.md"
grep -qF '· **Integration:** `develop`' "$BM/CLAUDE.md" \
  || { echo "team-smoke-policy: FAIL — the template's combined Integration line was not filled"; exit 1; }
[ "$(bm)" = "$WANT" ] || { echo "team-smoke-policy: FAIL — template layout parsed as $(bm)"; exit 1; }
printf '%s\n' '**Trunk:** `main`' '**Integration:** `develop`' '**Maintenance:** `rc/1` — the 1.x line' \
  '**Retired:** `old/x` — merged' '**Protected:** `main`, `develop`, `old/x`' > "$BM/CLAUDE.md"
[ "$(bm)" = "$WANT" ] || { echo "team-smoke-policy: FAIL — one-field layout parsed as $(bm)"; exit 1; }
printf '%s\n' '**Preset:** gitflow · **Trunk:** `main` · **Integration:** `develop`' \
  '**Protected:** `main`, `develop`' > "$BM/CLAUDE.md"
[ "$(bm)" = '{"Integration":["develop"],"Maintenance":[],"Protected":["main","develop"],"Retired":[]}' ] \
  || { echo "team-smoke-policy: FAIL — no Maintenance/Retired lines parsed as $(bm)"; exit 1; }
echo "team-smoke-policy: OK"
