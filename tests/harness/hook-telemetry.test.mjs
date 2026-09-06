import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { runHook } from '../../harness-source/scripts/hook-runner.mjs';
import { AUDIT_KEEP_LINES, AUDIT_MAX_LINES, appendAudit, readMemoryUsage, redact, sidecarPaths } from '../../harness-source/scripts/lib/telemetry.mjs';
import { memoryKeys } from '../../harness-source/hooks/core/memory-read.mjs';

const REPO = path.resolve(import.meta.dirname, '../..');
const ADAPTERS = path.join(REPO, 'harness-source/adapters');

function project({ legacy = true } = {}) {
  const dir = fs.realpathSync.native(fs.mkdtempSync(path.join(os.tmpdir(), 'harness telemetry-')));
  execFileSync('git', ['init', '-q'], { cwd: dir });
  fs.mkdirSync(path.join(dir, '.agents/memory/archive'), { recursive: true });
  fs.mkdirSync(path.join(dir, '.agents/memory/domain'), { recursive: true });
  for (const f of ['index.md', 'errors.md', 'patterns.md', 'domain/auth.md', 'archive/old.md']) fs.writeFileSync(path.join(dir, '.agents/memory', f), `# ${f}\n`);
  if (legacy) fs.mkdirSync(path.join(dir, '.claude'));
  return dir;
}
const env = (root) => ({ PATH: process.env.PATH, HOME: os.homedir(), CLAUDE_PROJECT_DIR: root });

test('memory reads: Read and shell reads count, writes and archive do not, globs are never keys, a malformed sidecar heals', async () => {
  const root = project();
  const run = (payload, host = 'claude') => runHook({ host, hook: 'track-memory-read', payload, env: env(root), cwd: root, adaptersRoot: ADAPTERS });
  const sidecar = path.join(root, '.claude/memory-usage.json');
  fs.writeFileSync(sidecar, '{ broken');
  await run({ hook_event_name: 'PostToolUse', session_id: 's', tool_name: 'Read', tool_input: { file_path: path.join(root, '.agents/memory/errors.md') } });
  let db = readMemoryUsage(sidecar);
  assert.equal(db['errors.md'].ref_count, 1, 'malformed sidecar healed to {} then bumped');
  await run({ hook_event_name: 'PostToolUse', session_id: 's', tool_name: 'Bash', tool_input: { command: 'sed -n 1,5p .agents/memory/errors.md; cat .agents/memory/domain/auth.md; cat .agents/memory/archive/old.md; wc -l .agents/memory/*.md; echo x >> .agents/memory/patterns.md' } });
  db = readMemoryUsage(sidecar);
  assert.equal(db['errors.md'].ref_count, 2);
  assert.equal(db['domain/auth.md'].ref_count, 1);
  assert.equal(db['archive/old.md'], undefined, 'archive excluded');
  assert.equal(db['patterns.md'], undefined, 'redirect target is maintenance, not consultation');
  assert.ok(!Object.keys(db).some((k) => k.includes('*')));
  await run({ hook_event_name: 'PostToolUse', session_id: 's', tool_name: 'Edit', tool_input: { file_path: path.join(root, '.agents/memory/errors.md'), new_string: 'x' } });
  assert.equal(readMemoryUsage(sidecar)['errors.md'].ref_count, 2, 'writes never count as reads');
  const codex = await run({ hook_event_name: 'PostToolUse', session_id: 'p', tool_name: 'Bash', tool_input: { command: 'cat .agents/memory/index.md' } }, 'codex');
  assert.equal(codex.state, 'active');
  assert.equal(readMemoryUsage(sidecar)['index.md'].ref_count, 1);
  const codexPatch = await run({ hook_event_name: 'PostToolUse', session_id: 'p', tool_name: 'apply_patch', tool_input: { command: '*** Begin Patch\n*** Update File: .agents/memory/index.md\n+x\n*** End Patch' } }, 'codex');
  assert.equal(readMemoryUsage(sidecar)['index.md'].ref_count, 1);
  assert.equal(codexPatch.state, 'active');
  assert.deepEqual(memoryKeys(root, ['.agents/memory/nope.md', '.agents/memory/errors.md']), ['errors.md'], 'missing files are not keys');
});

