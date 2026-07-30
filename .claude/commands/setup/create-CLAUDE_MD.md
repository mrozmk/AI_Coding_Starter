---
description: Create global rules (CLAUDE.md + architecture.md + project README) from codebase analysis
---

# Create Global Rules

Generate a CLAUDE.md file by analyzing the codebase and extracting patterns.

---

## Objective

Create project-specific global rules that give Claude context about:
- What this project is
- Technologies used
- How the code is organized
- Patterns and conventions to follow
- How to build, test, and validate

---

> **Large / brownfield codebase?** On a very large existing repo, analyzing inline here floods context. Run [`/setup:map-codebase`](map-codebase.md) first — it fans out the analysis and produces `.agents/memory/architecture.md`, then invokes this command as its final cascade step. When `architecture.md` is already `status: populated` from that run, **consume it** instead of re-walking the whole tree.

## Phase 1: DISCOVER

### Identify Project Type

First, determine what kind of project this is. The list covers common types across the top-5 backend / frontend / mobile stacks — extend it if the project doesn't match:

| Type | Indicators |
|------|------------|
| Web App (Full-stack) | Separate client/server dirs, API routes |
| Web App (Frontend) | React/Next.js, Vue/Nuxt, Svelte/SvelteKit, Angular — no server code |
| API/Backend — Node | Express/Fastify/NestJS, `package.json` with server deps |
| API/Backend — Python | FastAPI/Django/Flask, `pyproject.toml` / `requirements.txt` |
| API/Backend — JVM | Spring Boot (`pom.xml` / `build.gradle`), Ktor |
| API/Backend — Go | `go.mod` with `net/http`, `gin`, `echo`, `chi` |
| API/Backend — .NET | `*.csproj`, ASP.NET Core |
| Mobile App — iOS | Swift/SwiftUI, `*.xcodeproj` / `Package.swift` / `Podfile` |
| Mobile App — Android | Kotlin/Jetpack Compose, `build.gradle.kts`, `AndroidManifest.xml` |
| Mobile App — cross-platform | React Native (`metro.config.*`), Flutter (`pubspec.yaml`), Kotlin Multiplatform (`*.kt` under `commonMain/`) |
| Library/Package | `main`/`exports` in package.json, publishable; or `pyproject.toml` with `[project]`, `Cargo.toml`, `go.mod` as a module, NuGet package |
| CLI Tool | `bin` in package.json; `console_scripts` in `pyproject.toml`; `cmd/` in Go; `Program.cs` in .NET |
| Monorepo | Multiple packages, workspaces config (`pnpm-workspace.yaml`, `turbo.json`, Nx, Gradle multi-module, Cargo workspaces) |
| ML / Data pipeline | Notebooks (`*.ipynb`), `dvc.yaml`, `airflow/`, `pipelines/`, model artifacts |
| Script/Automation | Standalone scripts, task-focused, minimal config |

### Analyze Configuration

Look at root configuration files for the detected stack(s):

```
# Node / TS
package.json            → dependencies, scripts, type
tsconfig.json           → TypeScript settings
vite.config.* / next.config.* / nuxt.config.*  → build tool
eslint.config.* / .prettierrc                   → lint/format

# Python
pyproject.toml / poetry.lock / requirements.txt → deps, entry points
ruff.toml / mypy.ini                            → lint/type

# JVM (Java / Kotlin)
pom.xml / build.gradle / build.gradle.kts       → deps, build
settings.gradle(.kts)                           → modules
detekt.yml / .editorconfig                      → lint

# Go
go.mod / go.sum                                 → module + deps
golangci.yml                                    → lint

# Rust
Cargo.toml / Cargo.lock                         → crate + deps

# .NET
*.csproj / *.sln / Directory.Build.props        → project + deps
.editorconfig                                   → style

# Mobile — iOS
*.xcodeproj / *.xcworkspace / Package.swift / Podfile

# Mobile — Android
build.gradle(.kts) / settings.gradle(.kts) / AndroidManifest.xml

# Mobile — cross-platform
pubspec.yaml (Flutter) · metro.config.* + app.json (React Native)
```

### Map Directory Structure

Explore the codebase to understand organization:
- Where does source code live?
- Where are tests?
- Any shared code?
- Configuration locations?

### Identify Git Workflow

Ask the user which git workflow the project follows (use `AskUserQuestion` if available). The answer feeds the `Default branch` slot in the generated `CLAUDE.md` and shapes any branch-convention guidance.

**Detect a sensible default first** (do not block greenfield projects):

