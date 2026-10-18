#!/usr/bin/env bash
# Offline smoke for team-tracker.sh: the ticket file, marker idempotence across FULL enumeration,
# the project-status path, and the two no-op trackers. `gh` is a stub on PATH — every call is logged
# and the `none` case must leave that log empty (nothing may reach the network).
# Bash 3.2 compatible (macOS /bin/bash) — run it with /bin/bash, like the harness does.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/team-smoke-lib.sh"
smoke_init

TRK="bash .claude/lib/team-tracker.sh"
P="$MAIN/.claude/project-profile.json"
GH_DIR="$WORK/gh"
GH_LOG="$WORK/gh.log"
export GH_DIR GH_LOG
mkdir -p "$GH_DIR"
: > "$GH_LOG"

GH_BLOCK='.teams.github = {repo: "owner/repo", project_owner: "owner", project_number: 2,
  project_id: "PVT_x", status_field_id: "PVTSSF_x",
  status_options: {started: "opt-started", delivered: "opt-delivered"}}'
setprofile() { smoke_profile "${1:-.}" > "$P"; }
github_profile() { setprofile ".teams.tracker = \"github\" | $GH_BLOCK"; }
posts() { grep -c -- '-X POST' "$GH_LOG" | tr -d ' '; }
creates() { grep -c -- 'issue create' "$GH_LOG" | tr -d ' '; }

# ---- the gh stub: all state in $GH_DIR, 30 items per page, failures by env switch -------------
cat > "$WORK/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "gh $*" >> "$GH_LOG"
G="$GH_DIR"
pages() {  # pages <array file> — 30 per page, each page its own JSON array (as `gh api` does)
  local n i=0
  n=$(jq 'length' "$1")
  if [ "$n" = 0 ]; then echo '[]'; return 0; fi
  while [ "$i" -lt "$n" ]; do
    if [ "$i" -gt 0 ] && [ "${STUB_GH_PAGE2_FAIL:-0}" = 1 ]; then
      echo "gh: HTTP 502 on page 2" >&2; exit 1
    fi
    jq -c ".[$i:$((i + 30))]" "$1"
    i=$((i + 30))
  done
}
case "${1:-}" in
  issue)
    case "${2:-}" in
      view)
        [ -f "$G/issue-$3.json" ] || { echo "could not resolve to an Issue" >&2; exit 1; }
        cat "$G/issue-$3.json" ;;
      create)
        t=""; bf=""; shift 2
        while [ $# -gt 0 ]; do case "$1" in
          --title) t="$2"; shift 2 ;; --body-file) bf="$2"; shift 2 ;; *) shift ;; esac; done
        n=$(( $(jq 'length' "$G/issues.json") + 100 ))
        jq --argjson n "$n" --arg t "$t" --rawfile b "$bf" \
          '. + [{number: $n, title: $t, body: $b}]' "$G/issues.json" > "$G/t" \
          && mv "$G/t" "$G/issues.json"
        echo "https://github.com/owner/repo/issues/$n" ;;
      *) echo "stub: gh issue $2" >&2; exit 1 ;;
    esac ;;
  api)
    meth=GET; path=""; input=""; shift
    while [ $# -gt 0 ]; do case "$1" in
      -X) meth="$2"; shift 2 ;; --input) input="$2"; shift 2 ;; -*) shift ;;
      *) path="$1"; shift ;; esac; done
    case "$meth $path" in
      "GET "*/comments)
        pages "$G/comments.json" ;;
      "POST "*/comments)
        id=$(( $(jq 'length' "$G/comments.json") + 900 ))
        jq --argjson i "$id" --slurpfile p "$input" '. + [{id: $i, body: $p[0].body}]' \
          "$G/comments.json" > "$G/t" && mv "$G/t" "$G/comments.json"
        printf '{"id": %s}\n' "$id" ;;
      "GET "*issues\?*)
        pages "$G/issues.json" ;;
      *) echo "stub: gh api $meth $path" >&2; exit 1 ;;
    esac ;;
  project)
    case "${2:-}" in
      item-list)
        lim=1000
        while [ $# -gt 0 ]; do case "$1" in --limit) lim="$2"; shift 2 ;; *) shift ;; esac; done
        jq -c --argjson k "$lim" '{items: .[0:$k], totalCount: length}' "$G/items.json" ;;
      field-list)
        cat "$G/fields.json" ;;
      item-edit)
        [ "${STUB_GH_EDIT_DENY:-0}" != 1 ] \
          || { echo "your token has not been granted the required scopes: project" >&2; exit 1; }
        id=""; opt=""
        while [ $# -gt 0 ]; do case "$1" in
          --id) id="$2"; shift 2 ;; --single-select-option-id) opt="$2"; shift 2 ;;
          *) shift ;; esac; done
        name=$(jq -r --arg o "$opt" \
          '[.fields[]? | .options[]? | select(.id == $o) | .name] | .[0] // ""' "$G/fields.json")
        jq --arg id "$id" --arg s "$name" 'map(if .id == $id then .status = $s else . end)' \
          "$G/items.json" > "$G/t" && mv "$G/t" "$G/items.json"
        printf '%s\n' "$name" > "$G/status"
        echo '{}' ;;
      *) echo "stub: gh project $2" >&2; exit 1 ;;
    esac ;;
  *) echo "stub: gh $*" >&2; exit 1 ;;
