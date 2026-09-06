// audit-append (T10): local best-effort event audit, ported from .claude/hooks/audit-append.sh.
// One redacted line per tool event; ATTEMPT (PreToolUse) and DONE (PostToolUse) are distinct so a
// blocked attempt is not read as a completed action. Bounded retention. Never a gate.
import { appendAudit } from '../../scripts/lib/telemetry.mjs';

export const id = 'audit-append';
export const strength = 'telemetry';

export function describe(event) {
  switch (event.tool) {
    case 'shell': return { label: 'BASH', value: event.shell?.command ?? '' };
    case 'fetch': return { label: 'FETCH', value: event.url ?? '' };
    case 'file-edit': return { label: event.host === 'codex' ? 'PATCH' : (event.changes[0]?.op === 'add' ? 'WRITE' : 'EDIT'), value: event.changes.map((c) => `${c.op}:${c.path}`).join(' ') };
    case 'file-read': return { label: 'READ', value: event.reads.join(' ') };
    default: return null;
  }
}

export async function run(event, ctx) {
  const d = describe(event);
  if (!d) return { decision: 'none', state: event.host === 'codex' && event.raw_tool_name === 'WebFetch' ? 'unsupported' : 'active' };
  const phase = event.event === 'PostToolUse' ? 'DONE' : 'ATTEMPT';
  const line = appendAudit(ctx.state.audit, { phase, label: d.label, value: d.value, now: ctx.now });
  return { decision: 'none', state: 'active', line, file: ctx.state.audit };
}
