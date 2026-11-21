#!/usr/bin/env node
// github-sync.mjs — mirror `.agents/backlog.md` Epics and Tasks into GitHub issues: Epics as issues,
// Tasks as their sub-issues, every issue added to the profile's Project (when it has one).
// One-way and create-only: an existing issue is never edited, closed or deleted, and no status is
// moved. Every GitHub call goes through `.claude/lib/team-tracker.sh` (the single gh boundary).
//
//   node .claude/lib/github-sync.mjs [--root <dir>] [--epic E<n>] --preview
//   node .claude/lib/github-sync.mjs [--root <dir>] --epic E<n> --apply --yes
//
// Reads `.agents/backlog.md` and its Epic files (`.agents/backlog/E<n>-….md`, the criteria). A
// selected Task with no acceptance criterion yet (Epic file and approved spec both empty) stops the
// run before any GitHub call.
// Order: validate the sources and every known issue's identity → plan in memory → preview, or
// (`--apply --yes`, one Epic group) write → verify. `--preview` and `--apply` without `--yes` make
// no write call of any kind — not to GitHub, not to the backlog.
// Identity: each issue body carries `<!-- backlog:<namespace>:<row id> -->` on a line of its own,
// plus `<!-- backlog-hash:<h> -->` (the hash of the body as mirrored, with dependencies as row ids)
// so a later backlog edit is reported as "changed since sync". The issue number lands in the row's
// `Jira` cell as `#n (unverified)` at once, and becomes `#n` after the markers are read back.
//
// Exit: 0 ok · 1 refused (invalid backlog, identity conflict, ambiguity, capacity, failed verify) ·
//   2 usage / confirmation required · 3 tracker is not github · 4 recoverable (adapter exit 4).
import { spawnSync } from 'node:child_process';
import crypto from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  PRE_DETAIL_MESSAGE, PRE_SCOPE_MESSAGE, cleanId, loadInventory, parseBacklog, parseTables, readBacklogFiles, resolveTask,
} from './backlog-check.mjs';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const NAMESPACE = /\*\*Jira namespace:\*\*\s*`?([a-z0-9]+(?:-[a-z0-9]+)*)`?/;
const SCOPE_REV = /\*\*Scope rev:\*\*\s*v(\d+)\.(\d+)/;
const CELL = /^#(\d+)( \(unverified\))?$/;
const SUB_ISSUE_LIMIT = 100;

class Stop extends Error { constructor(code, msg) { super(msg); this.code = code; } }
const say = (s) => process.stdout.write(`${s}\n`);

function parseArgs(argv) {
  const a = { root: process.cwd(), epic: null, preview: false, apply: false, yes: false };
  for (let i = 0; i < argv.length; i += 1) {
    const k = argv[i];
    if (k === '--root') a.root = argv[++i];
    else if (k === '--epic') a.epic = argv[++i];
    else if (k === '--preview') a.preview = true;
    else if (k === '--apply') a.apply = true;
    else if (k === '--yes') a.yes = true;
    else throw new Stop(2, `unknown argument '${k}'`);
  }
  if (a.preview === a.apply) throw new Stop(2, 'exactly one of --preview / --apply');
  if (a.epic !== null && !/^E\d+$/.test(a.epic ?? '')) throw new Stop(2, '--epic needs an Epic id (E<n>)');
  if (a.apply && !a.epic) throw new Stop(2, '--apply needs --epic E<n> — one confirmed Epic group per run');
  // Before ANY read or write: an unconfirmed apply is a refusal, not a dry run.
  if (a.apply && !a.yes) throw new Stop(2, 'confirmation required — run --apply --yes only after the user confirmed this Epic group');
  a.root = path.resolve(a.root);
  return a;
}

// ---- the adapter ------------------------------------------------------------------------------

function tracker(root, args) {
  const r = spawnSync('bash', [path.join(root, '.claude/lib/team-tracker.sh'), ...args], { cwd: root, encoding: 'utf8' });
  const out = (r.stdout ?? '').trim();
  if (r.status === 3) throw new Stop(3, 'the tracker is jira — /github-sync needs tracker=github');
  if (r.status !== 0) throw new Stop(r.status === 4 ? 4 : 1, `team-tracker.sh ${args[0]} failed: ${(r.stderr ?? '').trim() || out}`);
  if (out.startsWith('skipped (tracker=none)')) throw new Stop(3, 'the tracker is none — /github-sync needs tracker=github');
  return out;
}

function readMarkers(root, tmp, ns) {
  const f = path.join(tmp, `markers-${Date.now()}.json`);
  tracker(root, ['markers', '--prefix', `<!-- backlog:${ns}:`, '--out', f]);
  return JSON.parse(fs.readFileSync(f, 'utf8'));
}

