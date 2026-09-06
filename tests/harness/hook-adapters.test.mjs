import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { execFileSync, spawnSync } from 'node:child_process';
import { CORES, STATES, buildContext, loadCore, loadHostAdapter, runHook } from '../../harness-source/scripts/hook-runner.mjs';
import { MAX_PATCH_FILES, normalizeShell, parseApplyPatch, resolveProjectRoot } from '../../harness-source/scripts/lib/hook-events.mjs';
import { resolveHookConfig } from '../../harness-source/scripts/lib/hook-config.mjs';

const REPO = path.resolve(import.meta.dirname, '../..');
const RUNNER = path.join(REPO, 'harness-source/scripts/hook-runner.mjs');
const ADAPTERS = path.join(REPO, 'harness-source/adapters');

function project() {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'harness hooks project-'));
  execFileSync('git', ['init', '-q'], { cwd: dir });
  fs.mkdirSync(path.join(dir, 'src'), { recursive: true });
  return fs.realpathSync.native(dir);
}
const env = (root, extra = {}) => ({ PATH: process.env.PATH, HOME: os.homedir(), CLAUDE_PROJECT_DIR: root, ...extra });

test('Claude payloads normalize: Edit/Write/MultiEdit changes, Bash shell, Read, Grep, WebFetch, subagent identity', async () => {
  const root = project();
  const claude = await loadHostAdapter('claude', ADAPTERS);
  const write = claude.normalize({ hook_event_name: 'PreToolUse', session_id: 's1', tool_name: 'Write', tool_input: { file_path: path.join(root, 'src/a.ts'), content: 'x' }, cwd: root }, { env: env(root) });
  assert.equal(write.tool, 'file-edit');
  assert.deepEqual(write.changes, [{ op: 'add', path: 'src/a.ts', content: 'x' }]);
  assert.equal(write.project_root, root);
  const edit = claude.normalize({ hook_event_name: 'PostToolUse', session_id: 's1', agent_id: 'child-7', tool_name: 'Edit', tool_input: { file_path: 'src/b.ts', old_string: 'a', new_string: 'b // why\n' } }, { env: env(root), cwd: root });
  assert.equal(edit.changes[0].op, 'update');
  assert.equal(edit.changes[0].content, 'b // why\n');
  assert.equal(edit.session.agent_id, 'child-7');
  assert.equal(edit.session.parent_shared, false);
  const multi = claude.normalize({ hook_event_name: 'PostToolUse', session_id: 's1', tool_name: 'MultiEdit', tool_input: { file_path: 'src/c.ts', edits: [{ new_string: 'one' }, { new_string: 'two' }] } }, { env: env(root), cwd: root });
  assert.equal(multi.changes[0].content, 'one\ntwo');
  const bash = claude.normalize({ hook_event_name: 'PreToolUse', session_id: 's1', tool_name: 'Bash', tool_input: { command: 'cat .agents/memory/errors.md && git -C /tmp/x commit -m x' }, cwd: root }, { env: env(root) });
  assert.equal(bash.tool, 'shell');
  assert.equal(bash.shell.git.subcommand, 'commit');
  assert.equal(bash.shell.target_dir, '/tmp/x');
  assert.deepEqual(bash.reads, ['.agents/memory/errors.md']);
  const read = claude.normalize({ hook_event_name: 'PostToolUse', session_id: 's1', tool_name: 'Read', tool_input: { file_path: path.join(root, '.agents/memory/index.md') } }, { env: env(root), cwd: root });
  assert.deepEqual(read.reads, ['.agents/memory/index.md']);
  const grep = claude.normalize({ hook_event_name: 'PostToolUse', session_id: 's1', tool_name: 'Grep', tool_input: { pattern: 'buildSpawn', glob: '*.ts' } }, { env: env(root), cwd: root });
  assert.deepEqual(grep.search, { pattern: 'buildSpawn', glob: '*.ts', path: '' });
  const fetch = claude.normalize({ hook_event_name: 'PreToolUse', session_id: 's1', tool_name: 'WebFetch', tool_input: { url: 'https://example.com' } }, { env: env(root), cwd: root });
  assert.equal(fetch.url, 'https://example.com');
});

