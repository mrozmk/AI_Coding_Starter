import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { EXCLUDE_RE, HARD_EXCLUDE_RE, KEYWORD_EXCLUDE_RE, buildContextPack, outboundManifest } from '../../harness-source/scripts/context-pack.mjs';

const PROJECTS = path.join(import.meta.dirname, 'fixtures/projects');
const SPEC = '.agents/specs/2026-01-01-fixture.md';

function plugin() {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'harness-export-plugin-'));
  fs.mkdirSync(path.join(dir, 'skills/prime'), { recursive: true });
  fs.writeFileSync(path.join(dir, 'skills/prime/SKILL.md'), '---\nname: prime\ndescription: p\n---\nprime\n');
  return dir;
}

function project() {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'harness export project-'));
  fs.cpSync(path.join(PROJECTS, 'with-private-inputs'), dir, { recursive: true });
  fs.writeFileSync(path.join(dir, '.env'), 'SECRET=canary-9f3a\n');
  fs.writeFileSync(path.join(dir, '.agents/memory/user-profile.md'), 'private notes canary-up\n');
  fs.mkdirSync(path.join(dir, 'docs/design'), { recursive: true });
  fs.writeFileSync(path.join(dir, 'docs/design/secret-garden-landing.md'), '# Secret Garden landing page design\n');
  fs.writeFileSync(path.join(dir, 'config/credentials.json'.replace('config/', '')), '{"token":"canary-cred"}\n');
  return dir;
}

test('user-profile, keys, raw inputs and handoffs stay out of every reviewer pack', () => {
  const root = project();
  const res = buildContextPack({ projectRoot: root, pluginRoot: plugin(), artifacts: [SPEC], optionalDeps: ['.env', '.agents/memory/user-profile.md', '.agents/sources/brief.md', 'credentials.json'], allowExceptions: ['.env', '.agents/memory/user-profile.md', '.agents/sources/brief.md'] });
  assert.equal(res.ok, true);
  assert.ok(!res.text.includes('canary-9f3a'));
  assert.ok(!res.text.includes('canary-up'));
  assert.ok(!res.text.includes('canary-cred'));
  for (const p of ['.env', '.agents/memory/user-profile.md', '.agents/sources/brief.md']) {
    const o = res.meta.omissions.find((x) => x.path === p);
    assert.ok(o && /no exception applies/.test(o.reason), `${p}: hard exclusion cannot be lifted`);
  }
  for (const p of ['.env', '.env.local', 'certs/server.pem', 'id_rsa', '.agents/memory/user-profile.md', '.agents/sources/x.pdf', '.agents/handoffs/h.md', '.agents/memory/archive/a.md', '.agents/harness-state/binding.json']) assert.ok(HARD_EXCLUDE_RE.test(p), p);
  for (const p of ['.env.example', 'src/environment.ts', 'CLAUDE.md']) assert.ok(!EXCLUDE_RE.test(p), p);
  assert.ok(KEYWORD_EXCLUDE_RE.test('aws/credentials.json') && KEYWORD_EXCLUDE_RE.test('my-secret.txt'));
});

test('a secret-keyword filename is excluded by default and included only through an explicit per-file exception', () => {
  const root = project();
  const pl = plugin();
  const blocked = buildContextPack({ projectRoot: root, pluginRoot: pl, artifacts: [SPEC], deps: ['docs/design/secret-garden-landing.md'] });
  assert.equal(blocked.ok, false, 'a required secret-looking dependency blocks rather than silently dropping');
  assert.match(blocked.detail, /secret-looking name/);
  const other = buildContextPack({ projectRoot: root, pluginRoot: pl, artifacts: [SPEC], deps: ['docs/design/secret-garden-landing.md'], allowExceptions: ['docs/design/other.md'] });
  assert.equal(other.ok, false, 'an exception for a different file lifts nothing');
  const allowed = buildContextPack({ projectRoot: root, pluginRoot: pl, artifacts: [SPEC], deps: ['docs/design/secret-garden-landing.md'], allowExceptions: ['docs/design/secret-garden-landing.md'] });
  assert.equal(allowed.ok, true);
  const f = allowed.meta.files.find((x) => x.path === 'docs/design/secret-garden-landing.md');
  assert.equal(f.exception, true, 'the exception is visible in the pack metadata');
  const cred = buildContextPack({ projectRoot: root, pluginRoot: pl, artifacts: [SPEC], deps: ['credentials.json'], allowExceptions: ['credentials.json'] });
  assert.equal(cred.ok, true);
  assert.ok(cred.text.includes('canary-cred'), 'an explicitly vetted exception is a deliberate decision, recorded in the outbound manifest');
  assert.ok(outboundManifest(cred.meta, { provider: 'openai' }).files.find((x) => x.path === 'credentials.json').exception);
});

test('outbound manifest names the provider, exact files, bytes and what stayed local; nothing outside the root is listed', () => {
  const root = project();
  const outside = path.join(os.tmpdir(), `outside-${Date.now()}.md`);
  fs.writeFileSync(outside, 'outside');
  const res = buildContextPack({ projectRoot: root, pluginRoot: plugin(), artifacts: [SPEC], optionalDeps: [outside, 'dep.mjs'] });
  assert.equal(res.ok, true);
  const m = outboundManifest(res.meta, { provider: 'openai', host: 'codex' });
  assert.equal(m.provider, 'openai');
  assert.equal(m.reviewer_host, 'codex');
  assert.equal(m.pack_digest, res.meta.pack_digest);
  assert.equal(m.total_bytes, m.files.reduce((n, f) => n + f.bytes, 0));
  assert.ok(m.files.every((f) => f.sha256.length === 64 && f.roles.length >= 1));
  assert.ok(!m.files.some((f) => f.path.includes(os.tmpdir()) || path.isAbsolute(f.path)));
  assert.ok(m.omitted.some((o) => /outside project root/.test(o.reason)));
  assert.match(m.note, /can never be listed/);
});
