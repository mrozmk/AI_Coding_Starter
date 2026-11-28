// Tests of the catalog cross-checks (.claude/lib/regression/crosscheck.mjs) through the catalog.mjs
// entry: `--backlog [--candidate <dir>]` and `--delta <rev|none> [--spec | --plan [--planning]]`.
// Every root is a fresh temp git repo (user/email per command, never the global config).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import crypto from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

import { extractFingerprintBlock, fingerprint, currentFingerprint } from '../regression/catalog.mjs';
import { validateConfig } from '../regression/config.mjs';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const REPO = path.join(HERE, '../../..');
const CATALOG = path.join(HERE, '../regression/catalog.mjs');
const FIX = path.join(HERE, 'fixtures/regression');
const FP_REF = path.join(REPO, '.agents/reference/qa-evidence-families.md');
const CAT = '.agents/regression/scenarios';
const SPEC = '.agents/specs/2026-11-27-cart.md';
const PLAN = '.agents/plans/active/cart.md';
const CAND = '.agents/.pending-update';
const CONFIG = { version: 1, catalog: { areas: { CART: 'Cart' } } };
const GIT = ['-c', 'user.name=t', '-c', 'user.email=t@example.invalid', '-c', 'commit.gpgsign=false', '-c', 'init.defaultBranch=main'];

const FPB = extractFingerprintBlock(REPO).block;
const tok = (id, text) => `${id} [${fingerprint(FPB, `- **${id}** ${text}`)}]`;
const keyTok = (key, text) => `${key} [${fingerprint(FPB, `- ${text}`)}]`;
const digest = (text) => crypto.createHash('sha256').update(text.replace(/\s+/g, ' ').trim()).digest('hex').slice(0, 12);

const A1 = '[reg P0] Given one line in the cart, when the quantity is raised to the maximum, then the line total follows.';
const B1 = '[reg P1] Given a valid voucher, when it is applied, then the discount shows.';
const U1 = 'Given an empty cart, when the cart opens, then the empty state shows.';
const T1 = tok('E1-1.AC1', A1);
const T2 = tok('E1-2.AC1', B1);

function write(root, rel, text) {
  fs.mkdirSync(path.dirname(path.join(root, rel)), { recursive: true });
  fs.writeFileSync(path.join(root, rel), typeof text === 'string' ? text : `${JSON.stringify(text, null, 2)}\n`);
}
const read = (root, rel) => fs.readFileSync(path.join(root, rel), 'utf8');
const remove = (root, rel) => fs.rmSync(path.join(root, rel), { recursive: true, force: true });

function git(root, ...args) {
  const r = spawnSync('git', ['-C', root, ...GIT, ...args], { encoding: 'utf8' });
  assert.equal(r.status, 0, `git ${args.join(' ')}: ${r.stderr}`);
  return r.stdout.trim();
}
function commit(root, msg = 'change') { git(root, 'add', '-A'); git(root, 'commit', '-qm', msg); }

/** A temp git repo: the `valid` fixture's backlog, the §7c reference, the catalog-only config, `files`, one base commit. */
function mkRepo(files = {}, { adopted = true } = {}) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'crosscheck-test-'));
  for (const rel of ['.agents/backlog.md', '.agents/backlog/E1-cart.md']) write(root, rel, fs.readFileSync(path.join(FIX, 'valid', rel), 'utf8'));
  write(root, '.agents/reference/qa-evidence-families.md', fs.readFileSync(FP_REF, 'utf8'));
  if (adopted) write(root, '.claude/regression.json', CONFIG);
  for (const [rel, text] of Object.entries(files)) write(root, rel, text);
  git(root, 'init', '-q');
  commit(root, 'base');
  return root;
}

const cli = (root, ...args) => spawnSync(process.execPath, [CATALOG, '--root', root, ...args], { encoding: 'utf8' });
const out = (r) => `${r.stdout}${r.stderr}`;
const has = (r, s) => assert.ok(out(r).includes(s), `expected "${s}" in:\n${out(r)}`);
const lacks = (r, s) => assert.ok(!out(r).includes(s), `unexpected "${s}" in:\n${out(r)}`);
const exit = (r, code) => assert.equal(r.status, code, out(r));

