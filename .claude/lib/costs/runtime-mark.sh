#!/usr/bin/env bash
# Runtime log writer for the token-usage tool (TT-821); never fails its caller.
#
# Usage:
#   runtime-mark.sh session --provider claude|codex [--session ID]
#                   --source team-run|start-team|mail-tt|codex-bg [--name N] [--ticket T]
#                   [--team T] [--role R] [--run R] [--attempt N] [--parent ID] [--cwd DIR]
#                   [--team-json PATH]
#   runtime-mark.sh stage start|end NAME --session ID --source hook-skill|hook-prompt|skill-end
#                   [--tool-use-id ID]
#   runtime-mark.sh stage end NAME   # no --session: no-op — the stage hook records this call
#
# Opt-in: writes $AGENT_COSTS_HOME/runtime.jsonl only when that dir exists. Contract:
# .agents/reference/token-usage.md → Runtime log (TT-821).
set -uo pipefail

UUID_RE='^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
NAME_RE='^[A-Za-z0-9._:-]{1,64}$'
TICKET_RE='^[A-Z][A-Z0-9]+-[0-9]+$'
RUN_RE='^[a-z0-9]+-[0-9]{8}-[0-9]{6}$'
ATTEMPT_RE='^[0-9]{1,3}$'
TOOL_USE_RE='^[A-Za-z0-9_]{1,128}$'

home="${AGENT_COSTS_HOME:-$HOME/.agent-costs}"
[ -d "$home" ] || exit 0
command -v jq >/dev/null 2>&1 || { echo "runtime-mark: jq not found — mark skipped" >&2; exit 0; }

skip() { echo "runtime-mark: $1 — mark skipped" >&2; exit 0; }

# Prints the value when it matches the regex; a bad optional field is dropped, not fatal.
valid() { if [ -n "$1" ] && [[ "$1" =~ $2 ]]; then printf '%s' "$1"; fi; }

lower() { printf '%s' "$1" | tr 'A-Z' 'a-z'; }

abs_dir() { case "$1" in /*) [[ "$1" != *$'\n'* ]] && printf '%s' "$1" ;; esac; }

type="${1:-}"; shift || true
event=""; stage=""
if [ "$type" = stage ]; then
  event="${1:-}"; stage="${2:-}"
  shift 2 2>/dev/null || skip "stage needs start|end NAME"
fi

provider=""; session=""; session_set=0; source=""; name=""; ticket=""; team=""; role=""
run=""; attempt=""; parent=""; cwd=""; team_json=""; tool_use_id=""
while [ $# -gt 0 ]; do
  [ $# -ge 2 ] || skip "flag $1 has no value"
  case "$1" in
    --provider) provider="$2" ;;
    --session) session="$2"; session_set=1 ;;
    --source) source="$2" ;;
    --name) name="$2" ;;
    --ticket) ticket="$2" ;;
    --team) team="$2" ;;
    --role) role="$2" ;;
    --run) run="$2" ;;
    --attempt) attempt="$2" ;;
    --parent) parent="$2" ;;
    --cwd) cwd="$2" ;;
    --team-json) team_json="$2" ;;
    --tool-use-id) tool_use_id="$2" ;;
    *) skip "unknown flag $1" ;;
  esac
  shift 2
done

at_ms='now | (strftime("%Y-%m-%dT%H:%M:%S") + "."
  + ((. * 1000 | floor % 1000 | tostring) | ("00" + .)[-3:]) + "Z")'
drop_empty='with_entries(select(.value != null and .value != ""))'

if [ "$type" = stage ]; then
  case "$event" in start|end) ;; *) skip "stage event must be start or end" ;; esac
  [ "$event" = end ] && [ "$session_set" = 0 ] && exit 0
  session="$(lower "$session")"
  [[ "$session" =~ $UUID_RE ]] || skip "stage needs a session uuid"
  [[ "$stage" =~ $NAME_RE ]] || skip "bad stage name"
  case "$source" in hook-skill|hook-prompt|skill-end) ;; *) skip "bad stage source" ;; esac
  line="$(jq -cn --arg session "$session" --arg event "$event" --arg name "$stage" \
    --arg source "$source" --arg tool_use_id "$(valid "$tool_use_id" "$TOOL_USE_RE")" \
    "{v: 1, type: \"stage\", session: \$session, event: \$event, name: \$name,
      source: \$source, tool_use_id: \$tool_use_id, at: ($at_ms)} | $drop_empty")" \
    || skip "jq failed"
elif [ "$type" = session ]; then
  [ "$session_set" = 1 ] || session="${CLAUDE_CODE_SESSION_ID:-}"
  session="$(lower "$session")"
  [[ "$session" =~ $UUID_RE ]] || skip "session needs a uuid (--session or CLAUDE_CODE_SESSION_ID)"
  case "$provider" in claude|codex) ;; *) skip "bad provider" ;; esac
  case "$source" in team-run|start-team|mail-tt|codex-bg) ;; *) skip "bad session source" ;; esac
  if [ -n "$team_json" ] && [ -f "$team_json" ]; then
    IFS=$'\x1f' read -r j_ticket j_team j_role j_run j_attempt < <(jq -r \
      '[.ticket, .team, .role, .run, .attempt] | map(. // "" | tostring) | join("\u001f")' \
      "$team_json" 2>/dev/null)
    ticket="${ticket:-${j_ticket:-}}"; team="${team:-${j_team:-}}"; role="${role:-${j_role:-}}"
    run="${run:-${j_run:-}}"; attempt="${attempt:-${j_attempt:-}}"
  fi
  line="$(jq -cn --arg provider "$provider" --arg session "$session" --arg source "$source" \
    --arg name "$(valid "$name" "$NAME_RE")" --arg ticket "$(valid "$ticket" "$TICKET_RE")" \
    --arg team "$(valid "$team" "$NAME_RE")" --arg role "$(valid "$role" "$NAME_RE")" \
    --arg run "$(valid "$run" "$RUN_RE")" --arg attempt "$(valid "$attempt" "$ATTEMPT_RE")" \
    --arg parent "$(valid "$(lower "$parent")" "$UUID_RE")" --arg cwd "$(abs_dir "$cwd")" \
    "{v: 1, type: \"session\", provider: \$provider, session: \$session, source: \$source,
      name: \$name, ticket: \$ticket, team: \$team, role: \$role, run: \$run,
      attempt: (if \$attempt == \"\" then null else (\$attempt | tonumber) end),
      parent_session: \$parent, cwd: \$cwd, at: ($at_ms)} | $drop_empty")" \
    || skip "jq failed"
else
  skip "first argument must be session or stage"
fi

printf '%s\n' "$line" >> "$home/runtime.jsonl" || skip "cannot append to $home/runtime.jsonl"
exit 0
