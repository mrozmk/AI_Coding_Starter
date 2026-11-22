# Coverage — what `/discover` must know before it writes

The coverage table is the control loop of `/discover`: eleven categories, each *Clear*, *Partial*,
*Missing* or *Deferred*. Questions are asked to move a category, never to be thorough; the loop
stops when no **critical** category is *Missing*. Completeness is **this table**, never a numeric
score — a percentage hides which category is the hole.

Ported from spec-kit `/clarify` (coverage taxonomy, ≤5 questions, Recommended option, write-back)
and the discovery method of the BMAD PRD rubric, the pm-skills red team and Kiro specs.

---

## 1. The eleven categories

Critical categories are marked ★ — the Definition of Ready (section 4) refuses a PRD while any of
them is *Missing*.

| # | Category | Clear | Partial | Missing | Produces |
|---|---|---|---|---|---|
| 1 ★ | Functional scope & behaviour | every in-scope capability named, with the one must-work scenario walked end to end | capabilities listed but a flow has gaps or the scenario is implied | no agreed in-scope list or no must-work scenario | PRD §4 Scope, `R-n`, `FL-n` |
| 2 ★ | Domain & data model | main entities, identities and the source of truth for each are known | entities named but identity or ownership unclear for at least one | entities not identified | discovery Entities, `BR-n` |
| 3 | Interaction & UX flow (incl. error / empty / loading) | each `FL-n` has actor, trigger, steps and what the user sees on error, empty and waiting states | happy path known, failure/empty states not | no flow drawn | `FL-n`, `FL-n.Ak` |
| 4 ★ | Non-functional qualities | every applicable ISO/IEC 25010 characteristic has a number + measurement method, or an explicit N/A with reason | some characteristics have numbers, others adjectives ("fast") | no NFR stated | `NFR-n` |
| 5 ★ | Integrations & failure modes | every external system named with direction, auth, limits and what happens when it fails | systems named, failure handling not | an external system is implied but not identified | PRD §10, `R-n` (unwanted), `NFR-n` |
| 6 | Edge cases & failure handling | the known exceptions and overrides are listed with their handling | exceptions named without handling | nobody has asked "what goes wrong" | `BR-n`, `R-n` (IF…THEN) |
| 7 | Constraints & tradeoffs | hard constraints listed; appetite and the cut order are stated | constraints listed, appetite or cut order missing | neither | PRD §4, Release intent |
| 8 | Terminology | every domain term has one definition and the synonyms to avoid | terms used consistently but undefined | the same thing has two names in the material | discovery Glossary |
| 9 ★ | Completion signals | ≥1 `G-n` with a target value and a date; "done" for slice 1 is unambiguous | goals stated without numbers or dates | no success definition | `G-n`, Release intent |
| 10 | Misc / placeholders & vague adjectives | no TBD, TODO, "etc.", or unmeasured adjective ("robust", "intuitive", "scalable") left in a requirement | a few remain, each tracked as `Q-n` | requirements are mostly adjectives | `Q-n`, rewritten `R-n` / `NFR-n` |
| 11 | Stakeholders & decision rights | who uses / pays / approves / operates is named, plus the decision owner and their latency | roles named, decision owner missing | nobody knows who decides | discovery Stakeholders, PRD §3, `Q-n` owner |

*Deferred* is a legitimate fourth status: the category is consciously left for later, by a named
owner, with the reason on the row — never used for a critical category in slice 1.

---

## 2. Asking rules

1. **Derive first.** Read `.agents/sources/`, the repo, existing `docs/PRD.md` / `docs/discovery.md`
   before asking anything. An answer that is on disk is written into the artifact and the question
   is never shown.
2. **Ask only when the answer changes an artifact.** If both plausible answers lead to the same
   PRD and discovery text, do not ask — assume, and log an `A-n` (section 3).
3. **Rank by Impact × Uncertainty.** Impact = how much of the artifact (or which critical category)
   the answer moves; Uncertainty = how far apart the plausible answers are. Highest product first;
   ties go to the critical category.
4. **≤5 questions per round.** One `AskUserQuestion` call holds at most 4 questions, so a round
   is at most two calls (4 + 1); never a third. Bundle only independent questions in one call —
   if an answer would change how a later question is phrased, the later one waits for the next
   round.
5. **Each question has one shape:**
   - a full sentence (not a label),
   - one line of **why it matters** (which category/artifact it moves),
   - a **Recommended** option *first* — the asker's own best guess with its reason — then 2–5
     options; or, for a short free answer, a **Suggested** value the user can accept as-is.
   The user replying "yes" / "ok" accepts the Recommended option.
