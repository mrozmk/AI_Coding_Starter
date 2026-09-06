// guard-comments (T10): advisory comment-noise nudge, ported from .claude/hooks/guard-comments.sh.
// Same configured globs (shell `case` semantics: `*` spans `/`), same exemptions, same thresholds,
// same message. Multi-file patches are checked per file; one nudge names every offender. Never blocks.
export const id = 'guard-comments';
export const strength = 'advisory';

export const EXEMPT_RE = /(\.test\.|\.spec\.|_test\.|Test\.|\/__tests__\/|\/__mocks__\/|\/test\/|\/tests\/|\.stories\.|\.story\.|\/node_modules\/|\/vendor\/|\/dist\/|\/build\/|\/\.venv\/)/;

// Shell-style glob where `*` spans path separators (the legacy hooks' `case` semantics).
export function globToRegExp(glob) {
  const esc = glob.replace(/[.+^${}()|[\]\\]/g, '\\$&').replace(/\*/g, '.*').replace(/\?/g, '.');
  return new RegExp(`^${esc}$`);
}

export function matchesAny(rel, globs) {
  return (globs ?? []).some((g) => g && globToRegExp(g).test(rel));
}

export function commentPattern(rel) {
  if (/\.(html|htm|vue|svelte|xml|xhtml|astro)$/.test(rel)) return /^\s*<!--/;
  if (/\.(py|rb|sh|bash|zsh|pl|r|R|jl|ex|exs|tf|yaml|yml|toml)$/.test(rel)) return /^\s*#/;
  if (/\.(sql|lua|hs|elm|adb|ads)$/.test(rel)) return /^\s*--/;
  if (/\.(ts|tsx|js|jsx|mjs|cjs|java|kt|kts|go|rs|swift|c|h|cc|cpp|hpp|cs|scss|less|css|php|dart|scala|groovy|m|mm)$/.test(rel)) return /^\s*(\/\/|\/\*|\*)/;
  return null;
}

export function measure(content, pattern) {
  const lines = content.split('\n').filter((l) => l.trim());
  return { total: lines.length, comments: lines.filter((l) => pattern.test(l)).length };
}

export async function run(event, ctx) {
  if (event.tool !== 'file-edit' || event.changes.length === 0) return { decision: 'none', state: 'active' };
  const config = ctx.config.values.comment_guard;
  if (!config || !(config.src_globs ?? []).length) return { decision: 'none', state: 'dormant', reason: 'comment-guard.json has no src_globs' };
  const minLines = Number.isInteger(config.min_comment_lines) ? config.min_comment_lines : 3;
  const maxPct = Number.isInteger(config.max_comment_percent) ? config.max_comment_percent : 15;
  const offenders = [];
  for (const c of event.changes) {
    if (c.op === 'delete' || !c.content) continue;
    if (!matchesAny(c.path, config.src_globs) || EXEMPT_RE.test(c.path)) continue;
    if (/@generated|DO NOT EDIT/.test(c.content)) continue;
    const pattern = commentPattern(c.path);
    if (!pattern) continue;
    const { total, comments } = measure(c.content, pattern);
    if (total === 0 || comments <= minLines || Math.floor((comments * 100) / total) <= maxPct) continue;
    offenders.push({ path: c.path, comments, total });
  }
  if (!offenders.length) return { decision: 'none', state: 'active' };
  const head = offenders.map((o) => `${o.path}: ${o.comments} comment lines out of ${o.total} non-blank lines`).join('; ');
  return { decision: 'none', state: 'active', context: `That write was comment-heavy (${head}). Re-read the diff and delete narration: a comment restating the adjacent statement, echoing a variable/function name, or repeating what the signature already says is noise. Keep only a WHY the code cannot express — a vendor quirk, a rejected alternative, a non-obvious invariant, or a workaround with a ticket reference — capped at 1-2 lines. Longer reasoning belongs in .agents/memory/ or the spec, with a one-line pointer from the code. See the project rules → Style & Conventions.` };
}
