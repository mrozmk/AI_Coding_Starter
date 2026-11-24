#!/usr/bin/env bash
# Offline test for .claude/lib/codex-bg.sh's CODEX_MODEL: set → `-m <id>` on the codex line and
# the model named in LOG; unset → no `-m` (the CLI default); an unsafe value → exit 2, no spawn.
# A stub `codex` on PATH records its argv; the real codex is never called.
set -euo pipefail
SRC="$(cd "$(dirname "$0")/.." && pwd)/codex-bg.sh"
[ -f "$SRC" ] || { echo "codex-bg-model-test: FAIL — $SRC missing"; exit 1; }
T=$(mktemp -d "${TMPDIR:-/tmp}/codex-bg-model.XXXXXX") \
  || { echo "codex-bg-model-test: FAIL — mktemp"; exit 1; }
trap 'rm -rf "$T"' EXIT
fail() { echo "codex-bg-model-test: FAIL — $1"; exit 1; }

# Comments-only profile: the template behaviour (no CODEX_HOME check, codex-bg.sh:138).
mkdir -p "$T/repo/.claude/lib" "$T/bin" "$T/codex-home"
cp "$SRC" "$T/repo/.claude/lib/codex-bg.sh"
printf '# template profile — no value\n' > "$T/repo/.claude/codex-profile"
export STUB_LOG="$T/stub.log"
cat > "$T/bin/codex" <<'STUB'
#!/usr/bin/env bash
out=""; prev=""
for a in "$@"; do
  printf '%s\n' "$a" >> "$STUB_LOG"
  [ "$prev" = "--output-last-message" ] && out="$a"
  prev="$a"
done
printf -- '--END--\n' >> "$STUB_LOG"
[ -z "$out" ] || printf '{}\n' > "$out"
exit 0
STUB
chmod +x "$T/bin/codex"

run_wrapper() {  # <model or -> → rc in $rc
  : > "$STUB_LOG"
  rc=0
  if [ "$1" = - ]; then
    env -u CODEX_MODEL PATH="$T/bin:$PATH" CODEX_HOME="$T/codex-home" CODEX_EFFORT=high \
      PROMPT="review" OUT="$T/out.md" LOG="$T/run.log" REPO="$T/repo" \
      bash "$T/repo/.claude/lib/codex-bg.sh" >/dev/null 2>"$T/err" || rc=$?
  else
    env PATH="$T/bin:$PATH" CODEX_HOME="$T/codex-home" CODEX_EFFORT=high CODEX_MODEL="$1" \
      PROMPT="review" OUT="$T/out.md" LOG="$T/run.log" REPO="$T/repo" \
      bash "$T/repo/.claude/lib/codex-bg.sh" >/dev/null 2>"$T/err" || rc=$?
  fi
}

# model set: the pair -m / <id> in argv, the model named in LOG.
run_wrapper gpt-6.2-sol
[ "$rc" = 0 ] || fail "model set: exit $rc ($(cat "$T/err"))"
grep -qx -- '-m' "$STUB_LOG" || fail "model set: no -m in argv"
[ "$(grep -A1 -x -- '-m' "$STUB_LOG" | sed -n 2p)" = gpt-6.2-sol ] \
  || fail "model set: -m is not followed by gpt-6.2-sol"
grep -qxF 'codex-bg.sh: model=gpt-6.2-sol' "$T/run.log" || fail "model set: LOG does not name the model"
echo "codex-bg-model-test: model set OK"

# model unset: no -m, LOG names the CLI default.
run_wrapper -
[ "$rc" = 0 ] || fail "model unset: exit $rc ($(cat "$T/err"))"
! grep -qx -- '-m' "$STUB_LOG" || fail "model unset: -m passed"
grep -qxF 'codex-bg.sh: model=CLI default' "$T/run.log" || fail "model unset: LOG does not say CLI default"
echo "codex-bg-model-test: model unset OK"

# model refused: an unsafe value never reaches codex; OUT stays empty.
run_wrapper 'x;rm'
[ "$rc" = 2 ] || fail "model refused: exit $rc, want 2"
[ ! -s "$STUB_LOG" ] || fail "model refused: codex was called"
[ ! -s "$T/out.md" ] || fail "model refused: OUT not empty"
grep -qF "CODEX_MODEL='x;rm' is not a model id" "$T/err" || fail "model refused: no message"
echo "codex-bg-model-test: model refused OK"
