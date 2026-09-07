import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { CANONICAL, LEGACY, checkVersion, effective, groupEnabled, readProfile, resolvePluginRoot, updateProfile } from '../../harness-source/scripts/profile.mjs';
import { writeReceipt, verifyPackageRoot } from '../../harness-source/scripts/lib/locator.mjs';
import { buildAll } from '../../scripts/build-harness.mjs';

const PROJECTS = path.join(import.meta.dirname, 'fixtures/projects');
const MINI = path.join(import.meta.dirname, 'fixtures/mini-repo');

function copy(name) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), `harness-profile-${name}-`));
  fs.cpSync(path.join(PROJECTS, name), dir, { recursive: true });
  return dir;
}

test('missing profile means interview, with legacy defaults in effect and nothing inferred', () => {
  const p = readProfile(path.join(PROJECTS, 'no-profile'));
  assert.equal(p.status, 'missing');
  const eff = effective(p);
  assert.equal(eff.after_brainstorm, 'stop');
  assert.deepEqual(eff.roles.executor, { model: 'opus', effort: 'medium' });
  assert.deepEqual(eff.roles.reviewer.claude, { model: 'fable', effort: 'high' });
  assert.equal(eff.groups.execution, false);
  assert.throws(() => updateProfile(path.join(PROJECTS, 'no-profile'), { language: 'pl' }, { consent: true }), /no profile exists/);
});

test('legacy schema-1 profile is read through the schema-2 view and written in place', () => {
  const dir = copy('legacy-profile');
  const p = readProfile(dir);
  assert.equal(p.status, 'ok');
  assert.equal(p.kind, 'legacy');
  assert.equal(p.view.schema, 2);
  assert.equal(p.view.language, 'pl');
  assert.deepEqual(p.errors, []);
  assert.equal(effective(p).after_brainstorm, 'stop');

  const preview = updateProfile(dir, { 'planning.after_brainstorm': 'plan-feature', author_host: 'claude' });
  assert.equal(preview.written, false, 'no consent -> preview only');
  assert.ok(!fs.existsSync(path.join(dir, CANONICAL)), 'no second authoritative file');
  const before = JSON.parse(fs.readFileSync(path.join(dir, LEGACY), 'utf8'));
  assert.equal(before.harness, undefined);

  const res = updateProfile(dir, { 'planning.after_brainstorm': 'plan-feature', author_host: 'claude' }, { consent: true });
  assert.equal(res.written, true);
  assert.ok(!fs.existsSync(path.join(dir, CANONICAL)));
  const after = JSON.parse(fs.readFileSync(path.join(dir, LEGACY), 'utf8'));
  assert.equal(after.schema, 1, 'legacy schema preserved');
  assert.deepEqual(after.custom_unknown_key, { keep: 'me' }, 'unknown keys preserved');
  assert.deepEqual(after.commands, before.commands, 'legacy answers preserved');
  assert.equal(after.harness.planning.after_brainstorm, 'plan-feature');
  assert.equal(after.harness.author_host, 'claude');
  assert.equal(effective(readProfile(dir)).after_brainstorm, 'plan-feature');
});

test('canonical schema-2 profile: overrides win, disabled groups and unknown keys survive', () => {
  const dir = copy('canonical-profile');
  const p = readProfile(dir);
  assert.equal(p.kind, 'canonical');
  assert.deepEqual(p.errors, []);
  const eff = effective(p);
  assert.equal(eff.after_brainstorm, 'plan-feature');
  assert.deepEqual(eff.roles.reviewer.codex, { model: 'gpt-6-astra', effort: 'medium' }, 'explicit project override wins');
  assert.deepEqual(eff.roles.reviewer.claude, { model: 'fable', effort: 'high' }, 'absent role falls back to the starter default');
  assert.equal(groupEnabled(p, 'execution'), false);
  assert.equal(groupEnabled(p, 'planning'), true);
  updateProfile(dir, { 'groups.review': false }, { consent: true });
  const raw = JSON.parse(fs.readFileSync(path.join(dir, CANONICAL), 'utf8'));
  assert.deepEqual(raw.project_specific, ['kept']);
  assert.equal(raw.groups.review, false);
  assert.equal(raw.harness, undefined, 'schema 2 keeps fields at top level');
});

