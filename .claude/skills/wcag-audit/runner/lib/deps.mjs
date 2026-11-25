// deps.mjs — the pinned engine cache: key, lookup, readiness and lazy loading. Nothing here imports
// playwright-core or pngjs at module load, so the unit tests run without the cache.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import crypto from 'node:crypto';
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';
import { Refusal } from './paths.mjs';

export const SKILL_DIR = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..');
export const MIN_NODE = [22, 12];
const CHROME_PATHS = ['/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'];

// Byte order must match install.sh: lock bytes, then "platform|arch|node major".
export function cacheKey(lockBytes, { platform = process.platform, arch = process.arch, nodeMajor = process.versions.node.split('.')[0] } = {}) {
  return crypto.createHash('sha256').update(lockBytes).update(`${platform}|${arch}|${nodeMajor}`).digest('hex').slice(0, 24);
}

export function cacheRoot(env = process.env) {
  return env.WCAG_AUDIT_CACHE || path.join(os.userInfo().homedir, '.cache', 'wcag-audit');
}

export function nodeOk(version = process.versions.node) {
  const [maj, min] = version.split('.').map(Number);
  return maj > MIN_NODE[0] || (maj === MIN_NODE[0] && min >= MIN_NODE[1]);
}

export function lockBytes(skillDir = SKILL_DIR) {
  return fs.readFileSync(path.join(skillDir, 'package-lock.json'));
}

// absent: no cache root or no ready.json anywhere under it (the suite skips the browser step);
// broken:<why>: something is installed but unusable for this lock; ready: usable. Every non-ready
// result carries its refusal code.
export function classifyInstall({ root = cacheRoot(), skillDir = SKILL_DIR, nodeVersion = process.versions.node } = {}) {
  let entries = [];
  try { entries = fs.readdirSync(root); } catch { return { install: 'absent', refusal: 'cache-absent' }; }
  const readyDirs = entries.filter((e) => fs.existsSync(path.join(root, e, 'ready.json')));
  if (!readyDirs.length) return { install: 'absent', refusal: 'cache-absent' };
  let key;
  try { key = cacheKey(lockBytes(skillDir), { nodeMajor: nodeVersion.split('.')[0] }); } catch { return { install: 'broken', refusal: 'cache-broken', reason: 'package-lock.json unreadable' }; }
  const dir = path.join(root, key);
  if (!readyDirs.includes(key)) return { install: 'broken', refusal: 'cache-key-mismatch', reason: 'cache-key-mismatch', dir };
  let ready;
  try { ready = JSON.parse(fs.readFileSync(path.join(dir, 'ready.json'), 'utf8')); } catch { return { install: 'broken', refusal: 'cache-broken', reason: 'ready.json unreadable', dir }; }
  if (ready.key !== key) return { install: 'broken', refusal: 'cache-key-mismatch', reason: 'cache-key-mismatch', dir };
  for (const mod of ['playwright-core', 'axe-core', '@axe-core/playwright', 'pngjs']) {
    if (!fs.existsSync(path.join(dir, 'node_modules', mod, 'package.json'))) return { install: 'broken', refusal: 'cache-broken', reason: `module missing: ${mod}`, dir };
  }
  return { install: 'ready', dir, key };
}

export function assertReady(opts = {}) {
  const nodeVersion = opts.nodeVersion ?? process.versions.node;
  if (!nodeOk(nodeVersion)) throw new Refusal('node-too-old', `node ${nodeVersion} is too old — /wcag-audit needs >= ${MIN_NODE.join('.')}`);
  const st = classifyInstall({ ...opts, nodeVersion });
  if (st.install !== 'ready') throw new Refusal(st.refusal, `${st.reason ?? 'engine cache not installed'} — run: bash .claude/skills/wcag-audit/install.sh`);
  return st;
}

export function browserChoice(dir, env = process.env) {
  if (CHROME_PATHS.some((p) => fs.existsSync(p))) return { channel: 'chrome' };
  for (const bin of ['google-chrome', 'google-chrome-stable']) {
    for (const d of String(env.PATH || '').split(path.delimiter)) {
      if (d && fs.existsSync(path.join(d, bin))) return { channel: 'chrome' };
    }
  }
  const browsers = path.join(dir, 'browsers');
  try {
    if (fs.readdirSync(browsers).some((e) => e.startsWith('chromium'))) return { channel: undefined };
  } catch { /* none bundled */ }
  throw new Refusal('browser-absent', 'no Google Chrome and no bundled Chromium — install Chrome or run: bash .claude/skills/wcag-audit/install.sh --with-chromium');
}

let loaded = null;
export function load(opts = {}) {
  if (loaded) return loaded;
  const st = assertReady(opts);
  const browsers = path.join(st.dir, 'browsers');
  // Must be set before playwright-core is required: it reads the path at load.
  if (fs.existsSync(browsers)) process.env.PLAYWRIGHT_BROWSERS_PATH = browsers;
  const req = createRequire(path.join(st.dir, 'node_modules', 'noop.js'));
  loaded = {
    dir: st.dir,
    playwright: req('playwright-core'),
    AxeBuilder: req('@axe-core/playwright').default ?? req('@axe-core/playwright').AxeBuilder,
    axe: req('axe-core'),
    PNG: req('pngjs').PNG,
    versions: {
      playwright: req('playwright-core/package.json').version,
      axe: req('axe-core/package.json').version,
    },
  };
  return loaded;
}
