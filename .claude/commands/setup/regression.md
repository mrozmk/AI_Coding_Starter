---
description: Switch regression on in this project — the catalog stage writes .claude/regression.json, the baseline stage adds the runner and environments and copies the runner templates; --check lists what the foundation still lacks
argument-hint: "[--check]"
allowed-tools: Bash(node .claude/lib/regression/setup.mjs:*), Bash(node .claude/lib/regression/catalog.mjs:*), Bash(jq:*), Bash(bash .claude/lib/costs/runtime-mark.sh stage end *), AskUserQuestion, Read, Write, Edit
---

# Setup: Regression — switch the regression kit on

## Input: $ARGUMENTS

Runs in the project's repo root. Contract: [.agents/reference/regression.md](../../../.agents/reference/regression.md)
(the switch, the scenario block, the scripts); adapter contract:
[.agents/reference/regression-test-data.md](../../../.agents/reference/regression-test-data.md).
`--check` → run only Step 0's `setup.mjs check`, print its lines, stop.

## Guardrails (absolute)

- **Never overwrite** `.claude/regression.json` or a file in the project's e2e directory. Only
  `setup.mjs` writes `regression.json`; a template is copied only when its target is absent.
- Never edit `.claude/settings*.json`.
- Never run a spec, start the app, install a package or reach the network — `setup.mjs check` is static.
- Never commit: the human commits the result with `/commit`.
- Web projects only: when the project has no web frontend, say so and stop.

## Step 0 — State probe

```bash
node .claude/lib/regression/setup.mjs check
jq 'keys' .claude/regression.json
```

- No `regression.json` → **catalog stage** (Step 1).
- `catalog` only (no `runner` or no `environments`) → **baseline stage** (Step 2).
- `catalog`, `runner` and `environments` present → print the `check` lines (`foundation complete`, or
  each gap) and stop; re-running a finished stage changes nothing.

## Step 1 — Catalog stage

1. Propose area codes (2–10 chars, `^[A-Z][A-Z0-9]{1,9}$`) with a name each: from the node ids of
   `docs/map/system.yaml` when it exists, else from the app's route list (the router file or the
   pages directory). Keep it to the user-facing areas.
2. One `AskUserQuestion`: the proposed `CODE=Name` list (recommended first), the catalog path
   (default `.agents/regression/scenarios`) and the smoke priorities (default `P0`).
3. Write:

   ```bash
   node .claude/lib/regression/setup.mjs catalog --areas CODE=Name,CODE=Name [--path <dir>] [--smoke P0,P1]
   ```

   `regression.json exists — unchanged` → it was already there; nothing was written.
4. Report: the catalog phase is on; scenarios are written per Task; the baseline stage comes when a
   deployed environment and test accounts exist.

## Step 2 — Baseline stage

1. Ask (one `AskUserQuestion`): the e2e directory (default `e2e`), the device names (runner projects
   for `desktop` and `mobile`), and the environments — for each a name, its host (an `http(s)://` URL
   without credentials or a trailing slash, or `qa-env` to take `base_url` from `.claude/qa-env.json`) and whether it
   is a test environment (`kind: "test"`; otherwise it is production).
2. Copy each template of `.claude/templates/regression/` into the e2e directory **only when the target
   is absent** — never overwrite: `playwright.config.ts.template` → `<e2e>/playwright.config.ts`,
   `fixtures.ts.template` → `<e2e>/fixtures.ts`, `spec-header.ts.template` → keep as
   `<e2e>/regression/_spec-header.example.ts`. Fill the placeholders each template lists; report every
   target that existed and was kept.
3. Build the fragment with whichever of `runner` / `environments` is absent (shape:
   `.claude/regression.json.example`; every path repo-root-relative) and write it with the Write tool
   to the session scratchpad, then:

   ```bash
   node .claude/lib/regression/setup.mjs baseline --fragment <scratchpad>/regression-fragment.json
   node .claude/lib/regression/setup.mjs check
   ```

4. When `check` reports `@playwright/mcp not pinned` for a server in `.mcp.json`, propose the exact pin
   (`@playwright/mcp@<x.y.z>`, the version the team uses) and make that one edit with the Edit tool
   after a yes.
5. The test-data adapter (`check | provision | reset | session`) is project code: point at
   `regression-test-data.md` for what each `test_data` command must do; `check` lists the ones whose
   program file is still missing.

## Report

The stage run, what was written (or kept), the `setup.mjs check` lines verbatim, and the next step
(`catalog` phase: write scenarios with each Task; baseline: implement the adapter until `check` says
`foundation complete`).

## Stage end marker (token usage)

At this command's definitive end — its work is done, or it stops for good (STOP, refusal, blocker) —
run exactly this once, as its own Bash call from the repo root with nothing chained before or after
it, as the last step **before** the final report (or handback):

`bash .claude/lib/costs/runtime-mark.sh stage end setup-regression`

Never at a pause that waits for the user (a question, an approval): the stage goes on after the
answer, and a plain reply records no new start. The call writes nothing itself; when the team
harness has registered the stage hook, the hook records it as this stage's end for
`cost.py report --by-stage` (`.agents/reference/token-usage.md` → Stages). Without the hook, and
inside a sub-agent, it does nothing.
