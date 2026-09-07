# Harness plugin — capability matrix (0.1.0, planning/review + guard portability)

> Honest per-host state of the harness plugin (remediation tasks T01–T17 completed 2026-09-06). Vocabulary: **implemented** — code + offline tests exist; **verified** — an installed-host run observed it in `release-readiness.json`; **conditional / dormant** — applies only under the named precondition or configuration; **legacy-only** — still served by the project's `.claude/` files, not by the plugin; **blocked** — waiting on an operator step; **retired** — dropped with a recorded decision.
>
> **Live evidence (2026-09-06).** Eleven installed-host runs on both CLIs (history under `history/`; current `release-readiness.json` = run 10, 79 rows passed). Claude Code: every row passed. Codex: every row passed except `$prime` in an empty repository, which is no longer asserted (host-dependent skill discovery, recorded below). Run 11 was aborted by the Codex account's usage limit and is kept in history for the record. **Live evidence is a report, never a gate** — build, export, bundle check and installation do not depend on it.
>
> Hook parity is implemented and verified on both hosts (25/25 hook scenarios across hosts), but **not activated in any real project**: the legacy `.claude/` hooks stay registered until an explicit activation per `installation.md`.

Ledgers (authoritative, rendered from JSON): [instruction-parity.md](instruction-parity.md) · [hook-parity.md](hook-parity.md) · hook scenarios `harness-source/contracts/hook-scenarios.json`. Build identity: `packages/<host>/harness-build.json`; bundle identity: `harness-release.json`.

## Procedures

| Capability | Claude Code | Codex CLI | State | Check |
|---|---|---|---|---|
| `prime` — rules authority (brownfield `CLAUDE.md` vs greenfield shared rules), binding, readiness, facts-only report | plugin | plugin | verified (runs 5–8, both hosts; same-payload alternate root accepted) | `rules.test.mjs`, `bootstrap.test.mjs`; live `*:cold-prime`, `*:prime-empty-project-not-ready`, `*:prime-brownfield-authority` |
| `setup-start` — interview incl. explicit review choice, atomic JSON profile writes, rules rendering, memory seed, binding, dependency preflight | plugin | plugin | implemented | `profile-cli.test.mjs`, `rules.test.mjs`, `bootstrap.test.mjs`, `hook-preflight.test.mjs` |
| `brainstorm` — spec Draft → closed-context review → single approval stamped into the spec → optional continuation | plugin | plugin | verified (run 5; continuation/opt-out on Codex verified by receipt replay after assertion fix) | `approval.test.mjs`; live `*:brainstorm-no-approval-no-plan`, `*:approval-roundtrip`, `*:continuation-gated-by-approval`, `*:review-opt-out-visible`, `*:review-required-missing-cli-blocks` |
| `plan-feature` — approval-stamp verification, backlog WIP/Ref write-back, architecture/UI contracts, EXPECT/VALIDATE, explicit `medium` | plugin | plugin | verified (run 5 plans on both hosts; mutation refused; assertion replay for the keyword format) | `planning-flow.test.mjs`, `skills.test.mjs`; live `*:plan-feature-writes-plan-no-execute`, `*:post-approval-mutation-refused` |
| `handoff` — project-local handoff document | plugin | plugin | implemented | `skills.test.mjs` |

## Rules and memory

| Capability | Claude Code | Codex CLI | State |
|---|---|---|---|
| Brownfield: populated `CLAUDE.md` stays the single authority; `AGENTS.md` loads it; no competing seed | kept | via `AGENTS.md` | implemented |
| Greenfield: shared `.agents/project-rules.md` + compatibility `CLAUDE.md` satisfying the legacy tier-1/tier-2 heading contract | rendered | rendered | implemented |
| Publish intent derived from the profile (`push` only direct-to-trunk; PR-gated → `branch-local`) | rendered | rendered | implemented |
| Memory layer seeded absent-only (routing, reflection, empty placeholders) on a bare repository | seeded | seeded | implemented |
| Loader / Output-Discipline / File-Status conventions, archive never auto-loaded | seeded index | seeded index | implemented |
| Author's local `user-profile.md` honored; never exported to a reviewer | prime + pack | prime + pack | implemented |

## Review

| Capability | Claude Code (author) | Codex CLI (author) | State |
|---|---|---|---|
| Independent review by the other host's model, effort pinned, identity confirmed | Codex `gpt-6-astra`/high | Claude `fable`/high | verified (both directions, runs 4–5); Claude CLI does not confirm effort (optional assertion, known limit) |
| Context pack: normalized paths, every artifact present, explicit read-set, typed omissions, identity bound to bytes, outbound manifest | both | both | implemented |
| Judge outside the model: contradictory `ship`, unknown `evidence_read`, CLI error envelope, tool/subagent/denied activity → never `completed`; typed `missing_context` | both | both | implemented |
| Rounds ledger: first opinion required by default, repeat only for material change, max three, technical retry separate, no run while a child is alive | both | both | implemented |
| Reviewer isolation: declared flags checked, canary at the effective path, tool surface recorded, permissive adapter fails the probe | probe | probe | verified (probe run 1 both hosts; Codex re-probe 2026-09-06 after the capacity error) — `reviewer-capabilities.json` predates the last adapter edits, so `preflight --verify-capabilities` reports a stale digest until re-run |
| Explicit review opt-out (`groups.review=false`) visible; enabled review with a missing CLI **blocks** | both | both | verified (run 5) |

