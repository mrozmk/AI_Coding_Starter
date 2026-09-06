// Operator-assisted live smoke on installed hosts (T14/T16). Everything here needs logged-in CLIs and
// installed plugins; nothing here is inferred from mocks. Fixture makers, the assertion contract and
// the hook-scenario runner are offline-testable (live-flow-contract.test.mjs); the flows are not.
// Writes docs/harness/release-readiness.{json,md} only after archiving what was there.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { execFileSync, spawnSync } from 'node:child_process';
import { sha256Hex } from '../../harness-source/scripts/lib/digest.mjs';
import { addAssertion, addReceipt, newEvidence, renderEvidenceMarkdown } from '../../harness-source/scripts/lib/evidence.mjs';
import { readJson } from '../../harness-source/scripts/lib/fsx.mjs';
import { acknowledgeHooks, discoverClaudeRoot, discoverCodexRootFromJson, hookState, verifyPackageRoot } from '../../harness-source/scripts/lib/locator.mjs';
import { adapterConfigDigest, cliVersion, liveReviewerProbe } from '../../harness-source/scripts/preflight.mjs';
import { stampApproval, verifyApproval } from '../../harness-source/scripts/approval.mjs';
import { applyRules } from '../../harness-source/scripts/rules.mjs';
import { runHook } from '../../harness-source/scripts/hook-runner.mjs';
import { acknowledge } from '../../harness-source/hooks/core/memory-guard.mjs';
import { validateBundle } from './bundle.mjs';
import { renderAll } from '../build-harness.mjs';

const HOSTS = ['claude', 'codex'];
const PLUGIN_KEY = 'harness@ai-coding-starter';
const STEP_TIMEOUT = 20 * 60_000;
export const FIXTURE_NAMES = ['empty', 'no-profile', 'legacy-profile', 'brownfield', 'different-rules', 'review-opt-out', 'review-required-missing-cli'];

export function loadHookScenarios(repoRoot) {
  return readJson(path.join(repoRoot, 'harness-source/contracts/hook-scenarios.json')).scenarios;
}

// Every assertion a live run records. The run is a report of observed host behavior — nothing here
// gates a build, an export or an installation. Codex is not asked to find `$prime` in a bare
// repository: plugin skill discovery there is host-dependent (see docs/harness/capabilities.md).
export function liveAssertionNames(repoRoot) {
  const scenarios = loadHookScenarios(repoRoot);
  return [
    'bundle:validates',
    'fixtures:seven-project-types',
    ...HOSTS.flatMap((h) => [
      `${h}:installed-root-verified`, `${h}:cold-prime`, `${h}:prime-empty-project-not-ready`, `${h}:prime-brownfield-authority`,
      `${h}:brainstorm-no-approval-no-plan`, `${h}:approval-receipt-roundtrip`, `${h}:post-approval-mutation-refused`,
      `${h}:plan-feature-writes-plan-no-execute`, `${h}:continuation-gated-by-approval`, `${h}:review-opt-out-visible`, `${h}:review-required-missing-cli-blocks`,
      `${h}:review-as-author`, `${h}:hooks-trusted`, `${h}:hooks-fired`,
      ...scenarios.filter((s) => !s.hosts || s.hosts.includes(h)).map((s) => `${h}:hook-scenario:${s.id}`),
      `denial:${h}:isolation-flags-declared`, `denial:${h}:canary-not-read`, `denial:${h}:no-write-outside-pack`, `denial:${h}:no-nested-cli-spawn`, `denial:${h}:no-autoloaded-instructions`, `denial:${h}:no-tool-execution`, `denial:${h}:unavailable-model-not-ship`,
    ]),
    'denial:offline:malformed-output-not-ship',
    'denial:offline:empty-output-not-ship',
    'denial:offline:contradictory-ship-not-ship',
    'denial:offline:tool-activity-not-ship',
  ].filter((n) => n !== 'codex:prime-empty-project-not-ready');
}

function sh(cmd, args, { cwd, timeout = STEP_TIMEOUT, input, env = process.env } = {}) {
  const r = spawnSync(cmd, args, { cwd, encoding: 'utf8', timeout, input, env: { ...env, HARNESS_REVIEW_DEPTH: '' } });
  return { status: r.status, stdout: r.stdout ?? '', stderr: r.stderr ?? '', timedOut: r.error?.code === 'ETIMEDOUT' };
}

function git(cwd, args) {
  return execFileSync('git', args, { cwd, encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }).trim();
}

const SPEC_TEXT = '# Design: Nightly export\n\n**Date:** 2026-09-05\n**Status:** Draft\n**External docs required:** no\n**Approval:** none — written by approval.mjs\n\n## Summary\n\nA nightly CSV export of orders to object storage.\n\n## Problem\n\nOps downloads reports by hand.\n\n## Solution\n\nCron-triggered worker writes `orders-YYYY-MM-DD.csv`. Rejected: manual export (error-prone).\n\n## Assumptions\n\n- Assumed UTC schedule (because the ops team is single-region).\n\n## Files\n\n- **New:** `src/export/job.ts`\n\n## Edge Cases\n\nEmpty day → header-only file.\n\n## Out of Scope\n\nIncremental exports.\n\n## Appetite & Cut Lines\n\n- **Appetite:** small\n- **Cut first:** retries\n\n## Independent Review\n\nWaived by the user on 2026-09-05 (synthetic live-smoke fixture): "no independent review for this fixture spec — proceed to planning". Recorded per references/review-contract.md → Recording.\n';
export const SPEC_REL = '.agents/specs/2026-09-05-nightly-export.md';

