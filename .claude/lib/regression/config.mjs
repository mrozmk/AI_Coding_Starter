// Config library of the opt-in regression kit: loads and validates `.claude/regression.json`
// (sections `catalog`, `runner`, `environments`, `visual`) and resolves an environment's base URL
// (`host: "qa-env"` → `.claude/qa-env.json` `base_url`), the environment policy (`envPolicy`:
// kind, writes, workers, means, pacing, guard, consent — defaults safe for production) and the run
// target (`resolveTarget`). Library only — `catalog.mjs`, `setup.mjs`, `policy.mjs` and `run.mjs`
// are its CLIs. Absent file = regression not adopted: every regression step is silent.
// Node builtins only — ships to every downstream. Contract: .agents/reference/regression.md.

import fs from 'node:fs';
import path from 'node:path';
import { isIP } from 'node:net';
import { hostAllowed } from './guard.mjs';

export const CONFIG_PATH = '.claude/regression.json';
export const QA_ENV_PATH = '.claude/qa-env.json';
export const RUNS_DIR = '.agents/regression/runs';
export const DEFAULTS = { path: '.agents/regression/scenarios', id_pattern: '^[A-Z][A-Z0-9]{1,9}-[0-9]{3}$', smoke: ['P0'] };
export const PRIORITIES = ['P0', 'P1', 'P2'];
export const ENV_KINDS = ['test', 'production'];
const AREA_CODE = /^[A-Z][A-Z0-9]{1,9}$/;
const RUNNER_STRINGS = ['config', 'spec_dir', 'report'];
const RUNNER_COMMANDS = ['smoke', 'full'];
export const TEST_DATA_COMMANDS = ['check', 'provision', 'reset', 'session'];

export const isObject = (v) => v !== null && typeof v === 'object' && !Array.isArray(v);
const isFilled = (v) => typeof v === 'string' && v.trim() !== '';
export const docKey = (k) => k.startsWith('_');

/** An http(s) URL with a host, no credentials and no whitespace. */
function isHttpUrl(s) {
  if (typeof s !== 'string' || s === '' || /\s/.test(s)) return false;
  let u;
  try { u = new URL(s); } catch { return false; }
  // The config is committed and `env` prints the URL: credentials in it would leak.
  return (u.protocol === 'http:' || u.protocol === 'https:') && u.hostname !== '' && u.username === '' && u.password === '';
}

/** A base URL both sources must satisfy: an http(s) URL (isHttpUrl) without a trailing `/`. */
export const isBaseUrl = (s) => isHttpUrl(s) && !s.endsWith('/');

/** An environment's kind; absent means production, so nothing destructive runs by omission. */
export const envKind = (entry) => entry?.kind ?? 'production';

export const WRITES = ['refuse', 'declared', 'allowed'];
export const CONSENT_STRATEGIES = ['decline', 'accept', 'none'];
export const NEED_KEY = /^[a-z0-9][a-z0-9:_-]*$/;
const HOSTNAME = /^(\*\.)?([a-z0-9]([a-z0-9-]*[a-z0-9])?)(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)*$/i;
const PACING_KEYS = ['action_delay_ms', 'requests_per_minute'];
const STOP_KEYS = ['statuses', 'watch_4xx', 'challenge', 'error_signals'];

/** A local server: never a regression target (a run targets a deployed environment only). */
export function isLoopbackHost(hostname) {
  if (typeof hostname !== 'string') return false;
  const h = hostname.toLowerCase().replace(/^\[|\]$/g, '').replace(/\.$/, '');
  if (h === 'localhost' || h.endsWith('.localhost')) return true;
  if (h === '::1' || h === '0:0:0:0:0:0:0:1' || h === '0.0.0.0' || h === '::') return true;
  if (isIP(h) === 4) return h.split('.')[0] === '127';
  if (/^::ffff:/i.test(h)) return isLoopbackHost(h.slice(7));
  return false;
}

const urlHost = (s) => { try { return new URL(s).hostname; } catch { return ''; } };
const compiles = (s) => { try { new RegExp(s); return true; } catch { return false; } };
const isRegex = (v) => isFilled(v) && compiles(v);
const nonNeg = (v) => typeof v === 'number' && Number.isFinite(v) && v >= 0;
const positive = (v) => typeof v === 'number' && Number.isFinite(v) && v > 0;

