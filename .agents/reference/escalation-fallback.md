# Reference: Advisor no-reply fallback, late-reply wake, orphans

The contract of the tier-2 escalation fallback and its two companions: the late-reply wake and
the bootstrap resume. Code: `.claude/lib/team-escalate.sh`, `team-escalate-lib.sh`,
`team-question.sh` (`orphans`, author guard); the escalation adapter (`escalation.local.json` →
`opinion`, `peek`). The team-watch signals of §6 belong to the team-watch layer and are inert
without it. Tiers and deciders: [team-decision-model.md](team-decision-model.md) §3; escalation
mechanics: [team-questions.md](team-questions.md).

## 1. Purpose

When the Advisor stops answering, the Reviewer may still answer within minutes, but nothing
consolidates the Reviewer's opinion, so team escalations stall until the Operator decides them by
hand — even after the Reviewer already accepted an option. An Advisor reply that arrives after its
waiter exited is lost: nothing wakes the TeamLead, and waiters die with the TeamLead session.

Every class a ticket lists stays critical, AC changes included. The fallback may close only the
four eligible classes below. The script decides, the TeamLead delivers; the Operator is never asked
for an eligible class.

## 2. Classes

`/monitor` 4(c) picks the class **critical-first**: check AC, contract, schema, sensitive/prod
boundary, harness rule and conflict before any eligible class. A deviation from a `[promoted]`
precedent is `harness-rule`; an „unsure → higher” escalation that touches a critical ground takes
that critical class. A missing `--class` is `unclassified`, which is critical.

| Class | Kind | Example |
|---|---|---|
| `analysts-condition` | eligible | the plan deviates from a condition the analysts set earlier |
| `plan-variant` | eligible | a choice between plan variants that all keep the AC |
| `borderline` | eligible | an „unsure → higher” escalation touching no critical ground |
| `policy-deviation` | eligible | TeamLead would answer against a live policy-log precedent |
| `ac` | critical | an AC change, even one that keeps the ticket's goal |
| `contract` | critical | route, DTO, byte enum, SignalR method, AF queue message |
| `schema` | critical | a schema or EF migration |
| `sensitive` | critical | a CLAUDE.md sensitive path, a prod safety boundary, customer data |
| `harness-rule` | critical | `decisions.md` / `patterns.md` / `index.md`, a harness rule |
| `conflict` | critical | an analyst disagreement or an TeamLead–analyst conflict |

