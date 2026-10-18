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
        # The UNCERTAIN write: the issue really is created, then the client dies before it can read
        # the answer. The adapter must not conclude "nothing happened".
        [ "${STUB_GH_CREATE_THEN_FAIL:-0}" != 1 ] \
          || { echo "gh: timeout awaiting response headers" >&2; exit 1; }
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
        # Same uncertain write for comments: stored, then a non-zero exit (error/timeout).
        [ "${STUB_GH_POST_THEN_FAIL:-0}" != 1 ] \
          || { echo "gh: HTTP 502 after the write" >&2; exit 1; }
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

# Two comments carrying the SAME marker: `.[0]` would call one arbitrary duplicate "the" comment and
# let the intent go `done` over an unresolved mess. 0 → create · 1 → exists · >1 → exit 4, no write.
fx_reset
jq -n --arg m MARKER-DUP '[{id: 801, body: ("noise\n" + $m)}, {id: 802, body: ("noise\n" + $m)}]' \
  > "$GH_DIR/comments.json"
body_file "$WORK/c.md" MARKER-DUP
run "$MAIN" $TRK comment 7 --marker MARKER-DUP --body-file "$WORK/c.md"
expect 4 "matches 2 comments" "two comments with one marker is recoverable, not 'exists' of the first"
[ "$(posts)" = 0 ] || fail "the ambiguous comment match still posted"
[ "$(jq 'length' "$GH_DIR/comments.json")" = 2 ] || fail "the ambiguous match changed the comments"

# The UNCERTAIN WRITE: the POST stores the comment, then the command exits non-zero (error/timeout).
# The adapter must be recoverable (so the intent stays pending) and the retry must find exactly one
# comment — `exists`, not a second POST. Total comments on the issue: 1.
fx_reset
body_file "$WORK/c.md" MARKER-U
export STUB_GH_POST_THEN_FAIL=1
run "$MAIN" $TRK comment 7 --marker MARKER-U --body-file "$WORK/c.md"
unset STUB_GH_POST_THEN_FAIL
expect 4 "recoverable" "a POST that stored the comment but failed is recoverable, not 'created'"
[ "$(jq 'length' "$GH_DIR/comments.json")" = 1 ] || fail "the uncertain write stored no comment"

# A second-page read failure on the RETRY may not become a POST — the object already exists.
export STUB_GH_PAGE2_FAIL=1
jq '. + ([range(40)] | map({id: (1000 + .), body: "x"}))' "$GH_DIR/comments.json" > "$GH_DIR/t" \
  && mv "$GH_DIR/t" "$GH_DIR/comments.json"
run "$MAIN" $TRK comment 7 --marker MARKER-U --body-file "$WORK/c.md"
unset STUB_GH_PAGE2_FAIL
expect 4 "recoverable" "a failed page 2 on the retry is recoverable"
[ "$(posts)" = 1 ] || fail "the retry after an uncertain write posted again ($(posts) POSTs)"
jq '[.[] | select(.id < 1000)]' "$GH_DIR/comments.json" > "$GH_DIR/t" \
  && mv "$GH_DIR/t" "$GH_DIR/comments.json"
run "$MAIN" $TRK comment 7 --marker MARKER-U --body-file "$WORK/c.md"
expect 0 "exists" "the retry finds the comment the failed POST had stored"
[ "$(posts)" = 1 ] || fail "the recovered retry posted a second comment ($(posts) POSTs)"
[ "$(jq 'length' "$GH_DIR/comments.json")" = 1 ] || fail "the issue ended up with 2 comments"

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

# Two items for the SAME repo + number (a duplicated add): editing one of them at random is
# unrecoverable, so an ambiguous match is exit 4 with no item-edit at all.
fx_reset
jq '[{id: "item-dup", status: "Todo",
      content: {type: "Issue", number: 7, repository: "owner/repo"}}] + .' \
  "$GH_DIR/items.json" > "$GH_DIR/t" && mv "$GH_DIR/t" "$GH_DIR/items.json"
run "$MAIN" $TRK set-status 7 delivered
expect 4 "matches 2 items" "two project items for repo+number is recoverable, not an arbitrary edit"
[ "$(grep -c -- 'item-edit' "$GH_LOG" | tr -d ' ')" = 0 ] || fail "the ambiguous item match still edited"
[ "$(jq -r '[.[] | select(.status != "Todo")] | length' "$GH_DIR/items.json")" = 0 ] \
  || fail "the ambiguous item match moved a status"

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

