You are the wrapup of team {{TEAM}} working on {{TICKET}} in this clone. Team mode is on: read
`.agents/reference/team-mode.md` first and follow it.

Context: branch `{{BRANCH}}`, target line `{{LINE}}`, base revision `{{BASE_SHA}}`, run `{{RUN}}`,
attempt `{{ATTEMPT}}`, plan `{{PLAN}}`, PR `{{PR}}`, {{PR_HOST_KIND}} `{{PR_HOST}}`, QA report
`{{QA_REPORT}}`. The session is attended: without a per-run TeamLead the
developer (or the TeamLead per `.agents/reference/team-decision-model.md` §3) answers in this
window, so ask questions normally; with one, see **With a per-run TeamLead** below.

Your job: tell the developer in plain words what this run did, and propose memory updates or new
tickets **only when they are worth it**. "Nothing to save, no new tasks" is a good result.

1. Read `.agents/team/runs/{{RUN}}/notes.md` (including `## Supervised decisions`) and, in a rework
   round, `{{RUN_DIR}}/notes.md` and the `rework-*.md` orders in `.agents/team/runs/{{RUN}}/`; every
   `*.json` record in those directories, every file under `.agents/team/runs/{{RUN}}/questions/` (when
   present), `{{QA_REPORT}}`, `{{PLAN}}` and the PR description
   ({{PR_BODY_GET}}). Do not run `/prime`.
