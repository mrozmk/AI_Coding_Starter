// Unit tests of the regression request guard (.claude/lib/regression/guard.mjs) against a local
// node:http stub with fake Playwright objects — no browser, no network beyond 127.0.0.1. The stub
// is the "environment" here (loopback is refused only as a run TARGET, config.mjs).
import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import http from 'node:http';
import { spawn, spawnSync } from 'node:child_process';
import { fileURLToPath, pathToFileURL } from 'node:url';

import {
  installGuard, newGuardedContext, guardRequestContext, guardedFetch, attestSession, createLedger, ownerLock,
  setCurrentTest, clearCurrentTest,
} from '../regression/guard.mjs';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const GUARD_URL = pathToFileURL(path.join(HERE, '../regression/guard.mjs')).href;
const HEADER = { name: 'x-regression-run', value: 'guard-test' };

// ---------------------------------------------------------------------------------------------
// The stub environment: two origins (two ports on 127.0.0.1)

const hits = [];
let A = '';
let B = '';
const servers = [];

function handler(origin) {
  return (req, res) => {
    const chunks = [];
    req.on('data', (c) => chunks.push(c));
    req.on('end', () => {
      const u = new URL(req.url, 'http://x');
      hits.push({ origin, method: req.method, path: u.pathname, search: u.search, body: Buffer.concat(chunks).toString('utf8'), headers: req.headers });
      const send = (status, body = '', headers = {}) => { res.writeHead(status, headers); res.end(body); };
      switch (u.pathname) {
        case '/ok': return send(200, 'ok');
        case '/r1': return send(302, '', { location: '/r2' });
        case '/r2': return send(302, '', { location: 'http://foreign.invalid/x' });
        case '/rf': return send(302, '', { location: 'http://foreign.invalid/x' });
        case '/r307': return send(307, '', { location: '/sink' });
        case '/r302post': return send(302, '', { location: '/sink' });
        case '/sink': return send(200, 'sunk');
        case '/nav1': return send(302, '', { location: '/page' });
        case '/to-other': return send(302, '', { location: `${B}/echo` });
        case '/echo': return send(200, 'echo');
        case '/forbidden': return send(403, 'no');
        case '/rate': return send(429, 'slow down');
        case '/watched': return send(404, 'gone');
        case '/challenge': return send(200, '<html>please solve the captcha</html>', { 'content-type': 'text/html' });
        case '/price': return send(200, '{"price": 10}', { 'content-type': 'application/json' });
        case '/price-unbounded': return send(200, '{"stock": 1}');
        case '/graphql': return send(200, '{"data": {}}');
        case '/login': return send(200, 'signed in');
        case '/page': return send(200, '<html><body>page</body></html>', { 'content-type': 'text/html' });
        default: return send(404, 'unknown');
      }
    });
  };
}

before(async () => {
  for (const name of ['A', 'B']) {
    const s = http.createServer(handler(name));
    await new Promise((r) => s.listen(0, '127.0.0.1', r));
    servers.push(s);
    const url = `http://127.0.0.1:${s.address().port}`;
    if (name === 'A') A = url; else B = url;
  }
});
after(() => { for (const s of servers) s.close(); });

const hitsOf = (p, origin = 'A') => hits.filter((h) => h.path === p && h.origin === origin);

// ---------------------------------------------------------------------------------------------
// Fake Playwright surface

const SAFE = new Set(['GET', 'HEAD']);
async function nodeFetch(url, { method = 'GET', body, headers = {} } = {}) {
  const r = await fetch(url, { method, headers, body: SAFE.has(method.toUpperCase()) || body === undefined || body === null ? undefined : body, redirect: 'manual' });
  const buf = Buffer.from(await r.arrayBuffer());
  return { status: () => r.status, headers: () => Object.fromEntries(r.headers.entries()), body: async () => buf, text: async () => buf.toString('utf8'), url: () => url };
}

