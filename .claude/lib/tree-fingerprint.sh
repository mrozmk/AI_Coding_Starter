#!/usr/bin/env bash
# tree-fingerprint.sh — prove a read-only step (the Step 1ab finders) did not touch the checkout.
# Contract: .claude/commands/check-implementation.md → Step 1ab.
#
# Usage:
#   bash .claude/lib/tree-fingerprint.sh capture <file>   # before the spawn
#   bash .claude/lib/tree-fingerprint.sh compare <file>   # after the barrier
#     exit 0 identical · 1 differs (differing keys on stdout) · 2 could not run
#
# Relative by design: it compares two snapshots, so pre-existing dirt is fine — only a change
# between capture and compare counts. git-baseline.sh cannot serve here: its compare flags any
# write under .claude/ as a deviation, including the run's own earlier edits. The index is read
# with `git ls-files --stage` (paths, modes, blob ids), never `git write-tree`, which writes
# objects.
set -uo pipefail

git rev-parse --is-inside-work-tree >/dev/null 2>&1 \
  || { echo "tree-fingerprint.sh: not a git repo"; exit 2; }
command -v shasum >/dev/null 2>&1 || { echo "tree-fingerprint.sh: shasum not found"; exit 2; }

sha() { shasum -a 256 | cut -d' ' -f1; }

# stdin: NUL-delimited untracked paths → one line per entry. A symlink is hashed by its target
# text (shasum would follow it, fail on a dangling or directory link and abort the whole snapshot).
untracked_hashes() {
  local f
  while IFS= read -r -d '' f; do
    if [ -L "$f" ]; then printf 'link %s %s\n' "$(readlink "$f")" "$f"
    elif [ -f "$f" ]; then shasum -a 256 "$f" || return 1
    else printf 'other %s\n' "$f"; fi
  done
}

# Every value is a checked assignment: `echo "K $(cmd)"` would mask a failed substitution and
# hash empty input, and two empty snapshots compare equal.
fingerprint() {
  local head refs index status diff untracked cfg cfg_sha local_sha
  head=$(git rev-parse HEAD) || return 2
  refs=$(git for-each-ref --format='%(refname) %(objectname)' | sha) || return 2
  index=$(git ls-files --stage -z | sha) || return 2
  status=$(git status --porcelain -z | sha) || return 2
  diff=$(git diff | sha) || return 2
  untracked=$(git ls-files -o --exclude-standard -z | untracked_hashes | sha) || return 2
  cfg=$(git rev-parse --git-path config) && [ -f "$cfg" ] || return 2
  cfg_sha=$(sha < "$cfg") || return 2
  # Ignored, so invisible to status/diff, yet it widens permissions — hashed explicitly.
  if [ -f .claude/settings.local.json ]; then
    local_sha=$(sha < .claude/settings.local.json) || return 2
  else local_sha=absent; fi
  printf 'HEAD %s\nREFS %s\nINDEX %s\nSTATUS %s\nDIFF %s\nUNTRACKED %s\n' \
    "$head" "$refs" "$index" "$status" "$diff" "$untracked"
  printf 'GIT_CONFIG %s\nSETTINGS_LOCAL %s\n' "$cfg_sha" "$local_sha"
}

capture() {
  local out
  out=$(fingerprint) || { echo "tree-fingerprint.sh: could not compute fingerprint"; exit 2; }
  if printf '%s\n' "$out" | grep -Evq '^[A-Z_]+ ([0-9a-f]{40,64}|absent)$'; then
    echo "tree-fingerprint.sh: incomplete fingerprint — refusing to write it"; exit 2
  fi
  mkdir -p "$(dirname "$1")" && printf '%s\n' "$out" > "$1" && echo "FINGERPRINT captured: $1"
}

compare() {
  local before="$1" after
  [ -f "$before" ] \
    || { echo "tree-fingerprint.sh: no fingerprint at $before — run capture first"; exit 2; }
  after=$(fingerprint) || { echo "tree-fingerprint.sh: could not compute fingerprint"; exit 2; }
  local delta
  if delta=$(diff "$before" <(printf '%s\n' "$after")); then
    echo "FINGERPRINT OK — checkout unchanged"; return 0
  fi
  echo "FINGERPRINT CHANGED — a read-only step wrote to the checkout:"
  printf '%s\n' "$delta" | grep '^[<>]' | awk '{print $2}' | sort -u
  return 1
}

usage() { echo "usage: tree-fingerprint.sh capture|compare <file>"; exit 2; }
case "${1:-}" in
  capture|compare) [ -n "${2:-}" ] || usage; "$1" "$2" ;;
  *) usage ;;
esac
