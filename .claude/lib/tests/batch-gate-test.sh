#!/usr/bin/env bash
# Offline test of .claude/lib/batch-gate.sh — `due` (line, prime, json, --merged, --release), `run`,
# `hold`, `lift` — over fixture repos under one mktemp -d. HOME, TMPDIR and the gate lock dir point
# inside it; commit dates are pinned in local time at fixed hours and "today" with BATCH_GATE_TODAY.
# Each fixture repo carries a fake `.claude/lib/tests/team-suite.sh` driven by files in its control
# dir (what --list-steps prints, what a run prints, its exit, a marker that proves it ran).
# BATCH_GATE_TEST_GROUPS="<names>" runs only those case groups (frame due run hold release; unset =
# all); a selected group that runs no case is a FAIL. No network, no real checkout, no real lock.
set -u
SRC="$(cd "$(dirname "$0")/../../.." && pwd)"
BG="$SRC/.claude/lib/batch-gate.sh"
GL_PY="$SRC/.claude/lib/gate_lock.py"
T=$(mktemp -d) || { echo "batch-gate-test: FAIL — mktemp"; exit 1; }
BGPIDS=()
cleanup() {
  local p
  for p in ${BGPIDS[@]+"${BGPIDS[@]}"}; do kill "$p" 2>/dev/null; done
  chmod -R u+rwx "$T" 2>/dev/null; rm -rf "$T"
}
trap cleanup EXIT
T="$(cd "$T" && pwd -P)"
export HOME="$T/home" TMPDIR="$T/tmp/"; mkdir -p "$HOME" "$T/tmp"
export TEAM_GATE_LOCK_DIR="$T/locks" TEAM_GATE_LOCK_WAIT=2 TEAM_GATE_LOCK_POLL=0.1 \
  TEAM_GATE_LOCK_LOG="$T/lock.log" TEAM_GATE_LOCK_NOTICE=60
SEL="${BATCH_GATE_TEST_GROUPS:-frame due run hold release}"
unset CLAUDE_PROJECT_DIR BATCH_GATE_TODAY BATCH_GATE_TEST_GROUPS TEAM_SUITE_ONLY TEAM_SUITE_SKIP \
  TEAM_SUITE_TESTS TEAM_SUITE_SELFTEST TEAM_SUITE_JOBS TEAM_SUITE_CASE_TIMES TEAM_GATE_LOCK_WORKLOAD
TODAY=2026-06-30
TAB=$(printf '\t')
[ -f "$BG" ] || echo "FAIL batch-gate.sh present"

fail=0; GROUP=""; GROUPS_RUN=" "
ok() {  # <label> <exit status of the check>
  eval "GC_$GROUP=\$((\${GC_$GROUP:-0} + 1))"
  if [ "$2" = 0 ]; then echo "PASS $1"; else fail=1; echo "FAIL $1"; fi
}
group() {  # group <name> — 0 when selected; the cases that follow count for it
  GROUP="$1"
  case " $SEL " in *" $1 "*) GROUPS_RUN="$GROUPS_RUN$1 "; return 0 ;; esac
  return 1
}

