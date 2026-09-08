# Supervised executor contract

How a skill delegates work to a second model. The mechanics live in `scripts/executor-orchestrator.mjs` and `scripts/git-baseline.mjs`; this file is what the calling skill must know, decide and record. It replaces the shell spawner and its prose: liveness is a process fact, "did the second model actually run" is answered by a confirmed header, and what the child did to the tree comes from a pair of snapshots taken around it.

## Roles and direction

| Author host | Worker | Model / effort |
|---|---|---|
| claude | codex | `gpt-6-astra` / `high` (adapter default; `--effort` overrides) |
| codex | — | refused |

The author host is passed explicitly (`--author-host`), never guessed. `--author-host codex` is refused with `executor-orchestrator serves Claude authors; a Codex author has no cross-model executor in this release` — no call site may ever count a second Codex process as an independent opinion.

**Read mode keeps its eyes.** The child runs under `--sandbox read-only` with `shell_tool` / `unified_exec` *enabled*: it must read files, run `git diff`, run `rg`. It has no context pack. What both modes disable is delegation and the side channels (`multi_agent*`, `apps`, `plugins`, `remote_plugin`, `hooks`, `browser_use*`, `computer_use`, `in_app_*`, `memories`, `goals`, `workspace_dependencies`, `image_generation`, and `web_search` by config). Write mode adds `--sandbox workspace-write`. This is the opposite of the reviewer adapter, which is closed-context on purpose; the two share `adapter.json` and nothing else.

## Groups

- **Write mode** requires `groups.execution`. Disabled → `skipped`, and the skill says so.
- **Read mode** is an opinion, so it requires `groups.execution` **and** `groups.review`. A project that switched review off never launches an automatic cross-model review; report the opt-out exactly as `brainstorm` does.
- Group enabled but the CLI missing is **blocked, not skipped** — the profile said this team delegates.

## Invocation

```
node <plugin_root>/scripts/executor-orchestrator.mjs --project-root <root> --plugin-root <plugin_root> \
  --author-host claude --mode read|write --prompt-file <file> [--scope <path>]... [--schema <file>] \
  [--effort high] [--timeout-minutes N] [--allow-dirty yes] --scratch <dir> \
  [--dry-run yes] [--technical-retry yes]
```

| Flag | Meaning |
|---|---|
| `--mode` | `write` (the child edits) or `read` (the child gives an opinion) |
| `--prompt-file` | the whole prompt, from a file — never argv |
| `--scope` | one allowed write path **per occurrence**; a positional argument is an error. Write mode only |
| `--schema` | a JSON Schema the final message must satisfy. Read mode; validated by the orchestrator *after* the run |
| `--allow-dirty yes` | admits a corrective run on a tree that already carries earlier output |
| `--scratch` | one directory per lineage: it holds the results, the run dirs and the retry budget |
| `--dry-run yes` | writes `<run>/manifest.json` and spawns nothing; leaves no result in the lineage |
| `--technical-retry yes` | spends the lineage's single retry |

`--output-schema` is never passed. The prompt asks for JSON and the orchestrator validates the final message afterwards, so `--sandbox read-only` is never traded away for structured output.

## Ceilings per call site

| Call site | Mode | Ceiling |
|---|---|---|
| `execute codex` | write | 90 min |
| `check-implementation codex` fixer | write | 60 min |
| `check-implementation` Step 1.5 cross-model review | read | 60 min |
| `orchestrate` Phase 7 step 0 | read | 60 min |
| `quick-change` Phase 2 plan review | read | 25 min |
| `architecture-review --codex` sweep | read | 60 min |

## Lifecycle per host

- **Claude Code caller:** launch with `run_in_background: true` (never a trailing `&`), first check after 6–8 min, then every 3 min with `ScheduleWakeup`. The heartbeat is `<run>/status.json` (`state`, `updated_utc`, `pid`), and the decision comes from the printed result file `<scratch>/exec-<run_id>.json` — never from a PID and never from log growth. Cancel the wake-up on every exit path.
- **Codex host:** not applicable. A Codex author is refused, so there is no lifecycle to emulate.

## What the result says

`<scratch>/exec-<run_id>.json`, typed by `schemas/executor-result.schema.json`:

| Field | Meaning |
|---|---|
| `status` | `completed` · `failed` · `skipped` |
| `execution` | `not-executed` (no confirmed model, or no exit code) · `executed-rejected` · `executed-complete` |
| `summary_line` | the one line the skill prints **verbatim** |
| `model` / `effort` | `{requested, confirmed}` — confirmed comes from the CLI's own header |
| `delta` | paths whose state changed **during this run** |
| `out_of_scope` | `delta` minus `--scope` (write mode) |
| `baseline` | `ok` · `deviation` · `precondition-failed` · `not-run`, plus the deviation lines |
| `output_file` / `output_json` | the prose report, or the schema-validated JSON |
| `lock` | the worktree lock path and whether a stale one was reclaimed |
| `technical_retry` / `technical_retry_allowed` | whether this run spent the budget, and whether one more is permitted |

