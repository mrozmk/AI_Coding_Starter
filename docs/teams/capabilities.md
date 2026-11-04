# Team supervision — capabilities

What the team layer does, and how far each claim is proven. Three words, used exactly:

- `implemented` — the code and its offline tests exist in the starter at the named phase;
- `verified` — a live evidence line (an E-id in `evidence/p9-<date>.md`) on the host below;
- `to verify` — not yet proven: no evidence line, another host, or another CLI version.

**Every cell stays `to verify` until an E-id backs it** — the implemented column included. The offline column cites a `team-suite.sh`
step and its check count, and the live column cites an E-id. Nothing in this file is `verified`
yet: the acceptance run (P9 phases B and C) fills it.

- Verified host: `to verify` (filled from E01: macOS · Claude Code · Codex CLI · `/bin/bash` · Python · tmux · jq)
- Linux: `to verify` (flock, ps formats, SIGALRM, the messaging socket, cron/systemd for the health check) — follow-up F12
- Other Claude Code versions: `to verify` — the messaging socket is an observed interface (preflight row 10)

## Capabilities

| Capability | Phase | Implemented | Verified offline (suite step, checks) | Verified live (E-id) |
|---|---|---|---|---|
| Channel config loads; two projects kept apart by suffix and tmux prefix | P3 | to verify | to verify | to verify (E03, E22) |
| Agent-mail channel: fresh and reuse bring-up, never a second tool or box | P2 | to verify | to verify | to verify (E02, E23) |
| Operator kit installs, verifies and rolls back outside the repo | P7 | to verify | to verify | to verify (E04, E19) |
| Role profiles check and preflight | P5 | to verify | to verify | to verify (E05, E06) |
| Role sessions start under their prefix and report their role | P5 | to verify | to verify | to verify (E07) |
| Signal daemon delivers to the role sessions over the messaging socket | P4 | to verify | to verify | to verify (E08, E24) |
| Role-to-role mail round-trip (Reviewer only in `pair`) | P2, P5 | to verify | to verify | to verify (E09) |
| Split routing: routine to the TeamLead, READY and incidents to the Supervisor | P4 | to verify | to verify | to verify (E10, E17) |
| A tier-1 menu is answered exactly once | P1 | to verify | to verify | to verify (E11) |
| Deny / ask outside an enabled class is never auto-approved | P1, P8 | to verify | to verify | to verify (E12) |
| A tier-2 reply survives a TeamLead restart without a duplicate | P1, P6 | to verify | to verify | to verify (E13) |
| `/clear` and a pid restart keep the routing | P4 | to verify | to verify | to verify (E14) |
| An old run or a stale fingerprint is refused | P1 | to verify | to verify (E15) | — offline only |
| Tiers off with a pending reply blocks delivery | P1 | to verify | to verify (E16) | — offline only |
| An unavailable receiver raises an alarm outside the LLM | P4 | to verify | to verify | to verify (E18) |
| Rollback hands control back to one owner | P4, P5, P7 | to verify | to verify | to verify (E19) |
| Menu keystroke path | P1 | to verify | — | to verify (E20, attended) |
| Prompt binding holds across a re-render | P1 | to verify | — | to verify (E21, attended) |
| Health check notices a stopped role once | P7 | to verify | to verify | to verify (E25) |
| Permission classes stay off until the profile enables them | P8 | to verify | to verify | — offline only |

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
- The channel's sender name is declarative; there is no authentication between sessions.
- Everything about the Reviewer assumes a CLI with a queue-style wake entry point.
