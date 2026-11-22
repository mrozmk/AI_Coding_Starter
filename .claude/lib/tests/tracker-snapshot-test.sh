#!/usr/bin/env bash
# Offline test for .claude/lib/tracker-snapshot.mjs: snapshots from a github show result and from the
# three Jira result shapes (raw REST page, MCP issue, MCP-wrapped string), owner-only files with no
# ticket text, and every comparator case. Fixture text is dummy; no output may echo it.
set -euo pipefail

ST=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
ts() { node "$ST/.claude/lib/tracker-snapshot.mjs" "$@"; }
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
fail() { echo "tracker-snapshot-test: FAIL — $*"; exit 1; }
N=0
run() {  # run <args…> → RC, OUT (stdout+stderr); fails the test if a fixture secret word leaks
  set +e; OUT=$(ts "$@" 2>&1); RC=$?; set -e; N=$((N + 1))
  case "$OUT" in *SECRETWORD*) fail "output echoed ticket text: $OUT" ;; esac
}
mode() { stat -f %Lp "$1" 2>/dev/null || stat -c %a "$1"; }

# ---- github: a show result (team-tracker.sh show shape) -----------------------------------------
gh_show() {  # gh_show <file> <comment-2 body> [description]
  jq -n --arg b2 "$2" --arg d "${3:-SECRETWORD description}" '{key: "7", title: "t", state: "OPEN",
    updated: "2026-11-03T09:00:00Z", body: $d, comments: [
    {id: "900", author: "dev", created: "2026-11-03T09:00:00Z", updated: "2026-11-03T09:00:00.100Z", body: "SECRETWORD one"},
    {id: "901", author: "dev", created: "2026-11-03T09:01:00Z", updated: "2026-11-03T09:01:00.100Z", body: $b2},
    {id: "902", author: "bot", created: "2026-11-03T09:02:00Z", updated: "2026-11-03T09:02:00Z",
     body: "SECRETWORD summary\n\n[wrapup alfa-20261103-090000 comment-1]"}]}' > "$1"
}
gh_show "$WORK/show1.json" "SECRETWORD two"
run snapshot --github "$WORK/show1.json" --out "$WORK/base.json"
[ "$RC" = 0 ] && [ "$OUT" = "key=7 comments=3 status=complete" ] || fail "github snapshot: $RC $OUT"
[ "$(mode "$WORK/base.json")" = 600 ] || fail "the snapshot is not owner-only"
! grep -q SECRETWORD "$WORK/base.json" || fail "the snapshot stores ticket text"
jq -e '.comments[2].own == true and .comments[0].own == false and (.body_sha | length) == 64
  and .comments[0].updated == "2026-11-03T09:00:00.100Z"' "$WORK/base.json" >/dev/null || fail "snapshot fields"
jq -e '[.comments[] | has("author")] | any | not' "$WORK/base.json" >/dev/null || fail "the snapshot stores comment authors"

# (1) identical read → none new, exit 0
run snapshot --github "$WORK/show1.json" --out "$WORK/same.json"
run compare "$WORK/base.json" "$WORK/same.json"
[ "$RC" = 0 ] && case "$OUT" in "Tracker comments: none new"*) ;; *) false ;; esac || fail "1 none new: $RC $OUT"

# (2) an edit inside the same second (only the text differs) → edited
gh_show "$WORK/show2.json" "SECRETWORD two, amended"
jq '.comments[1].updated = "2026-11-03T09:01:00.100Z"' "$WORK/show2.json" > "$WORK/t" && mv "$WORK/t" "$WORK/show2.json"
run snapshot --github "$WORK/show2.json" --out "$WORK/f2.json"
run compare "$WORK/base.json" "$WORK/f2.json" --out "$WORK/r2.json"
[ "$RC" = 3 ] && [ "$OUT" = "Tracker comments: edited 901" ] || fail "2 edited: $RC $OUT"
[ "$(mode "$WORK/r2.json")" = 600 ] || fail "2: the result file is not owner-only"
# … reconciled at that version → not reported again; a later edit is
SHA=$(jq -r '.comments[1].sha' "$WORK/f2.json")
run compare "$WORK/base.json" "$WORK/f2.json" --reconciled "901@$SHA"
[ "$RC" = 0 ] || fail "2 reconciled pair still reported: $OUT"
gh_show "$WORK/show2b.json" "SECRETWORD two, amended again"
run snapshot --github "$WORK/show2b.json" --out "$WORK/f2b.json"
run compare "$WORK/base.json" "$WORK/f2b.json" --reconciled "901@$SHA"
[ "$RC" = 3 ] && [ "$OUT" = "Tracker comments: edited 901" ] || fail "2 later edit after reconciliation: $RC $OUT"

