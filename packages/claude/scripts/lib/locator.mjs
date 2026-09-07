// Installed-root binding (contract 2; T12). Two records, two audiences:
//   .agents/harness-version.json  — PORTABLE, committed: which package identity (name, version,
//                                   digests) the project expects per host. No paths, no timestamps.
//   .agents/harness-state/         — LOCAL, gitignored: where that package is installed on THIS
//                                   machine, when it was bound, what the operator acknowledged
//                                   (hook trust, probes). A copied receipt is not an installation.
// A plugin root is trusted only after its build marker, payload digest and skill entry paths are
// re-verified; the binding is re-checked on every use. Never guesses a cache layout.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { recordsDigest, sha256Hex } from './digest.mjs';
import { isInside, listFiles, readJson, realpathOrSelf, writeJson } from './fsx.mjs';

export const MARKER = 'harness-build.json';
export const RECEIPT = '.agents/harness-version.json';
export const STATE_DIR = '.agents/harness-state';
export const STATE_FILE = `${STATE_DIR}/binding.json`;

// Files a host writes into an installed root that are not part of the payload; a trailing slash
// names a directory the host owns. Claude Code keeps session lockfiles in `.in_use/<pid>` and stamps
// a superseded version root with `.orphaned_at` (both observed 2026-09-07, Claude Code 2.1.x — the
// lockfile invalidated every binding). Anything else blocks binding.
export const HOST_OWNED_EXTRAS = { claude: ['.in_use/', '.orphaned_at'], codex: [] };

export function isHostOwnedExtra(host, rel) {
  return (HOST_OWNED_EXTRAS[host] ?? []).some((allowed) => allowed.endsWith('/') ? rel.startsWith(allowed) : rel === allowed);
}

export function verifyPackageRoot(root, { host, expectedName, expectedVersion, expectedSourceDigest } = {}) {
  const errors = [];
  const real = realpathOrSelf(root);
  const markerPath = path.join(real, MARKER);
  if (!fs.existsSync(markerPath)) return { ok: false, errors: [`no ${MARKER} in ${real}`], root: real };
  const marker = readJson(markerPath);
  if (marker.schema_version !== 1) errors.push('marker schema_version must be 1');
  if (host && marker.host !== host) errors.push(`marker host ${marker.host} != ${host}`);
  if (expectedName && marker.name !== expectedName) errors.push(`marker name ${marker.name} != ${expectedName}`);
  if (expectedVersion && marker.version !== expectedVersion) errors.push(`marker version ${marker.version} != ${expectedVersion}`);
  if (expectedSourceDigest && marker.source_digest !== expectedSourceDigest) errors.push('marker source_digest differs from the expected release');

  const records = [];
  for (const f of marker.files ?? []) {
    const abs = path.join(real, f.path);
    if (!isInside(real, abs)) { errors.push(`listed path escapes root: ${f.path}`); continue; }
    if (!fs.existsSync(abs)) { errors.push(`listed file missing: ${f.path}`); continue; }
    const bytes = fs.readFileSync(abs);
    if (bytes.length !== f.bytes) errors.push(`byte length changed: ${f.path}`);
    if (sha256Hex(bytes) !== f.sha256) errors.push(`content changed: ${f.path}`);
    records.push({ path: f.path, bytes });
  }
  if (records.length === (marker.files ?? []).length && recordsDigest(records) !== marker.payload_digest) {
    errors.push('payload_digest does not match the listed files');
  }
  const listed = new Set([...(marker.files ?? []).map((f) => f.path), MARKER]);
  const { files, symlinks } = listFiles(real);
  const extras = files.filter((p) => !listed.has(p) && !isHostOwnedExtra(marker.host, p));
  if (extras.length) errors.push(`unknown extra files in installed root (block): ${extras.join(', ')}`);
  if (symlinks.length) errors.push(`symlinks in installed root: ${symlinks.join(', ')}`);
  for (const [id, rel] of Object.entries(marker.skills ?? {})) {
    if (!fs.existsSync(path.join(real, rel))) errors.push(`skill entry missing: ${id} -> ${rel}`);
  }
  const nativeManifest = marker.host === 'claude' ? '.claude-plugin/plugin.json' : '.codex-plugin/plugin.json';
  const manifestPath = path.join(real, nativeManifest);
  if (!fs.existsSync(manifestPath)) errors.push(`native manifest missing: ${nativeManifest}`);
  else {
    const manifest = readJson(manifestPath);
    if (manifest.version !== marker.version) errors.push(`native manifest version ${manifest.version} != marker ${marker.version}`);
    if (manifest.name !== marker.name) errors.push(`native manifest name ${manifest.name} != marker ${marker.name}`);
  }
  for (const [id, rel] of Object.entries(marker.hooks ?? {})) {
    if (!fs.existsSync(path.join(real, rel))) errors.push(`hook target missing: ${id} -> ${rel}`);
  }
  return { ok: errors.length === 0, errors, root: real, marker, extras };
}

