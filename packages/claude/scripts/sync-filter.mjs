#!/usr/bin/env node
// Migration-aware filters for /maintain:sync-from-starter (installation.md → Migration record; T13).
// Pure functions over the sync manifest (.claude/.starter-sync.json): which candidate paths get
// no task, how a configuration union skips migrated identities AND entries a disabled profile group
// owns, what an activation would replace (one owner per command/hook), what a rollback restores,
// and when a migration may be recorded (only after a verified replacement).
//   node scripts/sync-filter.mjs tasks      --manifest <file> --candidates <json-array-file>
//   node scripts/sync-filter.mjs union      --manifest <file> --ours <settings.json> --theirs <settings.json> [--project-root <dir>]
//   node scripts/sync-filter.mjs activation --manifest <file> --settings <settings.json> --plugin-hooks <hooks.json> --release <version>
//   node scripts/sync-filter.mjs rollback   --manifest <file> --release <version>
//   node scripts/sync-filter.mjs snapshot   --settings <settings.json> --hooks-dir <dir> --hooks <id,id> [--project-root <dir>] [--write yes]
//   node scripts/sync-filter.mjs activation-record --record <file> --host <h> --hook <id> --release <v> --decision <d> --evidence <path> [--rationale <text>] [--previous <file>] [--observed <state>] [--write yes]
// Works from a starter checkout (harness-source/scripts/) as well as from an installed plugin —
// a legacy-only downstream needs no plugin to sync.
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { parseArgv, requireOpt } from './lib/argv.mjs';
import { sha256Hex } from './lib/digest.mjs';
import { readJson, realpathOrSelf } from './lib/fsx.mjs';
// The pure normalization contract only — never resolveHookConfig. The preview must read `disabled`
// exactly as the runner does, but it is a sync tool and does not resolve a project's runtime config.
import { normalizeDisabled } from './lib/hook-config.mjs';
import { validate } from './lib/schema.mjs';
import { renderWrapper } from './lib/wrapper.mjs';

const activationSchemaFile = path.join(path.dirname(fileURLToPath(import.meta.url)), '..', 'schemas', 'hook-activation.schema.json');

export function loadManifest(file) {
  const m = readJson(file);
  return { ...m, excluded: m.excluded ?? [], migrated: m.migrated ?? [], migrated_config: m.migrated_config ?? [] };
}

function prefixMatch(rule, candidate) {
  return rule.endsWith('/') ? candidate.startsWith(rule) : candidate === rule;
}

// One decision per candidate path: `task` (normal sync task), `excluded` (pruned by setup), or
// `migrated` (replaced by the plugin — an intentional deletion in 3-way terms, never re-offered).
export function filterTasks(manifest, candidates) {
  const decisions = [];
  for (const c of candidates) {
    const rel = typeof c === 'string' ? c : c.path;
    const migrated = manifest.migrated.find((m) => prefixMatch(m.path, rel));
    if (migrated) { decisions.push({ path: rel, decision: 'migrated', reason: `replaced by ${migrated.replaced_by} in release ${migrated.release}${migrated.deleted ? ' (intentional deletion)' : ''}` }); continue; }
    if (manifest.excluded.some((e) => prefixMatch(e, rel))) { decisions.push({ path: rel, decision: 'excluded', reason: 'pruned by /setup:start' }); continue; }
    decisions.push({ path: rel, decision: 'task', reason: typeof c === 'string' ? 'differs from upstream' : (c.verdict ?? 'differs from upstream') });
  }
  return decisions;
}

// Three-way verdict for one path, migration-aware. `base`/`ours`/`theirs` are content strings or null.
export function threeWayVerdict(manifest, rel, { base, ours, theirs }) {
  const migrated = manifest.migrated.find((m) => prefixMatch(m.path, rel));
  if (migrated && ours === null) return { verdict: 'intentional-deletion', action: 'none', reason: `migrated to ${migrated.replaced_by}; local absence is deliberate` };
  if (migrated) return { verdict: 'migrated-but-present', action: 'flag', reason: 'recorded as migrated yet still present locally — finish the migration or drop the record' };
  if (base === null && theirs !== null && ours === null) return { verdict: 'new', action: 'add' };
  if (theirs === null && base !== null) return ours === base ? { verdict: 'safe-upstream-deletion', action: 'offer-remove' } : { verdict: 'deleted-upstream-locally-edited', action: 'flag' };
  if (ours === base && theirs !== base) return { verdict: 'clean-upstream-update', action: 'overwrite' };
  if (ours !== base && theirs === base) return { verdict: 'local-customization', action: 'keep' };
  if (ours !== base && theirs !== base && ours !== theirs) return { verdict: 'conflict', action: 'ask' };
  return { verdict: 'identical', action: 'none' };
}

