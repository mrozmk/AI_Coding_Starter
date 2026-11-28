// Unit tests of the regression kit (.claude/lib/regression/): catalog format and validator, the
// computed automation state, --status/--json, setup.mjs catalog|baseline|check|env, config and the
// qa-env host. Fixture or temp roots only (--root) — never the real ~ or this repo's regression.json.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

import {
  catalogFiles, parseCatalog, validateCatalog, sourceTokens, automationState, statusReport,
  extractFingerprintBlock, fingerprint, currentFingerprint, blockTexts,
} from '../regression/catalog.mjs';
import { loadConfig, validateConfig, catalogSettings, resolveEnvBaseUrl, isBaseUrl, envKind } from '../regression/config.mjs';
import { checkFoundation } from '../regression/setup.mjs';
import { readBacklogFiles, parseBacklog } from '../backlog-check.mjs';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const REPO = path.join(HERE, '../../..');
const LIB = path.join(HERE, '../regression');
const FIX = path.join(HERE, 'fixtures/regression');
const FP_REF = path.join(REPO, '.agents/reference/qa-evidence-families.md');
const CAT = '.agents/regression/scenarios';
const NODE_PATH = `${path.dirname(process.execPath)}:${process.env.PATH ?? ''}`;

function mkRoot(files = {}) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'regression-test-'));
  for (const [rel, text] of Object.entries(files)) {
    if (text === undefined) continue;
    fs.mkdirSync(path.dirname(path.join(root, rel)), { recursive: true });
    fs.writeFileSync(path.join(root, rel), typeof text === 'string' ? text : `${JSON.stringify(text, null, 2)}\n`);
  }
  return root;
}

/** A copy of a fixture root, with the real §7c reference unless `withRef` is false. */
function copyFixture(name, { withRef = true } = {}) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'regression-test-'));
  fs.cpSync(path.join(FIX, name), root, { recursive: true });
  if (withRef) {
    fs.mkdirSync(path.join(root, '.agents/reference'), { recursive: true });
    fs.copyFileSync(FP_REF, path.join(root, '.agents/reference/qa-evidence-families.md'));
  }
  return root;
}

const run = (script, args, env = {}) => spawnSync(process.execPath, [path.join(LIB, script), ...args], { encoding: 'utf8', env: { ...process.env, ...env } });
const CONFIG = { version: 1, catalog: { areas: { CART: 'Cart', PDP: 'Product page' } } };

/**
 * One scenario block. Line offsets from its heading: +1 the Priority line, +2 Goal, +3 Steps,
 * +4 the step item (only with the default list Steps), then Expected, then Source.
 */
function scenario(id, o = {}) {
  const head = [`**Priority:** ${o.priority ?? 'P1'}`, `**Viewport:** ${o.viewport ?? 'both'}`, `**Status:** ${o.status ?? 'READY'}`];
  if (o.effect !== null) head.push(`**Effect:** ${o.effect ?? 'read'}`);
  const lines = [`### ${id}${o.title === '' ? '' : ` — ${o.title ?? 'Open the page'}`}`, `- ${head.join(' · ')}`, '- **Goal:** Open the page and see it.'];
  if (o.steps === undefined) lines.push('- **Steps:**', '  1. Open the page.');
  else lines.push(`- **Steps:** ${o.steps}`);
  lines.push(`- **Expected:** ${o.expected ?? 'The page shows its heading.'}`);
  lines.push(`- **Source:** ${o.source ?? 'live'} · **Spec:** ${o.spec ?? '—'}`);
  return lines.join('\n');
}
/** A catalog file: `# Area`, a blank line, then the blocks (first heading on line 3, blocks a blank line apart). */
const catalogFile = (...blocks) => `# Area\n\n${blocks.join('\n\n')}\n`;

function errorsOf(files, config = CONFIG) {
  const root = mkRoot({ '.claude/regression.json': config, ...Object.fromEntries(Object.entries(files).map(([n, t]) => [`${CAT}/${n}`, t])) });
  const settings = catalogSettings(loadConfig(root).config);
  return validateCatalog(parseCatalog(root, catalogFiles(root, settings)), settings).map((e) => `${e.file}:${e.line}: ${e.message}`);
}
const has = (errors, re) => assert.ok(errors.some((e) => re.test(e)), `expected ${re} in:\n${errors.join('\n')}`);
const rowOf = (json, id) => json.scenarios.find((s) => s.id === id);

// ---------------------------------------------------------------------------------------------
// Validator — every rejection names the file and the line
// ---------------------------------------------------------------------------------------------

test('rejects duplicate id with file and line', () => {
  const errors = errorsOf({ 'cart.md': catalogFile(scenario('CART-001'), scenario('CART-001')) });
  assert.deepEqual(errors, [`${CAT}/cart.md:11: duplicate id CART-001 (also at ${CAT}/cart.md:3)`]);
  const root = mkRoot({ '.claude/regression.json': CONFIG, [`${CAT}/cart.md`]: catalogFile(scenario('CART-001'), scenario('CART-001')) });
  const r = run('catalog.mjs', ['--root', root]);
  assert.equal(r.status, 1);
  assert.match(r.stdout, new RegExp(`^${CAT}/cart\\.md:11: duplicate id CART-001`, 'm'));
});

