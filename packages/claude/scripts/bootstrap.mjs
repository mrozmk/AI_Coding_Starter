#!/usr/bin/env node
// Project bootstrap helpers (T05/T12): seed the generic memory layer absent-only, and report the
// readiness of a project for the planning skills — rules authority, profile, memory, binding,
// dependency preflight. Nothing here overwrites a file that exists; nothing here reads .env.
//
//   node scripts/bootstrap.mjs seed   --project-root <dir> [--consent yes]
//   node scripts/bootstrap.mjs report --project-root <dir> --host claude|codex [--plugin-root <dir>]
//   node scripts/bootstrap.mjs wrappers --project-root <dir> --plugin-root <dir> [--consent yes]
//   node scripts/bootstrap.mjs swap   --project-root <dir> [--name <n>] [--description <d>]
//                                     [--license starter] [--consent yes]
import fs from 'node:fs';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { parseArgv, requireOpt } from './lib/argv.mjs';
import { isInside, listFiles, readJson, realpathOrSelf, toPosix, writeBytes } from './lib/fsx.mjs';
import { sha256Hex } from './lib/digest.mjs';
import { STATE_DIR } from './lib/locator.mjs';
import { parseFrontmatter } from './lib/frontmatter.mjs';
import { checkVersion, effective, readProfile } from './profile.mjs';
import { resolveRulesAuthority, templatesDir } from './rules.mjs';
import { dependencyPreflight } from './preflight-deps.mjs';

export const MEMORY_DIR = '.agents/memory';
// Seed set: routing/reflection + empty placeholders. user-profile stays an .example (per-developer).
export const MEMORY_SEED = ['index.md', 'reflection-protocol.md', 'project-brief.md', 'architecture.md', 'patterns.md', 'decisions.md', 'errors.md', 'api.md', 'domain/business-model.md', 'user-profile.md.example'];
export const SCAFFOLD_DIRS = ['.agents/specs', '.agents/plans/active', '.agents/plans/done', '.agents/reference', '.agents/sources', '.agents/memory/domain'];
// Project-owned reference overlays: seeded absent-only like memory, but they live under
// .agents/reference/ rather than .agents/memory/. Source is templates/reference/<from>.
export const REFERENCE_SEED = [{ from: 'qa-evidence-families-project.md', to: '.agents/reference/qa-evidence-families.md' }];

function memoryTemplates() {
  return path.join(templatesDir(), 'memory');
}

// Absent-only. A present file — populated or empty — is `kept` untouched; never merged, never
// rewritten. `{seed-date}` in a template becomes today's date at seed time.
export function seedMemory({ projectRoot, consent = false, today = new Date().toISOString().slice(0, 10) }) {
  const root = path.resolve(projectRoot);
  const src = memoryTemplates();
  const actions = [];
  for (const dir of SCAFFOLD_DIRS) {
    const abs = path.join(root, dir);
    if (fs.existsSync(abs)) { actions.push({ path: dir, action: 'kept' }); continue; }
    actions.push({ path: dir, action: consent ? 'created' : 'would-create' });
    if (consent) fs.mkdirSync(abs, { recursive: true });
  }
  for (const rel of MEMORY_SEED) {
    const target = path.join(root, MEMORY_DIR, rel);
    const dest = toPosix(path.join(MEMORY_DIR, rel));
    if (fs.existsSync(target)) { actions.push({ path: dest, action: 'kept' }); continue; }
    const text = fs.readFileSync(path.join(src, rel), 'utf8').split('{seed-date}').join(today);
    actions.push({ path: dest, action: consent ? 'created' : 'would-create' });
    if (consent) { fs.mkdirSync(path.dirname(target), { recursive: true }); fs.writeFileSync(target, text); }
  }
  for (const { from, to } of REFERENCE_SEED) {
    const target = path.join(root, to);
    if (fs.existsSync(target)) { actions.push({ path: to, action: 'kept' }); continue; }
    const text = fs.readFileSync(path.join(templatesDir(), 'reference', from), 'utf8').split('{seed-date}').join(today);
    actions.push({ path: to, action: consent ? 'created' : 'would-create' });
    if (consent) { fs.mkdirSync(path.dirname(target), { recursive: true }); fs.writeFileSync(target, text); }
  }
  return { actions, created: actions.filter((a) => a.action === 'created').length, kept: actions.filter((a) => a.action === 'kept').length };
}

