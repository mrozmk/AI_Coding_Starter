#!/usr/bin/env node
// Offline quality gate for the harness source. Modes (combine freely):
//   --inventory   schema, ids, dependencies, ownership, legacy classification coverage
//   --syntax      node --check on every .mjs, JSON parse, SKILL.md frontmatter, TOML shape
//   --links       every inventory source exists; Markdown links and import specifiers resolve
//   --generated   packages/ and marketplace manifests match a fresh render byte for byte
//   --tests       node --test over tests/harness with nonzero counts
//   --contracts   parity ledgers (instruction + hook) validate with nonzero counts; scenarios resolve
//   --all         syntax + inventory + links + contracts + tests + generated
//   --bundle <dir>  validate an exported release bundle (contract 13)
// Never launches a model or installs anything.
import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { parseArgv } from '../harness-source/scripts/lib/argv.mjs';
import { parseFrontmatter } from '../harness-source/scripts/lib/frontmatter.mjs';
import { listFiles, readJson, realpathOrSelf } from '../harness-source/scripts/lib/fsx.mjs';
import { renderAll } from './build-harness.mjs';
import { validateBundle } from './lib/bundle.mjs';
import { loadInventory, unclaimedSources, validateInventory } from './lib/inventory.mjs';
import { diffPackage, renderMarketplaces } from './lib/package-build.mjs';
import { checkParity } from '../harness-source/scripts/lib/parity.mjs';

const TEST_DIR = 'tests/harness';

export function checkInventory(repoRoot) {
  const { inventory } = loadInventory(repoRoot);
  const errors = validateInventory(inventory, repoRoot);
  for (const p of unclaimedSources(inventory, repoRoot)) errors.push(`file under harness-source/ not claimed by any inventory entry: ${p}`);
  return errors;
}

export function checkSyntax(repoRoot) {
  const errors = [];
  const mjs = [];
  for (const dir of ['harness-source', 'scripts', TEST_DIR]) {
    for (const f of listFiles(path.join(repoRoot, dir)).files) {
      const rel = path.posix.join(dir, f);
      if (rel.endsWith('.mjs')) mjs.push(rel);
      if (rel.endsWith('.json')) {
        try { readJson(path.join(repoRoot, rel)); } catch (e) { errors.push(`${rel}: ${e.message}`); }
      }
      if (rel.endsWith('SKILL.md')) {
        try {
          const { data } = parseFrontmatter(fs.readFileSync(path.join(repoRoot, rel), 'utf8'));
          if (!data.name || !data.description) errors.push(`${rel}: frontmatter needs name and description`);
          if (data.name && !/^[a-z][a-z0-9-]*$/.test(data.name)) errors.push(`${rel}: name must be flat kebab-case`);
        } catch (e) { errors.push(`${rel}: ${e.message}`); }
      }
      if (rel.endsWith('.toml')) {
        for (const [i, line] of fs.readFileSync(path.join(repoRoot, rel), 'utf8').split('\n').entries()) {
          if (line.trim() && !/^\s*(#|\[[^\]]+\]\s*$|[A-Za-z0-9_.-]+\s*=)/.test(line)) errors.push(`${rel}:${i + 1}: not a TOML key/table/comment line`);
        }
      }
    }
  }
  for (const rel of mjs) {
    const r = spawnSync(process.execPath, ['--check', rel], { cwd: repoRoot, encoding: 'utf8' });
    if (r.status !== 0) errors.push(`${rel}: ${r.stderr.trim().split('\n').slice(-1)[0]}`);
  }
  return errors;
}

export function checkLinks(repoRoot) {
  const errors = [];
  const { inventory } = loadInventory(repoRoot);
  for (const e of inventory.entries) {
    if (e.source && !fs.existsSync(path.join(repoRoot, e.source))) errors.push(`${e.id}: source missing ${e.source}`);
  }
  const { files } = listFiles(path.join(repoRoot, 'harness-source'));
  for (const f of files) {
    const rel = path.posix.join('harness-source', f);
    const text = fs.readFileSync(path.join(repoRoot, rel), 'utf8');
    // Memory templates are copied into a project and link project-relative; they resolve there, not here.
    if (rel.endsWith('.md') && !rel.startsWith('harness-source/templates/memory/')) {
      // Fenced blocks hold examples (a plan's own table shape), not links this repo must resolve.
      for (const m of text.replace(/```[\s\S]*?```/g, '').matchAll(/\]\(([^)\s]+)\)/g)) {
        const target = m[1].split('#')[0];
        if (!target || /^[a-z]+:/.test(target)) continue;
        const abs = path.resolve(repoRoot, path.dirname(rel), target);
        if (!fs.existsSync(abs)) errors.push(`${rel}: broken link ${m[1]}`);
        else if (path.relative(path.join(repoRoot, 'harness-source'), abs).startsWith('..')) errors.push(`${rel}: link leaves harness-source/: ${m[1]}`);
      }
      // Package-relative pointers used by skills: `references/x.md`, `templates/x.md`, `scripts/x.mjs`.
      for (const m of text.matchAll(/`((?:references|templates|schemas|scripts)\/[A-Za-z0-9_./-]+)`/g)) {
        if (!fs.existsSync(path.join(repoRoot, 'harness-source', m[1]))) errors.push(`${rel}: packaged path does not exist in harness-source/: ${m[1]}`);
      }
    }
    if (rel.endsWith('.mjs')) {
      for (const m of text.matchAll(/from\s+'(\.[^']+)'/g)) {
        if (!fs.existsSync(path.resolve(repoRoot, path.dirname(rel), m[1]))) errors.push(`${rel}: import does not resolve ${m[1]}`);
      }
    }
  }
  return errors;
}

