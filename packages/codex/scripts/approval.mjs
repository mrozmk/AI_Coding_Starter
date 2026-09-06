#!/usr/bin/env node
// Spec approval identity (T02). A spec never carries its own whole-file hash: the approval is an
// external receipt under .agents/approvals/ that names the final approved bytes. `stamp` applies
// only the declared metadata transition (Status → Approved, Approval → receipt pointer), hashes the
// result and writes the receipt; `verify` recomputes the hash and compares. Any later edit fails.
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

export const APPROVALS_DIR = '.agents/approvals';
const STATUS_RE = /^\*\*Status:\*\*[ \t]*(.*)$/m;
const APPROVAL_RE = /^\*\*Approval:\*\*.*$/m;

export function receiptPathFor(specRel) {
  const base = path.posix.basename(toPosix(specRel)).replace(/\.md$/, '');
  return `${APPROVALS_DIR}/${base}.approval.json`;
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
export function applyTransition(text, { receiptRel, date }) {
  const status = text.match(STATUS_RE);
  if (!status) throw new Error('spec has no **Status:** line');
  if (!/^(Draft|Approved)\b/.test(status[1].trim())) throw new Error(`spec status is "${status[1].trim()}" — only Draft (or a stale Approved) can be stamped`);
  let out = text.replace(STATUS_RE, '**Status:** Approved');
  const line = `**Approval:** receipt \`${receiptRel}\` — approved by the user on ${date}`;
  out = APPROVAL_RE.test(out) ? out.replace(APPROVAL_RE, line) : out.replace(/^\*\*Status:\*\* Approved$/m, `**Status:** Approved\n${line}`);
  return out;
}

export function stampApproval({ projectRoot, spec, expectedSha, decision, date = new Date().toISOString().slice(0, 10), consent = false }) {
  const { root, abs, rel } = resolveSpec(projectRoot, spec);
  if (!fs.existsSync(abs)) throw new Error(`spec not found: ${rel}`);
  if (!decision || !decision.trim()) throw new Error('--decision is required: record where the user approved (message, ticket, review round)');
  const draft = fs.readFileSync(abs);
  const draftSha = sha256Hex(draft);
  if (!expectedSha) throw new Error('--expected is required: the SHA-256 of the draft bytes the user approved');
  if (expectedSha !== draftSha) throw new Error(`spec changed since the approved draft (expected ${expectedSha.slice(0, 12)}…, found ${draftSha.slice(0, 12)}…) — re-present it for approval`);
  const receiptRel = receiptPathFor(rel);
  const finalText = applyTransition(draft.toString('utf8'), { receiptRel, date });
  const finalBytes = Buffer.from(finalText, 'utf8');
  const receipt = {
    schema_version: 1,
    spec: rel,
    sha256: sha256Hex(finalBytes),
    bytes: finalBytes.length,
    draft_sha256: draftSha,
    approved_on: date,
    decision,
    stamped_at: new Date().toISOString(),
  };
  const preview = { spec: rel, receipt: receiptRel, draft_sha256: draftSha, final_sha256: receipt.sha256, transition: ['**Status:** Approved', `**Approval:** receipt \`${receiptRel}\``] };
  if (!consent) return { written: false, preview };
  atomicWrite(abs, finalBytes);
  atomicWrite(path.join(root, receiptRel), `${JSON.stringify(receipt, null, 2)}\n`);
  return { written: true, preview, receipt };
}

export function verifyApproval({ projectRoot, spec }) {
  const errors = [];
  let root; let abs; let rel;
  try { ({ root, abs, rel } = resolveSpec(projectRoot, spec)); } catch (e) { return { ok: false, errors: [e.message] }; }
  if (!fs.existsSync(abs)) return { ok: false, errors: [`spec not found: ${rel}`] };
  const bytes = fs.readFileSync(abs);
  const sha256 = sha256Hex(bytes);
  const text = bytes.toString('utf8');
  const status = text.match(STATUS_RE)?.[1]?.trim() ?? null;
  if (status !== 'Approved') errors.push(`spec status is ${status ?? 'missing'}, not Approved`);
  // plan-feature's research step keys off this field; a spec without it cannot say whether docs were needed.
  // Authors append a rationale after the value ("yes — SDK reference for …"); only the leading word decides.
  const docsLine = text.match(/^\*\*External docs required:\*\*[ \t]*(.*)$/m)?.[1]?.trim() ?? null;
  const docs = docsLine?.match(/^(yes|no)\b(?![ \t]*\|)/i)?.[1]?.toLowerCase() ?? docsLine;
  if (!['yes', 'no'].includes(docs)) errors.push(`spec ${docs === null ? 'lacks' : `has an unusable`} **External docs required:** ${docs === null ? '(yes | no)' : `(${docs})`} — fix it in brainstorm or by hand, then re-approve`);
  const receiptRel = receiptPathFor(rel);
  const receiptAbs = path.join(root, receiptRel);
  if (!isInside(root, receiptAbs)) errors.push(`receipt path escapes the project: ${receiptRel}`);
  if (!fs.existsSync(receiptAbs)) errors.push(`no approval receipt at ${receiptRel} — the spec was never stamped, or the stamp was interrupted`);
  let receipt = null;
  if (errors.length === 0) {
    try { receipt = JSON.parse(fs.readFileSync(receiptAbs, 'utf8')); } catch (e) { errors.push(`receipt unreadable: ${e.message}`); }
  }
  if (receipt) {
    if (receipt.schema_version !== 1) errors.push('receipt schema_version must be 1');
    if (receipt.spec !== rel) errors.push(`receipt names ${receipt.spec}, not ${rel}`);
    if (!/^[0-9a-f]{64}$/.test(receipt.sha256 ?? '')) errors.push('receipt sha256 malformed');
    else if (receipt.sha256 !== sha256) errors.push(`spec bytes changed after approval (receipt ${receipt.sha256.slice(0, 12)}…, current ${sha256.slice(0, 12)}…) — re-approve`);
    if (!receipt.decision) errors.push('receipt has no decision reference');
    if (!text.includes(`receipt \`${receiptRel}\``)) errors.push('spec Approval line does not point at its receipt');
  }
  return { ok: errors.length === 0, errors, spec: rel, sha256, receipt: receiptRel, decision: receipt?.decision ?? null, approved_on: receipt?.approved_on ?? null };
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
