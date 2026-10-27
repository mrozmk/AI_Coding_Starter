---
name: seo-geo-audit
description: Technical on-site audit of a live website for classic SEO and GEO (readiness for AI search engines and agents — ChatGPT, Claude, Perplexity, Gemini). Use when the user asks for "audyt SEO", "audyt GEO", "audyt strony pod AI", "AI readiness", "czy AI widzi moją stronę", "sprawdź stronę pod kątem SEO", "SEO + GEO audit", "GEO audit", "AEO", "LLM visibility", or gives a URL and wants to know what to fix. Probes robots.txt, sitemap, llms.txt, bot access, rendering, headings, schema, security headers; optionally pulls a scored Audit AI engine report over MCP; writes a Polish report to .agents/handoffs/ and recommends next steps. Scope is the technical on-site layer only — not content-marketing strategy, citations or off-site presence.
argument-hint: <url> [more urls…] [--no-engine] [--no-browser] [--en]
---

# /seo-geo-audit — SEO + GEO on-site audit

Audit a live site the way Audit AI's engine does, plus the classic on-page SEO checks, and turn the evidence into a prioritized, Polish-language report. **Evidence only** — every finding cites the probe field, header, or rendered DOM it came from. No ranking statistics, no "studies show", no guessed verdicts.

Materials (full paths — this file lives in `commands/`):

- `.claude/skills/seo-geo-audit/checklist.md` — the check table, verdict rules, priorities
- `.claude/skills/seo-geo-audit/fetch-site.mjs` — deterministic GET probe (robots, sitemap, llms.txt + its links, headers, HTML signals, snippet eligibility, bot-UA differential, soft-404, canonical target, markdown negotiation)
- `.claude/skills/seo-geo-audit/auditai-mcp.mjs` — scored engine report via the public Audit AI MCP server
- `checklist.md` ends with an appendix mapping engine checkpoint ids to their meaning

## Preconditions

- `node` ≥ 20 on PATH (both helpers use global `fetch`).
- Network access to the target site and, unless `--no-engine`, to `https://auditai.cc`.
- The helpers use Node `fetch` for every request (including the MCP POSTs) — do not reimplement them with `curl`; many projects deny-list `curl` POST.

## Process

### 0. Parse arguments and set up

- Collect every URL in `$ARGUMENTS` (bare domains get `https://`). The first is the **primary** page; the rest are extra pages to probe. If no URL → ask for one and stop.
- Flags: `--no-engine` skips Step 2; `--no-browser` skips Step 3; `--en` writes the report in English (default Polish).
- `SCRATCH=<session scratchpad dir>/seo-geo-audit/<domain>` — probe JSON goes there, never into the repo.
- Read `.claude/skills/seo-geo-audit/checklist.md` now; it drives Step 4.
- Site context (optional): if `.agents/product-marketing.md` or `.claude/product-marketing.md` exists, read it. Otherwise infer the site type (local business, e-commerce, SaaS, blog, corporate) from the probe and say which you assumed.

### 1. Probe the pages (deterministic)

```bash
node .claude/skills/seo-geo-audit/fetch-site.mjs <primary-url> "$SCRATCH/home.json"
```

Then pick **up to 3 extra pages** when the user gave none: one service/product page, one article/blog page if the site has one, and the contact page — take candidates from `sitemaps[].sampleUrls` and the nav links in the HTML. Probe each into `"$SCRATCH/<slug>.json"`. More pages only when the user asks; this is a technical on-site audit, not a crawl.

Read each JSON with the Read tool. The probe is GET-only and does not run JavaScript — a `jsonLdBlocks: 0` or `emptyAppShell: true` here is a **hypothesis**, confirmed in Step 3.

### 2. Engine report (scored second opinion) — in the background

Unless `--no-engine`:

```bash
node .claude/skills/seo-geo-audit/auditai-mcp.mjs <primary-url> "$SCRATCH/auditai.json" pl
```

Run it with `run_in_background: true` and carry on with Step 3 — a fresh audit takes 1–5 minutes; a `cached: true` answer returns at once. Exit code `3` or a non-`COMPLETED` status means **no engine report** (site blocks the crawler, rate limit, worker failure). That is a fact about the engine run, not about the site: say "raport silnika niedostępny: <reason>" in the report and continue with Steps 1 + 3 only. Never invent a grade.