**Exit code:** `0` only when `status` is `completed` **and** `baseline.status` is `ok` **and** `out_of_scope` is empty. Anything else exits `3`. The skill never has to reason about a shell exit code and a porcelain listing separately.

## Caller disposition per terminal state

The script reports; the skill decides.

| Terminal state | write mode (`execute codex`, fixer) | read mode (Step 1.5, Phase 7 step 0, `quick-change`, `architecture-review --codex`) |
|---|---|---|
| CLI absent, group enabled | blocked — STOP, report | blocked — STOP, report (the legacy "codex absent → skip" is gone: the profile said the team reviews) |
| `NOT EXECUTED` (auth, config, exit before model) | STOP after one technical retry | continue without the opinion after one technical retry; print `summary_line` verbatim in the report and mark the step `cross-model review: NOT EXECUTED` — never a pass |
| timeout, empty output + empty delta, malformed schema after retry | STOP (plan not moved) | continue without the opinion, `summary_line` verbatim, step marked accordingly (legacy fail-open retained, now visible) |
| empty output + delta | `execute`: verify the delta, no re-spawn · fixer: STOP for human inspection | n/a (a delta in read mode is a deviation) |
| baseline deviation / out of scope | STOP | STOP — the opinion is rejected, not judged |
| `completed` | verification → gates | score findings as the legacy step does |

**Never re-run the same prompt on a tree that already carries its partial output** — that double-applies edits. The orchestrator enforces it rather than trusting the reader: `technical_retry_allowed` is true only for a failure that left no delta, no baseline deviation, no timeout and no spent budget. A corrective re-spawn with a *different* prompt, a fresh snapshot and `--allow-dirty yes` is a separate, allowed thing.

## Snapshot coverage — stated, not implied

`scripts/git-baseline.mjs` hashes **tracked files, untracked non-ignored files and the sensitive subset of ignored files** (`.env*`, keys, PEMs, `user-profile.md`, and everything ignored under `.agents/` or `.claude/`), plus git metadata: HEAD, branch, stash OIDs, every ref, the index listing and the `.git/config` hash. Ordinary ignored build and cache output is **listed but not hashed** — a child overwriting `node_modules/` is not a deviation, a vanished ignored file still is.

`delta` is derived from the pair, not from a final `git status`: a file that was already dirty and that the child never touched is **not** in it; a second edit to that same file **is**. A protected-path deviation follows the same rule — pre-existing dirt under `.agents/` or `.claude/` that stays byte-identical is exempt, a further edit to it is not. A read-mode run with a non-empty `delta` is a deviation and its opinion is rejected whatever the exit code.

## Concurrency

Before it checks cleanliness or snapshots anything, the orchestrator takes an atomic lock at `git rev-parse --git-path harness-executor.lock`, keyed to the worktree and held through the child's termination and the second snapshot. A live supervisor → `failed: another executor holds <worktree>`. A dead supervisor with a live worker group → `failed: orphaned executor <pgid> still running in <worktree>`; the orchestrator never kills a group it did not start, so terminating it is the operator's call. Both gone → the lock is reclaimed and the result says so. Different worktrees stay independent.

## Prompt guardrails — the canonical block

Each caller pastes this whole and adds only its own delta: the executor adds "stay inside the plan's files and their tests"; the fixer reports each finding as `applied` / `skipped — <reason>` instead of `## Deviations`.

- Orient via the quick-mode steps of `references/orientation.md`, **packed into the prompt by the caller** — the child reads the prompt, not a path in the project. Two carve-outs: read `CLAUDE.md` in full (the "already injected" note is false for a spawned child) and skip the repo-state step (`git rev-list` is outside the allowlist). Ignore LSP / Context7 / MCP bullets wherever they appear — the plan's `file:line` references and API notes are the documentation.
- Never tick a `- [ ]` marker — they are parse anchors for `/harness:gates-verify-implementation`.
- **Git is read-only, and it is an allowlist, not a denylist:** only `git status`, `git diff`, `git log`, `git show`, `git ls-files`, `git rev-parse`, `git branch --show-current`. Everything else — add, commit, push, reset, checkout, restore, stash, clean, tag, config, update-ref, worktree, … — is forbidden.
- Never write under `.agents/`, `.claude/`, `.git/`; never touch `.env*`; never delete a file you did not create in this run.
- No documentation access (network is off). A step you cannot complete without it is stopped and listed under `## Deviations` — never guessed at.

**Supervisor re-validation is mandatory.** The child's report is data, not a verdict: the calling skill re-runs the validation commands and the gates itself, and STOPs on any forbidden or out-of-scope change instead of reverting it. The orchestrator refuses a scope naming `.claude/`, `.agents/`, `.git/` or `.env*` before it spawns anything, so the sandbox is never the only thing standing in the way.
