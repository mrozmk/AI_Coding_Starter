# Framework guide — AI Coding Starter

> The how-to-use reference for the workflow: what ships, the daily flows, every command, configuration and
> permissions. New here? Start with the [tutorial](https://github.com/mrozmk/AI_Coding_Starter/blob/main/docs/TUTORIAL.md)
> (a whole project, step by step). The short overview is the starter's
> [landing page](https://github.com/mrozmk/AI_Coding_Starter#readme).

This guide lives in `.claude/docs/` so it ships with the framework: it stays in every project made from the
template and `/maintain:sync-from-starter` keeps it current. Your project's root `README.md` is yours — see
[The root README is yours](#the-root-readme-is-yours).

The starter ships **no application code** — only the scaffolding that makes Claude a reliable collaborator:

- `.claude/` — commands, agents, skills, hooks, permission settings, and this guide (`.claude/docs/`)
- `.agents/` — persistent knowledge layers (sources, memory, reference, specs, plans)
- `CLAUDE.md` — project rules seed, ready to be filled in per project; `AGENTS.md` — the same role for Codex
- `.mcp.json` (Atlassian, Context7, Playwright) and `.env.example` (credentials template)
- `.gitignore`, sensible defaults
- in the starter repo only: `docs/TUTORIAL.md`, `docs/teams/` (the team layer's human docs) and `tools/agent_mail/` (the channel the team layer uses)

---

## What's in the box

### `.claude/`

| Path | Purpose |
|------|---------|
| `commands/` | Slash commands — grouped by role in [Commands by role](#commands-by-role) below; when to run each is in [Daily workflow](#daily-workflow). |
| `agents/` | Sub-agents — grouped by role in [Agents by role](#agents-by-role) below; their models and effort are in [Model & effort strategy](#model--effort-strategy-shared-across-the-pipeline). |
| `skills/` | Skills — `/jira` (Jira Cloud via `mcp-atlassian` — create / edit / search / transition / comment / link Epics, Tasks, Bugs; `/jira sync` mirrors `.agents/backlog.md` into Jira through local drafts, `/jira resync` reports drift), `/confluence` (read and author Confluence pages, publish only on confirm), `/pr-comments` (triage PR review threads on GitHub / Bitbucket / GitLab) and `/design-ui` (guided UI design as a quality loop — screen brief → design (1 or 3 variants) → rendered screenshots → the independent `design-critic` (Fable, high) judging against its UI/UX `principles.md` → author fixes, up to 3 rounds → one Codex cross-review of the chosen design; named so it never collides with Claude Code's bundled `design` canvas skill; its knowledge files sit next to `SKILL.md`). Plus command-bound resource bundles loaded by path (no `SKILL.md`): `architecture-review/` (depth/locality method for `/architecture-review`), `discover/` (question bank, coverage rules, discovery + PRD templates, rubric for `/discover`), `architect/` (subdomain tests, decision dimensions, stack method, architecture template, `system.yaml` schema, rubric for `/architect`), `backlog/` (the rubric `/check-backlog` grades against), `audit-security/` (methodology, policies, scripts for `/audit-security`), `seo-geo-audit/`. Three mods ship as skills too: `stage-handoff/` (compacts between `/orchestrate` stages), `cache-handoff/` (context size and cache warmth in the status line, `/hc`) and `subagent-model/` (lowers the model of a built-in subagent spawned without one, from a rule table in the profile; off by default). |
| `templates/` | Starting templates — `CLAUDE-template.md` (project rules), `README-template.md` (project README, used by `/setup:create-CLAUDE_MD` on bootstrap), `TESTING-template.md`, `DEFINITION-OF-DONE-template.md`, `PULL_REQUEST_TEMPLATE.md` (convention docs placed by `/setup:start` step 8) |
| `hooks/` | Workflow hooks — the registered ones and what each does are in [Permissions & safety](#permissions--safety). Most need `jq`. |
| `settings.json` → `skillOverrides` | Switches off the Claude Code bundled skills the starter replaces or does not want auto-triggered (`init`, `design`, `dataviz`, `simplify`, the `artifact-*` trio, …). Kept on: `code-review` and `security-review` (the quality pipeline calls them), `run`, `loop`, `schedule`, `claude-api`, `update-config`, `claude-in-chrome`. Undocumented key, verified on Claude Code 2.1.257 (2026-09-16); values `off` / `user-invocable-only` / `name-only`. |
| `output-styles/` | Output styles — `Simply` (three-block answers: done / did it work / now what, ≤120 words, no walls of text). Activate per session with `/output-style simply`. |
| `workflows/` | `Workflow` orchestration scripts — `map-codebase.js` (brownfield fan-out comprehension), driven by `/setup:map-codebase` |
| `lib/` | Shared scripts — `backlog-check.mjs` (backlog validator), `codex-bg.sh` (the one way to spawn Codex), `git-baseline.sh`, the team layer's `team-*.sh`, `costs/` (token usage) |
| `team/` | The opt-in team layer (manifest, role prompts, tracker and PR adapters) |
| config files | `project-profile.json.example` (the `/setup:start` answers), `qa-env.json` (QA hosts), `comment-guard.json`, `nudge-rules.json`, `memory-domains.json`, `starter-sync-playbook.md` (how sync classifies files) |
| `settings.json` | Security-first permissions (non-destructive git allowed, destructive ops denied, deny on secrets, audit-log hooks) |

### `.agents/`

Layers of persistent project knowledge:

| Layer | Contents | Lifecycle |
|-------|----------|-----------|
| `sources/` | **Raw input materials** — briefs, transcripts, sketches, PDFs supplied by the user. Feeds `/discover` and `/setup:createwikillm`. Never modified by Claude. | Immutable input, pruned manually |
| `memory/` | Lessons, decisions, quirks, patterns, plus three regenerated files: `architecture.md` (directory map), `project-brief.md` (TL;DR of PRD), `domain/business-model.md` (pricing/billing facts) | Mixed — most files append-only, three are regenerated wholesale by their owning command |
| `reference/` | Stable domain/API references | Long-lived, updated as domain evolves |
| `backlog.md` *(optional)* | **Delivery map** from `/setup:create-backlog` — Epics → Tasks (user stories or technical tasks) sized M/H/XH, a dependency DAG, a sequential Wave 0 foundation, parallel lanes for 2–4 developers and a story map with a walking skeleton. Each Task feeds one `/brainstorm` (H/XH) or `/quick-change` (M) cycle; `/jira sync` mirrors it into Jira. | Generated once; `Status`/`Ref` written back by `/plan-feature` (WIP), `/execute`, `/quick-change` and `/orchestrate` (DONE); `Jira` cells by `/jira sync`; structural changes through `/update-backlog` |
| `specs/` | Design docs from `/brainstorm` | Lives with the feature |
| `plans/` | Implementation plans — `active/` → `done/` | Short-lived |
| `meeting-notes/` | One dated note per meeting transcript, from `/meeting-notes` | Immutable once written |
| `handoffs/` · `jira/` | `/handoff` files and other local reports; `/jira` drafts (`inprogress/`, `sent/`) | Local scratch, per clone |
| `project-profile.json` | Your `/setup:start` answers (groups, tracker, branch model, `teams`) | Edited with `/setup:start --rerun` |

The product documents live in `docs/`: `docs/discovery.md` and `docs/PRD.md` (from `/discover`), `docs/architecture.md` and `docs/map/system.yaml` (from `/architect`).

Full routing of "what to read when" lives in [.agents/memory/index.md](../../.agents/memory/index.md) — its `When to Read` table tells Claude which memory files to load for the current task. `CLAUDE.md` stays slim (hard cap: ≤165 lines / ≤9 500 chars, enforced by `/setup:create-CLAUDE_MD`) and points to memory files instead of duplicating their content.

**Status frontmatter convention.** Regenerated files (`architecture.md`, `project-brief.md`, `domain/business-model.md`) carry a `status: empty | seeded | populated` flag. Files with `status: empty` are unfilled placeholders — `/prime` and other commands skip them, falling back to the source (e.g. PRD instead of empty brief). Run the owning command (`/setup:create-CLAUDE_MD` or `/maintain:refresh-brief`) to populate them.

### Commands by role

| Role | Commands |
|------|----------|
| **Setup** | `/setup:start` (guided bootstrap), `/setup:map-codebase` (existing codebase), `/setup:create-CLAUDE_MD`, `/setup:createwikillm`, `/setup:teams` |
| **Business analyst** | `/prime-ba`, `/discover`, `/architect`, `/design-ui`, `/setup:create-backlog`, `/check-backlog`, `/meeting-notes`, `/update-backlog`, `/jira`, `/github-sync`, `/confluence` |
| **Developer** | `/prime`, `/start-task`, `/tasks-status`, `/recon`, `/brainstorm`, `/plan-feature`, `/execute`, `/check-implementation`, `/quick-change`, `/commit`, `/push`, `/pull`, `/pr-create`, `/pr-comments`, `/pr-merge`, `/release`, `/orchestrate` |
| **Review and gates** | `/codex-review`, `/deep-review`, `/architecture-review`, `/gates:verify-implementation`, `/gates:design-quality-check`, `/architecture-doc` |
| **QA and security** | `/prime-qa`, `/qa-verify`, `/test-e2e`, `/audit-security`, `/seo-geo-audit` |
| **Teams (opt-in)** | `/setup:teams`, `/roles`, `/start-team`, `/tasks-status` |
| **Session and upkeep** | `/handoff`, `/hc`, `/analysis`, `/simply`, `/retro`, `/maintain:refresh-brief`, `/maintain:cleanup-workflow`, `/maintain:sync-from-starter`, `/maintain:sync-herdr-kit` |

### Agents by role

| Role | Agents |
|------|--------|
| **`/orchestrate` pipeline** | `orchestrator-executor`, `orchestrator-executor-hard`, `orchestrator-refiner`, `orchestrator-verifier`, `orchestrator-designer`, `orchestrator-committer` |
| **Critics** | `start-critic` (`/discover`, `/architect`, `/check-backlog`), `design-critic` (`/design-ui`) |
| **Review finders** | `correctness-reviewer`, `structure-reviewer` — read-only; the caller applies the fixes |
| **QA verifiers** | `qa-contract`, `qa-runtime-ui` (`/qa-verify`); `qa-runtime-app.md.example` and `qa-runtime-device.md.example` are opt-in templates |
| **Security audit** | `audit-threat-modeler`, `audit-control-verifier`, `audit-finding-validator` (`/audit-security`) |
| **Docs** | `documentation-manager` (`/orchestrate --sync-docs`) |

---

## Two daily flows

This starter supports two distinct roles. Both share the same knowledge layers (`.agents/`, `CLAUDE.md`) — they differ only in the command chain.

> **Why every flow starts with a new chat + prime?** A fresh chat means no leftover context from a previous task that could bias Claude. Priming (`/prime` or `/prime-ba`) is the *first message* in that fresh chat — it loads the project's knowledge layers (PRD brief, architecture map, memory) so Claude reasons over the actual project state instead of guessing. Skipping either step is the most common cause of off-target answers.

### Business Analyst flow

```
New chat → /prime-ba → /discover → /architect → /setup:create-backlog → /check-backlog → /jira sync
```

| Step | What it means |
|------|---------------|
| **New chat** | Open a fresh Claude Code session — no history, no leftover context from previous tasks. |
| **`/prime-ba`** | Loads the BA context: `docs/PRD.md`, `docs/discovery.md`, `docs/architecture.md`, `.agents/specs/`, the local `.agents/backlog.md` (validated by `backlog-check.mjs`) with its scope register, and the Jira backlog when `mcp-atlassian` is reachable (skipped otherwise). Implementation details (`patterns.md`, `errors.md`, code) are intentionally skipped — a BA reasons over product, not internals. |
| **Source files** | Drop briefs, transcripts, sketches, PDFs into [.agents/sources/](../../.agents/sources/). Raw input — never modified by Claude; `/discover` reads it automatically. |
| **`/discover`** | The BA interview (or `--import` of existing requirements) → `docs/discovery.md` + `docs/PRD.md` with stable ids, judged by an independent critic and one Codex review. |
| **`/architect`** | Subdomains, per-context decisions and the stack → `docs/architecture.md` + `docs/map/system.yaml`. |
| **`/setup:create-backlog`** | Epics and Tasks with sizes, dependencies, lanes and acceptance criteria → `.agents/backlog.md`. |
| **`/check-backlog`** | The independent critic grades the backlog; you decide which fixes to apply. |
| **`/jira sync`** | Drafts the Epics and Tasks locally, sends them on your confirmation (one per Epic group), and writes the keys back into the backlog. |

When scope changes later: `/meeting-notes <transcript>` turns a meeting into a note, and `/update-backlog` applies the changes to the PRD and the backlog in one reviewed write.

### Developer flow

The first half is always the same — **prime → brainstorm → plan-feature** turns an idea (a free-text request, or one you lift from a Jira issue) into an approved, codebase-aware plan. How you take that plan to *shipped* is your call — pick by how much you want to drive:

> **Multi-phase project?** Run `/setup:create-backlog` once (after the PRD) to generate `.agents/backlog.md` — a delivery map that breaks the PRD into **Epics and Tasks** with sizes (M/H/XH), a dependency DAG and parallel lanes. Each Task row then tells you which `/brainstorm <Task>` (H/XH) or `/quick-change <Task>` (M) to run next, and in what order. It's optional: when the backlog exists, `/plan-feature` and `/orchestrate` tick `Status`/`Ref` back into it; when it doesn't, the flow below is unchanged. See [§Map the delivery (optional)](#optional-map-the-delivery-before-brainstorming-feature-by-feature).

**A — Manual (more human-in-the-loop):**

```
New chat → /prime → /brainstorm <feature> → /plan-feature → /execute → /check-implementation → /commit → /push → /qa-verify
```

Tracker-driven variant — `/start-task <KEY>` replaces the first three steps (branch + prime + brainstorm from the issue); in a PR-gated repo `/pr-create` replaces `/push`. `/qa-verify` runs in a fresh session after `/prime-qa`.

> You run and review each step. `/check-implementation` **applies** fixes (two parallel read-only finders report, your session applies bugs first, then structure) and loops the read-only gate until it passes, then stops at a clean tree for **you** to `/commit` and `/push`. Best for high-stakes changes, or when you want eyes on every gate.

**B — Orchestrated (hands-off):**

```
New chat → /prime → /orchestrate <feature>
```

> `/orchestrate` drives the whole thing end-to-end — brainstorm → plan-feature → build (execute → refine → verify → [design-check] → [codex second judge for `medium` steps] → commit → push, per step) → closing commit — **compacting its own context between stages** (through the `stage-handoff` mod it ships with) so a 1M-token session never loses the thread. It asks you only at a real directional fork, a 🔶 rethink signal from the cross-model reviewer, or a blocker it cannot resolve; everything else (spec approval, grill scope, split decisions) it decides and reports. Give it a spec path to start at planning, or a plan path to start at the build — that last form is the previous `/orchestrate`, unchanged.

**C — Fast lane (small changes):**

```
New chat → /prime → /quick-change <what to change> → /commit
```

> For work where the full first half is ceremony: a short plan in chat (no spec, no plan file), a **mandatory** independent `codex` review of that plan **before any code exists** (no opt-out flag — it is skipped only when `codex` isn't installed, and the report says so), then implement → `/code-review` (low effort) → `/deep-review` → the `CLAUDE.md → Validation` gates. A guard fires — and says so — when the change turns out not to be small (sensitive path, >~5 files or more than one module/layer, new dependency, schema/contract change, design reference needed, or a "done" that does not fit one sentence), recommending flow A or B instead; you can override it. Not a replacement for A/B — it is the honest middle between them and "just do it".

| Step | What it means |
|------|---------------|
| **New chat** | Open a fresh Claude Code session — no history, no leftover context from previous tasks. |
| **`/prime`** | Quick mode by default — loads `CLAUDE.md`, `.agents/memory/index.md`, `project-brief.md`, `architecture.md`, plus listings of plans/specs/reference and git state. Use `/prime full` after a long break or for deep multi-area work (also pulls `patterns.md`, `decisions.md`, `api.md`, `errors.md`, populated `domain/*`). |
| **`/brainstorm [feature \| Task id \| KEY]`** | Explores the requirement. A backlog Task id or a Jira key resolves to the local Task (its acceptance criteria and traces); a bare `/brainstorm` takes the next free Task from the backlog, or offers to fetch your open tracker issues when there is no backlog file. It reads Jira, never writes it. Output: a design spec in `.agents/specs/`. If `codex` is installed, a cross-model pass reviews the spec before it advances (auto-skips otherwise). |
| **`/plan-feature`** | Reads the approved spec, analyzes the codebase, optionally runs web research for declared external dependencies, writes a step-by-step plan to `.agents/plans/active/`, then **grills** it (self-critique) and — if `codex` is installed — runs an independent cross-model review loop (Phase 7) before handing the plan over. |
| **`/execute`** *(flow A)* | Runs the active plan top to bottom. Moves it to `.agents/plans/done/` when complete. Add `codex` (`/execute codex`) to have Codex write the code at effort `medium` while Claude supervises and re-validates. |
| **`/check-implementation`** *(flow A)* | Full quality loop: two parallel read-only finders (`correctness-reviewer` → `code-review`, `structure-reviewer` → `deep-review report-only`, pinned models) → your session applies their findings → `gates:verify-implementation` (read-only gate, incl. conditional design-parity), looping up to 3× until the gate approves; a one-shot codex cross-review of the approved diff follows (if `codex` is installed). **Applies** fixes; leaves a commit-ready tree — does **not** commit. `/check-implementation codex` makes Codex the fixer (effort `high`); Claude stays the judge, and the cross-review step is skipped whenever Codex actually applied fixes (Claude's gate is then the second model). |
| **`/commit` → `/push`** *(flow A)* | Conventional-commit message + a memory-reflection checkpoint (in its own `chore(memory)` commit), then push to the current branch with a secret scan. |
| **`/qa-verify <task>`** *(flow A)* | In a fresh session after `/prime-qa`: checks every acceptance criterion with evidence and writes a verdict matrix you sign. |
| **`/orchestrate <feature>`** *(flow B)* | Runs flow A as one pipeline — `/brainstorm` → `/plan-feature` → the plan runner (execute → refine → verify → [design] → [codex judge] → commit → push via sub-agents) → a closing `chore` commit — compacting the session between stages. Asks only at directional forks, 🔶 rethink signals and blockers. `/orchestrate <plan>` runs just the build. |

> Both flows share the same gates and memory-reflection — `/orchestrate` just drives them for you instead of you running each command. The read-only, report-only `/gates:verify-implementation` is also available standalone when you only want the verdict without applying fixes.

---

## Requirements

**Required:**
- [Claude Code](https://claude.com/claude-code) — the CLI tool that drives all slash commands and skills shipped here.
- Git — for the `/commit`, `/push`, `/pull`, `/release` workflow.
- [`jq`](https://jqlang.github.io/jq/) — required by the workflow hooks (`guard-memory`, `track-memory-read`, `audit-append`, `guard-push`). Most **fail open silently** without it: the memory-distillation guard never fires, the audit log stays empty, and read telemetry is not recorded — with no error shown. `guard-push` fails open **loudly** (it prints a "secret scan SKIPPED" warning) so the security gap is visible. Install via `brew install jq` / `apt install jq` before relying on those safeguards.
- [`gitleaks`](https://github.com/gitleaks/gitleaks) *(optional)* — if on `PATH`, `guard-push` runs it as a broader entropy/ruleset pass on top of its built-in baseline scan. Without it the baseline (known-format tokens, private keys, credential files, hardcoded assignments) still applies.
- [`codex`](https://github.com/openai/codex) CLI *(optional)* — enables **cross-model review**: a second, independent model (GPT-class) reviews work the primary thread produced. Used by `/codex-review` (standalone diff/proposal review), by `/quick-change` (Phase 2, on the plan before any code exists), and as a conditional gate inside `/plan-feature` (Phase 7), `/brainstorm` (Step 8), `/check-implementation` (Step 1.5, on the gate-approved diff), `/architecture-review --codex` (Phase 0, a second independent sweep), `/orchestrate` (Step 5.3b per `medium` step, and Phase 7 step 0 on the whole run's diff), `/discover`, `/architect`, `/check-backlog`, `/design-ui` and `/audit-security`. It also writes code in `/execute codex` and fixes it in `/check-implementation codex`. The conditional gates **skip cleanly** when `codex` is not on `PATH` (each logs one "skipped — codex not on PATH" line, no error), keeping the harness portable; the standalone `/codex-review` instead **hard-stops** with a clear install/login message, since running it without `codex` has no fallback. **`/quick-change` sits between the two:** its review is mandatory in the sense that nothing you can type disables it, but an absent `codex` degrades the run rather than blocking it — the missing opinion is reported on its own line instead of being silently dropped. Install + `codex login` to activate.

**Optional (per integration):**
- **Jira Cloud + `mcp-atlassian`** — needed for `/jira`, `/confluence` and every command that reads a ticket (`/start-task`, `/brainstorm <KEY>`, `/prime-ba`, `/qa-verify`, `/test-e2e CS-1`, `/pr-create`, `/pr-merge`, the team commands). The starter ships the skill itself but does not require Jira to function. See [Jira integration setup](#jira-integration-optional) below.
- **`uvx`** (from [uv](https://github.com/astral-sh/uv)) — runtime for the `mcp-atlassian` MCP server, only if you wire up Jira.
- **MCP Playwright** — needed for browser work: `/test-e2e`, `/qa-verify` UI checks (`qa-runtime-ui`), `/design-ui`, `/gates:design-quality-check`, `/seo-geo-audit`.
- **Team layer** — macOS, a session host (`tmux`, or Herdr with `teams.session_host: "herdr"`), `python3`, `perl` and the Codex CLI (`sqlite3` only for the optional agent-mail kit); see [Team supervision](#team-supervision-opt-in). See [MCP Playwright setup](#mcp-playwright-optional) below.

That's it. No language runtime is required by the starter itself — pick your stack when scaffolding the actual project (the seed `CLAUDE.md` is stack-agnostic; `/setup:create-CLAUDE_MD` adapts to whatever you initialize).

### Recommended MCP servers

These three MCP servers extend the shipped commands. All three are already declared in the committed `.mcp.json`, so Claude Code offers to enable them when you open the project; only Atlassian needs credentials.

| MCP | What it does | Repo | Used by |
|-----|--------------|------|---------|
| **context7** | Fetches up-to-date library / API docs on demand | [upstash/context7](https://github.com/upstash/context7) | Any command researching external libs (`/plan-feature` Phase 2, `/architect` stack research, `/execute`, `/recon`) |
| **playwright-mcp** | Browser automation — drives a real browser for testing and UI verification | [microsoft/playwright-mcp](https://github.com/microsoft/playwright-mcp) | `/test-e2e`, `/qa-verify` (`qa-runtime-ui`), `/design-ui`, `/gates:design-quality-check`, `/seo-geo-audit` |
| **mcp-atlassian** | Jira Cloud — create / edit / search / transition Epics, Tasks, Bugs | [sooperset/mcp-atlassian](https://github.com/sooperset/mcp-atlassian) | `/jira`, `/confluence`, `/start-task`, `/brainstorm <KEY>`, `/prime-ba`, `/qa-verify`, `/recon`, `/test-e2e CS-1`, PR and team commands |

**Installing outside this project** (the `.mcp.json` entries already cover it here):

```bash
# context7 — no credentials required
claude mcp add context7 -- npx -y @upstash/context7-mcp

# playwright — no credentials required
claude mcp add playwright -- npx -y @playwright/mcp@latest

# mcp-atlassian — needs credentials in .env
#   (see "Jira integration (optional)" below)
```

After installing, restart your Claude Code session so the new MCP tools register. Verify with `claude mcp list`.

For canonical install commands, env-var configuration, and version pinning, follow the linked repos.

### Jira integration (optional)

The committed `.mcp.json` declares the `atlassian` server (next to `context7` and `playwright`) and reads its credentials from `.env` (`--env-file .env`). To activate Jira:

1. Answer **Jira: yes** in `/setup:start` — it activates the Jira block in `.env.example` (or uncomment it by hand). Then copy the template: `cp .env.example .env && chmod 600 .env`
2. Fill in your Atlassian credentials in `.env` — `JIRA_URL`, `JIRA_USERNAME` (your Atlassian email), `JIRA_API_TOKEN` (generate at <https://id.atlassian.com/manage-profile/security/api-tokens>).
3. Restart Claude Code — the MCP server loads `.env` at startup, not per call. Repeat after every edit of `.env`.
4. Optionally set skill defaults (`JIRA_DEFAULT_PROJECT`, `JIRA_DEFAULT_COMPONENTS`, `JIRA_DEFAULT_LABELS`, `JIRA_BUG_EPIC`) in `.claude/settings.local.json` — not in `.env`, which only the MCP server reads — so `/jira create` skips the project prompt.

`.env` is gitignored — credentials never leave your machine; `.mcp.json` holds no secrets, so the server list stays shared and synced via `/maintain:sync-from-starter`. If you skip this, the `/jira` skill simply hard-stops with a clear error message; nothing else breaks.

### MCP Playwright (optional)

Needed for the browser-driven commands (see the table above). The starter uses Microsoft's [playwright-mcp](https://github.com/microsoft/playwright-mcp), already declared in `.mcp.json` (isolated profile, output in `.playwright-mcp/`). Outside this project: `claude mcp add playwright -- npx -y @playwright/mcp@latest`.

Once installed, `/test-e2e` can drive a real browser to explore your UI and generate Playwright test files. If you skip this, `/test-e2e` falls back to a degraded mode (plan derived from code/spec inspection) instead of failing.

---

## Quick start

> **Bootstrap chain:** `/setup:start` → it prints the rest, in order, for your kind of project.
>
> Each command produces a concrete artifact and feeds the next one. Running them in the printed order keeps `docs/PRD.md`, `.agents/memory/project-brief.md`, `.agents/memory/architecture.md`, `.agents/memory/decisions.md`, and `.agents/specs/` mutually consistent.

### 0. Create a new project from this template

This repo is a **GitHub template** — pick whichever method you prefer:

**Option A — GitHub UI (recommended):**

1. Go to <https://github.com/mrozmk/AI_Coding_Starter>
2. Click **"Use this template"** → **"Create a new repository"**
3. Name it, choose visibility, create
4. Clone it locally: `git clone <url-of-new-repo> my-new-project && cd my-new-project`

**Option B — `gh` CLI (one-liner):**

```bash
gh repo create my-new-project --template mrozmk/AI_Coding_Starter --private --clone
cd my-new-project
```

Use `--public` instead of `--private` if you want a public repo.

**Option C — manual clone (no GitHub account needed):**

```bash
git clone https://github.com/mrozmk/AI_Coding_Starter my-new-project
cd my-new-project
rm -rf .git
git init
```

All three give you the same result: a fresh project with starter scaffolding and clean git history.

### 1. Run `/setup:start`

Open `claude` in the fresh clone and run `/setup:start`. It asks seven plain-language questions (language, new or existing code, where the repo is hosted, how code reaches `main`, Jira, Confluence, Codex), writes `.claude/project-profile.json`, prepares `.env.example` / `.mcp.json` / the `CLAUDE.md` branch model and language rules, creates `TESTING.md`, `docs/DEFINITION-OF-DONE.md` and your Git host's PR template, offers to remove the command groups you will never use (`pr`, `jira`, `confluence`, `codex`, `qa_runtime_ui`), and prints the numbered list of what to run next. The detailed steps below are that list, explained.

### 2. Drop raw materials (optional)

If you already have briefs, transcripts, sketches, PDFs, or any written materials describing the product — drop them into [.agents/sources/](../../.agents/sources/). `/discover` reads them automatically as input context (together with any notes in `.agents/meeting-notes/`); `/setup:createwikillm` suggests the folder as its default source.

> **Next step:** once the materials are in place, run `/discover` (step 3 below) — it reads `.agents/sources/` automatically and uses its contents alongside the conversation. Requirements that already exist elsewhere (a spreadsheet exported to CSV, a brief) go in with `/discover --import <path>`.

### 3. Define the product

```
/discover                          # BA interview — or start from a one-line idea: /discover <idea>
/discover --import reqs.csv        # existing requirements become id'd entries; questions only for gaps
```

> Run `/prime` first. A business-analysis interview before any design: it derives what it can from `.agents/sources/` and the repo, then asks only the gaps — short rounds of ≤5 questions, each with a **Recommended** answer first — until problem, measurable outcome, appetite and the critical flow are clear. It writes two files: `docs/discovery.md` (coverage, clarifications log, flows, business rules, glossary, entities, assumptions, open questions, risks) and `docs/PRD.md` (goals, EARS requirements, NFRs, scope). Every statement gets a stable id (`G-n`, `R-n`, `NFR-n`, `BR-n`, `FL-n`, `A-n`, `Q-n`) that the backlog, specs and `/qa-verify` trace back to. An independent critic (`start-critic`) grades the result and Codex reviews it once. Architecture and stack are left to step 4.

### 4. Decide the architecture and the stack

```
/architect                         # project-level — subdomains, decisions, stack
/architect --stack realtime        # focused stack research on one area
```

> Run this **after** `/discover`. Classifies the subdomains (core / supporting / generic) from the discovery evidence, decides each bounded context on fixed dimensions (one `AD-n` row per decision, deferred cells named honestly), and chooses the stack by structured web research over 2–3 candidates. Writes `docs/architecture.md` (subdomains, context map, `## Decisions`, stack + research, NFR map) and `docs/map/system.yaml` (the machine-readable map the backlog's `Node` cells point at); the PRD's architecture and stack sections become a digest of it, and `.agents/memory/decisions.md` gets one pointer per active decision. Judged by the same independent critic + one Codex review.
>
> **UI-heavy product?** `/design-ui` after `/architect` for the critical flow's key screens — optional, never a gate.

### 5. Distill the PRD into a fast-load brief

```
/maintain:refresh-brief   # only standalone LATER, after substantial PRD changes
```

> `/setup:start` prints when to run it (after `/architect`, before `/setup:create-backlog`); `/setup:create-CLAUDE_MD` also refreshes it when the brief is still empty or older than the PRD.
>
> Either way it generates `.agents/memory/project-brief.md` — a 50-line TL;DR that `/prime` loads instead of the full PRD on every session start — and, if the PRD has pricing/billing/monetization sections, also seeds `.agents/memory/domain/business-model.md` (plan IDs, feature gates, Stripe events).

### Optional: Map the delivery before brainstorming feature by feature

```
/setup:create-backlog
```

> Run `/prime` first — this command (and `/brainstorm`) stops without primed context. On a new product `/setup:start` lists it as a regular step; on an existing codebase it is optional. Reads the PRD (plus `docs/discovery.md`, `docs/architecture.md`, `docs/map/system.yaml` when present) and writes `.agents/backlog.md`: a **delivery map** of **Epics → Tasks** — user stories or technical tasks, each sized `M` (4 pts), `H` (8) or `XH` (16; anything bigger is split), points summed to the Epic, with acceptance criteria carrying ids (`E1-2.AC1`) and traces to the PRD/architecture ids. A small **sequential Wave 0** foundation (scaffold `E0-1`, schema, contracts) comes first; after it the Tasks are cut into **parallel lanes for 2, 3 and 4 developers**, and a **story map** marks the **walking skeleton** — the thinnest set of Tasks that covers the critical flow end-to-end. `node .claude/lib/backlog-check.mjs --write` validates ids, the DAG, sizes and trace coverage, then fills in the lanes and the story map. Each Task = one `/brainstorm <Task>` (H/XH) or `/quick-change <Task>` (M) cycle — the layer between the PRD and the per-feature plan's `## Execution Plan`.
>
> **Backlog is the source of truth; Jira is an optional mirror of it.** The local `.agents/backlog.md` is the canonical "what-to-build-in-what-order" map — create it first, always. A team on Jira mirrors it with `/jira sync` — one-way, create-only (Epics and Tasks, with parent, labels, estimate and `Blocks` links), each Jira key written back into the Task's `Jira` cell. It drafts locally first (`.agents/jira/inprogress/`) and asks once per Epic group before sending; after creating it runs the recorded follow-ups (Epic links, attachments, an open-questions comment, and an optional initial status from `initial_jira_status`). It never updates or deletes an existing issue; `/jira resync` reads groomed Jira text back and reports drift. Jira then owns only the workflow status of synced Tasks; structure, order and sizes stay in the backlog — never a second parallel list maintained in reverse. A bare `/brainstorm` (no topic, no Jira reference) **resolves its topic from the backlog** — it picks the next *free* Task (Status `TODO`, all `Depends on` `DONE`, lowest `Wave`), guards against a stale "already done" status, and designs that; an explicit topic or a Jira reference always overrides.
>
> It's the input to `/brainstorm`, not another spec. The MVP is laid out as a sub-graph with a fan-in Definition of Done, not a flat checklist. Universal structure for every project; optional **domain adapters** (layer tags, a reference build, parity gates) kick in only for ports/migrations.
>
> **Brownfield:** run `/setup:map-codebase` first (it reconstructs the PRD), then this. **Maintenance:** when the backlog exists, `/plan-feature` ticks a Task to `WIP` + records the spec/plan `Ref`, and `/execute`, `/quick-change` or `/orchestrate` tick it to `DONE` — automatically and only if the file is present. Re-shaping the DAG is never a pipeline side-effect: structural changes go through `/update-backlog` (a hand edit is allowed, followed by `node .claude/lib/backlog-check.mjs --write`).
>
> **Check it before building from it.** `/check-backlog` has the independent critic (`start-critic`) grade the backlog against its rubric and grill the gaps; accepted fixes go through `/update-backlog`. When scope changes later, turn each meeting transcript into a note with `/meeting-notes`, then let `/update-backlog` apply the changes to the PRD and the backlog in one reviewed write that protects work in progress.

### 6. Initialize project rules (after first scaffolding)

```
/setup:create-CLAUDE_MD
```

> Run this **after** you have at least some scaffolding — in the routed sequence the scaffold is the first backlog task (`E0-1`), built through steps 7–11 below. Then run `/setup:start --rerun` once (it fills the toolchain preflight in `check-project-deps.sh` and declares the LSP plugin for the stack now that a manifest exists — run the install commands it prints and `/reload-plugins`) and this command. It analyzes the codebase to extract real patterns — on a truly empty repo it has nothing to read. The seed `CLAUDE.md` already ships with language rules, knowledge-layer routing, and security defaults, so you are not blocked without this step.
>
> It reads the branch model and language from `.claude/project-profile.json` (written by `/setup:start`) instead of asking again, and refuses to silently overwrite a `CLAUDE.md` value that was edited by hand. **Safety net:** if `project-brief.md` is still empty (or older than `docs/PRD.md`) and a PRD exists, it runs the PRD→brief step itself first (skipped when the brief is current).
>
> **Adopting into a large existing codebase (brownfield)?** Don't run this alone — run [`/setup:map-codebase`](../commands/setup/map-codebase.md) instead. It fans out parallel analysis sub-agents (distilled summaries, no context flooding), produces `architecture.md` + a reconstructed `docs/PRD.md`, and cascades into `/maintain:refresh-brief` and `/setup:create-CLAUDE_MD` — the whole Phase-1 AI layer in one guided run with two review checkpoints.

It generates **three files** in tandem:
- `CLAUDE.md` — slim rules file (hard cap ≤165 lines / ≤9 500 chars), filled with project overview, tech stack, commands, conventions
- `.agents/memory/architecture.md` — full directory map, module roles, naming rules (loaded on demand, not in every conversation)
- `README.md` — the project's human-facing README: generated when absent, replaces the starter's landing page when that is still in place, and is left alone otherwise (see [below](#the-root-readme-is-yours)).

On the first run it also swaps `LICENSE`: the starter's MIT license moves to `.claude/STARTER-LICENSE` and a new root `LICENSE` is generated for your project.

The CLAUDE/architecture split keeps `CLAUDE.md` cheap to load every session while preserving the detailed map.

### 7. Design a feature

```
/brainstorm <feature idea>
```

Explores requirements, proposes 2-3 approaches, and writes a design doc to `.agents/specs/YYYY-MM-DD-<topic>.md`. No code is written until the design is approved. With no argument it picks the next free Task from `.agents/backlog.md`; a backlog Task id (`/brainstorm E1-2`) or a Jira key (`/brainstorm PROJ-123`) designs that Task. On a tracker project, `/start-task <KEY>` cuts the branch and starts it for you.

### 8. Plan the implementation

```
/plan-feature          # picks up the newest spec from .agents/specs/
/plan-feature .agents/specs/2026-04-19-my-feature.md   # or point at a specific spec
```

Reads the approved spec, analyzes the codebase, and — **only if** the spec declares `External docs required: yes` — performs a web-research phase for the libs/APIs listed in the spec's `External dependencies`. Writes a step-by-step plan to `.agents/plans/active/`, then **grills** it (mandatory self-critique; you accept or reject each fix) and, if `codex` is installed, runs a cross-model review. A large spec can be split into an umbrella plan of several steps.

### 9. Execute

```
/execute
```

Runs the active plan. Moves it to `.agents/plans/done/` when complete and, when a backlog exists, marks the Task `DONE`. `/execute codex` has Codex write the code while Claude supervises.

> If the feature includes UI, run `/test-e2e <flow-name>` (or `/test-e2e CS-1` to pull acceptance criteria from a Jira issue) after implementation to generate Playwright E2E tests. Requires MCP Playwright (see Requirements above); falls back to degraded mode without it.
>
### 10. Check the implementation

```
/check-implementation
```

The full quality loop: bug review and fixes, structural cleanup, your `CLAUDE.md → Validation` gates and a read-only verifier, looping until clean, then one Codex cross-review. It leaves a commit-ready tree. (`/gates:verify-implementation` alone gives the verdict without fixing anything.)

### 11. Commit

```
/commit
```

Conventional-commit message, plus a memory checkpoint — lessons, decisions, or patterns worth keeping go to `.agents/memory/` in a separate `chore(memory): …` commit.

### 12. Verify the acceptance criteria

```
/prime-qa
/qa-verify <task>
```

Checks what shipped against the Task's acceptance criteria, one by one, and writes a verdict matrix you sign. Run it in a fresh session: `/prime-qa` deliberately does not load specs or plans.

---

## Daily workflow

| Command | When to run |
|---------|-------------|
| `/setup:start [--rerun]` | Once, right after cloning (or adopting the harness into an existing repo): interview → `.claude/project-profile.json` → day-one config → optional command pruning → the ordered list of next commands. `--rerun` to change answers. |
| `/confluence <url \| id \| search \| new "Title" \| publish <draft>>` | Reading or authoring Confluence pages — same MCP server and token as `/jira` (`CONFLUENCE_*` in `.env`). Authoring is local-first: draft in `.agents/handoffs/confluence-drafts/`, publish only on explicit `y`. |
| `/pr-create [KEY]` | Work is committed and ready for review — pushes via `/push`, derives title/dest/merge strategy from the tracker + Branch model, fills the repo's PR template honestly, prints the create-PR URL. With tracker `github` the title is `<issue title> (#n)` and the body closes the issue (`Closes #n`, or `owner/repo#n` from another repo) — or says why it cannot (a PR not into the default branch, a non-GitHub host). Never merges the PR or moves a tracker status; it opens the PR only with `workflow.pr_open: true` (github / azure-devops), after showing the full draft and an explicit **Create** answer. |
| `/pr-comments [KEY]` | Reviewers left comments on your PR (GitHub / Bitbucket / GitLab, detected from `origin`) — pulls the threads, triages which still need you, proposes a reply + optional fix per thread, posts only on a per-thread `y`. Never resolves threads, never commits. |
| `/start-task <KEY>` | Starting a tracker issue — fetches it, proposes `<type>/<KEY>-<slug>` (confirmed), cuts the branch off the fresh base from the Branch model, then runs `/prime` + `/brainstorm <KEY>`. Soft-fails to a typed title when the tracker MCP is absent. With tracker `github` the key is the issue number (`42` / `#42`): the issue is read through `team-tracker.sh` (a failed read stops), the branch is `<type>/42-<slug>`, the Project status moves to `started` once the branch exists, and `/brainstorm` gets the issue's ticket file. |
| `/hc [focus]` | A long session, before the prompt cache goes cold — `/compact` with state-keeping instructions (background work, decisions, tickets, production state, the next step). The bundled `cache-handoff` mod also shows the context size + cache warmth in the status line, offers a **Compact (/hc)** band from 500k tokens, and runs `/hc` by itself when the session is idle and the cache is about to expire. |
| `/prime` | Start of every session — quick mode: loads `CLAUDE.md` + `index.md` + `project-brief.md` + `architecture.md` + listings only. Cheap and sufficient for most sessions. |
| `/prime full` | When returning to a project after a long break or starting deep multi-area work — also loads `patterns.md`, `decisions.md`, `api.md`, `errors.md`, all `domain/*`, and `reference/` up to a budget (120 KB / 25 files). `specs/` is listed, never auto-read. |
| `/prime-ba` | When working as a Business Analyst on stories/backlog — loads PRD, specs, Jira backlog (no implementation context). Independent from `/prime`. |
| `/prime-qa [deep]` | When verifying acceptance criteria against a running system — loads `errors.md` + `domain/*` + the QA evidence taxonomy, then runs an injected environment preflight (host reachability, build skew, credentials presence, parallel-session safety) that resolves `BASE_URL` deterministically. Deliberately **never** reads `specs/` or `plans/`: the author's intent biases the verdict toward what was meant rather than what shipped. Configure hosts in `.claude/qa-env.json`. Self-contained — do not run `/prime` first. `deep` also loads `decisions.md` and `patterns.md`. |
| `/qa-verify [key\|spec\|task-id]` | After `/prime-qa`, to verify what shipped against its **acceptance criteria** (not against the plan — that's `/check-implementation`). A router: it assigns each AC a stable id, classifies it into an *evidence family* ([.agents/reference/qa-evidence-families.md](../../.agents/reference/qa-evidence-families.md)), dispatches that family's verifier, grills every FAIL for a second independent method, and writes a per-AC verdict matrix to `.agents/handoffs/` that a human signs row by row. Stops for approval after classification — nothing runs before that. **Two verifiers ship**: `qa-contract` (static contract/type/boundary checks, lane P) and `qa-runtime-ui` (rendered UI and accessibility in a browser, lane S); the design lane `I` and the other declared verifiers are **guarded** — their ACs route to `NEEDS-HUMAN` with the missing verifier named, derived from a live `ls` of `.claude/agents/`, never from a hand-maintained column. Never mutates: on a defect it records a FAIL and keeps verifying. |
| `/maintain:refresh-brief` | After substantial PRD changes — regenerates `project-brief.md` (and `domain/business-model.md` if PRD has pricing content) so future `/prime` calls stay fast and current. |
| `/discover [idea] \| --import <path>` | Once at the start of a product (and again when scope shifts — every existing id is preserved) — BA interview or import of existing requirements → `docs/discovery.md` + `docs/PRD.md` with stable ids, judged by an independent critic. |
| `/architect [--stack <area>]` | Once after `/discover` — subdomains, per-context decisions (`AD-n`), stack → `docs/architecture.md` + `docs/map/system.yaml`; ad-hoc later with `--stack <area>` for focused research (`--stack realtime`, `--stack auth`). |
| `/setup:create-backlog` | Once after `/architect` — Epics and Tasks with sizes, a dependency DAG, Wave 0, lanes for 2–4 developers and acceptance criteria with ids → `.agents/backlog.md`. |
| `/check-backlog` | After `/setup:create-backlog`, before building from it — the independent critic grades the backlog, you decide, accepted fixes go through `/update-backlog`. |
| `/meeting-notes <transcript>` | After a meeting — turns one transcript (DOCX, Markdown or text) into one dated, immutable note in `.agents/meeting-notes/`, after a clarification loop and a review gate. |
| `/update-backlog` | When scope changes after the baseline (meeting notes, specs, decisions said in chat) — applies them to the PRD and `.agents/backlog.md` in one reviewed, validated write, shows the impact first, protects work in progress, records one `D-n`. |
| `/jira sync` | After `/setup:create-backlog` (and after each structural backlog edit) on a Jira team — creates the Epics/Tasks in Jira (draft first, one confirmation per Epic group), writes the keys back into the backlog's `Jira` cells. Never updates or deletes an existing issue; `/jira resync` reports drift. |
| `/github-sync [E<n>] [--preview]` | The `/jira sync` of a `tracker: github` project — after `/setup:create-backlog` and after each structural backlog edit. Mirrors Epics as issues and Tasks as their sub-issues, adds each to the profile's Project (when it has one), writes `#n` into the rows' `Jira` cells. One-way and create-only: never edits, closes or re-creates an issue, never moves a status; a crashed run is recovered by the marker in each body, a backlog edit after the sync is only reported. Shows the exact issue texts first (`--preview` stops there) and asks per Epic. |
| `/architecture-doc [scope]` | When you want to *see* how the built system fits together — renders 3–5 complementary flows (technical, data, temporal, business, state…) as Mermaid diagrams in one self-contained HTML under `.agents/reference/`, every box verified against code, with an exists / to build / later legend. Analyze-only. Not `/architect` (decides structure before code) and not `/architecture-review` (audits code for refactors). |
| `/setup:map-codebase` | **Brownfield bootstrap** — adopting the workflow into a large existing codebase that never had AI. One run: parallel fan-out comprehension (distilled summaries, no context flooding) → `architecture.md` + reconstructed `docs/PRD.md` → cascades into `/maintain:refresh-brief` + `/setup:create-CLAUDE_MD`. Two review checkpoints (scope; PRD validation). See [.claude/commands/setup/map-codebase.md](../commands/setup/map-codebase.md). |
| `/test-e2e <flow\|jira-key>` | After implementing a UI feature — explores the UI with MCP Playwright, produces a test plan for approval, generates Playwright tests under the project's test directory. Three input modes: empty (reads latest plan in `.agents/plans/active/`), Jira key like `CS-1` (pulls acceptance criteria via mcp-atlassian), or a flow name. Requires MCP Playwright; falls back to degraded mode otherwise. |
| `/maintain:sync-from-starter [--check\|<ref>]` | Pull newer workflow definitions from the upstream starter (commands, agents, skills, hooks, config) without touching project knowledge. 3-way aware via a committed `.claude/.starter-sync.json` provenance manifest; recommends but asks on `settings.json`/hook conflicts. `--check` = dry-run only; `<ref>` = pin to a tag. See [.claude/starter-sync-playbook.md](../starter-sync-playbook.md). |
| `/maintain:sync-herdr-kit [<ref>]` | Opt-in, per developer: install or update the Herdr panels kit (side panels and the `harness` layout) from the starter into your Herdr app home (`~/.config/herdr-app`). Clones the starter, shows the kit installer's dry run, writes only after your yes, never moves a folder you copied by hand; does nothing without a Herdr app home. `/maintain:sync-from-starter` never runs it — it only names it when the kit changed upstream. |
| `/maintain:cleanup-workflow` | Periodic AI-workflow housekeeping. Five sequential phases: (1) reference integrity check across 6 categories — markdown links, path refs, section anchors, slash commands, MCP tool refs, the `CLAUDE.md` section contract; (2) memory pruning — surfaces stale entries in `errors.md` / `decisions.md` / `patterns.md` / `api.md` / `domain/*` and archives them (per-entry user decision) to `.agents/memory/archive/`; (3) workflow health warnings — empty status stuck >30 days, orphan specs, stale active plans, audit log size, large memory files, `CLAUDE.md` over its cap or carrying narrative that belongs in memory; (4) workflow optimization audit — systemic drift in the workflow itself (stale auto-loads, internal contradictions, unbounded automation, config gaps); (5) `CLAUDE.md` diet — opt-in, per-paragraph: moves history and rationale into `decisions.md` / `errors.md` / `reference/` and leaves a one-line pointer, measuring before and after. No auto-fix in Phase 1, archive-not-delete in Phase 2, signal-only in Phases 3–4, consent per move in Phase 5. |
| `/retro` | At the end of a long or frictional session, before `/clear` — generates an **evidence-based** session retrospective from the session's `.jsonl` transcript (paths, counts, tool-call refs, timestamps; no opinions or self-assessment). Refuses to write when the session was trivial or friction-free (`<15` tool calls, `<5` min, or zero friction signals) — `--force` overrides loudly. Saves one `.md` under `.agents/retros/` (or `.claude/retros/`); never touches code or repo state. Output feeds `/maintain:cleanup-workflow`. Flags: `--dry-run`, `--force`, `--transcript <path>`, `--slug <kebab>`. |
| `/brainstorm [topic \| Task id \| KEY]` | Designing one Task — questions, 2–3 approaches, a spec in `.agents/specs/`, cross-reviewed by Codex. Empty = next free backlog Task. |
| `/plan-feature [spec]` | After the spec is approved — a step-by-step plan with tests and checks per step, then a mandatory grill and a Codex review. |
| `/execute [plan] [codex]` | Building an approved plan, step by step; `codex` lets Codex write the code under Claude's supervision. |
| `/commit` · `/push` · `/pull` | Commit only the files this session changed (memory goes in a separate commit) · push with a pre-publication secret scan · pull the latest code. |
| `/release` | Cutting a version — commit + tag. |
| `/orchestrate <feature \| spec \| plan>` | Hands-off: runs brainstorm → plan → build (execute → refine → verify → commit → push per step) → closing commit, compacting between stages; asks only at forks and blockers. |
| `/recon <topic>` | Before `/brainstorm` on a broad topic — research agents gather memory, prior specs, the integration surface, docs and similar repos into a cited brief (no files written). |
| `/handoff [focus]` | At a session boundary — compacts the conversation into a handoff file in `.agents/handoffs/` for the next session. |
| `/pr-merge` | Completing an Azure DevOps pull request — publishes a draft, approves, completes with the Branch-model strategy, cleans up branches, moves the Jira ticket. |
| `/gates:design-quality-check` | Pixel-level audit of an implemented UI section against its reference design. |
| `/setup:create-CLAUDE_MD` | After the first scaffolding — generates `CLAUDE.md`, `architecture.md` and the project README from the real code. |
| `/analysis` | Deep analytical pass before a decision — no code, no files, 99% certainty rule, uses `AskUserQuestion` when possible. |
| `/simply [topic]` | Re-explains what just happened in plain language — what I did / did it work / what now, in the project's communication language. No new work, no file edits, no memory writes; empty argument defaults to the immediately preceding work. |
| `/tasks-status` | When you want to know where the work stands — read-only, fresh each run. First what waits for **your** decision (tasks whose evidence says they wait on you), then what waits on the team (role questions, blocked runs, PRs awaiting merge), then every open task with what blocks Done, its team run and PR state, and one recommended next action. Works for `teams.tracker` / `tracker` = `github` (via `team-tracker.sh list`/`show`), `jira` (MCP; scope from `status_report.jira_jql`, default: my open issues) or `none` (`.agents/backlog.md`); team columns appear only with a `teams` block. Every row has a ref (`W1`, `2c`) you can answer by. |
| `/gates:verify-implementation [plan-name]` | After `/execute` finishes a plan — validates checklist completion, runs quality gates from `CLAUDE.md → Validation` (or stack-detected fallback), performs language-aware semantic review (TypeScript-first; sections gated on detected stack), and verifies design compliance for UI plans. Reports only — does not modify code. For a quick check before committing, without a plan, run the `CLAUDE.md → Validation` commands themselves; a check you want enforced — a formatter in check mode included — belongs in `Validation`, the one list every gate runs. |
| `/check-implementation [plan-name] [codex] [--base <rev>]` | The **full** quality loop after `/execute`: two parallel read-only finders (correctness ∥ structure, pinned models; a finder falls back to the session's model after two rate-limit or model-unavailable failures unless `workflow.finder_fallback` is `off`) → your session applies their findings → `gates:verify-implementation` (read-only gate) → the design gate when UI changed and a reference design exists, looping up to 3× until the gate approves — then a one-shot **codex cross-model review** of the approved diff (Step 1.5, only if `codex` is installed; judge-only, findings go through the fixer) — then stopping for `/commit`. Unlike `/gates:verify-implementation` it **applies** fixes; unlike `/orchestrate` it does not commit/push. `/orchestrate` runs the same passes per step through its refiner (Step 5.1b), with `code-review --fix` inline instead of finders. With `codex`, Codex applies the fixes and Claude only judges. |
| `/quick-change <what to change>` | **The fast lane for small changes** — when `/brainstorm → /plan-feature → /execute` is too heavy but "just do it" is too risky. Short plan in chat (no spec, no plan file) → **`codex` reviews the plan before any code exists** (idea mode) → implement → `/code-review` at low effort → `/deep-review` → the `CLAUDE.md → Validation` gates. The review is **mandatory — there is no opt-out flag**; it is skipped only when `codex` is not installed, and the report says so on its own line. A Phase 0 guard always fires when the change touches a sensitive path, spans >~5 files, adds a dependency, changes a schema/contract, or needs a design reference — it names the criterion and recommends the real route, and you may override it. Writes nothing to `.agents/`, never commits. |
| `/codex-review [idea\|diff] [hint]` | **Independent cross-model review** — hands the current work to `codex` (a different model) for a review steered by zero opinions, then judges its findings honestly back in the main thread. Two modes, auto-detected: **`diff`** reviews CHANGES already made (uncommitted/unpushed work), **`idea`** reviews a PROPOSAL before any code is written. Codex orients itself by replaying `/prime`, runs detached with a heartbeat every ~3 min, and only advises — you decide what to apply. Requires `codex` on `PATH` (see Requirements); hard-stops with a clear message if absent. |

Harness files should have an owner — route `.claude/**`, `.agents/**`, `CLAUDE.md`, `TESTING.md` and `docs/DEFINITION-OF-DONE.md` to a tech lead in CODEOWNERS, so a change to the rules gets a rules-owner review (`/setup:start` prints the stanza).

---

## Team supervision (opt-in)

For projects that run several AI **teams** in parallel on one machine. A team is a permanent git clone that runs a ticket through a fixed pipeline of fresh role sessions (planner → coder → qa → wrapup, or one `cli` role), driven by a shell runner in tmux. **Supervision roles** watch the teams:

- a **Supervisor** that talks to you, merges within the gate and starts teams;
- an **Advisor**, with an optional second-vendor **Reviewer**, for contract, schema, AC, sensitive-path and harness-rule questions.

You are asked only for a short critical list and for actions only a human may click.

Scripts, not prompts, enforce the routing, the binding of each answer to the exact prompt, the human-only refusals, the merge gate and the alarms.

**Requirements:** macOS (Linux is not supported yet), plus `jq`, `claude`, `codex`, `git`, `python3`, `perl` and a session host — `tmux`, or Herdr (`hc`) with `teams.session_host: "herdr"` — and `/setup:teams` stops if one is missing (`sqlite3` only for the agent-mail kit). The Codex CLI is required even with `advisor: solo`.

It is off until you opt in. `/setup:teams` installs the team layer into a project, and the agent-mail kit (cross-machine mail) only when you ask for it. `/start-team` provisions and starts a team, the run's own TeamLead supervises it (see *Per-run TeamLead* below), and `/tasks-status` shows where every task and run stands. Commit and push the `teams` profile to trunk before the first `/start-team`. The supervision role sessions are started, restored, stopped and listed by `/roles` (after a crash or reboot too: it restores the standing roles, asks which interrupted team runs to resume, and prints a resume line for each gone ad-hoc conversation; `/roles resume <Role>` continues a Claude role's previous conversation; the driver behind it: `.agents/reference/session-host.md`); the role contract reaches each session through the SessionStart hook on start, `/clear` and compaction. The old commands `/session-role`, `/sessions-up`, `/mail-role`, `/team-watch` and `/monitoring` are gone (`/setup:teams` removes their unchanged copies from a project). Everything project-specific is configuration in `.claude/project-profile.json` → `teams` (`teams.channel` for names, `teams.policy` for policy) and never a default.

- Setting it up: run `/setup:teams <path to this starter clone>` in **your project's** root, then follow [`docs/teams/09-setup.md`](https://github.com/mrozmk/AI_Coding_Starter/blob/main/docs/teams/09-setup.md) (fresh machine or one that already runs the channel, the profile from `.claude/project-profile.json.example`, the operator kit).
- Human overview: [`docs/teams/`](https://github.com/mrozmk/AI_Coding_Starter/blob/main/docs/teams/README.md): decision model, pipeline, permissions, operator kit, follow-ups.
- The contracts the agents follow: `.agents/reference/team-*.md`, `agent-mail.md`.
- What is implemented vs verified on which host: `docs/teams/capabilities.md` — the offline column comes from the team test suite, the live column from the acceptance run.

### Per-run TeamLead (pilot)

Instead of one global TeamLead watching every team, each team run can get its own **TeamLead**: a session the runner starts next to the stages and ends with the run. It gates the plan against the order (there is no spec gate), answers the stages' questions and permission prompts on an authority, accepts the delivery against the order (a blind order-vs-diff check) and orders rework within a budget. It never edits code, commits or merges.

- **When:** every brainstorm and quick run (mode `cli` never has one); `/start-team` asks for the order brief of each new run.
- **Where you answer:** the `<team>-lead` window. Only human-only items reach you — a settings or permission edit, a production ask rule, egress, an irreversible delete — as `[d-<n>] <question>`. Type your answer there.
- **What reaches you:** two notifications — `human_decision` (a pending decision) and `abandon_decision` (the lead recommends abandoning a run past its rework budget). The Supervisor gets four inbox events: `accepted`, `closed`, `collision` and `session_dead`.
- **Where to look:** `runs/<run>/acceptance-brief.md` in the team clone (what was ordered vs delivered), and `.agents/team/teamlead-log.md` in your checkout (the lead's notes, one block per finished run).
- **Its limits:** [`team-decision-model.md` §3](../../.agents/reference/team-decision-model.md), "Where the trust ends". The contract is in `.agents/reference/team-lead.md`.

## Orchestration internals — how the agent-spawning commands work

Three commands do heavy multi-step work. They use **two different orchestration mechanisms** and spawn different agents per role. This section spells out exactly what runs, when, why, and at which effort.

### Model & effort strategy (shared across the pipeline)

**Model and effort are chosen per role**, pinned in each agent's frontmatter (`model:` + `effort:`). Effort cannot be passed at spawn time (the `Agent` tool takes `model`, not `effort`), so it lives in each agent's frontmatter; that is also why the harder executor tier is a separate agent file rather than an argument. The rule is **lower the effort for doers, never for gates**: a false "pass" from a weakened audit lets a defect onto `main` and costs more than every token it saved.

| Role | Agent | Model · effort | Mutates? | Why |
|------|-------|----------------|----------|-----|
| Orchestrator (your session) | — (the `/orchestrate` driver) | your interactive session's setting | no (decides/routes) | needs the most judgment — it loops, gates, escalates |
| Execute a plan | `orchestrator-executor` | Opus 5 · `medium` (`acceptEdits`) | ✅ code | implementation against a plan that already did the thinking |
| Execute a hard step | `orchestrator-executor-hard` | Fable 5.1 · `medium` (`acceptEdits`) | ✅ code | same contract, a stronger model — spawned when the plan marks the step `medium` |
| Refine (bugs + cleanup) | `orchestrator-refiner` | Fable 5.1 · `medium` (`acceptEdits`) | ✅ code | runs `code-review --fix` + `deep-review` |
| Verify (code gate) | `orchestrator-verifier` | Fable 5.1 · **`high`** | ❌ read-only | the gate must be sharp; independence from the fixer |
| Design parity | `orchestrator-designer` | Opus 5 · **`high`** | ❌ read-only | pixel/structural audit vs reference design |
| Design critique | `design-critic` | Fable 5.1 · **`high`** | ❌ read-only | judges `/design-ui` mockups from rendered screenshots — the author fixes, the critic never edits |
| Start-phase critique | `start-critic` | Fable 5.1 · **`high`** | ❌ read-only | judges `/discover`, `/architect` and `/check-backlog` artifacts against their rubric — the author fixes, the critic never edits |
| Correctness finder | `correctness-reviewer` | Opus 5.5 · **`xhigh`** | ❌ read-only | `/check-implementation` Step 1ab: runs `/code-review` and reports confirmed bugs; the main session applies fixes |
| Structure finder | `structure-reviewer` | Fable 5.1 · **`high`** | ❌ read-only | runs `/deep-review report-only` in parallel with the correctness finder |
| Finder fallbacks | `correctness-reviewer-fallback`, `structure-reviewer-fallback` | the session's model (`inherit`) · same effort as their finder | ❌ read-only | only after a finder's pinned model failed twice on a rate/usage limit or was unavailable, unless `workflow.finder_fallback` is `off`; same contract, named in the report |
| Security audit | `audit-threat-modeler`, `audit-control-verifier`, `audit-finding-validator` | Opus 5 · **`high`** | ❌ read-only | threat model, invariant checks and a falsifier pass for `/audit-security` |
| QA verifiers | `qa-contract`, `qa-runtime-ui` | Sonnet 4.6 · default | ❌ read-only | `/qa-verify` evidence families — see the note below |
| Commit | `orchestrator-committer` | Sonnet 5 · `low` (`acceptEdits`) | ✅ git index | purely mechanical stage+commit |
| Doc sync | `documentation-manager` | Opus 5 · `low` | ✅ docs | only on `/orchestrate --sync-docs` when docs would drift |

**Codex runs** are pinned the same way, through `CODEX_EFFORT` (`.claude/lib/codex-bg.sh` refuses to start without it): every Codex **review** runs at `high` — `/brainstorm`, `/plan-feature`, `/check-implementation` (incl. its `codex` fixer mode), `/orchestrate`, `/codex-review`, `/quick-change`, `/discover`, `/architect`, `/audit-security`, `/architecture-review`, `/design-ui` — and `/execute codex`, where Codex writes the code, runs at `medium`.

> **Difficulty travels in the plan, not the terminal.** `/plan-feature` writes `**Execution effort:** low | medium` into a single-file plan's header, or an `Effort` cell per row in an umbrella plan's `## Execution Plan` table. `/orchestrate` reads that to choose between `orchestrator-executor` and `orchestrator-executor-hard`. Changing the pinned model means editing `model:` in `.claude/agents/*.md` — a deliberate sync point, so the pipeline never silently drifts onto a costlier tier.

> Keeping the **verifier/designer (judges) on a different, read-only setup from the executor/refiner (fixers)** is deliberate — no agent grades its own homework.

> **Cheaper tiers where cost dominates:** the `/qa-verify` verifiers (`qa-contract`, `qa-runtime-ui`) pin Sonnet 4.6 — they run many in parallel per QA run and do bounded reads, so the per-agent model cost, not judgment depth, dominates. The committer pins Sonnet 5 for the same reason: staging and committing is mechanical.

### `/check-implementation` — in-context quality loop (no fleet)

Drives freshly-written code to **commit-ready**, then stops. Runs **in your own session** (you see every step) — it does *not* spawn an executor fleet; it spawns the two read-only finders each round (their reports come back, your session applies them), the design gate (to isolate visual-tool output) and, when installed, the Codex cross-model review. It **applies fixes** but never commits. **Cost:** two subagents per iteration (Opus 5.5 `xhigh` + Fable 5.1 `high`, up to 3 iterations) instead of one inline pass of each skill — faster wall-clock, more tokens.

`/check-implementation codex` swaps the fixer: Codex (effort `high`, workspace-write) becomes the only thing that edits code, the review steps run report-only, and Claude stays the judge. It needs a clean tree and a plan, and takes `--base <rev>` to set the diff base.

```
resolve scope (plan | diff-only)
  └─ loop, max 3×:
       1ab @correctness-reviewer ∥ @structure-reviewer   (read-only finders, pinned models;
            fingerprint + report contract + finder-model.sh; session-model fallback on 429/unavailable)
           apply in your session: bugs first, then structure re-checked against the fixes
       1c /gates:verify-implementation   (read-only CODE gate: tests/lint/build + semantic review)
       1d @orchestrator-designer  ← spawned, Opus 5 high, ONLY if UI changed AND a reference design exists
       1e decide: approve → done · gaps → next round's FOCUS · blocker / 3× → escalate to you
  └─ 1.5 cross-model review ← codex (different model, read-only judge; only if installed) reads the
       gate-approved diff cold — surviving findings get ONE fixer pass + re-gate, never a new loop
  └─ leaves a clean tree → you run /commit
```

**Why this order:** find in parallel, apply bugs first (don't polish code you're about to rewrite), cleanliness second, then the read-only gate (it can't invalidate itself), design last (slowest, UI-only). The design gate defaults to **skip** unless the change touches UI *and* a reference design exists.

### `/orchestrate` — idea-to-commit pipeline (brainstorm → plan → build → commit, compacting between stages)

`/orchestrate <feature>` runs `/brainstorm` and `/plan-feature` in **pipeline mode** (no approval or grill-scope questions — the spec is auto-approved with its assumptions listed, the grill applies **All**, a split defaults to densify-or-umbrella) and then the plan runner below, closing with one `chore` commit of the workflow state (plan moved to `done/`, run-log, memory, backlog). Between stages — and between the steps of an umbrella — it writes a handoff marker and ends its turn; the bundled **`stage-handoff` mod** (`.claude/skills/stage-handoff/`, loaded automatically in a trusted project) compacts the session with stage-boundary instructions and resumes it with `/orchestrate --resume`. State lives in `.claude/orchestrate-run.json`, so a resumed stage reads the spec and plan from disk, not from the summary. `--abort` retires a run. It interrupts you only for a directional fork, a 🔶 rethink signal, or a blocker; every answer is recorded so no stage re-asks.

**The plan runner** (`/orchestrate <plan-path>`, also Stage 3 of the pipeline) is the only part that takes a plan all the way to **pushed**. Your main session becomes the **orchestrator**: it decides / routes / loops / reports and performs the `git push` itself (push authorization lives in your session, not in sub-agents) — but it never implements, audits, or commits. Each of those is a sub-agent.

**Per step** (sequential; flat = one plan, umbrella = a DAG of steps each in its own git worktree on a named branch, fast-forward-merged to `main`):

```
5.1  Execute       → @orchestrator-executor   (Opus 5 medium; the plan's Effort column routes `medium` steps to @orchestrator-executor-hard, Fable 5.1)
5.1-recon          → orchestrator re-derives the facts itself (independent ground-truth, before trusting any report)
5.1b Refine        → @orchestrator-refiner     (Fable 5.1 medium — code-review --fix + deep-review)
5.2  Verify   ≤3×  → @orchestrator-verifier    (Fable 5.1 high, read-only)        ┐ GAPS loop back
5.3  Design   ≤2×  → @orchestrator-designer    (Opus 5 high, read-only)          ┘ into the next Refine/Execute
       (5.3 runs ONLY if .agents/specs/design/Ready/ exists)
5.3b Second judge  → codex (high, read-only) — ONLY for `Effort: medium` steps; surviving
                     findings get one refine→verify cycle before the commit
5.4  Commit        → @orchestrator-committer   (Sonnet 5 low) → clean-build gate
5.4b Push          → orchestrator (your session) — git push, ff-merge the step branch to main
─ once, end of run ─
7.0  Cross-model   → codex (different model, read-only judge; only if installed) reviews the whole
     review          run's diff cold — surviving findings get ONE refine→verify→commit cycle
```

**Looping & escalation:** verifier/designer GAPS feed back into the next refine/execute pass; it loops fixes on its own and **escalates to you only on a real blocker** (Phase 6) — never asks "continue?" mid-loop. On completion (Phase 7) an independent codex pass cross-reviews the whole run's diff (step 0, only if `codex` is installed — surviving findings get one refine→verify→commit cycle), then it moves the plan + a durable run-log to `plans/done/`; with `--sync-docs` it spawns `@documentation-manager` and commits a `docs:` follow-up.

> `/check-implementation` ≈ the 5.1b→5.2 slice of `/orchestrate`, run inline in your session without the commit/push. Use `/check-implementation` when you want to drive + review; `/orchestrate` when you trust the pipeline to ship.

### `/setup:map-codebase` — Workflow fan-out (a different primitive)

Brownfield comprehension uses the **`Workflow` engine**, not the Agent-tool fleet above — a deterministic script whose parallelism the engine caps. Your session drives the **interaction + sequencing** (the two checkpoints, the cascade); the Workflow runs the **parallel compute**.

```
Phase 0  Scan & filter        (deterministic bash, NO LLM — git ls-files -z, categorize, import-graph in-degree)
   🛑 Checkpoint 1 — confirm scope (what's analyzed / skipped)
Phase 1  Fan-out (parallel, concurrency capped by the Workflow engine):
            N × module-analyzer   (one per module — schema-validated summary, NEVER raw source)
         then, in a second parallel batch:
            docs-analyzer         (README/docs/ADRs → decisions, patterns, the "why")
            infra-analyzer        (IaC/CI → hosting, deployables, external services)
Phase 2  Synthesis (from summaries only — never re-reads code):
            architecture-synthesizer  → architecture.md (+ topology + Mermaid map)
            reverse-prd-writer         → docs/PRD.md
            data-model-synthesizer     → domain/data-model.md (if persistence)
   write artifacts
   🛑 Checkpoint 2 — validate the reconstructed PRD
Phase 4  Cascade → /maintain:refresh-brief → /setup:create-CLAUDE_MD
```

**Anti-flooding contract:** analyzers return distilled summaries, never file contents — so codebase size scales the *number of agents*, not the aggregator's context. Workflow agents inherit your **session model**; the script never holds source code.

---

## When to run `/setup:createwikillm`

`/setup:createwikillm` bootstraps a persistent, synthesized knowledge base (Karpathy's LLM Wiki pattern). It is **not** part of the minimal flow — run it only when the signals below match your project.

**Run it when:**
- You have **≥ 3-5 matured specs in `.agents/specs/`** or completed plans in `.agents/plans/done/`, and the same knowledge keeps resurfacing across features.
- You are building a **product-facing LLM** (chatbot, runtime assistant, agent) that needs synthesized domain knowledge injected into its context at query time.
- **`.agents/sources/` is a large corpus** (many transcripts, patch-notes, documentation files) that will not fit into a single prompt and benefits from pre-synthesis.
- `.agents/memory/` entries are **drifting into long narratives** instead of short, actionable lessons — that is a signal you need a wiki layer.

**Skip it (and stay with `memory/` + `reference/`) when:**
- The repo is **fresh**, with no specs or completed plans yet.
- The project is **small / single-feature** — memory files are enough.
- There is **no product-LLM** consuming the wiki at runtime, and `.agents/sources/` is empty or ephemeral.
- You would be maintaining it "just in case" — an unused wiki rots faster than it helps.

If in doubt: do **not** run it. You can always add `/setup:createwikillm` later; removing an unused wiki after the fact is more work than adding one when you actually need it.

---

## Design principles

- **KISS, YAGNI, SOLID** — write the simplest thing that works
- **Fail fast** on programmer errors; degrade gracefully on user/env errors
- **Read memory before acting** — `.agents/memory/` is permanent project context
- **Design before building** — `/brainstorm` is a hard gate before implementation
- **Commits tell a story** — conventional commits via `/commit`, no AI attribution unless asked

Full rules live in [CLAUDE.md](../../CLAUDE.md).

---

## Permissions & safety

`.claude/settings.json` ships a security-first policy:

- **Git:** AI may run non-destructive operations — `status`, `diff`, `log`, `add`, `commit`, `push`, `pull`, `fetch`, `stash`, `tag`, `describe`, `rev-parse`, `rev-list`, `symbolic-ref`, `check-ignore`, `ls-remote`, `remote get-url`, `switch`, `worktree add/list/prune/remove`, plus `revert` (only ever adds a new commit) and `merge --ff-only` (no merge commit, no history rewrite) — via the shipped [/push](../commands/push.md) / [/pull](../commands/pull.md) / [/release](../commands/release.md) / [/commit](../commands/commit.md) skills. The rest sits in two guard tiers (full lists in `settings.json`): **denied** — no prompt can override — are `push --force`/`-f`/`--force-with-lease`, `reset --hard`, `clean -f*`, `checkout -- *`/`checkout .`, `restore .`/`--staged`, `rebase` (incl. `pull --rebase`/`-r`), `switch -f`/`-C`/`--force`/`--discard-changes`, `cherry-pick`, `config`, `remote remove/set-url/rename`, `reflog expire`, `gc --prune=now`/`--aggressive`; **ask-tier** — always prompts, even in auto mode — are `git rm`, `branch -d`/`-D`, `merge --no-ff`/`--squash`, `remote add`, `rm -rf`. A bare `git merge` and `git reset` soft/mixed are in no list — they prompt interactively.
- **Secrets:** editing `.env`, `*.pem`, `*.key`, `id_rsa*`, `id_ed25519*`, `*secret*` and `*credentials*` is denied; editing `.env.*` (e.g. `.env.example`) is ask-tier. Reading them is not blocked.
- **Inline tokens in shell:** `Bash` denies any command containing known secret prefixes (`ATATT`, `ghp_`, `github_pat_`, `gho_`, `ghs_`, `ghu_`, `xoxb-`, `xoxp-`, `xapp-`, `xoxa-`, `AKIA`, `ASIA`, `sk-ant-`) — defense-in-depth so a literal token never gets cached in `permissions.allow` after an "Always allow" click.
- **Secrets in pushed content:** the `guard-push` hook scans every `git push` for secrets in the commits about to be published — closing the gap the deny-prefixes leave open (a token in file *content*, not in a shell command). It blocks (exit 2) on known-format tokens, private keys, credentialed connection strings, hardcoded credential assignments, and credential files (`.env`, `*.pem`, `*.key`, `.npmrc`, `*.tfstate`, …); uses `gitleaks` for a broader pass if installed. Escape hatches: inline `# guard-push:allow`, `*.example` files, or `GUARD_PUSH_SKIP=1 git push` (logged to `audit.log`). See [/push](../commands/push.md).
- **Dangerous shell:** `sudo` — denied; `rm -rf` — ask-tier (always prompts).
- **Data egress:** uploads through `curl` (`-d`/`--data`/`-F`/`--form`/`-T`/`--upload-file`/`--json`/`-X`/`--request`) and `wget` (`--post*`/`--body*`) are denied; plain downloads are not.
- **Jira / Confluence:** search and read are allowed; every create, update, comment, transition and link is ask-tier; deletes and page-restriction changes are denied. Bypassing an Azure DevOps PR policy (`az repos pr … --bypass-policy`) is denied.
- **Hooks** (registered in `settings.json`; most need `jq`):

  | When | Hook | What it does |
  |------|------|--------------|
  | before Bash/WebFetch/Write/Edit | `audit-append` | appends a timestamped audit trail to `.claude/audit.log` (gitignored) |
  | before `git commit` | `guard-commit` | blocks a commit with nothing staged (so `git add … && git commit` in one call is blocked too), scans the staged changes for credentials, and logs the staged set |
  | before `git push` | `guard-push` | pre-publication secret scan (above) |
  | before Edit/Write | `guard-memory`, `guard-team-memory` | memory-distillation gate; team clones may write memory only from the wrap-up role |
  | before AskUserQuestion | `guard-team-question` | holds a team stage to one question per AskUserQuestion call |
  | after Edit/Write | `guard-comments`, `nudge-files`, `guard-memory-scope` | comment-noise nudge, file-size nudge, memory-scope check |
  | after Read/Bash | `track-memory-read` | memory read telemetry |
  | around Grep/LSP | `nudge-lsp`, `warm-lsp` | nudge toward LSP for symbol searches; warm tsserver before cross-project queries (TS/JS) |
  | session start | `check-deps`, `check-project-deps` | dependency preflight |
  | notification | `team-attention` | surfaces a team session waiting for a human |

  The team layer adds two more when `/setup:teams` installs it: `guard-destructive-sql` (denies `DROP`/`TRUNCATE`, asks on any other SQL write) and `guard-team-egress`.

User-local overrides live in `.claude/settings.local.json` (gitignored) — Claude Code writes new "Always allow" approvals there by default, keeping per-session permissions out of the committed `settings.json`.

---

## Customizing the starter

- Edit `CLAUDE.md` placeholders after `/setup:create-CLAUDE_MD` runs — add project-specific rules, naming conventions, key files.
- Add reference docs to `.agents/reference/` as you integrate new APIs/libraries.
- Drop in new slash commands under `.claude/commands/` — they appear automatically.
- Tighten or loosen `.claude/settings.json` permissions to match your risk profile.
- **Sync workflow with upstream** — when this starter ships new commands or updated skills, refresh `.claude/` and the `.agents/` framework in a downstream project without touching your project's memory, specs, plans, or `CLAUDE.md`. Run the command:

  ```
  /maintain:sync-from-starter            # full run: report → task list → ask per task → apply
  /maintain:sync-from-starter --check    # report what would change, write nothing
  /maintain:sync-from-starter v3.1.0     # pin to a specific starter ref
  ```

  It clones the upstream starter to `/tmp`, classifies every file into three buckets — **A** overwrite (commands, agents, skills, templates, **hooks**, `.claude/lib/`, `.claude/workflows/`, the team-harness files, `.claude/STARTER-LICENSE`, this guide in `.claude/docs/`), **B** merge with a diff (`settings.json` permissions, `index.md`, `.gitignore`, `memory-domains.json`, `.editorconfig`, `.mcp.json`, `.env.example`, `comment-guard.json`, `qa-env.json`, the memory log headers), **C** never touch (your `CLAUDE.md`, `architecture.md`, append-only memory, specs, plans, root README, `LICENSE`, code) — then builds a task list from the report and works through it one task at a time: it analyses the change, asks you, and has a subagent make the edit. Nothing is written without your answer. Finally it proposes a `chore(workflow): sync …` commit. It tracks provenance in a committed `.claude/.starter-sync.json` so repeated syncs become true **3-way merges** (telling intentional local edits from staleness, detecting upstream-deleted files), and on real `settings.json`/hook conflicts it **recommends but asks** rather than overwriting. Authoritative file classification and flow: [.claude/starter-sync-playbook.md](../starter-sync-playbook.md); command: [.claude/commands/maintain/sync-from-starter.md](../commands/maintain/sync-from-starter.md).

---

## The root README is yours

A single root `README.md` can't serve two audiences at once: visitors to the *starter repo* want
to read about the framework, but your *project* needs its root README to describe the application.
So the two are kept apart:

1. **In the starter repo**, the root `README.md` is a short landing page, marked with a
   `<!-- STARTER-KIT-README` comment on its first line. The full framework documentation — this
   guide — lives in `.claude/docs/` from the start.
2. **On your first `/setup:create-CLAUDE_MD`**, the command sees that marker and replaces the landing
   page with a fresh project `README.md` from `.claude/templates/README-template.md`, filled with your
   project name, description, tech stack, commands, and structure. A project with no root README gets
   one generated the same way. Nothing needs to be moved: the guide is already in `.claude/docs/`.
3. **When the root README has no marker** (later runs, or an existing project's own README), your
   README is left alone — the command only offers to fill leftover `{placeholder}` markers, never
   clobbering a customized README.

After bootstrap:

| File | Owner | Updated by |
|------|-------|------------|
| `README.md` (root) | **your project** | you / `/setup:create-CLAUDE_MD` placeholder fill |
| `.claude/docs/` | **the framework** | `/maintain:sync-from-starter` (category A — overwritten with the starter's newest docs) |
| `LICENSE` (root) | **your project** | `/setup:create-CLAUDE_MD` bootstrap — you pick the license type + copyright holder |
| `.claude/STARTER-LICENSE` | **the starter** (MIT attribution, preserved) | `.claude/starter-sync-playbook.md` |

> **`LICENSE` is swapped, not replaced.** On first `/setup:create-CLAUDE_MD`, the starter's MIT license moves to `.claude/STARTER-LICENSE` (preserving the starter author's copyright notice — MIT requires it to survive in copies of the scaffolding) and a fresh root `LICENSE` is generated for *your* project from the type + copyright holder you choose. Later runs leave your `LICENSE` untouched.

> **Projects bootstrapped before this layout** have the old framework guide at `.claude/README.md`.
> It is a stale copy now — the sync no longer updates it, and you can delete it; the current guide is
> `.claude/docs/guide.md`.

---

## Language convention (default)

The starter assumes:
- Claude ↔ developer: **Polish**
- Code, comments, commits, technical docs: **English**
- User-facing UI: **per PRD**

Change this in `CLAUDE.md` → `Language Rules` if your team prefers a different split.
