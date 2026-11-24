# Legal reference — Regulation (EU) 2024/1689 (EU AI Act), audit-relevant condensate

The regulation **as amended by Regulation (EU) 2026/1744** (Digital Omnibus on AI, OJ L 24.7.2026,
in force 27 Jul 2026), read with the Commission's Art. 50 Guidelines (C(2026) 5054 final,
20 Jul 2026) and the Code of Practice on Transparency of AI-generated Content (final 10 Jun 2026).
**Last verified: 2026-11-24** — sources and the change log: [sources.md](sources.md).

Link findings to `https://artificialintelligenceact.eu/article/{n}/` and
`https://artificialintelligenceact.eu/annex/3/`. That site is unofficial and was not checked for
the amended wording: for a finding that rests on an amended provision (Art. 4, 4a, 5(1)(ba)/(bb),
25, 99, 111, 113) also cite `http://data.europa.eu/eli/reg/2026/1744/oj`.

## Timeline — what applies when

| From | Obligations |
|---|---|
| 2 Feb 2025 | **Art. 5** prohibited practices (a)–(h) · **Art. 4** AI literacy (original wording, until 26 Jul 2026) |
| 2 Aug 2025 | GPAI provider duties (Ch. V) · penalty framework (Art. 99–100) |
| 27 Jul 2026 | Omnibus in force: **new Art. 4** ("take measures to support" AI literacy, no guaranteed level) · Art. 4a (special-category data for bias detection) · SMC relief incl. Art. 99(6a) |
| **2 Aug 2026** | General application: **Art. 50 transparency**, all paragraphs. *Not* the high-risk regime |
| **2 Dec 2026** | New prohibitions **Art. 5(1)(ba)/(bb)** · end of the Art. 50(2) grace period for generative systems placed on the market before 2 Aug 2026 (Art. 111(4)) |
| 2 Aug 2027 | At least one national regulatory sandbox operational (Art. 57(1)) · legacy GPAI full compliance (Art. 111(3)) |
| **2 Dec 2027** | Chapter III Sections 1–3 for **Annex III** systems: Art. 6(2)/(3), Arts. 8–15, **Art. 26**, **Art. 27** |
| 2 Aug 2028 | Chapter III Sections 1–3 for Annex I / Art. 6(1) systems (product-safety components) |

The dates are fixed in the amended Art. 113 — no conditional "stop-the-clock" mechanism is in the
final text.

**Date rules for every audit — compare each obligation with the audit date before calling
anything a breach:**

- **Art. 50** is enforceable since 2 Aug 2026, whenever the system was placed on the market.
  One exception: provider-side marking under 50(2) for a generative system placed on the market
  before 2 Aug 2026 was due by **2 Dec 2026**; from that date no grace remains. Chatbot
  disclosure (50(1)), 50(3) and 50(4) were never deferred.
- **No retroactive labelling** (Guidelines paras 153–154). Content generated or published
  before 2 Aug 2026 carries no Art. 50 marking or disclosure duty — with one stated exception:
  **text** generated earlier but **published on or after 2 Aug 2026** must be labelled. So for
  public-interest text the *publication* date decides; for media (images, video, audio) the
  date of *generation or last AI modification* decides — an image generated before 2 Aug 2026
  and not modified since is not a `fail`, whenever it went online. Establish the relevant date
  before flagging an article or an image; an undated item is `needs-owner`, not `fail`.
- **Art. 26 / Art. 27 and the whole Annex III regime are not enforceable until 2 Dec 2027**
  (Annex I: 2 Aug 2028). Before that date report a high-risk hit as an **upcoming obligation**
  with its date — a readiness finding, never a current breach.
- **Grandfathering (Art. 111(2)).** A high-risk system placed on the market or put into service
  *before* the application date of Chapter III falls under the regime only once its design
  changes significantly afterwards (systems used by public authorities: by 2 Aug 2030). After
  2 Dec 2027, establish when the system went into service and whether it changed before
  calling a missing Art. 26 measure a breach. This does not cover Art. 50.
- **Art. 5(1)(ba)/(bb)** apply from 2 Dec 2026; before that date they are upcoming.

## Risk tiers

