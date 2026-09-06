// Claude Code hook adapter (T09): native PreToolUse/PostToolUse/SessionStart payloads → normalized
// events; core outcomes → the responses Claude Code documents (exit 2 + stderr to deny, stdout JSON
// hookSpecificOutput.additionalContext for advisory context). Subagents share the parent's
// session_id and carry agent_id, which is the child identity the memory guard scopes by.
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

// Same file in two layouts (source: adapters/<host>/, package: scripts/adapters/<host>/); resolve
// the shared event library from wherever this adapter actually lives.
const here = path.dirname(fileURLToPath(import.meta.url));
const libFile = ['../../scripts/lib/hook-events.mjs', '../../lib/hook-events.mjs'].map((r) => path.join(here, r)).find((f) => fs.existsSync(f));
const { makeEvent, normalizeShell, parseApplyPatch, relTo, resolveProjectRoot } = await import(pathToFileURL(libFile).href);

export const host = 'claude';

export const supports = {
  PreToolUse: ['deny', 'context'],
  PostToolUse: ['context'],
  SessionStart: ['context'],
};

const FILE_TOOLS = new Set(['Edit', 'Write', 'MultiEdit', 'NotebookEdit']);

function memoryPathsIn(command) {
  const stripped = String(command).replace(/>>?\s*\S+/g, '').replace(/(^|\s|\|)tee(\s+-[-a-zA-Z=]+)*(\s+[^\s|;&]+)+/g, '');
  return [...new Set([...stripped.matchAll(/[^\s"';|)&]*\.agents\/memory\/[^\s"';|)&]*\.md/g)].map((m) => m[0]))];
}

export function normalize(payload, { env = process.env, cwd = process.cwd() } = {}) {
  const projectRoot = resolveProjectRoot({ env, cwd: payload.cwd ?? cwd });
  const base = makeEvent({
    host, event: payload.hook_event_name ?? null, raw_tool_name: payload.tool_name ?? null,
    session: { id: payload.session_id ?? env.CLAUDE_CODE_SESSION_ID ?? null, agent_id: payload.agent_id ?? null, parent_shared: false },
    cwd: payload.cwd ?? cwd, project_root: projectRoot,
  });
  const input = payload.tool_input ?? {};
  const tool = payload.tool_name;
  if (tool === 'Bash') {
    return { ...base, tool: 'shell', shell: normalizeShell(String(input.command ?? ''), { cwd: base.cwd, root: projectRoot }), reads: memoryPathsIn(input.command ?? '').map((p) => relTo(projectRoot, p)) };
  }
  if (FILE_TOOLS.has(tool)) {
    const file = input.file_path ?? input.notebook_path ?? null;
    if (!file) return { ...base, tool: 'file-edit' };
    const content = input.content ?? input.new_string ?? (Array.isArray(input.edits) ? input.edits.map((e) => e.new_string ?? e.replacement ?? '').join('\n') : '');
    return { ...base, tool: 'file-edit', changes: [{ op: input.content !== undefined ? 'add' : 'update', path: relTo(projectRoot, file), content: String(content ?? '') }] };
  }
  if (tool === 'Read') {
    const file = input.file_path ?? input.path ?? null;
    return { ...base, tool: 'file-read', reads: file ? [relTo(projectRoot, file)] : [] };
  }
  if (tool === 'Grep') {
    return { ...base, tool: 'search', search: { pattern: input.pattern ?? '', glob: input.glob ?? '', path: input.path ?? (Array.isArray(input.paths) ? input.paths.join(' ') : '') } };
  }
  if (tool === 'WebFetch') return { ...base, tool: 'fetch', url: input.url ?? null };
  return base;
}

// Outcome → process response. Unsupported combinations are dropped and reported as such.
export function respond(outcome, event) {
  const allowed = supports[event.event] ?? [];
  if (outcome.decision === 'deny') {
    if (!allowed.includes('deny')) return { exit: 0, stdout: '', stderr: `hook-runner: deny is not supported for ${event.event} on claude — reported, not enforced: ${outcome.reason}\n`, delivered: false };
    return { exit: 2, stdout: '', stderr: `${outcome.reason}\n`, delivered: true };
  }
  if (outcome.context) {
    if (!allowed.includes('context')) return { exit: 0, stdout: '', stderr: '', delivered: false };
    return { exit: 0, stdout: `${JSON.stringify({ hookSpecificOutput: { hookEventName: event.event, additionalContext: outcome.context } })}\n`, stderr: '', delivered: true };
  }
  return { exit: 0, stdout: '', stderr: '', delivered: true };
}
