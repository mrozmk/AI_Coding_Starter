#!/usr/bin/env node
// Content-sensitive snapshot of a working tree around a write-enabled child, and the comparison of
// two snapshots. Port of the legacy git-baseline shell script with one addition the shell could
// not express: a per-path hash of every dirty file, so "what changed DURING this run" is derivable
// from the pair of snapshots instead of from a final `git status` that cannot tell pre-existing dirt
// from the child's writes.
//
//   node scripts/git-baseline.mjs snapshot <dir> [--repo-root <dir>]
//   node scripts/git-baseline.mjs compare <before> <after>
// Exit 0 clean · 1 deviation(s) · 2 precondition failure. JSON on stdout in every case.
//
// Coverage, stated so it is never assumed: tracked files, untracked non-ignored files and the
// sensitive subset of ignored files are hashed. Ordinary ignored build/cache output is listed but
// not hashed — a child overwriting node_modules/ is not a deviation.
import fs from 'node:fs';
import path from 'node:path';
import { createHash } from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { parseArgv } from './lib/argv.mjs';
import { realpathOrSelf, toPosix } from './lib/fsx.mjs';

// Keep in sync with the push guard's FILE_RE — the repo's one other "secret-looking by name" list.
export const SENSITIVE_RE = /(^|\/)\.env|\.pem$|\.key$|\.p12$|\.pfx$|\.keystore$|\.jks$|\.ppk$|(^|\/)id_(rsa|dsa|ecdsa|ed25519)|(^|\/)\.(npmrc|pypirc|netrc|htpasswd)$|(^|\/)\.aws\/credentials$|kubeconfig|\.tfstate|\.tfvars$|credential|secret|service-account[^/]*\.json$|user-profile\.md$/i;
// Ignored harness files (settings.local.json, hooks state) are invisible to `git status` yet can
// weaken permissions — hashed like secrets. Telemetry that the host's own hooks append to between
// the two snapshots, and worktree checkouts, are excluded or every run would deviate.
export const PROTECTED_RE = /^(\.claude|\.agents)\//;
export const TELEMETRY_RE = /^\.claude\/(audit\.log|memory-usage\.json|scheduled_tasks\.lock|worktrees\/)|(^|\/)\.DS_Store$/i;
// Vendored/cache trees churn on every install or test run — excluded from the sensitive scan
// (a vendored "credentials.js" is not a secret); their disappearance is still a deviation.
export const CACHE_RE = /(^|\/)(node_modules|\.venv|venv|vendor|__pycache__|\.pytest_cache|\.mypy_cache|\.ruff_cache|coverage|dist|build|\.next|\.turbo|target)\//i;

export class BaselineError extends Error {
  constructor(message, code = 'precondition') {
    super(message);
    this.name = 'BaselineError';
    this.code = code;
  }
}

const FILES = ['meta.json', 'ignored.json', 'sensitive.json', 'dirty.json', 'protected_dirty.json'];

function sha256File(abs) {
  return createHash('sha256').update(fs.readFileSync(abs)).digest('hex');
}

function sha256Text(text) {
  return createHash('sha256').update(text).digest('hex');
}

// Every git call goes through here so a failure is a precondition error, never a silent empty value
// that would make the comparison pass vacuously.
function gitOut(git, repoRoot, args, { allowEmpty = true, buffer = false } = {}) {
  const r = git('git', ['-c', 'core.hooksPath=/dev/null', ...args], { cwd: repoRoot, encoding: buffer ? 'buffer' : 'utf8', maxBuffer: 64 * 1024 * 1024 });
  if (r.error) throw new BaselineError(`git ${args[0]} failed: ${r.error.message}`);
  if (r.status !== 0) throw new BaselineError(`git ${args.join(' ')} exited ${r.status}: ${String(r.stderr ?? '').trim().slice(0, 200)}`);
  const out = buffer ? r.stdout : String(r.stdout ?? '');
  if (!allowEmpty && (buffer ? out.length === 0 : out.trim() === '')) throw new BaselineError(`git ${args.join(' ')} returned nothing`);
  return out;
}

function splitZ(buf) {
  return buf.toString('utf8').split('\0').filter((s) => s !== '');
}

