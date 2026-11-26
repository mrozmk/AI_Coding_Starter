// The request guard of a regression run: one module the runner config and the fixture import
// (so a guard fix reaches every project through sync; the copied templates only wire it).
// Pure decisions (`decide`, `classifyResponse`), a file ledger in the run directory (guard.jsonl
// events, stop.json, budget.json and pace.json under owner locks), `installGuard` over duck-typed Playwright
// objects (context routing with a per-hop redirect walk, WebSocket blocking on production, the
// guarded APIRequestContext), `guardedFetch` for a session adapter's plain HTTP, `runnerOptions`
// for the config, `stopRun`. No `@playwright/test` import: Playwright objects arrive as arguments.
// Node builtins only — ships to every downstream. Contract: .agents/reference/regression.md §11.
//
// Library only (no CLI). The run manifest (`REGRESSION_RUN`) is written by run.mjs.

import fs from 'node:fs';
import path from 'node:path';
import { randomBytes } from 'node:crypto';

const SAFE_METHODS = new Set(['GET', 'HEAD', 'OPTIONS']);
const MAX_HOPS = 10;
const GUARDED = Symbol.for('regression.guard.installed');
const SLEEPER = new Int32Array(new SharedArrayBuffer(4));
const CONTROL_WAIT_MS = 30000;
const LEDGER_LOCK_WAIT_MS = 30000;
const TITLE_SEP = ' — ';

export class LockError extends Error {}

const sleepSync = (ms) => { if (ms > 0) Atomics.wait(SLEEPER, 0, 0, ms); };
const sleep = (ms) => new Promise((r) => setTimeout(r, Math.max(0, ms)));

// ---------------------------------------------------------------------------------------------
// Manifest and runner options

/** The run manifest run.mjs wrote; throws when the run did not come through /regression-tests. */
export function loadRunManifest(file = process.env.REGRESSION_RUN) {
  if (!file) throw new Error('REGRESSION_RUN is not set — run specs through /regression-tests');
  let manifest;
  try { manifest = JSON.parse(fs.readFileSync(file, 'utf8')); } catch (err) {
    throw new Error(`REGRESSION_RUN is not set — run specs through /regression-tests (manifest ${file} unreadable: ${err.code ?? err.message})`);
  }
  return manifest;
}

const escapeRe = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');

/** The scenario id of a test title `<ID> — <title>` (the text before the separator), or null. */
export const scenarioId = (title) => (typeof title === 'string' && title.includes(TITLE_SEP) ? title.split(TITLE_SEP)[0].trim() : null);

/** Config-side options: workers, a per-project grep of the selected ids, service workers blocked, slowMo. */
export function runnerOptions(manifest) {
  const selection = Array.isArray(manifest.selection) ? manifest.selection : [];
  return {
    workers: manifest.workers ?? 1,
    grepFor(projectName) {
      const ids = [...new Set(selection.filter((c) => c.project === projectName).map((c) => c.id))];
      // A project with no selected case matches nothing: a desktop-only scenario never runs on mobile.
      // `(?!)` fails on every input — `/$^/` would still match an empty string.
      return ids.length ? new RegExp(`(^|\\s)(${ids.map(escapeRe).join('|')})${TITLE_SEP}`) : /(?!)/;
    },
    use: { serviceWorkers: 'block', launchOptions: { slowMo: manifest.pacing?.action_delay_ms ?? 0 } },
  };
}

// ---------------------------------------------------------------------------------------------
// Policy and pure decisions

const re = (s) => new RegExp(s);
const anchored = (s) => new RegExp(`^(?:${s})$`, 's');

