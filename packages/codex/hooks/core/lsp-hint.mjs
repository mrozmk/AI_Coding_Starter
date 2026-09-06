// nudge-lsp (T10): symbol-shaped search → pointer to LSP navigation, ported from
// .claude/hooks/nudge-lsp.sh. Conditional twice over: it needs a structured search event (Claude's
// Grep; Codex has none → unsupported, legacy-only) and a project that declares an LSP (the rules
// carry a Code Navigation section → otherwise dormant, not applicable). Never blocks.
import fs from 'node:fs';
import path from 'node:path';

export const id = 'nudge-lsp';
export const strength = 'advisory';

function declaresLsp(projectRoot) {
  for (const f of ['CLAUDE.md', '.agents/project-rules.md']) {
    try { if (/Code Navigation/.test(fs.readFileSync(path.join(projectRoot, f), 'utf8'))) return true; } catch { /* absent */ }
  }
  return false;
}

export async function run(event, ctx) {
  if (event.host === 'codex') return { decision: 'none', state: 'unsupported', reason: 'Codex has no structured search event; shell bodies are not parsed as Grep' };
  if (event.tool !== 'search' || !event.search?.pattern) return { decision: 'none', state: 'active' };
  if (!declaresLsp(ctx.projectRoot)) return { decision: 'none', state: 'dormant', reason: 'no LSP declared (rules have no Code Navigation section)' };
  const { pattern, glob, path: p } = event.search;
  if (!/^[A-Za-z_][A-Za-z0-9_]{2,}$/.test(pattern)) return { decision: 'none', state: 'active' };
  if (/\.(json|md|mdx|css|scss|yml|yaml|txt|html|lock)$/.test(`${glob}${p}`)) return { decision: 'none', state: 'active' };
  return { decision: 'none', state: 'active', context: `Searched for the symbol "${pattern}" with Grep. If you are navigating code (where is it defined, who calls it, its signature), an LSP tool is more precise — goToDefinition / findReferences / incomingCalls / hover return real symbol references, not text matches. Grep stays correct for free-text and non-code files. See the project rules → Code Navigation.` };
}
