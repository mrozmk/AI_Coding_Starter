// Validator + generator for `.agents/backlog.md` (Epics + Tasks) and `docs/map/system.yaml`.
// Owns every check a model must not self-grade: ids, DAG, sizes, trace coverage, system-tree
// integrity, and the derived lanes / story map it writes back into the two marker regions.
// Node builtins only — ships to every downstream (umbrella D4).
//
//   node .claude/lib/backlog-check.mjs [--root <dir>] [--prd <path>] [--write] [--json] [--system-only]
//   exit 0 = no errors · 1 = errors · 2 = usage / missing backlog or system.yaml

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
const LANE_COUNTS = [2, 3, 4];
const CRITICAL_PATH_SHARE = 0.6;

const TASK_ID = /^E\d+-\d+$/;
const EPIC_ID = /^E\d+$/;
const AC_ID = /^E\d+-\d+\.AC\d+$/;
const SLICE = /^(WS|R\d+)$/;
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
const AC_SECTION_HEADING = /^##\s+Acceptance criteria\b/i;
const AC_BLOCK_HEADING = /^###\s+(E\d+-\d+)\b/;
const AC_DEFINITION = /^\s*[-*]\s+\*\*(E\d+-\d+\.AC[^*]*)\*\*/;
// A PRD NFR row whose Requirement cell starts with this is a declared non-applicable characteristic.
const NFR_NOT_APPLICABLE = /^N\/A\b/;
const ARCHITECTURE_DRAFT = /^\*\*Status:\*\*\s*draft\b/im;

// ---------------------------------------------------------------------------------------------
// Markdown helpers
// ---------------------------------------------------------------------------------------------

