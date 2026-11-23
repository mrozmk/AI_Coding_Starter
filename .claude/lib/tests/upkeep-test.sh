#!/usr/bin/env bash
# Offline test of .claude/lib/upkeep.sh — `due` (prime and json), `record`, `decline` — over
# fixture repos under one mktemp -d. HOME and TMPDIR point inside it, commit dates are pinned with
# GIT_AUTHOR_DATE / GIT_COMMITTER_DATE and "today" with UPKEEP_TODAY. No network, no real checkout.
set -u
SRC="$(cd "$(dirname "$0")/../../.." && pwd)"
UP="$SRC/.claude/lib/upkeep.sh"
[ -f "$UP" ] || { echo "upkeep-test: FAIL — $UP missing"; exit 1; }
T=$(mktemp -d) || { echo "upkeep-test: FAIL — mktemp"; exit 1; }
trap 'chmod -R u+w "$T" 2>/dev/null; rm -rf "$T"' EXIT
T="$(cd "$T" && pwd -P)"
export HOME="$T/home" TMPDIR="$T/tmp"; mkdir -p "$HOME" "$TMPDIR"
unset UPKEEP_TODAY CLAUDE_PROJECT_DIR
TODAY=2026-06-30
TAB=$(printf '\t')
N=0; fail=0; SEQ=0
ok() {  # <label> <exit status of the check>
  N=$((N + 1))
  if [ "$2" = 0 ]; then echo "PASS $1"; else fail=1; echo "FAIL $1"; fi
}
mkrepo() { mkdir -p "$1" && git -C "$1" -c init.defaultBranch=main init -q; }
commit_at() {  # <dir> <YYYY-MM-DD | full ISO timestamp> <subject> [file…] — one commit at that date
  local d="$1" day="$2" subj="$3" ts f; shift 3
  case "$day" in *T*) ts="$day" ;; *) ts="${day}T12:00:00Z" ;; esac
  [ $# -gt 0 ] || set -- f.txt
  for f in "$@"; do
    SEQ=$((SEQ + 1)); mkdir -p "$(dirname "$d/$f")"; echo "$subj $SEQ" >> "$d/$f"
    git -C "$d" add -- "$f"
  done
  GIT_AUTHOR_DATE="$ts" GIT_COMMITTER_DATE="$ts" \
    git -C "$d" -c user.email=t@t -c user.name=t -c commit.gpgsign=false commit -q -m "$subj"
}
profile() { mkdir -p "$1/.claude" && printf '%s\n' "$2" > "$1/.claude/project-profile.json"; }
OUT=""; ERR=""; RC=0
run() {  # <dir> <args…> — upkeep.sh in <dir> with today pinned; stdout → OUT, stderr → ERR
  local d="$1"; shift
  OUT=$(cd "$d" && UPKEEP_TODAY="$TODAY" bash "$UP" "$@" 2>"$T/err"); RC=$?
  ERR=$(cat "$T/err")
}
jout() { printf '%s' "$OUT" | jq -r "$1" 2>/dev/null; }
item() { jout ".items[] | select(.id == \"$1\") | $2"; }
has_row() { printf '%s\n' "$OUT" | grep -q "^UPKEEP_DUE${TAB}$1${TAB}"; }
rows() { printf '%s\n' "$OUT" | grep -c . || true; }
PROF='{"upkeep":{"cleanup_workflow":{"commits":3,"min_days":5},"architecture_review":{"feat_commits":2,"min_days":5},"refresh_brief":true}}'
PRD=docs/PRD.md; BRIEF=.agents/memory/project-brief.md
SHA_X=0123456789abcdef0123456789abcdef01234567

# 1. nothing due
R="$T/r1"; mkrepo "$R"; profile "$R" "$PROF"
commit_at "$R" 2026-06-01 "chore: a"; commit_at "$R" 2026-06-02 "chore: b"
run "$R" due
[ "$RC" = 0 ] && [ -z "$OUT" ]; ok "nothing due — prime prints nothing, exit 0" $?

