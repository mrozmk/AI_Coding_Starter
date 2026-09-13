#!/usr/bin/env node
// Immutable context pack for a closed-context reviewer (contract 6; T07): exact bytes of the prime
// instructions, applicable rules, routed non-empty memory, an explicit topic read-set, the target
// artifact(s) and named dependency files, with per-file hashes and typed omissions. Every requested
// path is normalized once and containment-checked before it is read; every requested artifact must
// appear in the pack; the pack identity binds the packed bytes. Never truncates.
//
//   node scripts/context-pack.mjs --project-root <dir> --plugin-root <dir> --artifact <file> [--dep <file>]... \
//        [--optional-dep <file>]... [--read <file>]... [--optional-read <file>]... [--out <pack.txt>] [--max-bytes N] [--provider <name>]
import fs from 'node:fs';
import path from 'node:path';
import { randomUUID } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { parseArgv, requireOpt } from './lib/argv.mjs';
import { sha256Hex } from './lib/digest.mjs';
import { parseFrontmatter } from './lib/frontmatter.mjs';
import { isInside, realpathOrSelf, toPosix } from './lib/fsx.mjs';

export const DEFAULT_MAX_BYTES = 400 * 1024;
export const PACK_HEADER = '# HARNESS CONTEXT PACK v1';

// Hard exclusions: never packed, whatever the caller asks (contract 6). No exception can lift these.
export const HARD_EXCLUDE_RE = /(^|\/)\.env(\.(?!example$)|$)|\.pem$|\.key$|\.p12$|\.pfx$|(^|\/)id_(rsa|dsa|ecdsa|ed25519)|(^|\/)user-profile\.md$|^\.agents\/sources\/|^\.agents\/handoffs\/|^\.agents\/memory\/archive\/|^\.agents\/harness-state\/|(^|\/)\.git\//i;
// Keyword exclusions: conservative filename classes. An explicit, per-file, vetted exception may lift one.
export const KEYWORD_EXCLUDE_RE = /credential|secret/i;
export const EXCLUDE_RE = new RegExp(`${HARD_EXCLUDE_RE.source}|${KEYWORD_EXCLUDE_RE.source}`, 'i');
// Directories refused as a whole — the directory itself and every descendant (the regexes above
// match descendants only). Shared with the read broker (reader-mcp.mjs); never overridable.
export const EXCLUDED_DIRS = ['.agents/sources', '.agents/handoffs', '.agents/memory/archive', '.agents/harness-state', '.git', 'node_modules', 'dist', '.playwright-mcp'];
// Sections of an artifact whose backtick-quoted paths are packed automatically in hybrid mode.
const CITED_HEADINGS = ['Files', 'Relevant Codebase Files', 'New Files to Create', 'Patterns to Follow'];
const CITED_LINE_SECTION = 'Architecture and contracts';
const CITED_LINE_MARKER = /reuse targets/i;

// Basename rule: every `.env*` spelling except exactly `.env.example` (`.envrc`, `.env-production`, …).
export function isEnvFile(basename) {
  return basename.startsWith('.env') && basename !== '.env.example';
}

// Hard exclusion of a project-relative POSIX path: no caller option can lift it.
export function isHardExcludedRel(rel) {
  const r = toPosix(String(rel));
  if (isEnvFile(path.posix.basename(r))) return true;
  if (HARD_EXCLUDE_RE.test(r)) return true;
  // A single-name directory (node_modules, dist, .git, .playwright-mcp) is excluded at every depth —
  // a nested workspace's node_modules is no less a dependency tree; a path-qualified one is root-anchored.
  return EXCLUDED_DIRS.some((dir) => (dir.includes('/')
    ? r === dir || r.startsWith(`${dir}/`)
    : r === dir || r.startsWith(`${dir}/`) || r.endsWith(`/${dir}`) || r.includes(`/${dir}/`)));
}

// Keyword exclusion: name-based, liftable per file by a vetted `allowExceptions` entry when packing.
export function isKeywordExcludedRel(rel) {
  return KEYWORD_EXCLUDE_RE.test(toPosix(String(rel)));
}

// Strict union for the broker: no exceptions, ever.
export function isExcludedRel(rel) {
  return isHardExcludedRel(rel) || isKeywordExcludedRel(rel);
}

