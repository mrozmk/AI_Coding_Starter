# Testing

> Placed by `/setup:start` step 8. `{slots}` it could not resolve from the manifest stay literal; `/setup:create-CLAUDE_MD` fills them later. Everything below the slots is binding as written.

## Stack

| | |
|---|---|
| Test runner | `{test-runner}` |
| Test command | `{test-command}` |
| Coverage tool | `{coverage-tool}` |

## File layout

{Where tests live and how they are named — co-located `*.test.*` / `*.spec.*` next to the unit, or a `tests/` tree mirroring `src/`. One rule, applied everywhere.}

## What to test

- Public API of every module — everything the entry point exports.
- Domain logic: pricing, validation, transformations, rules with branches.
- Sensitive paths named in `CLAUDE.md → Validation` — always, with external SDKs and the database mocked.
- Edge cases that break in practice: empty collections, missing optional inputs, boundary numbers, locale formatting.

## What NOT to test

- Trivial getters/setters and pass-through adapters.
- Pure types and interfaces — the compiler already checks them; a "type test" adds churn, not coverage.
- Tests that only assert a mock was called without exercising real logic.
- Snapshots of large trees — snapshot small, stable units only.

---

## Rules for AI assistants

Binding for every AI assistant working in this repository (Claude Code, Copilot, agents). They exist because each one was broken at least once.

1. **Run the affected tests (`{test-command}`) before reporting a task as done.** "I did not change tests" is not evidence — coverage thresholds and snapshots fail from upstream changes.
2. **A failing test is fixed, never skipped or disabled** (`skip`, `only`, `xit`, commented out) without an explicit instruction from the user in this session.
3. **A new public runtime export ships with a test in the same change.** Pure types are exempt; a function, class or component is not. An export without a test is incomplete work.
4. **Deleted code deletes its test.** No dead test files referencing removed symbols.
5. **Never edit coverage configuration or thresholds to make a run pass.** The threshold is a floor, not a target; raising coverage is done with tests.
6. **Never update a snapshot without reading the diff.** An accepted snapshot is a claim that the new output is correct.
7. **Use the exact project/target name in every command, one test command per Bash call.** A runner given a wrong name can run zero tests and exit 0.
8. **Report the runner's counts** (passed / failed / skipped), never a bare exit code.
9. **Sensitive paths per `CLAUDE.md → Validation` MUST have tests** — a change there without one is a gate failure, not a nice-to-have.
10. **A test-only change still runs the full affected set.** A test that passes alone and fails in the suite is the common shape of a shared-fixture bug.
