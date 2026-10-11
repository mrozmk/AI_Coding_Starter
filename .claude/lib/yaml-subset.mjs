// Minimal YAML subset reader shared by /audit-security (policies/*.yaml) and backlog-check.mjs
// (docs/map/system.yaml). Supports: block maps by indentation, `- ` lists of scalars or maps,
// `[a, b]` inline lists, quoted/bare scalars, `#` comments. No anchors, no multi-line scalars,
// no `{flow: maps}`. A `#` preceded by whitespace always starts a comment — `#` inside a value is
// unsupported. A full YAML dependency is not allowed (node: builtins only, ships to every downstream).

export function parseYaml(text) {
  // `lines` is private to this call; parseList rewrites map-item lines in place.
  const lines = text.split(/\r?\n/)
    .map((raw) => raw.replace(/\s+#.*$/, '').replace(/^\s*#.*$/, ''))
    .filter((l) => l.trim() !== '');
  const [value, next] = parseBlock(lines, 0, indentOf(lines[0] ?? ''));
  if (next < lines.length) throw new Error(`yaml: unexpected indent at line: ${lines[next]}`);
  return value ?? {};
}

function indentOf(line) { return line.length - line.trimStart().length; }

function parseBlock(lines, i, indent) {
  if (i >= lines.length) return [null, i];
  const first = lines[i].trim();
  if (first.startsWith('- ')) return parseList(lines, i, indent);
  const out = {};
  while (i < lines.length) {
    const ind = indentOf(lines[i]);
    if (ind < indent) break;
    if (ind > indent) throw new Error(`yaml: unexpected indent at line: ${lines[i]}`);
    const line = lines[i].trim();
    const m = /^([^:]+):(.*)$/.exec(line);
    if (!m) throw new Error(`yaml: expected key: value, got: ${line}`);
    const key = m[1].trim();
    const rest = m[2].trim();
    i += 1;
    if (rest === '') {
      const child = i < lines.length && indentOf(lines[i]) > indent ? parseBlock(lines, i, indentOf(lines[i])) : [{}, i];
      out[key] = child[0];
      i = child[1];
    } else {
      out[key] = scalar(rest);
    }
  }
  return [out, i];
}

// `- key: value` opens a map item; the remaining keys of that item sit at indent + 2. The regex
// rejects URLs (`https://x` — colon not followed by whitespace) and quoted scalars.
const MAP_ITEM = /^[A-Za-z_][\w-]*:(\s|$)/;

function parseList(lines, i, indent) {
  const out = [];
  while (i < lines.length && indentOf(lines[i]) === indent && lines[i].trim().startsWith('- ')) {
    const content = lines[i].trim().slice(2).trim();
    if (MAP_ITEM.test(content)) {
      lines[i] = ' '.repeat(indent + 2) + content;
      const [item, next] = parseBlock(lines, i, indent + 2);
      out.push(item);
      i = next;
    } else {
      out.push(scalar(content));
      i += 1;
    }
  }
  return [out, i];
}

function scalar(s) {
  if (s.startsWith('[') && s.endsWith(']')) {
    const inner = s.slice(1, -1).trim();
    return inner === '' ? [] : inner.split(',').map((x) => scalar(x.trim()));
  }
  if ((s.startsWith('"') && s.endsWith('"')) || (s.startsWith("'") && s.endsWith("'"))) return s.slice(1, -1);
  if (s === 'true') return true;
  if (s === 'false') return false;
  if (s === 'null' || s === '~') return null;
  if (/^-?\d+(\.\d+)?$/.test(s)) return Number(s);
  return s;
}