- If a remote exists, run `git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|^refs/remotes/origin/||'` to get the remote's default branch.
- If no remote / no origin HEAD, use the output of `git rev-parse --abbrev-ref HEAD` as a hint.
- If the repo has no commits yet, silently default to `main` (trunk-based) and skip the question.

**Then present these options to the user:**

| Option | Description | Default branch |
|--------|-------------|----------------|
| Trunk-based on `main` | All work merges to `main` via PRs. No long-lived branches. | `main` |
| Trunk-based on `master` | Same as above, legacy naming. | `master` |
| GitFlow | `main` + `develop` + feature / release / hotfix branches. | `main` (release target) |
| Feature-branch off `main` | PR-centric, no `develop`. Short-lived feature branches. | `main` |
| Other / custom | Ask the user to describe. | user-specified |

Record the chosen workflow label AND the default branch name — both are needed when filling the `Default branch` slot in `CLAUDE.md`.

**Then derive the `Orchestrate publish` slot from the same answer** — do not ask a second question, the workflow already implies it:

- **GitFlow**, or any answer describing mandatory PR review / protected branches → `branch-local`. In these repos a pipeline push to the integration branch is rejected server-side, so `/orchestrate` must commit and stop.
- **Trunk-based** / **Feature-branch off `main`** → `push`.
- **Other / custom** → ask the one follow-up: *"Can an automated pipeline push directly to `<default-branch>`, or does everything go through a PR?"* PR-only → `branch-local`.

State the derived value when you present the summary, so the user can correct a wrong inference cheaply.

### Identify Communication Language

Ask the user which language Claude should use when talking to the developer (use `AskUserQuestion` if available). This fills the `{communication-language}` placeholder in the generated `CLAUDE.md` → `Language Rules`. It governs Claude↔dev communication and the default for user-facing prompts emitted by the shipped commands — **not** code, comments, or commit messages, which stay English regardless.

| Option | Effect |
|--------|--------|
| Polish (default) | Claude responds to the developer in Polish; command prompts render in Polish. |
| English | Claude responds in English; command prompts render in English. |
| Other | Any language the team prefers — record it verbatim. |

