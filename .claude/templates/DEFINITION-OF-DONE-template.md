# Definition of Done

A task is **Done** when it is merged, every acceptance criterion is verified with evidence, and the next person to touch the code inherits no hidden cost. "It works on my branch" is not Done.

**Applies to** every PR before merge, and to the ticket before it moves to Done. **Owner:** the implementer. **Verified by:** the reviewer + CI. The PR template is the short form of this list.

**(CI)** marks items the pipeline enforces — it blocks the merge. The rest are the reviewer's job.

---

## The checklist

- [ ] Every acceptance criterion verified with concrete evidence — an observed value, a screenshot, a passing test. "Looks fine" is not evidence.
- [ ] Criteria no tool can check (visual regression, real-device behaviour) are signed off by a human, by name.
- [ ] Tests pass locally and in CI **(CI)**. Nothing was skipped or disabled to get there.
- [ ] New behaviour is covered by tests; deleted behaviour has its tests deleted.
- [ ] Test coverage did not decrease **(CI)**. Rules: `TESTING.md`.
- [ ] Where a reference design exists, the implementation matches it; screenshots per width tier (`.claude/qa-env.json` sweep widths, else desktop + mobile) are attached to the PR.
- [ ] Visual values come from the design system, not one-off hardcoded values.
- [ ] Usable by keyboard and screen reader, with visible focus and readable contrast (WCAG AA).
- [ ] No new console errors or warnings.
- [ ] All user-facing text is translatable — no hardcoded strings — and registered where the project keeps translations.
- [ ] No secrets committed, and none reach the client.
- [ ] User input is validated wherever it enters the system.
- [ ] Branch name, commit messages and PR title follow `CLAUDE.md → Git Workflow`; hooks were not bypassed.
- [ ] CI green **(CI)**. A failing check is fixed, not explained away.