function block(id, o = {}) {
  return [
    `### ${id} — ${o.title ?? 'A cart scenario'}`,
    `- **Priority:** ${o.priority ?? 'P0'} · **Viewport:** both · **Status:** ${o.status ?? 'READY'} · **Effect:** read`,
    '- **Goal:** Check the cart.',
    '- **Steps:**',
    '  1. Open the cart.',
    `- **Expected:** ${o.expected ?? 'The cart shows its lines.'}`,
    `- **Source:** ${o.source ?? 'live'} · **Spec:** —`,
  ].join('\n');
}
const cat = (...blocks) => `# Cart\n\n${blocks.join('\n\n')}\n`;
const spec = (criteria, extra = '') => `# Design: cart\n\n**Status:** Approved (auto — team mode)\n\n## Acceptance Criteria\n\n${criteria.join('\n')}\n${extra}`;
const crit = (head, ...proofs) => [head, ...proofs.map((p) => `  - Proof: ${p}`)].join('\n');
function plan({ source = `\`${SPEC}\``, parent, scenarios, criteria = [], tasks = '' } = {}) {
  const head = ['# Feature: cart', ''];
  if (parent) head.push(`**Parent:** ${parent}`);
  else if (source !== null) head.push(`**Source spec:** ${source}`);
  if (scenarios) head.push(`**Scenarios:** ${scenarios}`);
  return `${head.join('\n')}\n\n## STEP-BY-STEP TASKS\n\n${tasks}\n\n## ACCEPTANCE CRITERIA\n\n${criteria.join('\n')}\n\n## NOTES\n\n- none\n`;
}
const epic = (ac1 = `- **E1-1.AC1** — ${A1}`, ac2 = `- **E1-1.AC2** — ${U1}`, more = '') => `# E1 — Cart

## E1-1 — Change quantity
**Summary:** Change quantity for the shop.
**Goal:** deliver change quantity.
**In scope:** the happy path and its errors.
**Out of scope:** admin tooling.
### Acceptance criteria
${ac1}
${ac2}
${more}
## E1-2 — Vouchers
**Summary:** Vouchers for the shop.
**Goal:** deliver vouchers.
**In scope:** the happy path and its errors.
**Out of scope:** admin tooling.
### Acceptance criteria
- **E1-2.AC1** — ${B1}
`;
const backlogMd = (root, edit) => edit(read(root, '.agents/backlog.md'));
const setStatus = (md, task, status) => md.replace(new RegExp(`(\\| ${task} \\|.*\\| )(TODO|WIP|DONE)( \\|)`), `$1${status}$3`);
const withdrawTask = (md, task) => md.replace(new RegExp(`(\\| ${task} \\| E1 \\| )([^|]+?)( \\|)`), '$1$2 (withdrawn)$3');
/** The candidate set of /update-backlog: backlog.md, the Epic file, the catalog files given. */
function candidate(root, { backlog, epicText, catalog = {} }) {
  write(root, `${CAND}/backlog.md`, backlog ?? read(root, '.agents/backlog.md'));
  write(root, `${CAND}/backlog/E1-cart.md`, epicText ?? read(root, '.agents/backlog/E1-cart.md'));
  for (const [name, text] of Object.entries(catalog)) write(root, `${CAND}/regression/${name}`, text);
}

// ---------------------------------------------------------------------------------------------

test('crosscheck: not adopted — --backlog and --delta print nothing and exit 0', () => {
  const root = mkRepo({}, { adopted: false });
  for (const args of [['--backlog'], ['--delta', 'HEAD'], ['--delta', 'HEAD', '--spec', 'x.md']]) {
    const r = cli(root, ...args);
    assert.equal(r.stdout, '', args.join(' '));
    assert.equal(r.status, 0, args.join(' '));
  }
  assert.equal(cli(root).stdout, 'regression not adopted\n');
});

test('crosscheck: --backlog reports unknown, withdrawn and superseded Source ids', () => {
  const ac3 = '[reg P0] Given two lines, when one is raised, then only its total follows.';
  const root = mkRepo({
    '.agents/backlog/E1-cart.md': epic('- **E1-1.AC1** — (withdrawn) superseded by E1-1.AC3', `- **E1-1.AC2** — ${U1}`,
      `- **E1-1.AC3** — ${ac3}\n- **E1-1.AC4** — (withdrawn) no longer needed\n`),
    'docs/discovery.md': '# Discovery\n\n## Flows\n\n### FL-1 — Checkout\n- **FL-1.A1** — Open the cart\n- **FL-1.A2** — (withdrawn) Old step\n\n'
      + '### FL-2 — Old flow (withdrawn)\n- **FL-2.A1** — A step\n\n### FL-3 — Account\n- **FL-3.A1** — (superseded by FL-4)\n\n### FL-4 — Account v2\n- **FL-4.A1** — Sign in\n',
    [`${CAT}/cart.md`]: cat(
      block('CART-001', { source: 'E9-1.AC1 [abcdef]' }), block('CART-002', { source: 'E1-1.AC9 [abcdef]' }),
      block('CART-003', { source: T1 }), block('CART-004', { source: 'E1-1.AC4 [abcdef]' }),
      block('CART-005', { source: 'FL-9' }), block('CART-006', { source: 'FL-1.A2' }), block('CART-007', { source: 'FL-2.A1' }),
      block('CART-008', { source: 'FL-3.A1' }), block('CART-009', { source: `FL-1.A1 · ${tok('E1-1.AC3', ac3)}` }),
      block('CART-010', { status: 'DROPPED (D-1)', source: 'E9-9.AC1 [abcdef]' })),
  });
  const r = cli(root, '--backlog');
  exit(r, 1);
  has(r, 'CART-001: unknown E9-1.AC1 [abcdef] — Task E9-1 absent');
  has(r, "CART-002: unknown E1-1.AC9 [abcdef] — not among E1-1's current criteria");
  has(r, `CART-003: withdrawn ${T1} — superseded by E1-1.AC3`);
  has(r, 'CART-004: withdrawn E1-1.AC4 [abcdef]');
  has(r, 'CART-005: unknown FL-9 — not in docs/discovery.md');
  has(r, 'CART-006: withdrawn FL-1.A2');
  has(r, 'CART-007: withdrawn FL-2.A1');
  has(r, 'CART-008: withdrawn FL-3.A1 — superseded by FL-4');
  lacks(r, 'CART-009');
  lacks(r, 'CART-010');
});

