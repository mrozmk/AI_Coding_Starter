// Unit tests of the inventory walk (.claude/lib/regression/walk.mjs) against a fake Playwright page:
// a scripted site keyed by path, a duck-typed document fed to the real extractFacts, and the real
// guard ledger in a temp run directory (the fake plays the guard's part: navigation and blocked
// events). No browser, no network.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

import { sanitize, sanitizeAria, sanitizeUrl, matchSubmit, walkGroup, extractFacts, submitUrl, validateRouteList } from '../regression/walk.mjs';
import { createLedger, reduceUrl } from '../regression/guard.mjs';

const BASE = 'https://shop.example.com';
const TEST_ID = 'walk-test-1';

// ---------------------------------------------------------------------------------------------
// Fakes

/** A duck-typed form element list entry. */
const el = (name, type, o = {}) => ({ name, type, disabled: false, checked: false, value: '', ...o });

/** A duck-typed document built from a scripted page. */
function fakeDocument(pageUrl, facts = {}) {
  const forms = (facts.forms ?? []).map((f) => ({
    ...f,
    requestSubmit() { throw new Error('requestSubmit must never be called'); },
  }));
  return {
    title: facts.title ?? '',
    baseURI: pageUrl,
    location: { hash: new URL(pageUrl).hash },
    links: (facts.links ?? []).map((href) => ({ href: new URL(href, pageUrl).href })),
    forms,
    querySelectorAll: (sel) => (sel === 'h1, h2, h3' ? (facts.headings ?? []).map((t) => ({ textContent: t })) : []),
  };
}

/**
 * A fake page over `site` (`{<path[?query][#hash]>: {status, final?, facts?, aria?, error?, blocked?}}`).
 * On production it records the guard's `navigation` event and keeps the first URL (a collapsed redirect).
 * An entry with `sameDocument: true` is a hash-only change as Playwright reports it: no request (no
 * guard event), `goto` returns null, the page lands on the client-side route (`final`, else the URL).
 */
function fakePage(site, manifest) {
  const ledger = createLedger(manifest.run_dir, { nonce: manifest.nonce });
  const production = manifest.kind === 'production';
  let cur = { url: 'about:blank', s: {} };
  const page = {
    calls: [],
    async goto(url) {
      page.calls.push(url);
      const u = new URL(url);
      const s = site[`${u.pathname}${u.search}${u.hash}`] ?? site[`${u.pathname}${u.hash}`] ?? { status: 404 };
      if (s.error) throw new Error(s.error);
      if (s.blocked) ledger.record({ kind: 'blocked', reason: s.blocked, method: 'GET', url, op: null, test: TEST_ID });
      const finalUrl = new URL(s.final ?? `${u.pathname}${u.search}${u.hash}`, url).href;
      if (s.sameDocument) { cur = { url: finalUrl, s }; return null; }
      if (production) ledger.record({ kind: 'navigation', url, final: reduceUrl(finalUrl), status: s.status, hops: s.final ? 2 : 1, test: TEST_ID });
      cur = { url: production ? url : finalUrl, s };
      return { status: () => s.status };
    },
    url: () => cur.url,
    async evaluate(fn) {
      // `blockedLate`: the page's own request the guard blocks while the walk reads the facts.
      if (cur.s.blockedLate) ledger.record({ kind: 'blocked', reason: cur.s.blockedLate, method: 'GET', url: cur.url, op: null, test: TEST_ID });
      return fn(fakeDocument(cur.url, cur.s.facts));
    },
    locator: () => ({ ariaSnapshot: async () => cur.s.aria ?? '' }),
    async waitForLoadState() {},
  };
  return page;
}

function walkManifest({ kind = 'test', routes, redact = [], caps = { aria_chars: 8000, links: 200 } }) {
  const runDir = fs.mkdtempSync(path.join(os.tmpdir(), 'regression-walk-'));
  const group = { key: 'WALK1', account: null, routes: routes.map((r) => r.route) };
  return {
    manifest: { run_id: 'w', nonce: 'n1', kind, base_url: BASE, run_dir: runDir, walk: { groups: [group], routes, redact, caps, timeout_ms: 60000 } },
    group,
  };
}

async function walk(site, opts) {
  const { manifest, group } = walkManifest(opts);
  const page = fakePage(site, manifest);
  const result = await walkGroup({ page, manifest, group, testInfo: { testId: TEST_ID } });
  const file = path.join(manifest.run_dir, 'walk/WALK1.json');
  return { result, page, manifest, text: fs.readFileSync(file, 'utf8'), byRoute: (r) => result.routes.find((x) => x.route === r) };
}