# ---- fixtures ------------------------------------------------------------------------------------
SEQ=0
gitc() { local d="$1"; shift; git -C "$d" -c user.email=t@t -c user.name=t -c commit.gpgsign=false "$@"; }
cmt() {  # cmt <repo> <local YYYY-MM-DDTHH:MM:SS> <file…> — one commit touching each file
  local d="$1" ts="$2" f; shift 2
  for f in "$@"; do
    SEQ=$((SEQ + 1)); mkdir -p "$(dirname "$d/$f")"; echo "c$SEQ" >> "$d/$f"; git -C "$d" add -- "$f"
  done
  GIT_AUTHOR_DATE="$ts" GIT_COMMITTER_DATE="$ts" gitc "$d" commit -q -m "c$SEQ"
}
mrg() {  # mrg <repo> <ts> <file…> — a --no-ff merge into main of a side branch touching each file
  local d="$1" ts="$2" b; shift 2
  b="side$SEQ"; git -C "$d" checkout -q -b "$b"
  cmt "$d" "$ts" "$@"
  git -C "$d" checkout -q main
  GIT_AUTHOR_DATE="$ts" GIT_COMMITTER_DATE="$ts" gitc "$d" merge -q --no-ff -m "Merge $b" "$b"
}
hsha() { git -C "$1" rev-parse HEAD; }
fake_suite() {  # fake_suite <repo> <ctl dir> — the gate's team suite, driven by <ctl>
  local c="$2"
  mkdir -p "$1/.claude/lib/tests" "$c"
  cat > "$1/.claude/lib/tests/team-suite.sh" <<EOF
#!/usr/bin/env bash
C='$c'
for a in "\$@"; do
  if [ "\$a" = --list-steps ]; then
    env > "\$C/list-env"; [ ! -f "\$C/list" ] || cat "\$C/list"; exit "\$(cat "\$C/list-rc" 2>/dev/null || echo 0)"
  fi
done
touch "\$C/ran"; env > "\$C/seen-env"
[ ! -f "\$C/sleep" ] || sleep "\$(cat "\$C/sleep")"
[ ! -f "\$C/dirty" ] || echo x >> "\$PWD/dirtied-by-suite"
[ ! -f "\$C/out" ] || cat "\$C/out"
: > "\$C/suite.log"; echo "team-suite: done"; echo "log: \$C/suite.log"
exit "\$(cat "\$C/rc" 2>/dev/null || echo 0)"
EOF
  printf 'purity\nsmoke-1\nx-test\n' > "$c/list"
  printf 'ok purity 1 checks 0s\nok smoke-1 2 checks 0s\nok x-test 1 checks 0s\n' > "$c/out"
}
mkrepo() {  # mkrepo <dir> <ctl dir>
  mkdir -p "$1" && git -C "$1" -c init.defaultBranch=main init -q
  printf '.agents/team/\n.claude/project-profile.json\n' > "$1/.gitignore"
  fake_suite "$1" "$2"
  printf '# names tested.sh and docs/tested.md\n' > "$1/.claude/lib/tests/a-test.sh"
  mkdir -p "$1/src"; echo base > "$1/src/base.txt"
  git -C "$1" add -A
  GIT_AUTHOR_DATE=2026-06-01T12:00:00 GIT_COMMITTER_DATE=2026-06-01T12:00:00 gitc "$1" commit -q -m base
}
BG_HERE='{"line":"main","gates":{"here":{"repo":"."}}}'
BG_BOTH='{"line":"main","gates":{"here":{"repo":"."},"starter":{"repo":"../starter","only":["purity"]}}}'
prof() {  # prof <main> <batch_gate json | -> — a complete teams profile, with the block unless -
  mkdir -p "$1/.claude"
  jq -n --arg b "$2" '{schema: 1, teams: ({tracker: "none", pr_provider: "none", trunk: "main",
      gates: "auto", build_check: "true", test_gate: "none", env_file_required: false,
      branch_types: ["feat", "fix"], required_tools: ["git"]}
      + (if $b == "-" then {} else {batch_gate: ($b | fromjson)} end))}' > "$1/.claude/project-profile.json"
}
world() {  # world <name> [starter] → W M S CH CS: fresh repos, the default block
  W="$T/w/$1"; M="$W/main"; S="$W/starter"; CH="$T/ctl/$1-here"; CS="$T/ctl/$1-starter"
  mkrepo "$M" "$CH"
  if [ "${2:-}" = starter ]; then mkrepo "$S" "$CS"; printf 'purity\n' > "$CS/list"
    printf 'ok purity 1 checks 0s\n' > "$CS/out"; prof "$M" "$BG_BOTH"
  else prof "$M" "$BG_HERE"; fi
}
OUT=""; ERR=""; RC=0
bg() {  # bg <dir> <args…> — batch-gate.sh in <dir> with today pinned; stdout → OUT, stderr → ERR
  local d="$1"; shift
  OUT=$(cd "$d" && BATCH_GATE_TODAY="${BTODAY:-$TODAY}" bash "$BG" "$@" 2>"$T/err"); RC=$?
  ERR=$(cat "$T/err")
}
green() {  # green <main> <gate> — a recorded green run (fails the case group when it is not)
  bg "$1" run "$2"
  [ "$RC" = 0 ] || { echo "FAIL fixture green run of $2 (rc $RC): $ERR"; fail=1; }
}
red() {  # red <main> <gate> <ctl> <step> — a recorded red run: <step> fails, every other listed step passes
  local s
  cp "$3/out" "$3/out.keep"
  while IFS= read -r s; do
    if [ "$s" = "$4" ]; then echo "FAIL $s rc 1, 0 checks — see x"; else echo "ok $s 1 checks 0s"; fi
  done < "$3/list" > "$3/out"
  echo 1 > "$3/rc"; bg "$1" run "$2"
  rm -f "$3/rc"; mv "$3/out.keep" "$3/out"
}
jrec() { jq -r "$2" "$1/.agents/team/batch-gate.json" 2>/dev/null; }
jout() { printf '%s' "$OUT" | jq -r "$1" 2>/dev/null; }
has() { printf '%s\n' "$OUT" | grep -qF -- "$1"; }
plan() {  # plan <main> <lines…> — writes the day plan
  local d="$1"; shift; mkdir -p "$d/.agents/team"; printf '%s\n' "$@" > "$d/.agents/team/day-plan.md"
}
fake_lock() {  # fake_lock <what> — a live holder of the fixture gate lock → LOCK_PID LOCK_TOKEN
  sleep 120 & LOCK_PID=$!; BGPIDS+=("$LOCK_PID")
  LOCK_TOKEN=$(python3 -I "$GL_PY" acquire "$LOCK_PID" fixture "$1" 2>/dev/null | cut -d' ' -f1)
}
fake_unlock() { python3 -I "$GL_PY" release "$LOCK_PID" "$LOCK_TOKEN"; kill "$LOCK_PID" 2>/dev/null; wait "$LOCK_PID" 2>/dev/null; }
T1=2026-06-30T09:00:00; T2=2026-06-30T10:00:00; T3=2026-06-30T11:00:00; T4=2026-06-30T13:00:00

