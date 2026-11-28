// The heal lane's scripts: which red specs may be diagnosed (`select`), the pinned attempt with its
// snapshot and stale rules (`start`), the probe's digests for its critic (`probe-key`), the class of a
// red spec from the two-pass probe record (`classify`: APP, TEST, catalog-outdated, env — or a stop),
// and the only writer of a claimed spec (`apply`: a TEST repair or an `author --refresh` header, kept
// only behind weaken-check, a heal verify of this attempt and a critic pass on the same digests).
// `discard` closes an attempt. Writes its candidate, its probe and its heal directory only; never
// the catalog, never a visual baseline, never a commit. Node builtins only — ships to every
// downstream. Contract: .agents/reference/regression.md §17.
//
//   node .claude/lib/regression/heal.mjs select (--run <run-id> | <spec>[ › <title>] | --refresh <ID>…) [--env <n>] [--root <dir>]
//   node .claude/lib/regression/heal.mjs start <ID> --env <n> [--from-run <run-id>] [--refresh] [--root <dir>]   (prints `heal: <dir>`)
//   node .claude/lib/regression/heal.mjs probe-key <ID> --run <heal dir> [--root <dir>]
//   node .claude/lib/regression/heal.mjs classify <ID> --run <heal dir> --probe <probe run dir> [--root <dir>]
//   node .claude/lib/regression/heal.mjs apply <ID> --run <heal dir> --verify <verify run dir> --critic <file> [--refresh] [--root <dir>]
//   node .claude/lib/regression/heal.mjs discard <ID> --run <heal dir> [--root <dir>]
//     exit 0 ok · 1 refused / nothing eligible / a stop · 2 usage / config / no target (prints `environments:`) · 3 team clone

import fs from 'node:fs';
import path from 'node:path';
import { randomBytes } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { RUNS_DIR, isObject, envPolicy, resolveTarget, specDir } from './config.mjs';
import { loadCatalog, validateCatalog, specOf, statusOf, blockTexts, automationState, staleNow, posix } from './catalog.mjs';
import {
  candidateProblem, buildProbePlan, evidenceKey, changedPart, sha256, targetOf, hasScreenshotAssertion, viewportProjects, readText, sameInputs,
} from './policy.mjs';
import { isTeamClone, newRunDir, scanIntegration, RUNNER_NEEDS } from './run.mjs';
import { lintSpec, stripComments } from './speclint.mjs';
import { weakenCheck } from './weaken-check.mjs';
import { checkVerified, loadAdopted, underCheckoutLock, readJson, refuse, Refusal, UsageError } from './author.mjs';
import { writeAtomic } from '../backlog-check.mjs';

const PASSED_OR_FAILED = new Set(['passed', 'failed']);

// ---------------------------------------------------------------------------------------------
// Shared reads

function configOf(root) {
  const cfg = loadAdopted(root);
  if (!cfg) throw new UsageError('regression not adopted');
  if (!isObject(cfg.runner) || !isObject(cfg.environments)) throw new UsageError('baseline not established — run /setup:regression baseline');
  return cfg;
}

/** The validated catalog: `{settings, files, blocks}`; an invalid one is a usage error. */
function catalogOf(root, cfg) {
  const cat = loadCatalog(root, cfg);
  const errors = validateCatalog(cat.blocks, cat.settings);
  if (errors.length) throw new UsageError(`the catalog is invalid — ${errors[0].file}:${errors[0].line}: ${errors[0].message}`);
  return cat;
}