esac
STUB
chmod +x "$WORK/bin/gh"

issue_json() {  # issue_json <n> <state> <labels json>
  jq -n --argjson n "$1" --arg s "$2" --argjson l "$3" \
    '{number: $n, title: "Fix the thing", labels: $l, body: "line one\nline two",
      url: ("https://github.com/owner/repo/issues/" + ($n | tostring)), state: $s}'
}

fx_reset() {
  issue_json 7 OPEN '[{"name": "bug"}, {"name": "harness"}]' > "$GH_DIR/issue-7.json"
  issue_json 9 CLOSED '[]' > "$GH_DIR/issue-9.json"
  issue_json 11 OPEN '[{"name": "documentation"}]' > "$GH_DIR/issue-11.json"
  echo '[]' > "$GH_DIR/comments.json"
  echo '[]' > "$GH_DIR/issues.json"
  jq -n '{fields: [{id: "PVTSSF_x", name: "Status",
      options: [{id: "opt-started", name: "In Progress"},
                {id: "opt-delivered", name: "Delivered"}]}]}' > "$GH_DIR/fields.json"
  # 50 project items; issue #7 sits at position 45 — past the first page of any enumeration.
  jq -n '[range(50)] | map({id: ("item-" + (. | tostring)), status: "Todo",
      content: {type: "Issue", number: (if . == 44 then 7 else 1000 + . end),
                repository: "owner/repo"}})' > "$GH_DIR/items.json"
  echo Todo > "$GH_DIR/status"
  : > "$GH_LOG"
}

body_file() {  # body_file <path> <marker>
  printf 'a line of body\n%s\n' "$2" > "$1"
}

# ================================================================================================
# (1) github read → ticket.json + ticket.md; the refusals come before any run exists
# ================================================================================================
github_profile
fx_reset
run "$MAIN" $TRK read 7 --out "$WORK/t"
expect 0 "key=7 type=bugfix" "github read prints the key and type"
has "title=Fix the thing" "$WORK/out" || fail "github read prints no title line"
jq -e '.key == "7" and .type == "bugfix" and (.labels | join(",")) == "bug,harness"
  and .url == "https://github.com/owner/repo/issues/7"' "$WORK/t/ticket.json" >/dev/null \
  || fail "ticket.json: bug+harness must resolve to bugfix by the first matching RULE"
has "# Fix the thing" "$WORK/t/ticket.md" || fail "ticket.md has no title heading"
has "URL: https://github.com/owner/repo/issues/7" "$WORK/t/ticket.md" || fail "ticket.md has no URL"
has "Labels: bug, harness" "$WORK/t/ticket.md" || fail "ticket.md has no labels"
has "line two" "$WORK/t/ticket.md" || fail "ticket.md has no body"

