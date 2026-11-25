// pack.mjs — the model-phase lock, the read manifest and the judge/disprove packs. Untrusted strings
// are JSON-encoded between nonce markers after a trusted header that carries the answer contract.
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { Refusal, handoffsRoot, readRun, writeRun, writeAtomic, evidencePath, reportPaths } from './paths.mjs';
import { KINDS, RULES, SCHEMAS, allowedScFor } from './contract.mjs';
import { inSet } from './evidence.mjs';

export const MAX_ITEMS = 80;
const STALE_MS = 2 * 60 * 60 * 1000;

export function lockDir(cwd = process.cwd()) {
  return path.join(handoffsRoot(cwd), '.wcag-model-lock');
}

export function sha256(text) {
  return crypto.createHash('sha256').update(String(text)).digest('hex');
}

function readJson(p) {
  try { return JSON.parse(fs.readFileSync(p, 'utf8')); } catch { return null; }
}

function reportRendered(work) {
  return fs.existsSync(reportPaths(work).html);
}

export function assertLlm(run) {
  if (run.llm === false) throw new Refusal('llm-off', 'this run was scanned with --no-llm — no pack and no ingest');
}

// Takes (or re-takes, for the same run) the per-repository model-phase lock.
export function acquireLock(work, cwd = process.cwd()) {
  const dir = lockDir(cwd);
  try {
    fs.mkdirSync(dir);
  } catch (err) {
    if (err.code !== 'EEXIST') throw err;
    const holder = readJson(path.join(dir, 'lock.json'));
    if (holder && holder.work !== work) {
      const age = Date.now() - Date.parse(holder.at || 0);
      if (reportRendered(holder.work) || age > STALE_MS) throw new Refusal('model-phase-stale', `a stale model-phase lock is held by ${path.basename(holder.work || '?')} — render that run or remove .agents/handoffs/.wcag-model-lock by hand`);
      throw new Refusal('model-phase-busy', `another /wcag-audit run (${path.basename(holder.work || '?')}) is in its model phase — wait for it to render`);
    }
  }
  return dir;
}

export function releaseLock(work, cwd = process.cwd()) {
  const dir = lockDir(cwd);
  const holder = readJson(path.join(dir, 'lock.json'));
  if (!fs.existsSync(dir)) return false;
  if (holder && holder.work !== work) return false;
  for (const f of ['lock.json', 'manifest.json']) fs.rmSync(path.join(dir, f), { force: true });
  fs.rmdirSync(dir);
  return true;
}

function writeManifest(dir, manifest) {
  writeAtomic(path.join(dir, 'manifest.json'), `${JSON.stringify(manifest, null, 2)}\n`);
}

export function writeProbe(work, cwd = process.cwd()) {
  const run = readRun(work);
  assertLlm(run);
  const dir = acquireLock(work, cwd);
  const nonce = crypto.randomBytes(12).toString('hex');
  const probeDenied = path.join(work, 'probe-denied.txt');
  fs.writeFileSync(probeDenied, 'This file is outside the pack manifest; reading it must be denied.\n');
  writeAtomic(path.join(dir, 'lock.json'), `${JSON.stringify({ nonce, work, pid: process.pid, at: new Date().toISOString() })}\n`);
  writeManifest(dir, { nonce, work, allowed: [], probe_denied: fs.realpathSync(probeDenied) });
  run.model.nonce = nonce;
  run.model.phases.probe = 'written';
  writeRun(work, run);
  return { nonce, probe_denied: fs.realpathSync(probeDenied) };
}

export function guardProven(work, nonce, probeDenied) {
  let lines = [];
  try { lines = fs.readFileSync(path.join(work, 'read-guard.log'), 'utf8').split('\n').filter(Boolean); } catch { return false; }
  const want = sha256(probeDenied);
  return lines.some((l) => {
    try {
      const e = JSON.parse(l);
      return e.nonce === nonce && e.decision === 'deny' && e.path_hash === want;
    } catch { return false; }
  });
}

