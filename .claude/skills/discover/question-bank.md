# Question bank — what `/discover` may ask

This is a **bank, not a script**. `.claude/skills/discover/coverage.md` decides which questions are
asked, in which order and how many per round; this file only holds the questions and what each
answer feeds. Before asking anything from here: derive the answer from `.agents/sources/`, the repo
and existing `docs/` first — **never ask a question whose answer is already on disk**. A question
that is skipped because the answer was derived still fills its target section; a question that is
skipped because nobody can answer it becomes an `A-n` (assumption) or `Q-n` (open question) in
`docs/discovery.md`.

Every question line ends with `→ feeds: <artifact section / id prefix>` so the asker knows which
artifact goes unfilled if the question is skipped. Each question, when asked, is phrased as a full
sentence with a one-line "why it matters" and a **Recommended** option first (`coverage.md` →
Asking rules).

Condensed from the discovery method of GitHub spec-kit `/clarify`, the pm-skills red team and
Kiro EARS requirements.

---

## Tier 0

Always covered — by derivation where possible, by asking otherwise. The ten questions plus Q0.

**Q0 — Project type (derived, then confirmed).** From the sources and the repo, classify the
project as one of: *greenfield product* · *internal tool* · *integration* · *data / AI* · *existing
codebase extension*. Present the derived type as the Recommended option with the other four as
alternatives; the confirmed type selects the Tier 1 pack. A project that is honestly two types
(an internal tool that is mostly an integration) opens both packs, the dominant one first.
`→ feeds: discovery header (type), question selection`

1. **Problem and today's workaround.** What problem does this solve, who has it, and how do they
   cope today (manual process, spreadsheet, competitor, nothing)? `→ feeds: PRD §1 Executive
   Summary, discovery Flows (as-is FL-n)`
2. **Users and the money/power map.** Who uses it day to day, who pays for it, who approves it,
   who operates it when it runs? Name roles (and people when known). `→ feeds: PRD §3 Users &
   stakeholders, discovery Stakeholders`
3. **Measurable success, with a date.** What number changes, from what to what, by when, and who
   will read that number? `→ feeds: PRD G-n`
4. **Why now.** What changed (deadline, regulation, lost deal, new team, cost spike) that makes this
   worth doing now rather than last year or next year? `→ feeds: PRD §1, PRD §12 Risks`
5. **Appetite and what gives first.** How much time and money is this worth (weeks, headcount,
   budget), and when it runs over, what is dropped first — scope, polish, or the date? `→ feeds:
   PRD §4 Scope, PRD Release intent`
6. **The NOT list.** What will this deliberately not do, even though someone will ask for it?
   Each item gets a one-line reason. `→ feeds: PRD §4 Scope (Out), non-goals`
7. **The one end-to-end scenario that must work.** Walk through the single flow that, if it fails,
   the product has failed — actor, trigger, steps, outcome. `→ feeds: discovery FL-n (critical),
   PRD Release intent`
8. **Hard constraints.** What is fixed regardless of design — platform, language, hosting, vendor,
   regulation, data residency, existing contracts, team skills? `→ feeds: PRD §9 Security &
   Configuration, discovery Business rules BR-n, PRD NFR-n`
9. **Pre-mortem.** It is six months later and the project failed — what is the most likely reason?
   `→ feeds: discovery Risks & pre-mortem, discovery A-n`
10. **Decision owner and latency.** Who decides open questions, and how fast can they answer
    (same day, weekly meeting, quarterly committee)? `→ feeds: discovery Open questions Q-n
    (owner), PRD §13`

**Gate G1** (checked after Tier 0): problem, outcome and appetite are *Clear* in the coverage
table. If any of the three is *Missing*, Tier 1 does not start.

---

## Tier 1

One pack per project type (Q0). Ask only the questions whose answers are not derivable; a pack is
5–6 questions by design — do not pad it.

### Greenfield product

1. **Segment and channel.** Which specific user segment is first, and through which channel do
   they find and start using the product? `→ feeds: PRD §3 Users & stakeholders`
2. **Evidence of need.** What evidence exists that this segment has the problem — interviews,
   sign-ups, support tickets, a competitor's revenue? `→ feeds: discovery A-n (value), PRD §1`
3. **Switching anxieties.** What stops this segment from switching from their current solution
   (data lock-in, habit, cost, trust)? `→ feeds: discovery Risks, PRD §12`
4. **Pricing hypothesis.** How will it make money, or what budget line pays for it, and what is
   the price point hypothesis? `→ feeds: PRD §1, discovery A-n (viability)`
5. **Killer assumption.** Which single assumption, if false, kills the product? `→ feeds:
   discovery A-n (confidence L, validate-by), discovery Risks`
6. **Smallest outcome release.** What is the smallest release that changes a measurable number
   for a real user? `→ feeds: PRD Release intent, PRD G-n`

### Internal tool

1. **The replaced process, in numbers.** Which process does this replace, with what volumes
   (items per day/month), time per item and current error rate? `→ feeds: discovery FL-n (as-is),
   PRD G-n`
