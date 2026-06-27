---
name: codex-review
description: Spawn an independent Codex agent (codex exec, separate model) to review the current work, fed by a fresh /handoff brief. Works in two modes — review of CHANGES already made (diff), or review of a PROPOSAL before any code is written (idea). Codex orients itself by running the steps of /prime, then reviews on its own with zero steering. Streams a status heartbeat every ~3 min so you know it's alive. When Codex finishes, the main thread judges its review honestly and unbiased — a second model often catches what the primary thread missed.
argument-hint: [optional: focus hint, and/or "idea" | "diff" to force the mode — empty = auto-detect + fully open review]
---

# /codex-review — Independent Cross-Model Review (Codex)

Hand the current work to **Codex** (a different model, run via the `codex` CLI) for a genuinely independent review, then judge that review honestly back in the main thread.

**Two modes — the command reviews *work*, which is not always a diff:**

- **`diff` mode — review of CHANGES already made.** There is unpushed / uncommitted work; Codex reads the actual diff. This is the classic "did we do this right?" review, *after* implementation.
- **`idea` mode — review of a PROPOSAL before any code is written.** There is no diff — only a plan or design the main thread is about to apply. Codex reviews the *thinking* (is this the right change? simpler way? missed risk?) *before* it lands. A pre-implementation review catches a wrong direction while it's still cheap to change; a post-implementation review can only catch it after the cost is sunk.

The command **auto-detects** which mode applies and can be **forced** with an argument (see "Determine the mode"). Everything downstream — what `/handoff` must capture, the scope, and the Codex prompt — branches on the mode.

**Why a separate model:** the main thread has blind spots — it tends to defend its own choices and skim what it already "knows". A different model reading the same material cold catches what we missed. The whole value is independence, so **the prompt must not steer Codex toward any conclusion** — we give it context and scope, never opinions or expected findings.

## Preconditions

- `codex` must be on PATH (`codex exec` runs it non-interactively). If `which codex` fails → stop and tell the user to install/login Codex (`codex login`); do not fake the review.
- Project should be primed in the main thread already (you ran `/prime`). The command itself does **not** re-load project context — it only orchestrates Codex.

## Process

### 0. Determine the mode (`diff` vs `idea`)

Decide the mode **before** anything else — it drives every step below.

**Forced by argument (wins over auto-detect):** if `$ARGUMENTS` contains the bare token `idea` (or `proposal` / `przed`) → **idea mode**; if it contains `diff` (or `changes` / `po`) → **diff mode**. Strip that token before using the rest of `$ARGUMENTS` as the focus hint.

**Auto-detect (when not forced):**

```bash
git status --porcelain
git log --oneline @{upstream}..HEAD 2>/dev/null   # unpushed commits (empty if no upstream)
```

- Any uncommitted changes **or** any unpushed commits → **diff mode** (there is real changed surface to read).
- Working tree clean **and** nothing unpushed → **idea mode** (there is nothing to diff; the work is a not-yet-applied proposal).

State the chosen mode and *why* in one line to the user before continuing (e.g. `Tryb: idea (brak diffu — recenzja propozycji przed wdrożeniem)`). If auto-detect picks a mode that contradicts what the user clearly wants (e.g. they have a tiny unrelated diff but asked to review a fresh idea), trust the explicit intent — re-run with the forcing token.

### 1. Build the brief with `/handoff`

The handoff is the context Codex reviews. **What it must contain depends on the mode** — this is the load-bearing difference between the two paths.

**Diff mode — brief that references the diff.** Run **`/handoff`** (pass the focus hint through). It produces a tight, reference-not-duplicate summary of what was being worked on — exactly what a fresh reviewer needs *alongside the diff it will read itself*. The handoff states what the change is and why; it must not editorialize about quality or hint at bugs.

> If `/handoff` would be overkill (tiny one-commit change), you may instead write a 5-10 line brief inline into a scratch file under the scratchpad dir and point Codex at that. Default is `/handoff`.

**Idea mode — handoff must be SELF-CONTAINED (the proposal lives here, there is no diff to fall back on).** This is the critical adaptation. Normally `/handoff` is "reference, don't duplicate" — but in idea mode there is nothing to reference, so the handoff **must carry the full proposal** or Codex reviews a stub. Run `/handoff` with an explicit instruction to operate in *proposal mode* and write a self-sufficient brief that includes, concretely:

