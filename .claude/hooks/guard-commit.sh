#!/bin/bash
# PreToolUse(Bash) guard for `git commit`.
#
# Three jobs, all fail-closed-safe (default to allowing non-commit commands):
#   D1 (hard block): refuse a `git commit` whose staged set is EMPTY. Side effect by design:
#       a chained `git add X && git commit` is ALWAYS blocked — the hook runs before the chain,
#       so the index is still empty. Commands must stage and commit in two calls.
#       Original D1 rationale: refuse a `git commit` whose staged set is EMPTY. This kills the
#       class where an orchestrate committer reports a SHA for a hallucinated/empty
#       commit — a prose contract cannot stop that; exit 2 can.
#   D3 (hard block): scan the staged diff's added lines and the staged (non-deleted) file
#       names for credentials with the guard-push patterns (hooks/lib/leak-patterns.sh).
#       `-a`/`--amend` forms exit before D3, so push stays the publication boundary for them.
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

# Only act on `git commit` (incl. `git -C <dir> commit`). Leave every other command untouched.
# A commit the plain match misses — in `( … )`, `$( … )`, backticks or `<shell> -c '…'` — is found by
# the segmenter (hooks/lib/git-segments.sh) and checked as that segment; quoted text never matches.
if ! printf '%s' "$CMD" | grep -Eq "(^|[;&|[:space:]])git([[:space:]]+-C[[:space:]]+(\"[^\"]*\"|'[^']*'|[^[:space:]]+))*[[:space:]]+commit([[:space:]]|\$)"; then
  GS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/git-segments.sh"
  [ -r "$GS" ] || exit 0
  . "$GS"
  CMD=$(git_first "$CMD" commit) || exit 0
fi

# Skip forms where the index is not what gets committed, or nothing is committed.
# `-a`/`--all` (incl. combined `-am`) stages tracked modifications at commit time, so
# an empty index is normal for it — blocking it with "nothing staged" is a false hit.
printf '%s' "$CMD" | grep -Eq -- '--amend|--dry-run|--help|--all([[:space:]]|$)|(^|[[:space:]])-[a-zA-Z]*a[a-zA-Z]*([[:space:]]|$)|(^|[[:space:]])-h([[:space:]]|$)' && exit 0
# `--no-edit` (e.g. concluding a merge) may legitimately commit an empty index: skip D1
# only — whatever IS staged still goes through the D3 scan.
NO_EDIT=0
printf '%s' "$CMD" | grep -Eq -- '--no-edit' && NO_EDIT=1

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

if [ -z "$STAGED" ] && [ "$NO_EDIT" = 0 ]; then
  # D1 — hard block. stderr is fed back to Claude as the block reason.
  echo "BLOCKED: 'git commit' with an empty staged set (git -C '$DIR' diff --cached is empty)." >&2
  echo "Nothing is staged for commit. If this is an orchestrate step, this is the empty/hallucinated-commit guard:" >&2
  echo "stage the real FILES_TOUCHED with explicit 'git add <path>' first, or report STATUS: nothing_to_commit." >&2
  exit 2
fi

# D3 — staged credential scan. Reports paths and classes only, never a matched line.
HOOK_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
if [ ! -r "$HOOK_DIR/lib/leak-patterns.sh" ]; then
  echo "guard-commit: hooks/lib/leak-patterns.sh missing — staged secret scan SKIPPED. Sync it from the starter with the hooks." >&2
else
  D3_REPORT=$(
    export LC_ALL=C LANG=C
    . "$HOOK_DIR/lib/leak-patterns.sh"
    leak_scan "$(git -C "$DIR" diff --cached --no-color 2>/dev/null | leak_added_lines)"
    # Deletions excluded: unstaging a credential file by `git rm` must not block.
    LEAK_HITS_FILE=$(git -C "$DIR" diff --cached --name-only --diff-filter=d 2>/dev/null | leak_file_hits)
    leak_report "Credential file staged"
  )
  if [ -n "$D3_REPORT" ]; then
    {
      echo "BLOCKED: guard-commit found likely credentials in the staged changes."
      echo ""
      printf '%s\n' "$D3_REPORT"
      echo ""
      echo "How to resolve: move the value to an ignored local file, a secret store, or a *.example"
      echo "file with an empty value, and unstage the file. A real test fixture → add an inline"
      echo "'guard-push:allow' marker on that line."
    } >&2
    exit 2
  fi
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
