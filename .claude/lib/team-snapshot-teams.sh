#!/usr/bin/env bash
# Teams + "waiting for you" section of the dashboard snapshot.
# Sourced by team-snapshot.sh: relies on its globals (W, root, PROJ, TMUX_OK) and helpers (err,
# event, mtime, jl_first_ts, skill_trail), on team_* from team-lib/roles/modes.sh and on pr_state
# (team-pr-state.sh). Function definitions only.

# pane_prompt_kind <session> → permission | menu | checkbox | review | none (team_prompt.py's
# complete parse), else unreadable — the caller then falls back to the screen regexes.
pane_prompt_kind() {
  local k
  k="$(team_pane_history "$1" 200 | python3 -I "$root/.claude/lib/team_prompt.py" parse \
    2>/dev/null | jq -r 'if .complete then .kind else "unreadable" end' 2>/dev/null)" \
    || k=unreadable
  case "$k" in permission|menu|checkbox|review|none) echo "$k" ;; *) echo unreadable ;; esac
}

# team_actions <team> <role> <status> <prompt kind> → JSON array of copyable commands. For
# `attention` they follow the pane in /monitor's order: menu → pick/other, permission prompt →
# yes/no, else say. An unreadable kind uses the greps; menu first there: a Yes/No
# AskUserQuestion also matches team_prompt_open's `❯ 1. Yes`.
team_actions() {
  local k="" pane
  if [ "$3" = attention ]; then
    case "${4:-unreadable}" in
      menu) k=menu ;;
      permission) k=prompt ;;
      none|checkbox|review) k=text ;;
      *)
        pane="$(team_pane "$1-$2" 40)"
        if grep -qF 'Enter to select' <<<"$pane" && grep -qF 'Type something.' <<<"$pane"; then
          k=menu
        elif team_prompt_open "$1-$2"; then k=prompt
        else k=text; fi ;;
    esac
  fi
  jq -cn --arg t "$1" --arg r "$2" --arg s "$3" --arg k "$k" '
    "bash .claude/lib/team-answer.sh \($t) \($r)" as $a
    | "bash .claude/lib/team-attach.sh \($t) \($r)" as $at
    | if $s != "attention" then [$at, "\($a) say \"<answer>\"", "/start-team \($t)"]
      elif $k == "prompt" then ["\($a) yes", "\($a) no \"<reason>\"", $at]
      elif $k == "menu" then ["\($a) pick <n>", "\($a) other \"<answer>\"", $at]
      else ["\($a) say \"<answer>\"", $at] end'
}

# role_session <session> → alive | absent | unknown. A failed probe alone is not proof of absence
# (socket or protocol errors after a tmux upgrade): only these two messages are.
role_session() {
  local out
  out="$(tmux has-session -t "=$1" 2>&1)" && { echo alive; return 0; }
  case "$out" in
    *"can't find session"*|*"no server running"*) echo absent ;;
    *"error connecting to"*"No such file"*) echo absent ;;
    *) err "tmux: $1: ${out:-has-session failed without a message}"; echo unknown ;;
  esac
}

# attention_pending <attention file> <transcript> → 0 when a notification at or after the
# transcript's last write is an open question; 1-s clocks, so same second counts. permission_prompt
# lines are skipped: an approved prompt during a long tool run would stick, and team_prompt_open
# already covers an open one.
attention_pending() {
  local at
  at="$(awk 'NF && $2 != "permission_prompt" {l = $1} END {print l}' "$1")"
  at="$(date -u -j -f %Y-%m-%dT%H:%M:%SZ "$at" +%s 2>/dev/null)" || return 1
  [ "$at" -ge "$(mtime "$2")" ]
}

