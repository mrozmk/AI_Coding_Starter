#!/usr/bin/env bash
# Run modes of a team ticket: which stages run, which planner prompt, the contract markers.
# Sourced, never executed; the caller sets `set -euo pipefail`. Contract: .agents/reference/team-mode.md
# Bash 3.2 compatible (macOS /bin/bash): no mapfile, no associative arrays.
# Loaded from the main checkout (like roles.json), so a clone on an older base still works.

# The `--mode` input set. team.json may also hold `lead`: the TeamLead chooses (never a `--mode`
# value); the runner replaces it with the chosen mode before any stage (team-run-mode.sh).
TEAM_MODES="brainstorm quick cli"
# The cli path runs on the TeamLead's model/effort (team-roles.sh); only its permission is set here.
TEAM_CLI_PERMISSION=auto
# Contract markers of the current prompts: a clone base without them has the older contract.
TEAM_QUICK_QA_MARKER='In mode `quick` no wrapup follows you'
TEAM_CLI_PROMPT_MARKER='/codex-review'

team_mode_valid() {  # an input value of --mode
  case "$1" in brainstorm|quick|cli) return 0 ;; *) return 1 ;; esac
}

team_mode_state_valid() {  # a team.json value
  case "$1" in lead|brainstorm|quick|cli) return 0 ;; *) return 1 ;; esac
}

team_mode() {  # team_mode <team.json> → mode; a team.json written before modes has none
  local m
  m="$(jq -r '.mode // "brainstorm"' "$1")" || return 1
  team_mode_state_valid "$m" || { echo "error: unknown mode '$m' in $1" >&2; return 1; }
  echo "$m"
}

team_cli_prompt_ok() {  # team_cli_prompt_ok <checkout dir> — its cli.md is the TeamLead's cli path
  grep -qF -- "$TEAM_CLI_PROMPT_MARKER" "$1/.claude/team/prompts/cli.md" 2>/dev/null
}

team_quick_qa_ok() {  # team_quick_qa_ok <checkout dir> — its qa.md ends a quick run (no wrapup)
  grep -qF -- "$TEAM_QUICK_QA_MARKER" "$1/.claude/team/prompts/qa.md" 2>/dev/null
}

team_mode_roles() {  # team_mode_roles <mode> [clone dir] → the stage roles in run order
  case "$1" in
    cli) echo cli ;;
    lead) echo "" ;;
    # A quick run provisioned before quick lost its wrapup keeps it: its clone's qa.md says so.
    quick) if [ -n "${2:-}" ] && ! team_quick_qa_ok "$2"; then echo "planner coder qa wrapup"
           else echo "planner coder qa"; fi ;;
    *) echo "planner coder qa wrapup" ;;
  esac
}

team_mode_last_role() {  # team_mode_last_role <mode> [clone dir] → the run's final role (none in lead)
  local r
  r="$(team_mode_roles "$@")"
  echo "${r##* }"
}

# team_mode_verdict <team dir> <run> → the run's mode verdict file (team-verdict.sh writes one at
# most); nothing while the TeamLead has not chosen.
team_mode_verdict() {
  local f
  f="$(ls "$1/runs/$2" 2>/dev/null | grep -E '^teamlead-mode-[0-9]+\.json$' | head -n 1 || true)"
  [ -z "$f" ] || echo "$1/runs/$2/$f"
}

team_prompt_name() {  # team_prompt_name <mode> <role> → file under .claude/team/prompts/
  if [ "$1/$2" = quick/planner ]; then echo planner-quick.md; else echo "$2.md"; fi
}

# Preflight for team-new/team-next; appends to TEAM_PROBLEMS (team-lib.sh pattern), never exits.
# Runs before any clone or branch exists, so its recovery is another <base-ref> argument.
team_mode_checks() {  # team_mode_checks <root> <base-ref> <mode>
  local need="" f mk
  case "$3" in
    lead) need="planner-quick qa cli" ;;  # a lead run may become any mode
    quick) need="planner-quick qa" ;;
    cli) need="cli" ;;
    brainstorm) return 0 ;;
    *) TEAM_PROBLEMS+=("mode '$3' must be one of: $TEAM_MODES (or none — the TeamLead chooses)"); return 0 ;;
  esac
  for f in $need; do
    case "$f" in qa) mk="$TEAM_QUICK_QA_MARKER" ;; cli) mk="$TEAM_CLI_PROMPT_MARKER" ;; *) mk="" ;; esac
    team_mode_base_has "$1" "$2" "$f.md" "$mk" \
      || TEAM_PROBLEMS+=("base $2 has no $f.md contract for mode $3 — pick a current base ref")
  done
  return 0
}

# A captured read, not `git show | grep -q`: grep's early exit would fail the pipe under pipefail.
# An empty marker checks only that the file exists on the base.
team_mode_base_has() {  # team_mode_base_has <root> <base-ref> <prompt file> <marker>
  local t
  t="$(git -C "$1" show "$2:.claude/team/prompts/$3" 2>/dev/null)" || return 1
  case "$t" in *"$4"*) return 0 ;; *) return 1 ;; esac
}
