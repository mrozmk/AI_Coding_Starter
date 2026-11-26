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

# ---- the gh stub (shared with team-tracker-sync-smoke.sh) -------------------------------------
. "$(dirname "${BASH_SOURCE[0]}")/gh-stub.sh"
gh_stub_install

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
grep -q "^project: exists" "$WORK/out" || fail "the retry did not report the board entry ($(cat "$WORK/out"))"
jq -e 'any(.[]; .content.number == 100)' "$GH_DIR/items.json" >/dev/null || fail "the follow-up is not on the board"

# The board half: added after `created`, a failed add is a warning (exit 0, no second issue), its
# retry adds it; without Project fields it is skipped.
fx_reset
body_file "$WORK/f.md" MARKER-P
run "$MAIN" $TRK create-followup --marker MARKER-P --title "Follow up" --body-file "$WORK/f.md"
expect 0 "project: added" "created is followed by the project add"
fx_reset
body_file "$WORK/f.md" MARKER-Q
export STUB_GH_ITEMADD_FAIL=1
run "$MAIN" $TRK create-followup --marker MARKER-Q --title "Follow up" --body-file "$WORK/f.md"
unset STUB_GH_ITEMADD_FAIL
expect 0 "warning: project add failed for #" "a failed project add is a warning, exit 0"
grep -q "^created " "$WORK/out" || fail "the failed add hid the created line"
[ "$(creates)" = 1 ] || fail "a failed project add created $(creates) issues"
run "$MAIN" $TRK create-followup --marker MARKER-Q --title "Follow up" --body-file "$WORK/f.md"
expect 0 "project: added" "the retry finds the issue and adds it to the board"
grep -q "^exists " "$WORK/out" || fail "the retry did not find the issue"
[ "$(creates)" = 1 ] || fail "the retry created a second issue"

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
  git -C "$SEED" switch --quiet -C "$1" develop
  smoke_profile "$2" > "$SEED/.claude/project-profile.json"
  git -C "$SEED" add .claude/project-profile.json
  git -C "$SEED" commit --quiet -m "base profile $1"
  git -C "$SEED" push --quiet --force origin "$1"
}
publish_base base-github ".teams.tracker = \"github\" | $GH_BLOCK"
publish_base base-none '.teams.tracker = "none"'
publish_base base-ghother \
  ".teams.tracker = \"github\" | $GH_BLOCK | .teams.github.project_id = \"PVT_other\""
# The same blocks at the TOP level (no teams.github): the guard must compare those, not {} with {}.
TOP_BLOCK="${GH_BLOCK/.teams.github =/.github =}"
publish_base base-ghtopother \
  ".teams.tracker = \"github\" | $TOP_BLOCK | .github.project_id = \"PVT_other\""
publish_base base-notracker ".teams.tracker = \"github\" | $GH_BLOCK"
git -C "$SEED" rm --quiet .claude/lib/team-tracker.sh
git -C "$SEED" commit --quiet -m "no tracker adapter"
git -C "$SEED" push --quiet --force origin base-notracker
git -C "$SEED" switch --quiet develop

no_clone() { [ ! -e "$WORK/main-$1" ] || fail "$2: a refused start left a clone behind"; }

github_profile
fx_reset
chmod 600 "$MAIN/.env"
rm -rf "$MAIN/.agents/team" "$WORK/main-alfa"
INC="$MAIN/.agents/team/incoming/alfa"
run "$MAIN" $TRK read 7 --out "$INC"
expect 0 "key=7 type=bugfix" "read into the incoming dir"

run "$MAIN" $NEW alfa 7 bugfix/7-fix-x origin/base-github brainstorm --ticket-file "$INC/ticket.json"
expect 0 "branch:" "team-new takes a github ticket file"
has "bugfix/7-fix-x" "$WORK/out" || fail "team-new did not print the branch"
CLONE="$WORK/main-alfa"; TD="$CLONE/.agents/team"
jq -e '.branch == "bugfix/7-fix-x" and .tracker == "github" and .cost_key == "owner/repo#7"' \
  "$TD/team.json" >/dev/null || fail "team.json lacks branch/tracker/cost_key"
[ -f "$TD/ticket.json" ] && [ -f "$TD/ticket.md" ] || fail "the clone has no ticket files"
jq -e '.key == "7"' "$TD/ticket.json" >/dev/null || fail "the copied ticket.json is not #7"

setprofile '.'
run "$MAIN" $NEW beta AB-795 feature/AB-795-x origin/develop brainstorm --ticket-file "$INC/ticket.json"
expect 1 "jira reads the ticket through MCP" "jira refuses a ticket file"
no_clone beta "jira + ticket file"

github_profile
run "$MAIN" $NEW beta 11 bugfix/11-other origin/base-github brainstorm --ticket-file "$INC/ticket.json"
expect 1 "is not ticket 11" "a ticket file for another key is refused"
no_clone beta "key mismatch"
run "$MAIN" $NEW beta 7 bugfix/7-other origin/base-github brainstorm
expect 1 "--ticket-file required for tracker=github" "github needs a ticket file"
no_clone beta "missing ticket file"
mkdir -p "$WORK/lonely" && cp "$INC/ticket.json" "$WORK/lonely/ticket.json"
run "$MAIN" $NEW beta 7 bugfix/7-other origin/base-github brainstorm --ticket-file "$WORK/lonely/ticket.json"
expect 1 "no ticket.md next to" "a ticket.json without its ticket.md is refused"
no_clone beta "no ticket.md"
run "$MAIN" $NEW beta abc bugfix/abc-x origin/base-github brainstorm --ticket-file "$INC/ticket.json"
expect 1 '^[0-9]+$' "a bad key is refused with the profile regex"
no_clone beta "bad key"

# The base must carry the adapter, the wrapup block and the SAME tracker/github block.
: > "$GH_LOG"
run "$MAIN" $NEW beta 7 bugfix/7-other origin/base-notracker brainstorm --ticket-file "$INC/ticket.json"
expect 1 "cannot run tracker=github" "a base without the adapter is refused"
no_clone beta "base without the adapter"
run "$MAIN" $NEW beta 7 bugfix/7-other origin/develop brainstorm --ticket-file "$INC/ticket.json"
expect 1 "cannot run tracker=github" "a base whose profile says jira is refused"
no_clone beta "base profile tracker=jira"
run "$MAIN" $NEW beta 7 bugfix/7-other origin/base-ghother brainstorm --ticket-file "$INC/ticket.json"
expect 1 "cannot run tracker=github" "a base pointing at another project is refused"
no_clone beta "base github block differs"
setprofile ".teams.tracker = \"github\" | $TOP_BLOCK"
run "$MAIN" $NEW beta 7 bugfix/7-other origin/base-ghtopother brainstorm --ticket-file "$INC/ticket.json"
expect 1 "cannot run tracker=github" "a base whose top-level github block differs is refused"
no_clone beta "base top-level github block differs"
github_profile
[ ! -s "$GH_LOG" ] || { sed 's/^/  | /' "$GH_LOG"; fail "a refused start called gh" ; }

