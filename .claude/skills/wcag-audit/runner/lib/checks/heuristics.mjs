// heuristics.mjs — ◐-only heuristics: static ones on the opened state (3.3.8, 2.5.7, 2.2.2, 4.1.3),
// the skip-link activation (2.4.1, mutating: it moves focus), and 1.3.4 on a separate 844×390
// landscape load.
import { inPage, toLocator } from '../dom.mjs';

const SKIP_TEXT = /skip|pomiń|przejdź do (treści|zawartości)|jump to|zum inhalt|aller au contenu|saltar/i;

export const staticHeuristics = {
  name: 'heuristics',
  mode: 'readonly',
  contributors: [
    { id: 'accessible-auth', sc: ['3.3.8'] },
    { id: 'dragging', sc: ['2.5.7'] },
    { id: 'pause-control', sc: ['2.2.2'] },
    { id: 'status-messages', sc: ['4.1.3'] },
  ],
  doesNotDetect: 'everything that needs interaction past focus',
  async run({ page }) {
    const r = await inPage(page, `
      const all = W.all();
      const creds = all.filter((el) => el.matches('input[type=password], input[autocomplete=username], input[autocomplete=current-password], input[autocomplete=new-password]'));
      const pasteBlocked = creds.filter((el) => el.getAttribute('onpaste') !== null || el.getAttribute('autocomplete') === 'off').map((el) => W.sel(el));
      const captcha = all.filter((el) => /captcha/i.test((el.id || '') + ' ' + (el.className && el.className.baseVal === undefined ? el.className : '') + ' ' + (el.getAttribute('src') || ''))).map((el) => W.sel(el));
      const drags = all.filter((el) => el.getAttribute('draggable') === 'true' || el.getAttribute('ondragstart') !== null);
      const dragNoAlt = drags.filter((el) => { const w = el.closest('[role], section, form, ul, ol, div') || el.parentElement; return !(w && w.querySelector('button, [role=button]')); }).map((el) => W.sel(el));
      const media = all.filter((el) => el.matches('video[autoplay], audio[autoplay]') && !el.hasAttribute('controls') && !el.muted);
      const infinite = all.filter((el) => { const cs = getComputedStyle(el); return cs.animationName !== 'none' && cs.animationIterationCount === 'infinite' && W.visible(el); });
      const pauseBtn = all.some((el) => el.matches('button, [role=button]') && /pause|stop|zatrzymaj|wstrzymaj|pauza/i.test((el.getAttribute('aria-label') || '') + ' ' + el.textContent));
      const moving = pauseBtn ? [] : [...media, ...infinite].map((el) => W.sel(el));
      const forms = all.filter((el) => el.tagName === 'FORM' && el.querySelector('input:not([type=hidden]), select, textarea'));
      const live = all.some((el) => el.matches('[role=alert], [role=status], [aria-live]'));
      return { creds: creds.length, pasteBlocked, captcha, drags: drags.length, dragNoAlt, moving, movingAny: media.length + infinite.length, forms: forms.map((f) => W.sel(f)), live };
    `);
    const out = [];
    const flag = (contributor, sel, impact = 'moderate') => out.push({ contributor, outcome: 'needs-review', basis: '◐', impact, selector: sel });
    if (!r.creds && !r.captcha.length) out.push({ contributor: 'accessible-auth', outcome: 'inapplicable' });
    else if (!r.pasteBlocked.length && !r.captcha.length) out.push({ contributor: 'accessible-auth', outcome: 'pass' });
    else [...r.pasteBlocked, ...r.captcha].slice(0, 5).forEach((s) => flag('accessible-auth', s, 'serious'));
    if (!r.drags) out.push({ contributor: 'dragging', outcome: 'inapplicable' });
    else if (!r.dragNoAlt.length) out.push({ contributor: 'dragging', outcome: 'pass' });
    else r.dragNoAlt.slice(0, 5).forEach((s) => flag('dragging', s));
    if (!r.movingAny) out.push({ contributor: 'pause-control', outcome: 'inapplicable' });
    else if (!r.moving.length) out.push({ contributor: 'pause-control', outcome: 'pass' });
    else r.moving.slice(0, 5).forEach((s) => flag('pause-control', s));
    if (!r.forms.length) out.push({ contributor: 'status-messages', outcome: 'inapplicable' });
    else if (r.live) out.push({ contributor: 'status-messages', outcome: 'pass' });
    else r.forms.slice(0, 5).forEach((s) => flag('status-messages', s));
    return out;
  },
};

