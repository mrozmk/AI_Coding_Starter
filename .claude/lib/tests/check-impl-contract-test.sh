#!/usr/bin/env bash
# Offline contract test of /check-implementation Step 1ab: the command spawns the two read-only
# finders in parallel, proves them (fingerprint, report contract, finder-model.sh), falls back to
# the session's model only as declared, and every place that copies a FALLBACK line says so.
# It also pins the structure finder's standards contract (the `STANDARDS:` line, the `rule:` /
# `duplicate of:` tags, `/deep-review` standard 9 and the string-coded wording of standard 5).
# It also pins the follow-up policy text: the own + reached finding filter in Step 1ab/1.5, the drop
# tags in the qa prompt, the one-defect ticket bar in the wrapup prompt, the TeamLead prompt,
# `team-lead.md` and the three tracker wrapup blocks, the ticket cap and rework clearing its own
# findings.
# It also pins the per-criterion ledger of /gates:verify-implementation and its copy in Step 1c/3.
# It also pins the sanctioned syntax-check form (#238) in the coder/qa/cli prompts and both finders.
# Text checks only — nothing is spawned.
#
# Usage: bash .claude/lib/tests/check-impl-contract-test.sh [root]   (default: this checkout)
set -u
ROOT="${1:-$(cd "$(dirname "$0")/../../.." && pwd)}"
command -v python3 >/dev/null 2>&1 || { echo "check-impl-contract-test: FAIL — python3 missing"; exit 1; }
python3 - "$ROOT" <<'PY'
import json, os, re, sys

root = sys.argv[1]
fails, checks = [], 0

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

def front(text):
    m = re.match(r"---\n(.*?)\n---\n(.*)", text, re.S)
    if not m:
        return {}, text
    meta, key = {}, None
    for line in m.group(1).splitlines():
        if line.startswith("  - ") and key:
            meta.setdefault(key, []).append(line[4:].strip())
        elif ":" in line:
            key, val = line.split(":", 1)
            key, val = key.strip(), val.strip()
            meta[key] = val if val else []
    return meta, m.group(2)

ci = read(".claude/commands/check-implementation.md")
meta, _ = front(ci)
tools = meta.get("allowed-tools", "")
check("Bash(bash .claude/lib/tree-fingerprint.sh:*)" in tools, "allowed-tools lacks tree-fingerprint.sh")
check("Bash(bash .claude/lib/finder-model.sh:*)" in tools, "allowed-tools lacks finder-model.sh")

s1 = ci.split("## Step 1 —", 1)[-1].split("## Step 1.5", 1)[0] if "## Step 1 —" in ci else ""
check(bool(s1), "Step 1 section not found")
check("subagent_type: correctness-reviewer" in s1 and "subagent_type: structure-reviewer" in s1,
      "Step 1 does not spawn both finders by subagent_type")
check("Spawn both in ONE message" in s1, "Step 1 does not spawn the finders in one message")
check("Never pass `model`" in s1, "Step 1 does not forbid a per-invocation model")
check("tree-fingerprint.sh capture" in s1 and "tree-fingerprint.sh compare" in s1,
      "Step 1 lacks the fingerprint capture/compare")
check("finder-model.sh correctness-reviewer=<id> structure-reviewer=<id>" in s1,
      "Step 1 lacks the finder-model.sh call")
check("=== CORRECTNESS REPORT ===" in s1 and "=== STRUCTURE REPORT ===" in s1,
      "Step 1 lacks the report contract blocks")
check("`agentId`" in s1, "Step 1 does not bind evidence to agent ids")
check("workflow.finder_fallback" in s1 and "correctness-reviewer-fallback" in s1
      and "structure-reviewer-fallback" in s1, "Step 1 lacks the declared fallback")
check("HTTP 429" in s1 and "unavailable" in s1, "Step 1 lacks the two fallback triggers")
check("a substitution is **not** a fallback trigger" in s1,
      "Step 1 lets a finder-model.sh mismatch trigger the fallback")
