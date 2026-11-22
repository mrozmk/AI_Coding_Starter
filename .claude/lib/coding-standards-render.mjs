// Verifying renderer of docs/coding-standards.md: takes the config/CI scan (standards-tools.mjs) and,
// unless --tools-only, the checked standards draft of the map-codebase workflow; re-checks every cited
// `path:line` on disk (inside the repo, a regular file, the line exists; byte-equal at the destination
// when it differs from the analyzed checkout), drops what fails, and writes the seed's shape. Section
// names come from the seed only — this file names none. Never overwrites an existing standards file:
// a reconstructed copy is written beside it instead. Node builtins only.
//
//   node .claude/lib/coding-standards-render.mjs render --scan <f> --repo <dir> [--draft <f>]
//     [--out-root <dir>] [--seed <f>] [--tools-only] [--date YYYY-MM-DD] [--by <command>]
//     [--files-from <list> --modules <modules.json>]   (search the consumers of the draft's helperCandidates)
//   stdout: summary JSON (`path: null` + `notWritten` when nothing survived — no file is written)
//   exit 2 = usage or refusal (one `coding-standards-render: <reason>` line)

import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const SEED_REL = '.agents/reference/coding-standards.md.example';

export function parseRef(ref) {
  if (typeof ref !== 'string') return null;
  const i = ref.lastIndexOf(':');
  if (i <= 0) return null;
  const p = ref.slice(0, i);
  const n = /^(\d+)(?:-(\d+))?$/.exec(ref.slice(i + 1));
  if (!n || path.isAbsolute(p) || p.split(/[\\/]/).includes('..')) return null;
  const from = Number(n[1]);
  const to = n[2] ? Number(n[2]) : from;
  return from >= 1 && to >= from ? { path: p, from, to } : null;
}

const inside = (realRoot, real) => real === realRoot || real.startsWith(realRoot + path.sep);
const lexists = (p) => { try { fs.lstatSync(p); return true; } catch { return false; } };
const one = (s) => String(s ?? '').replace(/\s*\r?\n\s*/g, ' ').trim();
const cell = (s) => one(s).replace(/\|/g, '\\|');
const tick = (s) => `\`${one(s).replace(/`/g, '')}\``;
const fileOf = (ref) => ref.slice(0, ref.lastIndexOf(':'));

// Replace `file` through an exclusive temp: a pre-planted temp (or a symlink there) fails with EEXIST.
export function writeReplace(file, text, { suffix } = {}) {
  const tmp = `${file}.tmp.${suffix || crypto.randomBytes(6).toString('hex')}`;
  const fd = fs.openSync(tmp, 'wx');
  try {
    fs.writeSync(fd, text);
    fs.closeSync(fd);
    fs.renameSync(tmp, file);
  } catch (e) {
    try { fs.unlinkSync(tmp); } catch { /* already gone */ }
    throw e;
  }
}

function readSeed(seed) {
  let text;
  try { text = fs.readFileSync(seed, 'utf8'); } catch { throw new Error(`seed missing: ${seed}`); }
  const lines = text.split(/\r?\n/);
  const title = lines.find((l) => l.startsWith('# '));
  const header = lines.filter((l) => l.startsWith('> ') && !l.startsWith('> Optional seed.'));
  const heads = lines.map((l, i) => [l, i]).filter(([l]) => l.startsWith('## '));
  if (!title || heads.length !== 4) throw new Error(`seed ${seed}: expected a title and four sections, found ${heads.length}`);
  const tableOf = (k) => lines.slice(heads[k][1], heads[k + 1] ? heads[k + 1][1] : lines.length).filter((l) => l.startsWith('|')).slice(0, 2);
  return { title, header, sections: heads.map(([l]) => l), tables: [null, tableOf(1), tableOf(2), null] };
}

function evidence(repo, outRoot) {
  const realRepo = fs.realpathSync(repo);
  const realOut = fs.realpathSync(outRoot);
  const redirect = realRepo !== realOut;
  const cache = new Map();
  const fileCheck = (rel) => {
    if (cache.has(rel)) return cache.get(rel);
    let res = { reason: null, lines: 0 };
    try {
      const real = fs.realpathSync(path.join(repo, rel));
      if (!inside(realRepo, real)) res = { reason: 'outside the repository' };
      else if (!fs.statSync(real).isFile()) res = { reason: 'not a file' };
      else {
        const bytes = fs.readFileSync(real);
        const text = bytes.toString('utf8');
        res.lines = text.split('\n').length - (text.endsWith('\n') ? 1 : 0);
        if (redirect) {
          let same = false;
          try {
            const dest = fs.realpathSync(path.join(outRoot, rel));
            same = inside(realOut, dest) && fs.statSync(dest).isFile() && fs.readFileSync(dest).equals(bytes);
          } catch { same = false; }
          if (!same) res = { reason: 'differs in destination' };
        }
      }
    } catch { res = { reason: 'missing' }; }
    cache.set(rel, res);
    return res;
  };
  return (ref) => {
    const r = parseRef(ref);
    if (!r) return 'invalid ref';
    const f = fileCheck(r.path);
    if (f.reason) return f.reason;
    return r.to > f.lines ? 'line past end' : null;
  };
}

