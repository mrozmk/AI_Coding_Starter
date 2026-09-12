import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { AGENTS_FILE, CLAUDE_FILE, RULES_FILE, applyRules, branchModel, compatDrift, derivePublish, fieldsFrom, fillRules, legacyContractCheck, renderTemplate, resolveRulesAuthority, syncCompat, unresolved } from '../../harness-source/scripts/rules.mjs';

const REPO = path.resolve(import.meta.dirname, '../..');

function project() {
  return fs.mkdtempSync(path.join(os.tmpdir(), 'harness rules-'));
}

const FACTS = {
  project_description: 'Order export service for ops.', language: 'pl', validation: 'npm run typecheck && npm run lint && npm test',
  commands: { dev: 'npm run dev', test: 'npm test' }, tech_stack: [{ tech: 'Node 24', purpose: 'runtime' }], architecture: 'Layered: routes → services → data.',
  style: 'ESLint + Prettier; camelCase.', workflow: { preset: 'feature-branch' }, app_surface: 'web', ui_paths: 'src/app/**',
};

test('brownfield: populated CLAUDE.md stays the authority and AGENTS.md points at it; no competing project-rules file is created', () => {
  const root = project();
  fs.copyFileSync(path.join(REPO, 'CLAUDE.md'), path.join(root, CLAUDE_FILE));
  const before = fs.readFileSync(path.join(root, CLAUDE_FILE), 'utf8');
  const auth = resolveRulesAuthority(root);
  assert.equal(auth.mode, 'brownfield');
  assert.equal(auth.authority, CLAUDE_FILE);
  const res = applyRules({ projectRoot: root, facts: FACTS, consent: true });
  assert.equal(res.ok, true);
  assert.equal(fs.readFileSync(path.join(root, CLAUDE_FILE), 'utf8'), before, 'CLAUDE.md untouched byte for byte');
  assert.ok(!fs.existsSync(path.join(root, RULES_FILE)), 'no generic seed competes with the real rules');
  const agents = fs.readFileSync(path.join(root, AGENTS_FILE), 'utf8');
  assert.match(agents, /Read `CLAUDE\.md` in full before any task/);
  assert.match(agents, /brownfield/);
  assert.ok(!agents.includes('{rules-file}'));
  assert.equal(res.actions.find((a) => a.file === RULES_FILE).action, 'skipped');
  assert.equal(res.ready, false, 'the starter CLAUDE.md still carries {typecheck-command} → incomplete, never ready');
  assert.ok(res.unresolved_required.includes('validation-command') || res.unresolved_required.length > 0);
});

test('a short hand-written CLAUDE.md is still the authority; a gutted Validation section is incomplete, not ready', () => {
  const root = project();
  fs.writeFileSync(path.join(root, CLAUDE_FILE), '# Rules\n\nAlways run `make check` before committing.\nNever touch `legacy/`.\n');
  const auth = resolveRulesAuthority(root);
  assert.equal(auth.mode, 'brownfield', 'four lines of real rules are rules');
  const res = applyRules({ projectRoot: root, facts: FACTS, consent: true });
  assert.ok(!fs.existsSync(path.join(root, RULES_FILE)));
  assert.match(fs.readFileSync(path.join(root, AGENTS_FILE), 'utf8'), /Read `CLAUDE\.md` in full/);
  assert.equal(res.ready, false, 'short rules without a Validation section are incomplete — meaning kept, gaps named');
  const green = project();
  applyRules({ projectRoot: green, facts: FACTS, consent: true });
  assert.equal(resolveRulesAuthority(green).ready, true);
  const gutted = fs.readFileSync(path.join(green, RULES_FILE), 'utf8').replace(/```bash\nnpm run typecheck && npm run lint && npm test\n```/, '```bash\n```');
  assert.ok(gutted !== fs.readFileSync(path.join(green, RULES_FILE), 'utf8'));
  fs.writeFileSync(path.join(green, RULES_FILE), gutted);
  const after = resolveRulesAuthority(green);
  assert.equal(after.ready, false, 'no placeholder left, but no command either');
  assert.ok(after.unresolved_required.includes('validation-command'));
  for (const [heading, field] of [['## Validation', 'validation-command'], ['## Language Rules', 'language'], ['### Branch model', 'trunk']]) {
    const dir = project();
    applyRules({ projectRoot: dir, facts: FACTS, consent: true });
    const f = path.join(dir, RULES_FILE);
    const t = fs.readFileSync(f, 'utf8');
    const i = t.indexOf(heading);
    const j = t.indexOf('\n## ', i + 3);
    fs.writeFileSync(f, t.slice(0, i) + (j === -1 ? '' : t.slice(j + 1)));
    const r = resolveRulesAuthority(dir);
    assert.equal(r.ready, false, `${heading} removed`);
    assert.ok(r.unresolved_required.includes(field), `${heading} → ${field}: ${r.unresolved_required}`);
  }
});

