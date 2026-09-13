#!/usr/bin/env node
// Read broker for the hybrid independent reviewer: a dependency-free stdio MCP server the reviewer
// CLI spawns from a per-run MCP config. Three tools (read_file, list_dir, search), two readable
// roots (project, plugin), the shared exclusions, a budget, and a typed, hashed JSONL log — the
// only file this process ever opens for writing. No network, no subprocesses, no other writes.
//
// Environment (all required, set by review-orchestrator.mjs in the MCP config):
//   HARNESS_READER_ROOTS   <projectRoot>:<pluginRoot>  absolute paths, path.delimiter-separated
//   HARNESS_READER_LOG     <run>/reads.jsonl            created exclusively; exists → exit 3
//   HARNESS_READER_BUDGET  files,bytes,calls            e.g. 30,409600,200
//   HARNESS_REVIEW_ID      the run's review id           echoed in the log header
// Request namespace: an unprefixed relative path is project-relative; `plugin:<path>` is
// plugin-relative; an absolute path is accepted only inside one of the roots. Canonical identity
// everywhere (log, evidence_read, re-hash): { root: 'project'|'plugin', path: <posix rel> }.
import fs from 'node:fs';
import path from 'node:path';
import readline from 'node:readline';
import { randomUUID } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { isExcludedRel, isInsideRoot } from './context-pack.mjs';
import { sha256Hex } from './lib/digest.mjs';
import { realpathOrSelf, toPosix } from './lib/fsx.mjs';
import { BROKER_TOOLS, DEFAULT_BUDGETS, MAX_READ_LIMIT, parseBudgetEnv } from './lib/reads.mjs';

const KNOWN_PROTOCOLS = ['2025-11-25', '2025-06-18', '2025-03-26', '2024-11-05'];
const SERVER_NAME = 'harness-reader';
const BINARY_PROBE_BYTES = 8192;
const DEFAULT_SEARCH_MAX = 50;
const MAX_SEARCH_MAX = 200;

export const TOOLS = [
  {
    name: 'read_file',
    description: 'Read a UTF-8 text file under the project root (relative path) or the plugin root (`plugin:<path>`). Returns at most 65536 bytes per call; use offset/limit for more. A second content item carries {root, path, file_bytes, offset, limit, returned_bytes, eof}. Excluded paths, paths outside the roots, binary files and reads beyond the budget are refused with a typed reason.',
    inputSchema: { type: 'object', properties: { path: { type: 'string' }, offset: { type: 'integer', minimum: 0 }, limit: { type: 'integer', minimum: 1, maximum: MAX_READ_LIMIT } }, required: ['path'] },
  },
  {
    name: 'list_dir',
    description: 'List a directory under the project root (relative path, "" or "." for the root) or the plugin root (`plugin:<path>`). Excluded entries are not shown. Returns JSON {root, path, entries: [{name, type}]}.',
    inputSchema: { type: 'object', properties: { path: { type: 'string' } }, required: ['path'] },
  },
  {
    name: 'search',
    description: 'Search text files under both roots for a literal string (or a regular expression with the `re:` prefix), optionally filtered by a glob on the relative path. Every file opened counts toward the file budget; results stop at `max` matches (default 50) or at the budget and say so. Returns JSON {pattern, glob, matches: [{root, path, line, text}], truncated, files_opened}.',
    inputSchema: { type: 'object', properties: { pattern: { type: 'string' }, glob: { type: 'string' }, max: { type: 'integer', minimum: 1, maximum: MAX_SEARCH_MAX } }, required: ['pattern'] },
  },
];

function pluginVersion() {
  try { return JSON.parse(fs.readFileSync(path.join(path.dirname(fileURLToPath(import.meta.url)), '..', 'harness.json'), 'utf8')).version ?? '0'; } catch { return '0'; }
}

