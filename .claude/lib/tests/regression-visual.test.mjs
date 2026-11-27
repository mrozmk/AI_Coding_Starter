// Unit and CLI tests of the regression visual lane: config.mjs (validateVisual), policy.mjs
// (visualPlan, the production plan digest), visual.mjs (sources, index, integrity, classifier, offer,
// token, accept), visual-spec.mjs (worker side, against fake Playwright objects), run.mjs (`visual
// compare | update | accept`, the visual pass of `run full`, status per mode) and setup.mjs (`visual`,
// `check`). A fake visual runner, temp copies of the fixture root (--root), REGRESSION_LOCK_DIR in a
// temp dir — never the real ~, no browser, no network beyond a local build-SHA stub.
// The lane modules are imported lazily inside each case.
import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import http from 'node:http';
import { createHash } from 'node:crypto';
import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const REPO = path.join(HERE, '../../..');
const RUN = path.join(HERE, '../regression/run.mjs');
const SETUP = path.join(HERE, '../regression/setup.mjs');
const FIX = path.join(HERE, 'fixtures/regression/visual');
const FAKE = path.join(FIX, 'fake-visual-runner.mjs');
const BASE = 'e2e/visual-baselines';
const RUNS = '.agents/regression/runs';
const PNG_SIG = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
const sha = (b) => createHash('sha256').update(b).digest('hex');

const lib = (name) => import(`../regression/${name}.mjs`);

// ---------------------------------------------------------------------------------------------
// Helpers

function copyRoot() {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'regression-visual-'));
  fs.cpSync(path.join(FIX, 'root'), root, { recursive: true });
  useFunctional(root, 'same');
  useVisual(root, 'same');
  return root;
}
const tmp = (p = 'regression-visual-tmp-') => fs.mkdtempSync(path.join(os.tmpdir(), p));
const readConfig = (root) => JSON.parse(fs.readFileSync(path.join(root, '.claude/regression.json'), 'utf8'));
function editConfig(root, fn) {
  const cfg = readConfig(root);
  fn(cfg);
  fs.writeFileSync(path.join(root, '.claude/regression.json'), `${JSON.stringify(cfg, null, 2)}\n`);
  return cfg;
}
const fakeCmd = (scenario) => `"${process.execPath}" "${FAKE}" ${scenario}`;
function useVisual(root, scenario) { editConfig(root, (cfg) => { cfg.visual.command = fakeCmd(scenario); }); }
function useFunctional(root, scenario) {
  editConfig(root, (cfg) => { cfg.runner.commands.smoke = fakeCmd(scenario); cfg.runner.commands.full = fakeCmd(scenario); });
}

function cli(script, args, { env = {}, locks } = {}) {
  return new Promise((resolve) => {
    const child = spawn(process.execPath, [script, ...args], {
      env: { ...process.env, REGRESSION_LOCK_DIR: locks ?? tmp('regression-locks-'), ...env },
    });
    let stdout = '';
    let stderr = '';
    child.stdout.on('data', (d) => { stdout += d; });
    child.stderr.on('data', (d) => { stderr += d; });
    child.on('close', (status) => resolve({ status, stdout, stderr, out: stdout + stderr }));
  });
}
const run = (args, opts) => cli(RUN, args, opts);
const recordOf = (root, r) => {
  const m = /^record: (.+)$/m.exec(r.stdout);
  assert.ok(m, `no record line in:\n${r.out}`);
  return JSON.parse(fs.readFileSync(path.join(root, m[1]), 'utf8'));
};
const callsOf = (root) => (fs.existsSync(path.join(root, 'runner-calls.log')) ? fs.readFileSync(path.join(root, 'runner-calls.log'), 'utf8').split('\n').filter(Boolean) : []);
const acceptTokenOf = (r) => /^acceptance-required: ([0-9a-f]{32})$/m.exec(r.stdout)?.[1];
const confirmTokenOf = (r) => /^confirmation-required: ([0-9a-f]{32})$/m.exec(r.stdout)?.[1];
const runIdOf = (root, r) => recordOf(root, r).run_id;
const tree = (dir) => (fs.existsSync(dir) ? fs.readdirSync(dir, { recursive: true }).map(String).filter((f) => fs.statSync(path.join(dir, f)).isFile()).sort() : []);

// A build-SHA endpoint: answers the queued SHAs in order (the last one repeats).
let shaServer;
let shaQueue = [];
let SHA_URL = '';
before(async () => {
  shaServer = http.createServer((req, res) => {
    const s = shaQueue.length > 1 ? shaQueue.shift() : shaQueue[0];
    res.writeHead(200, { 'content-type': 'application/json' });
    res.end(JSON.stringify({ sha: s }));
  });
  await new Promise((r) => shaServer.listen(0, '127.0.0.1', r));
  SHA_URL = `http://127.0.0.1:${shaServer.address().port}/version`;
});
after(() => shaServer.close());

function knownBuild(root, env = 'test') {
  shaQueue = ['abc1234'];
  editConfig(root, (cfg) => { cfg.environments[env].build_sha_url = SHA_URL; });
}

/** visual update then accept: the accepted baselines of `env`. */
async function acceptBaselines(root, { env = 'test', locks } = {}) {
  const u = await run(['visual', 'update', '--env', env, '--root', root], { locks });
  assert.equal(u.status, 3, u.out);
  const token = acceptTokenOf(u);
  assert.ok(token, u.out);
  const a = await run(['visual', 'accept', '--run', runIdOf(root, u), '--token', token, '--root', root], { locks });
  assert.equal(a.status, 0, a.out);
  return { update: u, accept: a };
}

/** Phase 1 (token) and phase 2 (--confirm) of a production visual compare. */
async function prodVisual(root, action = 'compare') {
  const locks = tmp('regression-locks-');
  const first = await run(['visual', action, '--env', 'prod', '--root', root], { locks });
  assert.equal(first.status, 3, first.out);
  const token = confirmTokenOf(first);
  assert.ok(token, first.out);
  return run(['visual', action, '--env', 'prod', '--confirm', token, '--root', root], { locks });
}

// Fake Playwright objects for renderTarget.
function fakeWorld({ status = 200, counts = {}, boxes = {}, viewport = { width: 100, height: 100 }, pageSize, matcherError = null, readyAttached = true, laterCounts = null, ignoreSnapshots = false, attachments = [] } = {}) {
  const calls = [];
  let screenshotStage = false;
  const countOf = (sel) => (screenshotStage && laterCounts && sel in laterCounts ? laterCounts[sel] : counts[sel] ?? 0);
  const locator = (sel) => ({
    first() { return this; },
    async waitFor(opts) { calls.push(['waitFor', sel, opts?.state]); if (!readyAttached) throw new Error('Timeout 30000ms exceeded'); },
    async count() { return countOf(sel); },
    async all() { return (boxes[sel] ?? []).map((b) => ({ boundingBox: async () => b })); },
  });
  const page = {
    async goto(url, opts) { calls.push(['goto', url, opts?.waitUntil]); return status === null ? null : { status: () => status }; },
    locator(sel) { calls.push(['locator', sel]); return locator(sel); },
    async evaluate(fn, arg) { calls.push(['evaluate', arg]); if (arg === 'size') return pageSize ?? viewport; if (arg === 'before-shot') screenshotStage = true; return undefined; },
    viewportSize() { return viewport; },
  };
  const browser = { browserType: () => ({ name: () => 'chromium' }), version: () => '120.0' };
  const expect = (p) => ({
    async toHaveScreenshot(name, opts) {
      calls.push(['toHaveScreenshot', name, opts]);
      if (matcherError) throw matcherError;
    },
  });
  const testInfo = { project: { name: 'desktop-chrome', ignoreSnapshots }, config: { version: '1.50.0' }, repeatEachIndex: 0, retry: 0, testId: 'tid-1', attachments, title: 'x' };
  return { page, browser, expect, testInfo, calls };
}
function workerManifest(pass = 'compare', extra = {}) {
  const dir = tmp('regression-visual-worker-');
  const snap = path.join(dir, 'expected');
  return { run_dir: dir, nonce: 'n1', visual: { pass, repeat_each: 1, snapshot_dir: snap, mask: [], max_mask_ratio: 0.25, tolerance: { threshold: 0.2, max_diff_pixels: 0 }, timezone: 'UTC', ...extra } };
}
const evidenceOf = (m) => fs.readFileSync(path.join(m.run_dir, 'visual.jsonl'), 'utf8').split('\n').filter(Boolean).map((l) => JSON.parse(l));
const routeTarget = (extra = {}) => ({ id: 'route:home', source: 'routes', title: 'Home', url: '/', mask: [], full_page: false, wait_for: null, ready: null, error: null, file: 'routes--home.png', ...extra });
const storyTarget = (extra = {}) => ({ id: 'story:button--primary', source: 'storybook', title: 'Button / Primary', url: 'https://sb.example.com/iframe.html?id=button--primary&viewMode=story', mask: [], full_page: false, wait_for: null, ready: 'body[data-visual-ready]', error: '.sb-show-errordisplay', file: 'storybook--button--primary.png', ...extra });
const matcherFailure = (diag) => new Error(`expect(page).toHaveScreenshot(expected) failed\n\n${diag}\n\nCall log:\n  - Expect "toHaveScreenshot" with timeout 5000ms\n  - Timeout 5000ms exceeded.`);

// ---------------------------------------------------------------------------------------------
// Config

