# Sourced by team-ask-hook.sh (main checkout), never executed: the hook's decision helpers kept apart
# so the hook stays one screenful. They read the hook's globals (MAIN, CLONE, RUN, TD, ASK_*, LIB,
# TMP, STAGE_SID, LIVEP) and its helpers (sj, stopped, verify_decision, reply_matches, dfm_h).
# Bash 3.2 + jq. Contract: .agents/reference/team-lead.md §6–§7.

# lead_egress_deny <id> <answer json> — #322: the lead's own deny of an unbound egress permission
# ask (team-answer.sh's rule): a deny grants nothing, so it needs no Operator verification. Under
# the run's ask lock: no decision bound to the ask that is not withdrawn. An allow never qualifies.
lead_egress_deny() {
  local v rc=0
  [ "$(jq -r '.authority // ""' <<<"$2")" = teamlead ] && [ "$(jq -r '.form // ""' <<<"$2")" = deny ] \
    && [ "$(jq -r '.decision // ""' <<<"$2")" = "" ] && [ "$(ask_get "$1" kind)" = permission ] \
    && [ -z "$(ask_get "$1" requires_decision)" ] || return 1
  case "$(ask_get "$1" tier_cause)" in "egress: "*) ;; *) return 1 ;; esac
  ask_lock || return 1
  for v in "$ASK_TD/runs/$ASK_RUN/decisions"/d-*.md; do
    [ -f "$v" ] && sed -n '/^---$/,/^---$/p' "$v" | grep -qx "bind_ask: $1" \
      && ! sed -n '/^---$/,/^---$/p' "$v" | grep -qx "status: withdrawn" && { rc=1; break; }
  done
  ask_unlock
  return "$rc"
}

# batch_claim — #322: the live request ($TMP.in) against the run's allowed batch decisions. Each
# candidate (team_batch.py, the main checkout's) is verified like any Operator decision, then, under
# the run's ask lock: the team not stopped, the run current, the decision still allowed and
# unrevoked, no earlier ask of this session for this very request with an answer waiting (that
# answer wins: handle claims and delivers it), and only then the claim, which re-checks the copy,
# the pins, the use and the expiry. Claimed → allow, `operator (batch d-<n>)` in answers.md, no
# Operator touch (no human acted now).
batch_claim() {
  local dd="$ASK_TD/runs/$ASK_RUN/decisions" cand did k id now f req
  [ -d "$dd" ] || return 1
  cand="$(python3 -I "$LIB/team_batch.py" candidates --dir "$dd" --input "$TMP.in" --now "$(ask_utc)" 2>/dev/null)" || return 1
  req="$(jq -cS . "$TMP.in" 2>/dev/null)" || return 1
  while read -r did k; do
    [ -n "$did" ] && [ -n "$k" ] || continue
    verify_decision "$did" -batch "" || continue
    ask_lock || return 1
    f="$dd/$did.md"
    if stopped || [ "$(sj run)" != "$RUN" ] || ! sed -n '/^---$/,/^---$/p' "$f" | grep -qx "answer_outcome: allow" \
        || sed -n '/^---$/,/^---$/p' "$f" | grep -q "^revoked_at:"; then
      ask_unlock; return 1
    fi
    for id in $(ask_ids); do
      [ "$(ask_get "$id" session_id)" = "$STAGE_SID" ] && [ -f "$ASK_D/$id.answer.json" ] || continue
      case "$(ask_get "$id" state)" in delivered|withdrawn) continue ;; esac
      [ "$(jq -cS .payload "$ASK_D/$id.json" 2>/dev/null)" = "$req" ] && { ask_unlock; return 1; }
    done
    now="$(ask_utc)"
    if python3 -I "$LIB/team_batch.py" claim --dir "$dd" --id "$did" --entry "$k" --input "$TMP.in" --now "$now"; then
      echo "$now batch $did entry $k — authority operator (batch $did)" >> "$ASK_TD/runs/$ASK_RUN/answers.md"
      ask_unlock
      jq -n '{hookSpecificOutput: {hookEventName: "PermissionRequest", decision: {behavior: "allow"}}}'
      return 0
    fi
    ask_unlock
  done <<<"$cand"
  return 1
}

