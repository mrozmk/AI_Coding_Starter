#!/usr/bin/env node
// Deterministic on-site probe for /seo-geo-audit.
// Usage: node .claude/skills/seo-geo-audit/fetch-site.mjs <url> [out.json]
// Pulls robots.txt, sitemap, llms.txt, headers, the HTML and the
// SEO/GEO signals the checklist needs. GET-only, no JS rendering —
// JS-injected JSON-LD is NOT visible here (use Playwright for that).
// Bot roles (retrieval / training / opt-out) follow the Audit AI
// AI_BOT_REGISTRY (source of truth: Audit AI) — keep in sync.

import { writeFileSync } from "node:fs";

const RETRIEVAL_BOTS = [
  "OAI-SearchBot",
  "Claude-SearchBot",
  "Claude-User",
  "PerplexityBot",
];
const TRAINING_BOTS = ["GPTBot", "ClaudeBot", "CCBot", "Meta-ExternalAgent"];
const OPT_OUT_TOKENS = ["Google-Extended", "Applebot-Extended"];
const SEARCH_BOTS = ["Googlebot", "Bingbot"];
const UA =
  "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 " +
  "(KHTML, like Gecko) Chrome/130.0 Safari/537.36";
const TIMEOUT_MS = 15000;

async function get(url, extraHeaders = {}) {
  const ctrl = new AbortController();
  const t = setTimeout(() => ctrl.abort(), TIMEOUT_MS);
  const started = Date.now();
  try {
    const res = await fetch(url, {
      headers: { "user-agent": UA, accept: "*/*", ...extraHeaders },
      redirect: "follow",
      signal: ctrl.signal,
    });
    // Headers are in once fetch resolves — measure TTFB before reading the body.
    const ttfbMs = Date.now() - started;
    const text = await res.text();
    return {
      ok: res.ok,
      status: res.status,
      finalUrl: res.url,
      ttfbMs,
      downloadMs: Date.now() - started,
      headers: Object.fromEntries(res.headers.entries()),
      text,
    };
  } catch (e) {
    return { ok: false, status: 0, error: String(e?.cause?.code ?? e.message) };
  } finally {
    clearTimeout(t);
  }
}

