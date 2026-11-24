#!/usr/bin/env bash
# The runner's run modes: the TeamLead's mode choice (team.json mode `lead`), the cli handover (a
# chosen cli resumes the choosing lead's own conversation as the worker), the status line, and the
# post-run summary sources (a quick run has no wrapup).
# Sourced by team-run.sh from the MAIN checkout, never executed; uses the runner's globals (TEAM, RUN,
# MODE, TD, CLONE, root, BRANCH, POLL) and helpers (die, rec, sess_name, cancel_exit, team_json,
# accepted_record, run_ref, team_lead_on, team_lead_json, team_tmux_alive, team_cancelled,
# dialog_watch_lead, lead_poll, team_mode_roles, team_cli_prompt_ok, team_quick_qa_ok). Bash 3.2.
# Contract: .agents/reference/team-mode.md, team-lead.md → Mode choice

UUID_RE='^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'

mode_choice() { jq -r --arg k "$1" '.mode_choice[$k] // empty' "$TD/team.json"; }

# mode_verdict → the run's first mode verdict (team-verdict.sh writes one at most). Names only:
# the full paths hold hyphens, so sort -t- on them would split the wrong field.
mode_verdict() {
  local f
  f="$(ls "$TD/runs/$RUN" 2>/dev/null | grep -E '^teamlead-mode-[0-9]+\.json$' | sort -t- -k3,3n | head -n 1 || true)"
  [ -z "$f" ] || echo "$TD/runs/$RUN/$f"
}

# mode_apply <verdict file> — the chosen mode into team.json, before any stage. The resume identity
# is the verdict's session id, never a later teamlead.json (a relaunched lead overwrites it).
mode_apply() {
  local v="$1" m reason sid cc lacks="" tmp
  m="$(rec "$v" verdict)"; reason="$(rec "$v" message)"; sid="$(rec "$v" session_id)"
  case "$m" in brainstorm|quick|cli) ;; *) die 4 "error: mode verdict $(basename "$v") names '$m', not brainstorm|quick|cli" ;; esac
  # Unreachable after the team-new/next preflight for `lead`; kept for a clone provisioned by hand.
  case "$m" in
    quick) [ -f "$CLONE/.claude/team/prompts/planner-quick.md" ] || lacks="planner-quick.md"
           [ -n "$lacks" ] || team_quick_qa_ok "$CLONE" || lacks="qa.md" ;;
    cli) team_cli_prompt_ok "$CLONE" || lacks="cli.md"
         [ -n "$lacks" ] || [[ "$sid" =~ $UUID_RE ]] || lacks="a resumable TeamLead session id in $(basename "$v")" ;;
  esac
  [ -z "$lacks" ] || die 4 "clone base lacks the $m contract ($lacks) — no stage has run yet: the Operator restarts the ticket on a fresh clone (team-new.sh) from a current line"
  cc="$(team_lead_json claude_config_dir)"
  tmp="$TD/.team.json.tmp"
  jq --arg m "$m" --arg reason "$reason" --arg verdict ".agents/team/runs/$RUN/$(basename "$v")" \
    --arg at "$(team_utc)" --arg sid "$sid" --arg cc "$cc" \
    '.mode = $m | .mode_choice = {by: "teamlead", reason: $reason, verdict: $verdict, at: $at,
      session_id: $sid, claude_config_dir: $cc}' "$TD/team.json" > "$tmp"
  mv "$tmp" "$TD/team.json"
  MODE="$m"
  echo "mode: $m — TeamLead: $reason"
}

# mode_wait — mode `lead`: no stage runs until the lead's mode verdict; the lead is watched as in a
# stage's wait (a dead lead is reported once and relaunched on relaunch-lead, the wait goes on).
mode_wait() {
  local v
  team_lead_on || die 4 "mode lead needs the per-run TeamLead"
  echo "waiting for TeamLead: mode choice"
  while :; do
    team_cancelled && cancel_exit
    v="$(mode_verdict)"
    if [ -n "$v" ]; then mode_apply "$v"; return 0; fi
    dialog_watch_lead
    lead_poll
    sleep "$POLL"
  done
}

