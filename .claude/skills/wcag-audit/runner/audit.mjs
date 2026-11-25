#!/usr/bin/env node
// audit.mjs — the deterministic core of /wcag-audit and its single entry point: doctor, scan, pack,
// ingest, render. Self-contained: node: builtins + the pinned engine cache (loaded by createRequire
// in lib/deps.mjs); never imports harness-source/. stdout = one JSON object; exit 0 ok · 2 usage ·
// 3 refusal · 4 run error.
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { Refusal, assertWork, readRun, writeRun, writeAtomic } from './lib/paths.mjs';

export const SKILL_DIR = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');

const USAGE = 'usage: audit.mjs doctor [--json] [--launch] | scan --urls-file <f> [--level A|AA] [--wcag 2.2|2.1] [--viewports desktop,mobile] [--max-pages n] [--client public-sector|eaa-service|microenterprise|other|unknown] [--no-llm] [--slug s] | pack --work <dir> --phase probe|judge|disprove | ingest --work <dir> --phase judge|disprove --file <f> | render --work <dir> [--lang <code>]';

const FLAGS = new Set(['--json', '--launch', '--no-llm']);

function parse(argv) {
  const [cmd, ...rest] = argv;
  const opts = {};
  for (let i = 0; i < rest.length; i += 1) {
    const a = rest[i];
    if (!a.startsWith('--')) throw new UsageError(`unexpected argument: ${a}`);
    if (FLAGS.has(a)) { opts[a.slice(2)] = true; continue; }
    const v = rest[i + 1];
    if (v === undefined || v.startsWith('--')) throw new UsageError(`${a} needs a value`);
    opts[a.slice(2)] = v;
    i += 1;
  }
  return { cmd, opts };
}

class UsageError extends Error {}

function out(obj, code = 0) {
  process.stdout.write(`${JSON.stringify(obj)}\n`);
  process.exitCode = code;
}

async function doctor(opts) {
  const deps = await import('./lib/deps.mjs');
  const info = { ok: false, node: process.versions.node, cache_dir: deps.cacheRoot() };
  if (!deps.nodeOk()) return out({ ...info, install: 'broken', refusal: 'node-too-old', reason: `node ${process.versions.node} < 22.12`, hint: 'install Node >= 22.12' }, 3);
  const st = deps.classifyInstall();
  info.install = st.install;
  if (st.install !== 'ready') {
    const hint = 'run: bash .claude/skills/wcag-audit/install.sh';
    return out({ ...info, reason: st.reason ?? 'engine cache not installed', refusal: st.install === 'absent' ? 'cache-absent' : (st.reason === 'cache-key-mismatch' ? 'cache-key-mismatch' : 'cache-broken'), hint }, 3);
  }
  info.cache_dir = st.dir;
  try {
    info.browser = deps.browserChoice(st.dir);
  } catch (err) {
    if (err instanceof Refusal) return out({ ...info, install: 'broken', reason: err.code, refusal: err.code, hint: err.hint }, 3);
    throw err;
  }
  if (opts.launch) {
    const { launchCheck } = await import('./lib/browser.mjs');
    try {
      info.launch = await launchCheck();
    } catch (err) {
      return out({ ...info, install: 'broken', reason: 'sandbox-failed', refusal: 'sandbox-failed', hint: String(err.message || err).split('\n')[0].slice(0, 300) }, 3);
    }
  }
  return out({ ...info, ok: true }, 0);
}

async function pack(opts) {
  const work = assertWork(opts.work);
  const p = await import('./lib/pack.mjs');
  if (opts.phase === 'probe') return out({ ok: true, ...p.writeProbe(work) });
  return out({ ok: true, ...p.writePack(work, opts.phase) });
}

async function ingestCmd(opts) {
  const work = assertWork(opts.work);
  if (!opts.file) throw new UsageError('--file is required');
  const { ingest } = await import('./lib/ingest.mjs');
  return out({ ok: true, ...ingest(work, opts.phase, path.resolve(opts.file)) });
}

async function renderCmd(opts) {
  const work = assertWork(opts.work);
  const { finalize } = await import('./lib/evidence.mjs');
  const { render, loadLegal } = await import('./lib/render.mjs');
  const { releaseLock } = await import('./lib/pack.mjs');
  const run = readRun(work);
  finalize(run);
  writeRun(work, run);
  const html = render(run, { lang: opts.lang || 'en', siteLang: run.site_lang ?? null, work, legal: loadLegal(SKILL_DIR) });
  const root = path.dirname(work);
  const base = path.basename(work);
  const htmlPath = path.join(root, `${base}.html`);
  const jsonPath = path.join(root, `${base}.json`);
  writeAtomic(htmlPath, html);
  writeAtomic(jsonPath, `${JSON.stringify(run, null, 2)}\n`);
  releaseLock(work);
  return out({ ok: true, html: htmlPath, json: jsonPath, verdict: run.verdict });
}

async function scan(opts) {
  const { scanCommand } = await import('./lib/scan.mjs');
  const res = await scanCommand(opts);
  return out(res.body, res.code);
}

export async function main(argv = process.argv.slice(2)) {
  let parsed;
  try {
    parsed = parse(argv);
    switch (parsed.cmd) {
      case 'doctor': return await doctor(parsed.opts);
      case 'scan': return await scan(parsed.opts);
      case 'pack': return await pack(parsed.opts);
      case 'ingest': return await ingestCmd(parsed.opts);
      case 'render': return await renderCmd(parsed.opts);
      default: throw new UsageError(parsed.cmd ? `unknown subcommand: ${parsed.cmd}` : 'missing subcommand');
    }
  } catch (err) {
    if (err instanceof UsageError) return out({ ok: false, refusal: 'usage', hint: `${err.message} — ${USAGE}` }, 2);
    if (err instanceof Refusal) return out({ ok: false, refusal: err.code, hint: err.hint }, 3);
    process.stderr.write(`audit.mjs: ${err && err.stack ? err.stack.split('\n')[0] : err}\n`);
    return out({ ok: false, error: 'run-error', hint: String(err && err.message ? err.message : err).slice(0, 300) }, 4);
  }
}

if (process.argv[1] && fs.realpathSync(process.argv[1]) === fileURLToPath(import.meta.url)) {
  await main();
}
