import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import {
  parseTables, parseBacklog, loadInventory, loadSystem, checkBacklog, checkSystem,
  scheduleLanes, renderLanes, renderStoryMap, replaceRegion, locateRegions, main,
} from './backlog-check.mjs';

const SCRIPT = fileURLToPath(import.meta.url).replace(/\.test\.mjs$/, '.mjs');

// ---------------------------------------------------------------------------------------------
// Fixtures — a 3-epic, 7-task greenfield project; every negative case mutates one of these.
// ---------------------------------------------------------------------------------------------

const PRD = `# PRD — Shop

## 3. Goals
- **G-1** — first order placed within 2 minutes by 2026-12-01
- **G-2** — (withdrawn) legacy goal

## 5. Requirements
- **R-1** — WHEN a user signs in, the system shall issue a session. Traces: G-1
- **R-2** — WHEN an order is placed, the system shall confirm it. Traces: G-1
- **R-3** — (withdrawn) old export requirement

## 6. Non-functional
| NFR | Characteristic | What | Target | Method |
|---|---|---|---|---|
| NFR-1 | Performance | sign-in | p95 < 300 ms | k6 |
`;

const DISCOVERY = `# Discovery — Shop

## Flows

### FL-1 — Place order

**Critical:** yes

- **FL-1.A1** — Sign in
- **FL-1.A2** — Place order
- **FL-1.A3** — Receive confirmation

### FL-2 — Reporting

**Critical:** no

- **FL-2.A1** — View report

## Business rules

- **BR-1** — an order needs at least one line
`;

const ARCHITECTURE = `# Architecture — Shop

## Decisions

| AD | Context | Dimension | Decision | Binds | Prevents | Rule | Status | Evidence |
|---|---|---|---|---|---|---|---|---|
| AD-1 | all | deployment unit | modular monolith | … | … | … | active | \`NFR-1\` |
| AD-2 | identity | auth | sessions | … | … | … | active | \`R-1\` |
| AD-3 | orders | storage | document store | … | … | … | superseded by AD-5 | \`BR-1\` |
| AD-4 | orders | queue | self-hosted broker | … | … | … | withdrawn | — |
| AD-5 | orders | storage | relational | … | … | … | active | \`BR-1\` |
`;

const SYSTEM = `schema: 1
nodes:
  - id: platform-core
    name: Platform Core
    kind: trunk
  - id: identity
    name: Identity
    kind: branch
    parent: platform-core
    subdomain: generic
  - id: authn
    name: Authentication
    kind: leaf
    parent: identity
  - id: business-core
    name: Business Core
    kind: branch
    parent: platform-core
    subdomain: core
  - id: orders
    name: Orders
    kind: leaf
    parent: business-core
    criticality: critical
  - id: integration
    name: Integration
    kind: branch
    parent: platform-core
    subdomain: supporting
  - id: notification
    name: Notification
    kind: twig
    parent: integration
  - id: email
    name: Email
    kind: leaf
    parent: notification
  - id: data-analytics
    name: Data & Analytics
    kind: branch
    parent: platform-core
    subdomain: supporting
  - id: reporting
    name: Reporting
    kind: leaf
    parent: data-analytics
  - id: cloud
    name: Cloud
    kind: root
links:
  - from: orders
    to: notification
    kind: events
  - from: identity
    to: business-core
    kind: ohs
flows:
  - id: place-order
    name: Place order
    critical: true
    fl: FL-1
    steps: [authn, orders, email]
`;

const TASK_HEADER = `| ID | Epic | Task | Type | Size | Pts | Depends on | Wave | Slice | Node | Traces | Status | Jira | Ref |
|----|------|------|------|------|-----|------------|------|-------|------|--------|--------|------|-----|`;

const TASK_ROWS = [
  '| E0-1 | E0 | Project scaffold | tech | H | 8 | — | 0 | WS | platform-core | AD-1 | TODO | — | — |',
  '| E0-2 | E0 | Auth skeleton | tech | M | 4 | E0-1 | 0 | WS | authn | AD-2, NFR-1 | TODO | — | — |',
  '| E1-1 | E1 | Sign in | story | M | 4 | E0-2 | 1 | WS | authn | R-1, FL-1.A1 | TODO | — | — |',
  '| E1-2 | E1 | Place order | story | H | 8 | E0-1 | 1 | WS | orders | R-2, FL-1.A2, AD-5 | TODO | — | — |',
  '| E1-3 | E1 | Confirmation email | story | M | 4 | E1-2 | 2 | WS | email | FL-1.A3, G-1 | TODO | — | — |',
  '| E2-1 | E2 | Report view | story | H | 8 | E1-2 | 2 | R2 | reporting | FL-2.A1, BR-1 | TODO | — | — |',
  '| E2-2 | E2 | Report export | story | M | 4 | E0-1 | 2 | R2 | — | FL-2.A1 | TODO | — | — |',
];

const ACS = `### E0-1 — Project scaffold
- **E0-1.AC1** — Given a clean clone, when \`npm test\` runs, then it passes.

### E0-2 — Auth skeleton
- **E0-2.AC1** — Given no session, when a protected route is hit, then 401.

### E1-1 — Sign in
- **E1-1.AC1** — Given valid credentials, when the user signs in, then a session is issued.
- **E1-1.AC2** — Given wrong credentials, when the user signs in, then no session and a generic error.

### E1-2 — Place order
- **E1-2.AC1** — Given a cart with one line, when the user places the order, then it is confirmed.
- **E1-2.AC2** — Given an empty cart, when the user places the order, then it is rejected (BR-1).

### E1-3 — Confirmation email
- **E1-3.AC1** — Given a confirmed order, when the event is published, then an email is sent.

### E2-1 — Report view
- **E2-1.AC1** — Given orders exist, when the report opens, then totals match.

### E2-2 — Report export
- **E2-2.AC1** — Given a report, when export is clicked, then a CSV downloads.`;

