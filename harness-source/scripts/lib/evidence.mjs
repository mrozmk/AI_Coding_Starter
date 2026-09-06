// Evidence contract (contract 14): machine-generated JSON is authoritative; Markdown is rendered.
// Shared by preflight --live-reviewer-probe / --verify-capabilities and smoke --live / --verify-evidence.
import fs from 'node:fs';
import path from 'node:path';
import { randomUUID } from 'node:crypto';
import { sha256Hex } from './digest.mjs';
import { validate } from './schema.mjs';

export const EVIDENCE_KINDS = ['reviewer-capabilities', 'release-readiness'];

const identity = { type: 'object', required: ['requested', 'confirmed'], properties: { requested: { type: ['string', 'null'] }, confirmed: { type: ['string', 'null'] } } };

export const evidenceSchema = {
  type: 'object',
  required: ['schema_version', 'kind', 'run_id', 'timestamp_utc', 'mode', 'cli', 'models', 'effort', 'config_digest', 'case_count', 'assertions', 'receipts', 'inputs'],
  additionalProperties: false,
  properties: {
    schema_version: { const: 1 },
    kind: { enum: EVIDENCE_KINDS },
    run_id: { type: 'string', minLength: 8 },
    timestamp_utc: { type: 'string', pattern: '^\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2}(\\.\\d+)?Z$' },
    mode: { enum: ['live', 'offline'] },
    cli: { type: 'object', properties: { claude: { type: 'object' }, codex: { type: 'object' } } },
    models: { type: 'object', properties: { claude: identity, codex: identity } },
    effort: { type: 'object', properties: { claude: identity, codex: identity } },
    config_digest: { type: 'string', pattern: '^[0-9a-f]{64}$' },
    case_count: { type: 'integer', minimum: 1 },
    assertions: {
      type: 'array', minItems: 1,
      items: {
        type: 'object', required: ['name', 'required', 'outcome', 'observation'],
        properties: {
          name: { type: 'string', minLength: 1 },
          required: { type: 'boolean' },
          outcome: { enum: ['pass', 'fail', 'not-run'] },
          observation: { type: 'string' },
          receipt_sha256: { type: ['string', 'null'], pattern: '^[0-9a-f]{64}$' },
        },
      },
    },
    receipts: { type: 'object', required: ['files'], properties: { files: { type: 'array', items: { type: 'object', required: ['name', 'sha256'] } } } },
    inputs: { type: 'object' },
    notes: { type: 'array', items: { type: 'string' } },
  },
};

export function newEvidence({ kind, mode, cli, models, effort, configDigest, inputs }) {
  return {
    schema_version: 1,
    kind,
    run_id: randomUUID(),
    timestamp_utc: new Date().toISOString(),
    mode,
    cli,
    models,
    effort,
    config_digest: configDigest,
    case_count: 0,
    assertions: [],
    receipts: { files: [] },
    inputs,
    notes: [],
  };
}

// Receipts are raw observations (stdout, JSON events, probe files). They stay local; the
// evidence carries their hashes so a reader can tell a re-labelled file from the original.
export function addReceipt(evidence, receiptsDir, name, content) {
  fs.mkdirSync(receiptsDir, { recursive: true });
  const bytes = Buffer.isBuffer(content) ? content : Buffer.from(String(content), 'utf8');
  fs.writeFileSync(path.join(receiptsDir, name), bytes);
  const sha256 = sha256Hex(bytes);
  evidence.receipts.files.push({ name, sha256 });
  return sha256;
}

export function addAssertion(evidence, { name, required = true, outcome, observation, receipt_sha256 = null }) {
  evidence.assertions.push({ name, required, outcome, observation, receipt_sha256 });
  evidence.case_count = evidence.assertions.length;
}

export function allRequiredPassed(evidence) {
  return evidence.assertions.filter((a) => a.required).every((a) => a.outcome === 'pass');
}