# cli_handover — a lead-chosen cli: the judge's session ends before its conversation is resumed as
# the worker (one process per transcript). Idempotent: a resume after the handover finds no lead.
cli_handover() {
  [ "$MODE" = cli ] && [ "$(mode_choice by)" = teamlead ] || return 0
  [ ! -f "$TD/session.json" ] && [ -z "$(accepted_record cli)" ] || return 0
  team_tmux_alive "$(sess_name lead)" || return 0
  (cd "$root" && bash .claude/lib/team-lead.sh end "$TEAM") >/dev/null \
    || die 1 "error: TeamLead judge of $TEAM did not end — rerun /start-team $TEAM"
  echo "TeamLead judge ended: the cli worker resumes its conversation"
}

# cli_session_args <role> <fresh sid> <config dir> → "<sid> <start flag>". A lead-chosen cli resumes
# the choosing lead's session on the same Claude config dir; every other launch starts fresh.
cli_session_args() {
  local sid want
  if [ "$1" != cli ] || [ "$(mode_choice by)" != teamlead ]; then
    [ "$1" != cli ] || team_cli_prompt_ok "$CLONE" \
      || echo "warn: clone base has the pre-#296 cli prompt — this run keeps the old cli contract (no /codex-review)" >&2
    echo "$2 --session-id"; return 0
  fi
  sid="$(mode_choice session_id)"
  [[ "$sid" =~ $UUID_RE ]] || die 4 "error: team.json mode_choice.session_id is no session id — the Operator restarts the ticket on a fresh clone (team-new.sh)"
  want="$(mode_choice claude_config_dir)"
  [ "$want" = "$3" ] || die 4 "the cli worker would run on another Claude config dir than the choosing TeamLead — set .claude/claude-profile to ${want:-nothing (the default config dir)}, then /start-team $TEAM"
  echo "$sid --resume"
}

mode_status() {
  if [ "$MODE" = lead ]; then echo "mode: lead (TeamLead choosing)"
  elif [ "$(mode_choice by)" = teamlead ]; then echo "mode: $MODE (TeamLead: $(mode_choice reason | head -n 1))"
  else echo "mode: $MODE (Operator)"; fi
}

# Read-only sources for the post-run summary: clone files are outside the supervisor's dirs.
cmd_summary() {
  local r f trk tf title="" url="" last
  RUN="$(cat "$TD/run" 2>/dev/null || true)"
  trk="$(team_json tracker)"; [ -n "$trk" ] || trk=jira
  # A supervision session never reads clone files, so the ticket title and link travel through here. `jira` has no
  # ticket.json — it keeps reading them over MCP, and both values stay empty.
  tf="$TD/ticket.json"
  if [ -f "$tf" ]; then
    title="$(jq -r '.title // ""' "$tf" 2>/dev/null || true)"
    url="$(jq -r '.url // ""' "$tf" 2>/dev/null || true)"
  fi
  echo "ticket: $(team_json ticket)"; echo "tracker: $trk"
  echo "title: $title"; echo "url: $url"
  echo "mode: $MODE"; echo "branch: $BRANCH"
  echo "run: ${RUN:-none}"
  r="$(accepted_record "$([ "$MODE" = cli ] && echo cli || echo coder)")"
  echo "pr: $([ -z "$r" ] || rec "$r" pr_id)"
  [ "$MODE" != lead ] || return 0
  if [ "$MODE" = cli ]; then
    summary_file cli "$(accepted_summary_file cli cli)"
    return 0
  fi
  f="$(accepted_summary_file qa qa-report)"
  echo "--- qa"
  if [ -f "$f" ]; then grep -E '^(Verdict|Warnings|Rethink signals):' "$f" || true
  else echo "missing: qa-report-<n>.md"; fi
  last="$(team_mode_roles "$MODE" "$CLONE")"; last="${last##* }"
  [ "$last" != wrapup ] || summary_file wrapup "$(accepted_summary_file wrapup wrapup)"
}

accepted_summary_file() {  # <role> <filename stem>
  local r
  r="$(accepted_record "$1")"
  [ -z "$r" ] || echo "$TD/runs/$(run_ref)/$2-$(rec "$r" attempt).md"
}

summary_file() {  # summary_file <label> <file> — the body without the machine target_rev line
  echo "--- $1"
  if [ -f "$2" ]; then grep -v '^target_rev: ' "$2" || true; else echo "missing: $1-<n>.md"; fi
}