// Resolve symlinks on the longest existing ancestor so absent paths still compare against real roots.
function realpathDeep(abs) {
  let dir = abs;
  const tail = [];
  while (!fs.existsSync(dir)) {
    tail.unshift(path.basename(dir));
    const parent = path.dirname(dir);
    if (parent === dir) return abs;
    dir = parent;
  }
  return path.join(realpathOrSelf(dir), ...tail);
}

function looksBinary(buf) {
  const head = buf.subarray(0, BINARY_PROBE_BYTES);
  if (head.includes(0)) return true;
  try { new TextDecoder('utf-8', { fatal: true }).decode(head, { stream: true }); return false; } catch { return true; }
}

function globToRegExp(glob) {
  let re = '';
  for (let i = 0; i < glob.length; i++) {
    const c = glob[i];
    if (c === '*') {
      if (glob[i + 1] === '*') { re += '.*'; i++; if (glob[i + 1] === '/') i++; } else re += '[^/]*';
    } else if (c === '?') re += '[^/]';
    else re += c.replace(/[.+^${}()|[\]\\]/g, '\\$&');
  }
  return new RegExp(`^${re}$`);
}

export class ReaderBroker {
  constructor({ roots, logFile, budgets, reviewId, testHook = null }) {
    this.roots = { project: realpathOrSelf(roots.project), plugin: realpathOrSelf(roots.plugin) };
    this.budgets = budgets;
    this.reviewId = reviewId;
    this.testHook = testHook;
    this.instanceId = randomUUID();
    this.seq = 0;
    this.calls = 0;
    this.denied = 0;
    this.bytes = 0;
    this.files = new Set();
    this.closed = false;
    // Exclusive create: a second broker for the same run finds the log and must not start.
    this.fd = fs.openSync(logFile, 'wx');
    this.append({ type: 'header', review_id: reviewId, instance_id: this.instanceId, roots: this.roots, budgets, started: new Date().toISOString() });
  }

  append(rec) {
    fs.writeSync(this.fd, `${JSON.stringify(rec)}\n`);
  }

  record(rec) {
    this.seq += 1;
    const full = { seq: this.seq, ts: new Date().toISOString(), ...rec };
    this.append(full);
    return full;
  }

  end(extra = {}) {
    if (this.closed) return;
    this.closed = true;
    this.seq += 1;
    this.append({ seq: this.seq, type: 'end', calls: this.calls, denied: this.denied, files: this.files.size, bytes: this.bytes, ...extra });
    fs.closeSync(this.fd);
  }

  fileKey(root, rel) { return `${root}\0${rel}`; }

  // { root, rel, resolved } or { deny: reason }.
  resolve(requested) {
    if (typeof requested !== 'string') return { invalid: 'path must be a string' };
    let root;
    let rel;
    const trimmed = requested.trim();
    if (trimmed.startsWith('plugin:')) { root = 'plugin'; rel = trimmed.slice('plugin:'.length); }
    else if (path.isAbsolute(trimmed)) {
      const resolvedAbs = realpathDeep(trimmed);
      root = ['project', 'plugin'].find((r) => isInsideRoot(this.roots[r], resolvedAbs)) ?? null;
      if (!root) return { deny: 'outside-roots' };
      rel = path.relative(this.roots[root], resolvedAbs);
    } else { root = 'project'; rel = trimmed; }
    if (rel === '.' || rel === './') rel = '';
    const resolved = realpathDeep(path.resolve(this.roots[root], rel));
    if (!isInsideRoot(this.roots[root], resolved)) return { deny: 'outside-roots' };
    const relPosix = toPosix(path.relative(this.roots[root], resolved));
    if (relPosix !== '' && isExcludedRel(relPosix)) return { deny: 'excluded' };
    return { root, rel: relPosix, resolved };
  }

  // `calls` was already incremented for this call: the cap is the number of calls served.
  budgetForCall() {
    return this.calls > this.budgets.calls ? 'budget-exhausted' : null;
  }

