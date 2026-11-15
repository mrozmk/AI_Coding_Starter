#!/usr/bin/env bash
# finder-model.sh — prove each Step 1ab finder ran on the model and effort pinned in its agent
# file.
# Contract: .claude/commands/check-implementation.md → Step 1ab (barrier, model evidence).
#
# Usage:
#   bash .claude/lib/finder-model.sh <agent-type>=<agentId>…
#     e.g. correctness-reviewer=a1b2c3 structure-reviewer=d4e5f6
#          correctness-reviewer=a1b2c3 structure-reviewer-fallback=d4e5f6
#     exit 0 every finder matches · 1 mismatch (`<agent>: seen …, expected …` on stdout)
#     2 no / ambiguous / unreadable evidence (the gate stops)
#
# Evidence is bound to the given agent ids inside the current session (`CLAUDE_CODE_SESSION_ID`)
# under the active config dir (`CLAUDE_CONFIG_DIR`, default `~/.claude`): a "newest transcript of
# that type" pick reads another session's or a parallel run's finder and reports a false OK.
# The session's subagent dir is found by session id under `projects/*/` (the project segment maps
# the launch cwd, not the repo root); completion = meta `finished` ≠ false plus a delivered
# `=== END ` report in the agent's current run (after its last real prompt), so a finder resumed
# after an earlier report counts as running, not finished.
# The frontmatter is the single source of truth; the harness may substitute a model silently, and
# a preloaded skill runs at the agent's effort, so both are read from the transcript's
# `type=="assistant"` records (`.message.model`, top-level `.effort`), parsed with jq.
# `model: inherit` (the `*-fallback` finders) expects the main session's model: the last real
# assistant model in the session's own transcript `<sid>.jsonl`, next to its `subagents/` dir.
set -uo pipefail

[ $# -ge 1 ] || { echo "usage: finder-model.sh <agent-type>=<agentId>…"; exit 2; }
git rev-parse --is-inside-work-tree >/dev/null 2>&1 \
  || { echo "finder-model.sh: not a git repo"; exit 2; }

root=$(git rev-parse --show-toplevel) || exit 2
cfg="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
sid="${CLAUDE_CODE_SESSION_ID:-}"
[ -n "$sid" ] || { echo "finder-model.sh: no session id (CLAUDE_CODE_SESSION_ID)"; exit 2; }
[[ "$sid" =~ ^[A-Za-z0-9-]+$ ]] || { echo "finder-model.sh: bad session id '$sid'"; exit 2; }
shopt -s nullglob
hits=()
for d in "$cfg"/projects/*/"$sid"/subagents; do [ -d "$d" ] && hits+=("$d"); done
shopt -u nullglob
[ "${#hits[@]}" -ge 1 ] \
  || { echo "finder-model.sh: no subagent dir for session $sid under $cfg/projects"; exit 2; }
[ "${#hits[@]}" -eq 1 ] \
  || { echo "finder-model.sh: ambiguous session $sid: ${#hits[@]} subagent dirs"; exit 2; }
dir="${hits[0]}"
main_model=""  # resolved once, on the first `model: inherit` finder

frontmatter() {  # $1 agent file, $2 key → value or empty
  sed -n '/^---$/,/^---$/p' "$1" | sed -n "s/^$2:[[:space:]]*//p" | head -1
}

# A delivered report, within the current run (records after the last real user prompt; a system
# notification is not a prompt): the last assistant record ends the turn with the marker in its text,
# or it ends the turn / is the call itself after a successful SubagentHandback carrying the marker.
# The marker alone may be a quoted format followed by an interrupted tool call.
delivered='def has_end: type == "string" and contains("=== END ");
def prompt: .type == "user" and (.message.content | type == "string")
  and (.message.content | startswith("[SYSTEM NOTIFICATION") | not);
