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
// Works from a starter checkout (harness-source/scripts/) as well as from an installed plugin —
// a legacy-only downstream needs no plugin to sync.
import { fileURLToPath } from 'node:url';
import { parseArgv, requireOpt } from './lib/argv.mjs';
import { readJson, realpathOrSelf } from './lib/fsx.mjs';
import { renderWrapper } from './lib/wrapper.mjs';

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
// `ours` are carried verbatim.
export function unionSettings(manifest, ours, theirs, { file = '.claude/settings.json', profile = null } = {}) {
  const merged = structuredClone(ours);
  const added = [];
  const skipped = [];
  const disabled = disabledByProfile(profile);
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

// Activation preview: for every hook id, who owns it after activation — the legacy Bash entry in
// settings.json, the plugin manifest, or both (a duplicate that must be resolved). Computes only.
export function activationPlan({ settings, pluginHooks, release, file = '.claude/settings.json' }) {
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
    const owner = l.length && p.length ? 'duplicate' : l.length ? 'legacy' : 'plugin';
    return { id, owner, legacy: l, plugin: p, replaced_identities: l.map((x) => x.identity), decision_required: owner === 'duplicate' };
  });
  const conflicts = rows.filter((r) => r.owner === 'duplicate').map((r) => r.id);
  const projectOwned = rows.filter((r) => r.owner === 'legacy' && !plugin.has(r.id)).map((r) => r.id);
  return {
    release,
    file,
    rows,
    conflicts,
    project_owned_only: projectOwned,
    rollback: { restore_identities: rows.flatMap((r) => r.replaced_identities), note: 'Rollback restores ownership: the listed legacy identities return to settings.json and their migrated_config records are dropped. It never purges a plugin cache.' },
    requires_confirmation: true,
    note: conflicts.length ? `${conflicts.length} hook(s) would have two owners after activation — choose legacy or plugin for each before recording anything` : 'one owner per hook',
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
  const manifest = loadManifest(requireOpt(opts, 'manifest'));
  const cmd = positionals[0];
  let out;
  if (cmd === 'tasks') out = filterTasks(manifest, readJson(requireOpt(opts, 'candidates')));
  else if (cmd === 'union') {
    const profile = opts['profile-view'] ? readJson(String(opts['profile-view'])) : null;
    out = unionSettings(manifest, readJson(requireOpt(opts, 'ours')), readJson(requireOpt(opts, 'theirs')), { profile });
  } else if (cmd === 'activation') out = activationPlan({ settings: readJson(requireOpt(opts, 'settings')), pluginHooks: readJson(requireOpt(opts, 'plugin-hooks')), release: requireOpt(opts, 'release') });
  else if (cmd === 'rollback') out = rollbackPlan(manifest, requireOpt(opts, 'release'));
  else throw new Error(`unknown command ${cmd}; use tasks | union | activation | rollback`);
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
