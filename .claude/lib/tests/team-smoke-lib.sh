#!/usr/bin/env bash
# Shared offline fixtures; each suite part owns its workspace and EXIT cleanup.
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SRC=$(cd "$HERE/../../.." && pwd)

fail() { echo "team-smoke: FAIL — $*"; [ ! -f "$WORK/out" ] || sed 's/^/  | /' "$WORK/out"; exit 1; }
has() { grep -qF -- "$1" "$2"; }
run() {  # run <dir> <cmd...> → RC, $WORK/out
  local d="$1"; shift
  set +e; (cd "$d" && "$@") > "$WORK/out" 2>&1; RC=$?; set -e
}
expect() {  # expect <rc> <text> <label>
  [ "$RC" = "$1" ] || fail "$3: exit $RC, expected $1"
  [ -z "$2" ] || has "$2" "$WORK/out" || fail "$3: output lacks '$2'"
}

session() {  # session <role> <attempt> <input_rev>
  jq -n --arg role "$1" --argjson attempt "$2" --arg input "$3" --arg run "$RUN_ID" \
    '{team: "alfa", role: $role, run: $run, attempt: $attempt, ticket: "TT-790",
      input_rev: $input, launched_at: "2026-10-02T00:00:00Z"}' > "$TD/session.json"
}
hook() { set +e; printf '%s' "$2" | CLAUDE_PROJECT_DIR="$1" bash "$HOOK" > "$WORK/out" 2>&1; RC=$?; set -e; }
commit_file() {  # commit_file <path> <content>
  mkdir -p "$CLONE/$(dirname "$1")"; printf '%s\n' "$2" > "$CLONE/$1"
  git -C "$CLONE" add "$1" && git -C "$CLONE" commit --quiet -m "add $1"
}
pr_json() {  # pr_json <isDraft> <source sha> [mergeStatus] [target ref] [target sha]
  jq -n --argjson d "$1" --arg s "$2" --arg ms "${3:-succeeded}" --arg t "${4:-refs/heads/develop-netcore7}" \
    --arg ts "${5:-$BASE}" \
    '{pullRequestId: 8371, status: "active", isDraft: $d, mergeStatus: $ms,
      repository: {name: "fixture"}, sourceRefName: "refs/heads/feature/TT-790-x", targetRefName: $t,
      lastMergeSourceCommit: {commitId: $s}, lastMergeTargetCommit: {commitId: $ts},
      lastMergeCommit: {commitId: (env.MERGE_SHA // "")}}' > "$STUB_PR"
}
record() { (cd "$CLONE" && $REC "$@") | tail -n 1; }

# Run fixtures for parts 2 and 3; they use the part's BR, TGT0, RUN_ID and RD.
pr_w() {  # pr_w <source sha> [target sha] — the PR of the clone's current branch
  pr_json false "$1" succeeded refs/heads/develop-netcore7 "${2:-$TGT0}"
  jq --arg b "refs/heads/$BR" '.sourceRefName = $b' "$STUB_PR" > "$WORK/pw.json" && mv "$WORK/pw.json" "$STUB_PR"
}
mkrec() {  # mkrec <role> <output sha> [verdict] — an accepted record in this run
  jq -n --arg role "$1" --arg rev "$2" --arg run "$RUN_ID" --arg v "${3:-done}" \
    --arg t "$(jq -r .ticket "$TD/team.json")" \
    '{team: "alfa", ticket: $t, run: $run, role: $role, attempt: 1, seq: 1, branch: "x",
      input_rev: "", output_rev: $rev, verdict: $v, pr_id: 8371, artifacts: [], evidence: [],
      notes: "", message: "", written_at: "2026-10-04T00:00:00Z"}' > "$RD/$1-1-1.json"
  [ "${3:-done}" != done ] || touch "$RD/$1-1-1.json.accepted"
}
point() {  # point <sha> — clone branch and its origin tip at <sha> (fixture-only ref surgery)
  git -C "$CLONE" switch --quiet -C "$BR" "$1"
  git -C "$CLONE" push --quiet --force origin "$1:refs/heads/$BR"
}
merge_at() {  # merge_at <source sha> [target sha] — ADO's merge ref and PR state for <sha>
  git -C "$CLONE" push --quiet --force origin "$1:refs/pull/8371/merge"
  export MERGE_SHA="$1"; pr_w "$1" "${2:-$TGT0}"
}

snap() {  # snap <label> <jq condition>; `coder` = the alfa coder role object
  run "$MAIN" $SNAP --out "$WORK/snap.json"
  expect 0 "" "snapshot $1"
  jq -e "def coder: .teams[] | select(.team == \"alfa\") | .roles[] | select(.role == \"coder\"); $2" \
    "$WORK/snap.json" >/dev/null || { jq . "$WORK/snap.json" > "$WORK/out" 2>&1; fail "snapshot $1: $2"; }
}

smoke_init() {
  WORK=$(mktemp -d)
  SPID=""
  trap '[ -z "$SPID" ] || kill "$SPID" 2>/dev/null || true; rm -rf "$WORK"' EXIT
  REAL_GIT=$(command -v git)
  ADO_URL=https://dev.azure.com/fixture/_git/fixture
  export STUB_LOG="$WORK/log" STUB_PR="$WORK/pr.json" REAL_GIT ADO_URL
  export GIT_CONFIG_GLOBAL="$WORK/gitconfig" GIT_CONFIG_NOSYSTEM=1
  # The runner resolves .claude/codex-profile against HOME; keep it hermetic (TT-912).
  export HOME="$WORK/home"
  mkdir -p "$HOME/.codex-taketask"
  export TEAM_NOTIFY=0 TEAM_POLL_SECS=0 TEAM_ADO_WAIT_SECS=0 TEAM_ADO_POLL_SECS=1
  export TEAM_EXIT_WAIT_SECS=0 TEAM_STOP_WAIT_SECS=1 TEAM_ATTACH_POLL=0
  unset CLAUDE_PROJECT_DIR
  smoke_gitconfig
  smoke_stubs
  smoke_git_stub
  chmod +x "$WORK/bin/"*
  export PATH="$WORK/bin:$PATH"
  smoke_repos
  REC="bash .claude/lib/team-record.sh"
  TR="bash .claude/lib/team-run.sh"
  HOOK="$SRC/.claude/hooks/guard-team-memory.sh"
  SNAP="bash .claude/lib/team-snapshot.sh"
}

smoke_gitconfig() {
  cat > "$GIT_CONFIG_GLOBAL" <<EOF
[user]
  name = smoke
  email = smoke@example.invalid
[init]
  defaultBranch = develop-netcore7
[advice]
  detachedHead = false
[url "$WORK/origin.git"]
  insteadOf = $ADO_URL
EOF

}

smoke_stubs() {
  mkdir -p "$WORK/bin"
  for t in claude codex dotnet; do
  printf '#!/usr/bin/env bash\necho "%s $*" >> "$STUB_LOG"\n' "$t" > "$WORK/bin/$t"
  done
  # STUB_OSA_OUT plays the tty `do script` returns; empty → team-attach takes its warn path.
  printf '#!/usr/bin/env bash\necho "osascript $*" >> "$STUB_LOG"\n[ -z "${STUB_OSA_OUT:-}" ] || echo "$STUB_OSA_OUT"\n' > "$WORK/bin/osascript"
  cat > "$WORK/bin/tmux" <<'STUB'
#!/usr/bin/env bash
echo "tmux $*" >> "$STUB_LOG"
if [ "$1" = has-session ]; then
  gone="can't find session: ${3#=}"
  [ "${STUB_TMUX_ALIVE:-1}" = 0 ] || echo "${STUB_TMUX_ERR:-$gone}" >&2
  exit "${STUB_TMUX_ALIVE:-1}"
fi
# Real tmux finds no pane for `-t =NAME` (session-only form); pane commands need `=NAME:`.
case "$1 $*" in capture-pane*" -t ="*|send-keys*" -t ="*) case "$*" in *" -t ="*:*) ;;
  *) echo "can't find pane" >&2; exit 1 ;; esac ;; esac
