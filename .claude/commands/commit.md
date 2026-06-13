---
description: Create a git commit
---

# /commit - Create a git commit

Create a clean, professional git commit **scoped to the files YOU edited in this session**. Co-existing changes in the working tree (left by another LLM window, by the user, or by tooling) are NOT auto-staged — they get reported and require explicit user opt-in.

The user often runs multiple Claude/LLM sessions in parallel. A naive `/commit` would sweep up another session's in-flight work under the wrong subject and pollute the git history. This command treats unfamiliar modified files as a hazard, not as input.

## Steps to follow (execute all in order):

1. Run `git status`, `git diff HEAD`, `git status --porcelain`, and `git log --oneline -5` **in parallel**.

2. If `git status --porcelain` output is empty — inform the user: "Nothing to commit, working tree clean." and stop.

3. **Determine "your" files** — the set you actually touched in this session:
   - Reconstruct from your transcript: every successful `Edit`, `Write`, `NotebookEdit`, `MultiEdit`, plus any `mv`/`rm`/file-creating `Bash` you ran. Track absolute paths; normalize to repo-relative.
   - Memory files you updated as part of step 9 (memory checkpoint) below count as yours too.
   - If the user explicitly named files in the `/commit` argument (e.g. `/commit src/foo.ts`), trust the argument verbatim — stage exactly those, skip the self-tracking classification below (no need to ask about FOREIGN files in argument-mode).
   - If you cannot reliably reconstruct your set (long compacted session, ambiguous tool history): say so explicitly and **fall back to step 4 confirmation mode** — do not silently auto-commit everything.

4. **Classify modified files** against your set:
   - **OWNED** = modified files in `git status --porcelain` that match your tracked set. These will be staged.
   - **FOREIGN** = modified files NOT in your tracked set. These will NOT be staged automatically.
   - **UNTRACKED** = `??` files. Only stage if they are clearly part of your work (created by your `Write`/`Bash`); otherwise treat as FOREIGN.

5. **Report the classification** for transparency, then proceed without waiting:

   ```
   Staging (your edits this session):
     M  src/lib/foo.ts
     M  src/lib/bar.ts
     ?? src/lib/baz.ts          ← created by your Write

   Skipping (changed by something else — not in this session's edits):
     M  src/components/header.tsx
     M  package.json
     ?? scripts/migrate.sh
   ```

   - **Default behavior: commit ONLY the Staging set, never the Skipping set, no confirmation needed.** Print the classification and immediately move to step 6.
   - **User-driven override:** if the user has _already_ (in the same `/commit` invocation or in a message right before it, unprompted by you) named different files, scopes, or said something like "all" / "include foo.ts" — honor that exactly. Never ask "should I commit all?" — only act on what the user volunteered without prompting.
   - If you are about to skip files because they are FOREIGN, do NOT ask permission to include them. Just print the list and continue.

6. Analyze the changes you ARE staging and generate a commit message following the canon format below. The message must describe only the files actually being staged — not the foreign ones.

7. Stage the approved set with explicit `git add <path>` calls, one path per file. Do NOT use `git add .` or `git add -A` — both bypass the scoping you just established. Skip `.env`, credentials, large binaries, `node_modules` even if they appear in your set (refuse + warn the user).

8. Create the commit with the generated message — **no further confirmation needed at this point**.
9. **Memory checkpoint** — before finishing, review the work done in this commit and ask yourself:
   - Did a bug occur and get fixed? → append to `.agents/memory/errors.md`
   - Was an API or protocol behavior discovered? → append to `.agents/memory/api.md`
   - Was an architectural decision made? → append to `.agents/memory/decisions.md`
   - Was a project-specific pattern identified? → append to `.agents/memory/patterns.md`
   - Was something module-specific learned? → append to `.agents/memory/domain/{module}.md` (create if needed)
   - If nothing worth remembering — skip silently, do not mention it
   - If memory files were updated as part of this checkpoint, they count as yours — `git add` them and create a follow-up commit (or `git commit --amend` if the previous commit was literally seconds ago and unpushed). Do NOT mix unrelated FOREIGN files into the amend either way.
10. Show a brief summary: list of staged files, the commit message used, and the SHA.

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
- NEVER `git add .` / `git add -A` / `git add -u` — they bypass session scoping and silently sweep up other windows' work. Always pass explicit paths.
- NEVER auto-stage a FOREIGN file (one not in your session's edit set). Reason: the user runs multiple LLM windows in parallel — committing another window's in-flight work under the wrong subject pollutes git history and is hard to untangle later.
- NEVER ask the user "should I commit all?" / "should I include the skipped files?". Default is always: commit OWNED set, skip FOREIGN, no confirmation. Only deviate if the user _unprompted_ told you to include specific files.
- If the user is silent about FOREIGN files, treat that as "skip them" — never as "include everything".
