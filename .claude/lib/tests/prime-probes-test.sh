#!/usr/bin/env bash
# Offline test of every `!`-probe in .claude/commands/prime.md: each one exits 0 on
# empty and partial input, keeps its semantics, and uses no form the team-clone skill-load
# permission check rejects (`-exec`, awk, sed, sort, xargs, `$(`).
set -u
PRIME="$(cd "$(dirname "$0")/../.." && pwd)/commands/prime.md"
EXPECTED_PROBES=12
[ -f "$PRIME" ] || { echo "prime-probes-test: FAIL — $PRIME missing"; exit 1; }
T=$(mktemp -d "${TMPDIR:-/tmp}/prime probes.XXXXXX") \
  || { echo "prime-probes-test: FAIL — mktemp"; exit 1; }
trap 'rm -rf "$T"' EXIT
die() { echo "prime-probes-test: FAIL — fixture setup: $1"; exit 1; }
fail=0; CHECKS=0
bad() { echo "FAIL [$1]: $2"; fail=1; }

# Inside Claude Code `rg` is a shell function over the claude binary, invisible to `bash -c`.
if ! command -v rg >/dev/null 2>&1; then
  [ -x "${CLAUDE_CODE_EXECPATH:-}" ] || die "no rg and no CLAUDE_CODE_EXECPATH"
  mkdir -p "$T/bin" || die "bin"
  printf '#!/usr/bin/env bash\nexec -a rg %q "$@"\n' "$CLAUDE_CODE_EXECPATH" > "$T/bin/rg" \
    && chmod +x "$T/bin/rg" || die "rg shim"
  export PATH="$T/bin:$PATH"
fi

probes=()
while IFS= read -r line; do probes+=("$line"); done \
  < <(sed -n 's/^[[:space:]]*!`\(.*\)`$/\1/p' "$PRIME")
[ "${#probes[@]}" -eq "$EXPECTED_PROBES" ] \
  || { echo "prime-probes-test: FAIL — ${#probes[@]} probes, expected $EXPECTED_PROBES"; exit 1; }
for p in "${probes[@]}"; do
  CHECKS=$((CHECKS + 1))
  if grep -Eq -- '-exec|\$\(|(^|[|;&[:space:]])(awk|sed|sort|xargs)([[:space:]]|$)' <<<"$p"; then
    bad "forbidden form" "$p"
  fi
done

probe() {  # <unique substring> → the one probe containing it
  local p hit="" n=0
  for p in "${probes[@]}"; do case "$p" in *"$1"*) hit="$p"; n=$((n + 1)) ;; esac; done
  [ "$n" -eq 1 ] || { echo "probe matching '$1' found $n times" >&2; return 1; }
  printf '%s' "$hit"
}
P_TREE=$(probe 'rg --files --max-depth') && P_DOMAIN=$(probe 'memory/domain/*.md') \
  && P_MEM=$(probe MEMORY_TOTAL) && P_REF=$(probe REFERENCE_LOADED) \
  && P_SPECS=$(probe SPECS_TOTAL) && P_NL=$(probe NOT_LOADED) \
  && P_ACTIVE=$(probe 'plans/active') && P_DONE=$(probe 'plans/done') \
  && P_SYNC=$(probe 'status -sb') && P_STAT=$(probe "archive/*' -type f -ls") \
  || die "probe lookup"

run_all() {  # <repo> <label> — every probe must exit 0
  local p rc
  for p in "${probes[@]}"; do
    (cd "$1" && bash -c "$p" >/dev/null 2>&1 </dev/null); rc=$?; CHECKS=$((CHECKS + 1))
    [ "$rc" -eq 0 ] || bad "$2: exit $rc" "${p:0:90}"
  done
}
out() {  # <repo> <probe> → its stdout
  (cd "$1" && bash -c "$2" 2>/dev/null </dev/null)
}
repo() {  # <dir> — a one-commit repo, no remote
  mkdir -p "$1" && git -C "$1" init -q \
    && git -C "$1" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init \
    || die "git repo $1"
}
fill() {  # <file> <bytes>
  mkdir -p "$(dirname "$1")" && head -c "$2" /dev/zero | tr '\0' x > "$1" || die "fill $1"
}
TAB=$(printf '\t')

