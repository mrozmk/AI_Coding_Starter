#!/usr/bin/env bash
# The team PR path for `pr_provider=azure-devops`: create and publish only. Reached through
# team-pr.sh (which keeps the github path); state, identity and validation stay on the team-lib.sh
# helpers (team_ado_coords, team_pr_json, team_pr_identity) the runner uses, byte for byte.
#
# Usage: bash .claude/lib/team-pr.sh create --draft|--ready --head <b> --base <b> --title <t>
#          --body-file <f>                                                     → pr=<n>
#        bash .claude/lib/team-pr.sh publish <pr>                              → pr=<n>
#
# create is idempotent like the github path: the active PRs of the head branch are looked up before
# the create and again after it, and the answer of `az repos pr create` itself is never trusted — a
# create that succeeded and lost its answer must not lead to a second PR. A found PR is settled:
# --draft never reverts a published PR (exit 3), --ready publishes a found draft. An active PR of
# the head branch that targets another line, or two of them, is refused (exit 3). The body is the
# PR description: at most 4000 characters (Azure DevOps' cap) and no `NAME=value` line for a
# key, token, secret or password.
#
# Exit codes: 0 ok · 2 usage/profile/body · 3 refusal (published, ambiguous, other target) ·
#   4 recoverable (az failed, no PR after the create). Bash 3.2 compatible (macOS /bin/bash).
set -euo pipefail

LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$LIB/team-profile.sh"
team_profile_load "$(git rev-parse --show-toplevel)"
. "$LIB/team-lib.sh"

die() { echo "error: $2" >&2; exit "$1"; }
[ "$TEAM_PR_PROVIDER" = azure-devops ] || die 2 "team-pr-ado.sh is for pr_provider=azure-devops"
team_ado_coords 2>/dev/null || die 2 "cannot resolve the Azure DevOps org/project/repo from origin"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
# Every `az` call goes through here, so the stub-vs-real surface is one line.
azc() { az "$@"; }
norm_pr() { [[ "${1:-}" =~ ^[0-9]+$ ]] || die 2 "pr number '${1:-}' must be a number"; }

# ado_find_open <head> <base> → FOUND / FOUND_DRAFT (empty when none). Only this repo's PRs of
# exactly this source branch count; one that targets another line is refused, never returned.
FOUND=""; FOUND_DRAFT=""
ado_find_open() {
  local c other
  azc repos pr list --org "$ADO_ORG_URL" --project "$ADO_PROJECT" --repository "$ADO_REPO" \
    --source-branch "$1" --status active -o json > "$TMP/list.json" 2>"$TMP/err" \
    || { sed 's/^/  | /' "$TMP/err" >&2; die 4 "az repos pr list for $1 failed — recoverable"; }
  jq -c --arg r "$ADO_REPO" --arg h "refs/heads/$1" \
    '[.[] | select(.repository.name == $r and .sourceRefName == $h and .status == "active")]' \
    "$TMP/list.json" > "$TMP/cand.json" || die 4 "the PR list for $1 is not parseable"
  other="$(jq -r --arg b "refs/heads/$2" '[.[] | select(.targetRefName != $b)
    | "#\(.pullRequestId) → \(.targetRefName)"] | join(", ")' "$TMP/cand.json")"
  [ -z "$other" ] || die 3 "an active PR of $1 targets another line: $other — not $2"
  c="$(jq -r 'length' "$TMP/cand.json")"
  [ "$c" -le 1 ] || die 3 "ambiguous: $(jq -r '[.[].pullRequestId | tostring] | join(",")' \
    "$TMP/cand.json") active for $1 → $2"
  FOUND="$(jq -r '.[0].pullRequestId // "" | tostring' "$TMP/cand.json")"
  FOUND_DRAFT="$(jq -r 'if (.[0] | type) != "object" then "" else (.[0].isDraft | tostring) end' \
    "$TMP/cand.json")"
}

# ado_publish <pr> — idempotent: `--draft false` on a published PR changes nothing; the re-read
# is the truth.
ado_publish() {
  azc repos pr update --org "$ADO_ORG_URL" --id "$1" --draft false -o json > /dev/null 2>"$TMP/err" \
    || true
  [ "$(team_pr_json "$1" 2>/dev/null | jq -r '.isDraft' 2>/dev/null)" = false ] \
    || { sed 's/^/  | /' "$TMP/err" >&2; die 4 "PR #$1 is still a draft after the update — recoverable"; }
}

settle_found() {  # settle_found draft|ready
  case "$1/$FOUND_DRAFT" in
    draft/true|ready/false) echo "pr=$FOUND" ;;
    draft/false) die 3 "PR #$FOUND is already published — not reverting" ;;
    ready/true)  ado_publish "$FOUND"; echo "pr=$FOUND" ;;
    *) die 4 "az repos pr list gave no draft flag for PR #$FOUND" ;;
  esac
}

# The description the reviewers read: within the cap, and never a secret value.
check_body() {
  local n
  [ -r "$1" ] || die 2 "--body-file '$1' is not readable"
  n="$(LC_ALL=en_US.UTF-8 wc -m < "$1" | tr -d ' ')"
  [ "$n" -le 4000 ] || die 2 "the PR body has $n characters — Azure DevOps keeps 4000; trim prose, never the checklist"
  ! grep -Eiq '^[[:space:]]*[A-Za-z0-9_]*(KEY|TOKEN|SECRET|PASSWORD|PASSWD)[A-Za-z0-9_]*[[:space:]]*[=:][[:space:]]*[^[:space:]]' "$1" \
    || die 2 "the PR body carries a secret-like NAME=value line — remove it"
}

op_create() {  # op_create draft|ready <head> <base> <title> <body file>
  local mode="$1" head="$2" base="$3" title="$4" bf="$5" args
  check_body "$bf"
  ado_find_open "$head" "$base"
  if [ -n "$FOUND" ]; then settle_found "$mode"; return 0; fi
  args=(repos pr create --org "$ADO_ORG_URL" --project "$ADO_PROJECT" --repository "$ADO_REPO"
    --source-branch "$head" --target-branch "$base" --title "$title" --description "@$bf" -o json)
  [ "$mode" != draft ] || args+=(--draft true)
  # Deliberately ignored: the truth is the list after it.
  azc "${args[@]}" > "$TMP/created" 2>&1 || true
  ado_find_open "$head" "$base"
  [ -n "$FOUND" ] || { sed 's/^/  | /' "$TMP/created" >&2
    die 4 "az repos pr create left no active PR for $head → $base — recoverable"; }
  settle_found "$mode"
}

op="${1:-}"; [ $# -eq 0 ] || shift
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
    norm_pr "$1"; ado_publish "$1"; echo "pr=$1" ;;
  *) die 2 "usage: team-pr.sh create|publish … (azure-devops)" ;;
esac
