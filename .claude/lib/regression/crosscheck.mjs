// Cross-checks of the regression catalog, the delivery half of the kit: `--backlog` (every scenario
// against the backlog and the discovery flows; `--candidate <dir>` for /update-backlog) and
// `--delta <rev|none>` (the catalog against its base, a spec's or a plan's tagged criteria).
// Loaded by catalog.mjs through a dynamic import, only for those two modes. Read-only: it never
// writes under the root (the base side goes to a temp dir). Contract: .agents/reference/regression.md §16.

import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import crypto from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { catalogFiles, parseCatalog, validateCatalog, sourceTokens, extractFingerprintBlock, fingerprint, statusOf } from './catalog.mjs';
import { CONFIG_PATH, PRIORITIES, catalogSettings } from './config.mjs';
import { readBacklogFiles, parseBacklog, resolveTask, regressionTag, loadInventory, AC_DEFINITION, criterionText } from '../backlog-check.mjs';

const BACKLOG = '.agents/backlog.md';
const PLAN_DIRS = ['.agents/plans/active', '.agents/plans/done'];
const RANK = Object.fromEntries(PRIORITIES.map((p, i) => [p, i]));
const BACKLOG_ID = /^E\d+-\d+\.AC\d+$/;
const LOCAL_ID = /^[-*]\s+\*\*(AC-\d+)\*\*\s*[—–\-:]?\s*/;
const PROOF = /^(\s+)[-*]\s+Proof:\s*([a-z]+)\s*—\s*(.*)$/;
const SCENARIOS_LINE = /^\*\*Scenarios:\*\*[ \t]*(.*)$/m;
const SOURCE_LINE = /^\*\*Source spec:\*\*[ \t]*(.*)$/m;
const PARENT_LINE = /^\*\*Parent:\*\*[ \t]*(.*)$/m;

const norm = (s) => String(s ?? '').replace(/\s+/g, ' ').trim();
const posix = (p) => p.split(path.sep).join('/');
const isDropped = (b) => statusOf(b)[1] === 'DROPPED';
const tokensOf = (b) => sourceTokens(b.fields.Source?.value ?? '');
const cites = (b, token) => tokensOf(b).some((t) => t.raw === token);
const lineOf = (md, re) => { const i = md.split('\n').findIndex((l) => re.test(l)); return i === -1 ? 1 : i + 1; };
const list = (v) => v.split(',').map((t) => t.trim()).filter((t) => t !== '' && t !== '—');
const newResult = () => ({ errors: [], warnings: [], lines: [], fatal: false });
const err = (res, file, line, message) => res.errors.push({ file, line, message });
const fatal = (res, message) => { res.errors.push({ message }); res.fatal = true; return res; };

/** First 12 hex of the sha256 of the whitespace-normalised text — the `(Expected <d>)` digest. */
export const expectedDigest = (text) => crypto.createHash('sha256').update(norm(text)).digest('hex').slice(0, 12);

function git(root, args) {
  const r = spawnSync('git', ['-C', root, ...args], { encoding: 'utf8' });
  return { ok: r.status === 0, out: r.stdout ?? '' };
}

function readRel(root, rel) {
  const file = path.resolve(root, rel);
  try { return fs.readFileSync(file, 'utf8').replace(/\r/g, ''); } catch { return null; }
}

// ---------------------------------------------------------------------------------------------
// Containment and the two catalog sides
// ---------------------------------------------------------------------------------------------

const exists = (p) => { try { fs.lstatSync(p); return true; } catch { return false; } };
const within = (base, p) => { const rel = path.relative(base, p); return rel === '' || (rel.split(path.sep)[0] !== '..' && !path.isAbsolute(rel)); };

/** True when `rel` — or, when it does not exist yet, its nearest existing ancestor — resolves inside `base`. */
function contained(base, rel) {
  let cur = path.resolve(base, rel);
  while (!exists(cur) && path.dirname(cur) !== cur) cur = path.dirname(cur);
  try { return within(fs.realpathSync(base), fs.realpathSync(cur)); } catch { return false; }
}

