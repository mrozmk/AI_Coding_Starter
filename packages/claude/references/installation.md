# Installation, update, rollback — and the migration record

Operator runbook for the `harness` plugin (planning/review release). Every command here is a human action; no skill runs them.

## Prerequisites

Node ≥ 22 (tested 24.10.0) · Claude Code CLI (tested 2.1.257) and/or Codex CLI (tested 0.153.4), each logged in (`claude auth status`, `codex login status`) · Git for provenance. The second CLI is needed only when independent review is enabled (it always is by default).

## Install from the release channel

The marketplace is the starter repository on its `release` branch (`harness.json → marketplace_source` + `release_ref`); `main` is the working branch and is never a channel. Claude Code refreshes a git marketplace at session start when auto-update is on for it (`/plugin → Marketplaces`), and adopts a new plugin only when `version` changed.

```bash
# Claude Code — project scope keeps the install out of user settings
claude plugin marketplace add mrozmk/AI_Coding_Starter@release
claude plugin install harness@ai-coding-starter --scope project
claude plugin list --json          # installPath = the installed root to bind

# Codex CLI
codex plugin marketplace add mrozmk/AI_Coding_Starter --ref release
codex plugin add harness@ai-coding-starter --json   # the JSON names the installed root
```

A release bundle (`dist/harness-<version>/`, both packages, both marketplace manifests, `harness-release.json`, evidence) still installs the same way from a directory path; a directory marketplace never auto-updates.

Then bind each installed root to the project (verifies marker, payload digest, skill paths; writes `.agents/harness-version.json`):

```bash
node <installed root>/scripts/profile.mjs bind --project-root <project> --host claude --plugin-root <installed root>
node <installed root>/scripts/profile.mjs bind --project-root <project> --host codex  --plugin-root <installed root>
```

Run `prime` in each host; it must report `harness <version> bound`. A `--plugin-dir` / local source-directory session is fine for development but is not an installation and does not satisfy the binding.

## Codex: writable `.agents/`

**Codex sandbox and `.agents/`.** Codex's `workspace-write` sandbox refuses writes under `.agents/` (it keeps its own marketplace config there), and the harness stores specs, plans, memory and the version receipt exactly there. A Codex author session needs `sandbox_workspace_write.writable_roots` to include the project's `.agents` directory — in `~/.codex/config.toml` (absolute path) or in a **trusted** project `.codex/config.toml` (a project-level file is ignored until the project is trusted; observed 2026-09-06 on Codex 0.153.4). Without it every planning skill reports the write as blocked; nothing is written elsewhere.

## Verify

```bash
node scripts/check-harness.mjs --bundle dist/harness-<version>          # bundle contract
node harness-source/scripts/preflight.mjs --verify-capabilities docs/harness/reviewer-capabilities.json
node scripts/smoke-harness.mjs --verify-evidence docs/harness/release-readiness.json
```

## Portable version vs local binding

`.agents/harness-version.json` (committed, schema 2) carries only the identity the project expects per host: `name`, `version`, `source_digest`, `payload_digest`. `.agents/harness-state/` (gitignored by its own `.gitignore`) carries this machine's facts: the installed root, `bound_at`, the machine name, and operator acknowledgements (hook trust, probes). A cloned repository therefore knows *which* release it expects and refuses to run planning until `profile.mjs bind` is run on that machine; a copied receipt is not an installation. A schema-1 receipt (root and timestamp inside the committed file) still resolves where its root verifies; `node <installed root>/scripts/profile.mjs migrate-binding --project-root <project> --consent yes` splits it — another machine's absolute root is never adopted.

## Activation — one owner per command and hook

Installing the plugin activates nothing in a project. Legacy `.claude/commands/*.md` and the Bash hooks in `.claude/settings.json` keep running until the operator records their replacement. The exception is a **wrapper**: `setup-start` copies `templates/wrappers/*.md` over the legacy top-level command files so the bare command routes to the plugin skill — those stay ordinary starter files (sync category A), never `migrated` records. The preview is computed, never applied:

```bash
node <installed root>/scripts/sync-filter.mjs activation --manifest .claude/.starter-sync.json \
  --settings .claude/settings.json --plugin-hooks <installed root>/hooks/hooks.json --release <version>
```

It lists every hook id with its owner after activation (`legacy`, `plugin`, or `duplicate` — two owners, a decision required), the exact `settings.json` identities the plugin would replace, the project-owned entries that never migrate (`check-project-deps`), and the rollback data. Activation of a hook id means: the plugin's hooks are trusted on this host (`/hooks` in Codex; plugin enable in Claude Code — recorded locally by `acknowledgeHooks`), the installed-host scenario for that hook passed, the legacy entry is removed from `settings.json`, and only then `recordMigration` adds the `migrated_config` record with the evidence name. A duplicate owner is a mistake, not a transition state. Codex advisory nudges and Claude-only events (Grep, WebFetch) stay legacy-only where the ledger says so (`contracts/hook-parity.json`).

## Publish (starter maintainer)

The plugin is developed in a separate private repository (Harness-Dev); the template repository's `main` carries the template only. The publisher lives in Harness-Dev and takes the template checkout as `--template-root <dir>` (default `../AI_Coding_Starter`, env `HARNESS_TEMPLATE_ROOT`): `node scripts/release-harness.mjs --template-root <dir>` after the version bump refuses a template that is not on `main` or not clean, a local `release` that disagrees with `origin/release`, a version not newer than the one published on `origin/release`, a failing `check-harness --all` / `smoke-harness --offline`, or a dirty Harness-Dev tree. It then snapshots the template's `main` plus the build output (`packages/`, both marketplace manifests) into one commit on `release` — `release(harness): <version> from main@<sha>` — made in a temporary worktree under the template's `.git/harness-publish/`, and pushes **only** `release` with `--push yes` (without it, the exact push command is printed). The template's `main` is pushed by the maintainer, by hand, after the installed-host proof; no script pushes it and nothing is ever forced.

## Update (project)

1. Claude Code with auto-update: the new version arrives at the next session start; `prime` then reports `harness <new> installed, project pinned to <old>` with the exact bind command. Without auto-update: `claude plugin marketplace update ai-coding-starter` + `claude plugin update harness@ai-coding-starter`. Codex: `codex plugin marketplace upgrade` + `codex plugin add harness@ai-coding-starter --json`.
2. Finish or stop running sessions — never switch versions under a live executor.
3. Adopt deliberately: re-bind (`profile.mjs bind`) for each host; the old binding is invalid by design, and `prime` never binds on its own — the committed receipt is the project's pin, not a per-machine side effect.
3b. Claude Code: `node <installed root>/scripts/bootstrap.mjs wrappers --project-root <project> --plugin-root <installed root>` previews the project wrappers the version adds or changes; `--consent yes` writes them. Re-binding alone never touches `.claude/commands/`.
4. Nothing in the project (profile, plans, specs, memory, rules) is changed by an update. Version changes are a deliberate act.

## Migrating a 0.2.0 project to 0.3.0

0.3.0 moves the execution stage into the plugin and retires the shell-based Codex spawner. A project on 0.2.0 does these once, in order; every step is a deliberate act, nothing runs on update.

