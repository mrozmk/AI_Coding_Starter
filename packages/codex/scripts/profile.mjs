#!/usr/bin/env node
// Project profile access (contract 3, 4, 6; T03): canonical `.agents/project-profile.json` (schema 2),
// legacy `.claude/project-profile.json` (schema 1) read/written in place with the new fields under
// `harness`, conflict detection over every shared behavioral fact, consent-gated atomic updates
// validated whole before any write, explicit roots. A missing, invalid or conflicting profile is a
// blocking state: it never yields enabled groups.
//
//   node scripts/profile.mjs read   --project-root <dir>
//   node scripts/profile.mjs set    --project-root <dir> --key workflow.protected --value '["main"]' --consent yes
//   node scripts/profile.mjs apply  --project-root <dir> --changes '{"language":"pl","groups.review":true}' --consent yes [--create yes]
//   node scripts/profile.mjs groups --project-root <dir>
//   node scripts/profile.mjs check-version --project-root <dir> --host claude [--plugin-root <dir>]
//   node scripts/profile.mjs bind   --project-root <dir> --host claude --plugin-root <installed root>
//   node scripts/profile.mjs migrate-binding --project-root <dir> [--consent yes]
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { parseArgv, requireOpt } from './lib/argv.mjs';
import { readJson, realpathOrSelf } from './lib/fsx.mjs';
import { verifyPackageRoot, resolveBoundRoot, writeReceipt, migrateReceipt, RECEIPT } from './lib/locator.mjs';
import { validate } from './lib/schema.mjs';

export const CANONICAL = '.agents/project-profile.json';
export const LEGACY = '.claude/project-profile.json';
export const HARNESS_KEYS = ['author_host', 'roles', 'planning', 'groups'];

export const DEFAULT_ROLES = {
  executor: { model: 'opus', effort: 'medium' },
  reviewer: {
    claude: { model: 'fable', effort: 'high' },
    codex: { model: 'gpt-6-astra', effort: 'high' },
  },
};
export const DEFAULT_GROUPS = { planning: true, review: true, execution: false, git: true, tracker: false, confluence: false };
const NO_GROUPS = Object.fromEntries(Object.keys(DEFAULT_GROUPS).map((g) => [g, false]));

// Every fact that changes behavior on either host. Two physical profiles disagreeing on any of
// these is a conflict; a difference in a purely descriptive key is not.
export const SHARED_KEYS = [
  'language', 'mode', 'git_host', 'tracker', 'confluence', 'codex', 'app_surface', 'author_host',
  'workflow.preset', 'workflow.pr_required', 'workflow.protected', 'workflow.orchestrate_publish', 'workflow.merge', 'workflow.trunk', 'workflow.integration', 'workflow.branch_pattern', 'workflow.branch_types', 'workflow.pr_dest',
  'planning.after_brainstorm', 'groups', 'roles',
];

// Legacy schema-1 `commands.*` answers mirrored from the shared facts when writing that file.
const LEGACY_MIRRORS = { codex: 'commands.codex', confluence: 'commands.confluence' };

function schemaPath() {
  return path.join(path.dirname(fileURLToPath(import.meta.url)), '..', 'schemas', 'project-profile.schema.json');
}

function get(obj, dotted) {
  return dotted.split('.').reduce((o, k) => (o == null ? undefined : o[k]), obj);
}

function set(obj, dotted, value) {
  const keys = dotted.split('.');
  let cur = obj;
  for (const k of keys.slice(0, -1)) {
    if (cur[k] == null || typeof cur[k] !== 'object') cur[k] = {};
    cur = cur[k];
  }
  cur[keys.at(-1)] = value;
}

// `kind` says which file holds the data; `shape` says which schema its bytes follow. A symlinked
// pair reads a schema-1 body through the canonical path, so the shape comes from the bytes.
function shapeOf(raw) {
  return raw?.schema === 1 ? 'legacy' : 'canonical';
}

// Normalized view: schema-2 shape regardless of which physical file holds the data.
function viewOf(raw) {
  if (shapeOf(raw) === 'canonical') return structuredClone(raw);
  const view = structuredClone(raw);
  delete view.harness;
  for (const k of HARNESS_KEYS) if (raw.harness?.[k] !== undefined) view[k] = structuredClone(raw.harness[k]);
  view.schema = 2;
  return view;
}