function guardPaths(res, root, settings, candidate) {
  if (!contained(root, settings.path)) { fatal(res, `catalog path resolves outside the repository: ${settings.path}`); return false; }
  if (candidate && !contained(path.resolve(root, candidate), 'regression')) {
    fatal(res, `catalog path resolves outside the repository: ${posix(path.join(candidate, 'regression'))}`);
    return false;
  }
  return true;
}

/** Working-tree blocks; with a candidate, each `<dir>/regression/<name>` replaces the repo file `<catalog.path>/<name>`. */
function treeSide(root, settings, candidate) {
  const files = catalogFiles(root, settings);
  if (!candidate) return { blocks: parseCatalog(root, files), replaced: [] };
  const candRoot = path.resolve(root, candidate);
  const dir = path.join(candRoot, 'regression');
  const names = fs.existsSync(dir) && fs.statSync(dir).isDirectory()
    ? fs.readdirSync(dir, { withFileTypes: true }).filter((d) => d.isFile() && d.name.endsWith('.md') && d.name !== 'README.md').map((d) => d.name).sort()
    : [];
  const repoPath = (name) => posix(path.join(settings.path, name));
  const kept = files.filter((f) => !names.includes(path.basename(f)));
  const overlay = parseCatalog(candRoot, names.map((n) => `regression/${n}`)).map((b) => ({ ...b, file: repoPath(path.basename(b.file)) }));
  return { blocks: [...parseCatalog(root, kept), ...overlay], replaced: names.map(repoPath) };
}

/** Blocks at `base`, read through the base's own `catalog.path`; no config there = first adoption = none. */
function baseSide(root, base) {
  const cfg = git(root, ['show', `${base}:${CONFIG_PATH}`]);
  if (!cfg.ok) return [];
  let parsed;
  try { parsed = JSON.parse(cfg.out); } catch { return []; }
  const rel = String(catalogSettings(parsed).path).replace(/\/+$/, '');
  if (path.isAbsolute(rel) || rel.includes('\\') || rel.split('/').includes('..')) return [];
  const ls = git(root, ['ls-tree', '-z', base, '--', `${rel}/`]);
  const files = ls.out.split('\0').map((l) => /^\d+ blob [0-9a-f]+\t(.+)$/.exec(l)?.[1])
    .filter((f) => f && f.endsWith('.md') && path.posix.basename(f) !== 'README.md' && path.posix.dirname(f) === rel);
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'regression-base-'));
  try {
    for (const f of files) {
      fs.mkdirSync(path.dirname(path.join(tmp, f)), { recursive: true });
      fs.writeFileSync(path.join(tmp, f), git(root, ['show', `${base}:${f}`]).out);
    }
    return parseCatalog(tmp, files);
  } finally {
    fs.rmSync(tmp, { recursive: true, force: true });
  }
}

function byId(blocks) {
  const m = new Map();
  for (const b of blocks) if (!m.has(b.id)) m.set(b.id, b);
  return m;
}

/** `added`, `changed` (id → labels) and the `removed` errors; ids are matched across files. */
function diffSides(res, baseBlocks, tree) {
  const was = byId(baseBlocks);
  const now = byId(tree);
  const added = [...now.keys()].filter((id) => !was.has(id));
  const changed = new Map();
  for (const [id, b] of now) {
    const o = was.get(id);
    if (!o) continue;
    const labels = [...new Set([...Object.keys(o.fields), ...Object.keys(b.fields)])]
      .filter((l) => norm(o.fields[l]?.value) !== norm(b.fields[l]?.value));
    if (o.title !== b.title) labels.unshift('title');
    if (labels.length) changed.set(id, labels);
  }
  for (const [id, o] of was) if (!now.has(id)) err(res, o.file, o.line, `${id}: removed — ids are never deleted; mark it DROPPED`);
  if (added.length) res.lines.push(`added ${added.join(', ')}`);
  for (const [id, labels] of changed) res.lines.push(`changed ${id} (${labels.join(', ')})`);
  return { added, changed, was, now };
}

// ---------------------------------------------------------------------------------------------
// Criteria, tokens, plan headers
// ---------------------------------------------------------------------------------------------