# Same ambiguity rule as comments: two issues carrying one marker is exit 4, not `exists` of the first.
fx_reset
jq -n --arg m MARKER-DUP '[{number: 301, body: ("noise\n" + $m)}, {number: 302, body: ("noise\n" + $m)}]' \
  > "$GH_DIR/issues.json"
body_file "$WORK/f.md" MARKER-DUP
run "$MAIN" $TRK create-followup --marker MARKER-DUP --title "Follow up" --body-file "$WORK/f.md"
expect 4 "matches 2 issues" "two follow-ups with one marker is recoverable, not 'exists' of the first"
[ "$(creates)" = 0 ] || fail "the ambiguous follow-up match still created an issue"
[ "$(jq 'length' "$GH_DIR/issues.json")" = 2 ] || fail "the ambiguous match changed the issue list"

# The UNCERTAIN WRITE for create-followup: `gh issue create` stored the issue, then exited non-zero.
# Recoverable (intent stays pending); the retry finds exactly one issue → `exists`, total = 1.
fx_reset
body_file "$WORK/f.md" MARKER-U
export STUB_GH_CREATE_THEN_FAIL=1
run "$MAIN" $TRK create-followup --marker MARKER-U --title "Follow up" --body-file "$WORK/f.md"
unset STUB_GH_CREATE_THEN_FAIL
expect 4 "recoverable" "a create that stored the issue but failed is recoverable, not 'created'"
[ "$(jq 'length' "$GH_DIR/issues.json")" = 1 ] || fail "the uncertain create stored no issue"

# A failed page 2 on the retry may not become a second create.
export STUB_GH_PAGE2_FAIL=1
jq '. + ([range(40)] | map({number: (400 + .), body: "x"}))' "$GH_DIR/issues.json" > "$GH_DIR/t" \
  && mv "$GH_DIR/t" "$GH_DIR/issues.json"
run "$MAIN" $TRK create-followup --marker MARKER-U --title "Follow up" --body-file "$WORK/f.md"
unset STUB_GH_PAGE2_FAIL
expect 4 "recoverable" "a failed page 2 on the follow-up retry is recoverable"
[ "$(creates)" = 1 ] || fail "the follow-up retry created again ($(creates) creates)"
jq '[.[] | select(.number < 400)]' "$GH_DIR/issues.json" > "$GH_DIR/t" \
  && mv "$GH_DIR/t" "$GH_DIR/issues.json"
run "$MAIN" $TRK create-followup --marker MARKER-U --title "Follow up" --body-file "$WORK/f.md"
expect 0 "exists" "the retry finds the issue the failed create had stored"
[ "$(creates)" = 1 ] || fail "the recovered retry created a second issue ($(creates) creates)"
[ "$(jq 'length' "$GH_DIR/issues.json")" = 1 ] || fail "the repo ended up with 2 follow-ups"

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
# read/comment/status AND create-followup: not one gh call, and in particular no write of either kind.
[ ! -s "$GH_LOG" ] || { sed 's/^/  | /' "$GH_LOG"; fail "tracker=none called gh"; }
[ "$(posts)" = 0 ] || fail "tracker=none posted a comment"
[ "$(creates)" = 0 ] || fail "tracker=none create-followup called gh issue create"

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


# ================================================================================================
# (7) the ticket file end to end: read → team-new → clone, and every refusal around it
# ================================================================================================
# The base guard reads the COMMITTED profile, so each positive case needs its own published base —
# overwriting $P in the working tree is not enough.
publish_base() {  # publish_base <branch> <profile jq filter>
  git -C "$SEED" switch --quiet -C "$1" develop-netcore7
  smoke_profile "$2" > "$SEED/.claude/project-profile.json"
  git -C "$SEED" add .claude/project-profile.json
  git -C "$SEED" commit --quiet -m "base profile $1"
  git -C "$SEED" push --quiet --force origin "$1"
}
publish_base base-github ".teams.tracker = \"github\" | $GH_BLOCK"
publish_base base-none '.teams.tracker = "none"'
publish_base base-ghother \
  ".teams.tracker = \"github\" | $GH_BLOCK | .teams.github.project_id = \"PVT_other\""