# record_open <td> <record file or ""> <runner> → 0 when the record still waits on someone; the
# live_status rule, evaluated apart from the pane (live_status answers attention/stopped first).
record_open() {
  local v
  [ -n "$2" ] || return 1
  v="$(jq -r '.verdict // empty' "$2" 2>/dev/null)" || return 1
  case "$v" in blocked|failed) ;; *) return 1 ;; esac
  [ "$(basename "$2")" != "$(cat "$1/acked" 2>/dev/null || true)" ] || [ "$3" != up ]
}

# attended_pending <td> <run> → 0 when an attended role's question may still be open although
# role_transcript did not identify the transcript. Uncertain stays open: only the role's own
# session file (session.json session_id) can close it, never another session's write.
attended_pending() {
  local td="$1" att="$1/runs/$2/attention" sid f
  [ -s "$att" ] || return 1
  sid="$(jq -r '.session_id // empty' "$td/session.json" 2>/dev/null)" || sid=""
  f="$(dirname "$PROJ")/$(team_project_slug "${td%/.agents/team}")/$sid.jsonl"
  if [ -n "$sid" ] && [ -f "$f" ]; then
    attention_pending "$att" "$f"
  else
    awk 'NF && $2 != "permission_prompt" {n++} END {exit !n}' "$att"
  fi
}

# team_screen <session> <prompt open> → redacted lines for team-watch: an open permission prompt
# shows its whole command block from the history (a long command scrolls off 15 visible lines).
team_screen() {
  local b=""
  if [ "$2" = true ]; then
    b="$(team_pane_history "$1" 200 | python3 -I "$root/.claude/lib/team_prompt_check.py" --block \
      2>/dev/null | team_redact | tail -n 40)" || b=""
  fi
  if [ -n "$b" ]; then printf '%s\n' "$b"; else team_pane "$1" 15 | team_redact; fi
}

# live_fields <td> <team> <run> <role> <transcript or ""> <status> <prompt open> <menu open> → one
# JSON object with the current role's fields team-watch filters on (additive to schema 1).
live_fields() {
  local td="$1" team="$2" run="$3" role="$4" tf="$5" st="$6" po="$7" mo="$8"
  local att="$1/runs/$3/attention" anchor="" ac=0 ap=false adp=false live=true
  [ "$st" != stopped ] || live=false
  if [ "$TMUX_OK" = 1 ] && [ "$live" = true ]; then anchor="$(team_pane_anchor "$team-$role")"; fi
  [ ! -f "$att" ] || ac="$(wc -l < "$att" | tr -d ' ')"
  if [ -n "$tf" ] && [ -s "$att" ] && attention_pending "$att" "$tf"; then ap=true; fi
  case "$role" in
    planner|wrapup) if [ -z "$tf" ] && attended_pending "$td" "$run"; then adp=true; fi ;;
  esac
  jq -cn --argjson live "$live" --argjson po "$po" --argjson mo "$mo" --arg anchor "$anchor" \
    --argjson ac "$ac" --argjson ap "$ap" --argjson adp "$adp" '
    {live: $live, prompt_open: $po, menu_open: $mo, anchor: $anchor, attention_count: $ac,
     attention_pending: $ap, attended_pending: $adp}'
}

# live_status <td> <run> <role> <attempt> <runner> <transcript or ""> <session> <prompt open>
# <menu open> → status of the role in session.json; <session> is role_session's answer, or "" when
# tmux is unusable.
live_status() {
  local td="$1" run="$2" role="$3" attempt="$4" runner="$5" tf="$6" ra
  local att="$td/runs/$run/attention"
  case "$7" in
    absent) echo stopped; return 0 ;;
    alive) ;;
    *) echo unknown; return 0 ;;
  esac
  if [ "$8" = true ] || [ "$9" = true ]; then echo attention; return 0; fi
  ra="$(ls -1t "$td/runs/$run/$role-$attempt"-*.json 2>/dev/null | head -n 1)" || true
  if record_open "$td" "$ra" "$runner"; then jq -r .verdict "$ra"; return 0; fi
  # After the record check (a role idling on a blocked record fires idle_prompt too).
  if [ -n "$tf" ] && [ -s "$att" ] && attention_pending "$att" "$tf"; then
    echo attention; return 0
  fi
  echo running
}

