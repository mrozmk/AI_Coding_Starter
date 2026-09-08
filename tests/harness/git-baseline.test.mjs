import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { BaselineError, compare, snapshot } from '../../harness-source/scripts/git-baseline.mjs';

const SCRIPT = path.resolve(import.meta.dirname, '../../harness-source/scripts/git-baseline.mjs');

// Every git call in these tests runs with the user's global and system config out of reach: a
// developer's core.excludesFile or hooksPath would otherwise change what the snapshot sees.
function gitEnv(home) {
  return { PATH: process.env.PATH, HOME: home, GIT_CONFIG_NOSYSTEM: '1', GIT_CONFIG_GLOBAL: path.join(home, '.gitconfig-none'), GIT_TERMINAL_PROMPT: '0' };
}

function repo() {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'harness-baseline-'));
  const home = fs.mkdtempSync(path.join(os.tmpdir(), 'harness-baseline-home-'));
  const env = gitEnv(home);
  const git = (...args) => {
    const r = spawnSync('git', ['-c', 'core.hooksPath=/dev/null', ...args], { cwd: dir, env, encoding: 'utf8' });
    if (r.status !== 0) throw new Error(`git ${args.join(' ')}: ${r.stderr}`);
    return r.stdout;
  };
  git('init', '-q', '-b', 'main', '.');
  git('config', 'user.email', 'harness@example.test');
  git('config', 'user.name', 'harness');
  fs.writeFileSync(path.join(dir, 'src.js'), 'one\n');
  fs.writeFileSync(path.join(dir, '.gitignore'), 'build/\nlocal.txt\n');
  fs.mkdirSync(path.join(dir, '.agents'), { recursive: true });
  fs.writeFileSync(path.join(dir, '.agents/kept.md'), 'kept\n');
  git('add', '-A');
  git('commit', '-q', '-m', 'init');
  return { dir, git, env, spawn: (cmd, args, opts) => spawnSync(cmd, args, { ...opts, env }) };
}

let n = 0;
function around(r, act) {
  const base = fs.mkdtempSync(path.join(os.tmpdir(), `harness-snap-${n++}-`));
  const before = path.join(base, 'before');
  const after = path.join(base, 'after');
  snapshot(before, { repoRoot: r.dir, git: r.spawn });
  act();
  snapshot(after, { repoRoot: r.dir, git: r.spawn });
  return { ...compare(before, after), base };
}

test('a tree nobody touched: ok, empty delta', () => {
  const r = repo();
  const c = around(r, () => {});
  assert.equal(c.status, 'ok');
  assert.deepEqual(c.delta, []);
  assert.deepEqual(c.deviations, []);
});

test('an untracked file created between the snapshots is delta, not a deviation', () => {
  const r = repo();
  const c = around(r, () => fs.writeFileSync(path.join(r.dir, 'new.js'), 'x\n'));
  assert.deepEqual(c.delta, ['new.js']);
  assert.equal(c.status, 'ok');
});

test('a write under .agents/ is a deviation', () => {
  const r = repo();
  const c = around(r, () => fs.writeFileSync(path.join(r.dir, '.agents/plan.md'), 'x\n'));
  assert.ok(c.delta.includes('.agents/plan.md'));
  assert.equal(c.status, 'deviation');
  assert.ok(c.deviations.some((d) => d.includes('writes under .agents/ or .claude/')), c.deviations.join('|'));
});

test('a protected file already dirty before both snapshots is exempt; a further edit is not', () => {
  const r = repo();
  fs.writeFileSync(path.join(r.dir, '.agents/kept.md'), 'edited by the human\n');
  const untouched = around(r, () => {});
  assert.equal(untouched.status, 'ok', 'pre-existing dirt the child never touched is not a deviation');
  assert.deepEqual(untouched.delta, []);

  const edited = around(r, () => fs.writeFileSync(path.join(r.dir, '.agents/kept.md'), 'edited again\n'));
  assert.deepEqual(edited.delta, ['.agents/kept.md']);
  assert.equal(edited.status, 'deviation');
});

test('a tracked file that was already dirty and changes again lands in the delta', () => {
  const r = repo();
  fs.writeFileSync(path.join(r.dir, 'src.js'), 'two\n');
  const c = around(r, () => fs.writeFileSync(path.join(r.dir, 'src.js'), 'three\n'));
  assert.deepEqual(c.delta, ['src.js']);
  assert.equal(c.status, 'ok');
});

test('a rename puts both endpoints in the delta', () => {
  const r = repo();
  const c = around(r, () => r.git('mv', 'src.js', 'moved.js'));
  assert.ok(c.delta.includes('src.js') && c.delta.includes('moved.js'), c.delta.join('|'));
});

