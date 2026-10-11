# Subdomains, bounded contexts, context map — the `/architect` Phase 1 decision aids

Three decision aids, each with the evidence rule it needs. `/architect` applies them to
`docs/PRD.md` + `docs/discovery.md` (ids per umbrella D5: `G-n`, `R-n`, `NFR-n`, `BR-n`, `FL-n` /
`FL-n.Ak`, `A-n`, `Q-n`) and writes the result into `docs/architecture.md` → `## Subdomains` and
`## Context map`, mirrored as `nodes[]` / `links[]` in `docs/map/system.yaml`. A classification or
a boundary that cites nothing is a guess; the critic (`architecture-rubric.md` A1) rejects it.

Method source: strategic DDD (Evans, Vernon), condensed — no essay here, only the tests.

---

## 1. Classify each subdomain — core / supporting / generic

Classify **before** deciding anything else: the type decides how much design effort a context
deserves (`decision-dimensions.md` → `style`, `build/buy`).

| Type | Test (all must hold) | Evidence the row must cite | Consequence |
|---|---|---|---|
| **core** | it is *why the product wins* — the owner would not buy it; the goals measure it; it changes often as the business learns | a `G-n`, or a quoted `docs/discovery.md` answer to "what makes us win / why not a competitor" (Clarifications log or Executive Summary), **and** the `FL-n` with `**Critical:** yes` passes through it | built in-house, built deep (rich domain model when the rules justify it), owned by the strongest people, decided first |
| **supporting** | needed for the product to work, specific to this business (no off-the-shelf fit), but a competitor doing it better would not change the outcome | an `R-n` / `BR-n` that no generic product satisfies as written (quote the rule that makes it specific) | built in-house but **simple** — transaction script / CRUD, minimal abstraction, no speculative extension points |
| **generic** | everyone has it and nobody wins by it — authentication, e-mail/SMS delivery, payments, file storage, search indexing, feature flags, audit logging | the absence of a differentiating `G-n`/`BR-n` for it **plus** the `NFR-n` / compliance line (`PRD §9`) that constrains the choice (data residency, retention) | buy / SaaS / library; the only design work is the integration seam and the `acl` that keeps its model out of the core |

Rules:

- **One type per subdomain, one row per subdomain**, each row citing an id or a verbatim quote
  (`"…" — docs/discovery.md ## Clarifications`). The critic checks the citation, not the label.
- **A product has one or two core subdomains**, rarely more. Three or more "core" rows mean the
  goals do not discriminate — report it as a question for the user (`Q-n`), do not pick silently.
- **Generic is not "unimportant".** `authn` is generic *and* on the critical flow — the
  `criticality: critical` node flag (`system-schema.md`) carries that, the subdomain type does not.
- **Owner intent counts as evidence** only when it is recorded: a discovery answer "we want to own
  the pricing engine" classifies pricing core even if a vendor exists — quote the answer.
- When the evidence is split (an `R-n` reads core, the owner's answer reads supporting), write the
  row with both quotes and the chosen type, and raise it in the Phase 1 question round — it is a
  directional fork, exactly what `coverage.md` §2 permits a question for.

## 2. Derive bounded contexts

A bounded context is a model boundary: inside it every term has exactly one meaning and one source
of truth. Derive them from the discovery material, in this order:

1. **Cluster the backbone activities.** Take every `FL-n.Ak` across all flows and group activities
   that read and write the **same entities** (`docs/discovery.md` → `## Entities`, source-of-truth
   column) under the **same `BR-n`** rules. A cohesive cluster = one candidate context.
2. **Split on glossary meaning.** A glossary term whose definition shifts between clusters
   ("Customer" = buyer in ordering, = account holder in billing, = lead in marketing) marks a
   boundary — two contexts, two models, a translation on the edge. Never one shared "Customer".
3. **Split on source of truth.** Two clusters that would both own writes to the same entity are
   one context, or one owns it and the other reads through an edge (`events` / `calls`). Never two
   owners.
4. **Merge by change rate.** Two clusters that always change together (every `BR-n` touching one
   touches the other) are one context — a boundary with no independence buys only an edge.
5. **Name each context with a glossary term**, map it to exactly one subdomain row from §1, and
   record the evidence: the `FL-n.Ak` ids inside it, the entities it owns, the `BR-n` it enforces.

Checks before writing: every `FL-n.Ak` of the critical flow sits in exactly one context; every
entity has exactly one owning context; no context has zero `BR-n`/`R-n` (an empty context is a
layer, not a context — fold it).

## 3. Context-map relationship kinds

Every edge in `## Context map` and every `links[].kind` in `system.yaml` is one of these; the kind
says who adapts to whom and how the data moves.

| Kind | Meaning | Use when | Avoid when |
|---|---|---|---|
| `acl` | **anti-corruption layer** — the consumer translates the provider's model into its own at the boundary | the consumer is a core context and the provider is generic, external or legacy (a SaaS auth model, a vendor's order schema) | both contexts are yours and share a release — translation for its own sake |
| `ohs` | **open host service** — the provider publishes a stable interface / published language for many consumers | a context serves ≥2 consumers and must not bend to each; the owner commits to the published contract | there is one consumer (use `customer-supplier`) |
| `customer-supplier` | upstream/downstream with **negotiated** priorities — the downstream's needs enter the upstream's planning | both contexts are yours, one clearly feeds the other, and the downstream can ask for changes | the upstream cannot be influenced (external, frozen) — that is `conformist` or `acl` |
| `conformist` | the downstream **adopts** the upstream's model as-is, no translation | the upstream is external/stable, the downstream is supporting or generic, and the model fits well enough that a translation layer would be waste | the downstream is core — a core context never conforms to someone else's model (`acl` instead) |
| `events` | **asynchronous**, the publisher owns the event schema, consumers react | the consumer must not block the producer's flow (notifications, reporting, projections), eventual consistency is acceptable per the relevant `NFR-n` | the consumer needs the answer in the same request (an `R-n` with a synchronous response) |
| `calls` | **synchronous** request/response, the caller waits | the `R-n` requires an immediate result and the callee's availability `NFR-n` is at least the caller's | the callee is slower or less available than the caller's `NFR-n` allows — decouple with `events` |

Rules:

- `acl` / `ohs` / `customer-supplier` / `conformist` describe **who adapts** (the model
  relationship); `events` / `calls` describe **how data moves**. Every edge carries **exactly one**
  kind, the same in `## Context map` and in `system.yaml`: the model relationship when there is
  one, else the transport. Never a combined label (`acl, calls`) — when the transport matters for
  an `acl`/`ohs`/… edge, say it in the edge's prose or its `FL-n.Ak` citation, not in the label.
- Every edge cites the `FL-n.Ak` or `R-n` that needs it. An edge nobody's flow uses is deleted,
  not deferred.
- `realizedBy` is **not** a context-map kind — it is the cross-tree link from a business node to
  the architecture node that implements it (`system-schema.md`); never draw it in `## Context map`.
- Direction matters: `from` is the consumer/caller for `acl`, `conformist`, `calls`; the publisher
  for `events`; the host for `ohs`; the supplier for `customer-supplier`.
