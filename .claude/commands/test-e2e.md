---
description: "Write E2E tests for a user flow using MCP Playwright browser automation"
argument-hint: "[flow-name | jira-key (e.g. CS-1) | empty for plan-driven]"
---

# Test E2E: Explore → Plan → Generate

## Input: $ARGUMENTS

<HARD-GATE>
Do NOT write any test code until you have explored the UI with MCP Playwright, produced a test plan, and the user has explicitly approved it. This applies even if the flow seems obvious from the code.
</HARD-GATE>

---

## Step 0: Load Project Context

Before exploring or testing, gather project-specific context from existing artifacts. Do NOT hardcode any values — read them from the project.

### 0.1 Detect input mode from `$ARGUMENTS`

| Pattern | Mode | What to do |
|---------|------|------------|
| empty / `all` | **plan-driven** | Read the latest plan in `.agents/plans/active/` → extract its `Testing Strategy` section → flow list comes from there |
| matches regex `^[A-Z]+-\d+$` (e.g. `CS-1`, `PROJ-42`) | **jira-driven** | Verify MCP atlassian is configured (env vars `JIRA_URL`, `JIRA_USERNAME`, `JIRA_API_TOKEN` set) → call `mcp__atlassian__jira_get_issue` → extract description, acceptance criteria, linked epic context |
| any other string (e.g. `auth-login`, `checkout-happy-path`) | **flow-name** | Treat as user-provided flow label; gather context from conversation in Phase 1 |

**Soft-fail for jira-driven mode:** if `$ARGUMENTS` looks like a Jira key but MCP atlassian is not configured (any of `JIRA_URL` / `JIRA_USERNAME` / `JIRA_API_TOKEN` missing):

> ⚠️ "`$ARGUMENTS` looks like a Jira key, but MCP atlassian is not configured. Treat it as a flow name and continue, or stop and configure Jira first?"

Wait for user response before proceeding.

### 0.2 Tool-specific reads (Playwright config + scripts)

These are the **only** files this command reads directly — they are test-runtime metadata that no other command loads:

| Source | Extract |
|--------|---------|
| `package.json` | Test command — first match in `scripts.test:e2e` / `scripts.e2e` / `scripts.test:browser`; fall back to `npx playwright test` |
| `playwright.config.{ts,js,mjs,cjs}` | `baseURL`, `testDir`, project-specific timeouts, projects/devices configured |

If `playwright.config.*` doesn't exist, note in your output (don't fail):

> ℹ️ "No `playwright.config.*` found — using defaults. Test command will be inferred from `package.json` scripts or fall back to `npx playwright test`."

### 0.3 Project context — delegated to `/prime`

**This command does NOT re-load project context.** UI language, module map, domain rules, and high-level goal are project-wide context that `/prime` loads once per session. Re-reading them here would duplicate work and burn tokens (especially `docs/PRD.md` — can be 2000+ lines).

The relevant files for E2E test work are:

- `CLAUDE.md` → `Language Rules` (UI language for selector matchers)
- `.agents/memory/project-brief.md` (distilled goal and success criteria, 50-line cap)
- `.agents/memory/architecture.md` (route map, naming conventions)
- `.agents/memory/domain/*.md` (domain rules invisible from the DOM — caching, gating, async pipelines)

**If those aren't in your conversation context yet** (no earlier `/prime` in this session, or they were absent), say so and ask the user to run `/prime` first, then re-invoke this command. Do not silently fall back to reading the PRD.

See [`.agents/memory/index.md` → Loader Convention](../../.agents/memory/index.md) for the project-wide rule.

### 0.4 Verify MCP Playwright availability

Check whether browser tools (`browser_navigate`, `browser_snapshot`, etc.) are available. If not:

> ⚠️ "MCP Playwright tools not detected. This command needs them for Phase 1 exploration. Install via your MCP setup (typically `claude mcp add playwright npx -- @anthropic-ai/mcp-playwright`), then retry. Continuing in degraded mode — Phase 1 exploration will be skipped, and the plan will be derived from code/spec inspection only."