run "$MAIN" $TRK read '#7' --out "$WORK/t2"
expect 0 "key=7" "a #-prefixed key is normalized"
run "$MAIN" $TRK read 11 --out "$WORK/t3"
expect 0 "type=chore" "a documentation label is a chore"
run "$MAIN" $TRK read 9 --out "$WORK/t9"
expect 1 "issue #9 is CLOSED" "a closed issue is refused"
[ ! -e "$WORK/t9/ticket.json" ] || fail "a refused read wrote a ticket file"
run "$MAIN" $TRK read 404 --out "$WORK/t404"
expect 1 "issue #404 cannot be read" "a missing issue is refused"
run "$MAIN" $TRK read abc --out "$WORK/tabc"
expect 1 '^[0-9]+$' "a bad key is refused with the profile regex"

# ================================================================================================
# (2) comment: the marker makes a retry idempotent, and a partial enumeration never posts
# ================================================================================================
fx_reset
body_file "$WORK/c.md" MARKER-A
run "$MAIN" $TRK comment 7 --marker MARKER-A --body-file "$WORK/c.md"
expect 0 "created 900" "the first comment is posted"
run "$MAIN" $TRK comment 7 --marker MARKER-A --body-file "$WORK/c.md"
expect 0 "exists 900" "a retry finds its own comment by marker"
[ "$(posts)" = 1 ] || fail "the retry posted again ($(posts) POSTs)"
[ "$(jq 'length' "$GH_DIR/comments.json")" = 1 ] || fail "the issue carries more than one comment"

body_file "$WORK/c.md" MARKER-WRONG
run "$MAIN" $TRK comment 7 --marker MARKER-A --body-file "$WORK/c.md"
expect 2 "last line" "a marker that is not the last line is refused"

# Line endings: validation and lookup must normalize the SAME way, or a CRLF body validates here
# and then misses in the search — and the retry posts a second comment.
fx_reset
printf 'body\r\nMARKER-D\r\n' > "$WORK/crlf.md"
run "$MAIN" $TRK comment 7 --marker MARKER-D --body-file "$WORK/crlf.md"
expect 0 "created" "a CRLF body posts"
run "$MAIN" $TRK comment 7 --marker MARKER-D --body-file "$WORK/crlf.md"
expect 0 "exists" "a CRLF body is found on retry"
run "$MAIN" $TRK comment 7 --marker "$(printf 'MARKER-D\r')" --body-file "$WORK/crlf.md"
expect 0 "exists" "a marker argument with a trailing CR is found"
[ "$(posts)" = 1 ] || fail "the CRLF retries posted $(posts) times"

fx_reset
printf 'body\nMARKER-E' > "$WORK/nonl.md"      # LF body, no trailing newline
run "$MAIN" $TRK comment 7 --marker MARKER-E --body-file "$WORK/nonl.md"
expect 0 "created" "a body without a trailing newline posts"
run "$MAIN" $TRK comment 7 --marker MARKER-E --body-file "$WORK/nonl.md"
expect 0 "exists" "a body without a trailing newline is found on retry"
[ "$(posts)" = 1 ] || fail "the no-newline retry posted $(posts) times"

# the marker on page 2 (comment 45 of 50): a 30-item first page must not conclude "not there"
fx_reset
jq -n --arg m MARKER-B '[range(50)] | map({id: (500 + .),
  body: ("noise\n" + (if . == 44 then $m else "x" end))})' > "$GH_DIR/comments.json"
body_file "$WORK/c.md" MARKER-B
run "$MAIN" $TRK comment 7 --marker MARKER-B --body-file "$WORK/c.md"
expect 0 "exists 544" "a marker on page 2 is found"
[ "$(posts)" = 0 ] || fail "a found marker still posted"

: > "$GH_LOG"
body_file "$WORK/c.md" MARKER-C
export STUB_GH_PAGE2_FAIL=1
run "$MAIN" $TRK comment 7 --marker MARKER-C --body-file "$WORK/c.md"
unset STUB_GH_PAGE2_FAIL
expect 4 "recoverable" "a failed second page is recoverable, not 'absent'"
[ "$(posts)" = 0 ] || fail "an incomplete enumeration still posted a comment"

