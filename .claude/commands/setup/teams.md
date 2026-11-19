---
description: Install or update the team harness from the starter (manifest-driven), then fill the teams profile
argument-hint: "<starter-root> [--check]"
allowed-tools: Bash(bash *team-setup.sh*), Bash(bash *team-mail-setup.sh*), Bash(bash *team-mail.sh*), Bash(bash *team-channel.sh*), Bash(command -v:*), Bash(jq:*), Bash(git rev-parse:*), Bash(git check-ignore:*), AskUserQuestion, Read
---

# Setup: Teams — install the team harness into this project

## Input: $ARGUMENTS

Runs in the **target** repo root. `<starter-root>` is required: when it is missing, ask for the starter clone's path (never assume a layout). The installer is always called **from the starter** (`bash <starter-root>/.claude/lib/team-setup.sh <starter-root> <repo-root>`), because the target may not have it yet. `--check` stops after Step 2 (plan only, nothing written).

## Guardrails (absolute)

- Never overwrite a file: a difference is a `conflict`, reported for a hand merge.
- Never guess a profile value: ask, recommendation first, one question per message.
- Never touch `.claude/settings.local.json`.
- Never commit or push: the human (or supervisor) commits the result.
- `team-setup.sh` adds `permissions.allow` for `team-*.sh` and `permissions.ask` for the supervisor-only trunk writers `team-integrate.sh`, `team-integrate-lock.sh`, `team-merge-check.sh` and the channel step `team-mail-setup.sh` (`ask` beats `allow`, so a role never integrates unattended) — except under the profile's `workflow.team_merge: auto` (the `/setup:start` answer), where the three trunk writers are left out and removed; the channel step stays behind ask. It also registers the egress guard `guard-team-egress.sh` under the `Bash` and `WebFetch` matchers with `"onFailure": "block"` (the template's shared settings do not carry it — the team layer opts in here) and ignores `.agents/team/` and `.agents/agent-mail/`. Mention this in the Report.

## Step 1 — Preflight

`command -v jq claude codex git python3 perl`, the session host — `tmux`, or `hc` when the profile sets `teams.session_host: "herdr"` (`auto` is tmux today) — plus `teams.required_tools` when a profile exists (the hooks and the runner need the last two); `sqlite3` only when Step 5c installs the agent-mail kit. Anything missing: list it and STOP. If the profile has `build_check`, print the absolute paths it names and `test -e` each; a missing one is a **warning** (venv, `.hcc`), not a STOP.

## Step 2 — Plan

Run `bash <starter-root>/.claude/lib/team-setup.sh <starter-root> <repo-root> --check`. Show the table and the summary counters; highlight `own` conflicts.

## Step 3 — Consent

`AskUserQuestion`: Install / Report only / Cancel. No consent: STOP.

## Step 4 — Install

Run `team-setup.sh` without `--check`; print its output verbatim. A `removed retired <path>` line is a file the layer no longer ships, deleted because it was an unchanged starter copy; a `conflict (retired — …)` line is such a file the project changed: show it and let the user delete or keep it. Exit 3 means "no `teams` block in the profile": continue to Step 5. Exit 1 means conflicts (everything else is installed): continue, handle in Step 6.

## Step 5 — Profile interview (exit 3, or `--rerun`)

Ask via `AskUserQuestion`: `tracker` (jira|github|none), `pr_provider`; `github.repo` when **tracker or pr_provider** is github; only for tracker=github `project_owner`, `project_number`, then `project_id` via `gh project view <n> --owner <o> --format json --jq .id` (required separately) and the status field/option IDs via `gh project field-list <n> --owner <o> --format json` (show them; the user picks `started` / `delivered`); then `trunk`, `branch_types`, `clone_parent` (optional), `clone_name` (optional; must end with `{team}`/`{Team}`), `build_check`, `test_gate`, `gates` (auto|manual-mql5), `seed_files` (warn: no tracked files, `team-new` preflight rejects them), `required_tools`, `env_file_required`.

**A top-level `github` block already exists** (written by `/setup:start` for `tracker=github` without teams) → do not ask `github.*` again and never copy it into `teams.github`: the team layer reads `teams.github // github`, so one block serves both paths. Offer to reuse it; when `teams.tracker=github` and the block has no Project fields (its "No Project" answer), ask the Project questions above and add the six fields **to that top-level block** — teams require a Project, the single-session path does not.

Shapes and examples: `.claude/project-profile.json.example` (installed with the layer). Easy to get wrong: `build_check` is one shell command (a string); `test_gate` is a script path or `none`; `env_file_required` is `true|false`; `branch_types` and `required_tools` are non-empty arrays. `pr_provider: none` turns the PR layer off: setup, the channel, the operator kit and the supervision roles work, but team runs, PRs and merges refuse with a message naming the setting; only `github` needs a `github.com` `origin`.

Write only with `jq --arg/--argjson` into `.claude/project-profile.json`: merge into the existing object, keep `schema`; a new file is `{"schema":1,"teams":{...}}`.

### Step 5b — Codex home

The runner refuses to start a role when `.claude/codex-profile` has no value line (the installer copies only the commented template). A value line already present: keep it. Otherwise ask for the directory (recommend `~/.codex-<project>`) and write one line under the comments (a leading `~/` is fine: the runner and the channel step expand it to `$HOME`). Validate exactly as the runner does: first non-comment line, `~/` becomes `$HOME`, `cd <dir> && pwd -P` must succeed; otherwise STOP with the message.