function fakeRequest({ method = 'GET', url, postData, isNavigation = false, headers = {} }) {
  return {
    method: () => method, url: () => url, headers: () => headers,
    postData: () => postData ?? null,
    postDataBuffer: () => (postData === undefined || postData === null ? null : Buffer.from(postData)),
    isNavigationRequest: () => isNavigation,
  };
}

function fakeContext({ ws = true } = {}) {
  const ctx = {
    routes: [], wsRoutes: [], listeners: {},
    route: async (pattern, h) => { ctx.routes.push(h); },
    on: (ev, fn) => { (ctx.listeners[ev] ??= []).push(fn); },
    emit: (ev, arg) => { for (const fn of ctx.listeners[ev] ?? []) fn(arg); },
    // The context's own APIRequestContext: the body is `opts.data` only, never a fallback.
    request: { fetch: (url, opts = {}) => nodeFetch(url, { method: opts.method ?? 'GET', body: opts.data, headers: opts.headers }) },
  };
  if (ws) ctx.routeWebSocket = async (pattern, h) => { ctx.wsRoutes.push(h); };
  return ctx;
}

/** Drive one browser request through the context route; Playwright's route.fetch falls back to the original body. */
async function send(ctx, { method = 'GET', url, postData, isNavigation = false, headers = {} }) {
  const req = fakeRequest({ method, url, postData, isNavigation, headers });
  const outcome = {};
  const route = {
    request: () => req,
    fetch: (opts = {}) => nodeFetch(opts.url ?? url, { method: opts.method ?? method, body: opts.postData ?? postData, headers: opts.headers ?? headers }),
    fulfill: async (o) => { outcome.fulfilled = o; },
    abort: async (code) => { outcome.aborted = code; },
  };
  assert.ok(ctx.routes.length, 'the guard installed a route');
  await ctx.routes[0](route);
  return outcome;
}

let seq = 0;
function manifest(o = {}) {
  const runDir = fs.mkdtempSync(path.join(os.tmpdir(), 'regression-guard-'));
  seq += 1;
  return {
    run_id: `guard-${seq}`, nonce: `nonce-${seq}`, env: 'prod', kind: o.kind ?? 'production', base_url: A,
    workers: 1, pacing: { action_delay_ms: 0, requests_per_minute: o.rpm ?? 0 }, consent: { strategy: 'decline', cookies: [] },
    selection: [], run_dir: runDir, accounts: [],
    policy: {
      hosts: o.hosts ?? ['127.0.0.1'], header: HEADER, operations: o.operations ?? {}, rpc: o.rpc ?? [], budget: o.budget ?? null,
      stop: { statuses: [403, 429], watch_4xx: [], challenge: [], error_signals: [], ...(o.stop ?? {}) },
    },
  };
}

const ledgerOf = (m) => createLedger(m.run_dir, { nonce: m.nonce });
const events = (m, kind) => ledgerOf(m).events().filter((e) => !kind || e.kind === kind);
const stopOf = (m) => { try { return JSON.parse(fs.readFileSync(path.join(m.run_dir, 'stop.json'), 'utf8')); } catch { return null; } };
async function guarded(m, opts) { const ctx = fakeContext(opts); await installGuard(ctx, m); return ctx; }

// ---------------------------------------------------------------------------------------------
// Aborts

test('aborts a host outside the allowlist', async () => {
  const m = manifest();
  const ctx = await guarded(m);
  const out = await send(ctx, { url: 'http://foreign.invalid/x' });
  assert.equal(out.aborted, 'blockedbyclient');
  assert.equal(events(m, 'blocked')[0].reason, 'foreign host');
});

test('aborts a redirect to a foreign host', async () => {
  const m = manifest();
  const ctx = await guarded(m);
  const out = await send(ctx, { url: `${A}/rf` });
  assert.equal(out.aborted, 'blockedbyclient');
  const b = events(m, 'blocked')[0];
  assert.equal(b.reason, 'redirect to foreign host');
  assert.equal(b.url, 'http://foreign.invalid/x');
});

