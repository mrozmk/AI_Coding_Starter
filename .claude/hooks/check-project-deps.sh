#!/bin/bash
# SessionStart hook — PROJECT environment preflight.
#
# Sibling of check-deps.sh, deliberately a separate file: that one checks what the
# HOOKS need (jq, git) and is starter-owned; this one checks what THIS PROJECT needs
# and is project-owned — /maintain:sync-from-starter never overwrites it.
#
# Contract, same as its sibling:
#   - silent on a healthy machine (no output => no noise in the session)
#   - loud exactly once when something is missing
#   - ALWAYS exits 0 — a preflight must never block a session
#   - stdout is injected into the session context, so the agent can relay it
#   - cheap: no `flutter doctor`, no `npm ls`, nothing over ~100 ms
#
# NEVER prints a secret. The .env block checks key PRESENCE and shape only.
# This block is the ONLY sanctioned way to reason about .env content — probing
# it from the agent's Bash is denied, so a key not checked here is a key nobody
# can check.

cat >/dev/null 2>&1   # drain stdin; the SessionStart payload is not needed here

ROOT="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
cd "$ROOT" 2>/dev/null || exit 0

problems=""
add() { problems="${problems}  - $1"$'\n'; }
# Continuation line under the previous bullet (install recipes for one problem).
note() { problems="${problems}      $1"$'\n'; }

# ---------------------------------------------------------------- toolchain ---
# {Filled by /setup:start (stack-detected) or by hand.} Cheap `command -v` proxies only.
# Examples:
#   command -v node >/dev/null 2>&1 || add "node not on PATH — Validation gates will fail. Install: brew install node"
#   [ -d node_modules ] || add "node_modules missing — run 'npm install' before the gates."
#   command -v uv >/dev/null 2>&1 || add "uv not on PATH — the pinned Python toolchain cannot be resolved."
# Platform-toolchain pattern (mobile): warn only when NEITHER platform is usable —
# a developer working iOS-only must not be nagged about Android every session.

# ------------------------------------------------------------------- .env ----
# Keys come from the committed .env.example (the contract), never from a hardcoded
# list here. Convention: an ACTIVE line (`KEY=...`) is required; an OPTIONAL
# integration is shipped commented out (`# KEY=...`) and is not checked.
if [ -f .env.example ]; then
  active=$(grep -cE '^[A-Z][A-Z0-9_]*=' .env.example)
  if [ ! -f .env ]; then
    # No active key => no integration needs credentials; a no-Jira, no-PR project must not be nagged.
    [ "$active" -gt 0 ] && add ".env missing — MCP servers declared in .mcp.json start without credentials. Copy .env.example to .env and fill it in, then restart Claude Code."
  else
    while IFS= read -r k; do
      [ -z "$k" ] && continue
      grep -qE "^${k}=.+" .env || add ".env: $k is missing or empty (restart Claude Code after fixing — MCP servers read .env at startup)"
    done < <(grep -E '^[A-Z][A-Z0-9_]*=' .env.example | cut -d= -f1)
    # Confluence trap: a space URL instead of the instance URL 404s every call.
    if grep -qE '^CONFLUENCE_URL=.+' .env && ! grep -qE '^CONFLUENCE_URL=.*/wiki[[:space:]]*$' .env; then
      add ".env: CONFLUENCE_URL must END with /wiki (instance URL, not a space URL)"
    fi
    perms=$(stat -f "%Lp" .env 2>/dev/null || stat -c "%a" .env 2>/dev/null)
    [ -n "$perms" ] && [ "$perms" != "600" ] && add ".env is mode $perms — it holds live tokens. Fix: chmod 600 .env"
  fi
fi

# --------------------------------------------------------------- MCP servers -
# Bash cannot see the live MCP roster; check that each declared server's command
# resolves, which catches the common "server silently absent" case.
if [ -f .mcp.json ] && command -v jq >/dev/null 2>&1; then
  while IFS=$'\t' read -r name cmd; do
    [ -z "$cmd" ] && continue
    command -v "$cmd" >/dev/null 2>&1 || add "MCP server '$name' declares command '$cmd', which is not on PATH — that server will not start"
  done < <(jq -r '.mcpServers | to_entries[] | "\(.key)\t\(.value.command)"' .mcp.json 2>/dev/null)
fi

# ------------------------------------------------------------------ report ---
if [ -n "$problems" ]; then
  printf '\n⚠️  Project preflight found problems:\n\n%s\n' "$problems"
  printf 'Toolchain and .env problems break the quality gates or the MCP-backed skills.\n\n'
fi

exit 0
