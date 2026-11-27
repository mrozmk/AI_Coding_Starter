// The inventory of an existing app: the committed route list (`.agents/regression/routes.json`),
// a per-machine staging directory for one inventory step, and `apply` — the only writer of the
// catalog for an inventory. Apply binds the reviewed proposal (its digest), the walk (COMPLETE, run
// on exactly the staged routes) and the observed outcome of every route to each scenario it maps,
// only appends blocks (never rewrites one), merges the route list, and does all of it under the
// checkout lock a run takes. `split` proposes one to three baseline Tasks by area. Nothing commits.
// Node builtins only — ships to every downstream. Contract: .agents/reference/regression.md §14.
//
//   node .claude/lib/regression/inventory.mjs stage [--root <dir>]
//   node .claude/lib/regression/inventory.mjs check-staged --routes <file> [--root <dir>]
//   node .claude/lib/regression/inventory.mjs check [--root <dir>]
//   node .claude/lib/regression/inventory.mjs apply --stage <dir> --walk <run dir> (--dry-run | --expect-proposal <digest>) [--root <dir>]
//   node .claude/lib/regression/inventory.mjs split [--root <dir>]
//     exit 0 ok · 1 refused / gaps · 2 usage / config

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { validateRouteList, betterOutcome } from './walk.mjs';
import { loadConfig, isObject } from './config.mjs';
import { loadCatalog, parseCatalog, validateCatalog, blockTexts, specOf, awaitsSpec, areaOf, isLiveBlocked, sourceTokens, statusOf, posix } from './catalog.mjs';
import { sha256 } from './policy.mjs';
import { withCheckoutLock, newRunDir } from './run.mjs';
import { writeAtomic } from '../backlog-check.mjs';

export const ROUTES_PATH = '.agents/regression/routes.json';

class Refusal extends Error {}
class UsageError extends Error {}
const refuse = (msg) => { throw new Refusal(msg); };

const readJsonFile = (file, what) => {
  let text;
  try { text = fs.readFileSync(file, 'utf8'); } catch { refuse(`${what} absent — ${file}`); }
  try { return JSON.parse(text); } catch (err) { return refuse(`${what} is not valid JSON (${err.message})`); }
};

/** The digest a critic round reviewed: sha256 over proposal.md bytes, NUL, proposal.json bytes. */
export function proposalDigest(stageDir) {
  const md = fs.readFileSync(path.join(stageDir, 'proposal.md'));
  const json = fs.readFileSync(path.join(stageDir, 'proposal.json'));
  return sha256(Buffer.concat([md, Buffer.from('\0'), json]));
}

function loadAdopted(root) {
  const loaded = loadConfig(root);
  if (!loaded.adopted) throw new UsageError('regression not adopted');
  if (loaded.errors.length) throw new UsageError(loaded.errors.map((e) => `.claude/regression.json: ${e}`).join('\n'));
  return loaded.config;
}

const usesWord = (b, word) => sourceTokens(b.fields.Source?.value ?? '').some((t) => t.kind === 'word' && t.id === word);

// ---------------------------------------------------------------------------------------------
// stage · check-staged · check

function cmdStage(root) {
  const { dir } = newRunDir(root, 'inventory');
  console.log(`stage: ${posix(path.relative(root, dir))}`);
  return 0;
}

function cmdCheckStaged(root, file) {
  const doc = readJsonFile(path.resolve(root, file), 'staged route list');
  const errors = validateRouteList(doc, { staged: true });
  for (const e of errors) console.log(e);
  if (!errors.length) console.log(`staged routes ok — ${doc.routes.length} routes`);
  return errors.length ? 1 : 0;
}

function cmdCheck(root) {
  const cfg = loadAdopted(root);
  const file = path.resolve(root, ROUTES_PATH);
  if (!fs.existsSync(file)) { console.log('no route list'); return 1; }
  const doc = readJsonFile(file, ROUTES_PATH);
  const gaps = validateRouteList(doc);
  const { blocks } = loadCatalog(root, cfg);
  const byId = new Map(blocks.map((b) => [b.id, b]));
  for (const e of Array.isArray(doc.routes) ? doc.routes : []) {
    if (!isObject(e)) continue;
    const ids = Array.isArray(e.scenarios) ? e.scenarios : [];
    if (!ids.length && !(typeof e.exclusion === 'string' && e.exclusion.trim())) gaps.push(`route ${e.route}: no scenario and no exclusion`);
    for (const id of ids) {
      const b = byId.get(id);
      if (!b) gaps.push(`route ${e.route}: unknown scenario ${id}`);
      else if (statusOf(b)[1] === 'DROPPED') gaps.push(`route ${e.route}: scenario ${id} is DROPPED`);
    }
  }
  for (const g of gaps) console.log(g);
  if (!gaps.length) console.log(`routes ok — ${doc.routes.length} routes, each with a scenario or an exclusion`);
  return gaps.length ? 1 : 0;
}

