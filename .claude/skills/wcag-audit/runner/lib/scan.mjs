// scan.mjs — the scan subcommand: refusals first, units planned before any navigation, then per
// URL × viewport: load → banner (audited, then dismissed) → states → engines + own checks, each
// mutating check on a freshly restored state. run.json is rewritten atomically after every target.
import fs from 'node:fs';
import path from 'node:path';
import { Refusal, allocWork, assertIgnored, assertInputFile, writeRun, isInside, reportPaths } from './paths.mjs';
import * as deps from './deps.mjs';
import { parseTarget, targetClass, givenOrigins, resolveAddresses } from './policy.mjs';
import * as ev from './evidence.mjs';
import { axeRuleIds, axeRuleSc } from './criteria.mjs';
import { startProxy } from './proxy.mjs';
import { launch, freshPage, closeAll, registerClose, wasInterrupted, VIEWPORTS } from './browser.mjs';
import { loadPage, siteLanguage } from './load.mjs';
import { runAxe, classifyFrames } from './engines/axe.mjs';
import { redactUrl } from './redact.mjs';
import { inPage, toLocator } from './dom.mjs';
import keyboard from './checks/keyboard.mjs';
import focus from './checks/focus.mjs';
import arrowWidgets from './checks/arrow-widgets.mjs';
import targetSize from './checks/target-size.mjs';
import reflow from './checks/reflow.mjs';
import textResize from './checks/text-resize.mjs';
import textSpacing from './checks/text-spacing.mjs';
import contrastRender from './checks/contrast-render.mjs';
import hoverFocus from './checks/hover-focus.mjs';
import heuristics from './checks/heuristics.mjs';
import { detectBanner, dismissBanner } from './checks/cookie-banner.mjs';
import { discoverStates, openState, MAX_STATES } from './checks/states.mjs';
import { collectSemantic, brokenImage } from './checks/semantic.mjs';

export const CHECKS = [targetSize, contrastRender, keyboard, focus, arrowWidgets, textSpacing, textResize, hoverFocus, reflow, ...heuristics];
const PAGE_LIMIT_MS = 120_000;
const RUN_LIMIT_MS = 20 * 60_000;
const MAX_EVIDENCE = 40;
const MASK_SELECTOR = 'input, textarea, select, [contenteditable]:not([contenteditable=false]), [data-wcag-mask]';
const CLIENTS = ['public-sector', 'eaa-service', 'microenterprise', 'other', 'unknown'];

class PageTimeout extends Error {}

function usage(hint) {
  return { code: 2, body: { ok: false, refusal: 'usage', hint } };
}

function today() {
  return new Date().toISOString().slice(0, 10);
}

function testEnv(name) {
  return process.env.WCAG_AUDIT_TEST === '1' ? process.env[name] : undefined;
}