/**
 * The environment's policy with every default filled: production-safe when a key is absent.
 * `guard.hosts` stays `[]` when absent — the caller defaults it to the resolved base URL's host.
 */
export function envPolicy(entry) {
  const e = isObject(entry) ? entry : {};
  const g = isObject(e.guard) ? e.guard : {};
  const stop = isObject(g.stop) ? g.stop : {};
  const pacing = isObject(e.pacing) ? e.pacing : {};
  const consent = isObject(e.consent) ? e.consent : {};
  const header = isObject(g.header) && isFilled(g.header.name) ? { name: g.header.name, value: String(g.header.value ?? '') } : null;
  const operations = isObject(g.operations)
    ? Object.fromEntries(Object.entries(g.operations).filter(([k, v]) => !docKey(k) && isObject(v)).map(([k, v]) => [k, {
      method: String(v.method ?? '').toUpperCase(), url: v.url, ...(v.body !== undefined ? { body: v.body } : {}),
      ...(v.cost !== undefined ? { cost: v.cost } : {}), ...(v.backend_calls !== undefined ? { backend_calls: v.backend_calls } : {}),
    }]))
    : {};
  return {
    kind: envKind(e),
    writes: e.writes ?? 'refuse',
    workers: e.workers ?? 1,
    means: Array.isArray(e.means) ? [...e.means] : [],
    pacing: { action_delay_ms: pacing.action_delay_ms ?? 0, requests_per_minute: pacing.requests_per_minute ?? 0 },
    guard: {
      hosts: Array.isArray(g.hosts) ? [...g.hosts] : [],
      header,
      operations,
      rpc: Array.isArray(g.rpc) ? g.rpc.filter(isObject).map((r) => ({ url: r.url, mutating: r.mutating })) : [],
      budget: g.budget ?? null,
      stop: {
        statuses: Array.isArray(stop.statuses) ? [...stop.statuses] : [403, 429],
        watch_4xx: Array.isArray(stop.watch_4xx) ? [...stop.watch_4xx] : [],
        challenge: Array.isArray(stop.challenge) ? [...stop.challenge] : [],
        error_signals: Array.isArray(stop.error_signals) ? stop.error_signals.filter(isObject).map((s) => ({ url: s.url, body: s.body })) : [],
      },
    },
    consent: {
      strategy: consent.strategy ?? 'decline',
      cookies: Array.isArray(consent.cookies)
        ? consent.cookies.filter(isObject).map((c) => ({ name: c.name, value: c.value, domain: c.domain, path: c.path ?? '/' }))
        : [],
    },
    build_sha_url: isFilled(e.build_sha_url) ? e.build_sha_url : null,
  };
}

/** Problems of one environment entry's policy keys, as `<key path>: <problem>` strings. */
function validateEnvPolicy(name, entry) {
  const errors = [];
  const at = (k) => `environments.${name}.${k}`;
  if ('writes' in entry && !WRITES.includes(entry.writes)) errors.push(`${at('writes')}: must be ${WRITES.join('|')}`);
  if ('workers' in entry && !(Number.isInteger(entry.workers) && entry.workers > 0)) errors.push(`${at('workers')}: must be a positive integer`);
  let means = [];
  if ('means' in entry) {
    if (!Array.isArray(entry.means) || entry.means.some((m) => typeof m !== 'string' || !NEED_KEY.test(m))) {
      errors.push(`${at('means')}: must be an array of keys matching ${NEED_KEY.source}`);
    } else means = entry.means;
  }
  if ('pacing' in entry) {
    if (!isObject(entry.pacing)) errors.push(`${at('pacing')}: must be an object`);
    else for (const k of PACING_KEYS) if (k in entry.pacing && !nonNeg(entry.pacing[k])) errors.push(`${at(`pacing.${k}`)}: must be a non-negative number`);
  }
  if ('guard' in entry) errors.push(...validateGuard(at, entry.guard, { means, production: envKind(entry) === 'production' }));
  if ('consent' in entry) errors.push(...validateConsent(at, entry.consent));
  if ('build_sha_url' in entry && !isHttpUrl(entry.build_sha_url)) errors.push(`${at('build_sha_url')}: must be an http(s) URL without credentials`);
  return errors;
}