# 2. cleanup-workflow due
R2="$T/r2"; mkrepo "$R2"; profile "$R2" "$PROF"
for d in 01 02 03 04; do commit_at "$R2" "2026-06-$d" "chore: $d"; done
run "$R2" due
st=1
[ "$RC" = 0 ] && [ "$(rows)" = 1 ] \
  && case "$OUT" in "UPKEEP_DUE${TAB}/maintain:cleanup-workflow${TAB}"*commits*) st=0 ;; esac
ok "cleanup-workflow due — one prime row" $st

# 3. architecture-review: feat commits counted, a merge subject from feat/x is not
R="$T/r3"; mkrepo "$R"; profile "$R" "$PROF"
commit_at "$R" 2026-06-01 "feat: a"; commit_at "$R" 2026-06-02 "feat: b"
commit_at "$R" 2026-06-03 "fix: c"; commit_at "$R" 2026-06-04 "feat: d"
commit_at "$R" 2026-06-05 "Merge pull request #1 from feat/x"
run "$R" due; st=1; has_row /architecture-review && st=0
run "$R" due --format json
[ "$st" = 0 ] && [ "$(item architecture-review .numbers.feat_commits)" = 3 ]
ok "architecture-review due — feat commits counted" $?

# 4. refresh-brief: PRD content changed since the record
R="$T/r4"; mkrepo "$R"; profile "$R" "$PROF"
commit_at "$R" 2026-06-01 "docs: prd and brief" "$PRD" "$BRIEF"
run "$R" record refresh-brief; st=$RC
echo "edited" >> "$R/$PRD"
run "$R" due
[ "$st" = 0 ] && printf '%s\n' "$OUT" \
  | grep -qx "UPKEEP_DUE${TAB}/maintain:refresh-brief${TAB}docs/PRD.md changed since the last refresh"
ok "refresh-brief due — PRD content changed since the record" $?

# 5. one threshold alone is never enough
R="$T/r5a"; mkrepo "$R"; profile "$R" "$PROF"
for i in 1 2 3 4 5 6 7 8 9 10; do commit_at "$R" "${TODAY}T0$((i % 10)):00:00Z" "chore: $i"; done
run "$R" due --format json
[ "$(item cleanup-workflow .due)" = false ] && [ "$(item cleanup-workflow .numbers.commits)" = 10 ]
ok "commits threshold alone is not enough" $?
R="$T/r5b"; mkrepo "$R"; profile "$R" "$PROF"; commit_at "$R" 2026-01-01 "chore: old"
run "$R" due --format json
[ "$(item cleanup-workflow .due)" = false ] && [ "$(item cleanup-workflow .numbers.days)" = 180 ]
ok "days threshold alone is not enough" $?

# 6. never recorded: the baseline is the root commit; every key for every enabled item
R="$T/r6"; mkrepo "$R"; profile "$R" "$PROF"
commit_at "$R" 2026-06-10 "chore: a"; commit_at "$R" 2026-06-12 "chore: b"
run "$R" due --format json
[ "$(item cleanup-workflow .baseline.kind)" = none ] && [ "$(item cleanup-workflow .numbers.days)" = 20 ]
ok "never recorded — baseline is the root commit" $?
printf '%s' "$OUT" | jq -e '.schema == 1 and (.items | length) == 3
  and ([.items[].id] == ["refresh-brief", "cleanup-workflow", "architecture-review"])
  and all(.items[]; (keys == ["ask","baseline","command","due","home","id","numbers","reason","record","record_error","state","thresholds"])
                    and .home == "." and .record == ".agents/upkeep.json")' >/dev/null
ok "json lists every key for every enabled item" $?

