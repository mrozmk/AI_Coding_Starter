#!/usr/bin/env bash
# Run modes of a team ticket (TT-790): which stages run, which planner prompt, the fixed cli model.
# Sourced, never executed; the caller sets `set -euo pipefail`. Contract: .agents/reference/team-mode.md
# Bash 3.2 compatible (macOS /bin/bash): no mapfile, no associative arrays.
# Loaded from the main checkout (like roles.json), so a clone on an older base still works.

TEAM_MODES="brainstorm quick cli"
# The cli role ignores roles.json and the override (TT-790 decision).
TEAM_CLI_MODEL='opus[1m]'
TEAM_CLI_EFFORT=medium

team_mode_valid() {
  case "$1" in brainstorm|quick|cli) return 0 ;; *) return 1 ;; esac
}

team_mode() {  # team_mode <team.json> → mode; a team.json written before TT-790 has none
  local m
  m="$(jq -r '.mode // "brainstorm"' "$1")" || return 1
  team_mode_valid "$m" || { echo "error: unknown mode '$m' in $1" >&2; return 1; }
  echo "$m"
}

team_mode_roles() {  # team_mode_roles <mode> → the stage roles in run order
  case "$1" in cli) echo cli ;; *) echo "planner coder qa wrapup" ;; esac
}

team_prompt_name() {  # team_prompt_name <mode> <role> → file under .claude/team/prompts/
  if [ "$1/$2" = quick/planner ]; then echo planner-quick.md; else echo "$2.md"; fi
}

# Preflight for team-new/team-next; appends to TEAM_PROBLEMS (team-lib.sh pattern), never exits.
team_mode_checks() {  # team_mode_checks <root> <base-ref> <mode>
  local p
  team_mode_valid "$3" || { TEAM_PROBLEMS+=("mode '$3' must be one of: $TEAM_MODES"); return 0; }
  case "$3" in quick) p=planner-quick.md ;; cli) p=cli.md ;; *) return 0 ;; esac
  git -C "$1" cat-file -e "$2:.claude/team/prompts/$p" 2>/dev/null \
    || TEAM_PROBLEMS+=("base $2 has no $p — mode $3 needs a TT-790 base")
}
