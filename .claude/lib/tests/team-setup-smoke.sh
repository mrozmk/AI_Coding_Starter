#!/usr/bin/env bash
# Offline smoke for team-setup.sh (the /setup:teams installer) and the seed preflight: the
# installation, its idempotence, the files it must never overwrite, and the full hook contract in
# settings.json (event + matcher coverage + command + sync mode).
# No network, no `gh`, no tmux — every fixture is a throwaway `git init` under $WORK.
# Bash 3.2 compatible (macOS /bin/bash) — run it with /bin/bash, like the harness does.
set -euo pipefail

ST=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
SETUP="$ST/.claude/lib/team-setup.sh"
MANIFEST="$ST/.claude/team/manifest.txt"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
export GIT_CONFIG_GLOBAL="$WORK/gitconfig" GIT_CONFIG_NOSYSTEM=1
cat > "$GIT_CONFIG_GLOBAL" <<EOF
[user]
  name = smoke
  email = smoke@example.invalid
[init]
  defaultBranch = main
EOF

fail() { echo "team-setup-smoke: FAIL — $*"; [ ! -f "$WORK/out" ] || sed 's/^/  | /' "$WORK/out"; exit 1; }
has() { grep -qF -- "$1" "$WORK/out"; }
setup() {  # setup <target> [--check] → RC, $WORK/out
  local t="$1"; shift
  set +e; bash "$SETUP" "$ST" "$t" "$@" > "$WORK/out" 2>&1; RC=$?; set -e
}
field() {  # field <status> [class] → how many output lines carry it
  awk -F'\t' -v s="$1" -v c="${2:-}" \
    '$1 == s && (c == "" || $2 == c) { n++ } END { print n + 0 }' "$WORK/out"
}
treehash() { (cd "$1" && find . -path ./.git -prune -o -type f -print | LC_ALL=C sort \
  | xargs shasum -a 256 | shasum -a 256); }
mktarget() {  # mktarget <name> → a fresh one-commit repo at $WORK/<name>
  local t="$WORK/$1"
  mkdir -p "$t"; git -C "$t" init --quiet
  echo README > "$t/README"; git -C "$t" add README; git -C "$t" commit --quiet -m README
  # The core files a synced project already has (team-setup.sh refuses without them, see (20)).
  mkdir -p "$t/.claude/lib/costs" "$t/.claude/hooks/lib"
  cp "$ST/.claude/lib/team-profile.sh" "$ST/.claude/lib/team-tracker.sh" "$t/.claude/lib/"
  cp "$ST/.claude/lib/costs/runtime-mark.sh" "$t/.claude/lib/costs/"
  cp "$ST/.claude/hooks/lib/guard_destructive_sql.py" "$t/.claude/hooks/lib/"
  printf '%s' "$t"
}
# Entries the manifest distributes — counted from the file, never hardcoded.
ENTRIES=$(grep -c '^own \|^shared ' "$MANIFEST")
[ "$ENTRIES" -gt 50 ] || fail "manifest has only $ENTRIES entries — wrong file?"

# ---- (1) --check on an empty target writes nothing ----------------------------------------------
T=$(mktarget t1)
touch "$WORK/marker"
setup "$T" --check
[ "$RC" = 3 ] || fail "1: --check on a profile-less target: exit $RC, expected 3"
[ "$(field create own)" -gt 0 ] || fail "1: --check printed no create lines"
has "profile: missing" || fail "1: --check did not report the missing profile"
touched=$(find "$T" -path "$T/.git" -prune -o -newer "$WORK/marker" -print)
[ -z "$touched" ] || fail "1: --check wrote $touched"

# ---- (2) the installation ----------------------------------------------------------------------
setup "$T"
[ "$RC" = 3 ] || fail "2: install into a profile-less target: exit $RC, expected 3"
n=$(awk -F'\t' '$1 == "created" && ($2 == "own" || $2 == "shared")' "$WORK/out" | wc -l | tr -d ' ')
[ "$n" = "$ENTRIES" ] || fail "2: created $n manifest files, manifest has $ENTRIES"
has "created	generated	.claude/codex-profile" || fail "2: no codex-profile from the template"
[ "$(field conflict)" = 0 ] || fail "2: a fresh install reported a conflict"
while IFS= read -r p; do
  [ -f "$T/$p" ] || fail "2: $p not installed"
  case "$p" in *.sh) [ -x "$ST/$p" ] || continue
    [ -x "$T/$p" ] || fail "2: $p lost its executable bit" ;; esac
done < <(sed -n 's/^own //p;s/^shared //p' "$MANIFEST")
git -C "$T" check-ignore -q .agents/team/x || fail "2: .agents/team/ is not ignored"
cmp -s "$ST/.claude/codex-profile" "$T/.claude/codex-profile" \
  || fail "2: codex-profile is not the starter template"
has "created	generated	.claude/claude-profile" || fail "2: no claude-profile from the template"
cmp -s "$ST/.claude/claude-profile" "$T/.claude/claude-profile" \
  || fail "2: claude-profile is not the starter template"
S="$T/.claude/settings.json"
jq -e '[.hooks.PreToolUse[] | select(.matcher | split("|") | index("AskUserQuestion")) | .hooks[]
  | select(.command | test("guard-team-question"))] | length == 1' "$S" >/dev/null \
  || fail "2: no PreToolUse/AskUserQuestion hook Q"
jq -e '[.hooks.PreToolUse[] | select(.matcher | split("|") as $t | ($t | index("Edit"))
  and ($t | index("Write"))) | .hooks[] | select(.command | test("guard-team-memory"))]
  | length == 1' "$S" >/dev/null || fail "2: no PreToolUse Edit+Write hook M"
jq -e '[.hooks.PreToolUse[] | select(.matcher == "Bash") | .hooks[]
  | select(.command | test("guard-team-verdict"))] | length == 1' "$S" >/dev/null \
  || fail "2: no PreToolUse/Bash verdict guard V"
jq -e '[.hooks.Notification[] | select(.matcher | split("|") | index("permission_prompt"))
  | .hooks[] | select((.command | test("team-attention")) and .async == true)] | length == 1' \
  "$S" >/dev/null || fail "2: no async Notification hook A"
[ "$(jq '.permissions.allow | length' "$S")" = 24 ] || fail "2: allow is not the 24 role rules"
jq -e '.permissions.ask | index("Bash(bash .claude/lib/team-mail-setup.sh*)")' "$S" >/dev/null \
  || fail "2: the channel setup is not behind ask"
jq -e '.permissions.ask | index("Bash(bash .claude/team/sessions/operator-kit/install.sh*)")' "$S" >/dev/null \
  || fail "2: the operator kit installer is not behind ask"
