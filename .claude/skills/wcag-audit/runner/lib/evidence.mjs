// evidence.mjs — the finding model, planned units, per-criterion status and the verdict. finalize()
// is the only place that derives criteria, findings, barriers, manual tasks, the needs-review queue
// and the verdict; it reads only the persisted units, observations and published model items.
import { criteriaFor, criterionById, OBSOLETE_411, STATUS } from './criteria.mjs';
import { merge, barriers as clusterBarriers, fingerprint, nodeKey } from './cluster.mjs';
import { manualTasks } from './manual.mjs';

export { STATUS };

export function newRun({ urls, viewports, wcag = '2.2', level = 'AA', client = 'unknown', llm = true, tool = {} }) {
  return {
    schema: 1,
    tool,
    scope: { urls, viewports, wcag, level, client, llm, retries: [], notes: [] },
    llm,
    criteria_set: criteriaFor({ wcag, level }).map((c) => c.id),
    contributors: [],
    pages: [],
    units: [],
    observations: [],
    evidence: [],
    semantic_items: [],
    ledger: [],
    model: { candidates: [], dropped: [], published: [], judged: [], phases: {} },
    needs_review_queue: [],
    findings: [],
    barriers: [],
    criteria: [],
    manual: [],
    verdict: null,
    status: 'partial',
    log: [],
  };
}

export function inSet(run, sc) {
  const set = new Set(run.criteria_set);
  return (sc || []).filter((s) => set.has(s));
}

// Contributors: {id, source: 'axe'|'check'|'runner'|'engine-b', sc[], perState, viewports?}. Only
// contributors that map to the run's criteria set get units.
export function registerContributors(run, list) {
  for (const c of list) {
    const sc = inSet(run, c.sc);
    if (!sc.length) continue;
    if (run.contributors.some((x) => x.id === c.id && x.source === c.source)) continue;
    run.contributors.push({ id: c.id, source: c.source, sc, perState: c.perState !== false, viewports: c.viewports ?? null });
  }
}

export function pageKey(i) {
  return `p${i + 1}`;
}

export function unitId(page, viewport, state, contributor) {
  return `${page}|${viewport}|${state}|${contributor}`;
}

function contributorKey(c) {
  return `${c.source}:${c.id}`;
}

// Planned before the first navigation: every requested URL × viewport gets its initial-state units.
export function planUnits(run) {
  run.pages = [];
  run.scope.urls.forEach((url, i) => {
    for (const viewport of run.scope.viewports) {
      run.pages.push({ page: pageKey(i), url, viewport, status: 'pending', states: [{ id: 'initial', opened: true }] });
      addStateUnits(run, pageKey(i), viewport, 'initial');
    }
  });
}

export function addStateUnits(run, page, viewport, state) {
  for (const c of run.contributors) {
    if (state !== 'initial' && !c.perState) continue;
    if (c.viewports && !c.viewports.includes(viewport)) continue;
    const id = unitId(page, viewport, state, contributorKey(c));
    if (run.units.some((u) => u.id === id)) continue;
    run.units.push({ id, sc: c.sc, page, viewport, state, contributor: contributorKey(c), status: 'pending' });
  }
}

function units(run, { page, viewport, state, contributor }) {
  return run.units.filter((u) => (page === undefined || u.page === page) && (viewport === undefined || u.viewport === viewport)
    && (state === undefined || u.state === state) && (contributor === undefined || u.contributor === contributor));
}

export function completeUnits(run, sel) {
  for (const u of units(run, sel)) if (u.status === 'pending') u.status = 'completed';
}

export function missUnits(run, sel, reason) {
  for (const u of units(run, sel)) if (u.status !== 'completed') { u.status = 'missing'; u.reason = reason; }
}

// Observation: {source, contributor, sc[], outcome, basis, impact, page, viewport, state, selector, frame,
// shadow, evidence_ids[], data, ancestor, remediation_key, steps[]}. SC outside the run's set is dropped.
export function addObservation(run, o) {
  const sc = inSet(run, o.sc);
  if (!sc.length) return null;
  const contributor = `${o.source}:${o.contributor}`;
  const id = `o${run.observations.length + 1}`;
  const obs = {
    id,
    source: o.source,
    contributor,
    sc,
    outcome: o.outcome,
    basis: o.basis ?? (o.outcome === 'violation' ? '●' : o.outcome === 'needs-review' ? '◐' : null),
    impact: o.impact ?? 'moderate',
    page: o.page,
    viewport: o.viewport,
    state: o.state ?? 'initial',
    selector: o.selector ?? '',
    frame: o.frame ?? '',
    shadow: o.shadow ?? '',
    ancestor: o.ancestor ?? null,
    evidence_ids: o.evidence_ids ?? [],
    data: o.data ?? null,
    remediation_key: o.remediation_key ?? o.contributor,
    steps: o.steps ?? [],
    unit: unitId(o.page, o.viewport, o.state ?? 'initial', contributor),
  };
  obs.node_key = nodeKey(obs);
  run.observations.push(obs);
  return obs;
}

function pageUrl(run, page) {
  const p = run.pages.find((x) => x.page === page);
  return p ? p.url : '';
}

