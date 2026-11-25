// browser.mjs — one sandboxed headless Chrome per run behind the pinned proxy, a fresh context per
// load, method enforcement and the per-page network lockdown in route, WebSockets and WebRTC blocked
// and ledgered live, and a guaranteed close (finally, SIGINT/SIGTERM, time limits).
import { load as loadDeps, browserChoice } from './deps.mjs';
import { canaryServer } from './proxy.mjs';
import { redactUrl } from './redact.mjs';

export const VIEWPORTS = {
  desktop: { viewport: { width: 1280, height: 800 }, deviceScaleFactor: 1, isMobile: false, hasTouch: false },
  mobile: { viewport: { width: 390, height: 844 }, deviceScaleFactor: 2, isMobile: true, hasTouch: true },
  reflow: { viewport: { width: 320, height: 640 }, deviceScaleFactor: 1, isMobile: false, hasTouch: false },
  landscape: { viewport: { width: 844, height: 390 }, deviceScaleFactor: 2, isMobile: true, hasTouch: true },
};

export const FREEZE_CSS = '*,*::before,*::after{animation-play-state:paused!important;transition:none!important;caret-color:transparent!important}';

// Printed through the init-time console.debug, so a frame that detaches right after the call is still
// recorded and teardown needs no page JavaScript.
export const WEBRTC_SIGNAL = 'wcag-audit:webrtc-blocked';

const WEBRTC_INIT = `(() => {
  const signal = console.debug.bind(console);
  const blocked = function () { signal(${JSON.stringify(WEBRTC_SIGNAL)}); throw new DOMException('blocked by wcag-audit', 'NotAllowedError'); };
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
  const probe = await canaryServer();
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

function chainUrls(req) {
  const urls = [];
  for (let r = req; r; r = r.redirectedFrom()) urls.push(r.url());
  return urls;
}

// A fresh context with one page. The page has a load phase (requests allowed: GET/HEAD through the
// proxy) and then a locked phase: every request is aborted and ledgered with the current label.
export async function freshPage(browser, viewportName, { ledger, context: ctxInfo = {}, userAgent } = {}) {
  const vp = VIEWPORTS[viewportName];
  const context = await browser.newContext({ ...vp, reducedMotion: 'reduce', serviceWorkers: 'block', ...(userAgent ? { userAgent } : {}) });
  const unregister = registerClose(() => context.close());
  const state = { locked: false, label: 'interaction-lockdown', aborted: 0, navAttempt: false, webrtc: false, responses: new Map(), failed: new Map(), proxyBlocked: new Set() };
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
  page.on('response', (r) => {
    const status = r.status();
    // The proxy's own refusal (destination policy) marks its 403; it says nothing about the origin.
    const blocked = r.headers()['x-wcag-audit'] === 'blocked';
    // A terminal answer is filed under every URL of its redirect chain: img.currentSrc keeps the first.
    const urls = status >= 300 && status < 400 ? [r.url()] : chainUrls(r.request());
    for (const u of urls) {
      state.responses.set(u, status);
      if (blocked) state.proxyBlocked.add(u);
    }
  });
  page.on('requestfailed', (r) => {
    const error = r.failure()?.errorText || 'failed';
    for (const u of chainUrls(r)) state.failed.set(u, error);
  });
  page.on('console', (m) => {
    if (state.webrtc || m.text() !== WEBRTC_SIGNAL) return;
    state.webrtc = true;
    ledger.push({ kind: 'webrtc-blocked', ...ctxInfo });
  });
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
