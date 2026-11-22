# Architecture assessment — method

The method behind report 2 of `/architecture-review` (`architecture-assessment-YYYY-MM-DD.html`):
the vocabulary, the risk checklist the sweep agents apply, the tiers, the axes and the scoring rule,
the evidence and verification rules, and the auditor's independence. Report 1 (deepening
candidates) keeps its own method: `GLOSSARY.md`, `DEEPENING.md`, `INTERFACE-DESIGN.md`.

---

## 1. Vocabulary

| Term | Meaning |
|---|---|
| **invariant** | a property the system must keep on every path — "an acknowledged write survives a restart" |
| **promise** | an invariant the project states or a user relies on (goal, non-functional requirement, accepted decision, documented behaviour) |
| **entry point** | where a flow starts: a route, a CLI command, a job, a hook, a message handler |
| **tier** | how soon a finding must be acted on — §4 |
| **axis** | one of the four scored dimensions of an area — *Boundaries*, *Runtime behaviour*, *Change cost*, *Safety net* (§5) |
| **coverage** | per area and per axis, whether the sweep checked it (`checked`) or not (`not-checked`, with the unread files) |
| **assessed / not assessed** | an axis is assessed when its check ran and the sweep reported it `checked`; otherwise it is not assessed and earns no points |
| **verified by** | who re-read the cited lines of a finding — §6 |
| **evidence kind** | what the evidence of a finding is — `static`, `test`, `probe`, `runtime` (§6) |

**Scope of the two vocabularies.** The report-1 vocabulary rule ("vocabulary is load-bearing") and
the content-quality guardrail keep full force for the `depth` output and report 1. The `risk` output
uses this file's vocabulary and may make exactly two judgments the guardrail otherwise forbids: a
wiring point outside the type checker and every test (class 9), and a kind of change that costs many
files (class 12, measured). Ordinary duplication, naming, typing and style stay with `/deep-review`
and appear in neither report.

---

## 2. Risk checklist

Twelve classes. "No finding in this class" is a valid answer for every class; the anti-forcing rule
of report 1 applies word for word — calibrate to what is there, never manufacture a finding.

### 1. Failure memory

A failure is remembered past its cause: a cached error, a circuit that never closes, a "disabled"
flag set on the first exception and never cleared, a poisoned retry queue.
- Counts: one transient failure makes a feature unavailable until a restart or a manual step.
- Does not count: a deliberate, documented backoff that expires on its own.
- Axis: *Runtime behaviour*.

### 2. Derived-data keys

A cache, index or derived artifact keyed by less than what determines its content — the version, the
tenant, the settings, the source revision — so a stale or wrong-version result is served.
- Counts: a cache key without the input's version; a build artifact reused across configurations.
- Does not count: a key that is complete but has a long, documented TTL.
- Axis: *Runtime behaviour*.

### 3. Durability of user-authored data

Data a user or operator created can be lost or silently overwritten: a write acknowledged before it
is durable, a non-atomic replace, a last-writer-wins race on hand-edited content.
- Counts: write-then-rename missing on a file the user edits; success returned before the commit.
- Does not count: loss of a regenerable cache or a derived file.
- Axis: *Runtime behaviour*.

### 4. Silent degradation

A failure path that returns a plausible default instead of an error, so the caller and the operator
cannot tell the result is degraded.
- Counts: a swallowed exception that returns an empty list; a fallback that reports success.
- Does not count: a fallback that is logged, surfaced to the caller, or named in the result.
- Axis: *Runtime behaviour*.

### 5. Work growth

Work per request or per run grows with retained data or history instead of with the input: a full
scan on every call, an ever-growing log re-read, a quadratic merge.
- Counts: a per-request cost that grows without bound as the data set ages.
- Does not count: a one-off migration, or growth bounded by a documented limit.
- Axis: *Runtime behaviour*.

### 6. Contention on a critical path

The latency-bound path shares a lock, a queue, a worker pool or a single process with heavy work, so
it waits behind it.
- Counts: an interactive request queued behind a batch job on the same worker.
- Does not count: shared resources with separate, bounded capacity for the critical path.
- Axis: *Runtime behaviour*.

