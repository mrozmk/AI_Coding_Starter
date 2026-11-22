#!/usr/bin/env node
// Ticket snapshot + freshness comparator for the tracker-comments contract
// (.agents/reference/tracker-comments.md). A snapshot holds hashes and metadata only — never the
// ticket's or the comments' text — and is written with mode 0600 (private tracker data).
//
//   node tracker-snapshot.mjs snapshot --github <show.json> --out <file>
//   node tracker-snapshot.mjs snapshot --jira <jira_get_issue result> [--limit 50] --out <file>
//   node tracker-snapshot.mjs compare <baseline|-> <fresh> [--reconciled id@sha,…] [--out <json>]
//
// compare exits 0 none new · 3 changed (or no baseline) · 4 uncertain · 2 usage / unreadable input.
// Output is ids, counts and statuses only.
import { createHash } from 'node:crypto';
import { readFileSync, writeFileSync, renameSync, chmodSync, existsSync } from 'node:fs';

const die = (msg) => { process.stderr.write(`tracker-snapshot: ${msg}\n`); process.exit(2); };
// Jira REST v3 returns ADF objects for description/comment bodies; String() would collapse them to
// "[object Object]" and hide every edit.
const sha = (text) => createHash('sha256')
  .update(typeof text === 'object' && text !== null ? JSON.stringify(text) : String(text ?? ''), 'utf8').digest('hex');
// Plain text of an ADF node: text nodes, hard breaks as newlines, containers by their children.
const adfText = (node) => {
  if (!node || typeof node !== 'object') return '';
  if (node.type === 'text') return String(node.text ?? '');
  if (node.type === 'hardBreak') return '\n';
  return Array.isArray(node.content) ? node.content.map(adfText).join('') : '';
};
const readJson = (path, what) => {
  try { return JSON.parse(readFileSync(path, 'utf8')); } catch { return die(`${what} ${path} is not readable JSON`); }
};
const flag = (args, name) => { const i = args.indexOf(name); return i >= 0 ? args[i + 1] : undefined; };

// A producer's own marker, at the position that producer writes it: the team wrapup's
// `[wrapup <run> <intent>]` as the LAST line; the cost report's `token-usage-report: <KEY>` as the
// FIRST line; /qa-verify's complete v1 record marker as the whole LAST line, optionally after the
// record's own verdict text (a Jira converter joins the two). A marker anywhere else (a quote) does
// not count. An ADF body counts only through a top-level paragraph — a blockquote, code block or list
// holding a marker is a quote.
function lineList(text) {
  const lines = String(text ?? '').replace(/\r/g, '').split('\n');
  while (lines.length && lines[lines.length - 1].trim() === '') lines.pop();
  return lines;
}
function ownMarker(body) {
  let last, first;
  if (typeof body === 'object' && body !== null) {
    // Trailing blank paragraphs go, like lineList's trailing blank lines; any other block stays the tail.
    const blocks = Array.isArray(body.content) ? [...body.content] : [];
    const blank = (b) => b && b.type === 'paragraph' && adfText(b).trim() === '';
    while (blocks.length && blank(blocks[blocks.length - 1])) blocks.pop();
    const para = (b) => (b && b.type === 'paragraph' ? lineList(adfText(b)) : []);
    const tail = para(blocks[blocks.length - 1]);
    last = (tail[tail.length - 1] ?? '').trim();
    first = (para(blocks[0])[0] ?? '').trim();
  } else {
    const lines = lineList(body);
    last = (lines[lines.length - 1] ?? '').trim();
    first = (lines[0] ?? '').trim();
  }
  return /^\[wrapup \S+ [a-z]+-\S+\]$/.test(last) || /^token-usage-report: \S+$/.test(first)
    || /^(?:(?:\*\*)?Blockers: \d+\.(?:\*\*)? (?:Acceptable — move the ticket yourself|Not acceptable|Not verifiable now — environment) )?qa-verify:v1 record run=\S+ ticket=\S+ mode=(?:first|recheck|light) group=\S+ build=\S+ pass=\d+ fail=\d+ cited=\d+ deferred=\d+ env=\d+ needs-human=\d+$/.test(last)
    || /^(?:QA: .+\. )?qa-verify:v1 deferral src=(?:[A-Z]+-[0-9]+|[0-9]+) row=[A-Za-z0-9.-]{1,40} fp=[0-9a-f]{6}$/.test(last);
}

// No author: the comparator does not need it, and a snapshot stored next to a spec is committed.
const comment = (id, created, updated, body) => ({
  id: String(id), created: String(created ?? ''),
  updated: String(updated ?? created ?? ''), sha: sha(body), own: ownMarker(body),
});

function fromGithub(x) {
  if (!x || typeof x !== 'object' || !Array.isArray(x.comments)) die('the github input is not a show result');
  const comments = x.comments.map((c, i) => {
    if (c.id === undefined || c.id === null || c.id === '') die(`github comment ${i} has no id — re-read with the current team-tracker.sh show`);
    return comment(c.id, c.created, c.updated, c.body);
  });
  return { key: String(x.key ?? ''), tracker: 'github', updated: String(x.updated ?? ''),
    body_sha: sha(x.body), status: 'complete', comments };
}