Continue in degraded mode if the user accepts; do NOT hard-stop.

### 0.5 Confirm context with user

Before Phase 1, summarize what you loaded:

```
Project:           <name from package.json>
Mode:              <plan-driven | jira-driven | flow-name>
Source:            <plan path / Jira key / arg string>
Base URL:          <from playwright.config or fallback>
Test directory:    <from playwright.config or fallback>
Test command:      <from package.json or "npx playwright test">
UI language:       <from CLAUDE.md Language Rules>
Domain rules:      <list of relevant .agents/memory/domain/*.md files>
MCP Playwright:    <available | degraded mode>

Flows to test:     <derived list>
```

Wait for user confirmation before running browser tools.

---

## Phase 1: Explore with MCP Playwright

For each flow in scope, explore the UI **before writing any code**. Skip this phase if running in degraded mode (no MCP Playwright); base the plan on code inspection instead.

### MCP tool sequence

```
1. browser_navigate         → navigate to the entry point
2. browser_snapshot         → accessibility tree FIRST — cheap, reveals roles and labels
3. browser_take_screenshot  → visual confirmation of initial state
4. [interact as needed]     → browser_click / browser_type / browser_fill_form
5. browser_wait_for         → wait for state change, never use fixed timeouts
6. browser_network_requests → capture API calls — note status codes and payload shape
7. browser_console_messages → check for JS errors after each interaction
8. browser_snapshot         → accessibility tree of the resulting state
9. browser_take_screenshot  → visual confirmation of final state
```

**Important:** Use `browser_snapshot` (accessibility tree) as your primary exploration tool — it is cheaper token-wise than screenshots and reveals ARIA roles needed for `getByRole()` selectors. Take a screenshot only to visually confirm state.

### What to record during exploration

For each flow, note:

- Exact ARIA roles and accessible names for interactive elements (from snapshot)
- Which `data-testid` attributes exist (if any)
- Network requests triggered and their response shape
- Any loading states, transitions, or conditional UI
- Console errors (there should be none — flag any you find)
- Text appearing in labels, buttons, headings — match what the UI actually renders, in whatever language the project uses (see Step 0.2)

---

## Phase 2: Test Plan

After exploring ALL flows in scope, produce a test plan in this format. Do NOT write any Playwright code yet.

```markdown
## Test Plan: [flow-name]

**File:** [testDir from playwright.config]/[flow-name].spec.ts
**Entry point:** [URL relative to baseURL]
**Source:** [plan file path / Jira issue link / user-provided context]

### Happy path
- [ ] Step 1: [what happens]
- [ ] Step 2: [what happens]
- [ ] Assert: [what should be true]

### Error cases
- [ ] [scenario] → [expected behavior]

### Edge cases
- [ ] [scenario] → [expected behavior]

### Selectors identified (from MCP exploration)
- [element]: getByRole('[role]', { name: /[ui-text]/i })
- [element]: getByTestId('[testid]')

### Network assertions
- [endpoint]: expect response status [code]

### Mocking strategy (if applicable)
- [external service or async pipeline]: [page.route() / mock fixture / storageState]
```

Produce a plan for every flow in scope, then present all plans together and ask:

> "Test plan ready. Review and confirm — only then will I generate test code. Want to change anything?"

**Wait for explicit approval before proceeding to Phase 3.**

---

## Phase 3: Generate Test Code

Only after the user approves the plan:

### File per flow

One file per flow: `[testDir]/[flow-name].spec.ts`

### Required structure

```typescript
import { test, expect } from '@playwright/test';

test.describe('[Flow Name]', () => {
  test('[specific behavior being tested]', async ({ page }) => {
    await test.step('[step description]', async () => {
      // ...
    });

    await test.step('[step description]', async () => {
      // ...
    });
  });
});
```

### Selector hierarchy — enforced, no exceptions