  // Charge returned bytes and (for a new file) one file slot; false when the budget is exhausted.
  charge({ root, rel, returnedBytes, countFile = true }) {
    const key = this.fileKey(root, rel);
    const newFile = countFile && !this.files.has(key);
    if (newFile && this.files.size >= this.budgets.files) return false;
    if (this.bytes + returnedBytes > this.budgets.bytes) return false;
    if (newFile) this.files.add(key);
    this.bytes += returnedBytes;
    return true;
  }

  deny(tool, fields, reason) {
    this.denied += 1;
    const rec = this.record({ tool, ...fields, denied: true, reason });
    return { rec, result: { content: [{ type: 'text', text: `denied: ${reason}` }], isError: true } };
  }

  fail(tool, fields, reason) {
    const rec = this.record({ tool, ...fields, error: true, reason });
    return { rec, result: { content: [{ type: 'text', text: `error: ${reason}` }], isError: true } };
  }

  // Validation → O_NOFOLLOW open → fstat identity check → read from the same descriptor.
  openAtomically(resolved) {
    let before;
    try { before = fs.lstatSync(resolved); } catch (e) { return { error: e.code === 'ENOENT' || e.code === 'ENOTDIR' ? 'absent' : 'unreadable' }; }
    if (before.isSymbolicLink()) return { deny: 'replaced' };
    if (before.isDirectory()) return { error: 'not-a-file' };
    if (!before.isFile()) return { error: 'not-a-file' };
    if (this.testHook === 'swap-before-open' && process.env.HARNESS_READER_TEST_SWAP_TARGET) {
      fs.rmSync(resolved);
      fs.symlinkSync(process.env.HARNESS_READER_TEST_SWAP_TARGET, resolved);
    }
    const flags = fs.constants.O_RDONLY | (fs.constants.O_NOFOLLOW ?? 0); // O_NOFOLLOW: macOS/Linux; absent on Windows (unsupported host)
    let fd;
    try { fd = fs.openSync(resolved, flags); } catch (e) {
      if (e.code === 'ELOOP' || e.code === 'EMLINK') return { deny: 'replaced' };
      return { error: e.code === 'ENOENT' ? 'absent' : 'unreadable' };
    }
    try {
      const after = fs.fstatSync(fd);
      if (after.dev !== before.dev || after.ino !== before.ino || !after.isFile()) { fs.closeSync(fd); return { deny: 'replaced' }; }
      const bytes = fs.readFileSync(fd);
      fs.closeSync(fd);
      return { bytes };
    } catch (e) {
      try { fs.closeSync(fd); } catch { /* already closed */ }
      return { error: e.code === 'EACCES' || e.code === 'EIO' || e.code === 'EPERM' ? 'unreadable' : 'unreadable' };
    }
  }

