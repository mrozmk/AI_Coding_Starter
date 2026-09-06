import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { MAX_ROUNDS, roundsLedger, runReview } from '../../harness-source/scripts/review-orchestrator.mjs';
import { judgeOutput, normalizeMissingContext, readReviewResult, validateReviewResult } from '../../harness-source/scripts/review-result.mjs';
import { syntheticProfile } from '../../harness-source/scripts/profile.mjs';
import { buildSpawn as codexSpawn } from '../../harness-source/adapters/codex-cli/review.mjs';

const FIX = path.join(import.meta.dirname, 'fixtures');
const MOCK_BIN = path.join(FIX, 'mock-bin');
const EMPTY_BIN = path.join(FIX, 'empty-bin');
const ADAPTERS = path.resolve(import.meta.dirname, '../../harness-source/adapters');
const ART = '.agents/specs/2026-01-01-fixture.md';

function project() {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'harness review-contract-'));
  fs.cpSync(path.join(FIX, 'projects/with-private-inputs'), dir, { recursive: true });
  return dir;
}
function plugin() {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'harness-rc-plugin-'));
  fs.mkdirSync(path.join(dir, 'skills/prime'), { recursive: true });
  fs.writeFileSync(path.join(dir, 'skills/prime/SKILL.md'), '---\nname: prime\ndescription: p\n---\nprime\n');
  return dir;
}
const env = (mode, extra = {}) => ({ PATH: `${MOCK_BIN}${path.delimiter}${path.dirname(process.execPath)}`, HOME: os.homedir(), MOCK_MODE: mode, ...extra });
async function review(authorHost, mode, { scratch = fs.mkdtempSync(path.join(os.tmpdir(), 'harness-rc-scratch-')), ...opts } = {}) {
  const result = await runReview({ projectRoot: opts.projectRoot ?? project(), pluginRoot: plugin(), authorHost, artifacts: [ART], deps: ['dep.mjs'], scratchDir: scratch, kind: 'spec', adaptersRoot: ADAPTERS, env: env(mode), timeoutMs: 30_000, profile: syntheticProfile({ author_host: authorHost }), ...opts });
  return { result, scratch };
}

test('early blocked results persist into a fresh scratch directory', async () => {
  const scratch = path.join(fs.mkdtempSync(path.join(os.tmpdir(), 'harness-rc-fresh-')), 'nested', 'scratch');
  assert.ok(!fs.existsSync(scratch));
  const result = await runReview({ projectRoot: project(), pluginRoot: plugin(), authorHost: 'claude', artifacts: [ART], scratchDir: scratch, adaptersRoot: ADAPTERS, env: { PATH: EMPTY_BIN }, profile: syntheticProfile() });
  assert.equal(result.status, 'failed');
  const files = fs.readdirSync(scratch).filter((f) => f.startsWith('review-'));
  assert.equal(files.length, 1, 'the blocked result is on disk');
  assert.equal(readReviewResult(path.join(scratch, files[0])).status, 'failed');
  const missing = await runReview({ projectRoot: project(), pluginRoot: plugin(), authorHost: 'claude', artifacts: ['.agents/specs/nope.md'], scratchDir: path.join(scratch, 'two'), adaptersRoot: ADAPTERS, env: env('ok'), profile: syntheticProfile() });
  assert.equal(missing.status, 'needs-context');
  assert.ok(fs.readdirSync(path.join(scratch, 'two')).some((f) => f.startsWith('review-')));
});

