#!/usr/bin/env bash
# The tracker adapter — the ONLY place the team harness calls `gh`.
#
# Usage: bash .claude/lib/team-tracker.sh <op> …
#   read <key> --out <dir>                                  (tracker=github)
#   read --brief <text>|--brief-file <path> --out <dir>      (tracker=none)
#   comment <key> --marker <m> --body-file <f>
#   set-status <key> started|delivered
#   create-followup --marker <m> --title <t> --body-file <f>
#
# Writes are idempotent by MARKER: the marker must be the body's last line, and a match is found by
# enumerating EVERYTHING (paginate / totalCount) — a failed or partial enumeration is exit 4, never
# the conclusion "not there" (which would double-post).
#
# Exit codes: 0 ok · 1 ticket unusable (closed, missing, bad input) · 2 usage/profile ·
#   3 tracker=jira (the session's MCP owns it) · 4 recoverable (permissions, no project item,
#   unknown logical, failed/incomplete enumeration, an AMBIGUOUS match — more than one marker hit
#   or more than one project item for repo+number — which is never resolved by picking the first).
# Bash 3.2 compatible (macOS /bin/bash).
set -euo pipefail

. "$(dirname "$0")/team-profile.sh"
root="$(git rev-parse --show-toplevel)"
team_profile_load "$root"

TMP="$(mktemp -d)"
LOCK=""
# `rm -rf`, not `rmdir`: the lock dir holds a `pid` file, like team_q_lock's.
cleanup() { [ -z "$LOCK" ] || rm -rf "$LOCK"; rm -rf "$TMP"; }
trap cleanup EXIT

die() { echo "error: $2" >&2; exit "$1"; }
gh_or4() { "$@" || { echo "error: gh $* failed — recoverable" >&2; exit 4; }; }

# A global, not stdout: `$(norm_key …)` would run the refusal in a subshell.
KEY=""
norm_key() {  # norm_key <key> — `#4` and `4` both normalize to `4`
  KEY="${1#\#}"
  [[ "$KEY" =~ $TEAM_KEY_REGEX ]] || die 1 "ticket key '$1' must match $TEAM_KEY_REGEX"
}

# Usage: marker_is_last_line <file> <marker> → the normalized marker in $MARKER_N.
# Validation and lookup MUST normalize identically, or a CRLF body validates here and then misses in
# the search — which posts a second comment. `\r` stripped on both sides (the jq filter does
# `gsub("\r"; "")`), trailing newline dropped by the command substitution.
MARKER_N=""
marker_is_last_line() {
  [ -r "$1" ] || die 2 "body file '$1' is not readable"
  MARKER_N="$(printf '%s' "$2" | tr -d '\r')"
  [ -n "$MARKER_N" ] || die 2 "the marker is empty"
  [ "$(tail -n 1 "$1" | tr -d '\r')" = "$MARKER_N" ] \
    || die 2 "the marker must be the last line of '$1'"
}

# Usage: write_ticket <dir> <ticket.json source> — ticket.json + ticket.md, and the stdout contract.
write_ticket() {
  local dir="$1" src="$2"
  mkdir -p "$dir" || die 2 "cannot create --out dir '$dir'"
  cp "$src" "$dir/ticket.json"
  jq -r '"# " + .title, "URL: " + .url, "Labels: " + (.labels | join(", ")), "", .body' \
    "$dir/ticket.json" > "$dir/ticket.md"
  jq -r '"key=" + .key + " type=" + .type, "title=" + .title' "$dir/ticket.json"
}

