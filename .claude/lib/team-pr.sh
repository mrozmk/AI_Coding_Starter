#!/usr/bin/env bash
# The PR provider layer for `pr_provider=github` — the ONLY place the harness calls `gh pr`.
#
# Usage: bash .claude/lib/team-pr.sh <op> …
#   coords                                   → owner/repo (origin must match teams.github.repo)
#   state <pr>                               → lifecycle JSON (also for closed/merged PRs)
#   identity <pr> <source branch> <target branch>
#   readiness <pr>                           → {merge, target_sha, merge_sha, source_sha, parents_ok}
#   create --draft|--ready --head <b> --base <b> --title <t> --body-file <f>   → pr=<n>
#   publish <pr> · body-get <pr> · body-set <pr> <file>
#
# `readiness` is deliberately separate from `state`: a merged or closed PR has no merge ref and
# often no source branch, and that must still read as a valid lifecycle. `merge=ok` requires the
# synthetic `refs/pull/<n>/merge` commit to have EXACTLY TWO parents and exactly the ones we
# validated — parent 1 the current target tip, parent 2 the PR head — so the caller can push a
# tested merge commit.
#
# CONTRACT for the integrator: on `merge=ok` that commit is in the local repo under
# `refs/team-pr/<pr>/merge` (NOT FETCH_HEAD, which any concurrent fetch rewrites). Push the
# `merge_sha` this prints, and resolve it through that ref.
#
# ADO is NOT handled here: `team_ado_coords`/`team_pr_json`/`team_pr_identity` in team-lib.sh keep
# that path byte-for-byte. Callers branch on `$TEAM_PR_PROVIDER`.
#
# This file never merges and never forces: no `gh pr merge`, no `--admin`, no `--force`, no writing
# `gh api`. The smoke suite greps for those.
#
# Exit codes: 0 ok · 2 usage/profile/provider · 3 refusal (identity, fork, conflict, ambiguous,
#   published) · 4 recoverable (network, missing merge ref, GitHub still recomputing).
# Bash 3.2 compatible (macOS /bin/bash).
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/team-profile.sh"
root="$(git rev-parse --show-toplevel)"
team_profile_load "$root"

die() { echo "error: $2" >&2; exit "$1"; }

[ "$TEAM_PR_PROVIDER" = github ] \
  || die 2 "azure-devops uses the team-lib.sh helpers (team-pr.sh is github-only)"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Every `gh` call goes through here, so the stub-vs-real surface is one line.
ghc() { gh "$@"; }

norm_pr() { [[ "${1:-}" =~ ^[0-9]+$ ]] || die 2 "pr number '${1:-}' must be a number"; }

# ---- coords -------------------------------------------------------------------------------------

# A global, not stdout: `$(op_coords)` would run the refusal in a subshell and the caller would
# sail on with an empty repo. The URL parsing itself lives in team-profile.sh, so `coords` and the
# pre-clone `team_profile_require_supported` check can never drift apart.
GH_OR=""
op_coords() {
  team_gh_origin_require
  GH_OR="$TEAM_GH_ORIGIN"
}

# ---- state --------------------------------------------------------------------------------------

pr_view() {  # pr_view <pr> <json fields> [jq expr] → $TMP/pr.json (or stdout when <jq expr> given)
  local n="$1" fields="$2"
  if [ -n "${3:-}" ]; then
    ghc pr view "$n" --repo "$TEAM_GH_REPO" --json "$fields" -q "$3" > "$TMP/pr.out" 2>"$TMP/err" \
      || { sed 's/^/  | /' "$TMP/err" >&2; die 4 "gh pr view #$n failed — recoverable"; }
    cat "$TMP/pr.out"
  else
    ghc pr view "$n" --repo "$TEAM_GH_REPO" --json "$fields" > "$TMP/pr.json" 2>"$TMP/err" \
      || { sed 's/^/  | /' "$TMP/err" >&2; die 4 "gh pr view #$n failed — recoverable"; }
  fi
}

