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

## 2026-06-14 — `@{u}` in slash-command embedded shell breaks permission checker

**What failed:** `/prime` aborted with `Brace expansion (unquoted { in concatenation with ,/..)` for every clone of the starter.
**Root cause:** Claude Code statically scans embedded `` !`...` `` shell in slash commands before running it. The git shorthand `@{u}` (= `@{upstream}`) contains an unquoted `{u}`, which the checker parses as shell brace expansion (like `{a,b}` / `{1..5}`) and refuses.
**Fix:** Resolve upstream into a var first (`up=$(git rev-parse --abbrev-ref --symbolic-full-name 'HEAD@{upstream}')`) and keep the only braced literal single-quoted. See `.claude/commands/prime.md:91`.
**Rule:** In embedded `` !`...` `` shell inside slash commands, never use bare `{...}` — git refspecs like `@{u}`/`HEAD@{upstream}`, awk bodies `{print}`, glob `{a,b}`. Single-quote any `{` literal so the permission scanner doesn't read it as brace expansion.
