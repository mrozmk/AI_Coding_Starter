#!/usr/bin/env bash
# Offline test of the Herdr strip docking (.claude/team/herdr-mod/install.sh --dock/--undock/
# --rollback and dock.py): fixture app home and layout files only — no Herdr app, no hc, no real
# ~/.config/herdr-app. The strip enters a layout only through --dock, keeps the root's title bar
# and look keys on the root, and leaves exactly what was there before when undocked.
set -u
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
I="$ROOT/.claude/team/herdr-mod/install.sh"
[ -f "$I" ] || { echo "herdr-dock-test: FAIL — $I missing"; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "herdr-dock-test: FAIL — jq missing"; exit 1; }
T=$(mktemp -d "${TMPDIR:-/tmp}/herdr dock.XXXXXX") || { echo "herdr-dock-test: FAIL — mktemp"; exit 1; }
trap 'rm -rf "$T"' EXIT
die() { echo "herdr-dock-test: FAIL — fixture setup: $1"; exit 1; }
APP="$T/app"; LD="$APP/layouts"; MODD="$APP/mods/harness-notify"
mkdir -p "$LD" "$T/home" || die "dirs"
# A row root like a clone of Herdr's main (titlebar none, traffic lights, look on the root) and a
# column root like Terminals.
cat > "$T/row.json" <<'EOF' || die "row"
{"type": "row", "id": "root", "titlebar": "none", "traffic_lights": [12, 16], "theme": "graphite",
 "background": "canvas", "divider": {"width": 1, "color": "border"},
 "cloned_from": {"name": "main", "version": "0.1.15"},
 "children": [{"type": "column", "id": "sidebar", "size": {"px": 240}, "children": []},
              {"type": "column", "id": "work", "children": [{"type": "block", "id": "tab", "content": {"tab": "active"}}]}]}
EOF
cat > "$T/col.json" <<'EOF' || die "col"
{"type": "column", "id": "root", "titlebar": "none", "font_size": 15,
 "children": [{"type": "block", "id": "tabs", "size": {"px": 34}, "content": {"mod": "terminals-bar"}},
              {"type": "block", "id": "main", "content": {"tab": "active"}}]}
