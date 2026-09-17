#!/usr/bin/env bash
# PreToolUse + PostToolUse hook for the built-in LSP tool — tsserver warm-up gate.
#
# Problem it solves: tsserver loads a TypeScript project only when a file from it is
# opened. Cold, a cross-project query (findReferences, incomingCalls, …) answers with
# the current project's hits ONLY — no error, nothing in the result says it is partial.
# Measured on an Nx monorepo with 25 tsconfig projects (Claude Code 2.1.273): rg+Read
# missed 3 of 20 references to an overloaded name, LSP after warm-up found 20/20; a
# root solution-style tsconfig referencing every project warmed nothing.
#
# Mechanics — one script, two registrations in settings.json (both synchronous):
#   - PostToolUse(LSP): a SUCCESSFUL documentSymbol / hover / goToDefinition records
#     its file as opened. Recording here, not in PreToolUse, so a failed call cannot
#     mark a project warm.
#   - PreToolUse(LSP): a cross-project operation on a TS/JS file is DENIED while any
#     warm-up file is still unopened; the reason lists the remaining files and the
#     exact call to make. This is a gate that re-checks progress on every call — a
#     "deny once, then set a marker" variant is bypassed by a plain retry (measured).
# The hook cannot warm tsserver itself: the server is a child of Claude Code, not
# reachable from a shell. It blocks + instructs; the agent opens the files.
#
# Scope — dormant (exit 0) unless ALL of these hold:
#   - jq is on PATH;
#   - CLAUDE.md mentions `warm-lsp` — the generated `## Code Navigation (LSP)` section
#     announces the denial as project behaviour; without that notice the model treats
#     the denial as prompt injection and works around it (measured). A project synced
#     from the starter gets this hook before its CLAUDE.md is regenerated, so the hook
#     must stay quiet until the announcement exists;
#   - the call targets a TS/JS file (`.ts .tsx .js .jsx .mts .cts`) — pyright, gopls
#     and intelephense index the whole workspace at startup, so a polyglot repo must
#     not have its Python/Go/PHP queries blocked by TypeScript warm-up;
#   - at least one warm-up file exists.
#
# Warm-up files: `.claude/lsp-warmup.txt` when present (one repo-relative path per
# line, `#` comments and blank lines ignored, paths that do not exist are ignored so a
# stale entry can never block forever); else discovered — every directory holding a
# `tsconfig*.json` (node_modules, dist, build, coverage, .git pruned), one entry file
# (`src/index.*` or `src/main.*`, else the first non-test source) plus one test file
# (`*.spec.*` / `*.test.*`). Two files per directory on purpose: `tsconfig.spec.json`
# is a separate tsserver project. A directory with no candidate (a solution-only root
# config) is skipped — its projects carry their own tsconfig.
#
# State: `${TMPDIR:-/tmp}/claude-lsp-warm-<session_id>` — the documented payload
# field, the same key guard-memory.sh uses. KNOWN LIMITATION, not yet measured: a
# subagent may carry its own session_id while sharing the parent's tsserver, in which
# case it pays the warm-up again (repeated cost, never a wrong answer).
#
# Fail-open everywhere: any missing dependency, unparsable payload or absent session
# id => exit 0. `find`, never `rg` — inside a hook `rg` can resolve to a shell shim.

set -u
command -v jq >/dev/null 2>&1 || exit 0

PAYLOAD=$(cat)
EVENT=$(printf '%s' "$PAYLOAD" | jq -r '.hook_event_name // ""' 2>/dev/null)
OP=$(printf '%s' "$PAYLOAD"    | jq -r '.tool_input.operation // ""' 2>/dev/null)
FP=$(printf '%s' "$PAYLOAD"    | jq -r '.tool_input.filePath // ""' 2>/dev/null)
SID=$(printf '%s' "$PAYLOAD"   | jq -r '.session_id // ""' 2>/dev/null)
if [ -z "$OP" ] || [ -z "$FP" ] || [ -z "$SID" ]; then exit 0; fi

ROOT="${CLAUDE_PROJECT_DIR:-$PWD}"
cd "$ROOT" 2>/dev/null || exit 0
grep -q 'warm-lsp' CLAUDE.md 2>/dev/null || exit 0

case "$FP" in
  *.ts|*.tsx|*.js|*.jsx|*.mts|*.cts) ;;
  *) exit 0 ;;
esac

REL="${FP#"$ROOT"/}"
REL="${REL#./}"
MARKER="${TMPDIR:-/tmp}/claude-lsp-warm-$SID"

# --- PostToolUse: record a successful open ------------------------------------
if [ "$EVENT" = "PostToolUse" ]; then
  case "$OP" in
    documentSymbol|hover|goToDefinition) printf '%s\n' "$REL" >>"$MARKER" ;;
  esac
  exit 0
fi

# --- PreToolUse: gate cross-project operations --------------------------------
case "$OP" in
  findReferences|incomingCalls|outgoingCalls|workspaceSymbol|goToImplementation|prepareCallHierarchy) ;;
  *) exit 0 ;;
esac

SRC=( \( -name '*.ts' -o -name '*.tsx' -o -name '*.js' -o -name '*.jsx' -o -name '*.mts' -o -name '*.cts' \) )
PRUNE=( \( -name node_modules -o -name dist -o -name build -o -name coverage -o -name .git \) -prune -o )

if [ -f .claude/lsp-warmup.txt ]; then
  WANT=$(grep -vE '^[[:space:]]*(#|$)' .claude/lsp-warmup.txt | sed 's#^\./##' | while IFS= read -r f; do
    [ -f "$f" ] && printf '%s\n' "$f"
  done)
else
  WANT=$(find . "${PRUNE[@]}" -name 'tsconfig*.json' -print 2>/dev/null | sed 's#/[^/]*$##' | sort -u | while IFS= read -r d; do
    entry=$(find "$d/src" -maxdepth 1 \( -name 'index.*' -o -name 'main.*' \) "${SRC[@]}" -print 2>/dev/null | sort | head -1)
    [ -n "$entry" ] || entry=$(find "$d" "${PRUNE[@]}" -type f "${SRC[@]}" -not -name '*.spec.*' -not -name '*.test.*' -not -name '*.d.ts' -print 2>/dev/null | sort | head -1)
    test=$(find "$d" "${PRUNE[@]}" -type f \( -name '*.spec.*' -o -name '*.test.*' \) "${SRC[@]}" -print 2>/dev/null | sort | head -1)
    [ -n "$entry" ] && printf '%s\n' "$entry"
    [ -n "$test" ]  && printf '%s\n' "$test"
  done | sed 's#^\./##' | sort -u)
fi
[ -n "$WANT" ] || exit 0

touch "$MARKER" 2>/dev/null || exit 0
MISSING=$(comm -23 <(printf '%s\n' "$WANT" | sort -u) <(sort -u "$MARKER"))
[ -n "$MISSING" ] || exit 0
N=$(printf '%s\n' "$MISSING" | wc -l | tr -d ' ')
MISSING=$(printf '%s' "$MISSING" | tr '\n' ' ')

jq -cn --arg r "[project hook .claude/hooks/warm-lsp.sh] $OP is blocked until tsserver is warm — cold, it silently returns only the current project's hits. Open the remaining $N warm-up file(s) with LSP documentSymbol (line 1, character 1), then retry this exact call. Remaining: $MISSING" \
  '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}' 2>/dev/null
exit 0
