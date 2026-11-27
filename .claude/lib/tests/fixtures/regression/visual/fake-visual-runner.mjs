// Fake runner for regression-visual.test.mjs. Reads the pass manifest named by REGRESSION_RUN.
// A visual pass (`manifest.visual`): one `installed` guard event per case and repeat, one renderer
// line per project and one outcome line per case and repeat in <run>/visual.jsonl, tiny PNGs into
// the snapshot dir on `capture`, the visual report. A functional pass (no `manifest.visual`): a
// generated all-passed report of the selection, every case attested. Appends
// `visual <pass> <scenario>` (or `functional <scenario>`) to runner-calls.log under cwd.
//
//   node fake-visual-runner.mjs <scenario>[,<scenario>…]
//   scenario: name[:arg][@pass] — same · differs:<id> · error:<id> · unstable:<id> · retry:<id> ·
//   drop-repeat:<id> · blocked:<id> · blocked-outside · stop · renderer:<field> · split-renderer ·
//   no-attest:<id>[#<repeat>] · fail-report:<id> · mutate-candidate:<id> · touch-baselines[:<env>] ·
//   untouch-baselines[:<env>] · touch-accepted · interrupted · no-report · dump-env · exit:<n>
import fs from 'node:fs';
import path from 'node:path';

export const PNG_SIG = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
const BASE_FP = { browser: 'chromium', browser_version: '120.0', playwright: '1.50.0', platform: 'linux', os_major: '6', arch: 'x64', fonts: 'aaaaaaaaaaaa', mode: 'host' };

const cwd = process.cwd();
const spec = process.argv[2] ?? 'same';
const manifest = JSON.parse(fs.readFileSync(process.env.REGRESSION_RUN, 'utf8'));
const v = manifest.visual ?? null;
const pass = v?.pass ?? null;
const cfg = JSON.parse(fs.readFileSync(path.join(cwd, '.claude/regression.json'), 'utf8'));

const scenarios = spec.split(',').filter(Boolean).map((s) => {
  const [body, only] = s.split('@');
  const i = body.indexOf(':');
  return { name: i < 0 ? body : body.slice(0, i), arg: i < 0 ? null : body.slice(i + 1), only: only ?? null };
}).filter((s) => !s.only || s.only === pass);
const has = (name, arg) => scenarios.some((s) => s.name === name && (arg === undefined || s.arg === arg));
const argOf = (name) => scenarios.find((s) => s.name === name)?.arg ?? null;

fs.appendFileSync(path.join(cwd, 'runner-calls.log'), `${v ? `visual ${pass}` : 'functional'} ${spec}\n`);
if (has('dump-env')) {
  const names = ['PLAYWRIGHT_JSON_OUTPUT_FILE', 'PLAYWRIGHT_JSON_OUTPUT_DIR', 'PLAYWRIGHT_JSON_OUTPUT_NAME'].filter((k) => k in process.env);
  fs.appendFileSync(path.join(cwd, 'runner-env.log'), `${names.join(' ') || 'none'}\n`);
}

const log = path.join(manifest.run_dir, 'guard.jsonl');
const evidence = path.join(manifest.run_dir, 'visual.jsonl');
const t = new Date().toISOString();
const guardLine = (e) => fs.appendFileSync(log, `${JSON.stringify({ t, nonce: manifest.nonce, ...e })}\n`);
const evLine = (e) => fs.appendFileSync(evidence, `${JSON.stringify({ t, nonce: manifest.nonce, ...e })}\n`);
const baselinesDir = (env) => path.resolve(cwd, cfg.visual.baselines, env ?? manifest.env);
const isInterrupted = has('interrupted');

function writeReport(file, suites) {
  if (has('no-report')) return;
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, `${JSON.stringify({ config: { version: '1.50.0', rootDir: cwd }, suites }, null, 2)}\n`);
}
const result = (ok) => ({ status: isInterrupted ? 'interrupted' : ok ? 'passed' : 'failed', duration: 1, retry: 0 });