const searchForm = (o = {}) => ({
  name: 'search', action: '/search', method: 'get',
  elements: [el('q', 'search', { value: 'prefilled-secret' }), el('go', 'submit')],
  ...o,
});
const SEARCH_ENTRY = { form: 'search', action: '/search', method: 'GET', inputs: { q: 'shoes' } };

// ---------------------------------------------------------------------------------------------
// Sanitizing

test('sanitize drops query strings and fragments and applies redact patterns', () => {
  assert.equal(sanitize('see https://shop.example.com/p/1?ref=mail#top now'), 'see https://shop.example.com/p/1 now');
  assert.equal(sanitize('link /search?q=private and /cart#x'), 'link /search and /cart');
  assert.equal(sanitize('licence lic-12345 for /orders/lic-9', ['lic-[0-9]+']), 'licence ‹redacted› for /orders/‹redacted›');
  assert.deepEqual(sanitizeUrl('/p/1?x=1'), { url: '/p/1', redacted: true });
  assert.deepEqual(sanitizeUrl('/#/product/7'), { url: '/#/product/7', redacted: false });
  assert.deepEqual(sanitizeUrl('/#/search?q=a'), { url: '/#/search', redacted: true });
  assert.deepEqual(sanitizeUrl('/orders/lic-77', ['lic-[0-9]+']), { url: '/orders/‹redacted›', redacted: true });
});

test('sanitize drops textbox values from the aria snapshot', () => {
  const yaml = ['- heading "Sign in" [level=1]', '- textbox "Email": a@b.example', '- searchbox: shoes', '- combobox "Size": XL', '- spinbutton "Qty": "2"', '- slider "Price": 40', '- button "Go"'].join('\n');
  assert.equal(sanitizeAria(yaml), ['- heading "Sign in" [level=1]', '- textbox "Email"', '- searchbox', '- combobox "Size"', '- spinbutton "Qty"', '- slider "Price"', '- button "Go"'].join('\n'));
});

// ---------------------------------------------------------------------------------------------
// The submit contract

test('extractFacts builds the entry list of a form with hidden, disabled, duplicate and relative-action controls', () => {
  const form = {
    name: 'filter', action: 'list', method: 'GET',
    elements: [
      el('tag', 'checkbox', { checked: true, value: 'a' }), el('tag', 'checkbox', { checked: true, value: 'b' }),
      el('tag', 'checkbox', { checked: false, value: 'c' }), el('csrf', 'hidden', { value: 'tok' }),
      el('off', 'text', { disabled: true, value: 'x' }), el('sort', 'select-one', { options: [{ value: 'price', selected: true }, { value: 'name', selected: false }] }),
      el('go', 'submit'), el('', 'text', { value: 'unnamed' }),
    ],
  };
  const doc = fakeDocument(`${BASE}/shop/`, { forms: [form] });
  const [f] = extractFacts(doc).forms;
  assert.equal(f.action, `${BASE}/shop/list`);
  assert.deepEqual(f.entries, [['tag', 'a'], ['tag', 'b'], ['csrf', 'tok'], ['sort', 'price']]);
  const entry = { form: 'filter', action: '/shop/list', method: 'GET', inputs: { tag: 'a', csrf: 'x', sort: 'price' } };
  assert.equal(matchSubmit(entry, f, BASE), false, 'the duplicate tag control is a second entry the allow-list does not name');
  const plain = { ...form, elements: form.elements.filter((e) => e.name !== 'tag') };
  const [g] = extractFacts(fakeDocument(`${BASE}/shop/`, { forms: [plain] })).forms;
  const ok = { form: 'filter', action: '/shop/list', method: 'GET', inputs: { csrf: 'x', sort: 'name' } };
  assert.equal(matchSubmit(ok, g, BASE), true);
  assert.equal(submitUrl(BASE, ok), `${BASE}/shop/list?csrf=x&sort=name`);
});

