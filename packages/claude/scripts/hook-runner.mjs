#!/usr/bin/env node
// Shared hook runner (T09). One process per hook event: read the host payload on stdin, normalize it
// through the host adapter, resolve the project root (never the plugin root) and the project's hook
// configuration, run the shared core policy, and emit only the response the host supports. The
// capability state (active / dormant / unsupported / untrusted / disabled / error) is always
// reported on stderr when it is not `active`, so a silent no-op cannot pass for protection.
//
//   node scripts/hook-runner.mjs --host claude|codex --hook <id> < payload.json
//   node scripts/hook-runner.mjs --host claude --hook guard-memory --ack --domain <d> [--executor <id>]
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { parseArgv, requireOpt } from './lib/argv.mjs';
import { realpathOrSelf } from './lib/fsx.mjs';
import { resolveHookConfig } from './lib/hook-config.mjs';
import { sidecarPaths } from './lib/telemetry.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
const HOST_DIR = { claude: 'claude-code', codex: 'codex-cli' };

export const CORES = {
  'guard-commit': 'commit.mjs',
  'guard-push': 'push.mjs',
  'guard-memory': 'memory-guard.mjs',
  'guard-comments': 'comments.mjs',
  'nudge-files': 'nudge-files.mjs',
  'guard-memory-scope': 'memory-scope.mjs',
  'track-memory-read': 'memory-read.mjs',
  'audit-append': 'audit.mjs',
  'nudge-lsp': 'lsp-hint.mjs',
  'check-deps': 'deps.mjs',
};
export const STATES = ['active', 'dormant', 'unsupported', 'untrusted', 'disabled', 'error'];
// Required protections: any failure before or during their run must block, never pass silently.
export const HARD_HOOKS = new Set(['guard-commit', 'guard-push', 'guard-memory']);

function firstExisting(candidates) {
  return candidates.find((c) => fs.existsSync(c));
}

export async function loadHostAdapter(host, adaptersRoot = null) {
  const dir = HOST_DIR[host];
  if (!dir) throw new Error(`host must be claude or codex, got ${host}`);
  const file = firstExisting(adaptersRoot ? [path.join(adaptersRoot, dir, 'hooks.mjs')] : [path.join(here, 'adapters', dir, 'hooks.mjs'), path.join(here, '..', 'adapters', dir, 'hooks.mjs')]);
  if (!file) throw new Error(`no hook adapter for ${host}`);
  return import(fileURLToPath(new URL(`file://${file}`)));
}

export async function loadCore(hook, coresRoot = null) {
  const name = CORES[hook];
  if (!name) throw new Error(`unknown hook ${hook}; known: ${Object.keys(CORES).join(', ')}`);
  const file = firstExisting(coresRoot ? [path.join(coresRoot, name)] : [path.join(here, '..', 'hooks', 'core', name), path.join(here, 'hooks', 'core', name)]);
  if (!file) throw new Error(`core missing for ${hook}: ${name}`);
  return import(fileURLToPath(new URL(`file://${file}`)));
}

// Context every core receives: project root, resolved config, sidecar paths, host, env.
export function buildContext({ event, env = process.env, config = null }) {
  const projectRoot = event.project_root;
  const resolved = config ?? resolveHookConfig(projectRoot);
  const state = sidecarPaths(projectRoot, { stateDir: resolved.values.state_dir, legacySidecars: resolved.values.legacy_sidecars !== false });
  return { projectRoot, host: event.host, env, config: resolved, state, now: new Date() };
}

