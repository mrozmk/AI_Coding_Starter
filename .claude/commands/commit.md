---
description: Create a git commit
---

# /commit - Create a git commit

Create a clean, professional git commit from staged and unstaged changes. Execute immediately — no confirmation needed.

## Steps to follow (execute all in order):

1. Run `git status`, `git diff HEAD`, `git status --porcelain`, and `git log --oneline -5` **in parallel**
2. If `git status --porcelain` output is empty — inform the user: "Nothing to commit, working tree clean." and stop.
3. Analyze the changes and generate a commit message following the canon format below
4. Stage all relevant files (skip: .env, credentials, large binaries, node_modules)
5. Create the commit immediately with the generated message — **do NOT ask for confirmation**
6. **Memory checkpoint** — before finishing, review the work done in this commit and ask yourself:
   - Did a bug occur and get fixed? → append to `.agents/memory/errors.md`
   - Was an API or protocol behavior discovered? → append to `.agents/memory/api.md`
   - Was an architectural decision made? → append to `.agents/memory/decisions.md`
   - Was a project-specific pattern identified? → append to `.agents/memory/patterns.md`
   - Was something module-specific learned? → append to `.agents/memory/domain/{module}.md` (create if needed)
   - If nothing worth remembering — skip silently, do not mention it
   - If memory files were updated — include them in the staged files for this commit
7. Show a brief summary: list of staged files and the commit message used

## Commit message canon:

```
<type>(<scope>): <subject>

<body — optional, only when changes are non-trivial>
- [what changed and WHY, not just what]
- [context useful for future AI reading this log]
```

**Types:** `feat`, `fix`, `docs`, `style`, `refactor`, `test`, `chore`

**Rules for generating the message:**
- `subject` is lowercase, max 72 characters, imperative mood ("add", not "added")
- `scope` reflects the area of change (e.g. `auth`, `api`, `ui`, `db`)
- body bullet points explain the **intent and reasoning**, not just file names
- message must be derived from actual diff content, not guessed
- if the change fixes a bug: briefly describe the root cause in the body
- if the change adds a feature: describe the user-facing effect

## CRITICAL rules:
- NEVER add "Co-Authored-By: Claude" or any Claude attribution
- NEVER add "🤖 Generated with Claude Code" markers
- NO version tags — this command creates commits only
- NEVER push — local commit only
