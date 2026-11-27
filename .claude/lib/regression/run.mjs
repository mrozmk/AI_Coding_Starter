// The deterministic regression run: `run` targets one named deployed environment, runs the
// selected cases through the configured runner command and decides the verdict from the runner's
// JSON report and the guard's own log only — no model in the loop. Refuses in a team clone and
// while another run holds the environment or checkout lock; on production it first checks that the
// runner is guard-integrated and asks for a single-use confirmation token bound to the plan.
// `visual compare | update` runs the visual lane on its own (regression.md §13), `run full` adds
// its compare pass after the functional one, `visual accept` is the only writer of baselines.
// `status` prints the newest per-machine record per environment and mode.
// Node builtins only — ships to every downstream. Contract: .agents/reference/regression.md §12–§13.
//
//   node .claude/lib/regression/run.mjs run [smoke|full] [--env <name>] [--confirm <token>] [--root <dir>]
//   node .claude/lib/regression/run.mjs visual compare|update [--env <name>] [--confirm <token>] [--root <dir>]
//   node .claude/lib/regression/run.mjs visual accept --run <run id> --token <token> [--root <dir>]
//   node .claude/lib/regression/run.mjs status [--env <name>] [--json] [--root <dir>]
//   run / visual exit: 0 GREEN · 1 RED · 2 usage / config / invalid catalog / baseline not established /
//             visual not configured / widened tolerance · 3 refused (team clone, lock held, not
//             guard-integrated, confirmation required/invalid, overlapping baselines; `visual update`:
//             acceptance required) · 4 INCOMPLETE · 5 BLOCKED/ENV
//   accept exit: 0 written · 2 usage / config · 3 refused          status exit: 0 (2 on usage)

