// Validator + generator for `.agents/backlog.md` (Epics + Tasks), its Epic files
// (`.agents/backlog/E<n>-<slug>.md` — per-Task Summary / Goal / scope and acceptance criteria) and
// `docs/map/system.yaml`. Owns every check a model must not self-grade: ids, DAG, sizes, trace
// coverage, system-tree integrity, Scope order, quality Tasks, the `## Outside the dev backlog` rows, where each
// criterion lives, and the derived story map + Epic-file meta lines it writes back (`--write`).
// Scheduling lives in `delivery-plan.mjs`, not here. Also warns on a Task delivered by a done plan
// whose Status / Ref was never written back. `--candidate <dir>` validates `<dir>/PRD.md` +
// `<dir>/backlog.md` + `<dir>/backlog/E*.md`; `--fingerprint` prints the hash of the backlog set.
// Node builtins only — ships to every downstream (umbrella D4).
//
//   node .claude/lib/backlog-check.mjs [--root <dir>] [--prd <path>] [--write] [--json] [--system-only] [--candidate <dir>] [--fingerprint]
//   exit 0 = no errors · 1 = errors · 2 = usage / missing backlog or system.yaml

import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { parseYaml } from './yaml-subset.mjs';

export const SIZE_POINTS = { M: 4, H: 8, XH: 16 };
const TASK_TYPES = new Set(['story', 'tech']);
const TASK_STATUSES = new Set(['TODO', 'WIP', 'DONE', 'BLOCKED']);
const NODE_KINDS = new Set(['trunk', 'branch', 'twig', 'leaf', 'root']);
const SUBDOMAINS = new Set(['core', 'supporting', 'generic']);
const CRITICALITIES = new Set(['critical', 'normal']);
const LINK_KINDS = new Set(['calls', 'events', 'acl', 'ohs', 'customer-supplier', 'conformist', 'realizedBy']);
const FORBIDDEN_SYSTEM_KEYS = new Set(['status', 'progress', 'done', 'completed']);

