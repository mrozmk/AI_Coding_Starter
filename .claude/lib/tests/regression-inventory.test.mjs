// Unit tests of the inventory of an existing app (.claude/lib/regression/inventory.mjs): the route
// list checks, apply's reconciliation of a reviewed proposal with a COMPLETE walk (never a rewrite,
// a failed path only as live BLOCKED, idempotent, under the checkout lock) and the baseline split.
// Temp copies of fixtures/regression/inventory only; REGRESSION_LOCK_DIR in a temp dir.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { createHash } from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

import { proposalDigest, splitBaseline } from '../regression/inventory.mjs';
import { acquireLock, checkoutLockName } from '../regression/run.mjs';
import { parseCatalog } from '../regression/catalog.mjs';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const INV = path.join(HERE, '../regression/inventory.mjs');
const CATALOG = path.join(HERE, '../regression/catalog.mjs');
const FIX = path.join(HERE, 'fixtures/regression/inventory');
const CAT = '.agents/regression/scenarios';
const ROUTES = '.agents/regression/routes.json';
const sha256 = (b) => createHash('sha256').update(b).digest('hex');

// ---------------------------------------------------------------------------------------------
// Helpers

function setup() {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'regression-inventory-'));
  fs.cpSync(path.join(FIX, 'root'), root, { recursive: true });
  const stage = path.join(root, '.agents/regression/runs/inventory-t');
  const walk = path.join(root, '.agents/regression/runs/test-walk');
  fs.cpSync(path.join(FIX, 'stage'), stage, { recursive: true });
  fs.cpSync(path.join(FIX, 'walk'), walk, { recursive: true });
  return { root, stage, walk, locks: fs.mkdtempSync(path.join(os.tmpdir(), 'regression-locks-')) };
}

const readJson = (f) => JSON.parse(fs.readFileSync(f, 'utf8'));
const writeJson = (f, v) => { fs.mkdirSync(path.dirname(f), { recursive: true }); fs.writeFileSync(f, `${JSON.stringify(v, null, 2)}\n`); };
const read = (ctx, rel) => fs.readFileSync(path.join(ctx.root, rel), 'utf8');

/**
 * Replace parts of the stage or walk, then re-bind the walk to the staged bytes (routes_digest and
 * the one group's planned routes) unless `bind` is false.
 */
function restage(ctx, { staged, md, json, obs, walk, bind = true } = {}) {
  if (staged) writeJson(path.join(ctx.stage, 'routes.staged.json'), staged);
  if (md !== undefined) fs.writeFileSync(path.join(ctx.stage, 'proposal.md'), md);
  if (json) writeJson(path.join(ctx.stage, 'proposal.json'), json);
  if (obs) writeJson(path.join(ctx.walk, 'walk/observations.json'), obs);
  const record = readJson(path.join(ctx.walk, 'walk.json'));
  if (bind) {
    const bytes = fs.readFileSync(path.join(ctx.stage, 'routes.staged.json'));
    record.routes_digest = sha256(bytes);
    record.groups[0].routes = JSON.parse(bytes.toString('utf8')).routes.map((r) => r.route);
  }
  writeJson(path.join(ctx.walk, 'walk.json'), { ...record, ...(walk ?? {}) });
}
const stagedOf = (ctx) => readJson(path.join(ctx.stage, 'routes.staged.json'));
const proposalOf = (ctx) => readJson(path.join(ctx.stage, 'proposal.json'));
const mdOf = (ctx) => fs.readFileSync(path.join(ctx.stage, 'proposal.md'), 'utf8');
const obsOf = (ctx) => readJson(path.join(ctx.walk, 'walk/observations.json'));

function cli(ctx, args) {
  const r = spawnSync(process.execPath, [INV, ...args, '--root', ctx.root], { encoding: 'utf8', env: { ...process.env, REGRESSION_LOCK_DIR: ctx.locks } });
  return { ...r, out: r.stdout + r.stderr };
}
const apply = (ctx, { dry = false, digest } = {}) => cli(ctx, ['apply', '--stage', ctx.stage, '--walk', ctx.walk, ...(dry ? ['--dry-run'] : ['--expect-proposal', digest ?? proposalDigest(ctx.stage)])]);
const refused = (r, re) => { assert.equal(r.status, 1, r.out); assert.match(r.stdout, re); };

