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
- `.claude/templates/*.md` — templates (e.g. `CLAUDE-template.md`, `README-template.md`), and `.claude/templates/regression/**` — the regression runner templates `/setup:regression` copies into a project's e2e directory, including `visual.config.ts.template` and `visual.spec.ts.template` of the Visual stage (the copies there are project code, category C)
- `.claude/hooks/*.sh` — workflow hook scripts (`audit-append`, `check-deps`, `guard-commit`, `guard-push`, `guard-memory`, `guard-comments`, `track-memory-read`, `nudge-lsp`, `warm-lsp`, `guard-jira-transition` — inert unless the profile's `workflow.jira_transition_comment` is true). **`.claude/hooks/lib/leak-patterns.sh`, `git-segments.sh` and `memory-domain.sh` are core and travel with them** — `guard-commit` and `guard-push` source the first two and `guard-memory` sources `memory-domain.sh` (the path→domain lookup), so sync them in the same step even in a project without the team harness (without them both git hooks skip their secret scan, loudly, and the memory guard fails open and stops enforcing, silently). **Exception: `check-project-deps.sh` is project-owned (category C)** — the starter ships a skeleton; the project fills its toolchain block; a sync never overwrites it. **Coupled with `settings.json`** — the `hooks` block there references these scripts by path, so they must sync together. After copying, restore the executable bit: `chmod +x .claude/hooks/*.sh`.
- `.claude/lib/*.sh` and `.claude/lib/*.mjs` — the helpers directly in `.claude/lib/` that commands invoke (`codex-bg.sh`, `qa-probe.sh`, `tree-fingerprint.sh` and `finder-model.sh` for `/check-implementation`'s finders, `backlog-check.mjs` with `yaml-subset.mjs`, `delivery-plan.mjs` and `backlog-migrate.mjs` (both import `backlog-check.mjs`), `github-sync.mjs`, `standards-tools.mjs` and `coding-standards-render.mjs`), in **every** project; never `*.test.mjs` (tests stay in the starter), and **except the `own` and `shared` entries of `.claude/team/manifest.txt`** (the team-harness bullet below and category B). **The tracker adapter is core:** `team-tracker.sh` and the `team-profile.sh` it sources keep their `team-` names but are `!` lines in the manifest, not `own` — `/start-task`, `/pr-create`, `/tasks-status` and `/github-sync` call them in projects without teams, so they travel here, never with the harness. **So is the start's claim** `team-claim.sh`, a `!` line too: `/start-task` runs it without teams (it calls `team-pr.sh` only when that file is installed). **So is the stage-end writer** `.claude/lib/costs/runtime-mark.sh`, a `!` line inside the team-only `.claude/lib/costs/**` tree: the core pipeline commands end with its no-op `stage end` step, so sync it with this step in every project (only the stage hook it feeds and the rest of the cost tool stay team). **Coupled with `settings.json`** the same way hooks are: `qa-probe.sh` and the `runtime-mark.sh … stage end` step are reached through exact `permissions.allow` entries, so a renamed script silently starts prompting. Sync them together and `chmod +x .claude/lib/*.sh` afterwards. **The touch log is core:** `touches.sh` and the `touches.py` it runs (the one top-level `.py` this bullet carries), with `.claude/hooks/touch-notify.sh` and its `Notification` entry in `settings.json` — sync all four together.
- `.claude/lib/guarded-writes/**` — the opt-in guarded-write kit (`az-write.sh`, `ops-write.sh`, `sqlcmd-write.sh` + `guarded_write.py`, which imports the core classifier `.claude/hooks/lib/guard_destructive_sql.py`), core in every project and inert until `workflow.guarded_writes` is true. The project's own `.claude/guarded-writes.json` (its allow-list) and the settings ask/deny block the Operator pasted are **category C** — never synced, never overwritten.
- `.claude/lib/local-env/**` — the opt-in local env runner (`with-local-env.sh`, `local-env-init.sh` + `local_env.py`), core in every project and inert until `workflow.local_env` is true. The project's `.claude/local-env.json` (its runner registry) and the settings block the Operator pasted are **category C**.
- `.claude/lib/remote-build/**` — the opt-in remote build check (`remote-build-check.sh`, `remote-build-node.sh` + `remote_build.py`), core in every project and inert until `workflow.remote_build` is true. The project's `.claude/remote-build.json` (node and command) is **category C**.
- `.claude/lib/trunk-trust/**` — the trunk-trust code the opt-in kits load (`trunk_trust.py`); sync it in the same step as any of them, or the kit fails to start. A project that pasted a kit's settings block before this tree existed adds its `Edit`/`Write` deny lines (both reference docs, §settings).
- `.claude/lib/regression/**` — the opt-in regression kit (`config.mjs`, `catalog.mjs`, `setup.mjs`, `policy.mjs`, `guard.mjs`, `run.mjs`, `visual.mjs`, `visual-spec.mjs`), core in every project and inert until `.claude/regression.json` exists. `catalog.mjs` and `setup.mjs` import `.claude/lib/backlog-check.mjs` — sync them in the same step. `guard.mjs` is imported by the project's copied runner config and fixtures, and `visual-spec.mjs` by the copied visual config and spec (category C), so a guard fix reaches the project through this sync. **Coupled with `settings.json`** once the Operator adds the allow entries `Bash(node .claude/lib/regression/catalog.mjs:*)`, `Bash(node .claude/lib/regression/setup.mjs:*)`, `Bash(node .claude/lib/regression/run.mjs:*)` and `Bash(node .claude/lib/regression/policy.mjs:*)` (`/setup:regression` grants the first two and `/regression-tests` — a category-A command like every `.claude/commands/*.md` — grants the last two through its own `allowed-tools`). The project's `.claude/regression.json` is **category C**. `.agents/regression/runs/` holds per-machine run records and confirmation tokens: it ignores itself (its own `.gitignore` holds `*`) and is never synced.
- **Team harness (manifest-driven)** — every `own` path listed in `.claude/team/manifest.txt` is category A, including the whole trees `.claude/team/**`, `.claude/lib/costs/**` and `.claude/hooks/lib/**` minus the core files the manifest names with `!` (`leak-patterns.sh`, `git-segments.sh`, `memory-domain.sh`, `team-tracker.sh`, `team-profile.sh`, `team-claim.sh`, `costs/runtime-mark.sh`, `guard_destructive_sql.py`; the harness tests are excluded there by the `!` lines and are never distributed), plus the `.agents/reference/` files and `.agents/memory/reflection-protocol.md` the manifest names. The manifest is the list — do not re-derive it by globbing; for upstream deletions read the `base` manifest too (`/maintain:sync-from-starter` Step 2), so a path dropped from both the tree and the manifest is still offered for removal. A `retired <path> <blob>…` line names such a file with the blob ids of the versions the starter shipped: a project copy with one of those ids is an unchanged pointer and goes; any other content is a local edit to confirm first. **This is an explicit exception to category C's blanket "`.agents/reference/` — do not touch"**, limited to the paths the manifest names (`team-mode.md`, `team-pipeline.md`, `worker-clone.md`, `security-egress.md`, `permission-probes.md`); every other file under `.agents/reference/` stays category C. A project that has no harness at all does not get one from a sync — it installs it once with `/setup:teams` (`.claude/lib/team-setup.sh`), which never overwrites an existing file.
- `.agents/memory/reflection-protocol.md` — the memory write-time protocol + entry/domain templates. Pure framework content (no project entries live in it — those go to `errors.md` / `decisions.md` / …), so overwrite wholesale.
- `*.example` seed files — `.agents/memory/user-profile.md.example`, `.claude/settings.local.json.example`, `.claude/regression.json.example`. Overwrite the `.example`; **never** touch the developer's real `user-profile.md` / `settings.local.json` (both gitignored, category C by nature) or the project's `.claude/regression.json` (committed, category C).
- `.claude/docs/**` — **the framework guide** (`guide.md` and any further framework docs). Same path in the starter and in every project — overwrite wholesale, and add it when the project has none yet (a project bootstrapped before this directory existed). The starter's root `README.md` is only its landing page and is **never** synced (category C).
- `.claude/README.md` — **legacy**: the old framework guide that `/setup:create-CLAUDE_MD` used to move here at bootstrap. Not synced any more (its content now lives in `.claude/docs/`); leave an existing copy alone — never update it, never add it, never make it a task.
- `.claude/starter-sync-playbook.md` — **this playbook itself**. It is framework content, so it lives under `.claude/` (not `docs/`, which is project-owned / category C) precisely so it can self-update: each sync pulls the newest playbook from upstream. Overwrite wholesale.
- `.claude/workflows/*.js` — `Workflow` orchestration scripts (e.g. `map-codebase.js`). Framework content — overwrite wholesale.
- `.claude/STARTER-LICENSE` — the starter's own license, preserved here at bootstrap (the starter's root `LICENSE` is moved here by `/setup:create-CLAUDE_MD` so the project root `LICENSE` is the cloner's own). Path mapping: overwrite the project's `.claude/STARTER-LICENSE` with the starter's **root `LICENSE`**. Do **not** touch the project's root `LICENSE` (category C).

### Bootstrap-only — **do not check or add in an existing project** (overrides the above)

This playbook is run on an **already-bootstrapped, live project**, not a fresh "Use this template"
clone. The following are seeding artifacts; re-checking or re-adding them on every sync is pure noise.
**If the project already has them**, you *may* refresh them as the category-A rules above describe —
but **if it doesn't, do not add them, and never make them a task or a question:**

> Profile-excluded paths (`.claude/.starter-sync.json → excluded`) follow the same rule — see the Critical rules exception below; the list lives in that file, not here.

- **`.claude/STARTER-LICENSE`** — listed as category A above only for the case where it already
  exists. In a project that omitted it at bootstrap, leave it out. The legacy **`.claude/README.md`** is
  never synced at all (see category A). A one-off manual copy covers the rare case where they're wanted later — it is not a sync job.
- **`.claude/commands/setup/create-CLAUDE_MD.md`** — sync it as an ordinary category-A command (apply a
  genuine improvement to how it *runs*), but **never** apply/ask "to keep bootstrap in sync". The
  bootstrap chain (`create-CLAUDE_MD` → generates `CLAUDE.md` + root `README.md`) already ran once and
  will not run again in this project, so its starter changes carry no bootstrap obligation here.
- root `CLAUDE.md`, root `README.md`, root `LICENSE` are category C regardless — never touched.

> Rationale: the sync keeps the **working** toolchain (commands/agents/skills/hooks) current. Effort
> spent diffing or prompting about the framework README, the starter license, or `CLAUDE.md`
> regeneration is wasted in a project that's long past bootstrap.

### Category B — **merge carefully**, show the diff and ask first

- **The `shared` entries of `.claude/team/manifest.txt`** (`.claude/lib/codex-bg.sh`, `AGENTS.md`, `.claude/commands/{quick-change,check-implementation,brainstorm,execute}.md`) — files the harness needs but the project legitimately customizes (its own `CODEX_HOME`, its own worker contract). **Merge by hand, never overwrite**: take the starter's team-mode sections, keep every project-specific line. `team-setup.sh` reports these as `conflict (shared — merge by hand)` with a diff instead of touching them.
- `.claude/settings.json` — the project may have its own permissions. Strategy: take the **union** of the `permissions.allow` / `permissions.ask` / `permissions.deny` entries from the starter and the project (all three tiers — `ask` is a first-class tier, not an afterthought). Do not remove project entries that the starter lacks. Show me the diff before writing.
- `.agents/memory/index.md` — take `Quick Reference` and `Loader Convention` from the starter, but `When to Read` may have project-specific rows appended by `/setup:create-CLAUDE_MD`. Strategy: overwrite with the starter's structure, then restore the project rows (the ones the starter lacks).
- `.agents/memory/*.md` headers (append-mode logs) — the starter's convention is **newest at the END**. Syncing the header changes the instruction only; existing entries are never reordered. A downstream that still has newest-at-TOP files either reverses them once by hand or accepts mixed order — both are fine, `cleanup-workflow` parses dated `##` blocks in any order.
- `.gitignore` — append the entries missing from the starter (e.g. `.claude/audit.log`, `.env`, `.agents/memory/archive/`); **do not remove** project ones.
- `.mcp.json` — **union** of `mcpServers`: add starter servers the project lacks, never remove or rewrite project ones. It must stay secret-free (credentials live in `.env` via `--env-file`).
- `.env.example` — append the starter's variables the project lacks; never remove project ones.
- `.claude/memory-domains.json` — the `guard-memory` path→domain rules. Strategy: take the starter's `_examples` and any new keys, but **preserve project-filled `rules`** (the project's path regexes are project-specific). Show the diff; never wipe populated `rules`.
- `.claude/comment-guard.json` — the `guard-comments` scope + thresholds. Same strategy as `memory-domains.json`: take the starter's `_examples` and any new keys, but **preserve a project-filled `src_globs`** and any tuned `max_comment_percent` (that number is meant to be the project's own comment density, not the starter's default). Show the diff; never wipe a populated `src_globs`.
- `.agents/reference/tracker-comments.md` — **an explicit exception to Category C's blanket "`.agents/reference/` — do not touch"**: the core contract `/brainstorm`, `/quick-change`, `/execute`, `/check-implementation`, `/pr-merge` and the team prompts point to, with its script `.claude/lib/tracker-snapshot.mjs` (a lib `*.mjs`, category A). Overwrite it from the starter in every project; it holds no project content.
- `.agents/reference/guarded-writes.md` — **the same explicit exception**: the core contract of the opt-in guarded-write kit (`.claude/lib/guarded-writes/**`) — policy, Operator setup, the settings block an Operator pastes, limits. Overwrite it from the starter in every project; it holds no project content (the project's allow-list is `.claude/guarded-writes.json`, category C).
- `.agents/reference/remote-build.md` — **the same explicit exception**: the core contract of the opt-in remote build check (`.claude/lib/remote-build/**`). Overwrite it from the starter in every project; the project's node and command are in `.claude/remote-build.json`, category C.
- `.agents/reference/regression.md` and `.agents/reference/regression-test-data.md` — **the same explicit exception**: the core contract of the opt-in regression kit (`.claude/lib/regression/**`) — the scenario block, the switch, the scripts, and the test-data adapter contract. Overwrite them from the starter in every project; the project's switch is `.claude/regression.json`, category C.
- `.agents/reference/local-env-runner.md` — **the same explicit exception**: the core contract of the opt-in local env runner (`.claude/lib/local-env/**`). Overwrite it from the starter in every project; the project's registry is `.claude/local-env.json`, category C.
- `.agents/reference/coding-standards.md.example` — **the same explicit exception**: the seed `/setup:map-codebase` and `/setup:create-CLAUDE_MD` render `docs/coding-standards.md` from (via `.claude/lib/coding-standards-render.mjs`). Overwrite it from the starter in every project; the project's own `docs/coding-standards.md` is category C.
- `.agents/reference/qa-evidence-families.md` — **an explicit exception to Category C's blanket "`.agents/reference/` — do not touch"**, and it must stay marked as one: without this line the two rules read as contradictory and a future sync picks the wrong one. Strategy is the same as `.agents/memory/index.md` above, and that entry is the precedent: the **framework** sections (`§1` families, `§3` classification signals, `§4` worked examples, `§6` output contract, `§7` router dispositions and the run record) overwrite from the starter, while the **project** sections (`§2` verifier roster, `§5` not-observable list) are preserved verbatim. Each `##` heading in the file carries a `[framework]` / `[project]` marker — route by that marker, never by section number alone. **Roster completeness:** every family in framework §1 must have a row in project §2. Sync *adds* a missing framework row (verifier · lane · required tooling, copied from the starter) and never removes or rewrites a project row — without this, a downstream receives a new family with no verifier to route it to. Show the diff before writing.
- `.agents/reference/qa-to-regression-test.md` — an explicit exception to Category C: the procedure the guide and `/qa-verify` point to for promoting a QA run to a regression test. Its rules overwrite from the starter; the project-filled slots — the non-browser driver → test-framework table (§3) and the test-directory slot (§4) — are preserved verbatim. When the project has none, add it from the starter with its slots unfilled. Show the diff before writing.
- `.agents/reference/pr-host-api.md` — an explicit exception to Category C: `§8` (PR facts for `/qa-verify`) is framework and overwrites from the starter; every other section (auth notes, live-validation status the project flips) is preserved verbatim. Show the diff before writing.
- `.claude/qa-env.json` — the `/prime-qa` environment description. Take new keys and doc strings from the starter, but **preserve every project-filled value** (hosts, probe paths, serve commands). Overwriting these silently re-points QA at nothing.
- `.editorconfig` — append/merge missing keys from the starter; do not drop project-specific overrides.

### Category C — **do not touch** (project content)

- `.claude/hooks/check-project-deps.sh` — the project-owned SessionStart preflight (toolchain + `.env` shape + MCP commands). The starter ships only the skeleton; never overwrite a project's filled copy.

- `CLAUDE.md` — project rules. If the starter has a new section structure, report it and propose a patch — but do not overwrite automatically.
- `.agents/memory/architecture.md`, `project-brief.md`, `domain/*.md` — regenerated from the project (`/setup:create-CLAUDE_MD`, `/maintain:refresh-brief`).
- `.agents/memory/errors.md`, `decisions.md`, `api.md`, `patterns.md` — append-only, project history.
- `.agents/sources/`, `.agents/specs/`, `.agents/plans/`, `.agents/reference/`, `.agents/wiki/`, `.agents/memory/archive/` — project content. **Exceptions, all explicit and all in category A/B above:** `.agents/reference/qa-evidence-families.md` (category B), `.agents/reference/qa-to-regression-test.md` (category B), `.agents/reference/pr-host-api.md` (category B, §8 only), `.agents/reference/tracker-comments.md`, `.agents/reference/guarded-writes.md`, `.agents/reference/local-env-runner.md`, `.agents/reference/remote-build.md`, `.agents/reference/regression.md`, `.agents/reference/regression-test-data.md`, `.agents/reference/operator-touches.md` and `.agents/reference/coding-standards.md.example` (category A, core) and the `.agents/reference/` files named as `own` in `.claude/team/manifest.txt` (category A, team harness).
- `README.md` (root) — the **project** README (generated by `/setup:create-CLAUDE_MD` at bootstrap). Never overwrite with starter content. The framework guide is `.claude/docs/` (category A).
- `LICENSE` — the project may have relicensed; never overwrite.
- `.claude/regression.json` — the project's regression switch (catalog areas, runner, environments), written by `/setup:regression`; never synced, never overwritten.
- `CHANGELOG.md`, `docs/`, any source files — project documentation and code.

## Step 3: dry-run report (BEFORE any change)

Show me:

1. **Category A — diff:**
   - **New** files (in the starter, absent from the project) → list of full paths
   - **Changed** files (content differs) → list + a concise "what changed" note (1-2 lines per file)
   - **Identical** files → count only, no list
   - Files **in the project but not in the starter** → list, mark as "project custom command? check if needed" — do NOT delete automatically
      - **Retired upstream, not custom:** for a project-only path that `base` does not hold either, or when there is no `base` (a path `base` still holds is decided by the 3-way deletion rows of `/maintain:sync-from-starter` Step 2; for a path its "project-custom" row would take, this check comes first): when the starter's history shipped that path (`git -C <clone> log --raw --no-abbrev --format= -- <path>` is non-empty), it is a file the starter removed. A shallow clone has no such history — an empty log from it never means "not shipped": check once, before the first such path, `git -C <clone> rev-parse --is-shallow-repository`; `true` → `git -C <clone> fetch --unshallow` (a failed fetch → flag every such path "history unavailable — decide"). The project copy's blob (`git hash-object <path>`) equal to one of the blob ids that log lists → offer to delete it (still confirmed); any other content → keep it and flag "removed upstream, edited locally — decide".

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
- NEVER check or add bootstrap-only artifacts (the legacy `.claude/README.md`, `.claude/STARTER-LICENSE`, root `LICENSE`/`README.md`, `create-CLAUDE_MD` as a bootstrap driver) in an existing project — see the "Bootstrap-only" subsection in Step 2
- Clean up the `/tmp` starter clone(s) at the end via `find … -delete` (`rm -rf` is `ask`-tier in settings, not denied); a leftover clone is harmless and must never block the run
