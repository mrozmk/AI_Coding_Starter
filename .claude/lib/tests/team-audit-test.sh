#!/usr/bin/env bash
# Offline test of the team run audit: auditor cases A–E, runner trap F, wrapper G–H.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/team-smoke-lib.sh"
smoke_init
AUD="$SRC/.claude/lib/team_audit.py"
CFG="$WORK/audit.json"
jq -n '{typical_minutes: {planner: 60, coder: 180, qa: 120, wrapup: 45, cli: 180},
  flags: {questions_min: 3, qa_rounds_min: 2},
  retro: {enabled: true, on_flag: true, sample_every_clean: 5, model: "sonnet",
    effort: "medium", max_minutes: 1}}' > "$CFG"

at() { date -u -r $(( $(date +%s) + $1 )) +%Y-%m-%dT%H:%M:%SZ; }
# A quick plan in a git repo, so the auditor can `git show <output_rev>:<plan>`.
PLANREPO="$WORK/planrepo"
git init --quiet "$PLANREPO"
plan_rev() {  # plan_rev <notes line> → sha of a commit holding .agents/plans/active/p.md
  mkdir -p "$PLANREPO/.agents/plans/active"
  printf '# Plan\n\n## NOTES\n\n%s\n' "$1" > "$PLANREPO/.agents/plans/active/p.md"
  git -C "$PLANREPO" add -A && git -C "$PLANREPO" commit --quiet --allow-empty -m plan
  git -C "$PLANREPO" rev-parse HEAD
}
CODEX_REV=$(plan_rev "- Codex (idea, high): clean")
NOCODEX_REV=$(plan_rev "- Phase 0: no hit")

rec() {  # rec <run dir> <role> <attempt> <seq> <verdict> <offset secs> [pr] [output_rev]
  jq -n --arg role "$2" --argjson a "$3" --argjson s "$4" --arg v "$5" --arg t "$(at "$6")" \
    --arg pr "${7:-}" --arg rev "${8:-x}" --arg run "$(basename "$1")" \
    '{team: "alfa", ticket: "AB-9", run: $run, role: $role, attempt: $a, seq: $s, verdict: $v,
      output_rev: $rev, pr_id: (if $pr == "" then null else ($pr | tonumber) end),
      artifacts: (if $role == "planner" then [".agents/plans/active/p.md"] else [] end),
      written_at: $t}' > "$1/$2-$3-$4.json"
  [ "$5" != done ] || touch "$1/$2-$3-$4.json.accepted"
  touch "$1/$2-$3.prompt.md"
}
qa_report() {  # qa_report <run dir> <attempt> [skip key]
  { echo "run: x"; echo "attempt: $2"; echo "output_rev: y"; echo "Verdict: ready"
    echo "Gate code: passed"; echo "Gate design: skipped — no UI"
    echo "Gate cross-model: passed"
    [ "${3:-}" = final-build ] || echo "Gate final-build: passed"
    echo "Tests: passed=5 failed=0 skipped=0 baseline=0"; echo "Warnings: none"
    echo "Rethink signals: none"; echo; echo "/check-implementation: 2 of 3 iterations."
  } > "$1/qa-report-$2.md"
}
team_dir() {  # team_dir <dir> <run> <mode>
  mkdir -p "$1/runs/$2"
  jq -n --arg m "$3" '{team: "alfa", ticket: "AB-9", branch: "chore/AB-9-x",
    line: "develop", base_sha: "b", mode: $m}' > "$1/team.json"
  echo "$2" > "$1/run"
}
clean_run() {  # clean_run <team dir> <run> [plan rev] — quick, four roles accepted
  local rd="$1/runs/$2"
  team_dir "$1" "$2" quick
  rec "$rd" planner 1 1 done 60 "" "${3:-$CODEX_REV}"
  rec "$rd" coder 1 1 done 120 8371; rec "$rd" qa 1 1 done 180; qa_report "$rd" 1
  rec "$rd" wrapup 1 1 done 240; echo "target_rev: y" > "$rd/wrapup-1.md"
}
audit() {  # audit <team dir> <run> <out> [extra...] — the retro decision cases run opted in
  local td="$1" r="$2" o="$3"; shift 3
  run "$WORK" python3 -I "$AUD" audit --team-dir "$td" --clone "$PLANREPO" --run "$r" --out "$o" \
    --config "$CFG" --roles "planner coder qa wrapup" --retro on "$@"
}
idx() { jq -s -r --arg r "$2" "map(select(.run == \$r)) | $3" "$1/index.jsonl"; }

