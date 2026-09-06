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

## Remaining gaps (recorded, not hidden)

- Codex: no permission tiers (`.claude/settings.json` denies have no equivalent — reported as unsupported); subagents share the parent session id (memory guard blocks until an executor id or a session-scope decision); no structured Read/Grep/WebFetch events (read telemetry covers shell reads only; no fetch audit; LSP hint legacy-only); plugin hooks run only after the operator trusts them (`/hooks`).
- Codex: `workspace-write` refuses writes under `.agents/` unless `sandbox_workspace_write.writable_roots` lists the project's `.agents` (user config, or a trusted project `.codex/config.toml`); Codex plugin hooks load only after the operator's interactive `/hooks` trust — the live smoke proves firing with the documented automation bypass and records trust separately (`--codex-hooks-trusted yes` after `/hooks`).
- Both hosts: the shell-target parser understands `git -C` and a leading `cd` only; a chained `git add && git commit` is blocked by design; a cooperative reviewer that never attempts the canary yields "no leak observed", not an observed denial.
- The whole execution/Git/QA command fleet stays legacy-only and unchanged.
