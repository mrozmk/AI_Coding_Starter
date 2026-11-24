#!/usr/bin/env bash
# The per-run TeamLead's gate verdicts, written into the team clone for the runner to act on.
# Usage: bash .claude/lib/team-verdict.sh <gate> <verdict> --for <record> --message "<line>"
#          [--ref <file>] [--notify human_decision|abandon_decision] [--decision d-<n>]
#          [--quick-call continue]
#        bash .claude/lib/team-verdict.sh run close --for <acked record|asks/a-<n>.json>
#          --reason delivered-elsewhere|team-part-ended --message "<line>"
#        bash .claude/lib/team-verdict.sh event collision --ref <file> --message "<line>"
#        bash .claude/lib/team-verdict.sh wrapup decide --for <wrapup_proposals-<a>_<k>.json>
#          --ref .agents/team/runs/<run>/wrapup-decision-<n>.md --message "<line>"
#        bash .claude/lib/team-verdict.sh mode brainstorm|quick|cli --message "<reason>"
#   mode → once per run, when team.json says `lead`; no --for (team-lead.md → Mode choice).
#   gates: plan → approve|revise|escalate|remode (remode in quick only); there is no spec gate.
#   --for names the planner's newest record, a done. revise needs --ref (the findings) and is capped per gate by teams.teamlead.revise_limit;
#   --decision names an answered decision with answer_outcome more-revise that grants one more round.
#   acceptance → accept|rework|abandon-recommended on the qa's newest done record (rework: done or
#   blocked) of the current round; round files live in runs/<run>/ (round 1) or runs/<run>/r<n>/.
#   accept needs the round's blind-check.md, then acceptance-brief.md (six headings; for a QA verdict
#   ready-with-warnings one `- <warning> → keep|fix|follow-up — <why>` line per warning; a lead with
#   teamlead.json ask_operator adds `## Decided by the TeamLead`, one `- a-<n> …` line per answer of
#   authority teamlead whose why starts `verification-only:`);
#   rework needs --ref runs/<run>/rework-<next round>.md and is capped by
#   teams.teamlead.rework_budget.<mode> plus consumed Operator continue grants (quick: the first
#   rework needs --quick-call continue); abandon-recommended needs --decision d-<n>, pending, opened
#   with --notify abandon_decision.
#   decision → escalate|continue|close|resolved: --for is any file under runs/<run>/ (a record, a
#   verdict, asks/a-<n>.json) or attention:<line>; escalate needs --ref <the decision file>;
#   continue/close need --decision d-<n> answered with that answer_outcome; resolved closes a
#   decision without changing the run. A used decision becomes status: consumed (once).
#   wrapup → decide: --for is the proposals file the wrapup's newest record (blocked, proposals)
#   names; --ref the lead's decision file, checked by team_wrapup.py (every item accept|decline once,
#   accept `needed because`, one optional correction line, the run's cap, a group B opinion). Once
#   per proposals file; the items and the file's sha256 land in the verdict, the items also under
#   `## Wrapup decisions` in the notes.
#   run → close --reason delivered-elsewhere|team-part-ended: --for the acked record or a live ask
#   (asks/a-<n>.json) of the current stage (role, attempt, round). Refused (4) when the close would
#   lose unmerged work (team_close_safe: a coder record or a PR of the run, a dirty tree, a commit
#   beyond base_sha touching anything but .agents/specs/** and .agents/plans/**) — open a decision.
#   The runner re-checks, pushes the branch and closes the run.
#   Writes .agents/team/runs/<run>/teamlead-<gate>-<seq>.json.
#   Tracker comments (opt-in workflow.tracker_comments, tracker not none): plan approve and
#   acceptance accept need the planner's ledger + snapshot and the lead's fresh read
#   runs/<run>/tracker-<gate>-<n>.json (acceptance: in the round's dir) — team-tracker-gate.sh.
#   An uncertain read (compare exit 4) passes only with --decision d-<n> answered approve whose
#   source is that fresh read (opened after it); confirmed changes in it keep their exit-3
#   handling; the decision is consumed.
#   e.g. bash .claude/lib/team-verdict.sh plan revise --for planner-1-2.json \
#          --ref .agents/team/runs/alfa-20261114-100000/gate-plan-1.md --message "2 findings"
# Exit: 0 written · 2 usage · 3 not the lead · 4 bad gate/verdict/for · 5 revise limit
#       7 constraint digest missing (team-lead.sh digest-check)
#       8 acceptance brief incomplete · 9 rework budget reached · 10 tracker comments not current.
#   Contract: .agents/reference/team-lead.md §4, §5, §8, §9, §11
set -euo pipefail

