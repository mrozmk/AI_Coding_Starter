// semantic.mjs — the producer of judge input (readonly, always runs on the initial state): images with
// a non-empty alt that loaded, link/button names with context, headings, labels, language changes,
// error texts and help links. A broken image (an HTTP error, a load that failed on the network, or a
// file that answered 2xx but cannot be decoded) is never an item: it is the runner finding
// broken-image (1.1.1, ●) with its load diagnostic. An image
// that simply never loaded — lazy content the lockdown blocked or never requested — is neither.
import { inPage } from '../dom.mjs';
import { redactText, redactUrl, axExcerpt } from '../redact.mjs';

const PER_KIND = 15;

export const brokenImage = { id: 'broken-image', sc: ['1.1.1'] };

// Refusals by the run's own browser boundary: the route lockdown and the proxy (CONNECT 403 for https).
const NOT_ORIGIN_ERRORS = /ERR_BLOCKED_BY_CLIENT|ERR_TUNNEL_CONNECTION_FAILED/;

export async function collectSemantic(page, { responses, failed = new Map(), proxyBlocked = new Set(), cdp }) {
  const raw = await inPage(page, `
    const all = W.all();
    // decode() is asked only of a complete image, so it starts no request; a sizeless SVG resolves.
    const decodeFailed = (el, src) => (el.complete && el.naturalWidth === 0 && src ? el.decode().then(() => false, () => true) : Promise.resolve(false));
    const imgPromise = Promise.all(all.filter((el) => el.tagName === 'IMG').map((el) => { const src = el.currentSrc || el.src; return decodeFailed(el, src).then((df) => ({ sel: W.sel(el), src, alt: el.getAttribute('alt'), loaded: el.complete && el.naturalWidth > 0, visible: W.visible(el), decodeFailed: df })); }));
    const ctx = (el) => { const p = el.closest('p, li, td, th, h1, h2, h3, h4, h5, h6, figcaption') || el.parentElement; return p ? p.textContent.trim().replace(/\\s+/g, ' ').slice(0, 200) : ''; };
    const name = (el) => (el.getAttribute('aria-label') || el.textContent || el.getAttribute('title') || '').trim().replace(/\\s+/g, ' ').slice(0, 200);
    const links = all.filter((el) => el.matches('a[href], button, [role=button], [role=link]') && W.visible(el)).map((el) => ({ sel: W.sel(el), kind: 'link-purpose', text: name(el), context: ctx(el) }));
    const labelled = all.filter((el) => el.matches('a[href], button') && el.getAttribute('aria-label') && el.textContent.trim()).map((el) => ({ sel: W.sel(el), kind: 'label-in-name', text: 'visible: ' + el.textContent.trim().slice(0, 100) + ' | name: ' + el.getAttribute('aria-label').slice(0, 150) }));
    const headings = all.filter((el) => el.matches('h1, h2, h3, h4, h5, h6, [role=heading]') && W.visible(el)).map((el) => ({ sel: W.sel(el), kind: 'heading-label', text: el.tagName + ': ' + el.textContent.trim().slice(0, 150) }));
    const labels = all.filter((el) => el.tagName === 'LABEL' && W.visible(el)).map((el) => ({ sel: W.sel(el), kind: 'heading-label', text: 'label: ' + el.textContent.trim().slice(0, 150) }));
    const langs = all.filter((el) => el !== document.documentElement && el.hasAttribute('lang')).map((el) => ({ sel: W.sel(el), kind: 'language-of-parts', text: el.getAttribute('lang') + ': ' + el.textContent.trim().slice(0, 150) }));
    const errors = all.filter((el) => el.matches('[role=alert], [aria-invalid=true], .error, .invalid-feedback') && el.textContent.trim()).map((el) => ({ sel: W.sel(el), kind: 'error-text', text: el.textContent.trim().slice(0, 200) }));
    const help = all.filter((el) => el.matches('a[href]') && /help|pomoc|kontakt|contact|support|faq/i.test(el.textContent)).map((el) => ({ sel: W.sel(el), kind: 'consistent-help', text: el.textContent.trim().slice(0, 80) }));
    const outline = all.filter((el) => /^H[1-6]$/.test(el.tagName)).map((el) => el.tagName + ' ' + el.textContent.trim().slice(0, 60)).slice(0, 40);
    return imgPromise.then((imgs) => ({ imgs, groups: [links, labelled, headings, labels, langs, errors, help], outline }));
  `);
  const broken = [];
  const items = [];
  for (const img of raw.imgs) {
    // An image the run itself refused is a coverage limit, never a verified failure.
    if (proxyBlocked.has(img.src)) continue;
    const status = responses.get(img.src);
    const netError = failed.get(img.src);
    const loadFailed = !img.loaded && !!img.src && !!netError && !NOT_ORIGIN_ERRORS.test(netError);
    if ((status && status >= 400) || loadFailed) {
      broken.push({ selector: img.sel, data: { status: status ?? null, url: redactUrl(img.src) } });
      continue;
    }
    if (status >= 200 && status < 300 && img.decodeFailed) {
      broken.push({ selector: img.sel, data: { status, url: redactUrl(img.src), decode: 'failed' } });
      continue;
    }
    if (img.alt && img.alt.trim() && img.loaded && img.visible && (!status || (status >= 200 && status < 300))) {
      items.push({ kind: 'alt-vs-image', selector: img.sel, text: redactText(img.alt.slice(0, 200)), crop: true });
    }
  }
  for (const group of raw.groups) {
    for (const g of group.slice(0, PER_KIND)) items.push({ kind: g.kind, selector: g.sel, text: redactText(g.text), context: g.context ? redactText(g.context) : null, crop: false });
  }
  if (raw.outline.length) items.push({ kind: 'heading-structure', selector: 'html', text: redactText(raw.outline.join('\n')), crop: false });
  if (cdp) await attachAx(page, cdp, items);
  return { items, broken, imageCount: raw.imgs.length };
}

