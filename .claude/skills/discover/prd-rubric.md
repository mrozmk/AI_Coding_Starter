# PRD rubric — what `@start-critic` grades `docs/PRD.md` + `docs/discovery.md` against

Every rule has an id; a critic finding cites one (`rule: "P4"`), and a finding that cites nothing
is taste and gets dropped. The rubric judges the **artifact**: is it decision-ready, honest and
usable downstream? It never re-litigates a product choice the user made — a choice is out of
bounds unless it contradicts another stated requirement (then the contradiction is the finding,
cited as B3).

Dimensions P1–P7 are the BMAD PRD rubric in our own words; B1–B5 are the Kiro / spec-kit
requirement-bug classes; I1–I3 are id hygiene for the umbrella D5 scheme. Each dimension is rated
**strong / thin / broken**; only *thin* and *broken* produce findings.

Sources: the BMAD PRD rubric, GitHub spec-kit `/clarify` and Kiro specs.

---

## P — the seven dimensions

### P1 Decision-readiness

Could an engineer and a product owner start the first slice from this PRD without a meeting?

- **strong** — scope, the critical flow, goals with numbers and the first slice's intent are all
  present; the open questions are owned and none blocks slice 1.
- **thin** — one of those is implied rather than stated; a reader would need to ask one question.
- **broken** — the PRD describes a wish, not a decision: no slice 1, no critical flow, or an
  unowned blocking question.

### P2 Substance over theater

Does every section carry information that changes a decision, or is it there to look complete?

- **strong** — personas say what the user does and needs today; NFRs carry numbers; the summary
  says what the product is, not what it believes in.
- **thin** — one section is padding (a persona with a name and a stock photo's worth of detail,
  an NFR row that says "high availability", a vision statement with no consequence).
- **broken** — *persona theater*, *NFR theater* or *vision theater* dominate: most of §3 or §6 is
  text that could be deleted without changing the backlog.

### P3 Strategic coherence

Do the goals, scope and requirements tell one story?

- **strong** — every `R-n` traces a `G-n`; the non-goals follow from the appetite; the critical
  flow is the one the goals measure.
- **thin** — a requirement or a goal is orphaned, or scope includes something no goal needs.
- **broken** — "a backlog with headings": a flat list of features with goals bolted on afterwards;
  the goals and the scope could belong to different products.

### P4 Done-ness clarity

Be unforgiving here. Is "done" unambiguous for slice 1?

- **strong** — every `G-n` has baseline, target, date and the role who reads it; the release
  intent names the evidence.
- **thin** — a goal has a target without a date, or a date without a baseline.
- **broken** — no goal is measurable, or "done" is a feature list rather than an outcome.

### P5 Scope honesty

Does the PRD admit what it does not know and will not do?

- **strong** — non-goals each carry a rationale; open-items density matches the stakes (a payments
  product with zero open questions is not honest); assumptions are logged with confidence.
- **thin** — non-goals present but unexplained, or assumptions hidden in requirement text ("users
  will have a stable connection").
- **broken** — no NOT list, or a high-stakes product with no `A-n` / `Q-n` at all.

### P6 Downstream usability

Can `/architect`, `/setup:create-backlog` and `/qa-verify` consume it mechanically?

- **strong** — stable ids on every goal, requirement, NFR and rule; the glossary's terms are the
  ones the requirements use; every `R-n` has `Traces: G-n`; `FL-n.Ak` activities exist for the
  critical flow.
- **thin** — one id prefix missing or a trace absent; a glossary term unused or a used term
  undefined.
- **broken** — requirements without ids, or ids without the D5 definition syntax.

### P7 Shape fit

Is the PRD the right size and shape for the product?

- **strong** — depth follows complexity; a CLI tool's PRD is short, a platform's is long; sections
  that do not apply say so in one line.
- **thin** — a section is bloated relative to its stakes or truncated relative to them.
- **broken** — the template was filled mechanically (every section the same length regardless of
  relevance) or sections were dropped without a line saying why.

---

## B — requirement-bug checks

Sweep every `G-n`, `R-n`, `NFR-n`, `BR-n`.

- **B1 Wrong level of detail** — a requirement prescribes implementation ("store in Postgres",
  "use a modal") or is so abstract it cannot fail ("the system shall handle orders").
- **B2 Ambiguity** — two competent readers would implement it differently. Two plausible readings
  → finding, with both readings in `evidence`.
- **B3 Inconsistency** — two statements cannot both be true (a goal vs a non-goal, a rule vs a
  flow, a PRD sentence vs a discovery answer, a user choice vs another stated requirement).
- **B4 Incompleteness** — a flow step, actor, failure branch or state the requirements imply but
  never specify; an EARS sentence missing its trigger/response.
- **B5 Vague adjectives and placeholders** — "fast", "robust", "intuitive", "scalable",
  "user-friendly", "etc.", "TBD", "TODO" in any requirement line; an NFR row without a number.

---

## I — id hygiene (umbrella D5)

- **I1 Duplicate id** — the same id defined twice in one or both files.
- **I2 Id without definition** — an id referenced (`Traces: G-4`, `Rests on A-2`) that no line
  defines in the D5 syntax.
- **I3 Renumbered or misused withdrawal** — ids out of sequence in a way that suggests
  renumbering, a `(withdrawn)` id still traced by a live requirement, or a withdrawn id's line
  deleted instead of kept.

---

## Severity mapping

| Condition | severity | kind |
|---|---|---|
| a Definition of Ready item unticked in `docs/discovery.md`, or ticked but visibly unmet | `blocker` | `patchable` (ask / log) |
| a P-dimension rated **broken** | `major` | `fundamental` when the fix is a rewrite of the section's approach (P3, P7), else `patchable` |
| a B-finding on a `G-n` or on an `R-n` of the critical flow | `major` | `patchable` |
| a P-dimension rated **thin** | `minor` (`major` if two or more dimensions are thin) | `patchable` |
| a B-finding elsewhere, any I-finding | `minor` (I1/I2 `major` — they break `backlog-check`) | `patchable` |

Verdict: `ship` = no blocker and no major; `revise` = at least one patchable blocker/major;
`rethink` = any `fundamental` finding — `rethink` wins over `revise`. A clean PRD gets `ship` with
an empty list; never manufacture findings to look thorough.
