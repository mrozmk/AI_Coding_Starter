// Unit tests of the regression environment policy, selection and deterministic run:
// config.mjs (envPolicy, default_env, loopback, resolveTarget), catalog.mjs (Needs), policy.mjs
// (selection, budget, confirmation) and run.mjs (refusals, locks, token, pre-flight, report
// mapping, verdicts, record) against stub Playwright JSON reports and a fake runner. Temp copies
// of the fixture root only (--root); REGRESSION_LOCK_DIR in a temp dir — never the real ~.
import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import http from 'node:http';
import { createHash } from 'node:crypto';
import { spawn, spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

import { validateConfig, envPolicy, isLoopbackHost, resolveTarget, resolveEnvBaseUrl, loadConfig, catalogSettings } from '../regression/config.mjs';
import { catalogFiles, parseCatalog, validateCatalog, needsKeys } from '../regression/catalog.mjs';
import { buildPlan, confirmationText, worstCaseBackendCalls } from '../regression/policy.mjs';
import { runnerOptions } from '../regression/guard.mjs';
import { parseBuildSha, isTeamClone } from '../regression/run.mjs';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const REPO = path.join(HERE, '../../..');
const RUN = path.join(HERE, '../regression/run.mjs');
const FIX = path.join(HERE, 'fixtures/regression/run');
const FAKE = path.join(FIX, 'fake-runner.mjs');
const CAT = '.agents/regression/scenarios';
const h16 = (s) => createHash('sha256').update(s).digest('hex').slice(0, 16);

// ---------------------------------------------------------------------------------------------
// Helpers

function copyRoot() {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'regression-run-'));
  fs.cpSync(path.join(FIX, 'root'), root, { recursive: true });
  return root;
}

const readConfig = (root) => JSON.parse(fs.readFileSync(path.join(root, '.claude/regression.json'), 'utf8'));
function editConfig(root, fn) {
  const cfg = readConfig(root);
  fn(cfg);
  fs.writeFileSync(path.join(root, '.claude/regression.json'), `${JSON.stringify(cfg, null, 2)}\n`);
  return cfg;
}

/** Point a mode's command at the fake runner: `<report> <events> <exit>`. */
function useRunner(root, args, mode = 'smoke') {
  editConfig(root, (cfg) => { cfg.runner.commands[mode] = `"${process.execPath}" "${FAKE}" ${args}`; });
}

function mkRoot(files) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'regression-run-'));
  for (const [rel, text] of Object.entries(files)) {
    fs.mkdirSync(path.dirname(path.join(root, rel)), { recursive: true });
    fs.writeFileSync(path.join(root, rel), typeof text === 'string' ? text : `${JSON.stringify(text, null, 2)}\n`);
  }
  return root;
}

/** run.mjs, asynchronously (the build-SHA stub answers from this process). */
function cli(args, { env = {}, locks } = {}) {
  return new Promise((resolve) => {
    const child = spawn(process.execPath, [RUN, ...args], {
      env: { ...process.env, REGRESSION_LOCK_DIR: locks ?? fs.mkdtempSync(path.join(os.tmpdir(), 'regression-locks-')), ...env },
    });
    let stdout = '';
    let stderr = '';
    child.stdout.on('data', (d) => { stdout += d; });
    child.stderr.on('data', (d) => { stderr += d; });
    child.on('close', (status) => resolve({ status, stdout, stderr, out: stdout + stderr }));
  });
}

const recordOf = (root, r) => {
  const m = /^record: (.+)$/m.exec(r.stdout);
  assert.ok(m, `no record line in:\n${r.out}`);
  return JSON.parse(fs.readFileSync(path.join(root, m[1]), 'utf8'));
};
const runnerCalls = (root) => (fs.existsSync(path.join(root, 'runner-calls.log')) ? fs.readFileSync(path.join(root, 'runner-calls.log'), 'utf8').split('\n').filter(Boolean).length : 0);
const tokenOf = (r) => /^confirmation-required: ([0-9a-f]{32})$/m.exec(r.stdout)?.[1];

// A build-SHA endpoint: answers the queued SHAs in order (the last one repeats).
let shaServer;
let shaQueue = [];
let SHA_URL = '';
before(async () => {
  shaServer = http.createServer((req, res) => {
    const sha = shaQueue.length > 1 ? shaQueue.shift() : shaQueue[0];
    res.writeHead(200, { 'content-type': 'application/json' });
    res.end(JSON.stringify({ sha }));
  });
  await new Promise((r) => shaServer.listen(0, '127.0.0.1', r));
  SHA_URL = `http://127.0.0.1:${shaServer.address().port}/version`;
});
after(() => shaServer.close());