- **Problem / motivation** — what's wrong today, why this change is being considered (the "why", not just the "what").
- **The proposal in full** — the actual change being weighed: for a document/config change, the concrete before→after (paste the proposed new wording / structure, since there is no diff); for a design, the approach, the new/modified files, the data flow.
- **Alternatives considered + the current leaning** — the options on the table and which one the main thread currently favours, so Codex can challenge the *choice*, not just the chosen option.
- **Rationale and constraints** — why this direction, what rules/decisions/memory it must respect.
- **Open questions** — what's genuinely undecided (this is where Codex's independent read is most valuable).

The standard `## Where we are / What's done / Next step` skeleton still applies, but the proposal content above is mandatory and must be complete enough that **Codex needs only the handoff + the files the proposal touches** to judge it. Do **not** thin it to a one-liner that points at "the conversation" — Codex cannot see the conversation.

- Note the path `/handoff` wrote to: `.agents/handoffs/handoff-YYYY-MM-DD-<topic>.md`.
- In **both** modes the handoff states facts, decisions, and (idea mode) the proposal — it must not pre-judge quality or hint at the conclusion we expect. Independence is the product.

### 2. Determine the review scope

Establish, in plain terms, **what Codex is reviewing** so the brief is precise but not bloated. This too branches on the mode:

**Diff mode:**

- Run `git rev-parse --abbrev-ref HEAD`, `git log --oneline origin/<branch>..HEAD` (or `-10` if no upstream), and `git status --short` to identify the changed surface.
- Scope = the diff of this branch's unpushed/uncommitted work, plus whatever the focus hint narrows it to. Codex will read the diff itself — you are telling it *where to look*, not pre-digesting the code for it.
- Keep it bounded: name the files/commits in scope. Do **not** ask Codex to review the entire repo unless the user said so.

**Idea mode:**

- There is **no diff**. Scope = the proposal in the handoff, plus the **current state of the files the proposal would change** (so Codex can compare "what exists now" against "what is proposed" and judge the delta itself).
- Name those files explicitly so Codex reads the real current state, not its assumptions about it. Include the focus hint if the user gave one.
- The question Codex answers is forward-looking: *"is this the right change to make?"* — not *"was this change done correctly?"*.

### 3. Assemble the Codex prompt

Construct a single prompt string for `codex exec`. It must contain, in this order:

1. **Orientation (the "prime" step).** Tell Codex to orient itself in the project *before* reviewing, by reading and following the steps of this project's prime command definition — give it the literal path:
   > "First, orient yourself in this project: read `.claude/commands/prime.md` and follow its quick-mode steps (read `CLAUDE.md`, `.agents/memory/index.md`, `.agents/memory/project-brief.md`, `.agents/memory/architecture.md`). That tells you the project's layout, conventions, and where things live. Do not run it as a slash command — you don't have one; just read that file and do what it says."

   Codex has no `/prime` of its own, so we point it at the **file** and let it execute the steps. This is the user's explicit choice: give it the path to `prime.md`.

2. **The brief.** Point Codex at the handoff file by path: "Read `<handoff-path>` — it summarizes what this is and why." (Reference by path; do not paste the whole thing into the prompt.) In **idea mode**, add: "It contains the full proposal — there is no diff; the handoff *is* the change under review."

3. **The scope** — phrased per mode:
   - **Diff mode:** "Review the following changes: <branch diff / named files / commits from step 2>. Use `git diff origin/<branch>..HEAD` (and `git diff` for uncommitted work) to see them."
   - **Idea mode:** "Nothing has been implemented yet — this is a review *before* any change is made. The proposal is in the handoff. To judge it, read the current state of the files it would change: <named files from step 2>. Compare what exists now against what the proposal does."

4. **The task — deliberately minimal and unsteered.** Pick the variant for the mode:
   - **Diff mode:**
     > "Do an independent code review of these changes. Form your own judgment — I am not telling you what to look for. Report what matters: correctness bugs, risks, and anything that would bite us later, plus genuine simplifications. Weight correctness heavily on any sensitive path the project defines (per `CLAUDE.md` → Validation — e.g. payment, auth, webhook, license, locale/redirect routing, or domain-specific money/safety code). Cite findings by `file:line`."
   - **Idea mode:**
     > "Do an independent review of this *proposal*, before any code is written. Form your own judgment — I am not telling you what to look for, and I am not asking you to confirm it. The decision is still open, so the most valuable thing you can do is challenge it: is this the right change to make at all? Is there a simpler or safer way to reach the same goal? Does it fight the existing architecture, duplicate something, or break an assumption the project already documents? What does it miss, and what would bite us *after* we implement it this way? If it isn't sound, say what you'd do instead. Cite specifics by `file:line` (the current files) or by the exact section of the proposal."

   **Append this anti-forcing clause to whichever variant you used (verbatim — it is the counterweight to an adversarial mandate):**
   > "Calibrate to what is actually there. A clean result is a valid, valuable outcome — if the work is sound, say so plainly and stop; do NOT manufacture findings, pad the list, or inflate severity to look thorough. Report only what you can anchor to a concrete `file:line` or proposal section, with a real consequence. Each finding must earn its place: would it actually change the decision or the code? If not, drop it. Three real findings beat fifteen padded ones. State a clear bottom line — e.g. `sound, ship` / `sound with minor notes` / `revise` / `blocked` — and let it honestly be the clean option when the work deserves it."

