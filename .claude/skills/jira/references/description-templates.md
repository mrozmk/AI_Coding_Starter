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

```markdown
## Steps to Reproduce

1. First step
2. Second step
3. Third step

## Expected Behavior

What should have happened.

## Actual Behavior

What actually happened. Include error messages verbatim inside backticks.

## Environment

- App version:
- Platform / OS:
- Browser (if applicable):

## Evidence

- Screenshot:
- Log excerpt:
- Related issue:
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
