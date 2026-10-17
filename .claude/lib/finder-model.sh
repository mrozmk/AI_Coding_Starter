#!/usr/bin/env bash
# finder-model.sh — prove each Step 1ab finder ran on the model and effort pinned in its agent
# file.
# Contract: .claude/commands/check-implementation.md → Step 1ab (barrier, model evidence).
#
# Usage:
#   bash .claude/lib/finder-model.sh <agent-name>…   # correctness-reviewer structure-reviewer
#     exit 0 every agent matches · 1 mismatch (`<agent>: seen …, expected …` on stdout)
#     2 no transcript / unreadable agent file
#
# The frontmatter is the single source of truth; the newest `*.meta.json` whose `agentType`
# matches names the transcript. The harness may substitute a model silently, and a preloaded skill
# runs at the agent's effort, so both are read from the transcript's `message.model` / `effort`.
set -uo pipefail

[ $# -ge 1 ] || { echo "usage: finder-model.sh <agent-name>…"; exit 2; }
git rev-parse --is-inside-work-tree >/dev/null 2>&1 \
  || { echo "finder-model.sh: not a git repo"; exit 2; }

root=$(git rev-parse --show-toplevel) || exit 2
# Claude Code maps every non-alphanumeric character of the path to `-`.
proj="$HOME/.claude/projects/$(printf '%s' "$root" | sed 's/[^A-Za-z0-9]/-/g')"
[ -d "$proj" ] || { echo "finder-model.sh: no transcript dir $proj"; exit 2; }

frontmatter() {  # $1 agent file, $2 key → value or empty
  sed -n '/^---$/,/^---$/p' "$1" | sed -n "s/^$2:[[:space:]]*//p" | head -1
}

rc=0
for agent in "$@"; do
  bad=0
  file="$root/.claude/agents/$agent.md"
  [ -f "$file" ] || { echo "$agent: no agent file $file"; exit 2; }
  want_model=$(frontmatter "$file" model); want_effort=$(frontmatter "$file" effort)
  [ -n "$want_model" ] || { echo "$agent: no model: in frontmatter"; exit 2; }

  meta=$(ls -t "$proj"/*/subagents/*.meta.json 2>/dev/null \
    | xargs grep -l "\"agentType\":\"$agent\"" 2>/dev/null | head -1)
  [ -n "$meta" ] && [ -f "${meta%.meta.json}.jsonl" ] \
    || { echo "$agent: no transcript with agentType $agent under $proj"; exit 2; }
  jsonl="${meta%.meta.json}.jsonl"

  # `<synthetic>` is the placeholder model of a retried/interrupted message, not a model that ran.
  seen() {
    grep -o "\"$1\":\"[^\"]*\"" "$jsonl" | cut -d'"' -f4 | grep -vx '<synthetic>' | sort -u \
      | tr '\n' ' ' | sed 's/ $//'
  }
  seen_model=$(seen model); seen_effort=$(seen effort)
  [ -n "$seen_model" ] || { echo "$agent: transcript $jsonl has no model field"; exit 2; }

  if [ "$seen_model" != "$want_model" ]; then
    echo "$agent: seen model '$seen_model', expected '$want_model'"; bad=1
  fi
  if [ -n "$want_effort" ] && [ "$seen_effort" != "$want_effort" ]; then
    echo "$agent: seen effort '${seen_effort:-none}', expected '$want_effort'"; bad=1
  fi
  [ "$bad" -eq 0 ] || rc=1
  [ "$bad" -eq 0 ] \
    && echo "$agent: $seen_model${seen_effort:+ / $seen_effort} — OK ($(basename "$jsonl"))"
done
[ "$rc" -eq 0 ] && echo "FINDER MODELS OK"
exit "$rc"
