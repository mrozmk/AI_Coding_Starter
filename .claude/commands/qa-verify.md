---
description: 'Verify a task acceptance criteria one by one — classify each into an evidence family, dispatch its verifier, grill the findings, emit a signed verdict matrix'
argument-hint: '[tracker key | path to spec | backlog task id]'
---

# /qa-verify — Acceptance-Criteria Verification Router

Read a task's acceptance criteria, assign each a stable id, classify each into an **evidence family** (`.agents/reference/qa-evidence-families.md`), dispatch that family's canonical verifier, grill what comes back, and emit a per-AC verdict matrix a human signs row by row.

---

<HARD-GATE>
**Nothing runs before Phase 1 is approved.** No verifier is spawned, no browser is driven, no probe is dispatched until every AC has been classified and the human has explicitly approved the classification table. Correcting a misclassification before verification costs one line; after it, the whole run was spent answering the wrong question.
</HARD-GATE>

<HARD-GATE>
**QA never mutates.** No source edits. No mutating git. No editing the AC text — not to clarify it, not to fix a typo. No transitioning the issue's status. **On finding a defect, record a `FAIL` with a severity and keep verifying — never fix it.** A proposed fix appears only as text in the row's notes. The single permitted outward write is the evidence comment on the tracker, after explicit human approval. This boundary has no exception: a QA run that repairs what it inspects has destroyed the evidence it exists to produce.
</HARD-GATE>

---

## What this is / is NOT

**Is:** a **router**. It decides what kind of evidence each criterion needs, sends it to whoever can gather that evidence, and assembles the result into something a human can sign.

**Is NOT:**

- **not an AC oracle** — the auto-verdict is *evidence*, not acceptance. A human signs each row.
- **not a regression-test author** — that is `/test-e2e`.
- **not a code-quality gate** — that is `/check-implementation` and `/gates:verify-implementation`. This command cites their result; it never reproduces it.
- **not a fixer** — see the second hard gate.

---

## Step 0 — Preflight

**Primed-context check.** This command does not re-load project context. If neither `/prime-qa` nor `/prime` has run this session, say so and ask whether to run `/prime-qa` first — it loads `errors.md`, the domain files and the evidence registry, and runs the environment preflight this command's verdicts lean on.

**Registry check.** `.agents/reference/qa-evidence-families.md` must exist. If it does not: explain that the evidence taxonomy is what makes classification something other than guessing, offer to scaffold it from the starter, and **stop**. Classify nothing.

**Resolve the AC source** from `$ARGUMENTS`, in this precedence order:

1. Matches `^[A-Z]+-\d+$` → a **tracker key**. Read the issue via the tracker MCP and take its acceptance criteria.
2. Ends in `.md` and resolves under `.agents/specs/` → a **spec path**. Read its `## Acceptance Criteria` section.
3. Present as a task id in `.agents/backlog.md` → that task's criteria.
4. **No argument → list candidates and stop.** Show recent entries from `.agents/plans/done/` and recent specs, and ask which one. Never pick one: QA that verifies "something" is worse than QA that asks what.

**Stop conditions, each stated plainly rather than worked around:**

| Situation | Response |
|---|---|
| Tracker key given, no tracker MCP configured this session | **Soft-fail:** name the missing configuration and the fix (`.mcp.json`, restart required), then stop. There is no useful degraded mode — the criteria live there |
| Spec path given, no acceptance-criteria section in it | Stop and say which file and which heading was missing |
| Zero ACs parsed from a source that resolved | Stop. An empty matrix is a bug in the run, never a pass |

**Resolve `GATE_STATUS` here, as an explicit value** — one of:

- `green` — the project's quality gate ran green on this tree this session, or the user states it did.
- `not-run` — it has not been run.
- `unknown` — the default when nothing establishes it.

Never leave it implicit. `qa-contract` is told to **cite** this value instead of re-running the gate, and it cannot cite a value that was never set. It is passed verbatim to every verifier and stamped into the matrix header.

**Resolve the environment, and carry it all the way to the signature.** `/prime-qa` runs `.claude/lib/qa-probe.sh`, which already computes these deterministically — read them off its output, do not re-probe:

- `BASE_URL` — from the probe's `RESOLVED-BASE_URL`. Unresolved is **not** fatal: it forces every runtime family to `NEEDS-HUMAN`, which is a correct outcome, not a failed run.
- `BASE_URL_REASON` — from `RESOLVED-REASON`. *Why* this host was chosen is the part a reviewer cannot reconstruct later.
- `BUILD_SKEW` — the probe's `build-skew:` line, **verbatim**. Do not normalise it into an enum of your own; consume the four states it actually emits:

| Probe emits | Meaning | How the runtime / SSR / visual rows are stamped |
|---|---|---|
| `not-applicable` | The deployed host was not used — this run is against `local_url`. **The default whenever `base_url` is empty.** | **No skew warning.** Stamp the host instead: `verified against local <URL>` |
| `NOT-VERIFIED — <reason>` | Deployed host in use, but skew could not be established (no `build_sha_url`, or it returned no SHA) | `⚠️ skew not verified — deployed build may lag HEAD` |
| `matched (<sha>)` | Deployed build SHA matches local HEAD | No warning; stamp the SHA |
| `MISMATCH — <detail>` | SHAs differ. The probe then sets `DEPLOYED_OK=0` and **falls back to local**, so this run is on local — not on a lagging deployed build | `⚠️ deployed build rejected (SHA mismatch) — verified against local instead` |

> **Never collapse `not-applicable` into the not-verified warning.** A starter ships `base_url: ""`, so doing that stamps "deployed build may lag HEAD" on every local run — a warning that fires on the default configuration is one people stop reading, which is the exact failure this stamping exists to prevent. `prime-qa.md` puts the same rule the other way round: *unverified is not "matched"*. Both directions matter.

## Step 0.5 — Resolve `SUBJECT`

`SUBJECT` is the named symbol / module / package the criteria are about. It scopes every static probe. Derive it from the AC text plus the source's own fields — the tracker issue's component, the spec's `## Files` section, or the plan the work came from.

If it cannot be derived, carry it as `(unresolved)` rather than inventing one. **Either way, show it in the Phase-1 table** so the human can correct it before anything runs. An unscoped probe is slow and noisy, not wrong; a *silently* unscoped probe is how a run produces confident thin evidence.

---

## Phase 0 — Classify

Which verifiers actually exist on disk, injected at command load:

!`ls .claude/agents/qa-*.md 2>/dev/null || echo "(no qa verifier agents)"`

1. **Assign ids.** Walk the criteria in **document order** and assign `AC-1 … AC-n`. Tracker criteria arrive as unnumbered bullets, and `ac_id` is the join key for the entire run — ids are assigned once, here, and never renumbered afterwards.
2. **Classify semantically** per `registry §3`. Reason about what evidence would settle each criterion; never keyword-match. One AC may map to several families — emit **one row per (ac_id, family)** pair.
3. **Guard unbuilt verifiers.** For each row, look up the family's canonical verifier in `registry §2`, then check the injected listing above. If that agent file is **not** in the listing → `verdict: NEEDS-HUMAN`, `agent: (none)`, and a note naming the missing verifier. **Never spawn an agent that is absent from the listing** — the listing, not the roster table, is the truth about what exists.

3b. **Guard unreachable tooling.** A built verifier is not a usable one. For each row, read the family's `Required tooling` class from `registry §2` and check this session's MCP roster for a server of that class:

   - **browser automation** absent → `verdict: NEEDS-HUMAN`, `agent: (none)`, note naming the missing class. Do **not** spawn.
   - **design-tool MCP** absent → `verdict: not-verified`, never a pass.
   - **none — filesystem only** → nothing to check.

   Neither case hard-stops the run; the other lanes proceed. Check the **class**, not a product name — any browser MCP satisfies `browser automation`, and hardcoding one server here would re-couple the router to a single stack.

   > **Why this is a separate guard from step 3.** Step 3 asks *does the agent exist*; this asks *can it actually observe*. The gap between them is the worst state in the system: a present agent file with an absent tool still returns a confident row, and that row reads as observed evidence. The failure it prevents is concrete — a verifier lacking hover/evaluate tools reporting an interactive-state criterion from reading stylesheets rather than from observation.
4. **Apply `registry §5`** — the not-observable list — to every row regardless of family. A match is `NEEDS-HUMAN` with the entry's reason quoted, whatever the code suggests.