# tracker=none: the adapter allocates the key, team-new takes it from the file.
setprofile '.teams.tracker = "none"'
run "$MAIN" $TRK read --brief '# Local work
details' --out "$MAIN/.agents/team/incoming/gamma"
expect 0 "key=L1" "the local ticket is allocated"
run "$MAIN" $NEW gamma L1 feature/L1-local origin/base-none brainstorm \
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
  sed -E 's/\{\{(TEAM|TICKET|BRANCH|LINE|BASE_SHA|RUN|RUN_DIR|ROUND|REWORK|ATTEMPT|PLAN|SPEC|PR|ORG_URL|QA_REPORT|BUILD_CHECK|TEST_GATE|PR_HOST_KIND|PR_HOST|PR_CREATE|PR_CREATE_READY|PR_PUBLISH|PR_BODY_GET|PR_BODY_SET|PR_TOOL|GATES_NOTE|ORIGIN_TICKET)\}\}/x/g' \
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
# Reviewer's reproducer, issue #4 acceptance review: run=OLD-RUN, ticket=999, repo=other/repo with a
# done comment and delivered/done status returned rc 0 before this gate existed.
TG_RUN=OLD-RUN; TG_TICKET='"999"'; TG_REPO='"other/repo"'; ws done done
ck 1 github "Reviewer's reproducer: OLD-RUN/999/other/repo is rejected"
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
# Reviewer's second reproducer (issue #4 fix review): a `done` comment with NO marker scored rc 0,
# because the marker rule skipped marker-less intents and `any(comment done)` then accepted them;
# and `[wrapup RUN-10 comment-1]` passed under RUN-1, since `contains` matches a substring.
TG_MARKER=none; ws done done
ck 1 github "Reviewer's reproducer: a done comment with no marker at all is rejected"
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
ck 1 github "Reviewer's reproducer: a foreign run that contains this one as a substring is rejected"
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
run "$MAIN" $NEW beta 7 bugfix/7-other origin/base-github brainstorm --ticket-file "$WORK/badjson/ticket.json"
expect 1 "is not readable JSON with a .key" "trailing garbage in the ticket file is refused"
no_clone beta "garbage ticket file"

# A ticket file inside the clone's own .agents/team/ would be archived by team-next before it is
# copied — the preflight refuses it, and the clone stays on its old ticket untouched.
rm -rf "$WORK/main-delta"
run "$MAIN" $NEW delta 7 bugfix/7-next-a origin/base-github brainstorm --ticket-file "$INC/ticket.json"
expect 0 "branch:" "a clone for the team-next case"
DTD="$WORK/main-delta/.agents/team"
run "$MAIN" $TRK read 11 --out "$DTD/incoming-bad"
expect 0 "key=11" "a ticket read into the clone's team dir"
cp "$DTD/team.json" "$WORK/delta-team.json"
run "$MAIN" bash .claude/lib/team-next.sh delta 11 bugfix/11-next-b origin/base-github brainstorm \
  --ticket-file "$DTD/incoming-bad/ticket.json"
expect 1 "keep it outside the team dir" "a ticket file inside the team dir is refused"
[ "$(git -C "$WORK/main-delta" rev-parse --abbrev-ref HEAD)" = bugfix/7-next-a ] \
  || fail "the refused team-next switched the branch anyway"
cmp -s "$WORK/delta-team.json" "$DTD/team.json" || fail "the refused team-next rewrote team.json"
[ ! -d "$DTD/archive" ] || fail "the refused team-next archived the previous run"
[ -f "$DTD/ticket.json" ] || fail "the refused team-next lost the original ticket"

# ================================================================================================
# (11) team-run summary: the Supervisor's read-only source for the tracker, the ticket title and its link
# ================================================================================================
# a supervision session never reads clone files, so whatever it prints about the ticket comes from here.
github_profile
run "$MAIN" $TR alfa summary
expect 0 "tracker: github" "the summary of a github clone names its tracker"
has "title: Fix the thing" "$WORK/out" || fail "the summary has no ticket title"
has "url: https://github.com/owner/repo/issues/7" "$WORK/out" || fail "the summary has no ticket URL"

setprofile '.'
rm -rf "$WORK/main-beta"
run "$MAIN" $NEW beta AB-795 feature/AB-795-x origin/develop brainstorm
expect 0 "branch:" "a jira clone for the summary case"
run "$MAIN" $TR beta summary
expect 0 "tracker: jira" "a jira clone reports tracker: jira"
has "title: " "$WORK/out" || fail "the jira summary has no title line"
[ "$(grep -c '^title: .' "$WORK/out")" = 0 ] || fail "jira must leave the title to MCP, not fill it"
[ "$(grep -c '^url: .' "$WORK/out")" = 0 ] || fail "jira must leave the url empty"

# ================================================================================================
# (12) list / show: the read-only views /tasks-status builds on — full enumeration, no writes
# ================================================================================================
github_profile
fx_reset
# 34 open issues + 1 PR over two pages; #7 sits on page 2, and on the board at position 45.
jq -n '[range(33)] | map({number: (500 + .), title: ("Issue " + (. | tostring)),
    updated_at: "2026-11-01T10:00:00Z", assignees: [], labels: [], html_url: "u"})
  + [{number: 7, title: "Fix the thing", updated_at: "2026-11-02T10:00:00Z",
      assignees: [{login: "dev"}], labels: [{name: "bug"}], html_url: "https://x/7"},
     {number: 1001, title: "On the board twice", updated_at: "", assignees: [], labels: []},
     {number: 600, title: "A pull request", pull_request: {url: "p"}}]' > "$GH_DIR/issues.json"
jq '[{id: "item-dup", status: "Delivered",
      content: {type: "Issue", number: 1001, repository: "owner/repo"}}] + .' \
  "$GH_DIR/items.json" > "$GH_DIR/t" && mv "$GH_DIR/t" "$GH_DIR/items.json"
run "$MAIN" $TRK list --out "$WORK/list.json"
expect 0 "items=35" "list returns every open issue across pages, PRs dropped"
jq -e '.tracker == "github" and .repo == "owner/repo" and .statuses == ["In Progress", "Delivered"]' \
  "$WORK/list.json" >/dev/null || fail "list header / status order"
jq -e '[.items[] | select(.key == "7")][0] | .status == "Todo" and .on_board == 1
    and .assignees == ["dev"] and .labels == ["bug"] and .updated == "2026-11-02T10:00:00Z"' \
  "$WORK/list.json" >/dev/null || fail "list: #7 from page 2 lost its board status or fields"
jq -e '[.items[] | select(.key == "500")][0] | .status == null and .on_board == 0' \
  "$WORK/list.json" >/dev/null || fail "list: an issue off the board must have status null"
jq -e '[.items[] | select(.key == "1001")][0] | .status == null and .on_board == 2' \
  "$WORK/list.json" >/dev/null || fail "list: an ambiguous board match must not pick one"
jq -e '[.items[] | select(.key == "600")] == []' "$WORK/list.json" >/dev/null \
  || fail "list: a pull request was listed as an issue"
grep -q 'issues?state=open&' "$GH_LOG" || fail "list without --state must keep requesting state=open"
jq -e '.items[0] | has("state") | not' "$WORK/list.json" >/dev/null \
  || fail "list without --state must keep today's item shape (no state field)"
