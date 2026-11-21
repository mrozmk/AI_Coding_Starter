// Delivery plan for `.agents/backlog.md`: the only scheduler of the harness. Simulates the strict
// phases CORE → MUST → COULD once, event-driven, in velocity-independent units (1 unit = the time a
// full-share person needs for 1 point), then scales the result to a pessimistic and an optimal
// velocity. Writes `.agents/backlog/delivery-plan.md` (or prints it). No calendar dates, no money.
// Node builtins only — ships to every downstream.
//
//   node .claude/lib/delivery-plan.mjs [--root <dir>] [--mode solo|team] [--developers <n>]
//        [--core-developers auto|0|1] [--sessions <n>] [--tl-share <0..1>] [--json] [--write]
//   exit 0 = plan computed · 1 = the backlog has errors / legacy backlog · 2 = usage, missing
//   backlog, invalid profile or config value

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  backlogFingerprint, byIdAsc, chainPaths, checkAgainstRoot, NO_CORE_WARNING, parseBacklog, readBacklogFiles,
  readIfExists, SCOPES, SIZE_POINTS, writeAtomic,
} from './backlog-check.mjs';

export const DEFAULTS = {
  mode: 'team',
  velocity: { pessimistic: 64, optimal: 96, sprint_days: 10 },
  solo: { sessions: 3 },
  team: { developers: 2, developer_sessions: 3, tl_core_sessions: 3, tl_scale_sessions: 2,
          tl_scale_share: 0.5, core_developers: 'auto' },
};

const EPS = 1e-9;
// "+ 1" is recommended when it ends CORE at or below this share of "Tech Lead alone".
const PLUS_ONE_SHARE = 0.8;
const FIRST_SCALE_SPRINT_MIN = 0.7;
const LONGEST_CHAIN_SHARE = 0.6;
const PLAN_FILE = path.join('.agents', 'backlog', 'delivery-plan.md');
const VARIANTS = ['optimal', 'pessimistic'];
// When an outside row is needed — a group heading in the plan and the `when` value of `--json`.
const OUTSIDE_WHEN = { core: 'before CORE', inCore: 'during CORE', solo: 'after CORE', scale: 'during scale', follows: 'follows developer work', none: 'no Task named' };
const CORE_LABEL = { '+1': 'Tech Lead + 1', alone: 'Tech Lead alone' };

const round3 = (x) => Math.round(x * 1000) / 1000;
const fmt1 = (x) => (Math.abs(x) < 0.05 ? 0 : x).toFixed(1);
const taskPts = (t) => (Number.isFinite(t.pts) ? t.pts : SIZE_POINTS[t.size] ?? 0);

// ---------------------------------------------------------------------------------------------
// Config
// ---------------------------------------------------------------------------------------------

const isMap = (v) => v !== null && typeof v === 'object' && !Array.isArray(v);

function validateConfig(c) {
  const bad = (key, value, rule) => `invalid delivery.${key}: ${JSON.stringify(value)} — ${rule}`;
  if (!['solo', 'team'].includes(c.mode)) return bad('mode', c.mode, 'must be solo or team');
  for (const k of ['pessimistic', 'optimal', 'sprint_days']) {
    const v = c.velocity[k];
    if (typeof v !== 'number' || !Number.isFinite(v) || v <= 0) return bad(`velocity.${k}`, v, 'must be a positive number');
  }
  if (c.velocity.pessimistic > c.velocity.optimal) return bad('velocity.pessimistic', c.velocity.pessimistic, 'must not exceed velocity.optimal');
  const sessions = [['solo.sessions', c.solo.sessions], ['team.developer_sessions', c.team.developer_sessions],
    ['team.tl_core_sessions', c.team.tl_core_sessions], ['team.tl_scale_sessions', c.team.tl_scale_sessions]];
  for (const [k, v] of sessions) if (!Number.isInteger(v) || v < 1 || v > 6) return bad(k, v, 'must be an integer from 1 to 6');
  if (!Number.isInteger(c.team.developers) || c.team.developers < 1) return bad('team.developers', c.team.developers, 'must be an integer ≥ 1');
  const share = c.team.tl_scale_share;
  if (typeof share !== 'number' || !Number.isFinite(share) || share <= 0 || share > 1) return bad('team.tl_scale_share', share, 'must be a number in (0, 1]');
  if (!['auto', 0, 1].includes(c.team.core_developers)) return bad('team.core_developers', c.team.core_developers, 'must be auto, 0 or 1');
  return null;
}

const numberFlag = (v) => (v === undefined ? undefined : /^-?(\d+(\.\d*)?|\.\d+)$/.test(v) ? Number(v) : v);
const coreDevelopers = (v) => (v === '0' || v === 0 ? 0 : v === '1' || v === 1 ? 1 : v);

/**
 * `DEFAULTS` ⊕ `.claude/project-profile.json` → `delivery` ⊕ flags (`{ mode, developers,
 * coreDevelopers, sessions, tlShare }`, raw strings). `--sessions` sets `solo.sessions` in solo mode and
 * `team.developer_sessions` in team mode. Returns `{ config }` or `{ error }` (exit 2).
 */
