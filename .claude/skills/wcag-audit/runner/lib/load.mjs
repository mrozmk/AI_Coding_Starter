// load.mjs — the load phase of one page: navigation, bounded network-idle, the main-document status,
// then the lockdown, the scroll settle (lazy content is blocked and ledgered) and the animation freeze.
import { freeze } from './browser.mjs';

export const NAV_TIMEOUT = 30000;
const IDLE_TIMEOUT = 10000;

export async function loadPage(session, url, { ledger, context: ctxInfo = {} } = {}) {
  const { page } = session;
  let res;
  try {
    res = await page.goto(url, { waitUntil: 'load', timeout: NAV_TIMEOUT });
  } catch (err) {
    session.lock();
    return { ok: false, status: 0, reason: /ERR_NAME_NOT_RESOLVED/.test(String(err.message)) ? 'dns-failed' : 'navigation-failed' };
  }
  const status = res ? res.status() : 0;
  const blockedByProxy = res ? (await res.headerValue('x-wcag-audit').catch(() => null)) === 'blocked' : false;
  if (blockedByProxy) { session.lock(); return { ok: false, status, reason: 'destination-blocked' }; }
  try {
    await page.waitForLoadState('networkidle', { timeout: IDLE_TIMEOUT });
  } catch {
    ledger.push({ kind: 'settle-timeout', ...ctxInfo });
  }
  // From here on nothing the page or the runner asks for reaches the network.
  session.lock('lazy-content-blocked');
  await page.evaluate(() => new Promise((resolve) => {
    window.scrollTo(0, document.documentElement.scrollHeight);
    setTimeout(() => { window.scrollTo(0, 0); setTimeout(resolve, 150); }, 150);
  })).catch(() => {});
  session.relabel('interaction-lockdown');
  await freeze(page);
  if (status < 200 || status >= 300) return { ok: false, status, reason: `http-${status}` };
  return { ok: true, status };
}

export async function siteLanguage(page) {
  return page.evaluate(() => (document.documentElement.getAttribute('lang') || '').toLowerCase().split('-')[0]).catch(() => '');
}
