// Validator and status matrix of the regression scenario catalog: the `*.md` files directly in
// `catalog.path` (README.md excluded), one `### <ID> — <title>` block per scenario. Read-only.
// Owns the format checks (errors as `<file>:<line>: <message>`), the computed automation state
// (`missing | verified | stale` — the spec's `// regression:` header against the CURRENT criterion,
// resolved by backlog-check's `resolveTask` and hashed by the canonical qa-evidence-families.md §7c
// block run through bash), `--status` and `--json` (one `statusReport`, the same numbers).
// Node builtins only — ships to every downstream. Contract: .agents/reference/regression.md.
//
//   node .claude/lib/regression/catalog.mjs [--root <dir>] [--config <path>] [--status | --json]
//   exit 0 = valid (or not adopted) · 1 = validation errors · 2 = usage / unreadable or invalid config

import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { readBacklogFiles, parseBacklog, resolveTask } from '../backlog-check.mjs';
import { CONFIG_PATH, PRIORITIES, NEED_KEY, loadConfig, catalogSettings } from './config.mjs';

const REQUIRED = ['Priority', 'Viewport', 'Status', 'Effect', 'Goal', 'Steps', 'Expected', 'Source', 'Spec'];
// `Needs`: the safe means / guard operations a scenario relies on (` · `-separated keys); the
// environment check is policy.mjs's — here only the key grammar.
const OPTIONAL = ['Data', 'Needs'];
const ENUMS = { Priority: PRIORITIES, Viewport: ['desktop', 'mobile', 'both'], Effect: ['read', 'write'] };
export const STATUSES = ['READY', 'BLOCKED', 'DROPPED'];
const STATUS = new RegExp(`^(${STATUSES.join('|')})(?:\\s+\\((.*)\\))?$`);
const BLOCKED_REF = /^(E\d+-\d+|[A-Z][A-Z0-9]+-\d+|#\d+)$/;
const CRITERION = /^E\d+-\d+\.AC\d+ \[[0-9a-f]{6}\]$/;
const CRITERION_BARE = /^E\d+-\d+\.AC\d+$/;
const FLOW = /^FL-\d+(\.A\d+)?$/;
const TRACKER = /^([A-Z][A-Z0-9]+-\d+|#\d+)( \[[0-9a-f]{6}\])?$/;
const WORDS = new Set(['live', 'code']);
const SPEC = /^(\S+) › (.+)$/;
const FIELD_SPLIT = / · (?=\*\*[A-Za-z]+:\*\*)/;
const FIELD = /^\*\*([A-Za-z]+):\*\*\s*(.*)$/;
const HEADER = /^\s*\/\/ regression: (\S+) · source: (.+)$/;
const FP_BEGIN = '<!-- qa-fingerprint:begin -->';
const FP_END = '<!-- qa-fingerprint:end -->';
export const FP_REFERENCE = '.agents/reference/qa-evidence-families.md';
const BACKLOG = '.agents/backlog.md';

const isEmpty = (v) => v === undefined || /^\s*(—|-)?\s*$/.test(v);
const posix = (p) => p.split(path.sep).join('/');
// A single-value field wrapped onto continuation lines reads as one line (the header copies it on one).
const oneLine = (v) => v.replace(/\s*\n\s*/g, ' ');
/** `[match, status, ref]` of a block's Status, `[]` when it does not parse. */
export const statusOf = (b) => STATUS.exec(b.fields.Status?.value ?? '') ?? [];
const isDropped = (b) => statusOf(b)[1] === 'DROPPED';

/** Catalog files: `*.md` directly in `settings.path`, README.md excluded, sorted, repo-relative. */
export function catalogFiles(root, settings) {
  const dir = path.resolve(root, settings.path);
  if (!fs.existsSync(dir) || !fs.statSync(dir).isDirectory()) return [];
  return fs.readdirSync(dir, { withFileTypes: true })
    .filter((d) => d.isFile() && d.name.endsWith('.md') && d.name !== 'README.md')
    .map((d) => posix(path.join(settings.path, d.name))).sort();
}

/** Scenario blocks of `files`: `{id, title, file, line, fields: {Label: {value, line}}, problems}`. */
export function parseCatalog(root, files) {
  const blocks = [];
  for (const file of files) {
    const lines = fs.readFileSync(path.resolve(root, file), 'utf8').replace(/\r/g, '').split('\n');
    let block = null;
    let last = null;
    lines.forEach((line, idx) => {
      const n = idx + 1;
      if (/^#{1,3}\s/.test(line)) {
        block = null; last = null;
        if (!/^###\s/.test(line)) return;
        // The first token is the id whatever follows it; the title needs the ` — ` separator.
        const m = /^###\s+(\S+)(?:\s+(.*))?$/.exec(line.trimEnd());
        const title = /^—\s+(.+)$/.exec(m?.[2] ?? '');
        block = { id: m?.[1] ?? '', title: title ? title[1].trim() : '', file, line: n, fields: {}, problems: [] };
        blocks.push(block);
        return;
      }
      if (!block) return;
      if (line.trim() === '') return;
      if (line.startsWith('- **')) {
        last = null;
        for (const seg of line.slice(2).split(FIELD_SPLIT)) {
          const f = FIELD.exec(seg);
          if (!f) { block.problems.push({ line: n, message: 'unexpected line — expected `- **<Label>:** <value>`' }); break; }
          const [, label, value] = f;
          if (!REQUIRED.includes(label) && !OPTIONAL.includes(label)) { block.problems.push({ line: n, message: `unknown field ${label}` }); continue; }
          if (block.fields[label]) { block.problems.push({ line: n, message: `duplicate field ${label} (also at line ${block.fields[label].line})` }); continue; }
          last = block.fields[label] = { value: value.trim(), line: n };
        }
        return;
      }
      if (/^\s+\S/.test(line) || /^\d+[.)]\s/.test(line)) {
        if (last) last.value = last.value ? `${last.value}\n${line.trim()}` : line.trim();
        else block.problems.push({ line: n, message: 'continuation line with no field above it' });
        return;
      }
      block.problems.push({ line: n, message: 'unexpected line — expected `- **<Label>:** <value>`' });
    });
  }
  return blocks;
}

/** Tokens of a `Source` value (` · `-separated): `{kind, raw, id, fp}`; kind `bad` when no grammar matches. */
export function sourceTokens(value) {
  return oneLine(value).split(' · ').map((t) => t.trim()).filter((t) => t !== '').map((raw) => {
    if (CRITERION.test(raw)) { const [id, fp] = raw.split(' '); return { kind: 'criterion', raw, id, fp: fp.slice(1, -1) }; }
    if (CRITERION_BARE.test(raw)) return { kind: 'bad', raw, message: `criterion id ${raw} needs its fingerprint [<6 hex>]` };
    if (FLOW.test(raw)) return { kind: 'flow', raw, id: raw };
    const t = TRACKER.exec(raw);
    if (t) return { kind: 'tracker', raw, id: t[1], fp: t[2] ? t[2].trim().slice(1, -1) : null };
    if (WORDS.has(raw)) return { kind: 'word', raw, id: raw };
    return { kind: 'bad', raw, message: `malformed Source token ${raw}` };
  });
}

/** Keys of a `Needs` value (` · `-separated, trimmed); `[]` for `—`, empty or absent. */
export function needsKeys(value) {
  if (value === undefined || value === null || isEmpty(value)) return [];
  return oneLine(value).split(' · ').map((k) => k.trim()).filter((k) => k !== '');
}

/** `{path, title}` of a `Spec` value, `null` for `—`, `{error}` when malformed. */
export function parseSpec(value, id) {
  if (isEmpty(value)) return null;
  const m = SPEC.exec(oneLine(value).trim());
  if (!m) return { error: 'malformed Spec — expected `—` or `<repo-relative path> › <title>`' };
  const [, p, title] = m;
  if (path.isAbsolute(p) || p.includes('\\') || p.split('/').includes('..')) return { error: `malformed Spec — ${p} must be repo-relative, inside the repo` };
  if (!(title === id || (title.startsWith(id) && /^\s/.test(title.slice(id.length))))) return { error: `Spec title must start with the scenario id ${id}` };
  return { path: p, title };
}

/** Every format error of the blocks as `{file, line, message}`. Never throws; never reads automation state. */
export function validateCatalog(blocks, settings) {
  const errors = [];
  const err = (b, line, message) => errors.push({ file: b.file, line, message });
  let idRe;
  try { idRe = new RegExp(settings.id_pattern); } catch { idRe = /$^/; }
  const areas = Object.keys(settings.areas ?? {});
  for (const b of blocks) {
    if (!idRe.test(b.id)) err(b, b.line, `malformed id ${b.id || '(none)'} — expected ${settings.id_pattern}`);
    else if (areas.length && !areas.includes(b.id.split('-')[0])) err(b, b.line, `unknown area code ${b.id.split('-')[0]} in id ${b.id} — configured: ${areas.join(', ')}`);
    if (!b.title) err(b, b.line, 'missing title — expected `### <ID> — <title>`');
    for (const p of b.problems) err(b, p.line, p.message);
    for (const label of REQUIRED) if (!b.fields[label]) err(b, b.line, `missing required field ${label}`);
    for (const [label, allowed] of Object.entries(ENUMS)) {
      const f = b.fields[label];
      if (f && !allowed.includes(f.value)) err(b, f.line, `unknown ${label} value ${f.value || '(empty)'} — expected ${allowed.join('|')}`);
    }
    const st = b.fields.Status;
    const [, status, ref] = statusOf(b);
    if (st) {
      if (!status) err(b, st.line, `unknown Status value ${st.value || '(empty)'} — expected READY | BLOCKED (<ref>) | DROPPED (<reason>)`);
      else if (status === 'READY' && ref !== undefined) err(b, st.line, 'READY takes no parenthesis');
      else if (status === 'BLOCKED' && !BLOCKED_REF.test((ref ?? '').trim())) err(b, st.line, 'BLOCKED without a reference — expected BLOCKED (<Task id | tracker key | #n>)');
      else if (status === 'DROPPED' && !(ref ?? '').trim()) err(b, st.line, 'DROPPED without a reason — expected DROPPED (<reason or D-n>)');
    }
    if (status === 'READY') {
      for (const label of ['Steps', 'Expected']) {
        const f = b.fields[label];
        if (f && isEmpty(f.value)) err(b, f.line, `READY scenario with empty ${label}`);
      }
    }
    const src = b.fields.Source;
    if (src) {
      const tokens = sourceTokens(src.value);
      if (!tokens.length || isEmpty(src.value)) err(b, src.line, 'empty Source — cite a criterion, flow, tracker key, live or code');
      for (const t of tokens) if (t.kind === 'bad') err(b, src.line, t.message);
    }
    const spec = b.fields.Spec;
    if (spec) {
      const s = parseSpec(spec.value, b.id);
      if (s?.error) err(b, spec.line, s.error);
    }
    const needs = b.fields.Needs;
    if (needs) {
      const seen = new Set();
      for (const k of needsKeys(needs.value)) {
        if (!NEED_KEY.test(k)) err(b, needs.line, `malformed Needs key ${k} — expected ${NEED_KEY.source}`);
        else if (seen.has(k)) err(b, needs.line, `duplicate Needs key ${k}`);
        seen.add(k);
      }
    }
  }
  const groups = new Map();
  for (const b of blocks) if (b.id) groups.set(b.id, [...(groups.get(b.id) ?? []), b]);
  for (const [id, group] of groups) {
    if (group.length < 2) continue;
    // Anchor on the DROPPED block wherever it sits: a live block above it still reuses its id.
    const dropped = group.find(isDropped);
    const anchor = dropped ?? group[0];
    for (const b of group) {
      if (dropped && !isDropped(b)) err(b, b.line, `id ${id} reuses the id of DROPPED scenario at ${dropped.file}:${dropped.line}`);
      else if (b !== anchor) err(b, b.line, `duplicate id ${id} (also at ${anchor.file}:${anchor.line})`);
    }
  }
  return errors.sort((a, b) => (a.file < b.file ? -1 : a.file > b.file ? 1 : a.line - b.line));
}

/** The §7c block's body (between the whole-line markers, fence lines dropped), or `{error}`. */
export function extractFingerprintBlock(root) {
  const file = path.resolve(root, FP_REFERENCE);
  if (!fs.existsSync(file)) return { error: `fingerprint unavailable — ${FP_REFERENCE} absent` };
  const lines = fs.readFileSync(file, 'utf8').replace(/\r/g, '').split('\n');
  const begin = lines.indexOf(FP_BEGIN);
  const end = begin === -1 ? -1 : lines.indexOf(FP_END, begin + 1);
  if (begin === -1 || end === -1) return { error: `fingerprint unavailable — qa-fingerprint markers missing in ${FP_REFERENCE}` };
  return { block: lines.slice(begin + 1, end).filter((l) => !l.startsWith('```')).join('\n') };
}

/** Six-hex §7c fingerprint of one criterion line (fed on stdin), or null when the block fails. */
export function fingerprint(block, criterionLine) {
  const r = spawnSync('bash', ['-c', block], { input: criterionLine, encoding: 'utf8' });
  const out = (r.stdout ?? '').trim();
  return r.status === 0 && /^[0-9a-f]{6}$/.test(out) ? out : null;
}

/** The parsed backlog (cached in ctx), or null when absent or not in the current format. */
function backlogOf(root, ctx) {
  if (ctx.backlog === undefined) {
    const { md, epicFiles } = readBacklogFiles(path.resolve(root, BACKLOG));
    const parsed = md === null ? null : parseBacklog(md, { epicFiles });
    ctx.backlog = !parsed || parsed.legacy || parsed.preScope || parsed.preDetail ? null : parsed;
  }
  return ctx.backlog;
}

/** `{fp}` of the current criterion `id`, or `{error}` naming why it cannot be compared. */
export function currentFingerprint(root, id, ctx = {}) {
  ctx.fps ??= new Map();
  if (ctx.fps.has(id)) return ctx.fps.get(id);
  const res = (() => {
    const backlog = backlogOf(root, ctx);
    if (!backlog) return { error: `criterion ${id} not resolvable — no current-format ${BACKLOG}` };
    const taskId = id.split('.')[0];
    const task = backlog.tasks.find((t) => t.id === taskId);
    if (!task) return { error: `criterion ${id} no longer found — Task ${taskId} absent` };
    if (task.withdrawn) return { error: `criterion ${id} withdrawn — Task ${taskId} withdrawn` };
    const c = resolveTask(root, backlog, task).current.find((a) => a.id === id);
    if (!c) return { error: `criterion ${id} no longer found` };
    if (c.withdrawn) return { error: `criterion ${id} withdrawn` };
    ctx.block ??= extractFingerprintBlock(root);
    if (ctx.block.error) return { error: ctx.block.error };
    // One space, no added separator: §7c strips the same id + separator the original bullet had.
    const fp = fingerprint(ctx.block.block, `- **${id}** ${c.text}`);
    return fp ? { fp } : { error: 'fingerprint unavailable — the §7c block failed under bash' };
  })();
  ctx.fps.set(id, res);
  return res;
}

/** `{state, reason}` — computed from the spec header and the current criteria, never stored. */
export function automationState(root, scenario, ctx = {}) {
  const spec = parseSpec(scenario.fields.Spec?.value ?? '—', scenario.id);
  if (!spec || spec.error) return { state: 'missing', reason: 'Spec: —' };
  const file = path.resolve(root, spec.path);
  if (!fs.existsSync(file)) return { state: 'missing', reason: `spec file ${spec.path} absent` };
  let text;
  try { text = fs.readFileSync(file, 'utf8'); } catch (err) { return { state: 'stale', reason: `spec file ${spec.path} unreadable (${err.code ?? err.message})` }; }
  const header = text.replace(/\r/g, '').split('\n').map((l) => HEADER.exec(l)).find((m) => m && m[1] === scenario.id);
  if (!header) return { state: 'stale', reason: `no // regression: header for ${scenario.id} in ${spec.path}` };
  const cited = sourceTokens(scenario.fields.Source?.value ?? '');
  const written = sourceTokens(header[2]);
  const ids = (ts) => ts.map((t) => t.id ?? t.raw).sort().join(' · ');
  if (ids(cited) !== ids(written)) return { state: 'stale', reason: `header source (${ids(written)}) differs from the catalog Source (${ids(cited)})` };
  const byId = new Map(written.map((t) => [t.id ?? t.raw, t]));
  const notes = [];
  for (const t of cited) {
    if (t.kind === 'criterion') {
      const cur = currentFingerprint(root, t.id, ctx);
      if (cur.error) return { state: 'stale', reason: cur.error };
      const was = byId.get(t.id).fp;
      if (cur.fp !== was) return { state: 'stale', reason: `${t.id}: header fingerprint [${was}] differs from the current criterion [${cur.fp}]` };
    } else if (t.kind === 'tracker') {
      const was = byId.get(t.id).fp;
      if (t.fp !== was) return { state: 'stale', reason: `${t.id}: header fingerprint [${was ?? '—'}] differs from the catalog's [${t.fp ?? '—'}]` };
      notes.push(`${t.id} not readable offline — compared catalog ↔ header`);
    }
  }
  return { state: 'verified', reason: notes.join('; ') };
}

/** One scenario's JSON row (the block's fields plus its computed automation state). */
export function scenarioRow(root, b, ctx) {
  const [, status, ref] = statusOf(b);
  const a = automationState(root, b, ctx);
  const spec = b.fields.Spec?.value;
  return {
    id: b.id, title: b.title, file: b.file, line: b.line,
    priority: b.fields.Priority?.value ?? null, viewport: b.fields.Viewport?.value ?? null,
    status: status ?? null, ref: ref?.trim() ?? null, effect: b.fields.Effect?.value ?? null,
    source: b.fields.Source?.value ?? null, spec: isEmpty(spec) ? null : spec,
    needs: needsKeys(b.fields.Needs?.value),
    automation: a.state, automation_reason: a.reason,
  };
}

/** Planned coverage: `[reg P<n>]` tags on current, non-withdrawn criteria of live Tasks; null without a backlog. */
function plannedCoverage(root, ctx) {
  const backlog = backlogOf(root, ctx);
  if (!backlog) return null;
  const planned = Object.fromEntries(PRIORITIES.map((p) => [p, 0]));
  for (const task of backlog.tasks) {
    if (task.withdrawn) continue;
    for (const c of resolveTask(root, backlog, task).current) {
      if (c.withdrawn) continue;
      // Classification only: the fingerprint input keeps the separator.
      const m = /^\[reg (P[0-2])\]/.exec(c.text.replace(/^\s*[—–\-:.]?\s*/, ''));
      if (m) planned[m[1]] += 1;
    }
  }
  return planned;
}

/** The counts `--status` and `--json` both print. `rows` are `scenarioRow` results. */
export function statusReport(root, rows, ctx = {}) {
  const byStatusPriority = Object.fromEntries(STATUSES.map((s) => [s, Object.fromEntries(PRIORITIES.map((p) => [p, 0]))]));
  for (const r of rows) if (byStatusPriority[r.status]?.[r.priority] !== undefined) byStatusPriority[r.status][r.priority] += 1;
  const planned = plannedCoverage(root, ctx);
  const live = rows.filter((r) => r.status !== 'DROPPED');
  const coverage = Object.fromEntries(PRIORITIES.map((p) => {
    const written = live.filter((r) => r.priority === p);
    return [p, { planned: planned ? planned[p] : 'n/a', written: written.length, automated: written.filter((r) => r.automation === 'verified').length }];
  }));
  return {
    by_status_priority: byStatusPriority,
    coverage,
    without_spec: rows.filter((r) => r.status === 'READY' && r.automation === 'missing').map((r) => r.id),
    stale: live.filter((r) => r.automation === 'stale').map((r) => r.id),
  };
}

function renderStatus(counts, nFiles, nScenarios) {
  const out = [`catalog ok — ${nScenarios} scenarios in ${nFiles} files`, 'by status × priority:'];
  for (const s of STATUSES) out.push(`  ${s.padEnd(8)} ${PRIORITIES.map((p) => `${p}=${counts.by_status_priority[s][p]}`).join(' ')}`);
  out.push('coverage (planned / written / automated):');
  for (const p of PRIORITIES) {
    const c = counts.coverage[p];
    out.push(`  ${p}  planned=${c.planned} written=${c.written} automated=${c.automated}`);
  }
  out.push(`without spec (READY, automation missing): ${counts.without_spec.join(', ') || 'none'}`);
  out.push(`stale: ${counts.stale.join(', ') || 'none'}`);
  return out.join('\n');
}

function parseArgs(argv) {
  const args = { root: process.cwd(), config: CONFIG_PATH, status: false, json: false };
  for (let i = 0; i < argv.length; i += 1) {
    const a = argv[i];
    if (a === '--status') args.status = true;
    else if (a === '--json') args.json = true;
    else if (a === '--root' || a === '--config') {
      if (i + 1 >= argv.length) throw new UsageError(`${a} needs a value`);
      args[a.slice(2)] = argv[++i];
    } else throw new UsageError(`unknown argument ${a}`);
  }
  if (args.status && args.json) throw new UsageError('--status and --json are exclusive');
  return args;
}

class UsageError extends Error {}
const USAGE = 'usage: node .claude/lib/regression/catalog.mjs [--root <dir>] [--config <path>] [--status | --json]';

export function main(argv = process.argv.slice(2)) {
  let args;
  try { args = parseArgs(argv); } catch (err) {
    if (!(err instanceof UsageError)) throw err;
    console.error(`catalog: ${err.message}\n${USAGE}`);
    return 2;
  }
  const root = path.resolve(args.root);
  const loaded = loadConfig(root, args.config);
  if (!loaded.adopted) {
    console.log(args.json ? JSON.stringify({ adopted: false, message: 'regression not adopted' }) : 'regression not adopted');
    return 0;
  }
  if (loaded.errors.length) {
    for (const e of loaded.errors) console.error(`catalog: ${args.config}: ${e}`);
    return 2;
  }
  const settings = catalogSettings(loaded.config);
  const files = catalogFiles(root, settings);
  const blocks = parseCatalog(root, files);
  const errors = validateCatalog(blocks, settings);
  const ok = !errors.length;
  const ctx = {};
  const rows = ok ? blocks.map((b) => scenarioRow(root, b, ctx)) : [];
  const counts = ok ? statusReport(root, rows, ctx) : null;
  if (args.json) {
    console.log(JSON.stringify({ adopted: true, catalog: { path: settings.path, files }, errors, scenarios: rows, counts }, null, 2));
  } else if (!ok) {
    for (const e of errors) console.log(`${e.file}:${e.line}: ${e.message}`);
  } else if (args.status) {
    console.log(renderStatus(counts, files.length, rows.length));
  } else {
    console.log(`catalog ok — ${rows.length} scenarios in ${files.length} files`);
  }
  return ok ? 0 : 1;
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    process.exitCode = main();
  } catch (err) {
    console.error(`catalog: ${err.message}`);
    process.exitCode = 2;
  }
}
