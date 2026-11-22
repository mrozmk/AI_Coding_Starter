---
description: Merge (complete) a pull request on Azure DevOps or GitHub — invoking it IS the go-ahead. Azure DevOps — publishes a draft, self-approves, completes with the Branch-model strategy (or sets auto-complete and waits while policies run), then cleans up remote and local branches, then (tracker jira) moves the ticket to its merged status; GitHub — publishes a draft, checks the required checks, merges with the Branch-model strategy, cleans up branches, never with --admin. Stops only on a real blocker; never bypasses policies.
argument-hint: "[PR-ID] [--auto <team>]"
allowed-tools: Bash(git status:*), Bash(git branch:*), Bash(git log:*), Bash(git ls-remote:*), Bash(git push origin --delete:*), Bash(git rev-parse:*), Bash(git remote:*), Bash(git switch:*), Bash(git fetch:*), Bash(cat:*), Bash(az account show:*), Bash(az repos show:*), Bash(az repos pr show:*), Bash(az repos pr list:*), Bash(az repos pr policy list:*), Bash(az repos pr update:*), Bash(az repos pr set-vote:*), Bash(bash .claude/lib/team-automerge-check.sh:*), Bash(bash .claude/lib/team-lead.sh:*), Bash(bash .claude/lib/team-tracker.sh show:*), Bash(node .claude/lib/tracker-snapshot.mjs:*), Monitor, Skill, mcp__atlassian__jira_get_issue, mcp__atlassian__jira_get_transitions, mcp__atlassian__jira_transition_issue, Bash(bash .claude/lib/costs/runtime-mark.sh:*), Bash(gh api user:*), Bash(gh pr view:*), Bash(gh pr list:*), Bash(gh pr checks:*), Bash(git pull --ff-only:*), Bash(git merge-base:*), Bash(bash .claude/lib/branch-model.sh:*), Bash(gh repo view:*)
---

# /pr-merge — Merge a Pull Request (Azure DevOps or GitHub)

> **Provider:** see `## Provider` below — Azure DevOps or GitHub (GitHub team PRs still merge
> through `team-integrate.sh`). In Azure Repos "merge" is called **Complete**.
> **Running `/pr-merge` is the user's decision to merge** — the command asks nothing. It resolves
> every state it can on its own (draft → publish, missing approval → self-approve, policies running
> → auto-complete + wait), cleans up the branches, and stops only on a blocker it must not work
> around. Companion of `/pr-create`. Re-running it on an already completed PR just does the cleanup.

Arguments: **$ARGUMENTS** — `[PR-ID] [--auto <team>]` (both optional; `--auto` needs the PR id)

---

## Provider

`PROVIDER` = `teams.pr_provider` when `.claude/project-profile.json` has a `teams` block, else its
`git_host` unless that is absent or `none`, else the `origin` host (github.com → `github`, an
Azure DevOps origin → `azure-devops`) — the `/pr-create` Step 3 rule: `git_host: none` means
"read the origin", not "no PR layer".

- `none` read from `teams.pr_provider` → STOP: "teams.pr_provider is none — the PR layer is off".
- `azure-devops` → `## Azure DevOps path`.
- `github` → `## GitHub path`.
- Anything else → STOP: "merging is supported for azure-devops and github only".

---

## Guardrails

- **Never `--bypass-policy`** (denied in `settings.json`) and **never abandon** a PR. A failing or
  pending required policy is reported, not worked around.
- **No questions.** Invocation is consent to publish, complete **this one PR** and delete its source
  branch. Nothing else: never touch another PR, never change policies.
- **Self-approval and auto-complete are project policy, off by default.** Only when
  `.claude/project-profile.json` has `teams.policy.pr.self_approve: true` does this command vote
  `approve` on the user's own PR or arm auto-complete. Without it: a missing required approval or
  a running blocking policy is a **STOP** naming what is missing (`self_approve` is off).
- **Stop, don't work around:** conflicts, a rejected policy, a rejecting reviewer vote (`-10`/`-5`),
  or an `az` error → report verbatim and stop.
