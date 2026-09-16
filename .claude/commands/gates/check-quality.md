---
description: Check code quality
---

# /gates:check-quality — Run project quality checks

Run the project's quality gates (format, lint, type-check, size limits) and report findings. Commands are **read from `CLAUDE.md`** — this command does not assume any specific toolchain.

## Steps to follow

### 1. Discover commands from CLAUDE.md

Read [CLAUDE.md](../../../CLAUDE.md) section `Validation` first — it is the declared source of truth for quality gates (the same one `/gates:verify-implementation` and `/orchestrate` read) — then fall back to `Commands`, plus `Code Structure & Modularity` for the size limits. Extract:
- **Format command** (e.g. `ruff format`, `prettier --check`, `go fmt`, `cargo fmt`)
- **Lint command** (e.g. `ruff check`, `eslint`, `cargo clippy`)
- **Type-check command** (e.g. `mypy`, `tsc --noEmit`) — optional
- **File / function / line length limits** — default 500 / 50 / 100 unless overridden

If `CLAUDE.md` does not define these, ask the user once which toolchain to use, then offer to save the answer to `CLAUDE.md` for next time.

**Record provenance per resolved value, not once for the step.** Discovery is field-level — `Validation` may supply lint and type-check while `Commands` supplies the format command and the size limits come from somewhere else entirely — so a single source line for the whole step would conceal a per-field fallback. Tag each value with one of: `Validation` · `Commands` · `Code Structure & Modularity` · `default <values>` · `user`. `default` is not decoration: when `Code Structure & Modularity` is absent or unfilled the 500 / 50 / 100 limits come from this command itself, and attributing them to a section that never supplied them hides exactly the drift the tag exists to reveal. Answers the user gave at the prompt above are `[src: user]`.

### 2. Format check

Run the format command in **check mode** (no writes). If it reports issues:

> "Run `<format-fix-command>` to auto-fix formatting? (yes/no)"

Never auto-fix without explicit confirmation.

### 3. Lint check

Run the lint command. If auto-fixable issues are reported:

> "Run `<lint-fix-command>` to auto-fix? (yes/no)"

### 4. Type check (optional)

Run the type-check command if configured. Report errors; do not offer to auto-fix.

### 5. File-size check

Find files exceeding the limit (default 500 lines). Use `rg` + `wc -l`, respecting the project's source directory layout (from `.agents/memory/architecture.md` — the `Source layout` / `Module roles` sections):

```bash
rg --files -g '*.{ext1,ext2}' <source-dir> | xargs wc -l | sort -rn | head -20
```

Report any file over the limit.

### 6. Function / class size heuristic

Quickly scan for likely-oversized functions or classes using a language-appropriate pattern (e.g. `^def ` / `^function ` / `^func ` / `class `). This is a heuristic — flag candidates, do not guarantee counts.

### 7. Summary report

```
Code Quality Report
===================
Formatting:  ✅ OK / ❌ N issues                          [src: Commands]
Linting:     ✅ OK / ❌ N issues                          [src: Validation]
Type check:  ✅ OK / ❌ N errors / ⚠️ skipped              [src: Validation]
File sizes:  ✅ all within <limit> lines                  [src: default 500/50/100]
```

The trailing `[src: <source>]` tag is a fixed format, not a suggestion — it names where that one value came from, so a fallback cannot pass as a project declaration.

## CRITICAL rules

- **NEVER auto-fix without user confirmation**
- If a tool is not installed or not configured in `CLAUDE.md`, report it and skip — do not fail the whole command
- Respect the project's actual line-length limit as defined in `CLAUDE.md`, not a hardcoded default
