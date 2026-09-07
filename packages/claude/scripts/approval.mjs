#!/usr/bin/env node
// Spec approval identity (T02). The approval lives in the spec's own `**Approval:**` line and names
// the bytes it approves. A file can name its own hash because the hash is taken over the CANONICAL
// form: that line removed and `**Status:**` normalized to Approved. A Draft and its stamped form
// canonicalize identically, so stamping is hash-neutral and no external receipt is needed.
// `stamp` applies the declared metadata transition; `verify` recanonicalizes and compares.
// Any edit to any other byte fails.
//
//   node scripts/approval.mjs stamp  --project-root <dir> --spec <rel> --expected <sha256 of the draft you approved> \
//        --decision "<who/where the decision was made>" [--date YYYY-MM-DD] --consent yes
//   node scripts/approval.mjs verify --project-root <dir> --spec <rel>
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { parseArgv, requireOpt } from './lib/argv.mjs';
import { sha256Hex } from './lib/digest.mjs';
import { isInside, realpathOrSelf, toPosix } from './lib/fsx.mjs';

const STATUS_RE = /^\*\*Status:\*\*[ \t]*(.*)$/m;
const APPROVAL_RE = /^\*\*Approval:\*\*.*$/m;
const APPROVAL_LINE_RE = /^\*\*Approval:\*\*.*(?:\r?\n)?/m;
const STAMP_RE = /^\*\*Approval:\*\* approved by the user on (\d{4}-\d{2}-\d{2}) · decision: (.+) · body-sha256 `([0-9a-f]{64})`[ \t]*$/m;

export function approvalLine({ date, decision, bodySha }) {
  return `**Approval:** approved by the user on ${date} · decision: ${decision} · body-sha256 \`${bodySha}\``;
}

// The bytes an approval binds to: everything except the approval line itself, with the status word
// pinned. This is what makes the hash quotable inside the file it measures.
export function canonicalBytes(text) {
  const stripped = text.replace(APPROVAL_LINE_RE, '');
  return Buffer.from(stripped.replace(STATUS_RE, () => '**Status:** Approved'), 'utf8');
}

export function bodySha256(text) {
  return sha256Hex(canonicalBytes(text));
}

function resolveSpec(projectRoot, spec) {
  const root = realpathOrSelf(projectRoot);
  const abs = path.resolve(root, spec);
  if (!isInside(root, abs)) throw new Error(`spec escapes the project root: ${spec}`);
  return { root, abs, rel: toPosix(path.relative(root, abs)) };
}

function atomicWrite(file, bytes) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  const tmp = `${file}.tmp-${process.pid}`;
  fs.writeFileSync(tmp, bytes);
  fs.renameSync(tmp, file);
}

// The only edit approval is allowed to make: two metadata lines. Anything else is the user's.
export function applyTransition(text, { date, decision, bodySha }) {
  const status = text.match(STATUS_RE);
  if (!status) throw new Error('spec has no **Status:** line');
  if (!/^(Draft|Approved)\b/.test(status[1].trim())) throw new Error(`spec status is "${status[1].trim()}" — only Draft (or a stale Approved) can be stamped`);
  const line = approvalLine({ date, decision, bodySha });
  let out = text.replace(STATUS_RE, () => '**Status:** Approved');
  out = APPROVAL_RE.test(out) ? out.replace(APPROVAL_RE, () => line) : out.replace(/^\*\*Status:\*\* Approved$/m, () => `**Status:** Approved\n${line}`);
  return out;
}