test('crosscheck: --backlog reports a DONE Task with a tagged criterion and no scenario', () => {
  const root = mkRepo({ [`${CAT}/cart.md`]: cat(block('CART-001', { source: 'live' })) });
  write(root, '.agents/backlog.md', backlogMd(root, (md) => setStatus(md, 'E1-1', 'DONE')));
  let r = cli(root, '--backlog');
  exit(r, 1);
  has(r, '.agents/backlog.md: E1-1: DONE with tagged criterion E1-1.AC1 and no scenario');
  lacks(r, 'E1-2:');
  write(root, `${CAT}/cart.md`, cat(block('CART-001', { source: T1 })));
  r = cli(root, '--backlog');
  exit(r, 0);
});

test('crosscheck: --backlog warns on an old fingerprint without failing', () => {
  const root = mkRepo({ [`${CAT}/cart.md`]: cat(block('CART-001', { source: 'E1-1.AC1 [000000]' })) });
  const r = cli(root, '--backlog');
  exit(r, 0);
  has(r, `warning: ${CAT}/cart.md:`);
  has(r, `CART-001: E1-1.AC1 [000000] cites an old fingerprint — re-point the Source (current [${T1.slice(-7, -1)}])`);
});

test('crosscheck: --backlog --candidate reads the candidate backlog and catalog overlay', () => {
  const root = mkRepo({ [`${CAT}/cart.md`]: cat(block('CART-001', { source: T1 })) });
  const before = read(root, `${CAT}/cart.md`);
  candidate(root, { backlog: backlogMd(root, (md) => setStatus(md, 'E1-2', 'DONE')) });
  let r = cli(root, '--backlog', '--candidate', CAND);
  exit(r, 1);
  has(r, 'E1-2: DONE with tagged criterion E1-2.AC1 and no scenario');
  candidate(root, { backlog: backlogMd(root, (md) => setStatus(md, 'E1-2', 'DONE')), catalog: { 'cart.md': cat(block('CART-001', { source: T1 }), block('CART-002', { priority: 'P1', source: T2 })) } });
  r = cli(root, '--backlog', '--candidate', CAND);
  exit(r, 0);
  write(root, `${CAND}/regression/cart.md`, cat(block('CART-001', { source: T1, priority: 'P9' })));
  r = cli(root, '--backlog', '--candidate', CAND);
  exit(r, 1);
  has(r, `${CAT}/cart.md:4: unknown Priority value P9`);
  assert.equal(read(root, `${CAT}/cart.md`), before);
  assert.equal(git(root, 'status', '--porcelain', '--', CAT), '');
});

test('crosscheck: a shared scenario keeps the citation of a live Task', () => {
  const root = mkRepo({ [`${CAT}/cart.md`]: cat(block('CART-001', { source: `${T1} · ${T2}` })) });
  const retired = backlogMd(root, (md) => setStatus(withdrawTask(md, 'E1-1'), 'E1-2', 'DONE'));
  candidate(root, { backlog: retired, catalog: { 'cart.md': cat(block('CART-001', { source: T2 })) } });
  exit(cli(root, '--backlog', '--candidate', CAND), 0);
  candidate(root, { backlog: retired, catalog: { 'cart.md': cat(block('CART-001', { status: 'DROPPED (D-1)', source: T2 })) } });
  const r = cli(root, '--backlog', '--candidate', CAND);
  exit(r, 1);
  has(r, 'E1-2: DONE with tagged criterion E1-2.AC1 and no scenario');
  // A block whose only criterion is retired becomes DROPPED and keeps that token as history.
  const two = mkRepo({ [`${CAT}/cart.md`]: cat(block('CART-001', { priority: 'P1', source: T2 }), block('CART-002', { source: T1 })) });
  candidate(two, { backlog: backlogMd(two, (md) => setStatus(withdrawTask(md, 'E1-1'), 'E1-2', 'DONE')),
    catalog: { 'cart.md': cat(block('CART-001', { priority: 'P1', source: T2 }), block('CART-002', { status: 'DROPPED (D-1)', source: T1 })) } });
  exit(cli(two, '--backlog', '--candidate', CAND), 0);
});

test('crosscheck: --delta --spec prints uncovered tokens and exits 1, then 0 once cited', () => {
  const root = mkRepo({ [SPEC]: spec([`- **E1-1.AC1** — ${A1}`, `- **E1-2.AC1** — ${B1}`, `- **E1-1.AC2** — ${U1}`]) });
  let r = cli(root, '--delta', 'HEAD', '--spec', SPEC);
  exit(r, 1);
  has(r, `uncovered ${T1} (P0) — Given one line in the cart`);
  has(r, `uncovered ${T2} (P1)`);
  lacks(r, 'E1-1.AC2');
  write(root, `${CAT}/cart.md`, cat(block('CART-001', { source: T1 }), block('CART-002', { priority: 'P1', source: T2 })));
  r = cli(root, '--delta', 'HEAD', '--spec', SPEC);
  exit(r, 0);
  has(r, 'added CART-001, CART-002');
});

test('crosscheck: --delta --spec cites an unnumbered criterion with the ticket key', () => {
  const text = '[reg P1] Given a guest, when the cart opens, then it is empty.';
  const root = mkRepo({ [SPEC]: spec([`- ${text}`]) });
  let r = cli(root, '--delta', 'HEAD', '--spec', SPEC, '--key', '#7');
  exit(r, 1);
  has(r, `uncovered ${keyTok('#7', text)} (P1)`);
  r = cli(root, '--delta', 'HEAD', '--spec', SPEC);
  exit(r, 1);
  has(r, 'tagged criterion without a backlog id — pass --key <KEY>');
  write(root, `${CAT}/cart.md`, cat(block('CART-001', { priority: 'P1', source: keyTok('#7', text) })));
  exit(cli(root, '--delta', 'HEAD', '--spec', SPEC, '--key', '#7'), 0);
});

