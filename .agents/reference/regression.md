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
| **Visual** | Screenshot baselines per environment, compared in `run full` and `visual compare`; written only by `visual accept` (§13). | Against the environment. |
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
| Safe on production by default | Every scenario declares `Effect`; an environment is production unless declared `kind: "test"`, and a production environment is read-only, one worker, default-deny for mutating requests unless its policy says otherwise. `policy.mjs` selects (§10), `guard.mjs` blocks every request the policy does not allow (§11), and a production run needs a human confirmation each time (§12); the adapter contract refuses `provision` / `reset` on production. |
| Exclusive ownership of test data | One run per environment at a time; a run resets only what it owns. |
| `Expected` comes from approved criteria | Derived from the approved criteria, never from reading code (an inventory of an existing app is the exception: there `Expected` is what the live app does). |

## 4. Lifecycle

| Stage | Regression artifact | Shipped |
|---|---|---|
| `/architect` | `app_surface` in `.claude/project-profile.json` from the stack; `web` → the report names `/setup:regression`. | yes |
| `/setup:regression`, catalog stage | `.claude/regression.json` with the `catalog` section (area codes proposed from the system map or the route list). | yes |
| `/setup:create-backlog` | `[regression:foundation]`, 1–3 `[regression:baseline]`, optional `[regression:smoke]` (`quality-tasks.md` → Regression), or a rule-out line. | yes |
| `/setup:delivery-plan` | Every browser-observable criterion carries `[reg P0|P1|P2]`. | yes |
| `/brainstorm` | The scenario blocks for the Task's tagged criteria, written into the catalog on the Task's branch. | (not yet shipped) |
| `/plan-feature`, `/execute` | The catalog change lands with the code; no spec is written, no app is started. | (not yet shipped) |
| `/check-implementation` | The catalog validates; every tagged criterion has a scenario citing its current fingerprint. | (not yet shipped) |
| `/setup:regression`, baseline stage | The `runner` and `environments` sections; Playwright config, fixtures and the test-data adapter from the templates; `@playwright/mcp` pinned. | yes |
| Inventory of an existing app | The whole catalog from the routes in the code and the live app (`Source: live` / `code`). | (not yet shipped) |
| `/regression-tests author` | A spec per READY scenario without one; the `Spec` field written back. | (not yet shipped) |
| `/regression-tests run [smoke\|full] [--env <name>]` | A per-machine run record for one environment and one build (§12). | yes |
| `/regression-tests status` | The catalog status matrix and the newest run record per environment. | yes |
| `/regression-tests heal` | Repairs. | (not yet shipped) |
| `/regression-tests visual compare \| update` | The visual lane on its own; `update` offers new baselines that only a human's `Accept baselines` writes (§13). | yes |
| `/setup:regression`, Visual stage | The `visual` section; the visual config and spec from the templates. | yes |
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
the repo root), `environments.<name>` (`host`: an `http(s)://` URL without credentials or a trailing slash, or
`"qa-env"` = `base_url` of `.claude/qa-env.json`; a local server — `localhost`, `*.localhost`,
`127.0.0.0/8`, `::1`, `0.0.0.0`, from either source — is refused, a `.local` host is allowed;
`kind`: `test | production`, absent = `production`; the policy keys `writes`, `workers`, `means`,
`pacing`, `guard`, `consent`, `build_sha_url` of §10; unknown keys are accepted for forward
compatibility), and the optional top-level `default_env` (it may name only a `kind: test`
environment).

