import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { canTechnicalRetry, executionOf, findOnPath, loginState, repeatPolicy, reviewerFor, runReview, MAX_ROUNDS } from '../../harness-source/scripts/review-orchestrator.mjs';
import { syntheticProfile } from '../../harness-source/scripts/profile.mjs';
import { blocksAdvancement, extractJson, judgeOutput, validateReviewResult } from '../../harness-source/scripts/review-result.mjs';
import { REQUIRED_CAPABILITY_ASSERTIONS, adapterConfigDigest, verifyCapabilities } from '../../harness-source/scripts/preflight.mjs';
import { addAssertion, addReceipt, newEvidence, validateEvidence } from '../../harness-source/scripts/lib/evidence.mjs';
import * as claudeAdapter from '../../harness-source/adapters/claude-code/review.mjs';
import * as codexAdapter from '../../harness-source/adapters/codex-cli/review.mjs';

const FIX = path.join(import.meta.dirname, 'fixtures');
const MOCK_BIN = path.join(FIX, 'mock-bin');
const EMPTY_BIN = path.join(FIX, 'empty-bin');
const ADAPTERS = path.resolve(import.meta.dirname, '../../harness-source/adapters');

function project() {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'harness review project-'));
  fs.cpSync(path.join(FIX, 'projects/with-private-inputs'), dir, { recursive: true });
  fs.writeFileSync(path.join(dir, '.env'), 'SECRET=canary-9f3a\n');
  return dir;
}

function plugin() {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'harness-review-plugin-'));
  fs.mkdirSync(path.join(dir, 'skills/prime'), { recursive: true });
  fs.writeFileSync(path.join(dir, 'skills/prime/SKILL.md'), '---\nname: prime\ndescription: p\n---\nprime\n');
  return dir;
}

function env(mode, extra = {}) {
  return { PATH: `${MOCK_BIN}${path.delimiter}${path.dirname(process.execPath)}`, HOME: os.homedir(), MOCK_MODE: mode, ...extra };
}

async function review(authorHost, mode, extra = {}, opts = {}) {
  const scratch = fs.mkdtempSync(path.join(os.tmpdir(), 'harness-review-scratch-'));
  const root = opts.projectRoot ?? project();
  const result = await runReview({ projectRoot: root, pluginRoot: plugin(), authorHost, artifacts: ['.agents/specs/2026-01-01-fixture.md'], deps: ['dep.mjs'], scratchDir: scratch, kind: 'spec', adaptersRoot: ADAPTERS, env: env(mode, extra), timeoutMs: opts.timeoutMs ?? 30_000, signal: opts.signal, profile: opts.profile ?? syntheticProfile({ author_host: authorHost }) });
  return { result, scratch, root };
}

test('author host picks the other host as reviewer; unknown author refused', () => {
  assert.equal(reviewerFor('claude'), 'codex');
  assert.equal(reviewerFor('codex'), 'claude');
  assert.throws(() => reviewerFor('gpt'), /author host/);
});

test('argv boundaries: prompt and pack go over stdin as data, argv is a fixed array, EOF is sent', async () => {
  const record = path.join(os.tmpdir(), `mock-record-${Date.now()}.json`);
  const root = project();
  fs.appendFileSync(path.join(root, '.agents/specs/2026-01-01-fixture.md'), '\n`$(rm -rf /)` ; && echo "injected" \'quote\'\n');
  const { result } = await review('codex', 'ok', { MOCK_RECORD: record }, { projectRoot: root });
  assert.equal(result.status, 'completed');
  const rec = JSON.parse(fs.readFileSync(record, 'utf8'));
  assert.ok(rec.args.includes('--restricted') && rec.args.includes('--safe-mode') && rec.args.includes('--tools'));
  assert.ok(!rec.args.some((a) => a.includes('rm -rf')), 'artifact bytes never reach argv');
  assert.ok(rec.stdinBytes > 500, 'pack arrived on stdin');
  assert.ok(rec.stdinHead.startsWith('You are an independent'), 'prompt precedes the pack on stdin');
  assert.equal(rec.depth, '1', 'child runs at review depth 1');
  assert.ok(fs.readdirSync(rec.cwd).length === 0, 'reviewer cwd is an empty scratch dir');
  assert.ok(!result.process.argv.join(' ').includes('canary-9f3a'));
});