/** The manifest's guard policy with every regex compiled once. */
export function compilePolicy(manifest) {
  const g = manifest.policy ?? {};
  const stop = g.stop ?? {};
  return {
    production: (manifest.kind ?? 'production') === 'production',
    hosts: (g.hosts ?? []).map((h) => h.toLowerCase()),
    header: g.header ?? null,
    operations: Object.entries(g.operations ?? {}).map(([name, o]) => ({
      name, method: String(o.method ?? '').toUpperCase(), url: re(o.url), body: o.body !== undefined ? anchored(o.body) : null,
      cost: o.cost, backend_calls: o.backend_calls,
    })),
    rpc: (g.rpc ?? []).map((r) => ({ url: re(r.url), mutating: re(r.mutating) })),
    budget: g.budget ?? null,
    stop: {
      statuses: stop.statuses ?? [403, 429],
      watch_4xx: (stop.watch_4xx ?? []).map(re),
      challenge: (stop.challenge ?? []).map((s) => new RegExp(s, 'i')),
      error_signals: (stop.error_signals ?? []).map((s) => ({ url: re(s.url), body: re(s.body) })),
    },
    rpm: manifest.pacing?.requests_per_minute ?? 0,
  };
}

const hostOf = (url) => { try { return new URL(url).hostname.toLowerCase(); } catch { return ''; } };
const originOf = (url) => { try { return new URL(url).origin; } catch { return ''; } };

export function hostAllowed(policy, url) {
  const h = hostOf(url).replace(/^\[|\]$/g, '');
  if (!h) return false;
  return policy.hosts.some((a) => (a.startsWith('*.') ? h.endsWith(a.slice(1)) : h === a));
}

const bodyText = (b) => (b === undefined || b === null ? '' : Buffer.isBuffer(b) ? b.toString('utf8') : typeof b === 'string' ? b : JSON.stringify(b));

/** The payload a rule judges: the body, or the query string for a GET/HEAD. */
function payloadOf(req) {
  if (SAFE_METHODS.has(req.method.toUpperCase())) { try { return new URL(req.url).search.replace(/^\?/, ''); } catch { return ''; } }
  return bodyText(req.body);
}

/** `{mutating, rpc}` — a non-safe method, or an RPC URL whose payload matches its `mutating` regex. */
export function isMutating(policy, req) {
  const payload = payloadOf(req);
  const rpc = policy.rpc.some((r) => r.url.test(req.url) && r.mutating.test(payload));
  return { mutating: rpc || !SAFE_METHODS.has(req.method.toUpperCase()), rpc };
}

/** The first named operation the request matches (method, url regex, whole-payload body regex), or null. */
export function matchOperation(policy, req) {
  const payload = payloadOf(req);
  return policy.operations.find((o) => o.method === req.method.toUpperCase() && o.url.test(req.url) && (!o.body || o.body.test(payload))) ?? null;
}

/**
 * The guard's decision on one hop BEFORE it is sent: `{action: 'send'|'abort', reason, op, stop?}`.
 * Reserves a costed operation's cost in the ledger (the one side effect).
 */
export function decide(policy, ledger, req, { hop = 1 } = {}) {
  if (ledger.stopped()) return { action: 'abort', reason: 'stopped', op: null };
  if (!hostAllowed(policy, req.url)) return { action: 'abort', reason: hop > 1 ? 'redirect to foreign host' : 'foreign host', op: null };
  const op = matchOperation(policy, req);
  if (policy.production) {
    const m = isMutating(policy, req);
    if (m.mutating && !op) return { action: 'abort', reason: m.rpc ? 'mutating RPC payload' : 'unnamed mutating request', op: null };
  }
  if (op && op.cost !== undefined) {
    if (policy.production && op.backend_calls === undefined) return { action: 'abort', reason: 'no backend upper bound', op: op.name, stop: 'no backend upper bound' };
    const r = ledger.reserve(op.name, op.cost, policy.budget);
    if (!r.ok) return { action: 'abort', reason: r.reason ?? 'budget reached', op: op.name, stop: r.reason ?? 'budget reached' };
  }
  return { action: 'send', reason: null, op: op?.name ?? null };
}

/** `null`, or `{stop: reason}` when the response means the environment pushes back. */
export function classifyResponse(policy, { url, status, headers = {}, body = '' }) {
  if (policy.stop.statuses.includes(status)) return { stop: `status ${status}` };
  if (status >= 400 && status < 500 && policy.stop.watch_4xx.some((r) => r.test(url))) return { stop: `watched 4xx ${status}` };
  if (policy.stop.challenge.length) {
    const text = `${Object.entries(headers).map(([k, v]) => `${k}: ${v}`).join('\n')}\n${bodyText(body)}`;
    if (policy.stop.challenge.some((r) => r.test(text))) return { stop: 'challenge page' };
  }
  if (policy.stop.error_signals.some((s) => s.url.test(url) && s.body.test(bodyText(body)))) return { stop: 'error signal' };
  return null;
}

