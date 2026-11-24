#!/usr/bin/env bash
# The tracker adapter — the ONLY place the team harness calls `gh`.
#
# Usage: bash .claude/lib/team-tracker.sh <op> …
#   read <key> --out <dir>                                  (tracker=github)
#   read --brief <text>|--brief-file <path> --out <dir>      (tracker=none)
#   comment <key> --marker <m> --body-file <f>
#   set-status <key> started|delivered | --name <option> | --clear   (--name/--clear: the
#                                                             restore form of a released claim)
#   create-followup --marker <m> --title <t> --body-file <f>  (adds the issue to the Project)
#   list --out <file>                                        (read-only; /tasks-status)
#   show <key> --out <file>                                  (read-only; /tasks-status)
#   create-issue --marker <m> --title <t> --body-file <f>    (marker on ANY body line; /github-sync;
#                                                             adds the issue to the Project)
#   markers --prefix <p> --out <file>                        (read-only; /github-sync)
#   sub-issues <parent> --out <file>                         (read-only; /github-sync)
#   add-sub-issue <parent> <child>                           (idempotent; /github-sync)
#   project-add <key>                                        (idempotent; /github-sync)
#   pool --status <name> --out <file>                        (read-only; /qa-verify)
#   item-status <key> --out <file>                           (read-only; /qa-verify, team-claim.sh;
#                                                             also the started/delivered option names)
#   which                                                    (read-only, local; /create-task)
#   add-labels <key> <label> [<label>…]                      (idempotent; /create-task)
#
# Profile: the `teams` block when there is one (full validation), else the top-level `tracker` and
# `github` block of a single-session project (`team_tracker_profile_load`). A github block without
# its Project fields is valid there: set-status says `skipped (no project)`, list reports no board.
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
team_tracker_profile_load "$root"

TMP="$(mktemp -d)"
LOCK=""
# `rm -rf`, not `rmdir`: the lock dir holds a `pid` file, like team-send-lock.sh's.
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

# Usage: branch_type <kind> → $TYPE, the generic kind (feature|bugfix|docs|chore) as one of
# teams.branch_types, because /start-team builds <type>/<key>-<slug> from it and team-new refuses a
# type outside that list. The first synonym the list holds wins; none → the list's FIRST entry, with
# a warning on stderr. Without a teams block there is no list: the kind as it is, docs as chore.
TYPE=""
branch_type() {
  local syn c t
  TYPE="$1"
  if [ -z "${TEAM_TRACKER_TEAMS:-}" ]; then [ "$1" != docs ] || TYPE=chore; return 0; fi
  case "$1" in
    feature) syn="feature feat" ;;
    bugfix)  syn="bugfix fix bug" ;;
    docs)    syn="docs doc documentation chore" ;;
    *)       syn="$1" ;;
  esac
  for c in $syn; do
    for t in "${TEAM_BRANCH_TYPES[@]}"; do [ "$t" != "$c" ] || { TYPE="$t"; return 0; }; done
  done
  TYPE="${TEAM_BRANCH_TYPES[0]}"
  echo "warning: teams.branch_types has no type for a $1 ticket — using '$TYPE'" >&2
}

op_read_github() {
  local dir="$1" type
  gh issue view "$KEY" --repo "$TEAM_GH_REPO" \
    --json number,title,labels,body,url,state > "$TMP/issue.json" 2>"$TMP/err" \
    || { sed 's/^/  | /' "$TMP/err" >&2; die 1 "issue #$KEY cannot be read"; }
  local state; state="$(jq -r '.state // empty' "$TMP/issue.json")"
  [ "$state" = OPEN ] || die 1 "issue #$KEY is $state"
  # First matching RULE wins (not the first label): bug → bugfix, the chore labels, documentation.
  type="$(jq -r '[.labels[]?.name] as $l
    | if ($l | index("bug")) then "bugfix"
      elif ($l | map(. == "harness" or . == "infra") | any) then "chore"
      elif ($l | index("documentation")) then "docs"
      else "feature" end' "$TMP/issue.json")"
  branch_type "$type"
  jq --arg key "$KEY" --arg type "$TYPE" \
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
  branch_type feature
  jq -n --arg key "$KEY" --arg title "$title" --arg body "$brief" --arg type "$TYPE" \
    '{key: $key, title: $title, type: $type, labels: [], body: $body, url: ""}' \
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

# Usage: project_items → $TMP/items.json, the WHOLE item list of the project: totalCount first, then
# exactly that many items. A short list is exit 4 — an item missing from it would read as "not on
# the board".
project_items() {
  local total
  gh_or4 gh project item-list "$TEAM_GH_PROJECT_NUMBER" --owner "$TEAM_GH_PROJECT_OWNER" \
    --format json --limit 1 > "$TMP/count.json"
  total="$(jq -r '.totalCount // empty' "$TMP/count.json")"
  [[ "$total" =~ ^[0-9]+$ ]] || die 4 "project $TEAM_GH_PROJECT_NUMBER has no readable totalCount"
  gh_or4 gh project item-list "$TEAM_GH_PROJECT_NUMBER" --owner "$TEAM_GH_PROJECT_OWNER" \
    --format json --limit "$total" > "$TMP/items.json"
  [ "$(jq -r '.items | length' "$TMP/items.json")" = "$total" ] \
    || die 4 "incomplete item list for project $TEAM_GH_PROJECT_NUMBER"
}

# Usage: project_item_match "<refusal>" → $TMP/match.json (the items of issue #$KEY) and HITS.
# Identity is repo + number, never the number alone (owner/A#7 and owner/B#7 can share a project).
# An ambiguous match is recoverable, not a coin flip: acting on the wrong item is unrecoverable.
project_item_match() {
  jq --argjson n "$KEY" --arg repo "$TEAM_GH_REPO" \
    '[.items[] | select(.content.type == "Issue" and .content.number == $n
       and .content.repository == $repo)]' "$TMP/items.json" > "$TMP/match.json" \
    || die 4 "item list of project $TEAM_GH_PROJECT_NUMBER is not parseable"
  HITS="$(jq -r 'length' "$TMP/match.json")"
  [ "$HITS" -le 1 ] || die 4 "issue #$KEY matches $HITS items in project \
$TEAM_GH_PROJECT_NUMBER — refusing to $1"
}