  readFile(args) {
    const tool = 'read_file';
    const exhausted = this.budgetForCall();
    if (exhausted) return this.deny(tool, { path: typeof args?.path === 'string' ? args.path : null }, exhausted);
    const r = this.resolve(args?.path);
    if (r.invalid) return this.fail(tool, { path: null }, 'invalid-arguments');
    if (r.deny) return this.deny(tool, { path: args.path }, r.deny);
    if (r.rel === '') return this.fail(tool, { root: r.root, path: '' }, 'not-a-file');
    const offset = Number.isInteger(args.offset) && args.offset >= 0 ? args.offset : 0;
    const limit = Number.isInteger(args.limit) && args.limit >= 1 ? Math.min(args.limit, MAX_READ_LIMIT) : MAX_READ_LIMIT;
    const opened = this.openAtomically(r.resolved);
    if (opened.error) return this.fail(tool, { root: r.root, path: r.rel }, opened.error);
    if (opened.deny) return this.deny(tool, { root: r.root, path: r.rel }, opened.deny);
    const whole = opened.bytes;
    if (looksBinary(whole)) return this.deny(tool, { root: r.root, path: r.rel }, 'binary');
    // Ranges are byte offsets; the returned window never ends inside a multi-byte UTF-8 sequence — a
    // trailing partial character is left for the next call, and `next_offset` says where that is.
    let end = Math.min(offset + limit, whole.length);
    if (end < whole.length) { let back = 0; while (back < 3 && end - back > offset && (whole[end - back - 1] & 0xC0) === 0x80) back++; if (end - back > offset && (whole[end - back - 1] & 0xC0) === 0xC0) end -= back + 1; else if (back && end - back <= offset) end = offset; }
    const slice = whole.subarray(offset, end);
    const text = slice.toString('utf8');
    const returned = Buffer.from(text, 'utf8');
    if (!this.charge({ root: r.root, rel: r.rel, returnedBytes: returned.length })) return this.deny(tool, { root: r.root, path: r.rel }, 'budget-exhausted');
    this.record({ tool, root: r.root, path: r.rel, file_sha256: sha256Hex(whole), file_bytes: whole.length, range: [offset, limit], returned_sha256: sha256Hex(returned), returned_bytes: returned.length });
    const meta = { root: r.root, path: r.rel, file_bytes: whole.length, offset, limit, returned_bytes: returned.length, next_offset: offset + slice.length, eof: offset + slice.length >= whole.length };
    return { result: { content: [{ type: 'text', text }, { type: 'text', text: JSON.stringify(meta) }], isError: false } };
  }

  entryType(dirent) {
    if (dirent.isSymbolicLink()) return 'symlink';
    if (dirent.isDirectory()) return 'dir';
    if (dirent.isFile()) return 'file';
    return 'other';
  }

  listDir(args) {
    const tool = 'list_dir';
    const exhausted = this.budgetForCall();
    if (exhausted) return this.deny(tool, { path: typeof args?.path === 'string' ? args.path : null }, exhausted);
    const r = this.resolve(args?.path);
    if (r.invalid) return this.fail(tool, { path: null }, 'invalid-arguments');
    if (r.deny) return this.deny(tool, { path: args.path }, r.deny);
    let dirents;
    try {
      const st = fs.lstatSync(r.resolved);
      if (!st.isDirectory()) return this.fail(tool, { root: r.root, path: r.rel }, st.isSymbolicLink() ? 'not-a-directory' : 'not-a-directory');
      dirents = fs.readdirSync(r.resolved, { withFileTypes: true });
    } catch (e) {
      return this.fail(tool, { root: r.root, path: r.rel }, e.code === 'ENOENT' || e.code === 'ENOTDIR' ? 'absent' : 'unreadable');
    }
    const entries = dirents
      .filter((d) => !isExcludedRel(r.rel ? `${r.rel}/${d.name}` : d.name))
      .map((d) => ({ name: d.name, type: this.entryType(d) }))
      .sort((a, b) => a.name.localeCompare(b.name));
    const text = JSON.stringify({ root: r.root, path: r.rel, entries });
    const returned = Buffer.from(text, 'utf8');
    if (!this.charge({ root: r.root, rel: r.rel, returnedBytes: returned.length, countFile: false })) return this.deny(tool, { root: r.root, path: r.rel }, 'budget-exhausted');
    this.record({ tool, root: r.root, path: r.rel, entries, returned_sha256: sha256Hex(returned) });
    return { result: { content: [{ type: 'text', text }], isError: false } };
  }

  // Regular files under a root, excluded directories pruned, symlinks never followed. Sorted.
  *walk(root) {
    const base = this.roots[root];
    const visit = function* visit(dir, rel) {
      let dirents;
      try { dirents = fs.readdirSync(dir, { withFileTypes: true }); } catch { return; }
      dirents.sort((a, b) => a.name.localeCompare(b.name));
      for (const d of dirents) {
        const childRel = rel ? `${rel}/${d.name}` : d.name;
        if (isExcludedRel(childRel)) continue;
        if (d.isSymbolicLink()) continue;
        if (d.isDirectory()) yield* visit(path.join(dir, d.name), childRel);
        else if (d.isFile()) yield { root, rel: childRel, abs: path.join(dir, d.name) };
      }
    };
    yield* visit(base, '');
  }