test('crosscheck: --delta --plan reports undeclared, removed and Expected changes', () => {
  const crits = [crit(`- **E1-1.AC2** — ${U1}`, 'manual — the cart')];
  const root = mkRepo({
    [SPEC]: spec([`- **E1-1.AC2** — ${U1}`]),
    [`${CAT}/cart.md`]: cat(block('CART-001', { expected: 'Old text.' }), block('CART-002')),
  });
  write(root, PLAN, plan({ criteria: crits }));
  write(root, `${CAT}/cart.md`, cat(block('CART-001', { expected: 'New text.' }), block('CART-003')));
  let r = cli(root, '--delta', 'HEAD', '--plan', PLAN);
  exit(r, 1);
  has(r, 'undeclared CART-003');
  has(r, 'undeclared CART-001');
  has(r, 'CART-002: removed — ids are never deleted; mark it DROPPED');
  has(r, 'Expected of CART-001 changed without the recorded human yes');
  write(root, `${CAT}/cart.md`, cat(block('CART-001', { expected: 'New text.' }), block('CART-002'), block('CART-003')));
  const d = digest('New text.');
  const section = (line) => `\n## Regression scenarios\n\n- base: abc1234 (main)\n- ${line}\n`;
  const variant = (decl, approved) => {
    write(root, PLAN, plan({ criteria: crits, scenarios: `added CART-003 · changed ${decl}` }));
    write(root, SPEC, spec([`- **E1-1.AC2** — ${U1}`], section(approved)));
    return cli(root, '--delta', 'HEAD', '--plan', PLAN);
  };
  exit(variant(`CART-001 (Expected ${d})`, `changed: CART-001 (Expected) — Expected ${d} approved by Operator`), 0);
  const other = digest('Other text.');
  r = variant(`CART-001 (Expected ${other})`, `changed: CART-001 (Expected) — Expected ${other} approved by Operator`);
  exit(r, 1);
  has(r, 'Expected of CART-001 differs from the approved text');
  r = variant('CART-001', `changed: CART-001 (Expected) — Expected ${d} approved by Operator`);
  has(r, 'Expected of CART-001 changed without the recorded human yes');
  r = variant(`CART-001 (Expected ${d})`, `changed: CART-001 (Expected) — Expected ${other} approved by Operator`);
  has(r, 'Expected of CART-001 changed without the recorded human yes');
  r = variant(`CART-001 (Expected ${d})`, 'CART-001 — Expected change declined');
  exit(r, 1);
  has(r, 'Expected of CART-001 changed without the recorded human yes');
});

test('crosscheck: --delta --plan binds each Proof: scenario to its criterion', () => {
  const root = mkRepo({
    [SPEC]: spec([`- **E1-1.AC1** — ${A1}`, `- **E1-2.AC1** — ${B1}`]),
    [`${CAT}/cart.md`]: cat(block('CART-001', { source: T1 }), block('CART-002', { priority: 'P1', source: T2 })),
  });
  write(root, PLAN, plan({ criteria: [crit(`- **E1-1.AC1** — ${A1}`, 'scenario — CART-002'), crit(`- **E1-2.AC1** — ${B1}`, 'scenario — CART-001')] }));
  let r = cli(root, '--delta', 'none', '--plan', PLAN);
  exit(r, 1);
  has(r, `Proof: scenario — CART-002 under E1-1.AC1: does not cite ${T1}`);
  has(r, `Proof: scenario — CART-001 under E1-2.AC1: does not cite ${T2}`);
  write(root, PLAN, plan({ criteria: [crit(`- **E1-1.AC1** — ${A1}`, 'scenario — CART-009'), crit(`- **E1-2.AC1** — ${B1}`)] }));
  r = cli(root, '--delta', 'none', '--plan', PLAN);
  has(r, 'Proof: scenario — CART-009 under E1-1.AC1: no such scenario');
  has(r, `no Proof: scenario under ${T2}`);
  write(root, PLAN, plan({ criteria: [crit(`- **E1-1.AC1** — ${A1}`, 'scenario — CART-001'), crit(`- **E1-2.AC1** — ${B1}`, 'scenario — CART-002')] }));
  exit(cli(root, '--delta', 'none', '--plan', PLAN), 0);
});

test("crosscheck: --delta --plan requires the source spec's tagged criteria", () => {
  const root = mkRepo({
    [SPEC]: spec([`- **E1-1.AC1** — ${A1}`, `- **E1-2.AC1** — ${B1}`]),
    [`${CAT}/cart.md`]: cat(block('CART-001', { source: T1 }), block('CART-002', { priority: 'P1', source: T2 })),
  });
  write(root, PLAN, plan({ criteria: [crit(`- **E1-1.AC1** — ${A1}`, 'scenario — CART-001')] }));
  let r = cli(root, '--delta', 'none', '--plan', PLAN);
  exit(r, 1);
  has(r, `tagged criterion ${T2} missing from the plan`);
  write(root, PLAN, plan({ criteria: [crit(`- **E1-1.AC1** — ${A1}`, 'scenario — CART-001'), crit(`- **E1-2.AC1** — ${B1.replace('[reg P1] ', '')}`, 'manual — x')] }));
  has(cli(root, '--delta', 'none', '--plan', PLAN), `tagged criterion ${T2} missing from the plan`);
  write(root, PLAN, plan({ source: '`.agents/specs/2026-01-01-absent.md`', criteria: [crit(`- **E1-1.AC1** — ${A1}`, 'scenario — CART-001')] }));
  r = cli(root, '--delta', 'none', '--plan', PLAN);
  exit(r, 1);
  has(r, 'source spec .agents/specs/2026-01-01-absent.md not found');
});

