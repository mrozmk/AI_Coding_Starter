// Unit and end-to-end tests of the heal lane (.claude/lib/regression/heal.mjs with run.mjs probe and
// verify --heal): select, start and its stale rules, the probe's classification (APP, TEST, env,
// the stops), apply behind weaken-check + a heal verify + a critic, discard, refresh, and the
// guarantees (no catalog write, no team clone). End to end on temp copies of the run fixture root
// with the fake runner and a loopback build-SHA stub; the stale and refusal cases on
// fixtures/regression/heal. REGRESSION_LOCK_DIR in a temp dir — never the real ~.
import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import http from 'node:http';
import { createHash } from 'node:crypto';
import { spawn, spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

import { loadConfig, catalogSettings } from '../regression/config.mjs';
import { blockTexts, catalogFiles, parseCatalog, staleRule, automationState } from '../regression/catalog.mjs';
import { evidenceKey } from '../regression/policy.mjs';
import { lintSpec } from '../regression/speclint.mjs';
import { classifyProbe } from '../regression/heal.mjs';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const HEAL = path.join(HERE, '../regression/heal.mjs');
const RUN = path.join(HERE, '../regression/run.mjs');
const RUN_FIX = path.join(HERE, 'fixtures/regression/run');
const HEAL_FIX = path.join(HERE, 'fixtures/regression/heal');
const FAKE = path.join(RUN_FIX, 'fake-runner.mjs');
const CAT = '.agents/regression/scenarios';
const SPEC8 = 'e2e/regression/cart/cart-008.spec.ts';
const CAND8 = 'e2e/regression/cart/cart-008.heal.spec.ts';
const PROBE8 = 'e2e/regression/_heal/cart-008.probe.spec.ts';
const BOTH = ['desktop-chrome', 'mobile-safari'];
const sha256 = (b) => createHash('sha256').update(b).digest('hex');

// ---------------------------------------------------------------------------------------------
// Helpers

let shaServer;
let SHA_URL = '';
before(async () => {
  shaServer = http.createServer((req, res) => { res.writeHead(200, { 'content-type': 'application/json' }); res.end(JSON.stringify({ sha: 'abc1234' })); });
  await new Promise((r) => shaServer.listen(0, '127.0.0.1', r));
  SHA_URL = `http://127.0.0.1:${shaServer.address().port}/version`;
});
after(() => shaServer.close());

function setup(from) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'regression-heal-'));
  fs.cpSync(from, root, { recursive: true });
  return { root, locks: fs.mkdtempSync(path.join(os.tmpdir(), 'regression-locks-')) };
}
const read = (ctx, rel) => fs.readFileSync(path.join(ctx.root, rel), 'utf8');
const write = (ctx, rel, text) => { fs.mkdirSync(path.dirname(path.join(ctx.root, rel)), { recursive: true }); fs.writeFileSync(path.join(ctx.root, rel), text); };
const writeJson = (ctx, rel, v) => write(ctx, rel, `${JSON.stringify(v, null, 2)}\n`);
const exists = (ctx, rel) => fs.existsSync(path.join(ctx.root, rel));
function editConfig(ctx, fn) {
  const file = path.join(ctx.root, '.claude/regression.json');
  const cfg = JSON.parse(fs.readFileSync(file, 'utf8'));
  fn(cfg);
  fs.writeFileSync(file, `${JSON.stringify(cfg, null, 2)}\n`);
}
const useRunner = (ctx, args) => editConfig(ctx, (cfg) => { cfg.runner.commands.full = `"${process.execPath}" "${FAKE}" ${args}`; });
const runnerCalls = (ctx) => (exists(ctx, 'runner-calls.log') ? read(ctx, 'runner-calls.log').split('\n').filter(Boolean).length : 0);

/** heal.mjs, synchronously (it reaches no network). */
function heal(ctx, ...args) {
  const r = spawnSync(process.execPath, [HEAL, ...args, '--root', ctx.root], { encoding: 'utf8', env: { ...process.env, REGRESSION_LOCK_DIR: ctx.locks, ...(ctx.env ?? {}) } });
  return { ...r, out: r.stdout + r.stderr };
}
/** run.mjs, asynchronously (the build-SHA stub answers from this process). */
function run(ctx, args) {
  return new Promise((resolve) => {
    const child = spawn(process.execPath, [RUN, ...args, '--root', ctx.root], { env: { ...process.env, REGRESSION_LOCK_DIR: ctx.locks } });
    let stdout = '';
    let stderr = '';
    child.stdout.on('data', (d) => { stdout += d; });
    child.stderr.on('data', (d) => { stderr += d; });
    child.on('close', (status) => resolve({ status, stdout, stderr, out: stdout + stderr }));
  });
}
const has = (r, re) => assert.match(r.stdout, re, r.out);
const healDirOf = (r) => { const m = /^heal: (\S+)$/m.exec(r.stdout); assert.ok(m, r.out); return m[1]; };
const recordDir = (r, name) => { const m = new RegExp(`^record: (\\S+)/${name}$`, 'm').exec(r.stdout); assert.ok(m, r.out); return m[1]; };
const healJson = (ctx, dir) => JSON.parse(read(ctx, `${dir}/heal.json`));