5. **The heartbeat instruction:**
   > "This may take a while. Every ~3 minutes of work, print one short status line prefixed `STATUS:` (e.g. `STATUS: reading backlog diff, 2 findings so far`) so the caller knows you're still working and not hung. End with a clear `REVIEW COMPLETE` marker."

**Do not** add: expected findings, hypotheses, "I think X might be wrong", severity pre-assignments, or anything from the main thread's own opinion of the change. The prompt gives orientation + scope + an open task. Nothing more.

### 4. Run Codex in the background

Launch it as a **background Bash process** so the main thread stays responsive and can monitor the heartbeat. **Split the two outputs** so you never have to dig the review out of the orchestration noise:

```bash
codex exec --sandbox read-only \
  --output-last-message "$SCRATCH/codex-review.final.md" \
  "<the assembled prompt from step 3>" \
  > "$SCRATCH/codex-review.log" 2>&1
```

- **`--output-last-message <file>` is the key to a clean read.** It writes ONLY Codex's final message (the actual review) to that file. The `.log` keeps the full run — every `exec`, `rg`, file dump, and `STATUS:` line — which is large (hundreds of KB) and ~95% orchestration noise. **Read the review from `codex-review.final.md`, not the log.** (Same mechanism `/plan-feature` uses for its codex pass.)
- Do **NOT** add `--output-schema` here — this review is prose, not structured JSON, and (per `plan-feature.md`) `--output-schema` combined with `--sandbox read-only` has hung in testing. `--output-last-message` alone is safe with the sandbox.
- `--sandbox read-only` — a review must not mutate the repo. Never grant write/full-access here.
- Write the log to the session scratchpad dir (not `/tmp`).
- Run it with `run_in_background: true`. The harness re-invokes you when it exits; you do not poll in a tight loop.

### 5. Relay heartbeats while it runs

While Codex is working, surface its progress to the user so they know it's alive. **Heartbeats come from the `.log`; the review comes from `.final.md`** — keep the two reads separate:

- For progress: read only the new `STATUS:` lines from the **`.log`** (`rg '^STATUS:' "$SCRATCH/codex-review.log" | tail -1`) and relay one line: `Codex pracuje: <ostatni status>`. Do not read the whole log — it is huge.
- The **`.final.md`** is empty until Codex finishes (`--output-last-message` writes it once, at the end). Its appearance / non-emptiness is itself the "done" signal.
- Do **not** spin a busy-wait. If you need a fallback timer to re-check a long-running run, schedule a single long wakeup (≥3 min) rather than tight polling — the heartbeat in the log is the primary signal; the timer is just a safety net in case Codex goes silent.
- If no `STATUS:` line appears for well over 3 minutes and the process is still alive, tell the user it's quiet but not yet exited (don't kill it).

### 6. Judge the review — honestly, no bias

This is the point of the command. When the process exits (or `codex-review.final.md` becomes non-empty), **read the review from `$SCRATCH/codex-review.final.md`** — the clean final message, not the noisy `.log`. Then **evaluate it as a critic, not a defender**:

- **Verify, don't trust.** Check each finding against the real source of truth — in **diff mode** the changed code (`file:line`), in **idea mode** the current files the proposal touches *and* the proposal text in the handoff. A second model hallucinates too — confirm the claim holds before you accept it. Quote the real code or the exact proposal section.
- **Be honest about your own miss.** If Codex caught a real bug, a better approach, or (idea mode) a flaw in the *direction* the main thread overlooked, **say so plainly** — that is exactly why we ran it. Do not minimize a valid finding because it implicates earlier work in this session.
- **Be honest about its misses too.** Flag findings that are wrong, based on a misread, out of scope, or stylistic noise dressed as substance. Explain *why* it's a false positive, with evidence.
- **A clean review is a real result — relay it as one.** If Codex says the work is sound (no findings, or only ones you drop on verification), report that plainly: "Codex: czysto" with the bottom line. Do **not** go hunting for problems it didn't raise just to make the review feel substantial, and do **not** treat "few/no findings" as a failure of the review — a sound change *should* pass. The command's job is an honest verdict, not a guaranteed list of fixes.
- **Don't inflate severity — his or yours.** Keep each finding at its true weight when you relay it. A nit stays a nit; a `file:line` cosmetic note does not become a "MAJOR". Resist the pull (yours and Codex's) to escalate small things so the report looks busier. If you demote one of Codex's findings, say why.
- **No rubber-stamping either way.** Don't accept the review wholesale to seem agreeable, and don't reject it wholesale to defend the original work or proposal. Each finding stands or falls on the evidence.
- Where Codex and the main thread disagree, lay out both readings and give your verdict with the evidence. In idea mode, a "fundamental" objection (challenges the whole approach) is the most valuable kind — surface it prominently rather than burying it among nits.

