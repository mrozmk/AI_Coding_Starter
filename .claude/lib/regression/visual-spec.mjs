// Worker side of the regression visual lane: what the copied visual config and spec call inside the
// Playwright process. `visualOptions` turns the pass manifest into config values (one spec file
// collected, update mode, repeats, output under the run directory, snapshot path, tolerance),
// `visualTargets` lists the targets the spec declares tests for, `renderTarget` renders one target and
// appends exactly one outcome line to `<run>/visual.jsonl` (plus one renderer line per worker and
// project). No `@playwright/test` import: Playwright objects arrive as arguments.
// Node builtins only — ships to every downstream. Contract: .agents/reference/regression.md §13.
//
// Library only (no CLI). The pass manifest (`REGRESSION_RUN`) is written by run.mjs.

import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { createHash } from 'node:crypto';

const FONT_DIRS = ['/System/Library/Fonts', '/Library/Fonts', '~/Library/Fonts', '/usr/share/fonts', '/usr/local/share/fonts', '~/.fonts', '~/.local/share/fonts'];
const STORY_ROOTS = ['#storybook-root', '#root'];
const MASK_COLOR = '#FF00FF';

const escapeRe = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
const posix = (p) => p.split(path.sep).join('/');
const firstLine = (s) => String(s ?? '').split('\n').map((l) => l.trim()).find(Boolean) ?? '';

/** Config-side values of one visual pass, from `manifest.visual`. */
export function visualOptions(manifest) {
  const v = manifest?.visual;
  if (!v) return { testDir: '.', testMatch: /(?!)/, repeatEach: 1, retries: 0, updateSnapshots: 'none', ignoreSnapshots: false, expect: {}, use: {} };
  const template = `${posix(path.relative(v.config_dir, v.snapshot_dir))}/{projectName}/{arg}{ext}`;
  const tolerance = v.tolerance ?? { threshold: 0.2, max_diff_pixels: 0 };
  return {
    testDir: path.dirname(v.spec_abs),
    // Only the configured spec: a second visual.spec.ts under testDir is never collected.
    testMatch: new RegExp(`^${escapeRe(v.spec_abs)}$`),
    repeatEach: v.repeat_each ?? 1,
    retries: 0,
    outputDir: v.output_dir,
    snapshotPathTemplate: template,
    updateSnapshots: v.pass === 'capture' ? 'all' : 'none',
    ignoreSnapshots: false,
    expect: { toHaveScreenshot: { pathTemplate: template, threshold: tolerance.threshold, maxDiffPixels: tolerance.max_diff_pixels, animations: 'disabled', caret: 'hide', scale: 'css' } },
    use: { serviceWorkers: 'block', reducedMotion: 'reduce', colorScheme: 'light', timezoneId: v.timezone ?? 'UTC' },
  };
}

/** The targets the spec declares one test each for; none in a functional manifest. */
export const visualTargets = (manifest) => (Array.isArray(manifest?.visual?.targets) ? manifest.visual.targets : []);

/** sha256 (first 12 hex) of the sorted `name\tsize` listing of the OS font directories. */
export function fontsDigest() {
  const rows = [];
  for (const d of FONT_DIRS) {
    const dir = d.startsWith('~') ? path.join(os.homedir(), d.slice(2)) : d;
    let names;
    try { names = fs.readdirSync(dir, { recursive: true }); } catch { continue; }
    for (const n of names) {
      try { const st = fs.statSync(path.join(dir, String(n))); if (st.isFile()) rows.push(`${path.join(dir, String(n))}\t${st.size}`); } catch { /* unreadable */ }
    }
  }
  return createHash('sha256').update(rows.sort().join('\n')).digest('hex').slice(0, 12);
}

/** A container renderer: `/.dockerenv`, or a container cgroup of pid 1. */
export function inContainer() {
  if (fs.existsSync('/.dockerenv')) return true;
  try { return /docker|containerd|kubepods/.test(fs.readFileSync('/proc/1/cgroup', 'utf8')); } catch { return false; }
}

/** One nonce-stamped line in `<run>/visual.jsonl`. */
export function appendEvidence(manifest, line) {
  fs.appendFileSync(path.join(manifest.run_dir, 'visual.jsonl'), `${JSON.stringify({ t: new Date().toISOString(), nonce: manifest.nonce ?? null, ...line })}\n`);
}