function fromJira(raw, limit) {
  let x = raw;
  if (x && typeof x === 'object' && typeof x.result === 'string') {
    try { x = JSON.parse(x.result); } catch { die('the jira input wraps a result that is not JSON'); }
  }
  if (!x || typeof x !== 'object') die('the jira input is not an issue');
  const f = x.fields && typeof x.fields === 'object' ? x.fields : {};
  const page = f.comment && typeof f.comment === 'object' ? f.comment : null;
  const list = page && Array.isArray(page.comments) ? page.comments : x.comments;
  if (!Array.isArray(list)) die('the jira input has no comments list — read it with include="comments"');
  const comments = list.map((c, i) => {
    if (!c || (c.id === undefined || c.id === null || c.id === '')) die(`jira comment ${i} has no id`);
    return comment(c.id, c.created, c.updated, c.body);
  });
  let status;
  if (page && Number.isInteger(page.total)) {
    // Raw REST shape: the page says what it holds.
    status = (page.startAt ?? 0) === 0 && comments.length === page.total ? 'complete' : 'possibly-truncated';
  } else {
    // MCP shape, no paging metadata: complete only below the read's own limit.
    status = comments.length === 0 ? 'unknown' : comments.length >= limit ? 'possibly-truncated' : 'complete';
  }
  return { key: String(x.key ?? ''), tracker: 'jira', updated: String(f.updated ?? x.updated ?? ''),
    body_sha: sha(f.description ?? x.description ?? ''), status, comments };
}

function writePrivate(path, data) {
  const tmp = `${path}.tmp.${process.pid}`;
  writeFileSync(tmp, JSON.stringify(data, null, 2) + '\n', { mode: 0o600 });
  chmodSync(tmp, 0o600);
  renameSync(tmp, path);
}

function snapshot(args) {
  const out = flag(args, '--out');
  if (!out) die('snapshot needs --out <file>');
  const gh = flag(args, '--github'), jira = flag(args, '--jira');
  if (!!gh === !!jira) die('snapshot needs exactly one of --github <show.json> / --jira <result.json>');
  const limit = Number(flag(args, '--limit') ?? 50);
  if (!Number.isInteger(limit) || limit < 1) die('--limit must be a positive integer');
  const s = gh ? fromGithub(readJson(gh, 'github input')) : fromJira(readJson(jira, 'jira input'), limit);
  const snap = { v: 1, ...s, read_at: new Date().toISOString(), fetched: s.comments.length };
  writePrivate(out, snap);
  console.log(`key=${snap.key} comments=${snap.fetched} status=${snap.status}`);
}

function loadSnap(path, what) {
  const s = readJson(path, what);
  if (!s || s.v !== 1 || !Array.isArray(s.comments) || typeof s.body_sha !== 'string') die(`${what} ${path} is not a snapshot`);
  return s;
}

function compare(args) {
  const [basePath, freshPath] = args.filter((a, i) => !a.startsWith('--') && !(args[i - 1] ?? '').startsWith('--'));
  if (!basePath || !freshPath) die('compare needs <baseline|-> <fresh>');
  const fresh = loadSnap(freshPath, 'fresh snapshot');
  const reconciled = new Set(String(flag(args, '--reconciled') ?? '').split(',').filter(Boolean));
  const noBaseline = basePath === '-' || !existsSync(basePath);
  const base = noBaseline ? { comments: [], body_sha: null } : loadSnap(basePath, 'baseline');
  const was = new Map(base.comments.map((c) => [c.id, c]));
  const res = { result: 'none', no_baseline: noBaseline, status: fresh.status, new: [], edited: [],
    removed: [], uncertain_removed: [], description_changed: false };

  for (const c of fresh.comments) {
    const old = was.get(c.id);
    if (reconciled.has(`${c.id}@${c.sha}`)) continue;
    // Skip only a producer's own entry: own now, and new or already own in the baseline. A human
    // comment edited into carrying a marker stays visible.
    if (c.own && (!old || old.own)) continue;
    if (!old) res.new.push(c.id);
    else if (old.sha !== c.sha) res.edited.push(c.id);
  }
  const seen = new Set(fresh.comments.map((c) => c.id));
  for (const c of base.comments) {
    if (c.own || seen.has(c.id)) continue;
    (fresh.status === 'complete' ? res.removed : res.uncertain_removed).push(c.id);
  }
  res.description_changed = noBaseline || base.body_sha !== fresh.body_sha;

  const changed = res.new.length || res.edited.length || res.removed.length || res.description_changed;
  if (fresh.status !== 'complete') res.result = 'uncertain';
  else if (changed) res.result = 'changed';
  const parts = [];
  if (res.new.length) parts.push(`new ${res.new.join(' ')}`);
  if (res.edited.length) parts.push(`edited ${res.edited.join(' ')}`);
  if (res.removed.length) parts.push(`removed ${res.removed.join(' ')}`);
  if (res.description_changed) parts.push(noBaseline ? 'no baseline — description and every comment count as new' : 'description changed');
  let line;
  if (res.result === 'uncertain') {
    line = `Tracker comments: uncertain — ${fresh.status}, ${fresh.fetched} read${parts.length ? `; ${parts.join('; ')}` : ''}${res.uncertain_removed.length ? `; missing ${res.uncertain_removed.join(' ')}` : ''}`;
  } else if (res.result === 'changed') line = `Tracker comments: ${parts.join('; ')}`;
  else line = `Tracker comments: none new (${fresh.read_at}, ${fresh.fetched})`;
  res.line = line;
  const out = flag(args, '--out');
  if (out) writePrivate(out, res);
  console.log(line);
  process.exit(res.result === 'none' ? 0 : res.result === 'changed' ? 3 : 4);
}

const [cmd, ...args] = process.argv.slice(2);
if (cmd === 'snapshot') snapshot(args);
else if (cmd === 'compare') compare(args);
else die('usage: tracker-snapshot.mjs snapshot|compare …');
