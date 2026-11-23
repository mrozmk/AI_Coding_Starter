#!/usr/bin/env bash
# Portable test for .claude/lib/portable-lib.sh (macOS bash 3.2 and GNU/Linux): every branch of
# file_mode, file_mtime, new_uuid and epoch_fmt (host, GNU/BSD/Python stubs, total failure), the
# project preflight hook agreeing with file_mode, and a scan of the runtime scripts under .claude/
# for a bare BSD `stat -f` or a `uuidgen` invocation (plus the scan's own self-test).
set -euo pipefail

ST=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
LIB="$ST/.claude/lib/portable-lib.sh"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
fail() { echo "portable-userland-test: FAIL — $*"; exit 1; }
N=0
ok() { N=$((N + 1)); echo "ok $1"; }
UUID_RE='^[0-9a-f]{8}-([0-9a-f]{4}-){3}[0-9a-f]{12}$'
py_mtime() { python3 -I -c 'import os,sys; print(int(os.lstat(sys.argv[1]).st_mtime))' "$1"; }

[ -f "$LIB" ] || fail "missing $LIB (portable-lib.sh)"
# shellcheck source=../portable-lib.sh
. "$LIB"

# ---- 1. host branch ------------------------------------------------------------------------------
F="$WORK/f"; : > "$F"
for m in 600 644 700; do
  chmod "$m" "$F"; [ "$(file_mode "$F")" = "$m" ] || fail "file_mode $m gave $(file_mode "$F")"
done
ok "file_mode reads 600/644/700"
if chmod 4600 "$F" 2>/dev/null; then
  [ "$(file_mode "$F")" = 600 ] || fail "file_mode did not mask the special bits: $(file_mode "$F")"
  ok "file_mode masks the special bits"
else
  echo "skip file_mode special bits — chmod 4600 refused here"
fi
chmod 600 "$F"
ln -s "$F" "$WORK/link"
[ "$(file_mode "$WORK/link")" != 600 ] || fail "file_mode followed a symlink"
ok "file_mode does not follow a symlink"
set +e; v="$(file_mode "$WORK/missing")"; rc=$?; set -e
[ "$rc" = 1 ] && [ -z "$v" ] || fail "file_mode of a missing path: rc=$rc out=$v"
ok "file_mode of a missing path fails empty"

touch -t 202001020304.05 "$F"
[ "$(file_mtime "$F")" = "$(py_mtime "$F")" ] || fail "file_mtime $(file_mtime "$F") != $(py_mtime "$F")"
ok "file_mtime matches lstat"
set +e; v="$(file_mtime "$WORK/missing")"; rc=$?; set -e
[ "$rc" = 1 ] && [ -z "$v" ] || fail "file_mtime of a missing path: rc=$rc out=$v"
ok "file_mtime of a missing path fails empty"

u1="$(new_uuid)"; u2="$(new_uuid)"
[[ "$u1" =~ $UUID_RE ]] && [ "$u1" != "$u2" ] || fail "new_uuid gave '$u1' / '$u2'"
ok "new_uuid gives distinct lower-case UUIDs"

[ "$(epoch_fmt -u 0 +%Y-%m-%dT%H:%M:%SZ)" = 1970-01-01T00:00:00Z ] || fail "epoch_fmt -u 0"
[ "$(TZ=UTC epoch_fmt 86400 +%Y%m%d)" = 19700102 ] || fail "epoch_fmt 86400"
ok "epoch_fmt formats an epoch"

fx="$WORK/hookfx"; mkdir "$fx"
printf 'X=\n' > "$fx/.env.example"; printf 'X=1\n' > "$fx/.env"
chmod 600 "$fx/.env"
out="$(CLAUDE_PROJECT_DIR="$fx" bash "$ST/.claude/hooks/check-project-deps.sh" </dev/null)"
case "$out" in *".env is mode"*) fail "hook flagged a 600 .env: $out" ;; esac
chmod 644 "$fx/.env"
out="$(CLAUDE_PROJECT_DIR="$fx" bash "$ST/.claude/hooks/check-project-deps.sh" </dev/null)"
case "$out" in *".env is mode 644"*) ;; *) fail "hook missed a 644 .env: $out" ;; esac
[ "$(file_mode "$fx/.env")" = 644 ] || fail "file_mode disagrees with the hook"
ok "check-project-deps agrees with file_mode"