import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { createHash, randomBytes } from 'node:crypto';
import { spawn, spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { CONFIG_PATH, QA_ENV_PATH, RUNS_DIR, loadConfig, resolveTarget, catalogSettings, isObject, docKey, visualSettings } from './config.mjs';
import { buildPlan, confirmationText, expandTargets, VISUAL_ACTIONS } from './policy.mjs';
import { ownerLock, LockError, createLedger, groupAlive, scenarioId, guardedFetch } from './guard.mjs';
import {
  SOURCES, assertDisjoint, verifyBaselines, treeDigest, readIndex, toleranceCheck, baselinesWatch, readEvidence, readVisualReport,
  classifyPass, classifyVisual, classifyUpdate, emptyPass, decideVisual, summaryLine, portabilityLine, hashCandidates,
  buildOffer, offerLine, issueAcceptToken, acceptOffer,
} from './visual.mjs';

const CONFIRM_TTL_MS = 10 * 60 * 1000;
const SHA_KEYS = ['sha', 'commit', 'commit_sha', 'git_sha', 'build_sha', 'revision'];
const HEX_SHA = /^[0-9a-f]{7,40}$/;
const EXIT = { GREEN: 0, RED: 1, INCOMPLETE: 4, 'BLOCKED/ENV': 5 };
const GUARD_MODULE = /\.claude\/lib\/regression\/guard\.mjs$/;
const VISUAL_SPEC_MODULE = /\.claude\/lib\/regression\/visual-spec\.mjs$/;
// Playwright gives these precedence over the configured report path: never inherited by a runner.
const REPORTER_ENV = ['PLAYWRIGHT_JSON_OUTPUT_FILE', 'PLAYWRIGHT_JSON_OUTPUT_DIR', 'PLAYWRIGHT_JSON_OUTPUT_NAME'];
// Calls that install a route of the spec's own: a page or context route a spec adds is matched
// before the guard's context route, and `continue()` there sends the request unguarded.
const OWN_ROUTE_CALLS = ['.route(', 'routeFromHAR', '.routeWebSocket('];

const h16 = (s) => createHash('sha256').update(s).digest('hex').slice(0, 16);
const now = () => (process.env.REGRESSION_NOW ? new Date(process.env.REGRESSION_NOW) : new Date());
const posix = (p) => p.split(path.sep).join('/');

// ---------------------------------------------------------------------------------------------
// Refusals and inputs

/** A team clone (`.agents/team/team.json` or `session.json`): a run never targets anything from there. */
export function isTeamClone(root) {
  return ['team.json', 'session.json'].some((f) => fs.existsSync(path.join(root, '.agents/team', f)));
}

/** The SHA a build endpoint reports (a plain 7–40 hex body, or one JSON field of SHA_KEYS), or null. */
export function parseBuildSha(text) {
  if (typeof text !== 'string') return null;
  const body = text.trim();
  if (HEX_SHA.test(body)) return body;
  let doc;
  try { doc = JSON.parse(body); } catch { return null; }
  if (!isObject(doc)) return null;
  const found = [...new Set(SHA_KEYS.map((k) => doc[k]).filter((v) => typeof v === 'string' && HEX_SHA.test(v)))];
  return found.length === 1 ? found[0] : null;
}

/** `{sha, source, reason}` — the deployed build, read from the environment's build_sha_url. */
export async function fetchBuildSha(root, cfg, envName, policy) {
  let url = policy.build_sha_url;
  if (!url && cfg.environments?.[envName]?.host === 'qa-env') {
    try { url = JSON.parse(fs.readFileSync(path.resolve(root, QA_ENV_PATH), 'utf8'))?.build_sha_url ?? null; } catch { url = null; }
  }
  if (!url) return { sha: null, source: null, reason: 'no build_sha_url' };
  try {
    const r = await fetch(url, { signal: AbortSignal.timeout(10000), redirect: 'follow' });
    if (!r.ok) return { sha: null, source: url, reason: `build_sha_url answered ${r.status}` };
    const sha = parseBuildSha(await r.text());
    return sha ? { sha, source: url, reason: null } : { sha: null, source: url, reason: 'build_sha_url returned no recognisable SHA' };
  } catch (err) {
    return { sha: null, source: url, reason: `build_sha_url unreachable (${err.name === 'TimeoutError' ? 'timeout' : err.code ?? err.message})` };
  }
}

/**
 * The text with `//` and `/* *\/` comments removed, string literals kept whole: a `/*` inside a
 * string such as a route glob `'**\/*.png'` opens no comment. A backslash outside a string escapes
 * the next character (a regex literal's `\/\/` is no comment).
 */
function stripComments(s) {
  let out = '';
  for (let i = 0; i < s.length; i += 1) {
    const c = s[i];
    if (c === '\\') { out += s.slice(i, i + 2); i += 1; continue; }
    if (c === "'" || c === '"' || c === '`') {
      let j = i + 1;
      while (j < s.length && s[j] !== c && !(c !== '`' && s[j] === '\n')) j += s[j] === '\\' ? 2 : 1;
      out += s.slice(i, j + 1);
      i = j;
      continue;
    }
    if (c === '/' && s[i + 1] === '/') { while (i < s.length && s[i] !== '\n') i += 1; out += '\n'; continue; }
    if (c === '/' && s[i + 1] === '*') {
      const end = s.indexOf('*/', i + 2);
      out += s.slice(i, end < 0 ? s.length : end + 2).replace(/[^\n]/g, '');
      i = end < 0 ? s.length : end + 1;
      continue;
    }
    out += c;
  }
  return out;
}

/** The text minus whole-line `//` comments only: a forbidden key is searched fail-closed (a mention elsewhere refuses). */
const dropCommentLines = (s) => s.split('\n').filter((l) => !/^\s*\/\//.test(l)).join('\n');

/** Import statements of a module: `[{bindings: [names], from}]` (named imports, comments stripped). */
function importsOf(text) {
  const out = [];
  const re = /^\s*import\s+([^;]*?)\s+from\s+['"]([^'"]+)['"]/gm;
  let m;
  while ((m = re.exec(stripComments(text)))) {
    const named = /\{([^}]*)\}/.exec(m[1]);
    const bindings = named ? named[1].split(',').map((b) => b.trim().split(/\s+as\s+/)[0].trim()).filter(Boolean) : [];
    out.push({ bindings, from: m[2] });
  }
  return out;
}

function resolveModule(fromFile, spec) {
  const base = path.resolve(path.dirname(fromFile), spec);
  for (const c of [base, `${base}.ts`, `${base}.js`, `${base}.mjs`, path.join(base, 'index.ts')]) {
    if (fs.existsSync(c) && fs.statSync(c).isFile()) return c;
  }
  return null;
}

const moduleLabel = (re) => re.source.replace(/\\/g, '').replace(/\$$/, '');

/**
 * One runner's pre-flight: the config imports every `configNeeds` binding from its module, every
 * spec imports `test` from a relative fixture module that imports `installGuard` from guard.mjs,
 * none of them sets context defaults the private redirect transport would re-add, and no spec or
 * fixture module installs a route of its own (a page route takes precedence over the guard's
 * context route). Returns findings `[{file, reason}]` (empty = integrated).
 */
export function scanIntegration(root, { configFile: configRel, configNeeds, specs }) {
  const findings = [];
  const rel = (f) => posix(path.relative(root, f));
  const read = (f) => { try { return fs.readFileSync(f, 'utf8'); } catch { return null; } };
  const scanned = []; // [file, text, routesChecked]
  const configFile = path.resolve(root, configRel);
  const configText = read(configFile);
  if (configText === null) findings.push({ file: configRel, reason: 'runner config absent' });
  else {
    scanned.push([configFile, configText, false]);
    const imports = importsOf(configText);
    for (const need of configNeeds) {
      if (!imports.some((i) => need.module.test(i.from) && i.bindings.includes(need.binding))) findings.push({ file: configRel, reason: `does not import ${need.binding} from ${moduleLabel(need.module)}` });
    }
  }
  const fixtures = new Set();
  for (const spec of [...new Set(specs)]) {
    const file = path.resolve(root, spec);
    const text = read(file);
    if (text === null) { findings.push({ file: spec, reason: 'spec file absent' }); continue; }
    scanned.push([file, text, true]);
    const testImport = importsOf(text).find((i) => i.bindings.includes('test'));
    if (!testImport) { findings.push({ file: spec, reason: 'imports no test' }); continue; }
    if (!testImport.from.startsWith('.')) { findings.push({ file: spec, reason: `imports test from ${testImport.from}, not from the guarded fixtures` }); continue; }
    const mod = resolveModule(file, testImport.from);
    if (!mod) { findings.push({ file: spec, reason: `fixture module ${testImport.from} not found` }); continue; }
    if (fixtures.has(mod)) continue;
    fixtures.add(mod);
    const modText = read(mod);
    scanned.push([mod, modText, true]);
    const ok = importsOf(modText).some((i) => GUARD_MODULE.test(i.from) && i.bindings.includes('installGuard'));
    if (!ok) findings.push({ file: rel(mod), reason: 'does not import installGuard from .claude/lib/regression/guard.mjs' });
  }
  for (const [file, text, routesChecked] of scanned) {
    const code = dropCommentLines(text);
    for (const key of ['extraHTTPHeaders', 'httpCredentials']) if (code.includes(key)) findings.push({ file: rel(file), reason: `sets ${key}` });
    if (!routesChecked) continue;
    // A literal call only: a route installed through a helper or a computed call is not seen (regression.md §11).
    for (const call of OWN_ROUTE_CALLS) if (code.includes(call)) findings.push({ file: rel(file), reason: `installs its own route (${call}) — it would take precedence over the guard` });
  }
  return findings;
}

/** The production pre-flight of a plan: the functional runner (not in a visual-only plan) and the visual one. */
export function checkIntegration(root, cfg, plan) {
  const findings = [];
  if (plan.mode !== 'visual') {
    findings.push(...scanIntegration(root, { configFile: cfg.runner.config, configNeeds: [{ module: GUARD_MODULE, binding: 'runnerOptions' }], specs: plan.cases.map((c) => c.spec) }));
  }
  if (plan.visual) findings.push(...visualIntegration(root, cfg));
  return findings;
}

/** The static scan of the visual config and spec (the pre-flight and `setup check` share it). */
export function visualIntegration(root, cfg) {
  const s = visualSettings(cfg);
  return scanIntegration(root, {
    configFile: s.config,
    configNeeds: [{ module: GUARD_MODULE, binding: 'runnerOptions' }, { module: VISUAL_SPEC_MODULE, binding: 'visualOptions' }],
    specs: [s.spec],
  });
}

// ---------------------------------------------------------------------------------------------
// Confirmation token (production)

function ensureRunsDir(root) {
  const dir = path.resolve(root, RUNS_DIR);
  fs.mkdirSync(dir, { recursive: true });
  const ignore = path.join(dir, '.gitignore');
  if (!fs.existsSync(ignore)) fs.writeFileSync(ignore, '*\n');
  return dir;
}

function issueToken(root, plan) {
  const dir = path.join(ensureRunsDir(root), '.confirm');
  fs.mkdirSync(dir, { recursive: true });
  const token = randomBytes(16).toString('hex');
  fs.writeFileSync(path.join(dir, `${plan.env}.json`), `${JSON.stringify({ token, digest: plan.digests.plan, expires: new Date(Date.now() + CONFIRM_TTL_MS).toISOString() })}\n`);
  return token;
}

/** null when the token is valid (and consumes it), else the reason it is not. */
function consumeToken(root, plan, token) {
  const file = path.resolve(root, RUNS_DIR, '.confirm', `${plan.env}.json`);
  let saved;
  try { saved = JSON.parse(fs.readFileSync(file, 'utf8')); } catch { return 'no pending confirmation for this environment (used, or never issued)'; }
  if (saved.token !== token) return 'token does not match the pending confirmation';
  if (saved.digest !== plan.digests.plan) { fs.rmSync(file, { force: true }); return 'the plan changed since the confirmation (config, catalog, mode, cases or budget)'; }
  if (!(Date.parse(saved.expires) > Date.now())) { fs.rmSync(file, { force: true }); return 'the confirmation expired'; }
  fs.rmSync(file, { force: true });
  return null;
}

// ---------------------------------------------------------------------------------------------
// Locks

export const lockDir = () => process.env.REGRESSION_LOCK_DIR || path.join(os.homedir(), '.agent-ops/locks/regression');

/** `{lock, name}` held, or `{error}` naming the holder. Reclaims a dead owner with a printed line. */
export function acquireLock(name, owner) {
  const base = lockDir();
  fs.mkdirSync(base, { recursive: true });
  const lock = ownerLock(path.join(base, name), { ...owner });
  let r;
  try { r = lock.acquire(); } catch (err) {
    if (err instanceof LockError) return { error: `${err.message} — remove it by hand once you are sure no run is active` };
    throw err;
  }
  if (r.ok) {
    if (r.reclaimed) console.log(`lock: reclaimed ${name} from dead pid ${r.reclaimed.pid} (run ${r.reclaimed.run_id ?? '?'})`);
    return { lock, name };
  }
  if (r.unreadable) return { error: `lock ${name} has an unreadable owner — inspect ${path.join(base, name)}` };
  return { error: `lock ${name} held by pid ${r.holder.pid} (run ${r.holder.run_id ?? '?'})` };
}

async function waitGroupEnd(pgid, ms = 30000) {
  const end = Date.now() + ms;
  while (groupAlive(pgid) && Date.now() < end) await new Promise((r) => setTimeout(r, 100));
  if (groupAlive(pgid)) { try { process.kill(-pgid, 'SIGKILL'); } catch { /* gone */ } }
}

// ---------------------------------------------------------------------------------------------
// Report mapping and verdict

function repoRel(root, abs) {
  const candidates = [root];
  try { candidates.push(fs.realpathSync(root)); } catch { /* keep root */ }
  for (const r of candidates) {
    const rel = path.relative(r, abs);
    if (!rel.startsWith('..') && !path.isAbsolute(rel)) return posix(rel);
  }
  return posix(abs);
}

/**
 * Map a Playwright JSON report onto the plan. A case is (id, project, spec file): a result with
 * a selected id from another file is outside the selection and the declared case stays missing.
 */
export function classifyReport(report, plan, { idPattern, catalogIds, root, configDir }) {
  const valid = isObject(report) && Array.isArray(report.suites);
  const out = { valid, report_errors: valid && Array.isArray(report.errors) ? report.errors.length : 0, cases: [], orphans: [], outside_selection: [], interrupted: false, executed: [], runner_version: valid && typeof report.config?.version === 'string' ? report.config.version : null };
  let idRe;
  try { idRe = new RegExp(idPattern); } catch { idRe = /$^/; }
  const rootDir = valid && typeof report.config?.rootDir === 'string' ? path.resolve(root, report.config.rootDir) : configDir;
  const selected = new Map(plan.cases.map((c) => [`${c.id}\0${c.project}\0${c.spec}`, c]));
  const found = new Map();
  const visit = (suite, inheritedFile) => {
    const file = suite.file ?? inheritedFile;
    for (const spec of suite.specs ?? []) {
      const specFile = spec.file ?? file;
      const fileRel = specFile ? repoRel(root, path.resolve(rootDir, specFile)) : null;
      const title = String(spec.title ?? '');
      const id = scenarioId(title);
      for (const t of spec.tests ?? []) {
        const project = t.projectName ?? '';
        if ((t.results ?? []).some((r) => r.status === 'interrupted')) out.interrupted = true;
        if (!id || !idRe.test(id) || !catalogIds.has(id)) { out.orphans.push({ title, project }); continue; }
        const key = `${id}\0${project}\0${fileRel}`;
        if (!selected.has(key)) { out.outside_selection.push({ id, project, file: fileRel }); continue; }
        found.set(key, [...(found.get(key) ?? []), t]);
      }
    }
    for (const s of suite.suites ?? []) visit(s, file);
  };
  if (valid) for (const s of report.suites) visit(s, null);
  for (const [key, c] of selected) {
    const tests = found.get(key) ?? [];
    let result;
    let duration = 0;
    if (!tests.length) result = 'missing';
    else if (tests.length > 1) result = 'duplicated';
    else {
      const t = tests[0];
      const results = t.results ?? [];
      duration = results.reduce((s, r) => s + (Number(r.duration) || 0), 0);
      const last = results[results.length - 1];
      // Playwright marks a skipped test `expectedStatus: 'skipped'` too: skipped is judged first.
      if (results.some((r) => r.status === 'interrupted')) result = 'interrupted';
      else if (t.status === 'skipped' || !results.length || last.status === 'skipped') result = 'skipped';
      else if (t.expectedStatus !== undefined && t.expectedStatus !== 'passed') result = 'invalid';
      else if (t.status === 'flaky') result = 'flaky';
      else if (last.status === 'passed') result = 'passed';
      else if (last.status === 'failed' || last.status === 'timedOut') result = 'failed';
      else result = 'invalid';
    }
    if (result !== 'missing') out.executed.push({ id: c.id, project: c.project });
    out.cases.push({ id: c.id, project: c.project, spec: c.spec, result, duration_ms: duration });
  }
  return out;
}

/**
 * Guard findings from the run's log: `{stop, blocked, attestation[], session[], outsideTest}`.
 * `ran` = the cases whose fixtures ran (a case skipped at declaration never installs the guard).
 */
export function readGuard(runDir, nonce, ran) {
  const ledger = createLedger(runDir, { nonce });
  const events = ledger.events();
  let stop = ledger.stopInfo();
  if (stop && stop.nonce !== undefined && stop.nonce !== nonce) stop = { reason: 'stop marker from another run' };
  const installed = events.filter((e) => e.kind === 'installed');
  const testCase = new Map(installed.map((e) => [e.test, { id: e.id, project: e.project }]));
  const blocked = events.filter((e) => e.kind === 'blocked');
  const attestation = ran.filter((c) => !installed.some((e) => e.id === c.id && e.project === c.project)).map((c) => `guard not attested for ${c.id}/${c.project}`);
  const session = [];
  events.forEach((e, i) => {
    if (e.kind !== 'session-start') return;
    // `session-failed`: the adapter itself failed — the test fails (RED), it is no attestation gap.
    if (!events.slice(i + 1).some((s) => (s.kind === 'session' || s.kind === 'session-failed') && s.account === e.account)) session.push(`session not guard-attested for ${e.account}`);
  });
  const budget = events.filter((e) => e.kind === 'budget').reduce((acc, e) => {
    acc.reserved = Math.max(acc.reserved, e.reserved ?? 0);
    acc.by_op[e.op] = (acc.by_op[e.op] ?? 0) + (e.cost ?? 0);
    return acc;
  }, { reserved: 0, by_op: {} });
  return {
    stop, blocked, testCase, attestation: [...new Set(attestation)], session: [...new Set(session)], budget,
    attested: installed.length > 0, outsideTest: blocked.some((e) => e.test === null || e.test === undefined),
  };
}

/** The cases whose fixtures ran: everything the report holds except a missing or skipped case. */
export const casesRan = (cls) => cls.cases.filter((c) => c.result !== 'missing' && c.result !== 'skipped').map(({ id, project }) => ({ id, project }));

/** A request the guard aborted fails the test it happened in, whatever the report says. */
export function failBlockedCases(cls, guard) {
  for (const e of guard.blocked) {
    const tc = guard.testCase.get(e.test);
    if (!tc) continue;
    for (const c of cls.cases) if (c.id === tc.id && c.project === tc.project && c.result === 'passed') c.result = 'failed';
  }
}

/** Verdict by precedence BLOCKED/ENV > RED > INCOMPLETE > GREEN; GREEN only when every condition holds. */
export function decideVerdict({ kind, cls, guard, runnerExit, signal, plan, build }) {
  const blocked = [];
  const red = [];
  const incomplete = [];
  const warnings = [];
  if (guard.stop) blocked.push(`guard stop: ${guard.stop.reason}`);
  if (kind === 'production') blocked.push(...guard.attestation, ...guard.session);
  else warnings.push(...guard.attestation, ...guard.session);
  const interrupted = Boolean(signal) || cls.interrupted;
  const completed = cls.valid && !interrupted;
  for (const c of cls.cases) {
    if (c.result === 'failed') red.push(`failed: ${c.id}/${c.project}`);
    else if (c.result === 'missing') (completed ? red : incomplete).push(`${completed ? 'missing' : 'not run (run interrupted or no report)'}: ${c.id}/${c.project}`);
    else if (c.result !== 'passed') incomplete.push(`${c.result}: ${c.id}/${c.project}`);
  }
  for (const o of cls.orphans) red.push(`no scenario id: ${o.title} (${o.project})`);
  for (const o of cls.outside_selection) red.push(`outside the selection: ${o.id}/${o.project} (${o.file})`);
  if (guard.outsideTest) red.push('blocked request outside a test');
  // A valid report with nothing executed, or nothing selected, is RED; an absent or invalid report is INCOMPLETE.
  if (!cls.executed.length && (cls.valid || !plan.cases.length)) red.push('zero executed cases');
  if (!cls.valid) incomplete.push('runner report missing, unparseable or invalid');
  if (cls.report_errors) incomplete.push(`report errors: ${cls.report_errors}`);
  if (signal) incomplete.push(`runner ended by ${signal}`);
  else if (runnerExit !== 0 && runnerExit !== null && !red.length) incomplete.push(`runner exit ${runnerExit}`);
  for (const n of plan.no_device) incomplete.push(`no device for ${n.id} (${n.device})`);
  const b = buildProblem(build);
  if (b) incomplete.push(b);
  return combineVerdict({ blocked, red, incomplete, warnings });
}

/** null when the deployed build was read before and after the run and did not change, else the reason. */
function buildProblem({ before, after }) {
  if (!before.sha || !after.sha) return `deployed build unknown (${before.reason ?? after.reason})`;
  if (before.sha !== after.sha) return `build changed during the run (${before.sha} → ${after.sha})`;
  return null;
}

/** The verdict of reason lists by precedence BLOCKED/ENV > RED > INCOMPLETE > GREEN (the lists kept as `parts`). */
export function combineVerdict({ blocked, red, incomplete, warnings }) {
  const verdict = blocked.length ? 'BLOCKED/ENV' : red.length ? 'RED' : incomplete.length ? 'INCOMPLETE' : 'GREEN';
  return { verdict, reasons: [...blocked, ...red, ...incomplete], warnings, exit: EXIT[verdict], parts: { blocked, red, incomplete } };
}

/**
 * The guard facts and the lane policy of a visual block over reason lists that already hold the
 * other passes' (§12 first, under both policies: a production attestation gap BLOCKED/ENV, a
 * guard-aborted visual test RED; then `warn` / `block`).
 */
function applyVisual(parts, block, { production }) {
  const out = { blocked: [...parts.blocked], red: [...parts.red], incomplete: [...parts.incomplete], warnings: [...parts.warnings] };
  if (production) out.blocked.push(...block.attestation);
  out.red.push(...block.guard_red);
  const dv = decideVisual({ policy: block.policy, block });
  out.red.push(...dv.red);
  out.incomplete.push(...dv.incomplete);
  out.warnings.push(...dv.warnings);
  return out;
}

// ---------------------------------------------------------------------------------------------
// run

function newRunDir(root, envName) {
  const runs = ensureRunsDir(root);
  const stamp = now().toISOString().replace(/[-:]/g, '').replace(/\.\d+Z$/, 'Z');
  for (;;) {
    const runId = `${envName}-${stamp}-${randomBytes(2).toString('hex')}`;
    const dir = path.join(runs, runId);
    try { fs.mkdirSync(dir); return { runId, dir }; } catch (err) { if (err.code !== 'EEXIST') throw err; }
  }
}

function headSha(root) {
  const r = spawnSync('git', ['-C', root, 'rev-parse', 'HEAD'], { encoding: 'utf8' });
  return r.status === 0 ? r.stdout.trim() : null;
}

function runRunner(root, command, env, locks) {
  return new Promise((resolve) => {
    const child = spawn('sh', ['-c', command], { cwd: root, stdio: 'inherit', detached: true, env });
    const pgid = child.pid;
    for (const l of locks) { try { l.update({ pgid }); } catch { /* lock still held by token */ } }
    let signalled = null;
    const forward = (sig) => { signalled = sig; try { process.kill(-pgid, 'SIGTERM'); } catch { /* gone */ } };
    const onInt = () => forward('SIGINT');
    const onTerm = () => forward('SIGTERM');
    process.on('SIGINT', onInt);
    process.on('SIGTERM', onTerm);
    child.on('error', () => {});
    child.on('close', async (code, signal) => {
      await waitGroupEnd(pgid);
      process.off('SIGINT', onInt);
      process.off('SIGTERM', onTerm);
      resolve({ code, signal: signal ?? signalled });
    });
  });
}

/** The runner's environment: inherited minus Playwright's reporter output overrides, plus the run's. */
function runnerEnv(extra) {
  const env = { ...process.env };
  for (const k of REPORTER_ENV) delete env[k];
  return { ...env, ...extra };
}

/** One runner launch: manifest written, the old report deleted, the runner run, the report read. */
async function runPass({ root, plan, manifest, manifestFile, command, reportFile, locks }) {
  fs.mkdirSync(path.dirname(manifestFile), { recursive: true });
  fs.writeFileSync(manifestFile, `${JSON.stringify(manifest, null, 2)}\n`);
  fs.rmSync(reportFile, { force: true });
  const runner = await runRunner(root, command, runnerEnv({
    REGRESSION_RUN: manifestFile, REGRESSION_ENV: plan.env, REGRESSION_ENV_KIND: plan.kind, REGRESSION_BASE_URL: plan.base_url,
  }), locks);
  let report = null;
  try { report = JSON.parse(fs.readFileSync(reportFile, 'utf8')); } catch { report = null; }
  return { runner, report };
}

function printPlanSummary(plan) {
  console.log(`target: ${plan.env} (${plan.kind}) ${plan.base_url} · mode ${plan.mode} · ${plan.cases.length} cases (${plan.scenarios} scenarios)`);
  for (const e of plan.excluded) console.log(`not run — policy: ${e.id} — ${e.reason}`);
  for (const n of plan.no_device) console.log(`not run — no device: ${n.id} (${n.device})`);
  if (plan.visual) {
    console.log(`visual: ${plan.visual.action} · ${plan.visual.cases.length} route cases${plan.visual.storybook ? ' · stories enumerated at run time' : ''} · policy ${plan.visual.policy}`);
    for (const n of plan.visual.no_device) console.log(`not run — no device: ${n.id} (${n.device})`);
  }
}

/**
 * Production, before any lock or traffic: refuse a runner that is not guard-integrated, then the
 * two-phase confirmation. `{confirmed: true}` to go on, `{exit: 3}` to stop (a fresh token printed).
 */
function confirmProduction(root, plan, findings, token) {
  if (findings.length) {
    for (const f of findings) console.error(`runner not guard-integrated — ${f.file}: ${f.reason} — re-copy the templates (regression.md §11)`);
    return { exit: 3 };
  }
  const why = token ? consumeToken(root, plan, token) : null;
  if (token && !why) return { confirmed: true };
  if (why) console.error(`confirmation invalid: ${why}`);
  else printPlanSummary(plan);
  console.log(confirmationText(plan));
  console.log(`confirmation-required: ${issueToken(root, plan)}`);
  return { exit: 3 };
}

/** The run record (regression.md §12): digests, devices, results and guard facts — never model output. */
function buildRecord({ root, plan, runId, startedAt, command, confirmed, build, runner, cls, guard, v, visual = null }) {
  const count = (r) => cls.cases.filter((c) => c.result === r).length;
  return {
    schema: 1, run_id: runId, env: plan.env, kind: plan.kind, base_url: plan.base_url, mode: plan.mode,
    started_at: startedAt, ended_at: new Date().toISOString(), head_sha: headSha(root),
    build_sha: build.before.sha, build_sha_after: build.after.sha, build_sha_source: build.before.source,
    runner_exit: runner.code, runner_signal: runner.signal ?? null, report_errors: cls.report_errors,
    digests: plan.digests, devices: [...new Set(plan.cases.map((c) => c.project))], command,
    versions: { node: process.version, runner: cls.runner_version }, confirmed,
    cases: cls.cases.map(({ id, project, result, duration_ms }) => ({ id, project, result, duration_ms })),
    orphans: cls.orphans, outside_selection: cls.outside_selection,
    not_run_policy: plan.excluded, no_device: plan.no_device,
    guard: {
      attested: guard.attested,
      blocked: guard.blocked.map(({ reason, method, url, op, test }) => ({ reason, method, url, op, test: test ?? null })),
      budget: { ceiling: plan.budget.ceiling, reserved: guard.budget.reserved, by_op: guard.budget.by_op },
      stop: guard.stop ? { reason: guard.stop.reason, url: guard.stop.url ?? null } : null,
    },
    counts: {
      selected: plan.cases.length, executed: cls.executed.length, passed: count('passed'), failed: count('failed'),
      skipped: count('skipped'), flaky: count('flaky'), duplicated: count('duplicated'), interrupted: count('interrupted'),
      missing: count('missing'), invalid: count('invalid'), orphans: cls.orphans.length, outside_selection: cls.outside_selection.length,
      not_run_policy: plan.excluded.length, no_device: plan.no_device.length, ...plan.counted,
    },
    consent: plan.policy.consent.cookies.length ? plan.policy.consent.strategy : 'not applied',
    visual,
    verdict: v.verdict, reasons: v.reasons, warnings: v.warnings, exit: v.exit,
  };
}

// ---------------------------------------------------------------------------------------------
// Visual passes (regression.md §13)

const EMPTY_CLS = { valid: true, report_errors: 0, cases: [], orphans: [], outside_selection: [], interrupted: false, executed: [], runner_version: null };

/** The Storybook build behind story targets: `{sha, reason}`, read through the guard. */
async function readStoryBuild(manifest, url) {
  if (!url) return { sha: null, reason: 'no build_sha_url' };
  try {
    const r = await guardedFetch(manifest, { url });
    if (!(r.status >= 200 && r.status <= 299)) return { sha: null, reason: `build_sha_url answered ${r.status}` };
    const sha = parseBuildSha(r.text());
    return sha ? { sha, reason: null } : { sha: null, reason: 'build_sha_url returned no recognisable SHA' };
  } catch (err) { return { sha: null, reason: `build_sha_url unreachable (${err.message})` }; }
}

/**
 * The visual passes of one run, inside the caller's locks and run directory: Storybook enumeration
 * (test environments), then per pass a manifest, a copy of the baselines (compare) or the candidate
 * directory (capture, stability), the runner, the classification. An interrupted runner or report,
 * or a guard stop, ends the sequence. Returns the record block and what an offer needs.
 */
async function runVisualPasses({ root, cfg, plan, dir, nonce, locks, baseManifest, watch, verify }) {
  const s = visualSettings(cfg);
  const v = plan.visual;
  const production = plan.kind === 'production';
  const envDir = path.resolve(root, s.baselines, plan.env);
  const visualDir = path.join(dir, 'visual');
  // The accept transaction binds this environment's tree as it was before any runner of the lane.
  const treeBefore = treeDigest(envDir);
  const targets = [...v.routes];
  const cases = [...v.cases];
  const noDevice = [...v.no_device];
  const sources = [{ name: 'routes', state: 'ok', count: v.routes.length }];
  const build = { storybook_index_before: null, storybook_index_after: null, storybook_before: null, storybook_after: null };
  const sbCfg = v.storybook ? s.storybook[plan.env] : null;
  const sbManifest = { ...baseManifest, mode: 'visual', selection: [] };
  if (sbCfg) {
    const sb = await SOURCES.storybook.enumerate({ cfg, env: plan.env, settings: s, manifest: sbManifest });
    sources.push({ name: 'storybook', state: sb.state, count: sb.targets.length, ...(sb.reason ? { reason: sb.reason } : {}) });
    build.storybook_index_before = sb.index_digest;
    for (const k of sb.skipped) console.log(`visual skipped: story ${k.id} — ${k.reason}`);
    if (sb.state === 'ok') {
      const ex = expandTargets(cfg, sb.targets);
      targets.push(...sb.targets);
      cases.push(...ex.cases);
      noDevice.push(...ex.no_device);
      build.storybook_before = await readStoryBuild(sbManifest, sbCfg.build_sha_url);
    }
  }
  const capDir = path.join(visualDir, 'capture', 'candidates');
  const reportFile = path.resolve(root, s.report);
  const passes = {};
  const runners = {};
  let interrupted = null;
  let hashes = {};
  let rehashes = null;
  for (const pass of v.passes) {
    const pdir = path.join(visualDir, pass);
    fs.mkdirSync(pdir, { recursive: true });
    let snapshot = capDir;
    if (pass === 'compare') {
      snapshot = path.join(pdir, 'expected');
      // Never through a symlinked `<env>` (verifyBaselines reports it): another environment's images.
      if (fs.existsSync(envDir) && fs.lstatSync(envDir).isDirectory()) fs.cpSync(envDir, snapshot, { recursive: true });
      else fs.mkdirSync(snapshot, { recursive: true });
    } else fs.mkdirSync(capDir, { recursive: true });
    const manifest = {
      ...baseManifest, mode: 'visual',
      selection: cases.map(({ id, title, project, file, source }) => ({ id, title, project, spec: s.spec, file, source })),
      visual: {
        pass, repeat_each: v.repeat[pass], targets, tolerance: s.tolerance, mask: s.mask, max_mask_ratio: s.max_mask_ratio, timezone: s.timezone,
        policy: s.policy, snapshot_dir: snapshot, output_dir: path.join(pdir, 'output'),
        config_dir: path.dirname(path.resolve(root, s.config)), spec_abs: path.resolve(root, s.spec),
        ...(pass === 'stability' ? { candidate_sha256: hashes } : {}),
      },
    };
    const r = await runPass({ root, plan, manifest, manifestFile: path.join(pdir, 'manifest.json'), command: s.command, reportFile, locks });
    runners[pass] = r.runner;
    watch.check(pass);
    passes[pass] = classifyPass({
      pass, cases, repeat: v.repeat[pass], evidence: readEvidence(dir, nonce), report: readVisualReport(reportFile), events: createLedger(dir, { nonce }).events(),
    });
    if (pass === 'capture') hashes = hashCandidates(capDir, cases);
    if (pass === 'stability') rehashes = hashCandidates(capDir, cases);
    if (r.runner.signal) interrupted = `visual runner ended by ${r.runner.signal} (${pass})`;
    else if (passes[pass].interrupted) interrupted = `visual pass interrupted (${pass})`;
    else if (fs.existsSync(path.join(dir, 'stop.json'))) interrupted = `guard stop during the ${pass} pass`;
    if (interrupted) break;
  }
  if (sbCfg && sources.find((x) => x.name === 'storybook')?.state === 'ok') {
    const again = await SOURCES.storybook.enumerate({ cfg, env: plan.env, settings: s, manifest: sbManifest });
    build.storybook_index_after = again.index_digest;
    build.storybook_after = await readStoryBuild(sbManifest, sbCfg.build_sha_url);
  }
  const storyBuild = !sbCfg ? { ok: true }
    : !build.storybook_before?.sha || !build.storybook_after?.sha ? { ok: false, reason: build.storybook_before?.reason ?? build.storybook_after?.reason ?? 'no build_sha_url' }
      : build.storybook_before.sha !== build.storybook_after.sha ? { ok: false, reason: `storybook build changed (${build.storybook_before.sha} → ${build.storybook_after.sha})` } : { ok: true };
  const baselinesRel = posix(path.relative(root, envDir));
  const integrityExtra = watch.changed ? [watch.changed] : [];
  if (v.action === 'compare') {
    const pass = passes.compare ?? emptyPass('compare', cases);
    const incompleteExtra = interrupted ? [interrupted] : [];
    if (sbCfg && build.storybook_index_before && build.storybook_index_after && build.storybook_index_before !== build.storybook_index_after) incompleteExtra.push('storybook index changed during the run');
    const block = classifyVisual({ settings: s, env: plan.env, cases, noDevice, sources, pass, verify, runner: runners.compare ?? { code: null, signal: null }, integrityExtra, incompleteExtra, production, baselinesRel, build });
    return { block, runners };
  }
  const { block, evals } = classifyUpdate({
    settings: s, env: plan.env, cases, noDevice, sources, passes, actionPasses: v.passes, hashes, rehashes, storyBuild, verify, integrityExtra, production, baselinesRel, build, interrupted,
  });
  return { block, runners, evals, cases, noDevice, sources, renderers: block.renderers, interrupted, capDir, treeBefore };
}

function printVisual(block) {
  if (block.action === 'compare') console.log(summaryLine(block));
  else console.log(`visual: update ${block.outcome} — stable ${block.counts.stable} · unstable ${block.counts.unstable} · error ${block.counts.error}`);
  for (const p of block.portability) console.log(portabilityLine(p));
}

/**
 * The refusals every run and visual command shares (regression.md §12 step 1): `{cfg}` or `{exit}`.
 * A team clone is refused before anything else is read from the run's inputs.
 */
function loadForRun(root) {
  const loaded = loadConfig(root);
  if (!loaded.adopted) { console.error('regression not adopted'); return { exit: 2 }; }
  if (loaded.errors.length) {
    for (const e of loaded.errors) console.error(`run: ${CONFIG_PATH}: ${e}`);
    return { exit: 2 };
  }
  const cfg = loaded.config;
  if (!isObject(cfg.runner) || !isObject(cfg.environments)) { console.error('baseline not established — run /setup:regression baseline'); return { exit: 2 }; }
  if (isTeamClone(root)) { console.error('refused: a team clone never runs regression (run from your own checkout)'); return { exit: 3 }; }
  return { cfg };
}

/** Target, plan, disjointness, pre-flight and the production confirmation: `{plan, confirmed}` or `{exit}`. */
function prepareRun(root, cfg, args, mode, visualAction) {
  const target = resolveTarget(cfg, args.env);
  if (target.error) {
    console.error(`run: ${target.error}`);
    console.log(`environments: ${target.names.join(', ') || '(none)'}`);
    return { exit: 2 };
  }
  const plan = buildPlan(root, cfg, target.name, mode, { visualAction });
  if (plan.catalog_errors) {
    for (const e of plan.catalog_errors) console.error(`${e.file}:${e.line}: ${e.message}`);
    console.error('run: the catalog is invalid — refusing to run');
    return { exit: 2 };
  }
  if (plan.error) { console.error(`run: ${plan.error}`); return { exit: 2 }; }
  // Before any token, lock, report deletion or runner: a runner must never clean the baselines.
  if (isObject(cfg.visual)) {
    const overlap = assertDisjoint(root, cfg, RUNS_DIR);
    if (overlap) { console.error(`refused: ${overlap}`); return { exit: 3 }; }
  }
  const findings = checkIntegration(root, cfg, plan);
  if (plan.kind === 'production') {
    const c = confirmProduction(root, plan, findings, args.confirm);
    if (c.exit !== undefined) return { exit: c.exit };
    return { plan, confirmed: true };
  }
  for (const f of findings) console.log(`warning: runner not guard-integrated — ${f.file}: ${f.reason}`);
  return { plan, confirmed: false };
}

/** The env and checkout locks of a run: `{locks}` or `{exit}`. */
function takeRunLocks(root, plan) {
  const owner = { pid: process.pid, pgid: null, run_id: `${plan.env}-pending` };
  const envLock = acquireLock(`env-${h16(plan.base_url)}`, owner);
  if (envLock.error) { console.error(`refused: ${envLock.error}`); return { exit: 3 }; }
  const coLock = acquireLock(`checkout-${h16(realRootOf(root))}`, owner);
  if (coLock.error) { envLock.lock.release(); console.error(`refused: ${coLock.error}`); return { exit: 3 }; }
  return { locks: [envLock.lock, coLock.lock] };
}

const realRootOf = (root) => { try { return fs.realpathSync(root); } catch { return root; } };
const releaseAll = (locks) => { for (const l of [...locks].reverse()) { try { l.release(); } catch { /* the lock holds its token */ } } };

/** The visual tolerance rule, under the lock and against the index the run reads: null or the exit. */
function toleranceRefusal(root, cfg, env) {
  const s = visualSettings(cfg);
  const why = toleranceCheck(s, readIndex(path.resolve(root, s.baselines, env)).index);
  if (!why) return null;
  console.error(`run: ${why}`);
  return 2;
}

function baseManifestOf(plan, runId, nonce, dir) {
  return {
    run_id: runId, nonce, env: plan.env, kind: plan.kind, base_url: plan.base_url, mode: plan.mode,
    workers: plan.policy.workers, pacing: plan.policy.pacing, consent: plan.policy.consent,
    selection: plan.cases, policy: plan.policy.guard, run_dir: dir, accounts: [],
  };
}

function printOutcome(root, v, before, after, recordFile) {
  for (const w of v.warnings) console.log(`warning: ${w}`);
  for (const r of v.reasons) console.log(`reason: ${r}`);
  console.log(`build: ${before.sha ?? 'unknown'}${after.sha && after.sha !== before.sha ? ` → ${after.sha}` : ''}`);
  console.log(`verdict: ${v.verdict}`);
  console.log(`record: ${posix(path.relative(root, recordFile))}`);
}

async function cmdRun(args) {
  const root = path.resolve(args.root);
  const pre = loadForRun(root);
  if (pre.exit !== undefined) return pre.exit;
  const { cfg } = pre;
  const prep = prepareRun(root, cfg, args, args.mode);
  if (prep.exit !== undefined) return prep.exit;
  const { plan, confirmed } = prep;
  const taken = takeRunLocks(root, plan);
  if (taken.exit !== undefined) return taken.exit;
  const { locks } = taken;
  try {
    const visualOn = isObject(cfg.visual);
    if (plan.visual) { const t = toleranceRefusal(root, cfg, plan.env); if (t !== null) return t; }
    const { runId, dir } = newRunDir(root, plan.env);
    for (const l of locks) l.update({ run_id: runId });
    const startedAt = new Date().toISOString();
    const nonce = randomBytes(8).toString('hex');
    const command = cfg.runner.commands[plan.mode];
    const reportFile = path.resolve(root, cfg.runner.report);
    const manifestFile = path.join(dir, 'manifest.json');
    const manifest = baseManifestOf(plan, runId, nonce, dir);
    fs.writeFileSync(manifestFile, `${JSON.stringify(manifest, null, 2)}\n`);
    printPlanSummary(plan);
    const watch = visualOn ? baselinesWatch(root, visualSettings(cfg)) : null;

    const before = await fetchBuildSha(root, cfg, plan.env, plan.policy);
    let runner = { code: null, signal: null };
    let report = null;
    if (plan.cases.length) {
      ({ runner, report } = await runPass({ root, plan, manifest, manifestFile, command, reportFile, locks }));
      watch?.check('functional');
    }
    const settings = catalogSettings(cfg);
    const cls = classifyReport(report, plan, { idPattern: settings.id_pattern, catalogIds: new Set(plan.catalog_ids), root, configDir: path.dirname(path.resolve(root, cfg.runner.config)) });
    // A stopped or interrupted functional pass ends the run's sequence: no visual pass after it.
    const stopped = fs.existsSync(path.join(dir, 'stop.json'));
    let visual = null;
    if (plan.visual && !stopped && !runner.signal && !cls.interrupted) {
      const verify = verifyBaselines(root, visualSettings(cfg), plan.env);
      visual = (await runVisualPasses({ root, cfg, plan, dir, nonce, locks, baseManifest: manifest, watch, verify })).block;
    }
    const ranAny = plan.cases.length || visual;
    const after = ranAny ? await fetchBuildSha(root, cfg, plan.env, plan.policy) : before;

    const guard = readGuard(dir, nonce, casesRan(cls));
    failBlockedCases(cls, guard);
    const base = decideVerdict({ kind: plan.kind, cls, guard, runnerExit: runner.code, signal: runner.signal, plan, build: { before, after } });
    let v = base;
    if (visual) v = combineVerdict(applyVisual({ ...base.parts, warnings: base.warnings }, visual, { production: plan.kind === 'production' }));
    else if (watch?.changed) {
      visual = { integrity: [watch.changed] };
      v = combineVerdict({ ...base.parts, incomplete: [...base.parts.incomplete, watch.changed], warnings: base.warnings });
    }
    const record = buildRecord({ root, plan, runId, startedAt, command: plan.cases.length ? command : null, confirmed, build: { before, after }, runner, cls, guard, v, visual });
    const recordFile = path.join(dir, 'record.json');
    fs.writeFileSync(recordFile, `${JSON.stringify(record, null, 2)}\n`);
    if (visual?.action) printVisual(visual);
    printOutcome(root, v, before, after, recordFile);
    if (v.verdict === 'RED') console.log(`next: /regression-tests heal --run ${runId}`);
    return v.exit;
  } finally {
    releaseAll(locks);
  }
}

// ---------------------------------------------------------------------------------------------
// visual compare | update | accept

/** The standalone verdict of a visual record: the guard rules of §12, then the lane policy, then the build. */
function visualVerdict({ plan, guard, block, build }) {
  const production = plan.kind === 'production';
  const parts = { blocked: [], red: [], incomplete: [], warnings: [] };
  if (guard.stop) parts.blocked.push(`guard stop: ${guard.stop.reason}`);
  if (production) parts.blocked.push(...guard.session); else parts.warnings.push(...guard.session);
  if (guard.outsideTest) parts.red.push('blocked request outside a test');
  const out = applyVisual(parts, block, { production });
  if (block.action === 'compare' && block.counts && !(block.counts.same + block.counts.differs)) out.incomplete.push('visual: nothing compared');
  const b = buildProblem(build);
  if (b) out.incomplete.push(b);
  return combineVerdict(out);
}

async function cmdVisual(args) {
  const root = path.resolve(args.root);
  const pre = loadForRun(root);
  if (pre.exit !== undefined) return pre.exit;
  const { cfg } = pre;
  if (!isObject(cfg.visual)) { console.error('run: visual not configured — see .claude/skills/regression/references/visual.md'); return 2; }
  const prep = prepareRun(root, cfg, args, 'visual', args.action);
  if (prep.exit !== undefined) return prep.exit;
  const { plan, confirmed } = prep;
  const taken = takeRunLocks(root, plan);
  if (taken.exit !== undefined) return taken.exit;
  const { locks } = taken;
  try {
    const s = visualSettings(cfg);
    const verify = verifyBaselines(root, s, plan.env);
    const tol = toleranceCheck(s, verify.index);
    if (tol) { console.error(`run: ${tol}`); return 2; }
    const { runId, dir } = newRunDir(root, plan.env);
    for (const l of locks) l.update({ run_id: runId });
    const startedAt = new Date().toISOString();
    const nonce = randomBytes(8).toString('hex');
    const manifest = baseManifestOf(plan, runId, nonce, dir);
    fs.writeFileSync(path.join(dir, 'manifest.json'), `${JSON.stringify(manifest, null, 2)}\n`);
    printPlanSummary(plan);
    const watch = baselinesWatch(root, s);
    const before = await fetchBuildSha(root, cfg, plan.env, plan.policy);
    const res = await runVisualPasses({ root, cfg, plan, dir, nonce, locks, baseManifest: manifest, watch, verify });
    const after = await fetchBuildSha(root, cfg, plan.env, plan.policy);
    const guard = readGuard(dir, nonce, []);
    const v = visualVerdict({ plan, guard, block: res.block, build: { before, after } });
    const runner = res.runners[plan.visual.passes.at(-1)] ?? Object.values(res.runners).at(-1) ?? { code: null, signal: null };
    const record = buildRecord({ root, plan, runId, startedAt, command: s.command, confirmed, build: { before, after }, runner, cls: EMPTY_CLS, guard, v, visual: res.block });
    const recordFile = path.join(dir, 'record.json');
    fs.writeFileSync(recordFile, `${JSON.stringify(record, null, 2)}\n`);
    printVisual(res.block);
    printOutcome(root, v, before, after, recordFile);
    if (plan.visual.action !== 'update') return v.exit;
    return offerStep({ root, s, plan, runId, dir, res, verify, v, before, after, guard });
  } finally {
    releaseAll(locks);
  }
}

/** The offer of a `visual update`: printed lines, then a token (exit 3) or `visual offer: none — <why>`. */
function offerStep({ root, s, plan, runId, dir, res, verify, v, before, after, guard }) {
  const none = (why) => { console.log(`visual offer: none — ${why}`); return v.exit; };
  if (verify.integrity.length) return none(`baselines integrity (${verify.integrity[0]})`);
  const offer = buildOffer({
    root, settings: s, env: plan.env, runId, evals: res.evals, verify, treeBefore: res.treeBefore, candidatesDir: res.capDir,
    sources: res.sources, cases: res.cases, noDevice: res.noDevice, renderers: res.renderers, build: { before: before.sha, after: after.sha },
  });
  for (const e of offer.entries) console.log(offerLine(e));
  if (res.block.integrity.length) return none(res.block.integrity[0]);
  if (res.interrupted) return none(res.interrupted);
  const b = buildProblem({ before, after });
  if (b) return none(b);
  if (guard.stop || guard.outsideTest || v.parts.blocked.length || res.block.guard_red.length) return none('the guard found a request it stopped or blocked');
  if (!offer.writes) return none(offer.entries.some((e) => e.kind === 'unstable' || e.kind === 'error') ? 'no stable target to accept' : 'the baselines already match');
  fs.writeFileSync(path.join(dir, 'visual', 'offer.json'), `${JSON.stringify(offer, null, 2)}\n`);
  console.log(`acceptance-required: ${issueAcceptToken(path.resolve(root, RUNS_DIR), plan.env, runId, offer.digest)}`);
  return 3;
}

async function cmdVisualAccept(args) {
  const root = path.resolve(args.root);
  const loaded = loadConfig(root);
  if (!loaded.adopted) { console.error('regression not adopted'); return 2; }
  if (loaded.errors.length) { for (const e of loaded.errors) console.error(`run: ${CONFIG_PATH}: ${e}`); return 2; }
  if (isTeamClone(root)) { console.error('refused: a team clone never writes baselines (accept from your own checkout)'); return 3; }
  if (!isObject(loaded.config.visual)) { console.error('run: visual not configured — see .claude/skills/regression/references/visual.md'); return 2; }
  const runsDir = path.resolve(root, RUNS_DIR);
  if (!fs.existsSync(path.join(runsDir, args.run, 'visual', 'offer.json'))) { console.error(`refused: no offer for run ${args.run} — run visual update first`); return 3; }
  const co = acquireLock(`checkout-${h16(realRootOf(root))}`, { pid: process.pid, pgid: null, run_id: args.run });
  if (co.error) { console.error(`refused: ${co.error}`); return 3; }
  try {
    const r = await acceptOffer({ root, settings: visualSettings(loaded.config), runId: args.run, token: args.token, runsDir });
    if (r.exit === 0) console.log(r.message); else console.error(r.message);
    return r.exit;
  } finally {
    try { co.lock.release(); } catch { /* the lock holds its token */ }
  }
}

// ---------------------------------------------------------------------------------------------
// status

function cmdStatus(args) {
  const root = path.resolve(args.root);
  const loaded = loadConfig(root);
  if (!loaded.adopted) { console.log(args.json ? JSON.stringify({ adopted: false, message: 'regression not adopted' }) : 'regression not adopted'); return 0; }
  const dir = path.resolve(root, RUNS_DIR);
  const newest = new Map();
  if (fs.existsSync(dir)) {
    for (const d of fs.readdirSync(dir, { withFileTypes: true })) {
      if (!d.isDirectory() || d.name.startsWith('.')) continue;
      let rec;
      try { rec = JSON.parse(fs.readFileSync(path.join(dir, d.name, 'record.json'), 'utf8')); } catch { continue; }
      if (args.env && rec.env !== args.env) continue;
      // Newest per environment AND mode: a green visual record never hides a red full run.
      const key = `${rec.env}\0${rec.mode}`;
      const prev = newest.get(key);
      if (!prev || String(rec.ended_at) > String(prev.ended_at)) newest.set(key, rec);
    }
  }
  const envs = isObject(loaded.config?.environments) ? Object.keys(loaded.config.environments).filter((k) => !docKey(k)) : [];
  const recorded = [...newest.values()];
  const names = args.env ? [args.env] : [...new Set([...envs, ...recorded.map((r) => r.env)])];
  const rows = names.flatMap((env) => {
    const mine = recorded.filter((r) => r.env === env).sort((a, b) => String(a.mode).localeCompare(String(b.mode)));
    return mine.length
      ? mine.map((r) => ({ env, mode: r.mode, verdict: r.verdict, build_sha: r.build_sha, ended_at: r.ended_at, run_id: r.run_id }))
      : [{ env, mode: null, verdict: null }];
  });
  if (args.json) { console.log(JSON.stringify({ adopted: true, runs: rows }, null, 2)); return 0; }
  if (!rows.length) console.log('no run recorded on this machine');
  for (const r of rows) {
    console.log(r.verdict ? `${r.env} ${r.mode} ${r.verdict} ${r.build_sha ?? 'unknown'} ${r.ended_at} ${r.run_id}` : `${r.env} no run recorded on this machine`);
  }
  return 0;
}

// ---------------------------------------------------------------------------------------------
// CLI

class UsageError extends Error {}
const USAGE = [
  'usage: node .claude/lib/regression/run.mjs run [smoke|full] [--env <name>] [--confirm <token>] [--root <dir>]',
  '       node .claude/lib/regression/run.mjs visual compare|update [--env <name>] [--confirm <token>] [--root <dir>]',
  '       node .claude/lib/regression/run.mjs visual accept --run <run id> --token <token> [--root <dir>]',
  '       node .claude/lib/regression/run.mjs status [--env <name>] [--json] [--root <dir>]',
].join('\n');
const RUN_MODES = ['smoke', 'full'];

function parseArgs(argv) {
  let [cmd, ...rest] = argv;
  if (!['run', 'status', 'visual'].includes(cmd)) throw new UsageError(cmd ? `unknown command ${cmd}` : 'a command is required');
  const args = { cmd, root: process.cwd(), env: undefined, mode: 'smoke', confirm: undefined, json: false, action: undefined, run: undefined, token: undefined };
  let flags = cmd === 'run' ? ['--env', '--confirm', '--root'] : ['--env', '--root'];
  if (cmd === 'visual') {
    const [action, ...more] = rest;
    if (action === 'accept') flags = ['--run', '--token', '--root'];
    else if (VISUAL_ACTIONS.includes(action)) flags = ['--env', '--confirm', '--root'];
    else throw new UsageError(action ? `unknown visual action ${action}` : 'visual needs compare, update or accept');
    args.action = action;
    rest = more;
  }
  for (let i = 0; i < rest.length; i += 1) {
    const a = rest[i];
    // `run` takes smoke|full only: `visual` is never a run mode (the lane runs through `visual …`).
    if (cmd === 'run' && i === 0 && RUN_MODES.includes(a)) args.mode = a;
    else if (cmd === 'status' && a === '--json') args.json = true;
    else if (flags.includes(a)) {
      if (i + 1 >= rest.length) throw new UsageError(`${a} needs a value`);
      args[a.slice(2)] = rest[++i];
    } else throw new UsageError(`unknown argument ${a}`);
  }
  if (args.action === 'accept' && (!args.run || !args.token)) throw new UsageError('visual accept needs --run <run id> and --token <token>');
  return args;
}

export async function main(argv = process.argv.slice(2)) {
  let args;
  try { args = parseArgs(argv); } catch (err) {
    if (!(err instanceof UsageError)) throw err;
    console.error(`run: ${err.message}\n${USAGE}`);
    return 2;
  }
  if (args.cmd === 'run') return cmdRun(args);
  if (args.cmd === 'visual') return args.action === 'accept' ? cmdVisualAccept(args) : cmdVisual(args);
  return cmdStatus(args);
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    process.exitCode = await main();
  } catch (err) {
    console.error(`run: ${err.message}`);
    process.exitCode = 2;
  }
}
