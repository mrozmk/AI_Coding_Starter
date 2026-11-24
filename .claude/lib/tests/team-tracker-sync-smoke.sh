#!/usr/bin/env bash
# Offline smoke for the backlog → GitHub sync: the adapter's sync ops (create-issue, markers,
# sub-issues, add-sub-issue, project-add) and github-sync.mjs on top of them. `gh` is the shared
# stub (gh-stub.sh): every call is logged, so "no write call" is checked against the log.
# Bash 3.2 compatible (macOS /bin/bash) — run it with /bin/bash, like the harness does.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/team-smoke-lib.sh"
smoke_init

TRK="bash .claude/lib/team-tracker.sh"
SYNC="node .claude/lib/github-sync.mjs"
P="$MAIN/.claude/project-profile.json"
B="$MAIN/.agents/backlog.md"
GH_DIR="$WORK/gh"
GH_LOG="$WORK/gh.log"
export GH_DIR GH_LOG
mkdir -p "$GH_DIR"
. "$(dirname "${BASH_SOURCE[0]}")/gh-stub.sh"
gh_stub_install
cp "$SRC/.claude/lib/github-sync.mjs" "$SRC/.claude/lib/backlog-check.mjs" "$SRC/.claude/lib/yaml-subset.mjs" \
  "$MAIN/.claude/lib/"

TOP_GH='{repo: "owner/repo", project_owner: "owner", project_number: 2, project_id: "PVT_x",
  status_field_id: "PVTSSF_x", status_options: {started: "opt-started", delivered: "opt-delivered"}}'
