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
  GH_URL=https://github.com/acme/widgets
  GH_BARE="$WORK/origin.git"
  export STUB_LOG="$WORK/log" STUB_PR="$WORK/pr.json" REAL_GIT ADO_URL GH_URL GH_BARE
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
  insteadOf = $GH_URL
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
  # `git remote get-url` must show the hosted URL while transport uses the local bare repo.
  # `SMOKE_ORIGIN=github` swaps it for the GitHub one; unset keeps smoke 1-4 on ADO, untouched.
  #
  # The integration switches below only fire on a push to an explicit `…:refs/heads/…` refspec —
  # the shape the integrator uses — so the fixtures' own `git push origin <branch>` calls stay
  # untouched. Pushes are logged to `$GIT_LOG` when that is set: a log SEPARATE from `$STUB_LOG`,
  # so the assertions of smoke 1-4 keep counting exactly what they count today.
  #   STUB_GIT_PRE_PUSH="<cmd>"    run just before the real push (a racing writer)
  #   STUB_GIT_PUSH_FAIL_AFTER=1   the push really lands, then the client gets an error
  #   STUB_GIT_PUSH_KILL=1         the push really lands, then the caller is SIGKILLed
  #   STUB_GIT_POST_PUSH="<cmd>"   run right after the real push (a writer landing on top of us)
  #   STUB_GIT_LSREMOTE_FAIL=1     every `ls-remote` fails (the network, mid-recovery)
  #   STUB_GIT_STATUS_FAIL=1       `git status` fails with EMPTY stdout (an unreadable repository)
  # `switch`/`checkout` are logged to `$GIT_LOG` as well, so a test can assert that a refused run
  # moved nothing in the clone.
  cat > "$WORK/bin/git" <<'STUB'
#!/usr/bin/env bash
a=("$@")
[ "${1:-}" != -C ] || shift 2
if [ "${1:-} ${2:-} ${3:-}" = "remote get-url origin" ]; then
  if [ "${SMOKE_ORIGIN:-ado}" = github ]; then echo "$GH_URL"; else echo "$ADO_URL"; fi
  exit 0
fi
if [ "${1:-}" = ls-remote ] && [ "${STUB_GIT_LSREMOTE_FAIL:-0}" = 1 ]; then
  echo "fatal: unable to access origin: Operation timed out" >&2
  exit 128
fi
if [ "${1:-}" = status ] && [ "${STUB_GIT_STATUS_FAIL:-0}" = 1 ]; then
  echo "fatal: not a git repository" >&2
  exit 128
fi
case "${1:-}" in
  switch|checkout) [ -z "${GIT_LOG:-}" ] || echo "git $*" >> "$GIT_LOG" ;;
