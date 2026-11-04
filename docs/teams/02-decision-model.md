# 02 — Decision model: who decides what

**Contract:**
- [`team-decision-model.md`](../../.agents/reference/team-decision-model.md): the detail table, memory acceptance, deterministic classes, the policy log.
- [`team-mode.md` §10](../../.agents/reference/team-mode.md#10-escalation-tiers): the tier table (canonical, one copy) and the Operator actions.

This page explains the model. When it and a contract disagree, the contract wins.

## The principle

**The session that sees the question decides it, unless it is on a short list.**

- The TeamLead sees every team question, so it decides them.
- The Advisor, with the Reviewer, gets a narrow list.
- The Operator gets only the critical list.

Two rules always hold:

- Unsure between two classes, pick the higher one.
- A failure, a timeout or silence is never consent.

The model was not designed on paper. The project it was ported from ran one supervisor session that asked the Operator everything. Over four days the Operator was asked six questions and answered all six "as recommended". Every analyst question cost the waiting team 10–20 minutes. The split moved almost every Operator question away from him and most Advisor questions to the TeamLead. The only questions still sent to the expensive analyst pair are the ones where a second model's opinion matters.

## The tiers at a glance

| Tier | Decides | What lands there |
|---|---|---|
| 1 | TeamLead | everything not listed below: implementation choices inside the plan, design inside the AC, plan variants that keep the AC, QA warnings on ordinary paths, menus, permission prompts that match the plan and no ask/deny rule |
| 2 | Advisor + Reviewer | contract / schema / AC change that keeps the ticket's goal, a sensitive path, `decisions.md` / `patterns.md` / `index.md` / harness rules, a dispute between the TeamLead and the analysts |
| 3 | Operator | permission changes, production actions outside standing approvals, irreversible decisions, developer-only overrides (except a size-only Phase 0 hit), safety-rule changes, release, cost and model choices, analyst disagreement, new business scope |
| — | Supervisor (not a tier) | operations: merge after the gate, starting/stopping teams, queue order, releases |

**Sensitive vs inside-AC.** A question about production safety is tier 2 only when it **moves** the safety boundary, for example a threshold that permits a restart, a kill switch, a rollout flag or removing a guard. A design choice that keeps or tightens the boundary stays the TeamLead's.

**Which paths are sensitive** is the project's own list: `CLAUDE.md → Validation → Test policy`, or `teams.policy.sensitive_paths` when set ([06](06-permissions.md#teamspolicy)). In v1 the list is an input to the TeamLead's and Advisor's judgement. It is attested, not enforced by a script.

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

These go to the Operator **directly from the session that met them**, as a push notification plus one fixed block. They never travel as a decision question through a peer:

```
<team / ticket / window>
<the exact command or screen>
Recommendation: <one line>
Why: <one line>
Risk: <one line>
```

## Tickets from recommendations

The Supervisor and the Advisor create technical tickets without asking: wrapup follow-ups, QA findings, analysis results. The TeamLead does not create tickets; its tickets come from the wrapup menu. Every such ticket:

- is searched for a duplicate first;
- carries a recommendation line saying the Operator verifies it when the work starts;
- gets a label and a path label only when the project configures them (`teams.policy.tickets`).

Cosmetic changes never get a ticket.

## The policy log

Some tier-1 answers set a precedent: a size-only Phase 0 override, a memory entry, a deferred memory entry, a QA-warnings disposition or a rethink. The TeamLead records each one append-only in `teamlead-policy-log.md`, in the channel's decisions directory. Before answering a question in the same class it reads the log:

- a live precedent gets the same answer;
- a deviation from a precedent becomes a blocking tier-2 question.

**Who may write the log.** The TeamLead appends decision and revocation lines and never rewrites one. The Advisor may replace exactly one promoted entry with a `[promoted]` pointer when it moves that conclusion into `decisions.md` through a PR. These are the only two writers, and their scopes are the ones just stated.

## What is a target, not behaviour

The per-class deadline overflow is an agreed **target**, not running code: a blocking Advisor-list question past 60 minutes would go to the Supervisor for the Operator's list, and a non-blocking one past 30 minutes would become a follow-up.

What runs today:
- the escalation adapter's timeout on each send and on the first reply;
- at most two delivered re-pings, then a wait without a deadline;
- the Advisor no-reply fallback for eligible classes ([05](05-escalation.md#when-the-advisor-is-silent)).

See [follow-ups](follow-ups.md) F6.