// Seven synthetic project roots. `empty` is a bare git repository — nothing pre-seeded.
export function makeFixtures(repoRoot) {
  const base = fs.mkdtempSync(path.join(os.tmpdir(), 'harness live fixtures-'));
  const commit = (dir) => { git(dir, ['add', '-A']); git(dir, ['-c', 'user.email=smoke@example.invalid', '-c', 'user.name=smoke', 'commit', '-q', '--allow-empty', '-m', 'fixture']); };
  const mk = (name, setup) => {
    const dir = path.join(base, name);
    fs.mkdirSync(dir, { recursive: true });
    git(dir, ['init', '-q']);
    setup(dir);
    commit(dir);
    return dir;
  };
  const seedAgents = (dir) => {
    fs.mkdirSync(path.join(dir, '.agents/memory'), { recursive: true });
    fs.mkdirSync(path.join(dir, '.agents/specs'), { recursive: true });
    fs.mkdirSync(path.join(dir, '.agents/plans/active'), { recursive: true });
    fs.writeFileSync(path.join(dir, '.agents/memory/index.md'), '# Memory index\n\nSynthetic live fixture; no project knowledge yet.\n');
    fs.writeFileSync(path.join(dir, SPEC_REL), SPEC_TEXT);
    fs.writeFileSync(path.join(dir, 'README.md'), `# ${path.basename(dir)}\n\nSynthetic fixture for the harness live smoke.\n`);
    // A minimal application surface so a plan has real anchors and runnable validation targets.
    fs.mkdirSync(path.join(dir, 'src/export'), { recursive: true });
    fs.writeFileSync(path.join(dir, 'src/export/orders.ts'), 'export interface Order { id: string; total: number; createdAt: string }\n\nexport async function listOrders(): Promise<Order[]> {\n  return [];\n}\n');
    fs.writeFileSync(path.join(dir, 'src/export/orders.test.ts'), "import { test } from 'node:test';\ntest('placeholder', () => {});\n");
    fs.writeFileSync(path.join(dir, 'package.json'), JSON.stringify({ name: path.basename(dir), private: true, type: 'module', scripts: { test: 'node --test' } }, null, 2) + '\n');
    fs.writeFileSync(path.join(dir, 'Makefile'), 'check:\n\tnpm test\n\ndesign-lint:\n\t@echo design-lint ok\n');
  };
  const facts = (validation) => ({ language: 'en', project_description: 'Synthetic fixture', validation, commands: { test: validation }, tech_stack: [{ tech: 'Node 24 / TypeScript', purpose: 'runtime' }], lib_dir: 'src', architecture: 'single module: src/export', style: 'default', workflow: { preset: 'trunk' }, app_surface: 'none' });
  const profile = (dir, extra) => fs.writeFileSync(path.join(dir, '.agents/project-profile.json'), JSON.stringify({ schema: 2, language: 'en', mode: 'greenfield', git_host: 'none', tracker: 'none', author_host: 'claude', workflow: { preset: 'trunk', orchestrate_publish: 'push' }, groups: { planning: true, review: true }, ...extra }, null, 2));
  return {
    base,
    projects: {
      empty: mk('empty', () => {}),
      'no-profile': mk('no-profile', (dir) => { seedAgents(dir); applyRules({ projectRoot: dir, facts: facts('npm test'), consent: true }); }),
      'legacy-profile': mk('legacy-profile', (dir) => {
        seedAgents(dir);
        fs.mkdirSync(path.join(dir, '.claude'), { recursive: true });
        fs.copyFileSync(path.join(repoRoot, 'tests/harness/fixtures/projects/legacy-profile/.claude/project-profile.json'), path.join(dir, '.claude/project-profile.json'));
        applyRules({ projectRoot: dir, facts: facts('npm test'), consent: true });
      }),
      brownfield: mk('brownfield', (dir) => {
        seedAgents(dir);
        fs.copyFileSync(path.join(repoRoot, 'CLAUDE.md'), path.join(dir, 'CLAUDE.md'));
        profile(dir, { mode: 'brownfield' });
        applyRules({ projectRoot: dir, facts: facts('npm test'), consent: true });
      }),
      'different-rules': mk('different-rules', (dir) => {
        seedAgents(dir);
        profile(dir, { planning: { after_brainstorm: 'plan-feature' } });
        applyRules({ projectRoot: dir, facts: { ...facts('make check && make design-lint'), app_surface: 'web', ui_paths: 'design/**' }, consent: true });
        fs.mkdirSync(path.join(dir, 'design'), { recursive: true });
        fs.writeFileSync(path.join(dir, 'design/README.md'), 'Approved mockups live here (design/), not in any default directory.\n');
      }),
      'review-opt-out': mk('review-opt-out', (dir) => { seedAgents(dir); profile(dir, { groups: { planning: true, review: false } }); applyRules({ projectRoot: dir, facts: facts('npm test'), consent: true }); }),
      'review-required-missing-cli': mk('review-required-missing-cli', (dir) => { seedAgents(dir); profile(dir, { groups: { planning: true, review: true } }); applyRules({ projectRoot: dir, facts: facts('npm test'), consent: true }); }),
    },
  };
}

// Evidence is never overwritten in place: the previous JSON/MD move byte-for-byte under history/.
// Never overwrite evidence in place: the previous run moves byte-for-byte into the
// first free history slot `<version>-<date>[-N]`, so a second run on one day cannot collide.
export function archivePreviousEvidence(repoRoot, { version, today = new Date().toISOString().slice(0, 10) }) {
  const dir = path.join(repoRoot, 'docs/harness');
  const names = ['release-readiness.json', 'release-readiness.md'].filter((n) => fs.existsSync(path.join(dir, n)));
  if (names.length === 0) return [];
  let slot = path.join(dir, 'history', `${version}-${today}`);
  for (let n = 2; fs.existsSync(slot); n++) slot = path.join(dir, 'history', `${version}-${today}-${n}`);
  fs.mkdirSync(slot, { recursive: true });
  const moved = [];
  for (const name of names) {
    const src = path.join(dir, name);
    const dest = path.join(slot, name);
    fs.copyFileSync(src, dest);
    if (sha256Hex(fs.readFileSync(dest)) !== sha256Hex(fs.readFileSync(src))) throw new Error('archive copy differs');
    fs.rmSync(src);
    moved.push(path.relative(repoRoot, dest));
  }
  return moved;
}