/** Every byte of the catalog directory and the route list. */
function snapshot(ctx) {
  const out = {};
  const dir = path.join(ctx.root, CAT);
  if (fs.existsSync(dir)) for (const f of fs.readdirSync(dir).sort()) out[f] = fs.readFileSync(path.join(dir, f), 'utf8');
  const routes = path.join(ctx.root, ROUTES);
  out.routes = fs.existsSync(routes) ? fs.readFileSync(routes, 'utf8') : null;
  return out;
}

/** A second walk of the same staged routes in which `route` answered 500. */
function failedWalk(ctx, route) {
  restage(ctx, { obs: obsOf(ctx).map((o) => (o.route === route ? { ...o, outcome: 'failed', reason: 'status 500', status: 500 } : o)) });
}

const block = (id, { title = 'A scenario', status = 'READY', source = 'live', spec = '—', steps = '\n  1. Open it.', expected = 'It shows.' } = {}) => [
  `### ${id} — ${title}`,
  `- **Priority:** P1 · **Viewport:** desktop · **Status:** ${status} · **Effect:** read`,
  '- **Goal:** Open it.',
  `- **Steps:**${steps.startsWith('\n') ? steps : ` ${steps}`}`,
  `- **Expected:** ${expected}`,
  `- **Source:** ${source} · **Spec:** ${spec}`,
].join('\n');

// ---------------------------------------------------------------------------------------------
// Route list checks

test('check: every route needs an existing scenario id or an exclusion', () => {
  const ctx = setup();
  const ok = cli(ctx, ['check']);
  assert.equal(ok.status, 0, ok.out);
  const doc = readJson(path.join(ctx.root, ROUTES));
  doc.routes.push({ route: '/x', source: 's' }, { route: '/y', source: 's', scenarios: ['CART-999'] }, { route: '/z', source: 's', scenarios: ['CART-003'] }, { route: '/w', source: 's', exclusion: 'third-party page' });
  writeJson(path.join(ctx.root, ROUTES), doc);
  const r = cli(ctx, ['check']);
  assert.equal(r.status, 1, r.out);
  assert.match(r.stdout, /^route \/x: no scenario and no exclusion$/m);
  assert.match(r.stdout, /^route \/y: unknown scenario CART-999$/m);
  assert.match(r.stdout, /^route \/z: scenario CART-003 is DROPPED$/m);
  assert.doesNotMatch(r.stdout, /route \/w/);
  fs.rmSync(path.join(ctx.root, ROUTES));
  const none = cli(ctx, ['check']);
  assert.equal(none.status, 1);
  assert.match(none.stdout, /^no route list$/m);
});

test('check-staged: refuses a non-GET submit entry and a duplicate route', () => {
  const ctx = setup();
  const file = path.join(ctx.stage, 'routes.staged.json');
  assert.equal(cli(ctx, ['check-staged', '--routes', file]).status, 0);
  const doc = stagedOf(ctx);
  doc.routes.push({ route: '/cart', source: 'again' }, { route: '/login', source: 's', submit: [{ form: 'login', action: '/login', method: 'POST', inputs: { user: 'x' } }] });
  writeJson(file, doc);
  const r = cli(ctx, ['check-staged', '--routes', file]);
  assert.equal(r.status, 1, r.out);
  assert.match(r.stdout, /^route \/cart: duplicate route$/m);
  assert.match(r.stdout, /^submit login: only GET forms may be allow-listed$/m);
});

// ---------------------------------------------------------------------------------------------
// apply — publishing

test('apply: appends new blocks to the area file and merges routes', () => {
  const ctx = setup();
  const before = read(ctx, `${CAT}/cart.md`);
  const r = apply(ctx);
  assert.equal(r.status, 0, r.out);
  for (const id of ['PDP-001', 'SRCH-001', 'CART-004', 'CART-005']) assert.match(r.stdout, new RegExp(`^applied: ${id}$`, 'm'));
  assert.match(r.stdout, /^routes: 5 added, 0 updated$/m);
  const cart = read(ctx, `${CAT}/cart.md`);
  assert.ok(cart.startsWith(before.replace(/\n+$/, '')), 'the existing blocks are untouched');
  assert.ok(cart.indexOf('### CART-004') > cart.indexOf('### CART-003'), 'appended after the last block');
  assert.ok(cart.indexOf('### CART-005') > cart.indexOf('### CART-004'));
  const routes = readJson(path.join(ctx.root, ROUTES)).routes;
  assert.deepEqual(routes.find((e) => e.route === '/cart'), { route: '/cart', source: 'app/cart.tsx', sample: '/cart', scenarios: ['CART-001'] });
  assert.deepEqual(routes.find((e) => e.route === '/p/:id'), { route: '/p/:id', source: 'app/product.tsx', match: '^/p/[0-9]+$', scenarios: ['PDP-001'] });
  assert.deepEqual(routes.find((e) => e.route === '/orders/:id').exclusion, 'needs a placed order — no sample on the walk');
  const v = spawnSync(process.execPath, [CATALOG, '--root', ctx.root], { encoding: 'utf8' });
  assert.equal(v.status, 0, v.stdout + v.stderr);
  assert.equal(cli(ctx, ['check']).status, 0);
});

