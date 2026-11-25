// cookie-banner.mjs — detects a consent banner (audited as part of the initial state) and dismisses it
// under the lockdown with a reject/close button. An accept-like button is never clicked.
import { inPage, toLocator } from '../dom.mjs';

export const CMP_SELECTORS = '#onetrust-banner-sdk, #CybotCookiebotDialog, #didomi-host, #usercentrics-root, .cmplz-cookiebanner, #iubenda-cs-banner, [id*=cookie i], [class*=cookie i], [id*=consent i], [class*=consent i]';
// Exact names: "Reject all", "Odrzuć wszystkie", "Odrzuć", "Decline", "Only necessary", "Nur notwendige", "Close", "Zamknij".
export const REJECT_NAMES = /^(reject all|reject|odrzuć wszystkie|odrzuć|decline|decline all|only necessary|necessary only|tylko niezbędne|nur notwendige|alle ablehnen|ablehnen|tout refuser|refuser|continuer sans accepter|rechazar todo|rechazar|close|zamknij|schließen|fermer|cerrar|×|✕|x)$/i;
export const ACCEPT_LIKE = /accept|akceptuj|zgadzam|allow all|agree|zezwól|zaakceptuj|alle akzeptieren|tout accepter|aceptar/i;

export async function detectBanner(page) {
  return inPage(page, `
    const cands = W.all().filter((el) => el.matches(arg) && W.visible(el));
    const dialogs = W.all().filter((el) => el.matches('dialog[open], [role=dialog], [role=alertdialog]') && W.visible(el) && /cookie|ciastecz/i.test(el.textContent));
    const pick = [...cands, ...dialogs].sort((a, b) => (b.contains(a) ? 1 : 0) - (a.contains(b) ? 1 : 0))[0];
    return pick ? W.sel(pick) : null;
  `, CMP_SELECTORS);
}

// Returns {dismissed: boolean, button?: string}.
export async function dismissBanner(page, selector) {
  const btn = await inPage(page, `
    const box = document.querySelector(arg.sel);
    if (!box) return null;
    const re = new RegExp(arg.reject, 'i');
    const accept = new RegExp(arg.accept, 'i');
    const buttons = W.all(box).concat(box.shadowRoot ? W.all(box.shadowRoot) : []).filter((el) => el.matches('button, [role=button], a[href="#"], input[type=button]'));
    const name = (el) => ((el.getAttribute('aria-label') || el.textContent || el.value || '').trim().replace(/\\s+/g, ' '));
    const hit = buttons.find((el) => re.test(name(el)) && !accept.test(name(el)));
    return hit ? W.sel(hit) : null;
  `, { sel: selector, reject: REJECT_NAMES.source, accept: ACCEPT_LIKE.source });
  if (!btn) return { dismissed: false };
  await page.locator(toLocator(btn)).first().click({ timeout: 3000 }).catch(() => {});
  await page.waitForTimeout(150);
  const still = await inPage(page, 'const b = document.querySelector(arg); return !!b && W.visible(b);', selector);
  return { dismissed: !still, button: btn };
}
