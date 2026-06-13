---
description: Sync the AI workflow (.claude/ + .agents/ framework) from the upstream AI_Coding_Starter — 3-way aware, recommend-but-ask on conflicts
argument-hint: [--check | <starter-ref>]
---

# /maintain:sync-from-starter — Cyclical workflow sync from upstream

Pull newer workflow definitions (commands, agents, skills, templates, hooks, config) from
the upstream **AI_Coding_Starter**, while preserving everything project-specific. Built for
**repeated** use over a project's lifetime — so it tracks provenance and resolves conflicts
by recommending and **asking**, never by silently overwriting.

> **This command orchestrates [.claude/starter-sync-playbook.md](../../starter-sync-playbook.md)** — that playbook owns the
> authoritative **A / B / C file classification** and the dry-run → approval → apply flow.
> This command does **not** duplicate it; it executes it and adds four things the bare
> playbook lacks: **provenance manifest**, **3-way merge**, **upstream-deletion handling**,
> and a **conflict protocol** for `settings.json` / hooks / `memory-domains.json`.

**Prerequisite:** the project already has `.claude/` and `CLAUDE.md`. If it does **not**, stop —
this is a *bootstrap*, not a sync (use GitHub "Use this template" instead). If the project is a
huge codebase that never had `.claude/`, that is the *brownfield retrofit*, also not this command.

---

## Modes (from `$ARGUMENTS`)

| Invocation | Behavior |
|---|---|
| `/maintain:sync-from-starter` | Full run: clone `main` HEAD → classify → **dry-run report** → wait for approval → apply → write manifest → propose commit. |
| `/maintain:sync-from-starter --check` | Dry-run only. Report what *would* change and stop. Writes nothing, no manifest, no commit. Use as a cheap "what's new upstream?" check. |
| `/maintain:sync-from-starter <ref>` | Pin to a specific starter ref (tag/branch/commit, e.g. `v2.1.0`). Clones that ref instead of floating `main`. Safer for controlled, audited syncs. |

---

## Step 0: Read provenance (enables 3-way)

Look for **`.claude/.starter-sync.json`** (committed — shared team state):

```json
{ "starter_repo": "https://github.com/mrozmk/AI_Coding_Starter",
  "last_sync_commit": "<short-hash>", "last_sync_ref": "main", "last_sync_date": "YYYY-MM-DD" }
```

- **Present** → you have a `base` (the starter revision the project last synced from). This unlocks true **3-way merge** in Step 2 — distinguishing *intentional local edits* from *staleness*, and detecting *upstream deletions*.
- **Absent** (first sync ever, or pre-manifest project) → **2-way fallback**: no `base`, so you cannot tell a local command edit from an old one. In that mode, before overwriting any category-A file that differs, run `git log --oneline -- <file>` and **flag** files the project committed after their initial add as "possible local edit — confirm overwrite". Note in the report that 3-way kicks in from the *next* sync once the manifest is written.

---

## Step 1: Clone the starter

```bash
rm -rf /tmp/ai-coding-starter-sync
git clone https://github.com/mrozmk/AI_Coding_Starter /tmp/ai-coding-starter-sync
```

