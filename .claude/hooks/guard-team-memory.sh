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
# Blocks (exit 2) Edit/Write under .agents/memory/ in team mode; contract:
# .agents/reference/team-mode.md. MUST be registered synchronously. Fails open.

command -v jq >/dev/null 2>&1 || exit 0

ROOT="${CLAUDE_PROJECT_DIR:-$PWD}"
SESSION="$ROOT/.agents/team/session.json"
[ -f "$SESSION" ] || exit 0

PAYLOAD=$(cat)
FILE=$(printf '%s' "$PAYLOAD" | jq -r '.tool_input.file_path // ""' 2>/dev/null)
[ -z "$FILE" ] && exit 0

case "$FILE" in
  */.agents/memory/*|.agents/memory/*) ;;
  *) exit 0 ;;
esac
[ "$(jq -r '.role // ""' "$SESSION" 2>/dev/null)" = wrapup ] && exit 0

RUN=$(jq -r '.run // "<run>"' "$SESSION" 2>/dev/null)
echo "team mode: project memory is written by the wrapup role only — add the lesson under ## Learnings in .agents/team/runs/${RUN}/notes.md (see .agents/reference/team-mode.md)" >&2
exit 2
