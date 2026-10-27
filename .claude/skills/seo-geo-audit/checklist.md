# SEO + GEO on-site checklist

Reference for `/seo-geo-audit`. Every row names the evidence field in the
`fetch-site.mjs` JSON (`probe.*`), the matching Audit AI checkpoint where one
exists (id → meaning in the appendix at the end of this file), and the fix direction.
Verdicts: `pass` / `warn` / `fail` / `unknown` (could not verify — never guess).

Priority buckets used in the report:

- **P1 — blokery** — the page cannot be found, read or trusted by crawlers / AI
- **P2 — duży wpływ** — measurable loss of visibility or extractability
- **P3 — quick wins** — cheap, template-level fixes
- **P4 — do rozważenia** — agent protocols and emerging signals; always last

---

## A. Crawlability & indexation (SEO + GEO shared)

| Check | Evidence | Audit AI | Verdict rule | Fix |
| --- | --- | --- | --- | --- |
| Page returns 200 over HTTPS | `probe.page.status`, `probe.page.finalUrl` | 5.1 | non-200 or http final URL → fail (P1) | fix server / redirect |
| HTTP → HTTPS redirect | `probe.httpToHttps.finalUrl` starts with `https://` | 5.1 | no redirect → warn | 301 at edge/server |
| robots.txt exists and parses | `probe.robots.status`, `probe.robots.missing` | 1.1 | 404 → warn (crawlers assume allow); 5xx → fail | add `/robots.txt` |
| Sitemap declared and valid | `probe.robots.sitemapsDeclared`, `probe.sitemaps[].valid`, `urlCount` | 1.3, 1.4 | missing → warn; invalid XML / 0 URLs → fail | generate sitemap, reference it in robots.txt |
| Sitemap freshness | `probe.sitemaps[].hasLastmod` | — | no `<lastmod>` → P3 note | emit `lastmod` |
| meta robots / X-Robots-Tag | `probe.page.metaRobots`, `probe.page.security.xRobotsTag` | 1.7 | `noindex` or `nosnippet`/`max-snippet:0` on a public page → fail (P1) | remove directive |
| Canonical present and self-referencing | `probe.page.canonical` vs `finalUrl` | — | missing → warn; points elsewhere → investigate (duplicate / wrong canonical) | add `<link rel="canonical">` |
| Canonical target reachable | `probe.canonicalTarget.status` / `location` | — | 3xx or 404 → fail (P2): a canonical that redirects or dies is a contradictory signal | point canonical at the final 200 URL |
| Snippet eligibility (Google AI features need indexable **and** snippet-eligible pages) | `probe.page.snippetEligibility.{noindex,nosnippet,dataNosnippetElements}` | 1.7 (superset) | `noindex`/`none` → fail (P1); `nosnippet` or `max-snippet:0` → fail (P1 for GEO); many `data-nosnippet` on main content → warn | remove directives |
| Soft-404 | `probe.soft404.isSoft404` | — | random path answers 200 → warn (P2): crawlers and agents get "pages" that do not exist | return 404/410 for unknown routes |
| hreflang consistency (multi-locale only) | `probe.page.hreflang`, `probe.sitemaps[].hasXhtmlLink` | — | self-reference + `x-default` missing → warn | add self-referencing hreflang + `x-default` on every locale |
| TTFB (headers received; `downloadMs` is the full fetch) | `probe.page.ttfbMs` | — | > 800 ms → warn, > 1500 ms → fail (P2); single sample — say so | cache / CDN |

## B. AI bot access (GEO — the Audit AI rule set)

Bot roles follow the Audit AI `AI_BOT_REGISTRY` (source of truth: Audit AI). Only **retrieval** bots decide whether a site can be cited. Blocking **training** crawlers is a content-owner decision and is never a finding.