# Usage: status_target → ITEM, the issue's one project item, and $TMP/fields.json. An issue off the
# board is exit 4 — set-status never adds it.
ITEM=""
status_target() {
  project_items
  project_item_match "edit one of them"
  ITEM="$(jq -r '.[0].id // ""' "$TMP/match.json")"
  [ -n "$ITEM" ] \
    || die 4 "issue #$KEY is not in project $TEAM_GH_PROJECT_NUMBER — not adding it"
  gh_or4 gh project field-list "$TEAM_GH_PROJECT_NUMBER" --owner "$TEAM_GH_PROJECT_OWNER" \
    --format json > "$TMP/fields.json"
}

# By item ID, not by issue number: another repo's #<n> may sit in the same project, and reading
# its status would report `unchanged` while the target item stays where it was.
item_status_now() {
  jq -r --arg id "$ITEM" '[.items[] | select(.id == $id)] | .[0].status // ""' "$TMP/items.json"
}

# Usage: status_edit <option id> — the one board write of every set-status form.
status_edit() {
  gh_or4 gh project item-edit --id "$ITEM" --project-id "$TEAM_GH_PROJECT_ID" \
    --field-id "$TEAM_GH_STATUS_FIELD_ID" --single-select-option-id "$1" >/dev/null
}

op_set_status() {
  local logical="$1" opt name
  case "$logical" in
    started)   opt="$TEAM_GH_STATUS_STARTED" ;;
    delivered) opt="$TEAM_GH_STATUS_DELIVERED" ;;
    *) die 4 "unknown logical status '$logical' (started|delivered)" ;;
  esac
  if [ -z "$TEAM_GH_PROJECT_NUMBER" ]; then echo "skipped (no project)"; return 0; fi
  status_target
  name="$(jq -r --arg f "$TEAM_GH_STATUS_FIELD_ID" --arg o "$opt" \
    '[.fields[]? | select(.id == $f) | .options[]? | select(.id == $o) | .name] | .[0] // ""' \
    "$TMP/fields.json")"
  [ -n "$name" ] || die 4 "status option '$opt' is not in field $TEAM_GH_STATUS_FIELD_ID"
  if [ "$(item_status_now)" = "$name" ]; then echo "unchanged"; return 0; fi
  status_edit "$opt"
  echo "set $logical"
}

# set-status --name <option>: the restore form — back to the status a claim's marker recorded, by
# the option's NAME (the marker never holds an option id).
op_set_status_name() {
  local want="$1" opt
  if [ -z "$TEAM_GH_PROJECT_NUMBER" ]; then echo "skipped (no project)"; return 0; fi
  status_target
  opt="$(jq -r --arg f "$TEAM_GH_STATUS_FIELD_ID" --arg n "$want" \
    '[.fields[]? | select(.id == $f) | .options[]? | select(.name == $n) | .id] | .[0] // ""' \
    "$TMP/fields.json")"
  [ -n "$opt" ] || die 4 "status option '$want' is not in field $TEAM_GH_STATUS_FIELD_ID"
  if [ "$(item_status_now)" = "$want" ]; then echo "unchanged"; return 0; fi
  status_edit "$opt"
  echo "set $want"
}