function statusOf(abs) {
  if (!fs.existsSync(abs)) return 'absent';
  try { return parseFrontmatter(fs.readFileSync(abs, 'utf8')).data.status ?? 'no-frontmatter'; } catch { return 'no-frontmatter'; }
}

// One readiness verdict for prime/setup: `ready` only when every operational rule is resolved.
// Optional project knowledge (brief, architecture, PRD) is a visible warning, never a blocker.
export function readiness({ projectRoot, host, pluginRoot = null }) {
  const root = path.resolve(projectRoot);
  const rules = resolveRulesAuthority(root);
  const profile = readProfile(root);
  const eff = effective(profile);
  const memory = { index: fs.existsSync(path.join(root, MEMORY_DIR, 'index.md')), reflection: fs.existsSync(path.join(root, MEMORY_DIR, 'reflection-protocol.md')), brief: statusOf(path.join(root, MEMORY_DIR, 'project-brief.md')), architecture: statusOf(path.join(root, MEMORY_DIR, 'architecture.md')), prd: fs.existsSync(path.join(root, 'docs/PRD.md')), user_profile: statusOf(path.join(root, MEMORY_DIR, 'user-profile.md')) };
  const binding = host ? checkVersion({ projectRoot: root, host, pluginRoot }) : { ok: false, errors: ['no host given'] };
  const deps = dependencyPreflight({ projectRoot: root, host });
  const blockers = [];
  const warnings = [];
  if (rules.mode === 'none') blockers.push('no project rules (CLAUDE.md or .agents/project-rules.md) — run setup-start');
  if (rules.mode === 'conflict') blockers.push(rules.warnings[0]);
  if (rules.mode !== 'none' && rules.mode !== 'conflict' && !rules.ready) {
    const parts = [];
    if (rules.unresolved_required.length) parts.push(`unresolved: ${rules.unresolved_required.join(', ')}`);
    if (rules.drift?.length) parts.push(`CLAUDE.md out of sync with .agents/project-rules.md (${rules.drift.map((d) => d.fact).join(', ')}) — re-run rules.mjs render`);
    blockers.push(`rules incomplete — ${parts.join('; ')}`);
  }
  if (profile.status !== 'ok') blockers.push(`profile ${profile.status}: ${profile.message}`);
  if (!memory.index) blockers.push('no .agents/memory/index.md — run bootstrap seed');
  if (!binding.ok) blockers.push(`harness not bound: ${binding.errors.join('; ')}`);
  for (const d of deps.checks) if (!d.ok && d.required) blockers.push(`dependency missing: ${d.name} — ${d.detail}`);
  for (const d of deps.checks) if (!d.ok && !d.required) warnings.push(`optional dependency missing: ${d.name} — ${d.detail}`);
  if (!['populated', 'seeded'].includes(memory.brief)) warnings.push(`project-brief.md is ${memory.brief}${memory.prd ? ' — docs/PRD.md available as fallback' : ' and no docs/PRD.md — no product context yet'}`);
  if (!['populated', 'seeded'].includes(memory.architecture)) warnings.push(`architecture.md is ${memory.architecture} — prime falls back to a shallow file listing`);
  warnings.push(...rules.warnings.filter((w) => !blockers.includes(w)));
  return { ready: blockers.length === 0, blockers, warnings, rules: { mode: rules.mode, authority: rules.authority, unresolved_required: rules.unresolved_required }, profile: { status: profile.status, file: profile.file ?? null, groups: eff.status === 'ok' ? eff.groups : null }, memory, binding: binding.ok ? { root: binding.root, version: binding.version } : { errors: binding.errors }, dependencies: deps };
}

