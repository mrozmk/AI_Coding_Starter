# /push - Push to GitHub

Push local commits to `origin/<current-branch>`. Branch is detected dynamically — works with any workflow (trunk-based, feature-branch, GitFlow).

## Steps to follow:

### 1. Detect current branch and verify state

- Run `BRANCH=$(git rev-parse --abbrev-ref HEAD)` — capture current branch
- If `$BRANCH` is literal `HEAD` (detached HEAD):
  - Stop and inform the user: "Detached HEAD — checkout a branch before pushing."
- Run `git remote get-url origin` — show the remote URL to the user
- Run `git status --short` — confirm working tree state
- Run `git log --oneline origin/$BRANCH..HEAD` — show commits about to be pushed
  - If `origin/$BRANCH` does not exist yet (new branch), fall back to `git log --oneline -10`
- If no commits to push: inform the user "Nothing to push, already up to date." and stop

### 2. Confirm protected-branch push

- If `$BRANCH` is one of `main`, `master`, `trunk`, `develop`:
  - Show the user: "You are about to push directly to protected branch `$BRANCH`. Confirm? (yes/no)"
  - If the user declines, stop here.
- Otherwise proceed silently.

### 3. Check for unpushed tags

- Run `git tag -l | sort -V | tail -5` to list recent local tags
- Run `git ls-remote --tags origin` to list remote tags
- If new local tags exist that are not on remote, note them for step 5

### 4. Push commits

- Run: `git push origin "$BRANCH"`
- If push is rejected (non-fast-forward):
  - Do NOT force push automatically
  - Inform the user: "Push rejected — remote has commits not in local history. Run /pull first, then /push again."
  - Stop here.

### 5. Push tags (if any new local tags)

- If new local tags were detected in step 3:
  - Inform the user: "New local tags found: [list]. Pushing tags..."
  - Run: `git push origin --tags`

### 6. Confirm success

- Show: `git log --oneline origin/$BRANCH~3..origin/$BRANCH`
- Confirm: "Push complete. `origin/$BRANCH` is up to date."

## CRITICAL rules:
- NEVER use `--force` or `--force-with-lease` — they are blocked in `.claude/settings.json`. If rewriting history is genuinely needed, ask the user to run it manually.
- When pushing to a protected branch (`main`/`master`/`trunk`/`develop`), always ask for confirmation first.