/** Problems of `guard.operations`, and whether any operation carries a valid `cost`. */
function validateOperations(at, ops, means) {
  if (!isObject(ops)) return { errors: [`${at('guard.operations')}: must be an object of <name>: {method, url, body?, cost?, backend_calls?}`], costed: false };
  const errors = [];
  let costed = false;
  for (const [op, o] of Object.entries(ops)) {
    if (docKey(op)) continue;
    const p = `guard.operations.${op}`;
    if (!NEED_KEY.test(op)) errors.push(`${at(p)}: name must match ${NEED_KEY.source}`);
    if (means.includes(op)) errors.push(`${at(p)}: name is also a means key — a Needs key must resolve to one of them`);
    if (!isObject(o)) { errors.push(`${at(p)}: must be an object`); continue; }
    if (!isFilled(o.method)) errors.push(`${at(`${p}.method`)}: must be a non-empty string`);
    if (!isRegex(o.url)) errors.push(`${at(`${p}.url`)}: must be a regex that compiles`);
    if ('body' in o && !isRegex(o.body)) errors.push(`${at(`${p}.body`)}: must be a regex that compiles`);
    if ('cost' in o) {
      if (positive(o.cost)) costed = true;
      else errors.push(`${at(`${p}.cost`)}: must be a positive number`);
    }
    if ('backend_calls' in o && !(Number.isInteger(o.backend_calls) && o.backend_calls >= 1)) errors.push(`${at(`${p}.backend_calls`)}: must be an integer ≥ 1`);
  }
  return { errors, costed };
}

function validateStop(at, s) {
  if (!isObject(s)) return [`${at('guard.stop')}: must be an object`];
  const errors = [];
  for (const k of STOP_KEYS) if (k in s && !Array.isArray(s[k])) errors.push(`${at(`guard.stop.${k}`)}: must be an array`);
  if (Array.isArray(s.statuses) && s.statuses.some((c) => !(Number.isInteger(c) && c >= 100 && c <= 599))) errors.push(`${at('guard.stop.statuses')}: must be HTTP status codes`);
  for (const k of ['watch_4xx', 'challenge']) if (Array.isArray(s[k]) && s[k].some((r) => !isRegex(r))) errors.push(`${at(`guard.stop.${k}`)}: must be regexes that compile`);
  if (Array.isArray(s.error_signals) && s.error_signals.some((r) => !isObject(r) || !isRegex(r.url) || !isRegex(r.body))) {
    errors.push(`${at('guard.stop.error_signals')}: must be an array of {url, body} regexes`);
  }
  return errors;
}

function validateGuard(at, g, { means, production }) {
  if (!isObject(g)) return [`${at('guard')}: must be an object`];
  const errors = [];
  if ('hosts' in g && (!Array.isArray(g.hosts) || g.hosts.some((h) => typeof h !== 'string' || !HOSTNAME.test(h)))) {
    errors.push(`${at('guard.hosts')}: must be an array of hostnames or *.domain entries`);
  }
  if ('header' in g && !(isObject(g.header) && isFilled(g.header.name) && typeof (g.header.value ?? '') === 'string')) {
    errors.push(`${at('guard.header')}: must be {name, value} strings`);
  }
  let costed = false;
  if ('operations' in g) {
    const ops = validateOperations(at, g.operations, means);
    errors.push(...ops.errors);
    costed = ops.costed;
  }
  if ('rpc' in g && (!Array.isArray(g.rpc) || g.rpc.some((r) => !isObject(r) || !isRegex(r.url) || !isRegex(r.mutating)))) {
    errors.push(`${at('guard.rpc')}: must be an array of {url, mutating} regexes`);
  }
  if ('budget' in g && !positive(g.budget)) errors.push(`${at('guard.budget')}: must be a positive number`);
  else if (!('budget' in g) && costed && production) errors.push(`${at('guard.budget')}: required on a production environment with a costed operation`);
  if ('stop' in g) errors.push(...validateStop(at, g.stop));
  return errors;
}