// ---------------------------------------------------------------------------------------------
// apply

/** Parse `text` as catalog blocks through a temp file in `dir` (parseCatalog reads files). */
function parseText(dir, text) {
  const tmp = path.join(dir, `proposal-parse.md.tmp-${process.pid}`);
  fs.writeFileSync(tmp, text);
  try {
    return { blocks: parseCatalog(dir, [tmp]), texts: blockTexts(dir, [tmp]) };
  } finally { fs.rmSync(tmp, { force: true }); }
}

/** The whole apply; throws Refusal. Returns the lines to print. */
function applyInventory(root, { stage, walk, dryRun, expect }) {
  const cfg = loadAdopted(root);
  const stageDir = path.resolve(root, stage);
  const walkDir = path.resolve(root, walk);

  // Inputs, and the reviewed digest before anything else.
  const stagedFile = path.join(stageDir, 'routes.staged.json');
  const stagedBytes = (() => { try { return fs.readFileSync(stagedFile); } catch { return refuse(`staged route list absent — ${posix(path.relative(root, stagedFile))}`); } })();
  if (!fs.existsSync(path.join(stageDir, 'proposal.md')) || !fs.existsSync(path.join(stageDir, 'proposal.json'))) refuse('proposal.md or proposal.json absent in the stage');
  const digest = proposalDigest(stageDir);
  if (!dryRun && digest !== expect) refuse('proposal changed since its review — run --dry-run and a critic round on the new proposal');
  let staged;
  try { staged = JSON.parse(stagedBytes.toString('utf8')); } catch (err) { refuse(`staged route list is not valid JSON (${err.message})`); }
  const stagedErrors = validateRouteList(staged, { staged: true });
  if (stagedErrors.length) refuse(`staged route list invalid — ${stagedErrors.join('; ')}`);
  const proposal = readJsonFile(path.join(stageDir, 'proposal.json'), 'proposal.json');
  if (!isObject(proposal) || !isObject(proposal.routes) || !isObject(proposal.sources ?? {})) refuse('proposal.json must hold {routes: {…}, sources: {…}}');
  const sources = proposal.sources ?? {};
  const proposalMd = fs.readFileSync(path.join(stageDir, 'proposal.md'), 'utf8').replace(/\r/g, '');
  const record = readJsonFile(path.join(walkDir, 'walk.json'), 'walk.json');
  const observations = readJsonFile(path.join(walkDir, 'walk/observations.json'), 'walk/observations.json');
  if (!Array.isArray(observations)) refuse('walk/observations.json must be an array');
  const routesFile = path.resolve(root, ROUTES_PATH);
  const committed = fs.existsSync(routesFile) ? readJsonFile(routesFile, ROUTES_PATH) : { schema: 1, routes: [] };
  const committedErrors = validateRouteList(committed);
  if (committedErrors.length) refuse(`${ROUTES_PATH} invalid — ${committedErrors.join('; ')}`);

  // Bind the walk.
  if (record.verdict !== 'COMPLETE') refuse(`walk ${record.run_id ?? '?'} is not COMPLETE (${record.verdict ?? 'no verdict'})`);
  if (record.routes_digest !== sha256(stagedBytes)) refuse(`walk ${record.run_id ?? '?'} was run on other staged routes`);
  for (const g of record.groups ?? []) {
    for (const r of g.routes ?? []) {
      const n = observations.filter((o) => o.group === g.key && o.route === r).length;
      if (n !== 1) refuse(`route ${r} missing from group ${g.key}`);
    }
  }

  // Best outcome per staged route over the groups.
  const best = new Map();
  for (const r of staged.routes) {
    let top = null;
    for (const o of observations.filter((x) => x.route === r.route)) {
      if (!top || betterOutcome(top.outcome, o.outcome) !== top.outcome) top = o;
    }
    best.set(r.route, top ?? { route: r.route, outcome: 'not-walked', submits: [] });
  }

  // The current catalog and the proposal's blocks.
  const { settings, files, blocks: current } = loadCatalog(root, cfg);
  const currentTexts = blockTexts(root, files);
  const byId = new Map(current.map((b) => [b.id, b]));
  const parsed = parseText(stageDir, proposalMd);
  const proposed = parsed.blocks;
  const newBlocks = [];
  const skipped = [];
  const lines = [];
  // New blocks: area, Spec, and the never-rewrite rule.
  for (const b of proposed) {
    const area = areaOf(b.id);
    const old = byId.get(b.id);
    const text = parsed.texts.get(b.id)?.text;
    if (old) {
      if (currentTexts.get(b.id)?.text === text) { skipped.push(b.id); continue; }
      if (statusOf(old)[1] === 'DROPPED') refuse(`reuses DROPPED id ${b.id}`);
      refuse(`rewrites existing block ${b.id}`);
    }
    if (!Object.keys(settings.areas).includes(area)) refuse(`unknown area code ${area} in ${b.id} — configured: ${Object.keys(settings.areas).join(', ')}`);
    if (specOf(b) !== null) refuse(`new block ${b.id} has a Spec — every inventoried block starts with Spec: —`);
    newBlocks.push({ block: b, text });
  }
  const newIds = new Set(newBlocks.map((n) => n.block.id));
  const merged = new Map([...byId, ...newBlocks.map((n) => [n.block.id, n.block])]);

  // The final mapping, in memory.
  const committedBy = new Map(committed.routes.map((e) => [e.route, e]));
  const finalMap = new Map();
  const reached = new Set();
  for (const r of staged.routes) {
    const old = committedBy.get(r.route);
    const prop = isObject(proposal.routes[r.route]) ? proposal.routes[r.route] : {};
    const retained = Array.isArray(old?.scenarios) ? old.scenarios : [];
    const added = Array.isArray(prop.scenarios) ? prop.scenarios : [];
    const ids = [...new Set([...retained, ...added])];
    const exclusion = (typeof prop.exclusion === 'string' && prop.exclusion.trim()) ? prop.exclusion : old?.exclusion ?? null;
    if (!ids.length && !exclusion) refuse(`route ${r.route}: no scenario and no exclusion`);
    for (const id of ids) {
      const b = merged.get(id);
      if (!b) refuse(`route ${r.route}: unknown scenario ${id}`);
      if (statusOf(b)[1] === 'DROPPED') refuse(`route ${r.route}: scenario ${id} is DROPPED`);
      reached.add(id);
    }
    finalMap.set(r.route, { ids, retained: new Set(retained), added, exclusion });
  }
  for (const id of newIds) if (!reached.has(id)) refuse(`unattached block ${id}`);

  // Every id of the final mapping against the route's observed outcome.
  for (const r of staged.routes) {
    const obs = best.get(r.route);
    const { ids, retained } = finalMap.get(r.route);
    for (const id of ids) {
      const b = merged.get(id);
      const src = sources[id] ?? null;
      const submit = newIds.has(id) && src?.submit ? (obs.submits ?? []).find((s) => s.form === src.submit) : null;
      const outcome = newIds.has(id) && src?.submit ? (submit?.outcome === 'failed' ? 'failed' : submit?.outcome === 'submitted' ? 'ok' : 'skipped') : obs.outcome;
      const live = usesWord(b, 'live');
      const problem = (() => {
        if (outcome === 'failed') return isLiveBlocked(b) && live ? null : 'must be BLOCKED (live: …) citing live';
        // A new block on a path the walk saw work cites what shows it: live or code. An existing
        // catalog id stays accepted whatever its Source (gaps mode maps a route to the scenario
        // that already covers it).
        if (outcome === 'ok') return !newIds.has(id) || live || usesWord(b, 'code') ? null : 'must cite live or code — a new block on a route the walk saw work';
        // Anything but ok admits code only: no live, and code cited.
        if (live) return 'cites live, but the walk did not see the path work';
        return usesWord(b, 'code') ? null : 'must cite code — the walk did not see the path work';
      })();
      if (problem) {
        if (retained.has(id) || !newIds.has(id)) {
          if (retained.has(id)) refuse(`route ${r.route}: retained ${id} conflicts with the walk (${outcome}) — ${problem}; apply cannot rewrite the block — fix it by hand, or remove ${id} from this route in ${ROUTES_PATH}`);
          refuse(`route ${r.route}: existing ${id} conflicts with the walk (${outcome}) — ${problem}`);
        }
        refuse(`route ${r.route}: ${id} ${problem} (walk: ${outcome}${src?.submit ? `, submit ${src.submit}` : ''})`);
      }
      if (newIds.has(id) && usesWord(b, 'code') && !(Array.isArray(src?.code) && src.code.length)) refuse(`${id} cites code but sources.${id}.code is empty`);
    }
  }

  // Build the target files' new text and validate the merged catalog.
  const targets = new Map(); // rel path → text
  for (const { block, text } of newBlocks) {
    const area = areaOf(block.id);
    const holder = files.find((f) => current.some((c) => c.file === f && areaOf(c.id) === area));
    const rel = holder ?? posix(path.join(settings.path, `${area.toLowerCase()}.md`));
    if (!targets.has(rel)) {
      const abs = path.resolve(root, rel);
      targets.set(rel, fs.existsSync(abs) ? fs.readFileSync(abs, 'utf8').replace(/\r/g, '').replace(/\n+$/, '') : `# ${settings.areas[area]}`);
    }
    targets.set(rel, `${targets.get(rel)}\n\n${text}`);
  }
  const tempDir = dryRun ? stageDir : path.resolve(root, settings.path);
  if (!dryRun && targets.size) fs.mkdirSync(tempDir, { recursive: true });
  const temps = new Map(); // rel → temp absolute
  try {
    for (const [rel, text] of targets) {
      const tmp = path.join(tempDir, `${path.basename(rel)}.tmp-${process.pid}`);
      fs.writeFileSync(tmp, `${text}\n`);
      temps.set(rel, tmp);
    }
    const all = [...new Set([...files, ...targets.keys()])].sort();
    const mergedBlocks = parseCatalog(root, all.map((f) => temps.get(f) ?? f));
    const back = new Map([...temps].map(([rel, tmp]) => [tmp, rel]));
    const errors = validateCatalog(mergedBlocks, settings);
    if (errors.length) refuse(`the merged catalog is invalid — ${errors.map((e) => `${back.get(e.file) ?? e.file}:${e.line}: ${e.message}`).join('; ')}`);

    // Merge the route list.
    const redacted = new Set(record.redacted_samples ?? []);
    let added = 0;
    let updated = 0;
    const routes = committed.routes.map((e) => {
      const f = finalMap.get(e.route);
      if (!f) return e;
      const gain = f.ids.filter((id) => !(e.scenarios ?? []).includes(id));
      if (!gain.length) return e;
      updated += 1;
      return { ...e, scenarios: [...(e.scenarios ?? []), ...gain] };
    });
    for (const r of staged.routes) {
      if (committedBy.has(r.route)) continue;
      const f = finalMap.get(r.route);
      const entry = { route: r.route, source: r.source };
      if (typeof r.sample === 'string' && !redacted.has(r.route) && !r.sample.includes('?')) entry.sample = r.sample;
      for (const k of ['match', 'account', 'submit']) if (r[k] !== undefined) entry[k] = r[k];
      if (f.ids.length) entry.scenarios = f.ids;
      if (f.exclusion) entry.exclusion = f.exclusion;
      routes.push(entry);
      added += 1;
    }
    const routesText = `${JSON.stringify({ schema: 1, routes }, null, 2)}\n`;

    // Publish.
    for (const { block } of newBlocks) lines.push(`${dryRun ? 'would apply' : 'applied'}: ${block.id}`);
    for (const id of skipped) lines.push(`skipped: ${id} (already applied)`);
    lines.push(`routes: ${added} added, ${updated} updated`);
    if (dryRun) { lines.push(`proposal: ${digest}`); return lines; }
    for (const [rel, tmp] of temps) fs.renameSync(tmp, path.resolve(root, rel));
    temps.clear();
    const before = fs.existsSync(routesFile) ? fs.readFileSync(routesFile, 'utf8') : null;
    if (before !== routesText) writeAtomic(routesFile, routesText);
    lines.push(`proposal: ${digest}`);
    return lines;
  } finally {
    for (const tmp of temps.values()) fs.rmSync(tmp, { force: true });
  }
}