// Claude Code keeps a registry file; the root is read from it, never guessed from the cache layout.
export function discoverClaudeRoot({ pluginKey, homeDir = os.homedir(), projectRoot = null, registryFile = null } = {}) {
  const file = registryFile ?? path.join(homeDir, '.claude/plugins/installed_plugins.json');
  if (!fs.existsSync(file)) return { found: false, reason: `registry not found: ${file}` };
  const registry = readJson(file);
  const entries = registry.plugins?.[pluginKey] ?? [];
  const scoped = entries.filter((e) => e.scope === 'user' || (projectRoot && e.projectPath && realpathOrSelf(e.projectPath) === realpathOrSelf(projectRoot)));
  if (scoped.length === 0) return { found: false, reason: `${pluginKey} not installed for this scope`, registry: file };
  if (scoped.length > 1) {
    const roots = new Set(scoped.map((e) => e.installPath));
    if (roots.size > 1) return { found: false, reason: `ambiguous installs for ${pluginKey}: ${[...roots].join(', ')}` };
  }
  return { found: true, root: scoped[0].installPath, version: scoped[0].version, scope: scoped[0].scope, registry: file };
}

// Codex: parse the JSON printed by `codex plugin add --json` (or an operator-supplied root).
// Any path-like string field that contains a build marker counts; nothing else is inferred.
export function discoverCodexRootFromJson(json) {
  const candidates = [];
  const walk = (v) => {
    if (typeof v === 'string' && path.isAbsolute(v)) candidates.push(v);
    else if (Array.isArray(v)) v.forEach(walk);
    else if (v && typeof v === 'object') Object.values(v).forEach(walk);
  };
  walk(json);
  const roots = candidates.filter((c) => fs.existsSync(path.join(c, MARKER)));
  if (roots.length === 0) return { found: false, reason: 'no candidate path in the CLI output carries a build marker', candidates };
  if (new Set(roots.map(realpathOrSelf)).size > 1) return { found: false, reason: `ambiguous roots: ${roots.join(', ')}` };
  return { found: true, root: roots[0] };
}

// --- receipts -----------------------------------------------------------------------------------

export function readReceipt(projectRoot) {
  const p = path.join(projectRoot, RECEIPT);
  return fs.existsSync(p) ? readJson(p) : null;
}

export function readState(projectRoot) {
  const p = path.join(projectRoot, STATE_FILE);
  return fs.existsSync(p) ? readJson(p) : null;
}

function ensureStateDir(projectRoot) {
  const dir = path.join(projectRoot, STATE_DIR);
  fs.mkdirSync(dir, { recursive: true });
  const ignore = path.join(dir, '.gitignore');
  if (!fs.existsSync(ignore)) fs.writeFileSync(ignore, '# machine-local harness state: installed roots, acknowledgements, telemetry. Never commit.\n*\n');
}

// A schema-1 receipt carried the absolute root and timestamp inside the committed file.
export function isLegacyReceipt(receipt) {
  return Boolean(receipt) && receipt.schema_version === 1;
}

export function writeReceipt(projectRoot, host, binding, { consent = true, machine = os.hostname() } = {}) {
  const previous = readReceipt(projectRoot);
  const receipt = previous && !isLegacyReceipt(previous) ? previous : { schema_version: 2, name: binding.marker.name, hosts: {} };
  receipt.name = binding.marker.name;
  receipt.hosts[host] = { version: binding.marker.version, source_digest: binding.marker.source_digest, payload_digest: binding.marker.payload_digest };
  const state = readState(projectRoot) ?? { schema_version: 1, hosts: {} };
  state.hosts[host] = { ...(state.hosts[host] ?? {}), root: binding.root, payload_digest: binding.marker.payload_digest, bound_at: new Date().toISOString(), machine };
  if (!consent) return { written: false, receipt, state };
  writeJson(path.join(projectRoot, RECEIPT), receipt);
  ensureStateDir(projectRoot);
  writeJson(path.join(projectRoot, STATE_FILE), state);
  return { written: true, receipt, state };
}