usage() { sed -n '2,52p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }
[ $# -ge 2 ] || usage
GATE="$1"; VERDICT="$2"; shift 2
FOR=""; FOR_RAW=""; REF=""; NOTIFY=""; MESSAGE=""; DECISION=""; QUICK_CALL=""; REASON=""
while [ $# -gt 0 ]; do
  [ $# -ge 2 ] || usage
  case "$1" in
    --for) FOR="$(basename "$2")"; FOR_RAW="$2" ;; --ref) REF="$2" ;; --notify) NOTIFY="$2" ;;
    --message) MESSAGE="$2" ;; --decision) DECISION="$2" ;; --quick-call) QUICK_CALL="$2" ;;
    --reason) REASON="$2" ;;
    *) usage ;;
  esac
  shift 2
done
[ -n "$MESSAGE" ] || { echo "error: --message is required" >&2; exit 2; }
case "$MESSAGE" in *$'\n'*) echo "error: --message must be one line" >&2; exit 2 ;; esac
case "$NOTIFY" in ""|human_decision|abandon_decision) ;;
  *) echo "error: --notify must be human_decision or abandon_decision" >&2; exit 2 ;; esac

LIB="$(cd "$(dirname "$0")" && pwd)"
. "$LIB/team-lib.sh"
. "$LIB/team-lead-lib.sh"
. "$LIB/team-modes.sh"

team_lead_caller || { echo "error: only this run's TeamLead writes verdicts" >&2; exit 3; }
TD="$(team_dir)"; RUN="$(cat "$TD/run")"; RD="$TD/runs/$RUN"; MAIN="$(team_lead_json main_root)"
# The current rework round's record dir (team-lead.md §9): runs/<run> in round 1, runs/<run>/r<n> after.
RREF="$(team_run_ref "$TD" "$RUN")"; RRD="$TD/runs/$RREF"
TEAM="$(team_json team)"; TICKET="$(team_json ticket)"; MODE="$(jq -r '.mode // "brainstorm"' "$TD/team.json")"
bad() { echo "error: $1" >&2; exit 4; }
rec() { jq -r --arg f "$2" '.[$f] // empty | if type == "array" then join(",") else . end' "$1"; }

fm() { sed -n '/^---$/,/^---$/p' "$1" | sed -n "s/^$2: *//p" | head -n 1; }
fm_set() {  # fm_set <file> <key> <value> — replace or add one frontmatter key, atomically
  FM_K="$2" FM_V="$3" awk '/^---$/ { n++; if (n == 2 && !done) print ENVIRON["FM_K"] ": " ENVIRON["FM_V"]; print; next }
    n == 1 && index($0, ENVIRON["FM_K"] ": ") == 1 { print ENVIRON["FM_K"] ": " ENVIRON["FM_V"]; done = 1; next } { print }' "$1" > "$1.tmp"
  mv "$1.tmp" "$1"
}
TRACKER_LINE=""
verdicts() { ls "$RD" 2>/dev/null | grep -E "^teamlead-$GATE-[0-9]+\.json\$" | sort -t- -k3,3n || true; }
write_verdict() {  # → prints the written file
  local seq=1 n target tmp
  n="$(verdicts | tail -n 1)"; [ -z "$n" ] || { n="${n#teamlead-"$GATE"-}"; seq=$((${n%.json} + 1)); }
  target="$RD/teamlead-$GATE-$seq.json"; tmp="$RD/.teamlead-$GATE-$seq.json.tmp"
  [ ! -e "$target" ] || { echo "error: $target already exists" >&2; exit 1; }
  jq -n --arg team "$TEAM" --arg ticket "$TICKET" --arg run "$RUN" --arg gate "$GATE" \
    --argjson seq "$seq" --arg for "$FOR" --arg verdict "$VERDICT" --arg ref "$REF" \
    --arg notify "$NOTIFY" --arg message "$MESSAGE" \
    --arg decision "$DECISION" --arg written_at "$(team_utc)" \
    --arg session_id "$(team_lead_json session_id)" --arg quick_call "$QUICK_CALL" \
    --arg tracker "$TRACKER_LINE" --argjson items "${ITEMS:-null}" --arg psha "${PROPOSALS_SHA:-}" \
    --arg reason "$REASON" \
    '{team: $team, ticket: $ticket, run: $run, gate: $gate, seq: $seq, for: $for, verdict: $verdict,
      ref: $ref, notify: $notify, message: $message,
      decision: $decision, written_at: $written_at, session_id: $session_id}
     + (if $quick_call == "" then {} else {quick_call: $quick_call} end)
     + (if $tracker == "" then {} else {tracker: $tracker} end)
     + (if $items == null then {} else {items: $items} end)
     + (if $psha == "" then {} else {proposals_sha256: $psha} end)
     + (if $reason == "" then {} else {reason: $reason} end)' > "$tmp"
  [ ! -e "$target" ] || { rm -f "$tmp"; echo "error: $target already exists" >&2; exit 1; }
  mv "$tmp" "$target"
  echo "$target"
}
# decision_file <d-n> → its path, or refuses
decision_file() {
  [[ "$1" =~ ^d-[0-9]+$ ]] && [ -f "$RD/decisions/$1.md" ] || bad "--decision $1: no runs/$RUN/decisions/$1.md"
  echo "$RD/decisions/$1.md"
}