// One tree entry, by lstat: a symlink is recorded by its target and never followed, a directory by
// its type, a vanished path by an explicit absence. All three must compare unequal to a file.
function entryFor(repoRoot, rel) {
  const abs = path.join(repoRoot, rel);
  let st;
  try { st = fs.lstatSync(abs); } catch { return { type: 'absent', sha256: null, target: null }; }
  if (st.isSymbolicLink()) return { type: 'symlink', sha256: null, target: toPosix(fs.readlinkSync(abs)) };
  if (st.isDirectory()) return { type: 'dir', sha256: null, target: null };
  if (!st.isFile()) return { type: 'other', sha256: null, target: null };
  try { return { type: 'file', sha256: sha256File(abs), target: null }; } catch (e) { throw new BaselineError(`cannot hash ${rel}: ${e.message}`); }
}

// `git status --porcelain=v1 -z`: fields are NUL-separated and a rename/copy entry is followed by a
// second field carrying the source path.
function parseStatusZ(buf, repoRoot) {
  const fields = splitZ(buf);
  const dirty = {};
  for (let i = 0; i < fields.length; i++) {
    const line = fields[i];
    const status = line.slice(0, 2);
    const rel = toPosix(line.slice(3));
    let renamedFrom = null;
    if (status[0] === 'R' || status[0] === 'C' || status[1] === 'R' || status[1] === 'C') {
      renamedFrom = toPosix(fields[++i] ?? '');
      dirty[renamedFrom] = { status, renamed_from: null, rename_to: rel, ...entryFor(repoRoot, renamedFrom) };
    }
    dirty[rel] = { status, renamed_from: renamedFrom, rename_to: null, ...entryFor(repoRoot, rel) };
  }
  return dirty;
}

export function snapshot(dir, { repoRoot = process.cwd(), git = spawnSync } = {}) {
  const root = path.resolve(repoRoot);
  const inside = git('git', ['rev-parse', '--is-inside-work-tree'], { cwd: root, encoding: 'utf8' });
  if (inside.error || inside.status !== 0 || !/true/.test(String(inside.stdout ?? ''))) throw new BaselineError(`not a git repository: ${root}`);
  // In a linked worktree `.git` is a file; the local config lives in the common dir.
  const cfgRel = gitOut(git, root, ['rev-parse', '--git-path', 'config']).trim();
  const cfgAbs = path.isAbsolute(cfgRel) ? cfgRel : path.join(root, cfgRel);
  if (!cfgRel || !fs.existsSync(cfgAbs)) throw new BaselineError('cannot resolve the git config path');
  const head = gitOut(git, root, ['rev-parse', 'HEAD'], { allowEmpty: false }).trim();
  // An empty index would blank the hash in both snapshots and pass vacuously.
  const index = gitOut(git, root, ['ls-files', '-s'], { allowEmpty: false });

  const meta = {
    head,
    branch: gitOut(git, root, ['branch', '--show-current']).trim(),
    stash: gitOut(git, root, ['stash', 'list', '--format=%H']).split('\n').filter(Boolean),
    refs: gitOut(git, root, ['for-each-ref', '--format=%(refname) %(objectname)']).split('\n').filter(Boolean).sort(),
    index_sha256: sha256Text(index),
    config_sha256: sha256File(cfgAbs),
  };

  const ignored = splitZ(gitOut(git, root, ['ls-files', '-o', '-i', '--exclude-standard', '-z'], { buffer: true })).map(toPosix).sort();
  const sensitive = {};
  for (const rel of ignored) {
    if (CACHE_RE.test(rel) || TELEMETRY_RE.test(rel)) continue;
    if (!SENSITIVE_RE.test(rel) && !PROTECTED_RE.test(rel)) continue;
    sensitive[rel] = entryFor(root, rel);
  }

  const dirty = parseStatusZ(gitOut(git, root, ['status', '--porcelain=v1', '-z', '--untracked-files=all'], { buffer: true }), root);
  const protectedDirty = Object.fromEntries(Object.entries(dirty).filter(([rel]) => PROTECTED_RE.test(rel)));

  fs.mkdirSync(dir, { recursive: true });
  const payload = { 'meta.json': meta, 'ignored.json': ignored, 'sensitive.json': sensitive, 'dirty.json': dirty, 'protected_dirty.json': protectedDirty };
  for (const [name, value] of Object.entries(payload)) fs.writeFileSync(path.join(dir, name), `${JSON.stringify(value, null, 2)}\n`);
  return { dir, repoRoot: root, ...payload };
}

