# Git policy — permission tiers, branches

Pointed at from `CLAUDE.md → Git Workflow`. `CLAUDE.md` keeps the three guardrails (worktree, attribution, the Branch model block); this file explains the mechanics behind them. The enforcing configuration is [.claude/settings.json](../../.claude/settings.json), which is the source of truth for which command sits in which tier.

## Three permission tiers

Precedence `deny` > `ask` > `allow`:

- **`deny`** is absolute — no prompt or classifier overrides it. Holds every history rewrite and every unrecoverable discard: `push --force`, `reset --hard`, `clean -f`, `checkout -- <path>`, `restore .`, `rebase`, `pull --rebase`, `cherry-pick`, `config`, `remote set-url` / `remove` / `rename`, `reflog expire`, `gc --prune`, forced `switch`.
- **`ask`** always prompts, even in auto mode: `merge --no-ff`, `merge --squash`, `branch -d` / `-D`, `git rm`, `remote add`, and bare `rm -rf` anywhere.
- **Deleting without a prompt** goes through two allow-listed wrappers, because a glob cannot confine `rm -rf` to a directory (`*` also matches spaces and extra arguments): `bash .claude/lib/rm-in-project.sh <path>…` inside the repository and its worktrees (never a worktree root, the git dir, `.git`, `.env*`, or the guard layer — `.claude/settings*.json`, `.claude/hooks` — nor a directory holding one; compared case-insensitively, so `.GIT` / `.ENV` aliases on macOS are refused too), and `bash .claude/lib/rm-in-scratchpad.sh <absolute-path>…` from the repo root, inside the current Claude Code session scratchpad only. Both validate every path before deleting anything.
- **`allow`** covers the read-only and the routine: `status`, `diff`, `log`, `add`, `commit`, `push`, `pull`, `fetch`, `stash`, `tag`, `switch`, `revert`, plus `worktree add` / `list` / `prune` / `remove` (the team's starter worktree) and `merge --ff-only`.
- Anything in no list (bare `git merge`, soft/mixed `git reset`) prompts interactively.

An `allow` cannot be scoped to one command, so **`git worktree` is allow-listed for the team's starter worktree** (`team-starter-land.sh` removes a landed one) — using it ad hoc is a behavioral rule, not a hard gate. The one thing that can still discard work through an `allow` is `git worktree remove --force`; nothing in the workflow runs it. That sentence lives in `CLAUDE.md` because nothing else holds it.

## Branches

- **A new branch must not track a protected branch.** `git switch -c` / `checkout -b` from `origin/<protected>` auto-sets that branch as upstream, so a bare `git push` targets it directly. Create with `--no-track` (or run `git branch --unset-upstream` right after) and let `/push` set the upstream on first push.
- **Protected branches refuse commits.** `/commit` reads **Protected** from the `### Branch model` block in `CLAUDE.md`. Block absent or field empty → no branch is protected and it proceeds (the starter's own default is committing on `main`).
- **The Branch model block is the single source of branch facts.** Where to base work, where a PR lands, which branches are protected — every command reads it there instead of guessing. Block absent → resolve `git symbolic-ref refs/remotes/origin/HEAD`, then `main`, then `master`; **never assume `develop`**. `**Merge:**` absent → squash for working types, merge commit for `release`/`hotfix`. The presets and how `/setup:create-CLAUDE_MD` expands them into the six fields: `.claude/commands/setup/create-CLAUDE_MD.md → Identify Git Workflow`.

## Attribution

`Never include AI attribution` is enforced by the `attribution` key in `settings.json` (`"commit": "", "pr": "", "sessionUrl": false`). The host injects a session instruction that outranks any rule file, so the setting is what actually switches it off — keep the key. A rule-file sentence alone let the default read as "requested" in at least one downstream project, and a whole release carried the trailer before the key was added.

## Commit and release conventions

- Conventional commits: `type(scope): subject`, imperative, lowercase, ≤72 chars; the body explains *why*.
- `/commit` stages an explicit list and refuses a protected branch; `/push` / `/pull` resolve the current branch; `/release` bumps the detected manifest, CHANGELOG and tag.
- `guard-commit.sh` runs before the command, so for a chained `git add <paths> && git commit` it stages those explicit paths into a temporary copy of the index and judges that set (empty-commit and credential checks); `git add -A` / `.` / `-u`, a `;` or another command in the chain are judged on the real index as before.