test('aborts the third hop of a redirect chain', async () => {
  const m = manifest();
  const ctx = await guarded(m);
  const r1 = hitsOf('/r1').length;
  const r2 = hitsOf('/r2').length;
  const out = await send(ctx, { url: `${A}/r1`, isNavigation: true });
  assert.equal(out.aborted, 'blockedbyclient');
  assert.equal(hitsOf('/r1').length, r1 + 1, 'hop 1 sent');
  assert.equal(hitsOf('/r2').length, r2 + 1, 'hop 2 sent');
  const b = events(m, 'blocked');
  assert.equal(b.length, 1);
  assert.equal(b[0].reason, 'redirect to foreign host');
  assert.equal(b[0].url, 'http://foreign.invalid/x');
  assert.equal(out.fulfilled, undefined, 'nothing reached the page');
});

test('judges a 307 hop as the original post', async () => {
  const onlyFirst = manifest({ operations: { start: { method: 'POST', url: '/r307$' } } });
  const ctx = await guarded(onlyFirst);
  const sinks = hitsOf('/sink').length;
  const out = await send(ctx, { method: 'POST', url: `${A}/r307`, postData: 'a=1' });
  assert.equal(out.aborted, 'blockedbyclient');
  assert.equal(events(onlyFirst, 'blocked')[0].reason, 'unnamed mutating request');
  assert.equal(hitsOf('/sink').length, sinks, 'the POST hop was never sent');

  const both = manifest({ operations: { start: { method: 'POST', url: '/r307$' }, sink: { method: 'POST', url: '/sink$' } } });
  const ctx2 = await guarded(both);
  const out2 = await send(ctx2, { method: 'POST', url: `${A}/r307`, postData: 'a=1' });
  assert.ok(out2.fulfilled?.response, 'the final response is fulfilled');
  const sink = hitsOf('/sink').at(-1);
  assert.equal(sink.method, 'POST');
  assert.equal(sink.body, 'a=1');
});

test('aborts a popup to a foreign host', async () => {
  const m = manifest();
  const ctx = await guarded(m);
  // A popup belongs to the context: its navigation passes the same context route.
  ctx.emit('page', { url: () => 'about:blank' });
  const out = await send(ctx, { url: 'http://foreign.invalid/popup', isNavigation: true });
  assert.equal(out.aborted, 'blockedbyclient');
  assert.equal(events(m, 'blocked')[0].reason, 'foreign host');
});

test('aborts an unnamed mutating request on production', async () => {
  const m = manifest();
  const ctx = await guarded(m);
  const before = hits.filter((h) => h.path === '/ok' && h.method === 'POST').length;
  const out = await send(ctx, { method: 'POST', url: `${A}/ok`, postData: 'x=1' });
  assert.equal(out.aborted, 'blockedbyclient');
  assert.equal(events(m, 'blocked')[0].reason, 'unnamed mutating request');
  assert.equal(hits.filter((h) => h.path === '/ok' && h.method === 'POST').length, before);
  const t = manifest({ kind: 'test' });
  const tctx = await guarded(t);
  assert.ok((await send(tctx, { method: 'POST', url: `${A}/ok`, postData: 'x=1' })).fulfilled, 'a test environment does not default-deny writes');
});

