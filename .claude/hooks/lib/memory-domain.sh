#!/usr/bin/env bash
# Path → memory domain from .claude/memory-domains.json. Side-effect free: sourced, never executed;
# reads no stdin, never exits. Used by guard-memory.sh (the distillation guard) and
# team-lead.sh digest-check (does a plan touch a routed domain?).
#
#   memory_domain_config <root>     → sets MEMORY_DOMAIN_FALLBACK (default general) and
#                                     MEMORY_DOMAIN_THRESHOLD (default 24000)
#   memory_domain_for <root> <rel>  → prints the domain of the first matching rule ($1..$9 capture
#                                     groups substituted), or nothing when no rule matches or there
#                                     is no config. The fallback is the caller's call.

memory_domain_config() {
  local cfg="$1/.claude/memory-domains.json" fb th
  MEMORY_DOMAIN_FALLBACK="general"; MEMORY_DOMAIN_THRESHOLD=24000
  [ -f "$cfg" ] || return 0
  fb=$(jq -r '.fallback // "general"' "$cfg" 2>/dev/null)
  [ -n "$fb" ] && [ "$fb" != "null" ] && MEMORY_DOMAIN_FALLBACK="$fb"
  th=$(jq -r '.size_threshold_bytes // 24000' "$cfg" 2>/dev/null)
  printf '%s' "$th" | grep -Eq '^[0-9]+$' && MEMORY_DOMAIN_THRESHOLD="$th"
  return 0
}

memory_domain_for() {
  local cfg="$1/.claude/memory-domains.json" rel="$2" n i=0 m d g cap
  [ -f "$cfg" ] || return 0
  n=$(jq '.rules | length' "$cfg" 2>/dev/null)
  printf '%s' "$n" | grep -Eq '^[0-9]+$' || n=0
  while [ "$i" -lt "$n" ]; do
    m=$(jq -r ".rules[$i].match // \"\"" "$cfg" 2>/dev/null)
    d=$(jq -r ".rules[$i].domain // \"\"" "$cfg" 2>/dev/null)
    if [ -n "$m" ] && [[ "$rel" =~ $m ]]; then
      for g in 1 2 3 4 5 6 7 8 9; do
        cap="${BASH_REMATCH[$g]:-}"
        d="${d//\$$g/$cap}"
      done
      printf '%s\n' "$d"
      return 0
    fi
    i=$((i + 1))
  done
  return 0
}