test('ship with critical/major/fundamental findings, invalid evidence references, CLI error envelopes and unexpected tool activity are rejected', async () => {
  const contradictory = await review('codex', 'contradictory');
  assert.equal(contradictory.result.status, 'failed');
  assert.match(contradictory.result.error, /contradictory result: verdict ship/);
  const contradictoryCodex = await review('claude', 'contradictory');
  assert.equal(contradictoryCodex.result.status, 'failed');
  const badEvidence = await review('codex', 'bad-evidence');
  assert.equal(badEvidence.result.status, 'failed');
  assert.match(badEvidence.result.error, /evidence_read names paths not in the pack: \/etc\/passwd/);
  const envelope = await review('codex', 'error-envelope');
  assert.equal(envelope.result.status, 'failed');
  assert.match(envelope.result.error, /error envelope/);
  const tool = await review('claude', 'tool');
  assert.equal(tool.result.status, 'failed');
  assert.match(tool.result.error, /unexpected tool\/delegation activity/);
  const sub = await review('codex', 'subagent');
  assert.equal(sub.result.status, 'failed');
  assert.match(sub.result.error, /subagent/);
  const denied = await review('codex', 'denied');
  assert.equal(denied.result.status, 'failed');
  assert.match(denied.result.error, /denied attempt/);
  const ship = await review('claude', 'ship');
  assert.equal(ship.result.status, 'completed', ship.result.error);
  assert.equal(ship.result.verdict, 'ship', 'ship with only minor findings is consistent');
  assert.deepEqual(validateReviewResult(ship.result), []);
});

test('missing context is typed; required unresolved items block; no heuristic manufactures completed', async () => {
  const typed = await review('codex', 'gap-typed');
  assert.equal(typed.result.status, 'needs-context');
  assert.deepEqual(typed.result.missing_context.map((m) => m.kind), ['required-decision', 'external-fact']);
  const codexTyped = await review('claude', 'gap-typed');
  assert.equal(codexTyped.result.status, 'needs-context');
  assert.deepEqual(codexTyped.result.missing_context, [{ kind: 'missing-file', detail: 'src/export/job.ts' }]);
  assert.deepEqual(normalizeMissingContext(['x', { kind: 'bogus', detail: 'y' }]), [{ kind: 'unspecified', detail: 'x' }, { kind: 'unspecified', detail: 'y' }]);
  const judged = judgeOutput({ verdict: 'ship', findings: [], evidence_read: ['CLAUDE.md'], missing_context: [{ kind: 'required-decision', detail: 'currency per locale' }] }, { packPaths: ['CLAUDE.md'] });
  assert.equal(judged.status, 'needs-context');
  assert.equal(judgeOutput({ verdict: 'ship', findings: [], evidence_read: [], missing_context: [] }, { toolUses: { count: 0, turns: 1, subagents_spawned: 0, permission_denials: 0 } }).status, 'completed');
  assert.equal(judgeOutput({ verdict: 'ship', findings: [], evidence_read: [], missing_context: [] }, { toolUses: { turns: 3, count: 0, permission_denials: 0 } }).status, 'completed', 'turns alone are not activity (structured output costs a turn)');
  assert.equal(judgeOutput({ verdict: 'ship', findings: [], evidence_read: [], missing_context: [] }, { isError: true }).status, 'failed');
  // a schema-1 record (string gaps) is still readable through the versioned reader
  const legacy = { ...typed.result, schema_version: 1, missing_context: ['old string gap'] };
  const file = path.join(typed.scratch, 'legacy.json');
  fs.writeFileSync(file, JSON.stringify(legacy));
  assert.deepEqual(readReviewResult(file).missing_context, [{ kind: 'unspecified', detail: 'old string gap' }]);
});

