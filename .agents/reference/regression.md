# Reference: regression (opt-in kit)

The entry point of the regression system: a checked scenario catalog, specs written against a
deployed app, and a deterministic run. Off by default: **nothing happens until a project commits
`.claude/regression.json`** — without it every regression step is silent and `catalog.mjs` says
`regression not adopted`. Web projects only. Scripts: `.claude/lib/regression/`; adapter contract:
[regression-test-data.md](regression-test-data.md).

## 1. What it is

A project with a web frontend keeps a **scenario catalog**: one block per user path, with a stable
id, a priority, and the ids of the acceptance criteria it comes from. Scenarios are written when a
Task is designed. **Specs** (Playwright tests) are written later, against the deployed app. A plain
command runs the specs with no model in the loop; that run is the only pass/fail judge.

## 2. Lanes

| Lane | Role | Where it runs |
|---|---|---|
| **Catalog** | The core, built first: the link between the backlog and the tests; everything else reads it. | Inside task delivery; no browser. |
| **Deterministic run** | The only judge: a configured command plus a JSON report. | Against a deployed environment, by hand. |
| **Author** | Writes a spec per READY scenario without one. | Against the environment, by hand. |
| **Heal** | Repairs a red spec behind a mechanical never-weaken check. | Against the environment, after a red run. |
| **Visual** | Screenshot baselines, part of the baseline and the full run. | Against the environment. |
| **Explore** | Optional, never a gate. | Against the environment. |

## 3. Invariants

| Invariant | How it is enforced |
|---|---|
| A model is never the sole judge | The run is a plain command; its record is written by a script from the runner's JSON report. |
| Independent reproduction | A new spec passes repeated runs with zero retries on every device project of the scenario; a critic that did not write it reviews it. |
| Never weaken | A removed or loosened assertion, or an added `skip` / `fixme` / `fail` marker, stops a spec change. |
| Two human decisions only | A changed `Expected` of an existing scenario, and a release waiver. A run against a production environment is confirmed by a human each time. |
| No auto-commit | Authoring and healing write to the working tree; committing stays `/commit`. |
| The catalog is the only list | A spec's title starts with its scenario id. |
| Three separate facts per scenario | *Readiness* (the hand-written `Status`), *automation* (computed, §7) and *run outcome* (from the run record). |
| Always against a named environment | A run targets one environment named in `regression.json`, from the developer's machine, never inside a team clone, never against an app the run starts itself. |
| Safe on production by default | Every scenario declares `Effect`; an environment is production unless declared `kind: "test"`. The selection and request-guard policy for production is added by a later task (not yet shipped); the adapter contract already refuses `provision` / `reset` on production. |
| Exclusive ownership of test data | One run per environment at a time; a run resets only what it owns. |
| `Expected` comes from approved criteria | Derived from the approved criteria, never from reading code (an inventory of an existing app is the exception: there `Expected` is what the live app does). |

## 4. Lifecycle

| Stage | Regression artifact | Shipped |
|---|---|---|
| `/setup:regression`, catalog stage | `.claude/regression.json` with the `catalog` section (area codes proposed from the system map or the route list). | yes |
| `/setup:delivery-plan` | Every browser-observable criterion carries `[reg P0|P1|P2]`. | (not yet shipped) |
| `/brainstorm` | The scenario blocks for the Task's tagged criteria, written into the catalog on the Task's branch. | (not yet shipped) |
| `/plan-feature`, `/execute` | The catalog change lands with the code; no spec is written, no app is started. | (not yet shipped) |
| `/check-implementation` | The catalog validates; every tagged criterion has a scenario citing its current fingerprint. | (not yet shipped) |
| `/setup:regression`, baseline stage | The `runner` and `environments` sections; Playwright config, fixtures and the test-data adapter from the templates; `@playwright/mcp` pinned. | yes |
| Inventory of an existing app | The whole catalog from the routes in the code and the live app (`Source: live` / `code`). | (not yet shipped) |
| `/regression-tests author` | A spec per READY scenario without one; the `Spec` field written back. | (not yet shipped) |
| `/regression-tests run`, `heal`, `visual`, `status` | Run records, repairs, baselines, coverage. | (not yet shipped) |
| `/release` | The release gate: a green full record from a test environment for the exact build. | (not yet shipped) |