test('aborts a mutating operation inside an rpc payload', async () => {
  const m = manifest({ rpc: [{ url: '/graphql$', mutating: '\\bmutation\\b' }], operations: { search: { method: 'GET', url: '/graphql' } } });
  const ctx = await guarded(m);
  const out = await send(ctx, { method: 'POST', url: `${A}/graphql`, postData: 'mutation { deleteAccount }' });
  assert.equal(out.aborted, 'blockedbyclient');
  assert.equal(events(m, 'blocked')[0].reason, 'mutating RPC payload');
  const viaGet = await send(ctx, { url: `${A}/graphql?query=mutation%20%7B%20x%20%7D` });
  assert.equal(viaGet.aborted, undefined, 'a named GET operation passes');
  const m2 = manifest({ rpc: [{ url: '/graphql', mutating: 'mutation' }] });
  const ctx2 = await guarded(m2);
  const get = await send(ctx2, { url: `${A}/graphql?query=mutation` });
  assert.equal(get.aborted, 'blockedbyclient', 'a GET whose query string mutates is mutating');
  assert.equal(events(m2, 'blocked')[0].reason, 'mutating RPC payload');
});

test('allows a named operation and rejects a batched extra mutation', async () => {
  const m = manifest({
    rpc: [{ url: '/graphql$', mutating: 'mutation' }],
    operations: { 'cart-add': { method: 'POST', url: '/graphql$', body: 'mutation \\{ addToCart \\}' } },
  });
  const ctx = await guarded(m);
  assert.ok((await send(ctx, { method: 'POST', url: `${A}/graphql`, postData: 'mutation { addToCart }' })).fulfilled);
  const batched = await send(ctx, { method: 'POST', url: `${A}/graphql`, postData: 'mutation { addToCart } mutation { deleteAccount }' });
  assert.equal(batched.aborted, 'blockedbyclient', 'the body regex must match the whole payload');
});

// ---------------------------------------------------------------------------------------------
// Stops

test('reached budget stops the run', async () => {
  const m = manifest({ operations: { price: { method: 'GET', url: '/price', cost: 2, backend_calls: 2 } }, budget: 3 });
  const ctx = await guarded(m);
  assert.ok((await send(ctx, { url: `${A}/price` })).fulfilled);
  const over = await send(ctx, { url: `${A}/price` });
  assert.equal(over.aborted, 'blockedbyclient');
  assert.equal(stopOf(m).reason, 'budget reached');
  const later = await send(ctx, { url: `${A}/ok` });
  assert.equal(later.aborted, 'blockedbyclient', 'every later request is aborted');
  assert.equal(events(m, 'blocked').at(-1).reason, 'stopped');
});

test('watched 4xx stops the run', async () => {
  const m = manifest({ kind: 'test', stop: { watch_4xx: ['/watched$'] } });
  const ctx = await guarded(m);
  const out = await send(ctx, { url: `${A}/watched` });
  assert.equal(out.aborted, 'blockedbyclient');
  assert.equal(stopOf(m).reason, 'watched 4xx 404');
  const other = manifest({ kind: 'test' });
  assert.ok((await send(await guarded(other), { url: `${A}/watched` })).fulfilled, 'an unwatched 404 is a plain response');
});

test('403 and 429 stop the run', async () => {
  for (const [p, code] of [['/forbidden', 403], ['/rate', 429]]) {
    const m = manifest();
    const ctx = await guarded(m);
    const out = await send(ctx, { url: `${A}${p}` });
    assert.equal(out.aborted, 'blockedbyclient');
    assert.equal(stopOf(m).reason, `status ${code}`);
  }
  const c = manifest({ stop: { challenge: ['captcha'] } });
  assert.equal((await send(await guarded(c), { url: `${A}/challenge` })).aborted, 'blockedbyclient');
  assert.equal(stopOf(c).reason, 'challenge page');
});

test('costed operation without backend bound is aborted on production', async () => {
  const m = manifest({ operations: { stock: { method: 'GET', url: '/price-unbounded', cost: 1 } }, budget: 10 });
  const ctx = await guarded(m);
  const before = hitsOf('/price-unbounded').length;
  const out = await send(ctx, { url: `${A}/price-unbounded` });
  assert.equal(out.aborted, 'blockedbyclient');
  assert.equal(stopOf(m).reason, 'no backend upper bound');
  assert.equal(hitsOf('/price-unbounded').length, before, 'never sent');
});

