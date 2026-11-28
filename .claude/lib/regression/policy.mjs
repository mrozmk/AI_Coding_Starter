// Selection policy of a regression run: for (catalog, config, environment, mode) which
// (scenario, runner project) cases run, which scenarios are `not run — policy: <reason>`, the run
// budget, the plan digest and the production confirmation text. Pure library + a read-only CLI
// (a dry run: it writes nothing and never issues a confirmation token — that is run.mjs's).
// Node builtins only — ships to every downstream. Contract: .agents/reference/regression.md §10.
//
// The visual part of a plan (`visualPlan`, `mode visual` and `full`) is pure config: route targets ×
// runner projects, the action and its pass count, one digest folded into the plan digest.
//
//   node .claude/lib/regression/policy.mjs [--env <name>] [--mode smoke|full|visual] [--action compare|update] [--json] [--root <dir>]
//   exit 0 = ok (or not adopted) · 2 = usage / config error / invalid catalog / no target

import fs from 'node:fs';
import path from 'node:path';
import { createHash } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import {
  CONFIG_PATH, loadConfig, envPolicy, resolveEnvBaseUrl, resolveTarget, isObject, docKey, specDir, envKind, visualSettings, runnerDevices, VISUAL_DEVICES,
} from './config.mjs';
import { loadCatalog, validateCatalog, needsKeys, specOf, statusOf, blockTexts } from './catalog.mjs';
import { lintSpec, stripComments, RETRY_NEEDLES } from './speclint.mjs';
import { redactedSamples } from './walk.mjs';

export const MODES = ['smoke', 'full', 'visual'];
export const VISUAL_ACTIONS = ['compare', 'update'];
export const VISUAL_REPEAT = { capture: 1, stability: 3, compare: 1 };
const VIEWPORT_DEVICES = { desktop: ['desktop'], mobile: ['mobile'], both: ['desktop', 'mobile'] };
/** The green passes a candidate spec needs before it may be claimed. */
export const VERIFY_PASSES = 3;

export const sha256 = (data) => createHash('sha256').update(data).digest('hex');

/** The evidence key verify records and claim re-checks: the spec, its scanned closure, its block. */
export function evidenceKey(root, spec, inputFiles, blockText) {
  return {
    spec_sha256: sha256(fs.readFileSync(path.resolve(root, spec))),
    inputs_sha256: digestFiles(root, inputFiles),
    block_sha256: sha256(blockText),
  };
}

const EVIDENCE_PARTS = { spec_sha256: 'spec', inputs_sha256: 'inputs', block_sha256: 'block' };
/** The first part (`spec` | `inputs` | `block`) where `recorded` differs from `current`, or null. */
export function changedPart(recorded, current) {
  const k = Object.keys(EVIDENCE_PARTS).find((p) => recorded?.[p] !== current[p]);
  return k ? EVIDENCE_PARTS[k] : null;
}

/**
 * The runner projects of a viewport (`desktop`, `mobile`, `both`): `[{device, project}]`, `project`
 * null when `runner.devices` names no project for that device.
 */
export function viewportProjects(cfg, viewport) {
  const devices = runnerDevices(cfg);
  return (VIEWPORT_DEVICES[viewport] ?? []).map((device) => ({ device, project: devices[device] ?? null }));
}

/** sha256 over `path\0bytes\0` of each repo-relative file, sorted by path. */
export function digestFiles(root, files) {
  const h = createHash('sha256');
  for (const f of [...files].sort()) {
    h.update(f); h.update('\0');
    h.update(fs.readFileSync(path.resolve(root, f))); h.update('\0');
  }
  return h.digest('hex');
}

/** JSON with object keys sorted at every level — the same value always yields the same bytes. */
export function canonicalJson(value) {
  if (Array.isArray(value)) return `[${value.map(canonicalJson).join(',')}]`;
  if (isObject(value)) return `{${Object.keys(value).sort().map((k) => `${JSON.stringify(k)}:${canonicalJson(value[k])}`).join(',')}}`;
  return JSON.stringify(value ?? null);
}

export const digestJson = (value) => sha256(canonicalJson(value));

/** `floor(budget × max over costed ops of (backend_calls / cost))` — 0 without a budget or a bound. */
export function worstCaseBackendCalls(budget, operations) {
  if (!(typeof budget === 'number' && budget > 0)) return 0;
  const ratios = Object.values(operations).filter((o) => o.cost > 0 && Number.isInteger(o.backend_calls)).map((o) => o.backend_calls / o.cost);
  return ratios.length ? Math.floor(budget * Math.max(...ratios)) : 0;
}

