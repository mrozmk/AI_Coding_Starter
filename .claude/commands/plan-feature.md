---
description: "Create a comprehensive implementation plan from an approved spec, then grill it (mandatory) — surface critical gaps with self-critique loop, apply user-accepted fixes in-place"
argument-hint: "[path-to-spec | optional — defaults to newest file in .agents/specs/]"
---

# Plan a new task (with built-in grilling)

## Input: $ARGUMENTS

## Mission

Transform an approved design spec into a **comprehensive, grilled, size-bounded implementation plan** through:

1. Codebase analysis (Phase 1)
2. External research if needed (Phase 2)
3. Strategic thinking (Phase 3)
4. Initial plan draft (Phase 4)
5. **Size budget check + auto-split if over hard cap** (Phase 4.5 — MANDATORY)
6. **Execution Plan section emission for umbrella plans** (Phase 4.6 — MANDATORY if multi-step)
7. **Critical self-audit with one self-critique loop** (Phase 5 — MANDATORY)
8. **User-approved fix application in-place + post-fix size re-check** (Phase 6 — MANDATORY)

**Core Principle**: We do NOT write code in this phase. The goal is a context-rich implementation plan that enables one-pass implementation success for AI agents.

**Key Philosophy**: Context is King. The plan must contain ALL information needed for implementation — patterns, mandatory reading, validation commands, and (if needed) external documentation references — so the execution agent succeeds on the first attempt.

