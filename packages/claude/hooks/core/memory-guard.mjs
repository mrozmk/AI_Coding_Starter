// guard-memory (T11): the first code edit per memory domain per AUTHOR CONTEXT is blocked until a
// scoped memory preparation is acknowledged. Ported from .claude/hooks/guard-memory.sh (same
// path→domain rules, capture-group substitution, hard skips, size gate). Markers now live under the
// project's state directory keyed by project root + worktree + host + session + child identity, so
// a parent's acknowledgement never satisfies an unprimed child and two projects never share one.
import fs from 'node:fs';
import path from 'node:path';
import { createHash } from 'node:crypto';

export const id = 'guard-memory';
export const strength = 'hard';

const SKIP_RE = /^(\.agents\/|\.claude\/|.*\/\.agents\/|.*\/\.claude\/)|(\.test\.|\.spec\.|\/__tests__\/|\/__mocks__\/|\/test\/|\/tests\/)|\.(md|json|lock|yaml|yml|toml|txt)$|\.env/;

export function resolveDomain(rel, config) {
  const fallback = config?.fallback ?? 'general';
  for (const rule of config?.rules ?? []) {
    if (!rule?.match) continue;
    const m = rel.match(new RegExp(rule.match));
    if (!m) continue;
    let domain = String(rule.domain ?? fallback);
    for (let g = 1; g <= 9; g++) domain = domain.split(`$${g}`).join(m[g] ?? '');
    return { domain: domain.replace(/[^A-Za-z0-9_-]/g, '_'), enforced: domain !== fallback && domain.length > 0 };
  }
  return { domain: fallback, enforced: false };
}

function memoryBytes(projectRoot) {
  let total = 0;
  for (const f of ['errors.md', 'patterns.md', 'decisions.md']) {
    try { total += fs.statSync(path.join(projectRoot, '.agents/memory', f)).size; } catch { /* absent */ }
  }
  return total;
}

// The author context: which project, which host, which session, which child. On Codex a subagent
// reuses the parent session_id, so the child must be named explicitly (HARNESS_EXECUTOR_ID) or the
// project must have decided to accept session-level scope; otherwise the capability is blocked.
export function contextKey({ projectRoot, host, session, agent, executor, parentShared, childPolicy }) {
  if (!session) return { ok: false, reason: 'no session id in the hook payload — cannot scope the memory acknowledgement' };
  let child = agent ?? executor ?? null;
  if (parentShared && !child) {
    if (childPolicy === 'session') child = 'session';
    else return { ok: false, reason: 'this host cannot distinguish a subagent from its parent (shared session id). Set HARNESS_EXECUTOR_ID per executor and acknowledge with --executor, or record the decision `codex_child_identity: "session"` in .agents/hooks/config.json to accept session-level scope. Until then the memory guard blocks rather than reusing a parent acknowledgement.' };
  }
  const facts = { projectRoot: fs.realpathSync.native(projectRoot), host, session, child: child ?? 'main' };
  return { ok: true, key: createHash('sha256').update(JSON.stringify(facts)).digest('hex').slice(0, 24), facts };
}

function markerPath(stateDir, key, domain) {
  return path.join(stateDir, 'memory-ack', key, domain);
}

export function acknowledge({ projectRoot, host, domain, session, agent = null, executor = null, stateDir = '.agents/harness-state', childPolicy = 'required' }) {
  const parentShared = host === 'codex';
  const ctx = contextKey({ projectRoot, host, session, agent, executor, parentShared, childPolicy });
  if (!ctx.ok) return { ok: false, reason: ctx.reason };
  const file = markerPath(path.join(projectRoot, stateDir), ctx.key, domain.replace(/[^A-Za-z0-9_-]/g, '_'));
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, `${JSON.stringify({ acknowledged_at: new Date().toISOString(), domain, context: ctx.facts, note: 'acknowledgement that memory was distilled for this author context — trusted like git add, not proof of understanding' }, null, 2)}\n`);
  return { ok: true, marker: file, context: ctx.facts };
}

export async function run(event, ctx) {
  if (event.tool !== 'file-edit' || event.changes.length === 0) return { decision: 'none', state: 'active' };
  const config = ctx.config.values.memory_domains;
  if (!config || !(config.rules ?? []).length) return { decision: 'none', state: 'dormant', reason: 'no path→domain rules configured (memory-domains.json)' };
  const threshold = Number(config.size_threshold_bytes ?? 24000);
  const total = memoryBytes(ctx.projectRoot);
  if (total < threshold) return { decision: 'none', state: 'dormant', reason: `memory ${total} B below threshold ${threshold} B` };
  const domains = [];
  for (const c of event.changes) {
    if (c.op === 'delete' || SKIP_RE.test(c.path)) continue;
    const d = resolveDomain(c.path, config);
    if (d.enforced && !domains.some((x) => x.domain === d.domain)) domains.push({ domain: d.domain, path: c.path });
  }
  if (!domains.length) return { decision: 'none', state: 'active' };
  const key = contextKey({ projectRoot: ctx.projectRoot, host: event.host, session: event.session.id, agent: event.session.agent_id, executor: ctx.env.HARNESS_EXECUTOR_ID ?? null, parentShared: event.session.parent_shared, childPolicy: ctx.config.values.codex_child_identity ?? 'required' });
  if (!key.ok) return { decision: 'deny', state: 'untrusted', reason: `BLOCKED (memory guard): author context cannot be established — ${key.reason}` };
  const pending = domains.filter((d) => !fs.existsSync(markerPath(ctx.state.stateDir, key.key, d.domain)));
  if (!pending.length) return { decision: 'none', state: 'active' };
  const d = pending[0];
  const ack = `node <plugin_root>/scripts/hook-runner.mjs --host ${event.host} --hook guard-memory --ack --domain ${d.domain} --project-root "${ctx.projectRoot}"${event.session.agent_id ? ` --agent ${event.session.agent_id}` : ''}${ctx.env.HARNESS_EXECUTOR_ID ? ` --executor ${ctx.env.HARNESS_EXECUTOR_ID}` : ''} --session ${event.session.id}`;
  const reason = [
    `BLOCKED (memory guard): first code edit in domain "${d.domain}" for this author context (${d.path}).`,
    `Project memory is large (${total} bytes across errors/patterns/decisions, threshold ${threshold}).`,
    'Loading it whole into this window would crowd out task context, so distill it FIRST:',
    '', `  1. Read .agents/memory/domain/${d.domain}.md IN FULL if it exists, then errors.md, patterns.md and decisions.md, and keep ONLY the entries relevant to this task (~2k tokens); a subagent may do this where the host has one.`,
    `  2. Acknowledge for this exact context (project, host, session, child) — never reuse a parent's marker:`, '', `       ${ack}`, '',
    'Then re-issue this edit. The marker records that memory was checked for this domain and context; it is trusted, not proof of execution.',
  ].join('\n');
  return { decision: 'deny', state: 'active', reason, domain: d.domain, context: undefined };
}