The optional `visual` section (§13) turns the visual lane on: `config`, `spec`, `command`, `report`,
`baselines` (required, repo-relative), `policy` (`warn` default | `block`), `tolerance` (`threshold`
0.2, `max_diff_pixels` 0), `max_mask_ratio` (0.25), `timezone` (`UTC`), `mask` (`[]`), `routes`
(`id`, `path`, `title`, `devices` default both, `mask`, `full_page`, `wait_for`) and `storybook`
(`<env>: {url, ready, error?, exclude_tags?, build_sha_url?}` — allowed only on a `kind: test`
environment, its host on that environment's `guard.hosts`). With it, environment keys and runner
project names must be disk-safe (`[A-Za-z0-9-]`, unique case-insensitively) and no runner command
may set `--output`/`-o`.

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
  (`read|write`), `Goal`, `Steps`, `Expected`, `Source`, `Spec`. **Optional:** `Data`, `Needs`.
  `Steps` and `Expected` may be `—` unless `Status: READY`.
- **`Status`:** `READY` · `BLOCKED (<Task id | tracker key | #n>)` · `DROPPED (<reason or D-n>)`.
  `BLOCKED` without a reference and `DROPPED` without a reason are rejected.
- **`Effect`:** `write` = anything that outlasts the browser session or reaches a person or a third
  party — an order, a payment, a new or changed account, any email, a subscription toggle, a review.
  `read` = navigation, search, filters, and state that dies with an anonymous session (a guest
  cart). A borderline case is `write`. A path that ends in a write is two scenarios: the `read` part
  up to the last step before the submit, and the `write` part.
- **`Data`** names a key (an account key, a test product), never a value.
- **Needs** (optional) — `- **Needs:** account:shopper · price-call`: the keys the scenario relies
  on, separated by ` · `, each matching `^[a-z0-9][a-z0-9:_-]*$` and listed once. A key is either a
  safe means an environment declares (`environments.<n>.means`) or a guard operation
  (`environments.<n>.guard.operations`). `catalog.mjs` checks only the grammar (a malformed or
  repeated key is a `<file>:<line>` error); whether a key is declared depends on the environment
  and is the selection's (§10). A catalog without the field stays valid; `--json` rows carry
  `needs: []`.
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

**The `[reg Pn]` tag is outside the fingerprint** — §7c step 4b strips a leading tag, so tagging,
retagging or untagging a criterion changes no fingerprint: no spec goes `stale` and no QA record is
invalidated. Every other edit of the criterion text does.

## 8. Scripts and commands

```
node .claude/lib/regression/catalog.mjs [--root <dir>] [--config <path>] [--status | --json]
  exit 0 valid (or not adopted) · 1 validation errors · 2 usage / unreadable or invalid config
node .claude/lib/regression/setup.mjs catalog  [--root <dir>] --areas CODE=Name,… [--path <dir>] [--smoke P0,…]
node .claude/lib/regression/setup.mjs baseline [--root <dir>] --fragment <json file, relative to --root>
node .claude/lib/regression/setup.mjs visual   [--root <dir>] --fragment <json file, relative to --root>
node .claude/lib/regression/setup.mjs check    [--root <dir>]
node .claude/lib/regression/setup.mjs env <name> [--root <dir>]
  exit 0 ok / nothing missing · 1 something missing / refused write · 2 usage / invalid config
node .claude/lib/regression/policy.mjs [--env <name>] [--mode smoke|full|visual] [--action compare|update] [--json] [--root <dir>]
  exit 0 ok (or not adopted) · 2 usage / config / invalid catalog / no target
node .claude/lib/regression/run.mjs run [smoke|full] [--env <name>] [--confirm <token>] [--root <dir>]
node .claude/lib/regression/run.mjs visual compare|update [--env <name>] [--confirm <token>] [--root <dir>]
  exit 0 GREEN · 1 RED · 2 usage / config / invalid catalog / baseline not established /
  visual not configured / widened tolerance · 3 refused (visual update: acceptance required) ·
  4 INCOMPLETE · 5 BLOCKED/ENV
node .claude/lib/regression/run.mjs visual accept --run <run id> --token <token> [--root <dir>]
  exit 0 written · 2 usage / config · 3 refused
node .claude/lib/regression/run.mjs status [--env <name>] [--json] [--root <dir>]
  exit 0
```

- `policy.mjs` is a read-only dry run of the selection (§10): it prints the cases, the
  `not run — policy` reasons and, for production, the confirmation text — never a token.
- `run.mjs` is the deterministic run (§12); `/regression-tests` drives it and asks the two human
  questions (which environment, the production confirmation).
- `guard.mjs` is a library the runner config and the fixtures import (§11); it has no CLI.

- `catalog.mjs` validates (each error `<file>:<line>: <message>`); `--status` prints counts by
  `Status` × `Priority`, per priority planned / written / automated, the READY ids without a spec
  and the stale ids; `--json` prints the same numbers with every scenario row. Planned = `[reg Pn]`
  tags on the current, non-withdrawn criteria of the backlog's Tasks (`n/a` without a backlog) —
  the tag form and the critical-flow P0 rule are checked by `backlog-check.mjs`
  (`quality-tasks.md` → Regression);
  written = scenarios not `DROPPED`; automated = written scenarios whose state is `verified`.
- `setup.mjs` is the only writer of `regression.json`: `catalog` never overwrites an existing file;
  `baseline` adds each absent section of `runner` / `environments` and never alters an existing
  key; `visual` adds an absent `visual` section the same way (baseline established first); `check` is static (never runs an adapter command, never reaches the network) and lists, one
  line per gap: config, catalog, the runner section and its files, environments and their hosts,
  the `test_data` program files (`<path> …` — an executable file — or `<interpreter> <script> …` with
  `node`, `bash`, `sh`, `python3`, `npx`), the `.mcp.json` pin.
- `/setup:regression` drives both stages and copies the templates of
  `.claude/templates/regression/` into the project's e2e directory, never over an existing file;
  `/setup:regression --check` runs only `setup.mjs check`.

## 9. Upgrade re-check

Exact pins the kit relies on — re-check them on an upgrade, never float them:

- `@playwright/mcp` in `.mcp.json` — an exact `@playwright/mcp@<x.y.z>`, never `@latest` or a range
  (`setup.mjs check` reports any other form).

## 10. Environments and selection

Every `environments.<name>` entry carries a policy (`config.mjs` `envPolicy`); an absent key takes
the production-safe default:

| Key | Meaning | Default |
|---|---|---|
| `kind` | `test` \| `production` | `production` |
| `writes` | `refuse` \| `declared` \| `allowed` | `refuse` |
| `workers` | runner workers (positive integer) | `1` |
| `means` | the safe means the environment provides (`Needs` keys: `account:<key>`, `payment:sandbox`, …) | `[]` |
| `pacing` | `{action_delay_ms, requests_per_minute}` — `slowMo` and a request ceiling for the whole run (every worker shares it, `pace.json` in the run directory) enforced by delaying | `{0, 0}` (none) |
| `guard.hosts` | allowlist: exact hostnames or `*.domain` (subdomains only) | the environment's own host |
| `guard.header` | `{name, value}` added to every request the guard sends | none |
| `guard.operations.<name>` | a named request: `method`, `url` regex, optional `body` regex (matched against the **whole** payload), optional `cost` (> 0) and `backend_calls` (integer ≥ 1) | `{}` |
| `guard.rpc[]` | `{url, mutating}` — an RPC/GraphQL endpoint whose payload (body, or query string of a `GET`) can hide a write | `[]` |
| `guard.budget` | cost units per run; **required** on production when any operation has a `cost` | none |
| `guard.stop` | `statuses`, `watch_4xx` (url regexes), `challenge` (regexes on headers + body), `error_signals` (`{url, body}`) | `statuses: [403, 429]` |
| `consent` | `{strategy: decline \| accept \| none, cookies: [{name, value, domain, path?}]}` — cookies set before the first navigation (`path` defaults to `/`) | `decline`, no cookies (`consent: not applied` in the record) |
| `build_sha_url` | the endpoint the deployed build SHA is read from (`host: "qa-env"` falls back to `qa-env.json` `build_sha_url`) | none |

A `Needs` key may not be both a means and an operation name of one environment (config error).
`default_env` may name only a `kind: test` environment.

**Selection** (`policy.mjs`, for environment E and mode M). Candidates are `READY` scenarios with a
`Spec`; `smoke` keeps the priorities in `catalog.smoke`, `full` keeps all. For each candidate, in
order:

1. a `Needs` key not declared for E (neither a means nor a guard operation) → `not run — policy:
   <key> not declared for <E>`;
2. on production, a needed operation with a `cost` and no `backend_calls` → `not run — policy:
   <op> has no declared backend upper bound`;
3. `Effect: write` under `writes: refuse` → `not run — policy: writes refuse`;
4. `Effect: write` under `writes: declared` with no `Needs` → `not run — policy: no safe means named`;
5. otherwise selected: one case per runner project of its `Viewport` (`desktop` →
   `runner.devices.desktop`, `mobile` → `runner.devices.mobile`, `both` → both). A viewport with no
   project is `not run — no device` and makes the run `INCOMPLETE` (a config gap, not a policy).

A case is the triple **(scenario id, runner project, spec file)**. A `READY` scenario without a
spec, `BLOCKED` and `DROPPED` scenarios are counted in the summary, never run, never "not run —
policy". Policy-excluded scenarios are listed and never counted green. The plan carries the budget
(`ceiling`, each costed operation's `cost` / `backend_calls`, and the worst case of backend calls
`floor(budget × max over ops of (backend_calls / cost))` — an upper bound also for mixed
operations) and three digests: `config` (the raw `regression.json`), `catalog` (every catalog
file) and `plan` (environment, base URL, mode, both digests, the cases, the budget).

## 11. The request guard

`.claude/lib/regression/guard.mjs` is the one implementation; the copied runner config and
fixtures only wire it, so a guard fix reaches every project through sync. The fixtures install it in
**every browser context before its first navigation** — the test's `context`, any context a test
creates through `browser.newContext`, and Playwright's `request` fixture / `context.request` (which
context routing does not see). Service workers are blocked (they would bypass routing); the config
takes workers, the per-project selection `grep` and `slowMo` from the run manifest. A guarded
`request` call with `multipart` (or a `form` carrying files) is refused — the guard judges only the
bytes it sends; `fetch(request)` replays a captured request with its method, headers and body.