# Lifecycle only. No `ls-remote`, no merge ref: a closed PR whose branch is gone still answers.
state_json() {  # state_json <pr> → $TMP/state.json
  pr_view "$1" \
    number,state,isDraft,headRefName,baseRefName,headRefOid,headRepository,headRepositoryOwner
  jq -c '{id: .number,
          status: (if .state == "OPEN" then "active"
                   elif .state == "MERGED" then "completed"
                   elif .state == "CLOSED" then "abandoned"
                   else "unknown" end),
          draft: (.isDraft // false),
          repo: ((.headRepositoryOwner.login // "") + "/" + (.headRepository.name // "")),
          source_ref: ("refs/heads/" + (.headRefName // "")),
          target_ref: ("refs/heads/" + (.baseRefName // "")),
          source_sha: (.headRefOid // "")}' "$TMP/pr.json" > "$TMP/state.json" \
    || die 4 "the state of PR #$1 is not parseable"
}

# The fork check comes FIRST and on its own exit text: a PR from `evil/widgets` with the right
# branch names would otherwise read as a plain ref mismatch and get retried.
refuse_fork_or_inactive() {  # refuse_fork_or_inactive <pr>
  local r
  r="$(jq -r '.repo' "$TMP/state.json")"
  [ "$r" = "$TEAM_GH_REPO" ] || die 3 "PR #$1 is from a fork ($r)"
  [ "$(jq -r '.status' "$TMP/state.json")" = active ] || die 3 "PR #$1 identity mismatch"
}

# ---- readiness ----------------------------------------------------------------------------------

ls_remote() {  # ls_remote <ref> → the sha, empty when the ref is absent
  local out
  out="$(git ls-remote origin "$1" 2>"$TMP/err")" \
    || { sed 's/^/  | /' "$TMP/err" >&2; die 4 "git ls-remote origin '$1' failed — recoverable"; }
  printf '%s' "$out" | awk 'NR == 1 { print $1 }'
}

# Printed on EVERY outcome, including the refusals: the caller logs what it saw.
# `reason` is diagnostic only — callers branch on `merge` and the exit code. `stale-base`: the merge
# ref we read and fetched is one commit, on the right head, but its parent 1 (`merge_base_sha`) is
# not the target tip — GitHub has not rebuilt it since the target moved.
emit_readiness() {  # emit_readiness <merge> <target_sha> <merge_sha> <source_sha> <parents_ok> <reason> [<p1>]
  jq -nc --arg m "$1" --arg t "$2" --arg g "$3" --arg s "$4" --argjson p "$5" --arg r "$6" \
    --arg b "${7:-}" \
    '{merge: $m, target_sha: $t, merge_sha: $g, source_sha: $s, parents_ok: $p, reason: $r,
      merge_base_sha: $b}'
}

op_readiness() {  # op_readiness <pr>
  local n="$1" src base mergeable target_sha merge_sha fh parents np p1 p2
  TEAM_PR_MERGE_REF="refs/team-pr/$n/merge"
  state_json "$n"
  refuse_fork_or_inactive "$n"
  src="$(jq -r '.source_sha' "$TMP/state.json")"
  base="$(jq -r '.target_ref | sub("^refs/heads/"; "")' "$TMP/state.json")"
  mergeable="$(pr_view "$n" mergeable '.mergeable')"
  target_sha="$(ls_remote "refs/heads/$base")"
  merge_sha="$(ls_remote "refs/pull/$n/merge")"

  if [ "$mergeable" = CONFLICTING ]; then
    emit_readiness conflict "$target_sha" "$merge_sha" "$src" false conflict
    exit 3
  fi
  # Anything that is not a plain MERGEABLE (UNKNOWN included) means GitHub is still recomputing.
  if [ "$mergeable" != MERGEABLE ] || [ -z "$merge_sha" ] || [ -z "$target_sha" ]; then
    emit_readiness pending "$target_sha" "$merge_sha" "$src" false recomputing
    exit 4
  fi
  # Fetched into a ref WE own, not FETCH_HEAD: FETCH_HEAD is global, any concurrent fetch in this
  # repo (another op, the runner, a hook) rewrites it between two reads. `+` on the refspec, not
  # `--force`: a recomputed merge M2(T2,S) is no descendant of M1, and this only moves a local ref.
  if ! git fetch --quiet origin "+refs/pull/$n/merge:$TEAM_PR_MERGE_REF" 2>"$TMP/err"; then
    sed 's/^/  | /' "$TMP/err" >&2
    emit_readiness pending "$target_sha" "$merge_sha" "$src" false fetch-failed
    exit 4
  fi
  # Resolved ONCE. Everything below is checked against this one sha, so nothing we verify can be
  # swapped underneath us between two `rev-parse` calls.
  fh="$(git rev-parse -q --verify "$TEAM_PR_MERGE_REF" || true)"
  # The FULL parent list, not `^1`/`^2`: an octopus M(T,S,X) answers both of those correctly while
  # carrying a third parent whose code never went through the gates.
  parents="$(git rev-list --parents -n 1 "$fh" 2>/dev/null || true)"
  np="$(printf '%s\n' "$parents" | awk 'NR == 1 { print NF - 1 }')"
  p1="$(printf '%s\n' "$parents" | awk 'NR == 1 { print $2 }')"
  p2="$(printf '%s\n' "$parents" | awk 'NR == 1 { print $3 }')"
  if [ -n "$fh" ] && [ "$np" = 2 ] && [ "$fh" = "$merge_sha" ] && [ "$p2" = "$src" ]; then
    if [ "$p1" = "$target_sha" ]; then
      emit_readiness ok "$target_sha" "$merge_sha" "$src" true ""
      return 0
    fi
    # The fetched commit IS the one ls-remote named (a ref rebuilt between the two reads is GitHub
    # catching up), on the right head — only its base is old.
    emit_readiness pending "$target_sha" "$merge_sha" "$src" false stale-base "$p1"
    exit 4
  fi
  emit_readiness pending "$target_sha" "$merge_sha" "$src" false parents
  exit 4
}

# ---- create / publish / body ---------------------------------------------------------------------

# `gh pr list --head` filters by BRANCH NAME, so a fork's PR with the same branch name comes back
# too. Publishing or returning that one would act on somebody else's branch — filter by repo and by
# both exact refs, and refuse rather than pick when more than one of OUR PRs matches.
FOUND=""; FOUND_DRAFT=""
find_open() {  # find_open <head> <base>
  ghc pr list --repo "$TEAM_GH_REPO" --head "$1" --base "$2" --state open \
    --json number,isDraft,headRefName,baseRefName,headRepositoryOwner,headRepository --limit 10 \
    > "$TMP/list.json" 2>"$TMP/err" \
    || { sed 's/^/  | /' "$TMP/err" >&2; die 4 "gh pr list for $1 failed — recoverable"; }
  jq -c --arg r "$TEAM_GH_REPO" --arg h "$1" --arg b "$2" \
    '[.[] | select(((.headRepositoryOwner.login // "") + "/" + (.headRepository.name // "")) == $r
       and .headRefName == $h and .baseRefName == $b)]' "$TMP/list.json" > "$TMP/cand.json" \
    || die 4 "the PR list for $1 is not parseable"
  local c
  c="$(jq -r 'length' "$TMP/cand.json")"
  [ "$c" -le 1 ] || die 3 "ambiguous: $(jq -r '[.[].number | tostring] | join(",")' \
    "$TMP/cand.json") open for $1 → $2"
  FOUND="$(jq -r '.[0].number // ""' "$TMP/cand.json")"
  # `// ""` would swallow a legitimate `false` — jq treats it as an empty alternative, and an
  # already-published PR would then read as "no draft flag" instead of "do not revert it".
  FOUND_DRAFT="$(jq -r 'if (.[0] | type) != "object" then "" else (.[0].isDraft | tostring) end' \
    "$TMP/cand.json")"
}

gh_publish() {  # gh_publish <pr> — idempotent: an already-published PR makes `gh pr ready` fail
  if ghc pr ready "$1" --repo "$TEAM_GH_REPO" >/dev/null 2>"$TMP/err"; then return 0; fi
  state_json "$1"
  [ "$(jq -r '.draft' "$TMP/state.json")" = false ] \
    || { sed 's/^/  | /' "$TMP/err" >&2; die 4 "gh pr ready #$1 failed — recoverable"; }
}

# The state rules of Amendment 7, applied to WHATEVER the list found — the PR we already had, or
# the one that turned up after our create. The post-create path must not skip them: `gh pr create`
# can lose its answer while a concurrent writer published (or drafted) that pair, and returning
# `pr=<n>` then would hand back a PR in the opposite state to the one that was asked for.
settle_found() {  # settle_found draft|ready
  case "$1/$FOUND_DRAFT" in
    draft/true|ready/false) echo "pr=$FOUND" ;;
    draft/false) die 3 "PR #$FOUND is already published — not reverting" ;;
    ready/true)  gh_publish "$FOUND"; echo "pr=$FOUND" ;;
    *) die 4 "gh pr list gave no draft flag for PR #$FOUND" ;;
  esac
}

op_create() {  # op_create draft|ready <head> <base> <title> <body file>
  local mode="$1" head="$2" base="$3" title="$4" bf="$5"
  [ -r "$bf" ] || die 2 "--body-file '$bf' is not readable"
  find_open "$head" "$base"
  if [ -n "$FOUND" ]; then settle_found "$mode"; return 0; fi
  local args
  args=(pr create --repo "$TEAM_GH_REPO" --base "$base" --head "$head" --title "$title"
    --body-file "$bf")
  [ "$mode" != draft ] || args+=(--draft)
  # The outcome of `gh pr create` is deliberately ignored: a create that succeeded and then lost
  # its answer (timeout, crash) must not produce a SECOND PR on the retry. The truth is the list.
  ghc "${args[@]}" > "$TMP/created" 2>&1 || true
  find_open "$head" "$base"
  [ -n "$FOUND" ] || { sed 's/^/  | /' "$TMP/created" >&2
    die 4 "gh pr create left no open PR for $head → $base — recoverable"; }
  settle_found "$mode"
}

# ---- dispatch -----------------------------------------------------------------------------------

op="${1:-}"; [ $# -eq 0 ] || shift
case "$op" in
  coords|state|identity|readiness|create|publish|body-get|body-set) ;;
  *) die 2 "usage: team-pr.sh coords|state|identity|readiness|create|publish|body-get|body-set …" ;;
