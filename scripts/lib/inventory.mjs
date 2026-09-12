// Loads and validates harness-source/inventory.json, derives package paths per host, and enumerates
// the source-digest inputs. The inventory is an allowlist: nothing outside it is packaged.
import fs from 'node:fs';
import path from 'node:path';
import { listFiles, readJson, toPosix } from '../../harness-source/scripts/lib/fsx.mjs';
import { validate } from '../../harness-source/scripts/lib/schema.mjs';

export const KINDS = ['skill', 'agent', 'reference', 'template', 'memory-template', 'contract', 'schema', 'script', 'script-lib', 'adapter', 'hook-core', 'hook-adapter', 'manifest'];
export const OWNERS = ['core', 'adapter:claude', 'adapter:codex', 'build'];
export const LEGACY_CLASSES = ['migrated', 'deferred', 'project', 'retained', 'host-provided', 'retired'];
export const HOSTS = ['claude', 'codex'];
const ID_PATTERN = '^[a-z][a-z0-9-]*$';
// A wrapper command path: one optional namespace segment, whose second half may be mixed-case
// because `create-PRD` is the real filename under .claude/commands/setup/.
const WRAPPER_PATTERN = '^[a-z][a-z0-9-]*(/[A-Za-z][A-Za-z0-9_-]*)?$';

// Local-only files that git ignores; never part of the classification duty.
const LOCAL_ONLY = /^\.claude\/(audit\.log|memory-usage\.json|settings\.local\.json|scheduled_tasks\.lock|worktrees\/|first-run|assistant-daemon-state\.json|.*\.tmp)$|(^|\/)\.DS_Store$/;

const inventorySchema = {
  type: 'object',
  required: ['schema_version', 'hosts', 'digest_inputs', 'entries', 'legacy'],
  properties: {
    schema_version: { const: 1 },
    hosts: { type: 'array', minItems: 1, items: { enum: HOSTS } },
    digest_inputs: { type: 'object', required: ['roots', 'globs'] },
    entries: {
      type: 'array', minItems: 1,
      items: {
        type: 'object', required: ['id', 'kind', 'owner', 'phase', 'dependencies'],
        properties: {
          id: { type: 'string', pattern: ID_PATTERN },
          kind: { enum: KINDS },
          owner: { enum: OWNERS },
          phase: { enum: ['planning', 'git', 'execution', 'product', 'qa', 'integration'] },
          dependencies: { type: 'array', items: { type: 'string' } },
          source: { type: 'string' },
          output: { type: 'string' },
          wrapper: { type: 'string', pattern: WRAPPER_PATTERN },
          host: { enum: HOSTS },
          legacy: { type: 'array', items: { type: 'string' } },
        },
      },
    },
    legacy: { type: 'array', items: { type: 'object', required: ['path', 'class'], properties: { class: { enum: LEGACY_CLASSES } } } },
  },
};

export function loadInventory(repoRoot) {
  const inventory = readJson(path.join(repoRoot, 'harness-source/inventory.json'));
  const harness = readJson(path.join(repoRoot, 'harness-source/harness.json'));
  return { inventory, harness };
}

export function validateInventory(inventory, repoRoot) {
  const errors = validate(inventorySchema, inventory);
  const ids = new Set();
  const wrappers = new Map();
  for (const e of inventory.entries) {
    if (e.wrapper !== undefined) {
      if (e.kind !== 'skill') errors.push(`${e.id}: wrapper is only valid on a skill entry`);
      if (wrappers.has(e.wrapper)) errors.push(`${e.id}: wrapper ${e.wrapper} already declared by ${wrappers.get(e.wrapper)}`);
      else wrappers.set(e.wrapper, e.id);
    }
    if (ids.has(e.id)) errors.push(`duplicate id ${e.id}`);
    ids.add(e.id);
    if (e.kind === 'manifest') {
      if (!e.host || !e.output) errors.push(`${e.id}: manifest needs host and output`);
    } else if (!e.source || !e.source.startsWith('harness-source/')) {
      errors.push(`${e.id}: source must be under harness-source/`);
    }
    if ((e.kind === 'adapter' || e.kind === 'hook-adapter') && !e.host_dir) errors.push(`${e.id}: ${e.kind} needs host_dir`);
    if (e.kind === 'hook-adapter' && e.source && e.source.endsWith('hooks.json') && !e.host) errors.push(`${e.id}: a native hooks manifest needs host`);
    if (e.source && path.isAbsolute(e.source)) errors.push(`${e.id}: absolute source path`);
    if (e.kind === 'memory-template' && e.source && !e.source.startsWith('harness-source/templates/memory/')) errors.push(`${e.id}: memory-template source must live under harness-source/templates/memory/`);
    if (e.kind === 'agent' && e.source && !e.source.startsWith('harness-source/agents/')) errors.push(`${e.id}: agent source must live under harness-source/agents/`);
    if (e.output !== undefined && e.kind !== 'manifest' && !safeOutput(e.output)) errors.push(`${e.id}: output must be a package-relative POSIX path without .. or a leading /`);
  }
  for (const e of inventory.entries) {
    for (const d of e.dependencies) if (!ids.has(d)) errors.push(`${e.id}: unknown dependency ${d}`);
  }
  const legacyClaimed = new Set();
  const retiredPaths = new Set();
  for (const l of inventory.legacy) {
    if (legacyClaimed.has(l.path)) errors.push(`legacy path listed twice: ${l.path}`);
    legacyClaimed.add(l.path);
    if (l.class === 'retired') retiredPaths.add(l.path);
    if (l.class === 'migrated' && !ids.has(l.replaced_by)) errors.push(`${l.path}: migrated but replaced_by unknown`);
    // A tombstone is the record of a deletion: the replacement must be a real entry and the file
    // must be gone, or the row is a lie in one direction or the other.
    if (l.class === 'retired') {
      if (!ids.has(l.replaced_by)) errors.push(`${l.path}: retired but replaced_by unknown`);
      if (fs.existsSync(path.join(repoRoot, l.path))) errors.push(`retired legacy path still exists: ${l.path}`);
    } else if (!fs.existsSync(path.join(repoRoot, l.path))) {
      errors.push(`legacy path does not exist: ${l.path}`);
    }
  }
  // A generated wrapper writes the command file back into a downstream project, where no build gate
  // runs — pointing one at a tombstoned path would silently resurrect the file this release deleted.
  for (const [wrapper, id] of wrappers) {
    const p = `.claude/commands/${wrapper}.md`;
    if (retiredPaths.has(p)) errors.push(`${id}: wrapper ${wrapper} resolves to retired legacy path ${p}`);
  }
  // Every existing harness file under .claude/ must be classified (exact or by directory prefix).
  const { files } = listFiles(path.join(repoRoot, '.claude'));
  for (const rel of files) {
    const p = `.claude/${rel}`;
    if (LOCAL_ONLY.test(p)) continue;
    const covered = [...legacyClaimed].some((c) => (c.endsWith('/') ? p.startsWith(c) : p === c));
    if (!covered) errors.push(`unclassified legacy file: ${p}`);
  }
  return errors;
}

