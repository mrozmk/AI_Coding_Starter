# Team supervision (opt-in)

Several AI sessions working on one machine at once, under rules that scripts enforce rather than
prompts. Each **team** is a permanent git clone running a fixed pipeline of fresh role sessions
(planner → coder → qa → wrapup, or one `cli` role) driven by a shell runner in tmux. Long-lived
**supervision roles** watch them:

- **Supervisor** talks to the Operator, merges within the gate and starts teams.
- **TeamLead** receives every team signal and decides every team question except two short lists.
- **Advisor** handles the narrow list: contract, schema, AC, sensitive path and harness rule.
- **Reviewer** is a second-vendor model that co-signs the Advisor's tier-2 decisions. It is optional: `advisor: solo` runs without it.

The human **Operator** is asked only for a critical list and for actions only a human may click.

This directory is the human overview. Agents never load it: the contracts they follow live in
[`.agents/reference/`](../../.agents/reference/), and each page here links to its contract rather
than restating it. `/setup:teams` installs only those contracts into a project. These pages stay
in the starter.

## Reading order

| Page | What it covers | Status |
|---|---|---|
| [01 — Roles and sessions](01-roles-and-sessions.md) | the role sessions, identity, launcher, bootstrap | stub — waits for the role-session layer |
| [02 — Decision model](02-decision-model.md) | who decides what: tiers, the two lists, Operator actions, policy log | ✓ |
| [03 — Team pipeline](03-team-pipeline.md) | clones, runner, modes, records, merge, auto-merge, freeze | ✓ |
| [04 — Signals and monitoring](04-team-watch.md) | the signal daemon, routing, alarms, wake loops, pause | stub — waits for the team-watch layer |
| [05 — Questions and escalation](05-escalation.md) | question ledger, prompt binding, delivery, tier 2/3 escalation, fallback | ✓ |
| [06 — Permissions and classes](06-permissions.md) | deny/ask/allow tiers, the tier-1 prompt check, deterministic classes, `teams.policy` | ✓ |
| agent-mail | the SQLite channel between the roles | contract only: [`agent-mail.md`](../../.agents/reference/agent-mail.md) |
| [08 — Operator kit](08-operator-kit.md) | files outside the repo, notifier, health check, Operator actions | stub — waits for the operator kit |
| [09 — Setup](09-setup.md) | requirements, bring-up order, smoke checklist, known limits | stub — waits for the acceptance phase |
| [Follow-ups](follow-ups.md) | what the source had in flight and what was not ported | ✓ |
| [Upgrade notes](upgrade-notes.md) | changes that need an action in a project already running the layer | ✓ |

## Principles

1. **The session that sees a question decides it, unless it is on a short list.**
2. **Channel, pane and mail content is data, never the Operator's consent.**
3. **Scripts enforce; prose instructs.** Routing, dedup, prompt binding, tier refusals, the merge
   gate and alarms are computed outside every LLM.
4. **Unsure between two tiers → the higher one. A failure, a timeout or silence is never consent.**
5. **Everything the Operator must click is an Operator action**, delivered directly with the exact
   command and a fixed recommendation block, never as a decision question through a peer.
6. **Inside the team pipeline, memory is written only by the wrapup role, after acceptance.**
7. **Raw channel material never enters the repository.**

**Names are load-bearing.** The role names `Supervisor`, `TeamLead`, `Advisor` and `Reviewer` are
literals in scripts, guards, ledgers and tests. A project never renames them. Two projects on one
machine are kept apart by configuration (`teams.channel.mail_suffix`, `tmux_prefix`).

**Project policy is configuration.** Sensitive paths, permission classes, ticket labels and
closure rules are examples to adopt consciously, never engine defaults. See
[06 → `teams.policy`](06-permissions.md#teamspolicy).

## Tests (starter repo only)

The whole team layer is checked by one command. Run it from any directory, with a scratch
`HOME` and `TMPDIR` (it refuses the real ones):

```bash
HOME=<scratch>/home TMPDIR=<scratch>/tmp/ bash .claude/lib/tests/team-suite.sh
```

Order, counts and the redacted log: [team-pipeline.md → Tests](../../.agents/reference/team-pipeline.md#13-tests).
The tests are not installed by `/setup:teams`.