/** A temp copy of the run fixture root plus the authoring files, CART-008 claimed, the build SHA reachable through the guard. */
function e2e({ claim9 = false } = {}) {
  const ctx = setup(path.join(RUN_FIX, 'root'));
  const cat = path.join(ctx.root, CAT, 'cart.md');
  fs.appendFileSync(cat, fs.readFileSync(path.join(RUN_FIX, 'authoring/cart-append.md'), 'utf8'));
  fs.cpSync(path.join(RUN_FIX, 'authoring/e2e'), path.join(ctx.root, 'e2e'), { recursive: true });
  let text = fs.readFileSync(cat, 'utf8').replace(/(### CART-008 [\s\S]*?\*\*Spec:\*\* )—/, `$1${SPEC8} › CART-008 — See the cart summary`);
  if (claim9) text = text.replace(/(### CART-009 [\s\S]*?\*\*Spec:\*\* )—/, '$1e2e/regression/cart/cart-009.spec.ts › CART-009 — Cart as a shopper');
  fs.writeFileSync(cat, text);
  editConfig(ctx, (cfg) => {
    cfg.environments.test.build_sha_url = SHA_URL;
    cfg.environments.test.guard = { hosts: ['test.shop.example.com', '127.0.0.1'] };
  });
  return ctx;
}

function keyOf(ctx, id, spec) {
  const cfg = loadConfig(ctx.root).config;
  const files = catalogFiles(ctx.root, catalogSettings(cfg));
  return evidenceKey(ctx.root, spec, lintSpec(ctx.root, cfg, spec, id).files, blockTexts(ctx.root, files).get(id).text);
}

/** start → the probe written → probe-key → a probe critic pass. `{dir, heal}`. */
function startWithProbe(ctx, id = 'CART-008') {
  const s = heal(ctx, 'start', id, '--env', 'test');
  assert.equal(s.status, 0, s.out);
  const dir = healDirOf(s);
  const h = healJson(ctx, dir);
  write(ctx, h.probe, read(ctx, h.spec).replace(/test\('CART-008 — [^']*'/, "test('CART-008 — probe'"));
  const k = heal(ctx, 'probe-key', id, '--run', dir);
  assert.equal(k.status, 0, k.out);
  const m = /^probe-key: \S+ spec_sha256=(\w+) inputs_sha256=(\w+) block_sha256=(\w+)$/m.exec(k.stdout);
  assert.deepEqual([m[1], m[2], m[3]], Object.values(keyOf(ctx, id, h.probe)), 'probe-key prints the evidence key the run re-checks');
  writeJson(ctx, h.probe_critic, {
    id, mode: 'probe', verdict: 'pass', spec_sha256: m[1], inputs_sha256: m[2], block_sha256: m[3],
    steps: [{ step: 1, file: h.probe, line: 7 }], clauses: [{ clause: 'The summary heading is visible.', assertion: `${h.probe}:8`, would_fail: true }], findings: [],
  });
  return { dir, heal: h };
}

/** start → probe run with `runner` → classify. `{dir, probeDir, c}` (c = the classify result). */
async function probeAndClassify(ctx, runner) {
  const { dir } = startWithProbe(ctx);
  useRunner(ctx, runner);
  const p = await run(ctx, ['probe', 'CART-008', '--heal', dir]);
  assert.ok([0, 5].includes(p.status), p.out);
  const probeDir = recordDir(p, 'probe.json');
  return { dir, probeDir, c: heal(ctx, 'classify', 'CART-008', '--run', dir, '--probe', probeDir) };
}

/** A heal verify of the attempt's candidate. Its run directory. */
async function healVerify(ctx, dir, h) {
  useRunner(ctx, 'verify-candidate-green attest-pass 0');
  const v = await run(ctx, ['verify', `CART-008=${h.candidate}`, '--heal', dir]);
  assert.equal(v.status, 0, v.out);
  return recordDir(v, 'verify.json');
}
function writeHealCritic(ctx, dir, h, extra = {}) {
  const file = `${dir}/critic-CART-008.json`;
  writeJson(ctx, file, {
    id: 'CART-008', mode: 'heal', heal_id: h.id, before_sha256: h.snapshot.spec_sha256, verdict: 'pass', ...keyOf(ctx, 'CART-008', h.candidate),
    clauses: [{ clause: 'The summary heading is visible.', assertion: `${h.candidate}:8`, would_fail: true }], findings: [], ...extra,
  });
  return file;
}
const retarget = (ctx, h) => write(ctx, h.candidate, read(ctx, h.candidate).replace("getByRole('heading', { name: 'Summary' })", "getByRole('heading', { name: 'Summary', level: 2 })"));

/** A probe record for classifyProbe: per pass `{project: result}` maps, facts and build overrides. */
function probeRecord({ spec, probe, facts1 = {}, facts2 = {}, build = { before: 'abc1234', after: 'abc1234', reason: null }, skipped = [] }) {
  const cases = (n, results) => Object.entries(results).map(([project, result]) => ({ id: 'CART-008', project, result, attempts: 1, retries: [0], attested: true, session_ok: true, attachments: [] }));
  const facts = (f) => ({ stop: null, server_error: [], navigation_5xx: [], network_failed: [], blocked: [], whole: [], attestation: [], ...f });
  const passes = [{ n: 1, cases: cases(1, spec), facts: facts(facts1) }];
  if (probe) passes.push({ n: 2, cases: cases(2, probe), facts: facts(facts2) });
  return { heal_id: 'h', build, passes, skipped };
}
const READ = { scenario: 'CART-008', effect: 'read' };

// ---------------------------------------------------------------------------------------------
// select

test('select: --run lists the failed scenarios of a RED record; a BLOCKED/ENV record classifies verified ones env and selects nothing', () => {
  const ctx = e2e();
  writeJson(ctx, '.agents/regression/runs/test-red/record.json', { schema: 1, env: 'test', kind: 'test', base_url: 'https://test.shop.example.com', verdict: 'RED', reasons: ['failed: CART-008/desktop-chrome'], cases: [{ id: 'CART-008', project: 'desktop-chrome', result: 'failed' }, { id: 'CART-001', project: 'desktop-chrome', result: 'passed' }] });
  const r = heal(ctx, 'select', '--run', 'test-red');
  assert.equal(r.status, 0, r.out);
  has(r, /^eligible: CART-008 e2e\/regression\/cart\/cart-008\.spec\.ts$/m);
  has(r, /^env: test$/m);
  assert.doesNotMatch(r.stdout, /CART-001/);
  writeJson(ctx, '.agents/regression/runs/test-blocked/record.json', { schema: 1, env: 'test', verdict: 'BLOCKED/ENV', reasons: ['guard stop: status 429'], cases: [{ id: 'CART-008', project: 'desktop-chrome', result: 'failed' }] });
  const b = heal(ctx, 'select', '--run', 'test-blocked');
  assert.equal(b.status, 1, b.out);
  has(b, /^env: CART-008 — the run was BLOCKED\/ENV: guard stop: status 429$/m);
  assert.doesNotMatch(b.stdout, /^eligible:/m);
  writeJson(ctx, '.agents/regression/runs/test-green/record.json', { schema: 1, env: 'test', verdict: 'GREEN', cases: [] });
  has(heal(ctx, 'select', '--run', 'test-green'), /^nothing to heal — test-green is GREEN$/m);
  const none = heal(ctx, 'select', '--run', 'nope');
  assert.equal(none.status, 1);
  has(none, /^refused: record not found — nope$/m);
});

test('select: the spec form matches the Spec field, the title narrows it, and a multi-test file is refused', () => {
  const ctx = setup(HEAL_FIX);
  const one = heal(ctx, 'select', 'e2e/regression/cart/cart-021.spec.ts');
  assert.equal(one.status, 0, one.out);
  has(one, /^eligible: CART-021 e2e\/regression\/cart\/cart-021\.spec\.ts$/m);
  const multi = heal(ctx, 'select', 'e2e/regression/cart/cart-024.spec.ts');
  assert.equal(multi.status, 1, multi.out);
  has(multi, /^refused: CART-024 — 2 tests — heal needs one test per file$/m);
  has(multi, /^refused: CART-025 — 2 tests — heal needs one test per file$/m);
  const narrow = heal(ctx, 'select', 'e2e/regression/cart/cart-024.spec.ts', '›', 'CART-025', '—', 'Restore', 'a', 'line');
  has(narrow, /^refused: CART-025 — 2 tests/m);
  assert.doesNotMatch(narrow.stdout, /CART-024/);
  has(heal(ctx, 'select', 'e2e/regression/cart/absent.spec.ts'), /^refused: no scenario cites e2e\/regression\/cart\/absent\.spec\.ts$/m);
});

// ---------------------------------------------------------------------------------------------
// start

test('start: pins the attempt, snapshots the spec and creates the probe and candidate targets exclusively', () => {
  const ctx = e2e();
  const specBytes = read(ctx, SPEC8);
  const r = heal(ctx, 'start', 'CART-008', '--env', 'test');
  assert.equal(r.status, 0, r.out);
  has(r, new RegExp(`^probe: ${PROBE8}$`, 'm'));
  has(r, new RegExp(`^candidate: ${CAND8}$`, 'm'));
  const dir = healDirOf(r);
  assert.match(dir, /^\.agents\/regression\/runs\/heal-\d{8}T\d{6}Z-[0-9a-f]{4}$/);
  const h = healJson(ctx, dir);
  assert.deepEqual([h.schema, h.scenario, h.env, h.kind, h.base_url, h.spec, h.title, h.state, h.refresh, h.effect], [1, 'CART-008', 'test', 'test', 'https://test.shop.example.com', SPEC8, 'CART-008 — See the cart summary', 'open', false, 'read']);
  assert.match(h.id, /^[0-9a-f]{16}$/);
  assert.equal(h.snapshot.spec_sha256, sha256(specBytes));
  assert.equal(read(ctx, `${dir}/${h.snapshot.path}`), specBytes);
  assert.deepEqual(h.snapshot.inputs.map((i) => i.file), ['e2e/fixtures.ts']);
  assert.equal(h.snapshot.block_sha256, sha256(blockTexts(ctx.root, catalogFiles(ctx.root, catalogSettings(loadConfig(ctx.root).config))).get('CART-008').text));
  assert.deepEqual([h.candidate, h.probe, h.probe_critic], [CAND8, PROBE8, `${dir}/probe-critic-CART-008.json`]);
  assert.equal(read(ctx, CAND8), specBytes, 'the candidate starts as a byte copy');
  assert.equal(read(ctx, PROBE8), '', 'the probe starts empty');
  assert.equal(read(ctx, SPEC8), specBytes, 'the claimed spec is untouched');
  const again = heal(ctx, 'start', 'CART-008', '--env', 'test');
  assert.equal(again.status, 1, again.out);
  has(again, new RegExp(`^refused: CART-008 — heal open in ${dir.replace(/\./g, '\\.')} — discard it first$`, 'm'));
  assert.equal(heal(ctx, 'discard', 'CART-008', '--run', dir).status, 0);
  write(ctx, CAND8, 'someone else');
  const taken = heal(ctx, 'start', 'CART-008', '--env', 'test');
  assert.equal(taken.status, 1, taken.out);
  has(taken, new RegExp(`^refused: CART-008 — target exists — ${CAND8.replace(/\./g, '\\.')}$`, 'm'));
  assert.equal(read(ctx, CAND8), 'someone else');
});

test('start: decides catalog-outdated, refresh needed and inconclusive for a stale scenario with no traffic', () => {
  const b = { id: 'CART-030', fields: { Source: { value: 'E1-1.AC1 [aaaaaa]' } } };
  const verified = { state: 'verified', reason: '' };
  assert.deepEqual(staleRule(b, verified, { fingerprint: () => ({ fp: 'aaaaaa' }) }), null);
  assert.equal(staleRule(b, verified, { fingerprint: () => ({ fp: 'bbbbbb' }) }).rule, 'catalog-outdated', 'a current header beside an outdated catalog citation');
  const noHeader = { state: 'stale', reason: 'no // regression: header for CART-030 in x.spec.ts' };
  assert.equal(staleRule(b, noHeader, { fingerprint: () => ({ error: 'criterion E1-1.AC1 withdrawn' }) }).rule, 'catalog-outdated', 'the catalog is judged before the missing header');
  assert.equal(staleRule(b, noHeader, { fingerprint: () => ({ error: 'criterion E1-1.AC1 no longer found — Task E1-1 absent' }) }).rule, 'catalog-outdated');
  assert.equal(staleRule(b, noHeader, { fingerprint: () => ({ fp: 'aaaaaa' }) }).rule, 'refresh needed');
  assert.equal(staleRule(b, { state: 'stale', reason: 'E1-1.AC1: header fingerprint [cccccc] differs from the current criterion [aaaaaa]' }, { fingerprint: () => ({ fp: 'aaaaaa' }) }).rule, 'refresh needed');
  assert.equal(staleRule(b, verified, { fingerprint: () => ({ error: 'fingerprint unavailable — the §7c block failed under bash' }) }).rule, 'inconclusive');
  assert.equal(staleRule(b, { state: 'stale', reason: 'spec file x unreadable (EACCES)' }, { fingerprint: () => ({ fp: 'aaaaaa' }) }).rule, 'inconclusive');
  const live = { id: 'CART-031', fields: { Source: { value: 'live' } } };
  assert.equal(staleRule(live, { state: 'stale', reason: 'header source (code) differs from the catalog Source (live)' }, { fingerprint: () => assert.fail('no criterion to resolve') }).rule, 'refresh needed');

  const ctx = setup(HEAL_FIX);
  const refresh = heal(ctx, 'start', 'CART-022', '--env', 'test');
  assert.equal(refresh.status, 1, refresh.out);
  has(refresh, /^stop: refresh needed — header source \(code\) differs from the catalog Source \(live\) — \/regression-tests author --refresh CART-022$/m);
  const h = healJson(ctx, healDirOf(refresh));
  assert.deepEqual([h.state, h.stop, h.candidate, h.probe], ['closed', 'refresh needed', null, null]);
  const unknown = heal(ctx, 'start', 'CART-023', '--env', 'test');
  assert.equal(unknown.status, 1, unknown.out);
  has(unknown, /^stop: inconclusive — criterion E1-1\.AC1 not resolvable — no current-format \.agents\/backlog\.md$/m);
  assert.ok(!exists(ctx, 'e2e/regression/cart/cart-022.heal.spec.ts') && !exists(ctx, 'e2e/regression/_heal'), 'a stale scenario gets no target');
  assert.equal(runnerCalls(ctx), 0, 'no traffic');
});

test('start: refuses a runner config without testMatch and leaves no target behind; two starts of different scenarios in one second get distinct heal directories', () => {
  const ctx = e2e({ claim9: true });
  const config = path.join(ctx.root, 'e2e/playwright.config.ts');
  const original = fs.readFileSync(config, 'utf8');
  fs.writeFileSync(config, original.replace('  testMatch: opts.testMatch,\n', ''));
  const r = heal(ctx, 'start', 'CART-008', '--env', 'test');
  assert.equal(r.status, 1, r.out);
  has(r, /^refused: CART-008 — runner not guard-integrated — e2e\/playwright\.config\.ts: does not set testMatch from runnerOptions/m);
  assert.ok(!exists(ctx, CAND8) && !exists(ctx, 'e2e/regression/_heal'), 'no target behind');
  const runs = path.join(ctx.root, '.agents/regression/runs');
  assert.ok(!fs.existsSync(runs) || !fs.readdirSync(runs).some((d) => d.startsWith('heal-')), 'no heal directory');
  fs.writeFileSync(config, original);
  ctx.env = { REGRESSION_NOW: '2026-11-28T08:00:00.000Z' };
  const a = healDirOf(heal(ctx, 'start', 'CART-008', '--env', 'test'));
  const b = healDirOf(heal(ctx, 'start', 'CART-009', '--env', 'test'));
  assert.notEqual(a, b);
  assert.equal(a.replace(/-[0-9a-f]{4}$/, ''), b.replace(/-[0-9a-f]{4}$/, ''), 'the same stamp');
});

test('start --from-run: refuses a host changed since the red record, a scenario that did not fail there, and a spec with a screenshot assertion', () => {
  const ctx = e2e();
  const red = { schema: 1, env: 'test', kind: 'test', base_url: 'https://test.shop.example.com', verdict: 'RED', cases: [{ id: 'CART-008', project: 'desktop-chrome', result: 'failed' }] };
  writeJson(ctx, '.agents/regression/runs/test-red/record.json', red);
  writeJson(ctx, '.agents/regression/runs/test-other/record.json', { ...red, cases: [{ id: 'CART-001', project: 'desktop-chrome', result: 'failed' }] });
  editConfig(ctx, (cfg) => { cfg.environments.test.host = 'https://test2.shop.example.com'; });
  const host = heal(ctx, 'start', 'CART-008', '--env', 'test', '--from-run', 'test-red');
  assert.equal(host.status, 1, host.out);
  has(host, /^refused: CART-008 — the target changed since test-red \(test test https:\/\/test\.shop\.example\.com → test test https:\/\/test2\.shop\.example\.com\)$/m);
  editConfig(ctx, (cfg) => { cfg.environments.test.host = 'https://test.shop.example.com'; });
  has(heal(ctx, 'start', 'CART-008', '--env', 'test', '--from-run', 'test-other'), /^refused: CART-008 — did not fail in test-other$/m);
  const pinned = heal(ctx, 'start', 'CART-008', '--env', 'test', '--from-run', 'test-red');
  assert.equal(pinned.status, 0, pinned.out);
  const dir = healDirOf(pinned);
  assert.equal(healJson(ctx, dir).source_run, 'test-red');
  heal(ctx, 'discard', 'CART-008', '--run', dir);
  write(ctx, SPEC8, read(ctx, SPEC8).replace("  await page.goto('/cart');", "  await page.goto('/cart');\n  await expect(page).toHaveScreenshot('cart.png');"));
  const shot = heal(ctx, 'start', 'CART-008', '--env', 'test', '--from-run', 'test-red');
  assert.equal(shot.status, 1, shot.out);
  has(shot, /^refused: CART-008 — e2e\/regression\/cart\/cart-008\.spec\.ts asserts a screenshot — the visual lane owns those$/m);
  for (const [p, why] of [[CAND8, 'candidate'], [PROBE8, 'probe']]) assert.ok(!exists(ctx, p), `no ${why} left behind`);
});

// ---------------------------------------------------------------------------------------------
// classify

test('classify: APP when spec and probe fail on the same project', async () => {
  const ctx = e2e();
  const specBytes = read(ctx, SPEC8);
  const { dir, c } = await probeAndClassify(ctx, 'probe-spec-failed,probe-probe-failed attest-pass 1');
  assert.equal(c.status, 1, c.out);
  has(c, /^class: APP — the claimed spec and the probe failed on desktop-chrome$/m);
  const bug = /^bug candidate: (\S+)$/m.exec(c.stdout)[1];
  assert.equal(bug, `${dir}/bug-CART-008.md`);
  const text = read(ctx, bug);
  assert.match(text, /^The summary heading is visible\.$/m, 'Expected verbatim');
  assert.match(text, /^Reproduced twice on desktop-chrome: the claimed spec and an independent probe\.$/m);
  assert.match(text, /^- Build: abc1234$/m);
  const h = healJson(ctx, dir);
  assert.deepEqual([h.state, h.class], ['closed', 'APP']);
  assert.ok(!exists(ctx, CAND8) && exists(ctx, `${dir}/discarded/cart-008.heal.spec.ts`), 'APP produces no diff');
  assert.equal(read(ctx, SPEC8), specBytes);
});

test('classify: TEST when the spec fails and the probe passes on every project', async () => {
  const ctx = e2e();
  const { dir, probeDir, c } = await probeAndClassify(ctx, 'probe-spec-failed,probe-probe-green attest-pass 1,0');
  assert.equal(c.status, 0, c.out);
  has(c, /^class: TEST — the claimed spec failed on desktop-chrome; the probe passed on every project$/m);
  const h = healJson(ctx, dir);
  assert.deepEqual([h.state, h.class, h.probe_run, h.probe], ['open', 'TEST', probeDir, `${dir}/probe/cart-008.probe.spec.ts`]);
  assert.ok(!exists(ctx, PROBE8), 'the probe leaves the spec directory');
  assert.ok(exists(ctx, CAND8), 'the candidate stays for the repair');
  const unit = classifyProbe({ probe: probeRecord({ spec: { 'desktop-chrome': 'failed', 'mobile-safari': 'failed' }, probe: { 'desktop-chrome': 'passed', 'mobile-safari': 'passed' } }), heal: READ, projects: BOTH });
  assert.equal(unit.class, 'TEST');
});

test('classify: env on a guard stop, a server-error, a 500 navigation or a network failure', async () => {
  const cases = [
    ['stop-429', /^class: env — guard stop: status 429$/m],
    ['server-error-case', /^class: env — server error 503 https:\/\/test\.shop\.example\.com\/api\/price \(CART-008\/desktop-chrome\)$/m],
    ['nav-500-case', /^class: env — navigation 500 https:\/\/test\.shop\.example\.com\/cart \(CART-008\/desktop-chrome\)$/m],
    ['network-failed-case', /^class: env — network failure GET https:\/\/test\.shop\.example\.com\/api\/price \(CART-008\/desktop-chrome\)$/m],
  ];
  for (const [events, re] of cases) {
    const ctx = e2e();
    const { dir, c } = await probeAndClassify(ctx, `probe-spec-failed,probe-probe-green ${events},attest-pass 1,0`);
    assert.equal(c.status, 1, `${events}: ${c.out}`);
    has(c, re);
    assert.deepEqual([healJson(ctx, dir).state, healJson(ctx, dir).class], ['closed', 'env'], events);
    assert.ok(!exists(ctx, CAND8), `${events}: env is blocked, never a repair`);
  }
  const noBuild = classifyProbe({ probe: probeRecord({ spec: { 'desktop-chrome': 'failed' }, probe: { 'desktop-chrome': 'passed' }, build: { before: null, after: null, reason: 'no build_sha_url' } }), heal: READ, projects: ['desktop-chrome'] });
  assert.deepEqual(noBuild, { class: 'env', evidence: ['deployed build unknown (no build_sha_url)'] });
  const moved = classifyProbe({ probe: probeRecord({ spec: { 'desktop-chrome': 'failed' }, probe: { 'desktop-chrome': 'passed' }, build: { before: 'a1b2c3d', after: 'e4f5a6b', reason: null } }), heal: READ, projects: ['desktop-chrome'] });
  assert.equal(moved.class, 'env');
});

test('classify: inconclusive on a crossed desktop/mobile pairing, a skipped case, a blocked event, or pass 2 not run', async () => {
  const cases = [
    ['probe-spec-failed,probe-probe-failed-mobile attest-pass 1', /^stop: inconclusive — crossed pairing — spec failed on desktop-chrome, probe failed on mobile-safari$/m],
    ['probe-spec-skipped,probe-probe-green attest-pass 1,0', /^stop: inconclusive — spec skipped on desktop-chrome$/m],
    ['probe-spec-failed,probe-probe-green blocked-case,attest-pass 1,0', /^stop: inconclusive — guard aborted GET https:\/\/foreign\.example\.net\/x$/m],
  ];
  for (const [runner, re] of cases) {
    const ctx = e2e();
    const { dir, c } = await probeAndClassify(ctx, runner);
    assert.equal(c.status, 1, `${runner}: ${c.out}`);
    has(c, re);
    assert.deepEqual([healJson(ctx, dir).state, healJson(ctx, dir).stop], ['closed', 'inconclusive']);
  }
  const noPass2 = classifyProbe({ probe: probeRecord({ spec: { 'desktop-chrome': 'failed' }, probe: null, skipped: [{ n: 2, reason: 'operator cancelled' }] }), heal: READ, projects: ['desktop-chrome'] });
  assert.deepEqual(noPass2, { stop: 'inconclusive', evidence: ['pass 2 not run — operator cancelled'] });
  const unqualified = probeRecord({ spec: { 'desktop-chrome': 'failed' }, probe: { 'desktop-chrome': 'passed' } });
  unqualified.passes[1].cases[0].attested = false;
  assert.deepEqual(classifyProbe({ probe: unqualified, heal: READ, projects: ['desktop-chrome'] }), { stop: 'inconclusive', evidence: ['unqualified evidence: pass 2 CART-008/desktop-chrome'] });
});

test('classify: not reproduced when the spec passes everywhere, with the weak-spec note when the probe failed', async () => {
  const ctx = e2e();
  const { dir, c } = await probeAndClassify(ctx, 'probe-spec-green,probe-probe-failed attest-pass 0,1');
  assert.equal(c.status, 1, c.out);
  has(c, /^stop: not reproduced — the claimed spec passed on every project$/m);
  has(c, /^evidence: the spec may assert too little on desktop-chrome$/m);
  assert.equal(healJson(ctx, dir).state, 'closed');
});

test('classify: refuses a probe record of another attempt or environment, and a spec changed since start', async () => {
  const ctx = e2e();
  const { dir } = startWithProbe(ctx);
  useRunner(ctx, 'probe-spec-failed,probe-probe-green attest-pass 1,0');
  const probeDir = recordDir(await run(ctx, ['probe', 'CART-008', '--heal', dir]), 'probe.json');
  const file = `${probeDir}/probe.json`;
  const original = read(ctx, file);
  const classify = () => heal(ctx, 'classify', 'CART-008', '--run', dir, '--probe', probeDir);
  for (const edit of [{ heal_id: 'another' }, { env: 'prod' }, { base_url: 'https://elsewhere.example.com' }, { plan_digest: '0'.repeat(64) }]) {
    writeJson(ctx, file, { ...JSON.parse(original), ...edit });
    const r = classify();
    assert.equal(r.status, 1, r.out);
    has(r, /^refused: CART-008 — probe record of another attempt, environment or plan$/m);
  }
  write(ctx, file, original);
  write(ctx, SPEC8, `${read(ctx, SPEC8)}\n`);
  const changed = classify();
  assert.equal(changed.status, 1, changed.out);
  has(changed, /^refused: CART-008 — the spec changed since start \(spec\) — the live check precedes any diff$/m);
  assert.equal(healJson(ctx, dir).state, 'open', 'a refusal classifies nothing');
});

test('classify: a write scenario whose probe passes after a failed spec is inconclusive; a block edit after start refuses classify and apply', async () => {
  const write1 = classifyProbe({ probe: probeRecord({ spec: { 'desktop-chrome': 'failed' }, probe: { 'desktop-chrome': 'passed' } }), heal: { scenario: 'CART-010', effect: 'write' }, projects: ['desktop-chrome'] });
  assert.deepEqual(write1, { stop: 'inconclusive', evidence: ['state may have changed between passes (a write scenario)'] });
  const editBlock = (ctx) => write(ctx, `${CAT}/cart.md`, read(ctx, `${CAT}/cart.md`).replace('- **Goal:** See the cart summary.', '- **Goal:** See the whole cart summary.'));
  const a = e2e();
  const { dir } = startWithProbe(a);
  useRunner(a, 'probe-spec-failed,probe-probe-green attest-pass 1,0');
  const probeDir = recordDir(await run(a, ['probe', 'CART-008', '--heal', dir]), 'probe.json');
  editBlock(a);
  const c = heal(a, 'classify', 'CART-008', '--run', dir, '--probe', probeDir);
  assert.equal(c.status, 1, c.out);
  has(c, /^refused: CART-008 — the spec changed since start \(block\)/m);
  const b = e2e();
  const t = await probeAndClassify(b, 'probe-spec-failed,probe-probe-green attest-pass 1,0');
  assert.equal(t.c.status, 0, t.c.out);
  editBlock(b);
  const ap = heal(b, 'apply', 'CART-008', '--run', t.dir, '--verify', t.dir, '--critic', `${t.dir}/none.json`);
  assert.equal(ap.status, 1, ap.out);
  has(ap, /^refused: CART-008 — the block changed since start$/m);
});

// ---------------------------------------------------------------------------------------------
// apply · discard · refresh

test('apply: installs the candidate only after weaken-check, a heal verify of this attempt and a critic pass on the same digests', async () => {
  const ctx = e2e();
  const { dir, c } = await probeAndClassify(ctx, 'probe-spec-failed,probe-probe-green attest-pass 1,0');
  assert.equal(c.status, 0, c.out);
  const h = healJson(ctx, dir);
  retarget(ctx, h);
  const repaired = read(ctx, h.candidate);
  const apply = (verify, critic) => heal(ctx, 'apply', 'CART-008', '--run', dir, '--verify', verify, '--critic', critic);
  const noVerify = apply(dir, `${dir}/none.json`);
  has(noVerify, /^refused: verify\.json unreadable/m);
  const verifyDir = await healVerify(ctx, dir, h);
  has(apply(verifyDir, `${dir}/none.json`), /^refused: critic verdict unreadable/m);
  for (const bad of [{ heal_id: 'another' }, { mode: 'clause' }, { before_sha256: '0'.repeat(64) }, { clauses: [] }, { verdict: 'revise' }]) {
    const r = apply(verifyDir, writeHealCritic(ctx, dir, h, bad));
    assert.equal(r.status, 1, `${JSON.stringify(bad)}: ${r.out}`);
    has(r, /^refused: CART-008 — no heal critic pass for this attempt$/m);
  }
  const stale = apply(verifyDir, writeHealCritic(ctx, dir, h, { spec_sha256: '0'.repeat(64) }));
  has(stale, /^refused: CART-008 — the critic verdict predates a change \(spec\)$/m);
  assert.ok(exists(ctx, h.candidate), 'every refusal keeps the candidate');
  const ok = apply(verifyDir, writeHealCritic(ctx, dir, h));
  assert.equal(ok.status, 0, ok.out);
  has(ok, /^healed: CART-008 — e2e\/regression\/cart\/cart-008\.spec\.ts$/m);
  assert.equal(read(ctx, SPEC8), repaired);
  assert.ok(!exists(ctx, h.candidate));
  assert.deepEqual([healJson(ctx, dir).state, healJson(ctx, dir).verify_run], ['applied', verifyDir]);
  const again = apply(verifyDir, `${dir}/critic-CART-008.json`);
  has(again, /^refused: CART-008 — the attempt is applied$/m);
});

test('apply: refuses a weakened candidate, a changed helper, a verify of another attempt, and keeps both versions on a conflict', async () => {
  const ctx = e2e();
  const { dir, c } = await probeAndClassify(ctx, 'probe-spec-failed,probe-probe-green attest-pass 1,0');
  assert.equal(c.status, 0, c.out);
  const h = healJson(ctx, dir);
  const apply = (verify, critic) => heal(ctx, 'apply', 'CART-008', '--run', dir, '--verify', verify, '--critic', critic);
  write(ctx, h.candidate, read(ctx, SPEC8).replace('toBeVisible()', 'toBeAttached()'));
  const weak = apply(dir, `${dir}/none.json`);
  assert.equal(weak.status, 1, weak.out);
  has(weak, /^refused: CART-008 — weakened: 8: loosened-matcher — toBeVisible → toBeAttached$/m);
  retarget(ctx, h);
  write(ctx, h.candidate, read(ctx, SPEC8).replace("{ name: 'Summary' }", "{ name: 'Summary', level: 2 }"));
  const verifyDir = await healVerify(ctx, dir, h);
  const critic = writeHealCritic(ctx, dir, h);
  const fixtures = read(ctx, 'e2e/fixtures.ts');
  write(ctx, 'e2e/fixtures.ts', `${fixtures}// a helper edit\n`);
  has(apply(verifyDir, critic), /^refused: CART-008 — a helper changed — heal changes only the spec$/m);
  write(ctx, 'e2e/fixtures.ts', fixtures);
  const vfile = `${verifyDir}/verify.json`;
  const vtext = read(ctx, vfile);
  writeJson(ctx, vfile, { ...JSON.parse(vtext), heal_id: 'another' });
  has(apply(verifyDir, critic), new RegExp(`^refused: CART-008 — verify\\.json belongs to heal attempt another, not ${h.id}$`, 'm'));
  write(ctx, vfile, vtext);
  const candidate = read(ctx, h.candidate);
  write(ctx, SPEC8, `${read(ctx, SPEC8)}// edited by hand\n`);
  const claimed = read(ctx, SPEC8);
  const conflict = apply(verifyDir, critic);
  assert.equal(conflict.status, 1, conflict.out);
  has(conflict, new RegExp(`^refused: CART-008 — conflict: e2e/regression/cart/cart-008\\.spec\\.ts changed since start; candidate kept at ${CAND8.replace(/\./g, '\\.')}$`, 'm'));
  assert.deepEqual([read(ctx, SPEC8), read(ctx, h.candidate)], [claimed, candidate], 'both versions kept');
});

test('discard: moves the candidate and probe into the heal directory and never touches the claimed spec', () => {
  const ctx = e2e();
  const specBytes = read(ctx, SPEC8);
  const { dir } = startWithProbe(ctx);
  const r = heal(ctx, 'discard', 'CART-008', '--run', dir);
  assert.equal(r.status, 0, r.out);
  has(r, /^discarded: CART-008$/m);
  assert.ok(!exists(ctx, CAND8) && !exists(ctx, PROBE8));
  assert.ok(exists(ctx, `${dir}/discarded/cart-008.heal.spec.ts`) && exists(ctx, `${dir}/discarded/cart-008.probe.spec.ts`));
  assert.equal(read(ctx, SPEC8), specBytes);
  assert.equal(healJson(ctx, dir).state, 'discarded');
  has(heal(ctx, 'discard', 'CART-008', '--run', dir), /^discarded: CART-008 — already discarded$/m);
});

test('refresh: installs a refreshed header only when the scenario then computes verified; a refused refresh leaves the claimed spec and the candidate intact', async () => {
  const ctx = e2e({ claim9: true });
  write(ctx, SPEC8, read(ctx, SPEC8).replace('// regression: CART-008 · source: live', '// regression: CART-008 · source: code'));
  const lagging = read(ctx, SPEC8);
  const notRefresh = heal(ctx, 'start', 'CART-009', '--env', 'test', '--refresh');
  has(notRefresh, /^refused: CART-009 — not a refresh: the spec is verified$/m);
  const s = heal(ctx, 'start', 'CART-008', '--env', 'test', '--refresh');
  assert.equal(s.status, 0, s.out);
  assert.doesNotMatch(s.stdout, /^probe:/m, 'a refresh writes no probe');
  const dir = healDirOf(s);
  const h = healJson(ctx, dir);
  assert.deepEqual([h.refresh, h.probe, h.automation.state], [true, null, 'stale']);
  const apply = (verify, critic) => heal(ctx, 'apply', 'CART-008', '--run', dir, '--verify', verify, '--critic', critic, '--refresh');
  has(heal(ctx, 'apply', 'CART-008', '--run', dir, '--verify', dir, '--critic', 'x'), /^refused: CART-008 — a refresh attempt is applied with --refresh$/m);
  const refused = apply(dir, `${dir}/none.json`);
  assert.equal(refused.status, 1, refused.out);
  has(refused, /^refused: CART-008 — lint: e2e\/regression\/cart\/cart-008\.heal\.spec\.ts:1: header source code differs from the catalog Source live$/m);
  assert.deepEqual([read(ctx, SPEC8), read(ctx, h.candidate)], [lagging, lagging], 'a refused refresh leaves both intact');
  write(ctx, h.candidate, lagging.replace('source: code', 'source: live').replace("{ name: 'Summary' }", "{ name: 'Summary!' }"));
  has(apply(dir, `${dir}/none.json`), /^refused: CART-008 — weakened: 8: retargeted — .* a refresh changes only the header$/m);
  write(ctx, h.candidate, lagging.replace('source: code', 'source: live').replace('toBeVisible()', 'toBeHidden()'));
  has(apply(dir, `${dir}/none.json`), /^refused: CART-008 — weakened: \d+: loosened-matcher/m, 'a refresh is a header change only');
  write(ctx, h.candidate, lagging.replace('source: code', 'source: live'));
  const verifyDir = await healVerify(ctx, dir, h);
  const ok = apply(verifyDir, writeHealCritic(ctx, dir, h));
  assert.equal(ok.status, 0, ok.out);
  has(ok, /^refreshed: CART-008 — e2e\/regression\/cart\/cart-008\.spec\.ts$/m);
  const b = parseCatalog(ctx.root, catalogFiles(ctx.root, catalogSettings(loadConfig(ctx.root).config))).find((x) => x.id === 'CART-008');
  assert.equal(automationState(ctx.root, b, {}).state, 'verified');
});

// ---------------------------------------------------------------------------------------------
// The guarantees

test('heal never writes the catalog', async () => {
  const ctx = e2e();
  const catalog = () => read(ctx, `${CAT}/cart.md`) + read(ctx, `${CAT}/pdp.md`);
  const bytes = catalog();
  const same = (step) => assert.equal(catalog(), bytes, `the catalog changed at ${step}`);
  const { dir } = startWithProbe(ctx);
  same('start');
  useRunner(ctx, 'probe-spec-failed,probe-probe-green attest-pass 1,0');
  const probeDir = recordDir(await run(ctx, ['probe', 'CART-008', '--heal', dir]), 'probe.json');
  same('probe');
  assert.equal(heal(ctx, 'classify', 'CART-008', '--run', dir, '--probe', probeDir).status, 0);
  same('classify');
  const h = healJson(ctx, dir);
  retarget(ctx, h);
  const verifyDir = await healVerify(ctx, dir, h);
  same('verify');
  const ok = heal(ctx, 'apply', 'CART-008', '--run', dir, '--verify', verifyDir, '--critic', writeHealCritic(ctx, dir, h));
  assert.equal(ok.status, 0, ok.out);
  same('apply');
  heal(ctx, 'discard', 'CART-008', '--run', dir);
  same('discard');
  assert.doesNotMatch(fs.readFileSync(HEAL, 'utf8'), /from '\.\/visual(-spec)?\.mjs'|child_process/, 'no visual writer, no subprocess');
});

test('every heal command refuses in a team clone', () => {
  const ctx = e2e();
  write(ctx, '.agents/team/team.json', '{}\n');
  const commands = [
    ['select', '--run', 'x'], ['select', SPEC8], ['start', 'CART-008', '--env', 'test'], ['probe-key', 'CART-008', '--run', 'd'],
    ['classify', 'CART-008', '--run', 'd', '--probe', 'p'], ['apply', 'CART-008', '--run', 'd', '--verify', 'v', '--critic', 'c'], ['discard', 'CART-008', '--run', 'd'],
  ];
  for (const args of commands) {
    const r = heal(ctx, ...args);
    assert.equal(r.status, 3, `${args[0]}: ${r.out}`);
    has(r, /^refused: a team clone never runs regression — run heal from your own checkout$/m);
  }
  assert.ok(!exists(ctx, CAND8));
});