function validateConsent(at, c) {
  if (!isObject(c)) return [`${at('consent')}: must be an object`];
  const errors = [];
  if ('strategy' in c && !CONSENT_STRATEGIES.includes(c.strategy)) errors.push(`${at('consent.strategy')}: must be ${CONSENT_STRATEGIES.join('|')}`);
  if ('cookies' in c) {
    const bad = !Array.isArray(c.cookies) || c.cookies.some((k) => !isObject(k) || !isFilled(k.name) || typeof k.value !== 'string' || !isFilled(k.domain)
      || ('path' in k && !(typeof k.path === 'string' && k.path.startsWith('/'))));
    if (bad) errors.push(`${at('consent.cookies')}: must be an array of {name, value, domain, path?} (path starting with /)`);
  }
  return errors;
}

/** Key-path type problems of a parsed config, as `<key path>: <problem>` strings. Never throws. */
export function validateConfig(cfg) {
  const errors = [];
  if (!isObject(cfg)) return ['top level: must be a JSON object'];
  const cat = cfg.catalog;
  if (!isObject(cat)) errors.push('catalog: required object');
  else {
    if ('path' in cat && !isFilled(cat.path)) errors.push('catalog.path: must be a non-empty string');
    if ('areas' in cat) {
      if (!isObject(cat.areas)) errors.push('catalog.areas: must be an object of CODE: name');
      else {
        for (const [code, name] of Object.entries(cat.areas)) {
          if (docKey(code)) continue;
          if (!AREA_CODE.test(code)) errors.push(`catalog.areas.${code}: area code must match ${AREA_CODE.source}`);
          if (!isFilled(name)) errors.push(`catalog.areas.${code}: name must be a non-empty string`);
        }
      }
    }
    if ('id_pattern' in cat) {
      if (!isFilled(cat.id_pattern)) errors.push('catalog.id_pattern: must be a non-empty string');
      else {
        try { new RegExp(cat.id_pattern); } catch (err) { errors.push(`catalog.id_pattern: does not compile (${err.message})`); }
      }
    }
    if ('smoke' in cat) {
      if (!Array.isArray(cat.smoke) || cat.smoke.some((p) => !PRIORITIES.includes(p))) {
        errors.push(`catalog.smoke: must be an array of ${PRIORITIES.join('|')}`);
      }
    }
  }
  if ('runner' in cfg) errors.push(...validateRunner(cfg.runner));
  if ('environments' in cfg) {
    const envs = cfg.environments;
    if (!isObject(envs)) errors.push('environments: must be an object of <name>: {host, kind}');
    else {
      for (const [name, entry] of Object.entries(envs)) {
        if (docKey(name)) continue;
        if (!isObject(entry)) { errors.push(`environments.${name}: must be an object`); continue; }
        if (entry.host !== 'qa-env' && !isBaseUrl(entry.host)) {
          errors.push(`environments.${name}.host: must be "qa-env" or an http(s) URL without credentials or a trailing /`);
        } else if (entry.host !== 'qa-env' && isLoopbackHost(urlHost(entry.host))) {
          errors.push(`environments.${name}.host: a local server is not a regression target`);
        }
        if ('kind' in entry && !ENV_KINDS.includes(entry.kind)) errors.push(`environments.${name}.kind: must be ${ENV_KINDS.join('|')}`);
        errors.push(...validateEnvPolicy(name, entry));
      }
    }
  }
  if ('visual' in cfg) errors.push(...validateVisual(cfg));
  if ('default_env' in cfg) {
    const envs = isObject(cfg.environments) ? cfg.environments : {};
    const d = cfg.default_env;
    if (!isFilled(d) || docKey(d) || !isObject(envs[d])) errors.push(`default_env: ${d} names no environment in environments`);
    else if (envKind(envs[d]) !== 'test') errors.push(`default_env: ${d} is a production environment — only a kind: test environment may be the default`);
  }
  return errors;
}

/**
 * The run target: `--env`, else `default_env`, else the only environment when it is `kind: test`.
 * `{name}` or `{error, names}` — production is never reached without naming it.
 */