# ==== group frame ==================================================================================
if group frame; then
  # 1. silent cases
  mkdir -p "$T/nogit"; bg "$T/nogit" due; st=$RC$OUT
  world s1
  mkdir -p "$T/nojq"; ln -s "$(command -v git)" "$T/nojq/git"
  OUT=$(cd "$M" && PATH="$T/nojq" /bin/bash "$BG" due 2>&1); st="$st|$?$OUT"
  rm "$M/.claude/project-profile.json"; bg "$M" due; st="$st|$RC$OUT"
  prof "$M" -; bg "$M" due; st="$st|$RC$OUT"
  C="$W/main-idle"; mkrepo "$C" "$T/ctl/s1-c"; prof "$C" "$BG_HERE"
  mkdir -p "$C/.agents/team"; echo '{"team":"idle"}' > "$C/.agents/team/team.json"
  bg "$C" due; st="$st|$RC$OUT"
  C2="$W/main-active"; mkrepo "$C2" "$T/ctl/s1-c2"; prof "$C2" "$BG_HERE"
  mkdir -p "$C2/.agents/team"; echo '{}' > "$C2/.agents/team/session.json"
  bg "$C2" due; st="$st|$RC$OUT"
  [ "$st" = "0|0|0|0|0|0" ]; ok "silent cases — outside git, no jq, no profile, no block, idle and active clone ($st)" $?
  prof "$M" "$BG_HERE"; bg "$C" -C "$M" due
  [ "$RC" = 0 ] && has "batch due (here): no green baseline"; ok "silent cases — -C <main> from a clone reports the main checkout" $?

  # 22. command not team suite refused
  world s22; st=0
  for c in "make test" "bash x/not-team-suite.sh" "bash .claude/lib/tests/team-suite.sh; touch $T/pwned" \
    "bash .claude/lib/tests/team-suite.sh --parallel"; do
    prof "$M" "$(jq -cn --arg c "$c" '{line: "main", gates: {here: {repo: ".", command: $c}}}')"
    bg "$M" due; has "batch gate: invalid gates.here.command" || st=1
    bg "$M" run here; [ "$RC" = 2 ] || st=1
  done
  [ "$st" = 0 ] && [ ! -e "$CH/ran" ] && [ ! -e "$CH/list-env" ] && [ ! -e "$T/pwned" ]
  ok "command not team suite refused — due names it, run exits 2, nothing invoked" $?
  prof "$M" "$(jq -cn '{line: "main", gates: {here: {repo: ".", command: "bash .claude/lib/tests/team-suite.sh --keep-going"}}}')"
  bg "$M" due; has "batch due (here)"; ok "command not team suite refused — --keep-going is accepted" $?

  # 34. writers refused from a team clone
  world s34; C="$W/main-x"; mkrepo "$C" "$T/ctl/s34-c"; mkdir -p "$C/.agents/team"; echo '{}' > "$C/.agents/team/team.json"
  st=0
  for a in "run here" "hold --text x" "lift --text x"; do
    OUT=$(cd "$C" && CLAUDE_PROJECT_DIR="$C" bash "$BG" -C "$M" $a 2>&1); r=$?
    [ "$r" = 2 ] && printf '%s' "$OUT" | grep -q 'not from a team clone' || st=1
  done
  OUT=$(cd "$T" && CLAUDE_PROJECT_DIR="$C" bash "$BG" -C "$M" hold --text x 2>&1); r=$?
  [ "$r" = 2 ] || st=1
  [ "$st" = 0 ] && [ ! -e "$M/.agents/team/batch-gate.json" ] && [ ! -e "$M/.agents/team/batch-hold.md" ] \
    && [ ! -e "$CH/ran" ]
  ok "writers refused from a team clone — run, hold, lift exit 2, main unchanged" $?
  bg "$C" -C "$M" due; [ "$RC" = 0 ] && has "batch due (here)"
  ok "writers refused from a team clone — -C <main> due still reports" $?
fi

