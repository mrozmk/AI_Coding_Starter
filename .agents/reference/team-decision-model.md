# Reference: team decision model

Who decides a team question, who is only informed, and when the Operator is asked. The tier table
is canonical in [team-mode.md](team-mode.md) §10 (one copy; edit it there); this file refines its
rows. Mechanics: [team-questions.md](team-questions.md); the Advisor no-reply fallback:
[escalation-fallback.md](escalation-fallback.md).

Human overview (starter repo only, not installed by `/setup:teams`): `docs/teams/02-decision-model.md`.

## 1. Roles

| Role | What it is | Decides |
|---|---|---|
| **Operator** | the human owner of the project | the critical list (§3), Operator actions (team-mode.md §10) |
| **Supervisor** | the session that runs the project's operations: merges after the gate, team start/stop/queue, releases, incidents | operational actions — never a team question |
| **TeamLead** | the session running `/monitor`: sees every team question | every team question outside the two lists below |
| **Advisor** | the analyst session (narrow list) | the Advisor list (§3), with the Reviewer |
| **Reviewer** | an independent second analyst (another model or session) | nothing alone; its opinion is the second voice of a tier-2 decision |

Role names in code and ledgers are exactly these four (plus `TeamLead-fallback` as the author of a
fallback delivery). A project that runs several projects' sessions on one machine distinguishes
them by configuration (a mail suffix), never by renaming the roles. In a one-window setup the same
session is Supervisor and TeamLead; the model still applies, only the hops disappear.

## 2. Principle

**The session that sees the question decides it, unless it is on a short list.** The TeamLead sees
every team question, so it decides them; the Advisor gets a narrow list; the Operator gets only the
critical list. Two rules always hold: unsure between two classes → the higher one; a failure, a
timeout or silence is never consent.

## 3. Decision model