test('visual config validation refuses forbidden flags, root masks and overlapping paths', async () => {
  const { validateConfig } = await lib('config');
  const root = copyRoot();
  const base = readConfig(root);
  assert.deepEqual(validateConfig(base), []);
  const errs = (fn) => { const c = structuredClone(base); fn(c); return validateConfig(c).join('\n'); };
  for (const flag of ['--update-snapshots', '-u', '--update-snapshots=all', '--repeat-each 3', '--grep home', '-g x', '--project desktop']) {
    assert.match(errs((c) => { c.visual.command = `npx playwright test ${flag}`; }), /^visual\.command:/m, flag);
  }
  assert.match(errs((c) => { c.visual.mask = [{ selector: 'body', reason: 'all' }]; }), /^visual\.mask/m);
  assert.match(errs((c) => { c.visual.routes[0].mask = [{ selector: ' :root ', reason: 'x' }]; }), /^visual\.routes\.0\.mask/m);
  assert.match(errs((c) => { c.visual.mask = [{ selector: '.price' }]; }), /^visual\.mask/m, 'a mask needs a reason');
  assert.match(errs((c) => { c.visual.baselines = 'e2e/regression/shots'; }), /^visual\.baselines:.*runner\.spec_dir/m);
  assert.match(errs((c) => { c.visual.spec = 'e2e/regression/visual.spec.ts'; }), /^visual\.spec:.*runner\.spec_dir/m);
  assert.match(errs((c) => { c.visual.baselines = 'e2e/visual/shots'; }), /^visual\.baselines:.*visual\.spec/m);
  assert.match(errs((c) => { c.visual.baselines = 'e2e'; }), /^visual\.baselines:.*runner\.report/m);
  assert.match(errs((c) => { c.visual.baselines = '.agents/regression/runs/b'; }), /^visual\.baselines:.*\.agents\/regression\/runs/m);
  assert.match(errs((c) => { c.visual.baselines = '../shots'; }), /^visual\.baselines:/m);
  assert.match(errs((c) => { c.visual.tolerance = { threshold: 2, max_diff_pixels: 0 }; }), /^visual\.tolerance\.threshold:/m);
  assert.match(errs((c) => { c.visual.tolerance = { threshold: 0.1, max_diff_pixels: -1 }; }), /^visual\.tolerance\.max_diff_pixels:/m);
  assert.match(errs((c) => { c.visual.policy = 'fail'; }), /^visual\.policy:/m);
  assert.match(errs((c) => { c.visual.max_mask_ratio = 0; }), /^visual\.max_mask_ratio:/m);
  assert.match(errs((c) => { c.visual.routes.push({ ...c.visual.routes[0] }); }), /^visual\.routes\.2\.id:.*duplicate/m);
  assert.match(errs((c) => { c.visual.routes[0].path = 'https://x.example.com/'; }), /^visual\.routes\.0\.path:/m);
  assert.match(errs((c) => { c.visual.routes[0].devices = ['tablet']; }), /^visual\.routes\.0\.devices:/m);
  assert.match(errs((c) => { c.visual.routes = []; }), /^visual\.routes:/m);
  assert.match(errs((c) => { delete c.visual.report; }), /^visual\.report:/m);
  assert.equal(errs((c) => { c.visual._doc = 'x'; c.visual.future_key = 1; }), '', 'doc and unknown keys stay accepted');
});

test('storybook on a production environment is a config error', async () => {
  const { validateConfig } = await lib('config');
  const root = copyRoot();
  const cfg = readConfig(root);
  cfg.visual.storybook = { prod: { url: 'https://shop.example.com', ready: 'body[data-visual-ready]' } };
  assert.ok(validateConfig(cfg).includes('visual.storybook.prod: storybook is allowed only on a kind: test environment'), validateConfig(cfg).join('\n'));
  cfg.visual.storybook = { test: { url: 'https://sb.test.shop.example.com', ready: 'body[data-visual-ready]' } };
  assert.match(validateConfig(cfg).join('\n'), /visual\.storybook\.test\.url:.*guard\.hosts/, 'the storybook host must be on the allowlist');
  cfg.environments.test.guard = { hosts: ['test.shop.example.com', 'sb.test.shop.example.com'] };
  assert.deepEqual(validateConfig(cfg), []);
  cfg.visual.storybook.test.url = 'http://localhost:6006';
  assert.match(validateConfig(cfg).join('\n'), /visual\.storybook\.test\.url:/);
  cfg.visual.storybook.test = { url: 'https://sb.test.shop.example.com' };
  assert.match(validateConfig(cfg).join('\n'), /visual\.storybook\.test\.ready:/, 'ready is required');
  cfg.visual.storybook = { nope: { url: 'https://sb.test.shop.example.com', ready: 'x' } };
  assert.match(validateConfig(cfg).join('\n'), /visual\.storybook\.nope:/);
  cfg.environments.test = { host: 'qa-env', kind: 'test' };
  cfg.visual.storybook = { test: { url: 'https://sb.test.shop.example.com', ready: 'x' } };
  assert.match(validateConfig(cfg).join('\n'), /visual\.storybook\.test: list the storybook host in environments\.test\.guard\.hosts/);
});

test('an output override or ignore-snapshots flag in a command is a config error', async () => {
  const { validateConfig } = await lib('config');
  const base = readConfig(copyRoot());
  const errs = (fn) => { const c = structuredClone(base); fn(c); return validateConfig(c).join('\n'); };
  for (const flag of ['--output out', '--output=out', '-o out', '--ignore-snapshots']) {
    assert.match(errs((c) => { c.visual.command = `npx playwright test ${flag}`; }), /^visual\.command:/m, flag);
  }
  assert.match(errs((c) => { c.runner.commands.full = 'npx playwright test -o elsewhere'; }), /^runner\.commands\.full:.*--output/m);
  const noVisual = structuredClone(base);
  delete noVisual.visual;
  noVisual.runner.commands.full = 'npx playwright test -o elsewhere';
  assert.deepEqual(validateConfig(noVisual), [], 'without a visual section the functional command is not checked');
});

test('a worker or retry override in the visual command is a config error', async () => {
  const { validateConfig } = await lib('config');
  const base = readConfig(copyRoot());
  for (const flag of ['--workers 4', '--workers=4', '-j 2', '--retries=1', '--retries 2']) {
    const c = structuredClone(base);
    c.visual.command = `npx playwright test ${flag}`;
    assert.match(validateConfig(c).join('\n'), /^visual\.command:/m, flag);
  }
});

test('dotted or underscored ids and project names are refused', async () => {
  const { validateConfig } = await lib('config');
  const base = readConfig(copyRoot());
  const errs = (fn) => { const c = structuredClone(base); fn(c); return validateConfig(c).join('\n'); };
  assert.match(errs((c) => { c.visual.routes[0].id = 'home.v2'; }), /^visual\.routes\.0\.id:/m);
  assert.match(errs((c) => { c.visual.routes[0].id = 'home_v2'; }), /^visual\.routes\.0\.id:/m);
  assert.match(errs((c) => { c.visual.routes[0].id = 'Home'; }), /^visual\.routes\.0\.id:/m);
  assert.match(errs((c) => { c.runner.devices.desktop = 'desktop_chrome'; }), /runner project desktop_chrome is not a safe directory name/);
  assert.match(errs((c) => { c.runner.devices.desktop = 'desktop.chrome'; }), /runner project desktop\.chrome/);
});

test('two environments keep separate baselines and unsafe env or project names are refused', async () => {
  const { validateConfig } = await lib('config');
  const root = copyRoot();
  knownBuild(root);
  editConfig(root, (cfg) => { cfg.environments.stage = { host: 'https://stage.shop.example.com', kind: 'test', build_sha_url: SHA_URL }; });
  await acceptBaselines(root);
  const before = tree(path.join(root, BASE, 'test'));
  assert.ok(before.length >= 4, before.join(','));
  const r = await run(['visual', 'compare', '--env', 'stage', '--root', root]);
  const block = recordOf(root, r).visual;
  assert.equal(block.env, 'stage');
  assert.equal(block.counts.missing, 3, 'stage has no baselines of its own — test baselines are never compared');
  assert.equal(block.counts.same, 0);
  assert.deepEqual(tree(path.join(root, BASE, 'test')), before);
  assert.equal(fs.existsSync(path.join(root, BASE, 'stage')), false);
  const cfg = readConfig(root);
  cfg.environments.my_env = { host: 'https://my.shop.example.com', kind: 'test' };
  assert.match(validateConfig(cfg).join('\n'), /visual: environment my_env is not a safe directory name/);
  delete cfg.environments.my_env;
  cfg.environments.Stage = { host: 'https://stage2.shop.example.com', kind: 'test' };
  assert.match(validateConfig(cfg).join('\n'), /visual: environment Stage/, 'names unique case-insensitively');
});

test('the shipped example validates with its storybook host allowed', async () => {
  const { validateConfig } = await lib('config');
  const example = JSON.parse(fs.readFileSync(path.join(REPO, '.claude/regression.json.example'), 'utf8'));
  assert.deepEqual(validateConfig(example), []);
  assert.equal(example.visual.policy, 'warn');
  assert.ok(example.visual.storybook.test, 'storybook on the test environment');
  assert.equal(example.visual.storybook.prod, undefined);
  const host = new URL(example.visual.storybook.test.url).hostname;
  example.environments.test.guard.hosts = example.environments.test.guard.hosts.filter((h) => h !== host);
  assert.match(validateConfig(example).join('\n'), /visual\.storybook\.test/);
});

// ---------------------------------------------------------------------------------------------
// Plan (policy.mjs)

test('production plan binds the visual action pass count and route cases', async () => {
  const { buildPlan, confirmationText, visualPlan } = await lib('policy');
  const root = copyRoot();
  const cfg = readConfig(root);
  const compare = buildPlan(root, cfg, 'prod', 'visual', { visualAction: 'compare' });
  const update = buildPlan(root, cfg, 'prod', 'visual', { visualAction: 'update' });
  assert.equal(compare.cases.length, 0, 'a visual plan selects no functional case');
  assert.deepEqual(compare.visual.passes, ['compare']);
  assert.deepEqual(update.visual.passes, ['capture', 'stability']);
  assert.equal(update.visual.repeat.stability, 3);
  assert.equal(compare.visual.cases.length, 3);
  assert.deepEqual(compare.visual.cases.map((c) => `${c.id}/${c.project}`).sort(), ['route:cart/desktop-chrome', 'route:home/desktop-chrome', 'route:home/mobile-safari']);
  assert.equal(compare.visual.storybook, null);
  assert.notEqual(compare.digests.plan, update.digests.plan, 'the action is bound');
  const cfg2 = structuredClone(cfg);
  cfg2.visual.routes[1].devices = ['desktop', 'mobile'];
  assert.notEqual(buildPlan(root, cfg2, 'prod', 'visual', { visualAction: 'compare' }).digests.plan, compare.digests.plan, 'every route case is bound');
  const text = confirmationText(update);
  assert.match(text, /^visual: update · passes capture, stability \(stability ×3\) · 3 route cases on desktop-chrome, mobile-safari · policy warn$/m);
  assert.match(text, /^visual baselines: none for prod$/m);
  assert.equal(buildPlan(root, cfg, 'prod', 'smoke').visual, undefined, 'smoke never carries the visual part');
  assert.ok(buildPlan(root, cfg, 'prod', 'full').visual, 'full does');
  const vp = visualPlan(cfg, 'prod', 'compare');
  assert.equal(vp.digest, compare.visual.digest);
});

