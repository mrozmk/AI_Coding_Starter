import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { buildContextPack, normalizeRequest, verifyPackUnchanged } from '../../harness-source/scripts/context-pack.mjs';

const PROJECTS = path.join(import.meta.dirname, 'fixtures/projects');
const SPEC = '.agents/specs/2026-01-01-fixture.md';

function plugin() {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'harness-ctxid-plugin-'));
  fs.mkdirSync(path.join(dir, 'skills/prime'), { recursive: true });
  fs.writeFileSync(path.join(dir, 'skills/prime/SKILL.md'), '---\nname: prime\ndescription: p\n---\nprime\n');
  return dir;
}

function project() {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'harness ctxid project-'));
  fs.cpSync(path.join(PROJECTS, 'with-private-inputs'), dir, { recursive: true });
  fs.mkdirSync(path.join(dir, '.agents/memory/domain'), { recursive: true });
  fs.mkdirSync(path.join(dir, '.agents/memory/archive'), { recursive: true });
  fs.mkdirSync(path.join(dir, '.agents/reference'), { recursive: true });
  fs.writeFileSync(path.join(dir, '.agents/memory/domain/export.md'), '---\nstatus: populated\n---\n# export\n\n- rule one\n- rule two\n- rule three\n');
  fs.writeFileSync(path.join(dir, '.agents/memory/domain/empty.md'), '---\nstatus: empty\n---\n# empty\n');
  fs.writeFileSync(path.join(dir, '.agents/memory/archive/old.md'), 'archived lesson\n');
  fs.writeFileSync(path.join(dir, '.agents/reference/api.md'), '# api reference\n');
  return dir;
}

test('equivalent relative and absolute artifact paths pack identically; a missing absolute path is needs-context, never an empty pack', () => {
  const root = project();
  const pl = plugin();
  const rel = buildContextPack({ projectRoot: root, pluginRoot: pl, artifacts: [SPEC] });
  const abs = buildContextPack({ projectRoot: root, pluginRoot: pl, artifacts: [path.join(root, SPEC)] });
  assert.equal(rel.ok, true);
  assert.equal(abs.ok, true);
  assert.deepEqual(abs.meta.artifacts, rel.meta.artifacts);
  assert.equal(abs.meta.pack_digest, rel.meta.pack_digest);
  assert.equal(rel.meta.artifacts[0].path, SPEC);
  const missingAbs = buildContextPack({ projectRoot: root, pluginRoot: pl, artifacts: [path.join(root, '.agents/specs/missing-spec.md')] });
  assert.equal(missingAbs.ok, false);
  assert.equal(missingAbs.reason, 'needs-context');
  assert.equal(missingAbs.kind, 'missing-file');
  assert.match(missingAbs.detail, /missing-spec\.md \(missing\)/);
  const missingRel = buildContextPack({ projectRoot: root, pluginRoot: pl, artifacts: ['.agents/specs/missing-spec.md'] });
  assert.equal(missingRel.reason, 'needs-context');
  const n = normalizeRequest(root, '.agents/specs/../specs/2026-01-01-fixture.md');
  assert.equal(n.rel, SPEC);
  assert.equal(normalizeRequest(root, '../../etc/passwd').inside, false);
});

test('an artifact also named as a dependency appears once with both roles; every requested artifact is in the pack', () => {
  const root = project();
  const pl = plugin();
  const res = buildContextPack({ projectRoot: root, pluginRoot: pl, artifacts: [SPEC, 'dep.mjs'], deps: [SPEC] });
  assert.equal(res.ok, true);
  const spec = res.meta.files.find((f) => f.path === SPEC);
  assert.deepEqual(spec.roles, ['artifact', 'dependency']);
  assert.equal(res.meta.files.filter((f) => f.path === SPEC).length, 1);
  assert.deepEqual(res.meta.artifacts.map((a) => a.path), [SPEC, 'dep.mjs']);
  assert.match(res.text, /roles=artifact,dependency path=\.agents\/specs\/2026-01-01-fixture\.md/);
  // A rules file requested as an artifact is still an artifact even though the pack already holds it as rules.
  const rules = buildContextPack({ projectRoot: root, pluginRoot: pl, artifacts: ['CLAUDE.md'] });
  assert.equal(rules.ok, true);
  assert.deepEqual(rules.meta.files.find((f) => f.path === 'CLAUDE.md').roles, ['rules', 'artifact']);
  assert.equal(rules.meta.artifacts[0].path, 'CLAUDE.md');
});