export function checkGenerated(repoRoot) {
  const errors = [];
  const { harness, rendered } = renderAll(repoRoot);
  for (const [host, pkg] of Object.entries(rendered)) {
    const pkgDir = path.join(repoRoot, 'packages', host);
    if (!fs.existsSync(pkgDir)) { errors.push(`${host}: packages/${host} not built`); continue; }
    errors.push(...diffPackage(pkgDir, pkg).map((d) => `${host}: ${d}`));
  }
  for (const [rel, text] of Object.entries(renderMarketplaces(harness))) {
    const abs = path.join(repoRoot, rel);
    if (!fs.existsSync(abs)) errors.push(`${rel} missing`);
    else if (fs.readFileSync(abs, 'utf8') !== text) errors.push(`${rel} differs from render`);
  }
  return errors;
}

export function checkContracts(repoRoot) {
  const { errors, counts } = checkParity(repoRoot);
  if (counts.instructions === 0 || counts.hooks === 0) errors.push('parity ledgers are empty — zero checks is not a pass');
  const scenarios = readJson(path.join(repoRoot, 'harness-source/contracts/hook-scenarios.json')).scenarios;
  if (!scenarios.length) errors.push('no hook scenarios defined');
  return { errors, counts: { ...counts, scenarios: scenarios.length } };
}

export function runTests(repoRoot, files = null) {
  const targets = files ?? listFiles(path.join(repoRoot, TEST_DIR)).files.filter((f) => f.endsWith('.test.mjs')).map((f) => path.posix.join(TEST_DIR, f));
  if (targets.length === 0) return { errors: ['no test files found'], counts: null };
  const r = spawnSync(process.execPath, ['--test', '--test-reporter=tap', ...targets], { cwd: repoRoot, encoding: 'utf8' });
  const num = (label) => Number((r.stdout.match(new RegExp(`^# ${label} (\\d+)`, 'm')) ?? [])[1] ?? NaN);
  const counts = { tests: num('tests'), pass: num('pass'), fail: num('fail') };
  const errors = [];
  if (!Number.isFinite(counts.tests) || counts.tests === 0) errors.push(`test runner reported no tests (exit ${r.status})`);
  if (counts.fail > 0 || r.status !== 0) {
    errors.push(`tests failed: ${counts.fail} of ${counts.tests} (exit ${r.status})`);
    errors.push(...r.stdout.split('\n').filter((l) => /^not ok|^\s+(error|failureType|message):/.test(l)).slice(0, 40));
  }
  return { errors, counts, files: targets };
}

function main() {
  const { opts } = parseArgv(process.argv.slice(2));
  const repoRoot = path.resolve(opts.repo ?? path.join(path.dirname(fileURLToPath(import.meta.url)), '..'));
  const report = [];
  let failed = false;
  const run = (label, fn) => {
    const errors = fn();
    report.push(`${errors.length ? 'FAIL' : 'OK  '} ${label}${errors.length ? `\n  ${errors.join('\n  ')}` : ''}`);
    if (errors.length) failed = true;
  };
  if (opts.bundle) {
    run(`bundle ${opts.bundle}`, () => validateBundle(path.resolve(opts.bundle)));
  }
  const all = Boolean(opts.all);
  if (all || opts.syntax) run('syntax', () => checkSyntax(repoRoot));
  if (all || opts.inventory) run('inventory', () => checkInventory(repoRoot));
  if (all || opts.links) run('links', () => checkLinks(repoRoot));
  if (all || opts.contracts) {
    const { errors, counts } = checkContracts(repoRoot);
    run(`contracts (${counts.instructions} instructions, ${counts.hooks} hooks, ${counts.scenarios} scenarios)`, () => errors);
  }
  if (all || opts.tests) {
    const { errors, counts, files } = runTests(repoRoot);
    run(`tests (${counts?.tests ?? 0} tests, ${counts?.pass ?? 0} pass, ${counts?.fail ?? 0} fail, ${files?.length ?? 0} files)`, () => errors);
  }
  if (all || opts.generated) run('generated', () => checkGenerated(repoRoot));
  if (report.length === 0) {
    console.error('check-harness: pick a mode (--inventory --syntax --links --contracts --generated --tests --all --bundle <dir>)');
    process.exit(2);
  }
  console.log(report.join('\n'));
  process.exit(failed ? 1 : 0);
}

if (process.argv[1] && fileURLToPath(import.meta.url) === realpathOrSelf(process.argv[1])) {
  try {
    main();
  } catch (err) {
    console.error(`check-harness: ${err.message}`);
    process.exit(1);
  }
}
