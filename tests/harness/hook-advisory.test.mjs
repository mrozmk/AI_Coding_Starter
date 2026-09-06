import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { runHook } from '../../harness-source/scripts/hook-runner.mjs';
import { globToRegExp, measure } from '../../harness-source/hooks/core/comments.mjs';

const REPO = path.resolve(import.meta.dirname, '../..');
const ADAPTERS = path.join(REPO, 'harness-source/adapters');

function project({ commentGuard = null, nudge = null, domains = null, legacy = true } = {}) {
  const dir = fs.realpathSync.native(fs.mkdtempSync(path.join(os.tmpdir(), 'harness advisory-')));
  execFileSync('git', ['init', '-q'], { cwd: dir });
  const cfgDir = legacy ? '.claude' : '.agents/hooks';
  fs.mkdirSync(path.join(dir, cfgDir), { recursive: true });
  if (commentGuard) fs.writeFileSync(path.join(dir, cfgDir, 'comment-guard.json'), JSON.stringify(commentGuard));
  if (nudge) fs.writeFileSync(path.join(dir, cfgDir, 'nudge-rules.json'), JSON.stringify(nudge));
  if (domains) fs.writeFileSync(path.join(dir, cfgDir, 'memory-domains.json'), JSON.stringify(domains));
  return dir;
}
const env = (root) => ({ PATH: process.env.PATH, HOME: os.homedir(), CLAUDE_PROJECT_DIR: root });
const claudeWrite = (file, content) => ({ hook_event_name: 'PostToolUse', session_id: 's', tool_name: 'Write', tool_input: { file_path: file, content } });
const codexPatch = (files) => ({ hook_event_name: 'PostToolUse', session_id: 's', tool_name: 'apply_patch', tool_input: { command: `*** Begin Patch\n${files.map(([p, c]) => `*** Add File: ${p}\n${c.split('\n').map((l) => `+${l}`).join('\n')}`).join('\n')}\n*** End Patch` } });
const NOISY = '// increment\nlet i = 0;\n// add one\ni += 1;\n// log it\nconsole.log(i);\n// done\nreturn i;\n';
const CLEAN = 'let i = 0;\ni += 1;\nconsole.log(i);\nreturn i;\n';

