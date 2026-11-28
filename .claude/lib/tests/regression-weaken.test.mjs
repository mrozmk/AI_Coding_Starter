// Unit tests of the never-weaken check (.claude/lib/regression/weaken-check.mjs): every refused kind
// with its line, the allow-list, the retarget hole the heal critic closes, and the CLI. Each case
// derives `after` from one base spec by one string replacement.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

import { weakenCheck } from '../regression/weaken-check.mjs';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const CLI = path.join(HERE, '../regression/weaken-check.mjs');
const AUTHORING = path.join(HERE, 'fixtures/regression/run/authoring/e2e/regression/cart');

const BASE = [
  "import { test, expect } from '../../fixtures';",
  '',
  '// regression: CART-004 · source: live',
  "test('CART-004 — Change quantity', { tag: ['@regression'] }, async ({ page }) => {",
  "  const stepper = page.getByRole('spinbutton', { name: 'Quantity' });",
  "  await page.goto('/cart');",
  "  await page.getByRole('button', { name: 'Increase' }).click();",
  "  await expect(stepper).toHaveValue('2');",
  "  await expect(page.getByRole('heading', { name: 'Cart' })).toBeVisible({ timeout: 5000 });",
  "  await expect(page).toHaveScreenshot('cart.png', { maxDiffPixels: 0 });",
  '});',
  '',
].join('\n');
// 1-based lines of BASE.
const L = { binding: 5, goto: 6, click: 7, value: 8, heading: 9, shot: 10, test: 4, header: 3 };

const swap = (from, to, text = BASE) => {
  assert.ok(text.includes(from), `the base holds ${from}`);
  return text.replace(from, to);
};
const kinds = (r) => r.weakened.map((w) => w.kind);
const find = (list, kind) => list.find((w) => w.kind === kind);
/** One refused finding of `kind` on `line`. */
function refuses(r, kind, line) {
  assert.equal(r.ok, false, JSON.stringify(r));
  const w = find(r.weakened, kind);
  assert.ok(w, `${kind} in ${JSON.stringify(r.weakened)}`);
  if (line !== undefined) assert.equal(w.line, line, JSON.stringify(w));
}

test('identical text passes', () => {
  assert.deepEqual(weakenCheck(BASE, BASE), { ok: true, weakened: [], allowed: [] });
});

test('refuses a removed assertion', () => {
  const r = weakenCheck(BASE, swap("  await expect(stepper).toHaveValue('2');\n", ''));
  refuses(r, 'removed-assertion', L.value);
  assert.deepEqual(kinds(r), ['removed-assertion']);
});

test('refuses a loosened matcher', () => {
  const r = weakenCheck(BASE, swap("toHaveValue('2')", "toContainText('2')"));
  refuses(r, 'loosened-matcher', L.value);
  assert.deepEqual(kinds(r), ['loosened-matcher']);
  const n = weakenCheck(BASE, swap('expect(stepper).toHaveValue', 'expect(stepper).not.toHaveValue'));
  refuses(n, 'loosened-matcher', L.value);
});

test('refuses a changed expected value', () => {
  const r = weakenCheck(BASE, swap("toHaveValue('2')", "toHaveValue('3')"));
  refuses(r, 'changed-value', L.value);
  assert.deepEqual(kinds(r), ['changed-value']);
});

test('refuses a changed tolerance', () => {
  const r = weakenCheck(BASE, swap('maxDiffPixels: 0', 'maxDiffPixels: 10'));
  refuses(r, 'changed-tolerance', L.shot);
  assert.deepEqual(kinds(r), ['changed-tolerance']);
});

