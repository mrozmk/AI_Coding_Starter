// Unit tests of the /wcag-audit runner: no browser, no network, no engine cache required (the one
// cache-dependent sub-case skips visibly when the cache is absent).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import net from 'node:net';
import http from 'node:http';
import { spawn, spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

import * as policy from '../../skills/wcag-audit/runner/lib/policy.mjs';
import { CRITERIA, criteriaFor, axeTags, axeRuleIds, scFromAxeTag } from '../../skills/wcag-audit/runner/lib/criteria.mjs';
import * as ev from '../../skills/wcag-audit/runner/lib/evidence.mjs';
import { merge, fingerprint, nodeKey } from '../../skills/wcag-audit/runner/lib/cluster.mjs';
import { redactUrl, redactText, axExcerpt } from '../../skills/wcag-audit/runner/lib/redact.mjs';
import { writeProbe, writePack, sha256 } from '../../skills/wcag-audit/runner/lib/pack.mjs';
import { ingest } from '../../skills/wcag-audit/runner/lib/ingest.mjs';
import { render } from '../../skills/wcag-audit/runner/lib/render.mjs';
import { STRINGS } from '../../skills/wcag-audit/runner/lib/strings.mjs';
import { RULES, SCHEMAS } from '../../skills/wcag-audit/runner/lib/contract.mjs';
import * as deps from '../../skills/wcag-audit/runner/lib/deps.mjs';
import { startProxy } from '../../skills/wcag-audit/runner/lib/proxy.mjs';
import { Scanner } from '../../skills/wcag-audit/runner/lib/scan.mjs';
import { collectSemantic } from '../../skills/wcag-audit/runner/lib/checks/semantic.mjs';
import arrowWidgets from '../../skills/wcag-audit/runner/lib/checks/arrow-widgets.mjs';
import contrastRender from '../../skills/wcag-audit/runner/lib/checks/contrast-render.mjs';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(HERE, '..', '..', '..');
const SKILL = path.join(ROOT, '.claude', 'skills', 'wcag-audit');
const AUDIT = path.join(SKILL, 'runner', 'audit.mjs');
const GUARD = path.join(SKILL, 'runner', 'read-guard.mjs');

function tmp(prefix = 'wcag-unit-') {
  return fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), prefix)));
}

function mkRepo({ exclude = true } = {}) {
  const dir = tmp('wcag-repo-');
  spawnSync('git', ['init', '-q', dir]);
  if (exclude) fs.appendFileSync(path.join(dir, '.git', 'info', 'exclude'), '.agents/handoffs/*\n');
  fs.mkdirSync(path.join(dir, '.agents', 'handoffs'), { recursive: true });
  return dir;
}

function baseRun({ urls = ['https://example.com/a'], viewports = ['desktop'], wcag = '2.2', level = 'AA', llm = true, contributors = [{ id: 'image-alt', source: 'axe', sc: ['1.1.1'] }] } = {}) {
  const run = ev.newRun({ urls, viewports, wcag, level, llm, tool: { version: 'test' } });
  ev.registerContributors(run, contributors);
  ev.planUnits(run);
  return run;
}

function completeAll(run) {
  ev.completeUnits(run, {});
  run.pages.forEach((p) => { p.status = 'completed'; });
  run.status = 'complete';
}

function writeWork(repo, run, name = 'wcag-audit-t-2026-11-25') {
  const work = path.join(repo, '.agents', 'handoffs', name);
  fs.mkdirSync(path.join(work, 'evidence'), { recursive: true });
  fs.writeFileSync(path.join(work, 'run.json'), JSON.stringify(run, null, 2));
  return work;
}

function readRun(work) {
  return JSON.parse(fs.readFileSync(path.join(work, 'run.json'), 'utf8'));
}

function cli(args, { cwd, env = {} } = {}) {
  return new Promise((resolve) => {
    const child = spawn(process.execPath, [AUDIT, ...args], { cwd, env: { ...process.env, ...env } });
    let stdout = '';
    let stderr = '';
    child.stdout.on('data', (d) => { stdout += d; });
    child.stderr.on('data', (d) => { stderr += d; });
    child.on('close', (code) => {
      let json = null;
      try { json = JSON.parse(stdout.trim().split('\n').pop()); } catch { /* not json */ }
      resolve({ code, json, stdout, stderr });
    });
  });
}

function guard(filePath, { repo, tool = 'Read' } = {}) {
  const r = spawnSync(process.execPath, [GUARD], { input: JSON.stringify({ tool_name: tool, tool_input: { file_path: filePath }, cwd: repo }), env: { ...process.env, CLAUDE_PROJECT_DIR: repo }, encoding: 'utf8' });
  return r.status;
}

function llmRun({ semantic = true } = {}) {
  const run = baseRun();
  ev.addObservation(run, { source: 'axe', contributor: 'image-alt', sc: ['1.1.1'], outcome: 'pass', page: 'p1', viewport: 'desktop' });
  completeAll(run);
  if (semantic) {
    run.semantic_items = [{ item_id: 's1', kind: 'alt-vs-image', evidence_id: 'e1', page: 'p1', viewport: 'desktop', state: 'initial', selector: 'img', text: 'Team photo' }];
    run.evidence = [{ id: 'e1', path: 'evidence/e-1.png' }];
  }
  ev.finalize(run);
  return run;
}

function proveGuard(repo, work) {
  const { probe_denied: probe } = writeProbe(work, repo);
  assert.equal(guard(probe, { repo }), 2);
  return probe;
}

// ---------------------------------------------------------------------------------------------

