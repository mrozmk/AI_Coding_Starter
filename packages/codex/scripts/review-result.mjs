#!/usr/bin/env node
// Validation of reviewer output and review results (contract 9; T08). Runs outside the model process:
// the reviewer's final message is parsed here, never trusted as-is. A "completed" status is earned
// only by a consistent, anchored, pack-referencing opinion; no heuristic manufactures it.
//   node scripts/review-result.mjs --result <review-result.json>
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { parseArgv, requireOpt } from './lib/argv.mjs';
import { validate } from './lib/schema.mjs';
import { realpathOrSelf } from './lib/fsx.mjs';
import { containmentError, evidencePathOf, successfulReads } from './lib/reads.mjs';

const schemaFile = path.join(path.dirname(fileURLToPath(import.meta.url)), '..', 'schemas', 'review-result.schema.json');

// Typed gaps. Every kind blocks; the kind tells the caller what unblocks it.
export const MISSING_KINDS = {
  'missing-file': 'a pack file the reviewer needed — add it with --dep and run once more',
  'required-decision': 'a product/design decision only the user can make — ask, record, then review again if material',
  'external-fact': 'a fact outside the repository (vendor docs, API behavior) — verify against current documentation and add it as a dependency',
  unspecified: 'the reviewer did not classify the gap — treat as required until the user resolves it',
};
export const MATERIAL_SEVERITIES = ['critical', 'major'];
export const CONTEXT_MODES = ['closed', 'hybrid'];
// Hybrid-only qualifier of a `missing-file` gap: what the author can still do about it.
export const MISSING_FILE_REASONS = ['absent', 'excluded', 'budget'];

export function loadSchema() {
  return JSON.parse(fs.readFileSync(schemaFile, 'utf8'));
}

// The JSON schema handed to the reviewer (Claude --json-schema) — the reviewer_output definition.
// Closed returns the same bytes it always did (the closed prompt embeds it); hybrid swaps in the
// missing_context_item variant that carries `reason` on missing-file gaps.
export function reviewerOutputSchema(mode = 'closed') {
  if (!CONTEXT_MODES.includes(mode)) throw new Error(`context mode must be closed or hybrid, got ${mode}`);
  const schema = loadSchema();
  const item = mode === 'hybrid' ? schema.$defs.missing_context_item_hybrid : schema.$defs.missing_context_item;
  return { ...schema.$defs.reviewer_output, $defs: { finding: schema.$defs.finding, missing_context_item: item } };
}

// Pull the first JSON object out of a model's final message: bare, fenced, or embedded in prose.
export function extractJson(text) {
  if (typeof text !== 'string' || !text.trim()) return { ok: false, error: 'empty output' };
  const candidates = [];
  const fence = text.match(/```(?:json)?\s*([\s\S]*?)```/);
  if (fence) candidates.push(fence[1]);
  candidates.push(text);
  const first = text.indexOf('{');
  const last = text.lastIndexOf('}');
  if (first !== -1 && last > first) candidates.push(text.slice(first, last + 1));
  for (const c of candidates) {
    try {
      const parsed = JSON.parse(c.trim());
      if (parsed && typeof parsed === 'object' && !Array.isArray(parsed)) return { ok: true, value: parsed };
    } catch { /* try next candidate */ }
  }
  return { ok: false, error: 'no JSON object in output' };
}

export function validateReviewerOutput(value, mode = 'closed') {
  return validate(reviewerOutputSchema(mode), value);
}

export function validateReviewResult(result) {
  return validate(loadSchema(), result);
}

// Strings (schema-1 reviewers) become `unspecified`; objects keep their declared kind, and a
// missing-file gap keeps its hybrid `reason` when it is one of the known three.
export function normalizeMissingContext(items = []) {
  return items.map((it) => {
    if (typeof it === 'string') return { kind: 'unspecified', detail: it };
    const kind = MISSING_KINDS[it.kind] ? it.kind : 'unspecified';
    const out = { kind, detail: it.detail };
    if (kind === 'missing-file' && MISSING_FILE_REASONS.includes(it.reason)) out.reason = it.reason;
    return out;
  });
}

