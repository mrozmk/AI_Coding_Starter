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

Installing the plugin activates no **command** in a project: legacy `.claude/commands/*.md` keep running until the operator records their replacement. The exception is a **wrapper**: `setup-start` copies `templates/wrappers/*.md` over the legacy top-level command files so the bare command routes to the plugin skill — those stay ordinary starter files (sync category A), never `migrated` records.

**Hooks are different, and the difference decides the whole procedure.** A plugin's `hooks/hooks.json` is live the moment the plugin is enabled — on Claude Code there is no per-hook opt-in, and on Codex the operator's `/hooks` trust covers the manifest, not one entry of it. So enabling the plugin *is* the hook activation. Nothing can be staged on the plugin side; staging happens on the **legacy** side, by removing entries, and the only thing that must never exist is a moment when a host event sees two owners.

The preview is computed, never applied:

```bash
node <installed root>/scripts/sync-filter.mjs activation --manifest .claude/.starter-sync.json \
  --settings .claude/settings.json --plugin-hooks <installed root>/hooks/hooks.json \
  --hook-config .agents/hooks/config.json --release <version>
```

It lists every hook id with its owner after activation — `legacy`, `plugin`, `duplicate` (two owners, a decision required) or **`none`** (the plugin hook is switched off in the project's hook config and no legacy entry took over: *nothing is enforcing it*) — plus `enforced` / `disabled` per row, the exact `settings.json` identities the plugin would replace, the project-owned entries that never migrate (`check-project-deps`), any `delegation_conflicts`, and the rollback data. **Pass `--hook-config`**: without it the preview runs on an empty disable list and will report `duplicate` after a successful rollback and `plugin` where nothing runs at all.

### Phase 0 — readiness only

No file changes, and deliberately no trust recording: on Claude Code acknowledging trust means the plugin is enabled, and enabling it is the activation, so demanding it here would open the duplicate window Phase 1 forbids.

1. `profile.mjs check-version` returns `ok` for this host.
2. Print the preview above and keep it with the evidence.
3. **Take the rollback snapshot now** — the later phases delete the legacy scripts, and neither the template nor a hash can supply a downstream's customized bytes afterwards:

```bash
node <installed root>/scripts/sync-filter.mjs snapshot --settings .claude/settings.json \
  --hooks-dir .claude/hooks --hooks guard-commit,guard-push,guard-memory --write yes
```

It emits the `previous` object — **whole** registration entries, never identity strings — and with `--write yes` copies each script byte-for-byte to `.agents/hooks/snapshots/<hook>.sh`.

### Phase 1 — the quiesced switch for the hard guards

With no session running on the project, **one commit** enables the plugin (`enabledPlugins`) and removes the legacy `guard-commit`, `guard-push` and `guard-memory` entries from `settings.json`. Two owners for a blocking guard is not a transition state: it means two denials for one action, and two full per-commit secret scans for `guard-push`.

| Starting state | Phase 1 is |
|---|---|
| legacy-only | enable + remove, one commit, between sessions |
| plugin enabled, legacy still registered | remove the three entries, one commit, between sessions |
| plugin enabled, no legacy at all | a no-op on `settings.json` — only the record and the observation remain |

**Phase 1b, in the first session on the new state:** record trust (`acknowledgeHooks` — on Codex this captures the interactive `/hooks` trust), observe each guard firing from the plugin, and write the activation record. `hookState()` still reporting `installed-untrusted` here is a **failed** activation, not a pending one.

### Phase 2 — advisory and preflight

`guard-comments`, `nudge-files`, `guard-memory-scope`, `check-deps`. A duplicate window costs a repeated advisory line, so these may lag Phase 1 by a session.

`check-deps` carries a decision the hook ids cannot show: the plugin's `check-deps` **delegates** to the project's `check-project-deps.sh`, which `settings.json` also registers directly at `SessionStart`. Activating one without removing the other runs the project preflight **twice** per session while the preview still reports one owner per hook — that is what `delegation_conflicts` names. Ownership of the script's *bytes* and of its *invocation* are separate: the bytes stay project-owned and untouched, the direct registration goes, the plugin delegate becomes the single caller.

### Phase 3 — telemetry and conditionals

Per-host decisions, not a blanket activation. `audit-append` and `track-memory-read` activate on both hosts with their documented conditionals (no hook on Codex's hosted web tools; shell reads only). `nudge-lsp` is conditional on a declared LSP on Claude Code and `unsupported` on Codex, which has no structured Grep surface — the legacy script is retired rather than kept alive to honour a word. `guard-memory` keeps `codex_child_identity: required`: the supervised executor exports `HARNESS_EXECUTOR_ID`, so a child is named and per-child scope survives; `session` remains a documented project-level fallback for a hand-run Codex.

### Switching one hook off, and rolling one back

`.agents/hooks/config.json → disabled: ["<hook id>", …]` stops a plugin hook without disabling the plugin. The runner reports the `disabled` state on stderr, and for a required guard prefixes it `UNPROTECTED:` — a guard that is off is loud, never absent. The exit code stays 0: a blocking off-switch could not rescue a project from a misbehaving guard, which is the switch's only purpose.

`sync-filter.mjs rollback` is a **preview** — it returns `restore_paths` / `restore_config`, says so itself, and filters by *release*, not by hook. The executable recovery for one hook is:

1. Add the hook id to `disabled` — the plugin side stops enforcing, loudly.
2. Restore that hook's registration from the Phase 0 snapshot (the whole entry) and its script from `.agents/hooks/snapshots/<hook>.sh`, verifying the recorded `sha256`.
3. Drop **only that hook's** records — not the whole release's.
4. Re-run the preview with `--hook-config` and require `owner: "legacy"` before any session resumes.

Steps 2–4 are what the helper does not do. Stopping after step 1 leaves a hard guard enforced by neither implementation.

### Recording: activation evidence is not a migration record

`recordMigration` writes a `migrated_config` entry only when a configuration identity was actually removed — so a project where the plugin already owns the hook and no legacy entry ever existed cannot be recorded that way at all. The two are separate:

- **`migrated_config`** (in `.claude/.starter-sync.json`) keeps its meaning exactly: an identity removed and replaced.
- **`.agents/hooks/activation.json`** carries the decision — `{ host, hook, release, decision, rationale, evidence, previous, date }`, `decision` one of `activated | conditional | unsupported | legacy-kept`. `evidence` is a **path to the observation file**, not a label: the gate checks it exists. Where an identity was removed, the `migrated_config` entry and the activation record describe the same event from two sides; where none existed, the activation record stands alone.

What an observation may be recorded as is fixed, not a judgement call: `active` → `activated`; `dormant` → `conditional` with the precondition named; `error`, `untrusted`, `unsupported` or `disabled` → **no record**, because the activation failed. `recordActivation` enforces this when it is given the observed state, and `check-harness` audits it afterwards.

```bash
node <installed root>/scripts/sync-filter.mjs activation-record --record .agents/hooks/activation.json \
  --host claude --hook guard-commit --release <version> --decision activated \
  --evidence docs/harness/history/<version>-<date>/hook-activation.json --observed active --write yes
```

### Sync never enables a plugin

`unionSettings` deliberately does **not** copy `enabledPlugins` down from upstream. Without that exclusion, syncing an activated template into a legacy-only downstream would hand it the plugin *and* leave its legacy hard guards registered — the duplicate this whole procedure forbids, produced by the ordinary sync path with no operator involved. A downstream that already has the key keeps it; the rule is "never inherited", not "never present". Plugin enablement is an activation decision each project makes for itself.

### The ledger

`contracts/hook-parity.json → activation` moves `none → pilot → verified`, and anything past `none` requires `activation_evidence`. The bar: one project running a full day on plugin hooks earns `pilot`; `verified` needs the template **and** one real downstream.

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

## Migrating 0.8.0 → 0.9.0 (downstream, by hand)

0.9.0 curates the generated command wrappers: ten skills keep a short name — `prime`, `brainstorm`, `plan-feature`, `execute`, `quick-change`, `check-implementation`, `commit`, `push`, `pull`, `orchestrate` — and nineteen short names retire (`handoff`, `release`, `pr-create`, `start-task`, `setup/create-PRD`, `setup/create-backlog`, `setup/stack-research`, `maintain/refresh-brief`, `prime-ba`, `prime-qa`, `qa-verify`, `retro`, `simply`, `deep-review`, `analysis`, `recon`, `design`, `test-e2e`, `architecture-review`). Every one of them still runs as `/harness:<skill>`; only the bare alias is gone. **Nothing in your project is touched by the update** — the wrapper files you already have keep working, because each one only routes to an installed skill.

1. **Update and re-bind** per *Update (project)* above, both hosts.
2. **Preview the orphans.** `node <installed root>/scripts/bootstrap.mjs wrappers --project-root <root> --plugin-root <installed root> --prune` lists every file under `.claude/commands/` that is self-evidently a generated wrapper for its own command path and that the current release no longer ships, as `status: orphaned`. It deletes nothing. `--prune --consent yes` deletes exactly that list. Declining costs nothing: an orphaned wrapper keeps routing to its skill.
3. **Before accepting any deletion, audit your rules for links and invocations naming the nineteen.** This is the same prerequisite as the 0.5.0 → 0.6.0 section, and it has a live case: the starter seed's *Git Workflow* linked five command files, and `release` is one of the nineteen — a downstream that kept its old wrappers can be left with `CLAUDE.md` pointing at a deleted `.claude/commands/release.md`. Rewrite each such reference as `/harness:<skill>` first, or keep those wrappers.
4. **Keeping a wrapper you adopted as your own:** remove its generated-note line (the `<!-- generated by scripts/build-harness.mjs … -->` comment) or move the file out of `.claude/commands/`. Either makes the prune skip it permanently. **`.claude/.starter-sync.json → excluded` does not protect it** — that list is read by `sync-filter.mjs`, never by `bootstrap.mjs`.
5. **Renaming is already safe.** A wrapper copied or renamed inside `.claude/commands/` still names its original command in its heading, so it fails the self-consistency check and is never reported as an orphan.

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
