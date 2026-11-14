---
description: Token usage summary (Claude + Codex) for a period — default last 30 days
argument-hint: "[--days N | --since YYYY-MM-DD [--until YYYY-MM-DD]]"
allowed-tools: Bash(python3 .claude/lib/costs/cost.py collect:*), Bash(python3 .claude/lib/costs/cost.py summary:*)
---

# /ai-costs — token usage summary

Monitoring view over `~/.agent-costs/costs.sqlite` (`$AGENT_COSTS_HOME`). Never `bind`, never post
to a tracker; the only write is `collect` refreshing that local DB. Definitions and the scope rule:
`.agents/reference/token-usage.md` → Summary (/ai-costs).

## Steps

1. **Refresh.** Run `python3 .claude/lib/costs/cost.py collect` from the repo root. A non-zero
   exit → print one line `⚠ collect failed (exit <n>) — summary uses the last collect` and go on.
2. **Summary.** Run `python3 .claude/lib/costs/cost.py summary <flags>`, where `<flags>` is only
   the documented flags taken from `$ARGUMENTS` — `--days N`, `--since YYYY-MM-DD`,
   `--until YYYY-MM-DD`. Drop anything else; never pass free text through to the shell. No
   arguments → no flags (the tool defaults to the last 30 days).
3. **Print.**
   - Exit `0` → print stdout verbatim. No re-summarizing, no commentary.
   - Exit `2` → show the tool's stderr message and the usage
     `/ai-costs [--days N | --since YYYY-MM-DD [--until YYYY-MM-DD]]`.
   - Exit `4` → "no DB — check `~/.agent-costs/config.json`", pointing at
     `.agents/reference/token-usage.md`.
