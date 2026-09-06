import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { runHook } from '../../harness-source/scripts/hook-runner.mjs';
import { dependencyPreflight } from '../../harness-source/scripts/preflight-deps.mjs';

const REPO = path.resolve(import.meta.dirname, '../..');
const ADAPTERS = path.join(REPO, 'harness-source/adapters');

function project() {
  const dir = fs.realpathSync.native(fs.mkdtempSync(path.join(os.tmpdir(), 'harness preflight-')));
  execFileSync('git', ['init', '-q'], { cwd: dir });
  return dir;
}
const env = (root, extra = {}) => ({ PATH: process.env.PATH, HOME: os.homedir(), CLAUDE_PROJECT_DIR: root, ...extra });
const start = { hook_event_name: 'SessionStart', session_id: 's', source: 'startup' };

test('shared preflight: node/git required, jq optional; the project-owned check-project-deps.sh runs unchanged with the project cwd and its output is relayed, never parsed', async () => {
  const root = project();
  const healthy = dependencyPreflight({ projectRoot: root, host: 'claude' });
  assert.equal(healthy.checks.find((c) => c.name === 'node').ok, true);
  assert.equal(healthy.checks.find((c) => c.name === 'git').required, true);
  assert.equal(healthy.checks.find((c) => c.name === 'jq').required, false);
  assert.match(healthy.project.error, /not present/);
  fs.mkdirSync(path.join(root, '.claude/hooks'), { recursive: true });
  fs.writeFileSync(path.join(root, '.claude/hooks/check-project-deps.sh'), '#!/bin/bash\ncat >/dev/null\n[ "$PWD" = "$CLAUDE_PROJECT_DIR" ] || echo "WRONG CWD"\n[ -f .env ] || echo "⚠️  .env missing — MCP servers start without credentials"\necho "SECRET_VALUE_SHOULD_NOT_BE_PRINTED_BY_HARNESS"\nexit 0\n');
  const res = dependencyPreflight({ projectRoot: root, host: 'codex' });
  assert.equal(res.project.ran, true);
  assert.equal(res.project.exit, 0);
  assert.match(res.project.output, /\.env missing/);
  assert.ok(!res.project.output.includes('WRONG CWD'), 'runs with the project root as cwd on both hosts');
  assert.equal(fs.existsSync(path.join(root, '.env')), false, 'the harness never creates or reads .env');
  for (const host of ['claude', 'codex']) {
    const out = await runHook({ host, hook: 'check-deps', payload: start, env: env(root), cwd: root, adaptersRoot: ADAPTERS });
    assert.equal(out.exit, 0);
    const ctx = JSON.parse(out.stdout).hookSpecificOutput;
    assert.equal(ctx.hookEventName, 'SessionStart');
    assert.match(ctx.additionalContext, /\.env missing/);
  }
  fs.mkdirSync(path.join(root, '.agents/hooks'), { recursive: true });
  fs.writeFileSync(path.join(root, '.agents/hooks/config.json'), JSON.stringify({ project_preflight: '../outside.sh' }));
  assert.match(dependencyPreflight({ projectRoot: root, host: 'claude', runProjectScript: false }).project.error, /not present|escapes/);
});

test('missing infrastructure is reported as missing protection, never as healthy enforcement; silent when healthy', async () => {
  const root = project();
  const quiet = await runHook({ host: 'claude', hook: 'check-deps', payload: start, env: env(root), cwd: root, adaptersRoot: ADAPTERS });
  const text = quiet.stdout ? JSON.parse(quiet.stdout).hookSpecificOutput.additionalContext : '';
  assert.ok(!/git.*missing/.test(text), 'git present → no warning about it');
  const nogit = await runHook({ host: 'codex', hook: 'check-deps', payload: start, env: env(root, { PATH: path.dirname(process.execPath) }), cwd: root, adaptersRoot: ADAPTERS });
  assert.equal(nogit.state, 'error');
  const ctx = JSON.parse(nogit.stdout).hookSpecificOutput.additionalContext;
  assert.match(ctx, /git \(required\)/);
  assert.match(ctx, /will BLOCK — that is missing protection, not a pass/);
  const res = dependencyPreflight({ projectRoot: root, host: 'claude', env: { PATH: path.dirname(process.execPath) } });
  assert.equal(res.ok, false);
});
