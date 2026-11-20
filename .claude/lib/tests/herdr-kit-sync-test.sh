#!/usr/bin/env bash
# Offline test of .claude/lib/herdr-kit-sync.sh (the helper of /maintain:sync-herdr-kit): a fixture
# starter repo and a fixture app home — no network, no Herdr app, no real ~/.config/herdr-app.
# plan writes nothing and is a no-op without an app home; apply installs only from the unmodified
# clone at the revision plan showed; a refusal adds mv advice for a hand copy and moves nothing.
set -u
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
S="$ROOT/.claude/lib/herdr-kit-sync.sh"
KD="$ROOT/.claude/team/herdr-mod/panels"
[ -f "$S" ] || { echo "herdr-kit-sync-test: FAIL — $S missing"; exit 1; }
command -v git >/dev/null 2>&1 || { echo "herdr-kit-sync-test: FAIL — git missing"; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "herdr-kit-sync-test: FAIL — jq missing"; exit 1; }
T=$(mktemp -d "${TMPDIR:-/tmp}/herdr kit sync.XXXXXX") || { echo "herdr-kit-sync-test: FAIL — mktemp"; exit 1; }
trap 'rm -rf "$T"' EXIT
die() { echo "herdr-kit-sync-test: FAIL — fixture setup: $1"; exit 1; }
mkdir -p "$T/home" "$T/tmp" || die "dirs"

g() { HOME="$T/home" GIT_CONFIG_NOSYSTEM=1 git -c user.name=t -c user.email=t@example.invalid -c init.defaultBranch=main "$@"; }
mkdir -p "$T/starter" && cd "$T/starter" || die "starter"
g init -q -b main && echo starter > README.md && g add README.md && g commit -q -m init || die "init"
g tag old || die "tag"
mkdir -p .claude/team/herdr-mod && cp -R "$KD" .claude/team/herdr-mod/panels || die "kit copy"
g add -A && g commit -q -m kit || die "kit commit"
REV=$(g -C "$T/starter" rev-parse HEAD) || die "rev"
cd "$T" || die "cd"

n=0; fail=0; OUT=""; RC=0; APP=""
ok() { n=$((n + 1)); if ! eval "$1"; then echo "FAIL [$2]"; printf '%s\n' "$OUT" | sed 's/^/    /'; fail=1; fi; }
run() { OUT=$(HOME="$T/home" TMPDIR="$T/tmp" HERDR_APP_HOME="$APP" bash "$S" "$@" 2>&1); RC=$?; }
field() { printf '%s\n' "$OUT" | sed -n "s/^$1: //p"; }
has() { printf '%s\n' "$OUT" | grep -qF -- "$1"; }
snap_dir() { (cd "$1" && find . -type f -print | LC_ALL=C sort | while IFS= read -r f; do shasum "$f"; done); }
fresh_app() {
  rm -rf "$APP" && mkdir -p "$APP/mods/other" "$APP/layouts" && echo other > "$APP/mods/other/main.js" \
    && echo '{"theme":"x"}' > "$APP/settings.json" || die "fresh_app"
}

# 1. Usage.
APP="$T/app"
run; ok '[ "$RC" -eq 2 ]' "no args → 2"
run plan --bogus; ok '[ "$RC" -eq 2 ]' "plan --bogus → 2"
run plan --ref; ok '[ "$RC" -eq 2 ]' "plan --ref without a value → 2"
run apply only-one; ok '[ "$RC" -eq 2 ]' "apply with one arg → 2"

# 2. No app home: one line, no clone.
APP="$T/none"
run plan --repo "$T/missing"
ok '[ "$RC" -eq 0 ] && has "nothing to do" && ! has "kit-source:" && [ -z "$(ls "$T/tmp")" ]' "no app home → no-op, no clone"

# 3. Plan writes nothing.
APP="$T/app"; fresh_app; before=$(snap_dir "$APP")
run plan --repo "$T/starter"
ok '[ "$RC" -eq 0 ] && [ "$(field kit-rev)" = "$REV" ] && has "would install mods/files-plus" && has "would install layouts/harness.json"' "plan shows the dry run"
ok '[ "$(snap_dir "$APP")" = "$before" ]' "plan writes nothing"
D=$(field kit-source)
ok '[ -n "$D" ] && [ -d "$D" ]' "plan prints kit-source"

# 4. Apply refuses another revision.
run apply "$D" 0000000000000000000000000000000000000000
ok '[ "$RC" -eq 3 ] && [ "$(snap_dir "$APP")" = "$before" ]' "apply on another revision → 3, nothing written"

# 5. Apply refuses a modified clone, even with untracked files hidden by config.
g -C "$D" config status.showUntrackedFiles no && echo x > "$D/stray" || die "stray"
run apply "$D" "$REV"
ok '[ "$RC" -eq 3 ] && has "local changes" && [ "$(snap_dir "$APP")" = "$before" ]' "apply on a modified clone → 3, nothing written"
rm -f "$D/stray"

# 6. Apply installs.
other_before=$(shasum "$APP/mods/other/main.js" "$APP/settings.json")
run apply "$D" "$REV"
ok '[ "$RC" -eq 0 ]' "apply → 0"
missing=""
for m in $(jq -r '.mods[]' "$KD/kit.json"); do [ -f "$APP/mods/$m/.installed-by-harness" ] || missing="$missing $m"; done
ok '[ -z "$missing" ]' "every kit mod installed with its marker (missing:$missing)"
ok '[ -f "$APP/layouts/harness.json" ]' "layout installed"
ok '[ "$(shasum "$APP/mods/other/main.js" "$APP/settings.json")" = "$other_before" ]' "other files untouched"

# 7. Update path.
run plan --repo "$T/starter"
ok '[ "$RC" -eq 0 ] && has "would update mods/limits" && has "layouts/harness.json unchanged"' "rerun plan → update path"

# 8. A ref without the kit.
run plan --repo "$T/starter" --ref old
ok '[ "$RC" -eq 3 ] && has "has no Herdr kit"' "ref without the kit → 3"

# 9. Unknown ref.
run plan --repo "$T/starter" --ref nope
ok '[ "$RC" -eq 4 ]' "unknown ref → 4"

# 10. Hand-copied mod: refused with an mv line, left untouched.
APP="$T/app2"; fresh_app
mkdir -p "$APP/mods/limits" && echo hand > "$APP/mods/limits/main.js" || die "hand copy"
before=$(snap_dir "$APP")
run plan --repo "$T/starter"
expect=$(printf 'mv %q %q' "$APP/mods/limits" "$T/home/limits.hand-copy")
ok '[ "$RC" -eq 3 ] && printf "%s\n" "$OUT" | grep -qxF -- "$expect"' "hand copy → 3 with an mv line"
ok '[ "$(snap_dir "$APP")" = "$before" ] && [ "$(cat "$APP/mods/limits/main.js")" = hand ]' "hand copy left untouched"

# 11. Unsafe layout sidecar: refused, no mv advice.
APP="$T/app3"; fresh_app
ln -s "$T/home" "$APP/layouts/.harness.installed-by-harness" || die "symlink"
before=$(snap_dir "$APP")
run plan --repo "$T/starter"
ok '[ "$RC" -eq 3 ] && has "its sidecar is not a plain file" && ! printf "%s\n" "$OUT" | grep -q "^mv "' "unsafe sidecar → 3, no mv line"
ok '[ "$(snap_dir "$APP")" = "$before" ]' "unsafe sidecar → nothing written"

[ "$fail" -eq 0 ] || exit 1
echo "herdr-kit-sync-test: OK ($n checks)"
