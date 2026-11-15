Create the PR against `{{LINE}}` published, not a draft: write a short body (what changed, why,
   the template checklist if the repo has one, plus `## Unattended decisions` and `## Follow-ups`
   taken from `{{RUN_DIR}}/notes.md` and the authority answers from
   `.agents/team/runs/{{RUN}}/answers.md`, when present; ≤ 4000 characters — trim prose, never the
   checklist; never a secret value) to `{{RUN_DIR}}/pr-body.md`, then run
   `bash .claude/lib/team-pr.sh create --ready --head {{BRANCH}} --base {{LINE}} --title '<ticket
   title>' --body-file {{RUN_DIR}}/pr-body.md`.
   It prints pr=<id>; an active PR for this branch is returned, never duplicated.
   Do not run /pr-create and never complete or abandon the PR. Every `az` command you run yourself
   carries `--org {{ORG_URL}}`.
