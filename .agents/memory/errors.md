# Memory: Errors & Lessons

Bugs that occurred during development, root causes, and how to avoid them next time.

Add newest entries at the **TOP**. Format: what failed · why · fix / rule.

---

## Format

```
## YYYY-MM-DD — Short title

**What failed:** {symptom observed}
**Root cause:** {why it happened}
**Fix:** {what was changed}
**Rule:** {generalized lesson — how to avoid this next time}
```

---

## 2026-06-27 — README sync missed drift outside edited lines + copied a pre-existing false claim

**What failed:** A "sync README with the last N commits" pass left two reader-facing inaccuracies that a `/codex-review` cross-model pass then caught: (1) `/maintain:cleanup-workflow` was described as **3 phases** while the command now ships **4** (Phase 4 = Workflow Optimization Audit, added when `a539274` absorbed memory-audit) — the stale line was never touched because it wasn't "new"; (2) the `/brainstorm` row claimed a **Jira `CS-1` intake mode** that the command never had — that false claim pre-dated the sync and was *expanded* (codex sentence appended) without verifying the rest of the sentence. A third miss was self-inflicted: a fresh Requirements bullet said all three codex integrations "auto-skip silently", contradicting the README's own `/codex-review` row two screens down (it **hard-stops**).

**Root cause:** Scoped the sync to *lines the commits visibly changed* instead of *claims those commits made stale*. A commit can invalidate a README sentence it never touches (cleanup-workflow). And when editing an existing sentence, only the added clause was checked — the surrounding pre-existing text was trusted, not verified against source.

**Fix:** Verified every changed claim against the actual source file (`settings.json`, `codex-review.md`, `plan-feature.md`, `brainstorm.md`, `cleanup-workflow.md`), corrected all four, confirmed the only surviving `CS-1` refs are the real `/test-e2e` jira-key mode.

**Rule:** When syncing docs to a commit range, diff the *claims* not just the *lines*: for each command touched in the range, re-read its current spec and confirm the README still matches — including counts ("3 phases"), modes, and skip-vs-hard-stop behavior. When you edit any sentence, verify the **whole** sentence against source, not just your added clause — touching a line makes its pre-existing errors yours. Cross-check new bullets against existing rows for internal contradiction. A cross-model `/codex-review` reliably catches exactly this class of drift — worth running after a doc-sync.