test('an overwritten ignored build artifact is documented non-coverage: not delta, not deviation', () => {
  const r = repo();
  fs.mkdirSync(path.join(r.dir, 'build'), { recursive: true });
  fs.writeFileSync(path.join(r.dir, 'build/out.js'), 'old\n');
  const c = around(r, () => fs.writeFileSync(path.join(r.dir, 'build/out.js'), 'new\n'));
  assert.deepEqual(c.delta, []);
  assert.equal(c.status, 'ok');
});

test('an ignored file that vanishes is a deviation (git clean is invisible to status)', () => {
  const r = repo();
  fs.writeFileSync(path.join(r.dir, 'local.txt'), 'local\n');
  const c = around(r, () => fs.rmSync(path.join(r.dir, 'local.txt')));
  assert.equal(c.status, 'deviation');
  assert.ok(c.deviations.some((d) => d.includes('ignored files removed')), c.deviations.join('|'));
});

test('a repointed untracked symlink is a change; under .agents/ it is a deviation', () => {
  const r = repo();
  fs.writeFileSync(path.join(r.dir, 't1'), '1\n');
  fs.writeFileSync(path.join(r.dir, 't2'), '2\n');
  fs.symlinkSync('t1', path.join(r.dir, 'link'));
  const c = around(r, () => {
    fs.rmSync(path.join(r.dir, 'link'));
    fs.symlinkSync('t2', path.join(r.dir, 'link'));
  });
  assert.ok(c.delta.includes('link'), c.delta.join('|'));
  assert.equal(c.status, 'ok');

  fs.symlinkSync('../t1', path.join(r.dir, '.agents/link'));
  const p = around(r, () => {
    fs.rmSync(path.join(r.dir, '.agents/link'));
    fs.symlinkSync('../t2', path.join(r.dir, '.agents/link'));
  });
  assert.ok(p.delta.includes('.agents/link'));
  assert.equal(p.status, 'deviation');
});

test('a commit taken between the snapshots is a git-metadata deviation', () => {
  const r = repo();
  const c = around(r, () => {
    fs.writeFileSync(path.join(r.dir, 'src.js'), 'committed\n');
    r.git('add', '-A');
    r.git('commit', '-q', '-m', 'child commit');
  });
  assert.equal(c.status, 'deviation');
  assert.ok(c.deviations.some((d) => d.includes('git metadata changed')), c.deviations.join('|'));
});

test('a sensitive ignored file that changes is a deviation, hashed and never copied', () => {
  const r = repo();
  fs.appendFileSync(path.join(r.dir, '.gitignore'), '.env\n');
  r.git('add', '-A');
  r.git('commit', '-q', '-m', 'ignore env');
  fs.writeFileSync(path.join(r.dir, '.env'), 'TOKEN=before\n');
  const c = around(r, () => fs.writeFileSync(path.join(r.dir, '.env'), 'TOKEN=after\n'));
  assert.equal(c.status, 'deviation');
  assert.ok(c.deviations.some((d) => d.includes('secret-looking')), c.deviations.join('|'));
  const sensitive = JSON.parse(fs.readFileSync(path.join(c.base, 'before/sensitive.json'), 'utf8'));
  assert.ok(sensitive['.env'].sha256, 'sensitive files are hashed');
  assert.ok(!JSON.stringify(sensitive).includes('TOKEN='), 'contents are never stored');
});

test('a directory that is not a repository is a precondition failure', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'harness-norepo-'));
  assert.throws(() => snapshot(path.join(dir, 'snap'), { repoRoot: dir }), (e) => e instanceof BaselineError && e.code === 'precondition');
});

test('CLI: 0 clean, 1 deviation, 2 precondition', () => {
  const r = repo();
  const base = fs.mkdtempSync(path.join(os.tmpdir(), 'harness-cli-'));
  const run = (...args) => spawnSync(process.execPath, [SCRIPT, ...args], { cwd: r.dir, env: r.env, encoding: 'utf8' });

  assert.equal(run('snapshot', path.join(base, 'before'), '--repo-root', r.dir).status, 0);
  assert.equal(run('snapshot', path.join(base, 'after'), '--repo-root', r.dir).status, 0);
  const clean = run('compare', path.join(base, 'before'), path.join(base, 'after'));
  assert.equal(clean.status, 0);
  assert.equal(JSON.parse(clean.stdout).status, 'ok');

  fs.writeFileSync(path.join(r.dir, '.agents/late.md'), 'x\n');
  run('snapshot', path.join(base, 'after2'), '--repo-root', r.dir);
  const dirty = run('compare', path.join(base, 'before'), path.join(base, 'after2'));
  assert.equal(dirty.status, 1);
  assert.match(dirty.stderr, /DEVIATION: writes under/);

  const missing = run('compare', path.join(base, 'nope'), path.join(base, 'after'));
  assert.equal(missing.status, 2);
  assert.equal(JSON.parse(missing.stdout).status, 'precondition-failed');
});
