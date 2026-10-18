#!/usr/bin/env bash
# Integrates a team PR by publishing the EXACT commit the gates ran on: a plain, non-force push of
# the tested merge commit `M = merge(T, S)` onto the PR's base. GitHub then marks the PR MERGED
# because its head became reachable from the base.
#
# Usage: bash .claude/lib/team-integrate.sh <team> [--base <branch>]
#   e.g. bash .claude/lib/team-integrate.sh alfa
#   --base <branch>: integrate into a line other than teams.trunk (it must be the team's `line`).
#
# Run from the main checkout, after `team-merge-check.sh <team>` printed VERDICT ok. It never
# merges through the API: no `gh pr merge` (it cannot promise the tested M), no admin override, no
# rebase, no force. A server that refuses the push (branch protection) is a STOP, not a fallback.
#
# Order: lock the base · read-only recovery of an earlier intent · merge-check.json · the base is
# still the validated target · re-run the eligibility check under the lock · write the intent ·
# push · verify the base is M and the PR is MERGED.
#
# Exit: 0 integrated, PR MERGED · 2 usage / ADO profile
#   3 refused with NO effect (lock held, missing or stale merge-check, moved sha, non-ff push)
#   4 partial or unknown effect (code published but the PR is not MERGED, server refused, network)
# Bash 3.2 compatible (macOS /bin/bash).
set -euo pipefail

usage() { sed -n '2,21p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
die() { echo "error: $2" >&2; exit "$1"; }

TEAM=""; BASE_OPT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --base) BASE_OPT="${2:-}"; shift 2 || usage; [ -n "$BASE_OPT" ] || usage ;;
    -*)     usage ;;
    *)      [ -z "$TEAM" ] || usage; TEAM="$1"; shift ;;
  esac
done
[ -n "$TEAM" ] || usage

# ---- 1. profile, clone, the target line ---------------------------------------------------------

root="$(git rev-parse --show-toplevel)"
. "$root/.claude/lib/team-profile.sh"
team_profile_load "$root"
team_profile_require_supported
[ "$TEAM_PR_PROVIDER" = github ] \
  || die 2 "use the ADO merge (/pr-merge) for pr_provider=azure-devops"
CLONE="$(team_clone_dir "$TEAM" "$root")"
[ -f "$CLONE/.agents/team/team.json" ] || die 3 "no team clone at $CLONE"
cd "$CLONE"
. "$CLONE/.claude/lib/team-lib.sh"
. "$root/.claude/lib/team-modes.sh"
. "$root/.claude/lib/team-integrate-lib.sh"
. "$root/.claude/lib/team-integrate-lock.sh"

TD="$CLONE/.agents/team"
BRANCH="$(team_json branch)"; LINE="$(team_json line)"
RUN="$(cat "$TD/run" 2>/dev/null || true)"
MODE="$(team_mode "$TD/team.json")" || die 3 "cannot read the mode of $TD/team.json"
B="${BASE_OPT:-$TEAM_TRUNK}"
# The team's own `line` IS the PR base; integrating anywhere else would push a merge commit whose
# first parent is not the branch we are updating.
[ "$B" = "$LINE" ] \
  || die 3 "team line is $LINE, not $B — pass --base $LINE to integrate into it"

ls_rem() {  # ls_rem <ref> → the sha on origin, empty when absent; rc 1 when the call itself failed
  local o
  o="$(git -C "$CLONE" ls-remote origin "$1" 2>&1)" || { printf '%s\n' "$o" >&2; return 1; }
  printf '%s' "$o" | awk 'NR == 1 { print $1 }'
}

# ---- 2. the integration lock for this base ------------------------------------------------------

# `$root` was resolved BEFORE the cd: inside the clone `--show-toplevel` answers the clone, and the
# lock would be invisible to the solo worker flow and to every other team on this base.
OWNER="team-integrate:$TEAM:$$"
til_acquire "$root" "$B" "$OWNER" $$ || exit 3
# Releases only OUR lock: `til_release` checks the owner AND the nonce `til_acquire` just wrote, so
# a lock of the same label taken later by somebody else is never removed by this trap.
trap 'til_release "$root" "$B" "$OWNER" "$TIL_TOKEN" >/dev/null 2>&1 || true' EXIT