# team-watch: W (SessionStart, no matcher, sync, timeout 5) and R (Stop), the wake/pause scripts
# allowed, the Operator verbs behind ask — each exactly once.
jq -e '[.hooks.SessionStart[] | select(has("matcher") | not) | .hooks[]
  | select((.command | test("team-watch-session")) and .timeout == 5 and (.async // false) == false)]
  | length == 1' "$S" >/dev/null || fail "2: no SessionStart hook W with timeout 5"
jq -e '[.hooks.Stop[] | .hooks[] | select(.command | test("monitoring-rearm"))] | length == 1' \
  "$S" >/dev/null || fail "2: no Stop hook R"
for a in "Bash(bash .claude/lib/session-wake.sh*)" "Bash(bash .claude/lib/monitoring.sh*)"; do
  [ "$(jq --arg a "$a" '[.permissions.allow[] | select(. == $a)] | length' "$S")" = 1 ] \
    || fail "2: allow $a not present once"
done
for a in routing stop "register --takeover" "mode answering" "mode class"; do
  a="Bash(bash .claude/lib/team-watch.sh $a*)"
  [ "$(jq --arg a "$a" '[.permissions.ask[] | select(. == $a)] | length' "$S")" = 1 ] \
    || fail "2: ask $a not present once"
done
# Role sessions: no session-role.sh hook any more (session-registry.sh prints the contract), the
# support verbs and /roles allowed, the Operator actions (freeze off, rollback, roles.sh here)
# behind ask — each exactly once; an Operator action is never on allow, and the launcher verbs
# step 9a removed (start, stop, status, up, here) are on neither list.
jq -e '[.hooks[]?[]?.hooks[]? | select(.command | test("session-role.sh"))] | length == 0' "$S" >/dev/null \
  || fail "2: session-role.sh is still registered"
RA="Bash(bash .claude/lib/roles.sh"
for a in "$RA)" "$RA up*)" "$RA status*)" "$RA stop *)" "$RA place *)"; do
  [ "$(jq --arg a "$a" '[.permissions.allow[] | select(. == $a)] | length' "$S")" = 1 ] \
    || fail "2: allow $a not present once"
done
[ "$(jq --arg a "$RA here *)" '[.permissions.ask[] | select(. == $a)] | length' "$S")" = 1 ] \
  || fail "2: ask roles.sh here not present once"
SSA="Bash(bash .claude/lib/supervisor-sessions.sh"
for a in "$SSA check*)" "$SSA preflight*)" "$SSA materialize*)" "$SSA reviewer*)" \
  "$SSA freeze on *)" "$SSA freeze status*)" "$SSA answer *)" \
  "Bash(printenv TEAM_SESSION_ROLE)" "Bash(bash .claude/lib/test-gate.sh*)"; do
  [ "$(jq --arg a "$a" '[.permissions.allow[] | select(. == $a)] | length' "$S")" = 1 ] \
    || fail "2: allow $a not present once"
done
for a in "$SSA freeze off*)" "$SSA rollback*)"; do
  [ "$(jq --arg a "$a" '[.permissions.ask[] | select(. == $a)] | length' "$S")" = 1 ] \
    || fail "2: ask $a not present once"
done
jq -e --arg p "$SSA" '[(.permissions.allow + .permissions.ask)[] | select(startswith($p)
  and test("sh (start|stop|status|up|here)"))] | length == 0' "$S" >/dev/null \
  || fail "2: a removed launcher verb is still allowed or asked"
jq -e --arg p "$SSA" '[.permissions.allow[] | select(startswith($p)
  and test("freeze off|rollback|here"))] | length == 0' "$S" >/dev/null \
  || fail "2: a launcher Operator action is on allow"
egress() {  # egress <settings> <matcher> → how many blocking egress guards that exact matcher has
  jq --arg m "$2" '[.hooks.PreToolUse[]? | select(.matcher == $m) | .hooks[]
    | select((.command | test("guard-team-egress")) and .onFailure == "block"
      and (.async // false) == false)] | length' "$1"
}
[ "$(egress "$S" Bash)" = 1 ] && [ "$(egress "$S" WebFetch)" = 1 ] \
  || fail "2: the egress guard is not registered once under Bash and once under WebFetch"
[ "$(jq '[.hooks.PreToolUse[]? | select(.matcher == "Bash") | .hooks[]
  | select((.command | test("guard-destructive-sql")) and .onFailure == "block")] | length' "$S")" = 1 ] \
  || fail "2: the destructive-SQL guard is not registered once, blocking, under Bash"
git -C "$T" check-ignore -q .agents/agent-mail/mail.sqlite || fail "2: .agents/agent-mail/ is not ignored"
# The token-usage stage hook: PreToolUse Skill, PreToolUse Bash filtered to the end step, and
# UserPromptExpansion — each once, synchronous, timeout 5; the full writer allow once.
END_IF='Bash(bash .claude/lib/costs/runtime-mark.sh stage end *)'
stage() {  # stage <settings> <event> <matcher|''> <if|''> → how many correct stage-mark entries
  jq --arg ev "$2" --arg m "$3" --arg c "$4" '[.hooks[$ev][]? | select((.matcher // "") == $m)
    | .hooks[] | select((.command | test("stage-mark.sh")) and .timeout == 5
      and (.async // false) == false and (.if // "") == $c)] | length' "$1"
}
[ "$(stage "$S" PreToolUse Skill '')" = 1 ] && [ "$(stage "$S" PreToolUse Bash "$END_IF")" = 1 ] \
  && [ "$(stage "$S" UserPromptExpansion '' '')" = 1 ] || fail "2: the stage hook is not registered 3x"
[ "$(jq '[.hooks[]?[]?.hooks[]? | select(.command | test("stage-mark.sh"))] | length' "$S")" = 3 ] \
  || fail "2: stage-mark.sh is registered more than 3 times"
[ "$(jq '[.permissions.allow[] | select(. == "Bash(bash .claude/lib/costs/runtime-mark.sh:*)")] | length' \
  "$S")" = 1 ] || fail "2: the runtime-mark allow is not present once"
[ "$(jq '[.hooks[]?[]?.hooks[]? | select((.command // "") | test("guard-team-egress"))] | length' \
  "$ST/.claude/settings.json")" = 0 ] || fail "2: the starter's shared settings register the egress guard"

# ---- (3) the second run changes nothing --------------------------------------------------------
echo '{"teams":{}}' > "$T/.claude/project-profile.json"
H0=$(treehash "$T")
setup "$T"
[ "$RC" = 0 ] || fail "3: the second run exited $RC, expected 0"
has "summary: created=0 kept=" || fail "3: the second run created something"
has "conflict=0 merged=0" || fail "3: the second run merged something"
[ "$(field kept)" -gt "$ENTRIES" ] || fail "3: the second run did not keep every path"
[ "$(treehash "$T")" = "$H0" ] || fail "3: the second run changed the tree"

# ---- (4) a locally edited own file is never overwritten -----------------------------------------
echo x >> "$T/.claude/lib/team-run.sh"
cp "$T/.claude/lib/team-run.sh" "$WORK/edited"
setup "$T"
[ "$RC" = 1 ] || fail "4: a conflict exited $RC, expected 1"
has "conflict	own	.claude/lib/team-run.sh" || fail "4: the edited file is not a conflict"
has "--- conflict .claude/lib/team-run.sh" || fail "4: no diff header for the conflict"
cmp -s "$WORK/edited" "$T/.claude/lib/team-run.sh" || fail "4: the local edit was overwritten"

# ---- (5) a differing shared file says so, and stays ---------------------------------------------
echo local > "$T/AGENTS.md"
setup "$T"
[ "$RC" = 1 ] || fail "5: a shared conflict exited $RC, expected 1"
has "conflict (shared — merge by hand)	shared	AGENTS.md" || fail "5: shared conflict not labelled"
[ "$(cat "$T/AGENTS.md")" = local ] || fail "5: the project's AGENTS.md was overwritten"

# ---- (6) M joins the project's own Edit|Write|MultiEdit entry -----------------------------------
T=$(mktarget t6)
mkdir -p "$T/.claude"
jq -n --arg m 'bash "$CLAUDE_PROJECT_DIR/.claude/hooks/guard-memory.sh"' \
  --arg q 'bash "$CLAUDE_PROJECT_DIR/.claude/hooks/guard-team-question.sh"' \
  '{hooks: {PreToolUse: [
     {matcher: "Edit|Write|MultiEdit", hooks: [{type: "command", command: $m}]},
     {matcher: "AskUserQuestion", hooks: [{type: "command", command: $q}]}]}}' \
  > "$T/.claude/settings.json"
setup "$T"
[ "$(field conflict)" = 0 ] || fail "6: a coverage-compatible matcher was reported as a conflict"
S="$T/.claude/settings.json"
[ "$(jq '[.hooks.PreToolUse[] | select(.matcher != "Bash" and .matcher != "WebFetch")] | length' \
  "$S")" = 3 ] || fail "6: M added a PreToolUse entry of its own (the third is the stage hook's Skill)"
jq -e '.hooks.PreToolUse[0] | (.matcher == "Edit|Write|MultiEdit")
  and ([.hooks[].command] | index("bash \"$CLAUDE_PROJECT_DIR/.claude/hooks/guard-team-memory.sh\""))
  and (.hooks[0].command | test("guard-memory"))' "$S" >/dev/null \
  || fail "6: M did not join the project's MultiEdit entry after its own hook"
setup "$T"
[ "$(jq '[.hooks.PreToolUse[].hooks[] | select(.command | test("guard-team-memory"))] | length' \
  "$S")" = 1 ] || fail "6: the second run duplicated hook M"

# ---- (7) wrong event: the project's entry stays, a correct one is added -------------------------
T=$(mktarget t7)
mkdir -p "$T/.claude"
jq -n --arg q 'bash "$CLAUDE_PROJECT_DIR/.claude/hooks/guard-team-question.sh"' \
  '{hooks: {PostToolUse: [{matcher: "AskUserQuestion", hooks: [{type: "command", command: $q}]}]}}' \
  > "$T/.claude/settings.json"
setup "$T"
has "conflict settings.json Q: registered under PostToolUse, not PreToolUse" \
  || fail "7: a hook under the wrong event is not a conflict"
S="$T/.claude/settings.json"
[ "$(jq '[.hooks.PostToolUse[] | select(.matcher == "AskUserQuestion") | .hooks[]] | length' "$S")" = 1 ] \
  || fail "7: the foreign entry was touched"
jq -e '[.hooks.PreToolUse[] | select(.matcher == "AskUserQuestion") | .hooks[]
  | select(.command | test("guard-team-question"))] | length == 1' "$S" >/dev/null \
  || fail "7: no correct PreToolUse entry was added"

