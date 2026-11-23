#!/usr/bin/env bash
# Offline smoke test for the credential scans in guard-push.sh and guard-commit.sh (both
# source hooks/lib/leak-patterns.sh). Each case gets its own throwaway repo; the hook is fed
# a PreToolUse payload and its exit code asserted.
# Run: bash .claude/lib/tests/guard-leak-smoke.sh
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
HOOKS=$(cd "$HERE/../../hooks" && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

fail() { echo "guard-leak-smoke: FAIL — $*"; exit 1; }

# no .claude dir under $WORK → the hooks never write an audit log
export CLAUDE_PROJECT_DIR="$WORK"
# gitleaks stub: a block case must pass on the built-in classes, not on gitleaks
mkdir -p "$WORK/bin"; printf '#!/bin/sh\nexit 0\n' > "$WORK/bin/gitleaks"
chmod +x "$WORK/bin/gitleaks"; export PATH="$WORK/bin:$PATH"

# Key names are concatenated so this file carries no scannable literal.
P=Pass; P="${P}word"
AK=Account; AK="${AK}Key"
SAK=SharedAccess; SAK="${SAK}Key"
XK=Access; XK="${XK}Key"
MG=mongo; MG="${MG}db"
GH=ghp_; GH="${GH}0123456789abcdefghijABCDEFGHIJ012345"

N=0; C=0
ok() { C=$((C + 1)); echo "OK $*"; }
gitc() { git -C "$R" -c user.email=t@t -c user.name=t "$@"; }
new_repo() {  # new_repo <file> <content> — sets R and stages the file; never call via $(…)
  N=$((N + 1)); R="$WORK/r$N"
  git init -q "$R"; mkdir -p "$(dirname "$R/$1")"
  printf '%s\n' "$2" > "$R/$1"; git -C "$R" add -A
}

run_hook() {  # run_hook <hook> <command> <cwd> — prints the exit code
  local rc=0
  jq -n --arg c "$2" --arg d "$3" '{tool_input:{command:$c},cwd:$d}' \
    | bash "$HOOKS/$1" >/dev/null 2>&1 || rc=$?
  echo "$rc"
}

push_case() {  # push_case <label> <expected rc> <file> <content>
  new_repo "$3" "$4"; gitc commit -qm t
  local rc; rc=$(run_hook guard-push.sh "git push origin HEAD" "$R")
  [ "$rc" = "$2" ] || fail "push $1: expected $2, got $rc"
  ok "push $1"
}

commit_case() {  # commit_case <label> <expected rc> <file> <content> [command]
  new_repo "$3" "$4"
  local rc; rc=$(run_hook guard-commit.sh "${5:-git commit -m t}" "$R")
  [ "$rc" = "$2" ] || fail "commit $1: expected $2, got $rc"
  ok "commit $1"
}

F=src/conn.txt

# --- push: block ----------------------------------------------------------------
push_case "known-format token" 2 "$F" "token = $GH"
push_case "sql login" 2 "$F" "Server=tcp:h.example.net;User ID=u;$P=Zq8vLm2r"
push_case "storage key" 2 "$F" "AccountName=prodst;$AK=QmFzZTY0VmFsdWVIZXJl=="
push_case "bus sas" 2 "$F" "Endpoint=sb://h/;SharedAccessKeyName=r;$SAK=QmFzZTY0QWdhaW4="
push_case "mongo userinfo" 2 "$F" "$MG://user:pa55word@h.example.net"
push_case "access key" 2 "$F" "Endpoint=https://h;$XK=QmFzZTY0U2lnbmFs;Version=1.0;"
push_case "at sign" 2 "$F" "$P=@bc123def"
push_case "dollar" 2 "$F" "$P=\$x9fq2Lk"
push_case "percent" 2 "$F" "$P=%41bcd2"
push_case "asterisk" 2 "$F" "$P=*q8Lmz2"
push_case "leading equals" 2 "$F" "$P==q8Lmz2"
push_case "leading space" 2 "$F" "$P= q8Lmz2"
push_case "single-quoted with ;" 2 "$F" "$P='q8;Lmz2'"
push_case "inside single-quoted literal" 2 "$F" "const cs = 'Server=db;$P=Zq8vLm2r';"
push_case "shell literal" 2 "$F" "CS='Server=h;$P=\"Zq8\";'"
push_case "json-escaped" 2 "$F" "\"cs\": \"Server=h;$P=\\\"Zq8\\\";\""
push_case "doubled quote" 2 "$F" "Server=h;$P='''q8';"
push_case "spaced quote" 2 "$F" "Server=h;$P= \"Zq8\";"
push_case "emulator then real" 2 "$F" \
  "A='AccountName=devstoreaccount1;$AK=emu1' B='AccountName=prodst;$AK=QmFz=='"
push_case "near-emulator account" 2 "$F" "AccountName=devstoreaccount1prod;$AK=QmFzZTY0=="
push_case "credential file" 2 ".env" "# local"
push_case "local env file" 2 "cfg/local.env" "# local"

# --- push: allow ----------------------------------------------------------------
push_case "empty" 0 "$F" "$P="
push_case "angle placeholder" 0 "$F" "$P=<set-locally>"
push_case "format slot" 0 "$F" "$P={0}"
push_case "placeholder word" 0 "$F" "$AK=placeholder"
push_case "env reference" 0 "$F" "$SAK=\${HUB_KEY}"
push_case "quoted placeholder word" 0 "$F" "const cs = 'Server=db;$P=changeme';"
push_case "quoted empty value" 0 "$F" "const cs = 'Server=db;$P=';"
push_case "runtime env read" 0 "$F" "password=process.env.DB_PASSWORD;"
push_case "emulator" 0 "$F" "A='AccountName=devstoreaccount1;$AK=emu1'"
push_case "allow marker" 0 "$F" "$P=Zq8vLm2r // guard-push:allow"
push_case "example file" 0 "cfg/settings.json.example" "$P=Zq8vLm2r"
push_case "local env example" 0 "cfg/local.env.example" "# local"

# secret added in one commit, removed in the next: still ships in history → block
new_repo "$F" "token = $GH"; gitc commit -qm add
printf 'clean\n' > "$R/$F"; gitc commit -qam remove
rc=$(run_hook guard-push.sh "git push origin HEAD" "$R")
[ "$rc" = 2 ] || fail "push add-then-remove: expected 2, got $rc"; ok "push add-then-remove"

# credential file committed earlier (already on the remote), deleted now → allow
new_repo ".env" "# local"; gitc commit -qm add
git -C "$R" update-ref refs/remotes/origin/main HEAD; git -C "$R" branch -qM main
gitc rm -q .env; gitc commit -qm remove
rc=$(run_hook guard-push.sh "git push origin main" "$R")
[ "$rc" = 0 ] || fail "push credential-file deletion: expected 0, got $rc"; ok "push credential-file deletion"

# --- commit (D3) ----------------------------------------------------------------
commit_case "sql login" 2 "$F" "Server=tcp:h.example.net;User ID=u;$P=Zq8vLm2r"
commit_case "known-format token" 2 "$F" "token = $GH"
commit_case "angle placeholder" 0 "$F" "$P=<set-locally>"
commit_case "clean file" 0 "$F" "hello"
commit_case "credential file" 2 "cfg/local.env" "# local"
commit_case "allow marker" 0 "$F" "$P=Zq8vLm2r // guard-push:allow"
commit_case "git -C form" 2 "$F" "token = $GH" "git -C $WORK/r$((N + 1)) commit -m t"
commit_case "--no-edit still scanned" 2 "$F" "token = $GH" "git commit --no-edit"
commit_case "-a form skipped" 0 "$F" "token = $GH" "git commit -am t"

# staged deletion of a credential file → allow
new_repo ".env" "# local"; gitc commit -qm add; gitc rm -q .env
rc=$(run_hook guard-commit.sh "git commit -m t" "$R")
[ "$rc" = 0 ] || fail "commit credential-file deletion: expected 0, got $rc"; ok "commit credential-file deletion"

# D1 still holds: empty index blocks, --no-edit on an empty index does not
N=$((N + 1)); R="$WORK/r$N"; git init -q "$R"
rc=$(run_hook guard-commit.sh "git commit -m t" "$R")
[ "$rc" = 2 ] || fail "commit empty index: expected 2, got $rc"; ok "commit empty index"
rc=$(run_hook guard-commit.sh "git commit --no-edit" "$R")
[ "$rc" = 0 ] || fail "commit --no-edit empty index: expected 0, got $rc"; ok "commit --no-edit empty index"

# D1 with a chained add: its explicit paths are staged into a temporary index and judged there (the
# real index stays untouched); -A / . / ; / another command in between keep the real index's verdict.
chain_case() {  # chain_case <label> <expected rc> <file> <content> <command; @R@ = the repo>
  N=$((N + 1)); R="$WORK/r$N"; git init -q "$R"; mkdir -p "$(dirname "$R/$3")"
  printf '%s\n' "$4" > "$R/$3"
  local rc; rc=$(run_hook guard-commit.sh "${5//@R@/$R}" "$R")
  [ "$rc" = "$2" ] || fail "commit chain $1: expected $2, got $rc"
  [ -z "$(git -C "$R" diff --cached --name-only)" ] || fail "commit chain $1: the real index changed"
  ok "commit chain $1"
}
chain_case "add && commit" 0 a.txt hi 'git add a.txt && git commit -m "x && y"'
chain_case "cd && add && commit" 0 a.txt hi 'cd @R@ && git add a.txt && git commit -m t'
chain_case "-C add && -C commit" 0 a.txt hi 'git -C @R@ add a.txt && git -C @R@ commit -m t'
chain_case "credential still scanned" 2 "$F" "token = $GH" "git add $F && git commit -m t"
chain_case "add -A not simulated" 2 a.txt hi 'git add -A && git commit -m t'
chain_case "add . not simulated" 2 a.txt hi 'git add . && git commit -m t'
chain_case "; is not a chain" 2 a.txt hi 'git add a.txt; git commit -m t'
chain_case "another command between" 2 a.txt hi 'git add a.txt && git status && git commit -m t'
chain_case "missing path" 2 a.txt hi 'git add nosuch && git commit -m t'

# --- wrapped invocations: subshell, substitution, <shell> -c; quoted text is not one ---------------
wrap_case() {  # wrap_case <hook> <label> <expected rc> <command; @R@ = the repo>
  new_repo "$F" "token = $GH"; [ "$1" = guard-commit.sh ] || gitc commit -qm t
  local rc; rc=$(run_hook "$1" "${4//@R@/$R}" "$R")
  [ "$rc" = "$3" ] || fail "$1 $2: expected $3, got $rc"
  ok "$1 $2"
}
wrap_case guard-push.sh "subshell" 2 "(git push origin HEAD)"
wrap_case guard-push.sh "bash -c" 2 'bash -c "git push origin HEAD"'
wrap_case guard-push.sh "sh -lc with cd" 2 "sh -lc 'cd @R@ && git push origin HEAD'"
wrap_case guard-push.sh "substitution" 2 'echo $(git push origin HEAD)'
wrap_case guard-push.sh "backticks" 2 'echo `git push origin HEAD`'
wrap_case guard-push.sh "brace group" 2 "{ git push origin HEAD; }"
wrap_case guard-push.sh "function body" 2 "function f() { git push origin HEAD; }; f"
wrap_case guard-push.sh "quoted text" 0 "echo 'git push origin HEAD'"
wrap_case guard-push.sh "message naming a push" 0 'git log -1 --grep "(git push origin HEAD)"'
wrap_case guard-commit.sh "subshell" 2 "(git commit -m t)"
wrap_case guard-commit.sh "bash -c" 2 "bash -c 'git commit -m t'"
wrap_case guard-commit.sh "zsh -c with cd" 2 "zsh -c 'cd @R@ && git commit -m t'"
wrap_case guard-commit.sh "brace group" 2 "{ git commit -m t; }"
wrap_case guard-commit.sh "function body" 2 "f() { git commit -m t; }; f"
wrap_case guard-commit.sh "quoted text" 0 "echo 'git commit -m t'"

# missing lib → both hooks fail open (loud), never scan with empty regexes
mkdir -p "$WORK/nolib"; cp "$HOOKS/guard-commit.sh" "$HOOKS/guard-push.sh" "$WORK/nolib/"
new_repo "$F" "token = $GH"
rc=0; jq -n --arg c "git commit -m t" --arg d "$R" '{tool_input:{command:$c},cwd:$d}' \
  | bash "$WORK/nolib/guard-commit.sh" >/dev/null 2>"$WORK/err" || rc=$?
[ "$rc" = 0 ] && grep -q SKIPPED "$WORK/err" || fail "commit missing lib: expected loud 0, got $rc"
ok "commit missing lib"

echo "guard-leak-smoke: OK ($C checks)"