function judgeItems(run) {
  const items = [];
  for (const s of run.semantic_items || []) {
    const allowed = inSet(run, allowedScFor(s.kind));
    if (!allowed.length || !KINDS[s.kind]) continue;
    items.push({ item_id: s.item_id, kind: s.kind, evidence_id: s.evidence_id ?? null, allowed_sc: allowed, page: s.page, viewport: s.viewport, state: s.state, selector: s.selector ?? '', data: { text: s.text ?? null, ax: s.ax_excerpt ?? null, context: s.context ?? null } });
  }
  for (const o of run.observations || []) {
    if (o.source !== 'axe' || o.outcome !== 'needs-review') continue;
    const allowed = inSet(run, o.sc);
    if (!allowed.length) continue;
    items.push({ item_id: `ax-${o.id}`, kind: 'axe-incomplete', evidence_id: o.evidence_ids[0] ?? null, allowed_sc: allowed, page: o.page, viewport: o.viewport, state: o.state, selector: o.selector, data: { rule: o.contributor.replace(/^axe:/, ''), help: o.data?.help ?? null } });
  }
  return items;
}

function cropPaths(work, run, items) {
  const out = [];
  for (const it of items) {
    if (!it.evidence_id) continue;
    const ev = (run.evidence || []).find((e) => e.id === it.evidence_id);
    if (!ev) continue;
    const p = evidencePath(work, ev.path);
    if (p) out.push(fs.realpathSync(p));
  }
  return [...new Set(out)];
}

export function writePack(work, phase, cwd = process.cwd()) {
  if (phase !== 'judge' && phase !== 'disprove') throw new Refusal('bad-phase', '--phase must be probe, judge or disprove');
  const run = readRun(work);
  assertLlm(run);
  const dir = lockDir(cwd);
  const holder = readJson(path.join(dir, 'lock.json'));
  const manifest = readJson(path.join(dir, 'manifest.json'));
  // A refusal before the judge phase means the model phases are skipped: the report's scope row says
  // so. After the judge phase the "model phase not completed" label already describes the run.
  const guardRefusal = (hint) => {
    if (!run.model.phases?.judge) {
      run.model.guard_inactive = true;
      writeRun(work, run);
    }
    return new Refusal('guard-not-proven', hint);
  };
  if (!holder || holder.work !== work || !manifest) throw guardRefusal('no probe for this run — run pack --phase probe and the probe spawn first');
  if (!guardProven(work, holder.nonce, manifest.probe_denied)) throw guardRefusal('read-guard.log holds no probe denial for the current nonce — the judge Read hook is not active');
  const nonce = holder.nonce;
  let items;
  let fpRows = null;
  if (phase === 'judge') {
    items = judgeItems(run);
    if (items.length > MAX_ITEMS) {
      run.ledger.push({ kind: 'pack-cap', count: items.length - MAX_ITEMS });
      items = items.slice(0, MAX_ITEMS);
    }
    run.model.items = items.map(({ item_id, kind, allowed_sc, evidence_id, page, viewport, state, selector }) => ({ item_id, kind, allowed_sc, evidence_id, page, viewport, state, selector }));
  } else {
    // Each candidate travels with its own sanitized evidence, so the disprove judge checks the
    // evidence itself; the first judge's rationale is a separate field, never a substitute.
    const byId = new Map((run.model.items || []).map((i) => [i.item_id, i]));
    const evidence = new Map(judgeItems(run).map((i) => [i.item_id, i.data]));
    items = run.model.candidates.map((c) => ({ candidate_id: c.candidate_id, item_id: c.item_id, kind: c.kind, sc: c.sc, evidence_id: byId.get(c.item_id)?.evidence_id ?? null, data: evidence.get(c.item_id) ?? null, rationale: c.rationale, false_positive_if: c.false_positive_if }));
    fpRows = Object.fromEntries([...new Set(items.map((i) => i.kind))].map((k) => [k, KINDS[k]?.false_positive_if ?? []]));
  }
  const crops = cropPaths(work, run, items);
  const pack = {
    trusted: { tool: 'wcag-audit', phase, nonce, rules: RULES[phase], schema: SCHEMAS[phase], false_positive_rows: fpRows, crops },
    untrusted: `<<<WCAG-DATA ${nonce}>>>\n${JSON.stringify(items)}\n<<<END ${nonce}>>>`,
  };
  const file = path.join(work, `pack-${phase}.json`);
  writeAtomic(file, `${JSON.stringify(pack, null, 2)}\n`);
  writeManifest(dir, { nonce, work, allowed: [fs.realpathSync(file), ...crops], probe_denied: manifest.probe_denied });
  run.model.phases[`${phase}_pack`] = 'written';
  if (phase === 'judge') delete run.model.guard_inactive;
  writeRun(work, run);
  return { pack: fs.realpathSync(file), items: items.length, nonce };
}
