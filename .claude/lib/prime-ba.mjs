// /prime-ba selector and extractor: measures and selects what a Business-Analyst prime loads under a
// named budget, extracts the index-shaped parts of the product documents, computes the pending-source
// queue and a code map from local git refs, and pages every output (never truncates).
//
//   node .claude/lib/prime-ba.mjs plan [--mode default|full] [--root <dir>] [--page <n>]
//   node .claude/lib/prime-ba.mjs extract <register|changelog|discovery|architecture|decisions|backlog|codemap>
//        [--summary] [--root <dir>] [--page <n>]          (--summary: backlog only)
//
// Read-only: writes nothing, fetches nothing; git calls are lock-free and run no hooks, fsmonitor or
// filter driver of the inspected checkout. Exit 0 on any repository state (problems print as ERROR
// rows); exit 2 only on a usage error.

import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

export const DEFAULT_BUDGET = 163840;
export const FULL_BUDGET = 327680;
export const PER_FILE_CAP = 40960;
export const FULL_PER_FILE_CAP = 81920;
export const PAGE_SIZE = 24576;
export const PENDING_BUDGET = 49152;
export const DECISIONS_NEWEST = 10;
export const CHANGELOG_NEWEST = 5;
export const SPECS_LISTED = 10;
export const MAXLOAD = 25;
export const MAXSKIP = 10;
export const FETCH_FRESH_HOURS = 24;
export const GIST_MAX = 72;
export const PRD_HEAD_LINES = 100;
const CONSTANTS = {
  DEFAULT_BUDGET, FULL_BUDGET, PER_FILE_CAP, FULL_PER_FILE_CAP, PAGE_SIZE, PENDING_BUDGET, DECISIONS_NEWEST,
  CHANGELOG_NEWEST, SPECS_LISTED, MAXLOAD, MAXSKIP, FETCH_FRESH_HOURS, GIST_MAX, PRD_HEAD_LINES,
};

export const SOURCE_EXT = new Set(['.ts', '.tsx', '.js', '.jsx', '.mjs', '.cjs', '.py', '.rb', '.go', '.rs', '.java',
  '.kt', '.kts', '.cs', '.fs', '.swift', '.m', '.dart', '.php', '.c', '.cc', '.cpp', '.h', '.hpp', '.scala', '.vue',
  '.svelte', '.sql', '.sh', '.ps1', '.lua', '.ex', '.exs', '.erl', '.clj', '.r', '.jl']);
const WORKFLOW_DIRS = ['.agents/', '.claude/', '.codex/', '.github/', 'docs/', 'tools/agent_mail/'];
const SCRIPT_CMD = 'node .claude/lib/prime-ba.mjs';
const TOTAL_PAD = 32;

// Re-declared from backlog-check.mjs (not exported there): DECISION_HEADING, REGISTER_ID, SCOPE_REV.
const DECISION_HEADING = /^###\s+(D-(\d+))\s+[—-]/;
const REGISTER_ID = /^(G|R|NFR)-\d+$/;
const SCOPE_REV = /\*\*Scope rev:\*\*\s*(v\d+\.\d+)/;
const BOLD_ID_LINE = /^\s*[-*]\s+\*\*([A-Za-z]+-\d+)\*\*\s*[—-]\s*/;
const CORRECTION_NAME = /^(.*)-correction(?:-(\d+))?\.md$/;
const RESYNC_REPORT = /^\d{4}-\d{2}-\d{2}-\d{6}-E(\d+)(-\d+)?\.md$/;

const HERE = path.dirname(fileURLToPath(import.meta.url));
let BC = null;
let BC_ERR = 'not loaded';

/** Load backlog-check.mjs once; on failure the dependent layers print ERROR rows. Exported for tests. */
export async function loadChecker() {
  if (BC) return;
  try { BC = await import('./backlog-check.mjs'); } catch (e) { BC = null; BC_ERR = e.message.split('\n')[0]; }
}
const bcMissing = (layer) => `ERROR\t${layer}\tbacklog-check.mjs not loadable — ${BC_ERR}\n`;

// ---------------------------------------------------------------------------------------------
// Readers and small helpers
// ---------------------------------------------------------------------------------------------

const bytes = (s) => Buffer.byteLength(s, 'utf8');
const kb = (n) => (n / 1024).toFixed(1);
const posix = (p) => p.split(path.sep).join('/');

/** `{ text, size, buf }` of a regular file (symlinks followed, directories skipped), else null. */
export function readText(root, rel) {
  const abs = path.resolve(root, rel);
  try {
    const st = fs.statSync(abs);
    if (!st.isFile()) return null;
    const buf = fs.readFileSync(abs);
    return { text: buf.toString('utf8'), size: st.size, buf };
  } catch { return null; }
}

/** Top-level `*.md` regular files of `dir` (relative to root), sorted, as root-relative posix paths. */
export function listMd(root, dir) {
  let entries;
  try { entries = fs.readdirSync(path.join(root, dir)); } catch { return []; }
  return entries.filter((n) => n.endsWith('.md')).filter((n) => {
    try { return fs.statSync(path.join(root, dir, n)).isFile(); } catch { return false; }
  }).sort().map((n) => posix(path.join(dir, n)));
}

const sha12 = (buf) => crypto.createHash('sha256').update(buf).digest('hex').slice(0, 12);

