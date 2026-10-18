#!/usr/bin/env bash
# Offline smoke for team-profile.sh: the values, the clone resolver, and the refusals that must
# happen BEFORE any side effect (clone, branch switch, team.json, tmux).
# Bash 3.2 compatible (macOS /bin/bash) — run it with /bin/bash, like the harness does.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/team-smoke-lib.sh"
smoke_init

P="$MAIN/.claude/project-profile.json"
NEXT="bash .claude/lib/team-next.sh"
WATCH="bash .claude/lib/team-watch.sh"
QUESTION="bash .claude/lib/team-question.sh"
ANSWER="bash .claude/lib/team-answer.sh"
WORKER="bash .claude/lib/worker-next.sh"
MERGE="bash .claude/lib/team-merge-check.sh"

# Profile variants as jq filters over the TT fixture (team-smoke-lib.sh → smoke_profile).
GH_BLOCK='.teams.github = {repo: "owner/repo", project_owner: "owner", project_number: 2,
  project_id: "PVT_x", status_field_id: "PVTSSF_x",
  status_options: {started: "opt-started", delivered: "opt-delivered"}}'
DTS=".teams.tracker = \"github\" | $GH_BLOCK"'| .teams.pr_provider = "none" | .teams.trunk = "main"
  | .teams.branch_types = ["feature", "bugfix", "chore"]
  | .teams.required_tools = ["git", "jq", "tmux", "claude", "codex", "gh", "python3"]
  | .teams.seed_files = [".claude/settings.local.json", ".agents/memory/user-profile.md"]
  | .teams.env_file_required = false | .teams.build_check = "python3 -m pytest -q"
  | .teams.test_gate = "none" | .teams.gates = "manual-mql5"
  | .teams.clone_parent = "~/DTS teams"'

setprofile() { smoke_profile "${1:-.}" > "$P"; }
peek() {  # peek <jq filter> <snippet> — load the profile in $MAIN and run <snippet> with it
  setprofile "$1"
  run "$MAIN" bash -c ". .claude/lib/team-profile.sh; team_profile_load; $2"
}

# ---- (1) the TT profile exports exactly the values the harness used to hardcode ----------------
peek '.' 'printf "%s\n" "$TEAM_TRACKER|$TEAM_KEY_REGEX|$TEAM_PR_PROVIDER|$TEAM_TRUNK" \
  "${TEAM_BRANCH_TYPES[*]}|${TEAM_REQUIRED_TOOLS[*]}|${TEAM_SEED_FILES[*]}" \
  "$TEAM_ENV_REQUIRED|$TEAM_BUILD_CHECK|$TEAM_TEST_GATE|$TEAM_GATES|[$TEAM_CLONE_PARENT]" \
  "$(team_clone_dir alfa)|$(team_base_ref)"'
expect 0 'jira|^[A-Z]+-[0-9]+$|azure-devops|develop-netcore7' "TT profile scalars"
has 'feature bugfix hotfix chore refactor|git jq tmux claude codex az dotnet|.env .claude/settings.local.json .agents/memory/user-profile.md' \
  "$WORK/out" || fail "TT profile lists"
has 'true|dotnet build TakeTask2.API.sln|.claude/lib/test-gate.sh|auto|[]' "$WORK/out" \
  || fail "TT profile gates (and no clone_parent)"
has "$WORK/main-alfa|origin/develop-netcore7" "$WORK/out" || fail "TT clone dir is a repo sibling"

# ---- (2) a DTS-like profile: github keys, clone_parent with `~` and a space ---------------------
peek "$DTS" 'printf "%s\n" "$TEAM_TRACKER|$TEAM_KEY_REGEX|$TEAM_PR_PROVIDER|$TEAM_TRUNK|$TEAM_GATES" \
  "${TEAM_BRANCH_TYPES[*]}|${TEAM_REQUIRED_TOOLS[*]}|${TEAM_SEED_FILES[*]}" \
  "$TEAM_ENV_REQUIRED|$TEAM_BUILD_CHECK|$TEAM_TEST_GATE" "$(team_clone_dir alfa)|$(team_base_ref)"'
