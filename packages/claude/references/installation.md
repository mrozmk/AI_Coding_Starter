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

`node scripts/release-harness.mjs` after the version bump: it refuses a dirty tree, a version not newer than `origin/release`, or a failing `check-harness --all`, then prints the two pushes (`main`, `main:release`); `--push yes` performs them.

## Update (project)

1. Claude Code with auto-update: the new version arrives at the next session start; `prime` then reports `harness <new> installed, project pinned to <old>` with the exact bind command. Without auto-update: `claude plugin marketplace update ai-coding-starter` + `claude plugin update harness@ai-coding-starter`. Codex: `codex plugin marketplace upgrade` + `codex plugin add harness@ai-coding-starter --json`.
2. Finish or stop running sessions — never switch versions under a live executor.
3. Adopt deliberately: re-bind (`profile.mjs bind`) for each host; the old binding is invalid by design, and `prime` never binds on its own — the committed receipt is the project's pin, not a per-machine side effect.
3b. Claude Code: `node <installed root>/scripts/bootstrap.mjs wrappers --project-root <project> --plugin-root <installed root>` previews the project wrappers the version adds or changes; `--consent yes` writes them. Re-binding alone never touches `.claude/commands/`.
4. Nothing in the project (profile, plans, specs, memory, rules) is changed by an update. Version changes are a deliberate act.

## Rollback

Rollback restores **ownership**, not merely an empty plugin directory. `node <installed root>/scripts/sync-filter.mjs rollback --manifest .claude/.starter-sync.json --release <version>` names the legacy paths and `settings.json` identities that return to the project once their `migrated*` records are dropped; the next `/maintain:sync-from-starter` re-offers them. Then disable or remove the plugin (`claude plugin disable|uninstall`, `codex plugin remove`), install the previous bundle if one is wanted, re-bind. Code, specs, plans, memory, `.agents/harness-state/` telemetry and other people's work stay untouched. No `git reset --hard`, no worktree deletion, no recursive cache purge.

## Legacy-only downstream sync

A project that has not installed the plugin still syncs: `/maintain:sync-from-starter` runs `harness-source/scripts/sync-filter.mjs` from the starter checkout it already clones, with `migrated: []` and no plugin root. The same decision tables apply; nothing requires an installation.

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