op_read_github() {
  local dir="$1" type
  gh issue view "$KEY" --repo "$TEAM_GH_REPO" \
    --json number,title,labels,body,url,state > "$TMP/issue.json" 2>"$TMP/err" \
    || { sed 's/^/  | /' "$TMP/err" >&2; die 1 "issue #$KEY cannot be read"; }
  local state; state="$(jq -r '.state // empty' "$TMP/issue.json")"
  [ "$state" = OPEN ] || die 1 "issue #$KEY is $state"
  # First matching RULE wins (not the first label): bug → bugfix, then the chore labels.
  type="$(jq -r '[.labels[]?.name] as $l
    | if ($l | index("bug")) then "bugfix"
      elif ($l | map(. == "harness" or . == "infra" or . == "documentation") | any) then "chore"
      else "feature" end' "$TMP/issue.json")"
  jq --arg key "$KEY" --arg type "$type" \
    '{key: $key, title: (.title // ""), type: $type, labels: [.labels[]?.name],
      body: (.body // ""), url: (.url // "")}' "$TMP/issue.json" > "$TMP/ticket.json"
  write_ticket "$dir" "$TMP/ticket.json"
}

# The one owner of `none` key allocation: the counter lives in the supervisor's checkout.
alloc_local_id() {
  local d="$root/.agents/team" f lock tries=0 max last n
  mkdir -p "$d" || die 2 "cannot create $d"
  f="$d/local-ids"; lock="$f.lock"
  max=$(( ${TEAM_ID_LOCK_SECS:-30} * 5 ))
  until mkdir "$lock" 2>/dev/null; do
    [ "$tries" -lt "$max" ] || die 4 "local-ids busy (lock held by pid $(cat "$lock/pid" \
      2>/dev/null || echo none))"
    sleep 0.2; tries=$((tries + 1))
  done
  LOCK="$lock"; echo $$ > "$lock/pid"
  # Only a MISSING counter is 0. An unreadable or non-numeric one would silently restart at L1 and
  # hand out an ID that is already in use — refuse instead, before anything is allocated.
  if [ -e "$f" ]; then
    [ -r "$f" ] || die 2 "$f is not readable"
    last="$(cat "$f")" || die 2 "$f cannot be read"
    [[ "$last" =~ ^[0-9]+$ ]] || die 2 "$f holds '$last', not a number — fix it by hand"
  else
    last=0
  fi
  n=$((last + 1))
  # temp file + mv: a crash mid-write must not leave a truncated counter behind.
  printf '%s\n' "$n" > "$f.new" || die 2 "cannot write $f"
  mv "$f.new" "$f" || die 2 "cannot write $f"
  rm -rf "$lock"; LOCK=""
  KEY="L$n"
}

op_read_none() {
  local dir="$1" brief="$2" title
  # awk, not `… | head -n 1`: head closes the pipe on a long brief and pipefail turns the SIGPIPE
  # into rc 141. This consumes every line and prints the first usable one at END.
  title="$(printf '%s\n' "$brief" | awk '
    t == "" { s = $0; sub(/^[[:space:]#]*/, "", s); if (s ~ /[^[:space:]]/) t = s }
    END { print t }')"
  [ -n "$title" ] || die 1 "the brief has no usable title line"
  alloc_local_id
  jq -n --arg key "$KEY" --arg title "$title" --arg body "$brief" \
    '{key: $key, title: $title, type: "feature", labels: [], body: $body, url: ""}' \
    > "$TMP/ticket.json"
  write_ticket "$dir" "$TMP/ticket.json"
}

op_comment() {
  local marker="$1" file="$2" id hits
  marker_is_last_line "$file" "$marker"
  # `--paginate` into a FILE, not a pipe: on a later-page error gh prints page 1 and exits non-zero,
  # and `local x=$(…)` would swallow that status even under pipefail.
  gh_or4 gh api "repos/$TEAM_GH_REPO/issues/$KEY/comments" --paginate > "$TMP/raw.json"
  jq -s 'add // []' "$TMP/raw.json" > "$TMP/all.json" \
    || die 4 "comment list of issue #$KEY is not parseable"
  jq --arg m "$MARKER_N" \
    'map(select((.body // "") | gsub("\r"; "") | rtrimstr("\n") | split("\n") | last == $m))' \
    "$TMP/all.json" > "$TMP/hits.json" || die 4 "comment list of issue #$KEY is not parseable"
  # 0 → create · 1 → exists · >1 → recoverable. Picking `.[0]` of an ambiguous match would call one
  # arbitrary duplicate "the" comment and let the intent go `done` over an unresolved mess.
  hits="$(jq -r 'length' "$TMP/hits.json")"
  [ "$hits" -le 1 ] \
    || die 4 "marker '$MARKER_N' matches $hits comments of issue #$KEY — refusing to choose one"
  id="$(jq -r '.[0].id // ""' "$TMP/hits.json")"
  if [ -n "$id" ]; then echo "exists $id"; return 0; fi
  jq -n --rawfile b "$file" '{body: $b}' > "$TMP/post.json"
  gh_or4 gh api -X POST "repos/$TEAM_GH_REPO/issues/$KEY/comments" \
    --input "$TMP/post.json" > "$TMP/resp.json"
  echo "created $(jq -r '.id // ""' "$TMP/resp.json")"
}

op_set_status() {
  local logical="$1" opt item total name hits
  case "$logical" in
    started)   opt="$TEAM_GH_STATUS_STARTED" ;;
    delivered) opt="$TEAM_GH_STATUS_DELIVERED" ;;
    *) die 4 "unknown logical status '$logical' (started|delivered)" ;;
  esac
  gh_or4 gh project item-list "$TEAM_GH_PROJECT_NUMBER" --owner "$TEAM_GH_PROJECT_OWNER" \
    --format json --limit 1 > "$TMP/count.json"
  total="$(jq -r '.totalCount // empty' "$TMP/count.json")"
  [[ "$total" =~ ^[0-9]+$ ]] || die 4 "project $TEAM_GH_PROJECT_NUMBER has no readable totalCount"
  gh_or4 gh project item-list "$TEAM_GH_PROJECT_NUMBER" --owner "$TEAM_GH_PROJECT_OWNER" \
    --format json --limit "$total" > "$TMP/items.json"
  [ "$(jq -r '.items | length' "$TMP/items.json")" = "$total" ] \
    || die 4 "incomplete item list for project $TEAM_GH_PROJECT_NUMBER"
  # Identity is repo + number, never the number alone (owner/A#7 and owner/B#7 can share a project).
  # An ambiguous match is recoverable, not a coin flip: editing the wrong item is unrecoverable.
  jq --argjson n "$KEY" --arg repo "$TEAM_GH_REPO" \
    '[.items[] | select(.content.type == "Issue" and .content.number == $n
       and .content.repository == $repo)]' "$TMP/items.json" > "$TMP/match.json" \
    || die 4 "item list of project $TEAM_GH_PROJECT_NUMBER is not parseable"
  hits="$(jq -r 'length' "$TMP/match.json")"
  [ "$hits" -le 1 ] || die 4 "issue #$KEY matches $hits items in project \
$TEAM_GH_PROJECT_NUMBER — refusing to edit one of them"
  item="$(jq -r '.[0].id // ""' "$TMP/match.json")"
  [ -n "$item" ] \
    || die 4 "issue #$KEY is not in project $TEAM_GH_PROJECT_NUMBER — not adding it"
  gh_or4 gh project field-list "$TEAM_GH_PROJECT_NUMBER" --owner "$TEAM_GH_PROJECT_OWNER" \
    --format json > "$TMP/fields.json"
  name="$(jq -r --arg f "$TEAM_GH_STATUS_FIELD_ID" --arg o "$opt" \
    '[.fields[]? | select(.id == $f) | .options[]? | select(.id == $o) | .name] | .[0] // ""' \
    "$TMP/fields.json")"
  [ -n "$name" ] || die 4 "status option '$opt' is not in field $TEAM_GH_STATUS_FIELD_ID"
  # By item ID, not by issue number: another repo's #<n> may sit in the same project, and reading
  # its status would report `unchanged` while the target item stays where it was.
  if [ "$(jq -r --arg id "$item" \
      '[.items[] | select(.id == $id)] | .[0].status // ""' "$TMP/items.json")" = "$name" ]; then
    echo "unchanged"; return 0
  fi
  gh_or4 gh project item-edit --id "$item" --project-id "$TEAM_GH_PROJECT_ID" \
    --field-id "$TEAM_GH_STATUS_FIELD_ID" --single-select-option-id "$opt" >/dev/null
  echo "set $logical"
}

