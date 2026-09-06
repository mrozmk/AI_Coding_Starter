import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { FIXTURE_NAMES, SPEC_REL, archivePreviousEvidence, loadHookScenarios, makeFixtures, requiredLiveAssertions, runHookScenarios } from '../../scripts/lib/smoke-live.mjs';
import { verifyReleaseEvidence } from '../../scripts/smoke-harness.mjs';
import { stampApproval, verifyApproval } from '../../harness-source/scripts/approval.mjs';
import { sha256Hex } from '../../harness-source/scripts/lib/digest.mjs';
import { addAssertion, addReceipt, newEvidence } from '../../harness-source/scripts/lib/evidence.mjs';
import { readProfile } from '../../harness-source/scripts/profile.mjs';
import { resolveRulesAuthority } from '../../harness-source/scripts/rules.mjs';
import { readiness } from '../../harness-source/scripts/bootstrap.mjs';
import { CORES } from '../../harness-source/scripts/hook-runner.mjs';

const REPO = path.resolve(import.meta.dirname, '../..');

test('fixtures: a genuinely empty project, a brownfield project with authoritative CLAUDE.md, an explicit review opt-out and a review-required project', () => {
  const { projects } = makeFixtures(REPO);
  assert.deepEqual(Object.keys(projects), FIXTURE_NAMES);
  assert.ok(!fs.existsSync(path.join(projects.empty, '.agents')), 'empty means empty — nothing pre-seeded');
  assert.equal(readiness({ projectRoot: projects.empty, host: 'claude' }).ready, false);
  const brown = resolveRulesAuthority(projects.brownfield);
  assert.equal(brown.mode, 'brownfield');
  assert.equal(brown.authority, 'CLAUDE.md');
  assert.ok(!fs.existsSync(path.join(projects.brownfield, '.agents/project-rules.md')), 'no competing rules file was created');
  assert.match(fs.readFileSync(path.join(projects.brownfield, 'AGENTS.md'), 'utf8'), /Read `CLAUDE\.md` in full/);
  assert.equal(resolveRulesAuthority(projects['different-rules']).authority, '.agents/project-rules.md');
  assert.match(fs.readFileSync(path.join(projects['different-rules'], 'CLAUDE.md'), 'utf8'), /make check && make design-lint/);
  assert.equal(readProfile(projects['review-opt-out']).view.groups.review, false, 'opt-out is an explicit profile value');
  assert.equal(readProfile(projects['review-required-missing-cli']).view.groups.review, true);
  assert.equal(readProfile(projects['no-profile']).status, 'missing');
  assert.equal(readProfile(projects['legacy-profile']).kind, 'legacy');
  for (const p of Object.values(projects)) assert.match(execFileSync('git', ['-C', p, 'log', '--oneline'], { encoding: 'utf8' }), /fixture/);
});

test('approval round-trip and post-approval mutation are exercised with the real helper, never a self-hash', () => {
  const { projects } = makeFixtures(REPO);
  const project = projects['different-rules'];
  const spec = path.join(project, SPEC_REL);
  const res = stampApproval({ projectRoot: project, spec: SPEC_REL, expectedSha: sha256Hex(fs.readFileSync(spec)), decision: 'contract test', date: '2026-09-05', consent: true });
  assert.equal(res.written, true);
  assert.equal(verifyApproval({ projectRoot: project, spec: SPEC_REL }).ok, true);
  assert.ok(!fs.readFileSync(spec, 'utf8').includes(res.receipt.sha256));
  fs.appendFileSync(spec, '\nedited after approval\n');
  const after = verifyApproval({ projectRoot: project, spec: SPEC_REL });
  assert.equal(after.ok, false);
  assert.ok(after.errors.some((e) => /changed after approval/.test(e)));
  assert.ok(!fs.readFileSync(path.join(REPO, 'scripts/lib/smoke-live.mjs'), 'utf8').includes('text.replace(hash, finalHash)'), 'the broken self-hash simulation is gone');
});

test('the required live assertion contract covers both hosts, every hook scenario, opt-out, missing CLI, mutation, continuation, trust and firing', () => {
  const required = requiredLiveAssertions(REPO);
  const scenarios = loadHookScenarios(REPO);
  assert.ok(scenarios.length >= 12);
  for (const s of scenarios) {
    assert.ok(CORES[s.hook], `${s.id}: unknown hook ${s.hook}`);
    assert.ok(['deny', 'context', 'none'].includes(s.expect) || s.expect.startsWith('state:'), s.id);
    for (const host of s.hosts ?? ['claude', 'codex']) {
      assert.ok(s.payload[host] || s.hook === 'check-deps', `${s.id}: payload for ${host}`);
      assert.ok(required.includes(`${host}:hook-scenario:${s.id}`), `${host}:hook-scenario:${s.id}`);
    }
  }
  for (const host of ['claude', 'codex']) {
    for (const name of ['prime-empty-project-not-ready', 'prime-brownfield-authority', 'approval-receipt-roundtrip', 'post-approval-mutation-refused', 'continuation-gated-by-approval', 'review-opt-out-visible', 'review-required-missing-cli-blocks', 'plan-feature-writes-plan-no-execute', 'hooks-trusted', 'hooks-fired']) assert.ok(required.includes(`${host}:${name}`), `${host}:${name}`);
    assert.ok(required.includes(`denial:${host}:no-tool-execution`));
    assert.ok(required.includes(`denial:${host}:isolation-flags-declared`));
  }
  assert.ok(!required.includes('codex:hook-scenario:lsp-hint-conditional'), 'a Claude-only scenario is not demanded of Codex');
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'harness-live-contract-'));
  const receipts = path.join(dir, 'receipts');
  const ev = newEvidence({ kind: 'release-readiness', mode: 'live', cli: {}, models: {}, effort: {}, configDigest: '0'.repeat(64), inputs: {} });
  const r = addReceipt(ev, receipts, 'x.json', '{}');
  addAssertion(ev, { name: 'bundle:validates', outcome: 'pass', observation: 'x', receipt_sha256: r });
  const file = path.join(dir, 'release-readiness.json');
  fs.writeFileSync(file, JSON.stringify(ev));
  const errors = verifyReleaseEvidence(file, { repoRoot: REPO });
  assert.ok(errors.some((e) => /required assertion missing: claude:hooks-fired/.test(e)));
  assert.ok(errors.some((e) => /required assertion missing: codex:hook-scenario:commit-empty-index-denied/.test(e)));
  assert.ok(errors.some((e) => /stale input source_digest/.test(e)), 'evidence must name the current source digest');
});

