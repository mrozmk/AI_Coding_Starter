// Tests of the coding-standards generation chain: the deterministic config/CI scan
// (standards-tools.mjs), the verifying renderer (coding-standards-render.mjs) and the map-codebase
// workflow run under a stub harness. Scripts are imported inside each test, so the scanner tests run
// before the renderer exists.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(HERE, '../../..');
const FIX = path.join(HERE, 'fixtures/coding-standards');
const REPO = path.join(FIX, 'repo');
const SEED = path.join(ROOT, '.agents/reference/coding-standards.md.example');
const SCANNER = path.join(ROOT, '.claude/lib/standards-tools.mjs');
const RENDERER = path.join(ROOT, '.claude/lib/coding-standards-render.mjs');
const WORKFLOW = path.join(ROOT, '.claude/workflows/map-codebase.js');

const scanner = () => import(SCANNER);
const renderer = () => import(RENDERER);
const json = (f) => JSON.parse(fs.readFileSync(path.join(FIX, f), 'utf8'));

function listFiles(dir, base = dir, out = []) {
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    const abs = path.join(dir, e.name);
    if (e.isDirectory()) listFiles(abs, base, out);
    else out.push(path.relative(base, abs).split(path.sep).join('/'));
  }
  return out.sort();
}
const defaultList = (dir = REPO) => listFiles(dir).filter((f) => !f.startsWith('excluded/'));
function tmp() { return fs.mkdtempSync(path.join(os.tmpdir(), 'csgen-')); }
function copyRepo() {
  const dir = path.join(tmp(), 'repo');
  fs.cpSync(REPO, dir, { recursive: true, verbatimSymlinks: true });
  return dir;
}
const tool = (s, id) => s.tools.find((t) => t.tool === id);
const cfg = (t, p) => t.configs.find((c) => c.path === p);
const ruleNames = (c) => c.rules.map((r) => r.rule);
const editJson = (file, fn) => { const o = JSON.parse(fs.readFileSync(file, 'utf8')); fn(o); fs.writeFileSync(file, JSON.stringify(o, null, 2) + '\n'); };

async function fixtureScan(repo = REPO, files = defaultList(repo)) {
  const { scan } = await scanner();
  return scan({ repo, files });
}

// ---- scanner ----

test('scanner: finds each tool and decides enforcement from runs', async () => {
  const s = await fixtureScan();
  const eslint = tool(s, 'eslint');
  assert.deepEqual(eslint.configs.map((c) => c.path),
    ['.eslintrc.json', 'eslint.config.mjs', 'packages/api/.eslintrc.json', 'packages/web/eslint.config.mjs']);
  assert.equal(eslint.enforced, true);
  assert.equal(eslint.enforcedBy, 'wired');
  assert.equal(cfg(eslint, 'eslint.config.mjs').attributed, true);
  assert.equal(cfg(eslint, 'packages/web/eslint.config.mjs').attributed, true);
  assert.ok(s.notLoaded.includes('.eslintrc.json'));
  assert.ok(s.unattributed.includes('packages/api/.eslintrc.json'));
  assert.ok(cfg(eslint, 'eslint.config.mjs').notEnforced.includes('no-empty'));

  const prettier = tool(s, 'prettier');
  assert.equal(prettier.enforced, false);
  assert.deepEqual(prettier.wiredBy, []);

  const phpcs = tool(s, 'phpcs');
  assert.deepEqual(phpcs.wiredBy, ['.github/workflows/ci.yml:8']);
  assert.equal(phpcs.selected, 'PSR12');
  assert.ok(cfg(phpcs, 'phpcs.xml').notEnforced.includes('Generic.PHP.RequireStrictTypes'));

  const rustfmt = tool(s, 'rustfmt');
  assert.deepEqual(rustfmt.configs, []);
  assert.deepEqual(rustfmt.ciChecks, [{ command: 'cargo fmt --check', at: '.github/workflows/ci.yml:9' }]);
  assert.equal(rustfmt.enforcedBy, 'ci');

  assert.equal(tool(s, 'gofmt'), undefined);
  assert.deepEqual(tool(s, 'golangci').wiredBy, ['Makefile:4']);
  assert.equal(tool(s, 'ruff').enforced, false);
  assert.equal(tool(s, 'typescript').enforcedBy, 'build');
  assert.equal(tool(s, 'msbuild').enforcedBy, 'build');
  assert.equal(tool(s, 'editorconfig').enforced, false);
  const stylelint = tool(s, 'stylelint');
  assert.equal(cfg(stylelint, '.stylelintrc.json').parsed, false);
  assert.ok(s.unparsed.includes('.stylelintrc.json'));
});

