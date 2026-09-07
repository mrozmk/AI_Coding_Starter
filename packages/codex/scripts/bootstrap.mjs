#!/usr/bin/env node
// Project bootstrap helpers (T05/T12): seed the generic memory layer absent-only, and report the
// readiness of a project for the planning skills — rules authority, profile, memory, binding,
// dependency preflight. Nothing here overwrites a file that exists; nothing here reads .env.
//
//   node scripts/bootstrap.mjs seed   --project-root <dir> [--consent yes]
//   node scripts/bootstrap.mjs report --project-root <dir> --host claude|codex [--plugin-root <dir>]
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { parseArgv, requireOpt } from './lib/argv.mjs';
import { realpathOrSelf, toPosix } from './lib/fsx.mjs';
import { parseFrontmatter } from './lib/frontmatter.mjs';
import { checkVersion, effective, readProfile } from './profile.mjs';
import { resolveRulesAuthority } from './rules.mjs';
import { templatesDir } from './rules.mjs';
import { dependencyPreflight } from './preflight-deps.mjs';

export const MEMORY_DIR = '.agents/memory';
// Seed set: routing/reflection + empty placeholders. user-profile stays an .example (per-developer).
export const MEMORY_SEED = ['index.md', 'reflection-protocol.md', 'project-brief.md', 'architecture.md', 'patterns.md', 'decisions.md', 'errors.md', 'api.md', 'domain/business-model.md', 'user-profile.md.example'];
export const SCAFFOLD_DIRS = ['.agents/specs', '.agents/plans/active', '.agents/plans/done', '.agents/reference', '.agents/sources', '.agents/memory/domain'];

function memoryTemplates() {
  return path.join(templatesDir(), 'memory');
}

// Absent-only. A present file — populated or empty — is `kept` untouched; never merged, never
// rewritten. `{seed-date}` in a template becomes today's date at seed time.
export function seedMemory({ projectRoot, consent = false, today = new Date().toISOString().slice(0, 10) }) {
  const root = path.resolve(projectRoot);
  const src = memoryTemplates();
  const actions = [];
  for (const dir of SCAFFOLD_DIRS) {
    const abs = path.join(root, dir);
    if (fs.existsSync(abs)) { actions.push({ path: dir, action: 'kept' }); continue; }
    actions.push({ path: dir, action: consent ? 'created' : 'would-create' });
    if (consent) fs.mkdirSync(abs, { recursive: true });
  }
  for (const rel of MEMORY_SEED) {
    const target = path.join(root, MEMORY_DIR, rel);
    const dest = toPosix(path.join(MEMORY_DIR, rel));
    if (fs.existsSync(target)) { actions.push({ path: dest, action: 'kept' }); continue; }
    const text = fs.readFileSync(path.join(src, rel), 'utf8').split('{seed-date}').join(today);
    actions.push({ path: dest, action: consent ? 'created' : 'would-create' });
    if (consent) { fs.mkdirSync(path.dirname(target), { recursive: true }); fs.writeFileSync(target, text); }
  }
  return { actions, created: actions.filter((a) => a.action === 'created').length, kept: actions.filter((a) => a.action === 'kept').length };
}

function statusOf(abs) {
  if (!fs.existsSync(abs)) return 'absent';
  try { return parseFrontmatter(fs.readFileSync(abs, 'utf8')).data.status ?? 'no-frontmatter'; } catch { return 'no-frontmatter'; }
}

