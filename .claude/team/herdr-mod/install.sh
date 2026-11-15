#!/usr/bin/env bash
# Install, update or remove the harness-notify Herdr mod (the Herdr channel of notify.sh).
# Usage: bash .claude/team/herdr-mod/install.sh [--dry-run | --rollback]
#   install / update: copies harness-notify/ to <app home>/mods/harness-notify/ with an ownership
#     marker; a folder of that name without the marker is someone else's and is never touched.
#   --rollback: removes that folder, only when it carries the marker.
#   --dry-run: prints what it would do and writes nothing.
# <app home> = $HERDR_APP_HOME, else ~/.config/herdr-app. Nothing else there is read or written: no
# setting, no layout, no other mod. Outside it, install / update creates only the mod's spool,
# ~/.agent-comms/outbox/herdr/{new,done} (mode 700, as notify.sh does); --rollback leaves it.
# Switch the channel on in ~/.agent-comms/notify.json (herdr.enabled).
# Exit 0 done · 2 usage · 3 a foreign folder or no Herdr app home · 1 a copy failed.
set -euo pipefail

SRC="$(cd "$(dirname "$0")/harness-notify" && pwd)"
APP="${HERDR_APP_HOME:-$HOME/.config/herdr-app}"
DST="$APP/mods/harness-notify"
MARK=".installed-by-harness"   # hidden: Herdr does not reload on it
FILES="main.js spool.js mod.json README.md"
SPOOL="$HOME/.agent-comms/outbox/herdr"   # the mod watches new/ from its first start

mode=install
case "${1:-}" in
  "") ;; --dry-run) mode=dry ;; --rollback) mode=rollback ;;
  *) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2 ;;
esac
[ $# -le 1 ] || { sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }
[ -d "$APP" ] || { echo "error: no Herdr app home at $APP — is Herdr installed?" >&2; exit 3; }
if [ -e "$DST" ] && [ ! -f "$DST/$MARK" ]; then
  echo "error: $DST exists and was not installed by the harness — left as it is" >&2; exit 3
fi

case "$mode" in
  dry)
    if [ -e "$DST" ]; then echo "would update $DST"; else echo "would install $DST"; fi
    for f in $FILES; do echo "  $f"; done
    [ -d "$SPOOL/new" ] && [ -d "$SPOOL/done" ] || echo "would create $SPOOL/new and $SPOOL/done" ;;
  install)
    verb=installed; [ ! -e "$DST" ] || verb=updated
    mkdir -p "$DST"
    for f in $FILES; do cp "$SRC/$f" "$DST/$f.tmp.$$" && mv "$DST/$f.tmp.$$" "$DST/$f" || { rm -f "$DST/$f.tmp.$$"; false; } \
      || { echo "error: cannot copy $f" >&2; exit 1; }; done
    date -u +%Y-%m-%dT%H:%M:%SZ > "$DST/$MARK"
    mkdir -p "$SPOOL/new" "$SPOOL/done" && chmod 700 "$HOME/.agent-comms" "$HOME/.agent-comms/outbox" \
      "$SPOOL" "$SPOOL/new" "$SPOOL/done" || { echo "error: cannot create the spool $SPOOL" >&2; exit 1; }
    echo "$verb $DST"
    echo "check: herdr-app check $DST   ·   switch on: herdr.enabled in ~/.agent-comms/notify.json" ;;
  rollback)
    [ -e "$DST" ] || { echo "nothing to remove: $DST is absent"; exit 0; }
    # Anything beyond the installed files is someone's: refuse before removing a thing.
    extra="$(cd "$DST" && ls -A | grep -vxF -e "$MARK" $(for f in $FILES; do printf -- '-e %s ' "$f"; done) || true)"
    [ -z "$extra" ] || { echo "error: $DST holds files the harness did not install — left in place" >&2; exit 3; }
    for f in $FILES $MARK; do rm -f "$DST/$f"; done
    rmdir "$DST"
    echo "removed $DST" ;;
esac