// Wrapper adoption (Claude Code): copy templates/wrappers/*.md from the installed plugin into the
// project's .claude/commands/ so the bare command routes to the plugin skill. Preview by default;
// `consent` writes. Wrappers are ordinary starter files (sync category A), never migrated records.
export function syncWrappers({ projectRoot, pluginRoot, consent = false }) {
  const src = path.join(pluginRoot, 'templates/wrappers');
  if (!fs.existsSync(src)) return { ok: false, reason: `no templates/wrappers under ${pluginRoot}`, files: [] };
  const dest = path.join(projectRoot, '.claude/commands');
  const files = [];
  // Recursive: a namespaced wrapper such as setup/create-PRD.md lands in a subdirectory of both
  // the plugin's templates/wrappers/ and the project's .claude/commands/.
  for (const name of listFiles(src).files.filter((f) => f.endsWith('.md'))) {
    const text = fs.readFileSync(path.join(src, name), 'utf8');
    const target = path.join(dest, name);
    const before = fs.existsSync(target) ? fs.readFileSync(target, 'utf8') : null;
    const status = before === null ? 'created' : before === text ? 'kept' : 'updated';
    if (status !== 'kept' && consent) { fs.mkdirSync(path.dirname(target), { recursive: true }); fs.writeFileSync(target, text); }
    files.push({ path: toPosix(path.relative(projectRoot, target)), status, replaces_local_edit: before !== null && before !== text && !before.includes('generated by scripts/build-harness.mjs') });
  }
  return { ok: true, written: consent, files };
}

// --- starter swap (WP-BOOTSTRAP) ------------------------------------------------------------
// A starter clone ships the framework guide as the root README.md and the starter's own MIT notice
// as the root LICENSE. The swap moves both under .claude/ and seeds a project README in their place,
// as ONE journaled transaction: the journal is written before the first rename and deleted only at
// the composite final state, so an interrupted run reconciles instead of guessing. The root LICENSE
// is never generated — a project picks its own license.
export const STARTER_README_MARKER = '<!-- STARTER-KIT-README';
export const STARTER_LICENSE_HOLDER = 'Marek Mróz';
export const SWAP_JOURNAL = path.posix.join(STATE_DIR, 'swap.json');
const SWAP_JOURNAL_TMP = `${SWAP_JOURNAL}.tmp`;
const SWAP_PATHS = { readme_from: 'README.md', readme_to: '.claude/README.md', license_from: 'LICENSE', license_to: '.claude/STARTER-LICENSE' };
const SEED_DESCRIPTION = '<!-- fill: one paragraph on what this project is -->';
// The reported action per LICENSE step; `move` becomes `moved` once the rename ran.
const LICENSE_ACTION = { move: 'move', kept: 'kept (project-owned LICENSE)', skipped: 'skipped (no starter LICENSE)' };

// Ownership is decided on the LICENSE's own bytes, never on the README marker: a project that
// replaced the notice but kept the guide must not have its license moved away.
export function classifyLicense(bytes) {
  const text = Buffer.isBuffer(bytes) ? bytes.toString('utf8') : String(bytes);
  const holder = STARTER_LICENSE_HOLDER.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  return /MIT License/.test(text) && new RegExp(`Copyright \\(c\\) \\d{4} ${holder}`).test(text) ? 'starter-owned' : 'project-owned';
}

function readOrNull(abs) {
  try {
    return fs.readFileSync(abs);
  } catch (err) {
    if (err.code === 'ENOENT') return null;
    throw err;
  }
}

function hashOf(abs) {
  const bytes = readOrNull(abs);
  return bytes === null ? null : sha256Hex(bytes);
}

// assertInside resolves an absent target lexically, so containment alone would let a symlinked
// ancestor carry a rename out of the project. Walk the existing components instead: no symlink on
// the way down, every existing ancestor a real directory (a plain file named `.claude` would fail
// the mkdir after the journal was written), and the deepest existing one really inside the root.
function guardPath(projectRoot, rel) {
  const rootReal = realpathOrSelf(projectRoot);
  const parts = rel.split('/');
  let cur = projectRoot;
  let deepest = projectRoot;
  for (let i = 0; i < parts.length; i++) {
    cur = path.join(cur, parts[i]);
    let st;
    try { st = fs.lstatSync(cur); } catch { break; }
    const shown = toPosix(path.relative(projectRoot, cur));
    if (st.isSymbolicLink()) return `${shown} is a symlink`;
    if (i < parts.length - 1 && !st.isDirectory()) return `${shown} is not a directory`;
    deepest = cur;
  }
  return isInside(rootReal, deepest) ? null : `${rel} escapes the project root`;
}

// `--name`, else the origin remote's repository name, else the directory name (setup-start passes
// the interview answer; a clone made straight from the starter remote would otherwise inherit its name).
function projectName(projectRoot, name) {
  if (typeof name === 'string' && name.length) return name;
  try {
    const url = execFileSync('git', ['remote', 'get-url', 'origin'], { cwd: projectRoot, stdio: ['ignore', 'pipe', 'ignore'] }).toString().trim();
    const base = url.replace(/\.git$/, '').split(/[/:]/).filter(Boolean).pop();
    if (base) return base;
  } catch { /* no repo, no remote — fall through to the directory name */ }
  return path.basename(path.resolve(projectRoot));
}

