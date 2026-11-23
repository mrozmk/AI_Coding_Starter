---
name: architecture-review
description: Codebase-wide architecture audit that hunts for deepening opportunities — shallow modules, pass-through layers, spaghetti coupling, and badly-located maintenance. On-demand (NOT in the feature pipeline). Produces an HTML report of refactor candidates ranked by depth/locality gain. Analyze-only — never mutates code. Uses the depth / locality / deletion-test method (Ousterhout "A Philosophy of Software Design" + Feathers "seams") — and an architecture assessment report (verdict, per-area scorecard, risk-tiered findings) with a blind Codex auditor.
argument-hint: "[module or area | empty = whole codebase] [--codex = also a second deepening sweep by Codex] [--no-codex = skip the Codex auditor and refutation] [--exclude <glob>]…"
allowed-tools: Bash(node .claude/lib/arch-assess.mjs:*), Bash(bash .claude/lib/tree-fingerprint.sh:*)
---

# /architecture-review — Codebase-Wide Architecture Audit

Surface architectural friction across the **whole codebase** (or a named area) and propose **deepening opportunities** — refactors that turn shallow modules into deep ones. The aim is leverage, locality, testability, and AI-navigability. This review **reports and reasons; it never edits code.** The actual refactor, once a candidate is chosen, goes through `/brainstorm` → `/plan-feature` → `/execute`.

One invocation writes **two reports**:

- **Report 1 — deepening candidates** (`architecture-review-YYYY-MM-DD.html`): where a refactor would pay off, by the depth / locality method — unchanged in method, structure and template.
- **Report 2 — architecture assessment** (`architecture-assessment-YYYY-MM-DD.html`): is the architecture sound — a verdict, a per-area scorecard on four axes, risk findings in three tiers, corrections, what not to do and what was not covered — from the same sweep, a deterministic measurement (`.claude/lib/arch-assess.mjs`), a blind Codex auditor and a refutation pass. Method: [`.claude/skills/architecture-review/ASSESSMENT.md`](../skills/architecture-review/ASSESSMENT.md).

Resource files for this skill live under `.claude/skills/architecture-review/` — reference them by **full path** (this command file lives in `commands/`, so relative links would resolve wrong).

**Vocabulary is load-bearing** — for report 1 and the `depth` output; the `risk` output uses `ASSESSMENT.md`. Use the terms in [`.claude/skills/architecture-review/GLOSSARY.md`](../skills/architecture-review/GLOSSARY.md) **exactly** in every observation and card — module, interface, depth/deep/shallow, seam, adapter, leverage, locality. Don't drift into "component," "service," "API," or "boundary." Consistent language is the point.

---

## What this is NOT — scope boundaries (read first)

This command is deliberately distinct from three neighbours. Pick the right tool:

- **`/deep-review`** — per-diff structural audit of a *change*, runs *inside* the quality pipeline, and **mutates** code (it applies fixes). `/architecture-review` is **codebase-wide**, **on-demand** (outside any feature cycle), and **analyze-only**. The two are **composed, not merged**: this review hands `/deep-review` a target list via the Hotspots section (Phase 2b) and never applies its standards itself.
- **`/analysis`** — a scope-boxed thinking tool for one decision or question; writes **no files**. `/architecture-review` sweeps the whole base and **emits an HTML report** of multiple ranked candidates.
- **`/setup:map-codebase`** — brownfield bootstrap that **documents** an unfamiliar codebase into the knowledge layer; it describes what exists, it does not hunt for debt. `/architecture-review` assumes the map exists and goes looking for **shallow modules worth deepening**.

> In one line: **codebase-wide, on-demand, analyze-only.** It finds refactor candidates; it does not document, decide-in-isolation, or change code.

---

## Preflight

