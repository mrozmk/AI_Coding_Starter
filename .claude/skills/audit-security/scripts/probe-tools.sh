#!/usr/bin/env bash
# probe-tools.sh — capability probe for /audit-security. One machine-readable line per candidate
# scanner: `available <tool> <version>` or `missing <tool>`. Exits 0 by construction (Probe
# Convention: success never depends on what the probe finds).
set -u

version_of() {  # $1 tool, rest: version args → first line, whitespace collapsed to `_`
  local tool="$1"; shift
  local v
  v=$("$tool" "$@" 2>/dev/null | head -n 1 | tr -s ' \t' '_' | tr -d '\r')
  printf '%s' "${v:-unknown}"
}

probe() {  # $1 tool, rest: version args
  local tool="$1"; shift
  if command -v "$tool" >/dev/null 2>&1; then
    echo "available $tool $(version_of "$tool" "$@")"
  else
    echo "missing $tool"
  fi
}

probe gitleaks version
probe semgrep --version
probe osv-scanner --version
probe trivy --version
probe checkov --version

exit 0