# (a) no .agents at all
A="$T/empty repo"; repo "$A"; run_all "$A" "empty"
[ "$(out "$A" "$P_MEM")" = "MEMORY_TOTAL${TAB}0 files / 0 bytes ≈ 0k tokens (on-disk upper bound)" ] \
  || bad empty "MEMORY_TOTAL: $(out "$A" "$P_MEM")"
grep -qx "REFERENCE_LOADED${TAB}0 files / 0 bytes ≈ 0k tokens" <(out "$A" "$P_REF") \
  || bad empty "REFERENCE_LOADED"
grep -qx "SPECS_TOTAL${TAB}0 files / 0 bytes (listing only — never auto-read)" \
  <(out "$A" "$P_SPECS") || bad empty "SPECS_TOTAL"
[ -z "$(out "$A" "$P_NL")" ] || bad empty "NOT_LOADED rows present"
[ "$(out "$A" "$P_ACTIVE")" = "(no active plans)" ] || bad empty "active plans fallback"
[ -z "$(out "$A" "$P_DONE")" ] || bad empty "done plans listing not empty"
[ -z "$(out "$A" "$P_DOMAIN")$(out "$A" "$P_STAT")" ] || bad empty "memory listings not empty"

# (b) full fixture: memory, reference (CAP + MAXLOAD + MAXSKIP), specs
B="$T/full repo"; repo "$B"
M="$B/.agents/memory"
fill "$M/a b.md" 1234; fill "$M/index.md" 2000; fill "$M/domain/a.md" 300
fill "$M/user-profile.md" 77; fill "$M/archive/x.md" 5000; fill "$M/reflection-protocol.md" 9000
echo '.agents/memory/user-profile.md' > "$B/.gitignore" || die gitignore
fill "$B/src/app/x.cs" 10
for i in $(seq -w 1 26); do fill "$B/.agents/reference/r$i.md" 100; done
for i in $(seq -w 1 12); do fill "$B/.agents/reference/big $i.md" 41000; done
fill "$B/.agents/reference/report.html" 50
for i in $(seq 1 17); do fill "$B/.agents/specs/s$i.md" $((i * 10)); done
run_all "$B" "full"

want=$(cat "$M/a b.md" "$M/index.md" "$M/domain/a.md" "$M/user-profile.md" | wc -c | tr -d ' ')
[ "$(out "$B" "$P_MEM")" = \
  "MEMORY_TOTAL${TAB}4 files / $want bytes ≈ $((want / 4000))k tokens (on-disk upper bound)" ] \
  || bad full "MEMORY_TOTAL: $(out "$B" "$P_MEM"), want 4 files / $want bytes"
ref=$(out "$B" "$P_REF")
[ "$(grep -c "^LOAD${TAB}" <<<"$ref")" -eq 25 ] || bad full "LOAD rows ≠ 25"
[ "$(grep -c '^SKIP_' <<<"$ref")" -eq 10 ] || bad full "SKIP rows ≠ 10"
for l in "REFERENCE_LOADED${TAB}25 files / 2500 bytes ≈ 0k tokens" \
  "SKIPPED_CAP${TAB}12 files / 492000 bytes" "SKIPPED_MAXLOAD${TAB}1 files / 100 bytes" \
  "SKIPPED_BUDGET${TAB}0 files / 0 bytes" \
  "…3 more skipped (names only) — rg --files .agents/reference"; do
  grep -qxF "$l" <<<"$ref" || bad full "reference line missing: $l"
done
grep -qF "SKIP_CAP${TAB}41000${TAB}./.agents/reference/big 01.md" <<<"$ref" \
  || bad full "path with a space lost in a SKIP row"