function cmdApply(root, args) {
  if (!args.stage || !args.walk) throw new UsageError('apply needs --stage <dir> and --walk <run dir>');
  if (Boolean(args.dryRun) === Boolean(args.expect)) throw new UsageError('apply needs exactly one of --dry-run and --expect-proposal <digest>');
  try {
    const r = withCheckoutLock(root, 'inventory-apply', () => applyInventory(root, args));
    if (r.error) { console.log(`refused: checkout lock held — ${r.error}`); return 1; }
    for (const l of r.value) console.log(l);
    return 0;
  } catch (err) {
    if (!(err instanceof Refusal)) throw err;
    console.log(`refused: ${err.message}`);
    return 1;
  }
}

// ---------------------------------------------------------------------------------------------
// split

/** `{parts: [{codes, n}]}` — READY scenarios without a spec, areas whole, largest first. */
export function splitBaseline(blocks) {
  const perArea = new Map();
  for (const b of blocks) {
    if (!awaitsSpec(b)) continue;
    const area = areaOf(b.id);
    perArea.set(area, (perArea.get(area) ?? 0) + 1);
  }
  const total = [...perArea.values()].reduce((s, n) => s + n, 0);
  if (!total) return { total, parts: [] };
  const k = Math.min(3, Math.ceil(total / 30), perArea.size);
  const parts = Array.from({ length: k }, () => ({ codes: [], n: 0 }));
  for (const [area, n] of [...perArea].sort((a, b) => b[1] - a[1] || (a[0] < b[0] ? -1 : 1))) {
    const target = parts.reduce((lo, p) => (p.n < lo.n ? p : lo), parts[0]);
    target.codes.push(area);
    target.n += n;
  }
  return { total, parts: parts.filter((p) => p.n) };
}