/** The reason a candidate is not run on this environment, or null when it is selected. */
export function exclusionReason(scenario, policy, envName) {
  const declared = new Set([...policy.means, ...Object.keys(policy.guard.operations)]);
  for (const k of scenario.needs) if (!declared.has(k)) return `${k} not declared for ${envName}`;
  if (policy.kind === 'production') {
    for (const k of scenario.needs) {
      const op = policy.guard.operations[k];
      if (op && op.cost !== undefined && op.backend_calls === undefined) return `${k} has no declared backend upper bound`;
    }
  }
  if (scenario.effect === 'write') {
    if (policy.writes === 'refuse') return 'writes refuse';
    if (policy.writes === 'declared' && !scenario.needs.length) return 'no safe means named';
  }
  return null;
}

/**
 * Targets × runner projects: `{cases: [{id, title, project, spec, file, source}], no_device: [{id, device}]}`.
 * A device without a runner project is `no_device`: never run, its baselines never orphans.
 */
export function expandTargets(cfg, targets) {
  const devices = runnerDevices(cfg);
  const spec = visualSettings(cfg).spec;
  const cases = [];
  const noDevice = [];
  for (const t of targets) {
    for (const d of t.devices) {
      if (devices[d]) cases.push({ id: t.id, title: t.title, project: devices[d], spec, file: t.file, source: t.source });
      else noDevice.push({ id: t.id, device: d });
    }
  }
  return { cases, no_device: noDevice };
}

/**
 * The visual part of a plan (pure — config only): route targets, their cases on the runner
 * projects, the passes of the action and the digest that binds them. Stories are enumerated at run
 * time and only on a test environment, so a production plan's digest binds every case it runs.
 */
export function visualPlan(cfg, envName, action = 'compare') {
  const s = visualSettings(cfg);
  const routes = s.routes.map((r) => ({
    id: `route:${r.id}`, source: 'routes', title: r.title, url: r.path, devices: Array.isArray(r.devices) ? r.devices : [...VISUAL_DEVICES],
    mask: Array.isArray(r.mask) ? r.mask : [], full_page: r.full_page === true, wait_for: r.wait_for ?? null, ready: null, error: null, file: `routes--${r.id}.png`,
  }));
  const { cases, no_device: noDevice } = expandTargets(cfg, routes);
  const passes = action === 'update' ? ['capture', 'stability'] : ['compare'];
  const entry = isObject(cfg?.environments) ? cfg.environments[envName] : undefined;
  const sb = envKind(entry) === 'test' && isObject(s.storybook[envName]) ? s.storybook[envName].url : null;
  const digest = digestJson({ action, passes, repeat: VISUAL_REPEAT, cases, tolerance: s.tolerance, mask: s.mask, policy: s.policy, storybook: sb });
  return { action, passes, repeat: { ...VISUAL_REPEAT }, routes, cases, no_device: noDevice, storybook: sb, policy: s.policy, digest };
}

/** PNG files under `<baselines>/<env>/` (a count for the confirmation; not part of any digest). */
function countBaselines(root, cfg, envName) {
  const dir = path.resolve(root, visualSettings(cfg).baselines, envName);
  try { return fs.readdirSync(dir, { recursive: true }).filter((f) => String(f).endsWith('.png')).length; } catch { return 0; }
}

/**
 * The plan of one run, or `{error}` / `{catalog_errors}`. Cases are (scenario, project) pairs:
 * `{id, title, project, spec, effect, needs}`. Never resolves a loopback target (resolveEnvBaseUrl refuses it).
 */
