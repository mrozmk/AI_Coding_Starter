#!/usr/bin/env bash
# Stage hook for the token-usage tool (TT-821): a Skill call or a typed /command starts a stage,
# the exact end-step Bash call ends it. Only a hook payload carries agent_id, so sub-agents are
# filtered here. Synchronous (async hooks can reorder marks); prints nothing; always exits 0.
set -uo pipefail

END_RE='^bash \.claude/lib/costs/runtime-mark\.sh stage end ([A-Za-z0-9._:-]{1,64})$'

command -v jq >/dev/null 2>&1 || exit 0

# Control characters become "?" so a multi-line command can never satisfy the anchored END_RE.
IFS=$'\x1f' read -r event session agent tool skill cmd tool_use_id expansion cname < <(jq -r '
  [.hook_event_name, .session_id, .agent_id, .tool_name, .tool_input.skill,
   .tool_input.command, .tool_use_id, .expansion_type, .command_name]
  | map(. // "" | tostring | gsub("[[:cntrl:]]"; "?")) | join("\u001f")' 2>/dev/null) \
  || exit 0

[ -z "$agent" ] || exit 0
mark="$(dirname "$0")/../lib/costs/runtime-mark.sh"

case "$event:$tool" in
  PreToolUse:Skill)
    [ -z "$skill" ] || bash "$mark" stage start "$skill" --session "$session" \
      --source hook-skill --tool-use-id "$tool_use_id" ;;
  PreToolUse:Bash)
    [[ "$cmd" =~ $END_RE ]] && bash "$mark" stage end "${BASH_REMATCH[1]}" \
      --session "$session" --source skill-end --tool-use-id "$tool_use_id" ;;
  UserPromptExpansion:*)
    [ "$expansion" = slash_command ] && [ -n "$cname" ] && bash "$mark" stage start \
      "${cname#/}" --session "$session" --source hook-prompt ;;
esac >&2
exit 0
