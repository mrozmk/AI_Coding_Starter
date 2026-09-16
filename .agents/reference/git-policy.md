# Git policy — permission tiers, branches, the pipeline's git

Pointed at from `CLAUDE.md → Git Workflow`. `CLAUDE.md` keeps the three guardrails (worktree, attribution, the Branch model block); this file explains the mechanics behind them. The enforcing configuration is [.claude/settings.json](../../.claude/settings.json), which is the source of truth for which command sits in which tier.

## Three permission tiers

Precedence `deny` > `ask` > `allow`:

- **`deny`** is absolute — no prompt or classifier overrides it. Holds every history rewrite and every unrecoverable discard: `push --force`, `reset --hard`, `clean -f`, `checkout -- <path>`, `restore .`, `rebase`, `pull --rebase`, `cherry-pick`, `config`, `remote set-url` / `remove` / `rename`, `reflog expire`, `gc --prune`, forced `switch`.
- **`ask`** always prompts, even in auto mode: `merge --no-ff`, `merge --squash`, `branch -d` / `-D`, `git rm`, `remote add`.
- **`allow`** covers the read-only and the routine: `status`, `diff`, `log`, `add`, `commit`, `push`, `pull`, `fetch`, `stash`, `tag`, `switch`, `revert`, plus the pipeline's `worktree add` / `list` / `prune` / `remove` and `merge --ff-only`.
- Anything in no list (bare `git merge`, soft/mixed `git reset`) prompts interactively.

An `allow` cannot be scoped to one command, so **`git worktree` and `git merge --ff-only` are allow-listed only so `/orchestrate` runs without per-step prompts** — using them ad hoc in a normal session is a behavioral rule, not a hard gate. The one thing that can still discard work through an `allow` is `git worktree remove --force`; its only guard is the pipeline's `status --porcelain` check (Step 5.5 and Phase 7), which force-removes a worktree only when it is clean and fully merged. That sentence lives in `CLAUDE.md` because nothing else holds it.

## Branches

- **A new branch must not track a protected branch.** `git switch -c` / `checkout -b` from `origin/<protected>` auto-sets that branch as upstream, so a bare `git push` targets it directly. Create with `--no-track` (or run `git branch --unset-upstream` right after) and let `/push` set the upstream on first push.
- **Protected branches refuse commits and pipeline runs.** `/commit` and `/orchestrate` Phase 4 read **Protected** from the `### Branch model` block in `CLAUDE.md`. Block absent or field empty → no branch is protected and both proceed (the starter's own default is committing on `main`).
- **The Branch model block is the single source of branch facts.** Where to base work, where a PR lands, which branches are protected — every command reads it there instead of guessing. Block absent → resolve `git symbolic-ref refs/remotes/origin/HEAD`, then `main`, then `master`; **never assume `develop`**. `**Merge:**` absent → squash for working types, merge commit for `release`/`hotfix`. The presets and how `/setup:create-CLAUDE_MD` expands them into the six fields: `.claude/commands/setup/create-CLAUDE_MD.md → Identify Git Workflow`.

## The pipeline's git

- **`/orchestrate` pushes the current branch**, not a hardcoded `main`. Parallel runs and the supervised `--integrate` merge queue: [parallel-orchestration.md](parallel-orchestration.md).
- **`Orchestrate publish:`** in `CLAUDE.md` is the mode `/orchestrate` uses when no `--publish` flag is given (Phase 4, resolution step 2). `push` — the pipeline pushes each step commit to the run branch. `branch-local` — it commits but **never** pushes; publishing is a separate human act (open a PR, review, merge). Choose `branch-local` for any PR-gated project (GitFlow, protected `main`/`develop`, mandatory review), where a pipeline push is rejected server-side rather than merely unwelcome. Omitting the line means `push`; dropping it during a regeneration silently turns a `branch-local` project back into a pushing one.

## Attribution

`Never include AI attribution` is enforced by the `attribution` key in `settings.json` (`"commit": "", "pr": "", "sessionUrl": false`). The host injects a session instruction that outranks any rule file, so the setting is what actually switches it off — keep the key. A rule-file sentence alone let the default read as "requested" in at least one downstream project, and a whole release carried the trailer before the key was added.

## Commit and release conventions

- Conventional commits: `type(scope): subject`, imperative, lowercase, ≤72 chars; the body explains *why*.
- `/commit` stages an explicit list and refuses a protected branch; `/push` / `/pull` resolve the current branch; `/release` bumps the detected manifest, CHANGELOG and tag.
- Chained `git add X && git commit` is blocked by `guard-commit.sh`, which inspects the staged set *before* the chain runs and sees it empty. Stage and commit in two calls.
