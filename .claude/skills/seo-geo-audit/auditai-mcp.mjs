#!/usr/bin/env node
// Run a full Audit AI audit through the public MCP server and save the
// report JSON. Used by /seo-geo-audit as the scored "second opinion".
// Usage: node .claude/skills/seo-geo-audit/auditai-mcp.mjs <url> <out.json> [pl|en]
// Env: AUDITAI_BASE (default https://auditai.cc) — point at a local dev
// server (http://localhost:3000) when testing against the engine locally.
// Exit 0 = report saved; 3 = audit failed/timed out (caller treats as
// "no engine report", NOT as a site finding).

import { writeFileSync } from "node:fs";

const BASE = process.env.AUDITAI_BASE ?? "https://auditai.cc";
const POLL_MS = 10000;
const MAX_WAIT_MS = 8 * 60 * 1000;
let rpcId = 1;

async function rpc(method, params, sessionId) {
  const res = await fetch(`${BASE}/api/mcp`, {
    method: "POST",
    headers: {
      "content-type": "application/json",
      accept: "application/json, text/event-stream",
      ...(sessionId ? { "mcp-session-id": sessionId } : {}),
    },
    body: JSON.stringify({ jsonrpc: "2.0", id: rpcId++, method, params }),
  });
  const session = res.headers.get("mcp-session-id") ?? sessionId;
  const text = await res.text();
  // Streamable HTTP may answer as SSE; take the last data: line.
  const dataLine = text
    .split("\n")
    .filter((l) => l.startsWith("data:"))
    .pop();
  const payload = JSON.parse(dataLine ? dataLine.slice(5) : text);
  if (payload.error) throw new Error(`${method}: ${JSON.stringify(payload.error)}`);
  return { result: payload.result, session };
}

function toolJson(result) {
  const text = result?.content?.find((c) => c.type === "text")?.text;
  return text ? JSON.parse(text) : result;
}

async function main() {
  const [url, out, locale = "pl"] = process.argv.slice(2);
  if (!url || !out) {
    console.error("usage: auditai-mcp.mjs <url> <out.json> [pl|en]");
    process.exit(2);
  }

  const init = await rpc("initialize", {
    protocolVersion: "2025-03-26",
    capabilities: {},
    clientInfo: { name: "seo-geo-audit", version: "1.0.0" },
  });
  const session = init.session;

  const started = toolJson(
    (await rpc("tools/call", { name: "audit_url", arguments: { url, locale } }, session)).result,
  );
  if (started.error) {
    console.error(`audit_url refused: ${started.error}`);
    process.exit(3);
  }
  console.log(`auditId=${started.auditId} publicId=${started.publicId} cached=${started.cached}`);

  const deadline = Date.now() + MAX_WAIT_MS;
  let status = started.cached ? "COMPLETED" : "PENDING";
  while (status !== "COMPLETED" && status !== "FAILED" && Date.now() < deadline) {
    await new Promise((r) => setTimeout(r, POLL_MS));
    const view = toolJson(
      (await rpc("tools/call", { name: "get_audit_status", arguments: { auditId: started.auditId } }, session)).result,
    );
    status = view.status;
    console.log(`status=${status} progress=${view.progress ?? "?"} step=${view.currentStep ?? "?"}`);
  }
  if (status !== "COMPLETED") {
    console.error(`audit did not complete (status=${status})`);
    process.exit(3);
  }

  const report = await fetch(`${BASE}/api/audit/${started.publicId}/report`);
  if (!report.ok) {
    console.error(`report fetch failed: HTTP ${report.status}`);
    process.exit(3);
  }
  const json = await report.json();
  writeFileSync(out, JSON.stringify(json, null, 2));

  const cps = json.checkpoints ?? [];
  const failed = cps.filter((c) => c.result?.status === "fail").map((c) => c.id);
  const warned = cps.filter((c) => c.result?.status === "warn").map((c) => c.id);
  console.log(
    `grade=${json.overallGrade} score=${json.overallScore} siteType=${json.siteType} ` +
      `checkpoints=${cps.length} fail=${failed.length} warn=${warned.length}`,
  );
  console.log(`categories: ${JSON.stringify(json.categoryGrades ?? {})}`);
  console.log(`fail: ${failed.join(", ") || "-"}`);
  console.log(`warn: ${warned.join(", ") || "-"}`);
  console.log(`retrievalScore: ${json.retrievalScore ? JSON.stringify(json.retrievalScore).slice(0, 300) : "null"}`);
  console.log(`reportUrl=${BASE}/raport/${json.publicId}`);
  console.log(`written ${out}`);
}

main().catch((e) => {
  console.error(e.message);
  process.exit(3);
});
