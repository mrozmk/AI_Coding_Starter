---
description: Check code quality
---

# /gates:check-quality — Run project quality checks

Run the project's quality gates (format, lint, type-check, size limits) and report findings. Commands are **read from `CLAUDE.md`** — this command does not assume any specific toolchain.

## Steps to follow

### 1. Discover commands from CLAUDE.md

Read [CLAUDE.md](../../CLAUDE.md) sections `Commands` and `Code Structure & Modularity`. Extract:
- **Format command** (e.g. `ruff format`, `prettier --check`, `go fmt`, `cargo fmt`)
- **Lint command** (e.g. `ruff check`, `eslint`, `cargo clippy`)
- **Type-check command** (e.g. `mypy`, `tsc --noEmit`) — optional
- **File / function / line length limits** — default 500 / 50 / 100 unless overridden

If `CLAUDE.md` does not define these, ask the user once which toolchain to use, then offer to save the answer to `CLAUDE.md` for next time.

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
Formatting:  ✅ OK / ❌ N issues
Linting:     ✅ OK / ❌ N issues
Type check:  ✅ OK / ❌ N errors / ⚠️ skipped (not configured)
File sizes:  ✅ all within <limit> lines / ❌ [list files over limit]
```

## CRITICAL rules

- **NEVER auto-fix without user confirmation**
- If a tool is not installed or not configured in `CLAUDE.md`, report it and skip — do not fail the whole command
- Respect the project's actual line-length limit as defined in `CLAUDE.md`, not a hardcoded default
