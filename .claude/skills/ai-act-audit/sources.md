# Sources & maintenance

**Last verified: 2026-11-24.** Re-verify when any of these lands: the final Commission guidelines
on high-risk classification (Art. 6(5), still a draft), Commission guidelines on Art. 25/26, the
joint Commission–EDPB guidelines on the AI Act / GDPR interplay, a further amending act — and in
any case before relying on a date in legal-refs.md that lies less than a month ahead.

## Primary legal sources

- Regulation (EU) 2024/1689 — `http://data.europa.eu/eli/reg/2024/1689/oj` (EUR-Lex 32024R1689)
- Regulation (EU) 2026/1744, Digital Omnibus on AI (OJ L 24.7.2026, in force 27.7.2026) —
  `http://data.europa.eu/eli/reg/2026/1744/oj`; signed text PE-CONS 30/1/26 REV 1:
  https://data.consilium.europa.eu/doc/document/PE-30-2026-REV-1/en/pdf
- Commission Guidelines on the Art. 50 transparency obligations, C(2026) 5054 final, 20 Jul 2026:
  https://digital-strategy.ec.europa.eu/en/library/guidelines-transparency-obligations-providers-and-deployers-ai-systems
- Code of Practice on Transparency of AI-generated Content (final 10 Jun 2026):
  https://digital-strategy.ec.europa.eu/en/policies/code-practice-ai-generated-content
- Draft Commission guidelines on the classification of high-risk AI systems (19 May 2026, not
  adopted): https://ai-act-service-desk.ec.europa.eu/en/guidelines-classification-high-risk-ai-systems
- Commission AI Act policy page: https://digital-strategy.ec.europa.eu/en/policies/regulatory-framework-ai

EUR-Lex answers automated fetches with a bot-challenge page; read the OJ text in a browser, or
the signed PE-CONS text above.

## Secondary references (unofficial)

- https://artificialintelligenceact.eu/ai-act-explorer/ — article/annex texts (FLI; link target
  for findings). **Not checked** on 2026-11-24 for whether its pages show the wording as amended
  by Regulation (EU) 2026/1744 — for Art. 4, 4a, 5, 25, 99, 111 and 113 cite the amending
  regulation as well.
- https://artificialintelligenceact.eu/high-level-summary/ — risk-tier overview
- https://artificialintelligenceact.eu/small-businesses-guide-to-the-ai-act/ — SME facilitations
- https://artificialintelligenceact.eu/assessment/eu-ai-act-compliance-checker/ — the triage
  question flow replicated in triage.md

## Change log

### 2026-11-24 — re-verification (previous: 2026-07-31)

Each change names its source; "Omnibus" = Regulation (EU) 2026/1744 read in the signed text,
"Guidelines" = C(2026) 5054 final with the paragraph number.

| Change | Source |
|---|---|
| Art. 26, Art. 27 and the whole Annex III high-risk regime apply from **2 Dec 2027**, Annex I systems from 2 Aug 2028 — not from 2 Aug 2026. High-risk findings became readiness findings until then | Omnibus, amended Art. 113 third paragraph point (c) |
| No conditional "stop-the-clock" mechanism; the dates are fixed | Omnibus, operative text |
| Art. 50 applies from 2 Aug 2026 unchanged; provider-side 50(2) marking for generative systems placed on the market earlier was due by 2 Dec 2026 | Omnibus, new Art. 111(4); Guidelines 153 |
| No retroactive labelling of content generated or published before 2 Aug 2026; text generated earlier but published later must be labelled (for media the generation / modification date decides) | Guidelines 153–154 |
| Grandfathering of high-risk systems already in service now runs from the application date of Chapter III | Omnibus, amended Art. 111(2) |
| Art. 4 replaced: "take measures to support" AI literacy, no guaranteed individual level; support duty for the Commission and Member States | Omnibus, Art. 4 as replaced (in force 27 Jul 2026) |
| New Art. 4a: permission to process special-category data for bias detection under cumulative safeguards | Omnibus, Art. 4a (Art. 10(5) deleted) |
| New prohibitions Art. 5(1)(ba)/(bb) from 2 Dec 2026 (non-consensual intimate imagery, CSAM), with Art. 5(1a)/(1b) | Omnibus, amended Art. 5 and Art. 113(a) |
| Small mid-caps (SMCs) share SME facilitations; fine cap "whichever is lower" for SMCs; warnings and non-monetary measures; economic viability | Omnibus, Art. 3(14a)/(14b), Art. 11(1), Art. 99(1), new Art. 99(6a) |
| Art. 25(2)/(4) rewritten and added to tier 2 | Omnibus, Art. 25, Art. 99(4)(da) |
| National sandbox deadline moved to 2 Aug 2027 | Omnibus, amended Art. 57(1) |
| FRIA may cross-reference the GDPR DPIA | Omnibus, Art. 27(4)/(5) |
| Code of Practice on Transparency of AI-generated Content is final and found adequate; optional EU icon; non-signatories show alternative means | Commission code page and FAQ (10 Jun 2026); Commission opinion (July 2026); Guidelines §8.1 |
| 50(1) is a provider duty; an in-house chatbot makes the org a provider; insufficient-disclosure patterns; cadence in riskier contexts; AI agents covered | Guidelines 11, 31, 38, 40, 143 |
| Deployer notion and the agency-commissioning carve-out | Guidelines 12, 14 |
| 50(2): marking and detection both required; out-of-scope outputs | Guidelines 68, 70, 90–92 |
| Deepfake notion refined (plausible persons, misleading product images; photorealism not determinative); label perceivable without tools, metadata alone insufficient | Guidelines 113–117 |
| Public-interest text narrowed (advertising and product descriptions out unless health/safety/sustainability claims); editorial-review exception needs a fact-checking read of the final text and a publicly named responsible person | Guidelines 131, 133–138 |
| High-risk classification guidelines are still a draft | AI Act Service Desk page, checked 2026-11-24 |
| Repo table: microsoft/agent-governance-toolkit licence MIT; AbdelStark data is pre-Omnibus | GitHub API, 2026-11-24 |

