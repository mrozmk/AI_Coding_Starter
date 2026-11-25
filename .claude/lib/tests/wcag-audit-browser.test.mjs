// Integration tests of /wcag-audit: the runner as a subprocess against the planted-defect fixture,
// served on loopback, with the installed engine cache and Chrome. Offline: the only listeners are
// this file's fixture server and canary.
//
// `node .claude/lib/tests/wcag-audit-browser.test.mjs --serve` starts the fixture server alone.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import http from 'node:http';
import { spawn, spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(HERE, '..', '..', '..');
const FIX = path.join(HERE, 'fixtures', 'wcag-audit');
const AUDIT = path.join(ROOT, '.claude', 'skills', 'wcag-audit', 'runner', 'audit.mjs');
const GUARD = path.join(ROOT, '.claude', 'skills', 'wcag-audit', 'runner', 'read-guard.mjs');
const EXPECTED = JSON.parse(fs.readFileSync(path.join(FIX, 'expected.json'), 'utf8'));
const LONG = { timeout: 600_000 };

const TYPES = { '.html': 'text/html; charset=utf-8', '.css': 'text/css', '.svg': 'image/svg+xml', '.json': 'application/json' };

export async function startServers() {
  const hits = new Map();
  const cookies = [];
  let upgrades = 0;
  let canaryConnections = 0;
  const canary = http.createServer((q, s) => s.end('canary'));
  canary.on('connection', () => { canaryConnections += 1; });
  await new Promise((r) => canary.listen(0, '127.0.0.1', r));
  const canaryPort = canary.address().port;
  let port = 0;
  const server = http.createServer((req, res) => {
    const url = new URL(req.url, 'http://x');
    hits.set(url.pathname, (hits.get(url.pathname) || 0) + 1);
    if (req.headers.cookie) cookies.push(req.headers.cookie);
    if (url.pathname === '/redirect-to-canary') { res.writeHead(302, { location: `http://127.0.0.1:${canaryPort}/redirect` }); return res.end(); }
    if (url.pathname === '/redirect-to-other-origin') { res.writeHead(302, { location: `http://localhost:${port}/framed.html` }); return res.end(); }
    if (url.pathname === '/slow.html') {
      return setTimeout(() => { res.writeHead(200, { 'content-type': TYPES['.html'] }); res.end(fs.readFileSync(path.join(FIX, 'clean.html'))); }, 3000);
    }
    const name = path.basename(url.pathname) || 'clean.html';
    const file = path.join(FIX, name);
    if (!fs.existsSync(file) || !fs.statSync(file).isFile()) { res.writeHead(404, { 'content-type': 'text/plain' }); return res.end('not found'); }
    let body = fs.readFileSync(file);
    if (name.endsWith('.html')) body = Buffer.from(body.toString('utf8').replaceAll('{CANARY}', String(canaryPort)));
    res.writeHead(200, { 'content-type': TYPES[path.extname(name)] || 'application/octet-stream' });
    res.end(body);
  });
  server.on('upgrade', (req, sock) => { upgrades += 1; sock.destroy(); });
  await new Promise((r) => server.listen(0, '127.0.0.1', r));
  port = server.address().port;
  return {
    port, canaryPort, hits, cookies,
    upgrades: () => upgrades,
    canaryConnections: () => canaryConnections,
    url: (p, host = '127.0.0.1') => `http://${host}:${port}/${p}`,
    close: async () => { await new Promise((r) => server.close(r)); await new Promise((r) => canary.close(r)); },
  };
}

function mkRepo({ exclude = true } = {}) {
  const dir = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'wcag-browser-')));
  spawnSync('git', ['init', '-q', dir]);
  if (exclude) fs.appendFileSync(path.join(dir, '.git', 'info', 'exclude'), '.agents/handoffs/*\n');
  fs.mkdirSync(path.join(dir, '.agents', 'handoffs'), { recursive: true });
  return dir;
}

function run(args, { cwd, env = {}, onSpawn } = {}) {
  const tmpdir = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'wcag-tmp-')));
  return new Promise((resolve) => {
    const child = spawn(process.execPath, [AUDIT, ...args], { cwd, env: { ...process.env, TMPDIR: tmpdir, WCAG_AUDIT_TEST: '1', ...env } });
    let stdout = '';
    let stderr = '';
    child.stdout.on('data', (d) => { stdout += d; });
    child.stderr.on('data', (d) => { stderr += d; });
    const killer = setTimeout(() => child.kill('SIGKILL'), 540_000);
    if (onSpawn) onSpawn(child, tmpdir);
    child.on('close', (code) => {
      clearTimeout(killer);
      let json = null;
      try { json = JSON.parse(stdout.trim().split('\n').pop()); } catch { /* not json */ }
      resolve({ code, json, stdout, stderr, tmpdir });
    });
  });
}

