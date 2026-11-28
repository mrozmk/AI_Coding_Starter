# QA working file — issue 12

- SUBJECT: #12 · BASE_URL: https://test.shop.example.com (qa-env) · DEPLOYED_SHA: abc1234 · mode: first · 2026-11-27

| AC | fp | family | agent | methods | evidence | artifacts | disposition |
|---|---|---|---|---|---|---|---|
| E2-3.AC2 | a1b2c3 | runtime-ui | qa-runtime-ui (driver: script) | playwright script | the cart heading is visible | qa-artifacts/ac2-flow.mjs, qa-artifacts/ac2.png | PASS |
| E2-3.AC3 | d4e5f6 | runtime-ui | qa-runtime-ui (driver: script) | playwright script | the total stays 0 | qa-artifacts/ac3-flow.mjs | FAIL |
| E2-3.AC4 | 0a0b0c | runtime-ui | qa-runtime-ui (driver: script) | playwright script | carried | qa-artifacts/ac4-flow.mjs | PASS (carried) |
| E2-3.AC5 | 111111 | visual | qa-visual | screenshot | the lines are listed | qa-artifacts/ac5.png | PASS |
| E2-3.AC6 | 222222 | runtime-ui | qa-runtime-ui | steps in the row | the filter narrows the list | — | PASS |

**Blockers: 0.**

## QA verification — Cart totals

- Run: 2026-11-27 · first · group: single
- Environment: https://test.shop.example.com (qa-env) · build: abc1234
- Criteria from: ticket description (5 criteria)

### Criteria
- E2-3.AC2 [a1b2c3] — PASS — runtime-ui — the cart heading is visible
- E2-3.AC3 [d4e5f6] — FAIL / major — runtime-ui — the total stays 0; contradicts "the total follows"
- E2-3.AC4 [0a0b0c] — PASS (carried from 2026-11-20) — runtime-ui — the badge shows the line count
- E2-3.AC5 [111111] — PASS — visual — the lines are listed
- E2-3.AC6 [222222] — PASS — runtime-ui — the filter narrows the list

### Feature path
- none

### Outside the criteria
- none

**Blockers: 1.** Not acceptable
qa-verify:v1 record run=20261127T100000Z ticket=12 mode=first group=- build=abc1234 pass=3 fail=1 cited=0 deferred=0 env=0 needs-human=0
