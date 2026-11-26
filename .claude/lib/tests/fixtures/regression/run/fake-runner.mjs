// Fake spec runner for regression-run.test.mjs: copies reports/<argv[2]>.json to the configured
// runner.report under cwd, optionally writes guard events (argv[3]) into the run directory of the
// manifest named by REGRESSION_RUN, appends one line to runner-calls.log, exits with argv[4] ?? 0.
//
//   node fake-runner.mjs <report|-> [attest-all|attest-none|attest-skip-first|stop-429|session-missing|session-failed|blocked-case|blocked-outside|-] [exit]
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const [reportName = '-', events = '-', exit = '0'] = process.argv.slice(2);
const cwd = process.cwd();

fs.appendFileSync(path.join(cwd, 'runner-calls.log'), `${reportName} ${events}\n`);
const cfg = JSON.parse(fs.readFileSync(path.join(cwd, '.claude/regression.json'), 'utf8'));
if (reportName !== '-') {
  const dest = path.resolve(cwd, cfg.runner.report);
  fs.mkdirSync(path.dirname(dest), { recursive: true });
  fs.copyFileSync(path.join(HERE, 'reports', `${reportName}.json`), dest);
}

if (events !== '-' && process.env.REGRESSION_RUN) {
  const manifest = JSON.parse(fs.readFileSync(process.env.REGRESSION_RUN, 'utf8'));
  const log = path.join(manifest.run_dir, 'guard.jsonl');
  const t = new Date().toISOString();
  const line = (e) => fs.appendFileSync(log, `${JSON.stringify({ t, nonce: manifest.nonce, ...e })}\n`);
  const testId = (c) => `${c.id}:${c.project}`;
  // sessions: 'session' (attested) | 'none' (missing) | 'session-failed' (the adapter failed)
  const attestAll = ({ sessions = 'session', skipFirst = false } = {}) => {
    for (const c of manifest.selection.slice(skipFirst ? 1 : 0)) line({ kind: 'installed', test: testId(c), id: c.id, project: c.project });
    const accounts = new Set(manifest.selection.flatMap((c) => (c.needs ?? []).filter((k) => k.startsWith('account:')).map((k) => k.slice('account:'.length))));
    for (const account of accounts) {
      line({ kind: 'session-start', account });
      if (sessions !== 'none') line({ kind: sessions, account });
    }
  };
  if (events === 'attest-all') attestAll();
  else if (events === 'attest-skip-first') attestAll({ skipFirst: true });
  else if (events === 'session-missing') attestAll({ sessions: 'none' });
  else if (events === 'session-failed') attestAll({ sessions: 'session-failed' });
  else if (events === 'stop-429') {
    attestAll();
    const stop = { t, nonce: manifest.nonce, reason: 'status 429', url: `${manifest.base_url}/api/price` };
    fs.writeFileSync(path.join(manifest.run_dir, 'stop.json'), `${JSON.stringify(stop)}\n`);
    line({ kind: 'stop', reason: 'status 429', url: `${manifest.base_url}/api/price` });
  } else if (events === 'blocked-case') {
    attestAll();
    const c = manifest.selection[0];
    line({ kind: 'blocked', reason: 'foreign host', method: 'GET', url: 'https://foreign.example.net/x', op: null, test: testId(c) });
  } else if (events === 'blocked-outside') {
    attestAll();
    line({ kind: 'blocked', reason: 'foreign host', method: 'GET', url: 'https://foreign.example.net/x', op: null, test: null });
  }
}

process.exit(Number(exit));