check("`off` → STOP" in s1, "Step 1 lacks the strict `off` path")
check("never substitute an in-session review" in s1, "Step 1 allows an in-session substitute")
check("the main session is the only mutator" in s1, "1ab-apply is not the only mutator")
check("--fix" not in s1, "Step 1 still applies through a skill's --fix")
check("code-review --fix" not in ci, "the command still routes fixes through /code-review --fix")
check(not re.search(r"^\*\*1[ab]\. ", ci, re.M), "the old 1a/1b steps are still there")

rep = ci.split("## Step 3", 1)[-1].split("## CRITICAL", 1)[0]
fb = [l for l in rep.splitlines() if "FALLBACK" in l]
check(bool(fb) and "workflow.finder_fallback" in fb[0] and "`Warnings:`" in fb[0]
      and "PR description" in fb[0], "Step 3 report lacks the FALLBACK line and where QA copies it")
check("Pinned models, the declared fallback, or STOP" in ci, "CRITICAL rules lack the pinning rule")

for name, skill in (("correctness-reviewer", "code-review"), ("structure-reviewer", "deep-review")):
    pm, _ = front(read(f".claude/agents/{name}.md"))
    fm, body = front(read(f".claude/agents/{name}-fallback.md"))
    check(pm.get("model", "").startswith("claude-"), f"{name}: model is not a pinned id")
    check(fm.get("model") == "inherit", f"{name}-fallback: model is not inherit")
    check(fm.get("effort") and fm.get("effort") == pm.get("effort"),
          f"{name}-fallback: effort differs from {name}")
    check(fm.get("skills") == [skill] == pm.get("skills"), f"{name}-fallback: skills differ")
    check(fm.get("tools") == pm.get("tools"), f"{name}-fallback: tools differ")
    check(f".claude/agents/{name}.md" in body, f"{name}-fallback: does not take {name}'s contract")
    never = read(f".claude/agents/{name}.md").split("## Never", 1)[-1].split("\n## ", 1)[0]
    check("`rm -rf`" in never and "mktemp -d" in never and "never cleaned up" in never,
          f"{name}: Never list lacks the no-rm-rf / fresh-mktemp fixture rule")

# The sanctioned syntax check (#238): role prompts and finders name it and warn off inline interpreters.
PYC = 'd="$(mktemp -d)" && python3 -I -X pycache_prefix="$d" -m py_compile'
FORMS = ("`bash -n <file>`", "`node --check <file>`", "`jq empty <file>`")
for rel in (".claude/team/prompts/coder.md", ".claude/team/prompts/qa.md", ".claude/team/prompts/cli.md"):
    t = read(rel)
    flat = " ".join(t.split())
    check(PYC in flat and all(f in flat for f in FORMS) and "never `python3 -c` or `node -e`" in flat
          and "protected file" in flat, f"{rel}: lacks the sanctioned syntax-check form")
for name in ("correctness-reviewer", "structure-reviewer"):
    nv = read(f".claude/agents/{name}.md").split("## Never", 1)[-1].split("\n## ", 1)[0]
    nv = " ".join(nv.split())
    check(PYC in nv and all(f in nv for f in FORMS) and "`python3 -c` or `node -e`" in nv
          and "protected file" in nv and "the one exception" in nv,
          f"{name}: Never list lacks the sanctioned syntax-check form")

dr = read(".claude/commands/deep-review.md")
check("## Non-negotiable standards (0–9)" in dr, "deep-review heading does not cover standards 0–9")
s9 = dr.split("**9. ", 1)[-1].split("\n---", 1)[0] if "**9. " in dr else ""
check(bool(s9), "deep-review lacks standard 9")
for needle in ("docs/coding-standards.md", "Enforced by: review", "Enforced by: tool",
               "## One shape per problem", "## Shared helpers", "## Open — pick one",
               "Standards: checked <n> review rules",
               "Standards: skipped — no docs/coding-standards.md", "rg --hidden",
               "Duplicate search:", "rule: CS-<n>", "duplicate of: <path:line>", "NEEDS_HUMAN",
               "edit scope"):
    check(needle in s9, f"deep-review standard 9 lacks {needle!r}")
