# PRD template — `docs/PRD.md`

`/discover` Phase 5 fills this skeleton after the Definition of Ready gate
(`.claude/skills/discover/coverage.md` §4) passes. Keep the section headings **verbatim** —
`/maintain:refresh-brief` reads `## Technology Stack` and `## Core Architecture & Patterns`, and
`backlog-check.mjs` parses the id syntax (umbrella D5: a list item `- **G-1** — …` or a table row
whose first cell is `G-1` / `**G-1**`). Ids are never renumbered. A register id (`G-n` `R-n`
`NFR-n`) leaving current scope keeps its line with `(superseded by X-m per D-k)` or
`(withdrawn per D-k)` right after the id's dash (see **Register rules**); discovery ids keep the
plain `(withdrawn)`. Scope decisions `D-n` are defined as `### D-n — …` headings under
`## Change log`. The literal token `[internal]` marks a span (to the end of its line) that must not
leave the repo — every outbound step (Jira send, wiki publish) strips it.

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
**Baseline:** v1.0 (YYYY-MM-DD) · **Approved by:** proposed | <role/name> on <date>[; <role/name> on <date>] · **Current:** v1.0 (YYYY-MM-DD)

> **Register rules** (the scope register lives inside this PRD — read before editing any id).
>
> | Field on a `G-n` / `R-n` line (NFR: table cells) | Interview mode | Import mode |
> |---|---|---|
> | id + sentence | required | required |
> | `Traces: G-n` (`R-n` only) | required | required |
> | `Source:` | optional — `conversation` or a `.agents/sources/` / `.agents/meeting-notes/` path | **required** — `<file>:<row\|line>` |
> | `Quote:` | optional | **required** — original wording, original language |
> | `Added: vX.Y` | required | required |
>
> - **States**, placed **immediately after** the `**ID** — ` prefix; the sentence is never deleted:
>   `- **R-37** — (superseded by R-52 per D-4) WHEN …` (meaning changed — `R-52` carries the current
>   text) · `- **R-41** — (withdrawn per D-4) WHEN …` (gone, no successor). The same words anywhere
>   else on the line — inside a `Quote:` in particular — are content, not state. NFR rows carry the
>   state in their `Status` cell: `active` · `superseded by NFR-m per D-k` · `withdrawn per D-k`.
> - **Current vs history:** superseded and withdrawn ids are history — existing Tasks may keep
>   tracing them; no new work is derived from them.
> - **Immutability:** once `**Approved by:**` names an approver, a register sentence is frozen. A
>   change of meaning = supersede + new id. A wording fix with no change of meaning = edit in place
>   and record a `D-n` of kind `editorial` listing the ids.
> - **Versions:** baseline `v1.0`; every `D-n` of kind `scope` bumps `Current` to the next
>   `v1.N`; `editorial` and `confirmation` do not bump — `Current` is always `v1.<number of scope
>   D-n>`.
> - **Register adoption** (a PRD written before these rules): the first update adds this header as
>   `v1.0`, lists the existing ids in `**Pre-register ids:** <ranges>` (exempt from `Added:`) and
>   leaves their bare `(withdrawn)` markers as they are.

## 1. Executive Summary

Two or three paragraphs: the problem and who has it, the product in one sentence, why now, and
what slice 1 must prove. Core value proposition in one line.

## 2. Goals

Measurable outcomes only — a number, a target, a date, and who reads the number. A goal without a
number is an aspiration and belongs in §1.

- **G-1** — <outcome>: <metric> from <baseline> to <target> by <date> (read by <role>) · Added: v1.0
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

- **R-1** — WHEN <trigger>, the system shall <response>. Traces: G-1 · Flow: FL-1 · Source: <file>:<row> · Quote: "<verbatim>" · Added: v1.0
- **R-2** — IF <failure> THEN the system shall <response>. Traces: G-1 · Rule: BR-1 · Added: v1.0
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

`Source` holds `<file>:<row|line> · "<verbatim quote>"` (interview mode: `conversation` or empty; a
literal `|` inside the quote is written `\|`). `Status` is exactly `active`, `withdrawn per D-k` or
`superseded by NFR-m per D-k` — anything else is a checker error.

| ID | ISO 25010 characteristic | Requirement | Target | Measured by | Source | Added | Status |
|---|---|---|---|---|---|---|---|
| NFR-1 | Performance efficiency | <what> | <number, percentile> | <tool / method> | <file>:<row> · "<quote>" | v1.0 | active |
| NFR-2 | Reliability | … | … | … | … | v1.0 | active |
| NFR-3 | Security | … | … | … | … | v1.0 | active |

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

Open `Q-n` only — text and closing state live in `docs/discovery.md`; a closed question leaves this
index.

- `Q-1` — <one line> · owner <role> · blocks slice 1: yes | no
- …

## 14. Assumptions index

Ids only; definitions in `docs/discovery.md` → `## Assumptions`.

- `A-1`, `A-2`, …

## Release intent

One paragraph: what slice 1 must prove, for whom, through which critical flow (`FL-n`), and what
evidence (`G-n`) would say it worked. Delivery order and waves live in `.agents/backlog.md`.

## Change log

_No decisions yet — baseline v1.0._

<!-- Entry format (newest first; D-n ids are append-only, never renumbered). Kind `confirmation`
records a processed source that changed nothing (`Affects: none`) or the baseline approval itself;
generation and a critic's `ship` are never approval.

### D-<n> — YYYY-MM-DD — <title>
**Kind:** scope | editorial | confirmation
**Sources:** <path> (sha256:<first 12 hex>) · <path> (sha256:…) · BA direct decision | conversation
**Decision:** <one or two sentences, the decider's wording>
**Approval:** proposed | approved by <role/name> on <date>
**Affects:** <R-37 superseded by R-52 · R-41 withdrawn · R-60 added · Q-7 closed | none>
**Impact:** <G-n moved · slice · protected Tasks · Jira issues — `—` until a backlog exists>
**Tasks:** — <written by later commands>
**Jira refresh:** — <written by later commands>
-->

The first real decision replaces the placeholder line; keep the comment block as the format
reference.

## 15. Appendix

Related documents (`docs/discovery.md`, `docs/architecture.md` when written, source files),
external references, anything too long for the body.
