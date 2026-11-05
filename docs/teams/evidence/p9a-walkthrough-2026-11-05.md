# Setup walkthrough evidence, phase A — 2026-11-05

A documentation dry-run, **not** the acceptance run. It follows a new developer on a new machine from an empty project to the point where a live Claude session is needed, using only `docs/teams/09`, `01`, `04` and `08`. It is the second walkthrough, now on the integrated role-session layer (P4, P5, P6); the first is [p9-docs](p9-docs-walkthrough-2026-11-05.md).

No Claude session was started, and nothing ran against a real `~/.agent-mail`. tmux ran only on a private fixture server. It changes no cell of [capabilities.md](../capabilities.md): those cells wait for the acceptance run with the Operator. Format: [TEMPLATE.md](TEMPLATE.md).

- **Starter sha:** `3c21f67` (integration after P6), with this branch's doc commits; the scripts are unchanged by them.
- **Environment:**
  - `HOME=<scratch>/home`, `CLAUDE_CONFIG_DIR=<scratch>/claude`, `TMPDIR=<scratch>/tmp`, `TMUX_TMPDIR=<short private dir>`;
  - the target projects are throwaway `git init` repos with `git remote add origin git@example.invalid:…`;
  - `pr_provider: none`, `tracker: none`, no network use.
- **Host:** macOS, `/bin/bash` 3.2.57, Python 3.9.6, Claude Code 2.1.318; tmux, jq, git, python3, sqlite3, perl, claude and codex present.

## Lines — scenario (a), fresh machine

```
E01 host-tools | live-a | command -v tmux jq claude codex git python3 sqlite3 perl | all present; bash 3.2.57, python 3.9.6 | 2026-11-05T13:23Z | 3c21f67
E02 channel-fresh | live-a | team-setup.sh <starter> <proj> (created=171 merged=2, exit 3) → profile (pr_provider none, advisor pair, notifier none) → rerun (kept=173, exit 0) → codex-profile ~/.codex-fx → teams.md Step 7 validate → team-mail-setup.sh --dry-run, apply, all uncommitted | mode fresh key FX: registry (0600, ~/.agent-mail 0700), tool copy agent_mail-35a4d0ce2f45, box + decisions/, 3 monitor recipients, channel.local.json, watch.local.json; escalation skipped (no kit) | 2026-11-05T13:23Z | 3c21f67
E03 channel-loads | live-a | team-mail.sh --here check; team-channel.sh show | OK FX; show exit 0 | 2026-11-05T13:23Z | 3c21f67
E04 kit | live-a | operator-kit/install.sh --dry-run, --apply, --verify | 6 files, dry-run plans escalation.local.json, --apply writes it (send/wait/peek/opinion/timeout_min), --verify 6 ok; the installed escalate.sh carries the P6 Contract: line | 2026-11-05T13:23Z | 3c21f67
E05 profiles | live-a | supervisor-sessions.sh check | Supervisor OK, TeamLead OK, effective hooks listed per layer (W, S, R, Q, M, A, egress ×2, SQL) | 2026-11-05T13:23Z | 3c21f67
E05 profiles-leak | live-a | settings.local.json allow Bash(cat *), then Bash(*) | cat *: no leak (the profile ask cat .env* beats the local allow — correct); Bash(*): 3 LEAK lines, exit 3, preflight FAIL role profiles, here Supervisor and start TeamLead both "refused: local allow leak … nothing launched", rc 3, no tmux server | 2026-11-05T13:24Z | 3c21f67
E05 materialise | live-a | supervisor-sessions.sh materialize Supervisor | 3 deny, 14 ask, 6 allow; file 0600 in a 0700 dir; {{CLONES}} expanded to the clone prefix; hooks exactly Notification + Stop | 2026-11-05T13:24Z | 3c21f67
E06 preflight-cold | live-a | supervisor-sessions.sh preflight, nothing running | WARN receivers live — Supervisor, TeamLead not started; FAIL team-watch loops beating; FAIL mail probe and picked ping per role; the other 7 rows ok, with declared losses for notifier none and no health check; Claude Code 2.1.318 verified | 2026-11-05T13:23Z | 3c21f67
E06 preflight-loops | live-a | team-watch.sh start --no-register (private tmux server), preflight, team-watch.sh stop | works, both beats fresh; row 2 ok; only row 4 still FAILs (needs a live role acking a ping); stop left no tmux server and no fixture process | 2026-11-05T13:23Z | 3c21f67
```

## Lines — scenario (b), planted registry

