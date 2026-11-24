# Task shape

One shape for every task a session opens, on any tracker. `/create-task` drafts it; the wrapup's
follow-up tickets carry the same sections under their own first and last lines.

## Title

- Imperative, English, ≤ 80 characters: `Add a retry to the issue sync`, not `Retry issue`.
- No `#`, no ticket key, no backtick and no `$(` — commands and code go in the body (a backtick in
  an argument makes the egress guard rescan it as a command, and that prompts).
- No secret-like token prefix and no `curl` data flag either — the shipped `deny` rules of
  `.claude/settings.json` match those anywhere in a command, and a deny outranks the skill's
  allowance; describe them in the body. A real credential value never goes into a task, title or
  body — write `[REDACTED]` in its place.

## Body

```markdown
## Problem
Why: the observed failure or gap, with evidence (file:line, command output, a linked issue) and
who reported it.

## Wanted
The scope as concrete changes.

## Acceptance
- Testable bullets — each one a check someone can run or read.

## Out of scope
What the task deliberately leaves.

## Related
(optional) Linked tickets.
```

- Add the line `Lands in the starter and here.` only when the repo's CLAUDE.md has a both-repos rule
  and the task changes the workflow.

## Type

- A defect — "When <who> runs <what>, <wrong result>", an error, a regression → `bug`.
- Anything else → `enhancement`.

## Callers keep their own contract

- **Wrapup follow-up** — the body opens with its failure sentence (or the cut order line) **above**
  `## Problem` and ends with its lineage line, then its run marker as the last line; its existing
  writer (`create-followup` on GitHub, the `/jira create` path on Jira) creates it, never
  `/create-task`. Example first and last lines:

  ```
  When the coder runs the per-task gate, the suite step list misses a renamed test.
  …
  Follow-up of #<ticket> · origin #<origin>
  [wrapup <run> create-<n>]
  ```

- **Recommendation** (Supervisor / Advisor) — search for an open duplicate first; the body carries
  the recommendation line from `teams.policy.tickets.recommendation_line` (default "Created from a
  recommendation — the Operator verifies it when the work starts").

## Example

```markdown
# Add a retry to the issue sync

## Problem
The sync stops on the first HTTP 502 from the API (seen twice in one week, `sync.log:41`), and the
rest of the Epic is left unsynced until someone reruns it by hand.

## Wanted
- One retry with a short back-off on a 5xx answer.
- The run report names a retried call.

## Acceptance
- A stubbed 502 on the first call is retried once and the sync completes.
- A second 502 stops the run with a recoverable exit, nothing half-written.

## Out of scope
- Retrying 4xx answers.
```