export async function scanCommand(opts) {
  if (!opts['urls-file']) return usage('--urls-file <file> is required (one URL per line)');
  const level = opts.level || 'AA';
  const wcag = opts.wcag || '2.2';
  if (!['A', 'AA'].includes(level)) return usage('--level must be A or AA');
  if (!['2.2', '2.1'].includes(wcag)) return usage('--wcag must be 2.2 or 2.1');
  const viewports = String(opts.viewports || 'desktop,mobile').split(',').map((v) => v.trim()).filter(Boolean);
  if (!viewports.length || viewports.some((v) => !['desktop', 'mobile'].includes(v))) return usage('--viewports takes desktop and/or mobile');
  const maxPages = opts['max-pages'] ? Number(opts['max-pages']) : 10;
  if (!Number.isInteger(maxPages) || maxPages < 1) return usage('--max-pages must be a positive integer');
  const client = opts.client || 'unknown';
  if (!CLIENTS.includes(client)) return usage(`--client must be one of ${CLIENTS.join(', ')}`);
  const llm = !opts['no-llm'];

  const file = path.resolve(opts['urls-file']);
  assertInputFile(file);
  const lines = fs.readFileSync(file, 'utf8').split('\n').map((l) => l.trim()).filter((l) => l && !l.startsWith('#'));
  if (!lines.length) throw new Refusal('bad-input-file', 'the URL file holds no URL');
  const parsed = lines.map((l) => parseTarget(l));
  const capped = parsed.length > maxPages ? parsed.length - maxPages : 0;
  const urls = parsed.slice(0, maxPages);

  const install = deps.assertReady();
  deps.browserChoice(install.dir);

  const slug = opts.slug || urls[0].hostname.replace(/^www\./, '');
  const work = allocWork(slug, today());
  assertIgnored([work.dir, reportPaths(work.dir).html]);

  // Each URL is resolved on its own: an unresolvable host is ledgered, never navigated.
  const dnsFail = testEnv('WCAG_AUDIT_TEST_DNS_FAIL');
  const targets = [];
  for (const u of urls) {
    try {
      if (dnsFail && u.hostname === dnsFail) throw new Error('test dns failure');
      targets.push({ url: u, addresses: await resolveAddresses(u.hostname) });
    } catch {
      targets.push({ url: u, addresses: null });
    }
  }
  const resolved = targets.filter((t) => t.addresses);
  const runClass = resolved.length ? targetClass(resolved) : 'public';
  const origins = givenOrigins(resolved.map((t) => t.url));

  const d = deps.load();
  const profile = { wcag, level };
  const ruleIds = axeRuleIds(d.axe, profile);
  const run = ev.newRun({ urls: urls.map((u) => redactUrl(u.href)), viewports, wcag, level, client, llm, tool: { version: '1.0.0', axe: d.versions.axe, playwright: d.versions.playwright } });
  run.created_at = new Date().toISOString();
  run.engines = { axe: { version: d.versions.axe, tags: profile, executed: [] } };
  ev.registerContributors(run, [
    ...ruleIds.map((id) => ({ id, source: 'axe', sc: axeRuleSc(d.axe, id, profile) })),
    ...CHECKS.flatMap((c) => c.contributors.map((k) => ({ id: k.id, source: 'check', sc: k.sc, perState: c.mode !== 'separate', viewports: c.viewports }))),
    { ...brokenImage, source: 'runner', perState: false },
  ]);
  ev.planUnits(run);
  if (capped) run.ledger.push({ kind: 'page-cap', count: capped });
  fs.mkdirSync(path.join(work.dir, 'evidence'), { recursive: true });
  const persist = () => writeRun(work.dir, run);
  persist();

  targets.forEach((t, i) => {
    if (t.addresses) return;
    for (const p of run.pages.filter((x) => x.page === ev.pageKey(i))) { p.status = 'unresolved'; p.reason = 'dns-failed'; }
    ev.missUnits(run, { page: ev.pageKey(i) }, 'dns-failed');
    run.ledger.push({ kind: 'dns-failed', page: ev.pageKey(i), url: redactUrl(t.url.href) });
  });

  const started = Date.now();
  let proxy = null;
  let browser = null;
  let interrupted = false;
  const ctxInfo = {};
  const scanner = new Scanner({ run, work: work.dir, ruleIds, ctxInfo });
  try {
    if (resolved.length) {
      proxy = await startProxy({ runClass, origins, ledger: run.ledger, context: () => ({ ...ctxInfo }) });
      registerClose(() => proxy.close());
      const b = await launch({ proxyPort: proxy.port, ledger: run.ledger });
      browser = b;
      run.browser = { launch: { chromiumSandbox: true, channel: b.info.channel }, channel: b.info.channel, version: b.info.version, commandLine: b.info.commandLine ?? null, live_probe: b.info.live_probe };
      scanner.browser = b.browser;
      persist();
      for (let i = 0; i < targets.length; i += 1) {
        if (!targets[i].addresses) continue;
        for (const viewport of viewports) {
          if (wasInterrupted()) { interrupted = true; break; }
          if (Date.now() - started > RUN_LIMIT_MS) { interrupted = true; run.ledger.push({ kind: 'run-time-limit' }); break; }
          await scanner.target(i, targets[i].url.href, viewport);
          persist();
        }
        if (interrupted) break;
      }
    }
    run.status = interrupted || wasInterrupted() ? 'partial' : 'complete';
    if (wasInterrupted()) { persist(); return { code: 4, body: { ok: false, error: 'interrupted', work: work.dir } }; }
  } catch (err) {
    run.status = 'partial';
    run.log.push({ at: new Date().toISOString(), phase: 'run', code: err.code || 'run-error' });
    ev.finalize(run);
    persist();
    if (err instanceof Refusal) throw err;
    return { code: 4, body: { ok: false, error: err.code || 'run-error', hint: String(err.message || err).slice(0, 300), work: work.dir } };
  } finally {
    if (browser) await browser.close().catch(() => {});
    if (proxy) await proxy.close().catch(() => {});
    await closeAll();
  }
  ev.finalize(run);
  persist();
  const counts = { findings: run.findings.length, fails: run.criteria.filter((c) => c.status === ev.STATUS.FAILS).length, suspected: run.criteria.filter((c) => c.status === ev.STATUS.SUSPECTED).length, pages: run.pages.filter((p) => p.status === 'completed').length };
  return { code: 0, body: { ok: true, work: work.dir, status: run.status, verdict: run.verdict, counts } };
}

