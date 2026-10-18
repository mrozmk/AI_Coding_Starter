#!/usr/bin/env bash
# Record validation for team-run.sh (moved out in TT-790 to keep the runner under 500 lines).
# Sourced from the main checkout; uses the runner's globals (TD, BRANCH, LINE, RUN, MODE) and
# helpers (rec, artifact, accepted_record, cancel_exit). Contract: .agents/reference/team-mode.md
# Bash 3.2 compatible (macOS /bin/bash): no mapfile, no associative arrays.

fail() { echo "validation failed: $*" >&2; return 1; }

check_common() {
  local r="$1"
  [ -f "$TD/session.json" ] || fail "no session.json — record has no launched attempt" || return 1
  [ "$(rec "$r" run)" = "$(session_json run)" ] && [ "$(rec "$r" role)" = "$(session_json role)" ] \
    && [ "$(rec "$r" attempt)" = "$(session_json attempt)" ] \
    || fail "record is not for the launched run/role/attempt" || return 1
  [ "$(rec "$r" input_rev)" = "$(session_json input_rev)" ] || fail "input_rev differs from session.json" || return 1
  [ "$(git rev-parse --abbrev-ref HEAD)" = "$BRANCH" ] || fail "clone is not on $BRANCH" || return 1
  [ "$(rec "$r" output_rev)" = "$(git rev-parse HEAD)" ] || fail "output_rev is not the clone HEAD" || return 1
  [ -z "$(git status --porcelain)" ] || fail "working tree is not clean"
}

