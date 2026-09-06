// Filesystem helpers with the containment rules from contract 2: resolve symlinks before any
// containment check, never follow a symlink out of the destination, POSIX-relative paths only.
import fs from 'node:fs';
import path from 'node:path';

export function toPosix(p) {
  return p.split(path.sep).join('/');
}

export function realpathOrSelf(p) {
  try {
    return fs.realpathSync.native(p);
  } catch {
    return path.resolve(p);
  }
}

// True when `target` (after symlink resolution) lives inside `root` (also resolved).
export function isInside(root, target) {
  const r = realpathOrSelf(root);
  const t = realpathOrSelf(target);
  const rel = path.relative(r, t);
  return rel === '' || (!rel.startsWith('..') && !path.isAbsolute(rel));
}

export function assertInside(root, target, what = 'path') {
  if (!isInside(root, target)) {
    throw new Error(`${what} escapes ${root}: ${target}`);
  }
}

export function readJson(file) {
  return JSON.parse(fs.readFileSync(file, 'utf8'));
}

export function writeJson(file, value) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, `${JSON.stringify(value, null, 2)}\n`);
}

export function writeBytes(file, bytes) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, bytes);
}

// Recursive listing of regular files as POSIX paths relative to `root`. Symlinks are reported
// separately so callers can refuse them instead of silently following them.
const DEFAULT_IGNORE = /(^|\/)\.DS_Store$/;

export function listFiles(root, { ignore = (rel) => DEFAULT_IGNORE.test(rel) } = {}) {
  const files = [];
  const symlinks = [];
  const walk = (dir) => {
    for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
      const abs = path.join(dir, entry.name);
      const rel = toPosix(path.relative(root, abs));
      if (ignore(rel)) continue;
      if (entry.isSymbolicLink()) symlinks.push(rel);
      else if (entry.isDirectory()) walk(abs);
      else if (entry.isFile()) files.push(rel);
    }
  };
  if (fs.existsSync(root)) walk(root);
  files.sort();
  return { files, symlinks };
}

export function exists(p) {
  return fs.existsSync(p);
}

export function isDir(p) {
  try {
    return fs.statSync(p).isDirectory();
  } catch {
    return false;
  }
}
