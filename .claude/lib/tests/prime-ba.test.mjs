// Unit tests of .claude/lib/prime-ba.mjs (selector, extracts, paging, pending queue, note families,
// code roots) over temp-dir fixtures. No network: git fixtures use local bare remotes only.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import crypto from 'node:crypto';
import { spawnSync, execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

import {
  main, PAGE_SIZE, DEFAULT_BUDGET, FULL_BUDGET, PER_FILE_CAP, FULL_PER_FILE_CAP, MAXLOAD, paginate, extractRegister,
  loadChecker, shellQuote,
} from '../prime-ba.mjs';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const SCRIPT = path.resolve(HERE, '..', 'prime-ba.mjs');
const REPO = path.resolve(HERE, '..', '..', '..');
const ENV = { ...process.env, GIT_CONFIG_GLOBAL: '/dev/null', GIT_CONFIG_NOSYSTEM: '1' };
const CONT = '… continued — run: ';

// ---------------------------------------------------------------------------------------------
// Fixture helpers
// ---------------------------------------------------------------------------------------------

function git(cwd, ...args) {
  return execFileSync('git', ['-c', 'user.email=t@t', '-c', 'user.name=t', '-c', 'init.defaultBranch=main',
    '-c', 'commit.gpgsign=false', ...args], { cwd, encoding: 'utf8', env: ENV, stdio: ['ignore', 'pipe', 'pipe'] });
}

function tmpRepo({ git: withGit = false, name = 'prime ba-' } = {}) {
  const d = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), name)));
  if (withGit) {
    git(d, 'init', '-q');
    git(d, 'commit', '-q', '--allow-empty', '-m', 'init');
  }
  return d;
}

function write(root, rel, text) {
  const abs = path.join(root, rel);
  fs.mkdirSync(path.dirname(abs), { recursive: true });
  fs.writeFileSync(abs, text);
  return abs;
}

/** Exactly `n` ASCII bytes: `prefix`, then 80-byte filler lines. */
function sized(prefix, n) {
  const body = n - Buffer.byteLength(prefix);
  assert.ok(body >= 0, `prefix longer than ${n}`);
  const line = `${'y'.repeat(79)}\n`;
  const full = line.repeat(Math.floor(body / 80));
  return prefix + full + 'y'.repeat(body - full.length);
}

const fill = (root, rel, n, prefix = '') => write(root, rel, sized(prefix, n));
const sha12 = (text) => crypto.createHash('sha256').update(text).digest('hex').slice(0, 12);
const briefText = (n = 300) => sized('---\nstatus: populated\n---\n# Brief\n', n);

function frame(root, { index = 300, profile = 0, brief = 300 } = {}) {
  fill(root, '.agents/memory/index.md', index, '# Index\n');
  if (profile) fill(root, '.agents/memory/user-profile.md', profile, '# Profile\n');
  if (brief) write(root, '.agents/memory/project-brief.md', briefText(brief));
}

function run(args, { cwd = REPO, script = SCRIPT } = {}) {
  return spawnSync(process.execPath, [script, ...args], { cwd, encoding: 'utf8', env: ENV, maxBuffer: 256 * 1024 * 1024 });
}

/** Every page of one invocation, concatenated (continuation lines included). */
function allPages(args, opts = {}) {
  let out = '';
  for (let p = 1; p < 2000; p += 1) {
    const r = run([...args, '--page', String(p)], opts);
    assert.equal(r.status, 0, r.stderr);
    out += r.stdout;
    if (!r.stdout.includes(CONT)) return { out, pages: p };
  }
  throw new Error('paging did not end');
}

const plan = (root, extra = []) => allPages(['plan', '--root', root, ...extra]).out;
const rows = (out, key) => out.split('\n').filter((l) => l.split('\t')[0] === key).map((l) => l.split('\t'));
const totalOf = (out) => Number(rows(out, 'TOTAL')[0][1].split(' ')[0]);
const loadPaths = (out) => rows(out, 'LOAD').map((r) => r[2]);
const field = (row, prefix) => row.find((f) => f.startsWith(prefix))?.slice(prefix.length);

