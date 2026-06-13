---
description: Verify implementation correctness and code quality after executing a plan
argument-hint: [plan-name]
---

# /verify-implementation — Verify Plan Execution & Code Quality

Run after `/execute` completes a plan. Validates checklist completion, runs quality gates, performs deep semantic code review, and checks design compliance. Do NOT modify code — only report findings.

> **Stack note:** The semantic review below has the most depth for **TypeScript/JavaScript** (the most common stack in projects using this starter). Sections explicitly tagged *"TypeScript/JavaScript only"*, *"Node.js only"*, or *"React only"* run conditionally based on the stack detection in Step 0. For other languages (Python/Go/Rust/etc.), the language-agnostic rules (Security, Error Handling, Performance, Best Practices) apply; per-language deep checks would need to be extended in this command.

## 0. Detect Stack

Run a cheap probe to find which manifests are present (lists only the files that exist; `ls` sends the rest to stderr, which is suppressed):

!`ls -d package.json tsconfig.json pyproject.toml Cargo.toml go.mod composer.json tailwind.config.js tailwind.config.ts tailwind.config.cjs 2>/dev/null`

Set flags from the output:

| Flag | Condition |
|------|-----------|
| `IS_NODE` | `package.json` exists |
| `IS_TS` | `tsconfig.json` exists OR `package.json` lists `typescript` in deps |
| `IS_REACT` | `package.json` lists `react` in deps |
| `IS_NEXT` | `package.json` lists `next` in deps |
| `IS_TAILWIND` | any `tailwind.config.*` exists OR `package.json` lists `tailwindcss` |
| `IS_PYTHON` | `pyproject.toml` exists |
| `IS_GO` | `go.mod` exists |
| `IS_RUST` | `Cargo.toml` exists |

Use these flags in Steps 3-5 to skip irrelevant sections. Report the detected stack in the final verdict.

## 1. Resolve Plan Context

1. If `$ARGUMENTS` looks like a plan name (e.g. `phase-3b-ui-hero-score`) → resolve the file under `.agents/plans/active/` or `.agents/plans/done/`.
2. If no argument given → use the **most recently modified** plan file in `.agents/plans/active/`.
3. If no plan found → STOP and tell the user: "No plan found. Pass a plan name or run `/execute` first."
4. Read the plan file. Extract:
   - **Checklist** (tasks with completion markers)
   - **Acceptance criteria**
   - **Design references** (Figma links, `design.md`, or `.agents/memory/domain/design.md` if the project has one)
   - **Test commands** (from Testing Strategy section)
   - **Files expected** to be created or modified

## 2. Checklist Validation

For each checklist item in the plan:
- Does the expected file exist? Use `Glob`.
- Does it contain expected content? Use `Grep`.
- Are tests mentioned in the plan present and passing?

Report:
```
Plan Compliance: X/Y tasks verified
Missing: [list if any]
```

If checklist completion < 80%, STOP and report as **BLOCK**.

## 3. Quality Gates

**Source of truth: `CLAUDE.md` → `Validation` section.** That section is filled per-project by `/setup:create-CLAUDE_MD` with the actual commands the project uses. Read it and run those commands in sequence.

If `CLAUDE.md` has no `Validation` section, or the section still contains placeholders, fall back to a stack-detected default:

| Stack flag | Fallback commands (run in order, fail fast) |
|------------|---------------------------------------------|
| `IS_TS` + `IS_NODE` | `npm run typecheck` (or `tsc --noEmit`), `npm run lint`, `npm run build`, `npm test` |
| `IS_NODE` (no TS) | `npm run lint`, `npm run build`, `npm test` |
| `IS_PYTHON` | `ruff check .`, `mypy .`, `pytest` |
| `IS_GO` | `go vet ./...`, `go build ./...`, `go test ./...` |
| `IS_RUST` | `cargo clippy`, `cargo build`, `cargo test` |
| (none detected) | Skip Quality Gates with a note; checklist + semantic review still run |

If any command fails, STOP (fail fast) and report which gate failed.

Report:
```
Quality Gates: [PASS / FAIL / SKIPPED]
Source: [CLAUDE.md Validation section / stack-detected fallback / skipped — no manifest]
Details: [which gate failed, if any]
```

## 4. Semantic Code Review

Review **only** files created or modified for this plan. Read context as needed.

Do NOT refactor or rewrite — report findings only.

