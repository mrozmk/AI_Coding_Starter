// Unit tests of the author lane's scripts (.claude/lib/regression/author.mjs): select (ids, areas,
// pending, --from-qa against a /qa-verify working file), draft ownership, claim's bindings to a
// verify record and a critic verdict, reject and suggest. Temp copies of fixtures/regression/author
// (and, end to end, of the run fixture root with the fake runner); REGRESSION_LOCK_DIR in a temp dir.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { createHash } from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

import { loadConfig, catalogSettings } from '../regression/config.mjs';
import { blockTexts, catalogFiles } from '../regression/catalog.mjs';
import { digestFiles } from '../regression/policy.mjs';
import { lintSpec } from '../regression/speclint.mjs';
import { acquireLock, checkoutLockName } from '../regression/run.mjs';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const AUTHOR = path.join(HERE, '../regression/author.mjs');
const RUN = path.join(HERE, '../regression/run.mjs');
const CATALOG = path.join(HERE, '../regression/catalog.mjs');
const FIX = path.join(HERE, 'fixtures/regression/author');
const RUN_FIX = path.join(HERE, 'fixtures/regression/run');
const CAT = '.agents/regression/scenarios';
const QA = '.agents/handoffs/qa-issue-12-ac-matrix.md';
const SPEC4 = 'e2e/regression/cart/cart-004.spec.ts';
const sha256 = (b) => createHash('sha256').update(b).digest('hex');

// ---------------------------------------------------------------------------------------------
// Helpers

function setup(from = FIX) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'regression-author-'));
  fs.cpSync(from, root, { recursive: true });
  return { root, locks: fs.mkdtempSync(path.join(os.tmpdir(), 'regression-locks-')) };
}
function cli(ctx, script, args, env = {}) {
  const r = spawnSync(process.execPath, [script, ...args, '--root', ctx.root], { encoding: 'utf8', env: { ...process.env, REGRESSION_LOCK_DIR: ctx.locks, ...env } });
  return { ...r, out: r.stdout + r.stderr };
}
const author = (ctx, ...args) => cli(ctx, AUTHOR, args);
const read = (ctx, rel) => fs.readFileSync(path.join(ctx.root, rel), 'utf8');
const write = (ctx, rel, text) => { fs.mkdirSync(path.dirname(path.join(ctx.root, rel)), { recursive: true }); fs.writeFileSync(path.join(ctx.root, rel), text); };
const writeJson = (ctx, rel, v) => write(ctx, rel, `${JSON.stringify(v, null, 2)}\n`);
const cfgOf = (ctx) => loadConfig(ctx.root).config;

/** The evidence key of a candidate as verify and claim compute it from the current files. */
function keyOf(ctx, id, spec) {
  const cfg = cfgOf(ctx);
  const files = catalogFiles(ctx.root, catalogSettings(cfg));
  return {
    spec_sha256: sha256(fs.readFileSync(path.join(ctx.root, spec))),
    inputs_sha256: digestFiles(ctx.root, lintSpec(ctx.root, cfg, spec, id).files),
    block_sha256: sha256(blockTexts(ctx.root, files).get(id).text),
  };
}

/** A verify run directory whose record qualifies `entries` (`[{id, spec, projects}]`), with overrides. */
function writeVerify(ctx, entries, { passesOk = [1, 2, 3], qualified = true, dropProject = null, passCount = 3, nonces } = {}) {
  const dir = `.agents/regression/runs/test-verify-${Math.random().toString(16).slice(2, 8)}`;
  const passes = Array.from({ length: passCount }, (_, i) => ({
    n: i + 1, nonce: nonces?.[i] ?? `nonce-${i + 1}`, disqualified: [],
    cases: entries.flatMap((e) => e.projects.filter((p) => !(dropProject && dropProject.pass === i + 1 && dropProject.project === p)).map((project) => ({ id: e.id, project, result: 'passed', attempts: 1 }))),
  }));
  const scenarios = entries.map((e) => ({ id: e.id, spec: e.spec, ...keyOf(ctx, e.id, e.spec), projects: e.projects, qualified, passes_ok: passesOk, reason: null, context: [] }));
  writeJson(ctx, `${dir}/verify.json`, { schema: 1, run_id: path.basename(dir), env: 'test', kind: 'test', base_url: 'https://test.shop.example.com', repeats: 3, passes, scenarios, guard: { blocked: [], budget: {}, stop: null } });
  return dir;
}
function writeCritic(ctx, dir, id, spec, extra = {}) {
  const file = `${dir}/critic-${id}.json`;
  writeJson(ctx, file, { id, verdict: 'pass', ...keyOf(ctx, id, spec), clauses: [], findings: [], ...extra });
  return file;
}
const BOTH = ['desktop-chrome', 'mobile-safari'];
const claim = (ctx, id, spec, dir, critic, extra = []) => author(ctx, 'claim', id, '--spec', spec, '--verify', dir, '--critic', critic, ...extra);
const has = (r, re) => assert.match(r.stdout, re, r.out);
const withoutSpec4 = (ctx) => { fs.rmSync(path.join(ctx.root, SPEC4)); return ctx; };