/** A test-environment root whose build SHA is known and stable. */
function knownBuild(root, env = 'test') {
  shaQueue = ['abc1234'];
  editConfig(root, (cfg) => { cfg.environments[env].build_sha_url = SHA_URL; });
}

/** Phase 1 (token) and phase 2 (--confirm) of a production run. */
async function prodRun(root, { locks, env = {} } = {}) {
  const lockDir = locks ?? fs.mkdtempSync(path.join(os.tmpdir(), 'regression-locks-'));
  const first = await cli(['run', '--env', 'prod', '--root', root], { locks: lockDir, env });
  assert.equal(first.status, 3, first.out);
  return cli(['run', '--env', 'prod', '--confirm', tokenOf(first), '--root', root], { locks: lockDir, env });
}

// ---------------------------------------------------------------------------------------------
// Config: environment policy and target

test('environment defaults to production refuse one worker', () => {
  const p = envPolicy({ host: 'https://shop.example.com' });
  assert.equal(p.kind, 'production');
  assert.equal(p.writes, 'refuse');
  assert.equal(p.workers, 1);
  assert.deepEqual(p.means, []);
  assert.deepEqual(p.guard.stop.statuses, [403, 429]);
  assert.equal(p.consent.strategy, 'decline');
  assert.deepEqual(p.pacing, { action_delay_ms: 0, requests_per_minute: 0 });
  assert.deepEqual(validateConfig({ version: 1, catalog: {}, environments: { prod: { host: 'https://shop.example.com' } } }), []);
  const errors = validateConfig({ version: 1, catalog: {}, environments: { prod: { host: 'https://shop.example.com', writes: 'sometimes', workers: 0 } } });
  assert.ok(errors.some((e) => /^environments\.prod\.writes:/.test(e)));
  assert.ok(errors.some((e) => /^environments\.prod\.workers:/.test(e)));
});

test('production default_env is a config error', () => {
  const envs = { test: { host: 'https://test.shop.example.com', kind: 'test' }, prod: { host: 'https://shop.example.com' } };
  const errors = validateConfig({ version: 1, catalog: {}, default_env: 'prod', environments: envs });
  assert.ok(errors.includes('default_env: prod is a production environment — only a kind: test environment may be the default'), errors.join('\n'));
  assert.ok(validateConfig({ version: 1, catalog: {}, default_env: 'nope', environments: envs }).some((e) => /^default_env: nope names no environment/.test(e)));
  assert.deepEqual(validateConfig({ version: 1, catalog: {}, default_env: 'test', environments: envs }), []);
  const root = copyRoot();
  editConfig(root, (cfg) => { cfg.default_env = 'prod'; });
  assert.match(loadConfig(root).errors.join('\n'), /only a kind: test environment may be the default/);
});

test('missing or unknown target is an error', async () => {
  const cfg = { environments: { test: { host: 'https://t.example.com', kind: 'test' }, prod: { host: 'https://shop.example.com' } } };
  assert.deepEqual(resolveTarget(cfg, 'nope'), { error: 'unknown environment nope', names: ['test', 'prod'] });
  const none = resolveTarget(cfg);
  assert.match(none.error, /several environments and no default_env/);
  assert.deepEqual(none.names, ['test', 'prod']);
  assert.deepEqual(resolveTarget({ ...cfg, default_env: 'test' }), { name: 'test' });
  const root = copyRoot();
  const r = await cli(['run', '--env', 'nope', '--root', root]);
  assert.equal(r.status, 2);
  assert.match(r.stdout, /^environments: test, prod$/m);
  editConfig(root, (c) => { delete c.default_env; });
  const r2 = await cli(['run', '--root', root]);
  assert.equal(r2.status, 2, r2.out);
  assert.equal(runnerCalls(root), 0);
});

test('loopback host is an error', () => {
  for (const host of ['http://localhost:3000', 'http://app.localhost', 'http://127.0.0.1:8080', 'http://127.5.0.1', 'http://[::1]:8080', 'http://0.0.0.0']) {
    const errors = validateConfig({ version: 1, catalog: {}, environments: { local: { host, kind: 'test' } } });
    assert.ok(errors.includes('environments.local.host: a local server is not a regression target'), `${host}: ${errors.join('; ')}`);
  }
  assert.equal(isLoopbackHost('shop.local'), false, 'a .local host is a deployed environment');
  assert.equal(isLoopbackHost('10.0.0.5'), false);
  const cfg = { version: 1, catalog: {}, environments: { test: { host: 'qa-env', kind: 'test' } } };
  const root = mkRoot({ '.claude/regression.json': cfg, '.claude/qa-env.json': { base_url: 'http://127.0.0.1:3000' } });
  assert.match(resolveEnvBaseUrl(root, cfg, 'test').error ?? '', /a local server is not a regression target/);
});