function cmdSplit(root) {
  const cfg = loadAdopted(root);
  const { blocks } = loadCatalog(root, cfg);
  const { parts } = splitBaseline(blocks);
  if (!parts.length) { console.log('no baseline work — every READY scenario has a spec'); return 0; }
  parts.forEach((p, i) => {
    console.log(`part ${i + 1}: ${p.codes.join(',')} (${p.n} scenarios) — /regression-tests author --area ${p.codes.join(',')}`);
    console.log(`title: [regression:baseline] Write the regression baseline — part ${i + 1}`);
  });
  return 0;
}

// ---------------------------------------------------------------------------------------------
// CLI

const USAGE = [
  'usage: node .claude/lib/regression/inventory.mjs stage [--root <dir>]',
  '       node .claude/lib/regression/inventory.mjs check-staged --routes <file> [--root <dir>]',
  '       node .claude/lib/regression/inventory.mjs check [--root <dir>]',
  '       node .claude/lib/regression/inventory.mjs apply --stage <dir> --walk <run dir> (--dry-run | --expect-proposal <digest>) [--root <dir>]',
  '       node .claude/lib/regression/inventory.mjs split [--root <dir>]',
].join('\n');
const COMMANDS = ['stage', 'check-staged', 'check', 'apply', 'split'];

