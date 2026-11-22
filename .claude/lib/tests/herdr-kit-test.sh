#!/usr/bin/env bash
# Offline test of the Herdr panels kit (.claude/team/herdr-mod/panels/install.sh and the kit tree):
# fixture app home only — no Herdr app, no real ~/.config/herdr-app. The installer writes only the
# kit's mod folders, its layout and their markers; it refuses a foreign or unsafe target with the
# whole app home unchanged; an update keeps files it does not own and a layout changed since install.
set -u
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
KD="$ROOT/.claude/team/herdr-mod/panels"
I="$KD/install.sh"
[ -f "$I" ] || { echo "herdr-kit-test: FAIL — $I missing"; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "herdr-kit-test: FAIL — jq missing"; exit 1; }
command -v node >/dev/null 2>&1 || { echo "herdr-kit-test: FAIL — node missing"; exit 1; }
T=$(mktemp -d "${TMPDIR:-/tmp}/herdr kit.XXXXXX") || { echo "herdr-kit-test: FAIL — mktemp"; exit 1; }
trap 'rm -rf "$T"' EXIT
die() { echo "herdr-kit-test: FAIL — fixture setup: $1"; exit 1; }
APP="$T/app"; MARK=".installed-by-harness"
MODS=$(jq -r '.mods[]' "$KD/kit.json") || die "kit.json"
MRE=$(jq -r '.mods | join("|")' "$KD/kit.json") || die "kit.json"
mkdir -p "$T/home" || die "home"

n=0; fail=0; OUT=""
ok() { n=$((n + 1)); if ! eval "$1"; then echo "FAIL [$2]"; printf '%s\n' "$OUT" | sed 's/^/    /'; fail=1; fi; }
inst() { OUT=$(HOME="$T/home" HERDR_APP_HOME="$APP" bash "$I" "$@" 2>&1); RC=$?; }
kinst() { OUT=$(HOME="$T/home" HERDR_APP_HOME="$APP" bash "$T/kit/install.sh" "$@" 2>&1); RC=$?; }
kitcopy() { rm -rf "$T/kit" && cp -R "$KD" "$T/kit" || die "kitcopy"; }
snap_dir() { (cd "$1" && find . -type f -print | LC_ALL=C sort | while IFS= read -r f; do shasum "$f"; done); }
snap_app() { snap_dir "$APP"; }
others() { snap_app | grep -Ev " \./mods/($MRE)/| \./layouts/harness\.json$| \./layouts/\.harness$MARK$"; }
sha() { shasum -a 256 "$1" | cut -d' ' -f1; }
fresh_app() {
  rm -rf "$APP" && mkdir -p "$APP/mods/files" "$APP/mods/other" "$APP/layouts/.state" \
    && echo 'files' > "$APP/mods/files/main.js" && echo 'other' > "$APP/mods/other/main.js" \
    && echo '{"type":"row","id":"root","children":[]}' > "$APP/layouts/main.json" \
    && echo '{"type":"column","id":"root","children":[]}' > "$APP/layouts/mine.json" \
    && echo '{"clicks":1}' > "$APP/layouts/.state/main.json" \
    && echo '{"theme":"graphite"}' > "$APP/settings.json" \
    && echo '{"global":{}}' > "$APP/keys.json" \
    && echo '{"mods":[]}' > "$APP/installed.json" || die "fresh_app"
}