solo() { jq -n "{schema: 1, tracker: \"github\", github: $TOP_GH} | ${1:-.}" > "$P"; }
writes() { grep -cE 'issue create|-X POST|item-add|item-edit' "$GH_LOG" | tr -d ' '; }
creates() { grep -c 'issue create' "$GH_LOG" | tr -d ' '; }
fx_reset() {
  echo '[]' > "$GH_DIR/issues.json"; echo '[]' > "$GH_DIR/comments.json"
  echo '[]' > "$GH_DIR/items.json"; rm -f "$GH_DIR"/subs-*.json
  jq -n '{fields: [{id: "PVTSSF_x", name: "Status", options: [{id: "opt-started", name: "In Progress"},
    {id: "opt-delivered", name: "Delivered"}]}]}' > "$GH_DIR/fields.json"
  : > "$GH_LOG"
}
issue() {  # issue <n> <body> — append an issue to the stub's list
  jq --argjson n "$1" --arg b "$2" '. + [{number: $n, title: "x", body: $b}]' "$GH_DIR/issues.json" \
    > "$GH_DIR/t" && mv "$GH_DIR/t" "$GH_DIR/issues.json"
}
E0F="$MAIN/.agents/backlog/E0-foundation.md"
backlog() {  # backlog [E0-2 Jira cell] [structure] — the minimal valid backlog (+ its Epic file) the checker accepts
  # `structure`: **Detail:** structure, and E0-2 has a Summary line but no criterion yet.
  local detail=full
  [ "${2:-}" = structure ] && detail=structure
  mkdir -p "$MAIN/.agents" "$MAIN/docs"
  rm -rf "$MAIN/.agents/backlog"
  mkdir -p "$MAIN/.agents/backlog"
  printf '# PRD — Demo\n\n## 3. Goals\n- **G-1** — ship\n' > "$MAIN/docs/PRD.md"
  cat > "$B" <<EOF
# Demo — Backlog (Epics + Tasks)
**Date:** 2026-10-10 · **Source PRD:** \`docs/PRD.md\` · **Jira namespace:** \`demo\` · **Sizes:** M=4 · H=8 · XH=16 points (currency, not hours) · **Detail:** $detail

## Epic map
| Epic | Title | Outcome | Key assumption | Pts | Depends on | Jira |
|------|-------|---------|----------------|-----|------------|------|
| E0 | Foundation | skeleton | monolith is enough | 12 | — | — |

**E0** — appetite: small · cut first: nothing

## Task table
| ID | Epic | Task | Type | Size | Pts | Depends on | Scope | Node | Traces | Status | Jira | Ref |
|----|------|------|------|------|-----|------------|-------|------|--------|--------|------|-----|
| E0-1 | E0 | Project scaffold | tech | H | 8 | — | CORE | — | — | TODO | — | — |
| E0-2 | E0 | Auth skeleton | tech | M | 4 | E0-1 | CORE | — | — | TODO | ${1:-—} | — |

## Story map
<!-- storymap:begin -->
x
<!-- storymap:end -->

## External blockers
- none

## Open questions
- none

## Consciously out of scope
- none
EOF
  local e02='### Acceptance criteria
- **E0-2.AC1** — Given no session, when a protected route is hit, then 401.'
  [ "$detail" = structure ] && e02='**Summary:** a protected route refuses a caller without a session.'
  cat > "$E0F" <<EOF
# E0 — Foundation

## E0-1 — Project scaffold
### Acceptance criteria
- **E0-1.AC1** — Given a clean clone, when tests run, then they pass.

## E0-2 — Auth skeleton
$e02
EOF
}
cell() {  # cell <row id> — that row's Jira cell (Epic: last column; Task: second to last)
  awk -F'|' -v id="$1" '{ k = $2; gsub(/ /, "", k) }
    k == id { c = (id ~ /-/) ? $(NF-2) : $(NF-1); gsub(/^ +| +$/, "", c); print c }' "$B"
}

# ================================================================================================
# (1) adapter: markers / create-issue — a marker on ANY line, full enumeration, ambiguity refused
# ================================================================================================
solo; fx_reset
issue 5 $'body\n<!-- backlog-hash:aaa -->\n<!-- backlog:demo:E0-1 -->\na human note added later'
issue 6 $'<!-- backlog:demo:E0 -->'
run "$MAIN" $TRK markers --prefix '<!-- backlog:demo:' --out "$WORK/m.json"
expect 0 "markers=2" "markers finds a marker that is not the last line"
jq -e '.["<!-- backlog:demo:E0-1 -->"] == [{number: 5, hash: "aaa"}]
  and .["<!-- backlog:demo:E0 -->"] == [{number: 6, hash: null}]' "$WORK/m.json" >/dev/null \
  || fail "markers output shape"
jq -n '[range(40)] | map({number: (700 + .), title: "y", body: "z"})' > "$GH_DIR/t"
jq -s 'add' "$GH_DIR/issues.json" "$GH_DIR/t" > "$GH_DIR/t2" && mv "$GH_DIR/t2" "$GH_DIR/issues.json"
export STUB_GH_PAGE2_FAIL=1
rm -f "$WORK/m2.json"
run "$MAIN" $TRK markers --prefix '<!-- backlog:demo:' --out "$WORK/m2.json"
unset STUB_GH_PAGE2_FAIL
expect 4 "recoverable" "a failed page 2 is recoverable, never a short marker list"
[ ! -e "$WORK/m2.json" ] || fail "a failed markers run still wrote its output"

printf 'text\n<!-- backlog:demo:E0-1 -->\n' > "$WORK/b1.md"
run "$MAIN" $TRK create-issue --marker '<!-- backlog:demo:E0-1 -->' --title t --body-file "$WORK/b1.md"
expect 0 "exists 5" "create-issue finds the marker above a human note — no duplicate"
grep -q "^project: \(added\|exists\)$" "$WORK/out" || fail "create-issue printed no project line ($(cat "$WORK/out"))"
echo "PASS create-issue finds the marker above a human note — no duplicate"
printf 'no marker here\n' > "$WORK/b2.md"
run "$MAIN" $TRK create-issue --marker '<!-- backlog:demo:E0-9 -->' --title t --body-file "$WORK/b2.md"
expect 2 "must be a line of" "create-issue refuses a body without its marker"
issue 7 $'<!-- backlog:demo:E0 -->'
printf '<!-- backlog:demo:E0 -->\n' > "$WORK/b3.md"
run "$MAIN" $TRK create-issue --marker '<!-- backlog:demo:E0 -->' --title t --body-file "$WORK/b3.md"
expect 4 "matches 2 issues" "two issues with one marker are refused, never one picked"
[ "$(creates)" = 0 ] || fail "create-issue created despite a hit"

# ================================================================================================
# (2) adapter: sub-issues / add-sub-issue / project-add — idempotent over the full list
# ================================================================================================
fx_reset
issue 5 'a task'; issue 6 'an epic'
run "$MAIN" $TRK add-sub-issue 6 5
expect 0 "added" "a missing sub-issue is added"
jq -e '. == [{number: 5}]' "$GH_DIR/subs-6.json" >/dev/null || fail "the stub did not record the sub-issue"
run "$MAIN" $TRK add-sub-issue 6 5
expect 0 "exists" "a second add-sub-issue is a no-op"
[ "$(grep -c -- '-X POST' "$GH_LOG" | tr -d ' ')" = 1 ] || fail "the second add-sub-issue posted"
echo "PASS a second add-sub-issue is a no-op"
jq -n '[range(35)] | map({number: (900 + .)})' > "$GH_DIR/subs-8.json"
export STUB_GH_PAGE2_FAIL=1
run "$MAIN" $TRK add-sub-issue 8 5
unset STUB_GH_PAGE2_FAIL
expect 4 "recoverable" "a partial sub-issue list is recoverable — never 'not there, add it'"
[ "$(grep -c -- '-X POST' "$GH_LOG" | tr -d ' ')" = 1 ] || fail "a partial list still posted"
run "$MAIN" $TRK sub-issues 8 --out "$WORK/s8.json"
expect 0 "sub_issues=35" "sub-issues reads every page"

run "$MAIN" $TRK project-add 5
expect 0 "added" "an issue off the board is added"
run "$MAIN" $TRK project-add 5
expect 0 "exists" "a second project-add is a no-op"
[ "$(grep -c 'item-add' "$GH_LOG" | tr -d ' ')" = 1 ] || fail "the second project-add added again"
jq '. + [{id: "dup", status: null, content: {type: "Issue", number: 5, repository: "owner/repo"}}]' \
  "$GH_DIR/items.json" > "$GH_DIR/t" && mv "$GH_DIR/t" "$GH_DIR/items.json"
run "$MAIN" $TRK project-add 5
expect 4 "refusing to guess" "two board items for one issue are refused"
solo '.github = {repo: "owner/repo"}'
: > "$GH_LOG"
run "$MAIN" $TRK project-add 5
expect 0 "skipped (no project)" "project-add without a Project skips"
[ ! -s "$GH_LOG" ] || fail "project-add without a Project called gh"

# ================================================================================================
# (3) github-sync: --preview and an unconfirmed --apply write nothing — not even a found orphan
# ================================================================================================
solo; fx_reset; backlog
issue 40 $'old body\n<!-- backlog:demo:E0-1 -->'   # an orphan: created by a crashed run, cell empty
cp "$B" "$WORK/backlog.before"
run "$MAIN" $SYNC --preview
expect 0 "nothing written" "preview runs"
has "E0 create" "$WORK/out" || fail "preview does not plan the Epic"
has "E0-1 recover #40" "$WORK/out" || fail "preview does not show the orphan as a recover"
has "<!-- backlog:demo:E0-2 -->" "$WORK/out" || fail "preview does not show the exact body with its marker"
has "E0-2.AC1" "$WORK/out" || fail "preview body lacks the AC"
[ "$(writes)" = 0 ] || { sed 's/^/  | /' "$GH_LOG"; fail "preview made a write call"; }
cmp -s "$B" "$WORK/backlog.before" || fail "preview changed the backlog"
: > "$GH_LOG"
run "$MAIN" $SYNC --epic E0 --apply
expect 2 "confirmation required" "apply without --yes is refused"
[ ! -s "$GH_LOG" ] || fail "an unconfirmed apply called gh at all"
cmp -s "$B" "$WORK/backlog.before" || fail "an unconfirmed apply wrote the recovered cell"
run "$MAIN" $SYNC --apply --yes
expect 2 "needs --epic" "apply without an Epic group is refused"

# ================================================================================================
# (4) github-sync --apply --yes: create, recover, link, board, verify — then a second run is a no-op
# ================================================================================================
: > "$GH_LOG"
run "$MAIN" $SYNC --epic E0 --apply --yes
expect 0 "apply E0: 2 created · 1 recovered · 3 verified" "apply creates the Epic and E0-2, recovers E0-1"
E0N="$(cell E0)"; T1="$(cell E0-1)"; T2="$(cell E0-2)"
[ "$T1" = "#40" ] || fail "the orphan was not recovered into the cell (got '$T1')"
[[ "$E0N" =~ ^#[0-9]+$ && "$T2" =~ ^#[0-9]+$ ]] || fail "cells not verified: E0=$E0N E0-2=$T2"
jq -e --argjson a 40 --argjson b "${T2#\#}" '[.[].number] | sort == ([$a, $b] | sort)' \
  "$GH_DIR/subs-${E0N#\#}.json" >/dev/null || fail "the Tasks are not sub-issues of the Epic"
[ "$(jq 'length' "$GH_DIR/items.json")" = 3 ] || fail "not every row is on the board"
jq -e --arg t2 "${T2#\#}" '[.[] | select(.number == ($t2 | tonumber))][0].body
  | test("Depends on:\\*\\* #40 \\(E0-1\\)")' "$GH_DIR/issues.json" >/dev/null \
  || fail "E0-2's body does not name its dependency's issue number"
[ "$(creates)" = 2 ] || fail "expected 2 creates, got $(creates)"
[ "$(grep -c 'item-add' "$GH_LOG" | tr -d ' ')" = 3 ] || fail "expected one item-add per row (2 by create, 1 recovered), got $(grep -c 'item-add' "$GH_LOG")"
[ "$(grep -c 'project: (added by create)' "$WORK/out" | tr -d ' ')" = 2 ] || fail "the created rows were added to the board again"
cp "$B" "$WORK/backlog.synced"
: > "$GH_LOG"
run "$MAIN" $SYNC --epic E0 --apply --yes
expect 0 "0 created · 0 recovered · 3 verified" "a second apply is a no-op"
[ "$(writes)" = 0 ] || { sed 's/^/  | /' "$GH_LOG"; fail "a second apply wrote to GitHub"; }
cmp -s "$B" "$WORK/backlog.synced" || fail "a second apply changed the backlog"

# A backlog edit after the sync is reported, never pushed — the criterion lives in the Epic file.
sed -i.bak 's/then 401\./then 401 with a reason./' "$E0F" && rm -f "$E0F.bak"
run "$MAIN" $SYNC --preview
expect 0 "2 changed since sync" "an AC edit after the sync is reported"
has "E0-2 synced ${T2} [changed since sync]" "$WORK/out" || fail "the edited row is not named"
# E0-1 is the recovered orphan, whose body was never this sync's; the Epic is untouched.
grep -qx -- "- E0 synced ${E0N}" "$WORK/out" || fail "the unchanged Epic is flagged"

# ================================================================================================
# (5) refusals before any write: identity conflict, ambiguity, capacity, another tracker's key
# ================================================================================================
fx_reset; backlog '#999'
issue 41 $'<!-- backlog:demo:E0-2 -->'
run "$MAIN" $SYNC --epic E0 --apply --yes
expect 1 "the cell says #999 but the marker is on #41" "a cell/marker conflict stops the group"
[ "$(writes)" = 0 ] || fail "a conflict still wrote"

fx_reset; backlog
issue 42 $'<!-- backlog:demo:E0-1 -->'; issue 43 $'<!-- backlog:demo:E0-1 -->'
run "$MAIN" $SYNC --preview
expect 1 "resolve the duplicate by hand" "a marker on two issues stops the group"

fx_reset; backlog
issue 44 $'<!-- backlog:demo:E0 -->'
jq -n '[range(99)] | map({number: (800 + .)})' > "$GH_DIR/subs-44.json"
run "$MAIN" $SYNC --epic E0 --apply --yes
expect 1 "GitHub allows 100 per parent" "the sub-issue limit is checked before any write"
[ "$(writes)" = 0 ] || fail "the capacity refusal still wrote"

fx_reset; backlog 'ABC-7'
run "$MAIN" $SYNC --preview
expect 1 "another tracker's" "a Jira key in the cell is refused"

solo '.tracker = "jira"'; fx_reset; backlog
run "$MAIN" $SYNC --preview
expect 3 "needs tracker=github" "tracker=jira is refused"

# ================================================================================================
# (6) Detail: structure — a Task with only its Summary line stops the sync before any create
# ================================================================================================
solo; fx_reset; backlog '' structure
run "$MAIN" node .claude/lib/backlog-check.mjs
expect 0 "" "the checker accepts a structure backlog with a Summary-only Task"
cp "$B" "$WORK/backlog.before"
run "$MAIN" $SYNC --preview
expect 1 "Task(s) E0-2 have no acceptance criteria yet — run /setup:delivery-plan" "preview of a criterion-less Task is refused"
run "$MAIN" $SYNC --epic E0 --apply --yes
expect 1 "the sync is create-only: an issue created now would never get them" "apply of a criterion-less Task is refused"
[ "$(creates)" = 0 ] || fail "a criterion-less Task still created an issue"
[ "$(writes)" = 0 ] || { sed 's/^/  | /' "$GH_LOG"; fail "the criteria guard still wrote to GitHub"; }
cmp -s "$B" "$WORK/backlog.before" || fail "the criteria guard changed the backlog"

# ================================================================================================
# (7) adapter: which / add-labels / set-status --name Todo (/create-task)
# ================================================================================================
solo; fx_reset
run "$MAIN" $TRK which
expect 0 "tracker=github" "which: solo github profile"
has "repo=owner/repo" "$WORK/out" || fail "which: solo github profile — no repo line"
has "project=2" "$WORK/out" || fail "which: solo github profile — no project line"
[ "$(writes)" = 0 ] || fail "which made a write call"
! grep -q . "$GH_LOG" || fail "which called gh"
echo "PASS which: solo github profile"

solo 'del(.github.project_owner, .github.project_number, .github.project_id, .github.status_field_id, .github.status_options)'
run "$MAIN" $TRK which
expect 0 "project=none" "which: solo github without a Project"
echo "PASS which: solo github without a Project"

jq -n '{schema: 1, tracker: "jira"}' > "$P"
run "$MAIN" $TRK which
expect 0 "tracker=jira" "which: jira answers instead of exit 3"
echo "PASS which: jira answers instead of exit 3"

rm -f "$P"
run "$MAIN" $TRK which
expect 0 "tracker=none" "which: no profile is none"
echo "PASS which: no profile is none"
solo
run "$MAIN" $TRK which extra
expect 2 "which takes no arguments" "which: refuses arguments"
echo "PASS which: refuses arguments"

solo; fx_reset; issue 5 'body'
run "$MAIN" $TRK add-labels 5 bug enhancement
expect 0 "labeled bug,enhancement" "add-labels: labels the issue"
grep -q 'issue edit 5 --repo owner/repo --add-label bug,enhancement' "$GH_LOG" \
  || fail "add-labels: labels the issue — no gh issue edit call logged"
jq -e '[.[] | select(.number == 5)][0].labels == ["bug", "enhancement"]' "$GH_DIR/issues.json" \
  >/dev/null || fail "add-labels: labels the issue — the stub issue lacks the labels"
echo "PASS add-labels: labels the issue"

echo '["bug"]' > "$GH_DIR/labels.json"
run "$MAIN" $TRK add-labels 5 nosuch
expect 4 "recoverable" "add-labels: a missing label is recoverable"
rm -f "$GH_DIR/labels.json"
echo "PASS add-labels: a missing label is recoverable"

run "$MAIN" $TRK add-labels 5
expect 2 "add-labels needs" "add-labels: needs a label"
echo "PASS add-labels: needs a label"
run "$MAIN" $TRK add-labels 5 'a,b'
expect 2 "comma" "add-labels: refuses a comma in a label"
echo "PASS add-labels: refuses a comma in a label"

jq -n '{schema: 1, tracker: "jira"}' > "$P"
run "$MAIN" $TRK add-labels 5 bug
expect 3 "jira runs through the session's MCP" "add-labels: jira is exit 3"
echo "PASS add-labels: jira is exit 3"
jq -n '{schema: 1, tracker: "none"}' > "$P"
run "$MAIN" $TRK add-labels 5 bug
expect 0 "skipped (tracker=none)" "add-labels: none is skipped"
echo "PASS add-labels: none is skipped"

solo; fx_reset; issue 5 'body'
echo '[{"id": "item-5", "status": null, "content": {"type": "Issue", "number": 5, "repository": "owner/repo"}}]' \
  > "$GH_DIR/items.json"
jq -n '{fields: [{id: "PVTSSF_x", name: "Status", options: [{id: "opt-started", name: "In Progress"},
  {id: "opt-delivered", name: "Delivered"}, {id: "opt-todo", name: "Todo"}]}]}' > "$GH_DIR/fields.json"
run "$MAIN" $TRK set-status 5 --name Todo
expect 0 "set Todo" "set-status --name Todo: Todo in a later board position"
jq -e '.[0].status == "Todo"' "$GH_DIR/items.json" >/dev/null \
  || fail "set-status --name Todo: Todo in a later board position — the item has no Todo"
echo "PASS set-status --name Todo: Todo in a later board position"

jq '.[0].status = null' "$GH_DIR/items.json" > "$GH_DIR/t" && mv "$GH_DIR/t" "$GH_DIR/items.json"
jq -n '{fields: [{id: "PVTSSF_x", name: "Status", options: [{id: "opt-started", name: "In Progress"},
  {id: "opt-delivered", name: "Delivered"}]}]}' > "$GH_DIR/fields.json"
run "$MAIN" $TRK set-status 5 --name Todo
expect 4 "is not in field" "set-status --name Todo: a board without Todo is exit 4"
echo "PASS set-status --name Todo: a board without Todo is exit 4"

solo; fx_reset
T7='Fix `x` for $HOME "y"'
printf 'text\n<!-- create-task:2026-11-24:x:abc123 -->\n' > "$WORK/b7.md"
run "$MAIN" $TRK create-issue --marker '<!-- create-task:2026-11-24:x:abc123 -->' --title "$T7" --body-file "$WORK/b7.md"
expect 0 "created" "create-issue: a title with backticks, dollar and quotes is stored verbatim"
jq -e --arg t "$T7" '.[-1].title == $t' "$GH_DIR/issues.json" >/dev/null \
  || fail "create-issue: a title with backticks, dollar and quotes is stored verbatim — got $(jq -r '.[-1].title' "$GH_DIR/issues.json")"
echo "PASS create-issue: a title with backticks, dollar and quotes is stored verbatim"

echo "team-tracker-sync-smoke: OK"
