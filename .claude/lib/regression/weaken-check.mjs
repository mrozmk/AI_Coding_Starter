// The never-weaken check of the heal lane: compares a claimed spec (`before`) with a candidate repair
// (`after`) and refuses every edit outside a small allow-list — a retargeted locator, a changed
// `timeout` option, an added assertion, action, wait or binding (and, under `--refresh`, the
// `// regression:` header). Fail-closed: a statement it cannot classify is `unclassified`, never
// skipped. Pure token comparison over the stripped text — no runner, no network, no model.
// Node builtins only — ships to every downstream. Contract: .agents/reference/regression.md §17.
//
//   node .claude/lib/regression/weaken-check.mjs <before> <after> [--refresh] [--json]
//     exit 0 ok · 1 weakened (one `weakened:` line per finding) · 2 usage / unreadable file

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { stripComments } from './speclint.mjs';
import { HEADER, UNOBSERVABLE } from './catalog.mjs';

// The index of the options argument of each web-first matcher; `last` = a trailing object literal.
const OPTION_ARG = {
  toBeAttached: 0, toBeChecked: 0, toBeDisabled: 0, toBeEditable: 0, toBeEmpty: 0, toBeEnabled: 0, toBeFocused: 0,
  toBeHidden: 0, toBeInViewport: 0, toBeVisible: 0, toBeOK: 0,
  toContainText: 1, toContainClass: 1, toHaveAccessibleDescription: 1, toHaveAccessibleName: 1, toHaveAccessibleErrorMessage: 1,
  toHaveClass: 1, toHaveCount: 1, toHaveId: 1, toHaveRole: 1, toHaveText: 1, toHaveTitle: 1, toHaveURL: 1, toHaveValue: 1,
  toHaveValues: 1, toMatchAriaSnapshot: 1,
  toHaveAttribute: 2, toHaveCSS: 2, toHaveJSProperty: 2,
  toHaveScreenshot: 'last', toMatchSnapshot: 'last',
};
// Generic matchers: every argument is expected data, a `{ timeout }` there included.
const GENERIC = new Set([
  'toBe', 'toEqual', 'toStrictEqual', 'toMatchObject', 'toContain', 'toContainEqual', 'toHaveLength', 'toHaveProperty', 'toMatch',
  'toBeTruthy', 'toBeFalsy', 'toBeNull', 'toBeUndefined', 'toBeDefined', 'toBeNaN', 'toBeGreaterThan', 'toBeGreaterThanOrEqual',
  'toBeLessThan', 'toBeLessThanOrEqual', 'toBeCloseTo', 'toBeInstanceOf', 'toThrow', 'toThrowError',
]);
const LOCATOR_CALLS = new Set(['getByRole', 'getByText', 'getByLabel', 'getByPlaceholder', 'getByAltText', 'getByTitle', 'getByTestId', 'locator', 'frameLocator', 'first', 'last', 'nth', 'filter', 'and', 'or']);
const WAITS = new Set(['waitFor', 'waitForURL', 'waitForLoadState', 'waitForResponse', 'waitForRequest', 'waitForEvent']);
const ACTIONS = new Set(['goto', 'click', 'dblclick', 'fill', 'press', 'pressSequentially', 'type', 'check', 'uncheck', 'selectOption', 'setInputFiles', 'hover', 'focus', 'tap', 'dragTo', 'setViewportSize']);
const MARKERS = new Set(['skip', 'fixme', 'fail', 'only', 'slow']);
const CONTROL = new Set(['if', 'else', 'switch', 'try', 'catch', 'finally', 'for', 'while', 'do']);
const PUNCT3 = ['===', '!==', '...'];
const PUNCT2 = ['=>', '==', '!=', '&&', '||', '??', '?.', '<=', '>=', '++', '--', '+=', '-='];
const REGEX_AFTER = new Set(['(', ',', '=', ':', '[', '!', '&', '|', '?', '{', '}', ';', '=>', '&&', '||', '??', 'return', 'typeof']);

class ParseError extends Error {}

// ---------------------------------------------------------------------------------------------
// Tokens and statements

