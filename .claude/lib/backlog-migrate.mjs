// One-off migration of a pre-Scope `.agents/backlog.md` (Task table on `Wave` + `Slice`) to the
// `Scope` column. Mechanical only — it never judges content: `Wave 0` → CORE, a Slice named in
// `--could` → COULD, every other Task → MUST; drops the `Wave` / `Slice` columns and the
// `## Parallel plan` section, adds an empty `## Outside the dev backlog`. The transformed text is
// validated with backlog-check before anything is written; a refusal leaves the file byte-identical.
// Which Tasks really are CORE, and which are non-developer work, is a /check-backlog finding.
// Node builtins only — ships to every downstream.
//
//   node .claude/lib/backlog-migrate.mjs [--root <dir>] [--could <slice,…>] [--write]
//   exit 0 = migrated (or already migrated) · 1 = refused, nothing written · 2 = usage / missing
//   backlog / unknown --could slice

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  checkAgainstRoot, cleanId, findTaskTable, headerLine, OUTSIDE_COLUMNS, OUTSIDE_HEADING, parseBacklog,
  parseTables, renderStoryMap, replaceRegion, REGIONS, SCOPES, splitCells, writeAtomic,
} from './backlog-check.mjs';

const PARALLEL_HEADING = /^##\s+Parallel plan\b/;
const BLOCKERS_HEADING = /^##\s+External blockers\b/;
const OUTSIDE_BLOCK = [
  '## Outside the dev backlog',
  headerLine(OUTSIDE_COLUMNS),
  `|${OUTSIDE_COLUMNS.map((c) => '-'.repeat(c.length + 2)).join('|')}|`,
  '',
];
export const NOTES = [
  'CORE is only the former Wave 0 — review CORE and non-developer Tasks with /check-backlog',
  'header notes that explain Wave / Slice are prose and were not changed',
  "issues already created by /github-sync report 'changed since sync' from now on — expected, the sync is create-only",
];

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
 * Pure text migration. Returns `{ md, summary }`; `summary.alreadyMigrated` is true (and `md` the
 * input) when the Task table already carries `Scope`. Throws `MigrateStop` on every refusal.
 */
export function migrate(md, { could = [] } = {}) {
  const parsed = parseBacklog(md);
  if (parsed.legacy) throw new MigrateStop(1, 'legacy WP backlog — regenerate with /setup:create-backlog');
  const tables = parseTables(md);
  const table = findTaskTable(tables);
  if (!parsed.preScope) {
    if (table && table.header.includes('Scope')) return { md, summary: { alreadyMigrated: true } };
    const problems = parsed.problems?.length ? parsed.problems : ['no pre-Scope Task table found (expected `Wave` / `Slice` columns)'];
    throw new MigrateStop(1, problems);
  }

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

  return { md: out.join('\n'), summary: { alreadyMigrated: false, scopes, removed, added, could: [...couldSet] } };
}

/** The summary lines printed by a dry run and by `--write`. */
export function summaryLines(summary, { write, storyMap }) {
  const { scopes } = summary;
  return [
    write ? 'backlog-migrate: wrote .agents/backlog.md' : 'backlog-migrate: dry run — nothing written (re-run with --write to apply)',
    `Tasks per scope: ${SCOPES.map((s) => `${s} ${scopes[s].length}`).join(' · ')}`,
    `CORE: ${scopes.CORE.join(', ') || '—'}`,
    `removed: ${summary.removed.join(', ')}`,
    `added: ${summary.added.join(', ')}`,
    ...(storyMap ? [`story map: ${write ? 'regenerated' : 'would be regenerated'}`] : []),
    ...NOTES.map((n) => `note: ${n}`),
  ];
}

// ---------------------------------------------------------------------------------------------
// CLI
// ---------------------------------------------------------------------------------------------

const USAGE = `usage: backlog-migrate.mjs [--root <dir>] [--could <slice,…>] [--write]
  --root   project root (default: cwd); migrates <root>/.agents/backlog.md
  --could  comma-separated Slice values whose Tasks become COULD (default: none)
  --write  apply the migration (default: dry run — print the summary, write nothing)
one-off: Wave 0 → CORE, a Slice in --could → COULD, every other Task → MUST; drops the Wave / Slice
columns and ## Parallel plan, adds ## Outside the dev backlog; the result must pass backlog-check
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
  const md = fs.existsSync(file) ? fs.readFileSync(file, 'utf8') : null;
  if (md === null || md.trim() === '') { console.error(`backlog-migrate: .agents/backlog.md not found under ${root}\n${USAGE}`); return 2; }

  let result;
  try {
    result = migrate(md, { could: args.could });
  } catch (err) {
    if (!(err instanceof MigrateStop)) throw err;
    for (const l of err.lines) console.log(`backlog-migrate: ${l}`);
    return err.code;
  }
  if (result.summary.alreadyMigrated) { console.log('backlog-migrate: already migrated — nothing to do'); return 0; }

  const parsed = parseBacklog(result.md);
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
