#!/usr/bin/env bash
# Tracker-shaped prompt rendering: the `{{TRACKER_*}}` placeholders of .claude/team/prompts/*.md.
# Sourced, never executed; the caller sets `set -euo pipefail`.
# Bash 3.2 compatible (macOS /bin/bash): no mapfile, no associative arrays.
#
# NOT in team-lib.sh on purpose: the runner sources team-lib.sh from the CLONE (team-run.sh:31),
# and a clone cut from an older base does not carry this function (team-mode.md: the clone keeps
# its own harness until team-next). This helper is loaded from the main checkout's `$root`, like
# team-roles.sh and team-validate.sh.

# Usage: team_tracker_render <tracker> <tracker-dir> <text> → the rendered text on stdout.
# An empty <tracker> is `jira` (a team.json written before the tracker field existed). A block file
# is read only when its placeholder actually occurs — a clone on an older base has no tracker dir.
# A present placeholder with no block file is a hard failure (return 1).
team_tracker_render() {
  local tracker="${1:-}" dir="$2" text="$3" task f
  [ -n "$tracker" ] || tracker=jira
  # Bash 5.2 expands `&` in a ${v//p/r} replacement; the blocks must land verbatim.
  shopt -u patsub_replacement 2>/dev/null || true
  case "$tracker" in
    jira) task="{{TICKET}}" ;;
    *)    task=".agents/team/ticket.md" ;;
  esac
  text="${text//'{{TRACKER_TASK}}'/$task}"
  case "$text" in
    *'{{TRACKER_READ}}'*)
      f="$dir/$tracker-read.md"
      [ -r "$f" ] || { echo "error: no tracker block $f" >&2; return 1; }
      text="${text//'{{TRACKER_READ}}'/$(cat "$f")}" ;;
  esac
  case "$text" in
    *'{{TRACKER_WRAPUP}}'*)
      f="$dir/$tracker-wrapup.md"
      [ -r "$f" ] || { echo "error: no tracker block $f" >&2; return 1; }
      text="${text//'{{TRACKER_WRAPUP}}'/$(cat "$f")}" ;;
  esac
  printf '%s' "$text"
}
