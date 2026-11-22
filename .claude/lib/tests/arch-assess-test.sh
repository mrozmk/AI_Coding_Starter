#!/usr/bin/env bash
# Offline test for .claude/lib/arch-assess.mjs (measure / check / score) and the text contract of
# /architecture-review's assessment assets: the auditor and refutation prompt templates, the
# architecture-sweeper agent and the command's wiring. Fixtures are throwaway git repos with dummy text.
set -euo pipefail

ST=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
AA="$ST/.claude/lib/arch-assess.mjs"
SK="$ST/.claude/skills/architecture-review"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
fail() { echo "arch-assess-test: FAIL — $*"; exit 1; }
N=0
ok() { N=$((N + 1)); echo "PASS $1"; }
run() { set +e; OUT=$(node "$AA" "$@" 2>&1); RC=$?; set -e; }
put() { mkdir -p "$(dirname "$1")"; printf '%s\n' "$2" > "$1"; }
lines() { mkdir -p "$(dirname "$1")"; awk -v n="$2" -v t="$3" 'BEGIN { for (i = 0; i < n; i++) print t }' > "$1"; }
repo() { mkdir -p "$WORK/$1"; git -c init.defaultBranch=main -C "$WORK/$1" init -q; }
commit() { git -C "$1" add -A; git -C "$1" -c user.name=t -c user.email=t@example.invalid commit -qm "${2:-c}"; }
measure() { local d="$1"; shift; run measure --root "$WORK/$d" --out "$WORK/$d.json" "$@"; [ "$RC" = 0 ] || fail "measure $d: $RC $OUT"; }
q() { jq -e "$2" "$WORK/$1.json" >/dev/null; }

# ---- measure: scope, inventory, determinism -----------------------------------------------------
repo base; B="$WORK/base"
put "$B/.claude/lib/x.mjs" "import { y } from './y.mjs';"
put "$B/.claude/lib/y.mjs" "export const y = 1;"
put "$B/.claude/commands/only.md" "# a command"
put "$B/.claude/settings.json" '{"a": 1}'
put "$B/policies/a.yaml" "key: value"
put "$B/policies/route.jq" ".a"
put "$B/docs/readme.md" "prose"
put "$B/package-lock.json" "{}"
put "$B/src/app.py" "import os"
put "$B/src/main.go" "package main"
put "$B/.agents/handoffs/probe.py" "x = 1"
put "$B/vendor/lib.py" "x = 1"
commit "$B"

measure base
cp "$WORK/base.json" "$WORK/base-1.json"
measure base
cmp -s "$WORK/base.json" "$WORK/base-1.json" || fail "M1 two runs differ"
ok "M1 measure is byte-identical on an unchanged tree"

q base '.files[] | select(.path == ".claude/lib/x.mjs") | .area == ".claude"' || fail "M2 dot-dir file not in an area"
q base '[.files[] | select(.path == ".claude/commands/only.md" or .path == ".claude/settings.json") | .lang == "def" and .area == ".claude"] | length == 2 and all' || fail "M2 def files"
q base '[.files[].path] | (index("docs/readme.md") == null) and (index("package-lock.json") == null)' || fail "M2 prose or lockfile in files[]"
ok "M2 dot-dirs in scope; definitions are def files; prose and lockfiles outside .claude dropped"
run measure --root "$B" --focus .claude/commands --out "$WORK/f1.json"
[ "$RC" = 0 ] && jq -e '(.areas | length) >= 1 and .root_scope == ".claude/commands"' "$WORK/f1.json" >/dev/null || fail "M2 focus .claude/commands: $OUT"
run measure --root "$B" --focus policies --out "$WORK/f2.json"
[ "$RC" = 0 ] && jq -e '(.areas | length) >= 1 and ([.files[].lang] | all(. == "def"))' "$WORK/f2.json" >/dev/null || fail "M2 focus policies: $OUT"
ok "M2 a Markdown-only and a policies-only focus get areas"

q base '[.files[].path] | index(".agents/handoffs/probe.py") == null and index("vendor/lib.py") != null' || fail "M3 handoffs not excluded"
measure base --exclude 'vendor/**'
q base '[.files[].path] | index("vendor/lib.py") == null' || fail "M3 --exclude ignored"
ok "M3 built-in and --exclude exclusions"

q base '.coverage_limits.sizes_only == ["go"] and (.files[] | select(.path == "src/main.go") | .test_imported == null and .fan_in == null)' || fail "M9 sizes-only language"
ok "M9 sizes-only language: listed, no import signals"