publish_base base-notracker ".teams.tracker = \"github\" | $GH_BLOCK"
git -C "$SEED" rm --quiet .claude/lib/team-tracker.sh
git -C "$SEED" commit --quiet -m "no tracker adapter"
git -C "$SEED" push --quiet --force origin base-notracker
git -C "$SEED" switch --quiet develop-netcore7

no_clone() { [ ! -e "$WORK/main-$1" ] || fail "$2: a refused start left a clone behind"; }

github_profile
fx_reset
chmod 600 "$MAIN/.env"
rm -rf "$MAIN/.agents/team" "$WORK/main-alfa"
INC="$MAIN/.agents/team/incoming/alfa"
run "$MAIN" $TRK read 7 --out "$INC"
expect 0 "key=7 type=bugfix" "read into the incoming dir"

run "$MAIN" $NEW alfa 7 bugfix/7-fix-x origin/base-github --ticket-file "$INC/ticket.json"
expect 0 "branch:" "team-new takes a github ticket file"
has "bugfix/7-fix-x" "$WORK/out" || fail "team-new did not print the branch"
CLONE="$WORK/main-alfa"; TD="$CLONE/.agents/team"
jq -e '.branch == "bugfix/7-fix-x" and .tracker == "github" and .cost_key == "owner/repo#7"' \
  "$TD/team.json" >/dev/null || fail "team.json lacks branch/tracker/cost_key"
[ -f "$TD/ticket.json" ] && [ -f "$TD/ticket.md" ] || fail "the clone has no ticket files"
jq -e '.key == "7"' "$TD/ticket.json" >/dev/null || fail "the copied ticket.json is not #7"

setprofile '.'
run "$MAIN" $NEW beta TT-795 feature/TT-795-x origin/develop-netcore7 --ticket-file "$INC/ticket.json"
expect 1 "jira reads the ticket through MCP" "jira refuses a ticket file"
no_clone beta "jira + ticket file"

github_profile
run "$MAIN" $NEW beta 11 bugfix/11-other origin/base-github --ticket-file "$INC/ticket.json"
expect 1 "is not ticket 11" "a ticket file for another key is refused"
no_clone beta "key mismatch"
run "$MAIN" $NEW beta 7 bugfix/7-other origin/base-github
expect 1 "--ticket-file required for tracker=github" "github needs a ticket file"
no_clone beta "missing ticket file"
mkdir -p "$WORK/lonely" && cp "$INC/ticket.json" "$WORK/lonely/ticket.json"
run "$MAIN" $NEW beta 7 bugfix/7-other origin/base-github --ticket-file "$WORK/lonely/ticket.json"
expect 1 "no ticket.md next to" "a ticket.json without its ticket.md is refused"
no_clone beta "no ticket.md"
run "$MAIN" $NEW beta abc bugfix/abc-x origin/base-github --ticket-file "$INC/ticket.json"
expect 1 '^[0-9]+$' "a bad key is refused with the profile regex"
no_clone beta "bad key"

# The base must carry the adapter, the wrapup block and the SAME tracker/github block.
: > "$GH_LOG"
run "$MAIN" $NEW beta 7 bugfix/7-other origin/base-notracker --ticket-file "$INC/ticket.json"
expect 1 "cannot run tracker=github" "a base without the adapter is refused"
no_clone beta "base without the adapter"
run "$MAIN" $NEW beta 7 bugfix/7-other origin/develop-netcore7 --ticket-file "$INC/ticket.json"
expect 1 "cannot run tracker=github" "a base whose profile says jira is refused"
no_clone beta "base profile tracker=jira"
run "$MAIN" $NEW beta 7 bugfix/7-other origin/base-ghother --ticket-file "$INC/ticket.json"
expect 1 "cannot run tracker=github" "a base pointing at another project is refused"
no_clone beta "base github block differs"
[ ! -s "$GH_LOG" ] || { sed 's/^/  | /' "$GH_LOG"; fail "a refused start called gh" ; }

# tracker=none: the adapter allocates the key, team-new takes it from the file.
setprofile '.teams.tracker = "none"'
run "$MAIN" $TRK read --brief '# Local work
details' --out "$MAIN/.agents/team/incoming/gamma"
expect 0 "key=L1" "the local ticket is allocated"
run "$MAIN" $NEW gamma L1 feature/L1-local origin/base-none \
  --ticket-file "$MAIN/.agents/team/incoming/gamma/ticket.json"