const renderersWritten = new Set();
function writeRenderer(manifest, project, browser, testInfo) {
  const key = `${manifest.run_dir}\0${manifest.visual.pass}\0${project}`;
  if (renderersWritten.has(key)) return;
  renderersWritten.add(key);
  const fp = {
    browser: browser?.browserType?.().name?.() ?? null, browser_version: browser?.version?.() ?? null,
    playwright: testInfo.config?.version ?? null, platform: process.platform, os_major: os.release().split('.')[0], arch: process.arch,
    fonts: fontsDigest(), mode: inContainer() ? 'container' : 'host',
  };
  appendEvidence(manifest, { kind: 'renderer', pass: manifest.visual.pass, project, fp });
}

/** Area of the union of rectangles clipped to `[0, w] × [0, h]` (a sweep over x-intervals). */
export function unionArea(rects, w, h) {
  const rs = rects.map((r) => ({ x1: Math.max(0, r.x), y1: Math.max(0, r.y), x2: Math.min(w, r.x + r.width), y2: Math.min(h, r.y + r.height) }))
    .filter((r) => r.x2 > r.x1 && r.y2 > r.y1);
  const xs = [...new Set(rs.flatMap((r) => [r.x1, r.x2]))].sort((a, b) => a - b);
  let area = 0;
  for (let i = 0; i + 1 < xs.length; i += 1) {
    const [a, b] = [xs[i], xs[i + 1]];
    const ys = rs.filter((r) => r.x1 <= a && r.x2 >= b).map((r) => [r.y1, r.y2]).sort((p, q) => p[0] - q[0]);
    let covered = 0;
    let cur = null;
    for (const [y1, y2] of ys) {
      if (!cur || y1 > cur[1]) { if (cur) covered += cur[1] - cur[0]; cur = [y1, y2]; } else cur[1] = Math.max(cur[1], y2);
    }
    if (cur) covered += cur[1] - cur[0];
    area += covered * (b - a);
  }
  return area;
}

/**
 * The outcome a toHaveScreenshot failure proves, read from its diagnostic block — the text after
 * the matcher header line and before `Call log:`. `differs` only on comparison evidence.
 */
export function classifyMatcherError(message) {
  const lines = String(message ?? '').split('\n');
  const callLog = lines.findIndex((l, i) => i > 0 && /^\s*Call log:/.test(l));
  const block = lines.slice(1, callLog < 0 ? undefined : callLog).join('\n');
  if (/Failed to take two consecutive stable screenshots|Timeout \d+ms exceeded/.test(block)) return { outcome: 'error', reason: 'render never stable', diff_pixels: null };
  const px = /(\d+) pixels \(ratio [0-9.]+ of all image pixels\) are different/.exec(block);
  if (px) return { outcome: 'differs', reason: null, diff_pixels: Number(px[1]) };
  if (/Expected an image \d+px by \d+px, received/.test(block)) return { outcome: 'differs', reason: null, diff_pixels: null };
  return { outcome: 'error', reason: `screenshot failed — ${firstLine(block) || firstLine(message)}`, diff_pixels: null };
}

class TargetError extends Error {}
const fail = (reason) => { throw new TargetError(reason); };

async function storyReady(page, target) {
  const sel = target.error ? `${target.ready}, ${target.error}` : target.ready;
  try { await page.locator(sel).first().waitFor({ state: 'attached' }); } catch { fail('story not ready'); }
  if (target.error && await page.locator(target.error).count()) fail('story error display');
  if (!(await page.locator(target.ready).count())) fail('story not ready');
  for (const rootSel of STORY_ROOTS) {
    if (!(await page.locator(rootSel).count())) continue;
    for (const child of await page.locator(`${rootSel} > *`).all()) {
      const b = await child.boundingBox();
      if (b && b.width > 0 && b.height > 0) return;
    }
    break;
  }
  fail('story rendered nothing');
}

