#!/usr/bin/env bash
# The runner's half of the ask channel (team-lead.md §6): withdraw and re-ring asks, re-derive their
# follow-ups, ring attention lines no ask covers, and act on the lead's `run close`.
# Sourced by team-run.sh from the MAIN checkout after team-run-lead.sh and team-ask.sh, never
# executed: every function runs in the runner's shell and uses its globals (TEAM, RUN, TD, CLONE,
# root, ROLE, rec, sess_name, end_session) and team-run-lead.sh's helpers. Bash 3.2.

# lead_withdraw_asks all|stale <why> — withdraw the run's open asks (all, or those whose session or
# attempt is no longer the stage's) and every pending decision bound to one of them.
lead_withdraw_asks() {
  local scope="$1" why="$2" id sid att
  ask_init "$TD" 2>/dev/null || return 0
  sid="$(jq -r '.session_id // ""' "$TD/session.json" 2>/dev/null || true)"
  att="$(jq -r '.attempt // "" | tostring' "$TD/session.json" 2>/dev/null || true)"
  for id in $(ask_ids); do
    case "$(ask_get "$id" state)" in delivered|withdrawn) continue ;; esac
    if [ "$scope" = stale ]; then
      [ -n "$sid" ] || continue
      [ "$(ask_get "$id" session_id)" != "$sid" ] || [ "$(ask_get "$id" attempt)" != "$att" ] || continue
    fi
    ask_cas "$id" "waiting timed-out answered delivering" withdrawn || continue
    lead_withdraw_decisions "$id" "$why" || true
    team_session_doorbell "$TD" lead "ask $(ask_get "$id" role) $id withdrawn — $why"
  done
}

# lead_withdraw_decisions <a-n> <why> — withdraw and resolve every pending decision bound to that
# ask. → 0 when one was withdrawn. Under the ask lock, which every decision writer takes
# (team-lead-decision.sh): a relay or an answer racing the withdrawal sees one or the other.
lead_withdraw_decisions() {
  local f did rc=1 gone=""
  ask_lock || return 1
  for f in "$ASK_TD/runs/$ASK_RUN"/decisions/d-*.md; do
    [ -f "$f" ] && [ "$(lfm "$f" bind_ask)" = "$1" ] && [ "$(lfm "$f" status)" = pending ] || continue
    did="$(lfm "$f" id)"
    lfm_set "$f" status withdrawn; lfm_set "$f" withdrawn_at "$(team_utc)"
    printf '\n## Withdrawn\nask gone (the runner): %s\n' "$2" >> "$f"
    gone="$gone $did"; rc=0
  done
  ask_unlock
  for did in $gone; do lead_resolve "$did"; done
  return "$rc"
}

# lead_ring_due <stamp file> <first due epoch> — rc 0, and the stamp set to now, when a ring is due:
# no stamp yet → at the first due time; after that every TEAM_ASK_RERING_SECS since the last ring.
lead_ring_due() {
  local now last due
  now="$(team_now)"; last="$(cat "$1" 2>/dev/null || true)"
  if [[ "$last" =~ ^[0-9]+$ ]]; then due=$((last + ${TEAM_ASK_RERING_SECS:-300})); else due="$2"; fi
  [ "$now" -ge "$due" ] || return 1
  echo "$now" > "$1"
}

