// The author lane's scripts: which scenarios may get a spec (`select`, also from a /qa-verify
// working file), the mechanical spec rules (`lint`), the draft's ownership (`draft`, `reject`) and
// the only writer of a scenario's `Spec` field (`claim`) — after three green passes of
// `run.mjs verify` and a critic verdict bound to the same spec, inputs and block digests. Writes
// candidate files only under the run directory it is given and the catalog only under the checkout
// lock; never commits. Node builtins only — ships to every downstream. Contract: regression.md §14.
//
//   node .claude/lib/regression/author.mjs select (<ID>… | --area <CODE[,CODE]> | --pending | --from-qa <file>) [--env <n>] [--json] [--root <dir>]
//   node .claude/lib/regression/author.mjs lint <spec> --id <ID> [--root <dir>]
//   node .claude/lib/regression/author.mjs draft <ID> --run <run dir> [--qa <ac_id>] [--root <dir>]
//   node .claude/lib/regression/author.mjs claim <ID> --spec <path> --verify <run dir> --critic <file> [--provenance <file>] [--root <dir>]
//   node .claude/lib/regression/author.mjs reject <ID> --run <run dir> [--root <dir>]
//   node .claude/lib/regression/author.mjs suggest --from-qa <file> [--root <dir>]
//     exit 0 ok · 1 none eligible / violations / refused · 2 usage / config / no target (prints `environments:`)

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { loadConfig, envPolicy, resolveTarget, isObject, specDir } from './config.mjs';
import { blockTexts, loadCatalog, parseCatalog, validateCatalog, specOf, awaitsSpec, areaOf, sourceTokens, statusOf, needsKeys, posix } from './catalog.mjs';
import { exclusionReason, viewportProjects, evidenceKey, changedPart, VERIFY_PASSES } from './policy.mjs';
import { withCheckoutLock, ensureRunsDir, RUNS_DIR } from './run.mjs';
import { lintSpec } from './speclint.mjs';
import { writeAtomic, parseTables } from '../backlog-check.mjs';

const PASS_NUMBERS = Array.from({ length: VERIFY_PASSES }, (_, i) => i + 1);
const RECORD_MARKER = /^qa-verify:v1 record /;
const ROW = /^- (\S+) \[([0-9a-f]{6})\] — ([^—]+?) — /;

class UsageError extends Error {}
class Refusal extends Error {}
const refuse = (m) => { throw new Refusal(m); };

function loadAdopted(root) {
  const loaded = loadConfig(root);
  if (!loaded.adopted) return null;
  if (loaded.errors.length) throw new UsageError(loaded.errors.map((e) => `.claude/regression.json: ${e}`).join('\n'));
  return loaded.config;
}

/** `<runner.spec_dir>/<area lowercased>/<id lowercased>.spec.ts` — one spec file per scenario. */
export function specPathFor(cfg, id) {
  return posix(path.join(specDir(cfg), areaOf(id).toLowerCase(), `${id.toLowerCase()}.spec.ts`));
}

/** Why `b` may not get a spec on this target, or null. `policy` null skips the environment check. */
function selectProblem(root, cfg, b, policy, envName) {
  const [, status] = statusOf(b);
  if (status !== 'READY') return `not READY (${b.fields.Status?.value})`;
  if (specOf(b) !== null) return 'already has a spec';
  if (policy) {
    const reason = exclusionReason({ id: b.id, needs: needsKeys(b.fields.Needs?.value), effect: b.fields.Effect?.value ?? 'read' }, policy, envName);
    if (reason) return reason;
  }
  const noDevice = viewportProjects(cfg, b.fields.Viewport?.value).find((d) => d.project === null);
  if (noDevice) return `no device ${noDevice.device}`;
  const target = specPathFor(cfg, b.id);
  if (fs.existsSync(path.resolve(root, target))) return `target exists — ${target}`;
  return null;
}

// ---------------------------------------------------------------------------------------------
// --from-qa: the working file's record and its tables

const normId = (s) => String(s).replace(/-/g, '').toUpperCase();