expect 0 "branch:" "team-new takes a local ticket file"
jq -e --arg ck "$(basename "$MAIN"):L1" '.tracker == "none" and .cost_key == $ck' \
  "$WORK/main-gamma/.agents/team/team.json" >/dev/null || fail "none team.json tracker/cost_key"
[ -f "$WORK/main-gamma/.agents/team/ticket.md" ] || fail "the none clone has no ticket.md"

# ================================================================================================
# (8) prompt rendering: a legacy clone is untouched, github/none render with no keys left
# ================================================================================================
# A clone on cfe9f9a has no {{TRACKER_*}} and no .claude/team/tracker/ — the helper from the main
# checkout must leave its prompts byte for byte alone.
mkdir -p "$WORK/legacy"
git -C "$SRC" show cfe9f9a:.claude/team/prompts/wrapup.md > "$WORK/legacy/wrapup.md"
set +e
( . "$MAIN/.claude/lib/team-tracker-render.sh"
  printf '%s\n' "$(team_tracker_render "" "$WORK/legacy/no-such-dir" \
    "$(cat "$WORK/legacy/wrapup.md")")" ) > "$WORK/legacy/out" 2>&1
RC=$?
set -e
[ "$RC" = 0 ] || { sed 's/^/  | /' "$WORK/legacy/out"; fail "legacy render exited $RC"; }
cmp -s "$WORK/legacy/out" "$WORK/legacy/wrapup.md" || fail "legacy render changed the prompt"

render_all() {  # render_all <tracker> <out file>
  ( . "$MAIN/.claude/lib/team-tracker-render.sh"
    for p in planner planner-quick cli coder qa wrapup; do
      team_tracker_render "$1" "$MAIN/.claude/team/tracker" \
        "$(cat "$MAIN/.claude/team/prompts/$p.md")" || exit 1
      echo
    done ) > "$2"
}
for t in github none jira; do
  render_all "$t" "$WORK/r-$t" || fail "render for tracker=$t failed"
  sed -E 's/\{\{(TEAM|TICKET|BRANCH|LINE|BASE_SHA|RUN|ATTEMPT|PLAN|SPEC|PR|ORG_URL|QA_REPORT|BUILD_CHECK|TEST_GATE|PR_HOST_KIND|PR_HOST|PR_CREATE|PR_CREATE_READY|PR_PUBLISH|PR_BODY_GET|PR_BODY_SET|PR_TOOL|GATES_NOTE)\}\}/x/g' \
    "$WORK/r-$t" > "$WORK/r-$t.x"
  if [ "$t" != jira ]; then
    ! grep -q '{{' "$WORK/r-$t.x" || { grep -o '{{[A-Z_]*}}' "$WORK/r-$t.x" | sort -u | sed 's/^/  | /'
      fail "tracker=$t left unrendered keys"; }
  fi
done
has '/brainstorm .agents/team/ticket.md' "$WORK/r-github" || fail "github planner lost the task path"
has '/brainstorm .agents/team/ticket.md' "$WORK/r-none" || fail "none planner lost the task path"
has '/brainstorm {{TICKET}}' "$WORK/r-jira" || fail "jira planner no longer reads the key"
has 'mcp__atlassian__jira_get_issue' "$WORK/r-jira" || fail "jira render lost the MCP read"
! grep -q 'mcp__atlassian__' "$WORK/r-github" || fail "github render still calls Jira over MCP"

# ================================================================================================
# (9) never Done: the runner refuses a wrapup record whose tracker intents are not finished
# ================================================================================================
github_profile
fx_reset
RUN_ID=alfa-20261018-000001
RD="$TD/runs/$RUN_ID"; mkdir -p "$RD"; printf '%s\n' "$RUN_ID" > "$TD/run"
mkdir -p "$CLONE/.agents/plans/done"; printf 'plan\n' > "$CLONE/.agents/plans/done/accepted.md"
git -C "$CLONE" add .agents/plans/done/accepted.md
git -C "$CLONE" commit --quiet -m "accepted plan"
REV="$(git -C "$CLONE" rev-parse HEAD)"
for role in planner coder qa wrapup; do mkrec "$role" "$REV"; done
session wrapup 1 ""      # mkrec writes an empty input_rev; check_common compares them
printf 'target_rev: %s\n' "$REV" > "$RD/wrapup-1.md"
WREC="$RD/wrapup-1-1.json"

