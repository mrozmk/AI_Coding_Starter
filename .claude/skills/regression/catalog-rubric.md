# Catalog rubric — what `@start-critic` grades an inventory proposal against (`/setup:regression` inventory step)

The artifact is the staged proposal of one inventory step: `proposal.md` (the new scenario blocks,
in the catalog grammar of `.agents/reference/regression.md` §6) and `proposal.json` (`routes`: each
staged route's scenario ids or exclusion; `sources`: per new id, the code it was written from, a
`covered by` claim and the submit path it describes). The sources are the staged route list, the
walk observations (one per route and group, with the ARIA snapshot, title, headings, links, forms
and submit outcomes), the existing catalog, every `sources.<id>.code` file and — gaps mode — the
backlog files the claimed criteria resolve from.

Every rule has an id; a finding cites one (`rule: "C4"`) or `other:<named principle>`. A finding
needs evidence: the block id or route key in `where`, and the line of the proposal or the
observation it contradicts in `evidence`. The rubric judges **judgement calls**.

**Do not report what `inventory.mjs apply --dry-run` already refuses** (its output is passed to you
in `PRIOR` as known context): the block grammar and `validateCatalog`, an unknown area code, a new
block with a `Spec`, a rewrite of an existing block or a reused DROPPED id, a staged route with
neither a scenario nor an exclusion, an unattached block, a READY or `code`-only block on a route
the walk saw fail, a `live` block or a block not citing `code` on a route the walk did not see work,
a failed submit path that is not `BLOCKED (live: …)`, a `code` block without `sources.<id>.code`.

---

## C — the twelve rules

**C1 Observable Expected.** Every `Expected` clause is browser-observable behaviour (a heading, a
list, a message, a URL) — never internal state (a database row, a cache, a sent email, a log line).

**C2 One path.** One scenario follows one path through the app; a block whose `Steps` branch ("if
signed in …, otherwise …") or that covers two outcomes is two scenarios.

**C3 No duplicates.** No two blocks — new against new, and new against the existing catalog —
check the same path; in gaps mode, no block duplicates a criterion a scenario will cover at
`/brainstorm` (a `covered by <id>` claim names it instead).

**C4 No copy, no catalogue content.** `Expected` states behaviour, not UI copy in another
language, and never catalogue content that changes on its own (prices, stock, promotions, product
names).

**C5 Effect.** `Effect` is right: anything that changes state for a user — an order, an email, an
account, a basket that persists — is `write`; a borderline path is `write`.

**C6 Split at the write.** A path ending in a write is split: a `read` scenario up to the submit,
written from the walk (`live`), and a `write` scenario from the submit on, written from the code
(`code`, citing `file:line`).

**C7 Reproducible sources.** A `Source: live` block's `Steps` can be replayed from the observations
of its route (the sample, the links and forms seen); a `Source: code` block cites code that really
holds the path (`sources.<id>.code` names the handler, route or component).

**C8 Keys, never values.** `Data` names test-data keys (`account:shopper`, `product:in-stock`),
never a value (an email, a password, a product id, an order number).

**C9 Suspicious Expected.** An `Expected` that states an error message, an empty result, a 404, a
redirect to sign-in or a disabled control as normal behaviour may freeze a defect into the
baseline. Always reported, flagged `suspicious: true`, even when it is plausibly right.

**C10 Route coverage.** Every staged route has a scenario or an exclusion whose reason is real (a
third-party page, a page that needs data the walk cannot have); a `covered by <id>` names a
resolvable current criterion.

**C11 A failed path stays blocked.** A path the walk saw fail (status ≥ 400, a guard block, a
failed submit) is `BLOCKED (live: <the observed reason>)`, never READY, and its reason quotes the
observation.

**C12 Priority sense.** P0 = the app's critical read paths (for a shop: sign-in, search, product,
cart, checkout up to the payment); a P0 off the critical paths, or a critical path below P0, is a
finding.

---

## Severity and verdict

| Condition | severity | kind |
|---|---|---|
| C11 broken, or C6 broken on a write path | `blocker` | `patchable` |
| C1, C3, C5, C7, C10 broken | `major` | `patchable` |
| C2, C4, C8, C12 broken | `major` | `patchable` |
| C9 (always) | `minor` and `suspicious: true` | `patchable` |
| any rule thin | `minor` | `patchable` |
| the route list itself misses whole areas of the app the code shows | `major` | `fundamental` |

A C9 finding carries `"suspicious": true` next to its other fields; the inventory step lists every
such finding in its report (read once — no gate) whether or not round 2 resolved it.

Verdict: `ship` = no blocker and no major; `revise` = at least one patchable blocker / major;
`rethink` = any `fundamental` finding — `rethink` wins. A clean proposal gets `ship` with an
empty list; never manufacture findings.
