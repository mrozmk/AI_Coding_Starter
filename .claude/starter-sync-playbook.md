# Sync Claude Code workflow from AI_Coding_Starter

**Goal:** update the workflow definitions (`.claude/`, the `.agents/` framework, `.gitignore`, `.mcp.json`, `.env.example`) in this project, using https://github.com/mrozmk/AI_Coding_Starter as the source of truth. **Preserve everything project-specific** — replace only workflow files.

**Assumption:** the project already has `.claude/` and `CLAUDE.md` (even an older version). If it doesn't — stop and tell me this is a bootstrap, not a sync (in that case use GitHub "Use this template" instead of this prompt).

---

## Step 1: clone the starter into a temp directory

```bash
rm -rf /tmp/ai-coding-starter-sync
git clone --depth 1 https://github.com/mrozmk/AI_Coding_Starter /tmp/ai-coding-starter-sync
```

Save the starter's commit hash (`git -C /tmp/ai-coding-starter-sync rev-parse --short HEAD`) — you'll use it in the final commit message.

## Step 2: classify the files

### Category A — **overwrite wholesale from the starter** (workflow definitions, project-agnostic)

- `.claude/commands/*.md` — all slash commands
- `.claude/agents/*.md` — subagent definitions
- `.claude/skills/**` — skill definitions (e.g. `jira/SKILL.md`)
- `.claude/templates/*.md` — templates (e.g. `CLAUDE-template.md`, `README-template.md`)
- `.claude/hooks/*.sh` — workflow hook scripts (`audit-append`, `check-deps`, `guard-commit`, `guard-push`, `guard-memory`, `guard-comments`, `track-memory-read`, `nudge-lsp`). **Exception: `check-project-deps.sh` is project-owned (category C)** — the starter ships a skeleton; the project fills its toolchain block; a sync never overwrites it. **Coupled with `settings.json`** — the `hooks` block there references these scripts by path, so they must sync together. After copying, restore the executable bit: `chmod +x .claude/hooks/*.sh`.
- `.claude/lib/*.sh` — helper scripts commands invoke directly (`codex-bg.sh`, `qa-probe.sh`). **Coupled with `settings.json`** the same way hooks are: `qa-probe.sh` is reached through an exact `permissions.allow` entry, so a renamed script silently starts prompting. Sync them together and `chmod +x .claude/lib/*.sh` afterwards.
- `.agents/memory/reflection-protocol.md` — the memory write-time protocol + entry/domain templates. Pure framework content (no project entries live in it — those go to `errors.md` / `decisions.md` / …), so overwrite wholesale.
- `*.example` seed files — `.agents/memory/user-profile.md.example`, `.claude/settings.local.json.example`. Overwrite the `.example`; **never** touch the developer's real `user-profile.md` / `settings.local.json` (both gitignored, category C by nature).
- `.claude/README.md` — **the framework guide**. Mind the path mapping: in the starter this guide lives as the **root `README.md`** (the GitHub template page); in a bootstrapped project it lives at `.claude/README.md` (moved there by `/setup:create-CLAUDE_MD`). Strategy: overwrite the project's `.claude/README.md` with the content of the starter's **root `README.md`**. Do **not** copy the starter's root README into the project root — that would destroy the project's README (see category C).
- `.claude/starter-sync-playbook.md` — **this playbook itself**. It is framework content, so it lives under `.claude/` (not `docs/`, which is project-owned / category C) precisely so it can self-update: each sync pulls the newest playbook from upstream. Overwrite wholesale.
- `.claude/workflows/*.js` — `Workflow` orchestration scripts (e.g. `map-codebase.js`). Framework content — overwrite wholesale.
- `.claude/STARTER-LICENSE` — the starter's own license, preserved here at bootstrap (the starter's root `LICENSE` is moved here by `/setup:create-CLAUDE_MD` so the project root `LICENSE` is the cloner's own). Path mapping mirrors `.claude/README.md`: overwrite the project's `.claude/STARTER-LICENSE` with the starter's **root `LICENSE`**. Do **not** touch the project's root `LICENSE` (category C).

### Bootstrap-only — **do not check or add in an existing project** (overrides the above)

This playbook is run on an **already-bootstrapped, live project**, not a fresh "Use this template"
clone. The following are seeding artifacts; re-checking or re-adding them on every sync is pure noise.
**If the project already has them**, you *may* refresh them as the category-A rules above describe —
but **if it doesn't, do not add them, and never make them a task or a question:**

