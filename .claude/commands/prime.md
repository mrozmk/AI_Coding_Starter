---
description: Prime agent with codebase understanding
---

# Prime: Load Project Context

## Objective

Build comprehensive understanding of the codebase by analyzing structure, documentation, and key files.

## Process

### 1. Analyze Project Structure

List all tracked files:
!`git ls-files`

Show directory structure (portable — works without `tree`):
!`find . -maxdepth 3 -not -path '*/node_modules/*' -not -path '*/__pycache__/*' -not -path '*/.git/*' -not -path '*/dist/*' -not -path '*/build/*' -not -path '*/venv/*' -not -path '*/.venv/*' -not -path '*/target/*' -not -path '*/.gradle/*' -not -path '*/DerivedData/*' -not -path '*/bin/*' -not -path '*/obj/*' | sort | head -100`

### 2. Read Core Documentation

Read in this order — stop reading a category if the file doesn't exist:

- `CLAUDE.md` — global rules and conventions
- `docs/PRD.md` — product requirements (or any PRD/spec file in `docs/`)
- `README.md` — project root readme
- Any other README files in major subdirectories

### 3. Load Project Memory

- Read `.agents/memory/index.md` — always
- If the task involves a specific module, read the relevant `.agents/memory/domain/{module}.md`
- Note whether memory is empty or contains existing lessons — mention this in the output report

### 4. Load Agent Context

If the following exist, read them:
- `.agents/reference/` — any reference documents
- `.agents/plans/` — list available plans (don't read all, just list filenames)

### 5. Identify Key Files

Based on the directory structure, identify and read:
- Main entry points (e.g. `index.*`, `main.*`, `app.*`, `server.*`, `cli.*`)
- Core configuration files (e.g. `package.json`, `tsconfig.json`, `*.config.*`, `*.toml`, `*.yaml`)
- Key schema or model definitions
- Important service, controller, or core logic files

Use judgment — read the most important 3-5 files, not everything.

### 6. Understand Current State

Check recent activity:
!`git log -10 --oneline`

Check current branch and status:
!`git status`

---

## Output Report

Provide a concise summary covering:

### Project Overview
- Purpose and type of application
- Primary technologies and frameworks
- Current version/state

### Architecture
- Overall structure and organization
- Key architectural patterns identified
- Important directories and their purposes

### Tech Stack
- Languages and versions
- Frameworks and major libraries
- Build tools and package managers
- Testing frameworks

### Core Principles
- Code style and conventions observed
- Documentation standards
- Testing approach

### Current State
- Active branch
- Recent changes or development focus
- Any immediate observations or concerns

### Memory Status
- Is `.agents/memory/` populated or empty?
- If populated: list the most critical items from `index.md` Quick Reference
- If empty: note that memory will be built as work progresses

### Available Plans
- List any files found in `.agents/plans/` (filenames only)

**Make this summary easy to scan — use bullet points and clear headers.**
