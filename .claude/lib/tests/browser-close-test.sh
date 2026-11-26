#!/usr/bin/env bash
# Contract + behaviour test for #306 — a verification session closes the browser it opened.
# (a) every text that drives a browser MCP carries a closing step; (b) a sweep of the tracked
# `.claude/` files for browser-starting markers — every hit must be classified in INVENTORY below;
# (c) design-render.sh's cleanup trap against a stub npx; (d) same_proc refuses a mismatched
# identity; (e) cleanup's ownership rules on a fixture process table (no real process signalled).
# No real browser runs; the test signals only processes it started itself.
#
# Usage: bash .claude/lib/tests/browser-close-test.sh [root]   (default: this checkout)
set -u
ROOT="${1:-$(cd "$(dirname "$0")/../../.." && pwd)}"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

DR=.claude/lib/design-render.sh
FAILS=()
N=0
check() {  # check <rc> <what>
  N=$((N + 1))
  [ "$1" -eq 0 ] || FAILS+=("$2")
}
has() { grep -qF -- "$2" "$ROOT/$1"; }
lacks() { ! grep -qF -- "$2" "$ROOT/$1"; }

# ---- (a) closing steps -------------------------------------------------------------------------
for f in .claude/agents/qa-runtime-ui.md .claude/commands/gates/design-quality-check.md \
         .claude/commands/seo-geo-audit.md; do
  has "$f" 'mcp__playwright__browser_close'; check $? "$f: no closing step"
done
for f in .claude/commands/qa-verify.md .claude/commands/execute.md \
         .claude/commands/gates/verify-implementation.md .claude/commands/ai-act-audit.md; do
  has "$f" 'browser_close'; check $? "$f: no closing step"
done
has .claude/agents/qa-runtime-device.md.example '## Closing the browser'
check $? ".claude/agents/qa-runtime-device.md.example: no closing step"
has .claude/agents/qa-runtime-device.md.example 'mcp__{device_mcp_server}__browser_close'
check $? ".claude/agents/qa-runtime-device.md.example: no closing step"
has .claude/agents/qa-runtime-ui.md '## Closing the browser'
check $? ".claude/agents/qa-runtime-ui.md: no closing step"
has .claude/commands/qa-verify.md '`## Closing the browser`'
check $? ".claude/commands/qa-verify.md: no closing step"
lacks .claude/commands/seo-geo-audit.md 'Close the browser page when done'
check $? ".claude/commands/seo-geo-audit.md: the vague close is back"

