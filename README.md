# AI-Assisted Development Starter Kit

A minimal, opinionated starter for projects built with [Claude Code](https://claude.com/claude-code) as a first-class development partner.

This repo ships **no application code** — only the scaffolding that makes Claude a reliable collaborator:

- `.claude/` — commands, agents, and permission settings
- `.agents/` — five persistent knowledge layers (sources, memory, reference, specs, plans)
- `CLAUDE.md` — project rules seed, ready to be filled in per project
- `.gitignore`, sensible defaults

---

## What's in the box

### `.claude/`

| Path | Purpose |
|------|---------|
| `commands/` | Slash commands — `/brainstorm`, `/plan-feature`, `/execute`, `/commit`, `/push`, `/pull`, `/release`, `/analysis`, `/prime`, `/create-PRD`, `/create-CLAUDE_MD`, `/check-quality`, `/createwikillm`, `/remember`, `/explain` |
| `agents/` | Sub-agents — `documentation-manager` |
| `skills/` | Skills — `/jira` (Jira Cloud via `mcp-atlassian` — create / edit / search / transition / comment / link Epics, Tasks, Bugs) |
| `templates/` | Starting templates — `CLAUDE-template.md` |
| `settings.json` | Security-first permissions (non-destructive git allowed, destructive ops denied, deny on secrets, audit-log hooks) |

### `.agents/`

Five layers of persistent project knowledge:

| Layer | Contents | Lifecycle |
|-------|----------|-----------|
| `sources/` | **Raw input materials** — briefs, transcripts, sketches, PDFs supplied by the user. Feeds `/create-PRD` and `/createwikillm`. Never modified by Claude. | Immutable input, pruned manually |
| `memory/` | Lessons, decisions, quirks, patterns | Append-only, permanent |
| `reference/` | Stable domain/API references | Long-lived, updated as domain evolves |
| `specs/` | Design docs from `/brainstorm` | Lives with the feature |
| `plans/` | Implementation plans — `active/` → `done/` | Short-lived |

Full routing of "what goes where" lives in `CLAUDE.md` and `.agents/memory/index.md`.

---

## Quick start

### 1. Clone as a new project

```bash
git clone <this-repo> my-new-project
cd my-new-project
rm -rf .git
git init
```

### 2. Drop raw materials (optional)

If you already have briefs, transcripts, sketches, PDFs, or any written materials describing the product — drop them into [.agents/sources/](.agents/sources/). Both `/create-PRD` and `/createwikillm` will pick them up automatically as input context.

> **Next step:** once the materials are in place, run `/create-PRD` (step 3 below) — it reads `.agents/sources/` automatically and uses its contents alongside the conversation to draft the PRD.

### 3. Define the product

```
/create-PRD
```

Generates `docs/PRD.md` from your conversation **plus** any files in `.agents/sources/`. The PRD defines **what** you're building and **why** — including the tech stack choice.

### 4. Initialize project rules (later, not now)

```
/create-CLAUDE_MD
```

> Run this **after** the PRD is written and you have at least some scaffolding (e.g. `npm init`, `uv init`, initial config files). It analyzes the codebase to extract real patterns — on a truly empty repo it has nothing to read. The seed `CLAUDE.md` already ships with language rules, knowledge-layer routing, and security defaults, so you are not blocked without this step.

When Claude can inspect actual code, it will fill in the placeholder sections of `CLAUDE.md` — overview, tech stack, commands, structure, architecture, conventions.

### 5. Design a feature

```
/brainstorm <feature idea>
```

Explores requirements, proposes 2-3 approaches, and writes a design doc to `.agents/specs/YYYY-MM-DD-<topic>.md`. No code is written until the design is approved.

### 6. Plan the implementation

```
/plan-feature          # picks up the newest spec from .agents/specs/
/plan-feature .agents/specs/2026-04-19-my-feature.md   # or point at a specific spec
```

Reads the approved spec, analyzes the codebase, and — **only if** the spec declares `External docs required: yes` — performs a web-research phase for the libs/APIs listed in the spec's `External dependencies`. Writes a step-by-step plan to `.agents/plans/active/`.

### 7. Execute

```
/execute
```

Runs the active plan. Moves it to `.agents/plans/done/` when complete.

### 8. Commit

```
/commit
```

Conventional-commit message, plus a memory checkpoint — captures any lessons, decisions, or patterns worth keeping in `.agents/memory/`.

---

## Daily workflow

| Command | When to run |
|---------|-------------|
| `/prime` | Start of every session — loads project context and relevant memory |
| `/analysis` | Deep analytical pass before a decision — no code, no files, 99% certainty rule, uses `AskUserQuestion` when possible |
| `/remember <topic>` | After a discovery — routes the entry into the right memory file |
| `/check-quality` | Before committing — format, lint, type-check, file-size gates |
| `/explain <code>` | When Claude is exploring unfamiliar code |

---

## When to run `/createwikillm`

`/createwikillm` bootstraps a persistent, synthesized knowledge base (Karpathy's LLM Wiki pattern). It is **not** part of the minimal flow — run it only when the signals below match your project.

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

If in doubt: do **not** run it. You can always add `/createwikillm` later; removing an unused wiki after the fact is more work than adding one when you actually need it.

---

## Design principles

- **KISS, YAGNI, SOLID** — write the simplest thing that works
- **Fail fast** on programmer errors; degrade gracefully on user/env errors
- **Read memory before acting** — `.agents/memory/` is permanent project context
- **Design before building** — `/brainstorm` is a hard gate before implementation
- **Commits tell a story** — conventional commits via `/commit`, no AI attribution unless asked

Full rules live in [CLAUDE.md](CLAUDE.md).

---

## Permissions & safety

`.claude/settings.json` ships a security-first policy:

- **Git:** AI may run non-destructive operations — `status`, `diff`, `log`, `add`, `commit`, `push`, `pull`, `fetch`, `stash`, `tag`, `describe`, `rev-parse`, `ls-remote`, `remote get-url` — via the shipped [/push](.claude/commands/push.md) / [/pull](.claude/commands/pull.md) / [/release](.claude/commands/release.md) / [/commit](.claude/commands/commit.md) skills. Destructive operations are **denied by default**: `push --force`, `push --force-with-lease`, `reset --hard`, `clean -f*`, `checkout -- *`, `restore .`, `branch -D`/`-d`, `rebase`, `merge`, `revert`, `cherry-pick`, `config`, `remote add/remove/set-url`, `reflog expire`, `gc --prune=now`.
- **Secrets:** `.env*`, `*.pem`, `*.key`, `*secret*`, `*credentials*` — write/edit denied.
- **Dangerous shell:** `rm -rf`, `sudo` — denied.
- **Hooks:** PreToolUse hooks append a timestamped audit trail to `.claude/audit.log` (gitignored).

User-local overrides live in `.claude/settings.local.json` (gitignored).

---

## Customizing the starter

- Edit `CLAUDE.md` placeholders after `/create-CLAUDE_MD` runs — add project-specific rules, naming conventions, key files.
- Add reference docs to `.agents/reference/` as you integrate new APIs/libraries.
- Drop in new slash commands under `.claude/commands/` — they appear automatically.
- Tighten or loosen `.claude/settings.json` permissions to match your risk profile.

---

## Language convention (default)

The starter assumes:
- Claude ↔ developer: **Polish**
- Code, comments, commits, technical docs: **English**
- User-facing UI: **per PRD**

Change this in `CLAUDE.md` → `Language Rules` if your team prefers a different split.