export function buildPlan(root, cfg, envName, mode = 'smoke', { configPath = CONFIG_PATH, visualAction } = {}) {
  if (!MODES.includes(mode)) return { error: `unknown mode ${mode} — expected ${MODES.join('|')}` };
  if (mode === 'visual' && !isObject(cfg?.visual)) return { error: 'visual not configured — see .claude/skills/regression/references/visual.md' };
  if (visualAction !== undefined && !VISUAL_ACTIONS.includes(visualAction)) return { error: `unknown visual action ${visualAction} — expected ${VISUAL_ACTIONS.join('|')}` };
  const t = targetOf(root, cfg, envName);
  if (t.error) return { error: t.error };
  const { policy, budget } = t;

  const { settings, files, blocks } = loadCatalog(root, cfg);
  const catalogErrors = validateCatalog(blocks, settings);
  if (catalogErrors.length) return { catalog_errors: catalogErrors };

  const cases = [];
  const excluded = [];
  const noDevice = [];
  const counted = { ready_without_spec: 0, blocked: 0, dropped: 0 };
  const smoke = new Set(settings.smoke);
  for (const b of blocks) {
    // A validated catalog: every block's Status parses.
    const [, status] = statusOf(b);
    if (status === 'BLOCKED') { counted.blocked += 1; continue; }
    if (status === 'DROPPED') { counted.dropped += 1; continue; }
    const spec = specOf(b);
    if (!spec || spec.error) { counted.ready_without_spec += 1; continue; }
    if (mode === 'visual') continue;
    if (mode === 'smoke' && !smoke.has(b.fields.Priority?.value)) continue;
    const scenario = { id: b.id, title: b.title, spec: spec.path, effect: b.fields.Effect?.value ?? 'read', needs: needsKeys(b.fields.Needs?.value) };
    const reason = exclusionReason(scenario, policy, envName);
    if (reason) { excluded.push({ id: b.id, reason }); continue; }
    for (const { device, project } of viewportProjects(cfg, b.fields.Viewport?.value)) {
      if (project === null) noDevice.push({ id: b.id, device });
      else cases.push({ ...scenario, project });
    }
  }

  const configFile = path.resolve(root, configPath);
  const digests = { config: sha256(fs.readFileSync(configFile)), catalog: digestFiles(root, files) };
  const visual = isObject(cfg.visual) && (mode === 'full' || mode === 'visual')
    ? { ...visualPlan(cfg, envName, mode === 'visual' ? visualAction ?? 'compare' : 'compare'), baselines_present: countBaselines(root, cfg, envName) }
    : undefined;
  digests.plan = digestJson({ env: envName, base_url: t.base_url, mode, config: digests.config, catalog: digests.catalog, cases, budget, visual: visual?.digest ?? null });
  return {
    env: envName, kind: policy.kind, base_url: t.base_url, mode,
    cases, scenarios: [...new Set(cases.map((c) => c.id))].length,
    excluded, no_device: noDevice, counted, budget, digests, policy,
    catalog_ids: blocks.map((b) => b.id),
    ...(visual ? { visual } : {}),
  };
}

/** The production confirmation text, one fact per line (English; the command reports in the project's language). */
export function confirmationText(plan) {
  const p = plan.policy;
  const ops = Object.entries(plan.budget.operations);
  const lines = [
    `environment: ${plan.env} (${plan.kind}) — ${plan.base_url}`,
    `config digest: ${plan.digests.config.slice(0, 12)} · catalog digest: ${plan.digests.catalog.slice(0, 12)}`,
    `mode: ${plan.mode}`,
    `${plan.cases.length} cases (${plan.scenarios} scenarios)`,
    `${plan.excluded.length} not run — policy`,
    `budget: ${plan.budget.ceiling ?? 'none'} cost units`,
    ...ops.map(([k, o]) => `  ${k}: cost ${o.cost}, backend_calls ${o.backend_calls ?? 'undeclared'}`),
    `worst case backend calls: ${plan.budget.worst_case_backend_calls}`,
    `workers: ${p.workers}`,
    `pacing: action_delay_ms ${p.pacing.action_delay_ms}, requests_per_minute ${p.pacing.requests_per_minute || 'unlimited'}`,
    `consent: ${p.consent.strategy}${p.consent.cookies.length ? '' : ' (not applied — no cookies declared)'}`,
  ];
  if (plan.visual) {
    const v = plan.visual;
    const projects = [...new Set(v.cases.map((c) => c.project))];
    lines.push(
      `visual: ${v.action} · passes ${v.passes.join(', ')}${v.passes.includes('stability') ? ` (stability ×${v.repeat.stability})` : ''} · ${v.cases.length} route cases on ${projects.join(', ') || 'no project'} · policy ${v.policy}`,
      `visual baselines: ${v.baselines_present ? `present ${v.baselines_present}` : 'none'} for ${plan.env}`,
    );
  }
  return lines.join('\n');
}

