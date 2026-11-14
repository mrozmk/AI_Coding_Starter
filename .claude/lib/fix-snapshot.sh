#!/usr/bin/env bash
# fix-snapshot.sh — the tree id of the working tree as it is now: tracked changes, untracked
# files, deletions; ignored files excluded. /orchestrate Step 5.2 takes one before and one after
# a verifier fix iteration, so `git diff --name-only <before> <after>` is the fix's real scope —
# not the executor's own list of what it touched. Writes git objects (harmless), never the index
# or the working tree.
#
#   bash .claude/lib/fix-snapshot.sh            # anywhere inside the step's work tree (whole tree)
#   stdout: <tree id> · exit 0 = ok · 2 = not a git work tree or git failed
set -uo pipefail
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "fix-snapshot.sh: not a git work tree" >&2; exit 2; }
idx=$(mktemp "${TMPDIR:-/tmp}/fix-snapshot.XXXXXX") || exit 2
trap 'rm -f "$idx"' EXIT
real=$(git rev-parse --path-format=absolute --git-path index) || exit 2
# Seed from the real index so the snapshot starts from what git already tracks, then add the rest.
if [ -f "$real" ]; then cp "$real" "$idx" || exit 2; else rm -f "$idx"; fi
GIT_INDEX_FILE="$idx" git add -A :/ >/dev/null 2>&1 || { echo "fix-snapshot.sh: git add failed" >&2; exit 2; }
GIT_INDEX_FILE="$idx" git write-tree || exit 2