test('sole production environment is never picked by default', () => {
  const prodOnly = { environments: { prod: { host: 'https://shop.example.com' } } };
  const r = resolveTarget(prodOnly);
  assert.match(r.error, /the only environment prod is production/);
  assert.deepEqual(r.names, ['prod']);
  assert.deepEqual(resolveTarget({ environments: { test: { host: 'https://t.example.com', kind: 'test' } } }), { name: 'test' });
  assert.deepEqual(resolveTarget(prodOnly, 'prod'), { name: 'prod' }, 'named explicitly, production is reachable');
});

test('needs field validates and old catalogs stay valid', () => {
  const head = '- **Priority:** P0 · **Viewport:** desktop · **Status:** READY · **Effect:** read';
  const block = (needs) => [
    '# Area', '', '### CART-001 — Open the cart', head, ...(needs ? [`- **Needs:** ${needs}`] : []),
    '- **Goal:** Open it.', '- **Steps:**', '  1. Open.', '- **Expected:** Shown.', '- **Source:** live · **Spec:** —', '',
  ].join('\n');
  const errorsOf = (text) => {
    const root = mkRoot({ '.claude/regression.json': { version: 1, catalog: { areas: { CART: 'Cart' } } }, [`${CAT}/cart.md`]: text });
    const settings = catalogSettings(loadConfig(root).config);
    return validateCatalog(parseCatalog(root, catalogFiles(root, settings)), settings).map((e) => `${e.file}:${e.line}: ${e.message}`);
  };
  assert.deepEqual(errorsOf(block(null)), [], 'a catalog without Needs stays valid');
  assert.deepEqual(errorsOf(block('account:shopper · price-call')), []);
  const bad = errorsOf(block('Account:Shopper · price-call · price-call'));
  assert.ok(bad.includes(`${CAT}/cart.md:5: malformed Needs key Account:Shopper — expected ^[a-z0-9][a-z0-9:_-]*$`), bad.join('\n'));
  assert.ok(bad.includes(`${CAT}/cart.md:5: duplicate Needs key price-call`), bad.join('\n'));
  assert.deepEqual(needsKeys('—'), []);
  assert.deepEqual(needsKeys('a · b:c'), ['a', 'b:c']);
});

// ---------------------------------------------------------------------------------------------
// Selection and budget

test('declared write runs only with every need declared', () => {
  const root = copyRoot();
  const plan = buildPlan(root, readConfig(root), 'prod', 'full');
  const ids = new Set(plan.cases.map((c) => c.id));
  assert.ok(ids.has('CART-002'), 'write needing a declared means runs under declared');
  const reason = (id) => plan.excluded.find((e) => e.id === id)?.reason;
  assert.equal(reason('CART-003'), 'no safe means named');
  assert.equal(reason('CART-004'), 'payment:sandbox not declared for prod');
  editConfig(root, (cfg) => { cfg.environments.prod.writes = 'refuse'; });
  assert.equal(buildPlan(root, readConfig(root), 'prod', 'full').excluded.find((e) => e.id === 'CART-002')?.reason, 'writes refuse');
});

test('costed operation without backend bound is not selected on production', () => {
  const root = copyRoot();
  const prod = buildPlan(root, readConfig(root), 'prod', 'full');
  assert.equal(prod.excluded.find((e) => e.id === 'PDP-002')?.reason, 'price-unbounded has no declared backend upper bound');
  assert.ok(!prod.cases.some((c) => c.id === 'PDP-002'));
  assert.ok(prod.cases.some((c) => c.id === 'PDP-001'), 'a bounded costed operation runs');
  editConfig(root, (cfg) => { cfg.environments.test.guard = { operations: { 'price-unbounded': { method: 'GET', url: '/api/stock', cost: 1 } } }; });
  assert.ok(buildPlan(root, readConfig(root), 'test', 'full').cases.some((c) => c.id === 'PDP-002'), 'on a test environment it runs and is budgeted');
});

test('worst case backend calls holds for mixed operations', () => {
  assert.ok(worstCaseBackendCalls(10, { a: { cost: 6, backend_calls: 6 }, b: { cost: 4, backend_calls: 4 } }) >= 10);
  // 10 units on the 1-cost/4-call op is the worst mix: 40 calls.
  assert.equal(worstCaseBackendCalls(10, { a: { cost: 1, backend_calls: 4 }, b: { cost: 2, backend_calls: 2 } }), 40);
  assert.equal(worstCaseBackendCalls(null, { a: { cost: 1, backend_calls: 4 } }), 0);
  const root = copyRoot();
  const plan = buildPlan(root, readConfig(root), 'prod', 'smoke');
  assert.equal(plan.budget.worst_case_backend_calls, 200);
  assert.match(confirmationText(plan), /^worst case backend calls: 200$/m);
});

