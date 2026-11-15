#!/usr/bin/env bash
# Switch a team ticket that failed quick mode's Phase 0 to a fresh brainstorm run.
# Usage: bash .claude/lib/team-remode.sh <team> brainstorm
# Only after the planner's "failed … too big for quick" record, or a TeamLead plan-gate remode
# (the brainstorm run then starts from the current HEAD); run by Supervisor.
# Next: /start-team <team>. Runbook: .agents/reference/team-pipeline.md
set -euo pipefail

if [ $# -ne 2 ]; then
  sed -n '2,6p' "$0" | sed 's/^# \{0,1\}//'
  exit 2
fi
team="$1"; target="$2"
if [ "$target" != brainstorm ]; then
  echo "error: only brainstorm is supported as the new mode" >&2; exit 1
fi

. "$(dirname "$0")/team-lib.sh"
. "$(dirname "$0")/team-modes.sh"

root="$(git rev-parse --show-toplevel)"
dir="$(team_clone_dir "$team" "$root")"
TD="$dir/.agents/team"
[ -f "$TD/team.json" ] || { echo "error: no team clone at $dir" >&2; exit 1; }
ticket="$(jq -r .ticket "$TD/team.json")"; branch="$(jq -r .branch "$TD/team.json")"
base_sha="$(jq -r .base_sha "$TD/team.json")"
run=""; lead_remode=""

# Problems of the current state; pass "locked" after stop, when no role session may be alive.
check_state() {
  local mode recs=() planners=() f g last desc porcelain tip remote
  TEAM_PROBLEMS=()
  mode="$(team_mode "$TD/team.json")" || mode="unreadable"
  [ "$mode" = quick ] || TEAM_PROBLEMS+=("team $team is in mode $mode, not quick")
  run="$(cat "$TD/run" 2>/dev/null || true)"
  if [ -z "$run" ] || [ ! -d "$TD/runs/$run" ]; then
    TEAM_PROBLEMS+=("no current run in $TD/run")
  else
    shopt -s nullglob
    recs=("$TD/runs/$run"/*.json)
    planners=("$TD/runs/$run"/planner-*.json)
    shopt -u nullglob
    lead_remode=""
    for f in ${recs[@]+"${recs[@]}"}; do
      case "$(basename "$f")" in
        planner-*) [ ! -e "$f.accepted" ] \
          || TEAM_PROBLEMS+=("planner record $(basename "$f") is accepted") ;;
        # The run's own TeamLead files: verdicts and the closure close_run leaves.
        teamlead-*|closed.json) ;;
        *) TEAM_PROBLEMS+=("run $run has $(basename "$f") — another role ran") ;;
      esac
    done
    if [ ${#planners[@]} -eq 0 ]; then
      TEAM_PROBLEMS+=("no planner record in run $run")
    else
      last="$(jq -s 'sort_by(.attempt, .seq) | last' "${planners[@]}")" || last='{}'
      desc="$(jq -r '"\(.role)-\(.attempt)-\(.seq).json is \(.verdict) \"\(.message // "")\""' \
        <<<"$last")"
      # A plan-gate remode names the last planner record, which is then a done.
      f="$(jq -r '"\(.role)-\(.attempt)-\(.seq).json"' <<<"$last")"
      for g in "$TD/runs/$run"/teamlead-plan-*.json; do
        [ -f "$g" ] || continue
        ! jq -e --arg r "$f" '.verdict == "remode" and .for == $r' "$g" >/dev/null || lead_remode="$g"
      done
      if [ -n "$lead_remode" ]; then
        jq -e '.verdict == "done"' <<<"$last" >/dev/null \
          || TEAM_PROBLEMS+=("last record $desc, but ${lead_remode##*/} remodes a done record")
      else
        jq -e '.verdict == "failed" and ((.message // "") | startswith("too big for quick"))' \
          <<<"$last" >/dev/null \
          || TEAM_PROBLEMS+=("last record $desc, not failed \"too big for quick: …\"")
      fi
    fi
  fi
  if [ -f "$TD/session.json" ]; then
    jq -e --arg r "$run" '.role == "planner" and .run == $r' "$TD/session.json" >/dev/null \
      || TEAM_PROBLEMS+=("session.json is $(jq -c '{role, run}' "$TD/session.json"),\
 not the planner of run $run")
  fi
  if ! porcelain="$(git -C "$dir" status --porcelain)"; then
    TEAM_PROBLEMS+=("git status failed in $dir")
  elif [ -n "$porcelain" ]; then
    TEAM_PROBLEMS+=("clone $dir has uncommitted changes")
  fi
  tip="$(git -C "$dir" rev-parse HEAD)"
  # After a TeamLead remode the committed quick plan stays in history (no rewrite).
  [ "$tip" = "$base_sha" ] || [ -n "$lead_remode" ] \
    || TEAM_PROBLEMS+=("HEAD $tip is not base_sha $base_sha — the planner committed work")
  [ "$(git -C "$dir" branch --show-current)" = "$branch" ] \
    || TEAM_PROBLEMS+=("branch $branch is not checked out in $dir")
  if ! remote="$(git -C "$dir" ls-remote origin "refs/heads/$branch")"; then
    TEAM_PROBLEMS+=("git ls-remote origin failed in $dir")
  elif [ -n "$remote" ] && [ "${remote%%[[:space:]]*}" != "$base_sha" ] \
    && { [ -z "$lead_remode" ] || [ "${remote%%[[:space:]]*}" != "$tip" ]; }; then
    TEAM_PROBLEMS+=("origin $branch is at ${remote%%[[:space:]]*}, not base_sha $base_sha")
  fi
  [ "${1:-}" = locked ] || return 0
  # stop touches cancel and a starting runner removes it, also one whose lock stop then deleted.
  [ -e "$TD/cancel" ] || TEAM_PROBLEMS+=("a runner started during stop (cancel removed)")
  for f in $TEAM_ROLES cli; do
    ! team_tmux_alive "$team-$f" || TEAM_PROBLEMS+=("tmux session $team-$f is alive after stop")
  done
}

report_or_die() {
  [ ${#TEAM_PROBLEMS[@]} -gt 0 ] || return 0
  for p in "${TEAM_PROBLEMS[@]}"; do echo "error: $p" >&2; done
  exit 1
}

# A refusal here must leave a live role session of an ordinary run untouched.
check_state; report_or_die

out="$(bash "$root/.claude/lib/team-run.sh" "$team" stop 2>&1)" || { echo "$out" >&2; exit 1; }

mkdir "$TD/lock" 2>/dev/null \
  || { echo "error: runner lock taken after stop — a runner started; nothing changed" >&2; exit 1; }
echo $$ > "$TD/lock/pid"
trap '[ "$(cat "$TD/lock/pid" 2>/dev/null)" != "$$" ] || rm -rf "$TD/lock"' EXIT

# The planner session lived until stop, so it may have written a record or a commit meanwhile.
check_state locked; report_or_die

bash "$root/.claude/lib/team-audit.sh" "$team" --final archived \
  || echo "warn: team audit failed — archiving anyway" >&2

# A remode starts a new run, and a run's TeamLead ends with its run.
(cd "$root" && bash .claude/lib/team-lead.sh end "$team") >/dev/null 2>&1 \
  || echo "warn: TeamLead of $team did not end — check: tmux has-session -t =$team-lead" >&2

old_run="$run"
archive="$TD/archive/$ticket-remode-$(date -u +%Y%m%d-%H%M%S)"
mkdir -p "$archive"
for f in runs run acked cancel session.json teamlead.json teamlead.settings.json teamlead.reg.json \
  round verdict-acked lead-dead relaunch-lead inbox-rung; do
  [ ! -e "$TD/$f" ] || mv "$TD/$f" "$archive/"
done

# Later roles and the wrapup read the notes of the current run only.
new_run="$team-$(date -u +%Y%m%d-%H%M%S)"
echo "$new_run" > "$TD/run"
mkdir -p "$TD/runs/$new_run"
notes="$archive/runs/$old_run/notes.md"
[ ! -f "$notes" ] || cp "$notes" "$TD/runs/$new_run/notes.md"

jq '.mode = "brainstorm"' "$TD/team.json" > "$TD/team.json.tmp"
mv "$TD/team.json.tmp" "$TD/team.json"

echo "clone:    $dir ($ticket, quick → brainstorm)"
echo "archived: ${archive#"$dir"/}"
echo "run:      $new_run (notes carried from $old_run)"
echo "branch:   $branch (unchanged, base $base_sha${lead_remode:+, from HEAD $(git -C "$dir" rev-parse --short HEAD)})"
echo "next:     /start-team $team   (or: bash .claude/lib/team-run.sh $team, from this checkout)"