// Cross-field rules the JSON schema cannot express. Each one names a real contradiction.
export function semanticErrors(view) {
  const errors = [];
  const groups = { ...DEFAULT_GROUPS, ...(view.groups ?? {}) };
  const other = view.author_host === 'claude' ? 'codex' : view.author_host === 'codex' ? 'claude' : null;
  if (groups.review && view.author_host === 'claude' && view.codex === false) errors.push('groups.review is true but codex is false — an independent review of a Claude author needs the Codex CLI; enable codex or disable the review group explicitly');
  if (groups.review && other && view.roles?.reviewer?.[other] && !view.roles.reviewer[other].model) errors.push(`roles.reviewer.${other}.model is required while groups.review is true`);
  if (groups.tracker && (view.tracker ?? 'none') === 'none') errors.push('groups.tracker is true but tracker is none');
  if (groups.confluence && view.confluence === false) errors.push('groups.confluence is true but confluence is false');
  const wf = view.workflow ?? {};
  if (wf.pr_required === true && wf.orchestrate_publish === 'push') errors.push('workflow.pr_required is true but orchestrate_publish is push — a PR-gated project must publish branch-local');
  if (Array.isArray(wf.protected) && wf.trunk && wf.protected.includes(wf.trunk) && wf.orchestrate_publish === 'push') errors.push(`workflow.protected names the trunk ${wf.trunk} but orchestrate_publish is push`);
  if (view.commands && typeof view.commands === 'object') {
    for (const [fact, mirror] of Object.entries(LEGACY_MIRRORS)) {
      const m = get(view, mirror);
      if (view[fact] !== undefined && m !== undefined && m !== view[fact]) errors.push(`${mirror} (${m}) disagrees with ${fact} (${view[fact]})`);
    }
  }
  return errors;
}

export function validateView(view) {
  return [...validate(readJson(schemaPath()), view), ...semanticErrors(view)];
}

export function resolvePluginRoot(explicit) {
  const root = explicit ? path.resolve(explicit) : path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
  if (!fs.existsSync(path.join(root, 'harness-build.json'))) {
    return { ok: false, root, error: `plugin root has no harness-build.json: ${root} (running from a checkout is not an installation)` };
  }
  return { ok: true, root };
}

function readRaw(file) {
  try { return { raw: readJson(file) }; } catch (e) { return { error: `${path.basename(file)}: ${e.message}` }; }
}

export function readProfile(projectRoot) {
  const root = path.resolve(projectRoot);
  const canonicalPath = path.join(root, CANONICAL);
  const legacyPath = path.join(root, LEGACY);
  const hasCanonical = fs.existsSync(canonicalPath);
  const hasLegacy = fs.existsSync(legacyPath);
  if (!hasCanonical && !hasLegacy) {
    return { status: 'missing', projectRoot: root, view: null, errors: [], message: 'no project profile — run setup-start (interview); nothing is inferred from installed tools' };
  }
  if (hasCanonical && hasLegacy && realpathOrSelf(canonicalPath) !== realpathOrSelf(legacyPath)) {
    const c = readRaw(canonicalPath);
    const l = readRaw(legacyPath);
    if (c.error || l.error) return { status: 'invalid', projectRoot: root, view: null, errors: [c.error, l.error].filter(Boolean), message: 'profile file unreadable' };
    const canonical = c.raw;
    const legacy = viewOf(l.raw);
    // Behavioral facts with defaults are compared as EFFECTIVE values: a `groups.review=false`
    // recorded in one file and simply absent from the other is a lost decision, not agreement.
    const effectiveOf = (v) => ({ groups: { ...DEFAULT_GROUPS, ...(v.groups ?? {}) }, roles: { executor: v.roles?.executor ?? DEFAULT_ROLES.executor, reviewer: { claude: v.roles?.reviewer?.claude ?? DEFAULT_ROLES.reviewer.claude, codex: v.roles?.reviewer?.codex ?? DEFAULT_ROLES.reviewer.codex } }, 'planning.after_brainstorm': v.planning?.after_brainstorm ?? 'stop' });
    const effC = effectiveOf(canonical);
    const effL = effectiveOf(legacy);
    const differences = SHARED_KEYS.filter((k) => {
      if (k in effC) return JSON.stringify(effC[k]) !== JSON.stringify(effL[k]);
      return get(canonical, k) !== undefined && get(legacy, k) !== undefined && JSON.stringify(get(canonical, k)) !== JSON.stringify(get(legacy, k));
    });
    if (differences.length) {
      return { status: 'conflict', projectRoot: root, files: [CANONICAL, LEGACY], differences, view: null, errors: [], message: `two profiles disagree on ${differences.join(', ')} — resolve by hand before any write` };
    }
    return finish('canonical', canonicalPath, canonical, root, { alsoLegacy: true });
  }
  const file = hasCanonical ? canonicalPath : legacyPath;
  const r = readRaw(file);
  if (r.error) return { status: 'invalid', projectRoot: root, file, view: null, errors: [r.error], message: 'profile file unreadable' };
  return finish(hasCanonical ? 'canonical' : 'legacy', file, r.raw, root);
}

