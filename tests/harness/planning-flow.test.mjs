import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { BACKLOG, backlogWriteBack, matchWorkPackage, parseBacklog, staleSignals, writeBackText } from '../../harness-source/scripts/backlog.mjs';

const REPO = path.resolve(import.meta.dirname, '../..');
const SPEC = '.agents/specs/2026-09-05-nightly-export.md';

const BACKLOG_TEXT = `# Backlog

## Work packages — pipeline inputs

| Package | Task scope | Depends on | Entry (how to run) | Status |
|---------|-----------|-----------|--------------------|--------|
| **NIGHTLY-EXPORT** | E1-1, E1-2 | — | \`/brainstorm nightly export → spec → /plan-feature <spec>\` | TODO |
| **AUTH** | E2-1 | — | \`/brainstorm auth\` | TODO |
| **REPORTS** | E3-1 | NIGHTLY-EXPORT | \`/brainstorm reports\` | TODO |

## Task table

| ID | Epic | Task | Description | Dependencies | Difficulty | Type | Wave | Status | Ref |
|----|------|------|-------------|--------------|------------|------|------|--------|-----|
| E1-1 | Export | Nightly CSV job | worker | — | S | core | 1 | TODO | — |
| E1-2 | Export | Export bucket config | storage | E1-1 | S | — | 1 | TODO | — |
| E2-1 | Auth | Login | login form | — | M | core | 1 | TODO | — |
| E3-1 | Reports | Weekly report | reads exports | E1-1 | M | — | 2 | TODO | — |
`;

function project(backlog = BACKLOG_TEXT) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'harness backlog-'));
  fs.mkdirSync(path.join(dir, '.agents/specs'), { recursive: true });
  fs.mkdirSync(path.join(dir, '.agents/plans/active'), { recursive: true });
  fs.mkdirSync(path.join(dir, '.agents/plans/done'), { recursive: true });
  if (backlog !== null) fs.writeFileSync(path.join(dir, BACKLOG), backlog);
  fs.writeFileSync(path.join(dir, SPEC), '# Design: Nightly export\n');
  return dir;
}

test('backlog write-back updates exactly the matched work package; none or ambiguous ownership writes nothing', () => {
  const root = project();
  const preview = backlogWriteBack({ projectRoot: root, spec: SPEC });
  assert.equal(preview.status, 'matched');
  assert.equal(preview.package, 'NIGHTLY-EXPORT');
  assert.equal(preview.written, false);
  assert.equal(fs.readFileSync(path.join(root, BACKLOG), 'utf8'), BACKLOG_TEXT, 'no consent → untouched');

  const res = backlogWriteBack({ projectRoot: root, spec: SPEC, consent: true });
  assert.equal(res.written, true);
  const after = parseBacklog(fs.readFileSync(path.join(root, BACKLOG), 'utf8'));
  assert.equal(after.packages.find((p) => p.name === 'NIGHTLY-EXPORT').status, 'WIP');
  assert.equal(after.packages.find((p) => p.name === 'AUTH').status, 'TODO', 'other packages untouched');
  assert.equal(after.packages.find((p) => p.name === 'REPORTS').status, 'TODO');
  for (const id of ['E1-1', 'E1-2']) {
    const t = after.tasks.find((x) => x.id === id);
    assert.equal(t.status, 'WIP', id);
    assert.ok(t.ref.includes(`\`${SPEC}\``), id);
  }
  assert.equal(after.tasks.find((x) => x.id === 'E2-1').status, 'TODO');
  assert.equal(after.tasks.find((x) => x.id === 'E3-1').ref, '—');
  const text = fs.readFileSync(path.join(root, BACKLOG), 'utf8');
  assert.ok(text.includes('| E3-1 | Reports | Weekly report | reads exports | E1-1 | M | — | 2 | TODO | — |'), 'untouched rows keep their exact bytes');
  assert.ok(text.includes('| **REPORTS** | E3-1 | NIGHTLY-EXPORT |'), 'the DAG is never restructured');

  const plan = backlogWriteBack({ projectRoot: root, spec: SPEC, refs: ['.agents/plans/active/nightly-export.md'], consent: true });
  assert.equal(plan.status, 'matched');
  const withPlan = parseBacklog(fs.readFileSync(path.join(root, BACKLOG), 'utf8'));
  assert.ok(withPlan.tasks.find((x) => x.id === 'E1-1').ref.includes('nightly-export.md'));
  assert.equal((withPlan.tasks.find((x) => x.id === 'E1-1').ref.match(/2026-09-05-nightly-export/g) ?? []).length, 1, 'spec ref is not duplicated');
  const again = backlogWriteBack({ projectRoot: root, spec: SPEC, refs: ['.agents/plans/active/nightly-export.md'], consent: true });
  assert.deepEqual(again.changed, [], 'idempotent');

  assert.equal(backlogWriteBack({ projectRoot: project(null), spec: SPEC, consent: true }).status, 'no-backlog');
  assert.ok(!fs.existsSync(path.join(project(null), BACKLOG)), 'never creates a backlog');

  const none = backlogWriteBack({ projectRoot: root, spec: '.agents/specs/2026-09-05-payments-refund.md', consent: true });
  assert.equal(none.status, 'none');
  assert.equal(none.written, false);
  const ambiguousText = BACKLOG_TEXT.replace('| **AUTH** | E2-1 | — | `/brainstorm auth` | TODO |', '| **EXPORT-ARCHIVE** | E2-1 | — | `/brainstorm export archive` | TODO |');
  const amb = backlogWriteBack({ projectRoot: project(ambiguousText), spec: '.agents/specs/2026-09-05-export.md', consent: true });
  assert.equal(amb.status, 'ambiguous');
  assert.equal(amb.written, false);
  assert.ok(amb.candidates.length >= 2);
});

