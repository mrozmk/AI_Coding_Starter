// focus.mjs — focus-visible (2.4.7) and focus-obscured (2.4.11) over the Tab stops of a state.
// focus-visible ●: the bbox ±12 px is pixel-identical before and after focus and no indicator style
// changes. focus-obscured ●: every point of a 5×5 grid is covered by painted author content
// (elementsFromPoint + opacity/visibility/background/text checks).
import { inPage } from '../dom.mjs';
import { load as loadDeps } from '../deps.mjs';

const MAX_STOPS = 40;
const STYLE_PROPS = ['outline-style', 'outline-width', 'outline-color', 'box-shadow', 'border-top-color', 'border-bottom-color', 'border-left-color', 'border-right-color', 'border-top-width', 'border-bottom-width', 'background-color', 'background-image', 'text-decoration-line', 'color'];

const ACTIVE_INFO = `
  const a = W.deepActive();
  if (!a || a === document.body || a === document.documentElement || a.tagName === 'IFRAME') return null;
  const r = a.getBoundingClientRect();
  const cs = getComputedStyle(a);
  return { sel: W.sel(a), x: r.left, y: r.top, w: r.width, h: r.height, vw: innerWidth, vh: innerHeight, style: arg.map((p) => cs.getPropertyValue(p)) };
`;

const OBSCURED = `
  const a = W.deepActive();
  if (!a) return null;
  const r = a.getBoundingClientRect();
  const isSelfOrDesc = (el) => el === a || a.contains(el) || (el.getRootNode && el.getRootNode().host && a.contains(el.getRootNode().host));
  const isAncestor = (el) => el.contains(a) || (a.getRootNode().host && el.contains(a.getRootNode().host));
  const transparent = (c) => !c || c === 'transparent' || /rgba\\([^)]*,\\s*0\\)$/.test(c);
  const painted = (top) => {
    let op = 1;
    for (let e = top; e && e.nodeType === 1; e = e.parentElement || (e.getRootNode().host || null)) {
      const cs = getComputedStyle(e);
      op *= parseFloat(cs.opacity);
      if (cs.visibility === 'hidden') return 'no';
    }
    if (op < 0.1) return 'no';
    if (/^(CANVAS|VIDEO|IMG|SVG|IFRAME|OBJECT|EMBED)$/i.test(top.tagName)) return 'yes';
    for (let e = top; e && e.nodeType === 1 && !isAncestor(e); e = e.parentElement) {
      const cs = getComputedStyle(e);
      if (!transparent(cs.backgroundColor) || cs.backgroundImage !== 'none') return 'yes';
      if (cs.backdropFilter && cs.backdropFilter !== 'none') return 'unknown';
    }
    if (Array.from(top.childNodes).some((n) => n.nodeType === 3 && n.textContent.trim())) return 'yes';
    return 'no';
  };
  let covered = 0, paintedAll = true, unknown = false, total = 0, cover = null;
  for (let i = 0; i < 5; i += 1) for (let j = 0; j < 5; j += 1) {
    const x = r.left + (r.width * (i + 0.5)) / 5;
    const y = r.top + (r.height * (j + 0.5)) / 5;
    if (x < 0 || y < 0 || x >= innerWidth || y >= innerHeight) continue;
    total += 1;
    const top = document.elementsFromPoint(x, y)[0];
    if (!top || isSelfOrDesc(top) || isAncestor(top)) continue;
    const p = painted(top);
    if (p === 'no') continue;
    covered += 1;
    if (p === 'unknown') unknown = true;
    cover = cover || W.sel(top);
  }
  return { total, covered, unknown, cover };
`;

function diffPixels(PNG, a, b) {
  const pa = PNG.sync.read(a);
  const pb = PNG.sync.read(b);
  if (pa.width !== pb.width || pa.height !== pb.height) return 1;
  let diff = 0;
  for (let i = 0; i < pa.data.length; i += 4) {
    if (pa.data[i] !== pb.data[i] || pa.data[i + 1] !== pb.data[i + 1] || pa.data[i + 2] !== pb.data[i + 2]) diff += 1;
  }
  return diff / (pa.width * pa.height);
}

export default {
  name: 'focus',
  mode: 'mutating',
  contributors: [
    { id: 'focus-visible', sc: ['2.4.7'] },
    { id: 'focus-obscured', sc: ['2.4.11'] },
  ],
  doesNotDetect: 'low-contrast focus indicators (2.4.13 is AAA); obscuring by user-agent UI; partial obscuring (2.4.12 is AAA)',
  async run({ page }) {
    const { PNG } = loadDeps();
    const out = [];
    const seen = new Set();
    let stops = 0;
    for (let i = 0; i < MAX_STOPS * 2 && stops < MAX_STOPS; i += 1) {
      await page.keyboard.press('Tab');
      const info = await inPage(page, ACTIVE_INFO, STYLE_PROPS);
      if (!info) { if (stops) break; continue; }
      if (seen.has(info.sel)) break;
      seen.add(info.sel);
      stops += 1;
      const ob = await inPage(page, OBSCURED);
      if (ob && ob.total > 0 && ob.covered === ob.total) {
        out.push(ob.unknown
          ? { contributor: 'focus-obscured', outcome: 'needs-review', basis: '◐', impact: 'serious', selector: info.sel, cropBox: info, data: { covered_by: ob.cover } }
          : { contributor: 'focus-obscured', outcome: 'violation', basis: '●', impact: 'serious', selector: info.sel, cropBox: info, data: { covered_by: ob.cover },
            steps: ['Press Tab until this element is focused.', 'The focused element is completely hidden by other content.'] });
      }
      const clip = { x: Math.max(0, info.x - 12), y: Math.max(0, info.y - 12) };
      clip.width = Math.min(info.vw, info.x + info.w + 12) - clip.x;
      clip.height = Math.min(info.vh, info.y + info.h + 12) - clip.y;
      if (clip.width < 2 || clip.height < 2) continue;
      const focused = await page.screenshot({ clip, animations: 'disabled', caret: 'hide' });
      await inPage(page, 'const a = W.deepActive(); if (a) a.blur();');
      const blurred = await page.screenshot({ clip, animations: 'disabled', caret: 'hide' });
      const after = await inPage(page, `const el = W.q(arg.sel); if (!el) return null; const cs = getComputedStyle(el); const style = arg.props.map((p) => cs.getPropertyValue(p)); el.focus(); return style;`, { sel: info.sel, props: STYLE_PROPS });
      if (!after) continue;
      const styleChanged = after.some((v, k) => v !== info.style[k]);
      const ratio = diffPixels(PNG, focused, blurred);
      if (ratio === 0 && !styleChanged) {
        out.push({ contributor: 'focus-visible', outcome: 'violation', basis: '●', impact: 'serious', selector: info.sel, cropBox: info,
          steps: ['Press Tab until this element is focused.', 'Nothing in its surroundings changes — there is no visible focus indicator.'] });
      } else if (ratio > 0 && ratio < 0.01 && !styleChanged) {
        out.push({ contributor: 'focus-visible', outcome: 'needs-review', basis: '◐', impact: 'moderate', selector: info.sel, cropBox: info });
      }
    }
    if (!stops) {
      out.push({ contributor: 'focus-visible', outcome: 'inapplicable' }, { contributor: 'focus-obscured', outcome: 'inapplicable' });
    } else {
      if (!out.some((o) => o.contributor === 'focus-visible')) out.push({ contributor: 'focus-visible', outcome: 'pass' });
      if (!out.some((o) => o.contributor === 'focus-obscured')) out.push({ contributor: 'focus-obscured', outcome: 'pass' });
    }
    return out;
  },
};