test('crosscheck: --delta --plan --planning accepts an id a catalog task adds', () => {
  const root = mkRepo({ [SPEC]: spec([`- **E1-1.AC1** — ${A1}`]) });
  const task = (implement) => `### Task 1 — UPDATE ${CAT}/cart.md\n\n- [ ]\n\n- **IMPLEMENT**: ${implement}\n- **EXPECT**: contains — ${CAT}/cart.md :: ### CART-005 — \n- **VALIDATE**: x\n`;
  write(root, PLAN, plan({ scenarios: 'added CART-005 · changed —', criteria: [crit(`- **E1-1.AC1** — ${A1}`, 'scenario — CART-005')], tasks: task(`add CART-005 citing \`${T1}\`.`) }));
  let r = cli(root, '--delta', 'HEAD', '--plan', PLAN, '--planning');
  exit(r, 0);
  r = cli(root, '--delta', 'HEAD', '--plan', PLAN);
  exit(r, 1);
  has(r, 'Proof: scenario — CART-005 under E1-1.AC1: no such scenario');
  has(r, `uncovered ${T1} (P0)`);
  write(root, PLAN, plan({ scenarios: 'added CART-005 · changed —', criteria: [crit(`- **E1-1.AC1** — ${A1}`, 'scenario — CART-005')], tasks: task('add CART-005.') }));
  r = cli(root, '--delta', 'HEAD', '--plan', PLAN, '--planning');
  exit(r, 1);
  has(r, 'Proof: scenario — CART-005 under E1-1.AC1: no such scenario');
});

test("crosscheck: --delta checks the covering scenario's priority against the tag", () => {
  const root = mkRepo({ [SPEC]: spec([`- **E1-1.AC1** — ${A1}`]), [`${CAT}/cart.md`]: cat(block('CART-001', { priority: 'P2', source: T1 })) });
  let r = cli(root, '--delta', 'none', '--spec', SPEC);
  exit(r, 1);
  has(r, 'priority CART-001 is P2, its criteria need P0');
  write(root, SPEC, spec([`- **E1-2.AC1** — ${B1}`]));
  write(root, `${CAT}/cart.md`, cat(block('CART-001', { priority: 'P0', source: T2 })));
  r = cli(root, '--delta', 'none', '--spec', SPEC);
  exit(r, 0);
  lacks(r, 'priority');
});

test("crosscheck: --delta uses the plan family's declarations", () => {
  const crits = [crit(`- **E1-1.AC2** — ${U1}`, 'manual — the cart')];
  const root = mkRepo({
    [SPEC]: spec([`- **E1-1.AC2** — ${U1}`]),
    '.agents/plans/done/cart-old.md': plan({ scenarios: 'added CART-009 · changed —', criteria: crits }),
  });
  write(root, '.agents/plans/active/cart-1-a.md', plan({ scenarios: 'added CART-001 · changed —', criteria: crits }));
  write(root, '.agents/plans/active/cart-2-b.md', plan({ scenarios: 'added CART-002 · changed —', criteria: crits }));
  write(root, `${CAT}/cart.md`, cat(block('CART-001'), block('CART-002')));
  const r = cli(root, '--delta', 'HEAD', '--plan', '.agents/plans/active/cart-1-a.md');
  exit(r, 0);
  lacks(r, 'undeclared');
  lacks(r, 'declared but unchanged');
  remove(root, '.agents/plans/active/cart-2-b.md');
  has(cli(root, '--delta', 'HEAD', '--plan', '.agents/plans/active/cart-1-a.md'), 'undeclared CART-002');
});

test('crosscheck: --delta none skips only the historical checks', () => {
  const root = mkRepo({ [SPEC]: spec([`- **E1-1.AC1** — ${A1}`]), [`${CAT}/cart.md`]: cat(block('CART-001')) });
  remove(root, `${CAT}/cart.md`);
  const r = cli(root, '--delta', 'none', '--spec', SPEC);
  exit(r, 1);
  has(r, 'delta: not evaluated — no base');
  has(r, `uncovered ${T1}`);
  lacks(r, 'removed');
});

test('crosscheck: a Proof: scenario stays deferred even with a GREEN record', () => {
  const cfg = JSON.parse(fs.readFileSync(path.join(FIX, 'run/root/.claude/regression.json'), 'utf8'));
  assert.equal(validateConfig(cfg).length, 0);
  const root = mkRepo({ [SPEC]: spec([`- **E1-1.AC1** — ${A1}`]), [`${CAT}/cart.md`]: cat(block('CART-001', { source: T1 })) });
  write(root, '.claude/regression.json', cfg);
  write(root, PLAN, plan({ criteria: [crit(`- **E1-1.AC1** — ${A1}`, 'scenario — CART-001')] }));
  const head = git(root, 'rev-parse', 'HEAD');
  write(root, '.agents/regression/runs/20261127-test/record.json', { schema: 1, verdict: 'GREEN', env: 'test', build_sha: head,
    cases: [{ scenario: 'CART-001', project: 'desktop-chrome', status: 'passed' }, { scenario: 'CART-001', project: 'mobile-safari', status: 'passed' }] });
  const r = cli(root, '--delta', 'none', '--plan', PLAN);
  exit(r, 0);
  has(r, 'proof CART-001 deferred');
  lacks(r, 'green');
});