# ---- A: a clean quick run, final ready -----------------------------------------------------------
O="$WORK/out-a"; clean_run "$WORK/td-a" alfa-20261020-100000
audit "$WORK/td-a" alfa-20261020-100000 "$O" --final ready --runner-exit 0
expect 0 "retro: no sample" "A clean final run"
J="$O/20261020-alfa-AB-9-alfa-20261020-100000.json"
jq -e '.state == "done" and .final == "ready" and (.flags | map(select(startswith("missing-")))
  | length == 0) and .steps.iterations == 2 and .steps."codex-plan-review" == "present"' "$J" \
  >/dev/null || fail "A: audit json $(jq -c '{state, final, flags, steps}' "$J")"
[ "$(wc -l < "$O/index.jsonl" | tr -d ' ')" = 1 ] || fail "A: index lines"
for k in "| team | alfa |" "| ticket | AB-9 |" "| run | alfa-20261020-100000 |" "| mode | quick |"; do
  has "$k" "${J%.json}.md" || fail "A: md header lacks $k"
done

# ---- B: quick plan without a Codex line, qa-report without Gate final-build -----------------------
O="$WORK/out-b"; clean_run "$WORK/td-b" alfa-20261020-110000 "$NOCODEX_REV"
qa_report "$WORK/td-b/runs/alfa-20261020-110000" 1 final-build
audit "$WORK/td-b" alfa-20261020-110000 "$O" --final ready
expect 0 "retro: due flags" "B flagged run"
# Off by default: the same flagged run without the project's opt-in never becomes due, even with
# an audit.json that says enabled.
O0="$WORK/out-b0"
run "$WORK" python3 -I "$AUD" audit --team-dir "$WORK/td-b" --clone "$PLANREPO" \
  --run alfa-20261020-110000 --out "$O0" --config "$CFG" --roles "planner coder qa wrapup" --final ready
expect 0 "retro: no disabled" "B flagged run without the opt-in"
F=$(idx "$O" alfa-20261020-110000 '.[0].flags | join(",")')
case ",$F," in *,missing-step:codex-plan-review,*missing-step:qa-report-keys,*) ;;
  *) fail "B: flags $F" ;; esac

# ---- C: a known shape — qa blocked, failed, done in one attempt ------------------------------------
O="$WORK/out-c"; TDC="$WORK/td-c"; R=alfa-20261021-090000; RD="$TDC/runs/$R"
team_dir "$TDC" "$R" quick
rec "$RD" planner 1 1 done 10 "" "$CODEX_REV"; rec "$RD" coder 1 1 done 20 8371
rec "$RD" qa 1 1 blocked 30; rec "$RD" qa 1 2 failed 40
audit "$TDC" "$R" "$O"
expect 0 "retro: no not-final" "C snapshot"
[ "$(idx "$O" "$R" '.[0].state')" = failed ] || fail "C: snapshot state"
rec "$RD" qa 1 3 done 50; qa_report "$RD" 1
rec "$RD" wrapup 1 1 done 60; echo "target_rev: y" > "$RD/wrapup-1.md"
audit "$TDC" "$R" "$O" --final ready
expect 0 "retro: due flags" "C final ready"
[ "$(idx "$O" "$R" '.[0].final')" = ready ] || fail "C: final"
idx "$O" "$R" '.[0].flags[]' | grep -qx 'qa-rounds:3' || fail "C: qa-rounds:3 flag"
audit "$TDC" "$R" "$O" --final archived
expect 0 "retro: no already-final" "C archive after ready"
[ "$(idx "$O" "$R" '.[0].final + " " + .[0].retro')" = "ready due flags" ] || fail "C: final kept"
[ "$(wc -l < "$O/index.jsonl" | tr -d ' ')" = 1 ] || fail "C: one index line"