export const skipLink = {
  name: 'skip-link',
  mode: 'mutating',
  contributors: [{ id: 'skip-link', sc: ['2.4.1'] }],
  doesNotDetect: 'bypass by headings or landmarks alone; skip links that appear only after the third Tab stop',
  async run({ page }) {
    const info = await inPage(page, `
      const re = new RegExp(arg, 'i');
      const focus = W.focusables().filter((el) => W.visible(el) || el.matches('a[href^="#"]'));
      const link = focus.slice(0, 3).find((el) => el.matches('a[href^="#"]') && re.test(el.textContent + ' ' + (el.getAttribute('aria-label') || '')));
      const main = document.querySelector('main, [role=main]');
      const before = main ? focus.filter((el) => main.compareDocumentPosition(el) & Node.DOCUMENT_POSITION_PRECEDING).length : 0;
      const needs = !!document.querySelector('nav, [role=navigation]') || before >= 5;
      return { link: link ? W.sel(link) : null, hash: link ? decodeURIComponent(link.getAttribute('href').slice(1)) : null, needs };
    `, SKIP_TEXT.source);
    if (!info.link) {
      if (!info.needs) return [{ contributor: 'skip-link', outcome: 'inapplicable' }];
      return [{ contributor: 'skip-link', outcome: 'needs-review', basis: '◐', impact: 'moderate', selector: 'body', cropViewport: true, data: { reason: 'no skip link before the navigation' } }];
    }
    await page.locator(toLocator(info.link)).first().focus().catch(() => {});
    await page.keyboard.press('Enter');
    await page.waitForTimeout(80);
    const moved = await inPage(page, `const t = document.getElementById(arg); const a = W.deepActive(); return !!t && !!a && a !== document.body && (a === t || t.contains(a));`, info.hash);
    if (moved) return [{ contributor: 'skip-link', outcome: 'pass' }];
    return [{ contributor: 'skip-link', outcome: 'needs-review', basis: '◐', impact: 'moderate', selector: info.link, data: { reason: 'the skip link does not move focus to its target' },
      steps: ['Press Tab once to focus the skip link, then Enter.', 'Focus does not move to the main content.'] }];
  },
};

export const orientation = {
  name: 'orientation',
  mode: 'separate',
  load: 'landscape',
  viewports: ['desktop'],
  contributors: [{ id: 'orientation', sc: ['1.3.4'] }],
  doesNotDetect: 'orientation locks set through the Screen Orientation API after interaction',
  async run({ page }) {
    const r = await inPage(page, `
      const main = document.querySelector('main, [role=main]') || document.body;
      const cs = getComputedStyle(main);
      const rotated = /matrix\\(\\s*-?0(\\.0+)?,\\s*-?1/.test(getComputedStyle(document.body).transform) || /matrix\\(\\s*-?0(\\.0+)?,\\s*-?1/.test(cs.transform);
      return { hidden: cs.display === 'none' || cs.visibility === 'hidden' || !W.visible(main), rotated, sel: W.sel(main) };
    `);
    if (r.hidden || r.rotated) return [{ contributor: 'orientation', outcome: 'needs-review', basis: '◐', impact: 'serious', selector: r.sel, cropViewport: true }];
    return [{ contributor: 'orientation', outcome: 'pass' }];
  },
};

export default [staticHeuristics, skipLink, orientation];