export function hookIdentity(event, matcher, command) {
  return `${event}|${matcher ?? ''}|${command}`;
}

function migratedIdentities(manifest, file, kind) {
  return new Set(manifest.migrated_config.filter((m) => m.file === file && (!kind || m.kind === kind)).map((m) => m.identity));
}

// Entries a disabled profile group owns (the documented rules of the sync playbook). A profile is
// the schema-2 view (or null → nothing is disabled). Each rule names the entry it would drop.
export function disabledByProfile(view) {
  if (!view) return { permission: () => null, mcpServer: () => null };
  const tracker = (view.tracker ?? 'none') === 'none' && view.groups?.tracker !== true;
  const confluence = view.confluence === false || view.groups?.confluence === false;
  const surfaceNoBrowser = ['none', 'mobile', 'desktop', 'tui'].includes(view.app_surface);
  const prOff = view.commands?.pr === false || view.groups?.git === false;
  return {
    permission: (entry) => {
      if (tracker && /mcp__atlassian__jira_/.test(entry)) return 'tracker disabled in profile';
      if (confluence && /mcp__atlassian__confluence_/.test(entry)) return 'confluence disabled in profile';
      if (surfaceNoBrowser && /mcp__playwright__/.test(entry)) return `app_surface ${view.app_surface} — no browser QA`;
      if (prOff && /pr-api\.sh/.test(entry)) return 'PR commands disabled in profile';
      return null;
    },
    mcpServer: (name) => {
      if (name === 'atlassian' && tracker && confluence) return 'tracker and confluence disabled in profile';
      if (name === 'playwright' && surfaceNoBrowser) return `app_surface ${view.app_surface} — no browser QA`;
      return null;
    },
  };
}

// Union of settings.json permissions and hooks that never resurrects a migrated identity, never
// adds an entry a disabled profile group owns, and never removes a project entry. Unknown keys of
// `ours` are carried verbatim. Other top-level keys upstream introduces (e.g. `attribution`) are
// copied whole only when the project has no value for them — a project value always wins, and no
// deep merge is attempted (only permissions and hooks are unioned entry by entry).
export function unionSettings(manifest, ours, theirs, { file = '.claude/settings.json', profile = null } = {}) {
  const merged = structuredClone(ours);
  const added = [];
  const skipped = [];
  const disabled = disabledByProfile(profile);
  for (const [key, value] of Object.entries(theirs ?? {})) {
    // `enabledPlugins` is an activation decision, never an inherited setting. Copying it down
    // while the downstream keeps its own legacy hook registrations is how the ordinary sync path
    // manufactures two owners for every hard guard, with no operator involved at all.
    if (key === 'enabledPlugins') {
      if (!(key in merged)) skipped.push({ id: 'settings.enabledPlugins', reason: 'plugin enablement is an activation decision, never inherited by sync' });
      continue;
    }
    if (key === 'permissions' || key === 'hooks' || key === '$schema') continue;
    if (key in merged) continue;
    merged[key] = structuredClone(value);
    added.push(`settings.${key}`);
  }
  merged.permissions = merged.permissions ?? {};
  for (const tier of ['allow', 'ask', 'deny']) {
    const skipIds = migratedIdentities(manifest, file, 'permission');
    merged.permissions[tier] = [...(ours.permissions?.[tier] ?? [])];
    for (const entry of theirs.permissions?.[tier] ?? []) {
      const id = `permissions.${tier}|${entry}`;
      if (merged.permissions[tier].includes(entry)) continue;
      if (skipIds.has(id)) { skipped.push({ id, reason: 'migrated to the plugin' }); continue; }
      const why = disabled.permission(entry);
      if (why) { skipped.push({ id, reason: why }); continue; }
      merged.permissions[tier].push(entry);
      added.push(id);
    }
  }
  merged.hooks = merged.hooks ?? {};
  const hookSkips = migratedIdentities(manifest, file, 'hook');
  for (const [event, groups] of Object.entries(theirs.hooks ?? {})) {
    merged.hooks[event] = merged.hooks[event] ?? [];
    const present = new Set(merged.hooks[event].flatMap((g) => (g.hooks ?? []).map((h) => hookIdentity(event, g.matcher, h.command))));
    for (const group of groups) {
      for (const hook of group.hooks ?? []) {
        const id = hookIdentity(event, group.matcher, hook.command);
        if (present.has(id)) continue;
        if (hookSkips.has(id)) { skipped.push({ id, reason: 'migrated to the plugin' }); continue; }
        let target = merged.hooks[event].find((g) => (g.matcher ?? '') === (group.matcher ?? ''));
        if (!target) { target = { ...(group.matcher !== undefined ? { matcher: group.matcher } : {}), hooks: [] }; merged.hooks[event].push(target); }
        target.hooks.push(structuredClone(hook));
        present.add(id);
        added.push(id);
      }
    }
  }
  return { merged, added, skipped };
}

