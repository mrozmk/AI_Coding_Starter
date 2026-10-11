# Decision dimensions — the fixed table every bounded context is decided on

`/architect` Phase 2 fills one row per **context × dimension**. The dimension list is fixed so that
no context is "architected" by omission: a cell that nobody looked at is a decision made by the
first developer who touches it. Every cell is in exactly one of three states, and the critic
(`architecture-rubric.md` A2) rejects an empty one.

Method source: the BMAD `bmad-architecture` spine (`AD-n` Binds / Prevents / Rule, Deferred,
"decided, deferred, or open").

---

## 1. The seven dimensions

| Dimension | Question the cell answers | Options and the default |
|---|---|---|
| **style** | How is the context's logic organised inside? | `rich domain model` (entities + invariants in code — core with many `BR-n`) · `transaction script` (one procedure per use case — supporting with few rules) · `CRUD` (forms over data — generic/supporting with no rules beyond validation) · `rules engine` (externally edited rules — only when a `BR-n` says the business changes rules without a release). Default follows the subdomain type: core → rich domain model, supporting → transaction script, generic → CRUD or bought. |
| **deployment unit** | Does it ship inside the modular monolith or as its own deployable? | `module in the modular monolith` is the **default for every context**. `separate deployable` only with one of these stated reasons in the `AD-n`: an independent-scaling `NFR-n`; a separate team owning its release; a compliance-isolation requirement (`PRD §9`, data residency / audit boundary); a release cadence that must differ. "Microservices are modern" is not a reason; the critic (A3) rejects a separate deployable whose `AD-n` names none of the four. |
| **data ownership** | Who writes the context's data, and how do others read it? | `own schema` (own tables/namespace in the shared database — monolith default) · `own store` (separate database — pairs with a separate deployable or a data-isolation `NFR-n`). Others read via `events` (projection) or an `api` (`calls`/`ohs`) — never by joining into another context's tables. |
| **integration** | How does it talk to its neighbours? | `calls` · `events` · `acl` — one of the context-map kinds from `subdomains.md` §3, per edge; the cell lists the edges and cites the `FL-n.Ak` / `R-n` that needs each. |
| **build/buy** | Do we write it, or integrate a product? | `build` (core, and supporting with no fitting product) · `buy / SaaS` (generic — auth, e-mail, payments) · `library` (generic inside the monolith — search index, PDF rendering). A buy decision names the candidate(s) and the `NFR-n` / compliance line that filters them; the stack phase (`stack-research.md`) researches them. |
| **ops envelope** | Where does it run and what is the minimum to operate it? | runtime/host (from the stack phase) · observability minimum (which logs/metrics/traces, and which `NFR-n` reads them) · backup / RPO / RTO for its data (`NFR-n` reliability row, or "N/A — stateless") · the alerting owner. One line each; a context whose data has no RPO is a decision nobody made. |
| **security boundary** | Where do authentication and authorisation happen for it, and what sensitive data does it hold? | authn entry (edge / gateway / per-context), authz model (role / attribute / ownership — cite the `BR-n`), sensitive data classes it stores (PII, payment, health — cite `PRD §9`), and the control each requires (encryption at rest, retention, audit log). |

## 2. Cell states — decided, deferred, open

Every cell is **one** of:

| State | Written as | Rule |
|---|---|---|
| **decided** | `AD-n` (the decision lives in the `## Decisions` table) | the default is still a decision — a context that takes "module in the monolith" gets an `AD-n` saying so, with the reason the default holds |
| **deferred** | `deferred — until <trigger>` | the trigger is an observable event that reopens the cell ("first external consumer appears", "p95 > 300 ms on `FL-1`", "second team joins") — never a date alone and never "later". Deferred cells are listed in `## Deferred` with the trigger |
| **open** | `open — Q-n (owner)` | a question only the user or a named stakeholder can answer; the `Q-n` exists in `docs/discovery.md` (or is added through the `/discover` update path) with an owner. An open cell on a **core** context or on the **critical flow** blocks slice 1 unless the owner accepted it in writing |

Rules:

- Empty is not a state. A cell the author "did not get to" is an **open** cell without an owner —
  the critic reports it as A2.
- The default for every supporting/generic context on a slice-1 product is: style per type,
  module in the monolith, own schema, `calls` inside the monolith / `events` out of it, buy for
  generic — decided in one `AD-n` per context with the reason. Deviation from a default needs its
  own `AD-n`.
- Scope is the **first product slice**. A dimension that only matters for slice 3 is *deferred*
  with the trigger "slice 3 planned" — the backlog schedules it; the table does not pre-decide it.

## 3. Decision record — `AD-n`

One row per decision in `docs/architecture.md` → `## Decisions` (header verbatim in
`architecture-template.md`; `backlog-check.mjs` parses it). Fields:

| Field | Content |
|---|---|
| `AD` | `AD-n` — stable, never renumbered (umbrella D5); a withdrawn decision keeps its row |
| `Context` | the bounded context (or `all` for a cross-cutting decision) |
| `Dimension` | one of the seven above (or `stack` for the stack phase) |
| `Decision` | what was chosen, one sentence |
| **Binds** | what it constrains downstream — the modules, Tasks, specs that must obey it ("every context's persistence goes through its own schema; no cross-schema joins") |
| **Prevents** | the concrete failure it rules out ("a reporting query locking the orders table during checkout") |
| **Rule** | **one imperative sentence a spec can be checked against** — a `/brainstorm` spec either satisfies it or contradicts it; no "should consider", no "where appropriate" |
| `Status` | `active` · `withdrawn` · `superseded by AD-m` |
| `Evidence` | the ids the decision rests on — `G-n` / `R-n` / `NFR-n` / `BR-n`, or a quoted discovery line |

Rules:

- A **Rule** is checkable when a reviewer with the spec and the Rule in front of them can say
  yes/no without asking the architect. "Prefer events" is not checkable; "Cross-context writes
  happen only through domain events; a synchronous call that writes another context's data is a
  defect" is.
- **Superseding, never editing.** A later decision that changes an earlier one adds a new `AD-m`
  row and flips the old row's `Status` to `superseded by AD-m`; the old row's text stays. A spec
  that traces a superseded id gets the successor named by `backlog-check.mjs`.
- `withdrawn` is for a decision that no longer applies and has **no** successor (the context was
  removed from scope). Its row stays, with `(withdrawn)` on the line.
- Each **active** `AD-n` of the final table gets one pointer entry in `.agents/memory/decisions.md`
  (`/architect` Phase 9) so a future session finds it without opening `docs/architecture.md`.
