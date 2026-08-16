---
description: Verify implementation correctness and code quality after executing a plan
argument-hint: [plan-name]
---

# /gates:verify-implementation — Verify Plan Execution & Code Quality

Run after `/execute` completes a plan. Validates task completion, runs quality gates, performs deep semantic code review, and checks design compliance. Do NOT modify code — only report findings.

> **Stack note:** The semantic review below has the most depth for **TypeScript/JavaScript** (the most common stack in projects using this starter). Sections explicitly tagged *"TypeScript/JavaScript only"*, *"Node.js only"*, or *"React only"* run conditionally based on the stack detection in Step 0. For other languages (Python/Go/Rust/etc.), the language-agnostic rules (Security, Error Handling, Performance, Best Practices) apply; per-language deep checks would need to be extended in this command.

## 0. Detect Stack

Run a cheap probe to find which manifests are present. It lists only the files that exist and **exits 0 by construction** — `find` returns success whether or not it matches, so an empty stack (a docs-only repo, or this starter template itself) is a valid answer rather than a non-zero exit that aborts the whole skill load. Do not rewrite this as `ls <list>`, `[ -f x ]`, or a `for` loop: each of those exits non-zero when a candidate is missing, and the trailing `|| true` that papers over it is one careless edit away from being dropped.

!`find . -maxdepth 1 -type f \( -name package.json -o -name tsconfig.json -o -name pyproject.toml -o -name Cargo.toml -o -name go.mod -o -name composer.json \)`

Set flags from the output:

| Flag | Condition |
|------|-----------|
| `IS_NODE` | `package.json` exists |
| `IS_TS` | `tsconfig.json` exists OR `package.json` lists `typescript` in deps |
| `IS_REACT` | `package.json` lists `react` in deps |
| `IS_NEXT` | `package.json` lists `next` in deps |
| `IS_PYTHON` | `pyproject.toml` exists |
| `IS_GO` | `go.mod` exists |
| `IS_RUST` | `Cargo.toml` exists |

Use these flags in Steps 3-5 to skip irrelevant sections. Report the detected stack in the final verdict.

## 1. Resolve Plan Context

1. If `$ARGUMENTS` looks like a plan name (e.g. `phase-3b-ui-hero-score`) → resolve the file under `.agents/plans/active/` or `.agents/plans/done/`.
2. If no argument given → use the **most recently modified** plan file in `.agents/plans/active/`.
3. If no plan found → **diff-only mode** (no spec to compare against). Do **not** STOP. Set `PLAN = none`, derive the scope from the working tree (`git status --porcelain` + `git diff`), skip the checklist/acceptance-criteria/spec axes (Steps 2 and the spec-dependent checks in Step 6), and run only the stack-detected quality gates and the semantic review over the changed files. Tell the user once: `No plan found — running in diff-only mode (checklist skipped; quality gates + semantic review over the working-tree diff).` This mode is what `/check-implementation` invokes when it has no plan; it must not abort here.
4. If a plan was found, read the plan file. Extract:
   - **Tasks** — `## STEP-BY-STEP TASKS`, each with its `- [ ]` marker, `EXPECT` assertions and `VALIDATE` command
   - **Acceptance criteria**
   - **Design references** (Figma links, `design.md`, or `.agents/memory/domain/design.md` if the project has one)
   - **Test commands** (from Testing Strategy section)
   - **Files expected** to be created or modified

## 2. Task Validation

**The counted list is `## STEP-BY-STEP TASKS`, not `## ACCEPTANCE CRITERIA`.** The acceptance criteria are prose assertions naming no file and no content — they are judged semantically in the review axis (Step 6), never turned into a percentage.

For each task in `## STEP-BY-STEP TASKS`:

- Verify **every** one of its `EXPECT` assertions:
  - `present` / `absent` — `Glob` the named path.
  - `contains` / `not-contains` — **fixed-string** search on the named literal (`rg -F`), never a regex and never an improvised query of your own. The assertion is what the plan declared; substituting a broader query verifies something the plan did not claim.