test('apply: writes a new area file with its heading', () => {
  const ctx = setup();
  assert.equal(apply(ctx).status, 0);
  assert.ok(read(ctx, `${CAT}/pdp.md`).startsWith('# Product page\n\n### PDP-001 — Open a product page\n'));
  assert.ok(read(ctx, `${CAT}/srch.md`).startsWith('# Search\n\n### SRCH-001'));
});

test('apply: a first apply creates a custom catalog path that does not exist yet', () => {
  const ctx = setup();
  const cfgFile = path.join(ctx.root, '.claude/regression.json');
  writeJson(cfgFile, { ...readJson(cfgFile), catalog: { ...readJson(cfgFile).catalog, path: 'qa/scenarios' } });
  fs.rmSync(path.join(ctx.root, ROUTES));
  restage(ctx, {
    staged: { schema: 1, routes: [{ route: '/p/:id', source: 'app/product.tsx', match: '^/p/[0-9]+$' }] },
    md: `${block('PDP-001')}\n`,
    json: { routes: { '/p/:id': { scenarios: ['PDP-001'] } }, sources: { 'PDP-001': { code: null, covered_by: null, submit: null } } },
    obs: obsOf(ctx).filter((o) => o.route === '/p/:id'),
  });
  const dry = apply(ctx, { dry: true });
  assert.equal(dry.status, 0, dry.out);
  assert.equal(fs.existsSync(path.join(ctx.root, 'qa')), false, 'a dry run never creates the catalog dir');
  const r = apply(ctx);
  assert.equal(r.status, 0, r.out);
  assert.ok(read(ctx, 'qa/scenarios/pdp.md').startsWith('# Product page\n\n### PDP-001'));
});

test('apply: refuses a proposal that rewrites an existing block or reuses a DROPPED id', () => {
  const ctx = setup();
  const before = snapshot(ctx);
  restage(ctx, { md: `${mdOf(ctx)}\n${block('CART-001', { title: 'Open the cart' })}\n` });
  refused(apply(ctx), /^refused: rewrites existing block CART-001$/m);
  const dropped = setup();
  restage(dropped, { md: `${mdOf(dropped)}\n${block('CART-003', { title: 'Old cart badge' })}\n` });
  refused(apply(dropped), /^refused: reuses DROPPED id CART-003$/m);
  assert.deepEqual(snapshot(ctx), before);
});

test('apply: a byte-identical re-apply is idempotent', () => {
  const ctx = setup();
  assert.equal(apply(ctx).status, 0);
  const once = snapshot(ctx);
  const again = apply(ctx);
  assert.equal(again.status, 0, again.out);
  for (const id of ['PDP-001', 'SRCH-001', 'CART-004', 'CART-005']) assert.match(again.stdout, new RegExp(`^skipped: ${id} \\(already applied\\)$`, 'm'));
  assert.match(again.stdout, /^routes: 0 added, 0 updated$/m);
  assert.deepEqual(snapshot(ctx), once);
});

test('apply: refuses a proposal changed after its reviewed digest and leaves every file byte-identical', () => {
  const ctx = setup();
  const dry = apply(ctx, { dry: true });
  assert.equal(dry.status, 0, dry.out);
  const reviewed = /^proposal: ([0-9a-f]{64})$/m.exec(dry.stdout)[1];
  const before = snapshot(ctx);
  fs.appendFileSync(path.join(ctx.stage, 'proposal.md'), '\n');
  refused(apply(ctx, { digest: reviewed }), /^refused: proposal changed since its review/m);
  assert.deepEqual(snapshot(ctx), before);
  assert.equal(fs.readdirSync(path.join(ctx.root, CAT)).some((f) => f.includes('.tmp-')), false, 'no temp left behind');
});