**Per hop.** The original request is hop 1, each redirect target the next, up to 10 hops (more →
abort, `redirect chain too long`). For each hop, **before it is sent**:

1. the run is already stopped → abort (`stopped`);
2. host not on the allowlist → abort (`foreign host`; on hop ≥ 2 `redirect to foreign host`);
3. production, mutating (a method other than `GET` / `HEAD` / `OPTIONS`, or a `guard.rpc` payload
   matching its `mutating` regex) and no named operation matches → abort (`unnamed mutating
   request` / `mutating RPC payload`); a 307/308 keeps the method and body and is judged as such,
   a 301/302/303 becomes a `GET` without a body;
4. production and a costed operation without `backend_calls` → abort **and stop** (`no backend
   upper bound`) — also when a read scenario reaches it indirectly;
5. a costed operation → reserve its cost in the run ledger (an owner lock shared by every worker);
   over the ceiling → abort **and stop** (`budget reached`);
6. wait for the request ceiling slot; **re-check the stop marker after the wait**; add the
   identifying header; send with redirects off. Headers are rebuilt per hop: an origin change drops
   `authorization`, `cookie` and `host`, a dropped body drops `content-type` / `content-length`.

The response is classified **before anything reaches the page**: a status in `guard.stop.statuses`
(403, 429), a watched 4xx, a challenge page or an error signal persists the stop and aborts the
request. A 3xx is the next hop; a final response is released to the page.