// Union of .mcp.json servers with the same rules.
export function unionMcp(manifest, ours, theirs, { file = '.mcp.json', profile = null } = {}) {
  const merged = structuredClone(ours);
  merged.mcpServers = merged.mcpServers ?? {};
  const skipIds = migratedIdentities(manifest, file, 'mcpServer');
  const disabled = disabledByProfile(profile);
  const added = [];
  const skipped = [];
  for (const [name, cfg] of Object.entries(theirs.mcpServers ?? {})) {
    if (name in merged.mcpServers) continue;
    if (skipIds.has(name)) { skipped.push({ id: name, reason: 'migrated to the plugin' }); continue; }
    const why = disabled.mcpServer(name);
    if (why) { skipped.push({ id: name, reason: why }); continue; }
    merged.mcpServers[name] = structuredClone(cfg);
    added.push(name);
  }
  return { merged, added, skipped };
}

// Host permission mapping: Claude's string-glob tiers have no Codex equivalent. Report each policy
// as supported or unsupported per host; never copy a tier into a host that cannot enforce it.
export function mapPermissionsForHost(settings, host) {
  const entries = [];
  for (const tier of ['allow', 'ask', 'deny']) for (const entry of settings.permissions?.[tier] ?? []) entries.push({ tier, entry });
  if (host === 'claude') return { host, supported: entries.map((e) => ({ ...e, enforcement: '.claude/settings.json permission tier' })), unsupported: [] };
  return {
    host,
    supported: [],
    unsupported: entries.map((e) => ({ ...e, reason: 'Codex has no string-glob permission tiers; the sandbox and approval_policy are the host controls — this policy is reported, not enforced' })),
    note: 'Hard file-write denies (e.g. Edit(**/.env)) have no Codex equivalent; the push guard still blocks a committed credential before publication.',
  };
}

function legacyHookId(command) {
  const m = command.match(/hooks\/([a-z-]+)\.sh/);
  return m ? m[1] : null;
}
function pluginHookId(command) {
  const m = command.match(/--hook ([a-z-]+)/);
  return m ? m[1] : null;
}

// Which plugin hook runs which project-owned script. The relationship is declared, not inferred:
// legacyHookId/pluginHookId match command ids, and the plugin's `check-deps` command string says
// nothing about the project script it shells out to.
export const HOOK_DELEGATES = { 'check-deps': 'check-project-deps' };

