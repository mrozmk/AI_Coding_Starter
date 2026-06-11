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

- Run `git rev-parse --abbrev-ref HEAD` — its output is the current branch name. Substitute that literal name into the commands below wherever `<branch>` appears (do not rely on a shell variable — each command runs in a fresh shell, so the value would not carry over).
- If `<branch>` is literal `HEAD` (detached HEAD):
  - Stop and inform the user: "Detached HEAD — checkout a branch before pulling."
- Run `git status --short` — show local changes summary
- Run `git log --oneline -3` — show last 3 local commits

### 4. Stash local changes (if any)

- Run `git status --porcelain`
- If output is non-empty (there are uncommitted changes):
  - Inform the user: "Stashing local changes before pull..."
  - Run `git stash push -m "auto-stash before pull"`
  - Remember that changes were stashed (track this in your reasoning — there is no persisted shell variable across commands).
- If output is empty: nothing was stashed.

### 5. Fetch and check for updates

- Run `git fetch origin`
- Run `git log --oneline HEAD..origin/<branch>` to see incoming commits
  - If `origin/<branch>` does not exist on remote (new local branch), inform the user: "`origin/<branch>` does not exist — nothing to pull. Push first with /push."
  - If changes were stashed, restore them: `git stash pop`
  - Stop here.
- If no output (nothing to pull):
  - Inform the user: "Already up to date with `origin/<branch>`."
  - If changes were stashed, restore them: `git stash pop`
  - Stop here.
- If there are incoming commits, show them to the user.

### 6. Pull

- Run `git pull origin "<branch>"`
- If pull fails due to merge conflicts:
  - If changes were stashed, restore them: `git stash pop`
  - Inform the user: "Pull failed due to merge conflicts. Resolve them manually, then commit the merge."
  - Show conflicting files: `git diff --name-only --diff-filter=U`
  - Stop here.
- If pull fails for any other reason:
  - If changes were stashed, restore them: `git stash pop`
  - Show the error and stop.

### 7. Restore stashed changes (if stashed)

- If changes were stashed earlier:
  - Run `git stash pop`
  - If stash pop reports conflicts, warn the user:
    > "Stash pop had conflicts. Resolve them manually, then run `git stash drop`."

### 8. Confirm success

- Show pulled commits: `git log --oneline ORIG_HEAD..HEAD`
- Confirm: "Pull complete. Now up to date with `origin/<branch>`."
