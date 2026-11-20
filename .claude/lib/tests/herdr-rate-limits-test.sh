#!/usr/bin/env bash
# Offline test of the Herdr kit's opt-in rate-limits producer (.claude/team/herdr-mod/panels/rate-limits.sh):
# fixture HOME only — never the real ~/.claude. A status line JSON on stdin becomes
# ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/rate-limits.json, which the limits panel's own claudeLimits()
# reads as the 5h and Week rows; bad or missing input writes nothing and never breaks a status line.
set -u
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
KD="$ROOT/.claude/team/herdr-mod/panels"
S="$KD/rate-limits.sh"
[ -f "$S" ] || { echo "herdr-rate-limits-test: FAIL — $S missing"; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "herdr-rate-limits-test: FAIL — jq missing"; exit 1; }
command -v node >/dev/null 2>&1 || { echo "herdr-rate-limits-test: FAIL — node missing"; exit 1; }
T=$(mktemp -d "${TMPDIR:-/tmp}/herdr limits.XXXXXX") || { echo "herdr-rate-limits-test: FAIL — mktemp"; exit 1; }
trap 'rm -rf "$T"' EXIT
die() { echo "herdr-rate-limits-test: FAIL — fixture setup: $1"; exit 1; }
H="$T/home"
mkdir -p "$H/.claude" "$H/.claude-work" || die "home"

FIVE='{"used_percentage":42,"resets_at":1795040000}'
WEEK='{"used_percentage":13.5,"resets_at":1795532400}'
BASE='"model":{"id":"claude-opus","display_name":"Opus"},"workspace":{"current_dir":"/tmp/x"},"session_id":"abc"'
FULL="{$BASE,\"rate_limits\":{\"five_hour\":$FIVE,\"seven_day\":$WEEK}}"