s5 = dr.split("**5. ", 1)[-1].split("**6. ", 1)[0]
check("String-coded control flow" in s5, "deep-review standard 5 does not name string-coded control flow")
check("rule: CS-<n>" in dr.split("## Non-negotiable", 1)[0],
      "deep-review report-only output shape does not name the tags")
for rel in (".claude/agents/orchestrator-refiner.md", ".claude/commands/quick-change.md"):
    check("Enforced by: review" not in read(rel), f"{rel} carries a copy of standard 9")

sr = read(".claude/agents/structure-reviewer.md")
block = sr.split("=== STRUCTURE REPORT ===", 1)[-1].split("=== END STRUCTURE REPORT ===", 1)[0]
check("STANDARDS: checked <n> review rules | skipped — no docs/coding-standards.md" in block,
      "structure report lacks the STANDARDS line")
for h in ("HIGH_CONVICTION:", "NEEDS_HUMAN:", "LOW_TIER:", "STATUS:"):
    check(h in block, f"structure report lost {h}")
check("rule: CS-<n>" in block and "duplicate of: <path:line>" in block,
      "structure report lines lack the rule:/duplicate of: tags")
_, fbody = front(read(".claude/agents/structure-reviewer-fallback.md"))
check("`STANDARDS:`" in fbody and "`rule:`" in fbody and "`duplicate of:`" in fbody,
      "structure-reviewer-fallback does not carry the STANDARDS line and tags")

apply_ = s1.split("**1ab-apply.", 1)[-1].split("**1ab-codex.", 1)[0]
check("`rule: CS-<n>`" in apply_ and "`duplicate of: <path:line>`" in apply_,
      "1ab-apply does not route rule:/duplicate of: findings")
check("`STANDARDS:`" in s1.split("**1ab-apply.", 1)[0], "1ab report contract does not name STANDARDS:")
check(any(l.startswith("- Standards:") for l in rep.splitlines()),
      "Step 3 report lacks the Standards: line")
s15 = ci.split("## Step 1.5", 1)[-1].split("## Step 2", 1)[0]
check("docs/coding-standards.md" in s15, "Step 1.5 prompt does not name docs/coding-standards.md")

qa = read(".claude/team/prompts/qa.md")
step5 = qa.split("\n5. ", 1)[-1].split("\n6. ", 1)[0]
step7 = qa.split("\n7. ", 1)[-1].split("\n8. ", 1)[0]
check("FALLBACK" in step5 and "Warnings:" in step5, "qa prompt step 5: FALLBACK not copied to Warnings")
check("FALLBACK" in step7, "qa prompt step 7: FALLBACK not copied to the PR description")
row = [l for l in read(".agents/reference/team-mode.md").splitlines()
       if l.startswith("| `/check-implementation` |")]
check(bool(row) and "FALLBACK" in row[0] and "Warnings:" in row[0] and "## QA" in row[0],
      "team-mode.md §8 row lacks the FALLBACK routing")
check("workflow.finder_fallback" in read(".agents/reference/team-pipeline.md"),
      "team-pipeline.md does not name the fallback")
check("planned step" not in read(".agents/reference/team-pipeline.md"),
      "team-pipeline.md still calls the finders a planned step")

try:
    prof = json.loads(read(".claude/project-profile.json.example") or "{}")
except ValueError:
    prof = {}
wf = prof.get("workflow", {})
check(wf.get("finder_fallback") in ("session", "off") and "_finder_fallback_doc" in wf,
      "profile example lacks workflow.finder_fallback with its doc")

check("same fixer channel `/check-implementation` uses" not in read(".claude/commands/quick-change.md"),
      "quick-change.md still claims /check-implementation's fixer channel")
