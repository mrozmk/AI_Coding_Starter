// text-spacing.mjs — 1.4.12: text that was not clipped before is clipped after the WCAG text-spacing
// CSS (● verified).
import { inPage } from '../dom.mjs';

export const SPACING_CSS = '* { line-height: 1.5 !important; letter-spacing: 0.12em !important; word-spacing: 0.16em !important; } p { margin-bottom: 2em !important; }';

export const CLIPPED = `
  const hidden = (v) => v === 'hidden' || v === 'clip';
  return W.all().filter((el) => {
    if (!W.visible(el)) return false;
    if (!Array.from(el.childNodes).some((n) => n.nodeType === 3 && n.textContent.trim())) return false;
    const cs = getComputedStyle(el);
    return (hidden(cs.overflowY) && el.scrollHeight > el.clientHeight + 1) || (hidden(cs.overflowX) && el.scrollWidth > el.clientWidth + 1);
  }).map((el) => W.sel(el));
`;

export default {
  name: 'text-spacing',
  mode: 'mutating',
  contributors: [{ id: 'text-spacing', sc: ['1.4.12'] }],
  doesNotDetect: 'spacing set by script after load; overlap without clipping',
  async run({ page }) {
    const before = new Set(await inPage(page, CLIPPED));
    await page.addStyleTag({ content: SPACING_CSS });
    await page.waitForTimeout(50);
    const after = await inPage(page, CLIPPED);
    const fresh = after.filter((s) => !before.has(s)).slice(0, 10);
    if (!fresh.length) return [{ contributor: 'text-spacing', outcome: 'pass' }];
    return fresh.map((sel) => ({ contributor: 'text-spacing', outcome: 'violation', basis: '●', impact: 'serious', selector: sel, cropSelector: sel,
      steps: ['Apply line-height 1.5, letter-spacing 0.12em, word-spacing 0.16em and paragraph spacing 2em (e.g. with a bookmarklet).', 'The text in this element is cut off.'] }));
  },
};
