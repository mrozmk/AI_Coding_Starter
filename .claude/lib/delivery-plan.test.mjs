import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { DEFAULTS, loadConfig, buildPlan, renderPlan, simulate } from './delivery-plan.mjs';
import { epicFileName, NO_CORE_WARNING, parseBacklog } from './backlog-check.mjs';

const SCRIPT = fileURLToPath(import.meta.url).replace(/\.test\.mjs$/, '.mjs');
const CHECKER = path.join(path.dirname(SCRIPT), 'backlog-check.mjs');

// ---------------------------------------------------------------------------------------------
// Fixtures — a neutral "Shop" backlog built from a compact Task list; every case writes its own.
// Optimal velocity 96 → 9.6 pts per full-share person per day; pessimistic 64 → 6.4.
// ---------------------------------------------------------------------------------------------

const SIZE = { 4: 'M', 8: 'H', 16: 'XH' };
const TASK_HEADER = `| ID | Epic | Task | Type | Size | Pts | Depends on | Relates | Chain | Scope | Node | Traces | Status | Jira | Ref |
|----|------|------|------|------|-----|------------|---------|-------|-------|------|--------|--------|------|-----|`;
const OUTSIDE_HEADER = `| ID | Owner | Item | Needed by | Starts after | Traces | Notes |
|----|-------|------|-----------|--------------|--------|-------|`;

const T = (id, scope, pts, deps = [], extra = {}) => ({ id, scope, pts, deps, ...extra });

function backlogMd(tasks, { outside = [] } = {}) {
  const epics = [...new Set(tasks.map((t) => t.id.split('-')[0]))];
  const epicRows = epics.map((e) => {
    const pts = tasks.filter((t) => t.id.startsWith(`${e}-`)).reduce((a, t) => a + t.pts, 0);
    return `| ${e} | Epic ${e} | outcome ${e} | assumption | ${pts} | — | — |`;
  });
  const rows = tasks.map((t) => `| ${t.id} | ${t.id.split('-')[0]} | ${t.title ?? `Task ${t.id}`}${t.withdrawn ? ' (withdrawn)' : ''} | story | ${SIZE[t.pts]} | ${t.pts} | ${t.deps.join(', ') || '—'} | — | ${t.chain ?? '—'} | ${t.scope} | ${t.node ?? '—'} | ${(t.traces ?? []).join(', ') || '—'} | ${t.status ?? 'TODO'} | — | — |`);
  return `# Shop — Backlog (Epics + Tasks)
**Date:** 2026-10-10 · **Sizes:** M=4 · H=8 · XH=16 points · **Detail:** full

## Epic map
| Epic | Title | Outcome | Key assumption | Pts | Depends on | Jira |
|------|-------|---------|----------------|-----|------------|------|
${epicRows.join('\n')}

## Task table
${TASK_HEADER}
${rows.join('\n')}

## Story map
<!-- storymap:begin -->
<!-- storymap:end -->

## Outside the dev backlog
${OUTSIDE_HEADER}
${outside.join('\n')}

## External blockers
- none
`;
}

const DISCOVERY = `# Discovery — Shop

## Flows

### FL-1 — Place order

**Critical:** yes

- **FL-1.A1** — Sign in
- **FL-1.A2** — Place order
`;

/** One Epic file per Epic of the Task table: per live Task its heading, a Summary and one criterion. */
function epicFilesFor(md) {
  const parsed = parseBacklog(md);
  return parsed.epics.map((e) => {
    const blocks = parsed.tasks.filter((t) => t.epic === e.id && !t.withdrawn)
      .map((t) => `## ${t.id} — ${t.title}\n**Summary:** ${t.title} for the shop.\n### Acceptance criteria\n- **${t.id}.AC1** — Given a shop, when ${t.id} is used, then it works.\n`);
    return { name: epicFileName(e.id, e.title), text: `# ${e.id} — ${e.title}\n\n${blocks.join('\n')}` };
  });
}

/** A project with `backlog` and its Epic files (default: derived from the backlog's Task table). */
function project({ backlog, epicFiles = epicFilesFor(backlog), discovery = null, profile = null } = {}) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'delivery-plan-'));
  fs.mkdirSync(path.join(dir, '.agents'));
  fs.mkdirSync(path.join(dir, 'docs'));
  fs.mkdirSync(path.join(dir, '.claude'));
  fs.writeFileSync(path.join(dir, '.agents', 'backlog.md'), backlog);
  if (epicFiles.length) fs.mkdirSync(path.join(dir, '.agents', 'backlog'));
  for (const f of epicFiles) fs.writeFileSync(path.join(dir, '.agents', 'backlog', f.name), f.text);
  if (discovery !== null) fs.writeFileSync(path.join(dir, 'docs', 'discovery.md'), discovery);
  if (profile !== null) fs.writeFileSync(path.join(dir, '.claude', 'project-profile.json'), typeof profile === 'string' ? profile : JSON.stringify(profile));
  return dir;
}

