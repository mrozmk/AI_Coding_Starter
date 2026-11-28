---
description: Run the regression suite against one named deployed environment and report the deterministic verdict (run | smoke | full | status | visual compare | visual update), or write specs for READY scenarios (author — 3 green passes, a critic, then a claim; author --refresh re-authors a stale header), or heal (diagnose a red spec; a TEST repair kept only behind weaken-check, 3 green passes and a critic); production needs a confirmation every time
argument-hint: "[run [smoke|full] | smoke | full | status | visual compare | visual update | author (<ID>… | --area <CODE> | --pending | --from-qa <file>) | heal (--run <run-id> | <spec>[ › <title>]) | author --refresh <ID>…] [--env <name>]"
allowed-tools: Bash(node .claude/lib/regression/run.mjs:*), Bash(node .claude/lib/regression/policy.mjs:*), Bash(node .claude/lib/regression/catalog.mjs:*), Bash(node .claude/lib/regression/author.mjs:*), Bash(node .claude/lib/regression/heal.mjs:*), Bash(node .claude/lib/regression/weaken-check.mjs:*), Bash(bash .claude/lib/costs/runtime-mark.sh stage end *), AskUserQuestion, Agent, Read, Write, Edit, Glob, Grep
---

# Regression tests — the deterministic run

## Input: $ARGUMENTS

Runs in the project's repo root. Contract: [.agents/reference/regression.md](../../.agents/reference/regression.md)
§10 (selection), §11 (the request guard), §12 (the run), §13 (the visual lane), §15 (the author
lane). The verdict is the script's — this command never judges a run and never reads a spec to
decide pass/fail.

## Guardrails (absolute)

- **Production: never pass `--confirm` without a `Run on production` answer to the confirmation question in this
  turn.** The token is the human's decision, not a formality: never reuse one from an earlier turn,
  never pass it on your own judgement, never retry a refused production run with a new token
  without asking again.
- **Never pass `--token` to `visual accept` without an `Accept baselines` answer to the acceptance
  question in this turn.** The same rule as the production token: never reuse one from an earlier
  turn, never accept on your own judgement, never retry a refused acceptance without asking again.
- `run`, `status` and `visual` never edit a spec or the catalog and never start a lane — a red run
  prints the `heal` command; you only relay it. A red run never starts `heal` or `author`; never
  start `visual update` from a `run` or on your own initiative — only when the user typed it.
- `author` writes only its own candidate spec files (created by `author.mjs draft`) and the critic
  and provenance verdict files in its verify run directory; it changes the catalog only through
  `author.mjs claim` and moves every unclaimed draft out with `author.mjs reject`.
- `heal` writes only its candidate, its probe and its heal directory; the claimed spec changes only
  through `heal.mjs apply`; it never writes the catalog, never calls `visual update` / `visual accept`,
  never commits.
- Never edit `.claude/regression.json`, the fixtures, the runner config or `.claude/settings*.json`;
  never start the app; never commit.
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
| `author <ID>…`, `author --area <CODE[,CODE]>`, `author --pending`, `author --from-qa <file>` | `## Author` |
| `heal --run <run-id>`, `heal <spec>[ › <title>]` | `## Heal` |
| `author --refresh <ID>…` | `## Heal` → Refresh |

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
printed, and say that `heal` is not started. INCOMPLETE → name what kept it
from green (a skipped / flaky case, no build SHA, a report error). BLOCKED/ENV → the stop reason;
the environment pushed back or the guard could not be attested — do not retry.

## Author

Writes specs for READY scenarios without one, following
[.claude/skills/regression/references/author.md](../skills/regression/references/author.md) (the
procedure) and [spec-rules.md](../skills/regression/references/spec-rules.md) (how a spec is
written). A spec is claimed only after three green passes with zero retries on every device project
of the scenario and a critic pass on the same digests. Run directory for the drafts:
`.agents/regression/runs/author-<UTC yyyymmddThhmmssZ>`.

1. **Select:** `node .claude/lib/regression/author.mjs select <the author arguments> [--env <name>]`.
   Exit 2 with `environments:` → one `AskUserQuestion` (a test environment first), rerun with
   `--env`. Exit 1 → nothing eligible: report the `refused:` / `not promoted:` / `skipped:` /
   `ambiguous:` lines and stop.
2. **Draft** each `eligible:` scenario: `node .claude/lib/regression/author.mjs draft <ID> --run <run dir>`
   (`--qa <ac_id>` for a `--from-qa` row) creates the empty target; then Write the spec at the
   printed path from the scenario, the code and the newest walk observations (and, `--from-qa`, the
   recorded sequence `select` printed).
3. **Lint:** `node .claude/lib/regression/author.mjs lint <spec> --id <ID>` — fix until clean.
4. **Verify:** `node .claude/lib/regression/run.mjs verify <ID>=<spec>… [--env <name>]`, one batch.
   Exit 3 with `confirmation-required:` → the production confirmation of Run step 3, verbatim; the
   token covers this verify's three passes only, and `Cancel` → step 7 for every draft. Exit 3
   otherwise (`refused: <ID> — …`) → fix what the refusal names or drop the scenario. `not
   verified:` → read the `context:` files, fix, verify again (at most two verify rounds before the
   critic).
