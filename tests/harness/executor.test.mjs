import { test, after } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawn, spawnSync } from 'node:child_process';
import { LOCK_NAME, runExecutor } from '../../harness-source/scripts/executor-orchestrator.mjs';
import { syntheticProfile } from '../../harness-source/scripts/profile.mjs';
import { validate } from '../../harness-source/scripts/lib/schema.mjs';

const FIX = path.join(import.meta.dirname, 'fixtures');
const MOCK_BIN = path.join(FIX, 'mock-bin');
const ADAPTERS = path.resolve(import.meta.dirname, '../../harness-source/adapters');
const SCRIPT = path.resolve(import.meta.dirname, '../../harness-source/scripts/executor-orchestrator.mjs');
const RESULT_SCHEMA = JSON.parse(fs.readFileSync(path.resolve(import.meta.dirname, '../../harness-source/schemas/executor-result.schema.json'), 'utf8'));

const strays = [];
after(() => { for (const p of strays) { try { process.kill(-p, 'SIGKILL'); } catch { /* gone */ } } });

function project() {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'harness-exec-project-'));
  const git = (...args) => {
    const r = spawnSync('git', ['-c', 'core.hooksPath=/dev/null', ...args], { cwd: dir, encoding: 'utf8', env: { ...process.env, GIT_CONFIG_NOSYSTEM: '1' } });
    if (r.status !== 0) throw new Error(`git ${args.join(' ')}: ${r.stderr}`);
    return r.stdout;
  };
  git('init', '-q', '-b', 'main', '.');
  git('config', 'user.email', 'harness@example.test');
  git('config', 'user.name', 'harness');
  fs.mkdirSync(path.join(dir, 'src'), { recursive: true });
  fs.mkdirSync(path.join(dir, '.agents/memory'), { recursive: true });
  fs.writeFileSync(path.join(dir, 'src/app.js'), 'original\n');
  fs.writeFileSync(path.join(dir, '.gitignore'), 'build/\n.secrets/\n');
  fs.writeFileSync(path.join(dir, '.agents/memory/index.md'), '# index\n');
  git('add', '-A');
  git('commit', '-q', '-m', 'init');
  return { dir, git, lock: path.join(dir, '.git', LOCK_NAME) };
}

function env(mockMode, extra = {}) {
  return { PATH: `${MOCK_BIN}${path.delimiter}${path.dirname(process.execPath)}${path.delimiter}/usr/bin${path.delimiter}/bin`, HOME: os.homedir(), MOCK_MODE: mockMode, ...extra };
}

function scratchDir() {
  return fs.mkdtempSync(path.join(os.tmpdir(), 'harness-exec-scratch-'));
}

function promptIn(scratch, text = 'Implement the plan.\n') {
  const file = path.join(scratch, 'prompt.md');
  fs.writeFileSync(file, text);
  return file;
}

// Every result of every case is schema-validated here, so case (t) needs no separate test.
async function run(mode, mockMode, opts = {}) {
  const p = opts.project ?? project();
  const scratch = opts.scratch ?? scratchDir();
  const result = await runExecutor({
    projectRoot: p.dir, pluginRoot: null, authorHost: opts.authorHost ?? 'claude', mode,
    promptFile: opts.promptFile ?? promptIn(scratch, opts.prompt), scope: opts.scope ?? [],
    schemaFile: opts.schemaFile ?? null, effort: 'high', timeoutMs: opts.timeoutMs ?? 30_000,
    allowDirty: opts.allowDirty ?? false, scratchDir: scratch, dryRun: opts.dryRun ?? false,
    technicalRetry: opts.technicalRetry ?? false, adaptersRoot: ADAPTERS,
    env: env(mockMode, opts.extra), profile: opts.profile ?? syntheticProfile({ groups: { execution: true, review: true } }),
  });
  assert.deepEqual(validate(RESULT_SCHEMA, result), [], `result of ${mockMode} must satisfy the schema`);
  return { result, project: p, scratch };
}

