import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { CANONICAL, DEFAULT_GROUPS, LEGACY, effective, readProfile, semanticErrors, syntheticProfile, updateProfile } from '../../harness-source/scripts/profile.mjs';

const CLI = path.resolve(import.meta.dirname, '../../harness-source/scripts/profile.mjs');
const PROJECTS = path.join(import.meta.dirname, 'fixtures/projects');

function copy(name) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), `harness-profile-cli-${name}-`));
  fs.cpSync(path.join(PROJECTS, name), dir, { recursive: true });
  return dir;
}

function cli(root, args) {
  return spawnSync(process.execPath, [CLI, ...args, '--project-root', root], { encoding: 'utf8' });
}

test('the real CLI writes every setup field type: arrays, objects, booleans, strings — through set and apply', () => {
  const root = copy('canonical-profile');
  const preview = cli(root, ['set', '--key', 'workflow.protected', '--value', '["main","develop"]']);
  assert.equal(preview.status, 0, preview.stderr);
  assert.match(preview.stderr, /preview only/);
  assert.deepEqual(JSON.parse(fs.readFileSync(path.join(root, CANONICAL), 'utf8')).workflow, undefined, 'preview writes nothing');

  const apply = cli(root, ['apply', '--consent', 'yes', '--changes', JSON.stringify({
    'workflow.preset': 'gitflow', 'workflow.trunk': 'main', 'workflow.integration': 'develop', 'workflow.protected': ['main', 'develop'],
    'workflow.pr_required': true, 'workflow.orchestrate_publish': 'branch-local', 'workflow.branch_types': ['feat', 'fix', 'release', 'hotfix'],
    'roles.reviewer.claude': { model: 'fable', effort: 'high' }, 'groups.review': true, 'language': 'pl', 'confluence': false,
  })]);
  assert.equal(apply.status, 0, apply.stderr);
  const raw = JSON.parse(fs.readFileSync(path.join(root, CANONICAL), 'utf8'));
  assert.deepEqual(raw.workflow.protected, ['main', 'develop']);
  assert.deepEqual(raw.workflow.branch_types, ['feat', 'fix', 'release', 'hotfix']);
  assert.equal(raw.workflow.pr_required, true);
  assert.deepEqual(raw.roles.reviewer.claude, { model: 'fable', effort: 'high' });
  assert.equal(raw.language, 'pl');
  assert.deepEqual(raw.project_specific, ['kept'], 'unknown keys survive');
  const read = cli(root, ['read']);
  assert.equal(read.status, 0);
  assert.match(read.stdout, /"status": "ok"/);
});

test('an invalid batch leaves no partial profile; contradictory shared behavior is rejected whole', () => {
  const root = copy('canonical-profile');
  const before = fs.readFileSync(path.join(root, CANONICAL), 'utf8');
  const bad = cli(root, ['apply', '--consent', 'yes', '--changes', JSON.stringify({ language: 'pl', 'workflow.protected': 'main', 'planning.after_brainstorm': 'stop' })]);
  assert.equal(bad.status, 1);
  assert.match(bad.stderr, /rejected/);
  assert.equal(fs.readFileSync(path.join(root, CANONICAL), 'utf8'), before, 'nothing of the batch was written');

  const contradictions = [
    [{ 'workflow.pr_required': true, 'workflow.orchestrate_publish': 'push' }, /pr_required.*branch-local/],
    [{ 'groups.tracker': true, tracker: 'none' }, /groups\.tracker/],
    [{ author_host: 'claude', codex: false, 'groups.review': true }, /needs the Codex CLI/],
    [{ 'workflow.trunk': 'main', 'workflow.protected': ['main'], 'workflow.orchestrate_publish': 'push' }, /protected names the trunk/],
  ];
  for (const [changes, re] of contradictions) {
    assert.throws(() => updateProfile(root, changes, { consent: true }), re, JSON.stringify(changes));
  }
  assert.equal(fs.readFileSync(path.join(root, CANONICAL), 'utf8'), before);
});