5. **Critic:** for each `verified:` scenario spawn `@regression-critic` with `SCENARIO` (the block
   text, verbatim), `SPEC` and `ROUND`; write its JSON plus the three digests of the `verified:`
   line to `<verify run dir>/critic-<ID>.json`. `--from-qa` only: also spawn `@regression-critic`
   `MODE=provenance` with `QA_SEQUENCE` and `SPEC`, and write `<verify run dir>/provenance-<ID>.json`
   with the same three digests; an action without a recorded step is `revise`. `revise` → fix,
   re-verify, ask again. Limits: at most two clause rounds and two provenance rounds, at most four
   verify rounds in total.
6. **Claim:** `node .claude/lib/regression/author.mjs claim <ID> --spec <spec> --verify <verify run dir> --critic <critic file> [--provenance <file>]`
   → `claimed: <ID> — <spec>`. A `refused:` is reported; the draft goes to step 7.
7. **Reject** every registered draft that was not claimed, on every exit:
   `node .claude/lib/regression/author.mjs reject <ID> --run <run dir>`.
8. **Check:** `node .claude/lib/regression/catalog.mjs` and `node .claude/lib/regression/catalog.mjs --status`.

**Report** (in the project's language): claimed (spec path), rejected (and why), refused, not
promoted, ambiguous, the unobservable clauses (`unobservable:` lines of `--status`), and for
`--from-qa` the step map of every claimed spec (`spec step n ← QA step k`). Nothing is committed.

## Heal

Gives each red spec a class from a critic-qualified live check and repairs only a `TEST` spec,
following [.claude/skills/regression/references/heal.md](../skills/regression/references/heal.md)
(the procedure, the probe brief, the classes). Only when the user typed `heal` — a red run never
starts it.

1. **Select:** `node .claude/lib/regression/heal.mjs select --run <run-id>` (or `select <spec>[ › <title>]`
   with `--env <name>`). Exit 1 → report the `env:` / `stale:` / `refused:` / `nothing to heal` lines and stop.
2. **Start** each `eligible:` scenario: `node .claude/lib/regression/heal.mjs start <ID> --env <the record's env> --from-run <run-id>`
   → `heal: <dir>`. A `class: catalog-outdated` or `stop:` line ends that scenario (report it).
3. **Probe:** the probe sub-agent with heal.md § The probe brief (the block with `**Spec:**`
   removed; it never reads the existing spec), `node .claude/lib/regression/author.mjs lint <probe> --id <ID>`,
   `node .claude/lib/regression/heal.mjs probe-key <ID> --run <heal dir>`, `@regression-critic`
   `MODE=probe` → `<heal dir>/probe-critic-<ID>.json` (its JSON plus the three digests).
4. **Run the probe:** `node .claude/lib/regression/run.mjs probe <ID> --heal <heal dir> [--env <name>]`.
   Exit 3 with `confirmation-required:` → the production confirmation of Run step 3, verbatim; the
   token covers this probe's two passes only, and `Cancel` → `discard`.
5. **Classify:** `node .claude/lib/regression/heal.mjs classify <ID> --run <heal dir> --probe <probe run dir>`
   (the directory of the `record:` line) → `class: APP | TEST | env — …` or `stop: … — …`.
6. **Repair** (`TEST` only): edit the candidate only;
   `node .claude/lib/regression/weaken-check.mjs <heal dir>/before/<file> <candidate> --json`;
   `node .claude/lib/regression/run.mjs verify <ID>=<candidate> --heal <heal dir> [--env <name>]`;
   `@regression-critic` `MODE=heal` with `SCENARIO`, `SPEC`, `BEFORE`, `WEAKEN`, `HEAL_ID`,
   `BEFORE_SHA256`, `ROUND` → `<verify run dir>/critic-<ID>.json`. The author lane's round limits hold.
7. **Apply:** `node .claude/lib/regression/heal.mjs apply <ID> --run <heal dir> --verify <verify run dir> --critic <critic file>`
   → `healed: <ID> — <spec>`. A `conflict:` keeps both files for a human.
8. **Discard** on every other exit: `node .claude/lib/regression/heal.mjs discard <ID> --run <heal dir>`.

**Refresh** (`author --refresh <ID>…`): `heal.mjs select --refresh <ID>…`, `heal.mjs start <ID> --env <name> --refresh`,
rewrite only the candidate's header, then steps 6–7 with `weaken-check … --refresh` and `apply … --refresh`
→ `refreshed: <ID> — <spec>`.

**Report** (in the project's language): per scenario the class or stop and its evidence lines,
`healed:` / `refreshed:`, every `bug candidate:` (offer `/create-task`), every attempt discarded or
left open. Nothing is committed.

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
