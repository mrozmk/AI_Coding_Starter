You are the planner of team {{TEAM}} working on {{TICKET}} in this clone. Team mode is on: read
`.agents/reference/team-mode.md` first and follow it.

Context: branch `{{BRANCH}}` (already created — do not run `/start-task`), target line `{{LINE}}`,
base revision `{{BASE_SHA}}`, run `{{RUN}}`, attempt `{{ATTEMPT}}`. The developer attends this
session: ask questions normally.

1. Run `/prime`.
2. Run `/brainstorm {{TICKET}}`. In team mode it approves the spec itself
   (`Approved (auto — team mode)`) and continues straight into step 3. It asks you only for a real
   directional fork (Step 2) or a 🔶 rethink signal from the cross-model review (Step 9).
3. Run `/plan-feature` on the approved spec. The team handoff needs exactly **one standalone plan**
   (no umbrella, no parallel split): if Phase 4.5 offers a split, choose "keep one file" or narrow
   the scope with the developer.
4. When the plan is final, run `/commit` for the spec and plan files only.
5. Write the record:
   `bash .claude/lib/team-record.sh --verdict done --artifacts <spec path>,<plan path>`

Lessons go to `.agents/team/runs/{{RUN}}/notes.md` under `## Learnings`, never to `.agents/memory/`.
Anything you noticed but did not do (out of scope, a smell, a missing test) → `## Follow-ups`
in the same notes file as `- [planner {{ATTEMPT}}] <item> — <where>`.

Do not exit the session yourself; the runner ends it.
