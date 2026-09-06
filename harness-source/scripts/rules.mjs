#!/usr/bin/env node
// Rules authority and rendering (T04). Brownfield: a populated CLAUDE.md stays the single rule body
// and AGENTS.md points at it — no competing project-rules file is created. Greenfield: the shared
// .agents/project-rules.md is canonical and a compatibility CLAUDE.md is rendered from the same
// facts so every legacy heading/content reader keeps working. Placeholders are named fields; braces
// in code are never treated as placeholders. Unresolved required fields mean `incomplete`.
//
//   node scripts/rules.mjs authority --project-root <dir>
//   node scripts/rules.mjs render    --project-root <dir> --facts <facts.json> [--consent yes]
//   node scripts/rules.mjs check     --project-root <dir>
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { parseArgv, requireOpt } from './lib/argv.mjs';
import { readJson, realpathOrSelf } from './lib/fsx.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
export const RULES_FILE = '.agents/project-rules.md';
export const CLAUDE_FILE = 'CLAUDE.md';
export const AGENTS_FILE = 'AGENTS.md';
export const GENERATED_MARK = '<!-- harness:generated-rules';

// Named placeholders the templates carry. Only these names are ever treated as unresolved.
export const PLACEHOLDERS = ['project-description', 'language', 'ui-language', 'commands', 'validation-command', 'sensitive-paths', 'lib-dir', 'ui-paths', 'tech-stack-rows', 'architecture', 'style-conventions', 'docs-hosts', 'publish', 'preset', 'trunk', 'integration', 'branch-pattern', 'branch-types', 'pr-dest', 'protected', 'merge', 'lsp-tool', 'rules-file', 'rules-authority-note'];
// Without these a project cannot be declared ready: gates and pipelines read them.
export const REQUIRED = ['validation-command', 'language', 'publish', 'preset', 'trunk', 'integration', 'protected'];

// Legacy contract (cleanup-workflow 1.6 / CLAUDE-template contract block). Tier 1 is mandatory for
// every legacy reader; tier 2 headings are addressed by name by commands and hooks.
export const LEGACY_HEADINGS = { 1: ['Language Rules', 'Validation', 'Git Workflow'], 2: ['Commands', 'Code Structure & Modularity', 'Style & Conventions', 'Tech Stack', 'Automatic Behaviors', 'Search Commands', 'Security', 'Project Knowledge Layers', 'Error Handling'] };
export const LEGACY_CONTENT = ['**Orchestrate publish:**', 'git worktree remove --force', '### Branch model'];
const BRANCH_FIELDS = ['**Preset:**', '**Trunk:**', '**Integration:**', '**Branch names:**', '**Base → PR dest:**', '**Protected:**'];

export function templatesDir() {
  for (const c of [path.join(here, '..', 'templates'), path.join(here, 'templates')]) if (fs.existsSync(c)) return c;
  throw new Error('templates directory not found next to scripts/');
}

// Publish intent is one profile-derived decision: push only when work lands on the trunk directly.
export function derivePublish(workflow = {}) {
  const explicit = workflow.orchestrate_publish;
  const gated = workflow.pr_required === true || workflow.preset === 'feature-branch' || workflow.preset === 'gitflow' || (Array.isArray(workflow.protected) && workflow.trunk && workflow.protected.includes(workflow.trunk));
  if (gated && explicit === 'push') throw new Error('PR-gated workflow cannot publish with push — set workflow.orchestrate_publish to branch-local or change the preset');
  if (explicit === 'push' || explicit === 'branch-local') return explicit;
  if (!workflow.preset) return null;
  return gated ? 'branch-local' : 'push';
}

const PRESETS = {
  trunk: { trunk: 'main', integration: 'main', pr_required: false, protected: [], merge: 'ff', pr_dest: 'commit on main (no PR)', branch_types: ['feat', 'fix', 'chore'] },
  'feature-branch': { trunk: 'main', integration: 'main', pr_required: true, protected: ['main'], merge: 'squash', pr_dest: 'main', branch_types: ['feat', 'fix', 'chore', 'docs'] },
  gitflow: { trunk: 'main', integration: 'develop', pr_required: true, protected: ['main', 'develop'], merge: 'squash (merge-commit for release/hotfix)', pr_dest: 'develop (release/hotfix → main)', branch_types: ['feat', 'fix', 'release', 'hotfix'] },
};

