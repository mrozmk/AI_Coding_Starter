// Shared read-record contract of the hybrid reviewer: the typed JSONL shapes the read broker
// (reader-mcp.mjs) writes, the containment rule the judge and the orchestrator re-apply to every
// successful read, and the transcript digest that binds the log to a review result. One module so
// the three parties cannot drift on what a record means.
import path from 'node:path';
import { sha256Hex } from './digest.mjs';
import { isExcludedRel, isInsideRoot } from '../context-pack.mjs';

export const BROKER_TOOLS = ['read_file', 'list_dir', 'search'];
export const ROOT_IDS = ['project', 'plugin'];
// Policy denials: the enforcement working. Logged with `denied: true`; permitted outcomes for the judge.
export const DENIAL_REASONS = ['budget-exhausted', 'excluded', 'outside-roots', 'binary', 'replaced'];
// Filesystem / protocol outcomes: not policy, not fatal. Logged with `error: true`; permitted too.
export const ERROR_REASONS = ['absent', 'not-a-file', 'not-a-directory', 'unreadable', 'invalid-arguments'];
export const DEFAULT_BUDGETS = { files: 30, bytes: 409600, calls: 200 };
export const MAX_READ_LIMIT = 65536;

const HEX64 = /^[0-9a-f]{64}$/;

function isPlainObject(v) {
  return v !== null && typeof v === 'object' && !Array.isArray(v);
}

// A relative POSIX path that stays inside its root by construction: no absolute, no `..` component.
export function isCanonicalRelPath(p) {
  if (typeof p !== 'string') return false;
  if (p === '') return true;
  if (p.startsWith('/') || p.includes('\\') || /^[A-Za-z]:/.test(p)) return false;
  return !p.split('/').some((seg) => seg === '..' || seg === '');
}

// The reviewer's spelling of a broker-read path in `evidence_read`.
export function evidencePathOf(root, rel) {
  return root === 'plugin' ? `plugin:${rel}` : rel;
}

// Component-aware containment of one identity {root, path} against the configured roots.
export function containmentError(record, roots) {
  if (!isPlainObject(roots) || !ROOT_IDS.every((r) => typeof roots[r] === 'string' && roots[r])) return 'roots must name absolute project and plugin directories';
  if (!ROOT_IDS.includes(record.root)) return `unknown root id ${JSON.stringify(record.root)}`;
  if (!isCanonicalRelPath(record.path)) return `path is not a canonical relative path: ${JSON.stringify(record.path)}`;
  const base = path.resolve(roots[record.root]);
  const abs = path.resolve(base, record.path);
  if (!isInsideRoot(base, abs)) return `${record.path} resolves outside the ${record.root} root`;
  if (record.path !== '' && isExcludedRel(record.path)) return `${record.path} is an excluded path`;
  return null;
}

// Shape check of one log line (header, call record, trailer). Returns `path: message` strings.
export function validateReadRecord(rec) {
  const errors = [];
  const fail = (m) => errors.push(m);
  if (!isPlainObject(rec)) return ['record is not an object'];
  if (rec.type === 'header') {
    for (const k of ['review_id', 'instance_id', 'roots', 'budgets', 'started']) if (rec[k] === undefined) fail(`header missing ${k}`);
    return errors;
  }
  if (rec.type === 'end') {
    for (const k of ['seq', 'calls', 'denied', 'files', 'bytes']) if (typeof rec[k] !== 'number') fail(`trailer ${k} must be a number`);
    return errors;
  }
  if (!Number.isInteger(rec.seq) || rec.seq < 1) fail('seq must be a positive integer');
  if (typeof rec.ts !== 'string') fail('ts must be a string');
  if (!BROKER_TOOLS.includes(rec.tool)) fail(`tool must be one of ${BROKER_TOOLS.join('|')}`);
  if (rec.denied === true) {
    if (!DENIAL_REASONS.includes(rec.reason)) fail(`denial reason must be one of ${DENIAL_REASONS.join('|')}`);
    return errors;
  }
  if (rec.error === true) {
    if (!ERROR_REASONS.includes(rec.reason)) fail(`error reason must be one of ${ERROR_REASONS.join('|')}`);
    return errors;
  }
  if (!HEX64.test(rec.returned_sha256 ?? '')) fail('returned_sha256 must be a sha256 hex');
  if (rec.tool === 'read_file') {
    if (!ROOT_IDS.includes(rec.root)) fail('read_file root must be project|plugin');
    if (!isCanonicalRelPath(rec.path) || rec.path === '') fail('read_file path must be a canonical relative path');
    if (!HEX64.test(rec.file_sha256 ?? '')) fail('file_sha256 must be a sha256 hex');
    if (!Number.isInteger(rec.file_bytes)) fail('file_bytes must be an integer');
    if (!Array.isArray(rec.range) || rec.range.length !== 2) fail('range must be [offset, limit]');
    if (!Number.isInteger(rec.returned_bytes)) fail('returned_bytes must be an integer');
  } else if (rec.tool === 'list_dir') {
    if (!ROOT_IDS.includes(rec.root)) fail('list_dir root must be project|plugin');
    if (!isCanonicalRelPath(rec.path)) fail('list_dir path must be a canonical relative path');
    if (!Array.isArray(rec.entries) || rec.entries.some((e) => !isPlainObject(e) || typeof e.name !== 'string' || typeof e.type !== 'string')) fail('entries must be [{name, type}]');
  } else if (rec.tool === 'search') {
    if (typeof rec.pattern !== 'string') fail('search pattern must be a string');
    if (!Array.isArray(rec.files_opened) || rec.files_opened.some((f) => !ROOT_IDS.includes(f.root) || !isCanonicalRelPath(f.path) || !HEX64.test(f.file_sha256 ?? ''))) fail('files_opened must be [{root, path, file_sha256}]');
    if (!Array.isArray(rec.matches)) fail('matches must be an array');
    if (typeof rec.truncated !== 'boolean') fail('truncated must be a boolean');
  }
  return errors;
}