test('policy excluded scenarios are listed and not counted', async () => {
  const root = copyRoot();
  knownBuild(root);
  useRunner(root, 'green attest-all 0');
  const r = await cli(['run', '--root', root]);
  assert.equal(r.status, 0, r.out);
  assert.match(r.stdout, /^not run — policy: PDP-001 — price-call not declared for test$/m);
  const rec = recordOf(root, r);
  assert.deepEqual(rec.not_run_policy, [{ id: 'PDP-001', reason: 'price-call not declared for test' }]);
  assert.ok(!rec.cases.some((c) => c.id === 'PDP-001'));
  assert.equal(rec.counts.not_run_policy, 1);
  assert.equal(rec.counts.passed, rec.cases.length);
});

// ---------------------------------------------------------------------------------------------
// Confirmation

test('production confirmation cannot be skipped', async () => {
  const root = copyRoot();
  useRunner(root, 'green-prod attest-all 0');
  const first = await cli(['run', '--env', 'prod', '--root', root]);
  assert.equal(first.status, 3);
  assert.match(first.stdout, /^confirmation-required: [0-9a-f]{32}$/m);
  assert.match(first.stdout, /^environment: prod \(production\) — https:\/\/shop\.example\.com$/m);
  const yes = await cli(['run', '--env', 'prod', '--yes', '--root', root]);
  assert.equal(yes.status, 2, 'an unknown flag is a usage error');
  editConfig(root, (cfg) => { cfg.confirm = false; cfg.environments.prod.confirm = false; cfg.environments.prod.consent = { strategy: 'accept' }; });
  const cfgSkip = await cli(['run', '--env', 'prod', '--root', root]);
  assert.equal(cfgSkip.status, 3, 'no config key skips the confirmation');
  assert.equal(runnerCalls(root), 0, 'nothing ran');
});

test('confirmation token is single use and bound to the plan', async () => {
  const root = copyRoot();
  useRunner(root, 'green-prod attest-all 0');
  const locks = fs.mkdtempSync(path.join(os.tmpdir(), 'regression-locks-'));
  const first = await cli(['run', '--env', 'prod', '--root', root], { locks });
  const token = tokenOf(first);
  const ok = await cli(['run', '--env', 'prod', '--confirm', token, '--root', root], { locks });
  assert.notEqual(ok.status, 3, ok.out);
  assert.equal(recordOf(root, ok).confirmed, true);
  const reuse = await cli(['run', '--env', 'prod', '--confirm', token, '--root', root], { locks });
  assert.equal(reuse.status, 3);
  assert.match(reuse.stderr, /confirmation invalid/);
  const fresh = tokenOf(reuse);
  assert.ok(fresh && fresh !== token, 'a fresh token is printed');
  fs.appendFileSync(path.join(root, CAT, 'cart.md'), '\n');
  const changed = await cli(['run', '--env', 'prod', '--confirm', fresh, '--root', root], { locks });
  assert.equal(changed.status, 3);
  assert.match(changed.stderr, /the plan changed/);
  assert.equal(runnerCalls(root), 1, 'only the confirmed run started the runner');
});

// ---------------------------------------------------------------------------------------------
// Verdicts

test('run green on a complete report', async () => {
  const root = copyRoot();
  knownBuild(root);
  useRunner(root, 'green attest-all 0');
  const r = await cli(['run', '--root', root]);
  assert.equal(r.status, 0, r.out);
  assert.match(r.stdout, /^verdict: GREEN$/m);
  assert.equal(recordOf(root, r).build_sha, 'abc1234');
});

const verdictCase = (name, report, { exit = 0, events = 'attest-all', status, verdict, reason }) => test(name, async () => {
  const root = copyRoot();
  knownBuild(root);
  useRunner(root, `${report} ${events} ${exit}`);
  const r = await cli(['run', '--root', root]);
  assert.equal(r.status, status, r.out);
  assert.match(r.stdout, new RegExp(`^verdict: ${verdict.replace('/', '\\/')}$`, 'm'));
  if (reason) assert.match(r.stdout, reason);
});

