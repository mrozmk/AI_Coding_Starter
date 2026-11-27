// The deterministic half of /setup:regression and the only writer of `.claude/regression.json`:
// `catalog` creates the file with its `catalog` section (never overwrites), `baseline` adds each of
// `runner` / `environments` that is absent (never alters an existing key), `visual` adds the `visual`
// section the same way (baseline established first), `check` lists what the foundation still lacks
// (static: never runs an adapter command, never reaches the network), `env` prints an environment's
// resolved base URL. Node builtins only. Contract: .agents/reference/regression.md.
//
//   node .claude/lib/regression/setup.mjs catalog  [--root <dir>] --areas CODE=Name,… [--path <dir>] [--smoke P0,…]
//   node .claude/lib/regression/setup.mjs baseline [--root <dir>] --fragment <json file>   ({runner?, environments?}; a relative path resolves against --root)
//   node .claude/lib/regression/setup.mjs visual   [--root <dir>] --fragment <json file>   ({visual})
//   node .claude/lib/regression/setup.mjs check    [--root <dir>]
//   node .claude/lib/regression/setup.mjs env <name> [--root <dir>]
//   exit 0 = ok / nothing missing · 1 = something missing / refused write · 2 = usage / invalid config

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { writeAtomic } from '../backlog-check.mjs';
import {
  CONFIG_PATH, DEFAULTS, TEST_DATA_COMMANDS, isObject, docKey, loadConfig, validateConfig, catalogSettings, resolveEnvBaseUrl, visualSettings,
} from './config.mjs';
import { catalogFiles, parseCatalog, validateCatalog } from './catalog.mjs';
import { scanIntegration } from './run.mjs';

const BASELINE_SECTIONS = ['runner', 'environments'];
const INTERPRETERS = new Set(['node', 'bash', 'sh', 'python3', 'npx']);
const MCP_PIN = /^@playwright\/mcp@\d+\.\d+\.\d+$/;
const serialize = (cfg) => `${JSON.stringify(cfg, null, 2)}\n`;

class UsageError extends Error {}
const USAGE = `usage: node .claude/lib/regression/setup.mjs catalog --areas CODE=Name,… [--path <dir>] [--smoke P0,…] [--root <dir>]
       node .claude/lib/regression/setup.mjs baseline --fragment <json file, relative to --root> [--root <dir>]
       node .claude/lib/regression/setup.mjs visual --fragment <json file, relative to --root> [--root <dir>]
       node .claude/lib/regression/setup.mjs check [--root <dir>]
       node .claude/lib/regression/setup.mjs env <name> [--root <dir>]`;

function parseArgs(argv) {
  const [cmd, ...rest] = argv;
  if (!Object.hasOwn(COMMANDS, cmd ?? '')) throw new UsageError(cmd ? `unknown subcommand ${cmd}` : 'missing subcommand');
  const args = { cmd, root: process.cwd(), positional: [] };
  for (let i = 0; i < rest.length; i += 1) {
    const a = rest[i];
    if (['--root', '--areas', '--path', '--smoke', '--fragment'].includes(a)) {
      if (i + 1 >= rest.length) throw new UsageError(`${a} needs a value`);
      args[a.slice(2)] = rest[++i];
    } else if (a.startsWith('--')) throw new UsageError(`unknown argument ${a}`);
    else args.positional.push(a);
  }
  if (cmd === 'env' && args.positional.length !== 1) throw new UsageError('env takes exactly one environment name');
  if (cmd !== 'env' && args.positional.length) throw new UsageError(`unexpected argument ${args.positional[0]}`);
  if (cmd === 'catalog' && !args.areas) throw new UsageError('catalog needs --areas CODE=Name,…');
  if ((cmd === 'baseline' || cmd === 'visual') && !args.fragment) throw new UsageError(`${cmd} needs --fragment <json file>`);
  return args;
}

function parseAreas(spec) {
  const areas = {};
  for (const pair of spec.split(',').map((s) => s.trim()).filter(Boolean)) {
    const eq = pair.indexOf('=');
    if (eq < 1) throw new UsageError(`--areas entry ${pair} is not CODE=Name`);
    areas[pair.slice(0, eq).trim()] = pair.slice(eq + 1).trim();
  }
  return areas;
}

function cmdCatalog(root, args) {
  const file = path.resolve(root, CONFIG_PATH);
  if (fs.existsSync(file)) { console.log('regression.json exists — unchanged'); return 0; }
  const catalog = {
    path: args.path ?? DEFAULTS.path,
    areas: parseAreas(args.areas),
    id_pattern: DEFAULTS.id_pattern,
    smoke: args.smoke ? args.smoke.split(',').map((s) => s.trim()).filter(Boolean) : DEFAULTS.smoke,
  };
  const cfg = { version: 1, catalog };
  const errors = validateConfig(cfg);
  if (errors.length) { for (const e of errors) console.log(`refused: ${e}`); return 1; }
  writeAtomic(file, serialize(cfg));
  console.log(`wrote ${CONFIG_PATH} (catalog phase) — areas ${Object.keys(catalog.areas).join(', ') || 'none'}`);
  return 0;
}