test('a clean write run: completed, delta inside scope, workspace-write argv, prompt on stdin', async () => {
  const record = path.join(os.tmpdir(), `exec-record-a-${Date.now()}.json`);
  const { result, project: p } = await run('write', 'exec-write-ok', { scope: ['src/app.js'], extra: { MOCK_RECORD: record } });
  assert.equal(result.status, 'completed');
  assert.equal(result.execution, 'executed-complete');
  assert.deepEqual(result.delta, ['src/app.js']);
  assert.deepEqual(result.out_of_scope, []);
  assert.equal(result.baseline.status, 'ok');
  assert.ok(result.status === 'completed' && result.baseline.status === 'ok' && result.out_of_scope.length === 0, 'the exit-0 condition holds');
  assert.match(result.summary_line, /^Executor: EXECUTED, COMPLETED — write/);
  const joined = result.process.argv.join(' ');
  assert.match(joined, /--sandbox workspace-write/);
  assert.ok(!joined.includes('--output-schema'), 'never a native output schema');
  assert.ok(!joined.includes('--disable shell_tool'), 'a worker keeps its shell');
  const rec = JSON.parse(fs.readFileSync(record, 'utf8'));
  assert.ok(rec.stdinHead.startsWith('Implement the plan.'), 'the prompt file is what reaches stdin');
  assert.ok(rec.args.includes(p.dir), 'the child is pointed at the project root with -C');
  assert.equal(rec.depth, '1');
});

test('a write under .agents/ is a baseline deviation, whatever the child reported', async () => {
  const { result } = await run('write', 'exec-write-tamper', { scope: ['src/app.js'] });
  assert.equal(result.baseline.status, 'deviation');
  assert.ok(result.baseline.deviations.some((d) => d.includes('writes under .agents/')), result.baseline.deviations.join('|'));
  assert.match(result.summary_line, /^Executor: EXECUTED, BASELINE DEVIATION/);
});

test('a path outside the declared scope is reported, never silently accepted', async () => {
  const { result } = await run('write', 'exec-write-outside-scope', { scope: ['src/app.js'] });
  assert.deepEqual(result.out_of_scope, ['other.js']);
  assert.match(result.summary_line, /^Executor: EXECUTED, OUT OF SCOPE — 1 path\(s\)/);
});

test('an empty final message with a delta is a completed run that lost its report', async () => {
  const { result } = await run('write', 'exec-write-empty-with-delta', { scope: ['src/app.js'] });
  assert.equal(result.status, 'completed');
  assert.ok(result.notes.includes('empty final message'));
  assert.equal(result.technical_retry_allowed, false, 'a run that wrote something is never re-run with the same prompt');
});

test('technical retry: one per lineage, only after a failure that touched nothing', async () => {
  const p = project();
  const scratch = scratchDir();
  const first = await run('write', 'exec-write-empty', { project: p, scratch });
  assert.equal(first.result.status, 'failed');
  assert.equal(first.result.technical_retry_allowed, true);

  const retried = await run('write', 'exec-write-empty', { project: p, scratch, technicalRetry: true });
  assert.equal(retried.result.technical_retry, true, 'the retry is admitted and recorded');
  assert.equal(retried.result.status, 'failed');
  assert.equal(retried.result.technical_retry_allowed, false, 'the budget is spent');

  const third = await run('write', 'exec-write-empty', { project: p, scratch, technicalRetry: true });
  assert.equal(third.result.status, 'skipped');
  assert.match(third.result.error, /budget of this lineage is spent/);

  const fresh = project();
  const lineage = scratchDir();
  await run('write', 'exec-write-empty', { project: fresh, scratch: lineage });
  const unflagged = await run('write', 'exec-write-empty', { project: fresh, scratch: lineage });
  assert.equal(unflagged.result.status, 'skipped');
  assert.match(unflagged.result.error, /retry refused — pass --technical-retry yes once/);
});

test('retry eligibility follows what the run left behind, not what failed', async () => {
  const schema = path.join(scratchDir(), 'out.schema.json');
  fs.writeFileSync(schema, JSON.stringify({ type: 'object', required: ['verdict'], properties: { verdict: { enum: ['ship', 'revise'] } } }));
  const bad = await run('read', 'exec-read-schema-bad', { schemaFile: schema });
  assert.equal(bad.result.technical_retry_allowed, true);
  const auth = await run('write', 'exec-auth-mid-run', {});
  assert.equal(auth.result.technical_retry_allowed, true);
  const hung = await run('write', 'exec-hang', { timeoutMs: 2_000 });
  assert.equal(hung.result.technical_retry_allowed, false, 'the ceiling is the budget');
});

test('a dirty tree blocks a write run; --allow-dirty admits a corrective one and exempts untouched dirt', async () => {
  const p = project();
  fs.writeFileSync(path.join(p.dir, 'src/app.js'), 'human edit\n');
  const blocked = await run('write', 'exec-write-noop', { project: p, scope: ['src/app.js'] });
  assert.equal(blocked.result.status, 'failed');
  assert.match(blocked.result.error, /working tree not clean/);

  const allowed = await run('write', 'exec-write-noop', { project: p, scope: ['src/app.js'], allowDirty: true });
  assert.equal(allowed.result.status, 'completed');
  assert.deepEqual(allowed.result.delta, [], 'dirt the child never touched is not the child\'s delta');
});