# ---- (b) inventory sweep -----------------------------------------------------------------------
# One line per tracked file that starts a browser: `<path> closes|exempt — <reason>`.
cat > "$WORK/inventory.txt" <<'EOF'
.claude/agents/qa-runtime-device.md.example closes — ## Closing the browser (#306 inventory row 6)
.claude/commands/gates/design-quality-check.md closes — §6 step 9 (#306 inventory row 7)
.claude/commands/qa-verify.md closes — Driver mcp / subagent / light run close; the script skeleton closes itself (#306 inventory rows 2-4)
.claude/commands/seo-geo-audit.md closes — Step 3 names mcp__playwright__browser_close (#306 inventory row 10)
.claude/lib/design-render.sh closes — cleanup trap on INT/TERM/HUP (#306 inventory row 1)
.claude/skills/wcag-audit/runner/lib/browser.mjs exempt — closes in finally + signal handlers (#306 inventory row 13)
EOF
git -C "$ROOT" ls-files .claude | grep -v '^\.claude/lib/tests/' | grep -v '/node_modules/' > "$WORK/tracked.txt"
[ -s "$WORK/tracked.txt" ]; check $? "sweep: git ls-files listed no .claude file"
( cd "$ROOT" && tr '\n' '\0' < "$WORK/tracked.txt" \
    | xargs -0 grep -lE '__browser_navigate|chromium\.launch\(|playwright@[^ ]*" screenshot' ) > "$WORK/hits.txt"
while IFS= read -r hit; do
  [ -n "$hit" ] || continue
  grep -qE "^$(printf '%s' "$hit" | sed 's/[][\.*^$/]/\\&/g') (closes|exempt) — " "$WORK/inventory.txt"
  check $? "unclassified browser-starting path: $hit — add it to the #306 inventory"
done < "$WORK/hits.txt"

# ---- (c) design-render.sh trap behaviour -------------------------------------------------------
if ! command -v node >/dev/null 2>&1; then
  echo "skip: node absent — design-render trap runs not executed"
  check 0 "design-render trap runs skipped — node absent"
else
  mkdir -p "$WORK/bin" "$WORK/bin2"
  printf '<p>x</p>\n' > "$WORK/m.html"
  cat > "$WORK/bin/npx" <<'EOF'
#!/usr/bin/env bash
echo $$ > "$STUB_DIR/npx.pid"
sleep 300 &
echo $! > "$STUB_DIR/child.pid"
wait
EOF
  cat > "$WORK/bin2/npx" <<'EOF'
#!/usr/bin/env bash
for a in "$@"; do last=$a; done
printf 'PNG' > "$last"
exit 0
EOF
  chmod +x "$WORK/bin/npx" "$WORK/bin2/npx"

  STUB_DIR="$WORK" PATH="$WORK/bin:$PATH" bash "$ROOT/$DR" "$WORK/m.html" "$WORK/out" > "$WORK/render.out" 2>&1 &
  dr_pid=$!
  i=0
  while [ ! -s "$WORK/child.pid" ] && [ "$i" -lt 50 ]; do sleep 0.2; i=$((i + 1)); done
  kill -TERM "$dr_pid" 2>/dev/null
  wait "$dr_pid"; rc=$?
  trap_ok=1
  if [ -s "$WORK/child.pid" ] && [ "$rc" -eq 0 ] \
     && grep -qF 'render: unavailable — interrupted (TERM)' "$WORK/render.out"; then
    j=0
    while [ "$j" -lt 25 ]; do
      alive=0
      for f in npx.pid child.pid; do
        kill -0 "$(cat "$WORK/$f")" 2>/dev/null && alive=1
      done
      [ "$alive" -eq 0 ] && { trap_ok=0; break; }
      sleep 0.2; j=$((j + 1))
    done
  fi
  check "$trap_ok" "design-render trap: an interrupted render leaves a stub process running"
  if [ "$trap_ok" -ne 0 ]; then  # end the stub processes this test started, so none outlives it
    for f in child.pid npx.pid; do
      [ -s "$WORK/$f" ] && kill "$(cat "$WORK/$f")" 2>/dev/null
    done
  fi

  PATH="$WORK/bin2:$PATH" bash "$ROOT/$DR" "$WORK/m.html" "$WORK/out2" > "$WORK/render2.out" 2>&1
  grep -qxF 'render: ok' "$WORK/render2.out"
  check $? "design-render: a normal render no longer prints render: ok"
fi

# ---- (d) same_proc -----------------------------------------------------------------------------
(
  DESIGN_RENDER_SOURCE_ONLY=1 . "$ROOT/$DR"
  sleep 300 &
  P=$!
  r=0
  same_proc "$P" "not the identity" && r=1
  same_proc "$P" "$(proc_ident "$P")" || r=1
  kill -0 "$P" 2>/dev/null || r=1
  kill "$P" 2>/dev/null
  wait "$P" 2>/dev/null
  exit "$r"
)
check $? "same_proc: a mismatched identity is not refused"

# ---- (e) cleanup ownership on a fixture process table ------------------------------------------
# Root 100 (start T0); child 101 (ppid 100); 102 is listed by `pgrep -P 100` but its own ps line
# names ppid 999. ps, pgrep, sleep and send_sig are shadowed: no real process is signalled.
fixture_cleanup() {  # fixture_cleanup <normal|replaced|changed|title>
  (
    DESIGN_RENDER_SOURCE_ONLY=1 . "$ROOT/$DR"
    CASE="$1"
    : > "$WORK/signals"
    : > "$WORK/cmd-calls"
    ps() {  # ps -o <format> -p <pid>
      local fmt="$2" pid="$4" ppid start
      case "$pid" in
        100) ppid=1; start=T0; [ "$CASE" = replaced ] && start=T9 ;;
        101) ppid=100; start=T1
             [ "$CASE" = changed ] && grep -qx 'TERM 101' "$WORK/signals" && start=T5 ;;
        102) ppid=999; start=T2 ;;
        *) return 1 ;;
      esac
      case "$fmt" in
        lstart=) echo "$start" ;;
        ppid=,lstart=) echo "  $ppid $start" ;;
        command=) echo x >> "$WORK/cmd-calls"
                  if [ "$CASE" = title ]; then echo "npm exec $(wc -l < "$WORK/cmd-calls")"; else echo npx; fi ;;
        *) return 1 ;;
      esac
    }
    pgrep() { [ "$2" = 100 ] && printf '101\n102\n'; return 0; }
    sleep() { :; }
    send_sig() { echo "$1 $2" >> "$WORK/signals"; }
    SHOT_PID=100
    SHOT_IDENT=T0
    cleanup
  )
}
fixture_cleanup normal
grep -qx 'TERM 100' "$WORK/signals" && grep -qx 'TERM 101' "$WORK/signals" && ! grep -q ' 102$' "$WORK/signals"
check $? "cleanup: a process whose parent does not match was signalled"
fixture_cleanup replaced
[ ! -s "$WORK/signals" ]
check $? "cleanup: a replaced root was signalled"
fixture_cleanup changed
grep -qx 'TERM 101' "$WORK/signals" && ! grep -qx 'KILL 101' "$WORK/signals"
check $? "cleanup: a process whose identity changed was killed"
fixture_cleanup title
grep -qx 'TERM 100' "$WORK/signals"
check $? "cleanup: a title change broke ownership"

# ---- no name-based or process-group killing in the script ------------------------------------
for neg in pkill killall 'kill -- -'; do
  lacks "$DR" "$neg"; check $? "design-render: contains $neg"
done

for f in "${FAILS[@]+"${FAILS[@]}"}"; do echo "FAIL [$f]"; done
[ "${#FAILS[@]}" -eq 0 ] || exit 1
echo "browser-close-test: OK ($N checks)"
