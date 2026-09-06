#!/usr/bin/env node
// Installed-cache smoke for the harness packages.
//   --offline                         package bytes, marketplace paths, namespaces/metadata, mocked
//                                     installation + locator contracts, scripts running from a copy
//                                     with no checkout access. Installs nothing, uses no account.
//   --live [--bundle <dir>] [--install] [--claude-root <dir>] [--codex-root <dir>] --receipts-dir <dir>
//                                     operator-assisted installed-host suite (scripts/lib/smoke-live.mjs)
//   --verify-evidence <json> [--receipts <dir>]
//                                     validate release-readiness evidence offline
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { parseArgv } from '../harness-source/scripts/lib/argv.mjs';
import { validateEvidence, verifyReceipts } from '../harness-source/scripts/lib/evidence.mjs';
import { listFiles, readJson, realpathOrSelf } from '../harness-source/scripts/lib/fsx.mjs';
import { discoverClaudeRoot, discoverCodexRootFromJson, resolveBoundRoot, verifyPackageRoot, writeReceipt } from '../harness-source/scripts/lib/locator.mjs';
import { parseFrontmatter } from '../harness-source/scripts/lib/frontmatter.mjs';
import { renderAll } from './build-harness.mjs';
import { diffPackage } from './lib/package-build.mjs';
import { requiredLiveAssertions, runLiveSmoke } from './lib/smoke-live.mjs';

const FIXTURE_PROJECT = 'tests/harness/fixtures/projects/legacy-profile';

function check(results, name, ok, detail) {
  results.push({ name, ok, detail });
}

export function offlineSmoke(repoRoot) {
  const results = [];
  const { harness, rendered } = renderAll(repoRoot);
  for (const host of ['claude', 'codex']) {
    const pkgDir = path.join(repoRoot, 'packages', host);
    const drift = fs.existsSync(pkgDir) ? diffPackage(pkgDir, rendered[host]) : ['not built'];
    check(results, `${host}:package-bytes-match-render`, drift.length === 0, drift.join('; ') || 'identical');
    if (drift.length) continue;
    const root = verifyPackageRoot(pkgDir, { host, expectedName: harness.name, expectedVersion: harness.version });
    check(results, `${host}:marker-payload-identity`, root.ok, root.errors.join('; ') || `payload ${root.marker.payload_digest.slice(0, 12)}…`);
    checkNamespaces(results, host, pkgDir, harness);
    checkLeakage(results, host, pkgDir);
    checkScriptsFromCopy(results, host, pkgDir, repoRoot);
    checkLocator(results, host, pkgDir, harness);
  }
  checkMarketplaces(results, repoRoot, harness);
  return results;
}

function checkNamespaces(results, host, pkgDir, harness) {
  const manifestRel = host === 'claude' ? '.claude-plugin/plugin.json' : '.codex-plugin/plugin.json';
  const manifest = readJson(path.join(pkgDir, manifestRel));
  check(results, `${host}:native-manifest`, manifest.name === harness.name && manifest.version === harness.version && manifest.skills === './skills/', JSON.stringify(manifest));
  if (host === 'codex') check(results, 'codex:manifest-only-documented-fields', Object.keys(manifest).sort().join(',') === 'description,name,skills,version', Object.keys(manifest).join(','));
  const skillsDir = path.join(pkgDir, 'skills');
  const problems = [];
  for (const dir of fs.readdirSync(skillsDir)) {
    const skill = path.join(skillsDir, dir, 'SKILL.md');
    if (!fs.existsSync(skill)) { problems.push(`${dir}: no SKILL.md`); continue; }
    const { data } = parseFrontmatter(fs.readFileSync(skill, 'utf8'));
    if (data.name !== dir || !/^[a-z][a-z0-9-]*$/.test(dir)) problems.push(`${dir}: name ${data.name}`);
    if (host === 'claude' && data['disable-model-invocation'] !== true) problems.push(`${dir}: model invocation not disabled`);
    if (host === 'codex') {
      const yaml = path.join(skillsDir, dir, 'agents/openai.yaml');
      if (!fs.existsSync(yaml) || !/allow_implicit_invocation: false/.test(fs.readFileSync(yaml, 'utf8'))) problems.push(`${dir}: implicit invocation not disabled`);
    }
  }
  check(results, `${host}:skill-namespaces-and-invocation-metadata`, problems.length === 0, problems.join('; ') || `${fs.readdirSync(skillsDir).length} skills, flat kebab ids, user-invoked only`);
}