test('greenfield render satisfies the legacy tier-1/tier-2 heading contract', () => {
  const root = project();
  const res = applyRules({ projectRoot: root, facts: FACTS, consent: true });
  assert.equal(res.ok, true);
  assert.equal(res.mode, 'greenfield');
  assert.equal(res.authority, RULES_FILE);
  assert.equal(res.ready, true, JSON.stringify(res.unresolved_required));
  const claude = fs.readFileSync(path.join(root, CLAUDE_FILE), 'utf8');
  assert.deepEqual(legacyContractCheck(claude), []);
  const rules = fs.readFileSync(path.join(root, RULES_FILE), 'utf8');
  for (const h of ['## Code Structure & Modularity', '## Error Handling', '## Security', '## Automatic Behaviors', '## Project Knowledge Layers', '## Search Commands', '## Language Rules']) assert.ok(rules.includes(h), h);
  assert.match(rules, /KISS.*YAGNI.*SOLID.*Fail Fast/);
  assert.match(rules, /Loader Convention/);
  assert.match(rules, /npm run typecheck && npm run lint && npm test/);
  assert.match(rules, /\*\*Polish\*\*/);
  assert.match(claude, /\*\*Orchestrate publish:\*\* branch-local/);
  assert.match(rules, /\*\*Orchestrate publish:\*\* branch-local/, 'both files carry the same derived value');
  const agents = fs.readFileSync(path.join(root, AGENTS_FILE), 'utf8');
  assert.match(agents, /Read `\.agents\/project-rules\.md` in full/);
  const again = applyRules({ projectRoot: root, facts: { ...FACTS, validation: 'other' }, consent: true });
  assert.ok(again.actions.every((a) => a.action === 'kept'), 'existing files are never overwritten');
});

test('unresolved required placeholders mean incomplete, never ready; braces in code are not placeholders', () => {
  const root = project();
  const res = applyRules({ projectRoot: root, facts: { language: 'en', workflow: { preset: 'trunk' }, commands: 'echo "${HOME}" && printf "{0}"' }, consent: true });
  assert.equal(res.ready, false);
  assert.ok(res.unresolved_required.includes('validation-command'));
  const rules = fs.readFileSync(path.join(root, RULES_FILE), 'utf8');
  assert.ok(rules.includes('${HOME}') && rules.includes('{0}'), 'code braces rendered verbatim');
  assert.ok(!unresolved('echo "${HOME}" {0} { } {not-a-known-field}').length, 'only named fields count');
  assert.ok(unresolved(rules).includes('validation-command'));
  assert.ok(legacyContractCheck(fs.readFileSync(path.join(root, CLAUDE_FILE), 'utf8')).some((e) => /placeholder command/.test(e)));
  const auth = resolveRulesAuthority(root);
  assert.equal(auth.mode, 'greenfield');
  assert.equal(auth.ready, false);
});