// ---------------------------------------------------------------------------------------------
// select

test('select: refuses not READY, an existing Spec, a write under policy, no device and an existing target', () => {
  const ctx = setup();
  const r = author(ctx, 'select', 'CART-006', 'CART-007', 'CART-005', 'CART-004', '--env', 'prod');
  assert.equal(r.status, 1, r.out);
  has(r, /^refused: CART-006 — not READY \(BLOCKED \(#12\)\)$/m);
  has(r, /^refused: CART-007 — already has a spec$/m);
  has(r, /^refused: CART-005 — writes refuse$/m);
  has(r, /^refused: CART-004 — target exists — e2e\/regression\/cart\/cart-004\.spec\.ts$/m);
  const nodev = setup();
  const cfg = cfgOf(nodev);
  delete cfg.runner.devices.mobile;
  writeJson(nodev, '.claude/regression.json', cfg);
  has(author(nodev, 'select', 'CART-004'), /^refused: CART-004 — no device mobile$/m);
  const noenv = author(ctx, 'select', 'CART-004', '--env', 'nope');
  assert.equal(noenv.status, 2);
  has(noenv, /^environments: test, prod$/m);
});

test('select: --area and --pending pick READY scenarios without a spec', () => {
  const ctx = withoutSpec4(setup());
  const area = author(ctx, 'select', '--area', 'SRCH');
  assert.equal(area.status, 0, area.out);
  assert.equal(area.stdout, 'eligible: SRCH-001 e2e/regression/srch/srch-001.spec.ts\n');
  const pending = author(ctx, 'select', '--pending');
  assert.deepEqual(pending.stdout.trim().split('\n').map((l) => l.split(' ')[1]), ['CART-004', 'CART-005', 'CART-008', 'CART-009', 'CART-010', 'SRCH-001']);
  const json = JSON.parse(author(ctx, 'select', '--area', 'CART,SRCH', '--json').stdout);
  assert.equal(json.env, 'test');
  assert.deepEqual(json.eligible.map((e) => e.id), ['CART-004', 'CART-005', 'CART-008', 'CART-009', 'CART-010', 'SRCH-001']);
});

test('select --from-qa: joins a PASS row by fingerprint, refuses a FAIL row and skips a carried row', () => {
  const ctx = withoutSpec4(setup());
  const r = author(ctx, 'select', '--from-qa', QA);
  assert.equal(r.status, 0, r.out);
  has(r, /^eligible: CART-004 e2e\/regression\/cart\/cart-004\.spec\.ts qa: E2-3\.AC2 \(script\) qa-artifacts\/ac2-flow\.mjs$/m);
  has(r, /^not promoted: CART-008 — E2-3\.AC3 FAIL$/m);
  has(r, /^skipped: CART-009 — E2-3\.AC4 carried$/m);
  assert.doesNotMatch(r.stdout, /eligible: CART-00[89]/);
});

test('select --from-qa: a CITED row next to the observed row lets the observation decide', () => {
  const ctx = withoutSpec4(setup());
  write(ctx, 'cited.md', read(ctx, QA)
    .replace('- E2-3.AC2 [a1b2c3] — PASS', '- E2-3.AC2 [a1b2c3] — CITED — task ledger: met (PR #7)\n- E2-3.AC2 [a1b2c3] — PASS')
    .replace('- E2-3.AC3 [d4e5f6] — FAIL', '- E2-3.AC3 [d4e5f6] — CITED — task ledger: met (PR #7)\n- E2-3.AC3 [d4e5f6] — FAIL'));
  const r = author(ctx, 'select', '--from-qa', 'cited.md');
  assert.equal(r.status, 0, r.out);
  has(r, /^eligible: CART-004 e2e\/regression\/cart\/cart-004\.spec\.ts qa: E2-3\.AC2 \(script\) qa-artifacts\/ac2-flow\.mjs$/m);
  has(r, /^not promoted: CART-008 — E2-3\.AC3 FAIL$/m);
  assert.doesNotMatch(r.stdout, /CITED/);
});

test('select --from-qa: a ticket-key scenario with two PASS rows is ambiguous', () => {
  const ctx = withoutSpec4(setup());
  const r = author(ctx, 'select', '--from-qa', QA);
  has(r, /^ambiguous: SRCH-001 — author without --from-qa$/m);
  has(r, /^no scenario: E2-3\.AC6$/m);
});

test('select --from-qa: a producer-shaped ticket=12 record joins a scenario citing #12', () => {
  const ctx = setup();
  const text = read(ctx, QA)
    .replace(/^- E2-3\.AC2 .*\n/m, '').replace(/^- E2-3\.AC4 .*\n/m, '').replace(/^- E2-3\.AC5 .*\n/m, '');
  write(ctx, '.agents/handoffs/qa-issue-12-ac-matrix-2.md', text);
  const r = author(ctx, 'select', '--from-qa', '.agents/handoffs/qa-issue-12-ac-matrix-2.md');
  assert.equal(r.status, 0, r.out);
  has(r, /^eligible: SRCH-001 e2e\/regression\/srch\/srch-001\.spec\.ts qa: E2-3\.AC6 \(row\)$/m);
});

test('select --from-qa: reordered matrix columns and AC-3 in the matrix against AC3 in the record still join', () => {
  const ctx = setup();
  fs.appendFileSync(path.join(ctx.root, CAT, 'srch.md'), '\n### SRCH-002 — Filter the results\n- **Priority:** P1 · **Viewport:** desktop · **Status:** READY · **Effect:** read\n- **Goal:** Filter.\n- **Steps:**\n  1. Filter.\n- **Expected:** The list narrows.\n- **Source:** CS-79 · **Spec:** —\n');
  write(ctx, '.agents/handoffs/qa-cs-79-ac-matrix.md', [
    '# QA working file — CS-79', '',
    '| artifacts | disposition | agent | ac_id |', '|---|---|---|---|',
    '| qa-artifacts/ac2-flow.mjs | PASS | qa-runtime-ui (driver: script) | AC-3 |', '',
    '## QA verification — Filters', '', '### Criteria', '- AC3 [abcdef] — PASS — runtime-ui — the list narrows', '',
    'qa-verify:v1 record run=20261127T100000Z ticket=CS-79 mode=first group=- build=- pass=1 fail=0 cited=0 deferred=0 env=0 needs-human=0', '',
  ].join('\n'));
  const r = author(ctx, 'select', '--from-qa', '.agents/handoffs/qa-cs-79-ac-matrix.md');
  assert.equal(r.status, 0, r.out);
  has(r, /^eligible: SRCH-002 e2e\/regression\/srch\/srch-002\.spec\.ts qa: AC3 \(script\) qa-artifacts\/ac2-flow\.mjs$/m);
});

test('select --from-qa: a carried PASS next to old evidence is skipped, and a screenshot-only row has no recorded sequence', () => {
  const ctx = withoutSpec4(setup());
  const r = author(ctx, 'select', '--from-qa', QA);
  has(r, /^skipped: CART-009 — E2-3\.AC4 carried$/m);
  has(r, /^skipped: CART-010 — no recorded sequence$/m);
  write(ctx, 'bad.md', read(ctx, QA).replace('- E2-3.AC3 [d4e5f6] — FAIL', '- E2-3.AC3 d4e5f6 — FAIL'));
  const bad = author(ctx, 'select', '--from-qa', 'bad.md');
  assert.equal(bad.status, 1);
  has(bad, /^record row 2 malformed$/m);
  write(ctx, 'none.md', '# notes\n');
  has(author(ctx, 'select', '--from-qa', 'none.md'), /^not a qa-verify working file with a record$/m);
});

test('lint: prints each violation with its file and line', () => {
  const ctx = setup();
  const r = author(ctx, 'lint', 'e2e/regression/lint/fixed-wait.spec.ts', '--id', 'CART-004');
  assert.equal(r.status, 1, r.out);
  has(r, /^e2e\/regression\/lint\/fixed-wait\.spec\.ts:8: forbidden waitForTimeout\($/m);
  has(r, /^e2e\/regression\/lint\/fixed-wait\.spec\.ts:9: forbidden \.locator\('$/m);
  const ok = author(ctx, 'lint', SPEC4, '--id', 'CART-004');
  assert.equal(ok.status, 0, ok.out);
});

// ---------------------------------------------------------------------------------------------
// claim

test('claim: writes Spec back and re-validates the catalog', () => {
  const ctx = setup();
  const dir = writeVerify(ctx, [{ id: 'CART-004', spec: SPEC4, projects: BOTH }]);
  const r = claim(ctx, 'CART-004', SPEC4, dir, writeCritic(ctx, dir, 'CART-004', SPEC4));
  assert.equal(r.status, 0, r.out);
  has(r, /^claimed: CART-004 — e2e\/regression\/cart\/cart-004\.spec\.ts$/m);
  const cart = read(ctx, `${CAT}/cart.md`);
  assert.match(cart, /^- \*\*Source:\*\* E2-3\.AC2 \[a1b2c3\] · \*\*Spec:\*\* e2e\/regression\/cart\/cart-004\.spec\.ts › CART-004 — See the cart heading$/m);
  assert.match(cart, /### CART-005[\s\S]*?- \*\*Source:\*\* live · \*\*Spec:\*\* —/, 'the next block is untouched');
  const v = spawnSync(process.execPath, [CATALOG, '--root', ctx.root], { encoding: 'utf8' });
  assert.equal(v.status, 0, v.stdout + v.stderr);
  assert.equal(fs.readdirSync(path.join(ctx.root, CAT)).some((f) => f.includes('.tmp-')), false);
});

test('claim: fills a Spec written as - and takes the title of the real test declaration, not a comment', () => {
  const ctx = setup();
  write(ctx, `${CAT}/cart.md`, read(ctx, `${CAT}/cart.md`).replace('**Source:** E2-3.AC2 [a1b2c3] · **Spec:** —', '**Source:** E2-3.AC2 [a1b2c3] · **Spec:** -'));
  write(ctx, SPEC4, `// was: test('CART-004 — an older title')\n${read(ctx, SPEC4)}`);
  const dir = writeVerify(ctx, [{ id: 'CART-004', spec: SPEC4, projects: BOTH }]);
  const r = claim(ctx, 'CART-004', SPEC4, dir, writeCritic(ctx, dir, 'CART-004', SPEC4));
  assert.equal(r.status, 0, r.out);
  assert.match(read(ctx, `${CAT}/cart.md`), /^- \*\*Source:\*\* E2-3\.AC2 \[a1b2c3\] · \*\*Spec:\*\* e2e\/regression\/cart\/cart-004\.spec\.ts › CART-004 — See the cart heading$/m);
});

test('claim: fills a Spec field that another field follows on its line', () => {
  const ctx = setup();
  write(ctx, `${CAT}/cart.md`, read(ctx, `${CAT}/cart.md`)
    .replace('- **Source:** E2-3.AC2 [a1b2c3] · **Spec:** —', '- **Spec:** — · **Source:** E2-3.AC2 [a1b2c3]'));
  const dir = writeVerify(ctx, [{ id: 'CART-004', spec: SPEC4, projects: BOTH }]);
  const r = claim(ctx, 'CART-004', SPEC4, dir, writeCritic(ctx, dir, 'CART-004', SPEC4));
  assert.equal(r.status, 0, r.out);
  assert.match(read(ctx, `${CAT}/cart.md`), /^- \*\*Spec:\*\* e2e\/regression\/cart\/cart-004\.spec\.ts › CART-004 — See the cart heading · \*\*Source:\*\* E2-3\.AC2 \[a1b2c3\]$/m);
});

test('claim: refuses without three passes, with a changed spec or block, or without a critic pass', () => {
  const two = setup();
  const d2 = writeVerify(two, [{ id: 'CART-004', spec: SPEC4, projects: BOTH }], { passesOk: [1, 2], qualified: false });
  has(claim(two, 'CART-004', SPEC4, d2, writeCritic(two, d2, 'CART-004', SPEC4)), /^refused: CART-004 — not three green passes/m);
  const spec = setup();
  const ds = writeVerify(spec, [{ id: 'CART-004', spec: SPEC4, projects: BOTH }]);
  const cs = writeCritic(spec, ds, 'CART-004', SPEC4);
  fs.appendFileSync(path.join(spec.root, SPEC4), '\n');
  has(claim(spec, 'CART-004', SPEC4, ds, cs), /^refused: CART-004 — spec changed since the verify$/m);
  const block = setup();
  const db = writeVerify(block, [{ id: 'CART-004', spec: SPEC4, projects: BOTH }]);
  const cb = writeCritic(block, db, 'CART-004', SPEC4);
  write(block, `${CAT}/cart.md`, read(block, `${CAT}/cart.md`).replace('The cart heading is visible.', 'The cart heading and the lines are visible.'));
  has(claim(block, 'CART-004', SPEC4, db, cb), /^refused: CART-004 — block changed since the verify$/m);
  const revise = setup();
  const dr = writeVerify(revise, [{ id: 'CART-004', spec: SPEC4, projects: BOTH }]);
  has(claim(revise, 'CART-004', SPEC4, dr, writeCritic(revise, dr, 'CART-004', SPEC4, { verdict: 'revise' })), /^refused: CART-004 — no critic pass$/m);
  for (const c of [two, spec, block, revise]) assert.match(read(c, `${CAT}/cart.md`), /\*\*Source:\*\* E2-3\.AC2 \[a1b2c3\] · \*\*Spec:\*\* —/);
});

test('claim: refuses a record marked qualified with only two passes or a missing project', () => {
  const two = setup();
  const d2 = writeVerify(two, [{ id: 'CART-004', spec: SPEC4, projects: BOTH }], { passCount: 2 });
  has(claim(two, 'CART-004', SPEC4, d2, writeCritic(two, d2, 'CART-004', SPEC4)), /^refused: CART-004 — verify\.json does not hold three passes with distinct nonces$/m);
  const same = setup();
  const dn = writeVerify(same, [{ id: 'CART-004', spec: SPEC4, projects: BOTH }], { nonces: ['n', 'n', 'n'] });
  has(claim(same, 'CART-004', SPEC4, dn, writeCritic(same, dn, 'CART-004', SPEC4)), /distinct nonces/m);
  const gap = setup();
  const dg = writeVerify(gap, [{ id: 'CART-004', spec: SPEC4, projects: BOTH }], { dropProject: { pass: 2, project: 'mobile-safari' } });
  has(claim(gap, 'CART-004', SPEC4, dg, writeCritic(gap, dg, 'CART-004', SPEC4)), /^refused: CART-004 — pass 2 has no single passed attempt on mobile-safari$/m);
  const one = setup();
  const d1 = writeVerify(one, [{ id: 'CART-004', spec: SPEC4, projects: ['desktop-chrome'] }]);
  has(claim(one, 'CART-004', SPEC4, d1, writeCritic(one, d1, 'CART-004', SPEC4)), /^refused: CART-004 — verified projects/m);
});

test('claim: refuses when the block changed after the digest check, rechecked under the lock', () => {
  const ctx = setup();
  const dir = writeVerify(ctx, [{ id: 'CART-004', spec: SPEC4, projects: BOTH }]);
  const critic = writeCritic(ctx, dir, 'CART-004', SPEC4);
  const saved = process.env.REGRESSION_LOCK_DIR;
  process.env.REGRESSION_LOCK_DIR = ctx.locks;
  const held = acquireLock(checkoutLockName(ctx.root), { pid: process.pid, pgid: null, run_id: 'a-run' });
  try {
    has(claim(ctx, 'CART-004', SPEC4, dir, critic), /^refused: checkout lock held — lock checkout-[0-9a-f]{16} held by pid \d+ \(run a-run\)$/m);
  } finally {
    held.lock.release();
    if (saved === undefined) delete process.env.REGRESSION_LOCK_DIR; else process.env.REGRESSION_LOCK_DIR = saved;
  }
  write(ctx, `${CAT}/cart.md`, read(ctx, `${CAT}/cart.md`).replace('- **Goal:** Open the cart and see it.', '- **Goal:** Open the cart.'));
  has(claim(ctx, 'CART-004', SPEC4, dir, critic), /^refused: CART-004 — block changed since the verify$/m);
  assert.match(read(ctx, `${CAT}/cart.md`), /\*\*Source:\*\* E2-3\.AC2 \[a1b2c3\] · \*\*Spec:\*\* —/);
});

test('claim: accepts the real output of run.mjs verify end to end and refuses a critic verdict from before a change of Expected', () => {
  const ctx = setup(path.join(RUN_FIX, 'root'));
  fs.appendFileSync(path.join(ctx.root, CAT, 'cart.md'), fs.readFileSync(path.join(RUN_FIX, 'authoring/cart-append.md'), 'utf8'));
  fs.cpSync(path.join(RUN_FIX, 'authoring/e2e'), path.join(ctx.root, 'e2e'), { recursive: true });
  const cfg = cfgOf(ctx);
  cfg.runner.commands.full = `"${process.execPath}" "${path.join(RUN_FIX, 'fake-runner.mjs')}" verify-green attest-pass 0`;
  writeJson(ctx, '.claude/regression.json', cfg);
  const spec = 'e2e/regression/cart/cart-008.spec.ts';
  const verify = () => {
    const v = cli(ctx, RUN, ['verify', `CART-008=${spec}`]);
    assert.equal(v.status, 0, v.out);
    const m = /^verified: CART-008 spec_sha256=(\S+) inputs_sha256=(\S+) block_sha256=(\S+)$/m.exec(v.stdout);
    return { dir: path.dirname(/^record: (.+)$/m.exec(v.stdout)[1]), key: { spec_sha256: m[1], inputs_sha256: m[2], block_sha256: m[3] } };
  };
  const first = verify();
  const criticFile = `${first.dir}/critic-CART-008.json`;
  writeJson(ctx, criticFile, { id: 'CART-008', verdict: 'pass', ...first.key, clauses: [], findings: [] });
  write(ctx, `${CAT}/cart.md`, read(ctx, `${CAT}/cart.md`).replace('- **Expected:** The summary heading is visible.', '- **Expected:** The summary heading and the total are visible.'));
  const second = verify();
  assert.notEqual(second.key.block_sha256, first.key.block_sha256);
  has(claim(ctx, 'CART-008', spec, second.dir, criticFile), /^refused: CART-008 — the critic verdict predates a change \(block\)$/m);
  const fresh = `${second.dir}/critic-CART-008.json`;
  writeJson(ctx, fresh, { id: 'CART-008', verdict: 'pass', ...second.key, clauses: [], findings: [] });
  const ok = claim(ctx, 'CART-008', spec, second.dir, fresh);
  assert.equal(ok.status, 0, ok.out);
  has(ok, /^claimed: CART-008 — e2e\/regression\/cart\/cart-008\.spec\.ts$/m);
});

test('claim: a --from-qa draft is refused without a provenance pass, or when one action has no recorded QA step', () => {
  const ctx = setup();
  const content = read(ctx, SPEC4);
  fs.rmSync(path.join(ctx.root, SPEC4));
  const run = '.agents/regression/runs/author-t';
  const d = author(ctx, 'draft', 'CART-004', '--run', run, '--qa', 'E2-3.AC2');
  assert.equal(d.status, 0, d.out);
  write(ctx, SPEC4, content);
  const dir = writeVerify(ctx, [{ id: 'CART-004', spec: SPEC4, projects: BOTH }]);
  const critic = writeCritic(ctx, dir, 'CART-004', SPEC4);
  has(claim(ctx, 'CART-004', SPEC4, dir, critic), /^refused: CART-004 — a --from-qa draft needs a provenance pass \(--provenance\)$/m);
  const prov = (actions) => { const f = `${dir}/provenance-CART-004.json`; writeJson(ctx, f, { id: 'CART-004', mode: 'provenance', verdict: 'pass', ...keyOf(ctx, 'CART-004', SPEC4), actions, findings: [] }); return f; };
  has(claim(ctx, 'CART-004', SPEC4, dir, critic, ['--provenance', prov([{ line: 7, action: 'goto', qa_step: 1 }, { line: 8, action: 'click', qa_step: null }])]), /^refused: CART-004 — 1 action\(s\) with no recorded QA step \(line 8\)$/m);
  const ok = claim(ctx, 'CART-004', SPEC4, dir, critic, ['--provenance', prov([{ line: 7, action: 'goto', qa_step: 1 }])]);
  assert.equal(ok.status, 0, ok.out);
});

test('claim: a rejected --from-qa draft does not hold a later plain draft of the same scenario to a provenance pass', () => {
  const ctx = setup();
  const content = read(ctx, SPEC4);
  fs.rmSync(path.join(ctx.root, SPEC4));
  const qaRun = '.agents/regression/runs/author-qa';
  assert.equal(author(ctx, 'draft', 'CART-004', '--run', qaRun, '--qa', 'E2-3.AC2').status, 0);
  has(author(ctx, 'reject', 'CART-004', '--run', qaRun), /^rejected: CART-004 — /m);
  assert.ok(JSON.parse(read(ctx, `${qaRun}/drafts.json`)).drafts[0].rejected_at, 'reject closes the registration');
  has(author(ctx, 'reject', 'CART-004', '--run', qaRun), /^rejected: CART-004 — already rejected$/m);
  const plainRun = '.agents/regression/runs/author-plain';
  const d = author(ctx, 'draft', 'CART-004', '--run', plainRun);
  assert.equal(d.status, 0, d.out);
  write(ctx, SPEC4, content);
  const dir = writeVerify(ctx, [{ id: 'CART-004', spec: SPEC4, projects: BOTH }]);
  const ok = claim(ctx, 'CART-004', SPEC4, dir, writeCritic(ctx, dir, 'CART-004', SPEC4));
  assert.equal(ok.status, 0, ok.out);
  has(ok, /^claimed: CART-004 — /m);
});

test('claim: a live --from-qa draft after a rejected plain draft still needs its provenance pass', () => {
  const ctx = setup();
  const content = read(ctx, SPEC4);
  fs.rmSync(path.join(ctx.root, SPEC4));
  const plainRun = '.agents/regression/runs/author-plain';
  assert.equal(author(ctx, 'draft', 'CART-004', '--run', plainRun).status, 0);
  assert.equal(author(ctx, 'reject', 'CART-004', '--run', plainRun).status, 0);
  assert.equal(author(ctx, 'draft', 'CART-004', '--run', '.agents/regression/runs/author-qa', '--qa', 'E2-3.AC2').status, 0);
  write(ctx, SPEC4, content);
  const dir = writeVerify(ctx, [{ id: 'CART-004', spec: SPEC4, projects: BOTH }]);
  has(claim(ctx, 'CART-004', SPEC4, dir, writeCritic(ctx, dir, 'CART-004', SPEC4)), /^refused: CART-004 — a --from-qa draft needs a provenance pass \(--provenance\)$/m);
});

test('claim: two claims in one file keep both', () => {
  const ctx = setup();
  const spec10 = 'e2e/regression/cart/cart-010.spec.ts';
  write(ctx, spec10, read(ctx, SPEC4).replace(/CART-004/g, 'CART-010').replace('E2-3.AC2 [a1b2c3]', 'E2-3.AC5 [111111]').replace('See the cart heading', 'The cart looks right'));
  const d4 = writeVerify(ctx, [{ id: 'CART-004', spec: SPEC4, projects: BOTH }]);
  const d10 = writeVerify(ctx, [{ id: 'CART-010', spec: spec10, projects: ['desktop-chrome'] }]);
  const c4 = writeCritic(ctx, d4, 'CART-004', SPEC4);
  const c10 = writeCritic(ctx, d10, 'CART-010', spec10);
  assert.equal(claim(ctx, 'CART-004', SPEC4, d4, c4).status, 0);
  const r = claim(ctx, 'CART-010', spec10, d10, c10);
  assert.equal(r.status, 0, r.out);
  const cart = read(ctx, `${CAT}/cart.md`);
  assert.match(cart, /\*\*Spec:\*\* e2e\/regression\/cart\/cart-004\.spec\.ts › CART-004 — See the cart heading/);
  assert.match(cart, /\*\*Spec:\*\* e2e\/regression\/cart\/cart-010\.spec\.ts › CART-010 — The cart looks right/);
});

// ---------------------------------------------------------------------------------------------
// draft · reject · suggest

test('reject: moves the draft into the run directory', () => {
  const ctx = withoutSpec4(setup());
  const run = '.agents/regression/runs/author-t';
  assert.equal(author(ctx, 'draft', 'CART-004', '--run', run).status, 0);
  assert.ok(fs.existsSync(path.join(ctx.root, SPEC4)));
  assert.equal(author(ctx, 'draft', 'CART-004', '--run', run).status, 1, 'a second draft of the same target is refused');
  const r = author(ctx, 'reject', 'CART-004', '--run', run);
  assert.equal(r.status, 0, r.out);
  has(r, /^rejected: CART-004 — \.agents\/regression\/runs\/author-t\/rejected\/cart-004\.spec\.ts$/m);
  assert.equal(fs.existsSync(path.join(ctx.root, SPEC4)), false);
  assert.ok(fs.existsSync(path.join(ctx.root, run, 'rejected/cart-004.spec.ts')));
  has(author(ctx, 'reject', 'CART-005', '--run', run), /^refused: CART-005 — no draft registered/m);
});

test('reject: after a cancelled confirmation the draft is moved and the target is free again', () => {
  const ctx = withoutSpec4(setup());
  const run = '.agents/regression/runs/author-t';
  assert.equal(author(ctx, 'draft', 'CART-004', '--run', run).status, 0);
  has(author(ctx, 'select', 'CART-004'), /^refused: CART-004 — target exists/m);
  assert.equal(author(ctx, 'reject', 'CART-004', '--run', run).status, 0);
  has(author(ctx, 'select', 'CART-004'), /^eligible: CART-004 e2e\/regression\/cart\/cart-004\.spec\.ts$/m);
});

test('reject: refuses a draft that a later claim published', () => {
  const ctx = setup();
  const content = read(ctx, SPEC4);
  fs.rmSync(path.join(ctx.root, SPEC4));
  const run = '.agents/regression/runs/author-t';
  assert.equal(author(ctx, 'draft', 'CART-004', '--run', run).status, 0);
  write(ctx, SPEC4, content);
  const dir = writeVerify(ctx, [{ id: 'CART-004', spec: SPEC4, projects: BOTH }]);
  assert.equal(claim(ctx, 'CART-004', SPEC4, dir, writeCritic(ctx, dir, 'CART-004', SPEC4)).status, 0);
  has(author(ctx, 'reject', 'CART-004', '--run', run), /^refused: CART-004 — already claimed/m);
  assert.ok(fs.existsSync(path.join(ctx.root, SPEC4)));
});

test('suggest: prints the author line for READY scenarios without a spec and nothing when not adopted', () => {
  const ctx = withoutSpec4(setup());
  const r = author(ctx, 'suggest', '--from-qa', QA);
  assert.equal(r.status, 0, r.out);
  assert.equal(r.stdout, `suggest: /regression-tests author --from-qa ${QA} (CART-004)\n`);
  write(ctx, 'fails.md', read(ctx, QA).replace(/^- E2-3\.AC(2|4|5|6) .*\n/gm, ''));
  assert.equal(author(ctx, 'suggest', '--from-qa', 'fails.md').stdout, 'suggest: /regression-tests author CART-008 SRCH-001\n');
  write(ctx, 'none.md', '# notes\n');
  assert.equal(author(ctx, 'suggest', '--from-qa', 'none.md').stdout, '');
  fs.rmSync(path.join(ctx.root, '.claude/regression.json'));
  const off = author(ctx, 'suggest', '--from-qa', QA);
  assert.equal(off.status, 0);
  assert.equal(off.stdout, '');
});