# Keep the log: the case's later checks still count the default list's calls. Assert on the
# lines this call adds after the offset only.
GH_OFF="$(wc -l < "$GH_LOG" | tr -d ' ')"
run "$MAIN" $TRK list --state all --out "$WORK/list-all.json"
expect 0 "items=" "list --state all requests every issue state"
tail -n "+$((GH_OFF + 1))" "$GH_LOG" > "$WORK/gh-log-all"
grep -q 'issues?state=all&' "$WORK/gh-log-all" || fail "list --state all did not request state=all"
! grep -q 'issues?state=open&' "$WORK/gh-log-all" || fail "list --state all still requested state=open"
jq -e '.items[0] | has("state")' "$WORK/list-all.json" >/dev/null \
  || fail "list --state all must carry each issue's state"
run "$MAIN" $TRK list --state closed --out "$WORK/x.json"
expect 2 "--state must be open or all" "list --state rejects a value other than open or all"

export STUB_GH_PAGE2_FAIL=1
rm -f "$WORK/list2.json"
run "$MAIN" $TRK list --out "$WORK/list2.json"
unset STUB_GH_PAGE2_FAIL
expect 4 "recoverable" "a failed page 2 is recoverable, never a short list"
[ ! -e "$WORK/list2.json" ] || fail "a failed list still wrote its output"

jq '[range(31)] | map({id: (900 + .), user: {login: "rev"}, created_at: "2026-11-03T09:00:00Z",
    updated_at: "2026-11-03T09:00:00.123Z", body: ("comment " + (. | tostring))})' -n > "$GH_DIR/comments.json"
run "$MAIN" $TRK show '#7' --out "$WORK/show.json"
expect 0 "key=7 comments=31" "show returns the issue with every comment across pages"
jq -e '.title == "Fix the thing" and .state == "OPEN" and .labels == ["bug", "harness"]
    and (.body | test("line two")) and .comments[30].body == "comment 30"
    and .comments[0].author == "rev" and .comments[0].id == "900"
    and .comments[0].updated == "2026-11-03T09:00:00.123Z"' "$WORK/show.json" >/dev/null || fail "show output shape"
[ "$(stat -f %Lp "$WORK/show.json" 2>/dev/null || stat -c %a "$WORK/show.json")" = 600 ] \
  || fail "show must write its output owner-only (0600)"
run "$MAIN" $TRK show 9 --out "$WORK/show9.json"
expect 0 "key=9" "show answers for a closed issue too"
jq -e '.state == "CLOSED"' "$WORK/show9.json" >/dev/null || fail "show must report the closed state"
run "$MAIN" $TRK show 8 --out "$WORK/show8.json"
expect 1 "cannot be read" "show of a missing issue is refused"
run "$MAIN" $TRK list 7 --out "$WORK/x.json"
expect 2 "takes no ticket key" "list refuses a key"
run "$MAIN" $TRK show 7
expect 2 "needs --out" "show needs --out"
[ "$(posts)" = 0 ] || fail "list/show posted a comment"
[ "$(creates)" = 0 ] || fail "list/show created an issue"
[ "$(grep -c -- 'item-edit' "$GH_LOG" | tr -d ' ')" = 0 ] || fail "list/show edited the board"

setprofile '.teams.tracker = "none"'
: > "$GH_LOG"
run "$MAIN" $TRK list --out "$WORK/ln.json"
expect 0 "skipped (tracker=none)" "list is a no-op for none"
run "$MAIN" $TRK show L1 --out "$WORK/sn.json"
expect 0 "skipped (tracker=none)" "show is a no-op for none"
setprofile '.'
run "$MAIN" $TRK list --out "$WORK/lj.json"
expect 3 "no adapter op" "jira list refused"
[ ! -s "$GH_LOG" ] || { sed 's/^/  | /' "$GH_LOG"; fail "list/show under none/jira called gh"; }

# ================================================================================================
# (13) no teams block: the single-session path reads the top-level tracker and github block
# ================================================================================================
TOP_GH='{repo: "owner/repo", project_owner: "owner", project_number: 2, project_id: "PVT_x",
  status_field_id: "PVTSSF_x", status_options: {started: "opt-started", delivered: "opt-delivered"}}'
solo() { jq -n "{schema: 1, tracker: \"github\", github: $TOP_GH} | $1" > "$P"; }
fx_reset
echo '[{"number": 7, "title": "Fix the thing", "updated_at": "", "assignees": [], "labels": []}]' \
  > "$GH_DIR/issues.json"
solo '.'
run "$MAIN" $TRK list --out "$WORK/solo-list.json"
expect 0 "items=1" "list works without a teams block"
jq -e '.items[0].status == "Todo" and .statuses == ["In Progress", "Delivered"]' \
  "$WORK/solo-list.json" >/dev/null || fail "solo list lost the board status"
run "$MAIN" $TRK read 7 --out "$WORK/solo-read"
expect 0 "key=7 type=bugfix" "read works without a teams block"
run "$MAIN" $TRK set-status 7 delivered
expect 0 "set delivered" "set-status works without a teams block"

# "No Project" is a valid answer: set-status skips, list has no board, no gh project call at all.
solo '.github = {repo: "owner/repo"}'
: > "$GH_LOG"
run "$MAIN" $TRK set-status 7 delivered
expect 0 "skipped (no project)" "set-status without a Project skips politely"
run "$MAIN" $TRK list --out "$WORK/solo-noproj.json"
expect 0 "items=1" "list without a Project still lists the issues"
jq -e '.statuses == [] and .items[0].status == null and .items[0].on_board == 0' \
  "$WORK/solo-noproj.json" >/dev/null || fail "list without a Project must report no board"
[ "$(grep -c '^gh project' "$GH_LOG" | tr -d ' ')" = 0 ] || fail "no Project, yet gh project was called"
body_file "$WORK/f.md" MARKER-NP
run "$MAIN" $TRK create-followup --marker MARKER-NP --title "Follow up" --body-file "$WORK/f.md"
expect 0 "project: skipped (no project)" "a create without Project fields skips the board"

solo 'del(.github.status_field_id)'
run "$MAIN" $TRK list --out "$WORK/x.json"
expect 2 "github.status_field_id is required for a github Project" "a partial Project is refused"
solo 'del(.github.repo)'
run "$MAIN" $TRK list --out "$WORK/x.json"
expect 2 "github.repo is required for tracker=github" "github without a repo is refused"
solo '.tracker = "svn"'
run "$MAIN" $TRK list --out "$WORK/x.json"
expect 2 "tracker=svn must be jira|github|none" "a bad top-level tracker is refused"

: > "$GH_LOG"
solo '.tracker = "none"'
run "$MAIN" $TRK set-status L1 delivered
expect 0 "skipped (tracker=none)" "none without teams: write ops skip"
run "$MAIN" $TRK read --brief 'Fix X' --out "$WORK/solo-none"
expect 2 "need the teams block" "none without teams: read refuses (no L<n> counter)"
solo 'del(.tracker)'
run "$MAIN" $TRK list --out "$WORK/x.json"
expect 0 "skipped (tracker=none)" "a missing top-level tracker means none"
solo '.tracker = "jira"'
run "$MAIN" $TRK list --out "$WORK/x.json"
expect 3 "no adapter op" "jira without teams: refused as with teams"
[ ! -s "$GH_LOG" ] || { sed 's/^/  | /' "$GH_LOG"; fail "none/jira without teams called gh"; }

