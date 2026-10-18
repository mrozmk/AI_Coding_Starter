#!/usr/bin/env bash
# Shared ground between `team-merge-check.sh` (which decides) and `team-integrate.sh` (which
# publishes): the record digest, the one eligibility check both run, and the `merge-check.json`
# writer. Sourced from the MAIN checkout (like team-modes.sh), never executed.
#
# Self-contained on purpose: a team clone may sit on a base whose `team-lib.sh` predates any of
# this, so nothing here depends on helpers from the clone.
# Bash 3.2 compatible (macOS /bin/bash).

# The roles whose records make up a run. Hardcoded rather than taken from `$TEAM_ROLES`: the digest
# must mean the same thing in the clone and in the main checkout, whatever either side's team-lib.
TEAM_RECORD_ROLES="planner coder qa wrapup cli"

# Usage: team_records_digest <team dir> <run> → one sha256 over the run's role records.
# The ONLY definition of `records_digest`. It covers the role records and their `.accepted` markers
# — name plus content — so a NEW record (a resumed workflow) or an edited one changes the digest,
# which is what binds a merge-check verdict to the work it was computed on. Deliberately NOT
# included: merge-check.json / integrate.json / wrapup-state.json / the summary reports, all of
# which the check itself writes or rewrites.
team_records_digest() {  # <td> <run>
  local d="$1/runs/$2" r f s
  {
    for r in $TEAM_RECORD_ROLES; do
      for f in "$d/$r-"*.json "$d/$r-"*.json.accepted; do
        [ -f "$f" ] || continue
        s="$(shasum -a 256 < "$f")" || return 1
        printf '%s %s\n' "$(basename "$f")" "${s%% *}"
      done
    done
  } | LC_ALL=C sort | shasum -a 256 | awk '{print $1}'
}