function toolRules(scan, ok, dropped) {
  const out = [];
  for (const t of scan.tools.filter((x) => x.enforced)) {
    const cfgs = (t.configs || []).filter((c) => c.attributed);
    const title = t.class === 'compiler' ? `Code builds under ${t.display} with the project settings`
      : `Code passes ${t.display}${cfgs.length || t.selected ? ' with the project config' : ''}`;
    let by;
    let example;
    if (t.selected) {
      const run = (t.runs || []).find((r) => r.selected === t.selected && !r.scopeUnknown);
      if (!run) continue;
      by = `tool (${fileOf(run.at)}: ${t.selected})`;
      example = run.at;
    } else if (!cfgs.length && (t.ciChecks || []).length) {
      by = `tool (${fileOf(t.ciChecks[0].at)}: ${t.ciChecks[0].command})`;
      example = t.ciChecks[0].at;
    } else if (cfgs.length) {
      const c = cfgs[0];
      const items = c.rules.filter((r) => !(c.notEnforced || []).includes(r.rule));
      const desc = c.presets.length ? c.presets.map((p) => p.name).join(', ')
        : items.length ? items.slice(0, 3).map((r) => r.rule).join(', ') + (items.length > 3 ? `, +${items.length - 3} more` : '') : 'whole config';
      const more = cfgs.length - 1;
      by = `tool (${c.path}: ${desc}${more ? `; +${more} more config${more > 1 ? 's' : ''}` : ''})`;
      example = items[0] ? `${c.path}:${items[0].line}` : c.presets[0] ? `${c.path}:${c.presets[0].line}` : `${c.path}:1`;
    } else continue;
    const support = [...cfgs.map((c) => `${c.path}:1`), ...(t.wiredBy || []), ...(t.ciChecks || []).map((x) => x.at)];
    const bad = [example, ...support].map(ok).find(Boolean);
    if (bad) { dropped.push({ section: 'rules', item: title, reason: bad, documentedIds: [] }); continue; }
    const except = (t.appliesExcept || []).length ? ` (except ${t.appliesExcept.map(tick).join(', ')})` : '';
    out.push({ title, by, applies: t.appliesTo.map(tick).join(', ') + except, example, why: `${t.display} fails the check when this is broken, so reviewers do not re-check it.`, documentedIds: [] });
  }
  return out;
}

// One sentence: no sentence end followed by a capital outside code spans and common abbreviations.
export const sentences = (s) => String(s ?? '').replace(/`[^`]*`/g, 'x').replace(/\b(e\.g|i\.e|etc|vs|cf)\./gi, 'x')
  .split(/[.!?]["')\]]?\s+(?=[A-Z(])/).filter((x) => x.trim()).length;

// The directories a module owns: its `roots`, else its name when every file lies under it, else the
// common directory of its files grouped by their first three path segments.
export function moduleRoots(m) {
  if (Array.isArray(m.roots) && m.roots.length) return m.roots.map((r) => String(r).replace(/\/+$/, '')).filter(Boolean);
  const files = (m.files || []).filter((f) => typeof f === 'string' && f.includes('/'));
  if (m.name && files.length && files.every((f) => f.startsWith(`${m.name}/`))) return [m.name];
  const groups = new Map();
  for (const f of files) {
    const d = path.posix.dirname(f).split('/');
    const k = d.slice(0, 3).join('/');
    if (!groups.has(k)) groups.set(k, []);
    groups.get(k).push(d);
  }
  return [...groups.values()].map((ds) => {
    let n = ds[0].length;
    for (const d of ds) { let i = 0; while (i < n && i < d.length && d[i] === ds[0][i]) i++; n = i; }
    return ds[0].slice(0, n).join('/');
  }).filter(Boolean);
}

const TEST_FILE = /(^|\/)(__tests__|__mocks__|e2e|tests?|fixtures?|testing)\/|[._-](spec|test|fake|mock|stub)s?\.[^/]+$|_test\.[^/]+$/;
// A consumer is written in the definition's language: same extension family (else the same extension).
const FAMILIES = [['ts', 'tsx', 'mts', 'cts', 'js', 'jsx', 'mjs', 'cjs', 'vue', 'svelte'], ['py', 'pyi'], ['c', 'h', 'cc', 'cpp', 'hpp'], ['kt', 'kts', 'java'], ['cs'], ['go'], ['rs'], ['rb'], ['php']];
const extOf = (f) => (/\.([^./]+)$/.exec(f) || [, ''])[1].toLowerCase();
const familyOf = (f) => FAMILIES.find((g) => g.includes(extOf(f))) || [extOf(f)];
const esc = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
const symbolOf = (s) => (/[A-Za-z_$][\w$]*/.exec(String(s ?? '').replace(/`/g, '').replace(/^\s*(new|await|throw|return)\s+/, '')) || [''])[0];