export function resolveTarget(cfg, name) {
  const envs = isObject(cfg?.environments) ? cfg.environments : {};
  const names = Object.keys(envs).filter((k) => !docKey(k) && isObject(envs[k]));
  if (name !== undefined && name !== null) {
    return names.includes(name) ? { name } : { error: `unknown environment ${name}`, names };
  }
  if (isFilled(cfg?.default_env) && names.includes(cfg.default_env)) return { name: cfg.default_env };
  if (names.length === 1 && envKind(envs[names[0]]) === 'test') return { name: names[0] };
  const why = !names.length ? 'no environment configured'
    : names.length === 1 ? `the only environment ${names[0]} is production — name it with --env`
      : 'several environments and no default_env — name one with --env';
  return { error: `no target environment: ${why}`, names };
}

function validateRunner(runner) {
  if (!isObject(runner)) return ['runner: must be an object'];
  const errors = [];
  for (const k of RUNNER_STRINGS) if (!isFilled(runner[k])) errors.push(`runner.${k}: must be a non-empty string`);
  if (!isObject(runner.devices) || !Object.keys(runner.devices).filter((k) => !docKey(k)).length) {
    errors.push('runner.devices: must be a non-empty object of <device>: <runner project>');
  } else {
    for (const [k, v] of Object.entries(runner.devices)) if (!docKey(k) && !isFilled(v)) errors.push(`runner.devices.${k}: must be a non-empty string`);
  }
  for (const [group, keys] of [['commands', RUNNER_COMMANDS], ['test_data', TEST_DATA_COMMANDS]]) {
    if (!isObject(runner[group])) { errors.push(`runner.${group}: must be an object with ${keys.join(', ')}`); continue; }
    for (const k of keys) if (!isFilled(runner[group][k])) errors.push(`runner.${group}.${k}: must be a non-empty string`);
  }
  return errors;
}

/** `{adopted:false}` when the file is absent, else `{adopted:true, config, errors}`. */
export function loadConfig(root, configPath = CONFIG_PATH) {
  const file = path.resolve(root, configPath);
  if (!fs.existsSync(file)) return { adopted: false };
  let config;
  try {
    config = JSON.parse(fs.readFileSync(file, 'utf8'));
  } catch (err) {
    return { adopted: true, config: null, errors: [`not valid JSON (${err.message})`] };
  }
  return { adopted: true, config, errors: validateConfig(config) };
}

/** The `catalog` section merged over the defaults. */
export function catalogSettings(cfg) {
  const cat = isObject(cfg?.catalog) ? cfg.catalog : {};
  const areas = isObject(cat.areas) ? Object.fromEntries(Object.entries(cat.areas).filter(([k]) => !docKey(k))) : {};
  return { ...DEFAULTS, ...cat, areas };
}

/** `{url}` or `{error}` for environment `name`. */
export function resolveEnvBaseUrl(root, cfg, name) {
  const entry = isObject(cfg?.environments) ? cfg.environments[name] : undefined;
  if (!isObject(entry) || docKey(name)) return { error: `unknown environment ${name}` };
  if (entry.host !== 'qa-env') {
    if (!isBaseUrl(entry.host)) return { error: `environments.${name}.host is not an http(s) URL without credentials or a trailing /` };
    if (isLoopbackHost(urlHost(entry.host))) return { error: `environments.${name}.host: a local server is not a regression target` };
    return { url: entry.host };
  }
  const file = path.resolve(root, QA_ENV_PATH);
  if (!fs.existsSync(file)) return { error: `${QA_ENV_PATH} absent (environment ${name} uses host "qa-env")` };
  let qa;
  try { qa = JSON.parse(fs.readFileSync(file, 'utf8')); } catch (err) { return { error: `${QA_ENV_PATH} unparsable (${err.message})` }; }
  const url = qa?.base_url;
  if (!isFilled(url)) return { error: `${QA_ENV_PATH} base_url is empty (environment ${name} uses host "qa-env")` };
  if (!isBaseUrl(url)) return { error: `${QA_ENV_PATH} base_url is not an http(s) URL without credentials or a trailing /` };
  if (isLoopbackHost(urlHost(url))) return { error: `${QA_ENV_PATH} base_url: a local server is not a regression target (environment ${name})` };
  return { url };
}

// ---------------------------------------------------------------------------------------------
// The `visual` section (regression.md §13)

