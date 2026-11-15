#!/usr/bin/env bash
# Offline test for guard-push.sh's protected-branch rule (Branch model `**Protected push:**`):
# every push form whose destination is a Protected branch is refused under pr-only; the repo being
# pushed decides (git -C / cd), not the session dir; an unreadable mode keeps today's behaviour with
# no hook error. The secret scan itself is guard-leak-smoke's. Bash 3.2 compatible.
set -euo pipefail

ST=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
export GIT_CONFIG_GLOBAL="$WORK/gitconfig" GIT_CONFIG_NOSYSTEM=1
printf '[user]\n  name = t\n  email = t@example.invalid\n[init]\n  defaultBranch = main\n' > "$GIT_CONFIG_GLOBAL"
export CLAUDE_PROJECT_DIR="$WORK"   # no .claude there → no audit log
mkdir -p "$WORK/bin"; printf '#!/bin/sh\nexit 0\n' > "$WORK/bin/gitleaks"; chmod +x "$WORK/bin/gitleaks"
export PATH="$WORK/bin:$PATH"
HOOK="$ST/.claude/hooks/guard-push.sh"

fail() { echo "guard-push-protected-test: FAIL — $*"; [ ! -s "$WORK/err" ] || sed 's/^/  | /' "$WORK/err"; exit 1; }
N=0
hook() {  # hook <cwd> <command> → RC; stderr in $WORK/err
  set +e
  jq -n --arg c "$2" --arg d "$1" '{tool_input:{command:$c},cwd:$d}' | bash "$HOOK" 2> "$WORK/err" >/dev/null
  RC=$?; set -e; N=$((N + 1))
}
blocked() { hook "$1" "$2"; [ "$RC" = 2 ] || fail "$3: '$2' exit $RC, expected 2"
  grep -qF 'Protected push:** confirm' "$WORK/err" || fail "$3: the refusal does not say how to switch it off"; }
allowed() { hook "$1" "$2"; [ "$RC" = 0 ] || fail "$3: '$2' exit $RC, expected 0"
  [ ! -s "$WORK/err" ] || fail "$3: '$2' wrote to stderr"; }

model() {  # model <repo> <Protected push value | ''> — writes its Branch model
  { echo '# CLAUDE.md'; echo; echo '### Branch model'; echo
    echo '**Preset:** gitflow · **Trunk:** `main` · **Integration:** `develop`'
    echo '**Protected:** `main`, `develop`'
    [ -z "$2" ] || echo "**Protected push:** $2"
    echo; echo '## Next'; } > "$1/CLAUDE.md"
}
mkrepo() {  # mkrepo <name> → a repo with origin, main/develop pushed, feature/x checked out
  local r="$WORK/$1"
  git init --quiet --bare "$WORK/$1.git"; git init --quiet "$r"
  echo a > "$r/f"; git -C "$r" add f; git -C "$r" commit --quiet -m a
  git -C "$r" remote add origin "$WORK/$1.git"
  git -C "$r" branch develop; git -C "$r" push --quiet -u origin main develop
  git -C "$r" switch --quiet -c feature/x; git -C "$r" tag v1
  printf '%s' "$r"
}
R=$(mkrepo pr); model "$R" pr-only
C=$(mkrepo plain); model "$C" ''

# (1) pr-only: every form with a protected destination is refused
blocked "$R" "git push origin main" "1"
blocked "$R" "git push origin HEAD:main" "1 HEAD:main"
blocked "$R" "git push origin +feature/x:refs/heads/main" "1 forced refs/heads"
blocked "$R" "git push origin :develop" "1 delete by refspec"
blocked "$R" "git push origin --delete develop" "1 --delete"
blocked "$R" "git push --delete origin main" "1 --delete first"
blocked "$R" "git push --all origin" "1 --all"
blocked "$R" "git push --mirror origin" "1 --mirror"
blocked "$R" "git push -u origin 'main'" "1 quoted"
blocked "$R" "git push -o ci.skip origin main" "1 option with a separate value"
git -C "$R" switch --quiet main
blocked "$R" "git push origin HEAD" "1 HEAD on main"
blocked "$R" "git push" "1 bare push on main (upstream)"
blocked "$R" "git push origin" "1 remote only on main"
git -C "$R" branch --quiet --unset-upstream
blocked "$R" "git push" "1 bare push on main (no upstream)"
git -C "$R" switch --quiet feature/x

# (2) pr-only: a working branch, a tag and a dry run pass
allowed "$R" "git push origin feature/x" "2 working branch"
allowed "$R" "git push -o ci.skip origin feature/x" "2 option value is not the remote"
allowed "$R" "git push -u origin HEAD" "2 HEAD on a working branch"
allowed "$R" "git push origin v1" "2 tag"
allowed "$R" "git push --tags origin" "2 --tags"
allowed "$R" "git push --dry-run origin main" "2 dry run"
git -C "$R" push --quiet -u origin feature/x
allowed "$R" "git push" "2 bare push on a working branch"

