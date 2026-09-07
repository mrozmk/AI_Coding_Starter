# AGENTS.md
<!-- harness:generated-rules agents -->

Codex entry point for this repository. It is deliberately thin.

1. **Read `{rules-file}` in full before any task.** {rules-authority-note} It does not auto-load. If it is missing, say so and stop — do not reconstruct rules from memory.
2. **Start every session with the `prime` skill** from the installed `harness` plugin (`$prime`). It loads the memory routing table, the project brief and the architecture map, checks `.agents/harness-version.json` against the loaded plugin, and reports exactly what was read.
3. **Planning flow:** `$brainstorm` → spec (Draft) → independent review → the user's approval (`scripts/approval.mjs` stamp) → optionally `$plan-feature` (only when the profile says `planning.after_brainstorm = plan-feature` and the user did not say stop). No skill in this plugin writes application code, commits, pushes or deploys.
4. **Profile:** `.agents/project-profile.json` (or the legacy `.claude/project-profile.json`). A disabled group in the profile disables its entrypoints even though the skill is installed; a missing or conflicting profile blocks them.
5. **Reviews are closed-context:** the reviewer receives an exact-byte context pack, runs read-only with no shell, no agents and no plugins, and returns a validated JSON opinion. A missing or malformed opinion never counts as approval.
6. **Write access.** Codex's sandbox protects `.agents/`; this project's `.agents` directory must be listed in `sandbox_workspace_write.writable_roots` (user config, or a trusted project `.codex/config.toml`) or no spec, plan, approval or memory entry can be saved. Say so instead of writing elsewhere.
7. **Host controls differ.** Claude Code's `.claude/settings.json` permission tiers do not apply here; the Codex sandbox and `approval_policy` are the controls. The shared rules record which enforcement each host actually has.

If the `harness` plugin is not installed, follow `references/installation.md` from the release bundle and stop; do not improvise the procedures.
