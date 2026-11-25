// cluster.mjs — finding merge (exact node identity + SC, contributors kept), barrier clustering and
// versioned fingerprints. Normalisation is used for fingerprints and barriers, never for merging.
import crypto from 'node:crypto';

export function nodeKey({ page, viewport, state, frame = '', selector = '', shadow = '' }) {
  return [page, viewport, state, frame, selector, shadow].join('|');
}

// Drops :nth-* indices and ids/classes that contain a digit.
export function norm(selector) {
  return String(selector || '')
    .replace(/:nth-(child|of-type|last-child|last-of-type)\([^)]*\)/g, '')
    .replace(/#[A-Za-z_-]*\d[\w-]*/g, '')
    .replace(/\.[A-Za-z_-]*\d[\w-]*/g, '')
    .replace(/\s+/g, ' ')
    .trim();
}

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export function template(url) {
  let path;
  try { path = new URL(url).pathname; } catch { path = String(url || ''); }
  return path.split('/').map((s) => (/^\d+$/.test(s) || UUID.test(s) ? ':id' : s)).join('/');
}

export function fingerprint(sc, selector, url, checkId) {
  return crypto.createHash('sha256').update(`v1|${sc}|${norm(selector)}|${template(url)}|${checkId}`).digest('hex').slice(0, 16);
}

// Occurrences on the same exact node that share an SC become one finding with every contributor.
export function merge(occurrences) {
  const groups = new Map();
  for (const o of occurrences) {
    const key = o.node_key;
    if (!groups.has(key)) groups.set(key, []);
    groups.get(key).push(o);
  }
  const findings = [];
  for (const list of groups.values()) {
    const merged = [];
    for (const o of list) {
      const hit = merged.find((f) => f.sc.some((s) => o.sc.includes(s)));
      if (hit) {
        hit.sc = [...new Set([...hit.sc, ...o.sc])].sort();
        hit.contributors.push(...o.contributors);
        hit.evidence_ids = [...new Set([...hit.evidence_ids, ...(o.evidence_ids || [])])];
        hit.observation_ids.push(...o.observation_ids);
        if (rankBasis(o.basis) > rankBasis(hit.basis)) { hit.basis = o.basis; hit.outcome = o.outcome; }
        if (rankImpact(o.impact) > rankImpact(hit.impact)) hit.impact = o.impact;
        if (!hit.data && o.data) hit.data = o.data;
      } else {
        merged.push({ ...o, sc: [...o.sc].sort(), contributors: [...o.contributors], evidence_ids: [...(o.evidence_ids || [])], observation_ids: [...o.observation_ids] });
      }
    }
    findings.push(...merged);
  }
  return findings;
}

export function rankBasis(b) {
  return b === '●' ? 2 : b === '◐' ? 1 : 0;
}

const IMPACT = ['minor', 'moderate', 'serious', 'blocker'];
export function rankImpact(i) {
  return IMPACT.indexOf(i);
}

// Barriers cluster findings by nearest interactive/landmark ancestor (normalised) + SC group, across pages.
export function barriers(findings) {
  const map = new Map();
  for (const f of findings) {
    const group = f.sc.map((s) => s.split('.').slice(0, 2).join('.')).sort()[0];
    const key = `${norm(f.ancestor || f.selector)}|${group}`;
    if (!map.has(key)) map.set(key, { key, ancestor: norm(f.ancestor || f.selector), sc_group: group, finding_ids: [], impact: f.impact, basis: f.basis });
    const b = map.get(key);
    b.finding_ids.push(f.id);
    if (rankImpact(f.impact) > rankImpact(b.impact)) b.impact = f.impact;
    if (rankBasis(f.basis) > rankBasis(b.basis)) b.basis = f.basis;
  }
  return [...map.values()];
}
