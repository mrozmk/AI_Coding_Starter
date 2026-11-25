// dom.mjs — helpers evaluated inside the page. Functions are built in Node and sent through CDP, so
// they work under a page CSP; nothing is installed on window, so page script cannot tamper with them.
// The e-mail pattern is the redaction one, so the crop mask and the text redaction agree.
import { EMAIL_RE } from './redact.mjs';

export const HELPERS = String.raw`
const W = {};
W.all = (root = document) => {
  const out = [];
  const walk = (node) => {
    for (const el of node.querySelectorAll('*')) {
      out.push(el);
      if (el.shadowRoot) walk(el.shadowRoot);
    }
  };
  walk(root);
  return out;
};
W.sel = (el) => {
  const parts = [];
  let cur = el;
  while (cur && cur.nodeType === 1) {
    const root = cur.getRootNode();
    const tag = cur.tagName.toLowerCase();
    if (cur.id && !/\d/.test(cur.id) && root.querySelectorAll('#' + CSS.escape(cur.id)).length === 1) {
      parts.unshift('#' + CSS.escape(cur.id));
    } else {
      const parent = cur.parentElement;
      const sibs = parent ? Array.from(parent.children).filter((c) => c.tagName === cur.tagName) : [];
      parts.unshift(sibs.length > 1 ? tag + ':nth-of-type(' + (sibs.indexOf(cur) + 1) + ')' : tag);
      if (parent) { cur = parent; continue; }
    }
    if (root instanceof ShadowRoot) { parts.unshift('>>>'); cur = root.host; continue; }
    break;
  }
  return parts.join(' > ').replace(/ > >>> > /g, ' >>> ').replace(/^>>> > /, '');
};
W.box = (el) => { const r = el.getBoundingClientRect(); return { x: r.left + window.scrollX, y: r.top + window.scrollY, w: r.width, h: r.height, vx: r.left, vy: r.top }; };
W.visible = (el) => {
  const cs = getComputedStyle(el);
  if (cs.visibility === 'hidden' || cs.display === 'none') return false;
  const r = el.getBoundingClientRect();
  return r.width > 0 && r.height > 0;
};
W.focusables = (root = document) => W.all(root).filter((el) => el.matches('a[href], button, input:not([type=hidden]), select, textarea, summary, [tabindex], [contenteditable=""], [contenteditable=true], iframe') && !el.disabled && !el.closest('[inert]'));
W.ancestor = (el) => {
  let cur = el;
  while (cur && cur.nodeType === 1) {
    if (cur.matches('a[href], button, input, select, textarea, [role=button], [role=link], [role=tab], header, nav, main, footer, aside, form, dialog, [role=dialog], [role=navigation], [role=banner], [role=main], [role=contentinfo]')) return W.sel(cur);
    cur = cur.parentElement || (cur.getRootNode() instanceof ShadowRoot ? cur.getRootNode().host : null);
  }
  return null;
};
W.deepActive = () => { let a = document.activeElement; while (a && a.shadowRoot && a.shadowRoot.activeElement) a = a.shadowRoot.activeElement; return a; };
W.EMAIL = new RegExp(${JSON.stringify(EMAIL_RE.source)});
W.q = (s) => { const parts = String(s).split(' >>> '); let root = document, el = null; for (const p of parts) { try { el = root.querySelector(p); } catch (e) { return null; } if (!el) return null; root = el.shadowRoot || el; } return el; };
W.markEmails = () => {
  let n = 0;
  const walk = (root) => {
    const tw = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
    for (let t = tw.nextNode(); t; t = tw.nextNode()) {
      if (W.EMAIL.test(t.textContent) && t.parentElement) { t.parentElement.setAttribute('data-wcag-mask', ''); n += 1; }
    }
    for (const el of root.querySelectorAll('*')) if (el.shadowRoot) walk(el.shadowRoot);
  };
  walk(document);
  return n;
};
`;

export function inPage(target, body, arg) {
  // eslint-disable-next-line no-new-func
  return target.evaluate(new Function('arg', `${HELPERS}\n${body}`), arg);
}

// W.sel joins shadow boundaries with ' >>> '; Playwright CSS pierces open shadow roots, so a plain
// descendant combinator locates the same element.
export function toLocator(sel) {
  return String(sel).split(' >>> ').join(' ');
}