/** Target, policy and budget shared by every plan builder, or `{error}`. */
function targetOf(root, cfg, envName) {
  const entry = isObject(cfg?.environments) ? cfg.environments[envName] : undefined;
  if (!isObject(entry) || docKey(envName)) return { error: `unknown environment ${envName}` };
  const base = resolveEnvBaseUrl(root, cfg, envName);
  if (base.error) return { error: base.error };
  const policy = envPolicy(entry);
  if (!policy.guard.hosts.length) policy.guard.hosts = [new URL(base.url).hostname];
  const operations = Object.fromEntries(Object.entries(policy.guard.operations)
    .filter(([, o]) => o.cost !== undefined)
    .map(([k, o]) => [k, { cost: o.cost, backend_calls: o.backend_calls ?? null }]));
  const budget = { ceiling: policy.guard.budget, operations, worst_case_backend_calls: worstCaseBackendCalls(policy.guard.budget, operations) };
  return { base_url: base.url, policy, budget };
}

/**
 * The walk plan of a staged route list: one case `WALK<k>` per account group on the desktop
 * project (anonymous routes in one group, each `account` in its own), a group whose account is not
 * a declared means of the environment excluded by policy. `{error}` on a target or device problem.
 */
export function buildWalkPlan(root, cfg, envName, routesDoc, routesFile, { configPath = CONFIG_PATH } = {}) {
  const stub = `${specDir(cfg)}/_walk.spec.ts`;
  const t = targetOf(root, cfg, envName);
  if (t.error) return { error: t.error };
  const [{ project }] = viewportProjects(cfg, 'desktop');
  if (project === null) return { error: 'no desktop device project — the walk runs on desktop' };
  const routes = routesDoc.routes;
  const accounts = [...new Set(routes.map((r) => r.account ?? null))].sort((a, b) => (a === null ? -1 : b === null ? 1 : a < b ? -1 : 1));
  const groups = [];
  const excluded = [];
  const cases = [];
  accounts.forEach((account, i) => {
    const key = `WALK${i + 1}`;
    const keys = routes.filter((r) => (r.account ?? null) === account).map((r) => r.route);
    const g = { key, account, routes: keys };
    if (account !== null && !t.policy.means.includes(`account:${account}`)) {
      const reason = `account:${account} not declared for ${envName}`;
      excluded.push({ group: key, account, reason, routes: keys });
      groups.push({ ...g, excluded: reason });
      return;
    }
    groups.push({ ...g, excluded: null });
    cases.push({ id: key, title: `${key} — ${account ?? 'anonymous'}`, project, spec: stub, effect: 'read', needs: account ? [`account:${account}`] : [] });
  });
  const submits = routes.flatMap((r) => (r.submit ?? []).map((s) => ({ route: r.route, form: s.form, action: s.action, inputs: Object.keys(s.inputs ?? {}) })));
  const { files } = loadCatalog(root, cfg);
  const digests = {
    config: sha256(fs.readFileSync(path.resolve(root, configPath))),
    catalog: digestFiles(root, files),
    routes: sha256(fs.readFileSync(path.resolve(root, routesFile))),
  };
  digests.plan = digestJson({ env: envName, base_url: t.base_url, mode: 'walk', config: digests.config, routes: digests.routes, cases, budget: t.budget });
  const walked = groups.filter((g) => !g.excluded).map(({ key, account, routes: r }) => ({ key, account, routes: r }));
  return {
    env: envName, kind: t.policy.kind, base_url: t.base_url, mode: 'walk',
    cases, scenarios: cases.length, groups, excluded: excluded.map((e) => ({ id: e.group, reason: e.reason })), excluded_groups: excluded,
    no_device: [], submits, redacted_samples: redactedSamples(routes, t.policy.redact),
    budget: t.budget, digests, policy: t.policy, catalog_ids: cases.map((c) => c.id),
    walk: { groups: walked, routes, redact: t.policy.redact, caps: { aria_chars: 8000, links: 200 }, timeout_ms: Math.max(60000, routes.length * 20000) },
    textFn: walkConfirmationText,
  };
}

/** `retries are not 0 — <config|command>`, or null: every retries in the runner config is a literal 0. */
export function retriesProblem(root, cfg) {
  let text = '';
  try { text = stripComments(fs.readFileSync(path.resolve(root, cfg.runner.config), 'utf8')); } catch { text = ''; }
  const values = [...text.matchAll(/\bretries\s*:\s*([^,}\n]*)/g)].map((m) => m[1].trim());
  if (values.some((v) => v !== '0')) return 'retries are not 0 — config';
  if (/--retries\b/.test(String(cfg.runner.commands?.full ?? ''))) return 'retries are not 0 — command';
  return null;
}