test('scanner: a strict run enforces warning-level rules', async () => {
  const repo = copyRepo();
  editJson(path.join(repo, 'package.json'), (o) => { o.scripts.lint = 'eslint --max-warnings 0 src'; });
  const s = await fixtureScan(repo);
  assert.ok(!cfg(tool(s, 'eslint'), 'eslint.config.mjs').notEnforced.includes('no-empty'));
});

test('scanner: extracted items carry their lines', async () => {
  const s = await fixtureScan();
  const eslint = tool(s, 'eslint');
  const flat = cfg(eslint, 'eslint.config.mjs');
  assert.deepEqual(flat.rules.map((r) => [r.rule, r.setting, r.line]),
    [['no-console', 'error', 4], ['eqeqeq', 'error', 5], ['no-empty', 'warn', 6]]);
  const legacy = cfg(eslint, '.eslintrc.json');
  assert.deepEqual(ruleNames(legacy), ['no-alert']);
  assert.deepEqual(legacy.presets, [{ name: 'eslint:recommended', line: 3 }]);
  assert.deepEqual(ruleNames(cfg(tool(s, 'ruff'), 'ruff.toml')), ['line-length', 'select']);
  assert.deepEqual(ruleNames(cfg(tool(s, 'golangci'), '.golangci.yml')), ['govet', 'errcheck']);
  assert.ok(ruleNames(cfg(tool(s, 'phpcs'), 'phpcs.xml')).includes('PSR12'));
  assert.deepEqual(ruleNames(cfg(eslint, 'packages/web/eslint.config.mjs')), ['no-var']);

  const dir = tmp();
  fs.writeFileSync(path.join(dir, 'eslint.config.mjs'), "export default [...tseslint.configs.recommendedTypeChecked.map((c) => c), ...nx.configs['flat/base']];\n");
  const presets = cfg(tool(await fixtureScan(dir, ['eslint.config.mjs']), 'eslint'), 'eslint.config.mjs').presets.map((p) => p.name);
  assert.deepEqual(presets, ['tseslint.configs.recommendedTypeChecked', "nx.configs['flat/base']"]);
});

test('scanner: harness paths, the file list, build integration and symlinks', async () => {
  const s = await fixtureScan();
  assert.ok(s.ignored.some((i) => i.path === '.claude/skills/demo/tsconfig.json'));
  assert.ok(!s.tools.some((t) => t.configs.some((c) => c.path.startsWith('.claude/'))));
  assert.ok(!s.unattributed.includes('excluded/.eslintrc.json'));

  const more = await fixtureScan(REPO, [...defaultList(), 'excluded/.eslintrc.json']);
  assert.deepEqual(more.unattributed.filter((p) => !s.unattributed.includes(p)), ['excluded/.eslintrc.json']);
  assert.equal(tool(s, 'eslint').configs.length, 4);
  assert.equal(tool(more, 'eslint').configs.length, 5);

  const props = copyRepo();
  fs.rmSync(path.join(props, 'app/App.csproj'));
  const ci = path.join(props, '.github/workflows/ci.yml');
  fs.writeFileSync(ci, fs.readFileSync(ci, 'utf8').replace(/^.*dotnet build.*\n/m, ''));
  assert.equal(tool(await fixtureScan(props), 'msbuild').enforced, false);

  const linked = copyRepo();
  const outside = path.join(tmp(), '.prettierrc.json');
  fs.writeFileSync(outside, '{"semi": false}\n');
  fs.symlinkSync(outside, path.join(linked, 'packages/web/.prettierrc.json'));
  const ls = await fixtureScan(linked);
  assert.ok(ls.ignored.some((i) => i.path === 'packages/web/.prettierrc.json' && i.reason === 'outside'));
  assert.ok(!tool(ls, 'prettier').configs.some((c) => c.path === 'packages/web/.prettierrc.json'));
});