test('sidecars: legacy .claude/ location while it exists (old cleanup reader), state directory otherwise; concurrent bumps lose nothing', () => {
  const legacy = project();
  const s1 = sidecarPaths(legacy);
  assert.equal(s1.memoryUsage, path.join(legacy, '.claude/memory-usage.json'));
  assert.equal(s1.audit, path.join(legacy, '.claude/audit.log'));
  const modern = project({ legacy: false });
  const s2 = sidecarPaths(modern);
  assert.equal(s2.memoryUsage, path.join(modern, '.agents/harness-state/memory-usage.json'));
  assert.equal(sidecarPaths(legacy, { legacySidecars: false }).audit, path.join(legacy, '.agents/harness-state/audit.log'));
  const file = path.join(modern, '.agents/harness-state/memory-usage.json');
  const script = `import('${path.join(REPO, 'harness-source/scripts/lib/telemetry.mjs')}').then((m) => { for (let i = 0; i < 20; i++) m.bumpMemoryReads(${JSON.stringify(file)}, ['errors.md']); })`;
  const procs = Array.from({ length: 5 }, () => import('node:child_process').then(({ spawn }) => new Promise((res) => spawn(process.execPath, ['-e', script]).on('exit', res))));
  return Promise.all(procs).then(() => {
    assert.equal(readMemoryUsage(file)['errors.md'].ref_count, 100, 'lock serializes concurrent writers');
    assert.ok(!fs.existsSync(`${file}.lock`));
  });
});

test('audit: attempted and completed are distinct lines, values are redacted, retention is bounded, never a gate', async () => {
  const root = project();
  const run = (payload, host = 'claude') => runHook({ host, hook: 'audit-append', payload, env: env(root), cwd: root, adaptersRoot: ADAPTERS });
  const log = path.join(root, '.claude/audit.log');
  const attempt = await run({ hook_event_name: 'PreToolUse', session_id: 's', tool_name: 'Bash', tool_input: { command: 'curl -H "Authorization: Bearer ghp_' + 'a'.repeat(36) + '" https://x' } });
  assert.equal(attempt.exit, 0);
  const done = await run({ hook_event_name: 'PostToolUse', session_id: 's', tool_name: 'Bash', tool_input: { command: 'ls' } });
  assert.equal(done.exit, 0);
  await run({ hook_event_name: 'PreToolUse', session_id: 's', tool_name: 'Write', tool_input: { file_path: 'src/a.ts', content: 'password = "hunter2hunter2"' } }); // guard-push:allow — synthetic payload proving the audit log redacts it
  await run({ hook_event_name: 'PreToolUse', session_id: 'p', tool_name: 'apply_patch', tool_input: { command: '*** Begin Patch\n*** Update File: src/b.ts\n+secret\n*** End Patch' } }, 'codex');
  const text = fs.readFileSync(log, 'utf8');
  assert.match(text, /ATTEMPT BASH   curl -H "Authorization: Bearer <redacted>" https:\/\/x/);
  assert.match(text, /DONE    BASH   ls/);
  assert.match(text, /ATTEMPT WRITE  add:src\/a\.ts/);
  assert.ok(!text.includes('hunter2'), 'file contents are never logged');
  assert.match(text, /ATTEMPT PATCH  update:src\/b\.ts/);
  assert.ok(!text.includes('ghp_aaaa'));
  assert.equal(redact('token: "abcdefgh12"'), 'token: <redacted>');
  for (let i = 0; i < AUDIT_MAX_LINES + 10; i++) appendAudit(log, { phase: 'DONE', label: 'BASH', value: `cmd ${i}` });
  const lines = fs.readFileSync(log, 'utf8').split('\n').filter(Boolean);
  assert.ok(lines.length <= AUDIT_MAX_LINES && lines.length < AUDIT_KEEP_LINES + 100, `bounded: ${lines.length}`);
  assert.match(lines.at(-1), /cmd \d+/);
});