/**
 * Why scenario block `b` may not get a spec on this target, or null: not READY, a Spec already, the
 * environment policy (`policy` null skips it), a viewport with no device project. Shared by
 * `author.mjs select` and the verify plan.
 */
export function candidateProblem(cfg, b, policy, envName) {
  const [, status] = statusOf(b);
  if (status !== 'READY') return `not READY (${b.fields.Status?.value})`;
  if (specOf(b) !== null) return 'already has a spec';
  if (policy) {
    const reason = exclusionReason({ id: b.id, needs: needsKeys(b.fields.Needs?.value), effect: b.fields.Effect?.value ?? 'read' }, policy, envName);
    if (reason) return reason;
  }
  const noDevice = viewportProjects(cfg, b.fields.Viewport?.value).find((d) => d.project === null);
  return noDevice ? `no device ${noDevice.device}` : null;
}

/**
 * The verify plan of candidate specs (`pairs = [{id, spec}]`): three passes of `runner.commands.full`
 * over the cases of READY, spec-less, policy-eligible scenarios whose candidate passes the lint.
 * Refusals in `refused` (the run stops before any confirmation, lock or runner); `scenarios`
 * carries the evidence key `{spec_sha256, inputs_sha256, block_sha256}` bound into the digest.
 */
export function buildVerifyPlan(root, cfg, envName, pairs, { configPath = CONFIG_PATH } = {}) {
  const t = targetOf(root, cfg, envName);
  if (t.error) return { error: t.error };
  const { settings, files, blocks } = loadCatalog(root, cfg);
  const catalogErrors = validateCatalog(blocks, settings);
  if (catalogErrors.length) return { catalog_errors: catalogErrors };
  const texts = blockTexts(root, files);
  const refused = [];
  const cases = [];
  const scenarios = [];
  const retries = retriesProblem(root, cfg);
  for (const { id, spec } of pairs) {
    const b = blocks.find((x) => x.id === id);
    const needs = b ? needsKeys(b.fields.Needs?.value) : [];
    const devices = b ? viewportProjects(cfg, b.fields.Viewport?.value) : [];
    let lint = null;
    const why = (() => {
      if (!b) return 'not in the catalog';
      const candidate = candidateProblem(cfg, b, t.policy, envName);
      if (candidate) return candidate;
      const dataAccounts = [...String(b.fields.Data?.value ?? '').matchAll(/\baccount:([a-z0-9][a-z0-9_-]*)/g)].map((m) => m[1]);
      const missing = dataAccounts.find((k) => !needs.includes(`account:${k}`));
      if (missing) return `account ${missing} in Data but not in Needs`;
      if (!fs.existsSync(path.resolve(root, spec))) return `spec file absent — ${spec}`;
      if (retries) return retries;
      lint = lintSpec(root, cfg, spec, id);
      if (lint.violations.some((v) => RETRY_NEEDLES.includes(v.needle))) return 'retries are not 0 — spec';
      if (lint.violations.length) return `lint: ${lint.violations[0].rule}`;
      return null;
    })();
    if (why) { refused.push({ id, reason: why }); continue; }
    const projects = devices.map((d) => d.project);
    for (const project of projects) cases.push({ id, title: b.title, project, spec, effect: b.fields.Effect?.value ?? 'read', needs });
    scenarios.push({ id, spec, projects, needs, ...evidenceKey(root, spec, lint.files, texts.get(id).text) });
  }
  const digests = { config: sha256(fs.readFileSync(path.resolve(root, configPath))), catalog: digestFiles(root, files) };
  digests.plan = digestJson({ env: envName, base_url: t.base_url, mode: 'verify', config: digests.config, catalog: digests.catalog, cases, scenarios, budget: t.budget, repeats: VERIFY_PASSES });
  return {
    env: envName, kind: t.policy.kind, base_url: t.base_url, mode: 'verify',
    cases, scenarios_list: scenarios, scenarios: scenarios.length, refused, excluded: [], no_device: [], repeats: VERIFY_PASSES,
    budget: t.budget, digests, policy: t.policy, catalog_ids: blocks.map((x) => x.id),
    textFn: verifyConfirmationText,
  };
}