**Grilling Philosophy**: Planning is cheap, broken implementation is expensive. The grilling phase costs ~30% more tokens at plan-time and saves 10× that in failed implementation runs. Find REAL gaps that will stop the execution agent (running on the project's default execution model) from succeeding ad-litteram. Do NOT search for hypothetical issues — keep only findings backed by repo evidence, memory entries, errors.md cases, or domain patterns. Aggressive self-critique drops ≥20% of raw findings.

---

## Phase 0: Locate and Load the Spec

1. Resolve the spec file:
   - If `$ARGUMENTS` looks like a path to an existing `.md` file under `.agents/specs/` → use it.
   - Otherwise → pick the **newest** file in `.agents/specs/` by modification time. If that directory is empty, STOP and tell the user: "No approved spec found. Run `/brainstorm <feature idea>` first."
2. Read the spec **in full**. Extract:
   - Feature name, summary, problem, solution
   - Architecture, files, edge cases
   - **`External docs required`** field (`yes` / `no`)
   - **`External dependencies`** section (list of libs / APIs / services, if any)
3. If the spec is missing the `External docs required` field, STOP and tell the user: "Spec does not declare `External docs required`. Update the spec via `/brainstorm` or add the field manually, then rerun `/plan-feature`."

> The spec is the single source of truth for **what** to build and **why**. This command's job is to decide **how**.

---

## Phase 1: Codebase Intelligence Gathering

Treat the spec as given — do not re-litigate the design. Your job here is to fill in implementation context.

> **Loader Convention — leverage primed context.** This phase assumes `/prime` has already loaded `.agents/memory/architecture.md` (directory map, module roles), `.agents/memory/patterns.md` (project-specific patterns), `.agents/memory/decisions.md`, and any populated `domain/*.md`. Do **not** re-walk the directory tree or re-derive conventions that memory already documents — focus on filling gaps unique to this feature. If context isn't primed (no recent `/prime` in conversation), pause and ask the user to run `/prime` first. See [.agents/memory/index.md → Loader Convention](../../.agents/memory/index.md).

**1. Project Structure Analysis**

- Confirm directory structure and architectural patterns from `.agents/memory/architecture.md`. Only re-walk the tree if `architecture.md` has `status: empty` or commits since its last regeneration suggest it's stale.
- Detect primary language(s), frameworks, and runtime versions if not already documented in `architecture.md` or `CLAUDE.md → Tech Stack`.
- Locate stack-specific config files only when the spec's needs require it: `package.json` / `tsconfig.json` (Node/TS) · `pyproject.toml` / `requirements.txt` (Python) · `pom.xml` / `build.gradle(.kts)` (JVM) · `go.mod` (Go) · `Cargo.toml` (Rust) · `*.csproj` / `*.sln` (.NET) · `Package.swift` / `Podfile` / `*.xcodeproj` (iOS) · `AndroidManifest.xml` / `build.gradle.kts` (Android) · `pubspec.yaml` (Flutter) · `metro.config.*` (React Native).

**2. Pattern Recognition**

- Pull conventions (naming, file organization, error handling, logging) from `.agents/memory/patterns.md` and `CLAUDE.md → Style & Conventions`. Only inspect the codebase directly if those are silent on the area you need.
- Search for similar implementations in the codebase (the spec's "Architecture" and "Files" sections name the relevant areas). **If the project exposes an LSP**, prefer `workspaceSymbol` to locate analogous services/classes and `documentSymbol` to read a pattern file's structure without loading the whole file (see CLAUDE.md → Code Navigation, if present).
- Document anti-patterns to avoid — use `.agents/memory/errors.md` as a starting point; past mistakes are recorded there.

**3. Dependency Analysis**

- Catalog the libraries the spec's "External dependencies" section names.
- Find existing reference docs in `.agents/reference/` and `.agents/wiki/` (if the project has a wiki from `/setup:createwikillm`).
- Note versions and compatibility requirements visible in the manifest.

**4. Testing Patterns**

- Identify test framework and structure — e.g. jest / vitest / mocha (Node) · pytest / unittest (Python) · JUnit / Kotest (JVM) · `go test` (Go) · `cargo test` (Rust) · xUnit / NUnit (.NET) · XCTest (iOS) · Espresso / JUnit (Android) · `flutter test` (Flutter).
- Find similar test examples for reference.

**5. Integration Points**

- Identify existing files that need updates and new files to create (use the spec's "Files" section as the starting point; extend with what you discover in the codebase).
- Map router / API registration patterns, database / model patterns, auth / authorization patterns — whatever applies. Check `.agents/memory/patterns.md` and any relevant `domain/*.md` first; supplement with codebase reading only when memory is thin or silent on the integration. **If the project exposes an LSP**, use `goToDefinition` + `incomingCalls` on an existing registration/integration point to read its real contract and who depends on it, instead of inferring from grep.

**Clarify remaining ambiguities**

- If after reading the spec + codebase something is still unclear, ask the user **before** proceeding. Do not guess.

---

## Phase 2: External Research & Documentation — **CONDITIONAL**

Run this phase **only if the spec says `External docs required: yes`**. Otherwise skip it entirely and move to Phase 3.

For each entry in the spec's "External dependencies" section:

- **For package-managed libraries** (npm / pip / Maven / Cargo / etc.) — if Context7 MCP is available, use it: call `resolve-library-id` to find the library, then `get-library-docs` with a focused query (e.g. "webhook signature verification"). This returns current, version-aware documentation. Otherwise fall back to fetching official docs with WebFetch.
- **For non-package resources** (hosted APIs, proprietary services, internal docs) — use WebFetch with specific section anchors.
- Note the precise area needed — the spec already calls it out (e.g. "payments SDK — webhook signature verification").
- Capture: current stable version, breaking-change notices, known gotchas, minimal working example.
- If there is no existing reference file for a dependency, consider proposing one in `.agents/reference/{dep-name}.md` after the plan is approved (don't write it yet).

**Compile research references** into the plan under `## Relevant Documentation`:

```markdown
## Relevant Documentation

- [Library Official Docs](https://example.com/docs#section)
  - Specific feature implementation guide
  - Why: Needed for X functionality
```

If `External docs required: no` — the plan must **omit** the "Relevant Documentation" section entirely.

---

## Phase 3: Strategic Thinking

Before generating the plan, think hard about:

- How does this feature fit into the existing architecture? (Spec answered this at a high level — you refine with concrete file paths and line numbers.)
- Critical dependencies and order of operations.
- Edge cases, race conditions, error modes.
- Performance and security implications.
- Maintainability and extensibility.

Spec may leave some of these open — resolve them here.

---

## Phase 4: Plan Structure Generation — Initial Draft

This produces the **first draft** of the plan. The plan is NOT final until Phase 4.5 (size budget) + Phase 5 (grilling) + Phase 6 (apply fixes) complete. Do not show the plan path to the user yet — they'll see it after Phase 6.

**Size budgeting awareness while drafting (read before writing):**

Plans MUST fit within the effective attention window of the execution model. Even models with a large nominal context (e.g. 200K) have practical attention that degrades above ~50K input tokens. The executor must hold: plan + spec + memory files + CLAUDE.md + grep results + file contents being edited. That leaves ~30K tokens of safe headroom for the plan itself.

**Per-file size budget** (enforced in Phase 4.5):

| File type                                                          | Soft target (LOC) | Hard cap (LOC) | Soft (chars) | Hard (chars) | Why                                                                            |
| ----------------------------------------------------------------- | ----------------- | -------------- | ------------ | ------------ | ------------------------------------------------------------------------------ |
| **Umbrella / parent** (decisions + risk register + step map)      | 250               | 350            | 10 000       | 14 000       | Loaded by every sub-step as context — must stay lightweight                    |
| **Sub-step (implementation)**                                     | 400               | 600            | 16 000       | 24 000       | Code snippets + tasks + DoD. High density but still readable in one pass       |
| **Post-launch / monitoring step** (runbooks, alerts)              | 350               | 500            | 14 000       | 20 000       | Low density (mostly prose + procedure), does not need to be larger             |

While drafting, target the **soft cap**. Hard cap is the trigger for Phase 4.5 auto-split. Plans above hard cap will be split — don't fight it, just write them naturally and let Phase 4.5 do the work.

**Create the plan with the following structure.** Sections marked `⟂ conditional` appear only when relevant.

```markdown
# Feature: <feature-name>

The following plan should be complete, but it's important that you validate codebase patterns and task sanity before you start implementing. Pay special attention to naming of existing utils, types, and models. Import from the right files.

**Source spec:** `.agents/specs/<spec-file>.md`
**External docs required:** yes | no

## Feature Description

<Derived from spec's Summary + Problem/Solution — expand with implementation-level detail>

## User Story

As a <type of user>
I want to <action/goal>
So that <benefit/value>

## Problem Statement

<From spec's Problem — keep tight>

## Solution Statement

<From spec's Solution — refined with concrete implementation approach>

## Feature Metadata

**Feature Type**: [New Capability/Enhancement/Refactor/Bug Fix]
**Estimated Complexity**: [Low/Medium/High]
**Primary Systems Affected**: [List of main components/services]
**Dependencies**: [External libraries or services required — matches spec's External dependencies]

---

## CONTEXT REFERENCES

### Relevant Codebase Files — IMPORTANT: READ BEFORE IMPLEMENTING

<List files with line numbers and relevance. Use the project's real extensions (.ts/.py/.java/.kt/.go/.rs/.cs/.swift/.dart — whatever this codebase uses).>

> **Get line numbers from a source of truth, not guesswork.** If the project exposes an LSP, use `documentSymbol` (exact start–end range of the symbol) or `goToDefinition` so the `(lines X-Y)` you cite are facts, not stale grep hits. If a symbol you intend to cite does not resolve, it does not exist — fix the reference before the plan ships.

- `path/to/file.{ext}` (lines 15-45) — Why: Contains pattern for X that we'll mirror
- `path/to/model.{ext}` (lines 100-120) — Why: Data model / persistence structure to follow
- `path/to/test.{ext}` — Why: Test pattern example

### New Files to Create

- `path/to/new_service.{ext}` — Service implementation for X functionality
- `path/to/new_model.{ext}` — Data model for Y resource
- `path/to/new_service.test.{ext}` (or project-specific test location) — Unit tests for new service

### Relevant Documentation ⟂ conditional — include only if External docs required: yes

- [Documentation Link 1](https://example.com/doc1#section)
  - Specific section: {section name}
  - Why: {what it unblocks in the plan}

### Patterns to Follow

<Specific patterns extracted from the codebase — include actual code snippets from the project>

**Naming Conventions:**

**Error Handling:**

**Logging Pattern:**

**Other Relevant Patterns:**

---

## IMPLEMENTATION PLAN

### Phase 1: Foundation

<Foundational work needed before main implementation — schemas, types, interfaces, dependency wiring>

### Phase 2: Core Implementation

<Main implementation — business logic, services, endpoints, data models>

### Phase 3: Integration

<How the feature integrates with existing functionality — routers, handlers, config, middleware>

### Phase 4: Testing & Validation ⟂ conditional — include only if tests are warranted for project size (see Testing Strategy)

<Unit / integration tests, edge-case coverage, acceptance validation>

---

## STEP-BY-STEP TASKS

IMPORTANT: Execute every task in order, top to bottom. Each task is atomic and independently testable.

### Task Format Guidelines

Use information-dense keywords for clarity:

- **CREATE**: New files or components
- **UPDATE**: Modify existing files
- **ADD**: Insert new functionality into existing code
- **REMOVE**: Delete deprecated code
- **REFACTOR**: Restructure without changing behavior
- **MIRROR**: Copy pattern from elsewhere in codebase

### {ACTION} {target_file}

- **IMPLEMENT**: {Specific implementation detail}
- **PATTERN**: {Reference to existing pattern — file:line}
- **IMPORTS**: {Required imports and dependencies}
- **GOTCHA**: {Known issues or constraints to avoid}
- **VALIDATE**: `{executable validation command}`

<Continue with all tasks in dependency order…>

---

## TESTING STRATEGY

<Adapt testing scope to project size — assessed during Phase 1.>

**Very small projects (single script / prototype / <5 files):**

- Tests are optional. If skipped, document why and list manual validation steps instead.
- If any tests are written, cover only core/critical functions.

**Small projects (few modules, no CI):**

- Unit tests for core business logic only — skip boilerplate and trivial getters/setters.
- At least one happy-path integration test for the main workflow.

**Medium/larger projects (multiple services, has CI):**

- Unit tests per component with edge cases.
- Integration tests for key workflows.
- Coverage target: 70%+ (adjust if the project has its own standard in `CLAUDE.md`).

### Core Functions to Test (if applicable)

### Edge Cases (if applicable)

---

## VALIDATION COMMANDS

Execute every applicable command to ensure zero regressions and feature correctness.

### Level 1: Syntax & Style

<Project-specific linting and formatting commands>

### Level 2: Tests

<Project-specific test commands — skip if tests were deemed unnecessary above>

### Level 3: Manual Validation

<Feature-specific manual testing steps — API calls, UI testing, etc. Always required regardless of project size>

---

## ACCEPTANCE CRITERIA

- [ ] Feature implements all specified functionality
- [ ] All validation commands pass with zero errors
- [ ] Code follows project conventions and patterns
- [ ] No regressions in existing functionality
- [ ] Tests written where appropriate for project size
- [ ] Security considerations addressed (if applicable)

---

## COMPLETION CHECKLIST

- [ ] All tasks completed in order
- [ ] Each task validation passed immediately
- [ ] All validation commands executed successfully
- [ ] Manual testing confirms feature works
- [ ] Acceptance criteria all met

---

## NOTES

<Additional context, design decisions, trade-offs — kept minimal; the spec carries the "why", the plan carries the "how".>
```

---

---

## Phase 4.5: Size Budget Check + Auto-Split

**Mandatory. Always runs after Phase 4. Before Phase 5.**

After the Phase 4 draft, measure the size of every plan file created (umbrella + sub-steps if they already exist). Goal: guarantee that no file exceeds the hard cap before grilling starts — because a huge plan means a huge grilling pass, a huge Phase 6 edit, and a poor loop.

### Step 4.5.1 — Measure

For each plan file created/modified in Phase 4, measure:

```bash
for f in <created plan files>; do
  lines=$(wc -l < "$f")
  chars=$(wc -c < "$f")
  echo "$f: $lines LOC / $chars chars"
done
```

### Step 4.5.2 — Classify

Per file, classify the type (umbrella / sub-step / monitoring) from its name + content:

- name has a `-N-` or `-Na-` pattern + references an umbrella → **sub-step**
- name is a root (e.g. `feature-launch.md`) + contains "step map" / "decisions" / "risk register" → **umbrella**
- name has `monitoring` / `post-launch` / `hardening` / `runbook` → **monitoring**
- other (single-file plan without a split) → **sub-step** budget (the most common case)

### Step 4.5.3 — Decide action per file

From the budget in Phase 4:

| State                          | Action                                                                                                   |
| ------------------------------ | -------------------------------------------------------------------------------------------------------- |
| ≤ soft target                  | ✅ OK, nothing                                                                                           |
| > soft target BUT ≤ hard cap   | ⚠️ Log warning ("X is 480 LOC, target 400 — acceptable but Phase 5 will scrutinize density"), nothing more |
| > hard cap                     | 🔴 **Auto-split (Step 4.5.4)** — without asking the user                                                  |

### Step 4.5.4 — Auto-split strategy

Per file type:

**Sub-step over hard cap (e.g. a 675 LOC implementation step):**

1. Read the file, identify natural split boundaries in the **already-existing `##` sections**. Preferred boundaries (in order):
   - **Functional** — distinct responsibilities (e.g. "API endpoints" vs "webhook handler" vs "Tests") → `Xa-endpoints`, `Xb-webhook`, `Xc-tests`
   - **Dependency-based** — A blocks B (e.g. "DB migration" before "Endpoints that use it")
   - **Surface-based** — backend vs frontend vs ops
2. Create new files `<plan>-Xa-<descriptor>.md`, `<plan>-Xb-<descriptor>.md` etc. using the natural name from the section.
3. Each new file gets: a standard sub-step header (Parent / Status / Complexity / Blocker / Pre-read / Design refs / Tasks / DoD / Commit).
4. **Update the umbrella** (if it exists):
   - The step map gets new entries `Xa/Xb/Xc` instead of `X`.
   - The dependency graph reflects the new order.
   - The complexity-per-step table is updated.
5. **Update cross-references** in all other plan files that referenced the old `X` — e.g. "Blocker: Step X done" → "Blocker: Step Xa+Xb done".
6. Delete the old `<plan>-X.md`.
7. **Re-measure** the split files — if any sub-step STILL exceeds the hard cap, split recursively (max 2 levels: `Xa` → `Xa1/Xa2/Xa3`; beyond that STOP and flag to the user "spec too broad for this stage, consider /brainstorm").

**Umbrella over hard cap:**

Rare but possible (an umbrella with over-detailed decisions). Strategy:

1. Extract "Strategic decisions" into a separate `<plan>-decisions.md` if > 80 LOC.
2. Extract the "Risk register" into a separate `<plan>-risks.md` if > 60 LOC.
3. The umbrella keeps: goal, step map, DoD, links to the extracted files.

**Monitoring step over hard cap:**

Very rare. Strategy:

1. Move runbooks into `docs/runbooks/*.md` (linked from the plan) — a runbook is an operational doc, not part of the implementation plan.
2. The plan keeps: monitoring setup tasks + alert config + chaos test, without the runbook content.

### Step 4.5.5 — Report split summary

After auto-split, report a short summary to the user (before Phase 5):

```
## 📏 Size budget check

Files measured: <N>
Within target: <K> files
Above target (acceptable): <L> files
**Auto-split (over hard cap): <M> files**

Splits applied:
  <old-file>.md (<X> LOC) → <new-fileA>.md (<Ya> LOC) + <new-fileB>.md (<Yb> LOC) + <new-fileC>.md (<Yc> LOC)
  Split rationale: <functional|dependency|surface>

Files within budget — proceeding to grilling...
```

---

## Phase 4.6: Execution Plan Section (Umbrella Only)

**Mandatory if Phase 4.5 produced an umbrella + sub-steps (or the plan started as a multi-step umbrella). Skip if a single atomic plan.**

The orchestrator (`/orchestrate`) reads the umbrella plan to determine step order, dependencies, and progress. This phase emits the canonical machine-readable section it parses.

### Step 4.6.1 — Detect umbrella

The plan is an umbrella if **any** of:

- More than 1 sub-step file exists (post-split or pre-existing)
- The plan title / structure references "step map" / "Steps" / a dependency graph
- The plan filename matches `<feature>.md` while sub-files match `<feature>-{N|Na|Nb}-*.md`

A single atomic plan (no umbrella) → skip this entire phase.

### Step 4.6.2 — Emit `## Execution Plan` section

Insert this section into the umbrella file, **immediately after the "## Step map" / "## Strategic decisions" sections and before "## Definition of Done"** (or an analogous position — near the top, before the risk register).

**Canonical format** (the orchestrator parses by header match + table column names):

```markdown
## Execution Plan

> **For orchestrator.** Single source of truth for step order, dependencies, and progress. Statuses updated in-place by `/orchestrate` (or manually). Valid statuses: `pending` | `in_progress` | `done` | `blocked` | `skipped` | `manual`.

| Step | File                                                     | Depends On | Status  | Model  |
| ---- | -------------------------------------------------------- | ---------- | ------- | ------ |
| 1    | [<plan>-1-<descriptor>.md](./<plan>-1-<descriptor>.md)   | —          | pending | sonnet |
| 2    | [<plan>-2-<descriptor>.md](./<plan>-2-<descriptor>.md)   | 1          | pending | opus   |
| 3a   | [<plan>-3a-<descriptor>.md](./<plan>-3a-<descriptor>.md) | 2          | pending | opus   |
| 3b   | [<plan>-3b-<descriptor>.md](./<plan>-3b-<descriptor>.md) | 3a         | pending | sonnet |
| ...  | ...                                                      | ...        | pending | ...    |
```

**Rules for the table:**

- **Step**: identifier matching the sub-file infix (`1`, `2`, `3a`, `3b1`, `3b2`...). Used as the DAG node id.
- **File**: relative markdown link to the sub-step file. The filename must exist in the same directory.
- **Depends On**: comma-separated list of Step ids that must reach `done` before this step starts. Use `—` (em dash) for no dependencies.
- **Status**: all automatable entries start as `pending`. The orchestrator (or user) flips them to `in_progress`, `done`, `blocked`, `skipped`. Use **`manual`** (set by YOU at plan time) for any step that is NOT automatable — external form submissions, interactive logins, screenshot capture, anything needing human judgment. The orchestrator pauses (does not spawn) when it reaches a `manual` step and tells the user to do it by hand, then `--resume`.
- **Model**: which model the orchestrator spawns the executor with for that step — `sonnet` | `opus` | `haiku` (or `—` / omit to use the executor default). Derive this from the per-stage model recommendation (see "Model Recommendation" section of this report): mechanical 1:1-from-pattern steps → `sonnet`; multi-module coordination, copy-sensitive UI, pattern-level decisions, concurrency/state reasoning → `opus`; trivial mechanical steps → `haiku`. Only the model is selectable per-step — `effort`/`fast` are not per-spawn-overridable, so do not try to encode them here.

**Dependency rules:**

- Every dependency must reference a Step id that exists in the same table.
- No circular dependencies (the orchestrator detects + fails fast).
- Multiple steps can depend on the same predecessor (fan-out).
- Multiple predecessors per step are allowed (fan-in).

### Step 4.6.3 — Preserve human-readable supplements

The ASCII DAG diagram and complexity table (if any) stay in the file as **supplements**, clearly marked as informational. Example:

```markdown
### Visual DAG (human-readable supplement, not parsed)

\`\`\`
Step 1 ──┐
Step 2 ──┴──► Step 3a ──► Step 3b ──► ...
\`\`\`

### Step complexity (informational, not for orchestrator)

| Step | Complexity |
| ---- | ---------- |
| 1    | easy       |
| 2    | complex    |
| ...  | ...        |
```

**Do not** keep a duplicate dependency table elsewhere — `## Execution Plan` is the single source of truth. Complexity, blocker prose, and rationale notes are fine as separate sections.

### Step 4.6.4 — Sub-step file frontmatter (optional but recommended)

Each sub-step file MAY carry a frontmatter line indicating its status, mirroring the umbrella table:

```markdown
**Status:** pending
```

The orchestrator does NOT rely on this — the umbrella table is authoritative. But keeping it in sync helps when reading sub-steps in isolation. If included, update both places when status changes.

### Step 4.6.5 — Report

After emitting the section, log briefly:

```
## 🗺  Execution Plan section emitted

File: .agents/plans/active/<umbrella>.md
Steps registered: <N>
DAG validated: ✅ no cycles, all dependencies resolvable
Ready for /orchestrate.
```

If validation fails (cycle detected, dangling dependency id) → STOP, report to the user, ask to fix manually before proceeding.

---

## Phase 5: Grilling — Critical Self-Audit of the Draft

**Mandatory phase. Always runs after Phase 4. Never skipped.**

After Phase 4 the plan exists in `active/`, but it is **not final**. This phase detects gaps, contradictions, and under-specifications before the user or `/execute` relies on it.

**Core principle:** we look for HOLES that will realistically stop the execution agent (the project's default execution model is the reference point — because that is the model the plan must succeed on per the Model Recommendation section). We do NOT manufacture holes. Better to return 3 real findings than 15 hypothetical ones.

### Step 5.1 — Load grilling context

Re-use the context loaded in Phase 1 (codebase) + Phase 2 (external docs if any) + add:

- `.agents/memory/index.md` + every memory file relevant to the plan (e.g. plan touches payments → the relevant `domain/*.md` payments/business-model file; plan touches auth/middleware → `patterns.md` + `errors.md`; plan touches a specific subsystem → that subsystem's `domain/*.md`).
- Any project auto-memory the harness exposes, plus any files the spec/description suggest are relevant.
- `CLAUDE.md` (global + project) — especially the "Automatic Behaviors" sections and any automatic file reads.

**Do not load everything defensively.** Choose based on the plan's domain. If the plan is UI-only → design-system memory yes, deploy/ops memory no.

### Step 5.1b — UI structural-contract gate (MANDATORY if the plan has `Design references:`)

**Trigger:** the plan (or any of its sub-steps) names a reference design file (e.g. a `Design references:` / `Design source:` line pointing at `.agents/specs/design/Ready/*.html`). Backend-only plans skip this gate entirely.

This gate exists because the most expensive failures in `/orchestrate` runs are UI steps where the plan said _"build X per Design.html"_ but did not enumerate the structural contract — so the executor satisfied the plan's prose while diverging from the design DOM, and the designer gate then returned dozens of gaps. Pointing at a design file is NOT a contract. Force the contract into the plan NOW, at plan-time, where it is cheap.

For each UI sub-step, open the referenced design HTML and verify the plan enumerates **all** of:

1. **Section inventory + order** — the list of top-level sections/blocks in the exact order the design renders them (e.g. hero → problem-strip → feature-matrix → pricing → … ). A plan that says "build the landing page" without this list fails the gate.
2. **Per-variant / per-state matrix** — every variant, card state, empty/error/loading state the design shows. (e.g. "Card: 4 variants × 5 states"; "pricing: 4 tiers + bridge".) Missing variants are where the executor silently ships fewer than the design has.
3. **Exact copy strings** — headline, CTA labels, subjects, microcopy that the design specifies verbatim. If the plan paraphrases or omits them, the executor will invent copy and the designer will flag it.
4. **Semantic/structural requirements** — native `<details>` vs button accordion, framework `<Link>` vs `<a>`, i18n namespace vs inline strings, icon set (which icon per element). These are the deltas that read as "structural gaps" in the designer report.

For any of the four that the plan does not pin down → raise a 🟠 MAJOR finding: _"UI step <X> points at <Design.html> but does not enumerate <section inventory | variant matrix | copy strings | semantic contract>; the executor will diverge and burn a mega-fix iteration. FIX: add the explicit contract to the sub-step."_

### Step 5.1c — Latent product-decision sweep (MANDATORY for any plan that ships customer-facing surface)

The other expensive failure class is product decisions that the plan **defers** rather than resolves — they stay latent until implementation collides with the design, then surface as designer/verifier BLOCKERS mid-pipeline. Sweep the plan for decisions in these classes and confirm each is either **resolved in the plan** or **explicitly marked `DEFER — requires rendered output to decide`**:

- **Commercial terms** — pricing numbers, refund window (e.g. 14 vs 30 days), trial length, currency per locale. These must match across plan, copy, emails, terms.
- **Tier/feature visibility** — which tiers appear on which surface; is a tier hidden, bridged, or fully shown.
- **Copy positioning** — product-name-first vs problem-first headline; brand voice. A divergence here rewrites many i18n keys.
- **Semantic choices with UX/SEO impact** — accordion semantics, multi-currency rendering, locale defaults, redirect locale preservation.

For each unresolved decision → raise a 🟠 MAJOR finding naming the decision and where it will explode if left latent. The point is to force these into an `AskUserQuestion` at **plan-time** (cheap, one round) instead of mid-`/orchestrate` (expensive, halts the pipeline).

> These two gates target a recurring root cause: it is not that the planning model is too weak — backend plans from the same model pass clean. It is that grilling did not press UI plans for a structural contract and did not force latent product decisions. These gates close that gap without needing a stronger model.

### Step 5.2 — Raw critique pass (4 categories)

Read the plan(s) end-to-end. Generate findings split into 4 severities:

**🔴 CRITICAL** — without the fix the feature **WILL NOT WORK** or will crash on boot/deploy:

- Internal contradictions between steps (one says X, another implements not-X).
- Missing env vars in a required-config check → runtime crash in production.
- Plan assumes an existing file/function/endpoint that does not exist.
- Race conditions / idempotency holes in hot paths (webhook handlers, license activation, payment flow).
- Plan breaks a load-bearing memory rule (e.g. a framework-version-specific gotcha recorded in `errors.md`/`patterns.md`).
- Plan assumes permissions / secrets that are not present in env / CI / the deploy environment.

**🟠 MAJOR** — the feature works, but edge-case paths break:

- A file in the "above target but acceptable" zone (Phase 4.5 report) BUT with low density — the signature of "filler" instead of real content. Catch it and recommend consolidation.
- Plan describes code files that will exceed the project's code-size cap (this is CODE, not the plan — Phase 4.5 covers plans; here it's the predicted size of generated code).
- Customer-facing copy contradicts UX logic (e.g. email says "one-time", dashboard implements multi-time).
- No refund / cancel / failure path where revenue is involved.
- Plan assumes an external object (customer / subscription / payment intent) exists without the setup that creates it.
- Plan assumes a background job is scheduled, but uses a non-existent cron interval / queue name.

**🟡 MEDIUM** — test omissions + edge cases that surface in production:

- No idempotency test for webhook handlers.
- No race-condition test for a counter / limit.
- No i18n parity check across locales.
- No failure mode in the UI when the backend returns 500 with a specific error code.
- No post-launch monitoring/alerting for a new surface.

**🟢 MINOR** — small bugs, style, optimizations:

- Regex / sed bugs (e.g. `^\* Version:` instead of `^\s*\*\s*Version:`).
- Hardcoded values that should be env-driven.
- No fallback messages for rare error codes.
- Missing comment / clarification (rarely worth reporting).

**Format for each finding** (must fit on 5 lines):

```
[#NN] {SEVERITY EMOJI} {1-line title}
WHERE: <file:section or task ID, e.g. feature-launch-3b.md task 3b.4>
PROBLEM: <what specifically is wrong, 1-2 sentences>
CONSEQUENCE: <what breaks when the execution agent does this ad litteram>
FIX: <the concrete one-time change to the plan, 1-2 sentences>
```

### Step 5.3 — Self-critique pass (1 loop, mandatory)

For **EVERY** finding from Step 5.2, ask yourself three questions:

1. **"Will it realistically stop the execution agent on this step?"** — The execution model is competent. If the problem is so obvious that the model would notice + fix it in-pass → drop the finding. If the problem requires knowledge outside the plan/spec/CLAUDE.md → keep it.
2. **"Am I manufacturing a hole?"** — Is my critique backed by real evidence (a memory entry, an `errors.md` case, a file in the repo, a credible domain pattern), or by "it might happen"? If the latter → drop the finding.
3. **"Is the SEVERITY honest?"** — Is 🔴 actually a crash/blocker, or just an inconvenience? Is 🟠 actually an edge case that will surface, or a hypothesis? Demote/promote if the scale doesn't fit.

**After each finding, write the self-critique result EXPLICITLY:**

```
[#NN] SELF-CHECK:
- Stops the execution agent? [YES why / NO why]
- Manufactured hole? [NO evidence: <link/cite> / YES → drop]
- Severity OK? [OK / DEMOTE to <X> / PROMOTE to <Y> because <reason>]
DECISION: KEEP | DROP | DEMOTE | PROMOTE
```

**Drop at least 20% of findings.** If you keep everything, it means either the plan is genuinely perfect (rare), or you are not self-critiquing honestly. Real grounds for dropping: "this is already covered by CLAUDE.md auto-behavior X" / "the model has this in training, see prior work" / "this is a hypothesis, no incident or memory backs it".

### Step 5.4 — Present findings to user, ask for fix scope

Show the user a summary of the findings that survived self-check, grouped by severity. **Format inline in the terminal**, short:

```
## 🔍 Grilling result: <N> findings post-self-check

🔴 CRITICAL (k_count):
  [#01] {title}
  [#02] {title}

🟠 MAJOR (p_count):
  [#03] {title}
  ...

🟡 MEDIUM (s_count):
  [#NN] {title}
  ...

🟢 MINOR (d_count):
  [#NN] {title}
  ...
```

**Then the mandatory question via AskUserQuestion**, asked in the project's communication language (CLAUDE.md → Language Rules):

> "Which findings should be applied to the plan?"
>
> - **All** (recommended if the reds/oranges are real)
> - **Only 🔴 + 🟠** (frugal — skip the minor ones)
> - **Only 🔴** (minimum viable, plan stays "acceptable but not perfect")
> - **Selectively** — list the finding numbers to apply, ignore the rest
> - **None** — plan stays as is, the user disagrees with the critique

The user chooses. Without a choice — STOP, plan stays in Phase 4 draft state, report to the user.

### Step 5.5 — (Optional, only if findings density is high)

If after self-check there are **>15 findings** or **>5 🔴** — the plan is genuinely not ready. Propose to the user, in the project's communication language (CLAUDE.md → Language Rules):

> "The plan has <N> findings (including <K> critical). Consider one of:
>
> - Apply the fixes (Phase 6) BUT the plan will change a lot — it may be worth reviewing after Phase 6 and deciding whether to return to `/brainstorm`.
> - Return to `/brainstorm` with the findings as input to redesign the spec.
> - Force the fixes and trust that the plan holds together."

The user decides, default = the first option.

---

## Phase 6: Apply Accepted Fixes

Apply ALL findings the user accepted in Step 5.4. For each finding:

1. **Edit in-place** in the plan file (Edit tool). Do NOT create `<plan>.grilling.md` — the user wants ONE plan as the single source of truth.
2. **If a fix requires a new step** (e.g. post-launch monitoring) — create it, add it to the parent map / dependency graph.
3. **Update memory** if grilling uncovered load-bearing knowledge missing from memory (e.g. a project-specific gotcha). Save it to `.agents/memory/patterns.md` or the relevant `domain/*.md` under the appropriate category. Do not save the finding as memory — save the RULE / LESSON that will prevent a similar finding on the next `/plan-feature`.

### Step 6.1 — Post-fix size re-check (mirror Phase 4.5)

After applying all fixes, **re-measure every plan file** (fixes may have grown a step over the hard cap). If any file is now > hard cap:

- Run the auto-split logic from Phase 4.5.4 on that file (the split logic per type).
- Update the report for the user about post-fix splits.

This prevents the situation: the plan was 580 LOC (acceptable), grilling added 2 fixes = 720 LOC (over cap), and the user receives a final plan that is already too big. Better to split now than to improvise in `/execute`.

**After applying all fixes:** a short diff summary to the user:

```
## ✅ Applied <N> fixes

Modified files:
- <plan>.md (umbrella decisions + risk register)
- <plan>-3b.md (NEW endpoint + idempotency check)
- <plan>-5.md (integration boundary corrected)

New files:
- <plan>-3c.md (split out of the monolithic step 3)
- <plan>-8.md (post-launch hardening)

Removed:
- <plan>-3.md (monolith, split into 3a/3b/3c)

Memory updated:
- .agents/memory/patterns.md (new section X)
```

---

## Output Format

**Filename**: `.agents/plans/active/{kebab-case-descriptive-name}.md`

- Replace `{kebab-case-descriptive-name}` with a short, descriptive feature name (usually derived from the spec's filename, minus the date prefix).
- Examples: `add-user-authentication.md`, `implement-search-api.md`, `refactor-database-layer.md`

**Directory**: Create `.agents/plans/active/` if it doesn't exist. After `/execute` completes the plan, it is moved to `.agents/plans/done/` — never write a plan directly into `done/`.

---

## Quality Criteria

### Context Completeness ✓

- [ ] All necessary patterns identified and documented
- [ ] External library usage documented with links — **only if `External docs required: yes`**
- [ ] Integration points clearly mapped
- [ ] Gotchas and anti-patterns captured
- [ ] Every task has an executable validation command

### Implementation Ready ✓

- [ ] Another developer could execute without additional context
- [ ] Tasks ordered by dependency (can execute top-to-bottom)
- [ ] Each task is atomic and independently testable
- [ ] Pattern references include specific `file:line` numbers

### Pattern Consistency ✓

- [ ] Tasks follow existing codebase conventions
- [ ] No reinvention of existing patterns or utils
- [ ] Testing scope matches project size

### Information Density ✓

- [ ] No generic references (all specific and actionable)
- [ ] Task descriptions use codebase keywords
- [ ] Validation commands are non-interactive and executable
- [ ] URLs include section anchors (when `External docs required: yes`)

### Size Within Budget ✓

- [ ] Every plan file ≤ hard cap (Phase 4.5 thresholds — 600 LOC sub-step / 350 LOC umbrella / 500 LOC monitoring)
- [ ] If above soft target, density justifies it (no filler / repetition)
- [ ] Phase 4.5 split report exists in conversation log (proof check ran)
- [ ] Post-fix re-check (Step 6.1) shows all files within budget after grilling applied

### Execution Plan ✓ (umbrella only)

- [ ] Umbrella plan has `## Execution Plan` section with canonical table format
- [ ] Every sub-step file is registered in the table
- [ ] Every `Depends On` references an existing Step id (no dangling refs)
- [ ] No circular dependencies
- [ ] All initial statuses are `pending`
- [ ] Visual DAG and complexity table (if kept) are marked as informational supplements

---

## Success Metrics

- **One-Pass Implementation** — execution agent can complete the feature without additional research or clarification.
- **Validation Complete** — every task has at least one working validation command.
- **Context Rich** — the plan passes the "No Prior Knowledge Test": someone unfamiliar with the codebase can implement using only the plan (plus the spec it points to).
- **Grilled** — Phase 5 + 6 completed. Plan reflects user-accepted findings. Pre-grilling drift defended against.
- **Confidence Score (post-grilling)**: #/10 that execution will succeed on the first attempt.

---

## Report

After Phase 6 completes (plan finalized post-grilling), provide:

- Summary of feature and approach
- Full path to the created plan file(s) — include sub-steps if the plan got split during Phase 6
- Whether Phase 2 (External Research) ran or was skipped, and why
- **Grilling summary** — N findings raised, M kept after self-check, K accepted by the user, fixes applied. If the user rejected all → note that the plan is "draft, ungrilled" and confidence is lower.
- Complexity assessment
- Key implementation risks or considerations (post-grilling — should be minimal if the user accepted critical fixes)
- Estimated confidence score for one-pass success (POST-grilling — typically +1.5 to +2.5 vs pre-grilling)
- **Model recommendation for execution** (see below) — last section of the report

---

## Model Recommendation (mandatory final section of the report)

End the report with **one** explicit recommendation, picking exactly one of three tiers. This is the last thing the user sees in the terminal — make it actionable, not hedged. Use the model names the project configures for its execution and orchestration agents (the orchestrator spawns executors with a `sonnet` | `opus` | `haiku` model class; map your recommendation to whichever the project sets as default and escalation models).

**Tiers:**

- **Fast tier (no thinking)** — fast, cheap, enough for mechanical migrations, small refactors, text edits, new components mirrored 1:1 from existing ones. Choose by default when the plan has `file:line` references, concrete keys to reuse, and no copy-language or critical logic.
- **High tier** — required when coordinating multiple modules in one pass, copy must read naturally in multiple languages, "pick a pattern from three options" decisions inside a stage, a refactor touching >5 files, or a plan with looser guidance than `file:line`.
- **High tier + thinking** — a _silent_ error has a real production cost (payments, auth, data migrations, mass rename across >10 files), ICU plurals with complex plural forms, locale-aware logic, reasoning about concurrent state, correctness criteria hard to verify with an automated test. Use sparingly.

**Output format (last section of the report, literally this shape):**

```
## 🎯 Recommended model for execution

**{choice}** — {1-2 sentences of rationale, referencing the real characteristics of THIS plan, not generically}

{If the plan is staged — a per-stage table with the model and a 1-sentence why.}

{If a sensible optimization exists (e.g. split stage X into two sessions, add one sentence to the executor prompt), list it in 1-2 bullets.}
```

**Selection rules (apply in order):**

1. Default to the **fast tier (no thinking)** — most tasks deserve it, the plan exists so a cheaper model can succeed.
2. Escalate to the **high tier** when the plan has ≥3 areas to coordinate at once, copy that needs linguistic feel (multi-locale tone, brand voice), or pattern-level decisions inside a stage.
3. Escalate to the **high tier + thinking** _only_ when: a silent error costs money/data/trust, the plan contains ICU plurals or locale-aware numbers/dates, or it requires reasoning about concurrency/state-machine logic.
4. A staged plan with varied complexity → different models per stage. Don't pretend all stages are equal — that misinforms the user.
5. Don't hedge. **One recommendation** per task (or per stage in a staged plan). If a task tolerates more than one tier — pick the cheaper one.
6. Don't use words like "consider", "it's worth", "maybe". Write: "Fast tier (no thinking) — because X and Y."