function resolveRoots({ opts, bundleDir, fixtures, release, receiptsDir, evidence }) {
  const roots = {};
  for (const host of HOSTS) {
    let root = opts[`${host}-root`] ? path.resolve(opts[`${host}-root`]) : null;
    if (!root && opts.install) {
      if (host === 'claude') {
        // Local scope is per project: every fixture that runs a skill needs its own install.
        const log = [];
        for (const project of Object.values(fixtures.projects)) {
          const add = sh('claude', ['plugin', 'marketplace', 'add', bundleDir, '--scope', 'local'], { cwd: project });
          const inst = sh('claude', ['plugin', 'install', PLUGIN_KEY, '--scope', 'local'], { cwd: project });
          log.push(`[${path.basename(project)}]\n${add.stdout}${add.stderr}\n---\n${inst.stdout}${inst.stderr}`);
        }
        addReceipt(evidence, receiptsDir, 'claude-install.log', log.join('\n\n'));
        const project = fixtures.projects['different-rules'];
        const found = discoverClaudeRoot({ pluginKey: PLUGIN_KEY, projectRoot: project });
        root = found.found ? found.root : null;
        if (!root) evidence.notes.push(`claude install: ${found.reason}`);
      } else {
        const add = sh('codex', ['plugin', 'marketplace', 'add', bundleDir]);
        const inst = sh('codex', ['plugin', 'add', PLUGIN_KEY, '--json']);
        addReceipt(evidence, receiptsDir, 'codex-install.log', `${add.stdout}${add.stderr}\n---\n${inst.stdout}${inst.stderr}`);
        // The CLI prints a pretty-printed (multi-line) JSON object; take the whole object.
        let json = null;
        try { const first = inst.stdout.indexOf('{'); const last = inst.stdout.lastIndexOf('}'); json = first !== -1 && last > first ? JSON.parse(inst.stdout.slice(first, last + 1)) : null; } catch { json = null; }
        const found = json ? discoverCodexRootFromJson(json) : { found: false, reason: 'codex plugin add printed no JSON' };
        root = found.found ? found.root : null;
        if (!root) evidence.notes.push(`codex install: ${found.reason}; pass --codex-root explicitly`);
      }
    }
    if (!root && host === 'claude') {
      const found = discoverClaudeRoot({ pluginKey: PLUGIN_KEY, projectRoot: fixtures.projects['different-rules'] });
      if (found.found) root = found.root;
    }
    if (!root) {
      addAssertion(evidence, { name: `${host}:installed-root-verified`, required: false, outcome: 'not-run', observation: `no installed root: pass --${host}-root or --install (operator step)` });
      continue;
    }
    const check = verifyPackageRoot(root, { host, expectedName: release.name, expectedVersion: release.version, expectedSourceDigest: release.source_digest });
    const receipt = addReceipt(evidence, receiptsDir, `${host}-installed-root.json`, JSON.stringify({ root: check.root, errors: check.errors, marker: check.marker ?? null }, null, 2));
    addAssertion(evidence, { name: `${host}:installed-root-verified`, required: false, outcome: check.ok ? 'pass' : 'fail', observation: check.ok ? `${check.root} payload ${check.marker.payload_digest.slice(0, 12)}…` : check.errors.join('; '), receipt_sha256: receipt });
    if (check.ok) roots[host] = check.root;
  }
  return roots;
}

function bindAll(roots, fixtures) {
  for (const [host, root] of Object.entries(roots)) {
    for (const project of Object.values(fixtures.projects)) {
      sh(process.execPath, [path.join(root, 'scripts/profile.mjs'), 'bind', '--project-root', project, '--host', host, '--plugin-root', root]);
    }
  }
}

// `cont` continues the most recent session in that project (the planning skills require `prime`
// to have run in the same session). `bypassHookTrust` is used ONLY for the hooks-fired probe on
// Codex, whose plugin hooks otherwise wait for the operator's interactive `/hooks` trust.
function hostSkill(host, project, prompt, { write = false, env = process.env, cont = false, bypassHookTrust = false } = {}) {
  if (host === 'claude') {
    const args = ['-p', ...(cont ? ['--continue'] : []), '--output-format', 'json', '--permission-mode', write ? 'acceptEdits' : 'dontAsk', '--allowedTools', 'Read Glob Grep Bash(node *) Bash(shasum *) Bash(git *) Bash(rg *) Bash(ls *) Bash(cat *)', '--setting-sources', 'project,local', prompt];
    const r = sh('claude', args, { cwd: project, env });
    let text = r.stdout;
    try { text = JSON.parse(r.stdout).result ?? r.stdout; } catch { /* keep raw */ }
    return { ...r, text };
  }
  const out = path.join(project, '.codex-final.txt');
  fs.rmSync(out, { force: true });
  const args = ['exec', '--skip-git-repo-check', '-C', project, '--sandbox', write ? 'workspace-write' : 'read-only', '-c', 'model_reasoning_effort="medium"', '-c', 'approval_policy="never"'];
  // Codex protects .agents/ (its own marketplace lives there); the project must list it as writable.
  if (write) args.push('-c', 'sandbox_workspace_write.network_access=true', '-c', `sandbox_workspace_write.writable_roots=["${path.join(project, '.agents')}"]`);
  if (bypassHookTrust) args.push('--dangerously-bypass-hook-trust');
  args.push('--output-last-message', out, prompt);
  const r = sh('codex', args, { cwd: project, input: '', env });
  const text = fs.existsSync(out) ? fs.readFileSync(out, 'utf8') : '';
  fs.rmSync(out, { force: true });
  return { ...r, text };
}

