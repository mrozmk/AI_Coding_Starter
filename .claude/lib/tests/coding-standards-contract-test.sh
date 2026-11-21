#!/usr/bin/env bash
# Offline contract test of the coding-standards seed and its routing: the seed
# (.agents/reference/coding-standards.md.example) has the fixed shape, and the memory index, the
# reflection protocol and the guide name docs/coding-standards.md. It also pins the reuse statement the
# planning commands require (`/plan-feature`'s reuse lookup, `**Reuse:**` block, grilling finding and
# cross-model conventions; `/quick-change`'s `Reuse:` line). Text checks only.
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

qc = read(".claude/commands/quick-change.md")
q1 = between(qc, "## Phase 1 —", "## Phase 2 —")
for needle in ("Reuse: <existing path:line> | none found (searched: <terms / paths>)",
               "whole repository", DOC, "CS-<n>"):
    check(needle in q1, f"quick-change Phase 1 lacks {needle!r}")
q2 = between(qc, "## Phase 2 —", "## Phase 3 —")
check("(its `Reuse:` line included)" in q2, "quick-change Phase 2 brief does not carry the Reuse: line")
tm = between(qc, "## Team mode (quick planner)", "## Phase 0")
check("the `Reuse:` line" in tm, "quick-change team-mode plan shape lacks the Reuse: line")

for f in fails:
    print(f"FAIL [{f}]")
if fails:
    sys.exit(1)
print(f"coding-standards-contract-test: OK ({checks} checks)")
PY
