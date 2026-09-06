// nudge-files (T10): first matching project-configured file-class reminder, ported from
// .claude/hooks/nudge-files.sh. Same glob semantics and exemptions as the comments nudge; for a
// multi-file patch each file gets its own first-match rule and one context lists them. Never blocks.
import { EXEMPT_RE, globToRegExp } from './comments.mjs';

export const id = 'nudge-files';
export const strength = 'advisory';

export function firstRule(rel, rules) {
  for (const r of rules ?? []) if (r?.glob && globToRegExp(r.glob).test(rel)) return r;
  return null;
}

export async function run(event, ctx) {
  if (event.tool !== 'file-edit' || event.changes.length === 0) return { decision: 'none', state: 'active' };
  const config = ctx.config.values.nudge_rules;
  if (!config || !(config.rules ?? []).length) return { decision: 'none', state: 'dormant', reason: 'nudge-rules.json has no rules' };
  const reminders = [];
  for (const c of event.changes) {
    if (c.op === 'delete' || EXEMPT_RE.test(c.path)) continue;
    if (c.content && /@generated|DO NOT EDIT/.test(c.content)) continue;
    const rule = firstRule(c.path, config.rules);
    if (rule?.message) reminders.push(`Reminder for ${c.path}: ${rule.message}`);
  }
  if (!reminders.length) return { decision: 'none', state: 'active' };
  return { decision: 'none', state: 'active', context: reminders.join('\n') };
}