**Claude home (optional).** `.claude/claude-profile` names the `CLAUDE_CONFIG_DIR` the harness launches every Claude session on — team roles, supervision roles and `roles.sh here`. No value line (the installer copies only the commented template) keeps today's behaviour: the launcher forwards its own `CLAUDE_CONFIG_DIR`, when set. Ask only when the project runs on its own Claude config dir (recommend `~/.claude-<project>`); write one line, validated like the Codex home. A declared dir that does not resolve makes every launcher refuse before a session starts.

## Step 5c — Optional — agent-mail kit (cross-machine mail)

The team layer does not need agent-mail: role messages are inbox files with the session host's doorbell. This step is the opt-in kit for mail between machines, and it is the only path through `/setup:teams` that writes under `~/.agent-mail`. Run it when the profile has `teams.channel` or the target already has `.agents/team/channel.local.json` (an installed kit: everything below behaves as before); otherwise ask once via `AskUserQuestion` — "Skip (recommended)" first, then "Install the agent-mail kit" — and on Skip go to Step 6 and say "agent-mail kit: not installed (optional)" in the Report.

Binds the project to its agent-mail box through the machine registry `~/.agent-mail/projects.json` (schema, protocol and modes: `.agents/reference/agent-mail.md`). Skipped under `--check` unless the target already has `.claude/lib/team-mail-setup.sh`; then only its `--dry-run` is shown. Names come from `teams.channel` in the profile (`project_code`, `mail_suffix`, `advisor`); when the block is missing, ask for `project_code` and `mail_suffix` (recommend a short upper-case code for both) and write them with `jq` like Step 5.

1. Plan: `bash .claude/lib/team-mail-setup.sh <repo-root> --dry-run`; print it verbatim. The `mode` line says **reuse** (an entry whose `repo` is this checkout), **extend** (registry without such an entry) or **fresh** (no registry). A refusal (exit 1): show it and skip the step — never edit the registry by hand to get past it.
2. **extend** while the registry already has entries: `AskUserQuestion` — "New box for this project (recommended)" or one option per existing key ("reuse `<KEY>` — `<repo>`"). A picked key: rerun the dry-run with `--key <KEY>`; it becomes **reuse**.
3. Consent: `AskUserQuestion` Apply / Skip. **reuse** never creates a tool or a box and never rewrites the entry's `tool` (one tool per box) — say so. **extend** / **fresh** copy the vendored tool to `~/.agent-mail/tools/agent_mail-<hash>` (named by its content, so an uncommitted fresh install works and two projects with the same tool share one copy) (`create tool-copy`; `keep tool-copy` when an identical copy exists) and the entry points at that copy, never at the checkout. When the plan has an `offer roles` line, add the option "Apply and add the role names to the entry" (`--add-roles`).
4. Apply: the same command without `--dry-run` (plus the chosen `--key` / `--add-roles`); print it verbatim. It registers the missing Claude roles with `--adapter monitor`, never overwrites a recipient, writes the gitignored `.agents/team/channel.local.json`, then renders `.agents/team/watch.local.json` from `.claude/team/watch.local.json.tmpl` (`team-channel.sh render`; a hand-written file is kept). A `warn render` line: show it — the channel is bound, the generated configs are not.
5. Verify: `bash .claude/lib/team-mail.sh --here check` must print `OK` and `bash .claude/lib/team-channel.sh show` must exit 0; otherwise show it and STOP. A `tool behind checkout (<old> → <new>)` line is a warning, not a failure: show it with its command and say that the re-sync (`--resync-tool`) is the Operator's decision — never run it from this step.
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

`bash -c 'source .claude/lib/team-profile.sh; team_profile_load; [ "$TEAM_PR_PROVIDER" = none ] || team_profile_require_supported; team_clone_dir alfa'` and print the resolved Codex home (Step 5b). On error show it verbatim and STOP.

## Report (Polish)

Status table, conflicts with instructions, the `alfa` clone path, the allow/ask permission note, the agent-mail kit (not installed, or the channel mode reuse/extend/fresh, key, box and the Reviewer step), and the reminder: **the profile must be committed and pushed to the trunk before the first `/start-team`** (clones read `origin/<trunk>`).
Then the next step, one of two:
- **single window:** in the supervising window run `bash .claude/lib/team-watch.sh start` (one
  daemon + watchdog in tmux `<tmux_prefix>-team-watch[-dog]`, this session registered as the
  receiver); routing stays `single Supervisor` and that window runs `/monitor` in pushed mode;
- **role sessions:** `bash .claude/lib/supervisor-sessions.sh check`, then `/roles` (starts the
  standing roles), `bash .claude/lib/supervisor-sessions.sh preflight` and the routing step in
  `.agents/reference/supervisor-sessions.md` → Migration.
Optional, Herdr users only: print (never run) the Herdr notification mod's install line,
`bash .claude/team/herdr-mod/install.sh --dry-run --dock <layout>` then without `--dry-run` (a
layout of the user's, never Herdr's `main`; without `--dock` no strip is docked), and the switch
`{"version": 1, "herdr": {"enabled": true}}` for `~/.agent-comms/notify.json` (mode 0600; the
user writes it). README: `.claude/team/herdr-mod/harness-notify/README.md`.
Optional, macOS: print (never run) the iMessage channel's steps — the user adds `imessage`
(`enabled`, `recipient`, `quiet`) to the same file, then runs `bash .claude/team/notify-kit/install.sh
--dry-run` and without it from the main checkout (the quiet-end flush job). README:
`.claude/team/notify-kit/README.md`.
The installer registered its SessionStart and Stop hooks (W, S, R); runbooks:
`.agents/reference/team-watch.md`, `.agents/reference/supervisor-sessions.md`.

## Re-run

A second run reports only `kept`; the interview runs only when the `teams` block is missing or with `--rerun`.