if [ "$GATE" = event ]; then
  [ "$VERDICT" = collision ] && [ -n "$REF" ] || usage
  exec bash "$MAIN/.claude/lib/team-inbox.sh" --main "$MAIN" write Supervisor collision \
    --from "$TEAM" --ticket "$TICKET" --run "$RUN" --ref "$REF" --message "$MESSAGE"
fi

# A human decision's gate: no stage record to be the newest of; the decision file carries the state.
if [ "$GATE" = decision ]; then
  case "$VERDICT" in escalate|continue|close|resolved) ;;
    *) bad "verdict $VERDICT is not allowed at the decision gate" ;; esac
  case "$FOR_RAW" in
    attention:*) [[ "$FOR_RAW" =~ ^attention:[1-9][0-9]*$ ]] || bad "--for attention:<line number>"
      FOR="$FOR_RAW" ;;
    *) FOR="${FOR_RAW#"$RD"/}"; FOR="${FOR#.agents/team/runs/"$RUN"/}"
       case "$FOR" in ""|/*|*..*) bad "--for must be a file under runs/$RUN/ or attention:<n>" ;; esac
       # In a rework round a bare record name is the current round's record.
       case "$FOR" in */*) ;; *) [ "$RREF" = "$RUN" ] || [ ! -f "$RRD/$FOR" ] || FOR="${RREF#"$RUN"/}/$FOR" ;; esac
       [ -f "$RD/$FOR" ] || bad "--for $FOR is not a file under runs/$RUN/" ;;
  esac
  if [ "$VERDICT" = escalate ]; then
    [ -n "$REF" ] && [ -f "$REF" ] || bad "escalate needs --ref <the decision file>"
  else
    [ -n "$DECISION" ] || bad "$VERDICT needs --decision d-<n>"
    df="$(decision_file "$DECISION")"
    # The status check, the verdict and the decision rewrite under the run's ask lock, which every
    # decision writer takes (team-lead-decision.sh, the runner's withdrawal).
    . "$LIB/team-ask.sh"
    { ask_init "$TD" && ask_lock; } || bad "cannot take the ask lock of run $RUN"
    trap ask_unlock EXIT
    case "$VERDICT:$(fm "$df" status)" in
      resolved:pending|resolved:answered) ;;
      resolved:*) bad "$DECISION is $(fm "$df" status) — nothing to resolve" ;;
      *:answered) [ "$(fm "$df" answer_outcome)" = "$VERDICT" ] \
          || bad "$DECISION was answered with outcome $(fm "$df" answer_outcome), not $VERDICT" ;;
      *) bad "$DECISION is $(fm "$df" status), not answered (a control verdict uses it once)" ;;
    esac
  fi
  t="$(write_verdict)"
  if [ -n "$DECISION" ]; then
    if [ "$VERDICT" = resolved ]; then fm_set "$df" status resolved
    else fm_set "$df" status consumed; fi
    fm_set "$df" consumed_by "$(basename "$t")"
  fi
  echo "$t"; exit 0
fi

