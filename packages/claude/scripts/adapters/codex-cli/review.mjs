// Codex reviewer adapter (contract 7): closed-context `codex exec` with the pack on stdin,
// `--sandbox read-only`, no native output schema, every execution/delegation surface disabled by
// feature flag, user config ignored, ephemeral session, empty scratch cwd. The live probe
// (preflight --live-reviewer-probe) is what proves the effective tool surface; flags alone are not.
// Hybrid context (recorded 2026-09-13, fixtures/reviewer-hybrid/events-README.md): the closed argv
// plus the read broker as `mcp_servers.reader` on the command line, `code_mode_host` kept enabled
// (disabling it breaks MCP tool routing on 0.154) and the broker's tools pre-approved; no `--json`
// (its events carry no model name) — the text stream keeps the header and one `mcp:` line pair per call.
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

export const host = 'codex';
const here = path.dirname(fileURLToPath(import.meta.url));
const meta = JSON.parse(fs.readFileSync(path.join(here, 'adapter.json'), 'utf8'));
const HYBRID = meta.reviewer.context?.hybrid ?? null;

export function defaults() {
  return { model: meta.reviewer.model, effort: meta.reviewer.effort, timeoutMinutes: meta.reviewer.timeout_minutes, hybridTimeoutMinutes: HYBRID?.timeout_minutes ?? 10 };
}

export function brokerTools() {
  return [...(HYBRID?.broker_tools ?? [])];
}

// TOML basic string: backslashes and quotes escaped; a value that fails to parse as TOML would be
// taken by the CLI as a literal string and silently break the server.
export function tomlString(value) {
  return `"${String(value).replace(/\\/g, '\\\\').replace(/"/g, '\\"').replace(/\n/g, '\\n')}"`;
}

function tomlInlineTable(obj) {
  return `{${Object.entries(obj).map(([k, v]) => `${k}=${tomlString(v)}`).join(',')}}`;
}

// The `-c` overrides that register the broker; exported so the orchestrator's manifest can list them.
export function mcpOverrides({ brokerCommand, brokerArgs, brokerEnv, scratchCwd }) {
  const name = HYBRID.mcp_server_name;
  return [
    `mcp_servers.${name}.command=${tomlString(brokerCommand)}`,
    `mcp_servers.${name}.args=[${brokerArgs.map(tomlString).join(',')}]`,
    `mcp_servers.${name}.env=${tomlInlineTable(brokerEnv)}`,
    `mcp_servers.${name}.cwd=${tomlString(scratchCwd)}`,
    `mcp_servers.${name}.startup_timeout_sec=${HYBRID.startup_timeout_sec}`,
    `mcp_servers.${name}.default_tools_approval_mode=${tomlString(HYBRID.default_tools_approval_mode)}`,
  ];
}

export function buildSpawn({ model, effort, scratchCwd, outFile, context = 'closed', brokerCommand = null, brokerArgs = null, brokerEnv = null }) {
  const hybrid = context === 'hybrid';
  if (!hybrid && context !== 'closed') throw new Error(`unknown reviewer context ${context}`);
  if (hybrid && !HYBRID) throw new Error('adapter.json declares no reviewer.context.hybrid block');
  if (hybrid && (!brokerCommand || !brokerArgs || !brokerEnv)) throw new Error('hybrid context needs brokerCommand, brokerArgs and brokerEnv');
  const args = [
    'exec',
    '--skip-git-repo-check',
    '-C', scratchCwd,
    '--sandbox', meta.reviewer.sandbox,
    '--ephemeral',
    '--ignore-user-config',
    '--ignore-rules',
    '-m', model,
    '-c', `model_reasoning_effort="${effort}"`,
  ];
  for (const override of meta.reviewer.config_overrides) args.push('-c', override);
  const disabled = hybrid ? meta.reviewer.disable_features.filter((f) => !HYBRID.keep_features.includes(f)) : meta.reviewer.disable_features;
  for (const feature of disabled) args.push('--disable', feature);
  const overrides = hybrid ? mcpOverrides({ brokerCommand, brokerArgs, brokerEnv, scratchCwd }) : [];
  for (const o of overrides) args.push('-c', o);
  args.push('--output-last-message', outFile, '-');
  return {
    command: meta.cli,
    args,
    cwd: scratchCwd,
    stdin: 'prompt+pack',
    env: {},
    isolation: [`--sandbox ${meta.reviewer.sandbox}`, '--ephemeral', '--ignore-user-config', '--ignore-rules', ...disabled.map((f) => `--disable ${f}`), ...(hybrid ? [`mcp_servers.${HYBRID.mcp_server_name} (broker only)`, `code_mode_host kept enabled (MCP routing)`] : [])],
    ...(hybrid ? { context: 'hybrid' } : {}),
    external_policy_note: 'requirements.toml / managed Codex policy cannot be disabled by the adapter and remains in effect',
  };
}