function prdText({ header = true, ids = 0, narrative = 0, decisions = 0, extra = '' } = {}) {
  const lines = ['# PRD — Fixture', ''];
  if (header) lines.push('**Baseline:** v1.0 (2026-01-01) · **Approved by:** proposed · **Current:** v1.2 (2026-02-01)', '');
  lines.push('## 3. Goals', '', '- **G-1** — Goal one is met. Added: v1.0', '- **G-2** — Goal two is met. Added: v1.0',
    '- **G-3** — Goal three is met. Added: v1.0', '', '## 5. Requirements', '', '### Capability A');
  for (let i = 1; i <= ids; i += 1) {
    let state = '';
    if (i === 7) state = '(withdrawn per D-3) ';
    if (i === 9) state = '(superseded by R-40 per D-4) ';
    lines.push(`- **R-${i}** — ${state}WHEN the user does thing ${i} the system shall respond with a clear answer number ${i}. Traces: G-1 · Added: v1.0`);
  }
  lines.push('', extra, '');
  if (narrative) lines.push('## 9. Narrative', '', sized('', narrative).replace(/y{79}/g, 'NARRATIVE-TEXT lorem ipsum dolor sit amet consectetur adipiscing elit sed do eiusmod'), '');
  lines.push('## Change log', '');
  for (let n = decisions; n >= 1; n -= 1) lines.push(`### D-${n} — 2026-01-${String((n % 28) + 1).padStart(2, '0')} — decision ${n}`, '**Kind:** scope', `**Decision:** text ${n}`, '');
  return `${lines.join('\n')}\n`;
}

function gitClone(from, to) { execFileSync('git', ['clone', '-q', from, to], { env: ENV, stdio: 'ignore' }); }

/** A bare remote with one commit, and a clone of it. */
function remoteAndClone(base, name = 'A') {
  const seed = path.join(base, 'seed');
  fs.mkdirSync(seed);
  git(seed, 'init', '-q');
  write(seed, 'README.md', 'seed\n');
  git(seed, 'add', '.');
  git(seed, 'commit', '-q', '-m', 'seed');
  const remote = path.join(base, 'remote.git');
  execFileSync('git', ['clone', '-q', '--bare', seed, remote], { env: ENV, stdio: 'ignore' });
  const clone = path.join(base, name);
  gitClone(remote, clone);
  return { remote, clone };
}

const profile = (root, repos) => write(root, '.claude/project-profile.json', JSON.stringify({ ba: { code_repos: repos } }));

// ---------------------------------------------------------------------------------------------
// Cases
// ---------------------------------------------------------------------------------------------

test('plan exits 0 and prints MISSING lines in an empty directory', () => {
  const d = tmpRepo();
  const r = run(['plan', '--root', d]);
  assert.equal(r.status, 0, r.stderr);
  const missing = rows(r.stdout, 'MISSING').map((x) => x[1]);
  for (const k of ['prd', 'discovery', 'architecture', 'backlog', 'profile', 'brief', 'user-profile']) assert.ok(missing.includes(k), `MISSING ${k}`);
  assert.equal(rows(r.stdout, 'NO_CODE_ROOT').length, 1);
  assert.equal(rows(r.stdout, 'LOAD').length, 0);
});

test('every extract part exits 0 in an empty directory', async () => {
  const d = tmpRepo();
  const names = {
    register: 'docs/PRD.md', changelog: 'docs/PRD.md', discovery: 'docs/discovery.md', architecture: 'docs/architecture.md',
    decisions: '.agents/memory/decisions.md', backlog: '.agents/backlog.md', codemap: 'docs/map/system.yaml',
  };
  for (const [part, name] of Object.entries(names)) {
    const r = run(['extract', part, '--root', d]);
    assert.equal(r.status, 0, `${part}: ${r.stderr}`);
    assert.ok(r.stdout.includes(name), `${part} names ${name}: ${r.stdout}`);
  }
  assert.equal(run(['extract', 'nope', '--root', d]).status, 2);
  assert.equal(await main(['extract', 'nope', '--root', d]), 2);
});