specs=$(out "$B" "$P_SPECS")
[ "$(grep -c "^[0-9]*${TAB}" <<<"$specs")" -eq 15 ] || bad full "specs rows ≠ 15"
[ "$(head -1 <<<"$specs")" = "170${TAB}./.agents/specs/s17.md" ] || bad full "specs not descending"
grep -qxF "SPECS_TOTAL${TAB}17 files / 1530 bytes (listing only — never auto-read)" <<<"$specs" \
  || bad full "SPECS_TOTAL"
grep -qxF "…2 more — rg --files .agents/specs" <<<"$specs" || bad full "specs more line"
[ "$(out "$B" "$P_NL")" = "NOT_LOADED${TAB}./.agents/reference/report.html" ] \
  || bad full "NOT_LOADED: $(out "$B" "$P_NL")"
grep -q '\./\.agents/memory/a b\.md$' <(out "$B" "$P_STAT") || bad full "stat lost 'a b.md'"
grep -q 'user-profile\.md$' <(out "$B" "$P_STAT") || bad full "stat lost user-profile.md"
grep -q 'archive' <(out "$B" "$P_STAT") && bad full "stat lists archive"
grep -qx '\./\.agents/memory/domain/a\.md' <(out "$B" "$P_DOMAIN") || bad full "domain listing"
grep -qx 'src/app' <(out "$B" "$P_TREE") || bad full "tree fallback: $(out "$B" "$P_TREE")"
case "$(out "$B" "$P_SYNC")" in "## "*) ;; *) bad full "branch sync header" ;; esac

# (b2) reference budget: the 5th 30000-byte file crosses 122880
C="$T/budget repo"; repo "$C"
for i in 1 2 3 4 5; do fill "$C/.agents/reference/b$i.md" 30000; done
run_all "$C" "budget"
ref=$(out "$C" "$P_REF")
for l in "REFERENCE_LOADED${TAB}4 files / 120000 bytes ≈ 30k tokens" \
  "SKIPPED_BUDGET${TAB}1 files / 30000 bytes" "SKIP_BUDGET${TAB}30000${TAB}./.agents/reference/b5.md"
do grep -qxF "$l" <<<"$ref" || bad budget "reference line missing: $l"; done

# (c) only .agents/memory — the optional reference/, specs/, plans/ are absent
D="$T/memory only"; repo "$D"; fill "$D/.agents/memory/index.md" 10
run_all "$D" "memory-only"
grep -qF "MEMORY_TOTAL${TAB}1 files / 10 bytes" <(out "$D" "$P_MEM") || bad memory-only "MEMORY_TOTAL"

# (d) a symlinked document counts its target's bytes; a directory named *.md is no document
E="$T/link repo"; repo "$E"
fill "$E/docs/big.md" 41000; fill "$E/docs/small.md" 500
mkdir -p "$E/.agents/reference/dir.md" "$E/.agents/specs" || die "link dirs"
ln -s ../../docs/big.md "$E/.agents/reference/doc.md" || die "symlink"
ln -s ../../docs/small.md "$E/.agents/specs/s.md" || die "symlink"
run_all "$E" "links"
ref=$(out "$E" "$P_REF")
grep -qxF "SKIP_CAP${TAB}41000${TAB}./.agents/reference/doc.md" <<<"$ref" \
  || bad links "symlink not measured by its target: $ref"
grep -q 'dir\.md' <<<"$ref" && bad links "directory listed as a document"
grep -qxF "500${TAB}./.agents/specs/s.md" <(out "$E" "$P_SPECS") || bad links "specs symlink"
CHECKS=$((CHECKS + 3))

# (e) GNU find escapes whitespace, backslash and quotes in -ls names: the parser undoes them
jqpart() { printf '%s' "${1#*| jq }"; }
line='  1  0 -rw-r--r--   1 u  g   1234 Nov 14 18:12 ./.agents/specs/a\ b\\c\"d.md'
got=$(printf '%s\n' "$line" | eval "jq $(jqpart "$P_SPECS")" | head -1)
[ "$got" = "1234${TAB}./.agents/specs/a b\\c\"d.md" ] || bad gnu "escaped name: $got"
CHECKS=$((CHECKS + 1))

[ "$fail" -eq 0 ] || exit 1
echo "prime-probes-test: OK ($CHECKS checks)"