**An AC that maps to no family is a legitimate outcome, not a failure of the run.** Criteria like *"the code should be maintainable"* carry no evidence family. Give it **one row** with `family: (unclassifiable)`, `agent: (none)`, `verdict: NEEDS-HUMAN`, and a note saying why it carries no evidence family. Do **not** stretch a classification to fit, and do **not** let the Phase-3 completeness assertion read it as a bug — an unclassifiable AC *has* its row.

---

## Phase 1 — Gate

Print, in this order:

1. `SUBJECT: <resolved | (unresolved)>` and `GATE_STATUS: <green | not-run | unknown>`.
2. `BASE_URL: <value | (unresolved)> (<reason>)` and `BUILD_SKEW: <the probe's line, verbatim>`. These print **here**, before the table and therefore before the approval — the environment a matrix was verified against is part of what the human is approving, and it is unrecoverable afterwards.
3. The classification table:

   | AC | Criterion (short) | Family | Verifier | Lane | Pre-verdict |
   |---|---|---|---|---|---|

4. Then **stop and ask for explicit approval.**

State plainly: **nothing has run yet**; correcting a misclassification, a wrong `SUBJECT`, a wrong `GATE_STATUS`, or a wrong `BASE_URL` right now is free. Do not proceed on silence, on a "looks good" that arrived before the table, or on an approval of something else.

> **Row cap.** The table is never truncated — every AC gets its row even at forty of them. A dropped row is the exact failure this command exists to prevent, so the usual "keep it scannable" rule yields here. Shorten the *criterion text* column instead; never the row count.

---

## Phase 2 — Verify

**Lanes P and S are built; Lane I is still guarded.** Never write or improvise dispatch for a verifier that is not in the injected listing — the Phase-0 guards decide what runs, not this section.

- **Lane P** (parallel, browser-free, non-mutating) — spawn each built verifier **once**, with only its own family's `AC_SUBSET` (a JSON object `{ac_id: "AC text"}`), plus `SUBJECT` and `GATE_STATUS`. Several Lane-P agents may run concurrently because nothing they touch is a singleton.
- **Lane S** (sequential) — exists because **a browser session and a working tree are singletons**; two concurrent drivers corrupt each other's evidence. Dispatch rules below.
- **Lane I** (inline in this session) — exists because **some MCP servers are reachable only from the parent session**, never from a spawned sub-agent. Still guarded by Phase 0: its verifier is not in the injected listing, so its rows resolve to `NEEDS-HUMAN`.

### Lane S dispatch

**Run Lane S after every Lane P agent has returned, and run at most one Lane S agent at a time.** This is not a scheduling preference — it is the constraint the lane exists for.

**Preflight, once, before the first browser verifier:**

1. **Tooling** — is a server of the `browser automation` class in this session's roster? (Phase 0 step 3b already resolved this; do not re-decide it here.)
2. **Liveness** — can the browser answer a single navigation within **~60 s**? Anything slower is a hung driver, not a slow one.
3. **Neighbours** — count already-running browser MCP servers using `qa-env.json → browser_mcp_process_pattern`. **Record the count; never gate on it.** It is diagnostic context for a collision, not permission to proceed.

**On a preflight failure — a timeout, or a profile reported as already in use — abort the lane:**

- Mark every criterion routed to Lane S as `NEEDS-HUMAN`, quoting the actual error in `notes`.
- **Continue Lanes P and I.** One dead lane is not a dead run.
- **Never retry in a loop.** Two sessions contending for one browser profile can burn tens of minutes and will not resolve themselves; the failure needs a human, and a retry loop is what stops it from reaching one.

**What to pass:** `AC_SUBSET`, `SUBJECT`, `GATE_STATUS`, the router-resolved `BASE_URL`, and `MOUNT_TARGETS` built from `qa-env.json → component_mount_url_template`. **If that template is empty, skip the lane** and route its criteria to `NEEDS-HUMAN` with `no component mount point configured` as the reason. A project with no way to mount a component in isolation is a normal state — say so rather than pointing the verifier at a guessed route.

**Collect each agent's JSON array** per `registry §6`. If it does not parse: retry **once** with the same subset. Still failing → that agent's ACs become `NEEDS-HUMAN` with the parse failure quoted in `notes`. **Never silently drop an agent's ACs** — a missing row reads as approval.

