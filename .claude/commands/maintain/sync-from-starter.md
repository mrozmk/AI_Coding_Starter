---
description: Sync the AI workflow (.claude/ + .agents/ framework) from the upstream AI_Coding_Starter — 3-way aware, task-driven, recommend-but-ask on conflicts, edits delegated to subagents
argument-hint: [--check | <starter-ref>]
---

# /maintain:sync-from-starter — Cyclical workflow sync from upstream

Pull newer workflow definitions (commands, agents, skills, templates, hooks, config) from
the upstream **AI_Coding_Starter**, while preserving everything project-specific. Built for
**repeated** use over a project's lifetime — so it tracks provenance and resolves conflicts
by recommending and **asking**, never by silently overwriting.

This command runs as a **task-driven, file-by-file loop**. The diff produces a task list; each
differing file becomes one task; you (the user) are a **hard gate** on every task; and the actual
edits are delegated to a **subagent per approved file/cluster** so the orchestrating session never
fills its context window applying changes. The main session only diffs, analyzes, recommends, and
records your decisions.

> **This command orchestrates [.claude/starter-sync-playbook.md](../../starter-sync-playbook.md)** — that playbook owns the
> authoritative **A / B / C file classification** and the dry-run → approval → apply flow.
> This command does **not** duplicate it; it executes it and adds five things the bare
> playbook lacks: **provenance manifest**, **3-way merge**, **upstream-deletion handling**,
> a **conflict protocol** for `settings.json` / hooks / `memory-domains.json`, and the
> **task-driven per-file loop with subagent-delegated edits** described below.

**Prerequisite:** the project already has `.claude/` and `CLAUDE.md`. If it does **not**, stop —
this is a _bootstrap_, not a sync (use GitHub "Use this template" instead). If the project is a
huge codebase that never had `.claude/`, that is the _brownfield retrofit_, also not this command.

---

## Modes (from `$ARGUMENTS`)

| Invocation                            | Behavior                                                                                                                                           |
| ------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------- |
| `/maintain:sync-from-starter`         | Full run: clone → classify → **build task list** → **per-task loop** (analyze → user gate → subagent edit) → write manifest → propose commit.      |
| `/maintain:sync-from-starter --check` | Dry-run only. Clone + classify + build the task list + report. Writes nothing, spawns no edit subagents, no manifest, no commit.                   |
| `/maintain:sync-from-starter <ref>`   | Pin to a specific starter ref (tag/branch/commit, e.g. `v2.1.0`). Clones that ref instead of floating `main`. Safer for controlled, audited syncs. |

---

## Step 0a: Open the upstream-findings handoff (accumulate regressions for fixing the starter)