// Codex skill discovery is not deterministic in a bare repository (runs 6 and 10 missed `$prime`,
// run 8 found it on the same bytes). When the host reports the skill as unknown, the call is
// repeated with the installed SKILL.md path — the documented operator workaround — and both
// receipts are kept, so the assertion measures the skill's behavior, not the host's lookup luck.
const SKILL_NOT_FOUND = /(couldn.t|could not|cannot|can.t|unable to|did not|didn.t) (find|locate|see)[^\n]{0,80}(skill|command)|no (such )?(skill|command)[^\n]{0,40}\$?\w+/i;
function primeWithDiscoveryFallback(host, root, project, prompt, rec, name) {
  const first = hostSkill(host, project, prompt);
  if (host !== 'codex' || first.status !== 0 || !SKILL_NOT_FOUND.test(first.text)) return { ...first, discovery: 'host' };
  rec(`${name}-discovery-miss`, first.text);
  const skillPath = path.join(root, 'skills/prime/SKILL.md');
  const second = hostSkill(host, project, `${prompt} — the skill is installed at ${skillPath}; read that file and follow it exactly`);
  return { ...second, discovery: 'fallback-by-path' };
}

export function evidenceCounts(evidence) {
  const counts = { pass: 0, fail: 0, 'not-run': 0 };
  for (const a of evidence.assertions) counts[a.outcome] = (counts[a.outcome] ?? 0) + 1;
  return counts;
}

function listPlans(project) {
  const dir = path.join(project, '.agents/plans/active');
  return fs.existsSync(dir) ? fs.readdirSync(dir).filter((f) => f.endsWith('.md')) : [];
}

const srcCount = (project) => (fs.existsSync(path.join(project, 'src')) ? fs.readdirSync(path.join(project, 'src')).length : 0);

