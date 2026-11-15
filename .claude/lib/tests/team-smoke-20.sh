#!/usr/bin/env bash
# per-run TeamLead identity and permission profile: team_lead_caller, the hooks that must not
# take the lead for a stage, the write guard, the materialised profile, the teams.teamlead keys.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/team-smoke-lib.sh"
smoke_init

smoke_team AB-1301 feature/AB-1301-x
L="$SRC/.claude/lib"; H="$SRC/.claude/hooks"
RUN_ID=alfa-20261114-000000; echo "$RUN_ID" > "$TD/run"; RD="$TD/runs/$RUN_ID"; mkdir -p "$RD"
CREAL="$(cd "$CLONE" && pwd -P)"
lead_json() {  # lead_json <run> <session id>
  jq -n --arg r "$1" --arg s "$2" '{run: $r, session_id: $s}' > "$TD/teamlead.json"
}
caller() {  # caller <sid|""> → RC of team_lead_caller in the clone, as the lead
  set +e; (cd "$CLONE" && . "$L/team-lib.sh" && . "$L/team-lead-lib.sh" && TEAM_SESSION_ROLE=TeamLead team_lead_caller "$1") \
    > "$WORK/out" 2>&1; RC=$?; set -e
}
# Here-strings, not pipes: a hook that exits before reading stdin would give printf EPIPE.
lhook() {  # lhook <hook> <json> — the hook as the lead (role env set), cwd outside the clone
  set +e; CLAUDE_PROJECT_DIR="$CLONE" TEAM_SESSION_ROLE=TeamLead bash "$H/$1" <<<"$2" \
    > "$WORK/out" 2>&1; RC=$?; set -e
}
shook() {  # shook <hook> <json> — the same hook as a stage session
  set +e; CLAUDE_PROJECT_DIR="$CLONE" bash "$H/$1" <<<"$2" > "$WORK/out" 2>&1; RC=$?; set -e
}
write_p() {  # write_p <tool> <path> [sid]
  jq -cn --arg t "$1" --arg p "$2" --arg s "${3-sid-lead}" \
    '{session_id: $s, tool_name: $t, tool_input: {file_path: $p, content: "x"}}'
}

# ---- (a) team_lead_caller ---------------------------------------------------------------------
caller sid-lead; [ "$RC" = 1 ] || fail "(a) caller true without teamlead.json"
lead_json "$RUN_ID" sid-lead
caller sid-lead; [ "$RC" = 0 ] || fail "(a) caller false with a matching sid"
caller ""; [ "$RC" = 0 ] || fail "(a) caller false without a hook sid"
caller sid-other; [ "$RC" = 1 ] || fail "(a) caller true with another sid"
lead_json alfa-old sid-lead; caller sid-lead; [ "$RC" = 1 ] || fail "(a) caller true for another run"
lead_json "$RUN_ID" sid-lead
set +e; (cd "$CLONE" && . "$L/team-lib.sh" && . "$L/team-lead-lib.sh" && TEAM_SESSION_ROLE=coder team_lead_caller sid-lead); RC=$?
set -e; [ "$RC" = 1 ] || fail "(a) caller true without the role env"
echo "team-smoke-20: (a) team_lead_caller OK"

# ---- (b) team-attention.sh --------------------------------------------------------------------
session coder 1 "$BASE"
N='{"session_id": "sid-lead", "notification_type": "permission_prompt", "message": "approve x"}'
lhook team-attention.sh "$N"; expect 0 "" "(b) attention as the lead"
[ ! -s "$RD/attention" ] || fail "(b) a lead notification reached the stage attention file"
shook team-attention.sh "$(jq -c '.session_id = "sid-coder-1"' <<<"$N")"; expect 0 "" "(b) stage"
[ "$(wc -l < "$RD/attention" | tr -d ' ')" = 1 ] || fail "(b) a stage notification wrote no line"
echo "team-smoke-20: (b) attention OK"

