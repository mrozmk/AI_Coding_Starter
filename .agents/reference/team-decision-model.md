# Reference: team decision model

Who decides a team question, who is only informed, and when the Operator is asked.

Human overview (starter repo only, not installed by `/setup:teams`): `docs/teams/02-decision-model.md`.

In brainstorm and quick mode the **per-run TeamLead** decides. The per-run contract is
[team-lead.md](team-lead.md); this file states who decides and links there.

## 1. Roles

| Role | What it is | Decides |
|---|---|---|
| **Operator** | the human owner of the project | human-only items, as pending decisions (§3) |
| **Supervisor** | the operations session (merges, team start/stop, releases) | operational actions; reads its four inbox events (team-lead.md §3) — never a team question |
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

**Human-only** (`teams.teamlead.human_only`, default `settings-profiles` + `prod-ask`): any edit of
settings or permission profiles, an ask rule the project added beyond the starter's baseline
(`.claude/team/baseline-ask.json` — the production group), egress (`git remote add|set-url`, a
network verb), and an irreversible delete outside the clone or inside its git dir. Deny rules,
destructive SQL and an unreadable prompt are refused for everyone, the Operator included. A
human-only item becomes `runs/<run>/decisions/d-<n>.md` (pending), and the Operator's answer is
recorded in their own words ([team-lead.md](team-lead.md) §7).

**Where the trust ends.** These limits matter when you decide how far to rely on the lead; each is
stated in full in one place:
- an Operator answer is bound to a terminal or a typed message in the lead's window, but that
  binding is not proof that a human answered — [team-lead.md](team-lead.md) §7, "Limit of the human
  binding";
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
to `"off"` or `"on"` in `.agents/team/watch/state.json`) can then switch an enabled class off and on
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
