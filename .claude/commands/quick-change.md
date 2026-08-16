---
name: quick-change
description: The fast lane for small changes — a short in-session plan (no spec, no plan file), a mandatory independent Codex review of that plan BEFORE any code is written, then implement, /code-review (low effort), /deep-review, and the project's Validation gates. The review cannot be opted out of; it is skipped only when codex is not installed. For work where /brainstorm → /plan-feature → /execute is too heavy, but "just do it" is too risky.
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

> **Writes nothing to `.agents/`.** No spec, no plan, no handoff file. The Codex brief goes to the session scratchpad. The only thing this command changes in the repo is the code you asked for. (Memory reflection is deliberately omitted too — a change small enough for this lane rarely teaches a fresh Claude anything, and `/quick-change` should not develop a paperwork tail.)

---

## Phase 0 — Is this actually small? (the guard)

**Do this before planning anything.** A fast lane that swallows work it shouldn't is worse than no fast lane, because the skipped steps are invisible afterwards.

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
PROMPT="<the assembled prompt>" \
OUT="$SCRATCH/quick-change-codex.final.md" \
LOG="$SCRATCH/quick-change-codex.log" \
REPO="<repo-root>" \
bash .claude/lib/codex-bg.sh
```

**Lifecycle — do not invent one here.** Launch with `run_in_background: true` (never a trailing `&`) and follow the canonical polling contract in [.agents/reference/codex-spawn.md](../../.agents/reference/codex-spawn.md), which carries this command's `FIRST_CHECK` / `POLL_INTERVAL` / `HARD_KILL` row. The ceiling is short by design — a plan review for a small change that runs past it is hung, not thorough — and hitting it fails **open**: continue without the opinion and report it, never stall the lane.

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

Run `/code-review` at **`low` effort** over the files this run touched (Phase 0's snapshot), and apply what it confirms — the skill's `--fix` behaviour, same fixer channel `/check-implementation` uses.

**Why this exists, and why it is `low`.** Nothing else in this lane looks for a logic bug. Phase 2 reviewed a *plan*, so it cannot see a mistake made while executing it; Phase 4 states outright that it does not hunt bugs; Phase 5 only catches what the test suite already covers, and in this lane there is often no new test. That is a real hole, and one cheap pass closes most of it. `low` is the point, not a compromise — it returns few, high-confidence findings, which is exactly the trade a fast lane wants. **Never raise the effort here**: a change that needs `high` is a change that needed `/check-implementation`, and the honest response is to say so rather than to grow this phase.

Bugs before structure — the same ordering `/check-implementation` justifies: do not let `/deep-review` reshape code that a fix is about to rewrite.

---

## Phase 4 — `/deep-review`

Run [`/deep-review`](deep-review.md) over the files **this run touched** (Phase 0's snapshot, not everything dirty), **pipeline mode** — its own contract lists `/quick-change` Phase 4 as a pipeline caller, so it applies findings rather than only reporting them: it applies its high-conviction structural findings and records anything needing a human call under `NEEDS_HUMAN`. Structure only — file size, spaghetti growth, layering, comment noise, code-judo simplifications. It is not a bug hunt.

Carry every `NEEDS_HUMAN` note into the final report. Never swallow one.

---

## Phase 5 — Validation gates

Run the **Validation** block from `CLAUDE.md` verbatim, in order, stopping at the first failure (typically `{typecheck} && {lint} && {test}`). If that section is still a `{placeholder}`, fall back to the stack-detected equivalents and say which you used.

- **Green** → done.
- **Red** → fix and re-run, **at most twice**. Phases 3.5 and 4 both mutate code, so a red gate here is often their doing — check that first.
- **Still red after two attempts** → stop and escalate with the actual output. Do not grind, and do not report a partial pass as a pass.

---

## Phase 6 — Report

```markdown
## /quick-change: <one-line task>

Plan: <1 line — what was decided>
/code-review (low): <N błędów poprawionych — jakie | czysto>
Codex (idea): <czysto | N uwag, M uwzględnionych — co dokładnie złapał | BEZ OPINII: codex nie jest zainstalowany / codex nie zwrócił wyniku mimo ponowienia>
Zmienione pliki: <list>
/deep-review: <N poprawek zastosowanych | czysto>
Gates: <✅ zielone — komendy | ❌ + output>

NEEDS_HUMAN: <z /deep-review, albo "brak">
Poza zakresem, zauważone: <albo "brak">
<Uwaga: Phase 0 zgłosiła <przesłankę>, pojechaliśmy przez /quick-change na Twoją decyzję.>

Werdykt: <✅ gotowe do /commit | ❌ eskalacja: co blokuje>
```

Then stop. **`/quick-change` never commits** — the tree is left ready for `/commit`.

---

## CRITICAL rules

- **The Codex review is mandatory and has no opt-out.** No flag disables it, and no judgement call skips it. The single exception is a `codex` that is not installed — a missing tool, never a decision, always stated on its own line in the report. A run that produced code without a review it could have had is a broken run.
- **The review happens before the code, or it is not this command.** Never reorder Phase 2 after Phase 3 to "save time" — a post-hoc review of a fast fix is what this lane exists to replace.
- **Never seed Codex with your own conclusions.** Orientation + the proposal + open task. Nothing else.
- **Verify every Codex finding against real code before folding it into the plan.** A second model hallucinates too.
- **A fundamental objection stops the lane** — it goes to the user with a route to `/brainstorm` / `/plan-feature`, and is never patched around inline.
- **The Phase 0 guard always fires when a criterion is met**, and its result is always said out loud. The user may override it; the command may not skip it.
- **Writes nothing to `.agents/`, commits nothing.** The scratchpad brief is the only file it creates outside your code.
- **Never fake a Codex review, and never round a red gate up to green.**