/** The walk's confirmation: the run lines plus routes, groups and every submit entry. */
export function walkConfirmationText(plan) {
  const submits = plan.submits.map((s) => `${s.route} ${s.form} ${s.action} ${s.inputs.join(',')}`).join(' · ') || 'none';
  return `${confirmationText(plan)}\nroutes: ${plan.walk.routes.length} · groups: ${plan.cases.map((c) => c.id).join(',') || 'none'} · submit entries: ${submits}`;
}

/** The verify confirmation: the run lines plus the three passes it covers. */
export function verifyConfirmationText(plan) {
  return `${confirmationText(plan)}\nrepeats: ${plan.repeats} passes over ${plan.cases.length} cases (${plan.scenarios_list.map((s) => s.id).join(', ')})`;
}

function renderPlan(plan) {
  const out = [`plan: ${plan.env} (${plan.kind}) ${plan.base_url} · mode ${plan.mode}`];
  out.push(`selected: ${plan.cases.length} cases (${plan.scenarios} scenarios)`);
  for (const c of plan.cases) out.push(`  ${c.id} · ${c.project} · ${c.spec}`);
  for (const e of plan.excluded) out.push(`not run — policy: ${e.id} — ${e.reason}`);
  for (const n of plan.no_device) out.push(`not run — no device: ${n.id} (${n.device})`);
  out.push(`counted, not run: ${plan.counted.ready_without_spec} READY without spec · ${plan.counted.blocked} BLOCKED · ${plan.counted.dropped} DROPPED`);
  if (plan.visual) {
    out.push(`visual: ${plan.visual.action} · ${plan.visual.cases.length} route cases${plan.visual.storybook ? ` · stories enumerated at run time from ${plan.visual.storybook}` : ''}`);
    for (const c of plan.visual.cases) out.push(`  ${c.id} · ${c.project} · ${c.file}`);
    for (const n of plan.visual.no_device) out.push(`not run — no device: ${n.id} (${n.device})`);
  }
  if (plan.kind === 'production') out.push('confirmation (run.mjs asks for it with a single-use token):', confirmationText(plan));
  return out.join('\n');
}

class UsageError extends Error {}
const USAGE = 'usage: node .claude/lib/regression/policy.mjs [--env <name>] [--mode smoke|full|visual] [--action compare|update] [--json] [--root <dir>]';

function parseArgs(argv) {
  const args = { root: process.cwd(), env: undefined, mode: 'smoke', action: undefined, json: false };
  for (let i = 0; i < argv.length; i += 1) {
    const a = argv[i];
    if (a === '--json') args.json = true;
    else if (a === '--env' || a === '--mode' || a === '--root' || a === '--action') {
      if (i + 1 >= argv.length) throw new UsageError(`${a} needs a value`);
      args[a.slice(2)] = argv[++i];
    } else throw new UsageError(`unknown argument ${a}`);
  }
  if (!MODES.includes(args.mode)) throw new UsageError(`unknown mode ${args.mode}`);
  if (args.action !== undefined && (args.mode !== 'visual' || !VISUAL_ACTIONS.includes(args.action))) throw new UsageError('--action compare|update goes with --mode visual');
  return args;
}

export function main(argv = process.argv.slice(2)) {
  let args;
  try { args = parseArgs(argv); } catch (err) {
    if (!(err instanceof UsageError)) throw err;
    console.error(`policy: ${err.message}\n${USAGE}`);
    return 2;
  }
  const root = path.resolve(args.root);
  const loaded = loadConfig(root);
  if (!loaded.adopted) { console.log('regression not adopted'); return 0; }
  if (loaded.errors.length) {
    for (const e of loaded.errors) console.error(`policy: ${CONFIG_PATH}: ${e}`);
    return 2;
  }
  const target = resolveTarget(loaded.config, args.env);
  if (target.error) {
    console.error(`policy: ${target.error}`);
    console.error(`environments: ${target.names.join(', ') || '(none)'}`);
    return 2;
  }
  const plan = buildPlan(root, loaded.config, target.name, args.mode, { visualAction: args.action });
  if (plan.catalog_errors) {
    for (const e of plan.catalog_errors) console.error(`${e.file}:${e.line}: ${e.message}`);
    return 2;
  }
  if (plan.error) { console.error(`policy: ${plan.error}`); return 2; }
  console.log(args.json ? JSON.stringify(plan, null, 2) : renderPlan(plan));
  return 0;
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    process.exitCode = main();
  } catch (err) {
    console.error(`policy: ${err.message}`);
    process.exitCode = 2;
  }
}
