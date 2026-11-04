# Description Templates: Epic / Task / Bug

Markdown templates for the `description` field. `mcp-atlassian` auto-converts markdown to ADF for Jira Cloud — stick to the safe subset (flat headings, simple lists, no nested tables).

Use these as **starting points** when generating descriptions during create/update. Do not force every section if a section would be empty — omit instead.

---

## Epic

`/jira sync` fills **Outcome · Key assumption · Appetite / cut first · Tasks** from the backlog's
Epic map; a hand-made Epic uses **Vision / Success Criteria / Out of Scope** instead. Omit whichever
set has no content — never leave both as placeholders.

```markdown
## Outcome

The product effect this Epic delivers, traced to the goal it moves — e.g. "Checkout completes
without a support call (G-2)."

## Key assumption

The most load-bearing thing we are not yet sure of. One sentence.

## Appetite

How much this Epic is worth (the budget, not the estimate) · **Cut first:** what drops when it grows.

## Tasks

- E1-1 — <title> (tech, M)
- E1-2 — <title> (story, H)

## Vision

One or two sentences on the outcome this Epic achieves. User-value framing preferred over technical description.

## Success Criteria

- Measurable outcome 1
- Measurable outcome 2
- Measurable outcome 3

## Out of Scope

- Thing this Epic explicitly does NOT cover
- Another thing out of scope

## Links

- Design doc:
- Related Epic:
```

---

## Task

```markdown
## Objective

One sentence stating what this Task accomplishes.

## Acceptance Criteria

- [ ] Specific, testable criterion 1
- [ ] Specific, testable criterion 2
- [ ] Specific, testable criterion 3

## Technical Notes

Implementation guidance, constraints, dependencies. Keep short. Link to docs rather than duplicating.
```

---

## Story

Used by `/jira sync` for a backlog Task whose `Type` is `story` (`sync-pattern.md` → Step 3).

**Acceptance-criteria ids are copied verbatim** — `E1-2.AC1`, never renumbered, never reworded.
`/qa-verify` keys its verdicts on these ids and joins on the exact string; a rewritten id silently
breaks the join. `Depends on` carries the **local** backlog ids; the Jira `Blocks` links are created
separately (`sync-pattern.md` → Step 7).

```markdown
## User story

As a <role> I want <capability> so that <outcome>.

## Acceptance criteria

- **E1-2.AC1** — Given <state> When <action> Then <result>
- **E1-2.AC2** — WHEN <trigger> the system shall <response>

## Traces

R-3, FL-1.A2, G-2

## Size

H (8 pts)

## Depends on

E1-1, E0-2

## Relates

E1-5

## Chain

checkout-flow — 2 of 3

## Node

checkout-core
```

`## Size` stays in every description whatever `jira.estimates` says — sizes are a planning currency, not a time estimate. `## Relates` / `## Chain` appear only when the row has them.

---

## Tech

Used by `/jira sync` for a backlog Task whose `Type` is `tech`. Same id rule as **Story**: AC ids
verbatim. A spike's acceptance criterion is the decision it produces.

```markdown
## Objective

One sentence stating the technical result this Task produces.

## Acceptance criteria

- **E0-1.AC1** — Given <state> When <action> Then <observable result>

## Traces

AD-1, NFR-2

## Size

M (4 pts)

## Depends on

—

## Node

platform-core
```

`## Size` stays in every description whatever `jira.estimates` says — sizes are a planning currency, not a time estimate. `## Relates` / `## Chain` appear only when the row has them.

---

## Bug

Evidence-grade: measured values, cited sources, a testable fix boundary. There is no standalone
`Environment` section — the reproducing viewport, locale and state belong in _Steps to
reproduce_; the build/SHA and whatever could not be verified belong in _Notes_.

```markdown
## Summary

One or two sentences: what is wrong, on which component or surface, and the exact range or
condition under which it happens. Bold the affected range when it is narrower than the
component — **The affected range is 768–1023 px.**

## Steps to reproduce

1. Open <a concrete reproduction URL — route, story, or dev page>
2. <the exact state that triggers it: viewport WxH, locale, logged-in/anonymous, data used>
3. Compare against <the design or spec source — design node link, ADR, ticket>

## Expected result

What the design or spec says must happen, citing the source rather than paraphrasing it.
Enumerate the concrete elements — what is visible, what is hidden, sizes, spacing — so the
fix is verifiable without opening the design tool.

## Actual result

What happens instead, in **measured** values: element sizes, visibility, counts, real error
strings in backticks. Not impressions. Name where the measurement was taken, e.g. "Measured
at 1022x593".

## Evidence

- Screenshot: <filename> — <what it proves>
- Log excerpt or console error, in a fenced block

## Root cause

The file and the offending fragment, quoted. If the cause is not yet known, delete this
section rather than speculating in it.

## Acceptance criteria

- <Testable statement of the fixed behaviour>
- <What must stay unchanged — the regression boundary>
- <How it is verified when unit tests cannot cover it, e.g. jsdom performs no layout, so
  breakpoint behaviour is verified in the browser>

## Out of scope

- <Adjacent components or systems this bug deliberately does not cover>

## Notes

- Where it was found (which build, which date) and anything that could not be verified.
- Related issue keys, and whether the same mistake may exist elsewhere.
- Suggested branch: `bugfix/<KEY>-short-title`.
```