```
1. getByRole('button', { name: /submit/i })       ✅ first choice always
2. getByTestId('user-card')                       ✅ when role is ambiguous
3. getByLabel(/email/i)                           ✅ for form fields
4. getByPlaceholder(/enter email/i)               ✅ for inputs without label
5. CSS selectors (.user-card, #submit-btn)        ❌ forbidden
6. XPath                                           ❌ forbidden
```

### Waiting rules

```typescript
// ✅ correct
await expect(locator).toBeVisible();
await page.waitForResponse(resp => resp.url().includes('/api/<resource>'));

// ❌ forbidden
await page.waitForTimeout(2000);
```

### Locale and i18n rules

- **Match the project's UI language** as defined in `CLAUDE.md → Language Rules` (loaded in Step 0.2). Examples in this command use English; if your UI renders in Polish, German, Spanish, etc., adapt the matchers accordingly.
- **All text matchers: regex with `i` flag** — `/submit/i` not `'Submit'`. Regex handles whitespace, casing, and pluralization variations regardless of language.
- Never rely on English `aria-label` if the UI renders in another language — ARIA labels follow the rendered language unless explicitly overridden in code.
- Use `data-testid` as fallback when translated labels make role+name matchers fragile (frequently the case for headlines and marketing copy).
- Do not hardcode strings that may change with copy updates — prefer `data-testid` for structural assertions.

### Network interception pattern (for async flows)

```typescript
// Wait for the response BEFORE the action that triggers it
const responsePromise = page.waitForResponse(
  resp => resp.url().includes('/api/<your-endpoint>') && resp.status() === 200
);
await page.getByRole('button', { name: /submit/i }).click();
const response = await responsePromise;
```

### baseURL usage

```typescript
// ✅ correct — baseURL comes from playwright.config
await page.goto('/');
await page.goto(`/<feature>/${id}`);

// ❌ forbidden — never hardcode the host
await page.goto('http://localhost:3000/');
```

### Comment rule

Add `// Why:` comments **only** for non-obvious waits, retry logic, or workarounds. No narration of what the code does.

---

## Phase 4: Run and Report

After generating all test files, run the test command identified in Step 0.2 (typically `npm run test:e2e`, fall back to `npx playwright test` if no script is defined).

Report results:

### Generated Files
- List each file created with its path

### Test Results
```
[paste test runner output]
```

### Failures (if any)
For each failing test:
- Which assertion failed
- What the actual vs expected value was
- Fix applied (if straightforward) or flag for manual investigation

### Ready for commit
Confirm all tests pass before handing off to `/commit`.

---

## Out-of-scope decisions (universal testing boundaries)

These rarely belong in E2E and are commonly mocked or skipped. If a flow under test depends on any of them, document the chosen mocking strategy in the test plan (Phase 2) before generating code.

- **External auth providers** (OAuth, SAML, magic links) — use `storageState` to inject a logged-in session, or test only the auth-redirect contract
- **Payment end-to-end** (Stripe, payment gateways) — mock webhooks at the API layer; do not drive real card flows in E2E
- **Email-driven flows** that require inbox access — mock the email service and assert that the API was called with the right payload
- **Third-party services** with rate limits or paid credentials — stub at the network layer with `page.route()`
- **Long-running async backend operations** (background jobs, AI calls, external APIs that take >10s) — mock the response endpoint via `page.route()` to keep tests fast and deterministic. The PRD or a `domain/*.md` memory file should call out which pipelines are slow.

---

## Notes on MCP Playwright limitations

- `browser_snapshot` returns the accessibility tree — elements hidden with `visibility: hidden` or `opacity: 0` won't appear. Use `browser_evaluate` to check computed styles if a visible element doesn't show up in the snapshot.
- Dynamic content (data fetched from API) requires `waitForResponse` interception — the snapshot taken before the API response resolves will show a loading state, not the final content.
- For long-running async backend operations, see "Out-of-scope decisions" above — mock the response endpoint to keep E2E tests deterministic.