export class Scanner {
  constructor({ run, work, ruleIds, ctxInfo, pageLimitMs = PAGE_LIMIT_MS }) {
    Object.assign(this, { run, work, ruleIds, ctxInfo, pageLimitMs });
    this.evidenceCount = 0;
    this.siteLangSet = false;
    this.token = { dead: false };
  }

  contributorSc(source, id) {
    return this.run.contributors.find((c) => c.source === source && c.id === id)?.sc ?? [];
  }

  async prepared(viewport, url, { banner = null, stateSpec = null, loadName = null } = {}) {
    // A target abandoned at its page time limit opens nothing more.
    if (this.token.dead) throw new PageTimeout('target abandoned');
    const s = await freshPage(this.browser, loadName || viewport, { ledger: this.run.ledger, context: this.ctxInfo, userAgent: this.userAgent });
    this.sessions.add(s);
    const r = await loadPage(s, url, { ledger: this.run.ledger, context: this.ctxInfo });
    if (!r.ok) { await this.drop(s); return { error: r }; }
    if (banner) await dismissBanner(s.page, banner).catch(() => {});
    if (stateSpec) {
      const o = await openState(s, stateSpec);
      if (!o.opened) { await this.drop(s); return { error: { reason: o.reason } }; }
      if (o.withoutNetwork) this.run.ledger.push({ kind: 'opened-without-network', state: stateSpec.id, ...this.ctxInfo });
    }
    return { s, status: r.status };
  }

  async drop(s) {
    this.sessions.delete(s);
    await s.close();
  }

  async target(i, url, viewport) {
    const page = ev.pageKey(i);
    const rec = this.run.pages.find((p) => p.page === page && p.viewport === viewport);
    Object.assign(this.ctxInfo, { page, viewport });
    this.sessions = new Set();
    this.userAgent = undefined;
    this.evidenceCount = 0;
    this.frameInfo = new WeakMap();
    this.framesLedgered = new Set();
    this.banner = null;
    this.replay = null;
    this.page = page;
    this.viewport = viewport;
    this.rec = rec;
    rec.attempts = [];
    const token = { dead: false };
    this.token = token;
    let timer;
    const limit = new Promise((_, reject) => { timer = setTimeout(() => reject(new PageTimeout('page time limit')), this.pageLimitMs); });
    const scan = this.scanTarget(url);
    try {
      await Promise.race([scan, limit]);
      if (rec.status === 'pending') rec.status = 'completed';
    } catch (err) {
      if (err instanceof PageTimeout) {
        this.run.ledger.push({ kind: 'page-time-limit', ...this.ctxInfo });
        ev.missUnits(this.run, { page, viewport }, 'page-time-limit');
        rec.status = rec.status === 'pending' ? 'completed' : rec.status;
      } else {
        rec.status = 'error';
        rec.reason = 'run-error';
        ev.missUnits(this.run, { page, viewport }, 'run-error');
        this.run.log.push({ at: new Date().toISOString(), phase: 'target', code: 'run-error' });
      }
    } finally {
      clearTimeout(timer);
      // An abandoned scanTarget must settle before the next target reuses this scanner's fields:
      // closing its sessions makes every pending page call fail fast, and prepared() opens no more.
      token.dead = true;
      for (const s of [...this.sessions]) await this.drop(s).catch(() => {});
      await scan.catch(() => {});
      for (const s of [...this.sessions]) await this.drop(s).catch(() => {});
    }
    // Units the target never reached stay missing for this page × viewport.
    for (const u of this.run.units) if (u.page === page && u.viewport === viewport && u.status === 'pending') { u.status = 'missing'; u.reason = u.reason || 'not-run'; }
  }

