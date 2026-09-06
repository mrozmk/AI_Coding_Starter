#!/usr/bin/env node
// Backlog write-back (T06). Opt-in: only when `.agents/backlog.md` exists and exactly one work package
// owns the spec. Writes Status (TODO → WIP) and Ref (spec, later plan) cells of the matched package
// and its tasks; never creates a backlog, never restructures the DAG, never writes on ambiguity.
//
//   node scripts/backlog.mjs match     --project-root <dir> --spec <rel spec>
//   node scripts/backlog.mjs writeback --project-root <dir> --spec <rel spec> [--ref <plan rel>] --consent yes
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { parseArgv, requireOpt } from './lib/argv.mjs';
import { realpathOrSelf, toPosix } from './lib/fsx.mjs';

export const BACKLOG = '.agents/backlog.md';

function cells(line) {
  return line.trim().replace(/^\|/, '').replace(/\|$/, '').split('|').map((c) => c.trim());
}

function isRow(line) {
  return /^\s*\|/.test(line) && !/^\s*\|[\s:-]+\|/.test(line);
}

// Two tables: work packages (Package | Task scope | Depends on | Entry | Status) and tasks
// (ID | … | Status | Ref). Column positions come from each header row, not from fixed offsets.
export function parseBacklog(text) {
  const lines = text.split('\n');
  const packages = [];
  const tasks = [];
  let header = null;
  let kind = null;
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    if (!isRow(line)) { if (!line.trim().startsWith('|')) { header = null; kind = null; } continue; }
    const c = cells(line);
    if (!header) {
      header = c.map((h) => h.toLowerCase());
      kind = header.includes('package') ? 'package' : header.includes('id') && header.includes('ref') ? 'task' : null;
      continue;
    }
    if (!kind) continue;
    const col = (name) => c[header.findIndex((h) => h.startsWith(name))] ?? '';
    if (kind === 'package') {
      packages.push({ name: col('package').replace(/\*\*/g, '').trim(), scope: col('task scope').split(/[,\s]+/).filter((s) => /^[A-Z]+\d*-\d+$/.test(s)), entry: col('entry'), status: col('status'), line: i });
    } else {
      tasks.push({ id: col('id'), task: col('task'), status: col('status'), ref: col('ref'), line: i, statusIndex: header.findIndex((h) => h === 'status'), refIndex: header.findIndex((h) => h === 'ref') });
    }
  }
  return { packages, tasks, lines };
}

function topicOf(specRel) {
  return path.posix.basename(toPosix(specRel)).replace(/\.md$/, '').replace(/^\d{4}-\d{2}-\d{2}-/, '').toLowerCase();
}

// Ownership: a package already carrying the spec in Entry/Ref wins; otherwise a package whose
// name or task titles match the spec topic. More than one candidate is ambiguous — no write.
export function matchWorkPackage(backlog, { spec }) {
  const specRel = toPosix(spec);
  const topic = topicOf(specRel);
  const byRef = backlog.packages.filter((p) => p.entry.includes(specRel) || backlog.tasks.some((t) => p.scope.includes(t.id) && t.ref.includes(specRel)));
  if (byRef.length === 1) return { status: 'matched', package: byRef[0], reason: 'package already references this spec' };
  if (byRef.length > 1) return { status: 'ambiguous', candidates: byRef.map((p) => p.name), reason: 'more than one package references this spec' };
  const words = topic.split('-').filter((w) => w.length > 2);
  const score = (p) => {
    const name = p.name.toLowerCase();
    const titles = backlog.tasks.filter((t) => p.scope.includes(t.id)).map((t) => t.task.toLowerCase()).join(' ');
    if (name.replace(/[^a-z0-9]/g, '') === topic.replace(/[^a-z0-9]/g, '')) return 100;
    return words.filter((w) => name.includes(w) || titles.includes(w)).length;
  };
  const scored = backlog.packages.map((p) => ({ p, s: score(p) })).filter((x) => x.s > 0).sort((a, b) => b.s - a.s);
  if (scored.length === 0) return { status: 'none', reason: `no work package matches topic "${topic}"` };
  if (scored.length > 1 && scored[0].s === scored[1].s) return { status: 'ambiguous', candidates: scored.filter((x) => x.s === scored[0].s).map((x) => x.p.name), reason: 'several packages match the topic equally' };
  if (scored.length > 1 && scored[0].s < 100 && scored[1].s > 0) return { status: 'ambiguous', candidates: scored.slice(0, 2).map((x) => x.p.name), reason: 'partial match with competing candidates — the user names the package' };
  return { status: 'matched', package: scored[0].p, reason: `topic "${topic}" matches package ${scored[0].p.name}` };
}

function setCell(line, index, value) {
  const c = cells(line);
  c[index] = value;
  return `| ${c.join(' | ')} |`;
}

