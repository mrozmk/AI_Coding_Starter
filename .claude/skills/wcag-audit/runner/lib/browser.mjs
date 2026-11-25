// browser.mjs — one sandboxed headless Chrome per run behind the pinned proxy, a fresh context per
// load, method enforcement and the per-page network lockdown in route, WebSockets and WebRTC blocked,
// and a guaranteed close (finally, SIGINT/SIGTERM, time limits).
import http from 'node:http';
import { load as loadDeps, browserChoice } from './deps.mjs';
import { redactUrl } from './redact.mjs';

export const VIEWPORTS = {
  desktop: { viewport: { width: 1280, height: 800 }, deviceScaleFactor: 1, isMobile: false, hasTouch: false },
  mobile: { viewport: { width: 390, height: 844 }, deviceScaleFactor: 2, isMobile: true, hasTouch: true },
  reflow: { viewport: { width: 320, height: 640 }, deviceScaleFactor: 1, isMobile: false, hasTouch: false },
  landscape: { viewport: { width: 844, height: 390 }, deviceScaleFactor: 2, isMobile: true, hasTouch: true },
};

export const FREEZE_CSS = '*,*::before,*::after{animation-play-state:paused!important;transition:none!important;caret-color:transparent!important}';

const WEBRTC_INIT = `(() => {
  const blocked = function () { window.__wcagWebrtc = (window.__wcagWebrtc || 0) + 1; throw new DOMException('blocked by wcag-audit', 'NotAllowedError'); };
  try { Object.defineProperty(window, 'RTCPeerConnection', { value: blocked, configurable: false, writable: false }); } catch (e) {}
  try { Object.defineProperty(window, 'webkitRTCPeerConnection', { value: blocked, configurable: false, writable: false }); } catch (e) {}
})();`;

const open = new Set();
let handlersInstalled = false;
let interrupted = false;

// True once SIGINT/SIGTERM arrived: the scan must not record the run as complete.
export function wasInterrupted() {
  return interrupted;
}

export async function closeAll() {
  const list = [...open];
  open.clear();
  for (const fn of list) {
    try { await fn(); } catch { /* best effort */ }
  }
}

function installSignalHandlers() {
  if (handlersInstalled) return;
  handlersInstalled = true;
  for (const sig of ['SIGINT', 'SIGTERM']) {
    process.once(sig, async () => {
      interrupted = true;
      await closeAll();
      process.exit(sig === 'SIGINT' ? 130 : 143);
    });
  }
}

export function registerClose(fn) {
  open.add(fn);
  return () => open.delete(fn);
}

// The runner-owned probe origin: a loopback listener outside the given origins that counts connections.
async function probeServer() {
  let hits = 0;
  const srv = http.createServer((q, s) => s.end('probe'));
  srv.on('connection', () => { hits += 1; });
  await new Promise((r) => srv.listen(0, '127.0.0.1', r));
  return { port: srv.address().port, hits: () => hits, close: () => new Promise((r) => srv.close(r)) };
}

