---
description: Prepare a pull request — push the branch, derive title + dest from the Branch model and the tracker, fill the repo's PR template honestly, print the create-PR URL. Prepares only — never opens the PR, never merges.
argument-hint: "[ISSUE-KEY | github: 42 or #42 (optional — derived from the branch name if omitted)]"
allowed-tools: Bash(git status:*), Bash(git branch:*), Bash(git rev-parse:*), Bash(git remote:*), Bash(git log:*), Bash(git diff:*), Bash(git fetch:*), Bash(git ls-remote:*), Bash(ls:*), Bash(cat:*), Bash(bash .claude/lib/team-tracker.sh show:*), mcp__atlassian__jira_get_issue, Skill
---

# /pr-create — Prepare a Pull Request (host-agnostic)

Prepare everything needed to open a PR, then **stop and hand the user a ready-to-paste PR**. The
command **never creates the PR and never merges** — the user opens it from the host UI so the PR
is authored by **them**, not by a token or bot identity, and so the outward-facing act (reviewers
get notified) stays a human one. Output: push confirmation · create-PR URL · title · filled
description + checklist · post-merge reminder.

Issue key argument: **$ARGUMENTS** (optional)

---

## Guardrails

- **Never create the PR, never merge, never commit.** Dirty tree → tell the user to run `/commit`
  first. Never call a host API (`gh`, `glab`, `curl`) to **open** the PR. Reading the issue through
  `team-tracker.sh show` is fine. No tracker status is moved here: delivery is the merge.
- **Protected-branch refuse.** Current branch listed under **Protected** in `CLAUDE.md → ### Branch
  model` (fallback when the block is absent: `main`, `master`, `trunk`, `develop`) → STOP: "You are on
  protected branch `<b>` — PRs are opened from a working branch."
- **PR layer off.** `.claude/project-profile.json` has `teams.pr_provider: none` → STOP:
  "teams.pr_provider is none — the PR layer is off for this project; set it to github or
  azure-devops to open PRs."
- **The only outward action is the push**, delegated to `/push` (own branch, never `--force*`).
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
