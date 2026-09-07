#!/usr/bin/env node
// Build both host packages from harness-source/ (deterministic bytes), write the native marketplace
// manifests, or export the release bundle. Usage:
//   node scripts/build-harness.mjs                      # packages/{claude,codex} + marketplaces
//   node scripts/build-harness.mjs --export dist/harness-0.1.1   # bundle; harness-release.json says whether live evidence is verified
//   node scripts/build-harness.mjs --out <dir>          # build into another destination (tests)
//   node scripts/build-harness.mjs --parity-docs        # render docs/harness/{instruction,hook}-parity.md from the ledgers
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { parseArgv } from '../harness-source/scripts/lib/argv.mjs';
import { recordsDigest } from '../harness-source/scripts/lib/digest.mjs';
import { realpathOrSelf, writeBytes } from '../harness-source/scripts/lib/fsx.mjs';
import { exportBundle } from './lib/bundle.mjs';
import { loadInventory, sourceDigestRecords, validateInventory } from './lib/inventory.mjs';
import { loadAdapterMeta, renderMarketplaces, renderPackage, writePackage } from './lib/package-build.mjs';
import { loadLedgers, renderHookParity, renderInstructionParity } from '../harness-source/scripts/lib/parity.mjs';
import { verifyCapabilities } from '../harness-source/scripts/preflight.mjs';
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

// Live evidence is current when both files exist and name the digests of the bytes being
// exported. Pass/fail inside them is a report; only currency decides whether they ship.
export function verifyLiveEvidence(repoRoot) {
  const errors = [];
  const rr = path.join(repoRoot, 'docs/harness/release-readiness.json');
  const rc = path.join(repoRoot, 'docs/harness/reviewer-capabilities.json');
  if (!fs.existsSync(rr)) errors.push('release-readiness: missing');
  else errors.push(...verifyReleaseEvidence(rr, { repoRoot }).map((e) => `release-readiness: ${e}`));
  if (!fs.existsSync(rc)) errors.push('reviewer-capabilities: missing');
  else errors.push(...verifyCapabilities(rc, { adaptersRootDir: path.join(repoRoot, 'harness-source/adapters'), scriptsRoot: path.join(repoRoot, 'harness-source/scripts') }).map((e) => `reviewer-capabilities: ${e}`));
  return errors;
}

export function renderParityDocs(repoRoot) {
  const { instructions, hooks } = loadLedgers(repoRoot);
  writeBytes(path.join(repoRoot, 'docs/harness/instruction-parity.md'), renderInstructionParity(instructions));
  writeBytes(path.join(repoRoot, 'docs/harness/hook-parity.md'), renderHookParity(hooks));
}

function main() {
  const { opts } = parseArgv(process.argv.slice(2));
  const repoRoot = path.resolve(opts.repo ?? path.join(path.dirname(fileURLToPath(import.meta.url)), '..'));
  if (opts['parity-docs']) { renderParityDocs(repoRoot); console.log('rendered docs/harness/instruction-parity.md and hook-parity.md'); return; }
  if (opts.export) {
    const { harness, rendered } = renderAll(repoRoot);
    const evidenceErrors = verifyLiveEvidence(repoRoot);
    const { dest, release } = exportBundle({ repoRoot, destDir: path.resolve(opts.export), harness, rendered, evidenceCurrent: evidenceErrors.length === 0 });
    console.log(`exported ${release.name} ${release.version} -> ${dest} (live evidence ${release.evidence_current ? 'current, shipped' : `not current for these bytes, not shipped: ${evidenceErrors.slice(0, 3).join('; ')}${evidenceErrors.length > 3 ? ` … +${evidenceErrors.length - 3}` : ''}`})`);
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