// Consumers of each helper candidate across the whole file list: per other module — one that imports the
// defining module when the partition carries `importedBy` — the first line (files in list order, the
// definition's language) that names the symbol and is no comment, re-export, bare list entry or
// definition; a module that defines the same name is no consumer. Every found ref is re-checked by `ok`
// before a row is written.
export function findConsumers({ repo, files, modules, candidates }) {
  const importers = new Map(modules.filter((m) => Array.isArray(m.importedBy)).map((m) => [m.name, new Set(m.importedBy)]));
  const realRepo = fs.realpathSync(repo);
  const roots = modules.flatMap((m) => moduleRoots(m).map((r) => ({ root: r, module: m.name }))).sort((a, b) => b.root.length - a.root.length);
  const ownerOf = (f) => (roots.find((r) => f.startsWith(`${r.root}/`)) || {}).module;
  const cache = new Map();
  const linesOf = (rel) => {
    if (cache.has(rel)) return cache.get(rel);
    let lines = null;
    try {
      const real = fs.realpathSync(path.join(repo, rel));
      const st = fs.statSync(real);
      if (inside(realRepo, real) && st.isFile() && st.size <= 1 << 20) lines = fs.readFileSync(real, 'utf8').split(/\r?\n/);
    } catch { lines = null; }
    cache.set(rel, lines);
    return lines;
  };
  const pool = files.filter((f) => !TEST_FILE.test(f)).map((f) => ({ f, module: ownerOf(f) })).filter((x) => x.module);
  const wordOf = (s) => new RegExp(`(?<![\\w$])${esc(s)}(?![\\w$])`);
  return candidates.map((c) => {
    const base = { module: c.module, need: c.need, symbol: c.symbol, at: c.at, consumers: [] };
    const def = parseRef(c.at);
    // `symbol` may name alternatives (`ApiError.from / apiErrorFromStatus`): the one the definition line names.
    const names = String(c.symbol ?? '').split(/\s*(?:\/|,|\bor\b)\s*/).map(symbolOf).filter(Boolean);
    if (!names.length || !def) return { ...base, result: 'no symbol or definition ref' };
    const defLine = (linesOf(def.path) || [])[def.from - 1];
    const definesOf = (n) => new RegExp(`\\b(function|class|def|const|let|var|fn|func|type|interface|enum|struct)\\s+${esc(n)}(?![\\w$])`);
    const sym = defLine === undefined ? null : names.find((n) => definesOf(n).test(defLine)) || names.find((n) => wordOf(n).test(defLine));
    if (!sym) return { ...base, result: 'definition line does not name the symbol' };
    const word = wordOf(sym);
    const defines = definesOf(sym);
    const bare = new RegExp(`^\\s*(type\\s+)?${esc(sym)}\\s*(as\\s+[\\w$]+\\s*)?,?\\s*$`);
    const family = familyOf(def.path);
    const allowed = importers.get(c.module);
    const found = new Map();
    const definers = new Set();
    for (const { f, module } of pool) {
      if (module === c.module || definers.has(module) || (allowed && !allowed.has(module)) || !family.includes(extOf(f))) continue;
      const lines = linesOf(f);
      if (!lines || !lines.some((l) => l.includes(sym))) continue;
      for (let i = 0; i < lines.length; i++) {
        const l = lines[i];
        if (!word.test(l) || /^\s*(\/\/|\/\*|\*|#)/.test(l) || /^\s*export\s*(\*|\{)/.test(l) || bare.test(l)) continue;
        if (defines.test(l)) { definers.add(module); found.delete(module); break; }
        if (!found.has(module)) found.set(module, `${f}:${i + 1}`);
        break;
      }
    }
    const consumers = [...found].filter(([m]) => !definers.has(m)).map(([module, ref]) => ({ module, ref }));
    return { ...base, name: sym, consumers, result: consumers.length >= 2 ? 'row' : 'fewer than two consumer modules' };
  });
}

// Surviving support: refs that pass the check, other than `exclude` (a helper's own definition).
function supportModules(item, ok, exclude) {
  return new Set((item.support || []).filter((s) => s && s.ref !== exclude && !ok(s.ref)).map((s) => s.module)).size;
}

export function render({ draft, scan, repo, outRoot = repo, seed, toolsOnly = false, date, by, files = null, modules = null }) {
  if (!scan || !Array.isArray(scan.tools)) throw new Error('invalid scan: no tools array');
  if (!toolsOnly && !(draft && ['rules', 'helpers', 'shapes', 'open'].every((k) => Array.isArray(draft[k])))) throw new Error('invalid draft: rules, helpers, shapes and open must be arrays');
  const s = readSeed(seed || path.join(outRoot, SEED_REL));
  const ok = evidence(repo, outRoot);
  const dropped = [];
  const drop = (section, item, name, reason) => dropped.push({ section, item: one(name), reason, documentedIds: item.documentedIds || [] });
  // An item survives when its own ref resolves and its support spans two modules (`exclude`: a helper's definition).
  const survives = (section, item, ref, name, exclude) => {
    const bad = ok(ref);
    if (bad) drop(section, item, name, bad);
    else if (supportModules(item, ok, exclude) < 2) drop(section, item, name, 'support below two modules');
    else return true;
    return false;
  };

  const rules = toolRules(scan, ok, dropped);
  const toolCount = rules.length;
  const helpers = [];
  const shapes = [];
  const open = [];
  const helperSearch = [];
  if (!toolsOnly) {
    for (const r of draft.rules) {
      if (sentences(r.rule) > 1) { drop('rules', r, r.rule, 'heading is more than one sentence'); continue; }
      if (!survives('rules', r, r.example, r.rule)) continue;
      const parts = one(r.appliesTo).split(/\s*,\s*(?![^{]*\})/);
      const applies = parts.every((p) => /^[\w./*{}@-]+$/.test(p) && /[/*.]/.test(p)) ? parts.map(tick).join(', ') : one(r.appliesTo);
      rules.push({ title: one(r.rule), by: 'review', applies, example: r.example, why: one(r.why), documentedIds: r.documentedIds || [] });
    }
    const row = (h) => `| ${cell(h.need)} | ${cell(tick(h.use))} | ${tick(h.path)} |`;
    for (const h of draft.helpers) {
      if (survives('helpers', h, h.path, h.need, h.path)) helpers.push(row(h));
    }
    const candidates = (Array.isArray(draft.helperCandidates) ? draft.helperCandidates : []).filter((c) => c && !draft.helpers.some((h) => h.path === c.at));
    if (candidates.length && files && modules) {
      for (const c of findConsumers({ repo, files, modules, candidates })) {
        if ((c.consumers || []).length >= 2) {
          const h = { need: c.need, use: c.symbol, path: c.at, support: [{ module: c.module, ref: c.at }, ...c.consumers] };
          if (survives('helpers', h, h.path, h.need, h.path)) helpers.push(row(h));
          else c.result = 'dropped';
        }
        helperSearch.push(c);
      }
    } else helperSearch.push(...candidates.map((c) => ({ ...c, consumers: [], result: 'not searched (no --files-from/--modules)' })));
    for (const x of draft.shapes) {
      if (survives('shapes', x, x.reference, x.problem)) shapes.push(`| ${cell(x.problem)} | ${cell(x.shape)} | ${tick(x.reference)} |`);
    }
    for (const o of draft.open) {
      const vs = (o.variants || []).filter((v) => !ok(v.evidence));
      if (vs.length < 2) { drop('open', o, o.topic, 'fewer than two resolving variants'); continue; }
      open.push({ topic: one(o.topic), line: `- ${one(o.topic)} — ${vs.map((v) => `${one(v.shape)} (${tick(v.evidence)})`).join('; ')}; a person picks one, then it becomes a rule.` });
    }
  }

  const body = [s.title, '', ...s.header, `> Generated by ${one(by || 'coding-standards-render')} on ${one(date)} from the code — verify every entry before relying on it.`, '', s.sections[0], ''];
  rules.forEach((r, i) => body.push(`### CS-${i + 1} — ${r.title}`, `- Enforced by: ${r.by}`, `- Applies to: ${r.applies}`, `- Example: ${tick(r.example)}`, `- Why: ${r.why}`, ''));
  body.push(s.sections[1], '', ...s.tables[1], ...helpers, '', s.sections[2], '', ...s.tables[2], ...shapes, '', s.sections[3], '');
  if (open.length) body.push(...open.map((o) => o.line), '');
  const text = `${body.join('\n').replace(/\n+$/, '')}\n`;

  // Nothing survived: an empty canonical file would make every later run write only the reconstructed copy.
  const empty = !rules.length && !helpers.length && !shapes.length && !open.length;
  const target = empty ? { path: null, reconstructed: false } : writeOut(outRoot, text);
  const lines = text.split('\n').length - 1;
  return {
    path: target.path,
    text,
    summary: {
      path: target.path, reconstructed: target.reconstructed, ...(empty ? { notWritten: 'nothing survived' } : {}),
      rules: { tool: toolCount, review: rules.length - toolCount }, helpers: helpers.length, shapes: shapes.length,
      open: open.map((o) => o.topic), dropped, helperSearch,
      renderedDocumentedIds: [...new Set(rules.flatMap((r) => r.documentedIds))], lines, overSoftLimit: lines > 200,
    },
  };
}

function writeOut(outRoot, text) {
  const realOut = fs.realpathSync(outRoot);
  const docs = path.join(outRoot, 'docs');
  let anc = docs;
  while (!lexists(anc)) anc = path.dirname(anc);
  if (!inside(realOut, fs.realpathSync(anc))) throw new Error(`unsafe output: ${anc} resolves outside ${outRoot}`);
  if (lexists(docs) && (fs.lstatSync(docs).isSymbolicLink() || !fs.statSync(docs).isDirectory())) throw new Error(`unsafe output: ${docs} is a symlink or not a directory`);
  const canonical = path.join(docs, 'coding-standards.md');
  if (!lexists(canonical)) {
    if (!lexists(docs)) fs.mkdirSync(docs);
    fs.writeFileSync(canonical, text, { flag: 'wx' });
    return { path: canonical, reconstructed: false };
  }
  const rec = path.join(docs, 'coding-standards.reconstructed.md');
  if (lexists(rec) && fs.lstatSync(rec).isSymbolicLink()) throw new Error(`unsafe output: ${rec} is a symlink`);
  writeReplace(rec, text);
  return { path: rec, reconstructed: true };
}

function main(argv) {
  if (argv[0] !== 'render') throw new Error('usage: render --scan <f> --repo <dir> [--draft <f>] [--out-root <dir>] [--seed <f>] [--tools-only] [--date YYYY-MM-DD] [--by <command>] [--files-from <list> --modules <f>]');
  const opt = { 'tools-only': false };
  for (let i = 1; i < argv.length; i++) {
    const k = argv[i];
    if (k === '--tools-only') { opt['tools-only'] = true; continue; }
    if (!['--scan', '--repo', '--draft', '--out-root', '--seed', '--date', '--by', '--files-from', '--modules'].includes(k) || argv[i + 1] === undefined) throw new Error(`unknown or incomplete option ${k}`);
    opt[k.slice(2)] = argv[++i];
  }
  if (!opt.scan || !opt.repo) throw new Error('--scan and --repo are required');
  if (!opt.draft && !opt['tools-only']) throw new Error('--draft is required unless --tools-only');
  if (!opt['files-from'] !== !opt.modules) throw new Error('--files-from and --modules go together');
  const readText = (f) => { try { return fs.readFileSync(f, 'utf8'); } catch (e) { throw new Error(`cannot read ${f}: ${e.message}`); } };
  const readJson = (f) => { try { return JSON.parse(readText(f)); } catch (e) { throw new Error(e.message.startsWith('cannot read') ? e.message : `cannot read ${f}: ${e.message}`); } };
  const modules = opt.modules ? readJson(opt.modules) : null;
  if (modules && !Array.isArray(modules)) throw new Error(`${opt.modules}: expected an array of modules`);
  const { summary } = render({
    scan: readJson(opt.scan), draft: opt.draft ? readJson(opt.draft) : null, repo: opt.repo, outRoot: opt['out-root'] || opt.repo,
    seed: opt.seed, toolsOnly: opt['tools-only'], date: opt.date || new Date().toISOString().slice(0, 10), by: opt.by,
    files: opt['files-from'] ? readText(opt['files-from']).split(/\0|\r?\n/).filter(Boolean) : null, modules,
  });
  process.stdout.write(`${JSON.stringify(summary, null, 2)}\n`);
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try { main(process.argv.slice(2)); } catch (e) { process.stderr.write(`coding-standards-render: ${e.message}\n`); process.exit(2); }
}
