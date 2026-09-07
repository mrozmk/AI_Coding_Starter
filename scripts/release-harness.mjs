#!/usr/bin/env node
// Checked publication of a harness release. The `release` branch is the marketplace channel
// (harness.json → release_ref); `main` is the working branch. Nothing is pushed unless every gate
// passes and --push yes is given; without it the two push commands are printed.
//   node scripts/release-harness.mjs [--push yes]
// Gates: clean working tree · version in harness.json is newer than on origin/<release_ref> ·
// check-harness --all (syntax, inventory, links, contracts, tests, generated).
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { parseArgv } from '../harness-source/scripts/lib/argv.mjs';
import { readJson, realpathOrSelf } from '../harness-source/scripts/lib/fsx.mjs';

export function compareSemver(a, b) {
  const pa = String(a).split('.').map(Number);
  const pb = String(b).split('.').map(Number);
  for (let i = 0; i < 3; i++) if ((pa[i] ?? 0) !== (pb[i] ?? 0)) return (pa[i] ?? 0) - (pb[i] ?? 0);
  return 0;
}

function git(repoRoot, args) {
  return spawnSync('git', ['-C', repoRoot, ...args], { encoding: 'utf8' });
}

// Version published on the release branch, or null when the branch does not exist on origin yet.
export function publishedVersion(repoRoot, ref) {
  git(repoRoot, ['fetch', '--quiet', 'origin', ref]);
  const shown = git(repoRoot, ['show', `origin/${ref}:harness-source/harness.json`]);
  if (shown.status !== 0) return null;
  try { return JSON.parse(shown.stdout).version; } catch { return null; }
}

export function releaseGates(repoRoot) {
  const harness = readJson(path.join(repoRoot, 'harness-source/harness.json'));
  const ref = harness.release_ref ?? 'release';
  const errors = [];
  const dirty = git(repoRoot, ['status', '--porcelain']).stdout.trim();
  if (dirty) errors.push(`working tree not clean:\n${dirty}`);
  const published = publishedVersion(repoRoot, ref);
  if (published !== null && compareSemver(harness.version, published) <= 0) errors.push(`harness.json version ${harness.version} is not newer than origin/${ref} (${published}) — bump it first`);
  const check = spawnSync(process.execPath, [path.join(repoRoot, 'scripts/check-harness.mjs'), '--all'], { cwd: repoRoot, encoding: 'utf8' });
  if (check.status !== 0) errors.push(`check-harness --all failed:\n${(check.stdout + check.stderr).trim()}`);
  return { ok: errors.length === 0, errors, version: harness.version, published, ref, branch: git(repoRoot, ['rev-parse', '--abbrev-ref', 'HEAD']).stdout.trim() };
}

function main() {
  const { opts } = parseArgv(process.argv.slice(2));
  const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
  const gates = releaseGates(repoRoot);
  if (!gates.ok) {
    console.error(`release-harness: not publishable\n  ${gates.errors.join('\n  ')}`);
    process.exit(1);
  }
  const pushes = [[gates.branch], [`${gates.branch}:${gates.ref}`]];
  const shown = pushes.map((refspec) => `git push origin ${refspec[0]}`);
  console.log(`harness ${gates.version} (origin/${gates.ref} has ${gates.published ?? 'nothing yet'}) — gates passed`);
  if (opts.push !== 'yes') {
    console.log(`publish with:\n  ${shown.join('\n  ')}\nor re-run with --push yes`);
    return;
  }
  for (const [refspec, label] of pushes.map((p, i) => [p[0], shown[i]])) {
    const r = spawnSync('git', ['-C', repoRoot, 'push', 'origin', refspec], { stdio: 'inherit' });
    if (r.status !== 0) { console.error(`release-harness: ${label} failed`); process.exit(1); }
  }
  console.log(`published harness ${gates.version} to origin/${gates.ref}; projects on autoUpdate adopt it at their next session start (then \`profile.mjs bind\`).`);
}

if (process.argv[1] && fileURLToPath(import.meta.url) === realpathOrSelf(process.argv[1])) main();