test('Codex payloads normalize: apply_patch becomes bounded per-file events (add/update/delete/move) without execution; shared session id is marked', async () => {
  const root = project();
  const codex = await loadHostAdapter('codex', ADAPTERS);
  const patch = ['*** Begin Patch', '*** Add File: src/new.ts', '+export const a = 1; // adds', '+rm -rf / # never executed', '*** Update File: src/old.ts', '@@', '-const x = 1;', '+const x = 2;', '*** Delete File: src/gone.ts', '*** Update File: src/from.ts', '*** Move to: src/to.ts', '@@', '+moved line', '*** End Patch'].join('\n');
  const ev = codex.normalize({ hook_event_name: 'PreToolUse', session_id: 'p1', tool_name: 'apply_patch', tool_input: { command: patch }, cwd: root }, { env: env(root) });
  assert.equal(ev.tool, 'file-edit');
  assert.deepEqual(ev.changes.map((c) => [c.op, c.path, c.from ?? null]), [['add', 'src/new.ts', null], ['update', 'src/old.ts', null], ['delete', 'src/gone.ts', null], ['move', 'src/to.ts', 'src/from.ts']]);
  assert.equal(ev.changes[0].content, 'export const a = 1; // adds\nrm -rf / # never executed');
  assert.equal(ev.changes[1].content, 'const x = 2;');
  assert.equal(ev.session.parent_shared, true);
  assert.equal(ev.session.agent_id, null);
  assert.ok(fs.existsSync(root), 'payload text was parsed, never run');
  const big = parseApplyPatch(Array.from({ length: MAX_PATCH_FILES + 20 }, (_, i) => `*** Add File: f${i}.ts\n+x`).join('\n'));
  assert.equal(big.changes.length, MAX_PATCH_FILES, 'bounded');
  const shell = codex.normalize({ hook_event_name: 'PreToolUse', session_id: 'p1', tool_name: 'Bash', tool_input: { command: 'cd sub && git push origin main' }, cwd: root }, { env: env(root) });
  assert.equal(shell.shell.git.subcommand, 'push');
  assert.equal(shell.shell.target_dir, path.join(root, 'sub'));
});

test('shell normalization: git -C, leading cd, chained add&&commit, relative targets', () => {
  const s = normalizeShell('git add a && git commit -m x', { cwd: '/w', root: '/w' });
  assert.equal(s.chained_add_commit, true);
  assert.equal(s.git.subcommand, 'commit');
  assert.equal(normalizeShell('git -c user.name=x -C "/p q" push', { cwd: '/w', root: '/w' }).target_dir, '/p q');
  assert.equal(normalizeShell("cd 'sub dir' && git commit", { cwd: '/w', root: '/w' }).target_dir, '/w/sub dir');
  assert.equal(normalizeShell('ls', { cwd: '/w', root: '/w' }).git, null);
});

test('project root resolves from the host variable, then git toplevel of cwd — never the plugin root', () => {
  const root = project();
  fs.mkdirSync(path.join(root, 'deep/er'), { recursive: true });
  assert.equal(resolveProjectRoot({ env: {}, cwd: path.join(root, 'deep/er') }), root);
  assert.equal(resolveProjectRoot({ env: { CLAUDE_PROJECT_DIR: '/explicit' }, cwd: root }), '/explicit');
  const plain = fs.mkdtempSync(path.join(os.tmpdir(), 'harness-nogit-'));
  assert.equal(resolveProjectRoot({ env: {}, cwd: plain }), path.resolve(plain));
});

test('project hook config: legacy .claude files read in place, canonical .agents/hooks counterparts, disagreeing copies are an error', () => {
  const root = project();
  fs.mkdirSync(path.join(root, '.claude'));
  fs.writeFileSync(path.join(root, '.claude/nudge-rules.json'), JSON.stringify({ _doc: 'x', rules: [{ glob: 'src/*', message: 'm' }] }));
  let cfg = resolveHookConfig(root);
  assert.equal(cfg.ok, true);
  assert.equal(cfg.sources.nudge_rules, '.claude/nudge-rules.json');
  assert.equal(cfg.values.nudge_rules.rules[0].message, 'm');
  assert.equal(cfg.values.project_preflight, '.claude/hooks/check-project-deps.sh');
  fs.mkdirSync(path.join(root, '.agents/hooks'), { recursive: true });
  fs.writeFileSync(path.join(root, '.agents/hooks/nudge-rules.json'), JSON.stringify({ rules: [{ glob: 'src/*', message: 'm' }] }));
  assert.equal(resolveHookConfig(root).ok, true, 'identical copies (docs ignored) are one config');
  fs.writeFileSync(path.join(root, '.agents/hooks/nudge-rules.json'), JSON.stringify({ rules: [] }));
  cfg = resolveHookConfig(root);
  assert.equal(cfg.ok, false);
  assert.match(cfg.errors[0], /disagree/);
  fs.rmSync(path.join(root, '.claude/nudge-rules.json'));
  fs.writeFileSync(path.join(root, '.agents/hooks/config.json'), JSON.stringify({ project_preflight: 'tools/preflight.sh', codex_child_identity: 'session' }));
  cfg = resolveHookConfig(root);
  assert.equal(cfg.values.project_preflight, 'tools/preflight.sh');
  assert.equal(cfg.values.codex_child_identity, 'session');
  assert.equal(cfg.sources.nudge_rules, '.agents/hooks/nudge-rules.json');
});

