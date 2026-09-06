import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { runHook } from '../../harness-source/scripts/hook-runner.mjs';
import { acknowledge, contextKey } from '../../harness-source/hooks/core/memory-guard.mjs';

const REPO = path.resolve(import.meta.dirname, '../..');
const ADAPTERS = path.join(REPO, 'harness-source/adapters');

function project() {
  const dir = fs.realpathSync.native(fs.mkdtempSync(path.join(os.tmpdir(), 'harness scope-')));
  execFileSync('git', ['init', '-q'], { cwd: dir });
  fs.mkdirSync(path.join(dir, '.agents/memory'), { recursive: true });
  fs.mkdirSync(path.join(dir, '.claude'));
  fs.writeFileSync(path.join(dir, '.agents/memory/errors.md'), 'e'.repeat(30_000));
  fs.writeFileSync(path.join(dir, '.claude/memory-domains.json'), JSON.stringify({ rules: [{ match: '^src/lib/([^/]+)/', domain: '$1' }], fallback: 'general', size_threshold_bytes: 24000 }));
  return dir;
}
const env = (root, extra = {}) => ({ PATH: process.env.PATH, HOME: os.homedir(), CLAUDE_PROJECT_DIR: root, ...extra });
const claudeEdit = (root, session, agent = null) => ({ hook_event_name: 'PreToolUse', session_id: session, ...(agent ? { agent_id: agent } : {}), tool_name: 'Edit', tool_input: { file_path: path.join(root, 'src/lib/ai/a.ts'), new_string: 'x' } });
const codexPatch = (session) => ({ hook_event_name: 'PreToolUse', session_id: session, tool_name: 'apply_patch', tool_input: { command: '*** Begin Patch\n*** Update File: src/lib/ai/a.ts\n+x\n*** End Patch' } });

test('a parent acknowledgement never satisfies an unprimed Claude subagent (agent_id is the child identity)', async () => {
  const root = project();
  const run = (payload) => runHook({ host: 'claude', hook: 'guard-memory', payload, env: env(root), cwd: root, adaptersRoot: ADAPTERS });
  assert.equal((await run(claudeEdit(root, 'sess'))).exit, 2);
  acknowledge({ projectRoot: root, host: 'claude', domain: 'ai', session: 'sess' });
  assert.equal((await run(claudeEdit(root, 'sess'))).exit, 0, 'parent acknowledged');
  const child = await run(claudeEdit(root, 'sess', 'agent-42'));
  assert.equal(child.exit, 2, 'child shares session_id but is a different author context');
  assert.match(child.stderr, /--agent agent-42/);
  acknowledge({ projectRoot: root, host: 'claude', domain: 'ai', session: 'sess', agent: 'agent-42' });
  assert.equal((await run(claudeEdit(root, 'sess', 'agent-42'))).exit, 0);
  assert.equal((await run(claudeEdit(root, 'sess', 'agent-43'))).exit, 2, 'a sibling child is unprimed');
});

test('Codex cannot tell a child apart: the guard blocks pending an explicit executor id or a recorded session-scope decision', async () => {
  const root = project();
  const run = (payload, extra = {}) => runHook({ host: 'codex', hook: 'guard-memory', payload, env: env(root, extra), cwd: root, adaptersRoot: ADAPTERS });
  const blocked = await run(codexPatch('p1'));
  assert.equal(blocked.exit, 2);
  assert.equal(blocked.state, 'untrusted');
  assert.match(blocked.stderr, /cannot distinguish a subagent from its parent/);
  const noAck = acknowledge({ projectRoot: root, host: 'codex', domain: 'ai', session: 'p1' });
  assert.equal(noAck.ok, false, 'no fabricated context-read proof without an executor identity');
  const withExec = await run(codexPatch('p1'), { HARNESS_EXECUTOR_ID: 'exec-A' });
  assert.equal(withExec.exit, 2, 'executor named but not yet acknowledged');
  assert.match(withExec.stderr, /--executor exec-A/);
  acknowledge({ projectRoot: root, host: 'codex', domain: 'ai', session: 'p1', executor: 'exec-A' });
  assert.equal((await run(codexPatch('p1'), { HARNESS_EXECUTOR_ID: 'exec-A' })).exit, 0);
  assert.equal((await run(codexPatch('p1'), { HARNESS_EXECUTOR_ID: 'exec-B' })).exit, 2, 'another executor is another context');
  fs.mkdirSync(path.join(root, '.agents/hooks'), { recursive: true });
  fs.writeFileSync(path.join(root, '.agents/hooks/config.json'), JSON.stringify({ codex_child_identity: 'session' }));
  const sessionScoped = await run(codexPatch('p1'));
  assert.equal(sessionScoped.exit, 2, 'decision recorded: session scope is accepted, still unacknowledged');
  assert.equal(sessionScoped.state, 'active');
  acknowledge({ projectRoot: root, host: 'codex', domain: 'ai', session: 'p1', childPolicy: 'session' });
  assert.equal((await run(codexPatch('p1'))).exit, 0);
});

test('separate projects, worktrees and hosts never share an acknowledgement', async () => {
  const a = project();
  const b = project();
  const run = (root, host, payload) => runHook({ host, hook: 'guard-memory', payload, env: env(root), cwd: root, adaptersRoot: ADAPTERS });
  acknowledge({ projectRoot: a, host: 'claude', domain: 'ai', session: 'same' });
  assert.equal((await run(a, 'claude', claudeEdit(a, 'same'))).exit, 0);
  assert.equal((await run(b, 'claude', claudeEdit(b, 'same'))).exit, 2, 'same session id, other project');
  execFileSync('git', ['-c', 'user.email=t@x.invalid', '-c', 'user.name=t', 'commit', '-q', '--allow-empty', '-m', 'init'], { cwd: a });
  const wt = path.join(os.tmpdir(), `harness-wt-${Date.now()}`);
  execFileSync('git', ['worktree', 'add', '-q', wt, '-b', 'wt-branch'], { cwd: a });
  fs.mkdirSync(path.join(wt, '.agents/memory'), { recursive: true });
  fs.mkdirSync(path.join(wt, '.claude'), { recursive: true });
  fs.writeFileSync(path.join(wt, '.agents/memory/errors.md'), 'e'.repeat(30_000));
  fs.copyFileSync(path.join(a, '.claude/memory-domains.json'), path.join(wt, '.claude/memory-domains.json'));
  const wtRoot = fs.realpathSync.native(wt);
  assert.equal((await run(wtRoot, 'claude', claudeEdit(wtRoot, 'same'))).exit, 2, 'a worktree is its own author context');
  const keyA = contextKey({ projectRoot: a, host: 'claude', session: 'same', agent: null, executor: null, parentShared: false });
  const keyCodex = contextKey({ projectRoot: a, host: 'codex', session: 'same', agent: null, executor: 'e', parentShared: true, childPolicy: 'required' });
  assert.notEqual(keyA.key, keyCodex.key, 'host is part of the context');
  assert.equal(contextKey({ projectRoot: a, host: 'claude', session: null, parentShared: false }).ok, false, 'no session id → no scope → block, never pass');
});
