---
description: Prime agent with QA context and verify the QA environment before any acceptance-criteria verification
argument-hint: '[deep]'
---

# Prime QA: Load QA Context + Environment Preflight

## Modes

- **`/prime-qa`** — default. Core project context + the QA layer + an environment preflight.
- **`/prime-qa deep`** — adds `decisions.md` and `patterns.md`, for a session that will reason about *why* the code looks the way it does, not only whether it meets its acceptance criteria.

**Mode detection:** deep if `$ARGUMENTS` contains `deep`, otherwise default.

This command is **self-contained** — it is the QA entry point. Do **not** tell the user to run `/prime` first; Phase 1 loads the same core files quick `/prime` does.

> For implementation priming use `/prime`; for product/BA priming use `/prime-ba`. Three entry points, three payloads — never chain them.

---

## Phase 1 — Core context (always)

Read `.agents/memory/index.md` — the routing table.

`CLAUDE.md` is injected by the harness every session — do **not** re-read it.

Status probe for the two regenerated files (no `Read` calls needed):

!`rg '^status:' .agents/memory/architecture.md .agents/memory/project-brief.md 2>/dev/null || echo "(no status frontmatter found)"`

- `status: populated` or `seeded` → **Read** the file.
- `status: empty`, or absent from the output above → **skip it** and emit a warning naming the command that regenerates it (`/maintain:refresh-brief` for the brief, `/setup:create-CLAUDE_MD` for the architecture map).

---

## Phase 2 — QA layer

Read, in this order:

1. `.agents/memory/errors.md` — the accumulated defect history QA reasons against. Skip if `status: empty`.
2. Every `.agents/memory/domain/*.md` whose frontmatter does **not** say `status: empty`. A file carrying **no** `status:` field at all **is** loaded — absence of the field is not `empty`.
3. `.agents/reference/qa-evidence-families.md` — the evidence-family taxonomy. **Expected present**: it is the contract `/qa-verify` classifies against, so read it. If it is absent, emit a warning naming both the file and `/qa-verify` as what needs it, then continue — a project synced from an older starter will not have it yet, and `/prime-qa` must still work there. Do not make this read unconditional; the absence path is load-bearing.

Roster + status of the domain files:

!`ls .agents/memory/domain/*.md 2>/dev/null || echo "(no domain/ files)"`
!`rg -H '^status:' .agents/memory/domain/*.md 2>/dev/null || echo "(no status frontmatter in domain/)"`

**Deep mode only** — additionally read `.agents/memory/decisions.md` and `.agents/memory/patterns.md`.

**Never read `.agents/specs/*` or `.agents/plans/*`** — in either mode. QA verifies acceptance criteria against the running system; a spec or a plan is the *author's intent*, and reading it biases the verdict toward what was meant rather than what shipped. If a concrete question later needs one, read it deliberately at that moment and say that you did.

**Never read `.agents/memory/reflection-protocol.md`** — QA observes and reports; it does not write memory.

---

## Phase 3 — Environment preflight

One injected probe, run at command load — before you reason about anything:

!`bash .claude/lib/qa-probe.sh`

The probe reads `.claude/qa-env.json` and emits `key: value` lines. **Transcribe them; do not re-derive them.** In particular `RESOLVED-BASE_URL` / `RESOLVED-REASON` are computed deterministically in the script precisely so the environment decision does not depend on model judgment. The probe does **not** decide which build is acceptable for a ticket: it reports the candidate deployed SHA, and `/qa-verify` makes that decision per ticket, explicitly, in Step 0.76 — from these lines plus the ticket's merge commit.

### Reading the probe output

| Line | What it means for the session |
|---|---|
| `qa-config: MISSING` | `.claude/qa-env.json` is not filled in. Every environment fact below is unavailable — say so plainly and offer to fill the file in. Do **not** guess a host. |
| `RESOLVED-BASE_URL: (none)` | Nothing to observe against. Runtime/visual verification is impossible this session; only static/code-level checks can run. |
| `deployed-sha: <sha> (differs)` | The deployed build differs from local `HEAD`. **A SHA difference alone never disqualifies the deployed host** — which host is the candidate, and why, is always `RESOLVED-BASE_URL` / `RESOLVED-REASON` (a failed probe path still moves it to local); `/qa-verify` decides per ticket whether the deployed build contains the ticket's merge. |
| `deployed-sha: not verified — …` | The deployed build **may** lag local `HEAD`. Every runtime or visual observation made **on the deployed host** carries that caveat (`/qa-verify` Step 0.76 row 5); an observation on the local host or of the checkout does not. Unverified is not a match. |
| `deployed-sha: not applicable` | No deployed host configured — local runs carry no skew warning. |
| `readiness <name>: FAILED \| UNREACHABLE` | An external system the feature needs is not ready. Warn; never stop — `/qa-verify` shows it at the gate. A readiness line is context, not proof: it is never `ENV` evidence on its own (`/qa-verify` Phase 2.5, kind 3 — an anonymous probe from the tester's machine measures that machine's access, not what the observed host used); it is quoted beside kind-3 evidence, never in place of it. |
| `readiness #<i>: MALFORMED` | Fix the entry in `qa-env.json → readiness_checks`. |
| `probe <path>: UNREACHABLE` | Most likely a **VPN / network gap**, not a host outage. Say so rather than declaring the environment broken. |
| `credentials-file …: MISSING` | Tracker-driven verification (reading acceptance criteria from Jira) will soft-fail. Local specs still work. |
| `browser-mcp-servers-running: N` | **Information, not a gate.** `0` = you are alone; higher = other testers are working in parallel. Never treat any value as a failure. |
| `parallel-safe flag …: NO` | A second concurrent browser session will collide with the first. Warn; do not block. |
| `artifacts-dir …: NOT gitignored` | Screenshots would become committable. Warn — QA evidence is point-in-time, not repo history. |
| `browser-driver: …` | Who observes browser rows in `/qa-verify`: `script` (default) · `mcp` · `subagent`; `UNKNOWN` is treated as `script`. |
| `playwright: …` | Whether the project's own Playwright (≥ 1.49) resolves — the `script` driver needs it; otherwise `/qa-verify` falls back to the browser MCP. Information, not a gate. |
| `browser-launch: …` | Launch settings (`qa-env.json → browser_launch`) every driver must honour. |

