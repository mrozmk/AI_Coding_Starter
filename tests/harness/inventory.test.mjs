import { test } from 'node:test';
import assert from 'node:assert/strict';
import path from 'node:path';
import { RETIRED_LEGACY, loadInventory, outputsFor, sourceDigestRecords, unclaimedSources, validateInventory } from '../../scripts/lib/inventory.mjs';
import { recordsDigest, sha256Hex } from '../../harness-source/scripts/lib/digest.mjs';

const REPO = path.resolve(import.meta.dirname, '../..');
const FIXTURE = path.join(import.meta.dirname, 'fixtures/mini-repo');

test('production inventory validates: schema, ids, dependencies, legacy coverage', () => {
  const { inventory } = loadInventory(REPO);
  assert.deepEqual(validateInventory(inventory, REPO), []);
});

test('every file under harness-source/ is claimed by an entry (allowlist is complete both ways)', () => {
  const { inventory } = loadInventory(REPO);
  assert.deepEqual(unclaimedSources(inventory, REPO), []);
});

test('execution and git commands are classified migrated, tracker skills deferred, project files never packaged', () => {
  const { inventory } = loadInventory(REPO);
  const byPath = Object.fromEntries(inventory.legacy.map((l) => [l.path, l.class]));
  assert.equal(byPath['.claude/skills/jira/'], 'deferred');
  for (const p of ['.claude/commands/execute.md', '.claude/commands/check-implementation.md', '.claude/commands/orchestrate.md',
    '.claude/commands/commit.md', '.claude/commands/push.md', '.claude/commands/start-task.md']) {
    assert.equal(byPath[p], 'migrated', p);
  }
  for (const p of ['.claude/lib/git-baseline.sh', '.claude/lib/codex-bg.sh', '.claude/commands/gates/verify-implementation.md',
    '.claude/agents/orchestrator-executor.md', '.claude/commands/codex-review.md']) {
    assert.equal(byPath[p], 'retired', p);
  }
  assert.equal(byPath['.claude/hooks/check-project-deps.sh'], 'project');
  const packagedSources = inventory.entries.map((e) => e.source ?? '');
  assert.ok(packagedSources.every((s) => s === '' || s.startsWith('harness-source/')), 'only harness-source/ is packaged');
});

test('fixture inventory validates and rejects broken shapes', () => {
  const { inventory } = loadInventory(FIXTURE);
  assert.deepEqual(validateInventory(inventory, FIXTURE), []);

  const dup = structuredClone(inventory);
  dup.entries.push({ ...dup.entries[0] });
  assert.ok(validateInventory(dup, FIXTURE).some((e) => e.includes('duplicate id')));

  const badDep = structuredClone(inventory);
  badDep.entries[0].dependencies.push('nope');
  assert.ok(validateInventory(badDep, FIXTURE).some((e) => e.includes('unknown dependency nope')));

  const abs = structuredClone(inventory);
  abs.entries[1].source = '/etc/passwd';
  assert.ok(validateInventory(abs, FIXTURE).some((e) => /absolute|under harness-source/.test(e)));

  const outside = structuredClone(inventory);
  outside.entries[1].source = '.claude/commands/demo.md';
  assert.ok(validateInventory(outside, FIXTURE).some((e) => e.includes('must be under harness-source/')));

  const missingLegacy = structuredClone(inventory);
  missingLegacy.legacy.push({ path: '.claude/commands/ghost.md', class: 'deferred' });
  assert.ok(validateInventory(missingLegacy, FIXTURE).some((e) => e.includes('does not exist')));

  const badClass = structuredClone(inventory);
  badClass.legacy[0].class = 'whatever';
  assert.ok(validateInventory(badClass, FIXTURE).length > 0);

  const retiredPresent = structuredClone(inventory);
  retiredPresent.legacy.push({ path: '.claude/commands/demo.md', class: 'retired', replaced_by: 'demo' });
  retiredPresent.legacy[0] = { path: '.claude/commands/gone.md', class: 'retired', replaced_by: 'demo' };
  assert.ok(validateInventory(retiredPresent, FIXTURE).some((e) => e.includes('still exists')));

  const retiredNoReplacement = structuredClone(inventory);
  retiredNoReplacement.legacy[0] = { path: '.claude/commands/gone.md', class: 'retired' };
  assert.ok(validateInventory(retiredNoReplacement, FIXTURE).some((e) => e.includes('replaced_by unknown')));

  const retiredOk = structuredClone(inventory);
  retiredOk.legacy.push({ path: '.claude/commands/gone.md', class: 'retired', replaced_by: 'demo' });
  assert.deepEqual(validateInventory(retiredOk, FIXTURE), [], 'a retired row with a known replacement and an absent path is valid');

  const executionPhase = structuredClone(inventory);
  executionPhase.entries[1].phase = 'execution';
  assert.deepEqual(validateInventory(executionPhase, FIXTURE), [], "phase: 'execution' validates");
  const badPhase = structuredClone(inventory);
  badPhase.entries[1].phase = 'quality';
  assert.ok(validateInventory(badPhase, FIXTURE).some((e) => e.includes('phase')));
});

