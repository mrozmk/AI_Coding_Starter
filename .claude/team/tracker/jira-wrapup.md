4. Jira — the state file `.agents/team/runs/{{RUN}}/wrapup-state.json` (`{}` if absent) makes every
   write safe to retry:
   - on start, load its run-scoped drafts and selections. Each accepted draft is attached to a
     stable create intent id and contains the complete fields, description, parent Epic,
     uploads/defaults, marker and acceptance. Reuse saved accepted drafts and markers verbatim;
     never regenerate or renumber them on another attempt. Recommendation numbers are display
     labels only, never intent ids. Only new/unaccepted proposals go through steps 6–7.
   - create/comment: before each Jira write, save an intent `{op, marker, state: "pending"}`, with
     `marker` = `[wrapup {{RUN}} <op>-<n>]`; put the marker as the last line of the payload; after
     the write, save the returned id or key with `state: "done"`;
   - on start, recover assign/sprint/upload intents by the read-only rules in step 8 first;
     every `pending` create/comment intent → search Jira for its exact marker (the ticket's comments;
     `jira_search` with an escaped marker phrase for an issue). Treat text search as candidates,
     not exact evidence: use read-only `jira_get_issue` to fetch the candidate description or
     comment and verify its final line equals the exact saved marker. Exactly one verified hit
     on the expected ticket/project → mark it `done`. None, several, a mismatched final line,
     or an unreadable result →
     `bash .claude/lib/team-record.sh --verdict blocked --message "jira <op> outcome unknown — check {{TICKET}} for <marker>"`
     and wait: Jira search lags writes, so "not found" does not prove nothing was written;
   - no `done` comment yet → post the summary on {{TICKET}} with
     `mcp__atlassian__jira_add_comment`;
   - Jira unavailable → add `- [wrapup {{ATTEMPT}}] Jira comment not posted: <error>` under
     `## Learnings` and continue.
5. PR description: replace the `## Learnings` section with `## Wrap-up` (at most 6 lines, English,
   ending "Full summary: Jira {{TICKET}}"; when there are supervised decisions, one of the lines is
   `Supervised decisions: <n> (tier 1: a, tier 2: b, revoked: c) — list in Jira {{TICKET}}`
   — n = a + b + c; a / b count tier 1 / tier 2 answers neither revoked nor superseded at
   tier 3, c the revoked ones).
   Stay ≤ 4000 characters — trim `## Unattended decisions` prose first, never the template
   checklist or `## QA`. Write it to
   `.agents/team/runs/{{RUN}}/pr-description.md`, then
   `az repos pr update --org {{ORG_URL}} --id {{PR}} --description @.agents/team/runs/{{RUN}}/pr-description.md`.
6. Recommendations — each one only if it passes its bar:
   - **memory**: `Memory hand-off … (supervisor)` lines are applied verbatim. Other `## Learnings`
     go through `.agents/memory/reflection-protocol.md` (the default is to save nothing),
     de-duplicated against `git show origin/{{LINE}}:<file>`, not against this branch;
   - **tasks**: `## Follow-ups` items that this PR does not cover and that deserve a ticket.
     Prepare `/jira create` drafts (required fields, components, description template, queued
     attachments). Fetch {{TICKET}} with `fields="parent"`, then fetch that parent's
     `summary,issuetype`; use it only when `issuetype.name == "Epic"`. Never use the run's ordinary
     Task as parent, or substitute a guessed/catch-all epic. An absent/non-Epic parent needs the
     clarification in step 7. Apply `.agents/memory/domain/jira.md`: Marek as assignee and the
     currently active TT sprint (read it from board 1; never hardcode a sprint).
7. No new/unaccepted recommendations → step 8 for saved accepted work still unfinished,
   otherwise step 9. For new/unaccepted recommendations ask **one** `AskUserQuestion` (2–4 options):
   - Before the selection question, resolve missing required fields. If there is no verified
     parent Epic, ask here for its key, fetch it and verify `issuetype.name == "Epic"`; until
     resolved, do not offer a task for acceptance or create it.
   - Allocate an unused run-scoped create intent id for each new draft; never recycle an id.
     Save each complete draft (field table, entire description verbatim, queued file paths,
     assignee and active-sprint policy) under that id in `wrapup-state.json`, and copy it to
     `.agents/team/runs/{{RUN}}/wrapup-{{ATTEMPT}}.md` for the report.
     Include the step 4 create marker in that saved/shown description.
     **Show that full dry-run once before the question.** Each ticket option names its title and
     `parent Epic: <key> — <summary>`; for 1 or >4 recommendations put those details in the question
     text. A choice accepts exactly the displayed, saved draft and its listed uploads/defaults.
   - 2–4 recommendations → multiSelect, one option each, naming its target file or ticket title
     plus parent Epic; exactly 1 → options "apply" / "skip"; more than 4 → number them in the
     question text and offer "all" / "none" (chosen numbers may be typed as "Other").
     Before any creation, persist each selection/accepted flag with its stable draft/intent id
     in the run-scoped state. Resume uses that state, not a newly numbered recommendation list
     or an attempt-scoped report, to identify consent and the matching issue key.
8. Apply only what the developer accepted:
   - memory: before editing a file, if `git diff --quiet {{BASE_SHA}} origin/{{LINE}} -- <file>`
     reports a change, start from the target version (`git show origin/{{LINE}}:<file> > <file>`)
     and add on top — memory files merge with `merge=union`, so editing the stale branch copy
     would splice two versions silently. Edit only `.agents/memory/**`, then `/commit`
     (`{{TICKET}} reconcile memory after <short topic>`) and `/push`;
   - tasks: `/jira create` with the saved run-scoped accepted draft and verified parent Epic.
     Follow the stable intent id → issue key mapping even when recommendation order changes.
     Step 7 acceptance
     replaces Flow A's confirmation: **no second dry-run and no "Tworzę? [y/n/edit]"**. Only this
     team wrapup flow (`.agents/team/session.json` has `role: "wrapup"`) has the HARD-GATE 1
     exception. Changed fields, description, parent or uploads return to step 7 for acceptance.
   - Follow step 4 for every create/comment; a `done` creation is never repeated. Use its saved
     issue key for the accepted assign/sprint/upload operations. Re-read the active TT sprint
     before adding the issue, following the accepted active-sprint policy; no active sprint →
     report it, do not pick a future one.
   - Before **each** assign/sprint/upload write, save a separate pending intent with the issue
     key and expected result: assignee account id, resolved sprint id, or queued attachment
     names/sizes and pre-upload attachment ids. After confirmed success, save `state: "done"`
     and returned ids. These operations have no textual marker; do not alter their payloads.
   - On resume, recover those pending intents by read-only issue inspection: matching assignee,
     membership in the saved sprint, or exactly one new attachment id per queued name/size →
     `done`. Missing, ambiguous or unreadable evidence → `team-record --verdict blocked` with the
     issue key and operation, and wait for resolution; never blindly repeat the write. Do not
     stop the create at `done` while its accepted post-create operations remain unfinished.