verdictCase('run red on a failed case', 'red', { exit: 1, status: 1, verdict: 'RED', reason: /^reason: failed: CART-001\/desktop-chrome$/m });
verdictCase('run red on a missing case', 'missing', { status: 1, verdict: 'RED', reason: /^reason: missing: PDP-003\/mobile-safari$/m });
verdictCase('run red on an orphan case', 'orphan', { status: 1, verdict: 'RED', reason: /^reason: no scenario id: Untitled smoke check/m });
verdictCase('run red on an empty report', 'empty', { status: 1, verdict: 'RED', reason: /^reason: zero executed cases$/m });
verdictCase('run red outside the selection', 'outside', { status: 1, verdict: 'RED', reason: /^reason: outside the selection: CART-006\/desktop-chrome/m });
verdictCase('run incomplete on a flaky case', 'flaky', { status: 4, verdict: 'INCOMPLETE', reason: /^reason: flaky: CART-001\/desktop-chrome$/m });

test('run incomplete on skipped duplicated or interrupted cases', async () => {
  for (const [report, word] of [['skipped', 'skipped'], ['duplicated', 'duplicated'], ['interrupted', 'interrupted']]) {
    const root = copyRoot();
    knownBuild(root);
    useRunner(root, `${report} attest-all 0`);
    const r = await cli(['run', '--root', root]);
    assert.equal(r.status, 4, `${report}: ${r.out}`);
    assert.match(r.stdout, new RegExp(`^reason: ${word}: CART-001/desktop-chrome$`, 'm'));
  }
});

test('run incomplete on report errors, an expected failure or a non-zero runner exit', async () => {
  for (const [args, reason] of [['errors attest-all 0', /^reason: report errors: 1$/m], ['expected-failure attest-all 0', /^reason: invalid: CART-001\/desktop-chrome$/m], ['green attest-all 1', /^reason: runner exit 1$/m]]) {
    const root = copyRoot();
    knownBuild(root);
    useRunner(root, args);
    const r = await cli(['run', '--root', root]);
    assert.equal(r.status, 4, `${args}: ${r.out}`);
    assert.match(r.stdout, reason);
  }
});

test('run incomplete without a build sha', async () => {
  const root = copyRoot();
  useRunner(root, 'green attest-all 0');
  const r = await cli(['run', '--root', root]);
  assert.equal(r.status, 4, r.out);
  assert.match(r.stdout, /^reason: deployed build unknown \(no build_sha_url\)$/m);
  assert.equal(recordOf(root, r).build_sha, null);
  assert.equal(parseBuildSha('{"commit": "abcdef1"}'), 'abcdef1');
  assert.equal(parseBuildSha('abcdef1234\n'), 'abcdef1234');
  assert.equal(parseBuildSha('{"sha": "abcdef1", "commit": "1234567"}'), null, 'two different SHAs are no SHA');
  assert.equal(parseBuildSha('<html>'), null);
});

test('run incomplete when the build changes during the run', async () => {
  const root = copyRoot();
  editConfig(root, (cfg) => { cfg.environments.test.build_sha_url = SHA_URL; });
  useRunner(root, 'green attest-all 0');
  shaQueue = ['aaaaaaa', 'bbbbbbb'];
  const r = await cli(['run', '--root', root]);
  assert.equal(r.status, 4, r.out);
  assert.match(r.stdout, /^reason: build changed during the run \(aaaaaaa → bbbbbbb\)$/m);
  const rec = recordOf(root, r);
  assert.equal(rec.build_sha, 'aaaaaaa');
  assert.equal(rec.build_sha_after, 'bbbbbbb');
});

test('a blocked request fails its case even when the report passed', async () => {
  const root = copyRoot();
  knownBuild(root);
  useRunner(root, 'green blocked-case 0');
  const r = await cli(['run', '--root', root]);
  assert.equal(r.status, 1, r.out);
  const rec = recordOf(root, r);
  assert.equal(rec.cases.find((c) => c.id === 'CART-001' && c.project === 'desktop-chrome').result, 'failed');
  assert.equal(rec.guard.blocked[0].url, 'https://foreign.example.net/x');
  const outside = copyRoot();
  knownBuild(outside);
  useRunner(outside, 'green blocked-outside 0');
  const r2 = await cli(['run', '--root', outside]);
  assert.equal(r2.status, 1, r2.out);
  assert.match(r2.stdout, /^reason: blocked request outside a test$/m);
});

test('a same-id case from another spec file is outside the selection', async () => {
  const root = copyRoot();
  knownBuild(root);
  useRunner(root, 'other-file attest-all 0');
  const r = await cli(['run', '--root', root]);
  assert.equal(r.status, 1, r.out);
  const rec = recordOf(root, r);
  assert.equal(rec.cases.find((c) => c.id === 'CART-001').result, 'missing');
  assert.deepEqual(rec.outside_selection, [{ id: 'CART-001', project: 'desktop-chrome', file: 'e2e/regression/pdp.spec.ts' }]);
  const other = copyRoot();
  knownBuild(other);
  useRunner(other, 'rootdir attest-all 0');
  const r2 = await cli(['run', '--root', other]);
  assert.equal(r2.status, 0, `a rootDir other than the testDir still maps the files: ${r2.out}`);
});