async function scan(srv, pages, { flags = ['--no-llm'], env = {}, repo = mkRepo(), viewports = 'desktop', urls = null, onSpawn } = {}) {
  const list = urls || pages.map((p) => srv.url(p));
  const file = path.join(repo, `urls-${Math.random().toString(16).slice(2)}.txt`);
  fs.writeFileSync(file, `${list.join('\n')}\n`);
  const r = await run(['scan', '--urls-file', file, '--slug', 't', '--viewports', viewports, '--max-pages', '50', ...flags], { cwd: repo, env, onSpawn });
  const work = r.json && r.json.work;
  const runJson = work && fs.existsSync(path.join(work, 'run.json')) ? JSON.parse(fs.readFileSync(path.join(work, 'run.json'), 'utf8')) : null;
  return { ...r, repo, work, run: runJson };
}

async function renderOf(res, lang = 'en') {
  const r = await run(['render', '--work', res.work, '--lang', lang], { cwd: res.repo });
  assert.equal(r.code, 0, r.stdout + r.stderr);
  return { html: fs.readFileSync(r.json.html, 'utf8'), json: JSON.parse(fs.readFileSync(r.json.json, 'utf8')) };
}

function pageKeyOf(runJson, file, viewport = 'desktop') {
  const p = runJson.pages.find((x) => x.viewport === viewport && new URL(x.url).pathname.endsWith(`/${file}`));
  return p ? p.page : null;
}

function findingsOf(runJson, file, viewport = 'desktop') {
  const key = pageKeyOf(runJson, file, viewport);
  return runJson.findings.filter((f) => f.page === key && f.viewport === viewport);
}

function hasFinding(list, { check_or_rule: id, sc, basis }) {
  return list.some((f) => f.contributors.some((c) => c.id === id) && f.sc.includes(sc) && (!basis || f.basis === basis));
}

function chromeLines(tmpdir) {
  const r = spawnSync('ps', ['-ax', '-o', 'args='], { encoding: 'utf8' });
  return r.stdout.split('\n').filter((l) => l.includes(tmpdir));
}

function loadPng() {
  // pngjs comes from the engine cache, the same one the runner uses.
  return import(path.join(ROOT, '.claude', 'skills', 'wcag-audit', 'runner', 'lib', 'deps.mjs')).then((d) => d.load().PNG);
}

async function magentaShare(file, box, scale) {
  const PNG = await loadPng();
  const png = PNG.sync.read(fs.readFileSync(file));
  let total = 0;
  let magenta = 0;
  const x0 = Math.max(0, Math.round(box.x * scale) + 1);
  const y0 = Math.max(0, Math.round(box.y * scale) + 1);
  const x1 = Math.min(png.width, Math.round((box.x + box.w) * scale) - 1);
  const y1 = Math.min(png.height, Math.round((box.y + box.h) * scale) - 1);
  for (let y = y0; y < y1; y += 1) {
    for (let x = x0; x < x1; x += 1) {
      const i = (png.width * y + x) * 4;
      total += 1;
      if (png.data[i] > 240 && png.data[i + 1] < 20 && png.data[i + 2] > 240) magenta += 1;
    }
  }
  return total ? magenta / total : 0;
}