test('queued request rechecks the stop before sending', async () => {
  const m = manifest({ rpm: 60 });
  const ctx = await guarded(m);
  const before = hitsOf('/ok').length;
  assert.ok((await send(ctx, { url: `${A}/ok` })).fulfilled, 'the first request takes the free slot');
  const queued = send(ctx, { url: `${A}/ok` });
  // Another worker (its own ledger on the same run directory) receives a 429 meanwhile.
  createLedger(m.run_dir, { nonce: m.nonce, workerTag: 'other-worker' }).stop('status 429');
  const out = await queued;
  assert.equal(out.aborted, 'blockedbyclient');
  assert.equal(hitsOf('/ok').length, before + 1, 'the queued request was never sent');
  assert.equal(events(m, 'blocked').at(-1).reason, 'stopped');
});

// ---------------------------------------------------------------------------------------------
// WebSockets

function fakeSocket(url) {
  const s = { closed: null, connected: false, url: () => url, close: (o) => { s.closed = o; }, connectToServer: () => { s.connected = true; } };
  return s;
}

test('closes every websocket on production', async () => {
  const m = manifest();
  const ctx = await guarded(m);
  assert.equal(ctx.wsRoutes.length, 1);
  const own = fakeSocket(`${A.replace('http', 'ws')}/socket`);
  ctx.wsRoutes[0](own);
  assert.equal(own.closed?.code, 1008);
  assert.equal(own.connected, false);
  assert.equal(events(m, 'blocked')[0].reason, 'websocket');
  const t = manifest({ kind: 'test' });
  const tctx = await guarded(t);
  const allowed = fakeSocket(`${A.replace('http', 'ws')}/socket`);
  const foreign = fakeSocket('wss://foreign.invalid/socket');
  tctx.wsRoutes[0](allowed);
  tctx.wsRoutes[0](foreign);
  assert.equal(allowed.connected, true, 'test environment: an allowed host connects');
  assert.equal(foreign.closed?.code, 1008, 'test environment: a foreign host is closed');
});

test('stops when websocket routing is unavailable on production', async () => {
  const m = manifest();
  const ctx = fakeContext({ ws: false });
  await assert.rejects(installGuard(ctx, m), /websocket routing unavailable/);
  assert.equal(stopOf(m).reason, 'websocket routing unavailable');
  assert.equal(ctx.routes.length, 0, 'nothing is routed: the run is refused before the first navigation');
});

// ---------------------------------------------------------------------------------------------
// Ledger, attribution, the session channel

test('guarded fetch shares the ledger', async () => {
  const m = manifest({ operations: { 'sign-in': { method: 'POST', url: '/login$', cost: 1, backend_calls: 1 } }, budget: 5 });
  const ctx = await guarded(m);
  await send(ctx, { url: 'http://foreign.invalid/x' });
  const r = await guardedFetch(m, { method: 'POST', url: `${A}/login`, body: 'user=key' }, { tag: 'session:shopper' });
  assert.equal(r.status, 200);
  attestSession(m, 'shopper');
  const kinds = events(m).map((e) => e.kind);
  assert.ok(kinds.includes('blocked') && kinds.includes('budget') && kinds.includes('session'), kinds.join(','));
  assert.equal(JSON.parse(fs.readFileSync(path.join(m.run_dir, 'budget.json'), 'utf8')).reserved, 1, 'sign-in counts in the run budget');
  await assert.rejects(guardedFetch(m, { url: 'http://foreign.invalid/login' }), /regression guard blocked foreign host/);
  assert.equal(events(m, 'session').length, 1, 'only attestSession writes the session attestation');
});