test('rejects malformed id with file and line', () => {
  const errors = errorsOf({ 'cart.md': catalogFile(scenario('cart-1'), scenario('XYZ-001')) });
  has(errors, new RegExp(`^${CAT}/cart\\.md:3: malformed id cart-1 `));
  has(errors, new RegExp(`^${CAT}/cart\\.md:11: unknown area code XYZ in id XYZ-001`));
});

test('rejects unknown enum value with file and line', () => {
  const errors = errorsOf({ 'cart.md': catalogFile(scenario('CART-001', { viewport: 'tablet' })), 'pdp.md': catalogFile(scenario('PDP-001', { effect: 'delete' })) });
  has(errors, new RegExp(`^${CAT}/cart\\.md:4: unknown Viewport value tablet`));
  has(errors, new RegExp(`^${CAT}/pdp\\.md:4: unknown Effect value delete`));
});

test('rejects missing Effect with file and line', () => {
  const errors = errorsOf({ 'cart.md': catalogFile(scenario('CART-001', { effect: null })) });
  assert.deepEqual(errors, [`${CAT}/cart.md:3: missing required field Effect`]);
});

test('rejects READY with empty Steps or Expected', () => {
  const errors = errorsOf({ 'cart.md': catalogFile(scenario('CART-001', { steps: '—' })), 'pdp.md': catalogFile(scenario('PDP-001', { expected: '—' })) });
  has(errors, new RegExp(`^${CAT}/cart\\.md:6: READY scenario with empty Steps$`));
  has(errors, new RegExp(`^${CAT}/pdp\\.md:8: READY scenario with empty Expected$`));
  // Not READY: empty Steps and Expected are allowed.
  assert.deepEqual(errorsOf({ 'cart.md': catalogFile(scenario('CART-001', { status: 'BLOCKED (E1-2)', steps: '—', expected: '—' })) }), []);
});

test('rejects BLOCKED without reference', () => {
  const errors = errorsOf({ 'cart.md': catalogFile(scenario('CART-001', { status: 'BLOCKED' }), scenario('CART-002', { status: 'DROPPED' })) });
  has(errors, new RegExp(`^${CAT}/cart\\.md:4: BLOCKED without a reference`));
  has(errors, new RegExp(`^${CAT}/cart\\.md:12: DROPPED without a reason`));
  assert.deepEqual(errorsOf({ 'cart.md': catalogFile(scenario('CART-001', { status: 'BLOCKED (#12)' }), scenario('CART-002', { status: 'BLOCKED (ABC-7)' })) }), []);
});

test('rejects reused id of a DROPPED scenario', () => {
  const errors = errorsOf({ 'cart.md': catalogFile(scenario('CART-001', { status: 'DROPPED (D-3)' }), scenario('CART-001')) });
  assert.deepEqual(errors, [`${CAT}/cart.md:11: id CART-001 reuses the id of DROPPED scenario at ${CAT}/cart.md:3`]);
});

test('rejects a reused DROPPED id placed above the DROPPED block', () => {
  const errors = errorsOf({ 'cart.md': catalogFile(scenario('CART-001'), scenario('CART-001', { status: 'DROPPED (D-3)' })) });
  assert.deepEqual(errors, [`${CAT}/cart.md:3: id CART-001 reuses the id of DROPPED scenario at ${CAT}/cart.md:11`]);
});

test('accepts a Source wrapped onto a continuation line', () => {
  const block = scenario('CART-001', { source: 'FL-1 · FL-2 ·' }).replace('· **Spec:** —', '\n  live\n- **Spec:** —');
  assert.deepEqual(errorsOf({ 'cart.md': catalogFile(block) }), []);
});

test('a heading without the em-dash separator keeps its id', () => {
  const errors = errorsOf({ 'cart.md': catalogFile(scenario('CART-001').replace('### CART-001 — ', '### CART-001 - ')) });
  assert.deepEqual(errors, [`${CAT}/cart.md:3: missing title — expected \`### <ID> — <title>\``]);
});

test('rejects two DROPPED blocks sharing an id', () => {
  const errors = errorsOf({ 'cart.md': catalogFile(scenario('CART-001', { status: 'DROPPED (D-3)' }), scenario('CART-001', { status: 'DROPPED (no longer sold)' })) });
  assert.deepEqual(errors, [`${CAT}/cart.md:11: duplicate id CART-001 (also at ${CAT}/cart.md:3)`]);
});

test('rejects malformed Source and Spec with file and line', () => {
  const errors = errorsOf({
    'cart.md': catalogFile(
      scenario('CART-001', { source: 'E1-1.AC1' }),
      scenario('CART-002', { spec: '/abs/cart.spec.ts › CART-002 — x' }),
      scenario('CART-003', { spec: 'e2e/cart.spec.ts › CART-999 — x' }),
      scenario('CART-004', { spec: 'e2e/cart.spec.ts' }),
    ),
  });
  has(errors, new RegExp(`^${CAT}/cart\\.md:9: criterion id E1-1\\.AC1 needs its fingerprint`));
  has(errors, new RegExp(`^${CAT}/cart\\.md:17: malformed Spec — /abs/cart\\.spec\\.ts must be repo-relative`));
  has(errors, new RegExp(`^${CAT}/cart\\.md:25: Spec title must start with the scenario id CART-003`));
  has(errors, new RegExp(`^${CAT}/cart\\.md:33: malformed Spec — expected`));
});