# The intent identity the prompt must write BEFORE any external op. The four TG_* globals default to
# this run's real target; a negative fixture overrides one of them. TG_LOGICAL covers the
# `started instead of delivered` case, TG_TARGET a missing/malformed `target` object.
# TG_MARKER_RUN is the run the markers were MINTED from — deliberately separate from TG_RUN (the
# stored `target.run`), so a fixture can relabel `target` while the markers stay foreign.
# TG_MARKER deforms the comment marker itself: ok | none (key absent) | null | empty | wrongid |
# substr (a foreign run that CONTAINS this one) | suffix (the right marker plus trailing text).
tg_reset() {
  TG_RUN="$RUN_ID"; TG_TICKET='"7"'; TG_REPO='"owner/repo"'; TG_PROJ='"PVT_x"'
  TG_LOGICAL=delivered; TG_TARGET=ok; TG_MARKER_RUN="$RUN_ID"; TG_MARKER=ok
}
tg_reset

ws() {  # ws <comment state> <set-status state> [accepted draft: 0|1] [create state]
  jq -n --arg c "$1" --arg s "$2" --argjson d "${3:-0}" --arg cs "${4:-pending}" \
    --arg run "$TG_RUN" --argjson tk "$TG_TICKET" --argjson repo "$TG_REPO" \
    --argjson proj "$TG_PROJ" --arg lg "$TG_LOGICAL" --arg tgt "$TG_TARGET" \
    --arg mr "$TG_MARKER_RUN" --arg mm "$TG_MARKER" \
    '{drafts: (if $d == 1 then {"create-1": {accepted: true, title: "t", body: "b"}} else {} end),
      intents: ({"comment-1": ({op: "comment", state: $c}
        + (if $mm == "none" then {}
           elif $mm == "null" then {marker: null}
           elif $mm == "empty" then {marker: ""}
           elif $mm == "wrongid" then {marker: ("[wrapup " + $mr + " comment-2]")}
           elif $mm == "substr" then {marker: ("[wrapup " + $mr + "0 comment-1]")}
           elif $mm == "suffix" then {marker: ("[wrapup " + $mr + " comment-1] and more")}
           else {marker: ("[wrapup " + $mr + " comment-1]")} end)),
                 "set-status-delivered": {op: "set-status", logical: $lg, state: $s}}
        + (if $d == 1 then {"create-1": {op: "create", draft_id: "create-1",
             marker: ("[wrapup " + $mr + " create-1]"), state: $cs}} else {} end))}
     + (if $tgt == "missing" then {}
        elif $tgt == "malformed" then {target: "alfa-20261018-000001"}
        else {target: {run: $run, ticket: $tk, repo: $repo, project_id: $proj}} end)' \
    > "$RD/wrapup-state.json"
}

# The prompt posted its comment for real; the status write was denied, so its intent is pending.
body_file "$WORK/tc.md" "[wrapup $RUN_ID comment-1]"
run "$MAIN" $TRK comment 7 --marker "[wrapup $RUN_ID comment-1]" --body-file "$WORK/tc.md"
expect 0 "created" "the wrapup comment is posted once"
ws done pending
run "$MAIN" $TR alfa check "$WREC"
expect 4 "validation failed: tracker=github" "a pending set-status intent is never Done"

# Recovery: the same marker finds the existing comment, the status write succeeds, and the record
# gets past the tracker gate (it then stops at check_pushed, as in smoke-3).
run "$MAIN" $TRK comment 7 --marker "[wrapup $RUN_ID comment-1]" --body-file "$WORK/tc.md"
expect 0 "exists" "the retry reuses the posted comment"
run "$MAIN" $TRK set-status 7 delivered
expect 0 "set delivered" "the denied status write succeeds on recovery"
[ "$(posts)" = 1 ] || fail "the wrapup posted $(posts) comments"
ws done done
run "$MAIN" $TR alfa check "$WREC"
[ "$RC" = 4 ] || fail "the recovered record should still stop at check_pushed, got $RC"
! has "tracker=github" "$WORK/out" || fail "the tracker gate still refuses a finished state"
has "origin bugfix/7-fix-x" "$WORK/out" || fail "validation did not reach check_pushed"

