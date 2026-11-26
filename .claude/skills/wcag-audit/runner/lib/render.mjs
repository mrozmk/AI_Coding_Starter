// render.mjs — the self-contained HTML report from run.json: every audited value escaped, no script,
// no event handlers, no remote resources; crops embedded as data: URIs read from <work>/evidence/.
import fs from 'node:fs';
import path from 'node:path';
import { pick, remediation } from './strings.mjs';
import { understandingUrl, criterionById, STATUS } from './criteria.mjs';
import { evidencePath } from './paths.mjs';
import { SKILL_DIR } from './deps.mjs';
import { IMPACTS } from './contract.mjs';

export function esc(value) {
  return String(value ?? '').replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;').replace(/'/g, '&#39;');
}

const CSS = `
:root { --bg: #ffffff; --fg: #1a1a1a; --muted: #4a4a4a; --line: #c8c8c8; --accent: #0b4f9c; --fail: #a4161a; --warn: #7a4b00; --ok: #1d5c2e; --card: #f4f6f8; }
@media (prefers-color-scheme: dark) { :root { --bg: #121417; --fg: #ececec; --muted: #c4c4c4; --line: #4a4f55; --accent: #8cc4ff; --fail: #ff9b9b; --warn: #ffd27a; --ok: #9be3ad; --card: #1d2126; } }
* { box-sizing: border-box; }
body { margin: 0; background: var(--bg); color: var(--fg); font: 16px/1.5 system-ui, -apple-system, "Segoe UI", Arial, sans-serif; }
header, main, footer { max-width: 1100px; margin: 0 auto; padding: 16px; }
h1 { font-size: 1.8rem; margin: 0.4rem 0 1rem; }
h2 { font-size: 1.3rem; margin-top: 2rem; border-bottom: 1px solid var(--line); padding-bottom: 4px; }
h3 { font-size: 1.05rem; }
a { color: var(--accent); }
a:focus-visible, summary:focus-visible { outline: 3px solid var(--accent); outline-offset: 2px; }
table { border-collapse: collapse; width: 100%; margin: 8px 0 16px; }
caption { text-align: left; font-weight: 600; padding: 4px 0; }
th, td { border: 1px solid var(--line); padding: 6px 8px; text-align: left; vertical-align: top; }
th { background: var(--card); }
.verdict { font-size: 1.15rem; font-weight: 600; background: var(--card); padding: 12px; border-left: 4px solid var(--accent); }
.s-fails { color: var(--fail); font-weight: 600; } .s-suspected { color: var(--warn); font-weight: 600; }
.muted { color: var(--muted); }
.card { background: var(--card); padding: 12px; margin: 12px 0; border-radius: 4px; overflow-wrap: anywhere; }
img.crop { max-width: 100%; border: 1px solid var(--line); }
code { overflow-wrap: anywhere; }
`;

function table(caption, headers, rows) {
  return `<table><caption>${esc(caption)}</caption><thead><tr>${headers.map((h) => `<th scope="col">${esc(h)}</th>`).join('')}</tr></thead><tbody>${rows.map((r) => `<tr>${r.map((c, i) => (i === 0 ? `<th scope="row">${c}</th>` : `<td>${c}</td>`)).join('')}</tr>`).join('')}</tbody></table>`;
}

function section(id, title, body) {
  return `<section aria-labelledby="s-${id}"><h2 id="s-${id}">${esc(title)}</h2>${body}</section>`;
}

function cropTag(work, run, evidenceId) {
  const ev = (run.evidence || []).find((e) => e.id === evidenceId);
  if (!ev || !ev.path || !work) return '';
  const p = evidencePath(work, ev.path);
  if (!p) return '';
  const b64 = fs.readFileSync(p).toString('base64');
  return `<img class="crop" alt="${esc(`Evidence ${evidenceId}`)}" src="data:image/png;base64,${b64}">`;
}

