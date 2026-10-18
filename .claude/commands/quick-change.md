---
name: quick-change
description: The fast lane for small changes — a short in-session plan (no spec, no plan file), a mandatory independent Codex review of that plan BEFORE any code is written, then implement, /code-review (low effort), /deep-review, and the project's Validation gates. The review cannot be opted out of; it is skipped only when codex is not installed. For work where /brainstorm → /plan-feature → /execute is too heavy, but "just do it" is too risky. Supports a Claude supervisor with a delegated Codex worker.
argument-hint: "<what to change>"
---

# /quick-change — Fast Lane for Small Changes

The full pipeline (`/brainstorm` → `/plan-feature` → `/execute` → `/check-implementation`) is right for a feature and absurd for a two-file change. But the alternative people fall back on — "just do it" — is where the not-quite-good-enough quick fixes come from: no plan, no second opinion, no cleanup, no gate.

This command is the middle. **It costs one short plan and one review, and it writes nothing to the repo's knowledge layer.**

```
short plan (in chat) → Codex reviews the PLAN → implement → /code-review (low) → /deep-review → Validation gates
```

The load-bearing move is **where the review sits**: before the code, not after. A wrong direction caught while the plan is three bullet points costs a rewrite of three bullet points. Caught after implementation, the cost is already sunk and the pull is to patch it rather than redo it. That is `/codex-review`'s **idea mode**, and this command is essentially that flow with the ceremony removed.

> **Loader Convention.** Assumes `/prime` already ran. Do not re-read `CLAUDE.md`, `architecture.md` or the brief here.

---

## What this is NOT

- **`/execute`** — runs a written plan file from `.agents/plans/active/`. `/quick-change` has no plan file, by design; the plan lives in the conversation and dies with it.
- **`/check-implementation`** — the full quality loop (code-review → deep-review → gates → design gate → cross-model, up to 3 iterations) over already-written code. `/quick-change` reviews **before** writing, then runs one low-effort correctness pass and one structural pass after — no loop, no design gate, no second model on the diff. If a change deserves that loop, it does not belong in this lane (Phase 0).
- **`/plan-feature`** — produces a durable, grilled plan artifact. `/quick-change` produces a disposable one.

> **Writes nothing to `.agents/`** — except the invoked Task's `Status`/`Ref` cells in `.agents/backlog.md` after green gates (Phase 6). No spec, no plan, no handoff file. The Codex brief goes to the session scratchpad. Beyond those two cells, the only thing this command changes in the repo is the code you asked for. (Memory reflection is deliberately omitted too — a change small enough for this lane rarely teaches a fresh Claude anything, and `/quick-change` should not develop a paperwork tail.)

---

## Delegated execution