test('comments: nudges above the configured density and stays silent on tests, generated files and small edits', async () => {
  const root = project({ commentGuard: { src_globs: ['src/*'], min_comment_lines: 3, max_comment_percent: 15 } });
  const run = (payload, host = 'claude') => runHook({ host, hook: 'guard-comments', payload, env: env(root), cwd: root, adaptersRoot: ADAPTERS });
  const noisy = await run(claudeWrite('src/lib/a.ts', NOISY));
  assert.equal(noisy.exit, 0, 'advisory never blocks');
  assert.match(noisy.stdout, /comment-heavy \(src\/lib\/a\.ts: 4 comment lines out of 8/);
  assert.equal((await run(claudeWrite('src/lib/a.ts', CLEAN))).stdout, '');
  assert.equal((await run(claudeWrite('src/lib/a.test.ts', NOISY))).stdout, '', 'tests exempt');
  assert.equal((await run(claudeWrite('src/lib/a.ts', `// @generated\n${NOISY}`))).stdout, '', 'generated exempt');
  assert.equal((await run(claudeWrite('lib/other.ts', NOISY))).stdout, '', 'outside configured globs');
  assert.equal((await run(claudeWrite('src/lib/a.ts', '// one\n// two\n// three\nx\n'))).stdout, '', 'at the floor of 3 comment lines');
  const patch = await run(codexPatch([['src/a.ts', NOISY], ['src/b.ts', CLEAN], ['src/c.test.ts', NOISY]]), 'codex');
  assert.match(patch.stdout, /src\/a\.ts: 4 comment lines/);
  assert.ok(!patch.stdout.includes('src/b.ts') && !patch.stdout.includes('src/c.test.ts'), 'every file in the patch judged on its own content');
  const dormant = await runHook({ host: 'claude', hook: 'guard-comments', payload: claudeWrite('src/a.ts', NOISY), env: env(project({ commentGuard: { src_globs: [] } })), cwd: root, adaptersRoot: ADAPTERS });
  assert.equal(dormant.state, 'dormant');
  assert.ok(globToRegExp('src/*').test('src/lib/deep/file.ts'), '* spans /');
  assert.ok(!globToRegExp('src/*').test('lib/file.ts'));
  assert.deepEqual(measure('# a\n\nx\n# b\n', /^\s*#/), { total: 3, comments: 2 });
});

test('nudge-files: first matching rule per file, most-specific first, generated files exempt, both payload shapes', async () => {
  const root = project({ nudge: { rules: [{ glob: '*/tokens/_semantic.*', message: 'central token file' }, { glob: 'src/*/index.ts', message: 'public barrel' }, { glob: 'src/*', message: 'generic src' }] } });
  const run = (payload, host = 'claude') => runHook({ host, hook: 'nudge-files', payload, env: env(root), cwd: root, adaptersRoot: ADAPTERS });
  const barrel = await run(claudeWrite('src/ui/index.ts', 'export * from "./x";'));
  assert.match(barrel.stdout, /Reminder for src\/ui\/index\.ts: public barrel/);
  assert.ok(!barrel.stdout.includes('generic src'), 'first match wins');
  assert.equal((await run(claudeWrite('src/ui/index.test.ts', 'x'))).stdout, '');
  assert.equal((await run(claudeWrite('src/x.ts', '// DO NOT EDIT\nx'))).stdout, '');
  const patch = await run(codexPatch([['src/tokens/_semantic.css', ':root{}'], ['src/a.ts', 'x'], ['docs/readme.md', 'y']]), 'codex');
  const ctx = JSON.parse(patch.stdout).hookSpecificOutput.additionalContext;
  assert.match(ctx, /src\/tokens\/_semantic\.css: central token file/);
  assert.match(ctx, /src\/a\.ts: generic src/);
  assert.ok(!ctx.includes('docs/readme.md'));
  const dormant = await runHook({ host: 'claude', hook: 'nudge-files', payload: claudeWrite('src/a.ts', 'x'), env: env(project({ nudge: { rules: [] } })), cwd: root, adaptersRoot: ADAPTERS });
  assert.equal(dormant.state, 'dormant');
});

test('memory-scope: dormant without app_source_regex; misrouted errors.md entries get a reroute, never a deletion', async () => {
  const dormantRoot = project({ domains: { rules: [], app_source_regex: '' } });
  const entry = '## 2026-09-05 — hook crashed\n\n**What failed:** the PreToolUse hook in .claude/hooks/x.sh exited 2\n';
  const write = (root, content = entry) => ({ hook_event_name: 'PostToolUse', session_id: 's', tool_name: 'Edit', tool_input: { file_path: path.join(root, '.agents/memory/errors.md'), new_string: content } });
  const d = await runHook({ host: 'claude', hook: 'guard-memory-scope', payload: write(dormantRoot), env: env(dormantRoot), cwd: dormantRoot, adaptersRoot: ADAPTERS });
  assert.equal(d.state, 'dormant');
  const root = project({ domains: { rules: [], app_source_regex: '(^|[^A-Za-z0-9_])src/[A-Za-z0-9_./-]+' }, legacy: false });
  fs.mkdirSync(path.join(root, '.agents/memory'), { recursive: true });
  fs.writeFileSync(path.join(root, '.agents/memory/errors.md'), 'before\n');
  const nudged = await runHook({ host: 'claude', hook: 'guard-memory-scope', payload: write(root), env: env(root), cwd: root, adaptersRoot: ADAPTERS });
  assert.match(nudged.stdout, /harness\/workflow markers; no application source path cited/);
  assert.equal(fs.readFileSync(path.join(root, '.agents/memory/errors.md'), 'utf8'), 'before\n', 'nothing moved or deleted');
  const fine = await runHook({ host: 'claude', hook: 'guard-memory-scope', payload: write(root, '## 2026-09-05 — null user\n\n**Fix:** src/auth/session.ts now guards null\n'), env: env(root), cwd: root, adaptersRoot: ADAPTERS });
  assert.equal(fine.stdout, '');
  const patch = await runHook({ host: 'codex', hook: 'guard-memory-scope', payload: codexPatch([['.agents/memory/errors.md', 'Playwright snapshot test flaked']]), env: env(root), cwd: root, adaptersRoot: ADAPTERS });
  assert.match(patch.stdout, /test-harness markers/);
  const other = await runHook({ host: 'claude', hook: 'guard-memory-scope', payload: { ...write(root), tool_input: { file_path: path.join(root, 'src/a.ts'), new_string: entry } }, env: env(root), cwd: root, adaptersRoot: ADAPTERS });
  assert.equal(other.stdout, '');
});

test('lsp-hint: conditional on a declared LSP and a structured search event; Codex is legacy-only', async () => {
  const root = project();
  const grep = (pattern, extra = {}) => ({ hook_event_name: 'PostToolUse', session_id: 's', tool_name: 'Grep', tool_input: { pattern, ...extra } });
  const noLsp = await runHook({ host: 'claude', hook: 'nudge-lsp', payload: grep('buildSpawn'), env: env(root), cwd: root, adaptersRoot: ADAPTERS });
  assert.equal(noLsp.state, 'dormant');
  assert.equal(noLsp.stdout, '');
  fs.writeFileSync(path.join(root, 'CLAUDE.md'), '# Rules\n\n## Code Navigation (LSP)\n\ntypescript-language-server\n');
  const hinted = await runHook({ host: 'claude', hook: 'nudge-lsp', payload: grep('buildSpawn'), env: env(root), cwd: root, adaptersRoot: ADAPTERS });
  assert.match(JSON.parse(hinted.stdout).hookSpecificOutput.additionalContext, /symbol "buildSpawn"/);
  assert.equal((await runHook({ host: 'claude', hook: 'nudge-lsp', payload: grep('build spawn'), env: env(root), cwd: root, adaptersRoot: ADAPTERS })).stdout, '', 'free text is not a symbol');
  assert.equal((await runHook({ host: 'claude', hook: 'nudge-lsp', payload: grep('buildSpawn', { glob: '*.md' }), env: env(root), cwd: root, adaptersRoot: ADAPTERS })).stdout, '', 'non-code scope');
  const codex = await runHook({ host: 'codex', hook: 'nudge-lsp', payload: { hook_event_name: 'PostToolUse', session_id: 's', tool_name: 'Bash', tool_input: { command: 'rg buildSpawn' } }, env: env(root), cwd: root, adaptersRoot: ADAPTERS });
  assert.equal(codex.state, 'unsupported');
  assert.equal(codex.stdout, '', 'shell bodies are not parsed as Grep');
});
