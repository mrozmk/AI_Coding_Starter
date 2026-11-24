# Risk-classification triage — decision tree

Run **per AI touchpoint** found in the inventory (not once per site — a site can host a
minimal-risk analytics setup AND a limited-risk chatbot AND a high-risk careers form).
Logic replicates the FLI EU AI Act Compliance Checker flow, ordered by precedence:
prohibited > high-risk > limited > minimal. Dates and article texts: [legal-refs.md](legal-refs.md)
(last verified 2026-11-24).

Record for each touchpoint: `tier`, `role`, and `decidingRule` (the step that fixed the tier).
The tier says what the touchpoint **is**; whether its obligations already apply on the audit date
is a separate question (legal-refs.md → Date rules) and decides `fail` versus an upcoming
obligation.

## Step 0 — Is it an AI system in scope?

- Machine-based system inferring outputs (predictions, content, recommendations, decisions)
  from inputs with some autonomy? Plain rule-based scripts, static content, standard analytics
  counters → **not an AI system → out of scope**.
- Used in / output reaches the EU? No → out of scope.
- Purely personal, military, or pure-research use? → out of scope.
- Company merely *uses* AI tools internally for productivity (drafting, summarising, coding),
  with no user-facing AI, no published AI output and **no evaluation of or decision about
  persons** → touchpoint is **minimal**, but the Art. 4 duty to take AI-literacy support
  measures still applies (→ ASK items). An internal tool that screens candidates, scores
  employees or customers, or reads emotions is not "mere internal use" — descend through
  Steps 2–3.

## Step 1 — Role

- Did the audited org **build** the system or commission it under its own name? → **provider**.
  This includes a chatbot built in-house on a third-party LLM API and a rebranded or modified
  generative system.
- Does it **use** a third-party system professionally, deciding to deploy it and how (embedded
  widget used as-is, published genAI output)? → **deployer**.
- Did it only commission an agency, without deciding or controlling whether and how the agency
  uses AI? → **not a deployer** for that output; the agency is. Record it and move on.
- **Art. 25 flip check** (deployer → provider): own brand on a high-risk system · substantial
  modification of a high-risk system · repurposing any system into a high-risk use. If the copy
  says "our proprietary AI" over a white-labeled vendor tool, flag COPY-16 and evaluate the flip.

## Step 2 — Art. 5 screen (STOP flags)

Test against the practices in the legal-refs.md table. Website-priority screens:

- **(a)** Does AI-driven personalization/persuasion materially distort user behaviour in a way
  likely to cause significant harm (deceptive bots, AI dark patterns)?
- **(b)** Does targeting exploit age, disability, or social/economic vulnerability? (Health
  verticals: fear-based dynamic content aimed at ill people.)
- **(f)** Any emotion inference on employees or students?
- **(ba)/(bb)** — applicable from 2 Dec 2026. Does the site offer user-facing image or video
  generation, or face-swap? As a provider: are there safeguards against non-consensual intimate
  imagery of identifiable persons and against CSAM? As a deployer: is such a tool used for that
  purpose? An audit dated before 2 Dec 2026 reports a hit as an upcoming prohibition.

Any hit → tier **prohibited**, severity CRITICAL, stop descending — but still finish the other
touchpoints.

## Step 3 — High-risk screen (Art. 6 + Annex III)

Website-relevant triggers:

- Recruitment/careers: AI CV screening, targeted job ads, candidate scoring → Annex III 4(a)
- Creditworthiness or insurance risk pricing in an online form → Annex III 5(b)/5(c)
- Access/eligibility decisions for essential services
- Profiling natural persons (health, economic situation, behaviour…) within Annex III contexts
- Election/referendum influence tooling → Annex III 8(b)

The test is the **intended use of the deployment**, not the vendor's marketing. A "check if you
qualify" form whose outcome is AI-decided without human review is the classic hidden trigger.
Two conditions make a hit, both needed: the use falls in an **Annex III area** (a form that
routes a support request is not one), and it is **outside the Art. 6(3) filter** — a narrow
procedural or preparatory task with no profiling and no significant risk is not high-risk
(legal-refs.md → Risk tiers). Unclear on either → `needs-owner` (ASK-20), not a tier.
Hit → tier **high-risk**: deployer duties Art. 26 (+ Art. 25 flip check), provider duties if
role=provider. **These obligations apply from 2 Dec 2027** (Annex III; 2 Aug 2028 for Annex I):
before that date report the hit as an upcoming obligation, not a current breach, and ask the
ASK-24 battery as readiness questions. After it, a system already in service before 2 Dec 2027
is covered only once its design changes significantly (Art. 111(2)). The Commission's classification guidelines are still a
draft — a borderline case stays `needs-owner`.

## Step 4 — Art. 50 screen (limited risk)

- Interacts with humans (chatbot, voice bot, AI email or booking agent)? → 50(1) disclosure
  checks (CODE-01/02). Own-built bot → the org is the **provider** and directly liable; vendor
  widget used as-is → the vendor is the provider, the org's exposure is indirect.
- Generates synthetic content offered on the site (own generator feature)? → org is a
  **provider** for that feature → 50(2) machine-readable marking **and** detection (CODE-09).
  A generator placed on the market before 2 Aug 2026 had until 2 Dec 2026; no grace after.
- Publishes deepfake-type media, incl. fictitious-but-plausible persons and product images that
  mislead about the real product? → 50(4) disclosure (CODE-04, COPY-11)
- Publishes AI text on matters of public interest? → 50(4): disclosure or genuine human
  editorial review (COPY-10, COPY-17, ASK-19). Advertising and product descriptions are out of
  scope unless they make health, safety or sustainability claims.
- Emotion recognition / biometric categorisation of visitors? → 50(3) information duty (CODE-07, COPY-15)

For published content check the **date** first (legal-refs.md → Date rules): text published
before 2 Aug 2026, or media generated before it and not modified since → no Art. 50 duty.

Hit → tier **limited**.

## Step 5 — Fallback

Nothing above → tier **minimal**. Remaining duties: Art. 4 literacy measures (if org uses AI at
all) and good-practice recommendations only. Say so plainly — an honest "minimal risk" verdict is
a feature, not a failure of the audit.