# ================================================================================================
# (3) set-status: permissions, the full item list, idempotence, the refusals
# ================================================================================================
fx_reset
body_file "$WORK/c.md" MARKER-A
export STUB_GH_EDIT_DENY=1
run "$MAIN" $TRK set-status 7 delivered
unset STUB_GH_EDIT_DENY
expect 4 "recoverable" "a denied item-edit is recoverable"
[ "$(cat "$GH_DIR/status")" = Todo ] || fail "a denied set-status moved the status anyway"

run "$MAIN" $TRK set-status 7 delivered
expect 0 "set delivered" "set-status finds the item at position 45 and sets it"
[ "$(cat "$GH_DIR/status")" = Delivered ] || fail "the stub status was not updated"
run "$MAIN" $TRK set-status 7 delivered
expect 0 "unchanged" "a second set-status is a no-op"
run "$MAIN" $TRK set-status 7 started
expect 0 "set started" "the other logical status maps to its own option"

# Another repo's #7 sitting EARLIER in the same project must not answer for ours.
fx_reset
jq '[{id: "item-other", status: "Delivered",
      content: {type: "Issue", number: 7, repository: "other/repo"}}] + .' \
  "$GH_DIR/items.json" > "$GH_DIR/t" && mv "$GH_DIR/t" "$GH_DIR/items.json"
run "$MAIN" $TRK set-status 7 delivered
expect 0 "set delivered" "a foreign #7 with the target status does not make it 'unchanged'"
[ "$(jq -r '[.[] | select(.id == "item-44")] | .[0].status' "$GH_DIR/items.json")" = Delivered ] \
  || fail "the target item was never edited"

fx_reset
run "$MAIN" $TRK set-status 8 delivered
expect 4 "is not in project 2" "an issue outside the project is not added silently"
run "$MAIN" $TRK set-status 7 merged
expect 4 "unknown logical status" "an unknown logical status is refused"

# ================================================================================================
# (4) create-followup: one issue per marker, PRs ignored, the hit may be on page 2
# ================================================================================================
fx_reset
body_file "$WORK/f.md" MARKER-F
run "$MAIN" $TRK create-followup --marker MARKER-F --title "Follow up" --body-file "$WORK/f.md"
expect 0 "created 100" "the follow-up is created"
run "$MAIN" $TRK create-followup --marker MARKER-F --title "Follow up" --body-file "$WORK/f.md"
expect 0 "exists 100" "a retry finds the follow-up by marker"
[ "$(creates)" = 1 ] || fail "the retry created a second issue ($(creates) creates)"

fx_reset
jq -n --arg g MARKER-G --arg h MARKER-H '([range(50)] | map({number: (200 + .),
    body: ("noise\n" + (if . == 44 then $g else "x" end))}))
  + [{number: 999, body: ("noise\n" + $h), pull_request: {url: "u"}}]' > "$GH_DIR/issues.json"
body_file "$WORK/f.md" MARKER-G
run "$MAIN" $TRK create-followup --marker MARKER-G --title "Follow up" --body-file "$WORK/f.md"
expect 0 "exists 244" "a marker on page 2 of the issue list is found"
[ "$(creates)" = 0 ] || fail "a found follow-up was created again"
body_file "$WORK/f.md" MARKER-H
run "$MAIN" $TRK create-followup --marker MARKER-H --title "Follow up" --body-file "$WORK/f.md"
expect 0 "created" "a PR carrying the marker is not a follow-up"
[ "$(creates)" = 1 ] || fail "the PR match suppressed the create"

# ================================================================================================
# (5) tracker=none: this adapter owns the L<n> counter, and `gh` is never called
# ================================================================================================
setprofile '.teams.tracker = "none"'
rm -rf "$MAIN/.agents/team"
: > "$GH_LOG"
run "$MAIN" $TRK read --brief '# Fix X
details here' --out "$WORK/n1"
expect 0 "key=L1 type=feature" "the first local ticket is L1"
has "title=Fix X" "$WORK/out" || fail "the title is not the first non-empty brief line"
jq -e '.key == "L1" and .labels == [] and .url == "" and (.body | test("details here"))' \
  "$WORK/n1/ticket.json" >/dev/null || fail "local ticket.json shape"
