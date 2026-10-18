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

# ---- (3) require_supported refuses what 2a cannot run ------------------------------------------
peek "$DTS" 'team_profile_require_supported; echo reached'
expect 2 "error: pr_provider=none unsupported in 2a" "DTS still refused — on pr_provider, not the tracker"
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
expect 2 "error: pr_provider=none unsupported in 2a" "pr_provider none refused in 2a"
peek '.teams.pr_provider = "github"' 'team_profile_require_supported; echo reached'
expect 2 "error: pr_provider=github unsupported in 2a" "pr_provider github refused in 2a"
peek '.' 'team_profile_require_supported; echo reached'
expect 0 "reached" "TT profile is supported in 2a"

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
setprofile "$DTS | .teams.clone_parent = null"
: > "$STUB_LOG"
run "$MAIN" $NEW alfa TT-790 feature/TT-790-x origin/develop-netcore7
expect 2 "unsupported in 2a" "team-new refused before side effects"
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
expect 2 "unsupported in 2a" "team-next refused before side effects"
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
expect 2 "unsupported in 2a" "worker-next start refused before side effects"
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
expect 2 "unsupported in 2a" "merge-check refused before fetch/ADO/build"
! grep -q "^az " "$STUB_LOG" || fail "a refused merge-check called az"
[ ! -e "$TD/merge-check-build.log" ] || fail "a refused merge-check ran the build"
[ "$(git -C "$CLONE" rev-parse --abbrev-ref HEAD)" = "$BR1" ] || fail "merge-check moved the clone"
run "$MAIN" $WORKER init origin/develop-netcore7
expect 2 "unsupported in 2a" "worker init refused before the first fetch"
[ ! -e "$WORK/main-sol" ] || fail "a refused worker init created the clone"

echo "team-profile-smoke: OK"