# (2b) a team branch: cut --no-track from the protected line (team-new.sh), first pushed by /push
# with -u; its PR to the protected line is made through the host (team-pr.sh), never a git push.
git -C "$R" switch --quiet --no-track -c feature/AB-1-team develop
allowed "$R" 'git push -u origin "feature/AB-1-team"' "2b team branch, first /push"
allowed "$R" "git push" "2b team branch after -u"
git -C "$R" switch --quiet feature/x

# (3) a destination only git config knows is refused under pr-only, until it is named
git -C "$R" config remote.origin.push HEAD:refs/heads/main
blocked "$R" "git push origin feature/x" "3 remote.origin.push maps <src>"
blocked "$R" "git push" "3 remote.origin.push, no refspec"
allowed "$R" "git push origin feature/x:feature/x" "3 named destination"
git -C "$R" config --unset remote.origin.push
git -C "$R" config push.default matching
blocked "$R" "git push" "3 push.default=matching"
git -C "$R" config --unset push.default

# (4) the repo being pushed decides, not the session dir
blocked "$C" "git -C $R push origin main" "4 -C into a pr-only repo"
blocked "$C" "cd $R && git push origin main" "4 cd into a pr-only repo"
allowed "$R" "git -C $C push origin main" "4 -C into a confirm repo"
allowed "$R" "cd $C && git push origin main" "4 cd into a confirm repo"

# (4b) every push of a compound command is checked, each in its own repo
git -C "$R" push --quiet origin feature/x:feature/y
blocked "$R" "git push origin main && git push origin feature/x" "4b protected first"
blocked "$R" "git push origin feature/x && git push origin main" "4b protected last"
allowed "$R" "git push origin feature/x; git push origin feature/y" "4b two working branches"
blocked "$R" "git push origin feature/x; git push origin HEAD:main || git push origin feature/y" "4b protected in the middle"
blocked "$R" "git status | cat
git push origin develop" "4b after a newline"
blocked "$C" "git push origin feature/x && cd $R && git push origin main" "4b cd before the second push"
allowed "$R" "git push origin feature/x && git -C $C push origin main" "4b second push into a confirm repo"
blocked "$C" "git push origin main && git -C $R push origin main" "4b second push into a pr-only repo"

# (4c) wrapped pushes are seen; quoted text is not a push
blocked "$R" "(git push origin main)" "4c subshell"
blocked "$R" 'bash -c "git push origin main"' "4c bash -c"
blocked "$C" "sh -c 'cd $R && git push origin main'" "4c sh -c with cd into a pr-only repo"
blocked "$R" 'echo $(git push origin develop)' "4c substitution"
blocked "$R" "sudo git push origin main" "4c after sudo"
blocked "$R" "if git push origin main; then :; fi" "4c in an if"
blocked "$R" "{ git push origin main; }" "4c brace group"
blocked "$R" "function f() { git push origin main; }; f" "4c function body"
blocked "$R" "f() { git push origin develop; }; f" "4c POSIX function body"
allowed "$R" 'B=feature/x; git push origin ${B}' "4c braces inside a word"
allowed "$R" "echo 'git push origin main'" "4c quoted text"
allowed "$R" 'git log -1 --grep "release: git push origin main"' "4c a message naming a push"

# (5) mode absent, confirm, unknown, no block, no CLAUDE.md, no reader → today's behaviour, silent
for v in '' confirm 'sometimes'; do
  model "$R" "$v"; allowed "$R" "git push origin main" "5 Protected push '${v:-absent}'"
done
printf '# CLAUDE.md\n' > "$R/CLAUDE.md"; allowed "$R" "git push origin main" "5 no Branch model block"
rm -f "$R/CLAUDE.md"; allowed "$R" "git push origin main" "5 no CLAUDE.md"
model "$R" pr-only
mkdir -p "$WORK/noreader/.claude"; cp -R "$ST/.claude/hooks" "$WORK/noreader/.claude/"
HOOK="$WORK/noreader/.claude/hooks/guard-push.sh"
allowed "$R" "git push origin main" "5 branch-model.sh missing"
HOOK="$ST/.claude/hooks/guard-push.sh"

# (6) the guard binds only git push; the GUARD_PUSH_SKIP secret-scan override does not lift it
allowed "$R" "git status" "6 not a push"
blocked "$R" "GUARD_PUSH_SKIP=1 git push origin main" "6 secret-scan override"

echo "guard-push-protected-test: OK ($N cases)"
