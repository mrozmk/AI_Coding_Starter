#!/usr/bin/env bash
# Per-ticket model/effort override helpers for the team runner and the dashboard.
# Sourced, never executed; the caller sets `set -euo pipefail`. Contract: .agents/reference/team-mode.md
# Bash 3.2 compatible (macOS /bin/bash): no mapfile, no associative arrays.
# Loaded from the main checkout (like roles.json), so a clone on an older base still works.
# Requires team-lib.sh (TEAM_ROLES).

# Base schema travels with main; overrides must belong to the clone's runnable roles.
TEAM_CONFIG_ROLES='planner coder qa wrapup'
TEAM_ROLE_VALUE_RE='^[A-Za-z0-9._:-]+(\[[a-z0-9]+\])?$'

team_roles_config_check() {  # <file> (or - for stdin) → first problem on stdout, rc 1
  local bad
  # `\z`: jq's `$` also matches before a trailing newline, Bash ERE's does not.
  bad="$(jq -sr --arg roles "${2:-$TEAM_ROLES}" \
    --arg re "$TEAM_ROLE_VALUE_RE" '
    ($roles | split(" ")) as $known
    | if length != 1 or (.[0] | type) != "object" then "not a single JSON object"
      else .[0] | [to_entries[] | .key as $r
       | if ($known | index($r)) == null then "unknown role \($r)"
         elif (.value | type) != "object" then "\($r) is not an object"
         else .value | to_entries[] | .value as $v
           | if (.key == "model" or .key == "effort") | not then "unknown field \($r).\(.key)"
             elif (.value | type) != "string" then "bad \(.key) for \($r): not a string"
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

team_roles_add_entry() {  # team_roles_add_entry <override JSON> <role>=[<model>][/<effort>]
  local e="$2" role val model effort
  case "$e" in *=*) ;; *) echo "'$e' is not <role>=[<model>][/<effort>]"; return 1 ;; esac
  role="${e%%=*}"; val="${e#*=}"; model="${val%%/*}"; effort=""
  case "$val" in */*) effort="${val#*/}" ;; esac
  [ -n "$model$effort" ] || { echo "'$e' sets neither model nor effort"; return 1; }
  jq -c --arg r "$role" --arg m "$model" --arg f "$effort" 'if has($r) and (.[$r] | type) != "object" then .
    else .[$r] = ((.[$r] // {})
    + (if $m == "" then {} else {model: $m} end)
    + (if $f == "" then {} else {effort: $f} end)) end' \
    <<<"$1"
}

team_roles_flags() {  # <roles.json> <override> <role>
  local file known cfg msg k v
  for file in "$1" "$2"; do
    [ -f "$file" ] || continue
    known="$TEAM_ROLES"; [ "$file" != "$1" ] || known="$TEAM_CONFIG_ROLES"
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

team_roles_status() {  # <override>
  local msg
  if msg="$(team_roles_override_check "$1")"; then
    jq -c . "$1"
  else
    echo "invalid — $msg"
  fi
}

team_roles_write() {  # <team> <override> <role>=[<model>][/<effort>]… | --clear
  local team="$1" file="$2" ov='{}' e msg tmp; shift 2
  [ $# -ge 1 ] || {
    echo "usage: team-run.sh $team roles <role>=[<model>][/<effort>]… | --clear"; return 2
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
