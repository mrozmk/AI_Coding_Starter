// Parity ledgers (contracts/instruction-parity.json, contracts/hook-parity.json): structure,
// completeness against the legacy contract, existence of owners/destinations/tests, and the rule
// that a gap or legacy-only row can never certify a capability. Rendering for docs/harness lives
// here too so the Markdown never drifts from the JSON.
import fs from 'node:fs';
import path from 'node:path';
import { validate } from './schema.mjs';

export const INSTRUCTION_STATUSES = ['migrated', 'compat-rendered', 'legacy-only', 'conditional', 'gap', 'retired'];
export const HOOK_STATES = ['ported', 'conditional', 'legacy-only', 'project-owned', 'retired'];
export const CERTIFIABLE = new Set(['migrated', 'compat-rendered', 'conditional']);

const destination = { type: ['string', 'null'] };
const instructionSchema = {
  type: 'object',
  required: ['schema_version', 'legacy_contract', 'entries'],
  properties: {
    schema_version: { const: 1 },
    legacy_contract: { type: 'object', required: ['source', 'items'], properties: { items: { type: 'array', minItems: 1, items: { type: 'object', required: ['item', 'kind'] } } } },
    entries: {
      type: 'array', minItems: 1,
      items: {
        type: 'object', required: ['id', 'legacy', 'applicability', 'strength', 'owner', 'destinations', 'check', 'status'],
        properties: {
          id: { type: 'string', pattern: '^[a-z]+\\.[a-z0-9-]+$' },
          legacy: { type: 'object', required: ['file', 'item'] },
          applicability: { type: 'string', pattern: '^(all|greenfield|brownfield|conditional:[a-z-]+)$' },
          strength: { enum: ['hard', 'advisory'] },
          owner: { type: 'string', minLength: 1 },
          destinations: { type: 'object', required: ['claude', 'codex'], properties: { claude: destination, codex: destination } },
          check: { type: 'object', required: ['test', 'name'] },
          status: { enum: INSTRUCTION_STATUSES },
          verified: { type: 'boolean' },
          rationale: { type: 'string' },
          decision: { type: 'string' },
        },
      },
    },
  },
};

const hookSchema = {
  type: 'object',
  required: ['schema_version', 'activation', 'hooks'],
  properties: {
    schema_version: { const: 1 },
    activation: { enum: ['none', 'pilot', 'verified'] },
    hooks: {
      type: 'array', minItems: 1,
      items: {
        type: 'object', required: ['id', 'legacy', 'event', 'strength', 'behavior', 'core', 'hosts', 'tests'],
        properties: {
          id: { type: 'string', pattern: '^[a-z][a-z0-9-]*$' },
          strength: { enum: ['hard', 'advisory', 'telemetry', 'preflight'] },
          core: { type: ['string', 'null'] },
          hosts: { type: 'object', required: ['claude', 'codex'], properties: { claude: { type: 'object', required: ['state'], properties: { state: { enum: HOOK_STATES } } }, codex: { type: 'object', required: ['state'], properties: { state: { enum: HOOK_STATES } } } } },
          tests: { type: 'array', minItems: 1, items: { type: 'string' } },
          rationale: { type: 'string' },
          decision: { type: 'string' },
        },
      },
    },
  },
};

export function loadLedgers(repoRoot) {
  const dir = path.join(repoRoot, 'harness-source/contracts');
  return {
    instructions: JSON.parse(fs.readFileSync(path.join(dir, 'instruction-parity.json'), 'utf8')),
    hooks: JSON.parse(fs.readFileSync(path.join(dir, 'hook-parity.json'), 'utf8')),
  };
}

// Owner strings point at a harness-source file (optionally `#section`) or a project-owned file.
function ownerFile(owner) {
  return owner.split('#')[0];
}

// Legacy paths (`.claude/…`) live in the template tree, which may be a separate checkout from the
// plugin source: `legacyRoot` resolves them, `repoRoot` resolves everything under harness-source/ and tests/.
function legacyAbs(repoRoot, legacyRoot, rel) {
  return path.join(rel.startsWith('.claude/') ? legacyRoot : repoRoot, rel);
}

export function checkInstructionLedger(ledger, repoRoot, { legacyRoot = repoRoot } = {}) {
  const errors = validate(instructionSchema, ledger);
  if (errors.length) return errors;
  const ids = new Set();
  const claimed = new Set();
  for (const e of ledger.entries) {
    if (ids.has(e.id)) errors.push(`duplicate id ${e.id}`);
    ids.add(e.id);
    if (e.legacy.file === ledger.legacy_contract.source) claimed.add(e.legacy.item);
    const owner = ownerFile(e.owner);
    if (!fs.existsSync(legacyAbs(repoRoot, legacyRoot, owner))) errors.push(`${e.id}: owner does not exist: ${owner}`);
    if (e.status !== 'legacy-only' && e.status !== 'gap' && !owner.startsWith('harness-source/')) errors.push(`${e.id}: a ${e.status} rule must be owned under harness-source/ (got ${owner})`);
    if (!fs.existsSync(path.join(repoRoot, e.check.test))) errors.push(`${e.id}: check test missing: ${e.check.test}`);
    if (e.destinations.claude === null && e.destinations.codex === null && e.status !== 'retired') errors.push(`${e.id}: no destination on either host — classify as retired with a rationale or name a destination`);
    if (e.status === 'retired' && (!e.rationale || !e.decision)) errors.push(`${e.id}: retired needs rationale and decision`);
    if (e.verified === true && !CERTIFIABLE.has(e.status)) errors.push(`${e.id}: status ${e.status} cannot be marked verified — an applicability gap never certifies the capability`);
    if (e.applicability.startsWith('conditional:') && e.status !== 'conditional' && e.status !== 'gap') errors.push(`${e.id}: conditional applicability must carry status conditional (or gap)`);
  }
  for (const item of ledger.legacy_contract.items) {
    if (!claimed.has(item.item)) errors.push(`legacy contract item not classified: ${item.item} (${item.kind}) — an unclassified removal`);
  }
  return errors;
}