test('hook scenarios run through the runner offline against a synthetic project (proving package behavior, not host invocation); previous evidence is archived byte-for-byte', async () => {
  const project = fs.realpathSync.native(fs.mkdtempSync(path.join(os.tmpdir(), 'harness scenario-')));
  execFileSync('git', ['init', '-q'], { cwd: project });
  fs.mkdirSync(path.join(project, '.claude'), { recursive: true });
  fs.mkdirSync(path.join(project, '.agents/memory'), { recursive: true });
  fs.mkdirSync(path.join(project, 'src'), { recursive: true });
  fs.writeFileSync(path.join(project, '.claude/comment-guard.json'), JSON.stringify({ src_globs: ['src/*'], min_comment_lines: 3, max_comment_percent: 15 }));
  fs.writeFileSync(path.join(project, '.claude/nudge-rules.json'), JSON.stringify({ rules: [{ glob: 'src/*/index.ts', message: 'public barrel' }] }));
  fs.writeFileSync(path.join(project, '.claude/memory-domains.json'), JSON.stringify({ rules: [{ match: '^src/lib/([^/]+)/', domain: '$1' }], fallback: 'general', size_threshold_bytes: 24000, app_source_regex: 'src/[A-Za-z0-9_./-]+' }));
  fs.writeFileSync(path.join(project, '.agents/memory/errors.md'), 'e'.repeat(30_000));
  fs.writeFileSync(path.join(project, 'CLAUDE.md'), '# Rules\n\n## Code Navigation (LSP)\n\ngopls\n');
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'harness-scenario-ev-'));
  const ev = newEvidence({ kind: 'release-readiness', mode: 'live', cli: {}, models: {}, effort: {}, configDigest: '0'.repeat(64), inputs: {} });
  for (const host of ['claude', 'codex']) {
    await runHookScenarios({ repoRoot: REPO, host, root: path.join(REPO, 'harness-source'), evidence: ev, receiptsDir: path.join(dir, 'r') });
  }
  const byName = Object.fromEntries(ev.assertions.map((a) => [a.name, a]));
  for (const host of ['claude', 'codex']) {
    for (const s of loadHookScenarios(REPO).filter((x) => !x.hosts || x.hosts.includes(host))) {
      assert.equal(byName[`${host}:hook-scenario:${s.id}`].outcome, 'pass', `${host}/${s.id}: ${byName[`${host}:hook-scenario:${s.id}`].observation}`);
    }
  }
  assert.ok(!fs.existsSync(path.join(project, '.claude/hooks')), 'the hand-made project above stays unused by the runner');
  const repoCopy = fs.mkdtempSync(path.join(os.tmpdir(), 'harness-archive-'));
  fs.mkdirSync(path.join(repoCopy, 'docs/harness'), { recursive: true });
  fs.writeFileSync(path.join(repoCopy, 'docs/harness/release-readiness.json'), '{"old":true}\n');
  fs.writeFileSync(path.join(repoCopy, 'docs/harness/release-readiness.md'), '# old\n');
  const moved = archivePreviousEvidence(repoCopy, { version: '0.1.0', today: '2026-09-05' });
  assert.deepEqual(moved, ['docs/harness/history/0.1.0-2026-09-05/release-readiness.json', 'docs/harness/history/0.1.0-2026-09-05/release-readiness.md']);
  assert.equal(fs.readFileSync(path.join(repoCopy, moved[0]), 'utf8'), '{"old":true}\n');
  assert.ok(!fs.existsSync(path.join(repoCopy, 'docs/harness/release-readiness.json')));
  fs.writeFileSync(path.join(repoCopy, 'docs/harness/release-readiness.json'), '{"new":true}\n');
  const again = archivePreviousEvidence(repoCopy, { version: '0.1.0', today: '2026-09-05' });
  assert.deepEqual(again, ['docs/harness/history/0.1.0-2026-09-05-2/release-readiness.json'], 'a taken slot yields the next numbered one, never an overwrite');
  assert.equal(fs.readFileSync(path.join(repoCopy, moved[0]), 'utf8'), '{"old":true}\n', 'the earlier archive is untouched');
});
