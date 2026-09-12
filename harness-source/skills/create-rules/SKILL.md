---
name: create-rules
description: Derive a project's rules from its own code — detect the stack, layout, conventions and validation commands, confirm them with the developer, then let the rules script write them. Also regenerates the repository map in .agents/memory/architecture.md. Post-scaffold and re-runnable; it needs code to exist.
argument-hint: "[--rerun]"
wrapper-description: Derive project rules and the architecture map from the codebase
---

# create-rules — project rules from the codebase

**Input:** optional `--rerun` to re-derive facts even when the rules already look complete. Anything else is ignored.

**Prerequisite:** `prime` ran in this session and reported `harness <version> bound`. Not primed → ask the user to run `prime` and stop. Unbound → stop with the binding error; never improvise from a checkout.

**Roots and helpers:** `project_root` / `plugin_root` as defined by `prime`. Scripts: `scripts/rules.mjs` (authority, render, fill), `scripts/profile.mjs` (the profile), `scripts/bootstrap.mjs` (memory seed). Contract: `references/setup-contract.md` (profile fields and preset expansion).

<HARD-GATE>
Every byte written into a rules file goes through `scripts/rules.mjs`. This skill discovers facts and gets them confirmed; it never edits `CLAUDE.md`, `.agents/project-rules.md` or `AGENTS.md` with its own tools, and it writes nothing before the facts-review screen in Phase 4.
</HARD-GATE>

**Guardrails (absolute):** never overwrite a populated rule body — filling an *unresolved* field is not overwriting a populated one, and only the former is allowed · never shorten an existing hand-written rules file · never invent a validation command: a docs-only project has its own, and a plausible `npm test` that nobody runs is worse than an honest gap · never read `.env*`.

## Phases

### 1. DISCOVER

**Consume an existing map first.** When `.agents/memory/architecture.md` is already `status: populated`, read it and treat it as the layout answer instead of re-walking the tree. A fan-out comprehension pass may have produced it, and re-deriving it wastes the budget it was written to save.

**Project type.** The table covers the common shapes across the top backend / frontend / mobile stacks; extend it when the project matches none.

| Type | Indicators |
|---|---|
| Web app, full-stack | separate client/server dirs, API routes |
| Web app, frontend only | React/Next, Vue/Nuxt, Svelte/SvelteKit, Angular — no server code |
| API — Node | Express/Fastify/NestJS; server deps in `package.json` |
| API — Python | FastAPI/Django/Flask; `pyproject.toml` / `requirements.txt` |
| API — JVM | Spring Boot (`pom.xml` / `build.gradle`), Ktor |
| API — Go | `go.mod` with `net/http`, `gin`, `echo`, `chi` |
| API — .NET | `*.csproj`, ASP.NET Core |
| Mobile — iOS | Swift/SwiftUI, `*.xcodeproj`, `Package.swift`, `Podfile` |
| Mobile — Android | Kotlin/Compose, `build.gradle.kts`, `AndroidManifest.xml` |
| Mobile — cross-platform | React Native (`metro.config.*`), Flutter (`pubspec.yaml`), KMP (`commonMain/`) |
| Library / package | publishable manifest — `exports` in `package.json`, `[project]` in `pyproject.toml`, `Cargo.toml`, a Go module |
| CLI tool | `bin` in `package.json`, `console_scripts`, `cmd/` in Go, `Program.cs` |
| Monorepo | workspaces config — `pnpm-workspace.yaml`, `turbo.json`, Nx, Gradle multi-module, Cargo workspaces |
| ML / data pipeline | `*.ipynb`, `dvc.yaml`, `airflow/`, model artifacts |
| Script / automation | standalone scripts, minimal config |

**Configuration.** Read the root manifests for the detected stack(s): dependency and script declarations, the type-checker config, the build tool, the linter and formatter config. **Also read `lint-staged`, husky hooks and `.pre-commit-config.yaml`** — a check that only runs at pre-commit still belongs in `Validation`, because the gates run it explicitly and the hook is not their substitute.

**Layout.** Where source lives, where tests live, shared code, config locations. Depth, not breadth: two or three levels is a map, a full tree is a dump.

### 2. ANALYZE

Tech stack (runtime and version, frameworks, database, test runner, build and lint tooling). Conventions the code actually follows: file and symbol naming, in-file structure, how errors are created and handled, how types are declared, how tests are laid out. Entry points, core business logic, shared utilities, type definitions.

Record **what the code does**, not what a template would like it to do. A convention you cannot point at in two files is not a convention.

### 3. CONDENSE — before the preview, never after

The rules body is loaded into every session, so it carries a hard budget: **≤165 lines and ≤9 500 characters**. Both axes are hard; a 160-line file at 15 000 characters has not solved the problem.

Measure the values you are about to propose and condense them **while they are still proposals**. Overflow moves into `.agents/memory/architecture.md` (layout, module roles, naming) or the other memory files, with a one-line pointer left in the rules.

This ordering is not a preference. Once a value is written it is *resolved*, and neither `render` nor `fill` will shorten a resolved value without an individually approved override — so measuring after the write leaves the loop with no legal way to close. If a mandatory rule makes the budget unreachable, stop cutting and say so explicitly in the report with the final numbers: an over-budget file with every contract intact beats an on-budget file missing one, and the second failure is silent.