function parseArgs(argv) {
  const [cmd, ...rest] = argv;
  if (!COMMANDS.includes(cmd)) throw new UsageError(cmd ? `unknown command ${cmd}` : 'a command is required');
  const args = { cmd, root: process.cwd() };
  const flags = { '--root': 'root', '--routes': 'routes', '--stage': 'stage', '--walk': 'walk', '--expect-proposal': 'expect' };
  for (let i = 0; i < rest.length; i += 1) {
    const a = rest[i];
    if (a === '--dry-run' && cmd === 'apply') args.dryRun = true;
    else if (flags[a]) {
      if (i + 1 >= rest.length) throw new UsageError(`${a} needs a value`);
      args[flags[a]] = rest[++i];
    } else throw new UsageError(`unknown argument ${a}`);
  }
  if (cmd === 'check-staged' && !args.routes) throw new UsageError('check-staged needs --routes <file>');
  return args;
}

export function main(argv = process.argv.slice(2)) {
  let args;
  try { args = parseArgs(argv); } catch (err) {
    if (!(err instanceof UsageError)) throw err;
    console.error(`inventory: ${err.message}\n${USAGE}`);
    return 2;
  }
  const root = path.resolve(args.root);
  try {
    if (args.cmd === 'stage') return cmdStage(root);
    if (args.cmd === 'check-staged') return cmdCheckStaged(root, args.routes);
    if (args.cmd === 'check') return cmdCheck(root);
    if (args.cmd === 'apply') return cmdApply(root, args);
    return cmdSplit(root);
  } catch (err) {
    if (err instanceof UsageError) { console.error(`inventory: ${err.message}`); return 2; }
    if (err instanceof Refusal) { console.log(`refused: ${err.message}`); return 1; }
    throw err;
  }
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    process.exitCode = main();
  } catch (err) {
    console.error(`inventory: ${err.message}`);
    process.exitCode = 2;
  }
}
