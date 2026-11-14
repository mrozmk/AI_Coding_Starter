#!/usr/bin/env bash
# Fresh UUID fixtures exercise the native layout without a production root override.
set -euo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd -P)"
WRAPPER="$REPO_ROOT/.claude/lib/rm-in-scratchpad.sh"
TEMP_BASE="$(cd /tmp && pwd -P)"
REPO_SLUG="${REPO_ROOT//[^A-Za-z0-9]/-}"
CLAUDE_TEMP="$TEMP_BASE/claude-$(id -u)"
SESSION_PARENT="$CLAUDE_TEMP/$REPO_SLUG"
WORK="$(mktemp -d "$TEMP_BASE/rm-in-scratchpad-smoke.XXXXXX")"
FIXTURES=()
CHECKS=0
CREATED_SLUG=0
CREATED_TEMP=0

cleanup() {
  local fixture
  for fixture in ${FIXTURES[@]+"${FIXTURES[@]}"}; do rm -rf -- "$fixture"; done
  rm -rf -- "$WORK"
  [ "$CREATED_SLUG" = 0 ] || rmdir -- "$SESSION_PARENT"
  [ "$CREATED_TEMP" = 0 ] || rmdir -- "$CLAUDE_TEMP"
}
trap cleanup EXIT

fail() {
  printf 'rm-in-scratchpad-smoke: FAIL — %s\n' "$1" >&2
  [ ! -f "$WORK/out" ] || cat "$WORK/out" >&2
  exit 1
}

new_session() {
  local sid
  sid="$(uuidgen | tr '[:upper:]' '[:lower:]')"
  SESSION_DIR="$SESSION_PARENT/$sid"
  mkdir "$SESSION_DIR"
  FIXTURES+=("$SESSION_DIR")
  mkdir "$SESSION_DIR/scratchpad"
  SESSION_UUID="$sid"
}

run() {
  local code=0
  (cd "$REPO_ROOT" && "$@") > "$WORK/out" 2>&1 || code=$?
  RC="$code"
}

refused() {
  local label="$1" reason="$2"; shift 2
  run "$@"
  [ "$RC" != 0 ] || fail "$label accepted"
  if [ "$label" = "empty input" ]; then
    grep -q '^usage:' "$WORK/out" || fail "$label failed without usage"
  else
    grep -qF "refused ($reason)" "$WORK/out" || fail "$label: wrong refusal reason"
  fi
  [ -f "$ROOT/keep" ] && [ -f "$OTHER_ROOT/keep" ] && [ -f "$WORK/keep" ] \
    && [ -f "$ROOT-other/keep" ] \
    || fail "$label deleted a sentinel"
  CHECKS=$((CHECKS + 1))
}

# A machine that never ran Claude Code has no native temp tree: create it (and remove it after).
if [ ! -e "$CLAUDE_TEMP" ]; then
  mkdir -m 700 "$CLAUDE_TEMP"
  CREATED_TEMP=1
fi
[ -d "$CLAUDE_TEMP" ] && [ ! -L "$CLAUDE_TEMP" ] || fail "Claude temp tree unavailable"
if [ ! -d "$SESSION_PARENT" ]; then
  mkdir "$SESSION_PARENT"
  CREATED_SLUG=1
fi
[ ! -L "$SESSION_PARENT" ] || fail "symlink fixture parent"
new_session
SESSION_ID="$SESSION_UUID"; ROOT="$SESSION_DIR/scratchpad"
new_session
OTHER_ROOT="$SESSION_DIR/scratchpad"
mkdir "$ROOT-other"
touch "$ROOT-other/keep"
touch "$ROOT/keep" "$OTHER_ROOT/keep" "$WORK/keep"
BASE_ENV=(env CLAUDE_CODE_SESSION_ID="$SESSION_ID" CLAUDE_CODE_TMPDIR=)

refused "empty input" "" "${BASE_ENV[@]}" bash "$WRAPPER"
refused "missing context" "missing or invalid Claude session context" \
  env -u CLAUDE_CODE_SESSION_ID CLAUDE_CODE_TMPDIR= \
  bash "$WRAPPER" "$ROOT/keep"
refused "malformed context" "missing or invalid Claude session context" \
  env CLAUDE_CODE_SESSION_ID=invalid CLAUDE_CODE_TMPDIR= \
  bash "$WRAPPER" "$ROOT/keep"
refused "custom temp with default root present" "custom Claude temporary directory" \
  env CLAUDE_CODE_SESSION_ID="$SESSION_ID" \
  CLAUDE_CODE_TMPDIR="$WORK/custom" bash "$WRAPPER" "$ROOT/keep"
