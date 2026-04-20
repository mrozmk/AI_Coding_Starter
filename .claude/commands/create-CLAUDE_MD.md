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

### Create CLAUDE.md

Use the template at `.claude/templates/CLAUDE-template.md` as a starting point.

**Output path**: `CLAUDE.md` (project root)

**Adapt to the project:**
- Fill in the **project-specific sections**: `Project Overview`, `Tech Stack`, `Commands`, `Project Structure`, `Architecture`, `Style & Conventions`, `Code Patterns`, `Testing`, `Validation`, `Key Files`, `Notes`.
- **Fill the `### Default branch` slot** inside the `Git Workflow` section with the workflow identified in Phase 1 (e.g. `` `main` (trunk-based) ``, `` `master` (GitFlow; release branch) ``). The three commands `/push` `/pull` `/release` detect the current branch dynamically — this slot is documentation of the project's convention, not runtime config.
- **DO NOT remove or soften** the shared baseline sections — they are mandatory for every project generated from this starter kit:
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
- Add project-specific subsections inside those baseline sections only if they extend (not replace) the defaults.
- Keep it concise — focus on what's useful, but never drop the baseline.

**Key sections to include:**

1. **Project Overview** — What is this and what does it do?
2. **Tech Stack** — What technologies are used?
3. **Commands** — How to dev, build, test, lint?
4. **Structure** — How is the code organized?
5. **Patterns** — What conventions should be followed?
6. **Key Files** — What files are important to know?
7. **Project Memory** — Always included, points to `.agents/memory/`

**Optional sections (add if relevant):**
- Architecture (for complex apps)
- API endpoints (for backends)
- Component patterns (for frontends)
- Database patterns (if using a DB)
- On-demand context references

### Initialize Project Memory

Memory files are provided by the starter under `.agents/memory/` — they exist already (`index.md`, `errors.md`, `decisions.md`, `api.md`, `patterns.md`). **Do not recreate them.** Extend the existing files as the project evolves. Create files under `.agents/memory/domain/` ad-hoc when a new module needs its own memory file (template in `.agents/memory/index.md`).

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
