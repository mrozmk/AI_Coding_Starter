---
description: Switch regression on in this project — the catalog stage writes .claude/regression.json, the baseline stage adds the runner and environments and copies the runner templates; --inventory catalogs an existing app from its code and a guarded walk; --check lists what the foundation still lacks
argument-hint: "[--check | --inventory]"
allowed-tools: Bash(node .claude/lib/regression/setup.mjs:*), Bash(node .claude/lib/regression/catalog.mjs:*), Bash(node .claude/lib/regression/run.mjs walk:*), Bash(node .claude/lib/regression/inventory.mjs:*), Bash(node .claude/lib/backlog-check.mjs:*), Bash(jq:*), Bash(bash .claude/lib/costs/runtime-mark.sh stage end *), AskUserQuestion, Agent, Read, Write, Edit, Glob, Grep
---

# Setup: Regression — switch the regression kit on

## Input: $ARGUMENTS

Runs in the project's repo root. Contract: [.agents/reference/regression.md](../../../.agents/reference/regression.md)
(the switch, the scenario block, the scripts); adapter contract:
[.agents/reference/regression-test-data.md](../../../.agents/reference/regression-test-data.md).
`--check` → run only Step 0's `setup.mjs check`, print its lines, stop. `--inventory` → Step 3.

## Guardrails (absolute)

- **Never overwrite** `.claude/regression.json` or a file in the project's e2e directory. Only
  `setup.mjs` writes `regression.json`; a template is copied only when its target is absent. Only
  `inventory.mjs apply` writes the catalog and the route list in the inventory step.
- Never edit `.claude/settings*.json`.
- Catalog and baseline stages and `--check`: never run a spec, start the app, install a package or
  reach the network — `setup.mjs check` is static. The inventory step reaches the environment
  **only** through `run.mjs walk` (the guard, the policy, the locks and the production
  confirmation); it never starts the app and never opens a browser itself.
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
  each gap) and stop; re-running a finished stage changes nothing. When the foundation is complete
  and `node .claude/lib/regression/catalog.mjs --json` shows 0 scenarios, recommend
  `/setup:regression --inventory` (an existing app: catalog it from its code and a walk).

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
   without credentials or a trailing slash, or `qa-env` to take `base_url` from `.claude/qa-env.json`;
   never a local server) and its `kind` — `test`, or production (the default). State the production
   defaults with the question: `writes: refuse`, one worker, guard allowlist = its own host, every
   WebSocket closed, a confirmation before every run; and that `default_env` may name only a test
   environment (regression.md §10). Write only `host`, `kind` and, when the user names one, a
   test `default_env` — every other policy key keeps its default until the project declares it.
