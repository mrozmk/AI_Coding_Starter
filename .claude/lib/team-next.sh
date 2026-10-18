#!/usr/bin/env bash
# Point an existing team clone at its next ticket: archive the finished run, cut a fresh branch.
#
# Usage: bash .claude/lib/team-next.sh <team> <TT-key> <new-branch> <base-ref> [mode] [--ticket-file <f>]
#   mode: brainstorm (default) | quick | cli — fixed for the ticket
#   e.g. bash .claude/lib/team-next.sh alfa TT-778 chore/TT-778-rollout origin/<trunk>
#
# Refuses while the previous ticket is in flight (runner, session, dirty tree, open PR or unpushed work).
# Next: bash .claude/lib/team-run.sh <team>   (from this checkout). Runbook: .agents/reference/team-pipeline.md
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
# Before the archive move, the branch switch and the team.json rewrite below.
team_profile_load "$root"
team_profile_require_supported
dir="$(team_clone_dir "$team" "$root")"
TD="$dir/.agents/team"
[ -f "$TD/team.json" ] || { echo "error: no team clone at $dir — create it with team-new.sh" >&2; exit 1; }
old_ticket="$(jq -r .ticket "$TD/team.json")"; old_branch="$(jq -r .branch "$TD/team.json")"
if [ "$old_ticket" = "$key" ]; then
  echo "error: team $team already has ticket $key; resume with /start-team $team" >&2
  exit 1
fi
old_base="$(jq -r .base_sha "$TD/team.json")"
TEAM_PROBLEMS=()

if [ -d "$TD/lock" ]; then
  TEAM_PROBLEMS+=("runner lock present ($TD/lock) — stop the runner or remove a stale lock first")
fi
[ ! -f "$TD/session.json" ] || TEAM_PROBLEMS+=("a stage of $old_ticket is still open (session.json) — finish or stop it")
for role in $TEAM_ROLES cli runner; do
  ! team_tmux_alive "$team-$role" || TEAM_PROBLEMS+=("tmux session $team-$role is alive — end it first")
done
[ -z "$(git -C "$dir" status --porcelain)" ] || TEAM_PROBLEMS+=("clone $dir has uncommitted changes")

# The previous ticket must be closed: its PR completed/abandoned, or no work done at all.
pr="$(jq -r '.pr_id // empty' "$TD"/runs/*/coder-*.json "$TD"/runs/*/cli-*.json 2>/dev/null \
  | tail -n 1)" || true
if [ -n "$pr" ]; then
  case "$TEAM_PR_PROVIDER" in
    github)
      status="$(cd "$dir" && bash "$root/.claude/lib/team-pr.sh" state "$pr" | jq -r .status)" \
        || status="unknown" ;;
    *)
      status="$(cd "$dir" && team_ado_coords && team_pr_json "$pr" | jq -r .status)" \
        || status="unknown" ;;
  esac
  case "$status" in
    completed|abandoned) ;;
    *) TEAM_PROBLEMS+=("previous PR #$pr of $old_ticket is $status — merge or abandon it first") ;;
  esac
elif [ "$(git -C "$dir" rev-parse "refs/heads/$old_branch" 2>/dev/null)" != "$old_base" ]; then
  TEAM_PROBLEMS+=("$old_ticket has commits on $old_branch but no PR — finish it, or remove the clone and use team-new.sh")
fi

team_ticket_checks "$root" "$key" "$branch" "$base" "$team"
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

archive="$TD/archive/$old_ticket-$(date -u +%Y%m%d-%H%M%S)"
mkdir -p "$archive"
for f in runs run acked cancel team.json merge-check-build.log roles.override.json \
  ticket.json ticket.md; do
  [ ! -e "$TD/$f" ] || mv "$TD/$f" "$archive/"
done

git -C "$dir" fetch --quiet origin
git -C "$dir" switch --quiet --no-track -c "$branch" "$base"
# Squash merges are never ancestors, so -D; the guard above proved the branch is merged or empty.
git -C "$dir" branch --quiet -D "$old_branch"
team_seed_files "$root" "$dir"
team_write_json "$dir" "$team" "$key" "$branch" "$base" "$mode" "$root"
[ -z "$tfile" ] || team_copy_ticket "$tfile" "$dir"

echo "clone:    $dir (was $old_ticket, archived to ${archive#"$dir"/})"
echo "branch:   $branch (from $base)"
echo "base sha: $(git -C "$dir" rev-parse HEAD)"
echo "mode:     $mode"
echo "next:     bash .claude/lib/team-run.sh $team   (from this checkout)"
