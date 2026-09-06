// guard-commit (T11): refuse `git commit` when the staged set of the target repository is empty.
// Ported from .claude/hooks/guard-commit.sh with the same target resolution (git -C, leading cd,
// caller cwd, project root) and the same audit line. Known limit kept on purpose: a chained
// `git add X && git commit` is inspected before the chain runs and is therefore blocked.
import { execFileSync } from 'node:child_process';
import { appendAudit } from '../../scripts/lib/telemetry.mjs';

export const id = 'guard-commit';
export const strength = 'hard';

const SKIP_RE = /--amend|--dry-run|--no-edit|--help|--all(\s|$)|(^|\s)-[a-zA-Z]*a[a-zA-Z]*(\s|$)|(^|\s)-h(\s|$)/;

function git(dir, args, env = process.env) {
  return execFileSync('git', ['-C', dir, ...args], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'], env }).trim();
}

export function gitAvailable(env = process.env) {
  try { execFileSync('git', ['--version'], { stdio: 'ignore', env }); return true; } catch { return false; }
}

export function resolveRepo(shell, ctx) {
  const candidates = [shell.target_dir, ctx.cwd, ctx.projectRoot].filter(Boolean);
  for (const dir of candidates) {
    try { git(dir, ['rev-parse', '--git-dir'], ctx.env); return dir; } catch { /* next */ }
  }
  return null;
}

export async function run(event, ctx) {
  if (event.tool !== 'shell' || !event.shell?.git?.subcommands?.includes('commit')) return { decision: 'none', state: 'active' };
  const cmd = event.shell.command;
  if (SKIP_RE.test(cmd)) return { decision: 'none', state: 'active', reason: 'commit form with a legitimately empty index' };
  if (!gitAvailable(ctx.env)) return { decision: 'deny', state: 'error', reason: 'BLOCKED: guard-commit cannot verify the staged set — git is not available. A required protection that cannot run blocks instead of passing.' };
  const dir = resolveRepo(event.shell, { cwd: event.cwd, projectRoot: ctx.projectRoot, env: ctx.env });
  if (!dir) return { decision: 'deny', state: 'error', reason: `BLOCKED: guard-commit found no git repository at ${event.shell.target_dir} — cannot verify what this commit would record.` };
  const staged = git(dir, ['diff', '--cached', '--name-only'], ctx.env);
  if (!staged) {
    const chained = event.shell.chained_add_commit ? ' This command chains `git add … && git commit`: the guard inspects the index before the chain runs, so stage and commit in two separate calls.' : '';
    return { decision: 'deny', state: 'active', reason: `BLOCKED: 'git commit' with an empty staged set (git -C '${dir}' diff --cached is empty).\nNothing is staged for commit. If this is an orchestrate step, this is the empty/hallucinated-commit guard: stage the real FILES_TOUCHED with explicit 'git add <path>' first, or report STATUS: nothing_to_commit.${chained}` };
  }
  try { appendAudit(ctx.state.audit, { phase: 'ATTEMPT', label: 'COMMIT', value: `staged in ${dir}: ${staged.split('\n').join(', ')}`, now: ctx.now }); } catch { /* telemetry never blocks */ }
  return { decision: 'none', state: 'active', staged: staged.split('\n') };
}
