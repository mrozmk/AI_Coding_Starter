#!/usr/bin/env bash
# Install or update the Herdr panels kit (the mods and the layout named in kit.json).
# Usage: bash .claude/team/herdr-mod/panels/install.sh [--dry-run]
#   Copies each mods/<name>/ of the kit to <app home>/mods/<name>/ with an ownership marker,
#   .installed-by-harness, that lists the files it owns. An update replaces those files, removes a
#   file the old marker lists and the kit no longer ships, and keeps every other file in the folder
#   (Herdr's jsconfig.json and *.d.ts, the user's own). A hidden entry in a kit mod folder (a
#   Finder .DS_Store) is not a kit file: it is neither checked nor copied.
#   Copies each layouts/<l>.json to <app home>/layouts/<l>.json with a sidecar,
#   layouts/.<l>.installed-by-harness, holding the digest of what it installed. A layout changed
#   since install (e.g. a docked strip) is left as it is; an unchanged one takes the kit's version.
#   Every target is checked before any write: a mod folder or layout it did not install, a
#   symlink, a marker entry that is not a plain name, or a file of a kit name it does not own makes
#   it refuse with nothing written.
#   --dry-run: prints what it would do and writes nothing.
# <app home> = $HERDR_APP_HOME, else ~/.config/herdr-app. Nothing else there is written: no
# settings.json, keys.json, installed.json, other mod or other layout.
# Exit 0 done · 2 usage · 3 refused (no Herdr app home, no jq, a foreign or unsafe target, a bad
# kit) · 1 a copy failed.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
APP="${HERDR_APP_HOME:-$HOME/.config/herdr-app}"
MARK=".installed-by-harness"   # hidden: Herdr does not reload on it
NAME_RE='^[A-Za-z0-9][A-Za-z0-9._-]*$'
README=".claude/team/herdr-mod/panels/README.md"

usage() { sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }
dry=""
case "$#:${1:-}" in
  0:) ;;
  1:--dry-run) dry=1 ;;
  *) usage ;;
esac

refuse() { echo "error: $1" >&2; exit 3; }
real_dir() { [ -d "$1" ] && [ ! -L "$1" ]; }
real_file() { [ -f "$1" ] && [ ! -L "$1" ]; }
absent() { [ ! -e "$1" ] && [ ! -L "$1" ]; }
digest() { shasum -a 256 "$1" | cut -d' ' -f1; }

# put <dst> < <content> — atomic, through a temp file mktemp creates exclusively in the
# already-checked destination folder, never at a predictable path.
put() {
  local tmp=""
  tmp="$(mktemp "$(dirname "$1")/.kit-tmp.XXXXXX")" && cat > "$tmp" && mv -f "$tmp" "$1" \
    || { rm -f "${tmp:-}"; echo "error: cannot write $1" >&2; exit 1; }
}

# 1. Preflight.
command -v jq >/dev/null || refuse "jq is required"
real_dir "$APP" || refuse "no Herdr app home at $APP — is Herdr installed?"
for p in mods layouts; do
  absent "$APP/$p" || real_dir "$APP/$p" || refuse "$APP/$p is not a folder — left as it is"
done

# 2. Read the kit.
mods="$(jq -r '.mods[]' "$HERE/kit.json")" || refuse "cannot read $HERE/kit.json"
layouts="$(jq -r '.layouts[]' "$HERE/kit.json")" || refuse "cannot read $HERE/kit.json"
version="$(jq -r '.herdr_version' "$HERE/kit.json")"
MODS=(); LAYOUTS=()
while IFS= read -r m; do
  [ -n "$m" ] || continue
  [[ "$m" =~ $NAME_RE ]] || refuse "bad mod name '$m' in kit.json"
  real_dir "$HERE/mods/$m" || refuse "the kit has no folder mods/$m"
  while IFS= read -r f; do
    [[ "$f" =~ $NAME_RE ]] && real_file "$HERE/mods/$m/$f" || refuse "the kit's mods/$m/$f is not a plain file"
  done < <(ls "$HERE/mods/$m")
  MODS+=("$m")
done <<< "$mods"
while IFS= read -r l; do
  [ -n "$l" ] || continue
  [[ "$l" =~ $NAME_RE ]] || refuse "bad layout name '$l' in kit.json"
  real_file "$HERE/layouts/$l.json" || refuse "the kit has no layouts/$l.json"
  LAYOUTS+=("$l")
done <<< "$layouts"

# check_mod <name> → prints install | update, or the reason it is foreign (exit 1).
check_mod() {
  local d="$APP/mods/$1" f
  if absent "$d"; then echo install; return 0; fi
  real_dir "$d" || { echo "not a plain folder"; return 1; }
  real_file "$d/$MARK" || { echo "no $MARK marker"; return 1; }
  while IFS= read -r f || [ -n "$f" ]; do
    [ -n "$f" ] || continue
    [[ "$f" =~ $NAME_RE ]] || { echo "marker entry '$f' is not a plain name"; return 1; }
    absent "$d/$f" || real_file "$d/$f" || { echo "$f is not a plain file"; return 1; }
  done < "$d/$MARK"
  while IFS= read -r f; do
    absent "$d/$f" && continue
    real_file "$d/$f" || { echo "$f is not a plain file"; return 1; }
    grep -qxF -- "$f" "$d/$MARK" || { echo "$f is not the kit's: the marker does not list it"; return 1; }
  done < <(ls "$HERE/mods/$1")
  echo update
}

