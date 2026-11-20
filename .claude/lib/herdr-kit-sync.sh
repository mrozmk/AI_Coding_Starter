#!/usr/bin/env bash
# Fetch the Herdr panels kit from the starter and install or update it — the helper of
# /maintain:sync-herdr-kit. Two non-interactive phases, so the command can confirm in between:
#   plan [--repo <url|path>] [--ref <branch|tag>]
#     No Herdr app home ($HERDR_APP_HOME, else ~/.config/herdr-app) → one line, exit 0, no clone.
#     Otherwise clones the starter (default .claude/.starter-sync.json → starter_repo, else
#     https://github.com/mrozmk/AI_Coding_Starter; ref main) into a new temp folder and prints
#     kit-source: <dir>, kit-ref: <ref>, kit-rev: <sha>, then the kit installer's --dry-run lines.
#     A refusal by the installer adds one "mv … .hand-copy" line per refused target; nothing is moved.
#   apply <dir> <rev>
#     Runs <dir>/.claude/team/herdr-mod/panels/install.sh when <dir> is an unmodified clone at <rev>.
# Never writes the Herdr app home itself: every write there is the kit installer's.
# Exit 0 done or nothing to do · 1 a copy failed · 2 usage · 3 refused (installer refusal, no kit
# at that ref, apply on another revision or a modified clone) · 4 clone failed (network, ref, repo).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
APP="${HERDR_APP_HOME:-$HOME/.config/herdr-app}"
KIT=".claude/team/herdr-mod/panels"
DEFAULT_REPO="https://github.com/mrozmk/AI_Coding_Starter"
usage() { sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }
refuse() { echo "error: $1" >&2; exit 3; }
has_kit() { [ -f "$1/$KIT/install.sh" ] && [ ! -L "$1/$KIT/install.sh" ]; }

# hint <installer output> — an mv line only for a confirmed hand copy (no marker, no sidecar).
hint() {
  local paths p first=1
  paths="$(printf '%s\n' "$1" | sed -n \
    -e 's/^error: \(.*\) was not installed by this kit (no \.installed-by-harness marker) — left as it is$/\1/p' \
    -e 's/^error: \(.*\) was not installed by this kit (no sidecar \.[^)]*) — left as it is$/\1/p')"
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    if [ -n "$first" ]; then echo "move it aside, then rerun /maintain:sync-herdr-kit (nothing was moved):"; first=""; fi
    printf 'mv %q %q\n' "$p" "$HOME/$(basename "$p").hand-copy"
  done <<< "$paths"
}

plan() {
  local repo="" ref="main" dir out rc=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --repo) [ "$#" -ge 2 ] || usage; repo="$2"; shift 2 ;;
      --ref) [ "$#" -ge 2 ] || usage; ref="$2"; shift 2 ;;
      *) usage ;;
    esac
  done
  if [ ! -d "$APP" ] || [ -L "$APP" ]; then
    echo "no Herdr app home at $APP — Herdr is not installed here; nothing to do"
    exit 0
  fi
  [ -n "$repo" ] || repo="$(jq -r '.starter_repo // empty' "$ROOT/.claude/.starter-sync.json" 2>/dev/null || true)"
  [ -n "$repo" ] || repo="$DEFAULT_REPO"
  dir="$(mktemp -d "${TMPDIR:-/tmp}/herdr-kit-sync.XXXXXX")" || { echo "error: cannot create a temp folder" >&2; exit 4; }
  echo "kit-source: $dir"
  git clone --quiet --depth 1 --branch "$ref" -- "$repo" "$dir" >&2 \
    || { echo "error: cannot clone $repo at $ref" >&2; exit 4; }
  has_kit "$dir" || refuse "the starter at $ref has no Herdr kit ($KIT/install.sh)"
  echo "kit-ref: $ref"
  echo "kit-rev: $(git -C "$dir" rev-parse HEAD)"
  out="$(bash "$dir/$KIT/install.sh" --dry-run 2>&1)" || rc=$?
  printf '%s\n' "$out"
  [ "$rc" -ne 3 ] || hint "$out"
  exit "$rc"
}

apply() {
  [ "$#" -eq 2 ] || usage
  local dir="$1" rev="$2"
  [ -d "$dir" ] && [ ! -L "$dir" ] || refuse "$dir is not a folder"
  [ "$(git -C "$dir" rev-parse HEAD 2>/dev/null || true)" = "$rev" ] \
    || refuse "$dir is not the clone at $rev the plan showed — run plan again"
  # --ignored too: the installer copies every non-hidden file of a mod folder, ignored ones included.
  [ -z "$(git -C "$dir" status --porcelain --ignored --untracked-files=all 2>/dev/null || echo x)" ] \
    || refuse "$dir has local changes — run plan again"
  has_kit "$dir" || refuse "$dir has no Herdr kit ($KIT/install.sh)"
  exec bash "$dir/$KIT/install.sh"
}

case "${1:-}" in
  plan) shift; plan "$@" ;;
  apply) shift; apply "$@" ;;
  *) usage ;;
esac