# ---- the intent -------------------------------------------------------------------------------

INTENT="$root/.agents/team/integrate/$TEAM-$RUN.json"
PR=""; T=""; S=""; M=""; DIG=""; NOTE=""
intent_write() {  # intent_write <state> [note]
  mkdir -p "$(dirname "$INTENT")"
  jq -n --arg team "$TEAM" --arg run "$RUN" --arg repo "$TEAM_GH_REPO" --arg pr "$PR" \
    --arg base "$B" --arg t "$T" --arg s "$S" --arg m "$M" --arg dig "$DIG" \
    --arg st "$1" --arg note "${2:-}" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{team: $team, run: $run, repo: $repo, pr: $pr, base: $base, target_sha: $t, source_sha: $s,
      merge_sha: $m, records_digest: $dig, state: $st, at: $at, note: $note}' \
    > "$INTENT.tmp" && mv "$INTENT.tmp" "$INTENT"
}

# ---- 3. recovery — READ ONLY, before anything else ---------------------------------------------

# The only safe answer to "did my push land?" is to look at the base. A second push of M is never
# needed: if M is already in the base, the work is published, whatever the client was told.
PUBLISHED=0
if [ -f "$INTENT" ]; then
  ist="$(jq -r '.state // ""' "$INTENT")"
  PR="$(jq -r '.pr // ""' "$INTENT")"; T="$(jq -r '.target_sha // ""' "$INTENT")"
  S="$(jq -r '.source_sha // ""' "$INTENT")"; M="$(jq -r '.merge_sha // ""' "$INTENT")"
  DIG="$(jq -r '.records_digest // ""' "$INTENT")"
  ibase="$(jq -r '.base // ""' "$INTENT")"
  [ "$ibase" = "$B" ] \
    || die 3 "the intent of run $RUN targets $ibase, not $B — integrate that base or remove it"
  if [ "$ist" = done ]; then
    # Even a finished integration is re-read against the base: `done` means "we published M", and
    # reporting that as the current state while the base has moved on to something else would hide
    # exactly the case the contract is about.
    dnow="$(ls_rem "refs/heads/$B")" || die 4 "cannot read origin $B — state unchanged, rerun"
    [ "$dnow" = "$M" ] \
      || die 3 "base moved past M — manual check (base $dnow, recorded M $M, intent done)"
    echo "already integrated: PR #$PR M=$M"
    exit 0
  fi
  # `stale` and `rejected` are not skipped: the base may have become readable or returned to T.
  now="$(ls_rem "refs/heads/$B")" || die 4 "cannot read origin $B — state unchanged, rerun"
  if [ "$now" = "$M" ]; then
    PUBLISHED=1
    intent_write published
  elif [ "$now" = "$T" ]; then
    echo "no push landed — retrying (base still $T)"
  else
    # The contract is `base == M`, EXACTLY (Amendment 1): "M is an ancestor of the base" is not it.
    # It means somebody published on top of our result (or instead of it), and whether the tested
    # tree survived that is not something this tool can decide. The intent is left untouched so a
    # human reads the same state we did.
    die 3 "base moved past M — manual check (base $now, T $T, M $M)"
  fi
fi

if [ "$PUBLISHED" = 0 ]; then

# ---- 4. the merge-check verdict for THIS run ----------------------------------------------------

MC="$TD/runs/$RUN/merge-check.json"
[ -f "$MC" ] || die 3 "no merge-check for run ${RUN:-none} — run team-merge-check.sh $TEAM"
# ONE read, then every field comes from that snapshot. Field-by-field `jq "$MC"` calls would let a
# concurrent merge-check swap the file between two of them: we would check an `ok` verdict and then
# push the M of a different, unverified check.
MCJ="$(cat "$MC")" || die 3 "cannot read $MC"
# TEST SEAM (fixtures only, explicit non-empty value): runs immediately after the snapshot read and
# before any field is used, which is precisely the window a second `jq "$MC"` would have read in.
# Subshell, errexit off: the seam must never decide the run's outcome, only stage the file swap.
[ -z "${TEAM_INTEGRATE_SNAPSHOT_HOOK:-}" ] \
  || ( set +e; eval "$TEAM_INTEGRATE_SNAPSHOT_HOOK" ) || true