**Default to Polish** if the user doesn't care or doesn't answer (the starter's primary audience). Record the chosen language; it substitutes every `{communication-language}` token when filling the template in Phase 3.1.

---

## Phase 2: ANALYZE

### Extract Tech Stack

From configuration files, identify:
- Runtime/Language and version
- Framework(s)
- Database (if any)
- Testing tools
- Build tools
- Linting/formatting

### Identify Patterns

Study existing code for:
- **Naming**: How are files, functions, classes named?
- **Structure**: How is code organized within files?
- **Errors**: How are errors created and handled?
- **Types**: How are types/interfaces defined?
- **Tests**: How are tests structured?

### Find Key Files

Identify files that are important to understand:
- Entry points
- Configuration
- Core business logic
- Shared utilities
- Type definitions

---

## Phase 2.5: Refresh the project brief (bootstrap only)

If `docs/PRD.md` exists **and** `.agents/memory/project-brief.md` is `status: empty` (or the PRD is newer than the brief), run **`/maintain:refresh-brief`** now to (re)generate `project-brief.md` (+ `domain/business-model.md` if the PRD has pricing). This must run **before** Phase 3 — the README and `CLAUDE.md` generated below read the brief for the project overview. This folds the brief step into bootstrap so it is not a separate manual call.

**Skip when:** `project-brief.md` is already `populated` and current (do NOT re-distill an unchanged PRD — re-running this command after *code* changes must not pointlessly regenerate the brief), or no `docs/PRD.md` exists yet. `/maintain:refresh-brief` remains a standalone `maintain/` command for later PRD-change refreshes — this step only covers the **first bootstrap**.

---

## Phase 3: GENERATE

This phase produces **three files** — `CLAUDE.md` (rules), `.agents/memory/architecture.md` (map), and the root `README.md` (project description). `CLAUDE.md` is loaded into every conversation, so heavy structural detail belongs in `architecture.md` (loaded only when relevant); the `README.md` is the human-facing front door and replaces the starter-kit's framework README at the project root.

### 3.1 Create `CLAUDE.md`

Use the template at `.claude/templates/CLAUDE-template.md` as a starting point.

**Output path**: `CLAUDE.md` (project root)

**Hard cap: ≤165 lines and ≤9 500 characters.** Both axes are hard — a 160-line file at 15 000 chars has not solved the problem. `CLAUDE.md` loads into every conversation, so its size is a tax on every session. If a section pushes you past either number, push the detail into the memory file named in the table below and leave a one-line pointer behind. **Per-section budget:** a section carries its rule plus a pointer, not the rule plus its explanation. Where an explanation is genuinely load-bearing, keep it as a one-line `>` blockquote.

**Where detail lives (NOT in `CLAUDE.md`):**

| Detail type | Goes to |
|---|---|
| Directory tree, file map, naming rules | `.agents/memory/architecture.md` |
| Project-specific patterns (auth flow, error wrapping, query builders) | `.agents/memory/patterns.md` |
| Architectural decisions and trade-offs | `.agents/memory/decisions.md` |
| Module-specific knowledge | `.agents/memory/domain/{module}.md` |

`CLAUDE.md` keeps **rules, conventions, policies, and pointers** — not maps.

**Adapt to the project:**
- Fill in project-specific sections: `Project Overview`, `Tech Stack`, `Commands`, `Architecture` (1-paragraph high-level only — full map is in `architecture.md`), `Style & Conventions` (link to linter config; do not enumerate rules), `Testing`, `Validation`, `Notes`.
- **LSP detection → `## Code Navigation` section (conditional).** If Phase 1 detected a symbol-level LSP wired into the toolchain (e.g. `typescript-language-server`, `gopls`, `rust-analyzer`, `intelephense`, `pyright` configured for this stack), add a `## Code Navigation (LSP)` section naming the available LSP tools (goToDefinition / findReferences / incomingCalls / hover) and when to prefer them over `rg`. The `nudge-lsp.sh` hook keys its CLAUDE.md pointer off the literal phrase `Code Navigation` — so a project **with** an LSP gets a live reference, and one **without** never gets a dead link. If no LSP is detected, omit the section entirely (do not stub it).
- **Fill the `### Default branch` slot** inside `Git Workflow` with the workflow from Phase 1.
- **Fill the `**Orchestrate publish:**` slot** in the same section with the value derived in Phase 1 (`push` / `branch-local`). Leave no `{push | branch-local}` placeholder in the output.
- **Substitute every `{communication-language}` token** in `Language Rules` with the language chosen in Phase 1 (default Polish). Leave no `{communication-language}` placeholder in the output.
- **DO NOT remove or soften** these baseline sections — mandatory for every generated `CLAUDE.md`:
  - `Language Rules`
  - `Validation`
  - `Commands`
  - `Code Structure & Modularity`
  - `Style & Conventions`
  - `Tech Stack`
  - `Error Handling`
  - `Security`
  - `Git Workflow`
  - `Project Knowledge Layers`
  - `Automatic Behaviors`
  - `Search Commands`

**Why those headings are mandatory — the reason, not just the list.** Their exact heading text is an **API**. Slash commands and hooks address them by name, in several syntaxes (`CLAUDE.md → Validation`, a markdown link plus the section name, a bare `` `## Git Workflow` `` literal), and one hook greps `CLAUDE.md` for a literal phrase. Renaming or deleting one of them **throws no error** — the consumer just silently stops finding what it was pointing at. `Error Handling` is retained on policy grounds rather than by a known consumer; keep it anyway. A thirteenth string is **conditional**: `Code Navigation`, emitted as `## Code Navigation (LSP)` only for LSP projects (see the LSP-detection rule above) — the contract there is the *substring*, not the full heading.

Deliberately no `file:line` list of consumers here: offsets decay within a handful of commits and this file ships to every project, read long after the lines have moved. Heading **names** are stable. Re-derive the consumers when you need them, searching **from the headings outward** (never from pointer syntaxes inward — a heading no known syntax matches is invisible, and a false positive only costs one kept line):

```bash
# For every heading CLAUDE.md has, count references to its literal text across the harness.
rg -o '^## (.+)$' -r '$1' CLAUDE.md | sort -u | while IFS= read -r h; do
  printf '%-32s refs:%s\n' "$h" \
    "$(rg -l -F --glob '!**/templates/**' --glob '!**/create-CLAUDE_MD.md' -- "$h" .claude/ .agents/ | wc -l | tr -d ' ')"
done   # --glob MUST precede --, or ripgrep reads it as a path and applies no exclusion
```

**Two lines inside `Git Workflow` are mandatory *content*, not prose to trim** — the list above is heading-only and cannot protect a line:

- the `**Orchestrate publish:**` line plus its explanatory blockquote (you derive the value in Phase 1 and fill it below). Drop it and `/orchestrate` silently falls back to `push` — so a PR-gated project that had declared `branch-local` starts pushing again after regeneration.
- the `git worktree remove --force` guard sentence — unlike the permission tiers, it is not a restatement of `settings.json`; that guard exists nowhere else.

**Generate project-specific Automatic Behaviors triggers:**

The `Automatic Behaviors` block in the template carries the generic baseline triggers. Based on detected directories and integrations, append project-specific routing rules to **`.agents/memory/index.md → When to Read` table**, *not* to `CLAUDE.md` itself.

Examples of project-specific triggers (write to `index.md`, derived from what you detected):
- Detected Stripe / payment SDK → "Working on payments → `domain/business-model.md`"
- Detected AI SDKs (`openai`, `anthropic`, LangChain) → "Working on AI layer → `domain/{ai-module}.md`, `decisions.md`, `api.md`"
- Detected job queues (BullMQ, Sidekiq, Celery) → "Working on background jobs → `domain/jobs.md`"
- Detected i18n libraries → "Adding new locale strings → `domain/i18n.md`"

This keeps `CLAUDE.md` slim and pushes routing logic into the file that's loaded on demand.

**Optional sections (add if relevant):**
- API endpoints (for backends) — link to OpenAPI / route file, do not duplicate

Do **not** add a pointer-table section (wiki links, reference-doc index) to `CLAUDE.md` — those belong in `.agents/memory/index.md → When to Read` or `.agents/reference/`. A second pointer table beside `index.md` is exactly the always-loaded bloat this cap exists to prevent.

### 3.2 Create `.agents/memory/architecture.md`

**Output path**: `.agents/memory/architecture.md`

This file is **regeneratable** — re-running `/setup:create-CLAUDE_MD` overwrites it wholesale. Permanent knowledge belongs in `decisions.md` / `patterns.md` / `domain/{module}.md`, not here.

**Frontmatter:**
```yaml
---
status: populated
populated_by: /setup:create-CLAUDE_MD
description: Cross-cutting map of the repository — directory structure, file roles, naming rules
---
```

**Body sections:**

1. **Source layout** — directory tree of `src/` (or equivalent), one or two levels deep.
2. **Module roles** — table: `Path | Responsibility`. One row per significant directory.
3. **Naming rules** — file naming, symbol naming, test file naming.
4. **Critical conventions** — non-obvious rules that affect *where* new code goes (e.g. "all Stripe webhook handlers live under `src/jobs/billing/`", "shared types in `src/types/`, never inline").

Aim for completeness over brevity — this file replaces what would otherwise bloat `CLAUDE.md`.

### 3.3 Generate the project `README.md`

The starter ships its **framework guide** as the root `README.md` (so the template repo's GitHub page documents the workflow). That guide is wrong for an actual project — bootstrap must replace it with a project README, while preserving the framework guide for reference.

**Output path**: `README.md` (project root). **Template**: `.claude/templates/README-template.md`.

**Idempotent bootstrap-vs-refresh logic** — branch on whether `.claude/README.md` already exists:

1. **Bootstrap (`.claude/README.md` does NOT exist):** this is the first run, so the root `README.md` is still the starter's framework guide.
   - Move it to preserve it: `git mv README.md .claude/README.md` (fall back to `mv` if the file is untracked). This keeps the framework guide available at `.claude/README.md` and is where `/sync-from-starter` will update it.
   - Generate a fresh root `README.md` from `.claude/templates/README-template.md`, filled with project facts: project name + description from `docs/PRD.md` / `.agents/memory/project-brief.md` (if present, else ask), the tech stack and commands from Phase 2, the top-level structure from `architecture.md`, and setup steps inferred from the detected manifest. Drop the template's own instructional header comment.

2. **Refresh (`.claude/README.md` already exists):** the project is already bootstrapped and the root `README.md` is project-owned — possibly hand-edited. **Do NOT overwrite it wholesale.**
   - If the root `README.md` still contains unfilled `{placeholder}` markers from the template, offer to fill just those (show a diff, ask first).
   - Otherwise leave it untouched and report `README.md` already customized — skipped.

Never clobber a customized project README, and never move `.claude/README.md` back to the root.

### 3.4 Bootstrap the project LICENSE (swap — mirrors the README swap)

The starter ships `LICENSE` (MIT, © the starter author) at the repo root. That license covers the **starter scaffolding**, not the cloner's project — so on first bootstrap, preserve it and give the project its own. **Branch on whether `.claude/STARTER-LICENSE` already exists:**

1. **Bootstrap (`.claude/STARTER-LICENSE` does NOT exist):** the root `LICENSE` is still the starter's.
   - Preserve it — MIT requires the copyright notice to survive in copies of the scaffolding: `git mv LICENSE .claude/STARTER-LICENSE` (fall back to `mv` if untracked). This keeps the starter's attribution in the repo and is where `/maintain:sync-from-starter` refreshes it.
   - Ask the user (use `AskUserQuestion` if available) for: **license type** (MIT / Apache-2.0 / BSD-3-Clause / proprietary / none), **copyright holder**, and **year** (default: current year). Generate a fresh root `LICENSE` from their choice — fill the standard MIT/BSD template with name+year; use the canonical Apache-2.0 text; for "proprietary" write a short "All rights reserved" notice; for "none" skip creating the file and note it.
   - Result: the root `LICENSE` is the cloner's own; the starter's MIT notice lives at `.claude/STARTER-LICENSE` (attribution preserved → MIT-compliant).
   - If the repo has **no** root `LICENSE` at all → skip the move; just offer to generate a project LICENSE from the answers above.

2. **Refresh (`.claude/STARTER-LICENSE` already exists):** already bootstrapped — the root `LICENSE` is project-owned. **Do NOT touch it.**

Never overwrite a project's existing `LICENSE` on a refresh run, and never move `.claude/STARTER-LICENSE` back to the root.

### 3.5 Verify Project Memory exists

Memory files ship with the starter — `index.md`, `errors.md`, `decisions.md`, `api.md`, `patterns.md`, `architecture.md`, `project-brief.md`, and `domain/business-model.md`. **Do not recreate them.** Extend `errors.md` / `decisions.md` / `api.md` / `patterns.md` as the project evolves (append-only, newest at top). `architecture.md` is regenerated by this command. `project-brief.md` and `business-model.md` are populated by `/maintain:refresh-brief` from PRD. Create new files under `.agents/memory/domain/` ad-hoc when a new module needs its own memory file (template in `.agents/memory/index.md`).

### 3.6 Cap gate — run this, do not assume it passed

A declared cap enforces nothing: this starter's own seed `CLAUDE.md` drifted to 239 lines while a `≤200` cap sat written down in two separate files. **Measure the file you just wrote:**

```bash
L=$(wc -l < CLAUDE.md); C=$(wc -c < CLAUDE.md)
printf 'CLAUDE.md: %s lines / %s chars (cap 165 / 9500)\n' "$L" "$C"
[ "$L" -gt 165 ]  && echo "OVER LINE CAP — move detail into a memory file and re-measure"
[ "$C" -gt 9500 ] && echo "OVER CHAR CAP — move detail into a memory file and re-measure"
```

While either branch fires, push detail out of `CLAUDE.md` into the memory file named in the *Where detail lives* table above, leave a one-line pointer, and re-run the two commands. Cut prose, never a mandatory section, a mandatory content line, or a rule. If a mandatory rule genuinely makes compliance impossible, stop cutting and **say so explicitly in the Phase 4 report** with the final numbers — an over-cap file with every rule intact beats an on-cap file missing a contract, and the second failure is silent.

---

## Phase 4: OUTPUT

```markdown
## Global Rules Created

**Files**: `CLAUDE.md`, `.agents/memory/architecture.md`, `README.md`

### Size

`CLAUDE.md`: {lines} lines / {chars} chars (cap 165 / 9 500) — {"within cap" | "over cap because <mandatory rule>"}

### Project Type

{Detected project type}

### Tech Stack Summary

{Key technologies detected}

### Structure

{Brief structure overview}

### README

{One of:
- "Bootstrap — framework guide moved to `.claude/README.md`; generated a project `README.md` from the template."
- "Refresh — filled remaining `{placeholder}` markers in the existing `README.md`."
- "Refresh — `README.md` already customized; left untouched."}

### License

{One of:
- "Bootstrap — starter MIT license preserved at `.claude/STARTER-LICENSE`; generated a fresh project `LICENSE` (<type>, © <holder> <year>)."
- "Bootstrap — no project license chosen; starter license preserved at `.claude/STARTER-LICENSE`."
- "Refresh — `LICENSE` is project-owned; left untouched."}

### Memory Verified

`.agents/memory/` ships with the starter — all five files exist (`index.md`, `errors.md`, `decisions.md`, `api.md`, `patterns.md`), plus an empty `domain/` directory for module-specific notes.

### Next Steps

1. Review the generated `CLAUDE.md`
2. Add any project-specific notes
3. Remove any **project-specific** sections that don't apply (never remove baseline sections listed in Phase 3)
4. Optionally create reference docs in `.agents/reference/`
```

---

## Tips

- Keep CLAUDE.md focused and scannable
- Don't duplicate information that's in other docs (link instead)
- Focus on patterns and conventions, not exhaustive documentation
- Update it as the project evolves
- Memory files grow automatically — you don't need to maintain them manually