// Activation preview: for every hook id, who owns it after activation — the legacy Bash entry in
// settings.json, the plugin manifest, both (a duplicate that must be resolved), or `none` when the
// plugin hook is switched off in the project's hook config and no legacy entry took over. `none` is
// the state that says nothing is enforcing this hook; without it a successful rollback reads as
// `duplicate` and a missing protection reads as `plugin`. Computes only.
export function activationPlan({ settings, pluginHooks, release, file = '.claude/settings.json', manifest = null, hookConfig = null }) {
  const disabledIds = Array.isArray(hookConfig?.disabled) ? hookConfig.disabled : [];
  const legacy = new Map();
  for (const [event, groups] of Object.entries(settings.hooks ?? {})) {
    for (const g of groups) for (const h of g.hooks ?? []) {
      const id = legacyHookId(h.command);
      if (!id) continue;
      if (!legacy.has(id)) legacy.set(id, []);
      legacy.get(id).push({ event, matcher: g.matcher ?? '', identity: hookIdentity(event, g.matcher, h.command) });
    }
  }
  const plugin = new Map();
  for (const [event, groups] of Object.entries(pluginHooks.hooks ?? {})) {
    for (const g of groups) for (const h of g.hooks ?? []) {
      const id = pluginHookId(h.command);
      if (!id) continue;
      if (!plugin.has(id)) plugin.set(id, []);
      plugin.get(id).push({ event, matcher: g.matcher ?? '', command: h.command });
    }
  }
  const ids = [...new Set([...legacy.keys(), ...plugin.keys()])].sort();
  const rows = ids.map((id) => {
    const l = legacy.get(id) ?? [];
    const p = plugin.get(id) ?? [];
    const disabled = disabledIds.includes(id);
    const owner = disabled ? (l.length ? 'legacy' : 'none') : l.length && p.length ? 'duplicate' : l.length ? 'legacy' : 'plugin';
    const delegate = HOOK_DELEGATES[id] ?? null;
    // The plugin hook shells out to a project script that settings.json also calls directly:
    // one owner per hook id, two invocations of the same script per event.
    const delegationConflict = Boolean(delegate && p.length && !disabled && legacy.has(delegate));
    const row = {
      id,
      owner,
      disabled,
      enforced: owner !== 'none',
      legacy: l,
      plugin: p,
      replaced_identities: l.map((x) => x.identity),
      decision_required: owner === 'duplicate' || owner === 'none' || delegationConflict,
    };
    if (delegate) { row.delegates = delegate; row.delegation_conflict = delegationConflict; }
    return row;
  });
  const conflicts = rows.filter((r) => r.owner === 'duplicate').map((r) => r.id);
  const unenforced = rows.filter((r) => r.owner === 'none').map((r) => r.id);
  const delegationConflicts = rows.filter((r) => r.delegation_conflict).map((r) => ({ id: r.id, delegates: r.delegates, note: `plugin ${r.id} delegates to ${r.delegates}, which ${file} also registers directly — the project script runs twice per event; keep one caller` }));
  const projectOwned = rows.filter((r) => r.owner === 'legacy' && !plugin.has(r.id)).map((r) => r.id);
  // A migrated_config hook record whose logical id no plugin hook owns is a hook nobody runs any
  // more (0.1.0 pilot: check-project-deps was recorded as migrated and silently stopped). Compared by
  // id, never by identity string — legacy and plugin command strings differ on purpose.
  const orphaned = (manifest?.migrated_config ?? [])
    .filter((r) => r.kind === 'hook' && typeof r.identity === 'string')
    .map((r) => ({ identity: r.identity, id: legacyHookId(r.identity.split('|').slice(2).join('|')) }))
    .filter((r) => !r.id || !plugin.has(r.id))
    .map((r) => ({ ...r, note: r.id ? `recorded as migrated but no plugin hook is named ${r.id} — restore the legacy entry and drop the record` : 'malformed identity (expected <event>|<matcher>|<command>)' }));
  return {
    release,
    file,
    rows,
    conflicts,
    project_owned_only: projectOwned,
    orphaned_records: orphaned,
    rollback: { restore_identities: rows.flatMap((r) => r.replaced_identities), note: 'Rollback restores ownership: the listed legacy identities return to settings.json and their migrated_config records are dropped. It never purges a plugin cache.' },
    unenforced,
    delegation_conflicts: delegationConflicts,
    requires_confirmation: true,
    note: [
      conflicts.length ? `${conflicts.length} hook(s) would have two owners after activation — choose legacy or plugin for each before recording anything` : 'one owner per hook',
      unenforced.length ? `${unenforced.length} hook(s) are enforced by nobody (disabled in the hook config with no legacy entry): ${unenforced.join(', ')}` : null,
      delegationConflicts.length ? `${delegationConflicts.length} delegation conflict(s): ${delegationConflicts.map((d) => d.id).join(', ')}` : null,
    ].filter(Boolean).join('; '),
  };
}

// Record a migration ONLY after the replacement was verified. `verification` is the result of the
// installed-host check for that identity (ok + evidence); anything else throws. Never resurrects
// an entry that was already removed; never drops a record it did not add.
export function recordMigration(manifest, { path: filePath = null, config = null, replacedBy, release, verification, date = new Date().toISOString().slice(0, 10) }) {
  if (!verification || verification.ok !== true || !verification.evidence) throw new Error('refusing to record a migration without a verified replacement (verification.ok + evidence)');
  const next = { ...manifest, migrated: [...manifest.migrated], migrated_config: [...manifest.migrated_config] };
  if (filePath) {
    if (next.migrated.some((m) => m.path === filePath)) return next;
    next.migrated.push({ path: filePath, replaced_by: replacedBy, release, deleted: Boolean(verification.deleted), date, evidence: verification.evidence });
  }
  if (config) {
    if (next.migrated_config.some((m) => m.file === config.file && m.identity === config.identity)) return next;
    next.migrated_config.push({ file: config.file, kind: config.kind, identity: config.identity, replaced_by: replacedBy, release, evidence: verification.evidence });
  }
  return next;
}