test('pre-existing dirt under .agents/ is exempt until the child edits it again', async () => {
  const p = project();
  fs.writeFileSync(path.join(p.dir, '.agents/note.md'), 'human note\n');
  const exempt = await run('write', 'exec-write-noop', { project: p, allowDirty: true });
  assert.equal(exempt.result.baseline.status, 'ok');

  const touched = await run('write', 'exec-write-ok', { project: p, allowDirty: true, extra: { MOCK_TOUCH: '.agents/note.md' } });
  assert.equal(touched.result.baseline.status, 'deviation');
  assert.ok(touched.result.baseline.deviations.some((d) => d.includes('writes under .agents/')));
});

test('read mode runs read-only and keeps its shell', async () => {
  const { result } = await run('read', 'exec-read-ok');
  assert.equal(result.status, 'completed');
  const joined = result.process.argv.join(' ');
  assert.match(joined, /--sandbox read-only/);
  assert.ok(!joined.includes('--disable shell_tool'), 'a read-mode worker still reads files and runs git');
});

test('a read-mode child that writes has its opinion rejected', async () => {
  const { result } = await run('read', 'exec-read-wrote');
  assert.equal(result.status, 'failed');
  assert.equal(result.baseline.status, 'deviation');
  assert.ok(result.baseline.deviations.some((d) => d.includes('read-only child changed')), result.baseline.deviations.join('|'));
});

test('--schema is validated after the run, never traded for the sandbox', async () => {
  const dir = scratchDir();
  const schema = path.join(dir, 'out.schema.json');
  fs.writeFileSync(schema, JSON.stringify({ type: 'object', required: ['verdict', 'findings'], properties: { verdict: { enum: ['ship', 'revise'] }, findings: { type: 'array' } } }));
  const ok = await run('read', 'exec-read-schema-ok', { schemaFile: schema });
  assert.equal(ok.result.status, 'completed');
  assert.equal(ok.result.output_json.verdict, 'ship');
  assert.ok(!ok.result.process.argv.join(' ').includes('--output-schema'));

  const bad = await run('read', 'exec-read-schema-bad', { schemaFile: schema });
  assert.equal(bad.result.status, 'failed');
  assert.match(bad.result.error, /not JSON/);
});

test('the ceiling terminates the child and releases the lock', async () => {
  const { result, project: p } = await run('write', 'exec-hang', { timeoutMs: 2_000 });
  assert.equal(result.status, 'failed');
  assert.equal(result.process.timed_out, true);
  assert.ok(!fs.existsSync(p.lock), 'the worktree lock is released on every exit path');
});

test('a nonzero exit is an executed, rejected run; a missing model header is not executed at all', async () => {
  const nonzero = await run('write', 'exec-nonzero');
  assert.equal(nonzero.result.status, 'failed');
  assert.equal(nonzero.result.execution, 'executed-rejected');

  const auth = await run('write', 'exec-auth-mid-run');
  assert.equal(auth.result.execution, 'not-executed');
  assert.match(auth.result.summary_line, /^Executor: NOT EXECUTED/);
});

test('the CLI-reported model must be the one that was asked for', async () => {
  const { result } = await run('write', 'exec-wrong-model', { scope: ['src/app.js'] });
  assert.equal(result.status, 'failed');
  assert.match(result.error, /model mismatch/);
});

test('a Codex author is refused: one model never marks its own work', async () => {
  const { result } = await run('write', 'exec-write-ok', { authorHost: 'codex' });
  assert.equal(result.status, 'failed');
  assert.equal(result.author_host, 'codex', 'the asking host is recorded, never rewritten');
  assert.match(result.error, /serves Claude authors/);
});

test('disabled groups skip: execution for a write, review for an opinion', async () => {
  const off = await run('write', 'exec-write-ok', { profile: syntheticProfile({ groups: { execution: false, review: true } }) });
  assert.equal(off.result.status, 'skipped');
  assert.match(off.result.error, /execution group disabled/);

  const noReview = await run('read', 'exec-read-ok', { profile: syntheticProfile({ groups: { execution: true, review: false } }) });
  assert.equal(noReview.result.status, 'skipped');
  assert.match(noReview.result.error, /review group disabled/);
});

test('a scope naming harness or secret paths is refused before anything is spawned', async () => {
  const record = path.join(os.tmpdir(), `exec-record-q-${Date.now()}.json`);
  const { result } = await run('write', 'exec-write-ok', { scope: ['.claude/x.md'], extra: { MOCK_RECORD: record } });
  assert.equal(result.status, 'failed');
  assert.match(result.error, /scope refused/);
  assert.ok(!fs.existsSync(record), 'no child was spawned');
});

