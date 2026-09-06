// PERMISSIVE NEGATIVE CONTROL (tests only): the Claude adapter with every isolation flag removed: a separate `claude -p` process with the context pack on
// stdin, no model tools, restricted + safe mode, no MCP, no project/user settings, an empty
// scratch cwd. Managed (policy) settings still apply and are reported as external policy context.
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

export const host = 'claude';
const meta = JSON.parse(fs.readFileSync(path.join(path.dirname(fileURLToPath(import.meta.url)), 'adapter.json'), 'utf8'));

export function defaults() {
  return { model: meta.reviewer.model, effort: meta.reviewer.effort, timeoutMinutes: meta.reviewer.timeout_minutes };
}

// argv array — never a shell string. `schemaFile` holds the reviewer_output JSON schema.
export function buildSpawn({ model, effort, scratchCwd, schemaFile, systemPrompt }) {
  const args = [
    '-p',
    '--model', model,
    '--effort', effort,
    '--output-format', 'json',
    '--json-schema', fs.readFileSync(schemaFile, 'utf8'),
    '--system-prompt', systemPrompt,
  ];
  return {
    command: meta.cli,
    args,
    cwd: scratchCwd,
    stdin: 'prompt+pack',
    env: { CLAUDE_CODE_EFFORT_LEVEL: effort },
    isolation: [],
    external_policy_note: 'admin-managed (policy) settings cannot be disabled by the adapter and remain in effect',
  };
}

// `--output-format json` prints one JSON object; the structured answer sits in structured_output
// (or result when the CLI returned plain text). modelUsage names every model billed — the one with
// the most output tokens is the reviewer; small helper models are recorded, never counted as it.
export function parseOutput({ stdout }) {
  const text = stdout.toString('utf8').trim();
  let envelope = null;
  try {
    envelope = JSON.parse(text);
  } catch {
    const last = text.split('\n').reverse().find((l) => l.trim().startsWith('{'));
    try { envelope = last ? JSON.parse(last) : null; } catch { envelope = null; }
  }
  if (!envelope) return { finalText: text, confirmed: { model: null, effort: null }, envelope: null, toolUses: null };
  const finalText = envelope.structured_output !== undefined
    ? JSON.stringify(envelope.structured_output)
    : typeof envelope.result === 'string' ? envelope.result : JSON.stringify(envelope.result ?? null);
  const usage = Object.entries(envelope.modelUsage ?? {});
  usage.sort((a, b) => (b[1]?.outputTokens ?? 0) - (a[1]?.outputTokens ?? 0));
  const primary = usage[0]?.[0] ?? null;
  const stats = envelope.subagent_stats ?? {};
  return {
    finalText,
    confirmed: { model: primary, effort: envelope.effort ?? null },
    envelope,
    toolUses: { turns: envelope.num_turns ?? null, subagents_spawned: stats.spawned ?? 0, permission_denials: (envelope.permission_denials ?? []).length, models_billed: usage.map(([m]) => m) },
    isError: envelope.is_error === true,
  };
}

// Requested vs confirmed model identity: an alias like `fable` must resolve to a claude-fable model id.
export function modelMatches(requested, confirmed) {
  return Boolean(confirmed) && confirmed.toLowerCase().includes(requested.toLowerCase());
}
