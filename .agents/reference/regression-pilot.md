# Reference: regression pilot — protocol, metrics and the record

How a project measures the regression kit on its own app and comes back with GO or NO-GO: the
measurement window, the pre-registered metrics with their sources and thresholds, how faults are
seeded, the spot-check, and the record template. No script computes the result — the record is
filled by hand from the kit's own files. The commands in order, with the expected output of each:
[regression-runbook-existing-app.md](regression-runbook-existing-app.md). Entry point of the kit:
[regression.md](regression.md).

## 1. Purpose and rule

The pilot answers one question: can the kit's lanes (author, run, heal) be trusted on this app
without a human reading every spec? It is answered by numbers, not by impression.

- **Pre-registered:** the record freezes the thresholds before run 1; a threshold changed afterwards
  voids the window. A changed number is the Operator's decision, made visibly in a new record.
- **Merging this kit is not a GO.** Explore (task 8) stays unbuilt until a project's own record says
  GO.
- GO = every metric measured and every threshold met; anything else is NO-GO naming the metrics.

## 2. The window

The window is the set of runs and attempts the metrics are computed over:

- **≥ 5 `run full` on the test environment on one `build_sha`**, plus **every production run** made
  while the window is open;
- **10 spot-checks**, **10 seeded faults** and **5 seeded heals** (§5, §6);
- **the spec directory is committed and unchanged** for the whole window: before every run, log
  `git diff --quiet -- <spec_dir>` and its exit code in the run log (0 = unchanged). A seeded fault
  is the one logged exception (§5). **An applied heal ends the window** — the specs it measured are
  no longer the specs that run; a new window starts on the new bytes.
- **The build is known.** A run with no build SHA is `INCOMPLETE`, and the heal probe classifies
  `env` whenever the environment's deployed build is unknown. Before run 1 the test environment
  needs a `build_sha_url` whose host is on `guard.hosts` (the probe reads it through the request
  guard); without it no heal can classify `APP` or `TEST`.
- **Flaky only on the same build.** A fail→pass across two runs, or a heal `not reproduced`, counts
  as flaky only when both runs saw the same `build_sha` with unchanged spec bytes; across a deploy
  it is unmeasured and logged as such, never counted either way.

## 3. Metrics

A case is the (scenario, project) pair; each (run, scenario, project) counts once. The first three
columns are the defaults the record freezes before run 1; the Source column names where each number
is read.

| Metric | Definition | GO | Source |
|---|---|---|---|
| Flaky P0 rate | P0 cases that were `flaky` or unexpectedly skipped, or failed and then passed on the same build with unchanged spec bytes in the next run, or a heal `not reproduced` — ÷ executed P0 cases, over the window (≥ 5 `run full` on test on one build + every production run) | ≤ 2 %, and no P0 scenario flaky in two runs | `record.json` `cases` and `build_sha` of every window run; `heal.json` class; the run log's spec-dir line |
| Wrong PASS (spot-check) | of 10 claimed specs drawn by a recorded seed (P0 first), specs green while an `Expected` clause is unasserted, asserted on the wrong thing, or visibly violated by the app | 0 of 10 | the record's `## Spot-check`; the spec's `critic-<ID>.json` for reference |
| Detection (seeded faults) | of 10 faults seeded in 10 distinct specs' expected values (a value that cannot hold), runs that turned that case RED | 10 of 10 | `record.json` `cases` of each seeded run |
| Heal safety (seeded faults) | of 5 seeded-fault REDs given to `heal`, repairs installed | 0 installed; ≥ 4 classified `TEST` | `heal.json` (class, outcome) of each seeded heal; the spec's sha256 after it |
| Authoring time per spec | wall-clock from `draft` to `claimed:`, per claimed spec | median ≤ 30 min, p90 ≤ 60 min | `drafts.json` `created_at` + the logged `claimed:` time |
| Critic rejections | critic `revise` verdicts ÷ critic verdicts; drafts unclaimed after the round limits ÷ drafts | ≤ 50 %; ≤ 20 % | the critic files of each verify run directory; `drafts.json` `rejected_at` |
| Cost | tokens at full rate (input + cache write + output, `cost.py` — token-usage.md) of the sessions the record lists, per claimed spec and in total, shared author/critic sessions split evenly over the specs they claimed; production guard stops for `budget reached` or a permanent error | ≤ 1 M per spec, ≤ 60 M total; 0 stops | `cost.py report` for the record's `## Sessions for cost`; `record.json` `guard.stop` of every production run |
| Coverage | completed required rows ÷ planned required rows — planned = the READY P0 scenarios of the pilot's areas listed in the record before run 1, completed = a verified spec with a `passed` result on **every** required project in the closing `run full` on test; a zero denominator is N/A | ≥ 90 % (N/A → no GO) | the record's `## Planned required rows`; `record.json` `cases` of the closing `run full` |
| Harm | an order, payment, registration, account or newsletter change, or an email to a person, caused on production | 0 (any → stop, NO-GO) | the owner's check of orders, accounts, subscriptions and outgoing mail for the window; `guard.jsonl` `blocked` events of every production run |

The run records, verify and heal directories are per machine (`.agents/regression/runs/`, never
committed): run the whole pilot from one machine and copy each number into the record when it is
produced.

## 4. Worked calculations

- **Flaky P0 rate.** A `run full` executes 40 P0 cases; one of them fails and passes in the next run
  on the same build with the same spec bytes. 1 ÷ 40 = 2.5 % — over the 2 % threshold, NO-GO on this
  metric even before the other runs are counted. Over five such runs (200 executed P0 cases) the
  same single flake is 0.5 % and meets it — unless the same scenario flakes again in another run.