function finish(kind, file, raw, root, extra = {}) {
  const view = viewOf(raw);
  const errors = validateView(view);
  const status = errors.length ? 'invalid' : 'ok';
  return { status, kind, file, raw, view, projectRoot: root, errors, message: errors.length ? `profile invalid: ${errors.join('; ')}` : undefined, ...extra };
}

// Effective settings (contract 4/6). Only an `ok` profile yields enabled groups; every other state
// reports `blocked` with the reason so a caller cannot mistake a missing profile for consent.
export function effective(profile) {
  const ok = profile?.status === 'ok';
  const view = ok ? profile.view : {};
  return {
    status: profile?.status ?? 'missing',
    blocked: ok ? null : (profile?.message ?? 'no project profile'),
    language: view.language ?? 'en',
    author_host: view.author_host ?? null,
    after_brainstorm: view.planning?.after_brainstorm ?? 'stop',
    roles: {
      executor: view.roles?.executor ?? DEFAULT_ROLES.executor,
      reviewer: {
        claude: view.roles?.reviewer?.claude ?? DEFAULT_ROLES.reviewer.claude,
        codex: view.roles?.reviewer?.codex ?? DEFAULT_ROLES.reviewer.codex,
      },
    },
    groups: ok ? { ...DEFAULT_GROUPS, ...(view.groups ?? {}) } : { ...NO_GROUPS },
  };
}

export function groupEnabled(profile, group) {
  return effective(profile).groups[group] === true;
}

// Synthetic profile for offline probes and tests. Never read from disk; the caller states it.
export function syntheticProfile(overrides = {}) {
  return { status: 'ok', kind: 'synthetic', file: null, raw: null, errors: [], view: { schema: 2, language: 'en', author_host: 'claude', groups: { planning: true, review: true }, ...overrides } };
}

function atomicWriteJson(file, value) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  const tmp = `${file}.tmp-${process.pid}`;
  fs.writeFileSync(tmp, `${JSON.stringify(value, null, 2)}\n`);
  fs.renameSync(tmp, file);
}

// Consent-gated, atomic update. `changes` maps dotted keys to JSON values (arrays and objects
// included). The whole resulting profile is validated before anything is written.
export function updateProfile(projectRoot, changes, { consent = false, create = false } = {}) {
  const current = readProfile(projectRoot);
  if (current.status === 'conflict') throw new Error(current.message);
  if (current.status === 'invalid' && !current.raw) throw new Error(current.message);
  let kind = current.kind;
  let file = current.file;
  let raw = current.raw;
  if (current.status === 'missing') {
    if (!create) throw new Error('no profile exists; pass create=true after the setup interview');
    kind = 'canonical';
    file = path.join(path.resolve(projectRoot), CANONICAL);
    raw = { schema: 2 };
  }
  if (!changes || typeof changes !== 'object' || Array.isArray(changes)) throw new Error('changes must be an object of dotted keys');
  const next = structuredClone(raw);
  const shape = shapeOf(raw);
  for (const [key, value] of Object.entries(changes)) {
    const top = key.split('.')[0];
    const target = shape === 'legacy' && HARNESS_KEYS.includes(top) ? `harness.${key}` : key;
    set(next, target, value);
    if (shape === 'legacy' && LEGACY_MIRRORS[key] && next.commands && typeof next.commands === 'object') set(next, LEGACY_MIRRORS[key], value);
  }
  if (shape === 'legacy') next.schema = 1;
  const view = viewOf(next);
  const errors = validateView(view);
  if (errors.length) throw new Error(`profile update rejected:\n  ${errors.join('\n  ')}`);
  const preview = { file: path.relative(path.resolve(projectRoot), file), kind, before: raw, after: next };
  if (!consent) return { written: false, preview };
  atomicWriteJson(file, next);
  return { written: true, preview };
}