test('policy classifies destinations by run class and given origins', async () => {
  const origins = new Set(['http://127.0.0.1:8080', 'http://10.1.2.3:80']);
  const d = (host, port, addresses, runClass, o = origins) => policy.decide({ scheme: 'http', host, port: String(port), addresses, runClass, origins: o });
  for (const runClass of ['public', 'loopback', 'private']) assert.equal(d('example.com', 443, ['93.184.216.34'], runClass).allow, true, runClass);
  assert.equal(d('127.0.0.1', 8080, ['127.0.0.1'], 'loopback').allow, true);
  assert.equal(d('127.0.0.1', 9090, ['127.0.0.1'], 'loopback').allow, false);
  assert.equal(d('10.1.2.3', 80, ['10.1.2.3'], 'public').allow, false);
  assert.equal(d('10.1.2.3', 80, ['10.1.2.3'], 'loopback').allow, false);
  assert.equal(d('10.1.2.3', 80, ['10.1.2.3'], 'private').allow, true);
  for (const a of ['169.254.169.254', 'fe80::1', '0.0.0.0', '224.0.0.1']) {
    for (const runClass of ['public', 'loopback', 'private']) assert.equal(d(a, 80, [a], runClass, new Set([`http://${a}:80`])).allow, false, `${a} ${runClass}`);
  }
  assert.equal(policy.addressClass('::ffff:127.0.0.1'), 'loopback');
  assert.equal(d('mixed.test', 80, ['93.184.216.34', '169.254.169.254'], 'public').allow, false);
  assert.throws(() => policy.parseTarget('https://u:p@x.example/'), (e) => e.code === 'credentials-in-url');
  const t = (url, addresses) => ({ url: new URL(url), addresses });
  assert.throws(() => policy.targetClass([t('http://127.0.0.1:1/', ['127.0.0.1']), t('https://example.com/', ['93.184.216.34'])]), (e) => e.code === 'mixed-target-class');
  assert.equal(policy.targetClass([t('http://127.0.0.1:1/', ['127.0.0.1']), t('http://localhost:1/', ['127.0.0.1', '::1'])]), 'loopback');
});

test('axe tag set is cumulative for every request', (t) => {
  assert.deepEqual(axeTags({ wcag: '2.2', level: 'AA' }), ['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa', 'wcag22aa']);
  assert.deepEqual(axeTags({ wcag: '2.2', level: 'A' }), ['wcag2a', 'wcag21a']);
  assert.deepEqual(axeTags({ wcag: '2.1', level: 'AA' }), ['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa']);
  assert.deepEqual(axeTags({ wcag: '2.1', level: 'A' }), ['wcag2a', 'wcag21a']);
  assert.equal(scFromAxeTag('wcag258'), '2.5.8');
  assert.equal(scFromAxeTag('wcag1410'), '1.4.10');
  assert.equal(scFromAxeTag('wcag2aa'), null);
  if (deps.classifyInstall().install !== 'ready') {
    t.skip('engine cache not installed — axeRuleIds sub-case skipped');
    return;
  }
  const { axe } = deps.load();
  const aa22 = axeRuleIds(axe, { wcag: '2.2', level: 'AA' });
  const aa21 = axeRuleIds(axe, { wcag: '2.1', level: 'AA' });
  const a22 = axeRuleIds(axe, { wcag: '2.2', level: 'A' });
  assert.ok(aa22.includes('target-size'));
  assert.ok(!aa21.includes('target-size') && !a22.includes('target-size'));
  for (const list of [aa22, aa21, a22]) {
    for (const bad of ['duplicate-id', 'duplicate-id-active', 'css-orientation-lock']) assert.ok(!list.includes(bad), bad);
  }
  assert.ok(aa22.includes('image-alt') && aa22.includes('autocomplete-valid'));
});

test('criteria table has 55 entries for 2.2 AA and 50 for 2.1 AA', () => {
  assert.equal(criteriaFor({ wcag: '2.2', level: 'AA' }).length, 55);
  assert.equal(criteriaFor({ wcag: '2.1', level: 'AA' }).length, 50);
  assert.equal(criteriaFor({ wcag: '2.2', level: 'A' }).length, 31);
  assert.equal(criteriaFor({ wcag: '2.1', level: 'A' }).length, 30);
  assert.ok(CRITERIA.every((c) => c.slug && c.title && /^(A|AA)$/.test(c.level)));
  assert.ok(criteriaFor({ wcag: '2.1' }).some((c) => c.id === '4.1.1'));
  assert.ok(!criteriaFor({ wcag: '2.2' }).some((c) => c.id === '4.1.1'));
});

test('status aggregation follows the precedence table', () => {
  const status = (outcome, basis) => {
    const run = baseRun();
    ev.addObservation(run, { source: 'axe', contributor: 'image-alt', sc: ['1.1.1'], outcome, basis, page: 'p1', viewport: 'desktop' });
    completeAll(run);
    ev.finalize(run);
    return run.criteria.find((c) => c.id === '1.1.1');
  };
  assert.equal(status('violation').status, 'fails');
  assert.equal(status('needs-review').status, 'suspected');
  assert.equal(status('inapplicable').status, 'n/a');
  const nf = status('pass');
  assert.equal(nf.status, 'no automated failure found');
  assert.equal(nf.ceiling, 'auto-partial');
  const none = baseRun();
  completeAll(none);
  ev.finalize(none);
  assert.equal(none.criteria.find((c) => c.id === '1.2.1').status, 'not tested');
  assert.equal(none.criteria.find((c) => c.id === '1.2.1').reason, 'no contributor');
  assert.equal(none.criteria.find((c) => c.id === '1.2.1').ceiling, 'manual-only');

  const two = (p1) => {
    const run = baseRun({ urls: ['https://example.com/a', 'https://example.com/b'] });
    ev.addObservation(run, { source: 'axe', contributor: 'image-alt', sc: ['1.1.1'], outcome: p1, page: 'p1', viewport: 'desktop' });
    ev.completeUnits(run, { page: 'p1' });
    ev.missUnits(run, { page: 'p2' }, 'page-error');
    run.pages[0].status = 'completed';
    run.pages[1].status = 'error';
    run.status = 'complete';
    ev.finalize(run);
    return run;
  };
  const mixedClean = two('pass').criteria.find((c) => c.id === '1.1.1');
  assert.equal(mixedClean.status, 'not tested');
  assert.match(mixedClean.reason, /partial coverage 1\/2/);
  const mixedFail = two('violation').criteria.find((c) => c.id === '1.1.1');
  assert.equal(mixedFail.status, 'fails');
  assert.match(mixedFail.reason, /partial coverage 1\/2/);

  // A cut own check has no units; the retained engine's ● still fails the criterion.
  const cut = baseRun({ contributors: [{ id: 'focus-order-semantics', source: 'axe', sc: ['2.4.7'] }] });
  ev.addObservation(cut, { source: 'axe', contributor: 'focus-order-semantics', sc: ['2.4.7'], outcome: 'violation', page: 'p1', viewport: 'desktop' });
  completeAll(cut);
  ev.finalize(cut);
  assert.equal(cut.criteria.find((c) => c.id === '2.4.7').status, 'fails');

  const nothing = baseRun();
  nothing.pages[0].status = 'error';
  ev.missUnits(nothing, {}, 'page-error');
  nothing.status = 'complete';
  ev.finalize(nothing);
  assert.equal(nothing.verdict, 'nothing-scanned');

  const onlyHalf = baseRun();
  ev.addObservation(onlyHalf, { source: 'axe', contributor: 'image-alt', sc: ['1.1.1'], outcome: 'needs-review', page: 'p1', viewport: 'desktop' });
  completeAll(onlyHalf);
  ev.finalize(onlyHalf);
  assert.ok(onlyHalf.criteria.every((c) => c.status !== 'fails'));
  assert.equal(onlyHalf.verdict, 'suspected');

  const positive = baseRun();
  ev.addObservation(positive, { source: 'axe', contributor: 'image-alt', sc: ['1.1.1'], outcome: 'pass', page: 'p1', viewport: 'desktop' });
  completeAll(positive);
  ev.finalize(positive);
  assert.equal(positive.verdict, 'positive');
  assert.ok(!JSON.stringify(positive.criteria).includes('passed'));
});

