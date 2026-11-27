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
  CONFIG_PATH, loadConfig, envPolicy, resolveEnvBaseUrl, resolveTarget, catalogSettings, isObject, docKey, envKind, visualSettings, runnerDevices, VISUAL_DEVICES,
} from './config.mjs';
import { catalogFiles, parseCatalog, validateCatalog, needsKeys, parseSpec, statusOf } from './catalog.mjs';

export const MODES = ['smoke', 'full', 'visual'];
export const VISUAL_ACTIONS = ['compare', 'update'];
export const VISUAL_REPEAT = { capture: 1, stability: 3, compare: 1 };
const VIEWPORT_DEVICES = { desktop: ['desktop'], mobile: ['mobile'], both: ['desktop', 'mobile'] };

export const sha256 = (data) => createHash('sha256').update(data).digest('hex');

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
  const entry = isObject(cfg?.environments) ? cfg.environments[envName] : undefined;
  if (!isObject(entry) || docKey(envName)) return { error: `unknown environment ${envName}` };
  const base = resolveEnvBaseUrl(root, cfg, envName);
  if (base.error) return { error: base.error };
  const policy = envPolicy(entry);
  if (!policy.guard.hosts.length) policy.guard.hosts = [new URL(base.url).hostname];

  const settings = catalogSettings(cfg);
  const files = catalogFiles(root, settings);
  const blocks = parseCatalog(root, files);
  const catalogErrors = validateCatalog(blocks, settings);
  if (catalogErrors.length) return { catalog_errors: catalogErrors };

  const devices = runnerDevices(cfg);
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
    const spec = parseSpec(b.fields.Spec?.value ?? '—', b.id);
    if (!spec || spec.error) { counted.ready_without_spec += 1; continue; }
    if (mode === 'visual') continue;
    if (mode === 'smoke' && !smoke.has(b.fields.Priority?.value)) continue;
    const scenario = { id: b.id, title: b.title, spec: spec.path, effect: b.fields.Effect?.value ?? 'read', needs: needsKeys(b.fields.Needs?.value) };
    const reason = exclusionReason(scenario, policy, envName);
    if (reason) { excluded.push({ id: b.id, reason }); continue; }
    for (const device of VIEWPORT_DEVICES[b.fields.Viewport?.value] ?? []) {
      const project = devices[device];
      if (!project) noDevice.push({ id: b.id, device });
      else cases.push({ ...scenario, project });
    }
  }

  const operations = Object.fromEntries(Object.entries(policy.guard.operations)
    .filter(([, o]) => o.cost !== undefined)
    .map(([k, o]) => [k, { cost: o.cost, backend_calls: o.backend_calls ?? null }]));
  const budget = { ceiling: policy.guard.budget, operations, worst_case_backend_calls: worstCaseBackendCalls(policy.guard.budget, operations) };
  const configFile = path.resolve(root, configPath);
  const digests = { config: sha256(fs.readFileSync(configFile)), catalog: digestFiles(root, files) };
  const visual = isObject(cfg.visual) && (mode === 'full' || mode === 'visual')
    ? { ...visualPlan(cfg, envName, mode === 'visual' ? visualAction ?? 'compare' : 'compare'), baselines_present: countBaselines(root, cfg, envName) }
    : undefined;
  digests.plan = digestJson({ env: envName, base_url: base.url, mode, config: digests.config, catalog: digests.catalog, cases, budget, visual: visual?.digest ?? null });
  return {
    env: envName, kind: policy.kind, base_url: base.url, mode,
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