expect 0 'github|^[0-9]+$|none|main|manual-mql5' "DTS profile scalars"
has 'feature bugfix chore|git jq tmux claude codex gh python3|.claude/settings.local.json .agents/memory/user-profile.md' \
  "$WORK/out" || fail "DTS profile lists"
has 'false|python3 -m pytest -q|none' "$WORK/out" || fail "DTS profile gates"
has "$HOME/DTS teams/main-alfa|origin/main" "$WORK/out" || fail "clone_parent with ~ and a space"

# ---- (3) require_supported refuses only what has no merge path ---------------------------------
peek "$DTS" 'team_profile_require_supported; echo reached'
expect 2 "error: pr_provider=none is reserved (no merge path)" "DTS with pr_provider=none is refused — on pr_provider, not the tracker"
! has "tracker=github unsupported" "$WORK/out" || fail "tracker github is supported now (2b)"
peek "$DTS | .teams.pr_provider = \"azure-devops\"" 'team_profile_require_supported; echo reached'
expect 0 "reached" "tracker=github is supported in 2b"
peek '.teams.tracker = "none" | .teams.pr_provider = "azure-devops"' \
  'team_profile_require_supported; printf "%s|%s\n" "$TEAM_TRACKER" "$TEAM_KEY_REGEX"'
expect 0 'none|^L[0-9]+$' "tracker=none is supported and keys its own IDs"

# The cost key is qualified per tracker — the same short key in two projects must not collide.
peek "$DTS | .teams.pr_provider = \"azure-devops\"" 'team_cost_key "$PWD" 4'
expect 0 "owner/repo#4" "cost key for github is <owner>/<repo>#<n>"
peek '.teams.tracker = "none"' 'team_cost_key "$PWD" L7'
expect 0 "main:L7" "cost key for none is <repo-dir>:L<n>"
peek '.' 'team_cost_key "$PWD" TT-790'
expect 0 "TT-790" "cost key for jira is the bare key"
peek '.teams.pr_provider = "none"' 'team_profile_require_supported; echo reached'
expect 2 "error: pr_provider=none is reserved (no merge path)" "pr_provider=none is reserved, not merely unimplemented"
# pr_provider=github is a running provider now, but it still needs the repo it will open PRs on —
# and the refusal must name pr_provider, not the tracker the reader never configured.
peek '.teams.pr_provider = "github"' 'team_profile_require_supported; echo reached'
expect 2 "teams.github.repo is required for pr_provider=github" \
  "pr_provider=github without teams.github.repo"
# pr_provider=github is only supported on an origin that IS the repo in the profile: otherwise the
# team would clone, run, and open its PRs on somebody else's repo. Checked before any side effect.
export SMOKE_ORIGIN=github
peek '.teams.pr_provider = "github" | .teams.github = {repo: "acme/widgets"}' \
  'team_profile_require_supported; printf "%s|%s|%s\n" "$TEAM_GH_REPO" "$TEAM_GH_ORIGIN" reached'
expect 0 "acme/widgets|acme/widgets|reached" \
  "pr_provider=github on the matching origin is supported, tracker untouched"
peek '.teams.pr_provider = "github" | .teams.github = {repo: "acme/other"}' \
  'team_profile_require_supported; echo reached'
expect 2 "origin acme/widgets is not teams.github.repo acme/other" \
  "pr_provider=github pointing at another repo is refused"
! has reached "$WORK/out" || fail "a mismatched github repo still reached the side effect"
unset SMOKE_ORIGIN
peek '.teams.pr_provider = "github" | .teams.github = {repo: "acme/widgets"}' \
  'team_profile_require_supported; echo reached'