// Expand a preset into the six branch-model facts, then let explicit profile values override.
export function branchModel(workflow = {}) {
  const base = PRESETS[workflow.preset] ?? {};
  const w = { ...base, ...Object.fromEntries(Object.entries(workflow).filter(([, v]) => v !== undefined)) };
  const pattern = w.branch_pattern ?? (workflow.tracker === 'jira' ? '<type>/<KEY>-<slug>' : '<type>/<slug>');
  return {
    preset: w.preset ?? null, trunk: w.trunk ?? null, integration: w.integration ?? null,
    'branch-pattern': pattern, 'branch-types': (w.branch_types ?? []).join(', ') || null,
    'pr-dest': w.pr_dest ?? null, protected: Array.isArray(w.protected) ? (w.protected.length ? w.protected.join(', ') : 'none') : null, merge: w.merge ?? null,
  };
}

// Facts → template fields. Anything not supplied stays a named placeholder.
export function fieldsFrom(facts = {}) {
  const wf = facts.workflow ?? {};
  const bm = branchModel({ ...wf, tracker: facts.tracker });
  const stack = Array.isArray(facts.tech_stack) && facts.tech_stack.length ? facts.tech_stack.map((t) => `| ${t.tech} | ${t.purpose} |`).join('\n') : null;
  const cmds = facts.commands && typeof facts.commands === 'object' ? Object.entries(facts.commands).map(([k, v]) => `# ${k}\n${v}`).join('\n\n') : (typeof facts.commands === 'string' ? facts.commands : null);
  return {
    'project-description': facts.project_description ?? null,
    language: facts.language === 'pl' ? 'Polish' : facts.language === 'en' ? 'English' : null,
    'ui-language': facts.ui_language ?? 'As defined in the PRD — check `docs/PRD.md` or ask if unclear',
    commands: cmds,
    'validation-command': facts.validation ?? null,
    'sensitive-paths': facts.sensitive_paths ?? 'payment, auth, webhook, license, locale/redirect routing, permission isolation, subprocess supervision',
    'lib-dir': facts.lib_dir ?? 'src/lib',
    'ui-paths': facts.ui_paths ?? null,
    'tech-stack-rows': stack,
    architecture: facts.architecture ?? null,
    'style-conventions': facts.style ?? null,
    'docs-hosts': facts.docs_hosts ?? 'none beyond the defaults',
    publish: derivePublish(wf),
    ...bm,
    'lsp-tool': facts.lsp?.tool ?? null,
  };
}

// Conditional blocks: `<!-- if:x -->…<!-- endif:x -->` stay only when the condition holds.
function applyConditions(text, conditions) {
  return text.replace(/\n?<!-- if:([a-z]+) -->([\s\S]*?)<!-- endif:\1 -->/g, (_m, name, body) => (conditions[name] ? body.replace(/\n$/, '') : ''));
}

export function renderTemplate(name, fields, conditions = {}) {
  let text = fs.readFileSync(path.join(templatesDir(), name), 'utf8');
  text = applyConditions(text, conditions);
  for (const key of PLACEHOLDERS) {
    const v = fields[key];
    if (v !== null && v !== undefined) text = text.split(`{${key}}`).join(String(v));
  }
  return text;
}

// Only named placeholders count; `${VAR}`, `{0}`, `{ }` and code braces are not placeholders.
export function unresolved(text) {
  const found = new Set();
  for (const m of text.matchAll(/\{([a-z][a-z0-9-]*)\}/g)) if (PLACEHOLDERS.includes(m[1])) found.add(m[1]);
  return [...found];
}