### 7. Report

Produce a short, structured verdict (in Polish, per project language rules — findings cite English `file:line` or the proposal section):

```
## Codex review — ocena

**Tryb:** <diff (recenzja zmian) | idea (recenzja propozycji przed wdrożeniem)>
**Co Codex sprawdził:** <scope, 1 line>
**Werdykt ogólny:** <czysto / drobne / istotne problemy>

### Trafne (uwzględnić)
- [file:line | sekcja propozycji] <finding> — <dlaczego słuszne, z dowodem>

### Do korekty / wątpliwe
- [file:line | sekcja propozycji] <finding Codexa> — <dlaczego częściowo/całkiem nietrafne>

### Co główny wątek przegapił (uczciwie)
- <jeśli Codex złapał coś realnego, czego nie zauważyliśmy — wprost>

### Rekomendacja
- <co realnie nanieść / jak skorygować propozycję, co zignorować>
```

> In **idea mode** the recommendation feeds the decision *before* implementation — it should say whether to proceed with the proposal as-is, proceed with named corrections, or reconsider the approach. In **diff mode** it says what to fix in the code already written.

**If the review is clean** (Codex raised nothing, or nothing survived your verification), do not force the full skeleton — collapse it honestly:

```
## Codex review — ocena

**Tryb:** <diff | idea>
**Co Codex sprawdził:** <scope, 1 line>
**Werdykt ogólny:** czysto — <1 line: co potwierdza, że praca/propozycja jest solidna>

Codex nie zgłosił realnych problemów (lub zgłoszone odpadły przy weryfikacji — wymień je krótko w
„Do korekty / wątpliwe" jeśli warto). Rekomendacja: <proceed / merge / wdrażaj — bez sztucznych poprawek>.
```

A clean verdict here is a success, not a thin result — relay it as such and move on. Do not pad it with invented notes.

Then ask whether to act on the accepted findings (skip the question if the review was clean — there is nothing to act on). **Do not auto-apply** Codex's suggestions — surface them, recommend, and let the user decide (same discipline as the report-evaluation flow we already use).

## Rules

- **Pick the mode first, and say which.** `diff` reviews changes already made; `idea` reviews a proposal before any code is written. Auto-detect from git state, allow forcing via the `idea`/`diff` token, and announce the chosen mode to the user. Every downstream step branches on it.
- **Independence is the product.** Never seed the prompt with the main thread's opinion, expected bugs, or hypotheses. Orientation + scope + open task only. In idea mode this matters more, not less: present the proposal neutrally and invite Codex to reject it — do not frame it as already decided.
- **Read-only sandbox, always.** A review mutates nothing. Never pass `workspace-write` or `danger-full-access` to `codex exec` for this command.
- **Reference, don't paste — except the proposal in idea mode.** Normally point Codex at the handoff and the diff by path. But in idea mode there is no diff, so the handoff itself must carry the full proposal; that content is the one thing that legitimately lives in the handoff rather than being referenced. Still point at the *files* by path.
- **Verify every finding against source before accepting it** — Codex can be confidently wrong, just like the main thread. In idea mode, "source" includes both the current files and the proposal text.
- **Read the review from `--output-last-message`, heartbeats from the log.** The `.final.md` is the clean review; the `.log` is the noisy run trace (read it only for `STATUS:` lines). Never hunt for the verdict inside the log.
- **A clean review is a valid outcome — both sides honour it.** The Codex prompt says "calibrate, don't manufacture"; your judging step says "relay clean as clean". Neither side should pad findings or inflate severity to look thorough. The point is an honest verdict, not a guaranteed punch-list. This does NOT soften independence: Codex is still told to challenge hard and you still verify every claim — calibration is the opposite of rubber-stamping, not a relaxation of it.
- **Judge fairly.** Honest credit when Codex is right (especially when it implicates our own work), honest pushback when it's wrong. No bias in either direction.
- **Never fake it.** If `codex` isn't available or errors out, say so and stop — do not write a "review" yourself and attribute it to Codex.
- **No attribution noise** in any commit that follows (project git policy).
