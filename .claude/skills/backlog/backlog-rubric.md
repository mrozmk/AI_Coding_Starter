# Backlog rubric — what `@start-critic` grades `.agents/backlog.md` and its Epic files against (`/check-backlog`, `/setup:delivery-plan`)

Every rule has an id; a finding cites one (`rule: "K2"`) or `other:<named principle>`. The rubric
judges **judgement calls** the mechanical checker cannot make. It grades **live** Tasks and their
**current** acceptance criteria — the file `/check-backlog` passes next to the backlog
(`$SCRATCH/check-backlog-current.md`, produced by `backlog-check.mjs --next-ids`), because a Task's
current criteria may live in an approved spec, not in the Task's block in its Epic file
(`.agents/backlog/E<n>-<slug>.md`). Withdrawn Tasks and withdrawn criteria are history.

**Do not report what `backlog-check.mjs` already checks** (its warnings are passed to you as known
context): ids and their syntax, the DAG (unknown ids, cycles), the `Scope` cell, a CORE Task
depending on later work, a MUST Task depending on a COULD Task, sizes ↔ points and Epic sums, AC ids
and their placement, trace existence, mandatory coverage of active `R-n` / `NFR-n` (by a Task or an
outside row), a critical activity with no CORE / MUST Task, outside rows' ids, `Needed by`,
`Starts after` (their ids, a withdrawn Task named there, a wait cycle through outside rows) and
traces, no CORE Task, a CORE Task nothing outside CORE depends on, XH stories with more than 5 AC,
a tech Task without a trace, a leaf without a Task, `Relates` / `Chain` validity, a live Task
without its block or its Summary in its Epic file, a `full` backlog Task without criteria. Quality Tasks (`.claude/skills/backlog/quality-tasks.md`): their markers, type / size / scope, a closing audit not waiting for all product work, the occurrence count, an occurrence without prerequisites, a marker neither planned nor ruled out. Regression (`quality-tasks.md` → Regression): the tag form, a critical flow without a `[reg P0]` criterion, the `[regression:*]` markers planned / ruled out / missing.

**Modes** (`MODE` in the spawn, from the backlog header's `**Detail:**`). **Structure**
(`structure` — after `/setup:create-backlog`): Tasks carry a one-line `**Summary:**` and criteria
may be missing. The criteria-based rules are deferred — K5 and K12 entirely, and the criteria parts of K1
(testable), K2 (modules named in the AC; an "installed / configured" AC) and K9 (a dependency the AC
imply). A missing criterion is never a finding in this mode. The Summary is graded in their place
for K1: does it name an outcome a user or system can observe (not a method, not a component list)?
Criteria that already exist are still graded by every rule. **Detail** (`full` — after
`/setup:delivery-plan` details the Epics): every rule, every part.

**Trace contract** (decisions D-A15): a `story` traces an active `R-n` and/or `FL-n.Ak`; a `tech`
Task traces an active `AD-n` and/or `NFR-n` (an `R-n` is allowed too). A story tracing only a flow
activity is valid. A **quality Task** (a marker of `.claude/skills/backlog/quality-tasks.md`) traces nothing: that file justifies it, its criteria come from its templates, and K1 (valuable), K6 and K10 do not grade its missing trace.

---

## K — the twelve rules

| Rule | Checks |
|---|---|
| **K1 INVEST per Task** | independent in substance (not just "no cycle"), negotiable (not an implementation recipe), valuable (its trace **justifies** the work), small for its size, testable (*criteria-based*: its current AC are testable; structure mode: its Summary names an observable outcome) |
| **K2 Size honesty** | an `H` whose current AC name three or more modules / components (*criteria-based*); a `tech` Task whose only AC is "installed / configured" (*criteria-based*); an `XH` whose obvious split pattern (create-backlog Phase 3 order) is unused |
| **K3 CORE sufficiency and minimality** | each CORE Task answers "which sessions are blocked without it"; a Task many others need that is not CORE is a gap; a CORE Task nothing outside CORE needs → candidate to leave CORE |
| **K4 Critical-flow coverage and MUST honesty** | each critical activity covered once by CORE / MUST; extra Tasks on one activity need a reason; a `MUST` whose requirement the PRD marks optional, or a `COULD` the critical flow needs |
| **K5 AC quality** (*criteria-based* — structure mode grades only the criteria that exist) | outcome, not verification method; no bracket labels — a valid leading `[reg P0|P1|P2]` tag is regression metadata, not a bracket label; no vague adjectives; ≥1 unwanted-behaviour criterion per story; **no time estimates** (sizes / points are fine) |
| **K6 Trace substance** | a trace that does not justify the work; trace padding (many `R-n` one Task cannot deliver); an **unprotected** Task (Status `TODO`, empty `Ref`, no key) tracing a superseded id |
| **K7 Epic is an outcome** | `Outcome`, `Key assumption`, appetite, cut-first specific; 3–12 live Tasks is the healthy band — outside it, explain (one deliverable in disguise, or two outcomes) — the `Quality & upkeep` Epic is exempt from the band (its size follows the cadence) |
| **K8 Parallel plausibility** | Tasks that will edit the same files despite different Nodes (shared config, tokens, routing tables) |
| **K9 Relation sanity** | a `Depends on` that is really `Relates`; a dependency the AC imply but the DAG lacks (*criteria-based*); a `Chain` that should be one Task |
| **K10 Scope drift** | a Task whose traces do not justify it under the trace contract above; first-release requirements whose every Task sits in `COULD`; a Task whose `R-n` a later `D-n` touched while the Task did not change |
| **K11 Developer work only** | a Task whose deliverable belongs to another team (pipeline, environment, monitoring setup, test plan / QA run, design) → move it to `Outside the dev backlog`; a **mixed** Task — part of its Summary, scope lines or criteria is developer work, part only another team can satisfy → split it: the developer part stays a Task, the rest becomes an outside row naming that Task under `Starts after` or `Needed by`; an outside row a developer must in fact build → a Task; an outside row that plainly waits for developer work (a test run, an audit, a rehearsal) with an empty `Starts after`; an audit the team runs with a workflow command is a quality Task, never an outside row or an external blocker; a `[regression:*]` Task is developer work |
| **K12 Regression tags** (only when `.claude/regression.json` is among the SOURCES; *criteria-based*) | a tag on a criterion with no user-visible (browser-observable) outcome; a browser-observable outcome with no tag; a priority that contradicts quality-tasks.md → Regression (P0 off a critical flow, a critical-flow path not P0) |

Calibration from a previous BA engagement: a healthy Task was one UI component or one runtime
primitive (one service, one integration step); Epics held 3–12 Tasks.

---

## Severity and verdict

| Condition | severity | kind |
|---|---|---|
| K4 gap or K10 drift on the critical flow | `blocker` | `patchable` |
| K1, K2, K3 or K11 broken | `major` | `fundamental` when the Epic cut itself is wrong, else `patchable` |
| K12 broken | `major` | `patchable` |
| two rules thin on one Task | `major` | `patchable` |
| any other rule thin | `minor` | `patchable` |

Verdict: `ship` = no blocker and no major; `revise` = at least one patchable blocker / major;
`rethink` = any `fundamental` finding — `rethink` wins. A clean backlog gets `ship` with an empty
list; never manufacture findings.