# Usage: team_integration_eligible <team> <clone> <run> <mode> <pr>
#   rc 0 eligible · 3 refusal · 4 recoverable (GitHub still recomputing the merge ref)
#   sets IE_SRC / IE_TGT / IE_MERGE from `team-pr.sh readiness`.
#
# Run TWICE on the same run: by merge-check before the gates, and by integrate immediately before
# the push, under the integration lock. The second call is what makes the gate verdict mean
# anything — between the two, a role could have restarted, the clone could have gone dirty, or
# GitHub could have rebuilt the merge ref.
IE_SRC=""; IE_TGT=""; IE_MERGE=""
team_integration_eligible() {  # <team> <clone> <run> <mode> <pr>
  local team="$1" clone="$2" run="$3" mode="$4" pr="$5"
  local td="$clone/.agents/team" rd branch line role rec out rc=0 merge
  IE_SRC=""; IE_TGT=""; IE_MERGE=""
  ie_no() { echo "error: $1" >&2; return 3; }
  [ -n "$run" ] || { ie_no "no run id for team $team — nothing to integrate"; return 3; }
  rd="$td/runs/$run"
  branch="$(jq -r '.branch // ""' "$td/team.json")" || { ie_no "cannot read $td/team.json"; return 3; }
  line="$(jq -r '.line // ""' "$td/team.json")"

  # (1) the work is accepted: cli alone in cli mode, otherwise qa AND wrapup (Amendment 3).
  ie_accepted() {  # ie_accepted <role> → the record path
    local f
    f="$(ls -1 "$rd/$1-"*.json.accepted 2>/dev/null | tail -n 1)" || true
    [ -n "$f" ] || return 1
    printf '%s\n' "${f%.accepted}"
  }
  if [ "$mode" = cli ]; then
    rec="$(ie_accepted cli)" || { ie_no "no accepted cli record in run '$run'"; return 3; }
    [ "$(jq -r .verdict "$rec")" = done ] || { ie_no "accepted cli record is not done"; return 3; }
  else
    rec="$(ie_accepted qa)" || { ie_no "no accepted qa record in run '$run'"; return 3; }
    [ "$(jq -r .verdict "$rec")" = done ] || { ie_no "accepted qa record is not done"; return 3; }
    rec="$(ie_accepted wrapup)" || { ie_no "wrapup not done in run '$run'"; return 3; }
    [ "$(jq -r .verdict "$rec")" = done ] || { ie_no "accepted wrapup record is not done"; return 3; }
  fi

  # (2) nobody is working: no live role, no runner, no role tmux session.
  [ ! -f "$td/session.json" ] \
    || { ie_no "a role is still live ($(jq -r .role "$td/session.json")) — wait for it to finish"
         return 3; }
  # `$TD/lock` is the runner's authoritative state, not tmux: `team-run.sh <team>; read` leaves the
  # `<team>-runner` session alive long after the runner exited, so tmux would refuse forever.
  [ ! -e "$td/lock" ] \
    || { ie_no "the runner still holds $td/lock (pid $(cat "$td/lock/pid" 2>/dev/null || echo none))"
         return 3; }
  if command -v tmux >/dev/null 2>&1; then
    for role in ${TEAM_ROLES:-planner coder qa wrapup} cli; do
      ! tmux has-session -t "=$team-$role" 2>/dev/null \
        || { ie_no "the $role session of $team is still alive"; return 3; }
    done
  fi

  # (3) the clone is clean: an uncommitted file is work that never reached the PR. The exit status
  # is read SEPARATELY from the output — a `git status` that FAILS prints nothing on stdout, so
  # testing only for empty output would read a broken or unreadable repository as a clean one.
  local st_out st_rc=0
  st_out="$(git -C "$clone" status --porcelain 2>&1)" || st_rc=$?
  [ "$st_rc" = 0 ] \
    || { ie_no "cannot read the status of $clone (git exit $st_rc): $st_out"; return 3; }
  [ -z "$st_out" ] || { ie_no "clone $clone is dirty"; return 3; }

  # (4) the PR is ours, active, published, and on exactly the refs team.json names.
  ( cd "$clone" && bash .claude/lib/team-pr.sh identity "$pr" "$branch" "$line" ) \
    || { ie_no "PR #$pr identity mismatch ($branch → $line)"; return 3; }
  out="$( cd "$clone" && bash .claude/lib/team-pr.sh state "$pr" )" \
    || { ie_no "cannot read the state of PR #$pr"; return 3; }
  [ "$(jq -r '.draft' <<<"$out")" = false ] \
    || { ie_no "PR #$pr is still a draft — publish it first"; return 3; }

  # (5) readiness: the tested merge commit, under `refs/team-pr/<pr>/merge` in the clone.
  rc=0
  out="$( cd "$clone" && bash .claude/lib/team-pr.sh readiness "$pr" )" || rc=$?
  # A refusal before any ref is read (fork, closed PR) prints to stderr only — no JSON to parse.
  merge=unknown
  [ -z "$out" ] || merge="$(jq -r '.merge // "unknown"' <<<"$out" 2>/dev/null || echo unknown)"
  if [ "$rc" != 0 ]; then
    case "$merge" in
      conflict) echo "error: PR #$pr conflicts with $line — resolve it on the PR" >&2; return 3 ;;
      *) echo "error: PR #$pr merge ref is $merge — GitHub is still recomputing, rerun later" >&2
         return 4 ;;
    esac
  fi
  IE_TGT="$(jq -r '.target_sha' <<<"$out")"
  IE_MERGE="$(jq -r '.merge_sha' <<<"$out")"
  IE_SRC="$(jq -r '.source_sha' <<<"$out")"
  [ -n "$IE_SRC" ] && [ -n "$IE_TGT" ] && [ -n "$IE_MERGE" ] \
    || { ie_no "readiness of PR #$pr is incomplete: $out"; return 3; }
}

# Usage: team_merge_check_write <file> <run> <pr> <repo> <head_ref> <base_ref> <source_sha>
#                              <target_sha> <merge_sha> <records_digest> <verdict>
# tmp + `mv`: a reader (integrate) must never see half a verdict.
team_merge_check_write() {
  local f="$1"
  mkdir -p "$(dirname "$f")"
  jq -n --arg run "$2" --arg pr "$3" --arg repo "$4" --arg head "$5" --arg base "$6" \
    --arg src "$7" --arg tgt "$8" --arg merge "$9" --arg dig "${10}" --arg v "${11}" \
    --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{run: $run, pr: $pr, repo: $repo, head_ref: $head, base_ref: $base, source_sha: $src,
      target_sha: $tgt, merge_sha: $merge, records_digest: $dig, verdict: $v, at: $at}' \
    > "$f.tmp" && mv "$f.tmp" "$f"
}
