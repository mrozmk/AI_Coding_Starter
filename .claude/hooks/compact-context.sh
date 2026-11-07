#!/usr/bin/env bash
# SessionStart hook, matcher `compact` — what the session must know again after a compaction.
#
# A compaction keeps the summary and reloads CLAUDE.md, rules/ and MEMORY.md; everything /prime
# loaded is gone. This prints the one thing a fresh context needs to find the rest on demand: the
# `## When to Read` routing table of .agents/memory/index.md, plus one line of repo state. Not the
# brief, not the architecture — those come back through the table when a task needs them (the
# /hc instructions in .claude/skills/cache-handoff name this file as "back from disk").
#
# Exits 0 and prints nothing when there is no index.md: a missing file is not a session problem.
set -u

root="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
index="$root/.agents/memory/index.md"
[ -f "$index" ] || exit 0

echo "Context after compaction — memory routing (from .agents/memory/index.md); read a file only when its row applies:"
echo
# The section runs from its heading to the next `## ` heading; blockquote notes are kept.
awk '/^## When to Read/{p=1; print; next} /^## /{if(p) exit} p' "$index"
echo
branch="$(git -C "$root" rev-parse --abbrev-ref HEAD 2>/dev/null || echo '?')"
dirty="$(git -C "$root" status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
sync=""
if up="$(git -C "$root" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null)"; then
  sync="$(git -C "$root" rev-list --left-right --count "$up...HEAD" 2>/dev/null \
    | awk '{printf " · behind %s / ahead %s", $1, $2}')"
fi
echo "Repo: branch $branch$sync · $dirty uncommitted file(s)"
exit 0