# check_wrapup_tracker on its own — in a SUBSHELL: team-validate.sh defines its own fail() and
# would otherwise replace the suite's (exit) with a return, so later assertions would not stop.
# The trusted context is exactly the runner's: the profile from the MAIN checkout, team.json from
# the CLONE's cwd, RUN from the runner global — never from the file under judgement.
ck() {  # ck <expected rc> <tracker> <label>
  set +e
  ( cd "$CLONE"
    . "$CLONE/.claude/lib/team-lib.sh"
    . "$MAIN/.claude/lib/team-profile.sh"; team_profile_load "$MAIN"
    . "$MAIN/.claude/lib/team-validate.sh"
    RUN="$RUN_ID"
    check_wrapup_tracker "$RD/wrapup-state.json" "$2" ) > "$WORK/out" 2>&1
  RC=$?; set -e
  [ "$RC" = "$1" ] || fail "$3: rc $RC, expected $1"
}
ws done pending;      ck 1 github "a pending set-status"
ws pending done;      ck 1 github "a pending comment"
ws done done;         ck 0 github "both intents done"
ws done done 1 pending; ck 1 github "an accepted follow-up still pending"
ws done done 1 done;    ck 0 github "an accepted follow-up done"

# ---- intent identity: finished intents of ANOTHER target must never carry this run to Done ------
TG_RUN=alfa-20261017-999999; ws done done
ck 1 github "a previous run's finished state"
has "is not this run's" "$WORK/out" || fail "the identity refusal does not name the mismatch"
tg_reset
TG_TICKET='"999"'; ws done done; ck 1 github "another ticket's finished state"
tg_reset
TG_REPO='"other/repo"'; ws done done; ck 1 github "another repo's finished state"
tg_reset
TG_PROJ='"PVT_other"'; ws done done; ck 1 github "another project's finished state"
tg_reset
TG_LOGICAL=started; ws done done; ck 1 github "set-status started instead of delivered"
tg_reset
TG_TARGET=missing; ws done done; ck 1 github "a state file with no target identity"
tg_reset
TG_TARGET=malformed; ws done done; ck 1 github "a target that is not an object"
tg_reset
# Astra's reproducer, issue #4 acceptance review: run=OLD-RUN, ticket=999, repo=other/repo with a
# done comment and delivered/done status returned rc 0 before this gate existed.
TG_RUN=OLD-RUN; TG_TICKET='"999"'; TG_REPO='"other/repo"'; ws done done
ck 1 github "Astra's reproducer: OLD-RUN/999/other/repo is rejected"
tg_reset
# The ORDER matters (codex, fix round 4b): if the prompt wrote the current `target` first and only
# then judged the file foreign, a previous run's finished intents would be relabelled as this run's
# and validate. `target` alone is not identity — the markers of the `done` intents are minted from
# {{RUN}}, so a relabelled foreign state is still refused.
TG_MARKER_RUN=alfa-20261017-999999; ws done done
ck 1 github "a foreign state with target rewritten to this run is still rejected"
has "without the exact marker [wrapup $RUN_ID" "$WORK/out" \
  || fail "the relabel refusal does not name the expected marker of this run"
TG_MARKER_RUN=alfa-20261017-999999; ws done done 1 done
ck 1 github "a relabelled foreign follow-up intent is rejected too"
tg_reset

# ---- the marker of a done comment/create must match EXACTLY ------------------------------------
# Astra's second reproducer (issue #4 fix review): a `done` comment with NO marker scored rc 0,
# because the marker rule skipped marker-less intents and `any(comment done)` then accepted them;
# and `[wrapup RUN-10 comment-1]` passed under RUN-1, since `contains` matches a substring.
TG_MARKER=none; ws done done
ck 1 github "Astra's reproducer: a done comment with no marker at all is rejected"
has "without the exact marker" "$WORK/out" || fail "the marker refusal is not explicit"
has "comment-1 marker=<none>" "$WORK/out" || fail "the marker refusal does not name the intent"
tg_reset
TG_MARKER=null; ws done done;  ck 1 github "a done comment with a null marker is rejected"
tg_reset
TG_MARKER=empty; ws done done; ck 1 github "a done comment with an empty marker is rejected"
tg_reset
TG_MARKER=wrongid; ws done done
ck 1 github "a done comment carrying another intent's marker id is rejected"
tg_reset
# RUN-1 is a substring of RUN-10: the whole point of an exact comparison.
TG_MARKER=substr; ws done done
ck 1 github "Astra's reproducer: a foreign run that contains this one as a substring is rejected"
tg_reset
TG_MARKER=suffix; ws done done
ck 1 github "the exact marker plus trailing text is not the marker"
tg_reset
# A done follow-up intent is held to the same rule, by its own stable intent id.
TG_MARKER_RUN="$RUN_ID"; ws done done 1 done
ck 0 github "a correctly marked comment and follow-up still validate"
jq '.intents["create-1"] |= del(.marker)' "$RD/wrapup-state.json" > "$RD/t" \
  && mv "$RD/t" "$RD/wrapup-state.json"