export function loadConfig(root, flags = {}) {
  const config = structuredClone(DEFAULTS);
  const text = readIfExists(path.join(root, '.claude', 'project-profile.json'));
  if (text !== null) {
    let profile;
    try { profile = JSON.parse(text); } catch (err) { return { error: `.claude/project-profile.json is not valid JSON: ${err.message}` }; }
    const d = isMap(profile) ? profile.delivery : undefined;
    if (d !== undefined) {
      if (!isMap(d)) return { error: `invalid delivery: ${JSON.stringify(d)} — must be an object` };
      if (d.mode !== undefined) config.mode = d.mode;
      for (const group of ['velocity', 'solo', 'team']) {
        if (d[group] === undefined) continue;
        if (!isMap(d[group])) return { error: `invalid delivery.${group}: ${JSON.stringify(d[group])} — must be an object` };
        for (const k of Object.keys(DEFAULTS[group])) if (d[group][k] !== undefined) config[group][k] = d[group][k];
      }
    }
  }
  if (flags.mode !== undefined) config.mode = flags.mode;
  if (flags.developers !== undefined) config.team.developers = numberFlag(flags.developers);
  if (flags.coreDevelopers !== undefined) config.team.core_developers = flags.coreDevelopers;
  if (flags.sessions !== undefined) {
    if (config.mode === 'solo') config.solo.sessions = numberFlag(flags.sessions);
    else config.team.developer_sessions = numberFlag(flags.sessions);
  }
  if (flags.tlShare !== undefined) config.team.tl_scale_share = numberFlag(flags.tlShare);
  config.team.core_developers = coreDevelopers(config.team.core_developers);
  const error = validateConfig(config);
  return error ? { error } : { config };
}

// ---------------------------------------------------------------------------------------------
// Engine
// ---------------------------------------------------------------------------------------------

/** Ready-Task order: critical first, then the longest chain, then id. */
const priority = (a, b) => Number(b.critical) - Number(a.critical) || b.chain - a.chain || byIdAsc(a.id, b.id);

/**
 * Event-driven simulation of one phase set. `tasks` = `[{ id, pts, deps, node, critical, chain }]`,
 * `people` = `[{ name, share, sessions }]`, `t0` = start in units. A person's share is split evenly
 * over their busy sessions. Returns `{ end, records, overlaps, intervals }` — records
 * `{ id, person, session, start, end }` (session 1-based), intervals `{ start, end, load }` where
 * load = Σ share of the people with at least one busy session.
 */
export function simulate(tasks, people, t0 = 0) {
  const ids = new Set(tasks.map((t) => t.id));
  const order = [...tasks].sort(priority);
  const sessions = [];
  people.forEach((p, pi) => { for (let s = 0; s < p.sessions; s += 1) sessions.push({ person: pi, index: s, run: null }); });
  const busy = people.map(() => 0);
  const started = new Set();
  const done = new Set();
  const records = [];
  const overlaps = [];
  const intervals = [];
  const rateIf = (s) => people[s.person].share / (busy[s.person] + 1);
  let t = t0;
  while (done.size < tasks.length) {
    // Assign one Task at a time; speeds change only here and at completion.
    for (;;) {
      const ready = order.filter((x) => !started.has(x.id) && x.deps.every((d) => !ids.has(d) || done.has(d)));
      const idle = sessions.filter((s) => !s.run);
      if (!ready.length || !idle.length) break;
      idle.sort((a, b) => (rateIf(b) - rateIf(a) > EPS ? 1 : rateIf(a) - rateIf(b) > EPS ? -1 : 0) || a.person - b.person || a.index - b.index);
      const session = idle[0];
      const running = sessions.filter((s) => s.run);
      const collides = (x) => x.node !== null && running.some((s) => s.run.task.node === x.node);
      let pick = ready.find((x) => !collides(x));
      if (!pick) {
        pick = ready[0];
        for (const s of running) if (s.run.task.node === pick.node) overlaps.push({ node: pick.node, a: s.run.task.id, b: pick.id });
      }
      session.run = { task: pick, remaining: pick.pts, start: t };
      busy[session.person] += 1;
      started.add(pick.id);
    }
    const running = sessions.filter((s) => s.run);
    if (!running.length) throw new Error(`no runnable Task among ${[...ids].filter((i) => !done.has(i)).join(', ')} — dependency cycle?`);
    const rate = (s) => people[s.person].share / busy[s.person];
    const dt = Math.min(...running.map((s) => s.run.remaining / rate(s)));
    if (dt > 0) intervals.push({ start: t, end: t + dt, load: people.reduce((a, p, i) => a + (busy[i] > 0 ? p.share : 0), 0) });
    for (const s of running) s.run.remaining -= rate(s) * dt;
    t += dt;
    for (const s of running) {
      if (s.run.remaining > EPS) continue;
      records.push({ id: s.run.task.id, person: people[s.person].name, session: s.index + 1, start: s.run.start, end: t });
      done.add(s.run.task.id);
      busy[s.person] -= 1;
      s.run = null;
    }
  }
  return { end: t, records, overlaps, intervals };
}