test('merge keeps corroboration and fingerprints are stable', () => {
  const base = { page: 'p1', viewport: 'desktop', state: 'initial', frame: '', shadow: '' };
  const occ = (selector, sc, source, id) => ({ node_key: nodeKey({ ...base, selector }), sc, outcome: 'violation', basis: '●', impact: 'serious', selector, contributors: [{ source, id, sc }], evidence_ids: [], observation_ids: [`${source}-${id}-${selector}`] });
  const same = merge([occ('main > a', ['2.4.7'], 'axe', 'r1'), occ('main > a', ['2.4.7'], 'check', 'focus-visible')]);
  assert.equal(same.length, 1);
  assert.equal(same[0].contributors.length, 2);
  const rows = merge([occ('tr:nth-child(3) button', ['4.1.2'], 'axe', 'button-name'), occ('tr:nth-child(7) button', ['4.1.2'], 'axe', 'button-name')]);
  assert.equal(rows.length, 2);
  assert.notEqual(rows[0].node_key, rows[1].node_key);
  const distinct = merge([occ('main > a', ['2.4.7'], 'axe', 'r1'), occ('main > a', ['1.4.3'], 'axe', 'color-contrast')]);
  assert.equal(distinct.length, 2);
  assert.equal(fingerprint('4.1.2', 'tr:nth-child(3) button', 'https://x/p/123', 'button-name'), fingerprint('4.1.2', 'tr:nth-child(7) button', 'https://x/p/456', 'button-name'));
  assert.notEqual(fingerprint('4.1.2', 'a', 'https://x/p/123', 'button-name'), fingerprint('4.1.2', 'a', 'https://x/q/123', 'button-name'));
});

test('criteria scope filters every source', () => {
  const run = baseRun({ wcag: '2.1', contributors: [{ id: 'focus-obscured', source: 'check', sc: ['2.4.11'] }, { id: 'image-alt', source: 'axe', sc: ['1.1.1'] }] });
  assert.ok(!run.contributors.some((c) => c.id === 'focus-obscured'));
  assert.equal(ev.addObservation(run, { source: 'check', contributor: 'focus-obscured', sc: ['2.4.11'], outcome: 'violation', page: 'p1', viewport: 'desktop' }), null);
  run.semantic_items = [{ item_id: 's1', kind: 'consistent-help', page: 'p1', viewport: 'desktop', state: 'initial' }];
  completeAll(run);
  ev.finalize(run);
  assert.ok(!run.findings.some((f) => f.sc.includes('2.4.11')));
  assert.ok(!run.criteria.some((c) => c.id === '2.4.11' || c.id === '3.2.6'));
  assert.ok(!run.manual.some((m) => m.sc.includes('2.4.11') || m.sc.includes('3.2.6')));
  assert.ok(!run.units.some((u) => u.sc.includes('2.4.11')));
  const a = baseRun({ level: 'A', contributors: [{ id: 'color-contrast', source: 'axe', sc: ['1.4.3'] }, { id: 'image-alt', source: 'axe', sc: ['1.1.1'] }] });
  ev.addObservation(a, { source: 'axe', contributor: 'color-contrast', sc: ['1.4.3'], outcome: 'violation', page: 'p1', viewport: 'desktop' });
  completeAll(a);
  ev.finalize(a);
  const aa = new Set(CRITERIA.filter((c) => c.level === 'AA').map((c) => c.id));
  assert.ok(!a.units.some((u) => u.sc.some((s) => aa.has(s))));
  assert.ok(!a.findings.length);
  assert.ok(!a.manual.some((m) => m.sc.some((s) => aa.has(s))));
});

test('finalize derives the report from observations and upheld candidates', async () => {
  const repo = mkRepo();
  const run = llmRun();
  assert.equal(run.criteria.find((c) => c.id === '1.1.1').status, 'no automated failure found');
  const work = writeWork(repo, run);
  fs.writeFileSync(path.join(work, 'evidence', 'e-1.png'), Buffer.from('89504e470d0a1a0a', 'hex'));
  const before = readRun(work).observations;
  const probe = await cli(['pack', '--work', work, '--phase', 'probe'], { cwd: repo });
  assert.equal(probe.code, 0, probe.stdout + probe.stderr);
  assert.equal(guard(probe.json.probe_denied, { repo }), 2);
  const judge = await cli(['pack', '--work', work, '--phase', 'judge'], { cwd: repo });
  assert.equal(judge.code, 0, judge.stdout);
  const nonce = probe.json.nonce;
  const jf = path.join(repo, 'judge.json');
  fs.writeFileSync(jf, JSON.stringify({ phase: 'judge', nonce, answers: [{ item_id: 's1', sc: '1.1.1', outcome: 'needs-review', impact: 'moderate', rationale: 'alt does not match the crop', false_positive_if: 'the image is decorative' }] }));
  assert.equal((await cli(['ingest', '--work', work, '--phase', 'judge', '--file', jf], { cwd: repo })).code, 0);
  assert.equal((await cli(['pack', '--work', work, '--phase', 'disprove'], { cwd: repo })).code, 0);
  const df = path.join(repo, 'disprove.json');
  fs.writeFileSync(df, JSON.stringify({ phase: 'disprove', nonce, answers: [{ candidate_id: 'c-s1', verdict: 'upheld', reason: 'the crop shows a chart, the alt says team photo' }] }));
  assert.equal((await cli(['ingest', '--work', work, '--phase', 'disprove', '--file', df], { cwd: repo })).code, 0);
  const r = await cli(['render', '--work', work], { cwd: repo });
  assert.equal(r.code, 0, r.stdout + r.stderr);
  const after = readRun(work);
  assert.equal(after.criteria.find((c) => c.id === '1.1.1').status, 'suspected');
  assert.equal(after.verdict, 'suspected');
  assert.deepStrictEqual(after.observations, before);
  const html = fs.readFileSync(r.json.html, 'utf8');
  assert.match(html, /model:alt-vs-image/);
  assert.match(html, /◐ 1\.1\.1/);
});