function checkLeakage(results, host, pkgDir) {
  const { files, symlinks } = listFiles(pkgDir);
  const bad = [];
  for (const rel of files) {
    if (/(^|\/)\.env/.test(rel) || /secret|credential|\.pem$|\.key$/i.test(rel)) bad.push(`${rel}: secret-looking file`);
    if (!/\.(md|mjs|json|yaml|toml)$/.test(rel)) continue;
    const text = fs.readFileSync(path.join(pkgDir, rel), 'utf8');
    if (/\/Users\/|\/home\/[a-z]/.test(text)) bad.push(`${rel}: machine path`);
    if (/\.\.\/\.\.\/harness-source\//.test(text) && !/never|Never|not/.test(text.split('../../harness-source/')[0].slice(-80))) bad.push(`${rel}: checkout dependency`);
    if (/\bPoezja\b|\bDent\b|\bpatient|\bpacjent/i.test(text)) bad.push(`${rel}: project data`);
  }
  if (symlinks.length) bad.push(`symlinks: ${symlinks.join(', ')}`);
  check(results, `${host}:no-leakage`, bad.length === 0, bad.join('; ') || `${files.length} files clean`);
}

// Copy the package to a temp dir named like an install cache and run its scripts from there with cwd
// elsewhere — proves the scripts resolve lib/, schemas/ and skills/ relative to themselves.
function checkScriptsFromCopy(results, host, pkgDir, repoRoot) {
  const cache = fs.mkdtempSync(path.join(os.tmpdir(), `harness-cache-${host}-`));
  const installed = path.join(cache, 'ai-coding-starter', 'harness', '0.1.0');
  fs.cpSync(pkgDir, installed, { recursive: true });
  const project = fs.mkdtempSync(path.join(os.tmpdir(), 'harness smoke project-'));
  fs.cpSync(path.join(repoRoot, FIXTURE_PROJECT), project, { recursive: true });
  fs.mkdirSync(path.join(project, '.agents/specs'), { recursive: true });
  fs.writeFileSync(path.join(project, '.agents/specs/s.md'), '# Design: S\n\n**Status:** Draft\n\n## Summary\n\nsynthetic\n');
  const run = (args) => spawnSync(process.execPath, args, { cwd: os.tmpdir(), encoding: 'utf8', env: { ...process.env, HARNESS_REVIEW_DEPTH: '' } });
  const syntax = listFiles(installed).files.filter((f) => f.endsWith('.mjs')).map((f) => [f, run(['--check', path.join(installed, f)])]).filter(([, r]) => r.status !== 0);
  check(results, `${host}:installed-scripts-syntax`, syntax.length === 0, syntax.map(([f, r]) => `${f}: ${r.stderr.trim().split('\n').at(-1)}`).join('; ') || 'all .mjs parse from the installed copy');
  const read = run([path.join(installed, 'scripts/profile.mjs'), 'read', '--project-root', project]);
  check(results, `${host}:installed-profile-read`, read.status === 0 && /"kind": "legacy"/.test(read.stdout), read.stderr.trim() || 'legacy profile read from the installed copy');
  const pack = run([path.join(installed, 'scripts/context-pack.mjs'), '--project-root', project, '--plugin-root', installed, '--artifact', '.agents/specs/s.md']);
  check(results, `${host}:installed-context-pack`, pack.status === 0 && pack.stdout.includes('role=prime path=plugin:skills/prime/SKILL.md'), pack.stderr.trim() || 'pack built from the installed copy with the packaged prime');
  const bind = run([path.join(installed, 'scripts/profile.mjs'), 'bind', '--project-root', project, '--host', host, '--plugin-root', installed]);
  const version = run([path.join(installed, 'scripts/profile.mjs'), 'check-version', '--project-root', project, '--host', host, '--plugin-root', installed]);
  check(results, `${host}:installed-bind-and-check-version`, bind.status === 0 && version.status === 0, `${bind.stderr.trim()} ${version.stderr.trim()}`.trim() || 'bound and re-verified from the installed copy');
  const checkoutRoot = run([path.join(installed, 'scripts/profile.mjs'), 'check-version', '--project-root', project, '--host', host, '--plugin-root', repoRoot]);
  check(results, `${host}:checkout-is-not-an-installation`, checkoutRoot.status !== 0, checkoutRoot.status !== 0 ? 'checkout root refused' : 'checkout root accepted (defect)');
  const manifest = path.join(installed, 'hooks/hooks.json');
  const runner = path.join(installed, 'scripts/hook-runner.mjs');
  check(results, `${host}:installed-hooks-manifest`, fs.existsSync(manifest) && fs.existsSync(runner) && fs.existsSync(path.join(installed, 'hooks/core/commit.mjs')), 'hooks/hooks.json + scripts/hook-runner.mjs + hooks/core present in the installed copy');
  const hookRun = spawnSync(process.execPath, [runner, '--host', host, '--hook', 'guard-comments'], { cwd: project, encoding: 'utf8', input: JSON.stringify({ hook_event_name: 'PostToolUse', session_id: 's', tool_name: host === 'codex' ? 'apply_patch' : 'Write', tool_input: host === 'codex' ? { command: '*** Begin Patch\n*** Add File: src/a.ts\n+x\n*** End Patch' } : { file_path: path.join(project, 'src/a.ts'), content: 'x' } }), env: { ...process.env, CLAUDE_PROJECT_DIR: project } });
  check(results, `${host}:installed-hook-runner-dormant-by-default`, hookRun.status === 0 && /dormant/.test(hookRun.stderr), `${hookRun.stderr.trim().split('\n')[0] || 'no state reported'} (no config in the fixture → dormant, never silent)`);
}

function checkLocator(results, host, pkgDir, harness) {
  const home = fs.mkdtempSync(path.join(os.tmpdir(), 'harness-home-'));
  const cacheRoot = path.join(home, '.claude/plugins/cache/ai-coding-starter/harness', harness.version);
  fs.cpSync(pkgDir, cacheRoot, { recursive: true });
  if (host === 'claude') {
    const registry = path.join(home, '.claude/plugins/installed_plugins.json');
    fs.writeFileSync(registry, JSON.stringify({ version: 2, plugins: { 'harness@ai-coding-starter': [{ scope: 'user', installPath: cacheRoot, version: harness.version }] } }));
    const found = discoverClaudeRoot({ pluginKey: 'harness@ai-coding-starter', homeDir: home });
    check(results, 'claude:locator-registry-discovery', found.found && found.root === cacheRoot, found.reason ?? `root from registry: ${found.root}`);
    const missing = discoverClaudeRoot({ pluginKey: 'other@market', homeDir: home });
    check(results, 'claude:locator-refuses-unknown-plugin', !missing.found, missing.reason);
  } else {
    const found = discoverCodexRootFromJson({ plugin: 'harness', install: { path: cacheRoot, marketplace: 'ai-coding-starter' } });
    check(results, 'codex:locator-json-discovery', found.found && found.root === cacheRoot, found.reason ?? `root from CLI JSON: ${found.root}`);
    const none = discoverCodexRootFromJson({ plugin: 'harness', path: os.tmpdir() });
    check(results, 'codex:locator-refuses-markerless-root', !none.found, none.reason);
  }
  const project = fs.mkdtempSync(path.join(os.tmpdir(), 'harness-locator-project-'));
  const verified = verifyPackageRoot(cacheRoot, { host, expectedName: harness.name, expectedVersion: harness.version });
  writeReceipt(project, host, verified);
  const bound = resolveBoundRoot(project, host);
  const moved = path.join(home, 'moved');
  fs.renameSync(cacheRoot, moved);
  const stale = resolveBoundRoot(project, host);
  fs.renameSync(moved, cacheRoot);
  fs.writeFileSync(path.join(cacheRoot, 'stray.txt'), 'x');
  const extra = verifyPackageRoot(cacheRoot, { host });
  check(results, `${host}:locator-binding-lifecycle`, bound.ok && !stale.ok && !extra.ok, `bound=${bound.ok} moved→invalid=${!stale.ok} unknown-extra→blocked=${!extra.ok}`);
}

function checkMarketplaces(results, repoRoot, harness) {
  const claude = readJson(path.join(repoRoot, '.claude-plugin/marketplace.json'));
  const codex = readJson(path.join(repoRoot, '.agents/plugins/marketplace.json'));
  const cOk = claude.name === harness.marketplace_name && claude.plugins[0].name === harness.name && claude.plugins[0].source === './packages/claude' && fs.existsSync(path.join(repoRoot, claude.plugins[0].source, '.claude-plugin/plugin.json'));
  const xOk = codex.name === harness.marketplace_name && codex.plugins[0].name === harness.name && codex.plugins[0].source.source === 'local' && fs.existsSync(path.join(repoRoot, codex.plugins[0].source.path, '.codex-plugin/plugin.json'));
  check(results, 'marketplaces:relative-paths-resolve', cOk && xOk, `claude ${cOk} codex ${xOk} (both named ${harness.marketplace_name})`);
  const validate = spawnSync('claude', ['plugin', 'validate', path.join(repoRoot, 'packages/claude')], { encoding: 'utf8', timeout: 60_000 });
  check(results, 'claude:native-validate', validate.status === 0, validate.status === null ? 'claude CLI not available (not-run)' : (validate.stdout + validate.stderr).trim().split('\n').slice(-2).join(' | '));
  const validateMp = spawnSync('claude', ['plugin', 'validate', repoRoot], { encoding: 'utf8', timeout: 60_000 });
  check(results, 'claude:native-validate-marketplace', validateMp.status === 0, validateMp.status === null ? 'claude CLI not available (not-run)' : (validateMp.stdout + validateMp.stderr).trim().split('\n').slice(-2).join(' | '));
}

export function verifyReleaseEvidence(file, { repoRoot, receiptsDir = null }) {
  const evidence = readJson(file);
  const { rendered, sourceDigest } = renderAll(repoRoot);
  const errors = validateEvidence(evidence, {
    kind: 'release-readiness', mode: 'live', requiredAssertions: requiredLiveAssertions(repoRoot),
    expectedInputs: { source_digest: sourceDigest, 'packages.claude.payload_digest': rendered.claude.marker.payload_digest, 'packages.codex.payload_digest': rendered.codex.marker.payload_digest },
  });
  if (receiptsDir) errors.push(...verifyReceipts(evidence, receiptsDir));
  return errors;
}

function printResults(results) {
  for (const r of results) console.log(`${r.ok ? 'PASS' : 'FAIL'}  ${r.name} — ${r.detail}`);
  const failed = results.filter((r) => !r.ok);
  console.log(`\n${results.length} checks, ${failed.length} failed`);
  return failed.length === 0;
}

async function main() {
  const { opts } = parseArgv(process.argv.slice(2));
  const repoRoot = path.resolve(opts.repo ?? path.join(path.dirname(fileURLToPath(import.meta.url)), '..'));
  if (opts.offline) {
    process.exit(printResults(offlineSmoke(repoRoot)) ? 0 : 1);
  }
  if (opts['verify-evidence']) {
    const errors = verifyReleaseEvidence(path.resolve(opts['verify-evidence']), { repoRoot, receiptsDir: opts.receipts ? path.resolve(opts.receipts) : null });
    console.log(errors.length ? `FAIL release evidence\n  ${errors.join('\n  ')}` : `OK   release evidence ${opts['verify-evidence']} binds the current source and package digests`);
    process.exit(errors.length ? 1 : 0);
  }
  if (opts.live) {
    const { passed } = await runLiveSmoke({ repoRoot, opts });
    process.exit(passed ? 0 : 1);
  }
  console.error('smoke-harness: use --offline | --live … | --verify-evidence <json>');
  process.exit(2);
}

if (process.argv[1] && fileURLToPath(import.meta.url) === realpathOrSelf(process.argv[1])) {
  main().catch((err) => { console.error(`smoke-harness: ${err.message}`); process.exit(1); });
}