- If a `<ref>` arg was given: `git -C /tmp/ai-coding-starter-sync checkout <ref>` (fail loudly if the ref doesn't exist — do not silently fall back to `main`).
- Record `theirs` hash: `git -C /tmp/ai-coding-starter-sync rev-parse --short HEAD`.
- If `base` exists, also record the upstream delta for the report: `git -C /tmp/ai-coding-starter-sync log --oneline <base>..HEAD` → "N upstream commits since last sync".

> A shallow `--depth 1` clone is fine for 2-way mode. For 3-way you need history back to `base`, so clone full (omit `--depth 1`) when a manifest exists.

## Step 2: Classify with 3-way awareness

Apply the **A / B / C classification from [.claude/starter-sync-playbook.md → Step 2](../../starter-sync-playbook.md)** (authoritative — includes `hooks/`→A, `memory-domains.json`/`.editorconfig`→B, `LICENSE`→C). For each file, compute the 3-way verdict:

| `base` vs `ours` (project) | `base` vs `theirs` (new starter) | Verdict |
|---|---|---|
| same (project untouched) | changed | **clean upstream update** → overwrite, no prompt (category A) |
| changed (project edited) | same | **local customization** → keep project, skip overwrite, note it |
| changed | changed | **TRUE CONFLICT** → 3-way diff, recommend, **ask** (Step 3) |
| existed in base | **deleted in theirs**, project copy == base | **safe upstream deletion** → offer to remove (project never customized it) |
| existed in base | deleted in theirs, project copy != base | **deleted upstream but locally edited** → keep + flag ("upstream removed this; you modified it — decide") |
| absent in base | new in theirs | **new file** → add |
| absent in theirs | present in project, absent in base | **project-custom** → never touch, flag "check if needed" |

> Without a `base` (2-way), collapse to the playbook's original new/changed/identical/custom buckets plus the `git log` local-edit flag from Step 0.

## Step 3: Conflict protocol — recommend, but ask (category B)

`settings.json`, the `hooks` block, and `memory-domains.json` can have **same-key / different-value** conflicts that a union cannot resolve. **Never guess.** For each conflict, apply the recommendation heuristic and present it via **`AskUserQuestion`** (one question per conflict, or grouped if many):

| Conflict shape | Default recommendation | Reasoning to show the user |
|---|---|---|
| Starter **tightens** `deny` (new secret prefix, new destructive-git rule) | **Take starter** (Recommended) | security hardening — adopt unless you have a reason |
| Project has an `allow` the starter lacks | **Keep project** (Recommended) | stack-specific permission — starter can't know it |
| Same hook matcher, **different command** | **Show both, ask** | not auto-resolvable — semantics may differ |
| Project **loosened** what the starter keeps strict | **Ask** (lean starter) | may be deliberate, but it's a security debt — surface it explicitly |
| `memory-domains.json` `rules` populated in project, starter only ships `_examples` | **Keep project rules** (Recommended) | path regexes are project-specific |

`AskUserQuestion` options per conflict: **Take starter (Recommended where security) / Keep project / Show full diff**. The user decides every genuine conflict. Pure additions (allow/deny present in one side only) follow the playbook's **union** rule with no prompt.

## Step 4: Dry-run report

Produce the playbook's **Step 3 report**, plus:
- **Upstream delta:** `N commits` since `<base>` (or "first sync — no baseline").
- **3-way verdicts table:** counts per verdict (clean-update / local-custom / conflict / safe-deletion / deleted-but-edited / new / project-custom).
- **Pending conflicts:** the list that Step 3 will ask about.

**`--check` mode stops here.** Otherwise: **wait for approval. Write nothing before confirmation.**

## Step 5: Apply (after approval)

Follow the playbook's **Step 4** order: category A (new + changed + approved overwrites) → category B merges (settings → index.md → .gitignore → memory-domains.json → .editorconfig) → resolve each Step-3 conflict per user's choice → process approved deletions.

Then:
- `chmod +x .claude/hooks/*.sh` (restore exec bit after copy).
- Sanity-check (playbook Step 4.3): links resolve, `index.md` has `Loader Convention`, `CLAUDE.md` still references active commands, **hook scripts referenced in `settings.json` all exist on disk** (the G1 coupling check).

## Step 6: Write provenance manifest

Write/overwrite **`.claude/.starter-sync.json`** (committed) with the `theirs` hash, ref, and **today's date passed in by the user** (do not invent a date — if unknown, ask or read from `git log -1 --format=%cd`):

```json
{ "starter_repo": "https://github.com/mrozmk/AI_Coding_Starter",
  "last_sync_commit": "<theirs-short-hash>", "last_sync_ref": "<main|tag>", "last_sync_date": "YYYY-MM-DD" }
```

This is what makes the *next* sync a true 3-way merge. Include it in the staged files.

## Step 7: Clean up + report + propose commit

- `rm -rf /tmp/ai-coding-starter-sync`
- Final report (playbook Step 5): added / updated / merged / conflicts-resolved / deleted / skipped (category C count).
- **Rollback note:** nothing was committed; everything is in the working tree — `git restore <path>` (or `git checkout -- .`) reverts the whole sync. Only `/commit` makes it permanent.
- Propose (do **not** run):
  ```
  chore(workflow): sync .claude from AI_Coding_Starter@<theirs-hash>
  ```

---

## Critical rules

- **NEVER overwrite category C** (CLAUDE.md, live memory, specs, plans, root README, LICENSE, code).
- **NEVER remove** `settings.json` entries the starter lacks — additions are a union; only true same-key conflicts are resolved, and only by **asking**.
- **NEVER delete** a project command/file automatically — safe-deletion (verdict in Step 2) is still *offered*, never forced.
- **NEVER pick a side on a real conflict** — recommend and ask (`AskUserQuestion`).
- **NEVER commit automatically** — propose the message, let `/commit` run.
- Hooks and `settings.json` move **together** (coupled by path reference).
- Always dry-run before apply; `--check` never writes.
- Clean up `/tmp/ai-coding-starter-sync` at the end.