### CRITICAL — Security (Block if any found, language-agnostic)

These apply to every project regardless of stack:

- `eval` / `new Function` / dynamic code execution with user input
- Unsanitized user input rendered as HTML (`innerHTML`, `dangerouslySetInnerHTML`, `document.write`, template-string interpolation in HTML)
- SQL/NoSQL injection — string concatenation in queries; must use parameterized queries / prepared statements / ORM
- Path traversal — file APIs without `path.resolve` + allowlist prefix validation
- Hardcoded secrets (API keys, tokens, passwords) — must use env vars or a secret manager
- Prototype pollution / unsafe object merging from untrusted sources (JS); equivalent in other langs (e.g. Python `pickle.loads` on untrusted data, YAML unsafe load)
- User input passed to subprocess / shell without strict allowlist validation

### HIGH — Type Safety *(TypeScript/JavaScript only — skip if `!IS_TS`)*

Block if ≥3, Warn if 1-2:

- Unjustified `any` — disables type checking. Use `unknown` and narrow, or use precise types
- Non-null assertions (`value!`) without prior guard
- `as` casts that bypass checks — fix the type instead
- `tsconfig.json` changes that weaken strictness
- Implicit `any` from missing return types on public functions

> **Other languages — generalize the principle:** every typed language has its own escape hatches from type/contract guarantees. Flag use of those without justification. Examples: Python — missing type hints on public functions, `# type: ignore`, `Any` from `typing`. Go — bare `interface{}` in public APIs, type assertions without comma-ok pattern. Rust — `unsafe` blocks without invariant comments.

### HIGH — Async Correctness *(TypeScript/JavaScript focus)*

- Unhandled promise rejections — `async` functions called without `await` or `.catch()`
- Sequential `await` inside loops for independent work — use `Promise.all`
- Floating promises in event handlers or constructors
- `array.forEach(async fn)` — does not await; use `for...of` or `Promise.all`

> **General principle for any language:** concurrent operations must be joined or awaited; errors must surface, not silently drop. Equivalents — Python: `asyncio.gather` vs naked `await` in loops; Go: goroutines without `sync.WaitGroup` / channel join; Rust: unawaited `Future`s.

### HIGH — Error Handling

**Generic (any language):**
- Swallowed errors — empty `catch` blocks (or equivalent) that log and re-raise nothing
- Parsing external input (JSON, YAML, query strings, CLI args) without handling malformed data
- Throwing primitives instead of error types — e.g. `throw "message"` (JS) or `raise "..."` (Python)

**TypeScript/JavaScript specific *(skip if `!IS_NODE` and `!IS_TS`)*:**
- `JSON.parse` without try/catch
- React: missing `<ErrorBoundary>` around async / data-fetching subtrees *(only if `IS_REACT`)*

### HIGH — Silent Failure Patterns (language-agnostic)

The most dangerous defects are not thrown exceptions — they are code that silently did nothing (or the wrong thing) while every green signal (test / lint / build) confirmed "success". Flag:

- **Two-state completion that should be three-state.** A boolean `done` / `ready` that collapses "work hasn't started" and "work finished but produced nothing" into one value. A polled/async result should expose a terminal `empty` state distinct from `ready`, and consumers must exit on **every** terminal state (including `empty`), not only on success — otherwise a poller spins forever on a legitimately-empty result. If a paid/critical operation can legally yield zero artifacts, the surface must say so explicitly.
- **Stub-beside-real.** Two similarly-named functions where one is a stub/`TODO` (`send` / `sendReal`, `process` / `processFull`) and the caller is wired to the stub → the feature silently no-ops. A green test that asserts the **stub** was called is a false signal — it encodes the bug. Before trusting a feature works, grep which implementation the caller actually imports; require a real end-to-end check for any "X happens on event Y" claim, not just a unit test.
- **Fire-and-forget on a critical path.** A side effect that **is** the business outcome (email, payment, webhook, queue enqueue) dispatched without awaiting its result and without surfacing failure (`.send().catch(log)` then return success). If the effect is the outcome, await it and propagate a non-success result; reserve fire-and-forget for genuinely best-effort work. Every form/action needs a visible error state for the failure branch — a silent success looks like a stuck button.

### HIGH — Idiomatic Patterns *(JavaScript/TypeScript only — skip if `!IS_NODE`)*