# ---- (c) guard-team-memory.sh during the wrapup stage ------------------------------------------
session wrapup 1 "$BASE"
M="$(write_p Write "$CLONE/.agents/memory/decisions.md")"
lhook guard-team-memory.sh "$M"; expect 2 "TeamLead decides memory proposals" "(c) lead refused"
lhook guard-team-memory.sh "$(write_p Write "$CLONE/.agents/memory/decisions.md" sid-stale)"
expect 2 "identity not current" "(c) stale lead refused"
lhook guard-team-memory.sh "$(write_p Write "$CLONE/.agents/memory/decisions.md" "")"
expect 2 "identity not current" "(c) lead without a session_id refused"
shook guard-team-memory.sh "$M"; expect 0 "" "(c) wrapup still writes memory"
session coder 1 "$BASE"
shook guard-team-memory.sh "$M"; expect 2 "wrapup role only" "(c) coder still refused"
echo "team-smoke-20: (c) memory guard OK"

# ---- (d) team-record.sh refuses the lead; guard-team-question.sh skips it ----------------------
set +e; (cd "$CLONE" && TEAM_SESSION_ROLE=TeamLead $REC --verdict done) > "$WORK/out" 2>&1; RC=$?
set -e; expect 1 "team-verdict.sh" "(d) record as the lead"
ls "$RD"/coder-*.json >/dev/null 2>&1 && fail "(d) the lead wrote a stage record"
Q2='{"session_id": "sid-lead", "tool_input": {"questions": [{"q": 1}, {"q": 2}]}}'
lhook guard-team-question.sh "$Q2"; expect 0 "" "(d) question guard skips the lead"
shook guard-team-question.sh "$(jq -c '.session_id = "x"' <<<"$Q2")"
expect 2 "one question" "(d) question guard still holds stages"
echo "team-smoke-20: (d) record + question OK"

# ---- (e) guard-teamlead-write.sh ---------------------------------------------------------------
G=guard-teamlead-write.sh
lhook $G "$(write_p Write "$CLONE/.agents/team/runs/$RUN_ID/x.md")"; expect 0 "" "(e) run dir"
lhook $G "$(write_p Edit ".agents/team/runs/$RUN_ID/y.md")"; expect 0 "" "(e) relative run path"
lhook $G "$(write_p Write "/private/tmp/claude-$(id -u)/s/notes.md")"; expect 0 "" "(e) scratchpad"
lhook $G "$(write_p Write "$CLONE/src/x.ts")"; expect 2 "writes only under" "(e) src refused"
lhook $G "$(write_p Write "$CLONE/.agents/team/runs/$RUN_ID/../escape")"
expect 2 "writes only under" "(e) .. escape refused"
lhook $G "$(write_p Write "$CREAL/.agents/team/runs/alfa-old/x.md")"
expect 2 "writes only under" "(e) another run refused"
lhook $G "$(jq -cn '{session_id: "sid-lead", tool_name: "NotebookEdit",
  tool_input: {notebook_path: "README.ipynb"}}')"; expect 2 "writes only under" "(e) notebook refused"
lhook $G "$(write_p Write "$CLONE/.agents/team/runs/$RUN_ID/x.md" sid-stale)"
expect 2 "identity not current" "(e) stale identity fails closed"
lhook $G "$(write_p Write "$CLONE/.agents/team/runs/$RUN_ID/x.md" "")"
expect 2 "identity not current" "(e) empty session_id fails closed"
lhook $G "$(jq -cn --arg p "$CLONE/.agents/team/runs/$RUN_ID/x.md" \
  '{tool_name: "Write", tool_input: {file_path: $p}}')"
expect 2 "identity not current" "(e) missing session_id fails closed"
lhook $G "$(jq -cn '{session_id: "sid-lead", tool_name: "Read", tool_input: {file_path: "/etc/hosts"}}')"
expect 0 "" "(e) other tools pass"
shook $G "$(write_p Write "$CLONE/src/x.ts" sid-coder-1)"; expect 0 "" "(e) stage passes"
set +e; CLAUDE_PROJECT_DIR="$MAIN" TEAM_SESSION_ROLE=TeamLead bash "$H/$G" \
  <<<"$(write_p Write "$MAIN/src/x.ts")" > "$WORK/out" 2>&1; RC=$?; set -e
expect 0 "" "(e) the global TeamLead in the main checkout is not confined"
echo "team-smoke-20: (e) write guard OK"

# ---- (f) the global-role hooks stay silent in a clone ------------------------------------------
for f in monitoring-rearm.sh; do   # session-role.sh is gone (session-registry.sh: part roles)
  lhook $f '{"session_id": "sid-lead"}'; expect 0 "" "(f) $f"
  [ ! -s "$WORK/out" ] || fail "(f) $f printed in the clone"
done
echo "team-smoke-20: (f) global-role hooks OK"

