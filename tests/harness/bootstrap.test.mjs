import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { MEMORY_SEED, REFERENCE_SEED, SCAFFOLD_DIRS, readiness, seedMemory, syncWrappers } from '../../harness-source/scripts/bootstrap.mjs';
import { applyRules } from '../../harness-source/scripts/rules.mjs';
import { updateProfile } from '../../harness-source/scripts/profile.mjs';
import { verifyPackageRoot, writeReceipt } from '../../harness-source/scripts/lib/locator.mjs';
import { buildAll } from '../../scripts/build-harness.mjs';
import { parseFrontmatter } from '../../harness-source/scripts/lib/frontmatter.mjs';

const MINI = path.join(import.meta.dirname, 'fixtures/mini-repo');

// A genuinely bare repository: git init and nothing else. Nothing is pre-seeded by the test.
function bare() {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'harness bare-'));
  execFileSync('git', ['init', '-q'], { cwd: dir });
  return dir;
}

test('a bare repository receives the routing, reflection and empty placeholder files; existing memory is never overwritten', () => {
  const root = bare();
  assert.equal(fs.readdirSync(root).filter((f) => f !== '.git').length, 0, 'fixture is truly empty');
  const preview = seedMemory({ projectRoot: root, consent: false, today: '2026-09-05' });
  assert.equal(preview.created, 0);
  assert.ok(!fs.existsSync(path.join(root, '.agents')), 'no consent → nothing written');
  const res = seedMemory({ projectRoot: root, consent: true, today: '2026-09-05' });
  assert.equal(res.created, MEMORY_SEED.length + SCAFFOLD_DIRS.length + REFERENCE_SEED.length, 'seed files, scaffold dirs and the project reference overlays');
  for (const rel of MEMORY_SEED) assert.ok(fs.existsSync(path.join(root, '.agents/memory', rel)), rel);
  const errors = fs.readFileSync(path.join(root, '.agents/memory/errors.md'), 'utf8');
  assert.match(errors, /created: 2026-09-05/);
  assert.ok(!/## 20\d\d-\d\d-\d\d — /.test(errors), 'no starter incident is seeded into a project');
  for (const rel of ['project-brief.md', 'architecture.md', 'domain/business-model.md']) {
    assert.equal(parseFrontmatter(fs.readFileSync(path.join(root, '.agents/memory', rel), 'utf8')).data.status, 'empty', rel);
  }
  assert.ok(fs.existsSync(path.join(root, '.agents/memory/user-profile.md.example')));
  assert.ok(!fs.existsSync(path.join(root, '.agents/memory/user-profile.md')), 'the per-developer profile is never created for someone');

  // The QA overlay is project-owned: seeded once with a usable roster, never rewritten afterwards.
  assert.deepEqual(REFERENCE_SEED.map((r) => r.to), ['.agents/reference/qa-evidence-families.md'], 'the overlay destination is part of the contract');
  const overlay = path.join(root, REFERENCE_SEED[0].to);
  const seeded = fs.readFileSync(overlay, 'utf8');
  assert.match(seeded, /## 2\. Verifier roster/);
  assert.match(seeded, /`qa-contract`/, 'the seed ships a roster row for every verifier the harness itself provides');
  assert.match(seeded, /`qa-runtime-ui`/);
  assert.match(seeded, /## 5\. Not observable in this repo/, 'the exclusion list is project-owned and ships with the seed');

  fs.writeFileSync(path.join(root, '.agents/memory/decisions.md'), 'my decisions\n');
  fs.writeFileSync(path.join(root, '.agents/memory/project-brief.md'), '---\nstatus: populated\n---\nreal brief\n');
  fs.writeFileSync(overlay, 'my roster\n');
  const againPreview = seedMemory({ projectRoot: root, consent: false });
  assert.equal(againPreview.created, 0, 'a preview writes nothing');
  const again = seedMemory({ projectRoot: root, consent: true });
  assert.equal(again.created, 0);
  assert.equal(fs.readFileSync(overlay, 'utf8'), 'my roster\n', 'an existing overlay is preserved byte for byte');
  assert.equal(again.actions.find((a) => a.path === REFERENCE_SEED[0].to).action, 'kept');
  assert.equal(fs.readFileSync(path.join(root, '.agents/memory/decisions.md'), 'utf8'), 'my decisions\n');
  assert.equal(fs.readFileSync(path.join(root, '.agents/memory/project-brief.md'), 'utf8'), '---\nstatus: populated\n---\nreal brief\n');
});

test('seeded index carries the loader, output-discipline and status conventions', () => {
  const root = bare();
  seedMemory({ projectRoot: root, consent: true });
  const index = fs.readFileSync(path.join(root, '.agents/memory/index.md'), 'utf8');
  for (const h of ['## Quick Reference', '## When to Read', '## Loader Convention', '## Output-Discipline Convention', '## File Status Convention', 'Archive folder — never auto-loaded']) assert.ok(index.includes(h), h);
  assert.ok(!index.includes('../../.claude/'), 'template pointers resolve without a starter checkout');
  const reflection = fs.readFileSync(path.join(root, '.agents/memory/reflection-protocol.md'), 'utf8');
  assert.match(reflection, /## Domain File Template/);
  assert.match(reflection, /default outcome is to save nothing/);
  assert.ok(!reflection.includes('../../.claude/'));
  assert.ok(!/\bPoezja\b|\bDent\b|\bpacjent\b/i.test(index + reflection), 'no project data in the seed');
});

test('readiness: operational rules, profile and binding block; absent optional knowledge is a visible warning', () => {
  const root = bare();
  let r = readiness({ projectRoot: root, host: 'claude' });
  assert.equal(r.ready, false);
  assert.ok(r.blockers.some((b) => /no project rules/.test(b)));
  assert.ok(r.blockers.some((b) => /profile missing/.test(b)));
  assert.ok(r.blockers.some((b) => /harness not bound/.test(b)));
  assert.ok(r.blockers.some((b) => /index\.md/.test(b)));

  seedMemory({ projectRoot: root, consent: true });
  applyRules({ projectRoot: root, facts: { language: 'en', workflow: { preset: 'trunk' } }, consent: true });
  r = readiness({ projectRoot: root, host: 'claude' });
  assert.ok(r.blockers.some((b) => /rules incomplete.*validation-command/.test(b)), 'created is not ready');

  fs.writeFileSync(path.join(root, '.agents/project-rules.md'), fs.readFileSync(path.join(root, '.agents/project-rules.md'), 'utf8').replace('{validation-command}', 'npm test'));
  r = readiness({ projectRoot: root, host: 'claude' });
  assert.ok(r.blockers.some((b) => /out of sync.*validation-command/.test(b)), 'editing the shared rules without re-rendering leaves the compat CLAUDE.md stale — a blocker, not a silent pass');
  applyRules({ projectRoot: root, facts: { language: 'en', workflow: { preset: 'trunk' } }, consent: true });
  updateProfile(root, { language: 'en', author_host: 'claude', 'workflow.preset': 'trunk', 'groups.review': true }, { consent: true, create: true });
  const out = fs.mkdtempSync(path.join(os.tmpdir(), 'harness-bootstrap-plugin-'));
  buildAll(MINI, out);
  const plugin = path.join(out, 'packages/claude');
  writeReceipt(root, 'claude', verifyPackageRoot(plugin, { host: 'claude' }));
  r = readiness({ projectRoot: root, host: 'claude', pluginRoot: plugin });
  assert.deepEqual(r.blockers.filter((b) => !/dependency missing/.test(b)), [], JSON.stringify(r.blockers));
  assert.ok(r.warnings.some((w) => /project-brief\.md is empty/.test(w)), 'absent brief is a warning, not a blocker');
  assert.ok(r.warnings.some((w) => /architecture\.md is empty/.test(w)));
  assert.equal(r.profile.groups.review, true);
  assert.equal(r.dependencies.project.ran, false, 'no project preflight script → nothing project-specific checked');
  assert.match(r.dependencies.project.error, /not present/);
});

test('wrapper adoption previews created/updated/kept, flags project edits, writes only with consent', () => {
  const REPO = path.resolve(import.meta.dirname, '../..');
  const out = fs.mkdtempSync(path.join(os.tmpdir(), 'harness-wrap-'));
  buildAll(REPO, out);
  const plugin = path.join(out, 'packages/claude');
  const project = bare();
  fs.mkdirSync(path.join(project, '.claude/commands'), { recursive: true });
  fs.writeFileSync(path.join(project, '.claude/commands/commit.md'), '---\ndescription: project-specific commit\n---\nlocal edits\n');
  const preview = syncWrappers({ projectRoot: project, pluginRoot: plugin });
  assert.equal(preview.written, false);
  const byPath = Object.fromEntries(preview.files.map((f) => [f.path, f]));
  assert.equal(byPath['.claude/commands/prime.md'].status, 'created');
  assert.equal(byPath['.claude/commands/commit.md'].status, 'updated');
  assert.equal(byPath['.claude/commands/commit.md'].replaces_local_edit, true);
  assert.ok(!fs.existsSync(path.join(project, '.claude/commands/prime.md')), 'preview writes nothing');
  const applied = syncWrappers({ projectRoot: project, pluginRoot: plugin, consent: true });
  assert.ok(applied.files.every((f) => f.status === 'created' || f.status === 'updated'));
  assert.equal(syncWrappers({ projectRoot: project, pluginRoot: plugin }).files.every((f) => f.status === 'kept'), true);
  assert.equal(syncWrappers({ projectRoot: project, pluginRoot: path.join(out, 'packages/codex') }).ok, false, 'codex package carries no wrappers');
});