if (!v) {
  // Functional pass: everything selected passes and is attested.
  for (const c of manifest.selection) guardLine({ kind: 'installed', test: `${c.id}:${c.project}`, id: c.id, project: c.project, pass: null });
  const specs = manifest.selection.map((c) => ({
    title: `${c.id} — ${c.title}`, file: c.spec,
    tests: [{ projectName: c.project, expectedStatus: 'passed', status: isInterrupted ? 'unexpected' : 'expected', results: [result(true)] }],
  }));
  writeReport(path.resolve(cwd, cfg.runner.report), [{ title: 'functional', specs }]);
  if (has('touch-accepted')) {
    const dir = baselinesDir('test');
    const first = fs.readdirSync(dir, { recursive: true }).map(String).find((f) => f.endsWith('.png'));
    if (first) fs.appendFileSync(path.join(dir, first), 'x');
  }
} else {
  const repeats = v.repeat_each ?? 1;
  const projects = [...new Set(manifest.selection.map((c) => c.project))];
  const fpFor = (project, worker = 0) => {
    const fp = { ...BASE_FP };
    for (const s of scenarios.filter((x) => x.name === 'renderer')) fp[s.arg] = `${fp[s.arg]}-changed`;
    if (worker === 1) fp.fonts = 'bbbbbbbbbbbb';
    return fp;
  };
  for (const project of projects) {
    evLine({ kind: 'renderer', pass, project, fp: fpFor(project) });
    if (has('split-renderer') && project === projects[0]) evLine({ kind: 'renderer', pass, project, fp: fpFor(project, 1) });
  }
  const titleOf = (id) => v.targets.find((x) => x.id === id)?.title ?? id;
  const render = (c) => Buffer.concat([PNG_SIG, Buffer.from(`${c.id}|${c.project}${has('differs', c.id) ? '|changed' : ''}`)]);
  const specs = [];
  let anyFailed = false;
  for (const c of manifest.selection) {
    const tests = [];
    for (let r = 0; r < repeats; r += 1) {
      const test = `${c.id}:${c.project}:${r}`;
      const noAttest = scenarios.some((s) => s.name === 'no-attest' && (s.arg === c.id || s.arg === `${c.id}#${r}`));
      if (!noAttest) guardLine({ kind: 'installed', test, id: c.id, project: c.project, pass });
      const snap = path.join(v.snapshot_dir, c.project, c.file);
      let outcome;
      let reason = null;
      let diff = null;
      if (has('error', c.id)) { outcome = 'error'; reason = 'navigation 500'; }
      else if (pass === 'capture') {
        fs.mkdirSync(path.dirname(snap), { recursive: true });
        fs.writeFileSync(snap, render(c));
        outcome = 'captured';
      } else if (!fs.existsSync(snap)) outcome = 'missing';
      else {
        let bytes = render(c);
        if (has('unstable', c.id) && r === 1) bytes = Buffer.concat([bytes, Buffer.from('|noise')]);
        outcome = Buffer.compare(bytes, fs.readFileSync(snap)) === 0 ? 'same' : 'differs';
        if (outcome === 'differs') diff = `.agents/regression/runs/x/${c.file.replace(/\.png$/, '-diff.png')}`;
      }
      if (has('blocked', c.id) && r === 0) guardLine({ kind: 'blocked', reason: 'foreign host', method: 'GET', url: 'https://cdn.foreign.example.net/a.js', op: null, test });
      const dropped = has('drop-repeat', c.id) && r === (repeats > 1 ? 1 : 0);
      if (!dropped) evLine({ kind: 'outcome', pass, id: c.id, project: c.project, file: c.file, repeat: r, retry: 0, test, outcome, diff_pixels: outcome === 'differs' ? 12 : null, masked_ratio: 0, reason, diff });
      if (has('retry', c.id)) evLine({ kind: 'outcome', pass, id: c.id, project: c.project, file: c.file, repeat: r, retry: 1, test, outcome: 'same', diff_pixels: null, masked_ratio: 0, reason: null, diff: null });
      const ok = ['same', 'missing', 'captured'].includes(outcome) && !has('fail-report', c.id) && !(has('blocked', c.id) && r === 0);
      if (!ok) anyFailed = true;
      tests.push({ projectName: c.project, expectedStatus: 'passed', status: ok ? 'expected' : 'unexpected', results: [result(ok)] });
    }
    if (has('mutate-candidate', c.id) && pass === 'stability') fs.appendFileSync(path.join(v.snapshot_dir, c.project, c.file), 'later');
    specs.push({ title: `${c.id} — ${titleOf(c.id)}`, file: path.relative(cwd, path.resolve(cwd, cfg.visual.spec)), tests });
  }
  // The report groups repeats of one (title, project) as separate entries of `tests[]`.
  const merged = [];
  for (const s of specs) {
    const prev = merged.find((m) => m.title === s.title);
    if (prev) prev.tests.push(...s.tests); else merged.push(s);
  }
  writeReport(path.resolve(cwd, cfg.visual.report), [{ title: 'visual.spec.ts', specs: merged }]);
  if (has('blocked-outside')) guardLine({ kind: 'blocked', reason: 'foreign host', method: 'GET', url: 'https://foreign.example.net/x', op: null, test: null });
  if (has('stop')) {
    fs.writeFileSync(path.join(manifest.run_dir, 'stop.json'), `${JSON.stringify({ t, nonce: manifest.nonce, reason: 'status 429', url: `${manifest.base_url}/` })}\n`);
    guardLine({ kind: 'stop', reason: 'status 429', url: `${manifest.base_url}/` });
  }
  if (anyFailed) process.exitCode = 1;
}

if (has('touch-baselines')) {
  const dir = baselinesDir(argOf('touch-baselines'));
  fs.mkdirSync(dir, { recursive: true });
  fs.writeFileSync(path.join(dir, 'touched.txt'), 'x');
}
if (has('untouch-baselines')) fs.rmSync(path.join(baselinesDir(argOf('untouch-baselines')), 'touched.txt'), { force: true });
const exit = argOf('exit');
if (exit !== null) process.exitCode = Number(exit);