test('production route cases reach the manifest exactly once', async () => {
  const root = copyRoot();
  knownBuild(root, 'prod');
  const r = await prodVisual(root, 'compare');
  assert.notEqual(r.status, 3, r.out);
  const rec = recordOf(root, r);
  const manifest = JSON.parse(fs.readFileSync(path.join(root, RUNS, rec.run_id, 'visual/compare/manifest.json'), 'utf8'));
  const keys = manifest.selection.map((c) => `${c.id}/${c.project}`);
  assert.deepEqual([...keys].sort(), ['route:cart/desktop-chrome', 'route:home/desktop-chrome', 'route:home/mobile-safari']);
  assert.equal(new Set(keys).size, keys.length);
  assert.ok(manifest.selection.every((c) => c.spec === 'e2e/visual/visual.spec.ts'));
  assert.equal(rec.confirmed, true);
});

test('pre-flight covers the visual config and spec on production', async () => {
  const run_ = await lib('run');
  const root = copyRoot();
  knownBuild(root, 'prod');
  const spec = path.join(root, 'e2e/visual/visual.spec.ts');
  const good = fs.readFileSync(spec, 'utf8');
  fs.writeFileSync(spec, good.replace("from '../fixtures'", "from '@playwright/test'"));
  let r = await run(['visual', 'compare', '--env', 'prod', '--root', root]);
  assert.equal(r.status, 3);
  assert.match(r.stderr, /runner not guard-integrated — e2e\/visual\/visual\.spec\.ts: imports test from @playwright\/test/);
  assert.equal(confirmTokenOf(r), undefined);
  fs.writeFileSync(spec, good);
  const config = path.join(root, 'e2e/visual/visual.config.ts');
  fs.writeFileSync(config, fs.readFileSync(config, 'utf8').replace("import { visualOptions } from '../../.claude/lib/regression/visual-spec.mjs';\n", ''));
  r = await run(['visual', 'compare', '--env', 'prod', '--root', root]);
  assert.equal(r.status, 3);
  assert.match(r.stderr, /e2e\/visual\/visual\.config\.ts: does not import visualOptions from \.claude\/lib\/regression\/visual-spec\.mjs/);
  assert.equal(callsOf(root).length, 0);
  assert.equal(typeof run_.scanIntegration, 'function');
});

// ---------------------------------------------------------------------------------------------
// Sources

test('storybook source enumerates stories from index.json and skips excluded tags', async () => {
  const { SOURCES } = await lib('visual');
  const root = copyRoot();
  const cfg = readConfig(root);
  cfg.environments.test.guard = { hosts: ['test.shop.example.com', 'sb.example.com'] };
  cfg.visual.storybook = { test: { url: 'https://sb.example.com', ready: 'body[data-visual-ready]', error: '.sb-show-errordisplay', exclude_tags: ['visual-skip'] } };
  const settings = (await lib('config')).visualSettings(cfg);
  const answer = (doc) => async (manifest, { url }) => { assert.equal(url, 'https://sb.example.com/index.json'); return { status: 200, text: () => JSON.stringify(doc) }; };
  const v5 = {
    v: 5,
    entries: {
      'button--primary': { type: 'story', id: 'button--primary', title: 'Button', name: 'Primary', tags: ['dev'] },
      'button--docs': { type: 'docs', id: 'button--docs', title: 'Button', name: 'Docs', tags: [] },
      'banner--promo': { type: 'story', id: 'banner--promo', title: 'Banner', name: 'Promo', tags: ['visual-skip'] },
      'Odd_Id': { type: 'story', id: 'Odd_Id', title: 'Odd', name: 'Id', tags: [] },
    },
  };
  const r = await SOURCES.storybook.enumerate({ cfg, env: 'test', settings, manifest: {}, fetch: answer(v5) });
  assert.equal(r.state, 'ok');
  assert.deepEqual(r.targets.map((t) => t.id), ['story:button--primary']);
  const t = r.targets[0];
  assert.equal(t.url, 'https://sb.example.com/iframe.html?id=button--primary&viewMode=story');
  assert.equal(t.file, 'storybook--button--primary.png');
  assert.equal(t.ready, 'body[data-visual-ready]');
  assert.deepEqual(t.devices, ['desktop', 'mobile']);
  assert.deepEqual(t.mask, []);
  assert.deepEqual(r.skipped.map((s) => s.id), ['Odd_Id']);
  assert.match(r.index_digest, /^[0-9a-f]{64}$/);
  const v3 = await SOURCES.storybook.enumerate({ cfg, env: 'test', settings, manifest: {}, fetch: answer({ v: 3, stories: { 'card--a': { id: 'card--a', title: 'Card', name: 'A' } } }) });
  assert.deepEqual(v3.targets.map((x) => x.id), ['story:card--a']);
  const bad = await SOURCES.storybook.enumerate({ cfg, env: 'test', settings, manifest: {}, fetch: async () => { throw new Error('regression guard blocked stopped'); } });
  assert.equal(bad.state, 'failed');
  assert.deepEqual(bad.targets, []);
  const shape = await SOURCES.storybook.enumerate({ cfg, env: 'test', settings, manifest: {}, fetch: answer({ v: 9 }) });
  assert.equal(shape.state, 'failed');
  const routes = await SOURCES.routes.enumerate({ cfg, env: 'test', settings });
  assert.deepEqual(routes.targets.map((x) => x.id), ['route:home', 'route:cart']);
});

test('an empty storybook index keeps story baselines and offers no removal', async () => {
  const v = await lib('visual');
  const root = copyRoot();
  const cfg = readConfig(root);
  cfg.environments.test.guard = { hosts: ['test.shop.example.com', 'sb.example.com'] };
  cfg.visual.storybook = { test: { url: 'https://sb.example.com', ready: 'body[data-visual-ready]' } };
  const settings = (await lib('config')).visualSettings(cfg);
  const empty = await v.SOURCES.storybook.enumerate({ cfg, env: 'test', settings, manifest: {}, fetch: async () => ({ status: 200, text: () => JSON.stringify({ v: 5, entries: {} }) }) });
  assert.equal(empty.state, 'failed', 'zero eligible stories is a failed source');
  const index = { images: { 'desktop-chrome/storybook--card--a.png': { sha256: 'x' }, 'desktop-chrome/routes--old.png': { sha256: 'y' } } };
  const sources = [{ name: 'routes', state: 'ok' }, { name: 'storybook', state: 'failed' }];
  const cases = [{ id: 'route:home', project: 'desktop-chrome', file: 'routes--home.png', source: 'routes' }];
  const orphans = v.orphanKeys({ index, cases, sources, noDeviceFiles: [] });
  assert.deepEqual(orphans, ['desktop-chrome/routes--old.png'], 'story baselines of a failed source are never orphans');
});

// ---------------------------------------------------------------------------------------------
// Worker side (visual-spec.mjs)

test('visualOptions derives the snapshot template, update mode, repeat and output from the manifest', async () => {
  const { visualOptions } = await lib('visual-spec');
  const root = '/r';
  const m = { workers: 2, visual: { pass: 'capture', repeat_each: 1, output_dir: '/r/.agents/regression/runs/x/visual/capture/output', snapshot_dir: '/r/.agents/regression/runs/x/visual/capture/candidates', config_dir: '/r/e2e/visual', spec_abs: '/r/e2e/visual/visual.spec.ts', tolerance: { threshold: 0.1, max_diff_pixels: 3 }, timezone: 'Europe/Warsaw' } };
  const o = visualOptions(m);
  assert.equal(o.snapshotPathTemplate, '../../.agents/regression/runs/x/visual/capture/candidates/{projectName}/{arg}{ext}');
  assert.equal(o.expect.toHaveScreenshot.pathTemplate, o.snapshotPathTemplate);
  assert.equal(o.updateSnapshots, 'all');
  assert.equal(o.repeatEach, 1);
  assert.equal(o.retries, 0);
  assert.equal(o.outputDir, m.visual.output_dir);
  assert.equal(o.testDir, `${root}/e2e/visual`);
  assert.equal(o.ignoreSnapshots, false);
  assert.equal(o.expect.toHaveScreenshot.threshold, 0.1);
  assert.equal(o.expect.toHaveScreenshot.maxDiffPixels, 3);
  assert.equal(o.expect.toHaveScreenshot.animations, 'disabled');
  assert.equal(o.expect.toHaveScreenshot.caret, 'hide');
  assert.equal(o.use.timezoneId, 'Europe/Warsaw');
  assert.equal(o.use.serviceWorkers, 'block');
  const s = visualOptions({ ...m, visual: { ...m.visual, pass: 'stability', repeat_each: 3 } });
  assert.equal(s.updateSnapshots, 'none');
  assert.equal(s.repeatEach, 3);
  assert.equal(visualOptions({ ...m, visual: { ...m.visual, pass: 'compare' } }).updateSnapshots, 'none');
});