n=0; fail=0; OUT=""; RC=0
ok() { n=$((n + 1)); if ! eval "$1"; then echo "FAIL [$2]"; printf '%s\n' "$OUT" | sed 's/^/    /'; fail=1; fi; }
# run <input> [env assignments...] -- [script args...]: CLAUDE_CONFIG_DIR is unset unless assigned.
run() {
  local input="$1"; shift
  local envs=()
  while [ $# -gt 0 ] && [ "$1" != "--" ]; do envs+=("$1"); shift; done
  [ $# -gt 0 ] && shift
  OUT=$(printf '%s' "$input" | env -u CLAUDE_CONFIG_DIR HOME="$H" ${envs[@]+"${envs[@]}"} bash "$S" "$@" 2>&1); RC=$?
}
no_temp() { [ -z "$(find "$1" -name '.rate-limits.*' 2>/dev/null)" ]; }

# ---- (1) default folder --------------------------------------------------------------------------
START=$(date +%s)
run "$FULL" --
END=$(date +%s)
F="$H/.claude/rate-limits.json"
ok '[ "$RC" -eq 0 ] && [ -z "$OUT" ]' "default: exit 0, stdout empty"
ok '[ -f "$F" ]' "default: rate-limits.json in ~/.claude"
ok '[ "$(jq -c "keys" "$F")" = "[\"at\",\"five_hour\",\"seven_day\"]" ]' "default: keys at, five_hour, seven_day"
ok '[ "$(jq -c .five_hour "$F")" = "$FIVE" ] && [ "$(jq -c .seven_day "$F")" = "$WEEK" ]' "default: windows equal the input"
ok 'jq -e --argjson s "$START" --argjson e "$END" "(.at | type) == \"number\" and .at >= \$s and .at <= \$e" "$F" >/dev/null' "default: at is now"
ok 'no_temp "$H/.claude"' "default: no temp file left"

# ---- (2) CLAUDE_CONFIG_DIR -----------------------------------------------------------------------
rm -f "$F"
run "$FULL" CLAUDE_CONFIG_DIR="$H/.claude-work" --
ok '[ "$RC" -eq 0 ] && [ -f "$H/.claude-work/rate-limits.json" ] && [ ! -e "$F" ]' "CLAUDE_CONFIG_DIR: written there, not into ~/.claude"

# ---- (3) only seven_day --------------------------------------------------------------------------
run "{$BASE,\"rate_limits\":{\"seven_day\":$WEEK}}" --
ok '[ "$RC" -eq 0 ] && [ "$(jq -c "keys" "$F")" = "[\"at\",\"seven_day\"]" ]' "seven_day only: file has at + seven_day"

# ---- (4) no rate_limits keeps an existing file --------------------------------------------------
echo '{"at":1,"keep":true}' > "$F" || die "seed"
BEFORE=$(shasum "$F")
run "{$BASE}" --
ok '[ "$RC" -eq 0 ] && [ -z "$OUT" ] && [ "$(shasum "$F")" = "$BEFORE" ]' "no rate_limits: existing file byte-identical"
run "{$BASE,\"rate_limits\":{}}" --
ok '[ "$RC" -eq 0 ] && [ "$(shasum "$F")" = "$BEFORE" ]' "empty rate_limits: existing file byte-identical"

# ---- (5) bad JSON --------------------------------------------------------------------------------
rm -f "$F"
run '{"rate_limits": {"five_hour": ' --
ok '[ "$RC" -eq 0 ] && [ -z "$OUT" ] && [ ! -e "$F" ] && no_temp "$H/.claude"' "bad JSON: nothing written, exit 0, stdout empty"

# ---- (6) config folder missing -------------------------------------------------------------------
run "$FULL" CLAUDE_CONFIG_DIR="$H/.claude-none" --
ok '[ "$RC" -eq 0 ] && [ -z "$OUT" ] && [ ! -e "$H/.claude-none" ]' "missing folder: nothing created, exit 0"

# ---- (7) pass-through ----------------------------------------------------------------------------
rm -f "$F"
run "$FULL" -- sh -c 'cat; echo; echo wrapped'
ok '[ "$RC" -eq 0 ] && [ "$OUT" = "$(printf "%s\nwrapped" "$FULL")" ]' "pass-through: wrapped command gets the exact input"
ok '[ -f "$F" ]' "pass-through: file written"
run "$FULL" -- sh -c 'exit 5'
ok '[ "$RC" -eq 5 ]' "pass-through: wrapped command's exit status"

# ---- (8) the panel's own claudeLimits() reads the file -------------------------------------------
run "$FULL" --
OUT=$(node -e '
  const fs = require("node:fs");
  const [mainJs, dir] = process.argv.slice(1);
  const lines = fs.readFileSync(mainJs, "utf8").split("\n");
  const i = lines.indexOf("async function claudeLimits(path) {");
  const j = i < 0 ? -1 : lines.indexOf("}", i);
  if (j < 0) { console.log("claudeLimits(path) not found in main.js"); process.exit(1); }
  const src = lines.slice(i, j + 1).join("\n");
  const readTextFile = async (p) => fs.readFileSync(p, "utf8");
  const claudeLimits = new Function("readTextFile", src + "\nreturn claudeLimits;")(readTextFile);
  claudeLimits(dir).then((r) => {
    const want = [{ label: "5h", used: 42, resets: 1795040000 }, { label: "Week", used: 13.5, resets: 1795532400 }];
    const good = typeof r.at === "number" && JSON.stringify(r.windows) === JSON.stringify(want);
    console.log(JSON.stringify(r));
    process.exit(good ? 0 : 1);
  }, (e) => { console.log(String(e)); process.exit(1); });
' "$KD/mods/limits/main.js" "$H/.claude" 2>&1); RC=$?
ok '[ "$RC" -eq 0 ]' "panel contract: claudeLimits() reads the 5h and Week rows"

# ---- (9) README ----------------------------------------------------------------------------------
OUT=""
ok 'grep -q "rate-limits.sh" "$KD/README.md" && ! grep -q "does not ship" "$KD/README.md"' "README names rate-limits.sh, no longer says the producer is missing"

[ "$fail" -eq 0 ] || exit 1
echo "herdr-rate-limits-test: OK ($n checks)"
