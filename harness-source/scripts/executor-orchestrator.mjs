#!/usr/bin/env node
// Supervised Codex worker for a Claude author: one child, one lock, one pair of tree snapshots.
// Replaces the shell spawner — liveness is a process fact rather than log growth, "did the second
// model actually run" is answered by a confirmed header, and what the child did to the tree is
// derived from the snapshots taken around it, not from a final `git status`.
//
//   node scripts/executor-orchestrator.mjs --project-root <dir> --plugin-root <dir> --author-host claude \
//        --mode read|write --prompt-file <file> [--scope <path>]... [--schema <file>] [--effort high] \
//        [--timeout-minutes N] [--allow-dirty yes] --scratch <dir> [--dry-run yes] [--technical-retry yes]
//
// Exit 0 only on completed + baseline ok + nothing out of scope; 3 on any other result; 1 internal.
import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { createHash, randomUUID } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { parseArgv, requireOpt } from './lib/argv.mjs';
import { realpathOrSelf, toPosix } from './lib/fsx.mjs';
import { validate } from './lib/schema.mjs';
import { effective, readProfile } from './profile.mjs';
import { BaselineError, compare, snapshot } from './git-baseline.mjs';
import { DEPTH_ENV, findOnPath, loginState, runChild } from './review-orchestrator.mjs';

