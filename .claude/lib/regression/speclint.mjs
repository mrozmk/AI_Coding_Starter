// Static scan of regression spec code: the comment stripper and import helpers shared with the run
// pre-flight (run.mjs `checkIntegration`), and `lintSpec` — the mechanical half of the spec rules
// (.claude/skills/regression/references/spec-rules.md) over a candidate spec and the transitive
// closure of its relative imports. The closure (`files`) is the candidate's executable surface:
// verify hashes it into `inputs_sha256` and claim re-hashes it, so a changed helper invalidates both.
// Library only (no CLI — `author.mjs lint` prints it). Imports only node: and ./catalog.mjs, so it
// never forms a cycle with run.mjs. Contract: .agents/reference/regression.md §14.

import fs from 'node:fs';
import path from 'node:path';
import { loadCatalog, needsKeys, accountOf, oneLine, posix, HEADER } from './catalog.mjs';

export const GUARD_MODULE = /\.claude\/lib\/regression\/guard\.mjs$/;
// Calls that install a route of the spec's own: a page or context route a spec adds is matched
// before the guard's context route, and `continue()` there sends the request unguarded.
export const OWN_ROUTE_CALLS = ['.route(', 'routeFromHAR', '.routeWebSocket('];

/**
 * The text with `//` and `/* *\/` comments removed, string literals kept whole: a `/*` inside a
 * string such as a route glob `'**\/*.png'` opens no comment. A backslash outside a string escapes
 * the next character (a regex literal's `\/\/` is no comment). Newlines are kept, so line numbers hold.
 */
export function stripComments(s) {
  let out = '';
  for (let i = 0; i < s.length; i += 1) {
    const c = s[i];
    if (c === '\\') { out += s.slice(i, i + 2); i += 1; continue; }
    if (c === "'" || c === '"' || c === '`') {
      let j = i + 1;
      while (j < s.length && s[j] !== c && !(c !== '`' && s[j] === '\n')) j += s[j] === '\\' ? 2 : 1;
      out += s.slice(i, j + 1);
      i = j;
      continue;
    }
    if (c === '/' && s[i + 1] === '/') { while (i < s.length && s[i] !== '\n') i += 1; out += '\n'; continue; }
    if (c === '/' && s[i + 1] === '*') {
      const end = s.indexOf('*/', i + 2);
      out += s.slice(i, end < 0 ? s.length : end + 2).replace(/[^\n]/g, '');
      i = end < 0 ? s.length : end + 1;
      continue;
    }
    out += c;
  }
  return out;
}

/** The text minus whole-line `//` comments only: a forbidden key is searched fail-closed (a mention elsewhere refuses). */
export const dropCommentLines = (s) => s.split('\n').filter((l) => !/^\s*\/\//.test(l)).join('\n');

/** Import statements of a module: `[{bindings: [names], from}]` (named imports, comments stripped). */
export function importsOf(text) {
  const out = [];
  const re = /^\s*import\s+([^;]*?)\s+from\s+['"]([^'"]+)['"]/gm;
  let m;
  while ((m = re.exec(stripComments(text)))) {
    const named = /\{([^}]*)\}/.exec(m[1]);
    const bindings = named ? named[1].split(',').map((b) => b.trim().split(/\s+as\s+/)[0].trim()).filter(Boolean) : [];
    out.push({ bindings, from: m[2] });
  }
  return out;
}

export function resolveModule(fromFile, spec) {
  const base = path.resolve(path.dirname(fromFile), spec);
  for (const c of [base, `${base}.ts`, `${base}.js`, `${base}.mjs`, path.join(base, 'index.ts')]) {
    if (fs.existsSync(c) && fs.statSync(c).isFile()) return c;
  }
  return null;
}

/** Every module specifier of a stripped text — `import … from`, `export … from`, a bare `import '…'` — with its line. */
function specifiersOf(code) {
  const out = [];
  const lineAt = (i) => code.slice(0, i).split('\n').length;
  for (const re of [/\b(?:import|export)\s[^;'"`]*?\bfrom\s*['"]([^'"]+)['"]/g, /^\s*import\s*['"]([^'"]+)['"]/gm]) {
    let m;
    while ((m = re.exec(code))) out.push({ from: m[1], line: lineAt(m.index) });
  }
  return out;
}

// Every scanned module but the fixtures one: nothing reaches the network or the process but the guard.
const NETWORK_CALLS = ['fetch(', 'require(', 'import(', 'XMLHttpRequest', 'WebSocket(', 'newContext(', 'launch(', 'connect(', 'process.env'];
// The spec only: waits, locators, skip markers and retries the spec rules forbid.
/** The needles that set retries in a spec — verify reports them as `retries are not 0 — spec`. */
export const RETRY_NEEDLES = ['describe.configure(', 'retries'];
const SPEC_CALLS = [
  'waitForTimeout(', 'setTimeout(', ".locator('", '.locator("', '.locator(`', '$(', '$$(', '$eval(', 'xpath=',
  'test.skip', 'test.fixme', 'test.fail', 'test.only', '.skip(', ...RETRY_NEEDLES,
];

/** `[{line, needle}]` of every occurrence of each needle in `code`. */
function occurrences(code, needles) {
  const out = [];
  code.split('\n').forEach((l, i) => { for (const n of needles) if (l.includes(n)) out.push({ line: i + 1, needle: n }); });
  return out;
}