check_planner() {
  local r="$1" rev a specs=0 plans=0 plan=""
  rev="$(rec "$r" output_rev)"
  for a in $(rec "$r" artifacts | tr ',' ' '); do
    [ "$(git cat-file -t "$rev:$a" 2>/dev/null)" = blob ] || fail "artifact $a not in $rev" || return 1
    case "$a" in
      .agents/specs/*.md) specs=$((specs + 1)) ;;
      .agents/plans/active/*.md) plans=$((plans + 1)); plan="$a" ;;
    esac
  done
  [ "$specs" -ge 1 ] || [ "$MODE" = quick ] || fail "no spec (.agents/specs/*.md) among the artifacts" || return 1
  [ "$plans" -ge 1 ] || fail "no plan (.agents/plans/active/*.md) among the artifacts" || return 1
  if [ "$plans" -gt 1 ] || [ -n "$(git show "$rev:$plan" | grep '^## Execution Plan')" ]; then
    fail "team handoff needs one standalone plan — resolve the split with the developer in the planner session"
  fi
}

# ADO computes the merge asynchronously: right after a push the PR can still show the old commit.
check_ado() {
  local pr="$1" rev="$2" draft="$3" j ms src waited=0
  team_ado_coords || return 1
  while :; do
    team_cancelled && cancel_exit
    j="$(team_pr_json "$pr")" || fail "az repos pr show $pr failed" || return 1
    ms="$(jq -r '.mergeStatus // "notSet"' <<<"$j")"
    src="$(jq -r '.lastMergeSourceCommit.commitId // ""' <<<"$j")"
    if { [ "$ms" = queued ] || [ "$ms" = notSet ] || [ "$src" != "$rev" ]; } && [ "$waited" -lt "$ADO_WAIT" ]; then
      sleep "$ADO_POLL"; waited=$((waited + ADO_POLL)); continue
    fi
    break
  done
  team_pr_identity "$j" "$BRANCH" "$LINE" || fail "PR identity mismatch (#$pr)" || return 1
  [ "$(jq -r '.isDraft' <<<"$j")" = "$draft" ] || fail "PR #$pr isDraft is not $draft" || return 1
  [ "$src" = "$rev" ] || fail "PR #$pr lastMergeSourceCommit $src is not $rev (mergeStatus $ms)"
}

check_pushed() {
  local tip
  tip="$(git ls-remote origin "refs/heads/$BRANCH" | cut -f1)"
  [ "$tip" = "$1" ] || fail "origin $BRANCH is '${tip:-absent}', not $1"
}

check_qa_report() {
  local f="$1" r="$2" g line val out
  [ -f "$f" ] || fail "qa report $f missing" || return 1
  grep -qxF "run: $(rec "$r" run)" "$f" && grep -qxF "attempt: $(rec "$r" attempt)" "$f" \
    && grep -qxF "output_rev: $(rec "$r" output_rev)" "$f" || fail "qa report header does not match the record" || return 1
  grep -Eqx 'Verdict: (ready|ready-with-warnings)' "$f" || fail "qa report Verdict must be ready or ready-with-warnings" || return 1
  for g in code design cross-model final-build; do
    line="$(grep -m1 "^Gate $g: " "$f")" || fail "qa report missing Gate $g" || return 1
    val="${line#Gate $g: }"; out="${val%% *}"
    case "$out" in
      passed|warn) ;;
      skipped|substituted|not-verified) case "$val" in "$out — "?*) ;; *) fail "qa report Gate $g $out needs a reason" || return 1 ;; esac ;;
      *) fail "qa report Gate $g has unknown outcome '$out'" || return 1 ;;
    esac
  done
  grep -Eq '^Gate final-build: passed( |$)' "$f" || fail "qa report Gate final-build must be passed" || return 1
  line="$(grep -Ex 'Tests: passed=[0-9]+ failed=[0-9]+ skipped=[0-9]+ baseline=[0-9]+' "$f")" \
    || fail "qa report Tests line malformed" || return 1
  set -- $(tr -c '0-9\n' ' ' <<<"$line")
  [ "$1" -gt 0 ] || fail "qa report Tests: passed=0 — no tests ran" || return 1
  [ "$2" -le "$4" ] || fail "qa report Tests: failed=$2 exceeds baseline=$4" || return 1
  grep -qx 'Rethink signals: none' "$f" || fail "qa report needs 'Rethink signals: none'"
}

# The coder must hand over the planner's own plan, moved to done/ by /execute.
check_coder_plan() {
  local r="$1" rev="$2" want
  want=".agents/plans/done/$(basename "$(artifact "$(accepted_record planner)" .agents/plans/active/)")"
  [ "$(artifact "$r" .agents/plans/done/)" = "$want" ] || fail "coder artifact is not $want" || return 1
  [ "$(git cat-file -t "$rev:$want" 2>/dev/null)" = blob ] || fail "$want not in $rev"
}

check_coder_pr() {  # check_coder_pr <role> <pr_id> — the role must report the coder's PR
  local coder
  coder="$(accepted_record coder)"
  [ -n "$coder" ] && [ "$2" = "$(rec "$coder" pr_id)" ] || fail "PR identity mismatch ($1 pr_id ${2:-none} is not the coder's)"
}

# "Never Done" for tracker=github: the runner, not the prompt, refuses a wrapup that did not post
# its comment, deliver its status, or finish an accepted follow-up. jira/none (and a pre-2b
# team.json) keep today's validation. `$s` binds the ROOT before `all` — without it `.intents`
# inside the loop resolves against the draft entry and every accepted follow-up loses.
check_wrapup_tracker() {  # check_wrapup_tracker <state-file> <tracker>
  local sf="$1" t="${2:-}"
  case "$t" in github) ;; *) return 0 ;; esac
  jq -e '. as $s
    | (any(($s.intents // {})[]; .op == "comment" and .state == "done"))
      and (any(($s.intents // {})[]; .op == "set-status" and .logical == "delivered"
               and .state == "done"))
      and (all(($s.drafts // {}) | to_entries[] | select(.value.accepted == true);
               .key as $k | any(($s.intents // {})[];
                 .op == "create" and .draft_id == $k and .state == "done")))' \
    "$sf" >/dev/null 2>&1 \
    || fail "tracker=github: wrapup-state.json lacks done comment/set-status delivered or an accepted follow-up"
}

# Wrapup may only add memory on top of the QA revision, so QA's build/test result still holds.
check_wrapup() {
  local r="$1" pr="$2" rev="$3" qa_rev bad f
  check_coder_pr wrapup "$pr" || return 1
  qa_rev="$(rec "$(accepted_record qa)" output_rev)"
  [ -n "$qa_rev" ] || fail "no accepted qa record" || return 1
  bad="$(team_non_memory_files "$qa_rev" "$rev")" || fail "cannot diff $qa_rev..$rev" || return 1
  [ -z "$bad" ] || fail "wrapup changed files outside .agents/memory/: $(echo $bad)" || return 1
  f="$TD/runs/$RUN/wrapup-$(rec "$r" attempt).md"
  [ -s "$f" ] || fail "wrapup summary $f missing or empty" || return 1
  grep -Eq '^target_rev: [0-9a-f]{40}$' "$f" || fail "wrapup summary lacks 'target_rev: <sha>'" || return 1
  check_wrapup_tracker "$TD/runs/$RUN/wrapup-state.json" "$(team_json tracker || true)" || return 1
  check_pushed "$rev" && check_ado "$pr" "$rev" false
}

validate_record() {
  local r="$1" role pr rev coder
  role="$(rec "$r" role)"; pr="$(rec "$r" pr_id)"; rev="$(rec "$r" output_rev)"
  check_common "$r" || return 1
  case " $(team_mode_roles "$MODE") " in
    *" $role "*) ;;
    *) fail "role $role does not run in mode $MODE"; return 1 ;;
  esac
  case "$role" in
    planner) check_planner "$r" ;;
    coder)
      [ -n "$pr" ] || fail "coder record has no pr_id" || return 1
      check_coder_plan "$r" "$rev" || return 1
      check_pushed "$rev" && check_ado "$pr" "$rev" true ;;
    qa)
      check_coder_pr qa "$pr" || return 1
      rec "$r" evidence | tr ',' '\n' | grep "qa-report-$(rec "$r" attempt)\.md\$" >/dev/null || fail "evidence lacks qa-report-$(rec "$r" attempt).md" || return 1
      check_qa_report "$TD/runs/$RUN/qa-report-$(rec "$r" attempt).md" "$r" || return 1
      check_pushed "$rev" && check_ado "$pr" "$rev" false ;;
    wrapup) check_wrapup "$r" "$pr" "$rev" ;;
    cli)
      [ -n "$pr" ] || fail "cli record has no pr_id" || return 1
      # A cli PR skips QA, so the role publishes it itself (TT-790).
      check_pushed "$rev" && check_ado "$pr" "$rev" false ;;
    *) fail "unknown role $role" ;;
  esac
}