// Status TODO → WIP on the package and its TODO tasks; Ref gains the path once. Other rows untouched.
export function writeBackText(text, { pkg, refs = [] }) {
  const backlog = parseBacklog(text);
  const lines = [...backlog.lines];
  const changed = [];
  const p = backlog.packages.find((x) => x.name === pkg.name);
  if (!p) throw new Error(`package ${pkg.name} not found`);
  const pkgCells = cells(lines[p.line]);
  const pkgHeader = cells(lines.slice(0, p.line).reverse().find((l) => isRow(l) && cells(l).some((h) => /package/i.test(h)))).map((h) => h.toLowerCase());
  const pkgStatusIdx = pkgHeader.findIndex((h) => h === 'status');
  if (pkgStatusIdx !== -1 && /^TODO$/i.test(pkgCells[pkgStatusIdx])) { lines[p.line] = setCell(lines[p.line], pkgStatusIdx, 'WIP'); changed.push(`${p.name}: Status TODO → WIP`); }
  for (const t of backlog.tasks) {
    if (!p.scope.includes(t.id)) continue;
    let line = lines[t.line];
    if (/^TODO$/i.test(t.status)) { line = setCell(line, t.statusIndex, 'WIP'); changed.push(`${t.id}: Status TODO → WIP`); }
    const current = t.ref === '—' || t.ref === '-' ? [] : t.ref.split(/\s*[,·]\s*/).map((s) => s.trim()).filter(Boolean);
    const add = refs.map((r) => `\`${toPosix(r)}\``).filter((r) => !current.includes(r));
    if (add.length) { line = setCell(line, t.refIndex, [...current, ...add].join(', ')); changed.push(`${t.id}: Ref + ${add.join(', ')}`); }
    lines[t.line] = line;
  }
  return { text: lines.join('\n'), changed };
}

// Stale-status signals the planner should surface rather than silently overwrite.
export function staleSignals(projectRoot, backlog) {
  const root = path.resolve(projectRoot);
  const out = [];
  for (const t of backlog.tasks) {
    for (const m of t.ref.matchAll(/`?(\.agents\/plans\/(active|done)\/[^`\s,]+)`?/g)) {
      const rel = m[1];
      const exists = fs.existsSync(path.join(root, rel));
      const done = fs.existsSync(path.join(root, rel.replace('/active/', '/done/')));
      if (/^TODO$/i.test(t.status) && (exists || done)) out.push(`${t.id} is TODO but already has a plan (${rel})`);
      if (/^WIP$/i.test(t.status) && !exists && !done) out.push(`${t.id} is WIP but its plan ${rel} is gone`);
      if (/^WIP$/i.test(t.status) && rel.includes('/active/') && !exists && done) out.push(`${t.id} is WIP but its plan moved to done/ — mark DONE?`);
    }
  }
  return out;
}

export function competingPlans(projectRoot, spec) {
  const dir = path.join(path.resolve(projectRoot), '.agents/plans/active');
  if (!fs.existsSync(dir)) return [];
  const specRel = toPosix(spec);
  return fs.readdirSync(dir).filter((f) => f.endsWith('.md')).filter((f) => fs.readFileSync(path.join(dir, f), 'utf8').includes(specRel)).map((f) => `.agents/plans/active/${f}`);
}

export function backlogWriteBack({ projectRoot, spec, refs = [], consent = false }) {
  const root = path.resolve(projectRoot);
  const file = path.join(root, BACKLOG);
  if (!fs.existsSync(file)) return { status: 'no-backlog', written: false, changed: [], note: 'no .agents/backlog.md — nothing to update (never created here)' };
  const text = fs.readFileSync(file, 'utf8');
  const backlog = parseBacklog(text);
  const match = matchWorkPackage(backlog, { spec });
  const stale = staleSignals(root, backlog);
  const competing = competingPlans(root, spec);
  if (match.status !== 'matched') return { status: match.status, written: false, changed: [], candidates: match.candidates ?? [], reason: match.reason, stale, competing };
  const res = writeBackText(text, { pkg: match.package, refs: [toPosix(spec), ...refs] });
  if (consent && res.changed.length) fs.writeFileSync(file, res.text);
  return { status: 'matched', package: match.package.name, written: consent && res.changed.length > 0, changed: res.changed, stale, competing };
}

function main() {
  const { opts, positionals } = parseArgv(process.argv.slice(2));
  const cmd = positionals[0];
  const projectRoot = requireOpt(opts, 'project-root');
  const spec = requireOpt(opts, 'spec');
  if (cmd === 'match') {
    const res = backlogWriteBack({ projectRoot, spec, consent: false });
    console.log(JSON.stringify(res, null, 2));
    return;
  }
  if (cmd === 'writeback') {
    const res = backlogWriteBack({ projectRoot, spec, refs: [].concat(opts.ref ?? []), consent: opts.consent === 'yes' });
    console.log(JSON.stringify(res, null, 2));
    process.exit(res.status === 'matched' || res.status === 'no-backlog' ? 0 : 3);
  }
  throw new Error(`unknown command ${cmd}; use match | writeback`);
}

if (process.argv[1] && fileURLToPath(import.meta.url) === realpathOrSelf(process.argv[1])) {
  try {
    main();
  } catch (err) {
    console.error(`backlog: ${err.message}`);
    process.exit(1);
  }
}