test('rejects an unknown or repeated field', () => {
  const block = `${scenario('CART-001')}\n- **Owner:** someone\n- **Goal:** again`;
  const errors = errorsOf({ 'cart.md': catalogFile(block) });
  has(errors, new RegExp(`^${CAT}/cart\\.md:10: unknown field Owner`));
  has(errors, new RegExp(`^${CAT}/cart\\.md:11: duplicate field Goal \\(also at line 5\\)`));
});

test('parses the normative Source and Spec line', () => {
  const block = `### CART-004 — Change quantity up to the maximum
- **Priority:** P0 · **Viewport:** both · **Status:** READY · **Effect:** write
- **Data:** signed-in test account with one in-stock line in the cart
- **Goal:** Raise one cart line to the maximum quantity and confirm the totals follow.
- **Steps:**
  1. Open the cart with one line in it.
  2. Increase the quantity with the stepper until it stops.
- **Expected:** The stepper stops at the maximum, the increase control is disabled, and the line
  total equals unit price × quantity.
- **Source:** E2-3.AC2 [a1b2c3] · FL-2.A4 · **Spec:** —`;
  const root = mkRoot({ '.claude/regression.json': CONFIG, [`${CAT}/cart.md`]: `# Cart\r\n\r\n${block.replace(/\n/g, '\r\n')}\r\n` });
  const settings = catalogSettings(loadConfig(root).config);
  const [b] = parseCatalog(root, catalogFiles(root, settings));
  assert.equal(b.fields.Source.value, 'E2-3.AC2 [a1b2c3] · FL-2.A4');
  assert.equal(b.fields.Spec.value, '—');
  assert.equal(b.fields.Spec.line, 12);
  assert.deepEqual(sourceTokens(b.fields.Source.value).map((t) => [t.kind, t.id]), [['criterion', 'E2-3.AC2'], ['flow', 'FL-2.A4']]);
  assert.equal(b.fields.Steps.value, '1. Open the cart with one line in it.\n2. Increase the quantity with the stepper until it stops.');
  assert.match(b.fields.Expected.value, /and the line\ntotal equals/);
  assert.deepEqual(validateCatalog([b], settings), []);
});

// ---------------------------------------------------------------------------------------------
// Valid catalogs, not adopted, --status ≡ --json
// ---------------------------------------------------------------------------------------------

test('accepts a valid three-file catalog', () => {
  const root = path.join(FIX, 'valid');
  const { md, epicFiles } = readBacklogFiles(path.join(root, '.agents/backlog.md'));
  assert.deepEqual(parseBacklog(md, { epicFiles }).problems, [], 'the backlog fixture must parse cleanly');
  const settings = catalogSettings(loadConfig(root).config);
  const files = catalogFiles(root, settings);
  assert.deepEqual(files, [`${CAT}/account.md`, `${CAT}/cart.md`, `${CAT}/pdp.md`], 'README.md is skipped');
  assert.deepEqual(validateCatalog(parseCatalog(root, files), settings), []);
  const r = run('catalog.mjs', ['--root', root]);
  assert.equal(r.status, 0, r.stdout + r.stderr);
  assert.equal(r.stdout.trim(), 'catalog ok — 6 scenarios in 3 files');
});

test('accepts a live-only catalog', () => {
  const r = run('catalog.mjs', ['--root', path.join(FIX, 'live-only'), '--json']);
  assert.equal(r.status, 0, r.stdout + r.stderr);
  const json = JSON.parse(r.stdout);
  assert.deepEqual(json.errors, []);
  assert.equal(json.scenarios.length, 2);
  assert.ok(json.scenarios.every((s) => s.automation === 'missing'));
  assert.equal(json.counts.coverage.P0.planned, 'n/a', 'no backlog → planned n/a');
});

test('status and json report the same counts', () => {
  const root = copyFixture('valid');
  const j = run('catalog.mjs', ['--root', root, '--json']);
  const s = run('catalog.mjs', ['--root', root, '--status']);
  assert.equal(j.status, 0, j.stdout + j.stderr);
  assert.equal(s.status, 0, s.stdout + s.stderr);
  const { counts } = JSON.parse(j.stdout);
  for (const [status, byP] of Object.entries(counts.by_status_priority)) {
    for (const [p, n] of Object.entries(byP)) {
      assert.match(s.stdout, new RegExp(`^  ${status}\\s+.*\\b${p}=${n}\\b`, 'm'), `${status} ${p}`);
    }
  }
  for (const [p, c] of Object.entries(counts.coverage)) {
    assert.match(s.stdout, new RegExp(`^  ${p}  planned=${c.planned} written=${c.written} automated=${c.automated}$`, 'm'));
  }
  assert.match(s.stdout, new RegExp(`^without spec \\(READY, automation missing\\): ${counts.without_spec.join(', ') || 'none'}$`, 'm'));
  assert.match(s.stdout, new RegExp(`^stale: ${counts.stale.join(', ') || 'none'}$`, 'm'));
  assert.equal(counts.coverage.P0.automated, 1);
  assert.equal(run('catalog.mjs', ['--root', root, '--json', '--status']).status, 2, '--json with --status is a usage error');
});