expect 2 "origin is not a github.com repo" "pr_provider=github on a non-github origin is refused"
peek '.' 'team_profile_require_supported; echo reached'
expect 0 "reached" "the TT profile (pr_provider=azure-devops) stays supported"

# ---- (4) refusals: missing file, missing block, bad enums, empty lists --------------------------
rm -f "$P"
run "$MAIN" bash -c '. .claude/lib/team-profile.sh; team_profile_load; echo reached'
expect 2 "no teams profile — run /setup:teams" "profile file missing"
peek 'del(.teams)' 'echo reached'
expect 2 "no teams profile — run /setup:teams" "teams block missing"
peek '.teams.tracker = "svn"' 'echo reached'
expect 2 "teams.tracker=svn must be jira|github|none" "bad tracker enum"
peek '.teams.tracker = "github"' 'echo reached'
expect 2 "teams.github.repo is required for tracker=github" "tracker=github without the block"
peek "$DTS | .teams.github.repo = \"not-a-slug\"" 'echo reached'
expect 2 "teams.github.repo is required for tracker=github" "teams.github.repo must be owner/repo"
peek "$DTS | del(.teams.github.status_options.delivered)" 'echo reached'
expect 2 "teams.github.status_options.delivered is required" "a missing status option is refused"
peek "$DTS | .teams.github.project_number = \"two\"" 'echo reached'
expect 2 "teams.github.project_number is required" "project_number must be numeric"
peek '.teams.pr_provider = "bitbucket"' 'echo reached'
expect 2 "teams.pr_provider=bitbucket must be" "bad pr_provider enum"
peek '.teams.gates = "sometimes"' 'echo reached'
expect 2 "teams.gates=sometimes must be auto|manual-mql5" "bad gates enum"
peek '.teams.branch_types = []' 'echo reached'
expect 2 "teams.branch_types must not be empty" "empty branch_types"
peek 'del(.teams.required_tools)' 'echo reached'
expect 2 "teams.required_tools must not be empty" "empty required_tools"
peek 'del(.teams.trunk)' 'echo reached'
expect 2 "teams.trunk is required" "missing trunk"
peek '.teams.env_file_required = "yes"' 'echo reached'
expect 2 "teams.env_file_required=yes must be true|false" "bad env_file_required"

# ---- (5) team-new with an unsupported profile: no clone, no tmux --------------------------------
chmod 600 "$MAIN/.env"
# The github repo/origin mismatch is a pre-clone refusal too, not just a library-level one.
export SMOKE_ORIGIN=github
setprofile '.teams.pr_provider = "github" | .teams.github = {repo: "acme/other"}'
: > "$STUB_LOG"
run "$MAIN" $NEW delta TT-794 feature/TT-794-x origin/develop-netcore7
expect 2 "is not teams.github.repo acme/other" "team-new refused a mismatched github repo"
[ ! -e "$WORK/main-delta" ] || fail "a refused team-new created the clone"
! grep -q tmux "$STUB_LOG" || fail "a refused team-new reached tmux"
unset SMOKE_ORIGIN
setprofile "$DTS | .teams.clone_parent = null"
: > "$STUB_LOG"
run "$MAIN" $NEW alfa TT-790 feature/TT-790-x origin/develop-netcore7
expect 2 "reserved (no merge path)" "team-new refused before side effects"
[ ! -e "$WORK/main-alfa" ] || fail "a refused team-new created the clone"
! grep -q tmux "$STUB_LOG" || fail "a refused team-new reached tmux"