  search(args) {
    const tool = 'search';
    const exhausted = this.budgetForCall();
    if (exhausted) return this.deny(tool, { pattern: typeof args?.pattern === 'string' ? args.pattern : null }, exhausted);
    if (typeof args?.pattern !== 'string' || !args.pattern) return this.fail(tool, { pattern: null }, 'invalid-arguments');
    const pattern = args.pattern;
    const glob = typeof args.glob === 'string' && args.glob ? args.glob : null;
    const max = Number.isInteger(args.max) && args.max >= 1 ? Math.min(args.max, MAX_SEARCH_MAX) : DEFAULT_SEARCH_MAX;
    let matcher;
    try {
      matcher = pattern.startsWith('re:') ? new RegExp(pattern.slice(3)) : null;
    } catch { return this.fail(tool, { pattern }, 'invalid-arguments'); }
    const literal = matcher ? null : pattern;
    const globRe = glob ? globToRegExp(glob) : null;
    const globOnBasename = glob ? !glob.includes('/') : false;
    const filesOpened = [];
    const matches = [];
    let truncated = false;
    let truncatedBy = null;
    outer:
    for (const root of ['project', 'plugin']) {
      for (const f of this.walk(root)) {
        if (globRe && !globRe.test(globOnBasename ? path.posix.basename(f.rel) : f.rel)) continue;
        const key = this.fileKey(root, f.rel);
        if (!this.files.has(key) && this.files.size >= this.budgets.files) { truncated = true; truncatedBy = 'budget'; break outer; }
        const opened = this.openAtomically(f.abs);
        if (!opened.bytes) continue;
        if (looksBinary(opened.bytes)) continue;
        this.files.add(key);
        filesOpened.push({ root, path: f.rel, file_sha256: sha256Hex(opened.bytes) });
        const lines = opened.bytes.toString('utf8').split('\n');
        for (let i = 0; i < lines.length; i++) {
          const hit = matcher ? matcher.test(lines[i]) : lines[i].includes(literal);
          if (!hit) continue;
          if (matches.length >= max) { truncated = true; truncatedBy = 'max'; break outer; }
          matches.push({ root, path: f.rel, line: i + 1, text: lines[i].slice(0, 400) });
        }
      }
    }
    const text = JSON.stringify({ pattern, glob, matches, truncated, truncated_by: truncatedBy, files_opened: filesOpened.length });
    const returned = Buffer.from(text, 'utf8');
    if (this.bytes + returned.length > this.budgets.bytes) return this.deny(tool, { pattern }, 'budget-exhausted');
    this.bytes += returned.length;
    this.record({ tool, pattern, glob, max, files_opened: filesOpened, matches: matches.map((m) => ({ root: m.root, path: m.path, line: m.line })), truncated, returned_sha256: sha256Hex(returned) });
    return { result: { content: [{ type: 'text', text }], isError: false } };
  }

  call(name, args = {}) {
    this.calls += 1;
    if (name === 'read_file') return this.readFile(args ?? {});
    if (name === 'list_dir') return this.listDir(args ?? {});
    if (name === 'search') return this.search(args ?? {});
    return null;
  }

