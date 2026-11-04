#!/usr/bin/env bash
# Per-ticket model/effort/permission override helpers for the team runner and the dashboard.
# Sourced, never executed; the caller sets `set -euo pipefail`. Contract: .agents/reference/team-mode.md
# Bash 3.2 compatible (macOS /bin/bash): no mapfile, no associative arrays.
# Loaded from the main checkout (like roles.json), so a clone on an older base still works.
# Requires team-lib.sh (TEAM_ROLES).

# Base schema travels with main; overrides must belong to the clone's runnable roles, plus cli,
# whose fixed model/effort leave it only `permission`.
TEAM_CONFIG_ROLES='planner coder qa wrapup'
TEAM_ROLE_VALUE_RE='^[A-Za-z0-9._:-]+(\[[a-z0-9]+\])?$'

team_roles_config_check() {  # <file> (or - for stdin) [known roles] → first problem, rc 1
  local bad
  # `\z`: jq's `$` also matches before a trailing newline, Bash ERE's does not.
  bad="$(jq -sr --arg roles "${2:-$TEAM_ROLES cli}" \
    --arg re "$TEAM_ROLE_VALUE_RE" '
    ($roles | split(" ")) as $known
    | if length != 1 or (.[0] | type) != "object" then "not a single JSON object"
      else .[0] | [to_entries[] | .key as $r
       | if ($known | index($r)) == null then "unknown role \($r)"
         elif (.value | type) != "object" then "\($r) is not an object"
         else .value | to_entries[] | .value as $v | .key as $k
           | if (["model", "effort", "permission"] | index($k)) == null then
               "unknown field \($r).\(.key)"
             elif $r == "cli" and .key != "permission" then
               "cli takes only permission (fixed opus[1m]/medium)"
             elif (.value | type) != "string" then "bad \(.key) for \($r): not a string"
             elif .key == "permission" and (["auto", "manual"] | index($v)) == null then
               "bad permission \(.value | tojson) for \($r)"
             elif .key == "effort" and
               (["low", "medium", "high", "xhigh", "max"] | index($v)) == null then
               "bad effort \(.value | tojson) for \($r)"
             elif .key == "model" and (.value | test($re + "\\z")) == false then
               "bad model \(.value | tojson) for \($r)"
             else empty end
         end] | first // empty end' "$1" 2>/dev/null)" \
    || { echo "not a single JSON object"; return 1; }
  [ -z "$bad" ] || { echo "$bad"; return 1; }
}

team_roles_override_check() { team_roles_config_check "$1"; }

team_role_cfg() {  # team_role_cfg <roles.json> <override> <role> → merged JSON; files optional
  local base='{}' ov='{}'
  [ ! -f "$1" ] || base="$(jq -c --arg r "$3" '.[$r] // {}' "$1")" || return 1
  [ ! -f "$2" ] || ov="$(jq -c --arg r "$3" '.[$r] // {}' "$2")" || return 1
  jq -cn --argjson b "$base" --argjson o "$ov" '$b + $o'
}

team_roles_add_entry() {  # <override JSON> <role>=[<model>][/<effort>][/<permission>]
  local e="$2" role val model effort="" perm="" rest
  local usage="'$e' is not <role>=[<model>][/<effort>][/<permission>]"
  case "$e" in *=*) ;; *) echo "$usage"; return 1 ;; esac
  role="${e%%=*}"; val="${e#*=}"; model="${val%%/*}"
  case "$val" in */*/*/*) echo "$usage"; return 1 ;; esac
  case "$val" in */*) rest="${val#*/}"; effort="${rest%%/*}"
    case "$rest" in */*) perm="${rest#*/}" ;; esac ;;
  esac
  [ -n "$model$effort$perm" ] || { echo "'$e' sets none of model, effort, permission"; return 1; }
  jq -c --arg r "$role" --arg m "$model" --arg f "$effort" --arg p "$perm" \
    'if has($r) and (.[$r] | type) != "object" then .
    else .[$r] = ((.[$r] // {})
    + (if $m == "" then {} else {model: $m} end)
    + (if $f == "" then {} else {effort: $f} end)
    + (if $p == "" then {} else {permission: $p} end)) end' \
    <<<"$1"
}

team_roles_flags() {  # <roles.json> <override> <role> → --model/--effort flags
  local file known cfg msg k v
  for file in "$1" "$2"; do
    [ -f "$file" ] || continue
    known="$TEAM_ROLES cli"; [ "$file" != "$1" ] || known="$TEAM_CONFIG_ROLES"
    msg="$(team_roles_config_check "$file" "$known")" \
      || { echo "error: $msg in $file"; return 1; }
  done
  cfg="$(team_role_cfg "$1" "$2" "$3")" \
    || { echo "error: cannot read $1 or $2"; return 1; }
  for k in model effort; do
    v="$(jq -r --arg k "$k" '.[$k] // empty' <<<"$cfg")" || return 1
    [ -z "$v" ] || printf -- "--%s '%s' " "$k" "$v"
  done
}

# Resolved apart from the flags: launch() may still downgrade auto, then renders --permission-mode.
team_roles_permission() {  # <roles.json> <override> <role> → auto|manual or nothing; after _flags
  local cfg
  cfg="$(team_role_cfg "$1" "$2" "$3")" || { echo "error: cannot read $1 or $2"; return 1; }
  jq -r '.permission // empty' <<<"$cfg"
}

