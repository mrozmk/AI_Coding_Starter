---
description: Merge (complete) an Azure DevOps pull request — invoking it IS the go-ahead: publishes a draft, self-approves, completes with the Branch-model strategy (or sets auto-complete and waits while policies run), then cleans up remote and local branches, then (tracker jira) moves the ticket to its merged status. Stops only on a real blocker; never bypasses policies.
argument-hint: "[PR-ID] [--auto <team>]"
allowed-tools: Bash(git status:*), Bash(git branch:*), Bash(git log:*), Bash(git ls-remote:*), Bash(git push origin --delete:*), Bash(git rev-parse:*), Bash(git remote:*), Bash(git switch:*), Bash(git fetch:*), Bash(cat:*), Bash(az account show:*), Bash(az repos show:*), Bash(az repos pr show:*), Bash(az repos pr list:*), Bash(az repos pr policy list:*), Bash(az repos pr update:*), Bash(az repos pr set-vote:*), Bash(bash .claude/lib/team-automerge-check.sh:*), Monitor, Skill, mcp__atlassian__jira_get_issue, mcp__atlassian__jira_get_transitions, mcp__atlassian__jira_transition_issue, Bash(bash .claude/lib/costs/runtime-mark.sh:*)
---

# /pr-merge — Complete an Azure DevOps Pull Request

> **Azure DevOps only** (`teams.pr_provider: azure-devops`; GitHub team PRs merge through
> `team-integrate.sh`; `none` → STOP: "teams.pr_provider is none — the PR layer is off"). In Azure Repos "merge" is called **Complete**.
> **Running `/pr-merge` is the user's decision to merge** — the command asks nothing. It resolves
> every state it can on its own (draft → publish, missing approval → self-approve, policies running
> → auto-complete + wait), cleans up the branches, and stops only on a blocker it must not work
> around. Companion of `/pr-create`. Re-running it on an already completed PR just does the cleanup.

Arguments: **$ARGUMENTS** — `[PR-ID] [--auto <team>]` (both optional; `--auto` needs the PR id)

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
- **Branch deletion only after `completed`.** Remote `git push origin --delete <source>` and local
  `git branch -D <source>` (ask-tier) run only once Azure DevOps reports the PR `completed`.
  Never force anything else locally.
- **Jira is bookkeeping:** a Jira failure is reported, never a reason to stop the cleanup or undo
  the merge.
- **`--auto <team>`** (the Supervisor's automatic merge after `team-automerge-check.sh <team>`
  passed — team-decision-model.md §5): never Step 5b, never `Monitor`; before
  Step 5a run `bash .claude/lib/team-automerge-check.sh <team> --recheck <PR_ID>` — exit ≠ 0 →
  STOP with its line, nothing changed. Without `--auto` every step below is unchanged.

---

## Process

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
| `status: completed` | → **Step 6a** (Jira), then Step 6 (cleanup) and Step 7 |
| `status: abandoned`, `mergeStatus: conflicts`, a vote `-10`/`-5`, or a blocking policy `rejected` | **STOP** — name the blocker and the fix (conflicts: merge `<TARGET>` into the branch, push, re-run) |
| `isDraft: true` | *resolve:* `az repos pr update --id <PR_ID> --org "$ORG_URL" --draft false -o none` |
| a *Minimum number of reviewers* policy exists, is not `approved`, and the current user has no vote ≥ 5 | `self_approve` off → **STOP** `needs an approval — teams.policy.pr.self_approve is off`. On → *resolve:* `az repos pr set-vote --id <PR_ID> --org "$ORG_URL" --vote approve -o none` — report it as a **self-approval**. No such policy → never vote. |
| a blocking policy `queued` / `running` (e.g. the build, a required reviewer) | `self_approve` off → **STOP** `policies running — re-run when they pass (auto-complete needs teams.policy.pr.self_approve)`. On → **5b** set auto-complete, then **5c** wait. With `--auto` → **STOP** `deferred: policies running — Supervisor retries on the next READY reminder` (no 5b) |
| all blocking policies `approved` / `notApplicable` (or none exist) | **5a** complete now (with `--auto`: the `--recheck` first) |

### Step 5 — Execute

**5a. Complete now:**
```bash
az repos pr update --id <PR_ID> --org "$ORG_URL" --status completed \
  --squash <SQUASH> --delete-source-branch true --merge-commit-message "<MSG>" \
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
  --squash <SQUASH> --delete-source-branch true --merge-commit-message "<MSG>" -o none
```

**5c. Wait for it** — the user asked for a merge, so finish the job instead of handing back a
"re-run later". Start a `Monitor` (background until-loop, one `az repos pr show … --query status`
every 60 s, **max 30 min**) and end the turn; the notification resumes this command:

- `completed` → Step 6a.
- `abandoned`, or a policy flips to `rejected` (check `az repos pr policy list` once when the loop
  ends) → report the blocker and stop. Auto-complete stays set; nothing else is changed.
- Timeout → report what it still waits for (e.g. "Build running 30 min") and say that
  `/pr-merge <id>` later only does the cleanup.

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

### Step 6 — Cleanup (only after `completed`)

1. **Remote branch.** Azure DevOps does not always honour `deleteSourceBranch` — observed on an
   auto-completed PR. `git ls-remote --heads origin <SOURCE>` still lists it →
   `git push origin --delete <SOURCE>` (merged per the completed PR; covered by this command's consent).
2. **Local** — only with a clean working tree (`git status --porcelain` empty; dirty → skip this
   step and say why):
   - `git switch <TARGET>` → `/pull`
   - local `<SOURCE>` exists (`git rev-parse --verify --quiet refs/heads/<SOURCE>`) →
     `git branch -D <SOURCE>` (ask-tier prompt; `-D` because a squash merge is never an ancestor —
     safe, Azure DevOps confirmed the PR completed)
   - `git fetch origin --prune`

### Step 7 — Report

✅ PR `#<id>` completed · self-approval if cast · strategy · merge commit (`lastMergeCommit`) ·
remote branch deleted (by Azure DevOps or by this command) · local state (`<TARGET>` up to date,
local branch removed) · URL `<ORG_URL>/<project>/_git/<repo>/pullrequest/<id>`. Then one line on
what happens next per `.agents/reference/git-policy.md` (the project's build/deploy after a merge).
Add `Tracker: <KEY> → <status> | already <status> | not transitioned — <reason>` (tracker jira).
If it stopped or timed out: what it waits for, and that auto-complete is still set (never with
`--auto`, which never arms it). With `--auto` the report is the one-line note
`auto-merge <team> PR #<id> <merge commit> (QA <Verdict>)` for Supervisor.

## Stage end marker (token usage)

When this command finishes — after its final report, and on any path that ends it early (STOP,
refusal, blocker) — run exactly this once, as its own Bash call from the repo root, with nothing
chained before or after it:

`bash .claude/lib/costs/runtime-mark.sh stage end pr-merge`

The command does nothing by itself; the stage hook records it as the end of this stage for
`cost.py report --by-stage` (`.agents/reference/token-usage.md` → Stages). Inside a sub-agent the
hook ignores it.