test('not adopted exits 0', () => {
  const root = path.join(FIX, 'not-adopted');
  const r = run('catalog.mjs', ['--root', root]);
  assert.equal(r.status, 0);
  assert.equal(r.stdout.trim(), 'regression not adopted');
  const j = run('catalog.mjs', ['--root', root, '--json']);
  assert.equal(j.status, 0);
  assert.deepEqual(JSON.parse(j.stdout), { adopted: false, message: 'regression not adopted' });
  const s = run('catalog.mjs', ['--root', root, '--status']);
  assert.equal(s.status, 0);
  assert.equal(s.stdout.trim(), 'regression not adopted');
});

test('invalid config exits 2', () => {
  const root = mkRoot({ '.claude/regression.json': '{ not json' });
  assert.equal(run('catalog.mjs', ['--root', root]).status, 2);
  const typed = mkRoot({ '.claude/regression.json': { catalog: { areas: { cart: 'Cart' } } } });
  const r = run('catalog.mjs', ['--root', typed]);
  assert.equal(r.status, 2);
  assert.match(r.stderr, /catalog\.areas\.cart: area code must match/);
});

// ---------------------------------------------------------------------------------------------
// Automation state — computed against the current criterion, never stored
// ---------------------------------------------------------------------------------------------

function cartRow(root) {
  const r = run('catalog.mjs', ['--root', root, '--json']);
  assert.equal(r.status, 0, r.stdout + r.stderr);
  return JSON.parse(r.stdout);
}

test('verified when header equals current fingerprint', () => {
  const row = rowOf(cartRow(copyFixture('valid')), 'CART-001');
  assert.equal(row.automation, 'verified', row.automation_reason);
});

test('stale when only the criterion changes', () => {
  const root = copyFixture('valid');
  assert.equal(rowOf(cartRow(root), 'CART-001').automation, 'verified');
  const epic = path.join(root, '.agents/backlog/E1-cart.md');
  fs.writeFileSync(epic, fs.readFileSync(epic, 'utf8').replace('then the line total follows.', 'then the line total and the cart total follow.'));
  const row = rowOf(cartRow(root), 'CART-001');
  assert.equal(row.automation, 'stale');
  assert.match(row.automation_reason, /E1-1\.AC1: header fingerprint \[5def01\] differs from the current criterion/);
});

test('missing when Spec is a dash', () => {
  const json = cartRow(copyFixture('valid'));
  assert.equal(rowOf(json, 'CART-002').automation, 'missing');
  assert.equal(rowOf(json, 'CART-002').automation_reason, 'Spec: —');
  assert.deepEqual(json.counts.without_spec, ['ACC-001', 'CART-002', 'PDP-001']);
});

test('stale when the fingerprint block is missing', () => {
  const row = rowOf(cartRow(copyFixture('valid', { withRef: false })), 'CART-001');
  assert.equal(row.automation, 'stale');
  assert.match(row.automation_reason, /fingerprint unavailable/);
});

test('stale without a header, after a withdrawal and without a backlog', () => {
  const noHeader = copyFixture('valid');
  const spec = path.join(noHeader, 'e2e/regression/cart.spec.ts');
  fs.writeFileSync(spec, fs.readFileSync(spec, 'utf8').replace(/^\/\/ regression:.*\n/m, ''));
  assert.match(rowOf(cartRow(noHeader), 'CART-001').automation_reason, /no \/\/ regression: header for CART-001/);

  const withdrawn = copyFixture('valid');
  const epic = path.join(withdrawn, '.agents/backlog/E1-cart.md');
  fs.writeFileSync(epic, fs.readFileSync(epic, 'utf8').replace('- **E1-1.AC1** — [reg P0]', '- **E1-1.AC1** — (withdrawn) [reg P0]'));
  const w = rowOf(cartRow(withdrawn), 'CART-001');
  assert.equal(w.automation, 'stale');
  assert.match(w.automation_reason, /criterion E1-1\.AC1 withdrawn/);

  const noBacklog = copyFixture('valid');
  fs.rmSync(path.join(noBacklog, '.agents/backlog.md'));
  assert.match(rowOf(cartRow(noBacklog), 'CART-001').automation_reason, /not resolvable/);
});