test('stale status and competing plans are surfaced, never resolved silently', () => {
  const root = project();
  fs.writeFileSync(path.join(root, '.agents/plans/active/nightly-export.md'), `# Feature\n\n**Source spec:** \`${SPEC}\`\n`);
  const res = backlogWriteBack({ projectRoot: root, spec: SPEC });
  assert.deepEqual(res.competing, ['.agents/plans/active/nightly-export.md']);
  const stale = BACKLOG_TEXT.replace('| E1-1 | Export | Nightly CSV job | worker | — | S | core | 1 | TODO | — |', '| E1-1 | Export | Nightly CSV job | worker | — | S | core | 1 | TODO | `.agents/plans/active/nightly-export.md` |');
  const signals = staleSignals(root, parseBacklog(stale));
  assert.ok(signals.some((s) => /E1-1 is TODO but already has a plan/.test(s)));
  const gone = BACKLOG_TEXT.replace('| E2-1 | Auth | Login | login form | — | M | core | 1 | TODO | — |', '| E2-1 | Auth | Login | login form | — | M | core | 1 | WIP | `.agents/plans/active/auth.md` |');
  assert.ok(staleSignals(root, parseBacklog(gone)).some((s) => /E2-1 is WIP but its plan .* is gone/.test(s)));
  const match = matchWorkPackage(parseBacklog(BACKLOG_TEXT), { spec: SPEC });
  assert.equal(match.status, 'matched');
  assert.throws(() => writeBackText(BACKLOG_TEXT, { pkg: { name: 'GHOST' } }), /not found/);
});

test('plan template keeps the parse anchors, EXPECT and VALIDATE exactly', () => {
  const tpl = fs.readFileSync(path.join(REPO, 'harness-source/templates/plan-feature-plan.template.md'), 'utf8');
  assert.ok(tpl.includes('## STEP-BY-STEP TASKS'));
  assert.ok(tpl.includes('\n- [ ]\n'));
  assert.ok(tpl.includes('- **EXPECT**: present | absent | contains | not-contains — {path}[ :: {literal or symbol}]'));
  assert.ok(tpl.includes('- **VALIDATE**:'));
  assert.ok(tpl.includes('**Execution effort:** medium'));
  assert.ok(tpl.includes('**Spec SHA-256:**'));
  assert.ok(tpl.includes('## VALIDATION COMMANDS'));
  assert.ok(tpl.includes('### Level 1: Automated'));
});

test('plan template carries the architecture/contract block and the conditional UI contract', () => {
  const tpl = fs.readFileSync(path.join(REPO, 'harness-source/templates/plan-feature-plan.template.md'), 'utf8');
  assert.ok(tpl.includes('## Architecture and contracts'));
  for (const f of ['Owned modules', 'Dependency direction', 'Interfaces & invariants', 'Reuse targets', 'Prohibited changes', 'Migration constraints']) assert.ok(tpl.includes(`**${f}:**`), f);
  assert.ok(tpl.includes('## UI structural contract ⟂ conditional'));
  for (const f of ['Section inventory + order', 'Variant / state matrix', 'Copy strings', 'Semantic requirements', 'Runtime validation']) assert.ok(tpl.includes(`**${f}:**`), f);
  assert.ok(tpl.includes('## Independent tracks'));
  assert.match(tpl, /Splitting the plan is the user's decision/);
  const skill = fs.readFileSync(path.join(REPO, 'harness-source/skills/plan-feature/SKILL.md'), 'utf8');
  assert.match(skill, /backlog\.mjs match/);
  assert.match(skill, /become `WIP`/);
  assert.match(skill, /Ambiguous ownership must not write/);
  assert.match(skill, /not executable/);
  assert.match(skill, /Architecture and contracts/);
  assert.match(skill, /DEFER — manual validation only/);
});