# ---- (6) team-next with an unsupported profile leaves the clone untouched -----------------------
setprofile '.'
smoke_team TT-790 feature/TT-790-x
BR0="$(git -C "$CLONE" rev-parse --abbrev-ref HEAD)"
SHA0="$(jq -r .base_sha "$TD/team.json")"
arch_count() { { ls -1 "$TD/archive" 2>/dev/null || true; } | wc -l | tr -d ' '; }
ARCH0="$(arch_count)"
setprofile "$DTS | .teams.clone_parent = null"
: > "$STUB_LOG"
run "$MAIN" $NEXT alfa TT-791 chore/TT-791-x origin/develop-netcore7
expect 2 "reserved (no merge path)" "team-next refused before side effects"
[ "$(git -C "$CLONE" rev-parse --abbrev-ref HEAD)" = "$BR0" ] || fail "refused team-next switched the branch"
[ "$(jq -r .base_sha "$TD/team.json")" = "$SHA0" ] || fail "refused team-next rewrote team.json"
[ "$(arch_count)" = "$ARCH0" ] || fail "refused team-next archived the run"
! grep -q tmux "$STUB_LOG" || fail "a refused team-next reached tmux"

# ---- (7) a non-standard clone_parent: every consumer still finds the clone ----------------------
PAR="$WORK/teams dir"
CUSTOM=".teams.clone_parent = \"$PAR\""
mkdir -p "$PAR"
setprofile "$CUSTOM"
run "$MAIN" $NEW gamma TT-792 chore/TT-792-x origin/develop-netcore7
expect 0 "next:" "team-new into a clone_parent with a space"
GC="$PAR/main-gamma"
[ -f "$GC/.agents/team/team.json" ] || fail "clone_parent ignored: no clone at $GC"
GTD="$GC/.agents/team"
mkdir -p "$GTD/runs/gamma-20261017-000001/questions"
echo gamma-20261017-000001 > "$GTD/run"

run "$MAIN" $WATCH --once gamma
expect 0 "WATCH gamma" "team-watch finds a clone outside the repo's parent"
! has "no clone" "$WORK/out" || fail "team-watch reports no clone for a custom clone_parent"

run "$MAIN" $QUESTION gamma list
expect 0 "total" "team-question finds a clone outside the repo's parent"

cat > "$WORK/pane" <<'PANE'
  Bash command
  │ echo hello
  Do you want to proceed?
  ❯ 1. Yes
PANE
export STUB_PANE="$WORK/pane" STUB_TMUX_ALIVE=0
: > "$STUB_LOG"
run "$MAIN" $ANSWER gamma coder yes
expect 0 "" "team-answer approves a tier-1 prompt in the custom clone"
grep -q "send-keys -t =gamma-coder: Enter" "$STUB_LOG" || fail "team-answer sent no Enter"
mkdir -p "$GC/.claude"
printf '{"permissions": {"ask": ["Bash(echo:*)"]}}\n' > "$GC/.claude/settings.json"
: > "$STUB_LOG"
run "$MAIN" $ANSWER gamma coder yes
expect 1 "ask/deny-tier prompt" "team-answer reads the custom clone's ask rules"
! grep -q "send-keys -t =gamma-coder: Enter" "$STUB_LOG" || fail "a refused team-answer sent Enter"
unset STUB_PANE STUB_TMUX_ALIVE

# /monitor step 1 preflight (monitor.md) through the one resolver — it must not drop this team.
run "$MAIN" bash -c '. .claude/lib/team-profile.sh; team_profile_load
  c="$(team_clone_dir gamma)"; [ -f "$c/.agents/team/team.json" ] && echo "monitor-ok: $c"'
expect 0 "monitor-ok: $GC" "/monitor preflight accepts a custom clone_parent"

setprofile "$DTS | .teams.clone_parent = null"
: > "$STUB_LOG"
run "$MAIN" $WORKER start TT-793 feature/TT-793-x origin/develop-netcore7 --thread th-1
expect 2 "reserved (no merge path)" "worker-next start refused before side effects"
[ ! -e "$WORK/main-sol" ] || fail "a refused worker start created the -sol clone"
[ ! -e "$WORK/main-sol/.git/taketask-worker/active" ] || fail "a refused worker start published state"
! grep -q tmux "$STUB_LOG" || fail "a refused worker start reached tmux"

