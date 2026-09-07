# Setup contract — profile, roots, groups, binding

## Roots

- `project_root`: the repository root of the working directory (`git rev-parse --show-toplevel`, else cwd). Every project artifact path is relative to it. Running from a subdirectory or a worktree still resolves to that root; paths with spaces are ordinary.
- `plugin_root`: the installed plugin directory — two levels above the running `SKILL.md`; `${CLAUDE_PLUGIN_ROOT}` on Claude Code. Scripts are `node <plugin_root>/scripts/<name>.mjs`; references and templates are `<plugin_root>/references/`, `<plugin_root>/templates/`. A starter checkout is not a plugin root: `scripts/profile.mjs` refuses a root without `harness-build.json`.
- Never rely on inherited cwd or on an environment variable shared between hosts.

## Profile

Canonical file `.agents/project-profile.json`, schema 2 (`schemas/project-profile.schema.json`). Fields:

| Field | Values | Notes |
|---|---|---|
| `schema` | `2` | |
| `language` | `pl` \| `en` | conversation language only |
| `mode` | `greenfield` \| `brownfield` | ≥50 project files → brownfield, confirmed in the interview |
| `git_host` | `github` \| `bitbucket` \| `gitlab` \| `none` | from `origin` |
| `workflow` | `preset`, `pr_required`, `trunk`, `integration`, `branch_types`, `branch_pattern`, `pr_dest`, `protected`, `merge`, `orchestrate_publish` | derived once from the preset |
| `tracker` / `confluence` / `codex` | `jira`\|`none` / bool / bool | team answers |
| `author_host` | `claude` \| `codex` | the host the team mostly authors from |
| `roles.executor` | `{model: opus, effort: medium}` | required target; shown, not asked |
| `roles.reviewer.claude` | `{model: fable, effort: high}` | fixed default |
| `roles.reviewer.codex` | `{model: <explicit>, effort: <explicit>}` | default `gpt-6-astra` / `high`; a project override wins |
| `planning.after_brainstorm` | `stop` \| `plan-feature` | absent → `stop` |
| `groups` | `planning`, `review`, `execution`, `git`, `tracker`, `confluence` → bool | plugin capability groups; `review` is the team's explicit choice (default `true`), never inferred from installed CLIs |

Preset expansion (`scripts/rules.mjs branchModel` / `derivePublish`): `trunk` → trunk `main`, integration `main`, pattern `<type>/<slug>` (`<type>/<KEY>-<slug>` with Jira), protected `[]`, merge `ff`, publish `push`. `feature-branch` → same trunk/integration, `pr_required=true`, protected `[main]`, merge `squash`, PR to `main`, publish **`branch-local`** (PR-gated: the pipeline commits, a human publishes). `gitflow` → trunk `main`, integration `develop`, protected `[main, develop]`, merge `squash` (merge-commit for release/hotfix), publish `branch-local`. An explicit `orchestrate_publish: push` on a PR-gated preset is rejected by the profile validator; a stricter explicit `branch-local` always wins.

### Legacy compatibility

- Only `.claude/project-profile.json` (schema 1) exists → it is read through the schema-2 view and **written in place**: `schema: 1`, every old and unknown key preserved, the schema-2-only fields stored under `harness`. No second authoritative file is created during the pilot.
- Both files exist → resolve symlinks; the same physical file is one authority. Different files with different shared behavioral values (`language`, `mode`, `git_host`, `tracker`, `confluence`, `codex`, `app_surface`, `author_host`, `workflow.preset|pr_required|protected|orchestrate_publish|merge`, `planning.after_brainstorm`, `groups`, `roles`) → `conflict`: every write is refused until a human resolves it.
- Missing profile → interview. Nothing is inferred from installed tools.

### Consent

`scripts/profile.mjs set` / `apply` without `--consent yes` print a preview and write nothing. Skills call them with consent only after the user approved the summary screen. `apply --changes '<json>'` writes the whole batch atomically; values are JSON (arrays, objects, booleans). Validation — schema plus cross-field contradictions (review enabled with `codex=false` for a Claude author, `groups.tracker` with tracker `none`, `pr_required` with `push`, a protected trunk with `push`, a legacy `commands.*` mirror disagreeing with its fact) — runs before any write; a rejected batch leaves no partial profile. Reading is just as strict: `read`/`groups` return `missing`, `invalid` or `conflict` with **no enabled groups**; a skill that sees anything but `ok` stops.

## Groups

A `false` group disables every entrypoint of that group even though the skill is installed: the skill checks `profile.mjs groups` first and stops with `<group> disabled in the project profile`. Disabling never prunes the shared plugin cache; enabling is a profile change after confirmation plus a dependency preflight (e.g. tracker credentials) — no cache edit, no file restore. A tracker counts as configured only when the profile says so, never because a skill exists.

## Binding (`.agents/harness-version.json`)

```json
{ "schema_version": 2, "name": "harness", "hosts": { "claude": { "version": "0.1.0", "source_digest": "<sha256>", "payload_digest": "<sha256>" } } }
```

Schema 2 is **portable**: identity only (`name`, per-host `version`, `source_digest`, `payload_digest`), committed. The installed root, `bound_at`, the machine name and operator acknowledgements (hook trust) live in `.agents/harness-state/binding.json`, gitignored by its own `.gitignore`. Written by `profile.mjs bind` after `verifyPackageRoot` re-hashed every file listed in the package marker, checked the native manifest version, the skill entry and hook target paths, and rejected unknown extras. `profile.mjs check-version` re-verifies on every `prime`; a moved, upgraded or edited root, or a clone with no local state, invalidates the binding and requires re-binding on that machine — never a fallback to checkout files, never another machine's root. A schema-1 receipt (root inside the committed file) is read compatibly and split by `profile.mjs migrate-binding --consent yes`. A started run keeps its version.

## Codex sandbox and `.agents/`

Codex's `workspace-write` sandbox refuses writes under `.agents/` (it keeps its own marketplace config there), and the harness stores specs, plans, memory and the version receipt exactly there. A Codex author session needs `sandbox_workspace_write.writable_roots` to include the project's `.agents` directory — in `~/.codex/config.toml` (absolute path) or in a **trusted** project `.codex/config.toml` (a project-level file is ignored until the project is trusted; observed 2026-09-06 on Codex 0.153.4). Without it every planning skill reports the write as blocked; nothing is written elsewhere.

## Legacy-only dependencies (routed, never reproduced)

| Need | Legacy owner | Behaviour when absent |
|---|---|---|
| `.env.example` toggles, `.mcp.json` pruning, toolchain block, command-group pruning, TESTING/DoD/PR templates | `.claude/commands/setup/start.md` | report `legacy bootstrap not installed — skipped` and stop that step |
| PRD, brief, backlog, CLAUDE.md generation, codebase map | `.claude/commands/setup/*.md`, `maintain/refresh-brief.md` | same |
| execute, check, commit, push, orchestrate | legacy commands (`groups.execution/git` are `false` in this release) | the skill names the dependency and stops |
