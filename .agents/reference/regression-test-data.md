# Reference: regression test-data adapter contract

The four commands a project's test-data adapter implements, named in `.claude/regression.json` →
`runner.test_data.{check,provision,reset,session}`. The starter never provisions anything itself:
this is the contract the project's own code (in its e2e directory) fulfils. Each command is a
repo-root-relative program, run from the repo root (`<path> …`, an executable file, or `<interpreter> <script> …` —
the forms `setup.mjs check` recognises). Entry point of the kit: [regression.md](regression.md).

## 1. Commands

`<env>` is an environment name from `regression.json` → `environments`. The caller passes its kind in
the environment variable `REGRESSION_ENV_KIND` (`test` only for an environment declared
`kind: "test"`; anything else, or nothing, means production).

| Command | Does | stdout | Exit codes |
|---|---|---|---|
| `check <env>` | Read-only: are the accounts, data and session prerequisites of `<env>` in place? Changes nothing. | What is missing, by key name only. | 0 ready · 1 not ready · 2 usage / config |
| `provision <env>` | Creates the test data the scenarios name. Runs **only** when `REGRESSION_ENV_KIND=test`. | What was created, by key name. | 0 done · 1 failed · 2 usage / config · **3 refused** |
| `reset <env> [--run <id>]` | Resets only the data this run owns (`--run` names it). Runs **only** when `REGRESSION_ENV_KIND=test`. | What was reset, by key name. | 0 done · 1 failed · 2 usage / config · **3 refused** |
| `session <env> <account-key>` | Signs the account in (once per account per run) and writes a storage-state file. | The **path** of the storage-state file, in a gitignored directory — one line, nothing else. | 0 ok · 1 failed · 2 usage / config |

**Production refusal.** `provision` and `reset` check `REGRESSION_ENV_KIND` first: absent or any
value but `test` = production → exit 3 and do nothing at all. The caller sets `test` only for an
environment `regression.json` declares `kind: "test"`; an environment without `kind` is production.
The starter never provisions anything on a production environment.

## 2. Secrets

- A secret value is **never printed** — not to stdout, not to stderr, not to a log or a report. Only
  key names and file paths appear.
- Values come from the project's local `.env` (never committed); the adapter reads them, the caller
  never sees them.
- `Data` in a scenario names a key (`account key shopper`), never a value.
- Storage-state files hold session cookies: they live in a gitignored directory and are referenced by
  path only.
- **Redaction:** the run record and traces redact the patterns the project configures (identifiers in
  URLs, tokens); the adapter applies the same patterns to anything it prints.

## 3. Account pool and session seeding

- **Account pool:** one key per role (`shopper`, `admin`, …); an account is used by one run at a time,
  so two concurrent runs never share a signed-in account.
- **Session seeding:** `session` signs an account in once per run and reuses its storage state for
  every scenario of that run; the fixture template turns the printed path into the browser context's
  `storageState`, so a spec starts signed in.
- An anonymous scenario (`account: null`) calls no `session` at all.