test('records every blocked and budgeted request', async () => {
  const m = manifest({ operations: { price: { method: 'GET', url: '/price', cost: 1, backend_calls: 2 } }, budget: 10 });
  const ctx = await guarded(m);
  await send(ctx, { url: `${A}/price?sku=1` });
  await send(ctx, { url: 'http://foreign.invalid/x?token=secret#frag' });
  await send(ctx, { method: 'DELETE', url: `${A}/ok` });
  const blocked = events(m, 'blocked');
  assert.equal(blocked.length, 2);
  assert.equal(blocked[0].url, 'http://foreign.invalid/x', 'query and fragment dropped');
  assert.equal(blocked[1].method, 'DELETE');
  const budget = events(m, 'budget');
  assert.equal(budget.length, 1);
  assert.equal(budget[0].op, 'price');
  assert.ok(events(m).every((e) => e.nonce === m.nonce));
});

test('a post redirected by 302 is sent as a get without its body', async () => {
  const m = manifest({ kind: 'test' });
  const ctx = await guarded(m);
  const out = await send(ctx, { method: 'POST', url: `${A}/r302post`, postData: 'secret=1', headers: { 'content-type': 'application/x-www-form-urlencoded' } });
  assert.ok(out.fulfilled);
  const sink = hitsOf('/sink').at(-1);
  assert.equal(sink.method, 'GET');
  assert.equal(sink.body, '', 'the second hop carries no body');
  assert.equal(sink.headers['content-type'], undefined);
});

test('collapses a redirected navigation on production', async () => {
  const m = manifest();
  const ctx = await guarded(m);
  const out = await send(ctx, { url: `${A}/nav1`, isNavigation: true });
  assert.ok(out.fulfilled?.response, 'the final response itself is fulfilled');
  assert.equal(out.fulfilled.status, undefined, 'no synthetic 302 on production');
  assert.equal(events(m, 'redirect-collapsed').length, 1);
  const t = manifest({ kind: 'test' });
  const tout = await send(await guarded(t), { url: `${A}/nav1`, isNavigation: true });
  assert.equal(tout.fulfilled.status, 302, 'test environment: the page lands on the verified URL');
  assert.equal(tout.fulfilled.headers.location, `${A}/page`);
  assert.equal(events(t, 'followed-by-browser').length, 1);
});

test('attributes a context created inside a test to that test', async () => {
  const m = manifest();
  setCurrentTest({ testId: 'test-1', id: 'CART-001', project: 'desktop-chrome' });
  try {
    const inner = fakeContext();
    await installGuard(inner, m);
    await send(inner, { url: 'http://foreign.invalid/x' });
  } finally {
    clearCurrentTest();
  }
  assert.equal(events(m, 'blocked')[0].test, 'test-1');
  const installed = events(m, 'installed');
  assert.deepEqual(installed.map((e) => [e.test, e.id, e.project]), [['test-1', 'CART-001', 'desktop-chrome']]);
  const outside = fakeContext();
  await installGuard(outside, m);
  await send(outside, { url: 'http://foreign.invalid/y' });
  assert.equal(events(m, 'blocked').at(-1).test, null, 'outside an active test');
});

// ---------------------------------------------------------------------------------------------
// Locks (owner protocol)

function worker(dir, body) {
  const file = path.join(dir, `worker-${Math.random().toString(16).slice(2)}.mjs`);
  fs.writeFileSync(file, `import { createLedger, ownerLock } from ${JSON.stringify(GUARD_URL)};\n${body}\n`);
  return file;
}

function runWorker(file, args, env = {}) {
  return new Promise((resolve) => {
    const child = spawn(process.execPath, [file, ...args], { env: { ...process.env, ...env } });
    let out = '';
    child.stdout.on('data', (d) => { out += d; });
    child.on('close', (code) => resolve({ code, out: out.trim() }));
  });
}

