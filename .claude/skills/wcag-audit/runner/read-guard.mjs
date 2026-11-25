#!/usr/bin/env node
// read-guard.mjs — the @wcag-judge PreToolUse hook. Allows a Read only when the path's realpath is in
// the active pack manifest; denies everything else (symlinks, traversal, no open pack). Fails closed.
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { spawnSync } from 'node:child_process';

const DENY_MSG = 'read-guard: path outside the wcag-audit pack manifest';
const hash = (t) => crypto.createHash('sha256').update(String(t)).digest('hex');

function deny(log) {
  if (log) log('deny');
  process.stderr.write(`${DENY_MSG}\n`);
  process.exit(2);
}

function projectRoot(input) {
  const start = process.env.CLAUDE_PROJECT_DIR || input.cwd || process.cwd();
  const r = spawnSync('git', ['rev-parse', '--show-toplevel'], { cwd: start, encoding: 'utf8' });
  return r.status === 0 ? r.stdout.trim() : start;
}

// Every existing component of the path is lstat-ed; a symlink anywhere denies.
function hasSymlink(abs) {
  const parts = abs.split(path.sep).filter(Boolean);
  let cur = path.sep;
  for (const p of parts) {
    cur = path.join(cur, p);
    let st;
    try { st = fs.lstatSync(cur); } catch { return null; }
    if (st.isSymbolicLink()) return true;
  }
  return false;
}

function main() {
  let input;
  try { input = JSON.parse(fs.readFileSync(0, 'utf8') || '{}'); } catch { return deny(null); }
  if (input.tool_name !== 'Read') process.exit(0);
  let manifest;
  let log = null;
  try {
    const root = fs.realpathSync(projectRoot(input));
    const lock = path.join(root, '.agents', 'handoffs', '.wcag-model-lock');
    manifest = JSON.parse(fs.readFileSync(path.join(lock, 'manifest.json'), 'utf8'));
    const holder = JSON.parse(fs.readFileSync(path.join(lock, 'lock.json'), 'utf8'));
    const work = manifest.work;
    // One open pack per repository: a manifest that is not the lock holder's is a stale second pack.
    if (holder.work !== work || holder.nonce !== manifest.nonce) return deny(null);
    log = (decision, p) => {
      try { fs.appendFileSync(path.join(work, 'read-guard.log'), `${JSON.stringify({ at: new Date().toISOString(), nonce: manifest.nonce, decision, path_hash: hash(p ?? '') })}\n`); } catch { /* fail closed below */ }
    };
  } catch { return deny(null); }
  const requested = input.tool_input && typeof input.tool_input.file_path === 'string' ? input.tool_input.file_path : '';
  if (!requested || !path.isAbsolute(requested) || requested.split(/[\\/]/).includes('..')) return deny((d) => log(d, requested));
  const abs = path.resolve(requested);
  const sym = hasSymlink(abs);
  let real;
  try { real = fs.realpathSync(abs); } catch { return deny((d) => log(d, abs)); }
  if (sym !== false) return deny((d) => log(d, real));
  const allowed = Array.isArray(manifest.allowed) ? manifest.allowed : [];
  if (!allowed.includes(real)) return deny((d) => log(d, real));
  log('allow', real);
  process.exit(0);
}

try { main(); } catch { process.stderr.write(`${DENY_MSG}\n`); process.exit(2); }