test('criterion fingerprint matches the original bullet', () => {
  const block = extractFingerprintBlock(REPO);
  assert.ok(block.block, block.error);
  const bullets = {
    'E1-1.AC1': '- **E1-1.AC1** — [reg P0] Open the menu.',
    'E1-1.AC2': '- **E1-1.AC2**: Close the menu with `Esc`.',
    'E1-1.AC3': '- **E1-1.AC3** – Keep the focus on the trigger.',
    'E1-1.AC4': '- **E1-1.AC4** — Given a long criterion,\n  then it wraps onto a second line.',
  };
  const root = copyFixture('valid');
  const epic = `# E1 — Cart\n\n## E1-1 — Change quantity\n**Summary:** x.\n**Goal:** x.\n**In scope:** x.\n**Out of scope:** x.\n### Acceptance criteria\n${Object.values(bullets).join('\n')}\n`;
  fs.writeFileSync(path.join(root, '.agents/backlog/E1-cart.md'), epic);
  const ctx = {};
  for (const [id, bullet] of Object.entries(bullets)) {
    const original = fingerprint(block.block, bullet);
    assert.match(original ?? '', /^[0-9a-f]{6}$/);
    assert.deepEqual(currentFingerprint(root, id, ctx), { fp: original }, id);
  }
});

test('a regression tag is outside the fingerprint', () => {
  const block = extractFingerprintBlock(REPO);
  assert.ok(block.block, block.error);
  const text = 'Given one line in the cart, when the quantity is raised to the maximum, then the line total follows.';
  const untagged = fingerprint(block.block, `- **E1-1.AC1** — ${text}`);
  assert.equal(untagged, '5def01');
  assert.equal(fingerprint(block.block, `- **E1-1.AC1** — [reg P0] ${text}`), untagged);
  assert.equal(fingerprint(block.block, `- **E1-1.AC1** — [reg P1] ${text}`), fingerprint(block.block, `- **E1-1.AC1** — [reg P0] ${text}`));
});

test('planned coverage counts tags after any separator', () => {
  const root = copyFixture('valid');
  const epic = `# E1 — Cart\n\n## E1-1 — Change quantity\n**Summary:** x.\n**Goal:** x.\n**In scope:** x.\n**Out of scope:** x.\n### Acceptance criteria\n`
    + '- **E1-1.AC1** — [reg P0] Open the menu.\n- **E1-1.AC2**: [reg P1] Close the menu.\n- **E1-1.AC3** – [reg P2] Keep the focus.\n- **E1-1.AC4** — (withdrawn) [reg P0] Old.\n- **E1-1.AC5** — Untagged.\n';
  fs.writeFileSync(path.join(root, '.agents/backlog/E1-cart.md'), epic);
  const { coverage } = statusReport(root, [], {});
  assert.deepEqual([coverage.P0.planned, coverage.P1.planned, coverage.P2.planned], [1, 1, 1]);
});

test('dropped scenario with a retained spec is not automated coverage', () => {
  const root = copyFixture('valid');
  const cart = path.join(root, CAT, 'cart.md');
  fs.writeFileSync(cart, fs.readFileSync(cart, 'utf8').replace('P0 · **Viewport:** both · **Status:** READY · **Effect:** write', 'P0 · **Viewport:** both · **Status:** DROPPED (D-9) · **Effect:** write'));
  const json = cartRow(root);
  assert.equal(rowOf(json, 'CART-001').automation, 'verified', 'the state is still computed');
  assert.deepEqual(json.counts.coverage.P0, { planned: 1, written: 2, automated: 0 });
  assert.ok(!json.counts.without_spec.includes('CART-001'));
  assert.ok(!json.counts.stale.includes('CART-001'));
});

test('automationState is a pure function of the files', () => {
  const root = copyFixture('valid');
  const settings = catalogSettings(loadConfig(root).config);
  const blocks = parseCatalog(root, catalogFiles(root, settings));
  const cart = blocks.find((b) => b.id === 'CART-001');
  assert.equal(automationState(root, cart, {}).state, 'verified');
  const catalogText = fs.readFileSync(path.join(root, CAT, 'cart.md'), 'utf8');
  assert.ok(!/Automation:/.test(catalogText), 'the state is never stored in the catalog');
});

// ---------------------------------------------------------------------------------------------
// setup.mjs — catalog, baseline, check, env
// ---------------------------------------------------------------------------------------------

test('setup catalog never overwrites', () => {
  const root = mkRoot();
  const first = run('setup.mjs', ['catalog', '--root', root, '--areas', 'CART=Cart,PDP=Product page']);
  assert.equal(first.status, 0, first.stdout + first.stderr);
  const file = path.join(root, '.claude/regression.json');
  const written = fs.readFileSync(file, 'utf8');
  assert.deepEqual(JSON.parse(written).catalog.areas, { CART: 'Cart', PDP: 'Product page' });
  assert.ok(written.endsWith('}\n'));
  const again = run('setup.mjs', ['catalog', '--root', root, '--areas', 'ACC=Account']);
  assert.equal(again.status, 0);
  assert.equal(again.stdout.trim(), 'regression.json exists — unchanged');
  assert.equal(fs.readFileSync(file, 'utf8'), written);
  const custom = mkRoot({ '.claude/regression.json': '{"custom": true}\n' });
  assert.equal(run('setup.mjs', ['catalog', '--root', custom, '--areas', 'CART=Cart']).status, 0);
  assert.equal(fs.readFileSync(path.join(custom, '.claude/regression.json'), 'utf8'), '{"custom": true}\n');
  const bad = mkRoot();
  assert.equal(run('setup.mjs', ['catalog', '--root', bad, '--areas', 'cart=Cart']).status, 1);
  assert.ok(!fs.existsSync(path.join(bad, '.claude/regression.json')), 'an invalid catalog section is never written');
});