// ---------------------------------------------------------------------------------------------
// Refusals, locks, record

test('run refuses in a team clone', async () => {
  const root = copyRoot();
  useRunner(root, 'green attest-all 0');
  fs.mkdirSync(path.join(root, '.agents/team'), { recursive: true });
  fs.writeFileSync(path.join(root, '.agents/team/team.json'), '{}\n');
  assert.equal(isTeamClone(root), true);
  const r = await cli(['run', '--root', root]);
  assert.equal(r.status, 3);
  assert.match(r.stderr, /team clone/);
  assert.equal(runnerCalls(root), 0);
});

function holdLock(locks, name, owner) {
  const dir = path.join(locks, name);
  fs.mkdirSync(dir, { recursive: true });
  fs.writeFileSync(path.join(dir, 'owner.json'), JSON.stringify({ token: 'held', run_id: 'other-run', ...owner }));
  return dir;
}
const deadPid = () => spawnSync(process.execPath, ['--version']).pid;

test('run refuses while a lock is held', async () => {
  const root = copyRoot();
  knownBuild(root);
  useRunner(root, 'green attest-all 0');
  const locks = fs.mkdtempSync(path.join(os.tmpdir(), 'regression-locks-'));
  const envLock = holdLock(locks, `env-${h16('https://test.shop.example.com')}`, { pid: process.pid });
  const r = await cli(['run', '--root', root], { locks });
  assert.equal(r.status, 3);
  assert.match(r.stderr, new RegExp(`held by pid ${process.pid} \\(run other-run\\)`));
  fs.rmSync(envLock, { recursive: true });
  const coLock = holdLock(locks, `checkout-${h16(fs.realpathSync(root))}`, { pid: process.pid });
  editConfig(root, (cfg) => { cfg.environments.test.host = 'https://other-test.shop.example.com'; });
  const r2 = await cli(['run', '--root', root], { locks });
  assert.equal(r2.status, 3, 'one run per checkout, whatever the base URL');
  assert.equal(runnerCalls(root), 0);
  fs.writeFileSync(path.join(coLock, 'owner.json'), JSON.stringify({ pid: deadPid(), token: 'dead', run_id: 'old-run' }));
  const r3 = await cli(['run', '--root', root], { locks });
  assert.equal(r3.status, 0, r3.out);
  assert.match(r3.stdout, /^lock: reclaimed checkout-[0-9a-f]{16} from dead pid \d+ \(run old-run\)$/m);
  assert.deepEqual(fs.readdirSync(locks), [], 'both locks released');
});

test('lock is kept while the runner group lives', async () => {
  const root = copyRoot();
  useRunner(root, 'green attest-all 0');
  const locks = fs.mkdtempSync(path.join(os.tmpdir(), 'regression-locks-'));
  const group = spawn('sleep', ['30'], { detached: true, stdio: 'ignore' });
  try {
    holdLock(locks, `env-${h16('https://test.shop.example.com')}`, { pid: deadPid(), pgid: group.pid });
    const r = await cli(['run', '--root', root], { locks });
    assert.equal(r.status, 3, r.out);
    assert.equal(runnerCalls(root), 0);
  } finally {
    process.kill(-group.pid, 'SIGKILL');
  }
});

test('record holds digests devices results and no model output', async () => {
  const root = copyRoot();
  knownBuild(root);
  useRunner(root, 'red attest-all 1');
  const r = await cli(['run', '--root', root]);
  const rec = recordOf(root, r);
  for (const k of ['run_id', 'env', 'kind', 'base_url', 'mode', 'started_at', 'ended_at', 'head_sha', 'build_sha', 'build_sha_after', 'build_sha_source',
    'runner_exit', 'report_errors', 'digests', 'devices', 'command', 'versions', 'confirmed', 'cases', 'orphans', 'outside_selection',
    'not_run_policy', 'no_device', 'guard', 'counts', 'verdict', 'reasons', 'exit']) assert.ok(k in rec, `record lacks ${k}`);
  assert.deepEqual(Object.keys(rec.digests).sort(), ['catalog', 'config', 'plan']);
  assert.deepEqual(rec.devices.sort(), ['desktop-chrome', 'mobile-safari']);
  assert.equal(rec.versions.runner, '1.64.0');
  assert.deepEqual(Object.keys(rec.cases[0]).sort(), ['duration_ms', 'id', 'project', 'result']);
  const text = fs.readFileSync(path.join(root, /^record: (.+)$/m.exec(r.stdout)[1]), 'utf8');
  assert.doesNotMatch(text, /RUNNER-SECRET-MESSAGE/, 'no runner error text in the record');
  assert.equal(fs.readFileSync(path.join(root, '.agents/regression/runs/.gitignore'), 'utf8'), '*\n');
});

