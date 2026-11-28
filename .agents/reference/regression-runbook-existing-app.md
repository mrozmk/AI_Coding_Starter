# Reference: regression runbook — an existing app

The adoption path of the regression kit for a web app that already runs: every command in order,
with its environment, its expected result and what to record. The pilot protocol, the metrics and
the record template it fills: [regression-pilot.md](regression-pilot.md). Contract of the kit:
[regression.md](regression.md); test-data adapter: [regression-test-data.md](regression-test-data.md).

## 1. Scope

- An existing web app with **one test and one production environment**, both deployed.
- **The full path on test** — inventory, authoring, runs, heal, seeded faults, spot-check.
- **Read-only on production** — `run smoke` / `run full` under `writes: refuse`, after the
  pre-flight (§3). Heal, seeded faults and authoring never target production in this runbook.
- **Nothing is run locally.** A local app is not an environment; every run targets a deployed host
  named in `regression.json`, from the Operator's own checkout (never a team clone). A test host
  that resolves only on the Operator's machine is fine — the run happens there.

## 2. What the project supplies

| Item | Why |
|---|---|
| A starter sync that carries this kit | the scripts, the commands, the templates and the guard come from the starter |
| `app_surface: web` in `.claude/project-profile.json` | regression is a web-only kit |
| `.claude/qa-env.json` pointed at the test environment | `qa-env` hosts and its `build_sha_url` fall back to it |
| A test account per environment, as an account key in the adapter | `means` on production names it; `session` signs it in through the guard |
| Test identifiers for deep links, per environment | a deep-link scenario needs a valid identifier on each side; a malformed one is never used on production |
| Each central API's rate limit and a verified upper bound of backend calls per page operation (or backend counters) | `backend_calls` and `guard.budget` are honest only with them; without them the costed path is `not run — policy` on production |
| The owner's rule for production runs: every run approved, or the rules approved once | the pre-flight records it; the run's own confirmation is asked every time regardless |

## 3. Pre-flight checklist before the first production request

Tick every box in `regression.json` → `environments.<production>` and record the ticked list in the
run log before the first production `run`, walk or verify. Any box open → production stays off.

- [ ] `kind` is `production` (or absent — the default is production).
- [ ] `writes: refuse` — every `Effect: write` scenario is `not run — policy: writes refuse`.
- [ ] `workers: 1`.
- [ ] `guard.hosts` = the shop only (and its asset hosts the pages need); no third-party write host.
- [ ] Every costed operation in `guard.operations` has `cost` and `backend_calls`; every mutating
      request a read path needs (a sign-in, an add to cart) is a named operation — an unnamed one is
      aborted as `unnamed mutating request`.
- [ ] `guard.budget` set; the confirmation's worst case of backend calls fits the owner's limit.
- [ ] `pacing.requests_per_minute` positive and fitting the owner's rate window and the backend
      fan-out per request. At 0 the confirmation prints `unlimited` — check that line.
- [ ] `guard.stop`: `statuses` (at least 403, 429), `watch_4xx` for the endpoints whose 4xx counts as
      a permanent error, `error_signals` for a 200 that carries an error body.
- [ ] `consent: decline` (analytics stays off).
- [ ] `means` = the production test account (`account:<key>`) and nothing else.
- [ ] `build_sha_url` set, its host on `guard.hosts` — on both environments. Without a known build a
      run is `INCOMPLETE` and the heal probe classifies `env` (it reads the build through the
      request guard), so no heal can classify `APP` or `TEST`.
- [ ] `node .claude/lib/regression/setup.mjs check` prints `foundation complete`.
- [ ] A `GREEN` `run full` on the test environment on the current build.
- [ ] The owner's approval recorded (who, when, for which runs).

## 4. Commands in order

Before row 8 copy the record template (regression-pilot.md §7) to `.agents/regression/pilot.md`,
fill the header, the thresholds and the planned required rows, and commit it — that is "before
run 1". Record = the section of that record the row fills.