2. **Roles and permissions.** Who may see, do, approve and undo what? `→ feeds: discovery
   Stakeholders, discovery BR-n, PRD §9`
3. **Systems of record.** Which existing systems hold the data this tool reads or writes, and
   which one wins when they disagree? `→ feeds: discovery Entities (source of truth), PRD §10`
4. **Mandated vs optional.** Will the users be required to use it, or does it have to win them
   over? `→ feeds: PRD §3, discovery Risks`
5. **Manual exceptions.** Which cases are handled by hand today and must stay handleable by hand
   (overrides, escalations, corrections)? `→ feeds: discovery FL-n (exceptions), discovery BR-n`

### Integration

1. **Systems, owners, direction.** Which systems are connected, who owns each side, and which
   direction does data flow (one-way, two-way, event-driven)? `→ feeds: discovery Entities,
   PRD §10 API`
2. **Protocol, auth, sandbox.** What protocol and authentication does each side use, and is there
   a sandbox/test environment? `→ feeds: PRD §9 Security & Configuration, PRD §10`
3. **Volume, latency, rate limits, SLA.** How many calls/records, how fast must they land, what
   rate limits apply, and what SLA does each side promise? `→ feeds: PRD NFR-n (performance
   efficiency, reliability)`
4. **Source of truth per entity.** For each shared entity, which system is authoritative, and what
   happens on conflict? `→ feeds: discovery Entities, discovery BR-n`
5. **Retries, idempotency, reconciliation.** What happens on a failed or duplicated message, and
   how are the two sides reconciled after an outage? `→ feeds: PRD R-n (unwanted-behaviour EARS),
   PRD NFR-n (reliability)`

### Data / AI

1. **The decision produced and the worse error.** What decision or output does the system
   produce, and which error is worse — a false positive or a false negative? `→ feeds: PRD G-n,
   PRD R-n, discovery BR-n`
2. **Data inventory and PII.** Which data sources feed it, who owns them, and do they contain
   personal or sensitive data? `→ feeds: discovery Entities, compliance flag (Tier 2)`
3. **Evaluation.** How will output quality be measured, against what baseline, and who signs off
   the metric? `→ feeds: PRD G-n, PRD NFR-n (functional suitability)`
4. **Human in the loop and fallback.** Where does a human review or override the output, and what
   does the system do when the model is unavailable or unsure? `→ feeds: discovery FL-n, PRD R-n`
5. **Cost and latency per call.** What is the acceptable cost and response time per request, and
   what volume is expected? `→ feeds: PRD NFR-n (performance efficiency), PRD §12`
6. **EU AI Act tier.** Does the use case fall into a prohibited, high-risk, limited-risk
   (transparency) or minimal-risk tier under Regulation (EU) 2024/1689? `→ feeds: compliance flag
   (Tier 2), PRD §9, discovery Risks`

### Existing codebase extension

1. **Touched flows and must-not-break.** Which existing user flows does this change touch, and
   which of them must keep working exactly as today? `→ feeds: discovery FL-n, PRD R-n`
2. **Existing domain terms.** Which terms does the codebase and the team already use for the
   things this feature handles — the glossary must reuse them. `→ feeds: discovery Glossary`
3. **Migration.** Does existing data or configuration need migrating, and can it be rolled back?
   `→ feeds: PRD R-n, discovery Risks`
4. **Rollout, flags, rollback.** How does it ship — behind a flag, to a cohort, big bang — and how
   is it switched off? `→ feeds: PRD Release intent, PRD §9`
5. **Test coverage and owners.** How well is the touched area covered by tests, and who owns it
   on the team? `→ feeds: discovery Stakeholders, discovery Risks, PRD §12`

---

## Tier 2

Opened by a **flag** raised during intake, Tier 0 or Tier 1. A pack is opened as a whole but each
question still obeys the derive-first rule.

| Pack | Opened by |
|---|---|
| Users / JTBD | more than one user role named, or a role whose motivation is unclear |
| Process | the product replaces or changes a human process (any as-is flow) |
| Data | any entity with a lifecycle, identity question or retention need |
| Integrations | any external system named anywhere |
| NFR | always opened once the critical flow is known — every applicable ISO/IEC 25010 characteristic needs a number or an explicit N/A |
| Compliance | personal data, payments, health, children, regulated industry, cross-border data, or an AI output that affects people |
| Risks | a killer assumption, a hard date, a single-vendor dependency, or a pre-mortem answer naming an external party |
| Money | a pricing hypothesis, a budget ceiling, or a per-call/per-seat cost |

### Users / JTBD

1. **Job to be done.** When a user "hires" this product, what job are they trying to get done, in
   what situation, and what does "done well" look like for them? `→ feeds: PRD §3, discovery
   FL-n`
2. **Alternatives considered.** What else did they try or consider for the same job? `→ feeds:
   PRD §1, discovery A-n (usability)`
3. **Frequency and stakes.** How often does the job occur, and what is at stake when it goes
   wrong? `→ feeds: PRD G-n, discovery FL-n (Critical)`

### Process

