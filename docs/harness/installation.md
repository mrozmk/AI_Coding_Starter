# Harness plugin — installation and release runbook (candidate 0.1.0)

> Operator document for the AI Coding Starter release bundle. The packaged, version-pinned copy of the same procedure ships inside both plugins as `references/installation.md` (install, bind, activation, update, rollback, migration record); this file adds the release-engineering steps and the current status. Every command below is a human action.

## Status — read this first

- **Candidate frozen:** `release-candidate.json` records the version and the exact source/payload digests a live run must match.
- **Installed-host validation (T16) ran five times on both CLIs** (2026-09-05/06; `history/*-live-run*`, current `release-readiness.json` = run 5). Procedures, review in both directions and all 24 hook scenarios passed on both hosts; Codex hooks trusted via `/hooks`. The remaining five required `fail` rows of run 5 were assessed on receipts as over-literal assertions (since corrected and replayed green on the same receipts) plus one transient provider error (re-probed green, `history/0.1.0-2026-09-06-probe-run2-codex/`). The operator closed T16 on that basis without a sixth run — see `capabilities.md` → T16 status.
- **Consequence:** the evidence file predates the assertion fixes, so `build-harness.mjs --export` without `--candidate` refuses (stale `source_digest`, one required `fail`). The shipped bundle is a **candidate**; a tested release needs one full run on the current bytes. The plugin is *planning + review + guard portability verified*, **hooks not activated in any real project** — do not migrate a real project, the legacy `.claude/` hooks stay registered.
- **Reviewer capability evidence:** `reviewer-capabilities.json` was recorded against earlier adapter bytes (`preflight --verify-capabilities` reports a stale digest); the isolation assertions were re-proven for Codex on 2026-09-06 and for both hosts in every live run's `denial:*` rows.

## What you get

Two natively installable plugins built from one source (`harness-source/`): `packages/claude` (`.claude-plugin/plugin.json`) and `packages/codex` (`.codex-plugin/plugin.json`). Both carry the five skills — `prime`, `brainstorm`, `plan-feature`, `setup-start`, `handoff` — the shared references, templates (rules + memory seed), contracts (parity ledgers, hook scenarios), schemas, scripts (profile, approval, rules, bootstrap, backlog, context-pack, review orchestrator/result, preflight, hook-runner), both reviewer adapters, both hook adapters with a native `hooks/hooks.json`, the shared hook cores under `hooks/core/`, and `harness-build.json` (build marker: source digest, payload digest, skill and hook targets, file list). Marketplaces: `.claude-plugin/marketplace.json` and `.agents/plugins/marketplace.json`, both named `ai-coding-starter`, both pointing at `./packages/<host>`.

Runtime: Node ≥ 22 (tested 24.10.0), Claude Code 2.1.257 and Codex CLI 0.153.4 (the versions the live run must record), Git. Legacy `.claude/` Bash hooks keep their `jq` requirement; the ported Node hooks need none.

## Produce and verify the candidate (release engineer)

```bash
node scripts/check-harness.mjs --all                         # syntax, inventory, links, contracts (parity ledgers), tests, generated drift
node scripts/smoke-harness.mjs --offline                     # package bytes, marketplaces, namespaces, installed-copy scripts and hook runner, locator
node scripts/build-harness.mjs --parity-docs                 # docs/harness/{instruction,hook}-parity.md from the ledgers
node scripts/build-harness.mjs --freeze                      # docs/harness/release-candidate.json — identities T16 must match
```

Any source change after the freeze changes `source_digest`; re-freeze and treat every earlier live evidence as invalid for the new bytes.

## Installed-host validation — T16 (operator gate; five runs recorded, see Status)

Requires separate authorization for: creating synthetic workspaces under `$TMPDIR`, adding a local marketplace and installing the plugin in both CLIs (`--scope local` on Claude Code; user-level on Codex), trusting the plugin hooks in each host, and live model calls (both reviewers, both authors). Nothing here touches a real project.

