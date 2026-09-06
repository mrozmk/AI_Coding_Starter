// Normalized hook event model (T09). Both host adapters produce this shape; every core policy reads
// only this shape. Shell commands are normalized (target directory, git subcommand); patches become
// bounded per-file change events without ever executing payload text.
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { toPosix } from './fsx.mjs';

export const MAX_PATCH_FILES = 200;
export const MAX_PATCH_BYTES = 2 * 1024 * 1024;

export function makeEvent(partial) {
  return {
    host: null, event: null, tool: 'other', raw_tool_name: null,
    session: { id: null, agent_id: null, parent_shared: false },
    cwd: null, project_root: null,
    shell: null, changes: [], reads: [], search: null, url: null,
    ...partial,
  };
}

// Project root: explicit host variable, else the git toplevel of cwd, else cwd. Never the plugin root.
export function resolveProjectRoot({ env = process.env, cwd = process.cwd(), explicit = null } = {}) {
  const candidate = explicit ?? env.CLAUDE_PROJECT_DIR ?? env.HARNESS_PROJECT_ROOT ?? null;
  if (candidate) return path.resolve(candidate);
  try {
    return execFileSync('git', ['rev-parse', '--show-toplevel'], { cwd, encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }).trim();
  } catch {
    return path.resolve(cwd);
  }
}

export function relTo(root, p) {
  if (!p) return p;
  const abs = path.isAbsolute(p) ? p : path.resolve(root, p);
  const rel = path.relative(root, abs);
  return rel.startsWith('..') ? toPosix(abs) : toPosix(rel);
}

const QUOTED = '("([^"]+)"|\'([^\']+)\'|([^\\s&;|]+))';

// Shell normalization: where the command runs (git -C, leading cd) and which git subcommand it is.
// Only these two directory forms are parsed — a known limit recorded in the hook ledger.
export function normalizeShell(command, { cwd, root }) {
  const gitC = command.match(new RegExp(`(?:^|[;&|\\s])git\\s+(?:-c\\s+\\S+\\s+)*-C\\s+${QUOTED}`));
  const cd = command.match(new RegExp(`^\\s*cd\\s+${QUOTED}`));
  const pick = (m) => (m ? (m[2] ?? m[3] ?? m[4]) : null);
  let target = pick(gitC) ?? pick(cd) ?? cwd ?? root;
  if (target && !path.isAbsolute(target)) target = path.resolve(cwd ?? root, target);
  const subcommands = [...command.matchAll(/(?:^|[;&|\s])git(?:\s+-[Cc]\s+(?:"[^"]+"|'[^']+'|\S+)|\s+-c\s+\S+)*\s+(commit|push|add|merge|rebase|reset|worktree|checkout|switch)(?=\s|$)/g)].map((m) => m[1]);
  const chained = /(^|[;&|])\s*git\s+add\b[^;&|]*&&\s*git\s+commit\b/.test(command);
  // Primary = the most consequential subcommand present; guards test `subcommands` for their own.
  const primary = ['push', 'commit', 'merge', 'rebase', 'reset', 'worktree', 'checkout', 'switch', 'add'].find((s) => subcommands.includes(s)) ?? null;
  return { command, target_dir: target, git: subcommands.length ? { subcommand: primary, subcommands } : null, chained_add_commit: chained };
}

// Codex apply_patch payload → per-file events. Bounded; never executed; hunk `+` lines are the
// new content, so advisory checks see what actually landed in each file.
export function parseApplyPatch(text) {
  const changes = [];
  if (typeof text !== 'string') return { changes, truncated: false };
  const bytes = Buffer.byteLength(text, 'utf8');
  const truncated = bytes > MAX_PATCH_BYTES;
  const lines = text.split('\n');
  let cur = null;
  const flush = () => { if (cur) { cur.content = cur.added.join('\n'); delete cur.added; changes.push(cur); cur = null; } };
  for (const line of lines) {
    const add = line.match(/^\*\*\* Add File: (.+)$/);
    const upd = line.match(/^\*\*\* Update File: (.+)$/);
    const del = line.match(/^\*\*\* Delete File: (.+)$/);
    const mv = line.match(/^\*\*\* Move to: (.+)$/);
    if (add || upd || del) {
      flush();
      if (changes.length >= MAX_PATCH_FILES) break;
      cur = { op: add ? 'add' : upd ? 'update' : 'delete', path: toPosix((add ?? upd ?? del)[1].trim()), added: [] };
      continue;
    }
    if (mv && cur) { cur.op = 'move'; cur.from = cur.path; cur.path = toPosix(mv[1].trim()); continue; }
    if (/^\*\*\* (Begin|End) Patch/.test(line)) { if (/End/.test(line)) flush(); continue; }
    if (cur && line.startsWith('+') && !line.startsWith('+++')) cur.added.push(line.slice(1));
  }
  flush();
  return { changes, truncated };
}

export function changedContent(event) {
  return event.changes.map((c) => c.content ?? '').filter(Boolean).join('\n');
}
