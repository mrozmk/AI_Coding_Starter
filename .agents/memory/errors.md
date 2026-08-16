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

## 2026-08-16 — `guard-commit.sh` blocks `git add X && git commit` in one Bash call

**What failed:** `git add <path> && git commit -F -` was rejected with `BLOCKED: 'git commit' with an empty staged set`, even though the `git add` immediately preceding it was correct and would have staged a real change.
**Root cause:** the guard is a **PreToolUse** hook — it inspects `git diff --cached` *before* the Bash tool runs, so the `git add` in the same command has not executed yet. The index is genuinely empty at inspection time. The hook is not wrong; the chaining is.
**Fix:** stage in one Bash call, commit in the next.
**Rule:** any repo-side guard that inspects git state runs **before** the whole compound command, so never chain a state-changing git step with the command that guard validates. One call to mutate state, one call to act on it.

<!-- Newest entry goes above this line. -->
