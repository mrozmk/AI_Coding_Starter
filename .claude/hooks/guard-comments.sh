#!/bin/bash
# PostToolUse hook for Edit|Write|MultiEdit — non-blocking comment-noise nudge.
#
# Problem it solves: models narrate. Left alone they emit a comment per statement
# ("// increment the counter"), which reads as diligence but is pure noise: it
# restates the adjacent line, echoes a variable name, or repeats the signature.
# It also rots — the code changes, the narration does not. A prose rule in
# CLAUDE.md is unenforceable once it falls out of the context window; this hook
# re-states it at the exact moment a comment-heavy write lands.
#
# It NEVER blocks. It appends `additionalContext` asking the model to re-read its
# own diff and delete narration — the write already happened, so the cost of a
# false positive is one re-read, not a wedged edit.
#
# Generic-by-design (this is a starter template, stack-agnostic):
#   - DORMANT until configured. No .claude/comment-guard.json, or an empty
#     `src_globs`, => exit 0. A fresh project feels nothing; you switch the guard
#     on by naming your source directories.
#   - CONFIG-DRIVEN scope + thresholds (.claude/comment-guard.json). Nothing about
#     any particular stack is hardcoded here except the extension -> comment-syntax
#     map, which is a fact about languages, not about your project.
#
# Requires `jq`. Absent jq fails open (no-op) — check-deps.sh warns at SessionStart.
# Must exit 0 always: a PostToolUse hook that errors is noise on every write.

command -v jq >/dev/null 2>&1 || exit 0

INPUT=$(cat)

FILE=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // ""' 2>/dev/null)
[ -z "$FILE" ] && exit 0

ROOT="$CLAUDE_PROJECT_DIR"
[ -z "$ROOT" ] && ROOT="$PWD"
REL="${FILE#"$ROOT"/}"

CONFIG="$ROOT/.claude/comment-guard.json"
[ -f "$CONFIG" ] || exit 0

# --- Scope: does this path fall inside a configured source glob? ---------------
# Entries are matched with shell `case` globbing, where `*` spans `/` too — so
# `src/*` matches `src/lib/deep/file.ts`. Empty list => dormant.
NGLOBS=$(jq '.src_globs | length' "$CONFIG" 2>/dev/null)
printf '%s' "$NGLOBS" | grep -Eq '^[0-9]+$' || exit 0
[ "$NGLOBS" -eq 0 ] && exit 0

MATCHED=0
i=0
while [ "$i" -lt "$NGLOBS" ]; do
  G=$(jq -r ".src_globs[$i] // \"\"" "$CONFIG" 2>/dev/null)
  if [ -n "$G" ]; then
    case "$REL" in $G) MATCHED=1; break ;; esac
  fi
  i=$((i + 1))
done
[ "$MATCHED" -eq 0 ] && exit 0

# --- Out of scope regardless of globs ------------------------------------------
# Tests document intent and legitimately carry more prose. Generated files and
# vendored trees carry their own header conventions.
case "$REL" in
  *.test.*|*.spec.*|*_test.*|*Test.*|*/__tests__/*|*/__mocks__/*|*/test/*|*/tests/*) exit 0 ;;
  *.stories.*|*.story.*) exit 0 ;;
  */node_modules/*|*/vendor/*|*/dist/*|*/build/*|*/.venv/*) exit 0 ;;
esac

# --- Written content only: Write -> content, Edit -> new_string, MultiEdit -> all
CONTENT=$(printf '%s' "$INPUT" | jq -r '
  .tool_input.content
  // .tool_input.new_string
  // ([.tool_input.edits[]?.new_string] | join("\n"))
  // ""' 2>/dev/null)
[ -z "$CONTENT" ] && exit 0

case "$CONTENT" in *@generated*|*"DO NOT EDIT"*) exit 0 ;; esac

# --- Comment syntax by extension (a fact about languages, not about the project)
case "$REL" in
  *.html|*.htm|*.vue|*.svelte|*.xml|*.xhtml|*.astro)
      PATTERN='^[[:space:]]*<!--' ;;
  *.py|*.rb|*.sh|*.bash|*.zsh|*.pl|*.r|*.R|*.jl|*.ex|*.exs|*.tf|*.yaml|*.yml|*.toml)
      PATTERN='^[[:space:]]*#' ;;
  *.sql|*.lua|*.hs|*.elm|*.adb|*.ads)
      PATTERN='^[[:space:]]*--' ;;
  *.ts|*.tsx|*.js|*.jsx|*.mjs|*.cjs|*.java|*.kt|*.kts|*.go|*.rs|*.swift|*.c|*.h|*.cc|*.cpp|*.hpp|*.cs|*.scss|*.less|*.css|*.php|*.dart|*.scala|*.groovy|*.m|*.mm)
      PATTERN='^[[:space:]]*(//|/\*|\*)' ;;
  *)  exit 0 ;;
esac

# --- Thresholds ----------------------------------------------------------------
MINLINES=$(jq -r '.min_comment_lines // 3' "$CONFIG" 2>/dev/null)
printf '%s' "$MINLINES" | grep -Eq '^[0-9]+$' || MINLINES=3
MAXPCT=$(jq -r '.max_comment_percent // 15' "$CONFIG" 2>/dev/null)
printf '%s' "$MAXPCT" | grep -Eq '^[0-9]+$' || MAXPCT=15

TOTAL=$(printf '%s\n' "$CONTENT" | grep -c -v '^[[:space:]]*$')
COMMENTS=$(printf '%s\n' "$CONTENT" | grep -c -E "$PATTERN")

[ "$TOTAL" -eq 0 ] && exit 0
# The floor spares a single legitimate 1-2 line why-comment in a small edit.
[ "$COMMENTS" -le "$MINLINES" ] && exit 0
[ $((COMMENTS * 100 / TOTAL)) -le "$MAXPCT" ] && exit 0

jq -cn --arg c "$COMMENTS" --arg t "$TOTAL" '{
  hookSpecificOutput: {
    hookEventName: "PostToolUse",
    additionalContext: ("That write was \($c) comment lines out of \($t) non-blank lines. Re-read the diff and delete narration: a comment restating the adjacent statement, echoing a variable/function name, or repeating what the signature already says is noise. Keep only a WHY the code cannot express — a vendor quirk, a rejected alternative, a non-obvious invariant, or a workaround with a ticket reference — capped at 1-2 lines. Longer reasoning belongs in .agents/memory/ or the spec, with a one-line pointer from the code. See CLAUDE.md -> Style & Conventions.")
  }
}' 2>/dev/null

exit 0
