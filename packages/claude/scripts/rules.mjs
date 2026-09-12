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
//   node scripts/rules.mjs fill      --project-root <dir> --facts <facts.json> [--set f=v]... [--consent yes]
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

// ── fill: resolve unresolved fields in an existing rules body (T05) ───────────────────────────
// Brownfield only. Greenfield rules are generated from facts, and carrying a fill into the compat
// CLAUDE.md needs field→span locators MIRRORED does not have (no Trunk/Integration entries of its
// own, five template fields absent), so a greenfield fill would leave the compat copy stale while
// `ready` still reported true. Refused with a reason rather than half-served.

// Which fieldsFrom key supplies each branch-model assignment.
const BRANCH_FIELD_KEYS = { '**Preset:**': 'preset', '**Trunk:**': 'trunk', '**Integration:**': 'integration', '**Branch names:**': 'branch-pattern', '**Base → PR dest:**': 'pr-dest', '**Protected:**': 'protected' };

// Template line shapes (templates/project-rules.md → ### Branch model). Preset/Trunk/Integration
// share ONE line: the MIRRORED `Preset` regex swallows the whole line, and that is the only reason
// Trunk and Integration survive a sync at all. Splitting them onto their own lines breaks both
// syncCompat and legacyContractCheck (whose field regex stops at `·`).
function branchModelLines(fields) {
  const q = (v) => `\`${v}\``;
  const out = [
    `**Preset:** ${fields.preset} · **Trunk:** ${q(fields.trunk)} · **Integration:** ${q(fields.integration)}`,
    `**Branch names:** ${q(fields['branch-pattern'])}${fields['branch-types'] ? ` — types: ${fields['branch-types']}` : ''}`,
    `**Base → PR dest:** ${fields['pr-dest']}`,
    `**Protected:** ${fields.protected}`,
  ];
  if (fields.merge) out.push(`**Merge:** ${fields.merge}`);
  return out;
}

// Absolute offsets of the `### Branch model` block inside the Git Workflow section. sectionSpan only
// locates `##` headings, so the sub-heading needs its own walk.
function branchModelRegion(text) {
  const span = sectionSpan(text, 'Git Workflow');
  if (!span) return null;
  const body = text.slice(span.start, span.end);
  const rel = body.search(/^### Branch model\s*$/m);
  if (rel === -1) return null;
  const headerEnd = body.indexOf('\n', rel) + 1;
  const nextRel = body.slice(headerEnd).search(/^###\s+/m);
  return { start: span.start + rel, headerEnd: span.start + headerEnd, end: span.start + (nextRel === -1 ? body.length : headerEnd + nextRel) };
}

// Insertion point: after the section's trailing blockquote, before whatever follows it.
function afterBlockquote(text, region) {
  const lines = text.slice(region.headerEnd, region.end).split('\n');
  let last = -1;
  for (let i = 0; i < lines.length; i++) if (lines[i].startsWith('>')) last = i;
  const upto = lines.slice(0, last + 1).join('\n');
  return region.headerEnd + (last === -1 ? 0 : upto.length + 1);
}

const norm = (v) => String(v ?? '').replace(/`/g, '').replace(/\s+/g, ' ').trim();

// Resolved workflow facts as the file currently states them.
function workflowInFile(text) {
  const out = {};
  const git = sectionBody(text, 'Git Workflow') ?? '';
  const pub = git.match(/^\*\*Orchestrate publish:\*\*\s*(\S+)/m);
  if (pub) out.publish = pub[1];
  const region = branchModelRegion(text);
  if (region) {
    const body = text.slice(region.headerEnd, region.end).split('\n').filter((l) => !l.startsWith('>')).join('\n');
    for (const [label, key] of Object.entries(BRANCH_FIELD_KEYS)) {
      const m = body.match(new RegExp(`${label.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}\\s*([^·\\n]*)`));
      if (!m || /\{[a-z-]+\}|\{…\}/.test(m[1]) || !norm(m[1])) continue;
      // `**Branch names:**` composes two fields — `{branch-pattern}` and `{branch-types}` — on one
      // template line. Comparing the whole value against branch-pattern alone makes the `— types:`
      // tail read as a permanent disagreement, so take the backticked pattern when there is one.
      const raw = key === 'branch-pattern' ? (m[1].match(/`([^`]+)`/)?.[1] ?? m[1]) : m[1];
      out[key] = norm(raw);
    }
  }
  return out;
}

export function parseSet(set) {
  const out = {};
  for (const raw of [].concat(set ?? []).filter((x) => typeof x === 'string')) {
    const eq = raw.indexOf('=');
    if (eq === -1) throw new Error(`--set expects field=value, got ${raw}`);
    out[raw.slice(0, eq)] = raw.slice(eq + 1);
  }
  return out;
}

