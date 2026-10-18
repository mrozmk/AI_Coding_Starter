# Reference: the permanent SolTT worker clone (TT-849)

The delegated Codex worker SolTT (`AGENTS.md` → **Delegated execution** → **Worker clone**) works
in one permanent clone, handed from one assignment to the next by `.claude/lib/worker-next.sh`.
It replaces a fresh 1.6–1.8 GB clone in `/private/tmp` per ticket once provisioned and verified.
Merge of TT-849 alone is not operational readiness: resolve the TT-855 hardening findings before
real assignments, then complete authorized provisioning, write-access checks and smoke. Record
the planned two-assignment reuse check separately; do not report it as passed before execution.

## Purpose and paths

| What | Path |
|---|---|
| Clone | `$(dirname <main>)/$(basename <main>)-sol` — `~/Desktop/TakeTask/TakeTask.DN-sol` |
| State | `<git dir>/taketask-worker/`: `provisioned.json`, `op.lock/`, `active/`, `history/` |
| Artifacts | `$WORKER_ARTIFACTS/<id>` — default `~/.agent-mail/taketask-dn/worker/<id>` |

State lives in the git dir: it never dirties the tree, needs no `.gitignore` entry and is invisible
to `team_clone_dirs` and `team_ticket_checks`, which look only for `.agents/team/team.json`.
Env overrides: `WORKER_ARTIFACTS`, `WORKER_ARTIFACT_MAX_MB` (50), `WORKER_LOCK_SECS` (30).
`WORKER_ARTIFACTS` is the artifacts root; use an absolute path outside all repository checkouts.
`<assignment-artifacts>` below is the full `artifacts:` path printed by `start`, already including
`<id>`. Pass this exact path in the handoff; do not append the id again.

## Provisioning (once, on the Operator's word)

