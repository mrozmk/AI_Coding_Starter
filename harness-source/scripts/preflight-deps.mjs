#!/usr/bin/env node
// Shared dependency preflight (T12): what the harness itself needs (node ≥ 22, git) and what the
// ported hooks need per host, plus a configured delegation to the project's own
// check-project-deps.sh — run unchanged with the project root as cwd, its stdout relayed, nothing
// from it parsed or exported. Never installs, never reads .env, never touches accounts.
//
//   node scripts/preflight-deps.mjs --project-root <dir> [--host claude|codex]
import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { parseArgv, requireOpt } from './lib/argv.mjs';
import { isInside, realpathOrSelf } from './lib/fsx.mjs';
import { resolveHookConfig } from './lib/hook-config.mjs';

export const MIN_NODE = 22;

function onPath(cmd, envPath = process.env.PATH ?? '') {
  for (const dir of envPath.split(path.delimiter)) {
    if (!dir) continue;
    try { fs.accessSync(path.join(dir, cmd), fs.constants.X_OK); return path.join(dir, cmd); } catch { /* next */ }
  }
  return null;
}

export function dependencyPreflight({ projectRoot, host = null, env = process.env, runProjectScript = true }) {
  const root = path.resolve(projectRoot);
  const checks = [];
  const major = Number(process.versions.node.split('.')[0]);
  checks.push({ name: 'node', required: true, ok: major >= MIN_NODE, detail: `node ${process.versions.node} (need ≥ ${MIN_NODE})` });
  const git = onPath('git', env.PATH);
  checks.push({ name: 'git', required: true, ok: Boolean(git), detail: git ? git : 'git not on PATH — commit/push guards and provenance cannot run; that is missing protection, not a pass' });
  const jq = onPath('jq', env.PATH);
  checks.push({ name: 'jq', required: false, ok: Boolean(jq), detail: jq ? `${jq} (legacy .claude/hooks only)` : 'jq not on PATH — legacy Bash hooks fail open; the ported Node hooks do not need it' });
  if (host) {
    const cli = onPath(host, env.PATH);
    checks.push({ name: `${host}-cli`, required: false, ok: Boolean(cli), detail: cli ?? `${host} CLI not on PATH` });
  }
  const config = resolveHookConfig(root);
  const projectScript = config.ok ? config.values.project_preflight : '.claude/hooks/check-project-deps.sh';
  let project = { configured: projectScript, ran: false, output: '', exit: null };
  if (projectScript) {
    const abs = path.resolve(root, projectScript);
    if (!fs.existsSync(abs)) project.error = `${projectScript} not present (nothing project-specific checked)`;
    else if (!isInside(root, abs)) project.error = 'project_preflight escapes the project root — refused';
    else if (runProjectScript) {
      const r = spawnSync('bash', [abs], { cwd: root, encoding: 'utf8', input: '{}', timeout: 20_000, env: { ...env, CLAUDE_PROJECT_DIR: root, HARNESS_PROJECT_ROOT: root } });
      project = { configured: projectScript, ran: true, output: (r.stdout ?? '').trim(), exit: r.status };
    }
  }
  return { host, checks, project, ok: checks.filter((c) => c.required).every((c) => c.ok) };
}

function main() {
  const { opts } = parseArgv(process.argv.slice(2));
  const res = dependencyPreflight({ projectRoot: requireOpt(opts, 'project-root'), host: opts.host ?? null });
  console.log(JSON.stringify(res, null, 2));
  process.exit(res.ok ? 0 : 3);
}

if (process.argv[1] && fileURLToPath(import.meta.url) === realpathOrSelf(process.argv[1])) {
  try {
    main();
  } catch (err) {
    console.error(`preflight-deps: ${err.message}`);
    process.exit(1);
  }
}