// One readiness verdict for prime/setup: `ready` only when every operational rule is resolved.
// Optional project knowledge (brief, architecture, PRD) is a visible warning, never a blocker.
export function readiness({ projectRoot, host, pluginRoot = null }) {
  const root = path.resolve(projectRoot);
  const rules = resolveRulesAuthority(root);
  const profile = readProfile(root);
  const eff = effective(profile);
  const memory = { index: fs.existsSync(path.join(root, MEMORY_DIR, 'index.md')), reflection: fs.existsSync(path.join(root, MEMORY_DIR, 'reflection-protocol.md')), brief: statusOf(path.join(root, MEMORY_DIR, 'project-brief.md')), architecture: statusOf(path.join(root, MEMORY_DIR, 'architecture.md')), prd: fs.existsSync(path.join(root, 'docs/PRD.md')), user_profile: statusOf(path.join(root, MEMORY_DIR, 'user-profile.md')) };
  const binding = host ? checkVersion({ projectRoot: root, host, pluginRoot }) : { ok: false, errors: ['no host given'] };
  const deps = dependencyPreflight({ projectRoot: root, host });
  const blockers = [];
  const warnings = [];
  if (rules.mode === 'none') blockers.push('no project rules (CLAUDE.md or .agents/project-rules.md) — run setup-start');
  if (rules.mode === 'conflict') blockers.push(rules.warnings[0]);
  if (rules.mode !== 'none' && rules.mode !== 'conflict' && !rules.ready) {
    const parts = [];
    if (rules.unresolved_required.length) parts.push(`unresolved: ${rules.unresolved_required.join(', ')}`);
    if (rules.drift?.length) parts.push(`CLAUDE.md out of sync with .agents/project-rules.md (${rules.drift.map((d) => d.fact).join(', ')}) — re-run rules.mjs render`);
    blockers.push(`rules incomplete — ${parts.join('; ')}`);
  }
  if (profile.status !== 'ok') blockers.push(`profile ${profile.status}: ${profile.message}`);
  if (!memory.index) blockers.push('no .agents/memory/index.md — run bootstrap seed');
  if (!binding.ok) blockers.push(`harness not bound: ${binding.errors.join('; ')}`);
  for (const d of deps.checks) if (!d.ok && d.required) blockers.push(`dependency missing: ${d.name} — ${d.detail}`);
  for (const d of deps.checks) if (!d.ok && !d.required) warnings.push(`optional dependency missing: ${d.name} — ${d.detail}`);
  if (!['populated', 'seeded'].includes(memory.brief)) warnings.push(`project-brief.md is ${memory.brief}${memory.prd ? ' — docs/PRD.md available as fallback' : ' and no docs/PRD.md — no product context yet'}`);
  if (!['populated', 'seeded'].includes(memory.architecture)) warnings.push(`architecture.md is ${memory.architecture} — prime falls back to a shallow file listing`);
  warnings.push(...rules.warnings.filter((w) => !blockers.includes(w)));
  return { ready: blockers.length === 0, blockers, warnings, rules: { mode: rules.mode, authority: rules.authority, unresolved_required: rules.unresolved_required }, profile: { status: profile.status, file: profile.file ?? null, groups: eff.status === 'ok' ? eff.groups : null }, memory, binding: binding.ok ? { root: binding.root, version: binding.version } : { errors: binding.errors }, dependencies: deps };
}

function main() {
  const { opts, positionals } = parseArgv(process.argv.slice(2));
  const cmd = positionals[0];
  const projectRoot = requireOpt(opts, 'project-root');
  if (cmd === 'seed') {
    const res = seedMemory({ projectRoot, consent: opts.consent === 'yes' });
    console.log(JSON.stringify(res, null, 2));
    if (opts.consent !== 'yes') console.error('preview only — re-run with --consent yes after the user approved the summary');
    return;
  }
  if (cmd === 'report') {
    const res = readiness({ projectRoot, host: opts.host ?? null, pluginRoot: opts['plugin-root'] ?? null });
    console.log(JSON.stringify(res, null, 2));
    process.exit(res.ready ? 0 : 3);
  }
  throw new Error(`unknown command ${cmd}; use seed | report`);
}

if (process.argv[1] && fileURLToPath(import.meta.url) === realpathOrSelf(process.argv[1])) {
  try {
    main();
  } catch (err) {
    console.error(`bootstrap: ${err.message}`);
    process.exit(1);
  }
}