function run(dir, ...flags) {
  const r = spawnSync(process.execPath, [SCRIPT, '--root', dir, ...flags], { encoding: 'utf8' });
  return { code: r.status, out: r.stdout + r.stderr, stdout: r.stdout };
}

const planOf = (tasks, { flags = [], ...opts } = {}) => {
  const dir = project({ backlog: backlogMd(tasks, opts), ...opts });
  const r = run(dir, '--json', ...flags);
  assert.equal(r.code, 0, r.out);
  return JSON.parse(r.stdout);
};

const close = (actual, expected, msg) => assert.ok(Math.abs(actual - expected) < 0.01, `${msg ?? ''} expected ${expected}, got ${actual}`);
const entry = (plan, id) => plan.schedule.find((s) => s.id === id);
const planFile = (dir) => path.join(dir, '.agents', 'backlog', 'delivery-plan.md');

// ---------------------------------------------------------------------------------------------
// 1. Solo, 3 sessions
// ---------------------------------------------------------------------------------------------

test('solo: CORE 0.83 d, MUST done 2.5 d (two Tasks share the person), COULD done 4.17 d; pessimistic × 1.5', () => {
  const p = planOf([T('E1-1', 'CORE', 8), T('E1-2', 'MUST', 8, ['E1-1']), T('E1-3', 'MUST', 8, ['E1-1']), T('E1-4', 'COULD', 16)], { flags: ['--mode', 'solo'] });
  assert.equal(p.config.mode, 'solo');
  close(p.summary.optimal.core.days, 0.833);
  close(p.summary.optimal.development.days, 2.5);
  close(p.summary.optimal.total.days, 4.167);
  close(p.summary.optimal.couldTail.days, 1.667);
  close(p.summary.pessimistic.core.days, 1.25);
  close(p.summary.pessimistic.development.days, 3.75);
  close(p.summary.pessimistic.total.days, 6.25);
  // B and C run side by side at 4.8 pts/day each.
  close(entry(p, 'E1-2').optimal.start, 0.833);
  close(entry(p, 'E1-3').optimal.start, 0.833);
  close(entry(p, 'E1-2').optimal.end, 2.5);
  assert.equal(p.summary.core, null);
  assert.equal(p.summary.optimal.join, null);
});

// ---------------------------------------------------------------------------------------------
// 2. COULD is a strict tail
// ---------------------------------------------------------------------------------------------

test('COULD is a strict tail: MUST done is identical with or without COULD rows', () => {
  const must = [T('E1-1', 'MUST', 16)];
  const withCould = planOf([...must, T('E2-1', 'COULD', 16), T('E2-2', 'COULD', 16)], { flags: ['--mode', 'solo'] });
  const without = planOf(must, { flags: ['--mode', 'solo'] });
  close(withCould.summary.optimal.development.days, 1.667);
  assert.equal(withCould.summary.optimal.development.days, without.summary.optimal.development.days);
  for (const s of withCould.schedule.filter((x) => x.scope === 'COULD')) assert.ok(s.optimal.start >= 1.667 - 0.01, `${s.id} starts at ${s.optimal.start}`);
});

// ---------------------------------------------------------------------------------------------
// 3. Team CORE variants
// ---------------------------------------------------------------------------------------------

test('team CORE variants: independent CORE → + 1; chained CORE → alone; --core-developers 0 forces alone', () => {
  const independent = [T('E1-1', 'CORE', 8), T('E1-2', 'CORE', 8), T('E2-1', 'MUST', 4, ['E1-1', 'E1-2'])];
  const a = planOf(independent);
  close(a.summary.core.alone.optimal.days, 1.667);
  close(a.summary.core.plusOne.optimal.days, 0.833);
  assert.equal(a.summary.core.recommendation, '+1');
  assert.equal(a.summary.core.chosen, '+1');
  assert.equal(a.summary.core.decidedBy, 'rule');
  close(a.summary.optimal.core.days, 0.833);
  assert.deepEqual(a.phases[0].team.map((x) => x.name), ['Tech Lead', 'Dev 1']);

  const b = planOf([T('E1-1', 'CORE', 8), T('E1-2', 'CORE', 8, ['E1-1']), T('E2-1', 'MUST', 4, ['E1-2'])]);
  close(b.summary.core.alone.optimal.days, 1.667);
  close(b.summary.core.plusOne.optimal.days, 1.667);
  assert.equal(b.summary.core.recommendation, 'alone');
  assert.equal(b.summary.core.chosen, 'alone');

  const c = planOf(independent, { flags: ['--core-developers', '0'] });
  assert.equal(c.summary.core.recommendation, '+1');
  assert.equal(c.summary.core.chosen, 'alone');
  assert.equal(c.summary.core.decidedBy, 'override');
  close(c.summary.optimal.core.days, 1.667);
  assert.deepEqual(c.phases[0].team.map((x) => x.name), ['Tech Lead']);
});

