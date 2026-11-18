#!/usr/bin/env bash
# Shared ground between `team-merge-check.sh` (which decides) and `team-integrate.sh` (which
# publishes): the record digest, the one eligibility check both run, and the `merge-check.json`
# writer. Sourced from the MAIN checkout (like team-modes.sh), never executed.
#
# Self-contained on purpose: a team clone may sit on a base whose `team-lib.sh` predates any of
# this, so nothing here depends on helpers from the clone.
# Bash 3.2 compatible (macOS /bin/bash).
# The session-host driver from this (main) checkout: its tmux calls go through sh_tmux.
[ -n "${SH_LIB:-}" ] || . "$(dirname "${BASH_SOURCE[0]}")/session-host-lib.sh"

# The roles whose records make up a run. Hardcoded rather than taken from `$TEAM_ROLES`: the digest
# must mean the same thing in the clone and in the main checkout, whatever either side's team-lib.
TEAM_RECORD_ROLES="planner coder qa wrapup cli"

# Usage: team_ie_run_ref <team dir> <run> → <run>, or <run>/r<n> in rework round n ≥ 2 — the same
# rule as team_run_ref (team-lib.sh), kept here because a clone's team-lib may predate it.
team_ie_run_ref() {
  local n; n="$(jq -r --arg r "$2" 'select(.run == $r) | .round' "$1/round" 2>/dev/null)" || n=""
  if [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -gt 1 ]; then echo "$2/r$n"; else echo "$2"; fi
}

# Usage: team_records_digest <team dir> <run> → one sha256 over the run's role records.
# The ONLY definition of `records_digest`. It covers the role records and their `.accepted` markers
# — name plus content — so a NEW record (a resumed workflow) or an edited one changes the digest,
# which is what binds a merge-check verdict to the work it was computed on. Deliberately NOT
# included: merge-check.json / integrate.json / wrapup-state.json / the summary reports, all of
# which the check itself writes or rewrites. Every rework round's records (r*/) count, named by their
# path under the run dir, so a round-1 run digests exactly as before.
team_records_digest() {  # <td> <run>
  local d="$1/runs/$2" r f s
  {
    for r in $TEAM_RECORD_ROLES; do
      for f in "$d/$r-"*.json "$d/$r-"*.json.accepted "$d"/r*/"$r-"*.json "$d"/r*/"$r-"*.json.accepted; do
        [ -f "$f" ] || continue
        s="$(shasum -a 256 < "$f")" || return 1
        printf '%s %s\n' "${f#"$d"/}" "${s%% *}"
      done
    done
  } | LC_ALL=C sort | shasum -a 256 | awk '{print $1}'
}

# Usage: team_lm_union_guard <clone> <pr> <line> <T> < paths → rc 3 with the reason on stderr when a
#   path on stdin is union-merged by T's attributes (or they cannot be read); rc 0 otherwise.
# Union merge would splice overlapping memory edits silently, while the provider's merge reports
# them as conflicting (team-pipeline.md): refuse instead of testing a merge GitHub would not make.
team_lm_union_guard() {
  local clone="$1" pr="$2" line="$3" t="$4" paths attrs union
  paths="$(grep -v '^$' || true)"
  [ -n "$paths" ] || return 0
  attrs="$(printf '%s\n' "$paths" | git -C "$clone" check-attr --stdin --source "$t" merge)" \
    || { echo "error: PR #$pr: cannot read the merge attributes of $t" >&2; return 3; }
  union="$(printf '%s\n' "$attrs" | sed -n 's/: merge: union$//p')"
  [ -z "$union" ] && return 0
  echo "error: PR #$pr and $line both changed union-merged memory logs: $(echo $union)" \
    "— the provider reports this as conflicting; follow team-pipeline.md → PR conflicting in memory files" >&2
  return 3
}