export function checkVersion({ projectRoot, host, pluginRoot }) {
  const bound = resolveBoundRoot(projectRoot, host);
  if (!bound.ok) return { ok: false, errors: bound.errors };
  if (pluginRoot) {
    const here = verifyPackageRoot(pluginRoot, { host });
    if (!here.ok) return { ok: false, errors: here.errors };
    if (here.marker.payload_digest !== bound.marker.payload_digest) {
      const error = `running from ${here.root} (payload ${here.marker.payload_digest.slice(0, 12)}…) but the project is bound to ${bound.root} (payload ${bound.marker.payload_digest.slice(0, 12)}…) — re-bind or use the bound installation`;
      // A different VERSION of the same plugin is an update the host adopted (auto-update); the
      // project pin stays until the operator binds it — reported, never applied here. The same
      // version with other bytes is not an update and gets no such hint.
      const upgrade = here.marker.name === bound.marker.name && here.marker.version !== bound.marker.version
        ? { from: bound.marker.version, to: here.marker.version, root: here.root, adopt: `node ${here.root}/scripts/profile.mjs bind --project-root ${projectRoot} --host ${host} --plugin-root ${here.root}` }
        : null;
      return { ok: false, errors: [error], ...(upgrade && { upgrade }) };
    }
    // Same release bytes from another directory (a host may run a local-marketplace plugin from its
    // source path while the registry names the cache copy): the binding is to the release, so it holds.
    if (realpathOrSelf(here.root) !== realpathOrSelf(bound.root)) {
      return { ok: true, root: bound.root, alternate_root: here.root, version: bound.marker.version, source_digest: bound.marker.source_digest, migration_needed: bound.migration_needed === true, note: `loaded from ${here.root}; identical payload to the bound ${bound.root}` };
    }
  }
  return { ok: true, root: bound.root, version: bound.marker.version, source_digest: bound.marker.source_digest, migration_needed: bound.migration_needed === true, note: bound.note };
}

export function bindInstalledRoot({ projectRoot, host, pluginRoot, consent = true }) {
  const check = verifyPackageRoot(pluginRoot, { host });
  if (!check.ok) return { ok: false, errors: check.errors };
  const r = writeReceipt(projectRoot, host, check, { consent });
  return { ok: true, written: r.written === true, root: check.root, version: check.marker.version, payload_digest: check.marker.payload_digest, receipt: RECEIPT, expected: r.receipt.hosts[host], local: r.state?.hosts?.[host] ?? null };
}

function parseValue(raw) {
  if (raw === true) throw new Error('--value needs a value');
  try { return JSON.parse(raw); } catch { return raw; }
}

function main() {
  const { opts, positionals } = parseArgv(process.argv.slice(2));
  const cmd = positionals[0];
  const projectRoot = requireOpt(opts, 'project-root');
  if (cmd === 'read') {
    const p = readProfile(projectRoot);
    console.log(JSON.stringify({ status: p.status, kind: p.kind, file: p.file, message: p.message, differences: p.differences, errors: p.errors, effective: effective(p), view: p.view }, null, 2));
    process.exit(p.status === 'ok' ? 0 : 2);
  }
  if (cmd === 'groups') {
    const p = readProfile(projectRoot);
    const eff = effective(p);
    console.log(JSON.stringify({ status: eff.status, blocked: eff.blocked, groups: eff.status === 'ok' ? eff.groups : null }, null, 2));
    process.exit(eff.status === 'ok' ? 0 : 2);
  }
  if (cmd === 'set' || cmd === 'apply') {
    const changes = cmd === 'set'
      ? { [requireOpt(opts, 'key')]: parseValue(requireOpt(opts, 'value')) }
      : opts['changes-file'] ? readJson(String(opts['changes-file'])) : JSON.parse(String(requireOpt(opts, 'changes')));
    const res = updateProfile(projectRoot, changes, { consent: opts.consent === 'yes', create: opts.create === 'yes' });
    console.log(JSON.stringify(res, null, 2));
    if (!res.written) console.error('preview only — re-run with --consent yes after the user confirms');
    return;
  }
  if (cmd === 'check-version') {
    const res = checkVersion({ projectRoot, host: requireOpt(opts, 'host'), pluginRoot: opts['plugin-root'] });
    console.log(JSON.stringify(res, null, 2));
    process.exit(res.ok ? 0 : 1);
  }
  if (cmd === 'migrate-binding') {
    const res = migrateReceipt(projectRoot, { consent: opts.consent === 'yes' });
    console.log(JSON.stringify(res, null, 2));
    if (!res.migrated) console.error(res.reason ?? 'preview only — re-run with --consent yes to split the schema-1 receipt');
    process.exit(res.ok ? 0 : 1);
  }
  if (cmd === 'bind') {
    const res = bindInstalledRoot({ projectRoot, host: requireOpt(opts, 'host'), pluginRoot: requireOpt(opts, 'plugin-root') });
    console.log(JSON.stringify(res, null, 2));
    process.exit(res.ok ? 0 : 1);
  }
  throw new Error(`unknown command ${cmd}; use read | set | apply | groups | check-version | bind | migrate-binding`);
}

if (process.argv[1] && fileURLToPath(import.meta.url) === realpathOrSelf(process.argv[1])) {
  try {
    main();
  } catch (err) {
    console.error(`profile: ${err.message}`);
    process.exit(1);
  }
}