- Module-level mutable shared state — prefer immutable data and pure functions
- `var` usage — default to `const`, use `let` only for reassignment
- Callback-style async mixed with promises — standardize on async/await
- `==` instead of `===` — strict equality everywhere

### HIGH — Node.js *(only if `IS_NODE`)*

- Synchronous `fs` inside request handlers — blocks event loop
- Missing input validation on external data — use schema validation (zod, joi, ajv)
- Unvalidated `process.env` access — validate at startup with fallbacks
- Mixing `require()` and ESM without explicit intent

### MEDIUM — React / Next.js *(only if `IS_REACT`)* (Warn only)

- Missing dependency arrays in `useEffect` / `useCallback` / `useMemo`
- Direct state mutation — return new objects instead
- `key={index}` in dynamic lists — use stable unique IDs
- Derived state computed inside `useEffect` — compute during render instead
- Server-only modules imported into client components *(extra weight if `IS_NEXT`)*

### MEDIUM — Performance (Warn only)

**Generic (any language):**
- N+1 queries in loops — batch or parallelize
- Expensive computations recomputed every render/request without memoization
- Large barrel imports — prefer named imports or tree-shakeable alternatives

**React-specific *(only if `IS_REACT`)*:**
- Inline objects/arrays passed as props — cause unnecessary re-renders
- Missing `useMemo` / `React.memo` for expensive renders

### MEDIUM — Best Practices (Warn only, language-agnostic)

- `console.log` / `print` left in production code — use a structured logger
- Magic numbers / strings — use named constants or enums
- Deep optional chaining without fallback (`a?.b?.c?.d`) — add `?? fallback`
- Inconsistent naming — follow language convention (camelCase JS/TS, snake_case Python/Rust, etc.)

## 5. Design Compliance (UI plans only)

Skip this section if the plan has no design references.

- **Design tokens**: No hardcoded literal values for colors, spacing, fonts, or radii. Use the project's design system — Tailwind classes (if `IS_TAILWIND`), CSS custom properties, theme tokens, or design-system components — whatever the project standardized on.
- **Animations**: No `transition: all`. Use explicit properties with named easing curves. If the project has a documented animation language (e.g. `.agents/memory/domain/design.md`), follow it.
- **Accessibility**: ARIA labels, focus management, keyboard navigation, color contrast (WCAG AA minimum).
- **Reduced motion**: Respect `prefers-reduced-motion` for all animations.
- **Responsive**: Proper breakpoints for all layouts — Tailwind `sm:`/`md:`/`lg:` if `IS_TAILWIND`, equivalent media queries otherwise.

## 6. Plan-Specific Validation

- Does the code satisfy the plan's **acceptance criteria**?
- Are all **dependencies** declared in the plan actually imported and used?
- If the plan specified **test files** — do they exist, run, and pass?
- If the plan specified **i18n keys** — are they present in all locale files?
- If the plan required **E2E** — was it validated? Use the project's test runner, MCP Playwright via `/test-e2e` if available, or document a manual check.

## 7. Final Verdict

```markdown
## Verification Report: [plan-name]

### Detected Stack
[e.g. "TypeScript + Next.js + Tailwind" / "Python + FastAPI" / "Go" / "unknown"]

### Plan Compliance
X/Y tasks verified | Missing: [list or "none"]

### Quality Gates
Source: [CLAUDE.md Validation / stack-detected fallback / skipped]
- [Each gate command]: [✅ / ❌ / N/A]

### Semantic Review
Critical: [N] | High: [N] | Medium: [N]

[If issues found, list in table:]
| Severity | File | Line | Issue | Fix |
|----------|------|------|-------|-----|

### Design Compliance
[✅ Pass / ⚠️ Warn / N/A]

### Verdict
[✅ APPROVE / ⚠️ WARN / ❌ BLOCK]

Next steps: [ready for commit / fix listed issues / ask user]
```

**Approve**: No Critical/High issues, all gates pass, checklist ≥ 95%.
**Warn**: Only Medium issues, or checklist 80–95%. Document Medium issues in `.agents/memory/errors.md` and ask user.
**Block**: Any Critical issue, or ≥3 High issues, or any gate fails, or checklist < 80%.

## CRITICAL Rules

- **NEVER auto-fix or rewrite code** — report only.
- If quality gates fail, skip semantic review (fail fast).
- If E2E infrastructure is missing, do NOT block — note it and continue.
- Respect the project's actual toolchain as defined in `CLAUDE.md` (especially the `Validation` section) and the plan.