export function loadLegal(skillDir = SKILL_DIR) {
  return JSON.parse(fs.readFileSync(path.join(skillDir, 'legal.json'), 'utf8'));
}

export function render(run, { lang = 'en', siteLang = null, work = null, legal = null } = {}) {
  const { lang: L, s, note } = pick(lang);
  const remLang = siteLang === 'pl' || siteLang === 'en' ? siteLang : 'en';
  const parts = [];
  const verdictText = s.verdict[run.verdict] ?? s.verdict['nothing-scanned'];
  parts.push(section('verdict', s.sections.verdict, `<p class="verdict">${esc(verdictText)}</p>${note ? `<p class="muted">${esc(note)}</p>` : ''}`));

  const sc = run.scope || {};
  const scopeRows = [
    [esc(s.labels.urls), (sc.urls || []).map((u) => `<code>${esc(u)}</code>`).join('<br>')],
    [esc(s.labels.viewports), esc((sc.viewports || []).join(', '))],
    [esc(s.labels.date), esc(run.created_at || '')],
    [esc(s.labels.wcag), esc(`${sc.wcag} ${sc.level}`)],
    [esc(s.labels.tool), esc(Object.entries(run.tool || {}).map(([k, v]) => `${k} ${v}`).join(' · '))],
    [esc(s.labels.engineB), esc(run.engines && Object.keys(run.engines).filter((k) => k !== 'axe').join(', ') || s.labels.none)],
    [esc(s.labels.llm), esc(run.llm ? s.labels.on : s.labels.off) + (run.llm && !run.model?.phases?.disprove ? ` — ${esc(s.labels.model_not_completed)}` : '') + (run.model?.guard_inactive ? ` — ${esc(s.labels.guard_inactive)}` : '')],
    [esc(s.labels.retry), esc((sc.retries || []).length ? sc.retries.join(', ') : s.labels.none)],
    [esc(s.labels.client), esc(sc.client || 'unknown')],
    [esc(s.labels.status_run), esc(run.status)],
  ];
  parts.push(section('scope', s.sections.scope, table(s.sections.scope, ['', ''], scopeRows)));

  if (legal) {
    const client = sc.client || 'unknown';
    const keys = client === 'unknown' ? [...new Set([...(legal.framings['public-sector'] || []), ...(legal.framings['eaa-service'] || [])])] : (legal.framings[client] || legal.framings.other || []);
    const items = keys.map((id) => legal.facts.find((f) => f.id === id)).filter(Boolean).map((f) => `<li>${esc(L === 'pl' ? f.text_pl : f.text_en)}${f.verified ? '' : ` <strong>(${esc(s.labels.unverified)})</strong>`}</li>`);
    parts.push(section('legal', s.sections.legal, `<p>${esc(s.labels.last_verified)}: ${esc(legal.last_verified)}</p><ul>${items.join('')}</ul>`));
  }

  const findings = run.findings || [];
  parts.push(section('summary', s.sections.summary, table(s.sections.summary, [s.labels.impact, '●', '◐'], IMPACTS.map((i) => [esc(i), String(findings.filter((f) => f.impact === i && f.basis === '●').length), String(findings.filter((f) => f.impact === i && f.basis === '◐').length)]))));

  const matrixRows = (run.criteria || []).map((c) => {
    const crit = criterionById(c.id);
    const label = s.status[c.status] ?? c.status;
    const cls = c.status === STATUS.FAILS ? 's-fails' : c.status === STATUS.SUSPECTED ? 's-suspected' : '';
    const link = crit ? ` <a href="${esc(understandingUrl(crit.slug))}">${esc(s.labels.understanding)}</a>` : '';
    return [`${esc(c.id)} ${esc(crit?.title || '')}${link}`, `<span class="${cls}">${esc(label)}</span>`, esc(c.ceiling), esc(c.reason || '')];
  });
  parts.push(section('matrix', s.sections.matrix, table(s.sections.matrix, [s.labels.criterion, s.labels.status, s.labels.ceiling, s.labels.reason], matrixRows)));

  const byId = new Map(findings.map((f) => [f.id, f]));
  const barrierHtml = (run.barriers || []).map((b, i) => {
    const fs2 = b.finding_ids.map((id) => byId.get(id)).filter(Boolean);
    const cards = fs2.map((f) => {
      const contributors = f.contributors.map((c) => `${c.source}:${c.id}`).join(', ');
      const fix = remediation(f.remediation_key, remLang, f.data?.help ? `${f.data.help} (${f.data.helpUrl || ''})` : null);
      const detail = f.data?.decode === 'failed' ? esc(s.labels.decode_failed) : f.data?.status ? `HTTP ${esc(f.data.status)}` : '';
      const diag = detail ? `<p>${esc(s.labels.detail)}: ${detail} <code>${esc(f.data.url || '')}</code></p>` : '';
      const crops = (f.evidence_ids || []).map((id) => cropTag(work, run, id)).join('');
      return `<div class="card"><p><strong>${esc(f.basis)} ${esc(f.sc.join(', '))}</strong> · ${esc(f.impact)} · ${esc(contributors)}</p><p>${esc(s.labels.where)}: <code>${esc(f.url)}</code> · ${esc(f.viewport || '')} · ${esc(f.state || '')} · <code>${esc(f.selector)}</code></p>${diag}${fix ? `<p>${esc(s.labels.fix)}: ${esc(fix)}</p>` : ''}${crops}</div>`;
    }).join('');
    return `<h3>${esc(`${i + 1}. ${b.ancestor || '—'} (${b.sc_group})`)}</h3>${cards}`;
  }).join('');
  parts.push(section('barriers', s.sections.barriers, barrierHtml || `<p>${esc(s.labels.none)}</p>`));

  const reviewRows = (run.needs_review_queue || []).map((q) => [esc(q.item_id), esc(q.kind), esc([].concat(q.sc || []).join(', ')), esc(q.reason)]);
  parts.push(section('review', s.sections.review, reviewRows.length ? table(s.sections.review, ['id', s.labels.kind, 'SC', s.labels.reason], reviewRows) : `<p>${esc(s.labels.none)}</p>`));

  const manualHtml = (run.manual || []).map((t) => {
    const tt = t[L] || t.en;
    return `<div class="card"><h3>${esc(tt.title)}</h3><ol>${tt.steps.map((x) => `<li>${esc(x)}</li>`).join('')}</ol><p>${esc(s.labels.question)}: ${esc(tt.question)}</p></div>`;
  }).join('');
  parts.push(section('manual', s.sections.manual, manualHtml));

  const counts = new Map();
  for (const l of run.ledger || []) counts.set(l.kind, (counts.get(l.kind) || 0) + 1);
  const ledgerRows = [...counts.entries()].map(([k, n]) => [esc(k), esc(s.ledger[k] || k), String(n)]);
  const pageRows = (run.pages || []).map((p) => [esc(`${p.page} ${p.viewport}`), `<code>${esc(p.url)}</code>`, esc(p.status + (p.reason ? ` — ${p.reason}` : ''))]);
  parts.push(section('ledger', s.sections.ledger, table(s.sections.ledger, [s.labels.kind, s.labels.detail, s.labels.count], ledgerRows) + table(s.labels.urls, ['', s.labels.urls, s.labels.status], pageRows)));

  parts.push(section('method', s.sections.method, `<p>${esc(s.method)}</p>${remLang !== siteLang && siteLang ? `<p class="muted">${esc(s.labels.lang_note)}</p>` : ''}`));

  return `<!doctype html>
<html lang="${esc(L)}">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${esc(s.title)}</title>
<style>${CSS}</style>
</head>
<body>
<header><p class="muted">/wcag-audit · ${esc(run.created_at || '')}</p></header>
<main>
<h1>${esc(s.title)}</h1>
${parts.join('\n')}
</main>
<footer><p>${esc(s.disclaimer)}</p></footer>
</body>
</html>
`;
}
