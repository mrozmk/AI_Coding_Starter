#!/usr/bin/env node
// Deterministic core of /architecture-review's assessment report (report 2). Three subcommands:
//
//   node arch-assess.mjs measure --root <dir> [--focus <path>] [--area <name>=<glob>[,<glob>]]…
//        [--exclude <glob>]… [--commits <n>=50] --out <file>
//     → one JSON file: areas, per-file sizes and signals, the area import graph and its cycles, the
//       comparison with docs/map/system.yaml, change cost per area, safety_flags. Prints
//       `areas=<n> files=<n> graph=<py,js|none> map=<compared|skipped:<reason>>`.
//   node arch-assess.mjs check <auditor|refutation|records> <file> [--submitted <records.json>] [--out <json>]
//     → extracts (auditor/refutation: the whole message or its single ```json block) and validates
//       against ../skills/architecture-review/<kind>-schema.json.
//   node arch-assess.mjs score --records <f> --measure <f> --assessed <f> --out <f>
//     → the scorecard; the rubric lives here, ASSESSMENT.md §5 explains it.
//
// Exit codes: 0 ok · 1 invalid input content (schema, records, unknown area — the message names
// it) · 2 usage / environment (bad flag, not a git repo, unreadable file). Errors go to stderr,
// prefixed `arch-assess: `. Unknown or missing structure is an error, never a default.
//
// Determinism: same tree → byte-identical output. Keys sorted, every list sorted (files by path,
// areas by name — explicit --area flags keep flag order, `(rest)` last), no timestamps, all paths
// relative to --root with `/`.
//
// Scope and inventory: `git ls-files -co --exclude-standard` under --root (dot-directories stay
// in), kept under --focus, minus the run's own artifacts and every --exclude glob. The review
// inventory drops binary files (counted in skipped_files) and prose / lockfiles outside `.claude/`.
// `py` and js/ts files are graphed; a fixed list of other languages gets sizes and branches;
// everything else is `def` (definitions: Markdown commands, JSON/YAML wiring, jq filters, templates)
// — sizes only, never a test, never in safety_flags.
//
// Area rule (auto, when no --area is given), over non-test inventory files under R (focus or root):
// start with every immediate child dir of R holding such files (test dirs never form an area) plus
// `(root)` for real files directly in R. Repeat, largest area first (ties by path), up to depth 8:
// split area A into its file-bearing child dirs when A has no real direct file (package markers
// __init__.py / index.{js,jsx,ts,tsx,mjs,cjs} do not count) and either has exactly one such child,
// or holds > 50 % of all lines with >= 2 children. A file belongs to the deepest area containing it;
// files in none go to `(rest)` (listed when non-empty). An area with 0 source lines is dropped.
//
// safety_flags: a non-test, non-def file with no test evidence (no sibling test, not imported by a
// test, not named by any test file) and >= SAFETY_LINES lines or >= SAFETY_BRANCHES branches.
//
// Node builtins + ./yaml-subset.mjs + ./backlog-check.mjs only — ships to every downstream.

import fs from 'node:fs';
import path from 'node:path';
import readline from 'node:readline';
import { execFileSync, spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { parseYaml } from './yaml-subset.mjs';
import { checkSystem } from './backlog-check.mjs';

export const SAFETY_LINES = 400;
export const SAFETY_BRANCHES = 40;
const AXES = ['boundaries', 'runtime', 'change_cost', 'safety_net'];
const MAX_AREA_DEPTH = 8;
const BUILTIN_EXCLUDES = ['.agents/reference/architecture-review-*', '.agents/reference/architecture-assessment-*', '.agents/handoffs/**'];
const PROSE_EXT = new Set(['md', 'txt', 'rst', 'adoc']);
const LOCKFILES = new Set(['package-lock.json', 'pnpm-lock.yaml', 'yarn.lock']);
const JS_EXT = ['ts', 'tsx', 'mts', 'cts', 'js', 'jsx', 'mjs', 'cjs'];
const SIZES_ONLY = new Set(['sh', 'bash', 'go', 'rs', 'java', 'kt', 'kts', 'rb', 'cs', 'php', 'swift', 'c', 'h', 'cc', 'cpp', 'hpp', 'm', 'scala', 'lua', 'dart', 'vue', 'svelte']);
const HASH_COMMENT = new Set(['py', 'sh', 'bash', 'rb']);
const TEST_DIRS = new Set(['test', 'tests', '__tests__', 'spec']);
const MARKER = /^(__init__\.py|index\.(js|jsx|ts|tsx|mjs|cjs))$/;
const CLASS_AXIS = { 1: 'runtime', 2: 'runtime', 3: 'runtime', 4: 'runtime', 5: 'runtime', 6: 'runtime', 7: 'runtime', 8: 'boundaries', 11: 'boundaries', 10: 'change_cost', 12: 'change_cost', candidate: 'change_cost', 9: 'safety_net' };

class Fail extends Error { constructor(msg, code) { super(msg); this.code = code; } }
const usage = (msg) => { throw new Fail(msg, 2); };
const invalid = (msg) => { throw new Fail(msg, 1); };

const cmp = (a, b) => (a < b ? -1 : a > b ? 1 : 0);
const by = (...keys) => (a, b) => { for (const k of keys) { const c = cmp(a[k], b[k]); if (c) return c; } return 0; };

export function sortKeys(v) {
  if (Array.isArray(v)) return v.map(sortKeys);
  if (v && typeof v === 'object') return Object.fromEntries(Object.keys(v).sort(cmp).map((k) => [k, sortKeys(v[k])]));
  return v;
}
const dump = (obj) => JSON.stringify(sortKeys(obj), null, 2) + '\n';

export function globToRegExp(glob) {
  let re = '';
  for (let i = 0; i < glob.length; i++) {
    const c = glob[i];
    if (c === '*' && glob[i + 1] === '*') {
      if (glob[i + 2] === '/') { re += '(?:.*/)?'; i += 2; } else { re += '.*'; i += 1; }
    } else if (c === '*') re += '[^/]*';
    else if (c === '?') re += '[^/]';
    else re += c.replace(/[.+^${}()|[\]\\]/g, '\\$&');
  }
  return new RegExp(`^${re}$`);
}

function parseArgs(argv, spec) {
  // spec: { flag: 'one' | 'many' | 'bool' } → { flag: value | [values] | true, _: [positionals] }
  const out = { _: [] };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (!a.startsWith('--')) { out._.push(a); continue; }
    const name = a.slice(2);
    const kind = spec[name];
    if (!kind) usage(`unknown flag ${a}`);
    if (kind === 'bool') { out[name] = true; continue; }
    const v = argv[++i];
    if (v === undefined || v.startsWith('--')) usage(`${a} needs a value`);
    if (kind === 'many') (out[name] ??= []).push(v);
    else if (out[name] !== undefined) usage(`${a} given twice`);
    else out[name] = v;
  }
  return out;
}

