// keyboard.mjs — the Tab walk (2.1.1 reachability, ◐ only) and the keyboard-trap check (2.1.2: ● only
// when 10 Tab, 10 Shift+Tab and Escape all keep focus inside one container).
import { inPage } from '../dom.mjs';

export const MAX_PRESSES = 250;
const TRAP_WINDOW = 10;

async function allSeen(page, history) {
  return inPage(page, `
    const seen = new Set(arg);
    return W.all().filter((el) => el.matches('a[href], button, input:not([type=hidden]), select, textarea') && !el.disabled && el.tabIndex >= 0 && W.visible(el)).every((el) => seen.has(W.sel(el)));
  `, history.filter(Boolean));
}

const ACTIVE ="const a = W.deepActive(); return a && a !== document.body && a !== document.documentElement ? W.sel(a) : null;";

export default {
  name: 'keyboard',
  mode: 'mutating',
  contributors: [
    { id: 'keyboard-walk', sc: ['2.1.1'] },
    { id: 'keyboard-trap', sc: ['2.1.2'] },
  ],
  doesNotDetect: 'handlers added by delegation or addEventListener on non-focusable elements; gestures; traps inside cross-origin frames',
  async run({ page }) {
    const out = [];
    // A full cycle runs from the top of the document back to it. A state that starts with focus
    // inside the page (a focused form field) first walks to the end and starts counting there.
    let collecting = (await inPage(page, ACTIVE)) === null;
    const history = [];
    let completed = false;
    let trapSet = null;
    let first = null;
    for (let i = 0; i < MAX_PRESSES; i += 1) {
      await page.keyboard.press('Tab');
      const sel = await inPage(page, ACTIVE);
      const window2 = [...history, sel].slice(-TRAP_WINDOW * 2);
      if (window2.length === TRAP_WINDOW * 2 && !window2.includes(null)) {
        const older = new Set(window2.slice(0, TRAP_WINDOW));
        const set = new Set(window2);
        if (set.size <= 5 && window2.slice(TRAP_WINDOW).every((s) => older.has(s))) { trapSet = [...set]; break; }
      }
      if (!collecting) {
        history.push(sel);
        if (sel === null) { collecting = true; history.length = 0; }
        continue;
      }
      history.push(sel);
      if (first === null && sel) first = sel;
      // Focus leaving the document ends a cycle; returning to the first stop without leaving it
      // counts only once every visible native control was seen (a two-button trap also "returns").
      else if (first !== null && sel === null) { completed = true; break; }
      else if (first !== null && sel === first && await allSeen(page, history)) { completed = true; break; }
    }
    if (trapSet) {
      const info = await inPage(page, `
        const q = (s) => { const parts = s.split(' >>> '); let root = document, el = null; for (const p of parts) { el = root.querySelector(p); if (!el) return null; root = el.shadowRoot || el; } return el; };
        const els = arg.map(q).filter(Boolean);
        if (!els.length) return null;
        let c = els[0].parentElement;
        while (c && !els.every((e) => c.contains(e))) c = c.parentElement;
        if (!c) return null;
        const outside = W.focusables().filter((el) => !c.contains(el) && W.visible(el) && el.tabIndex >= 0);
        return { container: W.sel(c), outside: outside.length };
      `, trapSet);
      if (info && info.outside > 0) {
        const inside = async () => trapSet.includes(await inPage(page, ACTIVE));
        let shiftStays = true;
        for (let i = 0; i < TRAP_WINDOW; i += 1) {
          await page.keyboard.press('Shift+Tab');
          if (!(await inside())) { shiftStays = false; break; }
        }
        let escStays = false;
        if (shiftStays) {
          await page.keyboard.press('Escape');
          escStays = (await inside()) && (await inPage(page, `const q = document.querySelector(arg); return !!q && W.visible(q);`, info.container).catch(() => true));
        }
        if (shiftStays && escStays) {
          out.push({ contributor: 'keyboard-trap', outcome: 'violation', basis: '●', impact: 'blocker', selector: info.container, cropSelector: info.container,
            steps: ['Press Tab from the top of the page until focus enters the component.', 'Press Tab and Shift+Tab 10 times each, then Escape.', 'Focus never leaves the component.'] });
        } else {
          out.push({ contributor: 'keyboard-trap', outcome: 'pass' });
        }
      } else {
        out.push({ contributor: 'keyboard-trap', outcome: 'pass' });
      }
      out.push({ contributor: 'keyboard-walk', missing: 'walk-incomplete' });
      return out;
    }
    out.push({ contributor: 'keyboard-trap', outcome: first ? 'pass' : 'inapplicable' });
    if (!completed) {
      out.push({ contributor: 'keyboard-walk', missing: 'walk-incomplete' });
      return out;
    }
    const visited = history.filter(Boolean);
    const unreached = await inPage(page, `
      const seen = new Set(arg);
      const native = W.all().filter((el) => el.matches('a[href], button, input:not([type=hidden]), select, textarea') && !el.disabled && !el.closest('[inert]') && el.tabIndex >= 0 && W.visible(el));
      const clickable = W.all().filter((el) => typeof el.onclick === 'function' && el.tabIndex < 0 && getComputedStyle(el).cursor === 'pointer' && !el.closest('a[href], button') && W.visible(el));
      return [...native, ...clickable].map((el) => W.sel(el)).filter((s) => !seen.has(s)).slice(0, 10);
    `, visited);
    for (const sel of unreached) {
      out.push({ contributor: 'keyboard-walk', outcome: 'needs-review', basis: '◐', impact: 'serious', selector: sel, cropSelector: sel,
        steps: ['Press Tab repeatedly from the top of the page through one full cycle.', 'This element never receives focus.'] });
    }
    if (!unreached.length) out.push({ contributor: 'keyboard-walk', outcome: visited.length ? 'pass' : 'inapplicable' });
    return out;
  },
};