test('scanner: option parsing per tool', async () => {
  const { parseRun } = await scanner();
  const p = parseRun('prettier', 'prettier -c src');
  assert.deepEqual(p.targets, ['src']);
  assert.equal(p.selected, null);
  const e = parseRun('eslint', 'eslint -c custom.config.mjs src');
  assert.equal(e.selected, 'custom.config.mjs');
  assert.deepEqual(e.targets, ['src']);
  const ph = parseRun('phpcs', 'phpcs --standard=PSR12 --ignore=src/legacy/* src tests');
  assert.deepEqual(ph.targets, ['src', 'tests']);
  assert.deepEqual(ph.excludes, ['src/legacy/*']);
  assert.equal(ph.selected, 'PSR12');
  assert.equal(parseRun('eslint', 'eslint $FILES').scopeUnknown, true);
  assert.equal(parseRun('eslint', 'eslint $(git diff --name-only)').scopeUnknown, true);
  assert.deepEqual(parseRun('eslint', "eslint --fix --rule '@nx/enforce-module-boundaries: off'").targets, []);
  assert.deepEqual(parseRun('stylelint', 'stylelint "**/*.scss" --ignore-path .gitignore').targets, ['**/*.scss']);
  assert.ok(parseRun('prettier', 'npx nx format:check --base="$NX_BASE" --head=HEAD'));
  assert.equal(parseRun('gofmt', 'gofmt -l .'), null);
  assert.equal(parseRun('prettier', 'prettier --write src'), null);
  assert.ok(parseRun('gofmt', 'test -z "$(gofmt -l .)"'));
});

test('scanner: installing or naming a tool is not a run', async () => {
  const { parseRun } = await scanner();
  for (const [id, cmd] of [['flake8', 'pip install flake8 mypy'], ['mypy', 'python -m pip install mypy'], ['stylelint', 'npm i -D stylelint-config-standard'],
    ['eslint', 'npm install -g eslint'], ['eslint', 'yarn global add eslint'], ['rubocop', 'gem install rubocop'], ['eslint', 'echo running eslint'], ['psalm', 'which psalm']]) {
    assert.equal(parseRun(id, cmd), null, cmd);
  }
  const dir = tmp();
  fs.writeFileSync(path.join(dir, 'setup.cfg'), '[flake8]\nmax-line-length = 100\n\n[mypy]\nstrict = True\n');
  fs.writeFileSync(path.join(dir, '.stylelintrc.json'), '{ "rules": { "color-no-invalid-hex": true } }\n');
  fs.writeFileSync(path.join(dir, 'package.json'), '{ "scripts": { "setup": "npm i -D stylelint-config-standard" } }\n');
  fs.mkdirSync(path.join(dir, '.github/workflows'), { recursive: true });
  fs.writeFileSync(path.join(dir, '.github/workflows/ci.yml'), 'jobs:\n  lint:\n    steps:\n      - run: pip install flake8 mypy\n');
  const s = await fixtureScan(dir, ['setup.cfg', '.stylelintrc.json', 'package.json', '.github/workflows/ci.yml']);
  for (const id of ['flake8', 'mypy', 'stylelint']) assert.equal(tool(s, id).enforced, false, id);
  assert.equal(parseRun('eslint', 'eslint --version'), null);
  assert.equal(parseRun('typescript', 'tsc --showConfig'), null);
});

test('scanner: a run whose failure is swallowed does not enforce', async () => {
  const dir = tmp();
  fs.writeFileSync(path.join(dir, 'eslint.config.mjs'), "export default [{ rules: { eqeqeq: 'error' } }];\n");
  fs.writeFileSync(path.join(dir, 'package.json'), '{ "scripts": { "lint": "eslint src || true" } }\n');
  const files = ['eslint.config.mjs', 'package.json'];
  assert.equal(tool(await fixtureScan(dir, files), 'eslint').enforced, false);
  fs.writeFileSync(path.join(dir, 'package.json'), '{ "scripts": { "lint": "eslint src || exit 1" } }\n');
  assert.equal(tool(await fixtureScan(dir, files), 'eslint').enforced, true);
});

test('scanner: a Bitbucket pipeline wires a tool; a fix script does not', async () => {
  const dir = tmp();
  fs.writeFileSync(path.join(dir, '.prettierrc'), '{ "semi": false }\n');
  fs.writeFileSync(path.join(dir, '.stylelintrc.json'), '{ "rules": { "color-no-invalid-hex": true } }\n');
  fs.writeFileSync(path.join(dir, 'package.json'), '{ "scripts": { "lint:styles:fix": "stylelint \\"**/*.scss\\" --fix" } }\n');
  fs.writeFileSync(path.join(dir, 'bitbucket-pipelines.yml'), 'pipelines:\n  default:\n    - step:\n        script:\n          - npx nx format:check --base="$NX_BASE"\n');
  const s = await fixtureScan(dir, ['.prettierrc', '.stylelintrc.json', 'bitbucket-pipelines.yml', 'package.json']);
  assert.deepEqual(tool(s, 'prettier').wiredBy, ['bitbucket-pipelines.yml:5']);
  assert.equal(tool(s, 'stylelint').enforced, false);
});