# lead_asks — every poll: follow-ups re-derived from every answer file (an interrupted sender, an
# answer before the ack), a decision named by an answer spent, stale asks withdrawn, an unhandled
# ask re-rung every TEAM_ASK_RERING_SECS, a blocked record that never got an ask rung once.
lead_asks() {
  local id a did f now every="${TEAM_ASK_RERING_SECS:-300}" pending acked r
  ask_init "$TD" 2>/dev/null || return 0
  for a in "$ASK_D"/a-*.answer.json; do
    [ -f "$a" ] || continue
    id="$(basename "$a" .answer.json)"; ask_follow_up "$id"
    did="$(jq -r '.decision // ""' "$a")"; f="$ASK_TD/runs/$ASK_RUN/decisions/$did.md"
    if [ -n "$did" ] && [ -f "$f" ] && [ "$(lfm "$f" status)" = answered ]; then
      lfm_set "$f" status dispatched; lfm_set "$f" dispatched_at "$(team_utc)"
    fi
  done
  lead_withdraw_asks stale "the stage session or attempt was replaced"
  now="$(team_now)"
  for id in $(ask_ids); do
    case "$(ask_get "$id" state)" in
      waiting|timed-out) ;;
      # A lead-tier (or unpinnable) permission ask withdrawn by its own hook's deadline, a
      # superseded or ambiguous operator ask: its decision goes with it.
      withdrawn) lead_withdraw_decisions "$id" "the ask was withdrawn; the stage's retry files a new ask" \
          && team_session_doorbell "$TD" lead "ask $(ask_get "$id" role) $id withdrawn — timed out, its decision withdrawn"
        continue ;;
      *) continue ;;
    esac
    [ ! -f "$ASK_D/$id.answer.json" ] || continue
    pending=""
    for f in "$ASK_TD/runs/$ASK_RUN"/decisions/d-*.md; do
      [ -f "$f" ] && [ "$(lfm "$f" bind_ask)" = "$id" ] && [ "$(lfm "$f" status)" = pending ] && pending=1
    done
    [ -z "$pending" ] || continue
    lead_ring_due "$ASK_D/.rung-$id" $(( $(team_epoch "$(ask_get "$id" filed_at)") + every )) || continue
    team_session_doorbell "$TD" lead "$(ask_ring_line "$id")"
  done
  # A blocked record the stage hook never turned into an ask (it failed open): ring it once.
  acked="$(cat "$TD/acked" 2>/dev/null)" || return 0
  r="$TD/runs/$RUN/$acked"
  [ -f "$r" ] && [ "$(rec "$r" verdict)" = blocked ] && [ ! -e "$r.answered" ] && [ ! -e "$r.noask" ] || return 0
  [ -z "$(ask_open_for_record "$acked")" ] || return 0
  [ $((now - $(team_epoch "$(rec "$r" written_at)"))) -ge 60 ] || return 0
  touch "$r.noask"
  team_session_doorbell "$TD" lead "stop $(rec "$r" role) $(rec "$r" attempt): ${r#"$CLONE"/} — $(rec "$r" message) (no ask filed)"
}

# lead_unasked_decisions — every poll, for a lead launched with ask_operator: a pending decision with
# a ## Dialog the lead has not raised as AskUserQuestion is rung `unasked d-<n>: …` after
# TEAM_UNASKED_GRACE_SECS, then every TEAM_ASK_RERING_SECS — a channel that never depends on
# notify.sh. Where the dialog is unreliable (an unclean or changed registration snapshot: a hook
# may answer it with no menu shown — after launch only: an unclean lead is never launched) a raised
# dialog is no attention: the ring goes on, worded to print the decision with the terminal command
# as a line to copy, and the runner warns once per decision. Always returns 0.
lead_unasked_decisions() {
  local f id c oldest="" list="" x sid t="" raised="" env_ok="" cause="" grace q w msg
  jq -e '.ask_operator == true' "$TD/teamlead.json" >/dev/null 2>&1 || return 0
  . "$root/.claude/lib/team-evidence.sh" 2>/dev/null || return 0
  command -v team_evidence_provenance >/dev/null 2>&1 || return 0
  for f in "$TD/runs/$RUN"/decisions/d-*.md; do
    [ -f "$f" ] && [ "$(lfm "$f" status)" = pending ] && grep -qx '## Dialog' "$f" || continue
    # Delegated to the Supervisor (team-mandate.sh): no dialog is owed until it lapses or is handed back.
    [ "$(lfm "$f" delegate)" != supervisor ] || continue
    list="$list $(lfm "$f" id)"; c="$(lfm "$f" created_at)"
    if [ -z "$oldest" ] || [[ "$c" < "$oldest" ]]; then oldest="$c"; fi
  done
  [ -n "$list" ] || return 0
  x="$(team_lead_trusted "$root" "$CLONE" "$RUN" 2>/dev/null)" || x=""
  sid="$(cut -f1 <<<"$x")"
  if [ -n "$sid" ] && [ "$(cut -f3 <<<"$x")" != legacy ] \
      && cause="$(team_evidence_provenance "$root" "$CLONE" "$RUN" "$sid")"; then
    env_ok=1
    t="$(team_role_transcript "$(git -C "$CLONE" rev-parse --show-toplevel 2>/dev/null || echo "$CLONE")" "$sid" "$cause")"
    raised=" $(team_evidence_dialog_raised "$t" "$oldest" | tr '\n' ' ')"
  else
    [ -n "$cause" ] || cause="the TeamLead session is not one the anchor records"
  fi
  grace="${TEAM_UNASKED_GRACE_SECS:-60}"
  w="$(sess_name lead 2>/dev/null || echo lead)"
  # Ids, not paths: a clone path with a space must not split.
  for id in $list; do
    f="$TD/runs/$RUN/decisions/$id.md"
    if [ -n "$env_ok" ]; then case "$raised" in *" $id "*) continue ;; esac; fi
    lead_ring_due "$TD/runs/$RUN/decisions/.unasked-$id" \
      $(( $(team_epoch "$(lfm "$f" created_at)") + grace )) || continue
    q="$(sed -n '/^## Question$/{n;p;q;}' "$f")"
    if [ -n "$env_ok" ]; then
      msg="unasked $id: no AskUserQuestion raised yet — run decision list --pending, then raise the ask-operator dialog of $id (team-lead.md §7) — ${q:0:120}"
    else
      msg="unasked $id: the dialog is unreliable here ($cause) — ask for no typed reply; print $id and this line for the Operator to copy into a terminal: $(team_evidence_terminal "$TEAM" "$f" "$id") — ${q:0:120}"
      if [ ! -e "$TD/runs/$RUN/decisions/.unclean-warned-$id" ]; then
        touch "$TD/runs/$RUN/decisions/.unclean-warned-$id"
        echo "warn: $id waits in $w — dialog unreliable ($cause)"
      fi
    fi
    team_session_doorbell "$TD" lead "$msg" || true
  done
  return 0
}