# 7. record clears the row and writes last_run
run "$R2" record cleanup-workflow; st=$RC; rec_out=$OUT
run "$R2" due
head2=$(git -C "$R2" rev-parse HEAD)
[ "$st" = 0 ] && [ "$rec_out" = "upkeep: recorded cleanup-workflow in .agents/upkeep.json" ] && [ -z "$OUT" ] \
  && jq -e --arg h "$head2" --arg d "$TODAY" \
    '.schema == 1 and .items["cleanup-workflow"].last_run == {date: $d, commit: $h}' \
    "$R2/.agents/upkeep.json" >/dev/null \
  && [ "${#head2}" = 40 ]
ok "record clears the row and writes last_run" $?

# 8. a recorded commit that is no ancestor of HEAD falls back to the recorded date
R="$T/r8"; mkrepo "$R"; profile "$R" "$PROF"
commit_at "$R" 2026-06-01 "chore: a"; commit_at "$R" 2026-06-02 "chore: b"
git -C "$R" switch -q -c side; commit_at "$R" 2026-06-03 "chore: side"
run "$R" record cleanup-workflow; st=$RC
git -C "$R" switch -q main
run "$R" due --format json
[ "$st" = 0 ] && [ "$(item cleanup-workflow .baseline.kind)" = date ] \
  && [ "$(item cleanup-workflow .baseline.value)" = "$TODAY" ]
ok "non-ancestor commit, object present — date fallback" $?
R="$T/r8b"; mkrepo "$R"; profile "$R" "$PROF"
commit_at "$R" 2026-06-01 "chore: a"; commit_at "$R" 2026-06-08 "chore: b"
mkdir -p "$R/.agents"
printf '{"schema":1,"items":{"cleanup-workflow":{"last_run":{"date":"2026-06-05","commit":"%s"}}}}\n' \
  "$SHA_X" > "$R/.agents/upkeep.json"
run "$R" due --format json
[ "$(item cleanup-workflow .baseline.kind)" = date ] && [ "$(item cleanup-workflow .baseline.value)" = 2026-06-05 ] \
  && [ "$(item cleanup-workflow .numbers.commits)" = 1 ]
ok "non-ancestor commit, object absent — date fallback" $?

# 9. the date fallback counts from UTC midnight
R="$T/r9"; mkrepo "$R"; profile "$R" "$PROF"
commit_at "$R" 2026-06-01 "chore: root"
commit_at "$R" 2026-06-09T23:30:00Z "chore: before midnight"
commit_at "$R" 2026-06-10T00:30:00Z "chore: after midnight"
mkdir -p "$R/.agents"
printf '{"schema":1,"items":{"cleanup-workflow":{"last_run":{"date":"2026-06-10","commit":"%s"}}}}\n' \
  "$SHA_X" > "$R/.agents/upkeep.json"
run "$R" due --format json
[ "$(item cleanup-workflow .numbers.commits)" = 1 ]; ok "date fallback counts from UTC midnight" $?

# 10. PRD edited, refreshed, committed with the brief and the record — not due
R="$T/r10"; mkrepo "$R"; profile "$R" "$PROF"
commit_at "$R" 2026-06-01 "docs: prd and brief" "$PRD" "$BRIEF"
echo "edited" >> "$R/$PRD"; echo "refreshed" >> "$R/$BRIEF"
run "$R" record refresh-brief; st=$RC
git -C "$R" add -- "$PRD" "$BRIEF" .agents/upkeep.json
GIT_AUTHOR_DATE=2026-06-02T12:00:00Z GIT_COMMITTER_DATE=2026-06-02T12:00:00Z \
  git -C "$R" -c user.email=t@t -c user.name=t -c commit.gpgsign=false commit -q -m "docs: refresh"
run "$R" due
[ "$st" = 0 ] && [ "$RC" = 0 ] && [ -z "$OUT" ]; ok "PRD edited, refreshed, committed together — not due" $?

