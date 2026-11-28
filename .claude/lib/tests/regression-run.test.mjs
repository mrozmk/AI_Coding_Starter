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
import { catalogFiles, parseCatalog, validateCatalog, needsKeys, blockTexts } from '../regression/catalog.mjs';
import { lintSpec } from '../regression/speclint.mjs';
import { buildPlan, confirmationText, worstCaseBackendCalls, evidenceKey } from '../regression/policy.mjs';
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
    // A queued `{status}` answers that status with no body.
    if (typeof sha === 'object' && sha !== null) { res.writeHead(sha.status); res.end(); return; }
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

test('run incomplete when the runner writes no report', async () => {
  const root = copyRoot();
  knownBuild(root);
  useRunner(root, '- attest-all 0');
  const r = await cli(['run', '--root', root]);
  assert.equal(r.status, 4, r.out);
  assert.match(r.stdout, /^reason: runner report missing, unparseable or invalid$/m);
  assert.doesNotMatch(r.stdout, /zero executed cases/);
  assert.doesNotMatch(r.stdout, /regression-tests heal/, 'no heal for a run that produced no results');
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

test('pre-flight sees a forbidden key between route globs', async () => {
  const root = copyRoot();
  fs.appendFileSync(path.join(root, 'e2e/regression/pdp.spec.ts'),
    "test.beforeEach(async ({ page }) => { await page.route('**/*.png', (r) => r.abort()); });\ntest.use({ extraHTTPHeaders: { authorization: 'x' } });\ntest.afterEach(async ({ page }) => { await page.unroute('**/*.css'); });\n");
  const r = await cli(['run', '--env', 'prod', '--root', root]);
  assert.equal(r.status, 3, r.out);
  assert.match(r.stderr, /pdp\.spec\.ts: sets extraHTTPHeaders/);
  const glob = copyRoot();
  const config = path.join(glob, 'e2e/playwright.config.ts');
  fs.writeFileSync(config, `const assets = '**/*.png';\n${fs.readFileSync(config, 'utf8')}\nconst styles = '**/*.css';\n`);
  const g = await cli(['run', '--env', 'prod', '--root', glob]);
  assert.match(g.stdout, /^confirmation-required: /m, `a glob before the import does not hide it: ${g.out}`);
});

test('pre-flight refuses a spec or fixture that installs its own route', async () => {
  const spec = copyRoot();
  fs.appendFileSync(path.join(spec, 'e2e/regression/cart.spec.ts'), "test.beforeEach(async ({ page }) => { await page.route('**/*', (r) => r.continue()); });\n");
  const r1 = await cli(['run', '--env', 'prod', '--root', spec]);
  assert.equal(r1.status, 3, r1.out);
  assert.match(r1.stderr, /^runner not guard-integrated — e2e\/regression\/cart\.spec\.ts: installs its own route \(\.route\(\)/m);
  assert.doesNotMatch(r1.stdout, /confirmation-required/, 'refused before the confirmation');
  assert.equal(runnerCalls(spec), 0);
  const har = copyRoot();
  fs.appendFileSync(path.join(har, 'e2e/fixtures.ts'), "export const replay = (page) => page.routeFromHAR('e2e/shop.har');\n");
  const r2 = await cli(['run', '--env', 'prod', '--root', har]);
  assert.equal(r2.status, 3, r2.out);
  assert.match(r2.stderr, /e2e\/fixtures\.ts: installs its own route \(routeFromHAR\)/);
  const commented = copyRoot();
  fs.appendFileSync(path.join(commented, 'e2e/regression/cart.spec.ts'), "// page.route('**/*', (r) => r.continue());\n");
  const r3 = await cli(['run', '--env', 'prod', '--root', commented]);
  assert.match(r3.stdout, /^confirmation-required: /m, `a whole-line comment is not a route: ${r3.out}`);
  const t = copyRoot();
  knownBuild(t);
  useRunner(t, 'green attest-all 0');
  fs.appendFileSync(path.join(t, 'e2e/regression/cart.spec.ts'), "test.beforeEach(async ({ page }) => { await page.route('**/*', (r) => r.continue()); });\n");
  const w = await cli(['run', '--root', t]);
  assert.equal(w.status, 0, `on a test environment it is a warning: ${w.out}`);
  assert.match(w.stdout, /^warning: runner not guard-integrated — e2e\/regression\/cart\.spec\.ts: installs its own route/m);
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

test('a skipped case needs no attestation on production', async () => {
  const root = copyRoot();
  knownBuild(root, 'prod');
  useRunner(root, 'skipped-prod attest-skip-first 0');
  const r = await prodRun(root);
  assert.equal(r.status, 4, r.out);
  assert.match(r.stdout, /^reason: skipped: CART-001\/desktop-chrome$/m);
  assert.doesNotMatch(r.stdout, /guard not attested/);
  assert.match(r.stdout, /^verdict: INCOMPLETE$/m);
});

test('a failed sign-in is no session attestation gap', async () => {
  const root = copyRoot();
  knownBuild(root, 'prod');
  useRunner(root, 'green-prod session-failed 0');
  const r = await prodRun(root);
  assert.doesNotMatch(r.stdout, /session not guard-attested/, r.out);
  assert.doesNotMatch(r.stdout, /^verdict: BLOCKED\/ENV$/m);
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

test('environment redact must be an array of compilable regexes', () => {
  const env = (redact) => ({ version: 1, catalog: {}, environments: { prod: { host: 'https://shop.example.com', redact } } });
  for (const bad of ['x', ['('], [1]]) {
    assert.ok(validateConfig(env(bad)).includes('environments.prod.redact: must be an array of compilable regexes'), JSON.stringify(bad));
  }
  assert.deepEqual(validateConfig(env(['lic-[0-9]+'])), []);
  assert.deepEqual(envPolicy({ host: 'https://shop.example.com' }).redact, []);
  assert.deepEqual(envPolicy({ host: 'https://shop.example.com', redact: ['lic-[0-9]+'] }).redact, ['lic-[0-9]+']);
});

// ---------------------------------------------------------------------------------------------
// The walk and verify lanes (#332)

const sha256 = (b) => createHash('sha256').update(b).digest('hex');

/** Add the authoring files (CART-008..010, their candidate specs, the walk stub) to a temp copy only. */
function withAuthoringFiles(root) {
  const src = path.join(FIX, 'authoring');
  fs.appendFileSync(path.join(root, CAT, 'cart.md'), fs.readFileSync(path.join(src, 'cart-append.md'), 'utf8'));
  fs.cpSync(path.join(src, 'e2e'), path.join(root, 'e2e'), { recursive: true });
  return root;
}

/** A staged route list in the temp root. */
function stagedRoutes(root, routes) {
  const file = path.join(root, '.agents/regression/runs/inventory-t/routes.staged.json');
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, `${JSON.stringify({ schema: 1, routes }, null, 2)}\n`);
  return file;
}
const WALK_ROUTES = [
  { route: '/', source: 'app/home.tsx', sample: '/', submit: [{ form: 'search', action: '/search', method: 'GET', inputs: { q: 'shoes' } }] },
  { route: '/account', source: 'app/account.tsx', sample: '/account', account: 'shopper' },
];
const walkOf = (root, r) => {
  const m = /^record: (.+walk\.json)$/m.exec(r.stdout);
  assert.ok(m, `no walk record in:\n${r.out}`);
  return JSON.parse(fs.readFileSync(path.join(root, m[1]), 'utf8'));
};
const verifyOf = (root, r) => {
  const m = /^record: (.+verify\.json)$/m.exec(r.stdout);
  assert.ok(m, `no verify record in:\n${r.out}`);
  return JSON.parse(fs.readFileSync(path.join(root, m[1]), 'utf8'));
};
const PAIR8 = 'CART-008=e2e/regression/cart/cart-008.spec.ts';
const PAIR9 = 'CART-009=e2e/regression/cart/cart-009.spec.ts';

test('walk: refuses a team clone, a missing stub and a non-GET submit entry', async () => {
  const team = withAuthoringFiles(copyRoot());
  fs.mkdirSync(path.join(team, '.agents/team'), { recursive: true });
  fs.writeFileSync(path.join(team, '.agents/team/team.json'), '{}\n');
  const t = await cli(['walk', '--routes', stagedRoutes(team, WALK_ROUTES), '--root', team]);
  assert.equal(t.status, 3, t.out);
  assert.match(t.stderr, /a team clone never runs regression/);
  const nostub = copyRoot();
  const s = await cli(['walk', '--routes', stagedRoutes(nostub, WALK_ROUTES), '--root', nostub]);
  assert.equal(s.status, 2, s.out);
  assert.match(s.stderr, /walk stub missing — \/setup:regression --inventory installs it/);
  const post = withAuthoringFiles(copyRoot());
  const p = await cli(['walk', '--routes', stagedRoutes(post, [{ route: '/login', source: 's', submit: [{ form: 'login', action: '/login', method: 'POST', inputs: {} }] }]), '--root', post]);
  assert.equal(p.status, 2, p.out);
  assert.match(p.stderr, /submit login: only GET forms may be allow-listed/);
  for (const r of [team, nostub, post]) assert.equal(runnerCalls(r), 0);
});

test('walk: production prints a confirmation naming the routes, groups and submit entries', async () => {
  const root = withAuthoringFiles(copyRoot());
  useRunner(root, 'walk-green walk-groups 0', 'full');
  const r = await cli(['walk', '--env', 'prod', '--routes', stagedRoutes(root, WALK_ROUTES), '--root', root]);
  assert.equal(r.status, 3, r.out);
  assert.match(r.stdout, /^target: prod \(production\) https:\/\/shop\.example\.com · walk · 2 routes in 2 groups$/m);
  assert.match(r.stdout, /^mode: walk$/m);
  assert.match(r.stdout, /^routes: 2 · groups: WALK1,WALK2 · submit entries: \/ search \/search q$/m);
  const token = tokenOf(r);
  assert.ok(token);
  assert.ok(fs.existsSync(path.join(root, '.agents/regression/runs/.confirm/prod.walk.json')), 'a walk token has its own lane');
  const ok = await cli(['walk', '--env', 'prod', '--confirm', token, '--routes', stagedRoutes(root, WALK_ROUTES), '--root', root]);
  assert.equal(ok.status, 0, ok.out);
  assert.equal(walkOf(root, ok).confirmed, true);
  assert.equal(runnerCalls(root), 1);
});

test('walk: a group whose account is not a declared means is not walked — policy', async () => {
  const root = withAuthoringFiles(copyRoot());
  useRunner(root, 'walk-missing walk-groups 0', 'full');
  const routes = [WALK_ROUTES[0], { route: '/admin', source: 'app/admin.tsx', sample: '/admin', account: 'admin' }];
  const r = await cli(['walk', '--routes', stagedRoutes(root, routes), '--root', root]);
  assert.equal(r.status, 0, r.out);
  assert.match(r.stdout, /^not walked — policy: WALK2 — account:admin not declared for test$/m);
  const rec = walkOf(root, r);
  assert.deepEqual(rec.excluded.map((e) => [e.group, e.reason]), [['WALK2', 'account:admin not declared for test']]);
  const observations = JSON.parse(fs.readFileSync(path.join(root, /^observations: (.+)$/m.exec(r.stdout)[1]), 'utf8'));
  assert.deepEqual(observations.find((o) => o.route === '/admin'), { route: '/admin', group: 'WALK2', account: 'admin', outcome: 'not-walked', reason: 'policy: account:admin not declared for test', sample: null });
});

test('walk: merges the group files into observations and is COMPLETE', async () => {
  const root = withAuthoringFiles(copyRoot());
  useRunner(root, 'walk-green walk-groups 0', 'full');
  const r = await cli(['walk', '--routes', stagedRoutes(root, WALK_ROUTES), '--root', root]);
  assert.equal(r.status, 0, r.out);
  assert.match(r.stdout, /^walk: COMPLETE$/m);
  const observations = JSON.parse(fs.readFileSync(path.join(root, /^observations: (.+)$/m.exec(r.stdout)[1]), 'utf8'));
  assert.deepEqual(observations.map((o) => [o.route, o.group, o.account, o.outcome]), [['/', 'WALK1', null, 'ok'], ['/account', 'WALK2', 'shopper', 'ok']]);
  const rec = walkOf(root, r);
  assert.deepEqual(rec.groups.map((g) => [g.key, g.result, g.done]), [['WALK1', 'passed', true], ['WALK2', 'passed', true]]);
  const manifest = JSON.parse(fs.readFileSync(path.join(root, '.agents/regression/runs', rec.run_id, 'manifest.json'), 'utf8'));
  assert.deepEqual(manifest.walk.groups.map((g) => g.key), ['WALK1', 'WALK2']);
  assert.deepEqual(manifest.selection.map((c) => [c.id, c.title, c.project, c.spec]), [['WALK1', 'WALK1 — anonymous', 'desktop-chrome', 'e2e/regression/_walk.spec.ts'], ['WALK2', 'WALK2 — shopper', 'desktop-chrome', 'e2e/regression/_walk.spec.ts']]);
});

test('walk: a missing group case or a missing attestation is not COMPLETE', async () => {
  const lastGroup = withAuthoringFiles(copyRoot());
  useRunner(lastGroup, 'walk-green walk-groups-missing-last 0', 'full');
  const a = await cli(['walk', '--routes', stagedRoutes(lastGroup, WALK_ROUTES), '--root', lastGroup]);
  assert.equal(a.status, 4, a.out);
  assert.match(a.stdout, /^reason: group WALK2 not done$/m);
  const missingCase = withAuthoringFiles(copyRoot());
  useRunner(missingCase, 'walk-missing walk-groups 0', 'full');
  const b = await cli(['walk', '--routes', stagedRoutes(missingCase, WALK_ROUTES), '--root', missingCase]);
  assert.equal(b.status, 4, b.out);
  assert.match(b.stdout, /^reason: missing: WALK2\/desktop-chrome$/m);
  const unattested = withAuthoringFiles(copyRoot());
  useRunner(unattested, 'walk-green attest-none 0', 'full');
  const c = await cli(['walk', '--routes', stagedRoutes(unattested, WALK_ROUTES), '--root', unattested]);
  assert.notEqual(c.status, 0, c.out);
  assert.doesNotMatch(c.stdout, /^walk: COMPLETE$/m);
  assert.match(c.stdout, /^reason: guard not attested for WALK1\/desktop-chrome$/m);
});

test('walk: report errors or a missing session attestation are not COMPLETE', async () => {
  const errors = withAuthoringFiles(copyRoot());
  useRunner(errors, 'walk-errors walk-groups 0', 'full');
  const a = await cli(['walk', '--routes', stagedRoutes(errors, WALK_ROUTES), '--root', errors]);
  assert.equal(a.status, 4, a.out);
  assert.match(a.stdout, /^reason: report errors: 1$/m);
  const session = withAuthoringFiles(copyRoot());
  useRunner(session, 'walk-green walk-groups-session-missing 0', 'full');
  const b = await cli(['walk', '--routes', stagedRoutes(session, WALK_ROUTES), '--root', session]);
  assert.equal(b.status, 5, b.out);
  assert.match(b.stdout, /^reason: session not guard-attested for shopper$/m);
  assert.match(b.stdout, /^walk: BLOCKED\/ENV$/m);
});

test('walk: a test environment refuses a runner that is not guard-integrated', async () => {
  const root = withAuthoringFiles(copyRoot());
  useRunner(root, 'walk-green walk-groups 0', 'full');
  fs.writeFileSync(path.join(root, 'e2e/fixtures.ts'), fs.readFileSync(path.join(FIX, 'root/e2e/fixtures.ts'), 'utf8').replace(/^import \{ installGuard[^\n]*\n/m, ''));
  const r = await cli(['walk', '--routes', stagedRoutes(root, WALK_ROUTES), '--root', root]);
  assert.equal(r.status, 3, r.out);
  assert.match(r.stderr, /^runner not guard-integrated — e2e\/fixtures\.ts: does not import installGuard/m);
  assert.equal(runnerCalls(root), 0);
});

test('walk: walk.json binds the staged routes digest and lists the redacted samples', async () => {
  const root = withAuthoringFiles(copyRoot());
  useRunner(root, 'walk-green walk-groups 0', 'full');
  editConfig(root, (cfg) => { cfg.environments.test.redact = ['lic-[0-9]+']; });
  const routes = [{ ...WALK_ROUTES[0], sample: '/?ref=mail' }, { ...WALK_ROUTES[1], sample: '/account/lic-42' }];
  const file = stagedRoutes(root, routes);
  const r = await cli(['walk', '--routes', file, '--root', root]);
  assert.equal(r.status, 0, r.out);
  const rec = walkOf(root, r);
  assert.equal(rec.routes_digest, sha256(fs.readFileSync(file)));
  assert.equal(rec.routes_file, '.agents/regression/runs/inventory-t/routes.staged.json');
  assert.deepEqual(rec.redacted_samples, ['/', '/account']);
});

test('verify: refuses a scenario that is not READY, already has a Spec, or a write under writes refuse', async () => {
  const root = withAuthoringFiles(copyRoot());
  editConfig(root, (cfg) => { cfg.environments.test.writes = 'refuse'; });
  const r = await cli(['verify', 'CART-005=e2e/regression/cart/cart-008.spec.ts', 'CART-001=e2e/regression/cart.spec.ts', 'CART-010=e2e/regression/cart/cart-010.spec.ts', '--root', root]);
  assert.equal(r.status, 3, r.out);
  assert.match(r.stdout, /^refused: CART-005 — not READY \(BLOCKED \(#12\)\)$/m);
  assert.match(r.stdout, /^refused: CART-001 — already has a spec$/m);
  assert.match(r.stdout, /^refused: CART-010 — writes refuse$/m);
  assert.equal(runnerCalls(root), 0);
});

test('verify: three green passes qualify the scenario and record both digests', async () => {
  const root = withAuthoringFiles(copyRoot());
  useRunner(root, 'verify-green attest-pass 0', 'full');
  const r = await cli(['verify', PAIR8, '--root', root]);
  assert.equal(r.status, 0, r.out);
  const spec = fs.readFileSync(path.join(root, 'e2e/regression/cart/cart-008.spec.ts'));
  const m = /^verified: CART-008 spec_sha256=([0-9a-f]{64}) inputs_sha256=([0-9a-f]{64}) block_sha256=([0-9a-f]{64})$/m.exec(r.stdout);
  assert.ok(m, r.out);
  assert.equal(m[1], sha256(spec));
  const rec = verifyOf(root, r);
  const s = rec.scenarios[0];
  assert.deepEqual({ qualified: s.qualified, passes_ok: s.passes_ok, projects: s.projects, spec_sha256: s.spec_sha256, inputs_sha256: s.inputs_sha256 }, { qualified: true, passes_ok: [1, 2, 3], projects: ['desktop-chrome', 'mobile-safari'], spec_sha256: m[1], inputs_sha256: m[2] });
  assert.equal(new Set(rec.passes.map((p) => p.nonce)).size, 3, 'one nonce per pass');
  assert.ok(rec.passes.every((p) => p.cases.length === 2 && p.cases.every((c) => c.result === 'passed' && c.attempts === 1)));
  assert.equal(runnerCalls(root), 3);
  for (const n of [1, 2, 3]) assert.ok(fs.existsSync(path.join(root, '.agents/regression/runs', rec.run_id, `report-${n}.json`)));
});

test('verify: a retry, a flaky result or a missing per-pass attestation does not qualify', async () => {
  const flaky = withAuthoringFiles(copyRoot());
  useRunner(flaky, 'verify-retry attest-pass 0', 'full');
  const a = await cli(['verify', PAIR8, '--root', flaky]);
  assert.equal(a.status, 1, a.out);
  assert.match(a.stdout, /^not verified: CART-008 — flaky in pass 1$/m);
  assert.equal(runnerCalls(flaky), 1, 'a scenario that lost a case runs no further pass');
  const unattested = withAuthoringFiles(copyRoot());
  useRunner(unattested, 'verify-green attest-pass,attest-none,attest-pass 0', 'full');
  const b = await cli(['verify', PAIR8, '--root', unattested]);
  assert.equal(b.status, 1, b.out);
  assert.match(b.stdout, /^not verified: CART-008 — no guard attestation in pass 2$/m);
  assert.deepEqual(verifyOf(unattested, b).scenarios[0].passes_ok, [1]);
});

test('verify: a scenario that fails pass 1 is dropped from later passes and prints its context', async () => {
  const root = withAuthoringFiles(copyRoot());
  useRunner(root, 'verify-failed attest-pass 1', 'full');
  const r = await cli(['verify', PAIR8, '--root', root]);
  assert.equal(r.status, 1, r.out);
  assert.match(r.stdout, /^not verified: CART-008 — failed in pass 1$/m);
  assert.match(r.stdout, /^context: test-results\/x\/error-context\.md$/m);
  assert.equal(runnerCalls(root), 1);
});

test('verify: a failed case keeps a copy of its attachment in the run directory', async () => {
  const root = withAuthoringFiles(copyRoot());
  fs.mkdirSync(path.join(root, 'test-results/x'), { recursive: true });
  fs.writeFileSync(path.join(root, 'test-results/x/error-context.md'), 'the page at the failure\n');
  useRunner(root, 'verify-failed attest-pass 1', 'full');
  const r = await cli(['verify', PAIR8, '--root', root]);
  assert.equal(r.status, 1, r.out);
  const kept = /^context: (\.agents\/regression\/runs\/\S+\/context-1\/test-results\/x\/error-context\.md)$/m.exec(r.stdout);
  assert.ok(kept, r.out);
  assert.equal(fs.readFileSync(path.join(root, kept[1]), 'utf8'), 'the page at the failure\n');
  assert.deepEqual(verifyOf(root, r).scenarios[0].context, [kept[1]]);
});

test('verify: production confirmation covers the three passes', async () => {
  const root = withAuthoringFiles(copyRoot());
  useRunner(root, 'verify-green attest-pass 0', 'full');
  const locks = fs.mkdtempSync(path.join(os.tmpdir(), 'regression-locks-'));
  const first = await cli(['verify', PAIR8, '--env', 'prod', '--root', root], { locks });
  assert.equal(first.status, 3, first.out);
  assert.match(first.stdout, /^repeats: 3 passes over 2 cases \(CART-008\)$/m);
  assert.match(first.stdout, /^mode: verify$/m);
  const ok = await cli(['verify', PAIR8, '--env', 'prod', '--confirm', tokenOf(first), '--root', root], { locks });
  assert.equal(ok.status, 0, ok.out);
  assert.equal(runnerCalls(root), 3, 'one token, three passes');
  assert.equal(verifyOf(root, ok).confirmed, true);
  const again = await cli(['verify', PAIR8, '--env', 'prod', '--confirm', tokenOf(first), '--root', root], { locks });
  assert.equal(again.status, 3, 'the token covered that verify only');
});

test('verify: a missing session attestation, a block outside a test, an orphan or an outside-selection case, or report errors do not qualify', async () => {
  const cases = [
    [PAIR9, 'verify-green-009', 'session-missing', /^not verified: CART-009 — no session evidence for account:shopper in pass 1$/m],
    [PAIR8, 'verify-green', 'blocked-outside', /^not verified: CART-008 — pass 1: blocked request outside a test$/m],
    [PAIR8, 'verify-orphan', 'attest-pass', /^not verified: CART-008 — pass 1: no scenario id: Untitled check$/m],
    [PAIR8, 'verify-outside', 'attest-pass', /^not verified: CART-008 — pass 1: outside the selection: CART-001\/desktop-chrome$/m],
    [PAIR8, 'verify-errors', 'attest-pass', /^not verified: CART-008 — pass 1: report errors: 1$/m],
  ];
  for (const [pair, report, events, re] of cases) {
    const root = withAuthoringFiles(copyRoot());
    useRunner(root, `${report} ${events} 0`, 'full');
    const r = await cli(['verify', pair, '--root', root]);
    assert.equal(r.status, 1, `${report} ${events}: ${r.out}`);
    assert.match(r.stdout, re, `${report} ${events}`);
  }
});

test('verify: refuses before the runner starts when retries are not zero or the candidate fails lint', async () => {
  const retries = withAuthoringFiles(copyRoot());
  useRunner(retries, 'verify-green attest-pass 0', 'full');
  const config = path.join(retries, 'e2e/playwright.config.ts');
  fs.writeFileSync(config, fs.readFileSync(config, 'utf8').replace('retries: 0', 'retries: 2'));
  const a = await cli(['verify', PAIR8, '--root', retries]);
  assert.equal(a.status, 3, a.out);
  assert.match(a.stdout, /^refused: CART-008 — retries are not 0 — config$/m);
  const lint = withAuthoringFiles(copyRoot());
  useRunner(lint, 'verify-green attest-pass 0', 'full');
  const spec = path.join(lint, 'e2e/regression/cart/cart-008.spec.ts');
  fs.writeFileSync(spec, fs.readFileSync(spec, 'utf8').replace("  await page.goto('/cart');", "  await page.goto('/cart');\n  await page.waitForTimeout(500);"));
  const b = await cli(['verify', PAIR8, '--root', lint]);
  assert.equal(b.status, 3, b.out);
  assert.match(b.stdout, /^refused: CART-008 — lint: forbidden waitForTimeout\($/m);
  assert.equal(runnerCalls(retries) + runnerCalls(lint), 0);
});

test('verify: refuses a project-level or spec-level retries override before the runner starts', async () => {
  const project = withAuthoringFiles(copyRoot());
  const config = path.join(project, 'e2e/playwright.config.ts');
  fs.writeFileSync(config, fs.readFileSync(config, 'utf8').replace("{ name: 'mobile-safari',", "{ name: 'mobile-safari', retries: 1,"));
  const a = await cli(['verify', PAIR8, '--root', project]);
  assert.equal(a.status, 3, a.out);
  assert.match(a.stdout, /^refused: CART-008 — retries are not 0 — config$/m);
  const spec = withAuthoringFiles(copyRoot());
  const f = path.join(spec, 'e2e/regression/cart/cart-008.spec.ts');
  fs.writeFileSync(f, `${fs.readFileSync(f, 'utf8')}test.describe.configure({ retries: 2 });\n`);
  const b = await cli(['verify', PAIR8, '--root', spec]);
  assert.equal(b.status, 3, b.out);
  assert.match(b.stdout, /^refused: CART-008 — retries are not 0 — spec$/m);
  const command = withAuthoringFiles(copyRoot());
  editConfig(command, (cfg) => { cfg.runner.commands.full = 'npx playwright test --retries=1'; });
  const c = await cli(['verify', PAIR8, '--root', command]);
  assert.equal(c.status, 3, c.out);
  assert.match(c.stdout, /^refused: CART-008 — retries are not 0 — command$/m);
  for (const r of [project, spec, command]) assert.equal(runnerCalls(r), 0);
});

test('verify: the record aggregates blocked events and budget across the three nonces', async () => {
  const root = withAuthoringFiles(copyRoot());
  useRunner(root, 'verify-green attest-budget,attest-budget,blocked-case 0', 'full');
  const r = await cli(['verify', PAIR8, '--root', root]);
  assert.equal(r.status, 1, r.out);
  assert.match(r.stdout, /^not verified: CART-008 — failed in pass 3$/m);
  const rec = verifyOf(root, r);
  assert.deepEqual(rec.guard.blocked.map((b) => [b.reason, b.pass]), [['foreign host', 3]]);
  assert.deepEqual({ reserved: rec.guard.budget.reserved, by_op: rec.guard.budget.by_op }, { reserved: 2, by_op: { 'price-call': 2 } });
  assert.deepEqual(rec.scenarios[0].passes_ok, [1, 2]);
});

test('verify: an account-required candidate with case attestations and no session events does not qualify', async () => {
  const root = withAuthoringFiles(copyRoot());
  useRunner(root, 'verify-green-009 attest-cases-only 0', 'full');
  const r = await cli(['verify', PAIR9, '--root', root]);
  assert.equal(r.status, 1, r.out);
  assert.match(r.stdout, /^not verified: CART-009 — no session evidence for account:shopper in pass 1$/m);
  const old = withAuthoringFiles(copyRoot());
  useRunner(old, 'verify-green-009 session-no-test 0', 'full');
  const o = await cli(['verify', PAIR9, '--root', old]);
  assert.match(o.stdout, /^not verified: CART-009 — fixture predates per-case sessions — re-copy fixtures\.ts \(regression\.md §11\)$/m);
});

test('verify: two projects sharing one account each need their own session evidence', async () => {
  const root = withAuthoringFiles(copyRoot());
  useRunner(root, 'verify-green-009 session-first-only 0', 'full');
  const r = await cli(['verify', PAIR9, '--root', root]);
  assert.equal(r.status, 1, r.out);
  assert.match(r.stdout, /^not verified: CART-009 — no session evidence for account:shopper in pass 1$/m);
  const ok = withAuthoringFiles(copyRoot());
  useRunner(ok, 'verify-green-009 attest-pass 0', 'full');
  assert.equal((await cli(['verify', PAIR9, '--root', ok])).status, 0);
});

test('verify: one failed candidate with exit 1 lets its passing sibling run passes two and three', async () => {
  const root = withAuthoringFiles(copyRoot());
  useRunner(root, 'verify-pair-fail1,verify-green-009,verify-green-009 attest-pass 1,0,0', 'full');
  const r = await cli(['verify', PAIR8, PAIR9, '--root', root]);
  assert.equal(r.status, 1, r.out);
  assert.match(r.stdout, /^not verified: CART-008 — failed in pass 1$/m);
  assert.match(r.stdout, /^verified: CART-009 /m);
  assert.equal(runnerCalls(root), 3);
  const rec = verifyOf(root, r);
  assert.deepEqual(rec.passes.map((p) => [...new Set(p.cases.map((c) => c.id))]), [['CART-008', 'CART-009'], ['CART-009'], ['CART-009']]);
});

test('run: an ordinary smoke run loads only the selected spec files (testMatch), so an invalid draft beside them does not break it', async () => {
  const root = withAuthoringFiles(copyRoot());
  knownBuild(root);
  useRunner(root, 'green attest-all 0');
  fs.writeFileSync(path.join(root, 'e2e/regression/cart/cart-011.spec.ts'), 'this is not TypeScript (\n');
  const r = await cli(['run', '--root', root]);
  assert.equal(r.status, 0, r.out);
  const rec = recordOf(root, r);
  const manifest = JSON.parse(fs.readFileSync(path.join(root, '.agents/regression/runs', rec.run_id, 'manifest.json'), 'utf8'));
  const { testMatch } = runnerOptions(manifest);
  assert.equal(testMatch.test(path.join(root, 'e2e/regression/cart.spec.ts')), true);
  assert.equal(testMatch.test(path.join(root, 'e2e/regression/cart/cart-011.spec.ts')), false);
  assert.equal(testMatch.test(path.join(root, 'e2e/regression/cart/cart-008.spec.ts')), false);
  assert.equal(testMatch.test(path.join(root, 'e2e/regression/_walk.spec.ts')), false);
});

test('run: a config without testMatch is refused on production with the migration hint', async () => {
  const root = copyRoot();
  useRunner(root, 'green-prod attest-all 0');
  const config = path.join(root, 'e2e/playwright.config.ts');
  fs.writeFileSync(config, fs.readFileSync(config, 'utf8').replace('  testMatch: opts.testMatch,\n', ''));
  const r = await cli(['run', '--env', 'prod', '--root', root]);
  assert.equal(r.status, 3, r.out);
  assert.match(r.stderr, /^runner not guard-integrated — e2e\/playwright\.config\.ts: does not set testMatch from runnerOptions — re-copy the templates \(regression\.md §11\)$/m);
  const t = copyRoot();
  knownBuild(t);
  useRunner(t, 'green attest-all 0');
  fs.writeFileSync(path.join(t, 'e2e/playwright.config.ts'), fs.readFileSync(config, 'utf8'));
  const w = await cli(['run', '--root', t]);
  assert.equal(w.status, 0, w.out);
  assert.match(w.stdout, /^warning: runner not guard-integrated — e2e\/playwright\.config\.ts: does not set testMatch from runnerOptions$/m);
});

test('run: the first production run still prints the same confirmation after the prepare refactor', async () => {
  const root = copyRoot();
  useRunner(root, 'green-prod attest-all 0');
  const r = await cli(['run', '--env', 'prod', '--root', root]);
  assert.equal(r.status, 3, r.out);
  const plan = buildPlan(root, readConfig(root), 'prod', 'smoke');
  const expected = [
    `target: prod (production) https://shop.example.com · mode smoke · ${plan.cases.length} cases (${plan.scenarios} scenarios)`,
    ...plan.excluded.map((e) => `not run — policy: ${e.id} — ${e.reason}`),
    confirmationText(plan),
  ].join('\n');
  assert.equal(r.stdout.replace(/^confirmation-required: [0-9a-f]{32}\n$/m, ''), `${expected}\n`);
  assert.ok(fs.existsSync(path.join(root, '.agents/regression/runs/.confirm/prod.run.json')));
});

test('a legacy confirmation token file still confirms a run', async () => {
  const root = copyRoot();
  useRunner(root, 'green-prod attest-all 0');
  const locks = fs.mkdtempSync(path.join(os.tmpdir(), 'regression-locks-'));
  const first = await cli(['run', '--env', 'prod', '--root', root], { locks });
  const dir = path.join(root, '.agents/regression/runs/.confirm');
  fs.renameSync(path.join(dir, 'prod.run.json'), path.join(dir, 'prod.json'));
  const ok = await cli(['run', '--env', 'prod', '--confirm', tokenOf(first), '--root', root], { locks });
  assert.notEqual(ok.status, 3, ok.out);
});

test('status ignores walk and verify run directories', async () => {
  const root = withAuthoringFiles(copyRoot());
  useRunner(root, 'walk-green walk-groups 0', 'full');
  assert.equal((await cli(['walk', '--routes', stagedRoutes(root, WALK_ROUTES), '--root', root])).status, 0);
  useRunner(root, 'verify-green attest-pass 0', 'full');
  assert.equal((await cli(['verify', PAIR8, '--root', root])).status, 0);
  const s = await cli(['status', '--env', 'test', '--root', root]);
  assert.equal(s.status, 0);
  assert.equal(s.stdout.trim(), 'test no run recorded on this machine');
});

// ---------------------------------------------------------------------------------------------
// The heal lane's probe and verify --heal (#334)

const HEAL_DIR = '.agents/regression/runs/heal-t';
const TITLES = { 'CART-008': 'See the cart summary', 'CART-009': 'Cart as a shopper' };
const TARGETS = {
  test: { kind: 'test', base_url: 'https://test.shop.example.com' },
  prod: { kind: 'production', base_url: 'https://shop.example.com' },
};

/** The probe critic verdict on the current probe bytes (`extra` overrides). */
function writeProbeCritic(root, heal, extra = {}) {
  const cfg = loadConfig(root).config;
  const files = catalogFiles(root, catalogSettings(cfg));
  const key = evidenceKey(root, heal.probe, lintSpec(root, cfg, heal.probe, heal.scenario).files, blockTexts(root, files).get(heal.scenario).text);
  const critic = {
    id: heal.scenario, mode: 'probe', verdict: 'pass', steps: [{ step: 1, file: heal.probe, line: 7 }],
    clauses: [{ clause: 'The heading is visible.', assertion: `${heal.probe}:8`, would_fail: true }], findings: [], ...key, ...extra,
  };
  fs.writeFileSync(path.join(root, heal.probe_critic), `${JSON.stringify(critic, null, 2)}\n`);
}

/**
 * A claimed scenario with an open heal attempt, written the way `heal.mjs start` writes it: the
 * catalog's Spec set, heal.json with the pin and the snapshot, the probe, the candidate and a
 * complete probe critic verdict. `{root, dir, heal}`.
 */
function withHealAttempt(root, { id = 'CART-008', env = 'test', extra = {} } = {}) {
  const lower = id.toLowerCase();
  const spec = `e2e/regression/cart/${lower}.spec.ts`;
  const catFile = path.join(root, CAT, 'cart.md');
  const cat = fs.readFileSync(catFile, 'utf8');
  fs.writeFileSync(catFile, cat.replace(new RegExp(`(### ${id} [\\s\\S]*?\\*\\*Spec:\\*\\* )—`), `$1${spec} › ${id} — ${TITLES[id]}`));
  const cfg = loadConfig(root).config;
  const files = catalogFiles(root, catalogSettings(cfg));
  const specText = fs.readFileSync(path.join(root, spec), 'utf8');
  const probe = `e2e/regression/_heal/${lower}.probe.spec.ts`;
  const candidate = `e2e/regression/cart/${lower}.heal.spec.ts`;
  fs.mkdirSync(path.join(root, HEAL_DIR, 'before'), { recursive: true });
  fs.mkdirSync(path.join(root, 'e2e/regression/_heal'), { recursive: true });
  fs.writeFileSync(path.join(root, HEAL_DIR, 'before', path.basename(spec)), specText);
  fs.writeFileSync(path.join(root, candidate), specText);
  fs.writeFileSync(path.join(root, probe), specText.replace(`${id} — ${TITLES[id]}`, `${id} — probe`));
  const lint = lintSpec(root, cfg, spec, id);
  const heal = {
    schema: 1, id: 'h1', scenario: id, effect: 'read', env, ...TARGETS[env], spec, title: `${id} — ${TITLES[id]}`,
    created_at: '2026-11-28T00:00:00.000Z', refresh: false, state: 'open',
    snapshot: {
      path: `before/${path.basename(spec)}`, spec_sha256: sha256(specText),
      inputs: lint.files.filter((f) => f !== spec).map((file) => ({ file, sha256: sha256(fs.readFileSync(path.join(root, file))) })),
      block_sha256: sha256(blockTexts(root, files).get(id).text),
    },
    automation: { state: 'verified', reason: '' }, candidate, probe, probe_critic: `${HEAL_DIR}/probe-critic-${id}.json`, ...extra,
  };
  fs.writeFileSync(path.join(root, HEAL_DIR, 'heal.json'), `${JSON.stringify(heal, null, 2)}\n`);
  writeProbeCritic(root, heal);
  return { root, dir: HEAL_DIR, heal };
}

/** The build-SHA stub reachable through the guard: its host on the environment's allowlist. */
function guardedBuild(root, env = 'test') {
  shaQueue = ['abc1234'];
  editConfig(root, (cfg) => {
    cfg.environments[env].build_sha_url = SHA_URL;
    cfg.environments[env].guard = { ...(cfg.environments[env].guard ?? {}), hosts: [new URL(cfg.environments[env].host).hostname, '127.0.0.1'] };
  });
}
const probeOf = (root, r) => {
  const m = /^record: (.+probe\.json)$/m.exec(r.stdout);
  assert.ok(m, `no probe record in:\n${r.out}`);
  return JSON.parse(fs.readFileSync(path.join(root, m[1]), 'utf8'));
};
const probeCli = (root, id = 'CART-008', extra = [], opts = {}) => cli(['probe', id, '--heal', HEAL_DIR, ...extra, '--root', root], opts);
const resultsOf = (pass) => Object.fromEntries(pass.cases.map((c) => [c.project, c.result]));

test('probe: runs the spec then the probe in two passes, one runner call each, and records per-project results and the heal id', async () => {
  const { root } = withHealAttempt(withAuthoringFiles(copyRoot()));
  guardedBuild(root);
  useRunner(root, 'probe-spec-failed,probe-probe-green attest-pass 1,0', 'full');
  const r = await probeCli(root);
  assert.equal(r.status, 0, r.out);
  assert.equal(runnerCalls(root), 2);
  const rec = probeOf(root, r);
  assert.equal(rec.heal_id, 'h1');
  assert.deepEqual([rec.env, rec.kind, rec.base_url], ['test', 'test', 'https://test.shop.example.com']);
  assert.match(rec.plan_digest, /^[0-9a-f]{64}$/);
  assert.deepEqual(rec.passes.map((p) => p.n), [1, 2]);
  assert.deepEqual(resultsOf(rec.passes[0]), { 'desktop-chrome': 'failed', 'mobile-safari': 'passed' });
  assert.deepEqual(resultsOf(rec.passes[1]), { 'desktop-chrome': 'passed', 'mobile-safari': 'passed' });
  assert.deepEqual(rec.passes[0].cases.map((c) => c.spec), ['e2e/regression/cart/cart-008.spec.ts', 'e2e/regression/cart/cart-008.spec.ts']);
  assert.deepEqual(rec.passes[1].cases.map((c) => c.spec), ['e2e/regression/_heal/cart-008.probe.spec.ts', 'e2e/regression/_heal/cart-008.probe.spec.ts']);
  assert.ok(rec.passes.every((p) => p.cases.every((c) => c.attempts === 1 && c.attested && c.session_ok)));
  assert.deepEqual(rec.build, { before: 'abc1234', after: 'abc1234', reason: null });
  assert.notEqual(rec.passes[0].nonce, rec.passes[1].nonce);
  const runDir = path.join(root, '.agents/regression/runs', rec.run_id);
  const m2 = JSON.parse(fs.readFileSync(path.join(runDir, 'manifest-2.json'), 'utf8'));
  assert.deepEqual([...new Set(m2.selection.map((c) => c.spec))], ['e2e/regression/_heal/cart-008.probe.spec.ts']);
  for (const n of [1, 2]) assert.ok(fs.existsSync(path.join(runDir, `report-${n}.json`)));
});

test('probe: records a guard stop, a server-error, a 500 navigation and a network failure as environment facts of the pass', async () => {
  const cases = [
    ['stop-429', 5, (f) => assert.equal(f.stop, 'status 429')],
    ['server-error-case', 0, (f) => assert.deepEqual(f.server_error, [{ url: 'https://test.shop.example.com/api/price', status: 503, case: 'CART-008/desktop-chrome' }])],
    ['nav-500-case', 0, (f) => assert.deepEqual(f.navigation_5xx, [{ url: 'https://test.shop.example.com/cart', status: 500, case: 'CART-008/desktop-chrome' }])],
    ['network-failed-case', 0, (f) => assert.deepEqual(f.network_failed, [{ method: 'GET', url: 'https://test.shop.example.com/api/price', case: 'CART-008/desktop-chrome' }])],
  ];
  for (const [events, status, check] of cases) {
    const { root } = withHealAttempt(withAuthoringFiles(copyRoot()));
    guardedBuild(root);
    useRunner(root, `probe-spec-failed,probe-probe-green ${events},attest-pass 1,0`, 'full');
    const r = await probeCli(root);
    assert.equal(r.status, status, `${events}: ${r.out}`);
    const rec = probeOf(root, r);
    check(rec.passes[0].facts);
    if (events === 'stop-429') {
      assert.deepEqual(rec.skipped, [{ n: 2, reason: 'guard stop: status 429' }]);
      assert.deepEqual(rec.build, { before: 'abc1234', after: null, reason: null, after_skipped: 'guard stop' });
    } else assert.equal(rec.passes[1].facts.server_error.length + rec.passes[1].facts.navigation_5xx.length + rec.passes[1].facts.network_failed.length, 0, events);
  }
});

test('probe: refuses without a probe critic pass on the current probe bytes, with a changed spec, or on another environment than the pinned one', async () => {
  const refusal = async (prep, re, args = []) => {
    const ctx = withHealAttempt(withAuthoringFiles(copyRoot()));
    useRunner(ctx.root, 'probe-spec-failed,probe-probe-green attest-pass 1,0', 'full');
    prep(ctx);
    const r = await probeCli(ctx.root, 'CART-008', args);
    assert.equal(r.status, 3, r.out);
    assert.match(r.stdout, re);
    assert.equal(runnerCalls(ctx.root), 0);
  };
  await refusal(({ root, heal }) => fs.rmSync(path.join(root, heal.probe_critic)), /^refused: CART-008 — no probe critic pass on the current probe$/m);
  await refusal(({ root, heal }) => fs.appendFileSync(path.join(root, heal.probe), '\n'), /^refused: CART-008 — no probe critic pass on the current probe$/m);
  await refusal(({ root, heal }) => writeProbeCritic(root, heal, { verdict: 'revise' }), /^refused: CART-008 — no probe critic pass on the current probe$/m);
  await refusal(({ root, heal }) => fs.appendFileSync(path.join(root, heal.spec), '\n'), /^refused: CART-008 — the spec \(or block\) changed since start$/m);
  await refusal(() => {}, /^refused: CART-008 — target differs from the pinned test \(test https:\/\/test\.shop\.example\.com\)$/m, ['--env', 'prod']);
  await refusal(({ root }) => editConfig(root, (cfg) => { cfg.environments.test.host = 'https://test2.shop.example.com'; }), /^refused: CART-008 — target differs from the pinned test/m);
});

test('probe: a retry, a missing attestation or missing account session on a test environment is recorded per case as unqualified evidence', async () => {
  const retry = withHealAttempt(withAuthoringFiles(copyRoot())).root;
  useRunner(retry, 'verify-retry,probe-probe-green attest-pass 0', 'full');
  const a = probeOf(retry, await probeCli(retry));
  assert.ok(a.passes[0].cases.some((c) => c.attempts !== 1 || c.retries.some((x) => x !== 0)), JSON.stringify(a.passes[0].cases));
  const unattested = withHealAttempt(withAuthoringFiles(copyRoot())).root;
  useRunner(unattested, 'probe-spec-failed,probe-probe-green attest-none,attest-pass 1,0', 'full');
  const b = probeOf(unattested, await probeCli(unattested));
  assert.deepEqual(b.passes[0].cases.map((c) => c.attested), [false, false]);
  assert.deepEqual(b.passes[0].facts.attestation, [], 'a test environment records the gap per case, not as an environment fact');
  assert.deepEqual(b.passes[1].cases.map((c) => c.attested), [true, true]);
  const session = withHealAttempt(withAuthoringFiles(copyRoot()), { id: 'CART-009' }).root;
  useRunner(session, 'verify-green-009,- session-missing,- 0', 'full');
  const c = await probeCli(session, 'CART-009');
  assert.equal(c.status, 0, c.out);
  assert.deepEqual(probeOf(session, c).passes[0].cases.map((x) => [x.result, x.session_ok]), [['passed', false], ['passed', false]]);
});

test('probe: on production prints one confirmation for both passes and refuses a token after the probe changed', async () => {
  const ctx = withHealAttempt(withAuthoringFiles(copyRoot()), { env: 'prod' });
  const { root, heal } = ctx;
  useRunner(root, 'probe-spec-failed,probe-probe-green attest-pass 1,0', 'full');
  const locks = fs.mkdtempSync(path.join(os.tmpdir(), 'regression-locks-'));
  const first = await probeCli(root, 'CART-008', ['--env', 'prod'], { locks });
  assert.equal(first.status, 3, first.out);
  assert.match(first.stdout, /^mode: probe$/m);
  assert.match(first.stdout, /^probe: 2 passes \(spec, probe\) over 2 cases \(CART-008\)$/m);
  assert.ok(fs.existsSync(path.join(root, '.agents/regression/runs/.confirm/prod.probe.json')), 'the probe has its own token lane');
  fs.appendFileSync(path.join(root, heal.probe), '\n');
  writeProbeCritic(root, heal);
  const stale = await probeCli(root, 'CART-008', ['--env', 'prod', '--confirm', tokenOf(first)], { locks });
  assert.equal(stale.status, 3, stale.out);
  assert.match(stale.stderr, /^confirmation invalid: the plan changed since the confirmation/m);
  assert.equal(runnerCalls(root), 0);
  const ok = await probeCli(root, 'CART-008', ['--env', 'prod', '--confirm', tokenOf(stale)], { locks });
  assert.equal(ok.status, 0, ok.out);
  assert.equal(runnerCalls(root), 2, 'one token, two passes');
  assert.equal(probeOf(root, ok).confirmed, true);
});

test('probe: a guard stop or an interrupted pass 1 skips pass 2', async () => {
  for (const [report, events, reason] of [['probe-spec-failed', 'stop-429', 'guard stop: status 429'], ['interrupted', 'attest-pass', 'pass 1 interrupted']]) {
    const { root } = withHealAttempt(withAuthoringFiles(copyRoot()));
    useRunner(root, `${report},probe-probe-green ${events},attest-pass 1,0`, 'full');
    const r = await probeCli(root);
    assert.equal(runnerCalls(root), 1, `${report}: ${r.out}`);
    assert.match(r.stdout, new RegExp(`^not run: pass 2 — ${reason}$`, 'm'));
    assert.deepEqual(probeOf(root, r).skipped, [{ n: 2, reason }]);
  }
});

test('probe: a guard stop on a build read runs no pass after it, records the stop and exits 5', async () => {
  const opening = withHealAttempt(withAuthoringFiles(copyRoot())).root;
  guardedBuild(opening);
  shaQueue = [{ status: 429 }];
  useRunner(opening, 'probe-spec-failed,probe-probe-green attest-pass 1,0', 'full');
  const a = await probeCli(opening);
  assert.equal(a.status, 5, a.out);
  assert.equal(runnerCalls(opening), 0, a.out);
  const ra = probeOf(opening, a);
  assert.equal(ra.build.stop, 'status 429');
  assert.deepEqual(ra.skipped.map((s) => s.reason), ['guard stop: status 429', 'guard stop: status 429']);
  const closing = withHealAttempt(withAuthoringFiles(copyRoot())).root;
  guardedBuild(closing);
  shaQueue = ['abc1234', { status: 429 }];
  useRunner(closing, 'probe-spec-failed,probe-probe-green attest-pass 1,0', 'full');
  const c = await probeCli(closing);
  assert.equal(c.status, 5, c.out);
  assert.equal(runnerCalls(closing), 2, c.out);
  const rc = probeOf(closing, c);
  assert.deepEqual([rc.build.before, rc.build.after, rc.build.stop], ['abc1234', null, 'status 429']);
});

test('probe: refuses a lint violation in the claimed spec\'s helper and a probe critic verdict without clauses, before any token or runner call', async () => {
  const root = withAuthoringFiles(copyRoot());
  const spec = path.join(root, 'e2e/regression/cart/cart-008.spec.ts');
  fs.writeFileSync(path.join(root, 'e2e/regression/cart/helper.ts'), "export const price = () => fetch('/api/price');\n");
  fs.writeFileSync(spec, fs.readFileSync(spec, 'utf8').replace("import { test, expect } from '../../fixtures';", "import { test, expect } from '../../fixtures';\nimport { price } from './helper';"));
  withHealAttempt(root, { env: 'prod' });
  useRunner(root, 'probe-spec-failed,probe-probe-green attest-pass 1,0', 'full');
  const a = await probeCli(root, 'CART-008', ['--env', 'prod']);
  assert.equal(a.status, 3, a.out);
  assert.match(a.stdout, /^refused: CART-008 — lint: e2e\/regression\/cart\/helper\.ts:1: forbidden fetch\($/m);
  const b = withHealAttempt(withAuthoringFiles(copyRoot()), { env: 'prod' });
  writeProbeCritic(b.root, b.heal, { clauses: [] });
  useRunner(b.root, 'probe-spec-failed,probe-probe-green attest-pass 1,0', 'full');
  const r = await probeCli(b.root, 'CART-008', ['--env', 'prod']);
  assert.equal(r.status, 3, r.out);
  assert.match(r.stdout, /^refused: CART-008 — the probe critic verdict has no clauses$/m);
  for (const x of [root, b.root]) {
    assert.equal(runnerCalls(x), 0);
    assert.ok(!fs.existsSync(path.join(x, '.agents/regression/runs/.confirm/prod.probe.json')), 'no token issued');
  }
});

test('verify --heal: verifies the candidate of a claimed scenario and writes heal_id; without --heal the scenario is refused as already having a spec', async () => {
  const { root, heal } = withHealAttempt(withAuthoringFiles(copyRoot()), { extra: { class: 'TEST' } });
  useRunner(root, 'verify-candidate-green attest-pass 0', 'full');
  const pair = `CART-008=${heal.candidate}`;
  const plain = await cli(['verify', pair, '--root', root]);
  assert.equal(plain.status, 3, plain.out);
  assert.match(plain.stdout, /^refused: CART-008 — already has a spec$/m);
  const other = await cli(['verify', 'CART-008=e2e/regression/cart/cart-008.spec.ts', '--heal', HEAL_DIR, '--root', root]);
  assert.equal(other.status, 3, other.out);
  assert.match(other.stdout, /^refused: CART-008 — not the candidate of heal attempt h1/m);
  assert.equal(runnerCalls(root), 0);
  const r = await cli(['verify', pair, '--heal', HEAL_DIR, '--root', root]);
  assert.equal(r.status, 0, r.out);
  const rec = verifyOf(root, r);
  assert.equal(rec.heal_id, 'h1');
  assert.deepEqual(rec.scenarios.map((s) => [s.id, s.spec, s.qualified]), [['CART-008', heal.candidate, true]]);
});