# ---- (8) wrong matcher: a new entry covering Edit and Write -------------------------------------
T=$(mktarget t8)
mkdir -p "$T/.claude"
jq -n --arg m 'bash "$CLAUDE_PROJECT_DIR/.claude/hooks/guard-team-memory.sh"' \
  '{hooks: {PreToolUse: [{matcher: "Edit", hooks: [{type: "command", command: $m}]}]}}' \
  > "$T/.claude/settings.json"
setup "$T"
has 'conflict settings.json M: matcher "Edit" does not cover Edit, Write' \
  || fail "8: a matcher that covers only Edit is not a conflict"
S="$T/.claude/settings.json"
jq -e '[.hooks.PreToolUse[] | select(.matcher | split("|") as $t | ($t | index("Edit"))
  and ($t | index("Write"))) | .hooks[] | select(.command | test("guard-team-memory"))]
  | length == 1' "$S" >/dev/null || fail "8: no entry covering Edit|Write was added"
jq -e '.hooks.PreToolUse[0].matcher == "Edit"' "$S" >/dev/null || fail "8: the project's entry moved"

# ---- (9) async guard: a guard must run synchronously --------------------------------------------
T=$(mktarget t9)
mkdir -p "$T/.claude"
jq -n --arg q 'bash "$CLAUDE_PROJECT_DIR/.claude/hooks/guard-team-question.sh"' \
  '{hooks: {PreToolUse: [{matcher: "AskUserQuestion",
     hooks: [{type: "command", command: $q, async: true}]}]}}' > "$T/.claude/settings.json"
setup "$T"
has "conflict settings.json Q: registered with async: true" || fail "9: an async guard is not a conflict"
S="$T/.claude/settings.json"
jq -e '[.hooks.PreToolUse[] | select(.matcher == "AskUserQuestion") | .hooks[]
  | select((.command | test("guard-team-question")) and (.async | not))] | length == 1' "$S" \
  >/dev/null || fail "9: no synchronous Q entry was added"
jq -e '[.hooks.PreToolUse[].hooks[] | select(.async == true)] | length == 1' "$S" >/dev/null \
  || fail "9: the project's async entry was rewritten"

# ---- (10) the project's own permissions and settings.local.json are left alone ------------------
T=$(mktarget t10)
mkdir -p "$T/.claude"
jq -n '{permissions: {allow: ["Bash(ls:*)", "Bash(rg:*)"], deny: ["Bash(curl:*)"]},
        ask: {keep: true}}' > "$T/.claude/settings.json"
printf '{"local": true}\n' > "$T/.claude/settings.local.json"
cp "$T/.claude/settings.local.json" "$WORK/local.before"
setup "$T"
S="$T/.claude/settings.json"
[ "$(jq -r '.permissions.allow[0:2] | join(",")' "$S")" = "Bash(ls:*),Bash(rg:*)" ] \
  || fail "10: the project's allow rules lost their order"
[ "$(jq -r '.permissions.deny | join(",")' "$S")" = "Bash(curl:*)" ] || fail "10: deny was changed"
[ "$(jq -r '.ask.keep' "$S")" = true ] || fail "10: an unrelated key was dropped"
[ "$(jq '.permissions.allow | length' "$S")" = 26 ] || fail "10: allow is not 2 project + 24 role rules"
cmp -s "$WORK/local.before" "$T/.claude/settings.local.json" || fail "10: settings.local.json changed"