check("two subagents per iteration" in read(".claude/docs/guide.md"), "guide.md does not state the cost")
check("two subagents per iteration" in read("docs/teams/upgrade-notes.md"),
      "upgrade-notes.md does not state the cost")

CI = "check-implementation.md"
for needle in ("**The finding filter (own + reached)**", "**own**", "**reached**",
               "When <who> runs <what> on a supported setup, <wrong result>",
               "dropped — hypothetical | cosmetic | not own",
               "only in iteration 1 and in the one cross-model apply pass",
               "more than 8 own-and-reached findings", "back to the coder", "comma-free label",
               "cross-model findings Step 1.5d hands over", "sensitive path found then goes to the warnings",
               "still hold after that spawn", "unpushed commits Step 1.5 reviews",
               "Step 1.5 is skipped as for an escalated loop"):
    check(needle in ci, f"{CI}: lacks {needle!r}")
item1 = apply_.split("\n1. ", 1)[-1].split("\n2. ", 1)[0]
codex_ = s1.split("**1ab-codex.", 1)[-1]
FILTER = "the finding filter (own + reached)"
check(FILTER in item1, f"{CI}: 1ab-apply item 1 does not use {FILTER!r}")
check(FILTER in codex_, f"{CI}: 1ab-codex does not use {FILTER!r}")
check(FILTER in s15, f"{CI}: Step 1.5 does not use {FILTER!r}")
check("apply `medium` only on a **sensitive path" not in item1,
      f"{CI}: 1ab-apply item 1 still carries the old sensitive-path-only filter")

check("dropped — hypothetical|cosmetic|not own" in qa, "qa.md: lacks the drop tags")
check("comma-free label" in qa, "qa.md: lacks 'comma-free label'")

wr = read(".claude/team/prompts/wrapup.md")
for needle in ("holds **one defect**", "When <who> runs <what>, <wrong result>.", "**Real use.**",
               "**Silent harm.**", "**Not fixable in this run.**", "No riders",
               "→ follow-up` line of the accepted `acceptance-brief.md`", "QA dropped N findings",
               "every round's notes"):
    check(needle in wr, f"wrapup.md: lacks {needle!r}")

tl = read(".claude/team/prompts/teamlead.md")
for needle in ("0 by default; at most 1 per run", "not fixable here:",
               "At most one `→ follow-up` line per run", "counted in the brief you accept with",
               "except one routed `→ follow-up`",
               "leaves no logged finding of this run behind", 'never "the brief routes it"'):
    check(needle in tl, f"teamlead.md: lacks {needle!r}")
check("1 ticket and 1 memory entry per run" not in tl, "teamlead.md: still carries the old ticket cap")

tlr = read(".agents/reference/team-lead.md")
for needle in ("0 by default; at most 1 per run", "not fixable here:",
               "leaves no logged finding of this run behind", "holds **one defect**",
               "**Calibration", "extra rework rounds", "counted in the accepted brief",
               "except one routed `→ follow-up`"):
    check(needle in tlr, f"team-lead.md: lacks {needle!r}")
check("1 ticket and 1 memory entry per run" not in tlr, "team-lead.md: still carries the old ticket cap")

for t in ("github", "jira", "none"):
    tw = read(f".claude/team/tracker/{t}-wrapup.md")
    for needle in ("→ follow-up", "the failure sentence"):
        check(needle in tw, f"{t}-wrapup.md: lacks {needle!r}")

man = read(".claude/team/manifest.txt").splitlines()
for p in (".claude/agents/correctness-reviewer.md", ".claude/agents/correctness-reviewer-fallback.md",
          ".claude/agents/structure-reviewer.md", ".claude/agents/structure-reviewer-fallback.md",
          ".claude/lib/tree-fingerprint.sh"):
    check(f"!{p}" in man and f"own {p}" not in man and f"shared {p}" not in man,
          f"manifest: {p} is not core")