// ---------------------------------------------------------------------------------------------
// 4. Scale team rates
// ---------------------------------------------------------------------------------------------

test('scale team rates: developers finish their three Tasks at coreEnd + 2.5 d, the Tech Lead his two at + 3.33 d', () => {
  const must = Array.from({ length: 8 }, (_, i) => T(`E2-${i + 1}`, 'MUST', 8, ['E1-1']));
  const p = planOf([T('E1-1', 'CORE', 8), ...must]);
  const coreEnd = p.summary.optimal.core.days;
  close(coreEnd, 0.833);
  const mine = (name) => p.schedule.filter((s) => s.person === name && s.scope === 'MUST');
  for (const name of ['Dev 1', 'Dev 2']) {
    assert.equal(mine(name).length, 3, name);
    for (const s of mine(name)) close(s.optimal.end, coreEnd + 2.5, `${name} ${s.id}`);
  }
  assert.equal(mine('Tech Lead').length, 2);
  for (const s of mine('Tech Lead')) close(s.optimal.end, coreEnd + 3.333, `Tech Lead ${s.id}`);
  close(p.summary.optimal.development.days, coreEnd + 3.333);
});

// ---------------------------------------------------------------------------------------------
// 5. Invariants on a ~12-Task fixture
// ---------------------------------------------------------------------------------------------

const TWELVE = [
  T('E1-1', 'CORE', 8, [], { node: 'platform' }),
  T('E1-2', 'CORE', 4, ['E1-1'], { node: 'auth' }),
  T('E1-3', 'CORE', 8, [], { node: 'catalog', status: 'DONE' }),
  T('E2-1', 'MUST', 8, ['E1-2'], { node: 'auth' }),
  T('E2-2', 'MUST', 16, ['E1-1'], { node: 'orders' }),
  T('E2-3', 'MUST', 4, ['E2-2'], { node: 'orders' }),
  T('E2-4', 'MUST', 8, ['E1-3'], { node: 'catalog' }),
  T('E2-5', 'MUST', 4, ['E2-1', 'E2-4']),
  T('E2-6', 'MUST', 8, ['E1-1'], { withdrawn: true }),
  T('E3-1', 'COULD', 8, ['E2-3'], { node: 'reporting' }),
  T('E3-2', 'COULD', 4, ['E2-6']),
  T('E3-3', 'COULD', 16, [], { node: 'reporting' }),
];

test('invariants: dependencies, strict phases, determinism, DONE and withdrawn Tasks, pessimistic = optimal × 1.5', () => {
  const dir = project({ backlog: backlogMd(TWELVE) });
  const r1 = run(dir, '--json');
  const r2 = run(dir, '--json');
  assert.equal(r1.code, 0, r1.out);
  assert.equal(r1.stdout, r2.stdout, 'two runs give identical JSON');
  const p = JSON.parse(r1.stdout);
  const ids = p.schedule.map((s) => s.id);
  assert.ok(!ids.includes('E1-3'), 'a DONE Task is not scheduled');
  assert.ok(!ids.includes('E2-6'), 'a withdrawn Task is not scheduled');
  assert.equal(ids.length, 10);
  const byId = new Map(p.schedule.map((s) => [s.id, s]));
  for (const t of TWELVE) {
    const s = byId.get(t.id);
    if (!s) continue;
    for (const d of t.deps) if (byId.has(d)) assert.ok(s.start >= byId.get(d).end - 1e-6, `${t.id} starts before ${d} ends`);
  }
  const coreEnd = p.summary.units.core;
  for (const s of p.schedule.filter((x) => x.scope !== 'CORE')) assert.ok(s.start >= coreEnd - 1e-6, `${s.id} starts before CORE ends`);
  const mustEnd = p.summary.units.development;
  for (const s of p.schedule.filter((x) => x.scope === 'COULD')) assert.ok(s.start >= mustEnd - 1e-6, `${s.id} starts before MUST ends`);
  // E2-4 depends only on the DONE E1-3: ready at the join.
  close(byId.get('E2-4').start, coreEnd);
  // E3-2 depends only on the withdrawn E2-6: ready when COULD opens.
  close(byId.get('E3-2').start, mustEnd);
  for (const s of p.schedule) {
    close(s.pessimistic.start, s.optimal.start * 1.5, `${s.id} start`);
    close(s.pessimistic.end, s.optimal.end * 1.5, `${s.id} end`);
  }
  for (const k of ['core', 'development', 'couldTail', 'total']) close(p.summary.pessimistic[k].days, p.summary.optimal[k].days * 1.5, k);
});