// ---- the backlog ------------------------------------------------------------------------------

/** Byte offsets of the unescaped pipes in a table line. */
const pipes = (line) => [...line.matchAll(/(?<!\\)\|/g)].map((m) => m.index);

/** Rewrite one cell of one table line, leaving every other byte of the file as it was. */
function setCell(file, lineNo, col, value) {
  const lines = fs.readFileSync(file, 'utf8').split('\n');
  const line = lines[lineNo - 1];
  const p = pipes(line);
  if (p.length < col + 2) throw new Stop(1, `backlog line ${lineNo} has no cell ${col + 1}`);
  lines[lineNo - 1] = `${line.slice(0, p[col] + 1)} ${value} ${line.slice(p[col + 1])}`;
  const tmp = `${file}.tmp.${process.pid}`;
  fs.writeFileSync(tmp, lines.join('\n'));
  fs.renameSync(tmp, file);
}

function loadRows(root, md, epicFiles) {
  const backlog = parseBacklog(md, { epicFiles });
  if (backlog.legacy) throw new Stop(1, 'legacy backlog (work packages) — regenerate it with /setup:create-backlog');
  if (backlog.preScope) throw new Stop(1, PRE_SCOPE_MESSAGE);
  if (backlog.preDetail) throw new Stop(1, PRE_DETAIL_MESSAGE);
  const tables = parseTables(md);
  const epicT = tables.find((t) => ['Epic', 'Title', 'Pts', 'Jira'].every((h) => t.header.includes(h)));
  const taskT = tables.find((t) => ['ID', 'Epic', 'Size', 'Pts', 'Jira'].every((h) => t.header.includes(h)));
  if (!epicT || !taskT) throw new Stop(1, 'the backlog has no Epic map / Task table with a Jira column');
  const appetite = (id) => {
    const m = new RegExp(`^\\*\\*${id}\\*\\*\\s*[—-]\\s*(.+)$`, 'm').exec(md);
    return m ? m[1].trim() : null;
  };
  const epics = epicT.rows.filter((r) => cleanId(r.Epic)).map((r) => ({
    kind: 'epic', id: cleanId(r.Epic), title: cleanId(r.Title), outcome: cleanId(r.Outcome),
    assumption: cleanId(r['Key assumption']), deps: (backlog.epics.find((e) => e.id === cleanId(r.Epic))?.deps ?? []),
    appetite: appetite(cleanId(r.Epic)), cell: cleanId(r.Jira), line: r._line, col: epicT.header.indexOf('Jira'),
  }));
  const tasks = backlog.tasks.filter((t) => !t.withdrawn).map((t) => {
    const raw = taskT.rows.find((r) => r._line === t.line);
    return {
      kind: 'task', id: t.id, epic: t.epic, title: t.title, type: t.type, size: t.size, pts: t.pts,
      scope: t.scope, traces: t.traces, deps: t.deps, ac: resolveTask(root, backlog, t),
      cell: cleanId(raw?.Jira ?? ''), line: t.line, col: taskT.header.indexOf('Jira'),
    };
  });
  return { epics, tasks };
}

const depText = (deps, numbers) => (deps.length
  ? deps.map((d) => (numbers[d] ? `#${numbers[d]} (${d})` : d)).join(', ') : '—');

/** The issue body as mirrored. `numbers` fills dependency issue numbers; the hash uses `{}`. */
function renderBody(row, numbers) {
  const tail = `_Mirrored from \`.agents/backlog.md\` (${row.id}) by /github-sync — the backlog is the planning source._`;
  if (row.kind === 'epic') {
    return [`**Outcome:** ${row.outcome || '—'}`, `**Key assumption:** ${row.assumption || '—'}`,
      ...(row.appetite ? [`**Appetite / cut first:** ${row.appetite}`] : []),
      `**Depends on:** ${depText(row.deps, numbers)}`, '', tail].join('\n');
  }
  const acs = row.ac.current.filter((a) => !a.withdrawn);
  return [`**Type:** ${row.type} · **Size:** ${row.size} (${row.pts} pts) · **Scope:** ${row.scope}`,
    `**Traces:** ${row.traces.join(', ') || '—'}`, `**Depends on:** ${depText(row.deps, numbers)}`, '',
    '## Acceptance criteria', ...(acs.length ? acs.map((a) => `- **${a.id}** — ${a.text}`) : ['- (none yet)']),
    `(source: \`${row.ac.source}\`)`, '', tail].join('\n');
}