test('codex reviewer argv carries the read-only sandbox, feature denials and stdin mode; claude carries restricted isolation', async () => {
  const record = path.join(os.tmpdir(), `mock-record-c-${Date.now()}.json`);
  const { result } = await review('claude', 'ok', { MOCK_RECORD: record });
  assert.equal(result.reviewer_host, 'codex');
  const rec = JSON.parse(fs.readFileSync(record, 'utf8'));
  const joined = rec.args.join(' ');
  assert.match(joined, /--sandbox read-only/);
  assert.match(joined, /--ephemeral/);
  assert.match(joined, /--ignore-user-config/);
  assert.ok(!joined.includes('--output-schema'), 'no native output schema (contract 7)');
  for (const f of ['shell_tool', 'unified_exec', 'multi_agent', 'apps', 'plugins', 'code_mode_host']) assert.match(joined, new RegExp(`--disable ${f}`));
  assert.equal(rec.args.at(-1), '-', 'prompt read from stdin');
  assert.match(joined, /-m gpt-6-astra/);
  assert.match(joined, /model_reasoning_effort="high"/);
  assert.equal(result.status, 'completed');
  assert.equal(result.verdict, 'revise');
  assert.equal(result.findings.length, 1);
  assert.deepEqual(result.model, { requested: 'gpt-6-astra', confirmed: 'gpt-6-astra' });
  assert.deepEqual(validateReviewResult(result), []);
});

test('missing CLI, auth failure, nonzero exit: no opinion, never ship', async () => {
  const scratch = fs.mkdtempSync(path.join(os.tmpdir(), 'harness-review-nocli-'));
  const none = await runReview({ projectRoot: project(), pluginRoot: plugin(), authorHost: 'claude', artifacts: ['.agents/specs/2026-01-01-fixture.md'], scratchDir: scratch, adaptersRoot: ADAPTERS, env: { PATH: EMPTY_BIN }, profile: syntheticProfile() });
  assert.equal(none.status, 'failed');
  assert.match(none.error, /not on PATH/);
  assert.equal(blocksAdvancement(none), true);
  const auth = await review('codex', 'auth');
  assert.equal(auth.result.status, 'failed');
  assert.match(auth.result.error, /exited 1/);
  const nz = await review('codex', 'nonzero');
  assert.equal(nz.result.status, 'failed');
  assert.equal(nz.result.verdict, null);
});