test('refuses an added skip, fixme, fail, only or slow marker', () => {
  const cases = [
    ['test.skip(', swap("test('CART-004", "test.skip('CART-004"), L.test],
    ['test.fixme(', swap("test('CART-004", "test.fixme('CART-004"), L.test],
    ['test.fail(', swap("test('CART-004", "test.fail('CART-004"), L.test],
    ['test.only(', swap("test('CART-004", "test.only('CART-004"), L.test],
    ['test.slow(', swap("  await page.goto('/cart');", "  test.slow();\n  await page.goto('/cart');"), L.goto],
    ['test.describe.skip(', swap("test('CART-004", "test.describe.skip('group', () => {});\ntest('CART-004"), L.test],
    ['test.step.skip(', swap("  await page.goto('/cart');", "  await test.step.skip('later', async () => {});\n  await page.goto('/cart');"), L.goto],
    ['test.skip(true, …) in the body', swap("  await page.goto('/cart');", "  test.skip(true, 'x');\n  await page.goto('/cart');"), L.goto],
    ['test.info().fixme()', swap("  await page.goto('/cart');", "  test.info().fixme();\n  await page.goto('/cart');"), L.goto],
    ['test.abort(', swap("  await page.goto('/cart');", "  test.abort();\n  await page.goto('/cart');"), L.goto],
  ];
  for (const [name, after, line] of cases) {
    const r = weakenCheck(BASE, after);
    assert.equal(r.ok, false, name);
    const w = find(r.weakened, 'added-marker');
    assert.ok(w, `${name}: ${JSON.stringify(r.weakened)}`);
    assert.equal(w.line, line, name);
  }
});

test('refuses an added unobservable line', () => {
  const r = weakenCheck(BASE, swap('// regression: CART-004 · source: live', '// regression: CART-004 · source: live\n// regression-unobservable: CART-004 · quantity is two — server side only'));
  refuses(r, 'added-unobservable', L.header + 1);
});

test('refuses a changed title, tag or header', () => {
  refuses(weakenCheck(BASE, swap('CART-004 — Change quantity', 'CART-004 — Change it')), 'changed-identity', L.test);
  refuses(weakenCheck(BASE, swap("tag: ['@regression']", "tag: ['@regression', '@smoke']")), 'changed-identity', L.test);
  refuses(weakenCheck(BASE, swap('source: live', 'source: code')), 'changed-identity', L.header);
});

test('--refresh allows only the header line to change', () => {
  const header = swap('source: live', 'source: E1-1.AC1 [abcdef]');
  const r = weakenCheck(BASE, header, { refresh: true });
  assert.equal(r.ok, true, JSON.stringify(r));
  assert.deepEqual(r.allowed.map((a) => [a.kind, a.line]), [['header', L.header]]);
  refuses(weakenCheck(BASE, swap('Change quantity', 'Other title', header), { refresh: true }), 'changed-identity', L.test);
  refuses(weakenCheck(BASE, swap("toHaveValue('2')", "toHaveValue('3')", header), { refresh: true }), 'changed-value', L.value);
  const moved = weakenCheck(BASE, swap("page.getByRole('banner')", "page.getByRole('heading', { name: 'Cart' })", swap("page.getByRole('heading', { name: 'Cart' })", "page.getByRole('banner')", header)), { refresh: true });
  assert.equal(weakenCheck(BASE, swap("page.getByRole('heading', { name: 'Cart' })", "page.getByRole('banner')", header)).ok, false, 'the header alone refuses without --refresh');
  assert.equal(moved.ok, true, 'a locator put back is no change');
  const retargeted = weakenCheck(BASE, swap("page.getByRole('heading', { name: 'Cart' })", "page.getByRole('banner')", header), { refresh: true });
  refuses(retargeted, 'retargeted', L.heading);
  assert.match(find(retargeted.weakened, 'retargeted').detail, /a refresh changes only the header$/);
  assert.deepEqual(retargeted.allowed.map((a) => a.kind), ['header']);
});