# ==== group due ====================================================================================
if group due; then
  # 2. counted vs untested merges
  world d2; green "$M" here
  mrg "$M" "$T1" src/tested.sh; cmt "$M" "$T1" docs/readme.md; mrg "$M" "$T2" src/tested.sh
  cmt "$M" "$T2" docs/other.md; cmt "$M" "$T3" src/tested.sh
  bg "$M" due; st="$RC:$OUT"; bg "$M" due --format json; n=$(jout '.gates[0].numbers.counted')
  [ "$st" = "0:" ] && [ "$n" = 3 ]; ok "counted vs untested merges — 3 counted, 2 docs-only, not due" $?
  cmt "$M" "$T4" src/tested.sh; bg "$M" due
  printf '%s\n' "$OUT" | grep -q '^batch due (here): 4 merges since .* at [0-9a-f]\{7\}'
  ok "counted vs untested merges — the fourth makes it due" $?

  # 3. tested by basename and md full path
  world d3; green "$M" here
  cmt "$M" "$T1" lib/deep/tested.sh; bg "$M" due --format json; a=$(jout '.gates[0].numbers.counted')
  cmt "$M" "$T2" notes/tested.md; bg "$M" due --format json; b=$(jout '.gates[0].numbers.counted')
  cmt "$M" "$T3" docs/tested.md; bg "$M" due --format json; c=$(jout '.gates[0].numbers.counted')
  [ "$a:$b:$c" = "1:1:2" ]; ok "tested by basename and md full path ($a:$b:$c)" $?

  # 4. heavy merges
  world d4; green "$M" here
  cmt "$M" "$T1" .claude/hooks/x.sh; cmt "$M" "$T2" .claude/hooks/x.sh; bg "$M" due
  has "(2 heavy: hooks)"; ok "heavy merges — two hook merges are due, area named" $?
  world d4b; cmt "$M" "$T1" .claude/hooks/y.sh; green "$M" here
  mkdir -p "$M/docs"; git -C "$M" mv .claude/hooks/y.sh docs/y.sh
  GIT_AUTHOR_DATE="$T2" GIT_COMMITTER_DATE="$T2" gitc "$M" commit -q -m move
  bg "$M" due --format json; [ "$(jout '.gates[0].numbers.heavy')" = 1 ]
  ok "heavy merges — a move out of a heavy area counts by its old path" $?

  # 5. days rule
  world d5; green "$M" here; cmt "$M" 2026-06-29T12:00:00 src/tested.sh; bg "$M" due
  st=1; has "batch due (here): 1 merge since" && st=0
  world d5b; green "$M" here; cmt "$M" "$T2" src/tested.sh; bg "$M" due
  [ "$st" = 0 ] && [ -z "$OUT" ]; ok "days rule — yesterday's counted merge is due, today's is not" $?

  # 6. never recorded and non-ancestor baseline
  world d6; bg "$M" due; st=1; has "batch due (here): no green baseline" && st=0
  green "$M" here; git -C "$M" checkout -q -b aside; cmt "$M" "$T1" src/plain1.txt; X=$(hsha "$M")
  git -C "$M" checkout -q main
  jq --arg x "$X" '.gates.here.last_green.commit = $x' "$M/.agents/team/batch-gate.json" > "$T/r.json"
  mv "$T/r.json" "$M/.agents/team/batch-gate.json"
  bg "$M" due; [ "$st" = 0 ] && has "batch due (here): no green baseline"
  ok "never recorded and non-ancestor baseline — both due" $?

  # 7. red last run
  world d7; red "$M" here "$CH" smoke-1; r=$RC; bg "$M" due
  [ "$r" = 1 ] && printf '%s\n' "$OUT" | grep -q '^batch red (here) at [0-9a-f]\{7\}: smoke-1 — fix and rerun$'
  ok "red last run — reported red with its step" $?

  # 8. reached point docs-only is due
  world d8; green "$M" here; cmt "$M" "$T1" docs/a.md; A=$(git -C "$M" rev-parse --short=7 HEAD)
  cmt "$M" "$T2" docs/b.md; B=$(git -C "$M" rev-parse --short=7 HEAD)
  plan "$M" "date: $TODAY" "accepted: ${TODAY}T08:00:00Z by Operator" "## Tickets" "- 41 · alfa · 1 · merged here $A" \
    "- 42 · beta · 2 · merged here $B" "## Regression points" "- after 41 42 · gate here"
  bg "$M" due; has "batch due (here): 0 merges since" && has "point after 41 42 reached"
  ok "reached point docs-only is due" $?

  # 9. satisfied point stays satisfied
  green "$M" here; bg "$M" due; st="$OUT"; cmt "$M" "$T3" src/tested.sh; bg "$M" due
  [ -z "$st" ] && [ -z "$OUT" ]; ok "satisfied point stays satisfied — green, then one light merge" $?

  # 10. two-repo ticket one mark unreached
  world d10 starter; green "$M" here; green "$M" starter
  cmt "$M" "$T1" docs/a.md; A=$(git -C "$M" rev-parse --short=7 HEAD)
  plan "$M" "date: $TODAY" "## Tickets" "- 41 · alfa · 1 · merged here $A" "## Regression points" \
    "- after 41 · gate here starter"
  bg "$M" due; [ "$RC" = 0 ] && [ -z "$OUT" ]; ok "two-repo ticket one mark unreached — no gate due" $?

  # 11. A-here B-both point
  world d11 starter; green "$M" here; green "$M" starter
  cmt "$M" "$T1" docs/a.md; A=$(git -C "$M" rev-parse --short=7 HEAD)
  cmt "$M" "$T2" docs/b.md; B=$(git -C "$M" rev-parse --short=7 HEAD)
  cmt "$S" "$T2" docs/b.md; BS=$(git -C "$S" rev-parse --short=7 HEAD)
  plan "$M" "date: $TODAY" "## Tickets" "- 51 · alfa · 1 · lands here · merged here $A" "- 52 · beta · 2 · merged here $B" \
    "## Regression points" "- after 51 52 · gate here starter"
  bg "$M" due; st="$OUT"
  plan "$M" "date: $TODAY" "## Tickets" "- 51 · alfa · 1 · lands here · merged here $A" \
    "- 52 · beta · 2 · merged here $B · merged starter $BS" "## Regression points" "- after 51 52 · gate here starter"
  bg "$M" due; both="$OUT"
  green "$M" starter; bg "$M" due
  [ -z "$st" ] && printf '%s\n' "$both" | grep -q '^batch due (here):' && printf '%s\n' "$both" | grep -q '^batch due (starter):' \
    && has "batch due (here):" && ! has "batch due (starter):"
  ok "A-here B-both point — due for both, starter satisfied by its own merge" $?

  # 12. marks before accepted survive
  world d12; green "$M" here; cmt "$M" "$T1" docs/a.md; A=$(git -C "$M" rev-parse --short=7 HEAD)
  plan "$M" "date: $TODAY" "## Tickets" "- 41 · alfa · 1 · merged here $A" "## Regression points" "- after 41 · gate here"
  bg "$M" due; st="$OUT"
  plan "$M" "date: $TODAY" "accepted: ${TODAY}T09:30:00Z by Operator" "## Tickets" "- 41 · alfa · 1 · merged here $A" \
    "## Regression points" "- after 41 · gate here"
  bg "$M" due
  printf '%s\n' "$st" | grep -q 'point after 41 reached' && has 'point after 41 reached'
  ok "marks before accepted survive — the point stays reached" $?

  # 13. held overnight carried then lifted stays due
  world d13; green "$M" here; cmt "$M" 2026-06-29T10:00:00 docs/a.md; A=$(git -C "$M" rev-parse --short=7 HEAD)
  plan "$M" "date: 2026-06-29" "## Tickets" "- 41 · alfa · 1 · merged here $A" "## Regression points" "- after 41 · gate here"
  BTODAY=2026-06-29 bg "$M" due; d1="$OUT"
  bg "$M" hold --text "not tonight"; bg "$M" due; d2="$OUT"
  plan "$M" "date: $TODAY" "## Tickets" "- 41 · alfa · 1 · merged here $A" "## Regression points" "- after 41 · gate here"
  bg "$M" due; d3="$OUT"; bg "$M" lift --text "go"; bg "$M" due
  printf '%s' "$d1" | grep -q 'point after 41 reached' && printf '%s' "$d2" | grep -q 'held by the Operator' \
    && printf '%s' "$d3" | grep -q 'held by the Operator' && has 'point after 41 reached' && ! has 'held'
  ok "held overnight carried then lifted stays due" $?

  # 17. lock held by another gate owner
  world d17; fake_lock "merge-check alfa"; bg "$M" due; st=1; has "· machine busy (" && st=0; fake_unlock
  fake_lock "batch-gate here"; bg "$M" due; [ "$st" = 0 ] && [ "$RC" = 0 ] && [ -z "$OUT" ]; r=$?; fake_unlock
  ok "lock held by another gate owner — machine busy; its own batch run prints nothing" $r

  # 18. line behind merged
  world d18; green "$M" here; git -C "$M" checkout -q -b aside; cmt "$M" "$T1" src/plain2.txt; X=$(hsha "$M")
  git -C "$M" checkout -q main
  bg "$M" due --merged "here=$X"; a="$OUT"
  bg "$M" due --merged "here=0123456789abcdef0123456789abcdef01234567"; b="$OUT"
  bg "$M" due --merged "starter=$X"; c="$RC:$OUT"
  printf '%s' "$a" | grep -q "line behind ${X:0:7} — update" && printf '%s' "$b" | grep -q "line behind 0123456 — update" \
    && ! printf '%s' "$a" | grep -q merges && [ "$c" = "0:" ]
  ok "line behind merged — unknown and off-line shas are behind, an unknown gate is ignored" $?

  # 27. recommendation
  world d27; C="$W/main-beta"; mkdir -p "$C/.agents/team/lock"; sleep 120 & P=$!; BGPIDS+=("$P")
  echo "$P" > "$C/.agents/team/lock/pid"; echo '{"team":"beta","ticket":"42"}' > "$C/.agents/team/team.json"
  plan "$M" "date: $TODAY" "## Tickets" "- 41 · alfa · 1" "- 42 · beta · 2" "## Regression points" "- after 41 42 · gate here"
  bg "$M" due; st=1; printf '%s\n' "$OUT" | grep -q '· beta running 42, planned before this point — run after its merge$' && st=0
  kill "$P"; wait "$P" 2>/dev/null; bg "$M" due
  [ "$st" = 0 ] && printf '%s\n' "$OUT" | grep -q '· machine free — run now$'
  ok "recommendation — a running team planned before the point, else machine free" $?

  # 28. formats
  world d28; green "$M" here; for x in 1 2 3 4; do cmt "$M" "$T2" src/tested.sh; done
  bg "$M" due --format prime; st=1
  case "$OUT" in "BATCH_DUE${TAB}here${TAB}due${TAB}-${TAB}batch due (here): 4 merges since"*) st=0 ;; esac
  bg "$M" due --format json
  [ "$st" = 0 ] && [ "$(jout '.schema')" = 1 ] && [ "$(jout '.gates[0].numbers.counted')" = 4 ] \
    && [ "$(jout '.gates[0].state')" = due ]
  ok "formats — prime rows and json" $?

  # 29. bounded scan
  world d29; {
    printf 'commit refs/heads/main\nmark :1\ncommitter t <t@t> 1780000000 +0000\ndata 2\nc\nfrom %s\nM 100644 inline src/many.txt\ndata 2\n0\n' "$(hsha "$M")"
    for x in $(seq 2 400); do
      printf 'commit refs/heads/main\nmark :%s\ncommitter t <t@t> %s +0000\ndata 2\nc\nfrom :%s\nM 100644 inline .claude/hooks/h.sh\ndata %s\n%s\n' \
        "$x" "$((1780000000 + x))" "$((x - 1))" "$(( ${#x} + 1 ))" "$x"
    done; } | git -C "$M" fast-import --quiet
  git -C "$M" checkout -q -f main
  mkdir -p "$T/gitw"; RG=$(command -v git)
  printf '#!/bin/bash\nfor a in "$@"; do [ "$a" = grep ] && echo x >> "%s/grepcount"; done\nexec "%s" "$@"\n' "$T" "$RG" > "$T/gitw/git"
  chmod +x "$T/gitw/git"; rm -f "$T/grepcount"
  s0=$SECONDS; OUT=$(cd "$M" && PATH="$T/gitw:$PATH" BATCH_GATE_TODAY=$TODAY bash "$BG" due 2>/dev/null); s1=$SECONDS
  st=1; printf '%s' "$OUT" | grep -q 'no green baseline' && [ $((s1 - s0)) -le 2 ] && [ ! -e "$T/grepcount" ] && st=0
  red "$M" here "$CH" smoke-1; rm -f "$T/grepcount"
  OUT=$(cd "$M" && PATH="$T/gitw:$PATH" BATCH_GATE_TODAY=$TODAY bash "$BG" due 2>/dev/null)
  [ "$st" = 0 ] && printf '%s' "$OUT" | grep -q '^batch red (here)' && [ ! -e "$T/grepcount" ]
  ok "bounded scan — no baseline and red walk nothing (no git grep, under 2 s)" $?

  # 36. merged into another base ignored
  world d36; green "$M" here; git -C "$M" checkout -q -b it-base; cmt "$M" "$T1" src/plain3.txt; X=$(hsha "$M")
  git -C "$M" checkout -q main
  bg "$M" due --merged "here=$X@it-base"; a="$RC:$OUT"; bg "$M" due --merged "here=$X@main"
  [ "$a" = "0:" ] && has "line behind ${X:0:7}"
  ok "merged into another base ignored — @it-base no line, @main behind" $?
