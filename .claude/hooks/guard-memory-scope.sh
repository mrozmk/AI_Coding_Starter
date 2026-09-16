#!/bin/bash
# PostToolUse hook for Edit|Write|MultiEdit — non-blocking scope nudge for
# .agents/memory/errors.md.
#
# Problem it solves: `errors.md` is loaded WHOLE whenever anyone debugs, so every
# entry that is not about the shipped application taxes every future investigation.
# The reflection prose says "bug -> errors.md" and, without this hook, nothing checks
# the claim — harness, shell and test-runner lessons pile up there.
#
# This hook classifies the text just written and, when it smells like a misrouted
# entry, appends additionalContext naming the correct destination. It NEVER blocks:
# a false positive must not wedge a legitimate write. Signals, any one of which fires:
#   - harness markers  (.claude/, slash command, hook, subagent, zsh, rg, design file…)
#   - test markers     (.spec., test runner, Storybook, Playwright, jsdom…)
#   - no app-source citation: the entry names no application source path, so rule 1
#     of the file's own Scope section is unmet
#
# Generic-by-design: DORMANT until `.claude/memory-domains.json` carries a non-empty
# `app_source_regex` (what an application source path looks like in this project).
# Requires `jq`, like nudge-files.sh. Fails open (no-op) if jq is absent.
# Must exit 0 always.

command -v jq >/dev/null 2>&1 || exit 0

INPUT=$(cat)

# Fork-free dismissal: only writes that mention errors.md can concern this hook.
case "$INPUT" in *'.agents/memory/errors.md'*) ;; *) exit 0 ;; esac

FILE=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // ""' 2>/dev/null)
[ -z "$FILE" ] && exit 0

# The Edit payload may carry an absolute or a repo-relative path.
case "$FILE" in
  */.agents/memory/errors.md|.agents/memory/errors.md) : ;;
  *) exit 0 ;;
esac

ROOT="$CLAUDE_PROJECT_DIR"
[ -z "$ROOT" ] && ROOT="$PWD"
CONFIG="$ROOT/.claude/memory-domains.json"
[ -f "$CONFIG" ] || exit 0

APP_RE=$(jq -r '.app_source_regex // ""' "$CONFIG" 2>/dev/null)
[ -z "$APP_RE" ] && exit 0

CONTENT=$(printf '%s' "$INPUT" | jq -r '
  .tool_input.content
  // .tool_input.new_string
  // ([.tool_input.edits[]?.new_string] | join("\n"))
  // ""' 2>/dev/null)
[ -z "$CONTENT" ] && exit 0

# A rewrite of the file's own Scope/Format preamble is maintenance, not an entry.
printf '%s' "$CONTENT" | grep -q '^## Scope' && exit 0

HARNESS_RE='\.claude/|\.agents/|slash command|slash-command|subagent|MCP |orchestrate|/gates:|\bhooks?\b|PreToolUse|PostToolUse|\bzsh\b|\bbash\b|ripgrep|\brg \b|git merge|git rebase|design file|Jira ticket|design ticket|review comment|DevTools'
TEST_RE='\.spec\.|\.test\.|test runner|Storybook|Playwright|jsdom|coverage threshold|snapshot test'

REASONS=""
printf '%s' "$CONTENT" | grep -Eq "$HARNESS_RE" && REASONS="${REASONS}harness/workflow markers; "
printf '%s' "$CONTENT" | grep -Eq "$TEST_RE" && REASONS="${REASONS}test-harness markers; "
printf '%s' "$CONTENT" | grep -Eq "$APP_RE" || REASONS="${REASONS}no application source path cited; "

[ -z "$REASONS" ] && exit 0

jq -cn --arg r "${REASONS%; }" '{
  hookSpecificOutput: {
    hookEventName: "PostToolUse",
    additionalContext: ("That write to .agents/memory/errors.md tripped the scope check (\($r)). errors.md is APPLICATION CODE ONLY — it is loaded whole on every debugging session, so a misrouted entry taxes all of them. Re-read the entry against the Scope section at the top of the file and move it if it belongs elsewhere: a broken slash command, hook, subagent, MCP server, shell/git/CLI invocation, a lying debugging tool, or a misread design file / ticket / review comment -> .agents/memory/domain/harness.md. A spec, test-runner, jsdom, Storybook or Playwright trap -> .agents/memory/domain/testing.md. Anything scoped to one module -> that module'"'"'s domain/*.md. An entry that stays must name the application source file it is about. If none of that applies, the entry likely fails the bar entirely — the default outcome of a reflection pass is to write nothing; delete it.")
  }
}' 2>/dev/null

exit 0