/** Add each of `sections` absent from the config from the fragment file; never alter an existing key. */
function addSections(root, fragmentPath, sections, existing) {
  let fragment;
  try { fragment = JSON.parse(fs.readFileSync(path.resolve(root, fragmentPath), 'utf8')); } catch (err) {
    console.error(`setup: --fragment ${fragmentPath} unreadable (${err.message})`);
    return 2;
  }
  if (!isObject(fragment)) { console.error('setup: --fragment must hold a JSON object'); return 2; }
  const added = [];
  const missing = [];
  for (const sec of sections) {
    if (sec in existing) console.log(`kept ${sec}${sec in fragment ? ' (fragment section ignored)' : ''}`);
    else if (sec in fragment) added.push(sec);
    else missing.push(sec);
  }
  if (added.length) {
    // New top-level keys only, appended after the existing ones: nothing present is rewritten.
    const candidate = { ...existing };
    for (const sec of added) candidate[sec] = fragment[sec];
    const errors = validateConfig(candidate);
    if (errors.length) { for (const e of errors) console.log(`refused: ${e}`); console.log(`${CONFIG_PATH} untouched`); return 1; }
    writeAtomic(path.resolve(root, CONFIG_PATH), serialize(candidate));
    for (const sec of added) console.log(`added ${sec}`);
  }
  for (const sec of missing) console.log(`still missing: ${sec} — add it to the fragment`);
  if (!added.length && !missing.length) console.log('nothing to add');
  return missing.length ? 1 : 0;
}

function cmdBaseline(root, args) {
  const loaded = loadConfig(root);
  if (!loaded.adopted) { console.log('no regression.json — run the catalog stage first'); return 1; }
  if (loaded.errors.length) { for (const e of loaded.errors) console.error(`setup: ${CONFIG_PATH}: ${e}`); return 2; }
  return addSections(root, args.fragment, BASELINE_SECTIONS, loaded.config);
}

function cmdVisual(root, args) {
  const loaded = loadConfig(root);
  if (!loaded.adopted) { console.log('no regression.json — run the catalog stage first'); return 1; }
  if (loaded.errors.length) { for (const e of loaded.errors) console.error(`setup: ${CONFIG_PATH}: ${e}`); return 2; }
  if (!isObject(loaded.config.runner) || !isObject(loaded.config.environments)) { console.log('baseline not established — run the baseline stage first'); return 1; }
  return addSections(root, args.fragment, ['visual'], loaded.config);
}

const insideRoot = (root, rel) => !path.isAbsolute(rel) && !rel.split('/').includes('..') && fs.existsSync(path.resolve(root, rel));
const isFileIn = (root, rel) => insideRoot(root, rel) && fs.statSync(path.resolve(root, rel)).isFile();
const isExecutable = (root, rel) => {
  try { fs.accessSync(path.resolve(root, rel), fs.constants.X_OK); return true; } catch { return false; }
};
const onPath = (name) => (process.env.PATH ?? '').split(':').filter(Boolean).some((d) => {
  try { return fs.statSync(path.join(d, name)).isFile(); } catch { return false; }
});

/** The gap of one `test_data` command, or null. Static: the command is parsed, never run. */
function programGap(root, key, command) {
  const tokens = command.trim().split(/\s+/);
  const [first] = tokens;
  if (first.includes('/')) {
    // Run directly (execFileSync in the fixtures template): it must be an executable file.
    if (!isFileIn(root, first)) return `test_data.${key}: ${first} not found (repo-relative path expected)`;
    return isExecutable(root, first) ? null : `test_data.${key}: ${first} is not executable — chmod +x it or run it through an interpreter`;
  }
  if (INTERPRETERS.has(first)) {
    const script = first === 'npx' ? tokens.slice(1).find((t) => t.includes('/')) : tokens[1];
    if (!script) return `test_data.${key}: unsupported command form — use <path> or <interpreter> <script>`;
    if (!onPath(first)) return `test_data.${key}: interpreter ${first} not on PATH`;
    return isFileIn(root, script) ? null : `test_data.${key}: ${script} not found (repo-relative path expected)`;
  }
  return `test_data.${key}: unsupported command form — use <path> or <interpreter> <script>`;
}

function mcpGaps(root) {
  const file = path.resolve(root, '.mcp.json');
  if (!fs.existsSync(file)) return ['no .mcp.json playwright server'];
  let mcp;
  try { mcp = JSON.parse(fs.readFileSync(file, 'utf8')); } catch (err) { return [`.mcp.json unparsable (${err.message})`]; }
  const servers = mcp?.mcpServers && typeof mcp.mcpServers === 'object' ? mcp.mcpServers : {};
  const gaps = [];
  let found = 0;
  for (const [name, server] of Object.entries(servers)) {
    const args = Array.isArray(server?.args) ? server.args : [];
    for (const a of args.filter((x) => typeof x === 'string' && x.startsWith('@playwright/mcp'))) {
      found += 1;
      if (!MCP_PIN.test(a)) gaps.push(`mcpServers.${name}: @playwright/mcp not pinned to an exact version (${a})`);
    }
  }
  return found ? gaps : ['no .mcp.json playwright server'];
}