test('red run prints the heal command and does not start it', async () => {
  const root = copyRoot();
  knownBuild(root);
  useRunner(root, 'red attest-all 1');
  const r = await cli(['run', '--root', root]);
  assert.equal(r.status, 1);
  const rec = recordOf(root, r);
  assert.match(r.stdout, new RegExp(`^next: /regression-tests heal --run ${rec.run_id}$`, 'm'));
  assert.equal(runnerCalls(root), 1, 'the runner ran once; heal was not started');
});

// ---------------------------------------------------------------------------------------------
// Production guarantees

test('production run refused when the runner config is not guard-integrated', async () => {
  const root = copyRoot();
  useRunner(root, 'green-prod attest-all 0');
  fs.writeFileSync(path.join(root, 'e2e/playwright.config.ts'), "import { defineConfig } from '@playwright/test';\nexport default defineConfig({ testDir: './regression' });\n");
  const r = await cli(['run', '--env', 'prod', '--root', root]);
  assert.equal(r.status, 3);
  assert.match(r.stderr, /^runner not guard-integrated — e2e\/playwright\.config\.ts: does not import runnerOptions/m);
  assert.doesNotMatch(r.stdout, /confirmation-required/, 'refused before the confirmation');
  assert.equal(fs.existsSync(path.join(root, 'e2e/.results/report.json')), false, 'no report was written');
  assert.equal(runnerCalls(root), 0);
});