. as $all
| ([range(0; length) | select($all[.] | prompt)] | last // -1) as $p
| $all[($p + 1):] as $run
| [$run[] | select(.type == "assistant" and (.message.model // "") != "<synthetic>")] as $as
| [$as[].message.content[]? | select(.type? == "tool_use" and .name? == "SubagentHandback"
    and (.input.message | has_end)) | .id] as $ids
| [$run[] | select(.type == "user") | .message.content[]?
    | select(.type? == "tool_result" and .is_error? != true) | .tool_use_id] as $ok
| any($ids[]; . as $i | any($ok[]; . == $i)) as $handed
| ($as | last | .message) as $l
| ($as | length) > 0
  and (($l.stop_reason == "end_turn"
        and (any($l.content[]?; .type? == "text" and (.text | has_end)) or $handed))
    or ($handed and any($l.content[]?; .name? == "SubagentHandback")))'

types=" "; ids=" "
for arg in "$@"; do
  case "$arg" in *=*) ;; *) echo "finder-model.sh: '$arg' is not <type>=<id>"; exit 2 ;; esac
  type="${arg%%=*}"; id="${arg#*=}"
  [[ "$type" =~ ^[A-Za-z0-9-]+$ && "$id" =~ ^[A-Za-z0-9]+$ ]] \
    || { echo "finder-model.sh: bad argument '$arg'"; exit 2; }
  case "$types" in *" $type "*) echo "finder-model.sh: repeated type '$type'"; exit 2 ;; esac
  case "$ids" in *" $id "*) echo "finder-model.sh: repeated id '$id'"; exit 2 ;; esac
  types="$types$type "; ids="$ids$id "
done

rc=0
for arg in "$@"; do
  type="${arg%%=*}"; id="${arg#*=}"
  file="$root/.claude/agents/$type.md"
  [ -f "$file" ] || { echo "$type: no agent file $file"; exit 2; }
  want_model=$(frontmatter "$file" model); want_effort=$(frontmatter "$file" effort)
  [ -n "$want_model" ] && [ -n "$want_effort" ] \
    || { echo "$type: frontmatter lacks model: or effort:"; exit 2; }
  via=""
  if [ "$want_model" = inherit ]; then
    if [ -z "$main_model" ]; then
      # Streamed, not slurped: the main transcript is the session's whole history (tens of MB),
      # and it is live — a half-written last line must not discard the records before it.
      main_model=$({ jq -r 'select(.type == "assistant"
          and (.message.model // "<synthetic>") != "<synthetic>") | .message.model' \
        "${dir%/subagents}.jsonl" 2>/dev/null || true; } | tail -n 1)
      [ -n "$main_model" ] \
        || { echo "$type: model: inherit, but the session's own model is unreadable"; exit 2; }
    fi
    want_model="$main_model"; via=", fallback: session model"
  fi

  meta="$dir/agent-$id.meta.json"; jsonl="$dir/agent-$id.jsonl"
  [ -f "$meta" ] && [ -f "$jsonl" ] || { echo "$type: no meta/transcript for agent $id"; exit 2; }
  jq -e --arg t "$type" '.agentType == $t' "$meta" >/dev/null 2>&1 \
    || { echo "$type: agent $id is not a $type"; exit 2; }
  jq -e '.finished != false' "$meta" >/dev/null 2>&1 \
    || { echo "$type: agent $id not finished"; exit 2; }

  # `<synthetic>` is the placeholder model of a retried/interrupted message, not a model that ran.
  seen=$(jq -r -s '
    [.[] | select(.type == "assistant" and (.message.model // "") != "<synthetic>")]
    | if length == 0 then error("no assistant record") else . end
    | (map(.message.model // "none" | tostring) | unique | join(" ")),
      (map(.effort // "none" | tostring) | unique | join(" "))' "$jsonl" 2>/dev/null) \
    || { echo "$type: transcript $(basename "$jsonl") unreadable, truncated or no model"; exit 2; }
  { read -r seen_model; read -r seen_effort; } <<<"$seen"
  jq -e -s "$delivered" "$jsonl" >/dev/null 2>&1 \
    || { echo "$type: agent $id not finished"; exit 2; }

  bad=0
  if [ "$seen_model" != "$want_model" ]; then
    echo "$type: seen model '$seen_model', expected '$want_model'"; bad=1
  fi
  if [ "$seen_effort" != "$want_effort" ]; then
    echo "$type: seen effort '$seen_effort', expected '$want_effort'"; bad=1
  fi
  if [ "$bad" -eq 0 ]; then
    echo "$type: $seen_model / $seen_effort — OK ($(basename "$jsonl")$via)"
  else
    rc=1
  fi
done
[ "$rc" -eq 0 ] && echo "FINDER MODELS OK"
exit "$rc"
