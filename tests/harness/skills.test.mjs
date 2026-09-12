import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { renderAll } from '../../scripts/build-harness.mjs';
import { parseFrontmatter } from '../../harness-source/scripts/lib/frontmatter.mjs';

const REPO = path.resolve(import.meta.dirname, '../..');
const INVENTORY = JSON.parse(fs.readFileSync(path.join(REPO, 'harness-source/inventory.json'), 'utf8'));
const SKILL_ENTRIES = INVENTORY.entries.filter((e) => e.kind === 'skill');
const SKILLS = SKILL_ENTRIES.map((e) => e.id);
const read = (rel) => fs.readFileSync(path.join(REPO, rel), 'utf8');

test('every inventory skill exists with a flat kebab-case name matching its directory and inventory id', () => {
  assert.ok(SKILLS.length >= 24, `expected the planning, git and execution skills, got ${SKILLS.length}`);
  for (const id of SKILLS) {
    const { data, body } = parseFrontmatter(read(`harness-source/skills/${id}/SKILL.md`));
    assert.equal(data.name, id);
    assert.match(id, /^[a-z][a-z0-9-]*$/);
    assert.ok(data.description.length > 40, `${id} description`);
    assert.ok(!body.includes('$ARGUMENTS'), `${id} must describe its input, not rely on $ARGUMENTS`);
    assert.ok(!/\/Users\//.test(body), `${id} embeds a machine path`);
    assert.ok(!/\]\(\.\.\//.test(body), `${id} keeps a project-relative markdown link that breaks under skills/<id>/`);
  }
});

// `phase` is packaging provenance; `groups` is the capability gate, and 0.4.0 is the first release
// where the two diverge — `retro`/`simply` are phase `product` with no group at all, `jira` is phase
// `integration` gated on `tracker`. So the expectation is an explicit map covering every skill; a
// phase-derived one would fail on exactly those and get "fixed" by weakening the test.
const SKILL_GROUP = {
  prime: null, handoff: null, 'setup-start': null, retro: null, simply: null,
  brainstorm: 'planning', 'plan-feature': 'planning',
  commit: 'git', push: 'git', pull: 'git', release: 'git', 'pr-create': 'git', 'start-task': 'git',
  'create-prd': 'product', 'refresh-brief': 'product', 'create-backlog': 'product', 'stack-research': 'product', 'prime-ba': 'product',
  'prime-qa': 'qa', 'qa-verify': 'qa',
  jira: 'tracker', confluence: 'confluence',
  'gates-check-quality': 'execution', 'gates-verify-implementation': 'execution', 'gates-design-quality-check': 'execution',
  'deep-review': 'execution', analysis: 'execution', recon: 'execution', design: 'execution', 'test-e2e': 'execution',
  'architecture-review': 'execution', 'quick-change': 'execution', execute: 'execution', 'check-implementation': 'execution', orchestrate: 'execution',
};

// Skills that spell out their own Codex invocation. Not derived from `phase`: naming the Codex
// form is an editorial property of the skill body, not of where it was packaged from.
const CODEX_FORM_DECLARED = ['analysis', 'architecture-review', 'check-implementation', 'commit', 'deep-review', 'design',
  'execute', 'gates-check-quality', 'gates-design-quality-check', 'gates-verify-implementation', 'orchestrate',
  'pr-create', 'pull', 'push', 'quick-change', 'recon', 'release', 'start-task', 'test-e2e'];

test('every skill is covered by the group map', () => {
  assert.deepEqual(SKILLS.slice().sort(), Object.keys(SKILL_GROUP).sort(), 'a new skill must declare its group (or null) in SKILL_GROUP');
});

test('group-gated skills check their own group first and name nested skills for both hosts', () => {
  for (const [id, group] of Object.entries(SKILL_GROUP)) {
    const body = parseFrontmatter(read(`harness-source/skills/${id}/SKILL.md`)).body;
    const gate = /profile\.mjs groups[^\n]*`(?:groups\.)?([a-z]+)` must be `true`/.exec(body);
    if (group === null) {
      // An ungrouped session tool must assert the ABSENCE of a gate: an accidental one silently
      // takes the skill away from every project that never set that flag.
      assert.equal(gate, null, `${id}: ungrouped, yet it checks the \`${gate?.[1]}\` group`);
      continue;
    }
    assert.ok(gate, `${id}: no group check at all — expected \`${group}\``);
    assert.equal(gate[1], group, `${id}: gates on \`${gate[1]}\`, expected \`${group}\``);
  }
  // Every skill, whatever its phase: a nested call named for one host only is a call that silently
  // does not resolve on the other.
  for (const e of SKILL_ENTRIES) {
    const { body } = parseFrontmatter(read(e.source));
    for (const m of body.matchAll(/`\/harness:([a-z-]+)`/g)) assert.ok(body.includes(`\`$${m[1]}\` (Codex)`), `${e.id}: /harness:${m[1]} without its Codex twin`);
  }
  for (const id of CODEX_FORM_DECLARED) {
    const { body } = parseFrontmatter(read(`harness-source/skills/${id}/SKILL.md`));
    assert.ok(body.includes(`On Codex this skill is \`$${id}\``), `${id}: names its Codex form`);
  }
  for (const id of ['orchestrate', 'check-implementation', 'quick-change', 'architecture-review']) {
    assert.match(parseFrontmatter(read(`harness-source/skills/${id}/SKILL.md`)).body, /On Codex this skill refuses/, `${id}: Codex refusal`);
  }
  const release = parseFrontmatter(read('harness-source/skills/release/SKILL.md')).body;
  assert.match(release, /harness:documentation-manager/);
  assert.match(release, /on Codex, which has no agents/);
});

test('host metadata: Claude entries stay Skill-tool invocable (wrappers need it), Codex entries disable implicit invocation', () => {
  const { rendered } = renderAll(REPO);
  for (const id of SKILLS) {
    const claude = parseFrontmatter(rendered.claude.files.get(`skills/${id}/SKILL.md`).toString()).data;
    assert.equal(claude['disable-model-invocation'], undefined, `${id} claude: a frontmatter gate breaks the /${id} wrapper`);
    const yaml = rendered.codex.files.get(`skills/${id}/agents/openai.yaml`).toString();
    assert.match(yaml, /allow_implicit_invocation: false/, `${id} codex`);
    const codex = parseFrontmatter(rendered.codex.files.get(`skills/${id}/SKILL.md`).toString()).data;
    assert.deepEqual(Object.keys(codex), ['name', 'description']);
  }
  assert.equal(rendered.claude.marker.skills.brainstorm, 'skills/brainstorm/SKILL.md');
});

test('packaged pointers used by skills resolve inside the package (no checkout, no ../../source)', () => {
  const { rendered } = renderAll(REPO);
  for (const host of ['claude', 'codex']) {
    const files = rendered[host].files;
    for (const id of SKILLS) {
      const body = files.get(`skills/${id}/SKILL.md`).toString();
      assert.ok(!body.includes('../../harness-source/'), `${id} depends on the checkout`);
      for (const m of body.matchAll(/`((?:references|templates|schemas|scripts)\/[A-Za-z0-9_./-]+)`/g)) {
        assert.ok(files.has(m[1]), `${host}/${id}: ${m[1]} not packaged`);
      }
    }
  }
});

test('plan template and planning contract carry explicit medium and legacy-low semantics', () => {
  const plan = read('harness-source/templates/plan-feature-plan.template.md');
  assert.ok(plan.includes('**Execution effort:** medium'));
  assert.ok(plan.includes('**Spec SHA-256:**'));
  assert.ok(plan.includes('## STEP-BY-STEP TASKS') && plan.includes('- [ ]') && plan.includes('**EXPECT**') && plan.includes('**VALIDATE**'));
  const contract = read('harness-source/references/planning-contract.md');
  assert.match(contract, /explicit `low` in an older plan stays `low`/);
  assert.match(contract, /no\*\* field keeps the legacy `low` fallback/);
  assert.match(contract, /absent means `stop`/);
  assert.match(read('harness-source/skills/plan-feature/SKILL.md'), /\*\*Execution effort:\*\* medium/);
});

test('brainstorm: approval binds to the spec hash, stop wins, both continuation values, no auto-execute', () => {
  const b = read('harness-source/skills/brainstorm/SKILL.md');
  assert.match(b, /approval\.mjs stamp/);
  assert.match(b, /body-sha256/);
  assert.match(b, /Status:\*\* Approved/);
  assert.match(b, /`stop`, `only spec` or `no plan`/);
  assert.match(b, /\| yes \| any \| stop/);
  assert.match(b, /`stop` or absent \| stop/);
  assert.match(b, /`plan-feature` \| continue \*\*once\*\*/);
  assert.match(b, /never executed/);
  assert.match(b, /disable|user-only|blocks a nested/);
  assert.match(b, /never convert a blocked opinion into `ship`/i);
  const spec = read('harness-source/templates/brainstorm-spec.template.md');
  assert.match(spec, /\*\*Status:\*\* Draft/);
  assert.match(spec, /\*\*Approval:\*\*/);
  assert.match(spec, /hashed with this line excluded/);
  assert.match(spec, /## Independent Review/);
});

test('plan-feature refuses a spec whose bytes changed after approval and never picks by mtime', () => {
  const p = read('harness-source/skills/plan-feature/SKILL.md');
  assert.match(p, /never pick a spec by modification time/);
  assert.match(p, /approval\.mjs verify/);
  assert.match(p, /body-sha256/);
  assert.match(p, /never runs the plan/);
  assert.match(p, /Maximum three substantive rounds|maximum three substantive rounds/);
});

test('setup-start: consent-gated writes, no cache pruning, legacy-only routing, canonical vs legacy file', () => {
  const s = read('harness-source/skills/setup-start/SKILL.md');
  assert.match(s, /--consent yes/);
  assert.match(s, /never prune or edit the plugin cache/);
  assert.match(s, /Never create a second authoritative profile/);
  assert.match(s, /legacy bootstrap not installed/);
  assert.match(s, /profile\.mjs bind/);
  assert.match(s, /never inf/i);
  assert.match(read('harness-source/references/setup-contract.md'), /absent → `stop`/);
});

test('prime reports what it read and refuses checkout fallback; handoff stays project-local', () => {
  const p = read('harness-source/skills/prime/SKILL.md');
  assert.match(p, /check-version/);
  assert.match(p, /Never fall back to files from a starter checkout/);
  assert.match(p, /\*\*Loaded \(quick\|full\):\*\*/);
  const h = read('harness-source/skills/handoff/SKILL.md');
  assert.match(h, /\.agents\/handoffs\/handoff-YYYY-MM-DD/);
  assert.match(h, /never the plugin cache/);
});

test('review contract documents the isolation both adapters actually pass', () => {
  const r = read('harness-source/references/review-contract.md');
  const claude = JSON.parse(read('harness-source/adapters/claude-code/adapter.json')).reviewer.isolation;
  for (const flag of ['--restricted', '--safe-mode', '--strict-mcp-config']) assert.ok(claude.includes(flag) && r.includes(flag), flag);
  const codex = JSON.parse(read('harness-source/adapters/codex-cli/adapter.json')).reviewer;
  assert.equal(codex.sandbox, 'read-only');
  assert.match(r, /--sandbox read-only/);
  assert.match(r, /HARNESS_REVIEW_DEPTH=1/);
  assert.match(r, /Maximum three substantive rounds/);
});

test('brainstorm keeps the WHY-GATE obligation, backlog appetite inheritance and the ticket-vs-design rule', () => {
  const b = read('harness-source/skills/brainstorm/SKILL.md');
  assert.match(b, /WHY-GATE — mandatory/);
  assert.match(b, /ask for it first\*\*, and do not propose approaches until it is answered/);
  assert.match(b, /inherit them verbatim, do not re-derive/);
  assert.match(b, /the frame is the spec and the prose is a summary; \*\*behaviour\*\* stays with the ticket/);
  assert.match(b, /Record the contradiction in the spec's `## Open Questions`/);
});

test('plan split contract: user decision, parallel-track line, Execution Plan table with manual and effort, no table on a single file, re-measure', () => {
  const c = read('harness-source/references/plan-split-contract.md');
  assert.match(c, /never decided by the model/);
  assert.match(c, /\*\*stop without an answer\*\*/);
  assert.match(c, /Gate A — parallelism/);
  assert.match(c, /\*\*Parallel track:\*\* <name> — owns <file globs>/);
  assert.match(c, /No `## Execution Plan` section\*\* in any of them/);
  assert.match(c, /\| Step \| File \| Depends On \| Status \| Effort \|/);
  assert.match(c, /`pending` \| `in_progress` \| `done` \| `blocked` \| `skipped` \| `manual`/);
  assert.match(c, /Effort\*\* — `medium` for every step by default/);
  assert.match(c, /the model never downgrades a step on its own judgement/);
  assert.match(c, /must update `## Execution Plan` in the same edit\*\*/);
  assert.match(c, /\[<plan>-1-<descriptor>\.md\]\(\.\/<plan>-1-<descriptor>\.md\)/);
  assert.match(c, /single-file plan \*\*never\*\* carries `## Execution Plan`/);
  assert.match(c, /Umbrella status is opt-in, never inferred/);
  assert.match(c, /Re-measure every resulting file/);
  const p = read('harness-source/skills/plan-feature/SKILL.md');
  assert.match(p, /If the user chooses a split, read `references\/plan-split-contract.md`/);
  assert.match(p, /re-measure every plan file once more/);
  assert.match(p, /also updates `## Execution Plan` \(files on disk, dependencies, no cycles\)/);
  assert.match(p, /no usable `\*\*External docs required:\*\* yes \| no` line/);
  assert.match(read('harness-source/references/planning-contract.md'), /plan-split-contract\.md/);
  const inv = JSON.parse(read('harness-source/inventory.json'));
  assert.ok(inv.entries.find((e) => e.id === 'ref-plan-split-contract'), 'inventory lists the split contract');
  assert.ok(inv.entries.find((e) => e.id === 'plan-feature').dependencies.includes('ref-plan-split-contract'));
});

// The stage-2 migration deleted these paths and spellings; a body that still names one would send a
// reader (or a child process) to a file the release no longer ships.
test('no migrated skill body reaches back into the starter checkout', () => {
  for (const e of SKILL_ENTRIES.filter((x) => x.phase === 'execution')) {
    const { body } = parseFrontmatter(read(e.source));
    for (const banned of ['codex-bg.sh', 'git-baseline.sh', 'codex-spawn.md', '@orchestrator-', '/gates:', '.claude/skills/', '.claude/agents/', '.claude/lib/']) {
      assert.ok(!body.includes(banned), `${e.id} still names ${banned}`);
    }
  }
});

// File presence proves a port happened; it cannot prove the port kept what made the command safe.
// Each assertion below stands in for one behaviour whose loss is silent at runtime.
test('the QA skills preserve the guards their verdicts rest on', () => {
  const qa = parseFrontmatter(read('harness-source/skills/qa-verify/SKILL.md')).body;
  assert.match(qa, /registry §2/, 'the roster is consulted, not assumed');
  assert.match(qa, /no §2 row/, 'a family with no roster row routes to NEEDS-HUMAN naming the missing row');
  assert.match(qa, /registry §5/, 'the not-observable list still overrides any verifier conclusion');
  assert.match(qa, /§5 as \*\*unknown\*\*, never as empty|§5 as \*\*unknown\*\*/, 'an absent overlay is missing information, not an empty exclusion list');
  assert.match(qa, /browser_mcp_server|the named server is one the verifier can actually reach/i, 'the UI lane checks browser reachability before dispatch');
  // The two-altitude guard: does the verifier exist, and can it observe. Collapsing them produces
  // confident rows from unobserved evidence — the failure this skill exists to remove.
  assert.match(qa, /Guard an unavailable verifier/);
  assert.match(qa, /Guard unreachable tooling/);
  assert.match(qa, /two guards, not one/);

  for (const [id, procedure] of [['qa-verify', 'contract'], ['qa-verify', 'runtime-ui'], ['prime-qa', null]]) {
    if (!procedure) continue;
    assert.ok(parseFrontmatter(read(`harness-source/skills/${id}/SKILL.md`)).body.includes(`references/qa/${procedure}-procedure.md`), `${id} cites the ${procedure} procedure`);
  }
  const primeQa = parseFrontmatter(read('harness-source/skills/prime-qa/SKILL.md')).body;
  assert.match(primeQa, /references\/qa-evidence-families\.md/, 'prime-qa loads the framework half');
  assert.match(primeQa, /\.agents\/reference\/qa-evidence-families\.md/, 'prime-qa loads the project overlay, and warns when it is absent');
  assert.match(primeQa, /scripts\/qa-probe\.mjs/);
  assert.ok(!primeQa.includes('qa-probe.sh'), 'the retired shell probe is gone');

  // The verifier bodies are shared by both hosts; a Claude-only procedure would let the two drift.
  for (const rel of ['harness-source/references/qa/contract-procedure.md', 'harness-source/references/qa/runtime-ui-procedure.md']) {
    const text = read(rel);
    assert.match(text, /Both hosts read this file/, rel);
    assert.match(text, /registry §6/, `${rel}: the output contract`);
  }
});

test('confluence keeps its per-publish confirmation gate, not merely the word publish', () => {
  const body = parseFrontmatter(read('harness-source/skills/confluence/SKILL.md')).body;
  assert.match(body, /Publish is explicit and gated/);
  assert.match(body, /No draft mode — publish = live/, 'a publish goes live immediately; the dry-run must say so');
  assert.match(body, /Never publish because the user approved the \*content\*/, 'approving the draft is not approval to publish');
  assert.match(body, /Re-ask every time/);
});