fi

# ==== group run ====================================================================================
if group run; then
  # 19. inherited one-step selection records no green
  world r19; printf 'ok purity 1 checks 0s\n' > "$CH/out"
  OUT=$(cd "$M" && TEAM_SUITE_ONLY=purity BATCH_GATE_TODAY=$TODAY bash "$BG" run here 2>&1); r=$?
  [ "$r" = 1 ] && [ "$(jrec "$M" '.gates.here.last_run.result')" = red ] \
    && [ "$(jrec "$M" '.gates.here.last_run.missing_steps | join(" ")')" = "smoke-1 x-test" ] \
    && [ "$(jrec "$M" '.gates.here.last_green')" = null ] && grep -qx 'TEAM_SUITE_ONLY=' "$CH/seen-env"
  ok "inherited one-step selection records no green" $?

  # 20. browser skip green missing step red
  world r20; printf 'purity\nsmoke-1\nwcag-audit-browser-test\n' > "$CH/list"
  printf 'ok purity 1 checks 0s\nok smoke-1 2 checks 0s\nskip wcag-audit-browser-test — engine cache not installed (bash .claude/skills/wcag-audit/install.sh)\n' > "$CH/out"
  bg "$M" run here; a=$RC
  printf 'purity\nsmoke-1\nsession-profiles\n' > "$CH/list"
  printf 'ok purity 1 checks 0s\nok smoke-1 2 checks 0s\nskip session-profiles — .claude/lib/session_profile_check.py not present at this sha\n' > "$CH/out"
  bg "$M" run here
  [ "$a" = 0 ] && [ "$RC" = 1 ] && [ "$(jrec "$M" '.gates.here.last_run.missing_steps | join(" ")')" = session-profiles ]
  ok "browser skip green missing step red" $?

  # 21. unknown only name refused
  world r21; prof "$M" '{"line":"main","gates":{"here":{"repo":".","only":["purity","bogus"]}}}'
  bg "$M" run here; [ "$RC" = 2 ] && [ ! -e "$CH/ran" ] && printf '%s' "$ERR" | grep -q bogus
  ok "unknown only name refused — exit 2, nothing run" $?

  # 23. run refusals
  world r23; st=""
  echo x > "$M/untracked.txt"; bg "$M" run here; st="$RC"; rm "$M/untracked.txt"
  git -C "$M" checkout -q -b other; bg "$M" run here; st="$st:$RC"; git -C "$M" checkout -q main
  bg "$M" run here --expect-head 0123456789abcdef0123456789abcdef01234567; st="$st:$RC"
  [ "$st" = "3:3:3" ] && [ ! -e "$CH/ran" ]; ok "run refusals — dirty, off the line, moved head ($st)" $?
  touch "$CH/dirty"; bg "$M" run here; rm -f "$CH/dirty" "$M/dirtied-by-suite"
  [ "$RC" = 1 ] && [ ! -e "$M/.agents/team/batch-gate.json" ] && printf '%s%s' "$OUT" "$ERR" | grep -q 'proves nothing'
  ok "run refusals — a checkout dirtied during the run records nothing" $?

  # 24. green run record
  world r24; bg "$M" run here; H=$(hsha "$M")
  [ "$RC" = 0 ] && printf '%s\n' "$OUT" | grep -q "^batch green (here) at ${H:0:7}" \
    && [ "$(jrec "$M" '.gates.here.last_run.result')" = green ] && [ "$(jrec "$M" '.gates.here.last_green.commit')" = "$H" ] \
    && [ "$(jrec "$M" '.gates.here.last_green.secs | type')" = number ] && [ "$(jrec "$M" '.schema')" = 1 ]
  ok "green run record — last_run and last_green written" $?

  # 25. first-red import with last green none
  world r25; H7=$(git -C "$M" rev-parse --short=7 HEAD)
  plan "$M" "date: $TODAY" "## Batch runs" "- here · last green none · last run $H7 2026-06-29T09:40Z red smoke-roles"
  bg "$M" due; a="$OUT"
  bg "$M" run here; b=$RC
  plan "$M" "date: $TODAY" "## Batch runs" "- here · last green none · last run $H7 2026-06-29T09:40Z red smoke-x"
  bg "$M" due
  printf '%s' "$a" | grep -q "^batch red (here) at $H7: smoke-roles" && [ "$b" = 0 ] && [ -z "$OUT" ] \
    && [ "$(jrec "$M" '.gates.here.last_green.commit')" = "$(hsha "$M")" ] && [ "$(jrec "$M" '.gates.here.last_run.result')" = green ]
  st=$?
  world r25b; H7=$(git -C "$M" rev-parse --short=7 HEAD)
  plan "$M" "date: $TODAY" "## Batch runs" "- here · last green $H7 2026-06-29T09:40Z 9 min · last run $H7 2026-06-29T09:40Z green"
  for x in 1 2 3 4; do cmt "$M" "$T2" src/tested.sh; done
  bg "$M" due; e="$OUT"; [ ! -e "$M/.agents/team/batch-gate.json" ] || st=1
  red "$M" here "$CH" smoke-1
  [ "$st" = 0 ] && printf '%s' "$e" | grep -q '· ~9 min$' && [ "$(jrec "$M" '.gates.here.last_green.imported')" = true ] \
    && [ "$(jrec "$M" '.gates.here.last_run.result')" = red ]
  ok "first-red import with last green none — red read-only, then the record wins; estimate and imported green kept" $?

  # 30. suite nonzero exit after all ok is red
  world r30; green "$M" here; G1=$(jrec "$M" '.gates.here.last_green.commit')
  cmt "$M" "$T2" src/plain4.txt; echo 1 > "$CH/rc"; bg "$M" run here; rm -f "$CH/rc"
  [ "$RC" = 1 ] && [ "$(jrec "$M" '.gates.here.last_run.result')" = red ] && [ "$(jrec "$M" '.gates.here.last_green.commit')" = "$G1" ] \
    && [ "$(jrec "$M" '.gates.here.last_run.log')" = "$CH/suite.log" ]
  ok "suite nonzero exit after all ok is red" $?

  # 31. no smoke dispatcher refused
  world r31; printf 'purity\nx-test\n' > "$CH/list"; bg "$M" run here
  [ "$RC" = 2 ] && [ ! -e "$CH/ran" ] && [ ! -e "$M/.agents/team/batch-gate.json" ]
  ok "no smoke dispatcher refused" $?

  # 33. head moved in queue refused
  world r33; fake_lock "merge-check alfa"
  (cd "$M" && TEAM_GATE_LOCK_WAIT=30 BATCH_GATE_TODAY=$TODAY bash "$BG" run here > "$T/r33.out" 2>&1; echo $? > "$T/r33.rc") &
  P=$!; BGPIDS+=("$P"); i=0
  until [ -n "$(ls "$TEAM_GATE_LOCK_DIR/queue" 2>/dev/null)" ] || [ "$i" -ge 300 ]; do sleep 0.1; i=$((i + 1)); done
  cmt "$M" "$T2" src/plain5.txt; fake_unlock; wait "$P"
  [ "$(cat "$T/r33.rc")" = 3 ] && [ ! -e "$CH/ran" ] && [ ! -e "$M/.agents/team/batch-gate.json" ] && grep -q moved "$T/r33.out"
  ok "head moved in queue refused" $?

  # 39. groups selector does not reach the suite
  world r39
  OUT=$(cd "$M" && BATCH_GATE_TEST_GROUPS=frame BATCH_GATE_TODAY=$TODAY bash "$BG" run here 2>&1); r=$?
  [ "$r" = 0 ] && [ -s "$CH/seen-env" ] && ! grep -q '^BATCH_GATE_' "$CH/seen-env" && ! grep -q '^BATCH_GATE_' "$CH/list-env"
  ok "groups selector does not reach the suite" $?
