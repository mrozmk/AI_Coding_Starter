# PRD template — `docs/PRD.md`

`/discover` Phase 5 fills this skeleton after the Definition of Ready gate
(`.claude/skills/discover/coverage.md` §4) passes. Keep the section headings **verbatim** —
`/maintain:refresh-brief` reads `## Technology Stack` and `## Core Architecture & Patterns`, and
`backlog-check.mjs` parses the id syntax (umbrella D5: a list item `- **G-1** — …` or a table row
whose first cell is `G-1` / `**G-1**`). Ids are never renumbered; a retired id keeps its line with
`(withdrawn)` appended.

Depth follows the product: a CLI tool gets a short PRD, a multi-tenant platform a long one. Every
section is present; a section that does not apply says so in one line rather than disappearing.
Successor of the section list in the retired `/setup:create-PRD`; the delivery timeline that used
to live here belongs to `.agents/backlog.md`.

The skeleton — copy from the first `---` to the end into `docs/PRD.md`:

---

# PRD — <Product name>

**Date:** YYYY-MM-DD · **Mode:** interview | import · **Discovery:** `docs/discovery.md` ·
**Sources:** <`.agents/sources/…`, or "conversation only">
**Status:** draft | reviewed (critic: ship | revise | rethink | not-reviewed — <reason> · codex: ship | revise | rethink | skipped — <reason>)

## 1. Executive Summary

Two or three paragraphs: the problem and who has it, the product in one sentence, why now, and
what slice 1 must prove. Core value proposition in one line.

## 2. Goals

Measurable outcomes only — a number, a target, a date, and who reads the number. A goal without a
number is an aspiration and belongs in §1.

- **G-1** — <outcome>: <metric> from <baseline> to <target> by <date> (read by <role>)
- **G-2** — …

## 3. Users & stakeholders

**Personas** (one short paragraph each): who they are, their technical comfort, the job they hire
the product for, today's workaround.

**Stakeholder map**

| Role | Uses | Pays | Approves | Operates | Name (if known) |
|---|---|---|---|---|---|
| … | ✓ / – | ✓ / – | ✓ / – | ✓ / – | … |

**Decision owner:** <role / name> — answers open questions within <latency>.

## 4. Scope

**In scope (slice 1)**

- <capability> — traces `G-n`
- …

**Out of scope (non-goals)** — each with a one-line rationale; this is the NOT list.

- <excluded thing> — because <reason>
- …

**Appetite:** <time / budget>. **Cut first when over:** <1>, then <2>, then <3>.

## 5. Functional requirements

EARS sentences, grouped by capability, each tracing at least one goal. Patterns:

- ubiquitous — "The system shall <response>."
- event-driven — "WHEN <trigger>, the system shall <response>."
- state-driven — "WHILE <state>, the system shall <response>."
- unwanted behaviour — "IF <condition> THEN the system shall <response>."
- optional feature — "WHERE <feature is present>, the system shall <response>."

### <Capability A>

- **R-1** — WHEN <trigger>, the system shall <response>. Traces: G-1 · Flow: FL-1
- **R-2** — IF <failure> THEN the system shall <response>. Traces: G-1 · Rule: BR-1
- …

### <Capability B>

- **R-n** — …

## 6. Non-functional requirements

One row per applicable ISO/IEC 25010:2023 characteristic (functional suitability, performance
efficiency, compatibility, interaction capability, reliability, security, maintainability,
flexibility, safety). A characteristic that does not apply gets a row with `N/A — <reason>` in
the Requirement cell — spelled exactly `N/A` (capital N, slash, capital A) at the start of the cell;
`backlog-check.mjs` keys on that prefix to keep the id but drop the row from mandatory Task
coverage.

| ID | ISO 25010 characteristic | Requirement | Target | Measured by |
|---|---|---|---|---|
| NFR-1 | Performance efficiency | <what> | <number, percentile> | <tool / method> |
| NFR-2 | Reliability | … | … | … |
| NFR-3 | Security | … | … | … |

## 7. Core Architecture & Patterns

> Written by `/architect` as a digest of `docs/architecture.md` — subdomains, bounded contexts,
> the binding `AD-n` decisions. Until then: *pending `/architect`*.

## 8. Technology Stack

> Written by `/architect` as a digest of `docs/architecture.md` — chosen stack per context with
> the `AD-n` that binds it. Until then: *pending `/architect`*.

## 9. Security & Configuration

- Authentication / authorisation approach (who may see and do what — see `BR-n`).
- Configuration surface (environment variables, settings files, secrets handling).
- Compliance regimes in scope and their owner (GDPR, AI Act tier, sector rules) — or "none".
- Security scope: in / out.

## 10. API

*If applicable* — endpoints or events exposed and consumed, request/response shape, auth, the
external systems from discovery Entities with their direction and failure mode. Otherwise one
line: "No external API in slice 1."

## 11. Success criteria

Slice 1 is a success when the goals below hit their targets; no new numbers here — point at §2.

- `G-1` — <how and when it is read>
- `G-n` — …

## 12. Risks

| Risk | Likelihood | Impact | Rests on | Mitigation | Owner |
|---|---|---|---|---|---|
| <what could go wrong> | H/M/L | H/M/L | `A-n` | <action> | <role> |

## 13. Open questions

Owned `Q-n` only — the text lives in `docs/discovery.md`.

- `Q-1` — <one line> · owner <role> · blocks slice 1: yes | no
- …

## 14. Assumptions index

Ids only; definitions in `docs/discovery.md` → `## Assumptions`.

- `A-1`, `A-2`, …

## Release intent

One paragraph: what slice 1 must prove, for whom, through which critical flow (`FL-n`), and what
evidence (`G-n`) would say it worked. Delivery order and waves live in `.agents/backlog.md`.

## 15. Appendix

Related documents (`docs/discovery.md`, `docs/architecture.md` when written, source files),
external references, anything too long for the body.