- Run its `VALIDATE` command. **Contract: exit 0 on success, non-zero on failure.** (The exit-zero-by-construction rule in `.agents/memory/index.md` → Probe Convention governs `!`-prefixed *skill-load* probes only — applying it here would make a failing check indistinguishable from a passing one.)
- Are tests mentioned in the plan present and passing?

**100% of tasks must pass.** One unimplemented task is a `BLOCK`, never a warning — every task in a plan is mandatory, so a partial score describes a feature that was not built.

**Malformed or legacy plans BLOCK — they do not fail open.** If `## STEP-BY-STEP TASKS` contains task headings that carry no `- [ ]` marker or no `EXPECT`, report a **contract error** and `BLOCK`. Reading a pre-contract plan as "zero tasks" would silently make this axis a no-op on exactly the plans that need it.

**`M` is the task count.** Every task is mandatory; the only exclusion is at the umbrella level, where rows whose `Status` is `manual` or `skipped` are not counted. Whenever `M` reaches zero — no tasks at all, or every umbrella row excluded — report `Plan Compliance: n/a (no mandatory tasks)` and fall through to the semantic and quality-gate axes. Never report `0%`.

**Umbrella plans aggregate.** Collect tasks from every sub-step file named in the `File` column of the umbrella's `## Execution Plan` table (links are relative to the umbrella's own directory) and report a single combined `X/Y` across all of them — **excluding rows whose `Status` is `manual` or `skipped`**, which are reported separately rather than counted. A `manual` step is by definition one the pipeline cannot verify from the filesystem (external forms, interactive logins, human judgment — `plan-feature.md` Step 4.6.2); counting it mechanically would fail every umbrella that legitimately contains one. The `n/a` path is only for plans with neither own tasks nor sub-steps.

Report:
```
Plan Compliance: X/Y tasks verified
Missing: [list if any — per task: which EXPECT or VALIDATE failed, and the path or command]
```

If any mandatory task fails, STOP and report as **BLOCK**.

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
- **SSR: server-only secrets embedded into the rendered HTML payload** (any SSR framework) — a value read on the server and serialized into the page, hydration state, or an inlined script reaches the client even though it never appears in client source. Distinct from the bullet above: the secret *is* correctly held in an env var, and still ships.
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

### MEDIUM — Comment noise (Warn only, language-agnostic)

Report narration added by this change: a comment restating the adjacent statement, echoing a variable / constant / function name, or repeating what the signature already says. Also flag a multi-line justification attached to a one-line change — that reasoning belongs in `.agents/memory/` or the spec, with a one-line pointer from the code.

**Do not flag** a comment that records a genuine *why* — a vendor quirk, a rejected alternative, a non-obvious invariant, or a workaround with a ticket reference. Those are the comments the rule exists to protect, and a warning on one trains the reader to ignore this whole section.

> Warn only, deliberately: this command is read-only. `/deep-review` standard 8 is what deletes the noise, and `guard-comments.sh` is what nudges at write time. See CLAUDE.md → Style & Conventions.

## 5. Design Compliance (UI plans only)

Skip this section if the plan has no design references.

- **Design tokens**: No hardcoded literal values for colors, spacing, fonts, or radii. Use whatever the project standardized on — read it from CLAUDE.md → Style & Conventions rather than guessing: utility classes, CSS custom properties, theme tokens, or design-system components. Judge against the convention the codebase actually uses.

  **Audit both directions.** Checking only "does the referenced token exist and match?" misses the most common real drift — writing `#1a1a1a` where a token already holds `#1a1a1a`:

  - A raw literal where a **same-value token already exists** is a defect.
  - A literal is allowed only when **no token exists** for that value, and only with a one-line justification.
  - Do not mix token references and literals for the **same property** in one component.
  - Token sourcing must stay **consistent across breakpoints**.

  > **Over-correction guard:** a genuinely token-less literal that carries its justification is **not** a defect — do not flag it. Flagging those is how a team learns to ignore this section.