- **Branch deletion only after the merge.** Remote `git push origin --delete <source>` and local
  `git branch -D <source>` (ask-tier) run only once the host reports the PR merged (Azure DevOps
  `completed`, GitHub `MERGED`).
  Never force anything else locally.
- **Long-lived branches are never deleted.** `KEEP` = the `trunk`, `integration`, `maintenance`
  and `protected` lists of `bash .claude/lib/branch-model.sh fields`. Its exit 3 (no Branch model
  block) or an empty `protected=` (exit 0, the Protected field omitted) → the protected part is
  `main`, `master`, `trunk`, `develop` (the `/push` step 2 fallback: block absent or field empty).
  Any other non-zero exit → `KEEP` is unreadable: every source/head branch counts as in `KEEP`
  (nothing is deleted; report "Branch model unreadable — `<branch>` kept" with the script's error).
  A source/head branch in `KEEP` (e.g. a `develop → main` PR) is merged but never deleted by this
  command, remote or local.
- **Tracker comments gate the completion** (Step 4a, opt-in `workflow.tracker_comments`): new, edited
  or uncertain ticket input since the baseline → STOP, no merge. The decision is the user's, recorded
  outside this command; then re-run.
- **Jira is bookkeeping:** a Jira failure is reported, never a reason to stop the cleanup or undo
  the merge.
- **`--auto <team>`** (the Supervisor's automatic merge after `team-automerge-check.sh <team>`
  passed — team-decision-model.md §5): never Step 5b, never `Monitor`; before
  Step 5a run `bash .claude/lib/team-automerge-check.sh <team> --recheck <PR_ID>` — exit ≠ 0 →
  STOP with its line, nothing changed. Without `--auto` every step below is unchanged.
- **GitHub:** never `--admin`, never `--auto`, never `--delete-branch`. A pending, failing or
  unreadable required check is reported, not worked around.

---

## Azure DevOps path

### Step 1 — Coordinates and auth

Resolve `ORG_URL`, `<project>`, `<repo>` from `origin` (`https://dev.azure.com/<org>/<project>/_git/<repo>`,
`<org>@vs-ssh.visualstudio.com:v3/<org>/<project>/<repo>` or `https://<org>.visualstudio.com/<project>/_git/<repo>`;
any other host → STOP "not an Azure DevOps origin"), then probe `az account show -o none` and
`az repos show --repository "<repo>" --org "$ORG_URL" --project "<project>" -o none` — a failure
→ STOP with the `az` message and the fix (`az login`, the `azure-devops` extension). Every `az` call
passes `--org "$ORG_URL"` (and `--project` / `--repository` where the subcommand accepts them).
Pass flags inline — in zsh a `$VAR` holding several flags is not word-split.

### Step 2 — Find the PR

- `$ARGUMENTS` = `<PR-ID> [--auto <team>]`: the first token is the PR id. `--auto` must be
  followed by a team name matching `^[a-z][a-z0-9-]*$`, else STOP with the usage line
  `/pr-merge [PR-ID] [--auto <team>]`. `--auto` without a numeric PR id → STOP with the same line
  (the id comes from the gate's stored `pr_id`, never from the branch). `AUTO` = the team, else
  empty.
- `$ARGUMENTS` is a number → `PR_ID`.
- Empty → `BRANCH` = `git rev-parse --abbrev-ref HEAD`, then
  `az repos pr list … --repository "<repo>" --source-branch "<BRANCH>" --status active --query "[].{id:pullRequestId,title:title}" -o json`.
  Exactly one → use it. None → STOP: "No active PR for `<BRANCH>` — run /pr-create first." More
  than one → STOP and list them: "Several active PRs — run `/pr-merge <id>`." (never guess).

### Step 3 — Read the state

Run in parallel:

- `az repos pr show --id <PR_ID> --org "$ORG_URL" --query "{title:title,status:status,isDraft:isDraft,mergeStatus:mergeStatus,source:sourceRefName,target:targetRefName,autoComplete:autoCompleteSetBy.displayName,commit:lastMergeCommit.commitId,reviewers:reviewers[].{name:displayName,vote:vote,required:isRequired}}" -o json`
- `az repos pr policy list --id <PR_ID> --org "$ORG_URL" --query "[].{policy:configuration.type.displayName,blocking:configuration.isBlocking,status:status}" -o json`

**`--auto`, first action after this read:** `autoComplete` is set (a legacy-armed PR could
complete while the gate builds, defers or refuses) → clear it with
`az repos pr update --id <PR_ID> --org "$ORG_URL" --auto-complete false -o none`, re-read Step 3,
and STOP if it is still set.

`SOURCE` / `TARGET` = the ref names without `refs/heads/`. Votes: `10` approved · `5` approved with
suggestions · `0` no vote · `-5` waiting for author · `-10` rejected. A repo with **no** branch
policies returns an empty policy list — that counts as "all blocking policies passed".

`MERGE` from `CLAUDE.md → ### Branch model` (**Merge** field, or the per-type rule there); absent →
squash for working types, merge commit for `release` / `hotfix`. `SQUASH` = `true` for squash,
`false` for merge commit. `MSG` = `<PR title> (#<PR_ID>)`.

### Step 4 — Decide (no questions)

Apply the first matching row; after any *resolve* action re-read Step 3 (at most 3 loops):

| State | Action |
|---|---|
| `status: completed` | → **Step 6a** (Jira), Step 6b (team run), then Step 6 (cleanup) and Step 7 |
| `status: abandoned`, `mergeStatus: conflicts`, a vote `-10`/`-5`, or a blocking policy `rejected` | **STOP** — name the blocker and the fix (conflicts: merge `<TARGET>` into the branch, push, re-run) |
| `isDraft: true` | *resolve:* `az repos pr update --id <PR_ID> --org "$ORG_URL" --draft false -o none` |
| a *Minimum number of reviewers* policy exists, is not `approved`, and the current user has no vote ≥ 5 | `self_approve` off → **STOP** `needs an approval — teams.policy.pr.self_approve is off`. On → *resolve:* `az repos pr set-vote --id <PR_ID> --org "$ORG_URL" --vote approve -o none` — report it as a **self-approval**. No such policy → never vote. |
| a blocking policy `queued` / `running` (e.g. the build, a required reviewer) | `self_approve` off → **STOP** `policies running — re-run when they pass (auto-complete needs teams.policy.pr.self_approve)`. On → **4a**, then **5b** set auto-complete, then **5c** wait. With `--auto` → **STOP** `deferred: policies running — Supervisor retries on the next READY reminder` (no 5b) |
| all blocking policies `approved` / `notApplicable` (or none exist) | **4a**, then **5a** complete now (with `--auto`: the `--recheck` first) |

### Step 4a — Tracker comments (immediately before 5a or 5b)

**Opt-in:** `workflow.tracker_comments` in `.claude/project-profile.json` is not `true` (absent, `false`, no profile) → skip this step; 5a / 5b run as before. Otherwise the gate **applies** without `--auto`, when the effective tracker (as `team-tracker.sh` resolves it)
is not `none` and a ticket key resolves from the PR: github → the `<n>` of `<type>/<n>-…` in `SOURCE`; jira → the first
`[A-Z][A-Z0-9]+-[0-9]+` in `SOURCE`, else in the PR title. No key → `Tracker comments: skipped — no
ticket key`, and 5a / 5b runs. Otherwise run [.agents/reference/tracker-comments.md](../../.agents/reference/tracker-comments.md)
§5 (baseline by §5.3, the no-plan row) via
`node .claude/lib/tracker-snapshot.mjs compare <baseline> <fresh>`:

- exit `0` → one report line, then 5a or 5b;
- exit `3` → **STOP, no merge**: list the ids (id, created, first sentence). The user decides — a
  ledger line `informational` (§6 → Solo decisions) or a follow-up ticket — and re-runs;
- exit `4` or a failed read → **STOP, no merge** until the user decides; the baseline stays.

`--auto` (the Supervisor's team path) skips this step: the Supervisor runs the team's merge-time
check itself before it calls `/pr-merge --auto` (`.agents/reference/team-pipeline.md` §5a). Never print the read or the snapshot. Checked once: an armed
auto-complete completes later without another read — the contract's §7 limit.

### Step 5 — Execute

**5a. Complete now:**
```bash
az repos pr update --id <PR_ID> --org "$ORG_URL" --status completed \
  --squash <SQUASH> --delete-source-branch false --merge-commit-message '<MSG>' \
  --query "{status:status,mergeStatus:mergeStatus}" -o json
```
With `--auto`, run `bash .claude/lib/team-automerge-check.sh <AUTO> --recheck <PR_ID>` immediately
before this call; exit ≠ 0 → STOP with its `RECHECK: no — …` line, nothing armed.
Azure DevOps completes asynchronously — re-read `az repos pr show` (a few reads) until `status` is
`completed`, then → Step 6a. With `--auto`, compare the completed PR's
`lastMergeSourceCommit.commitId` with the gate's `source` in
`.agents/team/watch/automerge/<AUTO>.json`; a mismatch → report `merged unvalidated commit <sha>`
to the Operator (the merge stands; nothing is undone).

**5b. Set auto-complete** (Azure DevOps merges by itself once every blocking policy passes):
```bash
az repos pr update --id <PR_ID> --org "$ORG_URL" --auto-complete true \
  --squash <SQUASH> --delete-source-branch false --merge-commit-message '<MSG>' -o none
```

In 5a and 5b the message goes in single quotes, each `'` of the title written as `'\''` (a title
is data; backticks or `$(` inside double quotes would run). `--delete-source-branch` is always
`false`: whether the source branch goes is decided once, after `completed`, in Step 6.1.

**5c. Wait for it** — the user asked for a merge, so finish the job instead of handing back a
"re-run later". Start a `Monitor` (background until-loop, one `az repos pr show … --query status`
every 60 s, **max 30 min**) and end the turn; the notification resumes this command:

- `completed` → Step 6a.
- `abandoned`, or a policy flips to `rejected` (check `az repos pr policy list` once when the loop
  ends) → report the blocker and stop. Auto-complete stays set; nothing else is changed.
- Timeout → report what it still waits for (e.g. "Build running 30 min") and say that the source
  branch is deleted only by a re-run after the PR completes: run `/pr-merge <id>` once it is
  `completed` to do the cleanup.

Any `az` error (e.g. "policy not satisfied", 403) → show it verbatim and stop; never retry with
other flags, never `--bypass-policy`.

### Step 6a — Tracker: move the ticket

Runs on every path that reaches `completed`, including a rerun on an already completed PR, and
only when `.claude/project-profile.json → teams.tracker` is `jira` (github: the team's wrapup
already set the delivered status; none: nothing to do). A tracker failure is reported, never a
reason to stop the cleanup.

0. Re-read the completed PR (Step 3's read predates completion):
   `az repos pr show --id <PR_ID> --org "$ORG_URL" --query "{title:title,source:sourceRefName,commit:lastMergeCommit.commitId}" -o json`.
   `COMMIT` = that `commit`; empty → write `merge commit unavailable` in the comment and the report.
1. `KEY` = the first `[A-Z][A-Z0-9]+-[0-9]+` in the PR title, else in `SOURCE`. None → Tracker:
   `no ticket key — not transitioned`; go to Step 6.
2. **Target:** the merged status named in `.agents/memory/domain/jira.md` (`Merged status:`), else
   `Done`. `mcp__atlassian__jira_get_issue(KEY, fields="status")`.
3. **Status guard:** current status equals the target (case-insensitive) → `already <target>`; go
   to Step 6 — do not comment again. Otherwise transition only from `To Do` / `In Progress`; any
   other status → `not transitioned — status <X>` (never back, never sideways); go to Step 6.
4. **Transition:** `mcp__atlassian__jira_get_transitions(KEY)` returns `[{id, name, to_status?}]`.
   Pick the transition whose `to_status`, if present, else `name`, equals the target
   (case-insensitive) — never a hard-coded id. None → `no <target> transition from <status> —
   available: <names>`; go to Step 6. Never walk several steps.
5. **Comment** — `mcp__atlassian__jira_transition_issue(KEY, <id>, comment="Merged in PR
   #<PR_ID>, merge commit <COMMIT>")`, one call, so there is no "moved without comment" state
   (`.agents/reference/jira-mcp-atlassian.md`). Any error → the error verbatim; go to Step 6.

### Step 6b — Team run: end its TeamLead

Runs on every path that reaches `completed`, when the PR belongs to a team run: the `--auto
<team>` team, else the team whose clone `.agents/team/team.json` has `branch` = `SOURCE` without
`refs/heads/`. None → skip silently. Run `bash .claude/lib/team-lead.sh finalize <team> merged`
(idempotent: it ends the run's per-run TeamLead, if any, and marks the run finalized). A failure is
reported with its retry command, never a reason to stop the cleanup.

### Step 6 — Cleanup (only after `completed`)

Step 6b runs first on every path that reaches this step (the "go to Step 6" exits of Step 6a too).

1. **Remote branch.** `MERGED_SRC` =
   `az repos pr show --id <PR_ID> --org "$ORG_URL" --query lastMergeSourceCommit.commitId -o tsv`
   (one read). Keep the remote branch, and say why, when any of these holds:
   - `SOURCE` is in `KEEP` (`## Guardrails`) → "`<SOURCE>` is a long-lived branch — kept";
   - another active PR has it as its source —
     `az repos pr list --org "$ORG_URL" --project "<project>" --repository "<repo>" --source-branch "<SOURCE>" --status active --query "[].pullRequestId" -o json`
     is non-empty, or the lookup fails → "`<SOURCE>` is the source of active PR `#…` — kept";
   - `git ls-remote --exit-code origin refs/heads/<SOURCE>` finds no branch → nothing to do;
   - its sha differs from `MERGED_SRC` (or `MERGED_SRC` is empty) → "`origin/<SOURCE>` moved after
     the merge — kept".

   Otherwise `git push origin --delete <SOURCE>` (merged per the completed PR; covered by this
   command's consent).
2. **Local** — only with a clean working tree (`git status --porcelain` empty; dirty → skip this
   step and say why):
   - `git switch <TARGET>` → `/pull`. The switch fails (e.g. `<TARGET>` is checked out in another
     worktree) → report it verbatim and skip the rest of this item (no pull, no branch deletion, no
     prune).
   - local `<SOURCE>` exists (`git rev-parse --verify --quiet refs/heads/<SOURCE>`), `SOURCE` is
     not in `KEEP` and its tip equals `MERGED_SRC` → `git branch -D <SOURCE>` (ask-tier prompt;
     `-D` because a squash merge is never an ancestor — safe, Azure DevOps confirmed the PR
     completed). In `KEEP` or a different tip → keep it and say why.
   - `git fetch origin --prune`

### Step 7 — Report

✅ PR `#<id>` completed · self-approval if cast · strategy · merge commit (`lastMergeCommit`) ·
remote branch (deleted by this command / kept — why) · local state as Step 6.2 ran it (`<TARGET>`
up to date, then local branch removed / kept — why (`KEEP`, tip ≠ `MERGED_SRC`) / absent; or the
local step skipped — why (dirty tree, failed switch); never "removed" for a branch that was not) ·
URL `<ORG_URL>/<project>/_git/<repo>/pullrequest/<id>`. Then one line on
what happens next per `.agents/reference/git-policy.md` (the project's build/deploy after a merge).
Add `Tracker comments: <none new … | the STOP line | skipped — <reason>>` when Step 4a ran.
Add `Tracker: <KEY> → <status> | already <status> | not transitioned — <reason>` (tracker jira).
If it stopped or timed out: what it waits for, that auto-complete is still set (never with
`--auto`, which never arms it), and that the source branch is deleted only by a re-run
(`/pr-merge <id>`) after the PR completes. With `--auto` the report is the one-line note
`auto-merge <team> PR #<id> <merge commit> (QA <Verdict>)` for Supervisor.

---

## GitHub path

Coordinates: `<owner>/<repo>` from `origin` (`git@github.com:<o>/<r>.git` or
`https://github.com/<o>/<r>.git`). Every `gh pr` call passes `--repo <owner>/<repo>` (the
account-scoped `gh api user` takes none). No step asks a question; every STOP names its fix.

### Step G1 — Guards and auth

- `.agents/team/session.json` exists → STOP: "a team role never merges — the Supervisor merges
  team PRs (team-mode.md §9)".
- `gh api user --jq .login` fails → STOP with the error and the fix `gh auth login`.

### Step G2 — Find the PR

Same argument grammar as Step 2. `--auto` → STOP: "--auto is the Azure DevOps team path only".

- `<n>` → `gh pr view <n> --repo <owner>/<repo> --json number,title,url,state,isDraft,mergeable,headRefName,headRefOid,baseRefName,headRepositoryOwner,headRepository,mergeCommit`.
- Empty → `BRANCH` = `git rev-parse --abbrev-ref HEAD`, then
  `gh pr list --repo <owner>/<repo> --head <BRANCH> --state open --json number,headRefName,headRepositoryOwner,headRepository`,
  keeping only entries with `headRepositoryOwner.login + "/" + headRepository.name` =
  `<owner>/<repo>` and `headRefName` = `BRANCH` (the `/pr-create` Step 7a filter). Exactly one →
  `gh pr view` it as above. Several → STOP, list them: "run `/pr-merge <n>`" (never guess).
  None → the rerun lookup: the same `gh pr list` with `--state merged` (fields + `headRefOid`) and
  the same filter.
  - Exactly one, and `git rev-parse --verify --quiet refs/heads/<BRANCH>` equals its `headRefOid`
    → `gh pr view` it as above (Step G4 routes it as `MERGED`).
  - Exactly one, local tip different or absent → STOP: "No open PR for `<BRANCH>`; merged PR
    `#<n>` (head `<sha>`) is not this branch's tip — run `/pr-merge <n>` to finish its cleanup, or
    /pr-create". (Step G3(c) is skipped for a merged PR, so an old merged PR of a reused branch
    name must not reach the tracker step and the cleanup.)
  - Several → STOP, list them: "run `/pr-merge <n>`".
  - None → STOP: "No open PR for `<BRANCH>` — run /pr-create first."

`HEAD` = `headRefName`, `BASE` = `baseRefName`, `HEAD_SHA` = `headRefOid`.

### Step G3 — Whose PR is it

Runs for both lookups, before any write:

- (a) **Fork:** head repository (`headRepositoryOwner.login + "/" + headRepository.name`) ≠
  `<owner>/<repo>` → STOP: "a fork's PR — not merged from here".
- (b) **Team run:** the invoking checkout's own `.agents/team/team.json` has `branch` = `<HEAD>` (a
  team clone, also between role sessions) → the STOP below. Otherwise `find .agents/team/anchors -maxdepth 1 -name '*.json' -exec jq -r --arg b "<HEAD>" 'select(.branch == $b) | .team' {} +`
  prints a team → STOP: "PR of team `<team>` — team PRs merge through team-merge-check.sh →
  team-integrate.sh".
- (c) **Own work:** unless the PR is already `MERGED`, `git rev-parse --verify --quiet refs/heads/<HEAD>` must equal `HEAD_SHA`;
  else STOP. Local `<HEAD>` exists and `git merge-base --is-ancestor <HEAD_SHA> refs/heads/<HEAD>`
  succeeds → "local `<HEAD>` is ahead of the PR head — check out `<HEAD>`, run /push, then
  re-run". Otherwise (absent, behind, diverged, `HEAD_SHA` unknown locally) → "`<HEAD>` is not
  this checkout's branch at the PR head (`<HEAD_SHA>`) — a team PR from another machine, or
  unpulled work; pull it or merge it where it was made". (c) is the cross-machine guard: anchors
  exist only on the machine that runs the team.

### Step G4 — Decide (no questions)

Apply the first matching row; after any *resolve* action re-read Step G2's `gh pr view` (at most 3
loops). `HEAD_SHA` stays the sha Step G3 accepted: a re-read whose `headRefOid`, `headRefName` or
head repository differs → STOP: "the PR head moved after the ownership check — re-run".

| State | Action |
|---|---|
| `state: MERGED` | `MERGE_SHA` = Step G2's `mergeCommit.oid`, then → **Step G6**, then **Step G7** (a rerun finishes the tracker step and the cleanup) |
| `state: CLOSED` | **STOP** — closed without merge |
| `isDraft: true` | *resolve:* `gh pr ready <n> --repo <owner>/<repo>` |
| `mergeable: CONFLICTING` | **STOP** — merge `<BASE>` into the branch, push, re-run |
| `mergeable: UNKNOWN` | *resolve:* re-read (GitHub computes it lazily); still `UNKNOWN` after the loops → **STOP** |
| `mergeable: MERGEABLE` | → **Step G5** |

### Step G5 — Required checks, then merge

Read the required checks: `gh pr checks <n> --repo <owner>/<repo> --required --json name,bucket`.

- The command fails with `no required checks reported` or `no checks reported` (no CI, no branch
  protection, or none marked required) → no required checks, go on. Any other failure → STOP with
  the error verbatim (an unreadable state is not "none").
- Any `bucket` `fail` or `cancel` → STOP naming those checks.
- Any `pending` → start a `Monitor` (background until-loop, the same `gh pr checks … --required`
  every 60 s, **max 30 min**) and end the turn; the notification resumes here. Timeout → report
  what still runs and that `/pr-merge <n>` later continues. Never merge while a check is pending
  (`gh pr merge` would silently arm auto-merge).
- All `pass` / `skipping` → go on.

Then Step 4a (tracker comments, opt-in) exactly as written there, reading its `SOURCE` as `HEAD`
and its "5a or 5b" as the merge below. Then `MERGE` and the strategy from Step 3's rule
(`CLAUDE.md` → Branch model **Merge**; absent → squash for working types, merge commit for
`release` / `hotfix`):

- merge commit → `--merge`
- squash → `--squash`
- rebase → `--rebase`

Immediately before the merge call — after the checks wait and Step 4a, so a long wait cannot make
them stale — two reads:

- **Long-lived head.** `HEAD` in `KEEP` (`## Guardrails`) →
  `gh repo view <owner>/<repo> --json deleteBranchOnMerge --jq .deleteBranchOnMerge`:
  - `true` → STOP: "`<HEAD>` is a long-lived branch (Branch model) and the repository deletes head
    branches on merge — a merge on the host deletes it too; turn off *Automatically delete head
    branches* in the repository settings, then re-run". (The Branch model is local text; GitHub's
    auto-delete does not read it.)
  - A failed read → STOP with the error verbatim: "cannot read `deleteBranchOnMerge` — `<HEAD>` is
    a long-lived branch and an unreadable setting is not `false`; fix the read (`gh auth status`,
    repository access), then re-run".
- **Merge queue and a moved PR.**
  `gh api graphql -f query='query($o:String!,$r:String!,$n:Int!){repository(owner:$o,name:$r){pullRequest(number:$n){isMergeQueueEnabled baseRefName headRefOid}}}' -f o=<owner> -f r=<repo> -F n=<n> --jq .data.repository.pullRequest`:
  - `isMergeQueueEnabled: true` → STOP: "`<BASE>` requires a merge queue — /pr-merge does not
    enqueue; merge through the queue on the host".
  - `baseRefName` ≠ `BASE` or `headRefOid` ≠ `HEAD_SHA` → STOP: "the PR moved after the checks —
    re-run".
  - A failed read → STOP with the error verbatim (unreadable is not "no queue").

  The seconds between this read and the merge call are not covered — stated and accepted, like the
  Step G7 check-then-delete.

Merge:

`gh pr merge <n> --repo <owner>/<repo> <--merge|--squash|--rebase> --match-head-commit <HEAD_SHA> --subject '<PR title> (#<n>)'`

The subject goes in single quotes, each `'` of the title written as `'\''`: a title is data, and
backticks or `$(` inside double quotes would run. Never `--admin`, never `--auto`, never `--delete-branch`. Any error (head moved, not mergeable,
403) → show it verbatim and STOP; never retry with other flags. Re-read
`gh pr view <n> --repo <owner>/<repo> --json state,mergeCommit,autoMergeRequest` (a few reads) until
`state` is `MERGED`; `MERGE_SHA` = `mergeCommit.oid`. Still not `MERGED` after the reads → STOP with
`gh`'s merge output verbatim and `autoMergeRequest`: "the PR may be queued or armed for auto-merge —
nothing cleaned up; resolve it on the host".

### Step G6 — Tracker

Effective tracker as `/pr-create` resolves it (`teams.tracker` when a `teams` block exists, else
the top-level `tracker`, else `none`). `github` / `none` → nothing (the PR's closing keyword closes
the issue on GitHub). `jira` → Step 6a from item 1 on, reading its `SOURCE` as `HEAD` and every
"go to Step 6" as "go to Step G7", with `COMMIT` = `MERGE_SHA` (Step G5, or on a rerun the
Step G4 `MERGED` row) and the comment
`Merged in PR #<n>, merge commit <COMMIT>`. A tracker failure is reported, never a reason to skip
Step G7.

### Step G7 — Cleanup (only after `MERGED`)

In this order:

- **Long-lived head.** `HEAD` in `KEEP` (`## Guardrails`) → skip item 0 and item 1 (no remote
  deletion) and the local branch deletion in item 2; report "`<HEAD>` is a long-lived branch —
  kept".

0. **Shared head.** `gh pr list --repo <owner>/<repo> --head <HEAD> --state open --json number,headRepositoryOwner,headRepository`,
   filtered to `<owner>/<repo>` as in Step G2: another open PR still uses `<HEAD>`, or the lookup
   fails → skip item 1 (deleting the remote branch would close that PR) and report "`<HEAD>` is the
   head of open PR `#…` — remote branch kept".
1. **Remote branch.**
   - `LIVE` = the sha of `git ls-remote --exit-code origin refs/heads/<HEAD>` (exact ref; absent → nothing to do;
     GitHub may have deleted it).
   - `LIVE` = `HEAD_SHA` → `git push origin --delete <HEAD>`.
   - Any other sha → leave it and report "`origin/<HEAD>` moved to `<LIVE>` after the merge — not
     deleted". The check and the delete are two calls: a push in between is not caught (no
     compare-and-swap without `--force-with-lease`, which the deny list blocks) — stated, accepted.
2. **Local** — only with a clean working tree (`git status --porcelain` empty; dirty → skip this
   step and say why):
   - `git switch <BASE>`. The switch fails (e.g. `<BASE>` is checked out in another worktree) →
     report it verbatim and skip the rest of this item (no pull, no branch deletion, no prune).
   - `git pull --ff-only origin <BASE>` (a refusal → report it verbatim, keep going)
   - local `<HEAD>` exists and `git rev-parse refs/heads/<HEAD>` = `HEAD_SHA` → `git branch -D <HEAD>`
     (ask-tier; `-D` because a squash or rebase merge is never an ancestor). A different tip →
     keep it and report "local `<HEAD>` has commits after the merged head — kept".
   - `git fetch origin --prune`
3. **Base state** — only when item 2 reached its pull (a skipped item 2 — dirty tree or failed
   switch — gets no base-state line; its skip reason is the local state):
   `BASE_SHA` = `git rev-parse <BASE>`; `git merge-base --is-ancestor <MERGE_SHA> <BASE>`
   → report "local `<BASE>` at `<BASE_SHA>`, contains the merge commit" (or that it does not, when
   the pull was refused).

### Step G8 — Report

✅ PR `#<n>` merged · strategy · merge commit `MERGE_SHA` · remote branch (deleted by GitHub / by
this command / kept — why, a long-lived head named as such) · local state as Step G7 ran it
(`BASE_SHA`, contains the merge commit, local branch removed or kept — why; or the local step
skipped — why, with no base-state line) · URL. Add `Tracker comments: …` when Step 4a ran and `Tracker: …` (tracker
jira) as in Step 7. On a STOP: what blocks and the fix.

## Stage end marker (token usage)

When this command finishes — after its final report, and on any path that ends it early (STOP,
refusal, blocker) — run exactly this once, as its own Bash call from the repo root, with nothing
chained before or after it:

`bash .claude/lib/costs/runtime-mark.sh stage end pr-merge`

The command does nothing by itself; the stage hook records it as the end of this stage for
`cost.py report --by-stage` (`.agents/reference/token-usage.md` → Stages). Inside a sub-agent the
hook ignores it.
