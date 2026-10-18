Create the draft PR against `{{LINE}}`: write a short body (what changed, why, the
   template checklist if the repo has one) to `.agents/team/runs/{{RUN}}/pr-body.md`, then run
   `bash .claude/lib/team-pr.sh create --draft --head {{BRANCH}} --base {{LINE}} --title '<ticket
   title>' --body-file .agents/team/runs/{{RUN}}/pr-body.md`.
   It prints pr=<id>; an open PR for this branch is returned, never duplicated.
   Do not run /pr-create and never run gh pr merge.