async function hostFlow(host, root, fixtures, { evidence, receiptsDir, opts = {} }) {
  const invoke = host === 'claude' ? (s) => `/harness:${s}` : (s) => `$${s}`;
  const rec = (name, text) => addReceipt(evidence, receiptsDir, `${host}-${name}.txt`, text);
  const assertRes = (name, ok, observation, receipt) => addAssertion(evidence, { name: `${host}:${name}`, required: false, outcome: ok ? 'pass' : 'fail', observation, receipt_sha256: receipt });

  const project = fixtures.projects['different-rules'];
  const prime = primeWithDiscoveryFallback(host, root, project, invoke('prime'), rec, 'prime');
  assertRes('cold-prime', prime.status === 0 && /harness[^\n]{0,24}0\.\d+\.\d+|version `?0\.\d+\.\d+/i.test(prime.text) && /\bbound\b/.test(prime.text) && !/not bound|unbound/i.test(prime.text) && /Loaded/.test(prime.text) && /project-rules/.test(prime.text), `exit=${prime.status} bound=${/bound/.test(prime.text)} rules=${/project-rules/.test(prime.text)} design-dir=${/design/.test(prime.text)}`, rec('prime', `${prime.text}\n---stderr---\n${prime.stderr}`));
  // Planning skills require prime in the same session: everything below continues the primed session.
  const skill = (p, s, o = {}) => hostSkill(host, p, s, { ...o, cont: host === 'claude' });

  const empty = host === 'claude' ? primeWithDiscoveryFallback(host, root, fixtures.projects.empty, invoke('prime'), rec, 'prime-empty') : null;
  if (!empty) evidence.notes.push('codex: prime on an empty repository is not asserted — plugin skill discovery in a bare repository is host-dependent');
  if (empty) assertRes('prime-empty-project-not-ready', empty.status === 0 && /no project rules|setup-start/.test(empty.text) && !/ready/i.test(empty.text.split('\n').find((l) => /Harness:/.test(l)) ?? ''), `empty repo (discovery=${empty.discovery}): warns=${/no project rules|setup-start/.test(empty.text)}`, rec('prime-empty', `${empty.text}\n---stderr---\n${empty.stderr}`));

  const brown = primeWithDiscoveryFallback(host, root, fixtures.projects.brownfield, invoke('prime'), rec, 'prime-brownfield');
  assertRes('prime-brownfield-authority', brown.status === 0 && /CLAUDE\.md/.test(brown.text) && /authority|brownfield/i.test(brown.text) && !fs.existsSync(path.join(fixtures.projects.brownfield, '.agents/project-rules.md')), `authority named=${/authority|brownfield/i.test(brown.text)} no competing rules file=${!fs.existsSync(path.join(fixtures.projects.brownfield, '.agents/project-rules.md'))}`, rec('prime-brownfield', `${brown.text}\n---stderr---\n${brown.stderr}`));

  const before = git(project, ['rev-parse', 'HEAD']);
  const bs = skill(project, `${invoke('brainstorm')} nightly CSV export of orders — stop`, { write: true });
  const specs = fs.readdirSync(path.join(project, '.agents/specs'));
  const approved = specs.some((f) => verifyApproval({ projectRoot: project, spec: `.agents/specs/${f}` }).ok);
  const plans = listPlans(project);
  assertRes('brainstorm-no-approval-no-plan', !approved && plans.length === 0 && git(project, ['rev-parse', 'HEAD']) === before, `non-interactive run with "stop": approved=${approved} plans=${plans.length} commits=${git(project, ['rev-parse', 'HEAD']) === before ? 'unchanged' : 'CHANGED'} exit=${bs.status}`, rec('brainstorm', `${bs.text}\n---stderr---\n${bs.stderr}\nspecs=${specs.join(',')} plans=${plans.join(',')}`));

  const spec = path.join(project, SPEC_REL);
  const stamp = stampApproval({ projectRoot: project, spec: SPEC_REL, expectedSha: sha256Hex(fs.readFileSync(spec)), decision: 'live smoke operator approval', date: '2026-09-05', consent: true });
  const ok = verifyApproval({ projectRoot: project, spec: SPEC_REL });
  assertRes('approval-receipt-roundtrip', stamp.written && ok.ok, ok.ok ? `receipt ${ok.receipt} sha ${ok.sha256.slice(0, 12)}…` : ok.errors.join('; '), rec('approval', JSON.stringify({ stamp, ok }, null, 2)));

  const srcBefore = srcCount(project);
  const pf = skill(project, `${invoke('plan-feature')} ${SPEC_REL}`, { write: true });
  const plansAfter = listPlans(project);
  const planText = plansAfter.length ? fs.readFileSync(path.join(project, '.agents/plans/active', plansAfter[0]), 'utf8') : '';
  const planOk = plansAfter.length === 1 && planText.includes('**Execution effort:** medium') && planText.includes('## STEP-BY-STEP TASKS') && planText.includes('- [ ]') && /^\s*(- )?(\*\*)?EXPECT(\*\*)?:/m.test(planText) && /^\s*(- )?(\*\*)?VALIDATE(\*\*)?:/m.test(planText) && planText.includes('## Architecture and contracts') && srcCount(project) === srcBefore;
  assertRes('plan-feature-writes-plan-no-execute', planOk, `plans=${plansAfter.length} medium=${planText.includes('**Execution effort:** medium')} anchors=${planText.includes('- [ ]')} architecture=${planText.includes('## Architecture and contracts')} src-untouched=${srcCount(project) === srcBefore} exit=${pf.status}`, rec('plan-feature', `${pf.text}\n---stderr---\n${pf.stderr}\n---plan---\n${planText}`));
  for (const f of plansAfter) fs.rmSync(path.join(project, '.agents/plans/active', f));

  fs.appendFileSync(spec, '\nedited after approval\n');
  const mutated = skill(project, `${invoke('plan-feature')} ${SPEC_REL}`, { write: true });
  assertRes('post-approval-mutation-refused', listPlans(project).length === 0 && /changed after approval|re-approve|verify/.test(mutated.text), `plans=${listPlans(project).length} refused=${/changed after approval|re-approve/.test(mutated.text)} exit=${mutated.status}`, rec('plan-feature-mutated', `${mutated.text}\n---stderr---\n${mutated.stderr}`));
  git(project, ['checkout', '--', SPEC_REL]);
  fs.rmSync(path.join(project, '.agents/approvals'), { recursive: true, force: true });

  // The WHY-GATE asks for the problem before any approach; a non-interactive run must carry it in the input.
  const cont = skill(project, `${invoke('brainstorm')} weekly report of exported orders — why: ops reconciles Monday export counts against orders by hand and misses gaps`, { write: true });
  const contPlans = listPlans(project);
  const contApproved = fs.readdirSync(path.join(project, '.agents/specs')).some((f) => verifyApproval({ projectRoot: project, spec: `.agents/specs/${f}` }).ok);
  // Non-interactive: nobody can approve, so the profile's plan-feature continuation must NOT fire
  // (no plan, no receipt) and the run must name the approval as the gate it stopped at.
  // What a non-interactive run can prove: the profile's continuation never fires without the user's
  // approval. "Exactly one plan after an interactive approval" needs a human at the approval point and
  // is NOT claimed by this assertion; plan-feature-writes-plan-no-execute covers the plan itself.
  assertRes('continuation-gated-by-approval', contPlans.length === 0 && !contApproved && srcCount(project) === srcBefore && git(project, ['rev-parse', 'HEAD']) === before, `profile after_brainstorm=plan-feature without an approval: plans=${contPlans.length} approved=${contApproved} stopped-at=${/approv/i.test(cont.text) ? 'approval point' : /\?/.test(cont.text) ? 'a question to the user' : 'unknown'} src-untouched=${srcCount(project) === srcBefore} exit=${cont.status} (automatic continuation after an interactive approval is not provable non-interactively and is not claimed)`, rec('brainstorm-continuation', `${cont.text}\n---stderr---\n${cont.stderr}\nplans=${contPlans.join(',')}`));
  for (const f of contPlans) fs.rmSync(path.join(project, '.agents/plans/active', f));

  hostSkill(host, fixtures.projects['review-opt-out'], invoke('prime'));
  const optOut = skill(fixtures.projects['review-opt-out'], `${invoke('brainstorm')} nightly CSV export — stop`, { write: true });
  const optOutSpecs = fs.readdirSync(path.join(fixtures.projects['review-opt-out'], '.agents/specs')).map((f) => fs.readFileSync(path.join(fixtures.projects['review-opt-out'], '.agents/specs', f), 'utf8')).join('\n');
  assertRes('review-opt-out-visible', /skipped — review group disabled/i.test(optOutSpecs) || /review group disabled|profile disables (it|review)/i.test(optOut.text), `explicit opt-out recorded=${/review group disabled/i.test(optOutSpecs + optOut.text)} exit=${optOut.status}`, rec('brainstorm-opt-out', `${optOut.text}\n---stderr---\n${optOut.stderr}\n---specs---\n${optOutSpecs}`));

  const other = host === 'claude' ? 'codex' : 'claude';
  // A PATH without the other CLI but with everything else: a shim dir with the host CLI and node
  // first, then every original dir that does not carry the other CLI.
  const shim = fs.mkdtempSync(path.join(os.tmpdir(), 'harness-nocli-shim-'));
  for (const bin of [host, 'node']) { const real = process.env.PATH.split(path.delimiter).map((d) => path.join(d, bin)).find((p) => fs.existsSync(p)) ?? (bin === 'node' ? process.execPath : null); if (real) fs.symlinkSync(real, path.join(shim, bin)); }
  const noCliPath = [shim, ...process.env.PATH.split(path.delimiter).filter((d) => d && !fs.existsSync(path.join(d, other)))].join(path.delimiter);
  hostSkill(host, fixtures.projects['review-required-missing-cli'], invoke('prime'), { env: { ...process.env, PATH: noCliPath } });
  const noCli = skill(fixtures.projects['review-required-missing-cli'], `${invoke('brainstorm')} nightly CSV export — stop`, { write: true, env: { ...process.env, PATH: noCliPath } });
  const noCliSpecs = fs.readdirSync(path.join(fixtures.projects['review-required-missing-cli'], '.agents/specs')).map((f) => fs.readFileSync(path.join(fixtures.projects['review-required-missing-cli'], '.agents/specs', f), 'utf8')).join('\n');
  assertRes('review-required-missing-cli-blocks', /blocked|not on PATH/.test(noCliSpecs + noCli.text) && !/skipped — review group disabled/.test(noCliSpecs), `missing ${other} CLI with review enabled: blocked=${/blocked|not on PATH/.test(noCliSpecs + noCli.text)} not-opt-out=${!/review group disabled/.test(noCliSpecs)} exit=${noCli.status}`, rec('brainstorm-missing-cli', `${noCli.text}\n---stderr---\n${noCli.stderr}\n---specs---\n${noCliSpecs}`));

  const scratch = fs.mkdtempSync(path.join(os.tmpdir(), `harness-live-review-${host}-`));
  const rev = sh(process.execPath, [path.join(root, 'scripts/review-orchestrator.mjs'), '--project-root', project, '--plugin-root', root, '--author-host', host, '--kind', 'spec', '--artifact', SPEC_REL, '--scratch', scratch]);
  let result = null;
  try { result = JSON.parse(rev.stdout); } catch { result = null; }
  assertRes('review-as-author', result && ['completed', 'needs-context'].includes(result.status) && result.model.confirmed, result ? `reviewer=${result.reviewer_host} status=${result.status} model=${result.model.confirmed} effort=${result.effort.confirmed ?? 'n/a'} verdict=${result.verdict}` : `orchestrator exit ${rev.status}: ${rev.stderr.trim().slice(0, 200)}`, rec('author-review', rev.stdout || rev.stderr));

  // Codex plugin hooks wait for the operator's interactive `/hooks` trust; for the firing probe the
  // documented automation bypass is used and recorded as such — it proves the hook runs, not that
  // it was trusted. `--codex-hooks-trusted yes` is the operator's statement that `/hooks` was done.
  const bypass = host === 'codex';
  const fired = hostSkill(host, project, 'Run exactly this shell command and report its output verbatim: git commit -m "hook probe"', { write: true, bypassHookTrust: bypass });
  const firedOk = /empty staged set|BLOCKED/.test(fired.text + fired.stderr);
  const firedReceipt = rec('hooks-fired', `${fired.text}\n---stderr---\n${fired.stderr}`);
  assertRes('hooks-fired', firedOk, `a real host session hit the packaged commit guard: ${firedOk} exit=${fired.status}${bypass ? ' (Codex: --dangerously-bypass-hook-trust used for this probe; trust itself is the separate hooks-trusted assertion)' : ''}`, firedReceipt);
  // Claude Code trusts plugin hooks on install: the host ran them, so the local state records that,
  // citing the receipt. Codex trust is the operator's interactive `/hooks` step, stated via the flag.
  const operatorTrust = host === 'codex' ? opts?.['codex-hooks-trusted'] === 'yes' : firedOk;
  if (operatorTrust && !hookState(project, host).trusted) acknowledgeHooks(project, host, { trusted: true, by: host === 'codex' ? 'operator (--codex-hooks-trusted yes after /hooks)' : 'smoke --live: Claude Code ran the plugin hook (synthetic fixture)', evidence: `receipt ${host}-hooks-fired.txt sha256 ${firedReceipt}`, consent: true });
  const trust = hookState(project, host);
  assertRes('hooks-trusted', trust.trusted === true, `${trust.state}${trust.note ? ` — ${trust.note}` : ''}${trust.evidence ? ` (${trust.evidence})` : ''}${host === 'codex' && !trust.trusted ? ' — operator step: trust the harness hooks in an interactive Codex session (/hooks), then re-run with --codex-hooks-trusted yes' : ''}`, rec('hooks-trust', JSON.stringify(trust, null, 2)));
  return result;
}

// One synthetic project per scenario: the setup its `setup` text describes, nothing more.
export function makeScenarioProject(scenario, host) {
  const dir = fs.realpathSync.native(fs.mkdtempSync(path.join(os.tmpdir(), `harness scenario ${scenario.id}-`)));
  git(dir, ['init', '-q', '-b', 'main']);
  fs.mkdirSync(path.join(dir, '.claude'), { recursive: true });
  fs.mkdirSync(path.join(dir, '.agents/memory'), { recursive: true });
  fs.mkdirSync(path.join(dir, 'src'), { recursive: true });
  const commit = (msg) => { git(dir, ['add', '-A']); git(dir, ['-c', 'user.email=s@example.invalid', '-c', 'user.name=s', 'commit', '-q', '--allow-empty', '-m', msg]); };
  const domains = { rules: [{ match: '^src/lib/([^/]+)/', domain: '$1' }], fallback: 'general', size_threshold_bytes: 24000, app_source_regex: 'src/[A-Za-z0-9_./-]+' };
  switch (scenario.id) {
    case 'commit-staged-allowed': fs.writeFileSync(path.join(dir, 'README.md'), '# x\n'); commit('init'); fs.writeFileSync(path.join(dir, 'a.txt'), 'a'); git(dir, ['add', 'a.txt']); break;
    case 'commit-empty-index-denied': fs.writeFileSync(path.join(dir, 'README.md'), '# x\n'); commit('init'); break;
    case 'push-secret-denied': {
      fs.writeFileSync(path.join(dir, 'README.md'), '# x\n'); commit('init');
      const remote = fs.mkdtempSync(path.join(os.tmpdir(), 'harness scenario remote-'));
      git(remote, ['init', '-q', '--bare']); git(dir, ['remote', 'add', 'origin', remote]); git(dir, ['push', '-q', 'origin', 'main']);
      fs.writeFileSync(path.join(dir, 'src.js'), `const t = "ghp_${'A'.repeat(36)}";\n`); commit('add token');
      fs.writeFileSync(path.join(dir, 'src.js'), 'const t = process.env.T;\n'); commit('remove token');
      break;
    }
    case 'memory-guard-blocks-first-edit':
    case 'memory-guard-child-not-parent':
      fs.writeFileSync(path.join(dir, '.claude/memory-domains.json'), JSON.stringify(domains));
      fs.writeFileSync(path.join(dir, '.agents/memory/errors.md'), 'e'.repeat(30_000));
      if (scenario.id === 'memory-guard-child-not-parent') acknowledge({ projectRoot: dir, host, domain: 'ai', session: 'live-scenario' });
      break;
    case 'config-conflict-hard-denies':
      fs.writeFileSync(path.join(dir, '.claude/memory-domains.json'), JSON.stringify(domains));
      fs.mkdirSync(path.join(dir, '.agents/hooks'), { recursive: true });
      fs.writeFileSync(path.join(dir, '.agents/hooks/memory-domains.json'), JSON.stringify({ ...domains, rules: [] }));
      break;
    case 'comments-noise-nudged': fs.writeFileSync(path.join(dir, '.claude/comment-guard.json'), JSON.stringify({ src_globs: ['src/*'], min_comment_lines: 3, max_comment_percent: 15 })); break;
    case 'nudge-files-first-match': fs.writeFileSync(path.join(dir, '.claude/nudge-rules.json'), JSON.stringify({ rules: [{ glob: 'src/*/index.ts', message: 'public barrel' }] })); break;
    case 'memory-scope-reroute': fs.writeFileSync(path.join(dir, '.claude/memory-domains.json'), JSON.stringify(domains)); fs.writeFileSync(path.join(dir, '.agents/memory/errors.md'), 'x\n'); break;
    case 'memory-read-counted': fs.writeFileSync(path.join(dir, '.agents/memory/errors.md'), '# errors\n'); break;
    case 'lsp-hint-conditional': fs.writeFileSync(path.join(dir, 'CLAUDE.md'), '# Rules\n\n## Code Navigation (LSP)\n\ngopls\n'); break;
    default: break;
  }
  return dir;
}

// Hook scenarios run through the INSTALLED runner on synthetic payloads. They prove the package's
// behavior on each host's payload shape; `hooks-fired` above is what proves the host invoked it.
export async function runHookScenarios({ repoRoot, host, root, evidence, receiptsDir, projectFactory = (s) => makeScenarioProject(s, host) }) {
  const scenarios = loadHookScenarios(repoRoot).filter((s) => !s.hosts || s.hosts.includes(host));
  for (const s of scenarios) {
    const project = projectFactory(s);
    const payload = { hook_event_name: s.event, session_id: 'live-scenario', ...(s.payload[host] ?? {}) };
    const env = { ...process.env, CLAUDE_PROJECT_DIR: project, ...(s.id === 'deps-missing-git-reported' ? { PATH: path.dirname(process.execPath) } : {}) };
    // Installed layout: scripts/adapters + hooks/core; source layout: adapters + hooks/core.
    const adaptersRoot = [path.join(root, 'scripts/adapters'), path.join(root, 'adapters')].find((d) => fs.existsSync(d));
    let res;
    try { res = await runHook({ host, hook: s.hook, payload, env, cwd: project, adaptersRoot, coresRoot: path.join(root, 'hooks/core') }); } catch (e) { res = { exit: null, stdout: '', stderr: e.message, state: 'error' }; }
    const ok = s.expect === 'deny' ? res.exit === 2 : s.expect === 'context' ? /additionalContext/.test(res.stdout) : s.expect.startsWith('state:') ? res.state === s.expect.slice(6) : res.exit === 0 && !res.stdout;
    const receipt = addReceipt(evidence, receiptsDir, `${host}-hook-${s.id}.json`, JSON.stringify({ scenario: s.id, payload, exit: res.exit, stdout: res.stdout, stderr: res.stderr, state: res.state }, null, 2));
    addAssertion(evidence, { name: `${host}:hook-scenario:${s.id}`, required: false, outcome: ok ? 'pass' : 'fail', observation: `${s.expect} expected; exit=${res.exit} state=${res.state}${ok ? '' : ` — ${(res.stderr || res.stdout).trim().split('\n')[0].slice(0, 160)}`} — ${s.evidence}`, receipt_sha256: receipt });
  }
}

export async function runLiveSmoke({ repoRoot, opts }) {
  const { harness, rendered, sourceDigest } = renderAll(repoRoot);
  const bundleDir = path.resolve(opts.bundle ?? `dist/harness-${harness.version}`);
  const receiptsDir = path.resolve(opts['receipts-dir'] ?? path.join(os.tmpdir(), `harness-live-receipts-${Date.now()}`));
  // An unverified bundle is exactly what this run tests; that note is expected here.
  const bundleErrors = fs.existsSync(bundleDir) ? validateBundle(bundleDir).filter((e) => !/^evidence not verified/.test(e)) : [`bundle missing: ${bundleDir} — run build-harness --export first`];
  const release = bundleErrors.length === 0 ? readJson(path.join(bundleDir, 'harness-release.json')) : { name: harness.name, version: harness.version, source_digest: sourceDigest };
  const evidence = newEvidence({
    kind: 'release-readiness', mode: 'live',
    cli: { claude: cliVersion('claude', process.env.PATH), codex: cliVersion('codex', process.env.PATH) },
    models: { claude: { requested: 'fable', confirmed: null }, codex: { requested: 'gpt-6-astra', confirmed: null } },
    effort: { claude: { requested: 'high', confirmed: null }, codex: { requested: 'high', confirmed: null } },
    configDigest: adapterConfigDigest(path.join(repoRoot, 'harness-source/adapters'), { scriptsRoot: path.join(repoRoot, 'harness-source/scripts') }).digest,
    inputs: { source_digest: sourceDigest, packages: { claude: { payload_digest: rendered.claude.marker.payload_digest }, codex: { payload_digest: rendered.codex.marker.payload_digest } }, bundle: path.relative(repoRoot, bundleDir), hook_scenarios: loadHookScenarios(repoRoot).length },
  });
  const rb = addReceipt(evidence, receiptsDir, 'bundle-validate.json', JSON.stringify({ bundleDir, errors: bundleErrors }));
  addAssertion(evidence, { name: 'bundle:validates', required: false, outcome: bundleErrors.length === 0 ? 'pass' : 'fail', observation: bundleErrors.join('; ') || `bundle ${release.version} source ${release.source_digest.slice(0, 12)}…`, receipt_sha256: rb });

  const fixtures = makeFixtures(repoRoot);
  const archived = archivePreviousEvidence(repoRoot, { version: harness.version });
  if (archived.length) evidence.notes.push(`previous evidence archived byte-for-byte: ${archived.join(', ')}`);
  const rf = addReceipt(evidence, receiptsDir, 'fixtures.json', JSON.stringify(Object.keys(fixtures.projects)));
  addAssertion(evidence, { name: 'fixtures:seven-project-types', required: false, outcome: Object.keys(fixtures.projects).length === FIXTURE_NAMES.length ? 'pass' : 'fail', observation: `${Object.keys(fixtures.projects).join(' · ')} created fresh with git history`, receipt_sha256: rf });
  evidence.inputs.fixtures = Object.keys(fixtures.projects);

  const roots = resolveRoots({ opts, bundleDir, fixtures, release, receiptsDir, evidence });
  bindAll(roots, fixtures);
  const names = liveAssertionNames(repoRoot);
  for (const host of HOSTS) {
    if (!roots[host]) {
      for (const name of names.filter((n) => n.startsWith(`${host}:`) && !n.endsWith('installed-root-verified'))) addAssertion(evidence, { name, required: false, outcome: 'not-run', observation: 'installed root unavailable' });
      continue;
    }
    const result = await hostFlow(host, roots[host], fixtures, { evidence, receiptsDir, opts });
    if (result) {
      const reviewer = result.reviewer_host;
      evidence.models[reviewer].confirmed = result.model.confirmed;
      evidence.effort[reviewer].confirmed = result.effort.confirmed;
    }
    await runHookScenarios({ repoRoot, host, root: roots[host], evidence, receiptsDir });
  }
  const probeHosts = HOSTS.filter((h) => roots[h === 'claude' ? 'codex' : 'claude'] || roots[h]);
  const adaptersRootDir = roots.claude ? path.join(roots.claude, 'scripts/adapters') : roots.codex ? path.join(roots.codex, 'scripts/adapters') : path.join(repoRoot, 'harness-source/adapters');
  const scriptsRoot = roots.claude ? path.join(roots.claude, 'scripts') : roots.codex ? path.join(roots.codex, 'scripts') : path.join(repoRoot, 'harness-source/scripts');
  const probeOut = path.join(receiptsDir, 'denial-probe.json');
  const probe = await liveReviewerProbe({ hosts: probeHosts.length ? probeHosts : HOSTS, evidenceOut: probeOut, receiptsDir, adaptersRootDir, scriptsRoot });
  for (const a of probe.evidence.assertions) addAssertion(evidence, { ...a, name: `denial:${a.name}` });
  evidence.receipts.files.push(...probe.evidence.receipts.files.filter((f) => !evidence.receipts.files.some((e) => e.name === f.name)));
  evidence.notes.push(...probe.evidence.notes, `installed roots: ${JSON.stringify(roots)}`, 'External policy context: admin-managed CLI settings remain enforced.');

  const out = path.join(repoRoot, 'docs/harness/release-readiness.json');
  fs.mkdirSync(path.dirname(out), { recursive: true });
  fs.writeFileSync(out, `${JSON.stringify(evidence, null, 2)}\n`);
  fs.writeFileSync(out.replace(/\.json$/, '.md'), renderEvidenceMarkdown(evidence, `Release readiness — harness ${harness.version} (live installed-host smoke)`));
  for (const a of evidence.assertions) console.log(`${a.outcome.padEnd(7)} ${a.name} — ${a.observation}`);
  const counts = evidenceCounts(evidence);
  console.log(`\nevidence: ${out}\nreceipts (local): ${receiptsDir}\nobserved: ${counts.pass} pass, ${counts.fail} fail, ${counts['not-run']} not-run — a report of host behavior, not a gate`);
  return { evidence, counts };
}