test('responses are host-shaped: deny is exit 2 + stderr, advisory is additionalContext JSON, unsupported combinations are reported not enforced', async () => {
  for (const host of ['claude', 'codex']) {
    const a = await loadHostAdapter(host, ADAPTERS);
    const deny = a.respond({ decision: 'deny', reason: 'nope' }, { event: 'PreToolUse' });
    assert.equal(deny.exit, 2);
    assert.equal(deny.stderr, 'nope\n');
    const ctxOut = a.respond({ decision: 'none', context: 'hint' }, { event: 'PostToolUse' });
    assert.equal(ctxOut.exit, 0);
    assert.deepEqual(JSON.parse(ctxOut.stdout), { hookSpecificOutput: { hookEventName: 'PostToolUse', additionalContext: 'hint' } });
    const lateDeny = a.respond({ decision: 'deny', reason: 'too late' }, { event: 'PostToolUse' });
    assert.equal(lateDeny.exit, 0);
    assert.equal(lateDeny.delivered, false);
    assert.match(lateDeny.stderr, /not supported/);
    const session = a.respond({ decision: 'none', context: 'warn' }, { event: 'SessionStart' });
    assert.equal(JSON.parse(session.stdout).hookSpecificOutput.hookEventName, 'SessionStart');
  }
});

test('runner: every ledger hook resolves to a core; capability state is reported; the CLI reads stdin and exits with the host code', async () => {
  const root = project();
  for (const hook of Object.keys(CORES)) {
    const core = await loadCore(hook);
    assert.equal(typeof core.run, 'function', hook);
    assert.ok(['hard', 'advisory', 'telemetry', 'preflight'].includes(core.strength), hook);
  }
  assert.deepEqual(STATES, ['active', 'dormant', 'unsupported', 'untrusted', 'disabled', 'error']);
  const dormant = await runHook({ host: 'claude', hook: 'guard-comments', payload: { hook_event_name: 'PostToolUse', session_id: 's', tool_name: 'Write', tool_input: { file_path: 'src/a.ts', content: '// a\n// b\n// c\n// d\nx' } }, env: env(root), cwd: root, adaptersRoot: ADAPTERS });
  assert.equal(dormant.state, 'dormant');
  assert.equal(dormant.exit, 0);
  assert.match(dormant.stderr, /hook-runner\[guard-comments\]: dormant/);
  const unsupported = await runHook({ host: 'codex', hook: 'nudge-lsp', payload: { hook_event_name: 'PostToolUse', session_id: 's', tool_name: 'Bash', tool_input: { command: 'grep foo' } }, env: env(root), cwd: root, adaptersRoot: ADAPTERS });
  assert.equal(unsupported.state, 'unsupported');
  const ctx = buildContext({ event: { project_root: root, host: 'claude' }, env: env(root) });
  assert.match(ctx.state.stateDir, /\.agents\/harness-state$/);
  fs.mkdirSync(path.join(root, '.claude'));
  fs.writeFileSync(path.join(root, '.claude/nudge-rules.json'), JSON.stringify({ rules: [{ glob: 'src/*', message: 'be careful' }] }));
  fs.mkdirSync(path.join(root, '.agents/hooks'), { recursive: true });
  fs.writeFileSync(path.join(root, '.agents/hooks/nudge-rules.json'), JSON.stringify({ rules: [] }));
  const conflict = await runHook({ host: 'claude', hook: 'nudge-files', payload: { hook_event_name: 'PostToolUse', session_id: 's', tool_name: 'Write', tool_input: { file_path: 'src/a.ts', content: 'x' } }, env: env(root), cwd: root, adaptersRoot: ADAPTERS });
  assert.equal(conflict.state, 'error');
  assert.equal(conflict.exit, 0, 'an advisory hook never blocks, even on a config error');
  const hardConflict = await runHook({ host: 'claude', hook: 'guard-memory', payload: { hook_event_name: 'PreToolUse', session_id: 's', tool_name: 'Write', tool_input: { file_path: 'src/a.ts', content: 'x' } }, env: env(root), cwd: root, adaptersRoot: ADAPTERS });
  assert.equal(hardConflict.exit, 2, 'a hard guard with a conflicting config blocks instead of guessing');
  fs.rmSync(path.join(root, '.agents/hooks/nudge-rules.json'));
  const cli = spawnSync(process.execPath, [RUNNER, '--host', 'claude', '--hook', 'nudge-files'], { cwd: root, env: env(root), encoding: 'utf8', input: JSON.stringify({ hook_event_name: 'PostToolUse', session_id: 's', tool_name: 'Write', tool_input: { file_path: path.join(root, 'src/a.ts'), content: 'x' } }) });
  assert.equal(cli.status, 0);
  assert.match(cli.stdout, /Reminder for src\/a\.ts: be careful/);
  const garbage = spawnSync(process.execPath, [RUNNER, '--host', 'codex', '--hook', 'guard-commit'], { cwd: root, env: env(root), encoding: 'utf8', input: 'not json' });
  assert.equal(garbage.status, 2, 'an unparsable payload means a required guard cannot see the call — block');
  assert.match(garbage.stderr, /could not parse/);
  const garbageSoft = spawnSync(process.execPath, [RUNNER, '--host', 'codex', '--hook', 'nudge-files'], { cwd: root, env: env(root), encoding: 'utf8', input: 'not json' });
  assert.equal(garbageSoft.status, 0, 'an advisory hook never blocks');
});