1. **Trigger and actors.** What starts the process, and which roles take part? `→ feeds:
   discovery FL-n (Actor), Mermaid swimlane lanes`
2. **Steps and handoffs.** What are the steps in order, and where does work pass between roles or
   systems? `→ feeds: discovery FL-n.Ak`
3. **Exceptions.** What goes wrong today, how often, and who fixes it? `→ feeds: discovery FL-n
   (exceptions), discovery BR-n`
4. **SLAs and waits.** Where does work wait, and what time limits apply to any step? `→ feeds:
   PRD NFR-n, discovery BR-n`
5. **Five whys.** Why is the process shaped this way — ask until a business rule or a historical
   accident appears. `→ feeds: discovery BR-n, discovery A-n`

### Data

1. **Entities and identity.** What are the main things the system tracks, and what uniquely
   identifies each? `→ feeds: discovery Entities (erDiagram)`
2. **Lifecycle.** How does each entity come into being, change and end? `→ feeds: discovery
   BR-n, PRD R-n (state EARS)`
3. **Volume.** How many of each entity exist now and in two years? `→ feeds: PRD NFR-n
   (performance efficiency)`
4. **Retention and deletion.** How long is each entity kept, and who may delete it? `→ feeds:
   discovery BR-n, compliance flag`

### Integrations

1. **Failure modes.** For each external system: what does the product do when it is down, slow,
   or returns garbage? `→ feeds: PRD R-n (unwanted-behaviour EARS), PRD NFR-n (reliability)`
2. **Change control.** Who is told when the other side changes its contract, and how early?
   `→ feeds: discovery Risks, discovery Stakeholders`
3. **Test access.** Is there a sandbox or recorded fixtures for the integration? `→ feeds: PRD
   §9, discovery Risks`

### NFR (ISO/IEC 25010:2023 — nine characteristics)

For each characteristic, ask for a number and how it will be measured, or an explicit **N/A with
a reason**. A characteristic without a number is *Partial*, never *Clear*.

1. **Functional suitability** — completeness, correctness, appropriateness: what accuracy or
   completeness threshold counts as working? `→ feeds: PRD NFR-n`
2. **Performance efficiency** — time behaviour, resource use, capacity: response time at which
   percentile, throughput, concurrent users? `→ feeds: PRD NFR-n`
3. **Compatibility** — co-existence, interoperability: which systems, browsers, devices, formats
   must it work with? `→ feeds: PRD NFR-n`
4. **Interaction capability** (usability) — learnability, operability, accessibility: which
   accessibility level (e.g. WCAG 2.2 AA), which time-to-first-success? `→ feeds: PRD NFR-n`
5. **Reliability** — availability, fault tolerance, recoverability: uptime target, RPO/RTO,
   degraded mode? `→ feeds: PRD NFR-n`
6. **Security** — confidentiality, integrity, authenticity, accountability: who may see what,
   audit trail, authentication strength? `→ feeds: PRD NFR-n, PRD §9`
7. **Maintainability** — modularity, testability, modifiability: test coverage floor, deploy
   frequency, time to change a rule? `→ feeds: PRD NFR-n`
8. **Flexibility** (portability) — adaptability, installability, replaceability: which hosting,
   which vendor lock-in is acceptable? `→ feeds: PRD NFR-n`
9. **Safety** — operational constraint, risk identification, fail-safe: what must never happen,
   and what is the fail-safe state? `→ feeds: PRD NFR-n, discovery BR-n`

### Compliance

1. **Regimes in scope.** Which regulations apply (GDPR, AI Act, PCI DSS, HIPAA, sector rules,
   accessibility law) and who in the organisation owns compliance? `→ feeds: PRD §9, discovery
   Stakeholders`
2. **Data subjects and lawful basis.** Whose personal data is processed, on what lawful basis,
   and where may it be stored? `→ feeds: discovery BR-n, PRD NFR-n (security)`
3. **Evidence required.** What documentation, logging or human oversight must exist to pass an
   audit? `→ feeds: PRD R-n, PRD §9`

### Risks

1. **Assumption map.** List the assumptions behind the plan and rate each: value (will they want
   it), usability (can they use it), feasibility (can we build it), viability (does it work for
   the business). `→ feeds: discovery A-n`
2. **Fails if.** For each load-bearing claim: "This fails if ___" — then the cheapest test that
   would show it. `→ feeds: discovery A-n (validate-by), discovery Risks`
3. **Rabbit holes.** Which parts could swallow unbounded time, and what is the rule for stopping?
   `→ feeds: PRD §4 Scope, PRD Release intent`
4. **Kill criterion.** What result would make you stop the project? `→ feeds: discovery Risks,
   PRD G-n`

### Money

1. **Budget ceiling.** What is the total budget, and who approves overruns? `→ feeds: PRD §4
   Scope (appetite), discovery Stakeholders`
2. **Running costs.** What per-user, per-call or per-month costs are acceptable in production?
   `→ feeds: PRD NFR-n (performance efficiency), PRD §12`
3. **Value per period.** What is the problem costing today per month, in money or hours?
   `→ feeds: PRD G-n, PRD §1`
