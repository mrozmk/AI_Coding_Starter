# Harness plugin — installation and release runbook (0.1.0)

> Operator document for the AI Coding Starter release bundle. The packaged, version-pinned copy of the same procedure ships inside both plugins as `references/installation.md` (install, bind, activation, update, rollback, migration record); this file adds the release-engineering steps and the current status. Every command below is a human action.

## Status — read this first

- **Version 0.1.0** (`harness-source/harness.json`). Identity of any build is its `harness-build.json` (source + payload digests); a bundle's `harness-release.json` repeats them and says whether the live evidence on disk describes these bytes (`evidence_current`). Evidence for other bytes is not shipped.
- **Live evidence is a report, not a gate.** `docs/harness/release-readiness.json` records what an installed-host run observed on both CLIs — nothing in the build, export, bundle check or installation requires any row of it to pass. Read it to know how the hosts behaved; decide for yourself what matters for your project. History of earlier runs: `history/`.
- **Current evidence (run 10, 2026-09-06, 79 rows passed).** Claude Code: every row passed, including plugin hooks firing in a real session, review by Codex, planning skills, guards. Codex: every row passed except `$prime` in an empty repository (not asserted any more — plugin skill discovery in a bare repository is host-dependent; see Remaining gaps). Reviewer isolation probe (`reviewer-capabilities.json`) predates the last adapter edits and is reported as stale by `preflight --verify-capabilities`; its isolation rows are re-observed in every live run's `denial:*` rows.
- **Hooks are not activated in any real project** — the legacy `.claude/` hooks stay registered until an explicit activation per `references/installation.md`.

## What you get

Two natively installable plugins built from one source (`harness-source/`): `packages/claude` (`.claude-plugin/plugin.json`) and `packages/codex` (`.codex-plugin/plugin.json`). Both carry the five skills — `prime`, `brainstorm`, `plan-feature`, `setup-start`, `handoff` — the shared references, templates (rules + memory seed), contracts (parity ledgers, hook scenarios), schemas, scripts (profile, approval, rules, bootstrap, backlog, context-pack, review orchestrator/result, preflight, hook-runner), both reviewer adapters, both hook adapters with a native `hooks/hooks.json`, the shared hook cores under `hooks/core/`, and `harness-build.json` (build marker: source digest, payload digest, skill and hook targets, file list). Marketplaces: `.claude-plugin/marketplace.json` and `.agents/plugins/marketplace.json`, both named `ai-coding-starter`, both pointing at `./packages/<host>`.

Runtime: Node ≥ 22 (tested 24.10.0), Claude Code 2.1.257 and Codex CLI 0.153.4 (the versions the live run must record), Git. Legacy `.claude/` Bash hooks keep their `jq` requirement; the ported Node hooks need none.

## Produce and verify a build (release engineer)

```bash
node scripts/check-harness.mjs --all                         # syntax, inventory, links, contracts (parity ledgers), tests, generated drift
node scripts/smoke-harness.mjs --offline                     # package bytes, marketplaces, namespaces, installed-copy scripts and hook runner, locator
node scripts/build-harness.mjs --parity-docs                 # docs/harness/{instruction,hook}-parity.md from the ledgers
```

Any source change changes `source_digest`; every earlier live evidence is then invalid for the new bytes by construction (`--verify-evidence` compares digests).

## Installed-host validation — live smoke (operator-run report; eleven runs recorded, see Status)

Requires separate authorization for: creating synthetic workspaces under `$TMPDIR`, adding a local marketplace and installing the plugin in both CLIs (`--scope local` on Claude Code; user-level on Codex), trusting the plugin hooks in each host, and live model calls (both reviewers, both authors). Nothing here touches a real project.

