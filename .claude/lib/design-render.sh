#!/usr/bin/env bash
#
# design-render.sh — render a /design-ui mockup to screenshots for the critics.
#
# WHY: a critic that only reads HTML cannot see what the user sees — icons that vanish on a
# light photo, a ragged left edge, a CTA below the fold, a page that shouts. /design-ui's
# critics (@design-critic, the Codex cross-review) judge these PNGs first and the source second.
#
# USAGE:  bash .claude/lib/design-render.sh <mockup.html> <out-dir>
#
# CONTRACT: emits `key: value` lines on stdout and exits 0 ALWAYS — a missing renderer is a
# reported state (`render: unavailable — <reason>`), never a crash; the caller carries it into
# its verdict as `not-verified`. It prints `render: ok` (all four shots) or
# `render: partial — missing <files>`, then one `shot: <path>` line per screenshot made:
#   desktop-fold.png  1440×900 viewport      desktop-full.png  1440 wide, full page
#   mobile-fold.png    390×844 viewport      mobile-full.png    390 wide, full page
#
# RENDERER: the Playwright CLI through npx, pinned (PW_VERSION) so a run is reproducible. It
# drives the system Google Chrome when one is installed (`--channel chrome`, no browser
# download); otherwise Playwright's own Chromium, which must already be installed for that
# version (`npx playwright@<PW_VERSION> install chromium`). The first run fetches the CLI
# package from npm — offline machines get `render: unavailable`.
#
# `--wait-for-timeout 500` is load-bearing: without it a Chrome full-page capture of a page
# taller than the viewport has come back with the top of the page stitched in twice.
#
# CLEANUP: an interrupted render must not leave Chrome running (#306). Playwright detaches its
# browser into its own process group, so a signal to this script never reaches it. On INT, TERM
# or HUP the script ends only the process tree of the shot it started — found by parent-PID
# descent, with an identity (start time) re-check before every signal — prints
# `render: unavailable — interrupted (<SIG>)` and exits 0. Nothing is matched by name, so the
# Operator's own browser is never touched. A SIGKILL of this script is out of reach.

PW_VERSION="1.64.0"

emit() { printf '%s\n' "$*"; }

# A process's identity is its start time only: the command string is mutable (npx hands over to
# npm, which rewrites process.title), so it must never be part of the comparison.
proc_ident() {
  local s
  s=$(ps -o lstart= -p "$1" 2>/dev/null) || return 1
  set -- $s
  printf '%s' "$*"
}
same_proc() { [ -n "$2" ] && [ "$(proc_ident "$1")" = "$2" ]; }
# The only place a signal is sent (the test overrides it to record).
send_sig() { kill -"$1" "$2" 2>/dev/null; }