# set-status --clear: the restore form for an item that had no status before the claim.
op_set_status_clear() {
  if [ -z "$TEAM_GH_PROJECT_NUMBER" ]; then echo "skipped (no project)"; return 0; fi
  status_target
  if [ -z "$(item_status_now)" ]; then echo "unchanged"; return 0; fi
  gh_or4 gh project item-edit --id "$ITEM" --project-id "$TEAM_GH_PROJECT_ID" \
    --field-id "$TEAM_GH_STATUS_FIELD_ID" --clear >/dev/null
  echo "cleared"
}

op_create_followup() {
  marker_is_last_line "$3" "$1"
  create_marked last "$2" "$3"
}

# create-issue: the backlog sync's create. The marker is a line ANYWHERE in the body — a note a
# human appends under it must not turn the next run into a duplicate create.
op_create_issue() {
  [ -r "$3" ] || die 2 "body file '$3' is not readable"
  MARKER_N="$(printf '%s' "$1" | tr -d '\r')"
  [ -n "$MARKER_N" ] || die 2 "the marker is empty"
  tr -d '\r' < "$3" | grep -Fxq -- "$MARKER_N" || die 2 "the marker must be a line of '$3'"
  create_marked any "$2" "$3"
}

# Usage: all_issues → $TMP/all.json, EVERY issue of the repo (all states, every page, PRs dropped).
# `--paginate` into a file: a later-page failure is a non-zero exit, never a short list.
all_issues() {
  gh_or4 gh api "repos/$TEAM_GH_REPO/issues?state=all&per_page=100" --paginate > "$TMP/raw.json"
  jq -s 'add // [] | map(select(.pull_request | not))' "$TMP/raw.json" > "$TMP/all.json" \
    || die 4 "issue list of $TEAM_GH_REPO is not parseable"
}

# Usage: project_after <n> — the board half of a create: `project: added|exists|skipped (no
# project)`, or a warning line (exit 0): the issue exists, only its board entry is missing.
project_after() {
  local out
  # op_project_add dies on a failure; in this subshell that ends only the board half.
  if out="$(KEY="$1"; op_project_add 2> "$TMP/padd.err")"; then echo "project: $out"
  else echo "warning: project add failed for #$1 — rerun: team-tracker.sh project-add $1 ($(tail -n 1 "$TMP/padd.err" 2>/dev/null))"; fi
}

# Usage: create_marked last|any <title> <body file> — $MARKER_N set by the caller. Looks the marker
# up over the full list (as the last body line, or as any body line), then 0 → create · 1 → exists ·
# >1 → recoverable, with nothing written. Either way the issue is then added to the Project.
create_marked() {
  local mode="$1" title="$2" file="$3" n url hits
  all_issues
  jq --arg m "$MARKER_N" --arg mode "$mode" \
    'map(select((.body // "") | gsub("\r"; "") | rtrimstr("\n") | split("\n")
       | if $mode == "last" then last == $m else any(. == $m) end))' \
    "$TMP/all.json" > "$TMP/hits.json" || die 4 "issue list of $TEAM_GH_REPO is not parseable"
  hits="$(jq -r 'length' "$TMP/hits.json")"
  [ "$hits" -le 1 ] \
    || die 4 "marker '$MARKER_N' matches $hits issues of $TEAM_GH_REPO — refusing to choose one"
  n="$(jq -r '.[0].number // ""' "$TMP/hits.json")"
  if [ -n "$n" ]; then echo "exists $n"; project_after "$n"; return 0; fi
  gh_or4 gh issue create --repo "$TEAM_GH_REPO" --title "$title" --body-file "$file" \
    > "$TMP/created"
  url="$(tail -n 1 "$TMP/created")"
  n="${url##*/}"
  [[ "$n" =~ ^[0-9]+$ ]] || die 4 "gh issue create printed no issue number ('$url')"
  echo "created $n"
  project_after "$n"
  return 0
}

# Usage: write_atomic <src> <dest> — the reader never sees a half-written file.
write_atomic() {
  cp "$1" "$2.tmp.$$" 2>/dev/null || die 2 "cannot write '$2'"
  mv "$2.tmp.$$" "$2" || die 2 "cannot write '$2'"
}

