# Reference: team decision model

Who decides a team question, who is only informed, and when the Operator is asked.

Human overview (starter repo only, not installed by `/setup:teams`): `docs/teams/02-decision-model.md`.

In brainstorm and quick mode the **per-run TeamLead** decides. The per-run contract is
[team-lead.md](team-lead.md); this file states who decides and links there.

## 1. Roles

| Role | What it is | Decides |
|---|---|---|
| **Operator** | the human owner of the project | human-only items, as pending decisions (§3) |
| **Supervisor** | the operations session (merges, team start/stop, releases) | operational actions; reads its four inbox events (team-lead.md §3) — never a team question, except a decision the Operator's mandate covers, as their delegate (§3 → Mandate) |
| **TeamLead** | one session per team run, launched by the runner, gone when the run ends | every team question of its run on an authority: gates, prompts, stops, menus, acceptance, rework |
| **Codex** | a second-opinion call the lead makes (`codex-bg.sh`), not a session | nothing; its opinion is cited in the lead's `--why` |

Stage → TeamLead → Operator: a stage's question reaches its run's lead (doorbell); the lead decides,
or opens a pending decision for a human-only item, which notifies the Operator once. The Advisor and
the Reviewer are not on this path.

## 3. Decision model

### Authority (per-run TeamLead)

Every answer the lead sends to a stage names an authority and lands in `runs/<run>/answers.md`
([team-lead.md](team-lead.md) §6):