test('redaction strips query values, fragments and e-mails', () => {
  assert.equal(redactUrl('https://shop.example/p/1?token=abc&q=x#frag'), 'https://shop.example/p/1?token=…&q=…#…');
  assert.equal(redactText('write to jan.kowalski@example.com now'), 'write to [email] now');
  const ex = axExcerpt({ role: { value: 'textbox' }, name: { value: 'E-mail anna@example.com' }, value: { value: 'secret' }, ignored: false });
  assert.equal(ex.role, 'textbox');
  assert.equal(ex.name, 'E-mail [email]');
  assert.ok(!('value' in ex));
});

test('paths are contained under handoffs', async () => {
  const repo = mkRepo();
  const run = llmRun({ semantic: false });
  const outside = path.join(tmp(), 'wcag-audit-x');
  fs.mkdirSync(outside);
  fs.writeFileSync(path.join(outside, 'run.json'), JSON.stringify(run));
  const sentinel = path.join(outside, 'sentinel.txt');
  fs.writeFileSync(sentinel, 'keep');
  const link = path.join(repo, '.agents', 'handoffs', 'wcag-audit-link');
  fs.symlinkSync(outside, link);
  const empty = path.join(repo, '.agents', 'handoffs', 'wcag-audit-empty');
  fs.mkdirSync(empty);
  for (const work of [outside, link]) {
    for (const args of [['pack', '--work', work, '--phase', 'probe'], ['ingest', '--work', work, '--phase', 'judge', '--file', sentinel], ['render', '--work', work]]) {
      const r = await cli(args, { cwd: repo });
      assert.equal(r.code, 3, `${args.join(' ')} → ${r.stdout}`);
      assert.equal(r.json.refusal, 'work-outside-handoffs');
    }
  }
  const e = await cli(['render', '--work', empty], { cwd: repo });
  assert.equal(e.code, 3);
  assert.equal(e.json.refusal, 'bad-work-dir');
  assert.equal(fs.readFileSync(sentinel, 'utf8'), 'keep');
  assert.deepEqual(fs.readdirSync(outside).sort(), ['run.json', 'sentinel.txt']);

  const work = writeWork(repo, run);
  const big = path.join(repo, 'big.json');
  fs.writeFileSync(big, 'x'.repeat(1024 * 1024 + 1));
  const sym = path.join(repo, 'sym.json');
  fs.symlinkSync(big, sym);
  for (const f of [big, sym]) {
    const r = await cli(['ingest', '--work', work, '--phase', 'judge', '--file', f], { cwd: repo });
    assert.equal(r.code, 3);
    assert.equal(r.json.refusal, 'bad-input-file');
  }
  const bad = llmRun({ semantic: false });
  ev.addObservation(bad, { source: 'axe', contributor: 'image-alt', sc: ['1.1.1'], outcome: 'violation', page: 'p1', viewport: 'desktop', evidence_ids: ['e9'] });
  bad.evidence = [{ id: 'e9', path: '../../outside.png' }];
  const w2 = writeWork(repo, bad, 'wcag-audit-crop-2026-11-25');
  const r = await cli(['render', '--work', w2], { cwd: repo });
  assert.equal(r.code, 3, r.stdout);
  assert.equal(r.json.refusal, 'evidence-outside-work');
});

test('read guard allows only manifest paths', () => {
  const repo = mkRepo();
  const work = writeWork(repo, llmRun());
  const allowed = path.join(work, 'pack-judge.json');
  fs.writeFileSync(allowed, '{}');
  const other = path.join(repo, 'secret.txt');
  fs.writeFileSync(other, 'x');
  assert.equal(guard(allowed, { repo }), 2, 'no open pack → deny');
  const lock = path.join(repo, '.agents', 'handoffs', '.wcag-model-lock');
  fs.mkdirSync(lock);
  fs.writeFileSync(path.join(lock, 'lock.json'), JSON.stringify({ nonce: 'n1', work }));
  fs.writeFileSync(path.join(lock, 'manifest.json'), JSON.stringify({ nonce: 'n1', work, allowed: [allowed], probe_denied: path.join(work, 'probe-denied.txt') }));
  assert.equal(guard(allowed, { repo }), 0);
  assert.equal(guard(other, { repo }), 2);
  const link = path.join(repo, 'link.json');
  fs.symlinkSync(allowed, link);
  assert.equal(guard(link, { repo }), 2);
  const dirLink = path.join(repo, 'dirlink');
  fs.symlinkSync(work, dirLink);
  assert.equal(guard(path.join(dirLink, 'pack-judge.json'), { repo }), 2);
  assert.equal(guard(`${work}/../${path.basename(work)}/pack-judge.json`, { repo }), 2);
  assert.equal(guard(other, { repo, tool: 'Bash' }), 0, 'other tools are not this hook\'s business');
  fs.writeFileSync(path.join(lock, 'lock.json'), JSON.stringify({ nonce: 'n2', work: path.join(repo, 'elsewhere') }));
  assert.equal(guard(allowed, { repo }), 2, 'a manifest that is not the lock holder\'s → deny');
  const log = fs.readFileSync(path.join(work, 'read-guard.log'), 'utf8').trim().split('\n').map((l) => JSON.parse(l));
  assert.ok(log.length >= 5);
  assert.ok(log.every((e) => /^[0-9a-f]{64}$/.test(e.path_hash) && !JSON.stringify(e).includes('secret.txt')));
  assert.ok(log.some((e) => e.decision === 'allow') && log.some((e) => e.decision === 'deny'));
});

test('pack judge refuses without a probe denial', () => {
  const repo = mkRepo();
  const work = writeWork(repo, llmRun());
  fs.writeFileSync(path.join(work, 'evidence', 'e-1.png'), 'png');
  const { probe_denied: probe, nonce } = writeProbe(work, repo);
  assert.throws(() => writePack(work, 'judge', repo), (e) => e.code === 'guard-not-proven');
  fs.writeFileSync(path.join(work, 'read-guard.log'), `${JSON.stringify({ nonce: 'other', decision: 'deny', path_hash: sha256(probe) })}\n`);
  assert.throws(() => writePack(work, 'judge', repo), (e) => e.code === 'guard-not-proven');
  assert.equal(guard(probe, { repo }), 2);
  const res = writePack(work, 'judge', repo);
  const pack = JSON.parse(fs.readFileSync(res.pack, 'utf8'));
  assert.equal(pack.trusted.nonce, nonce);
  const items = JSON.parse(pack.untrusted.split('\n')[1]);
  assert.equal(items[0].item_id, 's1');
  assert.equal(items[0].evidence_id, 'e1');
  assert.deepEqual(items[0].allowed_sc, ['1.1.1']);
});

