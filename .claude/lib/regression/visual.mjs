// Node side of the regression visual lane: the target sources (routes, Storybook) behind one
// interface, the accepted baselines (index, integrity, interrupted-accept recovery, tree digests),
// the path-disjointness check, the tolerance rule, the per-pass classifier and the record block,
// the lane policy (`warn` / `block`), and the only writer of baselines — the offer, its single-use
// acceptance token and `acceptOffer`. run.mjs orchestrates (refusals, locks, runners, verdict);
// this module never renders, never runs a runner and never imports run.mjs.
// Node builtins only — ships to every downstream. Contract: .agents/reference/regression.md §13.
//
// Library only (no CLI): `run.mjs visual compare | update | accept` is the entry point.

import fs from 'node:fs';
import path from 'node:path';
import { randomBytes } from 'node:crypto';
import { isObject, docKey, visualSettings, VISUAL_DEFAULTS, VISUAL_ID } from './config.mjs';
import { digestJson, canonicalJson, visualPlan, sha256, VISUAL_REPEAT } from './policy.mjs';
import { guardedFetch, scenarioId, escapeRe } from './guard.mjs';

export const PNG_SIG = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
const LFS_PREFIX = 'version https://git-lfs';
const ACCEPT_TTL_MS = 30 * 60 * 1000;
export const FP_FIELDS = ['browser', 'browser_version', 'playwright', 'platform', 'os_major', 'arch', 'fonts', 'mode'];
const INDEX_FILE = 'index.json';
const SHA_HEX = /^[0-9a-f]{64}$/;
const KEY_SEGMENT = /^[A-Za-z0-9][A-Za-z0-9.-]*$/;

const posix = (p) => p.split(path.sep).join('/');
const keyOf = (c) => `${c.id}\0${c.project}`;
const imageKey = (c) => `${c.project}/${c.file}`;

// ---------------------------------------------------------------------------------------------
// Sources — one interface: `enumerate(ctx)` → {state, reason?, targets, skipped, index_digest}

async function enumerateStorybook(ctx) {
  const sb = ctx.settings.storybook?.[ctx.env];
  if (!isObject(sb)) return { state: 'ok', targets: [], skipped: [], index_digest: null, configured: false };
  const failed = (reason) => ({ state: 'failed', reason, targets: [], skipped: [], index_digest: null, configured: true });
  const fetch = ctx.fetch ?? guardedFetch;
  let text;
  try {
    const r = await fetch(ctx.manifest, { url: `${sb.url}/index.json` });
    if (!(r.status >= 200 && r.status <= 299)) return failed(`index.json answered ${r.status}`);
    text = await r.text();
  } catch (err) { return failed(`index.json unreachable (${err.message})`); }
  let doc;
  try { doc = JSON.parse(text); } catch { return failed('index.json unparseable'); }
  const entries = isObject(doc) && doc.v >= 4 && isObject(doc.entries) ? doc.entries
    : isObject(doc) && doc.v === 3 && isObject(doc.stories) ? doc.stories : null;
  if (!entries) return failed('index.json of an unknown shape');
  const exclude = new Set(Array.isArray(sb.exclude_tags) ? sb.exclude_tags : []);
  const devices = Object.keys(isObject(ctx.cfg.runner?.devices) ? ctx.cfg.runner.devices : {}).filter((k) => !docKey(k));
  const targets = [];
  const skipped = [];
  for (const [key, e] of Object.entries(entries)) {
    if (!isObject(e)) continue;
    if ((e.type ?? 'story') !== 'story') continue;
    if ((Array.isArray(e.tags) ? e.tags : []).some((t) => exclude.has(t))) continue;
    const id = typeof e.id === 'string' ? e.id : key;
    if (!VISUAL_ID.test(id)) { skipped.push({ id, reason: `id does not match ${VISUAL_ID.source}` }); continue; }
    targets.push({
      id: `story:${id}`, source: 'storybook', title: [e.title, e.name].filter(Boolean).join(' / ') || id,
      url: `${sb.url}/iframe.html?id=${encodeURIComponent(id)}&viewMode=story`, devices,
      mask: [], full_page: false, wait_for: null, ready: sb.ready, error: sb.error ?? null, file: `storybook--${id}.png`,
    });
  }
  const digest = sha256(text);
  if (!targets.length) return { ...failed('no eligible story in index.json'), skipped, index_digest: digest };
  return { state: 'ok', targets, skipped, index_digest: digest, configured: true };
}

export const SOURCES = {
  routes: { name: 'routes', async enumerate(ctx) { return { state: 'ok', targets: visualPlan(ctx.cfg, ctx.env, 'compare').routes, skipped: [], index_digest: null }; } },
  storybook: { name: 'storybook', enumerate: enumerateStorybook },
};

// ---------------------------------------------------------------------------------------------
// Files: nearest real path, walks, tree digest, disjointness

/** The realpath of the nearest existing ancestor of `p`, with the not-yet-existing remainder appended. */
export function nearestReal(p) {
  let cur = path.resolve(p);
  const rest = [];
  for (;;) {
    try { return path.join(fs.realpathSync(cur), ...rest.reverse()); } catch { /* not there yet */ }
    const parent = path.dirname(cur);
    if (parent === cur) return path.join(cur, ...rest.reverse());
    rest.push(path.basename(cur));
    cur = parent;
  }
}
const insideAbs = (a, dir) => a === dir || a.startsWith(dir.endsWith(path.sep) ? dir : `${dir}${path.sep}`);
const overlapAbs = (a, b) => insideAbs(a, b) || insideAbs(b, a);