**Who vouches for the class.** The code checks only that the label is one of the four eligible
ones; it never reads the question. The payload's `## Reviewer` section therefore makes
`opinion: agree` a second attestation: Reviewer checked this version of the question and the
Recommendation and found no AC, contract, schema, sensitive-path / prod-boundary, harness-rule or
analyst-conflict ground (unsure or a mixed scope counts as one). A ground found →
`opinion: disagree` with the next line `class: <critical class> — <why>`; the ledger records
`opinion: <id> disagree class <c>` and the reason `Reviewer disagree (class <c>)`. Under
`opinion: agree` every body line is a condition and no class line belongs there: a leading
`class: <eligible class>` line is dropped as an attestation, any other class refuses the fallback
(`Reviewer agree names class <c>`). This is an attestation by two agents (TeamLead's label,
Reviewer's check), not a parser: a question both of them misclassify still falls back.

## 3. Trigger and ledger

A fallback is considered only after a Advisor wait timeout (`timeout_min`) and only when all hold:
tier 2; no `retier:` line; no `waiting:` line ever (a q Advisor took to the Operator never
auto-proceeds); no `reply: <id> disagree` ever (that is `conflict`); q `kind` ≠ `permission`;
class eligible; a `recommend:` line; a delivered request (a first `sent: … id <n>`); and the
config's `opinion` and `peek` keys. Then the newest Reviewer message on the thread must open with
`opinion: agree` and its mail id must be greater than the first sent id (the opinion floor).

`--recommend "<send> <text>"` takes `pick:<n>|picks:…|other` on a menu q and `say` on a
`blocked`/`idle` q — the pairs `team-question.sh answer` enforces; a permission q is refused.

Ledger lines (each under `## Escalation`, via the q lock):

- `started: <UTC> tier 2 class <c>`, `recommend: <send> <text>`;
- `waited: <UTC> timeout after <n> min` — on **every** wait timeout, before the decision;
- `opinion: <id> <agree|disagree|unmarked>`, with ` class <c>` when Reviewer named a class that
  refuses the fallback (§2);
- `fallback: Advisor no-reply — Reviewer #<id>` + `outcome: reviewer-fallback`, or
  `fallback: no — <reason>` + `outcome: no-reply — timeout after <n> min`;
- `late: <UTC>`, `outcome: late-<status>`, `outcome: late-none`.

Refusal reasons: `tier`, `retier`, `pending-operator`, `analyst-disagree`, `permission`, `class`,
`no-recommendation`, `no delivered request`, `opinion adapter off`, `peek adapter off`,
`opinion op failed (rc <n>)`,
`no Reviewer opinion`, `Reviewer <disagree|unmarked>`, `Reviewer disagree (class <c>)`,
`Reviewer agree names class <c>`,
`opinion older than the request`, `conditions on multiSelect`, `ledger busy`, `evidence changed`,
`evidence changed (peek timeout | peek failed rc <n> | peek: no EMPTY)`.

**Commit point.** The decision is re-validated holding the q lock right before the fallback is
written: `esc_fallback_check` again, the q still `escalating` (no answer meanwhile), the same
`recommend:` line, a re-read opinion with the same id, still `agree` (bounded by
`TEAM_ESCALATE_OPINION_RECHECK_SECS`, 12 s), and last Advisor's silence proven by one adapter
`peek` (§5, bounded by `TEAM_ESCALATE_PEEK_SECS`, 10 s): no staged reply and an output of exactly
`EMPTY`. A peek timeout, a non-zero exit or no `EMPTY` proves nothing and refuses. Both bounds
together stay under `TEAM_QUESTION_LOCK_SECS` (30 s), so a concurrent `answer` waits rather than
reads busy. Any change → `fallback: no — evidence changed`; a Advisor reply that arrived is then
consumed as usual (`ANSWER`, `waiting: operator`, …). A reply after the commit point is a late
reply (§4).

`timeout_min` is wall-clock minutes: `TEAM_ESCALATE_UNIT_SECS` is honoured only under the smoke
suite's marker `TEAM_SMOKE=1` (`team-smoke-lib.sh`); otherwise a minute is 60 s. The marker is a
test switch against a mistaken env, not a security boundary: whoever sets the env can set it.

An eligible q's wait is bounded on every `--resume` (`timeout_min`), so the opinion is re-checked;
a `waiting: operator` q keeps its unbounded wait.

## 4. Outputs and delivery

`team-escalate.sh` prints `FALLBACK` and exactly three lines, exit 0, only after it wrote them to
the ledger under the q lock (a busy ledger is `fallback: no — ledger busy`):

```
send: <action>
reviewer: #<id>
text: <one line>
```

- Empty Reviewer body (after the marker) → the recommended action and text as is.
- Conditions + `pick:<n>`/`other` → `send: other`; conditions + `say` → `say`. The text becomes
  `<recommendation text> — Warunki Reviewer (#<id>): <body lines joined with " / ">`, whitespace
  collapsed: every condition reaches the role on one line (`--text` refuses newlines).
- Conditions on `picks:…` (a checkbox multiSelect has no `other`) → no fallback.

`/monitor` delivers it: `team-question.sh <team> answer q-<n> --run <run> --tier 2 --author
TeamLead-fallback --why "fallback: Advisor no-reply — Reviewer #<id>" --text "<text>" --send
<send>`. The guard, under the q lock, refuses `TeamLead-fallback` without a recorded
`reviewer-fallback` outcome, and a delivery whose `--send`, `--text` (whitespace collapsed as
recorded, and the recorded text is what is typed) or `--why` id differs from the recorded
`    send:` / `    text:` / `    reviewer:` lines; on a q with that outcome every other tier-1/2
answer is refused — only the Operator's tier 3 may replace it. The marker reaches notes
`## Supervised decisions` (`[tier 2, TeamLead-fallback] … fallback: Advisor no-reply`), `list`
(`fallback=<f>`), the wrapup count (`fallback: f`) and the READY decisions line. `--resume` on an
undelivered fallback is refused.

`--resume` on an answered q (`sent`, `consumed`, `recorded`, `not-sent*`, `failed`, `pending`,
`unknown`, `revoked`) is a **late read**: it waits `TEAM_ESCALATE_LATE_SECS` (120 s), drains any
staged reply first, records it and prints `LATE <STATUS>` + body, or `LATE NONE`. It never
touches `## Answer` / `## Revoked` and never delivers; a different late answer is a conflict
`turn` to Supervisor, never a revoke by itself.

## 5. Adapter `opinion` and `peek` ops

`bash <adapter> opinion "$1" … "$6"` — the same template rules and positionals as `send`/`wait`
(`$1` payload, `$2` team, `$3` role, `$4` qid, `$5` thread, `$6` seq), bounded by
`TEAM_ESCALATE_OPINION_SECS` (60 s). It reads Advisor's and `$SELF`'s inbox
(`agent_mail.py inbox --for <box> --json --limit 0`, no `--unread`), picks the max-id message on
the thread from `Reviewer`, stages it as `<qid>.opinion-<id>.md` next to the payload and prints it
(`mail-id: <id>` + body); nothing when there is none. Read-only: it never acks — Reviewer's mail
to Advisor is Advisor's. Any CLI/JSON failure exits non-zero.

`bash <adapter> peek "$1" … "$6"` — the same template rules and positionals. One pass over the
inboxes `wait` polls: a Advisor reply on the
thread is staged, acked and printed exactly as `wait` does; none → exactly one line `EMPTY`, exit
0; any CLI/JSON failure exits non-zero. `wait` is the same pass in a loop with a 20 s sleep.

## 6. Signals (team-watch layer)

- `escreply:<mail id>` → TeamLead: `ESCALATION <team> <q>: odpowiedź Advisor #<id> bez waitera
  (<state>)` for an unread Advisor reply on an `esc-*` thread whose q has no live waiter;
  `ESCALATION <thread>: odpowiedź Advisor #<id> bez bieżącego q` when no current q matches. Input:
  the `esc_mail.TeamLead` probe; a live waiter suppresses it.
- `advisor-silent:<last Advisor reply UTC | none>` → Supervisor (single routing: the receiver),
  **never reminded**. The episode is defined by ledger facts only: it is open while some escalation
  of any team, in any state, has a timeout after the newest recorded Advisor reply (`answer`,
  `withdrawn`, `pending-operator`, their `late-*` forms — never `late-none`). An Operator answer
  does not end it; only a new Advisor reply does. The screen lists the waiting qs (not answered,
  not a fallback) as `<team> <q> tier <t> class <c>`. Supervisor sends one line to the
  Operator and never answers them.
- `err:esc_mail` — the probe failed or timed out; never read as "no replies".

## 7. Orphans and bootstrap

`team-question.sh <team> orphans` lists qs with no live waiter (`<q>.wait/pid`):

| Reason | When |
|---|---|
| `dead-waiter` | `escalating` or `waiting-operator` |
| `no-reply` | `escalated`, last outcome `no-reply*` |
| `cancelled` | `escalated`, last outcome `cancelled` |
| `staged-reply` | any state with a staged `<qid>.reply-<id>.md` not recorded (wins) |

`escalated:reviewer-fallback` and `escalated:answer` are not orphans: `/monitor` step 3 delivers
them. A fresh TeamLead session starts one background `team-escalate.sh <team> <role> <tier> <path>
--resume` per line; bootstrap never sends (`--reping` stays `/monitor`'s).

## Activation

Nothing is active until the local adapter offers both read operations:

1. Add the `opinion` and `peek` lines from `.claude/team/escalation.local.json.example` to the
   live `.agents/team/escalation.local.json` (with the live adapter path); without either line
   the fallback stays off.
2. The adapter's `send` must print `SENT id=<n>` as its last stdout line (the receipt).

Check: `jq -e '.opinion and .peek and .send and .wait' .agents/team/escalation.local.json`.

## Limits

- Current run only: the snapshot reads the current run's ledgers; an archived run's reply raises
  `bez bieżącego q`, and its silence facts drop out of the episode (the key may shift).
- Reviewer must follow the payload's marker instruction (`opinion: agree|disagree` as the first
  line). Without it no fallback fires — safe, but useless.
- The class is attested, not proven (§2): the script cannot tell a mislabelled critical question
  from an eligible one.
- A mail channel whose sender field is declarative cannot prove who wrote an opinion: the
  adapter's opinion filter trusts the Reviewer's sender name and is no defence against a forged
  opinion.
- One `ADVISOR silent` signal per episode: a critical q that times out later in the same episode
  raises no new notification (team-decision-model.md → Targets).
