#!/usr/bin/env bash
# Point an existing team clone at its next ticket: archive the finished run, cut a fresh branch.
#
# Usage: bash .claude/lib/team-next.sh [--abandoned] <team> <key> <new-branch> <base-ref> [mode] [--ticket-file <f>]
#   mode: brainstorm (default) | quick | cli — fixed for the ticket
#   --abandoned: move on although the previous PR is abandoned; its local branch is kept
#   e.g. bash .claude/lib/team-next.sh alfa AB-778 chore/AB-778-rollout origin/<trunk>
#
# Refuses while the previous ticket is in flight (runner, session, dirty tree, open PR or unpushed work).
# Next: bash .claude/lib/team-run.sh <team>   (from this checkout). Runbook: .agents/reference/team-pipeline.md
set -euo pipefail

# Bash 3.2: no `getopt --long`; pull --ticket-file and --abandoned out of the positionals by hand.
tfile=""; abandoned=""; args=()
while [ $# -gt 0 ]; do
  case "$1" in
    # A missing value must exit, not `shift 2 || true`: a failed shift leaves $1 in place and
    # the loop spins forever.
    --ticket-file)
      [ $# -ge 2 ] || { echo "error: --ticket-file needs a path" >&2; exit 2; }
      tfile="$2"; shift 2 ;;
    --abandoned) abandoned=1; shift ;;
    *) args+=("$1"); shift ;;
  esac
done
if [ ${#args[@]} -ne 4 ] && [ ${#args[@]} -ne 5 ]; then
  sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'
  exit 2
fi

team="${args[0]}"; key="${args[1]}"; branch="${args[2]}"; base="${args[3]}"
mode="${args[4]:-brainstorm}"

. "$(dirname "$0")/team-lib.sh"
. "$(dirname "$0")/team-modes.sh"
. "$(dirname "$0")/team-anchor.sh"

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

# The previous ticket must be closed: its PR completed (abandoned with --abandoned), or no work.
# An unmatched glob reaches jq literally and its error hides every later record; with
# no records at all jq would read stdin.
shopt -s nullglob
recs=("$TD"/runs/*/coder-*.json "$TD"/runs/*/cli-*.json)
shopt -u nullglob
pr=""
[ ${#recs[@]} -eq 0 ] || pr="$(jq -r '.pr_id // empty' "${recs[@]}" 2>/dev/null | tail -n 1)" || true
keep_old=""
if [ -n "$pr" ]; then
  # One normalised document per provider: ADO's PR JSON, or team-pr.sh's state (source_sha).
  case "$TEAM_PR_PROVIDER" in
    github)
      pr_doc="$(cd "$dir" && bash "$root/.claude/lib/team-pr.sh" state "$pr")" \
        || pr_doc='{"status":"unknown"}' ;;
    *)
      pr_doc="$(cd "$dir" && team_ado_coords && team_pr_json "$pr")" || pr_doc='{"status":"unknown"}' ;;
  esac
  status="$(jq -r '.status // "unknown"' <<<"$pr_doc")" || status="unknown"
  case "$status" in
    completed)
      src="$(jq -r '.lastMergeSourceCommit.commitId // .source_sha // ""' <<<"$pr_doc")"
      tip="$(git -C "$dir" rev-parse --verify --quiet "refs/heads/$old_branch")" || tip="none"
      [ "$tip" = "$src" ] || TEAM_PROBLEMS+=("$old_branch tip $tip is not PR #$pr's merged source\
 ${src:-none} — commits after the PR would be lost") ;;
    abandoned)
      if [ -n "$abandoned" ]; then keep_old=1
      else TEAM_PROBLEMS+=("previous PR #$pr of $old_ticket is abandoned — not merged; rerun with\
 --abandoned to move on keeping $old_branch"); fi ;;
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

team_seed_checks "$root" "$base"

# Everything that can fail runs before the archive, so a failure leaves the old ticket intact.
if ! git -C "$dir" fetch --quiet origin; then
  TEAM_PROBLEMS+=("git fetch origin failed in $dir")
elif ! git -C "$dir" rev-parse --verify --quiet "$base^{commit}" >/dev/null; then
  TEAM_PROBLEMS+=("base-ref $base does not resolve in $dir")
fi
! git -C "$dir" rev-parse --verify --quiet "refs/heads/$branch" >/dev/null \
  || TEAM_PROBLEMS+=("branch $branch already exists in $dir")

if [ ${#TEAM_PROBLEMS[@]} -gt 0 ]; then
  for p in "${TEAM_PROBLEMS[@]}"; do echo "error: $p" >&2; done
  exit 1
fi

# Last chance to read the run in place; a run that never reached ready becomes final here.
bash "$root/.claude/lib/team-audit.sh" "$team" --final archived \
  || echo "warn: team audit failed — archiving anyway" >&2

# The state files are git-ignored, so switching first leaves them in place for the archive.
git -C "$dir" switch --quiet --no-track -c "$branch" "$base"
archive="$TD/archive/$old_ticket-$(date -u +%Y%m%d-%H%M%S)"
mkdir -p "$archive"
for f in runs run acked cancel team.json merge-check-build.log roles.override.json \
  ticket.json ticket.md; do
  [ ! -e "$TD/$f" ] || mv "$TD/$f" "$archive/"
done

# Squash merges are never ancestors, so -D; the guard above proved the tip is the merged source.
[ -n "$keep_old" ] || git -C "$dir" branch --quiet -D "$old_branch"
team_seed_files "$root" "$dir"
team_write_json "$dir" "$team" "$key" "$branch" "$base" "$mode" "$root"
[ -z "$tfile" ] || team_copy_ticket "$tfile" "$dir"
team_anchor_init "$root" "$team" "$dir" || echo "warn: anchor not written" >&2

echo "clone:    $dir (was $old_ticket, archived to ${archive#"$dir"/})"
echo "branch:   $branch (from $base)"
[ -z "$keep_old" ] || echo "kept:     $old_branch (PR #$pr abandoned)"
echo "base sha: $(git -C "$dir" rev-parse HEAD)"
echo "mode:     $mode"
echo "next:     bash .claude/lib/team-run.sh $team   (from this checkout)"
