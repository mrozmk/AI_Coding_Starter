// redact.mjs — the collection policy applied before anything is persisted or packed.
export const EMAIL_RE = /[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/g;

export function redactText(text) {
  if (text === null || text === undefined) return text;
  return String(text).replace(EMAIL_RE, '[email]');
}

// Keeps scheme, host and path; query values and the fragment become "…"; user-info is refused.
export function redactUrl(text) {
  if (text === null || text === undefined) return text;
  let u;
  try { u = new URL(String(text)); } catch { return redactText(String(text)).replace(/\?.*$/, '?…'); }
  if (u.username || u.password) return `${u.protocol}//[credentials-removed]@${u.host}${u.pathname}`;
  let out = `${u.protocol}//${u.host}${redactText(u.pathname)}`;
  if (u.search) {
    const keys = [...new URLSearchParams(u.search).keys()].map((k) => redactText(k));
    out += `?${keys.map((k) => `${k}=…`).join('&')}`;
  }
  if (u.hash) out += '#…';
  return out;
}

const AX_FIELDS = ['role', 'name', 'description', 'ignored', 'ignoredReasons', 'states'];

// Accessibility-tree excerpt with an allowlist of fields — never `value`.
export function axExcerpt(node) {
  if (!node || typeof node !== 'object') return null;
  const out = {};
  for (const f of AX_FIELDS) {
    if (node[f] === undefined) continue;
    const v = node[f];
    if (v && typeof v === 'object' && 'value' in v && !Array.isArray(v)) out[f] = redactText(v.value);
    else if (Array.isArray(v)) out[f] = v.map((x) => (x && typeof x === 'object' ? redactText(x.name?.value ?? x.name ?? x.value ?? '') : redactText(x)));
    else out[f] = typeof v === 'string' ? redactText(v) : v;
  }
  return out;
}
