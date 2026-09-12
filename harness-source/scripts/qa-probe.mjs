#!/usr/bin/env node
// QA environment preflight — the single probe runner behind prime-qa and qa-verify.
//
//   node scripts/qa-probe.mjs [--project-root <dir>]
//
// WHY A SCRIPT AND NOT INLINE PROBES: the probes must run before the model reasons about the
// environment — every defect this preflight exists to catch is of the form "the model did not run
// the check at the right moment". Inlining raw network calls instead forces a permission rule broad
// enough to reach ANY host (permission globs are trailing-only, so the host cannot be constrained).
//
// WHY IT TAKES NO TARGET: the legacy allow rule was the exact-match, argument-free
// `Bash(bash .claude/lib/qa-probe.sh)`, so untrusted issue text read by qa-verify could never steer
// the probe at an arbitrary host. The plugin allowance is a *prefix* rule over every plugin script,
// which means argv handling is now the only thing preserving that property. The session root the
// host exports is the sole authority for which qa-env.json supplies every host, path and command;
// `--project-root` is accepted for calling convention but is a cross-check only, and there is no
// cwd fallback — cwd is model-controlled and persists between calls, so a cwd-derived check agrees
// with a foreign root by construction whenever the call is made from that directory.
//
// CONTRACT: emit `key: value` lines on stdout and exit 0 once the argv gate has passed. Print
// nothing secret — a credentials file is stat-ed (size + mtime), never read. Every network call
// carries an explicit timeout: a command whose job is detecting a blocked environment must never
// itself block.
import fs from 'node:fs';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { parseArgv } from './lib/argv.mjs';
import { readJson, realpathOrSelf } from './lib/fsx.mjs';

// The session-root variables this harness recognises. Claude Code exports the first; the second is
// the host-neutral spelling used by the hook runner, and is the only way a Codex session supplies a
// root — Codex documents no project-root variable of its own (adapters/codex-cli/adapter.json).
export const SESSION_ROOT_ENV = ['CLAUDE_PROJECT_DIR', 'HARNESS_PROJECT_ROOT'];

export function resolveSessionRoot({ env = process.env, projectRootOpt = null } = {}) {
  const named = SESSION_ROOT_ENV.map((k) => env[k]).find((v) => typeof v === 'string' && v.length > 0);
  if (!named) throw new Error(`qa-probe needs a host session root (${SESSION_ROOT_ENV.join(' or ')}); it never falls back to the working directory`);
  const root = path.resolve(named);
  if (projectRootOpt !== null) {
    if (realpathOrSelf(path.resolve(projectRootOpt)) !== realpathOrSelf(root)) {
      throw new Error('qa-probe refuses a project root other than the session root');
    }
  }
  return root;
}

// `--project-root <dir>` is the only accepted option and only as a cross-check; anything else —
// a positional, a host, a URL — is refused before a single configuration value is read.
export function gateArgv(argv) {
  const { opts, positionals } = parseArgv(argv);
  const extra = Object.keys(opts).filter((k) => k !== 'project-root');
  if (positionals.length > 0 || extra.length > 0) throw new Error('qa-probe takes no target arguments');
  const value = opts['project-root'];
  if (value === undefined) return null;
  if (value === true || Array.isArray(value)) throw new Error('qa-probe takes no target arguments');
  return value;
}

function httpProbe(url, { timeoutMs }) {
  const started = performance.now();
  return fetch(url, { signal: AbortSignal.timeout(timeoutMs), redirect: 'manual' })
    .then((res) => ({ code: String(res.status), seconds: (performance.now() - started) / 1000 }))
    .catch(() => ({ code: '000', seconds: (performance.now() - started) / 1000 }));
}

function fetchText(url, { timeoutMs }) {
  return fetch(url, { signal: AbortSignal.timeout(timeoutMs) }).then((res) => res.text()).catch(() => '');
}

function git(root, args) {
  try {
    return execFileSync('git', ['-C', root, ...args], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }).trim();
  } catch {
    return '';
  }
}

function gitIgnored(root, target) {
  try {
    execFileSync('git', ['-C', root, 'check-ignore', '-q', target], { stdio: 'ignore' });
    return true;
  } catch {
    return false;
  }
}

function countProcesses(pattern) {
  try {
    const out = execFileSync('pgrep', ['-f', pattern], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] });
    return out.split('\n').filter((l) => l.trim()).length;
  } catch {
    return 0;
  }
}

