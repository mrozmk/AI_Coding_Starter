#!/usr/bin/env bash
# Offline contract test of the coding-standards seed and its routing: the seed
# (.agents/reference/coding-standards.md.example) has the fixed shape, and the memory index, the
# reflection protocol and the guide name docs/coding-standards.md. It also pins the reuse statement the
# planning commands require (`/plan-feature`'s reuse lookup, `**Reuse:**` block, grilling finding and
# cross-model conventions; `/quick-change`'s `Reuse:` line).
# It also pins the per-criterion proof contract: the four-kind `Proof:` grammar and `AC-n` labels
# in `/plan-feature` and `/quick-change`, the withdrawn exclusion and the test-first task order in
# `/plan-feature`, grill step 5.1f, and `/execute`'s red-before-green line. Text checks only. It also asserts that
# `/setup:map-codebase`, the map-codebase workflow's standards prompt and the seed agree on the four
# section names, and that the renderer hard-codes none.
#
# Usage: bash .claude/lib/tests/coding-standards-contract-test.sh [root]   (default: this checkout)
set -u
ROOT="${1:-$(cd "$(dirname "$0")/../../.." && pwd)}"
command -v python3 >/dev/null 2>&1 || { echo "coding-standards-contract-test: FAIL — python3 missing"; exit 1; }
python3 - "$ROOT" <<'PY'
import os, re, sys

root = sys.argv[1]
fails, checks = [], 0
DOC = "docs/coding-standards.md"
SEED = ".agents/reference/coding-standards.md.example"
SECTIONS = ["Rules", "Shared helpers", "One shape per problem", "Open — pick one"]
FIELDS = ["- Enforced by:", "- Applies to:", "- Example:", "- Why:"]

def read(rel):
    try:
        with open(os.path.join(root, rel), encoding="utf-8") as f:
            return f.read()
    except OSError:
        fails.append(f"{rel}: missing")
        return ""

def check(ok, what):
    global checks
    checks += 1
    if not ok:
        fails.append(what)

def section(text, name):
    m = re.search(r"^## " + re.escape(name) + r"\n(.*?)(?=^## |\Z)", text, re.S | re.M)
    return m.group(1) if m else ""

def between(text, start, end):
    return text.split(start, 1)[1].split(end, 1)[0] if start in text else ""

def heading_slice(text, start, end):
    """(found, slice) between two headings, each matched as a whole line, end after start."""
    m = re.search(r"^" + re.escape(start) + r"$", text, re.M)
    n = re.compile(r"^" + re.escape(end) + r"$", re.M).search(text, m.end()) if m else None
    return (True, text[m.end():n.start()]) if m and n else (False, "")

def strict_between(text, start, end, what):
    """Fail closed: a missing or renamed start or end heading is a failure, never a widened slice."""
    found, body = heading_slice(text, start, end)
    check(found, f"{what}: heading lines {start!r} … {end!r} not found in order")
    return body

# The helper itself: a missing end fails, a renamed heading that keeps the old prefix fails,
# and a mid-line mention of the start is not the heading.
check(heading_slice("## A\nx\n", "## A", "## B") == (False, ""), "heading_slice accepts a missing end")
check(heading_slice("## A\nx\n## B2\n", "## A", "## B") == (False, ""),
      "heading_slice accepts a renamed end heading that keeps the old prefix")
check(heading_slice("see `## A`\n## A\ny\n## B\n", "## A", "## B") == (True, "\ny\n"),
      "heading_slice matches a mid-line mention instead of the heading")

GRAMMAR = ("Proof: static — <path>[ :: <literal>]",
           "Proof: test — <test file> :: <test name literal>",
           "Proof: manual — <what a human observes, and where>",
           "Proof: none — <why>")

seed = read(SEED)
lines = seed.splitlines()
check(len(lines) <= 200, f"seed: {len(lines)} lines, limit 200")
check([l for l in lines if re.match(r"# ", l)] == ["# Coding standards"], "seed: one `# Coding standards` title")
check([l[3:] for l in lines if l.startswith("## ")] == SECTIONS, "seed: the four `##` sections, in order")

rules = section(seed, "Rules")
blocks = re.findall(r"^### CS-(\d+) — \S.*?\n(.*?)(?=^### |\Z)", rules, re.S | re.M)
ids = [n for n, _ in blocks]
check(len(blocks) >= 2, "seed: at least two `### CS-<n> — ` rules")
check(len(ids) == len(set(ids)), "seed: rule ids are unique")
check(len(re.findall(r"^### ", rules, re.M)) == len(blocks), "seed: every `###` under Rules is a `CS-<n> — ` rule")
for n, body in blocks:
    rows = [l for l in body.splitlines() if l.startswith("- ")]
    for field in FIELDS:
        check(any(r.startswith(field) for r in rows), f"seed: CS-{n} has `{field}`")
    by = next((r[len(FIELDS[0]):].strip() for r in rows if r.startswith(FIELDS[0])), "")
    check(by == "review" or by.startswith("tool ("), f"seed: CS-{n} `Enforced by` is `review` or `tool (…)`")