**Aborts vs stops.** An abort fails the **test** it happened in (the fixture throws after the test
when the ledger holds a `blocked` event for it — the case is `failed`, the run `RED`); a blocked
request outside any test makes the run `RED`. A **stop** ends the run as `BLOCKED/ENV`: every later
request is aborted, every later test fails fast, nothing is retried. A test or an adapter that
recognises an error state the guard cannot see calls `stopRun(reason)`.

**WebSockets.** On production every WebSocket is closed (fail-closed, logged `blocked`); a
Playwright without `context.routeWebSocket` stops the run (`websocket routing unavailable`) before
the first navigation — production is refused rather than run unguarded. On a test environment a
socket to a host off the allowlist is closed, one to an allowed host connects.

**Attestation.** The fixture writes one `installed` event per test (its test id, scenario id and
project) carrying the run's nonce; on production every executed case needs its own, else the run is
`BLOCKED/ENV` (`guard not attested for <id>/<project>`). Every account a test signs in needs a
`session` attestation from the adapter (regression-test-data.md), else `BLOCKED/ENV` (`session not
guard-attested for <account>`). On a test environment both are recorded warnings. A case skipped at
declaration (`test.skip()`) never runs its fixtures and needs no `installed` event; an adapter that
fails is logged `session-failed` by the fixture and fails its test (`RED`), not the attestation.