test('pack carries its own answer contract', () => {
  const repo = mkRepo();
  const work = writeWork(repo, llmRun());
  fs.writeFileSync(path.join(work, 'evidence', 'e-1.png'), 'png');
  proveGuard(repo, work);
  const res = writePack(work, 'judge', repo);
  const text = fs.readFileSync(res.pack, 'utf8');
  assert.ok(text.indexOf('"trusted"') < text.indexOf('"untrusted"'));
  const pack = JSON.parse(text);
  assert.deepEqual(pack.trusted.schema, SCHEMAS.judge);
  assert.deepEqual(pack.trusted.rules, RULES.judge);
  assert.ok(pack.trusted.rules.some((r) => /nonce/i.test(r)));
  assert.match(pack.untrusted, new RegExp(`^<<<WCAG-DATA ${pack.trusted.nonce}>>>`));
  const items = JSON.parse(pack.untrusted.split('\n')[1]);
  const manifest = JSON.parse(fs.readFileSync(path.join(repo, '.agents', 'handoffs', '.wcag-model-lock', 'manifest.json'), 'utf8'));
  assert.ok(manifest.allowed.includes(res.pack) && pack.trusted.crops.every((c) => manifest.allowed.includes(c)));
  const answer = path.join(repo, 'a.json');
  fs.writeFileSync(answer, JSON.stringify({ phase: 'judge', nonce: pack.trusted.nonce, answers: items.map((i) => ({ item_id: i.item_id, sc: i.allowed_sc[0], outcome: 'no-issue-seen', impact: 'minor', rationale: 'ok', false_positive_if: 'n/a' })) }));
  assert.equal(ingest(work, 'judge', answer).dropped, 0);
});

test('proxy enforces CONNECT like HTTP', async () => {
  const listen = (handler) => new Promise((resolve) => {
    let count = 0;
    const srv = http.createServer(handler || ((q, s) => s.end('ok')));
    srv.on('connection', () => { count += 1; });
    srv.listen(0, '127.0.0.1', () => resolve({ srv, port: srv.address().port, count: () => count }));
  });
  const allowed = await listen();
  const canary = await listen();
  const ledger = [];
  const origins = new Set([`http://127.0.0.1:${allowed.port}`, `https://127.0.0.1:${allowed.port}`]);
  const proxy = await startProxy({ runClass: 'loopback', origins, ledger });
  const connect = (port) => new Promise((resolve) => {
    const s = net.connect(proxy.port, '127.0.0.1', () => s.write(`CONNECT 127.0.0.1:${port} HTTP/1.1\r\nHost: 127.0.0.1:${port}\r\n\r\n`));
    let buf = '';
    s.on('data', (d) => { buf += d; if (buf.includes('\r\n\r\n')) { s.destroy(); resolve(buf.split('\r\n')[0]); } });
    s.on('error', () => resolve(buf.split('\r\n')[0]));
    s.on('close', () => resolve(buf.split('\r\n')[0]));
  });
  const get = (port) => new Promise((resolve) => {
    const req = http.request({ host: '127.0.0.1', port: proxy.port, method: 'GET', path: `http://127.0.0.1:${port}/x`, headers: { host: `127.0.0.1:${port}` } }, (res) => { res.resume(); res.on('end', () => resolve(res.statusCode)); });
    req.on('error', () => resolve(0));
    req.end();
  });
  try {
    const before = allowed.count();
    assert.match(await connect(allowed.port), / 200 /);
    assert.equal(allowed.count(), before + 1);
    assert.match(await connect(canary.port), / 403 /);
    assert.equal(await get(allowed.port), 200);
    assert.equal(await get(canary.port), 403);
    assert.equal(canary.count(), 0);
    assert.ok(ledger.filter((l) => l.kind === 'destination-blocked').length >= 2);
  } finally {
    await proxy.close();
    allowed.srv.close();
    canary.srv.close();
  }
});

test('planned units survive an unreachable first URL', () => {
  const run = baseRun({ urls: ['https://unreachable.invalid/', 'https://example.com/'], viewports: ['desktop', 'mobile'] });
  for (const p of ['p1', 'p2']) for (const v of ['desktop', 'mobile']) assert.ok(run.units.some((u) => u.page === p && u.viewport === v && u.state === 'initial'));
  ev.missUnits(run, { page: 'p1' }, 'page-error');
  ev.addObservation(run, { source: 'axe', contributor: 'image-alt', sc: ['1.1.1'], outcome: 'pass', page: 'p2', viewport: 'desktop' });
  ev.addObservation(run, { source: 'axe', contributor: 'image-alt', sc: ['1.1.1'], outcome: 'pass', page: 'p2', viewport: 'mobile' });
  ev.completeUnits(run, { page: 'p2' });
  run.pages.forEach((p) => { p.status = p.page === 'p1' ? 'error' : 'completed'; });
  run.status = 'complete';
  ev.finalize(run);
  const c = run.criteria.find((x) => x.id === '1.1.1');
  assert.equal(c.status, 'not tested');
  assert.match(c.reason, /partial coverage 2\/4 — page-error/);
  const only = baseRun({ urls: ['https://unreachable.invalid/'] });
  ev.missUnits(only, {}, 'page-error');
  only.pages[0].status = 'error';
  only.status = 'complete';
  ev.finalize(only);
  assert.equal(only.verdict, 'nothing-scanned');
});