function readSnapshot(dir) {
  const out = {};
  for (const name of FILES) {
    const abs = path.join(dir, name);
    if (!fs.existsSync(abs)) throw new BaselineError(`no snapshot in ${dir} — ${name} is missing; run snapshot first`);
    out[name] = JSON.parse(fs.readFileSync(abs, 'utf8'));
  }
  return out;
}

// Paths whose dirty-entry differs between the snapshots: appeared, vanished, changed content,
// changed type, changed symlink target, or changed rename endpoint. A path dirty in BOTH snapshots
// with an identical entry is pre-existing dirt the child never touched — it is not in the delta.
export function deltaOf(before, after) {
  const keys = new Set([...Object.keys(before), ...Object.keys(after)]);
  const delta = [];
  for (const k of keys) {
    if (JSON.stringify(before[k] ?? null) !== JSON.stringify(after[k] ?? null)) delta.push(k);
  }
  return delta.sort();
}

export function compare(beforeDir, afterDir) {
  const b = readSnapshot(beforeDir);
  const a = readSnapshot(afterDir);
  const deviations = [];
  const info = [];

  if (JSON.stringify(b['meta.json']) !== JSON.stringify(a['meta.json'])) {
    deviations.push('git metadata changed (HEAD / branch / stash / refs / index / .git/config)');
  }
  if (JSON.stringify(b['sensitive.json']) !== JSON.stringify(a['sensitive.json'])) {
    deviations.push('a secret-looking or ignored harness file changed or vanished — never restore a secret yourself');
  }
  const beforeIgnored = new Set(b['ignored.json']);
  const afterIgnored = new Set(a['ignored.json']);
  const removed = b['ignored.json'].filter((p) => !afterIgnored.has(p));
  const added = a['ignored.json'].filter((p) => !beforeIgnored.has(p));
  if (removed.length) deviations.push(`ignored files removed (git clean?): ${removed.join(', ')}`);
  const addedProtected = added.filter((p) => PROTECTED_RE.test(p) && !TELEMETRY_RE.test(p));
  if (addedProtected.length) deviations.push(`new ignored files under .agents/ or .claude/: ${addedProtected.join(', ')}`);
  if (added.length) info.push(`${added.length} new ignored files (validation artifacts are expected): ${added.slice(0, 20).join(', ')}`);

  const delta = deltaOf(b['dirty.json'], a['dirty.json']);
  const protectedDelta = delta.filter((p) => PROTECTED_RE.test(p));
  if (protectedDelta.length) deviations.push(`writes under .agents/ or .claude/: ${protectedDelta.join(', ')}`);

  return { status: deviations.length ? 'deviation' : 'ok', deviations, delta, info };
}

function main() {
  const { opts, positionals } = parseArgv(process.argv.slice(2));
  const [command, ...rest] = positionals;
  try {
    if (command === 'snapshot') {
      if (!rest[0]) throw new BaselineError('usage: git-baseline.mjs snapshot <dir> [--repo-root <dir>]');
      const snap = snapshot(path.resolve(rest[0]), { repoRoot: opts['repo-root'] ?? process.cwd() });
      console.log(JSON.stringify({ status: 'ok', dir: snap.dir, dirty: Object.keys(snap['dirty.json']).length, ignored: snap['ignored.json'].length }, null, 2));
      process.exit(0);
    }
    if (command === 'compare') {
      if (!rest[0] || !rest[1]) throw new BaselineError('usage: git-baseline.mjs compare <before> <after>');
      const result = compare(path.resolve(rest[0]), path.resolve(rest[1]));
      console.log(JSON.stringify(result, null, 2));
      for (const d of result.deviations) console.error(`DEVIATION: ${d}`);
      if (result.status === 'ok') console.error('BASELINE OK — no forbidden change');
      process.exit(result.status === 'ok' ? 0 : 1);
    }
    throw new BaselineError('usage: git-baseline.mjs snapshot <dir> [--repo-root <dir>] | compare <before> <after>');
  } catch (err) {
    console.log(JSON.stringify({ status: 'precondition-failed', error: err.message }, null, 2));
    console.error(`git-baseline: ${err.message}`);
    process.exit(2);
  }
}

if (process.argv[1] && fileURLToPath(import.meta.url) === realpathOrSelf(process.argv[1])) main();
