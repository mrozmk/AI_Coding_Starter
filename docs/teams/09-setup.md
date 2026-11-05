# 09 — Setup

How a developer brings the team layer into a project, from a clean machine to the point where the
role sessions would start. Written from a walkthrough of the real scripts in a fixture `HOME`
([evidence](evidence/p9-docs-walkthrough-2026-11-05.md)). Starting the role sessions, the signal
daemon and the live checks belong to the role-session layer and to the acceptance run; until
then, see [capabilities.md](capabilities.md) for what is proven.

## Requirements

- macOS (Linux: to verify), `/bin/bash` 3.2 or newer, Python 3.9+ (stdlib only), `perl`, `sqlite3`.
- `tmux`, `jq`, `git`, Claude Code (`claude`) and the Codex CLI (`codex`) on `PATH`; `/setup:teams`
  stops when any of them is missing.
- A clone of this starter somewhere on the machine. You pass its path to `/setup:teams`.
- A pull-request provider (`github` or `azure-devops`) to run teams. `pr_provider: none` is
  valid and turns the PR layer off: setup, the channel, the operator kit and the supervision roles
  work, while team runs, PRs and merges refuse with a message naming the setting. Only `github`
  requires a `github.com` `origin`.

## Fresh machine (no `~/.agent-mail/projects.json`)

All commands run in **your project's** root, not in the starter.

1. **Install the layer:** `/setup:teams <starter-root>` (pass the path; the built-in default is one
   machine's layout). It plans first (`--check`), asks, then copies the manifest's files. Nothing
   existing is overwritten: a difference is reported as a conflict.
2. **Fill the profile** (`.claude/project-profile.json` → `teams`), when the installer exits 3.
   Start from [`.claude/project-profile.json.example`](../../.claude/project-profile.json.example):
   The profile check requires `tracker`, `pr_provider`, `trunk`, `branch_types`, `required_tools`,
   `build_check`, `test_gate`, `gates` and `env_file_required`, plus `github.repo` when the
   tracker or the PR provider is `github`; the rest is optional. Formats that are easy to get wrong: `build_check` is one shell command (a string),
   `test_gate` is a script path or `none`, `env_file_required` is `true|false`, and
   `required_tools`, `branch_types` and `seed_files` are arrays (the first two non-empty). Add `teams.channel` (`project_code`,
   `mail_suffix`, optional `tmux_prefix`, `advisor: pair|solo`, `notifier`).
3. **Codex home:** one value line in `.claude/codex-profile` (`~/.codex-<project>` is fine).
4. **Channel:** the dry-run's `mode` line says `fresh`. Apply it. It creates the registry, a tool
   copy under `~/.agent-mail/tools/` (named by its content: identical tools share one copy), the box and its `decisions/`, registers the three Claude
   roles and writes the gitignored `.agents/team/channel.local.json`, then renders
   `watch.local.json`. `escalation.local.json` is `skip`ped until step 6.
5. **Verify:** `bash .claude/lib/team-mail.sh --here check` prints `OK <KEY> (box …, tool …)` and
   `bash .claude/lib/team-channel.sh show` exits 0.
6. **Operator kit** (an Operator action, run it yourself with `!`):
   `bash .claude/team/sessions/operator-kit/install.sh --dry-run`, then `--apply`, then
   `--verify` (every line `ok`). `--apply` also renders `.agents/team/escalation.local.json`.
   The dry-run still prints `skip … escalation.local.json` because the adapter does not exist
   yet; `--apply` writes it. See [08](08-operator-kit.md).
7. **Reviewer** (`advisor: pair` only): the channel step's `reviewer:` block is for the
   Reviewer's own Codex window, which registers itself with its thread id.

Stop here. The role sessions are started by the role-session layer (01, not merged yet).

## A machine that already runs the channel

The registry `~/.agent-mail/projects.json` exists. The channel step's dry-run tells you which case
you are in:

- **`reuse`**: an entry's `repo` is this checkout. Everything is `keep`; a missing role recipient
  is registered. The entry's `tool` is never rewritten (one tool per box), even when it points at
  an external tool directory; a `note tool` line says the vendored copy is not used for that box.
  An `offer roles` line means the entry lacks role names: rerun with `--add-roles` to add them.
- **`extend`**: entries exist, none for this checkout. `/setup:teams` asks: a new box for this
  project (recommended), or one existing key (`--key <KEY>`, which turns it into `reuse` of that
  box). Reusing a key shares that box **and its recipient names**, so it is refused when the
  entry's suffix differs from your profile's `mail_suffix`: pick a key only for the same project.
- A second project on the same machine gets its own key, box and recipients from its own
  `project_code` / `mail_suffix` / `tmux_prefix`. Two projects never share a recipient name.

A refusal (exit 1) writes nothing. Never edit the registry by hand to get past it.

## Smoke checklist and evidence

The acceptance checks, their ids (E00–E25) and the line format:
[evidence/TEMPLATE.md](evidence/TEMPLATE.md). The offline gate in the starter:
`team-suite.sh` (README → Tests).

## Known limits

Written as boundaries in [capabilities.md → Boundaries](capabilities.md#boundaries).