// Every successful file identity a transcript touched: read_file paths and search.files_opened.
export function successfulReads(records) {
  const out = [];
  for (const rec of records) {
    if (rec.denied === true || rec.error === true) continue;
    if (rec.tool === 'read_file') out.push({ root: rec.root, path: rec.path, file_sha256: rec.file_sha256, seq: rec.seq });
    if (rec.tool === 'search') for (const f of rec.files_opened ?? []) out.push({ root: f.root, path: f.path, file_sha256: f.file_sha256, seq: rec.seq });
  }
  return out;
}

// Parse a reads.jsonl transcript. Never throws: malformed lines become `errors`.
export function parseReadsLog(text) {
  const lines = String(text ?? '').split('\n').filter((l) => l.trim());
  const errors = [];
  let header = null;
  let trailer = null;
  const records = [];
  const headers = [];
  lines.forEach((line, i) => {
    let rec;
    try { rec = JSON.parse(line); } catch { errors.push(`line ${i + 1}: not JSON`); return; }
    const shape = validateReadRecord(rec);
    if (shape.length) errors.push(`line ${i + 1}: ${shape.join('; ')}`);
    if (rec.type === 'header') { headers.push(rec); if (!header) header = rec; return; }
    if (rec.type === 'end') { trailer = rec; return; }
    records.push(rec);
  });
  if (headers.length > 1) errors.push(`${headers.length} header lines — more than one broker instance wrote this log`);
  let last = 0;
  for (const rec of records) {
    if (rec.seq <= last) errors.push(`seq not monotonic at ${rec.seq}`);
    last = rec.seq;
  }
  return { header, headers, records, trailer, lines, errors };
}

// The transcript identity: SHA-256 over the canonical JSONL (every non-empty line, in file order,
// LF-joined with a trailing LF). Header and trailer are part of it.
export function readsDigest(lines) {
  const canonical = lines.map((l) => (typeof l === 'string' ? l.trim() : JSON.stringify(l))).filter(Boolean).join('\n');
  return sha256Hex(Buffer.from(`${canonical}\n`, 'utf8'));
}

// Result-sized summary of one record (no entries, no match texts).
export function summarizeRecord(rec) {
  const out = { seq: rec.seq, tool: rec.tool };
  if (rec.root !== undefined) out.root = rec.root;
  if (rec.path !== undefined) out.path = rec.path;
  if (rec.pattern !== undefined) out.pattern = rec.pattern;
  if (rec.denied === true) { out.denied = true; out.reason = rec.reason; return out; }
  if (rec.error === true) { out.error = true; out.reason = rec.reason; return out; }
  if (rec.file_sha256) out.file_sha256 = rec.file_sha256;
  if (rec.returned_sha256) out.returned_sha256 = rec.returned_sha256;
  if (rec.range) out.range = rec.range;
  if (rec.truncated !== undefined) out.truncated = rec.truncated;
  if (rec.tool === 'search') { out.files_opened = (rec.files_opened ?? []).length; out.matches = (rec.matches ?? []).length; }
  if (rec.tool === 'list_dir') out.entries = (rec.entries ?? []).length;
  return out;
}

export function parseBudgetEnv(value) {
  const parts = String(value ?? '').split(',').map((s) => Number(s.trim()));
  if (parts.length !== 3 || parts.some((n) => !Number.isInteger(n) || n < 1)) return null;
  return { files: parts[0], bytes: parts[1], calls: parts[2] };
}

export function formatBudgetEnv(b = DEFAULT_BUDGETS) {
  return `${b.files},${b.bytes},${b.calls}`;
}
