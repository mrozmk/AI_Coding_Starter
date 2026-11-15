---
description: Prepare a pull request — push the branch, derive title + dest from the Branch model and the tracker, fill the repo's PR template honestly, print the create-PR URL. Opens the PR only with the workflow.pr_open opt-in and an explicit Create answer; never merges.
argument-hint: "[ISSUE-KEY | github: 42 or #42 (optional — derived from the branch name if omitted)]"
allowed-tools: Bash(git status:*), Bash(git branch:*), Bash(git rev-parse:*), Bash(git remote:*), Bash(git log:*), Bash(git diff:*), Bash(git fetch:*), Bash(git ls-remote:*), Bash(git show:*), Bash(ls:*), Bash(cat:*), Bash(bash .claude/lib/team-tracker.sh show:*), Bash(bash .claude/lib/branch-model.sh:*), Bash(gh api user:*), Bash(gh pr list:*), Bash(az repos show:*), Bash(az repos pr list:*), mcp__atlassian__jira_get_issue, Skill, AskUserQuestion
---

# /pr-create — Prepare a Pull Request (host-agnostic)

Prepare everything needed to open a PR, then **stop and hand the user a ready-to-paste PR**. The
command **never creates the PR and never merges** — the user opens it from the host UI so the PR
is authored by **them**, not by a token or bot identity, and so the outward-facing act (reviewers
get notified) stays a human one. Output: push confirmation · create-PR URL · title · filled
description + checklist · post-merge reminder. A project may opt in to having the command open the
PR (`workflow.pr_open`, Step 7a) — still only after the user has read the full draft and answered
**Create**; the default stays off for the reason above.

Issue key argument: **$ARGUMENTS** (optional)

---

## Guardrails

- **Never create the PR unless Step 7a's opt-in is on and the user answered Create; never merge,
  never commit.** Dirty tree → tell the user to run `/commit` first. Outside Step 7a never call a
  host API (`gh`, `glab`, `az`, `curl`). Never pass `--auto-complete` or `--bypass-policy`, never
  retry a failed create with other flags; one PR per branch and destination. Reading the issue through
  `team-tracker.sh show` is fine. No tracker status is moved here: delivery is the merge.
- **Protected-branch refuse.** Current branch listed under **Protected** in `CLAUDE.md → ### Branch
  model` (fallback when the block is absent: `main`, `master`, `trunk`, `develop`) → STOP: "You are on
  protected branch `<b>` — PRs are opened from a working branch."
- **PR layer off.** `.claude/project-profile.json` has `teams.pr_provider: none` → STOP:
  "teams.pr_provider is none — the PR layer is off for this project; set it to github or
  azure-devops to open PRs."
- **The only outward actions are the push**, delegated to `/push` (own branch, never `--force*`),
  **and, opt-in only, the PR the user approved in Step 7a.** The create call is deliberately not in
  `allowed-tools`: the permission prompt is a second gate after the question.
- **Faithful checklist.** Fill the template from the actual diff. Check `[x]` only what is genuinely
  true; otherwise mark **N/A** with a one-line reason. Never tick "tests pass" without having run
  the project's Validation commands in this session.

---

## Process

### Step 1 — Preflight

Run in parallel: `git rev-parse --abbrev-ref HEAD` (→ `BRANCH`), `git status --porcelain`,
`git remote get-url origin`, and `cat CLAUDE.md` sections **Branch model** + **Validation**.

- Detached `HEAD` → stop. Protected branch → refuse per Guardrails.
- Dirty tree with un-committed owned changes → STOP: run `/commit` first. Unrelated untracked
  files: note them, do not block.

### Step 2 — Derive type, key, dest, merge strategy

- `TYPE` = first path segment of `BRANCH`. Valid types and their **Base → PR dest** come from the
  Branch model. Unknown type → warn, continue with dest = **Integration** (else **Trunk**).
- **Tracker** — the effective one: `.claude/project-profile.json` → `teams.tracker` when a `teams`
  block exists, else the top-level `tracker`, else `none`.
- `KEY` — **github:** `$ARGUMENTS` if given (`^#?\d+$`, `#` dropped), else the number in
  `BRANCH` matching `^[^/]+/(\d+)-`. **Otherwise:** `$ARGUMENTS` if given, else the first
  `[A-Z]+-\d+` match in `BRANCH`, uppercased. May be empty (keyless maintenance branch) — proceed
  with a warning, no prefix.