- **Animations**: No `transition: all`. Use explicit properties with named easing curves. If the project has a documented animation language (e.g. `.agents/memory/domain/design.md`), follow it.
- **Accessibility**: ARIA labels, focus management, keyboard navigation, color contrast (WCAG AA minimum).
- **Reduced motion**: Respect `prefers-reduced-motion` for all animations.
- **Responsive**: Proper breakpoints for all layouts, expressed the way this project expresses them — utility-framework breakpoint prefixes, media queries, or container queries. Flag a layout that hardcodes one viewport, not the syntax it chose.

## 6. Plan-Specific Validation (Spec axis)

This is the **spec axis**: distinct from the semantic review above (which judged whether the code is *correct*), this judges whether the change implements the *right thing* — what the plan asked for, no more and no less. Correct code that builds the wrong feature still fails here. Check the diff against the plan along three independent lines, and **quote the plan/spec** for every finding:

- **(a) Missing / partial requirements** — a requirement, acceptance criterion, or task in the plan that is not implemented, or only partially. Name the unmet criterion verbatim.
- **(b) Unasked-for behavior / scope creep** — code that does something the plan did **not** ask for (extra endpoints, options, side effects, abstractions built "for later"). Unrequested scope is a risk, not a bonus — flag it so the user decides whether it belongs.
- **(c) Wrong implementation** — a requirement that *is* addressed, but in a way that contradicts the plan's intent or contract (different shape, different semantics, different edge-case behavior than the spec describes).

Then the concrete checks:

- Does the code satisfy the plan's **acceptance criteria**?
- Are all **dependencies** declared in the plan actually imported and used?
- If the plan specified **test files** — do they exist, run, and pass?
- If the plan specified **i18n keys** — are they present in all locale files?
- If the plan required **E2E** — was it validated? Use the project's test runner, MCP Playwright via `/test-e2e` if available, or document a manual check.

If there is no plan (diff-only mode), skip (a)-(c) — there is no spec to compare against — and run only the concrete checks that apply.

## 7. Final Verdict

```markdown
## Verification Report: [plan-name]

### Detected Stack
[e.g. "TypeScript + Next.js + Tailwind" / "Python + FastAPI" / "Go" / "unknown"]

### Plan Compliance
X/Y tasks verified | Missing: [list or "none"]
[or, when M is zero:] n/a (no mandatory tasks)

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

> **Diff-only mode (`PLAN = none`):** there is no plan, so report `Plan Compliance: N/A` and **drop every task clause below** — the verdict is decided by quality gates + semantic-review severity **only**. Read each rule as if its task clause were absent (e.g. Approve = no Critical/High issues and all gates pass; Warn = only Medium issues; Block = any Critical/High issue, or any gate fails).

The two axes are decided separately. **Task axis** (`## STEP-BY-STEP TASKS`, §2): any mandatory task failing → `Block`; all passing, or `n/a`, → no objection from this axis — there is no warn band here, because a task is either done or it is not. **Semantic axis** (acceptance criteria + review issues): the Medium-only warn band lives here, where a finding is a matter of judgement.

**Approve**: No Critical/High issues, all gates pass, all mandatory tasks pass or `n/a` *(task clause N/A in diff-only)*.
**Warn**: Only Medium issues, with the task axis clean *(task clause N/A in diff-only)*. **Report** the Medium issues in the verdict and stop there — this gate is read-only (see CRITICAL Rules). Recording them in `.agents/memory/errors.md` and any user decision belong to the caller (`/check-implementation`'s memory-reflection / escalation steps), not to the judge.
**Block**: Any Critical issue, or **any High issue**, or any gate fails, or **any mandatory task fails**, or a plan-contract error *(task clause N/A in diff-only)*. (Any High blocks — this closes the 1–2 High gap so every gates-pass outcome maps to exactly one of `APPROVE`/`WARN`/`BLOCK`, which the caller requires; it also aligns with Approve's "no Critical/High". The earlier "≥3 High" threshold left 1–2 High with no verdict once the task clause is N/A.)

## CRITICAL Rules

- **NEVER auto-fix or rewrite code** — report only.
- If quality gates fail, skip semantic review (fail fast).
- If E2E infrastructure is missing, do NOT block — note it and continue.
- Respect the project's actual toolchain as defined in `CLAUDE.md` (especially the `Validation` section) and the plan.