/** The interaction evidence of a fresh PASS row: `{driver: 'script'|'mcp'|'row', files}` or null. */
function evidenceFor(root, tables, acId) {
  for (const t of tables) {
    const col = (...names) => t.header.find((h) => names.includes(h.toLowerCase()));
    const idCol = col('ac', 'ac_id', 'id');
    const agentCol = col('agent', 'notes');
    const artCol = col('artifacts');
    if (!idCol || !artCol || !agentCol) continue;
    const row = t.rows.find((r) => normId(r[idCol]) === normId(acId));
    if (!row) continue;
    const text = t.header.map((h) => row[h]).join(' | ');
    const files = [...String(row[artCol] ?? '').matchAll(/[\w./-]+\.(?:mcp\.md|mjs|js|ts|png|jpg|json|md)/g)].map((m) => m[0])
      .filter((f) => fs.existsSync(path.resolve(root, f)));
    const driver = /driver:\s*(script|mcp)\b/.exec(text)?.[1];
    if (driver === 'script') { const s = files.filter((f) => /\.(mjs|js|ts)$/.test(f)); if (s.length) return { driver: 'script', files: s }; return null; }
    if (driver === 'mcp') { const s = files.filter((f) => f.endsWith('.mcp.md')); if (s.length) return { driver: 'mcp', files: s }; return null; }
    if (/\bqa-runtime-ui\b/.test(row[agentCol] ?? '')) return { driver: 'row', files: [] };
    return null;
  }
  return null;
}