// ---------------------------------------------------------------------------------------------
// 6. Node avoidance
// ---------------------------------------------------------------------------------------------

test('node avoidance: two sessions take different Nodes first; an unavoidable same-Node pair is listed', () => {
  const flags = ['--mode', 'solo', '--sessions', '2'];
  const a = planOf([T('E1-1', 'MUST', 8, [], { node: 'orders' }), T('E1-2', 'MUST', 8, [], { node: 'orders' }), T('E1-3', 'MUST', 16, [], { node: 'auth' })], { flags });
  // E1-3 outlasts E1-1, so E1-2 starts only after E1-1 ends — the Nodes never meet.
  assert.equal(entry(a, 'E1-1').start, 0);
  assert.equal(entry(a, 'E1-3').start, 0);
  close(entry(a, 'E1-2').start, entry(a, 'E1-1').end);
  assert.deepEqual(a.phases.flatMap((x) => x.overlaps), []);

  const b = planOf([T('E1-1', 'MUST', 8, [], { node: 'orders' }), T('E1-2', 'MUST', 8, [], { node: 'orders' })], { flags });
  assert.equal(entry(b, 'E1-1').start, 0);
  assert.equal(entry(b, 'E1-2').start, 0);
  assert.deepEqual(b.phases.flatMap((x) => x.overlaps), [{ node: 'orders', a: 'E1-1', b: 'E1-2' }]);
  assert.ok(b.warnings.some((w) => /Node orders: E1-1 and E1-2 run at the same time/.test(w)), b.warnings.join('\n'));
});

test('node avoidance: Tasks with Node — never collide and are never listed as overlaps', () => {
  const c = planOf([
    T('E1-1', 'MUST', 4, [], { traces: ['FL-1.A1'] }),
    T('E1-2', 'MUST', 4, [], { traces: ['FL-1.A2'] }),
    T('E1-3', 'MUST', 16, [], { node: 'orders' }),
  ], { flags: ['--mode', 'solo', '--sessions', '2'], discovery: DISCOVERY });
  assert.ok(entry(c, 'E1-1').critical && entry(c, 'E1-2').critical);
  assert.equal(entry(c, 'E1-1').start, 0);
  assert.equal(entry(c, 'E1-2').start, 0);
  assert.ok(entry(c, 'E1-3').start > 0, 'the lower-priority Task waits');
  assert.deepEqual(c.phases.flatMap((x) => x.overlaps), []);
});

// ---------------------------------------------------------------------------------------------
// 7. Gate
// ---------------------------------------------------------------------------------------------

const PRE_SCOPE = `# Shop — Backlog (Epics + Tasks)

## Epic map
| Epic | Title | Outcome | Key assumption | Pts | Depends on | Jira |
|------|-------|---------|----------------|-----|------------|------|
| E1 | Foundation | skeleton | monolith | 8 | — | — |

## Task table
| ID | Epic | Task | Type | Size | Pts | Depends on | Wave | Slice | Node | Traces | Status | Jira | Ref |
|----|------|------|------|------|-----|------------|------|-------|------|--------|--------|------|-----|
| E1-1 | E1 | Project scaffold | tech | H | 8 | — | 0 | WS | — | — | TODO | — | — |
`;

const LEGACY = `# Old — Backlog
## Work packages — pipeline inputs
| Package | Task scope | Depends on | Entry | Status |
|---|---|---|---|---|
| MVP | E0-1 | — | /brainstorm | TODO |
`;

// Criteria still in a `## Acceptance criteria` section of backlog.md: the pre-detail shape.
const PRE_DETAIL = backlogMd([T('E1-1', 'CORE', 8)]).replace('## Story map', '## Acceptance criteria\n### E1-1 — Task E1-1\n- **E1-1.AC1** — Given a shop, when E1-1 is used, then it works.\n\n## Story map');