# 11. refresh-brief never recorded: PRD commits the brief's last commit does not contain
R="$T/r11a"; mkrepo "$R"; profile "$R" "$PROF"
commit_at "$R" 2026-06-01 "docs: brief" "$BRIEF"; commit_at "$R" 2026-06-02 "docs: prd" "$PRD"
run "$R" due
printf '%s\n' "$OUT" | grep -qx \
  "UPKEEP_DUE${TAB}/maintain:refresh-brief${TAB}never recorded — docs/PRD.md has commits the brief does not"
ok "refresh-brief never recorded — PRD committed after the brief is due" $?
R="$T/r11b"; mkrepo "$R"; profile "$R" "$PROF"
commit_at "$R" 2026-06-01 "docs: prd" "$PRD"; commit_at "$R" 2026-06-02 "docs: brief" "$BRIEF"
run "$R" due --format json
[ "$(item refresh-brief .due)" = false ]; ok "refresh-brief never recorded — PRD older than the brief is not due" $?

# 12. decline keeps due, clears ask; ask returns once the thresholds are crossed from the decline
R12="$T/r12"; mkrepo "$R12"; profile "$R12" "$PROF"
for d in 01 02 03 04; do commit_at "$R12" "2026-06-$d" "chore: $d"; done
run "$R12" decline cleanup-workflow; st=$RC; dec_out=$OUT
run "$R12" due --format json
[ "$st" = 0 ] && [ "$dec_out" = "upkeep: declined cleanup-workflow in .agents/upkeep.json" ] \
  && [ "$(item cleanup-workflow .due)" = true ] && [ "$(item cleanup-workflow .ask)" = false ]
ok "decline keeps due, clears ask" $?
for d in 01 02 03; do commit_at "$R12" "2026-07-$d" "chore: july $d"; done
TODAY=2026-07-10; run "$R12" due --format json; TODAY=2026-06-30
[ "$(item cleanup-workflow .due)" = true ] && [ "$(item cleanup-workflow .ask)" = true ]
ok "ask returns once thresholds are crossed after the decline" $?

# 13. PRD A recorded, declined at B, restored to A
R="$T/r13"; mkrepo "$R"; profile "$R" "$PROF"
commit_at "$R" 2026-06-01 "docs: prd and brief" "$PRD" "$BRIEF"
run "$R" record refresh-brief; s1=$RC
echo "version B" >> "$R/$PRD"
run "$R" decline refresh-brief; s2=$RC
git -C "$R" checkout -q -- "$PRD"
run "$R" due --format json
[ "$s1" = 0 ] && [ "$s2" = 0 ] && [ "$(item refresh-brief .due)" = false ] && [ "$(item refresh-brief .ask)" = false ]
ok "PRD A recorded, declined at B, restored to A — not due, no ask" $?

# 14. record after a decline clears the decline
run "$R12" record cleanup-workflow
[ "$RC" = 0 ] && jq -e '.items["cleanup-workflow"] | has("declined") | not' "$R12/.agents/upkeep.json" >/dev/null
ok "record after a decline clears the decline" $?

# 15. the silent cases: no stdout, no stderr, exit 0
silent() {  # <label> <dir> [PATH for the run]
  local o rc e
  if [ -n "${3:-}" ]; then
    o=$(cd "$2" && env PATH="$3" UPKEEP_TODAY="$TODAY" /bin/bash "$UP" due 2>"$T/err"); rc=$?
  else
    o=$(cd "$2" && UPKEEP_TODAY="$TODAY" bash "$UP" due 2>"$T/err"); rc=$?
  fi
  e=$(cat "$T/err")
  [ "$rc" = 0 ] && [ -z "$o" ] && [ -z "$e" ]; ok "$1" $?
}
D="$T/nogit"; mkdir -p "$D"; profile "$D" "$PROF"
silent "silent outside a git work tree" "$D"
R="$T/r15"; mkrepo "$R"; profile "$R" "$PROF"
for d in 01 02 03 04; do commit_at "$R" "2026-06-$d" "chore: $d"; done
run "$R" due
if has_row /maintain:cleanup-workflow; then
  mkdir -p "$T/nojq"; ln -s "$(command -v git)" "$T/nojq/git"
  if env PATH="$T/nojq" git -C "$R" rev-parse HEAD >/dev/null 2>&1; then
    silent "silent without jq" "$R" "$T/nojq"
  else
    ok "nojq fixture cannot run git" 1
  fi