# ---- (11) manifest completeness: nothing in the harness trees is left behind ---------------------
while IFS= read -r p; do
  case "$p" in */tests/*) continue ;; esac
  grep -qxF "!$p" "$MANIFEST" && continue  # a core file that lives in a harness tree
  grep -qxF "own $p" "$MANIFEST" || grep -qxF "shared $p" "$MANIFEST" \
    || fail "11: $p is in the harness tree but not in the manifest"
done < <(git -C "$ST" ls-files '.claude/lib/team-*.sh' .claude/team \
  .claude/lib/costs .claude/hooks/lib)

# ---- (12) seed preflight: a seed file tracked on the base with other content is refused ---------
T=$(mktarget t12)
mkdir -p "$T/.claude" "$T/.agents/memory"
jq -n '{schema: 1, teams: {tracker: "none", pr_provider: "azure-devops", trunk: "main",
  branch_types: ["feature"], required_tools: ["git"], env_file_required: false,
  build_check: "true", test_gate: "none", gates: "auto",
  seed_files: [".agents/memory/user-profile.md", ".claude/settings.local.json"]}}' \
  > "$T/.claude/project-profile.json"
echo a > "$T/.agents/memory/user-profile.md"
git -C "$T" add .claude/project-profile.json .agents/memory/user-profile.md
git -C "$T" commit --quiet -m seed
seed_checks() {
  set +e
  bash -c '. "$1/.claude/lib/team-lib.sh"; TEAM_PROBLEMS=()
    team_seed_checks "$2" HEAD
    echo "problems=${#TEAM_PROBLEMS[@]}"
    printf "%s\n" ${TEAM_PROBLEMS[@]+"${TEAM_PROBLEMS[@]}"}' _ "$ST" "$1" > "$WORK/out" 2>&1
  RC=$?; set -e
}
echo b > "$T/.agents/memory/user-profile.md"      # tracked on HEAD, different in the work tree
seed_checks "$T"
[ "$RC" = 0 ] || fail "12: team_seed_checks exited $RC"
has "problems=1" || fail "12: a tracked seed file with other content raised no problem"
has "seed file .agents/memory/user-profile.md is tracked on HEAD with different content" \
  || fail "12: the problem does not name the seed file"
git -C "$T" checkout -- .agents/memory/user-profile.md   # same content as HEAD → fine
printf 'x\n' > "$T/.claude/settings.local.json"           # untracked → exactly what seeding is for
seed_checks "$T"
has "problems=0" || fail "12: an untracked or identical seed file raised a problem"

# ---- (13) the target must be a repo ROOT, and a refusal creates nothing -------------------------
T="$WORK/nosuch/x"
setup "$T"
[ "$RC" = 2 ] || fail "13: a missing target exited $RC, expected 2"
[ ! -e "$T" ] || fail "13: a refused run created $T"
T="$WORK/plain"; mkdir -p "$T"
setup "$T"
[ "$RC" = 2 ] || fail "13: a non-repo target exited $RC, expected 2"
has "is not a git repository" || fail "13: the refusal does not name the cause"
[ -z "$(ls -A "$T")" ] || fail "13: a refused run wrote into a non-repo directory"
T=$(mktarget t13); mkdir -p "$T/sub"
setup "$T/sub"
[ "$RC" = 2 ] || fail "13: a subdirectory target exited $RC, expected 2"
has "is not the repo root" || fail "13: the refusal does not name the repo root"
[ -z "$(ls -A "$T/sub")" ] || fail "13: a refused run wrote into a subdirectory"

# ---- (14) the settings.json write never goes through a planted temp name -----------------------
T=$(mktarget t14)
mkdir -p "$T/.claude"
printf '{"local": true}\n' > "$T/.claude/settings.local.json"
cp "$T/.claude/settings.local.json" "$WORK/local14"
# The first implementation wrote to this exact name before renaming it over settings.json.
ln -s settings.local.json "$T/.claude/settings.json.team-setup.tmp"
setup "$T"
cmp -s "$WORK/local14" "$T/.claude/settings.local.json" \
  || fail "14: the merge wrote through a planted temp-name symlink"
jq -e '.permissions.allow | length == 24' "$T/.claude/settings.json" >/dev/null \
  || fail "14: settings.json was not written"
[ -L "$T/.claude/settings.json.team-setup.tmp" ] || fail "14: the planted symlink was consumed"
[ -z "$(ls "$T/.claude"/.team-setup.* 2>/dev/null)" ] || fail "14: a temp file was left behind"

# ---- (15) no write may pass through a symlinked target component -------------------------------
T=$(mktarget t15a)
rm -rf "$T/.claude"                                       # the symlink takes the directory's place
mkdir -p "$T/outside"
ln -s outside "$T/.claude"
H0=$(treehash "$T")
setup "$T"
[ "$RC" = 2 ] || fail "15a: a symlinked .claude exited $RC, expected 2"
has "refusing to write through the symlink" || fail "15a: the refusal does not name the symlink"
[ "$(treehash "$T")" = "$H0" ] || fail "15a: a refused run wrote something"
T=$(mktarget t15b)
echo keep > "$T/elsewhere"
ln -s elsewhere "$T/.gitignore"
H0=$(treehash "$T")
setup "$T"
[ "$RC" = 2 ] || fail "15b: a symlinked .gitignore exited $RC, expected 2"
[ "$(cat "$T/elsewhere")" = keep ] || fail "15b: the symlink target was appended to"
[ "$(treehash "$T")" = "$H0" ] || fail "15b: a refused run wrote something"
T=$(mktarget t15c)
mkdir -p "$T/.claude/lib"
ln -s /nowhere/nothing "$T/.claude/lib/team-run.sh"      # dangling: invisible to `-e`
H0=$(treehash "$T")
setup "$T"
[ "$RC" = 2 ] || fail "15c: a dangling own-file symlink exited $RC, expected 2"
[ -L "$T/.claude/lib/team-run.sh" ] || fail "15c: the dangling symlink was replaced"
[ "$(treehash "$T")" = "$H0" ] || fail "15c: a refused run wrote something"
T=$(mktarget t15d)
rm -rf "$T/.claude"
printf 'file\n' > "$T/.claude"                           # a regular file where a dir must go
setup "$T"
[ "$RC" = 2 ] || fail "15d: a .claude file exited $RC, expected 2"
has "is not a directory" || fail "15d: the refusal does not name the type clash"

# ---- (16) manifest paths stay inside both roots ------------------------------------------------
FS="$WORK/fakestarter"
mkdir -p "$FS/.claude/team"
fake_manifest() { printf '%s\n' "$1" > "$FS/.claude/team/manifest.txt"; }
fake_setup() { set +e; bash "$SETUP" "$FS" "$1" > "$WORK/out" 2>&1; RC=$?; set -e; }
T=$(mktarget t16)
H0=$(treehash "$T")
fake_manifest "own /etc/hosts"
fake_setup "$T"
[ "$RC" = 2 ] || fail "16: an absolute manifest path exited $RC, expected 2"
has "is an absolute path" || fail "16: the refusal does not name the absolute path"
fake_manifest "own ../../../etc/hosts"
fake_setup "$T"
[ "$RC" = 2 ] || fail "16: a .. manifest path exited $RC, expected 2"
has "leaves the manifest root" || fail "16: the refusal does not name the .. escape"
fake_manifest "own .claude/team/esc"
ln -s /etc/hosts "$FS/.claude/team/esc"
fake_setup "$T"
[ "$RC" = 2 ] || fail "16: a symlinked manifest source exited $RC, expected 2"
has "is a symlink" || fail "16: the refusal does not name the symlinked source"
[ "$(treehash "$T")" = "$H0" ] || fail "16: a refused manifest run wrote something"

# ---- (17) settings.json must be one JSON object, checked before any write -----------------------
for bad in "" "{}
{}" "{ oops" "[]"; do
  T=$(mktarget "t17-$(echo "$bad" | cksum | tr -d ' ')")
  mkdir -p "$T/.claude"
  printf '%s' "$bad" > "$T/.claude/settings.json"
  H0=$(treehash "$T")
  setup "$T"
  [ "$RC" = 2 ] || fail "17: a settings.json of '$bad' exited $RC, expected 2"
  has "is not a single JSON object" || fail "17: the refusal does not name settings.json"
  [ "$(treehash "$T")" = "$H0" ] || fail "17: a refused run wrote something for '$bad'"
done
# A plain `{}` is the valid minimum, and an absent file starts the merge from one.
T=$(mktarget t17ok)
mkdir -p "$T/.claude"
printf '{}\n' > "$T/.claude/settings.json"
setup "$T"
[ "$RC" = 3 ] || fail "17: a valid empty object exited $RC, expected 3"
jq -e '.permissions.allow | length == 24' "$T/.claude/settings.json" >/dev/null \
  || fail "17: the merge did not run on a valid {}"

# ---- (18) the egress guard joins the project's exact Bash entry; a non-blocking one is a conflict
T=$(mktarget t18)
mkdir -p "$T/.claude"
printf '.agents/team/\n' > "$T/.gitignore"
jq -n --arg g 'bash "$CLAUDE_PROJECT_DIR/.claude/hooks/guard-push.sh"' \
  --arg e 'bash "$CLAUDE_PROJECT_DIR/.claude/hooks/guard-team-egress.sh"' \
  '{hooks: {PreToolUse: [{matcher: "Bash|Edit", hooks: []}, {matcher: "Bash", hooks: [{type: "command", command: $g}]},
     {matcher: "WebFetch", hooks: [{type: "command", command: $e}]}]}}' > "$T/.claude/settings.json"
setup "$T"
has 'conflict settings.json E: WebFetch registers guard-team-egress without "onFailure": "block"' \
  || fail "18: a non-blocking egress registration is not a conflict"
S="$T/.claude/settings.json"
jq -e '.hooks.PreToolUse[1] | .matcher == "Bash" and (.hooks | length == 3)
  and (.hooks[0].command | test("guard-push")) and (.hooks[1].onFailure == "block")
  and (.hooks[2].command | test("guard-destructive-sql")) and (.hooks[2].onFailure == "block")' "$S" >/dev/null \
  || fail "18: the guard did not join the exact Bash entry after the project's hook"
[ "$(jq '.hooks.PreToolUse[0].hooks | length' "$S")" = 0 ] || fail "18: the guard joined Bash|Edit"
[ "$(egress "$S" Bash)" = 1 ] && [ "$(egress "$S" WebFetch)" = 1 ] || fail "18: registration counts"
grep -qxF '.agents/agent-mail/' "$T/.gitignore" && [ "$(grep -c '^.agents/team/$' "$T/.gitignore")" = 1 ] \
  || fail "18: only the missing ignore line is appended"
cp "$S" "$WORK/s18"
setup "$T"
[ "$(egress "$S" Bash)" = 1 ] && [ "$(egress "$S" WebFetch)" = 1 ] || fail "18: the rerun duplicated it"
! has "conflict settings.json E" || fail "18: the rerun still reports the conflict"
cmp -s "$S" "$WORK/s18" || fail "18: the rerun changed settings.json"

# ---- (19) team-watch hooks: idempotent; an async W or a startup-only W is a conflict -------------
T=$(mktarget t19)
mkdir -p "$T/.claude"
echo '{"teams":{}}' > "$T/.claude/project-profile.json"
W='bash "$CLAUDE_PROJECT_DIR/.claude/hooks/team-watch-session.sh"'
setup "$T"; S="$T/.claude/settings.json"; cp "$S" "$WORK/s19"
setup "$T"
has "kept	generated	.claude/settings.json" || fail "19: the rerun did not keep settings.json"
cmp -s "$S" "$WORK/s19" || fail "19: the rerun changed settings.json"
[ "$(jq '[.hooks.SessionStart[].hooks[] | select(.command | test("session-registry.sh"))] | length' "$S")" = 1 ] \
  || fail "19: the rerun did not keep exactly one L hook"
for bad in '{type: "command", command: $w, async: true}' 'startup'; do
  if [ "$bad" = startup ]; then
    jq -n --arg w "$W" '{hooks: {SessionStart: [{matcher: "startup",
      hooks: [{type: "command", command: $w, timeout: 5}]}]}}' > "$S"
    want='conflict settings.json W: matcher "startup" does not cover startup, resume, clear, compact'
  else
    jq -n --arg w "$W" "{hooks: {SessionStart: [{hooks: [$bad]}]}}" > "$S"
    want="conflict settings.json W: registered with async: true"
  fi
  setup "$T"
  [ "$RC" = 1 ] && has "$want" || fail "19: a mis-registered W ($bad) is not a conflict"
  [ "$(jq '[.hooks.SessionStart[].hooks[] | select(.command | test("team-watch-session"))
    | select(.timeout == 5 and (.async // false) == false)] | length' "$S")" -ge 1 ] \
    || fail "19: the correct W was not added next to the conflict ($bad)"
done

# ---- (20) core prerequisites: never a harness on top of a missing or stale adapter/profile -------
for c in missing stale; do
  T=$(mktarget "core-$c")
  if [ "$c" = missing ]; then rm -f "$T/.claude/lib/team-profile.sh"
  else echo '# an older copy' >> "$T/.claude/lib/team-tracker.sh"; fi
  before=$(treehash "$T")
  setup "$T"
  [ "$RC" = 2 ] || fail "20: a $c core file: exit $RC, expected 2"
  if [ "$c" = missing ]; then has "core file .claude/lib/team-profile.sh is missing" \
    || fail "20: the refusal does not name the missing core file"
  else has "core file .claude/lib/team-tracker.sh differs from the starter's" \
    || fail "20: the refusal does not name the stale core file"; fi
  has "sync-from-starter" || fail "20: the refusal does not say how to fix it"
  [ "$(treehash "$T")" = "$before" ] || fail "20: a refused install ($c) wrote to the target"
done
# … the destructive-SQL classifier is core too (sqlcmd-write.sh and the team guards import it)
T=$(mktarget core-classifier)
rm -f "$T/.claude/hooks/lib/guard_destructive_sql.py"
before=$(treehash "$T")
setup "$T"
[ "$RC" = 2 ] && has "core file .claude/hooks/lib/guard_destructive_sql.py is missing" \
  || fail "20: a missing classifier is not refused: $RC"
[ "$(treehash "$T")" = "$before" ] || fail "20: a refused install (classifier) wrote to the target"
T=$(mktarget core-current)
setup "$T" --check
[ "$RC" != 2 ] || fail "20: current core files are refused: $(cat "$WORK/out")"

# ---- (21) a project without teams has every file the core tracker commands call -----------------
# The tree a sync gives a project that never installed the harness: the starter's tracked files
# minus every manifest own/shared path and the tests, and directly in .claude/lib/ only what the
# playbook's category A routes there (*.sh, *.mjs, never *.test.mjs). The sync itself is prose this
# cannot run; this checks that the routing rule carries the commands' whole closure.
D="$WORK/solo"; mkdir -p "$D"
while IFS= read -r p; do
  case "$p" in */tests/*|*.test.mjs) continue ;; esac
  grep -qxF "own $p" "$MANIFEST" && continue
  grep -qxF "shared $p" "$MANIFEST" && continue
  case "$p" in .claude/lib/*/*) ;; .claude/lib/*.sh|.claude/lib/*.mjs) ;; .claude/lib/*) continue ;; esac
  mkdir -p "$D/$(dirname "$p")"; cp "$ST/$p" "$D/$p"
done < <(git -C "$ST" ls-files)
git -C "$D" init --quiet
for f in team-tracker.sh team-profile.sh github-sync.mjs backlog-check.mjs yaml-subset.mjs; do
  [ -f "$D/.claude/lib/$f" ] || fail "21: a project without teams lacks .claude/lib/$f"
done
jq -n '{schema: 1, tracker: "github", github: {repo: "owner/repo"}}' > "$D/.claude/project-profile.json"
set +e; (cd "$D" && bash .claude/lib/team-tracker.sh set-status 7 started) > "$WORK/out" 2>&1; RC=$?; set -e
[ "$RC" = 0 ] && has "skipped (no project)" || fail "21: the adapter does not load without teams (exit $RC)"
set +e; (cd "$D" && node -e "import('./.claude/lib/github-sync.mjs').then(() => {}, (e) => { console.error(e.message); process.exit(1) })") \
  > "$WORK/out" 2>&1; RC=$?; set -e
[ "$RC" = 0 ] || fail "21: github-sync.mjs does not resolve its imports without teams"
# Every .claude/lib file these commands name ships too — except the two /tasks-status reads only
# with a `teams` block (team columns are dropped without one).
for c in start-task pr-create github-sync tasks-status; do
  for f in $(grep -oE '\.claude/lib/[A-Za-z0-9_.-]+\.(sh|mjs|py)' "$ST/.claude/commands/$c.md" | sort -u); do
    case "$f" in .claude/lib/team-snapshot.sh|.claude/lib/team-pr.sh) continue ;; esac
    [ -f "$D/$f" ] || fail "21: /$c names $f, which a project without teams does not get"
  done
done

# The stage-end step every core pipeline command runs is silent there: exit 0, nothing on stdout or
# stderr, no file — without $AGENT_COSTS_HOME, and with it but without jq on PATH.
for c in prime brainstorm plan-feature execute check-implementation qa-verify pr-create orchestrate quick-change; do
  grep -qxF "\`bash .claude/lib/costs/runtime-mark.sh stage end $c\`" "$ST/.claude/commands/$c.md" \
    || fail "21: /$c has no exact stage end step"
done
NOJQ="$WORK/nojq-bin"; mkdir -p "$NOJQ"; ln -s /bin/bash "$NOJQ/bash"
for costs in absent present; do
  CH="$WORK/costs-home-$costs"; rm -rf "$CH"; [ "$costs" = absent ] || mkdir -p "$CH"
  before=$(treehash "$D"); before_ch=$([ -d "$CH" ] && ls -A "$CH" || echo none)
  set +e; (cd "$D" && env -i HOME="$WORK/solo-home" PATH="$NOJQ" AGENT_COSTS_HOME="$CH" \
    bash .claude/lib/costs/runtime-mark.sh stage end prime) > "$WORK/out" 2> "$WORK/err"; RC=$?; set -e
  [ "$RC" = 0 ] && [ ! -s "$WORK/out" ] && [ ! -s "$WORK/err" ] \
    || fail "21: stage end with costs home $costs is not silent (exit $RC): $(cat "$WORK/err")"
  [ "$(treehash "$D")" = "$before" ] && [ ! -e "$WORK/solo-home" ] \
    && [ "$(ls -A "$CH" 2>/dev/null || echo none)" = "$before_ch" ] \
    || fail "21: stage end with costs home $costs created a file"
done
# The core settings allow only that step: no stage hook (team-setup registers it), and the narrow
# rule matches the end step but no other writer call. Claude Code's own matcher is not available
# offline; a shell glob is the same `*` semantics (any characters, spaces included).
[ "$(jq '[.hooks[]?[]?.hooks[]? | select((.command // "") | test("stage-mark"))] | length' \
  "$ST/.claude/settings.json")" = 0 ] || fail "21: the starter's core settings register the stage hook"
NARROW='Bash(bash .claude/lib/costs/runtime-mark.sh stage end *)'
[ "$(jq --arg r "$NARROW" '[.permissions.allow[] | select(test("runtime-mark"))] == [$r]' \
  "$ST/.claude/settings.json")" = true ] || fail "21: the core runtime-mark allow is not exactly the narrow rule"
pat=${NARROW#Bash(}; pat=${pat%)}
for cmd in "bash .claude/lib/costs/runtime-mark.sh stage start prime --session x --source hook-skill" \
  "bash .claude/lib/costs/runtime-mark.sh session --provider claude --source team-run" \
  "bash .claude/lib/costs/runtime-mark.sh stage endx"; do
  # shellcheck disable=SC2053
  [[ "$cmd" != $pat ]] || fail "21: the narrow allow covers '$cmd'"
done
# shellcheck disable=SC2053
[[ "bash .claude/lib/costs/runtime-mark.sh stage end prime" == $pat ]] \
  || fail "21: the narrow allow does not cover the end step"

# ---- (22) stage hook: an async or unfiltered existing registration is a conflict, kept, fixed ----
T=$(mktarget t22)
mkdir -p "$T/.claude"
SM='bash "$CLAUDE_PROJECT_DIR/.claude/hooks/stage-mark.sh"'
jq -n --arg s "$SM" '{hooks: {PreToolUse: [
   {matcher: "Skill", hooks: [{type: "command", command: $s, async: true}]},
   {matcher: "Bash", hooks: [{type: "command", command: $s}]}]}}' > "$T/.claude/settings.json"
setup "$T"
S="$T/.claude/settings.json"
has "conflict settings.json K: PreToolUse Skill registers stage-mark async" \
  || fail "22: an async stage hook is not a conflict"
has "conflict settings.json B: PreToolUse Bash registers stage-mark async or without the filter" \
  || fail "22: a stage hook without the end-step filter is not a conflict"
[ "$(stage "$S" PreToolUse Skill '')" = 1 ] && [ "$(stage "$S" PreToolUse Bash "$END_IF")" = 1 ] \
  || fail "22: the correct entries were not added next to the conflicts"
jq -e '.hooks.PreToolUse[0].hooks[0].async == true and (.hooks.PreToolUse[1].hooks[0] | has("if") | not)' \
  "$S" >/dev/null || fail "22: the project's entries were rewritten"
cp "$S" "$WORK/s22"
setup "$T"
cmp -s "$S" "$WORK/s22" || fail "22: the rerun changed settings.json"

# ---- (23) session-host state hook: once per event, synchronous; a fresh target writes state ------
NT='permission_prompt|idle_prompt|elicitation_dialog|agent_needs_input'
tstat() {  # tstat <settings> <event> <matcher|''> → how many correct team-status entries
  jq --arg ev "$2" --arg m "$3" '[.hooks[$ev][]? | select((.matcher // "") == $m) | .hooks[]
    | select((.command | test("team-status.sh")) and .timeout == 3 and (.async // false) == false)] | length' "$1"
}
T=$(mktarget t23)
setup "$T"
S="$T/.claude/settings.json"
[ -f "$T/.claude/hooks/team-status.sh" ] || fail "23: team-status.sh was not installed"
for e in "PostToolUse:" "Notification:$NT" "UserPromptSubmit:" "Stop:" "SessionEnd:"; do
  [ "$(tstat "$S" "${e%%:*}" "${e#*:}")" = 1 ] || fail "23: team-status is not registered once, synchronous, under ${e%%:*}"
  [ "$(tstat "$ST/.claude/settings.json" "${e%%:*}" "${e#*:}")" = 1 ] \
    || fail "23: the starter's own settings do not register team-status synchronously under ${e%%:*}"
done
[ "$(jq '[.hooks[]?[]?.hooks[]? | select(.command | test("team-status.sh"))] | length' "$S")" = 5 ] \
  || fail "23: team-status.sh is registered more than 5 times"
# State transitions through the target's own registrations only (TMUX unset: no OSC job).
REG="$WORK/reg23"; mkdir -p "$REG"
echo '{"address": "alfa-coder", "session_id": "s-new"}' > "$REG/alfa-coder.json"
fire() {  # fire <event> <session id> [notification type]
  local m='' cmd p
  [ "$1" != Notification ] || m="$NT"
  cmd="$(jq -r --arg ev "$1" --arg m "$m" '[.hooks[$ev][]? | select((.matcher // "") == $m) | .hooks[]
    | select(.command | test("team-status.sh")) | .command][0] // empty' "$S")"
  [ -n "$cmd" ] || fail "23: no team-status registration for $1"
  p="{\"hook_event_name\": \"$1\", \"session_id\": \"$2\", \"transcript_path\": \"/t/$2.jsonl\"${3:+, \"notification_type\": \"$3\"}}"
  printf '%s' "$p" | (cd "$T" && env -u TMUX -u TMUX_PANE CLAUDE_PROJECT_DIR="$T" HARNESS_REGISTRY="$REG" \
    HARNESS_ADDRESS=alfa-coder HARNESS_BACKEND=tmux bash -c "$cmd") || fail "23: the hook failed on $1"
}
st() { jq -r '.state + "/" + (.kind // "-") + "/" + .session_id' "$REG/state/alfa-coder.json" 2>/dev/null || echo none; }
fire UserPromptSubmit s-new; [ "$(st)" = working/-/s-new ] || fail "23: UserPromptSubmit gave $(st)"
fire Notification s-new permission_prompt; [ "$(st)" = blocked/permission/s-new ] || fail "23: permission_prompt gave $(st)"
fire PostToolUse s-new; [ "$(st)" = working/-/s-new ] || fail "23: PostToolUse gave $(st)"
fire Stop s-new; [ "$(st)" = done/-/s-new ] || fail "23: Stop gave $(st)"
fire UserPromptSubmit s-old; [ "$(st)" = done/-/s-new ] || fail "23: a stale session's write was not ignored: $(st)"
fire SessionEnd s-old; [ "$(st)" = done/-/s-new ] || fail "23: an old SessionEnd after a relaunch removed the state"
fire SessionEnd s-new; [ "$(st)" = none ] || fail "23: SessionEnd left the state file"
# An existing async registration is a conflict: kept, and a synchronous entry is added; the rerun is a no-op.
T=$(mktarget t23b)
mkdir -p "$T/.claude"
TS='bash "$CLAUDE_PROJECT_DIR/.claude/hooks/team-status.sh"'
jq -n --arg s "$TS" '{hooks: {PostToolUse: [{hooks: [{type: "command", command: $s, async: true}]}]}}' \
  > "$T/.claude/settings.json"
setup "$T"
S="$T/.claude/settings.json"
has "conflict settings.json T: PostToolUse registers team-status async" || fail "23: an async state hook is not a conflict"
[ "$(tstat "$S" PostToolUse '')" = 1 ] || fail "23: no synchronous entry next to the conflict"
jq -e '.hooks.PostToolUse[0].hooks[0].async == true' "$S" >/dev/null || fail "23: the project's entry was rewritten"
cp "$S" "$WORK/s23"
setup "$T"
cmp -s "$S" "$WORK/s23" || fail "23: the rerun changed settings.json"

# ---- (24) session registry: the old TeamLead hook is retired, a foreign look-alike stays ----------
T=$(mktarget t24)
mkdir -p "$T/.claude"
OLD='bash "$CLAUDE_PROJECT_DIR/.claude/hooks/teamlead-register.sh"'
FOREIGN='bash "$CLAUDE_PROJECT_DIR/tools/teamlead-register.sh"'
jq -n --arg o "$OLD" --arg f "$FOREIGN" '{hooks: {SessionStart: [
   {matcher: "startup|resume|clear|compact", hooks: [{type: "command", command: $o, timeout: 5}]},
   {matcher: "startup", hooks: [{type: "command", command: $f}, {type: "command", command: $o}]}]}}' \
  > "$T/.claude/settings.json"
setup "$T"
S="$T/.claude/settings.json"
has "retired settings.json: teamlead-register.sh" || fail "24: the old hook was not retired"
[ "$(jq --arg o "$OLD" '[.hooks[]?[]?.hooks[]? | select(.command == $o)] | length' "$S")" = 0 ] \
  || fail "24: the old hook is still registered"
[ "$(jq --arg f "$FOREIGN" '[.hooks[]?[]?.hooks[]? | select(.command == $f)] | length' "$S")" = 1 ] \
  || fail "24: a foreign hook whose path contains teamlead-register was dropped"
[ "$(jq '[.hooks.SessionStart[] | select((.hooks | length) == 0)] | length' "$S")" = 0 ] \
  || fail "24: an emptied entry was left behind"
jq -e '[.hooks.SessionStart[] | .hooks[] | select((.command | test("session-registry.sh")) and .timeout == 5)]
    | length == 1' "$S" >/dev/null \
  || fail "24: session-registry.sh is not registered once"
jq -e '[.hooks.UserPromptSubmit[] | .hooks[] | select((.command | test("inbox-count.sh")) and .timeout == 3
    and (.async // false) == false)] | length == 1' "$S" >/dev/null || fail "24: inbox-count.sh is not registered once"
jq -e '[.hooks.SessionEnd[] | select(has("matcher") | not) | .hooks[]
    | select((.command | test("session-registry.sh")) and .timeout == 5 and (.async // false) == false)]
    | length == 1' "$S" >/dev/null || fail "24: session-registry.sh is not registered once on SessionEnd"
jq -e '[.hooks.SessionEnd[] | .hooks[] | select(.command | test("session-registry.sh"))] | length == 1' \
  "$ST/.claude/settings.json" >/dev/null || fail "24: the starter's own settings lack the SessionEnd registry hook"
[ -f "$T/.claude/hooks/session-registry.sh" ] && [ -f "$T/.claude/hooks/inbox-count.sh" ] \
  && [ ! -e "$T/.claude/hooks/teamlead-register.sh" ] || fail "24: hook files"
setup "$T"
! has "retired settings.json" || fail "24: the rerun retired again"
jq -e '[.hooks[]?[]?.hooks[]? | select(.command | test("teamlead-register"))] | length == 1' \
  "$ST/.claude/settings.json" >/dev/null && fail "24: the starter's own settings still register teamlead-register"
true

# ---- (25) roles: the old session-role.sh hook is retired; a fresh target has what /roles needs ---
T=$(mktarget t25)
mkdir -p "$T/.claude"
OLD='bash "$CLAUDE_PROJECT_DIR/.claude/hooks/session-role.sh"'
FOREIGN='bash "$CLAUDE_PROJECT_DIR/tools/my-session-role.sh"'
jq -n --arg o "$OLD" --arg f "$FOREIGN" '{hooks: {SessionStart: [
   {hooks: [{type: "command", command: $o, timeout: 5}]},
   {matcher: "startup", hooks: [{type: "command", command: $f}]}]}}' > "$T/.claude/settings.json"
echo '{"teams":{}}' > "$T/.claude/project-profile.json"
setup "$T"
S="$T/.claude/settings.json"
has "retired settings.json: session-role.sh" || fail "25: the old hook was not retired"
[ "$(jq --arg o "$OLD" '[.hooks[]?[]?.hooks[]? | select(.command == $o)] | length' "$S")" = 0 ] \
  || fail "25: the old hook is still registered"
[ "$(jq --arg f "$FOREIGN" '[.hooks[]?[]?.hooks[]? | select(.command == $f)] | length' "$S")" = 1 ] \
  || fail "25: a foreign hook whose path contains session-role was dropped"
for f in .claude/lib/roles.sh .claude/lib/roles-lib.sh .claude/commands/roles.md \
  .claude/team/sessions/Advisor.settings.json .agents/reference/roles/supervisor.md \
  .agents/reference/roles/advisor.md; do
  [ -f "$T/$f" ] || fail "25: $f not installed"
done
[ ! -e "$T/.claude/hooks/session-role.sh" ] || fail "25: session-role.sh installed"
# agent-mail is an optional kit (#52): installing the team layer writes nothing under ~/.agent-mail.
[ ! -e "$HOME/.agent-mail" ] || fail "25: the install created ~/.agent-mail"
# Without teams.sessions the shipped roles apply: their contracts and templates are all there.
(cd "$T" && ROLES_ROOT="$T" bash -c '. .claude/lib/roles-lib.sh && roles_validate && roles_list --standing') \
  > "$WORK/out" 2>&1 || fail "25: the shipped roles do not validate in a fresh target"
[ "$(tr '\n' ' ' < "$WORK/out")" = "Supervisor Fable Astra " ] || fail "25: standing roles: $(cat "$WORK/out")"
setup "$T"
! has "retired settings.json" || fail "25: the rerun retired again"
jq -e '[.hooks[]?[]?.hooks[]? | select(.command | test("session-role"))] | length == 0' \
  "$ST/.claude/settings.json" >/dev/null || fail "25: the starter's own settings still name session-role"

# ---- (26) retired files: an unchanged shipped version is deleted, a changed one stays a conflict ---
# The five deprecated /roles pointers (step 9a-1) are `retired` manifest lines with the blob ids of
# the versions the starter shipped. So are the allow/ask rules for the launcher verbs 9a removed.
T=$(mktarget t26)
mkdir -p "$T/.claude/commands"
RET=$(sed -n 's/^retired \([^ ]*\) .*/\1/p' "$MANIFEST")
[ "$(printf '%s\n' "$RET" | grep -c .)" = 5 ] || fail "26: the manifest does not retire the five commands"
for p in $RET; do
  [ ! -e "$ST/$p" ] || fail "26: $p is retired but still in the starter"
  grep -qxF "own $p" "$MANIFEST" && fail "26: $p is both retired and own"
  b=$(sed -n "s|^retired $p ||p" "$MANIFEST"); b=${b##* }   # the last id listed: the newest shipped version
  git -C "$ST" cat-file blob "$b" > "$T/$p" 2>/dev/null || fail "26: $p: blob $b is not in the starter's history"
done
printf 'my own notes\n' >> "$T/.claude/commands/mail-role.md"   # a project edit: never deleted
SSA="Bash(bash .claude/lib/supervisor-sessions.sh"
jq -n --arg a "$SSA up*)" --arg b "$SSA start *)" --arg h "$SSA here *)" --arg m "$SSA up --mine)" \
  '{permissions: {allow: [$a, $b, $m], ask: [$h]}}' > "$T/.claude/settings.json"
echo '{"teams":{}}' > "$T/.claude/project-profile.json"
H0=$(treehash "$T")
setup "$T" --check
[ "$RC" = 1 ] || fail "26: --check exited $RC, expected 1 (the edited command is a conflict)"
[ "$(field remove retired)" = 4 ] || fail "26: --check does not plan 4 removals"
[ "$(treehash "$T")" = "$H0" ] || fail "26: --check wrote something"
setup "$T"
[ "$RC" = 1 ] || fail "26: install exited $RC, expected 1"
[ "$(field removed retired)" = 4 ] || fail "26: not 4 retired files removed"
has "conflict (retired — changed locally; delete or keep it by hand)	retired	.claude/commands/mail-role.md" \
  || fail "26: the edited retired file is not a conflict"
has "removed=4" || fail "26: the summary does not count the removals"
for p in $RET; do
  case "$p" in */mail-role.md) [ -f "$T/$p" ] || fail "26: the edited $p was deleted" ;;
    *) [ ! -e "$T/$p" ] || fail "26: $p was not deleted" ;; esac
