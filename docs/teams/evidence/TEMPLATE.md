# Acceptance evidence — <YYYY-MM-DD>

Copy this file to `p9-<YYYY-MM-DD>.md` for one acceptance run. Fill one line per check, appending
only. Every line is redacted before commit: the real home becomes `~`, the scratch root becomes
`<scratch>`, and the file must pass `team-purity.sh` (its scope includes `docs/teams/`). A check
that cannot run gets `skipped — <reason>`, and only the coordinator accepts a skip.

- Starter sha: `<sha>`
- Host: macOS `<version>` · Claude Code `<version>` · Codex CLI `<version>` · `/bin/bash` `<version>` · Python `<version>` · tmux `<E01>` · jq `<E01>`
- Offline suite: `team-suite.sh` summary line `<ok/FAIL>`, log `<out>/suite-<utc>.log` (redacted)
- Real registry `shasum -a 256` before phase B: `<hash>` · after: `<hash>` (AC3, must be equal)

## Line format

```
E<nn> <AC id> | <mode: offline|live-a|live-b|attended> | <command, redacted> | <observed, ≤ 1 line> | <UTC> | <starter sha>
```

Modes: `live-a` = fresh fixture `HOME`; `live-b` = reuse against a copy of the registry entry
whose box is a scratch box; `attended` = an Operator-run `!` script. Nothing runs against the live
project's box.

## Checks

| Id | Check | Mode | Pass when | Line |
|---|---|---|---|---|
| E00 | `HOME` + `CLAUDE_CONFIG_DIR` split | attended | `claude --version` and `claude -p "say ok"` answer under the fixture `HOME` with no login prompt; on failure P9 live stops | pending |
| E01 | host tools | live-a, live-b | tmux, jq, python3, sqlite3, perl, claude, codex present; versions recorded | pending |
| E02 | channel step | live-a fresh, live-b reuse | a: registry + box + 3 recipients under the fixture `HOME`; b: `mode reuse`, `keep tool`, no tool/box create lines, box = scratch box | pending |
| E03 | channel loads | live-a, live-b | `team-channel.sh show` exit 0, box = scratch box, suffix `P9` | pending |
| E04 | kit | live-a, live-b | `install.sh --dry-run`, `--apply`, `--verify` exit 0; `escalation.local.json` rendered | pending |
| E05 | profiles | live-a, live-b | `supervisor-sessions.sh check` → `Supervisor OK`, `TeamLead OK` | pending |
| E06 | preflight | live-a, live-b | every row ok, or a declared-loss line where the notifier is `none` | pending |
| E07 | roles up | live-a | 3 tmux sessions `p9-supervisor|teamlead|advisor`, each `/session-role` shows its role | pending |
| E08 | ping | live-a | `team-watch.sh ping` per role, `stats` → `picked` ≥ 1 each | pending |
| E09 | mail round-trip | live-a (pair, then solo) | TeamLead→Advisor and back delivered and processed; Reviewer only in pair | pending |
| E10 | routing | live-a | `status` shows `routing: split`, receivers active | pending |
| E11 | tier-1 menu exactly once | live-a | one `answer`; replaying the batch → `already answered` | pending |
| E12 | deny / ask outside a class never auto-approved | live-a | an ask-tier prompt becomes an Operator action, nothing typed | pending |
| E13 | tier-2 reply after a restart, no duplicate | live-a (pair, then solo) | a real Advisor reply on a scratch-box escalation; TeamLead restart; `--resume` delivers once | pending |
| E14 | `/clear` and a pid restart keep routing | live-a | same role, new socket, re-pointed line in `status` | pending |
| E15 | old run / stale fingerprint refused | offline | the regression parts in the suite log | pending |
| E16 | tiers off with a pending reply blocks delivery | offline | `answer --tier 2` refused, q file unchanged | pending |
| E17 | READY and incidents reach the Supervisor, routine does not | live-a | over the test team's run, the Supervisor is woken only for READY (`stats --since`) | pending |
| E18 | unavailable receiver alarm outside the LLM | live-a | the test TeamLead's pid killed (only that pid) → `RECEIVER TeamLead down` + a platform notification | pending |
| E19 | rollback hands control to one owner | live-a (last) | `receiver Supervisor: active`; kit `--verify` reports the files missing | pending |
| E20 | menu keystroke path | attended | script A: `confirmed: yes` for `pick:2`; the Other answer lands as `x` | pending |
| E21 | prompt binding | attended | script B: fingerprint equal after the re-render; `delivered once`, `confirmed: yes (tool_result)`; second answer → `already answered` | pending |
| E22 | two projects on one machine | live-a | `tmux ls` shows the live project's sessions untouched (names only); `ps Reviewer` matches only the scratch loop | pending |
| E23 | reuse never plants a second tool/box | live-b | E02-b plus equal `shasum` of the real registry before and after | pending |
| E24 | socket wire format on this CLI | live-a | E08 `picked` + preflight row 10 `verified` | pending |
| E25 | health check | live-a | `sessions-health.sh` with the test Advisor stopped → one notification; again → none | pending |

## Lines

<!-- one line per check, in the format above, appended in run order -->