const RUNNER = {
  config: 'e2e/playwright.config.ts', spec_dir: 'e2e/regression', devices: { desktop: 'desktop-chrome' },
  commands: { smoke: 'npx playwright test --grep @smoke', full: 'npx playwright test' }, report: 'e2e/.results/report.json',
  test_data: { check: 'e2e/test-data/adapter.sh check', provision: 'e2e/test-data/adapter.sh provision', reset: 'e2e/test-data/adapter.sh reset', session: 'e2e/test-data/adapter.sh session' },
};
const ENVS = { test: { host: 'https://test.example.com', kind: 'test' } };

test('setup baseline adds only absent sections', () => {
  const none = mkRoot({ 'fragment.json': { runner: RUNNER } });
  const n = run('setup.mjs', ['baseline', '--root', none, '--fragment', 'fragment.json']);
  assert.equal(n.status, 1);
  assert.match(n.stdout, /run the catalog stage first/);

  const existingRunner = { ...RUNNER, report: 'e2e/own-report.json' };
  const root = mkRoot({ '.claude/regression.json': { ...CONFIG, runner: existingRunner }, 'fragment.json': { runner: RUNNER, environments: ENVS } });
  const r = run('setup.mjs', ['baseline', '--root', root, '--fragment', 'fragment.json']);
  assert.equal(r.status, 0, r.stdout + r.stderr);
  assert.match(r.stdout, /^kept runner \(fragment section ignored\)$/m);
  assert.match(r.stdout, /^added environments$/m);
  const cfg = JSON.parse(fs.readFileSync(path.join(root, '.claude/regression.json'), 'utf8'));
  assert.deepEqual(Object.keys(cfg), ['version', 'catalog', 'runner', 'environments']);
  assert.deepEqual(cfg.runner, existingRunner, 'an existing section is never rewritten');
  assert.deepEqual(cfg.environments, ENVS);
  const done = run('setup.mjs', ['baseline', '--root', root, '--fragment', 'fragment.json']);
  assert.equal(done.status, 0);
  assert.match(done.stdout, /^nothing to add$/m);

  const partial = mkRoot({ '.claude/regression.json': CONFIG, 'fragment.json': { runner: RUNNER } });
  const p = run('setup.mjs', ['baseline', '--root', partial, '--fragment', 'fragment.json']);
  assert.equal(p.status, 1, 'environments still missing');
  assert.match(p.stdout, /^still missing: environments/m);

  const before = `${JSON.stringify(CONFIG, null, 2)}\n`;
  const invalid = mkRoot({ '.claude/regression.json': before, 'fragment.json': { runner: { ...RUNNER, test_data: { check: 'x' } }, environments: ENVS } });
  const i = run('setup.mjs', ['baseline', '--root', invalid, '--fragment', 'fragment.json']);
  assert.equal(i.status, 1);
  assert.match(i.stdout, /runner\.test_data\.provision: must be a non-empty string/);
  assert.equal(fs.readFileSync(path.join(invalid, '.claude/regression.json'), 'utf8'), before, 'file untouched');
});

/** A root whose foundation is complete; `over` replaces files. */
function completeRoot(over = {}) {
  const root = mkRoot({
    '.claude/regression.json': { ...CONFIG, runner: RUNNER, environments: ENVS },
    'e2e/playwright.config.ts': '// config\n',
    'e2e/regression/.gitkeep': '',
    'e2e/test-data/adapter.sh': '#!/usr/bin/env bash\n',
    '.mcp.json': { mcpServers: { playwright: { command: 'npx', args: ['-y', '@playwright/mcp@0.0.86', '--isolated'] } } },
    ...over,
  });
  const adapter = path.join(root, 'e2e/test-data/adapter.sh');
  if (fs.existsSync(adapter)) fs.chmodSync(adapter, 0o755);
  return root;
}

test('check flags a non-executable adapter and a directory as config', () => {
  const root = completeRoot({ 'e2e/playwright.config.ts': undefined, 'e2e/playwright.config.ts/.gitkeep': '' });
  fs.chmodSync(path.join(root, 'e2e/test-data/adapter.sh'), 0o644);
  const r = run('setup.mjs', ['check', '--root', root]);
  assert.equal(r.status, 1);
  assert.match(r.stdout, /^runner\.config: e2e\/playwright\.config\.ts not found$/m);
  assert.match(r.stdout, /^test_data\.check: e2e\/test-data\/adapter\.sh is not executable/m);
});