/** Tokens `{t, kind, line}` of stripped code: string, template and regex literals kept whole, byte for byte. */
export function tokenize(code) {
  const out = [];
  let line = 1;
  let i = 0;
  const push = (t, kind, at) => out.push({ t, kind, line: at });
  while (i < code.length) {
    const c = code[i];
    if (c === '\n') { line += 1; i += 1; continue; }
    if (/\s/.test(c)) { i += 1; continue; }
    const at = line;
    if (c === "'" || c === '"' || c === '`') {
      let j = i + 1;
      while (j < code.length && code[j] !== c) j += code[j] === '\\' ? 2 : 1;
      if (j >= code.length) throw new ParseError('unterminated string');
      const t = code.slice(i, j + 1);
      line += (t.match(/\n/g) ?? []).length;
      push(t, 'str', at);
      i = j + 1;
      continue;
    }
    const prev = out.at(-1);
    if (c === '/' && (!prev || REGEX_AFTER.has(prev.t))) {
      let j = i + 1;
      let cls = false;
      while (j < code.length && (cls || code[j] !== '/')) {
        if (code[j] === '\n') throw new ParseError('unterminated regex');
        if (code[j] === '\\') j += 1; else if (code[j] === '[') cls = true; else if (code[j] === ']') cls = false;
        j += 1;
      }
      j += 1;
      while (j < code.length && /[a-z]/i.test(code[j])) j += 1;
      push(code.slice(i, j), 'regex', at);
      i = j;
      continue;
    }
    const word = /^[A-Za-z_$][\w$]*/.exec(code.slice(i, i + 200));
    if (word) { push(word[0], 'id', at); i += word[0].length; continue; }
    const num = /^\d[\w.]*/.exec(code.slice(i, i + 50));
    if (num) { push(num[0], 'num', at); i += num[0].length; continue; }
    const p = PUNCT3.find((x) => code.startsWith(x, i)) ?? PUNCT2.find((x) => code.startsWith(x, i)) ?? c;
    push(p, 'punct', at);
    i += p.length;
  }
  return out;
}

const OPEN = { '(': ')', '[': ']', '{': '}' };
const CLOSE = new Set([')', ']', '}']);

/** Split tokens on `sep` at bracket depth 0; throws on an unbalanced list. */
function splitTop(toks, sep) {
  const parts = [[]];
  const stack = [];
  for (const tk of toks) {
    if (tk.kind === 'punct' && OPEN[tk.t]) stack.push(OPEN[tk.t]);
    else if (tk.kind === 'punct' && CLOSE.has(tk.t)) { if (stack.pop() !== tk.t) throw new ParseError('unbalanced brackets'); }
    if (!stack.length && tk.kind === 'punct' && tk.t === sep) { parts.push([]); continue; }
    parts.at(-1).push(tk);
  }
  if (stack.length) throw new ParseError('unbalanced brackets');
  return parts.filter((p) => p.length);
}

const textOf = (toks) => toks.map((x) => x.t).join(' ');

/** The index of the bracket closing the one at `i`. */
function closing(toks, i) {
  let depth = 0;
  for (let j = i; j < toks.length; j += 1) {
    if (toks[j].kind !== 'punct') continue;
    if (OPEN[toks[j].t]) depth += 1;
    else if (CLOSE.has(toks[j].t)) { depth -= 1; if (depth === 0) return j; }
  }
  throw new ParseError('unbalanced brackets');
}

/** A member/call chain `id(.name | ?.name | (args))*` covering all of `toks`, or null. */
function parseChain(toks) {
  if (!toks.length || toks[0].kind !== 'id') return null;
  const segs = [{ type: 'id', name: toks[0].t }];
  let i = 1;
  while (i < toks.length) {
    const tk = toks[i];
    if ((tk.t === '.' || tk.t === '?.') && toks[i + 1]?.kind === 'id') { segs.push({ type: 'member', name: toks[i + 1].t }); i += 2; continue; }
    if (tk.t === '(') {
      const j = closing(toks, i);
      segs.push({ type: 'call', args: splitTop(toks.slice(i + 1, j), ',') });
      i = j + 1;
      continue;
    }
    return null;
  }
  return segs;
}