function readText(file) {
  try { return fs.readFileSync(file, 'utf8'); } catch (e) { usage(`cannot read ${file}: ${e.code ?? e.message}`); }
}
function readJson(file) {
  const text = readText(file);
  try { return JSON.parse(text); } catch (e) { invalid(`${file}: not JSON: ${e.message}`); }
}

// ---------------------------------------------------------------- measure: per-file signals

function extOf(base) {
  const dot = base.lastIndexOf('.');
  return dot > 0 ? base.slice(dot + 1).toLowerCase() : '';
}

function langOf(rel) {
  const ext = extOf(path.posix.basename(rel));
  if (ext === 'py') return 'py';
  if (JS_EXT.includes(ext)) return 'js';
  if (SIZES_ONLY.has(ext)) return ext;
  return 'def';
}

function inInventory(rel) {
  if (rel === '.claude' || rel.startsWith('.claude/')) return true;
  const base = path.posix.basename(rel);
  const ext = extOf(base);
  return !(PROSE_EXT.has(ext) || ext === 'lock' || LOCKFILES.has(base));
}

function isTestPath(rel) {
  const parts = rel.split('/');
  const base = parts.pop();
  if (parts.some((p) => TEST_DIRS.has(p))) return true;
  return /^test_.+\.py$/.test(base) || /_test\.(py|go)$/.test(base) || /\.(test|spec)\.[cm]?[jt]sx?$/.test(base) || /[-_.]test\.sh$/.test(base);
}

function countLines(text) {
  if (text === '') return 0;
  const n = (text.match(/\n/g) ?? []).length;
  return text.endsWith('\n') ? n : n + 1;
}

export function countBranches(text, lang) {
  let code = text.replace(/"(?:\\.|[^"\\\n])*"|'(?:\\.|[^'\\\n])*'|`(?:\\.|[^`\\\n])*`/g, '""');
  code = HASH_COMMENT.has(lang) ? code.replace(/(^|\s)#.*$/gm, '$1') : code.replace(/\/\/.*$/gm, '');
  const keywords = (code.match(/\b(if|elif|elsif|unless|switch|case|when|match)\b/g) ?? []).length;
  const ternaries = (code.match(/(?<!\?)\?(?![.?:])[^?\n]*:/g) ?? []).length;
  return keywords + ternaries;
}

function testStem(base) {
  let s = base.replace(/\.[^.]+$/, '');
  if (s.startsWith('test_')) s = s.slice(5);
  return s.replace(/(_test|-test|\.test|\.spec)$/, '');
}

// Path-like tokens of a text and their suffixes at `/` boundaries: what `mentions` keys match.
function mentionTokens(text) {
  const out = new Set();
  for (const raw of text.match(/[A-Za-z0-9_./-]+/g) ?? []) {
    const tok = raw.replace(/\.+$/, '');
    if (!tok) continue;
    out.add(tok);
    for (let i = tok.indexOf('/'); i !== -1; i = tok.indexOf('/', i + 1)) out.add(tok.slice(i + 1));
  }
  return out;
}

// ---------------------------------------------------------------- measure: import graph

function pyModuleIndex(pyFiles) {
  const index = new Map();
  for (const f of pyFiles) {
    const parts = f.replace(/\.py$/, '').split('/');
    if (parts[parts.length - 1] === '__init__') parts.pop();
    for (let i = 0; i < parts.length; i++) {
      const name = parts.slice(i).join('.');
      if (!index.has(name)) index.set(name, new Set());
      index.get(name).add(f);
    }
  }
  return index;
}

