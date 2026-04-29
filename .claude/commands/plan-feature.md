---
description: "Create a comprehensive implementation plan from an approved spec"
argument-hint: "[path-to-spec | optional — defaults to newest file in .agents/specs/]"
---

# Plan a new task

## Input: $ARGUMENTS

## Mission

Transform an approved design spec into a **comprehensive implementation plan** through systematic codebase analysis and — **only when the spec requires it** — external web research.

**Core Principle**: We do NOT write code in this phase. The goal is a context-rich implementation plan that enables one-pass implementation success for AI agents.

**Key Philosophy**: Context is King. The plan must contain ALL information needed for implementation — patterns, mandatory reading, validation commands, and (if needed) external documentation references — so the execution agent succeeds on the first attempt.

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
- Search for similar implementations in the codebase (the spec's "Architecture" and "Files" sections name the relevant areas).
- Document anti-patterns to avoid — use `.agents/memory/errors.md` as a starting point; past mistakes are recorded there.

**3. Dependency Analysis**
- Catalog the libraries the spec's "External dependencies" section names.
- Find existing reference docs in `.agents/reference/` and `.agents/wiki/` (if the project has a wiki from `/createwikillm`).
- Note versions and compatibility requirements visible in the manifest.

**4. Testing Patterns**
- Identify test framework and structure — e.g. jest / vitest / mocha (Node) · pytest / unittest (Python) · JUnit / Kotest (JVM) · `go test` (Go) · `cargo test` (Rust) · xUnit / NUnit (.NET) · XCTest (iOS) · Espresso / JUnit (Android) · `flutter test` (Flutter).
- Find similar test examples for reference.

**5. Integration Points**
- Identify existing files that need updates and new files to create (use the spec's "Files" section as the starting point; extend with what you discover in the codebase).
- Map router / API registration patterns, database / model patterns, auth / authorization patterns — whatever applies. Check `.agents/memory/patterns.md` and any relevant `domain/*.md` first; supplement with codebase reading only when memory is thin or silent on the integration.

**Clarify remaining ambiguities**
- If after reading the spec + codebase something is still unclear, ask the user **before** proceeding. Do not guess.

---

## Phase 2: External Research & Documentation — **CONDITIONAL**

Run this phase **only if the spec says `External docs required: yes`**. Otherwise skip it entirely and move to Phase 3.

For each entry in the spec's "External dependencies" section:

- Fetch official documentation with specific section anchors (WebFetch is the right tool here).
- Note the precise area needed — the spec already calls it out (e.g. "Stripe SDK — webhook signature verification").
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

## Phase 4: Plan Structure Generation

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

---

## Success Metrics

- **One-Pass Implementation** — execution agent can complete the feature without additional research or clarification.
- **Validation Complete** — every task has at least one working validation command.
- **Context Rich** — the plan passes the "No Prior Knowledge Test": someone unfamiliar with the codebase can implement using only the plan (plus the spec it points to).
- **Confidence Score**: #/10 that execution will succeed on the first attempt.

---

## Report

After creating the plan, provide:

- Summary of feature and approach
- Full path to the created plan file
- Whether Phase 2 (External Research) ran or was skipped, and why
- Complexity assessment
- Key implementation risks or considerations
- Estimated confidence score for one-pass success