esac

# Nothing talks to GitHub before origin is confirmed to be the profile's repo.
op_coords

MODE=""; HEAD=""; BASE=""; TITLE=""; BODY_FILE=""; POS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --draft)     MODE=draft; shift ;;
    --ready)     MODE=ready; shift ;;
    --head)      HEAD="${2:-}"; shift 2 || die 2 "--head needs a branch" ;;
    --base)      BASE="${2:-}"; shift 2 || die 2 "--base needs a branch" ;;
    --title)     TITLE="${2:-}"; shift 2 || die 2 "--title needs a value" ;;
    --body-file) BODY_FILE="${2:-}"; shift 2 || die 2 "--body-file needs a path" ;;
    -*)          die 2 "unknown option '$1'" ;;
    *)           POS+=("$1"); shift ;;
  esac
done
set -- ${POS[@]+"${POS[@]}"}

case "$op" in
  coords)
    [ $# -eq 0 ] || die 2 "coords takes no arguments"
    printf '%s\n' "$GH_OR" ;;
  state)
    [ $# -eq 1 ] || die 2 "usage: state <pr>"
    norm_pr "$1"; state_json "$1"; cat "$TMP/state.json" ;;
  identity)
    [ $# -eq 3 ] || die 2 "usage: identity <pr> <source branch> <target branch>"
    norm_pr "$1"
    state_json "$1"
    refuse_fork_or_inactive "$1"
    jq -e --arg s "refs/heads/$2" --arg t "refs/heads/$3" \
      '.source_ref == $s and .target_ref == $t' "$TMP/state.json" >/dev/null \
      || die 3 "PR #$1 identity mismatch" ;;
  readiness)
    [ $# -eq 1 ] || die 2 "usage: readiness <pr>"
    norm_pr "$1"; op_readiness "$1" ;;
  create)
    [ $# -eq 0 ] || die 2 "create takes no positional arguments"
    [ -n "$MODE" ] || die 2 "create needs --draft or --ready"
    [ -n "$HEAD" ] || die 2 "create needs --head <branch>"
    [ -n "$BASE" ] || die 2 "create needs --base <branch>"
    [ -n "$TITLE" ] || die 2 "create needs --title <t>"
    [ -n "$BODY_FILE" ] || die 2 "create needs --body-file <f>"
    op_create "$MODE" "$HEAD" "$BASE" "$TITLE" "$BODY_FILE" ;;
  publish)
    [ $# -eq 1 ] || die 2 "usage: publish <pr>"
    norm_pr "$1"; gh_publish "$1"; echo "pr=$1" ;;
  body-get)
    [ $# -eq 1 ] || die 2 "usage: body-get <pr>"
    norm_pr "$1"; pr_view "$1" body '.body' ;;
  body-set)
    [ $# -eq 2 ] || die 2 "usage: body-set <pr> <file>"
    norm_pr "$1"
    [ -r "$2" ] || die 2 "body file '$2' is not readable"
    ghc pr edit "$1" --repo "$TEAM_GH_REPO" --body-file "$2" > "$TMP/edit" 2>"$TMP/err" \
      || { sed 's/^/  | /' "$TMP/err" >&2; die 4 "gh pr edit #$1 failed — recoverable"; } ;;
esac