fi

# ==== group hold ===================================================================================
if group hold; then
  # 14. hold blocks run and due reports words
  world h14; bg "$M" hold --text "no full suite until I say"; a=$RC; bg "$M" run here; b=$RC; bg "$M" due
  [ "$a" = 0 ] && [ "$b" = 3 ] && [ ! -e "$CH/ran" ] \
    && printf '%s\n' "$OUT" | grep -q '— held by the Operator since [0-9-]\{10\}: "no full suite until I say"$'
  ok "hold blocks run and due reports words" $?

  # 15. malformed hold counts as held
  world h15; HF="$M/.agents/team/batch-hold.md"; mkdir -p "$M/.agents/team"; st=0
  S1='state: held'; S2='since: 2026-06-30T08:00:00Z'; S3='by: Operator'; S4='words: wait'
  for v in "$S1|$S2|$S3" "$S1|$S1|$S2|$S3|$S4" "$S1|$S2|by: Supervisor|$S4" "state: lifted|$S2|$S3|words: " \
    "$S1|$S2|$S3|$S4|extra: x"; do
    printf '%s\n' "$v" | tr '|' '\n' > "$HF"; bg "$M" due; has "(hold file unreadable)" || { st=1; echo "  not held: $v"; }
  done
  printf '%s\n' "$S1" "$S2" "$S3" "$S4" > "$HF"; chmod 000 "$HF"; bg "$M" due; has "(hold file unreadable)" || st=1
  chmod 644 "$HF"; rm -f "$HF"; bg "$M" due; has "held" && st=1
  [ "$st" = 0 ]; ok "malformed hold counts as held — every bad shape, an unreadable file; absent is no hold" $?

  # 16. hold during lock queue stops run
  world h16; fake_lock "merge-check alfa"
  (cd "$M" && TEAM_GATE_LOCK_WAIT=30 BATCH_GATE_TODAY=$TODAY bash "$BG" run here > "$T/r16.out" 2>&1; echo $? > "$T/r16.rc") &
  P=$!; BGPIDS+=("$P"); i=0
  until [ -n "$(ls "$TEAM_GATE_LOCK_DIR/queue" 2>/dev/null)" ] || [ "$i" -ge 300 ]; do sleep 0.1; i=$((i + 1)); done
  bg "$M" hold --text "stop"; fake_unlock; wait "$P"
  [ "$(cat "$T/r16.rc")" = 3 ] && [ ! -e "$CH/ran" ] && grep -q held "$T/r16.out"
  ok "hold during lock queue stops run" $?

  # 37. red under hold
  world h37; red "$M" here "$CH" smoke-1; bg "$M" hold --text "keep it"; bg "$M" due; a="$OUT"
  bg "$M" due --format prime
  printf '%s' "$a" | grep -q '^batch red (here) at .*: smoke-1 — fix and rerun — held by the Operator since' \
    && case "$OUT" in "BATCH_DUE${TAB}here${TAB}red${TAB}held${TAB}"*) true ;; *) false ;; esac
  ok "red under hold — red steps kept, the hold named" $?

  # 38. lifted with a bad date is held
  world h38; mkdir -p "$M/.agents/team"
  printf 'state: lifted\nsince: 2026-02-30T25:00Z\nby: Operator\nwords: go\n' > "$M/.agents/team/batch-hold.md"
  bg "$M" due; a=1; has "(hold file unreadable)" && a=0; bg "$M" run here
  [ "$a" = 0 ] && [ "$RC" = 3 ] && [ ! -e "$CH/ran" ]; ok "lifted with a bad date is held" $?