test('supplying the missing context after needs-context is neither a repeat nor a round; a dry run writes the outbound manifest and sends nothing', async () => {
  const scratch = fs.mkdtempSync(path.join(os.tmpdir(), 'harness-rc-ctx-'));
  const root = project();
  const gap = await review('codex', 'gap-typed', { scratch, projectRoot: root });
  assert.equal(gap.result.status, 'needs-context');
  const supplied = await review('codex', 'ok', { scratch, projectRoot: root });
  assert.equal(supplied.result.status, 'completed', supplied.result.error);
  assert.match(supplied.result.repeat_reason, /context supplied/);
  assert.equal(roundsLedger(scratch, [ART]).substantive, 1, 'the needs-context run never counted as an opinion');
  const dryScratch = fs.mkdtempSync(path.join(os.tmpdir(), 'harness-rc-dry-'));
  const record = path.join(os.tmpdir(), `mock-record-dry-${Date.now()}.json`);
  const dry = await runReview({ projectRoot: root, pluginRoot: plugin(), authorHost: 'claude', artifacts: [ART], deps: ['dep.mjs'], scratchDir: dryScratch, kind: 'spec', adaptersRoot: ADAPTERS, env: env('ok', { MOCK_RECORD: record }), timeoutMs: 30_000, profile: syntheticProfile(), dryRun: true });
  assert.equal(dry.status, 'skipped');
  assert.match(dry.error, /dry run/);
  assert.ok(!fs.existsSync(record), 'no reviewer process was spawned');
  const runDir = fs.readdirSync(dryScratch).find((d) => d.startsWith('run-'));
  const manifest = JSON.parse(fs.readFileSync(path.join(dryScratch, runDir, 'pack.outbound.json'), 'utf8'));
  assert.equal(manifest.provider, 'openai');
  assert.ok(manifest.files.some((f) => f.path === ART));
  const real = await review('claude', 'ok', { scratch: fs.mkdtempSync(path.join(os.tmpdir(), 'harness-rc-real-')), projectRoot: root });
  assert.ok(real.result.notes.some((n) => /outbound manifest: .*pack\.outbound\.json/.test(n)), 'a real run records where the manifest is');
  // A preview between two opinions leaves the ledger untouched: the next material round still runs.
  const seq = fs.mkdtempSync(path.join(os.tmpdir(), 'harness-rc-seq-'));
  const first = await review('claude', 'ok', { scratch: seq, projectRoot: root });
  assert.equal(first.result.status, 'completed');
  const preview = await runReview({ projectRoot: root, pluginRoot: plugin(), authorHost: 'claude', artifacts: [ART], deps: ['dep.mjs'], scratchDir: seq, kind: 'spec', adaptersRoot: ADAPTERS, env: env('ok'), timeoutMs: 30_000, profile: syntheticProfile(), dryRun: true, changes: ['scope'] });
  assert.equal(preview.status, 'skipped');
  assert.ok(!fs.readdirSync(seq).some((f) => f.startsWith('review-') && fs.readFileSync(path.join(seq, f), 'utf8').includes('dry run')), 'no result file for a preview');
  const second = await review('claude', 'ok', { scratch: seq, projectRoot: root, changes: ['scope'] });
  assert.equal(second.result.status, 'completed', second.result.error);
  assert.equal(second.result.round, 2);
  // Supplying context is bounded: after MAX_CONTEXT_SUPPLIES needs-context runs the gaps go to the user.
  const ctx = fs.mkdtempSync(path.join(os.tmpdir(), 'harness-rc-ctxlimit-'));
  assert.equal((await review('codex', 'gap-typed', { scratch: ctx, projectRoot: root })).result.status, 'needs-context');
  assert.equal((await review('codex', 'gap-typed', { scratch: ctx, projectRoot: root })).result.status, 'needs-context');
  const third = await review('codex', 'gap-typed', { scratch: ctx, projectRoot: root });
  assert.equal(third.result.status, 'skipped');
  assert.equal(third.result.requires_user_decision, true);
  assert.match(third.result.error, /not converging/);
});