# verify_delegated <id> <did> <form> <val> <answer json> — a decision the Supervisor answered as a
# delegate (team-lead-decision.sh decision_delegated). Nothing is taken from the clone or from the
# ledger as proof; every binding is rebuilt from what this hook holds now and looked up in the
# Supervisor's own call:
# - the team and its active run from the main checkout's anchor;
# - the live input of this very event (handle's payload: the question, the plan, the permission
#   request) — an event with none refuses delegation — and its canonical digest;
# - the stage's active run, session and attempt, read from session.json now (after the wait,
#   never the values of this hook's entry), which must be the ask's;
# - the governing instruction now, derived from the Operator's message in the registered
#   Supervisor session: its id (m-<message uuid>) and the class, bound to this run;
# - the registered Supervisor session's transcript (registry + declared profile, never the
#   ledger) holds a standalone call whose argv is exactly run, decision, ask, attempt, session,
#   request digest, THAT mandate id, that class and the reply, made no earlier than the decision
#   opened or the run started — the call itself attests the grant it answered under, so a later
#   mandate of the same class approves nothing, whatever the files say and whatever the times;
# - that reply, parsed by the writer's parser, is this answer.
# The ledger only says which reply, class and mandate to look for and stops a second answer.
verify_delegated() {
  local x team lf cfg t floor cls reply sid cwd dig args ssid att mid
  . "$LIB/team-mandate.sh" 2>/dev/null && command -v mandate_covers >/dev/null 2>&1 || return 1
  x="$(team_anchor_team "$MAIN" "$CLONE")" || return 1
  team="$(cut -f1 <<<"$x")"; [ "$(cut -f2 <<<"$x")" = "$RUN" ] || return 1
  # Live input, for every event kind: the payload this hook process was given (handle's local).
  [ -n "${LIVEP:-}" ] && jq -e 'type == "object"' <<<"$LIVEP" >/dev/null 2>&1 || return 1
  dig="$(jq -cS . <<<"$LIVEP" 2>/dev/null | team_evidence_sha)" && [ -n "$dig" ] || return 1
  [ "$dig" = "$(jq -cS .payload "$ASK_D/$1.json" 2>/dev/null | team_evidence_sha)" ] || return 1
  # The stage's run, session and attempt as they are now, and they are the ask's.
  ssid="$(sj session_id)"; att="$(sj attempt)"
  [ "$(sj run)" = "$RUN" ] && [ -n "$ssid" ] && [ -n "$att" ] && [ "$(ask_get "$1" session_id)" = "$ssid" ] \
    && [ "$(ask_get "$1" attempt)" = "$att" ] || return 1
  lf="$MAIN/.agents/team/delegated/$team-$RUN-$2.json"
  team_relay_pins "$lf" "$team" "$RUN" "$2" "$1" || return 1
  reply="$(jq -r '.reply // ""' "$lf")"; cls="$(jq -r '.class // ""' "$lf")"; mid="$(jq -r '.mandate // ""' "$lf")"
  [ -n "$reply" ] && [ -n "$cls" ] && [ -n "$mid" ] && [ "$mid" = "$(dfm_h delegate_mandate)" ] || return 1
  # The class from the main checkout's checker on the live input; the answer's own mandate, in force.
  jq -n --arg k "$(ask_get "$1" kind)" --argjson p "$LIVEP" '{kind: $k, payload: $p}' > "$TMP.mand" 2>/dev/null || return 1
  [ "$(mandate_ask_class "$MAIN" "$CLONE" "$TMP.mand" "$cls")" = "$cls" ] || return 1
  [ "$(mandate_covers "$MAIN" "$cls" "$team" "$RUN" "$mid")" = "$mid" ] || return 1
  sid="$(jq -r '.session_id // empty' "$MAIN/.agents/team/registry/Supervisor.json" 2>/dev/null)"
  cwd="$(jq -r '.cwd // empty' "$MAIN/.agents/team/registry/Supervisor.json" 2>/dev/null)"; cwd="${cwd:-$MAIN}"
  [ -n "$sid" ] || return 1
  cfg="$(team_supervisor_home "$MAIN")" || return 1
  t="$(team_role_transcript "$cwd" "$sid" "$cfg")"
  [ -f "$t" ] || return 1
  floor="$(team_run_floor "$RUN" "$(dfm_h created_at)")"
  [ -n "$floor" ] || return 1
  args="$(team_delegate_args "$team" "$2" "$RUN" "$1" "$att" "$ssid" "$dig" "$reply" "$mid" "$cls")"
  [ -n "$(team_evidence_tool_call "$t" "$floor" "$MAIN" "$args")" ] || return 1
  reply_matches "$1" "$2" "$reply" "$3" "$4" "$5"
}