# ---- (8) the /start-team base-ref follows the profile trunk -------------------------------------
peek '.teams.trunk = "main"' 'team_profile_require_supported; team_base_ref'
expect 0 "origin/main" "base-ref for trunk=main on a supported provider"
! grep -q "develop-netcore7" "$SRC/.claude/commands/start-team.md" \
  || fail "start-team.md still hardcodes a trunk"
! grep -rqE "develop-netcore7|TakeTask2|codex-taketask" "$SRC"/.claude/lib/team-*.sh \
  "$SRC"/.claude/lib/worker-*.sh || fail "lib still carries TT values"

# ---- (9) QA/CLI prompts render the gates from the profile ---------------------------------------
RENDER='. .claude/lib/team-profile.sh; team_profile_load
  for f in qa cli; do p="$(cat ".claude/team/prompts/$f.md")"
    p="${p//\{\{BUILD_CHECK\}\}/$TEAM_BUILD_CHECK}"; p="${p//\{\{TEST_GATE\}\}/$(team_gate_sentence)}"
    printf "%s\n" "$p"; done'
peek '.teams.test_gate = "none"' "$RENDER"
expect 0 "test gate: none — skip" "test_gate=none renders a sentence, not a command"
! has 'test-gate' "$WORK/out" || fail "test_gate=none still renders a gate call"
has "dotnet build TakeTask2.API.sln" "$WORK/out" || fail "build_check not rendered from the profile"
peek '.teams.test_gate = "/opt/dts gates/test-gate.sh"' "$RENDER"
expect 0 'bash /opt/dts\ gates/test-gate.sh' "a test_gate path with a space is shell-quoted"
! has '{{TEST_GATE}}' "$WORK/out" || fail "TEST_GATE left unrendered"
! has '{{BUILD_CHECK}}' "$WORK/out" || fail "BUILD_CHECK left unrendered"

# ---- (10) the gate sentence is shell-safe, not merely double-quoted ----------------------------
peek '.teams.test_gate = "/g/$(touch injected)/test gate.sh"' 'team_gate_sentence'
expect 0 '\$\(touch\ injected\)' 'a command substitution in test_gate is escaped, not expanded'
run "$WORK" bash -c 'cd "$1"; eval "$2" >/dev/null 2>&1 || true; [ ! -e injected ] || exit 9' _ \
  "$WORK" "$(cat "$WORK/out")"
expect 0 "" 'evaluating the gate sentence runs no command substitution from the path'

# ---- (11) test_gate is a path: `~` expands, `none` stays a sentinel ----------------------------
peek '.teams.test_gate = "~/g/test gate.sh"' 'printf "%s\n" "$TEAM_TEST_GATE"; team_gate_sentence'
expect 0 "$HOME/g/test gate.sh" "a test_gate path with ~ is expanded"
peek '.teams.test_gate = "none"' 'printf "[%s]\n" "$TEAM_TEST_GATE"'
expect 0 "[none]" "the none sentinel is not path-expanded"

# ---- (12) an unresolvable clone must never be approved as tier 1 -------------------------------
rm -f "$GC/.claude/settings.json"            # without rules, a readable clone would be tier 1
export STUB_PANE="$WORK/pane" STUB_TMUX_ALIVE=0
: > "$STUB_LOG"
rm -f "$P"
run "$MAIN" $ANSWER gamma coder yes
expect 1 "nothing approved" "team-answer refuses when the clone cannot be resolved"
! grep -q "send-keys -t =gamma-coder: Enter" "$STUB_LOG" || fail "unresolved clone still got an Enter"
unset STUB_PANE STUB_TMUX_ALIVE