function seedBytes(name, description) {
  const template = fs.readFileSync(path.join(templatesDir(), 'README.md'), 'utf8');
  return Buffer.from(template.split('{project-name}').join(name).split('{description}').join(description), 'utf8');
}

// The binding creates the state directory; the swap only journals into it. Absent and read-only are
// different problems with different fixes, so the reason names which one it is.
function stateDirBlocker(root) {
  const stateDir = path.join(root, STATE_DIR);
  if (!fs.existsSync(stateDir)) return `${STATE_DIR} is absent — bind the plugin first (setup-start 3)`;
  try {
    fs.accessSync(stateDir, fs.constants.W_OK);
    return null;
  } catch {
    return `${STATE_DIR} not writable — see setup-start 3c`;
  }
}

function readmeReport(move, create) {
  return { from: SWAP_PATHS.readme_from, to: SWAP_PATHS.readme_to, move, create };
}

function licenseReport(action, ownership) {
  return { from: SWAP_PATHS.license_from, to: SWAP_PATHS.license_to, ownership: ownership ?? null, action };
}

function stopped(verdict, reason, license = licenseReport(verdict, null)) {
  return { verdict, reason, readme: readmeReport(verdict, verdict), license, seed: null, pre: null };
}

const SHA256_HEX = /^[0-9a-f]{64}$/;

// The journal is trusted only after it proves itself: the transaction reads its paths and writes its
// seed bytes, so a journal edited or corrupted in place must be refused before anything moves —
// the fixed swap paths, well-formed hashes, a known license step, and seed bytes that hash to the
// recorded digest.
function journalIsSound(plan) {
  if (!plan || typeof plan !== 'object' || !plan.paths || !plan.pre || typeof plan.seed_bytes_base64 !== 'string') return false;
  const pathsMatch = Object.keys(SWAP_PATHS).every((k) => plan.paths[k] === SWAP_PATHS[k]) && Object.keys(plan.paths).length === Object.keys(SWAP_PATHS).length;
  if (!pathsMatch) return false;
  if (!SHA256_HEX.test(plan.pre.readme_sha256 ?? '')) return false;
  if (plan.pre.license_sha256 !== null && !SHA256_HEX.test(plan.pre.license_sha256 ?? '')) return false;
  if (!(plan.license in LICENSE_ACTION)) return false;
  if (!SHA256_HEX.test(plan.seed_sha256 ?? '')) return false;
  return sha256Hex(Buffer.from(plan.seed_bytes_base64, 'base64')) === plan.seed_sha256;
}

// A journal that cannot be trusted (killed mid-write, edited) is refused with the files named, never
// crashed on: the preview must still produce a verdict so setup-start can print it.
function resumePreflight(root, journalPath) {
  let journal = null;
  try { journal = readJson(journalPath); } catch { /* unreadable — handled below */ }
  const plan = journal?.plan;
  if (!journalIsSound(plan)) {
    return { ...stopped('refused', `${SWAP_JOURNAL} is unreadable, incomplete or altered — check ${Object.values(SWAP_PATHS).join(', ')} by hand, then delete the journal and re-run`), journal: SWAP_JOURNAL };
  }
  const blocker = stateDirBlocker(root);
  if (blocker) return { ...stopped('blocked', blocker), journal: SWAP_JOURNAL };
  const r = readmeState(root, plan);
  const l = licenseState(root, plan);
  if (r.state === null || l.state === null) {
    return { ...stopped('refused', mismatch(r.reason ?? l.reason), licenseReport('refused', plan.ownership)), pre: plan.pre, journal: SWAP_JOURNAL };
  }
  const remaining = [...(r.state === 'R0' ? ['readme-move'] : []), ...(r.state !== 'R2' ? ['readme-create'] : []), ...(l.state === 'L0' ? ['license-move'] : [])];
  return {
    verdict: 'resume',
    reason: `${SWAP_JOURNAL} from ${journal.started ?? 'unknown time'}: ${remaining.length ? `${remaining.join(', ')} still to run` : 'every step ran; the final check is pending'}`,
    journal: SWAP_JOURNAL,
    plan,
    state: { readme: r.state, license: l.state },
    remaining,
    readme: readmeReport(r.state === 'R0' ? 'move' : 'moved', r.state === 'R2' ? 'created' : 'create'),
    license: licenseReport(l.state === 'L0' ? 'move' : l.state === 'L1' ? 'moved' : LICENSE_ACTION[plan.license], plan.ownership),
    seed: { sha256: plan.seed_sha256 },
    pre: plan.pre,
  };
}