  async scanTarget(url) {
    const { run, page, viewport, rec } = this;
    let first = await this.prepared(viewport, url);
    rec.attempts.push({ status: first.error ? first.error.status : first.status, ua: 'default' });
    if (first.error && first.error.reason !== 'destination-blocked' && (first.error.status === 403 || first.error.status === 429)) {
      // One internal retry of a CDN-blocked main document with a desktop-like user agent.
      const probe = await this.browser.newContext();
      const p = await probe.newPage();
      const ua = (await p.evaluate(() => navigator.userAgent)).replace('HeadlessChrome', 'Chrome');
      await probe.close();
      this.userAgent = ua;
      run.scope.retries.push(`${page} ${viewport}`);
      run.ledger.push({ kind: 'retry-desktop-ua', ...this.ctxInfo });
      first = await this.prepared(viewport, url);
      rec.attempts.push({ status: first.error ? first.error.status : first.status, ua: 'desktop-like' });
    }
    if (first.error) {
      rec.status = 'error';
      rec.reason = first.error.reason;
      ev.missUnits(run, { page, viewport }, 'page-error');
      run.ledger.push({ kind: 'page-error', reason: first.error.reason, ...this.ctxInfo });
      return;
    }
    const s0 = first.s;
    run.log.push({ at: new Date().toISOString(), phase: 'scroll', code: `${page}-${viewport}` });
    if (!this.siteLangSet) { run.site_lang = await siteLanguage(s0.page); this.siteLangSet = true; }
    await this.frames(s0);
    const banner = await detectBanner(s0.page);
    rec.banner = { detected: !!banner, selector: banner, dismissed: false };
    this.banner = banner;
    rec.page_evidence = await this.capture(s0, { viewport: true }, 'initial', { pageCrop: true });
    await this.readonlyPass(s0, 'initial', { semantic: viewport === run.scope.viewports[0] });
    let replay = null;
    if (banner) {
      const dres = await dismissBanner(s0.page, banner).catch(() => ({ dismissed: false }));
      rec.banner.dismissed = dres.dismissed;
      if (dres.dismissed) replay = banner;
      else run.ledger.push({ kind: 'banner-not-dismissed', ...this.ctxInfo });
    }
    this.replay = replay;
    const found = await discoverStates(s0.page).catch(() => []);
    const states = found.slice(0, MAX_STATES - 1);
    if (found.length > states.length) run.ledger.push({ kind: 'state-cap', count: found.length - states.length, ...this.ctxInfo });
    for (const st of states) {
      ev.addStateUnits(run, page, viewport, st.id);
      rec.states.push({ id: st.id, kind: st.kind, opened: false });
    }
    await this.drop(s0);
    await this.mutatingPass(url, 'initial', null);
    for (const check of CHECKS.filter((c) => c.mode === 'separate')) {
      if (check.viewports && !check.viewports.includes(viewport)) continue;
      await this.runCheck(check, 'initial', async () => this.prepared(viewport, url, { loadName: check.load }), url);
    }
    for (const st of states) {
      const p = await this.prepared(viewport, url, { banner: replay, stateSpec: st });
      const srec = rec.states.find((x) => x.id === st.id);
      if (p.error) {
        ev.missUnits(run, { page, viewport, state: st.id }, p.error.reason || 'not-opened');
        run.ledger.push({ kind: 'not-opened', state: st.id, reason: p.error.reason, ...this.ctxInfo });
        continue;
      }
      srec.opened = true;
      await this.readonlyPass(p.s, st.id, { semantic: false });
      await this.drop(p.s);
      await this.mutatingPass(url, st.id, st);
    }
  }

