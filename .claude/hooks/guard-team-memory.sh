#!/bin/bash
# PreToolUse(Edit|Write) guard — team clones never write project memory, except the wrapup role
# (developer-approved, team-mode.md §4).
#
# Problem it solves: two team clones writing .agents/memory/ on two branches produce
# merge=union duplicates and contradictions. The commands carry team-mode paragraphs,
# but a prose rule is easy to miss in a long unattended session; this hook enforces it.
#
# Team mode ⇔ .agents/team/session.json exists (written by team-run.sh). Hook processes
# are not documented to inherit the session environment, so the file is the signal.
# Blocks (exit 2) Edit/Write under .agents/memory/ and of exactly docs/coding-standards.md (never
# docs/**; the wrapup writes it through team-standards.sh) in team mode; contract:
# .agents/reference/team-mode.md. MUST be registered synchronously. Fails open.

command -v jq >/dev/null 2>&1 || exit 0

ROOT="${CLAUDE_PROJECT_DIR:-$PWD}"
SESSION="$ROOT/.agents/team/session.json"
[ -f "$SESSION" ] || exit 0

PAYLOAD=$(cat)
FILE=$(printf '%s' "$PAYLOAD" | jq -r '.tool_input.file_path // ""' 2>/dev/null)
[ -z "$FILE" ] && exit 0

case "$FILE" in
  */.agents/memory/*|.agents/memory/*) WHAT=memory ;;
  *)
    # Exactly docs/coding-standards.md (never docs/**), resolved, so an alias or a symlink of
    # another name that points at it matches too.
    case "$FILE" in /*) ;; *) FILE="$ROOT/$FILE" ;; esac
    real() { python3 -I -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$1" 2>/dev/null; }
    P="$(real "$FILE")" && STD="$(real "$ROOT/docs/coding-standards.md")" \
      || { P="$(printf '%s' "${FILE#"$ROOT"/}" | sed -e 's#/\./#/#g' -e 's#^\./##')"; STD=docs/coding-standards.md; }
    [ "$P" = "$STD" ] || exit 0
    WHAT=standards ;;
esac
# The per-run TeamLead never writes memory, even while the wrapup stage runs; a stale lead neither.
if [ "${TEAM_SESSION_ROLE:-}" = TeamLead ]; then
  SID=$(printf '%s' "$PAYLOAD" | jq -r '.session_id // ""' 2>/dev/null)
  LIB="$(cd "$(dirname "$0")/../lib" 2>/dev/null && pwd)"
  # An empty sid would skip the session comparison in team_lead_caller: fail closed.
  if [ -n "$SID" ] \
    && (cd "$ROOT" && . "$LIB/team-lib.sh" && . "$LIB/team-lead-lib.sh" \
      && team_lead_caller "$SID") 2>/dev/null; then
    echo "TeamLead decides memory proposals; the wrapup writes them" >&2
  else
    echo "TeamLead identity not current — restart the lead" >&2
  fi
  [ -f "$(dirname "$0")/../lib/touches.sh" ] && bash "$(dirname "$0")/../lib/touches.sh" block --source guard-team-memory --what "TeamLead memory write" >/dev/null 2>&1  # hook-block log, never fails the guard
  exit 2
fi
[ "$(jq -r '.role // ""' "$SESSION" 2>/dev/null)" = wrapup ] && exit 0

RUN=$(jq -r '.run // "<run>"' "$SESSION" 2>/dev/null)
if [ "$WHAT" = standards ]; then
  echo "team mode: docs/coding-standards.md is written by the wrapup role only (team-standards.sh add, after the TeamLead accepts) — add the finding under ## Learnings, prefixed standards:, in .agents/team/runs/${RUN}/notes.md" >&2
  [ -f "$(dirname "$0")/../lib/touches.sh" ] && bash "$(dirname "$0")/../lib/touches.sh" block --source guard-team-memory --what "coding-standards write outside wrapup" >/dev/null 2>&1  # hook-block log, never fails the guard
  exit 2
fi
echo "team mode: project memory is written by the wrapup role only — add the lesson under ## Learnings in .agents/team/runs/${RUN}/notes.md (see .agents/reference/team-mode.md)" >&2
[ -f "$(dirname "$0")/../lib/touches.sh" ] && bash "$(dirname "$0")/../lib/touches.sh" block --source guard-team-memory --what "memory write outside wrapup" >/dev/null 2>&1  # hook-block log, never fails the guard
exit 2