---

## Draft Epic

Rendered by `/jira draft` into `.agents/jira/inprogress/E<n>/_epic.md` (`draft-pattern.md`). The
Epic row of the backlog pre-fills it; sections with no content are omitted, never stubbed.

```markdown
## Epic Description

<the business need this Epic addresses, user-value framing — one or two paragraphs>

## Vision

<one or two sentences on the outcome, when it is not obvious from the description>

## Success criteria

- <from the Epic row's Outcome — measurable>

## Assumptions

- <from the Epic row's Key assumption>

## Appetite

appetite: <…> · cut first if over: <…>

## Epic Scope

| Feature | Description | Dependencies | Jira link |
|---|---|---|---|
| <Task title> | <one line> | <prerequisites and per-feature assumptions> | E1-2 |

## Out of Scope

- <explicit exclusions only — never the cut-first items, which are planned work>

## Links

- <design doc, related Epic>
```

The `Jira link` cell holds the Task id until `send` replaces it with the issue link.

---

## Draft Task

Rendered by `/jira draft` into `.agents/jira/inprogress/E<n>/<Task id>--<slug>.md`. The Task row and
the AC resolver pre-fill the machine-owned sections (`## Acceptance criteria`, `## Size`,
`## Traces`, `## Node`, `## Chain`, `## Dependencies`); everything else is the BA's.

```markdown
## User story

As a <role>, I want <capability>, so that <outcome>.

(A `tech` row uses `## Description` instead: one paragraph on what the Task delivers and why.)

## Requirements details

<the primary content: context, the flow step by step, design links (paste the share URL), references>

## Acceptance criteria

- **E1-2.AC1** — Given <state> When <action> Then <observable result>
- **E1-2.AC2** — IF <failure> THEN the system shall <response>

## Size

H (8 pts)

## Traces

R-3, FL-1.A2

## Node

checkout-core

## Chain

checkout-flow — 2 of 3

## Out of scope

- <explicit non-goal — name where the work lives instead>

## Open questions

- <question for the team — draft-only: posted as one comment after send>

## Notes

- <BA-only context — draft-only: never sent>

## Initial Jira status

<why the issue should start in a given status — draft-only; the frontmatter `initial_jira_status` is authoritative>

## Dependencies

- Blocked by: E1-1
- Relates to: E1-5
```

`## Open questions`, `## Notes`, `## Initial Jira status` and `## Dependencies` are **draft-only**
and never reach the description. A line may start with `[internal]` — stripped at send.

---

## Style rules

### Transport rules (fixed — not edited per project)

- Cross-references in Jira-bound text use Jira keys once they exist. Backlog Task ids appear only in
  `## Dependencies`, `## Chain`, the Epic Scope `Jira link` cell before send, and AC ids — machine ids
  `E<n>-<m>` and `E<n>-<m>.AC<k>` are exempt from "no row ids in Jira text".
- Draft-only sections and `[internal]` spans never leave the repo.
- The safe Markdown subset in **Notes on rendering in Jira Cloud** below.

### Editorial defaults (project-editable — shipped from a previous BA engagement's grooming)

- Acceptance criteria state the observable outcome, never how it is verified ("via DOM assertion",
  "Test: …", "Validation gate …" are method, not outcome).
- No bracket labels (`[Assumption]`, `[Note]`, `[Open question]`, …) in Task bodies — decision-pending
  content goes to `## Open questions` or `## Notes`.
- Placeholder-grade names carry `(naming to be decided)` or `(examples)`.
- `and`, not `+`, joins words in prose (`+` stays in counts and type unions).
- `## Requirements details` sits between the user story and the acceptance criteria.
- A Task that produces a document names its file path in an acceptance criterion.

Change the editorial defaults by a deliberate edit or an accepted `/jira resync` proposal; never
change the transport rules per project.

---

## Notes on rendering in Jira Cloud

**Safe** (renders correctly after ADF conversion):
- Flat headings `##`, `###`
- Bullet and numbered lists (one level)
- Bold `**...**`, italic `*...*`
- Inline code \`...\` and fenced code blocks
- Links `[text](url)`
- Checkboxes as `- [ ]` / `- [x]` (renders as plain bullets in most Cloud instances — good enough for visual parity)

**Avoid** (may fail or render oddly):
- Nested tables
- Lists deeper than one level
- HTML tags (`<details>`, `<br>`, `<img>`)
- Horizontal rules (`---`) — inconsistent across instances

If you need something from the "Avoid" list, first try it in a throwaway issue before using at scale.