# The light loader has its own flag: a full team_profile_load after it still refuses a no-teams
# profile instead of trusting a half-loaded state.
solo '.'
run "$MAIN" bash -c '. .claude/lib/team-profile.sh; team_tracker_profile_load; team_profile_load; echo reached'
expect 2 "no teams profile — run /setup:teams" "team_profile_load after the light loader still validates"

# ================================================================================================
# (14) the type is one of teams.branch_types — /start-team builds <type>/<key>-<slug> from it:
#      the first synonym the list holds, else the list's first entry with a warning
# ================================================================================================
fx_reset
issue_json 13 OPEN '[]' > "$GH_DIR/issue-13.json"
issue_json 15 OPEN '[{"name": "infra"}]' > "$GH_DIR/issue-15.json"
BT='.teams.branch_types = ["feat", "fix", "chore", "docs", "refactor", "test"]'
setprofile ".teams.tracker = \"github\" | $GH_BLOCK | $BT"
run "$MAIN" $TRK read 13 --out "$WORK/bt13"
expect 0 "" "an unlabelled issue is read"
grep -qx "key=13 type=feat" "$WORK/out" || fail "an unlabelled issue must map feature onto feat"
jq -e '.type == "feat"' "$WORK/bt13/ticket.json" >/dev/null || fail "ticket.json must carry the mapped type"
! has warning "$WORK/out" || fail "a mapped type must not warn"
run "$MAIN" $TRK read 7 --out "$WORK/bt7"
expect 0 "key=7 type=fix" "a bug maps bugfix onto fix"
run "$MAIN" $TRK read 11 --out "$WORK/bt11"
expect 0 "key=11 type=docs" "a documentation label maps onto docs when the list has it"
run "$MAIN" $TRK read 15 --out "$WORK/bt15"
expect 0 "key=15 type=chore" "an infra label stays chore"
setprofile ".teams.tracker = \"github\" | $GH_BLOCK | .teams.branch_types = [\"refactor\", \"test\"]"
run "$MAIN" $TRK read 13 --out "$WORK/bt13b"
expect 0 "key=13 type=refactor" "no synonym falls back to the list's first entry"
has "warning: teams.branch_types has no type for a feature ticket — using 'refactor'" "$WORK/out" \
  || fail "the fallback must say so"
setprofile ".teams.tracker = \"github\" | $GH_BLOCK | .teams.branch_types = [\"feature\", \"chore\"]"
run "$MAIN" $TRK read 11 --out "$WORK/bt11b"
expect 0 "key=11 type=chore" "documentation without a docs type is a chore"
setprofile ".teams.tracker = \"none\" | $BT"
rm -rf "$MAIN/.agents/team"
run "$MAIN" $TRK read --brief 'Do X' --out "$WORK/btn"
expect 0 "" "a local ticket is read"
grep -qx "key=L1 type=feat" "$WORK/out" || fail "a local ticket must map feature onto the list too"
solo '.'
run "$MAIN" $TRK read 11 --out "$WORK/bts"
expect 0 "key=11 type=chore" "without a teams block documentation stays chore"
run "$MAIN" $TRK read 13 --out "$WORK/bts13"
expect 0 "key=13 type=feature" "without a teams block the generic kind is unchanged"

# ================================================================================================
# (15) pool / item-status: the /qa-verify pool read — every item in a Status, whatever the issue
#      state, with its links; refusals are exit codes, never a short pool
# ================================================================================================
github_profile
fx_reset
jq -n '{fields: [{id: "PVTSSF_x", name: "Status",
    options: [{id: "opt-started", name: "In Progress"}, {id: "opt-qa", name: "QA"},
              {id: "opt-delivered", name: "Delivered"}]}]}' > "$GH_DIR/fields.json"
pool_node() {  # pool_node <n> <state> <status|""> <updatedAt> [content jq] — one GraphQL item node
  jq -n --argjson n "$1" --arg st "$2" --arg s "$3" --arg u "$4" '
    {id: ("PVTI_" + ($n | tostring)),
     status: (if $s == "" then null else {name: $s, updatedAt: $u} end),
     content: {__typename: "Issue", number: $n, title: ("Issue " + ($n | tostring)), state: $st,
       url: ("https://github.com/owner/repo/issues/" + ($n | tostring)),
       repository: {nameWithOwner: "owner/repo"}, parent: null,
       blockedBy: {pageInfo: {hasNextPage: false}, nodes: []},
       blocking: {pageInfo: {hasNextPage: false}, nodes: []},
       timelineItems: {pageInfo: {hasNextPage: false}, nodes: []}}}' | jq "${5:-.}"
}
pool_fx() {
  {
    pool_node 7 OPEN QA 2026-11-01T08:00:00Z \
      '.content.blocking.nodes = [{number: 9, repository: {nameWithOwner: "owner/repo"}}]'
    pool_node 9 CLOSED QA 2026-11-05T08:00:00Z '.content.parent = {number: 2,
        repository: {nameWithOwner: "owner/repo"}}
      | .content.blockedBy.nodes = [{number: 7, repository: {nameWithOwner: "owner/repo"}},
          {number: 7, repository: {nameWithOwner: "other/repo"}}]
      | .content.timelineItems.nodes = [{source: {__typename: "Issue", number: 11,
            repository: {nameWithOwner: "owner/repo"}}},
          {source: {__typename: "PullRequest"}},
          {source: {__typename: "Issue", number: 9, repository: {nameWithOwner: "owner/repo"}}}]'
    pool_node 11 OPEN Todo 2026-11-02T08:00:00Z
    pool_node 7 OPEN QA 2026-11-03T08:00:00Z '.content.repository.nameWithOwner = "other/repo"'
    pool_node 40 OPEN QA 2026-11-04T08:00:00Z '.content.__typename = "PullRequest"'
  } | jq -s '.' > "$GH_DIR/pool-items.json"
}
pool_fx
run "$MAIN" $TRK pool --status QA --out "$WORK/pool.json"
expect 0 "items=2" "pool --status returns the repo's issues in that status, across pages"
jq -e '[.items[].key] == ["7", "9"] and .status == "QA" and .tracker == "github"
    and .repo == "owner/repo" and .statuses == ["In Progress", "QA", "Delivered"]
    and .dependencies == "available"' "$WORK/pool.json" >/dev/null \
  || fail "pool header / item order (status_since ascending) / board order"
jq -e '[.items[] | select(.key == "9")][0] | .state == "CLOSED" and .parent == 2
    and .blocked_by == ["7"] and .blocking == [] and .mentions == ["11"]
    and .status_since == "2026-11-05T08:00:00Z" and .url == "https://github.com/owner/repo/issues/9"' \
  "$WORK/pool.json" >/dev/null || fail "pool: a closed issue in the status, with its links"
jq -e '[.items[] | select(.key == "7")][0] | .blocking == ["9"] and .parent == null' \
  "$WORK/pool.json" >/dev/null || fail "pool: #7 lost its blocking link"