# ---- D: missing run dir --------------------------------------------------------------------------
O="$WORK/out-d"; team_dir "$WORK/td-d" alfa-20261022-080000 brainstorm
audit "$WORK/td-d" alfa-20261022-999999 "$O"
expect 0 "retro: no no-run-dir" "D missing run dir"
[ "$(idx "$O" alfa-20261022-999999 '.[0].state')" = no-run-dir ] || fail "D: state"
idx "$O" alfa-20261022-999999 '.[0].info[0]' | grep -q 'run dir missing' || fail "D: info"

# ---- E: every 5th clean final run is sampled ----------------------------------------------------
O="$WORK/out-e"
for i in 1 2 3 4 5; do
  clean_run "$WORK/td-e$i" "alfa-20261023-00000$i"
  audit "$WORK/td-e$i" "alfa-20261023-00000$i" "$O" --final archived
  if [ "$i" = 5 ]; then expect 0 "retro: due sample" "E fifth"
  else expect 0 "retro: no sample" "E run $i"; fi
done

# ---- F: the runner trap keeps its exit code -----------------------------------------------------
smoke_team AB-790 feature/AB-790-x
RUN_ID=alfa-20261024-070000; RD="$TD/runs/$RUN_ID"; mkdir -p "$RD"; echo "$RUN_ID" > "$TD/run"
session planner 1 "$BASE"
mkrec planner "$BASE" blocked
cp "$MAIN/.claude/lib/team-audit.sh" "$WORK/team-audit.sh.real"
printf '#!/usr/bin/env bash\nexit 1\n' > "$MAIN/.claude/lib/team-audit.sh"
run "$MAIN" $TR alfa
expect 2 "warn: team audit failed" "F failing audit keeps blocked exit"
cp "$WORK/team-audit.sh.real" "$MAIN/.claude/lib/team-audit.sh"
cp "$AUD" "$MAIN/.claude/lib/"; cp "$CFG" "$MAIN/.claude/team/audit.json"
rm -f "$TD/acked"
run "$MAIN" $TR alfa
MAINP=$(cd "$MAIN" && pwd -P)
expect 2 "audit: $MAINP/.agents/team/audit/20261024-alfa-AB-790-$RUN_ID.md" "F real audit"
[ "$(jq -r .state "$MAIN/.agents/team/audit/20261024-alfa-AB-790-$RUN_ID.json")" = blocked ] \
  || fail "F: audit state"