function mismatch(reason) {
  return `${reason} — restore the journaled bytes, or finish the move by hand and delete ${SWAP_JOURNAL}`;
}

// Classify the whole swap before anything moves. No mutation, no journal write.
export function swapPreflight({ projectRoot, name, description, license }) {
  const root = path.resolve(projectRoot);
  for (const rel of [...Object.values(SWAP_PATHS), SWAP_JOURNAL, SWAP_JOURNAL_TMP]) {
    const reason = guardPath(root, rel);
    if (reason) return stopped('refused', reason);
  }
  const journalPath = path.join(root, SWAP_JOURNAL);
  if (fs.existsSync(journalPath)) return resumePreflight(root, journalPath);

  const readmeBytes = readOrNull(path.join(root, SWAP_PATHS.readme_from));
  const licenseBytes = readOrNull(path.join(root, SWAP_PATHS.license_from));
  const marked = readmeBytes !== null && readmeBytes.subarray(0, STARTER_README_MARKER.length).toString('utf8') === STARTER_README_MARKER;
  if (!marked) {
    // Nothing moves, but the LICENSE line must still tell the truth about whose notice it is.
    const ownership = licenseBytes === null ? null : classifyLicense(licenseBytes);
    const action = licenseBytes === null ? LICENSE_ACTION.skipped
      : ownership === 'starter-owned' ? `kept (starter-owned LICENSE beside a project README — move it to ${SWAP_PATHS.license_to} by hand if the notice is not yours)`
        : LICENSE_ACTION.kept;
    return stopped('kept', readmeBytes === null ? 'no root README.md' : 'root README.md is not the starter guide', licenseReport(action, ownership));
  }
  const guidePresent = fs.existsSync(path.join(root, SWAP_PATHS.readme_to));
  const starterLicensePresent = fs.existsSync(path.join(root, SWAP_PATHS.license_to));
  if (guidePresent || starterLicensePresent) {
    const named = [guidePresent ? SWAP_PATHS.readme_to : null, starterLicensePresent ? SWAP_PATHS.license_to : null].filter(Boolean);
    return stopped('conflict', `${SWAP_PATHS.readme_from} still carries the starter marker but ${named.join(' and ')} already exist(s) — resolve by hand`);
  }
  const blocker = stateDirBlocker(root);
  if (blocker) return stopped('blocked', blocker);

  let ownership = null;
  let licenseStep = 'skipped';
  if (licenseBytes !== null) {
    ownership = license === 'starter' ? 'starter-owned' : classifyLicense(licenseBytes);
    licenseStep = ownership === 'starter-owned' ? 'move' : 'kept';
  }
  const seedName = projectName(root, name);
  const seedDescription = typeof description === 'string' && description.length ? description : SEED_DESCRIPTION;
  const seed = seedBytes(seedName, seedDescription);
  return {
    verdict: 'plan',
    readme: readmeReport('move', 'create'),
    license: { ...licenseReport(LICENSE_ACTION[licenseStep], ownership), step: licenseStep },
    seed: { sha256: sha256Hex(seed), name: seedName, description: seedDescription, bytes: seed },
    pre: { readme_sha256: sha256Hex(readmeBytes), license_sha256: licenseBytes === null ? null : sha256Hex(licenseBytes) },
  };
}

function isTracked(projectRoot, rel) {
  try {
    execFileSync('git', ['ls-files', '--error-unmatch', rel], { cwd: projectRoot, stdio: 'ignore' });
    return true;
  } catch {
    return false;
  }
}

// A tracked file moves through git so the index follows the rename; anything else (no repository,
// an untracked file) is a plain rename. A failing `git mv` on a tracked file is an error, never a
// fallback — renaming behind git's back leaves the guide deleted in the index and untracked on disk.
function moveFile(projectRoot, from, to) {
  fs.mkdirSync(path.dirname(path.join(projectRoot, to)), { recursive: true });
  if (isTracked(projectRoot, from)) {
    try {
      execFileSync('git', ['mv', from, to], { cwd: projectRoot, stdio: ['ignore', 'ignore', 'pipe'] });
    } catch (err) {
      throw new Error(`git mv ${from} ${to} failed: ${(err.stderr?.toString() || err.message).trim()}`);
    }
  } else {
    fs.renameSync(path.join(projectRoot, from), path.join(projectRoot, to));
  }
  return 'moved';
}

