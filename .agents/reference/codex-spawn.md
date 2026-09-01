# Reference: spawning `codex exec` as a background review (the canonical pattern)

The single source of truth for how any slash command launches Codex (`codex exec`) in the
background for a cross-model review. `/plan-feature` (Phase 7), `/brainstorm` (Step 8.4),
`/check-implementation` (Step 1.5), `/orchestrate` (Phase 7 step 0), and
`/codex-review` all link here. The executable form is `.claude/lib/codex-bg.sh` — this file is the
*why*; the wrapper is the *how*. If you add a new command that runs codex, reuse the wrapper and
link here; do **not** copy a fresh `codex exec` invocation into the command (that drift is exactly
what this pattern exists to kill).

---

## The golden rule

> **`codex` exit 0 + an empty output file does NOT mean "codex finished with nothing".**

It almost always means one of:
1. **stdin-hang** — codex blocked waiting on stdin that never arrives (missing `< /dev/null`).
2. **still working** — the harness `task-notification completed (exit 0)` is the *launcher/subshell*
   exiting, not codex; or codex is mid-think at high reasoning effort.
3. **killed** — the polling loop hit `HARD_KILL` and stopped a slow-but-alive process.

**Always assert `[ -s "<out-file>" ]` BEFORE you treat a run as done or as a parse failure.** A
non-empty `--output-last-message` file — written once, at the very end — is the only trustworthy
"codex finished with a result" signal. Process exit alone is not.

---

## Root cause (verified — codex-cli 0.142.3, gpt-5.5)

Three independent failure modes, all closed by the pattern below:

1. **stdin-hang.** `codex exec` reads instructions from stdin when stdin is piped
   (`codex exec --help`: "If stdin is piped … stdin is appended as a `<stdin>` block"). Backgrounded
   by the harness, stdin is not a TTY, so without `< /dev/null` codex can block *before it starts
   thinking* → looks hung → gets killed. **`< /dev/null` is the universal fix.**
2. **HARD_KILL too low for the reasoning effort.** The effort level is now pinned per caller
   (`CODEX_EFFORT`, see the effort matrix) and the user's `~/.codex/config.toml` default is **not
   consulted any more** — it drifted silently between machines (documented as `xhigh`, actually
   `high`). At `high` a review still takes many minutes; a low ceiling murders a slow-but-alive
   process and reads as "codex stopped". **The fix is a high `HARD_KILL` ceiling, NOT a weaker
   model.** Lowering the effort to buy speed was tried and rejected — it degrades the review.
3. **double-backgrounding.** The old pattern used a shell `&` + `echo $!` + a PID liveness probe.
   That double-backgrounds the call: `$!` names the launcher (exits 0 instantly) → false "done".
   **One level of backgrounding only:** the harness' `run_in_background: true`, never a trailing `&`.

---

## The contract (`.claude/lib/codex-bg.sh`)

Call the wrapper, never raw `codex exec`. Pass via env vars:

| Var | Req? | Meaning |
|-----|------|---------|
| `PROMPT` | yes | the full review prompt string |
| `OUT` | yes | `--output-last-message` path — the clean result. **Non-empty == done.** |
| `LOG` | yes | the noisy run log — **grows while codex thinks** (the liveness signal) |
| `REPO` | no (def `$PWD`) | repo root for `-C` — never run codex in `/tmp` (non-trusted dir hangs) |
| `SCHEMA` | no | `--output-schema` path for structured JSON (plan-feature, brainstorm). Omit for prose (codex-review). |
| `SANDBOX` | no (def `read-only`) | only applied when `SCHEMA` is **unset** (see below). `workspace-write` is reserved for the executor / fixer modes below. |
| `CODEX_EFFORT` | **yes** | reasoning level (low/medium/high/xhigh). Pinned per caller — see the effort matrix below. The wrapper refuses to spawn without it. |

The wrapper bakes in, non-negotiably: `< /dev/null`, `-C "$REPO"`, `--skip-git-repo-check`,
`--output-last-message "$OUT"`, `-c model_reasoning_effort=$CODEX_EFFORT`, stdout → `$OUT.stdout`,
stderr → `$LOG`.

**`SCHEMA` and `SANDBOX` are mutually exclusive.** `--sandbox read-only` combined with
`--output-schema` has hung in testing, so the wrapper applies `--sandbox` *only when `SCHEMA` is
unset*. Structured reviews (with `SCHEMA`) enforce read-only via the prompt instead; prose reviews
(no `SCHEMA`) get the real `--sandbox read-only`. Don't try to set both.

## Effort matrix (per caller — the single source of truth)

Every caller quotes its level in its own spawn snippet; this table is where a change starts.
`high` for everything that judges; `medium` for the one caller that writes production code from a
finished plan (a plan is already the thinking — the executor needs speed and obedience, and Claude
re-validates everything).

