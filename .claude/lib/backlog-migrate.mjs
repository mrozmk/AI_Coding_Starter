// One-off migration of an older `.agents/backlog.md`. Two independent mechanical transforms, each
// applied only when its trigger holds:
//   Scope — a pre-Scope Task table (`Wave` + `Slice`) moves to the `Scope` column: `Wave 0` → CORE,
//     a Slice named in `--could` → COULD, every other Task → MUST; drops the `Wave` / `Slice` columns
//     and the `## Parallel plan` section, adds an empty `## Outside the dev backlog`.
//   criteria — a `## Acceptance criteria` section in backlog.md moves into one Epic file per Epic
//     (`.agents/backlog/E<n>-<slug>.md`): every block verbatim under its Task heading, and the
//     header gains `**Detail:** full`.
// It never judges content and never writes a Summary, a Goal or a criterion of its own. The result
// (backlog.md + Epic files) is validated with backlog-check before anything is written; a refusal
// leaves every file byte-identical. Which Tasks really are CORE, and which are non-developer work,
// is a /check-backlog finding. Node builtins only — ships to every downstream.
//
//   node .claude/lib/backlog-migrate.mjs [--root <dir>] [--could <slice,…>] [--write]
//   exit 0 = migrated (or already migrated) · 1 = refused, nothing written · 2 = usage / missing
//   backlog / unknown --could slice

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  AC_BLOCK_HEADING, AC_DEFINITION, AC_SECTION_HEADING, checkAgainstRoot, cleanId, EPIC_DIR, epicFileName, epicOfFile,
  fenceMask, fenceScanner,
  findTaskTable, headerLine, OUTSIDE_COLUMNS, OUTSIDE_HEADING, parseBacklog, parseTables, readBacklogFiles, renderMeta,
  renderStoryMap, replaceRegion, REGIONS, SCOPES, splitCells, writeAtomic,
} from './backlog-check.mjs';

const PARALLEL_HEADING = /^##\s+Parallel plan\b/;
const BLOCKERS_HEADING = /^##\s+External blockers\b/;
const DETAIL_FIELD = /(\*\*Detail:\*\*[ \t]*)\S*/;
const OUTSIDE_BLOCK = [
  '## Outside the dev backlog',
  headerLine(OUTSIDE_COLUMNS),
  `|${OUTSIDE_COLUMNS.map((c) => '-'.repeat(c.length + 2)).join('|')}|`,
  '',
];
const SCOPE_NOTES = [
  'CORE is only the former Wave 0 — review CORE and non-developer Tasks with /check-backlog',
  'header notes that explain Wave / Slice are prose and were not changed',
];
const SCOPE_SYNC_NOTE = "issues already created by /github-sync report 'changed since sync' from now on — expected, the sync is create-only";
const CRITERIA_SYNC_NOTE = "issues already created by /github-sync report 'changed since sync' because the criteria source path changed — expected, the sync is create-only";
const BOTH_SYNC_NOTE = "issues already created by /github-sync report 'changed since sync' from now on (Scope column, criteria source path) — expected, the sync is create-only";
// The notes a run with both transforms prints (one sync note for the two causes).
export const NOTES = [...SCOPE_NOTES, BOTH_SYNC_NOTE];

/** A refusal: `code` is the exit code, `lines` the messages; nothing has been written. */
export class MigrateStop extends Error {
  constructor(code, lines) {
    const list = Array.isArray(lines) ? lines : [lines];
    super(list.join('\n'));
    this.code = code;
    this.lines = list;
  }
}

/**
 * Pure migration. Returns `{ md, epicFiles, summary }`: `epicFiles` are the Epic files the criteria
 * transform produces, `{ name, epic, text }` (`[]` when it does not run); `summary.alreadyMigrated` is true (and `md` the
 * input) when neither transform's trigger holds and the Task table already carries `Scope`.
 * `epicFiles` in the options are the existing files of `.agents/backlog/` — one for a produced Epic
 * must already be byte-identical (a rerun after an interrupted write). Throws `MigrateStop` on every
 * refusal.
 */
