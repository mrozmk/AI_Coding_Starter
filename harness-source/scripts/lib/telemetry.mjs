// Local telemetry for the ported hooks (T10): append-only audit lines with bounded retention and a
// JSON sidecar for memory reads. Everything stays on the machine, under the project's state
// directory (or the legacy .claude/ sidecars while the old cleanup reader still expects them).
// Concurrency-safe by a lock file with retry; secret-looking values are redacted before writing.
import fs from 'node:fs';
import path from 'node:path';

export const AUDIT_MAX_LINES = 5000;
export const AUDIT_KEEP_LINES = 2500;
const SECRET_RE = /(-----BEGIN[A-Z ]*PRIVATE KEY-----[\s\S]*?-----END[A-Z ]*PRIVATE KEY-----|AKIA[0-9A-Z]{16}|gh[pousr]_[0-9A-Za-z]{36}|github_pat_[0-9A-Za-z_]{82}|xox[baprs]-[0-9A-Za-z-]{10,}|sk-ant-[0-9A-Za-z_-]{20,}|sk-proj-[0-9A-Za-z_-]{20,}|(?:sk|rk)_live_[0-9A-Za-z]{20,}|eyJ[0-9A-Za-z_-]{8,}\.eyJ[0-9A-Za-z_-]{8,}\.[0-9A-Za-z_-]{8,})/g;
const ASSIGN_RE = /((?:password|passwd|secret|api[_-]?key|token)\s*[:=]\s*)["'][^"']{6,}["']/gi;

export function redact(text) {
  return String(text).replace(SECRET_RE, '<redacted>').replace(ASSIGN_RE, '$1<redacted>');
}

// Sidecar locations: the legacy readers (cleanup-workflow) look under .claude/; keep feeding them
// while the project still has that directory, otherwise use the harness state directory.
export function sidecarPaths(projectRoot, { stateDir = '.agents/harness-state', legacySidecars = true } = {}) {
  const root = path.resolve(projectRoot);
  const legacy = legacySidecars && fs.existsSync(path.join(root, '.claude'));
  return {
    audit: legacy ? path.join(root, '.claude/audit.log') : path.join(root, stateDir, 'audit.log'),
    memoryUsage: legacy ? path.join(root, '.claude/memory-usage.json') : path.join(root, stateDir, 'memory-usage.json'),
    stateDir: path.join(root, stateDir),
    compat: legacy ? 'legacy .claude/ sidecars' : `${stateDir} sidecars`,
  };
}

function withLock(file, fn, { retries = 50, waitMs = 5 } = {}) {
  const lock = `${file}.lock`;
  fs.mkdirSync(path.dirname(file), { recursive: true });
  const until = Date.now() + retries * waitMs * 4;
  for (;;) {
    try {
      const fd = fs.openSync(lock, 'wx');
      try { return fn(); } finally { fs.closeSync(fd); fs.rmSync(lock, { force: true }); }
    } catch (e) {
      if (e.code !== 'EEXIST') throw e;
      if (Date.now() > until) { try { if (Date.now() - fs.statSync(lock).mtimeMs > 10_000) fs.rmSync(lock, { force: true }); } catch { /* gone */ } }
      Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, waitMs);
      if (Date.now() > until + 10_000) throw new Error(`telemetry lock stuck: ${lock}`);
    }
  }
}

function atomicWrite(file, text) {
  const tmp = `${file}.tmp-${process.pid}-${Date.now()}`;
  fs.writeFileSync(tmp, text);
  fs.renameSync(tmp, file);
}

// One audit line: timestamp, phase (ATTEMPT before the tool runs, DONE after), label, redacted value.
export function appendAudit(file, { phase, label, value, now = new Date() }) {
  const ts = now.toISOString().replace('T', ' ').slice(0, 19);
  const line = `[${ts}] ${phase.padEnd(7)} ${label.padEnd(6)} ${redact(value ?? '').replace(/\n/g, ' ').slice(0, 500)}\n`;
  withLock(file, () => {
    fs.appendFileSync(file, line);
    const text = fs.readFileSync(file, 'utf8');
    const lines = text.split('\n');
    if (lines.length - 1 > AUDIT_MAX_LINES) atomicWrite(file, `${lines.slice(-AUDIT_KEEP_LINES - 1).join('\n')}`);
  });
  return line;
}

// Memory read counter: { "<rel under .agents/memory/>": { last_referenced, ref_count } }.
// A malformed or empty sidecar heals to {} instead of poisoning every later update.
export function bumpMemoryReads(file, keys, { today = new Date().toISOString().slice(0, 10) } = {}) {
  if (!keys.length) return null;
  return withLock(file, () => {
    let db = {};
    try { const parsed = JSON.parse(fs.readFileSync(file, 'utf8')); if (parsed && typeof parsed === 'object' && !Array.isArray(parsed)) db = parsed; } catch { db = {}; }
    for (const k of keys) db[k] = { last_referenced: today, ref_count: (db[k]?.ref_count ?? 0) + 1 };
    atomicWrite(file, `${JSON.stringify(db, null, 2)}\n`);
    return db;
  });
}

export function readMemoryUsage(file) {
  try { return JSON.parse(fs.readFileSync(file, 'utf8')); } catch { return null; }
}