// Without `--json` the CLI prints a run header on stderr (model, provider, approval, sandbox,
// reasoning effort) and the final message to outFile. The header is the CLI's own confirmation of
// what actually ran; tool activity shows up as `exec`/`tool` lines after the header.
export function parseHeader(stderrText) {
  const header = {};
  for (const line of stderrText.split('\n').slice(0, 40)) {
    const m = line.match(/^(model|provider|approval|sandbox|reasoning effort|workdir):\s*(.+)$/);
    if (m) header[m[1]] = m[2].trim();
  }
  return header;
}

// Normalised for echo matching only: CRLF folded, trailing whitespace per line dropped, trailing
// blank lines dropped. The CLI re-prints the whole stdin after the header, so an `exec`-looking line
// that the caller itself wrote would otherwise be counted as the reviewer's own tool activity.
function normalizeEcho(s) {
  return s.replace(/\r\n/g, '\n').split('\n').map((l) => l.replace(/\s+$/, '')).join('\n').replace(/\n+$/, '');
}

const MCP_LINE = /^mcp: ([A-Za-z0-9_-]+)\/([A-Za-z0-9_-]+) (started|\((completed|failed)\))$/;

export function parseOutput({ stderr, outFile, stdinText, mode = 'closed' }) {
  const text = (stderr ?? '').toString('utf8');
  const header = parseHeader(text);
  // Only a complete, contiguous echo is removed: a partial or altered one must never hide activity,
  // so anything less falls back to scanning the whole stream.
  let scanned = text;
  if (stdinText) {
    const echo = normalizeEcho(String(stdinText));
    const normalized = normalizeEcho(text);
    const at = echo ? normalized.indexOf(echo) : -1;
    if (at !== -1) scanned = normalized.slice(0, at) + normalized.slice(at + echo.length);
  }
  const body = scanned.split('--------').slice(2).join('--------');
  const lines = body.split('\n').map((l) => l.trim());
  const finalText = outFile && fs.existsSync(outFile) ? fs.readFileSync(outFile, 'utf8') : '';
  if (mode !== 'hybrid') {
    const toolCalls = lines.filter((l) => /^(exec|tool|mcp|apply_patch|shell|spawn_agent|codex \$)/.test(l)).map((l) => l.slice(0, 80));
    return {
      finalText,
      confirmed: { model: header.model ?? null, effort: header['reasoning effort'] ?? null },
      header,
      toolUses: { count: toolCalls.length, types: toolCalls, sandbox: header.sandbox ?? null, approval: header.approval ?? null },
    };
  }
  // Hybrid: `mcp: <server>/<tool> started` opens a broker call, the next `(completed|failed)` line
  // for the same tool closes it; every other tool-looking line is non-broker activity.
  const brokerCalls = [];
  const other = [];
  const open = [];
  for (const l of lines) {
    const m = l.match(MCP_LINE);
    if (m) {
      const name = `${m[1]}.${m[2]}`;
      if (m[3] === 'started') open.push({ name, status: 'started' });
      else {
        const idx = open.findIndex((c) => c.name === name && c.status === 'started');
        const call = idx !== -1 ? open.splice(idx, 1)[0] : { name, status: 'started' };
        call.status = m[4];
        brokerCalls.push({ name: call.name, isError: m[4] === 'failed' });
      }
      continue;
    }
    if (/^(exec|tool|apply_patch|shell|spawn_agent|codex \$)/.test(l)) other.push(l.slice(0, 80));
  }
  for (const c of open) brokerCalls.push({ name: c.name, isError: true, unfinished: true });
  const broker = new Set(brokerTools());
  const foreignMcp = brokerCalls.filter((c) => !broker.has(c.name)).map((c) => `mcp ${c.name}`);
  const types = [...brokerCalls.filter((c) => broker.has(c.name)).map((c) => c.name), ...foreignMcp, ...other];
  return {
    finalText,
    confirmed: { model: header.model ?? null, effort: header['reasoning effort'] ?? null },
    header,
    toolUses: { count: types.length, types, broker_calls: brokerCalls.filter((c) => broker.has(c.name)), sandbox: header.sandbox ?? null, approval: header.approval ?? null },
    // A server that failed to start is silent in the text stream: the orchestrator decides from the log header.
    mcpFailure: null,
  };
}

export function modelMatches(requested, confirmed) {
  return Boolean(confirmed) && confirmed.toLowerCase() === requested.toLowerCase();
}