test('pre-flight rejects an old fixture or a spec importing the base test', async () => {
  const oldFixture = copyRoot();
  fs.writeFileSync(path.join(oldFixture, 'e2e/fixtures.ts'), fs.readFileSync(path.join(FIX, 'root/e2e/fixtures.ts'), 'utf8').replace(/^import \{ installGuard[^\n]*\n/m, ''));
  const r1 = await cli(['run', '--env', 'prod', '--root', oldFixture]);
  assert.equal(r1.status, 3);
  assert.match(r1.stderr, /e2e\/fixtures\.ts: does not import installGuard/);
  const baseTest = copyRoot();
  const spec = path.join(baseTest, 'e2e/regression/pdp.spec.ts');
  fs.writeFileSync(spec, fs.readFileSync(spec, 'utf8').replace("from '../fixtures'", "from '@playwright/test'"));
  const r2 = await cli(['run', '--env', 'prod', '--root', baseTest]);
  assert.equal(r2.status, 3);
  assert.match(r2.stderr, /pdp\.spec\.ts: imports test from @playwright\/test/);
  const comment = copyRoot();
  fs.writeFileSync(path.join(comment, 'e2e/playwright.config.ts'), "// import { runnerOptions } from '../.claude/lib/regression/guard.mjs';\nimport { defineConfig } from '@playwright/test';\nexport default defineConfig({});\n");
  const r3 = await cli(['run', '--env', 'prod', '--root', comment]);
  assert.equal(r3.status, 3, 'the guard path only in a comment does not count');
  const headers = copyRoot();
  fs.appendFileSync(path.join(headers, 'e2e/playwright.config.ts'), "export const extra = { extraHTTPHeaders: { authorization: 'x' } };\n");
  const r4 = await cli(['run', '--env', 'prod', '--root', headers]);
  assert.equal(r4.status, 3);
  assert.match(r4.stderr, /sets extraHTTPHeaders/);
});

test('production run without case attestation is blocked', async () => {
  const root = copyRoot();
  knownBuild(root, 'prod');
  useRunner(root, 'green-prod attest-none 0');
  const r = await prodRun(root);
  assert.equal(r.status, 5, r.out);
  assert.match(r.stdout, /^reason: guard not attested for CART-001\/desktop-chrome$/m);
  assert.match(r.stdout, /^verdict: BLOCKED\/ENV$/m);
});

test('production run without session attestation is blocked', async () => {
  const root = copyRoot();
  knownBuild(root, 'prod');
  useRunner(root, 'green-prod session-missing 0');
  const r = await prodRun(root);
  assert.equal(r.status, 5, r.out);
  assert.match(r.stdout, /^reason: session not guard-attested for shopper$/m);
  const ok = copyRoot();
  knownBuild(ok, 'prod');
  useRunner(ok, 'green-prod attest-all 0');
  const g = await prodRun(ok);
  assert.equal(g.status, 0, `fully attested production run is green: ${g.out}`);
  const t = copyRoot();
  knownBuild(t);
  useRunner(t, 'green session-missing 0');
  const w = await cli(['run', '--root', t]);
  assert.equal(w.status, 0, 'on a test environment it is a warning');
  assert.match(w.stdout, /^warning: session not guard-attested for shopper$/m);
});

test('guard stop makes the run blocked env', async () => {
  const root = copyRoot();
  knownBuild(root);
  useRunner(root, 'green stop-429 0');
  const r = await cli(['run', '--root', root]);
  assert.equal(r.status, 5, r.out);
  assert.match(r.stdout, /^reason: guard stop: status 429$/m);
  assert.equal(recordOf(root, r).guard.stop.reason, 'status 429');
  const noReport = copyRoot();
  knownBuild(noReport);
  useRunner(noReport, '- stop-429 0');
  const r2 = await cli(['run', '--root', noReport]);
  assert.equal(r2.status, 5, 'a missing report with a stop is BLOCKED/ENV, not INCOMPLETE');
});

// ---------------------------------------------------------------------------------------------
// Runner options, example, run directories, consent

test('runner options filter each project by its own cases', () => {
  const opts = runnerOptions({
    workers: 2, pacing: { action_delay_ms: 50 },
    selection: [{ id: 'CART-001', project: 'desktop' }, { id: 'CART-002', project: 'desktop' }, { id: 'CART-002', project: 'mobile' }],
  });
  assert.equal(opts.workers, 2);
  assert.deepEqual(opts.use, { serviceWorkers: 'block', launchOptions: { slowMo: 50 } });
  const mobile = opts.grepFor('mobile');
  assert.equal(mobile.test('mobile cart.spec.ts CART-001 — Open the cart'), false, 'a desktop-only scenario never runs on mobile');
  assert.equal(mobile.test('mobile cart.spec.ts CART-002 — Add to cart'), true);
  assert.equal(opts.grepFor('desktop').test('desktop cart.spec.ts CART-001 — Open the cart'), true);
  assert.equal(opts.grepFor('desktop').test('desktop cart.spec.ts XCART-001 — Open'), false);
  const none = opts.grepFor('tablet');
  assert.equal(none.test('tablet cart.spec.ts CART-001 — Open the cart'), false, 'a project with no case matches nothing');
  assert.equal(none.test(''), false);
});

test('the config example runs without a smoke grep', () => {
  const example = JSON.parse(fs.readFileSync(path.join(REPO, '.claude/regression.json.example'), 'utf8'));
  assert.doesNotMatch(example.runner.commands.smoke, /--grep/);
  assert.doesNotMatch(example.runner.commands.full, /--grep/);
  assert.deepEqual(validateConfig(example), []);
  assert.equal(example.default_env, 'test');
});

test('two runs in one second get separate run directories', async () => {
  const root = copyRoot();
  knownBuild(root);
  useRunner(root, 'green stop-429 0');
  const env = { REGRESSION_NOW: '2026-11-26T12:00:00.000Z' };
  const a = await cli(['run', '--root', root], { env });
  useRunner(root, 'green attest-all 0');
  const b = await cli(['run', '--root', root], { env });
  const ra = recordOf(root, a);
  const rb = recordOf(root, b);
  assert.notEqual(ra.run_id, rb.run_id);
  assert.match(ra.run_id, /^test-20261126T120000Z-[0-9a-f]{4}$/);
  assert.equal(ra.verdict, 'BLOCKED/ENV');
  assert.equal(rb.verdict, 'GREEN', 'the second run does not inherit the first run stop');
  assert.equal(fs.existsSync(path.join(root, '.agents/regression/runs', rb.run_id, 'stop.json')), false);
});

test('consent cookie without path defaults to slash', () => {
  const p = envPolicy({ host: 'https://shop.example.com', consent: { strategy: 'decline', cookies: [{ name: 'consent', value: 'denied', domain: 'shop.example.com' }] } });
  assert.deepEqual(p.consent.cookies, [{ name: 'consent', value: 'denied', domain: 'shop.example.com', path: '/' }]);
  const errors = validateConfig({ version: 1, catalog: {}, environments: { prod: { host: 'https://shop.example.com', consent: { cookies: [{ name: 'c', value: 'v', domain: 'd', path: 'no-slash' }] } } } });
  assert.ok(errors.some((e) => /^environments\.prod\.consent\.cookies:/.test(e)));
});
