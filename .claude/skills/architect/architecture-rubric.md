# Architecture rubric — what `@start-critic` grades `docs/architecture.md` + `docs/map/system.yaml` against

Every rule has an id; a critic finding cites one (`rule: "A3"`), and a finding that cites nothing is
taste and gets dropped. The rubric judges the **artifact**: is every decision evidenced, checkable
and consumable by `/setup:create-backlog`, `/brainstorm` and `backlog-check.mjs`? It never
re-litigates a choice the user made — a product or stack choice recorded as the user's decision is
out of bounds unless it contradicts a stated requirement (then the contradiction is the finding).

Sources the artifact must trace to: `docs/PRD.md` (`G-n`, `R-n`, `NFR-n`) and `docs/discovery.md`
(`FL-n` / `FL-n.Ak`, `BR-n`, `A-n`, `Q-n`, Clarifications quotes). The critic receives both as
`SOURCES` and reads them before the artifact.

Companion files: `.claude/skills/architect/subdomains.md` (A1, A6), `decision-dimensions.md` (A2,
A3, A5), `system-schema.md` (A6, A7), `stack-research.md` (A8), `.claude/skills/discover/prd-template.md`
§7–§8 (A9). Severity mapping mirrors `.claude/skills/discover/prd-rubric.md`.

---

## A — the nine rules

### A1 Every subdomain classification cites evidence

Each `## Subdomains` row's `Why` cell names an id (`G-n`, `R-n`, `NFR-n`, `BR-n`, `FL-n`) that
exists in the sources, or quotes a `docs/discovery.md` line verbatim — and the cited evidence
actually supports the type per `subdomains.md` §1 (a `core` row cites a goal or a "why we win"
answer; a `generic` row cites the absence of a differentiator plus its constraint).

- **finding when:** a row cites nothing, cites an id the sources do not define, or cites evidence
  that argues for a different type (quote both in `evidence`).
- **not a finding:** a classification the critic would have made differently when the cited
  evidence supports the author's — classification is the author's call, the citation is the rule.

### A2 Every context × dimension cell is decided, deferred or open

For every context in `## Subdomains` and every one of the seven dimensions in
`decision-dimensions.md` §1 there is an `AD-n` in `## Decisions`, a row in `## Deferred` with an
observable trigger, or an `open — Q-n (owner)` note. The stack dimension counts for the contexts
the stack binds.

- **finding when:** a cell has none of the three; a deferred row has a date or "later" instead of
  a trigger; an open cell has no `Q-n` or no owner; an open cell sits on a core context or on the
  critical flow with no `accepted as open by <owner>` line.

### A3 No separate deployable without a stated reason

Every `deployment unit` decision other than "module in the modular monolith" names, in its
`AD-n` `Evidence`/`Decision`, one of: an independent-scaling `NFR-n`, a separate owning team, a
compliance-isolation requirement (`PRD §9`), a differing release cadence.

- **finding when:** a separate deployable (also a separate `own store` paired with one) has an
  `AD-n` that names none of the four, or names one without the id/quote behind it.
- **not a finding:** the monolith default itself, however large the product — the rule is about
  the reason for leaving it.

### A4 Every NFR maps to a decision

Every `NFR-n` row of `docs/PRD.md` §6 appears in `## NFR → decision map` with at least one
`active` `AD-n`, or with `N/A — <reason>`.

- **finding when:** an `NFR-n` is absent from the map, maps only to a `withdrawn`/`superseded`
  `AD-n`, or maps to an `AD-n` whose `Decision`/`Rule` does not address the quality the NFR names
  (quote both).

### A5 Every `AD-n` has Binds, Prevents and a checkable Rule

Each `## Decisions` row has non-empty `Binds`, `Prevents`, `Rule`, `Status`, `Evidence`; the
`Rule` is **one imperative sentence a spec can be checked against** — a reviewer holding a
`/brainstorm` spec can answer yes/no without asking the architect.

