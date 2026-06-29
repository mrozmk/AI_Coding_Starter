# Reference: spawning `codex exec` as a background review (the canonical pattern)

The single source of truth for how any slash command launches Codex (`codex exec`) in the
background for a cross-model review. `/plan-feature` (Phase 7), `/brainstorm` (Step 8.4), and
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
2. **HARD_KILL too low for the chosen reasoning effort.** The user's `~/.codex/config.toml` sets
   `model_reasoning_effort = "xhigh"` globally — by design: a review wants full model power. xhigh
   takes many minutes; a low ceiling murders a slow-but-alive process and reads as "codex stopped".
   **The fix is a high `HARD_KILL` ceiling, NOT a weaker model.** Lower reasoning effort was tried
   and rejected — it degrades the review to buy speed nobody asked for.
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
| `SANDBOX` | no (def `read-only`) | only applied when `SCHEMA` is **unset** (see below) |
| `CODEX_EFFORT` | no | reasoning override (low/medium/high/xhigh). **Unset == inherit config xhigh — leave it unset.** |

The wrapper bakes in, non-negotiably: `< /dev/null`, `-C "$REPO"`, `--skip-git-repo-check`,
`--output-last-message "$OUT"`, stdout → `$OUT.stdout`, stderr → `$LOG`.

**`SCHEMA` and `SANDBOX` are mutually exclusive.** `--sandbox read-only` combined with
`--output-schema` has hung in testing, so the wrapper applies `--sandbox` *only when `SCHEMA` is
unset*. Structured reviews (with `SCHEMA`) enforce read-only via the prompt instead; prose reviews
(no `SCHEMA`) get the real `--sandbox read-only`. Don't try to set both.

### Invocation (always `run_in_background: true`, never a trailing `&`)

```bash
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
     gained since last check = alive at xhigh, not hung), emit one heartbeat line, `ScheduleWakeup`
     again at `POLL_INTERVAL`. A long elapsed time with a growing log is NORMAL for xhigh.
   - task still running AND elapsed `>= HARD_KILL` → `TaskStop task_id=<id>`, treat as fail-open
     skip.
4. **Never busy-wait with foreground `sleep`** (blocks the thread, burns context) and **never**
   `timeout codex …` — `timeout`/`gtimeout` are not installed by default on macOS. Suspend with
   `ScheduleWakeup`; the thread sleeps between checks instead of spinning.

`HARD_KILL` is a **backstop for a genuinely hung process, not a budget for a slow one.** Retune the
ceiling if codex needs longer; never retune by lowering reasoning effort.

---

## Current ceilings (per command)

| Command | FIRST_CHECK | POLL_INTERVAL | HARD_KILL |
|---------|-------------|---------------|-----------|
| `/plan-feature` Phase 7 | 6 min | 3 min | 50 min (per round, min 2 rounds) |
| `/brainstorm` Step 8.4 | 4 min | 3 min | 40 min (single round) |
| `/codex-review` | (long-wakeup fallback; heartbeat from log is primary) | — | no hard ceiling — relay heartbeats, kill only on a genuine hang |

Retune these in the command files; keep this table in sync.