function headings(text) {
  return text.split('\n').filter((l) => /^#{2,3}\s+/.test(l)).map((l) => l.replace(/^#{2,3}\s+/, '').replace(/\s+#+\s*$/, '').replace(/\s+/g, ' ').trim());
}

function sectionBody(text, heading) {
  const lines = text.split('\n');
  const start = lines.findIndex((l) => new RegExp(`^##\\s+${heading.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}\\s*$`).test(l));
  if (start === -1) return null;
  const end = lines.slice(start + 1).findIndex((l) => /^##\s+/.test(l));
  return lines.slice(start + 1, end === -1 ? undefined : start + 1 + end).join('\n');
}

// The legacy reader's contract, applied to a CLAUDE.md body (cleanup-workflow 1.6 semantics).
export function legacyContractCheck(text) {
  const errors = [];
  const hs = headings(text);
  const has = (h) => hs.some((x) => x === h || x.startsWith(`${h} (`));
  for (const tier of [1, 2]) for (const h of LEGACY_HEADINGS[tier]) if (!has(h)) errors.push(`tier ${tier} heading missing: ${h}`);
  const git = sectionBody(text, 'Git Workflow') ?? '';
  const publish = git.match(/^\*\*Orchestrate publish:\*\*\s*(\S+)/m);
  if (!publish) errors.push('Git Workflow lacks **Orchestrate publish:**');
  else if (!['push', 'branch-local'].includes(publish[1])) errors.push(`Orchestrate publish has no real value (${publish[1]})`);
  if (!/git worktree remove --force.*discard/.test(git)) errors.push('Git Workflow lacks the git worktree remove --force guard sentence');
  if (!/^### Branch model/m.test(git)) errors.push('Git Workflow lacks ### Branch model');
  else {
    const bm = git.split('### Branch model')[1].split('\n').filter((l) => !l.startsWith('>')).join('\n');
    for (const f of BRANCH_FIELDS) {
      const m = bm.match(new RegExp(`${f.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}\\s*(\\S[^·\\n]*)`));
      if (!m || /\{[a-z-]+\}|\{…\}/.test(m[1])) errors.push(`Branch model field unassigned: ${f}`);
    }
  }
  const validation = sectionBody(text, 'Validation') ?? '';
  if (/\{[a-z-]+-command\}|\{validation-commands\}/.test(validation)) errors.push('Validation still carries a placeholder command');
  const fence = validation.match(/```[a-z]*\n([\s\S]*?)```/);
  if (hs.some((x) => x === 'Validation') && !fence) errors.push('Validation has no command block — prose alone is not a command the gate can run');
  else if (fence && !fence[1].split('\n').some((l) => l.trim() && !l.trim().startsWith('#'))) errors.push('Validation has no command (placeholder command removed, nothing put in its place)');
  return errors;
}

// Facts the compat CLAUDE.md mirrors from the shared rules. Legacy gates read CLAUDE.md by heading,
// so a hand edit to project-rules.md that is not carried over leaves the gate running stale commands.
const MIRRORED = [
  { name: 'validation-command', section: 'Validation', re: /(```[a-z]*\n)([\s\S]*?)(```)/, block: true },
  { name: 'test-policy', section: 'Validation', re: /(\*\*Test policy — which layers MUST have tests:\*\*\n\n)((?:- .*\n?)+)()/, block: true },
  { name: 'runtime-smoke', section: 'Validation', re: /(^\*\*Runtime smoke — optional conditional step\.\*\*)(.*)()$/m, insertAfterFence: true },
  { name: 'orchestrate-publish', section: 'Git Workflow', re: /(^\*\*Orchestrate publish:\*\*[ \t]*)(\S*)()/m },
  ...['Preset', 'Branch names', 'Base → PR dest', 'Protected', 'Merge'].map((f) => ({ name: `branch-model:${f}`, section: 'Git Workflow', re: new RegExp(`(^\\*\\*${f.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}:\\*\\*)(.*)()$`, 'm') })),
  { name: 'language', section: 'Language Rules', re: /(\|[^|\n]*communication[^|\n]*\|)([^|\n]*)(\|)/ },
];

function sectionSpan(text, heading) {
  const body = sectionBody(text, heading);
  if (body === null) return null;
  const start = text.indexOf(body, text.search(new RegExp(`^##\\s+${heading.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}\\s*$`, 'm')));
  return { start, end: start + body.length };
}

function mirroredValue(text, item) {
  const span = sectionSpan(text, item.section);
  if (!span) return null;
  const m = text.slice(span.start, span.end).match(item.re);
  return m ? m[2].trim() : null;
}

// Mirrored facts that differ between the shared rules and the compat rendering (or are missing there).
export function compatDrift(rulesText, claudeText) {
  const drift = [];
  for (const item of MIRRORED) {
    const want = mirroredValue(rulesText, item);
    if (want === null) continue;
    const have = mirroredValue(claudeText, item);
    if (have !== want) drift.push({ fact: item.name, rules: want, claude: have });
  }
  return drift;
}

// Carry the mirrored facts from the shared rules into a generated compat CLAUDE.md. Only the value
// spans change; every other byte of the rendering stays. Never applied to a hand-written CLAUDE.md.
export function syncCompat(claudeText, rulesText) {
  let out = claudeText;
  for (const item of MIRRORED) {
    const want = mirroredValue(rulesText, item);
    if (want === null) continue;
    const span = sectionSpan(out, item.section);
    if (!span) continue;
    const body = out.slice(span.start, span.end);
    const m = body.match(item.re);
    if (!m && item.insertAfterFence) {
      // The rules gained the paragraph after the compat copy was rendered without it; add it below the command block.
      const fence = body.match(/```[a-z]*\n[\s\S]*?```/);
      if (!fence) continue;
      const at = fence.index + fence[0].length;
      out = out.slice(0, span.start) + body.slice(0, at) + `\n\n**Runtime smoke — optional conditional step.** ${want}` + body.slice(at) + out.slice(span.end);
      continue;
    }
    if (!m) continue;
    const value = item.block ? `${want}\n` : (m[2].startsWith(' ') ? ` ${want}` : want);
    out = out.slice(0, span.start) + body.replace(item.re, (_m, a, _b, c) => `${a}${value}${c}`) + out.slice(span.end);
  }
  return out;
}

// A hand-written CLAUDE.md carries its own placeholder spellings ({typecheck-command} …); map the
// legacy contract failures back onto the required field names so readiness has one vocabulary.
const LEGACY_FIELD_MAP = [
  [/placeholder command|has no command|heading missing: Validation/, 'validation-command'], [/heading missing: Language Rules/, 'language'],
  [/Orchestrate publish|heading missing: Git Workflow/, 'publish'], [/\*\*Preset:\*\*|lacks ### Branch model|heading missing: Git Workflow/, 'preset'],
  [/\*\*Trunk:\*\*|lacks ### Branch model/, 'trunk'], [/\*\*Integration:\*\*|lacks ### Branch model/, 'integration'], [/\*\*Protected:\*\*|lacks ### Branch model/, 'protected'],
];
export function legacyUnresolved(text) {
  const out = new Set();
  for (const e of legacyContractCheck(text)) for (const [re, field] of LEGACY_FIELD_MAP) if (re.test(e)) out.add(field);
  return [...out];
}

function populated(abs) {
  if (!fs.existsSync(abs)) return { exists: false, populated: false, generated: false };
  const text = fs.readFileSync(abs, 'utf8');
  const generated = text.includes(GENERATED_MARK);
  // Any hand-written, non-empty file is the user's rules — length is not a measure of meaning.
  const lines = text.split('\n').filter((l) => l.trim()).length;
  return { exists: true, populated: !generated && lines >= 1, generated, text };
}

// Which file is the rule body. A populated, human-authored CLAUDE.md wins (brownfield); generated
// files defer to the shared rules (greenfield); two populated authorities are a conflict.
export function resolveRulesAuthority(projectRoot) {
  const root = path.resolve(projectRoot);
  const claude = populated(path.join(root, CLAUDE_FILE));
  const rules = populated(path.join(root, RULES_FILE));
  const agents = populated(path.join(root, AGENTS_FILE));
  let mode; let authority; const warnings = [];
  if (claude.populated && rules.populated) {
    mode = 'conflict'; authority = null;
    warnings.push(`both ${CLAUDE_FILE} and ${RULES_FILE} carry hand-written rules — one authority must be chosen by a human before any render`);
  } else if (claude.populated) {
    mode = 'brownfield'; authority = CLAUDE_FILE;
    if (rules.exists) warnings.push(`${RULES_FILE} exists but is generated/thin — CLAUDE.md remains the authority until an explicit, verified migration`);
  } else if (rules.exists) {
    mode = 'greenfield'; authority = RULES_FILE;
  } else if (claude.exists) {
    mode = 'greenfield'; authority = RULES_FILE;
    warnings.push(`${CLAUDE_FILE} is a thin generated file; the shared rules file is missing — render it`);
  } else {
    mode = 'none'; authority = null;
  }
  const authorityText = authority ? (authority === CLAUDE_FILE ? claude.text : rules.text) : null;
  // Readiness checks presence of the required facts, not just absence of placeholders: a gutted
  // section with no command or an unassigned branch field is incomplete either way.
  const missing = !authorityText ? REQUIRED : [...new Set([...(authority === CLAUDE_FILE ? [] : unresolved(authorityText).filter((p) => REQUIRED.includes(p))), ...legacyUnresolved(authorityText)])];
  const drift = authority === RULES_FILE && claude.generated ? compatDrift(rules.text, claude.text) : [];
  if (drift.length) warnings.push(`${CLAUDE_FILE} is out of sync with ${RULES_FILE} (${drift.map((d) => d.fact).join(', ')}) — legacy gates read CLAUDE.md; re-render to sync`);
  return { mode, authority, ready: mode !== 'none' && mode !== 'conflict' && missing.length === 0 && drift.length === 0, unresolved_required: missing, drift, files: { claude, rules, agents: { exists: agents.exists } }, warnings };
}

function agentsFields(authority) {
  return authority === CLAUDE_FILE
    ? { 'rules-file': CLAUDE_FILE, 'rules-authority-note': 'This project keeps its rules in `CLAUDE.md` (brownfield); it is the single authority for every host until an explicit, verified migration to `.agents/project-rules.md`.' }
    : { 'rules-file': RULES_FILE, 'rules-authority-note': 'It is the shared rule set for every AI host; `CLAUDE.md` is a compatibility rendering of the same facts.' };
}

// The compat CLAUDE.md is a rendering, so it may be re-synced from the shared rules whenever it still
// carries the generated mark. A CLAUDE.md without the mark is the user's file and is never touched.
function syncCompatFile(root, actions, consent) {
  const rulesAbs = path.join(root, RULES_FILE);
  const claudeAbs = path.join(root, CLAUDE_FILE);
  if (!fs.existsSync(rulesAbs) || !fs.existsSync(claudeAbs)) return;
  const rulesText = fs.readFileSync(rulesAbs, 'utf8');
  const claudeText = fs.readFileSync(claudeAbs, 'utf8');
  const drift = compatDrift(rulesText, claudeText);
  if (!drift.length) return;
  if (!claudeText.includes(GENERATED_MARK)) { actions.push({ file: CLAUDE_FILE, action: 'drift', note: 'hand-written file differs from the shared rules on mirrored facts — not overwritten', drift }); return; }
  actions.push({ file: CLAUDE_FILE, action: consent ? 'synced' : 'would-sync', drift });
  if (consent) fs.writeFileSync(claudeAbs, syncCompat(claudeText, rulesText));
}

// Plan (and with consent, perform) the rule files for a project. Absent-only for the rule body:
// nothing populated is ever overwritten; brownfield never receives a competing project-rules file.
// The generated compat CLAUDE.md is the one file that is re-synced (mirrored facts only).
export function applyRules({ projectRoot, facts = {}, consent = false }) {
  const root = path.resolve(projectRoot);
  const auth = resolveRulesAuthority(root);
  if (auth.mode === 'conflict') return { ok: false, mode: auth.mode, reason: auth.warnings[0], actions: [] };
  const conditions = { ui: Boolean(facts.ui_paths) || (facts.app_surface && !['none', 'unknown'].includes(facts.app_surface)), lsp: Boolean(facts.lsp?.declared) };
  const fields = fieldsFrom(facts);
  const actions = [];
  const plan = (file, render) => {
    const abs = path.join(root, file);
    if (fs.existsSync(abs)) { actions.push({ file, action: 'kept' }); return; }
    const text = render();
    actions.push({ file, action: consent ? 'created' : 'would-create', unresolved: unresolved(text) });
    if (consent) { fs.mkdirSync(path.dirname(abs), { recursive: true }); fs.writeFileSync(abs, text); }
  };
  if (auth.mode === 'brownfield') {
    actions.push({ file: CLAUDE_FILE, action: 'kept', note: 'authority (brownfield)' });
    actions.push({ file: RULES_FILE, action: 'skipped', note: 'not created — a generic seed must not compete with the populated CLAUDE.md' });
    plan(AGENTS_FILE, () => renderTemplate('AGENTS.md', agentsFields(CLAUDE_FILE)));
  } else {
    plan(RULES_FILE, () => renderTemplate('project-rules.md', fields, conditions));
    plan(CLAUDE_FILE, () => renderTemplate('CLAUDE.md', fields, conditions));
    plan(AGENTS_FILE, () => renderTemplate('AGENTS.md', agentsFields(RULES_FILE)));
    syncCompatFile(root, actions, consent);
  }
  const after = resolveRulesAuthority(root);
  const authorityUnresolved = consent ? after.unresolved_required : (auth.mode === 'brownfield' ? auth.unresolved_required : REQUIRED.filter((r) => fields[r] === null || fields[r] === undefined));
  const drift = consent ? after.drift : (actions.find((a) => a.action === 'would-sync')?.drift ?? []);
  return { ok: true, mode: consent ? after.mode : auth.mode, authority: consent ? after.authority : (auth.mode === 'brownfield' ? CLAUDE_FILE : RULES_FILE), ready: authorityUnresolved.length === 0 && drift.length === 0, unresolved_required: authorityUnresolved, drift, actions, warnings: consent ? after.warnings : auth.warnings };
}

function main() {
  const { opts, positionals } = parseArgv(process.argv.slice(2));
  const cmd = positionals[0];
  const projectRoot = requireOpt(opts, 'project-root');
  if (cmd === 'authority') { console.log(JSON.stringify(resolveRulesAuthority(projectRoot), null, 2)); return; }
  if (cmd === 'render') {
    const facts = readJson(String(requireOpt(opts, 'facts')));
    const res = applyRules({ projectRoot, facts, consent: opts.consent === 'yes' });
    console.log(JSON.stringify(res, null, 2));
    if (!res.ok) process.exit(2);
    if (opts.consent !== 'yes') console.error('preview only — re-run with --consent yes after the user approved the summary');
    return;
  }
  if (cmd === 'check') {
    const auth = resolveRulesAuthority(projectRoot);
    const claude = path.join(path.resolve(projectRoot), CLAUDE_FILE);
    const legacy = fs.existsSync(claude) ? legacyContractCheck(fs.readFileSync(claude, 'utf8')) : ['CLAUDE.md missing'];
    console.log(JSON.stringify({ ...auth, legacy_contract: legacy }, null, 2));
    process.exit(auth.ready && legacy.length === 0 ? 0 : 3);
  }
  throw new Error(`unknown command ${cmd}; use authority | render | check`);
}

if (process.argv[1] && fileURLToPath(import.meta.url) === realpathOrSelf(process.argv[1])) {
  try {
    main();
  } catch (err) {
    console.error(`rules: ${err.message}`);
    process.exit(1);
  }
}