```bash
node scripts/build-harness.mjs --export dist/harness-0.1.0   # ships live evidence only when it names these bytes
node scripts/check-harness.mjs --bundle dist/harness-0.1.0
# 1. reviewer probe (archive the old evidence first — never overwrite in place)
mkdir -p docs/harness/history/0.1.0-<date> && git mv docs/harness/reviewer-capabilities.json docs/harness/reviewer-capabilities.md docs/harness/history/0.1.0-<date>/
node harness-source/scripts/preflight.mjs --live-reviewer-probe --evidence-out docs/harness/reviewer-capabilities.json --receipts-dir <local dir>
# 2. installed-host smoke (seven fixtures: empty, no-profile, legacy-profile, brownfield, different-rules, review-opt-out, review-required-missing-cli)
node scripts/smoke-harness.mjs --live --bundle dist/harness-0.1.0 [--install] [--claude-root <root>] [--codex-root <root>] --receipts-dir <local dir>
node scripts/smoke-harness.mjs --verify-evidence docs/harness/release-readiness.json --receipts <local dir>
```

What the live run records per host (the full list is `liveAssertionNames` in `scripts/lib/smoke-live.mjs`): cold prime; prime on an empty repository reporting *not ready* (Claude only); prime on a brownfield project naming `CLAUDE.md` as authority; brainstorm with `stop` producing no approval and no plan; approval receipt round-trip through `approval.mjs`; plan-feature writing a plan and executing nothing; plan-feature refusing a spec edited after approval; the profile's continuation never firing without the user's approval; the review opt-out visible; review enabled with the other CLI missing **blocking**; a review in each direction with confirmed model; hooks trusted (operator acknowledgement) and hooks fired by a real host session; every scenario in `contracts/hook-scenarios.json` through the installed runner; the reviewer isolation probe from the installed adapters. Actual CLI versions and requested/confirmed model/effort are recorded as observed. A failed row is information about the host on that day, not a verdict on the release — read the receipt, decide, and re-run only when you want fresh evidence. Stop at any missing authority, login, trust or network and report the exact human step; never widen a permission to pass.

## Install (both hosts)

Follow `packages/<host>/references/installation.md → Install from a release bundle`: add the bundle as a marketplace, install `harness@ai-coding-starter`, bind each installed root with `node <installed root>/scripts/profile.mjs bind …`, run `prime`. Login and trust prompts are yours; the harness never touches accounts or global settings. Binding writes the portable `.agents/harness-version.json` (commit it) and the local `.agents/harness-state/` (gitignored); every machine binds itself. Installing activates no hook.

## Activation, update, rollback

See the packaged `references/installation.md`: **Activation** (one owner per command and hook, `sync-filter.mjs activation` preview, `recordMigration` only after the installed-host scenario for that hook passed and the legacy entry was removed), **Portable version vs local binding**, **Update** (finish running sessions, re-bind after any version change), **Rollback** (restores ownership via the migration record; never a cache purge; project artifacts untouched), **Legacy-only downstream sync** (works without a plugin).

## Migrate 0.3.0 → 0.4.0 (downstream, by hand)

0.4.0 moves the product, QA, session-peripheral and Atlassian slice into the plugin. Nothing below happens automatically: a plugin release never edits a project's files, profile or migration record.

**1. Delete the seven files the plugin now owns**, and record each in `.claude/.starter-sync.json → migrated` with `deleted: true` (schema: packaged `references/installation.md → Migration record`), so sync never re-offers them:

| Delete | Replaced by |
|---|---|
| `.claude/lib/qa-probe.sh` | `scripts/qa-probe.mjs` in the plugin |
| `.claude/agents/qa-contract.md` | the registered `harness:qa-contract` |
| `.claude/agents/qa-runtime-ui.md` | the registered `harness:qa-runtime-ui` |
| `.claude/agents/qa-runtime-app.md.example` | the `templates/agents/qa-runtime-app.md` template |
| `.claude/agents/qa-runtime-device.md.example` | the `templates/agents/qa-runtime-device.md` template |
| `.claude/skills/jira/` (with its `references/`) | `harness:jira` + `references/jira/` |
| `.claude/skills/confluence/` | `harness:confluence` |