# Usage: team_local_merge <clone> <pr> <line> <branch> <T> <S> → prints the sha of M = merge(T, S)
#   kept under `refs/team-pr/<pr>/local-merge` in the clone; rc 3 with the reason on stderr.
# Reused while its FULL parent list is still exactly `T S` AND its tree is the merge-tree result,
# so merge-check and integrate (two calls, minutes apart) agree on one sha; a fresh commit-tree would
# carry new timestamps. The guards and merge-tree run on every call: a ref is writable by anything in
# the clone, so only a commit whose content IS merge(T, S) may be reused. Built with
# merge-tree/commit-tree, so the clone's worktree and index are never touched.
# Two union guards, both reading T's attributes — the same ones merge-tree is told to use with
# `--attr-source "$t"` (otherwise it reads the worktree's, which sits at S): the input guard refuses
# a union path both sides changed (it alone names a memory conflict merge-tree itself reports as a
# conflict, e.g. a whole-file modify/delete), the merge guard refuses a union path merge-tree
# content-merged (it alone sees a rename into a union path).
team_local_merge() {  # <clone> <pr> <line> <branch> <T> <S>
  local clone="$1" pr="$2" line="$3" branch="$4" t="$5" s="$6"
  local ref="refs/team-pr/$pr/local-merge" have mb dt ds both out tree m mrc=0
  # T is the live base tip from ls-remote; the clone may not have fetched it yet.
  git -C "$clone" cat-file -e "$t^{commit}" 2>/dev/null \
    || git -C "$clone" fetch --quiet origin "refs/heads/$line" 2>/dev/null || true
  git -C "$clone" cat-file -e "$t^{commit}" 2>/dev/null \
    && git -C "$clone" cat-file -e "$s^{commit}" 2>/dev/null \
    || { echo "error: PR #$pr: $line tip $t or head $s is not in $clone — cannot build the local merge" >&2
         return 3; }
  mb="$(git -C "$clone" merge-base "$t" "$s")" \
    || { echo "error: PR #$pr: no merge base of $t and $s" >&2; return 3; }
  # Input guard: the paths both sides changed since the merge base.
  dt="$(git -C "$clone" diff --no-renames --name-only "$mb" "$t")" \
    && ds="$(git -C "$clone" diff --no-renames --name-only "$mb" "$s")" \
    || { echo "error: PR #$pr: cannot diff against the merge base $mb" >&2; return 3; }
  # comm must collate like the sort that fed it, or it silently misses common lines.
  both="$(LC_ALL=C comm -12 <(printf '%s\n' "$dt" | LC_ALL=C sort) <(printf '%s\n' "$ds" | LC_ALL=C sort) \
    | grep -v '^$' || true)"
  printf '%s\n' "$both" | team_lm_union_guard "$clone" "$pr" "$line" "$t" || return 3
  # -z output: `<tree>NUL NUL`, then per message `<n>NUL<path>…NUL<type>NUL<message>NUL`; NULs become
  # newlines and newlines (inside messages) \002, so each field is one line.
  out="$(set -o pipefail
         LC_ALL=C git -C "$clone" --attr-source "$t" merge-tree --write-tree --messages -z "$t" "$s" \
           2>/dev/null | LC_ALL=C tr '\n\0' '\002\n')" || mrc=$?
  case "$mrc" in
    0) ;;
    1) echo "error: PR #$pr conflicts with $line on the current base ($t) — resolve it on the PR" >&2
       return 3 ;;
    *) echo "error: PR #$pr: git merge-tree failed (exit $mrc)" >&2; return 3 ;;
  esac
  tree="$(printf '%s\n' "$out" | sed -n 1p)"
  # The stable `Auto-merging` type names every content-merged path by its RESULT name.
  printf '%s\n' "$out" | LC_ALL=C awk 'NR <= 2 { next }
      st == 0 { n = $0 + 0; st = 1; k = 0; p = ""; next }
      st == 1 && k < n { p = p $0 "\n"; k++; next }
      st == 1 { ty = $0; st = 2; next }
      st == 2 { if (ty == "Auto-merging") printf "%s", p; st = 0 }' \
    | team_lm_union_guard "$clone" "$pr" "$line" "$t" || return 3
  have="$(git -C "$clone" rev-parse -q --verify "$ref^{commit}" 2>/dev/null || true)"
  if [ -n "$have" ] \
    && [ "$(git -C "$clone" rev-list --parents -n 1 "$have" 2>/dev/null)" = "$have $t $s" ] \
    && [ "$(git -C "$clone" rev-parse -q --verify "$have^{tree}" 2>/dev/null)" = "$tree" ]; then
    printf '%s\n' "$have"; return 0
  fi
  m="$(git -C "$clone" commit-tree "$tree" -p "$t" -p "$s" -m "Merge pull request #$pr from $branch")" \
    || { echo "error: PR #$pr: cannot create the local merge commit" >&2; return 3; }
  git -C "$clone" update-ref "$ref" "$m" \
    || { echo "error: PR #$pr: cannot store $ref" >&2; return 3; }
  printf '%s\n' "$m"
}

