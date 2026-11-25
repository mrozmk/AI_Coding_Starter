// arrow-widgets.mjs — inside composite roles, ArrowRight/ArrowDown must move focus or
// aria-activedescendant (2.1.1, ◐ only).
import { inPage } from '../dom.mjs';

const ROLES = '[role=tablist], [role=menu], [role=menubar], [role=grid], [role=radiogroup], [role=listbox], [role=tree]';

const STATE = "const a = W.deepActive(); return { active: a ? W.sel(a) : null, desc: a ? a.getAttribute('aria-activedescendant') : null };";

export default {
  name: 'arrow-widgets',
  mode: 'mutating',
  contributors: [{ id: 'arrow-widgets', sc: ['2.1.1'] }],
  doesNotDetect: 'widgets without a composite role',
  async run({ page }) {
    const widgets = await inPage(page, `return W.all().filter((el) => el.matches(arg) && W.visible(el)).slice(0, 5).map((el) => W.sel(el));`, ROLES);
    if (!widgets.length) return [{ contributor: 'arrow-widgets', outcome: 'inapplicable' }];
    const out = [];
    let tried = 0;
    for (const sel of widgets) {
      const focused = await inPage(page, `
        const c = W.q(arg);
        if (!c) return false;
        const t = c.matches('[tabindex]:not([tabindex="-1"])') ? c : Array.from(c.querySelectorAll('*')).find((el) => el.tabIndex >= 0 && W.visible(el));
        if (!t) return false;
        t.focus();
        return true;
      `, sel).catch(() => false);
      if (!focused) continue;
      tried += 1;
      const before = await inPage(page, STATE);
      let moved = false;
      for (const key of ['ArrowRight', 'ArrowDown']) {
        await page.keyboard.press(key);
        const after = await inPage(page, STATE);
        if (after.active !== before.active || after.desc !== before.desc) { moved = true; break; }
      }
      if (!moved) {
        out.push({ contributor: 'arrow-widgets', outcome: 'needs-review', basis: '◐', impact: 'serious', selector: sel, cropSelector: sel,
          steps: ['Focus the widget with Tab.', 'Press ArrowRight and ArrowDown: neither focus nor the active descendant moves.'] });
      }
    }
    // No widget could be focused: nothing was measured, so the unit is missing, never a pass.
    if (!tried) return [{ contributor: 'arrow-widgets', missing: 'not-measured' }];
    if (!out.length) out.push({ contributor: 'arrow-widgets', outcome: 'pass' });
    return out;
  },
};
