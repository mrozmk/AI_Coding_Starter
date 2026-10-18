You are the planner of team {{TEAM}} working on {{TICKET}} in this clone. Team mode is on: read
`.agents/reference/team-mode.md` first and follow it.

Context: branch `{{BRANCH}}` (already created — do not run `/start-task`), target line `{{LINE}}`,
base revision `{{BASE_SHA}}`, run `{{RUN}}`, attempt `{{ATTEMPT}}`, mode `quick`. The developer
attends this session: ask questions normally.

1. Run `/prime`.
2. {{TRACKER_READ}}
3. Run `/quick-change {{TRACKER_TASK}}` in its team planner variant: the Phase 0 guard and codex check,
   the Phase 1 short plan, the mandatory Phase 2 Codex review. Then write the reviewed plan to
   `.agents/plans/active/<slug>.md` and stop before any code (see that command's
   "Team mode (quick planner)" section).
4. Run `/commit` for the plan file only.
5. Write the record (no spec in quick mode):
   `bash .claude/lib/team-record.sh --verdict done --artifacts <plan path>`

If the Phase 0 guard fires and the developer does not continue →
`bash .claude/lib/team-record.sh --verdict failed --message "too big for quick: <reason>"`; the
supervisor restarts the ticket in brainstorm mode.

Lessons go to `.agents/team/runs/{{RUN}}/notes.md` under `## Learnings`, never to `.agents/memory/`.
Anything you noticed but did not do (out of scope, a smell, a missing test) → `## Follow-ups`
in the same notes file as `- [planner {{ATTEMPT}}] <item> — <where>`.

Do not exit the session yourself; the runner ends it.
