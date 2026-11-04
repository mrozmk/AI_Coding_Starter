# Backlog rubric — what `@start-critic` grades `.agents/backlog.md` against (`/check-backlog`)

Every rule has an id; a finding cites one (`rule: "K2"`) or `other:<named principle>`. The rubric
judges **judgement calls** the mechanical checker cannot make. It grades **live** Tasks and their
**current** acceptance criteria — the file `/check-backlog` passes next to the backlog
(`$SCRATCH/check-backlog-current.md`, produced by `backlog-check.mjs --next-ids`), because a Task's
current criteria may live in an approved spec, not in the backlog block. Withdrawn Tasks and
withdrawn criteria are history.

**Do not report what `backlog-check.mjs` already checks** (its warnings are passed to you as known
context): ids and their syntax, the DAG (unknown ids, cycles, Wave-0 depending on later waves),
sizes ↔ points and Epic sums, AC ids and their placement, trace existence, mandatory coverage of
active `R-n` / `NFR-n`, the walking-skeleton gap of a critical activity, XH stories with more than
5 AC, the critical-path share, same-Node same-wave Tasks split across lanes, a tech Task without a
trace, a leaf without a Task, `Relates` / `Chain` validity.

**Trace contract** (decisions D-A15): a `story` traces an active `R-n` and/or `FL-n.Ak`; a `tech`
Task traces an active `AD-n` and/or `NFR-n` (an `R-n` is allowed too). A story tracing only a flow
activity is valid.

---

## K — the ten rules

| Rule | Checks |
|---|---|
| **K1 INVEST per Task** | independent in substance (not just "no cycle"), negotiable (not an implementation recipe), valuable (its trace **justifies** the work), small for its size, testable |
| **K2 Size honesty** | an `H` whose current AC name three or more modules / components; a `tech` Task whose only AC is "installed / configured"; an `XH` whose obvious split pattern (create-backlog Phase 3 order) is unused |
| **K3 Wave 0 minimality** | each Wave-0 Task answers "who is blocked without it"; a Wave-0 Task with no dependents outside Wave 0 → candidate to move later |
| **K4 Skeleton thinness** | `WS` covers each critical activity once; extra `WS` Tasks on one activity need a reason; report the `WS` share of points |
| **K5 AC quality** | outcome, not verification method; no bracket labels; no vague adjectives; ≥1 unwanted-behaviour criterion per story; **no time estimates** (sizes / points are fine) |
| **K6 Trace substance** | a trace that does not justify the work; trace padding (many `R-n` one Task cannot deliver); an **unprotected** Task (Status `TODO`, empty `Ref`, no key) tracing a superseded id |
| **K7 Epic is an outcome** | `Outcome`, `Key assumption`, appetite, cut-first specific; 3–12 live Tasks is the healthy band — outside it, explain (one deliverable in disguise, or two outcomes) |
| **K8 Parallel plausibility** | Tasks that will edit the same files despite different Nodes (shared config, tokens, routing tables) |
| **K9 Relation sanity** | a `Depends on` that is really `Relates`; a dependency the AC imply but the DAG lacks; a `Chain` that should be one Task |
| **K10 Scope drift** | a Task whose traces do not justify it under the trace contract above; slice-1 requirements whose every Task sits in `R3` or later; a Task whose `R-n` a later `D-n` touched while the Task did not change |

Calibration from a previous BA engagement: a healthy Task was one UI component or one runtime
primitive (one service, one integration step); Epics held 3–12 Tasks.

---

## Severity and verdict

| Condition | severity | kind |
|---|---|---|
| K4 gap or K10 drift on the critical flow | `blocker` | `patchable` |
| K1, K2 or K3 broken | `major` | `fundamental` when the Epic cut itself is wrong, else `patchable` |
| two rules thin on one Task | `major` | `patchable` |
| any other rule thin | `minor` | `patchable` |

Verdict: `ship` = no blocker and no major; `revise` = at least one patchable blocker / major;
`rethink` = any `fundamental` finding — `rethink` wins. A clean backlog gets `ship` with an empty
list; never manufacture findings.