2. Copy each template of `.claude/templates/regression/` into the e2e directory **only when the target
   is absent** — never overwrite: `playwright.config.ts.template` → `<e2e>/playwright.config.ts`,
   `fixtures.ts.template` → `<e2e>/fixtures.ts`, `spec-header.ts.template` → keep as
   `<e2e>/regression/_spec-header.example.ts`, `walk.spec.ts.template` → `<spec_dir>/_walk.spec.ts`
   (the inventory walk's stub; it registers no test outside a walk). Fill the placeholders each template lists — in both
   the config and the fixtures `<guard-module-relative>` is the path from the copied file's directory
   to `.claude/lib/regression/guard.mjs` (`<e2e>/…` → `../.claude/lib/regression/guard.mjs`); report
   every target that existed and was kept. A kept config or fixtures file from before the request
   guard does not import `guard.mjs`: say that a production run refuses it until both are re-copied
   (regression.md §11, migration).
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

## Step 3 — Inventory (existing app)

`--inventory`: a first catalog of an app that already runs — routes from the code, a guarded walk
of a deployed environment, scenario blocks a critic grades, applied by a script. Contract:
regression.md §13. Nothing is committed; the proposal and the walk stay in
`.agents/regression/runs/` (per machine).

1. **Preconditions.** `regression.json` has `runner` and `environments`, `catalog.mjs` exits 0, and
   this is not a team clone (`.agents/team/team.json` or `session.json` → stop: inventory runs from
   your own checkout). Otherwise name the missing stage and stop.
2. **The walk stub.** `<spec_dir>/_walk.spec.ts` absent → copy `walk.spec.ts.template` there,
   filling `<fixtures-relative>` (the path to the fixtures module without extension, e.g.
   `'../fixtures'`), `<guard-module-relative>` and `<walk-module-relative>` (the paths from the stub's
   directory to `.claude/lib/regression/guard.mjs` and `walk.mjs`). Present → keep it and say so.
3. **Environment.** One `AskUserQuestion`: which environment to walk — the `kind: test` ones first
   (recommended); state that a production walk asks for a confirmation naming the routes, the
   groups and every submit entry before any traffic.
4. **Stage:** `node .claude/lib/regression/inventory.mjs stage` → `stage: <dir>`.
5. **Routes.** Spawn `@regression-inventory` with `PHASE=routes`, `CATALOG` (path, areas, id pattern,
   existing ids, next free number per area) and `ROUND 1`. Write its JSON with the Write tool to
   `<stage>/routes.staged.json`, then
   `node .claude/lib/regression/inventory.mjs check-staged --routes <stage>/routes.staged.json` —
   errors go back to the agent once (`PRIOR` = the lines); still failing → report and stop.
6. **Walk:** `node .claude/lib/regression/run.mjs walk --env <E> --routes <stage>/routes.staged.json`.
   Exit 2 → the walk refused before any traffic and wrote nothing (the route list unreadable or
   invalid, the walk stub missing, no desktop project, an unknown environment, an invalid catalog or
   configuration): with `environments:` → the environment was unknown — ask step 3's question again
   and rerun with its `--env`; `walk stub missing` → do step 2, then rerun; otherwise report the
   stderr lines and stop. Exit 3 with `confirmation-required: <token>` → the production confirmation question exactly as in
   `/regression-tests` → Run step 3 (`Run` / `Cancel`; `Run` re-runs with `--confirm <token>`);
   `Cancel` → stop, nothing written. Exit 4 (INCOMPLETE) or 5 (BLOCKED/ENV) → report the `reason:`
   lines and stop. Exit 0 → `walk: COMPLETE`, `observations: <file>`, `record: <walk run dir>/walk.json`.
7. **Scenarios.** `MODE=gaps` when `.agents/backlog.md` exists or a catalog scenario cites a
   criterion, else `MODE=full`. Spawn `@regression-inventory` with `PHASE=scenarios`, `MODE`,
   `CATALOG`, `ROUTES` (the staged file), `OBSERVATIONS`, `BACKLOG` (gaps) and `ROUND 1`; write its
   markdown block to `<stage>/proposal.md` and its JSON to `<stage>/proposal.json`.
8. **Dry run, then the critic** (at most two rounds, no human gate):
   1. `node .claude/lib/regression/inventory.mjs apply --dry-run --stage <stage> --walk <walk run dir>`.
      A mechanical refusal goes back to the agent (`PRIOR` = the refusal) before any critic sees the
      proposal; the last dry run prints `proposal: <digest>`.
   2. Spawn `@start-critic` with `RUBRIC=.claude/skills/regression/catalog-rubric.md`,
      `ARTIFACT=<stage>/proposal.md <stage>/proposal.json`, `SOURCES` = `<stage>/routes.staged.json`,
      the observations, the catalog files and every `sources.<id>.code` file — in gaps mode also
      the files the claimed criteria resolve from: `.agents/backlog.md`, the Epic files and every
      approved spec in a cited Task's `Ref` (`node .claude/lib/backlog-check.mjs --next-ids <Task>`
      → `source`) — and `ROUND 1`. Note the digest this round reviewed.
   3. `revise` / `rethink` → re-spawn the inventory agent with `PRIOR` = the findings, rewrite both
      files, dry-run again, then `@start-critic` `ROUND 2`. The findings round 2 leaves open, and
      every `C9` finding of either round, make up the **suspicious list**.
9. **Apply:** `node .claude/lib/regression/inventory.mjs apply --stage <stage> --walk <walk run dir> --expect-proposal <the digest the last critic round reviewed>`.
   **Only a digest a critic round reviewed is ever published**; the script refuses a proposal changed
   since, before any write. A refusal of the reviewed proposal:
   - **a critic round left:** the agent fixes it, then dry run → critic → apply with that round's
     digest;
   - **both rounds used:** nothing is written; the proposal stays in the stage, and the report names
     the refusal and the stage path. A rerun starts a fresh inventory step.
10. **Check:** `node .claude/lib/regression/inventory.mjs check`,
    `node .claude/lib/regression/catalog.mjs --status`, `node .claude/lib/regression/inventory.mjs split`.
11. **Report:** the walk verdict and record, the `applied:` / `skipped:` ids, route coverage (the
    `check` lines), the suspicious list (read it once — it is not a gate), and the proposed baseline
    Tasks from `split` (`part <k>: …` with its title): with a backlog through `/update-backlog`,
    without one through `/create-task`. Nothing is committed.

## Report

The stage run, what was written (or kept), the `setup.mjs check` lines verbatim, and the next step
(`catalog` phase: write scenarios with each Task; baseline: implement the adapter until `check` says
`foundation complete`; an existing app with 0 scenarios: `--inventory`). The inventory step reports
as Step 3.11 says.

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