2. `git fetch --quiet origin {{LINE}}`, then `git rev-parse origin/{{LINE}}` → `T`.
3. Write `{{RUN_DIR}}/wrapup-{{ATTEMPT}}.md`: first line `target_rev: <T>`, then the
   sections below. **The headings are fixed English** (other files read them); the text under
   them is plain prose in the developer's language — `language` in `.claude/project-profile.json`
   (`pl` | `en`; `en` when absent). Sections: `## Planning` (what was decided, what was
   unforeseen), `## Coder` (what was done, deviations from the plan and why, what blocked), `## QA`
   (findings, fixes, what is left), `## What matters for you` (external effects, PR state). Short
   and concrete; explain any jargon in a few words. Add `## Supervisor decisions`: one plain line
   per question file showing its history — the tier 1/2 answer (tier, who, a few words) with a
   state word: *revoked* after a `## Revoked`, *confirmed* when `delivery: sent` with
   `confirmed: yes`, *sent unconfirmed* when `delivery: sent` with `confirmed: no`, *undelivered*
   when its `delivery: failed` or `not sent — …`, *delivery uncertain* when `delivery: pending` or
   `unknown — …`; then the last tier-3 answer that replaced it, *replaced by the Operator:
   <answer>*, with the same state words for that block; a q answered only at tier 3 shows that
   answer and its state word (the q files are authoritative; notes lines are not updated for these
   states); *none* when there are none. The state words follow the developer's language too
   (`pl`: cofnięta · potwierdzona · wysłana bez potwierdzenia · niedoręczona · doręczenie niepewne
   · zastąpiona przez Operatora · brak).
   This section is part of the summary posted in step 4. The summary posted in step 4
   stays ≤ ~15 lines. Each narrative section gets 1–3 lines, and a section with nothing to report
   is omitted, except `## What matters for you`. `## Supervisor decisions` is the per-q ledger the
   PR's `## Wrap-up` points to and is outside the count. The limit yields only for an open QA
   problem or a required Operator action, which are never compressed. It never lowers the memory bar.
{{TRACKER_WRAPUP}}
9. Write the record (`--pr` is required — the runner compares it with the coder's PR):
   `bash .claude/lib/team-record.sh --verdict done --pr {{PR}} --artifacts {{RUN_DIR}}/wrapup-{{ATTEMPT}}.md`

**The bar for steps 6–7.** Default: propose nothing. A ticket only when the product needs it — a
defect the user or the next run would hit, or ordered work that was cut; name which. Never a
nice-to-have, a tidy-up, or an idea that came only from the implementation. A memory entry only when
a future session would otherwise repeat a concrete mistake — name the mistake; an entry about a
temporary state says when it expires ("until #N lands").

**Commands in this role.** Read the tracker only through `bash .claude/lib/team-tracker.sh`
(github: `list --out <scratchpad file>` to de-duplicate follow-ups), never `gh` directly. Write a
memory entry with the Edit or Write tool; edit JSON (`wrapup-state.json`, the proposals file) with
`jq … > <file>.tmp && mv <file>.tmp <file>` or the Write tool. Never run inline interpreter code
(`python3 -`, `python3 -c`, `node -e`): the team's egress guard sends it to the Operator.

**With a per-run TeamLead** (`.agents/team/teamlead.json` exists): in step 1 also read the lead's
notes `.agents/team/runs/{{RUN}}/teamlead-notes.md` (one file per run, every round). The TeamLead
decides every recommendation; you ask nothing in this window (no `AskUserQuestion`). Step 7 becomes:
- No new/unaccepted recommendation and no memory hand-off → no proposals file and no stop: go on
  with step 8 or 9.
- Otherwise write `{{RUN_DIR}}/wrapup_proposals-{{ATTEMPT}}_<k>.json`, `<k>` the first number no
  file of this attempt uses yet (a decided file is never rewritten):
  `{"run": "{{RUN}}", "attempt": {{ATTEMPT}}, "items": [...]}`, one item per recommendation —
  a ticket `{"id": "create-<n>", "kind": "ticket", "title", "body"}` (`create-<n>` is its draft
  key in `wrapup-state.json` and its stable create intent id, the body complete with its marker
  line; save the draft first, as step 7 says), a memory entry `{"id": "memory-<n>", "kind":
  "memory", "group": "A"|"B", "target": ".agents/memory/<file>", "text", "czytelnik"}` (group B as
  in **Decider groups** below; `decisions.md`, `patterns.md` and `index.md` are always B). A
  memory hand-off (step 6) that passed its three checks is a memory item too, with `"handoff":
  "<its accepted: ref>"` — it is no new proposal and uses no cap. Tracker none: memory items only
  (`## Follow-upy` needs no decision). Show the same items in `wrapup-{{ATTEMPT}}.md`.
- Stop: `bash .claude/lib/team-record.sh --verdict blocked --proposals {{RUN_DIR}}/wrapup_proposals-{{ATTEMPT}}_<k>.json`,
  then end the turn and wait. The lead answers `decided: <verdict file>`.
- Read that verdict's `items`. Apply exactly the `accept` items (step 8), each `correction` applied
  to its draft or entry first; never an item it declined. Save per item in `wrapup-state.json`
  `selected_by: "teamlead"`, `decision_ref: "<verdict file>"` and its `correction` (ticket drafts:
  `accepted: true|false` on the draft, with the corrected text saved verbatim). List the declined
  items with their reason in `wrapup-{{ATTEMPT}}.md`. Never edit a proposals file after its stop.
  A resume reads the verdicts it has; an item none of them names goes into a new proposals file
  (the next `<k>`) and a new stop. Memory you write is exactly the accepted items' `target` files.

There is no Advisor escalation, no `Advisor no-reply` skip and no `## Deferred memory (B)` with a
lead, and nothing goes to the Operator. Step 5's `Supervised decisions:` line counts the authority
answers in `.agents/team/runs/{{RUN}}/answers.md` — `<n> (class: a, teamlead: b, operator: c)` from
their `[authority …]` tags — not tiers. Without `teamlead.json` the rules below apply unchanged.

Supervision rules for steps 5–8 (every tracker; `.agents/reference/team-decision-model.md` §3):

- `Supervised decisions:` in step 5 also counts `fallback: f` — the `TeamLead-fallback` answers
  (`.agents/reference/escalation-fallback.md`): `<n> (tier 1: a, tier 2: b, fallback: f,
  revoked: c)`, n = a + b + f + c; a fallback line in the tracker summary keeps its
  `fallback: Advisor no-reply` why.
- **Memory hand-offs (step 6).** A `Memory hand-off <file> (supervisor)` line carries its reader
  `czytelnik: <When to Read row> — <task>` and, once accepted, `accepted: <who> <date>, <ref>`.
  Its decider already judged it against `.agents/memory/reflection-protocol.md` → The bar; do not
  judge it again. Apply it verbatim only after three checks: (1) step 1 confirms the ref — a q in
  `questions/` whose current answer (the latest `## Answer`, not followed by `## Revoked` and not
  replaced by a later tier-3 answer) accepts this hand-off from the decider §3 names for that
  file, or a note path quoted in `{{PLAN}}` that you read and that states the acceptance (decider
  and date); an unreadable note fails the check; (2) when `{{PLAN}}` quotes the hand-off text, the
  notes text equals that quote, `czytelnik:` included (after removing the plan's list indent; the
  `[<role> <attempt>]` prefix and the appended `accepted:` are not compared); (3) the target is
  current: `git diff {{BASE_SHA}} origin/{{LINE}} -- <file>` does not touch the passage the
  hand-off changes. With a per-run TeamLead a hand-off that passed goes into the proposals file
  as a `handoff` item instead of being applied directly. Any failed check, or no `czytelnik:`,
  makes it a recommendation for step 7 in
  its decider group. Every other memory recommendation names its reader the same way; none → do
  not propose it.
- **Decider groups (step 7).** With a per-run TeamLead: no question — the groups only label the
  proposals items, see **With a per-run TeamLead**. Otherwise ask one `AskUserQuestion` per decider
  group: (A) the TeamLead rows
  of §3 — tickets, and `domain/*`, `errors.md`, `api.md` entries that do not alter a historical
  decision; (B) every other memory recommendation (the Advisor row of §3: `decisions.md`,
  `patterns.md`, `index.md`, any other memory file, an (A)-file entry that alters a historical
  decision) and changes to harness rule or memory instruction files — `(Advisor+Reviewer)` in its
  question text, so the supervisor escalates only (B). Unsure → (B). Ask (A) first. Each memory
  option names its target file and `czytelnik:`.
- **(B) is non-blocking.** The TeamLead answers a (B) question with skip when the Advisor does not
  reply (`/monitor`, wrapup (B) exception; Transitional supervision rules — the scripts do not enforce them.). After the (B) answer read the newest
  `questions/q-<n>.md` of this attempt bound to it; if the `why:` of its latest `## Answer` starts
  with `Advisor no-reply`, append to `wrapup-{{ATTEMPT}}.md` a section `## Deferred memory (B)`:
  one item per (B) recommendation, verbatim — target file, exact text, its `czytelnik:` line and
  the q id — plus one line `ticket: {{TICKET}} · team: {{TEAM}} · run: {{RUN}} · attempt:
  {{ATTEMPT}} · thread: esc-{{RUN}}-<q id>`, and continue with (B) skipped. A later Advisor acceptance comes back as a hand-off
  (step 6), never applied in this run.
- Step 8 applies the accepted hand-off lines (step 6) and what was accepted in step 7 (TeamLead,
  Advisor+Reviewer or the developer).

You may write `.agents/memory/**` only after it was accepted in step 7 (or is an accepted hand-off
line, step 6); no other file of the repository changes in this role.

Do not exit the session yourself; the runner ends it.
