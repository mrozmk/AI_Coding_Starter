import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import {
  parseTables, parseBacklog, loadInventory, loadSystem, checkBacklog, checkSystem,
  renderStoryMap, replaceRegion, locateRegions, main, chainPaths, impactOf,
  loadPlanTasks, staleTaskWarnings, SCOPES, PRE_SCOPE_MESSAGE, NO_CORE_WARNING,
  PRE_DETAIL_MESSAGE, EPIC_DIR, readBacklogFiles, backlogFingerprint, epicSlug, epicFileName,
  renderMeta, renderEpicFile, checkAgainstRoot, fenceScanner, QUALITY_MARKERS,
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

const TASK_HEADER = `| ID | Epic | Task | Type | Size | Pts | Depends on | Scope | Node | Traces | Status | Jira | Ref |
|----|------|------|------|------|-----|------------|-------|------|--------|--------|------|-----|`;

const TASK_ROWS = [
  '| E0-1 | E0 | Project scaffold | tech | H | 8 | — | CORE | platform-core | AD-1 | TODO | — | — |',
  '| E0-2 | E0 | Auth skeleton | tech | M | 4 | E0-1 | CORE | authn | AD-2, NFR-1 | TODO | — | — |',
  '| E1-1 | E1 | Sign in | story | M | 4 | E0-2 | MUST | authn | R-1, FL-1.A1 | TODO | — | — |',
  '| E1-2 | E1 | Place order | story | H | 8 | E0-1 | MUST | orders | R-2, FL-1.A2, AD-5 | TODO | — | — |',
  '| E1-3 | E1 | Confirmation email | story | M | 4 | E1-2 | MUST | email | FL-1.A3, G-1 | TODO | — | — |',
  '| E2-1 | E2 | Report view | story | H | 8 | E1-2 | MUST | reporting | FL-2.A1, BR-1 | TODO | — | — |',
  '| E2-2 | E2 | Report export | story | M | 4 | E0-1 | COULD | — | FL-2.A1 | TODO | — | — |',
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

const OUTSIDE_HEADER = `| ID | Owner | Item | Needed by | Starts after | Traces | Notes |
|----|-------|------|-----------|--------------|--------|-------|`;
const OUTSIDE_ROWS = ['| X-1 | DevOps | Deployment pipeline | E0-1 | — | — | — |'];

function backlogMd({ rows = TASK_ROWS, epics, header, detail = 'full', markers = true, taskHeader = TASK_HEADER, outside = OUTSIDE_ROWS, outsideHeader = OUTSIDE_HEADER } = {}) {
  const epicRows = epics ?? [
    '| E0 | Foundation | skeleton everything stands on | monolith is enough | 12 | — | — |',
    '| E1 | Ordering | first order placed (G-1) | users accept email confirmation | 16 | E0 | — |',
    '| E2 | Reporting | owners see totals | daily granularity suffices | 12 | E1 | — |',
  ];
  return `# Shop — Backlog (Epics + Tasks)
${header ?? '**Date:** 2026-10-10 · **Source PRD:** `docs/PRD.md` · **Architecture:** `docs/architecture.md` · **Jira namespace:** `shop` · **Sizes:** M=4 · H=8 · XH=16 points (currency, not hours)'}
${detail === null ? '' : `**Detail:** ${detail}\n`}
## Epic map
| Epic | Title | Outcome | Key assumption | Pts | Depends on | Jira |
|------|-------|---------|----------------|-----|------------|------|
${epicRows.join('\n')}

**E0** — appetite: small · cut first: nothing
**E1** — appetite: medium · cut first: E1-3

## Task table
${taskHeader}
${rows.join('\n')}

## Story map
${markers ? '<!-- storymap:begin -->\n(generated by backlog-check --write)\n<!-- storymap:end -->' : '(no markers)'}

${outside === null ? '' : `## Outside the dev backlog
${outsideHeader}
${outside.join('\n')}

`}## External blockers
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

// Today's pre-Scope shape: Wave / Slice instead of Scope.
const PRE_SCOPE_BACKLOG = `# Shop — Backlog (Epics + Tasks)
**Date:** 2026-10-10 · **Source PRD:** \`docs/PRD.md\`

## Epic map
| Epic | Title | Outcome | Key assumption | Pts | Depends on | Jira |
|------|-------|---------|----------------|-----|------------|------|
| E0 | Foundation | skeleton | monolith is enough | 12 | — | — |

## Task table
| ID | Epic | Task | Type | Size | Pts | Depends on | Wave | Slice | Node | Traces | Status | Jira | Ref |
|----|------|------|------|------|-----|------------|------|-------|------|--------|--------|------|-----|
| E0-1 | E0 | Project scaffold | tech | H | 8 | — | 0 | WS | platform-core | AD-1 | TODO | — | — |
| E0-2 | E0 | Auth skeleton | tech | M | 4 | E0-1 | 0 | WS | authn | AD-2, NFR-1 | TODO | — | — |

## Acceptance criteria
### E0-1 — Project scaffold
- **E0-1.AC1** — Given a clean clone, when \`npm test\` runs, then it passes.

## Story map
<!-- storymap:begin -->
<!-- storymap:end -->

## Parallel plan
<!-- lanes:begin -->
<!-- lanes:end -->
`;

// Stage-B shape: a Scope backlog whose criteria still sit in its own `## Acceptance criteria` section.
const PRE_DETAIL_BACKLOG = backlogMd({ detail: null }).replace('## Story map', `## Acceptance criteria\n${ACS}\n\n## Story map`);

/** Criteria lines of an `ACS`-shaped text, keyed by the `### <Task id>` block they sit in (`null` = before any). */
function acsByBlock(acs) {
  const blocks = new Map();
  let block = null;
  for (const line of acs.split('\n')) {
    const h = /^###\s+(E\d+-\d+)\b/.exec(line);
    if (h) { block = h[1]; continue; }
    if (line.trim() === '') continue;
    blocks.set(block, [...(blocks.get(block) ?? []), line]);
  }
  return blocks;
}

/**
 * The Epic files that belong to a backlog `md`: one file per Epic prefix of its Task table rows, one
 * block per row (Summary, Goal, In scope, Out of scope, `### Acceptance criteria` + the lines of
 * `acs` under that Task's `###` heading). `drop` omits blocks, `plain` omits Goal / scope, `noSummary`
 * omits the Summary, `extra` appends text to a file by Epic id, `extraFiles` adds whole files.
 * Copyable by other tests: it needs only the Task table and the Epic map of `md`.
 */
function epicFilesFor(md, { acs = ACS, drop = [], plain = [], noSummary = [], extra = {}, extraFiles = [] } = {}) {
  const tables = parseTablesLocal(md);
  const taskTable = tables.find((t) => ['ID', 'Epic', 'Size'].every((h) => t.header.includes(h)));
  const epicTable = tables.find((t) => ['Epic', 'Title', 'Pts'].every((h) => t.header.includes(h)) && !t.header.includes('ID'));
  const titles = new Map((epicTable?.rows ?? []).map((r) => [clean(r.Epic), clean(r.Title)]));
  const blocks = acsByBlock(acs);
  const byEpic = new Map();
  const seen = new Set();
  for (const r of taskTable?.rows ?? []) {
    const id = clean(r.ID);
    if (!/^E\d+-\d+$/.test(id) || seen.has(id)) continue;
    seen.add(id);
    const epic = id.split('-')[0];
    if (!byEpic.has(epic)) byEpic.set(epic, []);
    if (!drop.includes(id)) byEpic.get(epic).push({ id, title: clean(r.Task) });
  }
  const files = [...byEpic].map(([epic, tasks], i) => {
    const title = titles.get(epic) ?? 'Epic';
    const out = [`# ${epic} — ${title}`, ''];
    if (i === 0 && blocks.has(null)) out.push(...blocks.get(null), '');
    for (const t of tasks) {
      out.push(`## ${t.id} — ${t.title}`);
      if (!noSummary.includes(t.id)) out.push(`**Summary:** ${t.title} for the shop.`);
      if (!plain.includes(t.id)) out.push(`**Goal:** deliver ${t.title.toLowerCase()}.`, '**In scope:** the happy path and its errors.', '**Out of scope:** admin tooling.');
      out.push('### Acceptance criteria', ...(blocks.get(t.id) ?? []), '');
    }
    if (extra[epic]) out.push(extra[epic], '');
    return { name: `${epic}-${title.toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '')}.md`, text: out.join('\n') };
  });
  return [...files, ...extraFiles];
}
const clean = (cell) => (cell ?? '').replace(/[`*]/g, '').trim();
function parseTablesLocal(md) {
  const split = (line) => line.trim().replace(/^\|/, '').replace(/\|$/, '').split('|').map((c) => c.trim());
  const lines = md.split(/\r?\n/);
  const tables = [];
  for (let i = 0; i + 1 < lines.length; i += 1) {
    if (!lines[i].trim().startsWith('|') || !/^\s*\|?\s*:?-{3,}/.test(lines[i + 1])) continue;
    const header = split(lines[i]).map(clean);
    const rows = [];
    let j = i + 2;
    for (; j < lines.length && lines[j].trim().startsWith('|'); j += 1) {
      const cells = split(lines[j]);
      rows.push(Object.fromEntries(header.map((h, k) => [h, cells[k] ?? ''])));
    }
    tables.push({ header, rows });
    i = j - 1;
  }
  return tables;
}
/** The Shop fixture's Epic files (E0, E1, E2). */
const epicFiles = (opts = {}) => epicFilesFor(backlogMd(), opts);

function writeEpicFiles(dir, files) {
  fs.mkdirSync(dir, { recursive: true });
  for (const f of files) fs.writeFileSync(path.join(dir, f.name), f.text);
}

function project({ prd = PRD, prdName = 'docs/PRD.md', discovery = DISCOVERY, architecture = ARCHITECTURE, system = SYSTEM, backlog = backlogMd(), epicFiles: files } = {}) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'backlog-check-'));
  fs.mkdirSync(path.join(dir, '.agents'));
  fs.mkdirSync(path.join(dir, 'docs', 'map'), { recursive: true });
  if (prd !== null) fs.writeFileSync(path.join(dir, prdName), prd);
  if (discovery !== null) fs.writeFileSync(path.join(dir, 'docs', 'discovery.md'), discovery);
  if (architecture !== null) fs.writeFileSync(path.join(dir, 'docs', 'architecture.md'), architecture);
  if (system !== null) fs.writeFileSync(path.join(dir, 'docs', 'map', 'system.yaml'), system);
  if (backlog !== null) fs.writeFileSync(path.join(dir, '.agents', 'backlog.md'), backlog);
  const set = files ?? (backlog === null ? [] : epicFilesFor(backlog));
  if (set.length) writeEpicFiles(path.join(dir, EPIC_DIR), set);
  return dir;
}

/** A `.agents/.pending-update` candidate: PRD + backlog + its Epic files under `backlog/`. */
function writeCandidate(dir, backlog, files = epicFilesFor(backlog), prd = PRD) {
  const cand = path.join(dir, '.agents', '.pending-update');
  fs.mkdirSync(cand, { recursive: true });
  fs.writeFileSync(path.join(cand, 'PRD.md'), prd);
  fs.writeFileSync(path.join(cand, 'backlog.md'), backlog);
  if (files.length) writeEpicFiles(path.join(cand, 'backlog'), files);
  return cand;
}

function run(dir, ...flags) {
  const r = spawnSync(process.execPath, [SCRIPT, '--root', dir, ...flags], { encoding: 'utf8' });
  return { code: r.status, out: r.stdout + r.stderr };
}

/**
 * Parse + check of a `project()` directory's backlog set (the directory carries the PRD and the
 * system map). The Epic files are the ones on disk; handed another backlog text, they are
 * re-derived from it (`epicFilesFor`) unless `epicFiles` is passed explicitly. Runs through
 * `checkAgainstRoot`, so the resolver-backed "≥ 1 criterion under full" rule is included.
 */
function check(dir, backlog, { epicFiles: files } = {}) {
  const onDisk = readBacklogFiles(path.join(dir, '.agents', 'backlog.md'));
  const md = backlog ?? onDisk.md;
  const set = files ?? (backlog === undefined ? onDisk.epicFiles : epicFilesFor(md));
  const parsed = parseBacklog(md, { epicFiles: set });
  return checkAgainstRoot(dir, parsed);
}
/** A project from one mutation: backlogMd options plus the epicFilesFor options, or `files(md)`. */
const shop = (mutation = {}, extra = {}) => {
  const md = backlogMd(mutation);
  return project({ backlog: md, epicFiles: mutation.files ? mutation.files(md) : epicFilesFor(md, mutation), ...extra });
};

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

test('parseBacklog reads epics, tasks, the Epic files\' criteria and details, and the header fields', () => {
  const b = parseBacklog(backlogMd(), { epicFiles: epicFiles() });
  assert.equal(b.legacy, false);
  assert.equal(b.preDetail, false);
  assert.deepEqual(b.epics.map((e) => e.id), ['E0', 'E1', 'E2']);
  assert.equal(b.tasks.length, 7);
  assert.deepEqual(b.tasks[3].traces, ['R-2', 'FL-1.A2', 'AD-5']);
  assert.equal(b.tasks[6].node, null);
  assert.equal(b.acs.length, 9);
  assert.equal(b.acs[2].block, 'E1-1');
  assert.equal(b.acs[2].file, 'E1-ordering.md');
  assert.equal(b.acs[2].inCriteria, true);
  assert.deepEqual(Object.keys(b.acs[2]).sort(), ['block', 'file', 'id', 'inCriteria', 'line', 'task', 'text']);
  assert.equal(b.details.get('E1-1').summary, 'Sign in for the shop.');
  assert.equal(b.details.get('E1-1').file, 'E1-ordering.md');
  assert.equal(b.details.get('E1-1').goal, 'deliver sign in.');
  assert.deepEqual(b.files.map((f) => [f.name, f.epic, f.taskIds.length]), [['E0-foundation.md', 'E0', 2], ['E1-ordering.md', 'E1', 3], ['E2-reporting.md', 'E2', 2]]);
  assert.deepEqual(b.files.map((f) => f.text), epicFiles().map((f) => f.text), 'each Epic file keeps its text');
  assert.equal(b.detail, 'full');
  assert.equal(b.sourcePrd, 'docs/PRD.md');
  assert.equal(parseBacklog(backlogMd()).acs.length, 0, 'no Epic files → no criteria; the checker decides');
  assert.equal(parseBacklog(backlogMd({ detail: null })).detail, null);
});

test('parseEpicFile (through parseBacklog): label paragraphs, continuation lines, CRLF and meta lines', () => {
  const text = '# E1 — Ordering\r\n\r\n## E1-1 — Sign in\r\n> Size M (4) · stale\r\n**Summary:** one\r\n  more\r\n**Goal:** g\r\n### Acceptance criteria\r\n- **E1-1.AC1** — Given a,\r\n  When b, Then c.\r\n';
  const b = parseBacklog(backlogMd(), { epicFiles: [{ name: 'E1-ordering.md', text }] });
  assert.equal(b.details.get('E1-1').summary, 'one more', 'the meta line is no label text');
  assert.equal(b.details.get('E1-1').goal, 'g');
  assert.equal(b.acs[0].text, 'Given a, When b, Then c.');
  assert.deepEqual(b.problems, []);
});

test('parseEpicFile: criteria under a #### sub-heading inside ### Acceptance criteria count; the sub-heading ends a continuation', () => {
  const acs = ACS.replace('### E2-2 — Report export\n', '### E2-2 — Report export\n#### Happy path\n')
    + '\n#### Errors\n  not a continuation of AC1\n- **E2-2.AC2** — Given no orders, when export is clicked, then an empty CSV downloads.';
  const dir = shop({ acs });
  assert.deepEqual(check(dir).errors, []);
  const { md, epicFiles: files } = readBacklogFiles(path.join(dir, '.agents', 'backlog.md'));
  const mine = parseBacklog(md, { epicFiles: files }).acs.filter((a) => a.task === 'E2-2');
  assert.deepEqual(mine.map((a) => [a.id, a.block, a.inCriteria]), [['E2-2.AC1', 'E2-2', true], ['E2-2.AC2', 'E2-2', true]]);
  assert.equal(mine[0].text, 'Given a report, when export is clicked, then a CSV downloads.');
});

test('parseEpicFile: a fenced code sample in a criterion continuation is text — no heading, label or criterion inside it', () => {
  const sample = [
    '- **E2-2.AC1** — Given a report, when export is clicked, then a CSV downloads:',
    '  ```sh',
    '# comment',
    '## E0-9 — x',
    '**Goal:** not a label',
    '- **E2-2.AC7** — not a criterion',
    '  ```',
    '- **E2-2.AC2** — Given no orders, when export is clicked, then an empty CSV downloads.',
  ].join('\n');
  const acs = ACS.replace('- **E2-2.AC1** — Given a report, when export is clicked, then a CSV downloads.', sample);
  const dir = shop({ acs });
  assert.deepEqual(check(dir).errors, []);
  const { md, epicFiles: files } = readBacklogFiles(path.join(dir, '.agents', 'backlog.md'));
  const b = parseBacklog(md, { epicFiles: files });
  assert.deepEqual(b.problems, []);
  assert.deepEqual(b.files.find((f) => f.epic === 'E2').taskIds, ['E2-1', 'E2-2']);
  assert.deepEqual(b.acs.filter((a) => a.task === 'E2-2').map((a) => [a.id, a.inCriteria]), [['E2-2.AC1', true], ['E2-2.AC2', true]]);
  assert.equal(b.acs.find((a) => a.id === 'E2-2.AC1').text, 'Given a report, when export is clicked, then a CSV downloads: ```sh');
  assert.equal(b.details.get('E2-2').goal, 'deliver report export.');
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
  ['duplicate Task id', { rows: [...TASK_ROWS, '| E2-2 | E2 | Dup | story | M | 4 | — | COULD | — | FL-2.A1 | TODO | — | — |'] }, /duplicate Task id E2-2/],
  ['Task epic not in Epic map', { rows: withRow('E2-2', '| E2-2 | E9 | Report export | story | M | 4 | E0-1 | COULD | — | FL-2.A1 | TODO | — | — |') }, /Task E2-2: Epic E9 not in Epic map/],
  ['unknown dependency', { rows: withRow('E2-2', '| E2-2 | E2 | Report export | story | M | 4 | E7-7 | COULD | — | FL-2.A1 | TODO | — | — |') }, /Task E2-2: unknown dependency E7-7/],
  ['Size outside M/H/XH', { rows: withRow('E2-2', '| E2-2 | E2 | Report export | story | S | 4 | E0-1 | COULD | — | FL-2.A1 | TODO | — | — |') }, /Task E2-2: Size S not in M\/H\/XH/],
  ['Pts ≠ size points', { rows: withRow('E2-2', '| E2-2 | E2 | Report export | story | M | 5 | E0-1 | COULD | — | FL-2.A1 | TODO | — | — |') }, /Task E2-2: Pts 5 ≠ 4 for Size M/],
  ['Epic Pts ≠ sum of Tasks', { epics: ['| E0 | Foundation | a | b | 12 | — | — |', '| E1 | Ordering | a | b | 16 | E0 | — |', '| E2 | Reporting | a | b | 8 | E1 | — |'] }, /Epic E2: Pts 8 ≠ 12/],
  ['Task without AC under Detail: full', { acs: ACS.replace(/### E2-2 — Report export\n- \*\*E2-2\.AC1\*\*[^\n]*/, '') }, /^Task E2-2: no acceptance criterion \(expected - \*\*E2-2\.AC1\*\* — … in \.agents\/backlog\/E2-reporting\.md, or an approved spec in Ref\)$/],
  ['AC under the wrong Task heading', { acs: ACS.replace('- **E2-2.AC1**', '- **E2-1.AC2**') }, /^AC E2-1\.AC2 defined under ## E2-2 — expected ## E2-1 \(E2-reporting\.md\)$/],
  ['AC in the wrong Epic file', { extra: { E1: '- **E2-2.AC2** — Given x When y Then z' } }, /^AC E2-2\.AC2 defined under ## E1-3 — expected ## E2-2 \(E1-ordering\.md\)$/],
  ['AC outside a Task\'s ### Acceptance criteria', { extra: { E2: '### Notes\n- **E2-2.AC2** — Given x When y Then z' } }, /^E2-2\.AC2 defined outside a Task's ### Acceptance criteria \(E2-reporting\.md line \d+\)$/],
  ['duplicate AC definition id', { acs: ACS.replace('- **E1-2.AC2**', '- **E1-2.AC1**') }, /^duplicate AC definition E1-2\.AC1 \(E1-ordering\.md line \d+\)/],
  ['malformed AC id', { acs: ACS.replace('- **E2-2.AC1**', '- **E2-2.ACa**') }, /malformed AC id E2-2\.ACa/],
  ['AC for a Task not in the table', { extra: { E2: '## E2-9 — Ghost\n### Acceptance criteria\n- **E2-9.AC1** — Given x When y Then z' } }, /^AC E2-9\.AC1: Task E2-9 not in Task table$/],
  ['Task heading not in the Task table', { extra: { E2: '## E2-9 — Ghost\n**Summary:** gone' } }, /^E2-reporting\.md: Task E2-9 not in the Task table$/],
  ['Task heading in the wrong Epic file', { drop: ['E2-2'], extra: { E1: '## E2-2 — Report export\n**Summary:** x\n### Acceptance criteria\n- **E2-2.AC1** — Given x When y Then z' } }, /^E1-ordering\.md: Task E2-2 belongs to Epic E2$/],
  ['live Task without a heading', { drop: ['E2-2'] }, /^Task E2-2: no `## E2-2 — …` block in the Epic file of E2 \(\.agents\/backlog\/E2-reporting\.md\)$/],
  ['live Task of an Epic without a file', { files: (md) => epicFilesFor(md).filter((f) => !f.name.startsWith('E2-')) }, /^Task E2-1: no `## E2-1 — …` block in the Epic file of E2 \(\.agents\/backlog\/E2-reporting\.md\)$/],
  ['two Epic files for one Epic', { extraFiles: [{ name: 'E2-other.md', text: '# E2 — Other\n' }] }, /^Epic E2: two Epic files \(E2-other\.md, E2-reporting\.md\)$/],
  ['an Epic file for an Epic not in the map', { extraFiles: [{ name: 'E7-legacy.md', text: '# E7 — Legacy\n' }] }, /^Epic file E7-legacy\.md: Epic E7 not in the Epic map$/],
  ['an Epic file whose first line is not # E<n> — …', { files: (md) => epicFilesFor(md).map((f) => (f.name.startsWith('E2-') ? { ...f, text: f.text.replace('# E2 — Reporting', 'Reporting notes') } : f)) }, /^Epic file E2-reporting\.md: first line must be `# E2 — <title>`$/],
  ['an Epic file headed by another Epic', { files: (md) => epicFilesFor(md).map((f) => (f.name.startsWith('E2-') ? { ...f, text: f.text.replace('# E2 — Reporting', '# E3 — Reporting') } : f)) }, /^Epic file E2-reporting\.md: first line must be `# E2 — <title>`$/],
  ['a stray ## heading inside an Epic file', { extra: { E2: '## Notes' } }, /^Epic file E2-reporting\.md line \d+: unexpected heading `## Notes`/],
  ['a duplicate Task heading in one Epic file', { extra: { E2: '## E2-2 — Report export again\n**Summary:** x' } }, /^Epic file E2-reporting\.md: duplicate Task heading E2-2 \(line \d+\)$/],
  ['**Detail:** missing', { detail: null }, /^backlog header: \*\*Detail:\*\* must be `structure` or `full`$/],
  ['**Detail:** partial', { detail: 'partial' }, /^backlog header: \*\*Detail:\*\* must be `structure` or `full`$/],
  ['unknown Node', { rows: withRow('E2-2', '| E2-2 | E2 | Report export | story | M | 4 | E0-1 | COULD | exports | FL-2.A1 | TODO | — | — |') }, /Task E2-2: unknown Node exports/],
  ['unknown trace id', { rows: withRow('E2-2', '| E2-2 | E2 | Report export | story | M | 4 | E0-1 | COULD | — | FL-2.A1, R-99 | TODO | — | — |') }, /Task E2-2: unknown trace R-99/],
  ['active R- with no Task tracing it', { rows: withRow('E1-1', '| E1-1 | E1 | Sign in | story | M | 4 | E0-2 | MUST | authn | FL-1.A1 | TODO | — | — |') }, /^R-1: no Task and no outside row traces it/],
  ['critical backbone activity without a CORE / MUST Task', { rows: withRow('E1-3', '| E1-3 | E1 | Confirmation email | story | M | 4 | E1-2 | COULD | email | FL-1.A3, G-1 | TODO | — | — |') }, /FL-1\.A3 \(critical flow FL-1\): no CORE or MUST Task traces it/],
  ['CORE Task depending on a MUST Task', { rows: withRow('E0-2', '| E0-2 | E0 | Auth skeleton | tech | M | 4 | E1-1 | CORE | authn | AD-2, NFR-1 | TODO | — | — |') }, /Task E0-2: CORE Task depends on E1-1 \(MUST\) — CORE cannot wait on later work/],
  ['MUST Task depending on a COULD Task', { rows: withRow('E2-1', '| E2-1 | E2 | Report view | story | H | 8 | E2-2 | MUST | reporting | FL-2.A1, BR-1 | TODO | — | — |') }, /Task E2-1: MUST Task depends on E2-2 \(COULD\) — committed work cannot depend on optional work/],
  ['Type outside story/tech', { rows: withRow('E2-2', '| E2-2 | E2 | Report export | bug | M | 4 | E0-1 | COULD | — | FL-2.A1 | TODO | — | — |') }, /Task E2-2: Type bug not in story\/tech/],
  ['Scope outside CORE/MUST/COULD', { rows: withRow('E2-2', '| E2-2 | E2 | Report export | story | M | 4 | E0-1 | MVP | — | FL-2.A1 | TODO | — | — |') }, /Task E2-2: Scope MVP must be CORE, MUST or COULD/],
  ['outside row: Needed by not a Task', { outside: ['| X-1 | DevOps | Deployment pipeline | E9-9 | — | — | — |'] }, /^outside X-1: Needed by E9-9 is not a Task$/],
  ['outside row: Starts after not a Task', { outside: ['| X-1 | QA | Regression run | — | E9-9 | — | — |'] }, /^outside X-1: Starts after E9-9 is not a Task$/],
  ['outside row: Starts after a Task that is in Needed by', { outside: ['| X-1 | QA | Regression run | E1-2 | E1-2 | — | — |'] }, /^outside rows: wait cycle E1-2 → X-1 → E1-2 — an item and the Tasks around it wait for each other$/],
  ['outside row: Starts after a Task that depends on a Needed by Task', { outside: ['| X-1 | QA | Regression run | E0-1 | E1-3 | — | — |'] }, /^outside rows: wait cycle E0-1 → X-1 → E1-3 → E1-2 → E0-1 — an item and the Tasks around it wait for each other$/],
  ['outside rows: two rows that wait for each other through Tasks', { outside: ['| X-1 | QA | Regression run | E2-2 | E2-1 | — | — |', '| X-2 | QA | Test data | E2-1 | E2-2 | — | — |'] }, /^outside rows: wait cycle E2-1 → X-2 → E2-2 → X-1 → E2-1 — an item and the Tasks around it wait for each other$/],
  ['outside row: unknown trace', { outside: ['| X-1 | DevOps | Deployment pipeline | E0-1 | — | R-99 | — |'] }, /^outside X-1: unknown trace R-99$/],
  ['outside row: withdrawn trace', { outside: ['| X-1 | DevOps | Deployment pipeline | E0-1 | — | R-3 | — |'] }, /^outside X-1: traces withdrawn R-3$/],
  ['outside row: duplicate id', { outside: ['| X-1 | DevOps | Deployment pipeline | E0-1 | — | — | — |', '| X-1 | QA | Test plan | E1-2 | — | — | — |'] }, /^duplicate outside id X-1$/],
  ['outside row: malformed id', { outside: ['| OPS-1 | DevOps | Deployment pipeline | E0-1 | — | — | — |'] }, /^outside OPS-1: id must match X-<n>$/],
  ['outside row: blank id on a filled row', { outside: ['| | DevOps | Deployment pipeline | E0-1 | — | — | — |'] }, /^outside row \(line \d+\): id must match X-<n>$/],
  ['outside section: renamed Needed by column', { outsideHeader: OUTSIDE_HEADER.replace('| Needed by |', '| Blocks |') }, /^Outside the dev backlog table \(line \d+\): missing column\(s\) `Needed by`/],
  ['outside section: heading with no table', { outside: [], outsideHeader: '- ask the platform team' }, /^Outside the dev backlog table not found/],
];

for (const [name, mutation, re] of ERROR_CASES) {
  test(`(2) error: ${name}`, () => {
    const res = check(shop(mutation));
    assert.ok(hasError(res, re), `expected ${re} in:\n${res.errors.join('\n')}`);
  });
}

test('(3) traces to a withdrawn id and to a superseded AD name the state / successor', () => {
  const rows = withRow('E2-2', '| E2-2 | E2 | Report export | story | M | 4 | E0-1 | COULD | — | FL-2.A1, R-3, AD-3 | TODO | — | — |');
  const res = check(project({ backlog: backlogMd({ rows }) }));
  assert.ok(hasError(res, /Task E2-2: traces withdrawn R-3/), res.errors.join('\n'));
  assert.ok(hasError(res, /Task E2-2: traces AD-3, superseded by AD-5 — trace AD-5 instead/), res.errors.join('\n'));
});

// --- scope register (ws-01)

const REGISTER_PRD = PRD.replace('# PRD — Shop\n', `# PRD — Shop
**Baseline:** v1.0 (2026-11-01) · **Approved by:** proposed · **Current:** v1.1 (2026-11-04)
`).replace('- **R-3** — (withdrawn) old export requirement', `- **R-3** — (withdrawn) old export requirement
- **R-4** — (superseded by R-5 per D-1) WHEN a user exports, the system shall send a PDF. Traces: G-1 · Added: v1.0
- **R-5** — WHEN a user exports, the system shall download a CSV. Traces: G-1 · Added: v1.1
- **R-6** — (withdrawn per D-1) WHEN a user filters, the system shall keep the filter. Traces: G-1 · Added: v1.0
- **R-7** — WHEN a user searches, the system shall rank results. Traces: G-1 · Source: scope.csv:R7 · Quote: "keep (superseded by R-9 per D-1) and (withdrawn) wording" · Added: v1.0`) + `
| ID | ISO 25010 characteristic | Requirement | Target | Measured by | Source | Added | Status |
|---|---|---|---|---|---|---|---|
| NFR-2 | Reliability | the audit view renders the literal label (withdrawn) | 99.9% | uptime probe | conversation | v1.1 | active |
| NFR-3 | Reliability | old uptime | 99% | uptime probe | conversation | v1.0 | superseded by NFR-2 per D-1 |

## Change log

### D-1 — 2026-11-04 — Export reworded
**Kind:** scope
`;

const registerRows = (e22Traces, { e21 = 'FL-2.A1, BR-1, R-5, R-7, NFR-2' } = {}) => withRow('E2-2', `| E2-2 | E2 | Report export | story | M | 4 | E0-1 | COULD | — | ${e22Traces} | TODO | — | — |`)
  .map((r) => (r.startsWith('| E2-1 |') ? `| E2-1 | E2 | Report view | story | H | 8 | E1-2 | MUST | reporting | ${e21} | TODO | — | — |` : r));
const checkRegister = (rows, { prd = REGISTER_PRD, header } = {}) => check(project({ prd, backlog: backlogMd({ rows, header }) }));

test('scope register: states from anchored markers and Status cells, D-n ids, Current version', () => {
  const inv = loadInventory(project({ prd: REGISTER_PRD }));
  assert.deepEqual(inv.ids.get('R-4'), { source: 'prd', state: 'superseded', successor: 'R-5', decision: 'D-1' });
  assert.equal(inv.ids.get('R-6').state, 'withdrawn');
  assert.equal(inv.ids.get('R-7').state, 'active', 'marker text inside Quote: is content, not state');
  assert.equal(inv.ids.get('NFR-2').state, 'active', 'an explicit Status wins over (withdrawn) in another cell');
  assert.deepEqual(inv.ids.get('NFR-3'), { source: 'prd', state: 'superseded', successor: 'NFR-2', decision: 'D-1' });
  assert.equal(inv.ids.get('D-1').state, 'active');
  assert.equal(inv.ids.get('R-3').state, 'withdrawn', 'legacy bare (withdrawn) still works');
  assert.equal(inv.scopeRev, 'v1.1');
  assert.deepEqual(inv.problems, []);
});

test('scope register: a superseded requirement trace warns; withdrawn errors; superseded AD still errors', () => {
  const res = checkRegister(registerRows('FL-2.A1, R-4, D-1'));
  assert.ok(res.warnings.some((w) => /^Task E2-2 traces R-4 \(superseded by R-5 per D-1\) — protected history or stale trace\?$/.test(w)), res.warnings.join('\n'));
  assert.ok(!hasError(res, /R-4/), res.errors.join('\n'));
  assert.ok(!hasError(res, /unknown trace D-1/), res.errors.join('\n'));
  assert.deepEqual(res.errors, []);
  const wd = checkRegister(registerRows('FL-2.A1, R-6, AD-3'));
  assert.ok(hasError(wd, /Task E2-2: traces withdrawn R-6/), wd.errors.join('\n'));
  assert.ok(hasError(wd, /Task E2-2: traces AD-3, superseded by AD-5 — trace AD-5 instead/), wd.errors.join('\n'));
});

test('scope register: coverage asks only for active ids — a quoted marker does not exempt R-7', () => {
  const res = checkRegister(registerRows('FL-2.A1', { e21: 'FL-2.A1, BR-1, R-5, NFR-2' }));
  assert.ok(hasError(res, /^R-7: no Task and no outside row traces it/), res.errors.join('\n'));
  assert.ok(!hasError(res, /^R-4: no Task/), res.errors.join('\n'));
  assert.ok(!hasError(res, /^NFR-3: no Task/), res.errors.join('\n'));
});

test('scope register: undefined and self successors are errors', () => {
  const prd = REGISTER_PRD.replace('### D-1', `- **R-8** — (superseded by R-99 per D-1) WHEN … Added: v1.0
- **R-9** — (superseded by R-9 per D-1) WHEN … Added: v1.0

### D-1`);
  const res = checkRegister(registerRows('FL-2.A1'), { prd });
  assert.ok(hasError(res, /^R-8: superseded by R-99, which is not defined$/), res.errors.join('\n'));
  assert.ok(hasError(res, /^R-9: superseded by itself$/), res.errors.join('\n'));
});

test('scope register: a malformed register Status is an error; an odd AD Status is not', () => {
  const typo = REGISTER_PRD.replace('superseded by NFR-2 per D-1 |', 'withdawn per D-1 |');
  assert.ok(hasError(checkRegister(registerRows('FL-2.A1'), { prd: typo }), /^NFR-3: malformed Status "withdawn per D-1"/));
  const junk = REGISTER_PRD.replace('superseded by NFR-2 per D-1 |', 'superseded by NFR-2oops |');
  assert.ok(hasError(checkRegister(registerRows('FL-2.A1'), { prd: junk }), /^NFR-3: malformed Status "superseded by NFR-2oops"/));
  const dir = project({ architecture: ARCHITECTURE.replace('| superseded by AD-5 |', '| retired |') });
  assert.deepEqual(loadInventory(dir).problems, []);
});

test('scope register: a legacy trailing (withdrawn) after a quote still withdraws; inside the quote it does not', () => {
  const discovery = DISCOVERY.replace('- **BR-1** — an order needs at least one line', '- **BR-1** — an order needs at least one line · Source: scope.csv:3 · Quote: "minimum one line" (withdrawn)\n- **BR-2** — keep · Quote: "this (withdrawn) word is quoted"');
  const inv = loadInventory(project({ discovery }));
  assert.equal(inv.ids.get('BR-1').state, 'withdrawn');
  assert.equal(inv.ids.get('BR-2').state, 'active');
});

test('scope register: Scope rev mismatch warns only when both sides carry a version', () => {
  const base = '**Date:** 2026-10-10 · **Source PRD:** `docs/PRD.md` · **Architecture:** `docs/architecture.md` · **Jira namespace:** `shop`';
  const rows = registerRows('FL-2.A1');
  const scopeWarn = (res) => res.warnings.filter((w) => /^backlog generated at scope/.test(w));
  assert.deepEqual(scopeWarn(checkRegister(rows, { header: `${base} · **Scope rev:** v1.0` })), ['backlog generated at scope v1.0, register is v1.1 — reconcile the backlog (/update-backlog)']);
  assert.deepEqual(scopeWarn(checkRegister(rows, { header: base })), []);
  assert.deepEqual(scopeWarn(check(project({ backlog: backlogMd({ header: `${base} · **Scope rev:** v1.0` }) }))), []);
});

// --- Relates / Chain (ws-02)

const WIDE_HEADER = TASK_HEADER.replace('| Depends on |', '| Depends on | Relates | Chain |').replace('|------------|', '|------------|---------|-------|');
const widen = (rows, cells = {}) => rows.map((r) => {
  const parts = r.split('|');
  const [rel, ch] = cells[parts[1].trim()] ?? ['—', '—'];
  parts.splice(8, 0, ` ${rel} `, ` ${ch} `);
  return parts.join('|');
});
const wide = (cells, rows = TASK_ROWS, extra = {}) => check(shop({ rows: widen(rows, cells), taskHeader: WIDE_HEADER, ...extra }));
const withdrawnE22 = withRow('E2-2', '| E2-2 | E2 | Report export (withdrawn) | story | M | 4 | E0-1 | COULD | — | FL-2.A1 | DONE | — | — |');

test('Relates/Chain: a table without the columns and one with both all — behave identically', () => {
  const narrow = backlogMd();
  const widened = backlogMd({ rows: widen(TASK_ROWS), taskHeader: WIDE_HEADER });
  const a = check(project({ backlog: narrow }));
  const b = check(project({ backlog: widened }));
  assert.deepEqual(b.errors, a.errors);
  assert.deepEqual(b.warnings, a.warnings);
  const flows = loadInventory(project()).flows;
  assert.equal(renderStoryMap(parseBacklog(widened).tasks, flows), renderStoryMap(parseBacklog(narrow).tasks, flows));
});

test('Relates: valid on one or both sides; self, unknown and Depends-on overlap are errors', () => {
  assert.deepEqual(wide({ 'E2-1': ['E2-2', '—'] }).errors, []);
  const both = wide({ 'E2-1': ['E2-2', '—'], 'E2-2': ['E2-1', '—'] });
  assert.deepEqual(both.errors, []);
  assert.ok(hasError(wide({ 'E2-1': ['E2-1', '—'] }), /^Task E2-1: Relates itself$/));
  assert.ok(hasError(wide({ 'E2-1': ['E9-9', '—'] }), /^Task E2-1: unknown Relates target E9-9$/));
  assert.ok(hasError(wide({ 'E1-3': ['E1-2', '—'] }), /^Tasks E1-2 and E1-3: both Depends on and Relates — one relation per pair$/));
  assert.ok(hasError(wide({ 'E1-2': ['E1-3', '—'] }), /^Tasks E1-2 and E1-3: both Depends on and Relates — one relation per pair$/));
});

test('Relates: a withdrawn endpoint warns exactly once however the pair is declared', () => {
  for (const cells of [{ 'E2-1': ['E2-2', '—'] }, { 'E2-2': ['E2-1', '—'] }, { 'E2-1': ['E2-2', '—'], 'E2-2': ['E2-1', '—'] }]) {
    const res = wide(cells, withdrawnE22);
    assert.deepEqual(res.warnings.filter((w) => /^Relates /.test(w)), ['Relates E2-1 ↔ E2-2: E2-2 is withdrawn'], JSON.stringify(cells));
  }
});

test('Chain: a linear chain is valid and ordered by Depends on', () => {
  const rows = withRow('E1-3', '| E1-3 | E1 | Confirmation email | story | M | 4 | E1-2 | MUST | orders | FL-1.A3, G-1 | TODO | — | — |');
  const reordered = [rows[0], rows[1], rows[2], rows[4], rows[3], rows[5], rows[6]];
  const res = wide({ 'E1-2': ['—', 'ord'], 'E1-3': ['—', 'ord'] }, reordered);
  assert.deepEqual(res.errors, []);
  const tasks = parseBacklog(backlogMd({ rows: widen(reordered, { 'E1-2': ['—', 'ord'], 'E1-3': ['—', 'ord'] }), taskHeader: WIDE_HEADER })).tasks;
  assert.deepEqual(chainPaths(tasks).get('ord').ids, ['E1-2', 'E1-3']);
});

test('Chain: spans of Epic or Node and non-linear paths are errors; malformed token is an error', () => {
  assert.ok(hasError(wide({ 'E1-3': ['—', 'x'], 'E2-1': ['—', 'x'] }), /^chain x: members span Epics E1, E2/));
  assert.ok(hasError(wide({ 'E1-2': ['—', 'x'], 'E1-3': ['—', 'x'] }), /^chain x: members span Nodes orders, email/));
  const twoHeads = withRow('E1-3', '| E1-3 | E1 | Confirmation email | story | M | 4 | E0-1 | MUST | orders | FL-1.A3, G-1 | TODO | — | — |');
  assert.ok(hasError(wide({ 'E1-2': ['—', 'x'], 'E1-3': ['—', 'x'] }, twoHeads), /^chain x: not one linear Depends on path \(2 heads\)/));
  assert.ok(hasError(wide({ 'E2-1': ['—', 'Ord_1'] }), /^Task E2-1: Chain Ord_1 must be a kebab token$/));
});

test('Chain: one head with a fork, a member with two inner deps and an unreachable member are each non-linear', () => {
  const row = (id, deps) => ({ id, epic: 'E9', node: 'n', deps, chain: 'c', withdrawn: false });
  const fork = chainPaths([row('E9-1', []), row('E9-2', ['E9-1']), row('E9-3', ['E9-1'])]).get('c');
  assert.match(fork.problems.join(';'), /not one linear Depends on path \(.*E9-1 is depended on by more than one member/);
  const join = chainPaths([row('E9-1', []), row('E9-2', ['E9-1']), row('E9-3', ['E9-1', 'E9-2'])]).get('c');
  assert.match(join.problems.join(';'), /E9-3 depends on more than one member/);
  const cut = chainPaths([row('E9-1', []), row('E9-2', ['E9-1']), row('E9-3', ['E9-4']), row('E9-4', ['E9-3'])]).get('c');
  assert.match(cut.problems.join(';'), /not one linear Depends on path \(path reaches 2 of 4 members\)/);
  assert.deepEqual(chainPaths([row('E9-1', []), row('E9-2', ['E9-1'])]).get('c').problems, []);
});

test('--chains prints the Depends-on order as JSON, whatever the table order', () => {
  const rows = withRow('E1-3', '| E1-3 | E1 | Confirmation email | story | M | 4 | E1-2 | MUST | orders | FL-1.A3, G-1 | TODO | — | — |');
  const reordered = [rows[0], rows[1], rows[2], rows[4], rows[3], rows[5], rows[6]];
  const dir = project({ backlog: backlogMd({ rows: widen(reordered, { 'E1-2': ['—', 'ord'], 'E1-3': ['—', 'ord'] }), taskHeader: WIDE_HEADER }) });
  const r = run(dir, '--chains');
  assert.equal(r.code, 0, r.out);
  assert.deepEqual(JSON.parse(r.out).chains.ord.ids, ['E1-2', 'E1-3']);
});

test('Chain: single member, long chains and withdrawn members warn; the path keeps a withdrawn member', () => {
  assert.ok(wide({ 'E2-1': ['—', 'solo'] }).warnings.includes('chain solo: single member'));
  const five = ['| E3-1 | E3 | S1 | tech | M | 4 | E0-1 | MUST | reporting | FL-2.A1 | TODO | — | — |', '| E3-2 | E3 | S2 | tech | M | 4 | E3-1 | MUST | reporting | FL-2.A1 | TODO | — | — |',
    '| E3-3 | E3 | S3 | tech | M | 4 | E3-2 | MUST | reporting | FL-2.A1 | TODO | — | — |', '| E3-4 | E3 | S4 | tech | M | 4 | E3-3 | MUST | reporting | FL-2.A1 | TODO | — | — |',
    '| E3-5 | E3 | S5 | tech | M | 4 | E3-4 | MUST | reporting | FL-2.A1 | TODO | — | — |'];
  const epics = ['| E0 | Foundation | a | b | 12 | — | — |', '| E1 | Ordering | a | b | 16 | E0 | — |', '| E2 | Reporting | a | b | 12 | E1 | — |', '| E3 | Steps | a | b | 20 | E0 | — |'];
  const cells = Object.fromEntries(['E3-1', 'E3-2', 'E3-3', 'E3-4', 'E3-5'].map((id) => [id, ['—', 'line']]));
  const acs = `${ACS}\n\n${['E3-1', 'E3-2', 'E3-3', 'E3-4', 'E3-5'].map((id) => `### ${id} — step\n- **${id}.AC1** — Given x When y Then z`).join('\n\n')}`;
  const res = wide(cells, [...TASK_ROWS, ...five], { epics, acs });
  assert.deepEqual(res.errors, []);
  assert.ok(res.warnings.includes('chain line: 5 members — consider one Task or a split'), res.warnings.join('\n'));
  const mid = five.map((r) => (r.startsWith('| E3-3 |') ? r.replace('| S3 |', '| S3 (withdrawn) |').replace('| TODO |', '| DONE |') : r));
  const tasks = parseBacklog(backlogMd({ rows: widen([...TASK_ROWS, ...mid], cells), taskHeader: WIDE_HEADER, epics })).tasks;
  assert.ok(wide(cells, [...TASK_ROWS, ...mid], { epics, acs }).warnings.includes('chain line: broken by withdrawal of E3-3'));
  assert.deepEqual(chainPaths(tasks).get('line').ids, ['E3-1', 'E3-2', 'E3-3', 'E3-4', 'E3-5']);
});

// --- writer helpers (ws-05)

const specFor = (status, acs) => `# Design: x\n\n**Date:** 2026-11-01\n**Status:** ${status}\n\n## Acceptance Criteria\n\n${acs}\n\n## Out of Scope\n- **E1-2.AC9** — not a criterion (outside the section)\n`;
const withSpec = (status, file = '.agents/specs/2026-11-02-place-order.md', acs = '- **E1-2.AC1** — Given a cart, When placed, Then confirmed.\n- **E1-2.AC2** — (withdrawn) superseded by E1-2.AC4\n- **E1-2.AC4** — Given an empty cart, When placed, Then rejected with a reason.', epic = {}) => {
  const rows = withRow('E1-2', `| E1-2 | E1 | Place order | story | H | 8 | E0-1 | MUST | orders | R-2, FL-1.A2, AD-5 | WIP | — | ${file} |`);
  const dir = shop({ rows, ...epic });
  fs.mkdirSync(path.join(dir, '.agents', 'specs'), { recursive: true });
  fs.writeFileSync(path.join(dir, file), specFor(status, acs));
  return dir;
};
const runJson = (dir, ...flags) => { const r = run(dir, ...flags); assert.equal(r.code, 0, r.out); return JSON.parse(r.out); };

test('--next-ids: an approved spec in Ref owns the current AC; nextAc spans every definition', () => {
  const out = runJson(withSpec('Approved'), '--next-ids');
  const t = out.tasks['E1-2'];
  assert.equal(t.source, '.agents/specs/2026-11-02-place-order.md');
  assert.deepEqual(t.current.map((a) => a.id), ['E1-2.AC1', 'E1-2.AC2', 'E1-2.AC4']);
  assert.equal(t.current[1].withdrawn, true);
  assert.equal(t.nextAc, 'E1-2.AC5', 'AC9 outside the section does not count');
  assert.deepEqual(out.next, { G: 'G-3', R: 'R-4', NFR: 'NFR-2', D: 'D-1', epic: 'E3' });
  assert.equal(out.taskNext.E1, 'E1-4');
});

test('--next-ids: a Draft spec does not own the current AC, but its ids still count for nextAc', () => {
  const t = runJson(withSpec('Draft'), '--next-ids').tasks['E1-2'];
  assert.equal(t.source, '.agents/backlog/E1-ordering.md');
  assert.deepEqual(t.current.map((a) => a.id), ['E1-2.AC1', 'E1-2.AC2']);
  assert.equal(t.nextAc, 'E1-2.AC5');
});

test('--next-ids: Task ids filter the output, unknown ids exit 2, continuation lines stay in the text', () => {
  const dir = withSpec('Approved', '.agents/specs/2026-11-02-place-order.md', '- **E1-2.AC1** — Given a cart,\n  When placed, Then confirmed.\n- **E1-2.AC4** — Given an empty cart, When placed, Then rejected.');
  const out = runJson(dir, '--next-ids', 'E1-2');
  assert.deepEqual(Object.keys(out.tasks), ['E1-2']);
  assert.equal(out.tasks['E1-2'].current[0].text, 'Given a cart, When placed, Then confirmed.');
  assert.equal(run(dir, '--next-ids', 'E9-9').code, 2);
  assert.equal(run(dir, 'E1-2').code, 2, 'positionals without --next-ids stay a usage error');
});

test('--candidate rejects a legacy backlog', () => {
  const dir = project();
  const cand = writeCandidate(dir, LEGACY_BACKLOG, []);
  assert.equal(run(dir, '--candidate', cand).code, 1);
});

test('--impact: tracing Tasks with protection reasons, transitive dependents, scopes, goals and cut lines', () => {
  const dir = withSpec('Approved');
  const { impact } = runJson(dir, '--impact', 'R-2,E0-1');
  const r2 = impact.find((x) => x.id === 'R-2');
  assert.deepEqual(r2.goals, ['G-1']);
  assert.deepEqual(r2.tasks.map((t) => [t.id, t.protected]), [['E1-2', ['status WIP', 'ref']]]);
  assert.deepEqual(r2.dependents.map((d) => d.id), ['E1-3', 'E2-1']);
  assert.deepEqual(r2.epics.map((e) => e.id), ['E1', 'E2'], 'Epics over Tasks and dependents');
  assert.deepEqual(r2.scopes, ['MUST']);
  assert.equal(r2.tasks[0].scope, 'MUST');
  assert.deepEqual(r2.outside, []);
  assert.deepEqual(r2.epics[0], { id: 'E1', cut: 'appetite: medium · cut first: E1-3' });
  const e01 = impact.find((x) => x.id === 'E0-1');
  assert.ok(e01.dependents.some((d) => d.id === 'E2-2') && e01.dependents.some((d) => d.id === 'E1-3'));
});

test('--candidate: validates a set outside the repo and rejects missing markers; the repo is never touched', () => {
  const dir = project();
  const repoEpic = readBacklogFiles(path.join(dir, '.agents', 'backlog.md')).epicFiles;
  const cand = writeCandidate(dir, backlogMd());
  assert.equal(run(dir, '--candidate', cand).code, 0);
  fs.writeFileSync(path.join(cand, 'backlog.md'), backlogMd({ markers: false }));
  const r = run(dir, '--candidate', cand);
  assert.equal(r.code, 1, r.out);
  assert.match(r.out, /candidate: .*markers? missing/);
  fs.writeFileSync(path.join(cand, 'backlog.md'), backlogMd({ rows: withRow('E2-2', '| E2-2 | E2 | Report export | story | M | 4 | E7-7 | COULD | — | FL-2.A1 | TODO | — | — |') }));
  assert.match(run(dir, '--candidate', cand).out, /unknown dependency E7-7/);
  assert.equal(fs.readFileSync(path.join(dir, '.agents', 'backlog.md'), 'utf8'), backlogMd(), 'the repo backlog is never touched');
  assert.deepEqual(readBacklogFiles(path.join(dir, '.agents', 'backlog.md')).epicFiles, repoEpic, 'nor its Epic files');
});

test('--candidate reads <dir>/backlog/E*.md: an error in a candidate Epic file exits 1, the repo files stay valid', () => {
  const dir = project();
  const cand = writeCandidate(dir, backlogMd(), epicFiles({ drop: ['E2-2'] }));
  const r = run(dir, '--candidate', cand);
  assert.equal(r.code, 1, r.out);
  assert.match(r.out, /error: Task E2-2: no `## E2-2 — …` block in the Epic file of E2/);
  assert.equal(run(dir).code, 0, 'the repo set is unaffected');
  const noEpicDir = writeCandidate(project(), backlogMd(), []);
  assert.match(run(path.dirname(path.dirname(noEpicDir)), '--candidate', noEpicDir).out, /Task E0-1: no `## E0-1 — …` block/, 'a candidate never falls back to the repo Epic files');
});

test('--candidate <dir> --write renders the candidate\'s own files; the repo files stay byte-identical', () => {
  const dir = project();
  const repoMd = fs.readFileSync(path.join(dir, '.agents', 'backlog.md'), 'utf8');
  const repoEpic = readBacklogFiles(path.join(dir, '.agents', 'backlog.md')).epicFiles;
  const cand = writeCandidate(dir, backlogMd());
  const r = run(dir, '--candidate', cand, '--write');
  assert.equal(r.code, 0, r.out);
  assert.match(r.out, /note: wrote the story map into \.agents\/\.pending-update\/backlog\.md and the meta lines of 3 Epic file\(s\)/);
  assert.match(fs.readFileSync(path.join(cand, 'backlog.md'), 'utf8'), /<!-- storymap:begin -->\n### FL-1 — Place order \(critical\)/);
  assert.match(fs.readFileSync(path.join(cand, 'backlog', 'E1-ordering.md'), 'utf8'), /^## E1-1 — Sign in\n> Size M \(4\) · Scope MUST · Depends on E0-2 · Traces R-1, FL-1\.A1\n\*\*Summary:\*\*/m);
  assert.equal(fs.readFileSync(path.join(dir, '.agents', 'backlog.md'), 'utf8'), repoMd);
  assert.deepEqual(readBacklogFiles(path.join(dir, '.agents', 'backlog.md')).epicFiles, repoEpic);
  const again = run(dir, '--candidate', cand, '--write');
  assert.match(again.out, /meta lines of 0 Epic file\(s\) \(unchanged\)/);
  const bad = writeCandidate(project(), backlogMd(), epicFiles({ drop: ['E2-2'] }));
  const before = fs.readFileSync(path.join(bad, 'backlog', 'E1-ordering.md'), 'utf8');
  const skipped = run(path.dirname(path.dirname(bad)), '--candidate', bad, '--write');
  assert.equal(skipped.code, 1);
  assert.match(skipped.out, /--write skipped/);
  assert.equal(fs.readFileSync(path.join(bad, 'backlog', 'E1-ordering.md'), 'utf8'), before);
});

test('(4) dependency cycle E1-1 → E1-2 → E1-1 is named', () => {
  const rows = withRow('E1-1', '| E1-1 | E1 | Sign in | story | M | 4 | E0-2, E1-2 | MUST | authn | R-1, FL-1.A1 | TODO | — | — |')
    .map((r) => (r.startsWith('| E1-2 |') ? '| E1-2 | E1 | Place order | story | H | 8 | E1-1 | MUST | orders | R-2, FL-1.A2, AD-5 | TODO | — | — |' : r));
  const res = check(project({ backlog: backlogMd({ rows }) }));
  assert.ok(hasError(res, /dependency cycle: E1-[12] → E1-[12] → E1-[12]/), res.errors.join('\n'));
});

test('(4a) a renamed `Depends on` header is a missing-column error, not an empty dependency list — the cycle cannot slip through', () => {
  const rows = withRow('E1-1', '| E1-1 | E1 | Sign in | story | M | 4 | E0-2, E1-2 | MUST | authn | R-1, FL-1.A1 | TODO | — | — |')
    .map((r) => (r.startsWith('| E1-2 |') ? '| E1-2 | E1 | Place order | story | H | 8 | E1-1 | MUST | orders | R-2, FL-1.A2, AD-5 | TODO | — | — |' : r));
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

test('a withdrawn Task keeps its ids but covers nothing and leaves the story map', () => {
  const rows = withRow('E1-3', '| E1-3 | E1 | Confirmation email (withdrawn) | story | M | 4 | E1-2 | MUST | email | FL-1.A3, G-1, R-3 | DONE | — | — |');
  const res = check(project({ backlog: backlogMd({ rows }) }));
  assert.ok(hasError(res, /FL-1\.A3 \(critical flow FL-1\): no CORE or MUST Task traces it/), res.errors.join('\n'));
  assert.ok(!hasError(res, /traces withdrawn R-3/), res.errors.join('\n'));
  assert.ok(hasError(res, /Task E1-3: unknown trace/) === false);
  const { tasks } = parseBacklog(backlogMd({ rows }));
  assert.equal(renderStoryMap(tasks, loadInventory(project()).flows).split('\n')[5], '| MUST | E1-1 | E1-2 | — |');
});

test('an NFR row whose Requirement starts with N/A keeps its id but is not mandatory coverage', () => {
  const prd = PRD.replace(
    /## 6\. Non-functional[\s\S]*$/,
    '## 6. Non-functional requirements\n| ID | ISO 25010 characteristic | Requirement | Target | Measured by |\n|---|---|---|---|---|\n| NFR-1 | Performance efficiency | N/A — single-user CLI, no latency budget | — | — |\n| NFR-2 | Security | secrets never logged | 0 findings | gitleaks |\n',
  );
  const rows = withRow('E0-2', '| E0-2 | E0 | Auth skeleton | tech | M | 4 | E0-1 | CORE | authn | AD-2, NFR-2 | TODO | — | — |');
  const dir = project({ prd, backlog: backlogMd({ rows }) });
  assert.equal(loadInventory(dir).ids.get('NFR-1').state, 'n/a');
  const res = check(dir);
  assert.deepEqual(res.errors, []);
  const untraced = check(project({ prd, backlog: backlogMd({ rows: withRow('E0-2', '| E0-2 | E0 | Auth skeleton | tech | M | 4 | E0-1 | CORE | authn | AD-2 | TODO | — | — |') }) }));
  assert.ok(hasError(untraced, /^NFR-2: no Task and no outside row traces it/), untraced.errors.join('\n'));
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

test('an AC defined outside a Task\'s ### Acceptance criteria is an error and does not count for its Task', () => {
  const moved = shop({ acs: ACS.replace('### E2-2 — Report export\n- **E2-2.AC1** — Given a report, when export is clicked, then a CSV downloads.', ''), extra: { E2: '### Notes\n- **E2-2.AC1** — Given a report, when export is clicked, then a CSV downloads.' } });
  const res = check(moved);
  assert.ok(hasError(res, /^E2-2\.AC1 defined outside a Task's ### Acceptance criteria \(E2-reporting\.md line \d+\)/), res.errors.join('\n'));
  assert.ok(hasError(res, /Task E2-2: no acceptance criterion/), res.errors.join('\n'));
  const noHeading = check(shop({ acs: ACS.replace('### E0-1 — Project scaffold\n', '') }));
  assert.ok(hasError(noHeading, /^E0-1\.AC1 defined outside a Task's ### Acceptance criteria \(E0-foundation\.md line 3\)/), noHeading.errors.join('\n'));
  assert.ok(hasError(noHeading, /Task E0-1: no acceptance criterion/), noHeading.errors.join('\n'));
  const beforeCriteria = check(shop({ files: (md) => epicFilesFor(md).map((f) => ({ ...f, text: f.text.replace('### Acceptance criteria\n- **E1-1.AC1**', '- **E1-1.AC1**') })) }));
  assert.ok(hasError(beforeCriteria, /^E1-1\.AC1 defined outside a Task's ### Acceptance criteria/), beforeCriteria.errors.join('\n'));
});

test('(4b) two different criteria both defined as E1-2.AC1 → error and exit 1', () => {
  const dir = shop({ acs: ACS.replace('- **E1-2.AC2**', '- **E1-2.AC1**') });
  const { code, out } = run(dir);
  assert.equal(code, 1);
  assert.match(out, /duplicate AC definition E1-2\.AC1/);
});

// ---------------------------------------------------------------------------------------------
// (5) Scope · (6)(7) warnings · (8) story map
// ---------------------------------------------------------------------------------------------

test('(5) SCOPES is the fixed order and parseBacklog reads a scope per Task', () => {
  assert.deepEqual(SCOPES, ['CORE', 'MUST', 'COULD']);
  const b = parseBacklog(backlogMd());
  assert.equal(b.preScope, false);
  assert.deepEqual(b.tasks.map((t) => t.scope), ['CORE', 'CORE', 'MUST', 'MUST', 'MUST', 'MUST', 'COULD']);
  assert.equal('wave' in b.tasks[0] || 'slice' in b.tasks[0], false);
  assert.deepEqual(b.outside, [{ id: 'X-1', owner: 'DevOps', item: 'Deployment pipeline', neededBy: ['E0-1'], startsAfter: [], traces: [], line: b.outside[0].line }]);
  assert.deepEqual(parseBacklog(backlogMd({ outside: null })).outside, [], 'the section is optional');
  assert.deepEqual(check(project({ backlog: backlogMd({ outside: null }) })).errors, []);
});

test('(5) a header with both Scope and a leftover Wave is not pre-Scope', () => {
  const header = TASK_HEADER.replace('| Depends on | Scope |', '| Depends on | Wave | Scope |').replace('|------------|', '|------------|------|');
  const rows = TASK_ROWS.map((r) => { const p = r.split('|'); p.splice(8, 0, ' 1 '); return p.join('|'); });
  const b = parseBacklog(backlogMd({ rows, taskHeader: header }));
  assert.equal(b.preScope, false);
  assert.deepEqual(check(project({ backlog: backlogMd({ rows, taskHeader: header }) })).errors, []);
});

test('(5) a withdrawn dependency or dependent raises no Scope-order error', () => {
  const rows = withRow('E2-2', '| E2-2 | E2 | Report export (withdrawn) | story | M | 4 | E0-1 | COULD | — | FL-2.A1 | DONE | — | — |')
    .map((r) => (r.startsWith('| E2-1 |') ? '| E2-1 | E2 | Report view | story | H | 8 | E2-2 | MUST | reporting | FL-2.A1, BR-1 | TODO | — | — |' : r));
  assert.ok(!hasError(check(project({ backlog: backlogMd({ rows }) })), /depends on E2-2/));
  const coreDep = withRow('E0-2', '| E0-2 | E0 | Auth skeleton (withdrawn) | tech | M | 4 | E1-2 | CORE | authn | AD-2, NFR-1 | DONE | — | — |');
  assert.ok(!hasError(check(project({ backlog: backlogMd({ rows: coreDep }) })), /CORE Task depends on/));
});

test('outside row: Starts after names the Tasks the item waits for; a later Task may need the item', () => {
  // The run starts after E1-2 and gates E2-1, which already depends on E1-2: no loop.
  const outside = ['| X-1 | QA | Regression run | E2-1 | E1-2, E0-2 | — | — |', '| X-2 | QA | Release sign-off | — | E1-3 | — | — |'];
  const md = backlogMd({ outside });
  assert.deepEqual(parseBacklog(md).outside.map((x) => [x.id, x.neededBy, x.startsAfter]), [['X-1', ['E2-1'], ['E1-2', 'E0-2']], ['X-2', [], ['E1-3']]]);
  assert.deepEqual(check(project({ backlog: md })).errors, []);
  // A withdrawn Task in either cell is a warning, and the wait graph does not run through it:
  // E1-3 depends on the withdrawn E1-2, so "needed by E0-1, starts after E1-3" is no loop.
  const withdrawnRows = withRow('E1-2', '| E1-2 | E1 | Place order (withdrawn) | story | H | 8 | E0-1 | MUST | orders | R-2, FL-1.A2, AD-5 | DONE | — | — |');
  const stale = check(project({ backlog: backlogMd({ rows: withdrawnRows, outside: ['| X-1 | QA | Regression run | E0-1, E1-2 | E1-3, E1-2 | R-2 | — |'] }) }));
  assert.equal(stale.errors.some((e) => /wait cycle/.test(e)), false, stale.errors.join('\n'));
  assert.ok(stale.warnings.includes('outside X-1: Needed by E1-2 is withdrawn — name the Task that replaces it, or drop the id'), stale.warnings.join('\n'));
  assert.ok(stale.warnings.includes('outside X-1: Starts after E1-2 is withdrawn — name the Task that replaces it, or drop the id'), stale.warnings.join('\n'));
  const renamed = check(project({ backlog: backlogMd({ outsideHeader: OUTSIDE_HEADER.replace('| Starts after |', '| After |') }) }));
  assert.ok(hasError(renamed, /^Outside the dev backlog table \(line \d+\): missing column\(s\) `Starts after`/), renamed.errors.join('\n'));
});

test('(6) coverage: a requirement traced only by an outside row passes and is reported as covered outside', () => {
  const rows = withRow('E1-1', '| E1-1 | E1 | Sign in | story | M | 4 | E0-2 | MUST | authn | FL-1.A1 | TODO | — | — |');
  const outside = ['| X-1 | DevOps | Session store provisioning | E1-1 | — | R-1 | — |'];
  const dir = project({ backlog: backlogMd({ rows, outside }) });
  const res = check(dir);
  assert.deepEqual(res.errors, []);
  assert.deepEqual(res.outsideCovered, ['R-1']);
  const r = run(dir);
  assert.equal(r.code, 0, r.out);
  assert.match(r.out, /^covered outside the dev backlog: R-1$/m);
  const none = check(project({ backlog: backlogMd({ rows }) }));
  assert.ok(hasError(none, /^R-1: no Task and no outside row traces it$/), none.errors.join('\n'));
  assert.deepEqual(check(project()).outsideCovered, [], 'an id a Task traces is not counted as outside-only');
});

test('(6) a superseded requirement traced by an outside row is an error, not a warning', () => {
  const outside = ['| X-1 | DevOps | Export service | E2-2 | — | R-4 | — |'];
  const res = check(project({ prd: REGISTER_PRD, backlog: backlogMd({ rows: registerRows('FL-2.A1'), outside }) }));
  assert.ok(hasError(res, /^outside X-1: traces superseded R-4$/), res.errors.join('\n'));
});

test('(7) warnings: no CORE Task; a CORE Task nothing outside CORE depends on', () => {
  const noCore = TASK_ROWS.map((r) => r.replace('| CORE |', '| MUST |'));
  const a = check(project({ backlog: backlogMd({ rows: noCore }) }));
  assert.deepEqual(a.errors, []);
  assert.ok(a.warnings.includes(NO_CORE_WARNING), a.warnings.join('\n'));
  const idle = withRow('E1-1', '| E1-1 | E1 | Sign in | story | M | 4 | E0-1 | MUST | authn | R-1, FL-1.A1 | TODO | — | — |');
  const b = check(project({ backlog: backlogMd({ rows: idle }) }));
  assert.deepEqual(b.errors, []);
  assert.ok(b.warnings.includes('Task E0-2: CORE, but nothing outside CORE depends on it — candidate to leave CORE'), b.warnings.join('\n'));
  assert.ok(!b.warnings.some((w) => /Task E0-1: CORE, but/.test(w)));
  assert.ok(!check(project()).warnings.some((w) => /CORE/.test(w)), 'the base fixture is clean');
  const onlyCore = TASK_ROWS.map((r) => r.replace(/\| (MUST|COULD) \|/, '| CORE |'));
  assert.ok(!check(project({ backlog: backlogMd({ rows: onlyCore }) })).warnings.some((w) => /candidate to leave CORE/.test(w)), 'skipped without non-CORE Tasks');
});

test('--impact: outside rows join the impact of a requirement, and an X-n id is a target', () => {
  const rows = withRow('E1-1', '| E1-1 | E1 | Sign in | story | M | 4 | E0-2 | MUST | authn | FL-1.A1 | TODO | — | — |');
  const outside = ['| X-1 | DevOps | Session store provisioning | E1-2 | — | R-1 | — |'];
  const dir = project({ backlog: backlogMd({ rows, outside }) });
  const { impact } = runJson(dir, '--impact', 'R-1,X-1,R-99');
  const r1 = impact.find((x) => x.id === 'R-1');
  assert.deepEqual(r1.outside, [{ id: 'X-1', owner: 'DevOps', neededBy: ['E1-2'], startsAfter: [] }]);
  assert.deepEqual(r1.tasks.map((t) => t.id), ['E1-2']);
  assert.deepEqual(r1.dependents.map((t) => t.id), ['E1-3', 'E2-1']);
  const x1 = impact.find((x) => x.id === 'X-1');
  assert.deepEqual(x1.tasks.map((t) => t.id), ['E1-2']);
  assert.deepEqual(x1.dependents.map((t) => t.id), ['E1-3', 'E2-1']);
  assert.deepEqual(x1.scopes, ['MUST']);
  const none = impact.find((x) => x.id === 'R-99');
  assert.deepEqual([none.tasks, none.dependents, none.outside, none.scopes], [[], [], [], []]);
  const parsed = parseBacklog(backlogMd({ rows, outside }));
  assert.deepEqual(impactOf(['X-1'], parsed, '')[0].outside.map((x) => x.id), ['X-1']);
  // A Task id lists the rows that name it in either cell, so a split or a withdrawal shows them.
  const both = parseBacklog(backlogMd({ rows, outside: [...outside, '| X-2 | QA | Regression run | — | E1-2, E1-3 | — | — |'] }));
  assert.deepEqual(impactOf(['E1-2', 'E1-3', 'E2-2'], both, '').map((i) => i.outside.map((x) => x.id)), [['X-1', 'X-2'], ['X-2'], []]);
});

test('pre-Scope backlog: parsed as preScope; every CLI mode exits 1 with the migration message', () => {
  assert.equal(parseBacklog(PRE_SCOPE_BACKLOG).preScope, true);
  assert.deepEqual(check(project({ backlog: PRE_SCOPE_BACKLOG })).errors, [PRE_SCOPE_MESSAGE]);
  const dir = project({ backlog: PRE_SCOPE_BACKLOG });
  for (const flags of [[], ['--next-ids'], ['--chains'], ['--impact', 'R-1'], ['--write']]) {
    const r = run(dir, ...flags);
    assert.equal(r.code, 1, `${flags.join(' ')}: ${r.out}`);
    assert.ok(r.out.includes(`backlog-check: ${PRE_SCOPE_MESSAGE}`), `${flags.join(' ')}: ${r.out}`);
  }
  const j = run(dir, '--json');
  assert.equal(j.code, 1);
  assert.deepEqual(JSON.parse(j.out), { errors: [PRE_SCOPE_MESSAGE], warnings: [], preScope: true });
  assert.equal(fs.readFileSync(path.join(dir, '.agents', 'backlog.md'), 'utf8'), PRE_SCOPE_BACKLOG, '--write touches nothing');
  const cand = path.join(dir, '.agents', '.pending-update');
  fs.mkdirSync(cand, { recursive: true });
  fs.writeFileSync(path.join(cand, 'PRD.md'), PRD);
  fs.writeFileSync(path.join(cand, 'backlog.md'), PRE_SCOPE_BACKLOG);
  assert.equal(run(dir, '--candidate', cand).code, 1);
});

test('other warnings: tech without trace, leaf without Task, XH story with >5 ACs', () => {
  const rows = withRow('E0-1', '| E0-1 | E0 | Project scaffold | tech | H | 8 | — | CORE | platform-core | — | TODO | — | — |')
    .map((r) => (r.startsWith('| E2-2 |') ? '| E2-2 | E2 | Report export | story | XH | 16 | E0-1 | COULD | — | FL-2.A1 | TODO | — | — |' : r));
  const epics = ['| E0 | Foundation | a | b | 12 | — | — |', '| E1 | Ordering | a | b | 16 | E0 | — |', '| E2 | Reporting | a | b | 24 | E1 | — |'];
  const acs = `${ACS}\n${[2, 3, 4, 5, 6].map((k) => `- **E2-2.AC${k}** — more`).join('\n')}`;
  const res = check(shop({ rows, epics, acs }));
  assert.deepEqual(res.errors, []);
  assert.ok(res.warnings.some((w) => /Task E0-1: tech Task with no trace/.test(w)));
  assert.ok(res.warnings.some((w) => /leaf reporting: no Task targets it/.test(w)) === false);
  assert.ok(res.warnings.some((w) => /Task E2-2: XH story with 6 criteria/.test(w)), res.warnings.join('\n'));
  const noReporting = check(project({ backlog: backlogMd({ rows: TASK_ROWS.map((r) => r.replace('| reporting |', '| — |')) }) }));
  assert.ok(noReporting.warnings.some((w) => /leaf reporting: no Task targets it/.test(w)), noReporting.warnings.join('\n'));
});

test('(8) renderStoryMap: critical flow first, activities as columns, Scopes as rows', () => {
  const { tasks } = parseBacklog(backlogMd());
  const md = renderStoryMap(tasks, loadInventory(project()).flows);
  const lines = md.split('\n');
  assert.equal(lines[0], '### FL-1 — Place order (critical)');
  assert.equal(lines[2], '| Scope | FL-1.A1 Sign in | FL-1.A2 Place order | FL-1.A3 Receive confirmation |');
  assert.deepEqual(lines.slice(4, 7), ['| CORE | — | — | — |', '| MUST | E1-1 | E1-2 | E1-3 |', '| COULD | — | — | — |']);
  assert.ok(lines.includes('### FL-2 — Reporting'));
  assert.ok(lines.includes('| MUST | E2-1 |'));
  assert.ok(lines.includes('| COULD | E2-2 |'));
  const noCould = renderStoryMap(tasks.filter((t) => t.scope !== 'COULD'), loadInventory(project()).flows);
  assert.ok(!/\| COULD \|/.test(noCould), 'only Scopes that occur among planned Tasks become rows');
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

test('--write with a duplicated or reversed storymap marker → exit 1 and the file is byte-for-byte unchanged', () => {
  const duplicated = backlogMd().replace('## External blockers', '<!-- storymap:begin -->\n## External blockers');
  const reversed = backlogMd().replace('<!-- storymap:begin -->\n(generated by backlog-check --write)\n<!-- storymap:end -->', '<!-- storymap:end -->\nx\n<!-- storymap:begin -->');
  for (const [name, backlog, re] of [['duplicated', duplicated, /marker <!-- storymap:begin --> appears 2 times/], ['reversed', reversed, /<!-- storymap:end --> appears before/]]) {
    const dir = project({ backlog });
    const r = run(dir, '--write');
    assert.equal(r.code, 1, `${name}: ${r.out}`);
    assert.match(r.out, re, name);
    assert.doesNotMatch(r.out, /note: wrote/, name);
    assert.equal(fs.readFileSync(path.join(dir, '.agents', 'backlog.md'), 'utf8'), backlog, name);
  }
});

test('--write ignores a hand-kept lanes block in a Scope backlog', () => {
  const kept = backlogMd().replace('## External blockers', '## Parallel plan\n<!-- lanes:begin -->\nold lanes\n<!-- lanes:end -->\n\n## External blockers');
  const dir = project({ backlog: kept });
  const r = run(dir, '--write');
  assert.equal(r.code, 0, r.out);
  assert.match(fs.readFileSync(path.join(dir, '.agents', 'backlog.md'), 'utf8'), /<!-- lanes:begin -->\nold lanes\n<!-- lanes:end -->/);
});

// ---------------------------------------------------------------------------------------------
// (9)–(13) CLI behaviour
// ---------------------------------------------------------------------------------------------

test('(9) --write changes only the storymap region and is idempotent', () => {
  const dir = project();
  const before = fs.readFileSync(path.join(dir, '.agents', 'backlog.md'), 'utf8');
  const first = run(dir, '--write');
  assert.equal(first.code, 0, first.out);
  assert.match(first.out, /note: wrote the story map into \.agents\/backlog\.md/);
  const after = fs.readFileSync(path.join(dir, '.agents', 'backlog.md'), 'utf8');
  const strip = (s) => s.replace(/<!-- storymap:begin -->[\s\S]*?<!-- storymap:end -->/g, '<!-- storymap -->');
  assert.equal(strip(after), strip(before));
  assert.match(after, /<!-- storymap:begin -->\n### FL-1 — Place order \(critical\)/);
  const second = run(dir, '--write');
  assert.equal(second.code, 0);
  assert.equal(fs.readFileSync(path.join(dir, '.agents', 'backlog.md'), 'utf8'), after);
});

test('--write with missing markers reports "markers missing" and exits 1; with errors it is skipped', () => {
  const noMarkers = run(project({ backlog: backlogMd({ markers: false }) }), '--write');
  assert.equal(noMarkers.code, 1);
  assert.match(noMarkers.out, /markers missing/);
  const dir = shop({ acs: ACS.replace('- **E2-2.AC1**', '- **E2-2.ACa**') });
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
  assert.equal('lanes' in JSON.parse(j.out), false);
});

test('(11) no system.yaml → Node checks skipped, everything else runs', () => {
  const rows = withRow('E2-2', '| E2-2 | E2 | Report export | story | M | 4 | E0-1 | COULD | anything | FL-2.A1 | TODO | — | — |');
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
  assert.match(r.out, /R-7: no Task and no outside row traces it/);
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
  assert.equal(run(shop({ acs: ACS.replace('- **E2-2.AC1**', '- **E2-2.ACa**') })).code, 1);
  const empty = fs.mkdtempSync(path.join(os.tmpdir(), 'backlog-check-empty-'));
  const r = run(empty);
  assert.equal(r.code, 2);
  assert.match(r.out, /backlog\.md not found/);
  assert.equal(run(project(), 'stray-positional').code, 2);
  assert.equal(run(project(), '--bogus').code, 2);
  assert.equal(run(project(), '--prd', '--write').code, 2);
  assert.equal(run(project(), '--write', '--json').code, 0);
  const j = JSON.parse(run(project(), '--json').out);
  assert.deepEqual(Object.keys(j), ['errors', 'warnings', 'notes', 'outsideCovered']);
  assert.deepEqual(j.errors, []);
  assert.deepEqual(j.outsideCovered, []);
  const rows = withRow('E1-1', '| E1-1 | E1 | Sign in | story | M | 4 | E0-2 | MUST | authn | FL-1.A1 | TODO | — | — |');
  const covered = run(project({ backlog: backlogMd({ rows, outside: ['| X-1 | DevOps | Session store provisioning | E1-1 | — | R-1 | — |'] }) }), '--json');
  assert.equal(covered.code, 0, covered.out);
  assert.deepEqual(JSON.parse(covered.out).outsideCovered, ['R-1']);
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

// ---------------------------------------------------------------------------------------------
// Epic files (stage C): Detail modes, pre-detail, resolver, fingerprint, meta lines, loader, slug
// ---------------------------------------------------------------------------------------------

const ALL_IDS = ['E0-1', 'E0-2', 'E1-1', 'E1-2', 'E1-3', 'E2-1', 'E2-2'];

test('check(dir, backlog): another backlog text re-derives its Epic files; explicit epicFiles win', () => {
  const dir = project();
  const extraTask = backlogMd({ rows: [...TASK_ROWS, '| E2-3 | E2 | Report filter | story | M | 4 | E2-1 | COULD | — | FL-2.A1 | TODO | — | — |'], epics: ['| E0 | Foundation | a | b | 12 | — | — |', '| E1 | Ordering | a | b | 16 | E0 | — |', '| E2 | Reporting | a | b | 16 | E1 | — |'] });
  const derived = check(dir, extraTask);
  assert.ok(!hasError(derived, /block in the Epic file/), derived.errors.join('\n'));
  assert.ok(hasError(derived, /^Task E2-3: no acceptance criterion/), 'the derived block has no criterion for the new Task');
  const explicit = check(dir, extraTask, { epicFiles: epicFilesFor(backlogMd()) });
  assert.ok(hasError(explicit, /^Task E2-3: no `## E2-3 — …` block/), explicit.errors.join('\n'));
});

test('Detail: structure — a Summary without criteria passes; neither fails; a misplaced criterion still fails', () => {
  const noE22 = ACS.replace(/### E2-2 — Report export\n- \*\*E2-2\.AC1\*\*[^\n]*/, '');
  assert.deepEqual(check(shop({ detail: 'structure', acs: noE22, plain: ALL_IDS })).errors, []);
  const summaryOnly = check(shop({ detail: 'structure', acs: '', plain: ALL_IDS }));
  assert.deepEqual(summaryOnly.errors, [], 'a structure-only backlog: Summary lines, no criteria at all');
  assert.ok(!summaryOnly.warnings.some((w) => /without Goal/.test(w)), 'no detail warning under structure');
  const neither = check(shop({ detail: 'structure', acs: noE22, noSummary: ['E2-2'] }));
  assert.deepEqual(neither.errors, ['Task E2-2: no **Summary:** line (.agents/backlog/E2-reporting.md)']);
  assert.deepEqual(check(shop({ detail: 'structure', acs: ACS, noSummary: ['E2-2'] })).errors, [], 'a criterion stands in for the Summary');
  const wrong = check(shop({ detail: 'structure', acs: ACS.replace('- **E2-2.AC1**', '- **E2-1.AC2**') }));
  assert.ok(hasError(wrong, /^AC E2-1\.AC2 defined under ## E2-2 — expected ## E2-1/), wrong.errors.join('\n'));
  const missingHeading = check(shop({ detail: 'structure', drop: ['E2-2'] }));
  assert.ok(hasError(missingHeading, /^Task E2-2: no `## E2-2 — …` block/), 'a heading is required in every mode');
});

test('Detail: full — one aggregated warning names the Tasks without Goal / In scope / Out of scope', () => {
  const res = check(shop({ plain: ['E0-1', 'E0-2', 'E1-1', 'E1-2', 'E1-3', 'E2-1'] }));
  assert.deepEqual(res.errors, []);
  assert.deepEqual(res.warnings.filter((w) => /without Goal/.test(w)), ['6 Task(s) without Goal / In scope / Out of scope (E0-1, E0-2, E1-1, E1-2, E1-3, +1) — /setup:delivery-plan details them']);
  const two = check(shop({ plain: ['E1-2', 'E2-2'] }));
  assert.deepEqual(two.warnings.filter((w) => /without Goal/.test(w)), ['2 Task(s) without Goal / In scope / Out of scope (E1-2, E2-2) — /setup:delivery-plan details them']);
  const partial = check(shop({ files: (md) => epicFilesFor(md).map((f) => ({ ...f, text: f.text.replace('**Out of scope:** admin tooling.\n### Acceptance criteria\n- **E2-2', '### Acceptance criteria\n- **E2-2') })) }));
  assert.deepEqual(partial.warnings.filter((w) => /without Goal/.test(w)), ['1 Task(s) without Goal / In scope / Out of scope (E2-2) — /setup:delivery-plan details them']);
  assert.ok(!check(project()).warnings.some((w) => /without Goal/.test(w)), 'the base fixture is fully detailed');
});

test('withdrawn Task: needs neither a heading nor a criterion; what it still carries is validated', () => {
  const rows = withRow('E2-2', '| E2-2 | E2 | Report export (withdrawn) | story | M | 4 | E0-1 | COULD | — | FL-2.A1 | DONE | — | — |');
  const noE22 = ACS.replace(/### E2-2 — Report export\n- \*\*E2-2\.AC1\*\*[^\n]*/, '');
  assert.deepEqual(check(shop({ rows, drop: ['E2-2'], acs: noE22 })).errors, []);
  assert.deepEqual(check(shop({ rows, acs: noE22, noSummary: ['E2-2'], plain: ['E2-2'] })).errors, [], 'an empty block is fine too');
  assert.ok(!check(shop({ rows, acs: noE22, plain: ['E2-2'] })).warnings.some((w) => /without Goal/.test(w)), 'not counted as undetailed');
  const misplaced = check(shop({ rows, acs: ACS.replace('- **E2-2.AC1**', '- **E2-1.AC2**') }));
  assert.ok(hasError(misplaced, /^AC E2-1\.AC2 defined under ## E2-2 — expected ## E2-1/), misplaced.errors.join('\n'));
  const wrongFile = check(shop({ rows, drop: ['E2-2'], extra: { E1: '## E2-2 — Report export\n**Summary:** x' } }));
  assert.ok(hasError(wrongFile, /^E1-ordering\.md: Task E2-2 belongs to Epic E2$/), wrongFile.errors.join('\n'));
});

test('Detail: full — a Task whose approved spec in Ref owns its criteria passes without an Epic-file criterion (CLI)', () => {
  const noE12 = ACS.replace(/### E1-2 — Place order\n(- \*\*E1-2[^\n]*\n?)+/, '');
  const owned = withSpec('Approved', undefined, undefined, { acs: noE12 });
  const ok = run(owned);
  assert.equal(ok.code, 0, ok.out);
  assert.deepEqual(check(owned).errors, []);
  const expected = 'error: Task E1-2: no acceptance criterion (expected - **E1-2.AC1** — … in .agents/backlog/E1-ordering.md, or an approved spec in Ref)';
  const draft = run(withSpec('Draft', undefined, undefined, { acs: noE12 }));
  assert.equal(draft.code, 1, 'a Draft spec exempts nothing');
  assert.ok(draft.out.includes(expected), draft.out);
  const other = run(withSpec('Approved', undefined, '- **E1-1.AC9** — Given x, When y, Then z.', { acs: noE12 }));
  assert.equal(other.code, 1, 'an approved spec without a criterion for the Task exempts nothing');
  assert.ok(other.out.includes(expected), other.out);
  const allWithdrawn = run(withSpec('Approved', undefined, '- **E1-2.AC1** — (withdrawn) gone', { acs: noE12 }));
  assert.equal(allWithdrawn.code, 1, 'only withdrawn criteria count as none');
  const gone = withSpec('Approved', undefined, undefined, { acs: noE12 });
  fs.rmSync(path.join(gone, '.agents/specs/2026-11-02-place-order.md'));
  const missing = run(gone);
  assert.equal(missing.code, 1, 'a Ref naming a missing spec file exempts nothing');
  assert.ok(missing.out.includes(expected), missing.out);
  const plain = run(shop({ acs: noE12 }));
  assert.equal(plain.code, 1);
  assert.ok(plain.out.includes(expected), plain.out);
  const rows = withRow('E1-2', '| E1-2 | E1 | Place order | story | H | 8 | E0-1 | MUST | orders | R-2, FL-1.A2, AD-5 | WIP | — | .agents/specs/2026-11-09-none.md |');
  assert.ok(hasError(check(shop({ rows, acs: noE12 })), /^Task E1-2: no acceptance criterion/), 'a spec path in Ref alone is no exemption');
  assert.deepEqual(checkBacklog({ backlog: parseBacklog(backlogMd(), { epicFiles: epicFiles({ acs: noE12 }) }), inventory: loadInventory(project()), system: loadSystem(project()) }).errors.filter((e) => /no acceptance criterion/.test(e)), [], 'the pure checkBacklog leaves this rule to checkAgainstRoot');
});

test('pre-detail backlog: parsed as preDetail; plain, --json, --next-ids and the other modes exit 1 with the migration message', () => {
  const b = parseBacklog(PRE_DETAIL_BACKLOG);
  assert.equal(b.preDetail, true);
  assert.deepEqual([b.tasks.length, b.acs.length, b.preScope], [0, 0, false]);
  assert.equal(parseBacklog(PRE_SCOPE_BACKLOG).preScope, true, 'pre-Scope wins over pre-detail');
  assert.deepEqual(checkBacklog({ backlog: b }).errors, [PRE_DETAIL_MESSAGE]);
  assert.equal(checkBacklog({ backlog: b }).preDetail, true);
  const dir = project({ backlog: PRE_DETAIL_BACKLOG, epicFiles: [] });
  for (const flags of [[], ['--next-ids'], ['--next-ids', 'E1-1'], ['--chains'], ['--impact', 'R-1'], ['--write']]) {
    const r = run(dir, ...flags);
    assert.equal(r.code, 1, `${flags.join(' ')}: ${r.out}`);
    assert.ok(r.out.includes(`backlog-check: ${PRE_DETAIL_MESSAGE}`), `${flags.join(' ')}: ${r.out}`);
  }
  const j = run(dir, '--json');
  assert.equal(j.code, 1);
  assert.deepEqual(JSON.parse(j.out), { errors: [PRE_DETAIL_MESSAGE], warnings: [], preDetail: true });
  assert.equal(fs.readFileSync(path.join(dir, '.agents', 'backlog.md'), 'utf8'), PRE_DETAIL_BACKLOG, '--write touches nothing');
  assert.equal(run(dir, '--candidate', writeCandidate(dir, PRE_DETAIL_BACKLOG, [])).code, 1);
});

test('--next-ids: the Epic file is the criteria source, with the Summary line', () => {
  const t = runJson(project(), '--next-ids', 'E1-1').tasks['E1-1'];
  assert.equal(t.source, '.agents/backlog/E1-ordering.md');
  assert.equal(t.summary, 'Sign in for the shop.');
  assert.deepEqual(t.current.map((a) => a.id), ['E1-1.AC1', 'E1-1.AC2']);
  assert.equal(t.nextAc, 'E1-1.AC3');
  assert.deepEqual(Object.keys(t), ['current', 'source', 'nextAc', 'summary', 'missing']);
  const owned = runJson(withSpec('Approved'), '--next-ids', 'E1-2').tasks['E1-2'];
  assert.equal(owned.source, '.agents/specs/2026-11-02-place-order.md', 'an approved spec still owns the criteria');
  assert.equal(owned.summary, 'Place order for the shop.');
});

test('--next-ids: missing for a detailed Task, a Summary-only Task and a Task an approved spec owns', () => {
  const detailed = runJson(project(), '--next-ids', 'E1-1').tasks['E1-1'];
  assert.deepEqual(detailed.missing, []);
  const md = backlogMd({ detail: 'structure' });
  const summaryOnly = runJson(project({ backlog: md, epicFiles: epicFilesFor(md, { acs: '', plain: ALL_IDS }) }), '--next-ids', 'E1-1').tasks['E1-1'];
  assert.deepEqual(summaryOnly.missing, ['goal', 'inScope', 'outOfScope', 'criteria']);
  assert.equal(summaryOnly.source, '.agents/backlog/E1-ordering.md');
  assert.deepEqual(summaryOnly.current, []);
  const noE12 = ACS.replace(/### E1-2 — Place order\n(- \*\*E1-2[^\n]*\n?)+/, '');
  const owned = runJson(withSpec('Approved', undefined, undefined, { acs: noE12, plain: ['E1-2'] }), '--next-ids', 'E1-2').tasks['E1-2'];
  assert.deepEqual(owned.missing, ['goal', 'inScope', 'outOfScope'], 'criteria resolved from the spec');
  const withdrawnOnly = runJson(withSpec('Approved', undefined, '- **E1-2.AC1** — (withdrawn) gone'), '--next-ids', 'E1-2').tasks['E1-2'];
  assert.ok(withdrawnOnly.missing.includes('criteria'), 'only withdrawn criteria count as none');
  const noBlock = runJson(project({ backlog: md, epicFiles: epicFilesFor(md, { drop: ['E2-2'] }) }), '--next-ids', 'E2-2');
  assert.equal(noBlock.tasks['E2-2'].source, '.agents/backlog/E2-reporting.md', 'no block → the Epic file the block belongs in');
  assert.equal(noBlock.tasks['E2-2'].summary, '');
});

test('--fingerprint: stable, covers the Epic files, ignores **Last check:**, refused with --candidate', () => {
  const dir = project();
  const a = run(dir, '--fingerprint');
  assert.equal(a.code, 0, a.out);
  assert.match(a.out, /^[0-9a-f]{12}\n$/);
  assert.equal(run(dir, '--fingerprint').out, a.out);
  const { md, epicFiles: files } = readBacklogFiles(path.join(dir, '.agents', 'backlog.md'));
  assert.equal(a.out.trim(), backlogFingerprint(md, files));
  assert.equal(backlogFingerprint(md, [...files].reverse()), backlogFingerprint(md, files), 'order-independent input');
  const backlogPath = path.join(dir, '.agents', 'backlog.md');
  fs.writeFileSync(backlogPath, md.replace('## Epic map', '**Last check:** 2026-11-21 · critic ship\n\n## Epic map'));
  assert.notEqual(run(dir, '--fingerprint').out, a.out, 'a blank line is content');
  fs.writeFileSync(backlogPath, md.replace('## Epic map', '**Last check:** 2026-11-21 · critic ship\n## Epic map'));
  assert.equal(run(dir, '--fingerprint').out, a.out, 'the **Last check:** line is ignored');
  const epicPath = path.join(dir, EPIC_DIR, 'E2-reporting.md');
  fs.appendFileSync(epicPath, '- **E2-2.AC2** — Given x When y Then z\n');
  assert.notEqual(run(dir, '--fingerprint').out, a.out, 'an Epic-file change changes the fingerprint');
  const delivery = path.join(dir, EPIC_DIR, 'delivery-plan.md');
  const before = run(dir, '--fingerprint').out;
  fs.writeFileSync(delivery, '# Delivery plan\n');
  assert.equal(run(dir, '--fingerprint').out, before, 'delivery-plan.md is not part of the set');
  const refused = run(dir, '--fingerprint', '--candidate', writeCandidate(dir, backlogMd()));
  assert.equal(refused.code, 2);
  assert.match(refused.out, /--fingerprint is refused with --candidate/);
  assert.equal(run(project({ backlog: PRE_SCOPE_BACKLOG }), '--fingerprint').code, 0, 'any backlog generation');
  assert.equal(run(project({ backlog: PRE_DETAIL_BACKLOG, epicFiles: [] }), '--fingerprint').code, 0);
  assert.equal(backlogFingerprint('a\n**Last check:** x\n', []), backlogFingerprint('a\n', []));
  assert.equal(backlogFingerprint('a', []), backlogFingerprint('a\n', []), 'trailing newline handling of the old backlog hash');
});

test('--write: inserts a missing meta line, replaces a stale one, keeps CRLF, and a second run is a no-op', () => {
  const md = backlogMd();
  const files = epicFilesFor(md).map((f) => (f.name === 'E1-ordering.md'
    ? { ...f, text: f.text.replace('## E1-2 — Place order\n', '## E1-2 — Place order\n> Size M (4) · stale\n\n> Withdrawn · Size H (8) · second stale line\n') }
    : f.name === 'E2-reporting.md' ? { ...f, text: f.text.replace(/\n/g, '\r\n') } : f));
  const dir = project({ backlog: md, epicFiles: files });
  const first = run(dir, '--write');
  assert.equal(first.code, 0, first.out);
  assert.match(first.out, /note: wrote the story map into \.agents\/backlog\.md and the meta lines of 3 Epic file\(s\)$/m);
  const read = (name) => fs.readFileSync(path.join(dir, EPIC_DIR, name), 'utf8');
  assert.match(read('E0-foundation.md'), /^## E0-1 — Project scaffold\n> Size H \(8\) · Scope CORE · Depends on — · Traces AD-1\n\*\*Summary:\*\*/m);
  const e1 = read('E1-ordering.md');
  assert.match(e1, /^## E1-2 — Place order\n> Size H \(8\) · Scope MUST · Depends on E0-1 · Traces R-2, FL-1\.A2, AD-5\n\*\*Summary:\*\*/m);
  assert.doesNotMatch(e1, /stale/);
  const e2 = read('E2-reporting.md');
  assert.match(e2, /## E2-2 — Report export\r\n> Size M \(4\) · Scope COULD · Depends on E0-1 · Traces FL-2\.A1\r\n/);
  assert.equal(e2.replace(/\r\n/g, '').includes('\n'), false, 'CRLF kept, no bare LF');
  const snapshot = ['E0-foundation.md', 'E1-ordering.md', 'E2-reporting.md'].map(read);
  const backlogAfter = fs.readFileSync(path.join(dir, '.agents', 'backlog.md'), 'utf8');
  const second = run(dir, '--write');
  assert.equal(second.code, 0, second.out);
  assert.match(second.out, /meta lines of 0 Epic file\(s\) \(unchanged\)/);
  assert.deepEqual(['E0-foundation.md', 'E1-ordering.md', 'E2-reporting.md'].map(read), snapshot);
  assert.equal(fs.readFileSync(path.join(dir, '.agents', 'backlog.md'), 'utf8'), backlogAfter);
  const parsed = parseBacklog(backlogAfter, { epicFiles: readBacklogFiles(path.join(dir, '.agents', 'backlog.md')).epicFiles });
  assert.equal(parsed.details.get('E1-2').summary, 'Place order for the shop.', 'the meta line is not part of the Summary');
});

test('--write with errors in an Epic file writes nothing', () => {
  const md = backlogMd();
  const dir = project({ backlog: md, epicFiles: epicFilesFor(md, { drop: ['E2-2'] }) });
  const before = readBacklogFiles(path.join(dir, '.agents', 'backlog.md'));
  const r = run(dir, '--write');
  assert.equal(r.code, 1);
  assert.match(r.out, /--write skipped/);
  assert.deepEqual(readBacklogFiles(path.join(dir, '.agents', 'backlog.md')), before);
});

test('renderMeta and renderEpicFile: table-derived line, withdrawn prefix, unknown headings untouched', () => {
  const { tasks } = parseBacklog(backlogMd());
  assert.equal(renderMeta(tasks[2]), '> Size M (4) · Scope MUST · Depends on E0-2 · Traces R-1, FL-1.A1');
  assert.equal(renderMeta({ ...tasks[6], withdrawn: true }), '> Withdrawn · Size M (4) · Scope COULD · Depends on E0-1 · Traces FL-2.A1');
  assert.equal(renderMeta({ ...tasks[0], deps: [], traces: [] }), '> Size H (8) · Scope CORE · Depends on — · Traces —');
  const text = '# E1 — Ordering\n\n## E1-1 — Sign in\n**Summary:** x\n\n## E1-9 — Unknown\n> keep\n';
  assert.equal(renderEpicFile(text, { tasks }), '# E1 — Ordering\n\n## E1-1 — Sign in\n> Size M (4) · Scope MUST · Depends on E0-2 · Traces R-1, FL-1.A1\n**Summary:** x\n\n## E1-9 — Unknown\n> keep\n');
  assert.equal(renderEpicFile(renderEpicFile(text, { tasks }), { tasks }), renderEpicFile(text, { tasks }));
});

test('fenceScanner: a fence closes only on the same character, at least as long, with nothing after it', () => {
  const scan = fenceScanner();
  const lines = ['text', '````md', '```', '```` x', '````', 'after', '~~~', '```', '~~~~', 'out', '```js', 'in'];
  assert.deepEqual(lines.map((l) => scan(l)), [false, true, true, true, true, false, true, true, true, false, true, true]);
  assert.equal(scan.openedAt(), 11, 'the open fence and the line that opened it');
  const indented = fenceScanner();
  assert.deepEqual(['   ```', 'x', '    ```', '```'].map((l) => indented(l)), [true, true, true, true]);
  assert.equal(indented.openedAt(), null);
  assert.equal(fenceScanner()('``` a`b'), false, 'a backtick info string with a backtick is no fence');
});

test('a fence holding a shorter or other-character fence line does not hide the criteria after it', () => {
  for (const [name, open, inner] of [['four backticks', '````md', '```'], ['tildes', '~~~', '```']]) {
    const sample = [
      '- **E0-1.AC1** — Given a clean clone, when `npm test` runs, then it passes:',
      `  ${open}`, `  ${inner}`, `  ${open.replace(/md$/, '')}`,
      '- **E0-1.AC2** — Given a second clone, when it builds, then it passes.',
    ].join('\n');
    const dir = shop({ acs: ACS.replace('- **E0-1.AC1** — Given a clean clone, when `npm test` runs, then it passes.', sample) });
    assert.deepEqual(check(dir).errors, [], name);
    const t = runJson(dir, '--next-ids', 'E0-1').tasks['E0-1'];
    assert.deepEqual(t.current.map((a) => a.id), ['E0-1.AC1', 'E0-1.AC2'], name);
    assert.equal(t.nextAc, 'E0-1.AC3', name);
  }
});

test('an unclosed code fence in an Epic file is a problem naming the line that opened it', () => {
  const files = epicFiles({ extra: { E2: '```sh\n# never closed\n- **E2-2.AC2** — hidden' } });
  const text = files.find((f) => f.name === 'E2-reporting.md').text;
  const at = text.split('\n').indexOf('```sh') + 1;
  const b = parseBacklog(backlogMd(), { epicFiles: files });
  assert.deepEqual(b.problems, [`Epic file E2-reporting.md: unclosed code fence opened on line ${at}`]);
});

test('a criterion definition left in backlog.md is an error with its line, and nextAc skips its id; one in a fenced example is not', () => {
  const md = backlogMd().replace('## Open questions\n- none', '## Open questions\n- **E2-2.AC99** — Given x, when y, then z.\n- **E9-1.AC1** — Given a ghost.');
  const lines = md.split('\n');
  const at = (id) => lines.findIndex((l) => l.includes(`**${id}**`)) + 1;
  const dir = project({ backlog: md });
  const errors = check(dir).errors;
  assert.ok(errors.includes(`E2-2.AC99 defined in .agents/backlog.md (line ${at('E2-2.AC99')}) — criteria live in the Task's block of its Epic file (.agents/backlog/E2-reporting.md)`), errors.join('\n'));
  assert.ok(errors.includes(`E9-1.AC1 defined in .agents/backlog.md (line ${at('E9-1.AC1')}) — criteria live in the Task's block of its Epic file (.agents/backlog/E<n>-<slug>.md)`), errors.join('\n'));
  const t = runJson(dir, '--next-ids', 'E2-2').tasks['E2-2'];
  assert.deepEqual(t.current.map((a) => a.id), ['E2-2.AC1'], 'a stray definition is no current criterion');
  assert.equal(t.nextAc, 'E2-2.AC100', 'the stray id is never re-issued');
  const fenced = backlogMd().replace('## Open questions\n- none', '## Open questions\n```md\n- **E2-2.AC99** — an example\n```');
  assert.deepEqual(check(project({ backlog: fenced })).errors, []);
});

test('renderEpicFile: a stale meta line after a blank line is replaced directly under the heading; a non-generated > note stays; idempotent', () => {
  const { tasks } = parseBacklog(backlogMd());
  const fresh = '> Size M (4) · Scope MUST · Depends on E0-2 · Traces R-1, FL-1.A1';
  const head = '# E1 — Ordering\n\n## E1-1 — Sign in\n';
  const stale = `${head}\n> Size H (8) · Scope COULD · Depends on — · Traces —\n**Summary:** x\n`;
  const once = renderEpicFile(stale, { tasks });
  assert.equal(once, `${head}${fresh}\n**Summary:** x\n`);
  assert.equal(renderEpicFile(once, { tasks }), once, 'a second render is a no-op');
  const note = `${head}> note: ask the product owner\n**Summary:** x\n`;
  const noted = renderEpicFile(note, { tasks });
  assert.equal(noted, `${head}${fresh}\n> note: ask the product owner\n**Summary:** x\n`);
  assert.equal(renderEpicFile(noted, { tasks }), noted);
  const blank = `${head}\n**Summary:** x\n`;
  const spaced = renderEpicFile(blank, { tasks });
  assert.equal(spaced, `${head}${fresh}\n\n**Summary:** x\n`, 'a blank line before content is kept');
  assert.equal(renderEpicFile(spaced, { tasks }), spaced);
  const fenced = '# E1 — Ordering\n\n```md\n## E1-1 — Sign in\n```\n';
  assert.equal(renderEpicFile(fenced, { tasks }), fenced, 'a heading inside a fence is no Task heading');
});

test('readBacklogFiles: Epic files in id order; delivery-plan.md, other files and directories ignored', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'backlog-files-'));
  const epicDir = path.join(dir, '.agents', 'backlog');
  fs.mkdirSync(path.join(epicDir, 'E3-dir.md'), { recursive: true });
  for (const name of ['E10-later.md', 'E2-reporting.md', 'E1-ordering.md', 'delivery-plan.md', 'notes.md', 'E4-x.md.tmp.1', 'E5.md']) fs.writeFileSync(path.join(epicDir, name), `# ${name}\n`);
  const missing = readBacklogFiles(path.join(dir, '.agents', 'backlog.md'));
  assert.equal(missing.md, null);
  assert.deepEqual(missing.epicFiles.map((f) => f.name), ['E1-ordering.md', 'E2-reporting.md', 'E10-later.md']);
  assert.equal(missing.epicFiles[0].text, '# E1-ordering.md\n');
  fs.writeFileSync(path.join(dir, '.agents', 'backlog.md'), 'x');
  assert.equal(readBacklogFiles(path.join(dir, '.agents', 'backlog.md'), path.join(dir, 'nope')).epicFiles.length, 0, 'a missing directory → no Epic files');
  assert.equal(readBacklogFiles(path.join(dir, '.agents', 'backlog.md')).md, 'x');
  assert.equal(EPIC_DIR, '.agents/backlog');
});

test('epicSlug: diacritics, ł, punctuation, empty titles and the 40-character cut at a hyphen', () => {
  assert.equal(epicSlug('Zamówienia i płatności – łańcuch'), 'zamowienia-i-platnosci-lancuch');
  assert.equal(epicSlug('Łódź Ćwiczenia ŻÓŁW'), 'lodz-cwiczenia-zolw');
  assert.equal(epicSlug('Checkout & payment'), 'checkout-payment');
  assert.equal(epicSlug('  --Café, crème brûlée!--  '), 'cafe-creme-brulee');
  assert.equal(epicSlug(''), 'epic');
  assert.equal(epicSlug('!!!'), 'epic');
  const sixty = 'Customer account management and self service portal features';
  assert.equal(sixty.length, 60);
  assert.equal(epicSlug(sixty), 'customer-account-management-and-self');
  assert.ok(epicSlug(sixty).length <= 40);
  assert.equal(epicSlug('a'.repeat(50)), 'a'.repeat(40), 'one word longer than the cap is cut mid-word');
  assert.equal(epicSlug(`${'b'.repeat(40)} tail`), 'b'.repeat(40), 'a cut exactly at a word end keeps the word');
  assert.equal(epicFileName('E5', 'Checkout & payment'), 'E5-checkout-payment.md');
});

// ---------------------------------------------------------------------------------------------
// Delivered-Task write-back
// ---------------------------------------------------------------------------------------------

const SPEC = '.agents/specs/2026-01-01-e1-1-sign-in.md';
const DONE_PLAN = '.agents/plans/done/e1-1-sign-in.md';

function writePlan(dir, rel, { tasks, spec = `\`${SPEC}\`` }) {
  const file = path.join(dir, rel);
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, `# Feature\n\n**Source spec:** ${spec}\n**Tasks:** ${tasks}\n\n## Body\n`);
}

const task = (over = {}) => ({ id: 'E1-1', status: 'TODO', ref: null, jira: null, withdrawn: false, ...over });

test('staleTaskWarnings: a TODO row on a done plan names the status, the plan and the spec', () => {
  const dir = project();
  writePlan(dir, DONE_PLAN, { tasks: 'E1-1' });
  const w = staleTaskWarnings([task()], loadPlanTasks(dir));
  assert.equal(w.length, 1);
  assert.match(w[0], /^Task E1-1: delivered by \.agents\/plans\/done\/e1-1-sign-in\.md but /);
  assert.match(w[0], /Status TODO, not DONE; Ref lacks a done plan \(.*e1-1-sign-in\.md\); /);
  assert.match(w[0], /; Ref lacks its spec \(/);
});

test('staleTaskWarnings: an id still on an active plan is not delivered yet', () => {
  const dir = project();
  writePlan(dir, DONE_PLAN, { tasks: 'E1-1' });
  writePlan(dir, '.agents/plans/active/e1-1-part-2.md', { tasks: 'E1-1, E1-2' });
  assert.deepEqual(staleTaskWarnings([task()], loadPlanTasks(dir)), []);
});

test('staleTaskWarnings: DONE + plan + spec in Ref is clean; plan only → lacks its spec', () => {
  const dir = project();
  writePlan(dir, DONE_PLAN, { tasks: 'E1-1' });
  const plans = loadPlanTasks(dir);
  assert.deepEqual(staleTaskWarnings([task({ status: 'DONE', ref: `${SPEC}, ${DONE_PLAN}` })], plans), []);
  const w = staleTaskWarnings([task({ status: 'DONE', ref: DONE_PLAN })], plans);
  assert.equal(w.length, 1);
  assert.match(w[0], /but Ref lacks its spec \(\.agents\/specs\/2026-01-01-e1-1-sign-in\.md\)$/);
});

test('staleTaskWarnings: a Jira-keyed Task reopened in the tracker keeps only the Ref checks', () => {
  const dir = project();
  writePlan(dir, DONE_PLAN, { tasks: 'E1-1' });
  const plans = loadPlanTasks(dir);
  assert.deepEqual(staleTaskWarnings([task({ jira: 'ABC-7', ref: `${SPEC}, ${DONE_PLAN}` })], plans), []);
  const w = staleTaskWarnings([task({ jira: 'ABC-7' })], plans);
  assert.equal(w.length, 1);
  assert.doesNotMatch(w[0], /Status/);
  assert.match(w[0], /Ref lacks a done plan/);
});

test('staleTaskWarnings: a GitHub issue number in the Jira cell keeps the Status check', () => {
  const dir = project();
  writePlan(dir, DONE_PLAN, { tasks: 'E1-1' });
  const w = staleTaskWarnings([task({ jira: '#42', ref: `${SPEC}, ${DONE_PLAN}` })], loadPlanTasks(dir));
  assert.equal(w.length, 1);
  assert.match(w[0], /Status TODO, not DONE/);
});

test('loadPlanTasks: quick-mode spec → null, non-Task id dropped; withdrawn Task skipped', () => {
  const dir = project();
  writePlan(dir, DONE_PLAN, { tasks: 'E1-1', spec: 'none (quick mode)' });
  writePlan(dir, '.agents/plans/done/139-filters.md', { tasks: '#139 (tracker issue, not a backlog Task)' });
  const plans = loadPlanTasks(dir);
  assert.deepEqual(plans.done.map((p) => [p.path, p.ids, p.spec]), [
    ['.agents/plans/done/139-filters.md', [], SPEC],
    [DONE_PLAN, ['E1-1'], null],
  ]);
  assert.deepEqual(staleTaskWarnings([task({ status: 'DONE', ref: DONE_PLAN })], plans), []);
  assert.deepEqual(staleTaskWarnings([task({ withdrawn: true })], plans), []);
});

test('loadPlanTasks: annotated ids keep their leading id; a later backtick is not the spec', () => {
  const dir = project();
  writePlan(dir, DONE_PLAN, { tasks: 'E1-1', spec: 'none (quick mode) — ticket `#158`' });
  writePlan(dir, '.agents/plans/active/e1-1-part-2.md', { tasks: '`E1-1` (umbrella), E1-2.' });
  const plans = loadPlanTasks(dir);
  assert.equal(plans.done[0].spec, null);
  assert.deepEqual(plans.active[0].ids, ['E1-1', 'E1-2']);
  assert.deepEqual(staleTaskWarnings([task({ status: 'WIP' })], plans), []);
});

test('CLI: no plans dir → no delivered-by warning; a done plan warns (exit 0) but never under --candidate', () => {
  const dir = project();
  assert.deepEqual(loadPlanTasks(dir), { done: [], active: [] });
  const clean = run(dir);
  assert.equal(clean.code, 0);
  assert.doesNotMatch(clean.out, /delivered by/);
  writePlan(dir, DONE_PLAN, { tasks: 'E1-1' });
  const stale = run(dir);
  assert.equal(stale.code, 0);
  assert.match(stale.out, /warning: Task E1-1: delivered by \.agents\/plans\/done\/e1-1-sign-in\.md but Status TODO/);
  const cand = writeCandidate(dir, backlogMd());
  const c = run(dir, '--candidate', cand);
  assert.equal(c.code, 0);
  assert.doesNotMatch(c.out, /delivered by/);
});

// ---------------------------------------------------------------------------------------------
// (Q) quality Tasks — .claude/skills/backlog/quality-tasks.md
// ---------------------------------------------------------------------------------------------

const BASE_EPICS = [
  '| E0 | Foundation | skeleton everything stands on | monolith is enough | 12 | — | — |',
  '| E1 | Ordering | first order placed (G-1) | users accept email confirmation | 16 | E0 | — |',
  '| E2 | Reporting | owners see totals | daily granularity suffices | 12 | E1 | — |',
];
const QUALITY_EPIC = '| E3 | Quality & upkeep | the committed scope ships audited | the audits run against the product as built | 40 | — | — |';
// Product P = 36 → n = 2; the prefix to 18 is E0-1…E1-2 (sinks E1-1, E1-2); the whole set's sinks are E1-1, E1-3, E2-1.
const QUALITY_ROWS = [
  '| E3-1 | E3 | [upkeep:architecture-review] Run /architecture-review — occurrence 1 | tech | M | 4 | E1-1, E1-2 | MUST | — | — | TODO | — | — |',
  '| E3-2 | E3 | [upkeep:cleanup-workflow] Run /maintain:cleanup-workflow — occurrence 1 | tech | M | 4 | E1-1, E1-2, E3-1 | MUST | — | — | TODO | — | — |',
  '| E3-3 | E3 | [upkeep:architecture-review] Run /architecture-review — occurrence 2 | tech | M | 4 | E1-1, E1-3, E2-1, E3-2 | MUST | — | — | TODO | — | — |',
  '| E3-4 | E3 | [upkeep:cleanup-workflow] Run /maintain:cleanup-workflow — occurrence 2 | tech | M | 4 | E1-1, E1-3, E2-1, E3-3 | MUST | — | — | TODO | — | — |',
  '| E3-5 | E3 | [audit:security] Run /audit-security | tech | H | 8 | E1-1, E1-3, E2-1 | MUST | — | — | TODO | — | — |',
  '| E3-6 | E3 | [audit:seo-geo] Run /seo-geo-audit | tech | H | 8 | E1-1, E1-3, E2-1 | MUST | — | — | TODO | — | — |',
  '| E3-7 | E3 | [audit:wcag] Run /wcag-audit | tech | H | 8 | E1-1, E1-3, E2-1 | MUST | — | — | TODO | — | — |',
];
const qepic = (pts) => QUALITY_EPIC.replace('| 40 |', `| ${pts} |`);
/** The backlog text of a quality fixture; `outOfScope` lines are appended under `## Consciously out of scope`. */
const qmd = (rows = QUALITY_ROWS, { epics = [...BASE_EPICS, QUALITY_EPIC], base = TASK_ROWS, outOfScope = [] } = {}) =>
  backlogMd({ rows: [...base, ...rows], epics, detail: 'structure' }).replace('- payments\n', ['- payments', ...outOfScope].join('\n') + '\n');
const quality = (rows = QUALITY_ROWS, opts = {}) => check(project({ backlog: qmd(rows, opts) }));
const qw = (res) => res.warnings.filter((w) => /quality|occurrence|\[(audit|upkeep):/.test(w));
const qrow = (id, cell) => QUALITY_ROWS.map((r) => (r.startsWith(`| ${id} |`) ? cell : r));
const qdrop = (rows, ...ids) => rows.filter((r) => !ids.some((id) => r.startsWith(`| ${id} |`)));
const auditError = (res, id) => res.errors.filter((e) => e.startsWith(`Task ${id} [audit:`));
const ALL_UNPLANNED = 'quality Tasks not planned: [audit:security], [audit:seo-geo], [audit:wcag], [upkeep:architecture-review], [upkeep:cleanup-workflow] — add them with /update-backlog (.claude/skills/backlog/quality-tasks.md); only [audit:seo-geo] and [audit:wcag] may be ruled out under ## Consciously out of scope';

test('audit:wcag names /wcag-audit', () => {
  assert.equal(QUALITY_MARKERS['audit:wcag'].command, '/wcag-audit');
});

test('quality: a fresh backlog with the full quality Epic raises no quality warning and no trace warning', () => {
  const res = quality();
  assert.deepEqual(res.errors, []);
  assert.deepEqual(qw(res), [], res.warnings.join('\n'));
  assert.ok(!res.warnings.some((w) => /^Task E3-\d+: tech Task with no trace/.test(w)), res.warnings.join('\n'));
  const base = check(project());
  assert.deepEqual(base.errors, []);
  assert.deepEqual(qw(base), [ALL_UNPLANNED], base.warnings.join('\n'));
});

test('quality: an open closing audit that misses a product sink is an error naming the sinks; WIP and DONE audits are not', () => {
  const short = (status) => qrow('E3-5', `| E3-5 | E3 | [audit:security] Run /audit-security | tech | H | 8 | E1-1, E1-3 | MUST | — | — | ${status} | — | — |`);
  const expected = 'Task E3-5 [audit:security]: a closing audit must wait for every live CORE/MUST product Task — add E2-1 to Depends on';
  assert.deepEqual(quality(short('TODO')).errors, [expected]);
  assert.deepEqual(quality(short('BLOCKED')).errors, [expected]);
  assert.deepEqual(quality(short('WIP')).errors, []);
  assert.deepEqual(quality(short('DONE')).errors, []);

  // A withdrawn product Task is no work to wait for.
  const withdrawn = TASK_ROWS.map((r) => (r.startsWith('| E2-1 |') ? '| E2-1 | E2 | Report view (withdrawn) | story | H | 8 | E1-2 | MUST | reporting | FL-2.A1, BR-1 | DONE | — | — |' : r));
  assert.deepEqual(quality(QUALITY_ROWS, { base: withdrawn }).errors, []);

  // A path through DONE Tasks is no wait: a reopened E1-2 behind DONE E1-3 / E2-1 must be named.
  const reopened = TASK_ROWS.map((r) => (/^\| E(1-3|2-1) \|/.test(r) ? r.replace('| TODO |', '| DONE |') : r));
  const done = quality(QUALITY_ROWS, { base: reopened });
  assert.deepEqual(auditError(done, 'E3-5'), ['Task E3-5 [audit:security]: a closing audit must wait for every live CORE/MUST product Task — add E1-2 to Depends on'], done.errors.join('\n'));

  // A re-audit supersedes the earlier audit of its marker; the newest one is the one that must wait.
  const reaudit = (deps, status = 'TODO') => [...short('TODO'), `| E3-8 | E3 | [audit:security] Run /audit-security | tech | H | 8 | ${deps} | MUST | — | — | ${status} | — | — |`];
  const e48 = [...BASE_EPICS, qepic(48)];
  assert.deepEqual(quality(reaudit('E1-1, E1-3, E2-1'), { epics: e48 }).errors, []);
  const late = quality(reaudit('E1-1'), { epics: e48 });
  assert.deepEqual(late.errors, ['Task E3-8 [audit:security]: a closing audit must wait for every live CORE/MUST product Task — add E1-3, E2-1 to Depends on']);
  const fix = '| E2-3 | E2 | Report fix | story | M | 4 | E1-2 | MUST | reporting | FL-2.A1 | TODO | — | — |';
  const e2 = BASE_EPICS.map((e) => (e.startsWith('| E2 |') ? e.replace('| 12 |', '| 16 |') : e));
  const closed = quality(reaudit('E1-1, E1-3, E2-1', 'DONE'), { base: [...TASK_ROWS, fix], epics: [...e2, qepic(48)] });
  assert.deepEqual(auditError(closed, 'E3-5'), [], closed.errors.join('\n'));
  assert.deepEqual(auditError(closed, 'E3-8'), [], closed.errors.join('\n'));
});

test('quality: the occurrence count follows max(2, ceil(P / 160)); unnumbered reminder Tasks are not counted', () => {
  const noE33 = qdrop(QUALITY_ROWS, 'E3-3').map((r) => (r.startsWith('| E3-4 |') ? r.replace('E2-1, E3-3', 'E2-1, E3-2') : r));
  const one = quality(noE33, { epics: [...BASE_EPICS, qepic(36)] });
  assert.deepEqual(one.errors, []);
  assert.deepEqual(qw(one), ['[upkeep:architecture-review]: 1 occurrence(s) planned, 2 expected for 36 CORE/MUST product points (one per 160, at least 2) — add or withdraw one with /update-backlog']);

  // Scaling: 284 bulk points + 36 = 320 → n = 2; one more M (324) → n = 3.
  const occurrences = QUALITY_ROWS.slice(0, 4);
  const bulk = (extraM) => [
    ...Array.from({ length: 17 }, (_, i) => `| E4-${i + 1} | E4 | Bulk ${i + 1} | tech | XH | 16 | E0-1 | MUST | — | AD-1 | TODO | — | — |`),
    ...Array.from({ length: 3 + extraM }, (_, i) => `| E4-${i + 18} | E4 | Bulk ${i + 18} | tech | M | 4 | E0-1 | MUST | — | AD-1 | TODO | — | — |`),
  ];
  const bulkEpic = (pts) => `| E4 | Bulk | bulk work | none | ${pts} | — | — |`;
  const at320 = quality(occurrences, { base: [...TASK_ROWS, ...bulk(0)], epics: [...BASE_EPICS, qepic(16), bulkEpic(284)] });
  assert.deepEqual(at320.errors, []);
  assert.ok(!at320.warnings.some((w) => /occurrence\(s\) planned/.test(w)), at320.warnings.join('\n'));
  const at324 = quality(occurrences, { base: [...TASK_ROWS, ...bulk(1)], epics: [...BASE_EPICS, qepic(16), bulkEpic(288)] });
  assert.deepEqual(at324.errors, []);
  assert.ok(at324.warnings.includes('[upkeep:architecture-review]: 2 occurrence(s) planned, 3 expected for 324 CORE/MUST product points (one per 160, at least 2) — add or withdraw one with /update-backlog'), at324.warnings.join('\n'));

  // A reminder's unnumbered Task neither counts nor needs prerequisites.
  const doneOcc = QUALITY_ROWS.map((r, i) => (i < 4 ? r.replace('| TODO |', '| DONE |') : r));
  const reminder = quality([...doneOcc, '| E3-8 | E3 | [upkeep:architecture-review] Run /architecture-review | tech | M | 4 | — | MUST | — | — | TODO | — | — |'], { epics: [...BASE_EPICS, qepic(44)] });
  assert.deepEqual(reminder.errors, []);
  assert.deepEqual(qw(reminder), [], reminder.warnings.join('\n'));
});

test('quality: an open numbered occurrence without Depends on warns', () => {
  const free = (status) => qrow('E3-1', `| E3-1 | E3 | [upkeep:architecture-review] Run /architecture-review — occurrence 1 | tech | M | 4 | — | MUST | — | — | ${status} | — | — |`);
  const open = quality(free('TODO'));
  assert.deepEqual(open.errors, []);
  assert.deepEqual(qw(open), ['Task E3-1 [upkeep:architecture-review]: occurrence 1 has no Depends on — it would be free on day one; place it after its share of the product work']);
  const done = quality(free('DONE'));
  assert.deepEqual(done.errors, []);
  assert.deepEqual(qw(done), [], done.warnings.join('\n'));
});

test('quality: a missing mandatory marker warns even when ruled out; a conditional one may be ruled out', () => {
  const conditionalOut = ['- [audit:seo-geo] — no public website', '- [audit:wcag] — no user interface'];
  const ruledRows = qdrop(QUALITY_ROWS, 'E3-6', 'E3-7');
  const ruledOpts = { epics: [...BASE_EPICS, qepic(24)], outOfScope: conditionalOut };
  const ruled = quality(ruledRows, ruledOpts);
  assert.deepEqual(ruled.errors, []);
  assert.ok(!ruled.warnings.some((w) => /quality Tasks not planned/.test(w)), ruled.warnings.join('\n'));
  assert.deepEqual(parseBacklog(qmd(ruledRows, ruledOpts)).ruledOut, ['audit:seo-geo', 'audit:wcag']);

  const noSecurity = quality(qdrop(QUALITY_ROWS, 'E3-5', 'E3-6', 'E3-7'), { epics: [...BASE_EPICS, qepic(16)], outOfScope: [...conditionalOut, '- [audit:security] — not needed'] });
  assert.deepEqual(noSecurity.errors, []);
  assert.deepEqual(noSecurity.warnings.filter((w) => /quality Tasks not planned/.test(w)), ['quality Tasks not planned: [audit:security] — add them with /update-backlog (.claude/skills/backlog/quality-tasks.md); only [audit:seo-geo] and [audit:wcag] may be ruled out under ## Consciously out of scope']);

  // A reminder's unnumbered Task alone does not plan the recurring command.
  const reminderOnly = qdrop(QUALITY_ROWS, 'E3-1', 'E3-3').map((r) => r.replace('E1-1, E1-2, E3-1', 'E1-1, E1-2').replace('E2-1, E3-3', 'E2-1, E3-2'));
  const reminder = quality([...reminderOnly, '| E3-8 | E3 | [upkeep:architecture-review] Run /architecture-review | tech | M | 4 | — | MUST | — | — | TODO | — | — |'], { epics: [...BASE_EPICS, qepic(36)] });
  assert.deepEqual(reminder.errors, []);
  assert.deepEqual(reminder.warnings.filter((w) => /quality Tasks not planned/.test(w)), ['quality Tasks not planned: [upkeep:architecture-review] — add them with /update-backlog (.claude/skills/backlog/quality-tasks.md); only [audit:seo-geo] and [audit:wcag] may be ruled out under ## Consciously out of scope']);
});

test('quality: off type/size/scope and unknown markers warn', () => {
  const resized = quality(qrow('E3-5', '| E3-5 | E3 | [audit:security] Run /audit-security | tech | M | 4 | E1-1, E1-3, E2-1 | MUST | — | — | TODO | — | — |'), { epics: [...BASE_EPICS, qepic(36)] });
  assert.deepEqual(resized.errors, []);
  assert.ok(resized.warnings.includes('Task E3-5 [audit:security]: expected tech · H · MUST, found tech · M · MUST'), resized.warnings.join('\n'));
  const typo = quality(qrow('E3-5', '| E3-5 | E3 | [audit:securty] Run /audit-security | tech | H | 8 | E1-1, E1-3, E2-1 | MUST | — | — | TODO | — | — |'));
  assert.deepEqual(typo.errors, []);
  assert.ok(typo.warnings.includes('Task E3-5: unknown quality marker [audit:securty] — use one of [audit:security], [audit:seo-geo], [audit:wcag], [upkeep:architecture-review], [upkeep:cleanup-workflow], [upkeep:refresh-brief]'), typo.warnings.join('\n'));
  const clean = quality();
  assert.ok(!clean.warnings.some((w) => /expected tech ·|unknown quality marker/.test(w)), clean.warnings.join('\n'));
});

test('quality: CORE minimality ignores quality consumers', () => {
  const flags = '| E0-3 | E0 | Feature flags | tech | M | 4 | E0-1 | CORE | platform-core | AD-1 | TODO | — | — |';
  const e0 = BASE_EPICS.map((e) => (e.startsWith('| E0 |') ? e.replace('| 12 |', '| 16 |') : e));
  const audits = QUALITY_ROWS.map((r) => (/^\| E3-[567] \|/.test(r) ? r.replace('| E1-1, E1-3, E2-1 |', '| E0-3, E1-1, E1-3, E2-1 |') : r));
  const res = quality(audits, { base: [...TASK_ROWS, flags], epics: [...e0, QUALITY_EPIC] });
  assert.deepEqual(res.errors, []);
  assert.ok(res.warnings.includes('Task E0-3: CORE, but nothing outside CORE depends on it — candidate to leave CORE'), res.warnings.join('\n'));
  assert.ok(!res.warnings.some((w) => /Task E0-[12]: CORE, but/.test(w)), res.warnings.join('\n'));
});

test('quality: reminder Tasks for every upkeep id need no trace and raise no quality warning', () => {
  const rows = [
    ...QUALITY_ROWS,
    '| E3-8 | E3 | [upkeep:refresh-brief] Run /maintain:refresh-brief | tech | M | 4 | — | MUST | — | — | TODO | — | — |',
    '| E3-9 | E3 | [upkeep:cleanup-workflow] Run /maintain:cleanup-workflow | tech | M | 4 | — | MUST | — | — | TODO | — | — |',
    '| E3-10 | E3 | [upkeep:architecture-review] Run /architecture-review | tech | M | 4 | — | MUST | — | — | TODO | — | — |',
  ];
  const res = quality(rows, { epics: [...BASE_EPICS, qepic(52)] });
  assert.deepEqual(res.errors, []);
  assert.deepEqual(qw(res), [], res.warnings.join('\n'));
  assert.ok(!res.warnings.some((w) => /^Task E3-(8|9|10): tech Task with no trace/.test(w)), res.warnings.join('\n'));
});

test('quality: a tech Task without a marker and no trace still warns', () => {
  const res = quality([...QUALITY_ROWS, '| E3-8 | E3 | Run the brief refresh | tech | M | 4 | — | COULD | — | — | TODO | — | — |'], { epics: [...BASE_EPICS, qepic(44)] });
  assert.ok(res.warnings.includes('Task E3-8: tech Task with no trace (AD-n / NFR-n)'), res.warnings.join('\n'));
});

test('quality: an unknown upkeep id is neither recognized nor trace-exempt', () => {
  const res = quality([...QUALITY_ROWS, '| E3-8 | E3 | [upkeep:foo] Run /foo | tech | M | 4 | — | COULD | — | — | TODO | — | — |'], { epics: [...BASE_EPICS, qepic(44)] });
  assert.ok(res.warnings.includes('Task E3-8: unknown quality marker [upkeep:foo] — use one of [audit:security], [audit:seo-geo], [audit:wcag], [upkeep:architecture-review], [upkeep:cleanup-workflow], [upkeep:refresh-brief]'), res.warnings.join('\n'));
  assert.ok(res.warnings.includes('Task E3-8: tech Task with no trace (AD-n / NFR-n)'), res.warnings.join('\n'));
});

test('quality: a refresh-brief reminder is never required and plans nothing', () => {
  const res = quality(['| E3-1 | E3 | [upkeep:refresh-brief] Run /maintain:refresh-brief | tech | M | 4 | — | MUST | — | — | TODO | — | — |'], { epics: [...BASE_EPICS, qepic(4)] });
  assert.deepEqual(res.errors, []);
  assert.deepEqual(qw(res), [ALL_UNPLANNED], res.warnings.join('\n'));
});