## Hooks — shared core + host adapters (verified on both installed hosts, not activated in any real project)

Per-hook detail: [hook-parity.md](hook-parity.md). Summary:

| Hook | Claude Code | Codex CLI | Notes |
|---|---|---|---|
| guard-commit, guard-push (synchronous deny) | verified | verified | Codex payload shape covered (`Bash`); without git the guard blocks instead of passing (deliberate strengthening, recorded) |
| guard-memory (synchronous deny, per author context) | verified (child = `agent_id`) | conditional, verified with the untrusted state — a subagent shares the parent id; blocks until `HARNESS_EXECUTOR_ID` or a recorded `codex_child_identity: session` decision | markers under `.agents/harness-state/`, never `/tmp` |
| guard-comments, nudge-files, guard-memory-scope (advisory) | verified | verified — `apply_patch` parsed per file | never block |
| track-memory-read, audit-append (telemetry) | verified | conditional, verified — shell reads only, no fetch audit | legacy `.claude/` sidecars kept while that directory exists |
| nudge-lsp | conditional (declared LSP), verified | legacy-only, verified as `unsupported` | not "ported by renaming" |
| check-deps | verified | verified | delegates to the project-owned `check-project-deps.sh` unchanged |
| Native manifests `hooks/hooks.json` | packaged (`${CLAUDE_PLUGIN_ROOT}`) | packaged (`${PLUGIN_ROOT}`, the documented variable); every command executed offline against the built package | required guards block (exit 2) when the plugin-root variable is absent instead of vanishing; activation = one owner per hook, recorded only after a verified replacement |

## Permissions and installation

| Capability | Claude Code | Codex CLI | State |
|---|---|---|---|
| Git / WebFetch / curl / `.env` permission tiers | `.claude/settings.json` (project-owned) | **none** — reported as unsupported, never copied; sandbox + `approval_policy` are the host controls | legacy-only / recorded gap |
| Portable `harness-version.json` + local `harness-state/` binding; schema-1 receipts migrated with consent | implemented | implemented | `binding-portability.test.mjs` |
| Profile-aware, migration-aware settings/MCP unions; activation preview; rollback restores ownership; legacy-only downstream sync | implemented | implemented | `migration.test.mjs`, `permissions.test.mjs` |
| Deterministic packages, marker with hook targets, package validation (paths, hook targets, no private data) | built | built | `packaging.test.mjs`, `smoke --offline` |
| execute / check-implementation / gates / commit / push / orchestrate / PR / Jira / Confluence / QA | legacy only | not available | deferred, unchanged |

## Known limits recorded so far

- Claude Code's JSON output confirms the model but not the effort level; the adapter pins `--effort high` and records confirmation as `null` rather than guessing (no assertion depends on it).
- Claude Code bills a small helper model alongside the reviewer; the adapter names the model with the most output tokens as the reviewer and records all billed models.
- Codex `exec --json` events carry no model name on 0.153.4; the adapter reads the CLI's own header (`model:`, `reasoning effort:`, `sandbox:`, `approval:`).
- A cooperative reviewer that never *tries* to read the canary yields "no leak observed", not "denial observed"; the probe labels the isolation evidence accordingly and asserts only that no leak happened.
- Codex skill discovery in a bare repository is not deterministic: runs 6, 10 and 11 saw `$prime` unresolved (the model searched `~/.codex/skills`), run 8 resolved it from the installed plugin with the same bytes. If `$prime` is not found, run the installed `skills/prime/SKILL.md` by path once; the rendered rules point at the plugin afterwards. The live smoke applies the same fallback and records which path was taken.
- A Codex usage-limit exhaustion mid-run fails every Codex call with exit 1 and a quota message (run 11); the evidence file records it as observed.
- Codex's `workspace-write` sandbox protects `.agents/`; a Codex author needs `sandbox_workspace_write.writable_roots` to include the project's `.agents` (observed 2026-09-06 — the live smoke passes it per call; real projects configure it once).
- Codex rejects any top-level field in `hooks/hooks.json` other than `description` and `hooks` (observed 2026-09-06); both manifests carry only those.
- Admin-managed policy of either CLI stays in force and is reported as external policy context; the adapters do not and cannot disable it.
- The shell-target parser of the commit/push guards understands `git -C <dir>` and a leading `cd <dir> &&` only; a chained `git add … && git commit` is blocked by design.
- Claude Code runs a plugin installed from a **local-path marketplace from the marketplace source directory** (`CLAUDE_PLUGIN_ROOT`), while `installed_plugins.json` names the cache copy (observed 2026-09-06, run 4). The binding therefore identifies a release by payload digest; the same payload from another directory is reported as `alternate_root`, a different payload is refused.
- Codex plugin hooks need the operator's interactive `/hooks` trust once per machine; the smoke records it via `--codex-hooks-trusted yes` (trusted on this machine 2026-09-06).
- The `WHY-GATE` holds in non-interactive runs: a brainstorm input without a *why* ends with the question, not a spec — the live fixture prompts carry one.
