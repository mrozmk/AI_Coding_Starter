---
description: Create global rules (CLAUDE.md) from codebase analysis
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

## Phase 3: GENERATE

This phase produces **two files** in parallel — `CLAUDE.md` (rules) and `.agents/memory/architecture.md` (map). Splitting them is mandatory: `CLAUDE.md` is loaded into every conversation, so heavy structural detail belongs in `architecture.md` (loaded only when relevant).

### 3.1 Create `CLAUDE.md`

Use the template at `.claude/templates/CLAUDE-template.md` as a starting point.

**Output path**: `CLAUDE.md` (project root)

**Hard cap: ≤200 lines.** If a section pushes you past the cap, push detail into a memory file and leave a one-line pointer in `CLAUDE.md`.

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
- **Fill the `### Default branch` slot** inside `Git Workflow` with the workflow from Phase 1.
- **DO NOT remove or soften** these baseline sections — mandatory for every generated `CLAUDE.md`:
  - `Language Rules`
  - `Code Structure & Modularity`
  - `Error Handling`
  - `Security`
  - `Git Workflow`
  - `Project Knowledge Layers`
  - `Automatic Behaviors`
  - `Proactive Agent Usage`
  - `Plan Mode`
  - `Search Commands`

**Generate project-specific Automatic Behaviors triggers:**

The `Automatic Behaviors` block in the template contains only generic triggers (`read index.md`, `check plans/active/`, `ask when uncertain`). Based on detected directories and integrations, append project-specific routing rules to **`.agents/memory/index.md → When to Read` table**, *not* to `CLAUDE.md` itself.

Examples of project-specific triggers (write to `index.md`, derived from what you detected):
- Detected Stripe / payment SDK → "Working on payments → `domain/business-model.md`"
- Detected AI SDKs (`openai`, `anthropic`, LangChain) → "Working on AI layer → `domain/{ai-module}.md`, `decisions.md`, `api.md`"
- Detected job queues (BullMQ, Sidekiq, Celery) → "Working on background jobs → `domain/jobs.md`"
- Detected i18n libraries → "Adding new locale strings → `domain/i18n.md`"

This keeps `CLAUDE.md` slim and pushes routing logic into the file that's loaded on demand.

**Optional sections (add if relevant):**
- API endpoints (for backends) — link to OpenAPI / route file, do not duplicate
- On-demand context references — point to wiki / reference docs

### 3.2 Create `.agents/memory/architecture.md`

**Output path**: `.agents/memory/architecture.md`

This file is **regeneratable** — re-running `/create-CLAUDE_MD` overwrites it wholesale. Permanent knowledge belongs in `decisions.md` / `patterns.md` / `domain/{module}.md`, not here.

**Frontmatter:**
```yaml
---
status: populated
populated_by: /create-CLAUDE_MD
description: Cross-cutting map of the repository — directory structure, file roles, naming rules
---
```

**Body sections:**

1. **Source layout** — directory tree of `src/` (or equivalent), one or two levels deep.
2. **Module roles** — table: `Path | Responsibility`. One row per significant directory.
3. **Naming rules** — file naming, symbol naming, test file naming.
4. **Critical conventions** — non-obvious rules that affect *where* new code goes (e.g. "all Stripe webhook handlers live under `src/jobs/billing/`", "shared types in `src/types/`, never inline").

Aim for completeness over brevity — this file replaces what would otherwise bloat `CLAUDE.md`.

### 3.3 Verify Project Memory exists

Memory files ship with the starter — `index.md`, `errors.md`, `decisions.md`, `api.md`, `patterns.md`, `architecture.md`, `project-brief.md`, and `domain/business-model.md`. **Do not recreate them.** Extend `errors.md` / `decisions.md` / `api.md` / `patterns.md` as the project evolves (append-only, newest at top). `architecture.md` is regenerated by this command. `project-brief.md` and `business-model.md` are populated by `/refresh-brief` from PRD. Create new files under `.agents/memory/domain/` ad-hoc when a new module needs its own memory file (template in `.agents/memory/index.md`).

---

## Phase 4: OUTPUT

```markdown
## Global Rules Created

**File**: `CLAUDE.md`

### Project Type

{Detected project type}

### Tech Stack Summary

{Key technologies detected}

### Structure

{Brief structure overview}

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