/**
 * Active top-level criteria of a file's `## Acceptance Criteria` section: the bullet plus the
 * indented lines `specCriteria` appends, minus nested `- Proof: …` lines (collected per criterion).
 * A `Technical checks` sub-list or sub-heading is no criterion.
 */
export function criteriaOf(md) {
  const raw = [];
  let inSection = false;
  let skip = false;
  let cur = null;
  let proofIndent = null;
  (md ?? '').replace(/\r/g, '').split('\n').forEach((line, idx) => {
    if (/^##\s/.test(line)) { inSection = /^##\s+acceptance criteria\b/i.test(line); cur = null; skip = false; return; }
    if (!inSection) return;
    if (/^#{3,}\s/.test(line)) { cur = null; skip = /technical checks/i.test(line); return; }
    if (skip) return;
    if (/^[-*]\s+/.test(line)) {
      proofIndent = null;
      cur = /^[-*]\s+(\*\*)?Technical checks\b/i.test(line) ? null : { line: idx + 1, lines: [line.replace(/^\*\s+/, '- ')], proofs: [] };
      if (cur) raw.push(cur);
      return;
    }
    if (!cur) return;
    const p = PROOF.exec(line);
    if (p) { proofIndent = p[1].length; cur.proofs.push({ kind: p[2], value: p[3].trim(), line: idx + 1 }); return; }
    if (/^\s+\S/.test(line)) {
      if (proofIndent !== null && line.search(/\S/) > proofIndent) return;
      if (/^\s*[-*]\s+\*\*/.test(line)) { cur = null; return; }
      proofIndent = null;
      cur.lines.push(line);
      return;
    }
    cur = null; proofIndent = null;
  });
  return raw.map((c) => {
    const d = AC_DEFINITION.exec(c.lines[0]);
    const local = d ? null : LOCAL_ID.exec(c.lines[0]);
    const id = d ? d[1].trim() : local ? local[1] : null;
    const head = local ? `- ${c.lines[0].slice(local[0].length)}` : c.lines[0];
    const text = criterionText([head, ...c.lines.slice(1)]);
    const tag = regressionTag(text);
    return { id, backlogId: id && BACKLOG_ID.test(id) ? id : null, text, line: c.line, priority: tag.priority, problem: tag.problem,
      withdrawn: tag.withdrawn, proofs: c.proofs };
  }).filter((c) => !c.withdrawn);
}

/** Citation token of a criterion: `<id> [<fp>]` for a backlog id, else `<KEY> [<fp>]`; null without a key. */
function tokenOf(c, key, block) {
  if (c.backlogId) { const fp = fingerprint(block, `- **${c.backlogId}** ${c.text}`); return fp ? `${c.backlogId} [${fp}]` : null; }
  if (!key) return null;
  const fp = fingerprint(block, `- ${c.text}`);
  return fp ? `${key} [${fp}]` : null;
}

/** Criteria of one file with their tokens; tag-form, key and ambiguity problems go to `res` when given. */
function analyse(res, file, md, key, block) {
  const crits = criteriaOf(md);
  for (const c of crits) {
    c.token = tokenOf(c, key, block);
    if (!res) continue;
    if (c.problem) err(res, file, c.line, c.problem);
    if (!c.token && c.priority) {
      err(res, file, c.line, c.backlogId ? 'fingerprint unavailable — the §7c block failed under bash'
        : 'tagged criterion without a backlog id — pass --key <KEY> (or `key <KEY>` on the **Scenarios:** line)');
    }
  }
  const seen = new Map();
  for (const c of crits.filter((x) => x.priority && x.token)) {
    if (!seen.has(c.token)) { seen.set(c.token, c.line); continue; }
    if (res) err(res, file, c.line, `ambiguous ${c.token} — criteria at ${seen.get(c.token)}, ${c.line} hash the same; reword one`);
    c.ambiguous = true;
  }
  return crits;
}

/** `**Scenarios:** added … · changed <ID>[ (Expected <d>)], … · key <KEY>` → `{added, changed: Map id→digest|null, key, line}`. */
function parseScenarios(md) {
  const m = SCENARIOS_LINE.exec(md ?? '');
  if (!m) return null;
  const out = { added: [], changed: new Map(), key: null, line: lineOf(md, /^\*\*Scenarios:\*\*/) };
  for (const seg of m[1].split(' · ').map((s) => s.trim())) {
    let x;
    if ((x = /^added\s+(.*)$/.exec(seg))) out.added.push(...list(x[1]));
    else if ((x = /^changed\s+(.*)$/.exec(seg))) {
      for (const item of list(x[1])) {
        const y = /^(\S+)(?:\s+\(Expected ([0-9a-f]{12})\))?$/.exec(item);
        if (y) out.changed.set(y[1], y[2] ?? null);
      }
    } else if ((x = /^key\s+(\S+)$/.exec(seg))) out.key = x[1];
  }
  return out;
}

/** Approved / declined `Expected` changes recorded in a spec's `## Regression scenarios` section. */
function approvals(md) {
  const map = new Map();
  let inSection = false;
  for (const line of (md ?? '').split('\n')) {
    if (/^##\s/.test(line)) { inSection = /^##\s+Regression scenarios\b/i.test(line); continue; }
    if (!inSection) continue;
    for (const m of line.matchAll(/([A-Z][A-Z0-9]*-\d+)(?:\s*\([^)]*\))?\s*—\s*Expected ([0-9a-f]{12}) approved by\b/g)) map.set(m[1], m[2]);
    for (const m of line.matchAll(/([A-Z][A-Z0-9]*-\d+)\s*—\s*Expected change declined\b/g)) map.set(m[1], 'declined');
  }
  return map;
}

function refOf(value, fromDir) {
  const tick = /`([^`]+)`/.exec(value);
  if (tick) return path.posix.normalize(tick[1].trim());
  const link = /\[[^\]]*\]\(([^)\s]+)\)/.exec(value);
  if (link) return path.posix.normalize(path.posix.join(fromDir, link[1]));
  const word = /^(\S+)/.exec(value.trim());
  return word ? path.posix.normalize(word[1]) : null;
}

/** `{spec}` (repo-relative) or `{quick: true}`; an umbrella sub-step resolves it through its `**Parent:**`. */
function sourceSpecOf(root, rel, md, depth = 0) {
  const s = SOURCE_LINE.exec(md ?? '');
  if (s) return /^none\b/i.test(s[1].trim()) ? { quick: true } : { spec: refOf(s[1], path.posix.dirname(rel)) };
  const p = PARENT_LINE.exec(md ?? '');
  if (p && depth < 3) {
    const parent = refOf(p[1], path.posix.dirname(rel));
    const pmd = parent ? readRel(root, parent) : null;
    if (pmd !== null) return sourceSpecOf(root, parent, pmd, depth + 1);
  }
  return { quick: true };
}

function allPlans(root) {
  return PLAN_DIRS.flatMap((dir) => {
    const abs = path.join(root, dir);
    if (!fs.existsSync(abs)) return [];
    return fs.readdirSync(abs).filter((f) => f.endsWith('.md')).sort().map((f) => ({ rel: `${dir}/${f}`, md: readRel(root, `${dir}/${f}`) }));
  });
}

/** `/execute` moves the plan before QA reruns its checks: an `active/` path also resolves in `done/`, and back. */
function resolvePlan(root, rel) {
  const p = posix(rel);
  if (exists(path.resolve(root, p))) return p;
  const swapped = p.includes('/plans/active/') ? p.replace('/plans/active/', '/plans/done/') : p.replace('/plans/done/', '/plans/active/');
  return exists(path.resolve(root, swapped)) ? swapped : null;
}

/** Plans with the same source spec that this branch added or changed since `base`, plus the plan itself. */
function familyOf(root, base, planRel, spec) {
  const touched = new Set([planRel]);
  for (const f of git(root, ['diff', '--name-only', base, '--', '.agents/plans/']).out.split('\n')) if (f) touched.add(f);
  for (const l of git(root, ['status', '--porcelain', '--untracked-files=all', '--', '.agents/plans/']).out.split('\n')) {
    const m = /^\?\? (.+)$/.exec(l);
    if (m) touched.add(m[1]);
  }
  return allPlans(root).filter((p) => touched.has(p.rel) && (p.rel === planRel || sourceSpecOf(root, p.rel, p.md).spec === spec));
}

/** Ids a plan task will add: `### … UPDATE|CREATE <catalog file>` with an EXPECT `contains — <file> :: ### <ID> — ` → its IMPLEMENT text. */
function plannedBlocks(md, settings) {
  const out = new Map();
  const prefix = `${String(settings.path).replace(/\/+$/, '')}/`;
  const sections = (md ?? '').split(/\n(?=###\s)/);
  for (const sec of sections) {
    const head = /^###\s.*\b(?:UPDATE|CREATE)\s+`?([^\s`]+)`?/.exec(sec);
    if (!head || !head[1].startsWith(prefix)) continue;
    const impl = /^- \*\*IMPLEMENT\*\*:([\s\S]*?)(?=^- \*\*[A-Z]+\*\*|(?![\s\S]))/m.exec(sec)?.[1] ?? '';
    for (const m of sec.matchAll(/contains — `?([^\s`]+)`? :: ### (\S+) —/g)) if (m[1] === head[1]) out.set(m[2], impl);
  }
  return out;
}

// ---------------------------------------------------------------------------------------------
// --delta
// ---------------------------------------------------------------------------------------------

const snippet = (text) => text.replace(/^\s*[—–\-:.]?\s*\[reg P[0-2]\]\s*/, '').slice(0, 60);

/** Coverage and priority of the tagged criteria `crits` (tag from `tagOf`); `plannedFor(c)` accepts a planned block. */
function coverage(res, file, crits, live, tagOf, plannedFor) {
  const need = new Map();
  for (const c of crits) {
    const tag = tagOf(c);
    if (!tag || !c.token || c.ambiguous) continue;
    const by = live.filter((b) => cites(b, c.token));
    if (!by.length && !plannedFor(c)) err(res, file, c.line, `uncovered ${c.token} (${tag}) — ${snippet(c.text)}`);
    for (const b of by) if (!need.has(b.id) || RANK[tag] < RANK[need.get(b.id).tag]) need.set(b.id, { tag, b });
  }
  for (const { tag, b } of need.values()) {
    const p = b.fields.Priority?.value;
    if (RANK[p] > RANK[tag]) err(res, b.file, b.fields.Priority.line, `priority ${b.id} is ${p}, its criteria need ${tag}`);
  }
}

/** `Expected` edits of base blocks: each needs the spec-recorded digest, declared (plans) and matching the text. */
function expectedCheck(res, diff, approved, declared) {
  for (const [id, labels] of diff.changed) {
    if (!labels.includes('Expected')) continue;
    const b = diff.now.get(id);
    const at = b.fields.Expected?.line ?? b.line;
    const d = declared === undefined ? approved?.get(id) : declared?.get(id);
    const ok = d && approved && approved.get(id) === d && d !== 'declined';
    if (!ok) err(res, b.file, at, `Expected of ${id} changed without the recorded human yes`);
    else if (expectedDigest(b.fields.Expected?.value) !== d) err(res, b.file, at, `Expected of ${id} differs from the approved text`);
  }
}

function specMode(res, root, opts, block, live, diff) {
  const md = readRel(root, opts.spec);
  if (md === null) return err(res, opts.spec, null, `spec ${opts.spec} not found`);
  const crits = analyse(res, opts.spec, md, opts.key, block);
  if (crits.some((c) => c.ambiguous)) return undefined;
  coverage(res, opts.spec, crits, live, (c) => c.priority, () => false);
  if (diff) expectedCheck(res, diff, approvals(md), undefined);
  return undefined;
}

function planMode(res, root, settings, opts, block, live, diff, base) {
  const planRel = resolvePlan(root, opts.plan);
  const md = planRel ? readRel(root, planRel) : null;
  if (md === null) return err(res, opts.plan, null, `plan ${opts.plan} not found`);
  const meta = sourceSpecOf(root, planRel, md);
  const family = !meta.quick && base ? familyOf(root, base, planRel, meta.spec) : [{ rel: planRel, md }];
  const key = opts.key ?? family.map((p) => parseScenarios(p.md)?.key).find(Boolean) ?? null;
  const crits = analyse(res, planRel, md, key, block);
  if (crits.some((c) => c.ambiguous)) return undefined;
  let specTags = null;
  let specMd = null;
  if (!meta.quick) {
    specMd = readRel(root, meta.spec);
    if (specMd === null) err(res, planRel, lineOf(md, /^\*\*(Source spec|Parent):\*\*/), `source spec ${meta.spec} not found`);
    else {
      const scrits = analyse(res, meta.spec, specMd, key, block);
      specTags = new Map(scrits.filter((c) => c.token).map((c) => [c.token, c.priority]));
      // Completeness spans every peer on disk: a split's peers each carry only their own criteria.
      const peerTagged = new Set(allPlans(root).filter((p) => p.rel === planRel || sourceSpecOf(root, p.rel, p.md).spec === meta.spec)
        .flatMap((p) => analyse(null, p.rel, p.md, key, block).filter((c) => c.priority && c.token).map((c) => c.token)));
      for (const c of scrits) if (c.priority && c.token && !peerTagged.has(c.token)) err(res, planRel, 1, `tagged criterion ${c.token} missing from the plan`);
      for (const c of crits) {
        if (!c.token || !c.priority || !specTags.has(c.token) || specTags.get(c.token) === c.priority) continue;
        err(res, planRel, c.line, `tag of ${c.token} is ${c.priority} in the plan, ${specTags.get(c.token) ?? 'none'} in the source spec`);
      }
    }
  }
  const tagOf = (c) => (specTags?.has(c.token) ? specTags.get(c.token) : c.priority);
  const planned = opts.planning ? plannedBlocks(md, settings) : new Map();
  const scenarioIds = (c) => c.proofs.filter((p) => p.kind === 'scenario').map((p) => /^(\S+)/.exec(p.value)?.[1]).filter(Boolean);
  const plannedFor = (c) => c.token && scenarioIds(c).some((id) => planned.get(id)?.includes(c.token));
  coverage(res, planRel, crits, live, tagOf, plannedFor);
  const proofs = new Set();
  for (const c of crits) {
    const label = c.id ?? c.token ?? `line ${c.line}`;
    const sp = c.proofs.filter((p) => p.kind === 'scenario');
    if (tagOf(c) && c.token && !sp.length) err(res, planRel, c.line, `no Proof: scenario under ${c.token}`);
    for (const p of sp) {
      const id = /^(\S+)/.exec(p.value)?.[1] ?? '';
      proofs.add(id);
      const b = live.find((x) => x.id === id);
      if (!b) {
        if (!(c.token && planned.get(id)?.includes(c.token))) err(res, planRel, p.line, `Proof: scenario — ${id} under ${label}: no such scenario`);
      } else if (!c.token || !cites(b, c.token)) err(res, planRel, p.line, `Proof: scenario — ${id} under ${label}: does not cite ${c.token ?? '(no token)'}`);
    }
  }
  for (const id of proofs) res.lines.push(`proof ${id} deferred`);
  if (!diff) return undefined;
  const decl = { added: new Set(), changed: new Map() };
  const lines = family.map((p) => parseScenarios(p.md)).filter(Boolean);
  for (const s of lines) { s.added.forEach((id) => decl.added.add(id)); for (const [id, d] of s.changed) if (!decl.changed.get(id)) decl.changed.set(id, d); }
  expectedCheck(res, diff, meta.quick ? null : approvals(specMd), decl.changed);
  if (opts.planning) return undefined;
  const scenLine = parseScenarios(md)?.line ?? 1;
  const tagged = family.some((p) => analyse(null, p.rel, p.md, key, block).some((c) => tagOf(c)));
  if (tagged && !lines.length) err(res, planRel, 1, 'tagged criteria and no **Scenarios:** line in the plan family');
  for (const id of diff.added) {
    const b = diff.now.get(id);
    if (decl.added.has(id)) continue;
    err(res, b.file, b.line, decl.changed.has(id) ? `declared changed but new since the base ${id}` : `undeclared ${id}`);
  }
  for (const id of diff.changed.keys()) {
    const b = diff.now.get(id);
    if (!decl.added.has(id) && !decl.changed.has(id)) err(res, b.file, b.line, `undeclared ${id}`);
  }
  for (const id of new Set([...decl.added, ...decl.changed.keys()])) {
    if (decl.added.has(id) && diff.was.has(id)) err(res, planRel, scenLine, `declared added but exists on the base ${id}`);
    else if (!diff.added.includes(id) && !diff.changed.has(id)) err(res, planRel, scenLine, `declared but unchanged ${id}`);
  }
  return undefined;
}

/** `--delta <rev|none> [--spec <file> [--key <KEY>] | --plan <file> [--planning]]`. */
export function deltaCheck(root, settings, config, opts = {}) {
  const res = newResult();
  if (!guardPaths(res, root, settings)) return res;
  const tree = treeSide(root, settings).blocks;
  const invalid = validateCatalog(tree, settings);
  if (invalid.length) { res.errors.push(...invalid); return res; }
  let base = null;
  if (opts.rev === 'none') res.lines.push('delta: not evaluated — no base');
  else {
    const mb = git(root, ['merge-base', opts.rev, 'HEAD']);
    if (!mb.ok) return fatal(res, `unknown revision ${opts.rev} — no merge-base with HEAD`);
    base = mb.out.trim();
  }
  const diff = base ? diffSides(res, baseSide(root, base), tree) : null;
  if (!opts.spec && !opts.plan) return res;
  const fp = extractFingerprintBlock(root);
  if (fp.error) { err(res, opts.spec ?? opts.plan, null, fp.error); return res; }
  const live = tree.filter((b) => !isDropped(b));
  if (opts.spec) specMode(res, root, opts, fp.block, live, diff);
  else planMode(res, root, settings, opts, fp.block, live, diff, base);
  return res;
}

// ---------------------------------------------------------------------------------------------
// --backlog
// ---------------------------------------------------------------------------------------------

/** State lookups of criterion and flow tokens against one backlog and the discovery inventory. */
function stateLookup(root, backlog, block) {
  const resolved = new Map();
  const current = (task) => { if (!resolved.has(task.id)) resolved.set(task.id, resolveTask(root, backlog, task).current); return resolved.get(task.id); };
  const hasDiscovery = fs.existsSync(path.join(root, 'docs', 'discovery.md'));
  const ids = hasDiscovery ? loadInventory(root).ids : new Map();
  const criterion = (t) => {
    const taskId = t.id.split('.')[0];
    const task = backlog.tasks.find((x) => x.id === taskId);
    if (!task) return { active: false, error: `unknown ${t.raw} — Task ${taskId} absent` };
    if (task.withdrawn) return { active: false, error: `withdrawn ${t.raw} — Task ${taskId} withdrawn` };
    const c = current(task).find((a) => a.id === t.id);
    if (!c) return { active: false, error: `unknown ${t.raw} — not among ${taskId}'s current criteria` };
    if (c.withdrawn) {
      const s = /superseded by\s+([A-Za-z0-9.-]*[A-Za-z0-9])/i.exec(c.text);
      return { active: false, error: s ? `withdrawn ${t.raw} — superseded by ${s[1]}` : `withdrawn ${t.raw}` };
    }
    const fp = t.fp && block ? fingerprint(block, `- **${t.id}** ${c.text}`) : null;
    return { active: true, warning: fp && fp !== t.fp ? `${t.raw} cites an old fingerprint — re-point the Source (current [${fp}])` : null };
  };
  const flow = (t) => {
    if (!hasDiscovery) return { active: true, skipped: true };
    const e = ids.get(t.id);
    if (!e) return { active: false, error: `unknown ${t.raw} — not in docs/discovery.md` };
    const owner = t.id.includes('.') ? ids.get(t.id.split('.')[0]) : null;
    const st = e.state === 'active' && owner && owner.state !== 'active' ? owner : e;
    if (st.state === 'withdrawn') return { active: false, error: `withdrawn ${t.raw}` };
    if (st.state === 'superseded') return { active: false, error: `withdrawn ${t.raw} — superseded by ${st.successor}` };
    return { active: true };
  };
  return (t) => (t.kind === 'criterion' ? criterion(t) : t.kind === 'flow' ? flow(t) : null);
}

/** /update-backlog never deletes an id, never edits `Expected`, and drops a citation only of a retired criterion or flow. */
function candidateGuards(res, root, settings, side, stateOf) {
  const now = byId(side.blocks);
  const key = (t) => `${t.kind}:${t.id ?? t.raw}`;
  const active = (t) => stateOf?.(t)?.active === true;
  for (const o of parseCatalog(root, catalogFiles(root, settings))) {
    if (!side.replaced.includes(o.file)) continue;
    const c = now.get(o.id);
    if (!c) { err(res, o.file, o.line, `${o.id}: candidate removes a scenario — ids are never deleted`); continue; }
    if (norm(o.fields.Expected?.value) !== norm(c.fields.Expected?.value)) {
      err(res, c.file, c.fields.Expected?.line ?? c.line, `${o.id}: candidate changes Expected — /update-backlog never does`);
    }
    const kept = new Set(tokensOf(c).map(key));
    const at = c.fields.Source?.line ?? c.line;
    for (const t of tokensOf(o)) if (!kept.has(key(t)) && active(t)) err(res, c.file, at, `${o.id}: candidate drops the citation of active ${t.raw}`);
    if (!isDropped(o) && isDropped(c)) for (const t of tokensOf(c)) if (active(t)) err(res, c.file, at, `${o.id}: candidate drops a scenario still citing active ${t.raw}`);
  }
}

/** `--backlog [--candidate <dir>]`. */
export function backlogCheck(root, settings, { candidate } = {}) {
  const res = newResult();
  if (!guardPaths(res, root, settings, candidate)) return res;
  const side = treeSide(root, settings, candidate);
  const invalid = validateCatalog(side.blocks, settings);
  if (invalid.length) { res.errors.push(...invalid); return res; }
  const candRoot = candidate ? path.resolve(root, candidate) : null;
  const { md, epicFiles } = candRoot ? readBacklogFiles(path.join(candRoot, 'backlog.md'), path.join(candRoot, 'backlog')) : readBacklogFiles(path.resolve(root, BACKLOG));
  const parsed = md === null ? null : parseBacklog(md, { epicFiles });
  const backlog = !parsed || parsed.legacy || parsed.preScope || parsed.preDetail ? null : parsed;
  const fp = extractFingerprintBlock(root);
  const stateOf = backlog ? stateLookup(root, backlog, fp.error ? null : fp.block) : null;
  if (candidate) candidateGuards(res, root, settings, side, stateOf);
  if (!backlog) { res.lines.push(`backlog cross-check: n/a — no current-format ${BACKLOG}`); return res; }
  let skippedFlows = false;
  for (const b of side.blocks) {
    if (isDropped(b)) continue;
    const at = b.fields.Source?.line ?? b.line;
    for (const t of tokensOf(b)) {
      const s = stateOf(t);
      if (!s) continue;
      if (s.skipped) skippedFlows = true;
      if (s.error) err(res, b.file, at, `${b.id}: ${s.error}`);
      if (s.warning) res.warnings.push(`${b.file}:${at}: ${b.id}: ${s.warning}`);
    }
  }
  if (skippedFlows) res.lines.push('flows: not checked — no docs/discovery.md');
  const live = side.blocks.filter((b) => !isDropped(b));
  for (const task of backlog.tasks) {
    if (task.status !== 'DONE' || task.withdrawn) continue;
    for (const c of resolveTask(root, backlog, task).current) {
      if (c.withdrawn || !regressionTag(c.text).priority) continue;
      if (!live.some((b) => tokensOf(b).some((t) => t.kind === 'criterion' && t.id === c.id))) {
        err(res, BACKLOG, null, `${task.id}: DONE with tagged criterion ${c.id} and no scenario`);
      }
    }
  }
  return res;
}