> Profile-excluded paths (`.claude/.starter-sync.json → excluded`) follow the same rule — see the Critical rules exception below; the list lives in that file, not here.

- **`.claude/README.md`** (framework guide) and **`.claude/STARTER-LICENSE`** — listed as category A
  above only for the case where they already exist. In a project that omitted them at bootstrap, leave
  them out. A one-off manual copy covers the rare case where they're wanted later — it is not a sync job.
- **`.claude/commands/setup/create-CLAUDE_MD.md`** — sync it as an ordinary category-A command (apply a
  genuine improvement to how it *runs*), but **never** apply/ask "to keep bootstrap in sync". The
  bootstrap chain (`create-CLAUDE_MD` → generates `CLAUDE.md` + root `README.md`) already ran once and
  will not run again in this project, so its starter changes carry no bootstrap obligation here.
- root `CLAUDE.md`, root `README.md`, root `LICENSE` are category C regardless — never touched.

> Rationale: the sync keeps the **working** toolchain (commands/agents/skills/hooks) current. Effort
> spent diffing or prompting about the framework README, the starter license, or `CLAUDE.md`
> regeneration is wasted in a project that's long past bootstrap.

### Category B — **merge carefully**, show the diff and ask first

- `.claude/settings.json` — the project may have its own permissions. Strategy: take the **union** of the `permissions.allow` / `permissions.ask` / `permissions.deny` entries from the starter and the project (all three tiers — `ask` is a first-class tier, not an afterthought). Do not remove project entries that the starter lacks. Show me the diff before writing.
- `.agents/memory/index.md` — take `Quick Reference` and `Loader Convention` from the starter, but `When to Read` may have project-specific rows appended by `/setup:create-CLAUDE_MD`. Strategy: overwrite with the starter's structure, then restore the project rows (the ones the starter lacks).
- `.agents/memory/*.md` headers (append-mode logs) — the starter's convention is **newest at the END**. Syncing the header changes the instruction only; existing entries are never reordered. A downstream that still has newest-at-TOP files either reverses them once by hand or accepts mixed order — both are fine, `cleanup-workflow` parses dated `##` blocks in any order.
- `.gitignore` — append the entries missing from the starter (e.g. `.claude/audit.log`, `.env`, `.agents/memory/archive/`); **do not remove** project ones.
- `.mcp.json` — **union** of `mcpServers`: add starter servers the project lacks, never remove or rewrite project ones. It must stay secret-free (credentials live in `.env` via `--env-file`).
- `.env.example` — append the starter's variables the project lacks; never remove project ones.
- `.claude/memory-domains.json` — the `guard-memory` path→domain rules. Strategy: take the starter's `_examples` and any new keys, but **preserve project-filled `rules`** (the project's path regexes are project-specific). Show the diff; never wipe populated `rules`.
- `.claude/comment-guard.json` — the `guard-comments` scope + thresholds. Same strategy as `memory-domains.json`: take the starter's `_examples` and any new keys, but **preserve a project-filled `src_globs`** and any tuned `max_comment_percent` (that number is meant to be the project's own comment density, not the starter's default). Show the diff; never wipe a populated `src_globs`.
- `.agents/reference/qa-evidence-families.md` — **an explicit exception to Category C's blanket "`.agents/reference/` — do not touch"**, and it must stay marked as one: without this line the two rules read as contradictory and a future sync picks the wrong one. Strategy is the same as `.agents/memory/index.md` above, and that entry is the precedent: the **framework** sections (`§1` families, `§3` classification signals, `§4` worked examples, `§6` output contract) overwrite from the starter, while the **project** sections (`§2` verifier roster, `§5` not-observable list) are preserved verbatim. Each `##` heading in the file carries a `[framework]` / `[project]` marker — route by that marker, never by section number alone. **Roster completeness:** every family in framework §1 must have a row in project §2. Sync *adds* a missing framework row (verifier · lane · required tooling, copied from the starter) and never removes or rewrites a project row — without this, a downstream receives a new family with no verifier to route it to. Show the diff before writing.
- `.claude/qa-env.json` — the `/prime-qa` environment description. Take new keys and doc strings from the starter, but **preserve every project-filled value** (hosts, probe paths, serve commands). Overwriting these silently re-points QA at nothing.
- `.editorconfig` — append/merge missing keys from the starter; do not drop project-specific overrides.

### Category C — **do not touch** (project content)

- `.claude/hooks/check-project-deps.sh` — the project-owned SessionStart preflight (toolchain + `.env` shape + MCP commands). The starter ships only the skeleton; never overwrite a project's filled copy.

