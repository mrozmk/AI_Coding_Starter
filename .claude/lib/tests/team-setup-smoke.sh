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
S="$T/.claude/settings.json"
jq -e '[.hooks.PreToolUse[] | select(.matcher | split("|") | index("AskUserQuestion")) | .hooks[]
  | select(.command | test("guard-team-question"))] | length == 1' "$S" >/dev/null \
  || fail "2: no PreToolUse/AskUserQuestion hook Q"
jq -e '[.hooks.PreToolUse[] | select(.matcher | split("|") as $t | ($t | index("Edit"))
  and ($t | index("Write"))) | .hooks[] | select(.command | test("guard-team-memory"))]
  | length == 1' "$S" >/dev/null || fail "2: no PreToolUse Edit+Write hook M"
jq -e '[.hooks.Notification[] | select(.matcher | split("|") | index("permission_prompt"))
  | .hooks[] | select((.command | test("team-attention")) and .async == true)] | length == 1' \
  "$S" >/dev/null || fail "2: no async Notification hook A"
[ "$(jq '.permissions.allow | length' "$S")" = 9 ] || fail "2: allow is not the 9 role rules"
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
  "$S")" = 2 ] || fail "6: M added a PreToolUse entry of its own"
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
[ "$(jq '[.hooks.PostToolUse[].hooks[]] | length' "$S")" = 1 ] || fail "7: the foreign entry was touched"
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
[ "$(jq '.permissions.allow | length' "$S")" = 11 ] || fail "10: allow is not 2 project + 9 role rules"
cmp -s "$WORK/local.before" "$T/.claude/settings.local.json" || fail "10: settings.local.json changed"

# ---- (11) manifest completeness: nothing in the harness trees is left behind ---------------------
while IFS= read -r p; do
  case "$p" in */tests/*) continue ;; esac
  grep -qxF "own $p" "$MANIFEST" || grep -qxF "shared $p" "$MANIFEST" \
    || fail "11: $p is in the harness tree but not in the manifest"
done < <(git -C "$ST" ls-files '.claude/lib/team-*.sh' .claude/team .claude/dashboard \
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
jq -e '.permissions.allow | length == 9' "$T/.claude/settings.json" >/dev/null \
  || fail "14: settings.json was not written"
[ -L "$T/.claude/settings.json.team-setup.tmp" ] || fail "14: the planted symlink was consumed"
[ -z "$(ls "$T/.claude"/.team-setup.* 2>/dev/null)" ] || fail "14: a temp file was left behind"

# ---- (15) no write may pass through a symlinked target component -------------------------------
T=$(mktarget t15a)
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
jq -e '.permissions.allow | length == 9' "$T/.claude/settings.json" >/dev/null \
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

echo "team-setup-smoke: OK"