export const RUN_ENV = 'HARNESS_EXECUTOR_RUN';
export const LOCK_NAME = 'harness-executor.lock';
// A worker never writes the harness itself; those paths are the supervisor's, and a secret is
// nobody's. Refused before the spawn, so the sandbox is never the only thing standing in the way.
const FORBIDDEN_SCOPE = [/^\.claude\//, /^\.agents\//, /^\.git\//, /^\.env/];
const here = path.dirname(fileURLToPath(import.meta.url));

function schemaFor(name) {
  return JSON.parse(fs.readFileSync(path.join(here, '..', 'schemas', name), 'utf8'));
}

export async function loadExecuteAdapter(adaptersRoot = null) {
  const candidates = adaptersRoot
    ? [path.join(adaptersRoot, 'codex-cli', 'execute.mjs')]
    : [path.join(here, 'adapters', 'codex-cli', 'execute.mjs'), path.join(here, '..', 'adapters', 'codex-cli', 'execute.mjs')];
  const file = candidates.find((c) => fs.existsSync(c));
  if (!file) throw new Error(`no codex executor adapter (looked in ${candidates.join(', ')})`);
  return import(fileURLToPath(new URL(`file://${file}`)));
}

function pidAlive(pid) {
  if (!Number.isInteger(pid) || pid <= 0) return false;
  try { process.kill(pid, 0); return true; } catch (e) { return e.code === 'EPERM'; }
}

function groupAlive(pgid) {
  if (!Number.isInteger(pgid) || pgid <= 0) return false;
  try { process.kill(-pgid, 0); return true; } catch (e) { return e.code === 'EPERM'; }
}

// Did a second model handle the input? Derived from facts, never from `status`: a refusal that
// never reached a spawn shows a full argv and still executed nothing.
export function executionOf(result) {
  const modelRan = Boolean(result.model?.confirmed) && result.process?.exit_code !== null;
  if (!modelRan) return 'not-executed';
  return result.status === 'completed' ? 'executed-complete' : 'executed-rejected';
}

export function summaryLine(result) {
  const execution = executionOf(result);
  const tail = `${result.model.confirmed}, run ${result.run_id.slice(0, 8)}`;
  if (execution === 'not-executed') return `Executor: NOT EXECUTED — ${result.error ?? result.status}`;
  if (result.baseline.status !== 'ok') return `Executor: EXECUTED, BASELINE DEVIATION — ${result.baseline.deviations[0] ?? result.baseline.status} (${tail})`;
  if (result.status === 'completed' && result.out_of_scope.length) return `Executor: EXECUTED, OUT OF SCOPE — ${result.out_of_scope.length} path(s) (${tail})`;
  if (result.status === 'completed') return `Executor: EXECUTED, COMPLETED — ${result.mode} (${tail})`;
  return `Executor: EXECUTED, REJECTED — ${result.error} (${tail})`;
}

// One retry per lineage, and only for a failure that left the tree exactly as it found it: a run
// that already wrote something must never have the same prompt applied to its own partial output.
export function retryEligible({ status, delta = [], baseline, process: proc = {}, lineageSpent = false }) {
  return status === 'failed' && !lineageSpent && baseline?.status === 'ok' && delta.length === 0 && !proc.timed_out && !proc.cancelled;
}

// Every result of one scratch lineage, oldest first, plus whether a child of it is still alive.
export function lineage(scratchDir) {
  const results = [];
  let alive = false;
  if (scratchDir && fs.existsSync(scratchDir)) {
    for (const f of fs.readdirSync(scratchDir)) {
      if (/^exec-.*\.json$/.test(f)) {
        try { results.push(JSON.parse(fs.readFileSync(path.join(scratchDir, f), 'utf8'))); } catch { /* not a result file */ }
      } else if (f.startsWith('run-')) {
        const pidFile = path.join(scratchDir, f, 'pid');
        if (fs.existsSync(pidFile) && pidAlive(Number(fs.readFileSync(pidFile, 'utf8')))) alive = true;
      }
    }
  }
  results.sort((a, b) => String(a.created_utc).localeCompare(String(b.created_utc)));
  const runs = results.filter((r) => r.status !== 'skipped');
  return { results, runs, last: runs.at(-1) ?? null, alive, spent: results.some((r) => r.technical_retry === true) };
}

function inScope(p, scope) {
  for (const s of scope) {
    if (p === s) return true;
    if (p.startsWith(s.endsWith('/') ? s : `${s}/`)) return true;
  }
  // A test written for a scope file is part of doing the work, wherever the project keeps tests.
  const stemOf = (f) => path.posix.basename(f).replace(/\.[^.]+$/, '');
  const base = path.posix.basename(p);
  for (const s of scope) {
    const stem = stemOf(s);
    if (!stem || !(base.startsWith(`${stem}.test.`) || base.startsWith(`${stem}.spec.`))) continue;
    if (p.includes('__tests__/') || p.startsWith('tests/') || path.posix.dirname(p) === path.posix.dirname(s)) return true;
  }
  return false;
}

function gitPath(projectRoot, name) {
  const r = spawnSync('git', ['rev-parse', '--git-path', name], { cwd: projectRoot, encoding: 'utf8' });
  if (r.status !== 0) throw new BaselineError(`cannot resolve the git dir of ${projectRoot}: ${String(r.stderr ?? '').trim().slice(0, 160)}`);
  const rel = r.stdout.trim();
  return path.isAbsolute(rel) ? rel : path.join(projectRoot, rel);
}

function porcelain(projectRoot) {
  const r = spawnSync('git', ['status', '--porcelain'], { cwd: projectRoot, encoding: 'utf8' });
  if (r.status !== 0) throw new BaselineError(`git status failed in ${projectRoot}`);
  return r.stdout.split('\n').filter((l) => l.trim() !== '');
}

export async function runExecutor(options) {
  const {
    projectRoot, pluginRoot = null, authorHost, mode, promptFile, scope = [], schemaFile = null,
    effort = null, timeoutMs = null, allowDirty = false, scratchDir, dryRun = false,
    technicalRetry = false, adaptersRoot = null, env = process.env, signal = null, profile = null,
  } = options;
  const root = path.resolve(projectRoot);
  const runId = randomUUID();
  const adapter = await loadExecuteAdapter(adaptersRoot);
  const def = adapter.defaults();
  const resultSchema = schemaFor('executor-result.schema.json');
  if (scratchDir) fs.mkdirSync(scratchDir, { recursive: true });

  const base = {
    schema_version: 1, run_id: runId, created_utc: new Date().toISOString(), author_host: authorHost,
    mode, status: 'failed', execution: 'not-executed', summary_line: '',
    model: { requested: def.model, confirmed: null }, effort: { requested: effort ?? def.effortDefault, confirmed: null },
    sandbox: null, scope: scope.map(toPosix), output_file: null, output_json: null,
    delta: [], out_of_scope: [], baseline: { status: 'not-run', deviations: [], info: [] },
    lock: { path: null, reclaimed: false },
    process: { exit_code: null, signal: null, duration_ms: 0, timed_out: false, cancelled: false, argv: [] },
    technical_retry: technicalRetry, technical_retry_allowed: false, notes: [], error: null,
  };
  let lockPath = null;
  let lockHeld = false;
  const releaseLock = () => {
    if (lockHeld && lockPath) { try { fs.rmSync(lockPath, { force: true }); } catch { /* already gone */ } }
    lockHeld = false;
  };
  const spent = lineage(scratchDir).spent || technicalRetry;
  const finish = (patch, { write = true } = {}) => {
    const result = { ...base, ...patch };
    result.execution = executionOf(result);
    result.technical_retry_allowed = retryEligible({ ...result, lineageSpent: spent });
    result.summary_line = summaryLine(result);
    const errors = validate(resultSchema, result);
    if (errors.length) throw new Error(`internal: executor result invalid: ${errors.join('; ')}`);
    if (write && scratchDir) fs.writeFileSync(path.join(scratchDir, `exec-${runId}.json`), `${JSON.stringify(result, null, 2)}\n`);
    releaseLock();
    return result;
  };

  try {
    // 1. Direction. A Codex author asking for a Codex worker would be one model marking its own work.
    if (authorHost !== 'claude') return finish({ status: 'failed', error: 'executor-orchestrator serves Claude authors; a Codex author has no cross-model executor in this release' });
    if (mode !== 'read' && mode !== 'write') return finish({ status: 'failed', error: `mode must be read or write, got ${JSON.stringify(mode)}` });
    if (Number(env[DEPTH_ENV] ?? 0) >= 1) return finish({ status: 'skipped', error: 'nested executor refused: this process already runs at reviewer/executor depth 1' });

    const eff = effective(profile ?? readProfile(root));
    if (eff.blocked) return finish({ status: 'failed', error: `project profile ${eff.status}: ${eff.blocked} — no executor runs on an implicit profile` });
    if (!eff.groups.execution) return finish({ status: 'skipped', error: 'execution group disabled in the project profile' });
    if (mode === 'read' && !eff.groups.review) return finish({ status: 'skipped', error: 'review group disabled in the project profile (explicit opt-out; this is not an opinion)' });

    if (mode === 'write') {
      const refused = base.scope.filter((p) => FORBIDDEN_SCOPE.some((re) => re.test(p)) || path.posix.isAbsolute(p) || p.split('/').includes('..'));
      if (refused.length) return finish({ status: 'failed', error: `scope refused: ${refused.join(', ')} — a worker never writes .claude/, .agents/, .git/ or .env*` });
    }

    const cli = findOnPath('codex', env.PATH);
    if (!cli) return finish({ status: 'failed', error: 'codex CLI not on PATH — the execution group is enabled, so this is blocked, not skipped' });
    const login = loginState('codex', env.PATH, env);
    if (login.loggedIn !== true) return finish({ status: 'failed', error: `codex CLI not logged in in this execution context (${login.detail}) — log in where the orchestrator runs; no attempt spent` });

    const led = lineage(scratchDir);
    if (led.alive) return finish({ status: 'skipped', error: 'an earlier executor child of this lineage is still alive — wait for it' });
    if (technicalRetry) {
      if (led.spent) return finish({ status: 'skipped', error: 'retry refused: the technical retry budget of this lineage is spent — start a new scratch lineage or decide by hand' });
      if (!led.last || led.last.status !== 'failed' || led.last.technical_retry_allowed !== true) return finish({ status: 'skipped', error: 'retry refused: only a failed run that left the tree untouched may be retried' });
      base.notes.push(`technical retry of failed run ${led.last.run_id}`);
    } else if (led.last && led.last.status === 'failed' && !(led.last.technical_retry_allowed === false && (led.last.delta ?? []).length === 0)) {
      return finish({ status: 'skipped', error: 'retry refused — pass --technical-retry yes once, or start a new scratch lineage' });
    }

    // 7. One write-mode child per worktree, whatever else shares the scratch directory.
    lockPath = gitPath(root, LOCK_NAME);
    base.lock.path = lockPath;
    const lockBody = () => `${JSON.stringify({ supervisor_pid: process.pid, child_pgid: null, started_utc: new Date().toISOString(), run_id: runId }, null, 2)}\n`;
    try {
      fs.writeFileSync(lockPath, lockBody(), { flag: 'wx' });
      lockHeld = true;
    } catch (e) {
      if (e.code !== 'EEXIST') throw e;
      let held = {};
      try { held = JSON.parse(fs.readFileSync(lockPath, 'utf8')); } catch { held = {}; }
      if (pidAlive(Number(held.supervisor_pid))) return finish({ status: 'failed', error: `another executor holds ${root}` });
      // A dead supervisor with a live worker group is not ours to clean up: report it, never kill a
      // group this process did not start.
      if (groupAlive(Number(held.child_pgid))) return finish({ status: 'failed', error: `orphaned executor ${held.child_pgid} still running in ${root}` });
      fs.rmSync(lockPath, { force: true });
      fs.writeFileSync(lockPath, lockBody(), { flag: 'wx' });
      lockHeld = true;
      base.lock.reclaimed = true;
      base.notes.push(`reclaimed a stale lock from run ${held.run_id ?? 'unknown'} (supervisor and child both gone)`);
    }

    if (mode === 'write' && !allowDirty) {
      const dirty = porcelain(root);
      if (dirty.length) return finish({ status: 'failed', error: `working tree not clean (${dirty.length} path(s)) — commit first, or pass --allow-dirty yes for a corrective run` });
    }

    const runDir = fs.mkdtempSync(path.join(scratchDir, `run-${runId.slice(0, 8)}-`));
    try {
      snapshot(path.join(runDir, 'before'), { repoRoot: root });
    } catch (e) {
      return finish({ status: 'failed', error: `baseline precondition failed: ${e.message}`, baseline: { status: 'precondition-failed', deviations: [], info: [] } });
    }

    const promptText = fs.readFileSync(promptFile, 'utf8');
    const outFile = path.join(runDir, 'final.md');
    fs.rmSync(outFile, { force: true });
    const spec = adapter.buildSpawn({ mode, model: def.model, effort: base.effort.requested, repoRoot: root, outFile });
    base.sandbox = adapter.modeSpec(mode).sandbox;
    const ceiling = timeoutMs ?? def.timeoutMinutes * 60_000;
    fs.writeFileSync(path.join(runDir, 'manifest.json'), `${JSON.stringify({
      run_id: runId, mode, sandbox: base.sandbox, effort: base.effort.requested, model: def.model,
      ceiling_ms: ceiling, scope: base.scope, prompt_file: promptFile, prompt_bytes: Buffer.byteLength(promptText),
      prompt_sha256: createHash('sha256').update(promptText).digest('hex'),
      schema_file: schemaFile, plugin_root: pluginRoot, argv: [spec.command, ...spec.args],
    }, null, 2)}\n`);
    if (dryRun) {
      // A preview is not a run: it leaves no result in the lineage.
      return finish({ status: 'skipped', error: `dry run — nothing was spawned; the manifest is ${path.join(runDir, 'manifest.json')}`, notes: [...base.notes, 'dry-run'] }, { write: false });
    }

    const statusFile = path.join(runDir, 'status.json');
    const startedUtc = new Date().toISOString();
    fs.writeFileSync(statusFile, `${JSON.stringify({ state: 'running', started_utc: startedUtc, updated_utc: startedUtc, pid: null }, null, 2)}\n`);
    let childPgid = null;
    // The pid arrives from runChild the moment the child exists; the lock records the group so a
    // dead supervisor can be told apart from a live orphan.
    const onSpawn = (pid) => {
      childPgid = pid;
      try { fs.writeFileSync(lockPath, `${JSON.stringify({ supervisor_pid: process.pid, child_pgid: pid, started_utc: startedUtc, run_id: runId }, null, 2)}\n`); } catch { /* lock vanished; the finally releases anyway */ }
      try { fs.writeFileSync(statusFile, `${JSON.stringify({ state: 'running', started_utc: startedUtc, updated_utc: new Date().toISOString(), pid }, null, 2)}\n`); } catch { /* heartbeat is advisory */ }
    };
    const heartbeat = setInterval(() => {
      try { fs.writeFileSync(statusFile, `${JSON.stringify({ state: 'running', started_utc: startedUtc, updated_utc: new Date().toISOString(), pid: childPgid }, null, 2)}\n`); } catch { /* advisory */ }
    }, 60_000);
    heartbeat.unref?.();

    let proc;
    try {
      proc = await runChild({
        command: cli, args: spec.args, cwd: root,
        env: { ...env, ...spec.env, [DEPTH_ENV]: '1', [RUN_ENV]: runId },
        stdin: promptText, timeoutMs: ceiling, signal, runDir, onSpawn,
      });
    } finally {
      clearInterval(heartbeat);
    }
    base.process = { exit_code: proc.exitCode, signal: proc.signal, duration_ms: proc.durationMs, timed_out: proc.timedOut, cancelled: proc.cancelled, argv: [spec.command, ...spec.args] };
    base.notes.push(`isolation: ${spec.isolation.join(' ')}`, spec.external_policy_note);

    // The leader can exit while a descendant it detached keeps writing. Establish the group is gone
    // before the second snapshot, or the snapshot measures a moving tree.
    if (childPgid && groupAlive(childPgid)) {
      try { process.kill(-childPgid, 'SIGTERM'); } catch { /* raced us */ }
      const deadline = Date.now() + 5_000;
      while (groupAlive(childPgid) && Date.now() < deadline) await new Promise((r) => setTimeout(r, 250));
      if (groupAlive(childPgid)) { try { process.kill(-childPgid, 'SIGKILL'); } catch { /* raced us */ } }
      base.notes.push('descendant processes terminated after leader exit');
    }
    fs.writeFileSync(statusFile, `${JSON.stringify({ state: 'settled', started_utc: startedUtc, updated_utc: new Date().toISOString(), pid: childPgid }, null, 2)}\n`);

    let baseline;
    try {
      snapshot(path.join(runDir, 'after'), { repoRoot: root });
      baseline = compare(path.join(runDir, 'before'), path.join(runDir, 'after'));
    } catch (e) {
      return finish({ status: 'failed', error: `baseline precondition failed after the run: ${e.message}`, baseline: { status: 'precondition-failed', deviations: [], info: [] } });
    }
    const delta = baseline.delta;
    const outOfScope = mode === 'write' ? delta.filter((p) => !inScope(p, base.scope)) : [];
    const bl = { status: baseline.status, deviations: [...baseline.deviations], info: baseline.info };
    if (mode === 'read' && delta.length) {
      bl.deviations.push(`read-only child changed ${delta.length} path(s): ${delta.join(', ')}`);
      bl.status = 'deviation';
    }
    const parsed = adapter.parseOutput({ stderr: proc.stderr, outFile });
    base.model.confirmed = parsed.confirmed.model;
    base.effort.confirmed = parsed.confirmed.effort;
    const common = { delta, out_of_scope: outOfScope, baseline: bl, output_file: fs.existsSync(outFile) ? outFile : null };
    const finalText = (parsed.finalText ?? '').trim();

    if (proc.timedOut) return finish({ ...common, status: 'failed', error: `executor exceeded ${Math.round(ceiling / 60_000)} min and was terminated` });
    if (proc.cancelled) return finish({ ...common, status: 'failed', error: 'executor cancelled by the supervisor' });
    if (mode === 'read' && delta.length) return finish({ ...common, status: 'failed', error: 'read-only child changed the tree — opinion rejected' });
    if (proc.exitCode !== 0) return finish({ ...common, status: 'failed', error: `executor exited ${proc.exitCode}${proc.stderr ? `: ${proc.stderr.toString('utf8').trim().split('\n').slice(-1)[0]}` : ''}` });
    if (!parsed.confirmed.model) return finish({ ...common, status: 'failed', error: 'model identity not confirmed by the CLI output' });
    if (!adapter.modelMatches(def.model, parsed.confirmed.model)) return finish({ ...common, status: 'failed', error: `model mismatch: requested ${def.model}, CLI reported ${parsed.confirmed.model}` });
    if (parsed.confirmed.effort && parsed.confirmed.effort !== base.effort.requested) return finish({ ...common, status: 'failed', error: `effort mismatch: requested ${base.effort.requested}, CLI reported ${parsed.confirmed.effort}` });
    if (schemaFile) {
      let value = null;
      try { value = JSON.parse(finalText); } catch (e) { return finish({ ...common, status: 'failed', error: `final message is not JSON: ${e.message}` }); }
      const errors = validate(JSON.parse(fs.readFileSync(schemaFile, 'utf8')), value);
      if (errors.length) return finish({ ...common, status: 'failed', error: `final message does not match the caller's schema: ${errors.slice(0, 5).join('; ')}` });
      return finish({ ...common, status: 'completed', output_json: value });
    }
    if (!finalText) {
      if (delta.length) return finish({ ...common, status: 'completed', notes: [...base.notes, 'empty final message'] });
      return finish({ ...common, status: 'failed', error: 'executor produced no final message and changed nothing (exit 0 is not a result)' });
    }
    return finish({ ...common, status: 'completed' });
  } finally {
    releaseLock();
  }
}

async function main() {
  const { opts, positionals } = parseArgv(process.argv.slice(2));
  if (positionals.length) throw new Error(`unexpected argument ${positionals[0]} — repeat --scope per path`);
  const result = await runExecutor({
    projectRoot: requireOpt(opts, 'project-root'), pluginRoot: opts['plugin-root'] ?? null,
    authorHost: requireOpt(opts, 'author-host'), mode: requireOpt(opts, 'mode'),
    promptFile: requireOpt(opts, 'prompt-file'), scope: [].concat(opts.scope ?? []),
    schemaFile: opts.schema ?? null, effort: opts.effort ?? null,
    timeoutMs: opts['timeout-minutes'] ? Number(opts['timeout-minutes']) * 60_000 : null,
    allowDirty: opts['allow-dirty'] === 'yes', scratchDir: requireOpt(opts, 'scratch'),
    dryRun: opts['dry-run'] === 'yes', technicalRetry: opts['technical-retry'] === 'yes',
  });
  console.log(JSON.stringify(result, null, 2));
  console.error(result.summary_line);
  process.exit(result.status === 'completed' && result.baseline.status === 'ok' && result.out_of_scope.length === 0 ? 0 : 3);
}

if (process.argv[1] && fileURLToPath(import.meta.url) === realpathOrSelf(process.argv[1])) {
  main().catch((err) => { console.error(`executor-orchestrator: ${err.message}`); process.exit(1); });
}