def part(text, start, end, what):
    """Lines from the first one starting with `start` to the next later one starting with `end`; fail closed."""
    lines = text.splitlines()
    i = next((n for n, l in enumerate(lines) if l.startswith(start)), None)
    j = None if i is None else next((n for n in range(i + 1, len(lines)) if lines[n].startswith(end)), None)
    if i is None or j is None:
        fails.append(f"{what}: heading lines {start!r} … {end!r} not found in order")
        return ""
    return "\n".join(lines[i:j])

VI = "gates/verify-implementation.md"
vi = read(".claude/commands/gates/verify-implementation.md")
vmeta, _ = front(vi)
check(vmeta.get("argument-hint") == '"[plan-name] [--base <rev>]"', f"{VI}: argument-hint lacks a quoted --base")
check("Bash(bash .claude/lib/branch-model.sh fields)" in vmeta.get("allowed-tools", ""),
      f"{VI}: allowed-tools lacks the base-resolution call")
v1 = part(vi, "## 1. ", "## 1b. ", VI)
v2 = part(vi, "## 2. ", "## 3. ", VI)
v3 = part(vi, "## 3. ", "## 4. ", VI)
v4 = part(vi, "## 4. ", "## 5. ", VI)
v6 = part(vi, "## 6. ", "## 7. ", VI)
v7 = part(vi, "## 7. ", "## CRITICAL", VI)
check("0. **Base for the existing-test check.**" in v1 and "branch-model.sh fields" in v1,
      f"{VI}: §1 lacks the --base resolution")
check("`Proof:` lines nested under it" in v1 and "skipping numbers already used" in v1,
      f"{VI}: §1 does not extract the Proof: lines or label AC-n")
check("**and has no active criteria of its own**" in v1, f"{VI}: §1 skips a sub-step's own criteria")
check("Acceptance criteria: not evaluated — gate stopped at §2 task <n>" in v2
      and "the failed task backs the proof of <id>" in v2, f"{VI}: §2 lacks the early-exit line")
check("or its `IMPLEMENT` / `GOTCHA` names that `<test file> :: <test name literal>` pair" in v2,
      f"{VI}: §2 early exit ignores a proof backed by an existing case")
check("gate stopped at §2 plan contract" in v2 and "§4's Existing tests did not run either" in v2,
      f"{VI}: §2 early exit lacks the plan-contract form or the Existing-tests note")
check("Acceptance criteria: not evaluated — gate stopped at §3 <command>" in v3,
      f"{VI}: §3 lacks the early-exit line")
ex = part(v4, "### HIGH — Existing tests", "### ", VI + " Existing tests")
for needle in ("git diff -M <BASE>", "git diff -M --name-status <BASE>", "git status --porcelain",
               "a move out of discovery is judged like an added skip",
               "Adding cases to an existing test file is not this finding.",
               "High (→ `BLOCK`) with a plan; with no plan (diff-only mode) Medium",
               "no plan task names that test file with that intent",
               "restore the base case (back to its text at the base",
               "undo any skip, filter or selector change that stopped it running",
               "the runner configuration and selection files the diff changes",
               "or of another plan whose file `git diff -M --name-status <BASE> -- .agents/plans/` shows added or moved",
               "of a sub-step of the same umbrella whose `## Execution Plan` row is `done`",
               "the diff changes or adds, untracked ones included"):
    check(needle in ex, f"{VI}: Existing tests lacks {needle!r}")
check("Does the code satisfy the plan's **acceptance criteria**?" not in vi,
      f"{VI}: §6 still judges all criteria in one prose question")
rows = {l.split(" | ", 1)[0]: l for l in v6.splitlines() if l.startswith("| `")}
for verdict, cond, effect in (
        ("| `met`", "**that named case ran and passed**", "| `—` |"),
        ("| `unmet`", "a declared `static` literal is absent", "| `BLOCK` (High) |"),
        ("| `unconfirmed` (declared `test`)", "the declared test is missing, failing", "| `BLOCK` (High) |"),
        ("| `unconfirmed` (other)", "a test that exists but whose run cannot be shown", "| `WARN` (Medium) |"),
        ("| `deferred`", "`Proof: manual`, `Proof: none — <why>`",
         "| `—` — informational: listed, no warning, verdict unchanged |")):
    row = rows.get(verdict, "")
    check(cond in row and row.endswith(effect), f"{VI}: ledger row {verdict!r} lost its condition or effect")