team_roles_cli_permission() {  # <override> → its cli.permission or nothing; rc 1 when invalid
  local msg
  [ -f "$1" ] || return 0
  msg="$(team_roles_override_check "$1")" || { echo "error: $msg in $1"; return 1; }
  jq -r '.cli.permission // empty' "$1"
}

team_roles_status() {  # <override>
  local msg
  if msg="$(team_roles_override_check "$1")"; then
    jq -c . "$1"
  else
    echo "invalid — $msg"
  fi
}

team_roles_write() {  # <team> <override> <role>=[<model>][/<effort>][/<permission>]… | --clear
  local team="$1" file="$2" ov='{}' e msg tmp; shift 2
  [ $# -ge 1 ] || {
    echo "usage: team-run.sh $team roles <role>=[<model>][/<effort>][/<permission>]… | --clear"
    return 2
  }
  if [ "$1" = --clear ]; then
    [ $# -eq 1 ] || { echo "usage: team-run.sh $team roles --clear"; return 2; }
    rm -f "$file" || { echo "error: cannot clear $file"; return 1; }
    echo "roles override cleared"; return 0
  fi
  if [ -f "$file" ]; then
    ov="$(jq -cse 'if length == 1 and (.[0] | type == "object") then .[0]
      else error("not a single JSON object") end' "$file" 2>/dev/null)" \
      || { echo "error: not a single JSON object in $file — use roles --clear"; return 1; }
  fi
  for e in "$@"; do
    ov="$(team_roles_add_entry "$ov" "$e")" \
      || { echo "error: $ov — fix the entry or use roles --clear"; return 1; }
  done
  # Check the merged candidate once: replacing a bad value can repair an old override.
  msg="$(team_roles_config_check - <<<"$ov")" \
    || { echo "error: $msg — fix the entry or use roles --clear"; return 1; }
  tmp="$(mktemp "$(dirname "$file")/roles.override.XXXXXX")" \
    || { echo "error: cannot create tempfile for $file"; return 1; }
  if ! jq . <<<"$ov" > "$tmp" || ! mv "$tmp" "$file"; then
    rm -f "$tmp"; echo "error: cannot write $file"; return 1
  fi
  echo "roles override: $ov"
}

# ---- launch configuration, used by team-run.sh launch() ----------------------------------------
# These read team-run.sh globals: ROLES, ROLES_OVERRIDE, CLONE, root, TEAM_CLI_* and its die().

role_flags() {
  local flags
  if [ "$1" = cli ]; then
    printf -- "--model '%s' --effort '%s' " "$TEAM_CLI_MODEL" "$TEAM_CLI_EFFORT"; return 0
  fi
  flags="$(team_roles_flags "$ROLES" "$ROLES_OVERRIDE" "$1")" || die 1 "$flags"
  printf '%s' "$flags"
}

role_permission() {  # after role_flags, which validated the config files
  local perm
  if [ "$1" = cli ]; then
    perm="$(team_roles_cli_permission "$ROLES_OVERRIDE")" || die 1 "$perm"
    printf '%s' "${perm:-$TEAM_CLI_PERMISSION}"; return 0
  fi
  perm="$(team_roles_permission "$ROLES" "$ROLES_OVERRIDE" "$1")" || die 1 "$perm"
  printf '%s' "$perm"
}

claude_version_ok() {  # ≥ 2.1.295, the first with hook `onFailure`
  local v a b c
  v="$(claude --version 2>/dev/null | sed -n '1s/^\([0-9][0-9.]*\).*/\1/p')" || true
  IFS=. read -r a b c <<<"$v"
  [[ "$a" =~ ^[0-9]+$ && "$b" =~ ^[0-9]+$ && "$c" =~ ^[0-9]+$ ]] || return 1
  [ $(( a * 1000000 + b * 1000 + c )) -ge 2001295 ]
}

# Auto mode lets the classifier approve egress; only the clone's guard-team-egress hook keeps the
# prompt, so a clone that cannot enforce it launches manual. Prints why, rc 1 when ready.
auto_blocker() {
  local h="$CLONE/.claude/hooks"
  if [ ! -f "$h/guard-team-egress.sh" ] || [ ! -f "$h/lib/guard_team_egress.py" ]; then
    echo "the clone has no guard-team-egress hook"; return 0
  fi
  if ! jq -e 'def reg($m): any(.hooks.PreToolUse[]? | select(.matcher == $m) | .hooks[]?;
      ((.command // "") | contains("guard-team-egress.sh")) and .onFailure == "block");
      reg("WebFetch") and reg("Bash")' "$CLONE/.claude/settings.json" >/dev/null 2>&1; then
    echo 'the clone settings.json lacks guard-team-egress with "onFailure": "block"'; return 0
  fi
  claude_version_ok || { echo "claude is older than 2.1.295 (no hook onFailure)"; return 0; }
  return 1
}

# Same parse as codex-bg.sh; an unresolvable profile refuses the launch before session.json.
codex_home() {
  local f="$CLONE/.claude/codex-profile" want real=""
  if [ ! -e "$f" ] && [ ! -L "$f" ]; then f="$root/.claude/codex-profile"; fi
  want="$(sed -n '/^[[:space:]]*$/d; /^#/d; p; q' "$f" 2>/dev/null || true)"
  case "$want" in "~/"*) want="$HOME/${want#\~/}" ;; esac
  [ -z "$want" ] || real="$(cd "$want" 2>/dev/null && pwd -P || true)"
  if [ -z "$real" ]; then
    echo "error: Codex profile ${want:-<none>} from .claude/codex-profile does not resolve" \
      "— no session launched"
    return 1
  fi
  printf '%s' "$real"
}
