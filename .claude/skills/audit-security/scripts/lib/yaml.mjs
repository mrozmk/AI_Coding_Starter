// Minimal YAML subset reader for policies/*.yaml — nested maps by indentation, `- item` block lists,
// `[a, b]` inline lists, quoted/bare scalars, `#` comments. No anchors, no multi-line scalars.
// Enough for a policy file; a full YAML dependency is not allowed (node: builtins only).

export function parseYaml(text) {
  const lines = text.split(/\r?\n/)
    .map((raw) => raw.replace(/\s+#.*$/, '').replace(/^\s*#.*$/, ''))
    .filter((l) => l.trim() !== '');
  const [value] = parseBlock(lines, 0, indentOf(lines[0] ?? ''));
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

function parseList(lines, i, indent) {
  const out = [];
  while (i < lines.length && indentOf(lines[i]) === indent && lines[i].trim().startsWith('- ')) {
    out.push(scalar(lines[i].trim().slice(2).trim()));
    i += 1;
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