# (3) description changed, a new comment, a removed comment (complete read)
gh_show "$WORK/show3.json" "SECRETWORD two" "SECRETWORD description v2"
jq '.comments = ([.comments[0]] + [.comments[2]] + [{id: "903", author: "pm", created: "2026-11-04T08:00:00Z",
  updated: "2026-11-04T08:00:00Z", body: "SECRETWORD please also"}])' "$WORK/show3.json" > "$WORK/t" && mv "$WORK/t" "$WORK/show3.json"
run snapshot --github "$WORK/show3.json" --out "$WORK/f3.json"
run compare "$WORK/base.json" "$WORK/f3.json"
[ "$RC" = 3 ] && [ "$OUT" = "Tracker comments: new 903; removed 901; description changed" ] || fail "3: $RC $OUT"

# (4) own entries: a new own comment is skipped; a quoted marker is not own; a human comment edited
#     into carrying a marker stays visible
gh_show "$WORK/show4.json" "SECRETWORD two"
jq '.comments += [{id: "904", author: "bot", created: "2026-11-05T08:00:00Z", updated: "2026-11-05T08:00:00Z",
    body: "token-usage-report: 7\n\nSECRETWORD table"},
   {id: "905", author: "dev", created: "2026-11-05T09:00:00Z", updated: "2026-11-05T09:00:00Z",
    body: "SECRETWORD quoting [wrapup alfa-1 comment-1] in the middle\nplease change AC2"}]
  | .comments[0].body = "SECRETWORD one\n[wrapup alfa-20261103-090000 comment-9]"' "$WORK/show4.json" > "$WORK/t" && mv "$WORK/t" "$WORK/show4.json"
run snapshot --github "$WORK/show4.json" --out "$WORK/f4.json"
run compare "$WORK/base.json" "$WORK/f4.json"
[ "$RC" = 3 ] && [ "$OUT" = "Tracker comments: new 905; edited 900" ] || fail "4 own handling: $RC $OUT"

# (4b) the /qa-verify record: a genuine marker as the last line and the Jira-joined form are own; an
#      earlier-line quote, a partial marker and a blockquoted complete marker are human comments
QAM='qa-verify:v1 record run=20261122T100000Z ticket=7 mode=first group=- build=- pass=1 fail=0 cited=0 deferred=0 env=0 needs-human=0'
QAV='**Blockers: 0.** Acceptable — move the ticket yourself'
gh_show "$WORK/show4b.json" "SECRETWORD two"
jq --arg m "$QAM" --arg v "$QAV" '.comments += [
    {id: "910", author: "dev", created: "2026-11-06T08:00:00Z", updated: "2026-11-06T08:00:00Z",
     body: ("SECRETWORD record\n\n" + $v + "\n" + $m)},
    {id: "911", author: "dev", created: "2026-11-06T08:01:00Z", updated: "2026-11-06T08:01:00Z",
     body: ("SECRETWORD quoting\n" + $m + "\nplease look at AC2 again")},
    {id: "912", author: "dev", created: "2026-11-06T08:02:00Z", updated: "2026-11-06T08:02:00Z",
     body: ("SECRETWORD record\n\n" + $v + " " + $m)},
    {id: "913", author: "dev", created: "2026-11-06T08:03:00Z", updated: "2026-11-06T08:03:00Z",
     body: "SECRETWORD see qa-verify:v1 record run=x ticket=y"},
    {id: "914", author: "dev", created: "2026-11-06T08:04:00Z", updated: "2026-11-06T08:04:00Z",
     body: ("SECRETWORD please change AC2\n> " + $m)}]' "$WORK/show4b.json" > "$WORK/t" && mv "$WORK/t" "$WORK/show4b.json"
run snapshot --github "$WORK/show4b.json" --out "$WORK/f4b.json"
[ "$(jq -c '[.comments[3:][].own]' "$WORK/f4b.json")" = '[true,false,true,false,false]' ] || fail "4b qa record own flags"
run compare "$WORK/base.json" "$WORK/f4b.json"
[ "$RC" = 3 ] && [ "$OUT" = "Tracker comments: new 911 913 914" ] || fail "4b qa record compare: $RC $OUT"

# (4c) the /qa-verify record in a Jira ADF body: only a top-level paragraph carries an own marker
jq -n --arg m "$QAM" '{key: "AB-2", fields: {description: "SECRETWORD d", updated: "2026-11-06T09:00:00.000+0000",
  comment: {startAt: 0, maxResults: 2, total: 2, comments: [
    {id: "920", created: "2026-11-06 09:00:00+00:00", updated: "2026-11-06 09:00:00+00:00",
     body: {type: "doc", version: 1, content: [
       {type: "paragraph", content: [{type: "text", text: "SECRETWORD record"}]},
       {type: "paragraph", content: [{type: "text", text: $m}]}]}},
    {id: "921", created: "2026-11-06 09:01:00+00:00", updated: "2026-11-06 09:01:00+00:00",
     body: {type: "doc", version: 1, content: [
       {type: "paragraph", content: [{type: "text", text: "SECRETWORD please change AC2"}]},
       {type: "blockquote", content: [{type: "paragraph", content: [{type: "text", text: $m}]}]}]}}]}}}' > "$WORK/j-qa.json"