```
E02 channel-reuse | live-b | team-mail-setup.sh --dry-run on the bound checkout | mode reuse key FX, every line keep (tool, box, 3 recipients, channel, both rendered configs) | 2026-11-05T13:25Z | 3c21f67
E02 channel-extend | live-b | second project F2 (suffix Ff, advisor solo): --dry-run, apply, check | mode extend key F2; keep tool-copy (identical, one shared copy); own box; check OK | 2026-11-05T13:25Z | 3c21f67
E02 channel-keyed | live-b | second project --dry-run --key FX | refused, exit 1: "entry FX has mail suffix 'Fx', this project declares 'Ff' …" | 2026-11-05T13:25Z | 3c21f67
E23 reuse-external-tool | live-b | planted entry LV (tool = an external directory, claude_roles []), --dry-run, apply, apply --add-roles | mode reuse; keep tool (external); note vendored tool unused; 2 recipients registered, 1 kept; offer roles; registry sha256 unchanged by the dry-run; --add-roles appended the roles and never touched tool | 2026-11-05T13:26Z | 3c21f67
```

A hand-planted entry without `suffix`, `decisions_dir` and the role lists is refused before anything is written ("the registry … fails the schema check; fix it first"). That is correct; the table of required keys is in `agent-mail.md`.

## P6 re-check (run against 3c21f67)

| Check | Result |
|---|---|
| `team-channel.sh turn TeamLead Advisor --kind info` | `kind=info awaiting=-`; without `--kind`, `kind=turn awaiting=AdvisorFx` |
| kit `escalate.sh` `Contract:` line | present in the installed copy; `--verify` 6 ok |
| `escalation.local.json` after `--apply` | `send`, `wait`, `peek`, `opinion`, `timeout_min` |
| smoke part `escalation` (serial, run once alone) | OK, E9 and E10 included |
| `sessions`, `team-profile-smoke`, `team-setup-smoke`, `team-smoke-kit`, purity | OK |

## Re-check after P6

P6 landed before this file was written, so every item above ran on `3c21f67`. Still open, for the acceptance run:

- E13: a tier-2 reply after a restart, with the real `team-escalate.sh` waiter and an Advisor reply, in pair and then solo mode. It needs live sessions.
- The preflight row 4 (`mail probe and picked ping per role`) turning `ok`. It needs live role windows acking a ping.
- `turn --kind report` (F30), if it is fixed.

## Linux (colima VM, Ubuntu 24.04.4, kernel 6.8, Python 3.12.3)

The VM already existed on the machine and was started for the run, then stopped. Nothing was installed or pulled: the VM has bash, python3, git, perl and shasum, but no `jq`, `sqlite3` CLI or `tmux`. The tree was copied with `git archive`.

| Piece | Result |
|---|---|
| agent-mail unittest | **pass**, 73 tests |
| purity | **pass** |
| guard tests (egress, SQL) | not runnable: the harness feeds payloads through `jq` (`jq: command not found`); the WebFetch and sqlcmd cases fail for that reason only |
| `team-smoke-lib.sh` self-test, parts 1–3 | not runnable: no `jq`/`tmux`. They also stopped earlier, on `cp: -r not specified; omitting directory …/.claude/hooks/lib/__pycache__` (F31) |

So [09](../09-setup.md) keeps "Linux: to verify": the stdlib Python layer passes, and the bash layer needs `jq`, `sqlite3` and `tmux` on the host plus the F31 fix.

## Gaps found (doc-only, fixed on this branch)

1. `09-setup.md` still said the role sessions were "not merged yet". It stopped without saying what `check` and `preflight` print before anything runs: one WARN, plus two FAILs that only running sessions clear. Step 8 and links to the launcher and the migration were added.
2. The `/setup:teams` report offered only the single-window next step and named two of the three session hooks it installs (W, R; S was missing). It now also points at `supervisor-sessions.sh check` and the migration.
3. `agent-mail.md` said a tool copy is named after `git log -1 --format=%h -- tools/agent_mail`; since F21/F22 it is named by a content hash.
4. The profile example's `_teams_doc` and `team-mode.md` §8a still called `pr_provider: none` "reserved and refused" (F23 missed both).
5. `team-mode.md` §4 named one source stack's transport method, queue service and ORM migration as examples; they are now generic.

## Gaps that need code

F29–F31 in [follow-ups.md](../follow-ups.md). None of them touches code P6 owns (`team-escalate.sh`, the escalation config, the kit's `escalate.sh`).