const rel = (root, abs) => posix(path.relative(root, abs));
const testCount = (text) => [...stripComments(text).matchAll(/\btest\(\s*['"`]/g)].length;
const writeHeal = (abs, heal) => writeAtomic(path.join(abs, 'heal.json'), `${JSON.stringify(heal, null, 2)}\n`);

/** `{abs, heal}` of a heal directory whose attempt is for `id`. */
function attemptOf(root, dir, id) {
  const abs = path.resolve(root, dir);
  const heal = readJson(path.join(abs, 'heal.json'), 'heal.json');
  if (heal.schema !== 1) refuse(`${id} — heal.json is not schema 1`);
  if (heal.scenario !== id) refuse(`${id} — ${rel(root, abs)} is the heal attempt of ${heal.scenario}`);
  return { abs, heal };
}

/** Repo-relative heal directories holding an open attempt for `id`. */
function openAttempts(root, id) {
  const dir = path.resolve(root, RUNS_DIR);
  if (!fs.existsSync(dir)) return [];
  return fs.readdirSync(dir, { withFileTypes: true }).filter((d) => d.isDirectory()).flatMap((d) => {
    try {
      const h = JSON.parse(fs.readFileSync(path.join(dir, d.name, 'heal.json'), 'utf8'));
      return h.scenario === id && h.state === 'open' ? [posix(path.join(RUNS_DIR, d.name))] : [];
    } catch { return []; }
  });
}

/** The resolved target of `--env`, or null after printing the error and the configured names. */
function targetOrNull(cfg, envName) {
  const target = resolveTarget(cfg, envName);
  if (!target.error) return target;
  console.error(`heal: ${target.error}`);
  console.log(`environments: ${target.names.join(', ') || '(none)'}`);
  return null;
}

/** The catalog blocks of `ids`, printing `refused: <id> — not in the catalog` for each unknown one. */
function pickIds(blocks, ids) {
  return ids.flatMap((id) => {
    const b = blocks.find((x) => x.id === id);
    if (!b) console.log(`refused: ${id} — not in the catalog`);
    return b ? [b] : [];
  });
}

/** Why the claimed spec, its block or its closure differ from the attempt's snapshot, or null. */
function snapshotProblem(root, cfg, heal, b, texts) {
  if (specOf(b)?.path !== heal.spec) return `the scenario's Spec no longer names ${heal.spec}`;
  const text = readText(root, heal.spec);
  if (text === null) return `spec file absent — ${heal.spec}`;
  if (sha256(text) !== heal.snapshot.spec_sha256) return 'spec';
  if (sha256(texts.get(b.id).text) !== heal.snapshot.block_sha256) return 'block';
  const inputs = lintSpec(root, cfg, heal.spec, b.id).files.filter((f) => f !== heal.spec);
  if (!sameInputs(root, inputs, heal.snapshot.inputs)) return 'a helper';
  return null;
}

/** Move `abs` (when it exists) into `destDir`; its new repo path, or null. */
function moveInto(root, abs, destDir) {
  if (!fs.existsSync(abs)) return null;
  fs.mkdirSync(destDir, { recursive: true });
  const dest = path.join(destDir, path.basename(abs));
  try { fs.renameSync(abs, dest); } catch { fs.copyFileSync(abs, dest); fs.unlinkSync(abs); }
  return rel(root, dest);
}

/** Why `b` may not be healed on this target (`policy` null skips it), or null. */
function healProblem(root, cfg, b, policy, envName) {
  const [, status] = statusOf(b);
  if (status !== 'READY') return `not READY (${b.fields.Status?.value})`;
  const spec = specOf(b);
  if (spec === null || spec.error) return 'no spec to heal';
  const candidate = candidateProblem(cfg, b, policy, envName, { allowSpec: spec.path });
  if (candidate) return candidate;
  const text = readText(root, spec.path);
  if (text === null) return `spec file absent — ${spec.path}`;
  const n = testCount(text);
  if (n !== 1) return `${n} tests — heal needs one test per file`;
  const open = openAttempts(root, b.id);
  if (open.length) return `heal open in ${open[0]} — discard it first`;
  return null;
}

// ---------------------------------------------------------------------------------------------
// select

function cmdSelect(root, args) {
  const cfg = configOf(root);
  const { blocks } = catalogOf(root, cfg);
  let envName;
  let picked = [];
  if (args.run) {
    const file = path.resolve(root, RUNS_DIR, args.run, 'record.json');
    if (!fs.existsSync(file)) refuse(`record not found — ${args.run}`);
    const rec = readJson(file, 'record.json');
    const red = [...new Set((rec.cases ?? []).filter((c) => c.result === 'failed').map((c) => c.id))];
    if (rec.verdict === 'GREEN') { console.log(`nothing to heal — ${args.run} is GREEN`); return 1; }
    if (rec.verdict === 'BLOCKED/ENV') {
      if (!red.length) console.log(`nothing to heal — ${args.run} was BLOCKED/ENV: ${rec.reasons?.[0] ?? 'no reason recorded'}`);
      for (const id of red) {
        const b = blocks.find((x) => x.id === id);
        const st = b ? automationState(root, b, {}) : { state: 'missing', reason: 'not in the catalog' };
        console.log(st.state === 'verified' ? `env: ${id} — the run was BLOCKED/ENV: ${rec.reasons?.[0] ?? 'no reason recorded'}` : `${st.state === 'stale' ? 'stale' : 'refused'}: ${id} — ${st.reason}`);
      }
      return 1;
    }
    if (rec.verdict !== 'RED') refuse(`${args.run} — verdict ${rec.verdict}: nothing a heal can classify`);
    envName = rec.env;
    picked = pickIds(blocks, red);
  } else {
    const target = targetOrNull(cfg, args.env);
    if (!target) return 2;
    envName = target.name;
    if (args.refresh) picked = pickIds(blocks, args.ids);
    else {
      const m = /^(\S+?)(?: › (.+))?$/.exec(args.spec.trim());
      picked = blocks.filter((b) => specOf(b)?.path === m?.[1] && (!m?.[2] || specOf(b).title === m[2]));
      if (!picked.length) refuse(`no scenario cites ${args.spec}`);
    }
  }
  const entry = cfg.environments[envName];
  const policy = isObject(entry) ? envPolicy(entry) : null;
  let eligible = 0;
  for (const b of picked) {
    let why = healProblem(root, cfg, b, policy, envName);
    if (!why && args.refresh) {
      const { rule } = staleNow(root, b);
      if (rule?.rule !== 'refresh needed') why = `not a refresh: ${rule ? `${rule.rule} — ${rule.reason}` : 'the spec is verified'}`;
    }
    if (why) console.log(`refused: ${b.id} — ${why}`);
    else { eligible += 1; console.log(`eligible: ${b.id} ${specOf(b).path}`); }
  }
  if (args.run) console.log(`env: ${envName}`);
  return eligible ? 0 : 1;
}

// ---------------------------------------------------------------------------------------------
// start

const STOP_LINE = {
  'catalog-outdated': (id, r) => `class: catalog-outdated — ${r.reason}`,
  'refresh needed': (id, r) => `stop: refresh needed — ${r.reason} — /regression-tests author --refresh ${id}`,
  inconclusive: (id, r) => `stop: inconclusive — ${r.reason}`,
};

function cmdStart(root, args) {
  const cfg = configOf(root);
  const id = args.id;
  const target = targetOrNull(cfg, args.env);
  if (!target) return 2;
  const t = targetOf(root, cfg, target.name);
  if (t.error) throw new UsageError(t.error);
  return underCheckoutLock(root, `heal-start-${id}`, () => {
    const { files, blocks } = catalogOf(root, cfg);
    const b = blocks.find((x) => x.id === id);
    if (!b) refuse(`${id} — not in the catalog`);
    const why = healProblem(root, cfg, b, t.policy, target.name);
    if (why) refuse(`${id} — ${why}`);
    const spec = specOf(b).path;
    const specText = readText(root, spec);
    // A candidate file name would change its snapshot path: screenshots belong to the visual lane.
    if (hasScreenshotAssertion(specText)) refuse(`${id} — ${spec} asserts a screenshot — the visual lane owns those`);
    const finding = scanIntegration(root, { configFile: cfg.runner.config, configNeeds: RUNNER_NEEDS, specs: [] })[0];
    if (finding) refuse(`${id} — runner not guard-integrated — ${finding.file}: ${finding.reason} (a candidate or probe would load in ordinary runs)`);
    let sourceRun = null;
    if (args.fromRun) {
      const recFile = path.resolve(root, RUNS_DIR, args.fromRun, 'record.json');
      if (!fs.existsSync(recFile)) refuse(`record not found — ${args.fromRun}`);
      const rec = readJson(recFile, 'record.json');
      if (!(rec.cases ?? []).some((c) => c.id === id && c.result === 'failed')) refuse(`${id} — did not fail in ${args.fromRun}`);
      if (rec.env !== target.name || rec.kind !== t.policy.kind || rec.base_url !== t.base_url) {
        refuse(`${id} — the target changed since ${args.fromRun} (${rec.env} ${rec.kind} ${rec.base_url} → ${target.name} ${t.policy.kind} ${t.base_url})`);
      }
      sourceRun = args.fromRun;
    }
    const { state, rule } = staleNow(root, b);
    if (args.refresh && rule?.rule !== 'refresh needed') refuse(`${id} — not a refresh: ${rule ? `${rule.rule} — ${rule.reason}` : 'the spec is verified'}`);
    const lower = id.toLowerCase();
    const candidate = posix(path.join(path.dirname(spec), `${lower}.heal.spec.ts`));
    const probe = args.refresh ? null : posix(path.join(specDir(cfg), '_heal', `${lower}.probe.spec.ts`));
    for (const p of [candidate, probe].filter(Boolean)) if (fs.existsSync(path.resolve(root, p))) refuse(`${id} — target exists — ${p}`);

    const lint = lintSpec(root, cfg, spec, id);
    const inputs = lint.files.filter((f) => f !== spec).map((file) => ({ file, sha256: sha256(fs.readFileSync(path.resolve(root, file))) }));
    const { dir } = newRunDir(root, 'heal');
    const before = path.join(dir, 'before', path.basename(spec));
    fs.mkdirSync(path.dirname(before), { recursive: true });
    fs.writeFileSync(before, specText);
    const heal = {
      schema: 1, id: randomBytes(8).toString('hex'), scenario: id, effect: b.fields.Effect?.value ?? 'read',
      env: target.name, kind: t.policy.kind, base_url: t.base_url, spec, title: specOf(b).title,
      created_at: new Date().toISOString(), refresh: args.refresh, state: 'open', source_run: sourceRun,
      snapshot: { path: posix(path.join('before', path.basename(spec))), spec_sha256: sha256(specText), inputs, block_sha256: sha256(blockTexts(root, files).get(id).text) },
      automation: state, candidate: null, probe: null, probe_critic: null,
    };
    if (!args.refresh && rule) {
      heal.state = 'closed';
      if (rule.rule === 'catalog-outdated') heal.class = rule.rule; else heal.stop = rule.rule;
      heal.evidence = [rule.reason];
      writeHeal(dir, heal);
      console.log(STOP_LINE[rule.rule](id, rule));
      console.log(`heal: ${rel(root, dir)}`);
      return 1;
    }
    // Exclusive targets: a candidate never sits at the claimed spec's path before apply.
    const created = [];
    try {
      fs.copyFileSync(path.resolve(root, spec), path.resolve(root, candidate), fs.constants.COPYFILE_EXCL);
      created.push(candidate);
      if (probe) {
        fs.mkdirSync(path.dirname(path.resolve(root, probe)), { recursive: true });
        fs.closeSync(fs.openSync(path.resolve(root, probe), 'wx'));
        created.push(probe);
      }
    } catch (err) {
      for (const c of created) fs.rmSync(path.resolve(root, c), { force: true });
      if (err.code === 'EEXIST') refuse(`${id} — target exists — ${created.length ? probe : candidate}`);
      throw err;
    }
    heal.candidate = candidate;
    heal.probe = probe;
    heal.probe_critic = probe ? posix(path.join(rel(root, dir), `probe-critic-${id}.json`)) : null;
    writeHeal(dir, heal);
    if (probe) console.log(`probe: ${probe}`);
    console.log(`candidate: ${candidate}`);
    console.log(`heal: ${rel(root, dir)}`);
    return 0;
  });
}

// ---------------------------------------------------------------------------------------------
// probe-key

function cmdProbeKey(root, args) {
  const cfg = configOf(root);
  const { heal } = attemptOf(root, args.run, args.id);
  if (!heal.probe) refuse(`${args.id} — this attempt has no probe`);
  if (readText(root, heal.probe) === null) refuse(`${args.id} — probe file absent — ${heal.probe}`);
  const { files } = catalogOf(root, cfg);
  const key = evidenceKey(root, heal.probe, lintSpec(root, cfg, heal.probe, args.id).files, blockTexts(root, files).get(args.id).text);
  console.log(`probe-key: ${args.id} spec_sha256=${key.spec_sha256} inputs_sha256=${key.inputs_sha256} block_sha256=${key.block_sha256}`);
  return 0;
}

// ---------------------------------------------------------------------------------------------
// classify

const qualified = (c) => Boolean(c) && c.attempts === 1 && Array.isArray(c.retries) && c.retries.length === 1 && c.retries[0] === 0 && c.attested === true && c.session_ok === true;

/** The environment facts of a probe record, one line each. */
function environmentFacts(probe) {
  const out = [];
  for (const pass of probe.passes ?? []) {
    const f = pass.facts ?? {};
    if (f.stop) out.push(`guard stop: ${f.stop}`);
    for (const e of f.server_error ?? []) out.push(`server error ${e.status} ${e.url} (${e.case})`);
    for (const e of f.navigation_5xx ?? []) out.push(`navigation ${e.status} ${e.url} (${e.case})`);
    for (const e of f.network_failed ?? []) out.push(`network failure ${e.method} ${e.url} (${e.case})`);
    for (const w of f.whole ?? []) out.push(`pass ${pass.n}: ${w}`);
    for (const a of f.attestation ?? []) out.push(`pass ${pass.n}: ${a}`);
  }
  const b = probe.build ?? {};
  if (b.stop) out.push(`guard stop on a build read: ${b.stop}`);
  if (!b.before || (!b.after && !b.after_skipped)) out.push(`deployed build unknown (${b.reason ?? 'no build_sha_url'})`);
  else if (b.after && b.after !== b.before) out.push(`build changed during the probe (${b.before} → ${b.after})`);
  return out;
}

/**
 * The class of one red spec from its probe record, per project: `R_p` the claimed spec's result
 * (pass 1), `P_p` the probe's (pass 2). `{class: APP|TEST|env, evidence}` or `{stop: not reproduced |
 * inconclusive, evidence}` — APP and TEST need no environment fact, no aborted request, every result
 * passed or failed and every case qualified; a write scenario never classifies TEST.
 */
export function classifyProbe({ probe, heal, projects }) {
  const pass = (n) => (probe.passes ?? []).find((p) => p.n === n);
  const caseOf = (n, p) => pass(n)?.cases?.find((c) => c.project === p);
  const env = environmentFacts(probe);
  if (env.length) return { class: 'env', evidence: env };
  const blocked = (probe.passes ?? []).flatMap((p) => (p.facts?.blocked ?? []).map((e) => `guard aborted ${e.method} ${e.url}`));
  if (blocked.length) return { stop: 'inconclusive', evidence: blocked };
  if (projects.every((p) => caseOf(1, p)?.result === 'passed')) {
    const weak = projects.filter((p) => caseOf(2, p)?.result === 'failed').map((p) => `the spec may assert too little on ${p}`);
    return { stop: 'not reproduced', evidence: ['the claimed spec passed on every project', ...weak] };
  }
  if (!pass(2)) return { stop: 'inconclusive', evidence: [`pass 2 not run${probe.skipped?.[0]?.reason ? ` — ${probe.skipped[0].reason}` : ''}`] };
  for (const [n, what] of [[1, 'spec'], [2, 'probe']]) {
    for (const p of projects) {
      const r = caseOf(n, p)?.result ?? 'missing';
      if (!PASSED_OR_FAILED.has(r)) return { stop: 'inconclusive', evidence: [`${what} ${r} on ${p}`] };
    }
  }
  const unqualified = [1, 2].flatMap((n) => projects.filter((p) => !qualified(caseOf(n, p))).map((p) => `unqualified evidence: pass ${n} ${heal.scenario}/${p}`));
  const both = projects.filter((p) => caseOf(1, p).result === 'failed' && caseOf(2, p).result === 'failed');
  const specFailed = projects.filter((p) => caseOf(1, p).result === 'failed');
  if (both.length || (specFailed.length && projects.every((p) => caseOf(2, p).result === 'passed'))) {
    if (unqualified.length) return { stop: 'inconclusive', evidence: unqualified };
    if (both.length) return { class: 'APP', evidence: [`the claimed spec and the probe failed on ${both.join(', ')}`] };
    if (heal.effect === 'write') return { stop: 'inconclusive', evidence: ['state may have changed between passes (a write scenario)'] };
    return { class: 'TEST', evidence: [`the claimed spec failed on ${specFailed.join(', ')}; the probe passed on every project`] };
  }
  return { stop: 'inconclusive', evidence: [`crossed pairing — spec failed on ${specFailed.join(', ')}, probe failed on ${projects.filter((p) => caseOf(2, p).result === 'failed').join(', ')}`] };
}

function bugCandidate(root, heal, b, probe, res, projects) {
  const failing = projects.filter((p) => (probe.passes ?? []).every((ps) => ps.cases?.find((c) => c.project === p)?.result === 'failed'));
  const context = (probe.passes ?? []).flatMap((ps) => (ps.cases ?? []).flatMap((c) => c.attachments ?? []));
  return [
    `# Bug candidate: ${b.id} — ${b.title}`,
    '',
    `- Target: ${heal.env} (${heal.kind}) ${heal.base_url}`,
    `- Build: ${probe.build?.before ?? 'unknown'}`,
    `- Failing projects: ${failing.join(', ')}`,
    `- Probe record: ${heal.probe_run}/probe.json`,
    `- Claimed spec: ${heal.spec}`,
    '',
    '## Expected (from the catalog, verbatim)',
    '',
    b.fields.Expected?.value ?? '',
    '',
    '## Evidence',
    '',
    ...res.evidence.map((e) => `- ${e}`),
    ...(context.length ? ['', '## Context', '', ...context.map((c) => `- ${c}`)] : []),
    '',
    `Reproduced twice on ${failing.join(', ')}: the claimed spec and an independent probe.`,
    '',
  ].join('\n');
}

function cmdClassify(root, args) {
  const cfg = configOf(root);
  const id = args.id;
  return underCheckoutLock(root, `heal-classify-${id}`, () => {
    const { abs, heal } = attemptOf(root, args.run, id);
    if (heal.state !== 'open') refuse(`${id} — the attempt is ${heal.state}`);
    if (heal.refresh) refuse(`${id} — a refresh attempt is not classified`);
    const { files, blocks } = catalogOf(root, cfg);
    const b = blocks.find((x) => x.id === id);
    if (!b) refuse(`${id} — not in the catalog`);
    const changed = snapshotProblem(root, cfg, heal, b, blockTexts(root, files));
    if (changed) refuse(`${id} — the spec changed since start (${changed}) — the live check precedes any diff`);
    const probeDir = path.resolve(root, args.probe);
    const probe = readJson(path.join(probeDir, 'probe.json'), 'probe.json');
    // The plan the probe ran is recomputed now: a refusal of it names its own reason.
    const plan = buildProbePlan(root, cfg, heal.env, heal);
    const planProblem = plan.error ?? (plan.catalog_errors ? 'the catalog is invalid' : plan.refused[0]?.reason);
    if (planProblem) refuse(`${id} — the probe plan no longer holds: ${planProblem}`);
    const pinned = probe.env === heal.env && probe.kind === heal.kind && probe.base_url === heal.base_url;
    if (probe.heal_id !== heal.id || !pinned || probe.plan_digest !== plan.digests.plan) refuse(`${id} — probe record of another attempt, environment or plan`);
    const projects = viewportProjects(cfg, b.fields.Viewport?.value).map((d) => d.project);
    const res = classifyProbe({ probe, heal, projects });
    heal.probe_run = rel(root, probeDir);
    heal.probe = moveInto(root, path.resolve(root, heal.probe), path.join(abs, 'probe')) ?? heal.probe;
    if (res.class) heal.class = res.class; else heal.stop = res.stop;
    heal.evidence = res.evidence;
    heal.classified_at = new Date().toISOString();
    const lines = [res.class ? `class: ${res.class} — ${res.evidence[0]}` : `stop: ${res.stop} — ${res.evidence[0]}`, ...res.evidence.slice(1).map((e) => `evidence: ${e}`)];
    if (res.class === 'APP') {
      const bug = path.join(abs, `bug-${id}.md`);
      fs.writeFileSync(bug, bugCandidate(root, heal, b, probe, res, projects));
      heal.bug = rel(root, bug);
      lines.push(`bug candidate: ${heal.bug}`);
    }
    if (res.class !== 'TEST') {
      heal.state = 'closed';
      heal.candidate = moveInto(root, path.resolve(root, heal.candidate), path.join(abs, 'discarded')) ?? heal.candidate;
    }
    writeHeal(abs, heal);
    for (const l of lines) console.log(l);
    return res.class === 'TEST' ? 0 : 1;
  });
}

// ---------------------------------------------------------------------------------------------
// apply · discard

function cmdApply(root, args) {
  const cfg = configOf(root);
  const id = args.id;
  return underCheckoutLock(root, `heal-apply-${id}`, () => {
    const { abs, heal } = attemptOf(root, args.run, id);
    if (heal.state !== 'open') refuse(`${id} — the attempt is ${heal.state}`);
    if (Boolean(args.refresh) !== Boolean(heal.refresh)) refuse(`${id} — ${heal.refresh ? 'a refresh attempt is applied with --refresh' : 'not a refresh attempt'}`);
    if (!heal.refresh && heal.class !== 'TEST') refuse(`${id} — the attempt is not classified TEST`);
    const { files, blocks } = catalogOf(root, cfg);
    const b = blocks.find((x) => x.id === id);
    if (!b) refuse(`${id} — not in the catalog`);
    const texts = blockTexts(root, files);
    if (sha256(texts.get(id).text) !== heal.snapshot.block_sha256) refuse(`${id} — the block changed since start`);
    if (specOf(b)?.path !== heal.spec) refuse(`${id} — the scenario's Spec no longer names ${heal.spec}`);
    const { rule } = staleNow(root, b);
    if (heal.refresh ? rule?.rule !== 'refresh needed' : rule) refuse(`${id} — the criterion changed during the heal — ${rule ? `${rule.rule}: ${rule.reason}` : 'the spec is verified again'}`);
    const specText = readText(root, heal.spec);
    if (specText === null || sha256(specText) !== heal.snapshot.spec_sha256) refuse(`${id} — conflict: ${heal.spec} changed since start; candidate kept at ${heal.candidate}`);
    const snapText = readText(root, path.join(rel(root, abs), heal.snapshot.path));
    if (snapText === null || sha256(snapText) !== heal.snapshot.spec_sha256) refuse(`${id} — the snapshot copy ${heal.snapshot.path} changed`);
    const candText = readText(root, heal.candidate);
    if (candText === null) refuse(`${id} — candidate absent — ${heal.candidate}`);
    if (hasScreenshotAssertion(candText)) refuse(`${id} — the candidate asserts a screenshot — the visual lane owns those`);
    const wc = weakenCheck(snapText, candText, { refresh: heal.refresh });
    if (!wc.ok) refuse(`${id} — weakened: ${wc.weakened[0].line}: ${wc.weakened[0].kind} — ${wc.weakened[0].detail}`);
    const lint = lintSpec(root, cfg, heal.candidate, id);
    if (lint.violations.length) refuse(`${id} — lint: ${lint.violations[0].file}:${lint.violations[0].line}: ${lint.violations[0].rule}`);
    if (lint.title !== heal.title) refuse(`${id} — the candidate's title ${lint.title} is not ${heal.title}`);
    if (!sameInputs(root, lint.files.filter((f) => f !== heal.candidate), heal.snapshot.inputs)) refuse(`${id} — a helper changed — heal changes only the spec`);
    const { entry } = checkVerified(root, cfg, { id, spec: heal.candidate, verifyDir: args.verify, heal });
    const current = evidenceKey(root, heal.candidate, lint.files, texts.get(id).text);
    const stale = changedPart(entry, current);
    if (stale) refuse(`${id} — ${stale} changed since the verify`);
    const critic = readJson(path.resolve(root, args.critic), 'critic verdict');
    if (critic.id !== id || critic.verdict !== 'pass' || critic.mode !== 'heal' || critic.heal_id !== heal.id
      || critic.before_sha256 !== heal.snapshot.spec_sha256 || !Array.isArray(critic.clauses) || !critic.clauses.length) refuse(`${id} — no heal critic pass for this attempt`);
    const criticStale = changedPart(critic, current);
    if (criticStale) refuse(`${id} — the critic verdict predates a change (${criticStale})`);
    if (heal.refresh) {
      const after = automationState(root, b, { specText: candText });
      if (after.state !== 'verified') refuse(`${id} — the refreshed spec would compute ${after.state}: ${after.reason}`);
    }
    // The one write of a claimed spec.
    fs.renameSync(path.resolve(root, heal.candidate), path.resolve(root, heal.spec));
    heal.state = 'applied';
    heal.applied_at = new Date().toISOString();
    heal.verify_run = posix(args.verify);
    writeHeal(abs, heal);
    console.log(`${heal.refresh ? 'refreshed' : 'healed'}: ${id} — ${heal.spec}`);
    return 0;
  });
}

function cmdDiscard(root, args) {
  configOf(root);
  const id = args.id;
  return underCheckoutLock(root, `heal-discard-${id}`, () => {
    const { abs, heal } = attemptOf(root, args.run, id);
    if (heal.state !== 'open') { console.log(`discarded: ${id} — already ${heal.state === 'discarded' ? 'discarded' : 'closed'}`); return 0; }
    const dest = path.join(abs, 'discarded');
    for (const k of ['candidate', 'probe']) if (heal[k]) heal[k] = moveInto(root, path.resolve(root, heal[k]), dest) ?? heal[k];
    heal.state = 'discarded';
    heal.discarded_at = new Date().toISOString();
    writeHeal(abs, heal);
    console.log(`discarded: ${id}`);
    return 0;
  });
}

// ---------------------------------------------------------------------------------------------
// CLI

const USAGE = [
  'usage: node .claude/lib/regression/heal.mjs select (--run <run-id> | <spec>[ › <title>] | --refresh <ID>…) [--env <n>] [--root <dir>]',
  '       node .claude/lib/regression/heal.mjs start <ID> --env <n> [--from-run <run-id>] [--refresh] [--root <dir>]',
  '       node .claude/lib/regression/heal.mjs probe-key <ID> --run <heal dir> [--root <dir>]',
  '       node .claude/lib/regression/heal.mjs classify <ID> --run <heal dir> --probe <probe run dir> [--root <dir>]',
  '       node .claude/lib/regression/heal.mjs apply <ID> --run <heal dir> --verify <verify run dir> --critic <file> [--refresh] [--root <dir>]',
  '       node .claude/lib/regression/heal.mjs discard <ID> --run <heal dir> [--root <dir>]',
].join('\n');

const FLAGS = { '--root': 'root', '--env': 'env', '--from-run': 'fromRun', '--run': 'run', '--probe': 'probe', '--verify': 'verify', '--critic': 'critic' };
const COMMANDS = { select: cmdSelect, start: cmdStart, 'probe-key': cmdProbeKey, classify: cmdClassify, apply: cmdApply, discard: cmdDiscard };
const NEEDS = { start: ['env'], 'probe-key': ['run'], classify: ['run', 'probe'], apply: ['run', 'verify', 'critic'], discard: ['run'] };

function parseArgs(argv) {
  const [cmd, ...rest] = argv;
  if (!Object.hasOwn(COMMANDS, cmd ?? '')) throw new UsageError(cmd ? `unknown command ${cmd}` : 'a command is required');
  const args = { cmd, root: process.cwd(), refresh: false, ids: [] };
  const positional = [];
  for (let i = 0; i < rest.length; i += 1) {
    const a = rest[i];
    if (a === '--refresh') args.refresh = true;
    else if (FLAGS[a]) {
      if (i + 1 >= rest.length) throw new UsageError(`${a} needs a value`);
      args[FLAGS[a]] = rest[++i];
    } else if (!a.startsWith('--')) positional.push(a);
    else throw new UsageError(`unknown argument ${a}`);
  }
  if (cmd === 'select') {
    if (args.refresh) args.ids = positional;
    // A spec form may hold ` › ` and spaces: the positional words are one argument.
    else args.spec = positional.join(' ');
    const modes = [Boolean(args.run), args.refresh, !args.refresh && Boolean(args.spec)].filter(Boolean).length;
    if (modes !== 1 || (args.refresh && !args.ids.length)) throw new UsageError('select takes exactly one of --run <run-id>, <spec>[ › <title>], --refresh <ID>…');
    return args;
  }
  if (positional.length !== 1) throw new UsageError(`${cmd} needs exactly one <ID>`);
  args.id = positional[0];
  if (args.refresh && !['start', 'apply'].includes(cmd)) throw new UsageError(`${cmd} takes no --refresh`);
  for (const k of NEEDS[cmd]) if (!args[k]) throw new UsageError(`${cmd} needs --${k}`);
  return args;
}

export function main(argv = process.argv.slice(2)) {
  let args;
  try { args = parseArgs(argv); } catch (err) {
    if (!(err instanceof UsageError)) throw err;
    console.error(`heal: ${err.message}\n${USAGE}`);
    return 2;
  }
  const root = path.resolve(args.root);
  if (isTeamClone(root)) { console.log('refused: a team clone never runs regression — run heal from your own checkout'); return 3; }
  try {
    return COMMANDS[args.cmd](root, args);
  } catch (err) {
    if (err instanceof UsageError) { console.error(`heal: ${err.message}`); return 2; }
    if (err instanceof Refusal) { console.log(`refused: ${err.message}`); return 1; }
    throw err;
  }
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    process.exitCode = main();
  } catch (err) {
    console.error(`heal: ${err.message}`);
    process.exitCode = 2;
  }
}
