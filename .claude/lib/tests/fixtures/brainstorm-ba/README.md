# Fixture: `/brainstorm-ba` worked proof

A synthetic "reading list" product for the hand-run proof of `/brainstorm-ba`: a new-format backlog
with one Epic file, a PRD register with one recorded decision (`D-1`), one Task (`E1-2`) whose
criteria an Approved design spec in its `Ref` replaced, a tiny code tree, tracker `github` in the
profile, and a client message with five planted points. All names are synthetic. The proof is run by
hand (it is not a suite step) on a scratch copy **outside any team clone** — the command refuses in a
team clone.

## What the fixture plants

| Input point (`inputs/input.md`) | Planted as | Grounded in |
|---|---|---|
| (1) share a list publicly by link | **conflict** | `D-1` "Lists stay private", `R-3`, `src/list.js` `isVisibleTo` |
| (2) add books to the list | **duplicate** | `E1-1` (DONE), `src/list.js` `addBook` |
| (3) see the date a book was finished | **covered** | `E1-2` current `E1-2.AC3` from `.agents/specs/2026-01-12-mark-read.md` (the Epic file's `E1-2.AC2` is the replaced criterion); `markRead` stores the date but nothing shows it on hover — a code-vs-criterion discrepancy, not new scope |
| (4) author's country in the export, source to come | **unanswerable** | nothing in the fixture says which source — only the client can answer |
| (5) undo marking a book as read | **extends** | exceeds `E1-2.AC3`; `E1-2` is protected by its `Ref` |

`src/list.js` `exportCsv` is implemented with no Task.

`node .claude/lib/backlog-check.mjs --root <copy>` prints 0 errors and one warning (`quality Tasks not
planned`) — expected for a fixture this small, and the same before and after the run.

## Setup

1. Make a scratch directory outside any team clone, then copy the committed workflow files of a
   template checkout that ships `/brainstorm-ba` (one with no project specs, backlog or PRD of its
   own — they would join the evidence), the test fixtures excluded (so this README, which holds the
   stage-2 reply, is not in the copy):
   `git -C <checkout> archive HEAD -- . ':(exclude).claude/lib/tests/fixtures' | tar -x -C <scratch>`
2. Copy the fixture over it **without this README**, so the fixture's `.claude/project-profile.json`
   wins: `rsync -a --exclude README.md <checkout>/.claude/lib/tests/fixtures/brainstorm-ba/ <scratch>/`
3. `git -C <scratch> init`, `git -C <scratch> add -A`, `git -C <scratch> commit -m fixture`.
4. Check that `<scratch>/.claude/commands/brainstorm-ba.md`, `<scratch>/.agents/memory/index.md` and
   `<scratch>/.agents/reference/spec-cross-review.md` exist.
5. `node .claude/lib/backlog-check.mjs` in the copy — keep the output for the comparison at the end.

## Stage 1

A session with the copy as its working directory (interactive, or `claude -p`): `/prime-ba`, then
`/brainstorm-ba inputs/input.md`. Answer the conflict question for point (1) with "keep lists
private" (the BA's choice). The run ends in the **waiting exit** for point (4): capture the spec it
wrote — `**Status:** Waiting — client`, the paste-ready question and its owner.

## Stage 2

Only now give the client's reply. Run `/brainstorm-ba <the spec from stage 1>` and paste this reply:

> Use the publisher catalogue's country field for the author's country.

The run resumes at Step 1 for the point (4) rows only. Approve, and capture the routing row the
terminal gate prints.

## Expected

Verification rows (every row with evidence; code evidence as `<repo>@<sha>:src/list.js:<line>`;
the header's `**Verified against:**` records the sha):

- (1) → `conflicts with D-1`, asked as a question quoting `D-1` and `src/list.js` `isVisibleTo`; not
  applied, not dropped.
- (2) → `covered by E1-1`, "use existing", no new Task.
- (3) → `covered by E1-2`, plus the `partly implemented` discrepancy citing `E1-2.AC3` from
  `.agents/specs/2026-01-12-mark-read.md` — never the Epic file's `E1-2.AC2`; no new Task.
- (4) → stage 1: an open question owned by the client under `## Open questions`, never text inside a
  Task; stage 2: resolved.
- (5) → `extends E1-2`, a `delta-linked` intent (E1-2 is protected), no criterion id allocated.
- `exportCsv` → `implemented, no Task` if the run touches the export.
- The tracker reads fail against the synthetic repo → the tracker is named under `## Not verified`.

Routing row after stage 2: `/update-backlog <spec>` → `/github-sync`.

After stage 2, `node .claude/lib/backlog-check.mjs` in the copy prints the same as in Setup step 5,
and no `Ref` cell names the requirements spec.

## No-backlog variant

A second scratch copy, set up the same way, with `.agents/backlog.md` and `.agents/backlog/` deleted
before the commit of Setup step 3. Run both stages again. Expected routing row: `/create-task <draft>`
per Task (never `/jira draft`).