test('missing, invalid or conflicting profiles never report enabled groups', () => {
  const missing = cli(path.join(PROJECTS, 'no-profile'), ['groups']);
  assert.equal(missing.status, 2);
  assert.match(missing.stdout, /"groups": null/);
  assert.match(missing.stdout, /"blocked": "no project profile/);
  // Derived from DEFAULT_GROUPS, so a group added later is covered without editing this line.
  const none = effective(readProfile(path.join(PROJECTS, 'no-profile'))).groups;
  assert.deepEqual(Object.keys(none).sort(), Object.keys(DEFAULT_GROUPS).sort(), 'every declared group is reported');
  assert.deepEqual(Object.values(none), Object.keys(none).map(() => false));

  const conflict = copy('conflict');
  const c = cli(conflict, ['groups']);
  assert.equal(c.status, 2);
  assert.match(c.stdout, /"groups": null/);
  assert.equal(effective(readProfile(conflict)).groups.review, false);

  const invalid = copy('canonical-profile');
  const raw = JSON.parse(fs.readFileSync(path.join(invalid, CANONICAL), 'utf8'));
  raw.planning.after_brainstorm = 'execute';
  fs.writeFileSync(path.join(invalid, CANONICAL), JSON.stringify(raw));
  const p = readProfile(invalid);
  assert.equal(p.status, 'invalid');
  assert.equal(effective(p).groups.planning, false);
  assert.equal(cli(invalid, ['read']).status, 2);
  const semantic = copy('canonical-profile');
  const sraw = JSON.parse(fs.readFileSync(path.join(semantic, CANONICAL), 'utf8'));
  sraw.workflow = { preset: 'feature-branch', pr_required: true, orchestrate_publish: 'push' };
  fs.writeFileSync(path.join(semantic, CANONICAL), JSON.stringify(sraw));
  assert.equal(readProfile(semantic).status, 'invalid', 'a semantically contradictory file is invalid on read, not silently ok');
  const synthetic = syntheticProfile();
  assert.equal(effective(synthetic).groups.review, true, 'a synthetic probe profile is explicit test input, never read from disk');
  assert.equal(synthetic.kind, 'synthetic');
});

test('two profiles differing only in groups, roles or publish facts are a conflict', () => {
  const root = copy('legacy-profile');
  const legacy = JSON.parse(fs.readFileSync(path.join(root, LEGACY), 'utf8'));
  const canonical = { schema: 2, language: legacy.language, mode: legacy.mode, git_host: legacy.git_host, tracker: legacy.tracker, confluence: legacy.confluence, codex: legacy.codex, app_surface: legacy.app_surface, groups: { review: false } };
  fs.mkdirSync(path.join(root, '.agents'), { recursive: true });
  legacy.harness = { groups: { review: true } };
  fs.writeFileSync(path.join(root, LEGACY), JSON.stringify(legacy));
  fs.writeFileSync(path.join(root, CANONICAL), JSON.stringify(canonical));
  const p = readProfile(root);
  assert.equal(p.status, 'conflict');
  assert.ok(p.differences.includes('groups'));
  delete legacy.harness;
  legacy.workflow.orchestrate_publish = 'branch-local';
  canonical.groups = undefined;
  canonical.workflow = { ...legacy.workflow, orchestrate_publish: 'push' };
  fs.writeFileSync(path.join(root, LEGACY), JSON.stringify(legacy));
  fs.writeFileSync(path.join(root, CANONICAL), JSON.stringify(canonical));
  assert.ok(readProfile(root).differences.includes('workflow.orchestrate_publish'));
  canonical.workflow = { ...legacy.workflow, trunk: 'master' };
  fs.writeFileSync(path.join(root, CANONICAL), JSON.stringify(canonical));
  assert.ok(readProfile(root).differences.includes('workflow.trunk'), 'trunk/integration differences are conflicts too');
  legacy.harness = { groups: { review: false } };
  fs.writeFileSync(path.join(root, LEGACY), JSON.stringify(legacy));
  canonical.workflow = { ...legacy.workflow };
  delete canonical.groups;
  fs.writeFileSync(path.join(root, CANONICAL), JSON.stringify(canonical));
  const lost = readProfile(root);
  assert.equal(lost.status, 'conflict', 'an explicit opt-out in one file and silence in the other is a lost decision, not agreement');
  assert.ok(lost.differences.includes('groups'));
});

test('legacy file: structured values land under harness, mirrors stay consistent, unknown keys survive', () => {
  const root = copy('legacy-profile');
  const res = updateProfile(root, { 'workflow.protected': ['main'], 'workflow.orchestrate_publish': 'branch-local', 'workflow.pr_required': true, confluence: true, 'groups.confluence': true, 'roles.reviewer.codex': { model: 'gpt-6-astra', effort: 'medium' } }, { consent: true });
  assert.equal(res.written, true);
  const after = JSON.parse(fs.readFileSync(path.join(root, LEGACY), 'utf8'));
  assert.equal(after.schema, 1);
  assert.deepEqual(after.workflow.protected, ['main']);
  assert.equal(after.commands.confluence, true, 'legacy commands mirror follows the shared fact');
  assert.deepEqual(after.harness.roles.reviewer.codex, { model: 'gpt-6-astra', effort: 'medium' });
  assert.deepEqual(after.custom_unknown_key, { keep: 'me' });
  assert.equal(readProfile(root).status, 'ok');
  assert.ok(semanticErrors({ schema: 2, language: 'en', codex: true, commands: { codex: false } }).some((e) => /commands\.codex/.test(e)), 'a mirror that disagrees is a conflict');
});