[ "$(stat -f %Lp "$WORK/pool.json" 2>/dev/null || stat -c %a "$WORK/pool.json")" = 600 ] \
  || fail "pool must write its output owner-only (0600)"
grep -qx 'graphql fname=Status' "$GH_LOG" || fail "pool must query the status field by its name"
[ "$(grep -c '^graphql fname=' "$GH_LOG" | tr -d ' ')" = 3 ] || fail "pool must read all three pages"

STUB_GH_POOL_STUCK=1 run "$MAIN" $TRK pool --status QA --out "$WORK/p-stuck.json"
expect 4 "" "pool: a cursor that never advances is recoverable, never a spin"
run "$MAIN" $TRK pool --status Nope --out "$WORK/p-nope.json"
expect 1 "options: In Progress, QA, Delivered" "pool: an unknown status names the options"
STUB_GH_POOL_TOTAL=99 run "$MAIN" $TRK pool --status QA --out "$WORK/p-short.json"
expect 4 "incomplete item list" "pool: fewer nodes than totalCount is exit 4"
[ ! -e "$WORK/p-short.json" ] || fail "a short pool still wrote its output"
jq 'map(if .content.number == 9 then .content.timelineItems.pageInfo.hasNextPage = true else . end)' \
  "$GH_DIR/pool-items.json" > "$GH_DIR/t" && mv "$GH_DIR/t" "$GH_DIR/pool-items.json"
run "$MAIN" $TRK pool --status QA --out "$WORK/p-links.json"
expect 4 "issue #9 has more links than one page" "pool: a truncated link list is exit 4"
pool_fx
{ jq '.[]' "$GH_DIR/pool-items.json"; pool_node 7 OPEN Todo 2026-11-06T08:00:00Z; } | jq -s '.' \
  > "$GH_DIR/t" && mv "$GH_DIR/t" "$GH_DIR/pool-items.json"
run "$MAIN" $TRK pool --status QA --out "$WORK/p-twice.json"
expect 4 "issue #7 has more than one item" "pool: an issue in the status and in another is exit 4"
pool_fx
STUB_GH_NODEPS=1 run "$MAIN" $TRK pool --status QA --out "$WORK/p-nodeps.json"
expect 0 "items=2" "pool: a host without issue dependencies still lists the pool"
jq -e '.dependencies == "unavailable" and ([.items[] | select(.key == "9")][0]
    | .blocked_by == [] and .mentions == ["11"])' "$WORK/p-nodeps.json" >/dev/null \
  || fail "pool: dependencies unavailable must be stated, mentions kept"
run "$MAIN" $TRK pool --out "$WORK/x.json"
expect 2 "needs --status" "pool without --status is a usage error"
run "$MAIN" $TRK pool 7 --status QA --out "$WORK/x.json"
expect 2 "takes no ticket key" "pool refuses a key"

# item-status: one issue, open or closed, by the set-status identity (repo + number).
jq -n '[{id: "i7", status: "QA", content: {type: "Issue", number: 7, repository: "owner/repo"}},
        {id: "i9", status: "QA", content: {type: "Issue", number: 9, repository: "owner/repo"}},
        {id: "o9", status: "Done", content: {type: "Issue", number: 9, repository: "other/repo"}},
        {id: "d1", status: "QA", content: {type: "Issue", number: 1001, repository: "owner/repo"}},
        {id: "d2", status: "Todo", content: {type: "Issue", number: 1001, repository: "owner/repo"}}]' \
  > "$GH_DIR/items.json"
issue_json 1001 OPEN '[]' > "$GH_DIR/issue-1001.json"
run "$MAIN" $TRK item-status 9 --out "$WORK/is9.json"
expect 0 "key=9 status=QA" "item-status of a closed issue on the board"
jq -e '.key == "9" and .state == "CLOSED" and .status == "QA" and .on_board == 1
    and .statuses == ["In Progress", "QA", "Delivered"]' "$WORK/is9.json" >/dev/null \
  || fail "item-status output shape"
run "$MAIN" $TRK item-status 1001 --out "$WORK/is-dup.json"
expect 4 "refusing" "item-status: two items for one issue is exit 4"
run "$MAIN" $TRK item-status 11 --out "$WORK/is11.json"
expect 0 "key=11 status=null" "item-status of an issue off the board"
jq -e '.status == null and .on_board == 0 and .state == "OPEN"' "$WORK/is11.json" >/dev/null \
  || fail "item-status off the board must say status null, on_board 0"
run "$MAIN" $TRK item-status 404 --out "$WORK/is404.json"
expect 1 "cannot be read" "item-status of a missing issue"
run "$MAIN" $TRK item-status 9
expect 2 "needs --out" "item-status needs --out"

# list stays open-only and keeps its shape next to the new ops.
echo '[{"number": 7, "title": "Fix the thing", "updated_at": "", "assignees": [], "labels": []},
  {"number": 11, "title": "Docs", "updated_at": "", "assignees": [], "labels": []}]' \
  > "$GH_DIR/issues.json"
run "$MAIN" $TRK list --out "$WORK/pool-list.json"
expect 0 "items=2" "list next to pool"
jq -e '[.items[].key] == ["7", "11"] and (.items[0] | keys)
    == ["assignees", "key", "labels", "on_board", "status", "title", "updated", "url"]' \
  "$WORK/pool-list.json" >/dev/null || fail "list output changed shape"
[ "$(posts)" = 0 ] || fail "pool/item-status posted a comment"
[ "$(grep -c -- 'item-edit' "$GH_LOG" | tr -d ' ')" = 0 ] || fail "pool/item-status edited the board"

solo '.github = {repo: "owner/repo"}'
run "$MAIN" $TRK pool --status QA --out "$WORK/x.json"
expect 2 "pool needs a GitHub Project" "pool without a Project is a profile error"
run "$MAIN" $TRK item-status 9 --out "$WORK/x.json"
expect 2 "needs a GitHub Project" "item-status without a Project is a profile error"
setprofile '.teams.tracker = "none"'
: > "$GH_LOG"
run "$MAIN" $TRK pool --status QA --out "$WORK/x.json"
expect 0 "skipped (tracker=none)" "pool is a no-op for none"
run "$MAIN" $TRK item-status L1 --out "$WORK/x.json"
expect 0 "skipped (tracker=none)" "item-status is a no-op for none"
[ ! -s "$GH_LOG" ] || { sed 's/^/  | /' "$GH_LOG"; fail "pool under none called gh"; }

# ================================================================================================
# (16) the claim at the start: team-claim.sh check / claim / release / holder, and the set-status
#      restore form
# ================================================================================================
export SMOKE_ORIGIN=github
CLM="bash .claude/lib/team-claim.sh"
ME="$(hostname -s 2>/dev/null || hostname)"; ME="${ME//[^A-Za-z0-9-]/-}"
CL_GH='.teams.github = {repo: "acme/widgets", project_owner: "owner", project_number: 2,
  project_id: "PVT_x", status_field_id: "PVTSSF_x",
  status_options: {started: "opt-started", delivered: "opt-delivered"}}'
