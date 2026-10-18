#!/usr/bin/env bash
# PR-provider-shaped prompt rendering: the `{{PR_*}}` and `{{GATES_NOTE}}` placeholders of
# .claude/team/prompts/*.md and of the `.claude/team/tracker/*-wrapup.md` blocks.
# Sourced, never executed; the caller sets `set -euo pipefail`.
# Bash 3.2 compatible (macOS /bin/bash): no mapfile, no associative arrays.
#
# Loaded from the main checkout's `$root`, like team-tracker-render.sh: the runner sources
# team-lib.sh from the CLONE, and a clone cut from an older base does not carry this helper.
#
# The `azure-devops-*` blocks are the byte-for-byte text the prompts carried before the PR layer
# existed, so an ADO render stays identical ($S/i5/render-diff.sh proves it per step).

# Usage: team_pr_render <provider> <pr-dir> <host-kind> <host> <gates> <text> → text on stdout.
# A block file is read only when its placeholder actually occurs — a clone on an older base has no
# PR dir. A present placeholder with no block file is a hard failure (return 1).
team_pr_render() {
  local provider="${1:-}" dir="$2" kind="$3" host="$4" gates="${5:-}" text="$6" key kebab f note
  [ -n "$provider" ] || provider=azure-devops
  # Bash 5.2 expands `&` in a ${v//p/r} replacement; the blocks must land verbatim.
  shopt -u patsub_replacement 2>/dev/null || true
  text="${text//'{{PR_HOST_KIND}}'/$kind}"
  text="${text//'{{PR_HOST}}'/$host}"
  note=""
  if [ "$gates" = manual-mql5 ]; then
    note=" — gates=manual-mql5: the MT5 compile and backtest are done by the Operator, not run by"
    note="$note the team."
  fi
  text="${text//'{{GATES_NOTE}}'/$note}"
  for key in CREATE CREATE_READY BODY_GET BODY_SET PUBLISH TOOL; do
    case "$text" in
      *"{{PR_$key}}"*) ;;
      *) continue ;;
    esac
    kebab="$(printf '%s' "$key" | tr 'A-Z_' 'a-z-')"
    f="$dir/$provider-$kebab.md"
    [ -r "$f" ] || { echo "error: no PR block $f" >&2; return 1; }
    text="${text//"{{PR_$key}}"/$(cat "$f")}"
  done
  printf '%s' "$text"
}
