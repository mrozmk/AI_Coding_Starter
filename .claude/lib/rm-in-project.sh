#!/usr/bin/env bash
#
# rm-in-project.sh — recursive delete, scoped to this repository and its git worktrees.
#
# WHY: bare `rm -rf` is ask-tier (settings.json), and an allow glob cannot be scoped to a directory
# because `*` also matches spaces and further arguments. This script is the allow-listed way to
# delete inside the project: every path is resolved and the whole call is refused unless each one
# lies strictly inside a worktree root. Never a root itself, nothing under .git or the repository's
# git dir (which `--separate-git-dir` may place under any name), no .env* file, and never the guard
# layer — `.claude/settings*.json` or `.claude/hooks` — or a directory holding any of these.
#
# Every refusal compares lower-cased paths: on a case-insensitive file system (macOS default)
# `.GIT` or `.ENV` reach the real `.git` / `.env`, and `pwd -P` keeps the caller's spelling. On a
# case-sensitive one this over-refuses a file literally named `.GIT` — the wrapper fails closed.
# Only the "inside a root" test stays case-sensitive: there a mismatch merely refuses.
#
# Usage: bash .claude/lib/rm-in-project.sh <path>...

set -euo pipefail
[ $# -gt 0 ] || { echo "usage: rm-in-project.sh <path>..." >&2; exit 2; }

HERE="$(cd "$(dirname "$0")" && pwd -P)"
COMMON="$(git -C "$HERE" rev-parse --path-format=absolute --git-common-dir)"
COMMON="$(cd "$COMMON" && pwd -P)"
lc() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }
CL="$(lc "$COMMON")"
ROOTS=""
while IFS= read -r R; do
  if [ -d "$R" ]; then ROOTS="$ROOTS$(cd "$R" && pwd -P)"$'\n'; fi
# --show-toplevel too: with a git dir nested in the work tree (`--separate-git-dir`) git lists the git
# dir itself as the main worktree; the COMMON guard below keeps that bogus root undeletable.
done <<< "$(git -C "$HERE" worktree list --porcelain | sed -n 's/^worktree //p'; git -C "$HERE" rev-parse --show-toplevel)"

# Location of the path itself, not of a symlink's target: rm removes the link, never follows it.
resolve() {
  local p="$1"
  if [ -d "$p" ] && [ ! -L "$p" ]; then
    (cd "$p" && pwd -P)
  else
    echo "$(cd "$(dirname "$p")" && pwd -P)/$(basename "$p")"
  fi
}

TARGETS=()
for ARG in "$@"; do
  # A trailing slash on a symlinked dir would make rm delete the target's contents.
  while [ "${ARG%/}" != "$ARG" ] && [ "$ARG" != / ]; do ARG="${ARG%/}"; done
  if [ ! -e "$ARG" ] && [ ! -L "$ARG" ]; then echo "skip (absent): $ARG"; continue; fi
  P="$(resolve "$ARG")"; PL="$(lc "$P")"
  INSIDE=0
  while IFS= read -r R; do
    [ -n "$R" ] || continue
    RL="$(lc "$R")"
    if [ "$PL" = "$RL" ]; then echo "refused (worktree root): $P" >&2; exit 1; fi
    case "$P" in "$R"/*) INSIDE=1 ;; esac
    case "$PL/" in "$RL"/.claude/hooks/*) echo "refused (guard layer): $P" >&2; exit 1 ;; esac
    case "$PL" in "$RL"/.claude/settings*.json) echo "refused (guard layer): $P" >&2; exit 1 ;; esac
  done <<< "$ROOTS"
  [ "$INSIDE" = 1 ] || { echo "refused (outside the project): $P" >&2; exit 1; }
  case "$PL" in */.git|*/.git/*) echo "refused (git metadata): $P" >&2; exit 1 ;; esac
  case "$PL/" in "$CL"/*) echo "refused (git metadata): $P" >&2; exit 1 ;; esac
  case "$(basename "$PL")" in .env*) echo "refused (.env file): $P" >&2; exit 1 ;; esac
  if [ -d "$ARG" ] && [ ! -L "$ARG" ]; then
    while IFS= read -r R; do
      [ -n "$R" ] || continue
      RL="$(lc "$R")"
      case "$RL/" in "$PL"/*) echo "refused (contains worktree $R): $P" >&2; exit 1 ;; esac
      case "$RL/.claude/" in "$PL"/*) echo "refused (contains the guard layer $R/.claude): $P" >&2; exit 1 ;; esac
    done <<< "$ROOTS"
    case "$CL" in "$PL"/*) echo "refused (contains git metadata $COMMON): $P" >&2; exit 1 ;; esac
    HIT="$(find "$ARG" \( -iname .git -o -iname '.env*' \) -print -quit)"
    [ -z "$HIT" ] || { echo "refused (contains $HIT): $P" >&2; exit 1; }
  fi
  TARGETS+=("$ARG")
done

for T in ${TARGETS[@]+"${TARGETS[@]}"}; do
  rm -rf -- "$T"
  echo "removed: $T"
done