check("| Need | Use | Path |" in section(seed, "Shared helpers"), "seed: Shared helpers table header")
check("| Problem | The shape to use | Reference |" in section(seed, "One shape per problem"),
      "seed: One shape per problem table header")

index = read(".agents/memory/index.md")
m = re.search(r"^## When to Read.*?\n(.*?)(?=^## |\Z)", index, re.S | re.M)
when = m.group(1) if m else ""
rows = [l for l in when.splitlines() if DOC in l]
check(len(rows) >= 3, f"index.md: When to Read names {DOC} in at least three rows")
check(all("skip if absent" in r for r in rows), f"index.md: every When to Read row naming {DOC} says `skip if absent`")

protocol = read(".agents/memory/reflection-protocol.md")
check(DOC in protocol, f"reflection-protocol.md names {DOC}")
check("### Standards vs memory" in protocol, "reflection-protocol.md has `### Standards vs memory`")

check(DOC in read(".claude/docs/guide.md"), f"guide.md names {DOC}")

pf = read(".claude/commands/plan-feature.md")
lookup = between(pf, "**2. Pattern Recognition**", "**3. Dependency Analysis**")
for needle in ("whole repository", "rg --hidden", DOC, "## Shared helpers", "## One shape per problem",
               "## Open — pick one", "**Reuse:**", "Open questions:"):
    check(needle in lookup, f"plan-feature Pattern Recognition lacks {needle!r}")
ptf = between(pf, "### Patterns to Follow", "## STEP-BY-STEP TASKS")
for needle in ("**Reuse:**", "→ reuse <path:line>", "→ none found (searched: <terms / paths>)",
               "→ shared at <path>", "**Standards:**", "skipped — no docs/coding-standards.md",
               "**Shapes:**", "**Open — pick one:**"):
    check(needle in ptf, f"plan template Patterns to Follow lacks {needle!r}")
notes = between(pf, "\n## NOTES\n", "## Phase 4.5")
check("Open questions:" in notes, "plan template NOTES does not name Open questions:")
check("(its `**Reuse:**` block included)" in pf, "densify rule does not protect the Reuse block")
major = between(pf, "**🟠 MAJOR**", "**🟡 MEDIUM**")
for needle in ("**Reuse:**", "## One shape per problem", "## Shared helpers"):
    check(needle in major, f"grilling MAJOR list lacks {needle!r}")
p7 = between(pf, "### Step 7.3", "### Step 7.4")
check(DOC in p7, f"Phase 7 prompt does not name {DOC}")
ac = strict_between(pf, "## ACCEPTANCE CRITERIA", "## NOTES", "plan template ACCEPTANCE CRITERIA")
for needle in GRAMMAR + ("**Proof lines — every active criterion.**",
                         "Under each criterion write one or more `Proof:` lines as nested list items",
                         "`AC-1 … AC-n` in document order", "skipping numbers already used",
                         "`(withdrawn)` keeps its id and text but takes no `Proof:` line and is not counted",
                         "The `Technical checks` sub-list takes neither",
                         "`contains — <test file> :: <test name literal>`",
                         "unless that named test case already exists",
                         "Order that task before the task(s) that implement the behaviour it proves",
                         "never in a separate tests-only sub-step",
                         "the criterion is a structural fact provable without running anything",
                         "the criterion asserts an outcome that appears only when something runs",
                         "the criterion can only be observed in a running app",
                         "the criterion is behavioural, could be tested, and the plan deliberately adds no test"):
    check(needle in ac, f"plan template ACCEPTANCE CRITERIA lacks {needle!r}")
ts = strict_between(pf, "## TESTING STRATEGY", "### Core Functions to Test (if applicable)",
                    "plan template TESTING STRATEGY")
for needle in ("**Per criterion (every project size):**", "**unit** test", "**integration** test",
               "`manual` at task level", "`static` for structure and text"):
    check(needle in ts, f"plan template TESTING STRATEGY lacks {needle!r}")
check("/test-e2e" not in ts, "plan template TESTING STRATEGY names /test-e2e")
gate = strict_between(pf, "### Step 5.1f — AC proof gate (MANDATORY for every plan with `## ACCEPTANCE CRITERIA`)",
                      "### Step 5.2 — Raw critique pass (4 categories)", "grill step 5.1f")
for needle in ("**Trigger:** always", "🟠 MAJOR", "no `Proof:` line", "carries only `static` proofs",
               "no task creates or updates", "test policy says a test MUST exist",
               "behaviour an existing test covers and names no task that updates or removes that test",
               "neither writes that test (before the behaviour) nor names the existing case",
               "unless that test is an unchanged case a `Proof: test` line names"):
    check(needle in gate, f"grill step 5.1f lacks {needle!r}")