Two rules that govern this phase and are easy to erode:

- **Never print a credential.** The probe stats `.env` (size + mtime) and never reads it, deliberately. Probe output is appended to `.claude/audit.log` by the audit hook, so anything printed here is persisted. Never `cat` a credentials file to "check" it, and never use `rg` to test whether `.env` exists — ripgrep honours `.gitignore` and `.env` is gitignored, so it reports a **false absence**.
- **A preflight that always passes is worse than none**, because it reads as evidence. If a check cannot actually fail in this project, the probe reports it as *not applicable* rather than as a pass — read it that way.

---

## Output Report

**Facts only. No procedural narration** — no "I'll start by…", no "Reading files…", no recap. The `Read` calls visible in the UI ARE the proof that loading happened. Narrate only when there is an actual problem (→ `Warnings`).

### Loaded
One dot-separated line prefixed with the mode: `Loaded (qa): index.md · project-brief.md · …` or `Loaded (qa deep): …`. List only files actually read.

### Environment — facts
- **BASE_URL:** `<RESOLVED-BASE_URL>` — `<RESOLVED-REASON>`
- **Probes:** `<path>=<code>` · … (or `not configured`)
- **Deployed SHA:** `<sha (equal) | sha (differs) | not verified — reason | not applicable>`
- **Credentials file:** `<present, N bytes, modified … | MISSING>`
- **Browser MCP servers running:** `<N>`
- **Parallel-safe:** `<yes | no | not applicable>`
- **Browser driver:** `<browser-driver line value>` · **Playwright:** `<resolves (pkg version) | below 1.49 | not resolvable | not checked>`
- **Browser launch:** `<defaults | the set keys>`
- **Readiness:** `<name>=<ok|FAILED|UNREACHABLE|MALFORMED>` · … (or `none configured`)

### MCP roster
- `<Browser automation | tracker | design tool>`: `<available | absent>` each.

Take this from the session's own tool roster, **not** from a probe — the probe sees processes and config files, not which tools this session actually has.

### Mode
- `QA` | `QA deep`

### Warnings (omit the section entirely if there are none)
- ⚠️ `<one line per real problem, each naming the fix>`

**No closing summary, no "Ready to start."**

---

## Notes

- **Nothing here hard-stops.** A missing file, an empty memory file, an unreachable host — all warn and continue. The tester decides whether the gap blocks their run; the command's job is to make the gap visible before work starts, not to adjudicate it.
- **Why the probes are `!`-injected:** they execute at command load, before the model reasons about anything. Every defect this preflight exists to catch has the shape *"the model did not run the check at the right moment"*. An injected probe removes the discretion.
- **Why one script instead of inline `curl` lines:** a permission rule's `*` is a **trailing** wildcard only, so an inline-`curl` allow rule cannot be constrained to a host — it would permit `curl` anywhere, including `-d @.env` exfiltration, which then needs a deny list to contain the rule you just wrote. `/qa-verify` reads issue descriptions, i.e. untrusted input, so that surface matters. One exact allow rule for an argument-free in-repo script (`Bash(bash .claude/lib/qa-probe.sh)`) is narrower, and keeps the per-project hosts in `.claude/qa-env.json` where `/maintain:sync-from-starter` will not fight over them.
- **If this command starts raising permission prompts**, the allow rule in `.claude/settings.json` drifted from the injected line — they must match exactly, character for character. Fix the rule; never widen it to a wildcard, and never drop the probe.
- **Project setup:** fill in `.claude/qa-env.json` (hosts, probe paths, local serve command, artifacts dir). Every key is documented inline in that file. Leave a key empty rather than guessing — the probe reports "not configured", which is honest; a wrong host produces a confident wrong answer.