test('every manifest command executes against the built package with the documented plugin-root variable', () => {
  const project = fs.realpathSync.native(fs.mkdtempSync(path.join(os.tmpdir(), 'harness manifest-exec-')));
  execFileSync('git', ['init', '-q'], { cwd: project });
  for (const [host, dir, envVar] of [['claude', 'claude-code', 'CLAUDE_PLUGIN_ROOT'], ['codex', 'codex-cli', 'PLUGIN_ROOT']]) {
    const pkg = path.join(REPO, 'packages', host);
    assert.ok(fs.existsSync(path.join(pkg, 'hooks/hooks.json')), `${host}: packaged manifest`);
    const manifest = JSON.parse(fs.readFileSync(path.join(pkg, 'hooks/hooks.json'), 'utf8'));
    const seen = new Set();
    for (const [event, groups] of Object.entries(manifest.hooks)) for (const g of groups) for (const h of g.hooks) {
      const id = h.command.match(/--hook ([a-z-]+)$/)[1];
      if (seen.has(id)) continue;
      seen.add(id);
      const payload = JSON.stringify({ hook_event_name: event, session_id: 's', tool_name: host === 'codex' ? 'Bash' : 'Bash', tool_input: { command: 'ls' } });
      const r = spawnSync('sh', ['-c', h.command], { cwd: project, encoding: 'utf8', input: payload, env: { ...process.env, [envVar]: pkg, CLAUDE_PROJECT_DIR: project, PATH: process.env.PATH } });
      assert.ok(!/Cannot find module|ENOENT|could not start/.test(r.stderr), `${host}/${id}: ${r.stderr.trim().split('\n')[0]}`);
      assert.ok(r.status === 0 || r.status === 2, `${host}/${id}: exit ${r.status}`);
    }
    assert.ok(seen.size >= 9, `${host}: ${seen.size} hooks executed`);
    const bad = spawnSync('sh', ['-c', manifest.hooks.PreToolUse[0].hooks[0].command], { cwd: project, encoding: 'utf8', input: '{}', env: { ...process.env, CLAUDE_PROJECT_DIR: project } });
    assert.equal(bad.status, 2, `${host}: without the plugin-root variable a required guard blocks instead of vanishing`);
    assert.match(bad.stderr, /BLOCKED/);
  }
});