/**
 * The violations of one candidate spec for scenario `id`: `{violations: [{file, line, rule, needle?}], files, title}`
 * (`needle`: the forbidden call a spec-rule violation matched).
 * `files` is the scanned closure (the spec, its fixtures module and every relative helper), sorted
 * and repo-relative; `title` is the test declaration's title (null when none). The header and the
 * unobservable lines are read raw; the rest after stripComments.
 */
export function lintSpec(root, cfg, specPath, id) {
  const violations = [];
  const rel = (f) => posix(path.relative(root, f));
  const add = (file, line, rule, needle) => violations.push(needle ? { file, line, rule, needle } : { file, line, rule });
  const { settings, blocks } = loadCatalog(root, cfg);
  const block = blocks.find((b) => b.id === id);
  const specFile = path.resolve(root, specPath);
  let raw;
  try { raw = fs.readFileSync(specFile, 'utf8').replace(/\r/g, ''); } catch { return { violations: [{ file: specPath, line: 0, rule: 'spec file absent' }], files: [], title: null }; }
  if (!block) add(specPath, 0, `no scenario ${id} in the catalog`);
  const code = stripComments(raw);

  // The test declaration, its title and tags.
  const decls = [...code.matchAll(/\btest\(\s*['"`]/g)];
  if (decls.length !== 1) add(specPath, 1, `exactly one test( declaration expected, found ${decls.length}`);
  const title = /\btest\(\s*(['"`])(.*?)\1/.exec(code);
  if (title && !title[2].startsWith(`${id} — `)) add(specPath, code.slice(0, title.index).split('\n').length, `title must start with ${id} — `);
  if (!/['"`]@regression['"`]/.test(code) || !/\btag\s*:/.test(code)) add(specPath, 1, 'tag @regression missing ({ tag: [...] })');
  const smoke = new Set(settings.smoke).has(block?.fields.Priority?.value);
  if (/['"`]@smoke['"`]/.test(code) !== smoke) add(specPath, 1, smoke ? 'tag @smoke missing for a smoke priority' : 'tag @smoke on a priority outside catalog.smoke');

  // The header copies the catalog Source.
  const header = raw.split('\n').map((l) => HEADER.exec(l)).find((m) => m && m[1] === id);
  const source = oneLine(block?.fields.Source?.value ?? '').trim();
  if (!header) add(specPath, 1, `header // regression: ${id} · source: <Source> missing`);
  else if (block && header[2].trim() !== source) add(specPath, 1, `header source ${header[2].trim()} differs from the catalog Source ${source}`);

  // The account: Needs is the only authority.
  const account = accountOf(needsKeys(block?.fields.Needs?.value));
  const use = /\btest\.use\(\s*\{\s*account\s*:\s*(null|'([^']*)'|"([^"]*)")\s*,?\s*\}\s*\)/.exec(code);
  const used = use ? (use[1] === 'null' ? null : use[2] ?? use[3]) : null;
  if (account && used !== account) add(specPath, 1, `account:${account} in Needs needs test.use({ account: '${account}' })`);
  else if (!account && used !== null) add(specPath, 1, `test.use account ${used} but no account in Needs`);

  // test from a relative module = the fixtures module.
  const testImport = importsOf(raw).find((i) => i.bindings.includes('test'));
  let fixtures = null;
  if (!testImport || !testImport.from.startsWith('.')) add(specPath, 1, 'test is not imported from a relative module (the guarded fixtures)');
  else {
    fixtures = resolveModule(specFile, testImport.from);
    if (!fixtures) add(specPath, 1, `unresolvable import ${testImport.from}`);
  }
  for (const o of occurrences(code, SPEC_CALLS)) add(specPath, o.line, `forbidden ${o.needle}`, o.needle);

  // The closure: the spec, then every relative import, breadth first; the fixtures module is a leaf.
  const visited = new Set();
  const queue = [specFile];
  if (fixtures) visited.add(fixtures);
  while (queue.length) {
    const file = queue.shift();
    if (visited.has(file)) continue;
    visited.add(file);
    let text;
    try { text = file === specFile ? raw : fs.readFileSync(file, 'utf8').replace(/\r/g, ''); } catch { add(rel(file), 0, 'unreadable'); continue; }
    const c = stripComments(text);
    for (const s of specifiersOf(c)) {
      if (!s.from.startsWith('.')) { add(rel(file), s.line, `non-relative import ${s.from}`); continue; }
      const mod = resolveModule(file, s.from);
      if (!mod) add(rel(file), s.line, `unresolvable import ${s.from}`);
      else if (!visited.has(mod)) queue.push(mod);
    }
    scanCommon(c, rel(file), add, { network: true });
  }
  if (fixtures) {
    try { scanCommon(stripComments(fs.readFileSync(fixtures, 'utf8')), rel(fixtures), add, { network: false }); } catch { add(rel(fixtures), 0, 'unreadable'); }
  }
  return { violations, files: [...visited].map(rel).sort(), title: title?.[2] ?? null };
}

/** Route and context-default rules for every scanned module; the network and process rules unless exempt. */
function scanCommon(code, file, add, { network }) {
  for (const o of occurrences(code, OWN_ROUTE_CALLS)) add(file, o.line, `installs its own route (${o.needle}) — it would take precedence over the guard`);
  for (const o of occurrences(code, ['extraHTTPHeaders', 'httpCredentials'])) add(file, o.line, `sets ${o.needle}`);
  if (network) for (const o of occurrences(code, NETWORK_CALLS)) add(file, o.line, `forbidden ${o.needle}`);
}