test('a docs-only project has its own real validation command, not an invented npm/typecheck requirement', () => {
  const root = project();
  const res = applyRules({ projectRoot: root, facts: { language: 'en', validation: 'markdownlint docs/ && lychee docs/', workflow: { preset: 'trunk' }, app_surface: 'none' }, consent: true });
  assert.equal(res.ready, true, JSON.stringify(res.unresolved_required));
  const claude = fs.readFileSync(path.join(root, CLAUDE_FILE), 'utf8');
  assert.match(claude, /markdownlint docs\/ && lychee docs\//);
  assert.ok(!/npm|typecheck/.test(claude.split('## Validation')[1].split('## Code Structure')[0]), 'no invented toolchain');
  assert.ok(!claude.includes('Runtime smoke'), 'no UI → no runtime smoke paragraph');
  assert.deepEqual(legacyContractCheck(claude), []);
});

test('runtime smoke paragraph is rendered only for rendered-UI projects', () => {
  const ui = renderTemplate('CLAUDE.md', fieldsFrom({ ...FACTS, workflow: { preset: 'trunk' } }), { ui: true, lsp: false });
  assert.match(ui, /Runtime smoke/);
  assert.match(ui, /src\/app\/\*\*/);
  const noUi = renderTemplate('CLAUDE.md', fieldsFrom({ ...FACTS, ui_paths: undefined, workflow: { preset: 'trunk' } }), { ui: false, lsp: false });
  assert.ok(!noUi.includes('Runtime smoke'));
});

test('code navigation section is rendered only when an LSP is declared', () => {
  const withLsp = renderTemplate('project-rules.md', fieldsFrom({ ...FACTS, lsp: { declared: true, tool: 'typescript-language-server' } }), { ui: false, lsp: true });
  assert.match(withLsp, /## Code Navigation \(LSP\)/);
  assert.match(withLsp, /typescript-language-server/);
  const without = renderTemplate('project-rules.md', fieldsFrom(FACTS), { ui: false, lsp: false });
  assert.ok(!without.includes('Code Navigation'));
  const root = project();
  applyRules({ projectRoot: root, facts: { ...FACTS, lsp: { declared: true, tool: 'gopls' } }, consent: true });
  const claude = fs.readFileSync(path.join(root, CLAUDE_FILE), 'utf8');
  assert.match(claude, /## Code Navigation \(LSP\)/);
  assert.deepEqual(legacyContractCheck(claude), []);
});

test('publish is derived from the profile: trunk → push, PR-gated presets → branch-local, never a hardcoded push', () => {
  assert.equal(derivePublish({ preset: 'trunk' }), 'push');
  assert.equal(derivePublish({ preset: 'feature-branch' }), 'branch-local');
  assert.equal(derivePublish({ preset: 'gitflow' }), 'branch-local');
  assert.equal(derivePublish({ preset: 'trunk', pr_required: true }), 'branch-local');
  assert.equal(derivePublish({ preset: 'trunk', trunk: 'main', protected: ['main'] }), 'branch-local');
  assert.equal(derivePublish({ preset: 'trunk', orchestrate_publish: 'branch-local' }), 'branch-local', 'an explicit stricter choice wins');
  assert.throws(() => derivePublish({ preset: 'gitflow', orchestrate_publish: 'push' }), /PR-gated/);
  assert.equal(derivePublish({}), null, 'no preset → unresolved, not an implicit push');
  const tpl = fs.readFileSync(path.join(REPO, 'harness-source/templates/CLAUDE.md'), 'utf8');
  assert.ok(!tpl.includes('**Orchestrate publish:** push'));
  assert.ok(tpl.includes('**Orchestrate publish:** {publish}'));
});

test('branch model renders six labelled assignments from the preset', () => {
  const bm = branchModel({ preset: 'gitflow', tracker: 'jira' });
  assert.equal(bm.trunk, 'main');
  assert.equal(bm.integration, 'develop');
  assert.equal(bm.protected, 'main, develop');
  assert.equal(bm['branch-pattern'], '<type>/<KEY>-<slug>');
  const trunk = branchModel({ preset: 'trunk' });
  assert.equal(trunk.protected, 'none');
  const override = branchModel({ preset: 'feature-branch', trunk: 'master', protected: ['master'] });
  assert.equal(override.trunk, 'master');
  const root = project();
  applyRules({ projectRoot: root, facts: { ...FACTS, workflow: { preset: 'gitflow' }, tracker: 'jira' }, consent: true });
  const claude = fs.readFileSync(path.join(root, CLAUDE_FILE), 'utf8');
  assert.match(claude, /\*\*Preset:\*\* gitflow · \*\*Trunk:\*\* `main` · \*\*Integration:\*\* `develop`/);
  assert.match(claude, /\*\*Protected:\*\* main, develop/);
  assert.deepEqual(legacyContractCheck(claude), []);
});

test('two populated authorities are a conflict that blocks rendering; a generated thin file never outranks a populated CLAUDE.md', () => {
  const root = project();
  fs.copyFileSync(path.join(REPO, 'CLAUDE.md'), path.join(root, CLAUDE_FILE));
  fs.mkdirSync(path.join(root, '.agents'), { recursive: true });
  fs.writeFileSync(path.join(root, RULES_FILE), `# Project rules\n\n${'real hand-written rule line\n'.repeat(12)}## Validation\n\nmake check\n`);
  const auth = resolveRulesAuthority(root);
  assert.equal(auth.mode, 'conflict');
  const res = applyRules({ projectRoot: root, facts: FACTS, consent: true });
  assert.equal(res.ok, false);
  fs.writeFileSync(path.join(root, RULES_FILE), renderTemplate('project-rules.md', fieldsFrom(FACTS)));
  const again = resolveRulesAuthority(root);
  assert.equal(again.mode, 'brownfield', 'a generated shared-rules file defers to the populated CLAUDE.md');
  assert.ok(again.warnings.some((w) => /CLAUDE\.md remains the authority/.test(w)));
});

test('legacy contract check rejects a gutted section, a placeholder publish value and an unassigned branch field', () => {
  const root = project();
  applyRules({ projectRoot: root, facts: FACTS, consent: true });
  const good = fs.readFileSync(path.join(root, CLAUDE_FILE), 'utf8');
  assert.ok(legacyContractCheck(good.replace('**Orchestrate publish:** branch-local', '**Orchestrate publish:** {push | branch-local}')).some((e) => /no real value/.test(e)));
  assert.ok(legacyContractCheck(good.replace('**Protected:** main', '**Protected:** {…}')).some((e) => /Protected/.test(e)));
  assert.ok(legacyContractCheck(good.replace('## Search Commands', '## Searching')).some((e) => /Search Commands/.test(e)));
  assert.ok(legacyContractCheck(good.replace(/git worktree remove --force.*\n/, '')).some((e) => /worktree/.test(e)));
});

test('a hand edit to project-rules.md is drift: not ready until the generated CLAUDE.md is re-synced; a hand-written CLAUDE.md is never overwritten', () => {
  const root = project();
  applyRules({ projectRoot: root, facts: FACTS, consent: true });
  assert.equal(resolveRulesAuthority(root).ready, true);
  const rules = path.join(root, RULES_FILE);
  fs.writeFileSync(rules, fs.readFileSync(rules, 'utf8').replace('npm run typecheck && npm run lint && npm test', 'make strict-check').replace('**Protected:** main', '**Protected:** main, release/*'));
  const drifted = resolveRulesAuthority(root);
  assert.equal(drifted.ready, false, 'the gate reads CLAUDE.md, which still carries the old command');
  assert.deepEqual(drifted.drift.map((d) => d.fact), ['validation-command', 'branch-model:Protected']);
  assert.ok(drifted.warnings.some((w) => /out of sync/.test(w)));
  const preview = applyRules({ projectRoot: root, facts: FACTS, consent: false });
  assert.equal(preview.ready, false);
  assert.ok(preview.actions.some((a) => a.file === CLAUDE_FILE && a.action === 'would-sync'), 'preview names the sync, writes nothing');
  assert.match(fs.readFileSync(path.join(root, CLAUDE_FILE), 'utf8'), /npm run typecheck/);
  const synced = applyRules({ projectRoot: root, facts: FACTS, consent: true });
  assert.ok(synced.actions.some((a) => a.file === CLAUDE_FILE && a.action === 'synced'));
  assert.equal(synced.ready, true);
  const claude = fs.readFileSync(path.join(root, CLAUDE_FILE), 'utf8');
  assert.match(claude, /```bash\nmake strict-check\n```/);
  assert.match(claude, /^\*\*Protected:\*\* main, release\/\*$/m);
  assert.ok(claude.includes('compatibility rendering'), 'only the mirrored values changed');
  assert.deepEqual(compatDrift(fs.readFileSync(rules, 'utf8'), claude), []);
  assert.equal(syncCompat(claude, fs.readFileSync(rules, 'utf8')), claude, 'sync is idempotent');

  // Brownfield: a hand-written CLAUDE.md is the authority and is never rewritten by a render.
  const brown = project();
  const hand = '# Rules\n\n## Validation\n\n```bash\nmake check\n```\n\nNever touch `legacy/`.\n';
  fs.writeFileSync(path.join(brown, CLAUDE_FILE), hand);
  applyRules({ projectRoot: brown, facts: FACTS, consent: true });
  assert.equal(fs.readFileSync(path.join(brown, CLAUDE_FILE), 'utf8'), hand);
});

test('a Validation section with prose but no command block is incomplete — the gate cannot run a sentence', () => {
  const root = project();
  applyRules({ projectRoot: root, facts: FACTS, consent: true });
  const rules = path.join(root, RULES_FILE);
  fs.writeFileSync(rules, fs.readFileSync(rules, 'utf8').replace(/```bash\nnpm run typecheck && npm run lint && npm test\n```/, 'Validation command not configured yet.'));
  const r = resolveRulesAuthority(root);
  assert.equal(r.ready, false);
  assert.ok(r.unresolved_required.includes('validation-command'));
  assert.ok(legacyContractCheck('## Language Rules\n\n## Validation\n\nRun the checks.\n\n## Git Workflow\n').some((e) => /no command block/.test(e)));
});

test('test policy and runtime smoke are mirrored too: a rules edit to either is drift, and sync carries it into the compat copy', () => {
  const root = project();
  applyRules({ projectRoot: root, facts: FACTS, consent: true });
  const rules = path.join(root, RULES_FILE);
  let text = fs.readFileSync(rules, 'utf8');
  text = text.replace('- Thin adapters / boilerplate / trivial getters — tests optional.', '- Thin adapters / boilerplate / trivial getters — tests optional.\n- Integration tests are **mandatory** for every route under `src/app/api/**`.');
  text = text.replace('touches `src/app/**`', 'touches `src/app/**` or `src/components/**`');
  fs.writeFileSync(rules, text);
  const drifted = resolveRulesAuthority(root);
  assert.equal(drifted.ready, false);
  assert.deepEqual(drifted.drift.map((d) => d.fact), ['test-policy', 'runtime-smoke']);
  applyRules({ projectRoot: root, facts: FACTS, consent: true });
  const claude = fs.readFileSync(path.join(root, CLAUDE_FILE), 'utf8');
  assert.match(claude, /Integration tests are \*\*mandatory\*\* for every route/);
  assert.match(claude, /touches `src\/app\/\*\*` or `src\/components\/\*\*`/);
  assert.equal(resolveRulesAuthority(root).ready, true);

  // A rules file that gains the runtime-smoke paragraph after a UI-less render: the paragraph is inserted, not dropped.
  const noUi = project();
  applyRules({ projectRoot: noUi, facts: { ...FACTS, app_surface: 'none', ui_paths: undefined }, consent: true });
  assert.ok(!fs.readFileSync(path.join(noUi, CLAUDE_FILE), 'utf8').includes('Runtime smoke'));
  const r2 = path.join(noUi, RULES_FILE);
  fs.writeFileSync(r2, fs.readFileSync(r2, 'utf8').replace('**Test policy — which layers MUST have tests:**', '**Runtime smoke — optional conditional step.** When a change touches `web/**` and an app is running, run the baseline → reload → diff check.\n\n**Test policy — which layers MUST have tests:**'));
  assert.deepEqual(resolveRulesAuthority(noUi).drift.map((d) => d.fact), ['runtime-smoke']);
  applyRules({ projectRoot: noUi, facts: { ...FACTS, app_surface: 'none', ui_paths: undefined }, consent: true });
  const c2 = fs.readFileSync(path.join(noUi, CLAUDE_FILE), 'utf8');
  assert.match(c2, /```\n\n\*\*Runtime smoke — optional conditional step\.\*\* When a change touches `web\/\*\*`/);
  assert.equal(resolveRulesAuthority(noUi).ready, true);
});

// ── fill (T05) ────────────────────────────────────────────────────────────────────────────────
// A minimal hand-written brownfield CLAUDE.md that satisfies legacyContractCheck, so a fill test
// can vary one thing at a time. Branch-model values are parameters; `bm: null` omits the
// assignments entirely, which is the real starter's shape.
function brownfield(dir, { bm = { preset: 'trunk', trunk: 'main', integration: 'main', names: '`<type>/<slug>` — types: feat, fix', dest: 'main', protectedList: 'none' }, publish = 'push', validation = 'npm test', extra = '' } = {}) {
  const model = bm === null ? '' : [
    `**Preset:** ${bm.preset} · **Trunk:** \`${bm.trunk}\` · **Integration:** \`${bm.integration}\``,
    `**Branch names:** ${bm.names}`,
    `**Base → PR dest:** ${bm.dest}`,
    `**Protected:** ${bm.protectedList}`,
  ].join('\n');
  const text = `# CLAUDE.md

Hand-written rules for this project.

## Language Rules

| Context | Language |
|---|---|
| Claude ↔ developer communication | **Polish** |

## Validation

\`\`\`bash
# Run in order
${validation}
\`\`\`
${extra}
## Commands

\`\`\`bash
npm run dev
\`\`\`

## Tech Stack

| Technology | Purpose |
|---|---|
| Node | runtime |

## Code Structure & Modularity

Files max 500 lines.

## Style & Conventions

ESLint.

## Error Handling

Specific exceptions only.

## Security

Never commit secrets.

## Git Workflow

- **\`git worktree remove --force\` can discard uncommitted work.** Its only guard is the pipeline's clean check.

**Orchestrate publish:** ${publish}

### Branch model

> _The single source of branch facts._

${model}

## Project Knowledge Layers

See \`.agents/memory/index.md\`.

## Automatic Behaviors

Read memory first.

## Search Commands

Use \`rg\`.
`;
  fs.mkdirSync(dir, { recursive: true });
  fs.writeFileSync(path.join(dir, CLAUDE_FILE), text);
  return text;
}

const TRUNK_FACTS = { language: 'pl', tracker: 'none', validation: 'npm run verify', workflow: { preset: 'trunk', trunk: 'main', integration: 'main', pr_dest: 'main', protected: [], merge: 'ff', branch_types: ['feat', 'fix'], orchestrate_publish: 'push' } };

test('fill 1: the real starter CLAUDE.md — absent branch fields are inserted in the template layout and the fence placeholders are replaced', () => {
  const root = project();
  const starter = fs.readFileSync(path.join(REPO, CLAUDE_FILE), 'utf8');
  fs.writeFileSync(path.join(root, CLAUDE_FILE), starter);
  // The shape this test exists for: the fields are ABSENT, not placeholder-valued, and the fence
  // placeholders ({typecheck-command} …) are not in PLACEHOLDERS so unresolved() cannot see them.
  assert.equal(/^\*\*Preset:\*\*/m.test(starter), false, 'starter must have no branch-model assignments');
  assert.match(starter, /\{typecheck-command\}/);
  assert.deepEqual(unresolved(starter).includes('typecheck-command'), false);
  assert.equal(resolveRulesAuthority(root).ready, false);

  const res = fillRules({ projectRoot: root, facts: { ...TRUNK_FACTS, validation: 'node scripts/check-harness.mjs --all' }, consent: true });
  assert.equal(res.ok, true);
  assert.equal(res.mode, 'brownfield');
  const after = fs.readFileSync(path.join(root, CLAUDE_FILE), 'utf8');
  // inserted, one combined line for Preset/Trunk/Integration — MIRRORED reads it whole
  assert.match(after, /^\*\*Preset:\*\* trunk · \*\*Trunk:\*\* `main` · \*\*Integration:\*\* `main`$/m);
  assert.match(after, /^\*\*Base → PR dest:\*\* main$/m);
  assert.match(after, /^\*\*Protected:\*\* none$/m);
  assert.match(after, /^node scripts\/check-harness\.mjs --all$/m);
  assert.doesNotMatch(after, /\{typecheck-command\}/);
  // the blockquote and the comment inside the fence survive byte-identically
  assert.ok(after.includes('> _Filled in by `/setup:create-CLAUDE_MD` at project bootstrap._'));
  assert.match(after, /# Run in order, stop on first failure/);
  const done = resolveRulesAuthority(root);
  assert.equal(done.ready, true);
  assert.deepEqual(done.unresolved_required, []);
});

test('fill 2: greenfield is refused with a reason, not half-served — both rule files stay byte-identical', () => {
  const root = project();
  applyRules({ projectRoot: root, facts: FACTS, consent: true });
  const rulesBefore = fs.readFileSync(path.join(root, RULES_FILE), 'utf8');
  const claudeBefore = fs.readFileSync(path.join(root, CLAUDE_FILE), 'utf8');
  const res = fillRules({ projectRoot: root, facts: FACTS, consent: true });
  assert.equal(res.ok, false);
  assert.equal(res.mode, 'greenfield');
  assert.match(res.reason, /generated/);
  assert.equal(fs.readFileSync(path.join(root, RULES_FILE), 'utf8'), rulesBefore);
  assert.equal(fs.readFileSync(path.join(root, CLAUDE_FILE), 'utf8'), claudeBefore);
});

test('fill 3: a resolved publish plus an empty branch model against a PR-gated fact set is a workflow contradiction', () => {
  const root = project();
  const before = brownfield(root, { bm: null, publish: 'push' });
  const res = fillRules({ projectRoot: root, facts: { ...TRUNK_FACTS, workflow: { preset: 'gitflow' } }, consent: true });
  assert.equal(res.ok, false);
  assert.equal(res.reason, 'workflow contradiction');
  assert.ok(res.drift.some((d) => d.fact === 'publish'));
  assert.equal(fs.readFileSync(path.join(root, CLAUDE_FILE), 'utf8'), before, 'nothing is written on a contradiction');
});

test('fill 4: omitted workflow facts are not a contradiction — a partial fill against a resolved workflow succeeds', () => {
  const root = project();
  brownfield(root, { extra: '\nArchitecture: {architecture}\n' });
  // fieldsFrom returns null for preset/trunk/integration here and still supplies a default
  // branch-pattern; comparing those against the resolved file would refuse every partial fill.
  const res = fillRules({ projectRoot: root, facts: { architecture: 'Layered.' }, consent: true });
  assert.equal(res.ok, true);
  assert.deepEqual(res.drift, []);
  const after = fs.readFileSync(path.join(root, CLAUDE_FILE), 'utf8');
  assert.match(after, /Architecture: Layered\./);
  assert.match(after, /^\*\*Preset:\*\* trunk · \*\*Trunk:\*\* `main`/m, 'the resolved workflow lines are untouched');
});

test('fill 5: a Jira rerun on unchanged facts reports no phantom contradiction', () => {
  const root = project();
  const facts = { ...TRUNK_FACTS, tracker: 'jira' };
  const f = fieldsFrom(facts);
  brownfield(root, { bm: { preset: f.preset, trunk: f.trunk, integration: f.integration, names: `\`${f['branch-pattern']}\` — types: ${f['branch-types']}`, dest: f['pr-dest'], protectedList: f.protected } });
  // fieldsFrom expands branchModel({ ...workflow, tracker }); dropping tracker would yield
  // `<type>/<slug>` instead of `<type>/<KEY>-<slug>` and fake a disagreement.
  assert.equal(f['branch-pattern'], '<type>/<KEY>-<slug>');
  const res = fillRules({ projectRoot: root, facts, consent: true });
  assert.equal(res.ok, true, `expected no contradiction, got ${JSON.stringify(res.drift)}`);
  assert.deepEqual(res.drift, []);
});

test('fill 6: --set cannot launder a workflow contradiction', () => {
  const root = project();
  const before = brownfield(root, { publish: 'push' });
  const res = fillRules({ projectRoot: root, facts: { ...TRUNK_FACTS, workflow: { preset: 'gitflow' } }, set: ['publish=push'], consent: true });
  assert.equal(res.ok, false);
  assert.equal(res.reason, 'workflow contradiction');
  assert.equal(fs.readFileSync(path.join(root, CLAUDE_FILE), 'utf8'), before);
});

test('fill 7: --set updates a resolved branch-model field and leaves every other section identical', () => {
  const root = project();
  const before = brownfield(root);
  const facts = { ...TRUNK_FACTS, workflow: { ...TRUNK_FACTS.workflow, trunk: 'develop' } };
  const res = fillRules({ projectRoot: root, facts, set: ['trunk=develop'], consent: true });
  assert.equal(res.ok, true, `unexpected refusal: ${res.reason} ${JSON.stringify(res.drift)}`);
  const after = fs.readFileSync(path.join(root, CLAUDE_FILE), 'utf8');
  assert.match(after, /\*\*Preset:\*\* trunk · \*\*Trunk:\*\* `develop` · \*\*Integration:\*\* `main`/, 'the combined line keeps its separators and backticks');
  assert.equal(after.replace('**Trunk:** `develop`', '**Trunk:** `main`'), before, 'only the overridden span changed');
});

test('fill 8: a resolved value is never changed without an explicit --set', () => {
  const root = project();
  const before = brownfield(root);
  const res = fillRules({ projectRoot: root, facts: { ...TRUNK_FACTS, workflow: { ...TRUNK_FACTS.workflow, trunk: 'main' } }, consent: true });
  assert.equal(res.ok, true);
  assert.equal(fs.readFileSync(path.join(root, CLAUDE_FILE), 'utf8'), before, 'resolved values stay put');
});

test('fill 9: a fill that would break the legacy contract writes nothing', () => {
  const root = project();
  const before = brownfield(root, { bm: null, validation: '{typecheck-command}' });
  // An empty validation value would gut the fence; the pre-write contract check must refuse.
  const res = fillRules({ projectRoot: root, facts: { ...TRUNK_FACTS, validation: '   ' }, consent: true });
  assert.equal(res.ok, false);
  assert.match(res.reason, /contract/);
  assert.equal(fs.readFileSync(path.join(root, CLAUDE_FILE), 'utf8'), before);
});

test('fill 10: two hand-written authorities are a conflict and fill refuses before any write', () => {
  const root = project();
  const before = brownfield(root);
  fs.mkdirSync(path.join(root, '.agents'), { recursive: true });
  fs.writeFileSync(path.join(root, RULES_FILE), '# Shared rules\n\nHand-written too.\n');
  const res = fillRules({ projectRoot: root, facts: TRUNK_FACTS, consent: true });
  assert.equal(res.ok, false);
  assert.equal(res.mode, 'conflict');
  assert.equal(fs.readFileSync(path.join(root, CLAUDE_FILE), 'utf8'), before);
});

test('fill 11: the shipped CLAUDE.md template renders inside the always-loaded cap on its own', () => {
  // The cap applies to the rendered file, and rendering substitutes arbitrary-length project text —
  // so this pins the template's own contribution, not the whole budget.
  const rendered = renderTemplate('CLAUDE.md', fieldsFrom({}));
  assert.ok(rendered.split('\n').length <= 165, `template is ${rendered.split('\n').length} lines`);
  assert.ok(Buffer.byteLength(rendered) <= 9500, `template is ${Buffer.byteLength(rendered)} B`);
});