export function fillRules({ projectRoot, facts = {}, set = [], consent = false }) {
  const root = path.resolve(projectRoot);
  const auth = resolveRulesAuthority(root);
  if (auth.mode !== 'brownfield') {
    const reason = auth.mode === 'greenfield'
      ? 'greenfield rules are generated — fix the facts and re-create, do not fill'
      : (auth.warnings[0] ?? `no rules authority (mode ${auth.mode})`);
    return { ok: false, mode: auth.mode, authority: auth.authority, ready: false, unresolved_required: auth.unresolved_required, drift: auth.drift, actions: [], warnings: auth.warnings, reason };
  }

  const file = auth.authority;
  const abs = path.join(root, file);
  const before = fs.readFileSync(abs, 'utf8');
  const fields = fieldsFrom(facts);
  const overrides = parseSet(set);
  const edits = [];
  const problems = [];

  // Effective workflow = what the file states, with approved overrides on top. Overrides never
  // exempt a field from the check: `--set publish=push` over gitflow facts must still be refused.
  const inFile = workflowInFile(before);
  const effective = { ...inFile, ...overrides };
  const wfSupplied = facts.workflow && Object.keys(facts.workflow).length > 0;
  const drift = [];
  if (wfSupplied) {
    for (const key of ['publish', 'preset', 'trunk', 'integration', 'branch-pattern', 'pr-dest', 'protected']) {
      const want = fields[key];
      const have = effective[key];
      // An omitted input preserves the existing value; only a supplied, differing one disagrees.
      if (want === null || want === undefined || have === undefined) continue;
      if (norm(have) !== norm(want)) drift.push({ fact: key, rules: have, facts: want });
    }
  }
  if (drift.length) return { ok: false, mode: auth.mode, authority: file, ready: false, unresolved_required: auth.unresolved_required, drift, actions: [], warnings: auth.warnings, reason: 'workflow contradiction' };

  let next = before;

  // (a) named placeholders, plus any override naming one.
  for (const key of [...new Set([...unresolved(next), ...Object.keys(overrides)])]) {
    if (!PLACEHOLDERS.includes(key)) continue;
    const value = overrides[key] ?? fields[key];
    if (value === null || value === undefined) { problems.push({ kind: 'missing-facts', field: key }); continue; }
    if (!next.includes(`{${key}}`)) continue;
    next = next.split(`{${key}}`).join(String(value));
    edits.push({ kind: 'placeholder', field: key, to: String(value) });
  }

  // (b) a Validation fence whose command is a legacy placeholder command. Those spellings
  // ({typecheck-command} …) are NOT in PLACEHOLDERS, so unresolved() never reports them —
  // legacyContractCheck catches them by its own regex and legacyUnresolved names the field.
  if (legacyUnresolved(next).includes('validation-command')) {
    const value = overrides['validation-command'] ?? fields['validation-command'];
    if (value === null || value === undefined) problems.push({ kind: 'missing-facts', field: 'validation-command' });
    else {
      const span = sectionSpan(next, 'Validation');
      const body = span ? next.slice(span.start, span.end) : '';
      const fence = body.match(/```[a-z]*\n([\s\S]*?)```/);
      if (fence) {
        const kept = fence[1].split('\n').filter((l) => l.trim().startsWith('#'));
        const replaced = `${[...kept, String(value)].join('\n')}\n`;
        const updated = body.replace(fence[1], replaced);
        next = next.slice(0, span.start) + updated + next.slice(span.end);
        edits.push({ kind: 'validation-fence', field: 'validation-command', to: String(value) });
      }
    }
  }

  // (c)/(d) branch-model assignments: placeholder-valued, or absent from an existing section.
  const region = branchModelRegion(next);
  if (region === null) {
    if (legacyUnresolved(next).some((f) => ['preset', 'trunk', 'integration', 'protected'].includes(f))) problems.push({ kind: 'section-missing', section: '### Branch model' });
  } else {
    const body = next.slice(region.headerEnd, region.end);
    const dup = Object.keys(BRANCH_FIELD_KEYS).filter((label) => body.split(label).length - 1 > 1);
    if (dup.length) problems.push({ kind: 'duplicate-field', fields: dup });
    else {
      const stated = workflowInFile(next);
      const need = Object.entries(BRANCH_FIELD_KEYS).filter(([, key]) => overrides[key] !== undefined || stated[key] === undefined);
      if (need.length) {
        const values = { ...fields, ...overrides };
        const missing = ['preset', 'trunk', 'integration', 'pr-dest', 'protected'].filter((k) => values[k] === null || values[k] === undefined);
        if (missing.length) for (const f of missing) problems.push({ kind: 'missing-facts', field: f });
        else if (Object.keys(BRANCH_FIELD_KEYS).every((label) => !body.includes(label))) {
          // Whole block absent: insert it in the template's own layout.
          const at = afterBlockquote(next, region);
          const block = `\n${branchModelLines(values).join('\n')}\n`;
          next = next.slice(0, at) + block + next.slice(at);
          edits.push({ kind: 'branch-model-insert', fields: Object.values(BRANCH_FIELD_KEYS) });
        } else {
          // Some assignments exist: replace only the placeholder-valued ones, line by line.
          let updated = next.slice(region.headerEnd, region.end);
          for (const [label, key] of Object.entries(BRANCH_FIELD_KEYS)) {
            if (stated[key] !== undefined && overrides[key] === undefined) continue;
            // Trailing whitespace is captured separately and re-emitted: `[^·\n]*` alone eats the
            // space before a `·` separator and welds the next label onto the new value. Backticks
            // are preserved because the template wraps trunk/integration in them.
            const re = new RegExp(`(${label.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}\\s*)([^·\\n]*?)(\\s*)(?=·|\\n|$)`);
            const m = updated.match(re);
            if (!m) continue;
            const quoted = /^`.*`$/.test(m[2].trim());
            const value = quoted ? `\`${values[key]}\`` : String(values[key]);
            updated = updated.replace(re, (_x, a, _b, trail) => `${a}${value}${trail}`);
            edits.push({ kind: 'branch-model-field', field: key, to: String(values[key]) });
          }
          next = next.slice(0, region.headerEnd) + updated + next.slice(region.end);
        }
      }
    }
  }

  // Build every candidate before writing anything, and contract-check each. One candidate today;
  // the loop shape is kept because the deferred greenfield follow-up adds a second.
  const candidates = [{ file, abs, before, next }];
  for (const c of candidates) {
    const was = legacyContractCheck(c.before);
    const now = legacyContractCheck(c.next);
    const introduced = now.filter((e) => !was.includes(e));
    if (now.length > was.length || introduced.length) {
      return { ok: false, mode: auth.mode, authority: file, ready: false, unresolved_required: auth.unresolved_required, drift: [], actions: [{ file: c.file, action: 'refused', contract_errors: introduced.length ? introduced : now }], warnings: auth.warnings, reason: 'fill would break the legacy contract' };
    }
  }

  const diff = edits.length
    ? edits.map((e) => `~ ${e.kind}${e.field ? ` ${e.field}` : ''}${e.to ? `: ${e.to}` : ''}`).join('\n')
    : '(no change)';
  const actions = candidates.map((c) => ({ file: c.file, action: consent ? (c.next === c.before ? 'kept' : 'filled') : (c.next === c.before ? 'kept' : 'would-fill'), fields: edits.map((e) => e.field).filter(Boolean), diff, problems }));
  if (consent) for (const c of candidates) if (c.next !== c.before) fs.writeFileSync(c.abs, c.next);

  const after = consent ? resolveRulesAuthority(root) : null;
  return {
    ok: true, mode: auth.mode, authority: file,
    ready: consent ? after.ready : false,
    unresolved_required: consent ? after.unresolved_required : auth.unresolved_required,
    drift: consent ? after.drift : [], actions, problems,
    warnings: consent ? after.warnings : auth.warnings,
  };
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
  if (cmd === 'fill') {
    const facts = readJson(String(requireOpt(opts, 'facts')));
    const res = fillRules({ projectRoot, facts, set: opts.set, consent: opts.consent === 'yes' });
    console.log(JSON.stringify(res, null, 2));
    if (!res.ok) process.exit(2);
    if (opts.consent !== 'yes') console.error('preview only — re-run with --consent yes after the user approved the diff');
    return;
  }
  if (cmd === 'check') {
    const auth = resolveRulesAuthority(projectRoot);
    const claude = path.join(path.resolve(projectRoot), CLAUDE_FILE);
    const legacy = fs.existsSync(claude) ? legacyContractCheck(fs.readFileSync(claude, 'utf8')) : ['CLAUDE.md missing'];
    console.log(JSON.stringify({ ...auth, legacy_contract: legacy }, null, 2));
    process.exit(auth.ready && legacy.length === 0 ? 0 : 3);
  }
  throw new Error(`unknown command ${cmd}; use authority | render | check | fill`);
}

if (process.argv[1] && fileURLToPath(import.meta.url) === realpathOrSelf(process.argv[1])) {
  try {
    main();
  } catch (err) {
    console.error(`rules: ${err.message}`);
    process.exit(1);
  }
}