// ---------------------------------------------------------------------------------------------
// Plan
// ---------------------------------------------------------------------------------------------

/** `chain` (own points + the longest chain of dependents inside the set) for every Task of `set`. */
function chainValues(set) {
  const ids = new Set(set.map((t) => t.id));
  const succ = new Map(set.map((t) => [t.id, []]));
  for (const t of set) for (const d of t.deps) if (ids.has(d)) succ.get(d).push(t.id);
  const byId = new Map(set.map((t) => [t.id, t]));
  const memo = new Map();
  const longest = (id) => {
    if (memo.has(id)) return memo.get(id);
    const v = byId.get(id).pts + Math.max(0, ...succ.get(id).map(longest));
    memo.set(id, v);
    return v;
  };
  set.forEach((t) => longest(t.id));
  return { memo, succ };
}

/** The longest chain of a set: the head with the highest `chain` (ties → lowest id), walked down. */
function longestChain(set, { memo, succ }) {
  let head = null;
  for (const t of set) if (!head || memo.get(t.id) > memo.get(head) || (memo.get(t.id) === memo.get(head) && byIdAsc(t.id, head) < 0)) head = t.id;
  const byId = new Map(set.map((t) => [t.id, t]));
  const ids = [];
  for (let cur = head; cur;) {
    ids.push(cur);
    const want = memo.get(cur) - byId.get(cur).pts;
    cur = succ.get(cur).filter((s) => memo.get(s) === want).sort(byIdAsc)[0] ?? null;
  }
  return { ids, pts: head ? memo.get(head) : 0 };
}

/** Tasks tracing an activity of a live critical flow, plus everything they transitively depend on. */
function criticalIds(live, flows) {
  const acts = new Set((flows ?? []).filter((f) => f.critical && !f.withdrawn).flatMap((f) => f.activities.filter((a) => !a.withdrawn).map((a) => a.id)));
  const byId = new Map(live.map((t) => [t.id, t]));
  const out = new Set();
  const walk = (t) => { if (out.has(t.id)) return; out.add(t.id); for (const d of t.deps) if (byId.has(d)) walk(byId.get(d)); };
  live.filter((t) => t.traces.some((x) => acts.has(x))).forEach(walk);
  return out;
}

const scaleDays = (units, v, sprintDays) => (units * sprintDays) / v;

/** `fn(points per person per sprint)` for both velocities → `{ optimal, pessimistic }`. */
const perVariant = (velocity, fn) => Object.fromEntries(VARIANTS.map((k) => [k, fn(velocity[k])]));

/** `{ days, weeks, sprints, sprint }` of a duration; `sprint` = the sprint in which `endUnits` falls. */
function scaled(units, v, sprintDays, endUnits = units) {
  const days = scaleDays(units, v, sprintDays);
  const endDays = scaleDays(endUnits, v, sprintDays);
  return {
    units: round3(units), days: round3(days), weeks: round3(days / 5), sprints: round3(days / sprintDays),
    sprint: endUnits > EPS ? Math.ceil(endDays / sprintDays - EPS) : 0,
  };
}

const overlap = (s, e, from, to) => Math.max(0, Math.min(e, to) - Math.max(s, from));
const capacityIn = (membership, s, e) => membership.reduce((a, m) => a + m.share * overlap(s, e, m.from, m.to), 0);

/** Per Scope: the Tasks still to do in the simulator's shape, with their chain values. */
function phaseSets(work, critical) {
  const sets = {};
  for (const scope of SCOPES) {
    const raw = work.filter((t) => t.scope === scope).map((t) => ({ ...t, pts: taskPts(t) }));
    const cv = chainValues(raw);
    sets[scope] = { tasks: raw.map((t) => ({ id: t.id, pts: t.pts, deps: t.deps, node: t.node, critical: critical.has(t.id), chain: cv.memo.get(t.id) })), cv, raw };
  }
  return sets;
}