[ "$1" != capture-pane ] || [ -z "${STUB_PANE:-}" ] || cat "$STUB_PANE"
STUB
  cat > "$WORK/bin/az" <<'STUB'
#!/usr/bin/env bash
echo "az $*" >> "$STUB_LOG"
case "$*" in
  "account show"*) echo '{}' ;;
  "repos pr show"*) [ -z "${STUB_AZ_SLEEP:-}" ] || sleep "$STUB_AZ_SLEEP"
    [ -z "${STUB_TOUCH:-}" ] || touch "$STUB_TOUCH"; cat "$STUB_PR" ;;
  *) exit 1 ;;
esac
STUB
}

smoke_git_stub() {
  # `git remote get-url` must show the ADO URL while transport uses the local bare repo.
  cat > "$WORK/bin/git" <<'STUB'
#!/usr/bin/env bash
a=("$@")
[ "${1:-}" != -C ] || shift 2
if [ "${1:-} ${2:-} ${3:-}" = "remote get-url origin" ]; then echo "$ADO_URL"; exit 0; fi
exec "$REAL_GIT" "${a[@]}"
STUB
}

smoke_repos() {
  git init --quiet --bare "$WORK/origin.git"
  SEED="$WORK/seed"
  mkdir -p "$SEED/.claude/lib" "$SEED/.claude/hooks" "$SEED/.claude/team/prompts"
  cp "$SRC"/.claude/lib/team-*.sh "$SEED/.claude/lib/"
  cp "$SRC/.claude/lib/worker-next.sh" "$SEED/.claude/lib/"
  cp "$SRC/.claude/lib/worker-lib.sh" "$SEED/.claude/lib/"
  mkdir -p "$SEED/.agents/reference"
  cp "$SRC/.agents/reference/worker-clone.md" "$SEED/.agents/reference/"
  cp "$SRC/AGENTS.md" "$SEED/"
  cp "$SRC/.claude/hooks/guard-team-memory.sh" "$SEED/.claude/hooks/"
  # Fixture fix (starter import): team-answer.sh runs team_prompt_check.py, which imports hooks/lib.
  mkdir -p "$SEED/.claude/hooks/lib"
  cp "$SRC/.claude/lib/team_prompt_check.py" "$SEED/.claude/lib/"
  cp "$SRC"/.claude/hooks/lib/* "$SEED/.claude/hooks/lib/"
  cp "$SRC"/.claude/team/prompts/*.md "$SEED/.claude/team/prompts/"
  cp "$SRC/.claude/team/roles.json" "$SEED/.claude/team/"
  # Fixture fix (starter import): own profile, independent of the repo's (template) codex-profile.
  printf '# test fixture\n~/.codex-taketask\n' > "$SEED/.claude/codex-profile"
  printf '#!/usr/bin/env bash\necho "test-gate: total 3, passed 3, failed 0 (baseline 0, new 0, now passing 0)"\n' \
  > "$SEED/.claude/lib/test-gate.sh"
  printf '.agents/team/\n.env\n' > "$SEED/.gitignore"
  echo seed > "$SEED/README"
  git -C "$SEED" init --quiet
  git -C "$SEED" add -A && git -C "$SEED" commit --quiet -m seed
  git -C "$SEED" remote add origin "$ADO_URL"
  git -C "$SEED" push --quiet origin develop-netcore7
  git -C "$SEED" switch --quiet -c rc && git -C "$SEED" rm --quiet .claude/lib/team-record.sh
  git -C "$SEED" commit --quiet -m "no harness" && git -C "$SEED" push --quiet origin rc
  git -C "$SEED" push --quiet origin develop-netcore7:refs/heads/feature/TT-791-pushed

  git clone --quiet "$ADO_URL" "$WORK/main"
  MAIN="$WORK/main"
  echo "SECRET=x" > "$MAIN/.env"
  [ "$(git -C "$MAIN" remote get-url origin)" = "$ADO_URL" ] || fail "fixture: get-url shim"
  [ -f "$MAIN/.claude/team/prompts/qa.md" ] || fail "fixture: prompts missing"
  NEW="bash .claude/lib/team-new.sh"

}

smoke_team() {  # smoke_team <ticket> <branch>; build a fresh team via the real producer.
  chmod 600 "$MAIN/.env"
  run "$MAIN" $NEW alfa "$1" "$2" origin/develop-netcore7
  [ "$RC" = 0 ] || fail "fixture team creation"
  CLONE="$WORK/main-alfa"
  TD="$CLONE/.agents/team"
  BASE=$(git -C "$CLONE" rev-parse HEAD)
}