op_create_followup() {
  local marker="$1" title="$2" file="$3" n url hits
  marker_is_last_line "$file" "$marker"
  gh_or4 gh api "repos/$TEAM_GH_REPO/issues?state=all&per_page=100" --paginate > "$TMP/raw.json"
  jq -s 'add // []' "$TMP/raw.json" > "$TMP/all.json" \
    || die 4 "issue list of $TEAM_GH_REPO is not parseable"
  jq --arg m "$MARKER_N" \
    'map(select((.pull_request | not)
       and ((.body // "") | gsub("\r"; "") | rtrimstr("\n") | split("\n") | last == $m)))' \
    "$TMP/all.json" > "$TMP/hits.json" || die 4 "issue list of $TEAM_GH_REPO is not parseable"
  # Same rule as op_comment: 0 → create · 1 → exists · >1 → recoverable, with nothing written.
  hits="$(jq -r 'length' "$TMP/hits.json")"
  [ "$hits" -le 1 ] \
    || die 4 "marker '$MARKER_N' matches $hits issues of $TEAM_GH_REPO — refusing to choose one"
  n="$(jq -r '.[0].number // ""' "$TMP/hits.json")"
  if [ -n "$n" ]; then echo "exists $n"; return 0; fi
  gh_or4 gh issue create --repo "$TEAM_GH_REPO" --title "$title" --body-file "$file" \
    > "$TMP/created"
  url="$(tail -n 1 "$TMP/created")"
  n="${url##*/}"
  [[ "$n" =~ ^[0-9]+$ ]] || die 4 "gh issue create printed no issue number ('$url')"
  echo "created $n"
}

# ---- dispatch -----------------------------------------------------------------------------------

op="${1:-}"; [ $# -eq 0 ] || shift
case "$op" in read|comment|set-status|create-followup) ;;
  *) die 2 "usage: team-tracker.sh read|comment|set-status|create-followup …" ;;
esac

if [ "$TEAM_TRACKER" = jira ]; then
  echo "error: jira runs through the session's MCP — no adapter op" >&2
  exit 3
fi

if [ "$TEAM_TRACKER" = none ] && [ "$op" != read ]; then
  echo "skipped (tracker=none)"
  exit 0
fi

OUT=""; MARKER=""; BODY_FILE=""; TITLE=""; BRIEF=""; HAS_BRIEF=0; POS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --out)        OUT="${2:-}"; shift 2 || die 2 "--out needs a directory" ;;
    --marker)     MARKER="${2:-}"; shift 2 || die 2 "--marker needs a value" ;;
    --body-file)  BODY_FILE="${2:-}"; shift 2 || die 2 "--body-file needs a path" ;;
    --title)      TITLE="${2:-}"; shift 2 || die 2 "--title needs a value" ;;
    --brief)      BRIEF="${2:-}"; HAS_BRIEF=1; shift 2 || die 2 "--brief needs text" ;;
    --brief-file) [ -r "${2:-}" ] || die 1 "--brief-file '${2:-}' is not readable"
                  BRIEF="$(cat "$2")"; HAS_BRIEF=1; shift 2 ;;
    -*)           die 2 "unknown option '$1'" ;;
    *)            POS+=("$1"); shift ;;
  esac
