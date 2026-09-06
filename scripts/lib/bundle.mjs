// Release bundle export and validation (contract 13). The bundle is a self-contained copy of both
// packages, both native marketplace manifests, harness-release.json and the sanitized evidence.
import fs from 'node:fs';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { sha256Hex } from '../../harness-source/scripts/lib/digest.mjs';
import { assertInside, isInside, listFiles, readJson, writeBytes } from '../../harness-source/scripts/lib/fsx.mjs';
import { verifyPackageRoot } from '../../harness-source/scripts/lib/locator.mjs';
import { validate } from '../../harness-source/scripts/lib/schema.mjs';
import { validateEvidence } from '../../harness-source/scripts/lib/evidence.mjs';
import { MARKER, renderMarketplaces } from './package-build.mjs';

export const RELEASE_FILE = 'harness-release.json';
export const EVIDENCE_DOCS = [
  'docs/harness/installation.md',
  'docs/harness/capabilities.md',
  'docs/harness/release-readiness.md',
  'docs/harness/reviewer-capabilities.json',
  'docs/harness/release-readiness.json',
];

const releaseSchema = {
  type: 'object',
  required: ['schema_version', 'name', 'version', 'source_digest', 'packages', 'tested_cli', 'evidence', 'git'],
  properties: {
    schema_version: { const: 1 },
    version: { type: 'string', pattern: '^\\d+\\.\\d+\\.\\d+$' },
    source_digest: { type: 'string', pattern: '^[0-9a-f]{64}$' },
    packages: {
      type: 'object', required: ['claude', 'codex'],
      properties: {
        claude: { type: 'object', required: ['path', 'payload_digest'] },
        codex: { type: 'object', required: ['path', 'payload_digest'] },
      },
    },
    evidence: { type: 'array', minItems: 1, items: { type: 'object', required: ['path', 'sha256'] } },
    git: { type: 'object', required: ['commit', 'dirty'] },
  },
};

export function gitProvenance(repoRoot) {
  const run = (args) => {
    try { return execFileSync('git', args, { cwd: repoRoot, encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }).trim(); } catch { return null; }
  };
  const commit = run(['rev-parse', 'HEAD']);
  const status = run(['status', '--porcelain']);
  return { commit, branch: run(['branch', '--show-current']), dirty: status === null ? null : status.length > 0 };
}

// `candidate: true` exports before the live run exists: evidence docs that are not there yet are
// listed under `evidence_missing`, so the bundle is usable for the installed-host validation but
// says on its face that it is untested.
export function exportBundle({ repoRoot, destDir, harness, rendered, candidate = false, requiredAssertions = {} }) {
  const dest = path.resolve(destDir);
  if (fs.existsSync(dest)) {
    const { files } = listFiles(dest);
    const owned = fs.existsSync(path.join(dest, RELEASE_FILE));
    if (files.length && !owned) throw new Error(`refusing to export into non-empty ${dest} without a ${RELEASE_FILE}`);
    fs.rmSync(dest, { recursive: true, force: true });
  }
  fs.mkdirSync(dest, { recursive: true });
  const packages = {};
  for (const [host, pkg] of Object.entries(rendered)) {
    const pkgDir = path.join(dest, 'packages', host);
    for (const [p, bytes] of pkg.files) {
      const abs = path.join(pkgDir, p);
      writeBytes(abs, bytes);
      assertInside(dest, abs, 'bundle output');
    }
    writeBytes(path.join(pkgDir, MARKER), `${JSON.stringify(pkg.marker, null, 2)}\n`);
    packages[host] = { path: `packages/${host}`, payload_digest: pkg.marker.payload_digest };
  }
  for (const [p, text] of Object.entries(renderMarketplaces(harness))) writeBytes(path.join(dest, p), text);
  const evidence = [];
  const evidenceMissing = [];
  for (const rel of EVIDENCE_DOCS) {
    const src = path.join(repoRoot, rel);
    // A candidate carries no live evidence at all: whatever exists belongs to earlier bytes.
    const live = /release-readiness|reviewer-capabilities/.test(rel);
    if (!fs.existsSync(src) || (candidate && live)) {
      if (!candidate) throw new Error(`bundle export needs ${rel} — produce it first (live run), or export with --candidate`);
      evidenceMissing.push(rel);
      continue;
    }
    const bytes = fs.readFileSync(src);
    writeBytes(path.join(dest, rel), bytes);
    evidence.push({ path: rel, sha256: sha256Hex(bytes) });
  }
  const release = {
    schema_version: 1,
    name: harness.name,
    version: harness.version,
    source_digest: rendered.claude.marker.source_digest,
    packages,
    tested_cli: harness.runtime,
    evidence,
    required_assertions: requiredAssertions,
    ...(candidate ? { candidate: true, evidence_missing: evidenceMissing, note: 'CANDIDATE bundle: not validated on an installed host; the listed evidence does not exist yet' } : {}),
    git: gitProvenance(repoRoot),
  };
  writeBytes(path.join(dest, RELEASE_FILE), `${JSON.stringify(release, null, 2)}\n`);
  return { dest, release };
}