| Caller | `CODEX_EFFORT` | `SANDBOX` |
|--------|----------------|-----------|
| `/brainstorm` Step 8 | `high` | (unset — `SCHEMA` run) |
| `/plan-feature` Phase 7 | `high` | (unset — `SCHEMA` run) |
| `/codex-review` | `high` | `read-only` (default) |
| `/check-implementation` Step 1.5 (also `/orchestrate` Phase 7 step 0) | `high` | (unset — `SCHEMA` run) |
| `/quick-change` Phase 2 | `high` | `read-only` (default) |
| `/architecture-review --codex` | `high` | `read-only` (default) |
| `/execute codex` (executor) | `medium` | `workspace-write` |
| `/check-implementation codex` (fixer) | `high` | `workspace-write` |

Never lower a level to make a run finish sooner — retune the caller's `HARD_KILL` instead.

### Invocation (always `run_in_background: true`, never a trailing `&`)

```bash
CODEX_EFFORT=high \
PROMPT="<review prompt>" \
OUT="<scratch>/codex.final.md" \
LOG="<scratch>/codex.log" \
SCHEMA="<schema-file>" \   # omit for a prose review
REPO="<repo-root>" \
bash .claude/lib/codex-bg.sh
```

Record the returned **task ID** and the start time (the harness timestamps each turn).
Codex's stdout is empty by design — the review lives in `OUT`. An empty `.stdout` is EXPECTED.

---

## The polling loop (stays in the command, not the wrapper)

The wrapper only guarantees a correct spawn. Lifecycle is the command's job. Each command sets its
own `FIRST_CHECK` / `POLL_INTERVAL` / `HARD_KILL` (a plan review is heavier than a spec review), but
the shape is identical:

1. **Spawn** (above), `run_in_background: true`. Note task ID + start time.
2. **Head-start:** `ScheduleWakeup` `delaySeconds = FIRST_CHECK` — do not poll before this. Pass the
   command's own input verbatim as the wakeup `prompt` so the loop resumes itself.
3. **On each wake-up / `<task-notification>`, decide state from the artifact (NOT a PID, NOT exit
   code), in order:**
   - `OUT` non-empty → **DONE-OK** → parse / read the review.
   - task exited but `OUT` empty/absent → **DONE-FAILED** → retry once, else fail-open skip. (Never
     read an empty file as a clean "no findings" result.)
   - task still running AND elapsed `< HARD_KILL` → confirm the **log is still growing** (bytes
     gained since last check = alive at high, not hung), emit one heartbeat line, `ScheduleWakeup`
     again at `POLL_INTERVAL`. A long elapsed time with a growing log is NORMAL for high.
   - task still running AND elapsed `>= HARD_KILL` → `TaskStop task_id=<id>`, treat as fail-open
     skip.
   - **Cancel the wakeup on every exit path.** Call `ScheduleWakeup stop: true` the moment the
     result is in hand — on DONE-OK, on DONE-FAILED **before** any re-spawn, on parse failure
     **before** any re-spawn, and right after a hard kill. A retry schedules its own fresh wakeup. A
     `<task-notification>` never cancels a pending wakeup: the stale wakeup
     fires later and re-invokes the command on top of finished work.
4. **Never busy-wait with foreground `sleep`** (blocks the thread, burns context) and **never**
   `timeout codex …` — `timeout`/`gtimeout` are not installed by default on macOS. Suspend with
   `ScheduleWakeup`; the thread sleeps between checks instead of spinning.

`HARD_KILL` is a **backstop for a genuinely hung process, not a budget for a slow one.** Retune the
ceiling if codex needs longer; never retune by lowering reasoning effort.

---

## Executor mode (write sandbox)

`/execute codex` and `/check-implementation codex` are the only callers that let Codex **write**.
They pass `SANDBOX=workspace-write` and no `SCHEMA` (the result is a prose report). Verified
2026-08-31 (codex-cli 0.149.1): the run log header shows `approval: never`,
`sandbox: workspace-write [workdir, /tmp, $TMPDIR]`, network off.

**Supported scope:** product code and tests. A plan that touches `.claude/`, `.agents/`, `.git/` or
`.env*` is refused **before** the spawn — the supervisor checks the plan's task paths and STOPs.

**Preconditions (the supervisor, i.e. Claude, enforces them):**
- `codex` on PATH — otherwise STOP with a pointer to the Claude executor. Never a silent fallback.
- Clean tree (`git status --porcelain` empty). A write-enabled Codex never runs on uncommitted work.
- **Git baseline** — `bash .claude/lib/git-baseline.sh capture <dir>` before the spawn,
  `… compare <dir>` after it (one script, so both callers and both sides of the wait take the
  identical snapshot). It covers HEAD, branch, stash OIDs, every ref, the index listing, the
  `.git/config` hash, the ignored-file **list** (a vanished entry = `git clean -fdx`, invisible to
  `git status`; new entries are `INFO` — validation runs create caches) and a hash of every
  secret-looking ignored file (`.env*`, keys, PEMs, `user-profile.md`; vendored/cache trees
  excluded). Hashed, never copied. Any `DEVIATION` line is 🔴; Claude never restores a secret — the
  human does, from their own source.