# ---- (g) materialize ---------------------------------------------------------------------------
mkdir -p "$MAIN/.claude/team/sessions"
cp "$SRC/.claude/team/sessions/TeamLead-run.settings.json" "$MAIN/.claude/team/sessions/"
jq '.permissions.deny = ["Bash(git rebase*)"] | .permissions.ask = ["Bash(git tag*)"]' \
  "$MAIN/.claude/settings.json" > "$WORK/s" && cp "$WORK/s" "$MAIN/.claude/settings.json"
run "$MAIN" bash .claude/lib/team-lead.sh materialize alfa
expect 0 "profile TeamLead-run:" "(g) materialize"
P="$TD/teamlead.settings.json"
[ "$(ls -l "$P" | cut -c1-10)" = "-rw-------" ] || fail "(g) profile is not mode 600"
jq -e '(.permissions.deny | index("Bash(az repos pr update*)")) and
  (.permissions.deny | index("Bash(git push*)")) and (.permissions.ask | index("Bash(git tag*)"))
  and .env.TEAM_SESSION_ROLE == "TeamLead"
  and (.hooks.PreToolUse[0].hooks[0].command | contains("guard-teamlead-write.sh"))' "$P" \
  >/dev/null || fail "(g) materialised profile content"
run "$MAIN" python3 -I "$L/session_profile_check.py" "$MAIN" --profiles "$MAIN/.claude/team/sessions" \
  --clone "$CLONE" TeamLead-run
expect 0 "TeamLead-run OK" "(g) profile check of the materialised file"
run "$CLONE" bash .claude/lib/team-lead.sh materialize alfa; expect 1 "main checkout" "(g) from a clone"
echo "team-smoke-20: (g) materialize OK"

# ---- (h) teams.teamlead profile keys -----------------------------------------------------------
load() {  # load <jq edit> → RC + $WORK/out of the profile load in a scratch root
  mkdir -p "$WORK/p/.claude"; smoke_profile "$1" > "$WORK/p/.claude/project-profile.json"
  set +e; (. "$L/team-profile.sh"; team_profile_load "$WORK/p"
    echo "$TEAM_LEAD_ENABLED $TEAM_LEAD_REVISE_LIMIT $TEAM_LEAD_BUDGET_BRAINSTORM" \
      "$TEAM_LEAD_BUDGET_QUICK $TEAM_LEAD_MODEL $TEAM_LEAD_EFFORT" \
      "$(printf '%s' "$TEAM_LEAD_HUMAN_ONLY" | tr '\n' ,)") > "$WORK/out" 2>&1; RC=$?; set -e
}
load .; expect 0 "false 3 2 1 fable high settings-profiles,prod-ask" "(h) defaults"
load '.teams.teamlead = {enabled: true, revise_limit: 5, rework_budget: {quick: 0}}
  | .teams.sessions.TeamLead = {model: "claude-fable-5-2"}'
expect 0 "true 5 2 0 claude-fable-5-2 high" "(h) set values"
load '.teams.teamlead.enabled = true | .teams.teamlead.revise_limit = 0'; expect 2 "teams.teamlead.revise_limit" "(h) revise_limit 0"
load '.teams.teamlead.enabled = "yes"'; expect 2 "teams.teamlead.enabled" "(h) enabled not boolean"
load '.teams.teamlead.enabled = true | .teams.teamlead.rework_budget.brainstorm = -1'
expect 2 "teams.teamlead.rework_budget.brainstorm" "(h) negative budget"
load '.teams.teamlead.enabled = true | .teams.teamlead.human_only = []'; expect 2 "teams.teamlead.human_only" "(h) empty human_only"
# With the switch off a bad TeamLead key never stops a core command: defaults, no refusal.
load '.teams.teamlead = {enabled: false, revise_limit: "garbage", rework_budget: {quick: -3}, human_only: []}'
expect 0 "false 3 2 1 fable high settings-profiles,prod-ask" "(h) switch off: bad keys load with defaults"
load '.teams.teamlead = {enabled: true, revise_limit: "garbage"}'
expect 2 "teams.teamlead.revise_limit=garbage must be a positive integer" "(h) switch on: refused as today"
load '.teams.sessions.TeamLead.effort = "huge"'; expect 2 "TeamLead.effort" "(h) bad effort"
echo "team-smoke-20: (h) profile keys OK"

echo "team-smoke-20: OK"
