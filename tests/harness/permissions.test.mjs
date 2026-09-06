import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { disabledByProfile, loadManifest, mapPermissionsForHost, unionMcp, unionSettings } from '../../harness-source/scripts/sync-filter.mjs';

const REPO = path.resolve(import.meta.dirname, '../..');
const FIX = path.join(import.meta.dirname, 'fixtures/sync');
const manifest = loadManifest(path.join(FIX, 'starter-sync.json'));
const ours = { permissions: { allow: ['Bash(ls:*)', 'Bash(project-only:*)', 'mcp__atlassian__jira_search'], ask: [], deny: [] }, hooks: {}, custom_key: { keep: true } };
const theirs = { permissions: { allow: ['Bash(rg:*)', 'mcp__atlassian__jira_create_issue', 'mcp__atlassian__confluence_get_page', 'mcp__playwright__browser_navigate', 'Bash(bash .claude/skills/pr-comments/references/pr-api.sh:*)'], ask: ['Bash(rm -rf:*)'], deny: ['Bash(sudo:*)'] }, hooks: {} };

test('profile-aware settings union skips entries a disabled group owns, keeps project entries, retains unknown keys', () => {
  const profile = { schema: 2, language: 'en', tracker: 'none', confluence: false, app_surface: 'tui', commands: { pr: false }, groups: { tracker: false, confluence: false, git: false } };
  const { merged, added, skipped } = unionSettings(manifest, ours, theirs, { profile });
  assert.ok(merged.permissions.allow.includes('Bash(rg:*)'));
  assert.ok(merged.permissions.allow.includes('mcp__atlassian__jira_search'), 'an existing project entry is never deleted, even for a disabled group');
  assert.ok(!merged.permissions.allow.includes('mcp__atlassian__jira_create_issue'));
  assert.ok(!merged.permissions.allow.includes('mcp__atlassian__confluence_get_page'));
  assert.ok(!merged.permissions.allow.includes('mcp__playwright__browser_navigate'));
  assert.ok(!merged.permissions.allow.some((e) => e.includes('pr-api.sh')));
  assert.deepEqual(merged.custom_key, { keep: true });
  assert.ok(merged.permissions.deny.includes('Bash(sudo:*)'));
  assert.ok(merged.permissions.ask.includes('Bash(rm -rf:*)'));
  assert.equal(skipped.filter((s) => /disabled|no browser|PR commands/.test(s.reason)).length, 4);
  assert.ok(added.includes('permissions.allow|Bash(rg:*)'));
  const noProfile = unionSettings(manifest, ours, theirs, { profile: null });
  assert.ok(noProfile.merged.permissions.allow.includes('mcp__atlassian__jira_create_issue'), 'no profile → plain union');
  const enabled = unionSettings(manifest, ours, theirs, { profile: { schema: 2, language: 'en', tracker: 'jira', confluence: true, app_surface: 'web', groups: { tracker: true, confluence: true, git: true } } });
  assert.ok(enabled.merged.permissions.allow.includes('mcp__atlassian__confluence_get_page'));
  assert.ok(enabled.merged.permissions.allow.includes('mcp__playwright__browser_navigate'));
});

test('profile-aware MCP union: atlassian dropped only when both tracker and confluence are off; playwright follows app_surface', () => {
  const theirsMcp = { mcpServers: { atlassian: { command: 'x' }, playwright: { command: 'npx' }, context7: { command: 'npx' } } };
  const off = unionMcp(manifest, { mcpServers: {} }, theirsMcp, { profile: { tracker: 'none', confluence: false, app_surface: 'none' } });
  assert.deepEqual(Object.keys(off.merged.mcpServers), ['context7']);
  assert.equal(off.skipped.length, 2);
  const half = unionMcp(manifest, { mcpServers: {} }, theirsMcp, { profile: { tracker: 'none', confluence: true, app_surface: 'web' } });
  assert.deepEqual(Object.keys(half.merged.mcpServers).sort(), ['atlassian', 'context7', 'playwright']);
  const keep = unionMcp(manifest, { mcpServers: { playwright: { command: 'mine' } } }, theirsMcp, { profile: { app_surface: 'tui' } });
  assert.equal(keep.merged.mcpServers.playwright.command, 'mine', 'project entry kept');
  const rules = disabledByProfile({ tracker: 'jira', groups: { tracker: true } });
  assert.equal(rules.permission('mcp__atlassian__jira_search'), null);
});

test('permission policies map explicitly per host and unsupported enforcement is reported, never copied', () => {
  const settings = JSON.parse(fs.readFileSync(path.join(REPO, '.claude/settings.json'), 'utf8'));
  const claude = mapPermissionsForHost(settings, 'claude');
  assert.ok(claude.supported.length > 10);
  assert.equal(claude.unsupported.length, 0);
  assert.ok(claude.supported.some((e) => e.tier === 'deny' && /git push.*force/.test(e.entry)), 'the git deny tier is enforced on Claude');
  const codex = mapPermissionsForHost(settings, 'codex');
  assert.equal(codex.supported.length, 0);
  assert.equal(codex.unsupported.length, claude.supported.length, 'every policy is reported, none silently dropped');
  assert.ok(codex.unsupported.every((e) => /reported, not enforced/.test(e.reason)));
  assert.match(codex.note, /push guard still blocks/);
  const envDeny = codex.unsupported.find((e) => /\.env/.test(e.entry) && e.tier === 'deny');
  assert.ok(envDeny, 'the .env write deny is listed as an unsupported policy on Codex — a recorded gap');
});
