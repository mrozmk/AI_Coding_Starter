import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { buildContextPack, EXCLUDE_RE, PACK_HEADER } from '../../harness-source/scripts/context-pack.mjs';
import { buildAll } from '../../scripts/build-harness.mjs';

const PROJECTS = path.join(import.meta.dirname, 'fixtures/projects');
const MINI = path.join(import.meta.dirname, 'fixtures/mini-repo');

function pluginRoot() {
  const out = fs.mkdtempSync(path.join(os.tmpdir(), 'harness-ctx-plugin-'));
  buildAll(MINI, out);
  const root = path.join(out, 'packages/claude');
  fs.mkdirSync(path.join(root, 'skills/prime'), { recursive: true });
  fs.writeFileSync(path.join(root, 'skills/prime/SKILL.md'), '---\nname: prime\ndescription: fixture prime\n---\nPrime steps.\n');
  return root;
}

function project() {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'harness ctx project-'));
  fs.cpSync(path.join(PROJECTS, 'with-private-inputs'), dir, { recursive: true });
  fs.writeFileSync(path.join(dir, '.env'), 'SECRET=canary-9f3a\n');
  fs.writeFileSync(path.join(dir, '.agents/memory/user-profile.md'), 'private notes\n');
  return dir;
}

test('pack contains prime, rules, routed memory, artifact and deps with exact hashes; excludes private inputs', () => {
  const root = project();
  const res = buildContextPack({ projectRoot: root, pluginRoot: pluginRoot(), artifacts: ['.agents/specs/2026-01-01-fixture.md'], deps: ['dep.mjs', '.env', '.agents/memory/user-profile.md', '.agents/sources/brief.md'] });
  assert.equal(res.ok, true);
  const roles = Object.fromEntries(res.meta.files.map((f) => [f.path, f.role]));
  assert.equal(roles['plugin:skills/prime/SKILL.md'], 'prime');
  assert.equal(roles['CLAUDE.md'], 'rules');
  assert.equal(roles['.agents/memory/index.md'], 'memory');
  assert.equal(roles['.agents/memory/architecture.md'], 'memory', 'populated memory is routed');
  assert.equal(roles['.agents/memory/patterns.md'], 'memory');
  assert.equal(roles['.agents/memory/project-brief.md'], undefined, 'status: empty placeholder skipped');
  assert.equal(roles['.agents/specs/2026-01-01-fixture.md'], 'artifact');
  assert.equal(roles['dep.mjs'], 'dependency');
  const omitted = Object.fromEntries(res.meta.omissions.map((o) => [o.path, o.reason]));
  assert.match(omitted['.env'], /excluded/);
  assert.match(omitted['.agents/memory/user-profile.md'], /excluded/);
  assert.match(omitted['.agents/sources/brief.md'], /excluded/);
  assert.match(omitted['.agents/memory/project-brief.md'], /status empty/);
  assert.ok(res.text.startsWith(PACK_HEADER));
  assert.ok(!res.text.includes('canary-9f3a'), 'secret bytes never reach the pack');
  assert.ok(!res.text.includes(root), 'no absolute machine path in the pack');
  assert.ok(res.text.includes('== FILE role=artifact path=.agents/specs/2026-01-01-fixture.md sha256='));
});

test('pack is deterministic for unchanged inputs and changes when an artifact changes', () => {
  const root = project();
  const plugin = pluginRoot();
  const a = buildContextPack({ projectRoot: root, pluginRoot: plugin, artifacts: ['.agents/specs/2026-01-01-fixture.md'] });
  const b = buildContextPack({ projectRoot: root, pluginRoot: plugin, artifacts: ['.agents/specs/2026-01-01-fixture.md'] });
  assert.equal(a.meta.pack_digest, b.meta.pack_digest);
  fs.appendFileSync(path.join(root, '.agents/specs/2026-01-01-fixture.md'), '\nchanged\n');
  const c = buildContextPack({ projectRoot: root, pluginRoot: plugin, artifacts: ['.agents/specs/2026-01-01-fixture.md'] });
  assert.notEqual(a.meta.pack_digest, c.meta.pack_digest);
});

test('cross-root paths are omitted, missing artifacts yield needs-context, oversize yields context-too-large', () => {
  const root = project();
  const plugin = pluginRoot();
  const outside = path.join(os.tmpdir(), 'outside-file.md');
  fs.writeFileSync(outside, 'outside');
  const res = buildContextPack({ projectRoot: root, pluginRoot: plugin, artifacts: ['.agents/specs/2026-01-01-fixture.md'], optionalDeps: [outside, '../../etc/hosts'] });
  assert.equal(res.ok, true);
  const required = buildContextPack({ projectRoot: root, pluginRoot: plugin, artifacts: ['.agents/specs/2026-01-01-fixture.md'], deps: [outside] });
  assert.equal(required.ok, false, 'a required dependency outside the root blocks');
  assert.ok(res.meta.omissions.some((o) => o.reason === 'outside project root'));
  assert.ok(!res.text.includes('outside project root\n== FILE'));

  const missing = buildContextPack({ projectRoot: root, pluginRoot: plugin, artifacts: ['.agents/specs/nope.md'] });
  assert.equal(missing.ok, false);
  assert.equal(missing.reason, 'needs-context');

  const big = buildContextPack({ projectRoot: root, pluginRoot: plugin, artifacts: ['.agents/specs/2026-01-01-fixture.md'], maxBytes: 100 });
  assert.equal(big.ok, false);
  assert.equal(big.reason, 'context-too-large');
  assert.match(big.detail, /nothing was truncated/);
});

test('exclusion regex covers the secret spellings and project-private files', () => {
  for (const p of ['.env', '.env.local', 'config/.env.production', 'certs/server.pem', 'id_rsa', 'aws/credentials.json', 'my-secret.txt', '.agents/memory/user-profile.md', '.agents/sources/x.pdf', '.agents/handoffs/h.md']) {
    assert.ok(EXCLUDE_RE.test(p), p);
  }
  for (const p of ['.env.example', 'src/environment.ts', '.agents/specs/a.md', 'CLAUDE.md']) {
    assert.ok(!EXCLUDE_RE.test(p), p);
  }
});