const hashOf = (row) => crypto.createHash('sha256').update(renderBody(row, {})).digest('hex').slice(0, 12);
const titleOf = (row) => `${row.id} — ${row.title}`;
const markerOf = (ns, row) => `<!-- backlog:${ns}:${row.id} -->`;
const fullBody = (ns, row, numbers) => `${renderBody(row, numbers)}\n\n<!-- backlog-hash:${hashOf(row)} -->\n${markerOf(ns, row)}\n`;

// ---- plan -------------------------------------------------------------------------------------

/** Classify every row of one group against the markers. Throws on a conflict — nothing written. */
function classify(ns, group, markers) {
  for (const row of group) {
    const hits = (markers[markerOf(ns, row)] ?? []);
    const nums = [...new Set(hits.map((h) => h.number))];
    if (row.cell === '' || row.cell === '—' || row.cell === '-') {
      if (nums.length > 1) throw new Stop(1, `${row.id}: marker found on issues ${nums.map((n) => `#${n}`).join(', ')} — resolve the duplicate by hand`);
      row.action = nums.length ? 'recover' : 'create';
      row.number = nums[0] ?? null;
    } else {
      const m = CELL.exec(row.cell);
      if (!m) throw new Stop(1, `${row.id}: the Jira cell holds '${row.cell}', not a GitHub issue — this row is another tracker's`);
      const n = Number(m[1]);
      // Identity BEFORE any linking: the issue in the cell must be the one carrying this row's marker.
      if (nums.length !== 1 || nums[0] !== n) {
        throw new Stop(1, `${row.id}: the cell says #${n} but the marker is on ${nums.length ? nums.map((x) => `#${x}`).join(', ') : 'no issue'} — fix the cell or the issue by hand`);
      }
      row.action = 'synced';
      row.number = n;
      row.unverified = Boolean(m[2]);
      row.changed = hits[0].hash !== hashOf(row);
    }
  }
}

function capacity(root, tmp, epic, tasks) {
  let existing = [];
  if (epic.number) {
    const f = path.join(tmp, `subs-${epic.number}.json`);
    tracker(root, ['sub-issues', String(epic.number), '--out', f]);
    existing = JSON.parse(fs.readFileSync(f, 'utf8'));
  }
  const after = new Set(existing);
  for (const t of tasks) after.add(t.number ?? `new:${t.id}`);
  if (after.size > SUB_ISSUE_LIMIT) {
    throw new Stop(1, `${epic.id}: ${after.size} sub-issues needed, GitHub allows ${SUB_ISSUE_LIMIT} per parent — split the Epic first`);
  }
}

// ---- run --------------------------------------------------------------------------------------

function run(a) {
  const file = path.join(a.root, '.agents/backlog.md');
  if (!fs.existsSync(file)) throw new Stop(1, 'no .agents/backlog.md — run /setup:create-backlog first');
  const check = spawnSync(process.execPath, [path.join(HERE, 'backlog-check.mjs'), '--root', a.root], { encoding: 'utf8' });
  if (check.status !== 0) throw new Stop(1, `the backlog checker refuses it — fix these first:\n${check.stdout}${check.stderr}`);
  const { md, epicFiles } = readBacklogFiles(file);
  const ns = NAMESPACE.exec(md)?.[1];
  if (!ns) throw new Stop(1, 'the backlog header has no **Jira namespace:** — the markers need it');
  const rev = SCOPE_REV.exec(md);
  const prd = loadInventory(a.root).scopeRev;
  if (rev && prd) {
    const [pm, pn] = prd.slice(1).split('.').map(Number);
    if (pm > Number(rev[1]) || (pm === Number(rev[1]) && pn > Number(rev[2]))) {
      throw new Stop(1, `the backlog trails the PRD (v${rev[1]}.${rev[2]} < ${prd}) — run /update-backlog first`);
    }
  }
  const { epics, tasks } = loadRows(a.root, md, epicFiles);
  const chosen = a.epic ? epics.filter((e) => e.id === a.epic) : epics;
  if (!chosen.length) throw new Stop(1, `no Epic ${a.epic} in the backlog`);
  // Create-only: an issue mirrored before its Task has criteria would never get them. Stop before
  // any GitHub call (preview and apply alike) — an approved spec in Ref that supplies them passes.
  const chosenIds = new Set(chosen.map((e) => e.id));
  const bare = tasks.filter((t) => chosenIds.has(t.epic) && !t.ac.current.some((x) => !x.withdrawn)).map((t) => t.id);
  if (bare.length) {
    throw new Stop(1, `Task(s) ${bare.join(', ')} have no acceptance criteria yet — run /setup:delivery-plan (the sync is create-only: an issue created now would never get them)`);
  }

  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'github-sync-'));
  try {
    const markers = readMarkers(a.root, tmp, ns);
    const groups = chosen.map((e) => ({ epic: e, tasks: tasks.filter((t) => t.epic === e.id) }));
    for (const g of groups) { classify(ns, [g.epic, ...g.tasks], markers); capacity(a.root, tmp, g.epic, g.tasks); }
    const numbers = Object.fromEntries([...epics, ...tasks].map((r) => [r.id, r.number ?? (CELL.exec(r.cell)?.[1] ?? null)]).filter(([, n]) => n));
    if (a.preview) return preview(ns, groups, numbers);
    return apply(a.root, tmp, file, ns, groups[0], numbers);
  } finally {
    fs.rmSync(tmp, { recursive: true, force: true });
  }
}