mcf() { jq -r --arg k "$1" '.[$k] // ""' <<<"$MCJ"; }
mcv="$(mcf verdict)"
[ "$mcv" = ok ] || die 3 "merge-check verdict is '${mcv:-none}' — rerun team-merge-check.sh $TEAM"

# The PR comes from the RECORDS, never from the merge-check file: the file is what we are checking.
if [ "$MODE" = cli ]; then
  erec="$(team_accepted_record "$RUN" cli)"
  [ -n "$erec" ] || die 3 "no accepted cli record in run ${RUN:-none}"
else
  erec="$(team_accepted_record "$RUN" qa)"
  [ -n "$erec" ] || die 3 "no accepted qa record in run ${RUN:-none}"
fi
PR="$(jq -r '.pr_id // ""' "$erec")"
[ -n "$PR" ] && [ "$PR" != null ] || die 3 "the accepted record of run $RUN names no PR"
for pair in "run=$RUN" "pr=$PR" "repo=$TEAM_GH_REPO" "head_ref=$BRANCH" "base_ref=$LINE"; do
  k="${pair%%=*}"; want="${pair#*=}"
  got="$(mcf "$k")"
  [ "$got" = "$want" ] \
    || die 3 "merge-check $k is '$got', not '$want' — rerun team-merge-check.sh $TEAM"
done
[ "$(mcf base_ref)" = "$B" ] || die 3 "merge-check targets another base — rerun"
T="$(mcf target_sha)"; S="$(mcf source_sha)"
M="$(mcf merge_sha)"; DIG="$(mcf records_digest)"
[ -n "$T" ] && [ -n "$S" ] && [ -n "$M" ] || die 3 "merge-check for run $RUN is incomplete"

# ---- 5. the base is still the target the gates ran against --------------------------------------

base_now="$(ls_rem "refs/heads/$B")" || die 4 "cannot read origin $B — nothing was pushed"
[ "$base_now" = "$T" ] \
  || die 3 "target moved since merge-check — rerun merge-check (base is ${base_now:-absent}, not $T)"

# ---- 6. the eligibility check again, under the lock ---------------------------------------------

erc=0
team_integration_eligible "$TEAM" "$CLONE" "$RUN" "$MODE" "$PR" || erc=$?
case "$erc" in
  0) ;;
  4) die 4 "PR #$PR is not ready right now — rerun later" ;;
  *) die 3 "PR #$PR is no longer eligible — nothing was pushed" ;;
esac
# Astra 3: a record added after the verdict means the workflow resumed, and the gates ran on a
# state that no longer exists. Name and sha256, never a timestamp.
[ "$(team_records_digest "$TD" "$RUN")" = "$DIG" ] \
  || die 3 "workflow resumed after merge-check — rerun merge-check"
[ "$IE_SRC" = "$S" ] || die 3 "PR head is $IE_SRC, not the validated $S — rerun merge-check"
[ "$IE_TGT" = "$T" ] || die 3 "PR base is $IE_TGT, not the validated $T — rerun merge-check"
[ "$IE_MERGE" = "$M" ] \
  || die 3 "the merge ref is $IE_MERGE, not the tested $M — rerun merge-check"

# ---- 7. the last look, then the durable intent --------------------------------------------------

main_before="$(ls_rem "refs/heads/$B")" || die 4 "cannot read origin $B — nothing was pushed"
# Amendment 1: a plain push would also accept any ancestor of M, so this refusal — not the push —
# is what reports a base that moved between the check and now.
[ "$main_before" = "$T" ] \
  || die 3 "base is ${main_before:-absent}, not the validated target $T — rerun merge-check"
intent_write pending

# ---- 8. the push: the tested M, by sha, onto the base -------------------------------------------

echo "pushing $M onto $B of $TEAM_GH_REPO (PR #$PR)"
set +e
out="$(git -C "$CLONE" push --porcelain origin "$M:refs/heads/$B" 2>&1)"
prc=$?
set -e
printf '%s\n' "$out" | sed 's/^/  | /'
# The porcelain status line for OUR refspec: <flag> TAB <local>:<remote> TAB <summary>.
pline="$(printf '%s\n' "$out" \
  | awk -F'\t' -v r=":refs/heads/$B" 'NF >= 3 && index($2, r) { print; exit }')"