### 7. Unbounded waits

A call, lock or poll with no timeout, ceiling or cancellation, so one stuck dependency stalls the
caller indefinitely.
- Counts: a network call without a timeout; a polling loop with no hard limit.
- Does not count: a wait bounded by an outer, enforced deadline.
- Axis: *Runtime behaviour*.

### 8. Dependency direction

A source dependency points against a declared direction. A map/import mismatch from `measure`
(`map.against`, `map.undeclared`) is a candidate to inspect, never a finding by itself. It is a
**breach** only when a decision or a layering rule (`decisions.md`, `CLAUDE.md`, the architecture
document) constrains the source dependency and the code contradicts it. A caller-owned port
implemented by the provider's adapter lands in `against` and is correct dependency inversion — not a
breach.
- Counts: a domain module importing an adapter when a recorded decision forbids it.
- Does not count: an `against` entry explained by an interface the caller owns; an undeclared edge
  no rule constrains.
- Axis: *Boundaries*.

### 9. Unchecked composition

The point where the pieces are wired together sits outside the type checker and every test: string
dispatch, a registry filled by convention, a config file naming handlers, a shell script gluing
tools — so a broken wiring ships green.
- Counts: a handler named in config that no test resolves; a script entry point no test runs.
- Does not count: wiring covered by a smoke or contract test that runs it.
- Axis: *Safety net*.

### 10. Admitted but unused

Code, configuration or an option that is accepted, documented or parsed but has no effect — a flag
read by nothing, a setting the code ignores, a branch no caller reaches.
- Counts: a documented option no code path reads; a parsed field never used.
- Does not count: a deliberately reserved field marked as such.
- Axis: *Change cost*.

### 11. Documentation drift

