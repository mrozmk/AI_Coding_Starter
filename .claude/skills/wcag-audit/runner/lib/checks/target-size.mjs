// target-size.mjs — target-spacing (2.5.8, ◐ only): an undersized pointer target whose 24 px circle
// meets another target or another undersized target's circle. axe `target-size` is the ● signal.
import { inPage } from '../dom.mjs';

export default {
  name: 'target-size',
  mode: 'readonly',
  contributors: [{ id: 'target-spacing', sc: ['2.5.8'] }],
  doesNotDetect: 'the equivalent and essential exceptions',
  async run({ page }) {
    const hits = await inPage(page, `
      const targets = W.all().filter((el) => el.matches('a[href], button, input:not([type=hidden]), select, textarea, summary, [role=button], [role=link], [role=checkbox], [role=radio], [role=tab]') && W.visible(el));
      const inlineInText = (el) => getComputedStyle(el).display === 'inline' && el.parentElement && Array.from(el.parentElement.childNodes).some((n) => n.nodeType === 3 && n.textContent.trim());
      const rects = targets.map((el) => ({ el, r: el.getBoundingClientRect() }));
      const small = rects.filter(({ el, r }) => (r.width < 24 || r.height < 24) && !inlineInText(el));
      const center = (r) => ({ x: r.left + r.width / 2, y: r.top + r.height / 2 });
      const distToRect = (c, r) => { const dx = Math.max(r.left - c.x, 0, c.x - r.right); const dy = Math.max(r.top - c.y, 0, c.y - r.bottom); return Math.hypot(dx, dy); };
      const out = [];
      for (const s of small) {
        const c = center(s.r);
        const bad = rects.some((o) => o.el !== s.el && !o.el.contains(s.el) && !s.el.contains(o.el) && (distToRect(c, o.r) < 12 || (small.includes(o) && Math.hypot(center(o.r).x - c.x, center(o.r).y - c.y) < 24)));
        if (bad) out.push({ sel: W.sel(s.el), w: Math.round(s.r.width), h: Math.round(s.r.height) });
      }
      return { count: targets.length, out: out.slice(0, 20) };
    `);
    if (!hits.count) return [{ contributor: 'target-spacing', outcome: 'inapplicable' }];
    if (!hits.out.length) return [{ contributor: 'target-spacing', outcome: 'pass' }];
    return hits.out.map((h) => ({ contributor: 'target-spacing', outcome: 'needs-review', basis: '◐', impact: 'moderate', selector: h.sel, data: { width: h.w, height: h.h } }));
  },
};