export async function runHook({ host, hook, payload, env = process.env, cwd = process.cwd(), adaptersRoot = null, coresRoot = null, config = null }) {
  const hard = HARD_HOOKS.has(hook);
  let adapter; let core; let event; let ctx;
  try {
    adapter = await loadHostAdapter(host, adaptersRoot);
    core = await loadCore(hook, coresRoot);
    event = adapter.normalize(payload, { env, cwd });
    ctx = buildContext({ event, env, config });
  } catch (e) {
    // Preparation failed (bad adapter, unreadable config, invalid state dir): a required
    // protection that cannot even start blocks; an advisory hook reports and steps aside.
    const reason = `hook ${hook} could not start: ${e.message}${hard ? ' — a required protection that cannot run blocks instead of passing' : ''}`;
    return hard ? { exit: 2, stdout: '', stderr: `BLOCKED: ${reason}\n`, delivered: true, state: 'error', outcome: { decision: 'deny', reason, state: 'error' }, event: event ?? null }
      : { exit: 0, stdout: '', stderr: `hook-runner[${hook}]: error — ${reason}\n`, delivered: false, state: 'error', outcome: { decision: 'none', reason, state: 'error' }, event: event ?? null };
  }
  if (!ctx.config.ok) {
    const outcome = { decision: core.strength === 'hard' ? 'deny' : 'none', reason: `hook configuration conflict: ${ctx.config.errors.join('; ')}`, state: 'error' };
    if (core.strength !== 'hard') outcome.context = undefined;
    return finish(adapter, event, outcome, hook);
  }
  let outcome;
  try {
    outcome = await core.run(event, ctx);
  } catch (e) {
    outcome = { decision: core.strength === 'hard' ? 'deny' : 'none', reason: `hook ${hook} failed: ${e.message}${core.strength === 'hard' ? ' — a required protection that cannot run blocks instead of passing' : ''}`, state: 'error' };
  }
  return finish(adapter, event, outcome, hook);
}

function finish(adapter, event, outcome, hook) {
  const response = adapter.respond(outcome, event);
  const state = outcome.state ?? (response.delivered ? 'active' : 'unsupported');
  let stderr = response.stderr;
  if (state !== 'active' && outcome.decision !== 'deny') stderr += `hook-runner[${hook}]: ${state}${outcome.reason ? ` — ${outcome.reason}` : ''}\n`;
  return { ...response, stderr, state, outcome, event };
}

async function main() {
  const { opts } = parseArgv(process.argv.slice(2));
  const host = requireOpt(opts, 'host');
  const hook = requireOpt(opts, 'hook');
  if (opts.ack) {
    const core = await loadCore(hook);
    if (!core.acknowledge) throw new Error(`${hook} has no acknowledgement step`);
    const projectRoot = opts['project-root'] ? path.resolve(opts['project-root']) : process.cwd();
    // The acknowledgement honours the same project configuration the guard reads (child policy, state dir).
    const config = resolveHookConfig(projectRoot);
    if (!config.ok) throw new Error(`hook configuration conflict: ${config.errors.join('; ')}`);
    const res = core.acknowledge({ projectRoot, host, domain: requireOpt(opts, 'domain'), session: opts.session ?? process.env.CLAUDE_CODE_SESSION_ID ?? null, agent: opts.agent ?? null, executor: opts.executor ?? process.env.HARNESS_EXECUTOR_ID ?? null, stateDir: config.values.state_dir, childPolicy: config.values.codex_child_identity ?? 'required' });
    console.log(JSON.stringify(res, null, 2));
    process.exit(res.ok ? 0 : 1);
  }
  let payload = {};
  try { payload = JSON.parse(fs.readFileSync(0, 'utf8') || '{}'); } catch (e) {
    // The host always sends JSON; anything else means a required guard cannot see the call.
    if (HARD_HOOKS.has(hook)) { console.error(`BLOCKED: hook-runner could not parse the hook payload (${e.message}) — the ${hook} guard cannot inspect this call and blocks instead of passing`); process.exit(2); }
    payload = {};
  }
  const res = await runHook({ host, hook, payload });
  if (res.stdout) process.stdout.write(res.stdout);
  if (res.stderr) process.stderr.write(res.stderr);
  process.exit(res.exit);
}

if (process.argv[1] && fileURLToPath(import.meta.url) === realpathOrSelf(process.argv[1])) {
  main().catch((err) => {
    // Whatever failed outside runHook (argv, stdin): a required protection still blocks.
    const hook = (process.argv.join(' ').match(/--hook (\S+)/) ?? [])[1];
    const hard = HARD_HOOKS.has(hook);
    console.error(`${hard ? 'BLOCKED: ' : ''}hook-runner: ${err.message}${hard ? ' — a required protection that cannot run blocks instead of passing' : ''}`);
    process.exit(hard ? 2 : 0);
  });
}