# ---- measure: Python graph ---------------------------------------------------------------------
repo py; P="$WORK/py"
put "$P/pa/__init__.py" ""
put "$P/pa/one.py" "import pb.two
from pc import three"
put "$P/pb/__init__.py" ""
put "$P/pb/two.py" "from ..pa import one"
put "$P/pc/three.py" "from . import helper
import pa.one"
put "$P/pc/helper.py" "x = 1"
commit "$P"
measure py
q py '.graph.mutual == [["pa","pb"],["pa","pc"]] and .graph.cycles == [["pa","pb","pc"]]' || fail "M4 python graph: $(jq -c .graph "$WORK/py.json")"
q py '(.files[] | select(.path == "pc/helper.py") | .fan_in == 1) and (.files[] | select(.path == "pa/one.py") | .fan_in == 2)' || fail "M4 python fan-in"
ok "M4 Python absolute and relative imports give area edges, mutual pairs and a cycle"

# ---- measure: JS/TS graph ----------------------------------------------------------------------
repo js; J="$WORK/js"
put "$J/web/a/main.ts" "import { x } from '../b/x.js';
import d from '../c/dir';
const y = require('../b/y');
import _ from 'lodash';"
put "$J/web/b/x.ts" "export const x = 1;"
put "$J/web/b/y.js" "module.exports = 1;"
put "$J/web/c/dir/index.ts" "export default 1;"
commit "$J"
measure js
q js '[.files[] | select(.path | test("web/b/x.ts|web/b/y.js|web/c/dir/index.ts")) | .fan_in] == [1,1,1]' || fail "M5 js resolution: $(jq -c '[.files[]|{path,fan_in}]' "$WORK/js.json")"
q js '.coverage_limits.unresolved_specifiers.js == 1 and (.graph.edges | map(select(.from == "web/a" and .to == "web/b")) | .[0].count == 2)' || fail "M5 js unresolved / edges"
ok "M5 JS/TS: .js → .ts, dir → index.ts, require, bare package unresolved"

# ---- measure: sibling tests, test imports ------------------------------------------------------
repo cli; L="$WORK/cli"
put "$L/cli.py" "import sys"
put "$L/tests/test_cli.py" "import subprocess
subprocess.run(['python', 'cli.py'])"
put "$L/run.sh" "echo run"
put "$L/run-test.sh" "bash run.sh"
commit "$L"
measure cli
q cli '.files[] | select(.path == "cli.py") | .sibling_test == true and .test_imported == false' || fail "M6 cli.py"
q cli '.files[] | select(.path == "run.sh") | .sibling_test == true and .test_imported == null' || fail "M6 run.sh"
ok "M6 sibling tests for a subprocess-tested CLI and a shell script"
q cli '.map == {skipped: "absent"}' || fail "M8 absent map"
ok "M8 no map → skipped absent"