jq '.fields.comment.comments = [] | .fields.comment.total = 0 | .fields.comment.maxResults = 0' "$WORK/j-qa.json" > "$WORK/j-qa0.json"
run snapshot --jira "$WORK/j-qa.json" --out "$WORK/jq1.json"
[ "$(jq -c '[.comments[].own]' "$WORK/jq1.json")" = '[true,false]' ] || fail "4c jira ADF qa record own flags"
run snapshot --jira "$WORK/j-qa0.json" --out "$WORK/jq0.json"
run compare "$WORK/jq0.json" "$WORK/jq1.json"
[ "$RC" = 3 ] && [ "$OUT" = "Tracker comments: new 921" ] || fail "4c jira ADF compare: $RC $OUT"

# (4d) ADF tail: every trailing blank paragraph is dropped (a record stays own); a non-paragraph block
# after the marker (a screenshot) is the tail, so a pasted marker above it is not own
jq -n --arg m "$QAM" '{key: "AB-3", fields: {description: "SECRETWORD d", updated: "2026-11-06T09:00:00.000+0000",
  comment: {startAt: 0, maxResults: 2, total: 2, comments: [
    {id: "930", created: "2026-11-06 09:00:00+00:00", updated: "2026-11-06 09:00:00+00:00",
     body: {type: "doc", version: 1, content: [
       {type: "paragraph", content: [{type: "text", text: "SECRETWORD record"}]},
       {type: "paragraph", content: [{type: "text", text: $m}]},
       {type: "paragraph", content: []}, {type: "paragraph", content: [{type: "text", text: " "}]}]}},
    {id: "931", created: "2026-11-06 09:01:00+00:00", updated: "2026-11-06 09:01:00+00:00",
     body: {type: "doc", version: 1, content: [
       {type: "paragraph", content: [{type: "text", text: $m}]},
       {type: "mediaSingle", content: [{type: "media", attrs: {id: "x", type: "file"}}]}]}}]}}}' > "$WORK/j-qa-tail.json"
run snapshot --jira "$WORK/j-qa-tail.json" --out "$WORK/jq-tail.json"
[ "$(jq -c '[.comments[].own]' "$WORK/jq-tail.json")" = '[true,false]' ] || fail "4d jira ADF tail own flags"

# (5) no baseline → everything non-own is new, description counts as changed
run compare - "$WORK/same.json"
[ "$RC" = 3 ] && [ "$OUT" = "Tracker comments: new 900 901; no baseline — description and every comment count as new" ] \
  || fail "5 no baseline: $RC $OUT"
run compare "$WORK/missing.json" "$WORK/same.json"
[ "$RC" = 3 ] || fail "5 a missing baseline file is no baseline"

# ---- jira: raw REST page, MCP issue, MCP-wrapped string -------------------------------------------
jc() { jq -n --arg i "$1" --arg b "$2" '{id: $i, body: $b, created: "2026-10-06 19:07:18+00:00",
  updated: "2026-10-06 19:07:18+00:00", author: {display_name: "A", displayName: "A"}}'; }
C1=$(jc 15100 $'SECRETWORD wrap\n\n[wrapup alfa-20261006-190718 comment-1]'); C2=$(jc 15101 "SECRETWORD needs")
jq -n --argjson a "$C1" --argjson b "$C2" '{key: "AB-1", fields: {description: "SECRETWORD d",
  updated: "2026-10-06T19:00:00.000+0000", comment: {startAt: 0, maxResults: 2, total: 2, comments: [$a, $b]}}}' > "$WORK/j-rest.json"
