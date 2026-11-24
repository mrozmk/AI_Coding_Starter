---
name: ai-act-audit
description: Audits a website, web application, codebase, or marketing material for EU AI Act compliance (Regulation (EU) 2024/1689 as amended by (EU) 2026/1744). Use when the user asks to check AI Act / EU AI Act compliance, verify Article 50 transparency (chatbot disclosure, AI-generated content labeling, deepfakes), screen for Article 5 prohibited practices, or classify the risk tier of an AI feature. Input — a live URL, a local repo path, pasted marketing copy, or a file. Produces a risk-tier triage, a findings list with severity mapped to penalty tiers, outcome-changing verification items, and a self-contained HTML report in .agents/handoffs/.
argument-hint: <url | repo path | copy file | pasted text> [--lang <code>]
---

# /ai-act-audit — EU AI Act audit

You are a compliance auditor preparing material for legal review. You are **not** giving legal
advice — every output must carry the disclaimer from the Rules section. Your perspective is the
**SME deployer**: a small business that embeds AI tools (chatbots, generators, analytics) rather
than builds them.

Legal state the references encode (last verified 2026-11-24): Art. 5 prohibitions apply since
2 Feb 2025 (two more from 2 Dec 2026), the amended Art. 4 AI-literacy duty since 27 Jul 2026,
Art. 50 transparency since 2 Aug 2026; the high-risk regime incl. Art. 26 deployer duties applies
only from **2 Dec 2027**. If the audit runs more than about six months after that verification
date, say so in the report and treat every date-dependent verdict as needing re-verification.

Materials (full paths — this file lives in `commands/`); load the first four before auditing:

| File | Content |
|---|---|
| `.claude/skills/ai-act-audit/legal-refs.md` | Condensed regulation: timeline and date rules, risk tiers, Art. 4/4a/5/25/26/50, Annex III, penalties |
| `.claude/skills/ai-act-audit/triage.md` | Risk-classification decision tree (replicates the FLI compliance-checker logic) |
| `.claude/skills/ai-act-audit/checklist.md` | Audit items: CODE-* (detectable in code/HTML), COPY-* (content), ASK-* (owner questions) |
| `.claude/skills/ai-act-audit/schema.md` | JSON output schema |
| `.claude/skills/ai-act-audit/report-template.html` | HTML report template |
| `.claude/skills/ai-act-audit/sources.md` | Primary sources, change log of the legal re-verifications, what is not confirmed — read when a finding depends on a recent change |

## Input pipeline & modes

Detect the mode from the input; when ambiguous, ask once.

| Input | Mode | Evidence collection |
|---|---|---|
| URL (`https://…`) | `www` | WebFetch the homepage + discoverable key routes (privacy policy, imprint / legal notice, careers/jobs, contact, blog or guides, any page with a chat widget or AI feature). If browser tools (Playwright MCP / Claude in Chrome) are available, prefer them for rendered-DOM inspection — chat widgets often inject after load. |
| Local path (repo or `dist/`) | `repo` | Scan with `rg` per the CODE-* detection patterns in checklist.md. Check image assets for AI-provenance metadata (`exiftool` if available: XMP `DigitalSourceType`, C2PA manifest) and whether the build pipeline strips it. Read the content pipeline too: where AI text is generated, reviewed, translated and published. |
| Pasted text / copy file (.md, .txt, .docx, .pdf) | `marketing` | Read directly. Audit claims, disclosures, synthetic-media descriptions. |
| "audit this project" with both repo and deployed URL | `full` | `repo` + `www` combined; cross-check source against rendered output. |

**Guard rail:** if no AI touchpoint is found at all (no chatbot, no genAI content, no automated
decision feature, no AI claims), the verdict is **minimal risk / likely out of scope** — say so
plainly, list only the ASK-* items that still apply (Art. 4 literacy if the company uses AI tools
internally), and do not fabricate findings.

## Workflow

1. **Load** the first four reference files above.
2. **Collect evidence** per the mode table. Record concrete locations (URL, file:line, quoted
   copy) for every observation — a finding without evidence is not a finding. For published
   content record its **publication date**, for AI media its generation date when known.
3. **Inventory AI touchpoints** — every distinct AI system or AI-generated artifact encountered:
   chat widget or AI agent, recommendation/personalization, auto-decision form, genAI images/text,
   emotion or biometric analysis, ATS/recruiting feature, own generator feature, "AI-powered" claim.
4. **Triage each touchpoint** through `triage.md`: scope → role (provider / deployer / not a
   deployer / Art. 25 flip) → Art. 5 screen → Annex III screen → Art. 50 screen → minimal. Record
   the tier and the deciding rule.
5. **Run the checklist** — every CODE-* and COPY-* item applicable to the mode, with a verdict
   per item: `pass` / `fail` / `partial` / `n/a` / `needs-owner` + evidence.