else
  ok "silent without jq — the fixture prints no row under the normal PATH" 1
fi
R="$T/r15p"; mkrepo "$R"
for d in 01 02 03 04; do commit_at "$R" "2026-06-$d" "chore: $d"; done
silent "silent without a profile" "$R"
profile "$R" '{"upkeep":false}'
silent "silent with upkeep false" "$R"
profile "$R" "$PROF"; mkdir -p "$R/.agents/team"; echo '{}' > "$R/.agents/team/session.json"
silent "silent in a team clone" "$R"

# 16. an item set to false is off; an invalid threshold is unknown
R="$T/r16"; mkrepo "$R"
for d in 01 02 03 04; do commit_at "$R" "2026-06-$d" "chore: $d"; done
profile "$R" '{"upkeep":{"cleanup_workflow":false}}'
run "$R" due --format json
[ "$(jout '[.items[].id] | join(",")')" = "refresh-brief,architecture-review" ]
ok "an item set to false is absent from json" $?
profile "$R" '{"upkeep":{"cleanup_workflow":{"commits":0,"min_days":0}}}'
run "$R" due --format json
st=1
[ "$(item cleanup-workflow .state)" = unknown ] && [ "$(item cleanup-workflow .reason)" = "invalid commits" ] \
  && [ "$(item cleanup-workflow .due)" = false ] && st=0
run "$R" due
[ "$st" = 0 ] && ! has_row /maintain:cleanup-workflow; ok "commits 0 is invalid — unknown state, no row" $?

# 17. record with the item off is a no-op
R="$T/r17"; mkrepo "$R"; commit_at "$R" 2026-06-01 "chore: a"
profile "$R" '{"upkeep":{"cleanup_workflow":false}}'
run "$R" record cleanup-workflow
[ "$RC" = 0 ] && [ "$OUT" = "upkeep: cleanup-workflow is off — nothing recorded" ] && [ ! -e "$R/.agents/upkeep.json" ]
ok "record with the item off is a no-op" $?

# 18. repo override: the home checkout's history and record decide the item
AP='{"upkeep":{"cleanup_workflow":false,"refresh_brief":false,"architecture_review":{"feat_commits":2,"min_days":5,"repo":"%s"}}}'
pair() {  # <A> <B> <repo value> — B with three feat commits and no profile, A pointing at it
  mkrepo "$2"; for d in 01 02 03; do commit_at "$2" "2026-06-$d" "feat: $d"; done
  mkrepo "$1"; commit_at "$1" 2026-06-01 "chore: a"
  profile "$1" "$(printf "$AP" "$3")"
}
A="$T/pair/A"; B="$T/pair/B"; pair "$A" "$B" ../B
run "$A" due; st=1
printf '%s\n' "$OUT" | grep -qx \
  "UPKEEP_DUE${TAB}/architecture-review${TAB}3 feat commits and 29 days since the first commit — never recorded in ../B — run it from that checkout" \
  && st=0
run "$A" due --format json
[ "$st" = 0 ] && [ "$(item architecture-review .numbers.feat_commits)" = 3 ] \
  && [ "$(item architecture-review .home)" = ../B ] \
  && [ "$(item architecture-review .record)" = ../B/.agents/upkeep.json ]
ok "repo override — counts and record come from the home checkout" $?
run "$A" record architecture-review --only-if-home
[ "$RC" = 0 ] && [ "$OUT" = "upkeep: architecture-review tracks ../B — this run was not there; nothing recorded" ] \
  && [ ! -e "$B/.agents/upkeep.json" ] && [ ! -e "$A/.agents/upkeep.json" ]
