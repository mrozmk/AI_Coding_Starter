#!/usr/bin/env bash
# Supervisor + sub-agents section of the dashboard snapshot (TT-783, split out by TT-826).
# Sourced by team-snapshot.sh: relies on its globals (W, root, PROJ, SID, NOW, SUP_UNKNOWN) and
# helpers (err, age, mtime, iso, jl_tail, jl_first_ts, skill_trail). Function definitions only.

# agent_def <type> → {owner, preloaded}: the first /command in the agent's description and its
# `skills:` list. Preloaded skills run inline, so the transcript never shows a Skill call for them.
agent_def() {
  local c="$W/agentdef-$1.json" f="$root/.claude/agents/$1.md"
  if [[ ! "$1" =~ ^[A-Za-z0-9_-]+$ ]] || [ ! -f "$f" ]; then
    echo '{"owner":null,"preloaded":[]}'; return 0
  fi
  [ -f "$c" ] || awk 'NR == 1 && /^---/ {fm = 1; next} fm && /^---/ {exit}
      fm && /^description:/ {print "d\t" substr($0, 13); next}
      fm && /^skills:/ {sk = 1; next}
      sk && /^  - / {sub(/^  - /, ""); print "s\t" $0; next}
      {sk = 0}' "$f" | jq -Rn '[inputs | split("\t")] as $l
      | {owner: ([$l[] | select(.[0] == "d") | .[1]
                  | [match("(^|\\s)(/[a-z][a-z0-9:-]*)"; "g")][0].captures[1].string][0]),
         preloaded: [$l[] | select(.[0] == "s") | .[1]]}' > "$c"
  cat "$c"
}

snap_supervisor() {
  local f="$PROJ/$SID.jsonl" st=idle sk
  if [ -z "$SID" ] || [ ! -f "$f" ]; then
    err "supervisor: no transcript ${SID:-found} under $PROJ"
    echo "$SUP_UNKNOWN"
    return 0
  fi
  [ "$(age "$f")" -ge 60 ] || st=running
  sk="$(skill_trail "$f")" || { err "supervisor: skill trail unreadable"; sk=null; }
  # `<synthetic>` is the placeholder of a retried/interrupted message, not a model that ran.
  jl_tail "$f" | jq -s --arg s "$SID" --arg st "$st" --arg at "$(iso "$(mtime "$f")")" \
    --argjson skills "$sk" '
    ([.[] | select(.type == "assistant" and .message.model != "<synthetic>")] | last) as $a
    | {session_id: $s, model: $a.message.model, effort: $a.effort, status: $st, last_at: $at,
       skills: $skills}'
}

sub_one() {  # sub_one <transcript> <age secs> → one sub-agent object
  local f="$1" id meta="${1%.jsonl}.meta.json" m='{}' def trail
  id="$(basename "$f" .jsonl)"; id="${id#agent-}"
  [ ! -f "$meta" ] || m="$(jq -c 'if type == "object" then . else {} end' "$meta" 2>/dev/null)" \
    || m='{}'
  [ -n "$m" ] || m='{}'
  def="$(agent_def "$(jq -r '.agentType // ""' <<<"$m")")"
  trail="$(skill_trail "$f")" || trail='[]'
  jl_tail "$f" | jq -cs --arg id "$id" --argjson m "$m" --argjson age "$2" \
    --arg started "$(jl_first_ts "$f")" --arg last "$(iso "$(mtime "$f")")" \
    --argjson def "$def" --argjson trail "$trail" '
    ([.[] | select(.type == "assistant" and .message.model != "<synthetic>")] | last) as $g
    | ([.[] | select(.type == "assistant" or .type == "user")] | last) as $l
    | (if $l.type == "assistant" and $l.message.stop_reason == "end_turn" then "done"
     elif $l.type == "user" and any($g.message.content[]?;
       .type? == "tool_use" and .name? == "SubagentHandback"
       and (.id? as $call | $call != null
         and any($l.message.content[]?;
           .type? == "tool_result" and .tool_use_id? == $call
           and .is_error? != true))) then "done"
     elif $age < 120 then "running"
     # A pending tool call (a long build, a test run) writes nothing until it returns.
     elif $l.type == "assistant" and any($l.message.content[]?;
       .type? == "tool_use" and .name? != "SubagentHandback")
       and $age < 3600 then "running"
     else "idle" end) as $st
    | {id: $id, type: $m.agentType, description: $m.description,
       model: $g.message.model, effort: $g.effort, status: $st,
       finished_at: (if $st == "done" then $last else null end),
       started_at: (if $started == "" then null else $started | sub("\\.[0-9]+Z$"; "Z") end),
       last_at: $last, owner: $def.owner,
       runs: (($def.preloaded | map({skill: ("/" + .), how: "preloaded"}))
              + (if ($m.name // "") != "" then [{skill: ("/" + $m.name), how: "fork"}] else [] end)
              + ($trail | map({skill, how: "invoked"}))
              | reduce .[] as $x ([]; if any(.[]; .skill == $x.skill) then . else . + [$x] end))}'
}

snap_subagents() {
  local d="$PROJ/$SID/subagents" f a o
  [ -n "$SID" ] && [ -d "$d" ] || { echo '[]'; return 0; }
  ls -1t "$d"/agent-*.jsonl > "$W/sublist" 2>/dev/null || true
  : > "$W/suball"
  while IFS= read -r f; do
    a="$(age "$f")"
    [ "$a" -lt 21600 ] || continue
    if o="$(sub_one "$f" "$a")"; then
      printf '%s\n' "$o" >> "$W/suball"
    else
      err "subagents: unreadable $(basename "$f")"
    fi
  done < "$W/sublist"
  # Every live one and every finish < 10 min stays (the UI shows those as cards, map-codebase fans
  # out 16); older finishes fill the expandable history up to 12 finished, newest first.
  jq -s --argjson now "$NOW" 'def fresh: $now - (.last_at | fromdateiso8601) < 600;
    map(select(.status != "done")) as $live | map(select(.status == "done")) as $done
    | ($done | map(select(fresh))) as $fresh | ($done | map(select(fresh | not))) as $old
    | $live + $fresh + $old[0:([12 - ($fresh | length), 0] | max)]' "$W/suball" > "$W/subkept"
  a=$(( $(jq -s 'length' "$W/suball") - $(jq 'length' "$W/subkept") ))
  [ "$a" = 0 ] || err "subagents: $a older finished hidden"
  jq -c '.[] | ({at: .started_at, source: "supervisor", text: "spawned \(.type // "agent")"}),
    (select(.status == "done")
     | {at: .last_at, source: "supervisor", text: "finished \(.type // "agent")"})' \
    "$W/subkept" >> "$W/events"
  cat "$W/subkept"
}
