// Project hook configuration resolver (T09/T12). One physical config per project: the legacy
// .claude/*.json files are read in place; a new project may use the canonical .agents/hooks/
// counterparts. Two copies that disagree are an explicit conflict — never a silent pick.
import fs from 'node:fs';
import path from 'node:path';

export const CONFIG_FILES = {
  memory_domains: { legacy: '.claude/memory-domains.json', canonical: '.agents/hooks/memory-domains.json' },
  comment_guard: { legacy: '.claude/comment-guard.json', canonical: '.agents/hooks/comment-guard.json' },
  nudge_rules: { legacy: '.claude/nudge-rules.json', canonical: '.agents/hooks/nudge-rules.json' },
  hooks: { legacy: null, canonical: '.agents/hooks/config.json' },
};

export const DEFAULTS = {
  project_preflight: '.claude/hooks/check-project-deps.sh',
  state_dir: '.agents/harness-state',
  legacy_sidecars: true,
  disabled: [],
};

// The single normalization contract for `hooks.disabled`, exported because the activation preview
// (scripts/sync-filter.mjs) must read the list exactly as the runner does: a runtime that trims
// " guard-push " while the preview compares it raw would report a protection the runner has
// switched off. Unknown ids are kept — a project may disable a hook before the release ships it.
export function normalizeDisabled(value) {
  if (value === undefined || value === null) return { ids: [], error: null };
  if (!Array.isArray(value)) return { ids: [], error: 'hooks.disabled must be an array of hook ids' };
  const ids = [];
  for (const entry of value) {
    if (typeof entry !== 'string') return { ids: [], error: `hooks.disabled entries must be strings, got ${typeof entry}` };
    const id = entry.trim();
    if (id && !ids.includes(id)) ids.push(id);
  }
  return { ids, error: null };
}

function readJsonOrError(abs) {
  try { return { value: JSON.parse(fs.readFileSync(abs, 'utf8')) }; } catch (e) { return { error: e.message }; }
}

function stripDocs(obj) {
  if (!obj || typeof obj !== 'object' || Array.isArray(obj)) return obj;
  return Object.fromEntries(Object.entries(obj).filter(([k]) => !k.startsWith('_')));
}

export function resolveHookConfig(projectRoot) {
  const root = path.resolve(projectRoot);
  const errors = [];
  const sources = {};
  const values = {};
  for (const [key, { legacy, canonical }] of Object.entries(CONFIG_FILES)) {
    const legacyAbs = legacy ? path.join(root, legacy) : null;
    const canonicalAbs = path.join(root, canonical);
    const hasLegacy = legacyAbs && fs.existsSync(legacyAbs);
    const hasCanonical = fs.existsSync(canonicalAbs);
    if (hasLegacy && hasCanonical) {
      const a = readJsonOrError(legacyAbs);
      const b = readJsonOrError(canonicalAbs);
      if (a.error || b.error) { errors.push(`${key}: unreadable config (${a.error ?? b.error})`); continue; }
      if (JSON.stringify(stripDocs(a.value)) !== JSON.stringify(stripDocs(b.value))) { errors.push(`${key}: ${legacy} and ${canonical} disagree — keep one physical config per project`); continue; }
      sources[key] = legacy; values[key] = a.value; continue;
    }
    const file = hasLegacy ? legacy : hasCanonical ? canonical : null;
    if (!file) { sources[key] = null; values[key] = null; continue; }
    const r = readJsonOrError(path.join(root, file));
    if (r.error) { errors.push(`${key}: ${file}: ${r.error}`); continue; }
    sources[key] = file; values[key] = r.value;
  }
  const hooks = { ...DEFAULTS, ...stripDocs(values.hooks ?? {}) };
  const disabled = normalizeDisabled(hooks.disabled);
  if (disabled.error) errors.push(`hooks: ${disabled.error}`);
  hooks.disabled = disabled.ids;
  return { ok: errors.length === 0, errors, sources, values: { ...values, ...hooks } };
}