/** The device → runner project map of the config (doc keys and empty projects dropped). */
export const runnerDevices = (cfg) => (isObject(cfg?.runner?.devices) ? Object.fromEntries(Object.entries(cfg.runner.devices).filter(([k, v]) => !docKey(k) && typeof v === 'string' && v !== '')) : {});

export const VISUAL_DEFAULTS = { policy: 'warn', tolerance: { threshold: 0.2, max_diff_pixels: 0 }, max_mask_ratio: 0.25, timezone: 'UTC', mask: [] };
export const VISUAL_POLICIES = ['warn', 'block'];
export const VISUAL_DEVICES = ['desktop', 'mobile'];
export const ROOT_SELECTORS = ['html', 'body', ':root', '*'];
// The manifest owns update mode, repeats, selection, output, workers and retries: a flag here would
// bypass the acceptance, the selection, the disjointness check or the confirmed plan.
export const FORBIDDEN_FLAGS = /(^|\s)(--update-snapshots(=\S*)?|-u|--repeat-each(=\S*)?|--grep(=\S*)?|-g|--project(=\S*)?|--ignore-snapshots|--output(=\S*)?|-o|--workers(=\S*)?|-j|--retries(=\S*)?)(\s|$)/;
const OUTPUT_FLAGS = /(^|\s)(--output(=\S*)?|-o)(\s|$)/;
// Playwright sanitises a screenshot name and `{projectName}`: only names that sanitise to themselves.
export const VISUAL_ID = /^[a-z0-9][a-z0-9-]*$/;
const SAFE_NAME = /^[A-Za-z0-9][A-Za-z0-9-]*$/;
const VISUAL_STRINGS = ['config', 'spec', 'command', 'report', 'baselines'];

const isRepoRel = (v) => isFilled(v) && !path.isAbsolute(v) && !v.split(/[\\/]/).includes('..');
const normRel = (p) => path.posix.normalize(p.replace(/\\/g, '/')).replace(/\/+$/, '') || '.';
const within = (a, dir) => dir === '.' || a === dir || a.startsWith(`${dir}/`);
const overlap = (a, b) => within(a, b) || within(b, a);

function validateMasks(at, masks) {
  if (!Array.isArray(masks)) return [`${at}: must be an array of {selector, reason}`];
  const errors = [];
  masks.forEach((m, i) => {
    if (!isObject(m) || !isFilled(m.selector) || !isFilled(m.reason)) errors.push(`${at}.${i}: must be {selector, reason}, both non-empty`);
    else if (ROOT_SELECTORS.includes(m.selector.trim())) errors.push(`${at}.${i}.selector: ${m.selector.trim()} would mask the whole page — mask volatile regions only`);
  });
  return errors;
}

function validateRoutes(routes) {
  if (!Array.isArray(routes)) return ['visual.routes: must be an array of {id, path, title, devices?, mask?, full_page?, wait_for?}'];
  const errors = [];
  const seen = new Set();
  routes.forEach((r, i) => {
    const at = `visual.routes.${i}`;
    if (!isObject(r)) { errors.push(`${at}: must be an object`); return; }
    if (typeof r.id !== 'string' || !VISUAL_ID.test(r.id)) errors.push(`${at}.id: must match ${VISUAL_ID.source}`);
    else if (seen.has(r.id)) errors.push(`${at}.id: duplicate route id ${r.id}`);
    else seen.add(r.id);
    if (typeof r.path !== 'string' || !r.path.startsWith('/') || r.path.startsWith('//')) errors.push(`${at}.path: must be a path starting with / (no scheme, no host)`);
    if (!isFilled(r.title)) errors.push(`${at}.title: must be a non-empty string`);
    if ('devices' in r && (!Array.isArray(r.devices) || !r.devices.length || r.devices.some((d) => !VISUAL_DEVICES.includes(d)))) errors.push(`${at}.devices: must be a non-empty array of ${VISUAL_DEVICES.join('|')}`);
    if ('mask' in r) errors.push(...validateMasks(`${at}.mask`, r.mask));
    if ('full_page' in r && typeof r.full_page !== 'boolean') errors.push(`${at}.full_page: must be a boolean`);
    if ('wait_for' in r && r.wait_for !== null && !isFilled(r.wait_for)) errors.push(`${at}.wait_for: must be a selector or null`);
  });
  return errors;
}