- `DEST` from the Branch model's **Base → PR dest** row for `TYPE`. Block absent → resolve
  `git symbolic-ref refs/remotes/origin/HEAD`, then `main`, then `master`; **never assume
  `develop`**.
- **Recorded line** — `bash .claude/lib/branch-model.sh line <BRANCH>` (written by `/start-task`):
  - recorded `L` = `bash .claude/lib/branch-model.sh default-base --type <TYPE>` → keep the row's
    `DEST` (gitflow's `release`/`hotfix` back-merge note stays);
  - any other recorded `L` (a Maintenance line, or Trunk/Integration chosen with `--line`) →
    `DEST = L`. A Maintenance `DEST` gets one informational line in the output: "Fix on a
    maintenance line — port it to <Integration> if it applies there too.";
  - nothing recorded (exit 1: a branch made by hand or before `/start-task` recorded lines) → the
    row's `DEST` as above. When `branch-model.sh fields` lists Maintenance lines, `git fetch origin
    <L>` and count `git log --oneline origin/<L>..HEAD` for the row's `DEST` and each of them, then ask once with
    `AskUserQuestion` which line the work belongs to — the row's `DEST` first, the closest one marked
    "looks cut from here" (a **suggestion**: history cannot tell which line the work was started
    on, so it is never applied silently). Answer `L` → `DEST = L` as above and `branch-model.sh
    record <BRANCH> <L>`, so the question is not asked again.
- **Retired check:** a `DEST` listed under `retired=` (`branch-model.sh fields`) → STOP:
  "`<DEST>` is retired — target the Integration or a Maintenance line."
- `MERGE` from the Branch model's **Merge** field; absent → squash for working types, merge commit
  for `release` / `hotfix` (CLAUDE.md rule). If the preset routes `release`/`hotfix` into a second
  branch as well, surface that second merge in the output.
- `git fetch origin <DEST>` then `git log --oneline origin/<DEST>..HEAD`. No commits ahead → STOP:
  "Branch has no commits ahead of `<DEST>` — nothing to PR."

### Step 3 — Host detection

Read `git_host` from `.claude/project-profile.json` first (`github` | `bitbucket` | `gitlab`); fall back to parsing `origin` only when the profile is absent or `git_host` is `none`. Parse the `origin` URL (`git@<host>:<owner>/<repo>.git` or `https://<host>/<owner>/<repo>.git`;
strip `.git`):

| Host | Create-PR URL | PR template lookup order |
|------|---------------|--------------------------|
| `github.com` | `https://github.com/<owner>/<repo>/compare/<DEST>...<BRANCH>?expand=1` | `.github/PULL_REQUEST_TEMPLATE.md`, `.github/pull_request_template.md`, `PULL_REQUEST_TEMPLATE.md`, `docs/PULL_REQUEST_TEMPLATE.md` |
| `bitbucket.org` | `https://bitbucket.org/<owner>/<repo>/pull-requests/new?source=<BRANCH>&dest=<DEST>` | `.bitbucket/pull_request_template.md` |
| `gitlab.*` | `https://<host>/<owner>/<repo>/-/merge_requests/new?merge_request[source_branch]=<BRANCH>&merge_request[target_branch]=<DEST>` | `.gitlab/merge_request_templates/Default.md` (else first file there) |
| Azure DevOps (`dev.azure.com/<org>/<project>/_git/<repo>`, `dev.azure.com/<org>/_git/<repo>` → project = repo, `ssh.dev.azure.com:v3/<org>/<project>/<repo>`, `<org>.visualstudio.com/[DefaultCollection/]<project>/_git/<repo>`; URL-decode, `ORG_URL = https://dev.azure.com/<org>`) | `<ORG_URL>/<project>/_git/<repo>/pullrequestcreate?sourceRef=<BRANCH>&targetRef=<DEST>` | read from the default branch (`git show origin/<default>:<path>`; Azure Repos applies only those): `.azuredevops/`, `.vsts/`, `docs/`, root — `pull_request_template/branches/<DEST>.md` first, then `pull_request_template.md` |
| other | none — print `BRANCH` and `DEST` and tell the user to open the PR manually | none |

GitHub's compare URL prefills nothing beyond the branches; Bitbucket Cloud ignores title/body
params — so in every case the title and description are pasted from the blocks below.

### Step 4 — Title (tracker soft-fail)

