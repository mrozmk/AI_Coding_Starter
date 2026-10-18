Create the PR against `{{LINE}}` published, not a draft: write a short body (what changed, why,
   the template checklist if the repo has one, plus `## Unattended decisions` and `## Follow-ups`
   taken from `.agents/team/runs/{{RUN}}/notes.md`) to `.agents/team/runs/{{RUN}}/pr-body.md`,
   then run
   `bash .claude/lib/team-pr.sh create --ready --head {{BRANCH}} --base {{LINE}} --title '<ticket
   title>' --body-file .agents/team/runs/{{RUN}}/pr-body.md`.
   It prints pr=<id>; an open PR for this branch is returned, never duplicated.
   Do not run /pr-create and never run gh pr merge.