/** The hosts a request of environment `name` may reach: `guard.hosts`, else the environment's own URL host. */
function allowedHosts(entry) {
  const hosts = Array.isArray(entry?.guard?.hosts) ? entry.guard.hosts.filter((h) => typeof h === 'string') : [];
  if (hosts.length) return hosts;
  return entry?.host && entry.host !== 'qa-env' ? [urlHost(entry.host)] : null;
}

function validateStorybook(sb, envs) {
  if (!isObject(sb)) return ['visual.storybook: must be an object of <environment>: {url, ready, error?, exclude_tags?, build_sha_url?}'];
  const errors = [];
  for (const [env, s] of Object.entries(sb)) {
    if (docKey(env)) continue;
    const at = `visual.storybook.${env}`;
    const entry = envs[env];
    if (!isObject(entry)) { errors.push(`${at}: names no environment in environments`); continue; }
    if (envKind(entry) !== 'test') { errors.push(`${at}: storybook is allowed only on a kind: test environment`); continue; }
    if (!isObject(s)) { errors.push(`${at}: must be an object`); continue; }
    if (!isBaseUrl(s.url)) errors.push(`${at}.url: must be an http(s) URL without credentials or a trailing /`);
    else if (isLoopbackHost(urlHost(s.url))) errors.push(`${at}.url: a local server is not a regression target`);
    else {
      const hosts = allowedHosts(entry);
      if (!hosts) errors.push(`${at}: list the storybook host in environments.${env}.guard.hosts`);
      else if (!hostAllowed({ hosts: hosts.map((p) => String(p).toLowerCase()) }, s.url)) errors.push(`${at}.url: host ${urlHost(s.url)} is not on the environment's allowlist — add it to environments.${env}.guard.hosts`);
    }
    if (!isFilled(s.ready)) errors.push(`${at}.ready: required — a selector present only once the story's render and play finished`);
    if ('error' in s && !isFilled(s.error)) errors.push(`${at}.error: must be a non-empty selector`);
    if ('exclude_tags' in s && (!Array.isArray(s.exclude_tags) || s.exclude_tags.some((t) => !isFilled(t)))) errors.push(`${at}.exclude_tags: must be an array of tags`);
    if ('build_sha_url' in s && !isBaseUrl(s.build_sha_url)) errors.push(`${at}.build_sha_url: must be an http(s) URL without credentials or a trailing /`);
  }
  return errors;
}