/** The teams, the two CORE variants (team mode) and the three simulated phases. */
function runPhases(sets, config) {
  const { velocity, team } = config;
  const dev = (i) => ({ name: `Dev ${i}`, share: 1, sessions: team.developer_sessions });
  const solo = config.mode === 'solo';
  const soloTeam = [{ name: 'Developer', share: 1, sessions: config.solo.sessions }];
  const aloneTeam = [{ name: 'Tech Lead', share: 1, sessions: team.tl_core_sessions }];
  const plusOneTeam = [...aloneTeam, dev(1)];
  const scaleTeam = [{ name: 'Tech Lead', share: team.tl_scale_share, sessions: team.tl_scale_sessions },
    ...Array.from({ length: team.developers }, (_, i) => dev(i + 1))];

  let core = null;
  let coreTeam = soloTeam;
  let coreRun;
  if (solo) coreRun = simulate(sets.CORE.tasks, soloTeam, 0);
  else {
    const alone = simulate(sets.CORE.tasks, aloneTeam, 0);
    const plusOne = simulate(sets.CORE.tasks, plusOneTeam, 0);
    const ruleSaysPlusOne = sets.CORE.tasks.length > 0 && plusOne.end <= PLUS_ONE_SHARE * alone.end + EPS;
    const recommendation = ruleSaysPlusOne ? '+1' : 'alone';
    const override = team.core_developers === 'auto' ? null : team.core_developers === 1 ? '+1' : 'alone';
    const chosen = override ?? recommendation;
    let reason;
    if (override) reason = `core_developers = ${team.core_developers} (override)`;
    else if (!sets.CORE.tasks.length) reason = 'no CORE Task left — nothing to split';
    else if (ruleSaysPlusOne) reason = `+ 1 ends CORE at ≤ ${PLUS_ONE_SHARE * 100} % of Tech Lead alone`;
    else reason = `+ 1 does not cut CORE by ${Math.round((1 - PLUS_ONE_SHARE) * 100)} % or more`;
    const variant = (run) => ({ units: round3(run.end), ...perVariant(velocity, (v) => scaled(run.end, v, velocity.sprint_days)) });
    core = { alone: variant(alone), plusOne: variant(plusOne), recommendation, chosen, decidedBy: override ? 'override' : 'rule', reason };
    coreTeam = chosen === '+1' ? plusOneTeam : aloneTeam;
    coreRun = chosen === '+1' ? plusOne : alone;
  }
  const laterTeam = solo ? soloTeam : scaleTeam;
  const mustRun = simulate(sets.MUST.tasks, laterTeam, coreRun.end);
  const couldRun = simulate(sets.COULD.tasks, laterTeam, mustRun.end);
  return { solo, core, coreTeam, laterTeam, runs: { CORE: coreRun, MUST: mustRun, COULD: couldRun } };
}

/** One row per Task: who runs it, when (units and days per velocity). Sorted by start, then id. */
function scheduleOf(records, byId, critical, velocity) {
  return records.map((r) => {
    const t = byId.get(r.id);
    return {
      id: r.id, title: t.title, scope: t.scope, pts: taskPts(t), node: t.node, critical: critical.has(r.id),
      person: r.person, session: r.session, start: round3(r.start), end: round3(r.end),
      ...perVariant(velocity, (v) => ({ start: round3(scaleDays(r.start, v, velocity.sprint_days)), end: round3(scaleDays(r.end, v, velocity.sprint_days)) })),
    };
  }).sort((a, b) => a.start - b.start || byIdAsc(a.id, b.id));
}

/**
 * Per velocity, one record per sprint: capacity by team membership, progress by busy intervals,
 * done by the Tasks finishing in it. One sprint = `v` units.
 */
function sprintsOf({ membership, intervals, records, byId, velocity, end }) {
  return perVariant(velocity, (len) => {
    const n = end > EPS ? Math.ceil(end / len - EPS) : 0;
    const sprintOf = (units) => Math.max(1, Math.ceil(units / len - EPS));
    return Array.from({ length: n }, (_, i) => {
      const s = i * len;
      const e = s + len;
      const capacity = capacityIn(membership, s, e);
      const progress = intervals.reduce((a, x) => a + x.load * overlap(s, e, x.start, x.end), 0);
      const finishing = records.filter((r) => sprintOf(r.end) === i + 1);
      return {
        sprint: i + 1, capacity: round3(capacity), progress: round3(progress),
        done: finishing.reduce((a, r) => a + taskPts(byId.get(r.id)), 0),
        utilisation: capacity > EPS ? round3(progress / capacity) : 0,
        ids: finishing.map((r) => r.id).sort(byIdAsc),
      };
    });
  });
}

/**
 * Outside rows that still gate live, not-done work: the first day one of their `Needed by` Tasks
 * starts, and the day the last open `Starts after` Task ends — from then the other team can begin
 * (`canStart` 0 = every Task it waited for is done; `null` = the row names none).
 */
function outsideRows(rows, schedule, byId, solo, daysOf) {
  const slot = new Map(schedule.map((s) => [s.id, s]));
  return rows.map((x) => {
    const tasks = x.neededBy.filter((id) => slot.has(id)).sort(byIdAsc);
    if (x.neededBy.length > 0 && tasks.length === 0) return null;
    const first = tasks.length ? Math.min(...tasks.map((id) => slot.get(id).start)) : null;
    const named = x.startsAfter ?? [];
    const waits = named.filter((id) => slot.has(id)).sort(byIdAsc);
    const canStart = waits.length ? Math.max(...waits.map((id) => slot.get(id).end)) : named.length ? 0 : null;
    let when = OUTSIDE_WHEN.none;
    // Needed by CORE: before CORE starts, unless the item itself waits for a CORE Task still open.
    if (tasks.some((id) => byId.get(id).scope === 'CORE')) when = waits.length ? OUTSIDE_WHEN.inCore : OUTSIDE_WHEN.core;
    else if (tasks.length) when = solo ? OUTSIDE_WHEN.solo : OUTSIDE_WHEN.scale;
    else if (named.length) when = OUTSIDE_WHEN.follows;
    return {
      id: x.id, owner: x.owner, item: x.item, neededBy: tasks, when,
      firstStart: first === null ? null : round3(first), firstDay: first === null ? null : daysOf(first),
      startsAfter: waits, canStart: canStart === null ? null : round3(canStart), canStartDay: canStart === null ? null : daysOf(canStart),
    };
  }).filter(Boolean).sort((a, b) => byIdAsc(a.id, b.id));
}

