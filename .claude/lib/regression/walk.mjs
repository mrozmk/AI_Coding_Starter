// The inventory walk of an existing app: one Playwright test per account group (`WALK<k>`, the
// stub `_walk.spec.ts` registers them) visits every staged route of its group on desktop, behind
// the guard the fixture installed, and records what the live app shows — status, final route,
// title, headings, a capped ARIA snapshot, same-host link paths and form shapes. It never installs
// a route, never calls a form handler and never persists a form value, a query string or a match of
// the environment's `redact` patterns. Allow-listed GET forms are submitted by a native GET
// navigation built from the route list. Also the route list grammar (`validateRouteList`), shared
// by run.mjs walk and inventory.mjs. Library only (no CLI; run.mjs walk drives it).
// Node builtins only — ships to every downstream. Contract: .agents/reference/regression.md §14.

import fs from 'node:fs';
import path from 'node:path';
import { reduceUrl, createLedger } from './guard.mjs';
import { NEED_KEY, isObject, isFilled, isRegex } from './config.mjs';

const REDACTED = '‹redacted›';
const VALUE_ROLES = ['textbox', 'searchbox', 'combobox', 'spinbutton', 'slider'];

const compileRedact = (list) => (list ?? []).map((r) => (r instanceof RegExp ? new RegExp(r.source, 'g') : new RegExp(r, 'g')));
const applyRedact = (text, res) => res.reduce((t, r) => t.replace(new RegExp(r.source, 'g'), REDACTED), text);

// ---------------------------------------------------------------------------------------------
// Sanitizing — everything persisted passes here

/**
 * Free text: absolute URLs reduced (no query, no fragment), a path's query and fragment dropped, a
 * relative href's `?key=value` query dropped (`?page=2`, `search?q=x`), redact matches replaced.
 */