claim_profile() {
  setprofile ".teams.tracker = \"github\" | .teams.pr_provider = \"github\" | $CL_GH
    | .teams.required_tools = [\"git\", \"jq\", \"gh\"]"
}
cl_reset() {
  fx_reset
  jq '.fields[0].options += [{id: "opt-todo", name: "Todo"}]' "$GH_DIR/fields.json" > "$GH_DIR/t" \
    && mv "$GH_DIR/t" "$GH_DIR/fields.json"
  jq 'map(.content.repository = "acme/widgets")' "$GH_DIR/items.json" > "$GH_DIR/t" \
    && mv "$GH_DIR/t" "$GH_DIR/items.json"
  rm -f "$GH_DIR"/timeline-*.json "$GH_DIR"/pr-*.json "$GH_DIR/race-claim.txt" "$GH_DIR/post-fail-once" \
    "$GH_DIR/race-reread.txt" "$GH_DIR/race-reread.seen"
  : > "$GH_LOG"
}
st44() { jq -r '[.[] | select(.id == "item-44")][0].status // "null"' "$GH_DIR/items.json"; }
set44() {
  jq --arg s "$1" 'map(if .id == "item-44" then .status = $s else . end)' "$GH_DIR/items.json" \
    > "$GH_DIR/t" && mv "$GH_DIR/t" "$GH_DIR/items.json"
}
seed_comment() {  # seed_comment <body> — the next numeric id, a created_at like the API's
  jq --arg b "$1" '. + [{id: (length + 900), created_at: "2026-11-22T10:00:00Z", body: $b}]' \
    "$GH_DIR/comments.json" > "$GH_DIR/t" && mv "$GH_DIR/t" "$GH_DIR/comments.json"
}
claim_body() {  # claim_body <id> <machine> <who> <branch> <previous> [takeover] — the GitHub form
  printf 'Claimed by %s on %s for branch %s at 2026-11-22T10:00:00Z.\n<!-- team:claim v1 id=%s machine=%s who=%s branch=%s at=2026-11-22T10:00:00Z previous=%s%s -->\n' \
    "$3" "$2" "$4" "$1" "$2" "$3" "$4" "$5" "${6:+ takeover=$6}"
}
release_body() {  # release_body <id> <reason>
  printf 'Claim released (%s): %s.\n<!-- team:claim-released v1 id=%s reason=%s -->\n' "$2" "$1" "$1" "$2"
}
n_bodies() {  # n_bodies <regex> — comments whose body matches
  jq --arg r "$1" '[.[] | select(.body | test($r))] | length' "$GH_DIR/comments.json"
}
edits() { grep -c -- 'item-edit' "$GH_LOG" | tr -d ' '; }
FID="othermac.beta.20261122T100000Z"
OWN="$ME.alfa.20261122T100000Z"

# 1. set-status, the restore form: by option name, and --clear for "had no status".
claim_profile
cl_reset
run "$MAIN" $TRK set-status 7 started
expect 0 "set started" "set-status started before the restore cases"
run "$MAIN" $TRK set-status 7 --name Todo
expect 0 "set Todo" "set-status --name restores a status by its option name"
[ "$(st44)" = Todo ] || fail "set-status --name restores a status by its option name: status $(st44)"
run "$MAIN" $TRK set-status 7 --clear
expect 0 "cleared" "set-status --clear clears the status"
[ "$(st44)" = null ] || fail "set-status --clear clears the status: status $(st44)"
run "$MAIN" $TRK set-status 7 --clear
expect 0 "unchanged" "set-status --clear on no status is a no-op"
run "$MAIN" $TRK set-status 7 --name Nope
expect 4 "is not in field" "set-status --name refuses an option the field lacks"
run "$MAIN" $TRK set-status 7 started --clear
expect 2 "usage: set-status" "set-status takes exactly one form"

# 2. a free ticket: one claim comment, then the started status.
cl_reset
run "$MAIN" $CLM claim 7 --who alfa --branch feat/7-fix
expect 0 "claimed id=$ME.alfa." "claim: a free ticket is claimed with one comment and the started status"
has "previous=Todo" "$WORK/out" || fail "claim: a free ticket is claimed with one comment and the started status (previous)"
has "status: set started" "$WORK/out" || fail "claim: the status line is missing"
[ "$(posts)" = 1 ] || fail "claim: a free ticket is claimed with one comment and the started status ($(posts) POSTs)"
[ "$(st44)" = "In Progress" ] || fail "claim: the status is $(st44), not In Progress"
jq -r '.[-1].body' "$GH_DIR/comments.json" | sed '/^[[:space:]]*$/d' | tail -n 1 \
  | grep -Eq "^<!-- team:claim v1 id=$ME\.alfa\.[0-9TZ]+ machine=$ME who=alfa branch=feat/7-fix at=[0-9TZ:-]+ previous=Todo -->$" \
  || fail "claim: the marker is not the body's last line in the v1 grammar"

# 3. the started status refuses, and nothing is written.
cl_reset
set44 "In Progress"
run "$MAIN" $CLM claim 7 --who alfa --branch feat/7-fix
expect 3 "refused: #7 — status In Progress" "claim: a ticket in started is refused"
[ "$(posts)" = 0 ] || fail "claim: a ticket in started is refused — it posted"

# 4. an open PR for the key (closes or branch) refuses; merged or mentions-only does not.
pr_fx() {  # pr_fx <state> <head>
  jq -n '[{event: "cross-referenced", source: {issue: {number: 60,
    repository: {full_name: "acme/widgets"}, pull_request: {url: "u"}}}}]' > "$GH_DIR/timeline-7.json"
  jq -n --arg s "$1" --arg h "$2" '{number: 60, title: "PR 60", state: $s, headRefName: $h,
    baseRefName: "main", body: "", mergedAt: null, updatedAt: "", mergeCommit: null,
    url: "https://github.com/acme/widgets/pull/60", closingIssuesReferences: []}' > "$GH_DIR/pr-60.json"
}
cl_reset; pr_fx OPEN feat/7-other
run "$MAIN" $CLM claim 7 --who alfa --branch feat/7-fix
expect 3 "PR https://github.com/acme/widgets/pull/60" "claim: an open PR for the key is refused"
[ "$(posts)" = 0 ] || fail "claim: an open PR for the key is refused — it posted"
cl_reset; pr_fx MERGED feat/7-other
run "$MAIN" $CLM claim 7 --who alfa --branch feat/7-fix
expect 0 "claimed" "claim: a merged PR for the key does not refuse"
cl_reset; pr_fx OPEN feat/other
run "$MAIN" $CLM claim 7 --who alfa --branch feat/7-fix
expect 0 "claimed" "claim: an open PR that only mentions the key does not refuse"

# 5. a remote branch carrying the key refuses; another number's branch does not.
cl_reset
git -C "$MAIN" push --quiet origin HEAD:refs/heads/fix/7-other
run "$MAIN" $CLM claim 7 --who alfa --branch feat/7-fix
expect 3 "branch fix/7-other" "claim: a remote branch for the key is refused"
git -C "$MAIN" push --quiet origin --delete fix/7-other
git -C "$MAIN" push --quiet origin HEAD:refs/heads/feat/77-x
cl_reset
run "$MAIN" $CLM claim 7 --who alfa --branch feat/7-fix
expect 0 "claimed" "claim: a branch of key 77 does not refuse key 7"
git -C "$MAIN" push --quiet origin --delete feat/77-x

