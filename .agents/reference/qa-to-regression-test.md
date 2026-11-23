# Reference: promoting a QA run to a regression test

`/qa-verify` does not write regression tests, and no command does yet —
a regression command is to be designed (#173). This is the procedure for the hand-off meanwhile:
turning the interaction sequence a QA run already executed into a permanent test.

It is **not** a slash command. It is a procedure a human asks for after a QA run.

**Why bother.** A Lane S run with interaction (browser: Playwright; non-browser app: a Tier-2
driver run — `qa-evidence-families.md` §2) already drove the app — clicked, scrolled, typed,
waited — and left the sequence behind: a browser row in its `artifacts` (the script and its
JSON for driver `script`, the `.mcp.md` step log for driver `mcp`), a non-browser Tier-2 row in
the row itself, call by call (`.claude/agents/qa-runtime-app.md.example` rule 8). That sequence
*is* a test; it just evaporates when the session ends.

**Why it is not part of `/qa-verify`.** That command carries a hard gate — *QA never mutates*.
Writing a test file is a source edit, so the verifier cannot do it without breaking the boundary
that makes its verdicts trustworthy.

---

## 1. Find the source

`.agents/handoffs/qa-<slug>-ac-matrix.md`, written by `/qa-verify` Phase 3. Several numbered
runs (`-2`, `-3`) → use the **newest** and say which.

**Stop if the matrix has no interaction rows** (browser: no row whose artifacts record an action
beyond navigation and reads; non-browser: no Tier-2 rows). An inspection-only run never acted on
the app, so there is no sequence to promote. That is a normal outcome, not a failure.

## 2. Extract the sequence — and refuse to fill gaps

Browser rows: read each row's `artifacts` first — they hold the action sequence; `methods` lists
only how a value was observed (ARIA snapshot, computed style, screenshot viewed). Non-browser
rows: read the call-by-call sequence the verifier recorded in the row and the tier stamp in
`notes`. Then `evidence` for the values to assert.

**The one rule that makes this trustworthy: never invent a step the run did not perform.** If
the row's recorded sequence (browser: its artifacts; non-browser: its recorded calls) does not
spell out a reproducible sequence — locator, action, assertion —
name the row as unusable and leave it out. A test assembled from a plausible reconstruction
asserts what the author *thinks* happened, and a green run of it proves nothing.

| Row verdict | Action |
|---|---|
| `PASS` | Promote — the assertion encodes behaviour observed to hold |
| `FAIL` | **Not by default.** Encoding a defect as expected behaviour turns a bug into a requirement. List it; a deliberately failing regression test is the user's call |
| `NEEDS-HUMAN` | Skip — nothing was settled, so there is nothing to assert |

## 3. Translate recorded calls to the project's test API

Browser lane (Playwright MCP → Playwright test):

| Recorded call | Test equivalent |
|---|---|
| `browser_navigate <url>` | `await page.goto('<url>')` |
| `browser_click` + role/name | `await page.getByRole('<role>', { name: '…' }).click()` |
| `browser_type` | `await page.getByLabel('…').fill('…')` |
| `browser_select_option` | `await page.getByLabel('…').selectOption('…')` |
| `browser_press_key` | `await page.keyboard.press('…')` |
| `browser_wait_for` text | `await expect(page.getByText('…')).toBeVisible()` |
| `browser_snapshot` assertion on a node | `await expect(locator).toHaveText / toHaveAttribute(…)` |
| `browser_resize` | `await page.setViewportSize({ width, height })` |

Non-browser app: `{fill in the driver → test-framework table for this stack — e.g. driver
`tap ByText` → `tester.tap(find.text(…))`; `waitFor` → `expect(finder, findsOneWidget)` after
settling}`. A driver call with **no** equivalent (frame-sync switches, device-level gestures) is
a hazard to report, not a step to approximate.

**Every interaction is followed by the framework's settle/wait.** The QA driver waited on a
condition; a test that acts without waiting asserts against the pre-action frame. Wait on a
condition (`expect(locator).toBeVisible()`, a response the action triggers), never a fixed sleep
(`waitForTimeout`), exactly as the QA rule says.

## 4. Write it the way this repo writes them

`{Project slot — filled by /setup:create-CLAUDE_MD or the first promotion: test directory,
file naming, fixture/bootstrap helper, how a case is registered, language of test names.}`
Match the existing tests; do not invent a house style. Rules that hold everywhere:

- **Never overwrite an existing test file.** Add a case to it or create a new one — a previous
  case may encode behaviour nobody has re-verified.
- Name the test after the criterion it encodes and cite the `ac_id` + tracker key in a comment.
- Locators in this order: role (`getByRole`) first; test id when the role is ambiguous; label
  for a form field; placeholder for an input without a label. Never CSS selectors, never XPath.
- Never assert translated copy when a stable role/label/test-id exists.

## 5. Report

State what was written, which ACs it covers, which rows were skipped and why, and every place
the translation was not one-to-one.

Then run the new test itself — with the project's test command (CLAUDE.md → Validation) when
that command runs it, else with the test runner's own CLI on the new file (e.g.
`npx playwright test <file>`) — and show output that names the new case; a run whose output does
not list the case counts as not run. Then claim the test only when that run is green.
When it cannot be run here, say plainly that it was **not run**. If the QA environment differed
from the test environment (another flavor, base URL, market, feature-flag state), say so: a
sequence that held under QA is a *hypothesis* under the test target until a run says otherwise.

Claiming a green test that was never executed is the worst possible outcome of a procedure
whose whole purpose is making evidence durable.
