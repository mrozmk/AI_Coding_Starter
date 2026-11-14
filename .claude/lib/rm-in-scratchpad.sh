#!/usr/bin/env bash
# Only the observed native Claude session layout is supported; unknown context must refuse.
set -euo pipefail

refuse() { printf 'refused (%s)\n' "$1" >&2; exit 1; }

[ $# -gt 0 ] || { echo "usage: rm-in-scratchpad.sh <absolute-path>..." >&2; exit 2; }
[ -z "${CLAUDE_CODE_TMPDIR:-}" ] || refuse "custom Claude temporary directory"
SESSION_ID="${CLAUDE_CODE_SESSION_ID:-}"
[[ "$SESSION_ID" =~ ^[0-9a-f]{8}-([0-9a-f]{4}-){3}[0-9a-f]{12}$ ]] \
  || refuse "missing or invalid Claude session context"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd -P)"
[ "$(pwd -P)" = "$REPO_ROOT" ] || refuse "working directory differs from wrapper repository"
TEMP_BASE="$(cd /tmp && pwd -P)"
REPO_SLUG="${REPO_ROOT//[^A-Za-z0-9]/-}"
ROOT="$TEMP_BASE/claude-$(id -u)/$REPO_SLUG/$SESSION_ID/scratchpad"

canonical_path() {
  local rest="$1" part resolved=""
  case "$rest" in
    /tmp) rest="$TEMP_BASE" ;;
    /tmp/*) rest="$TEMP_BASE/${rest#/tmp/}" ;;
    /*) ;;
    *) refuse "relative path" ;;
  esac
  rest="${rest#/}"
  while [ -n "$rest" ]; do
    part="${rest%%/*}"
    if [ "$part" = "$rest" ]; then rest=""; else rest="${rest#*/}"; fi
    case "$part" in
      ""|.) continue ;;
      ..) refuse "parent traversal" ;;
    esac
    resolved="$resolved/$part"
    [ ! -L "$resolved" ] || refuse "symlink component"
  done
  printf '%s\n' "${resolved:-/}"
}

CHECKED_ROOT="$(canonical_path "$ROOT")"
[ "$CHECKED_ROOT" = "$ROOT" ] && [ -d "$ROOT" ] || refuse "session scratchpad unavailable"

TARGETS=()
for ARG in "$@"; do
  # Newlines would be lost by command substitution, changing the selected pathname.
  case "$ARG" in *$'\n'*) refuse "newline in path" ;; esac
  TARGET="$(canonical_path "$ARG")"
  [ "$TARGET" != "$ROOT" ] || refuse "scratchpad root"
  case "$TARGET" in
    "$ROOT"/*) ;;
    *) refuse "outside current session scratchpad" ;;
  esac
  TARGETS+=("$TARGET")
done

for TARGET in "${TARGETS[@]}"; do
  (
    cd -P -- "${TARGET%/*}" || refuse "target parent unavailable"
    case "$(pwd -P)" in
      "$ROOT"|"$ROOT"/*) ;;
      *) refuse "target parent outside current session scratchpad" ;;
    esac
    rm -rf -- "./${TARGET##*/}"
  )
  printf 'removed: %s\n' "$TARGET"
done