/** `{key: valueText}` of an object literal's tokens, `{__raw}` when it is not plain `key: value` pairs. */
function objectOf(toks) {
  if (toks[0]?.t !== '{' || toks.at(-1)?.t !== '}') return null;
  const out = {};
  for (const pair of splitTop(toks.slice(1, -1), ',')) {
    if (pair.length < 3 || !['id', 'str'].includes(pair[0].kind) || pair[1].t !== ':') return { __raw: textOf(toks) };
    out[pair[0].t.replace(/^['"]|['"]$/g, '')] = pair.slice(2);
  }
  return out;
}

/** Locator calls of a chain: `[{name, args}]`, in order. */
const locatorCalls = (segs) => {
  const out = [];
  segs?.forEach((s, k) => { if (s.type === 'member' && LOCATOR_CALLS.has(s.name) && segs[k + 1]?.type === 'call') out.push({ name: s.name, args: segs[k + 1].args }); });
  return out;
};

/** The chain's text with every run of locator-producing calls collapsed to `LOC`. */
function maskChain(segs) {
  const parts = [];
  for (let k = 0; k < segs.length; k += 1) {
    const s = segs[k];
    if (s.type === 'member' && LOCATOR_CALLS.has(s.name) && segs[k + 1]?.type === 'call') {
      if (parts.at(-1) !== '.LOC') parts.push('.LOC');
      k += 1;
      continue;
    }
    parts.push(s.type === 'id' ? s.name : s.type === 'member' ? `.${s.name}` : `(${s.args.map(textOf).join(' , ')})`);
  }
  return parts.join('');
}

/** A locator call of `after` that matches less than its `before` counterpart: `exact: true` dropped, a string turned into a regex. */
function loosenedLocator(beforeSegs, afterSegs) {
  const b = locatorCalls(beforeSegs);
  const a = locatorCalls(afterSegs);
  if (b.length !== a.length) return null;
  for (let k = 0; k < b.length; k += 1) {
    if (b[k].name !== a[k].name) continue;
    const bargs = b[k].args;
    const aargs = a[k].args;
    if (bargs[0]?.length === 1 && bargs[0][0].kind === 'str' && aargs[0]?.length === 1 && aargs[0][0].kind === 'regex') return `${b[k].name}: a string became a regex`;
    const bo = bargs.map(objectOf).find((o) => o && !o.__raw) ?? {};
    const ao = aargs.map(objectOf).find((o) => o && !o.__raw) ?? {};
    if (bo.exact && textOf(bo.exact) === 'true' && !(ao.exact && textOf(ao.exact) === 'true')) return `${b[k].name}: exact: true dropped`;
    for (const [key, v] of Object.entries(bo)) {
      if (v.length === 1 && v[0].kind === 'str' && ao[key]?.length === 1 && ao[key][0].kind === 'regex') return `${b[k].name}: ${key} became a regex`;
    }
  }
  return null;
}

/** Literal arguments only (strings, numbers, regexes, booleans, null, object keys). */
function literalArgs(args) {
  return args.every((arg) => arg.every((tk, k) => tk.kind !== 'id' || ['true', 'false', 'null', 'undefined'].includes(tk.t) || arg[k + 1]?.t === ':'));
}

/** One body statement: `{kind, text, masked, line, segs, assertion?, name?}`. */
function classifyStatement(toks) {
  const text = textOf(toks);
  const line = toks[0].line;
  const base = { text, masked: text, line, segs: null };
  if (hasMarker(toks)) return { ...base, kind: 'marker' };
  if (toks[0].t === 'const' && toks[1]?.kind === 'id' && toks[2]?.t === '=') {
    const segs = parseChain(toks.slice(3));
    const locatorsOnly = segs && segs.slice(1).every((s, k, rest) => (s.type === 'member' ? LOCATOR_CALLS.has(s.name) && rest[k + 1]?.type === 'call' : rest[k - 1]?.type === 'member'));
    if (segs && segs.length > 1 && locatorsOnly && segs.filter((s) => s.type === 'call').every((s) => literalArgs(s.args))) {
      return { ...base, kind: 'binding', name: toks[1].t, segs, masked: `const ${toks[1].t} = ${maskChain(segs)}` };
    }
    return { ...base, kind: 'other' };
  }
  const awaited = toks[0].t === 'await';
  const segs = parseChain(awaited ? toks.slice(1) : toks);
  if (!segs) return { ...base, kind: 'other' };
  if (segs[0].name === 'expect') {
    const a = assertionOf(segs, awaited);
    if (a && !toks.some((tk) => ['||', '&&', '??'].includes(tk.t))) return { ...base, kind: 'assertion', segs, assertion: a };
    return { ...base, kind: 'other' };
  }
  const lastCall = [...segs].reverse().findIndex((s) => s.type === 'call');
  const method = lastCall === 0 ? segs.at(-2) : null;
  const masked = `${awaited ? 'await ' : ''}${maskChain(segs)}`;
  if (awaited && method?.type === 'member' && WAITS.has(method.name)) return { ...base, kind: 'wait', segs, masked };
  if (awaited && method?.type === 'member' && ACTIONS.has(method.name)) return { ...base, kind: 'action', segs, masked };
  return { ...base, kind: 'other' };
}

/** `{awaited, soft, poll, not, matcher, subject, subjectSegs, data, options}` of an `expect` chain, or null. */
function assertionOf(segs, awaited) {
  let k = 1;
  let soft = false;
  let poll = false;
  if (segs[k]?.type === 'member' && (segs[k].name === 'soft' || segs[k].name === 'poll')) { soft = segs[k].name === 'soft'; poll = segs[k].name === 'poll'; k += 1; }
  if (segs[k]?.type !== 'call') return null;
  const subjectArgs = segs[k].args;
  k += 1;
  let not = false;
  if (segs[k]?.type === 'member' && segs[k].name === 'not') { not = true; k += 1; }
  const m = segs[k];
  if (m?.type !== 'member' || !/^to[A-Z]\w*$/.test(m.name) || segs[k + 1]?.type !== 'call' || k + 2 !== segs.length) return null;
  const matcher = m.name;
  const args = segs[k + 1].args;
  let optIdx = null;
  if (Object.hasOwn(OPTION_ARG, matcher)) {
    const at = OPTION_ARG[matcher] === 'last' ? args.length - 1 : OPTION_ARG[matcher];
    if (at >= 0 && at < args.length && args[at][0]?.t === '{') optIdx = at;
  } else if (!GENERIC.has(matcher)) return null;
  const options = optIdx === null ? {} : objectOf(args[optIdx]) ?? { __raw: textOf(args[optIdx]) };
  return {
    awaited, soft, poll, not, matcher,
    subject: subjectArgs.map(textOf).join(' , '), subjectSegs: subjectArgs.length === 1 ? parseChain(subjectArgs[0]) : null,
    data: args.filter((_, i) => i !== optIdx).map(textOf),
    options: Object.fromEntries(Object.entries(options).map(([key, v]) => [key, typeof v === 'string' ? v : textOf(v)])),
  };
}

const withoutTimeout = (o) => JSON.stringify(Object.entries(o).filter(([key]) => key !== 'timeout').sort());

function hasMarker(toks) {
  return toks.some((tk, k) => (tk.t === '.' && MARKERS.has(toks[k + 1]?.t) && toks[k + 2]?.t === '(')
    || (tk.t === 'test' && toks[k + 1]?.t === '.' && toks[k + 2]?.t === 'abort' && toks[k + 3]?.t === '('));
}

/** `[{line, text}]` of every marker call in the tokens. */
function markers(toks) {
  const out = [];
  toks.forEach((tk, k) => {
    if (tk.t === '.' && MARKERS.has(toks[k + 1]?.t) && toks[k + 2]?.t === '(') out.push({ line: tk.line, name: toks[k + 1].t });
    else if (tk.t === 'test' && toks[k + 1]?.t === '.' && toks[k + 2]?.t === 'abort' && toks[k + 3]?.t === '(') out.push({ line: tk.line, name: 'abort' });
  });
  return out;
}

/** `[{line}]` of every control-flow token: a keyword or a ternary `?`. */
const controlFlow = (toks) => toks.filter((tk) => (tk.kind === 'id' && CONTROL.has(tk.t)) || (tk.kind === 'punct' && tk.t === '?'));

// ---------------------------------------------------------------------------------------------
// The parsed spec

/** `{imports, header, unobservable, use, test, rest, toks, error}` of one spec text. */
export function parseSpecText(raw) {
  const text = raw.replace(/\r/g, '');
  const lines = text.split('\n');
  const out = {
    lines,
    header: lines.filter((l) => HEADER.test(l)).map((l) => l.trim()),
    unobservable: lines.map((l, i) => ({ line: i + 1, text: l.trim() })).filter((l) => UNOBSERVABLE.test(l.text)),
    imports: [], use: [], tests: [], rest: [], toks: [], error: null,
  };
  try {
    out.toks = tokenize(stripComments(text));
    for (const st of splitTop(out.toks, ';')) {
      const head = st.slice(0, 3).map((x) => x.t).join(' ');
      if (st[0].t === 'import') out.imports.push(textOf(st));
      else if (head === 'test . use') out.use.push({ text: textOf(st), line: st[0].line });
      else if (st[0].t === 'test' && st[1]?.t === '(') out.tests.push(parseTest(st));
      else out.rest.push({ text: textOf(st), line: st[0].line });
    }
  } catch (err) {
    if (!(err instanceof ParseError)) throw err;
    out.error = err.message;
  }
  return out;
}

/** `{title, details, params, line, body: [statement]}` of a `test(title, details?, async (…) => { … })` call. */
function parseTest(st) {
  const j = closing(st, 1);
  if (j !== st.length - 1) throw new ParseError('test( is followed by more code');
  const args = splitTop(st.slice(2, j), ',');
  if (args.length < 2 || args.length > 3 || args[0].length !== 1 || args[0][0].kind !== 'str') throw new ParseError('test( does not take (title, details?, fn)');
  const fn = args.at(-1);
  const arrow = fn.findIndex((tk) => tk.t === '=>');
  if (arrow < 0 || fn[arrow + 1]?.t !== '{' || closing(fn, arrow + 1) !== fn.length - 1) throw new ParseError('the test body is not an arrow function block');
  const body = splitTop(fn.slice(arrow + 2, -1), ';').map(classifyStatement);
  return {
    title: args[0][0].t, details: args.length === 3 ? textOf(args[1]) : '', params: textOf(fn.slice(0, arrow)),
    line: st[0].line, body, toks: fn,
  };
}

// ---------------------------------------------------------------------------------------------
// Compare

/**
 * `{ok, weakened: [{line, kind, detail}], allowed: [{line, kind, detail}]}` — lines are 1-based in
 * `afterText` (`beforeText` for a `removed-*` finding). `refresh` allows a changed header only.
 */
export function weakenCheck(beforeText, afterText, { refresh = false } = {}) {
  const weakened = [];
  const allowed = [];
  const bad = (line, kind, detail) => weakened.push({ line, kind, detail });
  const ok = (line, kind, detail) => allowed.push({ line, kind, detail });
  const b = parseSpecText(beforeText);
  const a = parseSpecText(afterText);
  const done = () => {
    // A refresh re-authors the header only: every other allowed edit is refused there.
    if (refresh) {
      for (const x of allowed.filter((y) => y.kind !== 'header')) weakened.push({ ...x, detail: `${x.detail} — a refresh changes only the header` });
      allowed.splice(0, allowed.length, ...allowed.filter((y) => y.kind === 'header'));
    }
    return { ok: weakened.length === 0, weakened, allowed };
  };

  for (const [which, p] of [['before', b], ['after', a]]) {
    if (p.error) bad(1, 'unclassified', `${which}: ${p.error}`);
    else if (p.tests.length !== 1) bad(1, 'unclassified', `${which}: ${p.tests.length} test( calls — one expected`);
    else if (p.rest.length) bad(p.rest[0].line, 'unclassified', `${which}: top-level code besides imports, test.use and test(`);
    else if (p.use.length > 1) bad(p.use[1].line, 'unclassified', `${which}: more than one test.use`);
  }
  // 1. imports
  if (JSON.stringify(b.imports) !== JSON.stringify(a.imports)) bad(1, 'unclassified', 'the imports changed');
  // 2. header and unobservable notes
  if (JSON.stringify(b.header) !== JSON.stringify(a.header)) {
    const line = a.lines.findIndex((l) => HEADER.test(l)) + 1 || 1;
    if (refresh) ok(line, 'header', `${b.header.join(' | ') || '(none)'} → ${a.header.join(' | ') || '(none)'}`);
    else bad(line, 'changed-identity', 'the // regression: header changed');
  }
  const known = b.unobservable.map((u) => u.text);
  for (const u of a.unobservable) {
    const at = known.indexOf(u.text);
    if (at >= 0) known.splice(at, 1); else bad(u.line, 'added-unobservable', u.text);
  }
  // 3. identity: test.use, title, tags
  if (JSON.stringify(b.use.map((u) => u.text)) !== JSON.stringify(a.use.map((u) => u.text))) bad(a.use[0]?.line ?? 1, 'changed-identity', 'test.use changed');
  // 4. markers anywhere in the code
  const bm = markers(b.toks).map((m) => `${m.name}\0${b.lines[m.line - 1]?.trim()}`);
  for (const m of markers(a.toks)) {
    const key = `${m.name}\0${a.lines[m.line - 1]?.trim()}`;
    const at = bm.indexOf(key);
    if (at >= 0) bm.splice(at, 1); else bad(m.line, 'added-marker', `.${m.name}(`);
  }
  if (weakened.some((w) => w.kind === 'unclassified' && /^(before|after):/.test(w.detail))) return done();
  const [bt] = b.tests;
  const [at] = a.tests;
  if (bt.title !== at.title) bad(at.line, 'changed-identity', `title ${bt.title} → ${at.title}`);
  if (bt.details !== at.details) bad(at.line, 'changed-identity', `details (tags) ${bt.details} → ${at.details}`);
  if (bt.params !== at.params) bad(at.line, 'unclassified', 'the test function parameters changed');
  // 5. control flow
  const bcf = controlFlow(bt.toks);
  const acf = controlFlow(at.toks);
  if (acf.length > bcf.length) {
    const old = bcf.map((tk) => b.lines[tk.line - 1]?.trim());
    const fresh = acf.find((tk) => { const k = old.indexOf(a.lines[tk.line - 1]?.trim()); if (k >= 0) { old.splice(k, 1); return false; } return true; });
    bad(fresh?.line ?? at.line, 'unclassified', `control flow added (${fresh?.t ?? '?'})`);
  }
  // 6. the body, statement by statement
  compareBody(bt.body, at.body, bad, ok);
  return done();
}

function compareBody(before, after, bad, ok) {
  const used = new Set();
  let j = 0;
  const take = (k) => { used.add(k); j = Math.max(j, k + 1); };
  const find = (from, to, pred) => { for (let k = from; k < to; k += 1) if (!used.has(k) && pred(after[k])) return k; return -1; };
  for (const s of before) {
    if (s.kind === 'marker') continue;
    if (s.kind === 'assertion') { matchAssertion(s, after, { find, take, used, j: () => j }, bad, ok); continue; }
    let k = find(j, after.length, (x) => x.kind === s.kind && x.text === s.text);
    if (k >= 0) { take(k); continue; }
    k = find(j, after.length, (x) => x.kind === s.kind && s.kind !== 'other' && x.masked === s.masked && (s.kind !== 'binding' || x.name === s.name));
    if (k >= 0) {
      take(k);
      const loose = loosenedLocator(s.segs, after[k].segs);
      if (loose) bad(after[k].line, 'loosened-matcher', loose);
      else ok(after[k].line, 'retargeted', `${s.text} → ${after[k].text}`);
      continue;
    }
    k = find(0, j, (x) => x.kind === s.kind && x.text === s.text);
    if (k >= 0) { used.add(k); bad(after[k].line, 'unclassified', 'reordered statement'); continue; }
    bad(s.line, 'unclassified', `${s.kind === 'action' ? 'removed action' : 'removed statement'}: ${s.text}`);
  }
  after.forEach((x, k) => {
    if (used.has(k) || x.kind === 'marker' || x.kind === 'binding') return;
    if (x.kind === 'assertion') ok(x.line, 'added-assertion', x.text);
    else if (x.kind === 'action') ok(x.line, 'added-action', x.text);
    else if (x.kind === 'wait') ok(x.line, 'added-wait', x.text);
    else bad(x.line, 'unclassified', `added statement: ${x.text}`);
  });
}

/** One before assertion against the after body: the best counterpart from the pointer on, by the plan's order. */
function matchAssertion(s, after, { find, take, used, j }, bad, ok) {
  const x = s.assertion;
  const same = (y, ...keys) => keys.every((key) => JSON.stringify(x[key]) === JSON.stringify(y[key]));
  const shape = ['soft', 'poll', 'not', 'matcher'];
  const rules = [
    [(y) => same(y, 'awaited', ...shape, 'subject', 'data') && JSON.stringify(x.options) === JSON.stringify(y.options), null],
    [(y) => same(y, 'awaited', ...shape, 'subject', 'data') && withoutTimeout(x.options) === withoutTimeout(y.options), 'timeout'],
    [(y) => same(y, ...shape, 'subject', 'data') && y.awaited !== x.awaited, 'unclassified'],
    [(y) => same(y, 'awaited', ...shape, 'subject') && JSON.stringify(x.data) !== JSON.stringify(y.data), 'changed-value'],
    [(y) => same(y, 'awaited', ...shape, 'subject', 'data'), 'changed-tolerance'],
    [(y) => same(y, 'subject') && y.matcher.startsWith('to'), 'loosened-matcher'],
    [(y) => same(y, 'awaited', ...shape, 'data') && withoutTimeout(x.options) === withoutTimeout(y.options), 'retargeted'],
  ];
  const isA = (pred) => (y) => y.kind === 'assertion' && pred(y.assertion);
  for (const [pred, kind] of rules) {
    const k = find(j(), after.length, isA(pred));
    if (k < 0) continue;
    take(k);
    const y = after[k];
    if (kind === null) return;
    if (kind === 'timeout') ok(y.line, 'timeout', `${x.options.timeout ?? '(none)'} → ${y.assertion.options.timeout ?? '(none)'}`);
    else if (kind === 'retargeted') {
      const loose = loosenedLocator(x.subjectSegs, y.assertion.subjectSegs);
      if (loose) bad(y.line, 'loosened-matcher', loose);
      else ok(y.line, 'retargeted', `${x.subject} → ${y.assertion.subject}`);
    } else if (kind === 'unclassified') bad(y.line, 'unclassified', 'dropped or added await');
    else if (kind === 'loosened-matcher') bad(y.line, kind, `${x.not ? 'not.' : ''}${x.matcher} → ${y.assertion.not ? 'not.' : ''}${y.assertion.matcher}`);
    else if (kind === 'changed-value') bad(y.line, kind, `${x.data.join(', ')} → ${y.assertion.data.join(', ')}`);
    else bad(y.line, kind, `${JSON.stringify(x.options)} → ${JSON.stringify(y.assertion.options)}`);
    return;
  }
  const back = find(0, j(), isA((y) => same(y, 'awaited', ...shape, 'subject', 'data')));
  if (back >= 0) { used.add(back); bad(after[back].line, 'unclassified', 'reordered assertion'); return; }
  bad(s.line, 'removed-assertion', s.text);
}

// ---------------------------------------------------------------------------------------------
// CLI

const USAGE = 'usage: node .claude/lib/regression/weaken-check.mjs <before> <after> [--refresh] [--json]';

export function main(argv = process.argv.slice(2)) {
  const files = argv.filter((a) => !a.startsWith('--'));
  const flags = argv.filter((a) => a.startsWith('--'));
  const unknown = flags.find((f) => f !== '--refresh' && f !== '--json');
  if (unknown || files.length !== 2) { console.error(`weaken-check: ${unknown ? `unknown argument ${unknown}` : 'two files expected'}\n${USAGE}`); return 2; }
  const texts = [];
  for (const f of files) {
    try { texts.push(fs.readFileSync(f, 'utf8')); } catch (err) { console.error(`weaken-check: unreadable — ${f} (${err.code ?? err.message})`); return 2; }
  }
  const r = weakenCheck(texts[0], texts[1], { refresh: flags.includes('--refresh') });
  if (flags.includes('--json')) console.log(JSON.stringify({ ok: r.ok, weakened: r.weakened, allowed: r.allowed }, null, 2));
  else {
    for (const w of r.weakened) console.log(`weakened: ${w.line}: ${w.kind} — ${w.detail}`);
    for (const w of r.allowed) console.log(`allowed: ${w.line}: ${w.kind} — ${w.detail}`);
    console.log(`weaken-check: ${r.ok ? 'ok' : `refused (${r.weakened.length})`}`);
  }
  return r.ok ? 0 : 1;
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    process.exitCode = main();
  } catch (err) {
    console.error(`weaken-check: ${err.message}`);
    process.exitCode = 2;
  }
}