ck 1 github "a done follow-up with no marker is rejected"
has "create-1 marker=<none>" "$WORK/out" || fail "the follow-up refusal does not name the intent"
jq '.intents["create-1"].marker = "[wrapup other-run create-1]"' "$RD/wrapup-state.json" > "$RD/t" \
  && mv "$RD/t" "$RD/wrapup-state.json"
ck 1 github "a done follow-up marked with another run is rejected"
# set-status keeps its own rules: it carries no marker and must not be asked for one.
ws done done
jq -e '.intents["set-status-delivered"] | has("marker") | not' "$RD/wrapup-state.json" >/dev/null \
  || fail "the fixture gave set-status a marker"
ck 0 github "a marker-less set-status intent is still fine"
# A PENDING comment may legitimately have no marker yet — only `done` is held to the format.
TG_MARKER=none; ws pending done
ck 1 github "a pending comment with no marker is refused for being pending, not for the marker"
! has "without the exact marker" "$WORK/out" || fail "a pending intent was judged on its marker"
tg_reset
# jira and none are unaffected by the identity gate — they have no intents at all.
ws done done; ck 0 github "the matching target still validates"
TG_RUN=OLD-RUN; TG_TICKET='"999"'; TG_REPO='"other/repo"'; ws pending pending
ck 0 none "none ignores a foreign state file"
ck 0 jira "jira ignores a foreign state file"
ck 0 "" "a pre-2b team.json ignores a foreign state file"
tg_reset

rm -f "$RD/wrapup-state.json"
ck 1 github "a missing state file"
ck 0 none "none needs no intents"
ck 0 jira "jira needs no intents"
ck 0 "" "a pre-2b team.json needs no intents"

# ---- the durable record of a failed `set-status started` (/start-team 4b) -----------------------
run "$MAIN" bash .claude/lib/team-warn.sh alfa "status started not set — HTTP 403"
expect 0 "warning recorded" "team-warn.sh records a started failure in the clone's team.json"
jq -e '(.warnings | length) == 1 and (.warnings[0].text | test("status started not set"))
  and (.warnings[0].at | test("^[0-9]{4}-"))' "$TD/team.json" >/dev/null \
  || fail "team.json carries no warnings[] entry"
jq -e '.ticket == "7" and .branch == "bugfix/7-fix-x"' "$TD/team.json" >/dev/null \
  || fail "team-warn.sh damaged team.json"
run "$MAIN" bash .claude/lib/team-warn.sh alfa "second one"
expect 0 "warning recorded" "warnings[] is append-only"
[ "$(jq '.warnings | length' "$TD/team.json")" = 2 ] || fail "the second warning replaced the first"
run "$MAIN" $TR alfa status
expect 0 "warn: status started not set" "team-run.sh status surfaces the durable warning"
run "$MAIN" bash .claude/lib/team-warn.sh alfa
expect 2 "usage:" "team-warn.sh needs a text"
run "$MAIN" bash .claude/lib/team-warn.sh nosuchteam "x"
expect 1 "no team clone" "team-warn.sh refuses a team without a clone"

# The write itself failing is what /start-team step 4b must STOP on: a non-zero exit, and team.json
# left exactly as it was (no truncation by a half-finished `>`). A read-only team dir is the cheapest
# way to make both the temp file and the mv impossible.
cp "$TD/team.json" "$WORK/warn-before.json"
chmod 500 "$TD"
run "$MAIN" bash .claude/lib/team-warn.sh alfa "this write must fail"
chmod 700 "$TD"
[ "$RC" != 0 ] || fail "team-warn.sh reported success on an unwritable team dir"
cmp -s "$WORK/warn-before.json" "$TD/team.json" || fail "the failed warn write changed team.json"
[ ! -e "$TD/team.json.new" ] || fail "the failed warn write left a temp file behind"
[ "$(jq '.warnings | length' "$TD/team.json")" = 2 ] || fail "the failed warn write touched warnings[]"

jq 'del(.warnings)' "$TD/team.json" > "$TD/t" && mv "$TD/t" "$TD/team.json"