function planWarnings({ live, work, byId, outside, sets, phases, sprints, membership, laterTeam, solo, velocity, coreEnd, planEnd }) {
  const warnings = [];
  if (live.length && !live.some((t) => t.scope === 'CORE')) warnings.push(NO_CORE_WARNING);
  for (const x of outside.filter((o) => o.when === OUTSIDE_WHEN.core)) {
    const coreTasks = x.neededBy.filter((id) => byId.get(id).scope === 'CORE');
    warnings.push(`outside ${x.id} (${x.owner}: ${x.item}) is needed by CORE Task${coreTasks.length > 1 ? 's' : ''} ${coreTasks.join(', ')} — it must be ready before CORE starts`);
  }
  // The schedule does not wait for other teams: an item that can begin only when (or after) the
  // first Task needing it starts has no time left to be done.
  const days = (d) => `day ${fmt1(d.pessimistic)} / ${fmt1(d.optimal)}`;
  for (const x of outside) {
    if (!x.startsAfter.length || x.firstStart === null) continue;
    if (x.canStart < x.firstStart - EPS) {
      if (x.when === OUTSIDE_WHEN.inCore) warnings.push(`outside ${x.id} (${x.owner}: ${x.item}) is needed by CORE work (${x.neededBy.join(', ')}) from ${days(x.firstDay)} and can start on ${days(x.canStartDay)} (pessimistic / optimal — after ${x.startsAfter.join(', ')}) — it must be done in between`);
      continue;
    }
    warnings.push(`outside ${x.id} (${x.owner}: ${x.item}) can start only on ${days(x.canStartDay)} (pessimistic / optimal — after ${x.startsAfter.join(', ')}), yet ${x.neededBy.join(', ')} need${x.neededBy.length > 1 ? '' : 's'} it from ${days(x.firstDay)} — no time left for it; the plan does not wait for other teams`);
  }
  const blocked = work.filter((t) => t.status === 'BLOCKED').map((t) => t.id).sort(byIdAsc);
  if (blocked.length) warnings.push(`${blocked.length} BLOCKED Task${blocked.length > 1 ? 's are' : ' is'} scheduled as if unblocked: ${blocked.join(', ')} — the plan assumes each blocker is cleared before the Task's start day`);
  if (!solo && sets.MUST.tasks.length) {
    const scaleSessions = laterTeam.reduce((a, p) => a + p.sessions, 0);
    const mustIds = new Set(sets.MUST.tasks.map((t) => t.id));
    const ready = sets.MUST.tasks.filter((t) => t.deps.every((d) => !mustIds.has(d))).length;
    if (ready < scaleSessions) warnings.push(`CORE unlocks too little parallel work: ${ready} ready for ${scaleSessions} sessions at the join — scale sessions will idle`);
  }
  if (!solo && planEnd > coreEnd + EPS) {
    const len = velocity.optimal;
    const k = Math.floor(coreEnd / len + EPS) + 1;
    const sp = sprints.optimal[k - 1];
    // Capacity only up to the end of the plan: time after the last Task is not idle scale capacity.
    const capacity = capacityIn(membership, (k - 1) * len, Math.min(k * len, planEnd));
    if (sp && capacity > EPS && sp.progress / capacity < FIRST_SCALE_SPRINT_MIN) {
      warnings.push(`first scale sprint (sprint ${k}, optimal) is ${Math.round((100 * sp.progress) / capacity)} % used — progress ${fmt1(sp.progress)} of capacity ${fmt1(capacity)} pts`);
    }
  }
  const mustPts = phases[1].points;
  const mustChain = sets.MUST.tasks.length ? longestChain(sets.MUST.raw, sets.MUST.cv) : { ids: [], pts: 0 };
  if (mustPts > 0 && mustChain.pts > LONGEST_CHAIN_SHARE * mustPts) {
    warnings.push(`longest MUST chain ${mustChain.ids.join(' → ')} = ${mustChain.pts} pts, ${Math.round((100 * mustChain.pts) / mustPts)} % of ${mustPts} MUST pts — too sequential for parallel sessions`);
  }
  for (const p of phases) for (const o of p.overlaps) warnings.push(`Node ${o.node}: ${o.a} and ${o.b} run at the same time in ${p.name} (no other ready Task) — expect merge contention`);
  return warnings;
}

/**
 * The whole plan from a parsed (and checked) backlog, the discovery flows and a validated config.
 * Pure: no I/O. Everything time-like is in units, plus days per velocity.
 */