# check_layout <name> → prints install | same | replace | changed, or the reason (exit 1).
# Its sidecar is layouts/.<name>.installed-by-harness — for the kit's one layout, .harness.installed-by-harness.
check_layout() {
  local L="$APP/layouts/$1.json" SIDE="$APP/layouts/.$1$MARK"
  absent "$SIDE" || real_file "$SIDE" || { echo "its sidecar is not a plain file"; return 1; }
  if absent "$L"; then echo install; return 0; fi
  real_file "$L" || { echo "not a plain file"; return 1; }
  real_file "$SIDE" || { echo "no sidecar .$1$MARK"; return 1; }
  if [ "$(digest "$L")" != "$(head -1 "$SIDE")" ]; then echo changed
  elif cmp -s "$HERE/layouts/$1.json" "$L"; then echo same
  else echo replace; fi
}

# 3. Plan every target before any write: one "<name>:<action>" entry each (NAME_RE has no ':').
MOD_PLAN=(); LAY_PLAN=(); foreign=()
for m in ${MODS[@]+"${MODS[@]}"}; do
  if a="$(check_mod "$m")"; then MOD_PLAN+=("$m:$a")
  else foreign+=("$APP/mods/$m was not installed by this kit ($a)"); fi
done
for l in ${LAYOUTS[@]+"${LAYOUTS[@]}"}; do
  if a="$(check_layout "$l")"; then LAY_PLAN+=("$l:$a")
  else foreign+=("$APP/layouts/$l.json was not installed by this kit ($a)"); fi
done
if [ "${#foreign[@]}" -gt 0 ]; then
  for line in "${foreign[@]}"; do echo "error: $line — left as it is" >&2; done
  echo "nothing written — move a hand-copied folder aside and rerun (see $README)" >&2
  exit 3
fi

# 4. Dry run.
if [ -n "$dry" ]; then
  for e in ${MOD_PLAN[@]+"${MOD_PLAN[@]}"}; do echo "would ${e#*:} mods/${e%%:*}"; done
  for e in ${LAY_PLAN[@]+"${LAY_PLAN[@]}"}; do
    l="${e%%:*}"
    case "${e#*:}" in
      install) echo "would install layouts/$l.json" ;;
      replace) echo "would replace layouts/$l.json" ;;
      same) echo "layouts/$l.json unchanged" ;;
      changed) echo "layouts/$l.json changed since install — would be left as it is" ;;
    esac
  done
  exit 0
fi

# 5. Write.
mkdir -p "$APP/mods" || { echo "error: cannot create $APP/mods" >&2; exit 1; }
installed=0; updated=0
for e in ${MOD_PLAN[@]+"${MOD_PLAN[@]}"}; do
  m="${e%%:*}"; d="$APP/mods/$m"
  shipped="$(ls "$HERE/mods/$m")"
  old=""
  if [ "${e#*:}" = install ]; then
    mkdir "$d" || { echo "error: cannot create $d" >&2; exit 1; }
    installed=$((installed + 1))
  else
    old="$(grep -v '^$' "$d/$MARK" || true)"
    updated=$((updated + 1))
  fi
  # Own the union first, so a run cut short still owns what it copied and a rerun is not refused.
  put "$d/$MARK" <<< "$(printf '%s\n%s\n' "$old" "$shipped" | grep -v '^$' | LC_ALL=C sort -u)"
  while IFS= read -r f; do put "$d/$f" < "$HERE/mods/$m/$f"; done <<< "$shipped"
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    printf '%s\n' "$shipped" | grep -qxF -- "$f" || rm -f "$d/$f"
  done <<< "$old"
  put "$d/$MARK" <<< "$shipped"
done

lay_out=()
for e in ${LAY_PLAN[@]+"${LAY_PLAN[@]}"}; do
  l="${e%%:*}"; L="$APP/layouts/$l.json"
  case "${e#*:}" in
    install|replace)
      mkdir -p "$APP/layouts" || { echo "error: cannot create $APP/layouts" >&2; exit 1; }
      put "$L" < "$HERE/layouts/$l.json"
      put "$APP/layouts/.$l$MARK" <<< "$(digest "$L")"
      if [ "${e#*:}" = install ]; then lay_out+=("installed layouts/$l.json")
      else lay_out+=("replaced layouts/$l.json with the kit's newer version"); fi ;;
    same) lay_out+=("layouts/$l.json unchanged") ;;
    changed) lay_out+=("layouts/$l.json changed since install — left as it is; to take the kit's version move it aside and rerun") ;;
  esac
done

# 6. Report.
[ "$installed" = 0 ] || echo "installed $installed mods into $APP/mods"
[ "$updated" = 0 ] || echo "updated $updated mods into $APP/mods"
for line in ${lay_out[@]+"${lay_out[@]}"}; do echo "$line"; done
echo "checked against Herdr $version"
echo "switch to the layout \"harness\" in Herdr (layout.switch) · check a mod: herdr-app check <mod folder>"