run "$MAIN" $TRK read --brief 'Fix Y' --out "$WORK/n2"
expect 0 "key=L2" "the counter advances"
[ "$(cat "$MAIN/.agents/team/local-ids")" = 2 ] || fail "local-ids is not 2"
[ ! -e "$MAIN/.agents/team/local-ids.lock" ] || fail "the allocation lock was not released"

printf 'From a file\n' > "$WORK/brief.md"
run "$MAIN" $TRK read --brief-file "$WORK/brief.md" --out "$WORK/n3"
expect 0 "title=From a file" "--brief-file is read"
run "$MAIN" $TRK read --out "$WORK/n4"
expect 1 "--brief" "read without a brief is refused"
run "$MAIN" $TRK read --brief '   ' --out "$WORK/n5"
expect 1 "empty" "an empty brief is refused"
run "$MAIN" $TRK read --brief-file "$WORK/nope.md" --out "$WORK/n6"
expect 1 "not readable" "an unreadable brief file is refused"
[ "$(cat "$MAIN/.agents/team/local-ids")" = 3 ] || fail "a refused read consumed an ID"

# A long brief must not die of SIGPIPE (pipefail + a filter that stops reading early → rc 141).
{ echo '# Big brief'; i=0
  while [ "$i" -lt 8000 ]; do echo "line $i padding padding padding padding padding"; i=$((i + 1))
  done; } > "$WORK/big.md"
run "$MAIN" $TRK read --brief-file "$WORK/big.md" --out "$WORK/nbig"
expect 0 "title=Big brief" "a ~400 KB brief is read whole"
[ "$(cat "$MAIN/.agents/team/local-ids")" = 4 ] || fail "the big brief did not get an ID"

# A garbage counter must be refused, not silently restarted at L1 (which would re-issue a live ID).
echo not-a-number > "$MAIN/.agents/team/local-ids"
run "$MAIN" $TRK read --brief 'Fix Z' --out "$WORK/ngarbage"
expect 2 "not a number" "a non-numeric counter is refused"
[ "$(cat "$MAIN/.agents/team/local-ids")" = not-a-number ] || fail "the refusal rewrote the counter"
[ ! -e "$MAIN/.agents/team/local-ids.lock" ] || fail "the refusal left the lock behind"
[ ! -e "$WORK/ngarbage/ticket.json" ] || fail "the refusal still wrote a ticket"
echo 4 > "$MAIN/.agents/team/local-ids"

run "$MAIN" $TRK comment L1 --marker MARKER-A --body-file "$WORK/c.md"
expect 0 "skipped (tracker=none)" "comment is a no-op for none"
run "$MAIN" $TRK set-status L1 delivered
expect 0 "skipped (tracker=none)" "set-status is a no-op for none"
run "$MAIN" $TRK create-followup --marker MARKER-A --title t --body-file "$WORK/c.md"
expect 0 "skipped (tracker=none)" "create-followup is a no-op for none"
[ ! -s "$GH_LOG" ] || { sed 's/^/  | /' "$GH_LOG"; fail "tracker=none called gh"; }

# ================================================================================================
# (6) tracker=jira: every op refuses, nothing touches gh
# ================================================================================================
setprofile '.'
: > "$GH_LOG"
run "$MAIN" $TRK read 7 --out "$WORK/j"
expect 3 "jira runs through the session's MCP" "jira read refused"
run "$MAIN" $TRK comment 7 --marker MARKER-A --body-file "$WORK/c.md"
expect 3 "no adapter op" "jira comment refused"
run "$MAIN" $TRK set-status 7 delivered
expect 3 "no adapter op" "jira set-status refused"
run "$MAIN" $TRK create-followup --marker MARKER-A --title t --body-file "$WORK/c.md"
expect 3 "no adapter op" "jira create-followup refused"
run "$MAIN" $TRK bogus-op
expect 2 "usage:" "an unknown op is a usage error"
[ ! -s "$GH_LOG" ] || { sed 's/^/  | /' "$GH_LOG"; fail "tracker=jira called gh"; }

echo "team-tracker-smoke: OK"
