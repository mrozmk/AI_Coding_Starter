# Spec rules — how a regression spec is written (`/regression-tests author`)

The rules every candidate spec follows. The mechanical half is `node .claude/lib/regression/author.mjs
lint <spec> --id <ID>` (`speclint.mjs` `lintSpec`); the half a script cannot judge — does each
assertion prove its clause — is `@regression-critic`'s. Contract: `.agents/reference/regression.md`
§6 (the block), §11 (the guard), §15 (the lane).

## The file

- **One spec file per scenario** at `<runner.spec_dir>/<area lowercased>/<id lowercased>.spec.ts`
  (`CART-004` → `e2e/regression/cart/cart-004.spec.ts`), created by `author.mjs draft`, never by hand.
- `test` and `expect` come from the project's guarded fixtures module (a relative import, e.g.
  `'../../fixtures'`) — never from `@playwright/test`, never from a package or a `node:` module.
- **Exactly one** `test(…)` declaration. Its title is `<ID> — <title>`, the scenario's id and title.
- Tags as the second argument: `{ tag: ['@regression'] }`, plus `'@smoke'` exactly when the
  scenario's Priority is in `catalog.smoke`.
- The header above the test copies the catalog `Source` verbatim:
  `// regression: <ID> · source: <Source>` (the automation state compares it with the criteria).
- `test.use({ account: '<key>' })` when the scenario's `Needs` holds `account:<key>`;
  `test.use({ account: null })` (or no `test.use`) otherwise. `Needs` is the only authority —
  `Data` names keys, never values.

The template is `.claude/templates/regression/spec-header.ts.template`.

## Locators

Locator order: role › test id › label (› placeholder, for an input without a label): `getByRole`, `getByTestId`,
`getByLabel`, `getByPlaceholder`. No CSS selector (`.locator('…')`, `$(…)`, `$$(…)`, `$eval`), no
XPath (`xpath=`). An accessible name that is UI copy is resolved through the app's i18n catalogue —
a lookup helper reading the locale file — never a hard-coded translated string.

## Waiting

Wait on a condition — `await expect(locator).toBeVisible()`, `toHaveText`, a response the action
triggers — never a fixed delay (`waitForTimeout`, `setTimeout`). A server-driven re-render (a list
refreshed after a filter, a total recomputed after a quantity change) is waited for by its response
or its new state, not by time.

## Assertions

- **One assertion per `Expected` clause.** Split `Expected` into its clauses; each gets the
  assertion that would fail if that clause were false.
- A clause a browser cannot observe (an email is sent, a record is written) is not asserted. It
  gets one line, which `catalog.mjs --status` lists:
  `// regression-unobservable: <ID> · <clause> — <reason>`.
- No assertion on catalogue content that changes on its own (prices, stock, promotions, product
  names): assert that a price is shown, not which price.

## Never

- A route of the spec's own (`.route(`, `routeFromHAR`, `.routeWebSocket(`), context defaults
  (`extraHTTPHeaders`, `httpCredentials`) — the guard's context route must see every request.
- Network or process access outside the guard: `fetch(`, `require(`, `import(`, `XMLHttpRequest`,
  `WebSocket(`, `newContext(`, `launch(`, `connect(`, `process.env`.
- Skip markers and focus: `test.skip`, `test.fixme`, `test.fail`, `test.only`, `.skip(`.
- Retries: `retries` or `test.describe.configure(…)` anywhere in the spec or its helpers — a
  candidate qualifies only on three passes with zero retries.

A relative helper module the spec imports is scanned with the same network, process, import and
route rules, transitively; the fixtures module is the one exemption (it wires the guard).