/** `{ticket, rows: [{n, id, fp, disposition, kind}], tables}` of a working file, or throws a Refusal. */
export function readQaFile(root, file) {
  let text;
  try { text = fs.readFileSync(path.resolve(root, file), 'utf8').replace(/\r/g, ''); } catch { refuse(`not a qa-verify working file with a record — ${file} unreadable`); }
  const lines = text.split('\n');
  const last = [...lines].reverse().find((l) => l.trim() !== '') ?? '';
  if (!RECORD_MARKER.test(last)) refuse('not a qa-verify working file with a record');
  let ticket = /\bticket=(\S+)/.exec(last)?.[1] ?? null;
  if (ticket && /^\d+$/.test(ticket)) ticket = `#${ticket}`;
  const start = lines.findIndex((l) => /^### Criteria\s*$/.test(l));
  const rows = [];
  if (start >= 0) {
    for (let i = start + 1; i < lines.length && !/^#{1,3}\s/.test(lines[i]); i += 1) {
      const l = lines[i];
      if (l.trim() === '') continue;
      if (!l.startsWith('- ')) break;
      const m = ROW.exec(l);
      if (!m) refuse(`record row ${rows.length + 1} malformed`);
      const disposition = m[3].trim();
      const kind = /^PASS$/.test(disposition) ? 'pass'
        : /^PASS \(carried from \d{4}-\d{2}-\d{2}\)$/.test(disposition) ? 'carried'
          : /^FAIL\b/.test(disposition) ? 'fail' : 'other';
      rows.push({ n: rows.length + 1, id: m[1], fp: m[2], disposition, kind });
    }
  }
  const recordAt = lines.findIndex((l) => /^## QA verification/.test(l));
  const tables = parseTables((recordAt >= 0 ? lines.slice(0, recordAt) : lines).join('\n'));
  return { ticket, rows, tables };
}

/**
 * The join of a working file's record onto the catalog: per scenario one outcome
 * (`eligible` with its row and sequence, `not promoted`, `skipped`, `ambiguous`) and the PASS rows
 * no scenario cites. Only READY scenarios without a Spec take part.
 */
export function joinQa(root, blocks, qa) {
  const out = { joined: [], lines: [], orphanRows: [] };
  const evidence = new Map(qa.rows.filter((r) => r.kind === 'pass').map((r) => [r, evidenceFor(root, qa.tables, r.id)]));
  const withEvidence = [...evidence].filter(([, e]) => e).map(([r]) => r);
  const cited = new Set();
  for (const b of blocks) {
    if (!awaitsSpec(b)) continue;
    const tokens = sourceTokens(b.fields.Source?.value ?? '');
    const crit = tokens.filter((t) => t.kind === 'criterion');
    // A criterion may carry a `CITED` row plus its observed row (same id and fp): the observation decides.
    const groups = crit.map((t) => qa.rows.filter((r) => normId(r.id) === normId(t.id) && r.fp === t.fp)).filter((g) => g.length);
    const hits = groups.map((g) => g.find((r) => r.kind === 'fail') ?? g.find((r) => !/^CITED\b/.test(r.disposition)) ?? g[0]);
    for (const r of groups.flat()) cited.add(r);
    if (hits.length) {
      const h = hits[0];
      if (hits.some((x) => x.kind === 'fail')) { out.lines.push(`not promoted: ${b.id} — ${hits.find((x) => x.kind === 'fail').id} FAIL`); continue; }
      if (h.kind === 'carried') { out.lines.push(`skipped: ${b.id} — ${h.id} carried`); continue; }
      if (h.kind !== 'pass') { out.lines.push(`skipped: ${b.id} — ${h.id} ${h.disposition}`); continue; }
      const e = evidence.get(h);
      if (!e) { out.lines.push(`skipped: ${b.id} — no recorded sequence`); continue; }
      out.joined.push({ block: b, row: h, evidence: e });
      continue;
    }
    if (qa.ticket && tokens.some((t) => t.kind === 'tracker' && t.id === qa.ticket)) {
      if (withEvidence.length === 1) {
        const h = withEvidence[0];
        cited.add(h);
        out.joined.push({ block: b, row: h, evidence: evidence.get(h) });
      } else out.lines.push(`ambiguous: ${b.id} — author without --from-qa`);
    }
  }
  for (const r of qa.rows) if (r.kind === 'pass' && !cited.has(r)) out.orphanRows.push(r);
  return out;
}

// ---------------------------------------------------------------------------------------------
// select · lint · suggest

function cmdSelect(root, args) {
  const cfg = loadAdopted(root);
  if (!cfg) { console.log('regression not adopted'); return 0; }
  if (!isObject(cfg.runner)) throw new UsageError('baseline not established — run /setup:regression baseline');
  const target = resolveTarget(cfg, args.env);
  if (target.error) {
    console.error(`author: ${target.error}`);
    console.log(`environments: ${target.names.join(', ') || '(none)'}`);
    return 2;
  }
  const policy = envPolicy(cfg.environments[target.name]);
  const { settings, blocks } = loadCatalog(root, cfg);
  const errors = validateCatalog(blocks, settings);
  if (errors.length) { for (const e of errors) console.error(`${e.file}:${e.line}: ${e.message}`); return 2; }
  const result = { eligible: [], refused: [], lines: [] };
  const consider = (b, qa) => {
    const why = selectProblem(root, cfg, b, policy, target.name);
    if (why) result.refused.push({ id: b.id, reason: why });
    else result.eligible.push({ id: b.id, spec: specPathFor(cfg, b.id), ...(qa ? { qa } : {}) });
  };
  if (args.fromQa) {
    const j = joinQa(root, blocks, readQaFile(root, args.fromQa));
    result.lines.push(...j.lines);
    for (const x of j.joined) consider(x.block, { ac_id: x.row.id, sequence: x.evidence.driver, files: x.evidence.files });
    for (const r of j.orphanRows) result.lines.push(`no scenario: ${r.id}`);
  } else {
    let picked;
    if (args.pending) picked = blocks.filter(awaitsSpec);
    else if (args.area) {
      const codes = new Set(args.area.split(',').map((c) => c.trim()).filter(Boolean));
      picked = blocks.filter((b) => codes.has(areaOf(b.id)) && awaitsSpec(b));
    } else {
      picked = [];
      for (const id of args.ids) {
        const b = blocks.find((x) => x.id === id);
        if (b) picked.push(b); else result.refused.push({ id, reason: 'not in the catalog' });
      }
    }
    for (const b of picked) consider(b, null);
  }
  if (args.json) console.log(JSON.stringify({ env: target.name, ...result }, null, 2));
  else {
    for (const e of result.eligible) console.log(`eligible: ${e.id} ${e.spec}${e.qa ? ` qa: ${e.qa.ac_id} (${e.qa.sequence})${e.qa.files.length ? ` ${e.qa.files.join(' ')}` : ''}` : ''}`);
    for (const r of result.refused) console.log(`refused: ${r.id} — ${r.reason}`);
    for (const l of result.lines) console.log(l);
  }
  return result.eligible.length ? 0 : 1;
}

function cmdLint(root, args) {
  const cfg = loadAdopted(root);
  if (!cfg) throw new UsageError('regression not adopted');
  const r = lintSpec(root, cfg, args.spec, args.id);
  for (const v of r.violations) console.log(`${v.file}:${v.line}: ${v.rule}`);
  if (!r.violations.length) console.log(`lint ok — ${args.spec} (${r.files.length} files scanned)`);
  return r.violations.length ? 1 : 0;
}

function cmdSuggest(root, args) {
  const cfg = loadAdopted(root);
  if (!cfg || !isObject(cfg.runner)) return 0;
  let qa;
  try { qa = readQaFile(root, args.fromQa); } catch (err) { if (err instanceof Refusal) return 0; throw err; }
  const { blocks } = loadCatalog(root, cfg);
  const j = joinQa(root, blocks, qa);
  const eligible = j.joined.filter((x) => !selectProblem(root, cfg, x.block, null, null)).map((x) => x.block.id);
  if (eligible.length) { console.log(`suggest: /regression-tests author --from-qa ${args.fromQa} (${eligible.join(', ')})`); return 0; }
  const rowIds = new Set(qa.rows.map((r) => normId(r.id)));
  const citing = blocks.filter((b) => awaitsSpec(b)
    && sourceTokens(b.fields.Source?.value ?? '').some((t) => (t.kind === 'tracker' && t.id === qa.ticket) || (t.kind === 'criterion' && rowIds.has(normId(t.id)))));
  if (citing.length) console.log(`suggest: /regression-tests author ${citing.map((b) => b.id).join(' ')}`);
  return 0;
}

// ---------------------------------------------------------------------------------------------
// draft · claim · reject

const draftsFile = (runDir) => path.join(runDir, 'drafts.json');
const readDrafts = (runDir) => { try { return JSON.parse(fs.readFileSync(draftsFile(runDir), 'utf8')); } catch { return { drafts: [] }; } };

function cmdDraft(root, args) {
  const cfg = loadAdopted(root);
  if (!cfg) throw new UsageError('regression not adopted');
  const { blocks } = loadCatalog(root, cfg);
  const b = blocks.find((x) => x.id === args.id);
  if (!b) refuse(`${args.id} — not in the catalog`);
  ensureRunsDir(root);
  const runDir = path.resolve(root, args.run);
  fs.mkdirSync(runDir, { recursive: true });
  const spec = specPathFor(cfg, args.id);
  const abs = path.resolve(root, spec);
  fs.mkdirSync(path.dirname(abs), { recursive: true });
  try { fs.closeSync(fs.openSync(abs, 'wx')); } catch (err) {
    if (err.code === 'EEXIST') refuse(`${args.id} — target exists — ${spec}`);
    throw err;
  }
  const doc = readDrafts(runDir);
  doc.drafts.push({ id: args.id, spec, run: posix(path.relative(root, runDir)), created_at: new Date().toISOString(), ...(args.qa ? { qa: args.qa } : {}) });
  writeAtomic(draftsFile(runDir), `${JSON.stringify(doc, null, 2)}\n`);
  console.log(`draft: ${args.id} ${spec}`);
  return 0;
}

/** Every drafts.json entry of the runs directory that registers `spec`. */
function registrations(root, spec) {
  const dir = path.resolve(root, RUNS_DIR);
  if (!fs.existsSync(dir)) return [];
  return fs.readdirSync(dir, { withFileTypes: true }).filter((d) => d.isDirectory())
    .flatMap((d) => readDrafts(path.join(dir, d.name)).drafts.filter((x) => x.spec === spec));
}

/**
 * The draft a claim of `spec` claims: the newest registration that no reject has closed, or
 * undefined when none is live. A rejected or older registration of the same path never decides
 * what the claim requires.
 */
function liveDraft(root, spec) {
  return registrations(root, spec).filter((d) => !d.rejected_at)
    .sort((a, b) => String(a.created_at ?? '').localeCompare(String(b.created_at ?? ''))).at(-1);
}

/** Run `fn` under the checkout lock; a held lock refuses. */
function underCheckoutLock(root, owner, fn) {
  const r = withCheckoutLock(root, owner, fn);
  if (r.error) refuse(`checkout lock held — ${r.error}`);
  return r.value;
}

const readJson = (file, what) => {
  try { return JSON.parse(fs.readFileSync(file, 'utf8')); } catch { return refuse(`${what} unreadable — ${file}`); }
};

/**
 * The text with the empty `**Spec:**` value (`—`, `-` or nothing — what the catalog reads as no
 * spec) on 1-based `specLine` — the line the catalog parser found the block's Spec field on —
 * replaced by `value`, whether the field ends the line or another field follows it; null when absent.
 */
function withSpec(text, specLine, value) {
  const lines = text.split('\n');
  const i = specLine - 1;
  const m = i >= 0 && i < lines.length ? /\*\*Spec:\*\*\s*(?:—|-)?\s*?(?=\s*$| · \*\*[A-Za-z]+:\*\*)/.exec(lines[i]) : null;
  if (!m) return null;
  lines[i] = `${lines[i].slice(0, m.index)}**Spec:** ${value}${lines[i].slice(m.index + m[0].length).replace(/^\s*$/, '')}`;
  return lines.join('\n');
}

function cmdClaim(root, args) {
  const cfg = loadAdopted(root);
  if (!cfg) throw new UsageError('regression not adopted');
  return underCheckoutLock(root, `claim-${args.id}`, () => {
    const id = args.id;
    // The verify record and its own evidence.
    const rec = readJson(path.join(path.resolve(root, args.verify), 'verify.json'), 'verify.json');
    if (rec.schema !== 1) refuse(`${id} — verify.json is not schema 1`);
    const entry = (rec.scenarios ?? []).find((s) => s.id === id);
    if (!entry) refuse(`${id} — not in verify.json`);
    if (entry.spec !== args.spec) refuse(`${id} — verify.json verified ${entry.spec}, not ${args.spec}`);
    if (entry.qualified !== true || JSON.stringify(entry.passes_ok) !== JSON.stringify(PASS_NUMBERS)) refuse(`${id} — not three green passes (passes_ok ${JSON.stringify(entry.passes_ok ?? [])})`);
    const passes = rec.passes ?? [];
    if (passes.length !== VERIFY_PASSES || new Set(passes.map((p) => p.nonce)).size !== VERIFY_PASSES) refuse(`${id} — verify.json does not hold three passes with distinct nonces`);
    const { settings, files, blocks } = loadCatalog(root, cfg);
    const b = blocks.find((x) => x.id === id);
    if (!b) refuse(`${id} — not in the catalog`);
    const projects = viewportProjects(cfg, b.fields.Viewport?.value).map((d) => d.project);
    if (JSON.stringify([...(entry.projects ?? [])].sort()) !== JSON.stringify([...projects].sort())) refuse(`${id} — verified projects ${JSON.stringify(entry.projects)} are not the scenario's ${JSON.stringify(projects)}`);
    for (const p of passes) {
      for (const project of projects) {
        if (!(p.cases ?? []).some((c) => c.id === id && c.project === project && c.result === 'passed' && c.attempts === 1)) refuse(`${id} — pass ${p.n} has no single passed attempt on ${project}`);
      }
    }
    // The digests against the current files, and the lint.
    if (specOf(b) !== null) refuse(`${id} — already has a spec`);
    const specAbs = path.resolve(root, args.spec);
    if (!fs.existsSync(specAbs)) refuse(`${id} — spec file absent — ${args.spec}`);
    const lint = lintSpec(root, cfg, args.spec, id);
    const current = evidenceKey(root, args.spec, lint.files, blockTexts(root, files).get(id).text);
    const changed = changedPart(entry, current);
    if (changed) refuse(`${id} — ${changed} changed since the verify`);
    if (lint.violations.length) refuse(`${id} — lint: ${lint.violations[0].file}:${lint.violations[0].line}: ${lint.violations[0].rule}`);
    // The critic verdict (and the provenance verdict of a --from-qa draft) on the same digests.
    const critic = readJson(path.resolve(root, args.critic), 'critic verdict');
    if (critic.id !== id || critic.verdict !== 'pass') refuse(`${id} — no critic pass`);
    const criticStale = changedPart(critic, current);
    if (criticStale) refuse(`${id} — the critic verdict predates a change (${criticStale})`);
    const fromQa = Boolean(liveDraft(root, args.spec)?.qa);
    if (fromQa || args.provenance) {
      if (!args.provenance) refuse(`${id} — a --from-qa draft needs a provenance pass (--provenance)`);
      const prov = readJson(path.resolve(root, args.provenance), 'provenance verdict');
      if (prov.mode !== 'provenance' || prov.verdict !== 'pass' || (prov.id !== undefined && prov.id !== id)) refuse(`${id} — no provenance pass`);
      const provStale = changedPart(prov, current);
      if (provStale) refuse(`${id} — the provenance verdict predates a change (${provStale})`);
      const missing = (prov.actions ?? []).filter((a) => a.qa_step === null || a.qa_step === undefined);
      if (missing.length) refuse(`${id} — ${missing.length} action(s) with no recorded QA step (line ${missing[0].line})`);
    }
    // Write the Spec back on its own field line, validate, check the field now names the spec, rename.
    const file = path.resolve(root, b.file);
    const next = withSpec(fs.readFileSync(file, 'utf8').replace(/\r/g, ''), b.fields.Spec?.line ?? 0, `${args.spec} › ${lint.title}`);
    if (next === null) refuse(`${id} — no **Spec:** — in its block`);
    const tmp = `${file}.tmp-${process.pid}`;
    try {
      fs.writeFileSync(tmp, next);
      const reparsed = parseCatalog(root, files.map((f) => (path.resolve(root, f) === file ? tmp : f)));
      const errors = validateCatalog(reparsed, settings);
      if (errors.length) refuse(`${id} — the catalog would be invalid: ${errors[0].line}: ${errors[0].message}`);
      if (specOf(reparsed.find((x) => x.id === id) ?? { fields: {}, id })?.path !== args.spec) refuse(`${id} — the written Spec field does not name ${args.spec}`);
      fs.renameSync(tmp, file);
    } finally { fs.rmSync(tmp, { force: true }); }
    console.log(`claimed: ${id} — ${args.spec}`);
    return 0;
  });
}

function cmdReject(root, args) {
  const cfg = loadAdopted(root);
  if (!cfg) throw new UsageError('regression not adopted');
  return underCheckoutLock(root, `reject-${args.id}`, () => {
    const runDir = path.resolve(root, args.run);
    const doc = readDrafts(runDir);
    const mine = doc.drafts.filter((d) => d.id === args.id);
    if (!mine.length) refuse(`${args.id} — no draft registered in ${posix(path.relative(root, draftsFile(runDir)))}`);
    const draft = mine.filter((d) => !d.rejected_at).at(-1);
    if (!draft) { console.log(`rejected: ${args.id} — already rejected`); return 0; }
    const { blocks } = loadCatalog(root, cfg);
    const b = blocks.find((x) => x.id === args.id);
    if (b && specOf(b) !== null) refuse(`${args.id} — already claimed (Spec: ${b.fields.Spec.value})`);
    if (blocks.some((x) => specOf(x)?.path === draft.spec)) refuse(`${args.id} — ${draft.spec} is referenced by the catalog`);
    // Close the registration, so a later draft of the same path is judged on its own at claim.
    const close = () => {
      draft.rejected_at = new Date().toISOString();
      writeAtomic(draftsFile(runDir), `${JSON.stringify(doc, null, 2)}\n`);
    };
    const src = path.resolve(root, draft.spec);
    if (!fs.existsSync(src)) { close(); console.log(`rejected: ${args.id} — already gone`); return 0; }
    const dest = path.join(runDir, 'rejected', path.basename(draft.spec));
    fs.mkdirSync(path.dirname(dest), { recursive: true });
    try { fs.renameSync(src, dest); } catch { fs.copyFileSync(src, dest); fs.unlinkSync(src); }
    close();
    console.log(`rejected: ${args.id} — ${posix(path.relative(root, dest))}`);
    return 0;
  });
}

// ---------------------------------------------------------------------------------------------
// CLI

const USAGE = [
  'usage: node .claude/lib/regression/author.mjs select (<ID>… | --area <CODE[,CODE]> | --pending | --from-qa <file>) [--env <n>] [--json] [--root <dir>]',
  '       node .claude/lib/regression/author.mjs lint <spec> --id <ID> [--root <dir>]',
  '       node .claude/lib/regression/author.mjs draft <ID> --run <run dir> [--qa <ac_id>] [--root <dir>]',
  '       node .claude/lib/regression/author.mjs claim <ID> --spec <path> --verify <run dir> --critic <file> [--provenance <file>] [--root <dir>]',
  '       node .claude/lib/regression/author.mjs reject <ID> --run <run dir> [--root <dir>]',
  '       node .claude/lib/regression/author.mjs suggest --from-qa <file> [--root <dir>]',
].join('\n');

const FLAGS = { '--root': 'root', '--env': 'env', '--area': 'area', '--from-qa': 'fromQa', '--id': 'id', '--run': 'run', '--qa': 'qa', '--spec': 'spec', '--verify': 'verify', '--critic': 'critic', '--provenance': 'provenance' };
const COMMANDS = { select: cmdSelect, lint: cmdLint, draft: cmdDraft, claim: cmdClaim, reject: cmdReject, suggest: cmdSuggest };

function parseArgs(argv) {
  const [cmd, ...rest] = argv;
  if (!Object.hasOwn(COMMANDS, cmd ?? '')) throw new UsageError(cmd ? `unknown command ${cmd}` : 'a command is required');
  const args = { cmd, root: process.cwd(), ids: [], pending: false, json: false };
  const positional = [];
  for (let i = 0; i < rest.length; i += 1) {
    const a = rest[i];
    if (a === '--pending') args.pending = true;
    else if (a === '--json') args.json = true;
    else if (FLAGS[a]) {
      if (i + 1 >= rest.length) throw new UsageError(`${a} needs a value`);
      args[FLAGS[a]] = rest[++i];
    } else if (!a.startsWith('--')) positional.push(a);
    else throw new UsageError(`unknown argument ${a}`);
  }
  if (cmd === 'select') {
    args.ids = positional;
    const modes = [args.ids.length > 0, Boolean(args.area), args.pending, Boolean(args.fromQa)].filter(Boolean).length;
    if (modes !== 1) throw new UsageError('select takes exactly one of <ID>…, --area, --pending, --from-qa');
  } else if (cmd === 'lint') {
    if (positional.length !== 1 || !args.id) throw new UsageError('lint needs <spec> and --id <ID>');
    args.spec = positional[0];
  } else if (cmd === 'suggest') {
    if (!args.fromQa || positional.length) throw new UsageError('suggest needs --from-qa <file>');
  } else {
    if (positional.length !== 1) throw new UsageError(`${cmd} needs exactly one <ID>`);
    args.id = positional[0];
    const need = { draft: ['run'], reject: ['run'], claim: ['spec', 'verify', 'critic'] }[cmd];
    for (const k of need) if (!args[k]) throw new UsageError(`${cmd} needs --${k}`);
  }
  return args;
}

export function main(argv = process.argv.slice(2)) {
  let args;
  try { args = parseArgs(argv); } catch (err) {
    if (!(err instanceof UsageError)) throw err;
    console.error(`author: ${err.message}\n${USAGE}`);
    return 2;
  }
  const root = path.resolve(args.root);
  try {
    return COMMANDS[args.cmd](root, args);
  } catch (err) {
    if (err instanceof UsageError) { console.error(`author: ${err.message}`); return 2; }
    if (err instanceof Refusal) {
      if (args.cmd === 'select' || args.cmd === 'lint') { console.log(err.message); return 1; }
      console.log(`refused: ${err.message}`);
      return 1;
    }
    throw err;
  }
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    process.exitCode = main();
  } catch (err) {
    console.error(`author: ${err.message}`);
    process.exitCode = 2;
  }
}
