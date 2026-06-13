---
description: Execute an implementation plan
argument-hint: [path-to-plan]
---

# Execute: Implement from Plan

## Plan to Execute

### Phase 0: Resolve the plan file

1. If `$ARGUMENTS` looks like a path to an existing `.md` file under `.agents/plans/active/` → use it as the plan path.
2. Otherwise → pick the **newest** file in `.agents/plans/active/` by modification time. If that directory is empty or does not exist, STOP and tell the user: "No active plan found. Run `/plan-feature <spec>` first, or pass an explicit path."
3. Use the resolved path as the plan to execute in every step below.

Read the resolved plan file.

## Execution Instructions

### 1. Read and Understand

- Read the ENTIRE plan carefully
- Understand all tasks and their dependencies
- Note the validation commands to run
- Review the testing strategy

### 2. Execute Tasks in Order

For EACH task in "Step by Step Tasks":

#### a. Navigate to the task
- Identify the file and action required
- Read existing related files if modifying
- **If the project exposes an LSP, navigate by symbol** instead of greping/reading whole files: `documentSymbol` to map the target file, `goToDefinition` to jump to a type/util the plan references, `workspaceSymbol` to find the canonical export to import. See CLAUDE.md → Code Navigation (if present).
- **Before a REFACTOR/REMOVE/rename task**: run `findReferences` / `incomingCalls` on the symbol first — confirm every caller, so nothing is left dangling (grep misses some and matches comments).

#### b. Implement the task
- Follow the detailed specifications exactly
- Maintain consistency with existing code patterns
- Include proper type hints and documentation
- Add structured logging where appropriate
- When a task calls an external library/framework API, verify current behavior against up-to-date docs (e.g. Context7 `resolve-library-id` → `get-library-docs`) rather than relying on training data — API surfaces drift between versions.

#### c. Verify as you go
- After each file change, check syntax
- Ensure imports are correct — if an LSP is available, `hover` on the imported symbol confirms it resolves and matches the expected signature
- Verify types are properly defined

### 2.5 Validate User-Facing Flows (when the plan requires E2E)

If the plan's checklist includes a browser-validation item (e.g. "E2E flow tested in the browser" or similar), validate the running app, not just the code:

1. **If the project has an E2E-generation command** (e.g. a `/test-e2e [flow-name]` command), run it to generate browser tests via MCP exploration. It typically needs the dev server running in the background.
   - Use the flow name from the plan. If unsure, validate the full set.
   - If no such command exists, fall back to step 2.

2. **Fallback via an MCP browser driver** (e.g. Playwright MCP) — drive the app directly for manual validation:
   - navigate to the entry-point URL
   - snapshot the accessibility tree and interactive elements
   - capture a screenshot as validation evidence
   - check console messages for JS errors
   - Save the screenshot path in your output report.

3. **If E2E infrastructure is missing** (no browser-test runner installed, no `tests/e2e/` directory):
   - Mark the checklist item completed with a NOTE: "E2E validated manually via MCP; dedicated test suite pending runner setup."
   - Do NOT block plan completion on missing test infrastructure — the checklist item refers to validation, not test-code generation.

### 3. Implement Testing Strategy

After completing implementation tasks:

- Create all test files specified in the plan
- Implement all test cases mentioned
- Follow the testing approach outlined
- Ensure tests cover edge cases

### 4. Run Validation Commands

Execute ALL validation commands from the plan in order:

```bash
# Run each command exactly as specified in plan
```

If any command fails:
- Fix the issue
- Re-run the command
- Continue only when it passes

### 5. Final Verification

Before completing:

- ✅ All tasks from plan completed
- ✅ All tests created and passing
- ✅ All validation commands pass
- ✅ Code follows project conventions
- ✅ Documentation added/updated as needed

### 6. Move Plan to Done

After all validations pass, move the plan file from `active/` to `done/`:

```bash
mv .agents/plans/active/<plan-file>.md .agents/plans/done/<plan-file>.md
```

This marks the feature as fully implemented.

### 7. Memory reflection

**Guard first — skip this step if you will run `/check-implementation` or `/orchestrate` next.** Those reflect with the same protocol and richer context, so reflecting here too would risk a duplicate entry. Run this step **only** when `/execute` is your final action before `/commit` (raw execute → commit, no quality loop).

If it applies, run the **Memory Reflection Protocol** in [.agents/memory/index.md](../../.agents/memory/index.md) over what you just implemented. Apply its bar strictly — **the default is to save nothing**; a plan that executed cleanly rarely teaches a fresh Claude anything. Save only a non-obvious bug root-cause you hit (`errors.md`), an undocumented quirk that bit you (`api.md`), or a deliberate fix-direction decision (`decisions.md`). Append at most one entry, newest-first, and **do not duplicate** anything already in the target file. This does not commit — the memory write is left in the tree for your `/commit`.

## Output Report

Provide summary:

### Completed Tasks
- List of all tasks completed
- Files created (with paths)
- Files modified (with paths)

### Tests Added
- Test files created
- Test cases implemented
- Test results

### Validation Results
```bash
# Output from each validation command
```

### Ready for Commit
- Confirm all changes are complete
- Confirm all validations pass
- Memory: <appended 1 entry to <file> / nothing worth remembering / skipped — running /check-implementation or /orchestrate next>
- Ready for `/commit` command

## Notes

- If you encounter issues not addressed in the plan, document them
- If you need to deviate from the plan, explain why
- If tests fail, fix implementation until they pass
- Don't skip validation steps