test('execution status is derived from facts: a launched process is not an executed review', async () => {
  const noCli = await runReview({ projectRoot: project(), pluginRoot: plugin(), authorHost: 'claude', artifacts: ['.agents/specs/2026-01-01-fixture.md'], scratchDir: fs.mkdtempSync(path.join(os.tmpdir(), 'harness-exec-')), adaptersRoot: ADAPTERS, env: { PATH: EMPTY_BIN }, profile: syntheticProfile() });
  assert.equal(noCli.execution, 'not-executed');
  assert.match(noCli.summary_line, /^Review: NOT EXECUTED — .*not on PATH/);

  for (const author of ['claude', 'codex']) {
    const pre = await review(author, 'auth-preflight');
    assert.equal(pre.result.status, 'failed', `${author}: login probe fails closed`);
    assert.equal(pre.result.execution, 'not-executed');
    assert.match(pre.result.error, /not logged in in this execution context/);
    assert.equal(pre.result.process.exit_code, null, `${author}: nothing was spawned`);
    assert.match(pre.result.summary_line, /^Review: NOT EXECUTED — /);
  }
  assert.equal(loginState('claude', env('auth-preflight').PATH, env('auth-preflight')).loggedIn, false);
  assert.equal(loginState('codex', env('ok').PATH, env('ok')).loggedIn, true);
  assert.equal(loginState('claude', EMPTY_BIN).loggedIn, null);

  const authLate = await review('codex', 'auth');
  assert.equal(authLate.result.execution, 'not-executed', 'exit 1 before a confirmed model is not an execution');

  const packGap = await runReview({ projectRoot: project(), pluginRoot: plugin(), authorHost: 'claude', artifacts: ['.agents/specs/does-not-exist.md'], scratchDir: fs.mkdtempSync(path.join(os.tmpdir(), 'harness-exec-')), adaptersRoot: ADAPTERS, env: env('ok'), profile: syntheticProfile() });
  assert.equal(packGap.status, 'needs-context');
  assert.equal(packGap.execution, 'not-executed', 'needs-context raised while packing never counts as an executed review');
  assert.match(packGap.summary_line, /^Review: NOT EXECUTED — /);

  const gap = await review('codex', 'gap');
  assert.equal(gap.result.execution, 'executed-incomplete');
  assert.match(gap.result.summary_line, /^Review: EXECUTED, OPINION INCOMPLETE — 1 missing context item\(s\) \(claude-fable-5-1/);

  const rejected = await review('codex', 'contradictory');
  assert.equal(rejected.result.status, 'failed');
  assert.equal(rejected.result.execution, 'executed-rejected');
  assert.match(rejected.result.summary_line, /^Review: EXECUTED, OPINION REJECTED — /);

  const ok = await review('codex', 'ok');
  assert.equal(ok.result.execution, 'executed-complete');
  assert.match(ok.result.summary_line, /^Review: EXECUTED, COMPLETED — ship \(claude-fable-5-1/);
  assert.deepEqual(validateReviewResult(ok.result), []);
  assert.equal(executionOf({ ...ok.result, model: { requested: 'fable', confirmed: null } }), 'not-executed');
});

test('empty, malformed, stale and unanchored outputs fail; a reported gap is needs-context, not ship', async () => {
  for (const [author, mode] of [['codex', 'empty'], ['claude', 'empty'], ['codex', 'malformed'], ['claude', 'malformed']]) {
    const { result } = await review(author, mode);
    assert.equal(result.status, 'failed', `${author}/${mode}`);
    assert.equal(result.verdict, null);
  }
  const stale = await review('claude', 'stale');
  assert.equal(stale.result.status, 'failed', 'a pre-existing final file is never read as this run\'s result');
  const gap = await review('codex', 'gap');
  assert.equal(gap.result.status, 'needs-context');
  assert.equal(gap.result.verdict, null);
  assert.deepEqual(gap.result.missing_context, [{ kind: 'unspecified', detail: '.agents/memory/architecture.md' }], 'schema-1 strings are typed as unspecified');
  assert.equal(blocksAdvancement(gap.result), true);
  const un = await review('codex', 'unanchored');
  assert.equal(un.result.status, 'failed');
  assert.match(un.result.error, /without evidence/);
});

test('model and effort identity are verified against what the CLI reports', async () => {
  const wrongClaude = await review('codex', 'wrong-model');
  assert.equal(wrongClaude.result.status, 'failed');
  assert.match(wrongClaude.result.error, /model mismatch/);
  assert.equal(wrongClaude.result.model.confirmed, 'claude-sonnet-5');
  const wrongCodex = await review('claude', 'wrong-model');
  assert.equal(wrongCodex.result.status, 'failed');
  assert.match(wrongCodex.result.error, /model mismatch/);
  const wrongEffort = await review('claude', 'ok', { MOCK_EFFORT: 'low' });
  assert.equal(wrongEffort.result.status, 'failed');
  assert.match(wrongEffort.result.error, /effort mismatch/);
  assert.ok(claudeAdapter.modelMatches('fable', 'claude-fable-5-1'));
  assert.ok(!claudeAdapter.modelMatches('fable', 'claude-opus-5'));
  assert.ok(!codexAdapter.modelMatches('gpt-6-astra', null));
});

test('artifact changed mid-review invalidates the opinion', async () => {
  const root = project();
  const { result } = await review('codex', 'ok', { MOCK_TOUCH: path.join(root, '.agents/specs/2026-01-01-fixture.md') }, { projectRoot: root });
  assert.equal(result.status, 'failed');
  assert.match(result.error, /changed while the review was running/);
});

test('timeout terminates the child and cancellation is honoured; both fail closed', async () => {
  const t = await review('codex', 'hang', {}, { timeoutMs: 1500 });
  assert.equal(t.result.status, 'failed');
  assert.equal(t.result.process.timed_out, true);
  assert.match(t.result.error, /terminated/);
  const ac = new AbortController();
  setTimeout(() => ac.abort(), 500);
  const c = await review('claude', 'hang', {}, { timeoutMs: 30_000, signal: ac.signal });
  assert.equal(c.result.status, 'failed');
  assert.equal(c.result.process.cancelled, true);
  assert.ok(c.result.process.duration_ms < 10_000, 'cancellation did not wait for the timeout');
});

test('nested review is refused at depth 1 and a disabled review group skips', async () => {
  const nested = await review('codex', 'ok', { HARNESS_REVIEW_DEPTH: '1' });
  assert.equal(nested.result.status, 'skipped');
  assert.match(nested.result.error, /nested review refused/);
  const disabled = await review('codex', 'ok', {}, { profile: syntheticProfile({ author_host: 'codex', groups: { planning: true, review: false } }) });
  assert.equal(disabled.result.status, 'skipped');
  assert.match(disabled.result.error, /disabled/);
  const scratchMissing = fs.mkdtempSync(path.join(os.tmpdir(), 'harness-review-noprofile-'));
  const noProfile = await runReview({ projectRoot: project(), pluginRoot: plugin(), authorHost: 'codex', artifacts: ['.agents/specs/2026-01-01-fixture.md'], scratchDir: scratchMissing, adaptersRoot: ADAPTERS, env: env('ok') });
  assert.equal(noProfile.result?.status ?? noProfile.status, 'failed', 'a missing profile is a blocking state, never an implicit review opt-in');
  assert.match(noProfile.error, /profile/);
});

test('repeat policy: first opinion stays; editorial edits use local checks; material changes repeat up to 3 rounds', () => {
  const prev = { review_id: 'x', status: 'completed', verdict: 'revise' };
  assert.equal(repeatPolicy({ previous: null }).repeat, true);
  assert.equal(repeatPolicy({ previous: prev, changes: ['typo', 'formatting'], roundsDone: 1 }).repeat, false);
  assert.equal(repeatPolicy({ previous: prev, changes: ['scope'], roundsDone: 1 }).repeat, true);
  const capped = repeatPolicy({ previous: prev, changes: ['api'], roundsDone: MAX_ROUNDS });
  assert.equal(capped.repeat, false);
  assert.equal(capped.requiresUserDecision, true);
  assert.equal(canTechnicalRetry({ previous: { status: 'failed', review_id: 'a' }, alive: true }).allowed, false);
  assert.equal(canTechnicalRetry({ previous: { status: 'failed', review_id: 'a' }, alive: false }).allowed, true);
  assert.equal(canTechnicalRetry({ previous: { status: 'needs-context', review_id: 'a' }, alive: false }).allowed, false);
});

test('result parsing helpers: fenced JSON, prose, empty', () => {
  assert.equal(extractJson('```json\n{"a":1}\n```').value.a, 1);
  assert.equal(extractJson('Here you go: {"verdict":"ship","findings":[],"evidence_read":[],"missing_context":[]} thanks').value.verdict, 'ship');
  assert.equal(extractJson('').ok, false);
  assert.equal(judgeOutput({ verdict: 'ship', findings: [], evidence_read: [], missing_context: ['x'] }).status, 'needs-context');
  assert.equal(judgeOutput({ verdict: 'ship' }).status, 'failed');
  assert.equal(findOnPath('claude', MOCK_BIN), path.join(MOCK_BIN, 'claude'));
  assert.equal(findOnPath('claude', EMPTY_BIN), null);
});

test('capability evidence: config digest binds the adapter bytes; missing required assertions or stale digest fail', () => {
  const { digest } = adapterConfigDigest(ADAPTERS);
  assert.match(digest, /^[0-9a-f]{64}$/);
  const receipts = fs.mkdtempSync(path.join(os.tmpdir(), 'harness-receipts-'));
  const ev = newEvidence({ kind: 'reviewer-capabilities', mode: 'live', cli: { claude: { version: 'x' }, codex: { version: 'y' } }, models: { claude: { requested: 'fable', confirmed: 'claude-fable-5-1' }, codex: { requested: 'gpt-6-astra', confirmed: 'gpt-6-astra' } }, effort: { claude: { requested: 'high', confirmed: null }, codex: { requested: 'high', confirmed: 'high' } }, configDigest: digest, inputs: { config_digest: digest } });
  const r = addReceipt(ev, receipts, 'r.json', '{}');
  for (const name of REQUIRED_CAPABILITY_ASSERTIONS('claude')) {
    addAssertion(ev, { name, outcome: 'pass', observation: 'ok', receipt_sha256: r });
  }
  const file = path.join(receipts, 'evidence.json');
  fs.writeFileSync(file, JSON.stringify(ev));
  assert.deepEqual(verifyCapabilities(file, { adaptersRootDir: ADAPTERS, receiptsDir: receipts, hosts: ['claude'] }), []);
  assert.ok(verifyCapabilities(file, { adaptersRootDir: ADAPTERS, hosts: ['claude', 'codex'] }).some((e) => /codex:reviewer-completed/.test(e)));
  const stale = { ...ev, inputs: { config_digest: '0'.repeat(64) }, config_digest: '0'.repeat(64) };
  assert.ok(validateEvidence(stale, { expectedInputs: { config_digest: digest } }).some((e) => /stale input/.test(e)));
  const zero = { ...ev, assertions: [], case_count: 0 };
  assert.ok(validateEvidence(zero).length > 0, 'zero cases fail');
  const failed = structuredClone(ev);
  failed.assertions[2].outcome = 'fail';
  assert.ok(validateEvidence(failed).some((e) => /not passed/.test(e)));
  const noReceipt = structuredClone(ev);
  noReceipt.assertions[0].receipt_sha256 = null;
  assert.ok(validateEvidence(noReceipt).some((e) => /without receipt/.test(e)));
  const demoted = structuredClone(ev);
  demoted.assertions[2].required = false;
  demoted.assertions[2].outcome = 'fail';
  assert.deepEqual(validateEvidence(demoted), [], 'the file alone cannot tell which gates matter…');
  assert.ok(validateEvidence(demoted, { requiredAssertions: [demoted.assertions[2].name] }).some((e) => /not passed.*marked optional in the file/.test(e)), '…the verifier\'s list does');
});

test('codex stderr scan skips the echoed stdin only when the echo is complete and contiguous', () => {
  const stdin = 'Implement the plan.\ntools: Read, Write\nexec something\nEnd of prompt.';
  const head = 'OpenAI Codex v0.0.0-mock\n--------\nmodel: gpt-6-astra\nreasoning effort: high\n--------\nuser\n';
  const activity = 'exec\nbash -lc ls\n';

  const echoed = codexAdapter.parseOutput({ stderr: `${head}${stdin}\n`, stdinText: stdin });
  assert.equal(echoed.toolUses.count, 0, 'the caller\'s own prompt is not the reviewer\'s tool activity');

  const after = codexAdapter.parseOutput({ stderr: `${head}${stdin}\n${activity}`, stdinText: stdin });
  assert.ok(after.toolUses.count > 0, 'activity outside the echo is still counted');

  const altered = `${stdin.split('\n')[0]}\nsomething else entirely\nexec injected\n${stdin.split('\n').at(-1)}`;
  const partial = codexAdapter.parseOutput({ stderr: `${head}${altered}\n`, stdinText: stdin });
  assert.ok(partial.toolUses.count > 0, 'an altered echo hides nothing — the whole stream is scanned');

  const legacy = codexAdapter.parseOutput({ stderr: `${head}${stdin}\n` });
  assert.ok(legacy.toolUses.count > 0, 'without stdinText the scan behaves exactly as before');
});
