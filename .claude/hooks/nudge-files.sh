#!/bin/bash
# PostToolUse hook for Edit|Write|MultiEdit — non-blocking per-file-class reminder.
#
# Problem it solves: some rules only matter in one corner of the tree — what may be
# added to a central token file, what a migration may contain, what an export in a
# public barrel commits you to. Those rules live in CLAUDE.md, which the model may
# not be holding by the time it writes there. This restates the rule for that file
# class at the moment the write lands.
#
# Sibling of guard-comments.sh and deliberately built to the same shape: same stdin
# read, same jq extraction, same exclusion list, same fail-open stance. Both may fire
# on one write — they carry different concerns, and neither suppresses the other.
#
# It NEVER blocks. It appends `additionalContext`; the write already happened, so a
# false positive costs one re-read, not a wedged edit.
#
# Generic-by-design (this is a starter template, stack-agnostic):
#   - DORMANT until configured. No .claude/nudge-rules.json, or an empty `rules`
#     array, => exit 0. A fresh project feels nothing.
#   - Nothing about any stack is hardcoded here; the file classes and their messages
#     are entirely the project's, in .claude/nudge-rules.json.
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

CONFIG="$ROOT/.claude/nudge-rules.json"
[ -f "$CONFIG" ] || exit 0

NRULES=$(jq '.rules | length' "$CONFIG" 2>/dev/null)
printf '%s' "$NRULES" | grep -Eq '^[0-9]+$' || exit 0
[ "$NRULES" -eq 0 ] && exit 0

# --- Out of scope regardless of rules ------------------------------------------
# Same exclusions as guard-comments.sh: tests carry their own conventions, and
# generated or vendored trees are not ours to lecture about.
case "$REL" in
  *.test.*|*.spec.*|*_test.*|*Test.*|*/__tests__/*|*/__mocks__/*|*/test/*|*/tests/*) exit 0 ;;
  *.stories.*|*.story.*) exit 0 ;;
  */node_modules/*|*/vendor/*|*/dist/*|*/build/*|*/.venv/*) exit 0 ;;
esac

CONTENT=$(printf '%s' "$INPUT" | jq -r '
  .tool_input.content
  // .tool_input.new_string
  // ([.tool_input.edits[]?.new_string] | join("\n"))
  // ""' 2>/dev/null)
case "$CONTENT" in *@generated*|*"DO NOT EDIT"*) exit 0 ;; esac

# --- First matching rule wins ---------------------------------------------------
# Entries are matched with shell `case` globbing, where `*` spans `/` too — so
# `src/*` matches `src/lib/deep/file.ts`.
i=0
while [ "$i" -lt "$NRULES" ]; do
  G=$(jq -r ".rules[$i].glob // \"\"" "$CONFIG" 2>/dev/null)
  if [ -n "$G" ]; then
    case "$REL" in
      $G)
        MSG=$(jq -r ".rules[$i].message // \"\"" "$CONFIG" 2>/dev/null)
        [ -z "$MSG" ] && exit 0
        jq -cn --arg m "$MSG" --arg f "$REL" '{
          hookSpecificOutput: {
            hookEventName: "PostToolUse",
            additionalContext: ("Reminder for \($f): \($m)")
          }
        }' 2>/dev/null
        exit 0
        ;;
    esac
  fi
  i=$((i + 1))
done

exit 0