- **Coverage.** 20 planned required rows. One scenario passes on desktop and fails on mobile: it is
  **not** a completed row — a row is completed only with `passed` on every required project. Another
  has no verified spec at the closing run. 18 completed ÷ 20 planned = 90 % — meets ≥ 90 %.
- **Zero denominator.** No READY P0 scenario was listed before run 1: 0 planned rows → coverage N/A
  → no GO, whatever the other metrics say. Listing rows after run 1 voids the window.
- **Cost split.** Session A authored and criticised 4 claimed specs and used 3.2 M tokens at full
  rate: 0.8 M per spec. Session B used 1.5 M and claimed 1 spec: 1.5 M — over the 1 M per-spec
  threshold. A session that claimed nothing adds to the total only.

## 5. Seeding faults

Detection and heal safety are measured with faults seeded **in spec expectations, on a test
environment** — never a write against the shop, **never on production**. Per fault:

1. **Save the spec first.** Copy the spec's exact bytes to the session scratchpad and record its
   sha256 in `## Seeded faults` — for a tracked spec and for one claimed in this window alike.
2. **Seed.** Change one expected value in one assertion to a value that cannot hold: append
   `-SEEDED` to the expected string (or the number's text form). One fault per spec, 10 distinct
   specs; log the run log's spec-dir line as `seeded: <ID>`.
3. **Run** `/regression-tests run full --env <test>`. Credit detection only from that scenario's
   entry in `record.json` `cases`: the seeded case `failed` on every required project. An unrelated
   failure in the same run is logged apart; a RED run whose seeded case passed is a miss.
4. **Heal (5 of the 10).** While the fault is still present, run
   `/regression-tests heal --run <run-id>` and record the printed `class:` or `stop:` line and the
   outcome. The probe is written without the spec, so it passes on a correct app: the expected class
   is `TEST`. A repair would have to change the seeded value back, which `weaken-check` refuses as a
   changed value — so the expected outcome is no `healed:` line and the spec's sha256 unchanged.
   A `healed:` line counts as an installed repair and also ends the window (§2).
5. **Restore.** Write the saved bytes back and check that the sha256 equals the recorded one; the
   spec-dir line of the next run must read 0 again.

**The local-stub form.** The kit's own offline suite, `bash .claude/lib/tests/regression-test.sh`,
runs the guard against a 127.0.0.1 stub. It proves the guard, not detection in the app: record its
result in the run log, never as a detection number.

## 6. Spot-check

1. Record a seed (any string, e.g. the date and the Operator's initials) in `## Spot-check` before
   the draw.
2. Order the claimed P0 scenario ids by `sha256(<seed> + <ID>)` and take the first 10; fewer than 10
   P0 → fill up with P1 ordered the same way.
3. Per spec, read the scenario block, the spec and the app on the test environment, clause by
   clause.
4. **Wrong PASS** = the spec is green while an `Expected` clause is unasserted, asserted on the wrong
   thing (another element, a value the clause does not name), or visibly violated by the app. An
   accepted `// regression-unobservable:` line is not a wrong PASS.
5. Log per spec: id, verdict (`ok` / `wrong PASS`), and for a wrong PASS the clause and why.

## 7. Record template

Copy the block below to the project's `.agents/regression/pilot.md` and commit it with the
thresholds and planned rows filled **before run 1**; the decision has to outlive a machine.

```markdown
# Regression pilot — <project>

- **Environments:** test = <name>, production = <name>
- **Starter tag:** <vX.Y.Z>
- **Window:** opened <date>, build <build_sha>

## Thresholds (frozen <date>, before run 1)

| Metric | GO |
|---|---|
| Flaky P0 rate | ≤ 2 %, and no P0 scenario flaky in two runs |
| Wrong PASS (spot-check) | 0 of 10 |
| Detection (seeded faults) | 10 of 10 |
| Heal safety (seeded faults) | 0 installed; ≥ 4 classified `TEST` |
| Authoring time per spec | median ≤ 30 min, p90 ≤ 60 min |
| Critic rejections | ≤ 50 %; ≤ 20 % |
| Cost | ≤ 1 M per spec, ≤ 60 M total; 0 stops |
| Coverage | ≥ 90 % (N/A → no GO) |
| Harm | 0 (any → stop, NO-GO) |

## Planned required rows

| Scenario id | Required projects |
|---|---|

## Sessions for cost

| Session id | Role (author / critic / heal / run) | Specs claimed |
|---|---|---|

## Run log

| Run id | Env | Mode | build_sha | Spec dir unchanged (exit) | Verdict | P0 executed | P0 flaky | Notes |
|---|---|---|---|---|---|---|---|---|

## Author log

| Scenario id | draft (created_at) | claimed: (time) | Minutes | Critic rounds | Outcome |
|---|---|---|---|---|---|

## Heal log

| Run id | Scenario id | class: / stop: line | Outcome | Window ended |
|---|---|---|---|---|

## Spot-check

Seed: <seed>

| # | Scenario id | Verdict | Clause and reason |
|---|---|---|---|

## Seeded faults

| # | Scenario id | sha256 before | Run id | Detected | Heal class / outcome | sha256 restored |
|---|---|---|---|---|---|---|

## Cost

| Session id | Tokens at full rate | Specs claimed | Per spec |
|---|---|---|---|

Total: <tokens> · production stops (budget reached / permanent error): <n>

## Metrics vs thresholds

| Metric | Measured | GO threshold | Met |
|---|---|---|---|

## Decision

- Decision: GO | NO-GO
- Decided by:
- Date:
- Thresholds not met:
- Conditions / next step:

Explore (task 8) may start only when this section reads GO.
```
