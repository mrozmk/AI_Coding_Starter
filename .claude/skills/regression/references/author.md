# The author lane — procedure (`/regression-tests author`)

Turns READY scenarios without a spec into specs that are claimed only after they ran green three
times with zero retries on every device project of the scenario and a critic found every
`Expected` clause asserted. Read with `spec-rules.md` (how a spec is written) and
`.agents/reference/regression.md` §14 (the scripts' contract). Nothing in the lane commits.

## 1. Select

`node .claude/lib/regression/author.mjs select (<ID>… | --area <CODES> | --pending | --from-qa <file>) [--env <n>]`.

- `eligible: <ID> <spec path>` — the scenario may get a spec on this environment. Every other line
  is reported as is: `refused:` (not READY, already has a spec, policy, no device, target exists),
  `not promoted:`, `skipped:`, `ambiguous:`, `no scenario:`.
- Exit 2 with `environments:` → ask which environment (test first); production is confirmed later.

## 2. Draft

For each eligible scenario: `author.mjs draft <ID> --run <run dir> [--qa <ac_id>]` creates the
target file empty and registers it; then write the spec into that file. Sources, in this order:

1. the scenario block (`Steps`, `Expected`, `Data`, `Needs`);
2. the code the routes and components live in;
3. the newest walk observations of the route (`.agents/regression/runs/*/walk/observations.json`):
   the YAML ARIA snapshot gives roles and accessible names, the headings and links the structure;
4. `--from-qa` only: the recorded QA sequence (§ From a QA run).

Follow `spec-rules.md`. Never guess a locator the sources do not show — a clause you cannot locate
is reported, not approximated.

## 3. Lint

`author.mjs lint <spec> --id <ID>`; fix every violation before a runner sees the spec.

## 4. Verify — at most two rounds to 3/3 green

`node .claude/lib/regression/run.mjs verify <ID>=<spec>… [--env <n>]` — one batch for every draft.
Three passes of `runner.commands.full`, each with its own nonce and guard evidence; a scenario
qualifies only when every case of it passed at the first attempt in all three. On production the
command prints a confirmation (`confirmation-required:`) that covers this verify's three passes
only. On `not verified:` read the `context:` files (Playwright's error context), fix the spec, and
verify again — at most two verify rounds before the critic.

## 5. Critic — at most two rounds, each re-verified

Spawn `@regression-critic` with the block text (verbatim) and the spec path. Write its JSON plus
the three digests of the `verified:` line to `<verify run dir>/critic-<ID>.json`. `revise` → fix
the named clauses, re-verify (a new verify run; its digests replace the old ones), ask again. At
most two critic rounds and at most four verify rounds in total.

## 6. Claim

`author.mjs claim <ID> --spec <spec> --verify <verify run dir> --critic <critic file> [--provenance <file>]`.
It re-checks everything under the checkout lock — the three passes, the digests of the spec, its
helpers and the block, the critic verdict on those digests, the lint — and only then writes
`<spec> › <title>` into the block's `Spec` field and re-validates the catalog.

## 7. Reject what never qualifies

Every registered draft that is not claimed — after the round limits, on a refusal, on `Cancel`
at a production confirmation — goes through `author.mjs reject <ID> --run <run dir>`: the file
moves into the run directory, the target is free again, and the scenario stays without a spec in
the report.

## From a QA run (`--from-qa <working file>`)

The source is `.agents/handoffs/qa-<slug>-ac-matrix.md`, written by `/qa-verify`; its record is
the file's last section. `select --from-qa` joins the record's rows onto the catalog: a scenario
whose `Source` cites a criterion with the same fingerprint as a fresh `PASS` row, or — only when
exactly one evidence-bearing `PASS` row exists — the record's ticket.

**Never invent a step the QA run did not perform.** The spec's interactions come from the recorded
sequence; a step the row does not spell out — locator, action, assertion — is not reconstructed.
A test assembled from a plausible reconstruction asserts what the author thinks happened, and a
green run of it proves nothing.

| Row | Action |
|---|---|
| `PASS` | Promote — the assertion encodes behaviour observed to hold |
| `FAIL` | **Never promoted** (`not promoted:`): encoding a defect as expected behaviour turns a bug into a requirement |
| `NEEDS-HUMAN` | Skipped — nothing was settled, so there is nothing to assert |
| `PASS (carried from …)` | Skipped — it was not observed in this run |

**The sequence, by driver** (`select` prints which one it found):

- `script` — the driver script in the row's `artifacts` (and its JSON) holds the action sequence;
- `mcp` — the `.mcp.md` step log in the row's `artifacts`;
- `row` — a `qa-runtime-ui` row without a driver prefix: the sequence the verifier wrote in the
  row itself (`methods`, `evidence`).

`methods` lists only how a value was observed (ARIA snapshot, computed style, screenshot viewed); a
screenshot alone is no sequence (`skipped: … no recorded sequence`).

**Translation, Playwright MCP → Playwright test:**

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

A recorded call with no equivalent is a hazard to report, not a step to approximate. **Every
interaction is followed by a condition wait** — the QA driver waited on a condition; a test that
acts without waiting asserts against the pre-action frame.

**Coverage.** When the recorded sequence does not cover the scenario's `Steps`, stop that
scenario: `QA sequence does not cover <ID>` — and reject its draft.

**Provenance pass.** Besides the clause critic, spawn `@regression-critic` `MODE=provenance` with
the QA sequence (the paths `select` printed, or the row text) and the spec. It maps every
interaction of the spec to a recorded step; an action without one is `revise`. Write its JSON plus
the three digests to `<verify run dir>/provenance-<ID>.json` and pass it to `claim --provenance`.
The same round limits apply, each revision re-verified.

## Report

Claimed / rejected / refused / not promoted / ambiguous, the unobservable clauses
(`catalog.mjs --status` → `unobservable:`), and for `--from-qa` the step map of every claimed spec
(`spec step n ← QA step k`). A spec never run green three times is never reported as written.
