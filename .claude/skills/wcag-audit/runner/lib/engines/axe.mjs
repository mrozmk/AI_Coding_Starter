// engines/axe.mjs — axe-core through @axe-core/playwright with the run's effective rule list
// (runOnly = the planned rule ids, target-size enabled for 2.2 AA). Frames are classified from
// browser-controlled metadata (CDP frame tree), never from page script; skipped frames are excluded,
// ledgered and masked in every crop.
import { load as loadDeps } from '../deps.mjs';
import { scFromAxeTag } from '../criteria.mjs';
import { redactText } from '../redact.mjs';

const IMPACT = { critical: 'blocker', serious: 'serious', moderate: 'moderate', minor: 'minor' };

const PATH_FN = `function () {
  const parts = [];
  let cur = this;
  while (cur && cur.nodeType === 1 && cur !== cur.ownerDocument.documentElement) {
    const parent = cur.parentElement;
    const idx = parent ? Array.prototype.filter.call(parent.children, (c) => c.tagName === cur.tagName).indexOf(cur) + 1 : 1;
    parts.unshift(cur.tagName.toLowerCase() + ':nth-of-type(' + idx + ')');
    cur = parent;
  }
  return 'html > ' + parts.join(' > ');
}`;

// The owner element of each frame in the top document's frame tree, from CDP (DOM.getFrameOwner),
// with the frame's browser-reported security origin. A Playwright frame whose owner is not an
// in-scope tree entry (opaque, other origin, or out-of-process) is skipped.
export async function classifyFrames(page) {
  const skipped = [];
  const entries = [];
  let topOrigin = null;
  let cdp = null;
  try {
    cdp = await page.context().newCDPSession(page);
    const { frameTree } = await cdp.send('Page.getFrameTree');
    topOrigin = frameTree.frame.securityOrigin;
    await cdp.send('DOM.getDocument', { depth: 0 });
    for (const child of frameTree.childFrames || []) {
      try {
        const { backendNodeId } = await cdp.send('DOM.getFrameOwner', { frameId: child.frame.id });
        const { object } = await cdp.send('DOM.resolveNode', { backendNodeId });
        const { result } = await cdp.send('Runtime.callFunctionOn', { objectId: object.objectId, functionDeclaration: PATH_FN, returnByValue: true });
        entries.push({ sel: result.value, origin: child.frame.securityOrigin });
      } catch { /* unresolved owner: the Playwright pass below skips it */ }
    }
  } catch { /* no CDP: every child frame is skipped */ }
  if (cdp) await cdp.detach().catch(() => {});
  const opaque = (o) => !o || o === 'null' || !/^https?:\/\//.test(o);
  for (const frame of page.mainFrame().childFrames()) {
    const sel = await ownerSelector(frame);
    const entry = sel ? entries.find((e) => e.sel === sel) : null;
    if (!entry || opaque(entry.origin) || entry.origin !== topOrigin) skipped.push({ frame, selector: sel, reason: entry ? 'other-origin' : 'owner-unresolved' });
  }
  return { skipped };
}

export async function ownerSelector(frame) {
  try {
    const el = await frame.frameElement();
    // eslint-disable-next-line no-new-func
    return await el.evaluate(new Function(`return (${PATH_FN}).call(arguments[0]);`));
  } catch { return null; }
}

function selectorOf(target) {
  const t = Array.isArray(target) ? target.map((x) => (Array.isArray(x) ? x.join(' >>> ') : x)) : [target];
  return redactText(t.join(' >>> ')).replace(/\[value=(["']).*?\1\]/g, '[value=…]');
}

function frameOf(target) {
  return Array.isArray(target) && target.length > 1 && !Array.isArray(target[0]) ? target.slice(0, -1).join(' | ') : '';
}

export async function runAxe(page, { ruleIds, enableTargetSize, exclude = [], testFault = false }) {
  const { AxeBuilder } = loadDeps();
  if (testFault) throw new Error('test fault: axe analyze');
  let builder = new AxeBuilder({ page }).options({ runOnly: { type: 'rule', values: ruleIds }, rules: enableTargetSize ? { 'target-size': { enabled: true } } : {} });
  for (const sel of exclude) builder = builder.exclude(sel);
  const res = await builder.analyze();
  const out = [];
  const map = (list, outcome) => {
    for (const r of list) {
      const sc = [...new Set(r.tags.map(scFromAxeTag).filter(Boolean))];
      const nodes = r.nodes && r.nodes.length ? r.nodes : [null];
      for (const n of nodes) {
        out.push({
          rule: r.id, sc, outcome,
          impact: IMPACT[(n && n.impact) || r.impact] || 'moderate',
          selector: n ? selectorOf(n.target) : '',
          frame: n ? frameOf(n.target) : '',
          help: r.help, helpUrl: r.helpUrl,
          data: outcome === 'needs-review' && n ? contrastData(n) : null,
        });
      }
    }
  };
  map(res.violations, 'violation');
  map(res.incomplete, 'needs-review');
  map(res.passes, 'pass');
  map(res.inapplicable, 'inapplicable');
  const executed = [...new Set([...res.violations, ...res.incomplete, ...res.passes, ...res.inapplicable].map((r) => r.id))].sort();
  return { results: out, executed, version: res.testEngine?.version ?? null };
}

function contrastData(node) {
  const d = (node.any || []).map((c) => c.data).find((x) => x && typeof x === 'object' && ('fgColor' in x || 'contrastRatio' in x));
  if (!d) return null;
  return { fgColor: d.fgColor ?? null, bgColor: d.bgColor ?? null, contrastRatio: d.contrastRatio ?? null, fontSize: d.fontSize ?? null, fontWeight: d.fontWeight ?? null, messageKey: d.messageKey ?? null };
}
