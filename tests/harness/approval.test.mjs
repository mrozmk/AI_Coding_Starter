import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { applyTransition, receiptPathFor, stampApproval, verifyApproval } from '../../harness-source/scripts/approval.mjs';
import { sha256Hex } from '../../harness-source/scripts/lib/digest.mjs';

const CLI = path.resolve(import.meta.dirname, '../../harness-source/scripts/approval.mjs');
const SPEC = '.agents/specs/2026-09-05-feature.md';
const DRAFT = '# Design: Feature\n\n**Date:** 2026-09-05\n**Status:** Draft\n**External docs required:** no\n**Approval:** none — written by approval.mjs\n\n## Summary\n\nsynthetic\n\n## Independent Review\n\nreviewer codex · verdict ship\n';

function project() {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'harness approval-'));
  fs.mkdirSync(path.join(dir, '.agents/specs'), { recursive: true });
  fs.writeFileSync(path.join(dir, SPEC), DRAFT);
  return dir;
}

test('draft is rejected; stamped final bytes verify; a one-byte edit fails; receipt lives outside the spec', () => {
  const root = project();
  assert.equal(verifyApproval({ projectRoot: root, spec: SPEC }).ok, false, 'Draft never verifies');
  const expected = sha256Hex(fs.readFileSync(path.join(root, SPEC)));
  const preview = stampApproval({ projectRoot: root, spec: SPEC, expectedSha: expected, decision: 'user said approve (msg 12)', date: '2026-09-05' });
  assert.equal(preview.written, false);
  assert.ok(!fs.existsSync(path.join(root, receiptPathFor(SPEC))), 'no consent → nothing written');
  assert.equal(fs.readFileSync(path.join(root, SPEC), 'utf8'), DRAFT);

  const res = stampApproval({ projectRoot: root, spec: SPEC, expectedSha: expected, decision: 'user said approve (msg 12)', date: '2026-09-05', consent: true });
  assert.equal(res.written, true);
  const text = fs.readFileSync(path.join(root, SPEC), 'utf8');
  assert.match(text, /^\*\*Status:\*\* Approved$/m);
  assert.match(text, /^\*\*Approval:\*\* receipt `\.agents\/approvals\/2026-09-05-feature\.approval\.json` — approved by the user on 2026-09-05$/m);
  assert.ok(!text.includes(res.receipt.sha256), 'the spec never contains its own hash');
  assert.equal(res.receipt.sha256, sha256Hex(fs.readFileSync(path.join(root, SPEC))), 'receipt hashes the exact final bytes');
  const v = verifyApproval({ projectRoot: root, spec: SPEC });
  assert.equal(v.ok, true, v.errors.join('; '));
  assert.equal(v.decision, 'user said approve (msg 12)');

  fs.appendFileSync(path.join(root, SPEC), ' ');
  const bad = verifyApproval({ projectRoot: root, spec: SPEC });
  assert.equal(bad.ok, false);
  assert.ok(bad.errors.some((e) => /changed after approval/.test(e)));
});

test('a changed draft, a missing decision and an interrupted stamp all fail', () => {
  const root = project();
  const stale = sha256Hex(Buffer.from('other bytes'));
  assert.throws(() => stampApproval({ projectRoot: root, spec: SPEC, expectedSha: stale, decision: 'x', consent: true }), /changed since the approved draft/);
  const expected = sha256Hex(fs.readFileSync(path.join(root, SPEC)));
  assert.throws(() => stampApproval({ projectRoot: root, spec: SPEC, expectedSha: expected, decision: '', consent: true }), /decision is required/);
  assert.equal(fs.readFileSync(path.join(root, SPEC), 'utf8'), DRAFT, 'failed stamp leaves the draft untouched');

  // Interrupted stamp: the spec transitioned but no receipt was written.
  fs.writeFileSync(path.join(root, SPEC), applyTransition(DRAFT, { receiptRel: receiptPathFor(SPEC), date: '2026-09-05' }));
  const v = verifyApproval({ projectRoot: root, spec: SPEC });
  assert.equal(v.ok, false);
  assert.ok(v.errors.some((e) => /never stamped, or the stamp was interrupted/.test(e)));
});

test('re-approval after an editorial edit replaces the receipt; a receipt for another spec is refused', () => {
  const root = project();
  const first = stampApproval({ projectRoot: root, spec: SPEC, expectedSha: sha256Hex(fs.readFileSync(path.join(root, SPEC))), decision: 'round 1', date: '2026-09-05', consent: true });
  fs.appendFileSync(path.join(root, SPEC), '\nTypo fixed.\n');
  assert.equal(verifyApproval({ projectRoot: root, spec: SPEC }).ok, false, 'editorial edit invalidates the approval');
  const second = stampApproval({ projectRoot: root, spec: SPEC, expectedSha: sha256Hex(fs.readFileSync(path.join(root, SPEC))), decision: 'round 1 re-approved after typo', date: '2026-09-06', consent: true });
  assert.notEqual(first.receipt.sha256, second.receipt.sha256);
  assert.equal(verifyApproval({ projectRoot: root, spec: SPEC }).ok, true);
  const receipt = JSON.parse(fs.readFileSync(path.join(root, receiptPathFor(SPEC)), 'utf8'));
  receipt.spec = '.agents/specs/other.md';
  fs.writeFileSync(path.join(root, receiptPathFor(SPEC)), JSON.stringify(receipt));
  assert.ok(verifyApproval({ projectRoot: root, spec: SPEC }).errors.some((e) => /receipt names/.test(e)));
  assert.throws(() => stampApproval({ projectRoot: root, spec: '../outside.md', expectedSha: 'x', decision: 'x' }), /escapes/);
});

test('CLI: stamp needs consent and expected hash; verify exits 3 on a draft and 0 after stamping', () => {
  const root = project();
  const run = (args) => spawnSync(process.execPath, [CLI, ...args, '--project-root', root, '--spec', SPEC], { encoding: 'utf8' });
  assert.equal(run(['verify']).status, 3);
  const expected = sha256Hex(fs.readFileSync(path.join(root, SPEC)));
  const preview = run(['stamp', '--expected', expected, '--decision', 'cli test']);
  assert.equal(preview.status, 0);
  assert.match(preview.stderr, /preview only/);
  assert.equal(run(['stamp', '--expected', '0'.repeat(64), '--decision', 'cli test', '--consent', 'yes']).status, 1);
  assert.equal(run(['stamp', '--expected', expected, '--decision', 'cli test', '--consent', 'yes']).status, 0);
  const v = run(['verify']);
  assert.equal(v.status, 0, v.stderr);
  assert.match(v.stdout, /"ok": true/);
});

test('a spec without a usable External docs required line never verifies', () => {
  for (const [variant, replace] of [['missing', ''], ['unusable', '**External docs required:** maybe\n']]) {
    const root = project();
    fs.writeFileSync(path.join(root, SPEC), DRAFT.replace('**External docs required:** no\n', replace));
    const expected = sha256Hex(fs.readFileSync(path.join(root, SPEC)));
    stampApproval({ projectRoot: root, spec: SPEC, expectedSha: expected, decision: 'user said approve', date: '2026-09-05', consent: true });
    const v = verifyApproval({ projectRoot: root, spec: SPEC });
    assert.equal(v.ok, false, variant);
    assert.ok(v.errors.some((e) => /External docs required/.test(e)), `${variant}: ${v.errors}`);
  }
});