test('apply: refuses while the checkout lock is held', () => {
  const ctx = setup();
  const saved = process.env.REGRESSION_LOCK_DIR;
  process.env.REGRESSION_LOCK_DIR = ctx.locks;
  const held = acquireLock(checkoutLockName(ctx.root), { pid: process.pid, pgid: null, run_id: 'a-run' });
  try {
    assert.ok(held.lock, held.error);
    const before = snapshot(ctx);
    refused(apply(ctx), /^refused: checkout lock held — lock checkout-[0-9a-f]{16} held by pid \d+ \(run a-run\)$/m);
    assert.deepEqual(snapshot(ctx), before);
  } finally {
    held.lock?.release();
    if (saved === undefined) delete process.env.REGRESSION_LOCK_DIR; else process.env.REGRESSION_LOCK_DIR = saved;
  }
});

// ---------------------------------------------------------------------------------------------
// apply — the walk binds every scenario

test('apply: refuses a READY scenario for a route the walk saw fail', () => {
  const ctx = setup();
  restage(ctx, { md: mdOf(ctx).replace('**Status:** BLOCKED (live: 500 on /checkout)', '**Status:** READY').replace('- **Steps:** —\n- **Expected:** —\n- **Source:** live · **Spec:** —', '- **Steps:**\n  1. Open the checkout.\n- **Expected:** The checkout shows.\n- **Source:** live · **Spec:** —') });
  refused(apply(ctx), /^refused: route \/checkout: CART-004 must be BLOCKED \(live: …\) citing live/m);
});

test('apply: accepts a live BLOCKED scenario for a route that answered 500 and re-applies it idempotently', () => {
  const ctx = setup();
  assert.equal(apply(ctx).status, 0);
  assert.match(read(ctx, `${CAT}/cart.md`), /^- \*\*Priority:\*\* P0 · \*\*Viewport:\*\* desktop · \*\*Status:\*\* BLOCKED \(live: 500 on \/checkout\) · \*\*Effect:\*\* read$/m);
  const again = apply(ctx);
  assert.equal(again.status, 0, again.out);
  assert.match(again.stdout, /^skipped: CART-004 \(already applied\)$/m);
});

test('apply: refuses a walk that is not COMPLETE, a walk of other staged routes, and a route missing from a completed group', () => {
  const a = setup();
  restage(a, { walk: { verdict: 'INCOMPLETE' } });
  refused(apply(a), /^refused: walk test-20261127T120000Z-abcd is not COMPLETE \(INCOMPLETE\)$/m);
  const b = setup();
  const staged = stagedOf(b);
  staged.routes[0].sample = '/cart?changed=1';
  writeJson(path.join(b.stage, 'routes.staged.json'), staged);
  refused(apply(b), /^refused: walk test-20261127T120000Z-abcd was run on other staged routes$/m);
  const c = setup();
  restage(c, { obs: obsOf(c).filter((o) => o.route !== '/search') });
  refused(apply(c), /^refused: route \/search missing from group WALK1$/m);
});

test('apply: refuses a failed route mapped to an existing READY scenario', () => {
  const ctx = setup();
  const json = proposalOf(ctx);
  json.routes['/checkout'].scenarios.push('CART-001');
  restage(ctx, { json });
  refused(apply(ctx), /^refused: route \/checkout: existing CART-001 conflicts with the walk \(failed\)/m);
});

test('apply: two applies from the same route list keep both additions', () => {
  const ctx = setup();
  assert.equal(apply(ctx).status, 0);
  restage(ctx, {
    md: `${block('PDP-002', { title: 'See a second product' })}\n`,
    json: { routes: { '/p/:id': { scenarios: ['PDP-002'] } }, sources: { 'PDP-002': { code: null, covered_by: null, submit: null } } },
  });
  const r = apply(ctx);
  assert.equal(r.status, 0, r.out);
  assert.match(r.stdout, /^routes: 0 added, 1 updated$/m);
  const routes = readJson(path.join(ctx.root, ROUTES)).routes;
  assert.deepEqual(routes.find((e) => e.route === '/p/:id').scenarios, ['PDP-001', 'PDP-002']);
  assert.deepEqual(routes.find((e) => e.route === '/checkout').scenarios, ['CART-004']);
  const pdp = read(ctx, `${CAT}/pdp.md`);
  assert.ok(pdp.includes('### PDP-001') && pdp.includes('### PDP-002'));
});

