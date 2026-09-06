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

const schemaFile = path.join(path.dirname(fileURLToPath(import.meta.url)), '..', 'schemas', 'review-result.schema.json');

// Typed gaps. Every kind blocks; the kind tells the caller what unblocks it.
export const MISSING_KINDS = {
  'missing-file': 'a pack file the reviewer needed — add it with --dep and run once more',
  'required-decision': 'a product/design decision only the user can make — ask, record, then review again if material',
  'external-fact': 'a fact outside the repository (vendor docs, API behavior) — verify against current documentation and add it as a dependency',
  unspecified: 'the reviewer did not classify the gap — treat as required until the user resolves it',
};
export const MATERIAL_SEVERITIES = ['critical', 'major'];

export function loadSchema() {
  return JSON.parse(fs.readFileSync(schemaFile, 'utf8'));
}

// The JSON schema handed to the reviewer (Claude --json-schema) — the reviewer_output definition.
export function reviewerOutputSchema() {
  const schema = loadSchema();
  return { ...schema.$defs.reviewer_output, $defs: { finding: schema.$defs.finding, missing_context_item: schema.$defs.missing_context_item } };
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

export function validateReviewerOutput(value) {
  return validate(reviewerOutputSchema(), value);
}

export function validateReviewResult(result) {
  return validate(loadSchema(), result);
}

// Strings (schema-1 reviewers) become `unspecified`; objects keep their declared kind.
export function normalizeMissingContext(items = []) {
  return items.map((it) => (typeof it === 'string' ? { kind: 'unspecified', detail: it } : { kind: MISSING_KINDS[it.kind] ? it.kind : 'unspecified', detail: it.detail }));
}

// Decide the result status from a parsed reviewer output. Never converts a gap into ship.
//   packPaths — the exact paths in the pack; evidence_read must name them.
//   toolUses  — the adapter's observed tool surface; any activity rejects the opinion.
//   isError   — the CLI's own error envelope.
export function judgeOutput(output, { packPaths = null, toolUses = null, isError = false } = {}) {
  if (isError) return { status: 'failed', verdict: null, error: 'CLI returned an error envelope; no opinion was produced' };
  const activity = toolActivity(toolUses);
  if (activity) return { status: 'failed', verdict: null, error: `unexpected tool/delegation activity in a closed-context review: ${activity}` };
  const errors = validateReviewerOutput(output);
  if (errors.length) return { status: 'failed', verdict: null, error: `reviewer output invalid: ${errors.join('; ')}` };
  const unanchored = output.findings.filter((f) => !f.evidence.trim());
  if (unanchored.length) return { status: 'failed', verdict: null, error: `${unanchored.length} finding(s) without evidence` };
  if (packPaths) {
    const unknown = output.evidence_read.filter((p) => !packPaths.includes(p));
    if (unknown.length) return { status: 'failed', verdict: null, error: `evidence_read names paths not in the pack: ${unknown.join(', ')}` };
  }
  const material = output.findings.filter((f) => MATERIAL_SEVERITIES.includes(f.severity) || f.kind === 'fundamental');
  if (output.verdict === 'ship' && material.length) return { status: 'failed', verdict: null, error: `contradictory result: verdict ship with ${material.length} critical/major/fundamental finding(s)` };
  const missing = normalizeMissingContext(output.missing_context);
  if (missing.length > 0) {
    return { status: 'needs-context', verdict: null, missing, error: `reviewer reported missing context: ${missing.map((m) => `[${m.kind}] ${m.detail}`).join('; ')}` };
  }
  return { status: 'completed', verdict: output.verdict, missing: [], error: null };
}

function toolActivity(toolUses) {
  if (!toolUses) return null;
  const parts = [];
  if (Number(toolUses.count) > 0) parts.push(`${toolUses.count} tool call(s): ${(toolUses.types ?? []).slice(0, 3).join(' | ')}`);
  if (Number(toolUses.subagents_spawned) > 0) parts.push(`${toolUses.subagents_spawned} subagent(s)`);
  if (Number(toolUses.permission_denials) > 0) parts.push(`${toolUses.permission_denials} denied attempt(s)`);
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
