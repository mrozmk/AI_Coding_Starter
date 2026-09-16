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

- Read **Protected** from `CLAUDE.md → ### Branch model`; if the block is absent or the field empty, fall back to `main`, `master`, `trunk`, `develop`. If `<branch>` is in that set:
  - Show the user: "You are about to push directly to protected branch `<branch>`. Confirm? (yes/no)"
  - If the user declines, stop here.
- Otherwise: if the Branch model declares a **Branch names** pattern (e.g. `<type>/<KEY>-<slug>`) and `<branch>` does not match it, **warn once and continue** — a naming slip is worth a note, not a blocked push. No pattern declared → nothing to check.

### 3. Check for unpushed tags

- Run `git tag -l | sort -V | tail -5` to list recent local tags
- Run `git ls-remote --tags origin` to list remote tags
- If new local tags exist that are not on remote, note them for step 5

### 4. Push commits

- Check whether the branch has an upstream: `git rev-parse --abbrev-ref --symbolic-full-name '@{u}'`
  - **No upstream** (the command fails) → push with `-u`: `git push -u origin "<branch>"`. Without it a first push leaves no tracking ref, so `git status` never reports ahead/behind and **this command's own step 1** (`git log HEAD..origin/<branch>`) permanently takes the "branch doesn't exist on remote" path — `/push` would keep behaving as if nothing had ever been published.
  - **Upstream exists** → `git push origin "<branch>"`
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
- **Reverting a merge:** `git revert -m 1 <merge>` run on the *base* branch (e.g. develop after a develop→feature merge) removes the base's own commits, not the feature's. Revert on the branch that received the merge, and only with the parent number checked against `git show --format=%P`.
- NEVER use `--force` or `--force-with-lease` — they are blocked in `.claude/settings.json`. **Resolve forward, don't delegate the rewrite:** integrate with `/pull` then `/push`, or undo the bad commit with `git revert`. Do not tell the user to run the force-push by hand — that turns a deliberate `deny` into a suggestion, and published history stays rewritten either way. If a rewrite is genuinely the only option, say why the forward paths do not work and let the user decide unprompted.
- When pushing to a protected branch (the Branch model's **Protected** set; fallback `main`/`master`/`trunk`/`develop`), always ask for confirmation first. Never work around a refusal with a refspec (`git push origin HEAD:<protected>`) — the **destination** is what is protected, not the syntax.

## Pre-publication secret scan (automatic)

Every `git push` is intercepted by the `guard-push.sh` PreToolUse hook — a deterministic, last-line scan of the commits about to be published for secrets (tokens, private keys, credentialed connection strings, hardcoded credentials) and credential files (`.env`, `*.pem`, `*.key`, `.npmrc`, `*.tfstate`, …). On a hit it **blocks the push** (exit 2) and prints the offending file paths (never the values).

- This runs regardless of `/push` — it guards the underlying `git push`, so a hand-rolled push is covered too.
- **On a block:** remove the secret, rotate it if real, and amend/rewrite the offending commit (history rewrite is denied for the AI — ask the human). Do **not** auto-override.
- **False positive:** add an inline `# guard-push:allow` marker on the line, or move sample values to a `*.example`/`*.sample` file.
- **Emergency override (logged to `audit.log`):** the human re-runs as `GUARD_PUSH_SKIP=1 git push …`.
- If `gitleaks` is on PATH it runs as an additional, broader check; otherwise the built-in baseline scan still applies.