Also drop `"Bash(bash .claude/lib/qa-probe.sh)"` from `.claude/settings.json → permissions.allow` and record it in `migrated_config` as `permissions.allow|Bash(bash .claude/lib/qa-probe.sh)`. The plugin's scripts already run under the machine-local plugin-script allowance. **Keep `.claude/skills/pr-comments/` and its `pr-api.sh` allowance** — they are unchanged.

**2. Adopt the nine new wrappers** — `node <installed root>/scripts/bootstrap.mjs wrappers --project-root <dir> --plugin-root <installed root>` previews, `--consent yes` writes. Four are nested (`.claude/commands/setup/{create-PRD,create-backlog,stack-research}.md`, `.claude/commands/maintain/refresh-brief.md`); the rest are flat (`prime-ba`, `prime-qa`, `qa-verify`, `retro`, `simply`). Each replaces the legacy command body with a wrapper, so record those nine paths in `migrated` too (`deleted: false` — the file stays, its content is now generated). `.claude/commands/setup/start.md` and `.claude/commands/gates/` are deliberately **not** wrapper-eligible and must stay untouched. `jira` and `confluence` get no wrapper: invoke them as `/harness:jira` / `/harness:confluence`.

**3. Set the two new group flags** in `.agents/project-profile.json → groups`: `product` (`true` unless you keep the legacy PRD/brief/backlog commands) and `qa` (`true` only if this project verifies acceptance criteria). Both default to `false` for a profile written before 0.4.0, so an un-edited profile keeps the legacy behaviour and every new entrypoint reports the disabled group rather than silently doing nothing.

**4. Replace the three citations in your own rules file** — `CLAUDE.md`, or `.agents/project-rules.md` on a greenfield project. These are human-owned; the harness does not rewrite them, and left alone they become dead links:

| Replace | With |
|---|---|
| `.agents/reference/runtime-smoke.md` | the harness reference `runtime-smoke.md` |
| `.agents/reference/parallel-orchestration.md` | the harness reference `parallel-orchestration.md` |
| `.agents/reference/qa-to-regression-test.md` | the harness reference `qa-to-regression-test.md` |

`.agents/reference/jira-mcp-atlassian.md` moved into the plugin as well — delete your copy or leave it; nothing reads it any more.

**5. Split your QA evidence registry.** `.agents/reference/qa-evidence-families.md` becomes the **project overlay only**: keep §1a, §2 and §5, delete §1, §3, §4 and §6 (they now ship as the plugin's `references/qa-evidence-families.md` and are replaced on upgrade). A project that has no such file gets a seeded overlay from `bootstrap.mjs seed` — absent-only, never overwriting yours. **The roster-completeness rule no longer has a sync step behind it:** `qa-verify` routes any family with no §2 row to `NEEDS-HUMAN` naming the missing row, so an overlay you never fill in degrades loudly instead of silently.

## Remaining gaps (recorded, not hidden)

- Codex: no permission tiers (`.claude/settings.json` denies have no equivalent — reported as unsupported); subagents share the parent session id (memory guard blocks until an executor id or a session-scope decision); no structured Read/Grep/WebFetch events (read telemetry covers shell reads only; no fetch audit; LSP hint legacy-only); plugin hooks run only after the operator trusts them (`/hooks`).
- Codex: `workspace-write` refuses writes under `.agents/` unless `sandbox_workspace_write.writable_roots` lists the project's `.agents` (user config, or a trusted project `.codex/config.toml`); Codex plugin hooks load only after the operator's interactive `/hooks` trust — the live smoke proves firing with the documented automation bypass and records trust separately (`--codex-hooks-trusted yes` after `/hooks`).
- Both hosts: the shell-target parser understands `git -C` and a leading `cd` only; a chained `git add && git commit` is blocked by design; a cooperative reviewer that never attempts the canary yields "no leak observed", not an observed denial.
- Legacy-only after 0.4.0: `setup/start` (its bootstrap-only steps), `setup/create-CLAUDE_MD`, `setup/map-codebase`, `setup/createwikillm`, `maintain/cleanup-workflow`, `maintain/sync-from-starter`, and the `pr-comments` skill. Every other command in this repository's `.claude/` is now a generated wrapper over a plugin skill.