export function stampApproval({ projectRoot, spec, expectedSha, decision, date = new Date().toISOString().slice(0, 10), consent = false }) {
  const { abs, rel } = resolveSpec(projectRoot, spec);
  if (!fs.existsSync(abs)) throw new Error(`spec not found: ${rel}`);
  // Collapsed to one line: the approval is a single metadata line, and a newline would forge others.
  const ref = (decision ?? '').replace(/\s+/g, ' ').trim();
  if (!ref) throw new Error('--decision is required: record where the user approved (message, ticket, review round)');
  const draft = fs.readFileSync(abs);
  const draftSha = sha256Hex(draft);
  if (!expectedSha) throw new Error('--expected is required: the SHA-256 of the draft bytes the user approved');
  if (expectedSha !== draftSha) throw new Error(`spec changed since the approved draft (expected ${expectedSha.slice(0, 12)}…, found ${draftSha.slice(0, 12)}…) — re-present it for approval`);
  const draftText = draft.toString('utf8');
  const bodySha = bodySha256(draftText);
  const finalText = applyTransition(draftText, { date, decision: ref, bodySha });
  if (bodySha256(finalText) !== bodySha) throw new Error('the approval transition would change the canonical body — refusing to stamp');
  const finalBytes = Buffer.from(finalText, 'utf8');
  const approval = { schema_version: 2, spec: rel, sha256: bodySha, bytes: finalBytes.length, draft_sha256: draftSha, approved_on: date, decision: ref };
  const preview = { spec: rel, draft_sha256: draftSha, body_sha256: bodySha, transition: ['**Status:** Approved', approvalLine({ date, decision: ref, bodySha })] };
  if (!consent) return { written: false, preview };
  atomicWrite(abs, finalBytes);
  return { written: true, preview, approval };
}

export function verifyApproval({ projectRoot, spec }) {
  const errors = [];
  let abs; let rel;
  try { ({ abs, rel } = resolveSpec(projectRoot, spec)); } catch (e) { return { ok: false, errors: [e.message] }; }
  if (!fs.existsSync(abs)) return { ok: false, errors: [`spec not found: ${rel}`] };
  const text = fs.readFileSync(abs, 'utf8');
  const sha256 = bodySha256(text);
  const status = text.match(STATUS_RE)?.[1]?.trim() ?? null;
  if (status !== 'Approved') errors.push(`spec status is ${status ?? 'missing'}, not Approved`);
  // plan-feature's research step keys off this field; a spec without it cannot say whether docs were needed.
  // Authors append a rationale after the value ("yes — SDK reference for …"); only the leading word decides.
  const docsLine = text.match(/^\*\*External docs required:\*\*[ \t]*(.*)$/m)?.[1]?.trim() ?? null;
  const docs = docsLine?.match(/^(yes|no)\b(?![ \t]*\|)/i)?.[1]?.toLowerCase() ?? docsLine;
  if (!['yes', 'no'].includes(docs)) errors.push(`spec ${docs === null ? 'lacks' : `has an unusable`} **External docs required:** ${docs === null ? '(yes | no)' : `(${docs})`} — fix it in brainstorm or by hand, then re-approve`);
  const stamp = text.match(STAMP_RE);
  if (!stamp) {
    errors.push(APPROVAL_RE.test(text)
      ? 'the **Approval:** line is not a stamp (expected "approved by the user on <date> · decision: <ref> · body-sha256 `<hash>`") — the spec was never stamped, or the line was hand-edited'
      : 'spec has no **Approval:** line — it was never stamped');
    return { ok: false, errors, spec: rel, sha256, approved_on: null, decision: null };
  }
  const [, approvedOn, decision, approvedSha] = stamp;
  if (approvedSha !== sha256) errors.push(`spec bytes changed after approval (approved ${approvedSha.slice(0, 12)}…, current ${sha256.slice(0, 12)}…) — re-approve`);
  return { ok: errors.length === 0, errors, spec: rel, sha256, approved_on: approvedOn, decision };
}

function main() {
  const { opts, positionals } = parseArgv(process.argv.slice(2));
  const cmd = positionals[0];
  const projectRoot = requireOpt(opts, 'project-root');
  const spec = requireOpt(opts, 'spec');
  if (cmd === 'stamp') {
    const res = stampApproval({ projectRoot, spec, expectedSha: requireOpt(opts, 'expected'), decision: requireOpt(opts, 'decision'), date: opts.date, consent: opts.consent === 'yes' });
    console.log(JSON.stringify(res, null, 2));
    if (!res.written) console.error('preview only — re-run with --consent yes after the user approved these exact draft bytes');
    return;
  }
  if (cmd === 'verify') {
    const res = verifyApproval({ projectRoot, spec });
    console.log(JSON.stringify(res, null, 2));
    process.exit(res.ok ? 0 : 3);
  }
  throw new Error(`unknown command ${cmd}; use stamp | verify`);
}

if (process.argv[1] && fileURLToPath(import.meta.url) === realpathOrSelf(process.argv[1])) {
  try {
    main();
  } catch (err) {
    console.error(`approval: ${err.message}`);
    process.exit(1);
  }
}