Folded in from a real audit run (Aug 2026), where they hold generally: check dates before calling
anything overdue; disclosure *or* a genuine editorial read of the final text per language; a
proprietary meta tag or JSON flag is not a detection mechanism and provenance belongs at
generation time; a disclosure flag that defaults to "not AI" fails open (CODE-11).

### Not confirmed from a primary source — deliberately not encoded

- The detailed rules of the Code of Practice (modality-specific label placement, the "at least
  two layers" of marking for providers, the fate of the draft's "fully AI-generated vs
  AI-assisted" taxonomy): the code text itself was not read; law-firm summaries only.
- A formal re-adoption of the Art. 50 Guidelines in November 2026 under a new reference and an
  OJ notice: secondary sources only (an OJ publication under `eli/C/2026/6005` was reported in
  review and not opened — check it at the next verification).
- The adoption date of the final high-risk classification guidelines ("by end of 2026").
- A deferral of watermark-detection interoperability to February 2027: not in the final text of
  the Omnibus.
- The exact day of the Commission's adequacy opinion on the code (8 or 9 July 2026 — two
  Commission pages disagree).
- Whether any Commission guideline on Art. 26 exists: none was found.

## Open-source projects reviewed (2026-07, re-checked 2026-11-24) — reusable, license-checked

| Repo | License | What we drew / could draw |
|---|---|---|
| AbdelStark/eu-ai-act-toolkit | MIT | 26-question risk decision tree (`questions.json`), `articles.json`, `penalties.json` — machine-readable regulation layer if we ever automate triage. **Data is pre-Omnibus** (last push 2026-03) |
| studio121-develop/ai-act-compliance-skill | Apache-2.0 | 219-item lifecycle checklist; Art. 50 implementation patterns per framework. Last push 2026-07-20 — may be pre-Omnibus |
| FutureRootsDE/legal-audit-de | MIT (text + an appended disclaimer, so GitHub reports no SPDX id) | Live-URL audit architecture, severity report format, auditor→researcher→writer flow |
| NGO-Algorithm-Audit/AI-Act-Implementation-Tool | EUPL-1.2 | Question-flow JSON Schema structure (content OK to reuse; check reciprocity before copying code) |
| ark-forge/mcp-eu-ai-act | MIT | AI-framework detection patterns; `article_map` output shape |
| microsoft/agent-governance-toolkit | MIT | Per-article checklist format (Gap/Partial/Full + tiered recommendations) |
| Hiepler/EuConform | MIT | Offline Annex IV PDF deliverable pattern |
| GenAI-Gurus/awesome-eu-ai-act | CC0-1.0 | Ecosystem watchlist |

Avoid copying from: oliwoodman/compliance-audit-skill, jalaalrd/full-stack-audit (no license),
abk1969/ai_act_compass (AGPL-3.0).

## Gap this skill fills (why it exists)

As of 2026-07 no open-source tool audited a *website/app/marketing surface* for AI Act
compliance from the SME-deployer perspective (Art. 50 transparency + Art. 5 marketing screens).
Existing tools scan codebases for high-risk provider duties (Art. 9–15) or manage GRC paperwork.