# ---- (13) merge-check and worker init refuse an unsupported profile before any side effect -----
setprofile "$DTS | .teams.clone_parent = null"
: > "$STUB_LOG"
BR1="$(git -C "$CLONE" rev-parse --abbrev-ref HEAD)"
run "$MAIN" $MERGE alfa
expect 2 "reserved (no merge path)" "merge-check refused before fetch/ADO/build"
! grep -q "^az " "$STUB_LOG" || fail "a refused merge-check called az"
[ ! -e "$TD/merge-check-build.log" ] || fail "a refused merge-check ran the build"
[ "$(git -C "$CLONE" rev-parse --abbrev-ref HEAD)" = "$BR1" ] || fail "merge-check moved the clone"
run "$MAIN" $WORKER init origin/develop-netcore7
expect 2 "reserved (no merge path)" "worker init refused before the first fetch"
[ ! -e "$WORK/main-sol" ] || fail "a refused worker init created the clone"

# ---- (14) teams.clone_name: the clone directory template ----------------------------------------
# No key → today's behaviour, `<repo dir>-<team>`. Physical $WORK: with no clone_parent the
# parent comes from `git rev-parse --show-toplevel`, which resolves /var -> /private/var.
WP="$(cd "$WORK" && pwd -P)"
peek '.' 'printf "%s|%s\n" "$(team_clone_dir alfa)" "$(team_clone_glob)"'
expect 0 "$WP/main-alfa|$WP/main-" "no clone_name keeps <repo>-<team>"
# `{Team}` capitalizes the first letter only; the glob stays the prefix before the placeholder.
PAR2="$WORK/dts teams"
mkdir -p "$PAR2"
CN=".teams.clone_parent = \"$PAR2\" | .teams.clone_name = \"DTS-{Team}\""
peek "$CN" 'printf "%s|%s\n" "$(team_clone_dir alfa)" "$(team_clone_glob)"'
expect 0 "$PAR2/DTS-Alfa|$PAR2/DTS-" "clone_name DTS-{Team} with a clone_parent"
peek "$CN" 'team_clone_dir my-team'
expect 0 "$PAR2/DTS-My-team" "{Team} capitalizes the first letter, not the whole name"
peek '.teams.clone_name = "x-{team}"' 'team_clone_dir alfa'
expect 0 "$WP/x-alfa" "{team} is substituted verbatim"
# The placeholder must END the template and be the only one: the clone glob is a prefix.
for bad in '{team}-x' 'a/{team}' 'nope' '{team}{team}'; do
  peek ".teams.clone_name = \"$bad\"" 'echo reached'
  expect 2 "teams.clone_name=$bad must end with {team} or {Team} (no '/')" \
    "clone_name '$bad' is refused"
  ! has reached "$WORK/out" || fail "clone_name '$bad' still loaded"
done
# Consumers: a clone created under the template is found by the resolver, team-watch and /monitor.
setprofile "$CN"
run "$MAIN" $NEW zeta TT-795 chore/TT-795-x origin/develop-netcore7
expect 0 "next:" "team-new honours clone_name"
ZC="$PAR2/DTS-Zeta"
[ -f "$ZC/.agents/team/team.json" ] || fail "clone_name ignored: no clone at $ZC"
mkdir -p "$ZC/.agents/team/runs/zeta-20261018-000001/questions"
echo zeta-20261018-000001 > "$ZC/.agents/team/run"
run "$MAIN" $WATCH --once zeta
expect 0 "WATCH zeta" "team-watch finds a {Team} clone"
! has "no clone" "$WORK/out" || fail "team-watch reports no clone for a {Team} template"
run "$MAIN" bash -c '. .claude/lib/team-profile.sh; team_profile_load
  c="$(team_clone_dir zeta)"; [ -f "$c/.agents/team/team.json" ] && echo "monitor-ok: $c"'
expect 0 "monitor-ok: $ZC" "/monitor preflight accepts a clone_name template"
run "$MAIN" $NEXT zeta TT-796 chore/TT-796-x origin/develop-netcore7
expect 0 "clone:    $ZC" "team-next switches the {Team} clone it resolved"

echo "team-profile-smoke: OK"