**Pre-flight (production).** Before the lock, the confirmation or any traffic, `run.mjs` refuses
(exit 3, `runner not guard-integrated — <file>: <reason>`) unless `runner.config` imports
`runnerOptions` from `.claude/lib/regression/guard.mjs`, every selected spec imports `test` from a
relative fixture module that imports `installGuard` from it, and none of those files sets
`extraHTTPHeaders` or `httpCredentials` (context defaults the guard's own redirect transport would
re-add on a cross-origin hop), and no selected spec or fixture module installs a route of its own
(`.route(`, `routeFromHAR`, `.routeWebSocket(` — a page route is matched before the guard's context
route, and its `continue()` would send the request unguarded). On a test environment the same
finding is a warning.

**Migrating a #330 installation.** The copied config and fixtures are project code and never
synced: re-copy both templates (`/setup:regression` baseline, Step 2, fills `<guard-module-relative>`)
and drop any `--grep` from `runner.commands` — the manifest selects the cases.

**What it cannot see — stated limitations.**

- On production a redirected navigation is **collapsed**: the page receives the final response but
  keeps the first URL (logged `redirect-collapsed`). Assertions on a redirect target belong to a
  test environment, where the page gets a `302` to the verified final URL and the browser's
  follow-up `GET` is the one hop not routed (logged `followed-by-browser`, reserved again when
  costed).
- Server-to-server fan-out behind one browser request is invisible: declare `backend_calls` for an
  expensive operation (the confirmation states the worst case).
- A `200` with an error body is not a status: declare `error_signals`, or call `stopRun`.
- A load balancer serving mixed builds can make a run straddle two builds; pin the environment.
- The pre-flight is a static text check of the selected specs and their fixture module: a route
  installed through a helper module they import, or through a computed call (`page[name](…)`), is
  not seen — and such a route takes precedence over the guard. Keep request mocking out of
  production scenarios.

## 12. The run

`/regression-tests` drives `run.mjs`. The order of one `run`:

1. **Refusals:** not adopted, config errors, no `runner` / `environments` (baseline not established),
   an invalid catalog → exit 2; a team clone (`.agents/team/team.json` or `session.json`) → exit 3.
2. **Target:** `--env`, else `default_env`, else the only environment when it is `kind: test`;
   otherwise exit 2 listing the names — `/regression-tests` asks which one. Production is never
   reached without naming it.
3. **Production:** the pre-flight (§11), then the **two-phase confirmation** — phase 1 prints the
   confirmation text (environment and host, config and catalog digests, mode, case and scenario
   counts, the `not run — policy` count, budget and worst case, workers, pacing, consent) and a
   single-use 128-bit token bound to the plan digest, valid 10 minutes, stored per machine at
   `.agents/regression/runs/.confirm/<env>.json`, and exits 3; phase 2 is `--confirm <token>`,
   accepted once and only for the same plan. A changed config or catalog invalidates it. **No flag
   and no config key skips it** (unknown flags are usage errors).