# ---- G: a hung PR lookup is time-boxed ----------------------------------------------------------
rm -f "$TD/session.json" "$RD"/*.json*
mkrec planner "$BASE"; mkrec coder "$BASE"
pr_json true "$BASE"
start=$(date +%s)
STUB_AZ_SLEEP=30 TEAM_AUDIT_PR_SECS=1 run "$CLONE" bash "$MAIN/.claude/lib/team-audit.sh" alfa
expect 0 "audit: " "G hung az"
[ $(( $(date +%s) - start )) -lt 10 ] || fail "G: wrapper took $(( $(date +%s) - start ))s"
has "| title | - |" "$MAIN/.agents/team/audit/20261024-alfa-AB-790-$RUN_ID.md" || fail "G: title"
has "az repos pr show" "$STUB_LOG" || fail "G: no PR lookup"

# ---- H: the detached retro, report-only tools ---------------------------------------------------
cat > "$WORK/bin/tmux" <<'STUB'
#!/usr/bin/env bash
echo "tmux $*" >> "$STUB_LOG"
[ "$1" != has-session ] || exit 1
[ "$1" != new-session ] || bash -c "${@: -1}"
STUB
cat > "$WORK/bin/claude" <<'STUB'
#!/usr/bin/env bash
n=$(ls "$WORK"/claude-argv-* 2>/dev/null | wc -l | tr -d ' ')
printf '%s\n' "$@" > "$WORK/claude-argv-$n"
echo "## planner attempt 1"
STUB
chmod +x "$WORK/bin/tmux" "$WORK/bin/claude"
export WORK
mkdir -p "$MAIN/.claude/commands"; cp "$SRC/.claude/commands/retro.md" "$MAIN/.claude/commands/"
echo sid-planner > "$RD/planner-1.session"
pending_tool sid-planner t1 Read '{"file_path": "/x"}'
for r in qa wrapup; do mkrec "$r" "$BASE"; done
printf 'run: x\nattempt: 1\n' > "$RD/qa-report-1.md"
# The wrapper launches a retro only when the project opted in (profile teams.audit.retro: true).
cp "$MAIN/.claude/project-profile.json" "$WORK/prof-audit"
jq '.teams.audit = {retro: true}' "$WORK/prof-audit" > "$MAIN/.claude/project-profile.json"
run "$CLONE" bash "$MAIN/.claude/lib/team-audit.sh" alfa --runner-exit 0 --final ready
expect 0 "audit: " "H final flagged run"
B="$MAIN/.agents/team/audit/20261024-alfa-AB-790-$RUN_ID"
[ -s "$B.retro.md" ] || fail "H: no retro output"
jq -e '.retro | startswith("done")' "$B.json" >/dev/null || fail "H: json retro $(jq -r .retro "$B.json")"
[ "$(jq -s -r --arg r "$RUN_ID" 'map(select(.run == $r))[0].retro' "$MAIN/.agents/team/audit/index.jsonl" \
  | cut -d' ' -f1)" = done ] || fail "H: index retro"
A="$WORK/claude-argv-0"
for w in -p --permission-mode dontAsk --allowedTools --disallowedTools Write Edit Bash Agent \
  'mcp__*'; do
  grep -qxF -- "$w" "$A" || fail "H: claude argv lacks $w"
done
# Report-only: the tool flags grant nothing beyond Read Grep Glob.
TOOLS=$(sed '/^--$/q' "$A" | sed -n '/^--allowedTools$/,/^--disallowedTools$/p')
[ "$(printf '%s\n' "$TOOLS" | tr '\n' ' ')" = "--allowedTools Read Grep Glob --disallowedTools " ] \
  || fail "H: allowed tools $(printf '%s' "$TOOLS" | tr '\n' ' ')"
grep -qF "$(transcript sid-planner) — metrics: " "$A" || fail "H: prompt lacks the planner metrics"
M=$(grep -oE "metrics: [^ ]+/planner-1\.json" "$A" | head -n 1)
[ -n "$M" ] || fail "H: no metrics json for the planner transcript"
[ ! -e "${M#metrics: }" ] || fail "H: retro temp dir left behind"
# A second run's retro uses its own temp dir.
R2=alfa-20261024-080000; cp -R "$RD" "$TD/runs/$R2"; echo "$R2" > "$TD/run"
for f in "$TD/runs/$R2"/*.json; do jq --arg r "$R2" '.run = $r' "$f" > "$f.t" && mv "$f.t" "$f"; done
run "$CLONE" bash "$MAIN/.claude/lib/team-audit.sh" alfa --runner-exit 0 --final ready
expect 0 "audit: " "H second run"
grep -qF "/retro-$R2." "$WORK/claude-argv-1" || fail "H: second run temp dir"
grep -qF "/retro-$RUN_ID." "$WORK/claude-argv-1" && fail "H: runs share a temp dir"

# ---- I: a retro killed by a signal is failed, never done (pr_timebox keeps 128+n) ---------------
rc=0; ( . "$SRC/.claude/lib/team-lib.sh"; pr_timebox 5 bash -c 'kill -TERM $$' ) || rc=$?
[ "$rc" = 143 ] || fail "I: pr_timebox over a TERM-killed child exited $rc, expected 143"
rc=0; ( . "$SRC/.claude/lib/team-lib.sh"; pr_timebox 5 bash -c 'exit 3' ) || rc=$?
[ "$rc" = 3 ] || fail "I: pr_timebox lost a plain exit status ($rc)"
printf '#!/usr/bin/env bash\necho "## planner attempt 1"\nkill -TERM $$\n' > "$WORK/bin/claude"
R3=alfa-20261024-090000; cp -R "$RD" "$TD/runs/$R3"; echo "$R3" > "$TD/run"
for f in "$TD/runs/$R3"/*.json; do jq --arg r "$R3" '.run = $r' "$f" > "$f.t" && mv "$f.t" "$f"; done
run "$CLONE" bash "$MAIN/.claude/lib/team-audit.sh" alfa --runner-exit 0 --final ready
expect 0 "audit: " "I killed retro"
B3="$MAIN/.agents/team/audit/20261024-alfa-AB-790-$R3"
[ "$(jq -r .retro "$B3.json")" = "failed: rc 143" ] || fail "I: killed retro marked $(jq -r .retro "$B3.json")"

echo "team-audit-test: OK"