EOF
reset_layouts() {
  rm -f "$LD"/* && cp "$T/row.json" "$LD/mine.json" && cp "$T/col.json" "$LD/term.json" \
    && echo '{"type":"row","id":"root","children":[]}' > "$LD/main.json" \
    && printf '{"type": "row", ' > "$LD/broken.json" && echo '[1, 2]' > "$LD/list.json" || die "layouts"
}
reset_layouts
n=0; fail=0
ok() { n=$((n + 1)); if ! eval "$1"; then echo "FAIL [$2]"; printf '%s\n' "$OUT" | sed 's/^/    /'; fail=1; fi; }
inst() { OUT=$(HOME="$T/home" HERDR_APP_HOME="$APP" bash "$I" "$@" 2>&1); RC=$?; }
same() { [ "$(jq -S . "$1")" = "$(jq -S . "$2")" ]; }
snap() { (cd "$LD" && shasum ./* | sort); }
strips() { jq '[.. | objects | select(.id == "harness-notify-strip")] | length' "$1"; }

# ---- (1) install without --dock: no layout changes, mod.json docks nowhere ----------------------
before=$(snap); inst
ok '[ "$RC" = 0 ] && [[ "$OUT" == *"no layout changed"* ]] && [ "$(snap)" = "$before" ]' "install without --dock leaves every layout as it is"
ok '[ "$(jq -r .place "$MODD/mod.json")" = none ]' "the installed mod.json says place none (no auto-dock)"
ok '[ ! -e "$MODD/.docked-in" ]' "install without --dock records no layout"
inst --dry-run --dock mine
ok '[ "$RC" = 0 ] && [[ "$OUT" == *"would dock the strip into"* ]] && [ "$(snap)" = "$before" ]' "a dry run with --dock writes nothing"

# ---- (2) --dock a row root: wrapped, root keys stay on the root, one strip, backed up -----------
inst --dock mine
ok '[ "$RC" = 0 ] && [[ "$OUT" == *"docked the strip into"* ]]' "--dock mine"
ok 'jq -e ".id == \"harness-notify-dock\" and .type == \"column\" and .titlebar == \"none\" and .traffic_lights == [12,16] and .theme == \"graphite\" and .background == \"canvas\" and .cloned_from.name == \"main\"" "$LD/mine.json" >/dev/null' \
  "the root keeps titlebar, traffic lights, look and cloned_from (no title band)"
ok 'jq -e ".children[0].id == \"root\" and (.children[0] | has(\"titlebar\") or has(\"traffic_lights\") or has(\"theme\") | not) and .children[0].divider.width == 1" "$LD/mine.json" >/dev/null' \
  "the old root is the first child without the root-only keys, its own keys kept"
ok 'jq -e ".children[1] == {type: \"block\", id: \"harness-notify-strip\", size: {px: 26}, content: {mod: \"harness-notify\"}}" "$LD/mine.json" >/dev/null' \
  "one strip block, 26 px, the harness-notify mod"
bak=$(ls "$LD" | grep '^mine\.json\.harness-bak-' | head -n 1)
ok '[ -n "$bak" ] && cmp -s "$LD/$bak" "$T/row.json"' "the original was backed up before the write"
ok '[ "$(cat "$MODD/.docked-in")" = mine ]' "the layout is recorded for --rollback"
ok 'cmp -s "$LD/term.json" "$T/col.json" && [ -z "$(ls "$LD" | grep -v "^mine" | grep harness-bak)" ]' "no other layout touched"
cp "$LD/mine.json" "$T/docked.json"; nb=$(ls "$LD" | grep -c harness-bak)
inst --dock mine
ok '[ "$RC" = 0 ] && [[ "$OUT" == *"already docked"* ]] && cmp -s "$LD/mine.json" "$T/docked.json" && [ "$(ls "$LD" | grep -c harness-bak)" = "$nb" ]' \
  "a second --dock changes nothing and backs nothing up"
ok '[ "$(grep -c . "$MODD/.docked-in")" = 1 ]' "a second --dock records the layout once"

# ---- (3) --dock a column root: the strip is the last child, nothing wrapped ---------------------
inst --dock term
ok '[ "$RC" = 0 ] && jq -e ".id == \"root\" and .titlebar == \"none\" and (.children | length) == 3 and .children[2].id == \"harness-notify-strip\"" "$LD/term.json" >/dev/null' \
  "a column root gets the strip appended, no wrapper"

# ---- (4) --undock restores exactly the file before --dock -----------------------------------------
inst --undock term
ok '[ "$RC" = 0 ] && same "$LD/term.json" "$T/col.json"' "--undock of a column root restores the original"
inst --undock mine
ok '[ "$RC" = 0 ] && same "$LD/mine.json" "$T/row.json"' "--undock of a wrapped root restores the original (no wrapper left)"
ok '[ ! -e "$MODD/.docked-in" ]' "--undock clears the record"
cp "$LD/mine.json" "$T/m.json"; inst --undock mine
ok '[ "$RC" = 0 ] && [[ "$OUT" == *"nothing to undock"* ]] && cmp -s "$LD/mine.json" "$T/m.json"' "a second --undock changes nothing"

# ---- (5) refusals: missing, unparsable, not a layout, Herdr's own, a bad name -------------------
before=$(snap)
inst --dock gone; ok '[ "$RC" = 3 ] && [[ "$OUT" == *"no layout"* ]] && [ ! -e "$LD/gone.json" ]' "a missing layout is refused, not created"
inst --dock broken; ok '[ "$RC" = 3 ] && [[ "$OUT" == *"not valid JSON"* ]]' "an unparsable layout is refused"
inst --dock list; ok '[ "$RC" = 3 ] && [[ "$OUT" == *"not a Herdr layout"* ]]' "a JSON that is no layout is refused"
inst --dock main; ok '[ "$RC" = 3 ] && [[ "$OUT" == *"clone it first"* ]]' "Herdr's own main layout is refused"
inst --undock broken; ok '[ "$RC" = 3 ]' "--undock of an unparsable layout is refused"
inst --dock ../x; ok '[ "$RC" = 2 ]' "a layout name with a path is a usage error"
ok '[ "$(snap)" = "$before" ]' "no refused call wrote a layout"
inst --dock mine --undock mine; ok '[ "$RC" = 2 ]' "--dock with --undock is a usage error"

# ---- (6) the owner edited the layout in between --------------------------------------------------
inst --dock mine
jq '.children += [{"type": "block", "id": "owner-bar", "size": {"px": 20}, "content": {"mod": "x"}}]' "$LD/mine.json" > "$T/e" \
  && cp "$T/e" "$LD/mine.json" || die "edit 1"
inst --undock mine
ok '[ "$RC" = 0 ] && [ "$(strips "$LD/mine.json")" = 0 ] && jq -e ".id == \"harness-notify-dock\" and [.children[].id] == [\"root\", \"owner-bar\"]" "$LD/mine.json" >/dev/null' \
  "an owner's block beside it: only the strip goes, the wrapper stays with both children"
reset_layouts; rm -f "$MODD/.docked-in"
inst --dock mine
jq '(.children[0].children[0].children) += [.children[1]] | .children |= .[0:1]' "$LD/mine.json" > "$T/e" \
  && cp "$T/e" "$LD/mine.json" || die "edit 2"
inst --undock mine
ok '[ "$RC" = 0 ] && same "$LD/mine.json" "$T/row.json"' "the strip moved into the sidebar: removed there and the wrapper unwrapped"
inst --dock mine
jq '.children[0].children[1].children += [.children[1]]' "$LD/mine.json" > "$T/e" && cp "$T/e" "$LD/mine.json" || die "edit 3"
cp "$LD/mine.json" "$T/dup.json"
inst --undock mine
ok '[ "$RC" = 3 ] && [[ "$OUT" == *"appears 2 times"* ]] && cmp -s "$LD/mine.json" "$T/dup.json"' "two strips: refused, the file left as it is"
cp "$T/docked.json" "$LD/mine.json"
jq '.children[0].titlebar = "system"' "$LD/mine.json" > "$T/e" && cp "$T/e" "$LD/mine.json" || die "edit 4"
cp "$LD/mine.json" "$T/clash.json"
inst --undock mine
ok '[ "$RC" = 3 ] && [[ "$OUT" == *"both set titlebar"* ]] && cmp -s "$LD/mine.json" "$T/clash.json"' "a key set on both the wrapper and the inner root: refused"
jq '.children[0].children = [{"type": "column", "id": "only", "children": [{"type": "block", "id": "harness-notify-strip", "content": {"mod": "harness-notify"}}]}] | .children |= .[0:1]' \
  "$T/docked.json" > "$LD/mine.json" || die "edit 5"
inst --undock mine
ok '[ "$RC" = 0 ] && [[ "$OUT" == *"only has no children now"* ]] && jq -e ".id == \"root\" and .titlebar == \"none\" and .children == [{type: \"column\", id: \"only\", children: []}]" "$LD/mine.json" >/dev/null' \
  "the owner's own container left empty: kept with a note, our wrapper unwrapped"

# ---- (7) --rollback undocks first; a refused undock removes nothing --------------------------------
reset_layouts; rm -f "$MODD/.docked-in"
inst --dock mine; inst --dock term
cp "$LD/mine.json" "$T/m.json"; cp "$T/dup.json" "$LD/term.json"
inst --rollback
ok '[ "$RC" = 3 ] && [ -d "$MODD" ] && cmp -s "$LD/mine.json" "$T/m.json" && cmp -s "$LD/term.json" "$T/dup.json"' \
  "a refused undock stops --rollback before any layout or the mod is touched"
cp "$T/col.json" "$LD/term.json"; jq '.children += [{"type":"block","id":"harness-notify-strip","content":{"mod":"harness-notify"}}]' "$T/col.json" > "$LD/term.json" || die "term"
inst --rollback
ok '[ "$RC" = 0 ] && [ ! -e "$MODD" ] && same "$LD/mine.json" "$T/row.json" && same "$LD/term.json" "$T/col.json"' \
  "--rollback undocks every recorded layout, then removes the mod"
ok '[ "$(ls "$LD" | grep -c "harness-bak")" -ge 4 ] && [ -z "$(ls "$LD" | grep "\.tmp\.")" ]' "every write left a backup and no temp file"

# ---- (8) a strip --dock did not add (the owner's, or Herdr's old auto-dock) is never recorded -----
reset_layouts
jq '.children += [{"type":"block","id":"harness-notify-strip","content":{"mod":"harness-notify"}}]' "$T/col.json" > "$LD/term.json" || die "pre"
cp "$LD/term.json" "$T/pre.json"
inst --dock term
ok '[ "$RC" = 0 ] && [[ "$OUT" == *"not added by this installer"* ]] && ! grep -qx term "$MODD/.docked-in" 2>/dev/null && cmp -s "$LD/term.json" "$T/pre.json"' \
  "--dock on a strip it did not add: left as it is, not recorded"
inst --dock mine; inst --rollback
ok '[ "$RC" = 0 ] && [ ! -e "$MODD" ] && cmp -s "$LD/term.json" "$T/pre.json" && same "$LD/mine.json" "$T/row.json"' \
  "--rollback leaves that layout byte-identical and undocks only its own"

# ---- (9) --rollback removes the strip's list in Herdr's store (data/harness-notify/), only that ----
ST="$APP/data/harness-notify"; mkdir -p "$ST" "$APP/data/other-mod" || die "data"
echo '{"harness-notify.waiting":"[{\"id\":\"old\"}]"}' > "$ST/store.json"; echo keep > "$APP/data/other-mod/store.json"
inst; inst --rollback
ok '[ "$RC" = 0 ] && [ ! -e "$ST" ] && [[ "$OUT" == *"removed $ST"* ]] && [ "$(cat "$APP/data/other-mod/store.json")" = keep ]' \
  "--rollback removes data/harness-notify/ and no other mod's store"
mkdir -p "$ST" && echo x > "$ST/store.json" && echo mine > "$ST/notes.txt" || die "store"
inst --rollback
ok '[ "$RC" = 0 ] && [[ "$OUT" == *"left $ST"* ]] && [ ! -e "$ST/store.json" ] && [ "$(cat "$ST/notes.txt")" = mine ]' \
  "with the mod already gone: the list still goes, a foreign file stays and is named"
# The strip's "clear" drops every item and is a sibling of the item, so it never also opens one.
MJ="$ROOT/.claude/team/herdr-mod/harness-notify/main.js"
ok 'grep -q "on_click((_e, cx) => this.clear(cx))" "$MJ" && grep -A1 "^  clear(cx) {" "$MJ" | grep -q "this.list = \[\];" && grep -q "return strip.child(item).child(clear);" "$MJ"' \
  "the strip has a clear control that empties the list"

[ "$fail" -eq 0 ] || exit 1
echo "herdr-dock-test: OK ($n checks)"