if (process.argv.includes('--serve')) {
  const srv = await startServers();
  process.stdout.write(`fixture server: http://127.0.0.1:${srv.port}/clean.html (canary ${srv.canaryPort}) — Ctrl+C to stop\n`);
} else {
  const srvPromise = startServers();
  let bigScan = null;
  const big = async () => {
    const srv = await srvPromise;
    if (!bigScan) bigScan = scan(srv, Object.entries(EXPECTED).filter(([, e]) => e.scan).map(([p]) => p));
    return bigScan;
  };

  test('fixture: planted failures, twins and needs-review items match expected.json', LONG, async () => {
    const res = await big();
    assert.equal(res.code, 0, res.stdout + res.stderr);
    const problems = [];
    for (const [page, exp] of Object.entries(EXPECTED)) {
      if (!exp.scan) continue;
      const list = findingsOf(res.run, page);
      for (const f of exp.findings) if (!hasFinding(list, f)) problems.push(`${page}: missing ${f.check_or_rule} ${f.sc} ${f.basis}`);
      for (const a of exp.absent) if (hasFinding(list, a)) problems.push(`${page}: unexpected ${a.check_or_rule} ${a.sc}`);
    }
    assert.deepEqual(problems, []);
    assert.equal(findingsOf(res.run, 'clean.html').filter((f) => f.basis === '●').length, 0);
  });

  test('clean page verdict is the scan-not-audit sentence', LONG, async () => {
    const srv = await srvPromise;
    const res = await scan(srv, ['clean.html'], { viewports: 'desktop,mobile' });
    assert.equal(res.code, 0, res.stdout + res.stderr);
    const { html, json } = await renderOf(res);
    assert.equal(json.verdict, 'positive', JSON.stringify(json.findings.map((f) => [f.contributors[0].id, f.sc, f.basis])));
    assert.ok(html.includes('No automated failure was found in the scanned pages/states for the criteria marked so, within this coverage. This is a scan, not a conformance audit.'));
    assert.ok(!/passed/i.test(JSON.stringify(json.criteria)) && !/\bpassed\b/i.test(html));
  });

  test('broken image carries its load diagnostic', LONG, async () => {
    const res = await big();
    const f = findingsOf(res.run, 'broken-image.html').find((x) => x.contributors.some((c) => c.id === 'broken-image'));
    assert.ok(f, 'broken-image finding');
    assert.equal(f.data.status, 404);
    assert.match(f.data.url, /\/missing\.png$/);
  });

  test('injection pages produce the outcomes of their control twins', LONG, async () => {
    const srv = await srvPromise;
    const res = await scan(srv, ['inject-visual.html', 'inject-visual-ok.html', 'inject-aria.html', 'inject-aria-ok.html']);
    assert.equal(res.code, 0, res.stdout + res.stderr);
    const outcomes = (file) => {
      const key = pageKeyOf(res.run, file);
      return [...new Set(res.run.observations.filter((o) => o.page === key).map((o) => `${o.contributor}|${o.outcome}|${o.basis}`))].sort();
    };
    assert.deepEqual(outcomes('inject-visual.html'), outcomes('inject-visual-ok.html'));
    assert.deepEqual(outcomes('inject-aria.html'), outcomes('inject-aria-ok.html'));
  });

  test('axe ran cumulative rules and target-size', LONG, async () => {
    const res = await big();
    for (const id of ['image-alt', 'autocomplete-valid', 'target-size']) assert.ok(res.run.engines.axe.executed.includes(id), id);
    const srv = await srvPromise;
    for (const flags of [['--wcag', '2.2', '--level', 'AA'], ['--wcag', '2.1', '--level', 'AA'], ['--wcag', '2.2', '--level', 'A']]) {
      const r = await scan(srv, ['clean.html'], { flags: ['--no-llm', ...flags] });
      assert.equal(r.code, 0, r.stdout);
      const planned = r.run.contributors.filter((c) => c.source === 'axe').map((c) => c.id).sort();
      assert.deepEqual(r.run.engines.axe.executed, planned, flags.join(' '));
      assert.ok(!r.run.units.some((u) => u.contributor.startsWith('axe:') && u.status === 'missing'), flags.join(' '));
    }
  });

  test('browser launched with the sandbox', LONG, async () => {
    const srv = await srvPromise;
    const seen = [];
    let poll = null;
    const res = await scan(srv, ['slow.html'], {
      onSpawn: (child, tmpdir) => { poll = setInterval(() => { seen.push(...chromeLines(tmpdir)); }, 300); },
    });
    clearInterval(poll);
    assert.equal(res.code, 0, res.stdout + res.stderr);
    assert.ok(seen.length >= 1, 'a Chrome of this run was observed');
    assert.ok(!seen.some((l) => l.includes('--no-sandbox')));
    assert.ok(seen.some((l) => l.includes('--force-webrtc-ip-handling-policy=disable_non_proxied_udp')));
    assert.equal(res.run.browser.launch.chromiumSandbox, true);
  });

  test('destination policy: canary receives zero connections', LONG, async () => {
    const srv = await srvPromise;
    const before = srv.hits.get('/egress.html') || 0;
    const res = await scan(srv, ['egress.html']);
    assert.equal(res.code, 0, res.stdout + res.stderr);
    assert.ok((srv.hits.get('/egress.html') || 0) > before);
    assert.equal(srv.canaryConnections(), 0);
    assert.equal(srv.hits.get('/post-sink') || 0, 0);
    const kinds = res.run.ledger.map((l) => l.kind);
    assert.ok(kinds.includes('non-get'));
    assert.ok(kinds.filter((k) => k === 'destination-blocked').length >= 4, JSON.stringify(res.run.ledger));
    assert.equal(res.run.browser.live_probe, 'refused');
    // The images the proxy refused are a coverage limit, not broken images.
    assert.ok(!findingsOf(res.run, 'egress.html').some((f) => f.contributors.some((c) => c.id === 'broken-image')), 'proxy-refused image reported as broken-image');
  });

  test('interaction lockdown: no runner-caused request reaches the server', LONG, async () => {
    const srv = await srvPromise;
    const served = srv.hits.get('/lockdown.html') || 0;
    const res = await scan(srv, ['lockdown.html']);
    assert.equal(res.code, 0, res.stdout + res.stderr);
    await new Promise((r) => setTimeout(r, 2000));
    const rec = res.run.pages.find((p) => p.viewport === 'desktop');
    assert.ok(rec.states.some((s) => s.kind === 'menu' && s.opened), JSON.stringify(rec.states));
    assert.ok(res.run.log.some((l) => l.phase === 'scroll'));
    const kinds = new Set(res.run.ledger.map((l) => l.kind));
    for (const k of ['interaction-lockdown', 'lazy-content-blocked', 'websocket-blocked']) assert.ok(kinds.has(k), k);
    assert.ok((srv.hits.get('/lockdown.html') || 0) - served >= 2);
    for (const p of ['/canary-scroll', '/canary-click', '/canary-late']) assert.equal(srv.hits.get(p) || 0, 0, p);
    assert.equal(srv.upgrades(), 0);
  });

  test('state-bound checks are order-independent', LONG, async () => {
    const srv = await srvPromise;
    const a = await scan(srv, ['trap-ok.html']);
    const b = await scan(srv, ['trap-ok.html'], { env: { WCAG_AUDIT_TEST_CHECK_ORDER: 'reverse' } });
    const pick = (r) => r.run.observations.filter((o) => /^check:(keyboard|text-spacing)/.test(o.contributor)).map((o) => `${o.contributor}|${o.state}|${o.outcome}|${o.selector}`).sort();
    assert.ok(pick(a).length > 0);
    assert.deepEqual(pick(a), pick(b));
  });

  test('semantic items reach the pack without a model', LONG, async () => {
    const srv = await srvPromise;
    const res = await scan(srv, ['broken-image.html', 'photo.html'], { flags: [] });
    assert.equal(res.code, 0, res.stdout + res.stderr);
    const probe = await run(['pack', '--work', res.work, '--phase', 'probe'], { cwd: res.repo });
    assert.equal(probe.code, 0, probe.stdout);
    const g = spawnSync(process.execPath, [GUARD], { input: JSON.stringify({ tool_name: 'Read', tool_input: { file_path: probe.json.probe_denied } }), env: { ...process.env, CLAUDE_PROJECT_DIR: res.repo }, encoding: 'utf8' });
    assert.equal(g.status, 2);
    const judge = await run(['pack', '--work', res.work, '--phase', 'judge'], { cwd: res.repo });
    assert.equal(judge.code, 0, judge.stdout);
    const pack = JSON.parse(fs.readFileSync(judge.json.pack, 'utf8'));
    const items = JSON.parse(pack.untrusted.split('\n')[1]);
    const alt = items.filter((i) => i.kind === 'alt-vs-image');
    assert.equal(alt.length, 1, JSON.stringify(alt));
    assert.equal(alt[0].data.text, 'Team photo');
    assert.ok(alt[0].evidence_id);
    assert.equal(pack.trusted.crops.length >= 1, true);
    const broken = findingsOf(res.run, 'broken-image.html').find((f) => f.contributors.some((c) => c.id === 'broken-image'));
    assert.equal(broken.data.status, 404);
  });

  test('unresolvable host is ledgered, the rest is scanned', LONG, async () => {
    const srv = await srvPromise;
    const env = { WCAG_AUDIT_TEST_DNS_FAIL: 'nowhere.invalid' };
    const res = await scan(srv, [], { urls: ['http://nowhere.invalid/', srv.url('clean.html')], env });
    assert.equal(res.code, 0, res.stdout + res.stderr);
    assert.equal(res.run.pages.find((p) => p.page === 'p2').status, 'completed');
    assert.ok(res.run.units.filter((u) => u.page === 'p1').every((u) => u.status === 'missing' && u.reason === 'dns-failed'));
    const only = await scan(srv, [], { urls: ['http://nowhere.invalid/'], env });
    assert.equal(only.code, 0, only.stdout + only.stderr);
    const { json, html } = await renderOf(only);
    assert.equal(json.verdict, 'nothing-scanned');
    assert.ok(html.includes('Nothing was scanned'));
  });

  test('an interrupted scan still renders', LONG, async () => {
    const srv = await srvPromise;
    const repo = mkRepo();
    let poll = null;
    const res = await scan(srv, ['target.html', 'focus.html', 'spacing.html', 'trap.html', 'reflow.html'], {
      repo,
      onSpawn: (child) => {
        poll = setInterval(() => {
          const dirs = fs.readdirSync(path.join(repo, '.agents', 'handoffs')).filter((d) => d.startsWith('wcag-audit-'));
          for (const d of dirs) {
            try {
              const r = JSON.parse(fs.readFileSync(path.join(repo, '.agents', 'handoffs', d, 'run.json'), 'utf8'));
              if (r.pages.some((p) => p.status === 'completed')) { clearInterval(poll); child.kill('SIGTERM'); }
            } catch { /* mid-write */ }
          }
        }, 200);
      },
    });
    clearInterval(poll);
    const dir = fs.readdirSync(path.join(repo, '.agents', 'handoffs')).find((d) => d.startsWith('wcag-audit-'));
    const work = path.join(repo, '.agents', 'handoffs', dir);
    const r = await run(['render', '--work', work], { cwd: repo });
    assert.equal(r.code, 0, r.stdout + res.stderr);
    const json = JSON.parse(fs.readFileSync(r.json.json, 'utf8'));
    assert.equal(json.verdict, 'partial');
    const done = json.pages.find((p) => p.status === 'completed');
    assert.ok(json.observations.some((o) => o.page === done.page));
    assert.ok(fs.readFileSync(r.json.html, 'utf8').includes('The scan did not complete'));
  });

  test('engine failure on one page leaves partial coverage', LONG, async () => {
    const srv = await srvPromise;
    const res = await scan(srv, ['axe-fault.html', 'clean.html'], { env: { WCAG_AUDIT_TEST_FAULT: 'axe-on:axe-fault.html' } });
    assert.equal(res.code, 0, res.stdout + res.stderr);
    const { json, html } = await renderOf(res);
    const c = json.criteria.find((x) => x.id === '3.1.1');
    assert.equal(c.status, 'not tested');
    assert.match(c.reason, /partial coverage/);
    assert.ok(html.includes('partial coverage'));
  });

  test('runner interactions leave no state on the wire', LONG, async () => {
    const srv = await srvPromise;
    const res = await scan(srv, ['consent-load.html'], { viewports: 'desktop,mobile' });
    assert.equal(res.code, 0, res.stdout + res.stderr);
    assert.ok(res.run.pages.every((p) => p.banner && p.banner.dismissed), JSON.stringify(res.run.pages.map((p) => p.banner)));
    assert.ok(!srv.cookies.some((c) => c.includes('consent=')));
    assert.equal(srv.hits.get('/consent-dependent') || 0, 0);
  });

  test('sandboxed frame is skipped by its document origin', LONG, async () => {
    const srv = await srvPromise;
    const res = await scan(srv, ['sandboxed-frame.html']);
    assert.equal(res.code, 0, res.stdout + res.stderr);
    const skipped = res.run.ledger.filter((l) => l.kind === 'cross-origin-frame-skipped');
    assert.equal(skipped.length, 1, JSON.stringify(skipped));
    const framed = res.run.observations.filter((o) => o.source === 'axe' && o.frame);
    assert.ok(framed.length >= 1, 'the plain frame is analysed');
    assert.ok(framed.every((o) => !/nth-of-type\(1\)|sandboxed/.test(o.frame) || /plain/.test(o.frame)), JSON.stringify(framed.map((o) => o.frame)));
    assert.ok(!JSON.stringify(res.run).includes('jan.kowalski'));
  });

  test('cross-origin frame is skipped and masked', LONG, async () => {
    const srv = await srvPromise;
    const res = await scan(srv, [], { urls: [srv.url('frames.html'), srv.url('nested-frame.html'), srv.url('clean.html', 'localhost')] });
    assert.equal(res.code, 0, res.stdout + res.stderr);
    assert.ok(res.run.ledger.some((l) => l.kind === 'cross-origin-frame-skipped'));
    const key = pageKeyOf(res.run, 'frames.html');
    assert.ok(!res.run.observations.some((o) => o.page === key && o.frame));
    // A cross-origin frame nested inside a same-origin one is classified too: skipped, never analysed.
    const nested = pageKeyOf(res.run, 'nested-frame.html');
    assert.ok(res.run.ledger.some((l) => l.kind === 'cross-origin-frame-skipped' && l.page === nested), JSON.stringify(res.run.ledger));
    assert.ok(!res.run.observations.some((o) => o.page === nested && o.frame));
    assert.ok(!JSON.stringify(res.run).includes('jan.kowalski'));
    const rec = res.run.pages.find((p) => p.page === key);
    const ev = res.run.evidence.find((e) => e.id === rec.page_evidence);
    const box = ev.masked_boxes.find((b) => b.kind === 'skipped-frame');
    assert.ok(box, 'masked frame box recorded');
    assert.ok(await magentaShare(path.join(res.work, ev.path), box, ev.scale) >= 0.9);
  });

  test('contexts are isolated per viewport', LONG, async () => {
    const srv = await srvPromise;
    const res = await scan(srv, ['banner.html'], { viewports: 'desktop,mobile' });
    assert.equal(res.code, 0, res.stdout + res.stderr);
    for (const vp of ['desktop', 'mobile']) {
      const rec = res.run.pages.find((p) => p.viewport === vp);
      assert.ok(rec.banner.detected && rec.banner.dismissed, `${vp}: ${JSON.stringify(rec.banner)}`);
    }
    const label = findingsOf(res.run, 'banner.html').find((f) => f.contributors.some((c) => c.id === 'label'));
    assert.ok(label && (label.ancestor || label.selector).includes('cookie-banner'), JSON.stringify(label));
  });

  test('collection policy: no form value or e-mail leaks', LONG, async () => {
    const srv = await srvPromise;
    const res = await scan(srv, ['pii.html']);
    assert.equal(res.code, 0, res.stdout + res.stderr);
    const { html } = await renderOf(res);
    const text = [JSON.stringify(res.run), html, res.stdout, res.stderr].join('\n');
    for (const s of ['secret-token-123', 'jan.kowalski@example.com']) assert.ok(!text.includes(s), s);
    const f = findingsOf(res.run, 'pii.html').find((x) => x.contributors.some((c) => c.id === 'label'));
    assert.ok(f && f.evidence_ids.length, 'label finding with a crop');
    const ev = res.run.evidence.find((e) => e.id === f.evidence_ids[0]);
    assert.ok(await magentaShare(path.join(res.work, ev.path), ev.el_box, ev.scale) >= 0.9);
  });

  test('browser is closed after a run and after a forced error', LONG, async () => {
    const srv = await srvPromise;
    const ok = await scan(srv, ['clean.html']);
    assert.equal(ok.code, 0);
    assert.deepEqual(chromeLines(ok.tmpdir), []);
    const bad = await scan(srv, ['clean.html'], { env: { WCAG_AUDIT_TEST_FAULT: 'after-launch' } });
    assert.equal(bad.code, 4, bad.stdout);
    await new Promise((r) => setTimeout(r, 500));
    assert.deepEqual(chromeLines(bad.tmpdir), []);
  });

  test('scan refuses when the work path is not ignored', LONG, async () => {
    const srv = await srvPromise;
    const res = await scan(srv, ['clean.html'], { repo: mkRepo({ exclude: false }) });
    assert.equal(res.code, 3, res.stdout);
    assert.equal(res.json.refusal, 'work-not-ignored');
  });

  test('no-llm writes no pack', LONG, async () => {
    const res = await big();
    assert.equal(res.run.llm, false);
    assert.ok(!fs.readdirSync(res.work).some((f) => /^pack-.*\.json$/.test(f)));
  });

  test('stop fixture server', async () => { (await srvPromise).close(); });
}