// Accessibility-tree excerpts via CDP: mark the items' elements, find them in the pierced DOM tree by
// backend node id, and keep only the allowlisted fields of their AX nodes.
async function attachAx(page, cdp, items) {
  const sels = items.map((i) => i.selector);
  try {
    await inPage(page, `arg.forEach((s, i) => { const el = W.q(s); if (el) el.setAttribute('data-wcag-item', String(i)); });`, sels);
    const { root } = await cdp.send('DOM.getDocument', { depth: -1, pierce: true });
    const byItem = new Map();
    const walk = (n) => {
      const a = n.attributes || [];
      const k = a.indexOf('data-wcag-item');
      if (k >= 0) byItem.set(Number(a[k + 1]), n.backendNodeId);
      for (const c of [...(n.children || []), ...(n.shadowRoots || [])]) walk(c);
    };
    walk(root);
    const { nodes } = await cdp.send('Accessibility.getFullAXTree');
    const byBackend = new Map(nodes.filter((n) => n.backendDOMNodeId).map((n) => [n.backendDOMNodeId, n]));
    items.forEach((it, i) => {
      const ax = byBackend.get(byItem.get(i));
      if (ax) it.ax_excerpt = axExcerpt({ role: ax.role, name: ax.name, description: ax.description, ignored: ax.ignored, ignoredReasons: ax.ignoredReasons, states: (ax.properties || []).filter((p) => ['expanded', 'checked', 'pressed', 'selected', 'disabled', 'invalid', 'required'].includes(p.name)).map((p) => ({ name: `${p.name}=${p.value?.value}` })) });
    });
  } catch { /* excerpts are optional evidence */ }
  await inPage(page, "document.querySelectorAll('[data-wcag-item]').forEach((el) => el.removeAttribute('data-wcag-item'));").catch(() => {});
}
