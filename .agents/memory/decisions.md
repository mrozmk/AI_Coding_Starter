# Memory: Decisions

Architectural and technical decisions with rationale.

Add newest entries at the **TOP**.

---

## Format

```
## YYYY-MM-DD — Title

**Decision:** what was decided
**Why:** reasoning
**Alternatives considered:** what was rejected and why
**Impact:** where this shows up in the code
```

---

## 2026-06-13 — Memory-distillation guard: size-gated + active in subagents

**Decision:** added `guard-memory.sh` (PreToolUse: Edit/Write/MultiEdit, synchronous) implementing block-once-then-nudge — the first code edit in a memory domain per session is hard-blocked (exit 2) with an instruction to delegate a `general-purpose` subagent that distills `errors.md`+`patterns.md`+`decisions.md` into ~2k relevant to the task; a per-(session,domain) marker in `/tmp` releases subsequent edits. Two starter-specific adaptations: (1) **size gate** — dormant (exit 0) until those three files together exceed `size_threshold_bytes` (~24KB default); (2) **config-driven domains** in `.claude/memory-domains.json` (regex→domain, `$1` capture refs), default `rules: []` so the hook ships installed-but-silent.
**Why:** in a mature project the append-only memory monoliths grow to tens of thousands of tokens; a prose rule ("read patterns.md before coding") loads them whole into the main window (eviction → quality drift) and is unenforceable once it falls out of context. A hook + distillation subagent keeps the cost out of the main window and makes the check enforced. The size gate keeps the feature net-positive for the starter's typical audience (young, small projects) — it self-activates only when memory is actually large.
**Alternatives considered:** (a) always-active block regardless of size — rejected: pure friction + a wasted subagent spawn when memory is 1.5k tokens; (b) soft nudge only (exit 0 + stderr) — rejected: no enforcement, defeats the purpose; (c) skip in subagents via `CLAUDE_CODE_CHILD_SESSION` — rejected by the user in favor of **full guarantee** (active everywhere; each `/orchestrate` executor distills before its first edit). Note: that env var was observed `=1` even in the main session's Bash env, so it's an unreliable signal anyway. (d) sharding memory by domain instead of full reads — rejected per source handoff: cross-domain entries (env/middleware/deploy) cause lossy retrieval.
**Impact:** `.claude/hooks/guard-memory.sh`, `.claude/memory-domains.json`, `.claude/settings.json` (sync hook entries on Edit/Write + new MultiEdit matcher), `CLAUDE.md` → Automatic Behaviors, `.agents/memory/index.md` → When-to-Read row. Marker trust model mirrors `guard-commit.sh` (trusts the agent to act, not proof-of-execution). The sync-starter merge change from the source handoff (§4) was N/A — no such command exists in this repo.

## 2026-04-30 — Token-prefix deny patterns over broad curl-form bans

**Decision:** `.claude/settings.json` denies Bash commands containing literal token prefixes (`ATATT`, `ghp_`, `github_pat_`, `gho_`, `ghs_`, `ghu_`, `xoxb-`, `xoxp-`, `xapp-`, `xoxa-`, `AKIA`, `ASIA`, `sk-ant-`) rather than blocking entire command shapes like `Bash(curl * -u *)` or `Bash(curl * -H *Authorization:*)`.
**Why:** broad shape-bans block both the leaky form (`-u "user:hardcodedToken"`) AND the secure env-var form (`-u "$USER:$TOKEN"`, `-H "Authorization: Bearer $TOKEN"`) — they don't distinguish literal secret from `$VAR` reference. Prefix matching catches only the literal-token case, which is the exact failure mode (a "hardcoded token gets cached in `permissions.allow` after an Always-allow click" incident in another project).
**Alternatives considered:**
- Broad curl/wget shape bans — rejected: too many false positives, would push users to remove the rule.
- DB-URL credential patterns (`postgres://*:*@*` etc.) — rejected: Claude Code's permission validator forbids `:*` in the middle of a glob (legacy prefix-match conflict). DB URLs are also normally consumed via env vars.
- PreToolUse hook with regex secret scanner — rejected for v1: more moving parts, runs on every Bash call. Reconsider if compliance/audit requirements escalate.
**Impact:** [.claude/settings.json](../../.claude/settings.json) lines 75-87. Documented in [README.md](../../README.md) "Permissions & safety" and [CLAUDE.md](../../CLAUDE.md) Security. When adding support for a new SaaS provider whose tokens carry a stable documented prefix, append a new `Bash(*PREFIX*)` line — keep the zero-false-positive bar.

---