const needsBody = (policy) => policy.stop.challenge.length > 0 || policy.stop.error_signals.length > 0;

// ---------------------------------------------------------------------------------------------
// Owner lock — every transition under a short-held control mutex `<dir>.control/`

function pidAlive(pid) {
  if (!Number.isInteger(pid) || pid <= 0) return false;
  try { process.kill(pid, 0); return true; } catch (err) { return err.code === 'EPERM'; }
}

export function groupAlive(pgid) {
  if (!Number.isInteger(pgid) || pgid <= 0) return false;
  try { process.kill(-pgid, 0); return true; } catch (err) { return err.code === 'EPERM'; }
}

/** An owner is alive while its pid, or its process group when recorded, still exists. */
export const ownerAlive = (o) => pidAlive(o?.pid) || groupAlive(o?.pgid);

function readJson(file) {
  try { return JSON.parse(fs.readFileSync(file, 'utf8')); } catch { return null; }
}

function writeAtomic(file, value) {
  const tmp = `${file}.tmp`;
  fs.writeFileSync(tmp, `${JSON.stringify(value)}\n`);
  fs.renameSync(tmp, file);
}

/** Run `fn` holding `<dir>.control/`. A control mutex left by a dead pid is never removed: LockError. */
function withControl(dir, fn) {
  const control = `${dir}.control`;
  const deadline = Date.now() + CONTROL_WAIT_MS;
  let missingPidSince = null;
  for (;;) {
    try {
      fs.mkdirSync(control);
      break;
    } catch (err) {
      if (err.code !== 'EEXIST') throw err;
      const raw = (() => { try { return fs.readFileSync(path.join(control, 'pid'), 'utf8').trim(); } catch { return null; } })();
      const pid = Number(raw);
      if (raw !== null && raw !== '' && !pidAlive(pid)) throw new LockError(`lock control mutex stale: ${control}`);
      if (raw === null || raw === '') {
        missingPidSince ??= Date.now();
        // A holder publishes its pid right after mkdir; a pid that never appears is a crashed holder.
        if (Date.now() - missingPidSince > 2000) throw new LockError(`lock control mutex stale: ${control}`);
      }
      if (Date.now() > deadline) throw new LockError(`lock control mutex held too long: ${control}`);
      sleepSync(5);
    }
  }
  try {
    fs.writeFileSync(path.join(control, 'pid'), `${process.pid}\n`);
    return fn();
  } finally {
    try { fs.unlinkSync(path.join(control, 'pid')); } catch { /* already gone */ }
    try { fs.rmdirSync(control); } catch { /* already gone */ }
  }
}

/**
 * The owner lock of `dir` for `owner` (`{pid, pgid?, run_id?}`): `acquire()` →
 * `{ok, token, reclaimed?}` | `{ok:false, holder}` | `{ok:false, unreadable:true}`; `release()`
 * removes only a lock carrying this token; `update(fields)` rewrites the owner (same token).
 * Never reclaimed by age — only when the recorded owner is dead, re-checked under the mutex.
 */