test('default plan loads no spec file and stays within DEFAULT_BUDGET', () => {
  const d = tmpRepo();
  frame(d);
  write(d, 'docs/PRD.md', prdText({ ids: 5, decisions: 2 }));
  write(d, '.agents/backlog.md', '# Backlog\n');
  for (let i = 0; i < 94; i += 1) {
    const m = String((i % 12) + 1).padStart(2, '0');
    const day = String((i % 28) + 1).padStart(2, '0');
    fill(d, `.agents/specs/2026-${m}-${day}-s${i}.md`, 5000 + ((i * 7919) % 35000), `# Design: spec ${i}\n**Status:** Approved\n`);
  }
  // A symlinked spec counts by its target; a directory named *.md is no spec (mirror prime-probes-test).
  fill(d, 'outside/target.md', 6000, '# Design: linked\n');
  fs.symlinkSync(path.join(d, 'outside/target.md'), path.join(d, '.agents/specs/2025-01-01-link.md'));
  fs.mkdirSync(path.join(d, '.agents/specs/2025-02-02-dir.md'));
  const out = plan(d);
  for (const r of [...rows(out, 'LOAD'), ...rows(out, 'EXTRACT')]) assert.ok(!r.join('\t').includes('.agents/specs/'), r.join('\t'));
  assert.ok(totalOf(out) <= DEFAULT_BUDGET, `TOTAL ${totalOf(out)}`);
  assert.match(rows(out, 'SPECS_TOTAL')[0][1], /^95 files \//);
  const specs = rows(out, 'SPEC');
  assert.equal(specs.length, 10);
  const dates = specs.map((s) => s[1]);
  assert.deepEqual(dates, [...dates].sort().reverse());
});

test('pending small spec is queued but not loaded in default mode', () => {
  const d = tmpRepo();
  frame(d);
  write(d, 'docs/PRD.md', prdText({ ids: 2 }));
  fill(d, '.agents/specs/2026-01-01-small.md', 300, '# Design: small\n');
  const out = plan(d);
  const p = rows(out, 'PENDING').find((r) => r[3] === '.agents/specs/2026-01-01-small.md');
  assert.deepEqual(p.slice(0, 3), ['PENDING', 'spec', '300']);
  assert.ok(!loadPaths(out).includes('.agents/specs/2026-01-01-small.md'));
  assert.ok(loadPaths(plan(d, ['--mode', 'full'])).includes('.agents/specs/2026-01-01-small.md'));
});

test('large PRD loads the register index and newest 5 D-n, not the narrative', () => {
  const d = tmpRepo();
  frame(d);
  const nfr = '### Quality\n\n| ID | Requirement | Status |\n|---|---|---|\n| NFR-1 | Pages load within two seconds | active |\n';
  write(d, 'docs/PRD.md', prdText({ ids: 40, narrative: 60000, decisions: 30, extra: nfr }));
  assert.ok(fs.statSync(path.join(d, 'docs/PRD.md')).size > PER_FILE_CAP);
  const out = plan(d);
  assert.ok(!loadPaths(out).includes('docs/PRD.md'));
  const parts = rows(out, 'EXTRACT').map((r) => r[2]);
  assert.ok(parts.includes('register') && parts.includes('changelog'));
  assert.ok(out.includes('register index + newest 5 D-n — narrative not loaded'));
  const log = run(['extract', 'changelog', '--root', d]).stdout;
  for (let n = 30; n >= 26; n -= 1) assert.ok(log.includes(`### D-${n} —`), `D-${n}`);
  assert.ok(!log.includes('### D-25 —'));
  const reg = allPages(['extract', 'register', '--root', d]).out;
  assert.ok(reg.includes('**Baseline:** v1.0 (2026-01-01)'));
  assert.ok(reg.includes('R-7 · withdrawn per D-3'));
  assert.ok(reg.includes('R-9 · superseded by R-40 per D-4'));
  assert.ok(reg.includes('NFR-1 · active · Pages load within two seconds'));
  assert.ok(!reg.includes('NARRATIVE-TEXT'));
});

test('code root reports branch, HEAD and behind count without modifying the checkout', () => {
  const base = tmpRepo();
  const { remote, clone: A } = remoteAndClone(base);
  const B = path.join(base, 'B');
  gitClone(remote, B);
  for (const k of [1, 2]) {
    write(B, `f${k}.txt`, `${k}\n`);
    git(B, 'add', '.');
    git(B, 'commit', '-q', '-m', `c${k}`);
  }
  git(B, 'push', '-q', 'origin', 'main');
  git(A, 'fetch', '-q');
  const ws = tmpRepo();
  profile(ws, [{ name: 'app', path: A }]);
  const snap = () => {
    const files = ['index', 'HEAD', 'FETCH_HEAD'].map((f) => path.join(A, '.git', f));
    return {
      hashes: files.map((f) => crypto.createHash('sha256').update(fs.readFileSync(f)).digest('hex')),
      mtimes: files.map((f) => fs.statSync(f).mtimeMs),
      refs: git(A, 'for-each-ref'),
    };
  };
  const before = snap();
  const out = plan(ws);
  const row = rows(out, 'CODE_ROOT').find((r) => r[1] === 'app');
  const short = git(A, 'rev-parse', '--short', 'HEAD').trim();
  assert.ok(row, out);
  for (const want of ['branch=main', `head=${short}`, 'behind=2', 'stale']) assert.ok(row[3].includes(want), `${want} in ${row[3]}`);
  assert.deepEqual(snap(), before);
});

test('output larger than PAGE_SIZE is paged with a continuation line', () => {
  const d = tmpRepo();
  frame(d);
  write(d, 'docs/PRD.md', prdText({ ids: 600 }));
  const p1 = run(['extract', 'register'], { cwd: d });
  assert.equal(p1.status, 0, p1.stderr);
  assert.ok(Buffer.byteLength(p1.stdout) <= PAGE_SIZE);
  assert.ok(p1.stdout.endsWith('… continued — run: node .claude/lib/prime-ba.mjs extract register --page 2\n'));
  const { out, pages } = allPages(['extract', 'register'], { cwd: d });
  for (let i = 1; i <= 600; i += 1) {
    const hits = out.match(new RegExp(`^R-${i} ·`, 'gm')) ?? [];
    assert.equal(hits.length, 1, `R-${i}`);
  }
  const beyond = run(['extract', 'register', '--page', '99'], { cwd: d });
  assert.equal(beyond.status, 0);
  assert.equal(beyond.stdout, `no page 99 (last: ${pages})\n`);
  const planOut = allPages(['plan'], { cwd: d }).out;
  const row = rows(planOut, 'EXTRACT').find((r) => r[2] === 'register');
  assert.equal(row[3], `pages=${pages}`);
});

test('mandatory core over budget still loads and warns per layer', () => {
  const d = tmpRepo();
  frame(d);
  const lines = ['# Decisions', '', '## Format', '', 'one entry per heading', ''];
  const day0 = Date.UTC(2020, 0, 1);
  for (let i = 0; i < 2000; i += 1) {
    const date = new Date(day0 + i * 86400000).toISOString().slice(0, 10);
    lines.push(`## ${date} — decision number ${i} ${'h'.repeat(80)}`, '', `body ${i}`, '');
  }
  write(d, '.agents/memory/decisions.md', `${lines.join('\n')}\n`);
  const out = plan(d);
  assert.ok(rows(out, 'EXTRACT').some((r) => r[2] === 'decisions'));
  assert.ok(!out.split('\n').some((l) => l.startsWith('SKIP_') && l.includes('decisions')));
  const warn = rows(out, 'WARN').find((r) => r[1].startsWith('⚠️ mandatory layer decisions is'));
  assert.ok(warn, out);
  assert.ok(warn[1].includes('/maintain:cleanup-workflow'));
});

test('note family loads whole or is skipped whole', () => {
  const d = tmpRepo();
  frame(d);
  const N = '.agents/meeting-notes';
  fill(d, `${N}/2026-10-01-a.md`, 2048, '# Meeting a\n**Coverage:** partial\n');
  write(d, `${N}/2026-10-01-a-correction.md`, `# Correction — a\n**Corrects:** ${N}/2026-10-01-a.md\n`);
  write(d, `${N}/2026-10-01-a-correction-2.md`, `# Correction — a\n**Corrects:** ${N}/2026-10-01-a.md\n`);
  fill(d, `${N}/2026-10-02-b.md`, 60000, '# Meeting b\n');
  write(d, `${N}/2026-10-03-z-correction.md`, `# Correction — z\n**Corrects:** ${N}/2026-10-03-missing.md\n`);
  const out = plan(d);
  const fam = rows(out, 'LOAD').filter((r) => r.includes(`family=${N}/2026-10-01-a.md`)).map((r) => r[2]);
  assert.deepEqual(fam.sort(), [`${N}/2026-10-01-a-correction-2.md`, `${N}/2026-10-01-a-correction.md`, `${N}/2026-10-01-a.md`]);
  assert.ok(rows(out, 'SKIP_CAP').some((r) => r[2] === `family:${N}/2026-10-02-b.md`), out);
  assert.ok(rows(out, 'ERROR').some((r) => r[1] === 'orphan correction' && r[2] === `${N}/2026-10-03-z-correction.md`));
});

test('raw source covered after a metadata correction to partial is listed as uncovered', () => {
  const N = '.agents/meeting-notes';
  const make = (withCorrection) => {
    const d = tmpRepo();
    frame(d);
    write(d, '.agents/sources/t1.txt', 'transcript\n');
    write(d, `${N}/2026-10-01-t.md`, '# T\n**Source:** .agents/sources/t1.txt\n**Coverage:** full\n');
    if (withCorrection) {
      write(d, `${N}/2026-10-01-t-correction.md`, `# Correction — T\n**Corrects:** ${N}/2026-10-01-t.md\n\n## Metadata\n- Coverage: partial — x ⟵ was: "full"\n`);
    }
    return rows(plan(d), 'RAW').filter((r) => r[2] === './.agents/sources/t1.txt');
  };
  assert.equal(make(true).length, 1);
  assert.equal(make(false).length, 0);
});

test('full mode loads decisions.md whole and stays within FULL_BUDGET', () => {
  const d = tmpRepo();
  frame(d);
  const entries = Array.from({ length: 100 }, (_, i) => `## 2026-01-${String((i % 28) + 1).padStart(2, '0')} — d${i}\n\n${'b'.repeat(560)}\n`);
  write(d, '.agents/memory/decisions.md', `# Decisions\n\n${entries.join('\n')}`);
  const size = fs.statSync(path.join(d, '.agents/memory/decisions.md')).size;
  assert.ok(size > 55000 && size <= FULL_PER_FILE_CAP);
  const def = plan(d);
  assert.ok(rows(def, 'EXTRACT').some((r) => r[2] === 'decisions'));
  const full = plan(d, ['--mode', 'full']);
  assert.ok(loadPaths(full).includes('.agents/memory/decisions.md'));
  assert.ok(!rows(full, 'EXTRACT').some((r) => r[2] === 'decisions'));
  assert.ok(totalOf(full) <= FULL_BUDGET);
});

test('newest decisions entries are chosen by heading date', () => {
  const d = tmpRepo();
  const dates = ['2026-03-05', '2026-01-02', '2026-07-19', '2026-02-11', '2026-05-30', '2026-01-20', '2026-09-09',
    '2026-04-04', '2026-08-01', '2026-06-15', '2026-02-28', '2026-10-10', '2026-03-31', '2026-11-11'];
  const body = dates.map((dt) => `## ${dt} — entry ${dt}\n\nbody-${dt}\n`).join('\n');
  write(d, '.agents/memory/decisions.md', `# Decisions\n\n## Format\n\n\`\`\`\n## YYYY-MM-DD — title\n\`\`\`\n\n${body}`);
  const out = run(['extract', 'decisions', '--root', d]).stdout;
  const head = out.split('\n\nNewest')[0];
  assert.equal(head.split('\n').filter((l) => l.startsWith('## ')).length, 14);
  const sorted = [...dates].sort().reverse();
  for (const dt of sorted.slice(0, 10)) assert.ok(out.includes(`body-${dt}`), dt);
  for (const dt of sorted.slice(10)) assert.ok(!out.includes(`body-${dt}`), dt);
});

test('malformed ba.code_repos prints one ERROR line and runs valid entries', () => {
  const ok = tmpRepo({ git: true });
  const plain = tmpRepo();
  const ws = tmpRepo();
  profile(ws, [{ name: 'ok', path: ok }, { name: 'x' }]);
  let out = plan(ws);
  assert.equal(rows(out, 'ERROR').filter((r) => r[1] === 'ba.code_repos').length, 1);
  assert.equal(rows(out, 'CODE_ROOT').length, 1);
  write(ws, '.claude/project-profile.json', JSON.stringify({ ba: { code_repos: 'nope' } }));
  const r = run(['plan', '--root', ws]);
  assert.equal(r.status, 0);
  assert.equal(rows(r.stdout, 'ERROR').filter((x) => x[1] === 'ba.code_repos').length, 1);
  profile(ws, [{ name: 'plain', path: plain }]);
  out = plan(ws);
  assert.equal(rows(out, 'CODE_ROOT').find((x) => x[1] === 'plain')[3], 'not a git checkout');
});

test('changed source is pending again with changed since D-k', () => {
  const d = tmpRepo();
  frame(d);
  const S = '.agents/specs/2026-01-01-s.md';
  write(d, S, '# Design: s\nv1\n');
  const block = (n, hash, tasks) => `### D-${n} — 2026-01-0${n} — d${n}\n**Kind:** scope\n**Sources:** \`${S}\` (sha256:${hash})\n**Tasks:** ${tasks}\n`;
  const prd = (blocks) => write(d, 'docs/PRD.md', `# PRD\n\n## Change log\n\n${blocks.join('\n')}`);
  prd([block(2, sha12('# Design: s\nv1\n'), 'E1-1')]);
  assert.ok(!rows(plan(d), 'PENDING').some((r) => r[3] === S));
  write(d, S, '# Design: s\nv2\n');
  let row = rows(plan(d), 'PENDING').find((r) => r[3] === S);
  assert.equal(row[4], 'changed since D-2');
  prd([block(3, sha12('# Design: s\nv2\n'), '—'), block(2, sha12('# Design: s\nv1\n'), 'E1-1')]);
  row = rows(plan(d), 'PENDING').find((r) => r[3] === S);
  assert.ok(row, 'still pending after a D-n with empty Tasks');
});

test('this repo holds source detection', () => {
  const d = tmpRepo({ git: true });
  for (const f of ['.agents/x.md', 'docs/a.md', 'README.md', 'LICENSE', '.mcp.json', 'config/app.yaml', 'assets/logo.png',
    'tools/agent_mail/agent_mail.py']) write(d, f, 'x\n');
  git(d, 'add', '-A');
  git(d, 'commit', '-q', '-m', 'files');
  let out = plan(d);
  assert.equal(rows(out, 'NO_CODE_ROOT').length, 1);
  write(d, 'src/app.ts', 'export {};\n');
  git(d, 'add', '-A');
  out = plan(d);
  assert.deepEqual(rows(out, 'CODE_ROOT').map((r) => r.slice(0, 3)), [['CODE_ROOT', 'this repo', '.']]);
});

test('plan counts its own pages in TOTAL', () => {
  const d = tmpRepo();
  frame(d, { profile: 500 });
  write(d, 'docs/PRD.md', prdText({ ids: 20, decisions: 8 }));
  write(d, '.agents/backlog.md', '# Backlog\n');
  for (let i = 0; i < 30; i += 1) fill(d, `.agents/specs/2026-02-${String(i % 28 + 1).padStart(2, '0')}-x${i}.md`, 400, `# Design: x${i}\n`);
  const out = plan(d);
  const content = [...rows(out, 'LOAD'), ...rows(out, 'EXTRACT')].reduce((s, r) => s + Number(r[1]), 0);
  assert.ok(totalOf(out) >= content + Buffer.byteLength(out), `${totalOf(out)} < ${content} + ${Buffer.byteLength(out)}`);
});

test('optional selection near capacity keeps TOTAL within budget in both modes', () => {
  for (const [mode, budget, cap] of [['default', DEFAULT_BUDGET, PER_FILE_CAP], ['full', FULL_BUDGET, FULL_PER_FILE_CAP]]) {
    const d = tmpRepo();
    const each = cap - 60;
    frame(d, { index: each, profile: each, brief: each });
    const note = budget - 3 * each - 300;
    assert.ok(note <= cap, `${mode}: note ${note} over cap`);
    fill(d, '.agents/meeting-notes/2026-10-01-n.md', note, '# N\n');
    const out = plan(d, ['--mode', mode]);
    assert.ok(totalOf(out) <= budget, `${mode}: TOTAL ${totalOf(out)}`);
    assert.ok(rows(out, 'SKIP_BUDGET').some((r) => r[2] === 'family:.agents/meeting-notes/2026-10-01-n.md'), `${mode}: ${out}`);
  }
  const d = tmpRepo();
  frame(d, { index: DEFAULT_BUDGET + 10000 });
  const out = plan(d);
  assert.ok(rows(out, 'WARN').some((r) => r[1].includes('mandatory content and the plan listing alone')), out);
});

test('extract backlog output matches the plan measurement in each mode', () => {
  const d = tmpRepo();
  frame(d);
  fill(d, '.agents/backlog.md', 60000, '# Backlog\n\n');
  const def = plan(d);
  assert.ok(!loadPaths(def).includes('.agents/backlog.md'));
  let row = rows(def, 'EXTRACT').find((r) => r[2] === 'backlog');
  assert.ok(field(row, 'cmd=').includes('--summary'));
  let ex = allPages(['extract', 'backlog', '--summary', '--root', d]);
  assert.ok(ex.out.includes('Epic map'));
  assert.equal(Number(row[1]), Buffer.byteLength(ex.out));
  assert.equal(field(row, 'pages='), String(ex.pages));
  const full = plan(d, ['--mode', 'full']);
  assert.ok(loadPaths(full).includes('.agents/backlog.md'));
  row = rows(full, 'EXTRACT').find((r) => r[2] === 'backlog');
  assert.ok(!field(row, 'cmd=').includes('--summary'));
  ex = allPages(['extract', 'backlog', '--root', d]);
  assert.ok(!ex.out.includes('Epic map'));
  assert.equal(Number(row[1]), Buffer.byteLength(ex.out));
});

test('PRD head fallback counts only the first 100 lines', () => {
  const d = tmpRepo();
  fill(d, '.agents/memory/index.md', 300, '# Index\n');
  write(d, '.agents/memory/project-brief.md', '---\nstatus: empty\n---\n');
  const head = Array.from({ length: 100 }, (_, i) => `line ${i}`);
  write(d, 'docs/PRD.md', `${head.join('\n')}\n${sized('', 200 * 1024)}`);
  const out = plan(d);
  const row = rows(out, 'LOAD').find((r) => r[2] === 'docs/PRD.md');
  assert.equal(row[3], 'limit=100');
  assert.equal(Number(row[1]), Buffer.byteLength(`${head.join('\n')}\n`));
  assert.ok(Number(rows(out, 'LAYER').find((r) => r[1] === 'frame')[2]) < 50000);
});

test('register index keeps n/a NFR rows', () => {
  const d = tmpRepo();
  const extra = '### Quality\n\n| ID | Requirement | Status |\n|---|---|---|\n| NFR-1 | N/A — no personal data stored | active |\n\n'
    + '### Ops\n\n| ID | Requirement |\n|---|---|\n| NFR-2 | N/A — offline only |\n';
  write(d, 'docs/PRD.md', prdText({ ids: 2, extra }));
  const out = run(['extract', 'register', '--root', d]).stdout;
  assert.ok(out.includes('NFR-1 · n/a · no personal data stored'), out);
  assert.ok(out.includes('NFR-2 · n/a · offline only'), out);
  assert.ok(out.includes('NFR active=0 superseded=0 withdrawn=0 n/a=2'), out);
});

test('correction conflict in a skipped family is reported and blocks full coverage', () => {
  const d = tmpRepo();
  frame(d);
  const N = '.agents/meeting-notes';
  write(d, '.agents/sources/t2.txt', 'transcript\n');
  fill(d, `${N}/2026-10-01-big.md`, 60000, '# Big\n**Source:** .agents/sources/t2.txt\n**Coverage:** partial\n');
  write(d, `${N}/2026-10-01-big-correction.md`, `# Correction — Big\n**Corrects:** ${N}/2026-10-01-big.md\n\n## Metadata\n- Coverage: full ⟵ was: "full"\n`);
  const out = plan(d);
  assert.ok(rows(out, 'ERROR').some((r) => r[1] === 'correction conflict'), out);
  assert.ok(rows(out, 'SKIP_CAP').some((r) => r[2] === `family:${N}/2026-10-01-big.md`));
  assert.ok(rows(out, 'RAW').some((r) => r[2] === './.agents/sources/t2.txt'));
});

test('under-cap backlog dropped by the budget still gets its Epic map', () => {
  const d = tmpRepo();
  const each = PER_FILE_CAP - 60;
  frame(d, { index: each, profile: each, brief: each });
  const lines = ['# Decisions', ''];
  for (let i = 0; i < 160; i += 1) lines.push(`## 2026-01-01 — d${i} ${'h'.repeat(70)}`, '', 'b', '');
  write(d, '.agents/memory/decisions.md', `${lines.join('\n')}\n`);
  fill(d, '.agents/backlog.md', 30000, '# Backlog\n\n');
  const out = plan(d);
  assert.ok(!loadPaths(out).includes('.agents/backlog.md'), out);
  const row = rows(out, 'EXTRACT').find((r) => r[2] === 'backlog');
  assert.ok(field(row, 'cmd=').includes('--summary'));
  const ex = allPages(['extract', 'backlog', '--summary', '--root', d]);
  assert.ok(ex.out.includes('Epic map'));
  assert.equal(Number(row[1]), Buffer.byteLength(ex.out));
});

test('missing backlog-check degrades dependent layers and exits 0', () => {
  const d = tmpRepo();
  const lib = path.join(d, '.claude', 'lib');
  fs.mkdirSync(lib, { recursive: true });
  fs.copyFileSync(SCRIPT, path.join(lib, 'prime-ba.mjs'));
  frame(d);
  write(d, 'docs/PRD.md', prdText({ ids: 3, decisions: 2 }));
  fill(d, '.agents/specs/2026-01-01-a.md', 500, '# Design: a\n');
  fill(d, '.agents/meeting-notes/2026-10-01-m.md', 500, '# M\n');
  const r = run(['plan'], { cwd: d, script: path.join(lib, 'prime-ba.mjs') });
  assert.equal(r.status, 0, r.stderr);
  assert.ok(r.stdout.includes('ERROR\tregister\tbacklog-check.mjs not loadable'), r.stdout);
  assert.ok(r.stdout.includes('ERROR\tchangelog\tbacklog-check.mjs not loadable'));
  for (const key of ['SPEC', 'PENDING', 'NOTES']) assert.ok(rows(r.stdout, key).length > 0, key);
});

test("code root reads never run the checkout's fsmonitor or hooks", () => {
  const base = tmpRepo();
  const { clone: A } = remoteAndClone(base);
  const marker = path.join(base, 'marker');
  const hook = write(base, 'hook.sh', `#!/bin/sh\ntouch '${marker}'\n`);
  fs.chmodSync(hook, 0o755);
  fs.mkdirSync(path.join(A, '.git', 'hooks'), { recursive: true });
  fs.copyFileSync(hook, path.join(A, '.git', 'hooks', 'post-index-change'));
  fs.chmodSync(path.join(A, '.git', 'hooks', 'post-index-change'), 0o755);
  git(A, 'config', 'core.fsmonitor', hook);
  fs.rmSync(marker, { force: true });
  const ws = tmpRepo();
  profile(ws, [{ name: 'a', path: A }]);
  const out = plan(ws);
  assert.ok(rows(out, 'CODE_ROOT').some((r) => r[1] === 'a'));
  assert.ok(!fs.existsSync(marker), 'a checkout-configured program ran');
});

test('FETCH_HEAD age is read from the inspected checkout', () => {
  const base = tmpRepo();
  const { remote, clone: A } = remoteAndClone(base);
  const W = path.join(base, 'W');
  gitClone(remote, W);
  git(A, 'fetch', '-q');
  git(W, 'fetch', '-q');
  profile(W, [{ name: 'ext', path: A }]);
  const old = (Date.now() - 3 * 86400000) / 1000;
  const now = Date.now() / 1000;
  fs.utimesSync(path.join(A, '.git', 'FETCH_HEAD'), old, old);
  fs.utimesSync(path.join(W, '.git', 'FETCH_HEAD'), now, now);
  let row = rows(plan(W), 'CODE_ROOT').find((r) => r[1] === 'ext');
  assert.match(row[3], / unknown/);
  fs.utimesSync(path.join(A, '.git', 'FETCH_HEAD'), now, now);
  fs.utimesSync(path.join(W, '.git', 'FETCH_HEAD'), old, old);
  row = rows(plan(W), 'CODE_ROOT').find((r) => r[1] === 'ext');
  assert.match(row[3], / fresh$/);
});

test('MAXLOAD counts LOAD rows including note family members', () => {
  const d = tmpRepo();
  frame(d, { profile: 200 });
  const N = '.agents/meeting-notes';
  for (let i = 1; i <= 12; i += 1) {
    const base = `2026-10-${String(i).padStart(2, '0')}-f${i}`;
    write(d, `${N}/${base}.md`, `# F${i}\n`);
    write(d, `${N}/${base}-correction.md`, `# C\n**Corrects:** ${N}/${base}.md\n`);
    write(d, `${N}/${base}-correction-2.md`, `# C2\n**Corrects:** ${N}/${base}.md\n`);
  }
  for (const mode of ['default', 'full']) {
    const out = plan(d, ['--mode', mode]);
    const loads = rows(out, 'LOAD');
    assert.ok(loads.length <= MAXLOAD, `${mode}: ${loads.length}`);
    const loadedFamilies = new Set();
    for (let i = 1; i <= 12; i += 1) {
      const orig = `${N}/2026-10-${String(i).padStart(2, '0')}-f${i}.md`;
      const members = loads.filter((r) => r.includes(`family=${orig}`)).length;
      assert.ok(members === 0 || members === 3, `${mode}: family ${i} split (${members})`);
      if (members) loadedFamilies.add(orig);
    }
    const rejected = 12 - loadedFamilies.size;
    assert.ok(rejected > 0);
    assert.match(rows(out, 'SKIPPED_MAXLOAD')[0][1], new RegExp(`^${rejected * 3} files / \\d+ bytes$`));
  }
});

test('generated commands replay with quoted roots', () => {
  const parent = tmpRepo();
  const d = path.join(parent, "it's $(x) dir");
  fs.mkdirSync(d);
  frame(d);
  write(d, 'docs/PRD.md', prdText({ ids: 600, decisions: 3 }));
  const planOut = plan(d);
  const cmds = rows(planOut, 'EXTRACT').map((r) => field(r, 'cmd='));
  assert.ok(cmds.length >= 2);
  const page1 = run(['extract', 'register', '--root', d]).stdout;
  assert.ok(page1.includes(CONT));
  const cont = page1.split('\n').find((l) => l.startsWith(CONT)).slice(CONT.length);
  const node = shellQuote([process.execPath]);
  // Replayed from the checkout root, not from the fixture: the root comes only from the quoted --root.
  const replay = (text) => spawnSync('bash', ['-c', text.replace(/^node /, `${node} `)], { cwd: REPO, encoding: 'utf8', env: ENV });
  for (const cmd of cmds) {
    const argv = ['extract', cmd.split(' ')[1]];
    if (cmd.includes('--summary')) argv.push('--summary');
    const want = run([...argv, '--root', d]).stdout;
    const got = replay(`node .claude/lib/prime-ba.mjs ${cmd}`);
    assert.equal(got.stderr, '');
    assert.equal(got.stdout, want, cmd);
  }
  const got = replay(cont);
  assert.equal(got.stderr, '');
  assert.equal(got.stdout, run(['extract', 'register', '--root', d, '--page', '2']).stdout);
});

test('paged output survives a pipe intact', async () => {
  const d = tmpRepo();
  write(d, 'docs/PRD.md', prdText({ ids: 600 }));
  await loadChecker();
  const pages = paginate(extractRegister(d), PAGE_SIZE, 'extract register');
  assert.ok(pages.length > 1);
  const want = Buffer.byteLength(pages[0]);
  assert.ok(PAGE_SIZE - want < 200, `page 1 is ${want} bytes`);
  const r = run(['extract', 'register'], { cwd: d });
  assert.equal(Buffer.byteLength(r.stdout), want);
  assert.ok(r.stdout.endsWith('extract register --page 2\n'));
});