1. **Prohibited (Art. 5)** — must stop immediately. Penalty tier 1.
2. **High-risk (Art. 6 + Annex III)** — full regime: provider docs/QMS/registration; deployer
   duties under Art. 26. Obligations apply from 2 Dec 2027 (Annex III) / 2 Aug 2028 (Annex I).
   Web-relevant Annex III entries:
   - **4(a)** recruitment: CV screening, **targeted job ads**, candidate evaluation
   - **5(b)** creditworthiness scoring · **5(c)** health/life insurance risk pricing
   - access to essential private/public services; **8(b)** election influence
   - Profiling of natural persons (work performance, economic situation, **health**, preferences,
     behaviour, location) within Annex III contexts is **always high-risk**.
   - **Art. 6(3) filter:** an Annex III system is *not* high-risk when it poses no significant
     risk to health, safety or fundamental rights — it performs a narrow procedural task,
     improves the result of a completed human activity, detects decision patterns without
     replacing the human assessment, or does a preparatory task — and does no profiling. The
     provider documents that assessment. "AI touches a decision about a person" is therefore
     not enough: the use must fall in an Annex III area and outside this filter.
   - The Commission guidelines on high-risk classification (Art. 6(5)) are still a **draft**
     (published 19 May 2026, not adopted as of 2026-11-24) — cite them as non-final
     interpretation only.
3. **Limited risk (Art. 50)** — transparency only: chatbots, genAI content, deepfakes, emotion
   recognition, biometric categorisation. The core tier for typical SME websites.
4. **Minimal risk** — no Act obligations beyond Art. 4: spam filters, non-decisional analytics,
   AI in games, internal productivity use of AI tools.

## Art. 5 — prohibited practices (full list, web-relevance flag)

| § | Practice | Web/marketing relevance |
|---|---|---|
| (a) | Subliminal / purposefully manipulative or deceptive techniques materially distorting behaviour, causing significant harm | **HIGH** — AI-driven dark patterns, manipulative personalization, deceptive sales bots |
| (b) | Exploiting vulnerabilities of age, disability, social/economic situation | **HIGH** — AI targeting of seniors, the ill, the indebted; critical in health verticals |
| (ba) | *From 2 Dec 2026.* AI that generates or manipulates realistic intimate or sexually explicit imagery of an identifiable person without their freely given, specific, informed, unambiguous and explicit consent | LOW for a typical deployer — **HIGH** where the site offers its own image/video generation or face-swap (provider: caught when this is the intended purpose or a foreseeable, reproducible outcome without adequate safeguards — Art. 5(1a)) |
| (bb) | *From 2 Dec 2026.* AI generating child sexual abuse material within Directive 2011/93/EU | as (ba) |
| (c) | Social scoring → unjustified detrimental treatment in unrelated contexts | possible — lead/customer scoring leaking across contexts |
| (d) | Crime prediction solely from profiling/personality traits | rare on SME sites |
| (e) | Untargeted scraping of facial images (internet/CCTV) for face-recognition databases | possible in marketing data ops |
| (f) | Emotion inference in **workplace and education** (exception: medical/safety) | **HIGH** — HR video-interview emotion analysis, employee monitoring |
| (g) | Biometric categorisation inferring race, political opinion, religion, sexual orientation, etc. | possible in photo/video analytics |
| (h) | Real-time remote biometric identification in public spaces (law enforcement) | not website-relevant |

For (ba)/(bb) a deployer's *use* is prohibited only where it uses the system for the purpose of
generating or manipulating such material (Art. 5(1a)(b)); an edit that does not increase exposure
is not "manipulation" (Art. 5(1b)).

Screen priorities for a website audit: **(a), (b), (f)** — plus **(ba)** when the site has its own
image or video generator.

## Art. 50 — transparency (the core of a website audit)

Paragraphs 1–6 are unchanged by the Omnibus. Paragraph numbers in brackets below are the
Commission's Art. 50 Guidelines.