test('the worktree lock: a live holder blocks, dead pids are reclaimed, a live orphan is reported', async () => {
  const p = project();
  fs.writeFileSync(p.lock, JSON.stringify({ supervisor_pid: process.pid, child_pgid: null, run_id: 'held' }));
  const held = await run('write', 'exec-write-noop', { project: p });
  assert.equal(held.result.status, 'failed');
  assert.match(held.result.error, /another executor holds/);

  fs.writeFileSync(p.lock, JSON.stringify({ supervisor_pid: 2 ** 22 - 3, child_pgid: 2 ** 22 - 4, run_id: 'stale' }));
  const reclaimed = await run('write', 'exec-write-noop', { project: p });
  assert.equal(reclaimed.result.status, 'completed');
  assert.equal(reclaimed.result.lock.reclaimed, true);

  const orphan = spawn('sleep', ['30'], { detached: true, stdio: 'ignore' });
  orphan.unref();
  strays.push(orphan.pid);
  fs.writeFileSync(p.lock, JSON.stringify({ supervisor_pid: 2 ** 22 - 3, child_pgid: orphan.pid, run_id: 'orphaned' }));
  const reported = await run('write', 'exec-write-noop', { project: p });
  assert.equal(reported.result.status, 'failed');
  assert.match(reported.result.error, /orphaned executor \d+ still running/);
  try { process.kill(-orphan.pid, 'SIGKILL'); } catch { /* gone */ }
  fs.rmSync(p.lock, { force: true });
});

test('a dry run writes a manifest, spawns nothing and leaves no result in the lineage', async () => {
  const { result, project: p, scratch } = await run('write', 'exec-write-ok', { dryRun: true, scope: ['src/app.js'] });
  assert.equal(result.status, 'skipped');
  const runDir = fs.readdirSync(scratch).find((f) => f.startsWith('run-'));
  assert.ok(fs.existsSync(path.join(scratch, runDir, 'manifest.json')));
  assert.deepEqual(fs.readdirSync(scratch).filter((f) => f.startsWith('exec-')), [], 'a preview is not a run');
  assert.ok(!fs.existsSync(p.lock));
});

test('a nested executor refuses at depth 1', async () => {
  const { result } = await run('write', 'exec-write-ok', { extra: { HARNESS_REVIEW_DEPTH: '1' } });
  assert.equal(result.status, 'skipped');
  assert.match(result.error, /nested executor refused/);
});

test('a descendant that outlives the leader is terminated before the tree is measured', async () => {
  const { result, project: p } = await run('write', 'exec-write-leaves-descendant', { scope: ['src/app.js'] });
  assert.ok(result.notes.some((n) => n.includes('descendant processes terminated')), result.notes.join('|'));
  await new Promise((r) => setTimeout(r, 2_500));
  assert.ok(!fs.existsSync(path.join(p.dir, 'late.js')), 'the late write never lands');
  assert.ok(!fs.existsSync(p.lock), 'the lock outlives the child, not the group');
});

test('a secret-looking ignored file written by the child is a deviation', async () => {
  const { result } = await run('write', 'exec-write-ok', { scope: ['src/app.js'], extra: { MOCK_TOUCH: '.secrets/token.pem' } });
  assert.equal(result.baseline.status, 'deviation');
  assert.ok(result.baseline.deviations.some((d) => d.includes('secret-looking')), result.baseline.deviations.join('|'));
  assert.equal(result.technical_retry_allowed, false);
});

test('CLI: --scope repeats once per path, a positional is an error', async () => {
  const p = project();
  const scratch = scratchDir();
  const prompt = promptIn(scratch);
  const cli = (...args) => spawnSync(process.execPath, [SCRIPT, ...args], { encoding: 'utf8', env: env('exec-write-noop') });
  const ok = cli('--project-root', p.dir, '--author-host', 'claude', '--mode', 'write', '--prompt-file', prompt, '--scratch', scratch, '--scope', 'src/a b.js', '--scope', 'src/c.js', '--timeout-minutes', '1');
  const result = JSON.parse(ok.stdout);
  assert.deepEqual(result.scope, ['src/a b.js', 'src/c.js']);
  assert.match(ok.stderr, /^Executor: /m);

  const positional = cli('--project-root', p.dir, '--author-host', 'claude', '--mode', 'write', '--prompt-file', prompt, '--scratch', scratch, 'src/extra.js');
  assert.equal(positional.status, 1);
  assert.match(positional.stderr, /repeat --scope per path/);
});