// Validation used by --verify-capabilities / --verify-evidence. Never launches anything.
export function validateEvidence(evidence, { kind, mode, requiredAssertions = [], expectedInputs = {} } = {}) {
  const errors = validate(evidenceSchema, evidence);
  if (errors.length) return errors;
  if (kind && evidence.kind !== kind) errors.push(`kind is ${evidence.kind}, expected ${kind}`);
  if (mode && evidence.mode !== mode) errors.push(`mode is ${evidence.mode}, expected ${mode}`);
  if (evidence.case_count !== evidence.assertions.length) errors.push('case_count does not match assertions');
  const byName = new Map(evidence.assertions.map((a) => [a.name, a]));
  for (const req of requiredAssertions) {
    const a = byName.get(req);
    if (!a) { errors.push(`required assertion missing: ${req}`); continue; }
    // The verifier's list decides what is required — an evidence file cannot demote its own gate.
    if (a.outcome !== 'pass') errors.push(`required assertion not passed: ${req} (${a.outcome}${a.required ? '' : ', marked optional in the file'})`);
  }
  for (const a of evidence.assertions) {
    if (a.required && a.outcome !== 'pass') errors.push(`required assertion not passed: ${a.name} (${a.outcome})`);
    if (a.outcome === 'pass' && !a.receipt_sha256) errors.push(`passed assertion without receipt: ${a.name}`);
    if (a.receipt_sha256 && !evidence.receipts.files.some((f) => f.sha256 === a.receipt_sha256)) {
      errors.push(`assertion receipt not listed under receipts: ${a.name}`);
    }
  }
  for (const [key, expected] of Object.entries(expectedInputs)) {
    if (expected === undefined) continue;
    const actual = key.split('.').reduce((o, k) => (o == null ? undefined : o[k]), evidence.inputs);
    if (actual !== expected) errors.push(`stale input ${key}: evidence has ${actual}, current is ${expected}`);
  }
  return errors;
}

// Finalization check: the receipts named in the evidence exist locally with the recorded hashes.
export function verifyReceipts(evidence, receiptsDir) {
  const errors = [];
  for (const f of evidence.receipts.files) {
    const p = path.join(receiptsDir, f.name);
    if (!fs.existsSync(p)) errors.push(`receipt missing locally: ${f.name}`);
    else if (sha256Hex(fs.readFileSync(p)) !== f.sha256) errors.push(`receipt hash mismatch: ${f.name}`);
  }
  return errors;
}

export function renderEvidenceMarkdown(evidence, title) {
  const lines = [
    `# ${title}`,
    '',
    `> Rendered from the authoritative JSON (run ${evidence.run_id}, ${evidence.timestamp_utc}, mode **${evidence.mode}**). Edit the JSON producer, not this file.`,
    '',
    `- CLI: ${Object.entries(evidence.cli).map(([h, v]) => `${h} ${v.version ?? 'n/a'}`).join(' · ')}`,
    `- Models: ${Object.entries(evidence.models).map(([h, v]) => `${h} requested ${v.requested} / confirmed ${v.confirmed}`).join(' · ')}`,
    `- Effort: ${Object.entries(evidence.effort).map(([h, v]) => `${h} requested ${v.requested} / confirmed ${v.confirmed}`).join(' · ')}`,
    `- Config digest: \`${evidence.config_digest}\``,
    `- Cases: ${evidence.case_count}`,
    '',
    '| Assertion | Required | Outcome | Observation |',
    '|---|---|---|---|',
  ];
  for (const a of evidence.assertions) {
    lines.push(`| ${a.name} | ${a.required ? 'yes' : 'no'} | ${a.outcome} | ${a.observation.replace(/\|/g, '\\|').replace(/\n/g, ' ')} |`);
  }
  if (evidence.notes?.length) {
    lines.push('', '## Notes', '');
    for (const n of evidence.notes) lines.push(`- ${n}`);
  }
  return `${lines.join('\n')}\n`;
}