## 5. The config switch

`.claude/regression.json` (example: `.claude/regression.json.example`; committed, no secrets):

- **absent** — regression not adopted: every regression step is silent;
- **`catalog` only** — *catalog phase*: scenarios are written and validated, nothing runs;
- **`catalog` + `runner` + `environments`** — *baseline established*: the run and its lanes are active.

Sections: `catalog` (`path`, default `.agents/regression/scenarios`; `areas` `{CODE: name}`;
`id_pattern`, default `^[A-Z][A-Z0-9]{1,9}-[0-9]{3}$`; `smoke`, default `["P0"]`), `runner`
(`config`, `spec_dir`, `devices`, `commands.{smoke,full}`, `report`,
`test_data.{check,provision,reset,session}` — every path repo-root-relative, every command run from
the repo root), `environments.<name>` (`host`: an `http(s)://` URL without a trailing slash, or
`"qa-env"` = `base_url` of `.claude/qa-env.json`; `kind`: `test | production`, absent =
`production`; further keys are accepted unvalidated for the later policy task).

## 6. Scenario block

The catalog is the `*.md` files directly in `catalog.path`, one file per area, `README.md` skipped.
One block per scenario (normative):

```markdown
### CART-004 — Change quantity up to the maximum
- **Priority:** P0 · **Viewport:** both · **Status:** READY · **Effect:** write
- **Data:** signed-in test account with one in-stock line in the cart
- **Goal:** Raise one cart line to the maximum quantity and confirm the totals follow.
- **Steps:**
  1. Open the cart with one line in it.
  2. Increase the quantity with the stepper until it stops.
- **Expected:** The stepper stops at the maximum, the increase control is disabled, and the line
  total equals unit price × quantity.
- **Source:** E2-3.AC2 [a1b2c3] · FL-2.A4 · **Spec:** —
```

- **Heading** `### <ID> — <title>`: the id matches `catalog.id_pattern` and, when `catalog.areas` is
  set, its prefix is an area code. A block ends at the next `#`, `##` or `###` heading.
- **Field lines** `- **<Label>:** <value>`; several fields share a line separated by a ` · ` that is
  directly followed by the next `**<Label>:**` (a ` · ` inside a value, as between `Source` tokens,
  belongs to the value). An indented or numbered line continues the field above; blank lines are
  allowed. An unknown or repeated label is an error.
- **Required:** `Priority` (`P0|P1|P2`), `Viewport` (`desktop|mobile|both`), `Status`, `Effect`
  (`read|write`), `Goal`, `Steps`, `Expected`, `Source`, `Spec`. **Optional:** `Data`. `Steps` and
  `Expected` may be `—` unless `Status: READY`.
- **`Status`:** `READY` · `BLOCKED (<Task id | tracker key | #n>)` · `DROPPED (<reason or D-n>)`.
  `BLOCKED` without a reference and `DROPPED` without a reason are rejected.
- **`Effect`:** `write` = anything that outlasts the browser session or reaches a person or a third
  party — an order, a payment, a new or changed account, any email, a subscription toggle, a review.
  `read` = navigation, search, filters, and state that dies with an anonymous session (a guest
  cart). A borderline case is `write`. A path that ends in a write is two scenarios: the `read` part
  up to the last step before the submit, and the `write` part.
- **`Data`** names a key (an account key, a test product), never a value.
- **`Source`** — tokens separated by ` · `: a criterion id with its six-hex fingerprint as cited when
  the scenario was written, `E<n>-<m>.AC<k> [<fp>]` (qa-evidence-families.md §7c; an id without
  the fingerprint is rejected); a flow id `FL-<n>` or `FL-<n>.A<k>`; a tracker key
  `[A-Z][A-Z0-9]+-<n>` or `#<n>`, optional `[<fp>]`; the words `live` or `code` (an inventory).
  Flow ids are matched before tracker keys, so a tracker project literally called `FL` is not
  supported.
