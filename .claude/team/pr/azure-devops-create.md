Create the draft PR against `{{LINE}}`: write a short body (what changed, why, the
   template checklist if the repo has one, ≤ 4000 characters — trim prose, never the checklist; only
   what the diff and `{{RUN_DIR}}/notes.md` say, never a secret value) to `{{RUN_DIR}}/pr-body.md`,
   then run
   `bash .claude/lib/team-pr.sh create --draft --head {{BRANCH}} --base {{LINE}} --title '<ticket
   title>' --body-file {{RUN_DIR}}/pr-body.md`.
   It prints pr=<id>; an active PR for this branch is returned, never duplicated.
   Do not run /pr-create and never complete or abandon the PR. Every `az` command you run yourself
   carries `--org {{ORG_URL}}`.