---

## Phase 2.5 — Self-audit

For **every `FAIL`** and **every absence-based `NEEDS-HUMAN`**, answer three questions explicitly, in writing:

1. Was it confirmed by a **second independent method**? (Two greps over the same file are one method.)
2. Is the evidence **concrete observed values**, or a single artifact that could itself be wrong?
3. Is the **severity honest** — would you defend `blocker` to the person whose release it stops?

Then emit a line:

```
DECISION: KEEP        — <finding> — confirmed by <method 1> + <method 2>
DECISION: DOWNGRADE → NEEDS-HUMAN — <finding> — single method (<the one method>), not presentable
```

**Hard rule: a `FAIL` resting on a single method or a single artifact is not presentable.** Downgrade it. Retracted findings cost more trust than missed ones.

Log every downgrade in the row's `notes` — the trail travels with the row into the matrix. **Never silently drop a finding.**

This phase is **auto-applied, with no user gate**: grilling governs evidence *quality*, while the human sign-off remains the acceptance authority. They are different decisions and only the second belongs to the human.

---

## Phase 3 — Aggregate + sign-off

**Collect the post-audit rows** — the rows as they stand *after* Phase 2.5, not the raw lane output. A downgrade that does not carry through to the matrix did not happen.

**Merge** multi-family rows per `registry §6` (`FAIL` › `NEEDS-HUMAN` › `PASS`), keeping **both source rows** in the matrix alongside the merged verdict.

**Completeness assertion.** Every `ac_id` assigned in Phase 0 appears **exactly once** with a merged verdict — including every `(unclassifiable)` row. A missing or duplicated id is a bug in the run: surface it at the top of the matrix. Never drop it to make the table tidy.

### The matrix file

Write to `.agents/handoffs/qa-<slug>-ac-matrix.md`, where `<slug>` is:

- the tracker key lowercased (`cs-79`), else
- the spec filename without its date prefix and `.md` (`qa-verify-ac-router`), else
- the backlog task id lowercased.

**If that file already exists, append `-2`, `-3`, … — never overwrite.** A previous run's matrix may already carry human sign-offs, and a sign-off is not reproducible.

The file is local markdown, so a table is fine here (only the tracker comment is constrained — see below). Include:

- A header stamping `SUBJECT`, `GATE_STATUS`, **`BASE_URL` + its resolution reason**, **`BUILD_SKEW`**, the AC source, and the date. A matrix carries a human signature; the environment it was verified against must be readable off the artifact, not reconstructed from a session nobody kept.
- **Every runtime / SSR / visual row carries the skew stamp** from the Step 0 state table — including the `not-applicable` case, which stamps the local host rather than a warning.
- One row per AC: family · agent · evidence · artifact paths · auto-verdict · severity (`FAIL` rows only) · **an empty sign-off box** for the human.
- The source rows behind any merged verdict.
- **The blocker tally:** count of `FAIL` rows with severity `blocker`. **≥1 blocker ⇒ not acceptable**, stated in those words.
- Every `FAIL` cites its `ac_id` and **quotes the clause it contradicts**.
- Findings that map to no AC go in a separate **"Out-of-AC observations"** block below the matrix — never mixed into AC rows, never counted in the tally.

**Git-exclusion warning.** `.agents/handoffs/` is kept out of git by a **per-clone `.git/info/exclude` rule, not `.gitignore`** — deliberately, so `@`-references still resolve. On a fresh clone that rule has not been run, so the matrix **is committable**. Check it and warn once:

```bash
git check-ignore -q .agents/handoffs/<matrix-file> || echo "handoffs are NOT git-excluded in this clone"
```

`check-ignore` honours `.git/info/exclude`, so a non-zero exit means the rule is missing. When it is, print the two-line setup from `.claude/commands/handoff.md`:

```bash
echo '.agents/handoffs/*'         >> .git/info/exclude
echo '!.agents/handoffs/.gitkeep' >> .git/info/exclude
```

Do **not** "fix" this by adding the path to `.gitignore` — that would hide handoffs from `@`-references, which is the whole reason the per-clone mechanism exists.

### The tracker comment

**Always prepare it** inside the matrix file, under a `## Tracker comment (prepared)` heading. Then **offer** to post it, and post **only** on explicit approval, via `mcp__atlassian__jira_add_comment(issue_key, comment)`.

