// Config library of the opt-in regression kit: loads and validates `.claude/regression.json`
// (sections `catalog`, `runner`, `environments`) and resolves an environment's base URL
// (`host: "qa-env"` → `.claude/qa-env.json` `base_url`). Library only — `catalog.mjs` and
// `setup.mjs` are its CLIs. Absent file = regression not adopted: every regression step is silent.
// Node builtins only — ships to every downstream. Contract: .agents/reference/regression.md.

import fs from 'node:fs';
import path from 'node:path';

export const CONFIG_PATH = '.claude/regression.json';
export const QA_ENV_PATH = '.claude/qa-env.json';
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

/** A base URL both sources must satisfy: http(s), a host, no credentials, no whitespace, no trailing `/`. */
export function isBaseUrl(s) {
  if (typeof s !== 'string' || s === '' || /\s/.test(s) || s.endsWith('/')) return false;
  let u;
  try { u = new URL(s); } catch { return false; }
  // The config is committed and `env` prints the URL: credentials in it would leak.
  return (u.protocol === 'http:' || u.protocol === 'https:') && u.hostname !== '' && u.username === '' && u.password === '';
}

/** An environment's kind; absent means production, so nothing destructive runs by omission. */
export const envKind = (entry) => entry?.kind ?? 'production';

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
        }
        if ('kind' in entry && !ENV_KINDS.includes(entry.kind)) errors.push(`environments.${name}.kind: must be ${ENV_KINDS.join('|')}`);
      }
    }
  }
  return errors;
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
    return isBaseUrl(entry.host) ? { url: entry.host } : { error: `environments.${name}.host is not an http(s) URL without credentials or a trailing /` };
  }
  const file = path.resolve(root, QA_ENV_PATH);
  if (!fs.existsSync(file)) return { error: `${QA_ENV_PATH} absent (environment ${name} uses host "qa-env")` };
  let qa;
  try { qa = JSON.parse(fs.readFileSync(file, 'utf8')); } catch (err) { return { error: `${QA_ENV_PATH} unparsable (${err.message})` }; }
  const url = qa?.base_url;
  if (!isFilled(url)) return { error: `${QA_ENV_PATH} base_url is empty (environment ${name} uses host "qa-env")` };
  if (!isBaseUrl(url)) return { error: `${QA_ENV_PATH} base_url is not an http(s) URL without credentials or a trailing /` };
  return { url };
}