A document the project relies on (architecture notes, a command's contract, a README a user follows,
a decision record) states something the code no longer does.
- Counts: a documented step, path or behaviour that the code contradicts.
- Does not count: a stale comment inside a function (that is `/deep-review`'s).
- Axis: *Boundaries*.

### 12. Cost of change

A kind of change touches many files. **Measured, never judged by reading:** `change_cost` in the
measurement — per area, the median and maximum number of files touched by the last commits that
touch the area. The sweep cites the figure; it does not estimate one.
- Counts: an area whose typical commit touches many files across areas.
- Does not count: a single large commit (an initial import, a rename) — look at the median.
- Axis: *Change cost*.

---

## 3. What a sweep returns for the risk lens

**Per finding** (the `risk` output):

- `class` — 1–12 from §2
- `title` — one line
- `claim` — what is wrong, in one or two sentences
- `rule` — the promise or rule broken, with its source when it has one (a decision, a goal, a doc)
- `anchors` — `file:line`, at least one
- `consequence` — what follows, worded as `measured` (it ran, or a measurement shows it) or
  `predicted`
- `change` — the smallest change that would fix it
- `effort` — `S`, `M` or `L`
- `confidence` — `high`, `medium` or `low`
- `candidate` — the report-1 candidate number when the fix is that deepening, else none
- `unread` — files of the finding's flow the sweep did not read

**Coverage block** — per assigned area, per axis (`boundaries`, `runtime`, `change_cost`,
`safety_net`), independent of the findings:

- `checked`, or
- `not-checked` with the files left unread and why.

An empty `risk` list never says by itself that an axis was checked — only the coverage block does.

---

## 4. Tiers

| Tier | Record value | Definition |
|---|---|---|
| **Needed now** | `now` | wrong or lost data, an invisible failure, or a breach of a declared rule |
| **Before the next feature in the area** | `next` | it will make the next change in the area slower, riskier or wrong |
| **When convenient** | `later` | real, but nothing gets worse while it waits |
| — | `none` | recorded but not tiered (does not count in the score) |

Report-1 candidates enter on *Change cost*: `Strong` → `next`, `Worth exploring` → `later`,
`Speculative` → not entered. A risk finding that references a candidate is the same record, counted
once. Hotspot rows carry no tier and do not feed the score.

---

## 5. Axes and scoring

`node .claude/lib/arch-assess.mjs score` is the authority; this section explains it.

| Axis | Classes |
|---|---|
| *Boundaries* (`boundaries`) | 8, 11 |
| *Runtime behaviour* (`runtime`) | 1–7 |
| *Change cost* (`change_cost`) | 10, 12, report-1 candidates (`class: "candidate"`) |
| *Safety net* (`safety_net`) | 9, plus the cap below |

Only records with `status: finding` and a tier other than `none` count; a record counts in every area
it lists.

**Anchors, per area and assessed axis:**

- **3** — nothing above "when convenient"
- **2** — at least one "before the next feature" record
- **1** — exactly one "needed now" record
- **0** — two or more "needed now" records, or a "needed now" record with `breach: true` on
  *Boundaries*

**Safety-net cap.** An area holding a path of `safety_flags` scores at most 2 on *Safety net*. The
rule is fixed and comes from the measurement alone: a non-test, non-definition file with no test
evidence (no sibling test, not imported by a test, not named by any test file) and with ≥ 400 lines
or ≥ 40 branches. It is independent of report 1's editorial hotspot thresholds and its 10-row cap.

**Not assessed.** An axis is not assessed when the area's sweep did not return, reported the axis
`not-checked`, or its check could not run. *Boundaries* without a comparable map is still assessed —
against `decisions.md` and `CLAUDE.md`, the graph's cycles and the sweep's class-11 reading; it is not
assessed only when the area's language has no import graph as well. A not-assessed axis shows
"not assessed — <reason>" and earns 0 points.

**Area score** = the sum of the assessed axes / 12 × 10, rounded to 0.5 — a fixed denominator, so a
missing axis can never lift the number; shown with its coverage ("3 of 4 axes"). Fewer than two
assessed axes → no number.

**Overall** = the line-weighted sum of the area scores over the source lines of **every** in-scope
area, an unscored area contributing 0 — a coverage-adjusted lower bound, shown with the share of
lines that were scored. With identical records, lost coverage never raises it.

**Inconclusive** — the script sets it, with reasons, when the scored areas cover less than half of the
lines, or when one axis is not assessed in any area. The verdict call is then forced to
*inconclusive*.

---

## 6. Evidence kinds and verified by

| Evidence kind | Meaning |
|---|---|
| `static` | read in the code only |
| `test` | a test ran and showed it |
| `probe` | a bounded synthetic probe ran and showed it |
| `runtime` | observed on a running system |

| Verified by | Meaning |
|---|---|
| `main-session` | the main session re-read the cited lines and confirmed them |
| `sweep-only` | only the sweep agent read them |
| `codex` | the Codex auditor anchored it and the main session did not re-read it |

**No top-tier (`now`) record may be `sweep-only`.**

---

## 7. Verification and refutation

1. **Verify.** The main session re-reads the cited lines of every provisional `now` record. Not
   re-checked → `sweep-only`, which cannot stay `now`. Not confirmable → `status: dropped`, one line
   why.
2. **Refute.** The `now` and `next` records go to Codex (`refutation-prompt.md`), labelled not
   independent. Each verdict acts only after the main session checks it in the code:
   - `confirmed` → the record stays a finding, unchanged;
   - `refuted` and the counter-evidence holds → `status: correction`, listed under *Corrections*;
     does not hold → stays a finding with a one-line note;
   - `overstated` and the narrower version of the `target` element holds → that element rewritten,
     the tier re-derived, the original kept in `correction_note`, listed under *Corrections* as
     "narrowed"; does not hold → unchanged;
   - `not-checked` → unchanged, named under *Not covered*.

---

## 8. Independence

The Codex auditor (Phase 0b) is blind: it receives only `auditor-prompt.md` with its four slots. It
never receives prior reports, our findings or hypotheses, suspected files, proposed fixes, candidate
rankings, the measurement file, or the method files (`GLOSSARY.md`, `DEEPENING.md`,
`INTERFACE-DESIGN.md`). The prompt carries a read exclusion valid until it submits; an auditor that
lists an excluded path in `coverage_limits` opened it, and its agreement with our findings is marked
**not independent**.
