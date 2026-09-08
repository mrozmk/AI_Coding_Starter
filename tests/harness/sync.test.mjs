import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { filterTasks, hookIdentity, loadManifest, rollbackPlan, threeWayVerdict, unionMcp, unionSettings } from '../../harness-source/scripts/sync-filter.mjs';

const FIX = path.join(import.meta.dirname, 'fixtures/sync');
const REPO = path.resolve(import.meta.dirname, '../..');
const manifest = loadManifest(path.join(FIX, 'starter-sync.json'));
const ours = JSON.parse(fs.readFileSync(path.join(FIX, 'settings-ours.json'), 'utf8'));
const theirs = JSON.parse(fs.readFileSync(path.join(FIX, 'settings-theirs.json'), 'utf8'));

test('migrated and excluded paths get no task; unknown fields in the manifest survive', () => {
  const decisions = filterTasks(manifest, ['.claude/commands/brainstorm.md', '.claude/commands/setup/start.md', '.claude/skills/jira/SKILL.md', '.claude/commands/start-task.md', '.claude/commands/execute.md']);
  const byPath = Object.fromEntries(decisions.map((d) => [d.path, d.decision]));
  assert.equal(byPath['.claude/commands/brainstorm.md'], 'migrated');
  assert.equal(byPath['.claude/commands/setup/start.md'], 'migrated');
  assert.equal(byPath['.claude/skills/jira/SKILL.md'], 'excluded');
  assert.equal(byPath['.claude/commands/start-task.md'], 'excluded');
  assert.equal(byPath['.claude/commands/execute.md'], 'task');
  assert.equal(manifest.project_specific_flag, true);
});

test('3-way: a migrated path absent locally is an intentional deletion, not staleness', () => {
  const v = threeWayVerdict(manifest, '.claude/commands/brainstorm.md', { base: 'old', ours: null, theirs: 'newer upstream' });
  assert.equal(v.verdict, 'intentional-deletion');
  assert.equal(v.action, 'none');
  const stillThere = threeWayVerdict(manifest, '.claude/commands/setup/start.md', { base: 'old', ours: 'old', theirs: 'new' });
  assert.equal(stillThere.verdict, 'migrated-but-present');
  assert.equal(threeWayVerdict(manifest, '.claude/commands/execute.md', { base: 'a', ours: 'a', theirs: 'b' }).verdict, 'clean-upstream-update');
  assert.equal(threeWayVerdict(manifest, '.claude/commands/execute.md', { base: 'a', ours: 'b', theirs: 'a' }).verdict, 'local-customization');
  assert.equal(threeWayVerdict(manifest, '.claude/commands/execute.md', { base: 'a', ours: 'b', theirs: 'c' }).verdict, 'conflict');
  assert.equal(threeWayVerdict(manifest, '.claude/commands/new.md', { base: null, ours: null, theirs: 'x' }).verdict, 'new');
  assert.equal(threeWayVerdict(manifest, '.claude/commands/gone.md', { base: 'a', ours: 'a', theirs: null }).verdict, 'safe-upstream-deletion');
});

test('settings union: upstream top-level keys are copied whole when absent, a project value always wins', () => {
  const { merged, added } = unionSettings(manifest, ours, theirs);
  assert.deepEqual(merged.attribution, { commit: '', pr: '', sessionUrl: false }, 'attribution arrives from upstream');
  assert.ok(added.includes('settings.attribution'));
  const kept = unionSettings(manifest, { ...ours, attribution: { sessionUrl: true } }, theirs).merged;
  assert.deepEqual(kept.attribution, { sessionUrl: true }, 'project object kept whole, never deep-merged');
  assert.equal(unionSettings(manifest, ours, { ...theirs, $schema: 'x' }).merged.$schema, undefined, '$schema is never copied');
});

test('settings union: adds upstream entries, keeps project entries, never resurrects migrated identities', () => {
  const { merged, added, skipped } = unionSettings(manifest, ours, theirs);
  assert.ok(merged.permissions.allow.includes('Bash(project-only:*)'), 'project entry kept');
  assert.ok(merged.permissions.allow.includes('Bash(rg:*)'), 'upstream addition');
  assert.ok(!merged.permissions.allow.includes('Bash(bash .claude/lib/codex-bg.sh:*)'), 'migrated permission not resurrected');
  assert.ok(merged.permissions.deny.includes('Bash(sudo:*)'));
  assert.ok(merged.permissions.ask.includes('Bash(rm -rf:*)'));
  const cmds = merged.hooks.PreToolUse.flatMap((g) => g.hooks.map((h) => h.command));
  assert.ok(cmds.some((c) => c.includes('guard-push.sh')), 'new upstream hook added');
  assert.ok(!cmds.some((c) => c.includes('legacy-review.sh')), 'migrated hook not resurrected');
  assert.equal(cmds.filter((c) => c.includes('guard-commit.sh')).length, 1, 'no duplicate hook');
  assert.ok(merged.hooks.SessionStart?.length === 1);
  assert.deepEqual(skipped.map((s) => s.id).sort(), [
    hookIdentity('PreToolUse', 'Bash', 'bash "$CLAUDE_PROJECT_DIR/.claude/hooks/legacy-review.sh"'),
    'permissions.allow|Bash(bash .claude/lib/codex-bg.sh:*)',
  ].sort());
  assert.ok(added.includes('permissions.allow|Bash(rg:*)'));
  const again = unionSettings(manifest, merged, theirs);
  assert.deepEqual(again.merged, merged, 'idempotent');
  assert.deepEqual(again.added, []);
});

test('mcp union skips migrated servers and keeps project ones', () => {
  const { merged, skipped } = unionMcp(manifest, { mcpServers: { context7: { command: 'npx' } } }, { mcpServers: { context7: { command: 'npx' }, 'legacy-review': { command: 'x' }, playwright: { command: 'npx' } } });
  assert.deepEqual(Object.keys(merged.mcpServers).sort(), ['context7', 'playwright']);
  assert.equal(skipped[0].id, 'legacy-review');
});

test('rollback plan names what a release migrated and what the manifest becomes; it restores nothing itself', () => {
  const plan = rollbackPlan(manifest, '0.1.0');
  assert.deepEqual(plan.restore_paths, ['.claude/commands/brainstorm.md', '.claude/commands/setup/start.md']);
  assert.equal(plan.restore_config.length, 3);
  assert.deepEqual(plan.manifest_after.migrated, []);
  assert.equal(plan.manifest_after.excluded.length, 2, 'excluded untouched');
  assert.equal(plan.manifest_after.project_specific_flag, true);
  assert.match(plan.note, /does not restore/);
});

test('the starter keeps null provenance and empty migrated records; the sync docs know the word migrated', () => {
  const own = loadManifest(path.join(REPO, '.claude/.starter-sync.json'));
  assert.equal(own.last_sync_commit, null);
  assert.deepEqual(own.excluded, []);
  assert.deepEqual(own.migrated, []);
  for (const rel of ['.claude/commands/maintain/sync-from-starter.md', '.claude/starter-sync-playbook.md']) {
    const text = fs.readFileSync(path.join(REPO, rel), 'utf8');
    assert.match(text, /migrated/, rel);
    assert.match(text, /intentional deletion/i, rel);
    assert.match(text, /sync-filter\.mjs/, rel);
  }
  assert.match(fs.readFileSync(path.join(REPO, 'harness-source/references/installation.md'), 'utf8'), /"migrated_config"/);
});