ok "record --only-if-home in a non-home checkout records nothing" $?
run "$A" record architecture-review; s1=$RC; o1=$OUT
run "$A" decline architecture-review; s2=$RC
hb=$(git -C "$B" rev-parse HEAD)
[ "$s1" = 0 ] && [ "$s2" = 0 ] && [ "$o1" = "upkeep: recorded architecture-review in ../B/.agents/upkeep.json" ] \
  && jq -e --arg h "$hb" '.items["architecture-review"] | .last_run.commit == $h and .declined.commit == $h' \
    "$B/.agents/upkeep.json" >/dev/null \
  && [ ! -e "$A/.agents/upkeep.json" ]
ok "record and decline land in the home record" $?
A2="$T/pair2/A2"; B2="$T/pair2/B2"; pair "$A2" "$B2" ../B2
run "$A2" due; st=1; has_row /architecture-review && st=0
run "$B2" record architecture-review --only-if-home; s2=$RC; o2=$OUT
hb2=$(git -C "$B2" rev-parse HEAD)
run "$A2" due
[ "$st" = 0 ] && [ "$s2" = 0 ] && [ "$o2" = "upkeep: recorded architecture-review in .agents/upkeep.json" ] \
  && jq -e --arg h "$hb2" '.items["architecture-review"].last_run.commit == $h' "$B2/.agents/upkeep.json" >/dev/null \
  && ! has_row /architecture-review
ok "home without a profile records its own run and clears the row in the pointing repo" $?
A3="$T/pair3/A3"; mkrepo "$A3"; commit_at "$A3" 2026-06-01 "chore: a"; profile "$A3" "$(printf "$AP" ../nowhere)"
run "$A3" due --format json; st=1
[ "$(item architecture-review .state)" = unknown ] \
  && [ "$(item architecture-review .reason)" = "unknown — ../nowhere not found" ] && st=0
run "$A3" due
[ "$st" = 0 ] && [ "$RC" = 0 ] && [ -z "$OUT" ]; ok "missing repo — unknown in json, no prime row" $?

# 19. a corrupt record is never overwritten; a subdirectory repo; no commit yet
R="$T/r19"; mkrepo "$R"; profile "$R" "$PROF"
for d in 01 02 03 04; do commit_at "$R" "2026-06-$d" "chore: $d"; done
mkdir -p "$R/.agents"; st=0
for body in '{' '' '{}{}'; do
  printf '%s' "$body" > "$R/.agents/upkeep.json"; cp "$R/.agents/upkeep.json" "$T/saved"
  run "$R" record cleanup-workflow; [ "$RC" = 1 ] || st=1
  cmp -s "$R/.agents/upkeep.json" "$T/saved" || st=1
  run "$R" due --format json; [ "$RC" = 0 ] || st=1
  [ "$(item cleanup-workflow .record_error)" = true ] || st=1
done
ok "corrupt record is not overwritten" $st
A="$T/sub/A"; B="$T/sub/B"
mkrepo "$B"; commit_at "$B" 2026-06-01 "feat: a" sub/x.txt; commit_at "$B" 2026-06-02 "feat: b"
mkrepo "$A"; commit_at "$A" 2026-06-01 "chore: a"; profile "$A" "$(printf "$AP" ../B/sub)"
run "$A" due --format json; st=1
[ "$(item architecture-review .record)" = ../B/.agents/upkeep.json ] && st=0
run "$A" record architecture-review
hb=$(git -C "$B" rev-parse HEAD)
[ "$st" = 0 ] && [ "$RC" = 0 ] \
  && jq -e --arg h "$hb" '.items["architecture-review"].last_run.commit == $h' "$B/.agents/upkeep.json" >/dev/null
