#!/usr/bin/env bash
# Offline test of .claude/lib/team-inbox.sh's queue verbs: list, done, prune, and write's publication
# (a unique name, never over an existing message, a parallel writer takes the next -n).
# The script runs from a fixture lib dir without session-host.sh, so write never rings anything
# (`ring: 127`); `date` is a stub, so every write lands in the same second.
set -u
SRC="$(cd "$(dirname "$0")/.." && pwd)/team-inbox.sh"
[ -f "$SRC" ] || { echo "team-inbox-test: FAIL — $SRC missing"; exit 1; }
T=$(mktemp -d "${TMPDIR:-/tmp}/team inbox.XXXXXX") || { echo "team-inbox-test: FAIL — mktemp"; exit 1; }
trap 'rm -rf "$T"' EXIT
die() { echo "team-inbox-test: FAIL — fixture setup: $1"; exit 1; }
mkdir -p "$T/lib" "$T/bin" "$T/main/.agents" || die "dirs"
cp "$SRC" "$T/lib/team-inbox.sh" || die "copy"
cat > "$T/bin/date" <<'EOF' || die "date stub"
#!/bin/sh
echo "${FAKE_NOW:-20261115T120000Z}"
EOF
chmod +x "$T/bin/date" || die "chmod"
M="$T/main"; D="$M/.agents/team/inbox/alfa"
n=0; fail=0
ok() { n=$((n + 1)); if ! eval "$1"; then echo "FAIL [$2]"; fail=1; fi; }
ti() { PATH="$T/bin:$PATH" bash "$T/lib/team-inbox.sh" "$@"; }
w() { ti --main "$M" write alfa "$@" 2>/dev/null; }

# ---- list / done (T4) ---------------------------------------------------------------------------
out=$(ti --main "$M" list alfa 2>&1); rc=$?
ok '[ "$rc" = 0 ] && [ -z "$out" ]' "list on a missing inbox is empty, exit 0"
p1=$(FAKE_NOW=20261115T120005Z w collision-answer --from Supervisor --ticket 7 --run r1); rc=$?
ok '[ "$rc" = 0 ] && [ "$p1" = "$D/new/20261115T120005Z-Supervisor-collision-answer.md" ]' \
  "write prints the new/ path"
ok 'grep -qx "id: 20261115T120005Z-Supervisor-collision-answer" "$p1" && grep -qx "run: r1" "$p1"' \
  "write's frontmatter carries id and run"
p0=$(FAKE_NOW=20261115T120001Z w message --from Supervisor)
out=$(ti --main "$M" list alfa)
ok '[ "$out" = "$p0"$'"'"'\n'"'"'"$p1" ]' "list is sorted oldest first, full paths"
out=$(ti --main "$M" done alfa "$p0" 2>&1); rc=$?
ok '[ "$rc" = 0 ] && [ "$out" = "$D/done/$(basename "$p0")" ] && [ -f "$D/done/$(basename "$p0")" ] && [ ! -e "$p0" ]' \
  "done moves the file to done/ and prints its path"
out=$(ti --main "$M" done alfa "$p0" 2>&1); rc=$?
ok '[ "$rc" = 1 ] && [[ "$out" == *"is not in"* ]]' "done on a file not in new/ exits 1"
out=$(ti --main "$M" done alfa "/elsewhere/dir/$(basename "$p1")" 2>&1); rc=$?
ok '[ "$rc" = 0 ] && [ -f "$D/done/$(basename "$p1")" ]' "done uses the basename of its argument"
out=$(ti --main "$M" list alfa)
ok '[ -z "$out" ]' "list after done is empty"
out=$(ti --main "$M" done 'al fa' x 2>&1); rc=$?
ok '[ "$rc" = 2 ]' "a bad address exits 2"
C="$T/clone"; mkdir -p "$C/.agents/team" && echo '{"team":"alfa"}' > "$C/.agents/team/team.json" \
  && git -C "$C" init -q || die "clone"
out=$(cd "$C" && PATH="$T/bin:$PATH" bash "$T/lib/team-inbox.sh" list alfa 2>&1); rc=$?
ok '[ "$rc" = 2 ] && [[ "$out" == *"team clone"* ]]' "a team clone without --main exits 2"

# ---- write never replaces a message (T3) --------------------------------------------------------
a=$(w accepted --from Supervisor); b=$(w accepted --from Supervisor)
ok '[ "$a" = "$D/new/20261115T120000Z-Supervisor-accepted.md" ] && [ "$b" = "$D/new/20261115T120000Z-Supervisor-accepted-2.md" ]' \
  "the same name in the same second takes -2"
ok 'grep -qx "id: 20261115T120000Z-Supervisor-accepted-2" "$b"' "the suffixed message's id matches its name"
mkdir -p "$D/done" && echo old > "$D/done/20261115T120009Z-Supervisor-closed.md" || die "done file"
c=$(FAKE_NOW=20261115T120009Z w closed --from Supervisor)
ok '[ "$c" = "$D/new/20261115T120009Z-Supervisor-closed-2.md" ]' "a name already in done/ is skipped"
echo keep > "$D/new/20261115T120010Z-Supervisor-closed.md" || die "kept file"
c=$(FAKE_NOW=20261115T120010Z w closed --from Supervisor)
ok '[ "$(cat "$D/new/20261115T120010Z-Supervisor-closed.md")" = keep ] && [ "$c" = "$D/new/20261115T120010Z-Supervisor-closed-2.md" ]' \
  "an existing message in new/ is never replaced"
