#!/usr/bin/env bash
# git-baseline.sh — snapshot git metadata + sensitive ignored files around a write-enabled
# Codex run, then diff the two snapshots. Contract: .agents/reference/codex-spawn.md → Executor mode.
#
# Usage:
#   bash .claude/lib/git-baseline.sh capture <dir>   # before the spawn
#   bash .claude/lib/git-baseline.sh compare <dir>   # after it — exit 0 clean, 1 deviation(s) listed on stdout
#
# Why a script: two commands (/execute codex, /check-implementation codex) must take the SAME
# snapshot before and after a 60–90 minute wait; inline snippets drift and get compacted away.
set -uo pipefail

# Keep in sync with guard-push.sh FILE_RE — the repo's one other "secret-looking by name" list.
SENSITIVE_RE='(^|/)\.env|\.pem$|\.key$|\.p12$|\.pfx$|\.keystore$|\.jks$|\.ppk$|(^|/)id_(rsa|dsa|ecdsa|ed25519)|(^|/)\.(npmrc|pypirc|netrc|htpasswd)$|(^|/)\.aws/credentials$|kubeconfig|\.tfstate|\.tfvars$|credential|secret|service-account[^/]*\.json$|user-profile\.md$'
# Ignored harness files (settings.local.json, hooks state) are invisible to `git status` yet can
# weaken permissions — hashed like secrets. Telemetry that Claude's own hooks append to between
# capture and compare, and the worktree checkouts, are excluded or every run would deviate.
PROTECTED_RE='^(\.claude|\.agents)/'
TELEMETRY_RE='^\.claude/(audit\.log|memory-usage\.json|scheduled_tasks\.lock|worktrees/)|(^|/)\.DS_Store$'
# Vendored/cache trees churn on every install or test run — excluded from the sensitive scan
# (vendored "credentials.js" is not a secret); their disappearance is still a deviation.
CACHE_RE='(^|/)(node_modules|\.venv|venv|vendor|__pycache__|\.pytest_cache|\.mypy_cache|\.ruff_cache|coverage|dist|build|\.next|\.turbo|target)/'

git rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "git-baseline.sh: not a git repo"; exit 2; }
# A missing hasher would blank INDEX/CONFIG in both snapshots and pass vacuously.
command -v shasum >/dev/null 2>&1 || { echo "git-baseline.sh: shasum not found — cannot hash index/config"; exit 2; }

# Pure-bash filters: rg is a shell function in Claude's interactive shell, absent in `bash script.sh`,
# and a missing filter must never degrade into an empty (vacuously clean) sensitive list.
sensitive_paths() {  # stdin: NUL-delimited paths → stdout: NUL-delimited matches
  local f
  shopt -s nocasematch
  while IFS= read -r -d '' f; do
    [[ $f =~ $CACHE_RE ]] && continue
    [[ $f =~ $TELEMETRY_RE ]] && continue
    if [[ $f =~ $SENSITIVE_RE || $f =~ $PROTECTED_RE ]]; then printf '%s\0' "$f"; fi
  done
  shopt -u nocasematch
  return 0
}

capture() {
  local dir="$1" cfg head idx
  mkdir -p "$dir"
  # In a linked worktree `.git` is a file; the local config lives in the common dir.
  cfg=$(git rev-parse --git-path config) && [ -f "$cfg" ] || { echo "git-baseline.sh: cannot resolve git config path"; exit 2; }
  # Checked assignments: `echo "X $(cmd)"` masks a failed substitution, and shasum of the
  # resulting empty input still prints 64 hex chars — the emptiness guard below would pass.
  head=$(git rev-parse HEAD) || { echo "git-baseline.sh: git rev-parse HEAD failed"; exit 2; }
  idx=$(git ls-files -s) && [ -n "$idx" ] || { echo "git-baseline.sh: git ls-files -s failed or returned an empty index"; exit 2; }
  {
    echo "HEAD $head"
    echo "BRANCH $(git branch --show-current)"
    echo "STASH $(git stash list --format=%H | tr '\n' ' ')"
    git for-each-ref --format='REF %(refname) %(objectname)'
    echo "INDEX $(printf '%s' "$idx" | shasum -a 256 | cut -d' ' -f1)"
    echo "CONFIG $(shasum -a 256 "$cfg" | cut -d' ' -f1)"
  } > "$dir/meta.txt"
  [ "$(grep -Ec '^(INDEX|CONFIG) [0-9a-f]{64}$' "$dir/meta.txt")" -eq 2 ] \
    || { echo "git-baseline.sh: could not hash index/config — refusing an empty baseline"; exit 2; }

  # One walk of the ignored set, NUL-delimited; both the listing and the hashes derive from it.
  git ls-files -o -i --exclude-standard -z > "$dir/ignored.z" \
    || { echo "git-baseline.sh: could not enumerate ignored files"; exit 2; }
  tr '\0' '\n' < "$dir/ignored.z" | LC_ALL=C sort > "$dir/ignored.txt"
  # An empty sensitive.sha is the legitimate "nothing secret-looking is ignored" result.
  sensitive_paths < "$dir/ignored.z" \
    | xargs -0 -r shasum -a 256 2>/dev/null | LC_ALL=C sort > "$dir/sensitive.sha"
}

compare() {
  local dir="$1" after="$1/after" rc=0
  [ -f "$dir/meta.txt" ] || { echo "git-baseline.sh: no baseline in $dir — run capture first"; exit 2; }
  capture "$after"

  if ! diff -u "$dir/meta.txt" "$after/meta.txt"; then
    echo "DEVIATION: git metadata changed (HEAD / branch / stash / refs / index / .git/config)"; rc=1
  fi
  if ! diff -u "$dir/sensitive.sha" "$after/sensitive.sha"; then
    echo "DEVIATION: a secret-looking or ignored harness file changed or vanished — never restore a secret yourself"; rc=1
  fi
  local removed added
  removed=$(LC_ALL=C comm -23 "$dir/ignored.txt" "$after/ignored.txt")
  added=$(LC_ALL=C comm -13 "$dir/ignored.txt" "$after/ignored.txt")
  if [ -n "$removed" ]; then
    echo "DEVIATION: ignored files removed (git clean?):"; printf '%s\n' "$removed"; rc=1
  fi
  if [ -n "$added" ]; then
    local added_protected
    added_protected=$(printf '%s\n' "$added" | while IFS= read -r line; do
      [[ $line =~ $PROTECTED_RE && ! $line =~ $TELEMETRY_RE ]] && printf '%s\n' "$line"
    done)
    if [ -n "$added_protected" ]; then
      echo "DEVIATION: new ignored files under .agents/ or .claude/:"; printf '%s\n' "$added_protected"; rc=1
    fi
    added_n=$(printf '%s\n' "$added" | wc -l | tr -d ' ')
    echo "INFO: $added_n new ignored files (validation artifacts are expected; showing first 20):"
    printf '%s\n' "$added" | head -20
  fi
  local harness line
  harness=$(git status --porcelain | while IFS= read -r line; do
    [[ $line =~ ^..\ \"?(\.agents|\.claude)/ ]] && printf '%s\n' "$line"
  done)
  if [ -n "$harness" ]; then
    echo "DEVIATION: writes under .agents/ or .claude/:"; printf '%s\n' "$harness"; rc=1
  fi

  [ "$rc" -eq 0 ] && echo "BASELINE OK — no forbidden change"
  return "$rc"
}

usage() { echo "usage: git-baseline.sh capture|compare <dir>"; exit 2; }
case "${1:-}" in
  capture|compare) [ -n "${2:-}" ] || usage; "$1" "$2" ;;
  *) usage ;;
esac