export function buildPlan({ backlog, flows, config }) {
  const { velocity } = config;
  const sd = velocity.sprint_days;
  const live = backlog.tasks.filter((t) => !t.withdrawn);
  const work = live.filter((t) => t.status !== 'DONE');
  const byId = new Map(work.map((t) => [t.id, t]));
  const critical = criticalIds(work, flows);
  const sets = phaseSets(work, critical);
  const { solo, core, coreTeam, laterTeam, runs } = runPhases(sets, config);
  const coreEnd = runs.CORE.end;
  const mustEnd = runs.MUST.end;
  const couldEnd = runs.COULD.end;
  const daysOf = (units) => perVariant(velocity, (v) => round3(scaleDays(units, v, sd)));

  const teams = { CORE: coreTeam, MUST: laterTeam, COULD: laterTeam };
  const starts = { CORE: 0, MUST: coreEnd, COULD: mustEnd };
  const phases = SCOPES.map((name) => ({
    name,
    team: teams[name].map((p) => ({ ...p })),
    start: round3(starts[name]),
    end: round3(runs[name].end),
    days: { start: daysOf(starts[name]), end: daysOf(runs[name].end) },
    tasks: sets[name].tasks.map((t) => t.id).sort(byIdAsc),
    points: sets[name].tasks.reduce((a, t) => a + t.pts, 0),
    overlaps: runs[name].overlaps,
  }));

  const records = SCOPES.flatMap((name) => runs[name].records);
  const schedule = scheduleOf(records, byId, critical, velocity);
  // The CORE team until the join, the later team from it on (solo: one team throughout).
  const membership = solo
    ? laterTeam.map((p) => ({ share: p.share, from: 0, to: Infinity }))
    : [...coreTeam.map((p) => ({ share: p.share, from: 0, to: coreEnd })), ...laterTeam.map((p) => ({ share: p.share, from: coreEnd, to: Infinity }))];
  const sprints = sprintsOf({ membership, intervals: SCOPES.flatMap((name) => runs[name].intervals), records, byId, velocity, end: couldEnd });
  const outside = outsideRows(backlog.outside ?? [], schedule, byId, solo, daysOf);
  const warnings = planWarnings({ live, work, byId, outside, sets, phases, sprints, membership, laterTeam, solo, velocity, coreEnd, planEnd: couldEnd });

  const hasTail = couldEnd - mustEnd > EPS;
  const summary = { mode: config.mode, units: { core: round3(coreEnd), development: round3(mustEnd), couldTail: round3(couldEnd - mustEnd), total: round3(couldEnd) }, core };
  Object.assign(summary, perVariant(velocity, (v) => ({
    core: scaled(coreEnd, v, sd), development: scaled(mustEnd, v, sd),
    // An empty tail ends in no sprint.
    couldTail: scaled(couldEnd - mustEnd, v, sd, hasTail ? couldEnd : 0), total: scaled(couldEnd, v, sd),
    join: solo ? null : scaled(coreEnd, v, sd),
  })));

  // --- render-only data
  const people = [...new Set([...coreTeam, ...laterTeam].map((p) => p.name))];
  const order = [];
  for (const name of people) {
    const mine = schedule.filter((s) => s.person === name);
    for (const session of [...new Set(mine.map((s) => s.session))].sort((a, b) => a - b)) {
      order.push({ person: name, session, ids: mine.filter((s) => s.session === session).map((s) => s.id) });
    }
  }
  const anyById = new Map(backlog.tasks.map((t) => [t.id, t]));
  const chains = [...chainPaths(backlog.tasks)].map(([token, ch]) => ({
    token, ids: ch.ids,
    pts: ch.ids.filter((id) => !anyById.get(id)?.withdrawn).reduce((a, id) => a + taskPts(anyById.get(id)), 0),
  }));

  return {
    config, summary, warnings, phases, schedule, sprints, outside,
    meta: { backlogSha: backlogFingerprint(backlog.raw ?? '', backlog.files ?? []), order, chains, teams: { core: coreTeam, later: laterTeam } },
  };
}

/** The `--json` view: the analyst's input. */
export const planJson = (plan) => {
  const { config, summary, warnings, phases, schedule, sprints, outside } = plan;
  return { config, summary, warnings, phases, schedule, sprints, outside };
};

// ---------------------------------------------------------------------------------------------
// Rendering
// ---------------------------------------------------------------------------------------------

const cellText = (s) => String(s ?? '').replace(/\|/g, '\\|');
const teamText = (team) => team.map((p) => `${p.name}${p.share !== 1 ? ` at share ${p.share}` : ''} × ${p.sessions} session${p.sessions > 1 ? 's' : ''}`).join(' · ');
const durText = (d, tail = false) => `${fmt1(d.days)} d · ${fmt1(d.weeks)} wk · ${fmt1(d.sprints)} sprints${d.sprint ? ` (${tail ? 'ends in ' : ''}sprint ${d.sprint})` : ''}`;
const span = (x) => `${fmt1(x.start)}–${fmt1(x.end)}`;