test('crosscheck: an invalid catalog stops both modes with its validation errors', () => {
  const root = mkRepo({ [SPEC]: spec([`- **E1-1.AC1** — ${A1}`]), [`${CAT}/cart.md`]: cat(block('CART-001', { priority: 'P9', source: T1 })) });
  for (const args of [['--backlog'], ['--delta', 'HEAD'], ['--delta', 'none', '--spec', SPEC]]) {
    const r = cli(root, ...args);
    exit(r, 1);
    has(r, `${CAT}/cart.md:4: unknown Priority value P9`);
    lacks(r, 'uncovered');
  }
});

test('crosscheck: --delta --plan resolves a plan moved from active to done', () => {
  const root = mkRepo({ [SPEC]: spec([`- **E1-1.AC1** — ${A1}`]) });
  write(root, PLAN, plan({ criteria: [crit(`- **E1-1.AC1** — ${A1}`, 'scenario — CART-001')] }));
  const before = cli(root, '--delta', 'none', '--plan', PLAN);
  fs.mkdirSync(path.join(root, '.agents/plans/done'), { recursive: true });
  fs.renameSync(path.join(root, PLAN), path.join(root, '.agents/plans/done/cart.md'));
  const after = cli(root, '--delta', 'none', '--plan', PLAN);
  assert.equal(after.status, before.status);
  assert.equal(after.stdout.replaceAll('/plans/done/', '/plans/active/'), before.stdout);
  has(after, 'no such scenario');
});

test('crosscheck: a quick plan with no source spec is checked on its own declarations', () => {
  const root = mkRepo({});
  write(root, PLAN, plan({ source: 'none (quick mode)', criteria: [crit(`- **AC-1** — ${U1}`, 'manual — the cart')] }));
  exit(cli(root, '--delta', 'HEAD', '--plan', PLAN), 0);
  write(root, `${CAT}/cart.md`, cat(block('CART-001')));
  const r = cli(root, '--delta', 'HEAD', '--plan', PLAN);
  exit(r, 1);
  has(r, 'undeclared CART-001');
});

test('crosscheck: a multiline criterion is hashed with its continuation lines', () => {
  const head = '[reg P0] Given one line in the cart, when the quantity is raised,';
  const cont = 'then the line total follows the new quantity.';
  const root = mkRepo({ '.agents/backlog/E1-cart.md': epic(`- **E1-1.AC1** — ${head}\n  ${cont}`) });
  const old = tok('E1-1.AC1', head);
  const cur = currentFingerprint(root, 'E1-1.AC1').fp;
  const now = `E1-1.AC1 [${cur}]`;
  assert.notEqual(old, now);
  assert.equal(now, tok('E1-1.AC1', `${head} ${cont}`));
  write(root, SPEC, spec([`- **E1-1.AC1** — ${head}`, `  ${cont}`]));
  write(root, PLAN, plan({ criteria: [`- **E1-1.AC1** — ${head}\n  ${cont}\n  - Proof: scenario — CART-001`] }));
  write(root, `${CAT}/cart.md`, cat(block('CART-001', { source: old })));
  let r = cli(root, '--delta', 'none', '--spec', SPEC);
  has(r, `uncovered ${now}`);
  r = cli(root, '--delta', 'none', '--plan', PLAN);
  has(r, `does not cite ${now}`);
  r = cli(root, '--backlog');
  has(r, `current [${cur}]`);
});

test('crosscheck: --delta reads the base catalog path from the base regression.json', () => {
  const root = mkRepo({
    '.claude/regression.json': { version: 1, catalog: { path: 'cat-a', areas: { CART: 'Cart' } } },
    'cat-a/cart.md': cat(block('CART-001', { expected: 'Old text.' }), block('CART-002')),
    [SPEC]: spec([`- **E1-1.AC2** — ${U1}`]),
  });
  write(root, '.claude/regression.json', { version: 1, catalog: { path: 'cat-b', areas: { CART: 'Cart' } } });
  remove(root, 'cat-a');
  write(root, 'cat-b/more.md', cat(block('CART-001', { expected: 'New text.' })));
  const r = cli(root, '--delta', 'HEAD', '--spec', SPEC);
  exit(r, 1);
  has(r, 'changed CART-001 (Expected)');
  has(r, 'Expected of CART-001 changed without the recorded human yes');
  has(r, 'CART-002: removed');
  lacks(r, 'added');
});

test('crosscheck: --delta reads a ./-prefixed catalog path on the base like the tree', () => {
  const root = mkRepo({
    '.claude/regression.json': { version: 1, catalog: { path: `./${CAT}/`, areas: { CART: 'Cart' } } },
    [`${CAT}/cart.md`]: cat(block('CART-001')),
  });
  let r = cli(root, '--delta', 'HEAD');
  exit(r, 0);
  lacks(r, 'added');
  write(root, `${CAT}/cart.md`, cat(block('CART-002')));
  r = cli(root, '--delta', 'HEAD');
  exit(r, 1);
  has(r, 'added CART-002');
  has(r, 'CART-001: removed — ids are never deleted; mark it DROPPED');
});