# role_transcript <td> <team> <role> <run> <attempt> → the live role's transcript path, or nothing.
# Only when unambiguous: one transcript started after the launch whose first prompt is this role's;
# a plain session or a resumed conversation in the clone must never be shown as the role.
role_transcript() {
  local td="$1" team="$2" role="$3" run="$4" attempt="$5" dir at f ts n=0 hit="" first=""
  at="$(jq -r '.launched_at // empty' "$td/session.json" 2>/dev/null)" || at=""
  [ -n "$at" ] || return 0
  dir="$(dirname "$PROJ")/$(team_project_slug "${td%/.agents/team}")"
  for f in "$dir"/*.jsonl; do
    [ -f "$f" ] || continue
    ts="$(jl_first_ts "$f" | sed -E 's/\.[0-9]+Z$/Z/')"
    [ -n "$ts" ] && ! [[ "$ts" < "$at" ]] || continue
    n=$((n + 1)); hit="$f"
  done
  # No `| head -n 1` after jq: under pipefail its SIGPIPE would turn a found prompt into a failure.
  [ "$n" = 1 ] && first="$(head -c 262144 "$hit" | jq -cRn '[inputs | fromjson? | select(.type == "user")]
    | first | .message.content // "" | if type == "string" then . else (map(.text? // "") | join("")) end' \
    2>/dev/null)" || first=""
  # Prompts wrap lines, so each identity token is matched on its own.
  if [ -n "$first" ] && grep -qF "the $role of team $team" <<<"$first" \
    && grep -qF "run \`$run\`" <<<"$first" && grep -qF "attempt \`$attempt\`" <<<"$first"; then
    echo "$hit"
  else
    err "$team/$role: transcript not identified ($n candidates)"
  fi
}

team_role() {  # team_role <td> <team> <run> <role> <cur role> <runner> <override> <base or "" if invalid>
  local td="$1" team="$2" run="$3" role="$4" cur="$5" runner="$6" ov="$7" base="$8"
  local r="" rec='null' verdict="" status=pending attempt=null cfg='{}' screen='[]' actions='[]'
  local skills=null tf rop=false live='{}' sess="" po=false mo=false pk=unreadable
  [ -z "$run" ] || r="$(ls -1t "$td/runs/$run/$role"-*.json 2>/dev/null | head -n 1)" || true
  [ -z "$r" ] || rec="$(jq -c --arg f "$(basename "$r")" \
    '{file: $f, verdict, message, written_at, attempt}' "$r" 2>/dev/null)" || rec='null'
  [ -n "$rec" ] || rec='null'
  verdict="$(jq -r '.verdict // empty' <<<"$rec")"
  attempt="$(jq -r '.attempt // null' <<<"$rec")"
  ! record_open "$td" "$r" "$runner" || rop=true
  if [ "$verdict" = done ] && [ -e "$r.accepted" ]; then
    status=done
  elif [ "$role" = "$cur" ]; then
    attempt="$(jq -r '.attempt // null' "$td/session.json")" || attempt=null
    [[ "$attempt" =~ ^[0-9]+$ ]] || attempt=null
    tf="$(role_transcript "$td" "$team" "$role" "$run" "$attempt")"
    # One pane probe per fact, shared by status and the team-watch fields.
    [ "$TMUX_OK" = 0 ] || sess="$(role_session "$team-$role")"
    if [ "$sess" = alive ]; then
      # The parse knows busy/idle; the regexes stay only as the fail-open fallback.
      pk="$(pane_prompt_kind "$team-$role")"
      case "$pk" in
        permission) po=true ;;
        menu|checkbox|review) mo=true ;;
        none) ;;
        *)
          ! team_prompt_open "$team-$role" || po=true
          ! team_menu_open "$team-$role" || mo=true ;;
      esac
    fi
    status="$(live_status "$td" "$run" "$role" "$attempt" "$runner" "$tf" "$sess" "$po" "$mo")"
    [ -z "$tf" ] || skills="$(skill_trail "$tf")" || { err "$team/$role: skill trail unreadable"; skills=null; }
    live="$(live_fields "$td" "$team" "$run" "$role" "$tf" "$status" "$po" "$mo")"
  else
    case "$verdict" in blocked|failed) status="$verdict" ;; esac
  fi
  if jq -e '.prompt_open or .menu_open or .attended_pending' <<<"$live" >/dev/null \
    || [[ "$status" =~ ^(attention|blocked|failed)$ ]]; then
    screen="$(team_screen "$team-$role" "$po" | jq -R . | jq -sc .)"
  fi
  case "$status" in
    attention|blocked|failed) actions="$(team_actions "$team" "$role" "$status" "$pk")" ;;
  esac
  if [ "$role" = cli ]; then
    cfg="$(jq -cn --arg m "$TEAM_CLI_MODEL" --arg e "$TEAM_CLI_EFFORT" '{model: $m, effort: $e}')"
  else
    if [ -n "$base" ]; then
      cfg="$(team_role_cfg "$base" "$ov" "$role" 2>/dev/null)" || cfg='{}'
    fi
    [ -n "$cfg" ] || cfg='{}'
  fi
  jq -cn --arg role "$role" --argjson cfg "$cfg" --argjson attempt "$attempt" \
    --arg status "$status" --argjson rec "$rec" --argjson screen "$screen" \
    --argjson actions "$actions" --argjson skills "$skills" --arg cur "$cur" \
    --argjson rop "$rop" --argjson live "$live" '
    {role: $role, model: $cfg.model, effort: $cfg.effort, attempt: $attempt, status: $status,
     record: (if $rec == null then null else $rec | del(.attempt) end),
     screen: $screen, actions: $actions, record_open: $rop}
    # Only the live role has a transcript to read; for the others "skills ?" would be misleading.
    + (if $role == $cur then {skills: $skills} + $live else {} end)'
}

team_events() {  # team_events <td> <team> <run> — records, launch, attention lines
  local td="$1" team="$2" run="$3" line
  jq -c --arg t "$team" '{at: .written_at, source: "\($t)/\(.role)",
    text: ("record \(.verdict) #\(.seq)"
           + (if (.message // "") != "" then ": \(.message)" else "" end))}' \
    "$W/recs" >> "$W/events"
  [ ! -f "$td/session.json" ] || jq -c --arg t "$team" '{at: .launched_at, source: "\($t)/\(.role)",
    text: "launched attempt \(.attempt)"}' "$td/session.json" >> "$W/events" 2>/dev/null \
    || err "$team: unreadable session.json"
  # The hook does not record the role, so attention lines are attributed to the team only.
  [ -n "$run" ] && [ -f "$td/runs/$run/attention" ] || return 0
  while IFS= read -r line; do
    [ -z "$line" ] || event "${line%% *}" "$team" "${line#* }"
  done < "$td/runs/$run/attention"
}

# team_esc_unsent <td> <run> → one {q, seq, since, state, reason} line per escalating/escalated
# question whose outstanding request has no `sent:`.
team_esc_unsent() {
  local f q seq since state reason
  for f in "$1/runs/$2/questions"/q-*.md; do
    [ -f "$f" ] && [[ "$(basename "$f")" =~ ^q-[0-9]+\.md$ ]] || continue
    case "$(team_q_state "$f" | cut -f1)" in escalating|escalated) ;; *) continue ;; esac
    q="$(basename "$f" .md)"
    IFS=$'\t' read -r seq since state reason <<<"$(esc_unsent "$f")" || true
    [ -n "$seq" ] || continue
    jq -cn --arg q "$q" --arg seq "$seq" --arg since "$since" --arg state "$state" \
      --arg reason "$reason" '{q: $q, seq: ($seq | tonumber? // $seq), since: $since,
      state: $state, reason: $reason}'
  done
}

# team_escalations <td> <run> → one line per q with a ledger: the inputs of the escreply and
# silence signals. `replies` holds real Advisor replies only, never an empty late read.
team_escalations() {
  local f q waiter tr
  for f in "$1/runs/$2/questions"/q-*.md; do
    [ -f "$f" ] && [[ "$(basename "$f")" =~ ^q-[0-9]+\.md$ ]] || continue
    grep -qx '## Escalation' "$f" || continue
    q="$(basename "$f" .md)"; waiter="$(esc_waiter "$f")"
    tr="$(esc_lines "$f" | awk '
      /^waited: / { t = t sep_t $2; sep_t = " "; w = 1; next }
      /^outcome: no-reply — timeout after/ { if (!w) lt = 1; w = 0; next }
      /^outcome: (late-pending-operator)$/ { r1 = 1; w = 0; next }
      /^outcome: / { w = 0; next }
      /^reply: [^ ]+ (answer|withdrawn)$/ { r1 = 1; next }
      /^waiting: operator / { r = r sep_r $3; sep_r = " "; next }
      /^ended: / { if (lt) { t = t sep_t $2; sep_t = " " }
        if (r1) { r = r sep_r $2; sep_r = " " }; lt = 0; r1 = 0 }
      END { printf "%s\t%s\n", t, r }')"
    jq -cn --arg q "$q" --arg role "$(esc_field "$f" role)" --arg tier "$(esc_tier "$f")" \
      --arg class "$(esc_class "$f")" --arg thread "esc-$2-$q" \
      --arg state "$(team_q_state "$f" | cut -f1)" --arg last "$(esc_last_outcome "$f")" \
      --arg waiter "$waiter" --arg t "${tr%%$'\t'*}" --arg r "${tr#*$'\t'}" '
      {q: $q, role: $role, tier: ($tier | tonumber? // $tier), class: $class, thread: $thread,
       state: $state, last_outcome: (if $last == "" then null else $last end), waiter: $waiter,
       timeouts: ($t | split(" ") | map(select(. != ""))),
       replies: ($r | split(" ") | map(select(. != "")))}'
  done
}

snap_team() {  # snap_team <clone .agents/team dir> → team object
  local td="$1" team run runner=down pid cur="" role f ov base problem mode pr prs="" last fin
  team="$(jq -r .team "$td/team.json")"
  mode="$(team_mode "$td/team.json" 2>/dev/null)" || { err "$team: bad mode in team.json"; mode=brainstorm; }
  run="$(cat "$td/run" 2>/dev/null || true)"
  # The lock owner is authoritative: the runner may run via run_in_background, without tmux.
  if [ -d "$td/lock" ]; then
    pid="$(cat "$td/lock/pid" 2>/dev/null || true)"
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then runner=up; else runner=stale; fi
  fi
  [ ! -f "$td/session.json" ] || cur="$(jq -r '.role // empty' "$td/session.json" 2>/dev/null)" \
    || err "$team: unreadable session.json"
  : > "$W/recs"; : > "$W/esc"; : > "$W/escs"
  if [ -n "$run" ]; then
    team_esc_unsent "$td" "$run" > "$W/esc" || err "$team: escalation ledgers unreadable"
    team_escalations "$td" "$run" > "$W/escs" || err "$team: escalation ledgers unreadable"
    for f in "$td/runs/$run"/*-*-*.json; do
      [ -f "$f" ] || continue
      jq -c . "$f" >> "$W/recs" 2>/dev/null || err "$team: unreadable $(basename "$f")"
    done
  fi
  base="$root/.claude/team/roles.json"
  [ -f "$base" ] || base="${td%/.agents/team}/.claude/team/roles.json"
  if [ -f "$base" ] && ! problem="$(team_roles_config_check "$base" "$TEAM_CONFIG_ROLES")"; then
    err "$team: invalid $base — ${problem//$'\n'/ }"; base=""
  fi
  ov="$td/roles.override.json"
  if [ -f "$ov" ] && ! team_roles_override_check "$ov" >/dev/null; then
    err "$team: invalid $ov"; ov=""
  fi
  : > "$W/roles"
  for role in $(team_mode_roles "$mode"); do
    team_role "$td" "$team" "$run" "$role" "$cur" "$runner" "$ov" "$base" >> "$W/roles" \
      || err "$team/$role: failed"
  done
  team_events "$td" "$team" "$run" || err "$team: events failed"
  pr="$(jq -rs 'sort_by(.written_at) | map(.pr_id | select(. != null)) | last // empty' "$W/recs")" \
    || pr=""
  # Only a finished team asks ADO; `stale` is a leftover lock that still blocks team-next. Finished
  # = the mode's last role is done, not the last line: a failed team_role writes no line.
  last="$(team_mode_roles "$mode" | awk '{print $NF}')"
  fin="$(jq -rs --arg r "$last" 'map(select(.role == $r)) | last | .status == "done"' "$W/roles")" \
    || fin=false
  if [ "$runner" = down ] && [[ "$pr" =~ ^[0-9]+$ ]] && [ "$fin" = true ]; then
    prs="$(pr_state "${td%/.agents/team}" "$team" "$pr")"
  fi
  jq -c --arg run "$run" --arg runner "$runner" --arg mode "$mode" --arg prs "$prs" \
    --arg pr "$pr" --slurpfile roles "$W/roles" --argjson fin "$fin" --slurpfile esc "$W/esc" \
    --slurpfile escs "$W/escs" '
    {team, ticket, branch, line, mode: $mode, run: (if $run == "" then null else $run end), runner: $runner,
     finished: $fin,
     pr_id: (if $pr == "" then null else ($pr | tonumber? // $pr) end),
     pr_status: (if $prs == "" then null else $prs end),
     state: ({completed: "free", abandoned: "free", active: "awaiting_merge",
              unknown: "pr_unknown"}[$prs]),
     roles: $roles, esc_unsent: $esc, escalations: $escs,
     resume_hint: (if $runner != "up" and any($roles[]; .status == "blocked" or .status == "failed")
                   then "/start-team \(.team)" else null end)}' "$td/team.json"
}

snap_teams() {
  local td
  : > "$W/teams"
  while IFS= read -r td; do
    snap_team "$td" >> "$W/teams" || err "team $td: failed"
  done < <(team_clone_dirs "$root")
  jq -s . "$W/teams"
}

# The "waiting for you" bar: open questions, blocked/failed records, PRs ready to merge.
snap_attention() {
  jq --arg prov "${TEAM_DASH_PR_PROVIDER:-azure-devops}" '
  [ .[] as $t
    | ($t.roles[]? | select(.status == "attention" or .status == "blocked" or .status == "failed")
       | {kind: .status, team: $t.team, role, tmux: "\($t.team)-\(.role)",
          text: (if .status == "attention" then "waiting for an answer" else (.record.message // "") end),
          commands: (["bash .claude/lib/team-attach.sh \($t.team) \(.role)"]
            + (if .status != "attention" and $t.resume_hint then [$t.resume_hint] else [] end))}),
      (select($t.state == "awaiting_merge")
       | {kind: "merge", team: $t.team, pr_id: $t.pr_id, text: "PR \($t.pr_id) gotowy do merge",
          commands: (if $prov == "github"
            then ["bash .claude/lib/team-merge-check.sh \($t.team)", "bash .claude/lib/team-integrate.sh \($t.team)"]
            else ["bash .claude/lib/team-merge-check.sh \($t.team)", "/pr-merge \($t.pr_id)"] end)}) ]
  ' "$W/teams.json"
}