test('a required guard that cannot start blocks; an advisory one reports; --ack honours the project config', async () => {
  const root = project();
  fs.mkdirSync(path.join(root, '.agents/hooks'), { recursive: true });
  fs.writeFileSync(path.join(root, '.agents/hooks/config.json'), '{ not json');
  const hard = await runHook({ host: 'claude', hook: 'guard-commit', payload: { hook_event_name: 'PreToolUse', session_id: 's', tool_name: 'Bash', tool_input: { command: 'git commit -m x' } }, env: env(root), cwd: root, adaptersRoot: ADAPTERS });
  assert.equal(hard.exit, 2);
  assert.equal(hard.state, 'error');
  const soft = await runHook({ host: 'claude', hook: 'nudge-files', payload: { hook_event_name: 'PostToolUse', session_id: 's', tool_name: 'Write', tool_input: { file_path: 'src/a.ts', content: 'x' } }, env: env(root), cwd: root, adaptersRoot: ADAPTERS });
  assert.equal(soft.exit, 0);
  assert.equal(soft.state, 'error');
  const unknown = spawnSync(process.execPath, [RUNNER, '--host', 'claude', '--hook', 'guard-push'], { cwd: root, encoding: 'utf8', input: '{}', env: { ...env(root), CLAUDE_PROJECT_DIR: '/nonexistent/../weird' } });
  assert.ok([0, 2].includes(unknown.status));
  fs.writeFileSync(path.join(root, '.agents/hooks/config.json'), JSON.stringify({ codex_child_identity: 'session' }));
  const ack = spawnSync(process.execPath, [RUNNER, '--host', 'codex', '--hook', 'guard-memory', '--ack', '--domain', 'ai', '--project-root', root, '--session', 'p1'], { encoding: 'utf8', env: env(root) });
  assert.equal(ack.status, 0, ack.stdout + ack.stderr);
  assert.match(ack.stdout, /"ok": true/);
  fs.writeFileSync(path.join(root, '.agents/hooks/config.json'), JSON.stringify({ codex_child_identity: 'required' }));
  const refused = spawnSync(process.execPath, [RUNNER, '--host', 'codex', '--hook', 'guard-memory', '--ack', '--domain', 'ai', '--project-root', root, '--session', 'p1'], { encoding: 'utf8', env: env(root) });
  assert.equal(refused.status, 1, 'ok:false is a non-zero exit');
});

test('hook manifests: valid JSON, one runner command per entry, every hook id known, host-specific tool matchers', () => {
  for (const [host, dir] of [['claude', 'claude-code'], ['codex', 'codex-cli']]) {
    const manifest = JSON.parse(fs.readFileSync(path.join(ADAPTERS, dir, 'hooks.json'), 'utf8'));
    const ids = new Set();
    for (const [event, groups] of Object.entries(manifest.hooks)) {
      assert.ok(['PreToolUse', 'PostToolUse', 'SessionStart'].includes(event), event);
      for (const g of groups) for (const h of g.hooks) {
        const m = h.command.match(/hook-runner\.mjs" --host (\w+) --hook ([a-z-]+)$/);
        assert.ok(m, h.command);
        assert.equal(m[1], host);
        assert.ok(CORES[m[2]], `${host}: unknown hook ${m[2]}`);
        ids.add(m[2]);
        if (event === 'PreToolUse' && ['guard-commit', 'guard-push', 'guard-memory'].includes(m[2])) assert.notEqual(h.async, true, 'blockers are synchronous');
      }
    }
    if (host === 'codex') {
      assert.ok(!ids.has('nudge-lsp'), 'no Grep event on Codex');
      const pre = manifest.hooks.PreToolUse.map((g) => g.matcher);
      assert.ok(pre.includes('^apply_patch$'), 'Codex file edits arrive as apply_patch');
      assert.deepEqual(Object.keys(manifest).sort(), ['description', 'hooks'], 'Codex accepts no other top-level field');
      assert.match(JSON.parse(fs.readFileSync(path.join(ADAPTERS, dir, 'adapter.json'), 'utf8'))._hooks_doc, /PLUGIN_ROOT/);
    } else {
      assert.ok(ids.has('nudge-lsp'));
      assert.ok(manifest.hooks.PreToolUse.some((g) => g.matcher === 'Edit|Write|MultiEdit'));
    }
    assert.ok(ids.has('guard-commit') && ids.has('guard-push') && ids.has('guard-memory') && ids.has('check-deps'));
    assert.deepEqual(Object.keys(manifest).sort(), ['description', 'hooks'], `${host}: only the documented top-level fields`);
  }
});