export function migrate(md, { could = [], epicFiles = [] } = {}) {
  const parsed = parseBacklog(md);
  if (parsed.legacy) throw new MigrateStop(1, 'legacy WP backlog — regenerate with /setup:create-backlog');
  const hasSection = (text) => { const lines = text.split('\n'); const fenced = fenceMask(lines); return lines.some((l, i) => !fenced[i] && AC_SECTION_HEADING.test(l)); };
  if (!parsed.preScope && !hasSection(md)) {
    const table = findTaskTable(parseTables(md));
    if (table && table.header.includes('Scope')) return { md, epicFiles: [], summary: { alreadyMigrated: true } };
    const problems = parsed.problems?.length ? parsed.problems : ['no pre-Scope Task table found (expected `Wave` / `Slice` columns)'];
    throw new MigrateStop(1, problems);
  }
  // The Scope transform adds { scopes, removed, added, could }, the criteria transform `criteria`.
  const summary = { alreadyMigrated: false, criteria: null };
  let text = md;
  if (parsed.preScope) {
    const scope = migrateScope(md, could);
    text = scope.md;
    Object.assign(summary, scope.summary);
  }
  let produced = [];
  if (hasSection(text)) {
    const criteria = migrateCriteria(text, epicFiles);
    text = criteria.md;
    produced = criteria.epicFiles;
    summary.criteria = criteria.summary;
  }
  return { md: text, epicFiles: produced, summary };
}