ok "repo naming a subdirectory uses that checkout's record" $?
R="$T/r19c"; mkrepo "$R"; profile "$R" "$PROF"
run "$R" record cleanup-workflow; s1=$RC
run "$R" decline cleanup-workflow; s2=$RC
[ "$s1" = 1 ] && [ "$s2" = 1 ] && [ ! -e "$R/.agents/upkeep.json" ]
ok "record before the first commit is refused" $?

# 20. usage errors exit 2
st=0
run "$R2" frob; [ "$RC" = 2 ] || st=1
run "$R2" record nope; [ "$RC" = 2 ] || st=1
run "$R2" due --format xml; [ "$RC" = 2 ] || st=1
run "$R2" record cleanup-workflow --expect-prd-blob abc; [ "$RC" = 2 ] || st=1
ok "usage errors exit 2" $st

# 21. --expect-head / --expect-prd-blob: record exactly what the command read
R="$T/r21"; mkrepo "$R"; profile "$R" "$PROF"
commit_at "$R" 2026-06-01 "feat: a"; commit_at "$R" 2026-06-02 "feat: b"
old=$(git -C "$R" rev-parse HEAD); commit_at "$R" 2026-06-03 "chore: c"; new=$(git -C "$R" rev-parse HEAD)
run "$R" record architecture-review --only-if-home --expect-head "$old"; st=1
[ "$RC" = 0 ] && [ "$OUT" = "upkeep: architecture-review reviewed $old, HEAD is now $new — nothing recorded" ] \
  && [ ! -e "$R/.agents/upkeep.json" ] && st=0
run "$R" record architecture-review --only-if-home --expect-head "$new"
[ "$st" = 0 ] && [ "$RC" = 0 ] \
  && jq -e --arg h "$new" '.items["architecture-review"].last_run.commit == $h' "$R/.agents/upkeep.json" >/dev/null
ok "expect-head mismatch records nothing" $?
R="$T/r21b"; mkrepo "$R"; profile "$R" "$PROF"
commit_at "$R" 2026-06-01 "docs: prd and brief" "$PRD" "$BRIEF"
blob=$(git -C "$R" hash-object "$PRD"); echo "edited" >> "$R/$PRD"; cur=$(git -C "$R" hash-object "$PRD")
run "$R" record refresh-brief --expect-prd-blob "$blob"; st=1
[ "$RC" = 0 ] && [ "$OUT" = "upkeep: refresh-brief read PRD $blob, docs/PRD.md is now $cur — nothing recorded" ] \
  && [ ! -e "$R/.agents/upkeep.json" ] && st=0
run "$R" record refresh-brief --expect-prd-blob "$cur"
[ "$st" = 0 ] && [ "$RC" = 0 ] \
  && jq -e --arg b "$cur" '.items["refresh-brief"].last_run.prd_blob == $b' "$R/.agents/upkeep.json" >/dev/null
ok "expect-prd-blob mismatch records nothing" $?

# 22. a failed write keeps the old record and prints no receipt
R="$T/r22"; mkrepo "$R"; profile "$R" "$PROF"; commit_at "$R" 2026-06-01 "chore: a"
run "$R" record cleanup-workflow; s1=$RC
cp "$R/.agents/upkeep.json" "$T/saved22"; commit_at "$R" 2026-06-02 "chore: b"
chmod a-w "$R/.agents"
run "$R" record cleanup-workflow; s2=$RC; o2=$OUT
chmod u+w "$R/.agents"
[ "$s1" = 0 ] && [ "$s2" = 1 ] && case "$o2" in *"upkeep: recorded"*) false ;; *) true ;; esac \
  && cmp -s "$R/.agents/upkeep.json" "$T/saved22"
ok "failed rename keeps the old record and prints no receipt" $?

[ "$fail" = 0 ] || { echo "upkeep-test: FAIL"; exit 1; }
echo "upkeep-test: OK ($N checks)"