| Detail | Belongs in |
|---|---|
| Directory tree, file map, naming rules | `.agents/memory/architecture.md` |
| Project-specific patterns (auth flow, error wrapping, query builders) | `.agents/memory/patterns.md` |
| Architectural decisions and trade-offs | `.agents/memory/decisions.md` |
| Module-specific knowledge | `.agents/memory/domain/{module}.md` |

### 4. FACTS REVIEW — the normal stop, and the only one that happens every run

Read the profile first: `node <plugin_root>/scripts/profile.mjs read --project-root <project_root>`. Language, workflow preset and tracker come from there — **do not re-interview for them.**

Then present **one screen**: every fact you intend to write, its value, and **the file you derived it from**. Mark any missing `REQUIRED` field explicitly. Ask once for confirmation or corrections.

Nothing is written before this screen. Detected values are confirmed, never assumed — a wrong validation command discovered three sessions later costs more than one question now.

### 5. DRIFT — only when the profile and the rules disagree, and it resolves in either direction

A *resolved* rules value that differs from the profile's expansion is a contradiction, not a value to overwrite. Present it as a three-column fact — field, value in the rules, value from the profile — and ask which is right. Then:

- **profile wins** → `fill` with one `--set <field>=<value>` per accepted field. The profile is not touched.
- **file wins** → `node <plugin_root>/scripts/profile.mjs apply --project-root <project_root> --changes '<dotted keys>' --consent yes`. The rules bytes are **not** touched.

Neither direction is the default and neither is inferred. `rules.mjs fill` refuses a contradiction outright, so without this phase the operator is told "contradiction" and handed no route forward.

A partially populated workflow is the dangerous shape, not a safe one: a resolved `**Orchestrate publish:**` beside an empty branch model can yield protected branches and a pushing pipeline at once, and the contract check accepts that combination. Compare fact by fact, never "is the block populated".

### 6. WRITE — the script owns every byte

1. `node <plugin_root>/scripts/rules.mjs authority --project-root <project_root>`. `conflict` → stop, name both files, a human picks. `none` → the project has no rules yet; run `setup-start` first.
2. Write the confirmed facts to a `facts.json` under the session scratch directory.
3. **Rules file absent** → `rules.mjs render --project-root <project_root> --facts <facts.json>`; read the preview, then re-run with `--consent yes`.
4. **Rules file present with unresolved fields** → `rules.mjs fill --project-root <project_root> --facts <facts.json> [--set f=v]...`; read the diff, then re-run with `--consent yes`. `fill` is **brownfield-only**: a greenfield project's rules are generated, and it refuses with that reason rather than leaving the compatibility copy half-updated.
5. `created` is not `ready`. Report `incomplete — unresolved: …` with the field names whenever the result says so, and never call the run done with a placeholder validation command still in the file.

The script owns preset expansion, publish derivation, the mandatory headings and content lines, and the readiness verdict. Do not restate any of them here and do not re-derive them yourself — two sources of truth for a contract is worse than one in the wrong place.

### 7. architecture.md — regenerated wholesale

Write `.agents/memory/architecture.md` with frontmatter `status: populated`, `populated_by: create-rules`, and a description naming it the cross-cutting repository map. Body: **source layout** (the tree, two levels), **module roles** (a `Path | Responsibility` row per significant directory), **naming rules** (files, symbols, tests), **critical conventions** — the non-obvious rules that decide *where* new code goes.

This file is regeneratable by contract, so aim for completeness over brevity: it exists to absorb the detail the rules body cannot afford. Permanent knowledge still belongs in `decisions.md` / `patterns.md` / `domain/{module}.md`, which this skill never rewrites.

### 8. Routing rows — append, idempotently

Append project-specific rows to `.agents/memory/index.md` → `When to Read`, derived from what Phase 1 detected: a payment SDK → `domain/business-model.md`; AI SDKs → the AI module's domain file plus `decisions.md` and `api.md`; a job queue → `domain/jobs.md`; an i18n library → `domain/i18n.md`.

Match on the row's target file **before** appending — this skill is re-runnable and `bootstrap.mjs seed` is absent-only for `index.md`, so it is writing into a file it does not own. An existing row for the same target is kept, not duplicated.

### 9. Brief cascade — conditional

When `docs/PRD.md` exists **and** `.agents/memory/project-brief.md` is `status: empty` or older than the PRD, invoke `/harness:refresh-brief` (Claude Code) · `$refresh-brief` (Codex) so the brief exists before anyone reads the rules for a project overview. Brief already populated and current, or no PRD → skip with the reason stated. Do not re-distil an unchanged PRD.

## Report

Facts only. In the project language:

- **Files:** each path with `created` / `filled` / `kept` / `refused`, from the script's own result.
- **Readiness:** `ready` or `incomplete — unresolved: …` with the field names.
- **Budget:** the rules body's measured lines and characters against 165 / 9 500 — and, when a mandatory rule made the budget unreachable, that exception stated with the final numbers.
- **Project type and stack:** what was detected, one line each.
- **architecture.md:** regenerated, with its section count.
- **Routing rows:** appended / kept, per row.
- **Brief:** cascaded or skipped with the reason.
- **Warnings:** a drift left unresolved, a missing `REQUIRED` fact, a detected-but-unconfirmed value.

Stop after the report. This skill writes rules and memory; it never commits.