export async function launch({ proxyPort, ledger, env = process.env }) {
  installSignalHandlers();
  const deps = loadDeps();
  const choice = browserChoice(deps.dir, env);
  const args = ['--force-webrtc-ip-handling-policy=disable_non_proxied_udp'];
  if (args.some((a) => /no-sandbox/.test(a))) throw new Error('refusing --no-sandbox');
  const browser = await deps.playwright.chromium.launch({
    channel: choice.channel,
    headless: true,
    chromiumSandbox: true,
    proxy: { server: `http://127.0.0.1:${proxyPort}`, bypass: '<-loopback>' },
    args,
  });
  const unregister = registerClose(() => browser.close());
  if (env.WCAG_AUDIT_TEST === '1' && env.WCAG_AUDIT_TEST_FAULT === 'after-launch') throw new Error('test fault after launch');
  const info = { chromiumSandbox: true, channel: choice.channel ?? 'chromium', version: browser.version(), args };
  try {
    const cdp = await browser.newBrowserCDPSession();
    const { arguments: cl } = await cdp.send('Browser.getBrowserCommandLine');
    info.commandLine = cl.filter((a) => !/^--user-data-dir=/.test(a));
    await cdp.detach();
  } catch { /* experimental — best effort, never the sandbox proof */ }
  if ((info.commandLine || []).some((a) => a === '--no-sandbox')) throw new Error('the browser runs without its sandbox');
  // Live probe: the proxy must refuse a loopback origin outside the given origins.
  const probe = await probeServer();
  const ctx = await browser.newContext();
  const page = await ctx.newPage();
  let status = 0;
  try {
    const res = await page.goto(`http://127.0.0.1:${probe.port}/live-probe`, { timeout: 15000 });
    status = res ? res.status() : 0;
  } catch { status = -1; }
  await ctx.close();
  await probe.close();
  // The probe's own refusal ledger entry is expected; keep it out of the page ledger.
  for (let i = ledger.length - 1; i >= 0; i -= 1) if (/live-probe/.test(ledger[i].url || '')) ledger.splice(i, 1);
  if (probe.hits() !== 0 || (status !== 403 && status !== -1)) {
    const err = new Error(`live probe was not refused (status ${status}, hits ${probe.hits()})`);
    err.code = 'live-probe-failed';
    throw err;
  }
  info.live_probe = 'refused';
  return { browser, info, close: async () => { unregister(); await browser.close(); } };
}

// A fresh context with one page. The page has a load phase (requests allowed: GET/HEAD through the
// proxy) and then a locked phase: every request is aborted and ledgered with the current label.
export async function freshPage(browser, viewportName, { ledger, context: ctxInfo = {}, userAgent } = {}) {
  const vp = VIEWPORTS[viewportName];
  const context = await browser.newContext({ ...vp, reducedMotion: 'reduce', serviceWorkers: 'block', ...(userAgent ? { userAgent } : {}) });
  const unregister = registerClose(() => context.close());
  const state = { locked: false, label: 'interaction-lockdown', aborted: 0, navAttempt: false, responses: new Map(), failed: new Map(), docServed: 0 };
  await context.routeWebSocket(/.*/, (ws) => {
    ledger.push({ kind: 'websocket-blocked', url: redactUrl(ws.url()), ...ctxInfo });
    ws.close({ code: 1008, reason: 'blocked by wcag-audit' });
  });
  await context.addInitScript(WEBRTC_INIT);
  let page = null;
  await context.route('**/*', async (route) => {
    const req = route.request();
    const method = req.method();
    if (method !== 'GET' && method !== 'HEAD') {
      ledger.push({ kind: 'non-get', url: redactUrl(req.url()), reason: method, ...ctxInfo });
      return route.abort('blockedbyclient');
    }
    let owner = null;
    try { owner = req.frame().page(); } catch { owner = null; }
    if (state.locked || owner !== page) {
      state.aborted += 1;
      if (req.isNavigationRequest() && req.frame() === page?.mainFrame()) state.navAttempt = true;
      ledger.push({ kind: state.label, url: redactUrl(req.url()), ...ctxInfo });
      return route.abort('blockedbyclient');
    }
    return route.continue();
  });
  page = await context.newPage();
  page.on('response', (r) => { state.responses.set(r.url(), r.status()); });
  page.on('requestfailed', (r) => { state.failed.set(r.url(), r.failure()?.errorText || 'failed'); });
  const close = async () => { unregister(); await context.close().catch(() => {}); };
  return {
    context,
    page,
    state,
    lock(label = 'interaction-lockdown') { state.locked = true; state.label = label; },
    relabel(label) { state.label = label; },
    close,
  };
}

export async function freeze(page) {
  await page.addStyleTag({ content: FREEZE_CSS }).catch(() => {});
}

// doctor --launch: start the sandboxed browser once and close it.
export async function launchCheck() {
  const deps = loadDeps();
  const choice = browserChoice(deps.dir);
  const browser = await deps.playwright.chromium.launch({ channel: choice.channel, headless: true, chromiumSandbox: true });
  const version = browser.version();
  await browser.close();
  return { chromiumSandbox: true, channel: choice.channel ?? 'chromium', version };
}