test('the orchestrator supervises the max-three ledger per artifact lineage and separates technical retries', async () => {
  const scratch = fs.mkdtempSync(path.join(os.tmpdir(), 'harness-rc-ledger-'));
  const root = project();
  const r1 = await review('claude', 'ok', { scratch, projectRoot: root });
  assert.equal(r1.result.status, 'completed');
  assert.equal(r1.result.round, 1);
  const editorial = await review('claude', 'ok', { scratch, projectRoot: root, changes: ['typo'] });
  assert.equal(editorial.result.status, 'skipped');
  assert.match(editorial.result.error, /repeat refused: editorial change/);
  const r2 = await review('claude', 'ok', { scratch, projectRoot: root, changes: ['scope'] });
  assert.equal(r2.result.status, 'completed');
  assert.equal(r2.result.round, 2);
  assert.match(r2.result.repeat_reason, /material change: scope/);
  const r3 = await review('claude', 'ok', { scratch, projectRoot: root, changes: ['api'] });
  assert.equal(r3.result.round, 3);
  assert.equal(roundsLedger(scratch, [ART]).substantive, MAX_ROUNDS);
  const r4 = await review('claude', 'ok', { scratch, projectRoot: root, changes: ['api'] });
  assert.equal(r4.result.status, 'skipped');
  assert.equal(r4.result.requires_user_decision, true);
  assert.match(r4.result.error, /3 substantive rounds/);
  assert.equal(roundsLedger(scratch, [ART]).substantive, MAX_ROUNDS, 'a refusal is not a round');

  const other = fs.mkdtempSync(path.join(os.tmpdir(), 'harness-rc-ledger2-'));
  const fail = await review('claude', 'auth', { scratch: other, projectRoot: root });
  assert.equal(fail.result.status, 'failed');
  const retryRefused = await review('claude', 'ok', { scratch: other, projectRoot: root, changes: ['scope'] });
  assert.equal(retryRefused.result.status, 'completed', 'a technical failure is not a substantive round, so the next opinion is round 1');
  assert.equal(retryRefused.result.round, 1);
  const wrongRetry = await review('claude', 'ok', { scratch: other, projectRoot: root, technicalRetry: true });
  assert.equal(wrongRetry.result.status, 'skipped');
  assert.match(wrongRetry.result.error, /technical retry refused/);
  const third = fs.mkdtempSync(path.join(os.tmpdir(), 'harness-rc-ledger3-'));
  await review('claude', 'auth', { scratch: third, projectRoot: root });
  const okRetry = await review('claude', 'ok', { scratch: third, projectRoot: root, technicalRetry: true });
  assert.equal(okRetry.result.status, 'completed');
  assert.ok(okRetry.result.notes.some((n) => /retry of failed run/.test(n)));

  // A live child blocks a second spawn: simulate with a pid file for this very process.
  const live = fs.mkdtempSync(path.join(os.tmpdir(), 'harness-rc-live-'));
  fs.mkdirSync(path.join(live, 'run-live'));
  fs.writeFileSync(path.join(live, 'run-live/pid'), String(process.pid));
  const blocked = await review('claude', 'ok', { scratch: live, projectRoot: root });
  assert.equal(blocked.result.status, 'skipped');
  assert.match(blocked.result.error, /still alive/);
});

test('every effective reviewer setting the old config file carried is on the codex argv; the file is gone', () => {
  const spec = codexSpawn({ model: 'gpt-6-astra', effort: 'high', scratchCwd: os.tmpdir(), outFile: '/dev/null' });
  const joined = spec.args.join(' ');
  for (const setting of ['approval_policy="never"', 'web_search="disabled"']) assert.ok(joined.includes(`-c ${setting}`), setting);
  assert.match(joined, /--sandbox read-only/);
  for (const f of ['shell_tool', 'unified_exec', 'multi_agent', 'code_mode_host', 'apps', 'plugins', 'hooks', 'browser_use', 'computer_use', 'skill_search', 'tool_suggest', 'image_generation', 'view_image']) assert.ok(joined.includes(`--disable ${f}`), f);
  assert.ok(!joined.includes('--config') && !joined.includes('.toml'), 'no config file is referenced');
  assert.ok(!fs.existsSync(path.join(ADAPTERS, 'codex-cli/reviewer-config.toml')));
  const meta = JSON.parse(fs.readFileSync(path.join(ADAPTERS, 'codex-cli/adapter.json'), 'utf8'));
  assert.equal(meta.reviewer.config_file, undefined);
});