# 6. a closed ticket.
cl_reset
run "$MAIN" $CLM claim 9 --who alfa --branch feat/9-fix
expect 3 "issue is CLOSED" "claim: a closed ticket is refused"

# 7. a foreign unreleased claim refuses at the check; released, it does not.
cl_reset
seed_comment "$(claim_body "$FID" othermac beta feat/7-other Todo)"
run "$MAIN" $CLM claim 7 --who alfa --branch feat/7-fix
expect 3 "held by beta on othermac" "claim: a foreign unreleased claim is refused at the check"
[ "$(posts)" = 0 ] || fail "claim: a foreign unreleased claim is refused at the check — it posted"
seed_comment "$(release_body "$FID" start-failed)"
run "$MAIN" $CLM claim 7 --who alfa --branch feat/7-fix
expect 0 "claimed" "claim: a released foreign claim does not refuse"

# 8. the status move fails → exit 4, the claim released, the status untouched.
cl_reset
STUB_GH_EDIT_DENY=1 run "$MAIN" $CLM claim 7 --who alfa --branch feat/7-fix
expect 4 "release posted" "claim: a failed status move stops with a release"
[ "$(n_bodies "team:claim-released v1 id=$ME\\.alfa\\.")" = 1 ] \
  || fail "claim: a failed status move stops with a release — no release comment"
[ "$(st44)" = Todo ] || fail "claim: a failed status move stops with a release — status $(st44)"

# 9. the comment post fails → exit 4, no claim comment, one cleanup release.
cl_reset
touch "$GH_DIR/post-fail-once"
run "$MAIN" $CLM claim 7 --who alfa --branch feat/7-fix
expect 4 "claim comment not posted" "claim: a failed comment post stops with a release"
[ "$(n_bodies 'team:claim v1 ')" = 0 ] || fail "claim: a failed comment post stops with a release — a claim exists"
[ "$(n_bodies 'team:claim-released v1 ')" = 1 ] \
  || fail "claim: a failed comment post stops with a release — $(n_bodies 'team:claim-released v1 ') releases"
[ "$(st44)" = Todo ] || fail "claim: a failed comment post stops with a release — status $(st44)"

# 10. a foreign claim lands just before ours → ours withdrawn, the status never written.
cl_reset
claim_body "$FID" othermac beta feat/7-other Todo > "$GH_DIR/race-claim.txt"
run "$MAIN" $CLM claim 7 --who alfa --branch feat/7-fix
expect 3 "lost the race: held by beta on othermac" "claim: an earlier foreign claim withdraws this one, status untouched"
[ "$(n_bodies "team:claim v1 id=$ME\\.alfa\\.")" = 1 ] || fail "claim: race — our claim is missing"
[ "$(n_bodies "team:claim-released v1 id=$ME\\.alfa\\.[^ ]+ reason=lost-race")" = 1 ] \
  || fail "claim: race — our claim was not released"
[ "$(st44)" = Todo ] && [ "$(edits)" = 0 ] \
  || fail "claim: an earlier foreign claim withdraws this one, status untouched — status $(st44), $(edits) edits"

# 11. an own claim from a crashed start: held, no second comment, previous from its marker; an
#     advanced status is never moved back.
cl_reset
seed_comment "$(claim_body "$OWN" "$ME" alfa feat/7-fix Todo)"
set44 "In Progress"
run "$MAIN" $CLM claim 7 --who alfa --branch feat/7-fix
expect 0 "held id=$OWN previous=Todo" "claim: an own claim is held — no second comment, previous from the first marker"
[ "$(posts)" = 0 ] || fail "claim: an own claim is held — no second comment, previous from the first marker ($(posts) POSTs)"
cl_reset
seed_comment "$(claim_body "$OWN" "$ME" alfa feat/7-fix Todo)"
set44 Delivered
run "$MAIN" $CLM claim 7 --who alfa --branch feat/7-fix
expect 3 "status moved on to Delivered" "claim: an own claim never moves an advanced status back"
[ "$(posts)" = 0 ] && [ "$(edits)" = 0 ] || fail "claim: an own claim never moves an advanced status back — it wrote"
# A held claim confirms too: a takeover landing between its check and its confirm wins.
cl_reset
seed_comment "$(claim_body "$OWN" "$ME" alfa feat/7-fix Todo)"
claim_body "$FID" othermac beta feat/7-other Todo "$OWN" > "$GH_DIR/race-reread.txt"
run "$MAIN" $CLM claim 7 --who alfa --branch feat/7-fix
expect 3 "lost the race: held by beta on othermac" "claim: a held claim superseded before the confirm is withdrawn, status untouched"
[ "$(st44)" = Todo ] && [ "$(edits)" = 0 ] \
  || fail "claim: a held claim superseded before the confirm is withdrawn, status untouched — status $(st44), $(edits) edits"
[ "$(n_bodies "team:claim-released v1 id=$OWN reason=lost-race")" = 1 ] \
  || fail "claim: a held claim superseded before the confirm is withdrawn — no release comment"

# 12. a takeover only with --takeover, recorded in the marker; never over the new branch itself.
cl_reset
seed_comment "$(claim_body "$FID" othermac beta feat/7-other Todo)"
run "$MAIN" $CLM claim 7 --who alfa --branch feat/7-fix
expect 3 "held by beta" "claim: a held ticket is taken over only with --takeover, recorded in the marker"
run "$MAIN" $CLM claim 7 --who alfa --branch feat/7-fix --takeover
expect 0 "claimed" "claim: a held ticket is taken over only with --takeover, recorded in the marker"
jq -r '.[-1].body' "$GH_DIR/comments.json" | grep -q "takeover=$FID -->" \
  || fail "claim: a held ticket is taken over only with --takeover, recorded in the marker — no takeover field"
cl_reset
seed_comment "$(claim_body "$FID" othermac beta feat/7-other Todo)"
git -C "$MAIN" push --quiet origin HEAD:refs/heads/feat/7-fix
run "$MAIN" $CLM claim 7 --who alfa --branch feat/7-fix --takeover
expect 3 "remote branch feat/7-fix" "claim: takeover still refuses a remote branch equal to the new branch"
git -C "$MAIN" push --quiet origin --delete feat/7-fix

# 13. no Project (a solo profile): the comment alone is the claim, no board call.
cl_reset
echo '{"schema": 1, "tracker": "github", "github": {"repo": "acme/widgets"}}' > "$P"
run "$MAIN" $CLM claim 7 --who solo --branch feat/7-fix
expect 0 "previous=no-project" "claim: no Project — the comment alone is the claim"
has "status: skipped (no project)" "$WORK/out" || fail "claim: no Project — the status line"
[ "$(posts)" = 1 ] || fail "claim: no Project — the comment alone is the claim ($(posts) POSTs)"
[ "$(grep -c '^gh project' "$GH_LOG" | tr -d ' ')" = 0 ] || fail "claim: no Project, yet gh project was called"