/** Problems of the `visual` section (and of the names it turns into directories). */
export function validateVisual(cfg) {
  const v = cfg.visual;
  if (!isObject(v)) return ['visual: must be an object'];
  const errors = [];
  for (const k of VISUAL_STRINGS) {
    if (!isFilled(v[k])) errors.push(`visual.${k}: must be a non-empty string`);
    else if (k !== 'command' && !isRepoRel(v[k])) errors.push(`visual.${k}: must be a repo-relative path without ..`);
  }
  if (isFilled(v.command) && FORBIDDEN_FLAGS.test(v.command)) errors.push('visual.command: must not set --update-snapshots, -u, --repeat-each, --grep, -g, --project, --ignore-snapshots, --output, -o, --workers, -j or --retries — the run manifest drives them');
  if ('policy' in v && !VISUAL_POLICIES.includes(v.policy)) errors.push(`visual.policy: must be ${VISUAL_POLICIES.join('|')}`);
  if ('tolerance' in v) {
    const t = v.tolerance;
    if (!isObject(t)) errors.push('visual.tolerance: must be {threshold, max_diff_pixels}');
    else {
      if ('threshold' in t && !(typeof t.threshold === 'number' && t.threshold >= 0 && t.threshold <= 1)) errors.push('visual.tolerance.threshold: must be a number in [0, 1]');
      if ('max_diff_pixels' in t && !(Number.isInteger(t.max_diff_pixels) && t.max_diff_pixels >= 0)) errors.push('visual.tolerance.max_diff_pixels: must be an integer ≥ 0');
    }
  }
  if ('max_mask_ratio' in v && !(typeof v.max_mask_ratio === 'number' && v.max_mask_ratio > 0 && v.max_mask_ratio <= 1)) errors.push('visual.max_mask_ratio: must be a number in (0, 1]');
  if ('timezone' in v && !isFilled(v.timezone)) errors.push('visual.timezone: must be a non-empty string');
  if ('mask' in v) errors.push(...validateMasks('visual.mask', v.mask));
  if (!('routes' in v)) errors.push('visual.routes: required (an array; may be [] only when storybook names an environment)');
  else errors.push(...validateRoutes(v.routes));
  const envs = isObject(cfg.environments) ? cfg.environments : {};
  const hasStorybook = isObject(v.storybook) && Object.keys(v.storybook).some((k) => !docKey(k));
  if (Array.isArray(v.routes) && !v.routes.length && !hasStorybook) errors.push('visual.routes: empty — name a route or a storybook environment');
  if ('storybook' in v) errors.push(...validateStorybook(v.storybook, envs));
  // Disk-safe names: environments and runner projects become baseline directories.
  const names = (list, what) => {
    const seen = new Map();
    for (const n of list) {
      if (!SAFE_NAME.test(n)) errors.push(`visual: ${what} ${n} is not a safe directory name (letters, digits and - only)`);
      else if (seen.has(n.toLowerCase())) errors.push(`visual: ${what} ${n} is not unique case-insensitively (${seen.get(n.toLowerCase())})`);
      else seen.set(n.toLowerCase(), n);
    }
  };
  names(Object.keys(envs).filter((k) => !docKey(k)), 'environment');
  const runner = isObject(cfg.runner) ? cfg.runner : null;
  if (runner && isObject(runner.devices)) names(Object.entries(runner.devices).filter(([k, p]) => !docKey(k) && isFilled(p)).map(([, p]) => p), 'runner project');
  if (runner && isObject(runner.commands)) {
    for (const [k, c] of Object.entries(runner.commands)) if (!docKey(k) && typeof c === 'string' && OUTPUT_FLAGS.test(c)) errors.push(`runner.commands.${k}: must not set --output/-o while visual is configured — the output directory must stay where the disjointness check sees it`);
  }
  // Path containment (string level; run.mjs resolves symlinks and Playwright's outputDir defaults).
  if (isRepoRel(v.baselines) && isRepoRel(v.spec)) {
    const base = normRel(v.baselines);
    const spec = normRel(v.spec);
    if (runner && isRepoRel(runner.spec_dir)) {
      const sd = normRel(runner.spec_dir);
      if (within(spec, sd)) errors.push(`visual.spec: must not lie inside runner.spec_dir (${sd}) — the functional runner would collect it`);
      if (within(base, sd)) errors.push(`visual.baselines: must not lie inside runner.spec_dir (${sd})`);
    }
    if (within(base, path.posix.dirname(spec))) errors.push(`visual.baselines: must not lie inside the directory of visual.spec (${path.posix.dirname(spec)})`);
    const dirs = [];
    if (runner && isRepoRel(runner.report)) dirs.push(['runner.report', path.posix.dirname(normRel(runner.report))]);
    if (isRepoRel(v.report)) dirs.push(['visual.report', path.posix.dirname(normRel(v.report))]);
    dirs.push([RUNS_DIR, RUNS_DIR]);
    for (const [what, d] of dirs) {
      if (overlap(base, d)) { errors.push(`visual.baselines: overlaps the directory of ${what} (${d})`); break; }
    }
  }
  return errors;
}

/** The `visual` section merged over VISUAL_DEFAULTS (doc keys dropped). */
export function visualSettings(cfg) {
  const v = isObject(cfg?.visual) ? cfg.visual : {};
  const clean = Object.fromEntries(Object.entries(v).filter(([k]) => !docKey(k)));
  const tolerance = { ...VISUAL_DEFAULTS.tolerance, ...(isObject(v.tolerance) ? v.tolerance : {}) };
  const storybook = isObject(v.storybook) ? Object.fromEntries(Object.entries(v.storybook).filter(([k]) => !docKey(k))) : {};
  return { ...VISUAL_DEFAULTS, ...clean, tolerance, mask: Array.isArray(v.mask) ? v.mask : [], routes: Array.isArray(v.routes) ? v.routes : [], storybook };
}