test('invalid values are rejected before any write', () => {
  const dir = copy('canonical-profile');
  assert.throws(() => updateProfile(dir, { 'planning.after_brainstorm': 'execute' }, { consent: true }), /rejected/);
  assert.throws(() => updateProfile(dir, { 'roles.executor': { model: 'opus', effort: 'ultra' } }, { consent: true }), /rejected/);
  assert.equal(readProfile(dir).view.planning.after_brainstorm, 'plan-feature');
});

test('two profiles with different authorities block mutation; a symlinked pair is one authority', () => {
  const dir = copy('conflict');
  const p = readProfile(dir);
  assert.equal(p.status, 'conflict');
  assert.ok(p.differences.includes('language'));
  assert.throws(() => updateProfile(dir, { language: 'pl' }, { consent: true }), /disagree/);

  const linked = copy('legacy-profile');
  fs.mkdirSync(path.join(linked, '.agents'), { recursive: true });
  fs.symlinkSync(path.join(linked, LEGACY), path.join(linked, CANONICAL));
  const q = readProfile(linked);
  assert.equal(q.status, 'ok');
  assert.equal(q.kind, 'canonical');
});

test('plugin root resolves from the installed entry location and version binding is checked', () => {
  const out = fs.mkdtempSync(path.join(os.tmpdir(), 'harness-install-'));
  buildAll(MINI, out);
  const root = path.join(out, 'packages/claude');
  assert.equal(resolvePluginRoot(root).ok, true);
  assert.equal(resolvePluginRoot(MINI).ok, false, 'a checkout is not an installation');

  const project = copy('canonical-profile');
  let res = checkVersion({ projectRoot: project, host: 'claude', pluginRoot: root });
  assert.equal(res.ok, false, 'unbound project');
  const binding = verifyPackageRoot(root, { host: 'claude' });
  writeReceipt(project, 'claude', binding);
  res = checkVersion({ projectRoot: project, host: 'claude', pluginRoot: root });
  assert.equal(res.ok, true);
  assert.equal(res.version, '0.0.1');

  const other = path.join(fs.mkdtempSync(path.join(os.tmpdir(), 'harness-install2-')), 'packages/claude');
  fs.cpSync(root, other, { recursive: true });
  res = checkVersion({ projectRoot: project, host: 'claude', pluginRoot: other });
  assert.equal(res.ok, true, 'the same release payload loaded from another directory is still the bound release');
  assert.equal(fs.realpathSync(res.alternate_root), fs.realpathSync(other));
  assert.match(res.note, /identical payload/);
  fs.appendFileSync(path.join(root, 'references/demo.md'), 'upgrade');
  res = checkVersion({ projectRoot: project, host: 'claude' });
  assert.equal(res.ok, false, 'a changed payload invalidates the binding');
});

test('a newer version of the same plugin is reported as an adoptable upgrade; same version with other bytes is not', () => {
  const out = fs.mkdtempSync(path.join(os.tmpdir(), 'harness-install-'));
  buildAll(MINI, out);
  const root = path.join(out, 'packages/claude');
  const project = copy('canonical-profile');
  writeReceipt(project, 'claude', verifyPackageRoot(root, { host: 'claude' }));

  const src = fs.mkdtempSync(path.join(os.tmpdir(), 'harness-src-'));
  fs.cpSync(MINI, src, { recursive: true });
  const hj = path.join(src, 'harness-source/harness.json');
  fs.writeFileSync(hj, JSON.stringify({ ...JSON.parse(fs.readFileSync(hj, 'utf8')), version: '0.0.2' }, null, 2));
  const out2 = fs.mkdtempSync(path.join(os.tmpdir(), 'harness-install-'));
  buildAll(src, out2);
  const newer = path.join(out2, 'packages/claude');
  let res = checkVersion({ projectRoot: project, host: 'claude', pluginRoot: newer });
  assert.equal(res.ok, false, 'the pin does not move by itself');
  assert.deepEqual({ from: res.upgrade.from, to: res.upgrade.to }, { from: '0.0.1', to: '0.0.2' });
  assert.match(res.upgrade.adopt, /profile\.mjs bind --project-root .* --host claude --plugin-root /);

  const tampered = path.join(fs.mkdtempSync(path.join(os.tmpdir(), 'harness-install-')), 'packages/claude');
  fs.cpSync(root, tampered, { recursive: true });
  fs.appendFileSync(path.join(tampered, 'references/demo.md'), 'other bytes, same version');
  res = checkVersion({ projectRoot: project, host: 'claude', pluginRoot: tampered });
  assert.equal(res.ok, false);
  assert.equal(res.upgrade, undefined, 'same version, different payload: not an upgrade hint');
});

