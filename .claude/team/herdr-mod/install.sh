#!/usr/bin/env bash
# Install, update or remove the harness-notify Herdr mod (the Herdr channel of notify.sh).
# Usage: bash .claude/team/herdr-mod/install.sh [--dry-run] [--dock <layout>]
#        bash .claude/team/herdr-mod/install.sh --undock <layout> | --rollback
#   install / update: copies harness-notify/ to <app home>/mods/harness-notify/ with an ownership
#     marker; a folder of that name without the marker is someone else's and is never touched.
#     mod.json says place "none", so Herdr docks the strip nowhere by itself and no layout changes.
#   --dock <layout>: also docks the strip into <app home>/layouts/<layout>.json, and only there:
#     the file is validated, backed up (<layout>.json.harness-bak-<UTC>), rewritten atomically and
#     validated again; a second run changes nothing. Herdr's own layouts (main, terminals, win98)
#     are refused: Herdr restores them on its next start — clone one first (layout.clone).
#   --undock <layout>: removes exactly what --dock added (dock.py says when it cannot).
#   --rollback: undocks every layout --dock recorded, then removes the folder (with the editor
#     files Herdr adds), only when it carries the marker and holds nothing else.
#   --dry-run: prints what it would do and writes nothing.
# <app home> = $HERDR_APP_HOME, else ~/.config/herdr-app. Nothing else there is read or written: no
# setting, no other layout, no other mod. Outside it, install / update creates only the mod's spool,
# ~/.agent-comms/outbox/herdr/{new,done} (mode 700, as notify.sh does); --rollback leaves it.
# Switch the channel on in ~/.agent-comms/notify.json (herdr.enabled).
# Exit 0 done · 2 usage · 3 refused (a foreign folder, no Herdr app home, a missing, unparsable or
# shipped layout, a strip that cannot be found unambiguously) · 1 a copy or write failed.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/harness-notify"
APP="${HERDR_APP_HOME:-$HOME/.config/herdr-app}"
DST="$APP/mods/harness-notify"
MARK=".installed-by-harness"   # hidden: Herdr does not reload on it
DOCKED=".docked-in"            # hidden: the layouts --dock wrote, one name per line
APPFILES='jsconfig\.json|tsconfig\.json|[A-Za-z0-9._-]+\.d\.ts'   # written by Herdr itself
FILES="main.js spool.js mod.json README.md"
SHIPPED=" main terminals win98 "   # Herdr replaces these whole on every start
SPOOL="$HOME/.agent-comms/outbox/herdr"   # the mod watches new/ from its first start
DOCK=(python3 -I "$HERE/dock.py")

usage() { sed -n '2,21p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }
mode=install dry="" layout=""
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) dry=1 ;;
    --dock|--undock) [ $# -ge 2 ] && [ -z "$layout" ] || usage
      [ "$mode" = install ] || usage
      [ "$1" = --dock ] || mode=undock; layout="$2"; shift ;;
    --rollback) [ "$mode" = install ] && [ -z "$layout" ] || usage; mode=rollback ;;
    *) usage ;;
  esac
  shift
done
[ "$mode" = install ] || [ -z "$dry" ] || usage
[ -d "$APP" ] || { echo "error: no Herdr app home at $APP — is Herdr installed?" >&2; exit 3; }
if [ -e "$DST" ] && [ ! -f "$DST/$MARK" ]; then
  echo "error: $DST exists and was not installed by the harness — left as it is" >&2; exit 3
fi

# layout_file <name> → its path; refuses a bad, shipped or missing name.
layout_file() {
  [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || { echo "error: bad layout name '$1'" >&2; exit 2; }
  case "$SHIPPED" in *" $1 "*)
    echo "error: $1 is one of Herdr's own layouts, restored on its next start — clone it first" \
      "(herdr-app do layout.clone '{\"name\":\"$1\",\"as\":\"my-$1\"}') and dock the clone" >&2; exit 3 ;;
  esac
  [ -f "$APP/layouts/$1.json" ] || { echo "error: no layout $APP/layouts/$1.json — left as it is" >&2; exit 3; }
  echo "$APP/layouts/$1.json"
}

# plan <dock|undock> <file> <out> → 0 a new layout in <out> · 4 nothing to do · exits 3 on a refusal.
plan() {
  local rc=0
  "${DOCK[@]}" "$1" "$2" > "$3" || rc=$?
  case "$rc" in 0|4) return "$rc" ;; 3) exit 3 ;; *) echo "error: dock.py failed ($rc)" >&2; exit 1 ;; esac
}

# commit <file> <new> — back up, validate the new layout, replace atomically.
commit() {
  local f="$1" new="$2" base bak tmp n
  python3 -I -c 'import json,sys; json.load(open(sys.argv[1]))' "$new" 2>/dev/null \
    || { echo "error: the new $f did not validate — left as it is" >&2; exit 1; }
  base="$f.harness-bak-$(date -u +%Y%m%dT%H%M%SZ)"; bak="$base"; n=1
  while [ -e "$bak" ]; do n=$((n + 1)); bak="$base-$n"; done   # never over an older backup
  cp -p "$f" "$bak" || { echo "error: cannot back up $f" >&2; exit 1; }
  tmp="$f.tmp.$$"
  cp "$new" "$tmp" && mv "$tmp" "$f" || { rm -f "$tmp"; echo "error: cannot replace $f" >&2; exit 1; }
  echo "  backup: $bak"
}