/** The Scope transform of a pre-Scope backlog: `Wave` / `Slice` → `Scope`. */
function migrateScope(md, could) {
  const table = findTaskTable(parseTables(md));
  const col = (name) => table.header.indexOf(name);
  const [waveAt, sliceAt, idAt] = [col('Wave'), col('Slice'), col('ID')];
  const width = table.header.length;
  const lines = md.split('\n');
  const cellsOf = (lineNo) => splitCells(lines[lineNo - 1]);

  // Every row must have the header's cell count — otherwise a cell would be read through the wrong name.
  const ragged = table.rows.filter((r) => cellsOf(r._line).length !== width)
    .map((r) => `Task table line ${r._line}: ${cellsOf(r._line).length} cell(s), header has ${width}`);
  if (ragged.length) throw new MigrateStop(1, ragged);

  const cell = (r, at) => (at === -1 ? '' : cleanId(cellsOf(r._line)[at]));
  const present = [...new Set(table.rows.map((r) => cell(r, sliceAt)).filter(Boolean))];
  const unknown = could.filter((s) => !present.includes(s));
  if (unknown.length) throw new MigrateStop(2, unknown.map((s) => `--could: unknown slice ${s} (present: ${present.join(', ') || 'none'})`));
  const couldSet = new Set(could);

  const scopes = Object.fromEntries(SCOPES.map((s) => [s, []]));
  const conflicts = [];
  const scopeOf = new Map();
  for (const r of table.rows) {
    const id = cell(r, idAt);
    const core = cell(r, waveAt) === '0';
    const optional = couldSet.has(cell(r, sliceAt));
    if (core && optional) conflicts.push(`Task ${id || `(line ${r._line})`}: Wave 0 (CORE) but its Slice ${cell(r, sliceAt)} is in --could — change the --could selection or the Wave first`);
    const scope = core ? 'CORE' : optional ? 'COULD' : 'MUST';
    scopeOf.set(r._line, scope);
    if (id) scopes[scope].push(id);
  }
  if (conflicts.length) throw new MigrateStop(1, conflicts);

  // Rewrite header, separator and rows: Wave → Scope, Slice dropped, every other cell kept as text.
  const rewrite = (lineNo, value) => {
    const raw = lines[lineNo - 1];
    const cr = raw.endsWith('\r') ? '\r' : '';
    const cells = splitCells(raw);
    if (waveAt !== -1) cells[waveAt] = value;
    const kept = cells.filter((_, k) => k !== sliceAt);
    // A table with Slice but no Wave gains Scope where Slice stood.
    if (waveAt === -1) kept.splice(sliceAt, 0, value);
    lines[lineNo - 1] = `| ${kept.join(' | ')} |${cr}`;
  };
  rewrite(table.line, 'Scope');
  rewrite(table.line + 1, '-------');
  for (const r of table.rows) rewrite(r._line, scopeOf.get(r._line));

  const removed = ['Wave and Slice columns'];
  const added = ['Scope column'];
  let out = lines;
  const start = out.findIndex((l) => PARALLEL_HEADING.test(l));
  if (start !== -1) {
    let stop = out.findIndex((l, i) => i > start && /^## /.test(l));
    if (stop === -1) stop = out.length;
    out = [...out.slice(0, start), ...out.slice(stop)];
    removed.push('## Parallel plan');
  }

  if (!out.some((l) => OUTSIDE_HEADING.test(l))) {
    const cr = md.includes('\r\n') ? '\r' : '';
    const block = OUTSIDE_BLOCK.map((l) => `${l}${cr}`);
    const at = out.findIndex((l) => BLOCKERS_HEADING.test(l));
    if (at !== -1) out = [...out.slice(0, at), ...block, ...out.slice(at)];
    else {
      // At the end of the file: one blank line before the heading, the file ends on a newline.
      while (out.length && out[out.length - 1].replace('\r', '') === '') out.pop();
      out = [...out, cr, ...block.slice(0, -1), ''];
    }
    added.push('## Outside the dev backlog');
  }

  return { md: out.join('\n'), summary: { scopes, removed, added, could: [...couldSet] } };
}

/**
 * The criteria transform: cut every `## Acceptance criteria` section, then write each `### <Task id>`
 * block verbatim under its Task heading in its Epic file (Tasks in table order; a withdrawn Task only
 * when it has a block) and set `**Detail:** full`. Epics and Tasks come from `parseBacklog` of the
 * text without the section — never a second table reader.
 */
function migrateCriteria(md, existing) {
  const eol = md.includes('\r\n') ? '\r\n' : '\n';
  const strip = (l) => l.replace(/\r$/, '');
  // Every line keeps its 1-based number in `md`, so a refusal names it even after earlier cuts.
  let rows = md.split('\n').map((raw, k) => ({ raw, line: k + 1 }));
  // Headings inside a fenced example are text: they neither open nor end a section.
  const unfenced = (test) => { const fenced = fenceMask(rows.map((r) => strip(r.raw))); return (r, i) => !fenced[i] && test(r, i); };
  const nextSection = () => rows.findIndex(unfenced((r) => AC_SECTION_HEADING.test(strip(r.raw))));
  const section = [];
  for (let start = nextSection(); start !== -1; start = nextSection()) {
    let stop = rows.findIndex(unfenced((r, i) => i > start && /^## /.test(r.raw)));
    const atEnd = stop === -1;
    if (atEnd) stop = rows.length;
    section.push(...rows.slice(start + 1, stop).map((r) => ({ text: strip(r.raw), line: r.line })));
    rows = [...rows.slice(0, start), ...rows.slice(stop)];
    if (atEnd) {
      // The section ended the file: the text still ends on one newline.
      while (rows.length && strip(rows[rows.length - 1].raw) === '') rows.pop();
      rows.push({ raw: '', line: null });
    }
  }
  const lines = rows.map((r) => r.raw);

  // Blocks: a `### <Task id>` heading plus every line up to the next `###` / `##`.
  const blocks = new Map();
  const stray = [];
  let open = null;
  const scan = fenceScanner();
  for (const { text, line } of section) {
    // A fenced example stays whole in its block: nothing inside it is a block heading.
    if (scan(text)) {
      if (open) open.lines.push(text);
      else if (text.trim() !== '') stray.push(`Acceptance criteria line ${line}: text outside any \`### <Task id>\` block — move it into its Task's block first`);
      continue;
    }
    const h = AC_BLOCK_HEADING.exec(text);
    if (h) {
      if (blocks.has(h[1])) stray.push(`Acceptance criteria line ${line}: a second block for Task ${h[1]} — merge the two blocks first`);
      open = { id: h[1], line, lines: [] };
      blocks.set(h[1], open);
      continue;
    }
    if (/^###\s/.test(text)) { open = null; stray.push(`Acceptance criteria line ${line}: \`${text.trim()}\` is no Task block heading (\`### E<n>-<m> — …\`)`); continue; }
    if (open) { open.lines.push(text); continue; }
    if (text.trim() === '') continue;
    stray.push(`Acceptance criteria line ${line}: ${AC_DEFINITION.test(text) ? 'a criterion' : 'text'} outside any \`### <Task id>\` block — move it into its Task's block first`);
  }

  let text = lines.join('\n');
  const parsed = parseBacklog(text);
  if (parsed.problems.length) throw new MigrateStop(1, parsed.problems);
  const known = new Set(parsed.tasks.map((t) => t.id));
  for (const b of blocks.values()) {
    if (!known.has(b.id)) stray.push(`Acceptance criteria line ${b.line}: block for Task ${b.id}, which is not in the Task table`);
  }
  if (stray.length) throw new MigrateStop(1, stray);

  const epicFiles = [];
  let moved = 0;
  let withBlock = 0;
  const unescape = (s) => s.replace(/\\\|/g, '|');
  for (const epic of parsed.epics) {
    const tasks = parsed.tasks.filter((t) => t.epic === epic.id && (!t.withdrawn || blocks.has(t.id)));
    if (!tasks.length) continue;
    const out = [`# ${epic.id} — ${unescape(epic.title)}`];
    for (const t of tasks) {
      out.push('', `## ${t.id} — ${unescape(t.title)}`, renderMeta(t), '### Acceptance criteria');
      const block = blocks.get(t.id);
      if (!block) continue;
      const body = [...block.lines];
      while (body.length && body[body.length - 1].trim() === '') body.pop();
      out.push(...body);
      moved += body.filter((l) => AC_DEFINITION.test(l)).length;
      withBlock += 1;
    }
    epicFiles.push({ name: epicFileName(epic.id, epic.title), epic: epic.id, text: `${out.join(eol)}${eol}` });
  }
  // A Task whose Epic is missing from the Epic map has no file to go to.
  const placed = new Set(epicFiles.map((f) => f.epic));
  const orphans = parsed.tasks.filter((t) => !placed.has(t.epic) && (!t.withdrawn || blocks.has(t.id)));
  if (orphans.length) throw new MigrateStop(1, orphans.map((t) => `Task ${t.id}: Epic ${t.epic} is not in the Epic map — no Epic file to move its criteria to`));

  // An existing file of a produced Epic must be the produced text (an interrupted earlier run).
  const differs = [];
  for (const f of existing) {
    const mine = epicFiles.find((p) => p.epic === epicOfFile(f.name));
    if (mine && (mine.name !== f.name || mine.text !== f.text)) {
      differs.push(`Epic file ${f.name} already exists and differs — move its content or remove it, then rerun`);
    }
  }
  if (differs.length) throw new MigrateStop(1, differs);

  text = setDetailFull(text);
  return {
    md: text,
    epicFiles,
    summary: { files: epicFiles.map((f) => f.name), moved, tasks: withBlock },
  };
}

/** `**Detail:** full` in the header (above the first `## `): an existing field is set, else appended. */
function setDetailFull(md) {
  const lines = md.split('\n');
  let end = lines.findIndex((l) => l.startsWith('## '));
  if (end === -1) end = lines.length;
  const cr = (l) => (l.endsWith('\r') ? '\r' : '');
  const at = lines.slice(0, end).findIndex((l) => DETAIL_FIELD.test(l));
  if (at !== -1) {
    lines[at] = lines[at].replace(DETAIL_FIELD, '$1full');
    return lines.join('\n');
  }
  const host = lines.slice(0, end).findIndex((l) => l.includes('**Scope rev:**') || l.includes('**Source PRD:**'));
  if (host !== -1) {
    const l = lines[host];
    lines[host] = `${l.replace(/\r$/, '')} · **Detail:** full${cr(l)}`;
    return lines.join('\n');
  }
  const title = lines.slice(0, end).findIndex((l) => /^#\s/.test(l));
  const crlf = md.includes('\r\n') ? '\r' : '';
  lines.splice(title + 1, 0, `**Detail:** full${crlf}`);
  return lines.join('\n');
}

/** The summary lines printed by a dry run and by `--write`. */
export function summaryLines(summary, { write, storyMap }) {
  const { scopes, criteria } = summary;
  const files = criteria?.files ?? [];
  const wrote = `backlog-migrate: wrote .agents/backlog.md${files.length ? ` and ${files.length} Epic file(s) in .agents/backlog/` : ''}`;
  return [
    write ? wrote : 'backlog-migrate: dry run — nothing written (re-run with --write to apply)',
    ...(scopes ? [
      `Tasks per scope: ${SCOPES.map((s) => `${s} ${scopes[s].length}`).join(' · ')}`,
      `CORE: ${scopes.CORE.join(', ') || '—'}`,
      `removed: ${summary.removed.join(', ')}`,
      `added: ${summary.added.join(', ')}`,
    ] : []),
    ...(criteria ? [
      `Epic files: ${files.length} (${files.slice(0, 3).join(', ')}${files.length > 3 ? ', …' : ''})`,
      `criteria moved: ${criteria.moved} in ${criteria.tasks} Tasks`,
      'Detail: full',
    ] : []),
    ...(storyMap ? [`story map: ${write ? 'regenerated' : 'would be regenerated'}`] : []),
    ...(scopes ? SCOPE_NOTES : []).map((n) => `note: ${n}`),
    `note: ${scopes && criteria ? BOTH_SYNC_NOTE : scopes ? SCOPE_SYNC_NOTE : CRITERIA_SYNC_NOTE}`,
  ];
}

// ---------------------------------------------------------------------------------------------
// CLI
// ---------------------------------------------------------------------------------------------

const USAGE = `usage: backlog-migrate.mjs [--root <dir>] [--could <slice,…>] [--write]
  --root   project root (default: cwd); migrates <root>/.agents/backlog.md (+ <root>/.agents/backlog/)
  --could  comma-separated Slice values whose Tasks become COULD (default: none)
  --write  apply the migration (default: dry run — print the summary, write nothing)
one-off, each part only when needed: Wave 0 → CORE, a Slice in --could → COULD, every other Task → MUST;
drops the Wave / Slice columns and ## Parallel plan, adds ## Outside the dev backlog; moves
## Acceptance criteria into .agents/backlog/E<n>-<slug>.md and sets **Detail:** full; the result
must pass backlog-check
exit 0 = migrated or already migrated · 1 = refused (nothing written) · 2 = usage / missing backlog / unknown --could slice`;

function parseArgs(argv) {
  const args = { could: [] };
  for (let i = 0; i < argv.length; i += 1) {
    const a = argv[i];
    const next = argv[i + 1];
    if (a === '--write') args.write = true;
    else if (a === '--help') return null;
    else if ((a === '--root' || a === '--could') && next !== undefined && !next.startsWith('--')) {
      if (a === '--root') args.root = next;
      else args.could.push(...next.split(',').map((s) => s.trim()).filter(Boolean));
      i += 1;
    } else return null;
  }
  return args;
}

export function main(argv = process.argv.slice(2)) {
  const args = parseArgs(argv);
  if (!args) { console.error(USAGE); return 2; }
  const root = path.resolve(args.root ?? process.cwd());
  const file = path.join(root, '.agents', 'backlog.md');
  const epicDir = path.join(root, EPIC_DIR);
  const { md, epicFiles: existing } = readBacklogFiles(file, epicDir);
  if (md === null || md.trim() === '') { console.error(`backlog-migrate: .agents/backlog.md not found under ${root}\n${USAGE}`); return 2; }

  let result;
  try {
    result = migrate(md, { could: args.could, epicFiles: existing });
  } catch (err) {
    if (!(err instanceof MigrateStop)) throw err;
    for (const l of err.lines) console.log(`backlog-migrate: ${l}`);
    return err.code;
  }
  if (result.summary.alreadyMigrated) { console.log('backlog-migrate: already migrated — nothing to do'); return 0; }

  // Validate the set as it will be on disk: the produced Epic files plus every untouched one.
  const producedEpics = new Set(result.epicFiles.map((f) => f.epic));
  const set = [...existing.filter((f) => !producedEpics.has(epicOfFile(f.name))), ...result.epicFiles];
  const parsed = parseBacklog(result.md, { epicFiles: set });
  const { errors, warnings, inventory } = checkAgainstRoot(root, parsed);
  if (errors.length) {
    console.log('backlog-migrate: migration would produce an invalid backlog:');
    for (const e of errors) console.log(`error: ${e}`);
    console.log('backlog-migrate: nothing written — change the --could selection or fix the source classification first');
    return 1;
  }

  let next = result.md;
  const { begin, end } = REGIONS.storymap;
  const storyMap = next.includes(begin) || next.includes(end);
  if (storyMap) {
    try {
      next = replaceRegion(next, 'storymap', renderStoryMap(parsed.tasks, inventory.flows) || '_No flows in docs/discovery.md — no story map._');
    } catch (err) {
      console.log(`backlog-migrate: story map: ${err.message} — nothing written`);
      return 1;
    }
  }
  if (args.write) {
    // Epic files first, backlog.md last: an interrupted run leaves the old index, which reruns cleanly.
    const before = new Map(existing.map((f) => [f.name, f.text]));
    for (const f of result.epicFiles) if (before.get(f.name) !== f.text) writeAtomic(path.join(epicDir, f.name), f.text);
    writeAtomic(file, next);
  }
  for (const w of warnings) console.log(`warning: ${w}`);
  for (const l of summaryLines(result.summary, { write: args.write === true, storyMap })) console.log(l);
  return 0;
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    process.exitCode = main();
  } catch (err) {
    console.error(`backlog-migrate: ${err.message}`);
    process.exitCode = 1;
  }
}
