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

PW_VERSION="1.64.0"

emit() { printf '%s\n' "$*"; }

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
  local file="$1" viewport="$2"; shift 2
  rm -f "$OUT/$file" # a stale shot from an earlier run must not pass the -s check below
  npx -y "playwright@${PW_VERSION}" screenshot "${BROWSER[@]}" --viewport-size "$viewport" \
    --wait-for-timeout 500 "$@" "$URL" "$OUT/$file" >>"$OUT/.render.log" 2>&1
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