const splitCells = (line) => line.trim().replace(/^\|/, '').replace(/\|$/, '').split(/(?<!\\)\|/).map((c) => c.trim());
const isSeparator = (line) => /^\s*\|?\s*:?-{3,}/.test(line) && !/[^\s|:-]/.test(line);
export const cleanId = (cell) => (cell ?? '').replace(/[`*]/g, '').trim();
const isNone = (cell) => { const c = cleanId(cell); return c === '' || c === '—' || c === '-'; };
const listCell = (cell) => (isNone(cell) ? [] : cleanId(cell).split(',').map((s) => s.trim()).filter(Boolean));

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

// Every column the checker reads. A table located by its key columns must carry all of them — a
// renamed `Depends on` would otherwise silently turn every dependency into an empty list.
const EPIC_COLUMNS = ['Epic', 'Title', 'Outcome', 'Key assumption', 'Pts', 'Depends on', 'Jira'];
const TASK_COLUMNS = ['ID', 'Epic', 'Task', 'Type', 'Size', 'Pts', 'Depends on', 'Wave', 'Slice', 'Node', 'Traces', 'Status', 'Jira', 'Ref'];
const headerLine = (cols) => `| ${cols.join(' | ')} |`;

// ---------------------------------------------------------------------------------------------
// Backlog
// ---------------------------------------------------------------------------------------------

/** Parse `.agents/backlog.md` into epics, tasks, acceptance criteria and header fields. */
export function parseBacklog(md) {
  const tables = parseTables(md);
  const hasSize = tables.some((t) => t.header.includes('Size'));
  if (/^##\s+Work packages/m.test(md) && !hasSize) return { legacy: true, epics: [], tasks: [], acs: [], problems: [] };

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
  const taskTable = requireTable('Task table', findTable(tables, 'ID', 'Epic', 'Size', 'Pts'), TASK_COLUMNS);

  const epics = (epicTable?.rows ?? []).map((r) => ({
    id: cleanId(r.Epic), title: cleanId(r.Title), pts: Number(cleanId(r.Pts)), deps: listCell(r['Depends on']), line: r._line,
  })).filter((e) => e.id !== '');

  // A withdrawn Task keeps its row (ids are append-only) but is no longer planned work.
  const tasks = (taskTable?.rows ?? []).map((r) => ({
    id: cleanId(r.ID), epic: cleanId(r.Epic), title: cleanId(r.Task), type: cleanId(r.Type), size: cleanId(r.Size),
    pts: Number(cleanId(r.Pts)), deps: listCell(r['Depends on']), wave: cleanId(r.Wave), slice: cleanId(r.Slice),
    node: isNone(r.Node) ? null : cleanId(r.Node), traces: listCell(r.Traces), status: cleanId(r.Status),
    jira: isNone(r.Jira) ? null : cleanId(r.Jira), ref: isNone(r.Ref) ? null : cleanId(r.Ref),
    // Optional columns: a table without them reads as `—` everywhere.
    relates: listCell(r.Relates), chain: isNone(r.Chain) ? null : cleanId(r.Chain),
    withdrawn: /\(withdrawn\)/i.test(r.Task ?? ''), line: r._line,
  })).filter((t) => t.id !== '');

  // /qa-verify reads criteria only from `## Acceptance criteria` → `### <Task id> — …` blocks; a
  // definition anywhere else is recorded with `inSection: false` so the check can reject it.
  const acs = [];
  let block = null;
  let inSection = false;
  md.split(/\r?\n/).forEach((line, idx) => {
    const h = AC_BLOCK_HEADING.exec(line);
    if (h) { block = h[1]; return; }
    if (/^##\s/.test(line)) { block = null; inSection = AC_SECTION_HEADING.test(line); return; }
    const d = AC_DEFINITION.exec(line);
    if (d) acs.push({ id: d[1].trim(), task: d[1].split('.')[0], block, inSection, line: idx + 1 });
  });

  const prd = /\*\*Source PRD:\*\*\s*`([^`]+)`/.exec(md);
  return { legacy: false, epics, tasks, acs, problems, sourcePrd: prd ? prd[1].trim() : null, scopeRev: SCOPE_REV.exec(md)?.[1] ?? null };
}

// ---------------------------------------------------------------------------------------------
// Inventory (PRD + discovery + architecture ids, flows) and system.yaml
// ---------------------------------------------------------------------------------------------

const readIfExists = (p) => (fs.existsSync(p) ? fs.readFileSync(p, 'utf8') : null);

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

/** Every backlog check. `backlog` is the markdown or the `parseBacklog` result. */
export function checkBacklog({ backlog, inventory, system }) {
  const b = typeof backlog === 'string' ? parseBacklog(backlog) : backlog;
  if (b.legacy) return { errors: [], warnings: [], legacy: true };
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
    if (!/^\d+$/.test(t.wave)) errors.push(`Task ${t.id}: Wave ${t.wave || '(empty)'} must be an integer (0 = sequential foundation)`);
    if (!SLICE.test(t.slice)) errors.push(`Task ${t.id}: Slice ${t.slice || '(empty)'} must be WS or R<n>`);
    if (!TASK_STATUSES.has(t.status)) errors.push(`Task ${t.id}: Status ${t.status || '(empty)'} not in TODO/WIP/DONE/BLOCKED`);
    if (sys && t.node && !sys.nodes.has(t.node)) errors.push(`Task ${t.id}: unknown Node ${t.node} (not in docs/map/system.yaml)`);
  }

  // --- tasks: DAG
  for (const t of b.tasks) {
    for (const d of t.deps) {
      if (!taskIds.has(d)) { errors.push(`Task ${t.id}: unknown dependency ${d}`); continue; }
      if (t.wave === '0' && byId.get(d).wave !== '0') errors.push(`Task ${t.id}: Wave-0 Task depends on ${d} (Wave ${byId.get(d).wave}) — foundation cannot wait on later work`);
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

  // --- acceptance criteria
  const acCount = new Map();
  const seenAc = new Set();
  for (const ac of b.acs) {
    if (!AC_ID.test(ac.id)) { errors.push(`malformed AC id ${ac.id} (expected E<n>-<m>.AC<k>)`); continue; }
    if (seenAc.has(ac.id)) errors.push(`duplicate AC definition ${ac.id} (line ${ac.line}) — /qa-verify keys criteria by id`);
    seenAc.add(ac.id);
    if (!taskIds.has(ac.task)) errors.push(`AC ${ac.id}: Task ${ac.task} not in Task table`);
    // Only a criterion where /qa-verify will find it counts toward "Task has ≥1 AC".
    if (!ac.inSection) { errors.push(`${ac.id} defined outside ## Acceptance criteria (line ${ac.line})`); continue; }
    if (ac.block !== ac.task) { errors.push(`AC ${ac.id} defined under the ${ac.block ?? 'section'} heading — expected ### ${ac.task}`); continue; }
    acCount.set(ac.task, (acCount.get(ac.task) ?? 0) + 1);
  }
  for (const t of b.tasks) {
    const n = acCount.get(t.id) ?? 0;
    if (n === 0) errors.push(`Task ${t.id}: no acceptance criterion (expected - **${t.id}.AC1** — …)`);
    if (t.size === 'XH' && t.type === 'story' && n > 5) warnings.push(`Task ${t.id}: XH story with ${n} criteria — split it (workflow steps, business-rule variations, …)`);
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
    if (!t.withdrawn && t.type === 'tech' && t.traces.length === 0) warnings.push(`Task ${t.id}: tech Task with no trace (AD-n / NFR-n)`);
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
      if (def.state === 'active' && /^(R|NFR)-\d+$/.test(id) && !traced.has(id)) errors.push(`${id}: no Task traces it`);
    }
  }
  const liveFlows = inv.flows.filter((f) => !f.withdrawn);
  for (const f of liveFlows.filter((x) => x.critical)) {
    for (const a of f.activities.filter((x) => !x.withdrawn)) {
      if (!live.some((t) => t.slice === 'WS' && t.traces.includes(a.id))) errors.push(`${a.id} (critical flow ${f.id}): no Slice WS Task traces it — the walking skeleton has a gap`);
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
  if (!errors.length && live.length) warnings.push(...scheduleWarnings(live));
  return { errors, warnings, legacy: false };
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

/** Parallelism warnings over a valid DAG: a dominant critical path, and same-wave Tasks on one Node split across lanes. */
function scheduleWarnings(tasks) {
  const warnings = [];
  const schedules = LANE_COUNTS.map((n) => scheduleLanes(tasks, n));
  const { criticalPath } = schedules[0];
  const parallel = tasks.filter((t) => t.wave !== '0');
  const nonFoundation = parallel.reduce((a, t) => a + t.pts, 0);
  if (nonFoundation > 0 && criticalPath.pts > CRITICAL_PATH_SHARE * nonFoundation) {
    warnings.push(`critical path ${criticalPath.ids.join(' → ')} = ${criticalPath.pts} pts, ${Math.round((100 * criticalPath.pts) / nonFoundation)}% of ${nonFoundation} non-foundation pts — too sequential for parallel lanes`);
  }
  const seenPair = new Set();
  const onNode = parallel.filter((t) => t.node);
  schedules.forEach((s, k) => {
    const laneOf = new Map();
    s.lanes.forEach((lane, i) => lane.ids.forEach((id) => laneOf.set(id, i)));
    for (let i = 0; i < onNode.length; i += 1) {
      for (let j = i + 1; j < onNode.length; j += 1) {
        const a = onNode[i]; const c = onNode[j];
        const key = `${a.id}|${c.id}`;
        if (a.wave === c.wave && a.node === c.node && laneOf.get(a.id) !== laneOf.get(c.id) && !seenPair.has(key)) {
          seenPair.add(key);
          warnings.push(`Tasks ${a.id} and ${c.id} share Node ${a.node} in Wave ${a.wave} but land in different lanes (N=${LANE_COUNTS[k]}) — expect merge contention; sequence them or split the node`);
        }
      }
    }
  });
  return warnings;
}

// ---------------------------------------------------------------------------------------------
// Scheduling + rendering
// ---------------------------------------------------------------------------------------------

const taskPts = (t) => (Number.isFinite(t.pts) ? t.pts : pointsOf(t.size) ?? 0);
// Numeric-aware so E1-2 sorts before E1-10.
const byIdAsc = new Intl.Collator('en', { numeric: true }).compare;

function topoOrder(tasks) {
  const ids = new Set(tasks.map((t) => t.id));
  const byId = new Map(tasks.map((t) => [t.id, t]));
  const out = [];
  const done = new Set();
  while (out.length < tasks.length) {
    const ready = tasks.filter((t) => !done.has(t.id) && t.deps.every((d) => !ids.has(d) || done.has(d))).map((t) => t.id).sort(byIdAsc);
    if (!ready.length) throw new Error(`dependency cycle among ${[...ids].filter((i) => !done.has(i)).join(', ')}`);
    out.push(ready[0]);
    done.add(ready[0]);
  }
  return out.map((id) => byId.get(id));
}

/**
 * Wave-0 Tasks run sequentially in one foundation lane; the rest are list-scheduled over the DAG
 * onto `n` lanes: ready Tasks ordered by longest remaining path (pts desc, then id asc), each
 * placed where it can start earliest (ties → lowest lane). Withdrawn Tasks are not planned work and
 * are left out. Deterministic for a given input.
 */
export function scheduleLanes(tasks, n) {
  const planned = tasks.filter((t) => !t.withdrawn);
  const foundation = topoOrder(planned.filter((t) => String(t.wave) === '0'));
  const foundationPts = foundation.reduce((a, t) => a + taskPts(t), 0);
  const rest = planned.filter((t) => String(t.wave) !== '0');
  const restIds = new Set(rest.map((t) => t.id));
  const byId = new Map(rest.map((t) => [t.id, t]));

  const succ = new Map(rest.map((t) => [t.id, []]));
  for (const t of rest) for (const d of t.deps) if (restIds.has(d)) succ.get(d).push(t.id);
  const remaining = new Map();
  const longest = (id) => {
    if (remaining.has(id)) return remaining.get(id);
    remaining.set(id, taskPts(byId.get(id)));
    const v = taskPts(byId.get(id)) + Math.max(0, ...succ.get(id).map(longest));
    remaining.set(id, v);
    return v;
  };
  topoOrder(rest);
  rest.forEach((t) => longest(t.id));

  const lanes = Array.from({ length: Math.max(1, n) }, () => ({ ids: [], pts: 0, free: 0 }));
  const finish = new Map();
  const scheduled = new Set();
  while (scheduled.size < rest.length) {
    const ready = rest.filter((t) => !scheduled.has(t.id) && t.deps.every((d) => !restIds.has(d) || scheduled.has(d)))
      .sort((a, b) => remaining.get(b.id) - remaining.get(a.id) || byIdAsc(a.id, b.id));
    const t = ready[0];
    const depFinish = Math.max(0, ...t.deps.filter((d) => restIds.has(d)).map((d) => finish.get(d)));
    let best = 0;
    for (let i = 1; i < lanes.length; i += 1) if (Math.max(lanes[i].free, depFinish) < Math.max(lanes[best].free, depFinish)) best = i;
    const start = Math.max(lanes[best].free, depFinish);
    lanes[best].ids.push(t.id);
    lanes[best].pts += taskPts(t);
    lanes[best].free = start + taskPts(t);
    finish.set(t.id, lanes[best].free);
    scheduled.add(t.id);
  }

  let head = null;
  for (const t of rest) if (!head || remaining.get(t.id) > remaining.get(head) || (remaining.get(t.id) === remaining.get(head) && byIdAsc(t.id, head) < 0)) head = t.id;
  const criticalIds = [];
  for (let cur = head; cur; ) {
    criticalIds.push(cur);
    const next = succ.get(cur).filter((s) => remaining.get(s) === remaining.get(cur) - taskPts(byId.get(cur))).sort(byIdAsc);
    cur = next[0] ?? null;
  }
  return {
    foundation: foundation.map((t) => t.id),
    foundationPts,
    lanes: lanes.map((l) => ({ ids: l.ids, pts: l.pts })),
    makespan: Math.max(0, ...lanes.map((l) => l.free)),
    criticalPath: { ids: criticalIds, pts: head ? remaining.get(head) : 0 },
  };
}

/** Markdown for the `lanes` region: foundation, then one table per N = 2, 3, 4. */
export function renderLanes(tasks) {
  const schedules = LANE_COUNTS.map((n) => scheduleLanes(tasks, n));
  const base = schedules[0];
  const out = [];
  out.push(base.foundation.length
    ? `**Foundation (Wave 0, sequential):** ${base.foundation.join(' → ')} · ${base.foundationPts} pts`
    : '**Foundation (Wave 0):** none');
  if (base.lanes.every((l) => !l.ids.length)) out.push('', 'No parallel work yet — foundation only.');
  else {
    schedules.forEach((s, k) => {
      out.push('', `### N = ${LANE_COUNTS[k]} developers`, '', '| Lane | Tasks | Pts |', '|------|-------|-----|');
      s.lanes.forEach((l, i) => out.push(`| ${i + 1} | ${l.ids.length ? l.ids.join(', ') : '—'} | ${l.pts} |`));
      out.push('', `Makespan: ${s.makespan} pts after the foundation · critical path: ${s.criticalPath.ids.join(' → ')} (${s.criticalPath.pts} pts)`);
    });
  }
  // Chains are advisory: printed so a human sees where the lanes split them, never scheduled.
  const chains = chainPaths(tasks);
  if (chains.size) {
    const byId = new Map(tasks.map((t) => [t.id, t]));
    out.push('', '### Chains (advisory — one developer, in order)', '', '| Chain | Order | Pts |', '|-------|-------|-----|');
    for (const [token, ch] of chains) {
      const pts = ch.ids.filter((id) => !byId.get(id).withdrawn).reduce((a, id) => a + taskPts(byId.get(id)), 0);
      out.push(`| ${token} | ${ch.ids.join(' → ')} | ${pts} |`);
    }
  }
  return out.join('\n');
}

const sliceOrder = (a, b) => {
  if (a === b) return 0;
  if (a === 'WS') return -1;
  if (b === 'WS') return 1;
  return Number(a.slice(1)) - Number(b.slice(1)) || byIdAsc(a, b);
};

/** Markdown for the `storymap` region: one table per flow (critical first), slices × activities. */
export function renderStoryMap(tasks, flows) {
  const live = (flows ?? []).filter((f) => !f.withdrawn);
  if (!live.length) return '';
  const planned = tasks.filter((t) => !t.withdrawn);
  const ordered = [...live.filter((f) => f.critical), ...live.filter((f) => !f.critical)];
  const slices = [...new Set(planned.map((t) => t.slice).filter((s) => SLICE.test(s)))].sort(sliceOrder);
  const out = [];
  for (const f of ordered) {
    const acts = f.activities.filter((a) => !a.withdrawn);
    out.push(`### ${f.id} — ${f.name || f.id}${f.critical ? ' (critical)' : ''}`, '');
    if (!acts.length) { out.push('_No backbone activities in docs/discovery.md._', ''); continue; }
    out.push(`| Slice | ${acts.map((a) => (a.name ? `${a.id} ${a.name}` : a.id)).join(' | ')} |`);
    out.push(`|-------|${acts.map(() => '---').join('|')}|`);
    for (const s of slices) {
      const cells = acts.map((a) => planned.filter((t) => t.slice === s && t.traces.includes(a.id)).map((t) => t.id).join(', ') || '—');
      out.push(`| ${s} | ${cells.join(' | ')} |`);
    }
    out.push('');
  }
  return out.join('\n').trimEnd();
}

const escapeRegExp = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');

/** The two regions `--write` regenerates in `.agents/backlog.md`, with their literal markers. */
export const REGIONS = {
  lanes: { begin: '<!-- lanes:begin -->', end: '<!-- lanes:end -->' },
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

// ---------------------------------------------------------------------------------------------
// CLI
// ---------------------------------------------------------------------------------------------

const BOOL_FLAGS = new Set(['write', 'json', 'system-only', 'chains', 'help']);
const VALUE_FLAGS = new Set(['root', 'prd']);

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

const USAGE = `usage: backlog-check.mjs [--root <dir>] [--prd <path>] [--write] [--json] [--system-only] [--chains]
  --root         project root (default: cwd); reads .agents/backlog.md, docs/PRD.md, docs/discovery.md, docs/architecture.md, docs/map/system.yaml
  --prd          PRD path override (default: the backlog header's **Source PRD:**, else docs/PRD.md)
  --write        regenerate the lanes / storymap marker regions in .agents/backlog.md (only when there are no errors)
  --json         print { errors, warnings, lanes } instead of text
  --system-only  validate docs/map/system.yaml alone (used by /architect)
  --chains       print { chains: { <token>: { ids, members, problems } } } as JSON — the Depends-on order /jira sync numbers "k of n" by (read-only)
exit 0 = no errors · 1 = errors · 2 = usage / missing input`;

function report(result, { json, lanes = null, notes = [] }) {
  if (json) { console.log(JSON.stringify({ errors: result.errors, warnings: result.warnings, lanes, notes })); return; }
  for (const e of result.errors) console.log(`error: ${e}`);
  for (const w of result.warnings) console.log(`warning: ${w}`);
  for (const n of notes) console.log(`note: ${n}`);
  console.log(`backlog-check: ${result.errors.length} error(s), ${result.warnings.length} warning(s)`);
}

export function main(argv = process.argv.slice(2)) {
  const args = parseArgs(argv);
  if (!args || args.help || args._.length) { console.error(USAGE); return 2; }
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

  const backlogPath = path.join(root, '.agents', 'backlog.md');
  const md = readIfExists(backlogPath);
  if (md === null || md.trim() === '') { console.error(`backlog-check: .agents/backlog.md not found under ${root}\n${USAGE}`); return 2; }
  const parsed = parseBacklog(md);
  if (parsed.legacy) {
    const msg = 'legacy WP backlog — regenerate with /setup:create-backlog to use Task checks';
    if (json) console.log(JSON.stringify({ errors: [], warnings: [msg], lanes: null, legacy: true })); else console.log(`backlog-check: ${msg}`);
    return 0;
  }

  if (args.chains) {
    console.log(JSON.stringify({ chains: Object.fromEntries(chainPaths(parsed.tasks)) }));
    return 0;
  }

  const prdNamed = args.prd ?? parsed.sourcePrd;
  const prdPath = prdNamed ?? 'docs/PRD.md';
  if (prdNamed && !fs.existsSync(path.resolve(root, prdNamed))) { console.error(`backlog-check: PRD not found at ${prdNamed} (named by ${args.prd ? '--prd' : 'the backlog header'})`); return 2; }

  const inventory = loadInventory(root, prdPath);
  const warnings = [];
  if (!inventory.prdExists) warnings.push(`PRD not found at ${prdPath} — requirement coverage not checked`);
  if (inventory.architectureDraft) warnings.push('docs/architecture.md is draft — AD ids not loaded');
  let system = null;
  const errors = [];
  try { system = loadSystem(root); } catch (err) { errors.push(err.message); }

  const res = checkBacklog({ backlog: parsed, inventory, system });
  res.errors.unshift(...errors);
  res.warnings.unshift(...warnings);

  let lanes = null;
  const notes = [];
  if (!res.errors.length && parsed.tasks.length) {
    lanes = Object.fromEntries(LANE_COUNTS.map((n) => [n, scheduleLanes(parsed.tasks, n)]));
    if (args.write) {
      try {
        locateRegions(md, Object.keys(REGIONS));
        let next = replaceRegion(md, 'lanes', renderLanes(parsed.tasks));
        const storyMap = renderStoryMap(parsed.tasks, inventory.flows);
        next = replaceRegion(next, 'storymap', storyMap || '_No flows in docs/discovery.md — no story map._');
        if (next !== md) fs.writeFileSync(backlogPath, next);
        notes.push(`wrote lanes + story map into .agents/backlog.md${next === md ? ' (unchanged)' : ''}`);
      } catch (err) {
        res.errors.push(err.message);
      }
    }
  } else if (args.write && res.errors.length) {
    notes.push('--write skipped: fix the errors first');
  }
  report(res, { json, lanes, notes });
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