done
S="$T/.claude/settings.json"
[ "$(jq -c --arg p "$SSA" '[.permissions.allow[], .permissions.ask[]]
  | map(select(startswith($p) and test("sh (start|stop|status|up|here)")))' "$S")" \
  = "[\"$SSA up --mine)\"]" ] || fail "26: the removed verbs' rules were not retired (or a project rule was)"
setup "$T"
[ "$(field removed)" = 0 ] && has "conflict (retired — changed locally; delete or keep it by hand)	retired	.claude/commands/mail-role.md" \
  || fail "26: the rerun is not stable"
# A retired path still in the starter, or one that is also shipped, is manifest drift.
Z40=0000000000000000000000000000000000000000
touch "$FS/.claude/team/ok" "$FS/.claude/team/x"
printf 'own .claude/team/ok\nretired .claude/team/x %s\n' "$Z40" > "$FS/.claude/team/manifest.txt"
fake_setup "$T"; [ "$RC" = 2 ] && has "still exists in the starter" || fail "26: a retired path in the starter is not drift"
printf 'own .claude/team/ok\nretired .claude/team/ok %s\n' "$Z40" > "$FS/.claude/team/manifest.txt"
fake_setup "$T"; [ "$RC" = 2 ] && has "still exists in the starter" || fail "26: a shipped and retired path is not drift"
printf 'own .claude/team/ok\nretired .claude/commands/nope.md not-a-blob-id\n' > "$FS/.claude/team/manifest.txt"
fake_setup "$T"; [ "$RC" = 2 ] && has "is not a blob id" || fail "26: a bad blob id is not drift"

echo "team-setup-smoke: OK"