4. **Locks:** `env-<sha256(base URL)[:16]>` (one run per environment on this machine), then
   `checkout-<sha256(realpath of the repo)[:16]>` (one run per checkout — every environment writes
   the same `runner.report`), under `${REGRESSION_LOCK_DIR:-~/.agent-ops/locks/regression}`. Each
   holds an owner (pid, the runner's process group, run id); a lock is reclaimed only when both are
   gone (with a printed line), never by age; a live one refuses (exit 3, naming the pid and run id).
   Released after the runner's process group ended and the report was read, on every exit path;
   SIGINT/SIGTERM are forwarded to the runner's group. One run per environment across machines
   stays a rule, not a lock.
5. **Run:** the build SHA is read, a new run directory `.agents/regression/runs/<env>-<UTC
   yyyymmddThhmmssZ>-<4 hex>/` gets `manifest.json` (the selection, the guard policy, pacing,
   consent, a nonce), the stale report is deleted, the configured command runs in its own process
   group with `REGRESSION_RUN`, `REGRESSION_ENV`, `REGRESSION_ENV_KIND`, `REGRESSION_BASE_URL`; the
   build SHA is read again. Zero selected cases skip the runner (`RED`, `zero executed cases`).
   With `visual` configured, `run full` runs the visual compare pass (§13) after the functional one
   — unless that pass stopped or was interrupted — inside the same locks and directory, and the
   closing build read follows the visual pass. Every run with `visual` configured first refuses
   overlapping baselines (§13) and digests the baselines tree at every runner boundary.
6. **Verdict** from the report and `guard.jsonl` only, by precedence **BLOCKED/ENV > RED >
   INCOMPLETE > GREEN**:
   - `BLOCKED/ENV` — a guard stop; on production a missing case or session attestation.
   - `RED` — a failed case (a case with a guard-aborted request included); a required case missing
     from a completed run; a case whose title has no catalog scenario id; a case outside the
     selection (another id, a `BLOCKED`/`DROPPED` scenario, or the right id from another spec
     file); a blocked request outside a test; zero executed cases.
   - `INCOMPLETE` — a skipped, flaky, duplicated or interrupted required case; an expected status
     other than `passed` or an unknown result status; a case missing because the run was
     interrupted; a missing, unparseable or invalid report; report-level `errors`; a runner exit
     other than 0 while nothing failed; a viewport with no device; no build SHA, or a build that
     changed during the run.
   - `GREEN` — runner exit 0, a valid report with no report-level errors, an actual `passed` result
     for every required case, the build SHA known and unchanged, no stop.
7. **Record** `record.json` (schema 1): `run_id, env, kind, base_url, mode, started_at, ended_at,
   head_sha` (informational) `, build_sha, build_sha_after, build_sha_source, runner_exit,
   report_errors, digests, devices, command, versions{node, runner}, confirmed, cases[{id, project,
   result, duration_ms}], orphans, outside_selection, not_run_policy, no_device, guard{attested,
   blocked, budget, stop}, counts, visual, verdict, reasons, exit` — `visual` is the §13 block,
   `null` when the lane did not run (`run smoke`), `{integrity: [...]}` when it did not run but
   the baselines changed. No model output and no runner free
   text: statuses, ids, titles, durations, digests, SHAs, URLs reduced to origin + path.
   `.agents/regression/runs/` is **per machine** and ignores itself (its `.gitignore` holds `*`);
   it is never committed and never synced.
8. A `RED` run prints `next: /regression-tests heal --run <run-id>` and never starts it.

Exit codes: `0` GREEN · `1` RED · `2` usage / config / invalid catalog / baseline not established ·
`3` refused (team clone, lock held, not guard-integrated, confirmation required or invalid) · `4`
INCOMPLETE · `5` BLOCKED/ENV. `status` prints the newest record per environment and mode
(`smoke`, `full`, `visual` — `env mode verdict build_sha ended_at run_id`, or `<env> no run recorded
on this machine`), exit 0: a green visual record never hides a red full run.

## 13. The visual lane

Screenshots of configured routes and, on a `kind: test` environment, Storybook stories, compared
against **that environment's own accepted baselines** under the renderer that produced them.
Comparison across environments is not claimed. Recipe: `.claude/skills/regression/references/visual.md`.

**Sources.** One interface (`visual.mjs` `SOURCES`, `enumerate(ctx)` → `{state, targets, skipped,
index_digest}`): `routes` (the `visual.routes`, expanded by `policy.mjs` `visualPlan` — the confirmed
production cases are exactly the manifest's) and `storybook` (`<url>/index.json` read through
`guardedFetch`; v4+ `entries` or v3 `stories`; stories only; `exclude_tags` dropped; ids outside
`[a-z0-9-]` skipped). An unreachable or unknown index, or zero eligible stories, is a `failed`
source: no targets, and its baselines are never orphans or removals. Targets are `route:<id>` /
`story:<id>`, the image `<source>--<id>.png`, rendered on every runner project of their devices; a
device without a runner project is `not run — no device` and keeps its baselines.

**Layout.** `<baselines>/<env>/<project>/<file>` plus `<baselines>/<env>/index.json` (schema 1:
`tolerance`, `renderers{project: fingerprint}`, `images{"<project>/<file>": {sha256, run_id,
build_sha, stability, masked_ratio, renderer}}`). Per pass the run directory holds
`visual/<pass>/{manifest.json, output/}` plus `expected/` (compare — a **copy** of the baselines)
or the shared `visual/capture/candidates/` (capture, stability); evidence `visual.jsonl`; offer
`visual/offer.json`. The visual config collects exactly the configured spec; the manifest owns the
update mode (`all` on capture only, else `none`), repeats, output directory, snapshot path,
workers and retries — the config refuses those flags in `visual.command`.

**Evidence.** The worker (`visual-spec.mjs` `renderTarget`) writes one renderer line per worker and
project and exactly one outcome line per target × project × repeat: `{pass, id, project, file,
repeat, retry, test, outcome, diff_pixels, masked_ratio, reason, diff}`, `outcome` ∈ `same |
differs | missing | captured | error`. `differs` needs comparison evidence in the matcher's
diagnostic block (pixel count or size mismatch); any other matcher failure, a non-2xx navigation, a
story not ready / showing its error / rendering nothing, a mask over `max_mask_ratio` (the union of
the masked boxes) and an unstable render are `error`. The classifier joins every outcome to the
report entry and to the guard `installed` event **of the same pass** by test id.

**Verdict, in this order, under both policies first:** the §12 guard verdict over every pass — a
stop or, on production, a missing attestation → `BLOCKED/ENV`; a guard-aborted request in a visual
test or a blocked request outside a test → `RED`. Then the policy: differences (`differs`,
`missing`, `orphan`) → a `warning:` under `warn`, `RED` under `block`; an incomplete pass (errors,
`not-comparable`, no outcome, a failed source, a missing report, a non-zero runner exit with no
difference, a test-environment attestation gap) → a warning under `warn`, `INCOMPLETE` under
`block`. **Integrity reasons are `INCOMPLETE` under both:** a baseline whose sha256 differs from the
index (that target is an `error`, never `differs`), a PNG not in the index, an index key outside
the tree, a symlink, an interrupted accept, `baselines changed during the run (<pass>)`. A
standalone `visual compare` that compared nothing is `INCOMPLETE`; a build unknown or changed is
`INCOMPLETE`.

**Renderer.** A fingerprint per project: browser and version, Playwright, platform, OS major, arch,
a digest of the OS font listing, `host | container`. An image whose stored renderer differs from
this run's is `not-comparable`. Each project prints `visual portability: <project>: <baselines'
renderer> — this run same | differs in <fields>`.

**Disjointness.** Before any token, lock, report deletion or runner: the baselines (resolved,
nearest existing ancestor) must not overlap `runner.report`, `visual.report`, the functional
Playwright `outputDir` (the `test-results` defaults beside the config and the nearest
`package.json`, any literal `outputDir`; `runnerOptions(…).outputDir` or a variable bound to
`runnerOptions(…)` in the same file is the run directory; any other non-literal is refused) or the
runs directory —
else exit 3. The tolerance may never be wider than the accepted index's (or the defaults): exit 2.

**Update, offer, accept.** `visual update` runs a capture pass (`updateSnapshots: all` into the
candidates) and a stability pass (three read-only comparisons against the candidates, zero
retries). A candidate is offered only when it was captured, passed and attested, the three repeats
were each `same`, passed and attested, its bytes did not change after capture, the build was read
known and unchanged before and after, the guard found nothing, no integrity reason exists and —
for a story — the Storybook `build_sha_url` read the same build before and after. The offer
(`new | changed | unchanged | remove | unstable | error`) is printed line by line with a single-use
token (`acceptance-required:`, 30 minutes, `.agents/regression/runs/.confirm/visual-<env>.json`)
bound to the run, the offered index, the candidate hashes and the baselines tree; exit 3.
`visual accept --run <id> --token <t>` takes the checkout lock, recomputes the digest, stages the
next tree beside `<env>` (`.<env>.staging-<run>`), verifies it byte by byte, then swaps by two
renames (`<env>` → `.<env>.previous-<run>`, staging → `<env>`). It sends no request and renders
nothing. An interruption leaves a sibling the next run reports with its recovery.

**The human gate.** `/regression-tests` passes the token to `visual accept` only after an `Accept
baselines` answer in the same turn — conversational, like the production confirmation. The writer
cannot prove a human answered; what holds is: compare reads a copy, only `visual accept` writes
under `visual.baselines` and only with a token `visual update` issued, the tree is digested at
every runner boundary, and the index's sha256 per file turns a hand-copied PNG into an integrity
reason. No command widens a tolerance: a human edits `index.json` in a reviewed commit.