test('refuses an edit it cannot classify', () => {
  const value = "  await expect(stepper).toHaveValue('2');";
  const heading = "  await expect(page.getByRole('heading', { name: 'Cart' })).toBeVisible({ timeout: 5000 });";
  const cases = [
    ['removed action line', swap("  await page.getByRole('button', { name: 'Increase' }).click();\n", ''), L.click, /removed action/],
    ['reordered two assertions', swap(`${value}\n${heading}`, `${heading}\n${value}`), L.value, /reordered assertion/],
    ['wrapped in if', swap(value, `  if (x) { ${value.trim()} }`), L.value, /control flow/],
    ['try / catch', swap(value, `  try { ${value.trim()} } catch {}`), L.value, /control flow/],
    ['.catch( on an expect', swap(value, "  await expect(stepper).toHaveValue('2').catch(() => {});"), L.value, /control flow/],
    ['|| inside an assertion', swap(value, "  await expect(stepper).toHaveValue('2' || '3');"), L.value, /added statement/],
    ['a new import', swap("import { test, expect } from '../../fixtures';", "import { test, expect } from '../../fixtures';\nimport { helper } from './helper';"), 1, /imports changed/],
    ['toPass added', swap(value, `${value}\n  await expect(async () => { await page.reload(); }).toPass();`), L.value + 1, /added statement/],
    ['two tests', `${BASE}test('CART-004 — again', { tag: ['@regression'] }, async ({ page }) => {});\n`, 1, /2 test\( calls/],
  ];
  for (const [name, after, line, detail] of cases) {
    const r = weakenCheck(BASE, after);
    assert.equal(r.ok, false, name);
    const w = r.weakened.find((x) => x.kind === 'unclassified' && detail.test(x.detail));
    assert.ok(w, `${name}: ${JSON.stringify(r.weakened)}`);
    assert.equal(w.line, line, `${name}: ${JSON.stringify(w)}`);
  }
});

test('allows a retargeted locator, a changed timeout, an added assertion, action or wait, and reports each', () => {
  let after = swap("page.getByRole('button', { name: 'Increase' })", "page.getByTestId('increase')");
  after = swap("page.getByRole('spinbutton', { name: 'Quantity' })", "page.getByLabel('Quantity')", after);
  after = swap('timeout: 5000', 'timeout: 15000', after);
  after = swap("  await page.goto('/cart');", "  await page.goto('/cart');\n  await page.waitForLoadState('domcontentloaded');\n  await page.getByRole('button', { name: 'Accept' }).hover();", after);
  after = swap("  await expect(stepper).toHaveValue('2');", "  await expect(stepper).toHaveValue('2');\n  await expect(stepper).toBeEnabled();", after);
  const r = weakenCheck(BASE, after);
  assert.equal(r.ok, true, JSON.stringify(r.weakened));
  const got = r.allowed.map((a) => [a.kind, a.line]).sort();
  assert.deepEqual(got, [
    ['added-action', L.goto + 2], ['added-assertion', L.value + 3], ['added-wait', L.goto + 1],
    ['retargeted', L.binding], ['retargeted', L.click + 2], ['timeout', L.heading + 3],
  ].sort());
  assert.match(find(r.allowed, 'timeout').detail, /5000 → 15000/);
});

test('the retarget hole: an assertion moved to an always-visible header passes and is reported retargeted', () => {
  const r = weakenCheck(BASE, swap("page.getByRole('heading', { name: 'Cart' })", "page.getByRole('banner')"));
  assert.equal(r.ok, true, JSON.stringify(r.weakened));
  const w = find(r.allowed, 'retargeted');
  assert.equal(w.line, L.heading);
  assert.match(w.detail, /getByRole \( 'heading' , \{ name : 'Cart' \} \) \) ?→|getByRole.*'heading'.*→.*'banner'/);
});

test("refuses a dropped await, a changed literal inside a string, and a relaxed exact locator", () => {
  refuses(weakenCheck(BASE, swap("  await page.goto('/cart');", "  page.goto('/cart');")), 'unclassified', L.goto);
  const assertAwait = weakenCheck(BASE, swap("  await expect(stepper).toHaveValue('2');", "  expect(stepper).toHaveValue('2');"));
  refuses(assertAwait, 'unclassified', L.value);
  const spaced = swap("  await expect(stepper).toHaveValue('2');", "  await expect(stepper).toHaveValue('2');\n  await expect(page.getByRole('status')).toHaveText('A  B');");
  refuses(weakenCheck(spaced, swap("'A  B'", "'A B'", spaced)), 'changed-value', L.value + 1);
  const exact = swap("{ name: 'Cart' }", "{ name: 'Cart', exact: true }");
  refuses(weakenCheck(exact, BASE), 'loosened-matcher', L.heading);
  refuses(weakenCheck(BASE, swap("name: 'Quantity'", 'name: /Quantity/')), 'loosened-matcher', L.binding);
});