/** Every entry under `dir` (lstat — a symlink is reported, never followed): `[{rel, abs, link, file}]`. */
function walk(dir) {
  const out = [];
  const visit = (d) => {
    let names;
    try { names = fs.readdirSync(d).sort(); } catch { return; }
    for (const n of names) {
      const abs = path.join(d, n);
      const st = fs.lstatSync(abs);
      if (st.isSymbolicLink()) out.push({ rel: posix(path.relative(dir, abs)), abs, link: true, file: false });
      else if (st.isDirectory()) visit(abs);
      else if (st.isFile()) out.push({ rel: posix(path.relative(dir, abs)), abs, link: false, file: true });
    }
  };
  visit(dir);
  return out;
}

/** sha256 over the sorted `path → sha256` (or `link:<target>`) listing; an absent dir digests `[]`. */
export function treeDigest(dir) {
  return digestJson(walk(dir).map((e) => [e.rel, e.link ? `link:${fs.readlinkSync(e.abs)}` : sha256(fs.readFileSync(e.abs))]));
}

/** The functional runner's Playwright outputDir candidates, or `{error}` when one cannot be resolved statically. */
function functionalOutputDirs(root, cfg) {
  if (!isObject(cfg.runner) || typeof cfg.runner.config !== 'string') return { dirs: [] };
  const configAbs = path.resolve(root, cfg.runner.config);
  const configDir = path.dirname(configAbs);
  const dirs = [path.join(configDir, 'test-results')];
  const top = path.resolve(root);
  for (let d = configDir; ; d = path.dirname(d)) {
    if (fs.existsSync(path.join(d, 'package.json'))) { dirs.push(path.join(d, 'test-results')); break; }
    if (d === top || path.dirname(d) === d || !insideAbs(d, top)) break;
  }
  let text = '';
  try { text = fs.readFileSync(configAbs, 'utf8'); } catch { return { dirs }; }
  const code = text.split('\n').filter((l) => !/^\s*\/\//.test(l)).join('\n');
  const re = /\boutputDir\s*:\s*([^,\n}]+)/g;
  let m;
  while ((m = re.exec(code))) {
    const value = m[1].trim();
    const lit = /^(['"`])([^'"`$]*)\1$/.exec(value);
    if (lit) dirs.push(path.resolve(configDir, lit[2]));
    // `opts.outputDir` or `runnerOptions(…).outputDir`: the run directory, owned by run.mjs.
    else if (!/^(\w+|runnerOptions\(.*\))\.outputDir$/.test(value)) return { error: `cannot resolve the functional outputDir in ${cfg.runner.config} (${value}) — set it to a string literal or runnerOptions(…).outputDir (or opts.outputDir as in playwright.config.ts.template)` };
  }
  return { dirs };
}

/** null when the baselines are disjoint from every path a run deletes or a runner cleans, else the refusal. */
export function assertDisjoint(root, cfg, runsDir) {
  const s = visualSettings(cfg);
  const base = nearestReal(path.resolve(root, s.baselines));
  const items = [];
  if (isObject(cfg.runner) && typeof cfg.runner.report === 'string') items.push(['runner.report', path.resolve(root, cfg.runner.report)]);
  items.push(['visual.report', path.resolve(root, s.report)]);
  const fo = functionalOutputDirs(root, cfg);
  if (fo.error) return fo.error;
  for (const d of fo.dirs) items.push(['the functional outputDir', d]);
  items.push(['the run directory', path.resolve(root, runsDir)]);
  for (const [what, p] of items) {
    const r = nearestReal(p);
    if (overlapAbs(base, r)) return `visual.baselines overlaps ${what} (${posix(path.relative(nearestReal(root), r)) || '.'})`;
  }
  return null;
}

// ---------------------------------------------------------------------------------------------
// Index, integrity, tolerance

/** `{index|null, errors[], digest|null}` of `<dir>/index.json` (schema 1). */
export function readIndex(dir) {
  const file = path.join(dir, INDEX_FILE);
  let bytes;
  try { bytes = fs.readFileSync(file); } catch { return { index: null, errors: [], digest: null }; }
  let doc;
  try { doc = JSON.parse(bytes.toString('utf8')); } catch (err) { return { index: null, errors: [`index.json unparseable (${err.message})`], digest: sha256(bytes) }; }
  const errors = [];
  if (!isObject(doc) || doc.schema !== 1) errors.push('index.json: schema must be 1');
  else if (!isObject(doc.images)) errors.push('index.json: images must be an object');
  else {
    for (const [k, e] of Object.entries(doc.images)) if (!isObject(e) || !SHA_HEX.test(String(e.sha256))) errors.push(`index.json: images.${k} has no sha256`);
  }
  return { index: errors.length ? null : doc, errors, digest: sha256(bytes) };
}

const validKey = (k) => typeof k === 'string' && !path.isAbsolute(k) && k.split('/').length === 2 && k.split('/').every((s) => KEY_SEGMENT.test(s) && s !== '..') && k.endsWith('.png');

/** The recovery for each interrupted-accept sibling of `<baselines>/<env>` (staging / previous). */
function interruptedAccepts(baseAbs, env) {
  let names = [];
  try { names = fs.readdirSync(baseAbs); } catch { return []; }
  const parse = (kind) => names.map((n) => new RegExp(`^\\.${escapeRe(env)}\\.${kind}-(.+)$`).exec(n)).filter(Boolean).map((m) => m[0]);
  const staging = parse('staging');
  const previous = parse('previous');
  const envExists = fs.existsSync(path.join(baseAbs, env));
  const out = [];
  for (const p of previous) out.push(envExists ? `interrupted accept: remove ${p}` : `interrupted accept: restore: rename ${p} back to ${env}, then rerun visual update`);
  for (const s of staging) {
    if (envExists) out.push(`interrupted accept: remove ${s}; the accepted tree is intact`);
    else if (!previous.length) out.push(`interrupted accept: remove ${s}, then run visual update again`);
    else out.push(`interrupted accept: remove ${s}`);
  }
  return out;
}

/**
 * The accepted baselines of `env`, verified: `{integrity[], images: Map<key, entry>, index, index_digest,
 * target_errors: Map<key, reason>}`. Unknown or malformed state is an integrity reason, never "same".
 */
export function verifyBaselines(root, settings, env) {
  const baseAbs = path.resolve(root, settings.baselines);
  const envDir = path.join(baseAbs, env);
  const rel = (abs) => posix(path.relative(root, abs));
  const integrity = interruptedAccepts(baseAbs, env);
  const images = new Map();
  const targetErrors = new Map();
  if (!fs.existsSync(envDir)) return { integrity, images, index: null, index_digest: null, target_errors: targetErrors };
  const envReal = fs.realpathSync(envDir);
  const files = walk(envDir);
  for (const f of files) if (f.link) integrity.push(`baseline is a symlink: ${rel(f.abs)}`);
  const idx = readIndex(envDir);
  for (const e of idx.errors) integrity.push(`baselines index unreadable: ${rel(path.join(envDir, INDEX_FILE))} — ${e}`);
  const indexed = isObject(idx.index?.images) ? idx.index.images : {};
  for (const [key, entry] of Object.entries(indexed)) {
    if (!validKey(key)) { integrity.push(`index key outside the baselines: ${key}`); continue; }
    const abs = path.join(envDir, ...key.split('/'));
    if (!insideAbs(nearestReal(abs), envReal)) { integrity.push(`index key outside the baselines: ${key}`); continue; }
    let st;
    try { st = fs.lstatSync(abs); } catch { integrity.push(`baseline missing for index entry: ${rel(abs)}`); continue; }
    if (!st.isFile()) continue; // a symlink is already an integrity reason
    const bytes = fs.readFileSync(abs);
    images.set(key, entry);
    if (!bytes.subarray(0, 8).equals(PNG_SIG)) {
      targetErrors.set(key, bytes.toString('utf8', 0, LFS_PREFIX.length) === LFS_PREFIX ? 'Git LFS pointer — run git lfs pull' : 'baseline is not a PNG');
      continue;
    }
    if (sha256(bytes) !== entry.sha256) {
      integrity.push(`baseline altered outside visual accept: ${rel(abs)}`);
      // A comparison against an unaccepted file proves nothing: the target is an error, not differs.
      targetErrors.set(key, 'baseline altered outside visual accept');
    }
  }
  for (const f of files) {
    if (!f.file || f.rel === INDEX_FILE) continue;
    if (!f.rel.endsWith('.png')) integrity.push(`file not part of the baselines: ${rel(f.abs)}`);
    else if (!(f.rel in indexed)) integrity.push(`baseline not accepted: ${rel(f.abs)}`);
  }
  return { integrity, images, index: idx.index, index_digest: idx.digest, target_errors: targetErrors };
}

/** null, or the refusal when the config tolerance is wider than the accepted index's (or the defaults). */
export function toleranceCheck(settings, index) {
  const ref = isObject(index?.tolerance) ? index.tolerance : VISUAL_DEFAULTS.tolerance;
  for (const f of ['threshold', 'max_diff_pixels']) {
    if (settings.tolerance[f] > ref[f]) return `visual.tolerance widened over the accepted baselines (${f} ${ref[f]} → ${settings.tolerance[f]}) — no command widens a tolerance; a human edits index.json in a reviewed commit`;
  }
  return null;
}

/** Watches the whole baselines root across runner boundaries; the first change is kept. */
export function baselinesWatch(root, settings) {
  const dir = path.resolve(root, settings.baselines);
  let last = treeDigest(dir);
  let changed = null;
  return {
    check(after) {
      const now = treeDigest(dir);
      if (now !== last && !changed) changed = `baselines changed during the run (${after})`;
      last = now;
      return changed;
    },
    get changed() { return changed; },
  };
}

// ---------------------------------------------------------------------------------------------
// Evidence, report, per-pass classification

/** The run's `visual.jsonl` lines of this nonce. */
export function readEvidence(runDir, nonce) {
  const file = path.join(runDir, 'visual.jsonl');
  if (!fs.existsSync(file)) return [];
  return fs.readFileSync(file, 'utf8').split('\n').filter(Boolean).map((l) => { try { return JSON.parse(l); } catch { return null; } })
    .filter((e) => e && e.nonce === nonce);
}

const invalidReport = () => ({ valid: false, interrupted: false, tests: new Map() });

/** A visual pass report: `{valid, interrupted, tests: Map<id\0project, test[]>}` (one entry per repeat). */
export function readVisualReport(file) {
  let doc;
  try { doc = JSON.parse(fs.readFileSync(file, 'utf8')); } catch { return invalidReport(); }
  if (!isObject(doc) || !Array.isArray(doc.suites)) return invalidReport();
  const tests = new Map();
  let interrupted = false;
  const visit = (suite) => {
    for (const spec of suite.specs ?? []) {
      const id = scenarioId(spec.title) ?? String(spec.title ?? '').trim();
      for (const t of spec.tests ?? []) {
        if ((t.results ?? []).some((r) => r.status === 'interrupted')) interrupted = true;
        const k = keyOf({ id, project: t.projectName ?? '' });
        tests.set(k, [...(tests.get(k) ?? []), t]);
      }
    }
    for (const s of suite.suites ?? []) visit(s);
  };
  for (const s of doc.suites) visit(s);
  return { valid: true, interrupted, tests };
}

const testPassed = (t) => Array.isArray(t.results) && t.results.length === 1 && t.results[0].retry === 0 && t.results[0].status === 'passed';

/**
 * One pass, per case and repeat: the evidence line (exactly one, retry 0), the report entry (passed),
 * the guard attestation of this pass by test id, a guard-blocked request. `{results, guard_red,
 * attestation, renderers, renderer_conflicts, report_valid, interrupted}`.
 */
export function classifyPass({ pass, cases, repeat, evidence, report, events }) {
  const outcomes = evidence.filter((e) => e.kind === 'outcome' && e.pass === pass);
  const installed = events.filter((e) => e.kind === 'installed' && e.pass === pass);
  const blocked = events.filter((e) => e.kind === 'blocked' && e.test);
  const guardRed = [];
  const attestation = [];
  const results = new Map();
  for (const c of cases) {
    const k = keyOf(c);
    const mine = outcomes.filter((o) => o.id === c.id && o.project === c.project);
    const rtests = report.valid ? report.tests.get(k) ?? [] : null;
    const reps = [];
    for (let r = 0; r < repeat; r += 1) {
      const ls = mine.filter((o) => o.repeat === r);
      if (ls.length !== 1 || ls[0].retry !== 0) { reps.push({ repeat: r, outcome: 'error', reason: 'no outcome', ran: false, attested: false }); continue; }
      const o = ls[0];
      const attested = installed.some((i) => i.test === o.test && i.id === c.id && i.project === c.project);
      if (!attested) attestation.push(`guard not attested for ${c.id}/${c.project}/${pass}#${r}`);
      reps.push({ repeat: r, outcome: o.outcome, reason: o.reason ?? null, diff_pixels: o.diff_pixels ?? null, masked_ratio: o.masked_ratio ?? null, diff: o.diff ?? null, test: o.test, ran: true, attested });
    }
    // The report's repeat layout is undocumented: it must show every repeat, and no more failed
    // entries than the evidence explains — else every passing outcome of the case is in doubt.
    const failedEntries = rtests ? rtests.filter((t) => !testPassed(t)).length : 0;
    const explained = reps.filter((e) => e.outcome === 'differs' || e.outcome === 'error').length;
    const reportOk = rtests === null ? null : rtests.length === repeat && failedEntries <= explained;
    if (reportOk === false) {
      for (const e of reps) if (['same', 'missing', 'captured'].includes(e.outcome)) Object.assign(e, { outcome: 'error', reason: 'the report does not show the test passed', report_failed: true });
    }
    const tests = new Set(mine.map((o) => o.test));
    for (const i of events) if (i.kind === 'installed' && i.id === c.id && i.project === c.project) tests.add(i.test);
    if (blocked.some((b) => tests.has(b.test))) {
      guardRed.push(`guard blocked a request in ${c.id}/${c.project}`);
      for (const e of reps) Object.assign(e, { outcome: 'error', reason: 'guard blocked a request' });
    }
    results.set(k, { case: c, reps, report_ok: reportOk });
  }
  const renderers = {};
  const conflicts = new Set();
  for (const e of evidence.filter((x) => x.kind === 'renderer' && x.pass === pass)) {
    if (!renderers[e.project]) renderers[e.project] = e.fp;
    else if (canonicalJson(renderers[e.project]) !== canonicalJson(e.fp)) conflicts.add(e.project);
  }
  return { results, guard_red: guardRed, attestation, renderers, renderer_conflicts: [...conflicts], report_valid: report.valid, interrupted: report.interrupted };
}

/** The renderer fields in which two fingerprints differ (all when either is unknown). */
export function fingerprintDiff(a, b) {
  if (!isObject(a) || !isObject(b)) return ['renderer'];
  return FP_FIELDS.filter((f) => a[f] !== b[f]);
}

const fpText = (fp) => `${fp.browser} ${fp.browser_version} · Playwright ${fp.playwright} · ${fp.platform} ${fp.os_major} ${fp.arch} · fonts ${fp.fonts} · ${fp.mode}`;

/** Per project: the baselines' renderer, this run's and the fields that differ. */
export function portability(projects, index, renderers) {
  return projects.map((project) => {
    const base = isObject(index?.renderers?.[project]) ? index.renderers[project] : null;
    const now = renderers[project] ?? null;
    return { project, baseline_fingerprint: base, this_run: now, differs_in: base && now ? fingerprintDiff(base, now) : [] };
  });
}

export function portabilityLine(p) {
  if (!p.baseline_fingerprint) return `visual portability: ${p.project}: ${p.this_run ? fpText(p.this_run) : 'no renderer reported'} — no accepted baselines`;
  if (!p.this_run) return `visual portability: ${p.project}: ${fpText(p.baseline_fingerprint)} — this run reported no renderer`;
  return `visual portability: ${p.project}: ${fpText(p.baseline_fingerprint)} — this run ${p.differs_in.length ? `differs in ${p.differs_in.join(',')}` : 'same'}`;
}

/** Index keys of the environment not in this run's cases: never a no-device target's, never a failed source's. */
export function orphanKeys({ index, cases, sources, noDeviceFiles }) {
  const want = new Set(cases.map(imageKey));
  const failed = new Set(sources.filter((s) => s.state === 'failed').map((s) => s.name));
  return Object.keys(isObject(index?.images) ? index.images : {}).filter((k) => !want.has(k)).filter((k) => {
    const file = k.split('/').pop();
    if (noDeviceFiles.includes(file)) return false;
    return !failed.has(file.startsWith('storybook--') ? 'storybook' : 'routes');
  }).sort();
}

const emptyCounts = () => ({ same: 0, differs: 0, missing: 0, orphan: 0, error: 0, not_comparable: 0 });
const targetRow = (c, e) => ({ id: c.id, source: c.source, project: c.project, repeat: e.repeat, outcome: e.outcome, diff_pixels: e.diff_pixels ?? null, masked_ratio: e.masked_ratio ?? null, diff: e.diff ?? null, reason: e.reason ?? null });

/** The classification of a pass that never ran (or left no report): every case `no outcome`. */
export const emptyPass = (pass, cases) => classifyPass({ pass, cases, repeat: 1, evidence: [], report: invalidReport(), events: [] });

/**
 * The record block of a compare pass: targets with their outcomes (renderer-checked), orphans,
 * counts, the differences, the incomplete-pass reasons, the integrity reasons and the outcome.
 */
export function classifyVisual({ settings, env, cases, noDevice, sources, pass, verify, runner, integrityExtra = [], incompleteExtra = [], production = false, baselinesRel, build = null }) {
  const counts = emptyCounts();
  const targets = [];
  const differences = [];
  const incomplete = [];
  for (const { case: c, reps } of pass.results.values()) {
    const e = reps[0];
    const key = imageKey(c);
    let outcome = e.outcome;
    let reason = e.reason ?? null;
    const entry = verify.images.get(key);
    if (verify.target_errors.has(key)) { outcome = 'error'; reason = verify.target_errors.get(key); }
    else if ((outcome === 'same' || outcome === 'differs') && entry) {
      const d = fingerprintDiff(entry.renderer, pass.renderers[c.project]);
      if (d.length) { outcome = 'not-comparable'; reason = `renderer differs in ${d.join(',')}`; }
    }
    targets.push(targetRow(c, { ...e, repeat: 0, outcome, reason }));
    if (outcome === 'same') counts.same += 1;
    else if (outcome === 'differs') { counts.differs += 1; differences.push(`visual differs: ${c.id}/${c.project}${e.diff_pixels ? ` (${e.diff_pixels} pixels)` : ''}`); }
    else if (outcome === 'missing') { counts.missing += 1; differences.push(`visual baseline missing: ${c.id}/${c.project}`); }
    else if (outcome === 'not-comparable') { counts.not_comparable += 1; incomplete.push(`visual not comparable: ${c.id}/${c.project} — ${reason}`); }
    else { counts.error += 1; incomplete.push(`visual error: ${c.id}/${c.project} — ${reason ?? 'unknown'}`); }
  }
  const orphans = orphanKeys({ index: verify.index, cases, sources, noDeviceFiles: noDeviceFilesOf(noDevice) });
  counts.orphan = orphans.length;
  for (const o of orphans) differences.push(`visual orphan baseline: ${o}`);
  for (const p of pass.renderer_conflicts) incomplete.push(`renderer differs between workers of ${p}`);
  for (const s of sources) if (s.state === 'failed') incomplete.push(`visual source ${s.name} failed — ${s.reason}`);
  if (!pass.report_valid) incomplete.push('visual report missing or unparseable (compare)');
  if (pass.interrupted) incomplete.push('visual pass interrupted (compare)');
  if (runner.signal) incomplete.push(`visual runner ended by ${runner.signal}`);
  else if (runner.code !== 0 && runner.code !== null && !counts.differs && !counts.error) incomplete.push(`visual runner exit ${runner.code}`);
  if (!production) incomplete.push(...pass.attestation);
  incomplete.push(...incompleteExtra);
  const integrity = [...verify.integrity, ...integrityExtra];
  const outcome = integrity.length || incomplete.length ? 'incomplete' : differences.length ? 'differs' : 'clean';
  return {
    policy: settings.policy, env, action: 'compare', passes: ['compare'], baselines: baselinesRel, index_digest: verify.index_digest,
    tolerance: settings.tolerance, renderers: pass.renderers,
    portability: portability([...new Set(cases.map((c) => c.project))], verify.index, pass.renderers),
    sources: sources.map(({ name, state, count, reason }) => ({ name, state, count, ...(reason ? { reason } : {}) })),
    targets, orphans, no_device: noDevice, counts, differences, incomplete, integrity,
    attestation: production ? pass.attestation : [], guard_red: [...new Set(pass.guard_red)], outcome, build,
  };
}

/**
 * The record block of a `visual update` (capture + stability): per-case stability evaluation,
 * targets of the stability pass, the incomplete-pass reasons, the integrity reasons and the outcome.
 * `{block, evals}`.
 */
export function classifyUpdate({ settings, env, cases, noDevice, sources, passes, actionPasses, hashes, rehashes, storyBuild, verify, integrityExtra = [], production = false, baselinesRel, build, interrupted }) {
  const capture = passes.capture ?? emptyPass('capture', cases);
  const stability = passes.stability ?? null;
  const evals = evaluateUpdate({ cases, capture, stability, hashes, rehashes, storyBuild });
  const renderers = stability?.renderers ?? capture.renderers;
  const incomplete = [];
  for (const e of evals) if (e.kind !== 'stable') incomplete.push(`visual ${e.kind}: ${e.case.id}/${e.case.project} — ${e.reasons.join('; ')}`);
  for (const [name, p] of Object.entries(passes)) {
    if (!p.report_valid) incomplete.push(`visual report missing or unparseable (${name})`);
    for (const proj of p.renderer_conflicts) incomplete.push(`renderer differs between workers of ${proj} (${name})`);
  }
  for (const src of sources) if (src.state === 'failed') incomplete.push(`visual source ${src.name} failed — ${src.reason}`);
  if (interrupted) incomplete.push(interrupted);
  const attestation = Object.values(passes).flatMap((p) => p.attestation);
  const integrity = [...verify.integrity, ...integrityExtra];
  const block = {
    policy: settings.policy, env, action: 'update', passes: actionPasses, baselines: baselinesRel, index_digest: verify.index_digest,
    tolerance: settings.tolerance, renderers, portability: portability([...new Set(cases.map((c) => c.project))], verify.index, renderers),
    build, sources,
    targets: stability ? [...stability.results.values()].flatMap(({ case: c, reps }) => reps.map((e) => targetRow(c, e))) : [],
    orphans: [], no_device: noDevice,
    counts: { stable: evals.filter((e) => e.kind === 'stable').length, unstable: evals.filter((e) => e.kind === 'unstable').length, error: evals.filter((e) => e.kind === 'error').length },
    differences: [], incomplete, integrity, attestation: production ? attestation : [],
    guard_red: [...new Set(Object.values(passes).flatMap((p) => p.guard_red))],
    stability: evals.map((e) => ({ key: e.key, id: e.case.id, project: e.case.project, kind: e.kind, renders: e.renders, differences: e.differences, outcomes: e.outcomes, reasons: e.reasons })),
    outcome: integrity.length || incomplete.length ? 'incomplete' : 'clean',
  };
  return { block, evals };
}

/** The image file of a target id (`route:<id>` → `routes--<id>.png`, `story:<id>` → `storybook--<id>.png`). */
const fileOfTarget = (id) => (id.startsWith('route:') ? `routes--${id.slice(6)}.png` : id.startsWith('story:') ? `storybook--${id.slice(6)}.png` : null);
const noDeviceFilesOf = (noDevice) => noDevice.map((n) => fileOfTarget(n.id)).filter(Boolean);

/** The lane policy over a block: `{red, incomplete, warnings}` — integrity is incomplete under both. */
export function decideVisual({ policy, block }) {
  const diffs = block.differences ?? [];
  const inc = block.incomplete ?? [];
  const integ = block.integrity ?? [];
  if (policy === 'block') return { red: [...diffs], incomplete: [...inc, ...integ], warnings: [] };
  return { red: [], incomplete: [...integ], warnings: [...diffs, ...inc] };
}

export function summaryLine(block) {
  const c = block.counts;
  return `visual: ${block.outcome} — same ${c.same} · differs ${c.differs} · missing ${c.missing} · orphan ${c.orphan} · error ${c.error} · not comparable ${c.not_comparable}`;
}

// ---------------------------------------------------------------------------------------------
// Update: stability evaluation, offer, token, accept

/**
 * Per case of an update: stable only when the capture captured, passed and was attested, the three
 * stability repeats are each `same`, passed and attested, and the candidate bytes did not change.
 */
export function evaluateUpdate({ cases, capture, stability, hashes, rehashes, storyBuild }) {
  return cases.map((c) => {
    const k = keyOf(c);
    const key = imageKey(c);
    const cap = capture.results.get(k)?.reps[0] ?? { outcome: 'error', reason: 'no outcome', ran: false, attested: false };
    const st = stability?.results.get(k)?.reps ?? [];
    const reasons = [];
    let kind = 'stable';
    // `error` only for a render error the evidence states; a report or attestation gap is `unstable`.
    const renderError = (e) => e.outcome === 'error' && e.ran && !e.report_failed;
    if (cap.outcome !== 'captured') { kind = renderError(cap) ? 'error' : 'unstable'; reasons.push(`capture: ${cap.reason ?? cap.outcome}`); }
    else if (!cap.attested) reasons.push(`guard not attested for ${c.id}/${c.project}/capture#0`);
    // A pass whose report is absent or unparseable proves no test passed; a worker split proves no renderer.
    for (const [name, p] of [['capture', capture], ['stability', stability]]) {
      if (!p) continue;
      if (p.results.get(k)?.report_ok === null) reasons.push(`${name}: the report does not show the test passed`);
      if (p.renderer_conflicts.includes(c.project)) reasons.push(`${name}: renderer differs between workers of ${c.project}`);
    }
    if (!hashes[key]) reasons.push('no candidate file');
    const outcomes = st.map((e) => e.outcome);
    const differences = st.filter((e) => e.outcome !== 'same').length;
    if (st.length !== VISUAL_REPEAT.stability) reasons.push('stability pass did not run');
    for (const e of st) {
      if (renderError(e) && kind === 'stable') { kind = 'error'; reasons.push(`stability #${e.repeat}: ${e.reason}`); }
      else if (e.outcome !== 'same') reasons.push(`stability #${e.repeat}: ${e.outcome === 'error' ? e.reason : e.outcome}`);
      else if (!e.attested) reasons.push(`guard not attested for ${c.id}/${c.project}/stability#${e.repeat}`);
    }
    if (hashes[key] && rehashes && rehashes[key] !== hashes[key]) reasons.push('candidate changed after capture');
    if (c.source === 'storybook' && storyBuild && !storyBuild.ok) reasons.push(`storybook build not established (${storyBuild.reason})`);
    if (reasons.length && kind === 'stable') kind = 'unstable';
    return { key, case: c, kind, reasons, renders: st.length, differences, outcomes, sha256: hashes[key] ?? null, masked_ratio: cap.masked_ratio ?? null };
  });
}

/** sha256 of every case's candidate file (null when absent). */
export function hashCandidates(dir, cases) {
  const out = {};
  for (const c of cases) {
    const key = imageKey(c);
    try { out[key] = sha256(fs.readFileSync(path.join(dir, c.project, c.file))); } catch { out[key] = null; }
  }
  return out;
}

const destOf = (root, settings, env) => nearestReal(path.resolve(root, settings.baselines, env));
const offerDigest = ({ run_id, env, entries, next_index, tree, dest, candidate_sha256s }) => digestJson({ run_id, env, entries, next_index, tree, dest, candidate_sha256s });

/**
 * The offer of a `visual update`: one entry per image (`new | changed | unchanged | remove | unstable
 * | error`), the index the acceptance would write, and the digest the acceptance token binds.
 */
export function buildOffer({ root, settings, env, runId, evals, verify, treeBefore, candidatesDir, sources, cases, noDevice, renderers, build }) {
  const rel = (abs) => posix(path.relative(root, abs));
  const envDir = path.resolve(root, settings.baselines, env);
  const old = isObject(verify.index?.images) ? verify.index.images : {};
  const images = { ...old };
  const entries = [];
  const candidates = {};
  const candidateSha = {};
  for (const e of evals) {
    if (e.kind !== 'stable') { entries.push({ kind: e.kind, key: e.key, reason: e.reasons.join('; ') }); continue; }
    const cand = path.join(candidatesDir, e.case.project, e.case.file);
    const prev = old[e.key];
    const renderer = renderers[e.case.project] ?? null;
    // Same pixels on another renderer still rewrite the index entry: compare checks the entry's renderer.
    const samePixels = prev && prev.sha256 === e.sha256;
    const kind = prev ? (samePixels && canonicalJson(prev.renderer ?? null) === canonicalJson(renderer) ? 'unchanged' : 'changed') : 'new';
    const entry = { kind, key: e.key, candidate: rel(cand) };
    if (prev) entry.baseline = rel(path.join(envDir, ...e.key.split('/')));
    if (kind === 'changed' && samePixels) entry.reason = 'same pixels, renderer changed';
    entries.push(entry);
    if (kind === 'unchanged') continue;
    candidates[e.key] = cand;
    candidateSha[e.key] = e.sha256;
    images[e.key] = {
      project: e.case.project, sha256: e.sha256, run_id: runId, build_sha: build.before,
      stability: { renders: e.renders, differences: e.differences, build_before: build.before, build_after: build.after },
      masked_ratio: e.masked_ratio, renderer,
    };
  }
  for (const k of orphanKeys({ index: verify.index, cases, sources, noDeviceFiles: noDeviceFilesOf(noDevice) })) {
    entries.push({ kind: 'remove', key: k, baseline: rel(path.join(envDir, ...k.split('/'))) });
    delete images[k];
  }
  const next_index = { schema: 1, env, tolerance: { ...settings.tolerance }, renderers: { ...(isObject(verify.index?.renderers) ? verify.index.renderers : {}), ...renderers }, images };
  const offer = { run_id: runId, env, entries, next_index, tree: treeBefore, dest: destOf(root, settings, env), candidate_sha256s: candidateSha, candidates };
  return { ...offer, digest: offerDigest(offer), writes: entries.filter((x) => ['new', 'changed', 'remove'].includes(x.kind)).length };
}

export function offerLine(e) {
  return `visual offer: ${e.kind} ${e.key}${e.candidate ? ` candidate ${e.candidate}` : ''}${e.baseline ? ` baseline ${e.baseline}` : ''}${e.reason ? ` — ${e.reason}` : ''}`;
}

const tokenFile = (runsDir, env) => path.join(runsDir, '.confirm', `visual-${env}.json`);

/** A single-use acceptance token bound to the run and the offer digest (30 minutes). */
export function issueAcceptToken(runsDir, env, runId, digest) {
  fs.mkdirSync(path.join(runsDir, '.confirm'), { recursive: true });
  const token = randomBytes(16).toString('hex');
  fs.writeFileSync(tokenFile(runsDir, env), `${JSON.stringify({ token, run_id: runId, digest, expires: new Date(Date.now() + ACCEPT_TTL_MS).toISOString() })}\n`);
  return token;
}

/** null when the token is valid (and consumes it), else the reason it is not. */
export function consumeAcceptToken(runsDir, env, runId, token, digest) {
  const file = tokenFile(runsDir, env);
  let saved;
  try { saved = JSON.parse(fs.readFileSync(file, 'utf8')); } catch { return 'no pending acceptance for this environment (used, or never issued)'; }
  if (saved.token !== token) return 'token does not match the pending acceptance';
  if (saved.run_id !== runId) return 'the offer is for another run';
  if (saved.digest !== digest) { fs.rmSync(file, { force: true }); return 'the candidates or the baselines changed since the offer'; }
  if (!(Date.parse(saved.expires) > Date.now())) { fs.rmSync(file, { force: true }); return 'the acceptance expired'; }
  fs.rmSync(file, { force: true });
  return null;
}

/**
 * Write the offered baselines: verify the token against a recomputed offer digest, stage the next
 * tree beside `<env>`, verify it byte by byte against the offered index, then swap by two renames.
 * Pure file work — no request, no render. The caller holds the checkout lock. `{exit, message}`.
 */
export async function acceptOffer({ root, settings, runId, token, runsDir, afterVerify }) {
  let offer;
  try { offer = JSON.parse(fs.readFileSync(path.join(runsDir, runId, 'visual', 'offer.json'), 'utf8')); } catch { return { exit: 3, message: `refused: no offer for run ${runId} — run visual update first` }; }
  const env = offer.env;
  const baseAbs = path.resolve(root, settings.baselines);
  const envDir = path.join(baseAbs, env);
  const pending = interruptedAccepts(baseAbs, env);
  if (pending.length) return { exit: 3, message: `refused: ${pending.join('; ')}` };
  const candidateSha = {};
  for (const [k, p] of Object.entries(offer.candidates ?? {})) { try { candidateSha[k] = sha256(fs.readFileSync(p)); } catch { candidateSha[k] = null; } }
  const digest = offerDigest({ ...offer, tree: treeDigest(envDir), dest: destOf(root, settings, env), candidate_sha256s: candidateSha });
  const why = consumeAcceptToken(runsDir, env, runId, token, digest);
  if (why) return { exit: 3, message: `refused: ${why}` };
  if (afterVerify) afterVerify();
  const stale = { exit: 3, message: 'refused: stale offer — the candidates or the baselines changed during accept' };
  fs.mkdirSync(baseAbs, { recursive: true });
  const staging = path.join(baseAbs, `.${env}.staging-${runId}`);
  const removes = new Set(offer.entries.filter((e) => e.kind === 'remove').map((e) => e.key));
  try {
    fs.mkdirSync(staging);
    for (const f of walk(envDir)) {
      if (f.link) throw new Error('symlink');
      if (f.rel === INDEX_FILE || removes.has(f.rel)) continue;
      fs.mkdirSync(path.dirname(path.join(staging, f.rel)), { recursive: true });
      fs.copyFileSync(f.abs, path.join(staging, f.rel));
    }
    for (const [k, p] of Object.entries(offer.candidates ?? {})) {
      fs.mkdirSync(path.dirname(path.join(staging, k)), { recursive: true });
      fs.copyFileSync(p, path.join(staging, k));
    }
    // Staging is private until the directory rename below publishes it.
    fs.writeFileSync(path.join(staging, INDEX_FILE), `${JSON.stringify(offer.next_index, null, 2)}\n`);
    const staged = walk(staging).filter((f) => f.rel !== INDEX_FILE);
    const want = Object.keys(offer.next_index.images).sort();
    const ok = staged.every((f) => f.file) && canonicalJson(staged.map((f) => f.rel).sort()) === canonicalJson(want)
      && staged.every((f) => sha256(fs.readFileSync(f.abs)) === offer.next_index.images[f.rel].sha256)
      && canonicalJson(JSON.parse(fs.readFileSync(path.join(staging, INDEX_FILE), 'utf8'))) === canonicalJson(offer.next_index)
      && treeDigest(envDir) === offer.tree;
    if (!ok) throw new Error('stale');
  } catch {
    fs.rmSync(staging, { recursive: true, force: true });
    return stale;
  }
  const previous = path.join(baseAbs, `.${env}.previous-${runId}`);
  if (fs.existsSync(envDir)) fs.renameSync(envDir, previous);
  fs.renameSync(staging, envDir);
  fs.rmSync(previous, { recursive: true, force: true });
  const written = offer.entries.filter((e) => e.kind === 'new' || e.kind === 'changed').length;
  return { exit: 0, message: `accepted: ${written} written, ${removes.size} removed — commit with /commit` };
}