test('visualOptions matches only the configured visual spec', async () => {
  const { visualOptions, visualTargets } = await lib('visual-spec');
  const o = visualOptions({ visual: { pass: 'compare', snapshot_dir: '/r/s', config_dir: '/r/e2e/visual', spec_abs: '/r/e2e/visual/visual.spec.ts', output_dir: '/r/o' } });
  assert.equal(o.testMatch.test('/r/e2e/visual/visual.spec.ts'), true);
  assert.equal(o.testMatch.test('/r/e2e/visual/sub/visual.spec.ts'), false);
  assert.equal(o.testMatch.test('/r/e2e/visual/visual.spec.ts.bak'), false);
  assert.equal(o.testMatch.test('/r/e2e/visual/visualXspec.ts'), false, 'the dot is escaped');
  assert.deepEqual(visualTargets({ selection: [] }), [], 'a functional manifest defines no visual test');
});

test('renderTarget records outcomes keyed by pass, project, target, repeat and retry', async () => {
  const { renderTarget } = await lib('visual-spec');
  const m = workerManifest('compare');
  fs.mkdirSync(path.join(m.visual.snapshot_dir, 'desktop-chrome'), { recursive: true });
  fs.writeFileSync(path.join(m.visual.snapshot_dir, 'desktop-chrome/routes--home.png'), PNG_SIG);
  const w = fakeWorld();
  await renderTarget({ page: w.page, browser: w.browser }, w.testInfo, routeTarget(), w.expect, m);
  const ev = evidenceOf(m);
  const renderer = ev.find((e) => e.kind === 'renderer');
  assert.equal(renderer.project, 'desktop-chrome');
  assert.equal(renderer.fp.browser, 'chromium');
  assert.equal(renderer.fp.browser_version, '120.0');
  assert.equal(renderer.fp.playwright, '1.50.0');
  assert.match(renderer.fp.fonts, /^[0-9a-f]{12}$/);
  assert.ok(['host', 'container'].includes(renderer.fp.mode));
  const out = ev.filter((e) => e.kind === 'outcome');
  assert.equal(out.length, 1);
  assert.deepEqual({ pass: out[0].pass, id: out[0].id, project: out[0].project, repeat: out[0].repeat, retry: out[0].retry, test: out[0].test, outcome: out[0].outcome, nonce: out[0].nonce },
    { pass: 'compare', id: 'route:home', project: 'desktop-chrome', repeat: 0, retry: 0, test: 'tid-1', outcome: 'same', nonce: 'n1' });
  const shot = w.calls.find((c) => c[0] === 'toHaveScreenshot');
  assert.deepEqual(shot[1], ['routes--home.png']);
  assert.equal(shot[2].maskColor, '#FF00FF');
  const w2 = fakeWorld();
  w2.testInfo.repeatEachIndex = 2;
  w2.testInfo.retry = 1;
  await renderTarget({ page: w2.page, browser: w2.browser }, w2.testInfo, routeTarget({ id: 'route:x', file: 'routes--x.png' }), w2.expect, m);
  const last = evidenceOf(m).filter((e) => e.kind === 'outcome').at(-1);
  assert.equal(last.outcome, 'missing', 'no expected file: missing, no assertion');
  assert.equal(last.repeat, 2);
  assert.equal(last.retry, 1);
  assert.equal(w2.calls.some((c) => c[0] === 'toHaveScreenshot'), false);
  assert.equal(evidenceOf(m).filter((e) => e.kind === 'renderer').length, 1, 'one renderer line per worker and project');
  const cap = workerManifest('capture');
  const w3 = fakeWorld();
  await renderTarget({ page: w3.page, browser: w3.browser }, w3.testInfo, routeTarget(), w3.expect, cap);
  assert.equal(evidenceOf(cap).filter((e) => e.kind === 'outcome')[0].outcome, 'captured');
  const ig = fakeWorld({ ignoreSnapshots: true });
  await assert.rejects(renderTarget({ page: ig.page, browser: ig.browser }, ig.testInfo, routeTarget(), ig.expect, workerManifest('compare')));
});

test('renderTarget refuses a non-2xx navigation, an unready story and an oversized mask', async () => {
  const { renderTarget } = await lib('visual-spec');
  const outcomeOf = async (world, target, m = workerManifest('compare')) => {
    await assert.rejects(renderTarget({ page: world.page, browser: world.browser }, world.testInfo, target, world.expect, m));
    return evidenceOf(m).filter((e) => e.kind === 'outcome').at(-1);
  };
  let o = await outcomeOf(fakeWorld({ status: 404 }), routeTarget());
  assert.equal(o.outcome, 'error');
  assert.equal(o.reason, 'navigation 404');
  o = await outcomeOf(fakeWorld({ status: null }), routeTarget());
  assert.match(o.reason, /^navigation/);
  o = await outcomeOf(fakeWorld({ readyAttached: false }), storyTarget());
  assert.equal(o.reason, 'story not ready');
  const m = workerManifest('compare', { mask: [{ selector: '.banner', reason: 'promo' }] });
  o = await outcomeOf(fakeWorld({ boxes: { '.banner': [{ x: 0, y: 0, width: 100, height: 30 }] } }), routeTarget(), m);
  assert.equal(o.outcome, 'error');
  assert.equal(o.reason, 'mask covers 30.0%');
  assert.equal(o.masked_ratio, 0.3);
});

test('renderTarget waits for the story completion signal and fails on a delayed error', async () => {
  const { renderTarget } = await lib('visual-spec');
  const m = workerManifest('compare');
  const counts = { 'body[data-visual-ready]': 1, '.sb-show-errordisplay': 0 };
  const boxes = { '#storybook-root > *': [{ x: 0, y: 0, width: 50, height: 20 }] };
  const ok = fakeWorld({ counts: { ...counts, '#storybook-root': 1 }, boxes });
  await renderTarget({ page: ok.page, browser: ok.browser }, ok.testInfo, storyTarget(), ok.expect, m);
  const wait = ok.calls.find((c) => c[0] === 'waitFor');
  assert.deepEqual(wait, ['waitFor', 'body[data-visual-ready], .sb-show-errordisplay', 'attached']);
  assert.equal(evidenceOf(m).filter((e) => e.kind === 'outcome').at(-1).outcome, 'missing');
  const late = fakeWorld({ counts: { ...counts, '#storybook-root': 1 }, boxes, laterCounts: { '.sb-show-errordisplay': 1 } });
  await assert.rejects(renderTarget({ page: late.page, browser: late.browser }, late.testInfo, storyTarget(), late.expect, m));
  const o = evidenceOf(m).filter((e) => e.kind === 'outcome').at(-1);
  assert.equal(o.outcome, 'error');
  assert.equal(o.reason, 'story error display');
});

test('a story with an empty root is an error', async () => {
  const { renderTarget } = await lib('visual-spec');
  const m = workerManifest('compare');
  const w = fakeWorld({ counts: { 'body[data-visual-ready]': 1, '#storybook-root': 1 }, boxes: { '#storybook-root > *': [{ x: 0, y: 0, width: 0, height: 0 }] } });
  await assert.rejects(renderTarget({ page: w.page, browser: w.browser }, w.testInfo, storyTarget(), w.expect, m));
  assert.equal(evidenceOf(m).filter((e) => e.kind === 'outcome').at(-1).reason, 'story rendered nothing');
});

test('a matcher failure without a comparison is an error, not differs', async () => {
  const { renderTarget } = await lib('visual-spec');
  const m = workerManifest('compare');
  fs.mkdirSync(path.join(m.visual.snapshot_dir, 'desktop-chrome'), { recursive: true });
  fs.writeFileSync(path.join(m.visual.snapshot_dir, 'desktop-chrome/routes--home.png'), PNG_SIG);
  const w = fakeWorld({ matcherError: matcherFailure('  Target page, context or browser has been closed') });
  await assert.rejects(renderTarget({ page: w.page, browser: w.browser }, w.testInfo, routeTarget(), w.expect, m));
  const o = evidenceOf(m).filter((e) => e.kind === 'outcome').at(-1);
  assert.equal(o.outcome, 'error');
  assert.equal(o.reason, 'screenshot failed — Target page, context or browser has been closed');
  const d = fakeWorld({ matcherError: matcherFailure('  12 pixels (ratio 0.01 of all image pixels) are different.'), attachments: [{ name: 'routes--home-diff.png', path: path.join(process.cwd(), 'out/routes--home-diff.png') }] });
  await assert.rejects(renderTarget({ page: d.page, browser: d.browser }, d.testInfo, routeTarget(), d.expect, m));
  const od = evidenceOf(m).filter((e) => e.kind === 'outcome').at(-1);
  assert.equal(od.outcome, 'differs');
  assert.equal(od.diff_pixels, 12);
  assert.equal(od.diff, 'out/routes--home-diff.png');
});

test('an unstable render is an error, not differs', async () => {
  const { renderTarget } = await lib('visual-spec');
  const m = workerManifest('compare');
  fs.mkdirSync(path.join(m.visual.snapshot_dir, 'desktop-chrome'), { recursive: true });
  fs.writeFileSync(path.join(m.visual.snapshot_dir, 'desktop-chrome/routes--home.png'), PNG_SIG);
  const w = fakeWorld({ matcherError: matcherFailure('  Failed to take two consecutive stable screenshots.') });
  await assert.rejects(renderTarget({ page: w.page, browser: w.browser }, w.testInfo, routeTarget(), w.expect, m));
  const o = evidenceOf(m).filter((e) => e.kind === 'outcome').at(-1);
  assert.equal(o.outcome, 'error');
  assert.equal(o.reason, 'render never stable');
});

test('the screenshot diagnostic below the matcher header is classified', async () => {
  const { classifyMatcherError } = await lib('visual-spec');
  const diffs = classifyMatcherError(matcherFailure('  12 pixels (ratio 0.01 of all image pixels) are different.').message);
  assert.deepEqual({ outcome: diffs.outcome, diff_pixels: diffs.diff_pixels }, { outcome: 'differs', diff_pixels: 12 }, 'the Call log timeout line is not the diagnostic');
  const size = classifyMatcherError(matcherFailure('  Expected an image 100px by 100px, received 100px by 120px.').message);
  assert.equal(size.outcome, 'differs');
  assert.equal(size.diff_pixels, null);
  const header = classifyMatcherError('expect(page).toHaveScreenshot(12 pixels (ratio 0.01 of all image pixels) are different) failed\n\n  Screenshot comparison failed: unreadable expected image\n\nCall log:\n  - x');
  assert.equal(header.outcome, 'error', 'text in the header line is not comparison evidence');
});

