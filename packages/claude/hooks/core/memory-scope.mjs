// guard-memory-scope (T10): advisory reroute for misplaced errors.md entries, ported from
// .claude/hooks/guard-memory-scope.sh. Active only when memory-domains.json carries
// app_source_regex. Never deletes, never moves, never blocks.
export const id = 'guard-memory-scope';
export const strength = 'advisory';

const HARNESS_RE = /\.claude\/|\.agents\/|slash command|slash-command|subagent|MCP |orchestrate|gates(:|-)|\bhooks?\b|PreToolUse|PostToolUse|\bzsh\b|\bbash\b|ripgrep|\brg \b|git merge|git rebase|design file|Jira ticket|design ticket|review comment|DevTools/;
const TEST_RE = /\.spec\.|\.test\.|test runner|Storybook|Playwright|jsdom|coverage threshold|snapshot test/;

export async function run(event, ctx) {
  if (event.tool !== 'file-edit') return { decision: 'none', state: 'active' };
  const entries = event.changes.filter((c) => /(^|\/)\.agents\/memory\/errors\.md$/.test(c.path) && c.content);
  if (!entries.length) return { decision: 'none', state: 'active' };
  const appRe = ctx.config.values.memory_domains?.app_source_regex;
  if (!appRe) return { decision: 'none', state: 'dormant', reason: 'memory-domains.json has no app_source_regex' };
  const content = entries.map((e) => e.content).join('\n');
  if (/^## Scope/m.test(content)) return { decision: 'none', state: 'active', reason: 'preamble maintenance, not an entry' };
  const reasons = [];
  if (HARNESS_RE.test(content)) reasons.push('harness/workflow markers');
  if (TEST_RE.test(content)) reasons.push('test-harness markers');
  if (!new RegExp(appRe).test(content)) reasons.push('no application source path cited');
  if (!reasons.length) return { decision: 'none', state: 'active' };
  return { decision: 'none', state: 'active', context: `That write to .agents/memory/errors.md tripped the scope check (${reasons.join('; ')}). errors.md is APPLICATION CODE ONLY — it is loaded whole on every debugging session, so a misrouted entry taxes all of them. Re-read the entry against the Scope section at the top of the file and move it if it belongs elsewhere: a broken slash command, hook, subagent, MCP server, shell/git/CLI invocation, a lying debugging tool, or a misread design file / ticket / review comment -> .agents/memory/domain/harness.md. A spec, test-runner, jsdom, Storybook or Playwright trap -> .agents/memory/domain/testing.md. Anything scoped to one module -> that module's domain/*.md. An entry that stays must name the application source file it is about. If none of that applies, the entry likely fails the bar entirely — the default outcome of a reflection pass is to write nothing; delete it.` };
}