**github**, `KEY` set: `bash .claude/lib/team-tracker.sh show <KEY> --out <scratch>/issue.json`
(`<scratch>` = one `mktemp -d`; it answers for a closed issue too).
- Success → `TITLE = "<issue title verbatim> (#<KEY>)"`; keep its `url`. Note the state if it is
  `CLOSED`.
- Any failure → no hard stop. `TITLE = "<slug words, capitalised> (#<KEY>)"` and flag "⚠️ tracker
  unreachable — replace the title with the real issue title."

**jira**, `KEY` set: `mcp__atlassian__jira_get_issue(issue_key="<KEY>", fields="summary,status")`.
- Success → `TITLE = "<KEY>: <summary verbatim>"` (the ticket summary, not the branch slug —
  readable in the PR list). Note the status if it is Done/Closed.
- Any failure (MCP absent, 401/403/404, literal `${JIRA_URL}`) → no hard stop. `TITLE = "<KEY>:
  <slug words, capitalised>"` and flag "⚠️ tracker unreachable — replace the title with the real
  summary."

No `KEY` → concise human title from the slug, no prefix.

### Step 5 — Push

Invoke `/push`. It sets the upstream on first push, runs the secret scan, and asks before a
protected-branch push (which Step 1 already ruled out). Push rejected → surface the error
verbatim and stop.

### Step 6 — Build the description

- Template found (Step 3) → use its exact section structure. None → use: **Description** ·
  **Screenshots** (visual changes only) · **Checklist** · **Validation**.
- **Description:** 4–10 lines of *what changed and why*, from `git diff origin/<DEST>..HEAD --stat`
  plus the key hunks. End with the issue link line (omit if keyless):
  - **jira:** `Closes <KEY>`.
  - **github tracker, PR on github.com, `DEST` = the default branch** (`git symbolic-ref
    refs/remotes/origin/HEAD`): `Closes #<KEY>` when the effective github block's `repo`
    (`teams.github`, else the top-level `github`) is `origin`'s `owner/repo`, else
    `Closes <repo>#<KEY>` — a bare `#<KEY>` would name an issue of the code repo.
  - **github tracker, PR on github.com, `DEST` is not the default branch:** GitHub ignores closing
    keywords there and does not link the PR → `Refs <issue url>` and the warning "GitHub will not
    close #<KEY> on this merge — close it by hand once `<DEST>` reaches `<default>`".
  - **github tracker, PR on another host** (GitLab, Bitbucket): their own keyword syntax would
    close *their* issue → `Refs <issue url>` and the warning "close #<KEY> on GitHub by hand after
    the merge".
- **Screenshots:** required when the diff touches user-facing visual surface
  (`*.html|*.tsx|*.jsx|*.vue|*.svelte|*.css|*.scss|*.less` or component templates). State that the
  author must attach desktop and mobile captures — you cannot. Otherwise "N/A — no visual change".
- **Checklist:** each item faithfully (Guardrails). Non-UI / tooling change → UI/QA items N/A with
  reason.
- **Validation:** name the commands from `CLAUDE.md → Validation` that ran in this session and
  their result. Not run → say "not run in this session", never imply green.

### Step 7 — Emit (prepare-only)

In the user's communication language:

