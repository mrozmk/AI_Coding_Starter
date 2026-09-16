# Reference: running `/orchestrate` in parallel (branch-aware build + supervised integration)

The operator runbook for building several `/orchestrate` features at once and bringing them
together on `main`. The mechanism lives in the command
([.claude/commands/orchestrate.md](../../.claude/commands/orchestrate.md) — Phase 4 branch
resolution + **Integration mode**); this file is the *how-to* you actually follow at the terminal.

---

## The zero-setup baseline: run sequentially

> **Before reaching for parallelism, ask whether you need it.** Running two `/orchestrate` plans
> back-to-back on `main` in one clone is the default and needs **no setup at all** — no extra clones,
> no branches, no integration pass. Each run pushes `main`, moves its plan to `done/`, and reflects
> its own memory. Reach for the parallel flow **only** when the wall-clock of building features
> one-at-a-time is the actual bottleneck **and** the features are independent enough to build without
> waiting on each other.

Parallel orchestration trades setup + one supervised merge pass for build throughput. If you have
one feature, or the features are tightly coupled, the sequential baseline is strictly simpler.

---

## When to use the parallel flow

Use it when **all** of these hold:

- You have **2+ independent features** to build, each with its own approved plan under
  `.agents/plans/active/`.
- The features **don't depend on each other's output** (no "feature B imports what feature A just
  created") — otherwise build them in dependency order, sequentially.
- Building them one-at-a-time is a real time cost you want to cut.

If features touch **overlapping files**, expect an integration conflict on the second branch — that
is fine and handled (escalation → you re-order or resolve), but it erodes the parallelism benefit.

---

## Step 1 — one clone per concurrent run (NOT worktrees)

Give each concurrent run its **own clone** — a fully independent `.git`:

```bash
git clone <repo-url> ../myproject-orch-a
git clone <repo-url> ../myproject-orch-b
# ...one per feature you build in parallel
```

**Why clones and not `git worktree`.** A worktree shares the parent repo's `.git`, and
`/orchestrate` collides on that shared state across concurrent runs:

- **`refs/stash` is shared** — the clean-build gate's `git stash push -u` (Step 5.4a-bis) would race
  between runs; one run could pop another's stash.
- **The `step-<id>` branch namespace is shared** — two umbrella runs with the same step id would
  clobber each other's branch.
- **The main-checkout index / working tree is shared** — flat-mode runs edit it directly.

Separate clones give each run an isolated stash, branch namespace, and working tree.

## Step 2 — one `orch-<id>` branch per run

In each clone, create and check out a run branch named `orch-<id>`:

```bash
cd ../myproject-orch-a
git switch -c orch-a          # id = a
git push -u origin orch-a     # first push creates the upstream (Phase 4 handles "no upstream yet")
```

**Naming convention:** `orch-<id>` where `id` matches `[a-z0-9-]+` (e.g. `orch-a`, `orch-auth`,
`orch-billing-ui`). **No slashes** — the id feeds the integration temp-branch name
(`integrate-<id>-<sha>`) and the `/tmp` build-log slug. The pipeline sanitizes a slash to `-` as a
safety net, but the convention is: keep it slash-free.

Detached HEAD is refused: `/orchestrate` runs `git rev-parse --abbrev-ref HEAD` first and STOPs if
it sees literal `HEAD`. Check out a real branch before starting.

## Step 3 — run the pipeline in each window

In each clone, on its `orch-<id>` branch, run `/orchestrate` normally:

```bash
# window A (clone myproject-orch-a, on orch-a):
/orchestrate .agents/plans/active/<feature-a-plan>.md

# window B (clone myproject-orch-b, on orch-b):
/orchestrate .agents/plans/active/<feature-b-plan>.md
```

Each run is **byte-for-byte the normal pipeline**, except:

- every push targets `origin/orch-<id>` instead of `origin/main`;
- on completion it makes a final **`chore: workflow-state` commit** (the moved plan + run-log) and
  pushes it, so those files ride onto `main` in the integration merge;
- it **skips** its own memory-reflection + backlog write-back — those happen **once, centrally**, in
  the integration pass (below). So don't expect a build clone to leave memory edits behind.

## Step 4 — one supervised integration pass

After **every** parallel run has finished and pushed, integrate them from a checkout on `main` (a
fresh clone, or one of the build clones switched back to `main` and pulled):

```bash
git switch main && git pull        # clean main, in sync with origin
/orchestrate --integrate orch-a orch-b        # branches in the order you want them merged
```

What happens, per branch, single-threaded:

1. Fetch + pin the branch's exact tip.
2. Merge it on an isolated temp branch (`integrate-<id>-<sha>`) — **this is where you get one
   `ask` approval prompt.** Approve it. **Expect one prompt per branch.**
3. The merge is validated (the project's `CLAUDE.md → Validation` command) in an isolated worktree.
4. Only if the gate passes does `main` fast-forward onto the validated merge, then push.

`main` never moves until a branch's gate passes. Approving the merge prompt is the one manual action
per branch — this is deliberate: there is **no auto-approve and no settings change**. Auto-approving a
human-supervised merge isn't worth the added attack surface — a scoped `allow` glob can't prove a
branch's origin (permission globs aren't argument-aware), and a PreToolUse `allow` hook doesn't bypass
a matching `ask` rule.

### If a branch conflicts or fails its gate

The queue **aborts that branch cleanly** (discards the temp worktree/branch; `main` is untouched) and
**escalates to you**. Nothing is force-merged, nothing is auto-resolved. Your options are the normal
Phase 6 escalation choices — most commonly: resolve/re-order and re-run `--integrate` for the
remaining branches. Because `main` only advanced for branches that already passed, re-running is safe.

## Step 5 — central reconciliation happens automatically

The integration pass, after the queue drains, does the **memory reflection + backlog write-back once,
centrally**, reading the merged run-logs now sitting under `.agents/plans/done/` on `main`. It leaves
those writes **uncommitted** for you to review and `/commit`, exactly like a single run does.

> **Don't delete a build clone until integration has consolidated its run-log.** The run-log is the
> only record of what each parallel run did; central reflection reads it from `main` after the merge.
> Once `--integrate` has merged a branch and you've `/commit`ted the central reconciliation, the clone
> is safe to remove.

---

## Quick checklist

- [ ] Features are genuinely independent (else: build sequentially).
- [ ] One clone per concurrent run; each on its own `orch-<id>` branch (`[a-z0-9-]+`, no slashes).
- [ ] Each `orch-<id>` pushed to origin (creates the upstream).
- [ ] Ran `/orchestrate <plan>` in each clone; all finished + pushed (incl. the `chore: workflow-state` commit).
- [ ] From a clean `main` checkout: `/orchestrate --integrate orch-a orch-b …`.
- [ ] Approved one merge prompt per branch; resolved/re-ran on any escalation.
- [ ] `/commit`ted the central memory/backlog reconciliation.
- [ ] Deleted the build clones (and, if you like, the merged `orch-*` / `integrate-*` branches — `ask`-tier, your call).