# 14. tracker none: one line, no gh; tracker jira: exit 2 (the MCP runs it).
cl_reset
setprofile '.teams.tracker = "none"'
run "$MAIN" $CLM claim L1 --who alfa --branch feat/L1-x
expect 0 "skipped (tracker=none)" "claim: tracker none is skipped with no gh call"
[ ! -s "$GH_LOG" ] || fail "claim: tracker none is skipped with no gh call — gh was called"
setprofile
run "$MAIN" $CLM claim ABC-7 --who alfa --branch feat/ABC-7-x
expect 2 "session's MCP" "claim: tracker jira refuses with exit 2"

# 15. release after a won claim: the status first, then the comment; a rerun writes nothing.
claim_profile
cl_reset
run "$MAIN" $CLM claim 7 --who alfa --branch feat/7-fix
expect 0 "claimed" "release: the claim before the release"
CID="$(sed -n 's/^claimed id=\([^ ]*\) .*/\1/p' "$WORK/out")"
: > "$GH_LOG"
run "$MAIN" $CLM release 7 --id "$CID" --reason start-failed
expect 0 "status: restored Todo" "release: restores the previous status before the release comment"
[ "$(st44)" = Todo ] || fail "release: restores the previous status before the release comment — status $(st44)"
e1="$(grep -n -- 'item-edit' "$GH_LOG" | head -n 1 | cut -d: -f1)"
p1="$(grep -n -- '-X POST' "$GH_LOG" | tail -n 1 | cut -d: -f1)"
[ -n "$e1" ] && [ -n "$p1" ] && [ "$e1" -lt "$p1" ] \
  || fail "release: restores the previous status before the release comment — edit line '$e1', post line '$p1'"
: > "$GH_LOG"
run "$MAIN" $CLM release 7 --id "$CID" --reason start-failed
expect 0 "released id=$CID" "release: a rerun is idempotent"
[ "$(posts)" = 0 ] && [ "$(edits)" = 0 ] || fail "release: a rerun wrote again ($(posts) POSTs, $(edits) edits)"

# 16. previous=none → the status is cleared.
cl_reset
seed_comment "$(claim_body "$OWN" "$ME" alfa feat/7-fix none)"
set44 "In Progress"
run "$MAIN" $CLM release 7 --id "$OWN" --reason start-failed
expect 0 "status: restored none" "release: previous none clears the status"
[ "$(st44)" = null ] || fail "release: previous none clears the status — status $(st44)"

# 17. a superseded claim, or a status moved on, is not restored — the release comment still posts.
cl_reset
seed_comment "$(claim_body "$OWN" "$ME" alfa feat/7-fix Todo)"
seed_comment "$(claim_body "othermac.beta.20261122T110000Z" othermac beta feat/7-y Todo "$OWN")"
set44 "In Progress"
run "$MAIN" $CLM release 7 --id "$OWN" --reason start-failed
expect 0 "no longer the holder" "release: a superseded claim or an advanced status is not restored"
[ "$(edits)" = 0 ] && [ "$(n_bodies "team:claim-released v1 id=$OWN ")" = 1 ] \
  || fail "release: a superseded claim or an advanced status is not restored — superseded"
cl_reset
seed_comment "$(claim_body "$OWN" "$ME" alfa feat/7-fix Todo)"
set44 Delivered
run "$MAIN" $CLM release 7 --id "$OWN" --reason start-failed
expect 0 "status is Delivered" "release: a superseded claim or an advanced status is not restored"
[ "$(edits)" = 0 ] || fail "release: a superseded claim or an advanced status is not restored — advanced"

# 18. holder: the HTML-comment, the plain and the Jira-joined marker judge alike.
MK="team:claim v1 id=h.alfa.1 machine=h who=alfa branch=feat/7-a at=2026-11-06T09:00:00Z previous=To%20Do"
printf '2026-11-06T09:00:00Z\t901\t<!-- %s -->\n' "$MK" > "$WORK/hl-html.tsv"
printf '2026-11-06T09:00:00Z\t901\t%s\n' "$MK" > "$WORK/hl-plain.tsv"
printf '2026-11-06 09:00:00+00:00\t901\tClaimed by alfa on h for branch feat/7-a at 2026-11-06T09:00:00Z. %s\n' \
  "$MK" > "$WORK/hl-jira.tsv"
run "$MAIN" $CLM holder --lines "$WORK/hl-html.tsv" --who alfa
expect 0 "holder id=h.alfa.1 machine=h who=alfa" "holder: the HTML-comment and the plain marker form judge alike"
cp "$WORK/out" "$WORK/hl-html.out"
for f in plain jira; do
  run "$MAIN" $CLM holder --lines "$WORK/hl-$f.tsv" --who alfa
  cmp -s "$WORK/out" "$WORK/hl-html.out" \
    || fail "holder: the HTML-comment and the plain marker form judge alike — the $f form differs"
done
{ printf '2026-11-06T09:00:00Z\t903\tClaim released (lost-race): h.alfa.1. team:claim-released v1 id=h.alfa.1 reason=lost-race\n'
  printf '2026-11-06 09:00:00+00:00\t901\tClaimed by alfa on h for branch feat/7-a at t. %s\n' "$MK"
  printf '2026-11-06T09:00:00Z\t902\tteam:claim v1 id=k.beta.2 machine=k who=beta branch=feat/7-b at=t previous=none\n'
} > "$WORK/hl-mix.tsv"
run "$MAIN" $CLM holder --lines "$WORK/hl-mix.tsv" --who alfa
expect 0 "holder id=k.beta.2 machine=k who=beta" "holder: a joined release removes its claim"
{ printf '2026-11-06T09:00:00Z\t900\tteam:claim-released v1 id=x.alfa.0 reason=post-failed\n'
  printf '2026-11-06T09:00:00Z\t901\t<!-- team:claim v1 id=x.alfa.0 machine=x who=alfa branch=b at=t previous=none -->\n'
} > "$WORK/hl-late.tsv"
run "$MAIN" $CLM holder --lines "$WORK/hl-late.tsv" --who alfa
expect 0 "holder none" "holder: a claim released before it landed is never the holder"
printf '2026-11-06T09:00:00Z\tabc\t%s\n' "$MK" > "$WORK/hl-bad.tsv"
run "$MAIN" $CLM holder --lines "$WORK/hl-bad.tsv" --who alfa
expect 2 "malformed claim line 1" "holder: a non-numeric comment id is a usage error, never absent"

# 19. a short comment read is exit 4 — never "no claim".
cl_reset
for i in $(seq 31); do seed_comment "a comment $i"; done
STUB_GH_PAGE2_FAIL=1 run "$MAIN" $CLM check 7 --who alfa
expect 4 "" "check: a short comment read is recoverable, never no claim"
[ "$(posts)" = 0 ] || fail "check: a short comment read is recoverable, never no claim — it posted"

unset SMOKE_ORIGIN
setprofile

# which (/create-task): a teams block wins over the top-level tracker, whole.
github_profile
run "$MAIN" $TRK which
expect 0 "tracker=github" "which: a teams block wins"
echo "PASS which: a teams block wins"
setprofile '.teams.tracker = "none" | .tracker = "github"'
run "$MAIN" $TRK which
expect 0 "tracker=none" "which: teams tracker none beats a top-level github"
echo "PASS which: teams tracker none beats a top-level github"
setprofile

echo "team-tracker-smoke: OK"