function backlogMd({ rows = TASK_ROWS, epics, acs = ACS, header, markers = true } = {}) {
  const epicRows = epics ?? [
    '| E0 | Foundation | skeleton everything stands on | monolith is enough | 12 | — | — |',
    '| E1 | Ordering | first order placed (G-1) | users accept email confirmation | 16 | E0 | — |',
    '| E2 | Reporting | owners see totals | daily granularity suffices | 12 | E1 | — |',
  ];
  return `# Shop — Backlog (Epics + Tasks)
${header ?? '**Date:** 2026-10-10 · **Source PRD:** `docs/PRD.md` · **Architecture:** `docs/architecture.md` · **Jira namespace:** `shop` · **Sizes:** M=4 · H=8 · XH=16 points (currency, not hours)'}

## Epic map
| Epic | Title | Outcome | Key assumption | Pts | Depends on | Jira |
|------|-------|---------|----------------|-----|------------|------|
${epicRows.join('\n')}

**E0** — appetite: small · cut first: nothing
**E1** — appetite: medium · cut first: E1-3

## Task table
${TASK_HEADER}
${rows.join('\n')}

## Acceptance criteria
${acs}

## Story map
${markers ? '<!-- storymap:begin -->\n(generated by backlog-check --write)\n<!-- storymap:end -->' : '(no markers)'}

## Parallel plan
${markers ? '<!-- lanes:begin -->\n(generated by backlog-check --write)\n<!-- lanes:end -->' : '(no markers)'}

## External blockers
- none

## Open questions
- none

## Consciously out of scope
- payments
`;
}

const LEGACY_BACKLOG = `# Old — Backlog
## Epic map
| Epic | Title | Depends on |
|---|---|---|
| E0 | Foundation | — |
## Work packages — pipeline inputs
| Package | Task scope | Depends on | Entry | Status |
|---|---|---|---|---|
| MVP | E0-1 | — | /brainstorm | TODO |
## Task table
| ID | Epic | Task | Description | Dependencies | Difficulty | Type | Wave | Status | Ref |
|---|---|---|---|---|---|---|---|---|---|
| E0-1 | Foundation | scaffold | … | — | S | — | 1 | TODO | — |
`;

function project({ prd = PRD, prdName = 'docs/PRD.md', discovery = DISCOVERY, architecture = ARCHITECTURE, system = SYSTEM, backlog = backlogMd() } = {}) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'backlog-check-'));
  fs.mkdirSync(path.join(dir, '.agents'));
  fs.mkdirSync(path.join(dir, 'docs', 'map'), { recursive: true });
  if (prd !== null) fs.writeFileSync(path.join(dir, prdName), prd);
  if (discovery !== null) fs.writeFileSync(path.join(dir, 'docs', 'discovery.md'), discovery);
  if (architecture !== null) fs.writeFileSync(path.join(dir, 'docs', 'architecture.md'), architecture);
  if (system !== null) fs.writeFileSync(path.join(dir, 'docs', 'map', 'system.yaml'), system);
  if (backlog !== null) fs.writeFileSync(path.join(dir, '.agents', 'backlog.md'), backlog);
  return dir;
}

function run(dir, ...flags) {
  const r = spawnSync(process.execPath, [SCRIPT, '--root', dir, ...flags], { encoding: 'utf8' });
  return { code: r.status, out: r.stdout + r.stderr };
}

function check(dir, backlog = fs.readFileSync(path.join(dir, '.agents', 'backlog.md'), 'utf8')) {
  const parsed = parseBacklog(backlog);
  return checkBacklog({ backlog: parsed, inventory: loadInventory(dir, parsed.sourcePrd ?? 'docs/PRD.md'), system: loadSystem(dir) });
}

const withRow = (id, replacement) => TASK_ROWS.map((r) => (r.startsWith(`| ${id} |`) ? replacement : r));
const hasError = (res, re) => res.errors.some((e) => re.test(e));

// ---------------------------------------------------------------------------------------------
// Parsing
// ---------------------------------------------------------------------------------------------

test('parseTables keys rows by header text and ignores prose', () => {
  const tables = parseTables('intro\n| A | **B** |\n|---|---|\n| 1 | x \\| y |\n\ntext\n| Only | header |\n');
  assert.equal(tables.length, 1);
  assert.deepEqual(tables[0].header, ['A', 'B']);
  assert.equal(tables[0].rows[0].A, '1');
  assert.equal(tables[0].rows[0].B, 'x \\| y');
});

test('parseBacklog reads epics, tasks, ACs and the Source PRD header', () => {
  const b = parseBacklog(backlogMd());
  assert.equal(b.legacy, false);
  assert.deepEqual(b.epics.map((e) => e.id), ['E0', 'E1', 'E2']);
  assert.equal(b.tasks.length, 7);
  assert.deepEqual(b.tasks[3].traces, ['R-2', 'FL-1.A2', 'AD-5']);
  assert.equal(b.tasks[6].node, null);
  assert.equal(b.acs.length, 9);
  assert.equal(b.acs[2].block, 'E1-1');
  assert.equal(b.sourcePrd, 'docs/PRD.md');
});

test('loadInventory: D5 syntax, withdrawn and superseded states, flows with activities', () => {
  const dir = project();
  const inv = loadInventory(dir);
  assert.equal(inv.ids.get('G-1').state, 'active');
  assert.equal(inv.ids.get('G-2').state, 'withdrawn');
  assert.equal(inv.ids.get('R-3').state, 'withdrawn');
  assert.equal(inv.ids.get('NFR-1').source, 'prd');
  assert.equal(inv.ids.get('BR-1').source, 'discovery');
  assert.deepEqual(inv.ids.get('AD-3'), { source: 'architecture', state: 'superseded', successor: 'AD-5' });
  assert.equal(inv.ids.get('AD-4').state, 'withdrawn');
  assert.equal(inv.ids.get('FL-1.A2').state, 'active');
  assert.deepEqual(inv.flows.map((f) => [f.id, f.critical, f.activities.length]), [['FL-1', true, 3], ['FL-2', false, 1]]);
  assert.equal(inv.flows[0].activities[1].name, 'Place order');
});