1. **Update and re-bind** per *Update (project)* above, both hosts. Then `node <installed root>/scripts/bootstrap.mjs wrappers --project-root <project> --plugin-root <installed root> --consent yes` — ten new wrappers land in `.claude/commands/` (`analysis`, `architecture-review`, `check-implementation`, `deep-review`, `design`, `execute`, `orchestrate`, `quick-change`, `recon`, `test-e2e`), each replacing the legacy body of the same name. A wrapper marked `replaces_local_edit` holds project edits: diff first.
2. **Enable the group:** `node <installed root>/scripts/profile.mjs set --project-root <project> --key groups.execution --value true --consent yes`. A 0.2.0 profile keeps its explicit `false` until this is run; the migrated skills refuse until it is `true`.
3. **Delete the retired files** and record each in `.claude/.starter-sync.json → migrated` with `deleted: true`, `release: "0.3.0"` so `/maintain:sync-from-starter` never re-offers them. The list is the package marker's `retired` array (`harness-build.json`), verbatim:
   - `.claude/commands/codex-review.md`
   - `.claude/commands/gates/check-quality.md`, `.claude/commands/gates/verify-implementation.md`, `.claude/commands/gates/design-quality-check.md` — namespaced commands get no wrapper; they are invoked as `/harness:gates-check-quality`, `/harness:gates-verify-implementation`, `/harness:gates-design-quality-check`
   - `.claude/lib/codex-bg.sh`, `.claude/lib/git-baseline.sh`
   - `.claude/agents/orchestrator-committer.md`, `-designer.md`, `-executor.md`, `-executor-hard.md`, `-refiner.md`, `-verifier.md`, `.claude/agents/documentation-manager.md` — the plugin ships them as `harness:orchestrator-*` and `harness:documentation-manager`
   - `.claude/skills/design/` and `.claude/skills/architecture-review/` — packaged as `references/design/*` and `references/architecture-review/*`
   - plus two files outside `.claude/` that the marker cannot list: `.agents/reference/orientation.md` (now `references/orientation.md`, packed into every child's prompt) and `.agents/reference/codex-spawn.md` (absorbed into `references/executor-contract.md`)
4. **Drop the permission:** remove `"Bash(bash .claude/lib/git-baseline.sh:*)"` from `permissions.allow` in `.claude/settings.json` and record it in `migrated_config` as `{ "file": ".claude/settings.json", "kind": "permission", "identity": "permissions.allow|Bash(bash .claude/lib/git-baseline.sh:*)", "replaced_by": "harness", "release": "0.3.0" }`. The `git worktree` / `git merge --ff-only` allows stay — the orchestrate skill still needs them.
5. **Rewrite the `git-baseline.sh` paragraph** of the project's `CLAUDE.md` (Security → *Recorded allowance*) as the starter did: the executor runs as `node <installed root>/scripts/executor-orchestrator.mjs` under the machine-local plugin-script allowance; its only local write channels are the scratch run directory and a lock under the git dir; the write-mode child's authority is bounded after the fact by the run-relative snapshot, not prevented.
6. **Codex host:** `orchestrate`, `check-implementation`, `quick-change` and `architecture-review` refuse on Codex (no agents; host-provided `code-review`; judge ≠ fixer), `execute codex` refuses (a Codex author has no cross-model executor), `recon` and `design` run their waves sequentially. Every other migrated skill runs identically on both hosts. The ledger row per skill is in `docs/harness/instruction-parity.md`.

## Migrating 0.5.0 → 0.6.0 (downstream, by hand)

0.6.0 splits the repositories: the plugin source, its tests, the build and the publisher moved out of the template into a private development repository, and the template's `main` no longer ships the 29 generated command wrappers (`.claude/commands/<skill>.md`), `.claude-plugin/`, `.agents/plugins/marketplace.json` or any of the development apparatus. The `release` branch is now a snapshot of the template's `main` plus `packages/` and both marketplace manifests — the install commands above are unchanged. **Nothing in your project is touched by the update**; the wrappers you already have keep working exactly as before, because each one only routes to the installed plugin skill.

1. **Update and re-bind** per *Update (project)* above, both hosts.
2. **The next `sync-from-starter` offers to remove wrappers.** The template deleted them, so an unchanged wrapper in your project shows up as a safe upstream deletion. Either decline — the files are yours to keep — or list them under `.claude/.starter-sync.json → excluded` so they are never offered again. `setup-start` (Binding step) and `node <installed root>/scripts/bootstrap.mjs wrappers --consent yes` write the current wrapper set on request; the template is no longer where they come from.
3. **Before accepting any deletion, audit your `CLAUDE.md`** for links to `.claude/commands/{commit,push,pull,release,orchestrate}.md` (the starter's *Git Workflow* section carried five) and rewrite each as the skill invocation — `/harness:commit`, `/harness:push`, `/harness:pull`, `/harness:release`, `/harness:orchestrate` — first. A deletion accepted before the rewrite leaves dangling links in the rules file.
4. **Still on the 0.5.0 sync command with no plugin installed?** Its helper fallback pointed at `harness-source/scripts/sync-filter.mjs` in the starter checkout, which `main` no longer carries. Run it once as `/maintain:sync-from-starter release` — a clone of the `release` branch — and point the helper at `packages/claude/scripts/sync-filter.mjs` in that clone. The updated command names that location itself, so the detour ends with that one sync. Helper resolution order from 0.6.0 on: the installed plugin root the plugin itself resolves (`resolveBoundRoot`, the same lookup `check-version` uses) at `<root>/scripts/sync-filter.mjs`; otherwise a clone of the template's `release` branch at `packages/claude/scripts/sync-filter.mjs`.
5. **Codex** installs from a `release` clone as before (`codex plugin marketplace add … --ref release`); nothing changes for it.

## Rollback

Rollback restores **ownership**, not merely an empty plugin directory. `node <installed root>/scripts/sync-filter.mjs rollback --manifest .claude/.starter-sync.json --release <version>` names the legacy paths and `settings.json` identities that return to the project once their `migrated*` records are dropped; the next `/maintain:sync-from-starter` re-offers them. Then disable or remove the plugin (`claude plugin disable|uninstall`, `codex plugin remove`), install the previous bundle if one is wanted, re-bind. Code, specs, plans, memory, `.agents/harness-state/` telemetry and other people's work stay untouched. No `git reset --hard`, no worktree deletion, no recursive cache purge.

## Legacy-only downstream sync

A project that has not installed the plugin still syncs: `/maintain:sync-from-starter` resolves the helper first from the installed plugin root the plugin itself resolves (`resolveBoundRoot`, the same lookup `check-version` uses) at `<root>/scripts/sync-filter.mjs`; without a binding it uses a clone of the template's **`release`** branch at `packages/claude/scripts/sync-filter.mjs` (`/maintain:sync-from-starter release`), with `migrated: []` and no plugin root — `main` no longer carries the helper. The same decision tables apply; nothing requires an installation.

## Migration record — `.claude/.starter-sync.json`

When a project replaces legacy command files or configuration entries with the plugin, it records the replacement so `/maintain:sync-from-starter` never re-offers them. Field schema (additive to the existing file; unknown fields are preserved):

```json
{
  "migrated": [
    { "path": ".claude/commands/brainstorm.md", "replaced_by": "harness:brainstorm", "release": "0.1.0", "deleted": true, "date": "2026-09-05" }
  ],
  "migrated_config": [
    { "file": ".claude/settings.json", "kind": "hook", "identity": "PreToolUse|Bash|bash \"$CLAUDE_PROJECT_DIR/.claude/hooks/example.sh\"", "replaced_by": "harness", "release": "0.1.0" },
    { "file": ".mcp.json", "kind": "mcpServer", "identity": "example", "replaced_by": "harness", "release": "0.1.0" }
  ]
}
```

- `migrated[].path` — repo-relative file (directories end with `/`, prefix match). `deleted: true` means the project intentionally removed it; a 3-way comparison that sees "present in base, present upstream, absent locally" treats it as an **intentional deletion**, not staleness: no task, no re-add, no question.
- `migrated_config[].identity` — the stable identity of a configuration entry: `permissions.<tier>|<entry string>` for permission entries, `<event>|<matcher>|<command>` for hooks, `<server name>` for `.mcp.json`. Category-B unions skip these identities so a plugin-provided hook or permission is not resurrected by the file-level union.
- `excluded` (existing) keeps its meaning: paths pruned by `/setup:start`. `migrated` is separate because it also carries the replacement and the release.
- The starter itself keeps `migrated: []` and null provenance — it is upstream, not its own downstream.

The pilot project uses this exact format; it does not invent a local one. `scripts/sync-filter.mjs` implements the filtering and is what the sync command runs.

## Evidence files (bundle)

`docs/harness/reviewer-capabilities.json` (live probe of both reviewers), `docs/harness/release-readiness.json` (live installed-host smoke — a report of observed behavior, never a gate), their rendered `.md`, `docs/harness/installation.md`, `docs/harness/capabilities.md`. JSON is authoritative; hashes in `harness-release.json` establish identity, not proof of an unobserved run. Raw receipts stay on the machine that ran the probe.