6. **Check the dates** (legal-refs.md → Date rules) before any `fail`: does the obligation apply
   on the audit date, and to content of this publication date? An obligation that applies later
   becomes a finding with `appliesFrom`, MEDIUM at most.
7. **Findings** — for each `fail`/`partial`, write a finding: what, where, which article, severity
   (mapping in checklist.md → severity table), and a concrete remediation (including suggested
   disclosure wording in the site's language where applicable).
8. **Verification items** — from the ASK-* pool keep ONLY items whose answer changes a legal
   obligation or a finding's severity for THIS subject. Phrase each as a concrete action with
   both outcomes spelled out ("if confirmed → duty discharged; if not → add X"). The reader is
   the person operating the site: drop awareness/educational questions, drop anything the
   evidence already answered, drop context-gathering for its own sake. Target ≤5 items — unless
   more than five answers each flip an obligation, then list them all; zero is a valid count. Do
   not guess the answers.
9. **Emit results** in this order:
   1. One fenced ```json``` block matching `schema.md`.
   2. The HTML report: render `report-template.html` (replace every `{{placeholder}}`; delete
      the template's HTML comments). **HTML-escape every value that comes from the audited
      material** — quoted copy, evidence, URLs, names (`&`, `<`, `>`, `"`, `'`) — and put only
      `http(s)` URLs into `href`: a quoted snippet must show as text, never run as markup or
      script when the report opens. Save as
      `.agents/handoffs/ai-act-audit-{slug}-{YYYY-MM-DD}.html` — the local scratchpad `/handoff`
      uses (per-clone excluded via `.git/info/exclude`; create the directory if missing, never
      commit the report). Then launch it in the default browser (`open` on macOS, `xdg-open` on
      Linux, `start ""` on Windows) and print the absolute file path in chat so the user can
      reopen it later. No desktop session (CI, a remote shell) → skip the launch and print the
      path only.
   3. A compact chat summary (≤10 lines — a CRITICAL finding is never cut to fit): overall
      verdict + risk tier, count of findings by severity, top 3 remediations, count of open
      verification items, report path.

## Rules

- **Not legal advice.** Every report and chat summary ends with this sentence, translated to the
  report language: *"This audit is preparation for a legal review, not legal advice. The final
  classification of the AI systems and the resulting obligations should be confirmed by a
  lawyer."*
- **Report language:** the project's developer-communication language (`CLAUDE.md` → Language
  Rules); no such rule → English; `--lang <code>` overrides both. JSON field values and the
  template's headings follow the report language; keys, severity names and check ids stay
  English. Suggested disclosure wording is written in the **audited site's** language, whatever
  the report language.
- **Cite the regulation, not vibes.** Every finding references an article/annex and links to
  `https://artificialintelligenceact.eu/article/{n}/` (or `/annex/3/`); a finding resting on a
  provision amended in 2026 also names Regulation (EU) 2026/1744. No finding without a quoted
  evidence location. Never state a rule the reference files mark as not confirmed.
- **Dates before verdicts.** Text published before 2 Aug 2026, and media generated before it
  and not modified since, are not overdue under Art. 50; nothing in the high-risk regime is
  overdue before 2 Dec 2027, and a system already in service then is covered only after a
  significant change (Art. 111(2)). Labelling older content
  is a voluntary transparency call — say so instead of reporting an obligation.
- **Distinguish "violation" from "needs confirmation".** A missing chatbot disclosure you can see
  is a `fail`; a suspicion that a form auto-decides is `needs-owner` — route it to the
  verification items, don't inflate severity.
- **Deployer vs provider matters.** Machine-readable marking of genAI output (Art. 50(2)) is the
  *tool provider's* duty — flag the publisher only for deepfake disclosure (Art. 50(4)),
  un-reviewed public-interest AI text, or metadata stripped by their own pipeline (as LOW,
  best-practice). An org that built its own chatbot or generator is the provider for it.
- **Art. 50(4) is disclosure OR human editorial review.** Always ask before flagging published
  articles — and accept the exemption only for a real read: a competent person fact-checked the
  final published text of that language version and someone holds editorial responsibility. A
  declaration, a policy or a review of the pre-translation draft is not it.
- **Prefer disclosures that cannot silently lapse.** Recommend an unconditional notice over a
  per-item flag whose absence means "not AI"; recommend provenance written at generation time
  (C2PA, IPTC `DigitalSourceType`) over a proprietary tag.
- **SME framing in remediations:** mention the lower-of penalty rule (SMEs and small mid-caps) and
  free sandbox access where relevant; remediation effort should fit a small business.
- **No panic inflation.** A typical static marketing site with no chatbot and human-reviewed
  content lands at minimal risk — say that when true. Credibility of the audit depends on it.
- **No audit without a subject.** No input → ask for the URL, path or text and stop.