6. **One disambiguation, free of charge.** An ambiguous reply gets one follow-up in the same round
   that does not count towards the five. A second ambiguity becomes a `Q-n`.
7. **Write-back is immediate**, in two places, before the next round:
   - the log: `- Q: <question> → A: <answer>` under `## Clarifications` / `### Session YYYY-MM-DD`
     in `docs/discovery.md`;
   - the target section: apply the answer to the section the question feeds (`→ feeds:` in
     `.claude/skills/discover/question-bank.md`), **replacing** any text it contradicts — never
     leave both versions.
8. **Stop conditions.** A round is the last when: no critical category is *Missing*, **or** the
   user says they are done. Remaining gaps become owned `Q-n` (blocking or not) or `A-n`, never
   silent.
9. **Never re-ask a product choice the user already made.** The bank is for gaps, not for second
   opinions.

---

## 3. Assumptions log

Anything not asked and not derivable is written down, never carried in the head:

```
- **A-n** — <assumption, one sentence> · confidence H/M/L · owner <role or name> · validate by <date | event>
```

- `confidence` — H: the sources imply it; M: a reasonable default; L: a guess that should be
  tested before slice 1 ships.
- `owner` — who can confirm or refute it.
- `validate by` — a date or an event ("first user interview", "load test of the import").

A confidence-L assumption behind a `G-n` or a critical `R-n` also appears in `## Risks &
pre-mortem`. Every `A-n` is listed in the PRD's Assumptions index (`prd-template.md` §14) by id
only — `docs/discovery.md` holds the text.

---

## 4. Definition of Ready for PRD

A **gate**, not a checklist to tick optimistically: `/discover` does not write `docs/PRD.md` while
any item is open. An item that cannot be satisfied gets either another question round or an owned
`Q-n` with an explicit line `accepted as open by <owner>` — that line is what lets the item count
as satisfied for slice 1.

A run after the PRD exists (`/discover --fault-lines`) that leaves an open blocking `Q-n` not
accepted by its current owner unticks the last item and adds under it, once per `Q-n`,
`reopened by Q-n (fault-line run YYYY-MM-DD) — needs <owner>'s decision`; an existing line for
that `Q-n` stays, its `<owner>` set to the current one. Every run that writes
this list — a full run's Phase 5 too — removes a `reopened by` line once its `Q-n` is closed,
accepted or no longer `blocks slice 1: yes` (a DoR annotation, not an id line), and ticks the
item again only when its predicate holds and no such line remains.

- [ ] Problem, users and the current alternative are stated (categories 1, 11).
- [ ] At least one `G-n` with a target value **and** a date (category 9).
- [ ] Appetite and what gives first when it overruns (category 7).
- [ ] A NOT list — non-goals, each with a one-line rationale (category 7).
- [ ] Stakeholders mapped (uses / pays / approves / operates) and a decision owner named with their
      latency (category 11).
- [ ] The key journey is drawn as a to-be `FL-n` with backbone activities `FL-n.Ak`, `**Critical:**
      yes` on at least one flow, and the business rules it depends on as `BR-n` (categories 1, 3).
- [ ] Glossary consistent — one name per concept, synonyms listed as avoided (category 8).
- [ ] Entity sketch with a source of truth per entity (category 2).
- [ ] A measurable `NFR-n` for every applicable ISO/IEC 25010 characteristic; the rest marked N/A
      with a reason (category 4).
- [ ] Compliance flags resolved, or logged as owned risks (categories 5, 6).
- [ ] Top risks have owners (pre-mortem answered).
- [ ] No critical category (★) is *Missing*.
- [ ] Every open question is an owned `Q-n`, and none of them blocks slice 1 (or the block is
      accepted in writing by the owner).

The ticked copy of this list lives at the end of `docs/discovery.md` (`## Definition of Ready`);
`prd-rubric.md` treats an unticked item as a `blocker`.

---

## 5. Fault lines

The fourth Challenge pass (`/discover` Phase 3, and alone under `/discover --fault-lines`) looks
for what the plan has **not** decided — "someone proposes X — in or out?". The lenses and the
proposal shape live in `.claude/skills/discover/question-bank.md` → Fault lines; these are its
rules.

1. **Principles in.** A full run reads the working state of Phases 0–2 — goal candidates, the
   non-goals list, the critical flow draft, `BR-n`, NFRs, the Source precedence answer, imported
   rows and the user's corrections — and quotes what has no id yet. `--fault-lines` reads
   `docs/PRD.md` (`G-n`, §4 non-goals, the critical-flow `R-n`, `NFR-n`, §3), `docs/discovery.md`
   (`BR-n`) and the active `AD-n` of a published `docs/architecture.md`; a PRD without ids (one
   `/setup:map-codebase` reconstructed) gives quoted lines.
