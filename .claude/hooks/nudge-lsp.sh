#!/bin/bash
# PostToolUse hook for Grep — non-blocking LSP nudge.
#
# OPTIONAL — only useful when the project has an LSP wired up (typescript-lsp,
# gopls, rust-analyzer, etc.). It is registered in settings.json but harmless if
# no LSP is configured: it only ever appends a suggestion, never blocks. Drop the
# settings.json PostToolUse(Grep) entry if your stack has no symbol-level LSP.
#
# When a Grep call looks like a SYMBOL search (an identifier-shaped pattern,
# not narrowed to non-code files), append additionalContext reminding the
# model that LSP gives precise symbol navigation. Never blocks, never errors.
#
# Silent unless the pattern is clearly a symbol lookup — most Greps (text,
# config, content, regex) pass through untouched.
#
# Must exit 0 always.

INPUT=$(cat)

PATTERN=$(printf '%s' "$INPUT" | jq -r '.tool_input.pattern // ""' 2>/dev/null)
GLOB=$(printf '%s'   "$INPUT" | jq -r '.tool_input.glob   // ""' 2>/dev/null)
GREP_PATH=$(printf '%s' "$INPUT" | jq -r '.tool_input.path // ""' 2>/dev/null)

[ -z "$PATTERN" ] && exit 0

# Only nudge when the pattern is a bare identifier (symbol-shaped):
#   starts with a letter/underscore, >=3 chars, only word chars — no spaces,
#   no regex metacharacters, no dots. A real text/regex search won't match.
printf '%s' "$PATTERN" | grep -Eq '^[A-Za-z_][A-Za-z0-9_]{2,}$' || exit 0

# Skip if the search is explicitly scoped to non-code files (legit Grep use).
case "$GLOB$GREP_PATH" in
  *.json|*.md|*.mdx|*.css|*.scss|*.yml|*.yaml|*.txt|*.html|*.lock) exit 0 ;;
esac

jq -cn --arg p "$PATTERN" '{
  hookSpecificOutput: {
    hookEventName: "PostToolUse",
    additionalContext: ("Searched for the symbol \"" + $p + "\" with Grep. If you are navigating code (where is it defined, who calls it, its signature) and this project has an LSP wired up, the LSP tool is more precise — goToDefinition / findReferences / incomingCalls / hover return real symbol references, not text matches. Grep stays correct for free-text and non-code files.")
  }
}' 2>/dev/null

exit 0