  // The frame classification of one session's page — every state is a fresh load, so its frames can
  // differ from the initial one. A skipped frame is excluded from axe (a nested one through its
  // outermost owner) and masked by its owner element; a frame whose owner cannot be resolved
  // withholds the session's crops. Each skipped frame is ledgered once per target.
  async frames(session) {
    let info = this.frameInfo.get(session);
    if (info) return info;
    const { skipped, included } = await classifyFrames(session.page);
    info = { skipped, included, withhold: skipped.some((f) => !f.selector), exclude: [...new Set(skipped.filter((f) => f.path).map((f) => f.path[0]))] };
    this.frameInfo.set(session, info);
    for (const f of skipped) {
      const key = f.path ? f.path.join(' | ') : `unresolved ${f.frame.url()}`;
      if (this.framesLedgered.has(key)) continue;
      this.framesLedgered.add(key);
      this.run.ledger.push({ kind: f.selector ? 'cross-origin-frame-skipped' : 'frame-owner-unresolved', reason: f.reason, url: redactUrl(f.frame.url()), ...this.ctxInfo });
    }
    return info;
  }

  async readonlyPass(session, state, { semantic }) {
    const { run, page, viewport } = this;
    const fault = testEnv('WCAG_AUDIT_TEST_FAULT');
    const faultPage = fault && fault.startsWith('axe-on:') ? fault.slice(7) : null;
    let axe = [];
    try {
      const url = new URL(session.page.url());
      const { exclude } = await this.frames(session);
      const res = await runAxe(session.page, { ruleIds: this.ruleIds, enableTargetSize: this.ruleIds.includes('target-size'), exclude, testFault: !!faultPage && url.pathname.endsWith(`/${faultPage}`) });
      axe = res.results;
      run.engines.axe.executed = [...new Set([...run.engines.axe.executed, ...res.executed])].sort();
      if (res.version) run.engines.axe.version = res.version;
      await this.recordAxe(session, state, res);
    } catch {
      run.ledger.push({ kind: 'axe-error', state, ...this.ctxInfo });
      for (const id of this.ruleIds) {
        ev.addObservation(run, { source: 'axe', contributor: id, sc: this.contributorSc('axe', id), outcome: 'error', page, viewport, state });
      }
      for (const c of run.contributors.filter((x) => x.source === 'axe')) ev.missUnits(run, { page, viewport, state, contributor: `axe:${c.id}` }, 'axe-error');
    }
    for (const check of CHECKS.filter((c) => c.mode === 'readonly')) {
      await this.runCheck(check, state, async () => ({ s: session, keep: true }), null, { axe });
    }
    // broken-image still runs on every viewport; judge items come from the first viewport only.
    if (state === 'initial') await this.semantic(session, { itemsToo: semantic });
  }

  async recordAxe(session, state, res) {
    const { run, page, viewport } = this;
    const passSeen = new Set();
    const bannerSel = this.banner;
    for (const r of res.results) {
      if (r.outcome === 'pass' || r.outcome === 'inapplicable') {
        const key = `${r.rule}|${r.outcome}`;
        if (passSeen.has(key)) continue;
        passSeen.add(key);
        ev.addObservation(run, { source: 'axe', contributor: r.rule, sc: r.sc, outcome: r.outcome, page, viewport, state });
        continue;
      }
      let ancestor = null;
      if (bannerSel && r.selector && !r.frame) {
        ancestor = await inPage(session.page, 'const el = W.q(arg.sel); const b = W.q(arg.banner); return !!el && !!b && b.contains(el);', { sel: r.selector, banner: bannerSel }).catch(() => false) ? bannerSel : null;
      }
      const evidence = r.selector && !r.frame ? await this.capture(session, { selector: r.selector }, state) : null;
      ev.addObservation(run, { source: 'axe', contributor: r.rule, sc: r.sc, outcome: r.outcome, impact: r.impact, page, viewport, state, selector: r.selector, frame: r.frame, ancestor, evidence_ids: evidence ? [evidence] : [], data: { help: r.help, helpUrl: r.helpUrl, ...(r.data || {}) }, remediation_key: r.rule });
    }
    for (const id of this.ruleIds) {
      if (res.executed.includes(id)) ev.completeUnits(run, { page, viewport, state, contributor: `axe:${id}` });
      else ev.missUnits(run, { page, viewport, state, contributor: `axe:${id}` }, 'not-executed');
    }
  }

