import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import http from 'node:http';
import { spawn, spawnSync } from 'node:child_process';
import { REQUIRED_CAPABILITY_ASSERTIONS, REQUIRED_ISOLATION, adapterConfigDigest, isolationDeclared, liveReviewerProbe, verifyCapabilities } from '../../harness-source/scripts/preflight.mjs';

const REPO = path.resolve(import.meta.dirname, '../..');
const ADAPTERS = path.join(REPO, 'harness-source/adapters');
const PERMISSIVE = path.join(import.meta.dirname, 'fixtures/adapters/permissive');
const MOCK_BIN = path.join(import.meta.dirname, 'fixtures/mock-bin');
const env = (mode) => ({ PATH: `${MOCK_BIN}${path.delimiter}${path.dirname(process.execPath)}`, HOME: os.homedir(), MOCK_MODE: mode });
const tmp = (p) => fs.mkdtempSync(path.join(os.tmpdir(), p));
const byName = (ev) => Object.fromEntries(ev.assertions.map((a) => [a.name, a]));

test('with isolated adapters and a silent mock reviewer the probe passes; the canary sits at the effective path and its receipt records the tool surface', async () => {
  const receipts = tmp('harness-probe-receipts-');
  const out = path.join(tmp('harness-probe-out-'), 'reviewer-capabilities.json');
  const { evidence, passed } = await liveReviewerProbe({ hosts: ['claude', 'codex'], evidenceOut: out, receiptsDir: receipts, adaptersRootDir: ADAPTERS, env: env('ok') });
  const a = byName(evidence);
  for (const host of ['claude', 'codex']) {
    assert.equal(a[`${host}:isolation-flags-declared`].outcome, 'pass', host);
    assert.equal(a[`${host}:reviewer-completed`].outcome, 'pass', host);
    assert.equal(a[`${host}:no-tool-execution`].outcome, 'pass', host);
    assert.equal(a[`${host}:canary-not-read`].outcome, 'pass', host);
    assert.match(a[`${host}:canary-not-read`].observation, /isolation evidence: no-attempt \(cooperative/, 'absence of a leak is labelled as such, not as an observed denial');
    assert.equal(a[`${host}:unavailable-model-not-ship`].outcome, 'pass');
    const receipt = JSON.parse(fs.readFileSync(path.join(receipts, `${host}-probe-result.json`), 'utf8'));
    assert.ok(receipt.planted_canaries.some((p) => /run-[^/]+\/canary\.txt$/.test(p)), 'canary planted at <run>/canary.txt = ../canary.txt from the reviewer cwd');
    assert.ok(receipt.tool_surface, 'the tool surface the CLI reported is part of the receipt');
  }
  for (const name of ['offline:malformed-output-not-ship', 'offline:empty-output-not-ship', 'offline:contradictory-ship-not-ship', 'offline:tool-activity-not-ship']) assert.equal(a[name].outcome, 'pass', name);
  assert.equal(passed, true);
  assert.deepEqual(verifyCapabilities(out, { adaptersRootDir: ADAPTERS, receiptsDir: receipts }), []);
  assert.ok(evidence.inputs.digest_covers.includes('scripts/review-orchestrator.mjs'));
  await assert.rejects(() => liveReviewerProbe({ hosts: ['claude'], evidenceOut: out, receiptsDir: receipts, adaptersRootDir: ADAPTERS, env: env('ok') }), /never overwritten in place/);
});

test('a deliberately permissive adapter fails the isolation probe', async () => {
  for (const host of ['claude', 'codex']) {
    const d = await isolationDeclared(host, PERMISSIVE);
    assert.equal(d.ok, false, host);
    assert.ok(d.missing.length >= 3, `${host}: ${d.missing.join(', ')}`);
    assert.deepEqual((await isolationDeclared(host, ADAPTERS)).missing, [], host);
  }
  const receipts = tmp('harness-probe-perm-');
  const out = path.join(tmp('harness-probe-perm-out-'), 'reviewer-capabilities.json');
  const { evidence, passed } = await liveReviewerProbe({ hosts: ['claude', 'codex'], evidenceOut: out, receiptsDir: receipts, adaptersRootDir: PERMISSIVE, env: env('ok') });
  assert.equal(passed, false);
  const a = byName(evidence);
  assert.equal(a['claude:isolation-flags-declared'].outcome, 'fail');
  assert.equal(a['codex:isolation-flags-declared'].outcome, 'fail');
  assert.match(a['codex:isolation-flags-declared'].observation, /--sandbox read-only/);
  assert.ok(verifyCapabilities(out, { adaptersRootDir: PERMISSIVE }).some((e) => /isolation-flags-declared/.test(e)), 'the evidence itself records the failure');
  for (const host of ['claude', 'codex']) assert.ok(REQUIRED_ISOLATION[host].length >= 6);
});

test('observed tool activity, a nested spawn or a leaked canary fail the required assertions', async () => {
  const receipts = tmp('harness-probe-tool-');
  const out = path.join(tmp('harness-probe-tool-out-'), 'reviewer-capabilities.json');
  const { evidence, passed } = await liveReviewerProbe({ hosts: ['codex'], evidenceOut: out, receiptsDir: receipts, adaptersRootDir: ADAPTERS, env: env('tool') });
  assert.equal(passed, false);
  const a = byName(evidence);
  assert.equal(a['codex:no-tool-execution'].outcome, 'fail');
  assert.match(a['codex:no-tool-execution'].observation, /tool activity observed/);
  assert.equal(a['codex:reviewer-completed'].outcome, 'pass', 'the model answered; the supervisor rejected it — both facts recorded');
  const sub = await liveReviewerProbe({ hosts: ['claude'], evidenceOut: path.join(tmp('harness-probe-sub-'), 'e.json'), receiptsDir: tmp('harness-probe-sub-r-'), adaptersRootDir: ADAPTERS, env: env('subagent') });
  assert.equal(byName(sub.evidence)['claude:no-nested-cli-spawn'].outcome, 'fail');
  assert.equal(sub.passed, false);
});

test('capability evidence binds adapters AND runner/pack/judge/probe bytes; stale evidence is rejected', () => {
  const { digest, files } = adapterConfigDigest(ADAPTERS);
  assert.ok(files.some((f) => f.path === 'scripts/context-pack.mjs') && files.some((f) => f.path === 'scripts/review-result.mjs') && files.some((f) => f.path === 'adapters/codex-cli/review.mjs'));
  const scripts = tmp('harness-probe-scripts-');
  for (const f of ['review-orchestrator.mjs', 'context-pack.mjs', 'review-result.mjs', 'preflight.mjs']) fs.copyFileSync(path.join(REPO, 'harness-source/scripts', f), path.join(scripts, f));
  assert.equal(adapterConfigDigest(ADAPTERS, { scriptsRoot: scripts }).digest, digest, 'same bytes, same identity');
  fs.appendFileSync(path.join(scripts, 'context-pack.mjs'), '\n// changed\n');
  assert.notEqual(adapterConfigDigest(ADAPTERS, { scriptsRoot: scripts }).digest, digest, 'a pack change invalidates the evidence');
  const old = path.join(REPO, 'docs/harness/reviewer-capabilities.json');
  if (fs.existsSync(old)) {
    const errors = verifyCapabilities(old, { adaptersRootDir: ADAPTERS });
    assert.ok(errors.some((e) => /stale input config_digest|required assertion missing/.test(e)), 'the pre-remediation evidence no longer covers these bytes and says so');
  }
  assert.ok(REQUIRED_CAPABILITY_ASSERTIONS('claude').includes('claude:no-tool-execution'));
});

// --- qa-probe: the argv gate is the permission control ------------------------------------------
// The plugin allowance is a prefix rule over every plugin script, so argv handling is the only thing
// left preserving the narrow-target property the legacy exact-match allow rule gave for free.
const QA_PROBE = path.join(REPO, 'harness-source/scripts/qa-probe.mjs');

function qaFixture(config) {
  const dir = tmp('harness-qa-');
  fs.mkdirSync(path.join(dir, '.claude'), { recursive: true });
  if (config !== null) fs.writeFileSync(path.join(dir, '.claude/qa-env.json'), JSON.stringify(config, null, 2));
  return dir;
}

function probeKeys(stdout) {
  return Object.fromEntries(stdout.split('\n').filter(Boolean).map((l) => {
    const i = l.indexOf(': ');
    return i === -1 ? [l, ''] : [l.slice(0, i), l.slice(i + 2)];
  }));
}

function probeEnv(root, unsetRoot) {
  const e = { PATH: process.env.PATH, HOME: os.homedir() };
  if (!unsetRoot) e.CLAUDE_PROJECT_DIR = root;
  return e;
}

function runProbe(args, { root, cwd = root, unsetRoot = false } = {}) {
  const r = spawnSync(process.execPath, [QA_PROBE, ...args], { cwd, encoding: 'utf8', env: probeEnv(root, unsetRoot) });
  return { ...r, keys: probeKeys(r.stdout) };
}

// Async twin: a resolution case probes an HTTP server living in THIS process, and spawnSync would
// block the event loop that has to accept the connection.
function runProbeAsync(args, { root, cwd = root, unsetRoot = false } = {}) {
  return new Promise((resolve) => {
    const child = spawn(process.execPath, [QA_PROBE, ...args], { cwd, env: probeEnv(root, unsetRoot) });
    let stdout = '';
    let stderr = '';
    child.stdout.on('data', (d) => { stdout += d; });
    child.stderr.on('data', (d) => { stderr += d; });
    child.on('close', (status) => resolve({ status, stdout, stderr, keys: probeKeys(stdout) }));
  });
}

test('qa-probe refuses every target argument, and refuses a project root that is not the session root', () => {
  const home = qaFixture({ base_url: 'https://home.invalid', probe_paths: ['/'] });
  const foreign = qaFixture({ base_url: 'https://foreign.invalid', probe_paths: ['/'] });

  for (const args of [['https://x.invalid'], ['--base-url', 'https://x.invalid'], ['--host', 'x'], ['--project-root']]) {
    const r = runProbe(args, { root: home });
    assert.notEqual(r.status, 0, JSON.stringify(args));
    assert.match(r.stderr, /qa-probe takes no target arguments/, JSON.stringify(args));
    assert.equal(r.stdout, '', 'refused before any configuration is read');
  }

  // Both runs matter, but only the second distinguishes a session-root check from a cwd check: with
  // the process cwd inside the foreign fixture, a cwd-derived "independent" root agrees by
  // construction and the refusal would silently stop happening.
  for (const cwd of [home, foreign]) {
    const r = runProbe(['--project-root', foreign], { root: home, cwd });
    assert.notEqual(r.status, 0, `cwd=${cwd === home ? 'home' : 'foreign'}`);
    assert.match(r.stderr, /qa-probe refuses a project root other than the session root/);
    assert.equal(r.stdout, '', 'refused before the foreign qa-env.json is read');
  }

  const matching = runProbe(['--project-root', home], { root: home });
  assert.equal(matching.status, 0, 'the matching cross-check is accepted');

  const noRoot = runProbe([], { root: home, unsetRoot: true });
  assert.notEqual(noRoot.status, 0);
  assert.match(noRoot.stderr, /qa-probe needs a host session root/);
  assert.equal(noRoot.stdout, '', 'no configuration is read without a session root');
});

test('qa-probe reports a missing config and emits no RESOLVED-* keys on that branch', () => {
  const r = runProbe([], { root: qaFixture(null) });
  assert.equal(r.status, 0, 'a missing config is a reportable state, not a failure');
  assert.match(r.stdout, /^qa-config: MISSING — \.claude\/qa-env\.json not found/);
  // The legacy script returns before emitting any RESOLVED-* key here. Preserved deliberately: an
  // invented resolution on a project with no QA configuration is worse than none.
  assert.equal(Object.keys(r.keys).some((k) => k.startsWith('RESOLVED-')), false);
});

// The resolution table is a contract: prime-qa and qa-verify transcribe RESOLVED-BASE_URL rather
// than deriving a target, so each branch is pinned by value. Emission alone proves nothing.
test('qa-probe pins RESOLVED-BASE_URL and RESOLVED-REASON per resolution branch', async () => {
  const server = http.createServer((req, res) => {
    if (req.url === '/ok') { res.writeHead(200); res.end('ok'); return; }
    if (req.url === '/boom') { res.writeHead(500); res.end('no'); return; }
    if (req.url === '/sha') { res.writeHead(200); res.end('deadbee'); return; }
    res.writeHead(404); res.end();
  });
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  const base = `http://127.0.0.1:${server.address().port}`;
  const dead = 'http://127.0.0.1:1';
  try {
    const healthy = await runProbeAsync([], { root: qaFixture({ base_url: base, probe_paths: ['/ok'] }) });
    assert.equal(healthy.keys['RESOLVED-BASE_URL'], base);
    assert.equal(healthy.keys['RESOLVED-REASON'], 'deployed host reachable on every probe path');
    assert.match(healthy.keys['build-skew'], /^NOT-VERIFIED — no build_sha_url configured/);

    const failed = await runProbeAsync([], { root: qaFixture({ base_url: base, probe_paths: ['/boom'], local_url: dead }) });
    assert.equal(failed.keys['RESOLVED-BASE_URL'], dead, 'a failing deployed host falls back to local_url');
    assert.equal(failed.keys['RESOLVED-REASON'], 'deployed probe /boom returned 500');
    assert.equal(failed.keys['local-host'], `${dead} — down (not serving)`);

    const unreachable = await runProbeAsync([], { root: qaFixture({ base_url: dead, probe_paths: ['/ok'], local_url: base }) });
    assert.equal(unreachable.keys['RESOLVED-BASE_URL'], base);
    assert.equal(unreachable.keys['RESOLVED-REASON'], 'deployed probe /ok unreachable');

    const noPaths = await runProbeAsync([], { root: qaFixture({ base_url: base, probe_paths: [], local_url: base }) });
    assert.equal(noPaths.keys['probe'], 'SKIPPED — probe_paths is empty');
    assert.equal(noPaths.keys['RESOLVED-REASON'], 'no probe_paths configured — an unprobed host is not a verified host');

    const noFallback = await runProbeAsync([], { root: qaFixture({ base_url: '', probe_paths: [] }) });
    assert.equal(noFallback.keys['deployed-host'], 'not configured');
    assert.equal(noFallback.keys['RESOLVED-BASE_URL'], '(none)');
    assert.equal(noFallback.keys['RESOLVED-REASON'], 'no deployed host configured (qa-env.json -> base_url is empty), and no local_url configured — QA cannot observe runtime behaviour');

    const skew = qaFixture({ base_url: base, probe_paths: ['/ok'], build_sha_url: `${base}/sha`, local_url: dead });
    for (const args of [['init', '-q'], ['-c', 'user.email=t@t', '-c', 'user.name=t', 'commit', '-q', '--allow-empty', '-m', 'x']]) {
      spawnSync('git', ['-C', skew, ...args], { encoding: 'utf8' });
    }
    const head = spawnSync('git', ['-C', skew, 'rev-parse', '--short', 'HEAD'], { encoding: 'utf8' }).stdout.trim();
    const mismatch = await runProbeAsync([], { root: skew });
    assert.equal(mismatch.keys['local-HEAD'], head);
    assert.equal(mismatch.keys['build-skew'], `MISMATCH — deployed deadbee != local ${head}`);
    assert.equal(mismatch.keys['RESOLVED-BASE_URL'], dead, 'a stale deployed build is not a verifiable target');
    assert.equal(mismatch.keys['RESOLVED-REASON'], `deployed build SHA deadbee does not match local HEAD ${head}`);
  } finally {
    await new Promise((resolve) => server.close(resolve));
  }
});
