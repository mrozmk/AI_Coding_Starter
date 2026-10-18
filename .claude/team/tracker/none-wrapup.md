4. Tracker — none. Nothing is written to a tracker in this role: the summary stays in
   `.agents/team/runs/{{RUN}}/wrapup-{{ATTEMPT}}.md` and there is no comment and no status to set.
5. PR description: replace the `## Learnings` section with `## Wrap-up` (at most 6 lines, English,
   ending "Full summary: .agents/team/runs/{{RUN}}/wrapup-{{ATTEMPT}}.md"; when there are
   supervised decisions, one of the lines is
   `Supervised decisions: <n> (tier 1: a, tier 2: b, revoked: c) — list in the full summary`
   — n = a + b + c; a / b count tier 1 / tier 2 answers neither revoked nor superseded at
   tier 3, c the revoked ones).
   Stay ≤ 4000 characters — trim `## Unattended decisions` prose first, never the template
   checklist or `## QA`. Write it to
   `.agents/team/runs/{{RUN}}/pr-description.md`, then
   {{PR_BODY_SET}}.
6. Recommendations — each one only if it passes its bar:
   - **memory**: `Memory hand-off … (supervisor)` lines are applied verbatim. Other `## Learnings`
     go through `.agents/memory/reflection-protocol.md` (the default is to save nothing),
     de-duplicated against `git show origin/{{LINE}}:<file>`, not against this branch;
   - **tasks**: `## Follow-ups` items that this PR does not cover and that deserve a ticket. No
     ticket is created: they go to a `## Follow-upy` list in
     `.agents/team/runs/{{RUN}}/wrapup-{{ATTEMPT}}.md`, one line each (title plus one sentence).
7. No new/unaccepted recommendations → step 8 for accepted memory work still unfinished, otherwise
   step 9. For new/unaccepted memory recommendations ask **one** `AskUserQuestion` (2–4 options):
   - 2–4 recommendations → multiSelect, one option each, naming its target file; exactly 1 →
     options "apply" / "skip"; more than 4 → number them in the question text and offer
     "all" / "none" (chosen numbers may be typed as "Other").
     The `## Follow-upy` list needs no acceptance — it creates nothing.
8. Apply only what the developer accepted:
   - memory: before editing a file, if `git diff --quiet {{BASE_SHA}} origin/{{LINE}} -- <file>`
     reports a change, start from the target version (`git show origin/{{LINE}}:<file> > <file>`)
     and add on top — memory files merge with `merge=union`, so editing the stale branch copy
     would splice two versions silently. Edit only `.agents/memory/**`, then `/commit`
     (`{{TICKET}} reconcile memory after <short topic>`) and `/push`;
