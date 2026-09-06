// check-deps (T12): SessionStart preflight, ported from .claude/hooks/check-deps.sh and extended
// with the shared dependency preflight and the delegation to the project-owned
// check-project-deps.sh. Silent when healthy; one loud context line when something is missing.
// Missing infrastructure is reported as missing protection, never as healthy enforcement.
import { dependencyPreflight } from '../../scripts/preflight-deps.mjs';

export const id = 'check-deps';
export const strength = 'preflight';

export async function run(event, ctx) {
  if (event.event && event.event !== 'SessionStart') return { decision: 'none', state: 'active' };
  const res = dependencyPreflight({ projectRoot: ctx.projectRoot, host: event.host, env: ctx.env });
  const lines = [];
  const missing = res.checks.filter((c) => !c.ok);
  if (missing.length) {
    lines.push(`⚠️  Harness preflight: ${missing.map((c) => `${c.name} (${c.required ? 'required' : 'optional'})`).join(', ')} missing.`);
    for (const c of missing) lines.push(`   - ${c.name}: ${c.detail}`);
    if (missing.some((c) => c.name === 'git')) lines.push('   - without git the commit and push guards cannot run and will BLOCK — that is missing protection, not a pass.');
  }
  if (res.project.error) lines.push(`   - project preflight: ${res.project.error}`);
  else if (res.project.ran && res.project.output) lines.push(res.project.output);
  if (!lines.length) return { decision: 'none', state: 'active' };
  return { decision: 'none', state: missing.some((c) => c.required) ? 'error' : 'active', context: lines.join('\n'), preflight: res };
}