/** The masked ratio of the shot: the union of every matched element's box over the shot area. */
async function maskRatio(page, locators, fullPage) {
  const shot = fullPage
    ? await page.evaluate(() => ({ width: document.documentElement.scrollWidth, height: document.documentElement.scrollHeight }), 'size')
    : page.viewportSize();
  const rects = [];
  for (const loc of locators) for (const el of await loc.all()) { const b = await el.boundingBox(); if (b) rects.push(b); }
  if (!shot?.width || !shot?.height) return 0;
  return unionArea(rects, shot.width, shot.height) / (shot.width * shot.height);
}

/**
 * Render one target in a guarded context and record exactly one outcome line: `same`, `differs`,
 * `missing` (no expected file — no assertion), `captured` (capture pass) or `error`.
 * Navigation, readiness, mask and matcher failures fail the test (rethrown).
 */
export async function renderTarget({ page, browser }, testInfo, target, expect, manifest) {
  const v = manifest.visual;
  const project = testInfo.project?.name ?? null;
  const ev = {
    kind: 'outcome', pass: v.pass, id: target.id, project, file: target.file,
    repeat: testInfo.repeatEachIndex ?? 0, retry: testInfo.retry ?? 0, test: testInfo.testId ?? null,
    outcome: 'error', diff_pixels: null, masked_ratio: null, reason: null, diff: null,
  };
  let thrown = null;
  try {
    writeRenderer(manifest, project, browser, testInfo);
    if (testInfo.project?.ignoreSnapshots === true || testInfo.config?.ignoreSnapshots === true) fail('snapshots ignored');
    const resp = await page.goto(target.url, { waitUntil: 'load' });
    const status = resp ? resp.status() : null;
    if (!resp || !(status >= 200 && status <= 299)) fail(`navigation ${status ?? 'no response'}`);
    if (target.source === 'storybook') await storyReady(page, target);
    if (target.wait_for) await page.locator(target.wait_for).first().waitFor({ state: 'visible' });
    await page.evaluate(async () => {
      await document.fonts.ready;
      await Promise.all([...document.images].map((img) => (img.complete ? null : new Promise((r) => { img.onload = r; img.onerror = r; }))));
    }, 'settle');
    const masks = [...(v.mask ?? []), ...(target.mask ?? [])].map((m) => page.locator(m.selector));
    const ratio = await maskRatio(page, masks, target.full_page === true);
    ev.masked_ratio = Math.round(ratio * 10000) / 10000;
    if (ratio > (v.max_mask_ratio ?? 0.25)) fail(`mask covers ${(ratio * 100).toFixed(1)}%`);
    await page.evaluate(() => null, 'before-shot');
    if (target.source === 'storybook' && target.error && await page.locator(target.error).count()) fail('story error display');
    const opts = { mask: masks, maskColor: MASK_COLOR, fullPage: target.full_page === true };
    if (v.pass === 'capture') {
      try { await expect(page).toHaveScreenshot([target.file], opts); } catch (err) {
        const c = classifyMatcherError(err?.message);
        ev.reason = c.outcome === 'error' ? c.reason : `screenshot failed — ${firstLine(err?.message)}`;
        throw err;
      }
      ev.outcome = 'captured';
    } else if (!fs.existsSync(path.join(v.snapshot_dir, project, target.file))) {
      ev.outcome = 'missing';
    } else {
      try {
        await expect(page).toHaveScreenshot([target.file], opts);
        ev.outcome = 'same';
      } catch (err) {
        const c = classifyMatcherError(err?.message);
        Object.assign(ev, { outcome: c.outcome, reason: c.reason, diff_pixels: c.diff_pixels });
        const att = (testInfo.attachments ?? []).find((a) => /-diff\.png$/.test(a?.name ?? '') || /-diff\.png$/.test(a?.path ?? ''));
        if (c.outcome === 'differs' && att?.path) ev.diff = posix(path.relative(process.cwd(), att.path));
        throw err;
      }
    }
  } catch (err) {
    thrown = err;
    if (err instanceof TargetError) { ev.outcome = 'error'; ev.reason = err.message; }
    else if (ev.outcome === 'error' && !ev.reason) ev.reason = `screenshot failed — ${firstLine(err?.message)}`;
  } finally {
    appendEvidence(manifest, ev);
  }
  if (thrown) throw thrown;
}