# tree_collect <pid> <ident> — append `pid<TAB>ident` for an owned process and its descendants to
# $OWNED. A child counts only when its own ps line names <pid> as parent and <pid> is still the
# process we own; anything ambiguous is skipped.
tree_collect() {
  local pid="$1" ident="$2" c line cppid
  OWNED="${OWNED}${pid}	${ident}
"
  for c in $(pgrep -P "$pid" 2>/dev/null); do
    line=$(ps -o ppid=,lstart= -p "$c" 2>/dev/null) || continue
    set -- $line
    [ $# -ge 2 ] || continue
    cppid="$1"; shift
    [ "$cppid" = "$pid" ] && same_proc "$pid" "$ident" || continue
    tree_collect "$c" "$*"
  done
}

owned_signal() { # <sig> — signal every owned process that is still the one recorded
  printf '%s' "$OWNED" | while IFS='	' read -r p i; do
    [ -n "$p" ] && same_proc "$p" "$i" && send_sig "$1" "$p"
  done
  return 0
}
owned_alive() {
  printf '%s' "$OWNED" | { while IFS='	' read -r p i; do
    [ -n "$p" ] && same_proc "$p" "$i" && exit 0
  done; exit 1; }
}

SHOT_PID=
SHOT_IDENT=
cleanup() {
  if [ -n "${SHOT_PID:-}" ] && same_proc "$SHOT_PID" "$SHOT_IDENT"; then
    OWNED=
    tree_collect "$SHOT_PID" "$SHOT_IDENT"
    owned_signal TERM
    local n=0
    while [ "$n" -lt 15 ] && owned_alive; do
      sleep 0.2
      n=$((n + 1))
    done
    owned_signal KILL
  fi
  SHOT_PID=
  SHOT_IDENT=
}
on_signal() {
  cleanup
  emit "render: unavailable — interrupted ($1)"
  trap - EXIT
  exit 0
}

# Lets the test source the helpers above without rendering anything.
[ "${DESIGN_RENDER_SOURCE_ONLY:-}" = 1 ] && return 0 2>/dev/null

trap cleanup EXIT
trap 'on_signal INT' INT
trap 'on_signal TERM' TERM
trap 'on_signal HUP' HUP

HTML="${1:-}"
OUT="${2:-}"
if [ -z "$HTML" ] || [ -z "$OUT" ]; then
  emit "render: unavailable — usage: design-render.sh <mockup.html> <out-dir>"
  exit 0
fi
if [ ! -f "$HTML" ]; then
  emit "render: unavailable — mockup not found: $HTML"
  exit 0
fi
if ! command -v npx >/dev/null 2>&1; then
  emit "render: unavailable — npx not on PATH (Node.js is needed for the Playwright CLI)"
  exit 0
fi

mkdir -p "$OUT"
ABS="$(cd "$(dirname "$HTML")" && pwd)/$(basename "$HTML")"
# Node is already required (npx); its encoder handles #, ?, % and spaces in the path.
URL="$(node -e 'console.log(require("url").pathToFileURL(process.argv[1]).href)' "$ABS")"

# System Chrome first (no browser download); Playwright's bundled Chromium otherwise.
BROWSER=(--browser chromium)
if [ -x "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" ] \
  || command -v google-chrome >/dev/null 2>&1 || command -v google-chrome-stable >/dev/null 2>&1; then
  BROWSER=(--channel chrome)
fi

shoot() { # <file> <viewport> [--full-page]
  local file="$1" viewport="$2" rc; shift 2
  rm -f "$OUT/$file" # a stale shot from an earlier run must not pass the -s check below
  # In the background, so a trapped signal interrupts `wait` and the trap can clean up.
  npx -y "playwright@${PW_VERSION}" screenshot "${BROWSER[@]}" --viewport-size "$viewport" \
    --wait-for-timeout 500 "$@" "$URL" "$OUT/$file" >>"$OUT/.render.log" 2>&1 &
  SHOT_PID=$!
  SHOT_IDENT=$(proc_ident "$SHOT_PID")
  wait "$SHOT_PID"
  rc=$?
  # A wait cut short by a signal must leave the shot owned for the trap.
  if ! kill -0 "$SHOT_PID" 2>/dev/null; then
    SHOT_PID=
    SHOT_IDENT=
  fi
  return "$rc"
}

: >"$OUT/.render.log"

if ! shoot desktop-fold.png "1440,900"; then
  emit "render: unavailable — playwright@${PW_VERSION} could not render (${BROWSER[*]}); see $OUT/.render.log"
  [ "${BROWSER[*]}" = "--browser chromium" ] \
    && emit "hint: install a browser once with: npx playwright@${PW_VERSION} install chromium"
  exit 0
fi
shoot desktop-full.png "1440,900" --full-page
shoot mobile-fold.png "390,844"
shoot mobile-full.png "390,844" --full-page

MISSING=""
for f in desktop-fold desktop-full mobile-fold mobile-full; do
  [ -s "$OUT/$f.png" ] || MISSING="$MISSING $f.png"
done
if [ -z "$MISSING" ]; then
  emit "render: ok"
else
  emit "render: partial — missing$MISSING (see $OUT/.render.log)"
fi
for f in desktop-fold desktop-full mobile-fold mobile-full; do
  [ -s "$OUT/$f.png" ] && emit "shot: $OUT/$f.png"
done
exit 0