/** Markdown of `.agents/backlog/delivery-plan.md`. */
export function renderPlan(plan) {
  const { config, summary, warnings, phases, schedule, sprints, outside, meta } = plan;
  const v = config.velocity;
  const solo = config.mode === 'solo';
  const out = [];
  out.push('# Delivery plan', '', '> Generated by delivery-plan.mjs — do not edit; rerun /setup:delivery-plan.', '');
  out.push(`**Backlog:** sha256 ${meta.backlogSha} · **Mode:** ${config.mode} · **Velocity:** ${v.pessimistic} / ${v.optimal} pts per person per sprint (${v.sprint_days} working days)`, '');
  for (const p of phases) {
    const variant = !solo && p.name === 'CORE' ? ` (${CORE_LABEL[summary.core.chosen]})` : '';
    out.push(`**Team:** ${p.name} — ${teamText(p.team)}${variant}`, '');
  }

  out.push('## Summary', '', `| | Pessimistic (${v.pessimistic}) | Optimal (${v.optimal}) |`, '|---|---|---|');
  out.push(`| CORE | ${durText(summary.pessimistic.core)} | ${durText(summary.optimal.core)} |`);
  out.push(`| Development done (CORE + MUST) | ${durText(summary.pessimistic.development)} | ${durText(summary.optimal.development)} |`);
  out.push(`| COULD tail | ${durText(summary.pessimistic.couldTail, true)} | ${durText(summary.optimal.couldTail, true)} |`);
  if (!solo) {
    out.push(`| CORE — Tech Lead alone | ${durText(summary.core.alone.pessimistic)} | ${durText(summary.core.alone.optimal)} |`);
    out.push(`| CORE — Tech Lead + 1 | ${durText(summary.core.plusOne.pessimistic)} | ${durText(summary.core.plusOne.optimal)} |`);
  }
  out.push('');
  if (!solo) {
    const c = summary.core;
    out.push(`**CORE:** ${CORE_LABEL[c.chosen]} — recommendation ${CORE_LABEL[c.recommendation]}; decided by ${c.decidedBy}: ${c.reason}.`, '');
    out.push(`**Join:** the scale team starts on day ${fmt1(summary.pessimistic.join.days)} (pessimistic) / ${fmt1(summary.optimal.join.days)} (optimal).`, '');
  } else {
    out.push('**Join:** — (solo: one person, no join point).', '');
  }

  out.push('## Warnings', '');
  if (warnings.length) warnings.forEach((w) => out.push(`- ${w}`));
  else out.push('_None._');
  out.push('');

  out.push('## Needed from other teams', '');
  if (outside.length) out.push('_First start_: the day the first Task that needs the item begins. _Can start_: the day the last Task the item waits for ends.', '');
  if (!outside.length) out.push('_Nothing — no open row in `## Outside the dev backlog`._', '');
  for (const group of Object.values(OUTSIDE_WHEN)) {
    const rows = outside.filter((x) => x.when === group);
    if (!rows.length) continue;
    out.push(`### ${group[0].toUpperCase()}${group.slice(1)}`, '', '| ID | Owner | Item | Needed by | First start — pessimistic | First start — optimal | Starts after | Can start — pessimistic | Can start — optimal |', '|---|---|---|---|---|---|---|---|---|');
    for (const x of rows) {
      const day = (k) => (x.firstDay ? `day ${fmt1(x.firstDay[k])}` : '—');
      const can = (k) => (x.canStartDay === null ? '—' : x.canStart === 0 ? 'now' : `day ${fmt1(x.canStartDay[k])}`);
      out.push(`| ${x.id} | ${cellText(x.owner)} | ${cellText(x.item)} | ${x.neededBy.join(', ') || '—'} | ${day('pessimistic')} | ${day('optimal')} | ${x.startsAfter.join(', ') || '—'} | ${can('pessimistic')} | ${can('optimal')} |`);
    }
    out.push('');
  }

  out.push('## Sprints', '');
  for (const k of VARIANTS) {
    out.push(`### ${k[0].toUpperCase()}${k.slice(1)} (${v[k]} pts per person per sprint)`, '');
    if (!sprints[k].length) { out.push('_Nothing left to schedule._', ''); continue; }
    out.push('| Sprint | Capacity | Progress | Use | Done pts | Tasks finished |', '|---|---|---|---|---|---|');
    for (const s of sprints[k]) out.push(`| ${s.sprint} | ${fmt1(s.capacity)} | ${fmt1(s.progress)} | ${Math.round(s.utilisation * 100)} % | ${s.done} | ${s.ids.join(', ') || '—'} |`);
    out.push('');
  }

  out.push('## Order per person and session', '');
  if (!meta.order.length) out.push('_Nothing left to schedule._');
  else {
    out.push('| Person · session | Tasks (start order) |', '|---|---|');
    for (const o of meta.order) out.push(`| ${o.person} · ${o.session} | ${o.ids.join(' → ')} |`);
  }
  out.push('');

  out.push('## Task schedule', '');
  if (!schedule.length) out.push('_Nothing left to schedule._');
  else {
    out.push('| Task | Title | Scope | Pts | Person · session | Days — optimal | Days — pessimistic |', '|---|---|---|---|---|---|---|');
    for (const s of schedule) out.push(`| ${s.id} | ${cellText(s.title)} | ${s.scope} | ${s.pts} | ${s.person} · ${s.session} | ${span(s.optimal)} | ${span(s.pessimistic)} |`);
  }
  out.push('');

  out.push('## Chains', '');
  if (!meta.chains.length) out.push('_No chains in the backlog._');
  else {
    out.push('Advisory — one developer, in order.', '', '| Chain | Order | Pts |', '|-------|-------|-----|');
    for (const c of meta.chains) out.push(`| ${c.token} | ${c.ids.join(' → ')} | ${c.pts} |`);
  }
  out.push('');

  out.push('## Analysis', '', '<!-- analysis:begin -->', '_Not written — run /setup:delivery-plan._', '<!-- analysis:end -->', '');
  return out.join('\n');
}

