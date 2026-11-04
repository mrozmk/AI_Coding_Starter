---
description: Install or update the team harness from the starter (manifest-driven), then fill the teams profile
argument-hint: "<starter-root> [--check]"
allowed-tools: Bash(bash *team-setup.sh*), Bash(bash *team-mail-setup.sh*), Bash(bash *team-mail.sh*), Bash(command -v:*), Bash(jq:*), Bash(git rev-parse:*), Bash(git check-ignore:*), AskUserQuestion, Read
---

# Setup: Teams — install the team harness into this project

## Input: $ARGUMENTS

Runs in the **target** repo root. `<starter-root>` defaults to `~/Desktop/AI_Coding_Starter`. The installer is always called **from the starter** (`bash <starter-root>/.claude/lib/team-setup.sh <starter-root> <repo-root>`), because the target may not have it yet. `--check` stops after Step 2 (plan only, nothing written).

## Guardrails (absolute)

- Never overwrite a file: a difference is a `conflict`, reported for a hand merge.
- Never guess a profile value: ask, recommendation first, one question per message.
- Never touch `.claude/settings.local.json`.
- Never commit or push: the human (or supervisor) commits the result.
- `team-setup.sh` adds `permissions.allow` for `team-*.sh` and `permissions.ask` for the supervisor-only trunk writers `team-integrate.sh`, `team-integrate-lock.sh`, `team-merge-check.sh` and the channel step `team-mail-setup.sh` (`ask` beats `allow`, so a role never integrates unattended). Mention this in the Report.

## Step 1 — Preflight

`command -v tmux jq claude codex git` plus `teams.required_tools` when a profile exists. Anything missing: list it and STOP. If the profile has `build_check`, print the absolute paths it names and `test -e` each; a missing one is a **warning** (venv, `.hcc`), not a STOP.

## Step 2 — Plan

Run `bash <starter-root>/.claude/lib/team-setup.sh <starter-root> <repo-root> --check`. Show the table and the summary counters; highlight `own` conflicts.

## Step 3 — Consent

`AskUserQuestion`: Install / Report only / Cancel. No consent: STOP.

## Step 4 — Install

Run `team-setup.sh` without `--check`; print its output verbatim. Exit 3 means "no `teams` block in the profile": continue to Step 5. Exit 1 means conflicts (everything else is installed): continue, handle in Step 6.

## Step 5 — Profile interview (exit 3, or `--rerun`)

Ask via `AskUserQuestion`: `tracker` (jira|github|none), `pr_provider`; `github.repo` when **tracker or pr_provider** is github; only for tracker=github `project_owner`, `project_number`, then `project_id` via `gh project view <n> --owner <o> --format json --jq .id` (required separately) and the status field/option IDs via `gh project field-list <n> --owner <o> --format json` (show them; the user picks `started` / `delivered`); then `trunk`, `branch_types`, `clone_parent` (optional), `clone_name` (optional; must end with `{team}`/`{Team}`), `build_check`, `test_gate`, `gates` (auto|manual-mql5), `seed_files` (warn: no tracked files, `team-new` preflight rejects them), `required_tools`, `env_file_required`.

Write only with `jq --arg/--argjson` into `.claude/project-profile.json`: merge into the existing object, keep `schema`; a new file is `{"schema":1,"teams":{...}}`.

### Step 5b — Codex home

The runner refuses to start a role when `.claude/codex-profile` has no value line (the installer copies only the commented template). A value line already present: keep it. Otherwise ask for the directory (recommend `~/.codex-<project>`) and write one line under the comments. Validate exactly as the runner does: first non-comment line, `~/` becomes `$HOME`, `cd <dir> && pwd -P` must succeed; otherwise STOP with the message.

## Step 5c — Channel (agent-mail)

Binds the project to its agent-mail box through the machine registry `~/.agent-mail/projects.json` (schema, protocol and modes: `.agents/reference/agent-mail.md`). Skipped under `--check` unless the target already has `.claude/lib/team-mail-setup.sh`; then only its `--dry-run` is shown. Names come from `teams.channel` in the profile (`project_code`, `mail_suffix`, `advisor`); when the block is missing, ask for `project_code` and `mail_suffix` (recommend a short upper-case code for both) and write them with `jq` like Step 5.

1. Plan: `bash .claude/lib/team-mail-setup.sh <repo-root> --dry-run`; print it verbatim. The `mode` line says **reuse** (an entry whose `repo` is this checkout), **extend** (registry without such an entry) or **fresh** (no registry). A refusal (exit 1): show it and skip the step — never edit the registry by hand to get past it.
2. **extend** while the registry already has entries: `AskUserQuestion` — "New box for this project (recommended)" or one option per existing key ("reuse `<KEY>` — `<repo>`"). A picked key: rerun the dry-run with `--key <KEY>`; it becomes **reuse**.
3. Consent: `AskUserQuestion` Apply / Skip. **reuse** never creates a tool or a box and never rewrites the entry's `tool` (one tool per box) — say so. **extend** / **fresh** copy the vendored tool to `~/.agent-mail/tools/agent_mail-<sha>` (`create tool-copy`; `keep tool-copy` when an identical copy exists) and the entry points at that copy, never at the checkout. When the plan has an `offer roles` line, add the option "Apply and add the role names to the entry" (`--add-roles`).
4. Apply: the same command without `--dry-run` (plus the chosen `--key` / `--add-roles`); print it verbatim. It registers the missing Claude roles with `--adapter monitor`, never overwrites a recipient, and writes the gitignored `.agents/team/channel.local.json`.
5. Verify: `bash .claude/lib/team-mail.sh --here check` must print `OK`; otherwise show it and STOP. A `tool behind checkout (<old> → <new>)` line is a warning, not a failure: show it with its command and say that the re-sync (`--resync-tool`) is the Operator's decision — never run it from this step.
6. Hand the `reviewer:` block of the output to the user unchanged: the Reviewer registers itself from its Codex window (it needs its own thread UUID), then the Advisor restarts the `deliver` loop. With `advisor: solo` the block says there is no Reviewer.

## Step 6 — `shared` conflicts

For every `conflict (shared — merge by hand)` line give one instruction: which starter fragment the harness requires; project customizations stay.

| file | required fragment |
|---|---|
| `quick-change.md` | section `## Team mode (quick planner)` |
| `check-implementation.md` | `--base <rev>` (argument-hint, Step 0b, passed to reviewers, memory in team mode) |
| `brainstorm.md` | ticket file `.agents/team/ticket.md` as the topic; memory goes to `notes.md` in team mode; auto-approve in team mode (if the project has a gate) |
| `execute.md` | memory reflection skipped in team mode |
| `AGENTS.md` | integrator lock (`team-integrate-lock.sh`) around the worker-flow `merge --ff-only` |
| `codex-bg.sh` | per `codex-spawn.md` → Project variant |
| `tree-fingerprint.sh` | copy the starter's, when missing |

## Step 7 — Validate

`bash -c 'source .claude/lib/team-profile.sh; team_profile_load; team_profile_require_supported; team_clone_dir alfa'` and print the resolved Codex home (Step 5b). On error show it verbatim and STOP.

## Report (Polish)

Status table, conflicts with instructions, the `alfa` clone path, the allow/ask permission note, the channel mode (reuse/extend/fresh, key, box) and the Reviewer step, and the reminder: **the profile must be committed and pushed to the trunk before the first `/start-team`** (clones read `origin/<trunk>`).

## Re-run

A second run reports only `kept`; the interview runs only when the `teams` block is missing or with `--rerun`.