test('walkGroup submits only a form matching its submit entry and skips a differing one', async () => {
  const site = {
    '/': { status: 200, facts: { title: 'Home', forms: [searchForm(), { name: 'news', action: '/subscribe', method: 'get', elements: [el('email', 'email')] }] } },
    '/search?q=shoes': { status: 200, facts: { title: 'Results', headings: ['Results'] } },
  };
  const routes = [{ route: '/', source: 'app/home.tsx', sample: '/', submit: [SEARCH_ENTRY, { form: 'news', action: '/subscribe', method: 'GET', inputs: { email: 'a', name: 'b' } }, { form: 'gone', action: '/x', method: 'GET', inputs: {} }] }];
  const { byRoute, page } = await walk(site, { routes });
  const r = byRoute('/');
  assert.equal(r.outcome, 'ok');
  assert.deepEqual(r.submits.map((s) => [s.form, s.outcome]), [['search', 'submitted'], ['news', 'skipped'], ['gone', 'skipped']]);
  assert.deepEqual(page.calls, [`${BASE}/`, `${BASE}/search?q=shoes`], 'only the matching form is submitted');
  const differs = await walk({ '/': { status: 200, facts: { forms: [searchForm({ action: '/other' })] } } }, { routes: [{ route: '/', source: 's', sample: '/', submit: [SEARCH_ENTRY] }] });
  assert.deepEqual(differs.byRoute('/').submits, [{ form: 'search', outcome: 'skipped', reason: 'form differs' }]);
  assert.equal(differs.page.calls.length, 1, 'a differing form is never submitted');
});

test('walkGroup skips a form with an extra hidden control or an action on another allowed origin', async () => {
  const hidden = searchForm({ elements: [el('q', 'search'), el('csrf', 'hidden', { value: 't' })] });
  const other = searchForm({ action: 'https://cdn.shop.example.com/search' });
  for (const form of [hidden, other]) {
    const w = await walk({ '/': { status: 200, facts: { forms: [form] } } }, { routes: [{ route: '/', source: 's', sample: '/', submit: [SEARCH_ENTRY] }] });
    assert.deepEqual(w.byRoute('/').submits, [{ form: 'search', outcome: 'skipped', reason: 'form differs' }]);
    assert.equal(w.page.calls.length, 1);
  }
});

test('walkGroup submits by a native GET navigation and never calls requestSubmit', async () => {
  const site = { '/': { status: 200, facts: { forms: [searchForm()] } }, '/search?q=shoes': { status: 200, facts: { title: 'Results' } } };
  const w = await walk(site, { routes: [{ route: '/', source: 's', sample: '/', submit: [SEARCH_ENTRY] }] });
  assert.deepEqual(w.page.calls, [`${BASE}/`, `${BASE}/search?q=shoes`]);
  assert.equal(w.byRoute('/').submits[0].outcome, 'submitted', 'the fake form throws on requestSubmit — it was never called');
});

test('walkGroup records a failed submit when the page loads 200 and the allow-listed GET answers 500', async () => {
  const site = { '/': { status: 200, facts: { forms: [searchForm()] } }, '/search?q=shoes': { status: 500, facts: { title: 'Error' } } };
  const w = await walk(site, { routes: [{ route: '/', source: 's', sample: '/', submit: [SEARCH_ENTRY] }] });
  assert.equal(w.byRoute('/').outcome, 'ok');
  assert.equal(w.byRoute('/').submits[0].outcome, 'failed');
  assert.equal(w.byRoute('/').submits[0].status, 500);
});

// ---------------------------------------------------------------------------------------------
// Outcomes

test('walkGroup records an observation per route and marks the group done', async () => {
  const site = {
    '/': { status: 200, facts: { title: 'Home', headings: ['Welcome'], links: ['/cart', 'https://other.example.net/x'] }, aria: '- heading "Welcome" [level=1]' },
    '/cart': { status: 200, facts: { title: 'Cart', headings: ['Your cart'] } },
  };
  const w = await walk(site, { routes: [{ route: '/', source: 'app/home.tsx', sample: '/' }, { route: '/cart', source: 'app/cart.tsx', sample: '/cart' }] });
  assert.equal(w.result.done, true);
  assert.equal(JSON.parse(w.text).done, true);
  assert.deepEqual(w.result.routes.map((r) => [r.route, r.outcome]), [['/', 'ok'], ['/cart', 'ok']]);
  const home = w.byRoute('/');
  assert.deepEqual({ status: home.status, final: home.final, title: home.title, headings: home.headings, links: home.links }, { status: 200, final: '/', title: 'Home', headings: ['Welcome'], links: ['/cart'] });
  assert.equal(home.aria, '- heading "Welcome" [level=1]');
});

test('walkGroup resolves a parametric route from an earlier same-host link', async () => {
  const site = { '/': { status: 200, facts: { links: ['https://other.example.net/p/9', '/p/42?ref=x', '/about'] } }, '/p/42': { status: 200, facts: { title: 'Product' } } };
  const routes = [{ route: '/p/:id', source: 'app/product.tsx', match: '^/p/[0-9]+$' }, { route: '/', source: 'app/home.tsx', sample: '/' }];
  const w = await walk(site, { routes });
  assert.deepEqual(w.result.routes.map((r) => r.route), ['/', '/p/:id'], 'static routes first');
  assert.equal(w.byRoute('/p/:id').sample, '/p/42');
  assert.equal(w.byRoute('/p/:id').outcome, 'ok');
});

