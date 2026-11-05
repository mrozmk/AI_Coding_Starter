# 09 — Setup

How a developer brings the team layer into a project, from a clean machine to the point where the
role sessions would start. Written from walkthroughs of the real scripts in a fixture `HOME`
([first](evidence/p9-docs-walkthrough-2026-11-05.md), [with the role layer](evidence/p9a-walkthrough-2026-11-05.md)).
Starting the role sessions needs a live Claude session: [01 — Roles and sessions](01-roles-and-sessions.md)
and the acceptance run. [capabilities.md](capabilities.md) says what is proven.

## Requirements

- **macOS only today.** Linux is unsupported until the BSD `stat -f` / `date -r` sites are ported
  (follow-up F12): they break the daemon, the runner and the question ledger there. `/bin/bash` 3.2 or newer, Python 3.9+ (stdlib only), `perl`, `sqlite3`.
- `tmux`, `jq`, `git`, Claude Code (`claude`) and the Codex CLI (`codex`) on `PATH`; `/setup:teams`
  stops when any of them is missing. **Codex is required even with `advisor: solo`**: `solo` only
  removes the Reviewer from the channel, while the team pipeline launches every role with the Codex
  home from `.claude/codex-profile` (making it conditional is follow-up F32).
- A clone of this starter somewhere on the machine. You pass its path to `/setup:teams`.
- A pull-request provider (`github` or `azure-devops`) to run teams. `pr_provider: none` is
  valid and turns the PR layer off: setup, the channel, the operator kit and the supervision roles
  work, while team runs, PRs and merges refuse with a message naming the setting. Only `github`
  requires a `github.com` `origin`.

## Fresh machine (no `~/.agent-mail/projects.json`)

All commands run in **your project's** root, not in the starter. Each step names the slash command
and the script it runs, so the steps also work from a plain terminal. A command marked as an
Operator action is typed with Claude Code's `!` prefix (the shell prefix: the command runs in your
own shell, not the agent's); in a terminal, run the same `bash …` line without it.

1. **Install the layer:** `/setup:teams <starter-root>` (pass the path). It plans first, asks, then
   copies the manifest's files. Nothing existing is overwritten: a difference is reported as a
   conflict. In a terminal: `bash <starter-root>/.claude/lib/team-setup.sh <starter-root> "$PWD"
   --check` for the plan, then the same without `--check`; exit 3 means the profile has no `teams`
   block yet (step 2), exit 1 lists conflicts.
2. **Fill the profile** (`.claude/project-profile.json` → `teams`), when the installer exits 3.
   Start from [`.claude/project-profile.json.example`](../../.claude/project-profile.json.example):
   The profile check requires `tracker`, `pr_provider`, `trunk`, `branch_types`, `required_tools`,
   `build_check`, `test_gate`, `gates` and `env_file_required`, plus `github.repo` when the
   tracker or the PR provider is `github`; the rest is optional. Formats that are easy to get wrong: `build_check` is one shell command (a string),
   `test_gate` is a script path or `none`, `env_file_required` is `true|false`, and
   `required_tools`, `branch_types` and `seed_files` are arrays (the first two non-empty). Add `teams.channel` (`project_code`,
   `mail_suffix`, optional `tmux_prefix`, `advisor: pair|solo`, `notifier`).
3. **Codex home:** `mkdir -p ~/.codex-<project>` first, then one value line in
   `.claude/codex-profile` (`~/.codex-<project>` is fine). The directory must exist: `/setup:teams`
   (Step 5b) and the runner resolve it and refuse a missing one.
4. **Channel:** `bash .claude/lib/team-mail-setup.sh "$PWD" --dry-run`, then the same without
   `--dry-run` (variants: `--key <KEY>` to reuse an existing box, `--add-roles` to add the role
   names an existing entry lacks). The dry-run's `mode` line says `fresh`. Apply it. It creates the registry, a tool
   copy under `~/.agent-mail/tools/` (named by its content: identical tools share one copy), the box and its `decisions/`, registers the three Claude
   roles and writes the gitignored `.agents/team/channel.local.json`, then renders
   `watch.local.json`. `escalation.local.json` is `skip`ped until step 6.
5. **Verify:** `bash .claude/lib/team-mail.sh --here check` prints `OK <KEY> (box …, tool …)` and
   `bash .claude/lib/team-channel.sh show` exits 0.
6. **Operator kit** (an Operator action, run it yourself with `!`):
   `bash .claude/team/sessions/operator-kit/install.sh --dry-run`, then `--apply`, then
   `--verify` (every line `ok`). `--apply` also renders `.agents/team/escalation.local.json`.
   See [08](08-operator-kit.md).
7. **Reviewer** (`advisor: pair` only): the channel step's `reviewer:` block is for the
   Reviewer's own Codex window, which registers itself with its thread id.

8. **Before the first start:** `bash .claude/lib/supervisor-sessions.sh check` prints `<role> OK`
   for the Supervisor and the TeamLead. A `<role> LEAK: …` line (exit 3) means `settings.local.json`
   allows something the role profile must not; remove it, or `start` and `here` launch nothing.
   `bash .claude/lib/supervisor-sessions.sh preflight` on a machine where nothing runs yet prints
   `WARN receivers live — … not started` and two FAILs that only running sessions clear:
   `team-watch loops beating` (until `team-watch.sh start` or `/sessions-up`) and `mail probe and
   picked ping per role` (until each role window acks a `team-watch.sh ping <role>`). Every other
   row should be `ok`. Row 10 prints `unverified: run team-watch.sh ping <role>` on any Claude Code
   other than the version the socket wire format was verified on.
9. **First bring-up:** `bash .claude/lib/supervisor-sessions.sh up` (or `/sessions-up`): the daemon
   with `--no-register`, then the role windows, then `monitoring.sh start all`. The explicit form is
   `bash .claude/lib/team-watch.sh start --no-register`, `bash .claude/lib/supervisor-sessions.sh
   start all`, `bash .claude/lib/monitoring.sh start all`. `start all` alone starts no daemon, and a
   plain `team-watch.sh start` from a terminal stops at the receiver registration. Details and the
   switch to split routing: [01 → The launcher](01-roles-and-sessions.md#the-launcher). The
   [migration](../../.agents/reference/supervisor-sessions.md#migration) applies only when a single
   `/monitor` window already runs the daemon.

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

## Verified so far

- **Offline:** `team-suite.sh`, 39 steps, OK on `f3d7996` (macOS), including the offline-only
  checks E15 (an old run or a stale fingerprint is refused) and E16 (tiers off blocks delivery).
  Per capability: [capabilities.md](capabilities.md).
- **Live dry-run, not acceptance:** E01–E06 (host tools, channel fresh and reuse, channel loads, kit,
  profiles, cold preflight) on macOS with Claude Code 2.1.318:
  [evidence/p9a-walkthrough-2026-11-05.md](evidence/p9a-walkthrough-2026-11-05.md).
- **Still open (live):** E07 onward — the role windows, pings, routing, alarms, rollback.
- **Attended only:** E00, E20 and E21 (a TTY and the Operator).
- **Linux:** none (unsupported today, F12).

## Known limits

Written as boundaries in [capabilities.md → Boundaries](capabilities.md#boundaries), among them
the same-uid window between the socket check and the connect.