# The wrapup's proposals: decided once, by the lead alone (no Operator path), from its decision file.
if [ "$GATE" = wrapup ]; then
  [ "$VERDICT" = decide ] || bad "verdict $VERDICT is not allowed at the wrapup gate (decide)"
  [ -f "$TD/session.json" ] && [ "$(session_json role)" = wrapup ] || bad "no wrapup session"
  last="$(team_records "$RREF" wrapup "$(session_json attempt)" | tail -n 1)"
  [ -n "$last" ] && [ "$(rec "$last" verdict)" = blocked ] && [ -n "$(rec "$last" proposals)" ] \
    || bad "the wrapup's newest record is no proposals stop"
  prop="$(rec "$last" proposals)"
  [ "$FOR" = "$(basename "$prop")" ] || bad "--for $FOR is not $(basename "$prop"), the proposals the wrapup's stop names"
  FOR="${prop#.agents/team/runs/"$RUN"/}"
  # Compared by resolved directory: the lead may pass a relative, absolute or /private path.
  r="$(cd "$(dirname "$REF")" 2>/dev/null && pwd -P)" || bad "--ref must be .agents/team/runs/$RUN/wrapup-decision-<n>.md"
  r="${r#"$(cd "$RD" && pwd -P)"}"; r="${r#/}"; r="${r:+$r/}$(basename "$REF")"
  [[ "$r" =~ ^(r[0-9]+/)?wrapup-decision-[0-9]+\.md$ ]] && [ -f "$RD/$r" ] \
    || bad "--ref must be .agents/team/runs/$RUN/wrapup-decision-<n>.md"
  REF=".agents/team/runs/$RUN/$r"
  for f in $(verdicts); do [ "$(rec "$RD/$f" for)" != "$FOR" ] || bad "$FOR is already decided ($f)"; done
  # The cap and the one-standards-item limit count the whole run: accepts of earlier proposals files,
  # hand-offs aside (tickets, memory entries, standards items).
  prior="$(for f in $(verdicts); do cat "$RD/$f"; done | jq -rs '[.[].items // [] | .[]
    | select(.decision == "accept" and (.handoff | not))] as $a
    | "\([$a[] | select(.kind == "ticket")] | length),\([$a[] | select(.kind == "memory")] | length)"
      + ",\([$a[] | select(.kind == "memory" and .target == "docs/coding-standards.md")] | length)"')"
  # The lead decides the bytes the wrapup's stop named: the file must not move before or during decide.
  stop_sha="$(rec "$last" proposals_sha256)"
  PROPOSALS_SHA="$(shasum -a 256 "$TD/runs/$RUN/$FOR" | cut -d' ' -f1)"
  [ -z "$stop_sha" ] || [ "$PROPOSALS_SHA" = "$stop_sha" ] \
    || bad "$FOR changed since the wrapup's stop — the wrapup writes a new proposals file and stops again"
  ITEMS="$(python3 -I "$LIB/team_wrapup.py" decide "$TD/runs/$RUN/$FOR" "$RD/$r" "${prior:-0,0,0}" "$RD" "$RRD")" || exit 4
  [ "$(shasum -a 256 "$TD/runs/$RUN/$FOR" | cut -d' ' -f1)" = "$PROPOSALS_SHA" ] \
    || bad "$FOR changed since the wrapup's stop — the wrapup writes a new proposals file and stops again"
  t="$(write_verdict)"
  n="$RD/teamlead-notes.md"
  lines="$(jq -r '.[] | "- \(.id) \(.decision) — \(.why)" + (if .over_cap then " — over cap because \(.over_cap)" else "" end)
    + (if .correction then " (correction: \(.correction))" else "" end)' <<<"$ITEMS")"
  if [ -f "$n" ] && grep -qxF '## Wrapup decisions' "$n"; then
    ADD="$lines" awk '/^## / && f { print ENVIRON["ADD"]; f = 0 } { print }
      $0 == "## Wrapup decisions" { f = 1 } END { if (f) print ENVIRON["ADD"] }' "$n" > "$n.tmp" \
      && mv "$n.tmp" "$n"
  else
    printf '\n## Wrapup decisions\n%s\n' "$lines" >> "$n"
  fi
  echo "$t"; exit 0
fi

# The run's mode, chosen once by the lead when the Operator gave none; the runner applies it.
if [ "$GATE" = mode ]; then
  team_mode_valid "$VERDICT" || bad "verdict $VERDICT is not a mode (brainstorm|quick|cli)"
  [ "$MODE" = lead ] || bad "mode fixed by the Operator ($MODE) — no choice to make"
  [ -z "$(verdicts)" ] || bad "mode already chosen ($(verdicts | head -n 1))"
  FOR=""; write_verdict; exit 0