test('scanner: a compiler-only repository enforces no lint or format tool', async () => {
  const dir = tmp();
  fs.writeFileSync(path.join(dir, 'tsconfig.json'), '{ "compilerOptions": { "strict": true } }\n');
  fs.writeFileSync(path.join(dir, 'package.json'), '{ "scripts": { "build": "tsc -p ." } }\n');
  const s = await fixtureScan(dir, ['package.json', 'tsconfig.json']);
  assert.equal(tool(s, 'typescript').enforced, true);
  assert.deepEqual(s.tools.filter((t) => t.enforced && (t.class === 'lint' || t.class === 'format')), []);
});

// ---- renderer ----

const sections = (text) => text.split('\n').filter((l) => l.startsWith('## ')).map((l) => l.slice(3));
const seedSections = () => sections(fs.readFileSync(SEED, 'utf8'));
const ids = (text) => [...text.matchAll(/^### CS-(\d+) — /gm)].map((m) => Number(m[1]));
const cells = (line) => line.replace(/\\\|/g, '').split('|').length - 2;

async function renderIn(repo, opts = {}) {
  const { render } = await renderer();
  const s = opts.scan || await fixtureScan(repo);
  return render({ draft: json('draft-good.json'), scan: s, repo, seed: SEED, date: '2026-11-22', by: '/setup:map-codebase', ...opts });
}

test('renderer: parseRef', async () => {
  const { parseRef } = await renderer();
  assert.deepEqual(parseRef('a b/c:d.ts:12'), { path: 'a b/c:d.ts', from: 12, to: 12 });
  assert.deepEqual(parseRef('x.ts:3-5'), { path: 'x.ts', from: 3, to: 5 });
  for (const bad of ['x.ts', '/abs.ts:1', '../o.ts:1']) assert.equal(parseRef(bad), null);
});

test('renderer: a good draft renders the seed shape with tool rules first', async () => {
  const repo = copyRepo();
  fs.appendFileSync(path.join(repo, 'Makefile'), '\nruff:\n\truff check $(SRC)\n');
  const { text, summary } = await renderIn(repo);
  const written = fs.readFileSync(path.join(repo, 'docs/coding-standards.md'), 'utf8');
  assert.equal(written, text);
  assert.deepEqual(sections(text), seedSections());
  assert.equal(summary.rules.tool, 6);
  assert.equal(summary.rules.review, 1);
  for (const d of ['ESLint', 'PHP_CodeSniffer', 'rustfmt', 'golangci-lint', 'TypeScript', 'MSBuild']) assert.match(text, new RegExp(`### CS-\\d+ — .*${d}`));
  const blocks = text.split('### ').slice(1);
  const toolIdx = blocks.map((b, i) => (b.includes('Enforced by: tool') ? i : -1)).filter((i) => i >= 0);
  assert.deepEqual(toolIdx, [0, 1, 2, 3, 4, 5]);
  const php = blocks.find((b) => b.includes('PHP_CodeSniffer'));
  assert.match(php, /Enforced by: tool \(\.github\/workflows\/ci\.yml: PSR12\)/);
  assert.match(php, /Applies to: `src\/\*\*`/);
  assert.doesNotMatch(text, /RequireStrictTypes/);
  const es = blocks.find((b) => b.includes('ESLint'));
  assert.match(es, /Applies to: `src\/\*\*`, `packages\/web\/\*\*`/);
  assert.match(es, /\+1 more config/);
  assert.deepEqual(ids(text), [1, 2, 3, 4, 5, 6, 7]);
  assert.equal(summary.helpers, 1);
  assert.equal(summary.shapes, 1);
  assert.deepEqual(summary.open, ['Date formatting for display']);
  for (const no of ['Prettier', 'Ruff', 'packages/api', '.eslintrc.json', 'Optional seed']) assert.ok(!text.includes(no), no);
  assert.match(text, /^> Generated by \/setup:map-codebase on 2026-11-22 from the code/m);
  assert.equal(summary.reconstructed, false);
});

test('renderer: a bad draft drops what does not resolve and escapes what does', async () => {
  const repo = copyRepo();
  const bad = json('draft-bad.json');
  bad.rules[1].appliesTo = 'services, components';
  const { text, summary } = await renderIn(repo, { draft: bad });
  assert.ok(text.includes('- Applies to: services, components\n'));
  const dropped = (item) => summary.dropped.find((d) => d.item === item);
  assert.deepEqual(dropped('Exported functions declare an explicit return type').documentedIds, ['doc#r1']);
  assert.ok(dropped('Format a date'));
  assert.ok(dropped('Date formatting for display'));
  for (const no of ['Exported functions declare', '../outside.ts', 'Date formatting for display']) assert.ok(!text.includes(no), no);
  assert.ok(text.includes('`Result<T \\| E>`'));
  for (const l of text.split('\n').filter((x) => x.startsWith('|'))) assert.equal(cells(l), 3, l);
  assert.ok(text.includes('Why: Plain records serialise as they are. Classes carry behaviour.'));
  assert.equal(text.split('\n').filter((l) => l.startsWith('## ')).length, 4);
  const review = text.split('### ').slice(1).filter((b) => !b.includes('Enforced by: tool'));
  assert.ok(review.length >= 1);
  for (const b of review) assert.match(b, /- Enforced by: review\n/);
});

test('renderer: never overwrites an existing standards file', async () => {
  const repo = copyRepo();
  fs.mkdirSync(path.join(repo, 'docs'));
  fs.writeFileSync(path.join(repo, 'docs/coding-standards.md'), 'KEEP\n');
  const first = await renderIn(repo);
  assert.equal(fs.readFileSync(path.join(repo, 'docs/coding-standards.md'), 'utf8'), 'KEEP\n');
  assert.equal(first.summary.reconstructed, true);
  assert.equal(first.path, path.join(repo, 'docs/coding-standards.reconstructed.md'));
  fs.writeFileSync(first.path, 'OLD\n');
  await renderIn(repo);
  assert.equal(fs.readFileSync(first.path, 'utf8'), first.text);

  const fresh = copyRepo();
  fs.mkdirSync(path.join(fresh, 'docs'));
  fs.writeFileSync(path.join(fresh, 'docs/PRD.md'), '# PRD\n');
  const r = await renderIn(fresh);
  assert.equal(r.summary.reconstructed, false);
  assert.ok(fs.existsSync(path.join(fresh, 'docs/coding-standards.md')));
});

test('renderer: output and evidence stay inside the roots', async () => {
  const { writeReplace } = await renderer();
  const a = copyRepo();
  const away = tmp();
  fs.symlinkSync(away, path.join(a, 'docs'));
  await assert.rejects(renderIn(a), /unsafe output/);
  assert.deepEqual(fs.readdirSync(away), []);

  const b = copyRepo();
  fs.mkdirSync(path.join(b, 'docs'));
  fs.writeFileSync(path.join(b, 'docs/coding-standards.md'), 'KEEP\n');
  fs.symlinkSync('coding-standards.md', path.join(b, 'docs/coding-standards.reconstructed.md'));
  await assert.rejects(renderIn(b), /unsafe output/);
  assert.equal(fs.readFileSync(path.join(b, 'docs/coding-standards.md'), 'utf8'), 'KEEP\n');

  const c = copyRepo();
  const outsideFile = path.join(tmp(), 'a.ts');
  fs.copyFileSync(path.join(c, 'src/orders/a.ts'), outsideFile);
  fs.rmSync(path.join(c, 'src/orders/a.ts'));
  fs.symlinkSync(outsideFile, path.join(c, 'src/orders/a.ts'));
  const rc = await renderIn(c, { scan: await fixtureScan(REPO) });
  assert.ok(rc.summary.dropped.some((d) => d.item === 'Exported functions declare an explicit return type'));

  const src = copyRepo();
  const s = await fixtureScan(src);
  const differ = copyRepo();
  fs.appendFileSync(path.join(differ, 'src/orders/a.ts'), '// changed\n');
  const rd = await renderIn(src, { scan: s, outRoot: differ });
  assert.ok(rd.summary.dropped.some((d) => d.item === 'Exported functions declare an explicit return type' && d.reason === 'differs in destination'));
  assert.ok(fs.existsSync(path.join(differ, 'docs/coding-standards.md')));

  const linkOut = copyRepo();
  fs.rmSync(path.join(linkOut, 'src/orders/a.ts'));
  fs.symlinkSync(path.join(src, 'src/orders/a.ts'), path.join(linkOut, 'src/orders/a.ts'));
  const rl = await renderIn(src, { scan: s, outRoot: linkOut });
  assert.ok(rl.summary.dropped.some((d) => d.item === 'Exported functions declare an explicit return type' && d.reason === 'differs in destination'));

  const noLint = copyRepo();
  editJson(path.join(noLint, 'package.json'), (o) => { delete o.scripts.lint; });
  const rn = await renderIn(src, { scan: s, outRoot: noLint });
  assert.ok(rn.summary.dropped.some((d) => d.section === 'rules' && /ESLint/.test(d.item) && d.reason === 'differs in destination'));
  assert.ok(!rn.text.includes('Code passes ESLint'));

  const w = tmp();
  const canonical = path.join(w, 'coding-standards.md');
  fs.writeFileSync(canonical, 'KEEP\n');
  fs.symlinkSync(canonical, `${canonical}.tmp.x`);
  assert.throws(() => writeReplace(canonical, 'NEW\n', { suffix: 'x' }), /EEXIST/);
  assert.equal(fs.readFileSync(canonical, 'utf8'), 'KEEP\n');
});

test('renderer: support below two modules drops an item', async () => {
  const repo = copyRepo();
  const draft = json('draft-good.json');
  draft.helpers[0].support = [{ module: 'src/lib', ref: 'src/lib/dates.ts:2' }, { module: 'src/orders', ref: 'src/orders/a.ts:99' }, { module: 'src/billing', ref: '../elsewhere.ts:1' }];
  draft.rules[0].support[1].ref = 'src/billing/b.ts:999';
  const { text, summary } = await renderIn(repo, { draft });
  assert.ok(summary.dropped.some((d) => d.item === 'Format a date as YYYY-MM-DD' && d.reason === 'support below two modules'));
  assert.ok(summary.dropped.some((d) => d.item === 'Exported functions declare an explicit return type' && d.reason === 'support below two modules'));
  assert.ok(!text.includes('| Format a date as YYYY-MM-DD |'));
});

test('renderer: tools-only writes the tool rules alone', async () => {
  const repo = copyRepo();
  const { text, summary } = await renderIn(repo, { draft: null, toolsOnly: true });
  assert.equal(summary.rules.review, 0);
  assert.equal(summary.rules.tool, 6);
  assert.equal(summary.helpers, 0);
  assert.equal(summary.shapes, 0);
  assert.deepEqual(summary.open, []);
  for (const l of text.split('\n').filter((x) => x.startsWith('|'))) assert.ok(/^\| (Need|Problem) |^\|---/.test(l), l);
  assert.ok(!/^- .*a person picks one/m.test(text));
});

test('renderer: a missing seed is a usage error', async () => {
  const repo = copyRepo();
  const scanFile = path.join(tmp(), 'scan.json');
  fs.writeFileSync(scanFile, JSON.stringify(await fixtureScan(repo)));
  const r = spawnSync(process.execPath, [RENDERER, 'render', '--scan', scanFile, '--repo', repo, '--tools-only', '--seed', path.join(repo, 'no-seed.md')], { encoding: 'utf8' });
  assert.equal(r.status, 2);
  assert.match(r.stderr, /^coding-standards-render: /);
});

// ---- workflow stub ----

const MODULES = [
  { name: 'src/lib', files: ['src/lib/dates.ts', 'src/lib/errors.ts'], imports: [], importedBy: ['src/orders', 'src/billing'], isCore: true },
  { name: 'src/orders', files: ['src/orders/a.ts'], imports: ['src/lib'], importedBy: [], isCore: false },
  { name: 'src/billing', files: ['src/billing/b.ts', 'src/billing/c.ts'], imports: ['src/lib'], importedBy: [], isCore: false },
];

async function runWorkflow({ args = {}, draft = null, summaries = json('summaries.json'), docs = json('docs-analysis.json') } = {}) {
  const src = fs.readFileSync(WORKFLOW, 'utf8').replace('export const meta =', 'const meta =');
  const AsyncFunction = Object.getPrototypeOf(async function () {}).constructor;
  const fn = new AsyncFunction('args', 'agent', 'parallel', 'pipeline', 'phase', 'log', src);
  const calls = [];
  const agent = async (prompt, opts = {}) => {
    calls.push({ prompt, opts });
    const label = opts.label || '';
    if (label === 'analyze:docs') return structuredClone(docs);
    if (label === 'analyze:infra') return null;
    if (label.startsWith('analyze:')) return structuredClone(summaries.find((s) => s.module === label.slice(8)) || null);
    if (label === 'synthesize:coding-standards') return structuredClone(draft);
    return `## heading for ${label}`;
  };
  const parallel = (ts) => Promise.all(ts.map((t) => t().catch(() => null)));
  const pipeline = () => { throw new Error('pipeline not expected'); };
  const result = await fn({ modules: MODULES, docFiles: ['CLAUDE.md'], infraFiles: ['ci.yml'], today: '2026-11-22', projectName: 'fixture', ...args }, agent, parallel, pipeline, () => {}, () => {});
  return { result, calls };
}
const goodDraft = () => { const d = json('draft-good.json'); for (const k of ['rules', 'helpers', 'shapes']) for (const i of d[k]) delete i.support; return d; };
const call = (calls, label) => calls.filter((c) => c.opts.label === label);

test('workflow: analyzer schemas require the new fields', async () => {
  const { calls } = await runWorkflow({ draft: goodDraft() });
  const req = call(calls, 'analyze:src/orders')[0].opts.schema.required;
  for (const k of ['conventions', 'helpersDefined', 'helpersUsed', 'problemShapes']) assert.ok(req.includes(k), k);
  const docs = call(calls, 'analyze:docs')[0].opts.schema;
  assert.ok(docs.properties.documentedPatterns.items.required.includes('kind'));
  assert.ok(docs.required.includes('namedTools'));
});

test('workflow: one standards synthesizer; old prompts carry no new field', async () => {
  const { calls } = await runWorkflow({ draft: goodDraft() });
  const synth = call(calls, 'synthesize:coding-standards');
  assert.equal(synth.length, 1);
  assert.ok(synth[0].opts.schema);
  const p = synth[0].prompt;
  assert.ok(p.includes('src/orders#c1'));
  const pos = seedSections().map((s) => p.indexOf(`## ${s}`));
  assert.ok(pos.every((x) => x >= 0));
  assert.deepEqual(pos, [...pos].sort((x, y) => x - y));
  for (const label of ['synthesize:architecture', 'synthesize:reverse-prd']) {
    const q = call(calls, label)[0].prompt;
    for (const no of ['helpersUsed', 'problemShapes', '"conventions"']) assert.ok(!q.includes(no), `${label}: ${no}`);
  }
});

test('workflow: the draft check keeps what observations support and rejects the rest', async () => {
  const good = await runWorkflow({ draft: goodDraft() });
  const d = good.result.standardsDraft;
  assert.deepEqual(good.result.rejected, []);
  for (const k of ['rules', 'helpers', 'shapes']) {
    assert.equal(d[k].length, 1, k);
    assert.ok(d[k][0].support.length >= 2, k);
    for (const s of d[k][0].support) assert.ok(s.module && s.ref, k);
  }
  assert.equal(d.open.length, 1);

  const rejectedFor = async (draft, opts = {}) => (await runWorkflow({ draft, ...opts })).result.rejected;
  const one = goodDraft();
  one.rules = [{ ...one.rules[0], rule: 'Records carry an id', example: 'src/orders/a.ts:5', observations: ['src/orders#c2'] }];
  assert.equal((await rejectedFor(one)).length, 1);

  const money = goodDraft();
  money.helpers[0].observations = ['src/lib#hd1', 'src/orders#hu1', 'src/billing#hu2'];
  assert.equal((await rejectedFor(money))[0].section, 'helpers');

  const loose = goodDraft();
  loose.rules[0].example = 'explicit return type at src/orders/a.ts:9; also src/billing/b.ts:10';
  loose.open[0].variants[0].observation = 'src/orders#c1, src/billing#c2';
  const lr = await runWorkflow({ draft: loose });
  assert.deepEqual(lr.result.rejected, []);
  assert.equal(lr.result.standardsDraft.rules[0].example, 'src/orders/a.ts:9');
  assert.equal(lr.result.standardsDraft.open[0].variants[0].observation, 'src/billing#c2');

  const far = goodDraft();
  far.rules[0].example = 'src/orders/a.ts:10';
  assert.equal((await rejectedFor(far))[0].section, 'rules');

  const dissent = json('summaries.json');
  dissent[0].problemShapes = [{ problem: 'error handling and error bodies', shape: '`throw new Error()`', consistency: 'consistent', evidence: ['src/lib/dates.ts:12'], variants: [] }];
  const rd = await rejectedFor(goodDraft(), { summaries: dissent });
  assert.match(rd.find((r) => r.section === 'shapes').reason, /^dissent: src\/lib#s1/);

  const disagree = json('summaries.json');
  disagree[1].problemShapes[0].shape = '`ApiError` body';
  disagree[2].problemShapes[0].shape = '`ProblemDetails` body';
  const dd = goodDraft();
  dd.shapes[0].shape = 'use `ApiError` or `ProblemDetails`';
  assert.equal((await rejectedFor(dd, { summaries: disagree })).find((r) => r.section === 'shapes').reason, 'shapes disagree');

  const bound = MODULES.map((m) => (m.name === 'src/billing' ? { ...m, files: ['src/billing/c.ts'] } : m));
  const rb = await rejectedFor(goodDraft(), { args: { modules: bound } });
  assert.ok(rb.some((r) => r.section === 'rules'));

  const docs2 = json('docs-analysis.json');
  docs2.documentedPatterns.push({ name: 'Keep functions small', description: 'x', source: 'CONTRIBUTING.md', kind: 'rule' });
  const wn = (await runWorkflow({ draft: goodDraft(), docs: docs2 })).result.writtenNotFollowed;
  assert.ok(wn.some((w) => w.id === 'doc#r2' && w.reason === 'not assessed'));

  const rooted = await runWorkflow({ draft: goodDraft(), args: { root: '/abs/repo' } });
  const ap = call(rooted.calls, 'analyze:src/orders')[0].prompt;
  assert.ok(ap.includes('/abs/repo'));
  assert.ok(ap.includes('- src/orders/a.ts'));
});

test('workflow: named tools, the input budget and a docs-only run', async () => {
  const toolScan = await fixtureScan();
  const named = await runWorkflow({ draft: goodDraft(), args: { toolScan } });
  assert.deepEqual(named.result.toolsNamedNotPresent.map((t) => t.tool), ['StyleCop']);
  const loose = json('docs-analysis.json');
  loose.namedTools = [{ tool: 'ESLint 9 (flat config)', source: 'CLAUDE.md' }, { tool: 'Biome', source: 'CLAUDE.md' }];
  const ln = await runWorkflow({ draft: goodDraft(), docs: loose, args: { toolScan } });
  assert.deepEqual(ln.result.toolsNamedNotPresent.map((t) => t.tool), ['Biome']);

  const big = 'x'.repeat(1000);
  const bigModules = Array.from({ length: 60 }, (_, i) => ({ name: `m${i}`, files: [`m${i}/f.ts`], imports: [], importedBy: [], isCore: false }));
  const bigSummaries = bigModules.map((m) => ({ ...json('summaries.json')[1], module: m.name,
    conventions: Array.from({ length: 8 }, (_, k) => ({ rule: `${big}${k}`, appliesTo: '**', consistency: 'consistent', evidence: [`${m.name}/f.ts:1`], variants: [] })),
    helpersDefined: [], helpersUsed: [], problemShapes: [] }));
  const over = await runWorkflow({ draft: goodDraft(), summaries: bigSummaries, args: { modules: bigModules } });
  assert.equal(call(over.calls, 'synthesize:coding-standards').length, 0);
  assert.equal(over.result.standardsSkipped, 'input over budget');
  assert.ok(over.result.standardsInputChars > 200000);
  assert.deepEqual(over.result.writtenNotFollowed, []);

  const empty = json('summaries.json').map((s) => ({ ...s, conventions: [], helpersDefined: [], helpersUsed: [], problemShapes: [] }));
  const docsOnly = await runWorkflow({ draft: goodDraft(), summaries: empty });
  assert.equal(call(docsOnly.calls, 'synthesize:coding-standards').length, 0);
  assert.equal(docsOnly.result.standardsDraft, null);
  assert.ok(docsOnly.result.writtenNotFollowed.some((w) => w.source === 'CLAUDE.md' && w.reason === 'no evidence'));
  assert.ok(docsOnly.result.docsAnalysis.documentedPatterns.every((p) => p.source));
});