// Decide the result status from a parsed reviewer output. Never converts a gap into ship.
//   mode        — closed (the pack is the whole world) or hybrid (pack + read broker).
//   packPaths   — the exact paths in the pack; evidence_read must name them (or, hybrid, broker reads).
//   toolUses    — the adapter's observed tool surface; closed: any activity rejects; hybrid: any
//                 tool other than the broker's, any subagent, any native permission denial rejects.
//   brokerTools — hybrid: the host's spelling of the three broker tools (mcp__reader__read_file, …).
//   reads       — hybrid: the parsed reads.jsonl records; every successful read must satisfy containment.
//   roots       — hybrid: { project, plugin } the broker was configured with (required).
//   isError     — the CLI's own error envelope.
export function judgeOutput(output, { mode = 'closed', packPaths = null, toolUses = null, brokerTools = [], reads = [], roots = null, isError = false } = {}) {
  if (!CONTEXT_MODES.includes(mode)) return { status: 'failed', verdict: null, error: `unknown context mode ${mode}` };
  if (mode === 'hybrid' && (!roots || typeof roots.project !== 'string' || typeof roots.plugin !== 'string')) return { status: 'failed', verdict: null, error: 'hybrid judge without roots — containment cannot be checked' };
  if (isError) return { status: 'failed', verdict: null, error: 'CLI returned an error envelope; no opinion was produced' };
  const activity = toolActivity(toolUses, { mode, brokerTools });
  if (activity) return { status: 'failed', verdict: null, error: `unexpected tool/delegation activity in a ${mode}-context review: ${activity}` };
  const errors = validateReviewerOutput(output, mode);
  if (errors.length) return { status: 'failed', verdict: null, error: `reviewer output invalid: ${errors.join('; ')}` };
  const unanchored = output.findings.filter((f) => !f.evidence.trim());
  if (unanchored.length) return { status: 'failed', verdict: null, error: `${unanchored.length} finding(s) without evidence` };
  let readPaths = [];
  if (mode === 'hybrid') {
    const successful = successfulReads(reads);
    for (const rec of successful) {
      const problem = containmentError(rec, roots);
      if (problem) return { status: 'failed', verdict: null, error: `broker record outside roots: ${problem} (seq ${rec.seq})` };
    }
    readPaths = successful.map((r) => evidencePathOf(r.root, r.path));
  }
  if (packPaths) {
    const allowed = new Set([...packPaths, ...readPaths]);
    const unknown = output.evidence_read.filter((p) => !allowed.has(p));
    if (unknown.length) return { status: 'failed', verdict: null, error: mode === 'hybrid' ? `evidence_read names paths neither in the pack nor read through the broker: ${unknown.join(', ')}` : `evidence_read names paths not in the pack: ${unknown.join(', ')}` };
  }
  const material = output.findings.filter((f) => MATERIAL_SEVERITIES.includes(f.severity) || f.kind === 'fundamental');
  if (output.verdict === 'ship' && material.length) return { status: 'failed', verdict: null, error: `contradictory result: verdict ship with ${material.length} critical/major/fundamental finding(s)` };
  const missing = normalizeMissingContext(output.missing_context);
  if (missing.length > 0) {
    return { status: 'needs-context', verdict: null, missing, error: `reviewer reported missing context: ${missing.map((m) => `[${m.kind}${m.reason ? `:${m.reason}` : ''}] ${m.detail}`).join('; ')}` };
  }
  return { status: 'completed', verdict: output.verdict, missing: [], error: null };
}

function toolActivity(toolUses, { mode = 'closed', brokerTools = [] } = {}) {
  if (!toolUses) return null;
  const parts = [];
  if (mode === 'hybrid') {
    const names = (toolUses.types ?? []).map((t) => String(t));
    const other = names.filter((n) => !brokerTools.includes(n));
    if (other.length) parts.push(`${other.length} non-broker tool call(s): ${other.slice(0, 3).join(' | ')}`);
  } else if (Number(toolUses.count) > 0) parts.push(`${toolUses.count} tool call(s): ${(toolUses.types ?? []).slice(0, 3).join(' | ')}`);
  if (Number(toolUses.subagents_spawned) > 0) parts.push(`${toolUses.subagents_spawned} subagent(s)`);
  if (Number(toolUses.permission_denials) > 0) parts.push(`${toolUses.permission_denials} ${mode === 'hybrid' ? 'native ' : ''}denied attempt(s)`);
  // Turn count is not activity: Claude's structured-output run takes a second turn with no tools.
  return parts.length ? parts.join(', ') : null;
}

// A result advances an artifact only when it completed; everything else blocks until resolved
// or explicitly waived by the user (recorded by the caller, never here).
export function blocksAdvancement(result) {
  if (!result || result.status !== 'completed') return true;
  if (result.verdict === 'revise') return true;
  return false;
}

// Versioned reader: schema-1 records carry string gaps; the caller sees one shape.
export function readReviewResult(file) {
  const result = JSON.parse(fs.readFileSync(file, 'utf8'));
  const errors = validateReviewResult(result);
  if (errors.length) throw new Error(`review result invalid: ${errors.join('; ')}`);
  return { ...result, missing_context: normalizeMissingContext(result.missing_context) };
}

function main() {
  const { opts } = parseArgv(process.argv.slice(2));
  const result = readReviewResult(requireOpt(opts, 'result'));
  console.log(JSON.stringify({ review_id: result.review_id, status: result.status, verdict: result.verdict, blocks_advancement: blocksAdvancement(result), missing_context: result.missing_context, model: result.model, effort: result.effort }, null, 2));
  process.exit(blocksAdvancement(result) ? 3 : 0);
}

if (process.argv[1] && fileURLToPath(import.meta.url) === realpathOrSelf(process.argv[1])) {
  try {
    main();
  } catch (err) {
    console.error(`review-result: ${err.message}`);
    process.exit(1);
  }
}