for i in $(seq 1 20); do FAKE_NOW=20261115T120020Z w session_dead --from Supervisor --message "m$i" >/dev/null & done
wait
cnt=$(ls "$D/new" | grep -c '^20261115T120020Z-Supervisor-session_dead')
ids=$(cat "$D/new"/20261115T120020Z-Supervisor-session_dead* | sed -n 's/^id: //p' | sort -u | wc -l | tr -d ' ')
msgs=$(cat "$D/new"/20261115T120020Z-Supervisor-session_dead* | grep -c '^m[0-9]*$')
ok '[ "$cnt" = 20 ] && [ "$ids" = 20 ] && [ "$msgs" = 20 ]' "20 parallel writes in one second keep 20 messages ($cnt files, $ids ids, $msgs bodies)"
ok '[ -z "$(ls -A "$D/tmp")" ]' "tmp/ holds no leftover"

# ---- prune: done/ by age, every address, never tmp/ or new/ (#106) ------------------------------
B="$M/.agents/team/inbox/Supervisor"
mkdir -p "$B/done" "$B/new" "$B/tmp" || die "second address"
for f in "$D/done/old-a.md" "$B/done/old-b.md" "$D/new/old-new.md" "$B/tmp/old-tmp.md"; do
  echo old > "$f" && touch -t 202001010000 "$f" || die "old file $f"
done
echo recent > "$B/done/recent.md" || die "recent file"
out=$(ti --main "$M" prune --days 100000 2>&1); rc=$?
ok '[ "$rc" = 0 ] && [ -f "$D/done/old-a.md" ] && [ -f "$B/done/old-b.md" ]' "prune --days N keeps messages younger than N days"
out=$(ti --main "$M" prune 2>&1); rc=$?
ok '[ "$rc" = 0 ] && [ ! -e "$D/done/old-a.md" ] && [ ! -e "$B/done/old-b.md" ]' \
  "prune (default 30 days) deletes old done/ messages of every address"
ok '[[ "$out" == "pruned: 2 done/ message(s) older than 30 day(s)"* ]]' "prune reports the count ($out)"
ok '[ -f "$B/done/recent.md" ] && [ -f "$D/done/$(basename "$p0")" ]' "prune keeps recent done/ messages"
ok '[ -f "$D/new/old-new.md" ] && [ -f "$B/tmp/old-tmp.md" ]' "prune never touches new/ or tmp/"
out=$(ti --main "$M" prune --days x 2>&1); rc=$?
ok '[ "$rc" = 2 ]' "prune --days with a non-number exits 2"
out=$(mkdir -p "$T/fresh/.agents" && ti --main "$T/fresh" prune 2>&1); rc=$?
ok '[ "$rc" = 0 ] && [[ "$out" == "pruned: 0 "* ]]' "prune with no inbox yet prunes nothing, exit 0"
out=$(cd "$C" && PATH="$T/bin:$PATH" bash "$T/lib/team-inbox.sh" prune 2>&1); rc=$?
ok '[ "$rc" = 2 ] && [[ "$out" == *"team clone"* ]]' "prune in a team clone without --main exits 2"

# ---- #323: a clearance request rings the Supervisor -------------------------------------------
mkdir -p "$M/.agents/team/anchors" && echo '{"team":"alfa"}' > "$M/.agents/team/anchors/alfa.json" || die "anchor"
s1=$(FAKE_NOW=20261127T120000Z ti --main "$M" write Supervisor clearance --from alfa --ticket 9 --run r9 \
  --ref clearance/requests/c-1-0123456789abcdef.json 2>/dev/null); rc1=$?
s2=$(FAKE_NOW=20261127T120001Z ti --main "$M" write Supervisor clearance --from adhoc-probe 2>/dev/null); rc2=$?
s3=$(FAKE_NOW=20261127T120002Z ti --main "$M" write Supervisor bogus --from alfa 2>/dev/null); rc3=$?
ok '[ "$rc1" = 0 ] && grep -qx "event: clearance" "$s1" && grep -qx "ref: clearance/requests/c-1-0123456789abcdef.json" "$s1" && [ "$rc2" = 0 ] && [ "$rc3" = 2 ]' \
  "#323 clearance event to Supervisor from a role (and a team); another event still refused"
s4=$(FAKE_NOW=20261127T120003Z ti --main "$M" write Supervisor decision --from alfa --ticket 9 --run r9 \
  --ref runs/r9/decisions/d-1.md --message "d-1: which way" 2>/dev/null); rc4=$?
s5=$(FAKE_NOW=20261127T120004Z ti --main "$M" write Supervisor decision --from adhoc-probe 2>/dev/null); rc5=$?
ok '[ "$rc4" = 0 ] && grep -qx "event: decision" "$s4" && grep -qx "ref: runs/r9/decisions/d-1.md" "$s4" && grep -qx "d-1: which way" "$s4" && [ "$rc5" = 2 ]' \
  "a decision event to Supervisor from a team; refused from a role or ad-hoc session"

[ "$fail" -eq 0 ] || exit 1
echo "team-inbox-test: OK ($n checks)"