  async semantic(session, { itemsToo = true } = {}) {
    const { run, page, viewport } = this;
    let cdp = null;
    try { cdp = await session.context.newCDPSession(session.page); } catch { cdp = null; }
    try {
      const res = await collectSemantic(session.page, { responses: session.state.responses, failed: session.state.failed, proxyBlocked: session.state.proxyBlocked, cdp: itemsToo ? cdp : null });
      for (const b of res.broken) {
        const evidence = await this.capture(session, { selector: b.selector }, 'initial');
        ev.addObservation(run, { source: 'runner', contributor: 'broken-image', sc: brokenImage.sc, outcome: 'violation', basis: '●', impact: 'serious', page, viewport, state: 'initial', selector: b.selector, data: b.data, evidence_ids: evidence ? [evidence] : [], remediation_key: 'broken-image',
          steps: ['Open the page and look at the image.', b.data.decode === 'failed' ? 'The image file could not be decoded; its text alternative cannot be judged.' : `The image did not load (HTTP ${b.data.status ?? 'error'}); its text alternative cannot be judged.`] });
      }
      if (!res.broken.length) ev.addObservation(run, { source: 'runner', contributor: 'broken-image', sc: brokenImage.sc, outcome: res.imageCount ? 'pass' : 'inapplicable', page, viewport, state: 'initial' });
      ev.completeUnits(run, { page, viewport, state: 'initial', contributor: 'runner:broken-image' });
      if (itemsToo) {
        for (const it of res.items) {
          const id = `s${run.semantic_items.length + 1}`;
          const evidence = it.crop && run.llm ? await this.capture(session, { selector: it.selector }, 'initial') : null;
          run.semantic_items.push({ item_id: id, kind: it.kind, page, viewport, state: 'initial', selector: it.selector, text: it.text, context: it.context ?? null, ax_excerpt: it.ax_excerpt ?? null, evidence_id: evidence });
        }
      }
    } catch {
      ev.missUnits(run, { page, viewport, state: 'initial', contributor: 'runner:broken-image' }, 'check-error');
      run.ledger.push({ kind: 'check-error', check: 'semantic', ...this.ctxInfo });
    } finally {
      if (cdp) await cdp.detach().catch(() => {});
    }
  }

  async mutatingPass(url, state, stateSpec) {
    let list = CHECKS.filter((c) => c.mode === 'mutating');
    if (testEnv('WCAG_AUDIT_TEST_CHECK_ORDER') === 'reverse') list = [...list].reverse();
    for (const check of list) {
      await this.runCheck(check, state, async () => this.prepared(this.viewport, url, { banner: this.replay, stateSpec }), url);
    }
  }

  async runCheck(check, state, open, url, extra = {}) {
    const { run, page, viewport } = this;
    const sel = (k) => ({ page, viewport, state, contributor: `check:${k.id}` });
    const p = await open();
    if (p.error) {
      for (const k of check.contributors) ev.missUnits(run, sel(k), p.error.reason || 'state-not-restored');
      run.ledger.push({ kind: 'state-not-restored', check: check.name, state, ...this.ctxInfo });
      return;
    }
    try {
      const results = await check.run({ page: p.s.page, session: p.s, viewport, state, ...extra });
      const missing = new Set();
      for (const r of results) {
        if (r.missing) {
          missing.add(r.contributor);
          ev.missUnits(run, { page, viewport, state, contributor: `check:${r.contributor}` }, r.missing);
          if (r.missing === 'walk-incomplete') run.ledger.push({ kind: 'walk-incomplete', state, ...this.ctxInfo });
          continue;
        }
        let evidence = null;
        if (r.outcome === 'violation' || r.outcome === 'needs-review') {
          const target = r.cropViewport ? { viewport: true } : r.cropBox ? { box: r.cropBox } : r.selector ? { selector: r.selector } : null;
          evidence = target ? await this.capture(p.s, target, state) : null;
        }
        ev.addObservation(run, { source: 'check', contributor: r.contributor, sc: this.contributorSc('check', r.contributor), outcome: r.outcome, basis: r.basis, impact: r.impact, page, viewport, state, selector: r.selector, data: r.data, steps: r.steps, evidence_ids: evidence ? [evidence] : [], remediation_key: r.contributor });
      }
      for (const k of check.contributors) if (!missing.has(k.id)) ev.completeUnits(run, sel(k));
    } catch {
      for (const k of check.contributors) {
        ev.addObservation(run, { source: 'check', contributor: k.id, sc: k.sc, outcome: 'error', page, viewport, state });
        ev.missUnits(run, sel(k), 'check-error');
      }
      run.ledger.push({ kind: 'check-error', check: check.name, state, ...this.ctxInfo });
    } finally {
      if (!p.keep) await this.drop(p.s);
    }
  }