| Check | Evidence | Audit AI | Verdict rule | Fix |
| --- | --- | --- | --- | --- |
| Retrieval bots allowed (OAI-SearchBot, Claude-SearchBot, Claude-User, PerplexityBot) | `probe.robots.retrieval` | 1.2 | all blocked → fail (P1); some → warn; `Disallow: /` under `*` with no named exemption → fail | add named groups with `Allow: /` for retrieval bots |
| Search bots allowed (Googlebot, Bingbot) | `probe.robots.search` | — | blocked → fail (P1) | remove Disallow |
| WAF does not block AI bots | `probe.wafProbeAsRetrievalBot.blocked`, `probe.page.security.cfRay` | 1.8 | 403/429 for a retrieval UA while browser UA gets 200 → fail (P1) | Cloudflare: allow verified bots / skip managed challenge for listed UAs |
| Same content for bots and browsers (cloaking / thin bot version) | `probe.uaDifferential[*].{status,title,textRatioVsBrowser,noindex}` | — | any bot UA with `textRatioVsBrowser` < 0.6, a different title, or `noindex` only for bots → warn (P2). **Heuristic**: real bots are IP-verified, so say "wskazanie, nie dowód" | serve identical HTML; check CDN bot-management rules |
| Training bots (GPTBot, ClaudeBot, CCBot, Meta-ExternalAgent) | `probe.robots.training` | 1.2 note | **informational only** — report the owner's current policy, never recommend `Allow` | — |
| Opt-out tokens (Google-Extended, Applebot-Extended) | `probe.robots.optOut` | — | informational; note that Google-Extended does **not** affect AI Overviews or Search | — |
| Content-Signal directives | `probe.robots.contentSignal` | 1.10 | absent → P4 note | optional `Content-Signal:` line |

## C. AI-readability files (GEO)

| Check | Evidence | Audit AI | Verdict rule | Fix |
| --- | --- | --- | --- | --- |
| llms.txt exists | `probe.llmsTxt.status` | 1.5 | 404 → warn (P3) | add `/llms.txt` — mark as **unconfirmed ranking signal**, cheap hygiene |
| llms.txt has content (≥ 100 chars, links to key pages) | `probe.llmsTxt.chars`, `head` | 1.6 | thin → warn | describe business, link services/pricing/contact |
| llms.txt reachable by bots and its links resolve | `probe.llmsTxt.disallowedInRobots`, `sampledLinks[].status` | — | disallowed in robots → fail (the file exists but bots may not read it); any sampled link ≥ 400 → warn (dead links undermine the file) | fix robots / update links |
| Markdown for agents (`Accept: text/markdown` negotiation, `<link rel="alternate" type="text/markdown">`, `.md` mirror) | `probe.markdownForAgents` | — | absent → **informational only**, report in P4 ("nie serwuje markdown dla agentów"); served but `varyAcceptMissing: true` → warn (cache may hand markdown to browsers) | Cloudflare "Markdown for Agents" or static `.md` mirror; add `Vary: Accept` |
| pricing.md / machine-readable offer | `probe.wellKnown["/pricing.md"]` | — | only for sites that sell online or have public prices; otherwise skip | markdown file at root |
| Link headers RFC 8288 (`service-desc`, `api-catalog`) | `probe.page.security.linkHeader` | 1.9 | absent → P4 | header on the root response |

## D. Rendering & semantics (SEO + GEO shared)

| Check | Evidence | Audit AI | Verdict rule | Fix |
| --- | --- | --- | --- | --- |
| Content visible without JS (SSR) | `probe.page.bodyTextChars`, `emptyAppShell`; Playwright rendered text for comparison | 3.1 | raw HTML < 500 chars of text while rendered page has content → fail (P1) | SSR / prerender |
| Exactly one H1, hierarchy without skipped levels | `probe.page.h1Count`, `headings[]` | 3.2 | 0 or >1 H1 → warn; skips → warn | fix template |
| Semantic landmarks (`header`, `nav`, `main`, `footer`) | `probe.page.semanticTags` | 3.3 | `main` missing → warn | wrap content |
| ARIA landmarks | `probe.page.ariaLandmarks` | 3.4 | 0 and no semantic tags → warn | prefer native tags |
| Alt coverage ≥ 90% | `probe.page.images` | 3.5 | < 90% → warn; < 50% → fail | add alt |
| `<html lang>` | `probe.page.lang` | 3.6 | missing or wrong language → warn | set lang |
| Link text quality | `probe.page.weakAnchors` / `internalLinks` | 3.7 | > 10% weak anchors → warn | descriptive anchors |
| Answer capsules — direct Q&A blocks the model can lift | manual read of `bodyTextSample` + headings phrased as questions; `probe.page.faqMarkup` | 3.8 | no question-shaped headings and no FAQ → warn (P2) | add FAQ section with 40–60-word direct answers |
| Mixed content | `probe.page.mixedContent` | — | true → warn | https assets |
| Viewport meta (mobile) | `probe.page.viewport` | — | missing → warn | add viewport |

