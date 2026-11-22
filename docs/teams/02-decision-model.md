# 02 — Decision model: who decides what

**Contract:**
- [`team-decision-model.md`](../../.agents/reference/team-decision-model.md): the roles, the authorities, memory acceptance, deterministic classes.
- [`team-lead.md` §6](../../.agents/reference/team-lead.md#6-answering-through-the-ask-channel): the ask channel and its tiers.

This page explains the model. When it and a contract disagree, the contract wins.

## Per-run TeamLead (pilot)

In brainstorm and quick mode the decisions are each run's own TeamLead's: stage → TeamLead → Operator.

- The lead answers every stage question on an **authority**: `class` (a deterministic class, answered by the runner before the lead is woken), `teamlead` (the lead itself) or `operator` (a human-only item, relayed from a pending decision). Every answer lands in `runs/<run>/answers.md`.
- **Human-only** items never get the lead's approval: settings and permission-profile edits, ask rules the project added beyond the starter's baseline (the production group), egress, irreversible deletes outside the clone. Each one becomes a pending decision `[d-<n>]` and one `human_decision` notification. The Operator answers in the `<team>-lead` window.
- A run past its rework budget ends in one `abandon_decision` notification; the Operator answers continue or close.
- There is no policy log for these runs. The lead's notes go to `.agents/team/teamlead-log.md` when the run is merged or closed.
- Where the trust ends (the human binding is not proof, the verdict guard sees command text only, the budget counts files the lead can write, script pushes skip the push hook): [`team-decision-model.md` §3](../../.agents/reference/team-decision-model.md).

A failure, a timeout or silence is never consent.

## Operator actions are not questions

Some things only a human may do:

- click an ask-tier permission prompt;
- allow egress to an unlisted host;
- run a production command;
- merge when the auto-merge gate refuses;
- deploy or release;
- edit `.claude/settings*.json` or a role profile;
- install the operator kit;
- recover a stuck window.

These go to the Operator **directly from the session that met them**, as one line plus one fixed block in that session. They never travel as a decision question through a peer:

```
<team / ticket / window>
<the exact command or screen>
Recommendation: <one line>
Why: <one line>
Risk: <one line>
```

## Tickets from recommendations

The Supervisor and the Advisor create technical tickets without asking: wrapup follow-ups, QA findings, analysis results. The TeamLead does not create tickets; its tickets come from the wrapup's proposals, which it decides alone (default no, at most one ticket and one memory entry per run without a stated reason). Every such ticket:

- is searched for a duplicate first;
- carries a recommendation line saying the Operator verifies it when the work starts;
- gets a label and a path label only when the project configures them (`teams.policy.tickets`).

Cosmetic changes never get a ticket.