check("These five gates" in gate, "plan-feature gates note does not count five gates")
check("a tests-only sub-step never holds a test a `Proof: test` line names" in pf,
      "plan-feature split mechanics still allow a proof test in a tests-only sub-step")
p7s = strict_between(pf, "### Step 7.3 — Build the review prompt (BROAD mandate + strict evidence bar)",
                     "### Step 7.4 — Invoke codex in the background, then poll (per round)", "Phase 7 prompt")
check("**Acceptance proofs**" in p7s, "Phase 7 prompt lacks the Acceptance proofs bullet")

qc = read(".claude/commands/quick-change.md")
q1 = between(qc, "## Phase 1 —", "## Phase 2 —")
for needle in ("Reuse: <existing path:line> | none found (searched: <terms / paths>)",
               "whole repository", DOC, "CS-<n>"):
    check(needle in q1, f"quick-change Phase 1 lacks {needle!r}")
q2 = between(qc, "## Phase 2 —", "## Phase 3 —")
check("(its `Reuse:` line included)" in q2, "quick-change Phase 2 brief does not carry the Reuse: line")
tm = between(qc, "## Team mode (quick planner)", "## Phase 0")
check("the `Reuse:` line" in tm, "quick-change team-mode plan shape lacks the Reuse: line")
q1s = strict_between(qc, "## Phase 1 — The short plan (in chat, no file)",
                     "## Phase 2 — Codex reviews the plan (idea mode) — mandatory when `codex` exists",
                     "quick-change Phase 1")
for needle in GRAMMAR:
    check(needle in q1s, f"quick-change Phase 1 Testy line lacks {needle!r}")
tms = strict_between(qc, "## Team mode (quick planner)", "## Phase 0 — Is this actually small? (the guard)",
                     "quick-change team mode")
for needle in ("`Proof:` line as a nested item", "`- **AC-1** — <done>` then `  - Proof: <kind> — …`",
               "`contains — <test file> :: <test name literal>`",
               "the task that writes or changes a proof test comes before the task that implements"):
    check(needle in tms, f"quick-change team-mode plan shape lacks {needle!r}")

ex = read(".claude/commands/execute.md")
e2 = strict_between(ex, "### 2. Execute Tasks in Order", "#### a. Navigate to the task", "execute §2 head")
for needle in ("**Proof tests first — red before green.**", "see it fail",
               "a test that cannot compile yet counts as failing", "pull the test task forward",
               "rework a test this plan writes until it fails for the missing behaviour",
               "an existing case the plan leaves unchanged is not rewritten",
               "in `/execute codex` the supervisor does it, never Codex",
               "the umbrella's `## ACCEPTANCE CRITERIA`",
               "`red before green: <test> — yes | n/a — <why>`", "`## Unattended decisions`"):
    check(needle in e2, f"execute §2 lacks {needle!r}")
e3 = strict_between(ex, "### 3. Implement Testing Strategy", "### 4. Run Validation Commands", "execute §3")
check("proof tests were already written or run in §2" in e3, "execute §3 still writes proof tests after the code")
check("Re-run every proof test" in e3, "execute §3 does not re-run proof tests for green")
check("Implement all test cases mentioned" not in e3, "execute §3 still implements every test case after the code")
added = strict_between(ex, "### Tests Added", "### Validation Results", "execute Tests Added")
check("`red before green: <test> — yes | n/a — <why>`" in added, "execute Tests Added lacks the red-before-green line")
e7 = strict_between(ex, "### 7. Memory reflection", "## Output Report", "execute §7")
check("`red before green: <test> — …`" in e7, "execute §7 team paragraph does not route the red-before-green line")
tmd = read(".agents/reference/team-mode.md")
t8 = strict_between(tmd, "## 8. What team mode changes per command", "## 8a. PR provider", "team-mode §8")
row = [l for l in t8.splitlines() if l.startswith("| `/execute` |")]
check(len(row) == 1 and "red before green" in row[0] and "## Unattended decisions" in row[0],
      "team-mode §8 /execute row does not name the red-before-green notes line")

names = ["## " + s for s in SECTIONS]
def in_order(text):
    pos = [text.find(n) for n in names]
    return all(p >= 0 for p in pos) and pos == sorted(pos)
mc = read(".claude/commands/setup/map-codebase.md")
item = between(mc, "**Coding standards**", "## 🛑 Checkpoint 2")
check(in_order(item), "map-codebase.md Coding standards item does not name the four sections in order")
wf = read(".claude/workflows/map-codebase.js")
sp = between(wf, "const standardsPrompt", "\nconst ")
check(in_order(sp), "workflow standards prompt does not name the four sections in order")
rd = read(".claude/lib/coding-standards-render.mjs")
check(not any(s in rd for s in SECTIONS[1:]) and "## Rules" not in rd, "renderer hard-codes a section name")

for f in fails:
    print(f"FAIL [{f}]")
if fails:
    sys.exit(1)
print(f"coding-standards-contract-test: OK ({checks} checks)")
PY