- `CLAUDE.md` — project rules. If the starter has a new section structure, report it and propose a patch — but do not overwrite automatically.
- `.agents/memory/architecture.md`, `project-brief.md`, `domain/*.md` — regenerated from the project (`/setup:create-CLAUDE_MD`, `/maintain:refresh-brief`).
- `.agents/memory/errors.md`, `decisions.md`, `api.md`, `patterns.md` — append-only, project history.
- `.agents/sources/`, `.agents/specs/`, `.agents/plans/`, `.agents/reference/`, `.agents/wiki/`, `.agents/memory/archive/` — project content.
- `README.md` (root) — the **project** README (generated by `/setup:create-CLAUDE_MD` at bootstrap). Never overwrite with starter content. You update the framework guide in `.claude/README.md` (category A).
- `LICENSE` — the project may have relicensed; never overwrite.
- `CHANGELOG.md`, `docs/`, any source files — project documentation and code.

## Step 3: dry-run report (BEFORE any change)

Show me:

1. **Category A — diff:**
   - **New** files (in the starter, absent from the project) → list of full paths
   - **Changed** files (content differs) → list + a concise "what changed" note (1-2 lines per file)
   - **Identical** files → count only, no list
   - Files **in the project but not in the starter** → list, mark as "project custom command? check if needed" — do NOT delete automatically

2. **Category B — proposed merge:**
   - `settings.json`: show which `allow`/`ask`/`deny`/`hooks` entries the starter adds, and which project entries stay untouched
   - `index.md`: show which `When to Read` rows are project-specific and will be carried over
   - `.gitignore`: show the lines to append

3. **Category C — signals:**
   - If a section name in the starter's `CLAUDE.md` doesn't match the project's `CLAUDE.md` (e.g. the starter added "Loader Convention" to "Automatic Behaviors") — report it as a suggestion, don't enforce

**Wait for my approval. Do not write anything to disk before confirmation.**

## Step 4: apply (after my approval)

In order:

1. Copy category A (new + changed) — `cp -r` from `/tmp/ai-coding-starter-sync/` into the project
2. Perform the category B merge — `settings.json` first, then `index.md`, then `.gitignore`
3. **Sanity check:**
   - All links in the copied commands resolve (`rg -o '\[.*?\]\(.*?\.md.*?\)' .claude/commands/`)
   - `.agents/memory/index.md` contains the `Loader Convention` section
   - The project's `CLAUDE.md` still mentions the active commands (those in `.claude/commands/`)
4. Clean up the `/tmp` clone(s). `rm -rf` is `ask`-tier in settings (it prompts for approval; the sandbox may also
   restrict it), so delete without it and cover suffixed/leftover variants:
   `find /tmp/ai-coding-starter-sync /tmp/ai-coding-starter-sync-* -depth -delete 2>/dev/null`
   then verify `ls -d /tmp/ai-coding-starter* 2>/dev/null` shows no matches. If blocked entirely, ask
   the user to remove it manually (`! rm -rf …`) — a leftover clone is harmless and must never block the run.

## Step 5: final report

Show:

- **Added files:** list
- **Updated files:** list
- **Merged files:** list (settings.json, index.md, .gitignore)
- **Skipped (category C):** count
- **Suggested actions:** e.g. "regenerate `architecture.md` via `/setup:create-CLAUDE_MD` if the format changed", "run `/prime` to validate the new context"

Propose a commit message:

```
chore(workflow): sync .claude commands and skills from AI_Coding_Starter@<short-hash>
```

## Critical rules

- NEVER remove entries from `.claude/settings.json` that the starter lacks — those are project permissions
- NEVER overwrite category C files
- NEVER delete project slash commands from `.claude/commands/` — report and ask. **Exception:** paths in `.claude/.starter-sync.json → excluded` were pruned by `/setup:start` after explicit confirmation — never re-add them and never create a task for them
- NEVER commit automatically — show the message and wait for `/commit`
- Always dry-run before apply
- NEVER check or add bootstrap-only artifacts (`.claude/README.md`, `.claude/STARTER-LICENSE`, root `LICENSE`/`README.md`, `create-CLAUDE_MD` as a bootstrap driver) in an existing project — see the "Bootstrap-only" subsection in Step 2
- Clean up the `/tmp` starter clone(s) at the end via `find … -delete` (`rm -rf` is `ask`-tier in settings, not denied); a leftover clone is harmless and must never block the run