record() {  # record add|del <layout>
  local f="$DST/$DOCKED" rest
  rest="$(grep -vxF -- "$2" "$f" 2>/dev/null || true)"
  if [ "$1" = add ]; then rest="$(printf '%s\n%s' "$rest" "$2")"; fi
  rest="$(printf '%s\n' "$rest" | sed '/^$/d')"
  if [ -n "$rest" ]; then printf '%s\n' "$rest" > "$f"; else rm -f "$f"; fi
}

WORK="$(mktemp -d "${TMPDIR:-/tmp}/herdr-dock.XXXXXX")"
trap 'rm -f "$WORK"/*; rmdir "$WORK" 2>/dev/null || true' EXIT

case "$mode" in
  install)
    lf=""; dock_rc=0
    if [ -n "$layout" ]; then lf="$(layout_file "$layout")"; plan dock "$lf" "$WORK/new" || dock_rc=$?; fi
    if [ -n "$dry" ]; then
      if [ -e "$DST" ]; then echo "would update $DST"; else echo "would install $DST"; fi
      for f in $FILES; do echo "  $f"; done
      [ -d "$SPOOL/new" ] && [ -d "$SPOOL/done" ] || echo "would create $SPOOL/new and $SPOOL/done"
      [ -z "$lf" ] || { [ "$dock_rc" = 0 ] && echo "would dock the strip into $lf" || echo "already docked in $lf"; }
      exit 0
    fi
    verb=installed; [ ! -e "$DST" ] || verb=updated
    mkdir -p "$DST"
    for f in $FILES; do cp "$SRC/$f" "$DST/$f.tmp.$$" && mv "$DST/$f.tmp.$$" "$DST/$f" || { rm -f "$DST/$f.tmp.$$"; false; } \
      || { echo "error: cannot copy $f" >&2; exit 1; }; done
    date -u +%Y-%m-%dT%H:%M:%SZ > "$DST/$MARK"
    mkdir -p "$SPOOL/new" "$SPOOL/done" && chmod 700 "$HOME/.agent-comms" "$HOME/.agent-comms/outbox" \
      "$SPOOL" "$SPOOL/new" "$SPOOL/done" || { echo "error: cannot create the spool $SPOOL" >&2; exit 1; }
    echo "$verb $DST"
    if [ -n "$lf" ]; then
      if [ "$dock_rc" = 0 ]; then commit "$lf" "$WORK/new"; echo "docked the strip into $lf"; record add "$layout"
      elif grep -qxF -- "$layout" "$DST/$DOCKED" 2>/dev/null; then echo "already docked in $lf — unchanged"
      else  # a strip the owner or Herdr's old auto-dock put there: --rollback must not remove it
        echo "already has a strip in $lf — not added by this installer, left as it is" \
          "(remove it with --undock $layout)"; fi
    else
      echo "no layout changed — dock the strip with --dock <layout> (a layout of yours, not main)"
    fi
    echo "check: herdr-app check $DST   ·   switch on: herdr.enabled in ~/.agent-comms/notify.json" ;;
  undock)
    lf="$(layout_file "$layout")"
    if plan undock "$lf" "$WORK/new"; then commit "$lf" "$WORK/new"; echo "undocked the strip from $lf"
    else echo "nothing to undock in $lf"; fi
    [ ! -f "$DST/$MARK" ] || record del "$layout" ;;
  rollback)
    [ -e "$DST" ] || { echo "nothing to remove: $DST is absent"; exit 0; }
    # Herdr writes its own editor files into a mod folder on first load (jsconfig.json, *.d.ts);
    # those go too. Anything else is someone's: refuse before removing a thing.
    app="$(cd "$DST" && ls -A | grep -xE "$APPFILES" || true)"
    extra="$(cd "$DST" && ls -A | grep -vxE "$APPFILES" | grep -vxF -e "$MARK" -e "$DOCKED" $(for f in $FILES; do printf -- '-e %s ' "$f"; done) || true)"
    [ -z "$extra" ] || { echo "error: $DST holds files the harness did not install — left in place" >&2; exit 3; }
    # Plan every undock before writing any, so a refusal leaves all layouts and the mod as they are.
    names=(); i=0
    while IFS= read -r n; do
      [ -n "$n" ] || continue
      [ -f "$APP/layouts/$n.json" ] || { echo "  $n: layout gone — nothing to undock"; continue; }
      i=$((i + 1)); rc=0; plan undock "$APP/layouts/$n.json" "$WORK/new-$i" || rc=$?
      [ "$rc" = 0 ] && names+=("$i:$n")
    done < <(cat "$DST/$DOCKED" 2>/dev/null || true)
    for e in ${names[@]+"${names[@]}"}; do
      commit "$APP/layouts/${e#*:}.json" "$WORK/new-${e%%:*}"; echo "undocked the strip from ${e#*:}"
    done
    for f in $FILES $MARK $DOCKED $app; do rm -f "$DST/$f"; done
    rmdir "$DST"
    echo "removed $DST" ;;
esac