// Component-aware containment of an already-resolved path: `/w/project-other` is not inside `/w/project`.
export function isInsideRoot(root, resolved) {
  const rel = path.relative(root, resolved);
  if (rel === '') return true;
  if (path.isAbsolute(rel)) return false;
  return rel.split(path.sep)[0] !== '..';
}

function headingOf(line) {
  const m = line.match(/^(#{1,6})\s+(.*?)\s*#*\s*$/);
  return m ? { level: m[1].length, text: m[2] } : null;
}

// Repo-relative paths an artifact cites in its file-listing sections: backtick tokens that resolve to
// an existing regular file under the project root, `:line` / `(lines …)` suffixes stripped, deduped.
export function citedPaths(text, projectRoot) {
  const root = realpathOrSelf(projectRoot);
  const found = [];
  const seen = new Set();
  let active = null; // { level, lineOnly }
  for (const line of String(text).split('\n')) {
    const h = headingOf(line);
    if (h) {
      if (active && h.level <= active.level) active = null;
      if (!active) {
        if (CITED_HEADINGS.some((name) => h.text === name || h.text.startsWith(`${name} `) || h.text.startsWith(`${name}:`) || h.text.startsWith(`${name} —`))) active = { level: h.level, lineOnly: false };
        else if (h.text === CITED_LINE_SECTION || h.text.startsWith(`${CITED_LINE_SECTION} `)) active = { level: h.level, lineOnly: true };
      }
      continue;
    }
    if (!active) continue;
    if (active.lineOnly && !CITED_LINE_MARKER.test(line)) continue;
    for (const m of line.matchAll(/`([^`\n]+)`/g)) {
      let token = m[1].trim();
      token = token.replace(/\s*\(lines?[^)]*\)\s*$/i, '');
      token = token.replace(/:\d+(-\d+)?$/, '');
      token = token.replace(/:$/, '');
      if (!token || /\s/.test(token) || token.startsWith('plugin:') || token.startsWith('-')) continue;
      const req = normalizeRequest(root, token);
      if (!req.inside || seen.has(req.rel)) continue;
      let isFile = false;
      try { isFile = fs.statSync(req.abs).isFile(); } catch { isFile = false; }
      if (!isFile) continue;
      seen.add(req.rel);
      found.push(req.rel);
    }
  }
  return found;
}

const RULE_FILES = ['CLAUDE.md', 'AGENTS.md', '.agents/project-rules.md'];
const MEMORY_ALWAYS = ['.agents/memory/index.md'];
const MEMORY_STATUS_GATED = ['.agents/memory/project-brief.md', '.agents/memory/architecture.md'];
const MEMORY_IF_CONTENT = ['.agents/memory/patterns.md', '.agents/memory/decisions.md', '.agents/memory/errors.md', '.agents/memory/api.md'];
// Where an explicit read-set may point: topic memory, references, rules. Nothing else.
const READ_SET_ROOTS = ['.agents/memory/', '.agents/reference/', 'docs/', 'CLAUDE.md', 'AGENTS.md', '.agents/project-rules.md', '.agents/specs/'];

function statusOf(text) {
  try { return parseFrontmatter(text).data.status ?? 'no-frontmatter'; } catch { return 'no-frontmatter'; }
}

function hasContent(text) {
  const { body } = (() => { try { return parseFrontmatter(text); } catch { return { body: text }; } })();
  return body.split('\n').filter((l) => l.trim() && !l.startsWith('#') && !l.startsWith('>')).length >= 3;
}

// Resolve symlinks on the longest existing ancestor so a missing file under a symlinked root
// (macOS /var → /private/var) still compares against the same real root.
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

// One normalization for every requested path: resolve against the root, containment before reading.
export function normalizeRequest(root, requested) {
  const abs = realpathDeep(path.resolve(root, requested));
  const inside = isInside(root, abs);
  const rel = toPosix(path.relative(realpathOrSelf(root), abs));
  return { requested: String(requested), abs, rel, inside };
}

export function buildContextPack({ projectRoot, pluginRoot, artifacts = [], deps = [], optionalDeps = [], readSet = { required: [], optional: [] }, allowExceptions = [], maxBytes = DEFAULT_MAX_BYTES, mode = 'closed', cited = mode === 'hybrid' }) {
  if (!['closed', 'hybrid'].includes(mode)) throw new Error(`pack mode must be closed or hybrid, got ${mode}`);
  const root = realpathOrSelf(projectRoot);
  const files = [];
  const omissions = [];
  const byRel = new Map();
  const exceptions = new Set(allowExceptions.map((p) => toPosix(p)));

  const omit = (rel, reason, kind, required) => omissions.push({ path: rel, reason, kind, required });

  const consider = (requested, role, { optional = false, gate = null } = {}) => {
    const req = normalizeRequest(root, requested);
    const { rel, abs, inside } = req;
    if (byRel.has(rel)) { const f = byRel.get(rel); if (!f.roles.includes(role)) f.roles.push(role); return f; }
    if (role !== 'prime' && !inside) { omit(rel, 'outside project root', 'outside-root', !optional); return null; }
    if (isHardExcludedRel(rel)) { omit(rel, 'excluded (secret, private or raw input) — no exception applies', 'excluded', false); return null; }
    if (isKeywordExcludedRel(rel) && !exceptions.has(rel)) { omit(rel, 'excluded (secret-looking name) — list it in allowExceptions after review to include it', 'excluded', !optional); return null; }
    const resolved = realpathOrSelf(abs);
    if (!fs.existsSync(resolved) || !fs.statSync(resolved).isFile()) { omit(rel, 'missing', 'missing-file', !optional); return null; }
    const bytes = fs.readFileSync(resolved);
    const text = bytes.toString('utf8');
    if (gate) {
      const verdict = gate(text);
      if (verdict) { omit(rel, verdict, 'gated', false); return null; }
    }
    const entry = { path: role === 'prime' ? `plugin:${toPosix(path.relative(realpathOrSelf(pluginRoot), resolved))}` : rel, role, roles: [role], sha256: sha256Hex(bytes), bytes: bytes.length, text, exception: exceptions.has(rel) || undefined };
    files.push(entry);
    byRel.set(rel, entry);
    return entry;
  };

  consider(path.join(pluginRoot, 'skills/prime/SKILL.md'), 'prime');
  if (!files.some((f) => f.role === 'prime')) {
    return { ok: false, reason: 'needs-context', kind: 'missing-file', detail: `prime instructions missing under plugin root ${pluginRoot}/skills/prime/SKILL.md — bind a verified installation first`, omissions };
  }
  for (const f of RULE_FILES) consider(path.join(root, f), 'rules', { optional: true });
  for (const f of MEMORY_ALWAYS) consider(path.join(root, f), 'memory', { optional: true });
  for (const f of MEMORY_STATUS_GATED) consider(path.join(root, f), 'memory', { optional: true, gate: (t) => (['populated', 'seeded'].includes(statusOf(t)) ? null : `status ${statusOf(t)} — placeholder skipped`) });
  for (const f of MEMORY_IF_CONTENT) consider(path.join(root, f), 'memory', { optional: true, gate: (t) => (statusOf(t) === 'empty' ? 'status empty' : hasContent(t) ? null : 'no entries yet') });

  if (artifacts.length === 0) throw new Error('at least one --artifact is required');
  const artifactEntries = artifacts.map((a) => ({ a, entry: consider(a, 'artifact') }));
  for (const d of deps) consider(d, 'dependency');
  for (const d of optionalDeps) consider(d, 'dependency', { optional: true });
  for (const r of readSet.required ?? []) {
    const rel = normalizeRequest(root, r).rel;
    if (!READ_SET_ROOTS.some((p) => rel === p || rel.startsWith(p))) { omit(rel, 'read-set path outside the allowed roots (memory, reference, docs, rules, specs)', 'not-allowed', true); continue; }
    consider(r, 'read-set', { gate: (t) => (statusOf(t) === 'empty' ? 'status empty' : null) });
  }
  for (const r of readSet.optional ?? []) {
    const rel = normalizeRequest(root, r).rel;
    if (!READ_SET_ROOTS.some((p) => rel === p || rel.startsWith(p))) { omit(rel, 'read-set path outside the allowed roots', 'not-allowed', false); continue; }
    consider(r, 'read-set', { optional: true, gate: (t) => (statusOf(t) === 'empty' ? 'status empty' : null) });
  }

  // Hybrid: the paths the artifact cites ride along as `cited` — optional, exclusion-checked, and the
  // first to go when the pack is over budget (below). A cited file never becomes an artifact.
  if (cited) {
    for (const { entry } of artifactEntries) {
      if (!entry) continue;
      for (const rel of citedPaths(entry.text, root)) consider(rel, 'cited', { optional: true });
    }
  }

  const missingArtifacts = artifactEntries.filter((x) => !x.entry || !x.entry.roles.includes('artifact'));
  if (missingArtifacts.length) {
    const detail = missingArtifacts.map((x) => { const rel = normalizeRequest(root, x.a).rel; const o = omissions.find((om) => om.path === rel); return `${rel} (${o?.reason ?? 'not packed'})`; }).join(', ');
    return { ok: false, reason: 'needs-context', kind: 'missing-file', detail: `artifact not packable: ${detail}`, omissions };
  }
  const missingRequired = omissions.filter((o) => o.required);
  if (missingRequired.length) {
    return { ok: false, reason: 'needs-context', kind: missingRequired[0].kind, detail: `required context not packable: ${missingRequired.map((o) => `${o.path} (${o.reason})`).join(', ')}`, omissions };
  }
  let total = files.reduce((n, f) => n + f.bytes, 0);
  // Over budget: drop purely-cited files largest-first. Mandatory roles are never dropped, so an
  // oversized mandatory set still fails below exactly as in closed mode.
  if (total > maxBytes && cited) {
    const droppable = files.filter((f) => f.roles.length === 1 && f.roles[0] === 'cited').sort((a, b) => b.bytes - a.bytes);
    for (const f of droppable) {
      if (total <= maxBytes) break;
      files.splice(files.indexOf(f), 1);
      byRel.delete(f.path);
      omit(f.path, 'budget', 'budget', false);
      total -= f.bytes;
    }
  }
  if (total > maxBytes) {
    const largest = [...files].sort((a, b) => b.bytes - a.bytes).slice(0, 5).map((f) => `${f.path} (${f.bytes} B)`);
    return { ok: false, reason: 'context-too-large', detail: `pack is ${total} B, limit ${maxBytes} B; largest: ${largest.join(', ')}. Split the artifact or raise --max-bytes deliberately; nothing was truncated.`, total, maxBytes, omissions };
  }
  const meta = {
    schema_version: 1,
    pack_id: randomUUID(),
    created_utc: new Date().toISOString(),
    mode,
    total_bytes: total,
    files: files.map(({ text, ...rest }) => rest),
    artifacts: artifactEntries.map((x) => ({ path: x.entry.path, sha256: x.entry.sha256 })),
    omissions,
  };
  meta.pack_digest = sha256Hex(Buffer.from(files.map((f) => `${f.path}\0${f.sha256}\0${f.bytes}`).join('\n')));
  return { ok: true, meta, text: renderPack(meta, files) };
}

// Re-hash every packed project file; a changed or vanished file breaks the identity.
export function verifyPackUnchanged(projectRoot, meta) {
  const root = realpathOrSelf(projectRoot);
  const changed = [];
  for (const f of meta.files) {
    if (f.path.startsWith('plugin:')) continue;
    const abs = path.join(root, f.path);
    if (!fs.existsSync(abs)) { changed.push(`${f.path} (removed)`); continue; }
    if (sha256Hex(fs.readFileSync(abs)) !== f.sha256) changed.push(f.path);
  }
  return changed;
}

// What leaves the machine, for the consent boundary: provider, exact files, bytes, and what stayed.
// Closed output is byte-identical to before hybrid existed; hybrid adds the surface the reviewer may
// still read on its own, and labels the file list as the initial payload rather than the whole story.
export function outboundManifest(meta, { provider, host = null, mode = 'closed', roots = null, exclusions = null, budgets = null } = {}) {
  const manifest = {
    provider,
    reviewer_host: host,
    pack_id: meta.pack_id,
    pack_digest: meta.pack_digest,
    total_bytes: meta.total_bytes,
    files: meta.files.map((f) => ({ path: f.path, roles: f.roles, sha256: f.sha256, bytes: f.bytes, exception: f.exception ?? false })),
    omitted: meta.omissions.map((o) => ({ path: o.path, reason: o.reason })),
    note: 'Only the files listed are transmitted, byte-exact. Anything under `omitted` stays local. Hard exclusions (.env*, keys, user-profile, sources, handoffs, archive, harness-state) can never be listed.',
  };
  if (mode !== 'hybrid') return manifest;
  return {
    ...manifest,
    mode: 'hybrid',
    roots: roots ?? {},
    exclusions: exclusions ?? { env_basename: '.env* except .env.example', hard: HARD_EXCLUDE_RE.source, keyword: KEYWORD_EXCLUDE_RE.source, directories: [...EXCLUDED_DIRS] },
    budgets: budgets ?? {},
    initial_payload: true,
    note: 'The files listed are the initial payload, transmitted byte-exact. Files under `omitted` are not in the initial payload; in hybrid mode the reviewer may still read any file under the roots that the exclusions allow, up to the budgets, through the read broker — every such read is logged and hashed into the final audit (pack.outbound.final.json). Hard exclusions (.env*, keys, user-profile, sources, handoffs, archive, harness-state, node_modules, dist) can never be listed, packed or read.',
  };
}

function renderPack(meta, files) {
  const out = [PACK_HEADER, `pack_id: ${meta.pack_id}`, `pack_digest: ${meta.pack_digest}`, `files: ${files.length}`, `bytes: ${meta.total_bytes}`, ''];
  out.push('All paths are relative to the reviewed project root (or the plugin root when prefixed `plugin:`).');
  out.push('Files are byte-exact. Anything not present here was not shown to you; report it as missing evidence instead of assuming it.', '');
  for (const f of files) {
    out.push(`== FILE role=${f.role}${f.roles.length > 1 ? ` roles=${f.roles.join(',')}` : ''} path=${f.path} sha256=${f.sha256} bytes=${f.bytes} ==`);
    out.push(f.text.endsWith('\n') ? f.text.slice(0, -1) : f.text);
    out.push('== END FILE ==', '');
  }
  out.push('== OMISSIONS ==');
  if (meta.omissions.length === 0) out.push('(none)');
  for (const o of meta.omissions) out.push(`- ${o.path} — ${o.reason}`);
  out.push('== END PACK ==', '');
  return out.join('\n');
}

function main() {
  const { opts } = parseArgv(process.argv.slice(2));
  const res = buildContextPack({
    projectRoot: requireOpt(opts, 'project-root'),
    pluginRoot: requireOpt(opts, 'plugin-root'),
    artifacts: [].concat(opts.artifact ?? []),
    deps: [].concat(opts.dep ?? []),
    optionalDeps: [].concat(opts['optional-dep'] ?? []),
    readSet: { required: [].concat(opts.read ?? []), optional: [].concat(opts['optional-read'] ?? []) },
    allowExceptions: [].concat(opts['allow-exception'] ?? []),
    maxBytes: opts['max-bytes'] ? Number(opts['max-bytes']) : DEFAULT_MAX_BYTES,
  });
  if (!res.ok) {
    console.error(`context-pack: ${res.reason}: ${res.detail}`);
    process.exit(3);
  }
  if (opts.out) {
    fs.writeFileSync(opts.out, res.text);
    fs.writeFileSync(`${opts.out}.json`, `${JSON.stringify(res.meta, null, 2)}\n`);
    fs.writeFileSync(`${opts.out}.outbound.json`, `${JSON.stringify(outboundManifest(res.meta, { provider: opts.provider ?? 'unspecified' }), null, 2)}\n`);
    console.log(JSON.stringify({ pack: opts.out, meta: `${opts.out}.json`, outbound: `${opts.out}.outbound.json`, files: res.meta.files.length, bytes: res.meta.total_bytes, omissions: res.meta.omissions.length }));
  } else {
    process.stdout.write(res.text);
  }
}

if (process.argv[1] && fileURLToPath(import.meta.url) === realpathOrSelf(process.argv[1])) {
  try {
    main();
  } catch (err) {
    console.error(`context-pack: ${err.message}`);
    process.exit(1);
  }
}