test('only one model phase is active per repository', async () => {
  const repo = mkRepo();
  const a = writeWork(repo, llmRun(), 'wcag-audit-a-2026-11-25');
  const b = writeWork(repo, llmRun(), 'wcag-audit-b-2026-11-25');
  fs.writeFileSync(path.join(a, 'evidence', 'e-1.png'), 'png');
  fs.writeFileSync(path.join(b, 'evidence', 'e-1.png'), 'png');
  proveGuard(repo, a);
  writePack(a, 'judge', repo);
  const busy = await cli(['pack', '--work', b, '--phase', 'probe'], { cwd: repo });
  assert.equal(busy.code, 3);
  assert.equal(busy.json.refusal, 'model-phase-busy');
  assert.equal(guard(path.join(b, 'evidence', 'e-1.png'), { repo }), 2);
  assert.equal(guard(path.join(a, 'pack-judge.json'), { repo }), 0);
  assert.equal((await cli(['render', '--work', a], { cwd: repo })).code, 0);
  const ok = await cli(['pack', '--work', b, '--phase', 'probe'], { cwd: repo });
  assert.equal(ok.code, 0, ok.stdout);
});

test('pack and ingest refuse a run with llm false', () => {
  const repo = mkRepo();
  const run = llmRun();
  run.llm = false;
  const work = writeWork(repo, run);
  const f = path.join(repo, 'x.json');
  fs.writeFileSync(f, '{}');
  assert.throws(() => writeProbe(work, repo), (e) => e.code === 'llm-off');
  assert.throws(() => writePack(work, 'judge', repo), (e) => e.code === 'llm-off');
  assert.throws(() => ingest(work, 'judge', f), (e) => e.code === 'llm-off');
  assert.ok(!fs.existsSync(path.join(repo, '.agents', 'handoffs', '.wcag-model-lock')));
});

function judgeReady(repo) {
  const run = llmRun();
  ev.addObservation(run, { source: 'axe', contributor: 'image-alt', sc: ['1.1.1'], outcome: 'violation', page: 'p1', viewport: 'desktop', selector: 'img.logo' });
  ev.finalize(run);
  run.model.nonce = 'N1';
  run.model.items = [{ item_id: 'i1', kind: 'alt-vs-image', allowed_sc: ['1.1.1'] }, { item_id: 'i2', kind: 'link-purpose', allowed_sc: ['2.4.4'] }, { item_id: 'i3', kind: 'heading-label', allowed_sc: ['2.4.6'] }];
  return writeWork(repo, run);
}

test('ingest drops invalid model output and leaves non-model findings unchanged', () => {
  const repo = mkRepo();
  const work = judgeReady(repo);
  const before = readRun(work).findings;
  const ans = (o) => ({ item_id: 'i1', sc: '1.1.1', outcome: 'needs-review', impact: 'moderate', rationale: 'r', false_positive_if: 'f', ...o });
  const f = path.join(repo, 'j.json');
  fs.writeFileSync(f, JSON.stringify({ phase: 'judge', nonce: 'N1', answers: [ans({ outcome: 'fails' }), ans({ item_id: 'nope' }), ans({ item_id: 'i2', sc: '1.1.1' }), ans({ item_id: before[0].id }), ans({ outcome: 'passed' }), ans({ item_id: 'i3', sc: '2.4.6', outcome: 'compliant' }), { ...ans(), extra: 1 }] }));
  const res = ingest(work, 'judge', f);
  assert.equal(res.dropped, 7);
  assert.equal(res.candidates, 0);
  for (const doc of [{ phase: 'judge', nonce: 'WRONG', answers: [ans()] }, { phase: 'disprove', nonce: 'N1', answers: [ans()] }]) {
    fs.writeFileSync(f, JSON.stringify(doc));
    assert.equal(ingest(work, 'judge', f).candidates, 0);
  }
  const after = readRun(work);
  assert.ok(after.model.dropped.length >= 9);
  assert.ok(after.model.dropped.some((d) => d.reason === 'wrong-nonce') && after.model.dropped.some((d) => d.reason === 'wrong-phase'));
  assert.deepStrictEqual(after.findings.filter((x) => !x.model_item), before);
  assert.ok(!JSON.stringify(after.criteria).match(/passed|compliant/));
});

test('disprove publishes only upheld candidates', () => {
  const repo = mkRepo();
  const work = judgeReady(repo);
  const j = path.join(repo, 'j.json');
  const ans = (id, sc) => ({ item_id: id, sc, outcome: 'needs-review', impact: 'moderate', rationale: 'r', false_positive_if: 'f' });
  fs.writeFileSync(j, JSON.stringify({ phase: 'judge', nonce: 'N1', answers: [ans('i1', '1.1.1'), ans('i2', '2.4.4'), ans('i3', '2.4.6')] }));
  assert.equal(ingest(work, 'judge', j).candidates, 3);
  const d = path.join(repo, 'd.json');
  fs.writeFileSync(d, '{"phase":"disprove","nonce":"N1","answers":[{"candidate_id":"c-i3","verdict":"uph');
  assert.equal(ingest(work, 'disprove', d).published, 0);
  assert.equal(readRun(work).needs_review_queue.length, 3);
  fs.writeFileSync(d, JSON.stringify({ phase: 'disprove', nonce: 'N1', answers: [{ candidate_id: 'c-i2', verdict: 'rejected', reason: 'context names it' }, { candidate_id: 'c-i3', verdict: 'upheld', reason: 'the heading does not describe the section' }] }));
  assert.equal(ingest(work, 'disprove', d).published, 1);
  const run = readRun(work);
  const pub = run.findings.filter((f) => f.model_item);
  assert.equal(pub.length, 1);
  assert.equal(pub[0].basis, '◐');
  assert.deepEqual(pub[0].sc, ['2.4.6']);
  assert.equal(run.criteria.find((c) => c.id === '2.4.6').status, 'suspected');
  assert.deepEqual(run.needs_review_queue.map((q) => q.item_id).sort(), ['i1', 'i2']);
});

function scanTags(html) {
  const tags = [];
  const re = /<([a-zA-Z][\w-]*)((?:\s+[^\s=>"']+(?:\s*=\s*(?:"[^"]*"|'[^']*'|[^\s>"']+))?)*)\s*\/?>/g;
  let m;
  while ((m = re.exec(html))) {
    const attrs = [];
    const are = /([^\s=>"']+)(?:\s*=\s*("([^"]*)"|'([^']*)'|([^\s>"']+)))?/g;
    let a;
    while ((a = are.exec(m[2]))) attrs.push({ name: a[1].toLowerCase(), value: a[3] ?? a[4] ?? a[5] ?? '' });
    tags.push({ name: m[1].toLowerCase(), attrs });
  }
  return tags;
}