function pyImports(rel, text, index, fileSet) {
  const targets = new Set();
  let unresolved = 0;
  const exact = (name) => { const s = index.get(name); return s && s.size === 1 ? [...s][0] : null; };
  const absolute = (name) => {
    const parts = name.split('.');
    for (let n = parts.length; n > 0; n--) { const hit = exact(parts.slice(0, n).join('.')); if (hit) return hit; }
    return null;
  };
  const relFile = (dir, parts) => {
    const p = parts ? path.posix.join(dir, parts.replace(/\./g, '/')) : dir;
    for (const c of [`${p}.py`, `${p}/__init__.py`]) if (fileSet.has(c.replace(/^\.\//, ''))) return c.replace(/^\.\//, '');
    return null;
  };
  for (const line of text.split('\n')) {
    let m = /^\s*from\s+(\.*[\w.]*)\s+import\s+(.+)/.exec(line);
    if (m) {
      const mod = m[1];
      const names = m[2].replace(/[()\\]/g, ' ').split(',').map((s) => s.trim().split(/\s+/)[0]).filter((s) => /^\w+$/.test(s));
      const hits = [];
      if (mod.startsWith('.')) {
        const dots = mod.match(/^\.+/)[0].length;
        let dir = path.posix.dirname(rel);
        for (let i = 1; i < dots; i++) dir = path.posix.dirname(dir);
        const rest = mod.slice(dots);
        const base = relFile(dir, rest);
        if (base) hits.push(base);
        for (const n of names) { const sub = relFile(dir, rest ? `${rest}.${n}` : n); if (sub) hits.push(sub); }
      } else {
        const base = absolute(mod);
        if (base) hits.push(base);
        for (const n of names) { const sub = exact(`${mod}.${n}`); if (sub) hits.push(sub); }
      }
      if (hits.length) hits.forEach((h) => targets.add(h)); else unresolved++;
      continue;
    }
    m = /^\s*import\s+(.+)/.exec(line);
    if (m) {
      for (const item of m[1].split(',')) {
        const name = item.trim().split(/\s+/)[0];
        if (!/^[\w.]+$/.test(name)) continue;
        const hit = absolute(name);
        if (hit) targets.add(hit); else unresolved++;
      }
    }
  }
  targets.delete(rel);
  return { targets, unresolved };
}

function jsImports(rel, text, fileSet) {
  const specs = new Set();
  const patterns = [
    /\bimport\s+[^'"`;]*?\bfrom\s*['"]([^'"\n]+)['"]/g,
    /\bimport\s*['"]([^'"\n]+)['"]/g,
    /\bexport\s+[^'"`;]*?\bfrom\s*['"]([^'"\n]+)['"]/g,
    /\brequire\s*\(\s*['"]([^'"\n]+)['"]\s*\)/g,
    /\bimport\s*\(\s*['"]([^'"\n]+)['"]\s*\)/g,
  ];
  for (const re of patterns) for (const m of text.matchAll(re)) specs.add(m[1]);
  const targets = new Set();
  let unresolved = 0;
  const isJs = (p) => fileSet.has(p) && langOf(p) === 'js';
  for (const spec of [...specs].sort(cmp)) {
    let hit = null;
    if (spec.startsWith('./') || spec.startsWith('../')) {
      const cand = path.posix.normalize(path.posix.join(path.posix.dirname(rel), spec));
      const tries = [cand, ...JS_EXT.map((e) => `${cand}.${e}`), ...JS_EXT.map((e) => `${cand}/index.${e}`)];
      if (/\.(js|mjs|cjs)$/.test(cand)) {
        const stem = cand.replace(/\.(js|mjs|cjs)$/, '');
        tries.push(...['ts', 'tsx', 'mts', 'cts'].map((e) => `${stem}.${e}`));
      }
      hit = tries.find(isJs) ?? null;
    }
    if (hit && hit !== rel) targets.add(hit); else if (!hit) unresolved++;
  }
  return { targets, unresolved };
}

function tarjan(nodes, adj) {
  let index = 0;
  const idx = new Map(), low = new Map(), on = new Set(), stack = [], out = [];
  const visit = (v) => {
    idx.set(v, index); low.set(v, index); index++;
    stack.push(v); on.add(v);
    for (const w of adj.get(v) ?? []) {
      if (!idx.has(w)) { visit(w); low.set(v, Math.min(low.get(v), low.get(w))); }
      else if (on.has(w)) low.set(v, Math.min(low.get(v), idx.get(w)));
    }
    if (low.get(v) === idx.get(v)) {
      const comp = [];
      let w;
      do { w = stack.pop(); on.delete(w); comp.push(w); } while (w !== v);
      if (comp.length > 1) out.push(comp.sort(cmp));
    }
  };
  for (const v of [...nodes].sort(cmp)) if (!idx.has(v)) visit(v);
  return out.sort((a, b) => cmp(a.join('\0'), b.join('\0')));
}

// ---------------------------------------------------------------- measure: areas

function deriveAutoAreas(files, R) {
  // files: non-test inventory entries {path, lines}; returns sorted area dirs and `(root)` when present.
  const rel = (p) => (R ? p.slice(R.length + 1) : p);
  const total = files.reduce((s, f) => s + f.lines, 0);
  const childDirs = (dir) => {
    const prefix = dir === null ? '' : dir + '/';
    const dirs = new Set();
    for (const f of files) {
      const r = rel(f.path);
      if (!r.startsWith(prefix)) continue;
      const tail = r.slice(prefix.length).split('/');
      if (tail.length > 1 && !TEST_DIRS.has(tail[0])) dirs.add(prefix + tail[0]);
    }
    return [...dirs];
  };
  const hasRealDirect = (dir) => files.some((f) => { const r = rel(f.path); return path.posix.dirname(r) === dir && !MARKER.test(path.posix.basename(r)); });
  const linesUnder = (dir) => files.reduce((s, f) => s + (rel(f.path).startsWith(dir + '/') ? f.lines : 0), 0);
  let areas = childDirs(null);
  const rootArea = files.some((f) => !rel(f.path).includes('/') && !MARKER.test(path.posix.basename(f.path)));
  for (;;) {
    const ranked = areas.map((d) => ({ d, lines: linesUnder(d) })).sort((a, b) => b.lines - a.lines || cmp(a.d, b.d));
    const pick = ranked.find(({ d, lines }) => {
      if (d.split('/').length >= MAX_AREA_DEPTH || hasRealDirect(d)) return false;
      const kids = childDirs(d);
      return kids.length === 1 || (kids.length >= 2 && 2 * lines > total);
    });
    if (!pick) break;
    areas = areas.filter((d) => d !== pick.d).concat(childDirs(pick.d));
  }
  return { dirs: areas.map((d) => (R ? `${R}/${d}` : d)), rootArea };
}

// ---------------------------------------------------------------- measure: change cost

async function changeCost(root, areaOf, areaNames, limit, revision) {
  if (revision === null) return { skipped: 'no history' };
  const prefix = execFileSync('git', ['-C', root, 'rev-parse', '--show-prefix'], { encoding: 'utf8' }).trim();
  const samples = new Map(areaNames.map((a) => [a, []]));
  const full = () => [...samples.values()].every((s) => s.length >= limit);
  const child = spawn('git', ['-C', root, '-c', 'core.quotePath=false', 'log', '--no-merges', '--format=%x00%H', '--name-only'], { stdio: ['ignore', 'pipe', 'pipe'] });
  let stderr = '';
  child.stderr.on('data', (d) => { stderr += d; });
  let killed = false;
  let current = null;
  const flush = () => {
    if (!current) return;
    const touched = new Set();
    for (const p of current) {
      if (prefix && !p.startsWith(prefix)) continue;
      const a = areaOf(prefix ? p.slice(prefix.length) : p);
      if (a) touched.add(a);
    }
    for (const a of touched) { const s = samples.get(a); if (s.length < limit) s.push(current.length); }
    current = null;
  };
  const rl = readline.createInterface({ input: child.stdout });
  const closed = new Promise((resolve) => child.on('close', (code) => resolve(code)));
  for await (const line of rl) {
    if (killed) break;
    if (line.startsWith('\0')) {
      flush();
      if (full()) { killed = true; child.kill(); break; }
      current = [];
    } else if (line && current) current.push(line);
  }
  if (!killed) flush();
  rl.close();
  const code = await closed;
  if (!killed && code !== 0) return { skipped: `git log failed: ${(stderr.split('\n')[0] || `exit ${code}`).trim()}` };
  const out = {};
  for (const [a, s] of samples) {
    if (!s.length) { out[a] = { commits: 0, median_files: null, max_files: null }; continue; }
    const sorted = [...s].sort((x, y) => x - y);
    const mid = sorted.length >> 1;
    out[a] = { commits: s.length, median_files: sorted.length % 2 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2, max_files: sorted[sorted.length - 1] };
  }
  return out;
}

// ---------------------------------------------------------------- measure: map

function compareMap(root, fileArea, fileEdges) {
  const file = path.join(root, 'docs/map/system.yaml');
  if (!fs.existsSync(file)) return { skipped: 'absent' };
  const real = path.relative(fs.realpathSync(root), fs.realpathSync(file));
  if (real.startsWith('..') || path.isAbsolute(real) || !fs.statSync(file).isFile()) return { skipped: 'outside the root' };
  let parsed;
  try { parsed = parseYaml(fs.readFileSync(file, 'utf8')); } catch (e) { return { skipped: `unparseable: ${e.message}` }; }
  const { errors } = checkSystem(parsed);
  if (errors.length) return { skipped: `invalid: ${errors[0]}` };
  const nodes = parsed.nodes;
  const globs = new Map();
  for (const n of nodes) {
    const code = n.code === undefined ? [] : [].concat(n.code);
    if (code.length) globs.set(n.id, code.map((g) => globToRegExp(String(g))));
  }
  if (!globs.size) return { skipped: 'no code globs' };
  const nodeOf = new Map();
  for (const f of fileArea.keys()) {
    for (const n of nodes) if (globs.get(n.id)?.some((re) => re.test(f))) { nodeOf.set(f, n.id); break; }
  }
  const nodeEdges = new Map();
  for (const [from, tos] of fileEdges) {
    const a = nodeOf.get(from);
    if (!a) continue;
    for (const to of tos) {
      const b = nodeOf.get(to);
      if (!b || a === b) continue;
      const k = `${a}\0${b}`;
      nodeEdges.set(k, (nodeEdges.get(k) ?? 0) + 1);
    }
  }
  const incomparable = [];
  const expected = new Map(); // "importer\0imported" → [link kinds]
  const linked = new Set();
  for (const l of parsed.links ?? []) {
    linked.add(`${l.from}\0${l.to}`); linked.add(`${l.to}\0${l.from}`);
    let pair = null;
    if (['calls', 'acl', 'conformist'].includes(l.kind)) pair = [l.from, l.to];
    else if (['ohs', 'customer-supplier'].includes(l.kind)) pair = [l.to, l.from];
    let reason = null;
    if (!pair) reason = `kind ${l.kind} declares no import direction`;
    else if (!globs.has(l.from) || !globs.has(l.to)) reason = `node ${!globs.has(l.from) ? l.from : l.to} has no code globs`;
    if (reason) { incomparable.push({ from: l.from, to: l.to, kind: l.kind, reason }); continue; }
    const k = pair.join('\0');
    if (!expected.has(k)) expected.set(k, []);
    expected.get(k).push(l.kind);
  }
  const against = [], undeclared = [];
  for (const [k, count] of nodeEdges) {
    const [importer, imported] = k.split('\0');
    const reverse = expected.get(`${imported}\0${importer}`);
    if (reverse && !expected.has(k)) against.push({ importer, imported, link_kind: [...reverse].sort(cmp)[0] });
    if (!linked.has(k)) undeclared.push({ importer, imported, count });
  }
  return {
    against: against.sort(by('importer', 'imported')),
    incomparable: incomparable.sort(by('from', 'to', 'kind')),
    undeclared: undeclared.sort(by('importer', 'imported')),
  };
}

// ---------------------------------------------------------------- measure

export async function measure(opts) {
  const root = path.resolve(opts.root);
  const commits = opts.commits === undefined ? 50 : Number(opts.commits);
  if (!Number.isInteger(commits) || commits < 1) usage(`--commits must be a positive integer, got ${opts.commits}`);
  let listing;
  try { listing = execFileSync('git', ['-C', root, 'ls-files', '-co', '--exclude-standard', '-z'], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'], maxBuffer: 1 << 30 }); } catch { usage(`not a git repository: ${opts.root}`); }
  const focus = (opts.focus ?? '').replace(/^\.\//, '').replace(/\/+$/, '');
  const R = focus === '.' ? '' : focus;
  const excludes = [...BUILTIN_EXCLUDES, ...(opts.exclude ?? [])].map(globToRegExp);
  const candidates = [...new Set(listing.split('\0').filter(Boolean))].sort(cmp)
    .filter((p) => !R || p === R || p.startsWith(R + '/'))
    .filter((p) => !excludes.some((re) => re.test(p)));

  const entries = [];
  let skipped = 0;
  for (const rel of candidates) {
    if (!inInventory(rel)) continue;
    const abs = path.join(root, rel);
    let buf;
    try {
      const st = fs.lstatSync(abs);
      if (!st.isFile()) { skipped++; continue; }
      buf = fs.readFileSync(abs);
    } catch { skipped++; continue; }
    if (buf.subarray(0, 8192).includes(0)) { skipped++; continue; }
    const text = buf.toString('utf8');
    const lang = langOf(rel);
    entries.push({ path: rel, text, lang, lines: countLines(text), test: lang !== 'def' && isTestPath(rel) });
  }
  const fileSet = new Set(entries.map((e) => e.path));

  // sizes, branches, sibling tests
  const testStems = new Map(); // stem → [dir]
  for (const e of entries.filter((x) => x.test)) {
    const stem = testStem(path.posix.basename(e.path));
    if (!testStems.has(stem)) testStems.set(stem, []);
    testStems.get(stem).push(path.posix.dirname(e.path));
  }
  for (const e of entries) {
    e.branches = e.lang === 'def' ? null : countBranches(e.text, e.lang);
    const stem = path.posix.basename(e.path).replace(/\.[^.]+$/, '');
    const dir = path.posix.dirname(e.path);
    const ancestors = [];
    for (let d = dir; ; d = path.posix.dirname(d)) { ancestors.push(d); if (d === '.') break; }
    const homes = new Set([dir]);
    for (const a of ancestors) for (const t of TEST_DIRS) if (t !== 'spec') homes.add(a === '.' ? t : `${a}/${t}`);
    e.sibling_test = !e.test && (testStems.get(stem) ?? []).some((d) => homes.has(d));
  }

  // import graph
  const fileEdges = new Map();
  const unresolved = {};
  const graphed = new Set();
  const pyIndex = pyModuleIndex(entries.filter((e) => e.lang === 'py').map((e) => e.path));
  for (const e of entries) {
    if (e.lang !== 'py' && e.lang !== 'js') continue;
    graphed.add(e.lang);
    const { targets, unresolved: u } = e.lang === 'py' ? pyImports(e.path, e.text, pyIndex, fileSet) : jsImports(e.path, e.text, fileSet);
    unresolved[e.lang] = (unresolved[e.lang] ?? 0) + u;
    fileEdges.set(e.path, targets);
  }
  const importers = new Map();
  for (const [from, tos] of fileEdges) for (const to of tos) { if (!importers.has(to)) importers.set(to, new Set()); importers.get(to).add(from); }
  const byPath = new Map(entries.map((e) => [e.path, e]));

  // text signals
  const baseCount = new Map();
  for (const e of entries) { const b = path.posix.basename(e.path); baseCount.set(b, (baseCount.get(b) ?? 0) + 1); }
  const tokens = new Map(entries.map((e) => [e.path, mentionTokens(e.text)]));
  for (const e of entries) {
    const keys = [e.path];
    const b = path.posix.basename(e.path);
    if (baseCount.get(b) === 1) keys.push(b);
    let mentions = 0, referenced = false;
    for (const o of entries) {
      if (o === e) continue;
      const t = tokens.get(o.path);
      if (keys.some((k) => t.has(k))) { mentions++; if (o.test) referenced = true; }
    }
    e.mentions = mentions;
    e.test_referenced = referenced;
    const graphedLang = e.lang === 'py' || e.lang === 'js';
    const imp = importers.get(e.path) ?? new Set();
    e.fan_in = graphedLang ? imp.size : null;
    e.test_imported = graphedLang ? [...imp].some((p) => byPath.get(p).test) : null;
  }

  // areas
  const sourceFiles = entries.filter((e) => !e.test);
  let areaDefs; // [{name, globs, derived, match(path)}]
  if (opts.area?.length) {
    areaDefs = opts.area.map((spec) => {
      const m = /^([^=]+)=(.+)$/.exec(spec);
      if (!m) usage(`--area wants <name>=<glob>[,<glob>], got ${spec}`);
      const globs = m[2].split(',').filter(Boolean);
      const res = globs.map(globToRegExp);
      return { name: m[1], globs, derived: 'explicit', match: (p) => res.some((re) => re.test(p)) };
    });
    const names = areaDefs.map((a) => a.name);
    if (new Set(names).size !== names.length) usage('--area names must be unique');
    if (names.includes('(rest)')) usage('--area name (rest) is reserved');
  } else {
    const { dirs, rootArea } = deriveAutoAreas(sourceFiles, R);
    areaDefs = dirs.sort(cmp).map((d) => ({ name: d, globs: [`${d}/**`], derived: 'auto', depth: d.split('/').length, match: (p) => p.startsWith(d + '/') }));
    if (rootArea) {
      const name = '(root)';
      areaDefs.push({ name, globs: [R ? `${R}/*` : '*'], derived: 'auto', depth: 0, match: (p) => path.posix.dirname(p) === (R || '.') });
    }
  }
  const order = opts.area?.length ? areaDefs : [...areaDefs].sort((a, b) => b.depth - a.depth || cmp(a.name, b.name));
  const assign = (p) => order.find((a) => a.match(p))?.name ?? null;
  for (const e of entries) e.area = assign(e.path);
  const entriesOf = (name, test) => entries.filter((e) => e.area === name && e.test === test);
  const kept = new Set(areaDefs.filter((a) => entriesOf(a.name, false).reduce((s, e) => s + e.lines, 0) > 0).map((a) => a.name));
  for (const e of entries) if (!kept.has(e.area)) e.area = '(rest)';
  const areaList = areaDefs.filter((a) => kept.has(a.name));
  if (!opts.area?.length) areaList.sort(by('name'));
  if (entries.some((e) => e.area === '(rest)')) areaList.push({ name: '(rest)', globs: [], derived: opts.area?.length ? 'explicit' : 'auto' });
  const areas = areaList.map((a) => {
    const src = entriesOf(a.name, false), tst = entriesOf(a.name, true);
    return {
      name: a.name, globs: a.globs, derived: a.derived,
      source_files: src.length, source_lines: src.reduce((s, e) => s + e.lines, 0),
      test_files: tst.length, test_lines: tst.reduce((s, e) => s + e.lines, 0),
    };
  });

  // area graph
  const areaEdges = new Map();
  for (const [from, tos] of fileEdges) {
    const a = byPath.get(from).area;
    for (const to of tos) {
      const b = byPath.get(to).area;
      if (a === b) continue;
      const k = `${a}\0${b}`;
      areaEdges.set(k, (areaEdges.get(k) ?? 0) + 1);
    }
  }
  const edges = [...areaEdges].map(([k, count]) => { const [from, to] = k.split('\0'); return { from, to, count }; }).sort(by('from', 'to'));
  const mutual = edges.filter((e) => e.from < e.to && areaEdges.has(`${e.to}\0${e.from}`)).map((e) => [e.from, e.to]);
  const adj = new Map();
  for (const e of edges) { if (!adj.has(e.from)) adj.set(e.from, []); adj.get(e.from).push(e.to); }
  const cycles = tarjan(new Set(edges.flatMap((e) => [e.from, e.to])), adj);
  const languagesGraphed = [...graphed].sort(cmp);
  const sizesOnly = [...new Set(entries.map((e) => e.lang).filter((l) => l !== 'py' && l !== 'js' && l !== 'def'))].sort(cmp);

  const fileArea = new Map(entries.map((e) => [e.path, e.area]));
  const map = compareMap(root, fileArea, fileEdges);

  const historyMatchers = order.filter((a) => kept.has(a.name));
  // A path still in the tree keeps the area files[] records; the matchers only place deleted paths.
  const historyArea = (p) => fileArea.get(p) ?? historyMatchers.find((a) => a.match(p))?.name ?? null;
  let revision = null;
  try { revision = execFileSync('git', ['-C', root, 'rev-parse', '--verify', '-q', 'HEAD'], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }).trim(); } catch { revision = null; }
  const change_cost = await changeCost(root, historyArea, areas.map((a) => a.name), commits, revision);

  const safety_flags = entries.filter((e) => !e.test && e.lang !== 'def' && !e.sibling_test && e.test_imported !== true && !e.test_referenced
    && (e.lines >= SAFETY_LINES || (e.branches ?? 0) >= SAFETY_BRANCHES)).map((e) => e.path).sort(cmp);

  return {
    revision,
    root_scope: R || '.',
    areas,
    files: entries.map((e) => ({
      path: e.path, area: e.area, lang: e.lang, lines: e.lines, branches: e.branches, fan_in: e.fan_in,
      mentions: e.mentions, sibling_test: e.sibling_test, test_imported: e.test_imported,
      test_referenced: e.test_referenced, test: e.test,
    })),
    graph: { edges, mutual, cycles, languages_graphed: languagesGraphed },
    map,
    change_cost,
    safety_flags,
    coverage_limits: {
      sizes_only: sizesOnly,
      unresolved_specifiers: Object.fromEntries(languagesGraphed.map((l) => [l, unresolved[l] ?? 0])),
    },
    files_considered: candidates.length,
    skipped_files: skipped,
  };
}

// ---------------------------------------------------------------- check

// JSON-Schema subset (type, required, properties, additionalProperties, enum, const, anyOf, items,
// minItems, minimum, maximum, minLength), vendored from audit-security's schema.mjs: a `.claude/lib`
// script ships alone to every downstream and must not import another skill's private copy.
export function validate(schema, value, at = '$') {
  const errors = [];
  const fail = (msg) => errors.push(`${at}: ${msg}`);
  if (schema.const !== undefined && value !== schema.const) fail(`must equal ${JSON.stringify(schema.const)}`);
  if (schema.enum && !schema.enum.includes(value)) fail(`must be one of ${schema.enum.join('|')}`);
  if (schema.type) {
    const types = [].concat(schema.type);
    if (!types.some((t) => matchesType(t, value))) { fail(`expected ${types.join('|')}, got ${describe(value)}`); return errors; }
  }
  if (typeof value === 'string' && schema.minLength !== undefined && value.length < schema.minLength) fail(`shorter than ${schema.minLength}`);
  if (typeof value === 'number' && schema.minimum !== undefined && value < schema.minimum) fail(`below minimum ${schema.minimum}`);
  if (typeof value === 'number' && schema.maximum !== undefined && value > schema.maximum) fail(`above maximum ${schema.maximum}`);
  if (Array.isArray(value)) {
    if (schema.minItems !== undefined && value.length < schema.minItems) fail(`fewer than ${schema.minItems} items`);
    if (schema.items) value.forEach((v, i) => errors.push(...validate(schema.items, v, `${at}[${i}]`)));
  }
  if (value && typeof value === 'object' && !Array.isArray(value)) {
    for (const key of schema.required ?? []) if (!(key in value)) fail(`missing required property "${key}"`);
    const props = schema.properties ?? {};
    for (const [k, v] of Object.entries(value)) {
      if (k in props) errors.push(...validate(props[k], v, `${at}.${k}`));
      else if (schema.additionalProperties === false) fail(`unexpected property "${k}"`);
    }
  }
  if (schema.anyOf && !schema.anyOf.some((s) => validate(s, value, at).length === 0)) fail('matches none of anyOf');
  return errors;
}

function matchesType(t, v) {
  switch (t) {
    case 'string': return typeof v === 'string';
    case 'number': return typeof v === 'number' && Number.isFinite(v);
    case 'integer': return Number.isInteger(v);
    case 'boolean': return typeof v === 'boolean';
    case 'null': return v === null;
    case 'array': return Array.isArray(v);
    case 'object': return v !== null && typeof v === 'object' && !Array.isArray(v);
    default: return false;
  }
}
const describe = (v) => (v === null ? 'null' : Array.isArray(v) ? 'array' : typeof v);

function loadSchema(kind) {
  const file = path.join(path.dirname(fileURLToPath(import.meta.url)), `../skills/architecture-review/${kind}-schema.json`);
  try { return JSON.parse(fs.readFileSync(file, 'utf8')); } catch (e) { usage(`cannot load ${kind} schema: ${e.message}`); }
}

export function extractJson(text) {
  const trimmed = text.trim();
  try { return JSON.parse(trimmed); } catch { /* fall through to the fenced block */ }
  const lines = text.split('\n');
  const blocks = [];
  for (let i = 0; i < lines.length; i++) {
    // A bare fence too: both prompts show their output example in one.
    if (!/^\s*```(json)?\s*$/i.test(lines[i])) continue;
    let j = i + 1;
    while (j < lines.length && !/^\s*```\s*$/.test(lines[j])) j++;
    if (j >= lines.length) break;
    blocks.push(lines.slice(i + 1, j).join('\n'));
    i = j;
  }
  if (blocks.length !== 1) invalid('no single JSON object');
  try { return JSON.parse(blocks[0]); } catch (e) { invalid(`fenced json block is not JSON: ${e.message}`); }
}

function validOrFail(kind, value, label) {
  const errors = validate(loadSchema(kind), value);
  if (errors.length) invalid(`${label} invalid:\n${errors.join('\n')}`);
}

function uniqueIds(list, label) {
  const seen = new Set();
  for (const [i, r] of list.entries()) {
    if (typeof r?.id !== 'string' || r.id === '') invalid(`${label}[${i}]: id must be a non-empty string`);
    if (seen.has(r.id)) invalid(`${label}: duplicate id ${r.id}`);
    seen.add(r.id);
  }
  return seen;
}

export function check(kind, file, opts = {}) {
  if (!['auditor', 'refutation', 'records'].includes(kind)) usage(`check wants auditor|refutation|records, got ${kind ?? 'nothing'}`);
  if (!file) usage(`check ${kind} needs a file`);
  if (opts.submitted && kind !== 'refutation') usage('--submitted belongs to check refutation');
  let value;
  let line;
  if (kind === 'records') {
    value = readJson(file);
    validOrFail('records', value, 'records');
    uniqueIds(value.records, 'records');
    line = `valid records records=${value.records.length}`;
  } else {
    value = extractJson(readText(file));
    validOrFail(kind, value, kind);
    if (kind === 'auditor') line = `valid auditor findings=${value.findings.length}`;
    else {
      if (!opts.submitted) usage('check refutation needs --submitted <records.json>');
      const sub = readJson(opts.submitted);
      const list = Array.isArray(sub) ? sub : sub?.records;
      if (!Array.isArray(list)) invalid(`${opts.submitted}: expected a list of records or {records: [...]}`);
      const submitted = uniqueIds(list, 'submitted');
      const got = new Set();
      for (const r of value.results) {
        if (!submitted.has(r.id)) invalid(`refutation: result id ${r.id} was not submitted`);
        if (got.has(r.id)) invalid(`refutation: duplicate id ${r.id}`);
        got.add(r.id);
      }
      const missing = [...submitted].filter((id) => !got.has(id)).sort(cmp);
      for (const id of missing) value.results.push({ id, verdict: 'not-checked', target: 'claim', correction: '', evidence: 'no result returned', evidence_kind: 'static', command: null });
      value.results.sort(by('id'));
      line = `valid refutation results=${value.results.length} missing=${missing.length}`;
    }
  }
  if (opts.out) fs.writeFileSync(opts.out, dump(value));
  return line;
}

// ---------------------------------------------------------------- score

const roundHalf = (x) => Math.round(x * 2) / 2;

export function score({ records, measure: m, assessed }) {
  validOrFail('records', records, 'records');
  uniqueIds(records.records, 'records');
  if (!Array.isArray(m?.areas) || !Array.isArray(m?.files) || !Array.isArray(m?.safety_flags)) invalid('measure: expected areas[], files[], safety_flags[]');
  const areaNames = m.areas.map((a) => a.name);
  const known = new Set(areaNames);
  if (!assessed || typeof assessed.areas !== 'object' || assessed.areas === null || Array.isArray(assessed.areas)) invalid('assessed: expected {areas: {<area>: {<axis>: {...}}}}');
  for (const [area, axes] of Object.entries(assessed.areas)) {
    if (!known.has(area)) invalid(`assessed: unknown area ${area}`);
    for (const [axis, v] of Object.entries(axes ?? {})) {
      if (!AXES.includes(axis)) invalid(`assessed: unknown axis ${axis} in area ${area}`);
      const ok = v && (v.assessed === true || (v.assessed === false && typeof v.reason === 'string' && v.reason !== ''));
      if (!ok) invalid(`assessed: ${area}.${axis} must be {assessed: true} or {assessed: false, reason: "<text>"}`);
    }
  }
  for (const r of records.records) for (const a of r.areas) if (!known.has(a)) invalid(`records: ${r.id} names unknown area ${a}`);
  const counting = records.records.filter((r) => r.status === 'finding' && r.tier !== 'none');
  const flagged = new Set();
  const fileArea = new Map(m.files.map((f) => [f.path, f.area]));
  for (const p of m.safety_flags) if (fileArea.has(p)) flagged.add(fileArea.get(p));

  let total = 0, scoredLines = 0, weighted = 0;
  const unassessedEverywhere = new Set(AXES);
  const areas = m.areas.map((a) => {
    const axes = {};
    let sum = 0, count = 0;
    for (const axis of AXES) {
      const entry = assessed.areas[a.name]?.[axis];
      if (!entry || entry.assessed !== true) {
        axes[axis] = { value: null, reason: entry ? entry.reason : 'missing from assessed file' };
        continue;
      }
      unassessedEverywhere.delete(axis);
      const hits = counting.filter((r) => r.areas.includes(a.name) && CLASS_AXIS[r.class] === axis);
      const now = hits.filter((r) => r.tier === 'now');
      let value;
      if ((axis === 'boundaries' && now.some((r) => r.breach)) || now.length >= 2) value = 0;
      else if (now.length === 1) value = 1;
      else if (hits.some((r) => r.tier === 'next')) value = 2;
      else value = 3;
      if (axis === 'safety_net' && flagged.has(a.name)) value = Math.min(value, 2);
      axes[axis] = { value };
      sum += value; count++;
    }
    const areaScore = count >= 2 ? roundHalf((sum / 12) * 10) : null;
    total += a.source_lines;
    if (areaScore !== null) { scoredLines += a.source_lines; weighted += areaScore * a.source_lines; }
    return { name: a.name, source_lines: a.source_lines, axes, assessed_axes: count, score: areaScore };
  });
  const scoredShare = total > 0 ? Math.round((scoredLines / total) * 100) / 100 : null;
  const reasons = [];
  if (total === 0) reasons.push('no source lines in scope');
  else if (2 * scoredLines < total) reasons.push(`scored areas cover ${scoredShare} of the lines`);
  for (const axis of unassessedEverywhere) reasons.push(`axis ${axis} not assessed in any area`);
  return {
    areas,
    overall: total > 0 ? roundHalf(weighted / total) : null,
    scored_share: scoredShare,
    inconclusive: reasons.length > 0,
    inconclusive_reasons: reasons.sort(cmp),
  };
}

// ---------------------------------------------------------------- CLI

async function main(argv) {
  const [cmd, ...rest] = argv;
  if (cmd === 'measure') {
    const a = parseArgs(rest, { root: 'one', focus: 'one', area: 'many', exclude: 'many', commits: 'one', out: 'one' });
    if (a._.length) usage(`unexpected argument ${a._[0]}`);
    if (!a.root || !a.out) usage('measure needs --root <dir> and --out <file>');
    const res = await measure(a);
    fs.writeFileSync(a.out, dump(res));
    const map = res.map.skipped ? `skipped:${res.map.skipped}` : 'compared';
    const graph = res.graph.languages_graphed.length ? res.graph.languages_graphed.join(',') : 'none';
    return `areas=${res.areas.length} files=${res.files.length} graph=${graph} map=${map}`;
  }
  if (cmd === 'check') {
    const a = parseArgs(rest, { out: 'one', submitted: 'one' });
    if (a._.length > 2) usage(`unexpected argument ${a._[2]}`);
    return check(a._[0], a._[1], a);
  }
  if (cmd === 'score') {
    const a = parseArgs(rest, { records: 'one', measure: 'one', assessed: 'one', out: 'one' });
    if (a._.length) usage(`unexpected argument ${a._[0]}`);
    if (!a.records || !a.measure || !a.assessed || !a.out) usage('score needs --records --measure --assessed --out');
    const res = score({ records: readJson(a.records), measure: readJson(a.measure), assessed: readJson(a.assessed) });
    fs.writeFileSync(a.out, dump(res));
    return `areas=${res.areas.length} overall=${res.overall ?? 'none'} inconclusive=${res.inconclusive}`;
  }
  usage('usage: arch-assess.mjs <measure|check|score> …');
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main(process.argv.slice(2)).then((line) => { console.log(line); }, (err) => {
    console.error(`arch-assess: ${err.message}`);
    process.exitCode = err instanceof Fail ? err.code : 2;
  });
}
