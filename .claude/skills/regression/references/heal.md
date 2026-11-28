# The heal lane — procedure (`/regression-tests heal`, `/regression-tests author --refresh`)

Gives every red spec a class from a live check and repairs only a spec that the check shows is
wrong about a working app. A repair is kept only behind `weaken-check`, three green passes of the
repaired spec and a critic pass on the same bytes. Read with `author.md` (§2 how a spec is written),
`spec-rules.md` and `.agents/reference/regression.md` §17 (the scripts' contract).

Nothing in the lane commits. It writes only its candidate (`<spec dir>/<id>.heal.spec.ts`), its
probe (`<spec_dir>/_heal/<id>.probe.spec.ts`) and its heal directory
(`.agents/regression/runs/heal-…/`); the claimed spec changes in one place only — `heal.mjs apply`.
It never writes the catalog and never calls `visual update` / `visual accept`.

## 1. Select

- From a red run: `node .claude/lib/regression/heal.mjs select --run <run-id>` — the scenarios
  with a failed case in that `record.json`, plus `env: <the record's environment>`. A `BLOCKED/ENV`
  record selects nothing: each red scenario prints `env: <ID> — the run was BLOCKED/ENV: <reason>`
  (or `stale:` when its spec lags the catalog) — rerun when the environment is healthy.
- One spec: `heal.mjs select <spec>[ › <title>]` (the `Spec` field's path, the title narrows it).
- `eligible: <ID> <spec>` may be started. `refused: <ID> — …`: not READY, no spec, policy-excluded on
  the target, the file absent, more than one `test(` in it, an attempt already open.

## 2. Start

`heal.mjs start <ID> --env <the record's env> --from-run <run-id>` (from a red run; `--from-run`
re-checks that the scenario failed there and that the target's name, kind and base URL are the
record's). It pins the attempt — environment, kind, base URL, the spec's bytes (copied to
`<heal dir>/before/`), its helpers' digests, the block's digest — and prints `heal: <dir>`.

It decides the stale rules before any traffic:

| Line | Meaning | Next |
|---|---|---|
| `class: catalog-outdated — …` | a cited criterion was withdrawn, is gone or changed since the catalog cited it — the `Expected` itself moved | a human updates the block; then `Spec: —`, remove the spec, `author <ID>` |
| `stop: refresh needed — … — /regression-tests author --refresh <ID>` | the spec's header lags a current catalog | § Refresh |
| `stop: inconclusive — …` | the current criterion cannot be read (no backlog, the fingerprint block failed) | report it |

Otherwise it prints `probe:`, `candidate:` and `heal:` — the probe file is empty, the candidate is a
byte copy of the claimed spec. A spec with a screenshot assertion is refused (the visual lane owns
those); so is a runner config without `testMatch` from `runnerOptions` (the candidate and the probe
would load in ordinary runs).

## 3. The probe

The live check is a second spec written **without** the claimed one. Spawn a sub-agent with this
brief, verbatim apart from the slots:

> Write a Playwright spec for scenario `<ID>` into `<probe path>`. Its title is `<ID> — probe`; it
> carries the header `// regression: <ID> · source: <the block's Source>` and the tags the block's
> priority needs. Sources, in this order: the scenario block below (**`Spec:` removed**), the code
> the routes and components live in (`<paths>`), the newest walk observations
> (`<observations.json>`). Follow `.claude/skills/regression/references/author.md` §2 and
> `.claude/skills/regression/references/spec-rules.md`. Perform every `Steps` item through the UI and
> assert every `Expected` clause. Never open, search for or ask for the scenario's existing spec or
> the candidate (`<spec dir>/*.heal.spec.ts`) — the probe must not inherit their mistakes.
>
> `<the block, verbatim, without its **Spec:** field>`

Then, in this order:

1. `node .claude/lib/regression/author.mjs lint <probe> --id <ID>` — fix every violation.
2. `heal.mjs probe-key <ID> --run <heal dir>` — the probe's digests, taken before the critic reads it.
3. `@regression-critic` with `MODE=probe`, `SCENARIO` (the block verbatim), `SPEC` (the probe),
   `ROUND`. Write its JSON plus the three `probe-key` digests to `<heal dir>/probe-critic-<ID>.json`.
4. `revise` → one revision of the probe (then steps 1–3 again); a second `revise` → `heal.mjs
   discard`, report `inconclusive — the probe did not qualify`. A clause the critic accepts only as
   unobservable means no `TEST`: the probe cannot establish it.

## 4. Run the probe

`node .claude/lib/regression/run.mjs probe <ID> --heal <heal dir> [--env <env>]` — two passes of
`runner.commands.full` on the pinned target: pass 1 the claimed spec, pass 2 the probe, each with its
own nonce and guard evidence. On production it prints one confirmation for both passes
(`confirmation-required:`) — ask exactly as the command's Run step 3 does. It refuses a probe whose
bytes changed since the critic, a changed spec, another environment, a lint violation in the spec or
its helpers. A guard stop or an interrupted pass 1 skips pass 2. It writes `probe.json` and prints
`record: <dir>/probe.json`.

## 5. Classify

`heal.mjs classify <ID> --run <heal dir> --probe <probe run dir>` — per runner project, `R` = the
claimed spec's result, `P` = the probe's:

| Class | When | Then |
|---|---|---|
| `APP` | no environment fact, both failed on a project, every case qualified | a bug candidate `<heal dir>/bug-<ID>.md`; no diff; suggest `/create-task` |
| `TEST` | no environment fact, the spec failed, the probe passed on every project, every case qualified, `Effect: read` | § Repair |
| `catalog-outdated` | decided at start | a human |
| `env` | a guard stop, a 5xx answer or navigation, a failed request, an unexplained runner pass, a production attestation gap, an unknown or moving build | blocked — rerun later; never a FAIL |

Stops: `not reproduced` (the spec passed everywhere; `the spec may assert too little on <p>` when
the probe failed there) and `inconclusive` (a crossed desktop/mobile pairing, a skipped case, an
aborted request, pass 2 not run, unqualified evidence, a `write` scenario — pass 1 may have changed
the state pass 2 saw). Every class but `TEST` closes the attempt and moves the candidate into
`<heal dir>/discarded/`. `classify` refuses when the spec, its block or its helpers changed since
start — the live check precedes any diff.

## 6. Repair (`TEST` only)

Edit the candidate only — never the claimed spec, never a helper (a helper change refuses at apply).
Then:

1. `node .claude/lib/regression/weaken-check.mjs <heal dir>/before/<file> <candidate> --json` —
   `weakened:` lines are refusals; fix the repair, never the check. The allow-list: a retargeted
   locator, a changed `timeout`, an added assertion, action or wait.
2. `run.mjs verify <ID>=<candidate> --heal <heal dir>` — three green passes, as the author lane's.
3. `@regression-critic` with `MODE=heal`, `SCENARIO`, `SPEC` (the candidate), `BEFORE`, `WEAKEN`
   (step 1's JSON), `HEAL_ID`, `BEFORE_SHA256`, `ROUND`; write its JSON plus the `verified:` line's
   digests to `<verify run dir>/critic-<ID>.json`. `revise` → fix, steps 1–3 again; the author lane's
   round limits hold (two critic rounds, four verify rounds).

## 7. Apply or discard

`heal.mjs apply <ID> --run <heal dir> --verify <verify run dir> --critic <file>` re-checks it all
under the checkout lock — the class, the block, the stale rules, weaken-check, the lint and title,
the helpers, the heal verify of this attempt on its pinned target, the critic on the same digests —
then renames the candidate over the claimed spec and prints `healed: <ID> — <spec>`. When the claimed
spec changed since start it refuses with `conflict:` and keeps both files: a human merges.

`heal.mjs discard <ID> --run <heal dir>` on every other exit — the candidate and the probe move into
`<heal dir>/discarded/`; the claimed spec is never touched.

## Refresh (`author --refresh <ID>`)

For a spec whose header lags a current catalog (`stop: refresh needed`): `heal.mjs select --refresh
<ID>…`, then `heal.mjs start <ID> --env <n> --refresh` (no probe). Rewrite only the candidate's
`// regression:` header to the block's current `Source`; `weaken-check --refresh` allows the header
and nothing else. Then the Repair steps 1–3 (step 1 with `--refresh`) and `heal.mjs apply … --refresh`, which installs the
candidate only when the scenario then computes `verified` and prints `refreshed: <ID> — <spec>`.

## After a human changes `Expected`

A changed requirement is never healed: set the block's `Spec:` to `—`, remove the spec file, and
`/regression-tests author <ID>` writes a new one.

## Report

One line per scenario: the class or stop with its first evidence line, `healed:` / `refreshed:`,
the bug candidates (offer `/create-task` for each), and the attempts left open. Nothing is
committed — say which files changed for the user's `/commit`.