```bash
node scripts/build-harness.mjs --export dist/harness-0.1.0
node scripts/check-harness.mjs --bundle dist/harness-0.1.0
# 1. reviewer probe (archive the old evidence first — never overwrite in place)
mkdir -p docs/harness/history/0.1.0-<date> && git mv docs/harness/reviewer-capabilities.json docs/harness/reviewer-capabilities.md docs/harness/history/0.1.0-<date>/
node harness-source/scripts/preflight.mjs --live-reviewer-probe --evidence-out docs/harness/reviewer-capabilities.json --receipts-dir <local dir>
# 2. installed-host smoke (seven fixtures: empty, no-profile, legacy-profile, brownfield, different-rules, review-opt-out, review-required-missing-cli)
node scripts/smoke-harness.mjs --live --bundle dist/harness-0.1.0 [--install] [--claude-root <root>] [--codex-root <root>] --receipts-dir <local dir>
node scripts/smoke-harness.mjs --verify-evidence docs/harness/release-readiness.json --receipts <local dir>
```

What the live run must observe per host (the full list is `requiredLiveAssertions` in `scripts/lib/smoke-live.mjs`): cold prime; prime on an empty repository reporting *not ready*; prime on a brownfield project naming `CLAUDE.md` as authority; brainstorm with `stop` producing no approval and no plan; approval receipt round-trip through `approval.mjs`; plan-feature writing a plan and executing nothing; plan-feature refusing a spec edited after approval; the profile's continuation never fires without the user's approval (automatic continuation after an interactive approval is not provable non-interactively and is not claimed); the review opt-out visible; review enabled with the other CLI missing **blocking**; a review in each direction with confirmed model; **hooks trusted** (operator acknowledgement) and **hooks fired** by a real host session; every scenario in `contracts/hook-scenarios.json` through the installed runner; the reviewer denial probe from the installed adapters. Record actual CLI versions and requested/confirmed model/effort honestly. A required failure means the release is not ready; fix and re-run the whole live suite. Stop at any missing authority, login, trust or network and report the exact human step; never widen a permission to pass.

## Install (both hosts)

Follow `packages/<host>/references/installation.md → Install from a release bundle`: add the bundle as a marketplace, install `harness@ai-coding-starter`, bind each installed root with `node <installed root>/scripts/profile.mjs bind …`, run `prime`. Login and trust prompts are yours; the harness never touches accounts or global settings. Binding writes the portable `.agents/harness-version.json` (commit it) and the local `.agents/harness-state/` (gitignored); every machine binds itself. Installing activates no hook.

## Activation, update, rollback

See the packaged `references/installation.md`: **Activation** (one owner per command and hook, `sync-filter.mjs activation` preview, `recordMigration` only after the installed-host scenario for that hook passed and the legacy entry was removed), **Portable version vs local binding**, **Update** (finish running sessions, re-bind after any version change), **Rollback** (restores ownership via the migration record; never a cache purge; project artifacts untouched), **Legacy-only downstream sync** (works without a plugin).

## Remaining gaps (recorded, not hidden)

- Codex: no permission tiers (`.claude/settings.json` denies have no equivalent — reported as unsupported); subagents share the parent session id (memory guard blocks until an executor id or a session-scope decision); no structured Read/Grep/WebFetch events (read telemetry covers shell reads only; no fetch audit; LSP hint legacy-only); plugin hooks run only after the operator trusts them (`/hooks`).
- Codex: `workspace-write` refuses writes under `.agents/` unless `sandbox_workspace_write.writable_roots` lists the project's `.agents` (user config, or a trusted project `.codex/config.toml`); Codex plugin hooks load only after the operator's interactive `/hooks` trust — the live smoke proves firing with the documented automation bypass and records trust separately (`--codex-hooks-trusted yes` after `/hooks`).
- Both hosts: the shell-target parser understands `git -C` and a leading `cd` only; a chained `git add && git commit` is blocked by design; a cooperative reviewer that never attempts the canary yields "no leak observed", not an observed denial.
- The whole execution/Git/QA command fleet stays legacy-only and unchanged.
