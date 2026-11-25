---
name: wcag-audit
description: Scan the given URLs for WCAG 2.2 (or 2.1) A/AA in a sandboxed headless Chrome on desktop and mobile — axe-core, own Playwright measurements and an optional read-confined model judge — and render a JSON + HTML report with an evidence model, coverage ledger, manual tasks and the EAA / EN 301 549 / Polish legal framing. A scan, never a conformance claim.
argument-hint: "<url> [more urls…] [--level A|AA] [--wcag 2.2|2.1] [--viewports desktop,mobile] [--no-llm] [--lang <code>] [--max-pages <n>]"
---

# /wcag-audit — WCAG 2.2 AA scan with real engines

Scan the URLs in `$ARGUMENTS` and hand over a report. This command **routes only**: everything that
touches a page or the report runs in the deterministic runner, and the only model step runs in
`@wcag-judge`, whose `Read` is confined to the pack the runner wrote.

Resources live under `.claude/skills/wcag-audit/` — reference them by **full path**:
`.claude/skills/wcag-audit/method.md` (method and limits), `.claude/skills/wcag-audit/judge.md`
(judge contract), `.claude/skills/wcag-audit/legal.json` + `sources.md` (legal framing and its
sources). Design: `.agents/specs/2026-11-25-wcag-audit-command.md`.

**Runner:** `node .claude/skills/wcag-audit/runner/audit.mjs <doctor|scan|pack|ingest|render>` — the
sole writer of `run.json`, the evidence crops, the packs and the report. stdout is one JSON object;
exit 0 ok · 2 usage · 3 refusal (`refusal` + `hint`) · 4 run error. Relay a refusal's `hint`
verbatim and stop.

---

## What this is NOT

- **A conformance audit.** It scans the given URLs and the states it opens — no sampling, no complete
  processes, no login. The report never says compliant, conformant, passed or certified.
- **`/seo-geo-audit`** — that one reports three SEO-side accessibility hints; this is the WCAG scan.
- **A fixer.** Findings become backlog Tasks through `/update-backlog`; nothing here edits the site or
  the repo.

---

## Phase 0 — Arguments, frame, doctor

1. Parse `$ARGUMENTS`: one or more `http(s)://` URLs, then the flags of the argument-hint. Anything
   else → STOP with the argument-hint. `--lang` defaults to the developer-communication language of
   this project (`CLAUDE.md` → Language), else `en`.
2. One `AskUserQuestion` with up to two questions:
   - **Client type:** public sector / EAA-covered service / microenterprise service (exempt from the
     EAA, the scan is still useful) / other. No answer = `unknown` (both framings are reported).
   - **Model egress** (skip with `--no-llm`): "Cropped screenshots, accessibility-tree excerpts and
     page text of the scanned pages go to the model provider for judgement. Go ahead?" — "no" means
     `--no-llm`.
3. `node .claude/skills/wcag-audit/runner/audit.mjs doctor --json` → `ok:false` → relay `hint` and
   stop. When the cache is absent or for another lock, offer
   `bash .claude/skills/wcag-audit/install.sh` (it runs `npm ci --ignore-scripts` into
   `~/.cache/wcag-audit/<key>/` and prompts) — never run `npm` or `npx` yourself.

## Phases 1–3 — Scan (runner)

Write the URLs one per line to `$SCRATCH/wcag-urls.txt` with the Write tool (`$SCRATCH` = the session
scratchpad). URLs never appear on a command line: the project's `audit-append.sh` hook logs every Bash
command string.

```bash
node .claude/skills/wcag-audit/runner/audit.mjs scan --urls-file "$SCRATCH/wcag-urls.txt" --client <type> [--level A|AA] [--wcag 2.2|2.1] [--viewports desktop,mobile] [--max-pages <n>] [--no-llm]
```

Relay `status`, `verdict` and `counts` in one line. The runner retries a 403/429 main document once
with a desktop-like user agent by itself and records it in the scope; relay that note when present.
Keep `work` (the run directory, `.agents/handoffs/wcag-audit-<slug>-<YYYY-MM-DD>[-n]/`).

### --no-llm path

Phases 4 and 5 are skipped entirely: nothing leaves the machine and no subagent is started. The
criteria that need judgement go to the report's manual tasks. Continue at Phase 6.

## Phase 4 — Judge (only with the model on)

1. `node .claude/skills/wcag-audit/runner/audit.mjs pack --work <work> --phase probe` → `nonce`,
   `probe_denied`.
2. Spawn `@wcag-judge` with: mode `probe`, the nonce, the `probe_denied` path. Ignore its answer.
3. `node .claude/skills/wcag-audit/runner/audit.mjs pack --work <work> --phase judge`. A refusal
   `guard-not-proven` means the agent's Read hook did not run (an untrusted workspace, hooks skipped):
   say "read guard not active — model phases skipped" and continue at Phase 6. Never send a pack
   through an unconfined read.
4. Spawn a fresh `@wcag-judge` with: mode `judge`, the pack path printed by step 3.
5. Save its final message **verbatim** to `$SCRATCH/judge.json` with the Write tool, then
   `node .claude/skills/wcag-audit/runner/audit.mjs ingest --work <work> --phase judge --file "$SCRATCH/judge.json"`.

## Phase 5 — Disprove (only with the model on)

1. `node .claude/skills/wcag-audit/runner/audit.mjs pack --work <work> --phase disprove`.
2. Spawn a fresh `@wcag-judge` with: mode `disprove`, the pack path.
3. Save its final message verbatim to `$SCRATCH/disprove.json`, then
   `node .claude/skills/wcag-audit/runner/audit.mjs ingest --work <work> --phase disprove --file "$SCRATCH/disprove.json"`.

Only candidates the disprove pass upholds are published, always as ◐ suspected.

## Phases 6–7 — Render and hand over

```bash
node .claude/skills/wcag-audit/runner/audit.mjs render --work <work> --lang <code>
```

It writes `.agents/handoffs/wcag-audit-<slug>-<YYYY-MM-DD>[-n].html` and `.json` (git-ignored per
clone, never committed) and releases the model-phase lock. Open the HTML (`open` on macOS,
`xdg-open` elsewhere, skip when neither exists). Final terminal report, short:

- the verdict line exactly as the runner chose it;
- counts by criterion status (fails / suspected / not tested / no automated failure found / n/a);
- ledger highlights (blocked requests, skipped frames, states not opened, limits hit);
- the HTML path.

## Never

- Type findings, statuses or HTML yourself, or edit any file under the run directory.
- Read page content into this session (the runner and the judge handle it).
- Pass `--no-sandbox` or work around a runner refusal.
- Run `npm` or `npx`, other than offering `bash .claude/skills/wcag-audit/install.sh`.