1. **50(1) — human interaction (chatbots, voice bots, AI agents).** A **provider** duty: the
   person must **know they interact with AI**, unless obvious to a reasonably informed person.
   Disclosure at the latest at first interaction, clear and distinguishable, meeting
   accessibility requirements (50(5)).
   - Who is the provider: a company that develops a chatbot in-house — also on a third-party LLM
     API — and puts it into service under its own name **is a provider** (11); so is one that
     rebrands or modifies a generative system. A vendor widget used as-is leaves the vendor as
     provider; the site operator's exposure is indirect, but the missing notice is still the
     operator's to fix (most widgets expose the greeting text).
   - **Not sufficient on their own** (38): disclosure only in terms and conditions, a URL or
     documentation; a machine-readable mark; a generic name such as "assistant" or a human-like
     persona; a site-wide "services on this website use AI"; "this system uses LLMs".
   - Cadence (40, 143): one prominent notice before the first interaction usually suffices;
     riskier contexts (finance, insurance, legal, **health advice**, complaints, vulnerable
     users) call for a persistent indication or periodic reminders. The bot must disclose its
     nature when asked.
   - AI agents (31) are covered: they disclose that they are AI and on whose behalf they act.
2. **50(2) — synthetic content marking.** The **provider** of a generating system marks output
   as artificially generated in a machine-readable format **and** makes it detectable — marking
   *and* detection are both required (70). A proprietary `<meta>` tag or a JSON flag is
   machine-readable but is not a detection mechanism: use an established provenance standard
   (C2PA manifest; IPTC `DigitalSourceType` =
   `http://cv.iptc.org/newscodes/digitalsourcetype/trainedAlgorithmicMedia`), written **at
   generation time** — provenance reconstructed later from configuration drifts.
   - Out of scope (68, 90–92): alt-text, captions, UI labels, icon-scale graphics, source code,
     machine-to-machine output; standard editing, translation and minor polishing.
   - *This duty sits on the tool provider, not the publishing SME* — but a publisher's build
     pipeline that strips provenance metadata breaks the chain (flag as a best-practice issue),
     and a site offering its own generator is a provider for that feature.
   - Grace: generative systems placed on the market before 2 Aug 2026 had until 2 Dec 2026
     (Art. 111(4)).
3. **50(3) — emotion recognition / biometric categorisation.** Deployer **informs exposed
   persons** + GDPR compliance.
4. **50(4) — deepfakes & public-interest text.** A **deployer** duty.
   - **Deepfake** (113–116): content resembling existing persons, objects, places, entities or
     events that would falsely appear authentic — including things that "exist, can plausibly
     exist or could have plausibly existed". Photorealism is not determinative and intent to
     deceive is not required; the audience includes children and the elderly. *Deepfakes:* a
     synthetic CEO avatar, an AI influencer in an ad, a fictitious but plausible person
     ("our doctor"), an **AI product image that misleads about the real product**. *Not
     deepfakes:* fantasy scenes, a real product on an AI background that does not mislead,
     aesthetic background edits, a plain AI illustration.
   - **Deepfake label** (117): perceivable without tools. A deployer **cannot rely on the
     provider's machine-readable marking** — metadata alone fails. Artistic/satirical works need
     only non-intrusive disclosure.
   - **Public-interest text** (131): AI-generated text **published to inform the public on
     matters of public interest** — open to an indeterminate public, not internal or closed
     groups. In scope: health and diet articles, investor reports, safety warnings. **Out of
     scope: advertisements and product descriptions**, unless they make claims about health,
     consumer safety or sustainability.
   - **The duty is disclosure OR human editorial review — not both.** The exemption (133–138)
     needs substantive review by a competent person plus a natural or legal person holding
     editorial responsibility. **Fact-checking is the minimum.** A spell-check, a mere editorial
     policy, an automated review, a cursory approval or a declaration without a read does not
     count. The review must cover the **final published text**: substantive AI edits after
     sign-off void it, and a machine translation produced after the review is an unread text —
     review status is per language version. The identity or contact of whoever holds editorial
     responsibility should be publicly available in an easily findable place (imprint, legal
     notice).
5. **Code of Practice on Transparency of AI-generated Content** (final 10 Jun 2026; found
   adequate by the Commission and the AI Board in July 2026). Section 1: providers, marking and
   detection (50(2)); Section 2: deployers, labelling deepfakes and public-interest text (50(4)).
   It does not cover 50(1) or 50(3). Providers and deployers can sign. Its Annex I carries an
   **optional EU icon** — a ready-made visible label. Signatories are supervised on adherence;
   a non-signatory must show adequate alternative means, e.g. a gap analysis against the code;
   adherence can mitigate a fine (Art. 99(7)(e)). Detailed placement rules of the code are not
   encoded here (see sources.md → Not confirmed).

## Art. 4 — AI literacy (amended, in force 27 Jul 2026 — every provider AND deployer)