# lead_ask_near <role> <attempt> <epoch> <secs> [waiting] — an ask of that attempt filed or
# delivered within <secs> of <epoch> (with `waiting`: or one still waiting).
lead_ask_near() {
  local id t d
  ask_init "$TD" 2>/dev/null || return 1
  for id in $(ask_ids); do
    [ "$(ask_get "$id" role)" = "$1" ] && [ "$(ask_get "$id" attempt)" = "$2" ] || continue
    [ -z "${5:-}" ] || [ "$(ask_get "$id" state)" != waiting ] || return 0
    for t in "$(ask_get "$id" filed_at)" "$(ask_get "$id" delivered_at)"; do
      [ -n "$t" ] || continue
      d=$(( $3 - $(team_epoch "$t") )); d="${d#-}"
      [ "$d" -gt "$4" ] || return 0
    done
  done
  return 1
}

# lead_final_record <role> <attempt> — the attempt's newest record is final (done|failed) and newer
# than the last gate verdict that sent it back (a plan revise for that record).
lead_final_record() {
  local r a f
  r="$(team_records "$(run_ref)" "$1" "$2" | tail -n 1)"
  [ -n "$r" ] || return 1
  case "$(rec "$r" verdict)" in done|failed) ;; *) return 1 ;; esac
  a="$(ack_name "$r")"
  for f in "$TD/runs/$RUN"/teamlead-plan-*.json; do
    [ -f "$f" ] && [ "$(rec "$f" for)" = "$a" ] && [ "$(rec "$f" verdict)" = revise ] && return 1
  done
  return 0
}

# lead_attention <role> <line> — a new attention line with the lead on. No pane is read: the stage
# hook files every stop as an ask. An idle stage or a failed stop hook rings only when no ask covers
# it; a permission prompt rings only when no ask covers it after one poll's grace; other kinds ring
# as `attention <role>: <kind> — <message>`.
LEAD_ATT_DEFER=""
lead_attention() {
  local role="$1" line kind msg at
  line="$(sed -n "${2}p" "$TD/runs/$RUN/attention" 2>/dev/null || true)"
  kind="$(cut -d' ' -f2 <<<"$line")"; msg="$(cut -d' ' -f3- <<<"$line")"
  at="$(team_epoch "$(cut -d' ' -f1 <<<"$line")")"
  case "$kind" in
    idle_prompt|stop-failed)
      lead_final_record "$role" "$(session_json attempt)" && return 0
      lead_ask_near "$role" "$(session_json attempt)" "$at" 120 && return 0
      case "$msg" in *background*|*"Background"*) return 0 ;; esac
      team_session_doorbell "$TD" lead "attention $role: idle with no ask (the stop hook did not file one) — print it for the Operator" ;;
    permission_prompt)
      lead_ask_near "$role" "$(session_json attempt)" "$at" 10 waiting && return 0
      LEAD_ATT_DEFER="$LEAD_ATT_DEFER $2:$role" ;;
    *) team_session_doorbell "$TD" lead "attention $role: ${kind:-attention} — $msg" ;;
  esac
  return 0
}

# lead_attention_deferred — a permission prompt line seen one poll ago: still no ask → ring it.
lead_attention_deferred() {
  local e n role line at todo="$LEAD_ATT_DEFER"
  LEAD_ATT_DEFER=""
  for e in $todo; do
    n="${e%%:*}"; role="${e#*:}"
    line="$(sed -n "${n}p" "$TD/runs/$RUN/attention" 2>/dev/null || true)"
    at="$(team_epoch "$(cut -d' ' -f1 <<<"$line")")"
    lead_ask_near "$role" "$(session_json attempt)" "$at" 10 waiting && continue
    team_session_doorbell "$TD" lead "attention $role: permission prompt with no ask — $(cut -d' ' -f3- <<<"$line") (the channel did not see it; the Operator answers it in the window)"
  done
  return 0
}

