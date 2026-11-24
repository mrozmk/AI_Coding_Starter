# Audit checklist

Verdict per item: `pass` / `fail` / `partial` / `n/a` / `needs-owner`.
Every non-`n/a` verdict needs evidence (URL, file:line, or quoted copy).

**Dates first.** Before a `fail`, check that the obligation applies on the audit date and to this
content ([legal-refs.md](legal-refs.md) → Date rules): text published before 2 Aug 2026, and
media generated before it and not modified since, have no Art. 50 duty (`n/a`, or LOW as
voluntary transparency); an obligation that
applies later (Art. 26 / Annex III from 2 Dec 2027, Art. 5(1)(ba)/(bb) from 2 Dec 2026) is an
upcoming obligation, never a current breach.

## Severity mapping (finding severity ← article ← penalty tier)

| Severity | Meaning | Typical articles |
|---|---|---|
| CRITICAL | Likely prohibited practice — stop immediately | Art. 5 (tier 1: 7 %) |
| HIGH | Obligation applicable on the audit date, visibly unmet | Art. 50 (tier 2: 3 %); Art. 26 only from 2 Dec 2027 |
| MEDIUM | Probable breach that needs owner confirmation, partial implementation, or an upcoming obligation the org is not ready for | any, verdict `partial`/`needs-owner` escalated by plausibility · Art. 26 / Annex III readiness before 2 Dec 2027 · a vendor chat widget used as-is without disclosure |
| LOW | Best practice / defensive hygiene, not a hard duty | metadata provenance, voluntary labeling, Art. 4 documentation quality |
| INFO | Observation with no obligation attached | claims, inventory notes |

## CODE-* — detectable in code / HTML / rendered DOM

| ID | Check | Article | Detection hints |
|---|---|---|---|
| CODE-01 | Chat/AI widget or agent present → visible "you are talking to AI" disclosure at or before first interaction | 50(1) | Widget scripts: Intercom, Drift, Tidio, Crisp, Chatbase, Voiceflow, Botpress, LiveChat+AI, custom endpoints to `api.openai.com` / `api.anthropic.com` / `generativelanguage.googleapis.com`; websocket chat inits. Inspect rendered DOM — widgets inject post-load. **Fail patterns** (not sufficient on their own): disclosure only in T&C, a URL or docs; a machine-readable mark; a generic "assistant" or a human-like persona; a site-wide "this website uses AI"; "this system uses LLMs". Own-built bot (org = provider) → HIGH; vendor widget used as-is → MEDIUM, fix through the widget's greeting/settings |
| CODE-02 | Chatbot disclosure is textual, clear, distinguishable, accessible (not icon-only, present for screen readers); in health, finance, insurance, legal or complaint contexts and for vulnerable users it persists or repeats | 50(1)+50(5) | Check widget greeting text, aria labels, a persistent badge; ask the bot whether it is an AI — it must say so |
| CODE-03 | Image assets carry AI-provenance metadata intact (if AI-generated) | 50(2) chain | `exiftool`: XMP `DigitalSourceType` = `…/digitalsourcetype/trainedAlgorithmicMedia`, C2PA manifest, `DALL-E`/`Midjourney` creator tags |
| CODE-04 | Media depicting persons/places/events/products as real, AI-generated → visible label (EU icon of the Code of Practice or an equivalent visible label passes; **metadata alone fails**) | 50(4) | Cross-check asset naming, metadata, visual inspection; the site's own naming conventions for stock/model versus real-person images. Includes fictitious-but-plausible persons and product images that mislead about the real product; photorealism is not the test. Check the generation / last-modification date |
| CODE-05 | Build pipeline strips image metadata (breaks provenance chain) | 50(2) chain, LOW | Compare source asset metadata vs `dist/` derivative; image optimizers and CDNs commonly drop XMP/IPTC |
| CODE-06 | Forms producing automated outcomes about a person ("check if you qualify", instant pricing/scoring) | Annex III 5(b)(c), 4(a) | Form handlers, fetch targets, result rendering without human step → route to ASK-20 |
| CODE-07 | Emotion/biometric analysis in front-end (camera/mic access, face or sentiment libs) | 5(f)(g), 50(3) | `face-api.js`, `getUserMedia` + analysis endpoints, sentiment SDKs |
| CODE-08 | Careers page with automated application screening (ATS with AI ranking) | Annex III 4(a) | ATS embeds (Workable, Lever, Greenhouse AI features) → route to ASK-22 |
| CODE-09 | Site offers its OWN generator feature (user-facing genAI) → output marked machine-readably **and** detectable; org is provider here. Image/video generators: safeguards against non-consensual intimate imagery and CSAM | 50(2) · 5(1)(ba)/(bb) from 2 Dec 2026 | "generate", "create your…" features calling genAI APIs. A proprietary `<meta>` tag or JSON flag is not a detection mechanism — expect C2PA or IPTC `DigitalSourceType` written at generation time |
| CODE-10 | AI-driven per-user personalization/scoring in JS (dynamic content by profile, lead scoring) | 5(a)(b), Annex III profiling | Personalization SDKs, A/B on user traits → route to ASK-20/25 |
| CODE-11 | AI-disclosure logic fails closed: the notice does not depend on a per-item flag whose absence means "not AI" | 50(4), LOW–MEDIUM | An `aiGenerated`-style boolean defaulting to false, a notice rendered only when a field is set: a forgotten entry silently claims human authorship. Prefer an unconditional notice, or a flag that must be set explicitly to *remove* it. Check every place authorship is stated (byline, author box) for contradictions |