test('budget lock excludes a second process', async () => {
  const m = manifest();
  const file = worker(m.run_dir, [
    'const [runDir, nonce] = process.argv.slice(2);',
    "const r = createLedger(runDir, { nonce }).reserve('op', 3, 5);",
    'console.log(JSON.stringify(r));',
  ].join('\n'));
  const results = await Promise.all([runWorker(file, [m.run_dir, m.nonce]), runWorker(file, [m.run_dir, m.nonce])]);
  const oks = results.map((r) => JSON.parse(r.out).ok);
  assert.equal(oks.filter(Boolean).length, 1, `exactly one reservation: ${JSON.stringify(results)}`);
  assert.equal(JSON.parse(fs.readFileSync(path.join(m.run_dir, 'budget.json'), 'utf8')).reserved, 3);

  const held = path.join(m.run_dir, 'held.lock');
  fs.mkdirSync(held);
  fs.writeFileSync(path.join(held, 'owner.json'), JSON.stringify({ pid: process.pid, token: 'alive' }));
  const r = ownerLock(held, { pid: 999999 }).acquire();
  assert.equal(r.ok, false, 'a live owner is never reclaimed');
  assert.equal(r.holder.token, 'alive');
});

test('two reclaimers of a dead lock do not both acquire', async () => {
  const m = manifest();
  const lock = path.join(m.run_dir, 'contended.lock');
  const dead = spawnSync(process.execPath, ['--version']).pid;
  fs.mkdirSync(lock);
  fs.writeFileSync(path.join(lock, 'owner.json'), JSON.stringify({ pid: dead, token: 'dead-owner' }));
  const file = worker(m.run_dir, [
    'const r = ownerLock(process.argv[2], { pid: process.pid }).acquire();',
    'console.log(JSON.stringify({ ok: r.ok }));',
    // Hold the lock alive while the other contender looks at it.
    'await new Promise((res) => setTimeout(res, 1500));',
  ].join('\n'));
  const results = await Promise.all([
    runWorker(file, [lock], { REGRESSION_LOCK_PAUSE_MS: '300' }),
    runWorker(file, [lock], { REGRESSION_LOCK_PAUSE_MS: '300' }),
  ]);
  assert.equal(results.map((r) => JSON.parse(r.out).ok).filter(Boolean).length, 1, JSON.stringify(results));
});

test('stale control mutex fails closed', async () => {
  const m = manifest({ operations: { price: { method: 'GET', url: '/price', cost: 1, backend_calls: 1 } }, budget: 10 });
  const control = path.join(m.run_dir, 'budget.lock.control');
  fs.mkdirSync(control);
  fs.writeFileSync(path.join(control, 'pid'), `${spawnSync(process.execPath, ['--version']).pid}\n`);
  const ctx = await guarded(m);
  const out = await send(ctx, { url: `${A}/price` });
  assert.equal(out.aborted, 'blockedbyclient');
  assert.match(stopOf(m).reason, /lock control mutex stale: .*budget\.lock\.control/);
  assert.ok(fs.existsSync(control), 'never removed automatically');
});

// ---------------------------------------------------------------------------------------------
// APIRequestContext and contexts

test('guards the request fixture and page request', async () => {
  const m = manifest();
  const raw = fakeContext().request;
  const wrapped = guardRequestContext(raw, m);
  const before = hits.filter((h) => h.path === '/ok' && h.method === 'POST').length;
  await assert.rejects(wrapped.post(`${A}/ok`, { data: 'x=1' }), /regression guard blocked unnamed mutating request/);
  const ctx = await guarded(m);
  await assert.rejects(ctx.request.post('/ok', { data: 'y=1' }), /regression guard blocked unnamed mutating request/);
  assert.equal(hits.filter((h) => h.path === '/ok' && h.method === 'POST').length, before, 'neither reached the stub');
  assert.equal(events(m, 'blocked').length, 2);
  assert.equal((await ctx.request.get('/ok')).status(), 200, 'a safe request passes');
});

