#!/usr/bin/env bash
# Provision a team clone next to this checkout, on a fresh branch cut from a harness-carrying line.
#
# Usage: bash .claude/lib/team-new.sh <team> <TT-key> <new-branch> <base-ref> [mode] [--ticket-file <f>]
#        [--follow-up-of <key>]
#   mode: brainstorm (default) | quick | cli — fixed for the ticket
#   e.g. bash .claude/lib/team-new.sh alfa AB-790 feature/AB-790-slug origin/<trunk>
#
# Result: ../<repo>-<team>/ on <new-branch>, per-developer files copied, .agents/team/team.json.
# Next ticket in the same clone: team-next.sh. Runbook: .agents/reference/team-pipeline.md
set -euo pipefail

# Bash 3.2: no `getopt --long`; pull --ticket-file, --follow-up-of out of the positionals by hand.
tfile=""; fu=""; ARGS=()
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
    *) ARGS+=("$1"); shift ;;
  esac
done
set -- ${ARGS[@]+"${ARGS[@]}"}

if [ $# -ne 4 ] && [ $# -ne 5 ]; then
  sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'
  exit 2
fi

team="$1"; key="$2"; branch="$3"; base="$4"; mode="${5:-brainstorm}"

. "$(dirname "$0")/team-lib.sh"
. "$(dirname "$0")/team-modes.sh"
. "$(dirname "$0")/team-anchor.sh"

root="$(git rev-parse --show-toplevel)"
# Before anything that creates a directory, switches a branch or writes team.json.
team_profile_load "$root"
team_profile_require_supported
dir="$(team_clone_dir "$team" "$root")"
TEAM_PROBLEMS=()
team_check_name "$team" 2>/dev/null || TEAM_PROBLEMS+=("team name '$team' must match [a-z0-9-]+")
! tab="$(team_tab_clash "$team" "$root")" \
  || TEAM_PROBLEMS+=("team name $team is the roles' Herdr tab $tab (each team gets a tab named after it) — pick another name")
# Session names (session-host-lib.sh sh_name): not a role, an ad-hoc or a helper name, and the
# longest one, <prefix>-<team>-wrapup (as long as -runner), fits 32 characters.
lt="$(printf '%s' "$team" | tr '[:upper:]' '[:lower:]')"
for r in $(jq -r '.teams.sessions // {} | keys[]' "$root/.claude/project-profile.json" 2>/dev/null) \
  Supervisor TeamLead Advisor Fable Astra; do
  [ "$lt" != "$(printf '%s' "$r" | tr '[:upper:]' '[:lower:]')" ] \
    || { TEAM_PROBLEMS+=("team name $team is a declared role"); break; }
done
case "$lt" in adhoc-*|retro) TEAM_PROBLEMS+=("team name $team is reserved (adhoc-*, retro)") ;; esac
! lname="$(sh_name "$root" "$team-wrapup" 2>&1)" && TEAM_PROBLEMS+=("${lname#session-host: }") || true
[ ! -e "$dir" ] || TEAM_PROBLEMS+=("$dir already exists — to start the next ticket there: team-next.sh")
team_ticket_checks "$root" "$key" "$branch" "$base"
team_mode_checks "$root" "$base" "$mode"
team_seed_checks "$root" "$base"

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

# The follow-up cap (team-lineage.sh): checked after the refusals above, before the first side
# effect; its exit passes through (9 waits for the Operator's consent, 2 is a contradiction).
lopt=()
[ -z "$fu" ] || lopt+=(--follow-up-of "$fu")
[ -z "$tfile" ] || lopt+=(--ticket-file "$(cd "$(dirname "$tfile")" && pwd -P)/ticket.md")
lineage() { (cd "$root" && bash .claude/lib/team-lineage.sh "$@" ${lopt[@]+"${lopt[@]}"}); }
lineage check "$key" || exit $?

team_clone_dissociated "$root" "$dir"
git -C "$dir" switch --quiet --no-track -c "$branch" "$base"
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

echo "clone:    $dir"
echo "branch:   $branch (from $base)"
echo "base sha: $(git -C "$dir" rev-parse HEAD)"
echo "mode:     $mode"
echo "next:     bash .claude/lib/team-run.sh $team   (from this checkout)"