test('renderer never prints a conformance word and loads nothing remote', () => {
  const repo = mkRepo();
  const hostile = '<script>alert(1)</script>" onerror="x javascript:alert(1) <img src=http://x>';
  const run = baseRun({ urls: [`https://example.com/${encodeURIComponent('<script>')}`] });
  ev.addObservation(run, { source: 'axe', contributor: 'image-alt', sc: ['1.1.1'], outcome: 'violation', page: 'p1', viewport: 'desktop', selector: hostile, data: { help: hostile, helpUrl: 'javascript:alert(1)' } });
  run.scope.urls = [hostile];
  run.pages[0].url = hostile;
  completeAll(run);
  ev.finalize(run);
  const work = writeWork(repo, run);
  for (const lang of ['en', 'pl']) {
    const html = render(run, { lang, work, legal: JSON.parse(fs.readFileSync(path.join(SKILL, 'legal.json'), 'utf8')) });
    const tags = scanTags(html);
    assert.ok(!tags.some((t) => t.name === 'script'));
    assert.ok(!tags.some((t) => t.attrs.some((a) => a.name.startsWith('on'))));
    for (const t of tags) {
      for (const a of t.attrs) {
        if (a.name === 'src') assert.ok(a.value.startsWith('data:image/png;base64,'), a.value);
        if (a.name === 'href') assert.ok(a.value.startsWith('#') || a.value.startsWith('https://www.w3.org/WAI/WCAG22/Understanding/'), a.value);
      }
    }
    const style = /<style>([\s\S]*?)<\/style>/.exec(html)[1];
    assert.ok(!/url\((?!data:)/.test(style));
    assert.ok(html.includes('&lt;script&gt;') && html.includes('&quot;'));
  }
  const forbidden = /\b(compliant|conformant|passed|certified|zgodn|spełnia)\w*/i;
  for (const lang of ['en', 'pl']) {
    for (const v of Object.values(STRINGS[lang].verdict)) assert.ok(!forbidden.test(v), v);
    for (const v of Object.values(STRINGS[lang].status)) assert.ok(!forbidden.test(v), v);
  }
});

test('legal.json last_verified is valid and every fact has a source', () => {
  const legal = JSON.parse(fs.readFileSync(path.join(SKILL, 'legal.json'), 'utf8'));
  assert.match(legal.last_verified, /^\d{4}-\d{2}-\d{2}$/);
  assert.ok(!Number.isNaN(Date.parse(legal.last_verified)));
  assert.ok(legal.last_verified <= new Date().toISOString().slice(0, 10));
  const sources = fs.readFileSync(path.join(SKILL, 'sources.md'), 'utf8');
  for (const f of legal.facts) {
    assert.deepEqual(Object.keys(f).sort(), ['id', 'source_url', 'text_en', 'text_pl', 'verified']);
    assert.match(f.source_url, /^https:\/\//);
    assert.ok(sources.includes(`\`${f.id}\``), `sources.md row for ${f.id}`);
  }
  for (const ids of Object.values(legal.framings)) for (const id of ids) assert.ok(legal.facts.some((f) => f.id === id), id);
  const run = baseRun();
  run.scope.client = 'microenterprise';
  completeAll(run);
  ev.finalize(run);
  const html = render(run, { lang: 'en', legal });
  assert.ok(html.includes(legal.last_verified));
  assert.ok(html.includes('unverified'));
});

test('deps refuses old node, absent cache and key mismatch', () => {
  const skillDir = tmp();
  fs.writeFileSync(path.join(skillDir, 'package-lock.json'), '{"lockfileVersion":3}');
  const root = path.join(tmp(), 'cache');
  assert.equal(deps.classifyInstall({ root, skillDir }).install, 'absent');
  fs.mkdirSync(root);
  assert.equal(deps.classifyInstall({ root, skillDir }).install, 'absent');
  assert.throws(() => deps.assertReady({ root, skillDir }), (e) => e.code === 'cache-absent');
  assert.throws(() => deps.assertReady({ root, skillDir, nodeVersion: '20.11.0' }), (e) => e.code === 'node-too-old');
  assert.throws(() => deps.assertReady({ root, skillDir, nodeVersion: '22.11.0' }), (e) => e.code === 'node-too-old');
  fs.mkdirSync(path.join(root, 'otherkey'));
  fs.writeFileSync(path.join(root, 'otherkey', 'ready.json'), '{"key":"otherkey"}');
  const st = deps.classifyInstall({ root, skillDir });
  assert.equal(st.install, 'broken');
  assert.equal(st.reason, 'cache-key-mismatch');
  assert.throws(() => deps.assertReady({ root, skillDir }), (e) => e.code === 'cache-key-mismatch');
  const key = deps.cacheKey(fs.readFileSync(path.join(skillDir, 'package-lock.json')));
  fs.mkdirSync(path.join(root, key));
  fs.writeFileSync(path.join(root, key, 'ready.json'), JSON.stringify({ key }));
  assert.match(deps.classifyInstall({ root, skillDir }).reason, /module missing/);
});

test('install.sh and deps.mjs compute the same cache key', () => {
  const dir = tmp();
  fs.copyFileSync(path.join(SKILL, 'install.sh'), path.join(dir, 'install.sh'));
  const lock = '{"name":"x","lockfileVersion":3,"packages":{}}\n';
  fs.writeFileSync(path.join(dir, 'package-lock.json'), lock);
  const r = spawnSync('bash', [path.join(dir, 'install.sh'), '--print-key'], { encoding: 'utf8' });
  assert.equal(r.status, 0, r.stderr);
  assert.equal(r.stdout.trim(), deps.cacheKey(Buffer.from(lock)));
  assert.deepEqual(fs.readdirSync(dir).sort(), ['install.sh', 'package-lock.json']);
});

function judgeAgentContract() {
  const agent = fs.readFileSync(path.join(ROOT, '.claude', 'agents', 'wcag-judge.md'), 'utf8');
  const fm = /^---\n([\s\S]*?)\n---/.exec(agent)[1];
  assert.match(fm, /^tools: Read$/m);
  assert.match(fm, /^hooks:/m);
  assert.match(fm, /read-guard\.mjs/);
  assert.match(fm, /onFailure: block/);
}

function commandTextContract() {
  const cmd = fs.readFileSync(path.join(ROOT, '.claude', 'commands', 'wcag-audit.md'), 'utf8');
  const m = /^### --no-llm path\n([\s\S]*?)(?=^###? |(?![\s\S]))/m.exec(cmd);
  assert.ok(m, 'section ### --no-llm path');
  assert.ok(!m[1].includes('wcag-judge'));
  assert.match(cmd, /audit\.mjs scan --urls-file/);
  assert.ok(!/audit\.mjs scan[^\n]*--urls /.test(cmd));
  assert.match(cmd, /\.agents\/handoffs\/wcag-audit-/);
}

function settingsContract() {
  const settings = JSON.parse(fs.readFileSync(path.join(ROOT, '.claude', 'settings.json'), 'utf8'));
  const allow = settings.permissions.allow;
  const mine = allow.filter((e) => /wcag-audit/.test(e));
  assert.deepEqual(mine, ['Bash(node .claude/skills/wcag-audit/runner/audit.mjs:*)']);
  assert.ok(!allow.some((e) => /^Bash\(npx|npm ci|WebFetch\(domain:\*\)/.test(e)));
  const egress = fs.readFileSync(path.join(ROOT, '.agents', 'reference', 'security-egress.md'), 'utf8');
  const section = egress.split('## Recorded exceptions')[1] || '';
  assert.match(section, /wcag-audit\/runner\/audit\.mjs/);
}

test('judge agent contract holds', () => judgeAgentContract());
test('command text contract holds', () => commandTextContract());
test('settings contract holds', () => settingsContract());
test('command contracts hold', () => { judgeAgentContract(); commandTextContract(); settingsContract(); });

// ---- QA pins (round 1) ----------------------------------------------------------------------

function scanner(Cls, run, opts = {}) {
  return new Cls({ run, work: tmp(), ruleIds: [], ctxInfo: {}, ...opts });
}

test('an abandoned target settles before the scanner moves on', async () => {
  const run = baseRun();
  const seen = [];
  class Slow extends Scanner {
    async scanTarget(url) {
      await new Promise((r) => setTimeout(r, 80));
      seen.push({ page: this.page, viewport: this.viewport });
      await this.prepared('desktop', url);
      seen.push('opened after the time limit');
    }
  }
  await scanner(Slow, run, { pageLimitMs: 20 }).target(0, 'https://example.com/a', 'desktop');
  assert.deepEqual(seen, [{ page: ev.pageKey(0), viewport: 'desktop' }]);
  assert.ok(run.ledger.some((l) => l.kind === 'page-time-limit'));
});

test('the desktop user-agent retry never fires on the proxy refusal', async () => {
  const run = baseRun();
  class Blocked extends Scanner {
    async prepared() { this.calls = (this.calls || 0) + 1; return { error: { status: 403, reason: 'destination-blocked' } }; }
  }
  const s = scanner(Blocked, run);
  await s.target(0, 'https://example.com/a', 'desktop');
  assert.equal(s.calls, 1);
  assert.deepEqual(run.scope.retries, []);
  assert.equal(run.pages.find((p) => p.page === ev.pageKey(0)).reason, 'destination-blocked');
});

test('a broken image needs an HTTP error or a failed load, never an image the lockdown kept unloaded', async () => {
  const names = ['404', 'lazy', 'blocked', 'reset', 'policy', 'tunnel'];
  const imgs = names.map((n, i) => ({ sel: `img:nth-of-type(${i + 1})`, src: `https://x.test/${n}.png`, alt: n, loaded: false, visible: true }));
  const page = { evaluate: async () => ({ imgs, groups: [], outline: [] }) };
  const responses = new Map([['https://x.test/404.png', 404], ['https://x.test/policy.png', 403]]);
  const failed = new Map([['https://x.test/blocked.png', 'net::ERR_BLOCKED_BY_CLIENT'], ['https://x.test/reset.png', 'net::ERR_CONNECTION_RESET'], ['https://x.test/tunnel.png', 'net::ERR_TUNNEL_CONNECTION_FAILED']]);
  const proxyBlocked = new Set(['https://x.test/policy.png']);
  const res = await collectSemantic(page, { responses, failed, proxyBlocked, cdp: null });
  assert.deepEqual(res.broken.map((b) => b.selector), ['img:nth-of-type(1)', 'img:nth-of-type(4)']);
  assert.equal(res.items.filter((i) => i.kind === 'alt-vs-image').length, 0);
});

test('the disprove pack carries each candidate with its own evidence', () => {
  const repo = mkRepo();
  const run = llmRun();
  run.model.items = [{ item_id: 's1', kind: 'alt-vs-image', allowed_sc: ['1.1.1'], evidence_id: 'e1' }];
  run.model.candidates = [{ candidate_id: 'c-s1', item_id: 's1', kind: 'alt-vs-image', sc: '1.1.1', impact: 'moderate', rationale: 'the image shows people, alt says logo', false_positive_if: 'decorative' }];
  const work = writeWork(repo, run);
  fs.writeFileSync(path.join(work, 'evidence', 'e-1.png'), 'png');
  proveGuard(repo, work);
  const pack = JSON.parse(fs.readFileSync(writePack(work, 'disprove', repo).pack, 'utf8'));
  const [row] = JSON.parse(pack.untrusted.split('\n')[1]);
  assert.equal(row.data.text, 'Team photo');
  assert.equal(row.rationale, 'the image shows people, alt says logo');
  assert.equal(row.evidence_id, 'e1');
});

test('an IPv6 literal target is a given origin', () => {
  const origins = policy.givenOrigins([new URL('http://[::1]:8080/')]);
  for (const host of ['::1', '[::1]']) assert.equal(policy.decide({ scheme: 'http', host, port: '8080', addresses: ['::1'], runClass: 'loopback', origins }).allow, true, host);
});

test('selectors from W.sel are resolved through W.q, never document.querySelector', () => {
  const lib = path.join(SKILL, 'runner', 'lib');
  const files = [lib, path.join(lib, 'checks'), path.join(lib, 'engines')].flatMap((d) => fs.readdirSync(d).filter((f) => f.endsWith('.mjs')).map((f) => path.join(d, f)));
  for (const f of files) assert.doesNotMatch(fs.readFileSync(f, 'utf8'), /document\.querySelector\(arg/, f);
});

test('arrow-widgets and contrast-render report a missing unit when nothing was measured', async () => {
  const queue = [['[role=tablist]'], false];
  const page = { evaluate: async () => queue.shift(), keyboard: { press: async () => {} } };
  assert.deepEqual(await arrowWidgets.run({ page }), [{ contributor: 'arrow-widgets', missing: 'not-measured' }]);
  const detached = { locator: () => ({ first: () => ({ evaluate: async () => { throw new Error('detached'); } }) }) };
  assert.deepEqual(await contrastRender.run({ page: detached, axe: [{ rule: 'color-contrast', outcome: 'needs-review', selector: 'p' }] }), [{ contributor: 'contrast-render', missing: 'not-measured' }]);
});
