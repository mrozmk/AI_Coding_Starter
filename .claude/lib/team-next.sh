#!/usr/bin/env bash
# Point an existing team clone at its next ticket: archive the finished run, cut a fresh branch.
#
# Usage: bash .claude/lib/team-next.sh [--abandoned] <team> <key> <new-branch> <base-ref> [mode] [--ticket-file <f>]
#        [--follow-up-of <key>]
#   mode: lead (default — the TeamLead chooses) | brainstorm | quick | cli (fixed by the Operator)
#   --abandoned: move on although the previous PR is abandoned; its local branch is kept
#   e.g. bash .claude/lib/team-next.sh alfa AB-778 chore/AB-778-rollout origin/<trunk>
#
# Refuses while the previous ticket is in flight (runner, session, dirty tree, open PR or unpushed work).
# Next: bash .claude/lib/team-run.sh <team>   (from this checkout). Runbook: .agents/reference/team-pipeline.md
set -euo pipefail

# Bash 3.2: no `getopt --long`; pull --ticket-file, --follow-up-of and --abandoned out of the positionals by hand.
tfile=""; fu=""; abandoned=""; args=()
while [ $# -gt 0 ]; do
  case "$1" in
    # A missing value must exit, not `shift 2 || true`: a failed shift leaves $1 in place and
    # the loop spins forever.
    --ticket-file)
      [ $# -ge 2 ] || { echo "error: --ticket-file needs a path" >&2; exit 2; }
      tfile="$2"; shift 2 ;;
    --follow-up-of)
      [ $# -ge 2 ] || { echo "error: --follow-up-of needs a ticket key" >&2; exit 2; }
      fu="$2"; shift 2 ;;
    --abandoned) abandoned=1; shift ;;
    *) args+=("$1"); shift ;;
  esac
done
if [ ${#args[@]} -ne 4 ] && [ ${#args[@]} -ne 5 ]; then
  sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'
  exit 2
fi

team="${args[0]}"; key="${args[1]}"; branch="${args[2]}"; base="${args[3]}"
mode="${args[4]:-lead}"

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
  # Waived only by the runner's receipt of a safe lead close in the main checkout's anchor (the run,
  # this branch, and a sha equal to the local and the remote tip) — a clone-local closed.json alone
  # never waives it: the clone is role-writable.
  if rcpt="$(team_close_receipt_ok "$root" "$team" "$dir" "$old_branch")"; then
    echo "closed run: $old_branch kept at $rcpt (a lead close)"
  else
    TEAM_PROBLEMS+=("$old_ticket has commits on $old_branch but no PR — finish it, or remove the clone and use team-new.sh")
  fi
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

# The follow-up cap (team-lineage.sh): checked after the refusals above, before the first side
# effect; its exit passes through (9 waits for the Operator's consent, 2 is a contradiction).
lopt=()
[ -z "$fu" ] || lopt+=(--follow-up-of "$fu")
[ -z "$tfile" ] || lopt+=(--ticket-file "$(cd "$(dirname "$tfile")" && pwd -P)/ticket.md")
lineage() { (cd "$root" && bash .claude/lib/team-lineage.sh "$@" ${lopt[@]+"${lopt[@]}"}); }
lineage check "$key" || exit $?

# Last chance to read the run in place; a run that never reached ready becomes final here.
bash "$root/.claude/lib/team-audit.sh" "$team" --final archived \
  || echo "warn: team audit failed — archiving anyway" >&2

# The previous ticket's TeamLead ends with it; a missing session is fine.
(cd "$root" && bash .claude/lib/team-lead.sh end "$team") >/dev/null 2>&1 \
  || echo "warn: TeamLead of $team did not end — check: tmux has-session -t =$team-lead" >&2

old_run="$(cat "$TD/run" 2>/dev/null || true)"
# The state files are git-ignored, so switching first leaves them in place for the archive.
git -C "$dir" switch --quiet --no-track -c "$branch" "$base"
archive="$TD/archive/$old_ticket-$(date -u +%Y%m%d-%H%M%S)"
mkdir -p "$archive"
for f in runs run acked cancel team.json merge-check-build.log roles.override.json \
  ticket.json ticket.md order-brief.md teamlead.json teamlead.settings.json \
  round verdict-acked lead-dead relaunch-lead; do
  [ ! -e "$TD/$f" ] || mv "$TD/$f" "$archive/"
done
# Only now: a .resolved marker is permanent, and a failed switch above leaves the run live.
[ -z "$old_run" ] || bash "$root/.claude/lib/notify.sh" resolve --team "$team" --run "$old_run" --all >/dev/null 2>&1 || true
# The ended run's session records and doorbell registrations (the next run's start writes new ones).
for r in planner coder qa wrapup cli lead; do
  rm -f "$root/.agents/team/registry/$team-$r.json" "$root/.agents/team/registry/$team-$r.reg.json"
done

# Squash merges are never ancestors, so -D; the guard above proved the tip is the merged source.
[ -n "$keep_old" ] || git -C "$dir" branch --quiet -D "$old_branch"
team_seed_files "$root" "$dir"
team_write_json "$dir" "$team" "$key" "$branch" "$base" "$mode" "$root"
[ -z "$tfile" ] || team_copy_ticket "$tfile" "$dir"
# The lineage into team.json, then the start into the ledger. A failed record is a hard stop: the
# clone stays, the start is not counted, and /start-team's resume records it.
lg="$(lineage lineage "$key")" || exit $?
lp="${lg#parent=}"; lp="${lp%% *}"
jq --arg p "$lp" --arg o "${lg##*origin=}" \
  '. + {parent_ticket: (if $p == "" then null else $p end), origin_ticket: $o}' \
  "$dir/.agents/team/team.json" > "$dir/.agents/team/team.json.tmp" \
  && mv "$dir/.agents/team/team.json.tmp" "$dir/.agents/team/team.json" \
  || { echo "error: cannot write the lineage into team.json" >&2; exit 1; }
lineage record "$key" "$team" || exit $?
team_anchor_init "$root" "$team" "$dir" || echo "warn: anchor not written" >&2

echo "clone:    $dir (was $old_ticket, archived to ${archive#"$dir"/})"
echo "branch:   $branch (from $base)"
[ -z "$keep_old" ] || echo "kept:     $old_branch (PR #$pr abandoned)"
echo "base sha: $(git -C "$dir" rev-parse HEAD)"
echo "mode:     $mode"
echo "next:     bash .claude/lib/team-run.sh $team   (from this checkout)"
