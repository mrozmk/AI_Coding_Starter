4. Tracker — the state file `.agents/team/runs/{{RUN}}/wrapup-state.json` (`{}` if absent) makes
   every write safe to retry:
   - **compare the stored identity FIRST, before writing anything.** Read the existing `target` and
     compare it with this run's: `{run: "{{RUN}}", ticket: "{{TICKET}}", repo: "<teams.github.repo>",
     project_id: "<teams.github.project_id>"}` (`repo` and `project_id` verbatim from
     `.claude/project-profile.json`). Never write `target` before that comparison — writing the
     current identity over a foreign file and only then calling it FOREIGN would relabel another
     run's finished intents as this run's.
     - absent or empty file → write a fresh `{target, intents: {}}` with the identity above;
     - `target` equal to this run's → adopt its intents and drafts;
     - anything else (another run, ticket, repo or project, or a missing/malformed `target`) → the
       file is FOREIGN. `mv` it aside to
       `.agents/team/runs/{{RUN}}/wrapup-state.foreign-<UTC timestamp>.json` — discarding its intents
       and drafts — then write a fresh `{target, intents: {}}`. Do not reuse its markers or issue
       numbers, and never "fix" it in place.
     The runner refuses `done` both on a `target` that is not this run's AND on any `done` intent
     whose marker does not carry `{{RUN}}`, so relabelling is not a shortcut — it is a rejection.
   - on start, load its run-scoped drafts and selections (only after `target` matched). Each accepted
     draft is attached to a stable create intent id and contains the complete title, body, marker and
     acceptance. Reuse saved accepted drafts and markers verbatim; never regenerate or renumber them
     on another attempt. Recommendation numbers are display labels only, never intent ids. Only
     new/unaccepted proposals go through steps 6–7.
   - **markers are stable across attempts, and their format is exact.** A marker is
     `[wrapup {{RUN}} <intent id>]` — `[wrapup {{RUN}} comment-1]` for the comment,
     `[wrapup {{RUN}} create-<draft id>]` for a follow-up. It is built from `{{RUN}}` and the intent
     id only — never from `{{ATTEMPT}}`, a timestamp or a recommendation number; a second attempt
     that minted a new marker would post a second comment / create a second issue. Save it on the
     intent verbatim: the runner refuses `done` for any comment/create intent whose stored `marker`
     is missing, null, empty or not exactly that string — a foreign run id that merely *contains*
     this one (`RUN-10` under `RUN-1`) is a rejection, not a match. `set-status` has no marker.
   - intents live in the object `intents` under fixed ids: `comment-1`
     `{op: "comment", marker, state, id}`, `set-status-delivered`
     `{op: "set-status", logical: "delivered", state}`, `create-<n>`
     `{op: "create", draft_id, marker, state, issue}` (`<n>` = the draft id, never a
     recommendation number). Before the write save `state: "pending"`; after it succeeds save
     `state: "done"` and the returned id.
   - (a) write the summary to `.agents/team/runs/{{RUN}}/tracker-comment.md` with
     `[wrapup {{RUN}} comment-1]` as its last line, then
     `bash .claude/lib/team-tracker.sh comment {{TICKET}} --marker "<m>" --body-file <file>`;
     `created` or `exists` → `done`;
   - (b) the `set-status` intent with `logical: "delivered"` →
     `bash .claude/lib/team-tracker.sh set-status {{TICKET}} delivered`; `set` or `unchanged` →
     `done`;
   - exit 4 of any op → the intent stays `pending`,
     `bash .claude/lib/team-record.sh --verdict blocked --message "tracker <op> recoverable — <stderr line>"`
     and wait; a retry uses the same marker and the adapter detects `exists` itself. A NON-ZERO exit
     is never evidence that nothing was written: the object may exist. Leave the intent `pending`,
     change nothing, and let the retry's enumeration decide (`exists` → `done`). Never a second
     op "because the first one failed", and never `done` on an unconfirmed write.
   - you are the ONLY writer of this run's intents. Do not run the adapter from another role, another
     window or in parallel with yourself: the runner holds one role at a time (see
     `.agents/reference/team-mode.md` §2a), and that is what makes read-then-create idempotent.
5. PR description: replace the `## Learnings` section with `## Wrap-up` (at most 6 lines, English,
   ending "Full summary: GitHub issue #{{TICKET}}"; when there are supervised decisions, one of the
   lines is `Supervised decisions: <n> (tier 1: a, tier 2: b, revoked: c) — list in GitHub issue
   #{{TICKET}}` — n = a + b + c; a / b count tier 1 / tier 2 answers neither revoked nor superseded
   at tier 3, c the revoked ones).
   Stay ≤ 4000 characters — trim `## Unattended decisions` prose first, never the template
   checklist or `## QA`. Write it to
   `.agents/team/runs/{{RUN}}/pr-description.md`, then
   `az repos pr update --org {{ORG_URL}} --id {{PR}} --description @.agents/team/runs/{{RUN}}/pr-description.md`.
6. Recommendations — each one only if it passes its bar:
   - **memory**: `Memory hand-off … (supervisor)` lines are applied verbatim. Other `## Learnings`
     go through `.agents/memory/reflection-protocol.md` (the default is to save nothing),
     de-duplicated against `git show origin/{{LINE}}:<file>`, not against this branch;
   - **tasks**: `## Follow-ups` items that this PR does not cover and that deserve a ticket.
     Prepare a draft `{title, body}` for each, with `[wrapup {{RUN}} create-<n>]` as the last line
     of the body. No parent Epic, no sprint, no assignee — the tracker has none.
7. No new/unaccepted recommendations → step 8 for saved accepted work still unfinished,
   otherwise step 9. For new/unaccepted recommendations ask **one** `AskUserQuestion` (2–4 options):
   - Allocate an unused run-scoped create intent id for each new draft; never recycle an id.
     Save each complete draft (title and entire body verbatim) under that id in
     `wrapup-state.json`, and copy it to `.agents/team/runs/{{RUN}}/wrapup-{{ATTEMPT}}.md` for the
     report. Include the step 4 create marker in that saved/shown body.
     **Show that full dry-run once before the question.** Each ticket option names its title; for
     1 or more than 4 recommendations put those details in the question text. A choice accepts
     exactly the displayed, saved draft.
   - 2–4 recommendations → multiSelect, one option each, naming its target file or ticket title;
     exactly 1 → options "apply" / "skip"; more than 4 → number them in the question text and
     offer "all" / "none" (chosen numbers may be typed as "Other").
     Before any creation, persist each selection/accepted flag with its stable draft/intent id
     in the run-scoped state. Resume uses that state, not a newly numbered recommendation list
     or an attempt-scoped report, to identify consent and the matching issue number.
8. Apply only what the developer accepted:
   - memory: before editing a file, if `git diff --quiet {{BASE_SHA}} origin/{{LINE}} -- <file>`
     reports a change, start from the target version (`git show origin/{{LINE}}:<file> > <file>`)
     and add on top — memory files merge with `merge=union`, so editing the stale branch copy
     would splice two versions silently. Edit only `.agents/memory/**`, then `/commit`
     (`{{TICKET}} reconcile memory after <short topic>`) and `/push`;
   - tasks: save the intent `{op: "create", draft_id, marker, state}` as `pending`, then
     `bash .claude/lib/team-tracker.sh create-followup --marker "<m>" --title "<t>" --body-file <file>`;
     `created` or `exists` → `state: "done"` and the returned number.
   - Follow step 4 for every comment/create; a `done` creation is never repeated. Follow the
     stable intent id → issue number mapping even when recommendation order changes.
