import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { renderAll } from '../../scripts/build-harness.mjs';
import { parseFrontmatter } from '../../harness-source/scripts/lib/frontmatter.mjs';

const REPO = path.resolve(import.meta.dirname, '../..');
const SKILLS = ['prime', 'brainstorm', 'plan-feature', 'setup-start', 'handoff'];
const read = (rel) => fs.readFileSync(path.join(REPO, rel), 'utf8');

test('five skills exist with flat kebab-case names matching their directory and inventory id', () => {
  for (const id of SKILLS) {
    const { data, body } = parseFrontmatter(read(`harness-source/skills/${id}/SKILL.md`));
    assert.equal(data.name, id);
    assert.match(id, /^[a-z][a-z0-9-]*$/);
    assert.ok(data.description.length > 40, `${id} description`);
    assert.ok(!body.includes('$ARGUMENTS'), `${id} must describe its input, not rely on $ARGUMENTS`);
    assert.ok(!/\/Users\//.test(body), `${id} embeds a machine path`);
  }
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
