// Unit tests of the static spec scan (.claude/lib/regression/speclint.mjs): lintSpec over a
// candidate spec and the transitive closure of its relative imports, and the run pre-flight
// (checkIntegration) after its scan helpers moved here. Temp copies of the fixture root only.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import { lintSpec, RETRY_NEEDLES } from '../regression/speclint.mjs';
import { checkIntegration } from '../regression/run.mjs';
import { loadConfig } from '../regression/config.mjs';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const FIX = path.join(HERE, 'fixtures/regression/speclint');
const RUN_FIX = path.join(HERE, 'fixtures/regression/run/root');
const SPEC = 'e2e/regression/cart/cart-004.spec.ts';

function copyRoot(from = FIX) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'regression-speclint-'));
  fs.cpSync(from, root, { recursive: true });
  return root;
}
const cfgOf = (root) => loadConfig(root).config;
const read = (root, rel) => fs.readFileSync(path.join(root, rel), 'utf8');
const write = (root, rel, text) => { fs.mkdirSync(path.dirname(path.join(root, rel)), { recursive: true }); fs.writeFileSync(path.join(root, rel), text); };
const lint = (root, spec = SPEC, id = 'CART-004') => lintSpec(root, cfgOf(root), spec, id);
const rules = (r) => r.violations.map((v) => v.rule);

/** The conforming spec with one textual change; returns its violations. */
function variant(change, { id = 'CART-004' } = {}) {
  const root = copyRoot();
  write(root, SPEC, change(read(root, SPEC)));
  return rules(lint(root, SPEC, id));
}
const hasRule = (list, re) => assert.ok(list.some((r) => re.test(r)), `expected ${re} in:\n${list.join('\n')}`);

test('lint: a conforming spec passes', () => {
  const root = copyRoot();
  const r = lint(root);
  assert.deepEqual(r.violations, []);
  assert.deepEqual(r.files, ['e2e/fixtures.ts', SPEC, 'e2e/regression/cart/helpers/cart.ts', 'e2e/regression/cart/helpers/paths.ts'].sort());
});