// Re-validate a stored binding. The portable receipt says what is expected; the local state says
// where it is on this machine. A receipt without a local root is "expected, not bound here".
export function resolveBoundRoot(projectRoot, host) {
  const receipt = readReceipt(projectRoot);
  if (!receipt) return { ok: false, errors: [`no ${host} binding in ${RECEIPT} — bind the installed plugin first`] };
  if (isLegacyReceipt(receipt)) {
    const bound = receipt.hosts?.[host];
    if (!bound) return { ok: false, errors: [`no ${host} binding in ${RECEIPT} — bind the installed plugin first`] };
    const check = verifyPackageRoot(bound.root, { host, expectedName: bound.name, expectedVersion: bound.version });
    if (!check.ok) return { ok: false, errors: [`legacy binding for ${host} is stale on this machine (re-bind; a schema-1 receipt carried another machine's root):`, ...check.errors], migration_needed: true };
    if (check.marker.payload_digest !== bound.payload_digest) return { ok: false, errors: [`payload_digest changed since binding for ${host} — re-bind`], migration_needed: true };
    return { ok: true, root: check.root, marker: check.marker, migration_needed: true, note: 'schema-1 receipt: run profile.mjs migrate-binding --consent yes to split it into the portable receipt and the local state' };
  }
  const expected = receipt.hosts?.[host];
  if (!expected) return { ok: false, errors: [`no ${host} expectation in ${RECEIPT} — bind the installed plugin first`] };
  const local = readState(projectRoot)?.hosts?.[host];
  if (!local?.root) return { ok: false, errors: [`${RECEIPT} expects ${receipt.name} ${expected.version} for ${host} but this machine has no local binding (${STATE_FILE}) — run profile.mjs bind here; a committed receipt is not an installation`], expected };
  const check = verifyPackageRoot(local.root, { host, expectedName: receipt.name, expectedVersion: expected.version });
  if (!check.ok) return { ok: false, errors: [`binding for ${host} is stale (re-bind, do not fall back to checkout files):`, ...check.errors] };
  if (check.marker.payload_digest !== expected.payload_digest) return { ok: false, errors: [`installed ${host} package payload differs from the version the project expects (${expected.payload_digest.slice(0, 12)}…) — update the installation or re-bind deliberately`] };
  if (check.marker.source_digest !== expected.source_digest) return { ok: false, errors: [`installed ${host} package source digest differs from the expected release — re-bind deliberately`] };
  return { ok: true, root: check.root, marker: check.marker, local };
}

// Consent-gated split of a schema-1 receipt. The portable half is written from the receipt's
// identity facts; the local half only when the recorded root verifies ON THIS MACHINE — another
// machine's absolute path is never adopted as authority.
export function migrateReceipt(projectRoot, { consent = false, machine = os.hostname() } = {}) {
  const receipt = readReceipt(projectRoot);
  if (!receipt) return { ok: false, reason: 'no receipt to migrate' };
  if (!isLegacyReceipt(receipt)) return { ok: true, migrated: false, reason: 'receipt already schema 2' };
  const portable = { schema_version: 2, name: null, hosts: {} };
  const state = readState(projectRoot) ?? { schema_version: 1, hosts: {} };
  const report = [];
  for (const [host, bound] of Object.entries(receipt.hosts ?? {})) {
    portable.name = portable.name ?? bound.name;
    portable.hosts[host] = { version: bound.version, source_digest: bound.source_digest, payload_digest: bound.payload_digest };
    const check = fs.existsSync(path.join(bound.root ?? '', MARKER)) ? verifyPackageRoot(bound.root, { host, expectedName: bound.name, expectedVersion: bound.version }) : { ok: false, errors: ['root not present on this machine'] };
    if (check.ok && check.marker.payload_digest === bound.payload_digest) {
      state.hosts[host] = { root: check.root, payload_digest: bound.payload_digest, bound_at: new Date().toISOString(), machine, migrated_from: 'schema-1 receipt' };
      report.push(`${host}: local binding kept (${check.root} verifies here)`);
    } else {
      report.push(`${host}: recorded root not adopted (${check.errors[0]}) — re-bind on this machine`);
    }
  }
  if (!consent) return { ok: true, migrated: false, preview: { portable, state, report } };
  writeJson(path.join(projectRoot, RECEIPT), portable);
  ensureStateDir(projectRoot);
  writeJson(path.join(projectRoot, STATE_FILE), state);
  return { ok: true, migrated: true, portable, state, report };
}

// Operator acknowledgements live in the local state: hook trust, probes. Installed ≠ trusted.
export function hookState(projectRoot, host) {
  const local = readState(projectRoot)?.hosts?.[host];
  if (!local?.root) return { state: 'unbound', trusted: false };
  const ack = local.acknowledgements?.hooks;
  if (!ack) return { state: 'installed-untrusted', trusted: false, note: 'plugin bound; hooks not acknowledged as trusted on this machine — a present hook file is not a trusted hook' };
  return { state: ack.trusted ? 'trusted' : 'installed-untrusted', trusted: Boolean(ack.trusted), acknowledged_at: ack.acknowledged_at, by: ack.by, evidence: ack.evidence ?? null };
}

export function acknowledgeHooks(projectRoot, host, { trusted, by, evidence = null, consent = false }) {
  const state = readState(projectRoot);
  if (!state?.hosts?.[host]?.root) return { ok: false, reason: `no local ${host} binding — bind first` };
  const next = structuredClone(state);
  next.hosts[host].acknowledgements = { ...(next.hosts[host].acknowledgements ?? {}), hooks: { trusted: Boolean(trusted), by, evidence, acknowledged_at: new Date().toISOString() } };
  if (!consent) return { ok: true, written: false, preview: next.hosts[host].acknowledgements };
  writeJson(path.join(projectRoot, STATE_FILE), next);
  return { ok: true, written: true, acknowledgements: next.hosts[host].acknowledgements };
}