fi

# ==== group release ================================================================================
if group release; then
  # 26. release checks
  world e26 starter; green "$M" here; green "$M" starter; SH=$(hsha "$S")
  bg "$M" due --release "$S=$SH"; a="$RC"; n=$(printf '%s\n' "$OUT" | grep -c '^release ok (')
  mkdir -p "$TEAM_GATE_LOCK_DIR/lock"; printf 'pid=1\n' > "$TEAM_GATE_LOCK_DIR/lock/holder"
  bg "$M" due --release "$S=$SH"; b="$RC"; rm -f "$TEAM_GATE_LOCK_DIR/lock/holder"; rmdir "$TEAM_GATE_LOCK_DIR/lock"
  red "$M" starter "$CS" purity; bg "$M" due --release "$S=$SH"; c="$RC"; green "$M" starter
  bg "$M" hold --text "no release yet"; bg "$M" due --release "$S=$SH"; d="$RC"
  printf 'state: lifted\nsince: 2026-02-30T25:00Z\nby: Operator\nwords: go\n' > "$M/.agents/team/batch-hold.md"
  bg "$M" due --release "$S=$SH"; e="$RC"; rm -f "$M/.agents/team/batch-hold.md"
  cmt "$M" "$T2" src/plain6.txt; bg "$M" due --release "$S=$SH"; f="$RC"
  prof "$M" -; bg "$M" due --release "$S=$SH"; g="$RC:$OUT"
  [ "$a:$n" = "0:2" ] && [ "$b:$c:$d:$e:$f" = "3:3:3:3:3" ] && [ "$g" = "0:" ]
  ok "release checks ($a:$n $b:$c:$d:$e:$f $g)" $?

  # 32. release preflight
  world e32 starter; green "$M" here; green "$M" starter; SH=$(hsha "$S")
  mkdir -p "$T/nojq32"; ln -s "$(command -v git)" "$T/nojq32/git"
  OUT=$(cd "$M" && PATH="$T/nojq32" /bin/bash "$BG" due --release "$S=$SH" 2>/dev/null); a="$?"
  cp "$M/.claude/project-profile.json" "$T/p32.json"; echo '{' > "$M/.claude/project-profile.json"
  bg "$M" due --release "$S=$SH"; b="$RC"; cp "$T/p32.json" "$M/.claude/project-profile.json"
  mkdir -p "$M/.agents/team"; echo '{}' > "$M/.agents/team/team.json"; bg "$M" due --release "$S=$SH"; c="$RC"
  rm "$M/.agents/team/team.json"
  O="$W/other"; mkrepo "$O" "$T/ctl/e32-o"; bg "$M" due --release "$O=$(hsha "$O")"; d="$RC"
  st=1; [ "$d" = 3 ] && has "release blocked ($O): no gate for this checkout" && st=0
  world e32b; H32="$T/h32"; mkdir -p "$H32"
  lk() { [ ! -e "$H32/.agent-ops/locks/test-gate/lock" ]; }
  OUT=$(cd "$M" && env -u TEAM_GATE_LOCK_DIR HOME="$H32" BATCH_GATE_TODAY=$TODAY bash "$BG" run here 2>&1); g1=$?; lk; l1=$?
  echo 1 > "$CH/rc"; OUT=$(cd "$M" && env -u TEAM_GATE_LOCK_DIR HOME="$H32" BATCH_GATE_TODAY=$TODAY bash "$BG" run here 2>&1); g2=$?; lk; l2=$?
  rm -f "$CH/rc" "$CH/ran"; echo 2 > "$CH/sleep"
  (cd "$M" && exec env -u TEAM_GATE_LOCK_DIR HOME="$H32" BATCH_GATE_TODAY=$TODAY bash "$BG" run here > /dev/null 2>&1) & P=$!
  i=0; until [ -e "$CH/ran" ] || [ "$i" -ge 300 ]; do sleep 0.1; i=$((i + 1)); done
  kill -TERM "$P" 2>/dev/null; wait "$P"; g3=$?; lk; l3=$?; rm -f "$CH/sleep"
  # The predicate of .claude/commands/release.md Step 5, verbatim.
  q() { jq -s -e 'length == 1 and (.[0] | type == "object") and ((.[0].teams // {}) | type == "object") and ((.[0].teams // {}) | has("batch_gate") | not)' "$1" >/dev/null 2>&1; echo $?; }
  echo '{"teams":{"trunk":"main"}}' > "$T/q1.json"; echo '{"teams":{"batch_gate":false}}' > "$T/q2.json"
  echo '{"teams":{"batch_gate":null}}' > "$T/q3.json"; printf '{}\n{}\n' > "$T/q4.json"
  qs="$(q "$T/q1.json")$(q "$T/q2.json")$(q "$T/q3.json")$(q "$T/q4.json")"
  [ "$a:$b:$c" = "3:3:3" ] && [ "$st" = 0 ] && [ "$g1:$g2:$g3:$l1:$l2:$l3" = "0:1:130:0:0:0" ] \
    && [ "${qs:0:1}" = 0 ] && [ "${qs:1:1}" != 0 ] && [ "${qs:2:1}" != 0 ] && [ "${qs:3:1}" != 0 ]
  ok "release preflight — no jq, bad profile, team clone, no gate; lock released under the caller's HOME; release.md predicate ($a:$b:$c $g1:$g2:$g3 $l1$l2$l3 $qs)" $?

  # 35. settings change voids green
  world e35 starter; green "$M" here; green "$M" starter; SH=$(hsha "$S")
  prof "$M" '{"line":"main","gates":{"here":{"repo":"."},"starter":{"repo":"../starter","only":["purity","x-test"]}}}'
  printf 'purity\nx-test\n' > "$CS/list"
  bg "$M" due; a=1; has "batch due (starter): gate settings changed since the last green" && a=0
  bg "$M" due --release "$S=$SH"; b=$RC
  printf 'ok purity 1 checks 0s\nFAIL x-test rc 1\n' > "$CS/out"; echo 1 > "$CS/rc"; bg "$M" run starter; rm -f "$CS/rc"
  bg "$M" due; c=1; has "batch red (starter) at ${SH:0:7}: x-test — fix and rerun" && c=0
  bg "$M" due --release "$S=$SH"
  [ "$a:$b:$c:$RC" = "0:3:0:3" ]; ok "settings change voids green — due and blocked until a run under the new settings is green" $?
fi

for g in $SEL; do
  case "$GROUPS_RUN" in *" $g "*) ;; *) echo "FAIL group $g is unknown"; fail=1; continue ;; esac
  eval "n=\${GC_$g:-0}"
  [ "$n" -gt 0 ] || { echo "FAIL group $g ran no case"; fail=1; }
done
[ "$fail" = 0 ] && echo "batch-gate-test: OK" || echo "batch-gate-test: FAIL"
exit "$fail"