TAB="$(printf '\t')"
flag="${pline%%$TAB*}"
rest="${pline#*$TAB}"; summary="${rest#*$TAB}"

push_unknown() {  # the read-only answer of step 3, for a push whose outcome we do not know
  local n
  n="$(ls_rem "refs/heads/$B")" || die 4 "push result unknown and origin $B unreadable — rerun"
  if [ "$n" = "$M" ]; then
    echo "push reported an error but $B is M — continuing with the verification"
    return 0
  fi
  if [ "$n" = "$T" ]; then
    die 4 "push result unknown, base unchanged — rerun team-integrate.sh $TEAM"
  fi
  die 4 "push result unknown and base is at $n — check it by hand"
}

case "$flag" in
  ' '|'*'|'=')
    # A fast-forward: the old value the SERVER saw. Porcelain abbreviates it, hence the prefix test.
    if [ "$flag" = ' ' ]; then
      old="${summary%%..*}"
      case "$T" in
        "$old"*) ;;
        *) echo "warning: base moved during push (was $old, not $T) — published tested M anyway" ;;
      esac
    fi ;;
  '!')
    case "$summary" in
      *'[remote rejected]'*)
        intent_write rejected "$summary"
        die 4 "server refused the push ($summary) — base unchanged; branch protection? stop,\
 do not change repo settings" ;;
      *'[rejected]'*)
        intent_write rejected "$summary"
        die 3 "target moved — rerun merge-check ($summary)" ;;
      *) push_unknown ;;
    esac ;;
  *) push_unknown ;;
esac
[ "$prc" = 0 ] || push_unknown

fi  # PUBLISHED

# ---- 9. the base really is M, and the PR really is MERGED ---------------------------------------

after="$(ls_rem "refs/heads/$B")" || die 4 "pushed, but origin $B is unreadable — verify by hand"
# Success is `base == M`, exactly — the same bar as the recovery above. A base that merely CONTAINS
# M means another writer landed on top of our publish between the push and this read, and reporting
# that as a clean integration would hide it.
[ "$after" = "$M" ] \
  || die 4 "base moved past M — manual check (base $after, tested M $M); the PR was not closed"
intent_write published "${NOTE:-}"

POLL="${TEAM_INTEGRATE_POLL_SECS:-3}"; WAIT="${TEAM_INTEGRATE_MERGED_SECS:-30}"
waited=0
status=unknown
while :; do
  status="$( bash .claude/lib/team-pr.sh state "$PR" | jq -r '.status // "unknown"' )" \
    || status=unknown
  [ "$status" != completed ] || break
  [ "$waited" -lt "$WAIT" ] && [ "$POLL" -gt 0 ] || break
  sleep "$POLL"; waited=$((waited + POLL))
done

if [ "$status" = completed ]; then
  # The poll takes time, and a writer can land on the base inside it. `done` is only written for a
  # base that is still exactly M — otherwise this is a partial result like any other.
  final="$(ls_rem "refs/heads/$B")" \
    || die 4 "PR #$PR is MERGED but origin $B is unreadable — verify by hand"
  [ "$final" = "$M" ] \
    || die 4 "base moved past M while the PR was closing — manual check (base $final, tested M $M)"
  intent_write done "${NOTE:-}"
  echo "integrated: PR #$PR into $B T=$T S=$S M=$M"
  exit 0
fi
# The code is published either way; what is left is a PR that GitHub did not close. The usual
# cause is a source branch that moved after the validation (Amendment 2): its head is no longer
# reachable from the base, so the PR stays open with the tested merge already in.
src_now="$(ls_rem "refs/heads/$BRANCH")" || src_now=""
if [ -n "$src_now" ] && [ "$src_now" != "$S" ]; then
  die 4 "source advanced after validation — PR left open; tested M is on $B (head $src_now, validated $S)"
fi
die 4 "M is on $B but PR #$PR is not MERGED — check it by hand"