1. ✅ push confirmation (branch + upstream).
2. **🔗 Create-PR URL** from Step 3 (or the manual instruction).
3. **Title** — copy block.
4. **Description + checklist** — one copy-paste markdown block.
5. **Post-approval reminder:** `MERGE` strategy for this type, delete source branch, merge message
   `Closing <KEY>`; the second merge for `release`/`hotfix` if the preset needs it. **github with a
   Project:** the board moves only through the Project's own workflow — "item closed" must set the
   option the profile calls `delivered` (GitHub's default sets `Done`); otherwise move the item by
   hand after the merge.
6. Repeat any warning (tracker unreachable, unknown branch type, keyless, the issue will not close
   on this merge) so it is not missed.

### Step 7a — Open the PR (opt-in)

**Opt-in:** `workflow.pr_open` in `.claude/project-profile.json` is not `true` (absent, `false`, no
profile) → the command ends with Step 7: no host API call, no question. Team mode
(`.agents/team/session.json` exists) also ends there — the team PR path is not this step.

Otherwise:

1. **Provider** — `teams.pr_provider` when a `teams` block exists, else the Step 3 host: github.com
   → `github`, Azure DevOps → `azure-devops`. Anything else → one line "opening is supported for
   github and azure-devops only — open it from the URL above", stop.
2. **Identity** — github: `gh api user --jq .login` (the account `gh` will create with).
   azure-devops: `az repos show --org "$ORG_URL" --project "<project>" --repository "<repo>" --query id -o tsv`
   proves access only; `az repos` may use a PAT (`az devops login`) or the `az login` account, so the
   author is shown as **"not verified — the identity behind your `az repos` credentials"**, never
   as a confirmed name. A failed probe → STOP with the error and the fix (`gh auth login` · `az login`
   / `az devops login --org <ORG_URL>`).
3. **Preview, then ask.** Publication is immediate and notifies reviewers, so the user sees the
   **full** description before Create — print one block: repo, `BRANCH → DEST`, title, `MERGE`,
   template used, author (step 2), then the complete description exactly as it will be sent
   (azure-devops caps it at 4000 characters: trim prose before this preview, never checklist items).
   Then
   `AskUserQuestion`: **Create PR** · **Create as draft** · **Edit** (apply the change, show the full
   block again, ask again) · **Cancel** (the branch stays pushed; nothing else happens). Anything but
   Create → no create call.
4. After Edit, re-run the Retired check on `DEST`. Write the description with the Write tool to the
   path `git rev-parse --git-path PR_DESCRIPTION.md` prints (inside the git dir, so it can never be
   committed; works in a linked worktree) — the previewed text, unchanged.
5. **Find the PR this branch already has** (before the create, and again after it):
   - github: `gh pr list --repo <owner>/<repo> --head <BRANCH> --base <DEST> --state open --json number,url,isDraft,headRefName,baseRefName,headRepositoryOwner,headRepository`,
     keep only entries with `headRepositoryOwner.login + "/" + headRepository.name` = `<owner>/<repo>`,
     `headRefName` = `BRANCH` and `baseRefName` = `DEST` (`--head` also matches a fork's branch of the
     same name — `team-pr.sh` `find_open` applies the same filter);
   - azure-devops: `az repos pr list --org "$ORG_URL" --project "<project>" --repository "<repo>" --source-branch <BRANCH> --status active -o json`,
     keep entries with `repository.name` = `<repo>` and `sourceRefName` = `refs/heads/<BRANCH>`;
     one whose `targetRefName` is not `refs/heads/<DEST>` → STOP "an active PR of this branch targets
     `<its target>` — not the previewed `DEST`".

   Exactly one → report it (URL, draft state) and stop: no second PR. More than one → STOP, list
   them, create nothing.
6. **Create** (none found):
   - github: `gh pr create --repo <owner>/<repo> --base <DEST> --head <BRANCH> --title "<TITLE>" --body-file <path from 4>`
     plus `--draft` for Create as draft;
   - azure-devops: `az repos pr create --org "$ORG_URL" --project "<project>" --repository "<repo>" --source-branch <BRANCH> --target-branch <DEST> --title "<TITLE>" --description @<path from 4> --query "{id:pullRequestId,isDraft:isDraft}" -o json`
     plus `--draft true` for Create as draft.

   Whatever the create printed, run step 5 again — a create that succeeded and lost its answer must
   not lead to a second PR. Exactly one → the result. None → the create's error verbatim; stop (no
   retry with other flags).
7. **Report:** ✅ PR `#<n>` (draft or published) + URL, title, `DEST`, author line; next: review, then
   `/pr-merge <id>` (azure-devops) or the host's merge; repeat every warning.

---

## Notes

- Assumes the work is committed. Never stages, commits, or amends.
- Everything — host, owner/repo, type, key, dest, merge strategy — is derived at run time from
  `origin` and the Branch model; nothing project-specific is hardcoded.
- Natural completion of an `/orchestrate --publish branch-local` run (CLAUDE.md → *Orchestrate
  publish*): the pipeline commits, this command publishes for review.

## Stage end marker (token usage)

At this command's definitive end — its work is done, or it stops for good (STOP, refusal, blocker) —
run exactly this once, as its own Bash call from the repo root with nothing chained before or after
it, as the last step **before** the final report (or handback):

`bash .claude/lib/costs/runtime-mark.sh stage end pr-create`

Never at a pause that waits for the user (a question, an approval): the stage goes on after the
answer, and a plain reply records no new start. The call writes nothing itself; when the team
harness has registered the stage hook, the hook records it as this stage's end for
`cost.py report --by-stage` (`.agents/reference/token-usage.md` → Stages). Without the hook, and
inside a sub-agent, it does nothing.