esac
if [ "${1:-}" = push ]; then
  [ -z "${GIT_LOG:-}" ] || echo "git $*" >> "$GIT_LOG"
  case "$*" in
    *:refs/heads/*)
      [ -z "${STUB_GIT_PRE_PUSH:-}" ] || eval "$STUB_GIT_PRE_PUSH"
      if [ "${STUB_GIT_PUSH_FAIL_AFTER:-0}" = 1 ]; then
        "$REAL_GIT" "${a[@]}"
        echo "fatal: the remote end hung up unexpectedly" >&2
        exit 128
      fi
      if [ -n "${STUB_GIT_POST_PUSH:-}" ]; then
        "$REAL_GIT" "${a[@]}"; prc=$?
        eval "$STUB_GIT_POST_PUSH"
        exit "$prc"
      fi
      if [ "${STUB_GIT_PUSH_KILL:-0}" = 1 ]; then
        "$REAL_GIT" "${a[@]}"
        # Walks OUR OWN ancestor chain and kills every process in it that is the integrator (the
        # main one and the command-substitution fork). `pkill -f team-integrate.sh` was the first
        # try and is wrong twice over: it did not match the harness's `bash <script> <arg>` form on
        # macOS 15, and it would also kill any unrelated process whose command line merely MENTIONS
        # the script — an editor, a grep, the session that launched the suite.
        kp="$PPID"
        while [ -n "$kp" ] && [ "$kp" != 0 ] && [ "$kp" != 1 ]; do
          kc="$(ps -o command= -p "$kp" 2>/dev/null)"
          knext="$(ps -o ppid= -p "$kp" 2>/dev/null | tr -d ' ')"
          case "$kc" in *team-integrate.sh*) kill -KILL "$kp" 2>/dev/null || true ;; esac
          kp="$knext"
        done
        exit 0
      fi ;;
  esac
fi
exec "$REAL_GIT" "${a[@]}"
STUB
}

# The `gh` stub for the PR suites. NOT called by smoke_stubs: smoke 1-4 are ADO and must not gain a
# `gh` on PATH. All PR state is a file per PR in $GH_DIR; `state` is DERIVED from the bare origin
# (head reachable from base = MERGED) so the fixture cannot claim a lifecycle the refs contradict.
# Env switches: STUB_GH_AUTH (rc of `auth status`), STUB_GH_MERGEABLE (overrides `mergeable`),
# STUB_GH_ON_MERGED="<cmd>" (run ONCE, right after a `pr view` answers MERGED — the window between
# "the PR is closed" and the integrator's final look at the base),
# STUB_GH_ON_VIEW="<cmd>" (run ONCE, right after any `pr view` — the window between a caller's
# eligibility check and whatever it does next),
# STUB_GH_CREATE_FAIL_AFTER=1 (the PR is really created, then the client gets an error),
# STUB_GH_CREATE_RACE=draft|ready (the answer is lost AND the PR that lands has the opposite
# draft state to the one asked for — a concurrent writer won the race).
smoke_gh_stub() {
  : "${GH_DIR:?smoke_gh_stub needs GH_DIR}" "${GH_LOG:?smoke_gh_stub needs GH_LOG}"
  mkdir -p "$GH_DIR"
  cat > "$WORK/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "gh $*" >> "$GH_LOG"
G="$GH_DIR"
# The head sha and lifecycle GitHub would report, derived from the refs in the bare origin.
# Both print their answer: `$(pr_oid …)` runs in a subshell, so a global would never come back.
pr_oid() {  # pr_oid <file> → the live head sha, or the one recorded when the branch is gone
  local o
  o="$("$REAL_GIT" --git-dir="$GH_BARE" rev-parse -q --verify \
    "refs/heads/$(jq -r '.headRefName' "$1")" || true)"
  [ -n "$o" ] || o="$(jq -r '.headRefOid // ""' "$1")"
  printf '%s' "$o"
}
pr_state() {  # pr_state <file> <head sha> → OPEN|CLOSED|MERGED
  if [ -n "$2" ] && "$REAL_GIT" --git-dir="$GH_BARE" merge-base --is-ancestor "$2" \
    "refs/heads/$(jq -r '.baseRefName' "$1")" 2>/dev/null; then
    echo MERGED
  elif [ "$(jq -r '.closed // false' "$1")" = true ]; then
    echo CLOSED
  else
    echo OPEN
  fi
}
pr_obj() {  # pr_obj <file> → the PR object with state/headRefOid/mergeable resolved
  local o st
  o="$(pr_oid "$1")"; st="$(pr_state "$1" "$o")"
  jq -c --arg o "$o" --arg s "$st" --arg m "${STUB_GH_MERGEABLE:-}" \
    '.headRefOid = $o | .state = $s | (if $m == "" then . else .mergeable = $m end)' "$1"
}
case "${1:-} ${2:-}" in
  "auth status") exit "${STUB_GH_AUTH:-0}" ;;
esac
case "${1:-}" in
  pr)
    case "${2:-}" in
      view)
        n="$3"; shift 3; q=""
        while [ $# -gt 0 ]; do case "$1" in -q|--jq) q="$2"; shift 2 ;; *) shift ;; esac; done
        [ -f "$G/pr-$n.json" ] || { echo "no pull requests found for #$n" >&2; exit 1; }
        if [ -n "$q" ]; then pr_obj "$G/pr-$n.json" | jq -r "$q"
        else pr_obj "$G/pr-$n.json"; fi
        if [ -n "${STUB_GH_ON_VIEW:-}" ] && [ ! -f "$G/on-view" ]; then
          : > "$G/on-view"
          ( set +e; eval "$STUB_GH_ON_VIEW" ) >/dev/null 2>&1 || true
        fi
        if [ -n "${STUB_GH_ON_MERGED:-}" ] && [ ! -f "$G/on-merged-$n" ] \
          && [ "$(pr_state "$G/pr-$n.json" "$(pr_oid "$G/pr-$n.json")")" = MERGED ]; then
          : > "$G/on-merged-$n"
          ( set +e; eval "$STUB_GH_ON_MERGED" ) >/dev/null 2>&1 || true
        fi ;;
      list)
        head=""; base=""; shift 2
        while [ $# -gt 0 ]; do case "$1" in
          --head) head="$2"; shift 2 ;; --base) base="$2"; shift 2 ;; *) shift ;; esac; done
        # `--head` filters by BRANCH NAME only — a fork's PR on the same name comes back too.
        out='[]'
        for f in "$G"/pr-*.json; do
          [ -f "$f" ] || continue
          [ "$(pr_state "$f" "$(pr_oid "$f")")" = OPEN ] || continue
          [ "$(jq -r '.headRefName' "$f")" = "$head" ] || continue
          [ -z "$base" ] || [ "$(jq -r '.baseRefName' "$f")" = "$base" ] || continue
          out="$(printf '%s' "$out" | jq -c --argjson p "$(pr_obj "$f")" '. + [$p]')"
        done
        printf '%s\n' "$out" ;;
      create)
        base=""; head=""; t=""; bf=""; draft=false; shift 2
        while [ $# -gt 0 ]; do case "$1" in
          --base) base="$2"; shift 2 ;; --head) head="$2"; shift 2 ;;
          --title) t="$2"; shift 2 ;; --body-file) bf="$2"; shift 2 ;;
          --draft) draft=true; shift ;; *) shift ;; esac; done
        n="$(cat "$G/next" 2>/dev/null || echo 41)"; echo $((n + 1)) > "$G/next"
        case "${STUB_GH_CREATE_RACE:-}" in
          draft) draft=true ;; ready) draft=false ;;
        esac
        jq -n --argjson n "$n" --argjson d "$draft" --arg h "$head" --arg b "$base" \
          --arg t "$t" --rawfile body "$bf" \
          '{number: $n, isDraft: $d, headRefName: $h, baseRefName: $b, title: $t,
            headRepositoryOwner: {login: "acme"}, headRepository: {name: "widgets"},
            mergeable: "MERGEABLE", body: $body, closed: false, headRefOid: ""}' \
          > "$G/pr-$n.json"
        # The uncertain write: the PR exists, the client never learns its number.
        [ -z "${STUB_GH_CREATE_RACE:-}" ] \
          || { echo "gh: timeout awaiting response headers" >&2; exit 1; }
        [ "${STUB_GH_CREATE_FAIL_AFTER:-0}" != 1 ] \
          || { echo "gh: timeout awaiting response headers" >&2; exit 1; }
        echo "https://github.com/acme/widgets/pull/$n" ;;
      ready)
        [ -f "$G/pr-$3.json" ] || { echo "no pull requests found for #$3" >&2; exit 1; }
        [ "$(jq -r '.isDraft' "$G/pr-$3.json")" = true ] \
          || { echo "Pull request #$3 is already marked as ready for review" >&2; exit 1; }
        jq '.isDraft = false' "$G/pr-$3.json" > "$G/t" && mv "$G/t" "$G/pr-$3.json"
        echo '{}' ;;
      edit)
        n="$3"; shift 3; bf=""
        while [ $# -gt 0 ]; do case "$1" in --body-file) bf="$2"; shift 2 ;; *) shift ;; esac; done
        [ -f "$G/pr-$n.json" ] || { echo "no pull requests found for #$n" >&2; exit 1; }
        [ -r "$bf" ] || { echo "gh: cannot read $bf" >&2; exit 1; }
        jq --rawfile b "$bf" '.body = $b' "$G/pr-$n.json" > "$G/t" && mv "$G/t" "$G/pr-$n.json"
        echo '{}' ;;
      *) echo "stub: gh pr ${2:-}" >&2; exit 1 ;;
    esac ;;
  *) echo "stub: gh $*" >&2; exit 1 ;;
esac
STUB
  chmod +x "$WORK/bin/gh"
}

# Fixture-only ref surgery in the bare origin, through a throwaway clone (a bare repo takes
# `refs/pull/*` without hooks, and no working tree is needed by the harness).
smoke_gh_wc() {  # smoke_gh_wc <tag> → a fresh clone of the bare origin in $SGW
  SGW="$WORK/wc-$1"
  rm -rf "$SGW"
  git clone --quiet "$WORK/origin.git" "$SGW"
}

smoke_gh_commit() {  # smoke_gh_commit <branch> <tag> — one new commit on <branch> in the origin
  local b="$1" t="$2" start="origin/$1"
  smoke_gh_wc "$t"
  git -C "$SGW" rev-parse -q --verify "$start" >/dev/null 2>&1 \
    || start="origin/${SMOKE_TRUNK:-develop-netcore7}"
  git -C "$SGW" checkout --quiet -B "$b" "$start"
  printf '%s\n' "$t" > "$SGW/$t.txt"
  git -C "$SGW" add "$t.txt" && git -C "$SGW" commit --quiet -m "$t"
  git -C "$SGW" push --quiet origin "$b"
  rm -rf "$SGW"
}

smoke_gh_land() {  # smoke_gh_land <head> <base> — merge <head> into <base> in the origin
  smoke_gh_wc "land"
  git -C "$SGW" checkout --quiet -B "$2" "origin/$2"
  git -C "$SGW" merge --no-ff --no-edit --quiet "origin/$1"
  git -C "$SGW" push --quiet origin "$2"
  rm -rf "$SGW"
}

# Builds `refs/pull/<n>/merge` exactly as GitHub does: a merge commit whose parent 1 is the current
# base tip and parent 2 the PR head. The `+` force is FIXTURE-ONLY — a recomputed merge M2(T2,S) is
# not a descendant of M1, so a plain push would be rejected. Production never forces.
smoke_gh_pull() {  # smoke_gh_pull <pr> <head> <base>
  local n="$1"
  smoke_gh_wc "pull-$n"
  git -C "$SGW" checkout --quiet -B "$3" "origin/$3"
  if git -C "$SGW" merge --no-ff --no-edit --quiet "origin/$2" >/dev/null 2>&1; then
    git -C "$SGW" push --quiet origin "+HEAD:refs/pull/$n/merge"
  else
    git -C "$SGW" merge --abort || true    # a conflict leaves NO merge ref, like GitHub
  fi
  rm -rf "$SGW"
}

# An OCTOPUS merge ref: parent 1 the base, parent 2 the head, parent 3 somebody else's branch.
# `^1`/`^2` answer correctly here, so only the full parent list can reject it.
smoke_gh_pull_octopus() {  # smoke_gh_pull_octopus <pr> <head> <base> <extra>
  local n="$1"
  smoke_gh_wc "octo-$n"
  git -C "$SGW" checkout --quiet -B "$3" "origin/$3"
  git -C "$SGW" merge --no-ff --no-edit --quiet "origin/$2" "origin/$4"
  git -C "$SGW" push --quiet origin "+HEAD:refs/pull/$n/merge"
  rm -rf "$SGW"
}

smoke_gh_pull_stale() {  # smoke_gh_pull_stale <pr> <head> <base> — ref built, then the base moves
  smoke_gh_pull "$1" "$2" "$3"
  smoke_gh_commit "$3" "stale-$1"
}

# Usage: smoke_profile ['<jq filter>'] → the TT `teams` profile on stdout, optionally edited.
# These are exactly the values team-lib.sh and worker-next.sh used to hardcode.
smoke_profile() {
  jq -n '{schema: 1, teams: {
      tracker: "jira",
      pr_provider: "azure-devops",
      trunk: "develop-netcore7",
      branch_types: ["feature", "bugfix", "hotfix", "chore", "refactor"],
      required_tools: ["git", "jq", "tmux", "claude", "codex", "az", "dotnet"],
      seed_files: [".env", ".claude/settings.local.json", ".agents/memory/user-profile.md"],
      env_file_required: true,
      build_check: "dotnet build TakeTask2.API.sln",
      test_gate: ".claude/lib/test-gate.sh",
      gates: "auto"
    }}' | jq "${1:-.}"
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
  # Without the tracker blocks every wrapup/planner render in smoke 1-4 dies (return 1).
  mkdir -p "$SEED/.claude/team/tracker"
  cp "$SRC"/.claude/team/tracker/*.md "$SEED/.claude/team/tracker/"
  # Same reason for the PR blocks: a prompt carrying {{PR_*}} with no block dir dies (return 1).
  mkdir -p "$SEED/.claude/team/pr"
  cp "$SRC"/.claude/team/pr/*.md "$SEED/.claude/team/pr/"
  cp "$SRC/.claude/team/roles.json" "$SEED/.claude/team/"
  # Fixture fix (starter import): own profile, independent of the repo's (template) codex-profile.
  printf '# test fixture\n~/.codex-taketask\n' > "$SEED/.claude/codex-profile"
  printf '#!/usr/bin/env bash\necho "test-gate: total 3, passed 3, failed 0 (baseline 0, new 0, now passing 0)"\n' \
  > "$SEED/.claude/lib/test-gate.sh"
  # Fixture fix (starter import): the TT values the harness used to hardcode are now a profile.
  smoke_profile > "$SEED/.claude/project-profile.json"
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