function parseRobots(text) {
  const groups = [];
  let current = null;
  for (const raw of text.split(/\r?\n/)) {
    const line = raw.replace(/#.*$/, "").trim();
    if (!line) continue;
    const [key, ...rest] = line.split(":");
    const value = rest.join(":").trim();
    const k = key.trim().toLowerCase();
    if (k === "user-agent") {
      if (!current || current.rules.length) {
        current = { agents: [], rules: [] };
        groups.push(current);
      }
      current.agents.push(value.toLowerCase());
    } else if ((k === "disallow" || k === "allow") && current) {
      current.rules.push({ type: k, path: value });
    }
  }
  const sitemaps = [...text.matchAll(/^\s*sitemap:\s*(\S+)/gim)].map((m) => m[1]);
  const contentSignal = /content-signal/i.test(text);
  return { groups, sitemaps, contentSignal };
}

// RFC 9309 group precedence: a bot's own named groups win (all of them,
// merged — a UA may appear in several groups); "*" applies only to bots
// that have no named group. "Blocked" = site root disallowed.
const ROOT_BLOCK = /^\/(\*|\$)?$/;
function botVerdict(robots, bot) {
  const ua = bot.toLowerCase();
  const named = robots.groups.filter((g) => g.agents.includes(ua));
  const groups = named.length ? named : robots.groups.filter((g) => g.agents.includes("*"));
  if (!groups.length) return "allowed";
  const rules = groups.flatMap((g) => g.rules);
  const rootBlocked = rules.some((r) => r.type === "disallow" && ROOT_BLOCK.test(r.path));
  const rootAllowed = rules.some((r) => r.type === "allow" && ROOT_BLOCK.test(r.path));
  if (rootBlocked && !rootAllowed) return named.length ? "blocked" : "blocked-via-wildcard";
  return "allowed";
}

function pick(re, html, flags = "i") {
  const m = html.match(new RegExp(re, flags));
  return m ? m[1].trim() : null;
}

function analyzeHtml(html, finalUrl) {
  const head = html.slice(0, 200000);
  const metaContent = (name) =>
    pick(`<meta[^>]+(?:name|property)=["']${name}["'][^>]+content=["']([^"']*)["']`, head) ??
    pick(`<meta[^>]+content=["']([^"']*)["'][^>]+(?:name|property)=["']${name}["']`, head);
  const headings = [...html.matchAll(/<h([1-6])[^>]*>([\s\S]*?)<\/h\1>/gi)].map((m) => ({
    level: Number(m[1]),
    text: m[2].replace(/<[^>]+>/g, "").replace(/\s+/g, " ").trim().slice(0, 120),
  }));
  const imgs = [...html.matchAll(/<img\b[^>]*>/gi)].map((m) => m[0]);
  const imgsWithAlt = imgs.filter((t) => /\balt=["'][^"']+["']/i.test(t)).length;
  const jsonLdErrors = [];
  const jsonLd = [...html.matchAll(
    /<script[^>]+type=["']application\/ld\+json["'][^>]*>([\s\S]*?)<\/script>/gi,
  )].map((m) => {
    try {
      return JSON.parse(m[1]);
    } catch (e) {
      jsonLdErrors.push({ error: e.message, head: m[1].trim().slice(0, 160) });
      return null;
    }
  });
  const schemaTypes = [];
  const walk = (n) => {
    if (Array.isArray(n)) return n.forEach(walk);
    if (n && typeof n === "object") {
      if (n["@type"]) schemaTypes.push(String(n["@type"]));
      Object.values(n).forEach(walk);
    }
  };
  walk(jsonLd);
  const links = [...html.matchAll(/<a\b[^>]*href=["']([^"'#]+)["'][^>]*>([\s\S]*?)<\/a>/gi)];
  const origin = new URL(finalUrl).origin;
  const internal = links.filter((m) => {
    try {
      return new URL(m[1], finalUrl).origin === origin;
    } catch {
      return false;
    }
  });
  const weakAnchors = internal.filter((m) =>
    /^(kliknij|click here|tutaj|więcej|more|read more|czytaj więcej|link)\s*$/i.test(
      m[2].replace(/<[^>]+>/g, "").trim(),
    ),
  ).length;
  const bodyText = html
    .replace(/<script[\s\S]*?<\/script>/gi, "")
    .replace(/<style[\s\S]*?<\/style>/gi, "")
    .replace(/<[^>]+>/g, " ")
    .replace(/\s+/g, " ")
    .trim();
  const noscriptMarkers = /<div id=["'](root|app|__next)["']>\s*<\/div>/i.test(html);
  return {
    lang: pick(`<html[^>]+lang=["']([^"']+)["']`, head),
    title: pick(`<title[^>]*>([^<]*)</title>`, head),
    metaDescription: metaContent("description"),
    metaRobots: metaContent("robots"),
    canonical: pick(`<link[^>]+rel=["']canonical["'][^>]+href=["']([^"']+)["']`, head) ??
      pick(`<link[^>]+href=["']([^"']+)["'][^>]+rel=["']canonical["']`, head),
    viewport: metaContent("viewport"),
    ogTitle: metaContent("og:title"),
    ogImage: metaContent("og:image"),
    hreflang: [...head.matchAll(/<link[^>]+hreflang=["']([^"']+)["'][^>]*>/gi)].map((m) => m[1]),
    headings,
    h1Count: headings.filter((h) => h.level === 1).length,
    images: { total: imgs.length, withAlt: imgsWithAlt },
    semanticTags: {
      header: /<header\b/i.test(html),
      nav: /<nav\b/i.test(html),
      main: /<main\b/i.test(html),
      footer: /<footer\b/i.test(html),
      article: /<article\b/i.test(html),
    },
    ariaLandmarks: (html.match(/\brole=["'](banner|navigation|main|contentinfo)["']/gi) ?? []).length,
    jsonLdBlocks: jsonLd.length,
    jsonLdValid: jsonLd.filter(Boolean).length,
    jsonLdErrors,
    schemaTypes: [...new Set(schemaTypes)],
    microdata: /\bitemtype=["']https?:\/\/schema\.org/i.test(html),
    webmcpDeclarative: /\btoolname=|\btooldescription=/i.test(html),
    webmcpImperative: /navigator\.modelContext/i.test(html),
    internalLinks: internal.length,
    weakAnchors,
    bodyTextChars: bodyText.length,
    bodyTextSample: bodyText.slice(0, 600),
    emptyAppShell: noscriptMarkers && bodyText.length < 500,
    mixedContent: /<(img|script|link|iframe)[^>]+(src|href)=["']http:\/\//i.test(html),
    faqMarkup: schemaTypes.includes("FAQPage") || /<details\b/i.test(html),
  };
}

// Google AI features need a page that is indexable AND snippet-eligible.
// Directives may sit in meta robots, meta googlebot, or X-Robots-Tag
// (optionally bot-prefixed: "googlebot: noindex").
function snippetEligibility(html, headers) {
  const head = html.slice(0, 200000);
  const metas = [...head.matchAll(
    /<meta[^>]+name=["'](robots|googlebot|bingbot)["'][^>]+content=["']([^"']*)["']/gi,
  )].map((m) => `${m[1]}: ${m[2]}`);
  const xRobots = headers["x-robots-tag"] ? [`x-robots-tag: ${headers["x-robots-tag"]}`] : [];
  const all = [...metas, ...xRobots].map((s) => s.toLowerCase());
  const has = (re) => all.filter((s) => re.test(s));
  return {
    sources: all,
    noindex: has(/\bnoindex\b|\bnone\b/),
    nosnippet: has(/\bnosnippet\b|max-snippet:\s*0\b/),
    dataNosnippetElements: (html.match(/\bdata-nosnippet\b/gi) ?? []).length,
  };
}

function textLen(html) {
  return (html ?? "")
    .replace(/<script[\s\S]*?<\/script>/gi, "")
    .replace(/<style[\s\S]*?<\/style>/gi, "")
    .replace(/<[^>]+>/g, " ")
    .replace(/\s+/g, " ")
    .trim().length;
}

function securityHeaders(h) {
  return {
    xRobotsTag: h["x-robots-tag"] ?? null,
    hsts: h["strict-transport-security"] ?? null,
    csp: h["content-security-policy"] ? "present" : null,
    xContentTypeOptions: h["x-content-type-options"] ?? null,
    xFrameOptions: h["x-frame-options"] ?? null,
    referrerPolicy: h["referrer-policy"] ?? null,
    linkHeader: h["link"] ?? null,
    cacheControl: h["cache-control"] ?? null,
    server: h["server"] ?? null,
    cfRay: h["cf-ray"] ? "cloudflare" : null,
  };
}

async function main() {
  const input = process.argv[2];
  if (!input) {
    console.error("usage: fetch-site.mjs <url> [out.json]");
    process.exit(2);
  }
  const url = /^https?:\/\//i.test(input) ? input : `https://${input}`;
  const origin = new URL(url).origin;

  const [page, robotsRes, llms, httpRedirect] = await Promise.all([
    get(url),
    get(`${origin}/robots.txt`),
    get(`${origin}/llms.txt`),
    get(url.replace(/^https:/, "http:"), {}).then((r) => ({
      status: r.status,
      finalUrl: r.finalUrl,
    })),
  ]);

  const robots = robotsRes.ok ? parseRobots(robotsRes.text) : null;
  const sitemapUrls = robots?.sitemaps?.length
    ? robots.sitemaps
    : [`${origin}/sitemap.xml`, `${origin}/sitemap_index.xml`];
  const sitemaps = [];
  const describeSitemap = (s, r) => ({
    url: s,
    status: r.status,
    isIndex: /<sitemapindex\b/i.test(r.text ?? ""),
    valid: r.ok && /<(urlset|sitemapindex)\b/i.test(r.text ?? ""),
    urlCount: (r.text?.match(/<loc>/gi) ?? []).length,
    hasLastmod: /<lastmod>/i.test(r.text ?? ""),
    hasXhtmlLink: /xhtml:link/i.test(r.text ?? ""),
    sampleUrls: [...(r.text ?? "").matchAll(/<loc>\s*([^<\s]+)\s*<\/loc>/gi)]
      .slice(0, 8)
      .map((m) => m[1]),
  });
  for (const s of sitemapUrls.slice(0, 3)) {
    const r = await get(s);
    const entry = describeSitemap(s, r);
    sitemaps.push(entry);
    // Follow a sitemap index one level down so urlCount reflects real pages.
    if (entry.isIndex) {
      for (const child of entry.sampleUrls.slice(0, 3)) {
        sitemaps.push(describeSitemap(child, await get(child)));
      }
    }
  }

  // Bot-UA probes show WAF-level blocking and cloaking that robots.txt hides.
  // The AuditAI UA probe tells whether the engine report can be trusted at
  // all — a 403/429/challenge page here means a D/F grade is a block, not a verdict.
  // Heuristic: real bots are also IP-verified, so a spoofed UA can be treated
  // differently from the genuine crawler — report as indication, not proof.
  const BOT_UAS = {
    "OAI-SearchBot": "OAI-SearchBot/1.0; +https://openai.com/searchbot",
    GPTBot: "Mozilla/5.0 AppleWebKit/537.36 (KHTML, like Gecko; compatible; GPTBot/1.2; +https://openai.com/gptbot)",
    PerplexityBot: "Mozilla/5.0 (compatible; PerplexityBot/1.0; +https://perplexity.ai/perplexitybot)",
    Googlebot: "Mozilla/5.0 (compatible; Googlebot/2.1; +http://www.google.com/bot.html)",
    AuditAI: "Mozilla/5.0 (compatible; AuditAI/1.0; +https://auditai.cc/bot)",
  };
  const uaResults = await Promise.all(
    Object.entries(BOT_UAS).map(async ([name, ua]) => [name, await get(url, { "user-agent": ua })]),
  );
  const looksChallenged = (r) =>
    r.status === 403 || r.status === 429 || r.status === 503 ||
    /cf-chl|challenge-platform|Just a moment|Attention Required/i.test(r.text ?? "");
  const browserTextChars = page.ok ? textLen(page.text) : 0;
  const uaDifferential = Object.fromEntries(
    uaResults.map(([name, r]) => {
      const chars = textLen(r.text);
      return [name, {
        status: r.status,
        blocked: looksChallenged(r),
        title: pick(`<title[^>]*>([^<]*)</title>`, r.text ?? ""),
        textChars: chars,
        textRatioVsBrowser: browserTextChars ? Number((chars / browserTextChars).toFixed(2)) : null,
        noindex: /<meta[^>]+name=["']robots["'][^>]+noindex/i.test(r.text ?? "") ||
          /noindex/i.test(r.headers?.["x-robots-tag"] ?? ""),
      }];
    }),
  );
  const botProbe = uaResults.find(([n]) => n === "OAI-SearchBot")[1];
  const engineProbe = uaResults.find(([n]) => n === "AuditAI")[1];

  // Soft-404: a random path must not answer 200.
  const soft404 = await get(`${origin}/seo-geo-probe-${Math.random().toString(36).slice(2, 10)}`);

  // Canonical target reachability (no redirect, no 404) — only when canonical differs from final URL.
  const canonicalHref = page.ok ? analyzeHtml(page.text, page.finalUrl).canonical : null;
  let canonicalTarget = null;
  if (canonicalHref) {
    try {
      const abs = new URL(canonicalHref, page.finalUrl).href;
      const r = await fetch(abs, { method: "HEAD", redirect: "manual", headers: { "user-agent": UA } })
        .then((res) => ({ status: res.status, location: res.headers.get("location") }))
        .catch((e) => ({ status: 0, error: e.message }));
      canonicalTarget = { href: abs, selfReferencing: abs === page.finalUrl, ...r };
    } catch {
      canonicalTarget = { href: canonicalHref, invalid: true };
    }
  }

  // llms.txt hygiene: robots must not disallow it; sampled links must resolve.
  const llmsLinks = llms.ok
    ? [...llms.text.matchAll(/\((https?:\/\/[^)\s]+)\)|^(https?:\/\/\S+)$/gim)]
        .map((m) => m[1] ?? m[2]).filter(Boolean).slice(0, 5)
    : [];
  const llmsLinkStatus = await Promise.all(
    llmsLinks.map(async (l) => {
      const r = await fetch(l, { method: "HEAD", redirect: "follow", headers: { "user-agent": UA } })
        .then((res) => res.status).catch(() => 0);
      return { url: l, status: r };
    }),
  );
  const llmsDisallowed = robots
    ? robots.groups.some((g) =>
        (g.agents.includes("*") || RETRIEVAL_BOTS.some((b) => g.agents.includes(b.toLowerCase()))) &&
        g.rules.some((r) => r.type === "disallow" && r.path && "/llms.txt".startsWith(r.path.replace(/\*$/, ""))))
    : false;

  // Markdown for agents (Cloudflare / Vercel style content negotiation).
  const mdNeg = await get(url, { accept: "text/markdown" });
  const mdPath = new URL(url).pathname === "/" ? "/index.md" : `${new URL(url).pathname.replace(/\/$/, "")}.md`;
  const mdMirror = await get(`${origin}${mdPath}`);
  const markdownForAgents = {
    negotiation: {
      status: mdNeg.status,
      contentType: mdNeg.headers?.["content-type"] ?? null,
      servesMarkdown: /text\/markdown/i.test(mdNeg.headers?.["content-type"] ?? ""),
      vary: mdNeg.headers?.["vary"] ?? null,
      varyAcceptMissing: /text\/markdown/i.test(mdNeg.headers?.["content-type"] ?? "") &&
        !/\baccept\b/i.test(mdNeg.headers?.["vary"] ?? ""),
    },
    alternateLink: page.ok && /<link[^>]+type=["']text\/markdown["']/i.test(page.text),
    mirror: { path: mdPath, status: mdMirror.status, isMarkdown: /text\/markdown|text\/plain/i.test(mdMirror.headers?.["content-type"] ?? "") },
  };

  const wellKnown = {};
  for (const p of ["/.well-known/ai-catalog.json", "/.well-known/agent-card.json", "/openapi.json", "/agents.json", "/pricing.md"]) {
    const r = await get(`${origin}${p}`);
    wellKnown[p] = r.status;
  }

  const result = {
    input: url,
    fetchedAt: new Date().toISOString(),
    page: page.ok
      ? {
          status: page.status,
          finalUrl: page.finalUrl,
          ttfbMs: page.ttfbMs,
          htmlBytes: page.text.length,
          contentType: page.headers["content-type"] ?? null,
          security: securityHeaders(page.headers),
          snippetEligibility: snippetEligibility(page.text, page.headers),
          ...analyzeHtml(page.text, page.finalUrl),
        }
      : { status: page.status, error: page.error ?? "non-2xx" },
    httpToHttps: httpRedirect,
    robots: robots
      ? {
          status: robotsRes.status,
          sitemapsDeclared: robots.sitemaps,
          contentSignal: robots.contentSignal,
          retrieval: Object.fromEntries(RETRIEVAL_BOTS.map((b) => [b, botVerdict(robots, b)])),
          training: Object.fromEntries(TRAINING_BOTS.map((b) => [b, botVerdict(robots, b)])),
          optOut: Object.fromEntries(OPT_OUT_TOKENS.map((b) => [b, botVerdict(robots, b)])),
          search: Object.fromEntries(SEARCH_BOTS.map((b) => [b, botVerdict(robots, b)])),
          raw: robotsRes.text.slice(0, 3000),
        }
      : { status: robotsRes.status, missing: true },
    sitemaps,
    llmsTxt: llms.ok
      ? {
          status: llms.status,
          chars: llms.text.length,
          head: llms.text.slice(0, 500),
          disallowedInRobots: llmsDisallowed,
          sampledLinks: llmsLinkStatus,
        }
      : { status: llms.status, missing: true, disallowedInRobots: llmsDisallowed },
    wafProbeAsRetrievalBot: { status: botProbe.status, blocked: looksChallenged(botProbe) },
    wafProbeAsAuditAiBot: {
      status: engineProbe.status,
      blocked: looksChallenged(engineProbe),
      textChars: textLen(engineProbe.text),
    },
    uaDifferential,
    soft404: { path: "/seo-geo-probe-<random>", status: soft404.status, isSoft404: soft404.status === 200 },
    canonicalTarget,
    markdownForAgents,
    wellKnown,
  };

  const json = JSON.stringify(result, null, 2);
  if (process.argv[3]) {
    writeFileSync(process.argv[3], json);
    console.log(`written ${process.argv[3]} (${json.length} bytes)`);
  } else {
    console.log(json);
  }
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
