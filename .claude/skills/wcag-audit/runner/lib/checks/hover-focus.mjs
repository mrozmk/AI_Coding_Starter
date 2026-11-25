// hover-focus.mjs — 1.4.13 (◐ only): content that appears on hover over a control and does not go away
// with Escape.
import { inPage } from '../dom.mjs';

const MAX_TARGETS = 15;
const VISIBLE_SET = "return W.all().filter((el) => W.visible(el)).slice(0, 3000).map((el) => W.sel(el));";

export default {
  name: 'hover-focus',
  mode: 'mutating',
  contributors: [{ id: 'hover-focus', sc: ['1.4.13'] }],
  doesNotDetect: 'content shown by click; content that disappears when the pointer moves onto it; content that vanishes on its own',
  async run({ page }) {
    const targets = await inPage(page, `return W.focusables().filter((el) => W.visible(el)).slice(0, ${MAX_TARGETS}).map((el) => { const r = el.getBoundingClientRect(); return { sel: W.sel(el), x: r.left + r.width / 2, y: r.top + r.height / 2 }; }).filter((t) => t.x >= 0 && t.y >= 0 && t.x < innerWidth && t.y < innerHeight);`);
    if (!targets.length) return [{ contributor: 'hover-focus', outcome: 'inapplicable' }];
    const out = [];
    let appeared = 0;
    await page.mouse.move(1, 1);
    for (const t of targets) {
      const before = new Set(await inPage(page, VISIBLE_SET));
      await page.mouse.move(t.x, t.y);
      await page.waitForTimeout(60);
      const shown = (await inPage(page, VISIBLE_SET)).filter((s) => !before.has(s));
      if (!shown.length) continue;
      appeared += 1;
      await page.keyboard.press('Escape');
      await page.waitForTimeout(60);
      const still = new Set(await inPage(page, VISIBLE_SET));
      if (shown.some((s) => still.has(s))) {
        out.push({ contributor: 'hover-focus', outcome: 'needs-review', basis: '◐', impact: 'moderate', selector: t.sel, data: { shown: shown.length } });
      }
      await page.mouse.move(1, 1);
    }
    if (!out.length) out.push({ contributor: 'hover-focus', outcome: appeared ? 'pass' : 'inapplicable' });
    return out;
  },
};