export async function probe({ root, emit }) {
  const configPath = path.join(root, '.claude/qa-env.json');
  if (!fs.existsSync(configPath)) {
    emit('qa-config: MISSING — .claude/qa-env.json not found; no environment facts available');
    return;
  }
  let config;
  try {
    config = readJson(configPath);
  } catch (err) {
    emit(`qa-config: UNREADABLE — ${err.message}`);
    return;
  }
  const cfg = (k) => (config[k] === null || config[k] === undefined ? '' : String(config[k]));
  const list = (k) => (Array.isArray(config[k]) ? config[k] : []);

  const baseUrl = cfg('base_url');
  const localUrl = cfg('local_url');
  const serve = cfg('local_serve_command');
  const serveAlt = cfg('local_serve_command_alt_port');
  const buildShaUrl = cfg('build_sha_url');
  const artifacts = cfg('artifacts_dir');
  const envFile = cfg('env_file');
  const pgrepPattern = cfg('browser_mcp_process_pattern');
  const mcpFile = cfg('mcp_config_file');
  const safeFlag = cfg('parallel_safe_flag');
  const deviceMcp = cfg('device_mcp_server');
  const breakpointPrefix = cfg('breakpoint_token_prefix');

  emit('qa-config: present');

  // --- Deployed host ----------------------------------------------------------
  let deployedOk = true;
  let failReason = '';
  const fail = (reason) => { deployedOk = false; if (!failReason) failReason = reason; };

  if (!baseUrl) {
    deployedOk = false;
    failReason = 'no deployed host configured (qa-env.json -> base_url is empty)';
    emit('deployed-host: not configured');
  } else {
    emit(`deployed-host: ${baseUrl}`);
    const paths = list('probe_paths').filter((p) => typeof p === 'string' && p.length > 0);
    if (paths.length === 0) {
      deployedOk = false;
      failReason = 'no probe_paths configured — an unprobed host is not a verified host';
      emit('probe: SKIPPED — probe_paths is empty');
    }
    for (const p of paths) {
      const { code, seconds } = await httpProbe(`${baseUrl.replace(/\/$/, '')}${p}`, { timeoutMs: 10_000 });
      if (code === '000') {
        emit(`probe ${p}: UNREACHABLE (timeout or connection refused)`);
        fail(`deployed probe ${p} unreachable`);
      } else {
        emit(`probe ${p}: ${code} in ${seconds.toFixed(6)}s`);
        if (!/^[23]/.test(code)) fail(`deployed probe ${p} returned ${code}`);
      }
    }
  }

  // --- Build skew -------------------------------------------------------------
  const headSha = git(root, ['rev-parse', '--short', 'HEAD']);
  if (headSha) emit(`local-HEAD: ${headSha}`);

  let skew = 'not-applicable';
  if (deployedOk) {
    if (!buildShaUrl) {
      skew = 'NOT-VERIFIED — no build_sha_url configured; the deployed build may lag HEAD';
    } else {
      const deployedSha = (await fetchText(buildShaUrl, { timeoutMs: 10_000 })).match(/[0-9a-f]{7,40}/)?.[0] ?? '';
      if (!deployedSha) {
        skew = 'NOT-VERIFIED — build_sha_url returned no recognisable SHA';
      } else if (headSha && (deployedSha.startsWith(headSha) || headSha.startsWith(deployedSha))) {
        skew = `matched (${deployedSha})`;
      } else {
        skew = `MISMATCH — deployed ${deployedSha} != local ${headSha}`;
        deployedOk = false;
        failReason = `deployed build SHA ${deployedSha} does not match local HEAD ${headSha}`;
      }
    }
  }
  emit(`build-skew: ${skew}`);

  // --- Local fallback ---------------------------------------------------------
  if (localUrl) {
    const { code } = await httpProbe(localUrl, { timeoutMs: 5_000 });
    emit(code === '000' ? `local-host: ${localUrl} — down (not serving)` : `local-host: ${localUrl} — ${code}`);
  } else {
    emit('local-host: not configured');
  }
  if (serve) emit(`local-serve-command: ${serve}`);
  if (serveAlt) emit(`local-serve-command-2nd-session: ${serveAlt}`);

  // --- BASE_URL resolution (deterministic — the model transcribes, does not derive)
  if (deployedOk) {
    emit(`RESOLVED-BASE_URL: ${baseUrl}`);
    emit('RESOLVED-REASON: deployed host reachable on every probe path');
  } else if (localUrl) {
    emit(`RESOLVED-BASE_URL: ${localUrl}`);
    emit(`RESOLVED-REASON: ${failReason}`);
  } else {
    emit('RESOLVED-BASE_URL: (none)');
    emit(`RESOLVED-REASON: ${failReason}, and no local_url configured — QA cannot observe runtime behaviour`);
  }

  // --- Credentials file: presence only, never contents ------------------------
  // Never use ripgrep to test for a credentials file: it honours .gitignore, and the file is
  // gitignored, so it reports a false absence.
  if (envFile) {
    const abs = path.join(root, envFile);
    if (fs.existsSync(abs) && fs.statSync(abs).isFile()) {
      const st = fs.statSync(abs);
      const mt = new Date(st.mtimeMs);
      const pad = (n) => String(n).padStart(2, '0');
      const stamp = `${mt.getFullYear()}-${pad(mt.getMonth() + 1)}-${pad(mt.getDate())} ${pad(mt.getHours())}:${pad(mt.getMinutes())}`;
      emit(`credentials-file ${envFile}: present, ${st.size} bytes, modified ${stamp} (contents never read)`);
    } else {
      emit(`credentials-file ${envFile}: MISSING — tracker-driven QA will soft-fail`);
    }
  }

  // --- Concurrency + parallel safety ------------------------------------------
  if (pgrepPattern) emit(`browser-mcp-servers-running: ${countProcesses(pgrepPattern)} (information, not a gate)`);

  if (mcpFile) {
    const abs = path.join(root, mcpFile);
    if (fs.existsSync(abs) && fs.statSync(abs).isFile()) {
      const text = fs.readFileSync(abs, 'utf8');
      // Only judge the parallel-safe flag when a browser MCP is actually declared — otherwise the
      // warning fires on every project that does no browser QA, and a preflight that always warns
      // is read as noise and then ignored.
      if (!pgrepPattern || !text.includes(pgrepPattern)) emit(`mcp-config ${mcpFile}: present, no browser MCP declared (parallel-safety not applicable)`);
      else if (safeFlag && text.includes(safeFlag)) emit(`mcp-config ${mcpFile}: present, parallel-safe flag "${safeFlag}": yes`);
      else if (safeFlag) emit(`mcp-config ${mcpFile}: present, parallel-safe flag "${safeFlag}": NO — a second concurrent session will collide`);
      else emit(`mcp-config ${mcpFile}: present`);
    } else {
      emit(`mcp-config ${mcpFile}: MISSING`);
    }
  }

  // --- Cross-device lane (information only, never a gate) ---------------------
  // Names and widths the device verifier needs; an empty value is a normal state the router already
  // handles by routing the family to NEEDS-HUMAN.
  emit(`device_mcp_server: ${deviceMcp || 'unset'}`);
  for (const k of ['touch_sweep_widths', 'pointer_sweep_widths']) {
    const n = list(k).length;
    emit(n > 0 ? `${k}: ${n} widths` : `${k}: unset`);
  }
  emit(`breakpoint_token_prefix: ${breakpointPrefix || 'unset'}`);

  // --- Artifacts destination --------------------------------------------------
  if (artifacts) {
    // Probe both spellings: a directory-only rule (`dir/`) matches the path only when git can tell
    // it IS a directory — which it cannot for a path that does not exist yet.
    const ignored = gitIgnored(root, artifacts) || gitIgnored(root, `${artifacts.replace(/\/$/, '')}/`);
    emit(ignored
      ? `artifacts-dir ${artifacts}: gitignored (correct — QA evidence is not repo history)`
      : `artifacts-dir ${artifacts}: NOT gitignored — screenshots would be committable`);
  }
}

async function main() {
  const projectRootOpt = gateArgv(process.argv.slice(2));
  const root = resolveSessionRoot({ projectRootOpt });
  await probe({ root, emit: (line) => process.stdout.write(`${line}\n`) });
}

if (process.argv[1] && fileURLToPath(import.meta.url) === realpathOrSelf(process.argv[1])) {
  main().catch((err) => {
    console.error(err.message);
    process.exit(1);
  });
}