test('gate: checker error, pre-Scope, pre-detail and legacy backlogs exit 1 with nothing written and no schedule', () => {
  const broken = backlogMd([T('E1-1', 'CORE', 8), T('E1-2', 'MUST', 8, ['E9-9'])]);
  const cases = [['checker error', broken, /unknown dependency E9-9/], ['pre-Scope', PRE_SCOPE, /pre-Scope backlog/],
    ['pre-detail', PRE_DETAIL, /acceptance criteria still in \.agents\/backlog\.md — run: node \.claude\/lib\/backlog-migrate\.mjs --write/], ['legacy', LEGACY, /legacy WP backlog/]];
  for (const [label, backlog, re] of cases) {
    for (const flags of [['--write'], ['--json', '--write']]) {
      const dir = project({ backlog, epicFiles: [] });
      const r = run(dir, ...flags);
      assert.equal(r.code, 1, `${label} ${flags}: ${r.out}`);
      assert.match(r.out, re, label);
      assert.ok(!fs.existsSync(planFile(dir)), `${label}: nothing written`);
      assert.ok(!fs.existsSync(path.join(dir, '.agents', 'backlog')), `${label}: no directory`);
      assert.doesNotMatch(r.out, /## Task schedule|"schedule"/, label);
    }
  }
  const json = JSON.parse(run(project({ backlog: PRE_DETAIL, epicFiles: [] }), '--json').stdout);
  assert.equal(json.preDetail, true);
  assert.equal(json.errors.length, 1);
  // A Detail: full backlog whose Epic files are missing names the missing criteria.
  const bare = run(project({ backlog: backlogMd([T('E1-1', 'CORE', 8)]), epicFiles: [] }));
  assert.equal(bare.code, 1, bare.out);
  assert.match(bare.out, /Task E1-1: no acceptance criterion/);
  const plain = run(project({ backlog: broken }));
  assert.match(plain.out, /^delivery-plan: the backlog has errors — fix them first:/);
});

test('gate: an invalid config value or profile exits 2', () => {
  const backlog = backlogMd([T('E1-1', 'CORE', 8)]);
  const share = run(project({ backlog, profile: { schema: 1, delivery: { team: { tl_scale_share: 2 } } } }));
  assert.equal(share.code, 2, share.out);
  assert.match(share.out, /delivery\.team\.tl_scale_share/);
  const sessions = run(project({ backlog }), '--sessions', '9');
  assert.equal(sessions.code, 2);
  assert.match(sessions.out, /delivery\.team\.developer_sessions/);
  const mode = run(project({ backlog }), '--mode', 'crowd');
  assert.equal(mode.code, 2);
  assert.match(mode.out, /delivery\.mode/);
  const core = run(project({ backlog }), '--core-developers', '2');
  assert.equal(core.code, 2);
  assert.match(core.out, /core_developers/);
  const notJson = run(project({ backlog, profile: '{ not json' }));
  assert.equal(notJson.code, 2);
  assert.match(notJson.out, /not valid JSON/);
  assert.equal(run(project({ backlog }), '--bogus').code, 2);
  const swapped = run(project({ backlog, profile: { schema: 1, delivery: { velocity: { pessimistic: 120, optimal: 60 } } } }));
  assert.equal(swapped.code, 2, swapped.out);
  assert.match(swapped.out, /delivery\.velocity\.pessimistic.*must not exceed velocity\.optimal/);
});

test('loadConfig: defaults, profile merge, flag override', () => {
  const dir = project({ backlog: backlogMd([T('E1-1', 'CORE', 8)]) });
  assert.deepEqual(loadConfig(dir, {}).config, { ...DEFAULTS, team: { ...DEFAULTS.team } });
  fs.writeFileSync(path.join(dir, '.claude', 'project-profile.json'), JSON.stringify({ schema: 1, delivery: { mode: 'solo', velocity: { optimal: 80 }, team: { core_developers: 1 } } }));
  const { config } = loadConfig(dir, { sessions: '2' });
  assert.equal(config.mode, 'solo');
  assert.equal(config.velocity.optimal, 80);
  assert.equal(config.velocity.pessimistic, 64);
  assert.equal(config.solo.sessions, 2);
  assert.equal(config.team.core_developers, 1);
  assert.equal(loadConfig(dir, { mode: 'team', developers: '4', coreDevelopers: 'auto' }).config.team.developers, 4);
});

// ---------------------------------------------------------------------------------------------
// 8. Render
// ---------------------------------------------------------------------------------------------

const HEADINGS = ['# Delivery plan', '## Summary', '## Warnings', '## Needed from other teams', '## Sprints', '## Order per person and session', '## Task schedule', '## Chains', '## Analysis'];

test('render: --write creates the file with the headings in order, the analysis markers, no year and no currency', () => {
  const tasks = [
    T('E1-1', 'CORE', 8, [], { node: 'platform' }),
    T('E2-1', 'MUST', 8, ['E1-1'], { node: 'orders', chain: 'order-flow' }),
    T('E2-2', 'MUST', 4, ['E2-1'], { node: 'orders', chain: 'order-flow' }),
    T('E2-3', 'COULD', 4, ['E1-1']),
  ];
  const dir = project({ backlog: backlogMd(tasks, { outside: ['| X-1 | DevOps | Deployment pipeline | E1-1 | — | — | — |', '| X-2 | QA | Test data | E2-1 | — | — | — |'] }) });
  const r = run(dir, '--write');
  assert.equal(r.code, 0, r.out);
  assert.match(r.out, /wrote \.agents\/backlog\/delivery-plan\.md/);
  const md = fs.readFileSync(planFile(dir), 'utf8');
  let at = -1;
  for (const h of HEADINGS) {
    const i = md.split('\n').indexOf(h);
    assert.ok(i > at, `${h} missing or out of order`);
    at = i;
  }
  assert.match(md, /^> Generated by delivery-plan\.mjs — do not edit; rerun \/setup:delivery-plan\.$/m);
  assert.match(md, /^\*\*Backlog:\*\* sha256 [0-9a-f]{12} · \*\*Mode:\*\* team · \*\*Velocity:\*\* 64 \/ 96 pts per person per sprint \(10 working days\)$/m);
  // The header cites the fingerprint of the whole set (backlog.md + Epic files), the checker's own.
  const fp = spawnSync(process.execPath, [CHECKER, '--root', dir, '--fingerprint'], { encoding: 'utf8' });
  assert.equal(fp.status, 0, fp.stderr);
  assert.match(md, new RegExp(`^\\*\\*Backlog:\\*\\* sha256 ${fp.stdout.trim()} · `, 'm'));
  assert.match(md, /<!-- analysis:begin -->\n_Not written — run \/setup:delivery-plan\._\n<!-- analysis:end -->/);
  assert.doesNotMatch(md, /\b(19|20)\d\d\b/, 'no four-digit year');
  assert.doesNotMatch(md, /[$€£¥]/, 'no currency sign');
  assert.match(md, /\| order-flow \| E2-1 → E2-2 \| 12 \|/);
  assert.match(md, /### Before CORE[\s\S]*\| X-1 \| DevOps \|/);
  assert.match(md, /### During scale[\s\S]*\| X-2 \| QA \|/);
  assert.match(md, /outside X-1 \(DevOps: Deployment pipeline\) is needed by CORE Task E1-1/);
  // stdout render = the written file; reruns are byte-identical.
  assert.equal(run(dir).stdout, md);
  run(dir, '--write');
  assert.equal(fs.readFileSync(planFile(dir), 'utf8'), md);
});

test('outside rows: Starts after gives the day the other team can begin; a non-positive window and BLOCKED Tasks are warned', () => {
  const tasks = [
    T('E1-1', 'CORE', 8),
    T('E2-1', 'MUST', 8, ['E1-1']),
    T('E2-2', 'MUST', 8, ['E1-1'], { status: 'BLOCKED' }),
    T('E2-3', 'MUST', 8, ['E2-1']),
    T('E3-1', 'MUST', 4, ['E1-1'], { status: 'DONE' }),
  ];
  const outside = [
    '| X-1 | QA | End-to-end suite | — | E2-1, E2-3 | — | — |',     // follows developer work
    '| X-2 | QA | Test data | E2-3 | E2-1 | — | — |',                // E2-3 starts the moment E2-1 ends: no window
    '| X-3 | DevOps | Review environment | E2-3 | E1-1 | — | — |',   // E1-1 ends before E2-3 starts: fine
    '| X-4 | QA | Smoke run | — | E3-1 | — | — |',                   // everything it waited for is done
    '| X-5 | Design | Icons | — | — | — | — |',
  ];
  const plan = buildPlan({ backlog: parseBacklog(backlogMd(tasks, { outside })), flows: [], config: structuredClone(DEFAULTS) });
  const slot = new Map(plan.schedule.map((s) => [s.id, s]));
  const row = new Map(plan.outside.map((x) => [x.id, x]));
  assert.deepEqual(plan.outside.map((x) => [x.id, x.when]), [['X-1', 'follows developer work'], ['X-2', 'during scale'], ['X-3', 'during scale'], ['X-4', 'follows developer work'], ['X-5', 'no Task named']]);
  assert.deepEqual(row.get('X-1').startsAfter, ['E2-1', 'E2-3']);
  assert.equal(row.get('X-1').canStart, Math.max(slot.get('E2-1').end, slot.get('E2-3').end));
  assert.deepEqual(row.get('X-1').canStartDay, { pessimistic: slot.get('E2-3').pessimistic.end, optimal: slot.get('E2-3').optimal.end });
  assert.equal(row.get('X-1').firstStart, null);
  assert.equal(row.get('X-2').canStart, slot.get('E2-1').end);
  assert.equal(row.get('X-3').canStart, slot.get('E1-1').end);
  assert.deepEqual([row.get('X-4').startsAfter, row.get('X-4').canStart], [[], 0], 'a done Task no longer delays the item');
  assert.deepEqual([row.get('X-5').canStart, row.get('X-5').canStartDay], [null, null]);

  assert.ok(slot.get('E2-3').start <= slot.get('E2-1').end + 1e-9, 'fixture: E2-3 starts when E2-1 ends');
  const windowless = plan.warnings.filter((w) => /can start only on/.test(w));
  assert.equal(windowless.length, 1, plan.warnings.join('\n'));
  assert.match(windowless[0], /^outside X-2 \(QA: Test data\) can start only on day [\d.]+ \/ [\d.]+ \(pessimistic \/ optimal — after E2-1\), yet E2-3 needs it from day [\d.]+ \/ [\d.]+ — no time left for it; the plan does not wait for other teams$/);
  assert.ok(plan.warnings.includes("1 BLOCKED Task is scheduled as if unblocked: E2-2 — the plan assumes each blocker is cleared before the Task's start day"), plan.warnings.join('\n'));
  assert.ok(slot.has('E2-2'), 'a BLOCKED Task stays in the schedule');

  const md = renderPlan(plan);
  assert.match(md, /### Follows developer work\n\n\| ID \| Owner \| Item \| Needed by \| First start — pessimistic \| First start — optimal \| Starts after \| Can start — pessimistic \| Can start — optimal \|/);
  assert.match(md, /\| X-1 \| QA \| End-to-end suite \| — \| — \| — \| E2-1, E2-3 \| day [\d.]+ \| day [\d.]+ \|/);
  assert.match(md, /\| X-4 \| QA \| Smoke run \| — \| — \| — \| — \| now \| now \|/);
  assert.match(md, /\| X-5 \| Design \| Icons \| — \| — \| — \| — \| — \| — \|/);
  const clean = buildPlan({ backlog: parseBacklog(backlogMd(tasks.map((t) => ({ ...t, status: t.status === 'BLOCKED' ? 'TODO' : t.status })))), flows: [], config: structuredClone(DEFAULTS) });
  assert.equal(clean.warnings.some((w) => /BLOCKED/.test(w)), false);
});

test('outside rows: an item needed by CORE that waits for a CORE Task is "during CORE", not "before CORE"', () => {
  const tasks = [T('E1-1', 'CORE', 8), T('E1-2', 'CORE', 8, ['E1-1']), T('E1-3', 'CORE', 8, ['E1-2']), T('E2-1', 'MUST', 8, ['E1-3'])];
  const outside = [
    '| X-1 | DevOps | Cluster access | E1-1 | — | — | — |',       // before CORE
    '| X-2 | DevOps | Seed data | E1-3 | E1-1 | — | — |',         // a window: E1-2 runs in between
    '| X-3 | QA | Contract review | E1-2 | E1-1 | — | — |',       // no window
  ];
  const plan = buildPlan({ backlog: parseBacklog(backlogMd(tasks, { outside })), flows: [], config: structuredClone(DEFAULTS) });
  assert.deepEqual(plan.outside.map((x) => [x.id, x.when]), [['X-1', 'before CORE'], ['X-2', 'during CORE'], ['X-3', 'during CORE']]);
  const about = (id) => plan.warnings.filter((w) => w.startsWith(`outside ${id} `));
  assert.deepEqual(about('X-1'), ['outside X-1 (DevOps: Cluster access) is needed by CORE Task E1-1 — it must be ready before CORE starts']);
  assert.equal(about('X-2').length, 1, plan.warnings.join('\n'));
  assert.match(about('X-2')[0], /^outside X-2 \(DevOps: Seed data\) is needed by CORE work \(E1-3\) from day [\d.]+ \/ [\d.]+ and can start on day [\d.]+ \/ [\d.]+ \(pessimistic \/ optimal — after E1-1\) — it must be done in between$/);
  assert.equal(about('X-3').length, 1, plan.warnings.join('\n'));
  assert.match(about('X-3')[0], /can start only on .* yet E1-2 needs it from .* — no time left for it/);
  assert.match(renderPlan(plan), /### During CORE\n\n\| ID \|/);
});

test('config: --tl-share overrides team.tl_scale_share and is validated', () => {
  const dir = project({ backlog: backlogMd([T('E1-1', 'CORE', 8), T('E2-1', 'MUST', 8, ['E1-1'])]) });
  const full = run(dir, '--tl-share', '1', '--json');
  assert.equal(full.code, 0, full.out);
  assert.equal(JSON.parse(full.stdout).config.team.tl_scale_share, 1);
  assert.equal(JSON.parse(run(dir, '--json').stdout).config.team.tl_scale_share, 0.5);
  assert.equal(JSON.parse(run(dir, '--tl-share', '.25', '--json').stdout).config.team.tl_scale_share, 0.25, 'a bare fraction is a number');
  const bad = run(dir, '--tl-share', '1.5');
  assert.equal(bad.code, 2, bad.out);
  assert.match(bad.out, /invalid delivery\.team\.tl_scale_share: 1\.5 — must be a number in \(0, 1\]/);
});

test('render: renderPlan is pure and lists an outside row only while its Task is open', () => {
  const tasks = [T('E1-1', 'CORE', 8, [], { status: 'DONE' }), T('E2-1', 'MUST', 8, ['E1-1'])];
  const parsed = parseBacklog(backlogMd(tasks, { outside: ['| X-1 | DevOps | Deployment pipeline | E1-1 | — | — | — |'] }));
  const plan = buildPlan({ backlog: parsed, flows: [], config: structuredClone(DEFAULTS) });
  assert.deepEqual(plan.outside, []);
  assert.equal(renderPlan(plan), renderPlan(plan));
});

// ---------------------------------------------------------------------------------------------
// 9. Empty parts
// ---------------------------------------------------------------------------------------------

test('empty parts: no CORE Task → CORE 0 days and the warning; everything DONE → all zeros', () => {
  const a = planOf([T('E1-1', 'MUST', 8), T('E1-2', 'COULD', 4)]);
  assert.equal(a.summary.units.core, 0);
  assert.equal(a.summary.optimal.core.days, 0);
  assert.equal(a.summary.core.chosen, 'alone');
  assert.ok(a.warnings.includes(NO_CORE_WARNING), a.warnings.join('\n'));
  close(entry(a, 'E1-1').start, 0);

  const b = planOf([T('E1-1', 'CORE', 8, [], { status: 'DONE' }), T('E1-2', 'MUST', 8, ['E1-1'], { status: 'DONE' })]);
  assert.deepEqual(b.summary.units, { core: 0, development: 0, couldTail: 0, total: 0 });
  for (const v of ['optimal', 'pessimistic']) {
    assert.equal(b.summary[v].total.days, 0);
    assert.deepEqual(b.sprints[v], []);
  }
  assert.deepEqual(b.schedule, []);
});

test('simulate: an empty set ends where it starts', () => {
  assert.deepEqual(simulate([], [{ name: 'Developer', share: 1, sessions: 3 }], 5), { end: 5, records: [], overlaps: [], intervals: [] });
});

// ---------------------------------------------------------------------------------------------
// 10. Utilisation counts progress
// ---------------------------------------------------------------------------------------------

test('utilisation counts progress: eight 4 → 16 → 16 → 16 chains keep every session busy through the first sprint', () => {
  const tasks = [];
  for (let e = 1; e <= 8; e += 1) {
    tasks.push(T(`E${e}-1`, 'MUST', 4));
    for (let k = 2; k <= 4; k += 1) tasks.push(T(`E${e}-${k}`, 'MUST', 16, [`E${e}-${k - 1}`]));
  }
  const p = planOf(tasks);
  const first = p.sprints.optimal[0];
  assert.equal(first.sprint, 1);
  assert.equal(first.done, 160);
  close(first.progress, 240);
  close(first.capacity, 240);
  close(first.utilisation, 1);
  assert.ok(!p.warnings.some((w) => /first scale sprint/.test(w)), p.warnings.join('\n'));
  assert.ok(!p.warnings.some((w) => /ready for/.test(w)), p.warnings.join('\n'));
});

test('first scale sprint: time after the plan ends is not idle capacity; a starved scale team still warns', () => {
  // CORE 8, then two MUST 8 on two developers: every session with work is busy until the plan ends.
  const short = planOf([T('E1-1', 'CORE', 8), T('E2-1', 'MUST', 8, ['E1-1']), T('E2-2', 'MUST', 8, ['E1-1'])]);
  assert.ok(!short.warnings.some((w) => /first scale sprint/.test(w)), short.warnings.join('\n'));
  // One serial MUST chain: one developer works 48 units while 2.5 people are on the team.
  const serial = planOf([T('E1-1', 'CORE', 8), T('E2-1', 'MUST', 16, ['E1-1']), T('E2-2', 'MUST', 16, ['E2-1']), T('E2-3', 'MUST', 16, ['E2-2'])]);
  const w = serial.warnings.find((x) => /first scale sprint/.test(x));
  assert.ok(w, serial.warnings.join('\n'));
  assert.match(w, /44 % used — progress 56\.0 of capacity 128\.0 pts/);
});

test('an empty COULD tail ends in no sprint', () => {
  const dir = project({ backlog: backlogMd([T('E1-1', 'CORE', 8), T('E2-1', 'MUST', 8, ['E1-1'])]) });
  const p = JSON.parse(run(dir, '--json').stdout);
  assert.equal(p.summary.optimal.couldTail.days, 0);
  assert.equal(p.summary.optimal.couldTail.sprint, 0);
  assert.equal(p.summary.pessimistic.couldTail.sprint, 0);
  const tail = run(dir).stdout.split('\n').find((l) => l.startsWith('| COULD tail |'));
  assert.ok(!/ends in sprint/.test(tail), tail);
});