export function checkHookLedger(ledger, repoRoot, { legacyHooksDir = '.claude/hooks', legacyRoot = repoRoot } = {}) {
  const errors = validate(hookSchema, ledger);
  if (errors.length) return errors;
  const ids = new Set();
  const covered = new Set();
  for (const h of ledger.hooks) {
    if (ids.has(h.id)) errors.push(`duplicate hook id ${h.id}`);
    ids.add(h.id);
    covered.add(path.posix.basename(h.legacy));
    if (!fs.existsSync(legacyAbs(repoRoot, legacyRoot, h.legacy))) errors.push(`${h.id}: legacy script missing: ${h.legacy}`);
    const states = Object.values(h.hosts).map((x) => x.state);
    if (states.includes('ported') || states.includes('conditional')) {
      if (!h.core) errors.push(`${h.id}: a ported/conditional hook needs a shared core`);
      else if (!fs.existsSync(path.join(repoRoot, h.core))) errors.push(`${h.id}: core missing: ${h.core}`);
    }
    if (states.includes('retired') && (!h.rationale || !h.decision)) errors.push(`${h.id}: retirement needs rationale and decision`);
    for (const t of h.tests) if (!fs.existsSync(path.join(repoRoot, t))) errors.push(`${h.id}: test missing: ${t}`);
  }
  const dir = path.join(legacyRoot, legacyHooksDir);
  if (fs.existsSync(dir)) {
    for (const f of fs.readdirSync(dir)) {
      if (f.endsWith('.sh') && !covered.has(f)) errors.push(`legacy hook not in the ledger: ${legacyHooksDir}/${f}`);
    }
  }
  if (ledger.activation !== 'none' && !ledger.activation_evidence) errors.push('activation beyond none needs activation_evidence (a release-readiness assertion name)');
  return errors;
}

export function checkParity(repoRoot, { legacyRoot = repoRoot } = {}) {
  const { instructions, hooks } = loadLedgers(repoRoot);
  return {
    errors: [...checkInstructionLedger(instructions, repoRoot, { legacyRoot }).map((e) => `instruction-parity: ${e}`), ...checkHookLedger(hooks, repoRoot, { legacyRoot }).map((e) => `hook-parity: ${e}`)],
    counts: { instructions: instructions.entries.length, hooks: hooks.hooks.length, legacy_items: instructions.legacy_contract.items.length },
  };
}

const cell = (v) => (v === null || v === undefined ? '—' : String(v).replace(/\|/g, '\\|'));

export function renderInstructionParity(ledger) {
  const lines = ['# Instruction parity — legacy → dual-host harness', '', `> Rendered from \`harness-source/contracts/instruction-parity.json\` (schema ${ledger.schema_version}). Edit the JSON, rebuild the docs. Status meanings are in the JSON \`_doc\`.`, '', '| Id | Legacy anchor | Applies | Strength | Owner | Claude | Codex | Status | Check |', '|---|---|---|---|---|---|---|---|---|'];
  for (const e of ledger.entries) {
    lines.push(`| \`${e.id}\` | ${cell(e.legacy.file)} → ${cell(e.legacy.item)} | ${e.applicability} | ${e.strength} | ${cell(e.owner)} | ${cell(e.destinations.claude)} | ${cell(e.destinations.codex)} | **${e.status}** | ${cell(e.check.test)} |`);
  }
  const counts = {};
  for (const e of ledger.entries) counts[e.status] = (counts[e.status] ?? 0) + 1;
  lines.push('', '## Totals', '', ...Object.entries(counts).map(([k, v]) => `- ${k}: ${v}`));
  const gaps = ledger.entries.filter((e) => e.status === 'gap' || e.status === 'legacy-only');
  lines.push('', '## Not certified (gap / legacy-only)', '', ...(gaps.length ? gaps.map((e) => `- \`${e.id}\` — ${e.note ?? 'no note'}`) : ['- none']));
  return `${lines.join('\n')}\n`;
}

export function renderHookParity(ledger) {
  const lines = ['# Hook parity — legacy .claude/hooks → shared core + host adapters', '', `> Rendered from \`harness-source/contracts/hook-parity.json\`. Activation: **${ledger.activation}** — ${ledger.activation_note ?? ''}`, '', '| Hook | Strength | Core | Claude | Codex | Tests |', '|---|---|---|---|---|---|'];
  for (const h of ledger.hooks) {
    const host = (x) => `${x.state}${x.response ? ` · ${x.response}` : ''}${x.note ? ` · ${x.note}` : ''}${x.precondition ? ` · when ${x.precondition}` : ''}`;
    lines.push(`| \`${h.id}\` | ${h.strength} | ${cell(h.core)} | ${cell(host(h.hosts.claude))} | ${cell(host(h.hosts.codex))} | ${h.tests.join(', ')} |`);
  }
  lines.push('', '## Known limits', '');
  for (const h of ledger.hooks) for (const l of h.known_limits ?? []) lines.push(`- \`${h.id}\`: ${l}`);
  return `${lines.join('\n')}\n`;
}