When it succeeds, read `auditai.json` and use: `overallGrade`, `overallScore`, `categoryGrades`, `checkpoints[].{id,name,result.status,result.message}`, `topBlockers`, `quickWins`, `retrievalScore`, `agentUnderstandability`, `aiProvenance`. When the engine and the probe disagree: a **fresh** engine run (`cached: false` in the script output) wins — it runs a headless browser and the full RFC 9309 robots evaluation. A **cached** run (`cached: true`; the engine clones any COMPLETED audit of the same URL from the last 24 h, and MCP cannot force a fresh one) may predate a fix or a new block, so the **probe wins** and the report says "raport silnika z cache (<completedAt>), rozbieżność: …". Note every disagreement either way. `reportUrl` goes into the report as the public link.

**Engine sanity check — a bad engine result may be a block, not a verdict.** Before quoting the engine, run this when **any** of these holds: the script exited 3, `overallGrade` is `D` or `F`, more than 5 checkpoints have `result.status: "unknown"`, or `discovery.waf-not-blocking` is not `pass`:

1. Look at `probe.wafProbeAsAuditAiBot` (the probe already fetched the page with the engine's own UA `AuditAI/1.0`) and `probe.wafProbeAsRetrievalBot`. `blocked: true`, or `textChars` far below the browser-UA `bodyTextChars`, means the site serves bots a challenge / empty page.
2. If blocked: the engine grade is **unreliable** — report it as "ocena silnika zaniżona/niedostępna przez blokadę botów (WAF/CDN)", move the block itself to **P1** (it also hides the site from real AI retrieval bots, checkpoint 1.8), and base every other verdict on the browser-UA probe and the Playwright render. Do not list the engine's `fail` checkpoints as site findings.
3. If not blocked (bots get the same 200 and similar text): the D/F grade stands — say explicitly that the block hypothesis was checked and ruled out.
4. If the engine failed for another reason (`server_busy`, rate limit, timeout): say that, and offer a rerun; it says nothing about the site.

Local engine: `AUDITAI_BASE=http://localhost:3000` when a dev server with worker is running; default is production.

### 3. Rendered check (Playwright MCP, optional) — confirm what GET cannot see

This step needs the Playwright MCP server (`mcp__playwright__*` tools). It is **optional**: when `--no-browser` is given or the tools are not available in this project, write "render check skipped" in the report, treat Step 1 results as unconfirmed, and continue. Otherwise:

- `mcp__playwright__browser_navigate` to the primary URL, wait for network idle.
- `mcp__playwright__browser_evaluate` once, returning in one object: `document.querySelectorAll('script[type="application/ld+json"]').length`, `document.body.innerText.length`, `document.querySelectorAll('h1').length`, `document.documentElement.scrollWidth > window.innerWidth` after `browser_resize` to 390×844 (mobile horizontal scroll), and `navigator.modelContext !== undefined`.
- Compare with the probe: rendered JSON-LD > raw JSON-LD → schema is JS-injected (still counts, note that non-rendering crawlers miss it); rendered text ≫ raw text → SSR finding confirmed.
- Console errors via `mcp__playwright__browser_console_messages` (errors only) — report only if they affect content rendering.

Close the browser page when done. Do not browse beyond the probed pages.

### 4. Evaluate against the checklist

Walk `checklist.md` sections A → H for the primary page, then the extra pages only where the row says "subpage". For every row produce `pass` / `warn` / `fail` / `unknown` with the evidence value. Rules that override everything else:

- **Retrieval vs training bots.** Only OAI-SearchBot, Claude-SearchBot, Claude-User, PerplexityBot (and Googlebot/Bingbot for classic search) decide visibility. A blocked GPTBot/ClaudeBot/CCBot/Meta-ExternalAgent is the owner's policy — report it as information, **never** recommend allowing a training crawler, never count it against the site. Google-Extended is a Gemini-training opt-out, not an AI Overviews switch.
- **`unknown` is a valid verdict.** If a WAF returned 403 to the probe or a page could not be fetched, say so instead of guessing.
- **Bot-UA differential is a heuristic.** Real crawlers are IP-verified; a spoofed UA can get a different answer than the genuine bot. Report differences as "wskazanie" and recommend checking CDN bot-management logs, never as proven cloaking.
- **llms.txt, Content-Signal, Link headers, OKF** are cheap hygiene with **no confirmed ranking effect** — recommend, but label them that way.
- **No numbers you did not measure.** TTFB, counts, lengths and header values from the probe are fine; "+40% visibility" style claims are not.
- **Protocols go last.** WebMCP, MCP server card, A2A, agents.json, OpenAPI, NLWeb, DNS-AID, commerce protocols live only in the final "Do rozważenia później" block — never in blockers, never in quick wins, even when the engine marks them `fail`.

Then assign priorities (P1 blokery → P4 do rozważenia) per the checklist and rank inside each bucket by impact, then by fix cost.

### 5. Write the report

Path: **`.agents/handoffs/seo-geo-audit-YYYY-MM-DD-<domain>.md`** — the same local scratchpad `/handoff` uses (per-clone excluded via `.git/info/exclude`, see `handoff.md` for the one-time setup; create the directory if missing, never commit the report). Language: Polish (English with `--en`). Structure — keep headings exactly, fill with facts:

```markdown
# Audyt SEO + GEO — <domain> (<date>)

## Werdykt
<2–4 sentences: what the site does well, what blocks it, the single most important move.>

| Obszar | Status | Najważniejszy problem |
| Indeksowanie i crawl | ✅/⚠️/❌ | … |
| Dostęp botów AI | … | … |
| Pliki dla AI (llms.txt itd.) | … | … |
| Renderowanie i semantyka | … | … |
| On-page SEO | … | … |
| Dane strukturalne | … | … |
| Nagłówki bezpieczeństwa | … | … |

**Silnik Audit AI:** <grade> (<score>/100), typ strony <siteType>, <N> checkpointów: <fails> fail / <warns> warn — <reportUrl>
(or: raport silnika niedostępny — <reason>)

## P1 — Blokery
### <finding title>
- **Problem:** …
- **Dowód:** `<probe field>` = `<value>` / nagłówek / DOM
- **Wpływ:** SEO | GEO | oba — one sentence
- **Fix:** concrete change (snippet when it is a one-liner: robots.txt group, meta tag, JSON-LD skeleton)

## P2 — Duży wpływ
(same shape)

## P3 — Quick wins
(same shape, shorter)

## Retrieval Score / AI Vision (z silnika, jeśli dostępne)
<quote the engine's findings; do not re-derive>

## Do rozważenia później — protokoły agentowe
<what exists, what is missing, in maturity order; one line each; explicit "wdrażać po P1–P3">

## Czego ten audyt nie mierzy
<the list from checklist.md, verbatim>

## Dane
- Probe: <SCRATCH paths>
- Engine JSON: <path or "brak">
- Render check: wykonany / pominięty
```

Every finding must have a **Dowód** line. A section with nothing in it says "brak" — do not pad.

### 6. Chat summary and next step

In the chat, print only:

1. The `Obszar | Status` table and the engine grade line.
2. Top 3–5 concrete problems (one line each, with the fix in a few words).
3. The report path.
4. **Rekomendacja dalszych kroków**, pick one:
   - P1/P2 findings need design decisions (SSR migration, CMS change, schema model for many page types) → `/brainstorm <topic>` with the report path as input.
   - Only template-level fixes → propose a task list (one line per task, grouped P1→P3) the user can paste into their tracker.
   - Site is clean except P4 → say so; protocols as an optional follow-up.

No procedural narration. Ask nothing unless a URL is missing or the engine and probe disagree in a way that changes the verdict.

## Rules

- **Read-only on the target.** GET requests and one browser render. Never submit forms, never POST to the audited site.
- **Nothing is written to the repo** except the report in `.agents/handoffs/` and nothing in `/tmp`.
- **Audit AI rules beat generic SEO lore** where they conflict (bots, llms.txt, schema partial credit, training policy). Checklist rows cite the engine checkpoint so the mapping is auditable.
- **Engine failure ≠ site failure.** Report it as unavailable and continue.
- **One run, one report file** — re-running the same day overwrites it; say so.
- Report language PL by default; code, snippets, field names stay English.