export function ownerLock(dir, owner) {
  let token = null;
  const ownerFile = path.join(dir, 'owner.json');
  const publish = (fields) => writeAtomic(ownerFile, { ...owner, ...fields, token });
  return {
    get token() { return token; },
    acquire() {
      return withControl(dir, () => {
        try {
          fs.mkdirSync(dir, { recursive: false });
        } catch (err) {
          if (err.code !== 'EEXIST') throw err;
          const holder = readJson(ownerFile);
          if (!holder) return { ok: false, unreadable: true };
          if (ownerAlive(holder)) return { ok: false, holder };
          const pause = Number(process.env.REGRESSION_LOCK_PAUSE_MS ?? 0);
          if (pause > 0) sleepSync(pause);
          // Same critical section: the dead owner observed above is the one removed.
          const again = readJson(ownerFile);
          if (!again || again.token !== holder.token) return { ok: false, holder: again ?? holder };
          fs.unlinkSync(ownerFile);
          fs.rmdirSync(dir);
          fs.mkdirSync(dir);
          token = randomBytes(8).toString('hex');
          publish({});
          return { ok: true, token, reclaimed: holder };
        }
        token = randomBytes(8).toString('hex');
        publish({});
        return { ok: true, token };
      });
    },
    update(fields) {
      Object.assign(owner, fields);
      return withControl(dir, () => {
        const cur = readJson(ownerFile);
        if (!cur || cur.token !== token) return false;
        publish({});
        return true;
      });
    },
    release() {
      if (!token) return false;
      return withControl(dir, () => {
        const cur = readJson(ownerFile);
        if (!cur || cur.token !== token) return false;
        fs.unlinkSync(ownerFile);
        fs.rmdirSync(dir);
        token = null;
        return true;
      });
    },
  };
}

// ---------------------------------------------------------------------------------------------
// Ledger (the run directory) and test identity

let currentTest = null;

/** Set by the automatic fixture: every event until `clearCurrentTest()` carries this test. */
export function setCurrentTest(t) { currentTest = t ? { testId: t.testId, id: t.id ?? null, project: t.project ?? null } : null; }
export function clearCurrentTest() { currentTest = null; }