# ---- (1) the kit tree ----------------------------------------------------------------------------
ok '[ "$MODS" = "$(cd "$KD/mods" && LC_ALL=C ls)" ]' "kit.json mods equal the folders under mods/"
ok 'jq -r .herdr_version "$KD/kit.json" | grep -Eq "^[0-9]+\.[0-9]+\.[0-9]+$"' "kit.json names a Herdr version"
ok '[ "$(jq -c .layouts "$KD/kit.json")" = "[\"harness\"]" ] && jq -e . "$KD/layouts/harness.json" >/dev/null' "the layout harness is listed and parses"
ok '[ -z "$(find "$KD" -name "*.d.ts" -o -name jsconfig.json -o -name tsconfig.json)" ]' "no Herdr editor files in the kit"
syntax_ok() {
  local m
  for m in $MODS; do cp "$KD/mods/$m/main.js" "$T/x.mjs" && node --check "$T/x.mjs" 2>/dev/null || { OUT="$m"; return 1; }; done
}
ok syntax_ok "every main.js parses"
icons_ok() {
  local p m
  for p in $(grep -oh 'mods/[A-Za-z0-9._-]*/[A-Za-z0-9._-]*\.svg' "$KD"/mods/*/main.js | LC_ALL=C sort -u); do
    m="${p#mods/}"; m="${m%%/*}"
    printf '%s\n' "$MODS" | grep -qxF "$m" || continue
    [ -f "$KD/$p" ] || { OUT="missing $p"; return 1; }
  done
}
ok icons_ok "every icon a kit mod names is in the kit"
ok '[ ! -e "$KD/mods/tabs-plus/bot.svg" ] && [ ! -e "$KD/mods/tabs-plus/activity.svg" ]' "tabs-plus ships no unused icons"
ok '[ -f "$KD/LICENSE-Apache-2.0.txt" ] && [ -f "$KD/NOTICE.md" ]' "licence and notice files present"
headers_ok() {
  local m k=0
  for m in $MODS; do
    jq -e .cloned_from "$KD/mods/$m/mod.json" >/dev/null 2>&1 || continue
    k=$((k + 1))
    head -1 "$KD/mods/$m/main.js" | grep -q '^// Derived from Herdr' || { OUT="$m"; return 1; }
  done
  [ "$k" -gt 0 ] || { OUT="no mod.json names cloned_from"; return 1; }
}
ok headers_ok "every mod cloned from Herdr's (cloned_from) carries a derived-from header"
lic_ok() {
  local f
  for f in "$KD"/mods/*/ICONS-LICENSE.txt; do grep -q 'Permission to use, copy, modify' "$f" || { OUT="$f"; return 1; }; done
}
ok lic_ok "every ICONS-LICENSE.txt holds the full Lucide notice"
keys_ok() {
  local k
  for k in zoom cols rows left top grid; do grep -q "tabs-plus.layout-$k" "$KD/README.md" || { OUT="$k"; return 1; }; done
}
ok keys_ok "README carries the six tabs-plus bindings"

# ---- (2) usage and a missing app home ------------------------------------------------------------
OUT=$(HOME="$T/home" HERDR_APP_HOME="$T/none" bash "$I" 2>&1); RC=$?
ok '[ "$RC" = 3 ]' "no app home → 3"
fresh_app; inst --bogus
ok '[ "$RC" = 2 ]' "unknown argument → 2"

# ---- (3) dry run writes nothing ------------------------------------------------------------------
fresh_app; before=$(snap_app); inst --dry-run
ok '[ "$RC" = 0 ] && [[ "$OUT" == *"would install mods/limits"* ]] && [ "$(snap_app)" = "$before" ]' "--dry-run names the work and writes nothing"

# ---- (4) fresh install ---------------------------------------------------------------------------
fresh_app; base=$(others); inst
installed_ok() {
  local m
  for m in $MODS; do
    [ -f "$APP/mods/$m/main.js" ] || { OUT="$m: no main.js"; return 1; }
    [ "$(cat "$APP/mods/$m/$MARK")" = "$(cd "$KD/mods/$m" && ls)" ] || { OUT="$m: marker"; return 1; }
  done
}
ok '[ "$RC" = 0 ]' "install → 0"
ok installed_ok "twelve folders with main.js and a marker listing the kit's files"
ok 'cmp -s "$KD/layouts/harness.json" "$APP/layouts/harness.json" && [ "$(cat "$APP/layouts/.harness$MARK")" = "$(sha "$APP/layouts/harness.json")" ]' "layout installed with its digest sidecar"
ok '[ "$(others)" = "$base" ]' "install leaves every other file byte-identical"

# ---- (5) second install changes nothing ----------------------------------------------------------
lay=$(shasum "$APP/layouts/harness.json" "$APP/layouts/.harness$MARK"); inst
ok '[ "$RC" = 0 ] && [ "$(shasum "$APP/layouts/harness.json" "$APP/layouts/.harness$MARK")" = "$lay" ] && [ "$(others)" = "$base" ]' "a second install keeps layout, sidecar and other files"

# ---- (6) update replaces owned files, drops stale ones, keeps the rest ---------------------------
L="$APP/mods/limits"
echo '{}' > "$L/jsconfig.json"; echo 'd' > "$L/gpui-kit.d.ts"; echo 'mine' > "$L/notes.txt"
echo '<svg/>' > "$L/old.svg"; echo 'old.svg' >> "$L/$MARK"; echo 'x' > "$L/main.js"
inst
ok '[ "$RC" = 0 ] && cmp -s "$KD/mods/limits/main.js" "$L/main.js"' "update restores a shipped file"
ok '[ ! -e "$L/old.svg" ] && ! grep -qx old.svg "$L/$MARK"' "update removes a file only the old marker lists"
ok '[ -f "$L/jsconfig.json" ] && [ -f "$L/gpui-kit.d.ts" ] && [ "$(cat "$L/notes.txt")" = mine ]' "update keeps Herdr's and the user's files"

# ---- (7) an owned, unchanged layout takes a newer kit version ------------------------------------
kitcopy; jq '. + {"kit_test": 1}' "$T/kit/layouts/harness.json" > "$T/lay.json" && mv "$T/lay.json" "$T/kit/layouts/harness.json" || die "lay"
kinst
ok '[ "$RC" = 0 ] && cmp -s "$T/kit/layouts/harness.json" "$APP/layouts/harness.json" && [ "$(cat "$APP/layouts/.harness$MARK")" = "$(sha "$APP/layouts/harness.json")" ]' "unchanged layout replaced by the newer kit version"

# ---- (8) a layout changed since install survives; the mods still update --------------------------
fresh_app; inst
jq '. + {"kit_test_strip": {"type": "block", "id": "strip"}}' "$APP/layouts/harness.json" > "$T/lay.json" && mv "$T/lay.json" "$APP/layouts/harness.json" || die "dock"
lay=$(shasum "$APP/layouts/harness.json")
kitcopy; echo '// newer' >> "$T/kit/mods/limits/main.js"; kinst
ok '[ "$RC" = 0 ] && [ "$(shasum "$APP/layouts/harness.json")" = "$lay" ] && [[ "$OUT" == *"changed since install"* ]]' "a layout changed since install is left as it is"
ok 'cmp -s "$T/kit/mods/limits/main.js" "$APP/mods/limits/main.js"' "mods update alongside a changed layout"

# ---- (9)–(16) refusals: exit 3 and nothing written -----------------------------------------------
fresh_app; mkdir "$APP/mods/limits" && echo 'x' > "$APP/mods/limits/main.js" || die "foreign mod"
before=$(snap_app); inst
ok '[ "$RC" = 3 ] && [[ "$OUT" == *"mods/limits"* ]] && [ "$(snap_app)" = "$before" ]' "a mod folder without a marker is refused, nothing written"

fresh_app; echo '{}' > "$APP/layouts/harness.json"
before=$(snap_app); inst
ok '[ "$RC" = 3 ] && [[ "$OUT" == *"harness.json"* ]] && [ "$(snap_app)" = "$before" ]' "a layout without a sidecar is refused, nothing written"

fresh_app; rm -rf "$T/elsewhere"; mkdir "$T/elsewhere" && echo 'main.js' > "$T/elsewhere/$MARK" && echo 'y' > "$T/elsewhere/main.js" \
  && ln -s "$T/elsewhere" "$APP/mods/limits" || die "symlink"
before=$(snap_app); outside=$(snap_dir "$T/elsewhere"); inst
ok '[ "$RC" = 3 ] && [ "$(snap_app)" = "$before" ] && [ "$(snap_dir "$T/elsewhere")" = "$outside" ]' "a symlinked kit mod folder is refused, nothing changed inside or outside"

fresh_app; inst; echo '../../keys.json' >> "$APP/mods/limits/$MARK"
keys=$(shasum "$APP/keys.json"); before=$(snap_app); inst
ok '[ "$RC" = 3 ] && [ "$(shasum "$APP/keys.json" 2>/dev/null)" = "$keys" ] && [ "$(snap_app)" = "$before" ]' "a marker entry escaping the folder is refused, nothing changed"

fresh_app; kitcopy; jq '.mods += ["../x"]' "$T/kit/kit.json" > "$T/k.json" && mv "$T/k.json" "$T/kit/kit.json" || die "kit name"
before=$(snap_app); kinst
ok '[ "$RC" = 3 ] && [ "$(snap_app)" = "$before" ]' "a bad name in kit.json is refused, nothing written"

fresh_app; rm -rf "$T/elsewhere-dir"; mkdir "$T/elsewhere-dir" && ln -s "$T/elsewhere-dir" "$APP/layouts/.harness$MARK" || die "sidecar"
before=$(snap_app); inst
ok '[ "$RC" = 3 ] && [ "$(snap_app)" = "$before" ] && [ -z "$(ls -A "$T/elsewhere-dir")" ]' "a symlinked sidecar is refused, nothing changed inside or outside"

fresh_app; rm -rf "$APP/layouts" && echo 'x' > "$APP/layouts" || die "layouts file"
before=$(snap_app); inst
ok '[ "$RC" = 3 ] && [ "$(snap_app)" = "$before" ]' "a layouts path that is not a folder is refused, no mod written"

fresh_app; inst; echo 'mine' > "$APP/mods/limits/extra.svg"
kitcopy; echo '<svg/>' > "$T/kit/mods/limits/extra.svg"
before=$(snap_app); kinst
ok '[ "$RC" = 3 ] && [[ "$OUT" == *"extra.svg"* ]] && [ "$(snap_app)" = "$before" ]' "a user file of a newly shipped name is refused, nothing written"

# ---- (17) a planted temp-path symlink is harmless ------------------------------------------------
fresh_app; inst; echo 'keep' > "$T/victim"
ln -s "$T/victim" "$APP/mods/limits/main.js.tmp.99999" || die "planted"
echo 'x' > "$APP/mods/limits/main.js"; inst
ok '[ "$RC" = 0 ] && [ "$(cat "$T/victim")" = keep ]' "a planted temp symlink does not redirect a write"
ok '[ -z "$(find "$APP" -name ".kit-tmp.*")" ]' "a write leaves no temp file behind"

# ---- (18) an interrupted update is recoverable ---------------------------------------------------
fresh_app; inst
kitcopy; echo '<svg/>' > "$T/kit/mods/limits/new.svg"
echo 'new.svg' >> "$APP/mods/limits/$MARK"; echo '<svg/>' > "$APP/mods/limits/new.svg"
kinst
ok '[ "$RC" = 0 ] && [ "$(cat "$APP/mods/limits/$MARK")" = "$(cd "$T/kit/mods/limits" && ls)" ]' "a rerun after an interrupted update finishes it"

# ---- (18b) a hidden file in a kit mod folder is not a kit file -----------------------------------
fresh_app; kitcopy; echo 'finder' > "$T/kit/mods/limits/.DS_Store"
kinst
ok '[ "$RC" = 0 ] && [ ! -e "$APP/mods/limits/.DS_Store" ] && ! grep -qx .DS_Store "$APP/mods/limits/$MARK"' "a Finder .DS_Store in a kit mod folder is skipped, the install goes on"
kinst
ok '[ "$RC" = 0 ] && [[ "$OUT" == *"updated"* ]]' "an update with a .DS_Store in the kit goes on"

# ---- (19) limits discovery skips odd profile names -----------------------------------------------
mkdir -p "$T/h/.claude/projects" "$T/h/.codex-x/sessions" "$T/h/.codex-work laptop/sessions" || die "profiles"
DISC=$(node --input-type=module -e '
  import { readFileSync } from "node:fs";
  const src = readFileSync(process.argv.at(-1), "utf8");
  const m = src.match(/const DISCOVER = ([\s\S]*?);\n/);
  if (!m) process.exit(1);
  process.stdout.write((0, eval)(m[1]));
' "$KD/mods/limits/main.js") || die "DISCOVER"
OUT=$(HOME="$T/h" sh -c "$DISC" 2>&1)
ok '[ "$OUT" = "$(printf ".claude\n.codex-x")" ]' "discovery lists plain profile names only"

# ---- (20) file tabs are reused by full path ------------------------------------------------------
# Both openers run over one in-memory Herdr model; each case prints "<case> ok" or "<case> bad: <why>".
OUT=$(node --input-type=module -e '
  import { readFileSync } from "node:fs";
  const [fp, menu] = process.argv.slice(-2);
  const cut = (path, head, name) => {
    const lines = readFileSync(path, "utf8").split("\n"), i = lines.indexOf(head), j = lines.indexOf("}", i + 1);
    if (i < 0 || j < 0) { console.log(`cut ${name} missing in ${path}`); process.exit(1); }
    return lines.slice(i, j + 1).join("\n") + `\nreturn ${name};`;
  };
  let seq = 0, calls = [];
  const sp = [{ id: "s1", active: true, tabs: [{ id: "t0", name: "zsh" }] }, { id: "s2", active: false, tabs: [{ id: "t9", name: "other" }] }];
  let pn = [{ pane: "p0", tab: "t0", mod: null }, { pane: "p9", tab: "t9", mod: null }];
  const store = {};
  const env = [
    () => JSON.parse(JSON.stringify(sp)),
    () => pn.map(p => ({ ...p })),
    (cmd, args) => {
      calls.push([cmd, args]);
      if (cmd === "tab.new") { seq++; sp[0].tabs.push({ id: `t${seq}`, name: args.name }); pn.push({ pane: `p${seq}`, tab: `t${seq}`, mod: args.mod }); }
      return null;
    },
    k => store[k],
    (k, v) => { store[k] = JSON.parse(JSON.stringify(v)); return null; },
  ];
  const open = new Function("spaces", "panes", "run", "shared", "setShared", cut(fp, "function openFileTab(file, on) {", "openFileTab"))(...env);
  const prev = new Function("spaces", "panes", "run", "shared", "setShared", cut(menu, "function previewMarkdown(p) {", "previewMarkdown"))(...env);
  const step = f => { calls = []; f(); return calls; };
  const news = c => c.filter(x => x[0] === "tab.new").length, sel = c => c.filter(x => x[0] === "tab.select").map(x => x[1].id);
  const check = (name, cond, why) => console.log(cond ? `${name} ok` : `${name} bad: ${why} ${JSON.stringify(calls)}`);
  const reg = () => store["file-view.panes"] ?? {};
  const tabOf = id => pn.find(p => p.pane === id)?.tab;
  const split = (tab, pane) => { pn.push({ pane: `x${pane}`, tab, mod: "file-view" }); pn = pn.filter(p => p.pane !== pane); };

  let c = [...step(() => open("/r/a/README.md", null)), ...step(() => open("/r/b/README.md", null))];
  calls = c; check("c1", news(c) === 2 && sel(c).length === 0, "two same-named files must open two tabs");
  const aPane = Object.keys(reg()).find(id => reg()[id] === JSON.stringify([null, "/r/a/README.md", false])), aTab = tabOf(aPane);
  c = step(() => open("/r/a/README.md", null));
  check("c2", aTab && news(c) === 0 && sel(c).join() === aTab, "reopening a path must select its tab");
  split(aTab, aPane);
  c = step(() => open("/r/a/README.md", null));
  check("c3", news(c) === 1 && !sel(c).includes(aTab) && !(aPane in reg()), "a tab whose registered pane closed must not be reused");
  c = step(() => open("/r/a/README.md", "m1"));
  check("c4", news(c) === 1 && sel(c).length === 0, "the same path on another machine must open a new tab");

  c = step(() => prev({ path: "/r/a/README.md", name: "README.md", on: null }));
  check("c5a", news(c) === 1 && sel(c).length === 0, "a source tab must not match a preview");
  c = step(() => prev({ path: "/r/b/README.md", name: "README.md", on: null }));
  check("c5b", news(c) === 1 && sel(c).length === 0, "two same-named previews must open two tabs");
  const pPane = Object.keys(reg()).find(id => reg()[id] === JSON.stringify([null, "/r/a/README.md", true])), pTab = tabOf(pPane);
  c = step(() => prev({ path: "/r/a/README.md", name: "README.md", on: null }));
  check("c5c", pTab && news(c) === 0 && sel(c).join() === pTab, "reopening a preview must select its tab");
  split(pTab, pPane);
  c = step(() => prev({ path: "/r/a/README.md", name: "README.md", on: null }));
  check("c6", news(c) === 1 && !sel(c).includes(pTab) && !(pPane in reg()), "a preview tab whose registered pane closed must not be reused");
' "$KD/mods/files-plus/main.js" "$KD/mods/files-plus-menu/main.js" 2>&1); RC=$?
ok '[ "$RC" = 0 ]' "the file-tab model runs"
ok '[[ "$OUT" == *"c1 ok"* ]]' "files-plus: two same-named files in different folders open two tabs"
ok '[[ "$OUT" == *"c2 ok"* ]]' "files-plus: reopening the same path selects its tab"
ok '[[ "$OUT" == *"c3 ok"* ]]' "files-plus: a tab whose registered pane was closed is not reused; the registry is pruned"
ok '[[ "$OUT" == *"c4 ok"* ]]' "files-plus: the same path on another machine opens a new tab"
ok '[[ "$OUT" == *"c5a ok"* ]]' "files-plus-menu: a source tab of the file does not match its preview"
ok '[[ "$OUT" == *"c5b ok"* ]]' "files-plus-menu: two same-named previews open two tabs"
ok '[[ "$OUT" == *"c5c ok"* ]]' "files-plus-menu: reopening the same preview selects its tab"
ok '[[ "$OUT" == *"c6 ok"* ]]' "files-plus-menu: a preview tab whose registered pane was closed is not reused; the registry is pruned"
ok 'grep -q "^## Changes" "$KD/README.md"' "the kit README carries a change note"

[ "$fail" -eq 0 ] || exit 1
echo "herdr-kit-test: OK ($n checks)"
