#!/usr/bin/env bash
# Offline contract test of /check-implementation Step 1ab: the command spawns the two read-only
# finders in parallel, proves them (fingerprint, report contract, finder-model.sh), falls back to
# the session's model only as declared, and every place that copies a FALLBACK line says so.
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

man = read(".claude/team/manifest.txt").splitlines()
for p in (".claude/agents/correctness-reviewer.md", ".claude/agents/correctness-reviewer-fallback.md",
          ".claude/agents/structure-reviewer.md", ".claude/agents/structure-reviewer-fallback.md",
          ".claude/lib/tree-fingerprint.sh"):
    check(f"!{p}" in man and f"own {p}" not in man and f"shared {p}" not in man,
          f"manifest: {p} is not core")

for f in fails:
    print(f"FAIL [{f}]")
if fails:
    sys.exit(1)
print(f"check-impl-contract-test: OK ({checks} checks)")
PY