done
set -- ${POS[@]+"${POS[@]}"}

case "$op" in
  read)
    [ -n "$OUT" ] || die 2 "read needs --out <dir>"
    if [ "$TEAM_TRACKER" = none ]; then
      [ "$HAS_BRIEF" = 1 ] || die 1 "read needs --brief <text> or --brief-file <path>"
      [ -n "$(printf '%s' "$BRIEF" | tr -d '[:space:]')" ] || die 1 "the brief is empty"
      op_read_none "$OUT" "$BRIEF"
    else
      [ $# -eq 1 ] || die 2 "read needs a ticket key"
      norm_key "$1"
      op_read_github "$OUT"
    fi ;;
  comment)
    [ $# -eq 1 ] || die 2 "comment needs a ticket key"
    [ -n "$MARKER" ] || die 2 "comment needs --marker <m>"
    [ -n "$BODY_FILE" ] || die 2 "comment needs --body-file <f>"
    norm_key "$1"
    op_comment "$MARKER" "$BODY_FILE" ;;
  set-status)
    [ $# -eq 2 ] || die 2 "usage: set-status <key> started|delivered"
    norm_key "$1"
    op_set_status "$2" ;;
  create-followup)
    [ -n "$MARKER" ] || die 2 "create-followup needs --marker <m>"
    [ -n "$TITLE" ] || die 2 "create-followup needs --title <t>"
    [ -n "$BODY_FILE" ] || die 2 "create-followup needs --body-file <f>"
    op_create_followup "$MARKER" "$TITLE" "$BODY_FILE" ;;
esac