- **`Spec`:** `—` or `<repo-relative path> › <title>`, the title starting with the scenario id; an
  absolute path or a `..` segment is rejected.
- **Ids are never reused.** Never delete a `DROPPED` block — it keeps its id taken; a block that
  reuses the id of a `DROPPED` one is rejected, naming both places.
- **`Expected` is never translated copy** — it states observable behaviour, not UI strings in
  another language.

## 7. The spec header and the automation state

Every spec carries one header line per scenario, copying the `Source` it was written against:

```ts
// regression: CART-004 · source: E2-3.AC2 [a1b2c3] · FL-2.A4
```

The automation state is **computed, never stored** (there is no `Automation:` field):

- `missing` — `Spec: —`, or the spec file is absent.
- `stale` — the spec has no `// regression:` line for the id; its header cites other ids than the
  catalog `Source`; a cited criterion's **current** fingerprint differs from the header's; a cited
  criterion or its Task is withdrawn or no longer found; or the fingerprint cannot be computed
  (no current-format backlog, the §7c block or `bash` unavailable) — never `verified` on missing
  input. `automation_reason` says which.
- `verified` — header present and every cited criterion's current fingerprint equals the header's.

The current criterion is resolved by `resolveTask` of `.claude/lib/backlog-check.mjs` (an approved
spec in the Task's `Ref` wins over the Epic file — the resolver `/qa-verify` uses) and hashed by the
canonical §7c block of `qa-evidence-families.md`, run through `bash` (one implementation of the
hash). A tracker key is not readable offline: its fingerprint is compared catalog ↔ header. A
scenario citing only flows, `live` or `code` has nothing to go stale by: header present = `verified`.

**The `[reg Pn]` tag is part of the criterion text, so it is inside the fingerprint** (the same bytes
`/qa-verify` hashes): retagging a criterion makes the specs that cite it `stale` until they are
re-cited.

## 8. Scripts and commands

```
node .claude/lib/regression/catalog.mjs [--root <dir>] [--config <path>] [--status | --json]
  exit 0 valid (or not adopted) · 1 validation errors · 2 usage / unreadable or invalid config
node .claude/lib/regression/setup.mjs catalog  [--root <dir>] --areas CODE=Name,… [--path <dir>] [--smoke P0,…]
node .claude/lib/regression/setup.mjs baseline [--root <dir>] --fragment <json file>
node .claude/lib/regression/setup.mjs check    [--root <dir>]
node .claude/lib/regression/setup.mjs env <name> [--root <dir>]
  exit 0 ok / nothing missing · 1 something missing / refused write · 2 usage / invalid config
```

- `catalog.mjs` validates (each error `<file>:<line>: <message>`); `--status` prints counts by
  `Status` × `Priority`, per priority planned / written / automated, the READY ids without a spec
  and the stale ids; `--json` prints the same numbers with every scenario row. Planned = `[reg Pn]`
  tags on the current, non-withdrawn criteria of the backlog's Tasks (`n/a` without a backlog);
  written = scenarios not `DROPPED`; automated = written scenarios whose state is `verified`.
- `setup.mjs` is the only writer of `regression.json`: `catalog` never overwrites an existing file;
  `baseline` adds each absent section of `runner` / `environments` and never alters an existing
  key; `check` is static (never runs an adapter command, never reaches the network) and lists, one
  line per gap: config, catalog, the runner section and its files, environments and their hosts,
  the `test_data` program files (`<path> …` or `<interpreter> <script> …` with `node`, `bash`, `sh`,
  `python3`, `npx`), the `.mcp.json` pin.
- `/setup:regression` drives both stages and copies the templates of
  `.claude/templates/regression/` into the project's e2e directory, never over an existing file;
  `/setup:regression --check` runs only `setup.mjs check`.

## 9. Upgrade re-check

Exact pins the kit relies on — re-check them on an upgrade, never float them:

- `@playwright/mcp` in `.mcp.json` — an exact `@playwright/mcp@<x.y.z>`, never `@latest` or a range
  (`setup.mjs check` reports any other form).
