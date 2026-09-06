// guard-push (T11): pre-publication secret scan over the per-commit patches about to leave the
// machine. Ported from .claude/hooks/guard-push.sh: same classes (known-format tokens, private keys,
// credential connection strings, hardcoded credential assignments, credential filenames, optional
// gitleaks), same allowlisted paths, same explicit audited override, paths-only report. Deliberate
// strengthening recorded in the ledger: without git the scan cannot run and the push is refused,
// where the Bash version failed open when jq was missing.
import { execFileSync, spawnSync } from 'node:child_process';
import { appendAudit } from '../../scripts/lib/telemetry.mjs';
import { gitAvailable, resolveRepo } from './commit.mjs';

export const id = 'guard-push';
export const strength = 'hard';

const HIGH_RE = new RegExp([
  '-----BEGIN[A-Z ]*PRIVATE KEY-----', 'AKIA[0-9A-Z]{16}', 'ASIA[0-9A-Z]{16}', 'gh[pousr]_[0-9A-Za-z]{36}', 'github_pat_[0-9A-Za-z_]{82}',
  'xox[baprs]-[0-9A-Za-z-]{10,}', 'xapp-[0-9A-Za-z-]{10,}', 'glpat-[0-9A-Za-z_-]{20}', 'AIza[0-9A-Za-z_-]{35}', 'sk-ant-[0-9A-Za-z_-]{20,}', 'sk-proj-[0-9A-Za-z_-]{20,}',
  '(sk|rk)_live_[0-9A-Za-z]{20,}', 'shp(at|ss)_[0-9a-fA-F]{32}', 'SG\\.[0-9A-Za-z_-]{22}\\.[0-9A-Za-z_-]{43}', 'ATATT[0-9A-Za-z_=.-]{20,}', 'npm_[0-9A-Za-z]{36}',
  'eyJ[0-9A-Za-z_-]{8,}\\.eyJ[0-9A-Za-z_-]{8,}\\.[0-9A-Za-z_-]{8,}', '(postgres(ql)?|mysql|mongodb(\\+srv)?|redis|amqps?|ftp)://[^:@/\\s]+:[^@/\\s]+@', 'SK[0-9a-f]{32}',
].join('|'));
const A4_RE = /(password|passwd|pwd|secret|api[_-]?key|apikey|access[_-]?key|secret[_-]?key|access[_-]?token|auth[_-]?token|client[_-]?secret|private[_-]?key)["']?\s*[:=]\s*["'][^"']{8,}["']/i;
const A4_PLACEHOLDER = /process\.env|os\.environ|getenv|System\.getenv|ENV\[|secrets\.|vault|\$\{|\$\(|<[A-Za-z0-9_]+>|x{3,}|changeme|change-me|your[_-]|example|placeholder|dummy|sample|redacted|fake|mock|null|none|undefined|\*{3,}|\.\.\.|%s|\{\{|0{6,}|123456/i;
const ALLOW_MARK = /guard-push:allow|pragma: ?allowlist secret|gitleaks:allow/i;
const FILE_RE = /(^|\/)\.env($|\.)|(^|\/)id_(rsa|dsa|ecdsa|ed25519)$|\.(pem|key|p12|pfx|keystore|jks|ppk)$|(^|\/)\.(npmrc|pypirc|netrc|htpasswd)$|(^|\/)\.aws\/credentials$|(^|\/)kubeconfig$|\.(tfstate|tfvars)$|service[_-]?account.*\.json$/;
const FILE_ALLOW = /\.(example|sample|template)$|\.dist$/;
const SKIP_PATH = /\.(example|sample|template|lock|md|snap|map)$|(^|\/)\.agents\/reference\/|(^|\/)\.claude\/(settings\.json|memory-domains\.json)$|(^|\/)\.claude\/hooks\/guard-push\.sh$|(^|\/)hooks\/core\/push\.mjs$|(^|\/)(fixtures|__fixtures__|__mocks__|testdata)\/|(package-lock\.json|yarn\.lock|pnpm-lock\.yaml|composer\.lock|Cargo\.lock|poetry\.lock|go\.sum)$/;

let gitEnv = process.env;
function git(dir, args, opts = {}) {
  return execFileSync('git', ['-C', dir, ...args], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'], maxBuffer: 256 * 1024 * 1024, env: gitEnv, ...opts });
}

function pushArgs(command) {
  const m = command.match(/git\s+(-[Cc]\s+\S+\s+)*push\s+([^;&|]*)/);
  return m ? m[2].trim().split(/\s+/).filter(Boolean) : [];
}

// The tip about to be published and the range not yet on the remote (per-commit, never net diff).
export function publishRange(dir, command) {
  let tip = 'HEAD';
  let remoteSeen = false;
  for (const a of pushArgs(command)) {
    if (a.startsWith('-')) continue;
    if (!remoteSeen) { remoteSeen = true; continue; }
    const src = a.split(':')[0];
    try { git(dir, ['rev-parse', '--verify', '--quiet', src]); tip = src; } catch { /* keep HEAD */ }
    break;
  }
  let branch = tip;
  if (tip === 'HEAD') { try { branch = git(dir, ['rev-parse', '--abbrev-ref', 'HEAD']).trim(); } catch { branch = ''; } }
  if (!branch || branch === 'HEAD') return [tip, '--not', '--remotes'];
  try { git(dir, ['rev-parse', '--verify', '--quiet', `origin/${branch}`]); return [`origin/${branch}..${tip}`]; } catch { return [tip, '--not', '--remotes']; }
}

// Added lines (path + content) across the per-commit patches, allowlisted paths skipped.
export function addedLines(patchText) {
  const out = [];
  let file = null;
  let skip = true;
  for (const line of patchText.split('\n')) {
    if (line.startsWith('+++ ')) { file = line.slice(4).replace(/^b\//, ''); skip = file === '/dev/null' || SKIP_PATH.test(file); continue; }
    if (line.startsWith('--- ')) continue;
    if (line.startsWith('+') && !skip && file) out.push({ file, text: line.slice(1) });
  }
  return out;
}

export function scan(lines, names) {
  const high = lines.filter((l) => HIGH_RE.test(l.text) && !ALLOW_MARK.test(l.text));
  const a4 = lines.filter((l) => A4_RE.test(l.text) && !A4_PLACEHOLDER.test(l.text) && !ALLOW_MARK.test(l.text));
  const files = names.filter((n) => FILE_RE.test(n) && !FILE_ALLOW.test(n));
  return { high: [...new Set(high.map((l) => l.file))], a4: [...new Set(a4.map((l) => l.file))], files };
}

export async function run(event, ctx) {
  if (event.tool !== 'shell' || !event.shell?.git?.subcommands?.includes('push')) return { decision: 'none', state: 'active' };
  const cmd = event.shell.command;
  if (/--dry-run/.test(cmd) || /--delete(\s|=)|\s:[^\s]/.test(cmd)) return { decision: 'none', state: 'active', reason: 'nothing published' };
  if (/GUARD_PUSH_SKIP=(1|true|yes)/.test(cmd)) {
    try { appendAudit(ctx.state.audit, { phase: 'ATTEMPT', label: 'PUSH', value: `GUARD-PUSH OVERRIDE: ${cmd}`, now: ctx.now }); } catch { /* never blocks */ }
    return { decision: 'none', state: 'active', context: 'guard-push: OVERRIDE — GUARD_PUSH_SKIP set, secret scan bypassed for this push (audited).', override: true };
  }
  gitEnv = ctx.env;
  if (!gitAvailable(ctx.env)) return { decision: 'deny', state: 'error', reason: 'BLOCKED: guard-push cannot scan the commits about to be published — git is not available. Missing infrastructure is missing protection, not a pass.' };
  const dir = resolveRepo(event.shell, { cwd: event.cwd, projectRoot: ctx.projectRoot, env: ctx.env });
  if (!dir) return { decision: 'deny', state: 'error', reason: `BLOCKED: guard-push found no git repository at ${event.shell.target_dir}.` };
  const range = publishRange(dir, cmd);
  let patch = '';
  let names = [];
  try {
    patch = git(dir, ['log', '-p', '--no-color', ...range]);
    names = [...new Set(git(dir, ['log', '--name-only', '--pretty=format:', ...range]).split('\n').map((s) => s.trim()).filter(Boolean))];
  } catch (e) {
    return { decision: 'deny', state: 'error', reason: `BLOCKED: guard-push could not read the publish range (${range.join(' ')}): ${e.message.split('\n')[0]}` };
  }
  const hits = scan(addedLines(patch), names);
  let gitleaks = null;
  const gl = spawnSync('gitleaks', ['detect', '--source', dir, '--no-banner', '--redact', `--log-opts=${range.join(' ')}`], { encoding: 'utf8', env: ctx.env });
  if (gl.status === 1) gitleaks = `gitleaks reported leaks in the push range (run: gitleaks detect --log-opts="${range.join(' ')}")`;
  if (!hits.high.length && !hits.a4.length && !hits.files.length && !gitleaks) return { decision: 'none', state: 'active', range: range.join(' ') };
  const lines = [`BLOCKED: guard-push detected likely secrets/credentials in the commits about to be pushed (${range.join(' ')}).`, 'Push is the publication boundary — fix this BEFORE it leaves the machine.', ''];
  if (hits.high.length) lines.push('• Known-format secret/token or private key in:', ...hits.high.map((f) => `    - ${f}`));
  if (hits.a4.length) lines.push('• Hardcoded credential assignment in:', ...hits.a4.map((f) => `    - ${f}`));
  if (hits.files.length) lines.push('• Credential file staged for push:', ...hits.files.map((f) => `    - ${f}`));
  if (gitleaks) lines.push(`• ${gitleaks}`);
  lines.push('', 'How to resolve:', '  1. Remove the secret from the file, rotate it if it was real, and amend/rewrite the offending commit(s). (History rewrite is a human act.)', "  2. False positive? Add an inline marker on the line: '# guard-push:allow' (or 'pragma: allowlist secret'), or move sample values to a *.example / *.sample file.", '  3. Genuine emergency override (audited): re-run as  GUARD_PUSH_SKIP=1 git push ...');
  return { decision: 'deny', state: 'active', reason: lines.join('\n'), hits };
}