test('crosscheck: a scenario citing two criteria of one ticket covers both', () => {
  const t1 = '[reg P1] Given a guest, when the cart opens, then it is empty.';
  const t2 = '[reg P1] Given a guest, when a line is added, then the badge counts it.';
  const root = mkRepo({ [SPEC]: spec([`- ${t1}`, `- ${t2}`]) });
  write(root, `${CAT}/cart.md`, cat(block('CART-001', { priority: 'P1', source: `${keyTok('#7', t1)} · ${keyTok('#7', t2)}` })));
  exit(cli(root, '--delta', 'none', '--spec', SPEC, '--key', '#7'), 0);
  write(root, `${CAT}/cart.md`, cat(block('CART-001', { priority: 'P1', source: keyTok('#7', t1) })));
  const r = cli(root, '--delta', 'none', '--spec', SPEC, '--key', '#7');
  exit(r, 1);
  has(r, `uncovered ${keyTok('#7', t2)}`);
});

test('crosscheck: a catalog path outside the repository is refused', () => {
  for (const p of ['../outside', '/abs/scenarios']) {
    const root = mkRepo({ '.claude/regression.json': { version: 1, catalog: { path: p, areas: { CART: 'Cart' } } } });
    for (const args of [['--backlog'], ['--delta', 'HEAD']]) {
      const r = cli(root, ...args);
      exit(r, 2);
      has(r, 'catalog.path must be a repo-relative path inside the repository');
    }
    assert.ok(!fs.existsSync(path.resolve(root, '../outside')));
  }
});

test("crosscheck: nested Proof lines do not change a criterion's token", () => {
  const head = '[reg P0] Given one line in the cart, when the quantity is raised,';
  const cont = 'then the line total follows.';
  const root = mkRepo({ [SPEC]: spec([`- **E1-1.AC1** — ${head}`, `  ${cont}`]) });
  write(root, PLAN, plan({ criteria: [`- **E1-1.AC1** — ${head}\n  ${cont}\n  - Proof: test — t.test.mjs :: a case\n    that wraps\n  - Proof: scenario — CART-001`] }));
  const want = tok('E1-1.AC1', `${head} ${cont}`);
  has(cli(root, '--delta', 'none', '--spec', SPEC), `uncovered ${want}`);
  has(cli(root, '--delta', 'none', '--plan', PLAN), `uncovered ${want}`);
});

test('crosscheck: --backlog --candidate refuses dropping a citation of an active criterion', () => {
  const root = mkRepo({ [`${CAT}/cart.md`]: cat(block('CART-001', { source: `${T1} · ${T2}` })) });
  const retired = backlogMd(root, (md) => setStatus(withdrawTask(md, 'E1-1'), 'E1-2', 'WIP'));
  candidate(root, { backlog: retired, catalog: { 'cart.md': cat(block('CART-001', { source: T1 })) } });
  let r = cli(root, '--backlog', '--candidate', CAND);
  exit(r, 1);
  has(r, `CART-001: candidate drops the citation of active ${T2}`);
  candidate(root, { backlog: retired, catalog: { 'cart.md': cat(block('CART-001', { status: 'DROPPED (D-1)', source: `${T1} · ${T2}` })) } });
  r = cli(root, '--backlog', '--candidate', CAND);
  exit(r, 1);
  has(r, `CART-001: candidate drops a scenario still citing active ${T2}`);
});

test("crosscheck: completeness spans the split's peer plans", () => {
  const root = mkRepo({
    [SPEC]: spec([`- **E1-1.AC1** — ${A1}`, `- **E1-2.AC1** — ${B1}`]),
    [`${CAT}/cart.md`]: cat(block('CART-001', { source: T1 }), block('CART-002', { priority: 'P1', source: T2 })),
  });
  write(root, '.agents/plans/active/cart-1-a.md', plan({ criteria: [crit(`- **E1-1.AC1** — ${A1}`, 'scenario — CART-001')] }));
  write(root, '.agents/plans/active/cart-2-b.md', plan({ criteria: [crit(`- **E1-2.AC1** — ${B1}`, 'scenario — CART-002')] }));
  let r = cli(root, '--delta', 'none', '--plan', '.agents/plans/active/cart-1-a.md');
  exit(r, 0);
  lacks(r, 'missing from the plan');
  remove(root, '.agents/plans/active/cart-2-b.md');
  r = cli(root, '--delta', 'none', '--plan', '.agents/plans/active/cart-1-a.md');
  exit(r, 1);
  has(r, `tagged criterion ${T2} missing from the plan`);
});

test('crosscheck: a malformed tag in a tracker-only spec is an error', () => {
  const root = mkRepo({ [SPEC]: spec(['- [reg P0]Given a guest, when the cart opens, then it is empty.']) });
  remove(root, '.agents/backlog.md');
  remove(root, '.agents/backlog');
  const r = cli(root, '--delta', 'none', '--spec', SPEC, '--key', '#7');
  exit(r, 1);
  has(r, `${SPEC}:7: the tag must be followed by a space`);
});

test('crosscheck: --backlog --candidate refuses a removed block or a changed Expected', () => {
  const root = mkRepo({ [`${CAT}/cart.md`]: cat(block('CART-001', { source: T1 }), block('CART-002')) });
  candidate(root, { catalog: { 'cart.md': cat(block('CART-001', { source: T1 })) } });
  let r = cli(root, '--backlog', '--candidate', CAND);
  exit(r, 1);
  has(r, 'CART-002: candidate removes a scenario — ids are never deleted');
  candidate(root, { catalog: { 'cart.md': cat(block('CART-001', { source: T1 }), block('CART-002', { expected: 'Something else.' })) } });
  r = cli(root, '--backlog', '--candidate', CAND);
  exit(r, 1);
  has(r, 'CART-002: candidate changes Expected — /update-backlog never does');
});