function describe(row) {
  const flags = [row.unverified && 'unverified', row.changed && 'changed since sync'].filter(Boolean);
  const what = row.action === 'create' ? 'create' : `${row.action} #${row.number}`;
  return `${row.id} ${what}${flags.length ? ` [${flags.join(', ')}]` : ''}`;
}

function preview(ns, groups, numbers) {
  for (const g of groups) {
    say(`## ${g.epic.id} — ${g.epic.title}`);
    for (const row of [g.epic, ...g.tasks]) say(`- ${describe(row)}`);
    say(`- sub-issues of ${g.epic.id}: ${g.tasks.map((t) => t.id).join(', ') || '—'} · project-add: every row`);
    for (const row of [g.epic, ...g.tasks].filter((r) => r.action === 'create')) {
      say(`\n### ${titleOf(row)}\n${fullBody(ns, row, numbers)}`);
    }
  }
  const all = groups.flatMap((g) => [g.epic, ...g.tasks]);
  say(`\npreview: ${all.filter((r) => r.action === 'create').length} to create · ${all.filter((r) => r.action === 'recover').length} to recover · ${all.filter((r) => r.action === 'synced').length} synced · ${all.filter((r) => r.changed).length} changed since sync — nothing written`);
  return 0;
}

function apply(root, tmp, file, ns, g, numbers) {
  const rows = [g.epic, ...g.tasks];
  for (const row of rows.filter((r) => r.action === 'recover')) setCell(file, row.line, row.col, `#${row.number} (unverified)`);
  for (const row of rows.filter((r) => r.action === 'create')) {
    const body = path.join(tmp, `${row.id}.md`);
    fs.writeFileSync(body, fullBody(ns, row, numbers));
    const out = tracker(root, ['create-issue', '--marker', markerOf(ns, row), '--title', titleOf(row), '--body-file', body]);
    const n = Number(/^(created|exists) (\d+)$/m.exec(out)?.[2]);
    if (!n) throw new Stop(4, `${row.id}: create-issue printed '${out}'`);
    row.number = n; numbers[row.id] = n;
    setCell(file, row.line, row.col, `#${n} (unverified)`);  // at once: a crash after this is a recover
    say(`${row.id} ${out}`);
  }
  for (const t of g.tasks) say(`${t.id} sub-issue: ${tracker(root, ['add-sub-issue', String(g.epic.number), String(t.number)])}`);
  for (const row of rows) say(`${row.id} project: ${tracker(root, ['project-add', String(row.number)])}`);
  const back = readMarkers(root, tmp, ns);
  let bad = 0;
  for (const row of rows) {
    const nums = [...new Set((back[markerOf(ns, row)] ?? []).map((h) => h.number))];
    if (nums.length === 1 && nums[0] === row.number) setCell(file, row.line, row.col, `#${row.number}`);
    else { bad += 1; say(`${row.id} NOT verified — the marker is on ${nums.map((x) => `#${x}`).join(', ') || 'no issue'}; the cell stays unverified`); }
  }
  const changed = rows.filter((r) => r.changed).map((r) => r.id);
  say(`apply ${g.epic.id}: ${rows.filter((r) => r.action === 'create').length} created · ${rows.filter((r) => r.action === 'recover').length} recovered · ${rows.length - bad} verified${changed.length ? ` · changed since sync (not pushed): ${changed.join(', ')}` : ''}`);
  return bad ? 1 : 0;
}

export function main(argv = process.argv.slice(2)) {
  try {
    return run(parseArgs(argv));
  } catch (err) {
    if (!(err instanceof Stop)) throw err;
    process.stderr.write(`github-sync: ${err.message}\n`);
    return err.code;
  }
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) process.exitCode = main();