Format — **headings + one-level bullets only**:

```markdown
## QA verification — <SUBJECT> (gate: <GATE_STATUS>)

- AC-1 — PASS — createInvoice takes the mapped Payment type (signature + 4 call sites)
- AC-2 — FAIL / blocker — decline reason dropped at the adapter, contradicts "shows the provider's decline reason"
- AC-3 — NEEDS-HUMAN — runtime-UI verifier not built in this repo

**Blockers: 1 — not acceptable.**
```

One bullet per AC: `AC-n — <verdict>[ / <severity>] — <one-line evidence>`, plus the blocker tally.

**Do not put a markdown table in the comment, and do not use `- [ ]` task lists there.** `.agents/reference/jira-mcp-atlassian.md` lists tables outside the ADF safe subset and flags task lists as risky — both render wrong or fail conversion. The *matrix file* is local markdown and may use tables and checkboxes freely; **only the comment is constrained.**

---

## Reading the output

| What you see | What it means |
|---|---|
| `PASS` | Evidence was gathered and it settles the criterion. Still needs your signature — evidence is not acceptance |
| `FAIL` + severity | Confirmed by ≥2 independent methods and survived Phase 2.5. `blocker` means not shippable |
| `NEEDS-HUMAN` — *verifier not built* | The criterion is real and unchecked. Nothing is wrong with the run; the lane does not exist yet |
| `NEEDS-HUMAN` — *not observable here* | `registry §5` matched. Making it observable needs tooling or access this repo lacks |
| `NEEDS-HUMAN` — *downgraded* | Something looked like a defect on one method only. Look at it yourself before believing or dismissing it |
| `family: (unclassifiable)` | The criterion carries no evidence family at all. A judgment call, not a check |
| A matrix that is entirely `NEEDS-HUMAN` | A **correct** outcome, reported plainly. It means this repo cannot currently observe any of these criteria |

---

## CRITICAL rules

- **Never spawn a verifier absent from the Phase-0 listing.** The filesystem is the truth about what exists; the roster only names intentions.
- **Never emit a `PASS` for something not observable in this repo.** `NEEDS-HUMAN` with the reason named is the honest verdict, and it is not a lesser one.
- **Never present a `FAIL` confirmed by one method or one artifact.** Phase 2.5 downgrades it and logs the downgrade.
- **Never drop an AC.** Every id from Phase 0 reaches the matrix — including unclassifiable ones, guarded ones, and ones whose agent returned garbage. Absence reads as approval, which is the failure mode this command exists to remove.
- **Never declare something absent without showing the negative search** — the globs, the commands, the paths.
- **Never re-run the quality gate.** Cite `GATE_STATUS`. `/gates:verify-implementation` owns that check and may have just passed on this exact tree.
- **Never mutate.** Both hard gates at the top are absolute — no source edit, no fix, no status transition, nothing before Phase 1 approval.
- **Never post to the tracker without explicit approval**, and never post a table or a `- [ ]` list when you do.

---

## Notes

- **Why the classification gate is a full stop.** Misclassification is the cheapest error to fix before verification and the most expensive after — the run spends its whole budget gathering the wrong evidence and produces a matrix that looks complete. Stopping is not caution; it is the only moment the correction is free.
- **Why build status is derived, not declared.** A hand-maintained "is it built?" column can lie at exactly the moment the guard exists to fire, and the run then errors out spawning an agent whose file does not exist. Reading `.claude/agents/` removes the failure mode instead of documenting it.
- **Why every sub-agent re-reads the registry.** A spawned agent starts with fresh context and does not inherit this session's copy. One shared file read independently is what keeps the router and its verifiers speaking the same protocol.
- **Why the browser lane is dormant by default rather than absent.** Lane S needs the project to describe how a component is mounted for observation (`qa-env.json → component_mount_url_template`), and many projects have no answer. Shipping it dormant is what makes a partial roster *honest*: an unconfigured or untooled lane degrades its criteria to `NEEDS-HUMAN` with the reason stated, instead of quietly not appearing. The two Phase-0 guards are the same idea at two altitudes — step 3 asks whether the verifier **exists**, step 3b asks whether it can **observe**. A row that passes both is the only kind that may claim evidence.
