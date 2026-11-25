// reflow.mjs — 1.4.10 on a separate load at 320×640 (never a resize). ●: a control or text block is
// clipped and unreachable; ◐: page-level horizontal scroll with no measured loss; content inside a
// scroll container that holds 2-D content (tables, grids, pre, maps) is the exception: inapplicable.
import { inPage } from '../dom.mjs';

export default {
  name: 'reflow',
  mode: 'separate',
  load: 'reflow',
  viewports: ['desktop'],
  contributors: [{ id: 'reflow', sc: ['1.4.10'] }],
  doesNotDetect: 'loss inside canvas or images; the two-dimensional exception is reported as inapplicable, never as a finding',
  async run({ page }) {
    const r = await inPage(page, `
      const de = document.documentElement;
      const cs = (el) => getComputedStyle(el);
      const hidden = (v) => v === 'hidden' || v === 'clip';
      const pageScroll = de.scrollWidth > de.clientWidth + 1 && !hidden(cs(de).overflowX) && !hidden(cs(document.body).overflowX);
      const scroller = (el) => { for (let c = el.parentElement; c; c = c.parentElement) { const o = cs(c).overflowX; if ((o === 'auto' || o === 'scroll') && c.scrollWidth > c.clientWidth + 1) return c; } return null; };
      const twoD = (c) => c.matches('table, pre, [role=table], [role=grid], [role=treegrid]') || !!c.querySelector('table, pre, [role=table], [role=grid], [role=treegrid], canvas, svg');
      // Closed off-canvas content (inert/aria-hidden, or parked past the right edge in a fixed layer) is
      // only meant to appear when opened: not a reflow loss.
      const fixedLayer = (el) => { for (let c = el; c; c = c.parentElement) if (cs(c).position === 'fixed') return true; return false; };
      const items = W.all().filter((el) => el.matches('a[href], button, input:not([type=hidden]), select, textarea, [role=button], p, h1, h2, h3, h4, h5, h6, li, label') && W.visible(el) && !el.closest('[inert], [aria-hidden=true]'));
      const lost = [];
      let exception = false;
      for (const el of items) {
        const rect = el.getBoundingClientRect();
        if (rect.right <= de.clientWidth + 1) continue;
        if (rect.left >= de.clientWidth && fixedLayer(el)) continue;
        const sc = scroller(el);
        if (sc) { if (twoD(sc) || el.closest('table, pre')) exception = true; continue; }
        if (el.closest('table, pre, [role=grid]')) { exception = true; continue; }
        if (pageScroll) continue;
        lost.push(W.sel(el));
      }
      return { pageScroll, lost: lost.slice(0, 5), exception };
    `);
    if (r.lost.length) {
      return r.lost.map((sel) => ({ contributor: 'reflow', outcome: 'violation', basis: '●', impact: 'serious', selector: sel, cropViewport: true,
        steps: ['Open the page in a window 320 CSS px wide (or zoom to 400 % at 1280 px).', 'This element lies outside the viewport and cannot be scrolled into view.'] }));
    }
    if (r.pageScroll && !r.exception) return [{ contributor: 'reflow', outcome: 'needs-review', basis: '◐', impact: 'moderate', selector: 'html', cropViewport: true }];
    if (r.exception) return [{ contributor: 'reflow', outcome: 'inapplicable' }];
    return [{ contributor: 'reflow', outcome: 'pass' }];
  },
};