1. **Flags.** Strip the tokens `--codex`, `--no-codex` and every `--exclude <glob>` pair from `$ARGUMENTS`; the rest is the focus. The phase order is always **Preflight → 0 (if `--codex`) → 0b (unless `--no-codex`, or `codex` is not on PATH) → M → 1 → 2 → 2b → 2c → A → Publish → 3**, for all four flag combinations (`--codex --no-codex` = the deepening sweep yes, the auditor and the refutation no).
2. **Scratch.** `SCRATCH` = a **fresh subdirectory per invocation**, `<session scratch dir>/architecture-review-<UTC yyyymmddThhmmss>` (the host names the session scratch dir; without one, `$(mktemp -d)`) — never a path inside the checkout, never reused by a second invocation, so no artifact of an earlier run (an `auditor.json` above all) can enter this one. Every phase's `OUT`, `LOG`, prompt, JSON and rendered report lives there until Publish.
3. **Snapshot.** Record `git rev-parse HEAD` (the revision), `git status --porcelain` (the header's tree status: `clean`, or the lines) and the content fingerprint: `bash .claude/lib/tree-fingerprint.sh capture "$SCRATCH/tree.fp"`.
4. **One scope for every phase** — the measurement, both Claude lenses, the auditor's scope slot and the `--codex` sweep: the focus, or with no focus the whole base **including dot-directories**, minus the `--exclude` globs. In a downstream project pass `--exclude '.claude/**'` to assess product code only.
5. **Independence.** Read no earlier `.agents/reference/architecture-review-*` or `architecture-assessment-*` report before both reports of this run are rendered.

---

## Phase 0 — Second sweep by Codex (`--codex`, opt-in)

Strip a bare `--codex` token from `$ARGUMENTS` before treating the rest as the focus argument. **Without the flag, skip this phase** and continue with Phase 0b — a full `high`-effort Codex sweep of a whole codebase is slow and expensive, and this command is already on-demand. `--codex` adds this second *deepening* sweep; the Codex auditor of Phase 0b is separate and on by default.

With the flag: launch Codex on **the same task, with the same method, over the same codebase**, at the very start — so it works while Phase 1 runs. Two sweeps in parallel, not one sweep and one critique.

**Why the same method, not a free-form second opinion.** The method *is* this command's product. A reviewer without `GLOSSARY.md` and `DEEPENING.md` does not return deepening candidates — it returns a generic list of code smells, which is `/deep-review`'s lens and is explicitly out of scope here (see Phase 2b). So Codex gets the full method. The independence we want lives elsewhere:

> **Never show Codex our findings.** Not the candidate list, not the hotspots, not a hypothesis, not "we think module X is shallow" — during this phase or after it. It reads the same method and the same code, and reaches its own conclusions. The difference between the two sweeps must come from *what each noticed*, never from one having been told what the other found. This is the whole reason the phase exists; seeding it turns a second sweep into an echo.

**Precondition.** `command -v codex` — if absent, say so in one line, continue without it, and note in the report that only one sweep ran. **Never fabricate a Codex sweep** (project rule: never fake it).

**Assemble the prompt** in this order:

1. **Orientation** — "First, orient yourself in this project: read `.claude/commands/prime.md` and follow its quick-mode steps. Do not run it as a slash command — just read that file and do what it says."
2. **The method** — "Then read `.claude/skills/architecture-review/GLOSSARY.md` and `.claude/skills/architecture-review/DEEPENING.md`. They define the vocabulary and the method: depth as leverage per unit of interface complexity, the deletion test, seam discipline, the four dependency categories. Use those terms exactly."
3. **The task** — "Sweep this codebase for **deepening opportunities**: shallow modules whose interface is nearly as complex as their implementation, pass-through layers, clusters worth merging into one deep module, and maintenance scattered across callers. Apply the deletion test to everything you suspect is shallow. For each candidate report: the files, the problem in GLOSSARY terms, the deepening you propose, and what callers and maintainers gain. Cite by `file:line`." Add the focus argument if the user gave one; otherwise say the whole base is in scope. When `--exclude` was given, add "out of scope: <globs>" — with no `--exclude` the prompt is byte-for-byte what it was.
4. **The out-of-scope catch** — "If you notice areas that are simply large, branchy or untested but are *not* depth problems, list them separately at the end under `OUT-OF-LENS:`, one line each, files only. Do not mix them into the candidates." (These feed Hotspots in Phase 2b; the split keeps them from polluting the candidate list.)
5. **Anti-forcing, verbatim** — "Calibrate to what is actually there. A codebase with no strong deepening candidate is a valid, valuable result — say so plainly and stop; do NOT manufacture candidates, pad the list, or inflate a nit into a refactor. Each candidate must earn its place: would it actually change how someone maintains this code? Three real candidates beat fifteen padded ones."
6. **Heartbeat** — "Every ~3 minutes print one short line prefixed `STATUS:`. End with `REVIEW COMPLETE`."

Do **not** put our opinions, expected findings, or severity hints in the prompt. Orientation + method + scope + open task, nothing else.

**Launch** through the shared wrapper, in the background, read-only, prose (no `SCHEMA`) — the contract is [.agents/reference/codex-spawn.md](../../.agents/reference/codex-spawn.md):

```bash
CODEX_EFFORT=high \
PROMPT="<the assembled prompt>" \
OUT="$SCRATCH/architecture-codex.final.md" \
LOG="$SCRATCH/architecture-codex.log" \
REPO="<repo-root>" \
bash .claude/lib/codex-bg.sh
```

Never inline `codex exec`. Never pass `SANDBOX=workspace-write` — a review mutates nothing (that mode belongs to `/execute codex` / `/check-implementation codex` only). Run with `run_in_background: true`, then **go straight on to Phase 0b** rather than waiting; that concurrency is the point of running it first.

**Done signal: a non-empty `architecture-codex.final.md`, never process exit alone.** A backgrounded launcher exits 0 while Codex is still thinking, and a hung or killed run also exits without writing. Heartbeats come from the `.log` (`rg '^STATUS:' … | tail -1`) — never read the whole log, it is hundreds of KB of orchestration noise. If Phase 1 finishes first, relay a heartbeat and wait while the log still grows; never read an empty `.final.md` as "Codex found nothing". Three exits, each ending with `ScheduleWakeup stop: true` (cancel-on-every-exit rule: `codex-spawn.md` → polling loop, step 3): **DONE-OK** — `.final.md` non-empty → merge the sweep; **DONE-FAILED** — process exited, file empty → stop the wakeup, retry once, then render from Claude's sweep alone and say so; **hard kill** — elapsed ≥ 60 min (`codex-spawn.md` → ceilings) → `TaskStop`, stop the wakeup, render from one sweep. Never leave a wakeup or task armed after the report is written — a stale one re-invokes this command on finished work.

---

## Phase 0b — Codex auditor (default; --no-codex skips it)

A blind Codex auditor of operational invariants, feeding report 2. It runs by default; `--no-codex` skips it (and the refutation pass of Phase A).

**Precondition.** `command -v codex` — if absent, say so in one line and continue: report 2 then rests on one lens and its header says so. **Never fabricate an auditor run.**

**Prompt** = [`.claude/skills/architecture-review/auditor-prompt.md`](../skills/architecture-review/auditor-prompt.md) with its four slots filled by literal replacement, and **nothing else**:

- `{{revision}}` — the preflight revision;
- `{{treeStatus}}` — `clean`, or the porcelain lines;
- `{{scope}}` — the resolved scope (the focus or "the whole base, dot-directories included", plus "out of scope: <globs>" when `--exclude` was given);
- `{{goalPointers}}` — `CLAUDE.md`, `.agents/memory/project-brief.md`, `.agents/memory/decisions.md`, and `docs/PRD.md` when present.

**Forbidden inputs — no exception, a seeded auditor is an echo:** prior reports, our findings or hypotheses, suspected files, proposed fixes, candidate rankings, the measurement file, the method files (`GLOSSARY.md`, `DEEPENING.md`, `INTERFACE-DESIGN.md`). The template carries the read exclusion it keeps until it submits.

Write the filled prompt to `$SCRATCH/auditor.prompt.md`, then launch — prose mode (no `SCHEMA`), the real read-only sandbox, `run_in_background: true`:

```bash
CODEX_EFFORT=high \
PROMPT="$(cat "$SCRATCH/auditor.prompt.md")" \
OUT="$SCRATCH/auditor.final.md" \
LOG="$SCRATCH/auditor.log" \
SANDBOX=read-only \
REPO="<repo-root>" \
bash .claude/lib/codex-bg.sh
```

Then go straight on to Phase M. **Lifecycle** per [.agents/reference/codex-spawn.md](../../.agents/reference/codex-spawn.md) → polling loop, with `FIRST_CHECK 8 min · POLL_INTERVAL 5 min · HARD_KILL 40 min`. **DONE-OK** (`auditor.final.md` non-empty) → `node .claude/lib/arch-assess.mjs check auditor "$SCRATCH/auditor.final.md" --out "$SCRATCH/auditor.json"`; exit 1 (no single JSON object, or invalid) → one retry of the spawn, then the run counts as failed. An empty `OUT` is never "no findings". Cancel the wakeup on every exit path (`ScheduleWakeup stop: true`); Phase A step 0 freezes the outcome.

---

## Phase M — Measure

One deterministic measurement for both reports:

```bash
node .claude/lib/arch-assess.mjs measure --root <repo-root> [--focus <focus>] [--exclude <glob>]… --out "$SCRATCH/arch-measure.json"
```

It writes areas, per-file sizes and signals (`lines`, `branches`, `fan_in`, `mentions`, `sibling_test`, `test_imported`, `test_referenced`), the area import graph and its cycles, the comparison with `docs/map/system.yaml`, change cost per area and `safety_flags`. Same tree → byte-identical file.

- If one area holds **> 60 %** of the source lines, rerun with explicit `--area <name>=<glob>[,<glob>]` flags that split it (by its child directories), and say so in report 2. Explicit flags switch the auto areas off — an area not named in a flag falls into `(rest)` — so the rerun names **every** area: first the split child directories, then the large area itself with its own glob (it keeps its direct files), then every other area of the first run's `areas[]` with its `name` and `globs` (all but `(rest)`). The first matching flag wins, so this order keeps each file where it belongs.
- Group the areas into **at most 6 sweep assignments**; the smallest areas share one.
- The auditor never receives this file.

---

## Phase 1 — Explore (read-only)

**Read our knowledge layer first** so the review speaks our domain language and doesn't re-open settled choices:

1. [`.agents/memory/architecture.md`](../../.agents/memory/architecture.md) — our module map and naming rules. Use its domain vocabulary for *what the modules are*; use [`GLOSSARY.md`](../skills/architecture-review/GLOSSARY.md) for *how they're shaped* (depth/seam/adapter).
2. [`.agents/memory/decisions.md`](../../.agents/memory/decisions.md) — settled architectural decisions. **Do not re-litigate these.** If a candidate contradicts a recorded decision, only surface it when the friction is genuinely worth reopening the decision — and mark it clearly in the card as a warning callout (e.g. _"contradicts the 2026-xx-xx decision on X — but worth reopening because…"_). Don't list every refactor a decision forbids.

**Then walk the codebase.** Spawn the pinned **`architecture-sweeper`** agent (`subagent_type: "architecture-sweeper"` — Opus, medium effort, read-only, whole-file reads) via the Agent tool, **one per sweep assignment of Phase M, in parallel calls**, so codebase size scales the number of agents, not the context. Every sweep stays inside the resolved scope. Each brief carries:

1. the depth instructions below — this section from "Don't follow rigid heuristics" to "Do **not** propose interfaces yet", passed verbatim;
2. [`.claude/skills/architecture-review/ASSESSMENT.md`](../skills/architecture-review/ASSESSMENT.md) §2–3 — the risk checklist, the per-finding fields and the coverage block;
3. the assignment's slice of `$SCRATCH/arch-measure.json` — its areas and their `files[]` rows, their `change_cost` entries (or the top-level `change_cost.skipped` reason), and the `graph` edges, `mutual` pairs and `cycles` and the `map` entries (`against`, `undeclared`, `incomparable`, or `map.skipped`) that touch its areas; class 8 and class 12 of `ASSESSMENT.md` cite these figures.

Each sweep returns three typed sections: **`depth`** (observations and deletion-test results — what this phase has always collected), **`risk`** (findings per `ASSESSMENT.md` §3) and **`coverage`** (per assigned area and axis: `checked`, or `not-checked` with the unread files). The lenses meet only in the agent's reading.

Don't follow rigid heuristics — explore organically and note where you feel **friction**:

- **Bouncing between modules** — understanding one concept requires hopping across many small modules (poor locality).
- **Shallow interfaces** — the interface is nearly as complex as the implementation (a thin wrapper / pass-through).
- **Pure-function extraction for testability only** — logic split out solely to be unit-testable, while the real bugs hide in *how it's called* (no locality at the call sites).
- **Tightly-coupled leaks** — modules that leak state or assumptions across their seams.
- **Untested / hard-to-test code** — code that's untested, or untestable through its current interface (the interface is the test surface).

**Apply the deletion test** to anything you suspect is shallow: imagine deleting the module. If complexity *vanishes*, it was a pass-through layer — a candidate to delete or merge. If complexity *reappears scattered across N callers*, it was earning its keep — leave it. "Yes, deleting it scatters complexity" is the signal that a module is genuinely deep.

**Surface signals for the hotspot list** (Phase 2b) come from `$SCRATCH/arch-measure.json`, not from hand counts — the numbers are then identical run to run: `lines`, `branches` (`if`/`switch`/ternary/early-return count), callers = `max(fan_in ?? 0, mentions)`, and `sibling_test` (a sibling test file exists). Only what is *countable without reading for quality*; nothing else. The sweep still confirms callers where `fan_in` is `null` (no import graph for the language) or the file's basename is shared, so `mentions` was keyed by its path alone.

> **Guardrail — do not audit content quality here, in any phase** — for report 1 and the `depth` output; `ASSESSMENT.md` §1 names the two exceptions of the `risk` output. Naming, comment noise, duplication, hacky constructs, giant functions, spaghetti conditions and type sloppiness are `/deep-review`'s standards, and this command neither applies them nor reports them. A hotspot row says *"this file is large, branchy and untested"* — a measurement. It never says whether the code inside is good. Blurring that line reinstates the merge these two commands were split to avoid, and buries the deepening candidates under nits.

For candidates that involve **merging a cluster of shallow modules**, classify dependencies before recommending the merge — the four categories (in-process / local-substitutable / remote-owned / true-external) each set a different testing strategy. See [`.claude/skills/architecture-review/DEEPENING.md`](../skills/architecture-review/DEEPENING.md).

Do **not** propose interfaces yet — that's Phase 3.

---

## Phase 2 — Present candidates (HTML report)

**If Phase 0 ran, reconcile the two sweeps before rendering anything.** The report is written **once**, from the merged result — do not render ours and patch Codex in afterwards.

Sort every candidate from both sweeps into one of four buckets, and **verify before you accept**: a second model is confidently wrong as often as the first, so check each of its candidates against the real code (`file:line`) and run the deletion test yourself. A candidate that fails verification is dropped, with one line saying why.

- **Both found it** — merge into one card. Note the agreement; it is the strongest signal in the report.
- **Only Codex found it, and it survives verification** — full card, marked as such. **This is the highest-value output of the whole flag** — it is the thing we missed. Say so plainly; do not soften it or bury it below our own candidates because it implicates our sweep.
- **Only we found it** — full card, marked as such. Codex's silence is not a refutation; it may simply not have looked there.
- **Disagreement** — one sweep says merge, the other says leave it (or the deletion tests came out differently). Do not average them into a mushy card. State both readings, give your verdict with the evidence, and mark the card accordingly.

Codex's `OUT-OF-LENS:` lines are **not candidates**. Feed them into the Phase 2b hotspot signals, where they are re-measured like any other area — never promoted to a card on Codex's say-so.

Render the candidates into [`.claude/skills/architecture-review/report-template.html`](../skills/architecture-review/report-template.html), replacing the `{{placeholders}}`, and **save the rendered file to** `$SCRATCH/architecture-review-YYYY-MM-DD.html` (use today's date from context); Publish moves it to `.agents/reference/`. This **overrides the save instruction in `report-template.html`'s header comment** for this command — the template stays byte-identical, and its layout and content rules still apply. Render into `$SCRATCH` only (the session scratch dir may itself live under a temp directory — that is the one allowed temp location), never into the source tree; the final home is `.agents/reference/`, reached at Publish.

Drop any Codex candidate whose files lie outside the resolved scope (one line each).

Each candidate is one card:

- **Files** — which modules/files are involved.
- **Problem** — why the current architecture causes friction, in GLOSSARY terms (shallow interface, scattered locality, leaky seam…).
- **Solution** — plain-English description of what would change (the deepening), no interface design yet.
- **Benefits** — explained as **leverage** (what callers gain) and **locality** (where change concentrates), plus how tests improve.
- **Before / After diagram** — two Mermaid graphs: "before" reads shallow/scattered (many thin nodes, caller-side complexity), "after" reads deep/local (one module, thin callers).
- **Recommendation badge** — `Strong` / `Worth exploring` / `Speculative`.

---

## Phase 2b — Hotspots (triage hand-off, same report)

The candidate cards above cover **depth**. They deliberately say nothing about the other half of "this codebase is a mess" — file size, spaghetti conditions, duplication, naming, comment noise. That half belongs to `/deep-review`, which is per-file and can apply fixes. This section is the **hand-off between the two**: it names *where* to point that command, using only the signals collected in Phase 1.

Render the hotspots into the `{{#each hotspots}}` block of the template. Each row carries:

- **Area** — the file or small file cluster.
- **Signals** — the countable facts only (e.g. `1 240 lines · 47 branches · no test file · 19 callers`). No adjectives, no verdict.
- **Why it is listed** — one clause naming which signal crossed which threshold. Never a quality judgement.
- **Command** — a copy-ready `/deep-review <paths>` invocation for that row.

**Ranking and thresholds.** Sort by a combination of the signals rather than any single one — a 1 500-line file with 3 branches and full test coverage is not a hotspot, and a 200-line file with 40 branches and no tests is. Absence of tests is the strongest multiplier, because it is the one signal that makes a `/deep-review` fix risky to apply. State the thresholds you used in the section's intro line so the reader can disagree with them.

**Cap the list at 10 rows** — beyond that it stops being a triage and becomes the flood this split exists to prevent. *Yields when* the user asked for the full inventory, or when the report is scoped to a focus argument small enough that the residue is the answer; say explicitly how many rows were withheld and give the ranking rule so the residue is reproducible.

Drop any hotspot path outside the resolved scope. Report 2's *Safety net* cap does **not** read these rows — it uses `safety_flags` from `arch-assess.mjs` (fixed thresholds, `ASSESSMENT.md` §5); for files whose `fan_in` is `null` (no graph for the language) the sweep still counts callers, as before.

**Emit no hotspot section at all** when nothing crosses the thresholds. An empty table reads as "we checked and it is fine"; the omission plus one line in the chat reply says the same thing without a table to scan.

Hotspots are **not ranked against candidates and never merge into them** — they are a different question with a different owner. A file may legitimately appear in both, and when it does, say so in the row: the deepening comes first, since it may delete the code a `/deep-review` pass would otherwise have cleaned.

---

## Phase 2c — Close the report

End the report with a **Top recommendation** section: which candidate to tackle first and why. The chat reply comes at Publish, once both reports exist.

---

## Phase A — Assess

Report 2, built from records — never from conversation. Method: [`.claude/skills/architecture-review/ASSESSMENT.md`](../skills/architecture-review/ASSESSMENT.md).

**Step 0 — freeze the auditor outcome first.** When Phase 0b ran, wait (the `codex-spawn.md` polling loop) until it is DONE-OK with a valid `check auditor`, failed after its one retry, or at `HARD_KILL`. Record the outcome — `ran`, `failed`, `late` or `absent` — and from here on use only `$SCRATCH/auditor.json`, and only when the outcome is `ran` and its `revision` equals the preflight revision (else the outcome is `failed — revision mismatch`). Nothing the auditor writes later enters the run.

1. **Normalize and merge** into `$SCRATCH/records.json` per [`records-schema.json`](../skills/architecture-review/records-schema.json): one record per finding — id, areas, one class (→ one axis), provisional tier, sources, verified by, evidence kind, report-1 candidate link. A sweep finding carries its class; a Codex finding gets one from the main session by invariant, trigger and flow. A finding both sides reported is one record with both sources (agreed) — marked **not independent** when the auditor listed an excluded path in `coverage_limits`. Report-1 candidates enter on *Change cost* (`class: "candidate"`): `Strong` → `next`, `Worth exploring` → `later`, `Speculative` not at all; a risk finding that references a candidate is the same record, counted once. Then `node .claude/lib/arch-assess.mjs check records "$SCRATCH/records.json"`.
2. **Verify** — re-read the cited lines of every provisional `now` record. Not re-checked → `verified_by: sweep-only`, which cannot stay `now`. Not confirmable → `status: dropped`, one line why.
3. **Refute** — runs whenever `codex` is on PATH and `--no-codex` was not given, whatever happened to the auditor (it tests the merged top two tiers, Claude's included); skipped only when no `status: finding` record is `now` or `next`. Write the submitted records (every `now` and `next` record whose `status` is still `finding` — a record step 2 dropped is never submitted, so no verdict can bring it back) to `$SCRATCH/refute-submitted.json`; fill [`refutation-prompt.md`](../skills/architecture-review/refutation-prompt.md) — `{{revision}}`, and `{{records}}` = those records as a JSON list of `{id, title, claim, rule, anchors, consequence, consequence_kind, change, evidence_kind}` taken from `records.json` — into `$SCRATCH/refutation.prompt.md`, and launch it like Phase 0b (`CODEX_EFFORT=high`, `SANDBOX=read-only`, no `SCHEMA`, `OUT="$SCRATCH/refutation.final.md"`, `LOG="$SCRATCH/refutation.log"`), ceilings `FIRST_CHECK 4 min · POLL_INTERVAL 3 min · HARD_KILL 25 min` — at the ceiling, no corrections pass, said in the report. Then `node .claude/lib/arch-assess.mjs check refutation "$SCRATCH/refutation.final.md" --submitted "$SCRATCH/refute-submitted.json" --out "$SCRATCH/refutation.json"` (missing results become `not-checked`, named under Not covered). Apply each verdict, **in the code first**:
   - `confirmed` → the record stays a `finding`, unchanged;
   - `refuted` → check the counter-evidence in the code — holds → `status: correction` (rendered under Corrections); does not hold → stays a `finding` with a one-line note;
   - `overstated` → check the narrower version of the `target` element — holds → that element (`claim`, `consequence` or `change`) rewritten to it, `tier` re-derived, the original kept in `correction_note`, listed under Corrections as "narrowed"; does not hold → unchanged;
   - `not-checked` → unchanged, named under Not covered.
4. **Tier** — Needed now · Before the next feature in the area · When convenient (`ASSESSMENT.md` §4).
5. **Score** — write `$SCRATCH/assessed.json` (`{areas: {<area>: {<axis>: {assessed: true} | {assessed: false, reason}}}}`) by subtracting from the required set (every area of `arch-measure.json` × `boundaries runtime change_cost safety_net`) whatever a sweep did not return, reported `not-checked`, or whose check could not run, with a reason each. Then:

   ```bash
   node .claude/lib/arch-assess.mjs score --records "$SCRATCH/records.json" --measure "$SCRATCH/arch-measure.json" --assessed "$SCRATCH/assessed.json" --out "$SCRATCH/scorecard.json"
   ```

6. **Render** [`.claude/skills/architecture-review/assessment-template.html`](../skills/architecture-review/assessment-template.html) into `$SCRATCH/architecture-assessment-YYYY-MM-DD.html`. Scores, `overall`, `scored_share` and `inconclusive` are copied from `scorecard.json`, never computed by hand; every card field (and the refutation submission) comes from `records.json`. The header names every run — the sweeps, the auditor (`ran` / `absent` / `failed` / `late`, with the reason), the refutation — and every failed sweep. Run without Codex, it says that only one lens ran. The verdict call is `keep`, `restructure` or `inconclusive` — forced to `inconclusive` when the script says so.

---

## Publish

The auditor outcome is already frozen (Phase A step 0).

1. `bash .claude/lib/tree-fingerprint.sh compare "$SCRATCH/tree.fp"` — exit 1 (the tree changed under the run) or 2 (the compare failed) → state it in report 2's header (re-render the header line); never revert anything.
2. Move both reports from `$SCRATCH` to `.agents/reference/` (`architecture-review-YYYY-MM-DD.html`, `architecture-assessment-YYYY-MM-DD.html`).
3. **Record the run** — only when the focus is empty (a whole-codebase run; `--exclude` globs allowed): `bash .claude/lib/upkeep.sh record architecture-review --only-if-home --expect-head <the Preflight revision>` — the script records only when the checkout's `HEAD` still is the reviewed revision, and stores that revision. A focused run records nothing; a moved checkout records nothing (the script's line says so). Keep the printed line; a non-zero exit is reported, never fatal.
4. **Reply in chat** — keep it short, the HTML carries the detail:
   - **Clickable markdown links** to both saved reports.
   - **One line on the upkeep record** — the line step 3 printed, or "focused run — not recorded"; after `upkeep: recorded architecture-review in <path>` it adds the next step: commit that file with the reports (unless the checkout keeps it out of git).
   - **3–5 lines** summarizing the headline finding and the top recommendation.
   - **One line on the auditor** — ran / absent / failed / late, and what it found that the sweep did not, named.
   - **One line on the second sweep**, when `--codex` ran — how many candidates each sweep found alone, and *what Codex caught that we didn't*, named. If Codex was unavailable or never produced a result, say that instead, in one line: the report rests on one sweep.
   - **One line on hotspots** — how many were listed and the single worst one, with its `/deep-review` command inline so it can be run without opening the report. Omit the line when no hotspot crossed the thresholds, and say that instead.
   - **The verdict call** of report 2 (keep / restructure / inconclusive) with the overall score and the share of lines scored.
   - A question: **which candidate would you like to drill into?**

Do not repeat the full cards in chat.

---

## Phase 3 — Grilling loop (interactive)

Once the user picks a candidate, design its interface deliberately using **Design It Twice**: see [`.claude/skills/architecture-review/INTERFACE-DESIGN.md`](../skills/architecture-review/INTERFACE-DESIGN.md). Frame the problem space, generate 2–3 radically different interface variants (in parallel via the Agent tool, the way `/design-ui` fans out variants — spawn the variants as `architecture-sweeper` with the `INTERFACE-DESIGN.md` brief), then compare them by depth / locality / seam-placement and give an **opinionated** recommendation (or a hybrid).

Walk the design tree with the user — constraints, dependency category (per [`DEEPENING.md`](../skills/architecture-review/DEEPENING.md)), the shape of the deepened module, what sits behind the seam, which tests survive.

**Side effects only happen with the user's explicit consent:**

- **Naming a deepened module after a concept that isn't in our map?** Offer to add or sharpen the term in [`.agents/memory/architecture.md`](../../.agents/memory/architecture.md) so future reviews speak the same language. Ask first.
- **User rejects a candidate with a load-bearing reason** — one a future explorer would need to avoid re-suggesting the same refactor? Offer to record it in [`.agents/memory/decisions.md`](../../.agents/memory/decisions.md), framed as: _"Want me to record this so future architecture reviews don't re-suggest it?"_ Skip ephemeral reasons ("not worth it right now") and self-evident ones. Ask first.

**Never rewrite code here.** This phase produces a chosen, interface-designed deepening — the actual implementation is handed off to `/brainstorm` → `/plan-feature` → `/execute`.

---

## Rules both reports follow

- **Every subagent this command spawns is `architecture-sweeper`** (Opus, medium) — the Phase 1 sweeps and the Phase 3 variants.
- **Independence.** No earlier `architecture-review-*` / `architecture-assessment-*` report is read before both reports of this run are rendered; the auditor gets only its template and four slots.
- **Analyze-only** stays absolute for both reports and both Codex runs (`SANDBOX=read-only`, no `SCHEMA`).
- **No re-litigation.** Settled decisions are not reopened in either report; a finding contradicting one is raised only with concrete friction and marked as such.
- **Never fabricate a Codex run** — absent, late or failed is stated, and report 2 then rests on one lens.
- **Writes.** Until both reports exist, the command writes only under `$SCRATCH` and `.agents/reference/` (and nothing of this run reaches `.agents/reference/` before Publish); Publish step 3 adds the upkeep record (`.agents/upkeep.json` of the item's home), and Phase 3 keeps its two consented memory updates.
