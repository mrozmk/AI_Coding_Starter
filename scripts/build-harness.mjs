#!/usr/bin/env node
// Build both host packages from harness-source/ (deterministic bytes), write the native marketplace
// manifests, or export the release bundle. Usage:
//   node scripts/build-harness.mjs                      # packages/{claude,codex} + marketplaces
//   node scripts/build-harness.mjs --export dist/harness-0.1.0 [--candidate]   # --candidate: before live evidence exists
//   node scripts/build-harness.mjs --out <dir>          # build into another destination (tests)
//   node scripts/build-harness.mjs --freeze             # write docs/harness/release-candidate.json (identities the live run must match)
//   node scripts/build-harness.mjs --parity-docs        # render docs/harness/{instruction,hook}-parity.md from the ledgers
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { parseArgv } from '../harness-source/scripts/lib/argv.mjs';
import { recordsDigest } from '../harness-source/scripts/lib/digest.mjs';
import { realpathOrSelf, writeBytes } from '../harness-source/scripts/lib/fsx.mjs';
import { exportBundle } from './lib/bundle.mjs';
import { loadInventory, sourceDigestRecords, validateInventory } from './lib/inventory.mjs';
import { loadAdapterMeta, renderMarketplaces, renderPackage, writePackage } from './lib/package-build.mjs';
import { loadLedgers, renderHookParity, renderInstructionParity } from '../harness-source/scripts/lib/parity.mjs';
import { gitProvenance } from './lib/bundle.mjs';
import { requiredLiveAssertions } from './lib/smoke-live.mjs';
import { REQUIRED_CAPABILITY_ASSERTIONS, verifyCapabilities } from '../harness-source/scripts/preflight.mjs';
import { verifyReleaseEvidence } from './smoke-harness.mjs';

export function renderAll(repoRoot) {
  const { inventory, harness } = loadInventory(repoRoot);
  const errors = validateInventory(inventory, repoRoot);
  if (errors.length) throw new Error(`inventory invalid:\n  ${errors.join('\n  ')}`);
  const sourceDigest = recordsDigest(sourceDigestRecords(inventory, repoRoot));
  const rendered = {};
  for (const host of inventory.hosts) {
    rendered[host] = renderPackage({ repoRoot, inventory, harness, host, adapterMeta: loadAdapterMeta(repoRoot, host), sourceDigest });
  }
  return { inventory, harness, rendered, sourceDigest };
}

export function buildAll(repoRoot, outRoot = repoRoot) {
  const { harness, rendered, sourceDigest } = renderAll(repoRoot);
  for (const [host, pkg] of Object.entries(rendered)) writePackage(path.join(outRoot, 'packages', host), pkg);
  for (const [rel, text] of Object.entries(renderMarketplaces(harness))) writeBytes(path.join(outRoot, rel), text);
  return { rendered, sourceDigest };
}

// The candidate release: the version in harness.json (no harness release has been published —
// the starter's git tags are its own) and the exact source/payload identities the installed-host
// run (T16) must match. Any later source change makes the live evidence stale by construction.
export function freezeCandidate(repoRoot) {
  const { harness, rendered, sourceDigest } = renderAll(repoRoot);
  const candidate = {
    schema_version: 1,
    version: harness.version,
    version_basis: 'harness.json version; no harness release has been published (git tags belong to the starter), so the candidate keeps its first version',
    frozen_at: new Date().toISOString(),
    source_digest: sourceDigest,
    packages: Object.fromEntries(Object.entries(rendered).map(([h, p]) => [h, { payload_digest: p.marker.payload_digest, files: p.files.size }])),
    git: gitProvenance(repoRoot),
    note: 'Live evidence (release-readiness.json) is valid only for these identities; a changed digest requires re-validation before export.',
  };
  writeBytes(path.join(repoRoot, 'docs/harness/release-candidate.json'), `${JSON.stringify(candidate, null, 2)}\n`);
  return candidate;
}

export function renderParityDocs(repoRoot) {
  const { instructions, hooks } = loadLedgers(repoRoot);
  writeBytes(path.join(repoRoot, 'docs/harness/instruction-parity.md'), renderInstructionParity(instructions));
  writeBytes(path.join(repoRoot, 'docs/harness/hook-parity.md'), renderHookParity(hooks));
}

function main() {
  const { opts } = parseArgv(process.argv.slice(2));
  const repoRoot = path.resolve(opts.repo ?? path.join(path.dirname(fileURLToPath(import.meta.url)), '..'));
  if (opts.freeze) { const c = freezeCandidate(repoRoot); console.log(`frozen ${c.version} source ${c.source_digest}`); return; }
  if (opts['parity-docs']) { renderParityDocs(repoRoot); console.log('rendered docs/harness/instruction-parity.md and hook-parity.md'); return; }
  if (opts.export) {
    const { harness, rendered } = renderAll(repoRoot);
    const requiredAssertions = { 'release-readiness': requiredLiveAssertions(repoRoot), 'reviewer-capabilities': [...new Set(['claude', 'codex'].flatMap((h) => REQUIRED_CAPABILITY_ASSERTIONS(h)))] };
    if (!opts.candidate) {
      // A tested bundle needs passing, current evidence — integrity alone is never enough.
      const errors = [
        ...verifyReleaseEvidence(path.join(repoRoot, 'docs/harness/release-readiness.json'), { repoRoot }).map((e) => `release-readiness: ${e}`),
        ...verifyCapabilities(path.join(repoRoot, 'docs/harness/reviewer-capabilities.json'), { adaptersRootDir: path.join(repoRoot, 'harness-source/adapters'), scriptsRoot: path.join(repoRoot, 'harness-source/scripts') }).map((e) => `reviewer-capabilities: ${e}`),
      ];
      if (errors.length) throw new Error(`refusing to export a tested bundle:\n  ${errors.join('\n  ')}\n  (use --candidate for an untested bundle)`);
    }
    const { dest, release } = exportBundle({ repoRoot, destDir: path.resolve(opts.export), harness, rendered, candidate: Boolean(opts.candidate), requiredAssertions });
    console.log(`exported ${release.name} ${release.version} -> ${dest}${release.candidate ? ` (CANDIDATE — missing evidence: ${release.evidence_missing.join(', ')})` : ''}`);
    console.log(`source_digest ${release.source_digest}`);
    for (const [host, p] of Object.entries(release.packages)) console.log(`${host} payload_digest ${p.payload_digest}`);
    return;
  }
  const outRoot = opts.out ? path.resolve(opts.out) : repoRoot;
  const { rendered, sourceDigest } = buildAll(repoRoot, outRoot);
  console.log(`source_digest ${sourceDigest}`);
  for (const [host, pkg] of Object.entries(rendered)) {
    console.log(`${host}: ${pkg.files.size} files, payload_digest ${pkg.marker.payload_digest} -> ${path.join(outRoot, 'packages', host)}`);
  }
}

if (process.argv[1] && fileURLToPath(import.meta.url) === realpathOrSelf(process.argv[1])) {
  try {
    main();
  } catch (err) {
    console.error(`build-harness: ${err.message}`);
    process.exit(1);
  }
}