export function validateBundle(bundleDir) {
  const dir = path.resolve(bundleDir);
  const errors = [];
  const releasePath = path.join(dir, RELEASE_FILE);
  if (!fs.existsSync(releasePath)) return [`no ${RELEASE_FILE} in ${dir}`];
  const release = readJson(releasePath);
  errors.push(...validate(releaseSchema, release));
  if (errors.length) return errors;
  for (const [host, pkg] of Object.entries(release.packages)) {
    const root = path.join(dir, pkg.path);
    if (!fs.existsSync(root)) { errors.push(`${host}: package path missing ${pkg.path}`); continue; }
    const check = verifyPackageRoot(root, { host, expectedName: release.name, expectedVersion: release.version, expectedSourceDigest: release.source_digest });
    errors.push(...check.errors.map((e) => `${host}: ${e}`));
    if (check.marker && check.marker.payload_digest !== pkg.payload_digest) errors.push(`${host}: release payload_digest != marker`);
  }
  const claudeMp = path.join(dir, '.claude-plugin/marketplace.json');
  const codexMp = path.join(dir, '.agents/plugins/marketplace.json');
  for (const [p, getSource] of [[claudeMp, (e) => e.source], [codexMp, (e) => e.source?.path]]) {
    if (!fs.existsSync(p)) { errors.push(`marketplace manifest missing: ${path.relative(dir, p)}`); continue; }
    const mp = readJson(p);
    for (const entry of mp.plugins ?? []) {
      const src = getSource(entry);
      if (typeof src !== 'string' || !src.startsWith('./')) { errors.push(`${entry.name}: marketplace source must be a ./ relative path`); continue; }
      const abs = path.join(dir, src);
      if (!fs.existsSync(abs)) errors.push(`${entry.name}: marketplace source ${src} does not resolve inside the bundle`);
      else if (!isInside(dir, abs)) errors.push(`${entry.name}: marketplace source escapes the bundle`);
      if (entry.name !== release.name) errors.push(`marketplace plugin name ${entry.name} != ${release.name}`);
    }
  }
  for (const ev of release.evidence) {
    const abs = path.join(dir, ev.path);
    if (!fs.existsSync(abs)) { errors.push(`evidence missing: ${ev.path}`); continue; }
    if (sha256Hex(fs.readFileSync(abs)) !== ev.sha256) { errors.push(`evidence hash mismatch: ${ev.path}`); continue; }
    if (!ev.path.endsWith('.json') || release.candidate) continue;
    // Integrity is not success: a bundle that ships failed or stale evidence is not a tested bundle.
    let doc;
    try { doc = readJson(abs); } catch (e) { errors.push(`evidence unreadable: ${ev.path}: ${e.message}`); continue; }
    const kind = ev.path.includes('release-readiness') ? 'release-readiness' : ev.path.includes('reviewer-capabilities') ? 'reviewer-capabilities' : null;
    const expectedInputs = kind === 'release-readiness' ? { source_digest: release.source_digest, 'packages.claude.payload_digest': release.packages.claude.payload_digest, 'packages.codex.payload_digest': release.packages.codex.payload_digest } : {};
    errors.push(...validateEvidence(doc, { kind, mode: 'live', expectedInputs, requiredAssertions: (release.required_assertions?.[kind] ?? []) }).map((e) => `${ev.path}: ${e}`));
    if (!release.candidate && !doc.assertions?.some((a) => a.required)) errors.push(`${ev.path}: no required assertion at all`);
  }
  if (release.candidate) errors.push('CANDIDATE bundle: not validated on an installed host — not a release');
  return errors;
}