# list: every OPEN issue of the repo (PRs dropped) with its Project status, and the Status field's
# options in board order. Read-only. `status` is null for an issue not on the board; `on_board` > 1
# is an ambiguous repo+number match, reported, never resolved by picking one.
op_list() {
  local out="$1"
  gh_or4 gh api "repos/$TEAM_GH_REPO/issues?state=open&per_page=100" --paginate > "$TMP/raw.json"
  jq -s 'add // [] | map(select(.pull_request | not))' "$TMP/raw.json" > "$TMP/open.json" \
    || die 4 "issue list of $TEAM_GH_REPO is not parseable"
  if [ -n "$TEAM_GH_PROJECT_NUMBER" ]; then
    project_items
    gh_or4 gh project field-list "$TEAM_GH_PROJECT_NUMBER" --owner "$TEAM_GH_PROJECT_OWNER" \
      --format json > "$TMP/fields.json"
  else  # no Project: no board to read — every issue is off the board
    echo '{"items": []}' > "$TMP/items.json"; echo '{"fields": []}' > "$TMP/fields.json"
  fi
  jq -n --slurpfile o "$TMP/open.json" --slurpfile i "$TMP/items.json" \
    --slurpfile f "$TMP/fields.json" --arg repo "$TEAM_GH_REPO" --arg fid "$TEAM_GH_STATUS_FIELD_ID" '
    [$i[0].items[] | select(.content.type == "Issue" and .content.repository == $repo)] as $b
    | {tracker: "github", repo: $repo,
       statuses: [$f[0].fields[]? | select(.id == $fid) | .options[]?.name],
       items: [$o[0][] | . as $x | [$b[] | select(.content.number == $x.number)] as $m
         | {key: ($x.number | tostring), title: ($x.title // ""),
            status: (if ($m | length) == 1 then ($m[0].status // null) else null end),
            on_board: ($m | length), updated: ($x.updated_at // ""),
            assignees: [$x.assignees[]?.login], labels: [$x.labels[]?.name],
            url: ($x.html_url // "")}]}' > "$TMP/list.json" \
    || die 4 "issue list of $TEAM_GH_REPO cannot be joined with project $TEAM_GH_PROJECT_NUMBER"
  write_atomic "$TMP/list.json" "$out"
  jq -r '"items=" + (.items | length | tostring)' "$out"
}

# show: one issue with its body and EVERY comment (id, author, created, updated, body) — the
# evidence /tasks-status extractors judge and the input of tracker-snapshot.mjs. A closed issue still
# answers (its state says so). Read-only; the output file is mode 0600.
op_show() {
  local out="$1"
  gh issue view "$KEY" --repo "$TEAM_GH_REPO" \
    --json number,title,state,labels,assignees,body,updatedAt,url > "$TMP/issue.json" 2>"$TMP/err" \
    || { sed 's/^/  | /' "$TMP/err" >&2; die 1 "issue #$KEY cannot be read"; }
  # Into a FILE, not a pipe — same reason as op_comment: a later-page failure must stay visible.
  gh_or4 gh api "repos/$TEAM_GH_REPO/issues/$KEY/comments" --paginate > "$TMP/raw.json"
  jq -s 'add // []' "$TMP/raw.json" > "$TMP/comments.json" \
    || die 4 "comment list of issue #$KEY is not parseable"
  jq -n --slurpfile x "$TMP/issue.json" --slurpfile c "$TMP/comments.json" --arg key "$KEY" '
    $x[0] as $i
    | {key: $key, title: ($i.title // ""), state: ($i.state // ""), labels: [$i.labels[]?.name],
       assignees: [$i.assignees[]?.login], updated: ($i.updatedAt // ""), url: ($i.url // ""),
       body: ($i.body // ""),
       comments: [$c[0][] | {id: (.id // "" | tostring), author: (.user.login // ""),
                             created: (.created_at // ""), updated: (.updated_at // .created_at // ""),
                             body: (.body // "")}]}' > "$TMP/show.json" \
    || die 4 "issue #$KEY is not parseable"
  # Private tracker text: owner-only, like the snapshot built from it (tracker-snapshot.mjs).
  chmod 600 "$TMP/show.json"
  write_atomic "$TMP/show.json" "$out"
  jq -r '"key=" + .key + " comments=" + (.comments | length | tostring)' "$out"
}

# The pool query (verified live against a Project): the status value by the Status field's NAME
# (one value per item, no field-value paging), the issue's parent, dependency links and the issues
# that cross-reference it. POOL_Q_NODEPS drops the two dependency fields for a host without them.
POOL_Q_HEAD='query($pid: ID!, $cursor: String, $fname: String!) { node(id: $pid) { ... on ProjectV2 {
  items(first: 100, after: $cursor) { totalCount pageInfo { hasNextPage endCursor }
    nodes { id
      status: fieldValueByName(name: $fname) { ... on ProjectV2ItemFieldSingleSelectValue {
        name updatedAt } }
      content { __typename ... on Issue { number title state url repository { nameWithOwner }
        parent { number repository { nameWithOwner } }'
POOL_Q_DEPS='
        blockedBy(first: 50) { pageInfo { hasNextPage } nodes { number repository { nameWithOwner } } }
        blocking(first: 50) { pageInfo { hasNextPage } nodes { number repository { nameWithOwner } } }'
POOL_Q_TAIL='
        timelineItems(first: 100, itemTypes: [CROSS_REFERENCED_EVENT]) { pageInfo { hasNextPage }
          nodes { ... on CrossReferencedEvent { source { __typename
            ... on Issue { number repository { nameWithOwner } } } } } } } } } } } } }'
POOL_Q="$POOL_Q_HEAD$POOL_Q_DEPS$POOL_Q_TAIL"
POOL_Q_NODEPS="$POOL_Q_HEAD$POOL_Q_TAIL"

# Usage: status_field → $TMP/sfield.json ({name, options}) of the profile's Status field.
status_field() {
  gh_or4 gh project field-list "$TEAM_GH_PROJECT_NUMBER" --owner "$TEAM_GH_PROJECT_OWNER" \
    --format json > "$TMP/fields.json"
  jq --arg f "$TEAM_GH_STATUS_FIELD_ID" \
    '[.fields[]? | select(.id == $f)] | .[0] // {} | {name: (.name // ""), options: [.options[]?.name]}' \
    "$TMP/fields.json" > "$TMP/sfield.json" \
    || die 4 "field list of project $TEAM_GH_PROJECT_NUMBER is not parseable"
  [ -n "$(jq -r '.name' "$TMP/sfield.json")" ] \
    || die 4 "status field $TEAM_GH_STATUS_FIELD_ID is not in project $TEAM_GH_PROJECT_NUMBER"
}

# pool: every item of the Project whose Status is <name> and whose content is an issue of the repo,
# WHATEVER the issue state (a merged ticket's issue is closed while it still waits in QA). Pages are
# files; a page set that is short, repeats a cursor, or an item whose link list does not fit one page
# is exit 4 — a short read must never look like "not in the pool". Read-only; output mode 0600.
op_pool() {
  local want="$1" out="$2" fname q deps=available k=1 cur="" prev="" more total n
  [ -n "$TEAM_GH_PROJECT_ID" ] || die 2 "pool needs a GitHub Project (project_id) — none configured"
  status_field
  fname="$(jq -r '.name' "$TMP/sfield.json")"
  jq -e --arg s "$want" '.options | index($s) != null' "$TMP/sfield.json" >/dev/null \
    || die 1 "status '$want' is not an option of the Status field (options: \
$(jq -r '.options | join(", ")' "$TMP/sfield.json"))"
  q="$POOL_Q"
  # Not through gh_or4: a host without issue dependencies fails here, and stderr says which field.
  if ! gh api graphql -f "pid=$TEAM_GH_PROJECT_ID" -f "fname=$fname" -f "query=$q" \
      > "$TMP/page-1.json" 2> "$TMP/gql.err"; then
    grep -qE 'blockedBy|blocking' "$TMP/gql.err" \
      || { sed 's/^/  | /' "$TMP/gql.err" >&2; die 4 "gh api graphql failed — recoverable"; }
    deps=unavailable; q="$POOL_Q_NODEPS"
    gh_or4 gh api graphql -f "pid=$TEAM_GH_PROJECT_ID" -f "fname=$fname" -f "query=$q" \
      > "$TMP/page-1.json"
  fi
  total="$(jq -r '.data.node.items.totalCount' "$TMP/page-1.json" 2>/dev/null || true)"
  while :; do
    jq -e '(has("errors") | not) and (.data.node.items.nodes | type == "array")' \
      "$TMP/page-$k.json" >/dev/null 2>&1 || die 4 "project $TEAM_GH_PROJECT_ID answered no item page"
    [[ "$total" =~ ^[0-9]+$ ]] || die 4 "project $TEAM_GH_PROJECT_ID has no readable totalCount"
    more="$(jq -r '.data.node.items.pageInfo.hasNextPage' "$TMP/page-$k.json")"
    [ "$more" = true ] || break
    cur="$(jq -r '.data.node.items.pageInfo.endCursor // ""' "$TMP/page-$k.json")"
    # A cursor that never advances must not spin; nor may more pages than items.
    [ -n "$cur" ] && [ "$cur" != "$prev" ] && [ "$k" -le $((total + 1)) ] \
      || die 4 "item pages of project $TEAM_GH_PROJECT_ID do not advance — refusing a partial pool"
    prev="$cur"; k=$((k + 1))
    gh_or4 gh api graphql -f "pid=$TEAM_GH_PROJECT_ID" -f "fname=$fname" -f "cursor=$cur" \
      -f "query=$q" > "$TMP/page-$k.json"
  done
  jq -s 'map(.data.node.items.nodes[])' "$TMP"/page-*.json > "$TMP/nodes.json" \
    || die 4 "item pages of project $TEAM_GH_PROJECT_ID are not parseable"
  [ "$(jq 'length' "$TMP/nodes.json")" = "$total" ] \
    || die 4 "incomplete item list for project $TEAM_GH_PROJECT_ID"
  jq --arg repo "$TEAM_GH_REPO" --arg s "$want" '[.[] | select(.content.__typename == "Issue"
      and .content.repository.nameWithOwner == $repo and (.status.name? // null) == $s)]' \
    "$TMP/nodes.json" > "$TMP/sel.json" || die 4 "item list is not parseable"
  # Ambiguity over every item of the issue, not only those in <name>: an issue in QA and in Todo
  # has no single status (item-status refuses it too).
  n="$(jq -r --arg repo "$TEAM_GH_REPO" --arg s "$want" '[.[] | select(.content.__typename == "Issue"
      and .content.repository.nameWithOwner == $repo)] | group_by(.content.number)
    | map(select(length > 1 and any(.[]; (.status.name? // null) == $s)) | .[0].content.number)
    | .[0] // ""' "$TMP/nodes.json")"
  [ -z "$n" ] || die 4 "issue #$n has more than one item in project $TEAM_GH_PROJECT_ID — refusing to pick one"
  n="$(jq -r 'map(select([.content.blockedBy, .content.blocking, .content.timelineItems]
      | any(.pageInfo.hasNextPage? == true)) | .content.number) | .[0] // ""' "$TMP/sel.json")"
  [ -z "$n" ] || die 4 "issue #$n has more links than one page — refusing a partial link list"
  jq -n --slurpfile sel "$TMP/sel.json" --slurpfile f "$TMP/sfield.json" --arg repo "$TEAM_GH_REPO" \
    --arg s "$want" --arg deps "$deps" '
    def nums($self): [.[]? | select(.repository.nameWithOwner? == $repo) | .number
      | select(. != $self)] | unique | map(tostring);
    {tracker: "github", repo: $repo, status: $s, statuses: $f[0].options, dependencies: $deps,
     items: ([$sel[0][] | .content as $c
       | {key: ($c.number | tostring), title: ($c.title // ""), state: ($c.state // ""),
          url: ($c.url // ""), status_since: (.status.updatedAt // ""),
          parent: (if $c.parent != null and $c.parent.repository.nameWithOwner == $repo
                   then $c.parent.number else null end),
          blocked_by: ($c.blockedBy.nodes // [] | nums($c.number)),
          blocking: ($c.blocking.nodes // [] | nums($c.number)),
          mentions: ([$c.timelineItems.nodes[]?.source | select(.__typename? == "Issue")]
                     | nums($c.number))}]
       | sort_by(.status_since))}' > "$TMP/pool.json" || die 4 "the pool cannot be built"
  chmod 600 "$TMP/pool.json"
  write_atomic "$TMP/pool.json" "$out"
  jq -r '"items=" + (.items | length | tostring) + " status=" + .status' "$out"
}

# item-status: one issue, open or closed, with its board Status — by the set-status identity
# (repo + number over the full item list; more than one item is exit 4). Read-only.
op_item_status() {
  local out="$1"
  [ -n "$TEAM_GH_PROJECT_ID" ] \
    || die 2 "item-status needs a GitHub Project (project_id) — none configured"
  gh issue view "$KEY" --repo "$TEAM_GH_REPO" --json state > "$TMP/issue.json" 2>"$TMP/err" \
    || { sed 's/^/  | /' "$TMP/err" >&2; die 1 "issue #$KEY cannot be read"; }
  project_items
  status_field
  project_item_match "read one of them"
  # started/delivered: the NAMES of the profile's two option ids (null when not an option) — the
  # claim compares a status against them.
  jq -n --slurpfile i "$TMP/issue.json" --slurpfile m "$TMP/match.json" \
    --slurpfile f "$TMP/sfield.json" --slurpfile fl "$TMP/fields.json" --arg key "$KEY" \
    --arg fid "$TEAM_GH_STATUS_FIELD_ID" --arg so "$TEAM_GH_STATUS_STARTED" \
    --arg sd "$TEAM_GH_STATUS_DELIVERED" \
    'def oname($o): [$fl[0].fields[]? | select(.id == $fid) | .options[]? | select(.id == $o)
        | .name] | .[0] // null;
     {key: $key, state: ($i[0].state // ""),
      status: (if ($m[0] | length) == 1 then ($m[0][0].status // null) else null end),
      on_board: ($m[0] | length), statuses: $f[0].options,
      started: oname($so), delivered: oname($sd)}' > "$TMP/is.json" \
    || die 4 "issue #$KEY cannot be joined with project $TEAM_GH_PROJECT_NUMBER"
  write_atomic "$TMP/is.json" "$out"
  jq -r '"key=" + .key + " status=" + (.status // "null")' "$out"
}

# markers: every issue line that starts with <prefix> and ends with ` -->`, over the full list →
# {"<marker line>": [{number, hash}]}; `hash` is the issue's `<!-- backlog-hash:<h> -->` line, or
# null. Read-only. More than one number under a marker is the caller's ambiguity to refuse.
op_markers() {
  local prefix="$1" out="$2"
  all_issues
  jq --arg p "$prefix" '
    reduce (.[] | . as $i | ((.body // "") | gsub("\r"; "") | split("\n")) as $ls
      | ([$ls[] | select(startswith("<!-- backlog-hash:") and endswith(" -->"))
          | ltrimstr("<!-- backlog-hash:") | rtrimstr(" -->")] | .[0] // null) as $h
      | $ls[] | select(startswith($p) and endswith(" -->")) | {m: ., n: $i.number, h: $h})
    as $x ({}; .[$x.m] += [{number: $x.n, hash: $x.h}])' "$TMP/all.json" > "$TMP/markers.json" \
    || die 4 "issue list of $TEAM_GH_REPO is not parseable"
  write_atomic "$TMP/markers.json" "$out"
  jq -r '"markers=" + (keys | length | tostring)' "$out"
}

# Usage: sub_issue_numbers <parent> → $TMP/subs.json, the parent's sub-issue numbers (every page).
sub_issue_numbers() {
  gh_or4 gh api "repos/$TEAM_GH_REPO/issues/$1/sub_issues?per_page=100" --paginate > "$TMP/raw.json"
  jq -s 'add // [] | map(.number)' "$TMP/raw.json" > "$TMP/subs.json" \
    || die 4 "sub-issue list of #$1 is not parseable"
}

op_sub_issues() {
  sub_issue_numbers "$KEY"
  write_atomic "$TMP/subs.json" "$1"
  jq -r '"sub_issues=" + (length | tostring)' "$1"
}

# add-sub-issue: idempotent — the full list first; only a missing child is added, by its database id.
op_add_sub_issue() {
  local parent="$KEY" child="$1" id
  sub_issue_numbers "$parent"
  if jq -e --argjson c "$child" 'index($c) != null' "$TMP/subs.json" >/dev/null; then
    echo "exists"; return 0
  fi
  gh_or4 gh api "repos/$TEAM_GH_REPO/issues/$child" > "$TMP/child.json"
  id="$(jq -r '.id // empty' "$TMP/child.json")"
  [[ "$id" =~ ^[0-9]+$ ]] || die 4 "issue #$child has no readable id"
  gh_or4 gh api -X POST "repos/$TEAM_GH_REPO/issues/$parent/sub_issues" \
    -F "sub_issue_id=$id" > /dev/null
  echo "added"
}

# project-add: idempotent — the full board list first (repo + number identity); >1 match is exit 4.
op_project_add() {
  local url
  if [ -z "$TEAM_GH_PROJECT_NUMBER" ]; then echo "skipped (no project)"; return 0; fi
  project_items
  project_item_match "guess"
  if [ "$HITS" = 1 ]; then echo "exists"; return 0; fi
  gh_or4 gh issue view "$KEY" --repo "$TEAM_GH_REPO" --json url > "$TMP/url.json"
  url="$(jq -r '.url // empty' "$TMP/url.json")"
  [ -n "$url" ] || die 4 "issue #$KEY has no URL"
  gh_or4 gh project item-add "$TEAM_GH_PROJECT_NUMBER" --owner "$TEAM_GH_PROJECT_OWNER" \
    --url "$url" > /dev/null
  echo "added"
}

# which: the resolved tracker, local only — answered for jira and none too (no gh call).
op_which() {
  echo "tracker=$TEAM_TRACKER"
  if [ "$TEAM_TRACKER" = github ]; then
    echo "repo=$TEAM_GH_REPO"
    echo "project=${TEAM_GH_PROJECT_NUMBER:-none}"
  fi
}

# add-labels: `gh issue edit --add-label` is idempotent on GitHub's side; a label the repo lacks is exit 4.
op_add_labels() {
  local l joined
  for l in "$@"; do
    [ -n "$l" ] || die 2 "label '' is empty"
    case "$l" in *,*) die 2 "label '$l' contains a comma" ;; esac
  done
  joined="$(IFS=,; echo "$*")"
  gh_or4 gh issue edit "$KEY" --repo "$TEAM_GH_REPO" --add-label "$joined" > /dev/null
  echo "labeled $joined"
}

# ---- dispatch -----------------------------------------------------------------------------------

op="${1:-}"; [ $# -eq 0 ] || shift
case "$op" in
  read|comment|set-status|create-followup|create-issue|list|show|markers|sub-issues|add-sub-issue|project-add|pool|item-status|which|add-labels) ;;
  *) die 2 "usage: team-tracker.sh read|comment|set-status|create-followup|create-issue|list|show|markers|sub-issues|add-sub-issue|project-add|pool|item-status|which|add-labels …" ;;
esac

if [ "$op" = which ]; then
  [ $# -eq 0 ] || die 2 "which takes no arguments"
  op_which
  exit 0
fi

if [ "$TEAM_TRACKER" = jira ]; then
  echo "error: jira runs through the session's MCP — no adapter op" >&2
  exit 3
fi

if [ "$TEAM_TRACKER" = none ] && [ "$op" != read ]; then
  echo "skipped (tracker=none)"
  exit 0
fi
# The L<n> counter lives in the team layer's `.agents/team/`; a project without teams has none.
[ "$TEAM_TRACKER" != none ] || [ -n "$TEAM_TRACKER_TEAMS" ] \
  || die 2 "read: local L<n> tickets need the teams block — tracker=none without teams has no tickets"

OUT=""; MARKER=""; BODY_FILE=""; TITLE=""; BRIEF=""; HAS_BRIEF=0; PREFIX=""; STATUS=""; POS=()
NAME=""; HAS_NAME=0; CLEAR=0
while [ $# -gt 0 ]; do
  case "$1" in
    --name)       NAME="${2:-}"; HAS_NAME=1; shift 2 || die 2 "--name needs an option name" ;;
    --clear)      CLEAR=1; shift ;;
    --out)        OUT="${2:-}"; shift 2 || die 2 "--out needs a directory" ;;
    --status)     STATUS="${2:-}"; shift 2 || die 2 "--status needs a name" ;;
    --marker)     MARKER="${2:-}"; shift 2 || die 2 "--marker needs a value" ;;
    --body-file)  BODY_FILE="${2:-}"; shift 2 || die 2 "--body-file needs a path" ;;
    --title)      TITLE="${2:-}"; shift 2 || die 2 "--title needs a value" ;;
    --prefix)     PREFIX="${2:-}"; shift 2 || die 2 "--prefix needs a value" ;;
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
    SS_USAGE="usage: set-status <key> started|delivered | --name <option> | --clear"
    { [ $# -eq 1 ] || [ $# -eq 2 ]; } || die 2 "$SS_USAGE"
    # Exactly one form: the logical positional, --name, or --clear.
    [ $(( $# - 1 + HAS_NAME + CLEAR )) = 1 ] || die 2 "$SS_USAGE"
    [ "$HAS_NAME" = 0 ] || [ -n "$NAME" ] || die 2 "--name needs an option name"
    norm_key "$1"
    if [ "$HAS_NAME" = 1 ]; then op_set_status_name "$NAME"
    elif [ "$CLEAR" = 1 ]; then op_set_status_clear
    else op_set_status "$2"; fi ;;
  create-followup)
    [ -n "$MARKER" ] || die 2 "create-followup needs --marker <m>"
    [ -n "$TITLE" ] || die 2 "create-followup needs --title <t>"
    [ -n "$BODY_FILE" ] || die 2 "create-followup needs --body-file <f>"
    op_create_followup "$MARKER" "$TITLE" "$BODY_FILE" ;;
  create-issue)
    [ -n "$MARKER" ] || die 2 "create-issue needs --marker <m>"
    [ -n "$TITLE" ] || die 2 "create-issue needs --title <t>"
    [ -n "$BODY_FILE" ] || die 2 "create-issue needs --body-file <f>"
    op_create_issue "$MARKER" "$TITLE" "$BODY_FILE" ;;
  markers)
    [ -n "$PREFIX" ] || die 2 "markers needs --prefix <p>"
    [ -n "$OUT" ] || die 2 "markers needs --out <file>"
    op_markers "$PREFIX" "$OUT" ;;
  sub-issues)
    [ $# -eq 1 ] || die 2 "sub-issues needs a parent key"
    [ -n "$OUT" ] || die 2 "sub-issues needs --out <file>"
    norm_key "$1"
    op_sub_issues "$OUT" ;;
  add-sub-issue)
    [ $# -eq 2 ] || die 2 "usage: add-sub-issue <parent> <child>"
    norm_key "$2"; child="$KEY"
    norm_key "$1"
    op_add_sub_issue "$child" ;;
  project-add)
    [ $# -eq 1 ] || die 2 "project-add needs a ticket key"
    norm_key "$1"
    op_project_add ;;
  list)
    [ $# -eq 0 ] || die 2 "list takes no ticket key"
    [ -n "$OUT" ] || die 2 "list needs --out <file>"
    op_list "$OUT" ;;
  show)
    [ $# -eq 1 ] || die 2 "show needs a ticket key"
    [ -n "$OUT" ] || die 2 "show needs --out <file>"
    norm_key "$1"
    op_show "$OUT" ;;
  pool)
    [ $# -eq 0 ] || die 2 "pool takes no ticket key"
    [ -n "$STATUS" ] || die 2 "pool needs --status <name>"
    [ -n "$OUT" ] || die 2 "pool needs --out <file>"
    op_pool "$STATUS" "$OUT" ;;
  item-status)
    [ $# -eq 1 ] || die 2 "item-status needs a ticket key"
    [ -n "$OUT" ] || die 2 "item-status needs --out <file>"
    norm_key "$1"
    op_item_status "$OUT" ;;
  add-labels)
    [ $# -ge 1 ] || die 2 "add-labels needs a ticket key and a label"
    norm_key "$1"; shift
    [ $# -ge 1 ] || die 2 "add-labels needs a label"
    op_add_labels "$@" ;;
esac