## COPY-* — detectable in content / copy

| ID | Check | Article |
|---|---|---|
| COPY-10 | AI-generated articles/guides "informing the public" (health, finance, safety topics) published on or after 2 Aug 2026 carry disclosure OR underwent genuine human editorial review. Not in scope: advertising and product descriptions without health, safety or sustainability claims. A visible label (incl. the Code of Practice's EU icon) passes | 50(4) → ASK-19 |
| COPY-11 | Synthetic testimonials, AI avatars presented as real people (fake "doctor", cloned voice, AI "patients"), AI influencers in ads | 50(4) + UCPD — HIGH |
| COPY-12 | Copy exploits fear/vulnerability of a target group (age, illness, debt) via AI-driven dynamic content | 5(a)(b) — CRITICAL if AI-personalized, else UCPD-note INFO |
| COPY-13 | "AI-powered" claims: (i) true? (AI-washing) (ii) does the described function land in Annex III (e.g. "algorithm picks your therapy" = health profiling)? | 99 tier 3 · Annex III |
| COPY-14 | Claims like "AI detects the cause of your condition" — repurposing a tool into a (quasi-)medical/high-risk use | 25(1)(c), Annex III |
| COPY-15 | Privacy policy names AI systems in use, purposes, data categories; mentions emotion/biometric processing if present | 50(3) + GDPR |
| COPY-16 | White-labeling: vendor AI presented as "our proprietary AI assistant" | 25(1)(a) — provider flip if high-risk |
| COPY-17 | Where the site relies on editorial review instead of disclosure: the imprint or legal notice names the person or function holding editorial responsibility, easy to find | 50(4), LOW — supports ASK-19 |

## ASK-* — verification pool (report only outcome-changing items)

This is an internal triage pool, NOT a questionnaire to dump into the report. A pool item makes
it into the report only if its answer **flips a legal obligation or a finding's severity** for
the audited subject — and then it is written as a concrete action with both outcome branches
("if confirmed → duty discharged; if not → do X"). The report reader operates the site: never
emit awareness questions, context-gathering, or anything the evidence already answered.

| ID | Verifies | Article | Outcome branches |
|---|---|---|---|
| ASK-18 | Staff using AI is covered by some literacy measure: a role-adequate instruction, a short training, internal guidance | 4 | missing → gap under amended Art. 4 (since 27 Jul 2026: take support measures, no guaranteed level); a one-page instruction or a short training closes it |
| ASK-19 | AI-assisted public-interest texts underwent human editorial review: a competent person read and fact-checked the **final published text of each language version**, and a named person or entity holds editorial responsibility | 50(4) | confirmed → no disclosure duty; not → per-article disclosure required. Not confirmed when: only a declaration or policy exists, the review was automated or cursory, AI edited or machine-translated the text after sign-off |
| ASK-20 | A chatbot/form makes or materially prepares decisions about persons **in an Annex III area** (employment, credit, insurance pricing, essential services), beyond a narrow procedural or preparatory task (Art. 6(3)) | Annex III, 6(3) | yes → high-risk deployer duties apply from 2 Dec 2027 — prepare now (oversight person, logs ≥ 6 months, informing the persons concerned); outside Annex III, or within the 6(3) filter without profiling → stays limited/minimal |
| ASK-21 | Any tool analyzes emotions/voice/face/biometrics | 5(f)(g), 50(3) | yes in workplace → PROHIBITED; yes toward visitors → information duty |
| ASK-22 | AI used in recruitment (screening, targeted job ads, scoring) | Annex III 4 + 26 | yes → high-risk deployer duties incl. informing candidates/workers, applicable from 2 Dec 2027 — prepare now |
| ASK-23 | Vendor AI modified or rebranded under own name | 25 | yes + high-risk → full provider duties (Art. 16); yes for a chatbot → the org is the provider under 50(1) |
| ASK-24 | High-risk system in use: instructions, oversight person, logs ≥6 mo, persons informed | 26, 111(2) | each miss = a MEDIUM readiness finding until 2 Dec 2027. After that date a separate HIGH finding — but first establish when the system went into service: one in service before 2 Dec 2027 and not significantly changed since is not yet covered (Art. 111(2)) → readiness finding |
| ASK-25 | Ad campaigns use AI targeting that **singles out** a vulnerable group (age, disability, social or economic situation) to exploit that vulnerability | 5(b) | Art. 5(1)(b) needs exploitation of the vulnerability, material distortion of behaviour and significant harm (or its reasonable likelihood) — reach alone is not a finding. Targeting built on the vulnerability plus harmful persuasion → evaluate COPY-12, tier-1 exposure; the group is merely reachable → no finding, an audience exclusion is good practice (LOW at most) |
| ASK-26 | The relevant date of undated AI-generated content: publication date for text, generation / last AI modification date for media | 50, Guidelines 153–154 | text published before 2 Aug 2026 → no duty, on or after → the COPY-10 finding stands; media generated before 2 Aug 2026 and unmodified since → no duty, generated or modified on or after → the CODE-04 finding stands |

Dropped from reports by design: "does the company use AI at all" (the audit's evidence answers
it), sandbox/SME-support awareness (educational — chat-summary material at most).
