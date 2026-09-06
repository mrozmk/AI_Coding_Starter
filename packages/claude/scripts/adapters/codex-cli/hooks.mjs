// Codex CLI hook adapter (T09): PreToolUse/PostToolUse/SessionStart payloads → normalized events.
// Codex carries file changes as an apply_patch command string, not as file_path/content fields, so
// the patch is parsed into bounded per-file events (never executed). Subagents reuse the parent
// session_id and carry no child identity — the event says so (parent_shared) and the memory guard
// treats it as an unresolved author context rather than inventing one.
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

// Same file in two layouts (source: adapters/<host>/, package: scripts/adapters/<host>/); resolve
// the shared event library from wherever this adapter actually lives.
const here = path.dirname(fileURLToPath(import.meta.url));
const libFile = ['../../scripts/lib/hook-events.mjs', '../../lib/hook-events.mjs'].map((r) => path.join(here, r)).find((f) => fs.existsSync(f));
const { makeEvent, normalizeShell, parseApplyPatch, relTo, resolveProjectRoot } = await import(pathToFileURL(libFile).href);

export const host = 'codex';

// Documented Codex hook outputs: exit 2 / permissionDecision deny on PreToolUse; additionalContext
// on PostToolUse and SessionStart. No structured Read/Grep events exist on this host.
export const supports = {
  PreToolUse: ['deny', 'context'],
  PostToolUse: ['context'],
  SessionStart: ['context'],
};

function memoryPathsIn(command) {
  const stripped = String(command).replace(/>>?\s*\S+/g, '').replace(/(^|\s|\|)tee(\s+-[-a-zA-Z=]+)*(\s+[^\s|;&]+)+/g, '');
  return [...new Set([...stripped.matchAll(/[^\s"';|)&]*\.agents\/memory\/[^\s"';|)&]*\.md/g)].map((m) => m[0]))];
}

export function normalize(payload, { env = process.env, cwd = process.cwd() } = {}) {
  const projectRoot = resolveProjectRoot({ env, cwd: payload.cwd ?? cwd });
  const base = makeEvent({
    host, event: payload.hook_event_name ?? null, raw_tool_name: payload.tool_name ?? null,
    session: { id: payload.session_id ?? null, agent_id: null, parent_shared: true },
    cwd: payload.cwd ?? cwd, project_root: projectRoot,
  });
  const input = payload.tool_input ?? {};
  const tool = payload.tool_name;
  if (tool === 'apply_patch') {
    const { changes, truncated } = parseApplyPatch(String(input.command ?? input.patch ?? ''));
    return { ...base, tool: 'file-edit', changes: changes.map((c) => ({ ...c, path: relTo(projectRoot, c.path), from: c.from ? relTo(projectRoot, c.from) : undefined })), truncated };
  }
  if (tool === 'Bash' || tool === 'shell' || tool === 'local_shell') {
    const command = String(input.command ?? (Array.isArray(input.cmd) ? input.cmd.join(' ') : ''));
    return { ...base, tool: 'shell', shell: normalizeShell(command, { cwd: base.cwd, root: projectRoot }), reads: memoryPathsIn(command).map((p) => relTo(projectRoot, p)) };
  }
  return base;
}

export function respond(outcome, event) {
  const allowed = supports[event.event] ?? [];
  if (outcome.decision === 'deny') {
    if (!allowed.includes('deny')) return { exit: 0, stdout: '', stderr: `hook-runner: deny is not supported for ${event.event} on codex — reported, not enforced: ${outcome.reason}\n`, delivered: false };
    return { exit: 2, stdout: '', stderr: `${outcome.reason}\n`, delivered: true };
  }
  if (outcome.context) {
    if (!allowed.includes('context')) return { exit: 0, stdout: '', stderr: '', delivered: false };
    return { exit: 0, stdout: `${JSON.stringify({ hookSpecificOutput: { hookEventName: event.event, additionalContext: outcome.context } })}\n`, stderr: '', delivered: true };
  }
  return { exit: 0, stdout: '', stderr: '', delivered: true };
}
