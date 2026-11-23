#!/usr/bin/env bash
# Offline test of every `!`-probe in .claude/commands/prime.md: each one exits 0 on
# empty and partial input, keeps its semantics, and uses no form the team-clone skill-load
# permission check rejects (`-exec`, awk, sed, sort, xargs, `$(`). Also covers the browser
# lines of .claude/lib/qa-probe.sh (driver, project-local Playwright, launch summary) and
# its deployed-sha and readiness lines (offline, through a curl stub on PATH), and the upkeep
# probe (silent without a profile).
set -u
PRIME="$(cd "$(dirname "$0")/../.." && pwd)/commands/prime.md"
EXPECTED_PROBES=13
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

UPK="$(cd "$(dirname "$0")/.." && pwd)/upkeep.sh"
[ -f "$UPK" ] || { echo "prime-probes-test: FAIL — upkeep.sh missing"; exit 1; }
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
  && P_UPK=$(probe 'upkeep.sh due') \
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
repo() {  # <dir> — a one-commit repo, no remote, seeded with upkeep.sh so all probes run
  mkdir -p "$1" && git -C "$1" init -q \
    && git -C "$1" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init \
    && mkdir -p "$1/.claude/lib" && cp "$UPK" "$1/.claude/lib/upkeep.sh" \
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

# (e2) upkeep probe: silent without a profile, silent with nothing due
U1="$T/upkeep no profile"; repo "$U1"
[ -z "$(out "$U1" "$P_UPK")" ] || bad upkeep "output without a profile"
U2="$T/upkeep profile"; repo "$U2"
printf '{"schema":1}\n' > "$U2/.claude/project-profile.json" || die "upkeep profile"
run_all "$U2" "upkeep probe: exit 0, empty output"
[ -z "$(out "$U2" "$P_UPK")" ] || bad upkeep "output with nothing due"
CHECKS=$((CHECKS + 2))

# (f) qa-probe.sh browser lines: driver, project-local Playwright resolution, launch summary
QAP="$(cd "$(dirname "$0")/.." && pwd)/qa-probe.sh"
[ -f "$QAP" ] || die "qa-probe.sh missing"
qaenv() {  # <dir> <json members> — minimal config; no base_url/local_url keeps the probe offline
  mkdir -p "$1/.claude" && printf '{"artifacts_dir":""%s}\n' "${2:+, $2}" > "$1/.claude/qa-env.json" \
    || die "qaenv $1"
}
stub() {  # <dir> <pkg> <version> [noentry] — a package the probe can only resolve, never run
  mkdir -p "$1/node_modules/$2" \
    && printf '{"name":"%s","version":"%s","main":"index.js"}\n' "$2" "$3" > "$1/node_modules/$2/package.json" \
    || die "stub $2"
  [ "${4:-}" = noentry ] || : > "$1/node_modules/$2/index.js" || die "stub entry $2"
}
QOUT=""
qrun() {  # <dir> <label> [VAR=value …] — run the probe, assert exit 0, keep its output
  local d="$1" l="$2" rc; shift 2
  QOUT=$(cd "$d" && env "$@" CLAUDE_PROJECT_DIR="$d" bash "$QAP" 2>/dev/null </dev/null); rc=$?
  CHECKS=$((CHECKS + 1)); [ "$rc" -eq 0 ] || bad "$l" "qa-probe exit $rc"
}
qhas() {  # <label> <exact line>
  CHECKS=$((CHECKS + 1))
  grep -qxF "$2" <<<"$QOUT" \
    || bad "$1" "missing '$2' — got: $(grep -E '^(browser-driver|playwright|browser-launch|deployed-sha|readiness[^:]*|RESOLVED-BASE_URL): ' <<<"$QOUT" | tr '\n' '|')"
}
PW_NONE="playwright: not resolvable from the project"

# 1. defaults: no driver key, no Playwright, no launch block
Q="$T/qa defaults"; repo "$Q"; qaenv "$Q" ""
qrun "$Q" qa-defaults
qhas qa-defaults "browser-driver: script (default)"
qhas qa-defaults "$PW_NONE"
qhas qa-defaults "browser-launch: defaults"

# 2. explicit and unknown drivers
for d in mcp subagent; do
  Q="$T/qa driver $d"; repo "$Q"; qaenv "$Q" "\"browser_driver\":\"$d\""
  qrun "$Q" "qa-driver-$d"; qhas "qa-driver-$d" "browser-driver: $d"
done
Q="$T/qa driver unknown"; repo "$Q"; qaenv "$Q" '"browser_driver":"chrome"'
qrun "$Q" qa-driver-unknown
qhas qa-driver-unknown 'browser-driver: UNKNOWN "chrome" — treated as script'

# 3./4. a usable and a too-old playwright
Q="$T/qa pw 150"; repo "$Q"; qaenv "$Q" ""; stub "$Q" playwright 1.50.0
qrun "$Q" qa-pw-ok; qhas qa-pw-ok "playwright: resolves from the project (playwright 1.50.0)"
Q="$T/qa pw 148"; repo "$Q"; qaenv "$Q" ""; stub "$Q" playwright 1.48.2
qrun "$Q" qa-pw-old
qhas qa-pw-old "playwright: resolves from the project (playwright 1.48.2) — below 1.49, the script driver needs locator.ariaSnapshot"

# 5. @playwright/test alone, first usable wins, a missing entry file is not resolvable
Q="$T/qa pwt"; repo "$Q"; qaenv "$Q" ""; stub "$Q" @playwright/test 1.52.0
qrun "$Q" qa-pwt; qhas qa-pwt "playwright: resolves from the project (@playwright/test 1.52.0)"
Q="$T/qa pw mixed"; repo "$Q"; qaenv "$Q" ""; stub "$Q" playwright 1.40.0; stub "$Q" @playwright/test 1.52.0
qrun "$Q" qa-pw-mixed; qhas qa-pw-mixed "playwright: resolves from the project (@playwright/test 1.52.0)"
Q="$T/qa pw noentry"; repo "$Q"; qaenv "$Q" ""; stub "$Q" playwright 1.50.0 noentry
qrun "$Q" qa-pw-noentry; qhas qa-pw-noentry "$PW_NONE"

# 5b. a Playwright outside the checkout never counts: NODE_PATH, a parent directory
Q="$T/qa nodepath"; repo "$Q"; qaenv "$Q" ""; stub "$T/global pw" playwright 1.50.0
qrun "$Q" qa-nodepath NODE_PATH="$T/global pw/node_modules"; qhas qa-nodepath "$PW_NONE"
Q="$T/parent/child"; repo "$Q"; qaenv "$Q" ""; stub "$T/parent" playwright 1.50.0
qrun "$Q" qa-parent; qhas qa-parent "$PW_NONE"

# 6. launch settings: set keys only, the user-agent string is never printed
Q="$T/qa launch"; repo "$Q"
qaenv "$Q" '"browser_launch":{"channel":"chrome","user_agent":"X/1","ignore_https_errors":true}'
qrun "$Q" qa-launch
qhas qa-launch "browser-launch: channel=chrome · user-agent=custom · ignore-https-errors=yes"
CHECKS=$((CHECKS + 1)); grep -qF 'X/1' <<<"$QOUT" && bad qa-launch "user_agent string printed"

# 7. node not on PATH → the Playwright line says so, the probe still exits 0
mkdir -p "$T/nonode" || die "nonode"
for t in jq git curl pgrep wc tr date grep awk head cat dirname sed sort cut tail; do
  p=$(command -v "$t" 2>/dev/null) || continue
  case "$p" in /*) ln -s "$p" "$T/nonode/$t" || die "link $t" ;; esac
done
Q="$T/qa nonode"; repo "$Q"; qaenv "$Q" ""
QOUT=$(cd "$Q" && PATH="$T/nonode" CLAUDE_PROJECT_DIR="$Q" /bin/bash "$QAP" 2>/dev/null </dev/null); rc=$?
CHECKS=$((CHECKS + 1)); [ "$rc" -eq 0 ] || bad qa-nonode "qa-probe exit $rc"
qhas qa-nonode "playwright: NOT CHECKED — node not on PATH"

# (g) qa-probe.sh deployed SHA and readiness checks (offline: a curl stub on PATH)
# The stub answers from a TAB-separated map (the temp root contains a space) and logs the
# URL of EVERY invocation, whatever its scheme, so "never requested" is a real negative.
mkdir -p "$T/curlstub" || die "curlstub"
cat > "$T/curlstub/curl" <<'STUB'
#!/bin/bash
url="" fmt="" null=0
while [ $# -gt 0 ]; do
  case "$1" in
    -w) fmt="$2"; shift ;;
    -o) [ "$2" = /dev/null ] && null=1; shift ;;
    --connect-timeout|--max-time|--proto) shift ;;
    -*) : ;;
    *) url="$1" ;;
  esac; shift
done
printf '%s\n' "$url" >> "${CURL_STUB_LOG:-/dev/null}"
line=$(grep -F -- "$url	" "${CURL_STUB_MAP:-/dev/null}" 2>/dev/null | head -1)
code=000 body=- rc=7
if [ -n "$line" ]; then
  code=$(printf '%s' "$line" | cut -f2); body=$(printf '%s' "$line" | cut -f3)
  rc=$(printf '%s' "$line" | cut -f4); [ -n "$rc" ] || rc=0
fi
[ "$null" -eq 0 ] && [ "$body" != - ] && cat "$body"
if [ -n "$fmt" ]; then
  fmt=${fmt//%\{http_code\}/$code}; fmt=${fmt//%\{time_total\}/0.01}; fmt=${fmt//\\n/$'\n'}
  printf '%s' "$fmt"
fi
exit "$rc"
STUB
chmod +x "$T/curlstub/curl" || die "curlstub chmod"
rec() {  # <url> <code> <body-file|-> [curl exit] → one map record
  printf '%s\t%s\t%s\t%s' "$1" "$2" "$3" "${4:-0}"
}
body() {  # <dir> <name> <content> → writes the body file, prints its path
  printf '%s' "$3" > "$1/$2" || die "body $2"; printf '%s' "$1/$2"
}
qnet() {  # <dir> <label> <map record…> — run the probe against the stub, assert exit 0
  local d="$1" l="$2" r; shift 2
  : > "$d/map" || die "map $d"
  for r in "$@"; do printf '%s\n' "$r" >> "$d/map"; done
  : > "$d/log" || die "log $d"
  qrun "$d" "$l" PATH="$T/curlstub:$PATH" CURL_STUB_MAP="$d/map" CURL_STUB_LOG="$d/log"
}
one_sha() {  # <label> — exactly one deployed-sha line
  CHECKS=$((CHECKS + 1))
  [ "$(grep -c '^deployed-sha: ' <<<"$QOUT")" = 1 ] || bad "$1" "not exactly one deployed-sha line"
}
NET='"base_url":"http://dep.test","probe_paths":["/"],"build_sha_url":"http://dep.test/sha","local_url":"http://loc.test"'
ROOT_OK=$(rec http://dep.test/ 200 -)
LOC_OK=$(rec http://loc.test 200 -)
NOSHA="deployed-sha: not verified — build_sha_url returned no recognisable SHA"
shacase() {  # <label> <expected line> <body content> [code] [curl exit] — sha URL answers <body>
  local Q="$T/qa sha $1" b
  repo "$Q"; qaenv "$Q" "$NET"
  b=$(body "$Q" sha.body "$3")
  qnet "$Q" "$1" "$ROOT_OK" "$LOC_OK" "$(rec http://dep.test/sha "${4:-200}" "$b" "${5:-0}")"
  qhas "$1" "$2"; one_sha "$1"
}

# 1. a differing SHA is reported, the deployed host is kept; 13. no build-skew line remains
shacase sha-differs "deployed-sha: deadbee1234 (differs)" "deadbee1234"
qhas sha-differs "RESOLVED-BASE_URL: http://dep.test"
CHECKS=$((CHECKS + 1)); grep -q '^build-skew:' <<<"$QOUT" && bad sha-differs "build-skew line still printed"

# 2. equal to local HEAD
Q="$T/qa sha equal"; repo "$Q"; qaenv "$Q" "$NET"
h=$(git -C "$Q" rev-parse HEAD) || die "rev-parse $Q"
b=$(body "$Q" sha.body "$h")
qnet "$Q" sha-equal "$ROOT_OK" "$LOC_OK" "$(rec http://dep.test/sha 200 "$b")"
qhas sha-equal "deployed-sha: $h (equal)"; one_sha sha-equal

# 3. unreadable body → not verified, the deployed host still kept
shacase sha-unreadable "$NOSHA" "hello world"
qhas sha-unreadable "RESOLVED-BASE_URL: http://dep.test"

# 4. non-2xx: a hex token in an error body is never a SHA
shacase sha-500 "deployed-sha: not verified — build_sha_url returned 500" "request id deadbeef12" 500

# 5. the meta tag wins over an asset hash before it
shacase sha-meta "deployed-sha: abc1234def (differs)" \
  '<html><script src="/app.3f2a9b1c.js"></script><meta name="build-sha" content="abc1234def"></html>'

# 6. unidentified or ambiguous → never a SHA
shacase sha-asset "$NOSHA" '<html><script src="/app.3f2a9b1c4d.js"></script></html>'
shacase sha-two-one-line "$NOSHA" "abc1234def 9c1f84d"
shacase sha-json-two-fields "$NOSHA" '{"sha":"abc1234def5678","revision":"deadbeefcafe12"}'
shacase sha-json-request-id "deployed-sha: abc1234def5678 (differs)" \
  '{"commit":"abc1234def5678","request_id":"deadbeefcafe12"}'
shacase sha-incomplete "deployed-sha: not verified — build_sha_url transfer incomplete (curl exit 18)" \
  "abc1234def5678" 200 18
shacase sha-meta-conflict "deployed-sha: not verified — conflicting build-sha meta tags" \
  '<meta name="build-sha" content="abc1234def"><meta name="build-sha" content="deadbeefcafe">'
shacase sha-json-two-docs "$NOSHA" '{"sha":"abc1234def5678"}{"sha":"deadbeefcafe12"}'
shacase sha-json-broken-tail "$NOSHA" '{"sha":"abc1234def5678"} {"sha":'
shacase sha-meta-data-attrs "$NOSHA" \
  '<meta data-name="build-sha" content="abcdef1"><meta name="build-sha" data-content="abcdef1">'

# 7. a probe path down: the local host is resolved, the SHA is still reported
Q="$T/qa sha root down"; repo "$Q"; qaenv "$Q" "$NET"
b=$(body "$Q" sha.body "deadbee1234")
qnet "$Q" sha-root-down "$LOC_OK" "$(rec http://dep.test/sha 200 "$b")"
qhas sha-root-down "deployed-sha: deadbee1234 (differs)"
qhas sha-root-down "RESOLVED-BASE_URL: http://loc.test"; one_sha sha-root-down

# 8. no deployed host → not applicable
Q="$T/qa sha none"; repo "$Q"; qaenv "$Q" ""
qrun "$Q" sha-none
qhas sha-none "deployed-sha: not applicable — no deployed host configured"; one_sha sha-none

# 9. readiness: ok, FAILED, UNREACHABLE, and refused entries that are never requested
Q="$T/qa ready mixed"; repo "$Q"
qaenv "$Q" "$NET"', "readiness_checks":[
  {"name":"ok","url":"https://ok.test/","expect_status":200},
  {"name":"bad","url":"https://bad.test/","expect_status":200},
  {"name":"gone","url":"https://gone.test/"},
  {"name":"cred","url":"https://u:p@cms.test/"},
  {"name":"a b","url":"https://ab.test/"},
  {"name":"file","url":"file:///etc/passwd"},
  {"name":"n","url":"https://x.test/","expect_status":null}]'
b=$(body "$Q" sha.body "deadbee1234")
qnet "$Q" ready-mixed "$ROOT_OK" "$LOC_OK" "$(rec http://dep.test/sha 200 "$b")" \
  "$(rec https://ok.test/ 200 -)" "$(rec https://bad.test/ 503 -)"
qhas ready-mixed "readiness ok: ok — 200"
qhas ready-mixed "readiness bad: FAILED — got 503, expected 200"
qhas ready-mixed "readiness gone: UNREACHABLE — timeout or connection refused"
qhas ready-mixed "readiness #4: MALFORMED — url must be http(s) without userinfo"
qhas ready-mixed "readiness #5: MALFORMED — name must match [A-Za-z0-9._-]{1,40}"
qhas ready-mixed "readiness #6: MALFORMED — url must be http(s) without userinfo"
qhas ready-mixed "readiness #7: MALFORMED — expect_status must be an integer 100-599"
CHECKS=$((CHECKS + 1))
[ "$(grep -c 'cms.test\|ab.test\|/etc/passwd\|x.test' "$Q/log")" = 0 ] \
  || bad ready-mixed "a refused entry was requested: $(tr '\n' '|' < "$Q/log")"
CHECKS=$((CHECKS + 1))
got=$(grep -v 'dep.test\|loc.test' "$Q/log" | tr '\n' '|')
[ "$got" = "https://ok.test/|https://bad.test/|https://gone.test/|" ] \
  || bad ready-mixed "readiness requests: $got"

# 10. no expect_status → any 2xx/3xx is ok
Q="$T/qa ready redirect"; repo "$Q"
qaenv "$Q" "$NET"', "readiness_checks":[{"name":"r","url":"https://r.test/"}]'
qnet "$Q" ready-redirect "$ROOT_OK" "$LOC_OK" "$(rec https://r.test/ 302 -)"
qhas ready-redirect "readiness r: ok — 302"

# 11. at most 10 entries run, the rest is announced
Q="$T/qa ready cap"; repo "$Q"
entries="" recs=()
for n in 1 2 3 4 5 6 7 8 9 10 11 12; do
  entries="$entries${entries:+,}{\"name\":\"r$n\",\"url\":\"https://r$n.test/\"}"
  recs+=("$(rec "https://r$n.test/" 200 -)")
done
qaenv "$Q" "$NET, \"readiness_checks\":[$entries]"
qnet "$Q" ready-cap "$ROOT_OK" "$LOC_OK" "${recs[@]}"
qhas ready-cap "readiness-checks: 2 more not run (limit 10)"
CHECKS=$((CHECKS + 1))
[ "$(grep -c '^https://r[0-9]*\.test/$' "$Q/log")" = 10 ] || bad ready-cap "not exactly 10 readiness requests"

# 12. none configured / not an array
Q="$T/qa ready none"; repo "$Q"; qaenv "$Q" ""
qrun "$Q" ready-none; qhas ready-none "readiness-checks: none configured"
Q="$T/qa ready false"; repo "$Q"; qaenv "$Q" '"readiness_checks":false'
qrun "$Q" ready-false; qhas ready-false "readiness-checks: MALFORMED — not an array"

# 12b. a URL with brackets is one literal transfer (--globoff)
Q="$T/qa ready glob"; repo "$Q"
qaenv "$Q" "$NET"', "readiness_checks":[{"name":"g","url":"https://g.test/[1-3]"}]'
qnet "$Q" ready-glob "$ROOT_OK" "$LOC_OK" "$(rec 'https://g.test/[1-3]' 200 -)"
qhas ready-glob "readiness g: ok — 200"
CHECKS=$((CHECKS + 1))
[ "$(grep -v 'dep.test\|loc.test' "$Q/log")" = 'https://g.test/[1-3]' ] || bad ready-glob "not one literal transfer"

[ "$fail" -eq 0 ] || exit 1
echo "prime-probes-test: OK ($CHECKS checks)"