// Explicit output mapping (contract: safe, package-relative, never recursive). Used by
// memory templates and hook files whose destination is not derivable from the kind alone.
// Retired legacy paths, for the build marker: what this version deleted, recorded not implied.
export function RETIRED_LEGACY(inventory) {
  return inventory.legacy.filter((l) => l.class === 'retired').map((l) => l.path).sort();
}

export function safeOutput(out) {
  return typeof out === 'string' && out.length > 0 && !path.posix.isAbsolute(out) && !out.split('/').includes('..') && !out.includes('\\') && !out.endsWith('/');
}

export function skillName(entry) {
  return entry.id;
}

// Package-relative output paths for one entry on one host (generated helpers included).
export function outputsFor(entry, host) {
  const base = entry.source ? path.posix.basename(entry.source) : null;
  if (entry.kind !== 'manifest' && entry.host && entry.host !== host) return [];
  if (entry.output && entry.kind !== 'manifest') return [entry.output];
  switch (entry.kind) {
    case 'skill':
      return host === 'codex'
        ? [`skills/${entry.id}/SKILL.md`, `skills/${entry.id}/agents/openai.yaml`]
        : [`skills/${entry.id}/SKILL.md`];
    // Agents are a Claude Code component; Codex plugins carry none.
    case 'agent': return host === 'claude' ? [`agents/${base}`] : [];
    case 'reference': return [`references/${base}`];
    case 'template': return [`templates/${base}`];
    case 'memory-template': return [`templates/memory/${entry.source.slice('harness-source/templates/memory/'.length)}`];
    case 'contract': return [`contracts/${base}`];
    case 'hook-core': return [`hooks/core/${base}`];
    case 'hook-adapter': return base === 'hooks.json' ? ['hooks/hooks.json'] : [`scripts/adapters/${entry.host_dir}/${base}`];
    case 'schema': return [`schemas/${base}`];
    case 'script': return [`scripts/${base}`];
    case 'script-lib': return [`scripts/lib/${base}`];
    case 'adapter': return [`scripts/adapters/${entry.host_dir}/${base}`];
    case 'manifest': return entry.host === host ? [entry.output] : [];
    default: throw new Error(`unknown kind ${entry.kind}`);
  }
}

export function sourceDigestRecords(inventory, repoRoot) {
  const records = [];
  const seen = new Set();
  const add = (rel) => {
    if (seen.has(rel)) return;
    seen.add(rel);
    records.push({ path: rel, bytes: fs.readFileSync(path.join(repoRoot, rel)) });
  };
  for (const root of inventory.digest_inputs.roots) {
    const { files, symlinks } = listFiles(path.join(repoRoot, root));
    if (symlinks.length) throw new Error(`symlinks are not allowed in ${root}: ${symlinks.join(', ')}`);
    for (const f of files) add(toPosix(path.posix.join(root, f)));
  }
  for (const glob of inventory.digest_inputs.globs) {
    const dir = path.posix.dirname(glob);
    const ext = path.posix.extname(glob);
    const abs = path.join(repoRoot, dir);
    if (!fs.existsSync(abs)) continue;
    for (const name of fs.readdirSync(abs)) {
      const abs2 = path.join(abs, name);
      if (fs.statSync(abs2).isFile() && name.endsWith(ext)) add(path.posix.join(dir, name));
    }
  }
  return records;
}

// Files under harness-source/ that no entry claims — an allowlist must be complete in both directions.
export function unclaimedSources(inventory, repoRoot) {
  const claimed = new Set(inventory.entries.filter((e) => e.source).map((e) => e.source));
  claimed.add('harness-source/inventory.json');
  claimed.add('harness-source/harness.json');
  const { files } = listFiles(path.join(repoRoot, 'harness-source'));
  return files.map((f) => `harness-source/${f}`).filter((f) => !claimed.has(f));
}