// Compatibility stub for a legacy command file that a project keeps as a pointer after migration.
// It names the installed, bound package — never a starter checkout path.
// Snapshot what a hook owns BEFORE the switch: the complete settings.json registration objects
// (never identity strings — a rollback restores these verbatim) and the legacy script's bytes.
// `readScript` is injected so the pure function stays testable and the CLI owns the filesystem.
export function snapshotPrevious({ settings, hookIds, readScript = () => null, snapshotDir = '.agents/hooks/snapshots' }) {
  const out = {};
  for (const id of hookIds) {
    const registrations = [];
    for (const [event, groups] of Object.entries(settings.hooks ?? {})) {
      for (const g of groups) for (const h of g.hooks ?? []) {
        if (legacyHookId(h.command) !== id) continue;
        registrations.push({ event, matcher: g.matcher ?? '', hook: structuredClone(h) });
      }
    }
    const script = readScript(id);
    if (!registrations.length && !script) { out[id] = null; continue; }
    out[id] = {
      registrations,
      script: script ? { path: script.path, sha256: sha256Hex(script.bytes), snapshot_path: `${snapshotDir}/${id}.sh` } : null,
    };
  }
  return out;
}

// What an observed runtime state is allowed to be recorded as. A guard seen `error`, `untrusted`,
// `unsupported` or `disabled` during the run has a FAILED activation — it earns no record at all,
// and the mapping is enforced here rather than only in the audit gate so a bad record cannot exist
// even transiently.
export const OBSERVED_DECISION = { active: 'activated', dormant: 'conditional' };

// Activation evidence, deliberately separate from `recordMigration`: that one records a removed
// configuration identity and writes nothing without one, which is exactly the first rollout
// project's case. Pure — returns the next record, never touches disk.
export function recordActivation(record, { host, hook, release, decision, rationale = null, evidence, previous = null, observed = null, date = new Date().toISOString().slice(0, 10) }) {
  if (!evidence) throw new Error('refusing to record an activation without evidence naming the observation');
  if (decision !== 'activated' && !rationale) throw new Error(`a ${decision} decision needs a rationale — an unexplained negative decision is not a record`);
  if (observed !== null) {
    const allowed = OBSERVED_DECISION[observed];
    if (!allowed) throw new Error(`${hook} was observed \`${observed}\` — that is a failed activation, not a result; fix the cause and observe again`);
    if (allowed !== decision) throw new Error(`${hook} was observed \`${observed}\`, which is recorded as \`${allowed}\`, not \`${decision}\``);
  }
  const base = { schema_version: 1, project: record?.project ?? '', records: [...(record?.records ?? [])] };
  if (base.records.some((r) => r.host === host && r.hook === hook && r.release === release)) {
    throw new Error(`${host}/${hook} is already recorded for release ${release} — a second record would hide the first`);
  }
  const entry = { host, hook, release, decision, evidence, previous, date };
  if (rationale) entry.rationale = rationale;
  const next = { ...base, records: [...base.records, entry] };
  const errors = validate(JSON.parse(fs.readFileSync(activationSchemaFile, 'utf8')), next);
  if (errors.length) throw new Error(`invalid activation record: ${errors.join('; ')}`);
  return next;
}