run snapshot --jira "$WORK/j-rest.json" --out "$WORK/j1.json"
[ "$RC" = 0 ] && [ "$OUT" = "key=AB-1 comments=2 status=complete" ] || fail "jira REST complete: $RC $OUT"
jq '.fields.comment.total = 80' "$WORK/j-rest.json" > "$WORK/j-rest80.json"
run snapshot --jira "$WORK/j-rest80.json" --out "$WORK/j80.json"
[ "$OUT" = "key=AB-1 comments=2 status=possibly-truncated" ] || fail "jira REST total > page: $OUT"
jq -n --argjson a "$C1" --argjson b "$C2" '{key: "AB-1", description: "SECRETWORD d", comments: [$a, $b]}' > "$WORK/j-mcp.json"
jq -n --arg r "$(cat "$WORK/j-mcp.json")" '{result: $r}' > "$WORK/j-wrap.json"
run snapshot --jira "$WORK/j-wrap.json" --out "$WORK/j2.json"
[ "$RC" = 0 ] && [ "$OUT" = "key=AB-1 comments=2 status=complete" ] || fail "jira MCP-wrapped: $RC $OUT"
[ "$(jq -c '[.comments[].own]' "$WORK/j2.json")" = '[true,false]' ] || fail "jira own marker"
run snapshot --jira "$WORK/j-mcp.json" --limit 2 --out "$WORK/j3.json"
[ "$OUT" = "key=AB-1 comments=2 status=possibly-truncated" ] || fail "jira MCP at the limit: $OUT"
jq '.comments = []' "$WORK/j-mcp.json" > "$WORK/j-empty.json"
run snapshot --jira "$WORK/j-empty.json" --out "$WORK/j4.json"
[ "$OUT" = "key=AB-1 comments=0 status=unknown" ] || fail "jira empty read is unknown: $OUT"
# an incomplete fresh read → uncertain (exit 4), a missing baseline comment is "missing", not removed
run compare "$WORK/j1.json" "$WORK/j4.json"
[ "$RC" = 4 ] && case "$OUT" in "Tracker comments: uncertain — unknown, 0 read"*"missing 15101") ;; *) false ;; esac \
  || fail "uncertain: $RC $OUT"
# … the contract keeps the baseline after an uncertain read: a later complete read still reports
#     the missing comment as removed, which a baseline replaced by the incomplete read would hide
jq -n --argjson a "$C1" '{key: "AB-1", fields: {description: "SECRETWORD d",
  updated: "2026-10-07T08:00:00.000+0000", comment: {startAt: 0, maxResults: 1, total: 1, comments: [$a]}}}' > "$WORK/j-rest-del.json"
run snapshot --jira "$WORK/j-rest-del.json" --out "$WORK/j5.json"
run compare "$WORK/j1.json" "$WORK/j5.json"
[ "$RC" = 3 ] && [ "$OUT" = "Tracker comments: removed 15101" ] || fail "kept baseline → removed: $RC $OUT"
run compare "$WORK/j4.json" "$WORK/j5.json"
[ "$RC" = 0 ] || fail "an incomplete baseline hides the deletion (expected none new): $RC $OUT"
! grep -q SECRETWORD "$WORK"/j[0-9]*.json || fail "a jira snapshot stores ticket text"

# Jira REST v3 bodies are ADF objects: a changed object is a changed hash
adf() { jq -n --arg t "$1" '{type: "doc", version: 1, content: [{type: "paragraph", content: [{type: "text", text: $t}]}]}'; }
jq --argjson d "$(adf 'SECRETWORD adf v1')" '.fields.description = $d' "$WORK/j-rest.json" > "$WORK/adf1.json"
jq --argjson d "$(adf 'SECRETWORD adf v2')" '.fields.description = $d' "$WORK/j-rest.json" > "$WORK/adf2.json"
run snapshot --jira "$WORK/adf1.json" --out "$WORK/a1.json"; run snapshot --jira "$WORK/adf2.json" --out "$WORK/a2.json"
run compare "$WORK/a1.json" "$WORK/a2.json"
[ "$RC" = 3 ] && [ "$OUT" = "Tracker comments: description changed" ] || fail "ADF description change: $RC $OUT"
! grep -q SECRETWORD "$WORK/a1.json" || fail "an ADF snapshot stores ticket text"

# ---- bad input → 2, nothing echoed --------------------------------------------------------------
echo '{"key": "x", "SECRETWORD": 1}' > "$WORK/bad.json"
run snapshot --jira "$WORK/bad.json" --out "$WORK/x.json"; [ "$RC" = 2 ] || fail "bad jira input: $RC"
run snapshot --github "$WORK/bad.json" --out "$WORK/x.json"; [ "$RC" = 2 ] || fail "bad github input: $RC"
jq 'del(.comments[0].id)' "$WORK/show1.json" > "$WORK/noid.json"
run snapshot --github "$WORK/noid.json" --out "$WORK/x.json"; [ "$RC" = 2 ] || fail "a comment without id: $RC"
run compare "$WORK/base.json" "$WORK/bad.json"; [ "$RC" = 2 ] || fail "compare with a non-snapshot: $RC"
run snapshot --github "$WORK/show1.json"; [ "$RC" = 2 ] || fail "snapshot without --out: $RC"

echo "tracker-snapshot-test: OK ($N runs)"
