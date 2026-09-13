// Claude reviewer adapter (contract 8): a separate `claude -p` process with the context pack on
// stdin, no model tools, restricted + safe mode, no MCP, no project/user settings, an empty
// scratch cwd. Managed (policy) settings still apply and are reported as external policy context.
// Hybrid context (recorded 2026-09-13, fixtures/reviewer-hybrid/events-README.md): the closed argv
// minus `--safe-mode` (it disables every MCP server, `--mcp-config` included) plus the read broker
// as the only MCP server and the only allowed tools; output switches to `stream-json` so every
// tool use is observed, not just the final envelope.
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

export const host = 'claude';
const meta = JSON.parse(fs.readFileSync(path.join(path.dirname(fileURLToPath(import.meta.url)), 'adapter.json'), 'utf8'));
const HYBRID = meta.reviewer.context?.hybrid ?? null;

export function defaults() {
  return { model: meta.reviewer.model, effort: meta.reviewer.effort, timeoutMinutes: meta.reviewer.timeout_minutes, hybridTimeoutMinutes: HYBRID?.timeout_minutes ?? 10 };
}

// The host's spelling of the three broker tools, for the judge's allowlist.
export function brokerTools() {
  return [...(HYBRID?.broker_tools ?? [])];
}

// The per-run MCP config the CLI reads with --mcp-config; the CLI spawns the broker from it.
export function mcpConfig({ brokerCommand, brokerArgs, brokerEnv }) {
  return { mcpServers: { [HYBRID.server_name]: { command: brokerCommand, args: brokerArgs, env: brokerEnv } } };
}

// argv array — never a shell string. `schemaFile` holds the reviewer_output JSON schema.
export function buildSpawn({ model, effort, scratchCwd, schemaFile, systemPrompt, context = 'closed', brokerConfigFile = null }) {
  if (context === 'closed') {
    const args = [
      '-p',
      '--model', model,
      '--effort', effort,
      '--output-format', 'json',
      '--json-schema', fs.readFileSync(schemaFile, 'utf8'),
      '--system-prompt', systemPrompt,
      ...meta.reviewer.isolation,
    ];
    return {
      command: meta.cli,
      args,
      cwd: scratchCwd,
      stdin: 'prompt+pack',
      env: { CLAUDE_CODE_EFFORT_LEVEL: effort },
      isolation: [...meta.reviewer.isolation],
      external_policy_note: 'admin-managed (policy) settings cannot be disabled by the adapter and remain in effect',
    };
  }
  if (context !== 'hybrid') throw new Error(`unknown reviewer context ${context}`);
  if (!HYBRID) throw new Error('adapter.json declares no reviewer.context.hybrid block');
  if (!brokerConfigFile) throw new Error('hybrid context needs brokerConfigFile (the per-run MCP config)');
  const isolation = meta.reviewer.isolation.filter((f) => !HYBRID.drop_isolation.includes(f));
  const args = [
    '-p',
    '--model', model,
    '--effort', effort,
    '--output-format', HYBRID.output_format,
    '--verbose',
    '--json-schema', fs.readFileSync(schemaFile, 'utf8'),
    '--system-prompt', systemPrompt,
    ...isolation,
    '--mcp-config', brokerConfigFile,
    // Variadic flag: keep it last and the prompt on stdin, or it swallows the prompt.
    '--allowedTools', HYBRID.allowed_tools.join(','),
  ];
  return {
    command: meta.cli,
    args,
    cwd: scratchCwd,
    stdin: 'prompt+pack',
    env: { CLAUDE_CODE_EFFORT_LEVEL: effort },
    isolation: [...isolation, `--mcp-config ${HYBRID.mcp_config_file}`, `--allowedTools ${HYBRID.allowed_tools.join(',')}`],
    context: 'hybrid',
    external_policy_note: 'admin-managed (policy) settings cannot be disabled by the adapter and remain in effect; --safe-mode is dropped in hybrid context because it disables every MCP server — the live probe proves no auto-loaded instructions',
  };
}

// `--output-format json` prints one JSON object; the structured answer sits in structured_output
// (or result when the CLI returned plain text). modelUsage names every model billed — the one with
// the most output tokens is the reviewer; small helper models are recorded, never counted as it.
export function parseOutput({ stdout, mode = 'closed' }) {
  if (mode === 'hybrid') return parseStream(stdout);
  const text = stdout.toString('utf8').trim();
  let envelope = null;
  try {
    envelope = JSON.parse(text);
  } catch {
    const last = text.split('\n').reverse().find((l) => l.trim().startsWith('{'));
    try { envelope = last ? JSON.parse(last) : null; } catch { envelope = null; }
  }
  if (!envelope) return { finalText: text, confirmed: { model: null, effort: null }, envelope: null, toolUses: null };
  return fromEnvelope(envelope);
}

function fromEnvelope(envelope) {
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

// `--output-format stream-json`: one JSON event per line. Tool identity comes from the assistant
// `tool_use` blocks, results from the matching `tool_result`, the verdict from the final `result`.
export function parseStream(stdout) {
  const events = [];
  for (const line of stdout.toString('utf8').split('\n')) {
    if (!line.trim().startsWith('{')) continue;
    try { events.push(JSON.parse(line)); } catch { /* partial or foreign line */ }
  }
  const init = events.find((e) => e.type === 'system' && e.subtype === 'init') ?? null;
  const result = [...events].reverse().find((e) => e.type === 'result') ?? null;
  const uses = [];
  const results = new Map();
  for (const e of events) {
    const content = e.message?.content;
    if (!Array.isArray(content)) continue;
    for (const c of content) {
      if (e.type === 'assistant' && c.type === 'tool_use') uses.push({ id: c.id, name: c.name, input: c.input ?? {}, parent: e.parent_tool_use_id ?? null });
      if (e.type === 'user' && c.type === 'tool_result') results.set(c.tool_use_id, { isError: c.is_error === true, content: c.content });
    }
  }
  const structured = uses.filter((u) => u.name === 'StructuredOutput');
  const toolCalls = uses.filter((u) => u.name !== 'StructuredOutput');
  const broker = new Set(brokerTools());
  const brokerCalls = toolCalls.filter((u) => broker.has(u.name)).map((u) => ({ name: u.name, args: u.input, isError: results.get(u.id)?.isError === true }));
  const base = result ? fromEnvelope(result) : { finalText: '', confirmed: { model: init?.model ?? null, effort: null }, envelope: null, toolUses: { turns: null, subagents_spawned: 0, permission_denials: 0, models_billed: [] }, isError: false };
  if (!base.finalText && structured.length) base.finalText = JSON.stringify(structured.at(-1).input);
  if (!base.confirmed.model && init?.model) base.confirmed.model = init.model;
  const mcpServers = init?.mcp_servers ?? [];
  return {
    ...base,
    init,
    toolUses: {
      ...base.toolUses,
      count: toolCalls.length,
      types: toolCalls.map((u) => u.name),
      subagents_spawned: Math.max(base.toolUses.subagents_spawned ?? 0, toolCalls.filter((u) => u.parent).length ? 1 : 0),
      broker_calls: brokerCalls,
      mcp_servers: mcpServers,
    },
    mcpFailure: mcpServers.find((s) => s.name === HYBRID?.server_name && s.status !== 'connected')?.status ?? (init && !mcpServers.some((s) => s.name === HYBRID?.server_name) ? 'absent' : null),
  };
}

// Requested vs confirmed model identity: an alias like `fable` must resolve to a claude-fable model id.
export function modelMatches(requested, confirmed) {
  return Boolean(confirmed) && confirmed.toLowerCase().includes(requested.toLowerCase());
}