# ---- measure: system map ------------------------------------------------------------------------
repo map; MP="$WORK/map"
put "$MP/docs/map/system.yaml" "schema: 1
nodes:
  - id: core
    name: Core
    kind: trunk
  - id: biz
    name: Biz
    kind: branch
    parent: core
    subdomain: core
  - id: a
    name: A
    kind: leaf
    parent: biz
    code: [a/**]
  - id: b
    name: B
    kind: leaf
    parent: biz
    code: [b/**]
  - id: h
    name: H
    kind: leaf
    parent: biz
    code: [h/**]
  - id: c
    name: C
    kind: leaf
    parent: biz
    code: [c/**]
  - id: u
    name: U
    kind: leaf
    parent: biz
    code: [u/**]
  - id: e
    name: E
    kind: leaf
    parent: biz
links:
  - from: a
    to: b
    kind: calls
  - from: h
    to: c
    kind: ohs
  - from: a
    to: c
    kind: events
  - from: h
    to: e
    kind: calls"
put "$MP/a/mod.py" "x = 1"
put "$MP/b/bmod.py" "import a.mod"
put "$MP/h/hmod.py" "x = 1"
put "$MP/c/cmod.py" "import h.hmod"
put "$MP/u/umod.py" "import a.mod"
commit "$MP"
measure map
q map '.map.against == [{importer: "b", imported: "a", link_kind: "calls"}]' || fail "M7 against: $(jq -c .map "$WORK/map.json")"
q map '[.. | objects | has("breach")] | any | not' || fail "M7 measure emits a breach key"
q map '.map.undeclared == [{importer: "u", imported: "a", count: 1}]' || fail "M7 undeclared"
q map '[.map.incomparable[] | "\(.from)-\(.to)-\(.kind)"] == ["a-c-events", "h-e-calls"]' || fail "M7 incomparable"
ok "M7 map: against without breach, ohs direction, incomparable, undeclared"
printf 'schema: 1\nnodes:\n  - id: a\n bad: x\n' > "$MP/docs/map/system.yaml"
measure map
q map '.map.skipped | startswith("unparseable")' || fail "M8 malformed map: $(jq -c .map "$WORK/map.json")"
printf 'schema: 1\nnodes:\n  - id: core\n    name: C\n    kind: trunk\n  - id: core\n    name: D\n    kind: root\n' > "$MP/docs/map/system.yaml"
measure map
q map '.map.skipped | startswith("invalid")' || fail "M8 duplicate id map: $(jq -c .map "$WORK/map.json")"
ok "M8 malformed and invalid maps are skipped with a reason"
repo mapln; ML="$WORK/mapln"
put "$ML/a/mod.py" "x = 1"
put "$WORK/outside/map/system.yaml" "secret: line"
mkdir -p "$ML/docs/map"
ln -s "$WORK/outside/map/system.yaml" "$ML/docs/map/system.yaml"
measure mapln
q mapln '.map == {skipped: "outside the root"}' || fail "M8 symlinked map file: $(jq -c .map "$WORK/mapln.json")"
repo mapdir; MD="$WORK/mapdir"
put "$MD/a/mod.py" "x = 1"
ln -s "$WORK/outside" "$MD/docs"
measure mapdir
q mapdir '.map == {skipped: "outside the root"}' || fail "M8 symlinked map dir: $(jq -c .map "$WORK/mapdir.json")"
ok "M8 a map reached through a symlink out of the root is never read"

# ---- measure: areas ----------------------------------------------------------------------------
repo areas; AR="$WORK/areas"
put "$AR/api/src/pkg/__init__.py" ""
lines "$AR/api/src/pkg/a/m1.py" 30 "x = 1"
lines "$AR/api/src/pkg/b/m2.py" 30 "x = 1"
lines "$AR/web/src/x/f.ts" 20 "let x = 1;"
lines "$AR/web/src/y/g.ts" 20 "let x = 1;"
commit "$AR"
measure areas
q areas '[.areas[].name] == ["api/src/pkg/a", "api/src/pkg/b", "web/src", "(rest)"]' || fail "M10 auto areas: $(jq -c '[.areas[].name]' "$WORK/areas.json")"
q areas '(.files[] | select(.path == "api/src/pkg/__init__.py") | .area == "(rest)") and ([.areas[] | select(.derived == "auto")] | length == 4)' || fail "M10 rest holds the marker"
ok "M10 auto areas split single-child and > 50 % dirs, stop at 40 %"
measure areas --area 'core=api/**' --area 'ui=web/**'
q areas '[.areas[].name] == ["core", "ui"] and (.areas[0].derived == "explicit")' || fail "M10 explicit areas"
ok "M10 explicit --area flags replace the auto rule"

# ---- measure: change cost ----------------------------------------------------------------------
repo hist; H="$WORK/hist"
put "$H/old/o.py" "x = 0"; put "$H/mid/m.py" "x = 0"; commit "$H" c1
for i in 2 3; do put "$H/mid/m.py" "x = $i"; commit "$H" "c$i"; done
for i in 4 5 6 7 8; do put "$H/new/n.py" "x = $i"; commit "$H" "c$i"; done
measure hist
q hist '.change_cost.mid == {commits: 3, median_files: 1, max_files: 2}' || fail "M11 mid: $(jq -c .change_cost "$WORK/hist.json")"
measure hist --commits 2
q hist '.change_cost.old.commits == 1 and .change_cost.new.commits == 2' || fail "M11 window: $(jq -c .change_cost "$WORK/hist.json")"
ok "M11 change cost per area, no global commit window"
repo unborn; put "$WORK/unborn/a.py" "x = 1"
measure unborn
q unborn '.change_cost == {skipped: "no history"} and .revision == null' || fail "M11 unborn repo"
ok "M11 an unborn repo has no change cost"

mkdir -p "$WORK/plain"
run measure --root "$WORK/plain" --out "$WORK/plain.json"
[ "$RC" = 2 ] || fail "M12 not a repo: $RC $OUT"
run measure --root "$B" --bogus x --out "$WORK/x.json"
[ "$RC" = 2 ] || fail "M12 unknown flag: $RC"
ok "M12 not a git repo and an unknown flag exit 2"

# ---- measure: branches, mentions, safety flags --------------------------------------------------
repo br
put "$WORK/br/br.js" 'if (a) { x(); }
switch (b) {
  case 1: break;
}
const t = a ? b : c;
const o = a?.b;
const n = a ?? b;
const s = "if you";
// if in a comment'
commit "$WORK/br"
measure br
q br '.files[0].branches == 4' || fail "M13 branches: $(jq -c '.files[0]' "$WORK/br.json")"
ok "M13 branch count ignores strings, comments, ?. and ??"

repo ment; MN="$WORK/ment"
put "$MN/lib/lib.sh" "echo lib"
put "$MN/lib/one.sh" 'source "$DIR/lib.sh"'
put "$MN/lib/two.sh" ". ./lib.sh"
put "$MN/tool/tool.mjs" "export const x = 1;"
put "$MN/tool/run.sh" "node tool.mjs"
put "$MN/p/index.ts" "export const p = 1;"
put "$MN/q/index.ts" "export const q = 1;"
put "$MN/r/use.ts" "// see index.ts"
commit "$MN"
measure ment
q ment '.files[] | select(.path == "lib/lib.sh") | .fan_in == null and .mentions == 2' || fail "M14 lib.sh"
q ment '.files[] | select(.path == "tool/tool.mjs") | .fan_in == 0 and .mentions == 1' || fail "M14 tool.mjs"
q ment '.files[] | select(.path == "p/index.ts") | .mentions == 0' || fail "M14 shared basename"
ok "M14 mentions: sourced shell, a script run by name, shared basenames keyed by path"

repo safe; SF="$WORK/safe"
lines "$SF/s/big.py" 400 "x = 1"
{ lines "$WORK/t1" 39 "if x: pass"; lines "$WORK/t2" 360 "x = 1"; cat "$WORK/t1" "$WORK/t2"; } > "$SF/s/mid.py"
lines "$SF/s/br.py" 40 "if x: pass"
lines "$SF/s/tested.py" 900 "x = 1"
put "$SF/s/test_tested.py" "y = 2"
lines "$SF/s/setup.sh" 500 "echo x"
put "$SF/tests/setup-smoke.sh" "bash s/setup.sh"
commit "$SF"
measure safe
q safe '.safety_flags == ["s/big.py", "s/br.py"]' || fail "M15 safety flags: $(jq -c .safety_flags "$WORK/safe.json")"
q safe '.files[] | select(.path == "s/setup.sh") | .test_referenced == true' || fail "M15 test_referenced"
ok "M15 safety flags: 400 lines or 40 branches without test evidence"

# ---- check ------------------------------------------------------------------------------------
FIND='{"invariant":"i","entry_point":"e","trigger":"t","user_impact":"u","anchors":[{"path":"a.py","line":1}],"evidence_kind":"static","command":null,"observed":"o","uncertainty":"u","recommended_action":"r"}'
AUD="{\"revision\":\"abc\",\"scope\":\".\",\"findings\":[$FIND],\"coverage_limits\":[]}"
printf '%s\n' "$AUD" > "$WORK/a1.md"
run check auditor "$WORK/a1.md" --out "$WORK/a1.json"
[ "$RC" = 0 ] && [ "$OUT" = "valid auditor findings=1" ] && jq -e '.findings | length == 1' "$WORK/a1.json" >/dev/null || fail "C1: $RC $OUT"
ok "C1 auditor whole-message JSON"
printf 'Here is my report.\n\n```json\n%s\n```\n\nDone.\n' "$AUD" > "$WORK/a2.md"
run check auditor "$WORK/a2.md"
[ "$RC" = 0 ] || fail "C2: $RC $OUT"
ok "C2 auditor JSON in one fenced block between prose"
printf '%s\n' "${AUD/\"static\"/\"guess\"}" > "$WORK/a3.md"
run check auditor "$WORK/a3.md"
[ "$RC" = 1 ] && case "$OUT" in *evidence_kind*) true ;; *) false ;; esac || fail "C3: $RC $OUT"
ok "C3 a bad evidence_kind names the field"
printf 'nothing here\n' > "$WORK/a4.md"
run check auditor "$WORK/a4.md"
[ "$RC" = 1 ] || fail "C4 no JSON: $RC"
printf '```json\n%s\n```\n```json\n%s\n```\n' "$AUD" "$AUD" > "$WORK/a5.md"
run check auditor "$WORK/a5.md"
[ "$RC" = 1 ] && case "$OUT" in *"no single JSON object"*) true ;; *) false ;; esac || fail "C4 two fences: $RC $OUT"
ok "C4 no JSON and two fenced blocks are rejected"
printf '%s\n' "${AUD/\"anchors\":\[{\"path\":\"a.py\",\"line\":1}\]/\"anchors\":[]}" > "$WORK/a6.md"
run check auditor "$WORK/a6.md"
[ "$RC" = 1 ] || fail "C7 auditor empty anchors: $RC $OUT"
ok "C7 an auditor finding with empty anchors is rejected"

rec() {  # rec <id> <areas csv> <class json> <tier> [breach] [status]
  jq -nc --arg id "$1" --arg areas "$2" --argjson class "$3" --arg tier "$4" --argjson breach "${5:-false}" --arg status "${6:-finding}" \
    '{id: $id, title: "t", areas: ($areas | split(",")), class: $class, tier: $tier, breach: $breach, status: $status,
      sources: ["claude"], verified_by: "main-session", evidence_kind: "static", candidate: null, claim: "c", rule: "r",
      anchors: [{path: "a.py", line: 1}], consequence: "q", consequence_kind: "predicted", change: "x", effort: "S",
      confidence: "high", correction_note: null}'
}
records() { jq -sc '{records: .}'; }

rec R1 A 1 now > "$WORK/r1"; rec R2 A 2 next >> "$WORK/r1"
records < "$WORK/r1" > "$WORK/sub.json"
res() { jq -nc --arg id "$1" --arg v "$2" '{id: $id, verdict: $v, target: "claim", correction: "", evidence: "e", evidence_kind: "static", command: null}'; }
printf '{"results":[%s]}\n' "$(res R1 maybe)" > "$WORK/f1.md"
run check refutation "$WORK/f1.md" --submitted "$WORK/sub.json"
[ "$RC" = 1 ] || fail "C5 verdict maybe: $RC"
printf '{"results":[%s]}\n' "$(res R9 confirmed)" > "$WORK/f2.md"
run check refutation "$WORK/f2.md" --submitted "$WORK/sub.json"
[ "$RC" = 1 ] || fail "C5 unsubmitted id: $RC"
printf '{"results":[%s,%s]}\n' "$(res R1 confirmed)" "$(res R1 refuted)" > "$WORK/f3.md"
run check refutation "$WORK/f3.md" --submitted "$WORK/sub.json"
[ "$RC" = 1 ] || fail "C5 duplicate result id: $RC"
ok "C5 refutation: bad verdict, unsubmitted id and duplicate id rejected"
printf 'Results:\n```json\n{"results":[%s]}\n```\n' "$(res R1 confirmed)" > "$WORK/f4.md"
run check refutation "$WORK/f4.md" --submitted "$WORK/sub.json" --out "$WORK/f4.json"
[ "$RC" = 0 ] && [ "$OUT" = "valid refutation results=2 missing=1" ] \
  && jq -e '.results[] | select(.id == "R2") | .verdict == "not-checked" and .evidence == "no result returned"' "$WORK/f4.json" >/dev/null || fail "C5 missing: $RC $OUT"
ok "C5 a submitted id with no result becomes not-checked"
jq -c '.results[0] |= del(.target)' "$WORK/f4.json" > "$WORK/f5.md"
run check refutation "$WORK/f5.md" --submitted "$WORK/sub.json"
[ "$RC" = 1 ] || fail "C8 result without target: $RC"
ok "C8 a refutation result without target is rejected"
# Shaped like the prompts' own output example: one bare ``` fence, no language tag.
printf '```\n%s\n```\n' "$AUD" > "$WORK/a7.md"
run check auditor "$WORK/a7.md"
[ "$RC" = 0 ] && [ "$OUT" = "valid auditor findings=1" ] || fail "C9 auditor bare fence: $RC $OUT"
printf '```\n{"results":[%s,%s]}\n```\n' "$(res R1 confirmed)" "$(res R2 refuted)" > "$WORK/f6.md"
run check refutation "$WORK/f6.md" --submitted "$WORK/sub.json"
[ "$RC" = 0 ] && [ "$OUT" = "valid refutation results=2 missing=0" ] || fail "C9 refutation bare fence: $RC $OUT"
ok "C9 a reply in a bare fence, like the prompts' example, passes check auditor and check refutation"

M_FILE="$WORK/m.json"
jq -n '{areas: [{name: "A", source_lines: 60}, {name: "B", source_lines: 40}], files: [{path: "a/big.py", area: "A"}], safety_flags: []}' > "$M_FILE"
all_assessed() { jq -n '{areas: {A: {boundaries: {assessed: true}, runtime: {assessed: true}, change_cost: {assessed: true}, safety_net: {assessed: true}},
                                B: {boundaries: {assessed: true}, runtime: {assessed: true}, change_cost: {assessed: true}, safety_net: {assessed: true}}}}'; }
all_assessed > "$WORK/as.json"
sc() { run score --records "$1" --measure "${3:-$M_FILE}" --assessed "${2:-$WORK/as.json}" --out "$WORK/sc.json"; }

for bad in '"x"' 13; do
  rec R1 A "$bad" now | records > "$WORK/rb.json"
  run check records "$WORK/rb.json"; [ "$RC" = 1 ] || fail "C6 check records class $bad: $RC"
  sc "$WORK/rb.json"; [ "$RC" = 1 ] || fail "C6 score class $bad: $RC"
done
rec R1 A 12 now | records > "$WORK/rb.json"
run check records "$WORK/rb.json"
[ "$RC" = 0 ] && [ "$OUT" = "valid records records=1" ] || fail "C6 class 12: $RC $OUT"
ok "C6 record class: x and 13 rejected by check and score, 12 accepted"
rec R1 A 1 now | jq -c '.anchors = []' | records > "$WORK/rb.json"
run check records "$WORK/rb.json"; [ "$RC" = 1 ] || fail "C7 empty anchors: $RC"
rec R1 A 1 now | jq -c 'del(.claim)' | records > "$WORK/rb.json"
run check records "$WORK/rb.json"; [ "$RC" = 1 ] || fail "C7 no claim: $RC"
ok "C7 a record with empty anchors or no claim is rejected"
{ rec R1 A 1 now; rec R1 A 2 next; } | records > "$WORK/dup.json"
run check records "$WORK/dup.json"; [ "$RC" = 1 ] || fail "C8 check records duplicate: $RC"
run check refutation "$WORK/f4.md" --submitted "$WORK/dup.json"; [ "$RC" = 1 ] || fail "C8 submitted duplicate: $RC"
sc "$WORK/dup.json"; [ "$RC" = 1 ] || fail "C8 score duplicate: $RC"
ok "C8 duplicate record ids rejected in check records, check refutation and score"

# ---- score ------------------------------------------------------------------------------------
{ rec N1 A 1 next; rec N2 A 10 now; rec N3 A 9 now; rec N4 A 9 now; } | records > "$WORK/s1.json"
sc "$WORK/s1.json"
[ "$RC" = 0 ] && jq -e '.areas[0].axes == {boundaries: {value: 3}, runtime: {value: 2}, change_cost: {value: 1}, safety_net: {value: 0}}' "$WORK/sc.json" >/dev/null || fail "S1 anchors: $RC $OUT $(jq -c '.areas[0]' "$WORK/sc.json")"
rec N5 A 8 now true | records > "$WORK/s1b.json"
sc "$WORK/s1b.json"
jq -e '.areas[0].axes.boundaries.value == 0' "$WORK/sc.json" >/dev/null || fail "S1 breach"
ok "S1 rubric anchors 3 / 2 / 1 / 0 and a now breach on boundaries"

echo '{"records": []}' > "$WORK/empty.json"
jq '.areas.A.safety_net = {assessed: false, reason: "sweep failed"}' "$WORK/as.json" > "$WORK/as2.json"
sc "$WORK/empty.json" "$WORK/as2.json"
jq -e '.areas[0].score == 7.5 and .areas[0].assessed_axes == 3 and .areas[0].axes.safety_net == {value: null, reason: "sweep failed"}' "$WORK/sc.json" >/dev/null || fail "S2: $(jq -c '.areas[0]' "$WORK/sc.json")"
ok "S2 three axes at 3 and one not assessed → 7.5"
jq '.areas.A = {runtime: {assessed: true}}' "$WORK/as.json" > "$WORK/as3.json"
sc "$WORK/empty.json" "$WORK/as3.json"
jq -e '.areas[0].score == null and .areas[0].assessed_axes == 1' "$WORK/sc.json" >/dev/null || fail "S3"
ok "S3 one assessed axis → no score"
jq -e '.areas[0].axes.boundaries.reason == "missing from assessed file"' "$WORK/sc.json" >/dev/null || fail "S6 missing pair"
ok "S6 a pair absent from assessed.json → missing from assessed file"

jq '.safety_flags = ["a/big.py"]' "$M_FILE" > "$WORK/m-flag.json"
sc "$WORK/empty.json" "$WORK/as.json" "$WORK/m-flag.json"
jq -e '.areas[0].axes.safety_net.value == 2 and .areas[1].axes.safety_net.value == 3' "$WORK/sc.json" >/dev/null || fail "S4 cap"
sc "$WORK/empty.json"
jq -e '.areas[0].axes.safety_net.value == 3' "$WORK/sc.json" >/dev/null || fail "S4 uncapped"
ok "S4 an area holding a safety flag is capped at 2 on safety net"

{ rec P1 B 8 next; rec P2 B 1 next; rec P3 B 10 now; rec P4 B 9 now; } | records > "$WORK/s5.json"
sc "$WORK/s5.json"
jq -e '.overall == 8 and .areas[0].score == 10 and .areas[1].score == 5 and .inconclusive == false' "$WORK/sc.json" >/dev/null || fail "S5 full: $(jq -c . "$WORK/sc.json")"
jq '.areas.B = {boundaries: {assessed: false, reason: "r"}, runtime: {assessed: false, reason: "r"}, change_cost: {assessed: false, reason: "r"}, safety_net: {assessed: false, reason: "r"}}' "$WORK/as.json" > "$WORK/as-b.json"
sc "$WORK/s5.json" "$WORK/as-b.json"
jq -e '.overall == 6 and .scored_share == 0.6 and .areas[1].score == null' "$WORK/sc.json" >/dev/null || fail "S5 partial: $(jq -c . "$WORK/sc.json")"
ok "S5 overall 8 complete, 6 with the 40 % area unscored"

jq -n '{areas: [{name: "A", source_lines: 499}, {name: "B", source_lines: 501}], files: [], safety_flags: []}' > "$WORK/m7.json"
sc "$WORK/empty.json" "$WORK/as-b.json" "$WORK/m7.json"
jq -e '.inconclusive == true and (.inconclusive_reasons | length == 1) and (.inconclusive_reasons[0] | startswith("scored areas cover"))' "$WORK/sc.json" >/dev/null || fail "S7 499: $(jq -c . "$WORK/sc.json")"
jq -n '{areas: [{name: "A", source_lines: 500}, {name: "B", source_lines: 500}], files: [], safety_flags: []}' > "$WORK/m7b.json"
sc "$WORK/empty.json" "$WORK/as-b.json" "$WORK/m7b.json"
jq -e '.inconclusive == false' "$WORK/sc.json" >/dev/null || fail "S7 500"
jq '.areas.A.safety_net = {assessed: false, reason: "r"} | .areas.B.safety_net = {assessed: false, reason: "r"}' "$WORK/as.json" > "$WORK/as-sn.json"
sc "$WORK/empty.json" "$WORK/as-sn.json"
jq -e '.inconclusive == true and .inconclusive_reasons == ["axis safety_net not assessed in any area"]' "$WORK/sc.json" >/dev/null || fail "S7 axis"
ok "S7 inconclusive below half the lines and for an axis unassessed everywhere"

rec Z1 Z 1 now | records > "$WORK/s8.json"
sc "$WORK/s8.json"; [ "$RC" = 1 ] || fail "S8 unknown area in records: $RC"
jq '.areas.Z = {}' "$WORK/as.json" > "$WORK/as-z.json"
sc "$WORK/empty.json" "$WORK/as-z.json"; [ "$RC" = 1 ] || fail "S8 unknown area in assessed: $RC"
jq '.areas.A.speed = {assessed: true}' "$WORK/as.json" > "$WORK/as-x.json"
sc "$WORK/empty.json" "$WORK/as-x.json"; [ "$RC" = 1 ] || fail "S8 unknown axis: $RC"
ok "S8 unknown areas and axes exit 1"

rec C1 A 1 now false correction | records > "$WORK/s9.json"
sc "$WORK/s9.json"
jq -e '.areas[0].axes.runtime.value == 3' "$WORK/sc.json" >/dev/null || fail "S9 correction counted"
ok "S9 a correction does not count"
rec T1 A,B 1 now | records > "$WORK/s10.json"
sc "$WORK/s10.json"
jq -e '.areas[0].axes.runtime.value == 1 and .areas[1].axes.runtime.value == 1' "$WORK/sc.json" >/dev/null || fail "S10 two areas"
ok "S10 a record with two areas lowers both"

# S11: with identical records, removing coverage never raises a score
jq '.areas.A.runtime = {assessed: false, reason: "r"}' "$WORK/as.json" > "$WORK/as-ar.json"
jq '.areas.A.runtime = {assessed: false, reason: "r"}' "$WORK/as-b.json" > "$WORK/as-arb.json"
for recs in s5 s10; do
  sc "$WORK/$recs.json"; cp "$WORK/sc.json" "$WORK/full.json"
  for partial in as-b as-ar as-arb; do
    sc "$WORK/$recs.json" "$WORK/$partial.json"
    jq -e --slurpfile f "$WORK/full.json" '.overall <= $f[0].overall and
      ([range(0; .areas | length) as $i | (.areas[$i].score // -1) <= ($f[0].areas[$i].score // -1)] | all)' "$WORK/sc.json" >/dev/null \
      || fail "S11 $recs/$partial raised a score"
  done
done
ok "S11 lost coverage never raises the overall or an area score"

# ---- contract ---------------------------------------------------------------------------------
AP="$SK/auditor-prompt.md"
[ "$(grep -o '{{[^}]*}}' "$AP" | LC_ALL=C sort -u | tr '\n' ' ')" = '{{goalPointers}} {{revision}} {{scope}} {{treeStatus}} ' ] || fail "T1 auditor slots"
for line in '.agents/reference/architecture-review-' '.agents/reference/architecture-assessment-' '.claude/skills/architecture-review/' '.agents/handoffs/' 'coverage_limits'; do
  grep -qF "$line" "$AP" || fail "T1 read exclusion misses $line"
done
! grep -qiE 'GLOSSARY\.md|DEEPENING\.md|INTERFACE-DESIGN\.md|arch-measure|measurement|deepening|candidate|hotspot' "$AP" || fail "T1 auditor prompt names a forbidden input"
ok "T1 auditor prompt: four slots, read exclusion, no forbidden input"
grep -qF '{{records}}' "$SK/refutation-prompt.md" && grep -qF 'not independent' "$SK/refutation-prompt.md" || fail "T2 refutation prompt"
ok "T2 refutation prompt has {{records}} and says it is not independent"
AG="$ST/.claude/agents/architecture-sweeper.md"
grep -qx 'model: claude-opus-5-5' "$AG" && grep -qx 'effort: medium' "$AG" && grep -qx 'tools: Read, Glob, Grep' "$AG" || fail "T3 sweeper frontmatter"
ok "T3 architecture-sweeper is pinned, read-only"
CMD="$ST/.claude/commands/architecture-review.md"
! grep -qF '`Explore`' "$CMD" && grep -qF 'subagent_type: "architecture-sweeper"' "$CMD" || fail "T4 command still spawns Explore"
ok "T4 the command spawns architecture-sweeper, not Explore"
AT=$(awk 'NR > 1 && /^---$/ { exit } /^allowed-tools:/' "$CMD")
case "$AT" in *'Bash(node .claude/lib/arch-assess.mjs:*)'*'Bash(bash .claude/lib/tree-fingerprint.sh:*)'*) ;; *) fail "T5 allowed-tools: $AT" ;; esac
ok "T5 the command's allowed-tools carries both scripts"
for s in '## Phase 0b' 'Phase A' '## Publish' 'arch-assess.mjs score' "overrides the save instruction in \`report-template.html\`'s header comment"; do
  grep -qF "$s" "$CMD" || fail "T6 command misses: $s"
done
ok "T6 the command wires Phase 0b, Phase A, Publish, the scorer and the template override"
! grep -qF 'run the review exactly as it ran before' "$CMD" && ! grep -qF 'go straight into Phase 1' "$CMD" && grep -qF 'continue with Phase 0b' "$CMD" || fail "T7 a Phase 0 path skips the new phases"
ok "T7 no Phase 0 path skips Phase 0b"

echo "arch-assess-test: OK ($N checks)"