- **finding when:** a cell is empty or a placeholder; the `Rule` hedges ("should consider", "where
  appropriate", "prefer"), states a goal instead of a constraint, or needs a judgement call to
  apply; `Status` is not `active` / `withdrawn` / `superseded by AD-m`; `Evidence` cites an id the
  sources do not define; a `superseded by AD-m` row names an `AD-m` that does not exist.

### A6 Context-map edges use the allowed kinds and match `system.yaml`

Every edge label in `## Context map` is **exactly one** of `acl`, `ohs`, `customer-supplier`,
`conformist`, `events`, `calls` (the model relationship when there is one, else the transport —
`subdomains.md` §3; never a combined label such as `acl, calls`), and the set of edges equals the
set of `links[]` with those kinds in `docs/map/system.yaml` (same `from`, `to`, `kind`; direction
per `subdomains.md` §3). `realizedBy` never appears in the context map.

- **finding when:** an edge uses another or a combined label, an edge exists in one file and not
  the other, the direction is inverted against the kind's rule, or a core context `conformist`s
  to another model.

### A7 `system.yaml` flows and links touch only existing nodes; critical flows exist

Every `flows[].steps[]` entry and every `links[].from` / `to` is a declared node `id`; exactly one
`trunk`; every `branch` has a `subdomain`; every `parent` exists. Every `docs/discovery.md` flow
with `**Critical:** yes` has a `flows[]` entry with `critical: true` whose steps cover the
contexts its `FL-n.Ak` activities sit in; no status/progress key anywhere.

- **finding when:** any reference dangles, a critical `FL-n` has no flow, a flow's steps skip a
  context that owns one of the flow's backbone activities, or a `fl:` names an `FL-n` the
  discovery file does not define.

### A8 Stack recommendation tied to constraints, with the scenario where it is wrong

`## Stack research` → `### Recommendation` ties each point to a constraint stated in `### Problem
& constraints` (by id), and names a **concrete** scenario — an assumption or future state — in
which the recommendation is the wrong call. `## Stack` rows carry a confidence tag and a binding
`AD-n`.

- **finding when:** a recommendation point cites no constraint or a constraint not in the problem
  section; the comparison's criteria do not include the constraints the recommendation leans on;
  the "wrong when" scenario is absent or generic ("if requirements change") — in that case the
  critic **writes the concrete scenario it sees** into `fix` (this is the devil's-advocate role the
  author no longer plays); a `## Stack` row lacks a tag or an `AD-n`; a `verified` tag has no
  source.
- **not a finding:** a confident recommendation that already names a concrete wrong-when scenario
  — confidence with a stated failure case is the goal, not a defect.

### A9 PRD digests agree with the architecture

`docs/PRD.md` `## 7. Core Architecture & Patterns` and `## 8. Technology Stack` summarise
`docs/architecture.md` — the same contexts, the same `AD-n` ids, the same stack choices — and end
with `Source of truth: docs/architecture.md`.

- **finding when:** a digest names a context, pattern, stack element or `AD-n` the architecture
  does not, omits one the architecture marks binding for slice 1, or is still the `/discover`
  placeholder (`pending /architect`) after Phase 8 ran; the pointer line is missing.
- **round 1 note:** the digests are written in Phase 8, after the critic loop — in round 1 and 2
  they may legitimately still be placeholders; grade A9 only when `ROUND: final` (the Codex pass)
  or when the digests already carry content.

---

## Severity mapping

| Condition | severity | kind |
|---|---|---|
| A7 dangling reference, missing trunk, or a critical `FL-n` with no flow (`backlog-check` would fail) | `blocker` | `patchable` |
| A2 open/undecided cell on a core context or the critical flow; A5 empty `Rule`/`Binds`/`Prevents`; A6 edge mismatch between the two files | `major` | `patchable` |
| A1 evidence contradicts the type, A3 separate deployable with no reason, A8 recommendation not tied to constraints | `major` | `fundamental` when the fix changes the context boundaries or the stack choice itself, else `patchable` |
| A4 unmapped NFR; A5 hedged Rule; A8 missing wrong-when scenario; A9 digest drift | `minor` (`major` when two or more rules are hit by the same row/section) | `patchable` |
| A1 citation missing on a row whose type is otherwise consistent with the sources; tag/pointer omissions | `minor` | `patchable` |

Verdict: `ship` = no blocker and no major; `revise` = at least one patchable blocker/major;
`rethink` = any `fundamental` finding — `rethink` wins over `revise`. A clean architecture gets
`ship` with an empty list; never manufacture findings to look thorough, and never grade the
author's confidence — grade the evidence and the checkability.
