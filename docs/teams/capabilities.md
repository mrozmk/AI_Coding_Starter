# Team supervision — capabilities

What the team layer does, and how far each claim is proven. Three words, used exactly:

- `implemented` — the code and its offline tests exist in the starter at the named phase;
- `verified` — a live evidence line (an E-id in `evidence/p9-<date>.md`) on the host below;
- `to verify` — not yet proven: no evidence line, another host, or another CLI version.

The **offline** column cites the `team-suite.sh` steps that cover the row, with their check counts,
from the full run on `f3d7996` (2026-11-05T15:37Z, 39 steps, `team-suite: OK`, macOS). The
**live** column cites an E-id and stays `to verify` until the acceptance run (P9 phases B and C)
writes that line. The offline dry-run of E01–E06 is recorded in
[evidence/p9a-walkthrough-2026-11-05.md](evidence/p9a-walkthrough-2026-11-05.md); it is not a
live acceptance line.

- Verified host: `to verify` (filled from E01: macOS · Claude Code · Codex CLI · `/bin/bash` · Python · tmux · jq)
- Linux: **unsupported today** — the BSD `stat -f` sites break the daemon, the runner and the question ledger; ported and verified only under follow-up F12 (also flock, ps formats, SIGALRM, the messaging socket, cron/systemd for the health check). The stdlib-only agent-mail tool passed its unittest on Ubuntu 24.04 ([p9a evidence](evidence/p9a-walkthrough-2026-11-05.md#linux-colima-vm-ubuntu-24044-kernel-68-python-3123))
- Other Claude Code versions: `to verify` — the messaging socket is an observed interface (preflight row 10)

## Capabilities

| Capability | Phase | Implemented | Verified offline (suite step, checks) | Verified live (E-id) |
|---|---|---|---|---|
| Channel config loads; two projects kept apart by suffix and tmux prefix | P3 | implemented | smoke-channel (1), smoke-mail (1) | to verify (E03, E22) |
| Agent-mail channel: fresh and reuse bring-up, never a second tool or box | P2 | implemented | smoke-mail (1), agent-mail-unittest (73) | to verify (E02, E23) |
| Operator kit installs, verifies and rolls back outside the repo | P7 | implemented | smoke-kit (6) | to verify (E04, E19) |
| Role profiles check and preflight | P5 | implemented | smoke-sessions (10), session-profiles (2) | to verify (E05, E06) |
| Role sessions start under their prefix and report their role | P5 | implemented | smoke-sessions (10) | to verify (E07) |
| Signal daemon delivers to the role sessions over the messaging socket | P4 | implemented | smoke-15 (11), smoke-16 (8) — a stub receiver socket | to verify (E08, E24) |
| Role-to-role mail round-trip (Reviewer only in `pair`) | P2, P5 | implemented | smoke-escalation (12), agent-mail-unittest (73) | to verify (E09) |
| Split routing: routine to the TeamLead, READY and incidents to the Supervisor | P4 | implemented | smoke-16 (8) | to verify (E10, E17) |
| A tier-1 menu is answered exactly once | P1 | implemented | smoke-4 (1), smoke-5 (15), smoke-17 (12) | to verify (E11) |
| Deny / ask outside an enabled class is never auto-approved | P1, P8 | implemented | smoke-12 (16), smoke-policy (1), guard-team-egress-test (105), guard-destructive-sql-test (87) | to verify (E12) |
| A tier-2 reply survives a TeamLead restart without a duplicate | P1, P6 | implemented | smoke-11 (1), smoke-13 (1), smoke-escalation (12) | to verify (E13) |
| `/clear` and a pid restart keep the routing | P4 | implemented | smoke-16 (8), smoke-17 (12) | to verify (E14) |
| An old run or a stale fingerprint is refused | P1 | implemented | smoke-4 (1), smoke-5 (15) (E15) | — offline only |
| Tiers off with a pending reply blocks delivery | P1 | implemented | smoke-17 (12) (E16) | — offline only |
| An unavailable receiver raises an alarm outside the LLM | P4 | implemented | smoke-15 (11), smoke-16 (8) | to verify (E18) |
| Rollback hands control back to one owner | P4, P5, P7 | implemented | smoke-16 (8), smoke-sessions (10), smoke-kit (6) | to verify (E19) |
| Menu keystroke path | P1 | implemented | — | to verify (E20, attended) — never run: no TTY, Operator-only |
| Prompt binding holds across a re-render | P1 | implemented | — | to verify (E21, attended) — never run: no TTY, Operator-only |
| Health check notices a stopped role once | P7 | implemented | smoke-kit (6) | to verify (E25) |
| Permission classes stay off until the profile enables them | P8 | implemented | smoke-policy (1), smoke-12 (16) | — offline only |

## Boundaries

These are limits, not claims. They hold on every host.

- A dead tmux server takes every loop and every role down; only the external health check notices.
- The messaging socket is an observed interface. A CLI upgrade can break delivery silently:
  `UNDELIVERED` detects transport errors and `RECEIVER down` a dead pid or a missing socket, but a
  silent discard after a successful write is caught only behaviourally (`UNPICKED`).
- The prompt-check matcher approximates the host's permission matcher; the live `/permissions`
  view is the truth. The checker refuses any dynamic word (`$VAR`, a runtime path, a path after
  `cd`) and sends it to the Operator.
- The sender cannot detect a human typing between its last capture and the clear of a draft.
- The escalation class is attested by two agents, not proven by a parser.
- The socket predicate is checked, then used: `team-watch-send.py` runs `lstat` (a 0600 socket owned
  by this uid) and then `connect`. A same-uid process can swap the file in between; the residual is
  same-uid only, because the receiver files that name the socket live in a 0700 `receivers/`
  directory and are mode 600.
- The channel's sender name is declarative; there is no authentication between sessions. A role
  can send mail under another role's name, including a reply that reads as the Advisor's answer to
  its own escalation; the `operator-ref` check proves only that a matching note exists in the
  decisions directory, which the same user can write. Known and accepted, not a guarantee.
- Everything about the Reviewer assumes a CLI with a queue-style wake entry point.