// Reconciliation is over whole-transaction states, never per-step postconditions: R0 (guide at the
// root) → R1 (guide moved) → R2 (seed written), and L0 → L1 or L-skip when no LICENSE step was
// approved. Anything else means a file changed under us.
function readmeState(root, plan) {
  const rootHash = hashOf(path.join(root, plan.paths.readme_from));
  const destHash = hashOf(path.join(root, plan.paths.readme_to));
  if (rootHash === plan.pre.readme_sha256 && destHash === null) return { state: 'R0' };
  if (rootHash === null && destHash === plan.pre.readme_sha256) return { state: 'R1' };
  if (rootHash === plan.seed_sha256 && destHash === plan.pre.readme_sha256) return { state: 'R2' };
  if (rootHash !== null && rootHash !== plan.pre.readme_sha256 && rootHash !== plan.seed_sha256) {
    return { state: null, reason: `${plan.paths.readme_from} changed: expected ${plan.pre.readme_sha256} or ${plan.seed_sha256} got ${rootHash}` };
  }
  return { state: null, reason: `${plan.paths.readme_to} changed: expected ${plan.pre.readme_sha256} got ${destHash ?? 'absent'}` };
}

function licenseState(root, plan) {
  if (plan.license !== 'move') return { state: 'L-skip' };
  const rootHash = hashOf(path.join(root, plan.paths.license_from));
  const destHash = hashOf(path.join(root, plan.paths.license_to));
  if (rootHash === plan.pre.license_sha256 && destHash === null) return { state: 'L0' };
  if (rootHash === null && destHash === plan.pre.license_sha256) return { state: 'L1' };
  if (rootHash !== null && rootHash !== plan.pre.license_sha256) {
    return { state: null, reason: `${plan.paths.license_from} changed: expected ${plan.pre.license_sha256} got ${rootHash}` };
  }
  return { state: null, reason: `${plan.paths.license_to} changed: expected ${plan.pre.license_sha256} got ${destHash ?? 'absent'}` };
}

function refused(reason, plan) {
  return { written: false, verdict: 'refused', reason, readme: readmeReport('refused', 'refused'), license: licenseReport('refused', plan?.ownership ?? null), journal: SWAP_JOURNAL };
}

