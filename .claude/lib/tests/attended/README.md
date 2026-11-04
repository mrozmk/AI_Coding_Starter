# Attended acceptance checks (P9 phase B)

Starter repo only, not distributed. These files are for the Operator's attended session. **No
agent runs them**: they need a human to see the screen, and the agent's Bash has no TTY.

## 0. The scratch checkout and its environment

Everything runs in a **scratch clone** of the starter at the P9 sha, never in the shared checkout
or a live project. One-time preparation, in a plain terminal:

```bash
git clone <starter> <scratch>/p9-starter && cd <scratch>/p9-starter
pwd -P > .p9-scratch                       # the marker the scripts check; never committed
echo .p9-scratch >> .git/info/exclude      # keeps the clone's status clean
export HOME=<scratch>/p9-home              # the fixture HOME: registry, boxes, ~/.agent-ops
export CLAUDE_CONFIG_DIR=<real home>/.claude   # the roles keep the Operator's Claude login
```

Before anything else, E00: `claude --version` and `claude -p "say ok"` must answer in this
environment without a login prompt. If they do not, stop: P9 live returns to the coordinator.
Never fall back to the real registry.

## 1. The two `!` scripts

From the scratch checkout's top, in your own Claude window:

| Check | Command | What you do |
|---|---|---|
| E20 menu keystroke path | `! bash .claude/lib/tests/attended/p9-menu-keystroke.sh` | confirm each menu is visible; at the end confirm the planner got `B` and the Other answer `x` |
| E21 prompt binding | `! bash .claude/lib/tests/attended/p9-prompt-binding.sh` | confirm the permission prompt is visible, then resize the attached window (Ctrl-b d detaches) |

Each script provisions its own scratch team (`p9m`, `p9b`), starts only its stage runner, never
types into a pane (every key goes through `team-question.sh answer`, the path under test), prints
one `E2x …` evidence line and on exit kills only the tmux sessions named `<team>-*`. Paste the
line into `docs/teams/evidence/p9-<date>.md`. Both refuse to start outside the marked scratch
checkout, with the real `HOME`, or without `CLAUDE_CONFIG_DIR`.

## 2. The Codex Reviewer window (`advisor: pair` only)

The Reviewer is a Codex session that receives escalations by a push loop. For P9 it runs on a
**scratch Codex profile**, never the Operator's profile of a live project.

1. Profile: `mkdir -p <scratch>/p9-codex` and set the top-level key `codex_home` in the scratch
   checkout's `.agents/team/channel.local.json` to that path; re-render with
   `bash .claude/lib/team-channel.sh render`.
2. Login once in that profile: `CODEX_HOME=<scratch>/p9-codex codex login`. If a scratch login
   is impractical, run E09 and E13 under `advisor: solo` and mark the Reviewer rows `to verify`.
3. Open the window: `tmux new-session -s p9-reviewer -e HOME=$HOME -e CODEX_HOME=<scratch>/p9-codex
   -c <scratch>/p9-starter codex`.
4. First thing in that window, register the Reviewer with its own thread id. The exact line is
   printed by the channel step (`team-mail-setup.sh`, "reviewer:" block) — copy it from there; its
   shape is `python3 -I -B <tool>/agent_mail.py --box <scratch box> register --as Reviewer<suffix>
   --adapter codex-queue --thread <UUID from /status>`. The Codex sandbox needs write access to
   the box's directory and read access to the tool.
5. In the Advisor's session (`p9-advisor`), start the push loop as a background task:
   `bash .claude/lib/team-mail.sh <key> deliver Reviewer<suffix>`; liveness:
   `pgrep -f "$(bash .claude/lib/team-mail.sh <key> pattern deliver Reviewer<suffix>)"`.
6. What the Reviewer answers: on an escalation thread, its first reply line is exactly
   `opinion: agree` or `opinion: disagree` (the payload's `## Reviewer` section says when and
   why); it never writes memory and never answers the team directly.
7. Teardown (phase C): `tmux kill-session -t =p9-reviewer` — the `p9-` name only, never
   `kill-server`.