test('drops credentials when a redirect changes origin', async () => {
  const m = manifest({ kind: 'test' });
  const ctx = await guarded(m);
  const out = await send(ctx, { url: `${A}/to-other`, headers: { authorization: 'Bearer secret', cookie: 'sid=1' } });
  assert.ok(out.fulfilled);
  const first = hitsOf('/to-other').at(-1);
  assert.equal(first.headers.authorization, 'Bearer secret', 'hop 1 keeps the original headers');
  const echo = hitsOf('/echo', 'B').at(-1);
  assert.equal(echo.headers.authorization, undefined);
  assert.equal(echo.headers.cookie, undefined);
  assert.equal(echo.headers[HEADER.name], HEADER.value, 'the identifying header is re-added');
});

test('guarded request forces no retries and classifies a 429 first', async () => {
  const m = manifest();
  const calls = [];
  const api = { fetch: (url, opts) => { calls.push(opts); return nodeFetch(url, { method: opts.method, body: opts.data, headers: opts.headers }); } };
  const wrapped = guardRequestContext(api, m);
  const before = hitsOf('/rate').length;
  await assert.rejects(wrapped.get(`${A}/rate`, { maxRetries: 3, failOnStatusCode: true }));
  assert.equal(hitsOf('/rate').length, before + 1, 'one send');
  assert.equal(calls.length, 1);
  assert.equal(calls[0].maxRetries, 0);
  assert.equal(calls[0].failOnStatusCode, false);
  assert.equal(stopOf(m).reason, 'status 429', 'the stop is recorded before the throw');
});

test('guarded context blocks service workers', async () => {
  const m = manifest();
  let captured = null;
  const browser = { newContext: async (o) => { captured = o; return fakeContext(); } };
  const ctx = await newGuardedContext(browser, m, { serviceWorkers: 'allow', locale: 'en-GB' });
  assert.equal(captured.serviceWorkers, 'block');
  assert.equal(captured.locale, 'en-GB');
  assert.equal(ctx.routes.length, 1, 'the guard is installed');
});

test('requests per minute is one ceiling for every guard of the run', async () => {
  const m = manifest({ rpm: 600 }); // one slot per 100 ms
  const api = { fetch: (url, opts) => nodeFetch(url, { method: opts.method, body: opts.data, headers: opts.headers }) };
  const first = guardRequestContext(api, m);
  const second = guardRequestContext(api, m); // another worker's or fixture's guard on the same run
  const t0 = Date.now();
  await first.get(`${A}/ok`);
  await second.get(`${A}/ok`);
  await second.get(`${A}/ok`);
  assert.ok(Date.now() - t0 >= 190, `three requests take three slots across guards (${Date.now() - t0} ms)`);
  assert.ok(fs.existsSync(path.join(m.run_dir, 'pace.json')), 'the next slot lives in the run directory');
});

test('refuses multipart and replays a captured request whole', async () => {
  const m = manifest({ kind: 'test' });
  const calls = [];
  const api = { fetch: (url, opts) => { calls.push({ url, ...opts }); return nodeFetch(url, { method: opts.method, body: opts.data, headers: opts.headers }); } };
  const wrapped = guardRequestContext(api, m);
  await assert.rejects(wrapped.post(`${A}/sink`, { multipart: { file: { name: 'a.txt', mimeType: 'text/plain', buffer: Buffer.from('x') } } }), /multipart unsupported/);
  const form = new FormData();
  form.append('file', new Blob(['x']), 'a.txt');
  await assert.rejects(wrapped.post(`${A}/sink`, { form }), /form with files is unsupported/);
  assert.equal(calls.length, 0, 'nothing was sent');
  const captured = fakeRequest({ method: 'POST', url: `${A}/sink`, postData: 'q=1', headers: { 'x-trace': 't1' } });
  await wrapped.fetch(captured);
  const hit = hitsOf('/sink').at(-1);
  assert.equal(hit.method, 'POST', 'the captured method');
  assert.equal(hit.body, 'q=1', 'the captured body');
  assert.equal(hit.headers['x-trace'], 't1', 'the captured headers');
});