# ================================================================================================
# (10) --ticket-file argument hygiene (codex review of Step 2)
# ================================================================================================
# A watchdog, not `timeout`: macOS has no coreutils timeout, and a regressed `shift 2 || true`
# would spin forever instead of failing the suite.
timed() {  # timed <secs> <dir> <cmd...> → RC ("timeout" when it had to be killed), $WORK/out
  local t="$1" d="$2" pid w=0; shift 2
  set +e
  ( cd "$d" && "$@" ) > "$WORK/out" 2>&1 &
  pid=$!
  while kill -0 "$pid" 2>/dev/null && [ "$w" -lt "$t" ]; do sleep 1; w=$((w + 1)); done
  if kill -0 "$pid" 2>/dev/null; then
    kill -9 "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; RC=timeout
  else
    wait "$pid"; RC=$?
  fi
  set -e
}

github_profile
fx_reset
for sc in team-new team-next; do
  timed 10 "$MAIN" bash ".claude/lib/$sc.sh" alfa 7 bugfix/7-fix-x origin/base-github --ticket-file
  [ "$RC" != timeout ] || fail "$sc.sh hangs on a value-less --ticket-file"
  expect 2 "--ticket-file needs a path" "$sc.sh refuses a value-less --ticket-file"
done

# A valid object followed by garbage must refuse the whole file, not pass on the first .key.
mkdir -p "$WORK/badjson"
printf '{"key": "7"}\nnot json at all\n' > "$WORK/badjson/ticket.json"
cp "$INC/ticket.md" "$WORK/badjson/ticket.md"
run "$MAIN" $NEW beta 7 bugfix/7-other origin/base-github --ticket-file "$WORK/badjson/ticket.json"
expect 1 "is not readable JSON with a .key" "trailing garbage in the ticket file is refused"
no_clone beta "garbage ticket file"

# A ticket file inside the clone's own .agents/team/ would be archived by team-next before it is
# copied — the preflight refuses it, and the clone stays on its old ticket untouched.
rm -rf "$WORK/main-delta"
run "$MAIN" $NEW delta 7 bugfix/7-next-a origin/base-github --ticket-file "$INC/ticket.json"
expect 0 "branch:" "a clone for the team-next case"
DTD="$WORK/main-delta/.agents/team"
run "$MAIN" $TRK read 11 --out "$DTD/incoming-bad"
expect 0 "key=11" "a ticket read into the clone's team dir"
cp "$DTD/team.json" "$WORK/delta-team.json"
run "$MAIN" bash .claude/lib/team-next.sh delta 11 bugfix/11-next-b origin/base-github \
  --ticket-file "$DTD/incoming-bad/ticket.json"
expect 1 "keep it outside the team dir" "a ticket file inside the team dir is refused"
[ "$(git -C "$WORK/main-delta" rev-parse --abbrev-ref HEAD)" = bugfix/7-next-a ] \
  || fail "the refused team-next switched the branch anyway"
cmp -s "$WORK/delta-team.json" "$DTD/team.json" || fail "the refused team-next rewrote team.json"
[ ! -d "$DTD/archive" ] || fail "the refused team-next archived the previous run"
[ -f "$DTD/ticket.json" ] || fail "the refused team-next lost the original ticket"

# ================================================================================================
# (11) team-run summary: /monitor's only source for the tracker, the ticket title and its link
# ================================================================================================
# /monitor must never read clone files, so whatever it prints about the ticket comes from here.
github_profile
run "$MAIN" $TR alfa summary
expect 0 "tracker: github" "the summary of a github clone names its tracker"
has "title: Fix the thing" "$WORK/out" || fail "the summary has no ticket title"
has "url: https://github.com/owner/repo/issues/7" "$WORK/out" || fail "the summary has no ticket URL"

setprofile '.'
rm -rf "$WORK/main-beta"
run "$MAIN" $NEW beta TT-795 feature/TT-795-x origin/develop-netcore7
expect 0 "branch:" "a jira clone for the summary case"
run "$MAIN" $TR beta summary
expect 0 "tracker: jira" "a jira clone reports tracker: jira"
has "title: " "$WORK/out" || fail "the jira summary has no title line"
[ "$(grep -c '^title: .' "$WORK/out")" = 0 ] || fail "jira must leave the title to MCP, not fill it"
[ "$(grep -c '^url: .' "$WORK/out")" = 0 ] || fail "jira must leave the url empty"

echo "team-tracker-smoke: OK"