A `<supervisor>` (Claude) may delegate Phase 3 to a `<worker>` (Codex, clone `<worker-clone>`)
using the [AGENTS.md delegated execution contract](../../AGENTS.md#delegated-execution-supervisor--worker).
The supervisor owns the scope guard, plan approval and the final control gate; reviews run
in report-only mode on the clone and the worker applies their fixes. The pre-code review stays
mandatory. A worker handoff alone never means this workflow is complete.

**Two modes — the phases below say which applies:**

- **Solo** — the supervisor implements in its own checkout: Phases 3.5/4 mutate (`--fix`, pipeline mode).
- **Delegated** — the worker implements Phase 3 and the Phase 5 fixes in the clone. Phase 3.5 is
  `/code-review low` **without** `--fix` on `git -C <worker-clone> diff <base SHA>`; Phase 4 is
  a fresh Codex session running `/deep-review report-only <files>`, spawned through
  `.claude/lib/codex-bg.sh` with `REPO=<worker-clone>` (never the default `$PWD` — the
  supervisor's main checkout is dirty). Findings go to the worker as fixes to make. Fingerprint the
  clone with `.claude/lib/tree-fingerprint.sh` (`capture` before Phase 3.5, `compare` after
  Phase 4, run with the clone as the checkout) — the reviews are read-only, so it must match.
- The worker never edits the paths the project cannot validate in the clone (AGENTS.md → Delegation boundary).

---

## Team mode (quick planner)

**When it applies:** `.agents/team/session.json` exists and its `role` is `planner` — the team runs in `quick` mode. The supervisor's ticket is the request.

- **Phases 0–2 run as written.** On a Phase 0 hit, ask the developer (the planner is attended). If they do not continue → `bash .claude/lib/team-record.sh --verdict failed --message "too big for quick: <reason>"`, then stop.
- **After Phase 2, write the plan — do not implement.** The (revised) plan goes to `.agents/plans/active/<kebab-slug>.md`; this is the one exception to "Writes nothing to `.agents/`". Its minimal `/execute` shape:
  - `# Feature: <title>`
  - `**Source spec:** none (quick mode)`
  - `**Execution effort:** low|medium`
  - `## Feature Description` (Cel) and `## Solution Statement` (Podejście + odrzucona alternatywa + Ryzyko)
  - `## STEP-BY-STEP TASKS` — one `### {ACTION} <path>` per file, each with `- [ ]`, `- **IMPLEMENT**:`, `- **EXPECT**:` (`present` / `contains` …) and `- **VALIDATE**:`
  - `## VALIDATION COMMANDS` (Level 1 = `CLAUDE.md → Validation`)
  - `## ACCEPTANCE CRITERIA` (the one-sentence "done")
  - `## NOTES` with the Codex outcome line (`Codex: czysto` / the folded findings / `brak opinii — <reason>`)
- **Never** add a `## Execution Plan` section — the runner refuses it. `/gates:verify-implementation` counts the `- [ ]` anchors and checks the `EXPECT` lines, so a plan without them fails QA's gate.
- **Phases 3–6 belong to the coder and QA** — skip them here.

---

## Phase 0 — Is this actually small? (the guard)

**Do this before planning anything.** A fast lane that swallows work it shouldn't is worse than no fast lane, because the skipped steps are invisible afterwards.

**Task entry.** If the argument (trimmed) is a backlog Task id (`^E\d+-\d+$`) or a Jira key (`^[A-Z]+-\d+$`) equal to the leading `[A-Z]+-\d+` token of a `Jira` cell in `.agents/backlog.md` (a cell written by `/jira sync` may read `KEY (unverified)` — the key still counts), the task = that Task's title + its acceptance-criteria ids (verbatim, e.g. `E1-2.AC1`) + its `Traces`; announce `KEY → <Task id>` when it came from a Jira key. Remember the Task id — Phase 6 writes its status back. A Task id with no matching row → STOP: "`<id>` is not in `.agents/backlog.md`". A Jira key with no matching `Jira` cell → not a backlog Task: say "`KEY` is not synced to a backlog Task — no backlog write-back" and treat the argument as an ordinary request. The guard below **still applies**: an `M` Task can fail it (sensitive path, schema change, >5 files) — then say which criterion fired and recommend `/brainstorm <id>` instead. A legacy backlog (`## Work packages` heading or a `| Dependencies |` column instead of `| Size |` + `| Depends on |`) resolves the id read-only; Phase 6 will skip the write-back. A header matching neither shape is malformed → report it and treat the file as absent (no Task resolution, no write-back).

Read the request, look at the code it would touch, then check these. **Any hit → this is not a `/quick-change` job:**

- Touches a **sensitive path the project defines** (per `CLAUDE.md` → Validation — payment, auth, webhook, license, locale/redirect routing, or domain-specific money/safety code).
- Spans more than **~5 files**, or crosses more than one module/layer.
- Adds a **dependency**, changes a **data schema / migration**, or alters a **public contract** other code or people rely on.
- Needs a **design reference** to be judged (visual work with a Figma/spec source).
- You cannot state what "done" means in **one sentence**.

On a hit, say which one fired and recommend the real route:

```
To nie jest zadanie na /quick-change: <która przesłanka i dlaczego>.
Sugeruję: <"/brainstorm → /plan-feature" dla niejasnego zakresu | "/plan-feature" gdy kierunek jest jasny | "/check-implementation" jeśli kod już powstał>.
Chcesz mimo to jechać przez /quick-change?
```

**Then honour the answer.** If the user reaffirms `/quick-change`, proceed with the full flow and stop re-litigating — it is their call, and this command exists precisely because they know their codebase. Note the override once in the final report so the decision is visible later, and do not silently upgrade the lane behind their back.

> This guard is a **guardrail, not a shaping rule** — it always fires when a criterion is met. What is negotiable is what happens *after* it fires (the user decides); what is not negotiable is that it fires at all and is stated out loud.

**Snapshot the working tree here too:** `git status --porcelain`. Whatever is already dirty is **not yours** — Phases 3.5–6 act only on files *this run* touched. Both `/code-review` and `/deep-review` mutate code, so a review scoped to "the changed files" on a tree that was dirty at the start would rewrite someone else's uncommitted work and report it as this run's. If the pre-existing changes overlap the files you are about to touch, say so and ask before proceeding — that is the one case where the two cannot be separated.

**Also check `command -v codex` here, and say the result in one line** — `codex: dostępny` or `codex: brak na PATH — ta zmiana pojedzie bez drugiej opinii`. The check belongs *after* the scope guard (a too-large task goes to the right flow whether or not codex is installed) and *before* the plan, so the user learns the run will have no review while the cheapest response — switching to flow A — is still available. It never blocks: an absent `codex` is stated, not fatal.

---

## Phase 1 — The short plan (in chat, no file)

Write a plan that is genuinely short — **5–12 lines**, and it stays in the conversation:

- **Cel** — one sentence, and what "done" looks like.
- **Zmiana** — the files to touch and what happens in each, concretely enough to review (`src/x.ts: dodaj guard na pusty payload przed …`).
- **Podejście i odrzucona alternatywa** — the direction, plus the one option you considered and dropped, with the reason. *This is the part Codex reviews hardest; a plan with no alternative gives it nothing to push against.*
- **Ryzyko** — what could break, and what already covers it (existing test, type, guard) or does not.
- **Testy** — what gets a test and what deliberately does not, per `CLAUDE.md` → Validation test policy.

Do **not** start editing yet. Not one line.

*Yields on length* when the change is genuinely mechanical and a 3-line plan says everything true about it — pad nothing to reach the range. **The rejected alternative yields too**: when the change really admits only one sane approach, write `brak — zmiana mechaniczna` and move on. Inventing a straw alternative to satisfy the section gives the reviewer noise to push against instead of substance, which is worse than the empty line it replaces.

---

## Phase 2 — Codex reviews the plan (idea mode) — mandatory when `codex` exists

**There is no opt-out.** No flag skips this phase, and you never skip it by judgement — not because the change looks trivial, not because the plan feels obviously right, not to save time. The second opinion *is* what separates this lane from "just do it"; a `/quick-change` run that quietly dropped it is indistinguishable afterwards from the workflow this command was written to replace.

**Exactly two things can leave a run without the opinion, and neither is a choice:** `codex` is not installed (Phase 0 established this), or it failed to produce a result twice in a row (below). In both cases the run continues, and the report states the absence on its own line. Those are tool failures, not decisions — never present them as one, and **never fabricate a review** (project rule: never fake it).

**Write the brief to the scratchpad, not to `.agents/`.** Codex cannot see this conversation, so the brief must stand alone — the plan from Phase 1 verbatim, plus the paths of the files it would change and the current behaviour it changes. 10–20 lines into `$SCRATCH/quick-change-brief.md`. (`/codex-review` sanctions exactly this shortcut for changes where `/handoff` would be overkill — see its Step 1.)

Assemble the prompt: orientation (*"read `.claude/commands/prime.md` and follow its quick-mode steps; do not run it as a slash command"*) → *"read `$SCRATCH/quick-change-brief.md` — it is the full proposal; nothing has been implemented yet"* → the current files by path → then the **idea-mode task**, taken from [`/codex-review`](codex-review.md) Step 3 rather than reinvented:

> "Do an independent review of this *proposal*, before any code is written. Form your own judgment — I am not telling you what to look for, and I am not asking you to confirm it. The decision is still open, so the most valuable thing you can do is challenge it: is this the right change to make at all? Is there a simpler or safer way to reach the same goal? Does it fight the existing architecture, duplicate something, or break an assumption the project already documents? What does it miss, and what would bite us *after* we implement it this way? If it isn't sound, say what you'd do instead. Cite specifics by `file:line` or by the exact section of the proposal."

Append the anti-forcing clause verbatim (*"Calibrate to what is actually there. A clean result is a valid, valuable outcome…"* — `/codex-review` Step 3.4) and the `STATUS:` heartbeat instruction. **Seed nothing else** — no hypotheses, no "I think X is fine", no expected findings. Independence is the product.

Spawn through the shared wrapper, background, read-only, prose (no `SCHEMA`):

```bash
CODEX_EFFORT=high \
PROMPT="<the assembled prompt>" \
OUT="$SCRATCH/quick-change-codex.final.md" \
LOG="$SCRATCH/quick-change-codex.log" \
REPO="<repo-root>" \
bash .claude/lib/codex-bg.sh
```

**Lifecycle — do not invent one here.** Launch with `run_in_background: true` (never a trailing `&`) and follow the canonical polling contract in [.agents/reference/codex-spawn.md](../../.agents/reference/codex-spawn.md), which carries this command's `FIRST_CHECK` / `POLL_INTERVAL` / `HARD_KILL` row. The ceiling is short by design — a plan review for a small change that runs past it is hung, not thorough — and hitting it fails **open**: continue without the opinion and report it, never stall the lane. Effort is pinned `high` (the fast lane is fast because of its ceiling, not a weaker model). That contract includes the cancel-on-every-exit rule (`ScheduleWakeup stop: true`, polling loop step 3).

**Wait for it. Do not start implementing while it runs** — the entire value of this phase is that no code exists yet, and a half-written implementation turns an open question into something you defend. Relay `STATUS:` lines from the `.log` (never read the whole log).

Done means a **non-empty `.final.md`**, never process exit alone. An empty file at exit is a **failure, not a clean review** — retry once. Still empty → treat it exactly like an absent `codex`: continue without the opinion and say so plainly in the report. Do not ask the user for permission to skip; a question at that moment is the removed flag wearing a different hat, and it puts the decision on whoever is least able to judge what the missing review would have caught.

> `codex-bg.sh` truncates `OUT` before every spawn, so a non-empty `.final.md` is always *this* run's review. Before that fix, a second `/quick-change` in the same session read the previous run's file as its own and proceeded with a review of a different plan — the mandatory phase silently satisfied by a stale artifact. Do not reintroduce a done-check that trusts an untruncated file.

**Then judge it, as a critic of both sides:**

- **Verify before accepting.** Open the cited `file:line` and confirm the claim holds against the real current code. A second model is confidently wrong too. Fails inspection → drop it, with the reason.
- **Contradicts `decisions.md` / `patterns.md` / `CLAUDE.md`?** → drop it; our memory wins.
- **Survives?** → fold it into the plan and **show the revised plan** before implementing. Say plainly what changed and that Codex caught it — especially when it implicates your own plan.
- **A `fundamental` objection — "this is the wrong change to make"** — is the highest-value result this phase can produce, and it is **not** something to patch around. Stop, put it to the user, and recommend `/brainstorm` or `/plan-feature`. Do not implement a plan you now believe is wrong because the lane is called "quick-change".
- **Clean review is a real result.** Report `Codex: czysto` and move on. Do not manufacture plan changes to justify the wait.

---

## Phase 3 — Implement

Implement the (possibly revised) plan. Stay inside it: the plan is the scope, and a fast lane is exactly where scope creep does the most damage. Something out of scope that genuinely needs doing → note it for the report, don't do it.

Tests per the plan's test line and `CLAUDE.md` → Validation test policy. **In this lane, "no new test" is a legitimate answer** — Phase 0 already routed every sensitive path (payment, auth, webhook, license, routing) out of `/quick-change`, and those are exactly the tier the policy marks **MUST**. What remains is the tier where the policy itself says tests are optional. Write one when the change is logic with a real edge case; otherwise lean on the existing suite and say that in the report. Do not manufacture a test to look rigorous — and never use this paragraph to skip a test the policy demands. If Phase 0 was overridden and the change turned out to touch a sensitive path after all, **stop and say so** — that is `/check-implementation` territory, not this lane's.

---

## Phase 3.5 — Correctness (`/code-review`, low effort)

Run `/code-review` at **`low` effort** over the files this run touched (Phase 0's snapshot). **Solo:** apply what it confirms — the skill's `--fix` behaviour, same fixer channel `/check-implementation` uses. **Delegated:** run it **without** `--fix` on `git -C <worker-clone> diff <base SHA>` and relay the confirmed findings to the worker for Phase 5 (this replaces the `correctness-reviewer` agent on hosts that do not have it).

### When `/code-review` returns no opinion — one fallback, then STOP

**A valid opinion** (applies to the first review AND to the fallback) is either a findings list with
`file:line` references, or an explicit `CLEAN` that names the reviewed scope (base SHA plus the diff hash or the
reviewed file list). Anything else is **no opinion**: empty output, an error, "could not read the files", or text
that does not address the handed-over scope. The trigger is the content, not a tool-call count — a CLEAN that
names its scope is a success even with zero tool calls, and gets no fallback.

On **no opinion**, run exactly **one** replacement review:

- a fresh subagent/session with no author history, correctness-only, report-only, effort **low** (as the stage it
  replaces); it must state its actual model and effort;
- input = the brief/AC, the base SHA, `git diff <base SHA>` **and the full content (or explicit paths in the right
  tree) of every new untracked file of the assignment** — the diff alone does not show untracked files;
- artifacts (delegated: the assignment's artifacts directory `<artifacts-dir>/<id>`, outside every repository — never `.agents/`; solo: the session scratchpad): the reviewer's
  **full opinion verbatim**, plus the reviewed-tree metadata — base/HEAD, sha256 of the diff, list + sha256 of the
  untracked files — and the before/after tree snapshot. A summary alone is not an artifact.

**STOP** if the replacement also gives no opinion (same validity rule), or no fresh reviewer can be started:
record `Phase 3.5: BEZ OPINII → STOP` in the Phase 6 report with `Werdykt: ❌ eskalacja` and stop the lane (delegated: the supervisor reports it to the Operator). Unlike Phase 2, which fails **open** on a tool failure, a missing Phase 3.5 opinion fails **closed**. Never record it as CLEAN, never let the author
review its own work, never retry a second time.

**Why this exists, and why it is `low`.** Nothing else in this lane looks for a logic bug. Phase 2 reviewed a *plan*, so it cannot see a mistake made while executing it; Phase 4 states outright that it does not hunt bugs; Phase 5 only catches what the test suite already covers, and in this lane there is often no new test. That is a real hole, and one cheap pass closes most of it. `low` is the point, not a compromise — it returns few, high-confidence findings, which is exactly the trade a fast lane wants. **Never raise the effort here**: a change that needs `high` is a change that needed `/check-implementation`, and the honest response is to say so rather than to grow this phase.

Bugs before structure — the same ordering `/check-implementation` justifies: do not let `/deep-review` reshape code that a fix is about to rewrite.

---

## Phase 4 — `/deep-review`

**Delegated:** a fresh Codex session runs `/deep-review report-only <files>` on the clone (`codex-bg.sh` with `REPO=<worker-clone>`); it never edits, findings go to the worker. **Solo:** run [`/deep-review`](deep-review.md) over the files **this run touched** (Phase 0's snapshot, not everything dirty), **pipeline mode** — its own contract lists `/quick-change` Phase 4 (solo) as a pipeline caller, so it applies findings rather than only reporting them: it applies its high-conviction structural findings and records anything needing a human call under `NEEDS_HUMAN`. Structure only — file size, spaghetti growth, layering, comment noise, code-judo simplifications. It is not a bug hunt.

Carry every `NEEDS_HUMAN` note into the final report. Never swallow one.

---

## Phase 5 — Validation gates

Run the **Validation** block from `CLAUDE.md` verbatim, in order, stopping at the first failure (typically `{typecheck} && {lint} && {test}`). If that section is still a `{placeholder}`, fall back to the stack-detected equivalents and say which you used.

- **Delegated:** the worker runs the gate after its Phase 5 fixes; the supervisor re-runs it once on the final tree in Phase 6 — the worker's report alone never counts as green.
- **Green** → done.
- **Red** → fix and re-run, **at most twice**. Phases 3.5 and 4 both mutate code, so a red gate here is often their doing — check that first.
- **Still red after two attempts** → stop and escalate with the actual output. Do not grind, and do not report a partial pass as a pass.

---

## Phase 6 — Report

```markdown
## /quick-change: <one-line task>

Tryb: <solo | delegated — worker, klon <worker-clone>, branch, base SHA>
Fazy (owner · rc): <0–2 supervisor · 3 worker/supervisor · 3.5 supervisor · 4 codex · 5 worker/supervisor · 6 supervisor>
Plan: <1 line — what was decided>
/code-review (low): <N błędów poprawionych — jakie | czysto (zakres: base + hash diffu) | fallback: <model/effort> → <N uwag | czysto>, pełna opinia: <ścieżka> | BEZ OPINII → STOP>
Codex (idea): <czysto | N uwag, M uwzględnionych — co dokładnie złapał | BEZ OPINII: codex nie jest zainstalowany / codex nie zwrócił wyniku mimo ponowienia>
Zmienione pliki: <list>
/deep-review: <N poprawek zastosowanych | czysto>
Gates: <✅ zielone — komendy | ❌ + output>
Backlog: <id → DONE | id kept WIP (an active plan lists it: <path>) | no backlog | legacy — skipped | not a backlog Task>

NEEDS_HUMAN: <z /deep-review, albo "brak">
Poza zakresem, zauważone: <albo "brak">
<Uwaga: Phase 0 zgłosiła <przesłankę>, pojechaliśmy przez /quick-change na Twoją decyzję.>

Werdykt: <✅ gotowe do /commit | ❌ eskalacja: co blokuje>
```

**Backlog write-back (only when Phase 0 resolved a backlog Task, and only when the gates are green).** `/quick-change` has no plan file, so `DONE` is written directly here — still subject to the **whole-Task rule**: grep `.agents/plans/active/` for any file whose `**Tasks:**` line lists the Task id; none → set its `Status` to `DONE`; one or more → keep `WIP` (another plan still owns part of it) and say which. Legacy backlog → write nothing: "legacy WP backlog — write-back skipped; regenerate with `/setup:create-backlog`". Red gates → write nothing. Touch only that Task's `Status`/`Ref` cells, never the table structure; the write is left uncommitted for `/commit`. A Task with a `Jira` cell keeps its local `Status` as a cache only — never transition the Jira issue from here.

Then stop. **`/quick-change` never commits** — the tree is left ready for `/commit`.

---

## CRITICAL rules

- **The Codex review is mandatory and has no opt-out.** No flag disables it, and no judgement call skips it. The single exception is a `codex` that is not installed — a missing tool, never a decision, always stated on its own line in the report. A run that produced code without a review it could have had is a broken run.
- **A missing Phase 3.5 opinion fails closed.** One fresh fallback at most; a second no-opinion is a STOP, never CLEAN and never an author self-review.
- **The review happens before the code, or it is not this command.** Never reorder Phase 2 after Phase 3 to "save time" — a post-hoc review of a fast fix is what this lane exists to replace.
- **Never seed Codex with your own conclusions.** Orientation + the proposal + open task. Nothing else.
- **Verify every Codex finding against real code before folding it into the plan.** A second model hallucinates too.
- **A fundamental objection stops the lane** — it goes to the user with a route to `/brainstorm` / `/plan-feature`, and is never patched around inline.
- **The Phase 0 guard always fires when a criterion is met**, and its result is always said out loud. The user may override it; the command may not skip it.
- **Writes nothing to `.agents/` — except the invoked Task's `Status`/`Ref` cells in `.agents/backlog.md` after green gates — and commits nothing.** The scratchpad brief is the only file it creates outside your code.
- **Never fake a Codex review, and never round a red gate up to green.**
