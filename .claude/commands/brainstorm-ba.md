---
description: Requirements before Tasks — turn one input into a verified, approved requirements spec (coverage against the PRD, decisions, backlog, tracker and code; Task definitions; impact) under a 99 % certainty gate; writes nothing but the spec
argument-hint: "<pasted text | note or source path | tracker key(s) | Task or Epic id | URL | design link | waiting requirements spec>"
---

# Brainstorm BA: Requirements Before Tasks

## Input: $ARGUMENTS

**What this is.** The BA's command for requirement work: one input (a client message, a design change, a spike result, a question, a decision) in, one approved **requirements spec** out — what was verified against the current requirements, decisions, Tasks and code, what was decided, the Task definitions in full, and the changes to existing Tasks and requirements. It writes nothing but that spec; `/update-backlog` and the tracker commands consume it (Step 9). Designing a tool, a process or one Task's implementation is `/brainstorm`. **Precondition:** `/prime-ba` ran in this session (Loader Convention, `.agents/memory/index.md` — this command re-reads nothing it loaded).

<HARD-GATE>
A requirements spec only. No code. No write to the tracker, Confluence, the backlog, the PRD, memory, or any file in the repo tree or a code root other than the spec. Read-only everywhere else, the code roots included: no pull, no fetch, no checkout, no branch switch. Transport files of the prescribed reads (the tracker `--out` files, the adapter's own temporary directory) and of the review (schema, output, log) go to the session scratchpad and are not artifacts.
</HARD-GATE>

<CERTAINTY-GATE>
> **If you are not 99 % sure — ask. Never guess, never fill a gap with a silent default.**

- It covers the goal and the *why* of the input; every requirement, acceptance criterion and
  out-of-scope line; every verdict ("exists", "missing", "bug", "not in the design"); every
  attribution (who said or decided what); ownership and routing.
- **Order: verify first, then ask.** What a source can answer is read, not asked (Step 1). What is
  99 % certain from a cited source is *stated with its evidence*, not put to the BA for confirmation
  — that is what stops the run of one-word approvals.
- Below 99 % after verification → a question to the BA. The BA does not know → an **open question
  with an owner**; whatever depends on it is either a *first step* inside the Task (resolvable during
  delivery) or marks that Task `held` and keeps it out of the approved set.
- An assumption is never written into a Task as a requirement.

This gate is a guardrail, not a shaping rule — it has no yield (`.agents/memory/index.md` → Output-Discipline Convention). The asking rules of Step 2 are shaping rules and yield to it: no question budget may force a guess.
</CERTAINTY-GATE>

## Evidence rule

Every factual claim in the spec cites a source read **in this run**: `<repo>@<sha>:<path>:<line>` · tracker key + comment author + date · PRD / discovery id · `D-n` / `AD-n` · spec or note path · a rendered design frame. A claim relayed by someone else (a developer's plan, a QA note, a pasted message) is written as *reported by <author>*, never restated as fact. Unverifiable → `[unverified]`, and it goes through the CERTAINTY-GATE — never an unstated assumption.

**Code evidence comes only from committed objects at the recorded sha**, through hardened, filter-free reads (the prefix of `prime-ba.mjs` `gitReadWith`):

- `GIT_NO_REPLACE_OBJECTS=1 git --no-optional-locks --no-replace-objects -c core.fsmonitor=false -c core.hooksPath=/dev/null -C <root> cat-file blob <sha>:<path>`
- the same prefix with `grep -n <pattern> <sha> -- <path>`, and with `ls-tree -r --name-only <sha> -- <dir>`

Never `git status`, `git diff` or `git show` against the working tree — they can run the checkout's fsmonitor or filter drivers, or refresh the index (`.claude/lib/prime-ba.mjs` `gitReadWith` / `refState` avoid them for that reason). The `Read` tool on working-tree files is navigation only. When the session's `/prime-ba` `CODE_ROOT` row for a root is not `clean` (`dirty` or `dirty=unknown`), a claim only the working tree supports is written `[unverified — uncommitted]` and goes through the CERTAINTY-GATE — never cited as `<repo>@<sha>:path:line`.

## Process

### Step 0 — Input, environment, lane

Refusals, in this order:

1. **Team clone** — `.agents/team/session.json` or `.agents/team/team.json` exists → "BA work is not
   a team stage (`.agents/specs/ba-profile/decisions.md` D-A16)" — stop.
2. **Empty argument** → ask for the input (pasted text, a path, tracker key(s), a Task or Epic id, a
   URL, a design link). Never pick a backlog Task, never "the next free Task".
3. **No `/prime-ba` in this session** → ask for it, then continue.

**Resume.** The argument is a requirements spec (`**Kind:** requirements`) whose `**Status:**` starts with `Waiting —` → read it, take the reply from the invocation or the chat, and resume at Step 1 for the rows its open question affects, plus every row whose `**Verified against:**` revision moved while it waited (a Task that shipped or became protected meanwhile is judged again); the rest of the spec stands. A reply that opens a new question keeps it `Waiting`, the new paste-ready text replacing the old. A `Draft` one is a run that stopped before Step 8 → read it, re-run Step 1 for the rows whose `**Verified against:**` revision has moved, and continue at Step 4 with the spec as it stands — never a second spec for the same input.

**Backlog format** — read the Task table header of `.agents/backlog.md` once, testing in this order:
`Wave` / `Slice` and no `Scope` → pre-Scope (such a header may carry `| Size |` and `| Depends on |`
too) → stop: "run `node .claude/lib/backlog-migrate.mjs --write` first"; else `| Size |` and
`| Depends on |` → `new-format` (a pre-detail refusal of the checker in Step 1 stops the run with the
checker's message); a `## Work packages` heading or a
`| Dependencies |` column, or neither shape → `legacy` (its rows are context only, without checker
criteria — named under *Not verified*); no file → `absent`.

**Environment line**, printed once:

`backlog=<new-format|legacy|absent> · tracker=<jira|github|none> · code=<name@sha[, behind n]… | none> · design=<source|none>`

Tracker from `bash .claude/lib/team-tracker.sh which`; code roots from the session's `CODE_ROOT`
rows (this repo when it holds source, plus `ba.code_repos`), each sha read now with
`git -C <root> rev-parse HEAD`, behind from the row; design = a design link or file the input names.
Every absent surface is named, so the BA sees what the verification could not cover.

**Lane** — one line the BA can overrule: *new scope → Tasks* · *change to existing Tasks* (after a
spike, a decision, a reply) · *verification* (a design, a review or the code against Tasks) ·
*readiness* ("can the team start X?"). Any lane may end in the waiting exit (Step 2).

**When not to run** — a small edit with no open decision and nothing below 99 % → say so and name the
direct command (`/update-backlog`, `/jira update`, a tracker comment); a tool or process to build →
`/brainstorm`. Stated, never silently switched.

### Step 1 — Existing-state verification

Mandatory, before any question or proposal. Whenever a backlog, a tracker or a code root exists,
establish **what is already there** for the area the input touches, on four surfaces:

1. **Requirements** — the PRD register (`R-n` / `G-n` / `NFR-n` with their states), discovery flows
   and open `Q-n`, the brief's non-goals.
2. **Decisions** — the PRD `## Change log` (`D-n`), `.agents/memory/decisions.md`,
   `docs/architecture.md` `AD-n` (binding unless draft or superseded), earlier specs on the same area
   (design and requirements), the effective meeting notes, and in each code root its own recorded
   decisions (`decisions.md`, ADRs, `patterns.md`, `docs/coding-standards.md`) when present.
3. **Tasks** — backlog rows (withdrawn rows and `X-n` outside rows included). Each affected Task's
   criteria and protection come from the checker, never re-derived:
   - `node .claude/lib/backlog-check.mjs --next-ids <Task ids>` → per Task `current` and `source`.
     **The active criteria are the `current` entries with `withdrawn: false`**; a withdrawn entry is
     history and grounds no verdict; so is every criterion of a withdrawn Task (`--impact` →
     `withdrawn: true`) — never a `covered by` or `extends` target. `source` names where they live — an approved spec in `Ref`
     outranks the Epic file, and comparing code with an Epic-file criterion a later spec replaced
     yields a false "bug" or "covered".
   - `node .claude/lib/backlog-check.mjs --impact <ids>` → protection reasons, dependents, outside
     rows, tracker keys. The reasons are taken as given, with one resolution the checker leaves open
     (it does not read Jira status): a `jira key` reason is resolved by `/update-backlog` →
     Protection — live status in the project's backlog / waiting set and no other reason →
     unprotected; tracker unreachable → stays protected (say so once). No id is allocated here.
   - Tracker issues in every state (open, in progress, done, waiting): github →
     `bash .claude/lib/team-tracker.sh list --state all --out <scratchpad>/issues.json`, then
     `bash .claude/lib/team-tracker.sh show <key> --out <scratchpad>/<key>.json` per directly
     affected issue (its comments); jira → `jira_search` with no status filter, `limit=50`, paged
     with `start_at` until a page returns fewer than 50 (`.agents/reference/jira-mcp-atlassian.md`),
     then per directly affected issue the comment read of `.agents/reference/tracker-comments.md` §2
     (`jira_get_issue(…, include="comments", comment_limit=50)` — always pass `include`); none →
     nothing. A page error, a comment count at the limit, a Jira comment read §3 of that reference
     rates `possibly-truncated` or `unknown` (an empty MCP list without paging metadata) or a `gh`
     exit 4 is an **incomplete read**: named under *Not verified*, and every verdict that depends on
     it goes through the CERTAINTY-GATE — never "not found". Local drafts under `.agents/jira/` too.
4. **Code** — what the system does today in that area: the behaviour, where it lives (modules,
   components), what is configurable versus hardcoded, which shared pieces a change would touch,
   which tests pin the behaviour, and the recent history of the area (`git log` on the paths, with
   the read prefix of the Evidence rule).

**Output — the coverage and consistency table**, one row per requirement item or candidate, each
with its evidence. The verdicts, verbatim — a row may carry two (`covered by E1-2` plus
`partly implemented`):

- `covered by <Task/key>` — an active criterion of that Task or issue already asks for it.
- `extends <Task/key>` — the same feature as that Task, but beyond its active criteria or against
  one of its out-of-scope lines. With a backlog it becomes that Task's `edit` when the Task is
  unprotected and a `delta-linked` Task when it is protected — never a free-standing `add`.
- `implemented, no Task` — the code does it and no Task or requirement asks for it.
- `partly implemented` — the code does part of what an active criterion asks (it stores a value the
  criterion also shows, say); the row names the criterion and the missing part.
- `new` — no Task, issue or code covers it, and it extends no existing Task.
- `conflicts with <D-n | AD-n | R-n | observed behaviour>` — it contradicts the named source.

Consistency rules:

- A proposal that contradicts a recorded decision, an active requirement or delivered behaviour is
  **never applied silently**: it becomes a question quoting both sources; when the BA chooses the
  change, an explicit supersede proposal (a `D-n` through `/update-backlog`; an `AD-n` is flagged for
  the architect or the development lead — not the BA's to overturn alone).
- Code and Task disagree → classified with the evidence: *bug candidate* (names the violated
  criterion — no bug without one), *undocumented behaviour*, or *stale Task*.
- Already implemented or already covered → no new Task: "use existing" plus the key.
- A delivered or in-progress Task touched by the change is not rewritten: a delta Task or a context
  comment, matching `/update-backlog`'s protection rule.

Reading code at scale:

- Navigate from the map (`architecture.md`, `system.yaml`, LSP symbols); sweep only the areas the
  input touches; delegate a wide sweep to read-only sub-agents with a fixed return shape:
  `claim · verdict · path:line · confidence`.
- A sub-agent's finding is a *candidate*: every code claim that ends in a criterion or a verdict is
  re-read by the main session at the cited lines before it is written.
- Rules for the known traps: judge "does X exist?" by what a placement *does*, not by what a
  component *supports*; judge it from the shared library, not from the ticket list; a design claim
  needs the rendered frame; a relayed message is not the thread.
- Record the sha of every code root verified against; a root behind its upstream is reported with
  the count and a `/pull` recommendation before the verification is trusted; behind unknown (no
  fresh fetch) → said, the sha still recorded.

No backlog, no tracker and no code root → `Verification: nothing to verify against — greenfield`, and
go on. The step is never skipped silently.

### Step 2 — Certainty pass and questions

- List what is still below 99 % after Step 1: the why, scope edges, ownership and routing (our Task ·
  another team's work → an outside row · the client's task · a question for a stakeholder · a tester
  list), every conflict found, granularity forks.
- Show the findings first, then ask — the BA sees why each question exists. The message that asks
  carries, above its questions, the environment line, the lane and the Step 1 coverage and
  consistency table with every row's evidence (a dialog takes the table in the message before it).
- A conflict question quotes both sides verbatim next to the input's point: the recorded source (the
  `D-n`, `AD-n` or `R-n` text) and, when the code shows the behaviour, the code evidence
  (`<repo>@<sha>:<path>:<line>`, the symbol, what it does).
- Independent questions go into one `AskUserQuestion` call (up to four); dependent ones in order.
  Each carries the recommendation first and, where it uses design or technical jargon, a
  plain-language line with a concrete on-screen example. In the project's communication language.
- More than eight open points → offer one numbered list for a batch answer instead of eight dialogs.
- These are shaping rules — they yield to the CERTAINTY-GATE.

**Waiting exit.** An answer only someone else can give → write the spec (Step 5 template) with `**Status:** Waiting — <role>`, the question as paste-ready text for that person under `## Open questions`, run the stage end marker, and stop. `/brainstorm-ba <spec>` with the reply resumes it (Step 0 → Resume). Drafting other stakeholder messages is not this command's job.

### Step 3 — Shape the Tasks

- Epic → Task only; user-story style; each criterion testable and observable; explicit out of scope;
  an unknown that delivery can settle is a *first step* inside the Task, not an open question; reuse
  or extend an existing unprotected Task before adding one; split what exceeds the largest size,
  merge cohesive small ones.
- Project rules are **read, not hard-coded**: sizes and split patterns from the backlog skill
  (`.claude/skills/backlog/`); body shape by destination — tracker github (and none):
  `.claude/skills/create-task/references/task-shape.md`; tracker jira: the Jira skill's description
  templates (`.claude/skills/jira/references/`); grooming patterns from `.agents/memory/domain/jira.md`
  and the BA's `user-profile.md` when present. A source that is absent (the jira skill pruned by
  `/setup:start`, no `domain/jira.md`) is skipped and named once — never invented.
- The verification shapes the text: "extend the existing X" versus "create X", literal technical
  values where a developer needs them. Whether repository paths appear in tracker text is the
  project's style rule; the spec's evidence always keeps `path:line`.
- **With a backlog** (`new-format`): each change is an `/update-backlog` intent, named verbatim —
  `add`, `edit`, `delta-linked`, `split`, `merge`, `withdraw-task`, `withdraw-requirement`,
  `outside-add`, `outside-edit`, `outside-remove`, `move-outside` (`/update-backlog` Phase 3) — with
  the proposed placement (Epic, Scope, Size, `Depends on`, `Relates`, `Traces`), so its Phase 3 reads
  them at high confidence. A protected Task is never an `edit` target: `delta-linked`.
  No criterion id is allocated here — `/update-backlog` allocates from `nextAc`.
- **Without a backlog** (or `legacy`): each Task definition is a complete body for the tracker's
  ad-hoc create path (Step 9); the impact list names the existing keys to edit or comment.
- Every Task carries a state: `ready`, or `held — <Q-ref>` (an open question it depends on keeps it
  out of the approved set).

### Step 4 — Present once

One pass, no per-section approval, in the project's communication language: the input restated with its why; the coverage and consistency table; the decisions table (decision · recommendation · basis) where the BA marks only the exceptions; the Task definitions **in full**, never summarised; the impact list with protected Tasks flagged; open questions with owners; what was not verified and why.

### Step 5 — Write the requirements spec

`.agents/specs/YYYY-MM-DD-<slug>.md` (English; quotes verbatim in their original language):

```markdown
# Requirements: <topic>

**Date:** YYYY-MM-DD
**Status:** Draft | Waiting — <role> | Approved
**Kind:** requirements
**Lane:** new scope → Tasks | change to existing Tasks | verification | readiness
**Verified against:** <root>@<sha> (behind <n> | up to date | unknown) · scope rev <Current> · backlog <fingerprint> · tracker read <UTC> | nothing — greenfield
**Sources:** <every source read in this run, one per `·`>
**Cross-model review:** ran — <verdict> | skipped — codex not on PATH | skipped — <BA's reason>

## Summary
## Input            — provenance: who sent it, when, where; quoted verbatim
## Why
## Verification     — the coverage and consistency table: item · verdict · evidence
## Decisions        — decision · chosen · basis · each rejected option with its one-line reason
## Tasks            — per Task: state (ready | held — <Q-ref>), placement or tracker target, the full body
## Backlog and tracker impact — `/update-backlog` intents (backlog) or keys to edit/comment (no backlog); protected Tasks flagged
## Conflicts and supersede proposals
## Open questions   — question · owner · what depends on it · paste-ready text when Waiting
## Not verified     — surface · why
```

It is **not** a design spec, and nothing may mistake it for one: no `Architecture`, `Files`, `External dependencies`, `Appetite` or `External docs required` section; no `**Tasks:**` header line (that line binds a design spec or a plan to backlog rows); it is never written into a Task's `Ref` cell and no `Status` cell is touched — a non-empty `Ref` marks a Task protected, and an approved spec in `Ref` owns its criteria (`backlog-check.mjs` resolver, `/update-backlog` → Protection). `/plan-feature` refuses it.

### Step 6 — Self-review

Read the spec once more and fix inline: placeholders; internal consistency; **cross-Task consistency** over the siblings in the Epic and every Task on the impact list — one term per thing, no overlapping scope, no criterion contradicting another Task's criterion or out-of-scope line; every claim has evidence or `[unverified]`; every sub-99 % item is answered or is an owned open question; no `held` Task's open point appears inside a Task body as text.

### Step 7 — Cross-model review (optional)

Optional in the BA-profile sense (`.agents/specs/ba-profile/decisions.md` D-A17): runs when `codex` is installed, is never a condition of the verdict, and the BA may skip it by stating a reason → `**Cross-model review:** skipped — <reason>`. Mechanics: [.agents/reference/spec-cross-review.md](../../.agents/reference/spec-cross-review.md) with `BOUND_SECTIONS` = `## Tasks` + `## Decisions` + `## Open questions`, `WAKEUP_PROMPT` = this `/brainstorm-ba` input verbatim, `CONTINUE_TO` = Step 8, `STEP_LABEL` = `Step 7`. Absent codex → `**Cross-model review:** skipped — codex not on PATH`.

The prompt (fill `<spec-path>`):

> You are an independent reviewer of a REQUIREMENTS SPEC: `<spec-path>` — the verified Task
> definitions a business analyst turned one input into. First read `CLAUDE.md`,
> `.agents/memory/index.md` and `.agents/memory/project-brief.md`, then the spec and every source it
> cites (PRD ids, `D-n`, backlog rows and Epic files, specs, code at the cited `<repo>@<sha>:path:line`).
>
> Look for: incompleteness against the quoted input (a point of the input with no row, no Task and no
> open question); contradictions with recorded decisions (`D-n`, `AD-n`, `decisions.md`) or with the
> code; acceptance criteria that cannot be tested or observed; Tasks that duplicate an existing Task or
> issue; factual claims stated without evidence or marked verified when the cited source does not say
> it.
>
> **Bar for reporting:** every finding cites concrete `evidence` (a spec section, a `file:line`, a
> decision id) and gives a `consequence` and a `fix`; drop what you cannot anchor. Set
> `verdict: "ship"` with no findings if the spec is sound.
>
> **Classifying `kind` — the test is what the fix *changes*, not what it mentions.** Check every fix
> against the spec's `## Tasks`, `## Decisions` and `## Open questions`. `patchable` leaves what gets
> built untouched (a contradiction, a false claim about the repo, an ambiguous wording of an agreed
> criterion, a missing citation). `fundamental` changes or adds a Task, a criterion, an out-of-scope
> line or a decision, or answers an open question.
>
> **You are read-only.** Do not edit, create or reformat any file and run no mutating command. Output
> ONLY per the schema: exactly the keys `verdict` and `findings`.

**No memory write** (HARD-GATE): a recurring requirements gap the review surfaces is named in the
final report as a suggested lesson for the BA to record separately — never written to
`.agents/memory/`.

### Step 8 — Approval

The single gate. Present, in one message: the decisions with their defaults, the Task bodies, the
impact list, the conflicts, and the review's applied edits and 🔶 rethink signals. Then one
`AskUserQuestion`, recommendation first:

- **Approve** → `**Status:** Approved`, then Step 9.
- **Correct** → name what to change; fix it, re-run Step 6, return here.
- **Wait** → `**Status:** Waiting — <role>` with the paste-ready question (as the Step 2 exit); stage
  end marker; stop.

> This gate is a guardrail, not a shaping rule — it has no yield condition. There is no team-mode
> caller (Step 0 refuses a team clone), so it always asks.

### Step 9 — Terminal gate

Print the one row that matches `backlog × tracker`, name the next command, and stop:

| Backlog | Tracker | New Tasks | Changes to existing issues |
|---|---|---|---|
| yes | jira | `/update-backlog <spec>` → `/jira draft` → `/jira send` | `/update-backlog <spec>` records them (protected Tasks → delta Task, `Jira refresh` marker); the Jira side through `/jira resync` / `send --ops-only` |
| yes | github | `/update-backlog <spec>` → `/github-sync` | `/update-backlog <spec>`; `/github-sync` is create-only — edits to an existing issue are listed for the BA |
| yes | none | `/update-backlog <spec>` | same |
| no | jira | `/jira create` per Task (or `/jira bulk`) — **not** `/jira draft`, which reads backlog rows and needs the namespace | `/jira update` / `/jira comment` per key |
| no | github | `/create-task <draft>` per Task | listed for the BA (no edit command) |
| no | none | the spec stays the local record | — |

`<draft>` is one `ready` Task's title and full body from the spec's `## Tasks`, passed as free text —
never the whole spec.

A `legacy` backlog takes the **no**-backlog row, plus "regenerate with `/setup:create-backlog` to
route through `/update-backlog`". `/create-task` is never offered for a backlog Task — it refuses one.
`held` Tasks are listed as not ready, with the open question that holds them.

<TERMINAL-GATE>
**STOP. `/brainstorm-ba` is complete.** Report the spec path and the routing row. Do NOT auto-run the next command. Never `/plan-feature`.
</TERMINAL-GATE>

## Stage end marker (token usage)

At this command's definitive end — its work is done, or it stops for good (STOP, refusal, blocker,
the waiting exit) — run exactly this once, as its own Bash call from the repo root with nothing
chained before or after it, as the last step **before** the final report (or handback):

`bash .claude/lib/costs/runtime-mark.sh stage end brainstorm-ba`

Never at a pause that waits for the user (a question, an approval): the stage goes on after the
answer, and a plain reply records no new start. The call writes nothing itself; when the team
harness has registered the stage hook, the hook records it as this stage's end for
`cost.py report --by-stage` (`.agents/reference/token-usage.md` → Stages). Without the hook, and
inside a sub-agent, it does nothing.