test('a binding chain ending in an action is unclassified', () => {
  const r = weakenCheck(BASE, swap("  await page.goto('/cart');", "  const b = page.getByRole('button').click();\n  await page.goto('/cart');"));
  refuses(r, 'unclassified', L.goto);
  assert.match(find(r.weakened, 'unclassified').detail, /const b = page/);
});

test("a timeout key inside a generic matcher's expected object is data, not an option", () => {
  const extra = (lines) => swap("  await expect(stepper).toHaveValue('2');", `  await expect(stepper).toHaveValue('2');\n${lines}`);
  const before = extra("  await expect(count).toEqual({ timeout: 5000 });\n  await expect(stepper).toHaveJSProperty('x', { timeout: 1 });\n  await expect(stepper).toHaveJSProperty('y', 1, { timeout: 1 });");
  let after = swap('toEqual({ timeout: 5000 })', 'toEqual({ timeout: 10000 })', before);
  after = swap('toBeVisible({ timeout: 5000 })', 'toBeVisible({ timeout: 6000 })', after);
  const r = weakenCheck(before, after);
  refuses(r, 'changed-value', L.value + 1);
  assert.equal(find(r.allowed, 'timeout').line, L.heading + 3);
  const jsData = weakenCheck(before, swap("toHaveJSProperty('x', { timeout: 1 })", "toHaveJSProperty('x', { timeout: 2 })", before));
  refuses(jsData, 'changed-value', L.value + 2);
  const jsOpt = weakenCheck(before, swap("toHaveJSProperty('y', 1, { timeout: 1 })", "toHaveJSProperty('y', 1, { timeout: 2 })", before));
  assert.equal(jsOpt.ok, true, JSON.stringify(jsOpt.weakened));
  assert.equal(find(jsOpt.allowed, 'timeout').line, L.value + 3);
});

test('accepts the shipped spec shapes: anonymous and test.use({ account }) signed-in; a changed account is refused', () => {
  for (const f of ['cart-008.spec.ts', 'cart-009.spec.ts']) {
    const text = fs.readFileSync(path.join(AUTHORING, f), 'utf8');
    assert.deepEqual(weakenCheck(text, text), { ok: true, weakened: [], allowed: [] }, f);
  }
  const anon = fs.readFileSync(path.join(AUTHORING, 'cart-008.spec.ts'), 'utf8');
  const line = anon.split('\n').findIndex((l) => l.startsWith('test.use')) + 1;
  refuses(weakenCheck(anon, anon.replace('account: null', "account: 'shopper'")), 'changed-identity', line);
});

test('CLI prints one weakened line per finding and exits 1; --json prints {weakened, allowed}; a missing file exits 2', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'regression-weaken-'));
  const before = path.join(dir, 'before.spec.ts');
  const after = path.join(dir, 'after.spec.ts');
  fs.writeFileSync(before, BASE);
  fs.writeFileSync(after, swap("toHaveValue('2')", "toHaveValue('3')").replace('maxDiffPixels: 0', 'maxDiffPixels: 5'));
  const run = (...args) => spawnSync(process.execPath, [CLI, ...args], { encoding: 'utf8' });
  const r = run(before, after);
  assert.equal(r.status, 1, r.stderr);
  const lines = r.stdout.trim().split('\n');
  assert.deepEqual(lines.filter((l) => l.startsWith('weakened: ')).map((l) => l.replace(/ — .*/, '')), [`weakened: ${L.value}: changed-value`, `weakened: ${L.shot}: changed-tolerance`]);
  assert.equal(lines.at(-1), 'weaken-check: refused (2)');
  const j = run(before, after, '--json');
  assert.equal(j.status, 1);
  const doc = JSON.parse(j.stdout);
  assert.deepEqual(Object.keys(doc).sort(), ['allowed', 'ok', 'weakened']);
  assert.equal(doc.weakened.length, 2);
  const same = run(before, before);
  assert.equal(same.status, 0);
  assert.match(same.stdout, /^weaken-check: ok$/m);
  assert.equal(run(before, path.join(dir, 'absent.spec.ts')).status, 2);
  assert.equal(run(before).status, 2);
});
