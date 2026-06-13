# /push - Push to GitHub

Push local commits to `origin/<current-branch>`. Branch is detected dynamically — works with any workflow (trunk-based, feature-branch, GitFlow).

## Steps to follow:

### 1. Detect current branch and verify state

- Run `git rev-parse --abbrev-ref HEAD` — its output is the current branch name. Substitute that literal name into the commands below wherever `<branch>` appears (do not rely on a shell variable — each command runs in a fresh shell, so the value would not carry over).
- If `<branch>` is literal `HEAD` (detached HEAD):
  - Stop and inform the user: "Detached HEAD — checkout a branch before pushing."
- Run `git remote get-url origin` — show the remote URL to the user
- Run `git status --short` — confirm working tree state
- Run `git log --oneline origin/<branch>..HEAD` — show commits about to be pushed
  - If `origin/<branch>` does not exist yet (new branch), fall back to `git log --oneline -10`
- If no commits to push: inform the user "Nothing to push, already up to date." and stop

### 2. Confirm protected-branch push

- If `<branch>` is one of `main`, `master`, `trunk`, `develop`:
  - Show the user: "You are about to push directly to protected branch `<branch>`. Confirm? (yes/no)"
  - If the user declines, stop here.
- Otherwise proceed silently.

### 3. Check for unpushed tags

- Run `git tag -l | sort -V | tail -5` to list recent local tags
- Run `git ls-remote --tags origin` to list remote tags
- If new local tags exist that are not on remote, note them for step 5

### 4. Push commits

- Run: `git push origin "<branch>"`
- If push is rejected (non-fast-forward):
  - Do NOT force push automatically
  - Inform the user: "Push rejected — remote has commits not in local history. Run /pull first, then /push again."
  - Stop here.

### 5. Push tags (if any new local tags)

- If new local tags were detected in step 3:
  - Inform the user: "New local tags found: [list]. Pushing tags..."
  - Run: `git push origin --tags`

### 6. Confirm success

- Show: `git log --oneline origin/<branch>~3..origin/<branch>`
- Confirm: "Push complete. `origin/<branch>` is up to date."

## CRITICAL rules:
- NEVER use `--force` or `--force-with-lease` — they are blocked in `.claude/settings.json`. If rewriting history is genuinely needed, ask the user to run it manually.
- When pushing to a protected branch (`main`/`master`/`trunk`/`develop`), always ask for confirmation first.

## Pre-publication secret scan (automatic)

Every `git push` is intercepted by the `guard-push.sh` PreToolUse hook — a deterministic, last-line scan of the commits about to be published for secrets (tokens, private keys, credentialed connection strings, hardcoded credentials) and credential files (`.env`, `*.pem`, `*.key`, `.npmrc`, `*.tfstate`, …). On a hit it **blocks the push** (exit 2) and prints the offending file paths (never the values).

- This runs regardless of `/push` — it guards the underlying `git push`, so a hand-rolled push is covered too.
- **On a block:** remove the secret, rotate it if real, and amend/rewrite the offending commit (history rewrite is denied for the AI — ask the human). Do **not** auto-override.
- **False positive:** add an inline `# guard-push:allow` marker on the line, or move sample values to a `*.example`/`*.sample` file.
- **Emergency override (logged to `audit.log`):** the human re-runs as `GUARD_PUSH_SKIP=1 git push …`.
- If `gitleaks` is on PATH it runs as an additional, broader check; otherwise the built-in baseline scan still applies.