  handle(msg) {
    const { id, method, params } = msg;
    if (id === undefined || id === null) return null; // notification (notifications/initialized, cancelled, …)
    if (method === 'initialize') {
      const requested = params?.protocolVersion;
      return { jsonrpc: '2.0', id, result: { protocolVersion: KNOWN_PROTOCOLS.includes(requested) ? requested : KNOWN_PROTOCOLS[0], capabilities: { tools: {} }, serverInfo: { name: SERVER_NAME, version: pluginVersion() } } };
    }
    if (method === 'ping') return { jsonrpc: '2.0', id, result: {} };
    if (method === 'tools/list') return { jsonrpc: '2.0', id, result: { tools: TOOLS } };
    if (method === 'tools/call') {
      const name = params?.name;
      if (!BROKER_TOOLS.includes(name)) return { jsonrpc: '2.0', id, error: { code: -32602, message: `unknown tool ${String(name)}` } };
      const { result } = this.call(name, params?.arguments ?? {});
      return { jsonrpc: '2.0', id, result };
    }
    return { jsonrpc: '2.0', id, error: { code: -32601, message: `method not found: ${String(method)}` } };
  }
}

export function configFromEnv(env = process.env) {
  const errors = [];
  const rootsRaw = String(env.HARNESS_READER_ROOTS ?? '').split(path.delimiter).filter(Boolean);
  if (rootsRaw.length !== 2 || !rootsRaw.every((p) => path.isAbsolute(p))) errors.push('HARNESS_READER_ROOTS must be <projectRoot>:<pluginRoot>, both absolute');
  if (!env.HARNESS_READER_LOG || !path.isAbsolute(env.HARNESS_READER_LOG)) errors.push('HARNESS_READER_LOG must be an absolute file path');
  const budgets = env.HARNESS_READER_BUDGET === undefined ? DEFAULT_BUDGETS : parseBudgetEnv(env.HARNESS_READER_BUDGET);
  if (!budgets) errors.push('HARNESS_READER_BUDGET must be files,bytes,calls (positive integers)');
  if (!env.HARNESS_REVIEW_ID) errors.push('HARNESS_REVIEW_ID is required');
  if (errors.length) return { ok: false, errors };
  return { ok: true, roots: { project: rootsRaw[0], plugin: rootsRaw[1] }, logFile: env.HARNESS_READER_LOG, budgets, reviewId: env.HARNESS_REVIEW_ID, testHook: env.NODE_ENV === 'test' ? env.HARNESS_READER_TEST_HOOK ?? null : null };
}

function main() {
  const cfg = configFromEnv();
  if (!cfg.ok) { process.stderr.write(`reader-mcp: ${cfg.errors.join('; ')}\n`); process.exit(2); }
  let broker;
  try {
    broker = new ReaderBroker(cfg);
  } catch (e) {
    if (e.code === 'EEXIST') { process.stderr.write(`reader-mcp: log ${cfg.logFile} already exists — a broker for this run is already running or ran; refusing to start a second instance\n`); process.exit(3); }
    process.stderr.write(`reader-mcp: ${e.message}\n`);
    process.exit(2);
  }
  const write = (obj) => { try { process.stdout.write(`${JSON.stringify(obj)}\n`); } catch { /* client gone */ } };
  const rl = readline.createInterface({ input: process.stdin, crlfDelay: Infinity });
  rl.on('line', (line) => {
    if (!line.trim()) return;
    let msg;
    try { msg = JSON.parse(line); } catch { write({ jsonrpc: '2.0', id: null, error: { code: -32700, message: 'parse error' } }); return; }
    if (Array.isArray(msg)) { for (const m of msg) { const r = broker.handle(m); if (r) write(r); } return; }
    try {
      const response = broker.handle(msg);
      if (response) write(response);
    } catch (e) {
      if (msg.id !== undefined && msg.id !== null) write({ jsonrpc: '2.0', id: msg.id, error: { code: -32603, message: `internal error: ${e.message}` } });
    }
  });
  const shutdown = (signal) => { broker.end(signal ? { signal } : {}); process.exit(0); };
  rl.on('close', () => shutdown(null));
  process.on('SIGTERM', () => shutdown('SIGTERM'));
  process.on('SIGINT', () => shutdown('SIGINT'));
  process.on('SIGHUP', () => shutdown('SIGHUP'));
}

if (process.argv[1] && fileURLToPath(import.meta.url) === realpathOrSelf(process.argv[1])) {
  main();
}