# Usage: team_merge_commit_now <clone> <pr> <line> <branch>
#   rc 0 · 3 refusal (conflict, incomplete readiness, local merge refused) · 4 recomputing
#   The commit the integrator would push right now, from `team-pr.sh readiness`: GitHub's under
#   `refs/team-pr/<pr>/merge` in the clone, or, when that ref is stale, the local merge under
#   `refs/team-pr/<pr>/local-merge`. Resets, then sets IE_SRC / IE_TGT / IE_MERGE / IE_MERGE_REF.
team_merge_commit_now() {
  local clone="$1" pr="$2" line="$3" branch="$4" out rc=0 merge
  IE_SRC=""; IE_TGT=""; IE_MERGE=""; IE_MERGE_REF=""
  out="$( cd "$clone" && bash .claude/lib/team-pr.sh readiness "$pr" )" || rc=$?
  # A refusal before any ref is read (fork, closed PR) prints to stderr only — no JSON to parse.
  merge=unknown
  [ -z "$out" ] || merge="$(jq -r '.merge // "unknown"' <<<"$out" 2>/dev/null || echo unknown)"
  # readiness reports `conflict` only with a non-zero exit.
  [ "$merge" != conflict ] \
    || { echo "error: PR #$pr conflicts with $line — resolve it on the PR" >&2; return 3; }
  if [ "$rc" != 0 ] && [ "$(jq -r '.reason // ""' <<<"$out" 2>/dev/null)" != stale-base ]; then
    echo "error: PR #$pr merge ref is $merge — GitHub is still recomputing, rerun later" >&2
    return 4
  fi
  IE_TGT="$(jq -r '.target_sha // ""' <<<"$out")"
  IE_SRC="$(jq -r '.source_sha // ""' <<<"$out")"
  [ -n "$IE_SRC" ] && [ -n "$IE_TGT" ] \
    || { echo "error: readiness of PR #$pr is incomplete: $out" >&2; return 3; }
  if [ "$rc" = 0 ]; then
    IE_MERGE="$(jq -r '.merge_sha // ""' <<<"$out")"; IE_MERGE_REF="refs/team-pr/$pr/merge"
    [ -n "$IE_MERGE" ] || { echo "error: readiness of PR #$pr is incomplete: $out" >&2; return 3; }
  else
    IE_MERGE="$(team_local_merge "$clone" "$pr" "$line" "$branch" "$IE_TGT" "$IE_SRC")" || return 3
    IE_MERGE_REF="refs/team-pr/$pr/local-merge"
    echo "PR #$pr merge ref is stale (built on $(jq -r .merge_base_sha <<<"$out"), $line is at" \
      "$IE_TGT) — testing the local merge $IE_MERGE instead" >&2
  fi
}

# Usage: team_integration_eligible <team> <clone> <run> <mode> <pr>
#   rc 0 eligible · 3 refusal · 4 recoverable (GitHub still recomputing the merge ref)
#   sets IE_SRC / IE_TGT / IE_MERGE from `team-pr.sh readiness`, and IE_MERGE_REF to the clone ref
#   carrying IE_MERGE. A merge ref GitHub has not rebuilt since the line moved (`stale-base`) is not
#   waited out: M = merge(T, S) is built locally (team_local_merge) and that is what gets tested.
#
# Run TWICE on the same run: by merge-check before the gates, and by integrate immediately before
# the push, under the integration lock. The second call is what makes the gate verdict mean
# anything — between the two, a role could have restarted, the clone could have gone dirty, or
# GitHub could have rebuilt the merge ref.
IE_SRC=""; IE_TGT=""; IE_MERGE=""; IE_MERGE_REF=""
team_integration_eligible() {  # <team> <clone> <run> <mode> <pr>
  local team="$1" clone="$2" run="$3" mode="$4" pr="$5"
  local td="$clone/.agents/team" rd branch line role rec out
  IE_SRC=""; IE_TGT=""; IE_MERGE=""; IE_MERGE_REF=""
  ie_no() { echo "error: $1" >&2; return 3; }
  [ -n "$run" ] || { ie_no "no run id for team $team — nothing to integrate"; return 3; }
  rd="$td/runs/$(team_ie_run_ref "$td" "$run")"
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
  local m; m="$(sh_main_root 2>/dev/null)" || m=""
  if [ -n "$m" ]; then
    for role in ${TEAM_ROLES:-planner coder qa wrapup} cli; do
      ! sh_alive_addr "$m" "$team-$role" 2>/dev/null \
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

  # (5) readiness: the tested merge commit.
  team_merge_commit_now "$clone" "$pr" "$line" "$branch" || return $?
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