**Write-mode terminal states — an explicit exception to the golden rule's "retry once":**

| State | Meaning | Action |
|-------|---------|--------|
| exited + `OUT` empty + **no delta** since the pre-spawn snapshot | never got going | DONE-FAILED → stop sentence → retry once |
| exited + `OUT` empty + **delta present** | worked, then died before reporting | DONE-NO-REPORT → stop sentence → **never re-run the same prompt**; run the full supervisor verification on the delta and say Codex returned no report |
| exited + `OUT` non-empty | finished | DONE-OK |
| elapsed `>= HARD_KILL` | hung | `TaskStop`, stop sentence → **STOP, no retry** (the write-mode ceilings are the budget) |

"Delta" is measured against the pre-spawn `git status --porcelain`, never as "porcelain empty" —
the fixer's iterations 2–3 and the executor's corrective re-spawn run on an already-dirty tree. The
precise rule: **never re-run the same prompt on a tree that already carries its partial output**
(that double-applies edits). A corrective spawn with a different prompt on a fresh baseline is
allowed. The golden rule's text stays as written for reviewers.

**Prompt guardrails — the canonical block.** Each caller pastes it whole and adds only its own
delta: the executor adds "stay inside the plan's files and their tests"; the fixer reports each
finding as `applied` / `skipped — <reason>` instead of `## Deviations`.
- Orient via the quick-mode steps of `.claude/commands/prime.md` (read the file — Codex has no
  slash commands; do not try to run it). Two carve-outs: read `CLAUDE.md` in full (prime.md's
  "already injected" note is false for Codex) and skip prime.md's repo-state step (`git rev-list`
  is outside the allowlist). Ignore LSP / Context7 / MCP bullets wherever they appear — the plan's
  `file:line` references and API notes are the documentation.
- Never tick a `- [ ]` marker — they are parse anchors for `/gates:verify-implementation`.
- **Git is read-only, and it is an allowlist, not a denylist:** only `git status`, `git diff`,
  `git log`, `git show`, `git ls-files`, `git rev-parse`, `git branch --show-current`. Everything
  else — add, commit, push, reset, checkout, restore, stash, clean, tag, config, update-ref,
  worktree, … — is forbidden.
- Never write under `.agents/`, `.claude/`, `.git/`; never touch `.env*`; never delete a file you
  did not create in this run.
- No documentation access (network is off). A step you cannot complete without it is stopped and
  listed under `## Deviations` — never guessed at.

**Supervisor re-validation is mandatory.** Codex's report is data, not a verdict: Claude re-runs
the validation commands and `/gates:verify-implementation` itself, and STOPs on any forbidden or
out-of-scope change instead of reverting it.

`.git/` is protected by the sandbox: **yes** — verified 2026-08-31 (codex-cli 0.149.1, `SANDBOX=workspace-write`, scratch repo): `printf x > .git/PROBE` → `DENIED: operation not permitted`, file absent afterwards. This is not a licence to drop the git baseline compare — it is mandatory in both outcomes and is what detects metadata tampering; the prompt prohibition on `.git/` stays.

---

## Current ceilings (per command)

| Command | FIRST_CHECK | POLL_INTERVAL | HARD_KILL |
|---------|-------------|---------------|-----------|
| `/plan-feature` Phase 7 | 6 min | 3 min | 50 min (per round, min 2 rounds) |
| `/brainstorm` Step 8.4 | 4 min | 3 min | 40 min (single round) |
| `/codex-review` | (long-wakeup fallback; heartbeat from log is primary) | — | no hard ceiling — relay heartbeats, kill only on a genuine hang |
| `/quick-change` Phase 2 | 4 min | 3 min | 25 min — then proceed without the opinion, reported on its own line |
| `/architecture-review --codex` Phase 0 | 8 min | 5 min | 60 min (whole-codebase sweep) — then render the report from one sweep |
| `/execute codex` (executor) | 8 min | 3 min | 90 min — then STOP, tree left as-is, plan not moved |
| `/check-implementation codex` (fixer) | 6 min | 3 min | 60 min — then STOP, "fixer failed" |

> `/quick-change` is the one caller with a **short** ceiling, and deliberately so: it reviews a plan
> for a small change, so a run past 25 minutes is a hang, not depth. Its lane must stay fast — the
> fail-open is the review being *reported as missing*, never the command stalling.

Retune these in the command files; keep this table in sync.