// ---------------------------------------------------------------------------------------------
// CLI
// ---------------------------------------------------------------------------------------------

const BOOL_FLAGS = new Set(['write', 'json', 'help']);
const VALUE_FLAGS = new Set(['root', 'mode', 'developers', 'core-developers', 'sessions', 'tl-share']);

/** `{ _: positionals, <flag>: true | value }`, or `null` on an unknown flag / value flag without a value. */
function parseArgs(argv) {
  const args = { _: [] };
  for (let i = 0; i < argv.length; i += 1) {
    const a = argv[i];
    if (!a.startsWith('--')) { args._.push(a); continue; }
    const key = a.slice(2);
    const next = argv[i + 1];
    if (BOOL_FLAGS.has(key)) args[key] = true;
    else if (VALUE_FLAGS.has(key) && next !== undefined && !next.startsWith('--')) { args[key] = next; i += 1; }
    else return null;
  }
  return args;
}

const USAGE = `usage: delivery-plan.mjs [--root <dir>] [--mode solo|team] [--developers <n>] [--core-developers auto|0|1] [--sessions <n>] [--tl-share <0..1>] [--json] [--write]
  --root             project root (default: cwd); reads .agents/backlog.md + its Epic files (.agents/backlog/E*.md), docs/PRD.md, docs/discovery.md, docs/architecture.md, docs/map/system.yaml, .claude/project-profile.json → delivery
  --mode             solo | team (overrides delivery.mode)
  --developers       developers who join at scale (team.developers)
  --core-developers  auto | 0 | 1 — developers beside the Tech Lead in CORE (team.core_developers)
  --sessions         sessions per person: solo.sessions in solo mode, team.developer_sessions in team mode
  --tl-share         the Tech Lead's share of a full person once the team scales, in (0, 1] (team.tl_scale_share)
  --json             print { config, summary, warnings, phases, schedule, sprints, outside }
  --write            write .agents/backlog/delivery-plan.md (creates the directory); without it the plan is printed
exit 0 = plan computed · 1 = the backlog has errors or is a legacy WP backlog (nothing written) · 2 = usage / missing backlog / invalid profile or config`;

export function main(argv = process.argv.slice(2)) {
  const args = parseArgs(argv);
  if (!args || args.help || args._.length) { console.error(USAGE); return 2; }
  const root = path.resolve(args.root ?? process.cwd());
  const json = args.json === true;
  const fail = (errors, extra = {}) => {
    if (json) console.log(JSON.stringify({ errors, ...extra }));
    else console.log(`delivery-plan: the backlog has errors — fix them first:\n${errors.map((e) => `error: ${e}`).join('\n')}`);
    return 1;
  };

  const { md, epicFiles } = readBacklogFiles(path.join(root, '.agents', 'backlog.md'));
  if (md === null || md.trim() === '') { console.error(`delivery-plan: .agents/backlog.md not found under ${root}\n${USAGE}`); return 2; }
  const parsed = parseBacklog(md, { epicFiles });
  if (parsed.legacy) {
    const msg = 'legacy WP backlog — regenerate with /setup:create-backlog';
    if (json) console.log(JSON.stringify({ errors: [msg], legacy: true })); else console.log(`delivery-plan: ${msg}`);
    return 1;
  }
  const prdNamed = parsed.sourcePrd;
  if (prdNamed && !fs.existsSync(path.resolve(root, prdNamed))) { console.error(`delivery-plan: PRD not found at ${prdNamed} (named by the backlog header)`); return 2; }
  const res = checkAgainstRoot(root, parsed);
  if (res.errors.length) return fail(res.errors, res.preScope ? { preScope: true } : res.preDetail ? { preDetail: true } : {});

  const { config, error } = loadConfig(root, { mode: args.mode, developers: args.developers, coreDevelopers: args['core-developers'], sessions: args.sessions, tlShare: args['tl-share'] });
  if (error) { console.error(`delivery-plan: ${error}`); return 2; }

  let plan;
  try { plan = buildPlan({ backlog: parsed, flows: res.inventory.flows, config }); } catch (err) { console.error(`delivery-plan: ${err.message}`); return 1; }
  const text = renderPlan(plan);
  if (args.write) {
    try { writeAtomic(path.join(root, PLAN_FILE), text); } catch (err) { console.error(`delivery-plan: cannot write ${PLAN_FILE}: ${err.message}`); return 1; }
  }
  if (json) console.log(JSON.stringify(planJson(plan)));
  else if (args.write) {
    console.log(`delivery-plan: wrote ${PLAN_FILE}`);
    for (const w of plan.warnings) console.log(`warning: ${w}`);
  } else process.stdout.write(text);
  return 0;
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    process.exitCode = main();
  } catch (err) {
    console.error(`delivery-plan: ${err.message}`);
    process.exitCode = 1;
  }
}