test('walkGroup records no sample for a parametric route with no matching link', async () => {
  const w = await walk({ '/': { status: 200, facts: { links: ['/about'] } } }, { routes: [{ route: '/', source: 's', sample: '/' }, { route: '/p/:id', source: 's', match: '^/p/[0-9]+$' }] });
  assert.deepEqual({ outcome: w.byRoute('/p/:id').outcome, sample: w.byRoute('/p/:id').sample }, { outcome: 'no-sample', sample: null });
  assert.equal(w.page.calls.length, 1);
});

test('walkGroup records a failed route with its status and a guard-blocked route with the guard reason', async () => {
  const site = { '/checkout': { status: 500 }, '/promo': { status: 200, blocked: 'foreign host' }, '/broken': { error: 'net::ERR_ABORTED' } };
  const w = await walk(site, { routes: ['/checkout', '/promo', '/broken'].map((r) => ({ route: r, source: 's', sample: r })) });
  assert.deepEqual([w.byRoute('/checkout').outcome, w.byRoute('/checkout').reason, w.byRoute('/checkout').status], ['failed', 'status 500', 500]);
  assert.deepEqual([w.byRoute('/promo').outcome, w.byRoute('/promo').reason], ['failed', 'guard: foreign host']);
  assert.deepEqual([w.byRoute('/broken').outcome, w.byRoute('/broken').reason], ['failed', 'navigation error']);
});

test("walkGroup records a redirect to another route from the guard's final hop on production", async () => {
  const site = { '/account': { status: 200, final: '/login?next=%2Faccount' }, '/cart': { status: 200 } };
  const w = await walk(site, { kind: 'production', routes: [{ route: '/account', source: 's', sample: '/account' }, { route: '/cart', source: 's', sample: '/cart' }] });
  assert.deepEqual([w.byRoute('/account').outcome, w.byRoute('/account').reason, w.byRoute('/account').final], ['redirected', 'redirected to /login', '/login']);
  assert.equal(w.byRoute('/cart').outcome, 'ok', 'a direct 200 on production is identified by its own navigation event');
  const { manifest, group } = walkManifest({ kind: 'production', routes: [{ route: '/cart', source: 's', sample: '/cart' }] });
  const silent = fakePage({ '/cart': { status: 200 } }, { ...manifest, kind: 'test' });
  const r = await walkGroup({ page: silent, manifest, group, testInfo: { testId: TEST_ID } });
  assert.equal(r.routes[0].outcome, 'unverified', 'production without a guard final hop proves nothing');
});

test('walkGroup tells two hash routes with the same pathname apart', async () => {
  const site = { '/#/cart': { status: 200 }, '/#/account': { status: 200, final: '/#/login' } };
  const w = await walk(site, { routes: [{ route: '#/cart', source: 's', sample: '/#/cart' }, { route: '#/account', source: 's', sample: '/#/account' }] });
  assert.equal(w.byRoute('#/cart').outcome, 'ok');
  assert.deepEqual([w.byRoute('#/account').outcome, w.byRoute('#/account').reason], ['redirected', 'redirected to /#/login']);
});

test('walkGroup identifies hash routes on production from the page when the change is same-document', async () => {
  const site = { '/#/': { status: 200 }, '/#/cart': { status: 200, sameDocument: true }, '/#/account': { status: 200, sameDocument: true, final: '/#/login' } };
  const routes = ['#/', '#/cart', '#/account'].map((r) => ({ route: r, source: 's', sample: `/${r}` }));
  const w = await walk(site, { kind: 'production', routes });
  assert.deepEqual(routes.map((r) => w.byRoute(r.route).outcome), ['ok', 'ok', 'redirected'], w.text);
  assert.equal(w.byRoute('#/account').reason, 'redirected to /#/login');
});

test('walkGroup fails a route whose request the guard blocks while the facts are read', async () => {
  const site = { '/promo': { status: 200, blockedLate: 'foreign host' } };
  const w = await walk(site, { routes: [{ route: '/promo', source: 's', sample: '/promo' }] });
  assert.deepEqual([w.byRoute('/promo').outcome, w.byRoute('/promo').reason], ['failed', 'guard: foreign host']);
});