for needle in ("### Acceptance-criteria ledger", "a green file is not enough",
               "`unconfirmed — test exists, run not shown`",
               "a missing or duplicated id is reported at the top of the block, never dropped",
               "can **identify that case**",
               "a selection that excludes the named case (a step list, a filter, a skip flag) settles the row",
               "once no §3 command that could run it admits it",
               "**Evidence of a `deferred` row** carries the plan's own words",
               "never a direct file call that bypasses its isolation",
               "`unmet` › `unconfirmed` › `deferred` › `met`",
               "the one with effect `BLOCK` wins over `WARN`",
               "red before: declared yes | n/a | not recorded",
               "every active criterion appears exactly once", "(`<id> (1)`, `<id> (2)`)",
               "Withdrawn criteria get no row",
               "**Legacy plan — no `Proof:` line anywhere.** It does not block",
               "`unconfirmed — no proof declared`", "Acceptance criteria: n/a (no plan)"):
    check(needle in v6, f"{VI}: §6 ledger lacks {needle!r}")
for needle in ("### Acceptance Criteria",
               "Acceptance criteria: total=<n> met=<n> unmet=<n> unconfirmed=<n> deferred=<n>",
               "| Id | Verdict | Effect | Evidence |", "Existing tests: [",
               "no `unmet` or `unconfirmed` ledger row",
               "`unconfirmed` ledger rows with effect `WARN`",
               "any `unconfirmed` ledger row with effect `BLOCK`, or an Existing-tests High finding"):
    check(needle in v7, f"{VI}: §7 lacks {needle!r}")

c1c = part(ci, "**1c. Code gate", "**1d. ", CI + " 1c")
check("--base <BASE>" in c1c and "never edits, adds or drops a row" in c1c,
      f"{CI}: 1c does not pass --base or copy the ledger read-only")
check("in every mode, the merge-base SHA of the branch's line resolved with item 0's chain" in c1c
      and "Only when that is unresolvable is `--base` left out" in c1c,
      f"{CI}: 1c does not resolve the branch line for --base in every mode")
check("Acceptance criteria: not evaluated — gate failed to load" in c1c,
      f"{CI}: 1c reuses a ledger after a substituted gate")
check("**Then the blocking ledger rows**" in s1 and "four sources" in s1
      and "never enters `FOCUS`" in s1, f"{CI}: FOCUS lacks the blocking ledger rows")
check("**An Existing-tests finding is never cleared by editing the test further**" in item1,
      f"{CI}: 1ab-apply item 1 lacks the existing-test fixer rule")
check("to its base text and make the code pass it" in codex_,
      f"{CI}: 1ab-codex lacks the existing-test rule")
check("the blocking ledger rows of the gate's `### Acceptance Criteria` block, and **all** design-gate"
      in codex_, f"{CI}: 1ab-codex fix list omits the blocking ledger rows")
check("never the diff-only Medium Existing-tests finding, which stays in the report" in s15,
      f"{CI}: 1.5e re-gate feeds the diff-only Medium finding to the fixer")
check("- Acceptance criteria: <the gate's completeness notice" in rep,
      f"{CI}: Step 3 report lacks the Acceptance criteria block")
check("repeats the gate's `Acceptance criteria: not evaluated — gate stopped at …` line" in rep,
      f"{CI}: Step 3 does not repeat the not-evaluated line on escalation")

for f in fails:
    print(f"FAIL [{f}]")
if fails:
    sys.exit(1)
print(f"check-impl-contract-test: OK ({checks} checks)")
PY