  // A masked crop under <work>/evidence/: inputs, text areas, selects, editable regions, e-mail text
  // (top document, open shadow roots, every included frame at any depth) and every skipped frame are
  // painted #FF00FF. A frame that cannot be masked withholds the crop.
  async capture(session, target, state, { pageCrop = false } = {}) {
    if (this.evidenceCount >= MAX_EVIDENCE) {
      if (this.evidenceCount === MAX_EVIDENCE) this.run.ledger.push({ kind: 'evidence-cap', ...this.ctxInfo });
      this.evidenceCount += 1;
      return null;
    }
    const { page } = session;
    try {
      const info = await this.frames(session);
      if (info.withhold) return null;
      await inPage(page, 'return W.markEmails();');
      const masks = [page.locator(MASK_SELECTOR)];
      for (const f of info.included) {
        await inPage(f, 'return W.markEmails();');
        masks.push(f.locator(MASK_SELECTOR));
      }
      for (const f of info.skipped) masks.push(f.frame.parentFrame().locator(toLocator(f.selector)));
      const vp = page.viewportSize();
      let clip;
      let elBox = null;
      if (target.viewport) {
        clip = { x: 0, y: 0, width: vp.width, height: vp.height };
      } else {
        const box = target.box ? { x: target.box.x, y: target.box.y, w: target.box.w, h: target.box.h } : await inPage(page, `const el = W.q(arg); if (!el) return null; el.scrollIntoView({ block: 'center', inline: 'center' }); const r = el.getBoundingClientRect(); return { x: r.left, y: r.top, w: r.width, h: r.height };`, target.selector);
        if (!box || box.w <= 0 || box.h <= 0) return null;
        const x0 = Math.max(0, Math.floor(box.x - 12));
        const y0 = Math.max(0, Math.floor(box.y - 12));
        const x1 = Math.min(vp.width, Math.ceil(box.x + box.w + 12));
        const y1 = Math.min(vp.height, Math.ceil(box.y + box.h + 12));
        if (x1 - x0 < 2 || y1 - y0 < 2) return null;
        clip = { x: x0, y: y0, width: x1 - x0, height: y1 - y0 };
        elBox = { x: box.x - x0, y: box.y - y0, w: box.w, h: box.h };
      }
      const masked = pageCrop ? await this.maskedBoxes(page, info) : null;
      const n = this.run.evidence.length + 1;
      const rel = `evidence/e-${n}.png`;
      const file = path.join(this.work, rel);
      if (!isInside(file, path.join(this.work, 'evidence'))) return null;
      await page.screenshot({ path: file, clip, mask: masks, maskColor: '#FF00FF', animations: 'disabled', caret: 'hide' });
      this.evidenceCount += 1;
      const id = `e${n}`;
      this.run.evidence.push({ id, path: rel, page: this.page, viewport: this.viewport, state, clip, el_box: elBox, scale: VIEWPORTS[this.viewport].deviceScaleFactor, masked_boxes: masked });
      return id;
    } catch {
      return null;
    }
  }

  // Boxes of the skipped frames owned by the top document (nested owners sit inside an included
  // frame and are masked there).
  async maskedBoxes(page, info) {
    const out = [];
    for (const f of info.skipped.filter((x) => x.path && x.path.length === 1)) {
      const b = await inPage(page, 'const el = W.q(arg); if (!el) return null; const r = el.getBoundingClientRect(); return { x: r.left, y: r.top, w: r.width, h: r.height };', f.selector).catch(() => null);
      if (b) out.push({ kind: 'skipped-frame', ...b });
    }
    return out;
  }
}
