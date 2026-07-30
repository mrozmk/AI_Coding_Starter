#!/bin/bash
# PreToolUse(Bash) guard for `git commit`.
#
# Two jobs, both fail-closed-safe (default to allowing non-commit commands):
#   D1 (hard block): refuse a `git commit` whose staged set is EMPTY. This kills the
#       class where an orchestrate committer reports a SHA for a hallucinated/empty
#       commit — a prose contract cannot stop that; exit 2 can.
#   D2 (forensic log): for a real commit, append the staged file set to audit.log so a
#       post-hoc review can compare what each commit staged vs. what the plan declared.
#
# Mechanics (verified against Claude Code hooks docs):
#   - stdin carries the full PreToolUse JSON, incl. `.tool_input.command` and `.cwd`.
#     `.cwd` is the CALLER's working directory — NOT the directory the command ends up
#     running in. A committer that does `cd <worktree> && git commit` still reports the
#     repo root in `.cwd`, so trusting it alone reads the wrong index and blocks every
#     umbrella-mode step commit. Resolve the dir from the command itself first.
#   - exit 2 blocks the tool and feeds stderr back to Claude. exit 0 allows.
# MUST be registered as a SYNCHRONOUS hook (no "async": true) or the block won't apply.

PAYLOAD=$(cat)

CMD=$(printf '%s' "$PAYLOAD" | jq -r '.tool_input.command // ""' 2>/dev/null)
CWD=$(printf '%s' "$PAYLOAD" | jq -r '.cwd // ""' 2>/dev/null)
[ -z "$CMD" ] && exit 0

# Only act on `git commit`. Leave every other command untouched.
printf '%s' "$CMD" | grep -Eq '(^|[;&|[:space:]])git[[:space:]]+commit([[:space:]]|$)' || exit 0

# Skip forms where an empty staged set against the index is legitimate or harmless.
printf '%s' "$CMD" | grep -Eq -- '--amend|--dry-run|--no-edit|--help|(^|[[:space:]])-h([[:space:]]|$)' && exit 0

# Resolve the git dir to inspect. Order matters: a directory named IN the command is
# where the commit actually lands, so it beats the caller's cwd. Without this, umbrella
# mode (`cd <worktree> && git commit`) is checked against the repo-root index, which is
# empty — the guard then blocks a perfectly real commit.
DIR=""

# 1) explicit `git -C <dir> ... commit`
DIR=$(printf '%s' "$CMD" | sed -nE "s/.*git[[:space:]]+-C[[:space:]]+(\"([^\"]+)\"|'([^']+)'|([^[:space:]]+)).*/\2\3\4/p" | head -1)

# 2) leading `cd <dir> && ...` (the shape the orchestrate committer uses)
if [ -z "$DIR" ]; then
  DIR=$(printf '%s' "$CMD" | sed -nE "s/^[[:space:]]*cd[[:space:]]+(\"([^\"]+)\"|'([^']+)'|([^[:space:]&;|]+)).*/\2\3\4/p" | head -1)
fi

# 3) fall back to the caller's cwd, then the project root
[ -z "$DIR" ] && DIR="$CWD"
[ -z "$DIR" ] && DIR="$CLAUDE_PROJECT_DIR"
[ -z "$DIR" ] && DIR="$PWD"

# A dir taken from the command may be relative — resolve it against the caller's cwd.
case "$DIR" in
  /*) ;;
  *)  DIR="${CWD:-$PWD}/$DIR" ;;
esac

# If the resolved dir is not usable as a git dir, fall back rather than blocking a real
# commit on a parse artifact. The guard must fail toward its own correctness, not toward
# refusing work it simply could not locate.
git -C "$DIR" rev-parse --git-dir >/dev/null 2>&1 || DIR="${CWD:-${CLAUDE_PROJECT_DIR:-$PWD}}"

STAGED=$(git -C "$DIR" diff --cached --name-only 2>/dev/null)

if [ -z "$STAGED" ]; then
  # D1 — hard block. stderr is fed back to Claude as the block reason.
  echo "BLOCKED: 'git commit' with an empty staged set (git -C '$DIR' diff --cached is empty)." >&2
  echo "Nothing is staged for commit. If this is an orchestrate step, this is the empty/hallucinated-commit guard:" >&2
  echo "stage the real FILES_TOUCHED with explicit 'git add <path>' first, or report STATUS: nothing_to_commit." >&2
  exit 2
fi

# D2 — forensic log of the staged set (best-effort, never blocks).
# Only log when the .claude dir already exists; never create it, never error if absent.
if [ -n "$CLAUDE_PROJECT_DIR" ] && [ -d "$CLAUDE_PROJECT_DIR/.claude" ]; then
  L="$CLAUDE_PROJECT_DIR/.claude/audit.log"
  {
    TS=$(date '+%Y-%m-%d %H:%M:%S')
    printf '[%s] COMMIT staged in %s:\n' "$TS" "$DIR"
    printf '%s\n' "$STAGED" | sed 's/^/    /'
  } >> "$L" 2>/dev/null
  # Rotate like the other audit hooks.
  [ -f "$L" ] && [ "$(wc -l < "$L")" -gt 5000 ] && tail -n 2500 "$L" > "$L.tmp" && mv "$L.tmp" "$L"
fi

exit 0