| # | Command | Environment | Expected result | Record |
|---|---|---|---|---|
| 1 | `/setup:regression` (catalog stage) | — | `regression.json` written with the areas, or `regression.json exists — unchanged` | header |
| 2 | `/setup:regression` (baseline stage) | names test and production | the templates copied; `setup.mjs check` lines | header (environment names) |
| 3 | `/setup:regression --check` | — | `foundation complete` | header (starter tag) |
| 4 | `/setup:regression --inventory` | test (production only after §3) | `walk: COMPLETE`, the `applied:` ids, the suspicious list (read once) | Planned required rows |
| 5 | `node .claude/lib/regression/inventory.mjs split` | — | `part <k>: …` lines with their `author --area` line | Planned required rows (areas) |
| 6 | `/regression-tests author --area <codes> --env <test>` | test | `claimed: <ID> — <spec>` per spec; `refused:` / rejected drafts named | Author log, Sessions for cost |
| 7 | `/regression-tests status` | — | the planned areas show no READY id without a spec | Planned required rows (check) |
| 8 | `/regression-tests run smoke --env <test>`, then `run full --env <test>` ×5 | test | `GREEN` (exit 0); a RED prints `next: /regression-tests heal --run <run-id>` | Run log |
| 9 | Pre-flight checklist (§3) | production | every box ticked | Run log |
| 10 | `/regression-tests run smoke --env <prod>` / `run full --env <prod>` | production | exit 3 `confirmation-required: <token>` → `Run on production` → the verdict; every write scenario `not run — policy` | Run log, Cost (stops) |
| 11 | `/setup:regression --visual`, `/regression-tests visual update`, `Accept baselines` (optional) | test | `acceptance-required:` then `accepted: …`; set it up before row 8 or not in this window | Run log |
| 12 | `/regression-tests heal --run <run-id>` per RED | test | `class: APP\|TEST\|catalog-outdated\|env — …` or `stop: not reproduced\|inconclusive\|refresh needed — …`; an applied repair prints `healed: <ID> — <spec>` and ends the window | Heal log |
| 13 | Seeded faults (regression-pilot.md §5) | test | the seeded case failed on every required project; on the heal ones `class: TEST` and no `healed:` | Seeded faults |
| 14 | Spot-check (regression-pilot.md §6) | test | 10 specs read, each `ok` or `wrong PASS` | Spot-check |
| 15 | `python3 .claude/lib/costs/cost.py bind <KEY> --session <id>` per listed session, then `cost.py report <KEY> --format json` | — | tokens per session (input + cache write + output) | Cost |
| 16 | Decision | — | `Decision: GO \| NO-GO`, every threshold compared | Metrics vs thresholds, Decision |

A `stop: refresh needed` points at `/regression-tests author --refresh <ID>`; a refresh changes the
spec bytes, so it ends the window as an applied heal does.

## 5. Worked case: CLIENT-A

Anonymised. CLIENT-A runs a web shop for VENDOR's licences; CLIENT-B is the reference whose own
mechanism fed the design. Only what the runbook needs is stated.

**The app.**

- Licences are sold to **three customer kinds** (consumer, company, a group-VAT company); the kind is
  the first checkout question and decides every field below it — one scenario per kind.
- **A revenue-carrying renewal deep link:** most sales arrive from VENDOR's desktop application as a
  link carrying a licence identifier. The shop checks the licence live and routes to the renewal,
  conversion or upgrade. It is P0; the identifier is a secret in URLs and logs → a `redact` pattern,
  and a valid test identifier per environment is a precondition (§2).
- **A server-driven checkout** re-renders its components after every field change. Specs wait for
  the re-render (the response or the settled control), never for time — the flaky-P0 metric tells
  whether that holds.
- **A central price API** owns prices and licence state; every product page prices a whole period
  ladder, so one render is several backend calls the browser never sees. Its rate limit is unknown,
  and repeated permanent errors can disable the client's service account for every integration. So:
  the shop's pricing and add-to-cart requests are named operations with `cost` and a verified
  `backend_calls`; a `guard.budget`; `watch_4xx` on those endpoints and `error_signals` for the
  page's price-error state (a 200 with a zero price); `workers: 1`; valid inputs only, never a
  loop on a failing call. A 503 from that API behind a 200 page is a `server-error` ledger event —
  heal classifies it `env`, never `APP`.
- **No sandbox payment on production.** `writes: refuse`: orders, payments, registration,
  newsletter consent and licence-key resend are `Effect: write` and stay `not run — policy` on
  production. On test the full path runs with `kind: test`, `writes: allowed` and `means` naming
  `payment:sandbox` and the test account.
- **Consent declined** keeps the analytics container off; the consent dialog is handled by
  `consent: decline` before the first navigation.

**ED-346's asks, delivered by the kit** (nothing is built twice; CLIENT-A keeps its own command as a
thin alias that only delegates):

| ED-346 asks for | Delivered by |
|---|---|
| A command with a `test` or `prod` target; asks when none is given; never production by default; production confirmed in the run | `/regression-tests --env <name>`; no `default_env` may name production; the two-phase confirmation (regression.md §12) |
| Per-environment config, host allowlist, secrets only in `.env` | `regression.json` → `environments`, `guard.hosts`, the adapter's `session` (regression-test-data.md §2) |
| Production: no orders, registration, newsletter or forms, enforced by a request guard; read-only sign-in on a dedicated test account | `writes: refuse`, `means` = that account, the sign-in as a named operation; the guard aborts every other mutating request (regression.md §11) |
| Test: the full path incl. registration and an order paid in the payment sandbox | `kind: test`, `writes: allowed`, `means` with `payment:sandbox` |
| v1 scope: catalogue, search, product pricing, the renewal link, cart and checkout for three customer kinds, account, content pages, consent, redirects | the catalog's areas from the inventory (§4 rows 4-5), specs by `author --area` |
| Sequential production runs with capped price calls | `workers: 1`, `guard.budget`, `backend_calls`, `pacing.requests_per_minute` |
| Report: pass / fail / skip per scenario, traces for failures in a gitignored directory, a summary in the project's language | the run record (per machine, never committed) and the command's report |

CLIENT-A works from its tracker with no current local backlog, so its catalog uses the tracker-only
form (`Source: live | code`, later the ticket key) and the inventory runs in full mode.

The pilot's GO or NO-GO is the Operator's, recorded in the project's `.agents/regression/pilot.md`.
