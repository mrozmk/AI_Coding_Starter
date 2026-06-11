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
#   - stdin carries the full PreToolUse JSON, incl. `.tool_input.command` and `.cwd`
#     (`.cwd` = the dir the Bash command will run in — the worktree in umbrella mode,
#      the repo root in flat mode; using it makes the staged-index check hit the RIGHT
#      git index in both modes).
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

# Resolve the git dir to inspect: the command's cwd if usable, else the project root.
DIR="$CWD"
[ -z "$DIR" ] && DIR="$CLAUDE_PROJECT_DIR"
[ -z "$DIR" ] && DIR="$PWD"

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