## E. On-page SEO (classic on-page checks)

| Check | Evidence | Verdict rule | Fix |
| --- | --- | --- | --- |
| Title 30–60 chars, unique, keyword early | `probe.page.title` | missing → fail; > 60 or < 30 → warn | rewrite |
| Meta description 50–160 chars | `probe.page.metaDescription` (Audit AI 3.9) | missing → warn; outside range → P3 | rewrite |
| H1 matches the page intent / title | `headings[0]` vs `title` | mismatch → P3 note | align |
| Open Graph title/image | `probe.page.ogTitle`, `ogImage` | missing → P3 | add OG tags |
| URL structure | `finalUrl` and `sitemaps[].sampleUrls` | parameters / uppercase / no words → P3 | — |
| Internal linking | `probe.page.internalLinks` | < 5 on homepage → warn | link key pages |
| Thin page | `bodyTextChars` | < 1500 chars on a service/home page → warn (P2) | expand content |
| E-E-A-T surface | manual: author/owner named, contact + address, privacy policy link, credentials | missing on a business/medical site → warn (P2) | add about/author/contact blocks |
| Freshness | `sitemaps[].hasLastmod`, visible dates, `dateModified` in schema | none → P3 | show updated date |

## F. Structured data (SEO + GEO shared)

JSON-LD counts in full; microdata counts half (Audit AI rule). Raw HTML may miss JS-injected schema — confirm with Playwright `document.querySelectorAll('script[type="application/ld+json"]')` before reporting "no schema".

| Check | Evidence | Audit AI | Verdict rule | Fix |
| --- | --- | --- | --- | --- |
| Any JSON-LD | `probe.page.jsonLdBlocks`, `schemaTypes` | 2.1 | 0 (also after render) → fail (P2) | add Organization/LocalBusiness block |
| Organization / LocalBusiness with address, phone, openingHours | `schemaTypes` contains `Organization` or a LocalBusiness subtype | 2.5 | missing → warn | JSON-LD |
| BreadcrumbList on subpages | `schemaTypes` on subpage probes | 2.4 | missing → P3 | JSON-LD |
| FAQPage where FAQ exists | `faqMarkup` vs `FAQPage` | 2.6 | visible FAQ without schema → warn | JSON-LD |
| Article + author on blog posts | subpage `schemaTypes` | 2.8, 2.9 | missing → warn (blog only) | JSON-LD |
| Product + offers (e-commerce) | subpage `schemaTypes` | 2.2, 2.3 | missing → fail (e-commerce only) | JSON-LD |
| AggregateRating / Review | `schemaTypes` | 2.7 | missing where reviews are shown → P3 | JSON-LD |
| Invalid JSON-LD block | `probe.page.jsonLdErrors[]`, `jsonLdValid` vs `jsonLdBlocks` | — | any error → fail | fix JSON |

## G. Security headers (Audit AI category 5)

| Header | Evidence | Audit AI | Verdict |
| --- | --- | --- | --- |
| HSTS | `security.hsts` | 5.2 | missing → warn |
| CSP | `security.csp` | 5.3 | missing → warn (P3, hard to add on CMS — say so) |
| X-Content-Type-Options | `security.xContentTypeOptions` | 5.4 | missing → P3 |
| X-Frame-Options / frame-ancestors | `security.xFrameOptions` | 5.5 | missing → P3 |
| Referrer-Policy | `security.referrerPolicy` | 5.6 | missing → P3 |

## H. Agent protocols — report only in "Do rozważenia później" (P4)

Never in the top findings, never in quick wins. One short block at the end: what exists, what could be added, in this order of maturity.

| Check | Evidence | Audit AI | Note |
| --- | --- | --- | --- |
| WebMCP declarative (`toolname` / `tooldescription` on forms) | `probe.page.webmcpDeclarative` | 4.1 | only relevant when the site has forms worth exposing (booking, contact, quote) |
| WebMCP imperative (`navigator.modelContext`) | `probe.page.webmcpImperative` | 4.2 | |
| MCP server card `/.well-known/ai-catalog.json` | `probe.wellKnown` | 4.4 | |
| A2A agent card `/.well-known/agent-card.json` | `probe.wellKnown` | 4.3 | SaaS only |
| agents.json / OpenAPI | `probe.wellKnown` | 4.5, 4.6 | SaaS / API products |
| Markdown for agents | `probe.markdownForAgents` | — | one line: served / not served; documented by Cloudflare and Vercel, no engine documents using it for citations |
| NLWeb, DNS-AID | not probed | 4.11, 4.12 | mention as emerging, no action |
| Commerce protocols (UCP, ACP, AP2, x402, MPP) | not probed | 6.x | e-commerce only, experimental |