2. **Draft 8–12 proposals**, at least one per lens when the principles give material. Fewer than
   8 only when they do not, and the report says why; never more than 12. Each names the
   principle it tests (an id or a quote) and argues both sides, one sentence each.
3. **Discard only on a deciding record.** A proposal is discarded when an existing record
   decides it — the record is current and states in or out for this proposal, for the same scope
   and horizon — and the report cites it (file + id, or `file:line`). Records: an explicit in/out
   statement anywhere in `docs/PRD.md` (§4 scope lines, an active register id, a `D-n`, or a
   plain sentence elsewhere, cited by line); in `docs/discovery.md` active `BR-n`,
   `## Clarifications` lines and closed `Q-n`; the active `AD-n` of a published
   `docs/architecture.md` (an `AD-n` pointer in memory counts only through that current row);
   `.agents/memory/decisions.md`; the effective source set (`/discover` Phase 0 step 2) and, in a
   full run, the accepted `--import` rows (cite `<path>:<row>`, or the extract's row id) and an
   explicit in/out statement the user made in this session — the opening idea or an answer,
   cited verbatim with where it was said (a pre-filled derivation is not a statement); an
   **Approved** spec's `Assumed in scope despite the non-goal "<bullet>" (decided by <who>)` line,
   for that exact feature only. A later record that explicitly supersedes an earlier one wins; a
   record the project marks retired or replaced (a status note naming its replacement source)
   decides nothing — the named replacement does.
   Superseded or withdrawn ids, a draft architecture and any other spec content decide nothing;
   an inferred statement — hedged ("appears to", "likely") or describing what the code does, as
   a reconstructed PRD does — can motivate a proposal, never decide one. Two records that
   disagree decide nothing — keep one `Q-n` quoting both. An open `Q-n` of any kind asking the
   same decision for the same scope and horizon is not a new proposal: no second id, its id and
   provenance stay. Discards are reported, never written to a file.
4. **Owner.** Every survivor becomes a `Q-n` (line shape: `discovery-template.md` → Open
   questions) with one owner:
   - `team` — the call stays inside the stated goals and non-goals and changes only how or when
     the team delivers;
   - `analyst` — it changes which capability or user is in scope inside the agreed goals; the
     business analyst or product owner decides;
   - `client` — it moves a goal, a non-goal, the appetite or what the client pays for; the
     decision owner named in `## Stakeholders` decides.
5. **Who is asked.** First every fault-line `Q-n` still open from an earlier run, whatever its
   owner, is rechecked against the current deciding records (item 3); one a record now decides
   is closed with ` → resolved by <file id | file:line> (in | out, horizon now | slice 1 | later)`,
   not asked — except an `analyst` or `client` one whose decision `docs/PRD.md` does not carry
   yet: it stays open, the report cites the record, and the full update run of item 7 closes it.
   Then only `team`-owned questions are asked — the new survivors and the earlier ones
   still open — in the session's question round (`/discover` Phase 3 and the mode's step 4 say
   which), ranked with the other questions under §2 (≤5 per round); none when the user has said
   done (§2 item 8). The others are listed for their owner; a `team` question left over stays
   open. The Phase 5 DoR round may ask a blocking `team` one, never an `analyst` or `client` one:
   that one needs its owner's `accepted as open by <owner>` line (§4), or the PRD stays unwritten.
6. **`blocks slice 1`.** `yes` only when, without a decision, the slice 1 already agreed cannot
   be defined, delivered or verified. An optional extension is `no` even when one of its answers
   would touch the critical flow.
7. **Closing.** A `team` answer closes the `Q-n` with
   ` → answered in session YYYY-MM-DD (team: in | out, horizon now | slice 1 | later)` and one
   `## Clarifications` line naming the id and the chosen outcome — a "yes" to the Recommended
   option is written out as that option, never as "Recommended accepted"
   (`- Q: Q-7 — … in or out? → A: out (team, horizon slice 1)`) — and nothing else: unlike
   §2 item 7 it feeds no target section — never a PRD non-goal, never a register id. An answer
   that turns out to move scope leaves the `Q-n` open, re-owned to `analyst` or `client`. Their
   decision later goes through a full `/discover` update run, which closes the `Q-n`
   (` → D-n` or ` → answered in session`), drops it from PRD §13 and records any register
   change; a project with a backlog then reconciles it with `/update-backlog`, as that run's
   report says. PRD §13 follows `docs/discovery.md` by id for every `Q-n` a run touches: a
   closed one leaves it, an open one's row carries its current owner and `blocks slice 1`.
