// The harness-notify mod's logic, with no imports, so it runs under plain node in the team suite.
// main.js wires it to Herdr. Every path is built from the one constant SPOOL and an id that passed
// ID_RE: nothing from an entry's content ever reaches a path or a command.

export const SPOOL = ".agent-comms/outbox/herdr";   // under home(); notify.sh writes new/<id>.json
export const STALE_MS = 24 * 3600 * 1000;           // older entries are moved without a toast
export const ID_RE = /^[A-Za-z0-9_-][A-Za-z0-9._-]{0,199}$/;  // notify.sh's file id; no "." / ".." / hidden
const TERMINAL_RE = /^[A-Za-z0-9._-]{1,64}(\/[A-Za-z0-9._-]{1,64})?$/;
const ACTIONS = new Set(["agent.focus", "pane.focus"]);

export const dirs = (home) => ({
  root: `${home}/${SPOOL}`, new: `${home}/${SPOOL}/new`, done: `${home}/${SPOOL}/done`,
  alive: `${home}/${SPOOL}/.mod-alive`,
});

// idOf("<id>.json") → the id, or null for anything else (a tmp file, a hidden file, a bad name).
export function idOf(name) {
  if (typeof name !== "string" || !name.endsWith(".json")) return null;
  const id = name.slice(0, -5);
  return ID_RE.test(id) ? id : null;
}

// resolveOf("<id>.resolve") → the id: notify.sh resolve says the Operator answered it elsewhere.
export function resolveOf(name) {
  if (typeof name !== "string" || !name.endsWith(".resolve")) return null;
  const id = name.slice(0, -8);
  return ID_RE.test(id) ? id : null;
}

// plan(names) → the order of one scan over new/: every resolve marker first, then the entries, an
// entry resolved in the same round marked quiet (moved without a toast — already answered).
export function plan(names) {
  const sorted = [...names].sort();
  const resolved = sorted.map(resolveOf).filter(Boolean);
  const r = new Set(resolved);
  const entries = sorted.map((n) => ({ name: n, id: idOf(n) })).filter((e) => e.id)
    .map((e) => ({ ...e, quiet: r.has(e.id) }));
  return { resolved, entries };
}

// The move of one entry (or resolve marker) new/ → done/, as exec arguments. Throws on an id that
// did not pass ID_RE or another extension.
export function moveArgs(home, id, ext = ".json") {
  if (!ID_RE.test(id)) throw new Error(`bad spool id: ${id}`);
  if (ext !== ".json" && ext !== ".resolve") throw new Error(`bad spool extension: ${ext}`);
  const d = dirs(home);
  return ["mv", ["-f", `${d.new}/${id}${ext}`, `${d.done}/${id}${ext}`]];
}

const line = (s, n) => (typeof s === "string" ? s.replace(/[\u0000-\u001f\u007f]+/g, " ").slice(0, n) : "");

// parse(id, text, nowMs) → { item, stale } or { error }. An item is what the toast and the strip
// show: { id, title, body, action, at }.
export function parse(id, text, nowMs) {
  let e;
  try { e = JSON.parse(text); } catch { return { error: "not JSON" }; }
  if (!e || typeof e !== "object" || e.id !== id) return { error: "id does not match the file name" };
  const at = Date.parse(e.created_at);
  if (!Number.isFinite(at)) return { error: "no created_at" };
  const a = e.action, t = a && a.args && a.args.terminal;
  const action = a && ACTIONS.has(a.name) && typeof t === "string" && TERMINAL_RE.test(t)
    ? { name: a.name, args: { terminal: t } } : null;
  const item = { id, title: line(e.title, 120) || "harness", body: line(e.body, 400), action, at };
  return { item, stale: nowMs - at > STALE_MS };
}

// The notify() argument for one item: shown once, clicked → the answering session.
export function toast(item) {
  const n = { title: item.title, body: item.body, level: "warning" };
  if (item.action) n.action = item.action;
  return n;
}

// The strip's list of items not yet clicked: newest first, one per id, nothing older than a day.
export function add(list, item) { return [item, ...list.filter((i) => i.id !== item.id)]; }
export function ack(list, id) { return list.filter((i) => i.id !== id); }
export function expire(list, nowMs) { return list.filter((i) => nowMs - i.at <= STALE_MS); }
export function load(text) {
  try { const l = JSON.parse(text); return Array.isArray(l) ? l.filter((i) => i && ID_RE.test(i.id)) : []; }
  catch { return []; }
}
export function stripText(list) {
  if (!list.length) return "harness: watching";
  const first = `${list[0].title}${list[0].body ? " — " + list[0].body : ""}`;
  return `${list.length} waiting — ${first}`;   // the strip draws its own dot
}
