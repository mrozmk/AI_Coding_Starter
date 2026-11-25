// contrast-render.mjs — 1.4.3 (◐ only), only where axe color-contrast was incomplete (text over an
// image or gradient): hide the text, sample the background under its box away from the edges, and
// take the worst ratio against the text colour.
import { load as loadDeps } from '../deps.mjs';
import { toLocator } from '../dom.mjs';

const MAX_NODES = 10;

function lum([r, g, b]) {
  const f = (v) => { const c = v / 255; return c <= 0.03928 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4; };
  return 0.2126 * f(r) + 0.7152 * f(g) + 0.0722 * f(b);
}

export function ratio(a, b) {
  const [x, y] = [lum(a), lum(b)].sort((p, q) => q - p);
  return (x + 0.05) / (y + 0.05);
}

function parseRgb(text) {
  const m = /rgba?\(([^)]+)\)/.exec(text || '');
  return m ? m[1].split(',').slice(0, 3).map((v) => parseFloat(v)) : null;
}

export default {
  name: 'contrast-render',
  mode: 'readonly',
  contributors: [{ id: 'contrast-render', sc: ['1.4.3'] }],
  doesNotDetect: 'contrast of text inside images',
  async run({ page, axe }) {
    const nodes = (axe || []).filter((r) => r.rule === 'color-contrast' && r.outcome === 'needs-review' && r.selector && !r.frame).slice(0, MAX_NODES);
    if (!nodes.length) return [{ contributor: 'contrast-render', outcome: 'inapplicable' }];
    const out = [];
    let measured = 0;
    for (const n of nodes) {
      const loc = page.locator(toLocator(n.selector)).first();
      let info;
      try {
        info = await loc.evaluate((el) => {
          el.scrollIntoView({ block: 'center', inline: 'center' });
          const cs = getComputedStyle(el);
          const size = parseFloat(cs.fontSize);
          const bold = parseInt(cs.fontWeight, 10) >= 700;
          const prev = [el.style.getPropertyValue('color'), el.style.getPropertyPriority('color'), el.style.getPropertyValue('text-shadow')];
          const color = cs.color;
          el.style.setProperty('color', 'transparent', 'important');
          el.style.setProperty('text-shadow', 'none', 'important');
          const r = el.getBoundingClientRect();
          return { color, large: size >= 24 || (bold && size >= 18.66), prev, box: { x: r.left, y: r.top, width: r.width, height: r.height } };
        });
      } catch { continue; }
      const clip = { x: Math.max(0, info.box.x), y: Math.max(0, info.box.y), width: Math.max(1, info.box.width), height: Math.max(1, info.box.height) };
      let buf = null;
      try { buf = await page.screenshot({ clip, animations: 'disabled' }); } catch { buf = null; }
      await loc.evaluate((el, prev) => {
        if (prev[0]) el.style.setProperty('color', prev[0], prev[1]); else el.style.removeProperty('color');
        if (prev[2]) el.style.setProperty('text-shadow', prev[2]); else el.style.removeProperty('text-shadow');
      }, info.prev).catch(() => {});
      const fg = parseRgb(info.color);
      if (!buf || !fg) continue;
      const { PNG } = loadDeps();
      const png = PNG.sync.read(buf);
      let worst = Infinity;
      for (let y = 2; y < png.height - 2; y += 1) {
        for (let x = 2; x < png.width - 2; x += 1) {
          const i = (png.width * y + x) * 4;
          const rgb = [png.data[i], png.data[i + 1], png.data[i + 2]];
          if (rgb[0] === 255 && rgb[1] === 0 && rgb[2] === 255) continue;
          worst = Math.min(worst, ratio(fg, rgb));
        }
      }
      if (!Number.isFinite(worst)) continue;
      measured += 1;
      const threshold = info.large ? 3 : 4.5;
      if (worst < threshold) {
        out.push({ contributor: 'contrast-render', outcome: 'needs-review', basis: '◐', impact: 'serious', selector: n.selector, cropSelector: n.selector, data: { worst_ratio: Math.round(worst * 100) / 100, threshold } });
      }
    }
    // Nothing sampled: the unit is missing, never a pass.
    if (!measured) return [{ contributor: 'contrast-render', missing: 'not-measured' }];
    if (!out.length) out.push({ contributor: 'contrast-render', outcome: 'pass' });
    return out;
  },
};
