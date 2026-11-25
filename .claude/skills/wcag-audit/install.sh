#!/usr/bin/env bash
# install.sh — installs the pinned /wcag-audit engines into a private cache
# (~/.cache/wcag-audit/<key>/), never into the repo. The key must equal
# runner/lib/deps.mjs cacheKey(): sha256(lock bytes + "platform|arch|node major"), first 24 hex.
#
# Usage: bash .claude/skills/wcag-audit/install.sh [--with-chromium] [--print-key]
set -euo pipefail

SKILL="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WITH_CHROMIUM=0
PRINT_KEY=0
for arg in "$@"; do
  case "$arg" in
    --with-chromium) WITH_CHROMIUM=1 ;;
    --print-key) PRINT_KEY=1 ;;
    *) echo "install.sh: unknown argument: $arg" >&2; exit 2 ;;
  esac
done

if ! command -v node >/dev/null 2>&1; then
  echo "install.sh: node is required (>= 22.12)" >&2
  exit 3
fi

NODE_VERSION="$(node -p 'process.versions.node')"
NODE_MAJOR="${NODE_VERSION%%.*}"
NODE_REST="${NODE_VERSION#*.}"
NODE_MINOR="${NODE_REST%%.*}"
if [ "$NODE_MAJOR" -lt 22 ] || { [ "$NODE_MAJOR" -eq 22 ] && [ "$NODE_MINOR" -lt 12 ]; }; then
  echo "install.sh: node $NODE_VERSION is too old — /wcag-audit needs >= 22.12" >&2
  exit 3
fi

PLAT="$(node -p 'process.platform')"
ARCH="$(node -p 'process.arch')"
LOCK="$SKILL/package-lock.json"
if [ ! -f "$LOCK" ]; then
  echo "install.sh: $LOCK is missing" >&2
  exit 3
fi

KEY="$( { cat "$LOCK"; printf '%s|%s|%s' "$PLAT" "$ARCH" "$NODE_MAJOR"; } | shasum -a 256 | cut -c1-24 )"
if [ "$PRINT_KEY" -eq 1 ]; then
  echo "$KEY"
  exit 0
fi

LOCK_SHA="$(shasum -a 256 "$LOCK" | cut -d' ' -f1)"
# The passwd home, not $HOME: the suite runs under a scratch HOME and must still find this cache.
PASSWD_HOME="$(eval echo "~$(id -un)")"
CACHE_ROOT="${WCAG_AUDIT_CACHE:-$PASSWD_HOME/.cache/wcag-audit}"
DIR="$CACHE_ROOT/$KEY"

mkdir -p "$DIR"
chmod 700 "$CACHE_ROOT" "$DIR"
cp "$SKILL/package.json" "$SKILL/package-lock.json" "$DIR/"
npm --prefix "$DIR" ci --ignore-scripts --no-audit --no-fund

if [ "$WITH_CHROMIUM" -eq 1 ]; then
  if ! PLAYWRIGHT_BROWSERS_PATH="$DIR/browsers" node "$DIR/node_modules/playwright-core/cli.js" install chromium; then
    echo "install.sh: playwright-core could not install chromium (see the error above)" >&2
    exit 2
  fi
fi

CREATED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
printf '{"key":"%s","lock_sha256":"%s","node":"%s","platform":"%s","arch":"%s","created_at":"%s"}\n' \
  "$KEY" "$LOCK_SHA" "$NODE_VERSION" "$PLAT" "$ARCH" "$CREATED_AT" >"$DIR/ready.json.tmp"
mv "$DIR/ready.json.tmp" "$DIR/ready.json"
echo "installed: $DIR"