test('RETIRED_LEGACY lists tombstoned paths, sorted', () => {
  const { inventory } = loadInventory(FIXTURE);
  assert.deepEqual(RETIRED_LEGACY(inventory), []);
  const retired = structuredClone(inventory);
  retired.legacy.push({ path: '.claude/lib/z.sh', class: 'retired', replaced_by: 'demo' }, { path: '.claude/lib/a.sh', class: 'retired', replaced_by: 'demo' });
  assert.deepEqual(RETIRED_LEGACY(retired), ['.claude/lib/a.sh', '.claude/lib/z.sh']);
});

test('outputsFor maps kinds to flat package paths; manifests are host-specific', () => {
  const { inventory } = loadInventory(FIXTURE);
  const byId = Object.fromEntries(inventory.entries.map((e) => [e.id, e]));
  assert.deepEqual(outputsFor(byId.demo, 'claude'), ['skills/demo/SKILL.md']);
  assert.deepEqual(outputsFor(byId.demo, 'codex'), ['skills/demo/SKILL.md', 'skills/demo/agents/openai.yaml']);
  assert.deepEqual(outputsFor(byId['ref-demo'], 'claude'), ['references/demo.md']);
  assert.deepEqual(outputsFor(byId['lib-x'], 'codex'), ['scripts/lib/x.mjs']);
  assert.deepEqual(outputsFor(byId['adapter-codex-json'], 'claude'), ['scripts/adapters/codex-cli/adapter.json']);
  assert.deepEqual(outputsFor(byId['manifest-claude'], 'codex'), []);
  assert.deepEqual(outputsFor(byId['manifest-codex'], 'codex'), ['.codex-plugin/plugin.json']);
});

test('source digest covers harness-source/ and the build-script globs, sorted by UTF-8 path bytes', () => {
  const { inventory } = loadInventory(FIXTURE);
  const records = sourceDigestRecords(inventory, FIXTURE);
  const paths = records.map((r) => r.path);
  assert.ok(paths.includes('harness-source/inventory.json'));
  assert.ok(paths.includes('scripts/build.mjs'));
  assert.ok(!paths.some((p) => p.startsWith('.claude/')));
  const a = recordsDigest(records);
  const b = recordsDigest([...records].reverse());
  assert.equal(a, b, 'order-independent');
  assert.match(a, /^[0-9a-f]{64}$/);
});

test('record digest follows the contract-13 byte layout', () => {
  const rec = { path: 'a', bytes: Buffer.from('x') };
  const manual = Buffer.concat([Buffer.from('a'), Buffer.from([0]), Buffer.from([0, 0, 0, 0, 0, 0, 0, 1]), Buffer.from('x')]);
  assert.equal(recordsDigest([rec]), sha256Hex(manual));
  assert.throws(() => recordsDigest([rec, rec]), /duplicate/);
});