test('overlapping and repeated masks are measured as a union', async () => {
  const { renderTarget, unionArea } = await lib('visual-spec');
  assert.equal(unionArea([{ x: 0, y: 0, width: 10, height: 10 }, { x: 5, y: 5, width: 10, height: 10 }], 100, 100), 175);
  assert.equal(unionArea([{ x: 0, y: 0, width: 10, height: 10 }, { x: 0, y: 0, width: 10, height: 10 }], 100, 100), 100);
  assert.equal(unionArea([{ x: -5, y: 95, width: 10, height: 10 }], 100, 100), 25, 'clipped to the shot');
  const m = workerManifest('compare', { mask: [{ selector: '.a', reason: 'a' }] });
  const box = { x: 0, y: 0, width: 10, height: 10 };
  const w = fakeWorld({ boxes: { '.a': [box, box], '.b': [{ x: 5, y: 0, width: 10, height: 10 }] } });
  await renderTarget({ page: w.page, browser: w.browser }, w.testInfo, routeTarget({ mask: [{ selector: '.b', reason: 'b' }, { selector: '.a', reason: 'again' }] }), w.expect, m);
  const o = evidenceOf(m).filter((e) => e.kind === 'outcome').at(-1);
  assert.equal(o.masked_ratio, 0.015);
});

// ---------------------------------------------------------------------------------------------
// Compare, verdict and integrity (CLI)

test('compare reports differs, missing and orphan baselines in the visual block', async () => {
  const root = copyRoot();
  knownBuild(root);
  await acceptBaselines(root);
  editConfig(root, (cfg) => {
    cfg.visual.routes = [cfg.visual.routes[0], { id: 'pdp', path: '/p/1', title: 'Product', devices: ['desktop'] }];
  });
  useVisual(root, 'differs:route:home');
  const r = await run(['visual', 'compare', '--root', root]);
  const rec = recordOf(root, r);
  assert.equal(rec.mode, 'visual');
  assert.deepEqual(rec.cases, []);
  const b = rec.visual;
  assert.deepEqual(b.counts, { same: 0, differs: 2, missing: 1, orphan: 1, error: 0, not_comparable: 0 });
  assert.deepEqual(b.orphans, ['desktop-chrome/routes--cart.png']);
  assert.equal(b.outcome, 'differs');
  const home = b.targets.find((t) => t.id === 'route:home' && t.project === 'desktop-chrome');
  assert.equal(home.outcome, 'differs');
  assert.equal(home.diff_pixels, 12);
  assert.match(r.stdout, /^visual: differs — same 0 · differs 2 · missing 1 · orphan 1 · error 0 · not comparable 0$/m);
});

test('visual differences warn by default and fail the run under block', async () => {
  const root = copyRoot();
  knownBuild(root);
  await acceptBaselines(root);
  useVisual(root, 'differs:route:cart');
  let r = await run(['visual', 'compare', '--root', root]);
  assert.equal(r.status, 0, r.out);
  assert.equal(recordOf(root, r).verdict, 'GREEN');
  assert.match(r.stdout, /^warning: visual differs: route:cart\/desktop-chrome/m);
  editConfig(root, (cfg) => { cfg.visual.policy = 'block'; });
  r = await run(['visual', 'compare', '--root', root]);
  assert.equal(r.status, 1, r.out);
  assert.equal(recordOf(root, r).verdict, 'RED');
  assert.match(r.stdout, /^reason: visual differs: route:cart\/desktop-chrome/m);
});

test('an incomplete visual pass warns under warn and is incomplete under block', async () => {
  const root = copyRoot();
  knownBuild(root);
  await acceptBaselines(root);
  useVisual(root, 'error:route:cart');
  let r = await run(['visual', 'compare', '--root', root]);
  assert.equal(r.status, 0, r.out);
  assert.match(r.stdout, /^warning: visual error: route:cart\/desktop-chrome — navigation 500$/m);
  assert.equal(recordOf(root, r).visual.outcome, 'incomplete');
  editConfig(root, (cfg) => { cfg.visual.policy = 'block'; });
  r = await run(['visual', 'compare', '--root', root]);
  assert.equal(r.status, 4, r.out);
  assert.equal(recordOf(root, r).verdict, 'INCOMPLETE');
  useVisual(root, 'drop-repeat:route:home');
  r = await run(['visual', 'compare', '--root', root]);
  assert.equal(r.status, 4, r.out);
  assert.match(r.stdout, /^reason: visual error: route:home\/desktop-chrome — no outcome$/m);
  useVisual(root, 'no-report');
  r = await run(['visual', 'compare', '--root', root]);
  assert.equal(r.status, 4, r.out);
  assert.match(r.stdout, /visual report missing/);
});

test('guard verdict holds over the visual pass under warn', async () => {
  const root = copyRoot();
  knownBuild(root);
  await acceptBaselines(root);
  useVisual(root, 'blocked:route:home');
  let r = await run(['visual', 'compare', '--root', root]);
  assert.equal(r.status, 1, r.out);
  assert.equal(recordOf(root, r).verdict, 'RED');
  assert.match(r.stdout, /^reason: guard blocked a request in route:home\/desktop-chrome$/m);
  useVisual(root, 'blocked-outside');
  r = await run(['visual', 'compare', '--root', root]);
  assert.equal(r.status, 1, r.out);
  assert.match(r.stdout, /^reason: blocked request outside a test$/m);
  useVisual(root, 'stop');
  r = await run(['visual', 'compare', '--root', root]);
  assert.equal(r.status, 5, r.out);
  assert.equal(recordOf(root, r).verdict, 'BLOCKED/ENV');
});

test('a guarded visual block after a green functional pass is red under both policies', async () => {
  for (const policy of ['warn', 'block']) {
    const root = copyRoot();
    knownBuild(root);
    await acceptBaselines(root);
    editConfig(root, (cfg) => { cfg.visual.policy = policy; });
    useVisual(root, 'blocked:route:cart');
    const r = await run(['run', 'full', '--root', root]);
    const rec = recordOf(root, r);
    assert.equal(rec.verdict, 'RED', `${policy}: ${r.out}`);
    assert.ok(rec.reasons.includes('guard blocked a request in route:cart/desktop-chrome'), rec.reasons.join('\n'));
    assert.ok(rec.cases.every((c) => c.result === 'passed'), 'the functional pass was green');
  }
});

test('baselines integrity reasons are incomplete under both policies', async () => {
  for (const policy of ['warn', 'block']) {
    const root = copyRoot();
    knownBuild(root);
    await acceptBaselines(root);
    editConfig(root, (cfg) => { cfg.visual.policy = policy; });
    fs.appendFileSync(path.join(root, BASE, 'test/desktop-chrome/routes--home.png'), 'x');
    let r = await run(['visual', 'compare', '--root', root]);
    assert.equal(r.status, 4, `${policy}: ${r.out}`);
    assert.match(r.stdout, /^reason: baseline altered outside visual accept: e2e\/visual-baselines\/test\/desktop-chrome\/routes--home\.png$/m);
    const root2 = copyRoot();
    knownBuild(root2);
    await acceptBaselines(root2);
    editConfig(root2, (cfg) => { cfg.visual.policy = policy; });
    fs.writeFileSync(path.join(root2, BASE, 'test/desktop-chrome/routes--extra.png'), PNG_SIG);
    r = await run(['visual', 'compare', '--root', root2]);
    assert.equal(r.status, 4, r.out);
    assert.match(r.stdout, /^reason: baseline not accepted: e2e\/visual-baselines\/test\/desktop-chrome\/routes--extra\.png$/m);
  }
});

test('a run that changes the baselines tree is incomplete', async () => {
  const root = copyRoot();
  knownBuild(root);
  await acceptBaselines(root);
  useVisual(root, 'touch-baselines');
  let r = await run(['visual', 'compare', '--root', root]);
  assert.equal(r.status, 4, r.out);
  assert.match(r.stdout, /^reason: baselines changed during the run \(compare\)$/m);
  fs.rmSync(path.join(root, BASE, 'test/touched.txt'));
  useFunctional(root, 'touch-baselines');
  r = await run(['run', 'smoke', '--root', root]);
  assert.equal(r.status, 4, r.out);
  const rec = recordOf(root, r);
  assert.deepEqual(rec.visual, { integrity: ['baselines changed during the run (functional)'] });
});

test('a functional runner that changes an accepted file makes run full incomplete', async () => {
  const root = copyRoot();
  knownBuild(root);
  await acceptBaselines(root);
  useFunctional(root, 'touch-accepted');
  const r = await run(['run', 'full', '--root', root]);
  assert.equal(r.status, 4, r.out);
  const rec = recordOf(root, r);
  assert.ok(rec.reasons.includes('baselines changed during the run (functional)'), rec.reasons.join('\n'));
  assert.equal(rec.visual.outcome, 'incomplete');
});

test('a sibling environment write or a change restored by a later pass is an integrity reason', async () => {
  const root = copyRoot();
  knownBuild(root);
  await acceptBaselines(root);
  useVisual(root, 'touch-baselines:prod');
  let r = await run(['visual', 'compare', '--root', root]);
  assert.equal(r.status, 4, r.out);
  assert.match(r.stdout, /^reason: baselines changed during the run \(compare\)$/m);
  const root2 = copyRoot();
  knownBuild(root2);
  useVisual(root2, 'touch-baselines@capture,untouch-baselines@stability');
  r = await run(['visual', 'update', '--root', root2]);
  assert.notEqual(r.status, 3, r.out);
  assert.match(r.stdout, /^reason: baselines changed during the run \(capture\)$/m);
  assert.match(r.stdout, /^visual offer: none — /m);
  assert.equal(acceptTokenOf(r), undefined);
});