test('apply: refuses a retained READY id on a route the new walk saw fail, and an unattached new block', () => {
  const ctx = setup();
  failedWalk(ctx, '/cart');
  refused(apply(ctx), /^refused: route \/cart: retained CART-001 conflicts with the walk \(failed\) — must be BLOCKED \(live: …\) citing live; apply cannot rewrite the block — fix it by hand, or remove CART-001 from this route in \.agents\/regression\/routes\.json$/m);
  const loose = setup();
  restage(loose, { md: `${mdOf(loose)}\n${block('PDP-009', { title: 'Nowhere' })}\n` });
  refused(apply(loose), /^refused: unattached block PDP-009$/m);
});

test('apply: a block for a failed submit must be live BLOCKED', () => {
  const ctx = setup();
  const failSubmit = obsOf(ctx).map((o) => (o.route === '/search' ? { ...o, submits: [{ ...o.submits[0], outcome: 'failed', status: 500 }] } : o));
  restage(ctx, { obs: failSubmit });
  refused(apply(ctx), /^refused: route \/search: SRCH-001 must be BLOCKED \(live: …\) citing live \(walk: failed, submit search\)$/m);
  const fixed = setup();
  restage(fixed, { obs: failSubmit, md: mdOf(fixed).replace('### SRCH-001 — Search for a product\n- **Priority:** P0 · **Viewport:** desktop · **Status:** READY', '### SRCH-001 — Search for a product\n- **Priority:** P0 · **Viewport:** desktop · **Status:** BLOCKED (live: search answers 500)') });
  const r = apply(fixed);
  assert.equal(r.status, 0, r.out);
});

test('apply: refuses a live scenario for an unvisited or redirected route', () => {
  const ctx = setup();
  restage(ctx, { md: mdOf(ctx).replace('- **Source:** code · **Spec:** —', '- **Source:** live · **Spec:** —') });
  refused(apply(ctx), /^refused: route \/account: CART-005 cites live, but the walk did not see the path work/m);
  const orders = setup();
  const json = proposalOf(orders);
  json.routes['/orders/:id'] = { scenarios: ['PDP-002'] };
  json.sources['PDP-002'] = { code: null, covered_by: null, submit: null };
  restage(orders, { json, md: `${mdOf(orders)}\n${block('PDP-002', { title: 'Open an order' })}\n` });
  refused(apply(orders), /^refused: route \/orders\/:id: PDP-002 cites live, but the walk did not see the path work \(walk: no-sample\)$/m);
});

test('apply: a route the walk did not see work admits code only — a criterion-only block is refused', () => {
  const ctx = setup();
  const json = proposalOf(ctx);
  json.routes['/orders/:id'] = { scenarios: ['PDP-002'] };
  json.sources['PDP-002'] = { code: null, covered_by: null, submit: null };
  restage(ctx, { json, md: `${mdOf(ctx)}\n${block('PDP-002', { title: 'Open an order', source: 'E2-3.AC2 [a1b2c3]' })}\n` });
  refused(apply(ctx), /^refused: route \/orders\/:id: PDP-002 must cite code — the walk did not see the path work \(walk: no-sample\)$/m);
  const fixed = setup();
  const json2 = proposalOf(fixed);
  json2.routes['/orders/:id'] = { scenarios: ['PDP-002'] };
  json2.sources['PDP-002'] = { code: ['src/routes/orders.ts:1'], covered_by: null, submit: null };
  restage(fixed, { json: json2, md: `${mdOf(fixed)}\n${block('PDP-002', { title: 'Open an order', source: 'E2-3.AC2 [a1b2c3] · code' })}\n` });
  const r = apply(fixed);
  assert.equal(r.status, 0, r.out);
});

test('apply: refuses a proposal that omits a staged route', () => {
  const ctx = setup();
  const json = proposalOf(ctx);
  delete json.routes['/account'];
  restage(ctx, { json });
  refused(apply(ctx), /^refused: route \/account: no scenario and no exclusion$/m);
});