/** What the foundation still lacks, one line per gap, in the checklist order. Empty = complete. */
export function checkFoundation(root) {
  const loaded = loadConfig(root);
  if (!loaded.adopted) return [`${CONFIG_PATH} missing — run /setup:regression`];
  if (loaded.errors.length) return loaded.errors.map((e) => `${CONFIG_PATH}: ${e}`);
  const cfg = loaded.config;
  const gaps = [];
  const settings = catalogSettings(cfg);
  const errors = validateCatalog(parseCatalog(root, catalogFiles(root, settings)), settings);
  if (errors.length) gaps.push(`catalog: ${errors.length} validation error(s) — run node .claude/lib/regression/catalog.mjs`);
  const runner = cfg.runner;
  if (!runner) gaps.push('runner section missing — run the baseline stage');
  else {
    if (!isFileIn(root, runner.config)) gaps.push(`runner.config: ${runner.config} not found`);
    if (!insideRoot(root, runner.spec_dir) || !fs.statSync(path.resolve(root, runner.spec_dir)).isDirectory()) gaps.push(`runner.spec_dir: ${runner.spec_dir} not found`);
  }
  const envNames = Object.keys(cfg.environments ?? {}).filter((k) => !docKey(k));
  if (!envNames.length) gaps.push('no environment in environments');
  for (const name of envNames) {
    const r = resolveEnvBaseUrl(root, cfg, name);
    if (r.error) gaps.push(`environments.${name}: ${r.error}`);
  }
  if (runner) {
    for (const key of TEST_DATA_COMMANDS) {
      const gap = programGap(root, key, runner.test_data[key]);
      if (gap) gaps.push(gap);
    }
  }
  if (isObject(cfg.visual)) gaps.push(...visualGaps(root, cfg));
  gaps.push(...mcpGaps(root));
  return gaps;
}

/** The visual lane's gaps: its config and spec present and guard-integrated, the baselines, the Storybook environments. */
function visualGaps(root, cfg) {
  const s = visualSettings(cfg);
  const gaps = [];
  const present = [['config', s.config], ['spec', s.spec]].filter(([k, f]) => {
    if (isFileIn(root, f)) return true;
    gaps.push(`visual.${k}: ${f} not found`);
    return false;
  });
  if (present.length === 2) {
    const findings = scanIntegration(root, {
      configFile: s.config,
      configNeeds: [{ module: /\.claude\/lib\/regression\/guard\.mjs$/, binding: 'runnerOptions' }, { module: /\.claude\/lib\/regression\/visual-spec\.mjs$/, binding: 'visualOptions' }],
      specs: [s.spec],
    });
    for (const f of findings) gaps.push(`visual: ${f.file}: ${f.reason}`);
  }
  if (!insideRoot(root, s.baselines)) gaps.push(`visual.baselines: ${s.baselines} not found — created by the first visual accept`);
  for (const env of Object.keys(s.storybook)) {
    const r = resolveEnvBaseUrl(root, cfg, env);
    if (r.error) gaps.push(`visual.storybook.${env}: ${r.error}`);
  }
  return gaps;
}

function cmdCheck(root) {
  const gaps = checkFoundation(root);
  if (!gaps.length) { console.log('foundation complete'); return 0; }
  for (const g of gaps) console.log(g);
  return 1;
}

function cmdEnv(root, args) {
  const loaded = loadConfig(root);
  if (!loaded.adopted) { console.log(`${CONFIG_PATH} missing — run /setup:regression`); return 1; }
  if (loaded.errors.length) { for (const e of loaded.errors) console.error(`setup: ${CONFIG_PATH}: ${e}`); return 2; }
  const r = resolveEnvBaseUrl(root, loaded.config, args.positional[0]);
  if (r.error) { console.log(r.error); return 1; }
  console.log(r.url);
  return 0;
}

const COMMANDS = { catalog: cmdCatalog, baseline: cmdBaseline, visual: cmdVisual, check: cmdCheck, env: cmdEnv };

export function main(argv = process.argv.slice(2)) {
  try {
    const args = parseArgs(argv);
    return COMMANDS[args.cmd](path.resolve(args.root), args);
  } catch (err) {
    if (!(err instanceof UsageError)) throw err;
    console.error(`setup: ${err.message}\n${USAGE}`);
    return 2;
  }
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    process.exitCode = main();
  } catch (err) {
    console.error(`setup: ${err.message}`);
    process.exitCode = 2;
  }
}