Providers and deployers **take measures to support** the development of AI literacy of their
staff and other persons operating AI systems on their behalf, considering their knowledge, the
context of use and the persons affected. The article expressly does not require guaranteeing any
specific level of literacy of any individual. The Commission and Member States must support
these efforts, SMEs in particular, and the Commission publishes practical examples. Even a
micro-business using ChatGPT counts. Audit expectation: evidence of *some* proportionate measure
— an instruction, a short training, internal guidance.

## Art. 4a — special-category data for bias detection (in force 27 Jul 2026)

A **permission, not a duty**: providers and deployers of AI systems may exceptionally process
special-category personal data when strictly necessary for bias detection and correction, under
cumulative safeguards (no effective alternative such as synthetic or anonymised data;
pseudonymisation and re-use limits; access controls; no transmission to other parties; deletion
once the bias is corrected; the necessity recorded in the GDPR records of processing). Never a
finding on its own — relevant only when the audited org claims this basis.

## Roles — who carries which duty

- **Provider** — develops (or commissions) and places on the market or puts into service under
  own name; includes non-EU providers whose output is used in the EU. An in-house chatbot built
  on a third-party model is a provider case.
- **Deployer** — uses AI under its authority **in the course of professional activity** (purely
  personal use is out of scope). "Authority" = deciding to deploy and how to use; no technical
  control is needed (12). Embedding a vendor chatbot or publishing ChatGPT/Midjourney output =
  deployer. Employees and freelancers acting for the org are not separate deployers (14).
- **Not a deployer:** a company that merely commissions an agency without deciding or
  controlling whether and how the agency uses AI — the agency is the deployer.
- **Art. 25 — deployer BECOMES provider** when it: (a) puts its **own name/brand** on a high-risk
  system (white-label "our proprietary AI assistant"), (b) substantially modifies a high-risk
  system, (c) repurposes any system (incl. GPAI) so it becomes high-risk. Then full Art. 16
  provider duties apply. Amended Art. 25(2)/(4): the initial provider must cooperate, unless it
  clearly specified that the system must not be changed into a high-risk one.
- **SMEs: no exemptions**, only facilitations — simplified technical documentation and QMS
  elements, free priority sandbox access, proportionate fees, penalties "whichever is **lower**"
  (Art. 99(6)). **Small mid-caps (SMCs**, Recommendation (EU) 2025/1099) now share most of them,
  incl. simplified technical documentation (Art. 11(1)) and the same fine cap for tier-2 and
  tier-3 fines (Art. 99(6a) — not for Art. 5).

## Art. 26 — deployer duties for high-risk systems (from 2 Dec 2027 for Annex III, 2 Aug 2028 for Annex I)

Text unchanged by the Omnibus; only the application date moved. Use per provider's instructions
· competent human oversight assigned · monitoring + incident procedure · auto-generated logs
kept ≥ 6 months · **inform workers before workplace deployment** · inform persons subject to
decisions · DPIA where applicable. The fundamental-rights impact assessment (Art. 27) may
cross-reference the GDPR DPIA.

## Art. 99 — penalties

| Tier | Amount (higher of the two) | "Lower of" instead for | Trigger |
|---|---|---|---|
| 1 | €35 M / 7 % global turnover | SMEs (Art. 99(6)) — **not** SMCs | Art. 5 prohibited practices (incl. (ba)/(bb) from 2 Dec 2026) |
| 2 | €15 M / 3 % | SMEs (Art. 99(6)) and SMCs (Art. 99(6a)) | operator obligations incl. **Art. 50**; Art. 26 once applicable (2 Dec 2027); Art. 25(2)/(4) |
| 3 | €7.5 M / 1 % | SMEs (Art. 99(6)) and SMCs (Art. 99(6a)) | false/incomplete/misleading information to authorities (incl. AI-washing claims made to regulators) |

Art. 99(1) as amended: national rules may also use warnings and non-monetary measures, and must
take into account the interests and economic viability of SMEs, start-ups and SMCs.

## Out-of-scope reminders

Personal non-professional use · military/defence · pure scientific R&D · open-source components
below risk thresholds. "AI-powered" marketing claims as such are UCPD (unfair commercial
practices) territory, not the Act — but false claims can drag a product into scope or become
tier-3 misleading information.
