#!/usr/bin/env bash
# Auto-merge gate for Supervisor: release freeze, QA ready, merge-check VERDICT ok.
#
# Usage: bash .claude/lib/team-automerge-check.sh <team>                   (full gate, builds)
#        bash .claude/lib/team-automerge-check.sh <team> --recheck <PR id>  (cheap, before 5a)
#   e.g. bash .claude/lib/team-automerge-check.sh alfa && /pr-merge 8571 --auto alfa
#   Full: exit 0 `AUTOMERGE: yes — PR <id> source=<s> target=<t>`, 1 `AUTOMERGE: no — <reason>`.
#   Recheck: exit 0 `RECHECK: ok`, 1 `RECHECK: no — <freeze|moved tip|pr mismatch|no gate …>`.
#   Full on `stale merge`: one restart through TEAM_AUTOMERGE_RESTART (a project script taking the
#   PR id; default .claude/lib/ado-restart-merge.sh when present), then the merge check again;
#   no restart script → `no` with the manual step.
#   Full refuses `settings: …` on a .claude/**/*settings*.json change past allow-offline.
# Run from the main checkout. Never merges — /pr-merge <id> --auto <team> does, after --recheck.
set -euo pipefail

usage() { sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
[ $# = 1 ] || { [ $# = 3 ] && [ "$2" = --recheck ] && [[ "$3" =~ ^[0-9]+$ ]]; } || usage
TEAM="$1"
LIB="$(cd "$(dirname "$0")" && pwd)"
. "$LIB/team-lib.sh"
. "$LIB/team-modes.sh"
team_check_name "$TEAM" || exit 2
root="$(git rev-parse --show-toplevel)"
CLONE="$(team_clone_dir "$TEAM" "$root")"
TD="$CLONE/.agents/team"
FREEZE="$root/.agents/team/release-freeze"
STORE="$root/.agents/team/watch/automerge/$TEAM.json"
# Test seam (as TEAM_WATCH_SENDER): the merge check builds for minutes.
MERGE_CHECK="${TEAM_AUTOMERGE_MERGE_CHECK:-$root/.claude/lib/team-merge-check.sh}"
RESTART="${TEAM_AUTOMERGE_RESTART:-$LIB/ado-restart-merge.sh}"
SETTINGS_DIFF="$LIB/team_settings_diff.py"
RECALC_TRIES="${TEAM_AUTOMERGE_RECALC_TRIES:-12}"
RECALC_SLEEP="${TEAM_AUTOMERGE_RECALC_SLEEP:-10}"

no() { echo "AUTOMERGE: no — $*"; exit 1; }
[ -f "$TD/team.json" ] || no "no team clone at $CLONE"
RUN="$(cat "$TD/run" 2>/dev/null || true)"

freeze_reason() {
  [ -f "$FREEZE" ] || return 1
  jq -r '"release freeze \(.release // "?") (\(.by // "?"), \(.at // "?"))"' "$FREEZE" \
    2>/dev/null || echo "release freeze (unreadable $FREEZE)"
}

recheck() {
  local pr="$1" out src tgt branch line r
  if r="$(freeze_reason)"; then echo "RECHECK: no — freeze: $r"; exit 1; fi
  [ -f "$STORE" ] && [ "$(jq -r .run "$STORE")" = "$RUN" ] \
    || { echo "RECHECK: no — no gate result for run ${RUN:-none}"; exit 1; }
  [ "$(jq -r .pr_id "$STORE")" = "$pr" ] \
    || { echo "RECHECK: no — pr mismatch (gate passed PR $(jq -r .pr_id "$STORE"))"; exit 1; }
  branch="$(jq -r .branch "$TD/team.json")"; line="$(jq -r .line "$TD/team.json")"
  # The live remote tips, as team-merge-check.sh tips(): ADO's lastMerge* commits can lag.
  out="$(git -C "$CLONE" ls-remote origin "refs/heads/$branch" "refs/heads/$line")" \
    || { echo "RECHECK: no — moved tip (cannot read origin)"; exit 1; }
  src="$(awk -v r="refs/heads/$branch" '$2 == r {print $1}' <<<"$out")"
  tgt="$(awk -v r="refs/heads/$line" '$2 == r {print $1}' <<<"$out")"
  [ "$src" = "$(jq -r .source "$STORE")" ] && [ "$tgt" = "$(jq -r .target "$STORE")" ] \
    || { echo "RECHECK: no — moved tip (source ${src:-absent}, target ${tgt:-absent})"; exit 1; }
  echo "RECHECK: ok"
}

qa_ready() {  # → the PR id of the accepted QA (or cli) record; exits `no` otherwise
  local mode rec rep
  mode="$(team_mode "$TD/team.json")" || no "cannot read the mode of $TD/team.json"
  if [ "$mode" = cli ]; then
    rec="$(cd "$CLONE" && team_accepted_record "$RUN" cli)"
    [ -n "$rec" ] && [ "$(jq -r .verdict "$rec")" = done ] || no "no accepted cli record done"
  else
    rec="$(cd "$CLONE" && team_accepted_record "$RUN" qa)"
    [ -n "$rec" ] && [ "$(jq -r .verdict "$rec")" = done ] || no "no accepted qa record done"
    rep="$TD/runs/$RUN/qa-report-$(jq -r .attempt "$rec").md"
    [ -f "$rep" ] || no "qa report $(basename "$rep") missing"
    grep -Eqx 'Verdict: (ready|ready-with-warnings)' "$rep" \
      || no "QA $(grep -m1 '^Verdict: ' "$rep" || echo 'Verdict missing')"
    # Tests are not re-counted: team-validate.sh enforced failed <= baseline at acceptance.
    grep -Eq '^Gate final-build: passed( |$)' "$rep" \
      || no "QA $(grep -m1 '^Gate final-build: ' "$rep" || echo 'Gate final-build missing')"
  fi
  jq -r '.pr_id // empty' "$rec"
}

rc=0 out="" restarted=""
merge_check() { rc=0; out="$(cd "$root" && bash "$MERGE_CHECK" "$TEAM" 2>&1)" || rc=$?; }

restart_merge() {  # one PATCH per gate run; ADO may show the old merge for a while after it
  local i r
  [ -f "$RESTART" ] || no "merge-check: stale merge — restart the merge on PR $1, then rerun"
  r="$(bash "$RESTART" "$1" 2>&1)" \
    || no "merge-check: stale merge, restart merge refused: $(tail -n 1 <<<"$r")"
  for ((i = 0; i < RECALC_TRIES; i++)); do
    sleep "$RECALC_SLEEP"
    merge_check
    [ "$rc" = 3 ] && grep -Eq '^stale merge|not recalculated yet' <<<"$out" || return 0
  done
  restarted=" (after one restart merge)"
}

full() {
  local r pr v src tgt sl st
  if r="$(freeze_reason)"; then no "$r"; fi
  pr="$(qa_ready)" || { echo "$pr"; exit 1; }
  [[ "$pr" =~ ^[0-9]+$ ]] || no "the accepted record has no PR id"
  merge_check
  if [ "$rc" = 3 ] && grep -q '^stale merge' <<<"$out"; then restart_merge "$pr"; fi
  if [ "$rc" != 0 ]; then
    v="$(grep -m1 '^VERDICT:' <<<"$out" || grep -m1 -i 'error\|refus\|void\|stale\|not ' <<<"$out" \
      || tail -n 1 <<<"$out")"
    no "merge-check: $v$restarted"
  fi
  src="$(sed -n 's/^validated source=\([^ ]*\) target=.*/\1/p' <<<"$out" | tail -n 1)"
  tgt="$(sed -n 's/^validated source=[^ ]* target=\([^ ]*\)$/\1/p' <<<"$out" | tail -n 1)"
  [ -n "$src" ] && [ -n "$tgt" ] || no "merge-check printed no validated source/target"
  st=0; sl="$(python3 -I "$SETTINGS_DIFF" "$CLONE" "$root" "$tgt" "$src")" || st=$?
  [ "$st" = 0 ] || no "settings: ${sl:-settings check failed (exit $st)}"
  mkdir -p "$(dirname "$STORE")"
  jq -n --argjson pr "$pr" --arg s "$src" --arg t "$tgt" --arg run "$RUN" --arg at "$(team_utc)" \
    '{pr_id: $pr, source: $s, target: $t, run: $run, at: $at}' > "$STORE.tmp.$$"
  mv "$STORE.tmp.$$" "$STORE"
  echo "AUTOMERGE: yes — PR $pr source=$src target=$tgt"
  [ -z "$sl" ] || echo "$sl"
}

if [ $# = 3 ]; then recheck "$3"; else full; fi
