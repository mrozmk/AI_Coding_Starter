# Description Templates: Epic / Task / Bug

Markdown templates for the `description` field. `mcp-atlassian` auto-converts markdown to ADF for Jira Cloud — stick to the safe subset (flat headings, simple lists, no nested tables).

Use these as **starting points** when generating descriptions during create/update. Do not force every section if a section would be empty — omit instead.

---

## Epic

```markdown
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
