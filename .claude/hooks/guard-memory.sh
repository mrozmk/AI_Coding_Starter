#!/bin/bash
# PreToolUse(Edit|Write|MultiEdit) guard — memory-distillation enforcement (B3+C2).
#
# Problem it solves: in a mature project the append-only memory files
# (errors.md, patterns.md, decisions.md) grow to tens of thousands of tokens.
# A prose rule like "before writing code, read patterns.md" loads those monoliths
# reactively into the MAIN context window — most of it irrelevant to the task —
# until the window fills and earlier context is evicted (quality drift). A prose
# rule is also unenforceable: once it falls out of the window it silently stops.
#
# This hook makes the check ENFORCED and SCOPED:
#   - block-once-then-nudge: the FIRST code edit in a given domain in a given
#     session is hard-blocked (exit 2) with an instruction to delegate a
#     distillation subagent. After the agent creates the per-domain session
#     marker, every later edit in that domain passes untouched (no spam).
#   - the hook CANNOT spawn the subagent itself (bash has no Agent tool), so it
#     blocks + instructs; the agent delegates, absorbs the ~2k distillate into the
#     main window, and touches the marker.
#
# Generic-by-design (this is a starter template, stack-agnostic):
#   - SIZE GATE: stays fully dormant (exit 0) until errors+patterns+decisions
#     exceed `size_threshold_bytes`. Young/small projects feel nothing; the guard
#     switches itself on only once memory is large enough to be worth distilling.
#   - CONFIG-DRIVEN DOMAINS: path->domain mapping lives in
#     .claude/memory-domains.json (NOT hardcoded). No config / no matching rule
#     => domain `general` => exit 0 (soft, never a hard block). A fresh project
#     gets a working-but-silent hook; filling in memory-domains.json sharpens it.
#   - ACTIVE IN SUBAGENTS: no child-session skip. Subagents get a distinct
#     session_id => their own markers => each freshly checks memory (full
#     guarantee).
#
# Mechanics (Claude Code hooks): stdin carries the PreToolUse JSON incl.
# `.tool_input.file_path` and `.session_id`. exit 2 blocks the tool and feeds
# stderr back to Claude as the reason; exit 0 allows.
# MUST be registered SYNCHRONOUSLY (no "async": true) or the block won't apply.
#
# Fail-open everywhere: any missing dependency, unparsable payload, or absent
# session id => exit 0. A guard must never wedge legitimate edits on its own error.

command -v jq >/dev/null 2>&1 || exit 0

PAYLOAD=$(cat)

FILE=$(printf '%s' "$PAYLOAD" | jq -r '.tool_input.file_path // ""' 2>/dev/null)
[ -z "$FILE" ] && exit 0

# Session id keys the per-domain markers. Prefer the payload field; fall back to
# the env var. Without one we cannot scope markers => fail open.
SID=$(printf '%s' "$PAYLOAD" | jq -r '.session_id // ""' 2>/dev/null)
[ -z "$SID" ] && SID="$CLAUDE_CODE_SESSION_ID"
[ -z "$SID" ] && exit 0

ROOT="$CLAUDE_PROJECT_DIR"
[ -z "$ROOT" ] && ROOT="$PWD"

# Repo-relative path for matching/skip rules.
REL="${FILE#"$ROOT"/}"

# Hard skips — never a code domain. Memory/config edits, docs, and tests are out
# of scope regardless of the domain rules (avoids self-blocking and edit churn).
case "$REL" in
  .agents/*|*/.agents/*) exit 0 ;;
  .claude/*|*/.claude/*) exit 0 ;;
  *.test.*|*.spec.*|*/__tests__/*|*/__mocks__/*|*/test/*|*/tests/*) exit 0 ;;
  *.md|*.json|*.lock|*.yaml|*.yml|*.toml|*.txt|*.env*) exit 0 ;;
esac

# --- Resolve the domain from .claude/memory-domains.json -----------------------
# The lookup is shared with team-lead.sh digest-check; a missing library fails open.
. "$(dirname "$0")/lib/memory-domain.sh" 2>/dev/null || exit 0
memory_domain_config "$ROOT"
FALLBACK="$MEMORY_DOMAIN_FALLBACK"; THRESHOLD="$MEMORY_DOMAIN_THRESHOLD"
DOMAIN=$(memory_domain_for "$ROOT" "$REL")

[ -z "$DOMAIN" ] && DOMAIN="$FALLBACK"

# Fallback domain => soft, never a hard block. (Also covers "no config yet".)
[ "$DOMAIN" = "$FALLBACK" ] && exit 0

# Sanitize for use as a filename (defensive against odd capture groups).
DOMAIN=$(printf '%s' "$DOMAIN" | tr -c 'A-Za-z0-9_-' '_')
[ -z "$DOMAIN" ] && exit 0

# --- Size gate — stay dormant until memory is big enough to be worth distilling.
TOTAL=0
for f in errors.md patterns.md decisions.md; do
  p="$ROOT/.agents/memory/$f"
  if [ -f "$p" ]; then
    # BSD `wc -c` pads with leading spaces — strip all whitespace before validating.
    n=$(wc -c < "$p" 2>/dev/null | tr -d '[:space:]')
    printf '%s' "$n" | grep -Eq '^[0-9]+$' && TOTAL=$((TOTAL + n))
  fi
done
[ "$TOTAL" -lt "$THRESHOLD" ] && exit 0

# --- Marker check — block once per (session, domain), then pass. ---------------
MARKDIR="/tmp/claude-mem-${SID}"
MARK="${MARKDIR}/${DOMAIN}"
[ -f "$MARK" ] && exit 0

# Block. stderr is fed back to Claude as the block reason.
{
  echo "BLOCKED (memory guard): first code edit in domain \"$DOMAIN\" this session."
  echo "Project memory is large (${TOTAL} bytes across errors/patterns/decisions, threshold ${THRESHOLD})."
  echo "Loading it whole into this window would crowd out task context, so distill it FIRST:"
  echo
  echo "  1. Spawn a subagent (Agent tool, subagent_type: general-purpose) with a prompt that states:"
  echo "       - the domain: \"$DOMAIN\""
  echo "       - what you are about to do (the concrete task — you know it, the hook doesn't)"
  echo "       - \"Read .agents/memory/domain/$DOMAIN.md IN FULL if it exists (the domain's own lessons),"
  echo "          then errors.md, patterns.md and decisions.md, and return ONLY the entries relevant"
  echo "          to this task (~2k tokens). If an entry is cross-domain (env,"
  echo "          middleware, deploy, auth...) and touches the task, INCLUDE it even if outside the domain.\""
  echo "  2. Absorb the returned distillate, then create the marker so further \"$DOMAIN\" edits pass:"
  echo
  echo "       mkdir -p \"$MARKDIR\" && touch \"$MARK\""
  echo
  echo "Then re-issue this edit. (The marker records that memory was checked for this domain — it is"
  echo "trusted, like guard-commit trusts you to 'git add'. For a genuinely trivial change you may touch"
  echo "it directly; that is the deliberate decision point, not a proof of execution.)"
} >&2
[ -f "$(dirname "$0")/../lib/touches.sh" ] && bash "$(dirname "$0")/../lib/touches.sh" block --source guard-memory --what "first code edit in domain $DOMAIN — distill memory first" >/dev/null 2>&1  # hook-block log, never fails the guard
exit 2