---

## Things this audit does NOT measure — say so in the report

- Rankings, traffic, backlinks, Search Console data (no access)
- Core Web Vitals field data (only TTFB and HTML weight are measured)
- Whether any AI engine currently cites the site (no prompt tracking)
- Content quality beyond the structural signals above (handled by Audit AI Retrieval Score when the engine report is available — quote it, do not re-derive it)

---

## Appendix — Audit AI checkpoint ids referenced above

Short map of the engine checkpoints the rows cite (id → meaning). Level `must` /
`should` / `optional` is the engine's own classification; weight 0 means a bonus
signal that never affects grade, blockers or quick wins. The full registry lives
in Audit AI; this list only makes the `Audit AI` column readable without it.

| Id | Meaning | Level |
| --- | --- | --- |
| 1.1 | robots.txt exists | must |
| 1.2 | robots.txt allows AI **retrieval** bots | must |
| 1.3 | sitemap.xml exists | must |
| 1.4 | sitemap.xml valid (XML parseable) | must |
| 1.5 | llms.txt exists | must |
| 1.6 | llms.txt has content (min 100 chars) | must |
| 1.7 | meta robots does not block AI (`noindex` / `nosnippet`) | must |
| 1.8 | WAF / firewall does not block AI bots | must |
| 1.9 | Link headers RFC 8288 (`api-catalog`, `service-desc`) | should |
| 1.10 | Content-Signal directives in robots.txt (IETF draft) | optional |
| 2.1 | JSON-LD exists | should |
| 2.2 | Schema.org Product (JSON-LD full, microdata 50 %) — e-commerce | should |
| 2.3 | Product required fields (name, image, description, brand, offers) — e-commerce | should |
| 2.4 | BreadcrumbList | should |
| 2.5 | Organization schema | should |
| 2.6 | FAQ schema | should |
| 2.7 | AggregateRating / Reviews — e-commerce | should |
| 2.8 | Article schema — blog | should |
| 2.9 | Author schema — blog | should |
| 3.1 | SSR — content visible without JS | must |
| 3.2 | Heading hierarchy valid (H1 → H2 → H3) | must |
| 3.3 | Semantic HTML tags (header, nav, main, footer) | should |
| 3.4 | ARIA landmarks | should |
| 3.5 | Alt text coverage ≥ 90 % | must |
| 3.6 | Language tag (`<html lang>`) | must |
| 3.7 | Link text quality (not "click here") | should |
| 3.8 | Answer capsules (Q&A blocks an AI can lift) | should |
| 3.9 | Meta description 50–160 chars | must |
| 4.1 | WebMCP declarative (`toolname` / `tooldescription` on forms) | must (P4 here) |
| 4.2 | WebMCP imperative (`navigator.modelContext`) | should (P4 here) |
| 4.3 | A2A agent card (`/.well-known/agent-card.json`) — SaaS | optional, weight 0 |
| 4.4 | MCP server card (`/.well-known/ai-catalog.json`) | optional, weight 0 |
| 4.5 | OpenAPI / Swagger — SaaS | should |
| 4.6 | agents.json | optional |
| 4.11 | DNS-AID (HTTPS DNS records under `_agents`) | optional, weight 0 |
| 4.12 | NLWeb (`/ask` MCP endpoint over Schema.org) | optional, weight 0 |
| 5.1 | HTTPS + SSL expiry > 30 days | must |
| 5.2 | HSTS header | must |
| 5.3 | Content-Security-Policy | must |
| 5.4 | X-Content-Type-Options | must |
| 5.5 | X-Frame-Options | must |
| 5.6 | Referrer-Policy | must |
| 6.x | Commerce protocols (x402, MPP, UCP, ACP, AP2) — e-commerce, experimental | optional |

Category 4 and 6 checkpoints are reported **only** in the P4 block regardless of
their engine level — see section H.