Throughout the run you will discover places where the **starter is worse than this mature project**
(it reverts a project convention, re-introduces a dead assumption, ships only cosmetic churn) — and,
occasionally, the reverse (the project's version should be **contributed back** upstream). These are
valuable for a later session that improves `AI_Coding_Starter` itself, and they vanish if not written
down. So treat a findings handoff as a **first-class output of every sync**, exactly as done in the
2026-06-14 run:

- **Open/locate** `.agents/handoffs/starter-upstream-regressions.md` at the start. If it doesn't exist,
  create it with a short header (cel: zasilić upstream AI_Coding_Starter) and a "discoveries below"
  marker. If it exists, **append** to it (newest run's findings under a dated subsection) — don't
  overwrite prior runs' notes.
- **As you decide each task**, when the reason for `keep project` is "starter regressed / re-introduced
  a bug / project is ahead", write a section: **what the starter does**, **why it's a regression (or a
  contribution candidate)**, **what upstream should adopt**, and the **decision taken this sync**.
  Distinguish three kinds, like the reference handoff: (1) real starter regressions to fix upstream,
  (2) deliberate starter generalizations that are NOT bugs (so a future session doesn't "fix" them),
  (3) reverse contributions (project → starter).
- The handoff lives under `.agents/handoffs/` — a **local, per-clone scratchpad** kept out of git via
  `.git/info/exclude` (so it stays `@`-referenceable, not greyed out). Do not stage or commit it.
- At the end, the final report points the user at this file ("findings for improving the starter:
  `@.agents/handoffs/starter-upstream-regressions.md`").

> Why this is a step, not an afterthought: the orchestrator holds the full diff + the reasoning for
> every keep-project decision **only during the run**. That context is the raw material for fixing the
> starter, and it's gone next session. Capturing it now is the cheapest it will ever be.

## Step 0: Read provenance (enables 3-way)

Look for **`.claude/.starter-sync.json`** (committed — shared team state):

```json
{
  "starter_repo": "https://github.com/mrozmk/AI_Coding_Starter",
  "last_sync_commit": "<short-hash>",
  "last_sync_ref": "main",
  "last_sync_date": "YYYY-MM-DD"
}
```

- **Present** → you have a `base` (the starter revision the project last synced from). This unlocks true **3-way merge** in Step 2 — distinguishing _intentional local edits_ from _staleness_, and detecting _upstream deletions_.
- **Absent** (first sync ever, or pre-manifest project) → **2-way fallback**: no `base`, so you cannot tell a local command edit from an old one. In that mode, before overwriting any category-A file that differs, run `git log --oneline -- <file>` and **flag** files the project committed after their initial add as "possible local edit — confirm overwrite". Note in the report that 3-way kicks in from the _next_ sync once the manifest is written.

---

## Step 1: Clone the starter

```bash
# /tmp may not exist as a clone target across restarts; clone into a fresh dir.
git clone https://github.com/mrozmk/AI_Coding_Starter /tmp/ai-coding-starter-sync
```

- If `/tmp/ai-coding-starter-sync` already exists, remove it first (the sandbox may deny `rm -rf` chained with `git clone` — run the removal as its own step, or clone into a suffixed dir).
- If a `<ref>` arg was given: `git -C /tmp/ai-coding-starter-sync checkout <ref>` (fail loudly if the ref doesn't exist — do not silently fall back to `main`).
- Record `theirs` hash: `git -C /tmp/ai-coding-starter-sync rev-parse --short HEAD`.
- If `base` exists, also record the upstream delta for the report: `git -C /tmp/ai-coding-starter-sync log --oneline <base>..HEAD` → "N upstream commits since last sync".

> A shallow `--depth 1` clone is fine for 2-way mode. For 3-way you need history back to `base`, so clone full (omit `--depth 1`) when a manifest exists.

## Step 2: Classify with 3-way awareness

Apply the **A / B / C classification from [.claude/starter-sync-playbook.md → Step 2](../../starter-sync-playbook.md)** (authoritative — includes `hooks/`→A, `memory-domains.json`/`.editorconfig`→B, `LICENSE`→C). For each file, compute the 3-way verdict:

| `base` vs `ours` (project) | `base` vs `theirs` (new starter)            | Verdict                                                                                                   |
| -------------------------- | ------------------------------------------- | --------------------------------------------------------------------------------------------------------- |
| same (project untouched)   | changed                                     | **clean upstream update** → overwrite, no prompt (category A)                                             |
| changed (project edited)   | same                                        | **local customization** → keep project, skip overwrite, note it                                           |
| changed                    | changed                                     | **TRUE CONFLICT** → 3-way diff, recommend, **ask** (Step 3)                                               |
| existed in base            | **deleted in theirs**, project copy == base | **safe upstream deletion** → offer to remove (project never customized it)                                |
| existed in base            | deleted in theirs, project copy != base     | **deleted upstream but locally edited** → keep + flag ("upstream removed this; you modified it — decide") |
| absent in base             | new in theirs                               | **new file** → add                                                                                        |
| absent in theirs           | present in project, absent in base          | **project-custom** → never touch, flag "check if needed"                                                  |

> Without a `base` (2-way), collapse to the playbook's original new/changed/identical/custom buckets plus the `git log` local-edit flag from Step 0.

**Compute the raw diff up front** so the task list has hard data, not guesses:

- `diff -rq` per category-A tree (commands, agents, skills, templates, hooks, workflows) → which files are new / changed / project-only.
- For each "changed" file, compute a **content-only** diffstat that ignores whitespace (`diff -wB`) — a file that differs only by blank lines / trailing space is effectively identical and should be marked so, not treated as a real change. This prevents whitespace noise from inflating the task list.
- Record `ours:N theirs:M` (lines each side has that the other lacks) per file — this is the signal that separates a tiny upstream tweak from a heavy local customization.

## Step 2.5: Build the task list (NEW — this is the spine of the run)

This is what makes the run task-driven. **Do the diff FIRST (Step 2), then turn it into tasks** — do not analyze any file before the full list exists.

1. **One task per differing file.** Use `TaskCreate`, one task per file that is new, changed (real content diff, not whitespace-only), a true conflict, a project-custom path-conflict, or a category-B merge candidate. Identical-modulo-whitespace files get **no task** (note them once in the report and move on).
1b. **Skip bootstrap-only artifacts — NO task at all.** This command runs on an **already-bootstrapped, existing project**, not a fresh "Use this template" clone. The following exist only to seed a brand-new repo and are meaningless to re-check or re-add here — exclude them from the task list entirely and just note them in one line of the report:
   - **`.claude/README.md`** (the framework guide) and **`.claude/STARTER-LICENSE`** — bootstrap-time artifacts produced/placed by `/setup:create-CLAUDE_MD`. A mature project either already has them or deliberately doesn't; the sync should not nag about adding them. (If a project genuinely wants them later, that's a one-off manual copy, not a sync concern.)
   - **root `LICENSE`** and **root `README.md`** — category C, the project's own. Never a task.
   - **`.claude/commands/setup/create-CLAUDE_MD.md`** as a *bootstrap driver* — do **not** treat its starter changes as something to apply for bootstrap reasons. It is a normal category-A command like any other: only task it if its content genuinely changed AND you'd take that change for the **running** workflow (e.g. a fix to how it generates files), never "to keep bootstrap in sync". We use this sync inside a live project; the bootstrap chain already ran once and won't run again.
   > Rationale: the user runs `/maintain:sync-from-starter` to keep the **working** toolchain current, not to re-bootstrap. Time spent diffing/asking about `CLAUDE.md` regeneration, the framework README, or the starter license is pure noise — these are not part of the day-to-day workflow surface.
2. **Order the tasks** easiest-decision first: identical/new → clean upstream-update → small conflicts → large local-customization conflicts → path-conflicts. Decisions then compound logically.
3. **Auto-cluster cross-referencing files.** Before locking the list, scan each differing file's content for references to **other files that are also in the diff** (a command that names another command, e.g. `/retro` referencing `/maintain:cleanup-workflow`; a hook referenced by `settings.json`; an agent referenced by a command). When file A references file B **and both are in the diff**, **merge them into a single task-cluster**. Reason: deciding A's edits in isolation can bake in assumptions that B's pending changes would invalidate — you must read both and decide together. Mark the cluster task subject with all member paths. Known hard couplings to always cluster: `settings.json` ⇄ every `hooks/*.sh` it references; a command ⇄ any other command/skill it cross-links that is also changed.
4. **The task list is the source of truth for the rest of the run.** Every subsequent step operates on tasks, marks them `in_progress` when starting, `completed` when the user has decided and (if approved) the subagent has applied the edit.

> If resuming a partially-done sync (tasks already exist from a prior invocation in this session), call `TaskList` first and continue from the first `pending` task — do not rebuild the list or re-clone.

## Step 3: Conflict protocol — recommend, but ask (category B)

`settings.json`, the `hooks` block, and `memory-domains.json` can have **same-key / different-value** conflicts that a union cannot resolve. **Never guess.** These are themselves tasks (Step 2.5) and go through the same per-task gate (Step 4). Apply the recommendation heuristic and present each via **`AskUserQuestion`**:

| Conflict shape                                                                     | Default recommendation               | Reasoning to show the user                                          |
| ---------------------------------------------------------------------------------- | ------------------------------------ | ------------------------------------------------------------------- |
| Starter **tightens** `deny` (new secret prefix, new destructive-git rule)          | **Take starter** (Recommended)       | security hardening — adopt unless you have a reason                 |
| Project has an `allow` the starter lacks                                           | **Keep project** (Recommended)       | stack-specific permission — starter can't know it                   |
| Same hook matcher, **different command**                                           | **Show both, ask**                   | not auto-resolvable — semantics may differ                          |
| Project **loosened** what the starter keeps strict                                 | **Ask** (lean starter)               | may be deliberate, but it's a security debt — surface it explicitly |
| `memory-domains.json` `rules` populated in project, starter only ships `_examples` | **Keep project rules** (Recommended) | path regexes are project-specific                                   |

Pure additions (allow/deny present in one side only) follow the playbook's **union** rule with no prompt — but still surface them in that task's analysis so the user sees what the union added.

## Step 4: The per-task loop — analyze → user gate → delegate edit

Walk the task list in order. **One file (or one cross-ref cluster) at a time.** For each task:

### 4.1 — Analyze (main session, read-only)

- Mark the task `in_progress`.
- Read the differing file(s) in full from BOTH sides (project + `/tmp/ai-coding-starter-sync/...`). For a cluster, read **every** member before deciding anything.
- Show the user a focused write-up for this file/cluster:
  - **What it is** (one line) and the **verdict** from Step 2 (new / clean-update / local-custom / conflict / path-conflict / category-B).
  - **The actual difference** — the meaningful diff, not raw noise. Summarize large diffs; show small ones verbatim.
  - **Recommendation:** one of `apply` (take starter), `adapt` (take starter but adjust to this repo's ecosystem), `keep project` (skip), `partial`, or `delete`.
  - **Pros / cons of implementing (or adapting)** — concrete consequences, both positive and negative. Name regressions explicitly (e.g. "the starter's `prime.md` reverts the `domain/` split — adopting it is a regression").
  - If this is a cluster, state **how the members interact** and why a single combined decision is required.

### 4.2 — User gate (HARD — never skip, never assume)

After the write-up, **stop and let the user decide** for this file/cluster: `apply` / `adapt` / `keep project (skip)` / `partial` / `delete`. For category-B conflicts use `AskUserQuestion` with the Step-3 options (Take starter / Keep project / Show full diff). The user is the gate on **every** task — there is no "obviously safe, auto-apply" exception. Pure-addition unions and clean upstream-updates are _recommended_ strongly, but still confirmed.

### 4.3 — Delegate the edit to a subagent (only after approval; `--check` never reaches here)

If the decision is anything other than `keep project`/skip, **spawn one subagent** (Agent tool, `general-purpose`) to perform that file's/cluster's edit. **Do not edit in the main session** — the whole point is to keep the orchestrator's context clean across many files. Give the subagent a self-contained instruction:

- Exact source path(s) under `/tmp/ai-coding-starter-sync/...` and exact destination path(s) in the project.
- The decision (`apply` verbatim copy / `adapt` with the specific adjustments you and the user agreed / `partial` with the precise hunks to take) — be explicit; the subagent has none of this conversation's context.
- For `adapt`: spell out every ecosystem adjustment (path remaps, command-name remaps like `/cleanup-workflow`→`/maintain:cleanup-workflow`, frontmatter `name:` for slash-command+skill mounting, project language rules). The subagent must NOT invent adaptations beyond the list.
- Post-edit obligations: restore exec bit for `*.sh` (`chmod +x`), keep within the single file/cluster scope, touch nothing else.
- Tell the subagent its final message is a result, not user-facing — it should report back the paths it wrote and any deviation it had to make.

When the subagent returns, relay a one-line result to the user and mark the task `completed`. Move to the next task.

> **Why a subagent per file/cluster:** an `adapt` of a single 700-line command (e.g. `/retro`) can involve reading 2-3 related files and rewriting the whole thing. Doing that inline would burn the orchestrator's window and risk losing the diff/decision state for the remaining tasks. Isolating each edit keeps the main loop able to run the full list in one session.

### 4.4 — `--check` mode

In `--check` mode, do Steps 4.1 only (analysis + recommendation) for every task, skip 4.2–4.3 entirely, then jump to a summary report and STOP. Write nothing, spawn no edit subagents.

## Step 5: Sanity-check (after the loop, before manifest)

Once every task is `completed` (or skipped):

- Confirm exec bit on hooks: `chmod +x .claude/hooks/*.sh`.
- Sanity-check (playbook Step 4.3): links in copied commands resolve, `index.md` has `Loader Convention`, `CLAUDE.md` still references active commands, **hook scripts referenced in `settings.json` all exist on disk** (the G1 coupling check).
- If anything fails, create a follow-up task and resolve it via another subagent — do not leave the tree half-synced.

## Step 6: Write provenance manifest

Write/overwrite **`.claude/.starter-sync.json`** (committed) with the `theirs` hash, ref, and **today's date passed in by the user** (do not invent a date — if unknown, ask or read from `git log -1 --format=%cd`):

```json
{
  "starter_repo": "https://github.com/mrozmk/AI_Coding_Starter",
  "last_sync_commit": "<theirs-short-hash>",
  "last_sync_ref": "<main|tag>",
  "last_sync_date": "YYYY-MM-DD"
}
```

This is what makes the _next_ sync a true 3-way merge. Include it in the staged files. (Skip in `--check` mode.)

## Step 7: Clean up + report + propose commit

- **Remove the starter clone(s) from `/tmp`.** Clean up the dir you cloned into (and any suffixed
  variant or leftover from a prior run, e.g. both `/tmp/ai-coding-starter-sync` and
  `/tmp/ai-coding-starter-sync-<date>`). The sandbox **denies `rm -rf`** (global deny rule — do not try
  to disable the sandbox to force it), so use a non-`rm -rf` deletion:
  ```bash
  find /tmp/ai-coding-starter-sync /tmp/ai-coding-starter-sync-* -depth -delete 2>/dev/null
  ```
  Verify with `ls -d /tmp/ai-coding-starter* 2>/dev/null` (no matches = clean). If even `find -delete`
  is blocked, tell the user the exact dir(s) to remove manually via the `!`-prefix and move on — a
  leftover `/tmp` clone is harmless (wiped on restart), so never let cleanup block the run.
- Final report from the task list: per task — added / updated / adapted / merged / conflict-resolved / deleted / skipped (with the skipped category-C/project-only count). The task list IS the report; summarize it.
- **Point the user at the findings handoff** from Step 0a: `@.agents/handoffs/starter-upstream-regressions.md` — "regressions/contributions captured for improving the starter".
- **Rollback note:** nothing was committed; everything is in the working tree — `git restore <path>` (or `git checkout -- .`) reverts the whole sync. Only `/commit` makes it permanent.
- Propose (do **not** run):
  ```
  chore(workflow): sync .claude from AI_Coding_Starter@<theirs-hash>
  ```

---

## Critical rules

- **Diff first, then tasks, then analyze.** Never analyze or edit a file before the full task list exists (Step 2.5) — otherwise cross-ref clustering can't catch couplings.
- **One file = one user gate.** The user decides every task. No auto-apply, even for "obviously safe" updates — recommend strongly, but confirm.
- **Cluster cross-referencing files.** If a changed file references another changed file, decide them together — never bake a decision about A while B's pending changes are unread.
- **Edits go to subagents, not the main session.** One subagent per approved file/cluster. The orchestrator stays read-only so it can finish the whole list in one window.
- **NEVER overwrite category C** (CLAUDE.md, live memory, specs, plans, root README, LICENSE, code).
- **NEVER remove** `settings.json` entries the starter lacks — additions are a union; only true same-key conflicts are resolved, and only by **asking**.
- **NEVER delete** a project command/file automatically — safe-deletion is still _offered_, never forced.
- **NEVER pick a side on a real conflict** — recommend and ask (`AskUserQuestion`).
- **NEVER commit automatically** — propose the message, let `/commit` run.
- Hooks and `settings.json` move **together** (coupled by path reference — always one cluster).
- `--check` never writes and never spawns edit subagents.
- **NEVER task bootstrap-only artifacts** (Step 2.5.1b) — `.claude/README.md`, `.claude/STARTER-LICENSE`, root `LICENSE`/`README.md`, and `create-CLAUDE_MD` *as a bootstrap driver*. This sync runs on a live project; the bootstrap chain already ran. Note them in one line, never gate on them.
- **ALWAYS keep a findings handoff** (Step 0a) — append upstream regressions / contribution candidates to `.agents/handoffs/starter-upstream-regressions.md` as you make keep-project decisions. It's a local scratchpad; never stage/commit it.
- Clean up the `/tmp` starter clone(s) at the end via `find … -delete` (the sandbox denies `rm -rf`; don't disable the sandbox). A leftover clone is harmless — never let cleanup block the run.