function buildFindings(run) {
  const occ = [];
  for (const o of run.observations) {
    if (o.outcome !== 'violation' && o.outcome !== 'needs-review') continue;
    const u = run.units.find((x) => x.id === o.unit);
    if (u && u.status !== 'completed') continue;
    occ.push({
      node_key: o.node_key, sc: o.sc, outcome: o.outcome, basis: o.basis, impact: o.impact,
      page: o.page, url: pageUrl(run, o.page), viewport: o.viewport, state: o.state, frame: o.frame,
      selector: o.selector, ancestor: o.ancestor, steps: o.steps, data: o.data,
      contributors: [{ source: o.source, id: o.contributor.split(':').slice(1).join(':'), sc: o.sc }],
      evidence_ids: o.evidence_ids, observation_ids: [o.id], remediation_key: o.remediation_key,
      browser: run.browser ? `${run.browser.channel || 'chromium'} ${run.browser.version || ''}`.trim() : null,
    });
  }
  for (const p of run.model.published) {
    const sc = inSet(run, p.sc);
    if (!sc.length) continue;
    occ.push({
      node_key: `model|${p.item_id}`, sc, outcome: 'needs-review', basis: '◐', impact: p.impact || 'moderate',
      page: p.page ?? null, url: p.page ? pageUrl(run, p.page) : '', viewport: p.viewport ?? null, state: p.state ?? null,
      frame: '', selector: p.selector ?? '', ancestor: null, steps: [], data: { rationale: p.rationale, false_positive_if: p.false_positive_if },
      contributors: [{ source: 'model', id: p.kind, sc }], evidence_ids: p.evidence_id ? [p.evidence_id] : [],
      observation_ids: [], remediation_key: p.kind, model_item: p.item_id,
    });
  }
  const findings = merge(occ);
  findings.forEach((f, i) => {
    f.id = `f${i + 1}`;
    f.fingerprint = fingerprint(f.sc[0], f.selector, f.url, f.contributors[0].id);
  });
  return findings;
}

function scopesOf(list) {
  const map = new Map();
  for (const u of list) {
    const k = `${u.page}|${u.viewport}|${u.state}`;
    if (!map.has(k)) map.set(k, []);
    map.get(k).push(u);
  }
  return map;
}

export function statusFor(run, criterionId, findings) {
  const c = criterionById(criterionId);
  if (criterionId === '4.1.1') return { id: criterionId, status: STATUS.NA, reason: OBSOLETE_411, ceiling: 'manual-only' };
  const list = run.units.filter((u) => u.sc.includes(criterionId));
  const scopes = scopesOf(list);
  const done = [...scopes.values()].filter((us) => us.every((u) => u.status === 'completed')).length;
  const fraction = `${done}/${scopes.size}`;
  const missing = list.filter((u) => u.status !== 'completed');
  const reasons = [...new Set(missing.map((u) => u.reason || 'not-run'))].sort();
  const ceiling = list.length ? 'auto-partial' : 'manual-only';
  const base = { id: criterionId, title: c?.title, level: c?.level, slug: c?.slug, ceiling, coverage: fraction };
  const mine = findings.filter((f) => f.sc.includes(criterionId));
  if (mine.some((f) => f.basis === '●' && f.outcome === 'violation')) {
    return { ...base, status: STATUS.FAILS, reason: missing.length ? `partial coverage ${fraction}` : null };
  }
  if (mine.some((f) => f.basis === '◐')) {
    return { ...base, status: STATUS.SUSPECTED, reason: missing.length ? `partial coverage ${fraction}` : null };
  }
  if (!list.length) return { ...base, status: STATUS.NOT_TESTED, reason: 'no contributor' };
  if (missing.length) return { ...base, status: STATUS.NOT_TESTED, reason: `partial coverage ${fraction} — ${reasons.join(', ')}` };
  const frameSkipped = run.ledger.some((l) => l.kind === 'cross-origin-frame-skipped');
  const obs = run.observations.filter((o) => o.sc.includes(criterionId) && list.some((u) => u.id === o.unit));
  const unitsWithInapplicable = new Set(obs.filter((o) => o.outcome === 'inapplicable').map((o) => o.unit));
  if (!frameSkipped && obs.length && obs.every((o) => o.outcome === 'inapplicable') && list.every((u) => unitsWithInapplicable.has(u.id))) {
    return { ...base, status: STATUS.NA, reason: 'no applicable content found on any scanned page, viewport or state' };
  }
  return { ...base, status: STATUS.NO_FAILURE, reason: null };
}

export function verdictKey(run) {
  const completedPages = run.pages.filter((p) => p.status === 'completed');
  if (!completedPages.length) return 'nothing-scanned';
  if (run.status !== 'complete') return 'partial';
  if (run.criteria.some((c) => c.status === STATUS.FAILS)) return 'fails';
  if (run.criteria.some((c) => c.status === STATUS.SUSPECTED)) return 'suspected';
  return 'positive';
}

export function finalize(run) {
  for (const u of run.units) {
    if (u.status === 'pending' && run.status === 'complete') { u.status = 'missing'; u.reason = 'not-run'; }
  }
  run.findings = buildFindings(run);
  run.criteria = run.criteria_set.map((id) => statusFor(run, id, run.findings));
  run.barriers = clusterBarriers(run.findings);
  const queue = [];
  for (const cand of run.model.candidates) {
    if (!run.model.published.some((p) => p.item_id === cand.item_id)) queue.push({ item_id: cand.item_id, kind: cand.kind, sc: cand.sc, reason: cand.disprove || 'not upheld by the disprove pass' });
  }
  run.needs_review_queue = queue;
  run.manual = manualTasks(run);
  run.verdict = verdictKey(run);
  return run;
}
