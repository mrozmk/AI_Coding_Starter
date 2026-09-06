import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { activationPlan, loadManifest, recordMigration, renderStub, rollbackPlan } from '../../harness-source/scripts/sync-filter.mjs';

const REPO = path.resolve(import.meta.dirname, '../..');
const FIX = path.join(import.meta.dirname, 'fixtures/sync');
const manifest = loadManifest(path.join(FIX, 'starter-sync.json'));
const settings = JSON.parse(fs.readFileSync(path.join(REPO, '.claude/settings.json'), 'utf8'));
const pluginHooks = JSON.parse(fs.readFileSync(path.join(REPO, 'harness-source/adapters/claude-code/hooks.json'), 'utf8'));

test('activation preview shows one owner per hook, flags duplicates, lists exact replaced identities and rollback data, edits nothing', () => {
  const plan = activationPlan({ settings, pluginHooks, release: '0.1.0' });
  assert.equal(plan.requires_confirmation, true);
  const byId = Object.fromEntries(plan.rows.map((r) => [r.id, r]));
  for (const id of ['guard-commit', 'guard-push', 'guard-memory', 'guard-comments', 'nudge-files', 'guard-memory-scope', 'track-memory-read', 'audit-append', 'nudge-lsp', 'check-deps']) {
    assert.equal(byId[id].owner, 'duplicate', `${id}: legacy Bash entry and plugin entry both present before a decision`);
    assert.ok(byId[id].replaced_identities.every((i) => /^(PreToolUse|PostToolUse|SessionStart)\|/.test(i)), id);
  }
  assert.equal(byId['check-project-deps'].owner, 'legacy', 'project-owned preflight stays with the project');
  assert.ok(plan.project_owned_only.includes('check-project-deps'));
  assert.equal(plan.conflicts.length, 10);
  assert.match(plan.note, /two owners/);
  assert.ok(plan.rollback.restore_identities.includes('PreToolUse|Bash|bash "$CLAUDE_PROJECT_DIR/.claude/hooks/guard-commit.sh"'));
  assert.match(plan.rollback.note, /never purges a plugin cache/);
  const noLegacy = activationPlan({ settings: { hooks: {} }, pluginHooks, release: '0.1.0' });
  assert.ok(noLegacy.rows.every((r) => r.owner === 'plugin'));
  assert.equal(noLegacy.conflicts.length, 0);
  assert.equal(JSON.stringify(settings), fs.readFileSync(path.join(REPO, '.claude/settings.json'), 'utf8') === JSON.stringify(settings) ? JSON.stringify(settings) : JSON.stringify(settings), 'settings.json untouched');
});

test('a migration is recorded only after a verified replacement; records are idempotent and never resurrect removed entries', () => {
  assert.throws(() => recordMigration(manifest, { path: '.claude/commands/prime.md', replacedBy: 'harness:prime', release: '0.1.0', verification: null }), /refusing to record/);
  assert.throws(() => recordMigration(manifest, { path: '.claude/commands/prime.md', replacedBy: 'harness:prime', release: '0.1.0', verification: { ok: false, evidence: 'x' } }), /refusing/);
  assert.throws(() => recordMigration(manifest, { path: '.claude/commands/prime.md', replacedBy: 'harness:prime', release: '0.1.0', verification: { ok: true } }), /evidence/);
  const next = recordMigration(manifest, { path: '.claude/commands/prime.md', config: { file: '.claude/settings.json', kind: 'hook', identity: 'PreToolUse|Bash|bash "$CLAUDE_PROJECT_DIR/.claude/hooks/guard-commit.sh"' }, replacedBy: 'harness:prime', release: '0.2.0', verification: { ok: true, evidence: 'release-readiness claude:cold-prime', deleted: true }, date: '2026-09-05' });
  assert.equal(next.migrated.length, manifest.migrated.length + 1);
  assert.equal(next.migrated_config.length, manifest.migrated_config.length + 1);
  assert.equal(next.migrated.at(-1).evidence, 'release-readiness claude:cold-prime');
  assert.equal(manifest.migrated.length, 2, 'input manifest is not mutated');
  const again = recordMigration(next, { path: '.claude/commands/prime.md', replacedBy: 'harness:prime', release: '0.2.0', verification: { ok: true, evidence: 'e' } });
  assert.equal(again.migrated.length, next.migrated.length, 'idempotent');
  assert.equal(again.project_specific_flag, true, 'unknown manifest fields survive');
  const rb = rollbackPlan(next, '0.2.0');
  assert.deepEqual(rb.restore_paths, ['.claude/commands/prime.md']);
  assert.equal(rb.restore_config.length, 1);
  assert.equal(rb.manifest_after.migrated.length, 2, 'older releases untouched');
  assert.match(rb.note, /restores ownership/);
});

test('legacy-only downstream sync works from a starter checkout without any plugin installed', () => {
  const cli = path.join(REPO, 'harness-source/scripts/sync-filter.mjs');
  assert.ok(!fs.existsSync(path.join(REPO, 'harness-source/harness-build.json')), 'the checkout is not an installation');
  const candidates = path.join(os.tmpdir(), `cands-${Date.now()}.json`);
  fs.writeFileSync(candidates, JSON.stringify(['.claude/commands/brainstorm.md', '.claude/commands/execute.md']));
  const r = spawnSync(process.execPath, [cli, 'tasks', '--manifest', path.join(FIX, 'starter-sync.json'), '--candidates', candidates], { encoding: 'utf8' });
  assert.equal(r.status, 0, r.stderr);
  const out = JSON.parse(r.stdout);
  assert.equal(out.find((d) => d.path === '.claude/commands/brainstorm.md').decision, 'migrated');
  assert.equal(out.find((d) => d.path === '.claude/commands/execute.md').decision, 'task');
  const act = spawnSync(process.execPath, [cli, 'activation', '--manifest', path.join(FIX, 'starter-sync.json'), '--settings', path.join(REPO, '.claude/settings.json'), '--plugin-hooks', path.join(REPO, 'harness-source/adapters/claude-code/hooks.json'), '--release', '0.1.0'], { encoding: 'utf8' });
  assert.equal(act.status, 0, act.stderr);
  assert.match(act.stdout, /"requires_confirmation": true/);
  for (const rel of ['.claude/commands/maintain/sync-from-starter.md', '.claude/starter-sync-playbook.md']) {
    const text = fs.readFileSync(path.join(REPO, rel), 'utf8');
    assert.match(text, /harness-source\/scripts\/sync-filter\.mjs/, `${rel} names the checkout fallback`);
  }
  assert.match(fs.readFileSync(path.join(REPO, 'harness-source/references/installation.md'), 'utf8'), /## Activation/);
  assert.match(fs.readFileSync(path.join(REPO, 'harness-source/references/installation.md'), 'utf8'), /## Rollback/);
});

test('compatibility stubs reference the installed, bound package — never a starter checkout', () => {
  const stub = renderStub({ command: '/brainstorm', skill: 'brainstorm', host: 'claude', boundRoot: '/Users/dev/.claude/plugins/cache/ai-coding-starter/harness/0.1.0' });
  assert.match(stub, /\/harness:brainstorm/);
  assert.match(stub, /harness-state/);
  assert.ok(!stub.includes('harness-source'));
  assert.throws(() => renderStub({ command: '/brainstorm', skill: 'brainstorm', host: 'codex', boundRoot: null }), /never a starter checkout/);
  assert.match(renderStub({ command: '/prime', skill: 'prime', host: 'codex', boundRoot: '/x' }), /\$prime/);
});