test('apply: refuses a new block with a Spec', () => {
  const ctx = setup();
  restage(ctx, { md: mdOf(ctx).replace('### PDP-001 — Open a product page', '### PDP-001 — Open a product page').replace(/(### PDP-001[\s\S]*?\*\*Spec:\*\*) —/, '$1 e2e/regression/pdp/pdp-001.spec.ts › PDP-001 — Open a product page') });
  refused(apply(ctx), /^refused: new block PDP-001 has a Spec/m);
});

test('apply: refuses an unknown area code', () => {
  const ctx = setup();
  const json = proposalOf(ctx);
  json.routes['/p/:id'].scenarios.push('XYZ-001');
  restage(ctx, { json, md: `${mdOf(ctx)}\n${block('XYZ-001')}\n` });
  refused(apply(ctx), /^refused: unknown area code XYZ in XYZ-001 — configured: CART, PDP, SRCH$/m);
});

test('apply: never commits a redacted sample', () => {
  const ctx = setup();
  const staged = stagedOf(ctx);
  staged.routes.find((r) => r.route === '/checkout').sample = '/checkout?step=1';
  restage(ctx, { staged, walk: { redacted_samples: ['/checkout', '/search'] } });
  const r = apply(ctx);
  assert.equal(r.status, 0, r.out);
  const routes = readJson(path.join(ctx.root, ROUTES)).routes;
  assert.equal(routes.find((e) => e.route === '/checkout').sample, undefined);
  assert.equal(routes.find((e) => e.route === '/search').sample, undefined);
  assert.equal(read(ctx, ROUTES).includes('step=1'), false);
});

// ---------------------------------------------------------------------------------------------
// split

/** A root whose catalog holds `counts` READY no-spec scenarios per area (plus extras). */
function splitRoot(counts, extra = '') {
  const ctx = setup();
  const cfgFile = path.join(ctx.root, '.claude/regression.json');
  const cfg = readJson(cfgFile);
  cfg.catalog.areas = Object.fromEntries(Object.keys(counts).map((c) => [c, `Area ${c}`]));
  writeJson(cfgFile, cfg);
  fs.rmSync(path.join(ctx.root, CAT), { recursive: true, force: true });
  fs.mkdirSync(path.join(ctx.root, CAT), { recursive: true });
  for (const [code, n] of Object.entries(counts)) {
    const blocks = Array.from({ length: n }, (_, i) => block(`${code}-${String(i + 1).padStart(3, '0')}`));
    fs.writeFileSync(path.join(ctx.root, CAT, `${code.toLowerCase()}.md`), `# Area ${code}\n\n${blocks.join('\n\n')}\n${extra}`);
  }
  return ctx;
}

test('split: no candidates, a dangling Spec path and 61 scenarios in one area', () => {
  const none = splitRoot({ CART: 0 });
  const r0 = cli(none, ['split']);
  assert.equal(r0.status, 0, r0.out);
  assert.equal(r0.stdout.trim(), 'no baseline work — every READY scenario has a spec');
  const dangling = splitRoot({ CART: 0 }, `\n${block('CART-001', { spec: 'e2e/regression/cart/gone.spec.ts › CART-001 — A scenario' })}\n`);
  assert.equal(cli(dangling, ['split']).stdout.trim(), 'no baseline work — every READY scenario has a spec', 'a dangling Spec path is not "—"');
  const big = splitRoot({ CART: 61 });
  const r = cli(big, ['split']);
  assert.equal(r.stdout, 'part 1: CART (61 scenarios) — /regression-tests author --area CART\ntitle: [regression:baseline] Write the regression baseline — part 1\n');
});

test('split: proposes one to three parts by area', () => {
  const three = cli(splitRoot({ CART: 40, PDP: 20, SRCH: 5 }), ['split']);
  assert.match(three.stdout, /^part 1: CART \(40 scenarios\) — \/regression-tests author --area CART$/m);
  assert.match(three.stdout, /^part 2: PDP \(20 scenarios\) — \/regression-tests author --area PDP$/m);
  assert.match(three.stdout, /^part 3: SRCH \(5 scenarios\) — \/regression-tests author --area SRCH$/m);
  assert.match(three.stdout, /^title: \[regression:baseline\] Write the regression baseline — part 3$/m);
  const one = cli(splitRoot({ CART: 10, PDP: 5 }), ['split']);
  assert.match(one.stdout, /^part 1: CART,PDP \(15 scenarios\) — \/regression-tests author --area CART,PDP$/m);
  assert.doesNotMatch(one.stdout, /part 2/);
  const ctx = setup();
  const blocks = parseCatalog(ctx.root, [`${CAT}/cart.md`]);
  assert.deepEqual(splitBaseline(blocks).parts, [{ codes: ['CART'], n: 2 }]);
});