export function sanitize(text, redactRes = []) {
  if (text === null || text === undefined) return text;
  const res = compileRedact(redactRes);
  const s = String(text)
    .replace(/https?:\/\/[^\s"'<>]+/g, (u) => reduceUrl(u))
    .replace(/(^|[\s"'(=])(\/[^\s"'<>?#]*)[?#][^\s"'<>)]*/g, (m, pre, p) => `${pre}${p}`)
    .replace(/(^|[\s"'(=:])([^\s"'<>?#]*)\?[^\s"'<>)=?#]+=[^\s"'<>)]*/g, (m, pre, p) => `${pre}${p}`);
  return applyRedact(s, res);
}

/**
 * An ARIA snapshot with the value part of every text-entry line removed (`- textbox "Email": a@b` →
 * `- textbox "Email"`) and every link's `/url:` value cut at its query or fragment (relative,
 * `#main` or `page#x` alike), then sanitized.
 */
export function sanitizeAria(yaml, redactRes = []) {
  if (typeof yaml !== 'string') return '';
  const re = new RegExp(`^(\\s*- (?:${VALUE_ROLES.join('|')})(?: "(?:[^"\\\\]|\\\\.)*")?(?: \\[[^\\]]*\\])*)\\s*:.*$`, 'gm');
  const urls = /^(\s*- \/url: )(.*)$/gm;
  const cut = (m, pre, v) => {
    const quoted = /^"(.*)"$/.exec(v);
    const bare = (quoted ? quoted[1] : v).split(/[?#]/)[0];
    return `${pre}${quoted ? `"${bare}"` : bare}`;
  };
  return sanitize(yaml.replace(re, '$1').replace(urls, cut), redactRes);
}

/**
 * A route path (absolute URL or `/path#hash`) as persisted: `pathname` plus a fragment route with
 * its own query dropped. `redacted` when a query was dropped or a redact pattern matched.
 */
export function sanitizeUrl(url, redactRes = []) {
  let u;
  try { u = new URL(url, 'http://walk.invalid'); } catch { return { url: sanitize(String(url).split(/[?#]/)[0], redactRes), redacted: true }; }
  const [hashPath, hashQuery] = u.hash.split('?');
  const raw = `${u.pathname}${hashPath}`;
  const clean = applyRedact(raw, compileRedact(redactRes));
  return { url: clean, redacted: u.search !== '' || hashQuery !== undefined || clean !== raw };
}

const identity = (url) => { try { const u = new URL(url, 'http://walk.invalid'); return `${u.pathname}${u.hash}`; } catch { return String(url); } };

// ---------------------------------------------------------------------------------------------
// Route list and submit contract

/** Problems of a route list (`.agents/regression/routes.json` or a staged one), as strings. */
export function validateRouteList(doc, { staged = false } = {}) {
  if (!isObject(doc)) return ['route list: must be a JSON object'];
  const errors = [];
  if (doc.schema !== 1) errors.push('route list: schema must be 1');
  if (!Array.isArray(doc.routes)) return [...errors, 'route list: routes must be an array'];
  const seen = new Set();
  doc.routes.forEach((e, i) => {
    const at = isObject(e) && isFilled(e.route) ? `route ${e.route}` : `routes[${i}]`;
    if (!isObject(e)) { errors.push(`${at}: must be an object`); return; }
    if (!isFilled(e.route)) errors.push(`${at}: route must be a non-empty string`);
    else if (seen.has(e.route)) errors.push(`${at}: duplicate route`);
    else seen.add(e.route);
    if (!isFilled(e.source)) errors.push(`${at}: source must be a non-empty string`);
    if ('sample' in e) {
      if (typeof e.sample !== 'string' || !e.sample.startsWith('/')) errors.push(`${at}: sample must be a path starting with /`);
      else if (!staged && e.sample.includes('?')) errors.push(`${at}: a committed sample carries no query string`);
    }
    if ('match' in e && !isRegex(e.match)) errors.push(`${at}: match must be a regex that compiles`);
    if ('account' in e && !(typeof e.account === 'string' && NEED_KEY.test(e.account))) errors.push(`${at}: account must match ${NEED_KEY.source}`);
    if ('submit' in e) {
      if (!Array.isArray(e.submit)) errors.push(`${at}: submit must be an array`);
      else for (const s of e.submit) {
        const form = isObject(s) && isFilled(s.form) ? s.form : '?';
        if (!isObject(s) || !isFilled(s.form)) { errors.push(`${at}: submit entries need a form name`); continue; }
        if (s.method !== 'GET') { errors.push(`submit ${form}: only GET forms may be allow-listed`); continue; }
        if (typeof s.action !== 'string' || !s.action.startsWith('/') || /[?#]/.test(s.action)) errors.push(`submit ${form}: action must be a path starting with / (no query)`);
        if (!isObject(s.inputs) || Object.values(s.inputs).some((v) => typeof v !== 'string')) errors.push(`submit ${form}: inputs must be an object of strings`);
      }
    }
    if (staged) {
      if ('scenarios' in e || 'exclusion' in e) errors.push(`${at}: a staged entry carries no scenarios or exclusion`);
    } else {
      if ('scenarios' in e && !(Array.isArray(e.scenarios) && e.scenarios.every(isFilled))) errors.push(`${at}: scenarios must be an array of ids`);
      if ('exclusion' in e && !isFilled(e.exclusion)) errors.push(`${at}: exclusion must be a non-empty string`);
    }
  });
  return errors;
}

/** The route keys whose `sample` carries a query or matches a redact pattern — never committed. */
export function redactedSamples(routes, redactRes = []) {
  return (routes ?? []).filter((r) => typeof r.sample === 'string' && sanitizeUrl(r.sample, redactRes).redacted).map((r) => r.route);
}

/**
 * Whether a deployed form is exactly the allow-listed one: same name, a GET form and entry, the
 * action on the base origin at the entry's path, and the form's complete entry list (every
 * successful control, hidden and prefilled included, duplicates kept) equal to the entry's inputs.
 */
export function matchSubmit(entry, form, baseOrigin) {
  if (!isObject(entry) || !isObject(form)) return false;
  if (form.name !== entry.form) return false;
  if (String(form.method ?? '').toUpperCase() !== 'GET' || entry.method !== 'GET') return false;
  let action;
  try { action = new URL(form.action); } catch { return false; }
  if (action.origin !== baseOrigin || action.pathname !== entry.action) return false;
  const names = (form.entries ?? []).map(([n]) => n).sort();
  const keys = Object.keys(entry.inputs ?? {}).sort();
  return names.length === keys.length && names.every((n, i) => n === keys[i]);
}

/** The native GET the walk performs for an allow-listed form (never `requestSubmit()`). */
export const submitUrl = (baseOrigin, entry) => `${baseOrigin}${entry.action}?${new URLSearchParams(Object.entries(entry.inputs ?? {})).toString()}`;

// ---------------------------------------------------------------------------------------------
// DOM facts — serialized into the page by page.evaluate: self-contained, no closure

/**
 * Title, h1–h3 text, link hrefs, the location hash and every form's shape and entry list. The
 * entry list follows the browser's successful-control rules; it stays in memory (matchSubmit) and
 * is never persisted.
 */
export function extractFacts(doc = document) {
  const SKIP = ['submit', 'button', 'reset', 'image', 'fieldset', 'output', 'object'];
  const forms = Array.from(doc.forms ?? []).map((f) => {
    const fields = [];
    const entries = [];
    for (const el of Array.from(f.elements ?? [])) {
      const type = String(el.type ?? '').toLowerCase();
      if (!el.name || SKIP.includes(type)) continue;
      fields.push({ name: el.name, type });
      if (el.disabled) continue;
      if ((type === 'checkbox' || type === 'radio') && !el.checked) continue;
      if (type.startsWith('select')) {
        for (const o of Array.from(el.options ?? [])) if (o.selected) entries.push([el.name, String(o.value ?? '')]);
        continue;
      }
      entries.push([el.name, type === 'checkbox' || type === 'radio' ? String(el.value ?? 'on') : String(el.value ?? '')]);
    }
    let action;
    try { action = new URL(f.getAttribute?.('action') ?? f.action ?? '', doc.baseURI).href; } catch { action = String(f.action ?? ''); }
    return { name: f.getAttribute?.('name') ?? f.name ?? '', action, method: String(f.getAttribute?.('method') ?? f.method ?? 'get').toUpperCase(), fields, entries };
  });
  return {
    title: String(doc.title ?? ''),
    hash: String(doc.location?.hash ?? ''),
    headings: Array.from(doc.querySelectorAll?.('h1, h2, h3') ?? []).map((h) => String(h.textContent ?? '').trim()).filter(Boolean),
    links: Array.from(doc.links ?? []).map((a) => String(a.href ?? '')).filter(Boolean),
    forms,
  };
}

// ---------------------------------------------------------------------------------------------
// The walk of one group

const RANK = { ok: 4, redirected: 3, unverified: 3, failed: 2, 'no-sample': 1, 'not-walked': 1 };
/** The better of two outcomes for one route over the groups (apply's "best outcome"). */
export const betterOutcome = (a, b) => ((RANK[b] ?? 0) > (RANK[a] ?? 0) ? b : a);

function writeGroup(runDir, result) {
  const dir = path.join(runDir, 'walk');
  fs.mkdirSync(dir, { recursive: true });
  const file = path.join(dir, `${result.key}.json`);
  const tmp = `${file}.tmp-${process.pid}`;
  fs.writeFileSync(tmp, `${JSON.stringify(result, null, 2)}\n`);
  fs.renameSync(tmp, file);
}

const cap = (s, n) => (s.length > n ? `${s.slice(0, n)}\n… (capped at ${n} characters)` : s);

/**
 * Visit every route of `group` and write `<run_dir>/walk/<key>.json` (`done: false` first, so an
 * aborted walk stays not done). Static routes first, then parametric ones, whose sample is the
 * route's own or the first same-host link path seen earlier that matches its `match`.
 */
export async function walkGroup({ page, manifest, group, testInfo }) {
  const w = manifest.walk;
  const redact = w.redact ?? [];
  const caps = { aria_chars: w.caps?.aria_chars ?? 8000, links: w.caps?.links ?? 200 };
  const production = (manifest.kind ?? 'production') === 'production';
  const base = new URL(manifest.base_url);
  const testId = testInfo?.testId ?? null;
  const ledger = createLedger(manifest.run_dir, { nonce: manifest.nonce ?? null });
  const byKey = new Map((w.routes ?? []).map((r) => [r.route, r]));
  const entries = group.routes.map((k) => byKey.get(k)).filter(Boolean);
  const ordered = [...entries.filter((r) => !r.match), ...entries.filter((r) => r.match)];
  const result = { key: group.key, account: group.account ?? null, done: false, routes: [] };
  writeGroup(manifest.run_dir, result);

  const seenLinks = [];
  const blockedNow = () => ledger.blockedFor(testId);
  const safe = (t) => sanitize(t, redact);

  /** One guarded navigation and what it shows; never throws. */
  const visit = async (url) => {
    const mark = ledger.events().length;
    const blockedBefore = blockedNow().length;
    let status = null;
    let error = null;
    let resp = null;
    try {
      resp = await page.goto(url);
      status = resp && typeof resp.status === 'function' ? resp.status() : null;
      if (typeof page.waitForLoadState === 'function') await page.waitForLoadState();
    } catch (err) { error = err; }
    let facts = { title: '', hash: '', headings: [], links: [], forms: [] };
    let aria = '';
    if (!error) {
      try { facts = await page.evaluate(extractFacts); } catch { /* keep the empty facts */ }
      try { aria = await page.locator('body').ariaSnapshot({ timeout: 5000 }); } catch { aria = ''; }
    }
    // Read after the facts: a request the page makes while they are collected is still this visit's.
    const blocked = blockedNow().slice(blockedBefore);
    let observed = null;
    if (production) {
      const nav = ledger.events().slice(mark).find((e) => e.kind === 'navigation' && e.test === testId);
      if (nav) observed = `${identity(nav.final).split('#')[0]}${facts.hash}`;
      // A hash-only change is a same-document navigation: no request, so no guard hop and no
      // collapsed redirect to hide — `page.goto` returns null and the page's own URL is the truth.
      else if (!error && resp === null) observed = identity(page.url());
    } else {
      observed = identity(page.url());
    }
    return { status, error, blocked, facts, aria, observed };
  };
  const shape = (v) => ({
    status: v.status,
    final: v.observed === null ? null : sanitizeUrl(v.observed, redact).url,
    title: safe(v.facts.title),
    headings: v.facts.headings.map(safe),
    aria: cap(sanitizeAria(v.aria, redact), caps.aria_chars),
  });

  for (const entry of ordered) {
    const rec = { route: entry.route, outcome: null, reason: null, sample: null };
    if (ledger.stopped()) { rec.outcome = 'not-walked'; rec.reason = 'the run is stopped'; result.routes.push(rec); continue; }
    let sample = entry.sample ?? null;
    if (!sample && entry.match) {
      const re = new RegExp(entry.match);
      sample = seenLinks.find((p) => re.test(p)) ?? null;
    }
    if (!sample) { rec.outcome = 'no-sample'; rec.reason = 'no sample'; result.routes.push(rec); continue; }
    rec.sample = sanitizeUrl(sample, redact).url;
    const requested = identity(sample);
    const v = await visit(new URL(sample, base).href);
    for (const href of v.facts.links) {
      let u;
      try { u = new URL(href, base); } catch { continue; }
      if (u.hostname !== base.hostname) continue;
      const p = `${u.pathname}${u.hash}`;
      if (!seenLinks.includes(p)) seenLinks.push(p);
    }
    Object.assign(rec, shape(v));
    rec.links = [...new Set(v.facts.links.map((h) => { try { const u = new URL(h, base); return u.hostname === base.hostname ? sanitizeUrl(u.href, redact).url : null; } catch { return null; } }).filter(Boolean))].slice(0, caps.links);
    rec.forms = v.facts.forms.map((f) => ({ name: safe(f.name), action: sanitizeUrl(f.action, redact).url, method: f.method, fields: f.fields.map((x) => ({ name: safe(x.name), type: x.type })) }));
    rec.submits = [];
    if (v.error) { rec.outcome = 'failed'; rec.reason = 'navigation error'; }
    else if (v.blocked.length) { rec.outcome = 'failed'; rec.reason = `guard: ${v.blocked[0].reason}`; }
    else if (v.status !== null && v.status >= 400) { rec.outcome = 'failed'; rec.reason = `status ${v.status}`; }
    else if (v.observed === null) { rec.outcome = 'unverified'; rec.reason = 'no guard final hop for this visit'; }
    else if (v.observed !== requested && !(entry.match && new RegExp(entry.match).test(v.observed))) {
      rec.outcome = 'redirected';
      rec.reason = `redirected to ${sanitizeUrl(v.observed, redact).url}`;
    } else rec.outcome = 'ok';

    if (rec.outcome === 'ok') {
      for (const s of entry.submit ?? []) {
        const form = v.facts.forms.find((f) => f.name === s.form);
        if (!form || !matchSubmit(s, form, base.origin)) { rec.submits.push({ form: s.form, outcome: 'skipped', reason: 'form differs' }); continue; }
        if (ledger.stopped()) { rec.submits.push({ form: s.form, outcome: 'skipped', reason: 'the run is stopped' }); continue; }
        const sv = await visit(submitUrl(base.origin, s));
        const failed = Boolean(sv.error) || sv.blocked.length > 0 || (sv.status !== null && sv.status >= 400);
        rec.submits.push({ form: s.form, outcome: failed ? 'failed' : 'submitted', ...shape(sv) });
      }
    }
    result.routes.push(rec);
  }
  result.done = true;
  writeGroup(manifest.run_dir, result);
  return result;
}