1. From the main checkout: `bash .claude/lib/worker-next.sh init origin/<trunk>` (`<trunk>` = the
   profile's `teams.trunk`, as in `AGENTS.md`). The clone is detached at the base; that commit is
   the first settled tip.
2. Ensure the worker's Codex host can write to the clone and the selected artifacts root
   (default `~/.agent-mail/taketask-dn/worker/`). Preserve existing approved mailbox and host
   temporary-directory access; these two task paths do not replace the host's whole permission
   profile. The worker runs with `CODEX_HOME=<codex-home>` (the value of `.claude/codex-profile`,
   as in `AGENTS.md`). Use the thread cwd or narrow writable roots; do not widen to `~` or full
   access. Do not copy authentication files or session databases.
3. Smoke: from the clone root, the worker runs `bash .claude/lib/worker-next.sh status` and
   the project's build check `<build_check>` (profile `teams.build_check`), and performs a
   reversible write probe in the selected artifacts root. Report the resolved clone/base, actual
   status and command exit codes;
   `status` returning 0 alone is insufficient because it also returns 0 for a missing clone.
   A freshly provisioned clone must be idle at the expected base. Remove only the smoke probe.
4. `init` copies only `info/exclude` — no `.env`, credentials, `settings.local.json`, sessions or
   `user-profile.md`.

## Assignment lifecycle

| State | Where | Entered by |
|---|---|---|
| provisioned | `provisioned.json`, no `active/` | `init` |
| switching | `active/assignment.json .state` | `start` publishes `staging-<id>` as `active/` |
| active | same file | `start` after the switch and the artifacts dir |
| released | `history/<id>/release.json` | `release` moves `active/` to `history/<id>` |

| Command | Who | From | Lock |
|---|---|---|---|
| `init <base-ref>` | supervisor (OpusTT) | main checkout | `op.lock` |
| `start <key> <branch> <base-ref> --thread <id>` | supervisor | main checkout | `op.lock` |
| `release <id> [--pr <n>] [--abandoned]` | supervisor | main checkout | `op.lock` |
| `status` | either | clone or main checkout | none, exits 0 |
| `check <id>` | either (SolTT before each stage) | clone or main checkout | none |

One assignment covers plan, implementation, both reviews and the gate. The next `start` comes only
after the supervisor's `release`, after Stage 6 and a settled branch/PR. Before release, the
supervisor explicitly confirms all reviewers/builds/gates are finished and records their outcomes.
`op.lock` serializes script commands; `active/` records the assignment. Neither proves that all
participants have stopped. Process probing is supplementary, not a substitute for their closure.
An explicitly cancelled/abandoned assignment requires the supervisor's recorded disposition and
participant shutdown; do not claim that unfinished stages passed.

## Commands and refusals

Every refusal prints `error: <message>` on stderr and exits 1; problems are collected and printed
together where the command can continue checking.

Messages below are verbatim prefixes; `…` marks where a long one continues.

**Any command**
- `<cmd> is a supervisor command — run it from the main checkout` (init, start, release)
- `no worker clone at <dir> — run init` (start, release)
- `worker clone busy (op.lock held by pid <p>) — stale: check no worker-next.sh runs, …`
- `a build, gate or review is running against <dir>: <process>` (start, release) — the caller's
  own ancestor processes (wrapper shells, `timeout`, subshells) are never a hit

**init**
- `<dir> exists — the worker clone is provisioned once` · `git fetch origin failed`
- `jq is required — install it before init`
- `base-ref '<base>' must be origin/<branch>` · `base-ref <base> does not resolve` (also start)
- `base <base> has no worker contract (AGENTS.md ### Worker clone, worker-next.sh, …` (also start)

**start**
- `interrupted transition <id> pending — rerun: worker-next.sh start <ticket> <branch> …`
- `base change for active assignment <id> returns to the supervisor`
- `assignment <id> (<ticket>) is active — release it first`
- `ticket key '<key>' must look like TT-123` · `branch '<b>' must be <type>/<key>-<slug> …`
- `clone <dir> has uncommitted or untracked changes` (also release)
- `git status failed in <dir>` (also release, resumed start)
- `HEAD <sha> is not the last settled tip <sha> — a commit after release, or an …`
- `branch <b> already exists in the worker clone` · `branch <b> already exists on origin`
- `uncommitted or untracked changes — interrupted start <id> kept for the supervisor`
- `branch <b> moved during an interrupted start <id> — supervisor decides`
- a resumed start also refuses a process probe hit and, before the switch,
  `HEAD <sha> is not the last settled tip …`

**check**
- `no active assignment — message is stale` · `stale: active assignment is <id>` (also release)
- `assignment <id> is <state>` (also release) · `HEAD is on <x>, not <branch>`
- `base <sha> is not an ancestor of HEAD — base changed`
- `checkout has no worker contract (AGENTS.md ### Worker clone)`

**release**
- `assignment id '<id>' must be <key>-<yyyymmdd>-<hhmmss>[-<n>]`
- `no active assignment` · `HEAD of <dir> is not on <branch>`
- `cannot copy release.json to <dir> — release not recorded; fix the artifacts dir, …`
- `branch <b> is missing in <dir> — recreate it at its pushed or reflog tip …` — recover with
  `git -C <dir> branch <b> <sha>`, switch to it, rerun `release`
- `<n> commits on <branch> but no PR — pass --pr`
- `remote <branch> is at <sha>, not <tip> — reconcile before release`
- `ls-remote failed — PR state unknown` · `PR #<n> state unknown`
- `PR #<n> is not <branch> → <line> in <repo>` · `PR #<n> is <status> — merge or abandon it first`
- `PR #<n> is abandoned — not merged; pass --abandoned to close the assignment keeping …`
- `commits after PR #<n> (tip <tip>, PR source <src>, remote <live>)`
- `artifacts <dir> hold <kb> KB, over <max> KB — largest: …`
- `artifacts <dir> contain bin/ or obj/ — move them out`
- the size check and the `bin/`/`obj/` search are best-effort: a measurement error prints one
  `warning: artifacts <dir> could not be …` (`measured` when no size came back, `fully measured`
  for a partial sum), a search error prints `… could not be fully searched for bin/ or obj/`;
  neither refuses by itself — a partial sum is a lower bound and still compared, and a
  `bin/`/`obj/` the partial search found still refuses

## Settlement

`release` proves the branch is settled; `tip` is the local `refs/heads/<branch>`, `live` the
remote read with `git ls-remote --exit-code` (never the cached `origin/<branch>`).

| Outcome | Rule |
|---|---|
| `merged` | `--pr n`, PR `completed`, PR source `== tip`, live absent or `== tip` |
| `empty` | no `--pr`, `tip == base_sha`, live absent or `== tip` |
| `abandoned` | `--pr n --abandoned`, PR `abandoned`, live `== tip`, or absent + source `== tip` |

PR source is `lastMergeSourceCommit.commitId`. Anything else is refused. The PR must also match
repository, source `refs/heads/<branch>` and target `refs/heads/<line>`. Ancestry cannot detect a
squash merge — ADO's squash commit is never an ancestor of the worker branch — so only the exact
tip counts. `abandoned` is never `merged`. The branch is always kept locally as evidence; the
script never resets, cleans or deletes branches.

## Interrupted transitions

- **Before publication:** a `staging-<id>` dir is left. `status` lists it as `leftover:`; nothing
  deletes it. The next `start` ignores it.
- **After publication, before or after the switch:** `active/` is `switching`. Rerun the identical
  `start`; it resumes on the recorded `base_sha` (never re-resolved), skips the switch when HEAD is
  already on the branch, and refuses a dirty tree or a moved branch. It also runs the process
  probe and, before the switch, the settled-tip check of a fresh start. Other arguments are
  refused.
- **Release:** `release.json` is copied into the artifacts dir before `active/` moves to
  `history/<id>`; a failed copy leaves the assignment active and a rerun repeats the release.
  Idempotent — a rerun after `history/<id>/release.json` exists prints `already released` and
  re-copies `release.json` into the artifacts dir.
- **Stale `op.lock`:** the message says so; check that no `worker-next.sh` runs, then remove the
  `op.lock` dir by hand. The script never removes another holder's lock.

## Messages and the lock

- Every assignment message carries the assignment id.
- SolTT runs `bash .claude/lib/worker-next.sh check <id>` before each stage and before acting on
  an assignment-specific message. A missing/mismatched id blocks that work and is reported to
  the supervisor. Do not apply a late response to the current tree. Unrelated coordination,
  Operator instructions and stop requests remain actionable under their existing authority.
- SolTT never picks a ticket or a clone; an extra isolated clone needs an explicit supervisor order.

## Freezing base and tree for a phase

- `start` fetches and fixes `base_sha` before the plan; `check` verifies it is an ancestor of HEAD.
- Keep the base fixed throughout the assignment. Freeze the source tree for plan review,
  code reviews and the final gate; authorized implementation/fix stages may edit it.
- From the worker clone root, before each review run
  `bash .claude/lib/tree-fingerprint.sh capture <assignment-artifacts>/fp-<stage>`, then
  `bash .claude/lib/tree-fingerprint.sh compare <assignment-artifacts>/fp-<stage>` after all
  reviewers using that snapshot finish. Capture/compare failure blocks acceptance of that
  review; preserve evidence and return to the supervisor. Do not recapture to hide a mismatch.
- `check` verifies assignment identity, branch and base ancestry and prints hashes. It does not
  by itself prove that the reviewed tree stayed unchanged or that a review/gate completed.
- A base or scope change after plan approval returns to the supervisor.
- On a new assignment SolTT runs `/prime` in the clone first; `check` verifies the contract.

## Artifacts

- Layout under `<assignment-artifacts>/`: `brief*`, `review-*`, `fp-*`, `report.md`, `release.json`.
- Reports carry the `base sha`, `head` and `diff sha` that `check` prints.
- Limit 50 MB and no `bin/` or `obj/` — `release` refuses otherwise.
- Retention: 30 days after `released_at`, subject to any outstanding review/audit hold.
  The supervisor confirms the exact released assignment directory; existing ask-tier permissions
  still apply. Match its id and `release.json` to lifecycle history; resolve the path under the
  configured artifacts root. Reject the root, outside paths and symlink substitutions. A missing or
  inconsistent release record blocks pruning. Do not delete the clone or lifecycle history.

## Build policy

- `bin/obj` stay between assignments; `CLAUDE.md` Validation and the ticket smoke stay mandatory.
- For a cache or toolchain problem: `dotnet clean <project>.csproj` or
  `dotnet build --no-incremental`.
- Never `git clean -fdx`, never a broad deletion of ignored files.

## Stage 6 and merge

1. The supervisor runs and reads the mandatory final Validation result, confirms reviews and
   records Stage 6. Commit, push and `/pr-create` run with cwd = the worker clone under their
   separate authorization; this lifecycle guide does not grant it.
2. **`/pr-merge <pr-id>` from the main checkout only**, always with the explicit PR id:
   - without an argument it picks the PR of the invoking checkout's HEAD branch
     (`pr-merge.md` Step 2), which is the wrong PR from the main checkout;
   - its Step 6 switches and runs `branch -D` in the invoking checkout, so it must never run in
     the worker clone.
3. Then `bash .claude/lib/worker-next.sh release <id> --pr <n>` from the main checkout.