# ---- 2. stub branches ----------------------------------------------------------------------------
BASH_BIN="$(command -v bash)"
mkdir "$WORK/min"
for t in python3 tr date cat; do
  p="$(command -v "$t")" || fail "$t not on PATH"
  printf '#!/bin/sh\nexec "%s" "$@"\n' "$p" > "$WORK/min/$t"; chmod +x "$WORK/min/$t"
done
stub() {  # stub <dir> <name> <sh body>
  mkdir -p "$1"; printf '#!/bin/sh\n%s\n' "$3" > "$1/$2"; chmod +x "$1/$2"
}
sb() {  # sb <stub dir> <code> → OUT (stdout+stderr), RC
  set +e
  OUT="$(PATH="$1:$WORK/min" "$BASH_BIN" -c '. "$1"; set -euo pipefail; eval "$2"' _ "$LIB" "$2" 2>&1)"
  RC=$?; set -e
}
REAL_MT="$(py_mtime "$F")"

d="$WORK/s-bsd"
stub "$d" stat 'case "$1" in -c) echo "stat: illegal option -- c" >&2; exit 1 ;;
-f) case "$2" in %Lp) echo 600 ;; %m) echo 1600000000 ;; *) exit 1 ;; esac ;;
*) exit 1 ;; esac'
sb "$d" "file_mode '$F'; file_mtime '$F'"
[ "$RC" = 0 ] && [ "$OUT" = "600
1600000000" ] || fail "BSD stat branch: rc=$RC out=$OUT"
ok "BSD stat branch"

d="$WORK/s-leak"
stub "$d" stat 'case "$1" in -c) echo junk-c; exit 1 ;;
-f) echo "File: \"$3\""; echo "ID: 0 Namelen: 255"; exit 1 ;; *) exit 1 ;; esac'
chmod 600 "$F"
sb "$d" "file_mode '$F'; file_mtime '$F'"
case "$OUT" in *junk*|*File:*|*Namelen*) fail "a failed stat leaked into the output: $OUT" ;; esac
[ "$RC" = 0 ] && [ "$OUT" = "600
$REAL_MT" ] || fail "leak stub: rc=$RC out=$OUT"
ok "GNU stat -f leak is never used"

d="$WORK/s-gnu"
stub "$d" stat 'case "$1" in -c) case "$2" in %a) echo 4640 ;; %Y) echo 1700000000 ;; *) exit 1 ;; esac ;;
*) exit 1 ;; esac'
sb "$d" "file_mode '$F'; file_mtime '$F'"
[ "$RC" = 0 ] && [ "$OUT" = "640
1700000000" ] || fail "GNU stat branch: rc=$RC out=$OUT"
ok "GNU stat branch masks to 640"

d="$WORK/s-nostat"
stub "$d" stat 'exit 1'
sb "$d" "file_mode '$F'; file_mtime '$F'"
[ "$RC" = 0 ] && [ "$OUT" = "600
$REAL_MT" ] || fail "Python fallback: rc=$RC out=$OUT"
ok "Python fallback of file_mode and file_mtime"

d="$WORK/s-none"
stub "$d" stat 'exit 1'; stub "$d" python3 'exit 1'
sb "$d" "file_mode '$F'"
[ "$RC" = 1 ] && [ -z "$OUT" ] || fail "file_mode with no reader: rc=$RC out=$OUT"
sb "$d" "file_mtime '$F'"
[ "$RC" = 1 ] && [ -z "$OUT" ] || fail "file_mtime with no reader: rc=$RC out=$OUT"
ok "file_mode and file_mtime with no reader fail empty"

d="$WORK/s-upper"
stub "$d" uuidgen 'echo 0123ABCD-4567-89AB-CDEF-0123456789AB'
sb "$d" new_uuid
[ "$RC" = 0 ] && [ "$OUT" = 0123abcd-4567-89ab-cdef-0123456789ab ] || fail "upper uuidgen: rc=$RC out=$OUT"
ok "new_uuid lower-cases uuidgen"

d="$WORK/s-nouuidgen"
stub "$d" uuidgen 'exit 127'
sb "$d" new_uuid
[ "$RC" = 0 ] && [[ "$OUT" =~ $UUID_RE ]] || fail "uuidgen 127: rc=$RC out=$OUT"
ok "new_uuid falls back to Python"

d="$WORK/s-nogen"
stub "$d" uuidgen 'exit 1'; stub "$d" python3 'exit 1'
sb "$d" new_uuid
[ "$RC" = 1 ] && [ -z "$OUT" ] || fail "no generator: rc=$RC out=$OUT"
ok "new_uuid with no generator fails"

d="$WORK/s-bsddate"
stub "$d" date 'for a in "$@"; do [ "$a" = -d ] && exit 1; done; echo "BSD:$*"'
sb "$d" "epoch_fmt -u 5 +%s"
[ "$RC" = 0 ] && [ "$OUT" = "BSD:-u -r 5 +%s" ] || fail "BSD date branch: rc=$RC out=$OUT"
ok "epoch_fmt BSD branch"

d="$WORK/s-gnudate"
stub "$d" date '[ "$*" = "-d @0 +%s" ] && { echo 0; exit 0; }; echo "GNU:$*"'
sb "$d" "epoch_fmt -u 5 +%s"
[ "$RC" = 0 ] && [ "$OUT" = "GNU:-u -d @5 +%s" ] || fail "GNU date branch: rc=$RC out=$OUT"
ok "epoch_fmt GNU branch"

# ---- 3. runtime scan -----------------------------------------------------------------------------
# A runtime script must call portable-lib.sh (or a GNU-first inline form), never BSD-first `stat -f`
# (GNU prints file-system lines to stdout) nor `uuidgen` (absent on stock WSL).
scan() {  # scan git|fs <root> → `path:line: <rule>` per hit
  local how="$1" root="$2" rel
  if [ "$how" = git ]; then git -C "$root" ls-files .claude; else (cd "$root" && find .claude -type f | sed 's|^\./||'); fi |
  while IFS= read -r rel; do
    case "$rel" in
      .claude/lib/tests/*|.claude/lib/costs/tests/*|.claude/team/herdr-mod/*|.claude/lib/portable-lib.sh) continue ;;
    esac
    [ -f "$root/$rel" ] || continue
    grep -Iq . "$root/$rel" || continue
    awk -v p="$rel" '
      /^[[:space:]]*#/ { next }
      {
        if (match($0, /stat[[:space:]]+(-L[[:space:]]+)?-f/)) {
          if (substr($0, 1, RSTART - 1) !~ /stat[[:space:]]+-c/) print p ":" NR ": stat-f"
        }
        if ($0 ~ /(^|[;&|({!]|\$\(|(^|[^A-Za-z0-9_])(then|do|else|if|elif|while|until)[[:space:]])[[:space:]]*(command[[:space:]]+)?uuidgen([[:space:];|)>]|$)/)
          print p ":" NR ": uuidgen"
      }' "$root/$rel"
  done
}
hits="$(scan git "$ST")"
[ -z "$hits" ] || fail "runtime scripts still use a bare stat -f or uuidgen:
$hits"
ok "runtime scripts have no bare stat -f or uuidgen"

# ---- 4. scan self-test ---------------------------------------------------------------------------
mkdir -p "$WORK/fx/.claude/lib/tests" "$WORK/fx/.claude/team/herdr-mod"
cat > "$WORK/fx/.claude/lib/x.sh" <<'EOF'
stat -f %m "$f"
roles_mtime() { stat -f %m "$1" || stat -c %Y "$1"; }
s=$(uuidgen)
new_sid() { uuidgen; }
if uuidgen > "$f"; then :; fi
stat -c %Y "$f" 2>/dev/null || stat -f %m "$f"
  # stat -f in a comment
printf '#!/bin/sh\nexit 1\n' > "$WORK/bin/uuidgen"
echo "a lead session id without uuidgen"
EOF
echo 'stat -f %m "$f"' > "$WORK/fx/.claude/lib/tests/t.sh"
echo 'stat -f %m "$f"' > "$WORK/fx/.claude/team/herdr-mod/m.js"
hits="$(scan fs "$WORK/fx")"
expect=".claude/lib/x.sh:1: stat-f
.claude/lib/x.sh:2: stat-f
.claude/lib/x.sh:3: uuidgen
.claude/lib/x.sh:4: uuidgen
.claude/lib/x.sh:5: uuidgen"
[ "$hits" = "$expect" ] || fail "scan self-test hits:
$hits"
ok "scan self-test catches every forbidden form"

echo "portable-userland-test: OK ($N checks)"