/** Quote each argument for a POSIX shell unless it is plainly safe. */
export function shellQuote(argv) {
  return argv.map((a) => (/^[A-Za-z0-9_./:=@%+-]+$/.test(a) ? a : `'${String(a).replace(/'/g, `'\\''`)}'`)).join(' ');
}

const frontStatus = (text) => {
  const head = text.split('\n').slice(0, 10).join('\n');
  return /^status:\s*(\S+)/m.exec(head)?.[1] ?? 'no-frontmatter';
};
const isFilled = (text) => ['populated', 'seeded'].includes(frontStatus(text));

const mask = (lines) => (BC ? BC.fenceMask(lines) : lines.map(() => false));

/** Lines of the `## <title>` section (heading included) up to the next unfenced `## ` heading. */
function section(text, title) {
  const lines = text.split('\n');
  const fenced = mask(lines);
  const start = lines.findIndex((l, i) => !fenced[i] && l.trim().toLowerCase().startsWith(`## ${title.toLowerCase()}`));
  if (start === -1) return null;
  let end = start + 1;
  while (end < lines.length && !(!fenced[end] && /^##\s/.test(lines[end]))) end += 1;
  return lines.slice(start, end);
}

const trimBlank = (lines) => {
  const out = [...lines];
  while (out.length && out[out.length - 1].trim() === '') out.pop();
  return out;
};

// ---------------------------------------------------------------------------------------------
// Paging
// ---------------------------------------------------------------------------------------------

const continuation = (cmdline, next) => `… continued — run: ${SCRIPT_CMD} ${cmdline} --page ${next}\n`;

/** Split a string into chunks of at most `max` UTF-8 bytes without cutting a character. */
function splitBytes(line, max) {
  const out = [];
  let cur = '';
  let curBytes = 0;
  for (const ch of line) {
    const b = bytes(ch);
    if (curBytes + b > max && cur) { out.push(cur); cur = ''; curBytes = 0; }
    cur += ch; curBytes += b;
  }
  if (cur || !out.length) out.push(cur);
  return out;
}

/**
 * Pages of `text`, each at most `size` bytes; every page but the last ends with the continuation
 * line naming `cmdline`. Lines are kept whole; a line longer than a page is split on a UTF-8 boundary.
 */
export function paginate(text, size = PAGE_SIZE, cmdline = '') {
  const reserve = bytes(continuation(cmdline, 999999));
  const room = Math.max(64, size - reserve);
  const lines = text.split('\n');
  if (lines[lines.length - 1] === '') lines.pop();
  const units = lines.flatMap((l) => (bytes(l) + 1 > room ? splitBytes(l, room - 1) : [l])).map((l) => `${l}\n`);
  const bodies = [];
  let cur = '';
  let curBytes = 0;
  for (const u of units) {
    const b = bytes(u);
    if (curBytes + b > room && cur) { bodies.push(cur); cur = ''; curBytes = 0; }
    cur += u; curBytes += b;
  }
  if (cur || !bodies.length) bodies.push(cur);
  return bodies.map((body, i) => (i < bodies.length - 1 ? body + continuation(cmdline, i + 2) : body));
}

const pagesBytes = (pages) => pages.reduce((s, p) => s + bytes(p), 0);

// ---------------------------------------------------------------------------------------------
// Extractors
// ---------------------------------------------------------------------------------------------

function gistOf(text) {
  let g = text.replace(BOLD_ID_LINE, '').replace(/^\([^)]*\)\s*/, '');
  const cuts = [' Traces:', ' Source:', ' Quote:', ' Added:', ' · '].map((c) => g.indexOf(c)).filter((i) => i !== -1);
  if (cuts.length) g = g.slice(0, Math.min(...cuts));
  g = g.trim().replace(/[\s·—-]+$/, '').trim();
  return g.length > GIST_MAX ? `${g.slice(0, GIST_MAX - 1)}…` : g;
}

function indexLine(id, entry, gist) {
  const st = entry?.state ?? 'unknown';
  if (st === 'active') return `${id} · active · ${gist}`;
  if (st === 'superseded') return `${id} · superseded by ${entry.successor}${entry.decision ? ` per ${entry.decision}` : ''}`;
  if (st === 'withdrawn') return `${id} · withdrawn${entry.decision ? ` per ${entry.decision}` : ''}`;
  if (st === 'n/a') return `${id} · n/a · ${gist}`;
  return `${id} · ${st}`;
}

export function extractRegister(root) {
  const prd = readText(root, 'docs/PRD.md');
  if (!prd) return 'docs/PRD.md absent — run /discover\n';
  if (!BC) return bcMissing('register');
  const lines = prd.text.split('\n');
  const out = [lines.find((l) => l.includes('**Baseline:**')) ?? 'no register header — /discover adopts it'];
  const inv = BC.loadInventory(root);
  const reg = new Map([...inv.ids].filter(([id, v]) => v.source === 'prd' && REGISTER_ID.test(id)));
  const counts = ['G', 'R', 'NFR'].map((k) => {
    const c = { active: 0, superseded: 0, withdrawn: 0, 'n/a': 0 };
    for (const [id, v] of reg) if (id.startsWith(`${k}-`)) c[v.state] = (c[v.state] ?? 0) + 1;
    return `${k} ${Object.entries(c).map(([s, n]) => `${s}=${n}`).join(' ')}`;
  });
  out.push(`Counts: ${counts.join(' · ')}`, '');

  const tableRows = new Map();
  for (const t of BC.parseTables(prd.text)) {
    for (const row of t.rows) {
      const id = BC.cleanId(row[t.header[0]]);
      if (!REGISTER_ID.test(id)) continue;
      const cell = row.Requirement ?? row[t.header[1]] ?? '';
      tableRows.set(row._line, { id, cell: BC.cleanId(cell) });
    }
  }
  const fenced = mask(lines);
  const seen = new Set();
  let heading = null;
  lines.forEach((line, i) => {
    if (fenced[i]) return;
    if (/^##\s/.test(line)) { heading = null; return; }
    if (/^###\s/.test(line)) { heading = line; return; }
    let id = null;
    let gist = '';
    const t = tableRows.get(i + 1);
    if (t) {
      id = t.id;
      const entry = reg.get(id);
      gist = entry?.state === 'n/a' ? t.cell.replace(/^N\/A\b\s*[—:-]?\s*/, '') : t.cell;
      gist = gistOf(gist);
    } else {
      const m = BOLD_ID_LINE.exec(line);
      if (m && REGISTER_ID.test(m[1])) { id = m[1]; gist = gistOf(line); }
    }
    if (!id || seen.has(id) || !reg.has(id)) return;
    seen.add(id);
    if (heading) { out.push(heading); heading = null; }
    out.push(indexLine(id, reg.get(id), gist));
  });
  // An id the walk did not meet (an unusual layout) is still listed, never dropped.
  for (const [id, v] of reg) if (!seen.has(id)) out.push(indexLine(id, v, ''));
  for (const p of inv.problems) out.push(`problem: ${p}`);
  return `${out.join('\n')}\n`;
}

/**
 * `D-n` blocks of the PRD: `[{ id, n, lines }]` in file order (unfenced headings only). A block also
 * ends at an unfenced `<!--` line — the PRD template keeps its entry-format comment after the entries.
 */
function decisionBlocks(text) {
  const lines = text.split('\n');
  const fenced = mask(lines);
  const blocks = [];
  let cur = null;
  lines.forEach((line, i) => {
    const d = fenced[i] ? null : DECISION_HEADING.exec(line);
    if (d) { cur = { id: d[1], n: Number(d[2]), lines: [line] }; blocks.push(cur); return; }
    if (!fenced[i] && (/^#{2,3}\s/.test(line) || line.trimStart().startsWith('<!--'))) { cur = null; return; }
    if (cur) cur.lines.push(line);
  });
  return blocks;
}

export function extractChangelog(root) {
  const prd = readText(root, 'docs/PRD.md');
  if (!prd) return 'docs/PRD.md absent — run /discover\n';
  if (!BC) return bcMissing('changelog');
  const log = section(prd.text, 'Change log');
  const blocks = log ? decisionBlocks(log.join('\n')) : [];
  const newest = [...blocks].sort((a, b) => b.n - a.n).slice(0, CHANGELOG_NEWEST);
  const out = [`D-n entries: ${blocks.length} · shown: newest ${newest.length}`];
  if (!log) out.push('no ## Change log section');
  for (const b of newest) out.push('', ...trimBlank(b.lines));
  return `${out.join('\n')}\n`;
}

export function extractDiscovery(root) {
  const doc = readText(root, 'docs/discovery.md');
  if (!doc) return 'docs/discovery.md absent — run /discover\n';
  const out = [];
  for (const title of ['Coverage', 'Open questions']) {
    const s = section(doc.text, title);
    out.push(...(s ? trimBlank(s) : [`no ## ${title} section`]), '');
  }
  const lines = doc.text.split('\n');
  const fenced = mask(lines);
  const critical = [];
  let flow = null;
  lines.forEach((line, i) => {
    if (fenced[i]) return;
    if (/^###\s+FL-\d+/.test(line)) { flow = line; return; }
    if (/^#{2,3}\s/.test(line)) { flow = null; return; }
    if (flow && /^\*\*Critical:\*\*\s*yes/i.test(line.trim())) { critical.push(flow); flow = null; }
  });
  out.push(`Critical flows (${critical.length}):`, ...critical);
  return `${out.join('\n')}\n`;
}

export function extractArchitecture(root) {
  const doc = readText(root, 'docs/architecture.md');
  if (!doc) return 'docs/architecture.md absent — run /architect\n';
  if (!BC) return bcMissing('architecture');
  const out = [doc.text.split('\n').find((l) => l.startsWith('**Status:**')) ?? 'no **Status:** line'];
  const sub = section(doc.text, 'Subdomains');
  out.push('', ...(sub ? trimBlank(sub) : ['no ## Subdomains section']), '');
  const dec = section(doc.text, 'Decisions');
  const rows = [];
  if (dec) {
    for (const t of BC.parseTables(dec.join('\n'))) {
      for (const row of t.rows) {
        const id = BC.cleanId(row[t.header[0]]);
        if (!/^AD-\d+$/.test(id)) continue;
        const d = (row.Decision ?? '').trim();
        rows.push(`${id} · ${d.length > 80 ? `${d.slice(0, 79)}…` : d} · ${(row.Status ?? '').trim() || '—'}`);
      }
    }
  }
  out.push(`Decisions (${rows.length}):`, ...rows);
  return `${out.join('\n')}\n`;
}

export function extractDecisions(root) {
  const doc = readText(root, '.agents/memory/decisions.md');
  if (!doc) return '.agents/memory/decisions.md absent\n';
  if (!BC) return bcMissing('decisions');
  const lines = doc.text.split('\n');
  const fenced = mask(lines);
  let heads = lines.map((l, i) => (!fenced[i] && /^##\s/.test(l) ? i : -1)).filter((i) => i !== -1);
  const fmt = heads.findIndex((i) => /^##\s+Format\b/i.test(lines[i]));
  if (fmt !== -1) heads = heads.slice(fmt + 1);
  const entries = heads.map((start, k) => {
    let end = k + 1 < heads.length ? heads[k + 1] : lines.length;
    // A top-level `# ` heading also ends an entry.
    for (let j = start + 1; j < end; j += 1) if (!fenced[j] && /^#\s/.test(lines[j])) { end = j; break; }
    const date = /^##\s+(\d{4}-\d{2}-\d{2})\s+[—-]/.exec(lines[start])?.[1] ?? null;
    return { pos: k, date, heading: lines[start], body: trimBlank(lines.slice(start, end)) };
  });
  const dated = entries.filter((e) => e.date).sort((a, b) => (a.date === b.date ? b.pos - a.pos : a.date < b.date ? 1 : -1));
  let newest = dated.slice(0, DECISIONS_NEWEST);
  if (newest.length < DECISIONS_NEWEST) {
    newest = newest.concat(entries.filter((e) => !e.date).reverse().slice(0, DECISIONS_NEWEST - newest.length));
  }
  const out = [`Headings (${entries.length}):`, ...entries.map((e) => e.heading), '', `Newest ${newest.length} in full:`];
  for (const e of newest) out.push('', ...e.body);
  return `${out.join('\n')}\n`;
}

export function extractBacklog(root, { summary = false } = {}) {
  const backlogPath = path.join(root, '.agents', 'backlog.md');
  if (!readText(root, '.agents/backlog.md')) return 'no local backlog — .agents/backlog.md absent\n';
  const out = [];
  const checker = path.join(HERE, 'backlog-check.mjs');
  if (!fs.existsSync(checker)) {
    out.push('backlog-check.mjs absent — workflow older than the Epic/Task backlog');
  } else {
    let text;
    let code = 0;
    try {
      text = execFileSync(process.execPath, [checker, '--root', root], { cwd: root, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] });
    } catch (e) {
      text = `${e.stdout ?? ''}${e.stderr ?? ''}`;
      code = e.status ?? 1;
    }
    out.push('backlog-check:', ...trimBlank(text.split('\n')));
    if (code) out.push(`exit ${code}`);
  }
  if (!BC) return `${out.join('\n')}\n${bcMissing('backlog')}`;
  const { md, epicFiles } = BC.readBacklogFiles(backlogPath);
  const parsed = BC.parseBacklog(md, { epicFiles });
  out.push(`Detail: ${parsed.detail ?? 'none'}`);
  const last = md.split('\n').find((l) => l.startsWith('**Last check:**'));
  // No recorded hash (absent line, or /setup:create-backlog's `— (written by /check-backlog …)` placeholder).
  const recorded = last ? /sha256:\s*([0-9a-f]{12})/.exec(last)?.[1] : undefined;
  if (!recorded) out.push('Last check: never checked — /check-backlog');
  else out.push(`Last check: ${last} — ${recorded === BC.backlogFingerprint(md, epicFiles) ? 'fresh' : 'stale'}`);
  const current = BC.loadInventory(root).scopeRev;
  const rev = SCOPE_REV.exec(md)?.[1] ?? null;
  out.push(`Register: Current ${current ?? '—'} · Scope rev ${rev ?? '—'}${current && rev && current !== rev ? ' — behind — run /update-backlog' : ''}`);
  if (summary) {
    out.push('', `Epic map (${parsed.epics.length}):`);
    for (const e of parsed.epics) {
      const tasks = parsed.tasks.filter((t) => t.epic === e.id);
      const by = {};
      for (const t of tasks) by[t.status || '—'] = (by[t.status || '—'] ?? 0) + 1;
      const done = tasks.filter((t) => t.status === 'DONE').reduce((s, t) => s + (Number.isFinite(t.pts) ? t.pts : 0), 0);
      const total = tasks.filter((t) => !t.withdrawn).reduce((s, t) => s + (Number.isFinite(t.pts) ? t.pts : 0), 0);
      const st = Object.entries(by).map(([k, n]) => `${k}=${n}`).join(' ') || 'no Tasks';
      out.push(`${e.id} · ${e.title} · Tasks ${tasks.length} (${st}) · pts ${done}/${total}`);
    }
  }
  return `${out.join('\n')}\n`;
}

export function extractCodemap(root, roots) {
  if (!BC) return bcMissing('codemap');
  const out = [];
  for (const r of roots) {
    if (!fs.existsSync(path.join(r.abs, 'docs', 'map', 'system.yaml'))) continue;
    try {
      const sys = BC.loadSystem(r.abs);
      const nodes = Array.isArray(sys?.nodes) ? sys.nodes : [];
      out.push(`${r.name}:`, ...nodes.map((n) => `  ${n?.id ?? '?'} — ${n?.name ?? ''}`));
    } catch (e) {
      out.push(`ERROR ${r.name} system.yaml — ${e.message}`);
    }
  }
  if (!out.length) out.push('docs/map/system.yaml absent in every code root');
  return `${out.join('\n')}\n`;
}

// ---------------------------------------------------------------------------------------------
// Pending queue, note families, raw sources
// ---------------------------------------------------------------------------------------------

const normPath = (p) => p.replace(/`/g, '').trim().replace(/^\.\//, '');

/** Processed sources from every `D-n` with a filled `**Tasks:**` line. */
function processedSources(prdText) {
  const hashes = new Set();
  const byPath = new Map();
  for (const b of decisionBlocks(prdText)) {
    const tasks = b.lines.map((l) => /^\*\*Tasks:\*\*(.*)$/.exec(l)?.[1]).find((v) => v !== undefined);
    if (tasks === undefined || ['', '—', '-'].includes(tasks.trim())) continue;
    const src = b.lines.map((l) => /^\*\*Sources:\*\*(.*)$/.exec(l)?.[1]).find((v) => v !== undefined) ?? '';
    for (const h of src.match(/\b[0-9a-f]{12}\b/g) ?? []) hashes.add(h);
    for (const part of src.split(/\s+·\s+/)) {
      const hash = /\b([0-9a-f]{12})\b/.exec(part)?.[1] ?? null;
      const p = /`([^`]+)`/.exec(part)?.[1] ?? part.trim().split(/\s+/)[0] ?? '';
      if (!p || !/[./]/.test(p)) continue;
      const key = normPath(p);
      const prev = byPath.get(key) ?? [];
      prev.push({ hash, n: b.n, id: b.id });
      byPath.set(key, prev);
    }
  }
  return { hashes, byPath };
}

export function pendingSources(root) {
  const cands = [
    ...listMd(root, '.agents/meeting-notes').map((p) => ({ kind: 'note', path: p })),
    ...listMd(root, '.agents/specs').map((p) => ({ kind: 'spec', path: p })),
    ...(readText(root, 'docs/discovery.md') ? [{ kind: 'discovery', path: 'docs/discovery.md' }] : []),
  ];
  const prd = readText(root, 'docs/PRD.md');
  const proc = prd ? processedSources(prd.text) : null;
  const items = [];
  for (const c of cands) {
    const f = readText(root, c.path);
    if (!f) continue;
    const hash = sha12(f.buf);
    const item = { ...c, size: f.size, hash, pending: true, changed: null };
    if (proc) {
      if (proc.hashes.has(hash)) item.pending = false;
      else {
        const other = (proc.byPath.get(c.path) ?? []).filter((e) => e.hash && e.hash !== hash);
        if (other.length) item.changed = other.sort((a, b) => b.n - a.n)[0].id;
      }
    }
    items.push(item);
  }
  return { items, noPrd: !prd };
}

export function noteFamilies(root) {
  const notes = listMd(root, '.agents/meeting-notes');
  // A correction is a `-correction*` file that names its original on a `**Corrects:**` line
  // (meeting-notes.md); a meeting whose slug merely ends in `-correction` stays an original.
  const corrections = new Map();
  for (const p of notes) {
    const m = CORRECTION_NAME.exec(path.basename(p));
    if (!m) continue;
    const named = /\*\*Corrects:\*\*\s*(\S+)/.exec(readText(root, p)?.text ?? '')?.[1];
    if (named) corrections.set(p, { m, named });
  }
  const originals = notes.filter((p) => !corrections.has(p));
  const families = new Map(originals.map((p) => [p, { orig: p, members: [p], corrections: [] }]));
  const errors = [];
  for (const [p, { m, named }] of corrections) {
    // Membership is the `**Corrects:**` line alone: a missing original is an orphan, never the file-name stem.
    const target = originals.find((o) => path.basename(o) === path.basename(normPath(named)));
    if (!target) { errors.push(`ERROR\torphan correction\t${p}`); continue; }
    families.get(target).corrections.push({ path: p, k: m[2] ? Number(m[2]) : 1 });
  }
  for (const f of families.values()) {
    f.corrections.sort((a, b) => a.k - b.k);
    f.members = [f.orig, ...f.corrections.map((c) => c.path)];
    f.size = f.members.reduce((s, p) => s + (readText(root, p)?.size ?? 0), 0);
  }
  return { families: [...families.values()], errors };
}

/** Effective `Coverage` / `Source` of a family after its `## Metadata` corrections; conflicts as ERROR rows. */
export function effectiveMeta(root, family) {
  const orig = readText(root, family.orig)?.text ?? '';
  const meta = {
    Coverage: /^\*\*Coverage:\*\*\s*(.*)$/m.exec(orig)?.[1]?.trim() ?? '',
    Source: /^\*\*Source:\*\*\s*(.*)$/m.exec(orig)?.[1]?.trim() ?? '',
  };
  const errors = [];
  for (const c of family.corrections) {
    const s = section(readText(root, c.path)?.text ?? '', 'Metadata') ?? [];
    for (const line of s.slice(1)) {
      const m = /^\s*[-*]\s+(\w+):\s*(.*?)\s*⟵\s*was:\s*"(.*)"\s*$/.exec(line);
      if (!m || !(m[1] in meta)) continue;
      if (m[3].trim() === meta[m[1]].trim()) meta[m[1]] = m[2].trim();
      else {
        errors.push(`ERROR\tcorrection conflict\t${c.path} — ${m[1]} was "${m[3]}", effective "${meta[m[1]]}"`);
        meta[m[1]] = 'unresolved';
      }
    }
  }
  return { meta, errors };
}

function rawSources(root, metas) {
  const covered = new Set();
  for (const { meta } of metas) {
    if (meta.Coverage === 'unresolved' || meta.Source === 'unresolved' || !/^full\b/i.test(meta.Coverage)) continue;
    for (const s of meta.Source.split(/[,·]/)) covered.add(normPath(s));
  }
  const out = [];
  const walk = (rel, depth) => {
    let names;
    try { names = fs.readdirSync(path.join(root, rel)).sort(); } catch { return; }
    for (const n of names) {
      const r = posix(path.join(rel, n));
      let st;
      try { st = fs.statSync(path.join(root, r)); } catch { continue; }
      if (st.isDirectory()) { if (depth < 3) walk(r, depth + 1); continue; }
      if (st.isFile() && !covered.has(r)) out.push({ path: r, size: st.size });
    }
  };
  walk('.agents/sources', 1);
  return out;
}

// ---------------------------------------------------------------------------------------------
// Code roots
// ---------------------------------------------------------------------------------------------

/** stdout of a lock-free git read that runs no hooks or fsmonitor of the checkout; null on failure.
 *  It may still compare working-tree content (and so run a filter driver) — see refState. */
function gitReadWith(globals, p, ...args) {
  try {
    return execFileSync('git', ['--no-optional-locks', '--no-replace-objects', ...globals, '-c', 'core.fsmonitor=false',
      '-c', 'core.hooksPath=/dev/null', '-C', p, ...args], {
      encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'],
      env: { ...process.env, GIT_NO_REPLACE_OBJECTS: '1', GIT_OPTIONAL_LOCKS: '0' },
    });
  } catch { return null; }
}
const gitRead = (p, ...args) => gitReadWith([], p, ...args);

// Empty tree per object format: as `--attr-source` it leaves no attribute, so no filter driver applies.
const EMPTY_TREE = {
  sha1: '4b825dc642cb6eb9a060e54bf8d69288fbee4904',
  sha256: '6ef19b41225c5369f1c104d45d8d85efa9b057b53b14b4b9b939dd74decc5321',
};

export function holdsSource(root) {
  if (gitRead(root, 'rev-parse', '--is-inside-work-tree')?.trim() !== 'true') return false;
  const files = (gitRead(root, 'ls-files', '-z') ?? '').split('\0').filter(Boolean);
  return files.some((f) => !WORKFLOW_DIRS.some((d) => f.startsWith(d)) && SOURCE_EXT.has(path.extname(f).toLowerCase()));
}

export function codeRoots(root) {
  const roots = [];
  const errors = [];
  if (holdsSource(root)) roots.push({ name: 'this repo', path: '.', abs: path.resolve(root) });
  const prof = readText(root, '.claude/project-profile.json');
  let profileMissing = !prof;
  if (prof) {
    let repos;
    try { repos = JSON.parse(prof.text)?.ba?.code_repos; } catch (e) { errors.push(`ERROR\tprofile\t.claude/project-profile.json — ${e.message}`); }
    if (repos !== undefined && !Array.isArray(repos)) errors.push('ERROR\tba.code_repos\tnot an array — expected [{ "name", "path" }]');
    else if (repos) {
      repos.forEach((r, i) => {
        if (!r || typeof r !== 'object' || typeof r.path !== 'string' || !r.path) {
          errors.push(`ERROR\tba.code_repos\tentry ${i} has no string "path" — skipped`);
          return;
        }
        roots.push({ name: typeof r.name === 'string' && r.name ? r.name : r.path, path: r.path, abs: path.resolve(root, r.path) });
      });
    }
  }
  const seen = new Set();
  const unique = roots.filter((r) => {
    let key = r.abs;
    try { key = fs.realpathSync(r.abs); } catch { /* missing path keeps its resolved form */ }
    if (seen.has(key)) return false;
    seen.add(key);
    return true;
  });
  return { roots: unique, errors, profileMissing };
}

/**
 * Branch, upstream and ahead/behind from refs only (`for-each-ref` `%(upstream:track)`); dirty from
 * the index (`diff --cached`), the working tree (`diff-files` under an empty `--attr-source`) and
 * untracked files. Never `git status` or a plain `diff-files`: a racily-clean entry makes them compare
 * content through the filter driver the checkout configures (git < 2.40 lacks `--attr-source` →
 * `dirty=unknown`).
 */
function refState(abs) {
  const headRef = (gitRead(abs, 'symbolic-ref', '-q', 'HEAD') ?? '').trim();
  const st = { branch: headRef ? headRef.replace(/^refs\/heads\//, '') : '(detached)', upstream: null, gone: false, ahead: null, behind: null };
  if (headRef) {
    const [up = '', track = ''] = (gitRead(abs, 'for-each-ref', '--format=%(upstream:short)%09%(upstream:track)', headRef) ?? '')
      .split('\n')[0].split('\t');
    st.upstream = up.trim() || null;
    st.gone = /\bgone\b/.test(track);
    if (st.upstream && !st.gone) {
      st.ahead = Number(/ahead (\d+)/.exec(track)?.[1] ?? 0);
      st.behind = Number(/behind (\d+)/.exec(track)?.[1] ?? 0);
    }
  }
  const staged = gitRead(abs, 'diff', '--cached', '--no-ext-diff', '--name-only');
  const empty = EMPTY_TREE[(gitRead(abs, 'rev-parse', '--show-object-format') ?? '').trim()];
  const unstaged = empty ? gitReadWith([`--attr-source=${empty}`], abs, 'diff-files', '--name-only') : null;
  const untracked = gitRead(abs, 'ls-files', '--others', '--exclude-standard', '--directory', '--no-empty-directory');
  st.dirty = [staged, unstaged, untracked].some((o) => o !== null && o.trim() !== '') ? 'dirty'
    : [staged, unstaged, untracked].includes(null) ? 'dirty=unknown' : 'clean';
  return st;
}

export function codeRootState(abs, now = Date.now()) {
  if (!fs.existsSync(abs)) return 'path missing';
  if (gitRead(abs, 'rev-parse', '--is-inside-work-tree')?.trim() !== 'true') return 'not a git checkout';
  const { branch, upstream, gone, ahead, behind, dirty } = refState(abs);
  const [h, date] = (gitRead(abs, 'log', '-1', '--format=%h%x09%cs') ?? '').trim().split('\t');
  const fhPath = (gitRead(abs, 'rev-parse', '--path-format=absolute', '--git-path', 'FETCH_HEAD') ?? '').trim();
  let fetched = null;
  try { if (fhPath) fetched = fs.statSync(fhPath).mtimeMs; } catch { fetched = null; }
  let verdict = 'fresh';
  if (behind > 0) verdict = 'stale';
  else if (behind === null || fetched === null || now - fetched > FETCH_FRESH_HOURS * 3600 * 1000) verdict = 'unknown';
  const fetchText = fetched === null ? 'never' : new Date(fetched).toISOString().slice(0, 16).replace('T', ' ');
  return `branch=${branch} head=${h || 'none'}${date ? ` (${date})` : ''} upstream=${upstream ?? 'none'}${gone ? ' (gone)' : ''} `
    + `ahead=${ahead ?? '?'} behind=${behind ?? '?'} `
    + `${dirty} last-fetch=${fetchText} ${verdict}${verdict === 'fresh' ? '' : ' — run /pull there before verifying against code'}`;
}

// ---------------------------------------------------------------------------------------------
// Listings
// ---------------------------------------------------------------------------------------------

function specRows(root) {
  const specs = listMd(root, '.agents/specs');
  let total = 0;
  for (const s of specs) total += readText(root, s)?.size ?? 0;
  const dated = specs.map((p) => ({ p, date: /^(\d{4}-\d{2}-\d{2})/.exec(path.basename(p))?.[1] ?? '' }))
    .sort((a, b) => (a.date === b.date ? (a.p < b.p ? 1 : -1) : a.date < b.date ? 1 : -1));
  const rows = [`SPECS_TOTAL\t${specs.length} files / ${total} bytes (listing only — never auto-read)`];
  for (const { p, date } of dated.slice(0, SPECS_LISTED)) {
    const head = (readText(root, p)?.text ?? '').split('\n').slice(0, 30);
    const kind = head.map((l) => /^\*\*Kind:\*\*\s*(\S+)/.exec(l)?.[1]).find(Boolean) ?? 'design';
    const status = head.map((l) => /^\*\*Status:\*\*\s*(.+)$/.exec(l)?.[1]).find(Boolean)?.trim() ?? '—';
    const title = (head.find((l) => l.startsWith('# ')) ?? '# —').slice(2).replace(/^Design:\s*/, '').trim();
    rows.push(`SPEC\t${date || '—'}\t${kind}\t${status}\t${title}\t${p}`);
  }
  return { rows, specs: dated.map((d) => d.p) };
}

function byMtimeDesc(root, files) {
  return files.map((p) => ({ p, t: (() => { try { return fs.statSync(path.join(root, p)).mtimeMs; } catch { return 0; } })() }))
    .sort((a, b) => b.t - a.t).map((x) => x.p);
}

function jiraRows(root) {
  const rows = [];
  const inprog = path.join(root, '.agents', 'jira', 'inprogress');
  let epics = [];
  try { epics = fs.readdirSync(inprog).filter((d) => /^E\d+$/.test(d)).sort((a, b) => Number(a.slice(1)) - Number(b.slice(1))); } catch { /* none */ }
  for (const e of epics) {
    const files = listMd(root, `.agents/jira/inprogress/${e}`);
    const pending = files.filter((f) => {
      const t = readText(root, f)?.text ?? '';
      const m = /^ops:(.*)$/m.exec(t);
      if (!m) return false;
      const inline = m[1].replace(/\s#.*$/, '').trim(); // the draft template writes `ops: {}   # …`
      if (inline && inline !== '{}') return true;
      const after = t.slice(m.index + m[0].length).split('\n').slice(1);
      const block = [];
      for (const l of after) { if (!/^\s+\S/.test(l)) break; block.push(l); }
      return block.some((l) => /pending/.test(l));
    });
    rows.push(`JIRA_DRAFTS\t${e}\t${files.length}\t${pending.map((f) => path.basename(f)).join(', ') || 'no pending ops'}`);
  }
  let reports = [];
  try { reports = fs.readdirSync(path.join(root, '.agents', 'jira', 'sync-reports')).filter((n) => RESYNC_REPORT.test(n)); } catch { /* none */ }
  const newest = new Map();
  for (const n of reports.sort()) newest.set(Number(RESYNC_REPORT.exec(n)[1]), n);
  for (const [n, name] of [...newest].sort((a, b) => a[0] - b[0])) rows.push(`JIRA_RESYNC\tE${n}\t${name}`);
  const jira = readText(root, '.agents/memory/domain/jira.md')?.text ?? '';
  const groom = jira.split('\n').filter((l) => /^##\s+.*Grooming patterns/.test(l));
  for (const g of groom.slice(-2).reverse()) rows.push(`JIRA_GROOMING\t${g.replace(/^##\s+/, '')}`);
  return rows;
}

// ---------------------------------------------------------------------------------------------
// Selector
// ---------------------------------------------------------------------------------------------

const MANDATORY_ORDER = ['frame', 'register', 'changelog', 'discovery', 'architecture', 'decisions', 'backlog'];
/** Every extract part, in usage order: `(root, { summary, roots }) => text`. */
const EXTRACTORS = {
  register: extractRegister, changelog: extractChangelog, discovery: extractDiscovery,
  architecture: extractArchitecture, decisions: extractDecisions,
  backlog: (root, o) => extractBacklog(root, { summary: o.summary }),
  codemap: (root, o) => extractCodemap(root, o.roots),
};
export const PARTS = Object.keys(EXTRACTORS);

function extractCmd(part, summary, rootArg) {
  const argv = ['extract', part];
  if (summary) argv.push('--summary');
  if (rootArg) argv.push('--root', rootArg);
  return shellQuote(argv);
}

function renderExtract(root, part, { summary = false, roots = [] } = {}) {
  return EXTRACTORS[part](root, { summary, roots });
}

function measureExtract(root, part, opts, rootArg) {
  const cmd = extractCmd(part, opts.summary, rootArg);
  let text;
  try { text = renderExtract(root, part, opts); } catch (e) { text = `ERROR\t${part}\t${e.message}\n`; }
  const pages = paginate(text, PAGE_SIZE, cmd);
  return { kind: 'EXTRACT', part, layer: part, bytes: pagesBytes(pages), pages: pages.length, cmd };
}

/** Apply one optional item against the shared state; returns the skip reason or null when admitted. */
function admit(item, state, cap, groupLeft) {
  if (item.bytes > cap) return 'CAP';
  if (item.cost > state.slots) return 'MAXLOAD';
  if (item.bytes > state.left || item.bytes > groupLeft) return 'BUDGET';
  return null;
}

/** Build the plan; returns the rendered text (all pages joined) and its parts for tests. */
export function buildPlan(root, mode = 'default', { rootArg = null, argsIgnored = false } = {}) {
  const full = mode === 'full';
  const budget = full ? FULL_BUDGET : DEFAULT_BUDGET;
  const cap = full ? FULL_PER_FILE_CAP : PER_FILE_CAP;
  const missing = [];
  const errors = [];
  const warns = [];
  const guard = (what, fn, fallback) => { try { return fn(); } catch (e) { errors.push(`ERROR\t${what}\t${e.message}`); return fallback; } };

  // --- mandatory: frame ---
  const frame = [];
  const index = readText(root, '.agents/memory/index.md');
  if (index) frame.push({ kind: 'LOAD', path: '.agents/memory/index.md', bytes: index.size, layer: 'frame' });
  else missing.push('MISSING\tmemory index\t.agents/memory/index.md absent — /setup:start');
  const up = readText(root, '.agents/memory/user-profile.md');
  if (up) frame.push({ kind: 'LOAD', path: '.agents/memory/user-profile.md', bytes: up.size, layer: 'frame' });
  else missing.push('MISSING\tuser-profile\tper-developer, optional');
  const brief = readText(root, '.agents/memory/project-brief.md');
  const prd = readText(root, 'docs/PRD.md');
  let prdHeadLoaded = false;
  if (brief && isFilled(brief.text)) {
    frame.push({ kind: 'LOAD', path: '.agents/memory/project-brief.md', bytes: brief.size, layer: 'frame' });
  } else {
    missing.push(`MISSING\tbrief\t${brief ? 'project-brief.md is empty' : 'project-brief.md absent'} — /maintain:refresh-brief`);
    if (prd) {
      const head = prd.text.split('\n').slice(0, PRD_HEAD_LINES);
      const headBytes = bytes(head.join('\n')) + (prd.text.split('\n').length > PRD_HEAD_LINES ? 1 : 0);
      frame.push({ kind: 'LOAD', path: 'docs/PRD.md', bytes: headBytes, limit: PRD_HEAD_LINES, layer: 'frame' });
      prdHeadLoaded = true;
      warns.push(`WARN\t⚠️ project-brief.md is empty — reading the first ${PRD_HEAD_LINES} lines of docs/PRD.md; run /maintain:refresh-brief for faster primes`);
    }
  }
  const capName = full ? 'FULL_PER_FILE_CAP' : 'PER_FILE_CAP';
  for (const f of frame) {
    if (!f.limit && f.bytes > cap) warns.push(`WARN\t⚠️ mandatory layer frame: ${f.path} is ${kb(f.bytes)} KB — over ${capName}`);
  }
  if (!prd) missing.push('MISSING\tprd\tdocs/PRD.md absent — /discover');
  const disc = readText(root, 'docs/discovery.md');
  if (!disc) missing.push('MISSING\tdiscovery\tdocs/discovery.md absent — /discover');
  const arch = readText(root, 'docs/architecture.md');
  if (!arch) missing.push('MISSING\tarchitecture\tdocs/architecture.md absent — /architect');
  const decisions = readText(root, '.agents/memory/decisions.md');
  if (!decisions) missing.push('MISSING\tdecisions\t.agents/memory/decisions.md absent');
  const backlog = readText(root, '.agents/backlog.md');
  if (!backlog) missing.push('MISSING\tbacklog\t.agents/backlog.md absent — /setup:create-backlog');
  const cr = guard('code roots', () => codeRoots(root), { roots: [], errors: [], profileMissing: false });
  if (cr.profileMissing) missing.push('MISSING\tprofile\t.claude/project-profile.json absent — /setup:start');
  errors.push(...cr.errors);
  if (!BC) {
    const dependent = [[prd, 'register'], [prd, 'changelog'], [arch, 'architecture'], [decisions, 'decisions'], [backlog, 'backlog'],
      [cr.roots.length, 'codemap']];
    for (const [present, layer] of dependent) if (present) errors.push(bcMissing(layer).trimEnd());
  }

  const staticMandatory = [...frame];
  for (const [present, part] of [[prd, 'register'], [prd, 'changelog'], [disc, 'discovery'], [arch, 'architecture']]) {
    if (present) staticMandatory.push(guard(part, () => measureExtract(root, part, {}, rootArg), null));
  }
  const decisionSkip = [];
  if (decisions) {
    if (full && decisions.size <= FULL_PER_FILE_CAP) {
      staticMandatory.push({ kind: 'LOAD', path: '.agents/memory/decisions.md', bytes: decisions.size, layer: 'decisions' });
    } else {
      staticMandatory.push(guard('decisions', () => measureExtract(root, 'decisions', {}, rootArg), null));
      if (full) decisionSkip.push({ reason: 'CAP', path: '.agents/memory/decisions.md', bytes: decisions.size, files: 1, layer: 'decisions' });
    }
  }
  const mandatoryWith = (summary) => {
    const items = staticMandatory.filter(Boolean);
    if (backlog) items.push(guard('backlog', () => measureExtract(root, 'backlog', { summary }, rootArg), null));
    return items.filter(Boolean);
  };

  // --- optional items, in priority order ---
  const optional = [];
  const backlogItem = backlog ? { kind: 'LOAD', path: '.agents/backlog.md', bytes: backlog.size, cost: 1, layer: 'backlog-file', group: 'main' } : null;
  if (backlogItem) optional.push(backlogItem);
  for (const r of cr.roots) {
    const rel = r.path === '.' ? '.agents/memory/architecture.md' : posix(path.join(r.path, '.agents', 'memory', 'architecture.md'));
    const a = readText(root, rel);
    if (a && isFilled(a.text)) {
      optional.push({ kind: 'LOAD', path: rel, bytes: a.size, cost: 1, layer: 'codemap', group: 'main' });
    }
  }
  if (cr.roots.some((r) => fs.existsSync(path.join(r.abs, 'docs', 'map', 'system.yaml')))) {
    const m = guard('codemap', () => measureExtract(root, 'codemap', { roots: cr.roots }, rootArg), null);
    if (m) optional.push({ ...m, cost: 0, group: 'main' });
  }
  const pend = guard('pending sources', () => pendingSources(root), { items: [], noPrd: false });
  const pendingSet = new Set(pend.items.filter((i) => i.pending).map((i) => i.path));
  const fam = guard('note families', () => noteFamilies(root), { families: [], errors: [] });
  errors.push(...fam.errors);
  const metas = fam.families.map((f) => guard('note metadata', () => effectiveMeta(root, f), { meta: { Coverage: '', Source: '' }, errors: [] }));
  for (const m of metas) errors.push(...m.errors);
  const pendingUnits = [];
  for (const f of fam.families) {
    if (f.members.some((p) => pendingSet.has(p))) {
      pendingUnits.push({ kind: 'FAMILY', family: f, path: f.orig, bytes: f.size, cost: f.members.length, layer: 'pending', group: 'pending' });
    }
  }
  if (disc && pendingSet.has('docs/discovery.md')) pendingUnits.push({ kind: 'LOAD', path: 'docs/discovery.md', bytes: disc.size, cost: 1, layer: 'pending', group: 'pending' });
  pendingUnits.sort((a, b) => a.bytes - b.bytes);
  optional.push(...pendingUnits);
  const specList = guard('specs', () => specRows(root), { rows: [], specs: [] });
  if (full) {
    const pendSpecs = pend.items.filter((i) => i.kind === 'spec' && i.pending).sort((a, b) => a.size - b.size);
    const taken = new Set(pendSpecs.map((s) => s.path));
    for (const s of pendSpecs) optional.push({ kind: 'LOAD', path: s.path, bytes: s.size, cost: 1, layer: 'specs', group: 'main' });
    for (const p of specList.specs) {
      if (taken.has(p)) continue;
      optional.push({ kind: 'LOAD', path: p, bytes: readText(root, p)?.size ?? 0, cost: 1, layer: 'specs', group: 'main' });
    }
  }

  // --- selection ---
  const select = (mandatory, excluded) => {
    const mandBytes = mandatory.reduce((s, i) => s + i.bytes, 0);
    const mandLoads = mandatory.filter((i) => i.kind === 'LOAD').length;
    const state = { left: Math.max(0, budget - mandBytes), slots: Math.max(0, MAXLOAD - mandLoads) };
    let pendingLeft = null;
    const chosen = [];
    const skipped = [];
    for (const item of optional) {
      if (excluded.has(item)) { skipped.push({ item, reason: excluded.get(item) }); continue; }
      let groupLeft = Infinity;
      if (item.group === 'pending') {
        if (pendingLeft === null) pendingLeft = full ? state.left : Math.min(PENDING_BUDGET, state.left);
        groupLeft = pendingLeft;
      }
      const reason = admit(item, state, cap, groupLeft);
      if (reason) { skipped.push({ item, reason }); continue; }
      chosen.push(item);
      state.left -= item.bytes;
      state.slots -= item.cost;
      if (item.group === 'pending') pendingLeft -= item.bytes;
    }
    return { chosen, skipped, mandBytes };
  };

  const excluded = new Map();
  let backlogLoaded = Boolean(backlog) && backlog.size <= cap;
  let mandatory = mandatoryWith(!backlogLoaded);
  let sel = select(mandatory, excluded);
  if (backlogItem && backlogLoaded && !sel.chosen.includes(backlogItem)) {
    // The backlog did not make it: its extract now carries the Epic map, measured again.
    excluded.set(backlogItem, sel.skipped.find((s) => s.item === backlogItem)?.reason ?? 'BUDGET');
    backlogLoaded = false;
    mandatory = mandatoryWith(true);
    sel = select(mandatory, excluded);
  }

  // --- reconcile against the rendered plan ---
  const listings = guard('listings', () => [
    ...specList.rows,
    ...(pend.noPrd ? ['PENDING_NOTE\tno PRD change log — every source is pending'] : []),
    ...pend.items.filter((i) => i.pending).map((i) => `PENDING\t${i.kind}\t${i.size}\t${i.path}${i.changed ? `\tchanged since ${i.changed}` : ''}`),
    ...noteRows(root, fam.families),
    ...guard('raw sources', () => rawSources(root, metas), []).map((r) => `RAW\t${r.size}\t./${r.path}`),
    ...planRows(root),
    ...listMd(root, '.agents/memory/domain').map((p) => `DOMAIN\t${p}`),
    ...guard('jira workspace', () => jiraRows(root), []),
    ...(cr.roots.length
      ? cr.roots.map((r) => `CODE_ROOT\t${r.name}\t${r.path}\t${guard(`code root ${r.name}`, () => codeRootState(r.abs), 'unreadable')}`)
      : ['NO_CODE_ROOT\tno code root — greenfield or code elsewhere']),
  ], []);

  const render = (mand, chosen, skipped, total, pages, extraWarns) => {
    const rowOf = (i) => {
      if (i.kind === 'EXTRACT') return [`EXTRACT\t${i.bytes}\t${i.part}\tpages=${i.pages}\tlayer=${i.layer}\tcmd=${i.cmd}`];
      if (i.kind === 'FAMILY') {
        return i.family.members.map((p) => `LOAD\t${readText(root, p)?.size ?? 0}\t${p}\tfamily=${i.family.orig}\tlayer=${i.layer}`);
      }
      return [`LOAD\t${i.bytes}\t${i.path}${i.limit ? `\tlimit=${i.limit}` : ''}\tlayer=${i.layer}`];
    };
    const skips = [...decisionSkip.map((d) => ({ reason: d.reason, label: d.path, bytes: d.bytes, files: d.files, layer: d.layer })),
      ...skipped.map(({ item, reason }) => ({
        reason, label: item.kind === 'FAMILY' ? `family:${item.family.orig}` : item.kind === 'EXTRACT' ? `extract ${item.part}` : item.path,
        bytes: item.bytes, files: Math.max(1, item.cost), layer: item.layer,
      }))];
    const counters = { CAP: [0, 0], MAXLOAD: [0, 0], BUDGET: [0, 0] };
    for (const s of skips) { counters[s.reason][0] += s.files; counters[s.reason][1] += s.bytes; }
    const layers = new Map();
    for (const i of mand) layers.set(i.layer, { b: (layers.get(i.layer)?.b ?? 0) + i.bytes, t: 'mandatory' });
    for (const i of chosen) layers.set(i.layer, { b: (layers.get(i.layer)?.b ?? 0) + i.bytes, t: 'optional' });
    const skipWarns = [];
    if (counters.CAP[0]) skipWarns.push(`WARN\t⚠️ ${counters.CAP[0]} file(s) / ${counters.CAP[1]} bytes skipped — larger than the per-file cap (${cap}); read on demand`);
    if (counters.MAXLOAD[0]) skipWarns.push(`WARN\t⚠️ ${counters.MAXLOAD[0]} file(s) / ${counters.MAXLOAD[1]} bytes skipped — MAXLOAD (${MAXLOAD}) reached; a file-count limit, not a byte limit`);
    if (counters.BUDGET[0]) skipWarns.push(`WARN\t⚠️ ${counters.BUDGET[0]} file(s) / ${counters.BUDGET[1]} bytes skipped — budget ${budget} exhausted; read on demand${full ? '' : ' or run /prime-ba full'}`);
    const lines = [
      `PRIME_BA\tmode=${mode}\tbudget=${budget}\tpages=${pages}`,
      `CONST\t${Object.entries(CONSTANTS).map(([k, v]) => `${k}=${v}`).join(' ')}`,
      ...(argsIgnored ? ['ARGS_IGNORED\t/prime-ba takes no topic — the command that works on the topic loads it'] : []),
      ...mand.flatMap(rowOf),
      ...chosen.flatMap(rowOf),
      ...(prd ? [`INDEX\t${prd.size}\tdocs/PRD.md\tregister index + newest ${CHANGELOG_NEWEST} D-n — narrative not loaded`
        + `${prdHeadLoaded ? ` (first ${PRD_HEAD_LINES} lines loaded as the brief fallback)` : ''}`] : []),
      ...skips.slice(0, MAXSKIP).map((s) => `SKIP_${s.reason}\t${s.bytes}\t${s.label}\tlayer=${s.layer}`),
      ...(skips.length > MAXSKIP ? [`SKIP_MORE\t${skips.length - MAXSKIP} more skip rows (counters below are complete)`] : []),
      ...missing,
      ...errors,
      ...[...layers].map(([l, v]) => `LAYER\t${l}\t${v.b}\t${v.t}`),
      ...Object.entries(counters).map(([r, [n, b]]) => `SKIPPED_${r}\t${n} files / ${b} bytes`),
      `TOTAL\t${total} bytes ≈ ${Math.round(total / 4096)}k tokens / budget ${budget} (${mode})`,
      ...warns, ...extraWarns, ...skipWarns,
      ...listings,
    ];
    return `${lines.join('\n')}\n`;
  };

  const mandatoryWarns = (mand) => {
    const out = [];
    let cum = 0;
    let over = false;
    for (const layer of MANDATORY_ORDER) {
      const b = mand.filter((i) => i.layer === layer).reduce((s, i) => s + i.bytes, 0);
      if (!mand.some((i) => i.layer === layer)) continue;
      cum += b;
      if (cum > budget) over = true;
      if (over) {
        const cmd = layer === 'decisions' || layer === 'frame' ? '; /maintain:cleanup-workflow' : '';
        out.push(`WARN\t⚠️ mandatory layer ${layer} is ${kb(b)} KB — over budget ${budget / 1024} KB${cmd}`);
      }
    }
    return out;
  };

  const cmdline = shellQuote(['plan', ...(full ? ['--mode', 'full'] : []), ...(rootArg ? ['--root', rootArg] : [])]);
  /** Render to a fixed point of page count and TOTAL. */
  const finish = (mand, chosen, skipped, extraWarns) => {
    const content = mand.reduce((s, i) => s + i.bytes, 0) + chosen.reduce((s, i) => s + i.bytes, 0);
    let pages = 1;
    let total = content;
    let text = '';
    let paged = [];
    for (let k = 0; k < 6; k += 1) {
      text = render(mand, chosen, skipped, total, pages, extraWarns);
      paged = paginate(text, PAGE_SIZE, cmdline);
      const nextTotal = content + pagesBytes(paged) + TOTAL_PAD;
      if (paged.length === pages && nextTotal <= total + TOTAL_PAD) break;
      pages = paged.length;
      total = nextTotal;
    }
    return { text, pages: paged, total };
  };

  let chosen = [...sel.chosen];
  let skipped = [...sel.skipped];
  let result;
  for (let guardN = 0; guardN <= optional.length + 1; guardN += 1) {
    const mw = mandatoryWarns(mandatory);
    result = finish(mandatory, chosen, skipped, mw);
    if (result.total <= budget || !chosen.length) break;
    const dropped = chosen.pop();
    skipped.push({ item: dropped, reason: 'BUDGET' });
    if (dropped === backlogItem) mandatory = mandatoryWith(true);
  }
  if (result.total > budget && !chosen.length) {
    const mw = mandatoryWarns(mandatory);
    const overWarn = () => `WARN\t⚠️ mandatory content and the plan listing alone are ${kb(result.total)} KB — over budget ${budget / 1024} KB`;
    // Fixed-point the final warning in too (its bytes count toward the plan).
    for (let k = 0; k < 2; k += 1) result = finish(mandatory, chosen, skipped, [...mw, overWarn()]);
  }
  return { ...result, cmdline, mandatory, chosen, skipped, budget };
}

function noteRows(root, families) {
  const originals = families.map((f) => f.orig).sort().reverse();
  const rows = [`NOTES\t${families.length}`];
  for (const p of originals.slice(0, 3)) {
    const title = ((readText(root, p)?.text ?? '').split('\n').find((l) => l.startsWith('# ')) ?? '# —').slice(2).trim();
    rows.push(`NOTE\t${title}\t${p}`);
  }
  for (const f of families) if (f.corrections.length) rows.push(`FAMILY\t${f.orig}\t← ${f.corrections.map((c) => c.path).join(', ')}`);
  return rows;
}

function planRows(root) {
  const active = listMd(root, '.agents/plans/active').map((p) => path.basename(p));
  const done = byMtimeDesc(root, listMd(root, '.agents/plans/done')).map((p) => path.basename(p));
  return [`PLANS_ACTIVE\t${active.length}\t${active.join(', ') || '—'}`, `PLANS_DONE\t${done.length}\t${done.slice(0, 5).join(', ') || '—'}`];
}

// ---------------------------------------------------------------------------------------------
// CLI
// ---------------------------------------------------------------------------------------------

const USAGE = `usage: ${SCRIPT_CMD} plan [--mode default|full] [--root <dir>] [--page <n>]
       ${SCRIPT_CMD} extract <${PARTS.join('|')}> [--summary] [--root <dir>] [--page <n>]`;

function usage(msg) {
  process.stderr.write(`prime-ba: ${msg}\n${USAGE}\n`);
  return 2;
}

function printPage(pages, n) {
  if (n > pages.length) process.stdout.write(`no page ${n} (last: ${pages.length})\n`);
  else process.stdout.write(pages[n - 1]);
}

export async function main(argv = process.argv.slice(2)) {
  await loadChecker();
  const [sub, ...rest] = argv;
  if (sub !== 'plan' && sub !== 'extract') return usage(sub ? `unknown subcommand "${sub}"` : 'missing subcommand');
  let mode = 'default';
  let rootArg = null;
  let page = 1;
  let summary = false;
  const positional = [];
  for (let i = 0; i < rest.length; i += 1) {
    const a = rest[i];
    if (a === '--mode' || a === '--root' || a === '--page') {
      const v = rest[i + 1];
      if (v === undefined) return usage(`${a} needs a value`);
      i += 1;
      if (a === '--mode') { if (!['default', 'full'].includes(v)) return usage(`--mode must be default or full, got "${v}"`); mode = v; }
      if (a === '--root') rootArg = path.resolve(v);
      if (a === '--page') { if (!/^[1-9]\d*$/.test(v)) return usage(`--page must be a positive integer, got "${v}"`); page = Number(v); }
    } else if (a === '--summary') summary = true;
    else if (a.startsWith('--')) return usage(`unknown flag "${a}"`);
    else positional.push(a);
  }
  const root = rootArg ?? process.cwd();
  if (sub === 'plan') {
    if (summary) return usage('--summary applies to extract backlog only');
    const plan = buildPlan(root, mode, { rootArg, argsIgnored: positional.length > 0 });
    printPage(plan.pages, page);
    return 0;
  }
  const part = positional[0];
  if (!PARTS.includes(part ?? '')) return usage(part ? `unknown part "${part}"` : 'extract needs a part');
  if (positional.length > 1) return usage(`unexpected argument "${positional[1]}"`);
  if (summary && part !== 'backlog') return usage('--summary applies to extract backlog only');
  let text;
  try {
    const roots = part === 'codemap' ? codeRoots(root).roots : [];
    text = renderExtract(root, part, { summary, roots });
  } catch (e) { text = `ERROR\t${part}\t${e.message}\n`; }
  printPage(paginate(text, PAGE_SIZE, extractCmd(part, summary, rootArg)), page);
  return 0;
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main().then((code) => { process.exitCode = code; }, (err) => {
    process.stderr.write(`prime-ba: ${err.message}\n`);
    process.exitCode = 1;
  });
}