/** origin + path: query and fragment never reach the log. */
export function reduceUrl(url) {
  try { const u = new URL(url); return `${u.origin}${u.pathname}`; } catch { return String(url ?? '').split(/[?#]/)[0]; }
}

/** The file ledger of one run directory, shared by every worker and the session adapter. */
export function createLedger(runDir, { nonce = null, workerTag = `${process.pid}` } = {}) {
  const log = path.join(runDir, 'guard.jsonl');
  const stopFile = path.join(runDir, 'stop.json');
  const budgetFile = path.join(runDir, 'budget.json');
  const paceFile = path.join(runDir, 'pace.json');
  // Run `fn` holding the run-wide owner lock `<runDir>/<name>.lock` (shared by every worker);
  // null when the lock cannot be taken — the run is then stopped, never left unguarded.
  const underLock = (name, fn) => {
    const lock = ownerLock(path.join(runDir, `${name}.lock`), { pid: process.pid, worker: workerTag });
    const deadline = Date.now() + LEDGER_LOCK_WAIT_MS;
    for (;;) {
      let got;
      try { got = lock.acquire(); } catch (err) {
        ledger.stop(err instanceof LockError ? err.message : `${name} lock failed: ${err.message}`);
        return null;
      }
      if (got.ok) break;
      if (got.unreadable) { ledger.stop(`${name} ledger unreadable`); return null; }
      if (Date.now() > deadline) { ledger.stop(`${name} lock timeout`); return null; }
      sleepSync(5);
    }
    try { return fn(); } finally { lock.release(); }
  };
  const ledger = {
    runDir, nonce, workerTag,
    record(event) {
      const e = { t: new Date().toISOString(), nonce, ...event };
      if (e.url) e.url = reduceUrl(e.url);
      fs.appendFileSync(log, `${JSON.stringify(e)}\n`);
      return e;
    },
    stopped() { return fs.existsSync(stopFile); },
    /** The first stop marker, `{reason: 'stop marker unreadable'}` when it does not parse, or null. */
    stopInfo() {
      if (!fs.existsSync(stopFile)) return null;
      return readJson(stopFile) ?? { reason: 'stop marker unreadable' };
    },
    stop(reason, url = null) {
      const first = { t: new Date().toISOString(), nonce, reason, url: url ? reduceUrl(url) : null, worker: workerTag };
      try { fs.writeFileSync(stopFile, `${JSON.stringify(first)}\n`, { flag: 'wx' }); } catch (err) { if (err.code !== 'EEXIST') throw err; }
      ledger.record({ kind: 'stop', reason, url });
    },
    reserve(op, cost, ceiling) {
      const r = underLock('budget', () => {
        let state = { reserved: 0, by_op: {} };
        if (fs.existsSync(budgetFile)) {
          state = readJson(budgetFile);
          if (!state || typeof state.reserved !== 'number') { ledger.stop('budget ledger unreadable'); return { ok: false, reason: 'stopped' }; }
        }
        if (typeof ceiling === 'number' && state.reserved + cost > ceiling) {
          ledger.stop('budget reached');
          return { ok: false, reason: 'budget reached', reserved: state.reserved };
        }
        state.reserved += cost;
        state.by_op[op] = (state.by_op[op] ?? 0) + cost;
        writeAtomic(budgetFile, state);
        ledger.record({ kind: 'budget', op, cost, reserved: state.reserved, test: currentTest?.testId ?? null });
        return { ok: true, reserved: state.reserved };
      });
      return r ?? { ok: false, reason: 'stopped' };
    },
    /** The send time (epoch ms) of the next request under the run's `requests_per_minute`, or null when stopped. */
    paceSlot(intervalMs) {
      return underLock('pace', () => {
        const now = Date.now();
        const at = Math.max(now, readJson(paceFile)?.next ?? 0);
        writeAtomic(paceFile, { next: at + intervalMs });
        return at;
      });
    },
    attest(fields) { return ledger.record({ kind: 'installed', ...fields }); },
    events() {
      if (!fs.existsSync(log)) return [];
      return fs.readFileSync(log, 'utf8').split('\n').filter(Boolean).map((l) => { try { return JSON.parse(l); } catch { return null; } })
        .filter((e) => e && (nonce === null || e.nonce === nonce));
    },
    blockedFor(testId) { return ledger.events().filter((e) => e.kind === 'blocked' && e.test === testId); },
  };
  return ledger;
}

const ledgers = new Map();
function ledgerFor(manifest) {
  const key = `${manifest.run_dir}\0${manifest.nonce}`;
  if (!ledgers.has(key)) ledgers.set(key, createLedger(manifest.run_dir, { nonce: manifest.nonce ?? null }));
  return ledgers.get(key);
}

/** Stop the run from a test or an adapter that recognises an error state the guard cannot see. */
export function stopRun(reason, manifest = loadRunManifest()) {
  ledgerFor(manifest).stop(reason);
}

/** The session adapter's attestation that its sign-in for `account` went through the guard. */
export function attestSession(manifest, account) {
  return ledgerFor(manifest).record({ kind: 'session', account });
}

// ---------------------------------------------------------------------------------------------
// The hop walk (shared by context routing, the guarded APIRequestContext and guardedFetch)

/**
 * The run's throttle: `requests_per_minute` enforced by delaying, never by dropping. The next slot
 * lives in the run directory, so every worker, context and adapter call shares one ceiling.
 */
function makeThrottle(ledger, rpm) {
  return async () => {
    if (!(rpm > 0)) return;
    const at = ledger.paceSlot(60000 / rpm);
    // null = the pace lock failed and the run is stopped: the caller re-checks the stop next.
    if (at !== null) await sleep(at - Date.now());
  };
}

const lowerKeys = (h) => Object.fromEntries(Object.entries(h ?? {}).map(([k, v]) => [k.toLowerCase(), v]));

/** Headers of the next hop: credentials dropped on an origin change, body headers dropped with the body. */
function hopHeaders(prev, { originChanged, bodyDropped, header }) {
  const h = lowerKeys(prev);
  if (originChanged) { delete h.authorization; delete h.cookie; delete h.host; }
  if (bodyDropped) { delete h['content-type']; delete h['content-length']; }
  if (header) h[header.name.toLowerCase()] = header.value;
  return h;
}

/** The next hop after a 3xx, or null when the response is final. */
function nextHop(cur, status, location) {
  if (!(status >= 300 && status < 400) || !location || status === 304) return null;
  let url;
  try { url = new URL(location, cur.url).href; } catch { return null; }
  if (status === 307 || status === 308) return { method: cur.method, url, body: cur.body, bodyDropped: false };
  return { method: 'GET', url, body: undefined, bodyDropped: cur.body !== undefined && cur.body !== null };
}

/**
 * Walk one request's redirect chain, deciding every hop before sending it. `send(hop, headers, n)`
 * returns a response with `status()`, `headers()`, `body()`. Result: `{response, final, hops}` or
 * `{aborted: reason, stop?}` (already recorded) or `{failed: message}`.
 */
async function walk(g, first, send) {
  const { policy, ledger } = g;
  let cur = { method: first.method.toUpperCase(), url: first.url, body: first.body };
  let headers = hopHeaders(first.headers, { header: policy.header });
  for (let n = 1; ; n += 1) {
    const test = currentTest?.testId ?? null;
    if (n > MAX_HOPS) {
      ledger.record({ kind: 'blocked', reason: 'redirect chain too long', method: cur.method, url: cur.url, op: null, test });
      return { aborted: 'redirect chain too long' };
    }
    const d = decide(policy, ledger, cur, { hop: n });
    if (d.action === 'abort') {
      ledger.record({ kind: 'blocked', reason: d.reason, method: cur.method, url: cur.url, op: d.op, test });
      // `reserve` has already persisted a budget stop; the backend-bound stop is persisted here.
      if (d.stop && !ledger.stopped()) ledger.stop(d.stop, cur.url);
      return { aborted: d.reason, stop: d.stop };
    }
    await g.throttle();
    // Another worker may have stopped the run while this request waited for its slot.
    if (ledger.stopped()) {
      ledger.record({ kind: 'blocked', reason: 'stopped', method: cur.method, url: cur.url, op: d.op, test });
      return { aborted: 'stopped' };
    }
    let resp;
    try { resp = await send(cur, headers, n); } catch (err) {
      ledger.record({ kind: 'failed', reason: 'network error', method: cur.method, url: cur.url, op: d.op, test });
      return { failed: err.message };
    }
    const status = resp.status();
    const rh = lowerKeys(resp.headers());
    const body = needsBody(policy) ? bodyText(await resp.body()) : '';
    const c = classifyResponse(policy, { url: cur.url, status, headers: rh, body });
    if (c) {
      ledger.stop(c.stop, cur.url);
      return { aborted: 'stopped', stop: c.stop };
    }
    const next = nextHop(cur, status, rh.location);
    if (!next) return { response: resp, final: cur, hops: n };
    headers = hopHeaders(headers, { originChanged: originOf(next.url) !== originOf(cur.url), bodyDropped: next.bodyDropped, header: policy.header });
    cur = { method: next.method, url: next.url, body: next.body };
  }
}

function guardState(manifest) {
  const policy = compilePolicy(manifest);
  const ledger = ledgerFor(manifest);
  return { policy, ledger, throttle: makeThrottle(ledger, policy.rpm) };
}

// ---------------------------------------------------------------------------------------------
// Playwright wiring (duck-typed)

function attestCase(g, context, testInfo) {
  const t = testInfo ? { testId: testInfo.testId, id: scenarioId(testInfo.title), project: testInfo.project?.name ?? null } : currentTest;
  if (!t?.testId) return;
  context[GUARDED].attested ??= new Set();
  if (context[GUARDED].attested.has(t.testId)) return;
  context[GUARDED].attested.add(t.testId);
  g.ledger.attest({ test: t.testId, id: t.id, project: t.project });
}

async function routeHandler(g, raw, route) {
  const req = route.request();
  const first = { method: req.method(), url: req.url(), body: req.postDataBuffer?.() ?? req.postData?.() ?? undefined, headers: req.headers() };
  const navigation = typeof req.isNavigationRequest === 'function' && req.isNavigationRequest();
  const result = await walk(g, first, (hop, headers, n) => (n === 1
    ? route.fetch({ headers, maxRedirects: 0 })
    // Later hops: the context's own request client — `route.fetch` would fall back to the
    // original request's body when no postData is given, so the bytes judged are the bytes sent.
    : raw.fetch(hop.url, { method: hop.method, data: hop.body ?? undefined, headers, maxRedirects: 0, maxRetries: 0, failOnStatusCode: false })));
  if (result.aborted) return route.abort('blockedbyclient');
  if (result.failed) return route.abort('failed');
  const test = currentTest?.testId ?? null;
  if (result.hops > 1 && navigation && !g.policy.production && result.final.method === 'GET') {
    // Test environments: the page lands on the verified final URL; the browser's follow-up GET is
    // the one hop not routed (regression.md §11) — recorded, reserved again when costed.
    g.ledger.record({ kind: 'followed-by-browser', url: result.final.url, test });
    const op = matchOperation(g.policy, result.final);
    if (op && op.cost !== undefined) {
      const r = g.ledger.reserve(op.name, op.cost, g.policy.budget);
      if (!r.ok) return route.abort('blockedbyclient');
    }
    return route.fulfill({ status: 302, headers: { location: result.final.url } });
  }
  if (result.hops > 1 && navigation) g.ledger.record({ kind: 'redirect-collapsed', url: first.url, test });
  return route.fulfill({ response: result.response });
}

function webSocketHandler(g) {
  return (ws) => {
    const url = typeof ws.url === 'function' ? ws.url() : '';
    if (g.policy.production || !hostAllowed(g.policy, url.replace(/^ws/, 'http'))) {
      g.ledger.record({ kind: 'blocked', reason: 'websocket', method: 'WS', url, op: null, test: currentTest?.testId ?? null });
      return ws.close({ code: 1008, reason: 'regression guard' });
    }
    return ws.connectToServer();
  };
}

/**
 * Guard a browser context before its first navigation: route every request through the hop walk,
 * close WebSockets on production (no `routeWebSocket` there → the run stops), replace
 * `context.request` with the guarded client. Idempotent; attests the current test once per context.
 */
export function installGuard(context, manifest, { testInfo } = {}) {
  return (async () => {
    if (context[GUARDED]) {
      attestCase(context[GUARDED].g, context, testInfo);
      return context;
    }
    const g = guardState(manifest);
    if (g.ledger.stopped()) throw new Error('regression guard: the run is stopped');
    if (g.policy.production && typeof context.routeWebSocket !== 'function') {
      g.ledger.stop('websocket routing unavailable');
      throw new Error('regression guard: websocket routing unavailable — production is refused rather than run unguarded');
    }
    const raw = context.request;
    Object.defineProperty(context, GUARDED, { value: { g }, enumerable: false, configurable: true });
    if (typeof context.routeWebSocket === 'function') await context.routeWebSocket(/.*/, webSocketHandler(g));
    await context.route('**/*', (route) => routeHandler(g, raw, route));
    if (raw) {
      const guarded = guardRequestContext(raw, manifest, { state: g });
      Object.defineProperty(context, 'request', { value: guarded, configurable: true, writable: true });
    }
    attestCase(g, context, testInfo);
    return context;
  })();
}

/** The only way a session adapter (or the fixture's wrapper) creates a context. */
export async function newGuardedContext(browser, manifest, options = {}) {
  const context = await browser.newContext({ ...options, serviceWorkers: 'block' });
  await installGuard(context, manifest);
  return context;
}

/** The body the guard judges and sends; a request it cannot judge byte for byte is refused, never altered. */
function requestBody(opts, request) {
  if (opts.multipart !== undefined) throw new Error('regression guard: multipart unsupported — send data or form');
  if (opts.data !== undefined) return { body: opts.data, extra: {} };
  if (opts.form !== undefined) {
    const entries = typeof opts.form.entries === 'function' ? [...opts.form.entries()] : Object.entries(opts.form);
    if (entries.some(([, v]) => v !== null && typeof v === 'object')) throw new Error('regression guard: a form with files is unsupported — send data');
    const body = new URLSearchParams(entries.map(([k, v]) => [k, String(v)])).toString();
    return { body, extra: { 'content-type': 'application/x-www-form-urlencoded' } };
  }
  // fetch(request): a captured Playwright Request replays with its own body, as Playwright's does.
  if (request) return { body: request.postDataBuffer?.() ?? undefined, extra: {} };
  return { body: undefined, extra: {} };
}

/**
 * Wrap an APIRequestContext (the `request` fixture, `context.request`, `page.request` — which
 * context routing does not intercept) so every hop takes the same walk; retries are forced off.
 */
export function guardRequestContext(api, manifest, { state } = {}) {
  const g = state ?? guardState(manifest);
  const call = async (method, urlOrRequest, opts = {}) => {
    const request = typeof urlOrRequest === 'string' ? null : urlOrRequest;
    let url = new URL(request ? request.url() : urlOrRequest, manifest.base_url).href;
    if (opts.params) {
      const u = new URL(url);
      for (const [k, v] of Object.entries(opts.params)) u.searchParams.set(k, String(v));
      url = u.href;
    }
    const { body, extra } = requestBody(opts, request);
    const m = (opts.method ?? method).toUpperCase();
    const base = request?.headers?.() ?? {};
    const result = await walk(g, { method: m, url, body, headers: { ...base, ...extra, ...(opts.headers ?? {}) } }, (hop, headers) => api.fetch(hop.url, {
      method: hop.method, data: hop.body ?? undefined, headers, maxRedirects: 0, maxRetries: 0, failOnStatusCode: false,
      ...(opts.timeout !== undefined ? { timeout: opts.timeout } : {}),
    }));
    if (result.aborted) throw new Error(`regression guard blocked ${result.aborted}`);
    if (result.failed) throw new Error(`regression guard: request failed — ${result.failed}`);
    if (opts.failOnStatusCode && result.response.status() >= 400) throw new Error(`${result.response.status()} ${reduceUrl(url)}`);
    return result.response;
  };
  const wrapper = {
    fetch: (u, o = {}) => call(o.method ?? (typeof u === 'string' ? 'GET' : u.method()), u, o),
    get: (u, o) => call('GET', u, o),
    post: (u, o) => call('POST', u, o),
    put: (u, o) => call('PUT', u, o),
    patch: (u, o) => call('PATCH', u, o),
    delete: (u, o) => call('DELETE', u, o),
    head: (u, o) => call('HEAD', u, o),
  };
  return new Proxy(api, { get: (target, prop) => (prop in wrapper ? wrapper[prop] : typeof target[prop] === 'function' ? target[prop].bind(target) : target[prop]) });
}

/**
 * The bytes a plain-HTTP adapter call sends — the same bytes the guard judges. A string, a Buffer
 * (or Uint8Array) or URLSearchParams; any other body type is refused before transport.
 */
function adapterBody(body, headers) {
  if (body === undefined || body === null) return { body: undefined, headers };
  if (typeof body === 'string' || Buffer.isBuffer(body)) return { body, headers };
  if (body instanceof Uint8Array) return { body: Buffer.from(body), headers };
  if (body instanceof URLSearchParams) {
    const typed = Object.keys(headers).some((k) => k.toLowerCase() === 'content-type');
    return { body: body.toString(), headers: typed ? headers : { ...headers, 'content-type': 'application/x-www-form-urlencoded;charset=UTF-8' } };
  }
  throw new Error('regression guard: unsupported body type — send a string, a Buffer or URLSearchParams');
}

/** The hop walk over node `fetch` for a session adapter's plain HTTP sign-in, on the run's ledger. */
export async function guardedFetch(manifest, { method = 'GET', url, headers = {}, body } = {}, { tag = null } = {}) {
  const g = guardState(manifest);
  const sent = adapterBody(body, headers);
  const result = await walk(g, { method, url, body: sent.body, headers: sent.headers }, async (hop, h) => {
    const r = await fetch(hop.url, { method: hop.method, headers: h, body: hop.body ?? undefined, redirect: 'manual' });
    const buf = Buffer.from(await r.arrayBuffer());
    return { status: () => r.status, headers: () => Object.fromEntries(r.headers.entries()), body: async () => buf, text: async () => buf.toString('utf8') };
  });
  if (result.aborted) throw new Error(`regression guard blocked ${result.aborted}${tag ? ` (${tag})` : ''}`);
  if (result.failed) throw new Error(`regression guard: request failed — ${result.failed}`);
  const resp = result.response;
  const buf = await resp.body();
  return { status: resp.status(), headers: resp.headers(), body: buf, text: () => buf.toString('utf8'), url: result.final.url };
}