const TASK_ID = /^E\d+-\d+$/;
const JIRA_KEY = /^[A-Z]+-\d+/;
const EPIC_ID = /^E\d+$/;
const AC_ID = /^E\d+-\d+\.AC\d+$/;
export const SCOPES = ['CORE', 'MUST', 'COULD'];
export const NO_CORE_WARNING = 'no CORE Task — the delivery plan starts every session on day 0; mark the Tasks that must exist before parallel work';
// Quality Tasks — .claude/skills/backlog/quality-tasks.md (keep the two tables in step).
// `planned: false` marks a reminder-only marker: added by /check-backlog when an upkeep item is due, never required on a backlog, never counted.
export const QUALITY_MARKERS = {
  'audit:security': { kind: 'closing', command: '/audit-security', size: 'H', conditional: false, planned: true },
  'audit:seo-geo': { kind: 'closing', command: '/seo-geo-audit', size: 'H', conditional: true, planned: true },
  'audit:wcag': { kind: 'closing', command: '/wcag-audit', size: 'H', conditional: true, planned: true },
  'upkeep:architecture-review': { kind: 'recurring', command: '/architecture-review', size: 'M', conditional: false, planned: true },
  'upkeep:cleanup-workflow': { kind: 'recurring', command: '/maintain:cleanup-workflow', size: 'M', conditional: false, planned: true },
  'upkeep:refresh-brief': { kind: 'reminder', command: '/maintain:refresh-brief', size: 'M', conditional: false, planned: false },
};
export const QUALITY_CADENCE_POINTS = 160;
export const QUALITY_MIN_OCCURRENCES = 2;
const QUALITY_PREFIX = /^\[((?:audit|upkeep):[a-z0-9-]+)\]/;
const QUALITY_TOKEN = /\[((?:audit|upkeep):[a-z0-9-]+)\]/g;
const OCCURRENCE = /[—-]\s*occurrence\s+(\d+)\b/i;
const OUT_OF_SCOPE_HEADING = /^##\s+Consciously out of scope\b/i;
/** `{ marker, known, kind?, command?, size?, conditional?, occurrence }` for a Task cell that begins with a quality marker, else null. */
export function qualityMarker(title) {
  const m = QUALITY_PREFIX.exec(title ?? '');
  if (!m) return null;
  const occ = OCCURRENCE.exec(title);
  return { marker: m[1], known: Object.hasOwn(QUALITY_MARKERS, m[1]), ...(QUALITY_MARKERS[m[1]] ?? {}), occurrence: occ ? Number(occ[1]) : null };
}
const OUTSIDE_ID = /^X-\d+$/;
export const OUTSIDE_HEADING = /^##\s+Outside the dev backlog\b/;
export const PRE_SCOPE_MESSAGE = 'pre-Scope backlog (Wave / Slice columns) — run: node .claude/lib/backlog-migrate.mjs --write';
const INVENTORY_ID = /^(G|R|NFR|BR|A|Q|AD|FL|D)-\d+(\.A\d+)?$/;
const REGISTER_ID = /^(G|R|NFR)-\d+$/;
const BOLD_LIST_ID = /^\s*[-*]\s+\*\*([A-Za-z]+-\d+(?:\.A\d+)?)\*\*/;
const FLOW_HEADING = /^###\s+(FL-\d+)\b(.*)$/;
const DECISION_HEADING = /^###\s+(D-\d+)\s+[—-]/;
// A state marker counts only right after the `**ID** — ` prefix, so the same words inside a client
// `Quote:` stay content.
const STATE_MARKER = /^\s*[-*]\s+\*\*[A-Za-z]+-\d+(?:\.A\d+)?\*\*\s*[—-]\s*\((withdrawn|superseded by ([A-Z]+-\d+))(?:\s+per\s+(D-\d+))?\)/i;
const STATUS_SUPERSEDED = /^superseded by\s+([A-Z]+-\d+)(?:\s+per\s+(D-\d+))?$/i;
const STATUS_WITHDRAWN = /^withdrawn(?:\s+per\s+(D-\d+))?$/i;
const CHAIN_TOKEN = /^[a-z0-9]+(-[a-z0-9]+)*$/;
const SCOPE_REV = /\*\*Scope rev:\*\*\s*(v\d+\.\d+)/;
const PRD_CURRENT = /\*\*Current:\*\*\s*(v\d+\.\d+)/;
export const AC_SECTION_HEADING = /^##\s+Acceptance criteria\b/i;
export const AC_BLOCK_HEADING = /^###\s+(E\d+-\d+)\b/;
export const AC_DEFINITION = /^\s*[-*]\s+\*\*(E\d+-\d+\.AC[^*]*)\*\*/;
// Epic files (`.agents/backlog/E<n>-<slug>.md`): the one home of a Task's detail and criteria.
const DETAIL = /\*\*Detail:\*\*\s*(\S+)/;
const DETAILS = ['structure', 'full'];
const EPIC_FILE = /^(E\d+)-.+\.md$/;
const EPIC_HEADING = /^#\s+(E\d+)\b/;
const TASK_HEADING = /^##\s+(E\d+-\d+)\b(.*)$/;
const CRITERIA_HEADING = /^###\s+Acceptance criteria\b/i;
const DETAIL_LABELS = { summary: 'Summary', goal: 'Goal', inScope: 'In scope', outOfScope: 'Out of scope' };
const LABEL_LINE = new RegExp(`^\\*\\*(${Object.values(DETAIL_LABELS).join('|')}):\\*\\*\\s*(.*)$`);
const LABEL_KEY = Object.fromEntries(Object.entries(DETAIL_LABELS).map(([k, v]) => [v, k]));
// The shape of a generated meta line (`renderMeta`): anything else under a Task heading is content.
const META_LINE = /^> (Withdrawn · )?Size \S+ \(/;
export const EPIC_DIR = '.agents/backlog';
export const PRE_DETAIL_MESSAGE = 'acceptance criteria still in .agents/backlog.md — run: node .claude/lib/backlog-migrate.mjs --write';
// A PRD NFR row whose Requirement cell starts with this is a declared non-applicable characteristic.
const NFR_NOT_APPLICABLE = /^N\/A\b/;
const ARCHITECTURE_DRAFT = /^\*\*Status:\*\*\s*draft\b/im;

// ---------------------------------------------------------------------------------------------
// Markdown helpers
// ---------------------------------------------------------------------------------------------

export const splitCells = (line) => line.trim().replace(/^\|/, '').replace(/\|$/, '').split(/(?<!\\)\|/).map((c) => c.trim());
const isSeparator = (line) => /^\s*\|?\s*:?-{3,}/.test(line) && !/[^\s|:-]/.test(line);
export const cleanId = (cell) => (cell ?? '').replace(/[`*]/g, '').trim();
const isNone = (cell) => { const c = cleanId(cell); return c === '' || c === '—' || c === '-'; };
const listCell = (cell) => (isNone(cell) ? [] : cleanId(cell).split(',').map((s) => s.trim()).filter(Boolean));

const FENCE_OPEN = /^ {0,3}(`{3,}|~{3,})/;
const FENCE_CLOSE = /^ {0,3}(`{3,}|~{3,})\s*$/;
/**
 * A fenced-code tracker (CommonMark): fed one line at a time, returns true for a fence line or a
 * line inside a fence. A fence opens on ≥ 3 identical backticks or tildes after ≤ 3 spaces (a
 * backtick fence's info string holds no backtick) and closes only on the same character, at least as
 * many, and nothing but whitespace after. `scan.openedAt()` is the 1-based number (count of lines
 * fed) of the line that opened a still-open fence, else null.
 */
export function fenceScanner() {
  let open = null;
  let fed = 0;
  const scan = (line) => {
    fed += 1;
    if (open) {
      const c = FENCE_CLOSE.exec(line);
      if (c && c[1][0] === open.ch && c[1].length >= open.len) open = null;
      return true;
    }
    const o = FENCE_OPEN.exec(line);
    if (!o || (o[1][0] === '`' && line.slice(o[0].length).includes('`'))) return false;
    open = { ch: o[1][0], len: o[1].length, line: fed };
    return true;
  };
  scan.openedAt = () => open?.line ?? null;
  return scan;
}
/** Per line of `lines`: true when it is a fence line or inside a fenced code block. */
export const fenceMask = (lines) => { const scan = fenceScanner(); return lines.map((l) => scan(l)); };

/** Every pipe table in `md`: `{ header, rows }`, each row keyed by its header cell (plus `_line`). */
export function parseTables(md) {
  const lines = md.split(/\r?\n/);
  const tables = [];
  for (let i = 0; i + 1 < lines.length; i += 1) {
    if (!lines[i].trim().startsWith('|') || !isSeparator(lines[i + 1])) continue;
    const header = splitCells(lines[i]).map(cleanId);
    const rows = [];
    let j = i + 2;
    for (; j < lines.length && lines[j].trim().startsWith('|'); j += 1) {
      const cells = splitCells(lines[j]);
      const row = { _line: j + 1 };
      header.forEach((h, k) => { row[h] = cells[k] ?? ''; });
      rows.push(row);
    }
    tables.push({ header, rows, line: i + 1 });
    i = j - 1;
  }
  return tables;
}

const findTable = (tables, ...needed) => tables.find((t) => needed.every((h) => t.header.includes(h)));
/** The Task table is the one carrying these key columns — whatever else its header holds. */
export const findTaskTable = (tables) => findTable(tables, 'ID', 'Epic', 'Size', 'Pts');

// Every column the checker reads. A table located by its key columns must carry all of them — a
// renamed `Depends on` would otherwise silently turn every dependency into an empty list.
const EPIC_COLUMNS = ['Epic', 'Title', 'Outcome', 'Key assumption', 'Pts', 'Depends on', 'Jira'];
const TASK_COLUMNS = ['ID', 'Epic', 'Task', 'Type', 'Size', 'Pts', 'Depends on', 'Scope', 'Node', 'Traces', 'Status', 'Jira', 'Ref'];
export const OUTSIDE_COLUMNS = ['ID', 'Owner', 'Item', 'Needed by', 'Starts after', 'Traces', 'Notes'];
export const headerLine = (cols) => `| ${cols.join(' | ')} |`;

// ---------------------------------------------------------------------------------------------
// Backlog
// ---------------------------------------------------------------------------------------------

/**
 * Rows of `## Outside the dev backlog` (`Needed by` = the Tasks that need the item, `Starts after` =
 * the Tasks the item waits for), found by the section heading — never by columns. No heading →
 * `[]` (the section is optional); a heading whose first table lacks a column, or with no table
 * before the next `## ` heading, is a structural problem so a renamed column never reads as "no rows".
 */
function parseOutside(md, tables, requireTable) {
  const lines = md.split(/\r?\n/);
  const start = lines.findIndex((l) => OUTSIDE_HEADING.test(l));
  if (start === -1) return [];
  let stop = lines.findIndex((l, i) => i > start && /^##\s/.test(l));
  if (stop === -1) stop = lines.length;
  // `line` is 1-based: the heading sits on line start + 1, the next heading on stop + 1.
  const table = tables.find((t) => t.line > start + 1 && t.line < stop + 1);
  const found = requireTable('Outside the dev backlog table', table, OUTSIDE_COLUMNS);
  return (found?.rows ?? []).map((r) => ({
    id: cleanId(r.ID), owner: cleanId(r.Owner), item: cleanId(r.Item),
    neededBy: listCell(r['Needed by']), startsAfter: listCell(r['Starts after']), traces: listCell(r.Traces), line: r._line,
  // Only a wholly empty row is dropped: a filled row with a blank ID must fail the id check, not vanish.
  })).filter((x) => x.id !== '' || x.owner !== '' || x.item !== '' || x.neededBy.length || x.startsAfter.length || x.traces.length);
}

const acText = (line) => line.replace(AC_DEFINITION, '').replace(/^\s*[—-]\s*/, '').trim();
const EMPTY_DETAIL = () => ({ detail: null, details: new Map(), files: [] });

/** The id slug of an Epic file name (`E5-checkout-payment.md`): lowercase ASCII, ≤ 40 chars at a `-` boundary. */
export function epicSlug(title) {
  const slug = String(title ?? '').toLowerCase().replace(/ł/g, 'l').normalize('NFKD').replace(/[\u0300-\u036f]/g, '')
    .replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '');
  if (slug.length <= 40) return slug || 'epic';
  const cut = slug.slice(0, 41).lastIndexOf('-');
  return (cut > 0 ? slug.slice(0, cut) : slug.slice(0, 40)).replace(/-+$/, '') || 'epic';
}
export const epicFileName = (id, title) => `${id}-${epicSlug(title)}.md`;
/** The Epic id of an Epic file name (`E5-checkout.md` → `E5`), or null when the name is no Epic file. */
export const epicOfFile = (name) => EPIC_FILE.exec(name)?.[1] ?? null;

/**
 * One Epic file: its Task blocks (`## E<n>-<m> — …` up to the next `## `), their label paragraphs
 * and every criterion definition with where it sits — `block` (the open Task heading, or null) and
 * `inCriteria` (under that block's `### Acceptance criteria`; only a level-3 heading changes it, a
 * `####` sub-heading keeps it), so the check can reject one written anywhere else. A fenced code
 * block is text: nothing inside it is a heading, label or criterion. Structural faults are
 * `problems`, never skipped.
 */
function parseEpicFile({ name, text }) {
  const epic = epicOfFile(name);
  const problems = [];
  const tasks = [];
  const acs = [];
  const lines = text.split(/\r?\n/);
  const first = lines.findIndex((l) => l.trim() !== '');
  const head = first === -1 ? null : EPIC_HEADING.exec(lines[first]);
  if (!epic || !head || head[1] !== epic) problems.push(`Epic file ${name}: first line must be \`# ${epic ?? 'E<n>'} — <title>\``);
  let block = null;
  let inCriteria = false;
  let label = null;
  let last = null;
  const scan = fenceScanner();
  // An indented continuation line belongs to the criterion above it.
  const continues = (line) => last && /^\s+\S/.test(line);
  lines.forEach((line, idx) => {
    const inFence = scan(line);
    if (idx === first && /^#\s/.test(line)) return;
    if (inFence) {
      if (continues(line)) last.text = `${last.text} ${line.trim()}`;
      else { last = null; label = null; }
      return;
    }
    const t = TASK_HEADING.exec(line);
    if (t) {
      if (tasks.some((x) => x.id === t[1])) problems.push(`Epic file ${name}: duplicate Task heading ${t[1]} (line ${idx + 1})`);
      block = { id: t[1], title: t[2].replace(/^\s*[—-]\s*/, '').trim(), summary: '', goal: '', inScope: '', outOfScope: '' };
      tasks.push(block);
      inCriteria = false; label = null; last = null;
      return;
    }
    if (/^#{1,2}\s/.test(line)) {
      problems.push(`Epic file ${name} line ${idx + 1}: unexpected heading \`${line.trim()}\` — only \`## <Task id> — …\` blocks`);
      block = null; inCriteria = false; label = null; last = null;
      return;
    }
    if (/^###\s/.test(line)) { inCriteria = block !== null && CRITERIA_HEADING.test(line); label = null; last = null; return; }
    // A deeper sub-heading groups criteria: it ends the one above, the block and its section stay.
    if (/^#{4,}\s/.test(line)) { label = null; last = null; return; }
    const d = AC_DEFINITION.exec(line);
    if (d) {
      last = { id: d[1].trim(), task: d[1].split('.')[0], block: block?.id ?? null, file: name, inCriteria, line: idx + 1, text: acText(line) };
      acs.push(last); label = null;
      return;
    }
    if (continues(line) && !/^\s*[-*]\s+\*\*/.test(line)) { last.text = `${last.text} ${line.trim()}`; return; }
    last = null;
    const l = LABEL_LINE.exec(line);
    if (l && block) { label = LABEL_KEY[l[1]]; block[label] = l[2].trim(); return; }
    // A label paragraph runs on over non-blank lines that are no label, heading, list item or `>` line.
    if (label && line.trim() !== '' && !/^\s*([-*]|\d+\.)\s/.test(line) && !/^>/.test(line)) { block[label] = `${block[label]} ${line.trim()}`.trim(); return; }
    label = null;
  });
  if (scan.openedAt() !== null) problems.push(`Epic file ${name}: unclosed code fence opened on line ${scan.openedAt()}`);
  return { name, epic, tasks, acs, problems };
}

/** Parse `.agents/backlog.md` (+ the Epic-file texts) into epics, tasks, criteria and header fields. Pure. */
export function parseBacklog(md, { epicFiles = [] } = {}) {
  const tables = parseTables(md);
  const hasSize = tables.some((t) => t.header.includes('Size'));
  if (/^##\s+Work packages/m.test(md) && !hasSize) return { legacy: true, preDetail: false, epics: [], tasks: [], acs: [], outside: [], problems: [], ...EMPTY_DETAIL() };
  // A Task table still on Wave / Slice (and without Scope) is migrated, never half-checked.
  const keyed = findTaskTable(tables);
  if (keyed && !keyed.header.includes('Scope') && (keyed.header.includes('Wave') || keyed.header.includes('Slice'))) {
    return { legacy: false, preScope: true, preDetail: false, epics: [], tasks: [], acs: [], outside: [], problems: [], ...EMPTY_DETAIL() };
  }
  // Criteria still in a `## Acceptance criteria` section of backlog.md: migrated, never half-checked.
  const mdLines = md.split(/\r?\n/);
  const fenced = fenceMask(mdLines);
  if (mdLines.some((l, i) => !fenced[i] && AC_SECTION_HEADING.test(l))) {
    return { legacy: false, preScope: false, preDetail: true, epics: [], tasks: [], acs: [], outside: [], problems: [], ...EMPTY_DETAIL(), raw: md };
  }

  const problems = [];
  // Locate by key columns, then demand the full header; a table missing a column is dropped so no
  // row is read through a wrong key.
  const requireTable = (label, table, cols) => {
    if (!table) { problems.push(`${label} not found (header \`${headerLine(cols)}\`)`); return null; }
    const missing = cols.filter((c) => !table.header.includes(c));
    if (!missing.length) return table;
    problems.push(`${label} (line ${table.line}): missing column(s) ${missing.map((c) => `\`${c}\``).join(', ')} — expected header \`${headerLine(cols)}\``);
    return null;
  };
  const epicTable = requireTable('Epic map table', findTable(tables, 'Epic', 'Title', 'Pts'), EPIC_COLUMNS);
  const taskTable = requireTable('Task table', keyed, TASK_COLUMNS);

  const epics = (epicTable?.rows ?? []).map((r) => ({
    id: cleanId(r.Epic), title: cleanId(r.Title), pts: Number(cleanId(r.Pts)), deps: listCell(r['Depends on']), line: r._line,
  })).filter((e) => e.id !== '');

  // A withdrawn Task keeps its row (ids are append-only) but is no longer planned work.
  const tasks = (taskTable?.rows ?? []).map((r) => ({
    id: cleanId(r.ID), epic: cleanId(r.Epic), title: cleanId(r.Task), type: cleanId(r.Type), size: cleanId(r.Size),
    pts: Number(cleanId(r.Pts)), deps: listCell(r['Depends on']), scope: cleanId(r.Scope),
    node: isNone(r.Node) ? null : cleanId(r.Node), traces: listCell(r.Traces), status: cleanId(r.Status),
    jira: isNone(r.Jira) ? null : cleanId(r.Jira), ref: isNone(r.Ref) ? null : cleanId(r.Ref),
    // Optional columns: a table without them reads as `—` everywhere.
    relates: listCell(r.Relates), chain: isNone(r.Chain) ? null : cleanId(r.Chain),
    withdrawn: /\(withdrawn\)/i.test(r.Task ?? ''), line: r._line,
  })).filter((t) => t.id !== '');

  // /qa-verify reads criteria only from an Epic file's `## <Task id>` → `### Acceptance criteria`.
  const parsedFiles = epicFiles.map(parseEpicFile);
  const acs = parsedFiles.flatMap((f) => f.acs);
  const epicOf = new Map(tasks.map((t) => [t.id, t.epic]));
  const details = new Map();
  for (const f of parsedFiles) {
    problems.push(...f.problems);
    for (const t of f.tasks) {
      // A Task with a block in its own Epic's file and another elsewhere resolves to its own file.
      const own = f.epic === (epicOf.get(t.id) ?? t.id.split('-')[0]);
      if (details.has(t.id) && !own) continue;
      details.set(t.id, { file: f.name, summary: t.summary, goal: t.goal, inScope: t.inScope, outOfScope: t.outOfScope });
    }
  }
  const files = parsedFiles.map((f, i) => ({ name: f.name, epic: f.epic, taskIds: f.tasks.map((t) => t.id), text: epicFiles[i].text }));

  const outside = parseOutside(md, tables, requireTable);
  // A criterion definition anywhere else in backlog.md (outside a fenced example) is misplaced.
  const strayAcs = mdLines.flatMap((l, i) => {
    const d = fenced[i] ? null : AC_DEFINITION.exec(l);
    return d ? [{ id: d[1].trim(), task: d[1].split('.')[0], line: i + 1 }] : [];
  });

  const lines = md.split(/\r?\n/);
  // Quality markers ruled out under `## Consciously out of scope` (up to the next `## ` heading).
  const ruledOut = [];
  const outStart = lines.findIndex((l, i) => !fenced[i] && OUT_OF_SCOPE_HEADING.test(l));
  if (outStart !== -1) {
    for (let i = outStart + 1; i < lines.length && !lines[i].startsWith('## '); i++) {
      for (const m of lines[i].matchAll(QUALITY_TOKEN)) ruledOut.push(m[1]);
    }
  }
  const firstSection = lines.findIndex((l) => l.startsWith('## '));
  const header = (firstSection === -1 ? lines : lines.slice(0, firstSection)).join('\n');
  const prd = /\*\*Source PRD:\*\*\s*`([^`]+)`/.exec(md);
  return {
    legacy: false, preScope: false, preDetail: false, epics, tasks, acs, strayAcs, outside, problems,
    detail: DETAIL.exec(header)?.[1] ?? null, details, files, ruledOut,
    sourcePrd: prd ? prd[1].trim() : null, scopeRev: SCOPE_REV.exec(md)?.[1] ?? null, raw: md,
  };
}

/**
 * `.agents/backlog.md` and its Epic files: `{ md, epicFiles: [{ name, text }] }`. Epic files are the
 * regular files in `epicDir` named `E<n>-….md` (so `delivery-plan.md` never is one), in id order; a
 * missing backlog is `md: null`, a missing directory no Epic files.
 */
export function readBacklogFiles(backlogPath, epicDir = path.join(path.dirname(backlogPath), 'backlog')) {
  const md = readIfExists(backlogPath);
  let epicFiles = [];
  if (fs.existsSync(epicDir) && fs.statSync(epicDir).isDirectory()) {
    epicFiles = fs.readdirSync(epicDir, { withFileTypes: true })
      .filter((d) => d.isFile() && EPIC_FILE.test(d.name)).map((d) => d.name).sort(byIdAsc)
      .map((name) => ({ name, text: fs.readFileSync(path.join(epicDir, name), 'utf8') }));
  }
  return { md, epicFiles };
}

/**
 * sha256 (12 hex) of the backlog set: `backlog.md` without its `**Last check:**` line, then every
 * Epic file in id order behind a `--- <name> ---` separator. With no Epic files it equals the old
 * backlog-only hash. The one fingerprint /check-backlog records and the delivery plan cites.
 */
export function backlogFingerprint(md, epicFiles = []) {
  const lines = (md ?? '').split('\n');
  if (lines[lines.length - 1] === '') lines.pop();
  const kept = lines.filter((l) => !l.startsWith('**Last check:**'));
  let text = kept.length ? `${kept.join('\n')}\n` : '';
  for (const f of [...epicFiles].sort((a, b) => byIdAsc(a.name, b.name))) text += `\n--- ${f.name} ---\n${f.text}`;
  return crypto.createHash('sha256').update(text).digest('hex').slice(0, 12);
}

// ---------------------------------------------------------------------------------------------
// Inventory (PRD + discovery + architecture ids, flows) and system.yaml
// ---------------------------------------------------------------------------------------------

export const readIfExists = (p) => (fs.existsSync(p) ? fs.readFileSync(p, 'utf8') : null);

/** Write through a temp file + rename, creating the directory: a reader never sees a half-written file. */
export function writeAtomic(file, text) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  const tmp = `${file}.tmp.${process.pid}`;
  fs.writeFileSync(tmp, text);
  fs.renameSync(tmp, file);
}

// Verbatim provenance (`Quote: "…"`, a quoted `Source` cell) is content: markers inside it are not state.
const unquoted = (text) => text.replace(/Quote:\s*"[^"]*"/g, '').replace(/·\s*"[^"]*"/g, '');

/** State of a definition line: the anchored marker, else the legacy bare `(withdrawn)` outside quoted text. */
function lineState(line) {
  const m = STATE_MARKER.exec(line);
  if (m) {
    if (m[2]) return { state: 'superseded', successor: m[2].toUpperCase(), ...(m[3] ? { decision: m[3] } : {}) };
    return { state: 'withdrawn', ...(m[3] ? { decision: m[3] } : {}) };
  }
  if (/\(withdrawn\)/i.test(unquoted(line))) return { state: 'withdrawn' };
  return { state: 'active' };
}

/** State of a table row. A `Status` column is authoritative; a malformed value on a register row is a problem. */
function rowState(table, row, id, problems) {
  if (!table.header.includes('Status')) {
    return /\(withdrawn\)/i.test(unquoted(Object.values(row).join(' '))) ? { state: 'withdrawn' } : { state: 'active' };
  }
  const status = cleanId(row.Status ?? '');
  const sup = STATUS_SUPERSEDED.exec(status);
  if (sup) return { state: 'superseded', successor: sup[1].toUpperCase(), ...(sup[2] ? { decision: sup[2] } : {}) };
  const wd = STATUS_WITHDRAWN.exec(status);
  if (wd) return { state: 'withdrawn', ...(wd[1] ? { decision: wd[1] } : {}) };
  if (!/^active$/i.test(status) && REGISTER_ID.test(id)) {
    problems.push(`${id}: malformed Status "${status}" (expected active | withdrawn [per D-n] | superseded by <id> [per D-n])`);
  }
  return { state: 'active' };
}

function collectIds(md, source, ids, problems) {
  const define = (id, state) => {
    if (ids.has(id)) return;
    ids.set(id, { source, ...state });
  };
  for (const line of md.split(/\r?\n/)) {
    const h = FLOW_HEADING.exec(line);
    if (h) define(h[1], lineState(line));
    const d = DECISION_HEADING.exec(line);
    if (d) define(d[1], { state: 'active' });
    const m = BOLD_LIST_ID.exec(line);
    if (m && INVENTORY_ID.test(m[1])) define(m[1], lineState(line));
  }
  for (const table of parseTables(md)) {
    for (const row of table.rows) {
      const first = cleanId(row[table.header[0]]);
      if (!INVENTORY_ID.test(first)) continue;
      const notApplicable = /^NFR-/.test(first) && NFR_NOT_APPLICABLE.test(cleanId(row.Requirement ?? ''));
      // Without a Status column `N/A` wins over a row-wide `(withdrawn)`, as before the register.
      if (notApplicable && !table.header.includes('Status')) { define(first, { state: 'n/a' }); continue; }
      const state = rowState(table, row, first, problems);
      define(first, state.state === 'active' && notApplicable ? { state: 'n/a' } : state);
    }
  }
}

function collectFlows(md) {
  const flows = [];
  const byId = new Map();
  const lines = md.split(/\r?\n/);
  let current = null;
  for (const line of lines) {
    const h = FLOW_HEADING.exec(line);
    if (h) {
      current = { id: h[1], name: h[2].replace(/^\s*[—-]\s*/, '').trim(), critical: false, withdrawn: /\(withdrawn\)/i.test(line), activities: [] };
      flows.push(current);
      byId.set(current.id, current);
      continue;
    }
    if (/^##\s/.test(line)) current = null;
    const c = /^\*\*Critical:\*\*\s*(yes|no)/i.exec(line.trim());
    if (c && current) current.critical = c[1].toLowerCase() === 'yes';
    const a = /^\s*[-*]\s+\*\*(FL-\d+)\.(A\d+)\*\*\s*[—-]?\s*(.*)$/.exec(line);
    if (a) {
      const owner = byId.get(a[1]);
      if (owner) owner.activities.push({ id: `${a[1]}.${a[2]}`, name: a[3].replace(/\s*\(withdrawn\).*$/i, '').trim(), withdrawn: /\(withdrawn\)/i.test(line) });
    }
  }
  return flows;
}

/**
 * Ids defined by the PRD, `docs/discovery.md` and `docs/architecture.md` (umbrella D5 syntax),
 * with `active` / `withdrawn` / `superseded` / `n/a` states, plus the discovery flows for the story
 * map. A draft architecture (`**Status:** draft`, i.e. /architect's publication gate still holds)
 * contributes no AD ids — `architectureDraft` tells the caller to warn. `D-n` change-log headings
 * are ids too; `scopeRev` is the PRD's `**Current:**` version; `problems` lists malformed register
 * Status cells (the caller reports them as errors).
 */
export function loadInventory(root, prdPath = 'docs/PRD.md') {
  const ids = new Map();
  const problems = [];
  const prdAbs = path.resolve(root, prdPath);
  const prd = readIfExists(prdAbs);
  const discovery = readIfExists(path.join(root, 'docs', 'discovery.md'));
  const architecture = readIfExists(path.join(root, 'docs', 'architecture.md'));
  const architectureDraft = architecture !== null && ARCHITECTURE_DRAFT.test(architecture);
  if (prd) collectIds(prd, 'prd', ids, problems);
  if (discovery) collectIds(discovery, 'discovery', ids, problems);
  if (architecture && !architectureDraft) collectIds(architecture, 'architecture', ids, problems);
  return {
    ids, flows: discovery ? collectFlows(discovery) : [], prdPath, prdExists: prd !== null, architectureDraft,
    scopeRev: prd ? (PRD_CURRENT.exec(prd)?.[1] ?? null) : null, problems,
  };
}

/** `docs/map/system.yaml` parsed, or `null` when absent. A parse failure throws (`system.yaml: …`). */
export function loadSystem(root) {
  const file = path.join(root, 'docs', 'map', 'system.yaml');
  const text = readIfExists(file);
  if (text === null) return null;
  try {
    return parseYaml(text);
  } catch (err) {
    throw new Error(`docs/map/system.yaml: ${err.message}`);
  }
}

const PLAN_TASKS_LINE = /^\*\*Tasks:\*\*(.*)$/m;
const PLAN_SPEC_LINE = /^\*\*Source spec:\*\*[ \t]*`([^`]+)`/m;
const LEADING_TASK_ID = /^E\d+-\d+\b/;

function readPlans(root, sub) {
  const dir = path.join(root, '.agents', 'plans', sub);
  if (!fs.existsSync(dir)) return [];
  return fs.readdirSync(dir).filter((f) => f.endsWith('.md')).sort().map((f) => {
    const md = fs.readFileSync(path.join(dir, f), 'utf8');
    // An annotated entry (`E0-1 (umbrella)`) still counts: a dropped active id reads as delivered.
    const ids = listCell(PLAN_TASKS_LINE.exec(md)?.[1] ?? '').map((e) => LEADING_TASK_ID.exec(e)?.[0]).filter(Boolean);
    return { path: `.agents/plans/${sub}/${f}`, ids, spec: PLAN_SPEC_LINE.exec(md)?.[1] ?? null };
  });
}

/** `**Tasks:**` ids and the backticked `**Source spec:**` of every done / active plan. */
export function loadPlanTasks(root) {
  return { done: readPlans(root, 'done'), active: readPlans(root, 'active') };
}

// ---------------------------------------------------------------------------------------------
// Checks
// ---------------------------------------------------------------------------------------------

function findCycle(ids, depsOf) {
  const state = new Map();
  const stack = [];
  const visit = (id) => {
    state.set(id, 1);
    stack.push(id);
    for (const d of depsOf(id)) {
      if (!ids.has(d)) continue;
      if (state.get(d) === 1) return [...stack.slice(stack.indexOf(d)), d];
      if (!state.has(d)) { const c = visit(d); if (c) return c; }
    }
    stack.pop();
    state.set(id, 2);
    return null;
  };
  for (const id of ids) if (!state.has(id)) { const c = visit(id); if (c) return c; }
  return null;
}

/** Integrity of a parsed `system.yaml` (schema §5). Returns `{ errors, warnings }`. */
export function checkSystem(system) {
  const errors = [];
  const warnings = [];
  const err = (m) => errors.push(`system.yaml: ${m}`);
  if (!system || typeof system !== 'object' || Array.isArray(system)) { err('top level must be a map with nodes / links / flows'); return { errors, warnings }; }
  if (system.schema !== 1) err(`schema must be 1 (got ${JSON.stringify(system.schema ?? null)})`);
  // Shape errors are reported, never filtered away: `--system-only` must judge the file as written.
  const isMap = (v) => v !== null && typeof v === 'object' && !Array.isArray(v);
  const listOfMaps = (key, { required }) => {
    const value = system[key];
    if (value === undefined && !required) return [];
    if (!Array.isArray(value)) { err(`${key} must be a ${required ? 'non-empty ' : ''}list of maps`); return []; }
    if (required && value.length === 0) err(`${key} must be a non-empty list of maps`);
    const bad = value.map((v, i) => (isMap(v) ? null : i)).filter((i) => i !== null);
    for (const i of bad) err(`${key}[${i}] must be a map`);
    return bad.length ? value.filter(isMap) : value;
  };
  const nodes = listOfMaps('nodes', { required: true });
  const links = listOfMaps('links', { required: false });
  const flows = listOfMaps('flows', { required: false });

  const walk = (value, where) => {
    if (Array.isArray(value)) value.forEach((v, i) => walk(v, `${where}[${i}]`));
    else if (value && typeof value === 'object') {
      for (const k of Object.keys(value)) {
        if (FORBIDDEN_SYSTEM_KEYS.has(k.toLowerCase())) err(`${where}.${k}: status / progress keys are not stored in the map — they live in .agents/backlog.md`);
        walk(value[k], `${where}.${k}`);
      }
    }
  };
  walk({ nodes, links, flows }, '');

  const byId = new Map();
  for (const n of nodes) {
    const id = String(n.id ?? '');
    if (id === '') { err('node without id'); continue; }
    if (!/^[a-z][a-z0-9-]*$/.test(id)) err(`node ${id}: id must be kebab-case`);
    if (byId.has(id)) err(`duplicate node id ${id}`);
    byId.set(id, n);
    if (!NODE_KINDS.has(n.kind)) err(`node ${id}: kind ${JSON.stringify(n.kind ?? null)} not in trunk/branch/twig/leaf/root`);
    if (n.subdomain !== undefined && !SUBDOMAINS.has(n.subdomain)) err(`node ${id}: subdomain ${JSON.stringify(n.subdomain)} not in core/supporting/generic`);
    if (n.kind === 'branch' && n.subdomain === undefined) err(`node ${id}: branch without subdomain`);
    if (n.criticality !== undefined && !CRITICALITIES.has(n.criticality)) err(`node ${id}: criticality ${JSON.stringify(n.criticality)} not in critical/normal`);
  }
  const trunks = nodes.filter((n) => n.kind === 'trunk').map((n) => n.id);
  if (trunks.length !== 1) err(`exactly one trunk required (found ${trunks.length}${trunks.length ? `: ${trunks.join(', ')}` : ''})`);

  for (const [id, n] of byId) {
    const noParent = n.kind === 'trunk' || n.kind === 'root';
    if (noParent && n.parent !== undefined) err(`node ${id}: ${n.kind} must not have a parent`);
    if (!noParent && NODE_KINDS.has(n.kind) && n.parent === undefined) err(`node ${id}: ${n.kind} requires a parent`);
    if (n.parent !== undefined) {
      if (n.parent === id) err(`node ${id}: self-parent`);
      else if (!byId.has(n.parent)) err(`node ${id}: unknown parent ${n.parent}`);
    }
  }
  const cycle = findCycle(new Set(byId.keys()), (id) => { const p = byId.get(id).parent; return p !== undefined && p !== id ? [p] : []; });
  if (cycle) err(`parent cycle: ${cycle.join(' → ')}`);
  if (trunks.length === 1 && !cycle) {
    const reach = (id, seen = new Set()) => {
      if (seen.has(id)) return false;
      seen.add(id);
      const n = byId.get(id);
      if (!n) return false;
      if (n.id === trunks[0]) return true;
      return n.parent !== undefined && reach(n.parent, seen);
    };
    for (const [id, n] of byId) if (n.kind !== 'root' && n.kind !== 'trunk' && !reach(id)) err(`node ${id}: not reachable from trunk ${trunks[0]} by parent links`);
  }

  links.forEach((l, i) => {
    for (const side of ['from', 'to']) if (!byId.has(l[side])) err(`links[${i}].${side}: unknown node ${JSON.stringify(l[side] ?? null)}`);
    if (!LINK_KINDS.has(l.kind)) err(`links[${i}] ${l.from ?? '?'} → ${l.to ?? '?'}: kind ${JSON.stringify(l.kind ?? null)} not in ${[...LINK_KINDS].join('/')}`);
  });
  const flowIds = new Set();
  flows.forEach((f, i) => {
    const id = String(f.id ?? `flows[${i}]`);
    if (flowIds.has(id)) err(`duplicate flow id ${id}`);
    flowIds.add(id);
    if (f.critical !== undefined && typeof f.critical !== 'boolean') err(`flow ${id}: critical must be true/false`);
    const steps = Array.isArray(f.steps) ? f.steps : [];
    if (steps.length < 2) err(`flow ${id}: needs at least two steps`);
    for (const s of steps) if (!byId.has(s)) err(`flow ${id}: unknown step node ${s}`);
  });
  return { errors, warnings, nodes: byId, flows };
}

const pointsOf = (size) => SIZE_POINTS[size];

/** Repo-relative path of an Epic's file: the one on disk, else the name `epicFileName` would give it. */
function epicFilePath(b, epic) {
  const name = (b.files ?? []).find((f) => f.epic === epic)?.name ?? epicFileName(epic, b.epics.find((e) => e.id === epic)?.title ?? '');
  return path.posix.join(EPIC_DIR, name);
}

/** Every backlog check. `backlog` is the markdown or the `parseBacklog` result. */
export function checkBacklog({ backlog, inventory, system }) {
  const b = typeof backlog === 'string' ? parseBacklog(backlog) : backlog;
  if (b.legacy) return { errors: [], warnings: [], legacy: true };
  if (b.preScope) return { errors: [PRE_SCOPE_MESSAGE], warnings: [], legacy: false, preScope: true };
  if (b.preDetail) return { errors: [PRE_DETAIL_MESSAGE], warnings: [], legacy: false, preDetail: true };
  // A dropped table (missing column) would make every check below fail on an empty list — report
  // the structural problem alone instead of that cascade.
  if (b.problems.length) return { errors: [...b.problems], warnings: [] };
  const errors = [];
  const warnings = [];
  const inv = inventory ?? { ids: new Map(), flows: [] };

  // --- system integrity first: Node resolution below needs a sane node set
  let sys = null;
  if (system) {
    sys = checkSystem(system);
    errors.push(...sys.errors);
    warnings.push(...sys.warnings);
  }

  // --- epics
  const epicIds = new Set(b.epics.map((e) => e.id));
  const seenEpic = new Set();
  for (const e of b.epics) {
    if (seenEpic.has(e.id)) errors.push(`duplicate Epic id ${e.id}`);
    seenEpic.add(e.id);
    if (!EPIC_ID.test(e.id)) errors.push(`Epic ${e.id}: id must match E<n>`);
    for (const d of e.deps) if (!epicIds.has(d)) errors.push(`Epic ${e.id}: unknown dependency ${d}`);
  }
  const epicCycle = findCycle(epicIds, (id) => b.epics.find((e) => e.id === id)?.deps ?? []);
  if (epicCycle) errors.push(`Epic dependency cycle: ${epicCycle.join(' → ')}`);

  // --- tasks: cells
  const taskIds = new Set();
  const byId = new Map();
  for (const t of b.tasks) {
    if (taskIds.has(t.id)) errors.push(`duplicate Task id ${t.id}`);
    taskIds.add(t.id);
    byId.set(t.id, t);
    if (!TASK_ID.test(t.id)) errors.push(`Task ${t.id}: id must match E<n>-<m>`);
    else if (t.id.split('-')[0] !== t.epic) errors.push(`Task ${t.id}: Epic cell ${t.epic || '(empty)'} does not match the id prefix`);
    if (!epicIds.has(t.epic)) errors.push(`Task ${t.id}: Epic ${t.epic || '(empty)'} not in Epic map`);
    if (!TASK_TYPES.has(t.type)) errors.push(`Task ${t.id}: Type ${t.type || '(empty)'} not in story/tech`);
    if (pointsOf(t.size) === undefined) errors.push(`Task ${t.id}: Size ${t.size || '(empty)'} not in M/H/XH`);
    else if (t.pts !== pointsOf(t.size)) errors.push(`Task ${t.id}: Pts ${Number.isNaN(t.pts) ? '(not a number)' : t.pts} ≠ ${pointsOf(t.size)} for Size ${t.size}`);
    if (!SCOPES.includes(t.scope)) errors.push(`Task ${t.id}: Scope ${t.scope || '(empty)'} must be CORE, MUST or COULD`);
    if (!TASK_STATUSES.has(t.status)) errors.push(`Task ${t.id}: Status ${t.status || '(empty)'} not in TODO/WIP/DONE/BLOCKED`);
    if (sys && t.node && !sys.nodes.has(t.node)) errors.push(`Task ${t.id}: unknown Node ${t.node} (not in docs/map/system.yaml)`);
  }

  // --- tasks: DAG
  for (const t of b.tasks) {
    for (const d of t.deps) {
      if (!taskIds.has(d)) { errors.push(`Task ${t.id}: unknown dependency ${d}`); continue; }
      // Scope order binds planned work only: a withdrawn Task on either side raises nothing.
      const dep = byId.get(d);
      if (t.withdrawn || dep.withdrawn || !SCOPES.includes(t.scope) || !SCOPES.includes(dep.scope)) continue;
      if (t.scope === 'CORE' && dep.scope !== 'CORE') errors.push(`Task ${t.id}: CORE Task depends on ${d} (${dep.scope}) — CORE cannot wait on later work`);
      if (t.scope === 'MUST' && dep.scope === 'COULD') errors.push(`Task ${t.id}: MUST Task depends on ${d} (COULD) — committed work cannot depend on optional work`);
    }
  }
  const taskCycle = findCycle(taskIds, (id) => byId.get(id).deps);
  if (taskCycle) errors.push(`dependency cycle: ${taskCycle.join(' → ')}`);

  // --- Relates: one canonical unordered pair however it is declared
  const pairs = new Map();
  for (const t of b.tasks) {
    for (const x of t.relates) {
      if (x === t.id) { errors.push(`Task ${t.id}: Relates itself`); continue; }
      if (!taskIds.has(x)) { errors.push(`Task ${t.id}: unknown Relates target ${x}`); continue; }
      const [a, c] = t.id < x ? [t.id, x] : [x, t.id];
      pairs.set(`${a}|${c}`, [a, c]);
    }
  }
  for (const [a, c] of pairs.values()) {
    const A = byId.get(a);
    const C = byId.get(c);
    if (A.deps.includes(c) || C.deps.includes(a)) errors.push(`Tasks ${a} and ${c}: both Depends on and Relates — one relation per pair`);
    const gone = [A, C].filter((t) => t.withdrawn).map((t) => t.id);
    if (gone.length) warnings.push(`Relates ${a} ↔ ${c}: ${gone.join(' and ')} ${gone.length > 1 ? 'are' : 'is'} withdrawn`);
  }

  // --- Chain: advisory, validated, never scheduled
  for (const t of b.tasks) if (t.chain && !CHAIN_TOKEN.test(t.chain)) errors.push(`Task ${t.id}: Chain ${t.chain} must be a kebab token`);
  for (const [token, ch] of chainPaths(b.tasks.filter((t) => !t.chain || CHAIN_TOKEN.test(t.chain)))) {
    for (const p of ch.problems) errors.push(`chain ${token}: ${p}`);
    if (ch.members.length === 1) warnings.push(`chain ${token}: single member`);
    if (ch.members.length > 4) warnings.push(`chain ${token}: ${ch.members.length} members — consider one Task or a split`);
    for (const id of ch.members) if (byId.get(id)?.withdrawn) warnings.push(`chain ${token}: broken by withdrawal of ${id}`);
  }

  // --- epic points = sum of tasks
  for (const e of b.epics) {
    const sum = b.tasks.filter((t) => t.epic === e.id && pointsOf(t.size) !== undefined).reduce((a, t) => a + pointsOf(t.size), 0);
    if (Number.isNaN(e.pts)) errors.push(`Epic ${e.id}: Pts is not a number`);
    else if (e.pts !== sum) errors.push(`Epic ${e.id}: Pts ${e.pts} ≠ ${sum} (sum of its Tasks)`);
  }

  // --- Epic files: one per Epic, a block per live Task in its own Epic's file
  const { detail, files, details } = b;
  if (!DETAILS.includes(detail)) errors.push('backlog header: **Detail:** must be `structure` or `full`');
  const fileOf = new Map();
  for (const f of files) {
    if (fileOf.has(f.epic)) errors.push(`Epic ${f.epic}: two Epic files (${fileOf.get(f.epic)}, ${f.name})`);
    else fileOf.set(f.epic, f.name);
    if (!epicIds.has(f.epic)) errors.push(`Epic file ${f.name}: Epic ${f.epic} not in the Epic map`);
  }
  const hasBlock = new Set();
  for (const f of files) {
    for (const id of f.taskIds) {
      const t = byId.get(id);
      if (!t) { errors.push(`${f.name}: Task ${id} not in the Task table`); continue; }
      if (t.epic !== f.epic) errors.push(`${f.name}: Task ${id} belongs to Epic ${t.epic}`);
      else hasBlock.add(id);
    }
  }
  const epicPath = (epic) => epicFilePath(b, epic);
  for (const t of b.tasks) {
    if (!t.withdrawn && !hasBlock.has(t.id)) errors.push(`Task ${t.id}: no \`## ${t.id} — …\` block in the Epic file of ${t.epic} (${epicPath(t.epic)})`);
  }

  // --- acceptance criteria
  const acCount = new Map();
  const seenAc = new Set();
  for (const ac of b.acs) {
    if (!AC_ID.test(ac.id)) { errors.push(`malformed AC id ${ac.id} (expected E<n>-<m>.AC<k>)`); continue; }
    if (seenAc.has(ac.id)) errors.push(`duplicate AC definition ${ac.id} (${ac.file} line ${ac.line}) — /qa-verify keys criteria by id`);
    seenAc.add(ac.id);
    if (!taskIds.has(ac.task)) errors.push(`AC ${ac.id}: Task ${ac.task} not in Task table`);
    // Only a criterion where /qa-verify will find it counts toward "Task has ≥1 AC".
    if (ac.block === null || !ac.inCriteria) { errors.push(`${ac.id} defined outside a Task's ### Acceptance criteria (${ac.file} line ${ac.line})`); continue; }
    if (ac.block !== ac.task) { errors.push(`AC ${ac.id} defined under ## ${ac.block} — expected ## ${ac.task} (${ac.file})`); continue; }
    acCount.set(ac.task, (acCount.get(ac.task) ?? 0) + 1);
  }
  for (const ac of b.strayAcs) {
    const where = byId.has(ac.task) ? epicPath(byId.get(ac.task).epic) : '.agents/backlog/E<n>-<slug>.md';
    errors.push(`${ac.id} defined in .agents/backlog.md (line ${ac.line}) — criteria live in the Task's block of its Epic file (${where})`);
  }
  // "≥ 1 criterion under `full`" is judged by checkAgainstRoot: only the resolver knows whether an
  // approved spec in Ref owns a Task's criteria.
  const undetailed = [];
  for (const t of b.tasks) {
    const n = acCount.get(t.id) ?? 0;
    if (!t.withdrawn && hasBlock.has(t.id)) {
      const where = epicPath(t.epic);
      const d = details.get(t.id) ?? {};
      if (detail === 'structure' && n === 0 && !d.summary) errors.push(`Task ${t.id}: no **Summary:** line (${where})`);
      if (detail === 'full' && (!d.goal || !d.inScope || !d.outOfScope)) undetailed.push(t.id);
    }
    if (t.size === 'XH' && t.type === 'story' && n > 5) warnings.push(`Task ${t.id}: XH story with ${n} criteria — split it (workflow steps, business-rule variations, …)`);
  }
  if (undetailed.length) {
    const rest = undetailed.length - 5;
    warnings.push(`${undetailed.length} Task(s) without Goal / In scope / Out of scope (${undetailed.slice(0, 5).join(', ')}${rest > 0 ? `, +${rest}` : ''}) — /setup:delivery-plan details them`);
  }

  // --- traces (withdrawn Tasks keep valid ids but no longer cover anything)
  const live = b.tasks.filter((t) => !t.withdrawn);
  const traced = new Set();
  for (const t of b.tasks) {
    for (const id of t.traces) {
      const def = inv.ids.get(id);
      if (!def) { errors.push(`Task ${t.id}: unknown trace ${id}`); continue; }
      if (t.withdrawn) continue;
      if (def.state === 'withdrawn') errors.push(`Task ${t.id}: traces withdrawn ${id}`);
      // A superseded requirement is protected history for work already built on it; an AD is not.
      else if (def.state === 'superseded' && REGISTER_ID.test(id)) warnings.push(`Task ${t.id} traces ${id} (superseded by ${def.successor}${def.decision ? ` per ${def.decision}` : ''}) — protected history or stale trace?`);
      else if (def.state === 'superseded') errors.push(`Task ${t.id}: traces ${id}, superseded by ${def.successor} — trace ${def.successor} instead`);
      traced.add(id);
    }
    if (!t.withdrawn && t.type === 'tech' && t.traces.length === 0 && !qualityMarker(t.title)?.known) warnings.push(`Task ${t.id}: tech Task with no trace (AD-n / NFR-n)`);
  }
  if (!taskCycle) { const q = qualityChecks(b, live); errors.push(...q.errors); warnings.push(...q.warnings); }
  // --- outside rows: work the dev team needs but does not do; their traces count for coverage
  const tracedOutside = new Set();
  const seenOutside = new Set();
  for (const x of b.outside) {
    if (!OUTSIDE_ID.test(x.id)) errors.push(`outside ${x.id || `row (line ${x.line})`}: id must match X-<n>`);
    if (seenOutside.has(x.id)) errors.push(`duplicate outside id ${x.id}`);
    seenOutside.add(x.id);
    for (const [cell, ids] of [['Needed by', x.neededBy], ['Starts after', x.startsAfter]]) {
      for (const id of ids) {
        if (!taskIds.has(id)) errors.push(`outside ${x.id}: ${cell} ${id} is not a Task`);
        // The plan reads a withdrawn Task as gone: the row would silently stop gating or waiting.
        else if (byId.get(id).withdrawn) warnings.push(`outside ${x.id}: ${cell} ${id} is withdrawn — name the Task that replaces it, or drop the id`);
      }
    }
    for (const id of x.traces) {
      const def = inv.ids.get(id);
      if (!def) { errors.push(`outside ${x.id}: unknown trace ${id}`); continue; }
      // No build history to protect: anything but an active id is an error here.
      if (def.state !== 'active') { errors.push(`outside ${x.id}: traces ${def.state} ${id}`); continue; }
      tracedOutside.add(id);
    }
  }
  // One wait graph: a Task waits for its prerequisites and for the outside items it needs, an item
  // for its `Starts after` Tasks. Withdrawn Tasks are out, as in the plan. The Task DAG alone is
  // acyclic here, so a cycle always runs through an outside row.
  if (!taskCycle) {
    const liveTask = (id) => byId.has(id) && !byId.get(id).withdrawn;
    const rows = new Map(b.outside.filter((x) => OUTSIDE_ID.test(x.id)).map((x) => [x.id, x]));
    const itemsOf = new Map();
    for (const x of rows.values()) for (const n of x.neededBy) itemsOf.set(n, [...(itemsOf.get(n) ?? []), x.id]);
    const nodes = new Set([...b.tasks.filter((t) => !t.withdrawn).map((t) => t.id), ...rows.keys()]);
    const waitsFor = (id) => (rows.has(id) ? rows.get(id).startsAfter.filter(liveTask) : [...byId.get(id).deps.filter(liveTask), ...(itemsOf.get(id) ?? [])]);
    const loop = findCycle(nodes, waitsFor);
    if (loop) errors.push(`outside rows: wait cycle ${loop.join(' → ')} — an item and the Tasks around it wait for each other`);
  }
  errors.push(...(inv.problems ?? []));
  for (const [id, def] of inv.ids) {
    if (!REGISTER_ID.test(id) || def.state !== 'superseded') continue;
    if (def.successor === id) errors.push(`${id}: superseded by itself`);
    else if (!inv.ids.has(def.successor)) errors.push(`${id}: superseded by ${def.successor}, which is not defined`);
  }
  if (b.scopeRev && inv.scopeRev && b.scopeRev !== inv.scopeRev) {
    warnings.push(`backlog generated at scope ${b.scopeRev}, register is ${inv.scopeRev} — reconcile the backlog (/update-backlog)`);
  }
  const hasRequirements = [...inv.ids.keys()].some((id) => id.startsWith('R-'));
  if (hasRequirements) {
    for (const [id, def] of inv.ids) {
      if (def.state === 'active' && /^(R|NFR)-\d+$/.test(id) && !traced.has(id) && !tracedOutside.has(id)) errors.push(`${id}: no Task and no outside row traces it`);
    }
  }
  const liveFlows = inv.flows.filter((f) => !f.withdrawn);
  for (const f of liveFlows.filter((x) => x.critical)) {
    for (const a of f.activities.filter((x) => !x.withdrawn)) {
      if (!live.some((t) => (t.scope === 'CORE' || t.scope === 'MUST') && t.traces.includes(a.id))) errors.push(`${a.id} (critical flow ${f.id}): no CORE or MUST Task traces it`);
    }
  }
  if (sys && liveFlows.length) {
    const flowIds = new Set(liveFlows.map((f) => f.id));
    for (const f of sys.flows) if (f.fl !== undefined && !flowIds.has(f.fl)) errors.push(`system.yaml: flow ${f.id}: fl ${f.fl} not in docs/discovery.md`);
    for (const f of liveFlows.filter((x) => x.critical)) {
      if (!sys.flows.some((s) => s.fl === f.id && s.critical === true)) errors.push(`system.yaml: critical ${f.id} has no flow with critical: true`);
    }
  }

  if (sys) {
    const used = new Set(live.map((t) => t.node).filter(Boolean));
    for (const [id, n] of sys.nodes) if (n.kind === 'leaf' && !used.has(id)) warnings.push(`leaf ${id}: no Task targets it`);
  }
  if (!errors.length && live.length) warnings.push(...scopeWarnings(live));
  const outsideCovered = [...tracedOutside].filter((id) => !traced.has(id)).sort(byIdAsc);
  return { errors, warnings, legacy: false, outsideCovered };
}

/** Scope advisories over a valid DAG of live Tasks: no CORE at all, and CORE Tasks nothing later needs. */
function scopeWarnings(live) {
  const core = live.filter((t) => t.scope === 'CORE');
  if (!core.length) return [NO_CORE_WARNING];
  const later = live.filter((t) => t.scope !== 'CORE' && !qualityMarker(t.title)?.known);
  if (!later.length) return [];
  // Every Task some live non-CORE product Task needs, directly or transitively.
  const byId = new Map(live.map((t) => [t.id, t]));
  const needed = new Set();
  const walk = (t) => { for (const d of t.deps) if (byId.has(d) && !needed.has(d)) { needed.add(d); walk(byId.get(d)); } };
  later.forEach(walk);
  return core.filter((t) => !needed.has(t.id)).map((t) => `Task ${t.id}: CORE, but nothing outside CORE depends on it — candidate to leave CORE`);
}

/** Quality Tasks (quality-tasks.md) over a valid DAG: closing audits wait for all product work, the recurring cadence, and nothing left unplanned. */
function qualityChecks(b, live) {
  const errors = [];
  const warnings = [];
  const q = new Map(live.map((t) => [t.id, qualityMarker(t.title)]));
  const product = live.filter((t) => !q.get(t.id) && (t.scope === 'CORE' || t.scope === 'MUST'));
  if (!product.length) return { errors, warnings };
  const byId = new Map(live.map((t) => [t.id, t]));
  // "Waits for" walks open Tasks only, as delivery-plan.mjs does (a DONE Task is dropped there, so a path through it is no wait).
  const open = (t) => t.status !== 'DONE';
  const ancestors = (t) => { const seen = new Set(); const walk = (x) => { for (const d of x.deps) { const y = byId.get(d); if (y && open(y) && !seen.has(d)) { seen.add(d); walk(y); } } }; walk(t); return seen; };
  const sinks = (ids) => [...ids].filter((id) => !product.some((t) => ids.has(t.id) && t.deps.includes(id))).sort(byIdAsc);
  // Per closing marker the newest live audit (any status) is the one that counts — a re-audit supersedes an earlier one; it must wait only while TODO / BLOCKED.
  const newest = new Map();
  for (const t of live) {
    const m = q.get(t.id);
    if (m?.known && m.kind === 'closing' && (!newest.has(m.marker) || byIdAsc(t.id, newest.get(m.marker)) > 0)) newest.set(m.marker, t.id);
  }
  const points = product.reduce((a, t) => a + (pointsOf(t.size) ?? 0), 0);
  const n = Math.max(QUALITY_MIN_OCCURRENCES, Math.ceil(points / QUALITY_CADENCE_POINTS));
  const known = Object.keys(QUALITY_MARKERS).map((k) => `[${k}]`).join(', ');
  const conditional = Object.entries(QUALITY_MARKERS).filter(([, d]) => d.conditional).map(([k]) => `[${k}]`).join(' and ');
  for (const t of live) {
    const m = q.get(t.id);
    if (!m) continue;
    if (!m.known) { warnings.push(`Task ${t.id}: unknown quality marker [${m.marker}] — use one of ${known}`); continue; }
    if (t.type !== 'tech' || t.scope !== 'MUST' || t.size !== m.size) warnings.push(`Task ${t.id} [${m.marker}]: expected tech · ${m.size} · MUST, found ${t.type} · ${t.size} · ${t.scope}`);
    if (m.kind === 'closing' && newest.get(m.marker) === t.id && (t.status === 'TODO' || t.status === 'BLOCKED')) {
      const anc = ancestors(t);
      const missing = new Set(product.filter(open).map((p) => p.id).filter((id) => !anc.has(id)));
      if (missing.size) errors.push(`Task ${t.id} [${m.marker}]: a closing audit must wait for every live CORE/MUST product Task — add ${sinks(missing).join(', ')} to Depends on`);
    }
    if (m.kind === 'recurring' && m.occurrence !== null && t.status !== 'DONE' && !t.deps.length) warnings.push(`Task ${t.id} [${m.marker}]: occurrence ${m.occurrence} has no Depends on — it would be free on day one; place it after its share of the product work`);
  }
  for (const [marker, def] of Object.entries(QUALITY_MARKERS)) {
    if (def.kind !== 'recurring' || !def.planned) continue;
    const k = live.filter((t) => q.get(t.id)?.marker === marker && q.get(t.id).occurrence !== null).length;
    if (k > 0 && k !== n) warnings.push(`[${marker}]: ${k} occurrence(s) planned, ${n} expected for ${points} CORE/MUST product points (one per ${QUALITY_CADENCE_POINTS}, at least ${QUALITY_MIN_OCCURRENCES}) — add or withdraw one with /update-backlog`);
  }
  // A reminder's unnumbered Task does not plan a recurring command; a numbered occurrence does.
  const planned = new Set([...q.values()].filter((m) => m?.known && (m.kind !== 'recurring' || m.occurrence !== null)).map((m) => m.marker));
  const ruledOut = new Set(b.ruledOut ?? []);
  const missing = Object.entries(QUALITY_MARKERS).filter(([marker, def]) => def.planned && !planned.has(marker) && !(def.conditional && ruledOut.has(marker))).map(([marker]) => `[${marker}]`);
  if (missing.length) warnings.push(`quality Tasks not planned: ${missing.join(', ')} — add them with /update-backlog (.claude/skills/backlog/quality-tasks.md); only ${conditional} may be ruled out under ## Consciously out of scope`);
  return { errors, warnings };
}

/**
 * Chains by token: `members` (id order), `ids` (the walked `Depends on` path — order is the DAG's,
 * never the table's) and `problems` (span / linearity). Withdrawn members stay in, so a withdrawal
 * does not reshape the path.
 */
export function chainPaths(tasks) {
  const groups = new Map();
  for (const t of tasks) if (t.chain) groups.set(t.chain, [...(groups.get(t.chain) ?? []), t]);
  const out = new Map();
  for (const [token, members] of [...groups].sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0))) {
    const ids = new Set(members.map((t) => t.id));
    const sorted = members.map((t) => t.id).sort(byIdAsc);
    const problems = [];
    const epics = [...new Set(members.map((t) => t.epic))];
    if (epics.length > 1) problems.push(`members span Epics ${epics.join(', ')}`);
    const nodes = [...new Set(members.map((t) => t.node ?? '—'))];
    if (nodes.length > 1) problems.push(`members span Nodes ${nodes.join(', ')}`);
    const inner = new Map(members.map((t) => [t.id, t.deps.filter((d) => ids.has(d))]));
    const heads = sorted.filter((id) => inner.get(id).length === 0);
    const multiDep = sorted.filter((id) => inner.get(id).length > 1);
    const fanOut = sorted.filter((id) => sorted.filter((o) => inner.get(o).includes(id)).length > 1);
    const path = [];
    if (heads.length === 1) {
      const seen = new Set();
      for (let cur = heads[0]; cur && !seen.has(cur); cur = sorted.find((o) => inner.get(o).includes(cur))) { seen.add(cur); path.push(cur); }
    }
    const detail = [];
    if (heads.length !== 1) detail.push(`${heads.length} heads`);
    if (multiDep.length) detail.push(`${multiDep.join(', ')} depends on more than one member`);
    if (fanOut.length) detail.push(`${fanOut.join(', ')} is depended on by more than one member`);
    if (!detail.length && path.length !== sorted.length) detail.push(`path reaches ${path.length} of ${sorted.length} members`);
    if (detail.length && sorted.length > 1) problems.push(`not one linear Depends on path (${detail.join('; ')})`);
    out.set(token, { members: sorted, ids: path.length ? path : sorted, problems });
  }
  return out;
}

/**
 * A Task on a done plan's `**Tasks:**` line and on no active plan's is delivered: it must be
 * `DONE` with one of those plans (and its spec, when named) in `Ref`. Advisory only. A Task with a
 * `Jira` key skips the Status part — a reopen refreshed from Jira legitimately overrides the plan. A
 * GitHub issue number in that cell (`#42`, written by /github-sync) does not: nothing refreshes it.
 */
export function staleTaskWarnings(tasks, plans) {
  const activeIds = new Set(plans.active.flatMap((p) => p.ids));
  const warnings = [];
  for (const t of tasks) {
    if (t.withdrawn || activeIds.has(t.id)) continue;
    const delivered = plans.done.filter((p) => p.ids.includes(t.id));
    if (!delivered.length) continue;
    const ref = t.ref ?? '';
    const paths = delivered.map((p) => p.path);
    const specs = [...new Set(delivered.map((p) => p.spec).filter(Boolean))];
    const problems = [];
    if (t.status !== 'DONE' && !JIRA_KEY.test(t.jira ?? '')) problems.push(`Status ${t.status || '(empty)'}, not DONE`);
    if (!paths.some((p) => ref.includes(p))) problems.push(`Ref lacks a done plan (${paths.join(', ')})`);
    if (specs.length && !specs.some((s) => ref.includes(s))) problems.push(`Ref lacks its spec (${specs.join(', ')})`);
    if (problems.length) warnings.push(`Task ${t.id}: delivered by ${paths[0]} but ${problems.join('; ')}`);
  }
  return warnings;
}

// ---------------------------------------------------------------------------------------------
// Rendering
// ---------------------------------------------------------------------------------------------

// Numeric-aware so E1-2 sorts before E1-10.
export const byIdAsc = new Intl.Collator('en', { numeric: true }).compare;

/** Markdown for the `storymap` region: one table per flow (critical first), Scopes × activities. */
export function renderStoryMap(tasks, flows) {
  const live = (flows ?? []).filter((f) => !f.withdrawn);
  if (!live.length) return '';
  const planned = tasks.filter((t) => !t.withdrawn);
  const ordered = [...live.filter((f) => f.critical), ...live.filter((f) => !f.critical)];
  const scopes = SCOPES.filter((s) => planned.some((t) => t.scope === s));
  const out = [];
  for (const f of ordered) {
    const acts = f.activities.filter((a) => !a.withdrawn);
    out.push(`### ${f.id} — ${f.name || f.id}${f.critical ? ' (critical)' : ''}`, '');
    if (!acts.length) { out.push('_No backbone activities in docs/discovery.md._', ''); continue; }
    out.push(`| Scope | ${acts.map((a) => (a.name ? `${a.id} ${a.name}` : a.id)).join(' | ')} |`);
    out.push(`|-------|${acts.map(() => '---').join('|')}|`);
    for (const s of scopes) {
      const cells = acts.map((a) => planned.filter((t) => t.scope === s && t.traces.includes(a.id)).map((t) => t.id).join(', ') || '—');
      out.push(`| ${s} | ${cells.join(' | ')} |`);
    }
    out.push('');
  }
  return out.join('\n').trimEnd();
}

const escapeRegExp = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');

/** The region `--write` regenerates in `.agents/backlog.md`, with its literal markers. */
export const REGIONS = {
  storymap: { begin: '<!-- storymap:begin -->', end: '<!-- storymap:end -->' },
};

/**
 * Offsets of every `<!-- name:begin -->` / `<!-- name:end -->` pair in `md`, keyed by name. Throws
 * when a marker is missing or duplicated, not alone on its line, `end` precedes `begin`, or two
 * regions overlap — the caller must not write anything in those cases.
 */
export function locateRegions(md, names) {
  const regions = {};
  for (const name of names) {
    const at = {};
    for (const side of ['begin', 'end']) {
      const marker = REGIONS[name]?.[side] ?? `<!-- ${name}:${side} -->`;
      const hits = [...md.matchAll(new RegExp(`^[ \\t]*${escapeRegExp(marker)}[ \\t]*$`, 'gm'))];
      const anywhere = md.split(marker).length - 1;
      if (anywhere === 0) throw new Error(`markers missing: ${marker}`);
      if (anywhere > 1) throw new Error(`marker ${marker} appears ${anywhere} times — expected exactly once`);
      if (hits.length !== 1) throw new Error(`marker ${marker} must be alone on its own line`);
      const start = hits[0].index + hits[0][0].indexOf(marker);
      at[side] = { start, end: start + marker.length };
    }
    if (at.end.start <= at.begin.start) throw new Error(`marker <!-- ${name}:end --> appears before <!-- ${name}:begin -->`);
    regions[name] = { begin: at.begin.end, end: at.end.start };
  }
  const list = Object.entries(regions);
  for (let i = 0; i < list.length; i += 1) {
    for (let j = i + 1; j < list.length; j += 1) {
      const [a, ra] = list[i]; const [b, rb] = list[j];
      if (ra.begin < rb.end && rb.begin < ra.end) throw new Error(`regions ${a} and ${b} overlap — each must be a separate block`);
    }
  }
  return regions;
}

/** Replace the body between `<!-- name:begin -->` and `<!-- name:end -->`; invalid markers throw (see `locateRegions`). */
export function replaceRegion(md, name, body) {
  const { begin, end } = locateRegions(md, [name])[name];
  return `${md.slice(0, begin)}\n${body}\n${md.slice(end)}`;
}

/** The generated `>` meta line under a Task heading in its Epic file — derived from the Task table row. */
export function renderMeta(task) {
  const pts = SIZE_POINTS[task.size] ?? task.pts;
  const line = `Size ${task.size} (${pts}) · Scope ${task.scope} · Depends on ${task.deps.join(', ') || '—'} · Traces ${task.traces.join(', ') || '—'}`;
  return `> ${task.withdrawn ? 'Withdrawn · ' : ''}${line}`;
}

/**
 * An Epic file with exactly one meta line directly under every Task heading the table knows: the
 * generated meta lines (`META_LINE`) right under the heading — blank lines between them included —
 * are replaced, none → one inserted. A `>` quote of another shape is content and stays, and so does
 * a blank line before non-meta content; a heading inside a fenced code block is no Task heading.
 * Everything else, and the file's line endings, stay as they are.
 */
export function renderEpicFile(text, backlog) {
  const eol = text.includes('\r\n') ? '\r\n' : '\n';
  const byId = new Map(backlog.tasks.map((t) => [t.id, t]));
  const lines = text.split(/\r?\n/);
  const out = [];
  const scan = fenceScanner();
  for (let i = 0; i < lines.length; i += 1) {
    out.push(lines[i]);
    if (scan(lines[i])) continue;
    const h = TASK_HEADING.exec(lines[i]);
    const task = h && byId.get(h[1]);
    if (!task) continue;
    // Drop every meta line in the run of blank / meta lines below the heading, with the blanks before it.
    let end = i;
    for (let j = i + 1; j < lines.length && (lines[j].trim() === '' || META_LINE.test(lines[j])); j += 1) {
      if (META_LINE.test(lines[j])) end = j;
    }
    i = end;
    out.push(renderMeta(task));
  }
  return out.join(eol);
}

// ---------------------------------------------------------------------------------------------
// Helpers for the writers: next free ids + the AC resolver, impact, candidate validation
// ---------------------------------------------------------------------------------------------

const SPEC_DATE = /(\d{4}-\d{2}-\d{2})-[^/]*\.md$/;
const maxNum = (ids, re) => Math.max(0, ...ids.map((id) => re.exec(id)).filter(Boolean).map((m) => Number(m[1])));

/** AC definitions of `taskId` inside a spec's `## Acceptance Criteria` section only. */
function specCriteria(md, taskId) {
  const out = [];
  let inCriteria = false;
  let last = null;
  for (const line of md.split(/\r?\n/)) {
    if (/^##\s/.test(line)) { inCriteria = /^##\s+Acceptance criteria\b/i.test(line); last = null; continue; }
    if (!inCriteria) continue;
    const d = AC_DEFINITION.exec(line);
    if (d) {
      last = d[1].trim().split('.')[0] === taskId ? { id: d[1].trim(), text: acText(line) } : null;
      if (last) out.push(last);
      continue;
    }
    if (last && /^\s+\S/.test(line) && !/^\s*[-*]\s+\*\*/.test(line)) last.text = `${last.text} ${line.trim()}`;
    else last = null;
  }
  return out;
}

/**
 * The AC resolver `brainstorm.md` Step 5 and `qa-verify.md` define, made mechanical: `current` =
 * the Task-filtered `## Acceptance Criteria` of the approved spec in `Ref` with the newest
 * `YYYY-MM-DD` filename prefix, else the Task's block in its Epic file; `nextAc` = 1 + the highest
 * AC number in **any** definition the Task ever had (Epic file + every spec in `Ref`, withdrawn
 * included). `summary` is the block's Summary line; `missing` lists what the detail step still owes
 * (`goal`, `inScope`, `outOfScope`, `criteria` = no active resolved criterion from either source).
 */
export function resolveTask(root, backlog, task) {
  const specs = (task.ref ?? '').split(',').map((s) => cleanId(s)).filter((p) => p.endsWith('.md'))
    .map((p) => ({ path: p, md: readIfExists(path.resolve(root, p)) })).filter((s) => s.md !== null);
  const fromBacklog = backlog.acs.filter((a) => a.task === task.id && a.inCriteria && a.block === a.task).map((a) => ({ id: a.id, text: a.text }));
  const block = backlog.details?.get(task.id) ?? null;
  const approved = specs
    .filter((s) => /^\*\*Status:\*\*\s*Approved/im.test(s.md) && /^##\s+Acceptance criteria\b/im.test(s.md) && SPEC_DATE.test(s.path))
    .sort((a, b) => (SPEC_DATE.exec(a.path)[1] < SPEC_DATE.exec(b.path)[1] ? -1 : SPEC_DATE.exec(a.path)[1] > SPEC_DATE.exec(b.path)[1] ? 1 : 0));
  const owner = approved.length ? approved[approved.length - 1] : null;
  const fromSpec = owner ? specCriteria(owner.md, task.id) : [];
  const currentList = owner && fromSpec.length ? fromSpec : fromBacklog;
  // A misplaced definition in backlog.md still holds its id until it is moved: never re-issued.
  const stray = (backlog.strayAcs ?? []).filter((a) => a.task === task.id);
  const all = [...fromBacklog, ...stray, ...specs.flatMap((s) => specCriteria(s.md, task.id))].map((a) => a.id);
  const k = maxNum(all, /\.AC(\d+)$/);
  const current = currentList.map((a) => ({ ...a, withdrawn: /^\(withdrawn\)/i.test(a.text) }));
  const missing = ['goal', 'inScope', 'outOfScope'].filter((key) => !block?.[key]);
  if (!current.some((a) => !a.withdrawn)) missing.push('criteria');
  return {
    current,
    source: owner && fromSpec.length ? owner.path : epicFilePath(backlog, task.epic),
    nextAc: `${task.id}.AC${k + 1}`,
    summary: block?.summary ?? '',
    missing,
  };
}

/** Next free register / decision / Epic / Task ids, and every Task's resolved AC. */
export function nextIds(root, backlog, inventory) {
  const ids = [...inventory.ids.keys()];
  const next = Object.fromEntries(['G', 'R', 'NFR', 'D'].map((p) => [p, `${p}-${maxNum(ids, new RegExp(`^${p}-(\\d+)$`)) + 1}`]));
  next.epic = `E${maxNum(backlog.epics.map((e) => e.id), /^E(\d+)$/) + 1}`;
  const taskNext = {};
  for (const e of backlog.epics) taskNext[e.id] = `${e.id}-${maxNum(backlog.tasks.filter((t) => t.epic === e.id).map((t) => t.id), /^E\d+-(\d+)$/) + 1}`;
  const tasks = Object.fromEntries(backlog.tasks.map((t) => [t.id, resolveTask(root, backlog, t)]));
  return { next, taskNext, tasks };
}

/** Why a Task is protected from in-place edits (`/update-backlog`); empty = unprotected. Jira status is not read here. */
const protection = (t) => [t.status !== 'TODO' && `status ${t.status}`, t.ref && 'ref', t.jira && 'jira key'].filter(Boolean);

/**
 * What a change to each id touches: tracing Tasks (+ protection), transitive dependents, scopes,
 * goals, Epic cut lines, and the `## Outside the dev backlog` rows tracing it (`outside`) — their
 * `Needed by` Tasks join the affected Tasks. An `X-n` id targets its own `Needed by` Tasks; a Task
 * id lists the rows that name it in `Needed by` or `Starts after`.
 */
export function impactOf(ids, backlog, prdMd) {
  const byId = new Map(backlog.tasks.map((t) => [t.id, t]));
  const succ = new Map(backlog.tasks.map((t) => [t.id, []]));
  for (const t of backlog.tasks) for (const d of t.deps) succ.get(d)?.push(t.id);
  const dependents = (id) => {
    const out = new Set();
    const walk = (x) => { for (const s of succ.get(x) ?? []) if (!out.has(s)) { out.add(s); walk(s); } };
    walk(id);
    return [...out].sort(byIdAsc);
  };
  const cut = (epic) => new RegExp(`^\\*\\*${epic}\\*\\*\\s*[—-]\\s*(.*)$`, 'm').exec(backlog.raw ?? '')?.[1]?.trim() ?? null;
  const goalsOf = (id) => {
    const line = (prdMd ?? '').split(/\r?\n/).find((l) => new RegExp(`^\\s*[-*]\\s+\\*\\*${id}\\*\\*`).test(l));
    const m = line && /Traces:\s*([^·]+)/.exec(line);
    return m ? m[1].split(',').map((s) => s.trim()).filter((s) => /^G-\d+$/.test(s)) : [];
  };
  const detail = (t) => ({ id: t.id, epic: t.epic, scope: t.scope, jira: t.jira, withdrawn: t.withdrawn, protected: protection(t) });
  const outsideRows = backlog.outside ?? [];
  return ids.map((id) => {
    let tasks;
    let rows = [];
    if (TASK_ID.test(id)) {
      tasks = [byId.get(id)].filter(Boolean);
      rows = outsideRows.filter((x) => x.neededBy.includes(id) || (x.startsAfter ?? []).includes(id));
    } else {
      rows = OUTSIDE_ID.test(id) ? outsideRows.filter((x) => x.id === id) : outsideRows.filter((x) => x.traces.includes(id));
      const needed = new Set(rows.flatMap((x) => x.neededBy));
      const tracing = (t) => !OUTSIDE_ID.test(id) && t.traces.includes(id);
      tasks = backlog.tasks.filter((t) => tracing(t) || needed.has(t.id));
    }
    const deps = [...new Set(tasks.flatMap((t) => dependents(t.id)))].sort(byIdAsc).map((d) => byId.get(d));
    const all = [...tasks, ...deps];
    return {
      id,
      goals: goalsOf(id),
      tasks: tasks.map(detail),
      dependents: deps.map(detail),
      outside: rows.map((x) => ({ id: x.id, owner: x.owner, neededBy: x.neededBy, startsAfter: x.startsAfter ?? [] })),
      scopes: SCOPES.filter((s) => all.some((t) => t.scope === s)),
      epics: [...new Set(all.map((t) => t.epic))].sort(byIdAsc).map((e) => ({ id: e, cut: cut(e) })),
      jira: [...new Set(all.map((t) => t.jira).filter(Boolean))],
    };
  });
}

// ---------------------------------------------------------------------------------------------
// CLI
// ---------------------------------------------------------------------------------------------

const BOOL_FLAGS = new Set(['write', 'json', 'system-only', 'chains', 'next-ids', 'fingerprint', 'help']);
const VALUE_FLAGS = new Set(['root', 'prd', 'impact', 'candidate']);

/** `{ _: positionals, <flag>: true | value }`, or `null` on an unknown flag / value flag without a value. */
function parseArgs(argv) {
  const args = { _: [] };
  for (let i = 0; i < argv.length; i += 1) {
    const a = argv[i];
    if (!a.startsWith('--')) { args._.push(a); continue; }
    const key = a.slice(2);
    const next = argv[i + 1];
    if (BOOL_FLAGS.has(key)) args[key] = true;
    else if (VALUE_FLAGS.has(key) && next !== undefined && !next.startsWith('--')) { args[key] = next; i += 1; }
    else return null;
  }
  return args;
}

const USAGE = `usage: backlog-check.mjs [--root <dir>] [--prd <path>] [--write] [--json] [--system-only] [--chains] [--next-ids] [--impact <ids>] [--candidate <dir>] [--fingerprint]
  --root         project root (default: cwd); reads .agents/backlog.md, .agents/backlog/E*.md, docs/PRD.md, docs/discovery.md, docs/architecture.md, docs/map/system.yaml
  --prd          PRD path override (default: the backlog header's **Source PRD:**, else docs/PRD.md)
  --write        regenerate the storymap marker region in .agents/backlog.md and the \`>\` meta line under every Task heading of the Epic files (only when there are no errors)
  --json         print { errors, warnings, notes, outsideCovered } instead of text
  --system-only  validate docs/map/system.yaml alone (used by /architect)
  --chains       print { chains: { <token>: { ids, members, problems } } } as JSON — the Depends-on order /jira sync numbers "k of n" by (read-only)
  --next-ids     print { next, taskNext, tasks: { <id>: { current, source, nextAc, summary, missing } } } as JSON — next free ids + the AC resolver; optional Task ids as positionals filter tasks (read-only)
  --impact       print the impact of changing the comma-separated ids (R-/G-/NFR-/AD-/Task/X-) as JSON (read-only)
  --candidate    validate <dir>/PRD.md + <dir>/backlog.md + <dir>/backlog/E*.md instead of the repo's (also checks the storymap region and renders it in memory); with --write, renders inside <dir> only
  --fingerprint  print the sha256 (12 hex) of .agents/backlog.md (minus its **Last check:** line) + the Epic files, then exit 0 — any backlog generation; refused with --candidate
a pre-Scope backlog (Wave / Slice columns) or one with criteria still in .agents/backlog.md exits 1 in every mode until it is migrated (backlog-migrate.mjs)
exit 0 = no errors · 1 = errors · 2 = usage / missing input`;

function report(result, { json, notes = [] }) {
  const outsideCovered = result.outsideCovered ?? [];
  if (json) { console.log(JSON.stringify({ errors: result.errors, warnings: result.warnings, notes, outsideCovered })); return; }
  for (const e of result.errors) console.log(`error: ${e}`);
  for (const w of result.warnings) console.log(`warning: ${w}`);
  if (outsideCovered.length) console.log(`covered outside the dev backlog: ${outsideCovered.join(', ')}`);
  for (const n of notes) console.log(`note: ${n}`);
  console.log(`backlog-check: ${result.errors.length} error(s), ${result.warnings.length} warning(s)`);
}

/**
 * `checkBacklog` against the project's own sources: the inventory of `root` (loaded here unless the
 * caller already has it) and `docs/map/system.yaml`. A broken system.yaml is an error, not a throw.
 * Adds the one root-aware rule: under `**Detail:** full` every live Task resolves (`resolveTask`)
 * to at least one active criterion. Returns the `checkBacklog` result plus `inventory`.
 */
export function checkAgainstRoot(root, parsed, inventory = loadInventory(root, parsed.sourcePrd ?? 'docs/PRD.md')) {
  const errors = [];
  let system = null;
  try { system = loadSystem(root); } catch (err) { errors.push(err.message); }
  const res = checkBacklog({ backlog: parsed, inventory, system });
  // Under `full` every live Task resolves to ≥ 1 active criterion — from its Epic file or from the
  // approved spec in its Ref (a missing, Draft or criterion-less spec exempts nothing).
  const criteria = [];
  if (parsed.detail === 'full' && !parsed.legacy && !parsed.preScope && !parsed.preDetail && !(parsed.problems ?? []).length) {
    for (const t of parsed.tasks) {
      if (t.withdrawn || resolveTask(root, parsed, t).current.some((a) => !a.withdrawn)) continue;
      criteria.push(`Task ${t.id}: no acceptance criterion (expected - **${t.id}.AC1** — … in ${epicFilePath(parsed, t.epic)}, or an approved spec in Ref)`);
    }
  }
  return { ...res, errors: [...errors, ...res.errors, ...criteria], inventory };
}

export function main(argv = process.argv.slice(2)) {
  const args = parseArgs(argv);
  if (!args || args.help || (args._.length && !args['next-ids'])) { console.error(USAGE); return 2; }
  const root = path.resolve(args.root ?? process.cwd());
  const json = args.json === true;

  if (args['system-only']) {
    let system;
    try { system = loadSystem(root); } catch (err) { report({ errors: [err.message], warnings: [] }, { json }); return 1; }
    if (system === null) { console.error(`backlog-check: docs/map/system.yaml not found under ${root}`); return 2; }
    const res = checkSystem(system);
    report(res, { json });
    return res.errors.length ? 1 : 0;
  }

  if (args.candidate && args.fingerprint) { console.error('backlog-check: --fingerprint is refused with --candidate (fingerprint the installed set)'); return 2; }
  const candidate = args.candidate ? path.resolve(root, args.candidate) : null;
  const backlogPath = candidate ? path.join(candidate, 'backlog.md') : path.join(root, '.agents', 'backlog.md');
  const epicDir = candidate ? path.join(candidate, 'backlog') : path.join(root, EPIC_DIR);
  const { md, epicFiles } = readBacklogFiles(backlogPath, epicDir);
  if (md === null || md.trim() === '') { console.error(`backlog-check: ${candidate ? `${backlogPath}` : '.agents/backlog.md'} not found under ${root}\n${USAGE}`); return 2; }
  if (args.fingerprint) { console.log(backlogFingerprint(md, epicFiles)); return 0; }
  const parsed = parseBacklog(md, { epicFiles });
  if (parsed.legacy && candidate) { console.error('backlog-check: --candidate: legacy WP backlog — a candidate must be a new-format backlog'); return 1; }
  if (parsed.legacy) {
    const msg = 'legacy WP backlog — regenerate with /setup:create-backlog to use Task checks';
    if (json) console.log(JSON.stringify({ errors: [], warnings: [msg], legacy: true })); else console.log(`backlog-check: ${msg}`);
    return 0;
  }
  if (parsed.preScope) {
    if (json) console.log(JSON.stringify({ errors: [PRE_SCOPE_MESSAGE], warnings: [], preScope: true })); else console.log(`backlog-check: ${PRE_SCOPE_MESSAGE}`);
    return 1;
  }
  if (parsed.preDetail) {
    if (json) console.log(JSON.stringify({ errors: [PRE_DETAIL_MESSAGE], warnings: [], preDetail: true })); else console.log(`backlog-check: ${PRE_DETAIL_MESSAGE}`);
    return 1;
  }

  if (args.chains) {
    console.log(JSON.stringify({ chains: Object.fromEntries(chainPaths(parsed.tasks)) }));
    return 0;
  }

  const prdNamed = candidate ? path.join(candidate, 'PRD.md') : args.prd ?? parsed.sourcePrd;
  const prdPath = prdNamed ?? 'docs/PRD.md';
  if (prdNamed && !fs.existsSync(path.resolve(root, prdNamed))) { console.error(`backlog-check: PRD not found at ${prdNamed} (named by ${args.prd ? '--prd' : 'the backlog header'})`); return 2; }

  const inventory = loadInventory(root, prdPath);
  if (args['next-ids']) {
    const out = nextIds(root, parsed, inventory);
    const unknown = args._.filter((id) => !out.tasks[id]);
    if (unknown.length) { console.error(`backlog-check: --next-ids: unknown Task id(s) ${unknown.join(', ')}`); return 2; }
    if (args._.length) out.tasks = Object.fromEntries(args._.map((id) => [id, out.tasks[id]]));
    console.log(JSON.stringify(out));
    return 0;
  }
  if (args.impact) {
    const ids = args.impact.split(',').map((s) => s.trim()).filter(Boolean);
    console.log(JSON.stringify({ impact: impactOf(ids, parsed, readIfExists(path.resolve(root, prdPath))) }));
    return 0;
  }
  const warnings = [];
  if (!inventory.prdExists) warnings.push(`PRD not found at ${prdPath} — requirement coverage not checked`);
  if (inventory.architectureDraft) warnings.push('docs/architecture.md is draft — AD ids not loaded');
  const res = checkAgainstRoot(root, parsed, inventory);
  res.warnings.unshift(...warnings);
  if (!candidate) res.warnings.push(...staleTaskWarnings(parsed.tasks, loadPlanTasks(root)));

  if (candidate && !res.errors.length) {
    // A candidate must be installable: --write would otherwise fail only after the swap.
    try {
      locateRegions(md, ['storymap']);
      replaceRegion(md, 'storymap', renderStoryMap(parsed.tasks, inventory.flows) || '_No flows in docs/discovery.md — no story map._');
    } catch (err) { res.errors.push(`candidate: ${err.message}`); }
  }

  const notes = [];
  if (!res.errors.length && parsed.tasks.length) {
    if (args.write) {
      // Candidate mode renders inside the candidate directory only — the repo files are never touched.
      try {
        locateRegions(md, Object.keys(REGIONS));
        const storyMap = renderStoryMap(parsed.tasks, inventory.flows);
        const next = replaceRegion(md, 'storymap', storyMap || '_No flows in docs/discovery.md — no story map._');
        const changed = epicFiles.map((f) => ({ name: f.name, next: renderEpicFile(f.text, parsed), text: f.text })).filter((f) => f.next !== f.text);
        // Epic files first, backlog.md last: an interrupted write leaves the index stale, never the details.
        for (const f of changed) writeAtomic(path.join(epicDir, f.name), f.next);
        if (next !== md) writeAtomic(backlogPath, next);
        const label = path.relative(root, backlogPath).split(path.sep).join('/');
        notes.push(`wrote the story map into ${label} and the meta lines of ${changed.length} Epic file(s)${next === md && !changed.length ? ' (unchanged)' : ''}`);
      } catch (err) {
        res.errors.push(err.message);
      }
    }
  } else if (args.write && res.errors.length) {
    notes.push('--write skipped: fix the errors first');
  }
  report(res, { json, notes });
  return res.errors.length ? 1 : 0;
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    process.exitCode = main();
  } catch (err) {
    console.error(`backlog-check: ${err.message}`);
    process.exitCode = 1;
  }
}
