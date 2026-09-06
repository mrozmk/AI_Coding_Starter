// Minimal flat YAML frontmatter: `key: value` lines, quoted or bare scalars, booleans, and
// one-level `key:` + `  - item` lists. Enough for SKILL.md and openai.yaml; not a YAML parser.

export function parseFrontmatter(text) {
  if (!text.startsWith('---\n')) return { data: {}, body: text, raw: '' };
  const end = text.indexOf('\n---', 4);
  if (end === -1) throw new Error('unterminated frontmatter');
  const raw = text.slice(4, end);
  const body = text.slice(end + 4).replace(/^\n/, '');
  const data = {};
  let listKey = null;
  for (const line of raw.split('\n')) {
    if (!line.trim() || line.trimStart().startsWith('#')) continue;
    const item = line.match(/^\s+-\s+(.*)$/);
    if (item && listKey) {
      data[listKey].push(parseScalar(item[1]));
      continue;
    }
    const kv = line.match(/^([A-Za-z0-9_-]+):\s*(.*)$/);
    if (!kv) throw new Error(`frontmatter line not understood: ${line}`);
    if (kv[2] === '') {
      listKey = kv[1];
      data[listKey] = [];
    } else {
      listKey = null;
      data[kv[1]] = parseScalar(kv[2]);
    }
  }
  return { data, body, raw };
}

function parseScalar(v) {
  const s = v.trim();
  if (/^"(.*)"$/.test(s) || /^'(.*)'$/.test(s)) return s.slice(1, -1);
  if (s === 'true') return true;
  if (s === 'false') return false;
  return s;
}

export function serializeScalar(v) {
  if (typeof v === 'boolean') return String(v);
  const s = String(v);
  if (/[:#"'\n]|^\s|\s$|^[-?[\]{}&*!|>%@`]/.test(s) || s === '') {
    return JSON.stringify(s);
  }
  return s;
}

export function serializeFrontmatter(data) {
  const lines = ['---'];
  for (const [k, v] of Object.entries(data)) {
    if (Array.isArray(v)) {
      lines.push(`${k}:`);
      for (const item of v) lines.push(`  - ${serializeScalar(item)}`);
    } else {
      lines.push(`${k}: ${serializeScalar(v)}`);
    }
  }
  lines.push('---');
  return `${lines.join('\n')}\n`;
}