test('crosscheck: a plain sub-bullet stays in the criterion text for every reader', () => {
  const root = mkRepo({ [SPEC]: spec([`- **E1-1.AC1** — ${A1}`, '  - and the badge shows the new count']) });
  write(root, '.agents/backlog.md', backlogMd(root, (md) => md.replace(/(\| E1-1 \|.*\| TODO \| — \| )— \|/, `$1${SPEC} |`)));
  commit(root);
  const cur = currentFingerprint(root, 'E1-1.AC1').fp;
  const want = `E1-1.AC1 [${cur}]`;
  assert.equal(want, tok('E1-1.AC1', `${A1} - and the badge shows the new count`));
  write(root, PLAN, plan({ criteria: [`- **E1-1.AC1** — ${A1}\n  - and the badge shows the new count\n  - Proof: scenario — CART-001`] }));
  has(cli(root, '--delta', 'none', '--spec', SPEC), `uncovered ${want}`);
  has(cli(root, '--delta', 'none', '--plan', PLAN), `uncovered ${want}`);
});

test("crosscheck: the plan's tag must equal the source spec's", () => {
  const root = mkRepo({ [SPEC]: spec([`- **E1-1.AC1** — ${A1}`]), [`${CAT}/cart.md`]: cat(block('CART-001', { priority: 'P2', source: T1 })) });
  write(root, PLAN, plan({ criteria: [crit(`- **E1-1.AC1** — ${A1.replace('[reg P0]', '[reg P2]')}`, 'scenario — CART-001')] }));
  const r = cli(root, '--delta', 'none', '--plan', PLAN);
  exit(r, 1);
  has(r, `tag of ${T1} is P2 in the plan, P0 in the source spec`);
});

test("crosscheck: a merge of the line into the branch attributes only the Task's own changes", () => {
  const crits = [crit(`- **E1-1.AC2** — ${U1}`, 'manual — the cart')];
  const root = mkRepo({ [SPEC]: spec([`- **E1-1.AC2** — ${U1}`]), [`${CAT}/cart.md`]: cat(block('CART-001')) });
  git(root, 'checkout', '-qb', 'task');
  write(root, `${CAT}/cart.md`, cat(block('CART-001'), block('CART-011')));
  write(root, PLAN, plan({ scenarios: 'added CART-011 · changed —', criteria: crits }));
  commit(root, 'task');
  git(root, 'checkout', '-q', 'main');
  write(root, `${CAT}/more.md`, cat(block('CART-010', { expected: 'First text.' })));
  commit(root, 'line adds CART-010');
  write(root, `${CAT}/more.md`, cat(block('CART-010', { expected: 'Second text.' })));
  commit(root, 'line edits CART-010');
  git(root, 'checkout', '-q', 'task');
  git(root, 'merge', '-q', '--no-edit', 'main');
  const r = cli(root, '--delta', 'main', '--plan', PLAN);
  exit(r, 0);
  lacks(r, 'CART-010');
  has(r, 'added CART-011');
});

test('crosscheck: a catalog directory behind a symlink outside the repository is refused', () => {
  const outside = fs.mkdtempSync(path.join(os.tmpdir(), 'crosscheck-outside-'));
  const root = mkRepo({ '.claude/regression.json': { version: 1, catalog: { path: 'link/scenarios', areas: { CART: 'Cart' } } } });
  fs.symlinkSync(outside, path.join(root, 'link'));
  for (const args of [['--backlog'], ['--delta', 'HEAD']]) {
    const r = cli(root, ...args);
    exit(r, 2);
    has(r, 'catalog path resolves outside the repository: link/scenarios');
  }
  assert.deepEqual(fs.readdirSync(outside), []);
});

test('crosscheck: an umbrella sub-step resolves its source spec through its parent', () => {
  const root = mkRepo({
    [SPEC]: spec([`- **E1-1.AC1** — ${A1}`, `- **E1-2.AC1** — ${B1}`]),
    [`${CAT}/cart.md`]: cat(block('CART-001', { source: T1 })),
  });
  write(root, '.agents/plans/active/cart.md', plan({ criteria: [] }));
  write(root, '.agents/plans/active/cart-1-a.md', plan({ parent: '[cart.md](./cart.md)', criteria: [crit(`- **E1-1.AC1** — ${A1}`, 'scenario — CART-001')] }));
  const r = cli(root, '--delta', 'none', '--plan', '.agents/plans/active/cart-1-a.md');
  exit(r, 1);
  has(r, `tagged criterion ${T2} missing from the plan`);
  lacks(r, 'uncovered');
});

test('crosscheck: two tagged criteria with the same token are ambiguous', () => {
  const root = mkRepo({ [SPEC]: spec(['- [reg P1] Open [the cart](a.md) page.', '- [reg P1] Open [the cart](b.md) page.']) });
  const r = cli(root, '--delta', 'none', '--spec', SPEC, '--key', '#7');
  exit(r, 1);
  has(r, `ambiguous ${keyTok('#7', '[reg P1] Open the cart page.')} — criteria at 7, 8 hash the same; reword one`);
  lacks(r, 'uncovered');
});
