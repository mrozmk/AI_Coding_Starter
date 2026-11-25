// paths.mjs — containment for everything /wcag-audit reads or writes. The run directory lives under
// the canonical <repo root>/.agents/handoffs/ and nowhere else.
import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';

export class Refusal extends Error {
  constructor(code, hint) {
    super(`${code}: ${hint}`);
    this.code = code;
    this.hint = hint;
  }
}

export const HANDOFF_SETUP = "printf '%s\\n' '.agents/handoffs/*' '!.agents/handoffs/.gitkeep' >> .git/info/exclude";

// Mirrors audit-security/scripts/audit-runner.mjs realpathNearest: realpath of the deepest existing
// ancestor + the rest, so a not-yet-created path under a symlinked tmp still compares correctly.
export function realpathNearest(p) {
  const missing = [];
  let cur = path.resolve(p);
  while (!fs.existsSync(cur)) {
    missing.unshift(path.basename(cur));
    const parent = path.dirname(cur);
    if (parent === cur) break;
    cur = parent;
  }
  return path.join(fs.realpathSync(cur), ...missing);
}

export function isInside(child, parent) {
  const rel = path.relative(path.resolve(parent), path.resolve(child));
  return rel === '' || (!rel.startsWith('..') && !path.isAbsolute(rel));
}

export function repoRoot(cwd = process.cwd()) {
  const r = spawnSync('git', ['rev-parse', '--show-toplevel'], { cwd, encoding: 'utf8' });
  if (r.status !== 0) throw new Refusal('not-a-repo', 'run /wcag-audit inside a git checkout');
  return fs.realpathSync(r.stdout.trim());
}

export function handoffsRoot(cwd = process.cwd()) {
  return path.join(repoRoot(cwd), '.agents', 'handoffs');
}

// wcag-audit-<slug>-<date>[-n] — never overwrites an earlier run of the same day.
export function allocWork(slug, date, cwd = process.cwd()) {
  const root = handoffsRoot(cwd);
  const safe = String(slug || 'site').toLowerCase().replace(/[^a-z0-9-]+/g, '-').replace(/^-+|-+$/g, '').slice(0, 60) || 'site';
  let base = `wcag-audit-${safe}-${date}`;
  for (let n = 2; fs.existsSync(path.join(root, base)) || fs.existsSync(path.join(root, `${base}.html`)); n += 1) {
    base = `wcag-audit-${safe}-${date}-${n}`;
  }
  const dir = path.join(root, base);
  if (!isInside(realpathNearest(dir), realpathNearest(root))) throw new Refusal('out-outside-handoffs', 'the run directory must resolve inside .agents/handoffs/');
  return { root, base, dir };
}

export function assertIgnored(paths, cwd = process.cwd()) {
  for (const p of paths) {
    const r = spawnSync('git', ['check-ignore', '-q', p], { cwd });
    if (r.status !== 0) {
      throw new Refusal('work-not-ignored', `${path.relative(cwd, p) || p} is not git-ignored — add the per-clone handoff exclude first (see .claude/commands/handoff.md): ${HANDOFF_SETUP}`);
    }
  }
}

export function assertInputFile(p, maxBytes = 1024 * 1024) {
  let st;
  try { st = fs.lstatSync(p); } catch { throw new Refusal('bad-input-file', `${p} does not exist`); }
  if (st.isSymbolicLink() || !st.isFile()) throw new Refusal('bad-input-file', `${p} must be a regular file, not a symlink`);
  if (st.size > maxBytes) throw new Refusal('bad-input-file', `${p} is larger than ${maxBytes} bytes`);
  return p;
}

// Called first by pack, ingest and render — before any read or write in the run directory.
export function assertWork(dir, cwd = process.cwd()) {
  if (!dir) throw new Refusal('bad-work-dir', '--work <dir> is required');
  const abs = path.resolve(cwd, dir);
  let st;
  try { st = fs.lstatSync(abs); } catch { throw new Refusal('bad-work-dir', 'the run directory does not exist'); }
  if (st.isSymbolicLink()) throw new Refusal('work-outside-handoffs', 'the run directory must not be a symlink');
  const real = fs.realpathSync(abs);
  const root = fs.realpathSync(handoffsRoot(cwd));
  if (!isInside(real, root) || real === root) throw new Refusal('work-outside-handoffs', 'the run directory must be inside .agents/handoffs/');
  if (!/^wcag-audit-/.test(path.basename(real))) throw new Refusal('bad-work-dir', 'the run directory name must start with wcag-audit-');
  let rs;
  try { rs = fs.lstatSync(path.join(real, 'run.json')); } catch { throw new Refusal('bad-work-dir', 'the run directory holds no run.json'); }
  if (!rs.isFile() || rs.isSymbolicLink()) throw new Refusal('bad-work-dir', 'run.json must be a regular file');
  return real;
}

// A crop referenced from run.json is read only from <work>/evidence/.
export function evidencePath(work, rel) {
  const evidence = path.join(work, 'evidence');
  const p = path.resolve(work, rel);
  if (!isInside(p, evidence)) throw new Refusal('evidence-outside-work', 'a crop path points outside <work>/evidence/');
  let st;
  try { st = fs.lstatSync(p); } catch { return null; }
  if (st.isSymbolicLink() || !st.isFile()) throw new Refusal('evidence-outside-work', 'a crop must be a regular file');
  if (!isInside(fs.realpathSync(p), fs.realpathSync(evidence))) throw new Refusal('evidence-outside-work', 'a crop resolves outside <work>/evidence/');
  return p;
}

// The rendered report sits next to its run directory: <work>.html and <work>.json.
export function reportPaths(work) {
  const base = path.join(path.dirname(work), path.basename(work));
  return { html: `${base}.html`, json: `${base}.json` };
}

export function writeAtomic(file, text) {
  const tmp = `${file}.${process.pid}.tmp`;
  fs.writeFileSync(tmp, text);
  fs.renameSync(tmp, file);
}

export function readRun(work) {
  return JSON.parse(fs.readFileSync(path.join(work, 'run.json'), 'utf8'));
}

export function writeRun(work, run) {
  writeAtomic(path.join(work, 'run.json'), `${JSON.stringify(run, null, 2)}\n`);
}
