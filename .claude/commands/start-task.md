---
description: Bootstrap a tracker task end-to-end — derive branch type from the issue, cut a working branch off the fresh base branch, prime, then brainstorm
argument-hint: "<ISSUE-KEY> (e.g. PROJ-42)"
allowed-tools: Bash(git status:*), Bash(git branch:*), Bash(git switch:*), Bash(git rev-parse:*), Bash(git fetch:*), Bash(git ls-remote:*), mcp__atlassian__jira_get_issue, Skill, AskUserQuestion
---

# /start-task — from issue key to brainstorm in one go

Given a tracker issue key, derive the branch type from the issue, cut a working branch off a
freshly pulled base branch, prime the session, and launch `/brainstorm`.

The issue key for this run is: **$ARGUMENTS**

---

## Guardrails (read before acting)

- `git switch` / `git switch -c` only — never `git checkout` (`checkout -- *` is a denied op).
- Never auto-stash across a branch switch. Dirty working tree → **stop and ask**.
- Branch type is proposed, then **confirmed** with the user — never chosen silently.
- Do not push the branch. Creating it locally is enough; `/push` is a later, explicit step.
- Branch names and slugs are **English**, kebab-case — translate the summary first if needed.
- Branch facts come from `CLAUDE.md → ### Branch model`, never from a hardcoded name.

---

## Steps

### 1. Parse and validate the key

- Trim and uppercase `$ARGUMENTS`. It must match `^[A-Z]+-\d+$`. Empty or malformed → stop and
  ask for a valid key. Call the value `KEY`.

### 2. Resolve the base branch

- `git rev-parse --is-inside-work-tree` — not a repo → stop.
- Read `CLAUDE.md → ### Branch model`. `BASE` = **Integration** if set, else **Trunk**. Block
  absent → `git symbolic-ref refs/remotes/origin/HEAD`, then `main`, then `master`. **Never
  assume `develop`.** Also note **Branch names** (the `<type>/<KEY>-<slug>` pattern) and
  **Protected**.
- Verify: `git rev-parse --verify --quiet refs/heads/<BASE> || git ls-remote --heads origin <BASE>`.
  Neither → stop: "Base branch `<BASE>` not found — check the Branch model in CLAUDE.md."

### 3. Fetch the issue

- Call `mcp__atlassian__jira_get_issue(issue_key=KEY, fields="summary,issuetype")`.
- **Soft-fail:** tracker MCP not configured, `401`, or unknown key → say so in one line and ask
  the user for the **issue type** and a **one-line title** instead. Never continue on a guessed
  title.

### 4. Propose branch type + slug, then confirm

- Map the issue type to a `<type>` as the starting suggestion:
  - `Bug` → `bugfix`
  - `Story` / `Task` / `Improvement` → `feature` (default); `chore` when the summary reads as
    tooling / deps / CI / repo maintenance; `refactor` for a no-behaviour-change structural change
  - A critical production fix → `hotfix`, based on **Trunk** instead of `BASE` (say so)
- `SLUG`: English, lowercase, kebab-case, meaningful words only, ~5 words max.
  "Route brainstorm through plan feature" → `route-brainstorm-through-plan`.
- `BRANCH` = the Branch model's name pattern with `<type>`, `KEY`, `SLUG` filled in
  (default `<type>/KEY-SLUG`, e.g. `feature/PROJ-42-route-brainstorm-through-plan`).
- **Confirm via `AskUserQuestion`**: show `<type>` and the full `BRANCH`; let the user accept or
  override the type (`feature` · `bugfix` · `refactor` · `chore` · `hotfix`). Use the confirmed
  values from here on.

### 5. Clean working tree

- `git status --porcelain` non-empty → stop: "Working tree has uncommitted changes. Commit, stash
  or discard them first, then re-run `/start-task KEY`." No auto-stash.

### 6. Switch to the base and update it

- `git switch <BASE>` — on failure show the error and stop.
- Invoke `/pull`. It may stash on its own; step 5 guarantees there is nothing to stash. Conflict
  or failure → stop and surface it.

### 7. Create or resume the working branch

- Local: `git rev-parse --verify --quiet "refs/heads/<BRANCH>"` · Remote:
  `git ls-remote --heads origin "<BRANCH>"`.
  - **Exists locally** → `git switch "<BRANCH>"` — tell the user it is resumed.
  - **Remote only** → `git switch -c "<BRANCH>" --track "origin/<BRANCH>"`.
  - **New** → `git switch -c "<BRANCH>" --no-track` — `--no-track` so a bare `git push` can never
    target the protected base (CLAUDE.md → Git Workflow); `/push` sets the upstream on first push.
- Confirm with `git rev-parse --abbrev-ref HEAD`.

### 8. Prime and brainstorm

- Print one line: `Started KEY → <BRANCH> off <BASE> · priming · launching /brainstorm`
- Invoke `/prime` (quick mode).
- Invoke `/brainstorm KEY` — it recognises the key and pulls the issue's summary + AC as the
  topic. This is the intended finish; the brainstorm asks whatever else it needs.
