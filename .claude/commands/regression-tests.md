---
description: Run the regression suite against one named deployed environment and report the deterministic verdict (run | smoke | full | status); production needs a confirmation every time
argument-hint: "[run [smoke|full] | smoke | full | status | visual compare | visual update] [--env <name>]"
allowed-tools: Bash(node .claude/lib/regression/run.mjs:*), Bash(node .claude/lib/regression/policy.mjs:*), Bash(node .claude/lib/regression/catalog.mjs:*), Bash(bash .claude/lib/costs/runtime-mark.sh stage end *), AskUserQuestion, Read
---

# Regression tests — the deterministic run

## Input: $ARGUMENTS

Runs in the project's repo root. Contract: [.agents/reference/regression.md](../../.agents/reference/regression.md)
§10 (selection), §11 (the request guard), §12 (the run), §13 (the visual lane). The verdict is the script's — this command
never judges a run, never reads a spec to decide pass/fail, never edits a spec or the catalog.

## Guardrails (absolute)

- **Production: never pass `--confirm` without a `Run on production` answer to the confirmation question in this
  turn.** The token is the human's decision, not a formality: never reuse one from an earlier turn,
  never pass it on your own judgement, never retry a refused production run with a new token
  without asking again.
- **Never pass `--token` to `visual accept` without an `Accept baselines` answer to the acceptance
  question in this turn.** The same rule as the production token: never reuse one from an earlier
  turn, never accept on your own judgement, never retry a refused acceptance without asking again.
- Never start `heal` or `author`; never start `visual update` from a `run` or on your own
  initiative — only when the user typed it. A red run prints the `heal` command; you only relay it.
- Never edit `.claude/regression.json`, a spec, the fixtures or `.claude/settings*.json`; never
  start the app; never commit.
- In a team clone the script refuses (exit 3): say so and stop — a regression run happens from the
  developer's own checkout.

## Modes

| `$ARGUMENTS` | Action |
|---|---|
| empty, `run` | `run smoke` |
| `run smoke`, `smoke` | `run smoke` |
| `run full`, `full` | `run full` |
| `status` | `catalog.mjs --status`, then `run.mjs status` |
| `visual compare` | `run.mjs visual compare` (§ Visual) |
| `visual update` | `run.mjs visual update`, then the acceptance question (§ Visual) |
| `author`, `heal` | "not yet shipped" (regression.md §4) — stop |

`--env <name>` passes through to `run.mjs` (and to `run.mjs status`). Anything else → print the
argument hint and stop.

## Run

1. Run, as its own Bash call:

   ```bash
   node .claude/lib/regression/run.mjs run <mode> [--env <name>]
   ```

2. Read the exit code and the printed lines:

   | Exit | Meaning | Next |
   |---|---|---|
   | 0 · 1 · 4 · 5 | GREEN · RED · INCOMPLETE · BLOCKED/ENV | Report (below). |
   | 2 with an `environments:` line | no target resolved | One `AskUserQuestion` listing those names (a test environment first); rerun with `--env <answer>`. |
   | 2 otherwise | not adopted, config error, invalid catalog, baseline not established | Report the printed lines verbatim; point at `/setup:regression --check` or the catalog error. Stop. |
   | 3 with `confirmation-required: <token>` | production confirmation | Step 3. |
   | 3 otherwise | refused: team clone, lock held (pid, run id), runner not guard-integrated | Report the refusal verbatim. Stop. |

3. **Production confirmation.** Show the confirmation text the script printed (every line between
   the plan lines and `confirmation-required:`), **verbatim**, in one `AskUserQuestion` with the
   options `Run on production` and `Cancel`. Only on `Run on production`, rerun:

   ```bash
   node .claude/lib/regression/run.mjs run <mode> --env <name> --confirm <token>
   ```

   `Cancel` → stop, nothing ran. An exit 3 `confirmation invalid: <why>` (expired, reused, the plan
   changed) prints a fresh token: ask again with the new text — never confirm on the user's behalf.

## Visual

1. Run, as its own Bash call:

   ```bash
   node .claude/lib/regression/run.mjs visual <compare|update> [--env <name>]
   ```

2. Read the exit code and the printed lines:

   | Exit | Meaning | Next |
   |---|---|---|
   | 0 · 1 · 4 · 5 | GREEN · RED · INCOMPLETE · BLOCKED/ENV | Report (below); for `update` also the `visual offer: none — <why>` line. |
   | 2 | not adopted, config error, `visual not configured`, a widened tolerance, no target | As Run step 2 (an `environments:` line → ask, rerun); otherwise report verbatim and stop. |
   | 3 with `confirmation-required:` | production confirmation | As Run step 3, rerunning `visual <action> --env <name> --confirm <token>`. |
   | 3 with `acceptance-required: <token>` | `update` offers new baselines | Step 3. |
   | 3 otherwise | refused (team clone, lock held, not guard-integrated, overlapping baselines) | Report verbatim. Stop. |

3. **Acceptance.** Show every `visual offer:` line the script printed, **verbatim**, and the
   candidate paths to open, in one `AskUserQuestion` with the options `Accept baselines` and
   `Cancel`. Only on `Accept baselines`, run (the run id is the directory of the `record:` line):

   ```bash
   node .claude/lib/regression/run.mjs visual accept --run <run-id> --token <token>
   ```

   `Cancel` → stop, nothing is written. An exit 3 from `accept` (`stale offer`, expired, changed
   since the offer) → report it; a new `visual update` is the only way to a new token. Exit 0 →
   relay `accepted: …` and say the baselines are committed with `/commit`.

## Report

In the project's language: the target environment and host, the mode, the verdict, the build SHA,
the `reason:` and `warning:` lines, the `not run — policy` list, the `visual:` and every `visual
portability:` line (`run full` and `visual …`), and the record path (`record: …`). RED → print the `next: /regression-tests heal --run <run-id>` line the script
printed, and say that `heal` is not started (and not yet shipped). INCOMPLETE → name what kept it
from green (a skipped / flaky case, no build SHA, a report error). BLOCKED/ENV → the stop reason;
the environment pushed back or the guard could not be attested — do not retry.

## Status

```bash
node .claude/lib/regression/catalog.mjs --status
node .claude/lib/regression/run.mjs status [--env <name>]
```

Print both outputs; the run records are per machine (`.agents/regression/runs/`, never committed).

## Stage end marker (token usage)

At this command's definitive end — its work is done, or it stops for good (STOP, refusal, blocker) —
run exactly this once, as its own Bash call from the repo root with nothing chained before or after
it, as the last step **before** the final report (or handback):

`bash .claude/lib/costs/runtime-mark.sh stage end regression-tests`

Never at a pause that waits for the user (a question, an approval): the stage goes on after the
answer, and a plain reply records no new start. The call writes nothing itself; when the team
harness has registered the stage hook, the hook records it as this stage's end for
`cost.py report --by-stage` (`.agents/reference/token-usage.md` → Stages). Without the hook, and
inside a sub-agent, it does nothing.