test('functional output dirs overlapping the baselines refuse before any runner call', async () => {
  const root = copyRoot();
  knownBuild(root);
  fs.writeFileSync(path.join(root, 'package.json'), '{}\n');
  editConfig(root, (cfg) => { cfg.visual.baselines = 'test-results/shots'; });
  let r = await run(['run', 'smoke', '--root', root]);
  assert.equal(r.status, 3, r.out);
  assert.match(r.stderr, /^refused: visual\.baselines overlaps the functional outputDir/m);
  assert.equal(callsOf(root).length, 0);
  const root2 = copyRoot();
  knownBuild(root2);
  const config = path.join(root2, 'e2e/playwright.config.ts');
  fs.writeFileSync(config, fs.readFileSync(config, 'utf8').replace("testDir: './regression',", "testDir: './regression',\n  outputDir: './visual-baselines',"));
  r = await run(['visual', 'compare', '--root', root2]);
  assert.equal(r.status, 3, r.out);
  assert.match(r.stderr, /^refused: visual\.baselines overlaps the functional outputDir/m);
  fs.writeFileSync(config, fs.readFileSync(config, 'utf8').replace("outputDir: './visual-baselines',", 'outputDir: path.join(x),'));
  r = await run(['run', 'full', '--root', root2]);
  assert.equal(r.status, 3, r.out);
  assert.match(r.stderr, /cannot resolve the functional outputDir/);
  assert.equal(callsOf(root2).length, 0);
});

test('widened tolerance is refused by compare and update', async () => {
  const root = copyRoot();
  knownBuild(root);
  editConfig(root, (cfg) => { cfg.visual.tolerance = { threshold: 0.3, max_diff_pixels: 0 }; });
  for (const action of ['compare', 'update']) {
    const r = await run(['visual', action, '--root', root]);
    assert.equal(r.status, 2, r.out);
    assert.match(r.stderr, /visual\.tolerance widened over the accepted baselines \(threshold 0\.2 → 0\.3\) — no command widens a tolerance; a human edits index\.json in a reviewed commit/);
  }
  editConfig(root, (cfg) => { cfg.visual.tolerance = { threshold: 0.2, max_diff_pixels: 5 }; });
  const r = await run(['visual', 'compare', '--root', root]);
  assert.equal(r.status, 2);
  assert.match(r.stderr, /max_diff_pixels 0 → 5/);
  assert.equal(callsOf(root).length, 0);
});

test('a tolerance narrowed by an intervening accept is enforced under the lock', async () => {
  const root = copyRoot();
  knownBuild(root);
  editConfig(root, (cfg) => { cfg.visual.tolerance = { threshold: 0.1, max_diff_pixels: 0 }; });
  await acceptBaselines(root);
  const index = JSON.parse(fs.readFileSync(path.join(root, BASE, 'test/index.json'), 'utf8'));
  assert.deepEqual(index.tolerance, { threshold: 0.1, max_diff_pixels: 0 });
  editConfig(root, (cfg) => { cfg.visual.tolerance = { threshold: 0.2, max_diff_pixels: 0 }; });
  const calls = callsOf(root).length;
  const locks = tmp('regression-locks-');
  const r = await run(['visual', 'compare', '--root', root], { locks });
  assert.equal(r.status, 2, r.out);
  assert.match(r.stderr, /threshold 0\.1 → 0\.2/);
  assert.equal(callsOf(root).length, calls);
  assert.deepEqual(fs.readdirSync(locks), [], 'the locks are released');
});

test('renderer differences make images not comparable and are named in portability', async () => {
  const root = copyRoot();
  knownBuild(root);
  await acceptBaselines(root);
  let r = await run(['visual', 'compare', '--root', root]);
  assert.equal(r.status, 0, r.out);
  assert.match(r.stdout, /^visual portability: desktop-chrome: chromium 120\.0 · Playwright 1\.50\.0 · linux 6 x64 · fonts aaaaaaaaaaaa · host — this run same$/m);
  assert.equal(recordOf(root, r).visual.outcome, 'clean');
  useVisual(root, 'renderer:browser_version,renderer:fonts');
  r = await run(['visual', 'compare', '--root', root]);
  const b = recordOf(root, r).visual;
  assert.equal(b.counts.not_comparable, 3);
  assert.equal(b.counts.same, 0);
  assert.match(r.stdout, /^visual portability: desktop-chrome: chromium 120\.0 .* — this run differs in browser_version,fonts$/m);
  const p = b.portability.find((x) => x.project === 'desktop-chrome');
  assert.deepEqual(p.differs_in, ['browser_version', 'fonts']);
  useVisual(root, 'split-renderer');
  r = await run(['visual', 'compare', '--root', root]);
  assert.match(r.stdout, /renderer differs between workers of /);
});

test('two runs of the same build compare clean three times', async () => {
  const root = copyRoot();
  knownBuild(root);
  await acceptBaselines(root);
  for (let i = 0; i < 3; i += 1) {
    const r = await run(['visual', 'compare', '--root', root]);
    assert.equal(r.status, 0, r.out);
    assert.match(r.stdout, /^visual: clean — same 3 · differs 0 · missing 0 · orphan 0 · error 0 · not comparable 0$/m);
  }
});

// ---------------------------------------------------------------------------------------------
// Update, offer and accept

test('update offers only stable targets and records three comparisons', async () => {
  const root = copyRoot();
  knownBuild(root);
  useVisual(root, 'unstable:route:cart');
  const u = await run(['visual', 'update', '--root', root]);
  assert.equal(u.status, 3, u.out);
  assert.match(u.stdout, /^visual offer: new desktop-chrome\/routes--home\.png candidate \.agents\/regression\/runs\/.+\/visual\/capture\/candidates\/desktop-chrome\/routes--home\.png$/m);
  assert.match(u.stdout, /^visual offer: new mobile-safari\/routes--home\.png /m);
  assert.match(u.stdout, /^visual offer: unstable desktop-chrome\/routes--cart\.png/m);
  const rec = recordOf(root, u);
  const st = rec.visual.stability.find((s) => s.key === 'desktop-chrome/routes--home.png');
  assert.equal(st.renders, 3);
  assert.equal(st.differences, 0);
  assert.deepEqual(st.outcomes, ['same', 'same', 'same']);
  assert.equal(rec.visual.stability.find((s) => s.key === 'desktop-chrome/routes--cart.png').differences, 1);
  assert.deepEqual(callsOf(root).filter((l) => l.startsWith('visual')).map((l) => l.split(' ')[1]), ['capture', 'stability']);
  const a = await run(['visual', 'accept', '--run', rec.run_id, '--token', acceptTokenOf(u), '--root', root]);
  assert.equal(a.status, 0, a.out);
  assert.match(a.stdout, /^accepted: 2 written, 0 removed — commit with \/commit$/m);
  const index = JSON.parse(fs.readFileSync(path.join(root, BASE, 'test/index.json'), 'utf8'));
  assert.deepEqual(Object.keys(index.images).sort(), ['desktop-chrome/routes--home.png', 'mobile-safari/routes--home.png']);
  const img = index.images['desktop-chrome/routes--home.png'];
  assert.deepEqual(img.stability, { renders: 3, differences: 0, build_before: 'abc1234', build_after: 'abc1234' });
  assert.equal(img.build_sha, 'abc1234');
  assert.equal(img.run_id, rec.run_id);
  assert.equal(img.sha256, sha(fs.readFileSync(path.join(root, BASE, 'test/desktop-chrome/routes--home.png'))));
});

test('update makes no offer when the build changed or is unknown', async () => {
  const root = copyRoot();
  knownBuild(root);
  shaQueue = ['abc1234', 'def5678'];
  let r = await run(['visual', 'update', '--root', root]);
  assert.notEqual(r.status, 3, r.out);
  assert.match(r.stdout, /^visual offer: none — build changed during the run/m);
  const root2 = copyRoot();
  r = await run(['visual', 'update', '--root', root2]);
  assert.notEqual(r.status, 3, r.out);
  assert.match(r.stdout, /^visual offer: none — deployed build unknown/m);
  assert.equal(fs.existsSync(path.join(root2, BASE)), false);
});