test('required dependencies and read-set entries block when missing; optional ones are recorded omissions', () => {
  const root = project();
  const pl = plugin();
  const reqMissing = buildContextPack({ projectRoot: root, pluginRoot: pl, artifacts: [SPEC], deps: ['nope.mjs'] });
  assert.equal(reqMissing.ok, false);
  assert.equal(reqMissing.reason, 'needs-context');
  assert.match(reqMissing.detail, /nope\.mjs \(missing\)/);
  const optMissing = buildContextPack({ projectRoot: root, pluginRoot: pl, artifacts: [SPEC], optionalDeps: ['nope.mjs'] });
  assert.equal(optMissing.ok, true);
  assert.ok(optMissing.meta.omissions.some((o) => o.path === 'nope.mjs' && o.required === false));
  const readSet = buildContextPack({ projectRoot: root, pluginRoot: pl, artifacts: [SPEC], readSet: { required: ['.agents/memory/domain/export.md', '.agents/reference/api.md'], optional: ['.agents/memory/domain/empty.md', '.agents/reference/missing.md'] } });
  assert.equal(readSet.ok, true, readSet.detail);
  assert.equal(readSet.meta.files.find((f) => f.path === '.agents/memory/domain/export.md').role, 'read-set');
  assert.equal(readSet.meta.files.find((f) => f.path === '.agents/reference/api.md').role, 'read-set');
  assert.ok(readSet.meta.omissions.some((o) => o.path === '.agents/memory/domain/empty.md' && /status empty/.test(o.reason)));
  assert.ok(readSet.meta.omissions.some((o) => o.path === '.agents/reference/missing.md' && o.required === false));
  const reqEmpty = buildContextPack({ projectRoot: root, pluginRoot: pl, artifacts: [SPEC], readSet: { required: ['.agents/reference/missing.md'] } });
  assert.equal(reqEmpty.ok, false);
  assert.match(reqEmpty.detail, /required context not packable/);
  const outsideRoots = buildContextPack({ projectRoot: root, pluginRoot: pl, artifacts: [SPEC], readSet: { required: ['dep.mjs'] } });
  assert.equal(outsideRoots.ok, false, 'a read-set cannot pull arbitrary source files');
  assert.equal(outsideRoots.kind, 'not-allowed');
});

test('status-gated memory is skipped when empty and the omission is recorded', () => {
  const root = project();
  const res = buildContextPack({ projectRoot: root, pluginRoot: plugin(), artifacts: [SPEC] });
  assert.equal(res.ok, true);
  const omitted = Object.fromEntries(res.meta.omissions.map((o) => [o.path, o]));
  assert.match(omitted['.agents/memory/project-brief.md'].reason, /status empty/);
  assert.equal(omitted['.agents/memory/project-brief.md'].kind, 'gated');
  assert.ok(res.meta.files.some((f) => f.path === '.agents/memory/architecture.md'), 'populated memory is packed');
});

test('archive and private inputs are never packed even when requested as a dependency', () => {
  const root = project();
  const res = buildContextPack({ projectRoot: root, pluginRoot: plugin(), artifacts: [SPEC], optionalDeps: ['.agents/memory/archive/old.md', '.agents/sources/brief.md'] });
  assert.equal(res.ok, true);
  assert.ok(!res.text.includes('archived lesson'));
  assert.ok(res.meta.omissions.some((o) => o.path === '.agents/memory/archive/old.md' && o.kind === 'excluded'));
  const req = buildContextPack({ projectRoot: root, pluginRoot: plugin(), artifacts: [SPEC], deps: ['.agents/memory/archive/old.md'] });
  assert.equal(req.ok, true, 'a hard-excluded required dep is omitted, not fetched — and the omission is visible');
  assert.ok(req.meta.omissions.some((o) => o.path === '.agents/memory/archive/old.md'));
});

test('pack identity binds the packed bytes: a later change to any packed file is detected', () => {
  const root = project();
  const pl = plugin();
  const a = buildContextPack({ projectRoot: root, pluginRoot: pl, artifacts: [SPEC], deps: ['dep.mjs'] });
  assert.deepEqual(verifyPackUnchanged(root, a.meta), []);
  fs.appendFileSync(path.join(root, 'dep.mjs'), '\n// changed\n');
  assert.deepEqual(verifyPackUnchanged(root, a.meta), ['dep.mjs']);
  const b = buildContextPack({ projectRoot: root, pluginRoot: pl, artifacts: [SPEC], deps: ['dep.mjs'] });
  assert.notEqual(a.meta.pack_digest, b.meta.pack_digest);
  fs.rmSync(path.join(root, 'dep.mjs'));
  assert.deepEqual(verifyPackUnchanged(root, b.meta), ['dep.mjs (removed)']);
  const big = buildContextPack({ projectRoot: root, pluginRoot: pl, artifacts: [SPEC], maxBytes: 50 });
  assert.equal(big.reason, 'context-too-large');
  assert.match(big.detail, /nothing was truncated/);
});