test('rejects a base URL with credentials from either source', () => {
  assert.equal(isBaseUrl('https://user:secret@test.example.com'), false);
  assert.equal(isBaseUrl('https://user@test.example.com'), false);
  assert.ok(validateConfig({ ...CONFIG, environments: { a: { host: 'https://user:secret@test.example.com' } } }).some((e) => /^environments\.a\.host:/.test(e) && !/secret/.test(e)));
  const cfg = { ...CONFIG, environments: { test: { host: 'qa-env' } } };
  const root = mkRoot({ '.claude/regression.json': cfg, '.claude/qa-env.json': { base_url: 'https://user:secret@qa.example.com' } });
  const res = resolveEnvBaseUrl(root, cfg, 'test');
  assert.match(res.error ?? '', /base_url is not an http\(s\) URL/);
  assert.doesNotMatch(res.error, /secret/);
});

test('check exits non-zero while anything is missing', () => {
  const r = run('setup.mjs', ['check', '--root', path.join(FIX, 'valid')]);
  assert.equal(r.status, 1);
  assert.match(r.stdout, /^runner section missing/m);
  assert.match(r.stdout, /^no environment in environments$/m);
  assert.match(r.stdout, /^no \.mcp\.json playwright server$/m);
  const na = run('setup.mjs', ['check', '--root', path.join(FIX, 'not-adopted')]);
  assert.equal(na.status, 1);
  assert.match(na.stdout, /regression\.json missing/);
  const noSpecDir = completeRoot({ 'e2e/regression/.gitkeep': undefined });
  const s = run('setup.mjs', ['check', '--root', noSpecDir]);
  assert.equal(s.status, 1);
  assert.match(s.stdout, /^runner\.spec_dir: e2e\/regression not found$/m);
});

test('check passes on a complete foundation', () => {
  const root = completeRoot();
  assert.deepEqual(checkFoundation(root), []);
  const r = run('setup.mjs', ['check', '--root', root]);
  assert.equal(r.status, 0, r.stdout + r.stderr);
  assert.equal(r.stdout.trim(), 'foundation complete');
});

test('check flags a missing adapter entrypoint', () => {
  const root = completeRoot({ '.claude/regression.json': { ...CONFIG, runner: { ...RUNNER, test_data: { ...RUNNER.test_data, session: 'node e2e/test-data/missing.mjs session', reset: 'adapter reset' } }, environments: ENVS } });
  const r = run('setup.mjs', ['check', '--root', root], { PATH: NODE_PATH });
  assert.equal(r.status, 1);
  assert.match(r.stdout, /^test_data\.session: e2e\/test-data\/missing\.mjs not found/m);
  assert.match(r.stdout, /^test_data\.reset: unsupported command form/m);
  assert.ok(!/test_data\.check/.test(r.stdout));
});

test('check flags an unpinned playwright mcp', () => {
  const mixed = completeRoot({ '.mcp.json': { mcpServers: { a: { command: 'npx', args: ['-y', '@playwright/mcp@0.0.86'] }, b: { command: 'npx', args: ['-y', '@playwright/mcp@latest'] } } } });
  const r = run('setup.mjs', ['check', '--root', mixed]);
  assert.equal(r.status, 1);
  assert.match(r.stdout, /^mcpServers\.b: @playwright\/mcp not pinned to an exact version/m);
  assert.ok(!/mcpServers\.a:/.test(r.stdout));
  const range = completeRoot({ '.mcp.json': { mcpServers: { p: { args: ['@playwright/mcp@^0.0.86'] } } } });
  assert.match(run('setup.mjs', ['check', '--root', range]).stdout, /mcpServers\.p: @playwright\/mcp not pinned/);
  const bare = completeRoot({ '.mcp.json': { mcpServers: { p: { args: ['@playwright/mcp'] } } } });
  assert.match(run('setup.mjs', ['check', '--root', bare]).stdout, /mcpServers\.p: @playwright\/mcp not pinned/);
  const none = completeRoot({ '.mcp.json': { mcpServers: {} } });
  assert.match(run('setup.mjs', ['check', '--root', none]).stdout, /^no \.mcp\.json playwright server$/m);
});

test('qa-env host reads base_url', () => {
  const cfg = { ...CONFIG, environments: { test: { host: 'qa-env', kind: 'test' }, prod: { host: 'https://shop.example.com' } } };
  const root = mkRoot({ '.claude/regression.json': cfg, '.claude/qa-env.json': { base_url: 'https://qa.example.com' } });
  assert.deepEqual(resolveEnvBaseUrl(root, cfg, 'test'), { url: 'https://qa.example.com' });
  const r = run('setup.mjs', ['env', 'test', '--root', root]);
  assert.equal(r.status, 0, r.stdout + r.stderr);
  assert.equal(r.stdout.trim(), 'https://qa.example.com');
  assert.equal(run('setup.mjs', ['env', 'prod', '--root', root]).stdout.trim(), 'https://shop.example.com');
  assert.equal(envKind(cfg.environments.prod), 'production', 'absent kind = production');
  const empty = mkRoot({ '.claude/regression.json': cfg, '.claude/qa-env.json': { base_url: '' } });
  const e = run('setup.mjs', ['env', 'test', '--root', empty]);
  assert.equal(e.status, 1);
  assert.match(e.stdout, /base_url is empty/);
  const absent = mkRoot({ '.claude/regression.json': cfg });
  assert.match(resolveEnvBaseUrl(absent, cfg, 'test').error, /qa-env\.json absent/);
  assert.match(resolveEnvBaseUrl(root, cfg, 'nope').error, /unknown environment nope/);
});