test('a missing stability attestation withholds the offer', async () => {
  const root = copyRoot();
  knownBuild(root);
  useVisual(root, 'no-attest:route:home#0@stability');
  const u = await run(['visual', 'update', '--root', root]);
  assert.equal(u.status, 3, u.out);
  assert.match(u.stdout, /^visual offer: unstable desktop-chrome\/routes--home\.png.*guard not attested for route:home\/desktop-chrome\/stability#0/m);
  assert.match(u.stdout, /^visual offer: new desktop-chrome\/routes--cart\.png/m);
});

test('a candidate changed after the stability pass is never offered', async () => {
  const root = copyRoot();
  knownBuild(root);
  useVisual(root, 'mutate-candidate:route:cart@stability');
  const u = await run(['visual', 'update', '--root', root]);
  assert.equal(u.status, 3, u.out);
  assert.match(u.stdout, /^visual offer: unstable desktop-chrome\/routes--cart\.png.*candidate changed after capture/m);
});

test('a capture without attestation or with a teardown failure is never offered', async () => {
  const root = copyRoot();
  knownBuild(root);
  useVisual(root, 'no-attest:route:cart@capture,fail-report:route:home@capture');
  const u = await run(['visual', 'update', '--root', root]);
  assert.match(u.stdout, /^visual offer: unstable desktop-chrome\/routes--cart\.png/m);
  assert.match(u.stdout, /^visual offer: unstable desktop-chrome\/routes--home\.png/m);
  assert.match(u.stdout, /^visual offer: unstable mobile-safari\/routes--home\.png/m);
  assert.equal(acceptTokenOf(u), undefined, 'nothing stable, nothing to accept');
});

test('a pass without a report or with split renderers is never offered', async () => {
  for (const scenario of ['no-report@capture', 'no-report@stability', 'split-renderer@stability']) {
    const root = copyRoot();
    knownBuild(root);
    useVisual(root, scenario);
    const u = await run(['visual', 'update', '--root', root]);
    // The fake runner splits the renderer of the first project only; a missing report hits every case.
    assert.doesNotMatch(u.stdout, /^visual offer: new desktop-chrome\//m, `${scenario}: ${u.out}`);
    assert.match(u.stdout, /^visual offer: unstable desktop-chrome\/routes--home\.png — .*(the report does not show the test passed|renderer differs between workers)/m, scenario);
    if (scenario.startsWith('no-report')) assert.equal(acceptTokenOf(u), undefined, `${scenario}: ${u.out}`);
    else assert.match(u.stdout, /^visual offer: new mobile-safari\/routes--home\.png /m, scenario);
  }
});

test('a renderer change with the same pixels rewrites the index and compare is comparable again', async () => {
  const root = copyRoot();
  knownBuild(root);
  await acceptBaselines(root);
  useVisual(root, 'renderer:browser_version');
  let r = await run(['visual', 'compare', '--root', root]);
  assert.equal(recordOf(root, r).visual.counts.not_comparable, 3, r.out);
  const before = fs.readFileSync(path.join(root, BASE, 'test/desktop-chrome/routes--home.png'));
  const { update } = await acceptBaselines(root);
  assert.match(update.stdout, /^visual offer: changed desktop-chrome\/routes--home\.png .*— same pixels, renderer changed$/m);
  assert.deepEqual(fs.readFileSync(path.join(root, BASE, 'test/desktop-chrome/routes--home.png')), before);
  r = await run(['visual', 'compare', '--root', root]);
  assert.equal(r.status, 0, r.out);
  assert.match(r.stdout, /^visual: clean — same 3 · differs 0 · missing 0 · orphan 0 · error 0 · not comparable 0$/m);
});

test('a stray non-png file in the baselines blocks the offer with its cause', async () => {
  const root = copyRoot();
  knownBuild(root);
  await acceptBaselines(root);
  fs.writeFileSync(path.join(root, BASE, 'test/.DS_Store'), 'finder');
  const u = await run(['visual', 'update', '--root', root]);
  assert.notEqual(u.status, 3, u.out);
  assert.match(u.stdout, /^visual offer: none — baselines integrity \(file not part of the baselines: e2e\/visual-baselines\/test\/\.DS_Store\)$/m);
});

test('a functional outputDir from runnerOptions is resolved statically', async () => {
  const { assertDisjoint } = await lib('visual');
  const root = copyRoot();
  const config = path.join(root, 'e2e/playwright.config.ts');
  const text = fs.readFileSync(config, 'utf8');
  for (const value of ['runnerOptions(loadRunManifest()).outputDir', 'opts.outputDir']) {
    fs.writeFileSync(config, text.replace("testDir: './regression',", `testDir: './regression',\n  outputDir: ${value},`));
    assert.equal(assertDisjoint(root, readConfig(root), RUNS), null, value);
  }
  fs.writeFileSync(config, text.replace("testDir: './regression',", "testDir: './regression',\n  outputDir: path.join(x),"));
  assert.match(assertDisjoint(root, readConfig(root), RUNS), /cannot resolve the functional outputDir .* — set it to a string literal or runnerOptions\(…\)\.outputDir/);
});

test('an interrupted report stops the next pass', async () => {
  const root = copyRoot();
  knownBuild(root);
  useVisual(root, 'interrupted@capture');
  const u = await run(['visual', 'update', '--root', root]);
  assert.notEqual(u.status, 3, u.out);
  assert.deepEqual(callsOf(root).map((l) => l.split(' ').slice(0, 2).join(' ')), ['visual capture']);
  assert.match(u.stdout, /^visual offer: none — /m);
});

test('an interrupted pass launches no further runner', async () => {
  const root = copyRoot();
  knownBuild(root);
  useFunctional(root, 'interrupted');
  const r = await run(['run', 'full', '--root', root]);
  assert.equal(r.status, 4, r.out);
  assert.deepEqual(callsOf(root).map((l) => l.split(' ')[0]), ['functional']);
  assert.equal(recordOf(root, r).visual, null);
});

test('inherited reporter output variables are dropped from the runner environment', async () => {
  const root = copyRoot();
  knownBuild(root);
  useFunctional(root, 'dump-env');
  useVisual(root, 'dump-env');
  const r = await run(['run', 'full', '--root', root], { env: { PLAYWRIGHT_JSON_OUTPUT_FILE: '/tmp/x.json', PLAYWRIGHT_JSON_OUTPUT_DIR: '/tmp', PLAYWRIGHT_JSON_OUTPUT_NAME: 'x.json' } });
  assert.ok([0, 1, 4].includes(r.status), r.out);
  assert.deepEqual(fs.readFileSync(path.join(root, 'runner-env.log'), 'utf8').trim().split('\n'), ['none', 'none']);
});

test('accept writes baselines only with the token update issued', async () => {
  const root = copyRoot();
  knownBuild(root);
  let r = await run(['visual', 'compare', '--root', root]);
  assert.equal(fs.existsSync(path.join(root, BASE)), false, 'compare never writes baselines');
  r = await run(['run', 'full', '--root', root]);
  assert.equal(fs.existsSync(path.join(root, BASE)), false, 'run never writes baselines');
  const u = await run(['visual', 'update', '--root', root]);
  assert.equal(u.status, 3, u.out);
  const runId = runIdOf(root, u);
  assert.equal(fs.existsSync(path.join(root, BASE)), false, 'update never writes baselines');
  r = await run(['visual', 'accept', '--run', runId, '--token', '0'.repeat(32), '--root', root]);
  assert.equal(r.status, 3, r.out);
  assert.match(r.stderr, /token does not match/);
  assert.equal(fs.existsSync(path.join(root, BASE)), false);
  r = await run(['visual', 'accept', '--run', runId, '--token', acceptTokenOf(u), '--root', root]);
  assert.equal(r.status, 0, r.out);
  assert.equal(tree(path.join(root, BASE, 'test')).length, 4);
  r = await run(['visual', 'accept', '--run', runId, '--token', acceptTokenOf(u), '--root', root]);
  assert.equal(r.status, 3, 'the token is single use');
  assert.match(r.stderr, /no pending acceptance/);
  r = await run(['visual', 'accept', '--run', 'test-nope', '--token', acceptTokenOf(u), '--root', root]);
  assert.equal(r.status, 3);
  assert.match(r.stderr, /no offer/);
});

test('accept refuses a tree changed since the offer', async () => {
  const root = copyRoot();
  knownBuild(root);
  const u = await run(['visual', 'update', '--root', root]);
  assert.equal(u.status, 3, u.out);
  fs.mkdirSync(path.join(root, BASE, 'test'), { recursive: true });
  fs.writeFileSync(path.join(root, BASE, 'test/hand.png'), PNG_SIG);
  const r = await run(['visual', 'accept', '--run', runIdOf(root, u), '--token', acceptTokenOf(u), '--root', root]);
  assert.equal(r.status, 3, r.out);
  assert.match(r.stderr, /the candidates or the baselines changed since the offer/);
  assert.deepEqual(tree(path.join(root, BASE, 'test')), ['hand.png']);
});

test('first acceptance creates the baselines root from an absent directory', async () => {
  const root = copyRoot();
  knownBuild(root);
  assert.equal(fs.existsSync(path.join(root, 'e2e/visual-baselines')), false);
  await acceptBaselines(root);
  assert.deepEqual(tree(path.join(root, BASE)), ['test/desktop-chrome/routes--cart.png', 'test/desktop-chrome/routes--home.png', 'test/index.json', 'test/mobile-safari/routes--home.png']);
  assert.deepEqual(fs.readdirSync(path.join(root, BASE)), ['test'], 'no staging or previous left');
});

test('a candidate changed after verification leaves the accepted tree unchanged', async () => {
  const v = await lib('visual');
  const root = copyRoot();
  knownBuild(root);
  await acceptBaselines(root);
  useVisual(root, 'differs:route:home');
  const u = await run(['visual', 'update', '--root', root]);
  assert.equal(u.status, 3, u.out);
  const before = tree(path.join(root, BASE, 'test')).map((f) => [f, sha(fs.readFileSync(path.join(root, BASE, 'test', f)))]);
  const settings = (await lib('config')).visualSettings(readConfig(root));
  const runId = runIdOf(root, u);
  const candidate = path.join(root, RUNS, runId, 'visual/capture/candidates/desktop-chrome/routes--home.png');
  const r = v.acceptOffer({ root, settings, runId, token: acceptTokenOf(u), runsDir: path.join(root, RUNS), afterVerify: () => fs.appendFileSync(candidate, 'late') });
  assert.equal(r.exit, 3);
  assert.match(r.message, /stale offer — the candidates or the baselines changed during accept/);
  const afterTree = tree(path.join(root, BASE, 'test')).map((f) => [f, sha(fs.readFileSync(path.join(root, BASE, 'test', f)))]);
  assert.deepEqual(afterTree, before);
  assert.deepEqual(fs.readdirSync(path.join(root, BASE)), ['test'], 'staging removed');
});

test('an interrupted accept swap is an integrity reason', async () => {
  const root = copyRoot();
  knownBuild(root);
  await acceptBaselines(root);
  fs.mkdirSync(path.join(root, BASE, '.test.staging-run1'));
  let r = await run(['visual', 'compare', '--root', root]);
  assert.equal(r.status, 4, r.out);
  assert.match(r.stdout, /^reason: interrupted accept: remove \.test\.staging-run1; the accepted tree is intact$/m);
  r = await run(['visual', 'update', '--root', root]);
  assert.match(r.stdout, /^visual offer: none — baselines integrity/m);
  fs.rmSync(path.join(root, BASE, '.test.staging-run1'), { recursive: true });
  fs.cpSync(path.join(root, BASE, 'test'), path.join(root, BASE, '.test.previous-run2'), { recursive: true });
  r = await run(['visual', 'compare', '--root', root]);
  assert.match(r.stdout, /^reason: interrupted accept: remove \.test\.previous-run2$/m);
});

test('an interruption after the first rename is reported with its recovery', async () => {
  const root = copyRoot();
  knownBuild(root);
  await acceptBaselines(root);
  fs.renameSync(path.join(root, BASE, 'test'), path.join(root, BASE, '.test.previous-run3'));
  const r = await run(['visual', 'compare', '--root', root]);
  assert.equal(r.status, 4, r.out);
  assert.match(r.stdout, /^reason: interrupted accept: restore: rename \.test\.previous-run3 back to test, then rerun visual update$/m);
});

test('an interrupted first acceptance names its recovery', async () => {
  const root = copyRoot();
  knownBuild(root);
  fs.mkdirSync(path.join(root, BASE, '.test.staging-run4'), { recursive: true });
  const r = await run(['visual', 'compare', '--root', root]);
  assert.equal(r.status, 4, r.out);
  assert.match(r.stdout, /^reason: interrupted accept: remove \.test\.staging-run4, then run visual update again$/m);
});

test('an unindexed png blocks the offer and is never removed', async () => {
  const root = copyRoot();
  knownBuild(root);
  await acceptBaselines(root);
  const stray = path.join(root, BASE, 'test/desktop-chrome/routes--old.png');
  fs.writeFileSync(stray, PNG_SIG);
  const u = await run(['visual', 'update', '--root', root]);
  assert.notEqual(u.status, 3, u.out);
  assert.match(u.stdout, /^visual offer: none — baselines integrity/m);
  assert.ok(fs.existsSync(stray));
});

test('a route device without a runner project is not run and keeps its baseline', async () => {
  const root = copyRoot();
  knownBuild(root);
  await acceptBaselines(root);
  editConfig(root, (cfg) => { delete cfg.runner.devices.mobile; });
  let r = await run(['visual', 'compare', '--root', root]);
  const b = recordOf(root, r).visual;
  assert.deepEqual(b.orphans, []);
  assert.deepEqual(b.no_device, [{ id: 'route:home', device: 'mobile' }]);
  assert.match(r.stdout, /^not run — no device: route:home \(mobile\)$/m);
  useVisual(root, 'differs:route:home');
  r = await run(['visual', 'update', '--root', root]);
  assert.equal(r.status, 3, r.out);
  assert.doesNotMatch(r.stdout, /visual offer: remove/);
  const a = await run(['visual', 'accept', '--run', runIdOf(root, r), '--token', acceptTokenOf(r), '--root', root]);
  assert.equal(a.status, 0, a.out);
  assert.ok(fs.existsSync(path.join(root, BASE, 'test/mobile-safari/routes--home.png')));
});

test('update removes an orphan baseline only through accept', async () => {
  const root = copyRoot();
  knownBuild(root);
  await acceptBaselines(root);
  editConfig(root, (cfg) => { cfg.visual.routes = [cfg.visual.routes[0]]; });
  const u = await run(['visual', 'update', '--root', root]);
  assert.equal(u.status, 3, u.out);
  assert.match(u.stdout, /^visual offer: remove desktop-chrome\/routes--cart\.png baseline e2e\/visual-baselines\/test\/desktop-chrome\/routes--cart\.png$/m);
  assert.match(u.stdout, /^visual offer: unchanged desktop-chrome\/routes--home\.png/m);
  assert.ok(fs.existsSync(path.join(root, BASE, 'test/desktop-chrome/routes--cart.png')));
  const a = await run(['visual', 'accept', '--run', runIdOf(root, u), '--token', acceptTokenOf(u), '--root', root]);
  assert.match(a.stdout, /^accepted: 0 written, 1 removed/m);
  assert.equal(fs.existsSync(path.join(root, BASE, 'test/desktop-chrome/routes--cart.png')), false);
});

// ---------------------------------------------------------------------------------------------
// run full, status, setup, team clone, templates

test('run full includes the visual block and smoke never does', async () => {
  const root = copyRoot();
  knownBuild(root);
  await acceptBaselines(root);
  const before = callsOf(root).length;
  let r = await run(['run', 'full', '--root', root]);
  const full = recordOf(root, r);
  assert.equal(full.mode, 'full');
  assert.equal(full.visual.outcome, 'clean', r.out);
  assert.equal(full.verdict, 'GREEN', r.out);
  assert.deepEqual(callsOf(root).slice(before).map((l) => l.split(' ').slice(0, 2).join(' ')), ['functional same', 'visual compare']);
  assert.match(r.stdout, /^visual: clean — /m);
  assert.match(r.stdout, /^visual portability: /m);
  r = await run(['run', 'smoke', '--root', root]);
  assert.equal(recordOf(root, r).visual, null);
  assert.equal(callsOf(root).slice(before).filter((l) => l.startsWith('visual')).length, 1);
});

test('status keeps the newest record per environment and mode', async () => {
  const root = copyRoot();
  knownBuild(root);
  const env = (t) => ({ env: { REGRESSION_NOW: t } });
  useFunctional(root, 'same,exit:1');
  await run(['run', 'full', '--root', root], env('2026-11-26T10:00:00.000Z'));
  useFunctional(root, 'same');
  await run(['visual', 'compare', '--root', root], env('2026-11-26T11:00:00.000Z'));
  await run(['run', 'smoke', '--root', root], env('2026-11-26T12:00:00.000Z'));
  const r = await run(['status', '--root', root]);
  const lines = r.stdout.trim().split('\n');
  assert.ok(lines.some((l) => /^test full \S+ /.test(l)), r.stdout);
  assert.ok(lines.some((l) => /^test visual \S+ /.test(l)), r.stdout);
  assert.ok(lines.some((l) => /^test smoke GREEN /.test(l)), r.stdout);
  assert.ok(lines.includes('prod no run recorded on this machine'), r.stdout);
  const j = JSON.parse((await run(['status', '--json', '--root', root])).stdout);
  assert.deepEqual(j.runs.filter((x) => x.env === 'test').map((x) => x.mode).sort(), ['full', 'smoke', 'visual']);
});

test('setup visual adds an absent section and check lists visual gaps', async () => {
  const { checkFoundation } = await lib('setup');
  const root = copyRoot();
  const cfg = editConfig(root, (c) => { delete c.visual; });
  const frag = path.join(root, 'fragment.json');
  fs.writeFileSync(frag, `${JSON.stringify({ visual: { ...readConfig(copyRoot()).visual } })}\n`);
  let r = await cli(SETUP, ['visual', '--fragment', 'fragment.json', '--root', root]);
  assert.equal(r.status, 0, r.out);
  assert.match(r.stdout, /^added visual$/m);
  r = await cli(SETUP, ['visual', '--fragment', 'fragment.json', '--root', root]);
  assert.match(r.stdout, /^kept visual \(fragment section ignored\)$/m);
  const gaps = checkFoundation(root);
  assert.ok(gaps.includes('visual.baselines: e2e/visual-baselines not found — created by the first visual accept'), gaps.join('\n'));
  fs.rmSync(path.join(root, 'e2e/visual/visual.spec.ts'));
  assert.ok(checkFoundation(root).includes('visual.spec: e2e/visual/visual.spec.ts not found'));
  const bare = copyRoot();
  editConfig(bare, (c) => { delete c.visual; delete c.runner; delete c.environments; delete c.default_env; });
  fs.writeFileSync(path.join(bare, 'fragment.json'), `${JSON.stringify({ visual: cfg.visual ?? {} })}\n`);
  r = await cli(SETUP, ['visual', '--fragment', 'fragment.json', '--root', bare]);
  assert.equal(r.status, 1);
  assert.match(r.stdout, /baseline not established — run the baseline stage first/);
});

test('team clone refuses every visual command', async () => {
  const root = copyRoot();
  knownBuild(root);
  fs.mkdirSync(path.join(root, '.agents/team'), { recursive: true });
  fs.writeFileSync(path.join(root, '.agents/team/session.json'), '{}\n');
  for (const args of [['visual', 'compare'], ['visual', 'update'], ['visual', 'accept', '--run', 'x', '--token', 'y']]) {
    const r = await run([...args, '--root', root]);
    assert.equal(r.status, 3, `${args.join(' ')}: ${r.out}`);
    assert.match(r.stderr, /team clone/);
  }
  assert.equal(callsOf(root).length, 0);
});

test('visual not configured is a usage refusal', async () => {
  const root = copyRoot();
  editConfig(root, (c) => { delete c.visual; });
  const r = await run(['visual', 'compare', '--root', root]);
  assert.equal(r.status, 2);
  assert.match(r.stderr, /visual not configured — see \.claude\/skills\/regression\/references\/visual\.md/);
});

test('visual templates declare tests in the spec and import the guarded fixtures', async () => {
  const { scanIntegration } = await lib('run');
  const config = fs.readFileSync(path.join(REPO, '.claude/templates/regression/visual.config.ts.template'), 'utf8');
  const spec = fs.readFileSync(path.join(REPO, '.claude/templates/regression/visual.spec.ts.template'), 'utf8');
  assert.match(spec, /^import \{ test, expect \} from '<fixtures-relative>';$/m);
  assert.match(spec, /for \(const t of visualTargets\(manifest\)\) \{\n {2}test\(/);
  assert.match(spec, /renderTarget\(\{ page, browser \}, testInfo, t, expect, manifest\)/);
  assert.doesNotMatch(spec.split('\n').filter((l) => !l.startsWith('//')).join('\n'), /@playwright\/test/);
  assert.match(config, /import \{ visualOptions \} from '<visual-spec-module-relative>';/);
  assert.match(config, /import \{ loadRunManifest, runnerOptions \} from '<guard-module-relative>';/);
  assert.match(config, /testMatch: v\.testMatch/);
  assert.doesNotMatch(config.split('\n').filter((l) => !l.startsWith('//')).join('\n'), /webServer|extraHTTPHeaders|httpCredentials/);
  const functional = fs.readFileSync(path.join(REPO, '.claude/templates/regression/playwright.config.ts.template'), 'utf8');
  assert.match(functional, /outputDir: opts\.outputDir/);
  const root = copyRoot();
  const findings = scanIntegration(root, {
    configFile: 'e2e/visual/visual.config.ts',
    configNeeds: [{ module: /\.claude\/lib\/regression\/guard\.mjs$/, binding: 'runnerOptions' }, { module: /\.claude\/lib\/regression\/visual-spec\.mjs$/, binding: 'visualOptions' }],
    specs: ['e2e/visual/visual.spec.ts'],
  });
  assert.deepEqual(findings, [], 'the fixture copies of the templates are guard-integrated');
});
