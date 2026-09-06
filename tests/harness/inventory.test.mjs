import { test } from 'node:test';
import assert from 'node:assert/strict';
import path from 'node:path';
import { loadInventory, outputsFor, sourceDigestRecords, unclaimedSources, validateInventory } from '../../scripts/lib/inventory.mjs';
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

test('execute/check/git/integration commands are classified deferred, project files never packaged', () => {
  const { inventory } = loadInventory(REPO);
  const byPath = Object.fromEntries(inventory.legacy.map((l) => [l.path, l.class]));
  for (const p of ['.claude/commands/execute.md', '.claude/commands/check-implementation.md', '.claude/commands/commit.md', '.claude/commands/orchestrate.md', '.claude/skills/jira/']) {
    assert.equal(byPath[p], 'deferred', p);
  }
  assert.equal(byPath['.claude/hooks/check-project-deps.sh'], 'project');
  assert.equal(byPath['.claude/lib/git-baseline.sh'], 'retained');
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
