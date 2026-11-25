// ingest.mjs — validates judge/disprove answers against the contract and the pack binding. It only
// ever writes run.model.*; deterministic findings are re-derived by finalize() and never touched.
import fs from 'node:fs';
import { Refusal, assertInputFile, readRun, writeRun } from './paths.mjs';
import { OUTCOMES, VERDICTS, IMPACTS, MAX_TEXT, SCHEMAS } from './contract.mjs';
import { finalize } from './evidence.mjs';

function exactKeys(obj, keys) {
  return obj && typeof obj === 'object' && !Array.isArray(obj) && Object.keys(obj).length === keys.length && keys.every((k) => k in obj);
}

const shortText = (v) => typeof v === 'string' && v.length <= MAX_TEXT;

export function ingest(work, phase, file) {
  if (phase !== 'judge' && phase !== 'disprove') throw new Refusal('bad-phase', '--phase must be judge or disprove');
  const run = readRun(work);
  if (run.llm === false) throw new Refusal('llm-off', 'this run was scanned with --no-llm — no pack and no ingest');
  assertInputFile(file);
  const model = JSON.parse(JSON.stringify(run.model));
  const dropped = [];
  let doc;
  try { doc = JSON.parse(fs.readFileSync(file, 'utf8')); } catch { doc = null; }
  const answers = [];
  if (!exactKeys(doc, SCHEMAS[phase].top)) dropped.push({ reason: 'invalid-document' });
  else if (doc.phase !== phase) dropped.push({ reason: 'wrong-phase' });
  else if (doc.nonce !== model.nonce) dropped.push({ reason: 'wrong-nonce' });
  else if (!Array.isArray(doc.answers)) dropped.push({ reason: 'invalid-document' });
  else answers.push(...doc.answers);

  if (phase === 'judge') {
    const items = new Map((model.items || []).map((i) => [i.item_id, i]));
    const seen = new Set();
    model.candidates = [];
    model.judged = [];
    for (const a of answers) {
      const id = a && typeof a === 'object' ? a.item_id : undefined;
      if (!exactKeys(a, SCHEMAS.judge.answer)) { dropped.push({ reason: 'invalid-answer', item_id: typeof id === 'string' ? id.slice(0, 40) : undefined }); continue; }
      const item = items.get(a.item_id);
      if (!item) { dropped.push({ reason: 'unknown-item', item_id: String(a.item_id).slice(0, 40) }); continue; }
      if (seen.has(a.item_id)) { dropped.push({ reason: 'duplicate-item', item_id: a.item_id }); continue; }
      if (!item.allowed_sc.includes(a.sc)) { dropped.push({ reason: 'sc-not-allowed', item_id: a.item_id }); continue; }
      if (!OUTCOMES.includes(a.outcome)) { dropped.push({ reason: 'bad-outcome', item_id: a.item_id }); continue; }
      if (!IMPACTS.includes(a.impact)) { dropped.push({ reason: 'bad-impact', item_id: a.item_id }); continue; }
      if (!shortText(a.rationale) || !shortText(a.false_positive_if)) { dropped.push({ reason: 'text-too-long', item_id: a.item_id }); continue; }
      seen.add(a.item_id);
      model.judged.push({ item_id: a.item_id, outcome: a.outcome });
      if (a.outcome === 'needs-review') {
        model.candidates.push({ candidate_id: `c-${a.item_id}`, item_id: a.item_id, kind: item.kind, sc: a.sc, impact: a.impact, rationale: a.rationale, false_positive_if: a.false_positive_if });
      }
    }
    model.published = [];
    model.phases.judge = 'ingested';
  } else {
    const cands = new Map((model.candidates || []).map((c) => [c.candidate_id, c]));
    const items = new Map((model.items || []).map((i) => [i.item_id, i]));
    const upheld = new Set();
    for (const a of answers) {
      const id = a && typeof a === 'object' ? a.candidate_id : undefined;
      if (!exactKeys(a, SCHEMAS.disprove.answer)) { dropped.push({ reason: 'invalid-answer', item_id: typeof id === 'string' ? id.slice(0, 40) : undefined }); continue; }
      const cand = cands.get(a.candidate_id);
      if (!cand) { dropped.push({ reason: 'unknown-candidate', item_id: String(a.candidate_id).slice(0, 40) }); continue; }
      if (!VERDICTS.includes(a.verdict)) { dropped.push({ reason: 'bad-verdict', item_id: cand.item_id }); continue; }
      if (!shortText(a.reason)) { dropped.push({ reason: 'text-too-long', item_id: cand.item_id }); continue; }
      if (a.verdict === 'upheld') upheld.add(a.candidate_id);
      else cand.disprove = 'rejected by the disprove pass';
    }
    model.published = [];
    for (const cand of model.candidates || []) {
      if (!upheld.has(cand.candidate_id)) { if (!cand.disprove) cand.disprove = 'no valid disprove answer'; continue; }
      const item = items.get(cand.item_id) || {};
      model.published.push({ item_id: cand.item_id, kind: cand.kind, sc: [cand.sc], impact: cand.impact, rationale: cand.rationale, false_positive_if: cand.false_positive_if, evidence_id: item.evidence_id ?? null, page: item.page ?? null, viewport: item.viewport ?? null, state: item.state ?? null, selector: item.selector ?? '' });
    }
    model.phases.disprove = 'ingested';
  }
  model.dropped = [...(model.dropped || []), ...dropped.map((d) => ({ ...d, phase }))];
  run.model = model;
  finalize(run);
  writeRun(work, run);
  return { dropped: dropped.length, candidates: model.candidates.length, published: model.published.length };
}