# lead_close <verdict file> — act on the lead's `run close`: check, fence, quiesce, check again
# with trusted inputs (the main checkout's anchor and team-lib.sh), push, receipt, close. A refusal
# before the fence leaves the stage running; after it the stage is ended and nothing is relaunched
# (runs/<run>/close-refused) — the lead opens a decision.
lead_close() {
  local f="$TD/runs/$RUN/$1" rel=".agents/team/runs/$RUN/$1" reason anchor base br why sha
  reason="$(rec "$f" reason)"; anchor="$(team_anchor_file "$root" "$TEAM")"
  echo "$1" >> "$TD/verdict-acked"
  base="$(jq -r '.base_sha // empty' "$anchor" 2>/dev/null || true)"
  br="$(jq -r '.branch // empty' "$anchor" 2>/dev/null || true)"
  if [ -z "$base" ] || [ -z "$br" ] \
      || [ "$(jq -r '.clone // empty' "$anchor")" != "$(cd "$CLONE" && pwd -P)" ] \
      || [ "$(jq -r '.run // empty' "$anchor")" != "$RUN" ] \
      || [ "$br" != "$(git -C "$CLONE" branch --show-current)" ] || [ "$base" != "$(team_json base_sha)" ]; then
    lead_close_refused "the main checkout's anchor differs from this clone (clone, run, branch or base_sha)"
    return 0
  fi
  why="$(team_close_safe "$CLONE" "$base" "$RUN" "$(run_ref)" "$br" 2>&1)" \
    || { lead_close_refused "$why"; return 0; }
  touch "$TD/closing"
  lead_withdraw_asks all "run closing"
  end_session "$ROLE"
  why="$(team_close_safe "$CLONE" "$base" "$RUN" "$(run_ref)" "$br" 2>&1)" \
    || { lead_close_refused "$why" ended; return 0; }
  sha="$(git -C "$CLONE" rev-parse HEAD)"
  git -C "$CLONE" push origin "$br" >/dev/null 2>&1 || { lead_close_refused "push failed" ended; return 0; }
  [ "$(git -C "$CLONE" ls-remote origin "refs/heads/$br" 2>/dev/null | cut -f1)" = "$sha" ] \
    || { lead_close_refused "push failed: the remote tip is not $sha" ended; return 0; }
  team_anchor_closed "$root" "$TEAM" "$RUN" "$br" "$sha" "$reason" \
    || { lead_close_refused "the close receipt was not written to the anchor" ended; return 0; }
  close_run "lead-close:$reason" "$rel" "$br" "$sha"
}

# lead_close_hold <role> <attempt> — a lead close refused after the stage was ended: nothing is
# relaunched; the lead's decision (decision close) or a stop ends the run. → 0 while holding.
lead_close_hold() {
  [ -e "$TD/runs/$RUN/close-refused" ] || return 1
  ! team_lead_on || { lead_gate "$1" "$2" || true; lead_poll; }
  return 0
}

lead_close_refused() {  # lead_close_refused <why> [ended]
  rm -f "$TD/closing"
  [ -z "${2:-}" ] || touch "$TD/runs/$RUN/close-refused"
  team_session_doorbell "$TD" lead "close refused: $1${2:+ (the stage is ended — open a decision)}"
  echo "close refused: $1"
}

# stage_hooks_materialise — <clone>/.agents/team/stage-hooks.settings.json from the main checkout's
# template: every command an absolute path into the main checkout, every ask timeout (and the hook's
# TEAM_ASK_TIMEOUT) the measured hook wait (TEAM_ASK_TIMEOUT_SECS, 715 s: the hook answers by
# its own deadline 15 s earlier), {{SEAL}} the sha256 of the main checkout's clearance switch
# record at this launch, or off (#323). → 1 when the template cannot be rendered.
stage_hooks_materialise() {
  local seal
  . "$root/.claude/lib/team-clearance.sh" && seal="$(clearance_seal "$root")" || seal=off
  jq --arg m "$root" --argjson t "${TEAM_ASK_TIMEOUT_SECS:-715}" --arg s "$seal" 'del(._comment)
    | .hooks |= map_values(map(.hooks |= map(
        (if (.command | test("TEAM_ASK_TIMEOUT=")) then .timeout = $t
           | .command |= gsub("\\{\\{TIMEOUT\\}\\}"; ($t | tostring)) else . end)
        | .command |= (gsub("\\{\\{MAIN\\}\\}"; $m) | gsub("\\{\\{SEAL\\}\\}"; $s)))))' \
    "$root/.claude/team/stage-hooks.json" > "$TD/stage-hooks.settings.json.tmp" \
    && jq -e '.hooks.Stop' "$TD/stage-hooks.settings.json.tmp" >/dev/null \
    && mv "$TD/stage-hooks.settings.json.tmp" "$TD/stage-hooks.settings.json"
}