test('rejects a malformed host from either source', () => {
  for (const bad of ['https://??', 'https://x.example.com ', 'https://x.example.com/', 'ftp://x.example.com', '']) assert.equal(isBaseUrl(bad), false, JSON.stringify(bad));
  assert.equal(isBaseUrl('http://localhost:3000'), true);
  const errors = validateConfig({ ...CONFIG, environments: { a: { host: 'https://??' }, b: { host: 'https://x.example.com ' }, c: { host: 'qa-env', kind: 'staging' } } });
  assert.ok(errors.some((e) => /^environments\.a\.host:/.test(e)));
  assert.ok(errors.some((e) => /^environments\.b\.host:/.test(e)));
  assert.ok(errors.some((e) => /^environments\.c\.kind:/.test(e)));
  const cfg = { ...CONFIG, environments: { test: { host: 'qa-env' } } };
  for (const bad of ['https://??', 'https://qa.example.com ']) {
    const root = mkRoot({ '.claude/regression.json': cfg, '.claude/qa-env.json': { base_url: bad } });
    assert.match(resolveEnvBaseUrl(root, cfg, 'test').error ?? '', /base_url is not an http\(s\) URL/, JSON.stringify(bad));
  }
});

test('the config example validates', () => {
  const example = JSON.parse(fs.readFileSync(path.join(REPO, '.claude/regression.json.example'), 'utf8'));
  assert.deepEqual(validateConfig(example), []);
});

test('templates wire the session into storageState', () => {
  const dir = path.join(REPO, '.claude/templates/regression');
  const fixtures = fs.readFileSync(path.join(dir, 'fixtures.ts.template'), 'utf8');
  assert.match(fixtures, /storageState:/);
  assert.match(fixtures, /session/);
  const header = fs.readFileSync(path.join(dir, 'spec-header.ts.template'), 'utf8');
  assert.match(header, /import \{ test, expect \} from '[^']*fixtures';/);
  assert.match(header, /\/\/ regression: <ID> · source:/);
  assert.doesNotMatch(fs.readFileSync(path.join(dir, 'playwright.config.ts.template'), 'utf8'), /webServer:/);
});

// ---------------------------------------------------------------------------------------------
// Live BLOCKED, block texts and unobservable clauses (#332)
// ---------------------------------------------------------------------------------------------

test('BLOCKED (live: <reason>) is accepted and an empty live reason is rejected', () => {
  assert.deepEqual(errorsOf({ 'cart.md': catalogFile(scenario('CART-001', { status: 'BLOCKED (live: 500 on /checkout)', steps: '—', expected: '—' })) }), []);
  const errors = errorsOf({ 'cart.md': catalogFile(scenario('CART-001', { status: 'BLOCKED (live: )', steps: '—', expected: '—' })) });
  has(errors, new RegExp(`^${CAT}/cart\\.md:4: BLOCKED without a reference — expected BLOCKED \\(<Task id \\| tracker key \\| #n \\| live: <reason>>\\)$`));
});

test("blockTexts returns each block's exact text", () => {
  const a = scenario('CART-001');
  const b = scenario('CART-002', { title: 'Second' });
  const root = mkRoot({ '.claude/regression.json': CONFIG, [`${CAT}/cart.md`]: `# Cart\n\n${a}\n\n\n${b}\n\n## Notes\n\ntext\n` });
  const texts = blockTexts(root, [`${CAT}/cart.md`]);
  assert.deepEqual([...texts.keys()], ['CART-001', 'CART-002']);
  assert.deepEqual(texts.get('CART-001'), { file: `${CAT}/cart.md`, line: 3, text: a });
  assert.equal(texts.get('CART-002').text, b, 'trailing blank lines and the next heading are not part of the block');
});

test('--status lists the regression-unobservable lines of a spec', () => {
  const spec = [
    "import { test, expect } from '../fixtures';",
    '// regression: CART-004 · source: live',
    '// regression-unobservable: CART-004 · an email is sent — not observable in a browser',
    '// regression-unobservable: CART-009 · another scenario — not this row',
    "test('CART-004 — Check out', async ({ page }) => {});",
    '',
  ].join('\n');
  const root = mkRoot({
    '.claude/regression.json': CONFIG,
    [`${CAT}/cart.md`]: catalogFile(scenario('CART-004', { title: 'Check out', spec: 'e2e/regression/cart/cart-004.spec.ts › CART-004 — Check out' })),
    'e2e/regression/cart/cart-004.spec.ts': spec,
  });
  const s = run('catalog.mjs', ['--root', root, '--status']);
  assert.equal(s.status, 0, s.stdout + s.stderr);
  assert.match(s.stdout, /^unobservable: CART-004 — an email is sent — not observable in a browser$/m);
  assert.doesNotMatch(s.stdout, /CART-009/);
  const j = JSON.parse(run('catalog.mjs', ['--root', root, '--json']).stdout);
  assert.deepEqual(rowOf(j, 'CART-004').unobservable, [{ clause: 'an email is sent', reason: 'not observable in a browser' }]);
});