| Question type | Decider | Reviewer | Time limit | Past the limit | Informs |
|---|---|---|---|---|---|
| Implementation choice inside spec/plan | TeamLead | n | immediate | — | one line in the TeamLead window + `## Supervised decisions` |
| Planner design question inside the ticket AC | TeamLead | n | immediate | — | as above |
| Choice between plan variants that keep the AC | TeamLead | n | immediate | — | as above |
| 🔶 rethink signal that changes the approach but keeps the AC | TeamLead | n | immediate | — | as above + policy log |
| `/quick-change` Phase 0 hit on **size only** (no sensitive path, contract, schema, dependency) | TeamLead | n | immediate | — | as above + policy log; every other Phase 0 hit is an Operator override |
| Wrapup menu: follow-up ticket apply/skip | TeamLead | n | immediate | — | notification; the wrapup creates the ticket (labels per `teams.policy.tickets`) |
| Wrapup menu: `domain/*`, `errors.md`, `api.md` entries that do not alter a historical decision | TeamLead | n | immediate | — | notification |
| QA `ready-with-warnings` disposition, non-sensitive path | TeamLead | n | immediate | — | READY note line `QA warnings: accepted by TeamLead — <ref>` |
| Permission prompt matching the plan and no ask/deny rule | TeamLead | n | immediate | — | team-mode.md §10 rule |
| Ask-tier permission prompt in an enabled deterministic class (`team-question.sh <team> policy <role>` prints `class: <name>`) | TeamLead | n | immediate | — | class in the ledger and the notes; one line in "TeamLead decisions" |
| Stale human draft in a role pane | TeamLead | n | immediate | — | notification (`draft saved: <path>`) |
| Merge after READY (auto-merge gate) | Supervisor | n | on READY | gate refusal → Operator `Merge <team>?` | one line to the Operator |
| Team start/stop, queue order, clones, next ticket in the agreed order | Supervisor | n | immediate | — | one line "start <team> on <key> (path — why)" |
| Contract / schema / AC change of the ticket (an AC change that keeps the ticket's goal) | Advisor | y | 30 min | re-ping (cap 2), then the team stays blocked — **never auto-proceed** | question in the TeamLead flow |
| Sensitive path per `CLAUDE.md → Validation`, a production safety boundary, customer data | Advisor | y | 30 min | as above | as above |
| QA `ready-with-warnings` on a sensitive path | Advisor | y | 30 min | as above; the PR stays unmerged | as above |
| `decisions.md` entry, `patterns.md` rule, `index.md` routing row, harness rule change, any other memory entry outside the TeamLead memory row | Advisor | y | 30 min | **non-blocking**: the team continues without the entry; a wrapup (B) question closes as skip on the Advisor's NO-REPLY and its entries are deferred through the READY note (`monitor.md` 4(e)) | notification |
| TeamLead disputes an analysts' answer | Advisor | y | 30 min | Operator list (an analyst disagreement) | question to the Operator |
| Permission change (allow/ask/deny, profiles, permission mode, a class switch) | Operator | — | none | — | question |
| Production action outside standing approvals (restart, deploy, destructive SQL) | Operator | — | none | — | question |
| Irreversible decision (data loss, destructive migration, deleting a resource) | Operator | — | none | — | question |
| Developer-only override other than a size-only Phase 0 hit | Operator | — | none | — | question |
| Safety-rule change (egress, "never" rules) | Operator | — | none | — | question |
| Release, cost / limits (incl. a model/effort change), analyst disagreement, new business epic, product behaviour change | Operator | — | none | — | question, both positions + recommendation where analysts disagree |
| Status-quo refusal of a widening (e.g. a standing approval of an interpreter) | the session that met it | n | immediate | — | **not a question**: refuse, keep the permission, one line to the Operator |

**Memory acceptance.** Whoever accepts a memory entry or hand-off applies
`.agents/memory/reflection-protocol.md` → The bar; the default answer is skip. That is the decider
the rows above name for that file, or the developer in the window. A recommendation without
`czytelnik:` (a `When to Read` row) is skipped. In the wrapup, (A) is the TeamLead group and (B)
the Advisor+Reviewer group (`prompts/wrapup.md`).

**"TeamLead decisions".** The TeamLead decides alone; at the end of a run its READY summary lists
design decisions inside the AC, the QA-warnings disposition, a Phase 0 override, accepted and
deferred memory entries, class approvals and a settings change of the PR. The Supervisor passes on
to the Operator only what matters. This is a notification, not a question.

**Sensitive vs. inside-AC.** "Production safety" means code that acts on production (restart,
deploy, data writes) **when the question moves its safety boundary** — a threshold that permits a
restart, a kill switch, a rollout flag, removing a guard. A design question that keeps or
tightens that boundary is inside the AC and stays the TeamLead's. Unsure → the higher class.

**Deterministic classes.** `team_prompt_classes.py` knows `merge-line` (a `git merge --no-ff
origin/<line>` into the team's working branch), `allow-offline` (a settings edit adding only
offline single-file allow entries for files in the ticket diff), `add-ask` (a settings edit adding
only ask entries) and `prod-diagnose` (a read-only diagnose script from a directory the project
names in `teams.policy.classes.prod_diagnose`). Every class is **off until the profile enables it**
(`teams.policy.classes.<name>.enabled: true`); the Operator's word (`team-watch.sh mode class <name>
on|off`) can then switch an enabled class off and on again, never enable a disabled one.

**Advisor no-reply fallback.** A tier-2 escalation in an eligible class (`analysts-condition`,
`plan-variant`, `borderline`, `policy-deviation`) closes without the Advisor when the wait times
out and the newest Reviewer message on the thread opens with `opinion: agree`, newer than the
request, over the TeamLead's recorded recommendation. The script decides, the TeamLead delivers,
marked `fallback: Advisor no-reply` (`--author TeamLead-fallback`). Critical classes (`ac`,
`contract`, `schema`, `sensitive`, `harness-rule`, `conflict`, unclassified) and every q with
`waiting: operator` never fall back. Under `teams.channel.advisor: solo` the fallback is off by
design (reason `advisor solo`): there is no Reviewer, and every tier-2 question waits for the
Advisor.

**Tickets from recommendations.** The Supervisor and the Advisor create technical tickets without
asking (wrapup follow-ups, QA findings, analysis). Each carries the recommendation line —
`teams.policy.tickets.recommendation_line` from the profile, else "Created from a recommendation —
the Operator verifies it when the work starts" — and the Operator verifies it when the work
starts. Labels (`auto_label`, `path_labels`) only when the profile sets them; absent → no label. Search the tracker for a duplicate first; no ticket for cosmetics. In a
wrapup the wrapup role creates the ticket after the selection; outside a wrapup the TeamLead asks
the Supervisor or the Advisor.

## 4. Policy log

Policy-class answers (Phase 0 size, memory, deferred memory, QA warnings, rethink) are recorded
append-only in `teamlead-policy-log.md` in the team channel's decisions directory (no channel: the
main checkout's `.agents/team/decisions/`), one line `- <UTC> [<class>] <decision> — <why> — <team>
<q id>`. The TeamLead reads it before classifying, so two teams get the same answer to the same
case; a deviation from a live precedent goes to the Advisor as blocking tier 2. Two writers,
two scopes: the TeamLead is append-only and the only writer of decision and revocation lines; the
Advisor's one exception is promotion — it moves a recurring entry to `decisions.md` through a PR
and replaces exactly that entry's line with a `[promoted]` pointer, after which it is a rule
([team-advisor.md](team-advisor.md) §3). Format and procedure: `monitor.md` → Policy log.

## 5. The route to the Operator

- Operator actions (team-mode.md §10) — directly in the TeamLead's window (`PushNotification` +
  the block), never as a decision question and never through the Supervisor.
- Operator-list decisions — through the Advisor (`team-escalate.sh` tier 3); the Advisor relays
  `decided-by: operator` + a verified `operator-ref`.
- Merge stays with the Supervisor: the decider of a team's questions does not also merge their
  result; QA and the cross-model review stay the independent gate. The release freeze flag
  `.agents/team/release-freeze` stops the auto-merge gate.

## Targets (not implemented)

- Per-class deadlines: a blocking Advisor-list question past 60 min goes to the Supervisor for the
  Operator's list; a non-blocking one past 30 min becomes a Follow-up. Until then the NO-REPLY rule
  of team-mode.md §10 applies (re-ping ≤ 2, then wait without a deadline), except the wrapup (B)
  memory case (monitor.md 4(e); Transitional supervision rules — the scripts do not enforce them.)
- One `ADVISOR silent` signal per episode: a critical q that times out later in the same episode
  raises no new notification.