// Preview by default; `consent` runs the transaction. `hooks.afterStep` exists so the tests can kill
// the run at every operation boundary — it is never wired to the CLI.
export function swapStarterFiles({ projectRoot, consent = false, name, description, license, hooks = {} } = {}) {
  const root = path.resolve(projectRoot);
  const afterStep = hooks.afterStep ?? (() => {});
  const pre = swapPreflight({ projectRoot: root, name, description, license });
  if (!consent || (pre.verdict !== 'plan' && pre.verdict !== 'resume')) {
    // The preview never carries bytes: the seed is reported by hash, the journaled plan without its payload.
    const { seed, plan, ...rest } = pre;
    const { seed_bytes_base64: _bytes, ...planShown } = plan ?? {};
    return { written: false, ...rest, ...(plan ? { plan: planShown } : {}), seed: seed && pre.verdict === 'plan' ? { sha256: seed.sha256, name: seed.name, description: seed.description } : seed };
  }

  const journalPath = path.join(root, SWAP_JOURNAL);
  let plan;
  if (pre.verdict === 'resume') {
    plan = pre.plan;
  } else {
    plan = {
      paths: { ...SWAP_PATHS },
      pre: pre.pre,
      seed_sha256: pre.seed.sha256,
      seed_bytes_base64: pre.seed.bytes.toString('base64'),
      license: pre.license.step,
      ownership: pre.license.ownership,
    };
    // Journal FIRST, and whole: an interrupted run is only recoverable when the complete plan outlived
    // the first rename, and a half-written journal must never be mistaken for one.
    // `wx` creates the file or fails: a stale or planted temporary path is never followed or truncated.
    const tmpPath = path.join(root, SWAP_JOURNAL_TMP);
    try {
      fs.writeFileSync(tmpPath, `${JSON.stringify({ started: new Date().toISOString(), plan }, null, 2)}\n`, { flag: 'wx' });
    } catch (err) {
      return refused(`${SWAP_JOURNAL_TMP} could not be created (${err.code ?? err.message}) — remove it by hand and re-run`, plan);
    }
    fs.renameSync(tmpPath, journalPath);
  }

  let r = readmeState(root, plan);
  if (r.state === null) return refused(mismatch(r.reason), plan);
  let l = licenseState(root, plan);
  if (l.state === null) return refused(mismatch(l.reason), plan);

  // Steps already done by an earlier run are reported as done, not as `kept`.
  const report = {
    readme: readmeReport(r.state === 'R0' ? 'kept' : 'moved', r.state === 'R2' ? 'created' : 'kept'),
    license: licenseReport(l.state === 'L1' ? 'moved' : LICENSE_ACTION[plan.license], plan.ownership),
  };
  if (r.state === 'R0') {
    try {
      report.readme.move = moveFile(root, plan.paths.readme_from, plan.paths.readme_to);
    } catch (err) {
      return refused(`${err.message} — nothing moved; fix the repository state and re-run`, plan);
    }
    afterStep('readme-move');
    r = { state: 'R1' };
  }
  if (r.state === 'R1') {
    writeBytes(path.join(root, plan.paths.readme_from), Buffer.from(plan.seed_bytes_base64, 'base64'));
    report.readme.create = 'created';
    afterStep('readme-create');
    r = { state: 'R2' };
  }
  if (l.state === 'L0') {
    try {
      report.license.action = moveFile(root, plan.paths.license_from, plan.paths.license_to);
    } catch (err) {
      return refused(`${err.message} — the README half is done; fix the repository state and re-run to finish`, plan);
    }
    afterStep('license-move');
    l = { state: 'L1' };
  }

  const finalReadme = readmeState(root, plan);
  const finalLicense = licenseState(root, plan);
  if (finalReadme.state !== 'R2') return refused(mismatch(finalReadme.reason ?? `${plan.paths.readme_from} did not reach the final state`), plan);
  if (!['L1', 'L-skip'].includes(finalLicense.state)) return refused(mismatch(finalLicense.reason ?? `${plan.paths.license_from} did not reach the final state`), plan);
  fs.unlinkSync(journalPath);

  return { written: true, verdict: pre.verdict === 'resume' ? 'resumed' : 'swapped', ...report, seed: { sha256: plan.seed_sha256 }, pre: plan.pre, journal: null };
}

function main() {
  const { opts, positionals } = parseArgv(process.argv.slice(2));
  const cmd = positionals[0];
  const projectRoot = requireOpt(opts, 'project-root');
  if (cmd === 'seed') {
    const res = seedMemory({ projectRoot, consent: opts.consent === 'yes' });
    console.log(JSON.stringify(res, null, 2));
    if (opts.consent !== 'yes') console.error('preview only — re-run with --consent yes after the user approved the summary');
    return;
  }
  if (cmd === 'report') {
    const res = readiness({ projectRoot, host: opts.host ?? null, pluginRoot: opts['plugin-root'] ?? null });
    console.log(JSON.stringify(res, null, 2));
    process.exit(res.ready ? 0 : 3);
  }
  if (cmd === 'wrappers') {
    const res = syncWrappers({ projectRoot, pluginRoot: requireOpt(opts, 'plugin-root'), consent: opts.consent === 'yes' });
    console.log(JSON.stringify(res, null, 2));
    if (opts.consent !== 'yes') console.error('preview only (written: false) — a file marked replaces_local_edit holds project edits; re-run with --consent yes after the user approved the list');
    return;
  }
  if (cmd === 'swap') {
    const str = (key) => (opts[key] === true ? undefined : opts[key]);
    const res = swapStarterFiles({ projectRoot, consent: opts.consent === 'yes', name: str('name'), description: str('description'), license: str('license') });
    console.log(JSON.stringify(res, null, 2));
    if (opts.consent !== 'yes') console.error('preview only (written: false) — re-run with --consent yes after the user approved the preflight verdict');
    return;
  }
  throw new Error(`unknown command ${cmd}; use seed | report | wrappers | swap`);
}

if (process.argv[1] && fileURLToPath(import.meta.url) === realpathOrSelf(process.argv[1])) {
  try {
    main();
  } catch (err) {
    console.error(`bootstrap: ${err.message}`);
    process.exit(1);
  }
}