MISSING_ID="$(uuidgen | tr '[:upper:]' '[:lower:]')"
refused "missing scratchpad" "session scratchpad unavailable" \
  env CLAUDE_CODE_SESSION_ID="$MISSING_ID" CLAUDE_CODE_TMPDIR= \
  bash "$WRAPPER" "$SESSION_PARENT/$MISSING_ID/scratchpad/keep"
refused "relative path" "relative path" "${BASE_ENV[@]}" bash "$WRAPPER" "keep"
refused "parent traversal" "parent traversal" "${BASE_ENV[@]}" \
  bash "$WRAPPER" "$ROOT/../scratchpad/keep"
refused "scratchpad root" "scratchpad root" "${BASE_ENV[@]}" bash "$WRAPPER" "$ROOT/"
OUTSIDE="outside current session scratchpad"
refused "scratchpad parent" "$OUTSIDE" "${BASE_ENV[@]}" bash "$WRAPPER" "${ROOT%/*}"
refused "foreign session" "$OUTSIDE" "${BASE_ENV[@]}" bash "$WRAPPER" "$OTHER_ROOT/keep"
refused "similar prefix" "$OUTSIDE" "${BASE_ENV[@]}" bash "$WRAPPER" "$ROOT-other/keep"
refused "extra outside target" "$OUTSIDE" "${BASE_ENV[@]}" \
  bash "$WRAPPER" "$ROOT/keep" "$WORK/keep"
refused "outside target first" "$OUTSIDE" "${BASE_ENV[@]}" \
  bash "$WRAPPER" "$WORK/keep" "$ROOT/keep"
refused "absent outside target" "$OUTSIDE" "${BASE_ENV[@]}" bash "$WRAPPER" \
  "$ROOT/keep" "$WORK/absent"
ln -s "$WORK" "$ROOT/link"
refused "symlink with slash" "symlink component" "${BASE_ENV[@]}" \
  bash "$WRAPPER" "$ROOT/keep" "$ROOT/link/"
refused "symlink ancestor" "symlink component" "${BASE_ENV[@]}" bash "$WRAPPER" "$ROOT/link/keep"
refused "symlink operand" "symlink component" "${BASE_ENV[@]}" bash "$WRAPPER" "$ROOT/link"
ln -s "$ROOT/keep" "$ROOT/inside-link"
refused "internal symlink" "symlink component" "${BASE_ENV[@]}" bash "$WRAPPER" "$ROOT/inside-link"
refused "newline operand" "newline in path" "${BASE_ENV[@]}" bash "$WRAPPER" "$ROOT/keep"$'\n'
# shellcheck disable=SC2016
refused "different cwd" "working directory differs from wrapper repository" \
  "${BASE_ENV[@]}" bash -c 'cd "$1" && bash "$2" "$3"' \
  bash "$WORK" "$WRAPPER" "$ROOT/keep"

mv "$ROOT" "$ROOT-held"
ln -s "$WORK" "$ROOT"
refused "symlink scratchpad root" "symlink component" "${BASE_ENV[@]}" \
  bash "$WRAPPER" "$ROOT/keep"
[ -f "$ROOT-held/keep" ] || fail "symlink root deleted the original scratchpad"
unlink "$ROOT"
mv "$ROOT-held" "$ROOT"

mkdir "$ROOT/good dir"
touch "$ROOT/good dir/file" "$ROOT/-option" "$ROOT/file with spaces"
ln -s "$WORK" "$ROOT/good dir/nested-link"
run "${BASE_ENV[@]}" bash "$WRAPPER" "$ROOT/good dir/" "$ROOT/-option" \
  "$ROOT/file with spaces"
[ "$RC" = 0 ] || fail "valid deletion refused"
[ ! -e "$ROOT/good dir" ] && [ ! -e "$ROOT/-option" ] \
  && [ ! -e "$ROOT/file with spaces" ] || fail "selected targets survived"
[ -f "$ROOT/keep" ] && [ -f "$OTHER_ROOT/keep" ] && [ -f "$WORK/keep" ] \
  || fail "positive case escaped the selected targets"
CHECKS=$((CHECKS + 1))

touch "$ROOT/alias"
run "${BASE_ENV[@]}" bash "$WRAPPER" "/tmp/${ROOT#"$TEMP_BASE"/}/./alias"
[ "$RC" = 0 ] && [ ! -e "$ROOT/alias" ] || fail "system /tmp alias or dot normalization"
CHECKS=$((CHECKS + 1))

printf 'rm-in-scratchpad-smoke: OK (%s checks)\n' "$CHECKS"
