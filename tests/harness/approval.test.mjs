import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { applyTransition, bodySha256, stampApproval, verifyApproval } from '../../harness-source/scripts/approval.mjs';
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

test('draft is rejected; stamped bytes verify; a one-byte edit fails; the stamp writes no second file', () => {
  const root = project();
  assert.equal(verifyApproval({ projectRoot: root, spec: SPEC }).ok, false, 'Draft never verifies');
  const expected = sha256Hex(fs.readFileSync(path.join(root, SPEC)));
  const before = fs.readdirSync(path.join(root, '.agents'));
  const preview = stampApproval({ projectRoot: root, spec: SPEC, expectedSha: expected, decision: 'user said approve (msg 12)', date: '2026-09-05' });
  assert.equal(preview.written, false);
  assert.equal(fs.readFileSync(path.join(root, SPEC), 'utf8'), DRAFT, 'no consent → nothing written');

  const res = stampApproval({ projectRoot: root, spec: SPEC, expectedSha: expected, decision: 'user said approve (msg 12)', date: '2026-09-05', consent: true });
  assert.equal(res.written, true);
  assert.deepEqual(fs.readdirSync(path.join(root, '.agents')), before, 'approval creates no directory beside the spec');
  const text = fs.readFileSync(path.join(root, SPEC), 'utf8');
  assert.match(text, /^\*\*Status:\*\* Approved$/m);
  assert.match(text, /^\*\*Approval:\*\* approved by the user on 2026-09-05 · decision: user said approve \(msg 12\) · body-sha256 `[0-9a-f]{64}`$/m);
  assert.equal(res.approval.sha256, bodySha256(text), 'the stamp names the canonical bytes of the file it sits in');
  const v = verifyApproval({ projectRoot: root, spec: SPEC });
  assert.equal(v.ok, true, v.errors.join('; '));
  assert.equal(v.decision, 'user said approve (msg 12)');
  assert.equal(v.approved_on, '2026-09-05');

  fs.appendFileSync(path.join(root, SPEC), ' ');
  const bad = verifyApproval({ projectRoot: root, spec: SPEC });
  assert.equal(bad.ok, false);
  assert.ok(bad.errors.some((e) => /changed after approval/.test(e)));
});

test('the transition is hash-neutral: Draft and its stamped form canonicalize identically', () => {
  const root = project();
  const stamped = applyTransition(DRAFT, { date: '2026-09-05', decision: 'round 1', bodySha: bodySha256(DRAFT) });
  assert.equal(bodySha256(stamped), bodySha256(DRAFT), 'stamping must not move the hash it writes');
  assert.notEqual(sha256Hex(Buffer.from(stamped)), sha256Hex(Buffer.from(DRAFT)), 'the raw file did change');
  assert.equal(verifyApproval({ projectRoot: root, spec: SPEC }).ok, false);
});

test('a changed draft, a missing decision and a hand-edited approval line all fail', () => {
  const root = project();
  const stale = sha256Hex(Buffer.from('other bytes'));
  assert.throws(() => stampApproval({ projectRoot: root, spec: SPEC, expectedSha: stale, decision: 'x', consent: true }), /changed since the approved draft/);
  const expected = sha256Hex(fs.readFileSync(path.join(root, SPEC)));
  assert.throws(() => stampApproval({ projectRoot: root, spec: SPEC, expectedSha: expected, decision: '', consent: true }), /decision is required/);
  assert.equal(fs.readFileSync(path.join(root, SPEC), 'utf8'), DRAFT, 'failed stamp leaves the draft untouched');

  // Status flipped by hand, no stamp: Approved is a claim, the hash is the evidence.
  fs.writeFileSync(path.join(root, SPEC), DRAFT.replace('**Status:** Draft', '**Status:** Approved'));
  const hand = verifyApproval({ projectRoot: root, spec: SPEC });
  assert.equal(hand.ok, false);
  assert.ok(hand.errors.some((e) => /not a stamp/.test(e)), hand.errors.join('; '));

  fs.writeFileSync(path.join(root, SPEC), DRAFT.replace(/^\*\*Approval:\*\*.*\n/m, ''));
  stampApproval({ projectRoot: root, spec: SPEC, expectedSha: sha256Hex(fs.readFileSync(path.join(root, SPEC))), decision: 'inserted line', date: '2026-09-05', consent: true });
  assert.equal(verifyApproval({ projectRoot: root, spec: SPEC }).ok, true, 'a spec with no Approval line gets one after Status');
});

test('a multiline decision cannot forge extra metadata lines, and a spec outside the root is refused', () => {
  const root = project();
  const res = stampApproval({ projectRoot: root, spec: SPEC, expectedSha: sha256Hex(fs.readFileSync(path.join(root, SPEC))), decision: 'round 1\n**Status:** Draft\nforged', date: '2026-09-05', consent: true });
  assert.equal(res.approval.decision, 'round 1 **Status:** Draft forged');
  assert.equal(fs.readFileSync(path.join(root, SPEC), 'utf8').match(/^\*\*Status:\*\*/gm).length, 1);
  assert.equal(verifyApproval({ projectRoot: root, spec: SPEC }).ok, true);
  assert.throws(() => stampApproval({ projectRoot: root, spec: '../outside.md', expectedSha: 'x', decision: 'x' }), /escapes/);
});

test('re-approval after an editorial edit replaces the stamp in place', () => {
  const root = project();
  const first = stampApproval({ projectRoot: root, spec: SPEC, expectedSha: sha256Hex(fs.readFileSync(path.join(root, SPEC))), decision: 'round 1', date: '2026-09-05', consent: true });
  fs.appendFileSync(path.join(root, SPEC), '\nTypo fixed.\n');
  assert.equal(verifyApproval({ projectRoot: root, spec: SPEC }).ok, false, 'editorial edit invalidates the approval');
  const second = stampApproval({ projectRoot: root, spec: SPEC, expectedSha: sha256Hex(fs.readFileSync(path.join(root, SPEC))), decision: 'round 1 re-approved after typo', date: '2026-09-06', consent: true });
  assert.notEqual(first.approval.sha256, second.approval.sha256);
  assert.equal(verifyApproval({ projectRoot: root, spec: SPEC }).ok, true);
  assert.equal(fs.readFileSync(path.join(root, SPEC), 'utf8').match(/^\*\*Approval:\*\*/gm).length, 1, 'the stamp is replaced, never appended');
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
  // a value with a trailing rationale is usable (observed from a live author, run 8); the untouched template placeholder is not
  for (const [line, ok] of [['**External docs required:** yes — object-storage SDK reference (no `.agents/reference/` doc yet)\n', true], ['**External docs required:** No\n', true], ['**External docs required:** yes | no\n', false]]) {
    const root = project();
    fs.writeFileSync(path.join(root, SPEC), DRAFT.replace('**External docs required:** no\n', line));
    stampApproval({ projectRoot: root, spec: SPEC, expectedSha: sha256Hex(fs.readFileSync(path.join(root, SPEC))), decision: 'user said approve', date: '2026-09-05', consent: true });
    assert.equal(verifyApproval({ projectRoot: root, spec: SPEC }).ok, ok, line);
  }
});