test('sanitizeAria cuts every link url at its query or fragment', () => {
  const yaml = ['- link "Skip":', '  - /url: "#main"', '- link "Docs":', '  - /url: guide#install', '- link "Page 2":', '  - /url: ?page', '- link "Home":', '  - /url: /'].join('\n');
  assert.equal(sanitizeAria(yaml), ['- link "Skip":', '  - /url: ""', '- link "Docs":', '  - /url: guide', '- link "Page 2":', '  - /url: ', '- link "Home":', '  - /url: /'].join('\n'));
});

test('sanitize drops the query of a relative href in the aria snapshot and in free text', () => {
  assert.equal(sanitize('- link "Next":\n  - /url: ?page=2&token=abc'), '- link "Next":\n  - /url: ');
  assert.equal(sanitize('see search?q=secret and p/1?session=x'), 'see search and p/1');
  assert.equal(sanitize('[href="?token=abc"] stays a question? yes'), '[href=""] stays a question? yes');
});

test('walkGroup never writes a form value or a query string', async () => {
  const site = {
    '/': {
      status: 200,
      facts: { title: 'Home for token-abc', links: ['/p/1?session=xyz', '/cart#frag'], forms: [searchForm({ elements: [el('q', 'search', { value: 'prefilled-secret' }), el('csrf', 'hidden', { value: 'csrf-secret' })] })] },
      aria: '- searchbox "Search": prefilled-secret\n- link "Item" [href="/p/1?session=xyz"]',
    },
    '/search?q=shoes&csrf=fixed': { status: 200, facts: { title: 'Results for shoes' } },
  };
  const entry = { form: 'search', action: '/search', method: 'GET', inputs: { q: 'shoes', csrf: 'fixed' } };
  const w = await walk(site, { routes: [{ route: '/', source: 's', sample: '/?utm=mail', submit: [entry] }], redact: ['token-[a-z]+', 'shoes'] });
  assert.equal(w.byRoute('/').submits[0].outcome, 'submitted');
  for (const secret of ['prefilled-secret', 'csrf-secret', 'session=', 'xyz', 'utm', 'token-abc', 'shoes', 'fixed', '?']) {
    assert.equal(w.text.includes(secret), false, `${secret} leaked into the observation:\n${w.text}`);
  }
  assert.deepEqual(w.byRoute('/').forms[0].fields, [{ name: 'q', type: 'search' }, { name: 'csrf', type: 'hidden' }]);
});

test('walkGroup caps the aria snapshot and the link list', async () => {
  const links = Array.from({ length: 10 }, (_, i) => `/l/${i}`);
  const w = await walk({ '/': { status: 200, facts: { links }, aria: 'x'.repeat(200) } }, { routes: [{ route: '/', source: 's', sample: '/' }], caps: { aria_chars: 50, links: 3 } });
  const r = w.byRoute('/');
  assert.deepEqual(r.links, ['/l/0', '/l/1', '/l/2']);
  assert.ok(r.aria.startsWith('x'.repeat(50)));
  assert.ok(r.aria.length < 200);
  assert.match(r.aria, /capped at 50 characters/);
});

test('walkGroup marks every route not walked once the run is stopped', async () => {
  const { manifest, group } = walkManifest({ routes: [{ route: '/', source: 's', sample: '/' }, { route: '/cart', source: 's', sample: '/cart' }] });
  createLedger(manifest.run_dir, { nonce: manifest.nonce }).stop('status 429');
  const r = await walkGroup({ page: fakePage({}, manifest), manifest, group, testInfo: { testId: TEST_ID } });
  assert.deepEqual(r.routes.map((x) => x.outcome), ['not-walked', 'not-walked']);
});

test('validateRouteList refuses a non-GET submit, a duplicate route and scenarios on a staged entry', () => {
  const errors = validateRouteList({ schema: 1, routes: [
    { route: '/', source: 's', submit: [{ form: 'login', action: '/login', method: 'POST', inputs: {} }] },
    { route: '/', source: 's' },
    { route: '/cart', source: 's', scenarios: ['CART-001'] },
  ] }, { staged: true });
  assert.ok(errors.includes('submit login: only GET forms may be allow-listed'), errors.join('\n'));
  assert.ok(errors.includes('route /: duplicate route'));
  assert.ok(errors.includes('route /cart: a staged entry carries no scenarios or exclusion'));
  assert.deepEqual(validateRouteList({ schema: 1, routes: [{ route: '/cart', source: 's', sample: '/cart', scenarios: ['CART-001'] }] }), []);
  assert.ok(validateRouteList({ schema: 1, routes: [{ route: '/p', source: 's', sample: '/p?x=1' }] }).some((e) => /committed sample carries no query/.test(e)));
});
