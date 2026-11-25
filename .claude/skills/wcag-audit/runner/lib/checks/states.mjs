// states.mjs — state openers (menu/disclosure, modal, non-submitting form focus), at most 5 states per
// page including the initial one. Every opener click happens under the network lockdown.
import { inPage, toLocator } from '../dom.mjs';

export const MAX_STATES = 5;

export async function discoverStates(page) {
  return inPage(page, `
    const all = W.all();
    const out = [];
    for (const el of all) {
      if (!W.visible(el)) continue;
      const isBtn = el.matches('button, [role=button]') && !el.matches('a, [type=submit], input[type=submit]');
      if (!isBtn) continue;
      const form = el.closest('form');
      if (form && el.tagName === 'BUTTON' && (el.getAttribute('type') || 'submit') !== 'button') continue;
      const controls = el.getAttribute('aria-controls');
      const target = controls ? document.getElementById(controls) : null;
      if (el.getAttribute('aria-haspopup') === 'dialog' || (target && target.matches('dialog, [role=dialog]'))) out.push({ kind: 'modal', opener: W.sel(el), target: controls });
      else if (el.getAttribute('aria-expanded') === 'false') out.push({ kind: 'menu', opener: W.sel(el), target: controls });
    }
    for (const f of all.filter((el) => el.tagName === 'FORM')) {
      const field = Array.from(f.querySelectorAll('input:not([type=hidden]):not([type=submit]):not([type=button]), select, textarea')).find((el) => W.visible(el) && !el.disabled);
      if (field) out.push({ kind: 'form-focus', opener: W.sel(field), target: null });
    }
    return out.map((s, i) => ({ ...s, id: s.kind + '-' + (i + 1) }));
  `);
}

// Opens a state on a freshly loaded, locked page; returns {opened, reason}.
export async function openState(session, st) {
  const { page, state } = session;
  const abortedBefore = state.aborted;
  state.navAttempt = false;
  if (st.kind === 'form-focus') {
    const ok = await inPage(page, `const el = W.q(arg); if (!el) return false; el.focus(); return W.deepActive() === el;`, st.opener).catch(() => false);
    return { opened: ok, reason: ok ? null : 'state-not-restored', withoutNetwork: false };
  }
  try {
    await page.locator(toLocator(st.opener)).first().click({ timeout: 3000 });
  } catch {
    return { opened: false, reason: 'state-not-restored', withoutNetwork: false };
  }
  await page.waitForTimeout(250);
  if (state.navAttempt) return { opened: false, reason: 'not-opened (navigation attempted)', withoutNetwork: false };
  const ok = await inPage(page, `
    const o = W.q(arg.opener);
    if (arg.kind === 'menu') return !!o && o.getAttribute('aria-expanded') === 'true';
    return W.all().some((el) => el.matches('dialog[open], [role=dialog], [aria-modal=true]') && W.visible(el));
  `, st).catch(() => false);
  return { opened: ok, reason: ok ? null : 'state-not-restored', withoutNetwork: state.aborted > abortedBefore };
}
