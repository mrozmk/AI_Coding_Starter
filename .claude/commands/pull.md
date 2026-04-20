# /pull - Pull latest code from remote

Pull the latest changes on the current branch from origin. Branch is detected dynamically. Safe for all files — handles stash/pop automatically.

## Steps to follow:

### 1. Verify git repository

- Run `git rev-parse --is-inside-work-tree`
- If not inside a git repo, stop and inform the user:
  > "This is not a git repository. Clone it first with: `git clone <url>`"

### 2. Verify origin remote

- Run `git remote get-url origin` to get the current remote URL
- If origin is not set, stop and inform the user:
  > "Remote 'origin' is not configured. Add it with: `git remote add origin <url>`"
- Show the detected remote URL to the user

### 3. Detect current branch and show state

- Run `BRANCH=$(git rev-parse --abbrev-ref HEAD)` — capture current branch
- If `$BRANCH` is literal `HEAD` (detached HEAD):
  - Stop and inform the user: "Detached HEAD — checkout a branch before pulling."
- Run `git status --short` — show local changes summary
- Run `git log --oneline -3` — show last 3 local commits

### 4. Stash local changes (if any)

- Run `git status --porcelain`
- If output is non-empty (there are uncommitted changes):
  - Inform the user: "Stashing local changes before pull..."
  - Run `git stash push -m "auto-stash before pull"`
  - Set flag: `STASHED=true`
- If output is empty: set `STASHED=false`

### 5. Fetch and check for updates

- Run `git fetch origin`
- Run `git log --oneline HEAD..origin/$BRANCH` to see incoming commits
  - If `origin/$BRANCH` does not exist on remote (new local branch), inform the user: "`origin/$BRANCH` does not exist — nothing to pull. Push first with /push."
  - If `STASHED=true`, restore: `git stash pop`
  - Stop here.
- If no output (nothing to pull):
  - Inform the user: "Already up to date with `origin/$BRANCH`."
  - If `STASHED=true`, restore: `git stash pop`
  - Stop here.
- If there are incoming commits, show them to the user.

### 6. Pull

- Run `git pull origin "$BRANCH"`
- If pull fails due to merge conflicts:
  - If `STASHED=true`, restore: `git stash pop`
  - Inform the user: "Pull failed due to merge conflicts. Resolve them manually, then commit the merge."
  - Show conflicting files: `git diff --name-only --diff-filter=U`
  - Stop here.
- If pull fails for any other reason:
  - If `STASHED=true`, restore: `git stash pop`
  - Show the error and stop.

### 7. Restore stashed changes (if stashed)

- If `STASHED=true`:
  - Run `git stash pop`
  - If stash pop reports conflicts, warn the user:
    > "Stash pop had conflicts. Resolve them manually, then run `git stash drop`."

### 8. Confirm success

- Show pulled commits: `git log --oneline ORIG_HEAD..HEAD`
- Confirm: "Pull complete. Now up to date with `origin/$BRANCH`."