test('loadSystem: null when absent, parsed when present, throws on a parse error', () => {
  assert.equal(loadSystem(project({ system: null })), null);
  assert.equal(loadSystem(project()).nodes.length, 11);
  assert.throws(() => loadSystem(project({ system: 'nodes:\n  - id: a\n      name: bad\n' })), /system\.yaml: yaml: unexpected indent/);
});

// ---------------------------------------------------------------------------------------------
// (1) clean fixture · (2) error classes
// ---------------------------------------------------------------------------------------------

test('(1) clean fixture → no errors', () => {
  const res = check(project());
  assert.deepEqual(res.errors, []);
});

const ERROR_CASES = [
  ['duplicate Epic id', { epics: ['| E0 | Foundation | a | b | 12 | — | — |', '| E0 | Again | a | b | 0 | — | — |', '| E1 | Ordering | a | b | 16 | E0 | — |', '| E2 | Reporting | a | b | 12 | E1 | — |'] }, /duplicate Epic id E0/],
  ['duplicate Task id', { rows: [...TASK_ROWS, '| E2-2 | E2 | Dup | story | M | 4 | — | 2 | R2 | — | FL-2.A1 | TODO | — | — |'] }, /duplicate Task id E2-2/],
  ['Task epic not in Epic map', { rows: withRow('E2-2', '| E2-2 | E9 | Report export | story | M | 4 | E0-1 | 2 | R2 | — | FL-2.A1 | TODO | — | — |') }, /Task E2-2: Epic E9 not in Epic map/],
  ['unknown dependency', { rows: withRow('E2-2', '| E2-2 | E2 | Report export | story | M | 4 | E7-7 | 2 | R2 | — | FL-2.A1 | TODO | — | — |') }, /Task E2-2: unknown dependency E7-7/],
  ['Size outside M/H/XH', { rows: withRow('E2-2', '| E2-2 | E2 | Report export | story | S | 4 | E0-1 | 2 | R2 | — | FL-2.A1 | TODO | — | — |') }, /Task E2-2: Size S not in M\/H\/XH/],
  ['Pts ≠ size points', { rows: withRow('E2-2', '| E2-2 | E2 | Report export | story | M | 5 | E0-1 | 2 | R2 | — | FL-2.A1 | TODO | — | — |') }, /Task E2-2: Pts 5 ≠ 4 for Size M/],
  ['Epic Pts ≠ sum of Tasks', { epics: ['| E0 | Foundation | a | b | 12 | — | — |', '| E1 | Ordering | a | b | 16 | E0 | — |', '| E2 | Reporting | a | b | 8 | E1 | — |'] }, /Epic E2: Pts 8 ≠ 12/],
  ['Task without AC', { acs: ACS.replace(/### E2-2 — Report export\n- \*\*E2-2\.AC1\*\*[^\n]*/, '') }, /Task E2-2: no acceptance criterion/],
  ['AC under the wrong Task heading', { acs: ACS.replace('- **E2-2.AC1**', '- **E2-1.AC2**') }, /AC E2-1\.AC2 defined under the E2-2 heading/],
  ['duplicate AC definition id', { acs: ACS.replace('- **E1-2.AC2**', '- **E1-2.AC1**') }, /duplicate AC definition E1-2\.AC1/],
  ['malformed AC id', { acs: ACS.replace('- **E2-2.AC1**', '- **E2-2.ACa**') }, /malformed AC id E2-2\.ACa/],
  ['unknown Node', { rows: withRow('E2-2', '| E2-2 | E2 | Report export | story | M | 4 | E0-1 | 2 | R2 | exports | FL-2.A1 | TODO | — | — |') }, /Task E2-2: unknown Node exports/],
  ['unknown trace id', { rows: withRow('E2-2', '| E2-2 | E2 | Report export | story | M | 4 | E0-1 | 2 | R2 | — | FL-2.A1, R-99 | TODO | — | — |') }, /Task E2-2: unknown trace R-99/],
  ['active R- with no Task tracing it', { rows: withRow('E1-1', '| E1-1 | E1 | Sign in | story | M | 4 | E0-2 | 1 | WS | authn | FL-1.A1 | TODO | — | — |') }, /^R-1: no Task traces it/],
  ['critical backbone activity without a WS Task', { rows: withRow('E1-3', '| E1-3 | E1 | Confirmation email | story | M | 4 | E1-2 | 2 | R2 | email | FL-1.A3, G-1 | TODO | — | — |') }, /FL-1\.A3 \(critical flow FL-1\): no Slice WS Task/],
  ['Wave-0 Task depending on a later Task', { rows: withRow('E0-2', '| E0-2 | E0 | Auth skeleton | tech | M | 4 | E1-1 | 0 | WS | authn | AD-2, NFR-1 | TODO | — | — |') }, /Task E0-2: Wave-0 Task depends on E1-1 \(Wave 1\)/],
  ['Type outside story/tech', { rows: withRow('E2-2', '| E2-2 | E2 | Report export | bug | M | 4 | E0-1 | 2 | R2 | — | FL-2.A1 | TODO | — | — |') }, /Task E2-2: Type bug not in story\/tech/],
  ['Slice outside WS/R<n>', { rows: withRow('E2-2', '| E2-2 | E2 | Report export | story | M | 4 | E0-1 | 2 | MVP | — | FL-2.A1 | TODO | — | — |') }, /Task E2-2: Slice MVP must be WS or R<n>/],
];

for (const [name, mutation, re] of ERROR_CASES) {
  test(`(2) error: ${name}`, () => {
    const res = check(project({ backlog: backlogMd(mutation) }));
    assert.ok(hasError(res, re), `expected ${re} in:\n${res.errors.join('\n')}`);
  });
}

test('(3) traces to a withdrawn id and to a superseded AD name the state / successor', () => {
  const rows = withRow('E2-2', '| E2-2 | E2 | Report export | story | M | 4 | E0-1 | 2 | R2 | — | FL-2.A1, R-3, AD-3 | TODO | — | — |');
  const res = check(project({ backlog: backlogMd({ rows }) }));
  assert.ok(hasError(res, /Task E2-2: traces withdrawn R-3/), res.errors.join('\n'));
  assert.ok(hasError(res, /Task E2-2: traces AD-3, superseded by AD-5 — trace AD-5 instead/), res.errors.join('\n'));
});

test('(4) dependency cycle E1-1 → E1-2 → E1-1 is named', () => {
  const rows = withRow('E1-1', '| E1-1 | E1 | Sign in | story | M | 4 | E0-2, E1-2 | 1 | WS | authn | R-1, FL-1.A1 | TODO | — | — |')
    .map((r) => (r.startsWith('| E1-2 |') ? '| E1-2 | E1 | Place order | story | H | 8 | E1-1 | 1 | WS | orders | R-2, FL-1.A2, AD-5 | TODO | — | — |' : r));
  const res = check(project({ backlog: backlogMd({ rows }) }));
  assert.ok(hasError(res, /dependency cycle: E1-[12] → E1-[12] → E1-[12]/), res.errors.join('\n'));
});

test('(4a) a renamed `Depends on` header is a missing-column error, not an empty dependency list — the cycle cannot slip through', () => {
  const rows = withRow('E1-1', '| E1-1 | E1 | Sign in | story | M | 4 | E0-2, E1-2 | 1 | WS | authn | R-1, FL-1.A1 | TODO | — | — |')
    .map((r) => (r.startsWith('| E1-2 |') ? '| E1-2 | E1 | Place order | story | H | 8 | E1-1 | 1 | WS | orders | R-2, FL-1.A2, AD-5 | TODO | — | — |' : r));
  const renamed = backlogMd({ rows }).replace('| ID | Epic | Task | Type | Size | Pts | Depends on |', '| ID | Epic | Task | Type | Size | Pts | Deps |');
  const dir = project({ backlog: renamed });
  const r = run(dir, '--write');
  assert.equal(r.code, 1, r.out);
  assert.match(r.out, /Task table \(line \d+\): missing column\(s\) `Depends on`/);
  assert.match(r.out, /backlog-check: 1 error\(s\), 0 warning\(s\)/, 'the missing column stands alone — no cascade from the dropped table');
  assert.doesNotMatch(r.out, /note: wrote/);
  assert.equal(fs.readFileSync(path.join(dir, '.agents', 'backlog.md'), 'utf8'), renamed);
  const epicRenamed = backlogMd().replace('| Epic | Title | Outcome | Key assumption | Pts | Depends on | Jira |', '| Epic | Title | Outcome | Key assumption | Pts | Needs | Jira |');
  const epicRes = check(project({ backlog: epicRenamed }));
  assert.equal(epicRes.errors.length, 1, epicRes.errors.join('\n'));
  assert.match(epicRes.errors[0], /Epic map table \(line \d+\): missing column\(s\) `Depends on`/);
  assert.deepEqual(epicRes.warnings, []);
});

test('a withdrawn Task keeps its ids but covers nothing and is not scheduled', () => {
  const rows = withRow('E1-3', '| E1-3 | E1 | Confirmation email (withdrawn) | story | M | 4 | E1-2 | 2 | WS | email | FL-1.A3, G-1, R-3 | DONE | — | — |');
  const res = check(project({ backlog: backlogMd({ rows }) }));
  assert.ok(hasError(res, /FL-1\.A3 \(critical flow FL-1\): no Slice WS Task/), res.errors.join('\n'));
  assert.ok(!hasError(res, /traces withdrawn R-3/), res.errors.join('\n'));
  assert.ok(hasError(res, /Task E1-3: unknown trace/) === false);
  const { tasks } = parseBacklog(backlogMd({ rows }));
  const sched = scheduleLanes(tasks, 2);
  assert.ok(!sched.lanes.some((l) => l.ids.includes('E1-3')));
  assert.equal(renderStoryMap(tasks, loadInventory(project()).flows).split('\n')[4], '| WS | E1-1 | E1-2 | — |');
  assert.match(renderLanes(tasks.filter((t) => t.wave === '0' || t.id === 'E1-3')), /No parallel work yet — foundation only\./);
});

test('an NFR row whose Requirement starts with N/A keeps its id but is not mandatory coverage', () => {
  const prd = PRD.replace(
    /## 6\. Non-functional[\s\S]*$/,
    '## 6. Non-functional requirements\n| ID | ISO 25010 characteristic | Requirement | Target | Measured by |\n|---|---|---|---|---|\n| NFR-1 | Performance efficiency | N/A — single-user CLI, no latency budget | — | — |\n| NFR-2 | Security | secrets never logged | 0 findings | gitleaks |\n',
  );
  const rows = withRow('E0-2', '| E0-2 | E0 | Auth skeleton | tech | M | 4 | E0-1 | 0 | WS | authn | AD-2, NFR-2 | TODO | — | — |');
  const dir = project({ prd, backlog: backlogMd({ rows }) });
  assert.equal(loadInventory(dir).ids.get('NFR-1').state, 'n/a');
  const res = check(dir);
  assert.deepEqual(res.errors, []);
  const untraced = check(project({ prd, backlog: backlogMd({ rows: withRow('E0-2', '| E0-2 | E0 | Auth skeleton | tech | M | 4 | E0-1 | 0 | WS | authn | AD-2 | TODO | — | — |') }) }));
  assert.ok(hasError(untraced, /^NFR-2: no Task traces it/), untraced.errors.join('\n'));
  assert.ok(!hasError(untraced, /^NFR-1:/), untraced.errors.join('\n'));
});

test('a draft architecture (**Status:** draft) contributes no AD ids and the run warns', () => {
  const draft = ARCHITECTURE.replace('## Decisions', '**Status:** draft\n\n## Decisions');
  const dir = project({ architecture: draft });
  const inv = loadInventory(dir);
  assert.equal(inv.architectureDraft, true);
  assert.equal(inv.ids.has('AD-1'), false);
  assert.equal(inv.ids.get('R-1').state, 'active');
  const r = run(dir);
  assert.equal(r.code, 1, r.out);
  assert.match(r.out, /warning: docs\/architecture\.md is draft — AD ids not loaded/);
  assert.match(r.out, /Task E0-1: unknown trace AD-1/);
  const reviewed = project({ architecture: ARCHITECTURE.replace('## Decisions', '**Status:** reviewed (critic: ship · codex: skipped — offline)\n\n## Decisions') });
  assert.equal(loadInventory(reviewed).architectureDraft, false);
  assert.equal(run(reviewed).code, 0);
});

test('an AC defined outside ## Acceptance criteria is an error and does not count for its Task', () => {
  const moved = backlogMd({ acs: ACS.replace('### E2-2 — Report export\n- **E2-2.AC1** — Given a report, when export is clicked, then a CSV downloads.', '') })
    .replace('## Open questions\n- none', '## Open questions\n- **E2-2.AC1** — Given a report, when export is clicked, then a CSV downloads.');
  const res = check(project({ backlog: moved }));
  assert.ok(hasError(res, /^E2-2\.AC1 defined outside ## Acceptance criteria \(line \d+\)/), res.errors.join('\n'));
  assert.ok(hasError(res, /Task E2-2: no acceptance criterion/), res.errors.join('\n'));
  const noHeading = check(project({ backlog: backlogMd({ acs: ACS.replace('### E0-1 — Project scaffold\n', '') }) }));
  assert.ok(hasError(noHeading, /AC E0-1\.AC1 defined under the section heading — expected ### E0-1/), noHeading.errors.join('\n'));
  assert.ok(hasError(noHeading, /Task E0-1: no acceptance criterion/), noHeading.errors.join('\n'));
});

test('(4b) two different criteria both defined as E1-2.AC1 → error and exit 1', () => {
  const dir = project({ backlog: backlogMd({ acs: ACS.replace('- **E1-2.AC2**', '- **E1-2.AC1**') }) });
  const { code, out } = run(dir);
  assert.equal(code, 1);
  assert.match(out, /duplicate AC definition E1-2\.AC1/);
});

// ---------------------------------------------------------------------------------------------
// (5) scheduling · (6)(7) warnings · (8) story map
// ---------------------------------------------------------------------------------------------

test('(5) scheduleLanes is deterministic: foundation chain, lanes and makespan for N = 2/3/4', () => {
  const { tasks } = parseBacklog(backlogMd());
  const two = scheduleLanes(tasks, 2);
  assert.deepEqual(two.foundation, ['E0-1', 'E0-2']);
  assert.equal(two.foundationPts, 12);
  assert.deepEqual(two.lanes, [{ ids: ['E1-2', 'E2-1'], pts: 16 }, { ids: ['E1-1', 'E1-3', 'E2-2'], pts: 12 }]);
  assert.equal(two.makespan, 16);
  assert.deepEqual(two.criticalPath, { ids: ['E1-2', 'E2-1'], pts: 16 });

  const three = scheduleLanes(tasks, 3);
  assert.deepEqual(three.lanes, [{ ids: ['E1-2', 'E2-1'], pts: 16 }, { ids: ['E1-1', 'E1-3'], pts: 8 }, { ids: ['E2-2'], pts: 4 }]);
  assert.equal(three.makespan, 16);

  const four = scheduleLanes(tasks, 4);
  assert.deepEqual(four.lanes.map((l) => l.ids), [['E1-2', 'E2-1'], ['E1-1', 'E1-3'], ['E2-2'], []]);
  assert.equal(four.makespan, 16);
  assert.deepEqual(scheduleLanes([...tasks].reverse(), 2), two);
});

test('scheduleLanes orders ids numerically (E1-2 before E1-10) in the foundation chain and tie-breaks', () => {
  const t = (id, wave, deps = []) => ({ id, wave, deps, pts: 4, size: 'M', slice: 'WS', traces: [], node: null });
  const foundation = [t('E0-10', '0', ['E0-9']), t('E0-9', '0', ['E0-2']), t('E0-2', '0', ['E0-1']), t('E0-1', '0')];
  assert.deepEqual(scheduleLanes(foundation, 2).foundation, ['E0-1', 'E0-2', 'E0-9', 'E0-10']);
  assert.deepEqual(scheduleLanes([t('E1-10', '1'), t('E1-2', '1'), t('E1-9', '1')], 1).lanes[0].ids, ['E1-2', 'E1-9', 'E1-10']);
});

test('renderLanes writes the foundation line and one table per N, or the foundation-only sentence', () => {
  const { tasks } = parseBacklog(backlogMd());
  const md = renderLanes(tasks);
  assert.match(md, /\*\*Foundation \(Wave 0, sequential\):\*\* E0-1 → E0-2 · 12 pts/);
  for (const n of [2, 3, 4]) assert.match(md, new RegExp(`### N = ${n} developers\\n\\n\\| Lane \\| Tasks \\| Pts \\|`));
  assert.match(md, /Makespan: 16 pts after the foundation · critical path: E1-2 → E2-1 \(16 pts\)/);
  assert.match(renderLanes(tasks.filter((t) => t.wave === '0')), /No parallel work yet — foundation only\./);
});

test('(6) critical-path warning fires above 60% of non-foundation points', () => {
  assert.ok(!check(project()).warnings.some((w) => /critical path/.test(w)));
  const rows = TASK_ROWS.filter((r) => !r.startsWith('| E2-2 |'));
  const epics = ['| E0 | Foundation | a | b | 12 | — | — |', '| E1 | Ordering | a | b | 16 | E0 | — |', '| E2 | Reporting | a | b | 8 | E1 | — |'];
  const res = check(project({ backlog: backlogMd({ rows, epics, acs: ACS.replace(/### E2-2[\s\S]*$/, '') }) }));
  assert.deepEqual(res.errors, []);
  assert.ok(res.warnings.some((w) => /critical path E1-2 → E2-1 = 16 pts, 67% of 24/.test(w)), res.warnings.join('\n'));
});

test('(7) same wave + shared Node + different lanes → warning', () => {
  const rows = withRow('E2-2', '| E2-2 | E2 | Report export | story | M | 4 | E0-1 | 2 | R2 | reporting | FL-2.A1 | TODO | — | — |');
  const res = check(project({ backlog: backlogMd({ rows }) }));
  assert.deepEqual(res.errors, []);
  assert.ok(res.warnings.some((w) => /Tasks E2-1 and E2-2 share Node reporting in Wave 2 but land in different lanes/.test(w)), res.warnings.join('\n'));
});

test('other warnings: tech without trace, leaf without Task, XH story with >5 ACs', () => {
  const rows = withRow('E0-1', '| E0-1 | E0 | Project scaffold | tech | H | 8 | — | 0 | WS | platform-core | — | TODO | — | — |')
    .map((r) => (r.startsWith('| E2-2 |') ? '| E2-2 | E2 | Report export | story | XH | 16 | E0-1 | 2 | R2 | — | FL-2.A1 | TODO | — | — |' : r));
  const epics = ['| E0 | Foundation | a | b | 12 | — | — |', '| E1 | Ordering | a | b | 16 | E0 | — |', '| E2 | Reporting | a | b | 24 | E1 | — |'];
  const acs = `${ACS}\n${[2, 3, 4, 5, 6].map((k) => `- **E2-2.AC${k}** — more`).join('\n')}`;
  const res = check(project({ backlog: backlogMd({ rows, epics, acs }) }));
  assert.deepEqual(res.errors, []);
  assert.ok(res.warnings.some((w) => /Task E0-1: tech Task with no trace/.test(w)));
  assert.ok(res.warnings.some((w) => /leaf reporting: no Task targets it/.test(w)) === false);
  assert.ok(res.warnings.some((w) => /Task E2-2: XH story with 6 criteria/.test(w)), res.warnings.join('\n'));
  const noReporting = check(project({ backlog: backlogMd({ rows: TASK_ROWS.map((r) => r.replace('| reporting |', '| — |')) }) }));
  assert.ok(noReporting.warnings.some((w) => /leaf reporting: no Task targets it/.test(w)), noReporting.warnings.join('\n'));
});

test('(8) renderStoryMap: critical flow first, activities as columns, slices as rows', () => {
  const { tasks } = parseBacklog(backlogMd());
  const md = renderStoryMap(tasks, loadInventory(project()).flows);
  const lines = md.split('\n');
  assert.equal(lines[0], '### FL-1 — Place order (critical)');
  assert.equal(lines[2], '| Slice | FL-1.A1 Sign in | FL-1.A2 Place order | FL-1.A3 Receive confirmation |');
  assert.equal(lines[4], '| WS | E1-1 | E1-2 | E1-3 |');
  assert.equal(lines[5], '| R2 | — | — | — |');
  assert.ok(lines.includes('### FL-2 — Reporting'));
  assert.ok(lines.includes('| R2 | E2-1, E2-2 |'));
  assert.equal(renderStoryMap(tasks, []), '');
  const noActs = renderStoryMap(tasks, [{ id: 'FL-3', name: 'Later', critical: false, withdrawn: false, activities: [] }]);
  assert.equal(noActs, '### FL-3 — Later\n\n_No backbone activities in docs/discovery.md._');
});

test('replaceRegion swaps only the body and throws on missing markers', () => {
  const md = 'a\n<!-- x:begin -->\nold\n<!-- x:end -->\nb';
  assert.equal(replaceRegion(md, 'x', 'new'), 'a\n<!-- x:begin -->\nnew\n<!-- x:end -->\nb');
  assert.throws(() => replaceRegion('a', 'x', 'new'), /markers missing/);
});

test('locateRegions rejects duplicated, inline, reversed and overlapping markers', () => {
  const ok = 'a\n<!-- x:begin -->\n1\n<!-- x:end -->\n<!-- y:begin -->\n2\n<!-- y:end -->\n';
  assert.deepEqual(Object.keys(locateRegions(ok, ['x', 'y'])), ['x', 'y']);
  assert.throws(() => locateRegions(ok.replace('1\n', '1\n<!-- x:begin -->\n'), ['x']), /appears 2 times/);
  assert.throws(() => locateRegions('text <!-- x:begin -->\n1\n<!-- x:end -->\n', ['x']), /alone on its own line/);
  assert.throws(() => locateRegions('<!-- x:end -->\n1\n<!-- x:begin -->\n', ['x']), /end --> appears before/);
  const nested = '<!-- x:begin -->\n<!-- y:begin -->\n2\n<!-- y:end -->\n<!-- x:end -->\n';
  assert.throws(() => locateRegions(nested, ['x', 'y']), /regions x and y overlap/);
  const crossed = '<!-- x:begin -->\n<!-- y:begin -->\n<!-- x:end -->\n<!-- y:end -->\n';
  assert.throws(() => locateRegions(crossed, ['x', 'y']), /regions x and y overlap/);
});

test('--write with nested regions or a duplicated marker → exit 1 and the file is byte-for-byte unchanged', () => {
  const nested = backlogMd({ markers: false })
    .replace('## Story map\n(no markers)', '## Story map\n<!-- lanes:begin -->\n<!-- storymap:begin -->\nx\n<!-- storymap:end -->\n<!-- lanes:end -->')
    .replace('## Parallel plan\n(no markers)', '## Parallel plan');
  const duplicated = backlogMd().replace('## External blockers', '<!-- lanes:begin -->\n## External blockers');
  for (const [name, backlog, re] of [['nested', nested, /regions lanes and storymap overlap/], ['duplicated', duplicated, /marker <!-- lanes:begin --> appears 2 times/]]) {
    const dir = project({ backlog });
    const r = run(dir, '--write');
    assert.equal(r.code, 1, `${name}: ${r.out}`);
    assert.match(r.out, re, name);
    assert.doesNotMatch(r.out, /note: wrote/, name);
    assert.equal(fs.readFileSync(path.join(dir, '.agents', 'backlog.md'), 'utf8'), backlog, name);
  }
});

// ---------------------------------------------------------------------------------------------
// (9)–(13) CLI behaviour
// ---------------------------------------------------------------------------------------------

test('(9) --write changes only the two marker regions and is idempotent', () => {
  const dir = project();
  const before = fs.readFileSync(path.join(dir, '.agents', 'backlog.md'), 'utf8');
  const first = run(dir, '--write');
  assert.equal(first.code, 0, first.out);
  assert.match(first.out, /note: wrote lanes \+ story map/);
  const after = fs.readFileSync(path.join(dir, '.agents', 'backlog.md'), 'utf8');
  const strip = (s) => s.replace(/<!-- (lanes|storymap):begin -->[\s\S]*?<!-- \1:end -->/g, '<!-- $1 -->');
  assert.equal(strip(after), strip(before));
  assert.match(after, /<!-- lanes:begin -->\n\*\*Foundation/);
  assert.match(after, /<!-- storymap:begin -->\n### FL-1 — Place order \(critical\)/);
  const second = run(dir, '--write');
  assert.equal(second.code, 0);
  assert.equal(fs.readFileSync(path.join(dir, '.agents', 'backlog.md'), 'utf8'), after);
});

test('--write with missing markers reports "markers missing" and exits 1; with errors it is skipped', () => {
  const noMarkers = run(project({ backlog: backlogMd({ markers: false }) }), '--write');
  assert.equal(noMarkers.code, 1);
  assert.match(noMarkers.out, /markers missing/);
  const dir = project({ backlog: backlogMd({ acs: ACS.replace('- **E2-2.AC1**', '- **E2-2.ACa**') }) });
  const before = fs.readFileSync(path.join(dir, '.agents', 'backlog.md'), 'utf8');
  const r = run(dir, '--write');
  assert.equal(r.code, 1);
  assert.match(r.out, /--write skipped/);
  assert.equal(fs.readFileSync(path.join(dir, '.agents', 'backlog.md'), 'utf8'), before);
});

test('(10) legacy WP backlog → exit 0 with the legacy message, also under --json', () => {
  const dir = project({ backlog: LEGACY_BACKLOG });
  const r = run(dir);
  assert.equal(r.code, 0);
  assert.match(r.out, /legacy WP backlog — regenerate with \/setup:create-backlog to use Task checks/);
  const j = run(dir, '--json');
  assert.equal(j.code, 0);
  assert.equal(JSON.parse(j.out).legacy, true);
});

test('(11) no system.yaml → Node checks skipped, everything else runs', () => {
  const rows = withRow('E2-2', '| E2-2 | E2 | Report export | story | M | 4 | E0-1 | 2 | R2 | anything | FL-2.A1 | TODO | — | — |');
  const res = check(project({ system: null, backlog: backlogMd({ rows }) }));
  assert.deepEqual(res.errors, []);
  assert.ok(!res.warnings.some((w) => /leaf/.test(w)));
});

const SYSTEM_NEGATIVES = [
  ['duplicate node id', SYSTEM.replace('  - id: cloud\n    name: Cloud\n    kind: root\n', '  - id: cloud\n    name: Cloud\n    kind: root\n  - id: cloud\n    name: Cloud 2\n    kind: root\n'), /duplicate node id cloud/],
  ['two trunks', SYSTEM.replace('  - id: cloud\n    name: Cloud\n    kind: root\n', '  - id: cloud\n    name: Cloud\n    kind: trunk\n'), /exactly one trunk required \(found 2: platform-core, cloud\)/],
  ['self-parent', SYSTEM.replace('    parent: data-analytics\n', '    parent: reporting\n'), /node reporting: self-parent/],
  ['two-node parent cycle', SYSTEM.replace('  - id: data-analytics\n    name: Data & Analytics\n    kind: branch\n    parent: platform-core\n', '  - id: data-analytics\n    name: Data & Analytics\n    kind: branch\n    parent: reporting\n'), /parent cycle: (data-analytics → reporting → data-analytics|reporting → data-analytics → reporting)/],
  ['node unreachable from trunk', SYSTEM.replace('    kind: branch\n    parent: platform-core\n    subdomain: supporting\n  - id: reporting', '    kind: branch\n    parent: offgrid\n    subdomain: supporting\n  - id: reporting'), /node data-analytics: unknown parent offgrid|node reporting: not reachable from trunk platform-core/],
  ['bad kind', SYSTEM.replace('    kind: twig\n', '    kind: bough\n'), /node notification: kind "bough" not in trunk\/branch\/twig\/leaf\/root/],
  ['branch without subdomain', SYSTEM.replace('    parent: platform-core\n    subdomain: generic\n', '    parent: platform-core\n'), /node identity: branch without subdomain/],
  ['trunk with a parent', SYSTEM.replace('    kind: trunk\n', '    kind: trunk\n    parent: cloud\n'), /node platform-core: trunk must not have a parent/],
  ['leaf without a parent', SYSTEM.replace('    kind: leaf\n    parent: identity\n', '    kind: leaf\n'), /node authn: leaf requires a parent/],
  ['unknown link node', SYSTEM.replace('  - from: orders\n    to: notification\n', '  - from: orders\n    to: ghost\n'), /links\[0\]\.to: unknown node "ghost"/],
  ['bad link kind', SYSTEM.replace('    kind: ohs\n', '    kind: acl, calls\n'), /kind "acl, calls" not in/],
  ['unknown flow step', SYSTEM.replace('steps: [authn, orders, email]', 'steps: [authn, orders, sms]'), /flow place-order: unknown step node sms/],
  ['status key rejected', SYSTEM.replace('    criticality: critical\n', '    criticality: critical\n    status: done\n'), /status \/ progress keys are not stored in the map/],
  ['scalar item in nodes', SYSTEM.replace('  - id: cloud\n    name: Cloud\n    kind: root\n', '  - id: cloud\n    name: Cloud\n    kind: root\n  - stray-scalar\n'), /nodes\[11\] must be a map/],
  ['links as a list of scalars', SYSTEM.replace(/links:\n(?:  - .*\n|    .*\n)*/, 'links: [unknown-node]\n'), /links\[0\] must be a map/],
  ['flows as a map', SYSTEM.replace(/flows:\n[\s\S]*$/, 'flows:\n  id: place-order\n  steps: [authn, orders]\n'), /flows must be a list of maps/],
  ['nodes as a map', SYSTEM.replace(/nodes:\n[\s\S]*?links:/, 'nodes:\n  id: platform-core\n  kind: trunk\nlinks:'), /nodes must be a non-empty list of maps/],
];

for (const [name, system, re] of SYSTEM_NEGATIVES) {
  test(`(11b) system.yaml negative: ${name} → exit 1 under --system-only and in a normal run`, () => {
    const dir = project({ system });
    const only = run(dir, '--system-only');
    assert.equal(only.code, 1, only.out);
    assert.match(only.out, re);
    const full = run(dir);
    assert.equal(full.code, 1, full.out);
    assert.match(full.out, re);
  });
}

test('(11b) a system.yaml that does not parse is an error with a message, not a crash', () => {
  const dir = project({ system: 'nodes:\n  - id: a\n      name: bad\n' });
  for (const flags of [['--system-only'], []]) {
    const r = run(dir, ...flags);
    assert.equal(r.code, 1, r.out);
    assert.match(r.out, /error: docs\/map\/system\.yaml: yaml: unexpected indent/);
  }
});

test('full run: critical FL without a critical system flow, or a system flow naming an unknown FL', () => {
  const noCritical = check(project({ system: SYSTEM.replace('critical: true', 'critical: false') }));
  assert.ok(hasError(noCritical, /system\.yaml: critical FL-1 has no flow with critical: true/), noCritical.errors.join('\n'));
  const badFl = check(project({ system: SYSTEM.replace('fl: FL-1', 'fl: FL-9') }));
  assert.ok(hasError(badFl, /system\.yaml: flow place-order: fl FL-9 not in docs\/discovery\.md/), badFl.errors.join('\n'));
});

test('(11c) the header Source PRD is honoured; --prd overrides; a named PRD that is missing → exit 2', () => {
  const header = '**Date:** 2026-10-10 · **Source PRD:** `docs/product.md` · **Sizes:** M=4 · H=8 · XH=16 points';
  const dir = project({ prdName: 'docs/product.md', backlog: backlogMd({ header }) });
  assert.equal(run(dir).code, 0, run(dir).out);
  const noR1 = project({ prdName: 'docs/product.md', backlog: backlogMd({ header }), prd: PRD.replace('- **R-1**', '- **R-7**') });
  const r = run(noR1);
  assert.equal(r.code, 1);
  assert.match(r.out, /Task E1-1: unknown trace R-1/);
  assert.match(r.out, /R-7: no Task traces it/);
  fs.writeFileSync(path.join(noR1, 'docs', 'other.md'), PRD);
  assert.equal(run(noR1, '--prd', 'docs/other.md').code, 0);
  const missing = run(noR1, '--prd', 'docs/nope.md');
  assert.equal(missing.code, 2);
  assert.match(missing.out, /PRD not found at docs\/nope\.md \(named by --prd\)/);
  const missingHeader = run(project({ prd: null, backlog: backlogMd() }));
  assert.equal(missingHeader.code, 2);
  assert.match(missingHeader.out, /named by the backlog header/);
});

test('(12) --system-only exits 0 / 1 / 2 for a valid / invalid / missing system.yaml', () => {
  assert.equal(run(project(), '--system-only').code, 0);
  assert.equal(run(project({ system: SYSTEM.replace('    kind: twig\n', '    kind: bough\n') }), '--system-only').code, 1);
  const missing = run(project({ system: null }), '--system-only');
  assert.equal(missing.code, 2);
  assert.match(missing.out, /system\.yaml not found/);
  const sysOnlyNoBacklog = run(project({ system: SYSTEM, backlog: null }), '--system-only');
  assert.equal(sysOnlyNoBacklog.code, 0);
});

test('(13) CLI exit codes 0 / 1 / 2 and the --json shape', () => {
  assert.equal(run(project()).code, 0);
  assert.equal(run(project({ backlog: backlogMd({ acs: ACS.replace('- **E2-2.AC1**', '- **E2-2.ACa**') }) })).code, 1);
  const empty = fs.mkdtempSync(path.join(os.tmpdir(), 'backlog-check-empty-'));
  const r = run(empty);
  assert.equal(r.code, 2);
  assert.match(r.out, /backlog\.md not found/);
  assert.equal(run(project(), 'stray-positional').code, 2);
  assert.equal(run(project(), '--bogus').code, 2);
  assert.equal(run(project(), '--prd', '--write').code, 2);
  assert.equal(run(project(), '--write', '--json').code, 0);
  const j = JSON.parse(run(project(), '--json').out);
  assert.deepEqual(Object.keys(j), ['errors', 'warnings', 'lanes', 'notes']);
  assert.deepEqual(j.errors, []);
  assert.deepEqual(Object.keys(j.lanes), ['2', '3', '4']);
  assert.equal(j.lanes['2'].makespan, 16);
});

test('main() is callable in-process with the same exit codes', () => {
  const dir = project();
  const log = console.log;
  console.log = () => {};
  try {
    assert.equal(main(['--root', dir]), 0);
    assert.equal(main(['--root', dir, '--system-only']), 0);
  } finally {
    console.log = log;
  }
});

test('checkSystem accepts the schema worked example shape without warnings about structure', () => {
  const res = checkSystem(loadSystem(project()));
  assert.deepEqual(res.errors, []);
});
