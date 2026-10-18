#!/usr/bin/env bash
# Provision a team clone next to this checkout, on a fresh branch cut from a harness-carrying line.
#
# Usage: bash .claude/lib/team-new.sh <team> <TT-key> <new-branch> <base-ref> [mode] [--ticket-file <f>]
#   mode: brainstorm (default) | quick | cli — fixed for the ticket
#   e.g. bash .claude/lib/team-new.sh alfa TT-790 feature/TT-790-slug origin/<trunk>
#
# Result: ../<repo>-<team>/ on <new-branch>, per-developer files copied, .agents/team/team.json.
# Next ticket in the same clone: team-next.sh. Runbook: .agents/reference/team-pipeline.md
set -euo pipefail

# Bash 3.2: no `getopt --long`; pull --ticket-file out of the positionals by hand.
tfile=""; ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    # A missing value must exit, not `shift 2 || true`: a failed shift leaves $1 in place and
    # the loop spins forever.
    --ticket-file)
      [ $# -ge 2 ] || { echo "error: --ticket-file needs a path" >&2; exit 2; }
      tfile="$2"; shift 2 ;;
    *) ARGS+=("$1"); shift ;;
  esac
done
set -- ${ARGS[@]+"${ARGS[@]}"}

if [ $# -ne 4 ] && [ $# -ne 5 ]; then
  sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'
  exit 2
fi

team="$1"; key="$2"; branch="$3"; base="$4"; mode="${5:-brainstorm}"

. "$(dirname "$0")/team-lib.sh"
. "$(dirname "$0")/team-modes.sh"

root="$(git rev-parse --show-toplevel)"
# Before anything that creates a directory, switches a branch or writes team.json.
team_profile_load "$root"
team_profile_require_supported
dir="$(team_clone_dir "$team" "$root")"
TEAM_PROBLEMS=()
team_check_name "$team" 2>/dev/null || TEAM_PROBLEMS+=("team name '$team' must match [a-z0-9-]+")
[ ! -e "$dir" ] || TEAM_PROBLEMS+=("$dir already exists — to start the next ticket there: team-next.sh")
team_ticket_checks "$root" "$key" "$branch" "$base"
team_mode_checks "$root" "$base" "$mode"

# The ticket file is how github/none hand the clone its brief; jira reads it through MCP.
# `pwd -P` of an existing dir, not realpath: macOS 3.2 has no realpath and the clone may not exist.
tdir_real="$dir/.agents/team"
[ ! -d "$dir/.agents/team" ] || tdir_real="$(cd "$dir/.agents/team" && pwd -P)"
case "$TEAM_TRACKER" in
  github|none)
    if [ -z "$tfile" ]; then
      TEAM_PROBLEMS+=("--ticket-file required for tracker=$TEAM_TRACKER")
    elif [ ! -r "$tfile" ]; then
      TEAM_PROBLEMS+=("--ticket-file '$tfile' is not readable")
    elif ! tkey="$(jq -er '.key' "$tfile" 2>/dev/null)"; then
      # `jq -r … || true` would print the key of a valid first object and swallow the parse error
      # of the garbage after it; -e with the status checked refuses the whole file.
      TEAM_PROBLEMS+=("--ticket-file '$tfile' is not readable JSON with a .key")
    elif [ "$tkey" != "$key" ]; then
      TEAM_PROBLEMS+=("--ticket-file '$tfile' is not ticket $key")
    elif [ ! -r "$(dirname "$tfile")/ticket.md" ]; then
      TEAM_PROBLEMS+=("no ticket.md next to '$tfile'")
    elif tf_real="$(cd "$(dirname "$tfile")" && pwd -P)" \
      && case "$tf_real/" in "$tdir_real/"*) true ;; *) false ;; esac; then
      # team-next archives $TD before it copies the ticket, so an input living under the clone's
      # .agents/team/ would be moved away mid-switch and leave the clone without a ticket.
      TEAM_PROBLEMS+=("--ticket-file '$tfile' is inside $tdir_real — keep it outside the team dir")
    fi ;;
  jira)
    [ -z "$tfile" ] || TEAM_PROBLEMS+=("jira reads the ticket through MCP — no --ticket-file") ;;
esac

if [ ${#TEAM_PROBLEMS[@]} -gt 0 ]; then
  for p in "${TEAM_PROBLEMS[@]}"; do echo "error: $p" >&2; done
  exit 1
fi

# Real origin URL + --reference-if-able: a local-path clone would need `git remote set-url` (denied).
git clone --quiet --reference-if-able "$root" --dissociate "$(git -C "$root" remote get-url origin)" "$dir"
git -C "$dir" switch --quiet --no-track -c "$branch" "$base"
team_seed_files "$root" "$dir"
team_write_json "$dir" "$team" "$key" "$branch" "$base" "$mode" "$root"
[ -z "$tfile" ] || team_copy_ticket "$tfile" "$dir"

echo "clone:    $dir"
echo "branch:   $branch (from $base)"
echo "base sha: $(git -C "$dir" rev-parse HEAD)"
echo "mode:     $mode"
echo "next:     bash .claude/lib/team-run.sh $team   (from this checkout)"