fi

# A run with nothing left to lose: the lead closes it (work delivered elsewhere, or the plan ends
# the team's part). Anything that could lose unmerged work stays the Operator's decision close.
if [ "$GATE" = run ]; then
  [ "$VERDICT" = close ] || bad "verdict $VERDICT is not allowed at the run gate (close)"
  case "$REASON" in delivered-elsewhere|team-part-ended) ;;
    *) bad "close needs --reason delivered-elsewhere|team-part-ended" ;; esac
  [ -f "$TD/session.json" ] || bad "no stage session to close on"
  FOR="${FOR_RAW#"$RD"/}"; FOR="${FOR#.agents/team/runs/"$RUN"/}"
  case "$FOR" in ""|/*|*..*) bad "--for must be the acked record or asks/a-<n>.json under runs/$RUN/" ;; esac
  case "$FOR" in
    asks/a-*.json)
      [ -f "$RD/$FOR" ] || bad "--for $FOR is not an ask of runs/$RUN/"
      [ "$(rec "$RD/$FOR" role)" = "$(session_json role)" ] \
        && [ "$(rec "$RD/$FOR" attempt)" = "$(session_json attempt)" ] \
        && [ "$(rec "$RD/$FOR" round)" = "$(jq -r '.round // 1' "$TD/session.json")" ] \
        || bad "$FOR is not an ask of the current stage"
      case "$(rec "$RD/$FOR" state)" in delivered|withdrawn) bad "$FOR is $(rec "$RD/$FOR" state), not open" ;; esac ;;
    *)
      [ "$FOR" = "$(cat "$TD/acked" 2>/dev/null)" ] && [ -f "$RD/$FOR" ] \
        || bad "--for $FOR is not the acked record ($(cat "$TD/acked" 2>/dev/null || echo none))" ;;
  esac
  why="$(team_close_safe "$(team_root)" "$(team_json base_sha)" "$RUN" "$RREF" 2>&1)" \
    || bad "close would lose unmerged work — open a decision ($why)"
  write_verdict; exit 0
fi

# The gated record: the gated role's newest record of the launched attempt, in the gate's verdict.
case "$GATE" in
  # Sentinel: team-run-lead.sh lead_start greps a clone's copy of this file for the spec) refusal
  # text to tell a plan-gate-only base from an older one — keep its wording verbatim.
  spec) bad "no spec gate: the first gate is the plan gate" ;;
  plan) role=planner; want=done ;;
  acceptance) role=qa; want=done ;;
  *) bad "unknown gate $GATE (plan|acceptance|decision|wrapup|run|mode)" ;;
esac
[ -f "$TD/session.json" ] && [ "$(session_json role)" = "$role" ] \
  || bad "no $role session — the $GATE gate is the $role's"
last="$(team_records "$RREF" "$role" "$(session_json attempt)" | tail -n 1)"
[ -n "$FOR" ] && [ -n "$last" ] && [ "$FOR" = "$(basename "$last")" ] \
  || bad "--for ${FOR:-<none>} is not the newest $role record (${last:+$(basename "$last")})"
[ "$(rec "$last" verdict)" = "$want" ] || [ "$GATE $VERDICT $(rec "$last" verdict)" = "acceptance rework blocked" ] \
  || bad "$FOR is $(rec "$last" verdict), the $GATE gate needs $want"
# The verdict names the record relative to runs/<run>/ (r<n>/qa-1-1.json in a rework round), as the
# runner's acked file does.
FOR="${last#"$RD"/}"

case "$GATE $VERDICT" in
  "plan approve"|"plan revise"|"plan escalate") ;;
  "plan remode") [ "$MODE" = quick ] || bad "remode is for quick mode only" ;;
  "acceptance accept"|"acceptance rework"|"acceptance abandon-recommended") ;;
  *) bad "verdict $VERDICT is not allowed at the $GATE gate" ;;
esac
[ "$VERDICT" != revise ] || [ -n "$REF" ] || bad "revise needs --ref <findings file>"
[ -z "$QUICK_CALL" ] || [ "$GATE $VERDICT" = "acceptance rework" ] || bad "--quick-call is for acceptance rework only"

# Acceptance: the blind order-vs-diff check comes first, the brief is written from it.
acc_fail() { echo "error: acceptance: $1" >&2; exit 8; }
if [ "$GATE $VERDICT" = "acceptance accept" ]; then
  # A run that does not end in a wrapup (quick on the current contract) has nobody to carry a
  # follow-up ticket: neither a warning nor cut ordered work may be routed `→ follow-up`.
  NO_WRAPUP=""; [ "$(team_mode_last_role "$MODE" "$(team_root)")" = wrapup ] || NO_WRAPUP=1
  blind="$RRD/blind-check.md"; brief="$RRD/acceptance-brief.md"
  [ -s "$blind" ] || acc_fail "runs/$RREF/blind-check.md missing — the blind order-vs-diff check comes first"
  [ -s "$brief" ] || acc_fail "runs/$RREF/acceptance-brief.md missing"
  ! [ "$brief" -ot "$blind" ] || acc_fail "acceptance-brief.md is older than blind-check.md — write the brief from the blind check"
  for h in "## Ordered vs delivered" "## Scope delta" "## Fit risks" "## Open defects" "## Warnings" \
    "## Recommendation"; do
    grep -qxF "$h" "$brief" || acc_fail "acceptance-brief.md lacks the heading '$h'"
  done
  qr="$RRD/qa-report-$(rec "$last" attempt).md"
  [ -f "$qr" ] || acc_fail "no runs/$RREF/$(basename "$qr")"
  if [ "$(sed -n 's/^Verdict: //p' "$qr" | head -n 1)" = ready-with-warnings ]; then
    sect="$(awk '/^## Warnings$/ { f = 1; next } /^## / { f = 0 } f' "$brief")"
    IFS=',' read -ra ws <<<"$(sed -n 's/^Warnings: //p' "$qr" | head -n 1)"
    for w in ${ws[@]+"${ws[@]}"}; do
      w="$(printf '%s' "$w" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"; [ -n "$w" ] || continue
      ok=""
      while IFS= read -r l; do
        case "$l" in "- $w → keep — "?*|"- $w → fix — "?*) ok=1 ;;
          "- $w → follow-up — "?*) [ -z "$NO_WRAPUP" ] \
              || acc_fail "quick has no wrapup: '$w' needs keep or fix, not follow-up"
            ok=1 ;;
        esac
      done <<<"$sect"
      [ -n "$ok" ] || acc_fail "## Warnings has no '- $w → keep|fix|follow-up — <why>' line"
    done
  fi
  if [ -n "$NO_WRAPUP" ]; then
    l="$(awk '/^## Ordered vs delivered$/ { f = 1; next } /^## / { f = 0 } f' "$brief" \
      | grep -F ' → follow-up — ' | head -n 1 || true)"
    [ -z "$l" ] || acc_fail "quick has no wrapup: '$l' needs keep or fix, not follow-up"
  fi
  # A lead launched with ask_operator lists every verification-only answer it gave itself under a
  # seventh heading; the answers are read from their structured fields, never from a log line.
  if jq -e '.ask_operator == true' "$TD/teamlead.json" >/dev/null 2>&1; then
    grep -qxF "## Decided by the TeamLead" "$brief" || acc_fail "acceptance-brief.md lacks the heading '## Decided by the TeamLead'"
    sect="$(awk '/^## Decided by the TeamLead$/ { f = 1; next } /^## / { f = 0 } f' "$brief")"
    for a in "$RD"/asks/a-*.answer.json; do
      [ -f "$a" ] || continue
      jq -e '.authority == "teamlead" and ((.why // "") | startswith("verification-only:"))' "$a" >/dev/null 2>&1 || continue
      w="$(basename "$a" .answer.json)"; ok=""
      while IFS= read -r l; do case "$l" in "- $w "*|"- $w:"*) ok=1 ;; esac; done <<<"$sect"
      [ -n "$ok" ] || acc_fail "## Decided by the TeamLead has no line for verification-only answer $w"
    done
  fi
elif [ "$GATE $VERDICT" = "acceptance rework" ]; then
  round="$(jq -r --arg r "$RUN" 'select(.run == $r) | .round' "$TD/round" 2>/dev/null || true)"
  [[ "$round" =~ ^[0-9]+$ ]] || round=1
  want_ref="runs/$RUN/rework-$((round + 1)).md"
  r="${REF#"$TD"/}"; r="${r#.agents/team/}"
  [ "$r" = "$want_ref" ] && [ -s "$TD/$want_ref" ] \
    || bad "rework needs --ref $want_ref (the round's items, one per order line or QA defect)"
  REF=".agents/team/$want_ref"
  team_profile_load "$MAIN"
  ordered=0; grants=0; budget="$TEAM_LEAD_BUDGET_BRAINSTORM"; [ "$MODE" != quick ] || budget="$TEAM_LEAD_BUDGET_QUICK"
  for f in $(verdicts); do [ "$(rec "$RD/$f" verdict)" != rework ] || ordered=$((ordered + 1)); done
  # Derived from files, so a restarted runner or lead cannot reset it: one consumed Operator
  # continue on an abandon decision = one more round.
  for f in "$RD"/decisions/d-*.md; do
    [ -f "$f" ] && [ "$(fm "$f" answer_outcome)" = continue ] && [ "$(fm "$f" notify)" = abandon_decision ] \
      && [ "$(fm "$f" status)" = consumed ] && grants=$((grants + 1)) || true
  done
  if [ "$MODE" = quick ] && [ "$ordered" = 0 ] && [ "$QUICK_CALL" != continue ]; then
    bad "quick: --quick-call continue, or abandon-recommended to stop"
  fi
  if [ "$ordered" -ge $((budget + grants)) ]; then
    echo "error: rework budget $budget reached (teams.teamlead.rework_budget.$MODE) — write abandon-recommended with --notify abandon_decision" >&2
    exit 9
  fi
elif [ "$GATE $VERDICT" = "acceptance abandon-recommended" ]; then
  [ -n "$DECISION" ] || bad "abandon-recommended needs --decision d-<n> (a pending decision opened with --notify abandon_decision)"
  df="$(decision_file "$DECISION")"
  [ "$(fm "$df" status)" = pending ] && [ "$(fm "$df" notify)" = abandon_decision ] \
    || bad "$DECISION is not a pending decision opened with --notify abandon_decision"
fi

if [ "$VERDICT" = revise ]; then
  team_profile_load "$MAIN"
  used=0; grants=0
  for f in $(verdicts); do [ "$(rec "$RD/$f" verdict)" != revise ] || used=$((used + 1)); done
  # Consumed grants count, not verdict files: each answered more-revise decision is spent once.
  for f in "$RD"/decisions/d-*.md; do
    [ -f "$f" ] && [ "$(fm "$f" answer_outcome)" = more-revise ] && [ "$(fm "$f" gate)" = "$GATE" ] \
      && [ "$(fm "$f" status)" = consumed ] && grants=$((grants + 1)) || true
  done
  if [ -n "$DECISION" ]; then
    df="$(decision_file "$DECISION")"
    [ "$(fm "$df" status)" = answered ] && [ "$(fm "$df" answer_outcome)" = more-revise ] \
      && [ "$(fm "$df" gate)" = "$GATE" ] \
      || bad "--decision $DECISION is not an answered, unconsumed more-revise grant for gate $GATE"
    grants=$((grants + 1))
  fi
  if [ "$used" -ge $((TEAM_LEAD_REVISE_LIMIT + grants)) ]; then
    echo "error: revise limit $TEAM_LEAD_REVISE_LIMIT reached for gate $GATE (teams.teamlead.revise_limit) — write escalate with a pending decision, approve$([ "$MODE" != quick ] || echo ', or remode')" >&2
    exit 5
  fi
fi

# The plan approve that opens the run's work needs the constraint digest (team-lead.sh decides per mode).
if [ "$GATE $VERDICT" = "plan approve" ]; then
  need="$(jq -r '[.artifacts[] | select(startswith(".agents/plans/"))][0] // empty' "$last")"
  [ -n "$need" ] || bad "$FOR names no plan"
  bash "$LIB/team-lead.sh" digest-check "$TEAM" "$need" || exit 7
fi

# Tracker comments as requirements (opt-in): an approve or an accept needs a current read.
case "$GATE $VERDICT" in
  "plan approve"|"acceptance accept")
    . "$LIB/team-tracker-gate.sh"; if trk_on; then trk_gate; fi ;;
esac

target="$(write_verdict)"
# The grant, or the decision that accepted an uncertain tracker read, is spent by this verdict.
if [ -n "$DECISION" ] && { [ "$VERDICT" = revise ] || [ -n "${TRK_DECISION:-}" ]; }; then
  spent="${TRK_DECISION:-$df}"
  fm_set "$spent" status consumed; fm_set "$spent" consumed_by "$(basename "$target")"
fi
echo "$target"
