// text-resize.mjs — 1.4.4 (◐ only): text-only 200 % scaling (computed font-size ×2 on every element
// that carries text, not page zoom); text clipped afterwards that was not clipped before.
import { inPage } from '../dom.mjs';
import { CLIPPED } from './text-spacing.mjs';

export default {
  name: 'text-resize',
  mode: 'mutating',
  contributors: [{ id: 'text-resize', sc: ['1.4.4'] }],
  doesNotDetect: 'zoom-based failures; overlap without clipping',
  async run({ page }) {
    const before = new Set(await inPage(page, CLIPPED));
    await inPage(page, `
      const els = W.all().filter((el) => Array.from(el.childNodes).some((n) => n.nodeType === 3 && n.textContent.trim()));
      const sizes = els.map((el) => parseFloat(getComputedStyle(el).fontSize));
      els.forEach((el, i) => el.style.setProperty('font-size', (sizes[i] * 2) + 'px', 'important'));
    `);
    await page.waitForTimeout(50);
    const after = await inPage(page, CLIPPED);
    const fresh = after.filter((s) => !before.has(s)).slice(0, 10);
    if (!fresh.length) return [{ contributor: 'text-resize', outcome: 'pass' }];
    return fresh.map((sel) => ({ contributor: 'text-resize', outcome: 'needs-review', basis: '◐', impact: 'moderate', selector: sel, cropSelector: sel }));
  },
};