| Authority | Who decides | When |
|---|---|---|
| `class` | the runner, before the lead is rung | a prompt in an enabled deterministic class (below) — no lead turn |
| `teamlead` | the run's lead | everything that is not human-only: permission prompts, menus, stops, gates, acceptance, rework within the budget |
| `operator` | the Operator, through a pending decision the lead relays | human-only items; the lead never approves one itself |
| `supervisor (delegated)` | the Supervisor, under the Operator's mandate, through the same pending decision | only a decision whose class the mandate in force names (Mandate, below); never recorded as `operator` |
| `supervisor (cleared)` | the Supervisor, through a clearance request a hook filed (#323, [security-egress.md](security-egress.md) → Supervisor clearance) — no decision, no lead turn | only a request of a Supervisor-clearable class, under the Operator's typed switch (enforce); script-checked yes / no / unsure, claimed once by the asking hook; apart from `supervisor (delegated)` and never recorded as `operator` |

**Human-only** (`teams.teamlead.human_only`, default `settings-profiles` + `prod-ask`): any edit of
settings or permission profiles, an ask rule the project added beyond the starter's baseline
(`.claude/team/baseline-ask.json` — the production group), egress (`git remote add|set-url`, and
— #322 — what the effect classifier gives `deny`, `operator` or `ask`; a `pass` read is no egress,
`security-egress.md` → Effect classes), and an irreversible delete outside the clone or inside its
git dir. The lead may itself deny or reformulate an unbound egress ask (`--deny … --authority
teamlead`, `team-lead.md` §6); an allow stays the Operator's, also as one batch decision (§7). Deny rules,
destructive SQL and an unreadable prompt are refused for everyone, the Operator included. A
human-only item becomes `runs/<run>/decisions/d-<n>.md` (pending), and the Operator's answer is
recorded in their own words ([team-lead.md](team-lead.md) §7).

**Mandate — the Operator delegates a class to the Supervisor.** Off by default. The mandate is the
Operator's typed message in the Supervisor window, the whole message exactly `mandate
<class>[,<class>…] for <N>h|<N>d team <name>[,<name>…]` (at most 7 days); `team-mandate.sh grant`
records it in one local file in the main checkout, `.agents/team/mandate.json` — outside every
clone and outside git, a record and a cache: every use derives the mandate again from the message.
The latest instruction governs (a later grant replaces, the typed `revoke mandate` cancels; a
history that cannot be read whole grants nothing), a grant covers each named team for the exact
run id it showed back, and a new Supervisor session ends it. A pending decision bound to an ask whose class the mandate names goes to the Supervisor's
inbox instead of notifying the Operator; the Supervisor answers it as a delegate, never as the
Operator, or hands it back.

| Class | Covers | Delegable |
|---|---|---|
| `no-rule`, `lead-unsure` | a question, a plan or a lead-tier prompt the lead escalated with that reason | when named |
| — | every operator-tier request (a settings or profile edit, a production ask, an irreversible delete, egress — the #322 classifier's non-pass kinds), a deny rule, destructive SQL, a path outside the clone; a plan gate, an abandon decision, a stop, any decision bound to no ask; an escalation with another reason | never — a human-only gate is not overridden |

A delegated answer is refused wherever a binding cannot be established — the sender (the registered
Supervisor session and its own standalone call, whose argv names the run, the decision, the ask,
the stage's attempt and session, the request's digest and the reply), the mandate the decision was
routed under, its class, team and run — and it is checked again when the stage consumes it,
against the live input of that very event and the mandate in force then: an expired, revoked or
replaced mandate, a rotated Supervisor session, a replayed or stale answer, a changed request, an
answer for another run are refused and the decision returns to the Operator. It is logged apart
from the Operator's answers (`answers.md` `[authority supervisor (delegated)]`, the decision's
`answered_via: supervisor-delegated`, `team-mandate.sh answers`) and is no Operator touch. In a run
that has been under a mandate at any point, an answer counts as the Operator's only on positive
human evidence (their typed message or their dialog answer) for the rest of that run, never
because delegation markers are absent or the mandate has ended
([team-lead.md](team-lead.md) §7, [roles/supervisor.md](roles/supervisor.md) → Mandate).

**The order brief decides first.** A stage question the order brief already settles (a `[D]` line,
a decision-log row, an ordered or `Not ordered` item) is answered by the lead with the brief's
option (`authority: teamlead`, `why: brief: <line>`), also when the stage recommends otherwise. It
reaches the Operator only when the lead itself finds a material conflict, a constraint that changed
since the brief was written, or a requested scope change.

**Human-only is the act, not the plan.** The classes above gate the request when a stage makes it
(the settings edit, the network or install command the #322 classifier does not pass). Planning a step that will need such an
approval is the lead's to answer: a planned future egress is not human-only, including the step
grants nothing, and a prerequisite denied later means a blocked stage or a replan.

**Where the trust ends.** These limits matter when you decide how far to rely on the lead; each is
stated in full in one place:
- an Operator answer is the lead's `AskUserQuestion` dialog — a lead starts only when nothing
  else can answer that dialog: the settings' hooks and every enabled plugin's hooks are inventoried
  before the start (`/start-team`, the runner), and unclean or unknown refuses the start with the
  cause and the fix. The lead never asks for a typed reply; a terminal stays the documented route
  (`team-lead.sh decision answer`), and words typed in the lead's window on the Operator's own are
  still recorded. None of these bindings is proof that a human answered —
  [team-lead.md](team-lead.md) §7, "Provenance guard", "Plugin inventory" and "Limit of the human
  binding";
- the mandate and a delegated answer rest on transcripts and files of one user account (the
  same-account model, the Operator's decision 2026-11-25): the checks are aimed at clone-side roles
  and a drifting Supervisor model, a same-account process that forges a transcript is out of
  scope; every operator-tier request stays out of a mandate's reach either way
  ([roles/supervisor.md](roles/supervisor.md) → Mandate, with the controls and the gaps);
- the verdict guard (`guard-team-verdict.sh`) sees the command text only — a write of a verdict file
  by other means is not caught ([team-lead.md](team-lead.md) §4);
- the rework budget counts verdict and decision files the lead itself can write
  ([team-lead.md](team-lead.md) §9);
- pushes made inside the team scripts (the runner, `team-integrate.sh`) are outside the push hook,
  which guards a session's own `git push` only.

**Memory acceptance.** Whoever accepts a memory entry or hand-off applies
`.agents/memory/reflection-protocol.md` → The bar; the default answer is skip. A recommendation without
`czytelnik:` (a `When to Read` row) is skipped. In the wrapup, (A) is the TeamLead group and (B)
the Advisor+Reviewer group (`prompts/wrapup.md`). A standards item (target
`docs/coding-standards.md`) is accepted like a group B memory entry: same bar, Codex opinion, at
most one per run (team-lead.md §10).

**Deterministic classes.** `team_prompt_classes.py` knows `merge-line` (a `git merge --no-ff
origin/<line>` into the team's working branch), `allow-offline` (a settings edit adding only
offline single-file allow entries for files in the ticket diff), `add-ask` (a settings edit adding
only ask entries) and `prod-diagnose` (a read-only diagnose script from a directory the project
names in `teams.policy.classes.prod_diagnose`). Every class is **off until the profile enables it**
(`teams.policy.classes.<name>.enabled: true`); the Operator's word (a hand edit of `classes.<name>`
— the hyphenated name, e.g. `merge-line` — to `"off"` or `"on"` in `.agents/team/watch/state.json`) can then switch an enabled class off and on
again, never enable a disabled one.

**Tickets from recommendations.** The Supervisor and the Advisor create technical tickets without
asking (wrapup follow-ups, QA findings, analysis). Each carries the recommendation line —
`teams.policy.tickets.recommendation_line` from the profile, else "Created from a recommendation —
the Operator verifies it when the work starts" — and the Operator verifies it when the work
starts. Labels (`auto_label`, `path_labels`) only when the profile sets them; absent → no label. Search the tracker for a duplicate first; no ticket for cosmetics. In a
wrapup the wrapup role creates the ticket after the selection; outside a wrapup the TeamLead asks
the Supervisor or the Advisor.

## 4. Policy log

**Per-run TeamLead:** no policy-log line. The lead keeps `runs/<run>/teamlead-notes.md` (order
ambiguities, no-rule questions, gate misses, Operator cases with the tuning question, late answers),
appended once per run to the main checkout's `.agents/team/teamlead-log.md` at merge or close
([team-lead.md](team-lead.md) §10).

## 5. The route to the Operator

**Per-run TeamLead:** the Operator receives exactly four event types, all through
`.claude/lib/notify.sh`. The runner sends two — `human_decision` (a pending decision) and
`abandon_decision` (the lead recommends abandoning a run past its rework budget), each once per
verdict, answered in the `<team>-lead` window or with `team-lead.sh decision answer` from a terminal.
The Supervisor's `operator-record.sh` sends `unrepaired_failure` and `release`. Everything else stays between the
stage, the lead and the Supervisor's inbox.

**With a mandate in force** a `human_decision` whose class the mandate names is held: the decision
goes to the Supervisor's inbox (`delegated`) and the Operator is told nothing while the mandate
still covers it. The notification goes out as usual once the mandate expires, is revoked or
replaced, or the Supervisor session rotates; a decision the Supervisor hands back is withdrawn and
the lead opens a new one, which notifies the Operator (§3 → Mandate).
