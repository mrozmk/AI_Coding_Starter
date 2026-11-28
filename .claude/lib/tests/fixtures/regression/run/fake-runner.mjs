// Fake spec runner for regression-run.test.mjs: copies reports/<argv[2]>.json to the configured
// runner.report under cwd, optionally writes guard events (argv[3]) into the run directory of the
// manifest named by REGRESSION_RUN, appends one line to runner-calls.log, exits with argv[4] ?? 0.
// Each argument may be a comma list: entry REGRESSION_PASS - 1 (default 0) is taken — one entry
// per verify pass.
//
//   node fake-runner.mjs <report|-> [attest-all|attest-pass|attest-none|attest-skip-first|stop-429|session-missing|session-failed|
//        blocked-case|blocked-outside|attest-cases-only|session-first-only|session-no-test|attest-budget|
//        walk-groups|walk-groups-missing-last|walk-groups-session-missing|-] [exit]
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const pass = Number(process.env.REGRESSION_PASS ?? 1) - 1;
const pick = (v) => { const list = String(v).split(','); return list[Math.min(pass, list.length - 1)]; };
const [reportName = '-', events = '-', exit = '0'] = process.argv.slice(2).map(pick);
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
  const accountOf = (c) => (c.needs ?? []).find((k) => k.startsWith('account:'))?.slice('account:'.length);
  // sessions: 'session' (attested) | 'none' (missing) | 'session-failed' (the adapter failed) |
  // 'skip' (no sign-in at all). Each case signs in under its own test id, as the fixture does.
  const attestAll = ({ sessions = 'session', skipFirst = false, onlyFirstSession = false, withTest = true } = {}) => {
    const cases = manifest.selection.slice(skipFirst ? 1 : 0);
    for (const c of cases) line({ kind: 'installed', test: testId(c), id: c.id, project: c.project });
    let signed = 0;
    for (const c of cases) {
      const account = accountOf(c);
      if (!account || sessions === 'skip') continue;
      if (onlyFirstSession && signed) continue;
      signed += 1;
      const test = withTest ? { test: testId(c) } : {};
      line({ kind: 'session-start', account, ...test });
      if (sessions !== 'none') line({ kind: sessions, account, ...test });
    }
  };
  const walkGroups = ({ omitLast = false } = {}) => {
    const groups = manifest.walk?.groups ?? [];
    fs.mkdirSync(path.join(manifest.run_dir, 'walk'), { recursive: true });
    groups.slice(0, omitLast ? groups.length - 1 : groups.length).forEach((g) => {
      const routes = g.routes.map((r) => ({ route: r, outcome: 'ok', reason: null, sample: r, status: 200, final: r, title: 't', headings: [], aria: '', links: [], forms: [], submits: [] }));
      fs.writeFileSync(path.join(manifest.run_dir, 'walk', `${g.key}.json`), `${JSON.stringify({ key: g.key, account: g.account, done: true, routes })}\n`);
    });
  };
  if (events === 'attest-all' || events === 'attest-pass') attestAll();
  else if (events === 'attest-skip-first') attestAll({ skipFirst: true });
  else if (events === 'session-missing') attestAll({ sessions: 'none' });
  else if (events === 'session-failed') attestAll({ sessions: 'session-failed' });
  else if (events === 'attest-cases-only') attestAll({ sessions: 'skip' });
  else if (events === 'session-first-only') attestAll({ onlyFirstSession: true });
  else if (events === 'session-no-test') attestAll({ withTest: false });
  else if (events === 'attest-budget') {
    attestAll();
    const file = path.join(manifest.run_dir, 'budget.json');
    const state = fs.existsSync(file) ? JSON.parse(fs.readFileSync(file, 'utf8')) : { reserved: 0, by_op: {} };
    state.reserved += 1;
    state.by_op['price-call'] = (state.by_op['price-call'] ?? 0) + 1;
    fs.writeFileSync(file, `${JSON.stringify(state)}\n`);
    line({ kind: 'budget', op: 'price-call', cost: 1, reserved: state.reserved, test: testId(manifest.selection[0]) });
  } else if (events === 'walk-groups') { walkGroups(); attestAll(); }
  else if (events === 'walk-groups-missing-last') { walkGroups({ omitLast: true }); attestAll(); }
  else if (events === 'walk-groups-session-missing') { walkGroups(); attestAll({ sessions: 'none' }); }
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