export function renderStub({ command, skill, host, boundRoot }) {
  if (!boundRoot) throw new Error('a stub needs the bound installed root (resolveBoundRoot) — never a starter checkout');
  const name = command.replace(/^\//, '');
  if (host === 'claude') return renderWrapper({ command: name, skill, description: `/harness:${skill}`, boundRoot });
  return `---\ndescription: Migrated to the harness plugin — run $${skill}\n---\n\n# ${command} — migrated\n\nThis command moved to the installed \`harness\` plugin (bound at \`${boundRoot}\`, recorded in \`.agents/harness-version.json\` + \`.agents/harness-state/\`). Run $${skill}. This stub is kept only so old references resolve; it performs nothing.\n`;
}

// Rollback plan for one release: which migrated paths/entries would be re-offered by the next sync
// once their records are dropped. It computes; it never touches files.
export function rollbackPlan(manifest, release) {
  const paths = manifest.migrated.filter((m) => m.release === release);
  const config = manifest.migrated_config.filter((m) => m.release === release);
  const next = { ...manifest, migrated: manifest.migrated.filter((m) => m.release !== release), migrated_config: manifest.migrated_config.filter((m) => m.release !== release) };
  return {
    release,
    restore_paths: paths.map((m) => m.path),
    restore_config: config.map((m) => ({ file: m.file, identity: m.identity })),
    manifest_after: next,
    note: 'Dropping these records lets the next /maintain:sync-from-starter re-offer the legacy files and entries; it does not restore them by itself, restores ownership rather than emptying a plugin directory, and leaves specs, plans and memory untouched.',
  };
}

function main() {
  const { opts, positionals } = parseArgv(process.argv.slice(2));
  const cmd = positionals[0];
  const needsManifest = ['tasks', 'union', 'activation', 'rollback'].includes(cmd);
  const manifest = needsManifest ? loadManifest(requireOpt(opts, 'manifest')) : null;
  let out;
  if (cmd === 'tasks') out = filterTasks(manifest, readJson(requireOpt(opts, 'candidates')));
  else if (cmd === 'union') {
    const profile = opts['profile-view'] ? readJson(String(opts['profile-view'])) : null;
    out = unionSettings(manifest, readJson(requireOpt(opts, 'ours')), readJson(requireOpt(opts, 'theirs')), { profile });
  } else if (cmd === 'activation') {
    // The preview is only as honest as the disable list it reads: without this the operator's map
    // reports `duplicate` after a successful rollback and `plugin` where nothing enforces at all.
    let hookConfig = null;
    if (opts['hook-config']) {
      const norm = normalizeDisabled(readJson(String(opts['hook-config'])).disabled);
      if (norm.error) throw new Error(`--hook-config: ${norm.error}`);
      hookConfig = { disabled: norm.ids };
    }
    out = activationPlan({ settings: readJson(requireOpt(opts, 'settings')), pluginHooks: readJson(requireOpt(opts, 'plugin-hooks')), release: requireOpt(opts, 'release'), manifest, hookConfig });
  } else if (cmd === 'rollback') out = rollbackPlan(manifest, requireOpt(opts, 'release'));
  else if (cmd === 'snapshot') {
    const root = path.resolve(String(opts['project-root'] ?? '.'));
    const hooksDir = String(opts['hooks-dir'] ?? '.claude/hooks');
    const snapshotDir = String(opts['snapshot-dir'] ?? '.agents/hooks/snapshots');
    const ids = String(requireOpt(opts, 'hooks')).split(',').map((x) => x.trim()).filter(Boolean);
    const readScript = (id) => {
      const rel = `${hooksDir}/${id}.sh`;
      const abs = path.join(root, rel);
      return fs.existsSync(abs) ? { path: rel, bytes: fs.readFileSync(abs) } : null;
    };
    out = snapshotPrevious({ settings: readJson(requireOpt(opts, 'settings')), hookIds: ids, readScript, snapshotDir });
    // Without the byte copy the record holds a hash of a file Phase 4 deletes — enough to verify a
    // restoration, never enough to perform one.
    if (opts.write === 'yes') {
      for (const [id, prev] of Object.entries(out)) {
        if (!prev?.script) continue;
        const dest = path.join(root, prev.script.snapshot_path);
        fs.mkdirSync(path.dirname(dest), { recursive: true });
        fs.copyFileSync(path.join(root, prev.script.path), dest);
      }
    }
  } else if (cmd === 'activation-record') {
    const file = String(requireOpt(opts, 'record'));
    const current = fs.existsSync(file) ? readJson(file) : { schema_version: 1, project: String(opts.project ?? path.basename(process.cwd())), records: [] };
    out = recordActivation(current, {
      host: String(requireOpt(opts, 'host')),
      hook: String(requireOpt(opts, 'hook')),
      release: String(requireOpt(opts, 'release')),
      decision: String(requireOpt(opts, 'decision')),
      rationale: opts.rationale ? String(opts.rationale) : null,
      evidence: String(requireOpt(opts, 'evidence')),
      previous: opts.previous ? readJson(String(opts.previous)) : null,
      observed: opts.observed ? String(opts.observed) : null,
    });
    if (opts.write === 'yes') fs.writeFileSync(file, `${JSON.stringify(out, null, 2)}\n`);
  } else throw new Error(`unknown command ${cmd}; use tasks | union | activation | rollback | snapshot | activation-record`);
  console.log(JSON.stringify(out, null, 2));
}

if (process.argv[1] && fileURLToPath(import.meta.url) === realpathOrSelf(process.argv[1])) {
  try {
    main();
  } catch (err) {
    console.error(`sync-filter: ${err.message}`);
    process.exit(1);
  }
}
