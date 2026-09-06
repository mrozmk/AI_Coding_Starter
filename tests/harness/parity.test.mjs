import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { checkHookLedger, checkInstructionLedger, checkParity, loadLedgers, renderHookParity, renderInstructionParity } from '../../harness-source/scripts/lib/parity.mjs';

const REPO = path.resolve(import.meta.dirname, '../..');

test('production ledgers validate with nonzero counts', () => {
  const { errors, counts } = checkParity(REPO);
  assert.deepEqual(errors, []);
  assert.ok(counts.instructions >= 30, `instructions ${counts.instructions}`);
  assert.equal(counts.hooks, 11);
  assert.equal(counts.legacy_items, 16);
});

test('every legacy contract item is classified; an unclassified removal fails', () => {
  const { instructions } = loadLedgers(REPO);
  const broken = structuredClone(instructions);
  broken.entries = broken.entries.filter((e) => e.legacy.item !== 'Search Commands');
  assert.ok(checkInstructionLedger(broken, REPO).some((e) => /not classified: Search Commands/.test(e)));
});

test('a reference to an absent owner, test or destination-less row is rejected', () => {
  const { instructions } = loadLedgers(REPO);
  const noOwner = structuredClone(instructions);
  noOwner.entries[0].owner = 'harness-source/templates/does-not-exist.md';
  assert.ok(checkInstructionLedger(noOwner, REPO).some((e) => /owner does not exist/.test(e)));
  const noTest = structuredClone(instructions);
  noTest.entries[0].check.test = 'tests/harness/ghost.test.mjs';
  assert.ok(checkInstructionLedger(noTest, REPO).some((e) => /check test missing/.test(e)));
  const noDest = structuredClone(instructions);
  noDest.entries[0].destinations = { claude: null, codex: null };
  assert.ok(checkInstructionLedger(noDest, REPO).some((e) => /no destination on either host/.test(e)));
});

test('a gap or legacy-only row can be recorded but never certified; retirement needs a decision', () => {
  const { instructions } = loadLedgers(REPO);
  const gap = structuredClone(instructions);
  const row = gap.entries.find((e) => e.status === 'gap');
  assert.ok(row, 'the ledger records at least one honest gap');
  row.verified = true;
  assert.ok(checkInstructionLedger(gap, REPO).some((e) => /cannot be marked verified/.test(e)));
  const retired = structuredClone(instructions);
  retired.entries[0].status = 'retired';
  assert.ok(checkInstructionLedger(retired, REPO).some((e) => /retired needs rationale and decision/.test(e)));
  retired.entries[0].rationale = 'superseded';
  retired.entries[0].decision = 'team decision recorded in the release notes';
  assert.ok(!checkInstructionLedger(retired, REPO).some((e) => /retired needs/.test(e)));
});

test('hook ledger covers all 11 legacy hooks with a core owner, per-host state and a test', () => {
  const { hooks } = loadLedgers(REPO);
  assert.deepEqual(checkHookLedger(hooks, REPO), []);
  const legacy = fs.readdirSync(path.join(REPO, '.claude/hooks')).filter((f) => f.endsWith('.sh'));
  assert.equal(hooks.hooks.length, legacy.length);
  for (const h of hooks.hooks) {
    for (const host of ['claude', 'codex']) assert.ok(h.hosts[host].state, `${h.id} ${host}`);
  }
  assert.equal(hooks.activation, 'none', 'unit tests never activate hooks');
  const project = hooks.hooks.find((h) => h.id === 'check-project-deps');
  assert.equal(project.core, null, 'project-owned preflight is never packaged');
  assert.equal(hooks.hooks.find((h) => h.id === 'nudge-lsp').hosts.codex.state, 'legacy-only');
  assert.ok(hooks.hooks.every((h) => h.strength !== 'hard' || Object.values(h.hosts).every((x) => /exit 2/.test(x.response ?? ''))), 'hard blockers deny synchronously on both hosts');

  const missingCore = structuredClone(hooks);
  missingCore.hooks[0].core = 'harness-source/hooks/core/nope.mjs';
  assert.ok(checkHookLedger(missingCore, REPO).some((e) => /core missing/.test(e)));
  const retired = structuredClone(hooks);
  retired.hooks[0].hosts.codex.state = 'retired';
  assert.ok(checkHookLedger(retired, REPO).some((e) => /retirement needs rationale/.test(e)));
  const activated = structuredClone(hooks);
  activated.activation = 'verified';
  assert.ok(checkHookLedger(activated, REPO).some((e) => /activation_evidence/.test(e)));
});

test('an unlisted legacy hook script is an unclassified removal', () => {
  const { hooks } = loadLedgers(REPO);
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'harness-parity-'));
  fs.mkdirSync(path.join(tmp, 'hooks'));
  fs.writeFileSync(path.join(tmp, 'hooks/extra.sh'), '#!/bin/bash\n');
  const errors = checkHookLedger(hooks, REPO, { legacyHooksDir: path.relative(REPO, path.join(tmp, 'hooks')) });
  assert.ok(errors.some((e) => /legacy hook not in the ledger: .*extra\.sh/.test(e)));
});

test('rendered Markdown names every row and its status', () => {
  const { instructions, hooks } = loadLedgers(REPO);
  const md = renderInstructionParity(instructions);
  for (const e of instructions.entries) assert.ok(md.includes(`\`${e.id}\``));
  assert.match(md, /## Not certified/);
  const hm = renderHookParity(hooks);
  for (const h of hooks.hooks) assert.ok(hm.includes(`\`${h.id}\``));
  assert.match(hm, /Activation: \*\*none\*\*/);
});