test('lint: rejects fixed waits, CSS and XPath locators, skip markers, own routes, missing tags, a wrong title or header', () => {
  const body = (s) => (t) => t.replace('  await openCart(page);', `  await openCart(page);\n  ${s}`);
  hasRule(variant(body('await page.waitForTimeout(500);')), /waitForTimeout\(/);
  hasRule(variant(body('await new Promise((r) => setTimeout(r, 10));')), /setTimeout\(/);
  hasRule(variant(body("await page.locator('.cart').click();")), /\.locator\('/);
  hasRule(variant(body('await page.locator("//div").click();')), /\.locator\("/);
  hasRule(variant(body("await page.click('xpath=//button');")), /xpath=/);
  hasRule(variant(body("await page.$('.cart');")), /\$\(/);
  hasRule(variant((t) => t.replace("test('CART-004", "test.skip('CART-004")), /test\.skip/);
  hasRule(variant((t) => `${t}test.fixme(true, 'later');\n`), /test\.fixme/);
  hasRule(variant(body("await page.route('**/*', (r) => r.continue());")), /installs its own route \(\.route\(\)/);
  hasRule(variant(body("await page.context().setExtraHTTPHeaders({});\n  const o = { extraHTTPHeaders: {} };")), /extraHTTPHeaders/);
  hasRule(variant((t) => t.replace("{ tag: ['@regression', '@smoke'] }, ", '')), /@regression/);
  hasRule(variant((t) => t.replace(", '@smoke'", '')), /@smoke/);
  hasRule(variant((t) => t.replace("'CART-004 — Open the cart'", "'Open the cart'")), /title must start with CART-004 — /);
  hasRule(variant((t) => t.replace('// regression: CART-004 · source: live', '// regression: CART-004 · source: code')), /header/);
  hasRule(variant((t) => t.replace('// regression: CART-004 · source: live\n', '')), /header/);
  hasRule(variant((t) => `${t}\ntest('CART-004 — again', async () => {});\n`), /exactly one test/);
  hasRule(variant((t) => t.replace("test.use({ account: null });", "test.use({ account: 'shopper' });")), /account/);
  hasRule(variant((t) => t.replace('CART-004', 'CART-005').replace('CART-004', 'CART-005').replace(", '@smoke'", ''), { id: 'CART-005' }), /test\.use\(\{ account: 'shopper' \}\)/);
  hasRule(variant(body('test.describe.configure({ retries: 2 });')), /retries/);
  assert.deepEqual(variant((t) => t.replace('// regression: CART-004 · source: live', '// regression: CART-004 · source: live\n// regression-unobservable: CART-004 · a mail is sent — no inbox')), []);
});

test('lint: rejects a non-relative import, fetch, require, a dynamic import and a node network or process module', () => {
  const top = (s) => (t) => `${s}\n${t}`;
  const body = (s) => (t) => t.replace('  await openCart(page);', `  await openCart(page);\n  ${s}`);
  hasRule(variant(top("import { request } from '@playwright/test';")), /non-relative import @playwright\/test/);
  hasRule(variant(top("import http from 'node:http';")), /non-relative import node:http/);
  hasRule(variant(top("import 'some-package';")), /non-relative import some-package/);
  hasRule(variant((t) => t.replace("import { test, expect } from '../../fixtures';", "import { test, expect } from '@playwright/test';")), /test is not imported from a relative module/);
  hasRule(variant(body("await fetch('https://x.example');")), /fetch\(/);
  hasRule(variant(body("const fs = require('fs');")), /require\(/);
  hasRule(variant(body("await import('./helpers/cart');")), /import\(/);
  hasRule(variant(body('const v = process.env.SECRET;')), /process\.env/);
  hasRule(variant(body("const ws = new WebSocket('wss://x');")), /WebSocket\(/);
  hasRule(variant(body('const c = await browser.newContext();')), /newContext\(/);
  hasRule(variant(body('const x = new XMLHttpRequest();')), /XMLHttpRequest/);
});

test('lint: scans a relative helper module the spec imports and rejects a network call there', () => {
  const root = copyRoot();
  write(root, 'e2e/regression/cart/helpers/cart.ts', `${read(root, 'e2e/regression/cart/helpers/cart.ts')}\nexport const ping = () => fetch('https://x.example');\n`);
  const r = lint(root);
  const v = r.violations.find((x) => /fetch\(/.test(x.rule));
  assert.ok(v, JSON.stringify(r.violations));
  assert.equal(v.file, 'e2e/regression/cart/helpers/cart.ts');
  assert.ok(r.files.includes('e2e/regression/cart/helpers/cart.ts'));
  const fixtures = copyRoot();
  assert.deepEqual(lint(fixtures).violations, [], 'the fixtures module uses process.env and @playwright/test and is exempt');
});

test('lint: rejects retries set in a relative helper module', () => {
  const root = copyRoot();
  write(root, 'e2e/regression/cart/helpers/cart.ts', `${read(root, 'e2e/regression/cart/helpers/cart.ts')}\nexport const flaky = (t) => t.describe.configure({ retries: 2 });\n`);
  const r = lint(root);
  const v = r.violations.filter((x) => x.file === 'e2e/regression/cart/helpers/cart.ts' && RETRY_NEEDLES.includes(x.needle));
  assert.deepEqual(v.map((x) => x.needle).sort(), ['describe.configure(', 'retries'], JSON.stringify(r.violations));
});

test('lint: follows a second-level import, handles a cycle and rejects an unresolvable import', () => {
  const root = copyRoot();
  write(root, 'e2e/regression/cart/helpers/paths.ts', `${read(root, 'e2e/regression/cart/helpers/paths.ts')}\nexport const go = (page) => page.route('**/*', (r) => r.continue());\n`);
  const r = lint(root);
  assert.ok(r.violations.some((v) => v.file === 'e2e/regression/cart/helpers/paths.ts' && /own route/.test(v.rule)), JSON.stringify(r.violations));
  const missing = copyRoot();
  write(missing, 'e2e/regression/cart/helpers/paths.ts', `import { nope } from './absent';\n${read(missing, 'e2e/regression/cart/helpers/paths.ts')}`);
  const m = lint(missing);
  assert.ok(m.violations.some((v) => v.file === 'e2e/regression/cart/helpers/paths.ts' && /unresolvable import \.\/absent/.test(v.rule)), JSON.stringify(m.violations));
});

test('checkIntegration is unchanged after the move', () => {
  const root = copyRoot(RUN_FIX);
  const spec = path.join(root, 'e2e/regression/pdp.spec.ts');
  fs.writeFileSync(spec, fs.readFileSync(spec, 'utf8').replace("from '../fixtures'", "from '@playwright/test'"));
  const plan = { cases: [{ id: 'PDP-001', project: 'desktop-chrome', spec: 'e2e/regression/pdp.spec.ts' }] };
  const findings = checkIntegration(root, cfgOf(root), plan);
  assert.ok(findings.some((f) => f.file === 'e2e/regression/pdp.spec.ts' && f.reason === 'imports test from @playwright/test, not from the guarded fixtures'), JSON.stringify(findings));
  const clean = copyRoot(RUN_FIX);
  assert.deepEqual(checkIntegration(clean, cfgOf(clean), { cases: [{ id: 'CART-001', project: 'desktop-chrome', spec: 'e2e/regression/cart.spec.ts' }] }).filter((f) => !/testMatch/.test(f.reason)), []);
});
