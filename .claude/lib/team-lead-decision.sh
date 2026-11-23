#!/usr/bin/env bash
# Pending human decisions of the per-run TeamLead: runs/<run>/decisions/d-<n>.md. Sourced by
# team-lead.sh after resolve (TD, RUN, MAIN, LIB set), never executed. Bash 3.2.
#   decision open <team> --source <run file|attention:<n>> --question "<text>" [--options "<a|b>"]
#     [--recommend "<text>"] [--notify human_decision|abandon_decision] [--gate plan]
#     [--reason human-only|no-rule|lead-unsure|channel-failed|guard]
#   decision open <team> --ask a-<n> [--question "<text>"] [--options "<a|b>"] [--recommend "<text>"]
#     [--reason human-only|no-rule|lead-unsure|channel-failed|guard]
#     (an operator-tier ask, or a workflow human gate in a question: bound to the ask)
#   decision answer <team> d-<n> --text "<Operator answer>" | --from-ask
#     [--outcome continue|close|more-revise|approve|allow|deny]
#     [--tuning rule|TeamLead|none --why "<line>"]   (both required when the lead records the answer)
#   decision withdraw <team> d-<n> --why "<line>"     decision list <team> [--pending]
# A lead launched with teamlead.json ask_operator (the new path; an older lead keeps the contract
# below unchanged): open needs the Operator's choices — --options "a|b" (2–4), derived for an ask
# (permission/plan allow|deny, a question its labels), for --notify abandon_decision
# (continue|close) and for --gate plan (approve|revise|close) — and --recommend <one of them>; it
# stores the AskUserQuestion input under `## Dialog` and prints it as `ask-operator: <json>`. The
# lead raises that dialog verbatim; answer --from-ask then reads the Operator's answer entry from
# the lead's own transcript (team-evidence.sh: a dialog equal to ## Dialog, a lead session the
# anchor records, a clean registration snapshot) and records answered_via `teamlead-ask <uuid>`.
# open writes the file (status pending), then the escalate verdict with --notify, so the runner
# notifies the Operator once. answer asks for a human: from a terminal (a TTY, the id typed to
# confirm), or from the TeamLead window, where the lead's own transcript must hold a typed Operator
# message (not a doorbell, after created_at) containing the answer text. Both raise the bar; neither
# is proof (team-lead.md §7, "Limit of the human binding"). A decision bound to an ask (bind_ask)
# is answered by a fixed reply the Operator types — `d-<n> allow` | `d-<n> deny: <what instead>`
# (permission, plan) or `d-<n> <answer>` (question, text; several questions:
# `d-<n> <header>: <label>; <header>: <label>`) — and answer derives answer_outcome /
# answer_value / answer_map from it; team-answer.sh relays exactly those. A human answer appends
# `<utc> decision d-<n>` to runs/<run>/operator-touches and one entry to the project's touch log
# (`touches.sh add`, .agents/reference/operator-touches.md).

dfm() { sed -n '/^---$/,/^---$/p' "$1" | sed -n "s/^$2: *//p" | head -n 1; }
dfm_set() {  # dfm_set <file> <key> <value> — replace or add one frontmatter key, atomically
  # ENVIRON, not -v: awk -v expands backslash escapes, so `C:\tmp` or `\"` would be mangled.
  FM_K="$2" FM_V="$3" awk '/^---$/ { n++; if (n == 2 && !done) print ENVIRON["FM_K"] ": " ENVIRON["FM_V"]; print; next }
    n == 1 && index($0, ENVIRON["FM_K"] ": ") == 1 { print ENVIRON["FM_K"] ": " ENVIRON["FM_V"]; done = 1; next } { print }' "$1" > "$1.tmp"
  mv "$1.tmp" "$1"
}
d_bad() { echo "error: $2" >&2; exit "$1"; }
d_reply_shape() {  # d_reply_shape <a-n> — the reply form of a multi-question ask
  jq -r '[.payload.tool_input.questions[] | "\(.header // .question): <label>"] | join("; ")' "$ASK_D/$1.json"
}
d_resolve() {  # d_resolve <file> — its Operator notification is answered or moot (#97); never fails
  [ -n "$(dfm "$1" notify)" ] || return 0
  bash "$LIB/notify.sh" resolve --team "$(jq -r .team "$TD/team.json")" --run "$RUN" \
    --decision "$(dfm "$1" id)" >/dev/null 2>&1 || true
}
# d_reason_default <a-n|""> <gate> <notify> — the touch-log reason when the lead names none: an
# operator-tier ask, a plan gate or an abandon decision is human-only, anything else no-rule.
d_reason_default() {
  if [ -n "$1" ] && ask_init "$TD" 2>/dev/null && [ "$(ask_get "$1" tier || true)" = operator ]; then
    echo human-only
  elif [ "$2" = plan ] || [ "$3" = abandon_decision ]; then echo human-only
  else echo no-rule; fi
}
d_touch_reason() {  # d_touch_reason <file> — its touch_reason, derived for a file an older copy opened
  local r; r="$(dfm "$1" touch_reason)"
  [ -n "$r" ] || r="$(d_reason_default "$(dfm "$1" bind_ask)" "$(dfm "$1" gate)" "$(dfm "$1" notify)")"
  echo "$r"
}
# d_touch_log <file> <d-n> <ask> <ask kind> <outcome> <answer value> <reply rest> <text> — the
# answered decision as one entry of the project's touch log; a failure warns, the answer stands.
d_touch_log() {
  local f="$1" kind=decision ans c a ws="" stage
  if [ -n "$3" ]; then kind="${4:-decision}"; elif [ "$(dfm "$f" gate)" = plan ]; then kind=plan; fi
  case "$3:$4" in
    :*) ans="$8" ;;
    *:permission|*:plan) ans="$5"; [ -z "$6" ] || ans="deny: $6" ;;
    *) ans="$7" ;;
  esac
  c="$(team_epoch "$(dfm "$f" created_at)")"; a="$(team_epoch "$(dfm "$f" answered_at)")"
  [ "$c" -le 0 ] || [ "$a" -lt "$c" ] || ws=$(( a - c ))
  stage="$(dfm "$f" stage)"; case "$stage" in ""|-) stage=TeamLead ;; esac
  bash "$LIB/touches.sh" add --main "$MAIN" \
    --where "team $(jq -r .team "$TD/team.json") / $(jq -r .ticket "$TD/team.json") / $stage" \
    --kind "$kind" --reason "$(d_touch_reason "$f")" --what "$(sed -n '/^## Question$/{n;p;q;}' "$f")" \
    --answer "$ans" ${ws:+--wait-s "$ws"} >/dev/null 2>&1 || echo "warn: touch not recorded ($2)" >&2
}
d_file() {  # d_file <d-n> → path, or exit 2/4
  [[ "$1" =~ ^d-[0-9]+$ ]] || d_bad 2 "decision id must be d-<n>"
  [ -f "$DD/$1.md" ] || d_bad 4 "no decision $1 in runs/$RUN/decisions/"
  echo "$DD/$1.md"
}
one_line() { [ -n "$1" ] && [[ "$1" != *$'\n'* ]]; }

# notes_add <heading> <line> — one line at the end of a section of the lead's notes (team-lead.md
# §10); the file gets its six headings first when absent.
notes_add() {
  local f="$TD/runs/$RUN/teamlead-notes.md" h
  [ -f "$f" ] || ( IFS='|'; for h in $NOTES_HEADINGS; do printf '%s\n\n' "$h"; done ) > "$f"
  grep -qxF "$1" "$f" || printf '\n%s\n' "$1" >> "$f"
  NH="$1" NL="$2" awk '
    s && /^## / { print ENVIRON["NL"]; print ""; s = 0; b = 0 }
    s && /^$/ { b++; next }
    s { for (; b > 0; b--) print ""; print; next }
    $0 == ENVIRON["NH"] { s = 1; print; next }
    { print }
    END { if (s) print ENVIRON["NL"] }' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
}

# notes_tune <d-n> <tuning> <why> — completes the decision's Operator-case line (added by open).
notes_tune() {
  local f="$TD/runs/$RUN/teamlead-notes.md" p="- $1 " t="— tuning: pending"
  if grep -q "^- $1 .*— tuning: pending\$" "$f" 2>/dev/null; then
    NP="$p" NT="$t" NR="— tuning: $2 — $3" awk '
      BEGIN { p = ENVIRON["NP"]; t = ENVIRON["NT"]; r = ENVIRON["NR"] }
      index($0, p) == 1 && substr($0, length($0) - length(t) + 1) == t {
        $0 = substr($0, 1, length($0) - length(t)) r }
      { print }' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
  else
    notes_add "## Operator cases" "- $1 (answered) — tuning: $2 — $3"
  fi
}

# The dialog's recommended option goes first, its description marked; every other text is kept.
D_RECFIRST='def recfirst($r): (map(select(.label == $r)) | map(.description = ("Recommended — " + .label
  + (if (.description // "") == "" then "" else ". " + .description end)))) + map(select(.label != $r));'

# d_dialog <d-n> <ask|""> <kind> <dialog question> <options> <recommend> <gate> <notify> — the
# Operator's AskUserQuestion input of a new-path decision, built from the filed ask payload (never
# the shortened one-line summary); d_bad 2, nothing written, when it does not validate.
d_dialog() {
  local d="$1" ask="$2" kind="$3" dq="$4" opts="$5" rec="$6" j
  case "$kind" in permission|plan|question) ;; *)
    if [ -z "$opts" ]; then
      if [ "$8" = abandon_decision ]; then opts="continue|close"
      elif [ "$7" = plan ]; then opts="approve|revise|close"
      else d_bad 2 "decision open needs --options \"a|b\" (the Operator's dialog choices)"; fi
    fi ;;
  esac
  case "$kind" in
    permission|plan)
      # The target is what the Operator decides on: never cut (Bash the whole command, an MCP or
      # other tool its whole input).
      j="$(jq -c --arg d "$d" --arg a "$ask" --arg r "$rec" --arg k "$kind" "$D_RECFIRST"'
        .role as $role | .payload as $p | ($p.tool_name // "?") as $t | ($p.tool_input // {}) as $i
        | (if $t == "Bash" then ($i.command // "")
           elif ($t == "Edit" or $t == "Write" or $t == "NotebookEdit" or $t == "MultiEdit") then ($i.file_path // $i.notebook_path // "")
           elif $t == "WebFetch" then ($i.url // "")
           elif $t == "ExitPlanMode" then ((($i.plan // "") | split("\n") | map(select(test("\\S"))) | .[0] // "") + " (full plan: asks/\($a).json)")
           else ($i | tojson) end) as $target
        | {questions: [{question: "\($d) \($role): \($t) \($target)", header: $d, multiSelect: false,
            options: ([{label: "allow", description: (if $k == "plan" then "approve the plan as written" else "run it as asked" end)},
              {label: "deny", description: "type \"deny: <what instead>\" through Other"}] | recfirst($r))}]}' "$ASK_D/$ask.json")" ;;
    question)
      j="$(jq -c --arg d "$d" --arg r "$rec" "$D_RECFIRST"'
        .role as $role | (.payload.tool_input.questions // []) as $qs
        | {questions: [$qs | to_entries[] | .key as $k | .value
            | {question: ("\($d) " + (if ($qs | length) == 1 then "\($role): " else "" end) + .question),
               header: (if ($qs | length) == 1 then $d else (.header // "\($d)/\($k + 1)") end),
               multiSelect: (.multiSelect // false),
               options: ([(.options // [])[] | {label, description: (.description // "")}]
                 | if $k == 0 then recfirst($r) else . end)}]}' "$ASK_D/$ask.json")" ;;
    *)
      j="$(jq -cn --arg d "$d" --arg q "$dq" --arg o "$opts" --arg r "$rec" "$D_RECFIRST"'
        def desc: {continue: "keep the run going", close: "close the run without a merge",
          approve: "approve the plan", revise: "send the plan back for a revision",
          "more-revise": "grant one more plan revision past the limit"}[.] // "answer \(.)";
        {questions: [{question: "\($d) \($q)", header: $d, multiSelect: false,
          options: ([$o | split("|")[] | sub("^\\s+"; "") | sub("\\s+$"; "") | select(. != "")
            | {label: ., description: desc}] | recfirst($r))}]}')" ;;
  esac
  [ -n "$j" ] || d_bad 2 "the dialog of $d could not be built"
  jq -e --arg r "$rec" 'any(.questions[0].options[]; .label == $r)' <<<"$j" >/dev/null 2>&1 \
    || d_bad 2 "--recommend must name one of: $(jq -r '[.questions[0].options[].label] | sort | join("|")' <<<"$j")"
  jq -e '(.questions | length) >= 1 and (.questions | length) <= 4
    and all(.questions[]; (.options | length) >= 2 and (.options | length) <= 4
      and ((.header // "") | length) <= 12 and ((.options | map(.label) | unique | length) == (.options | length)))' \
    <<<"$j" >/dev/null 2>&1 \
    || d_bad 2 "the dialog of $d does not validate (1–4 questions, 2–4 distinct options each, a header of at most 12 characters)"
  printf '%s\n' "$j"
}

decision_open() {
  local src="" q="" opts="" rec="" notify=human_decision gate="" ask="" n f tmp v rel bind="" kind=""
  local reply="" reason="" new="" qgiven="" dq="" dialog=""
  while [ $# -gt 0 ]; do
    [ $# -ge 2 ] || usage
    case "$1" in
      --source) src="$2" ;; --question) q="$2" ;; --options) opts="$2" ;; --recommend) rec="$2" ;;
      --notify) notify="$2" ;; --gate) gate="$2" ;; --ask) ask="$2" ;;
      --reason) reason="$2" ;;
      *) usage ;;
    esac
    shift 2
  done
  team_lead_caller || d_bad 3 "only this run's TeamLead opens decisions"
  case "$reason" in ""|human-only|no-rule|lead-unsure|channel-failed|guard) ;;
    *) d_bad 2 "--reason human-only|no-rule|lead-unsure|channel-failed|guard" ;; esac
  case "$notify" in human_decision|abandon_decision) ;; *) d_bad 2 "--notify human_decision|abandon_decision" ;; esac
  case "$gate" in ""|plan) ;; *) d_bad 2 "--gate plan" ;; esac
  # The new path only for a lead the new runner launched: a reused older lead keeps its contract.
  ! jq -e '.ask_operator == true' "$TD/teamlead.json" >/dev/null 2>&1 || new=1
  qgiven="$q"
  if [ -n "$ask" ]; then
    ask_init "$TD" || d_bad 4 "no current run"
    ask_valid_id "$ask" && [ -f "$ASK_D/$ask.json" ] || d_bad 4 "no ask $ask in runs/$RUN/asks/"
    case "$(ask_state "$ask")" in waiting|timed-out) ;;
      *) d_bad 4 "ask $ask is $(ask_get "$ask" state), not open" ;; esac
    src="asks/$ask.json"; kind="$(ask_get "$ask" kind)"
    [ -n "$q" ] || q="$(ask_get "$ask" role): $(ask_one_line "$ask")"
    bind="bind_ask: $ask
bind_session_id: $(ask_get "$ask" session_id)
bind_attempt: $(ask_get "$ask" attempt)
ask_kind: $kind"
    case "$kind" in
      permission|plan) reply="reply: \"d-<n> allow\" | \"d-<n> deny: <what instead>\"" ;;
      *) if [ "$(jq -r '.payload.tool_input.questions // [] | length' "$ASK_D/$ask.json")" -gt 1 ]; then
           reply="reply: \"d-<n> $(d_reply_shape "$ask")\""
         else reply="reply: \"d-<n> <answer>\""; fi ;;
    esac
  fi
  [ -n "$src" ] && one_line "$q" || d_bad 2 "decision open needs --source and a one-line --question"
  [ -n "$reason" ] || reason="$(d_reason_default "$ask" "$gate" "$notify")"
  mkdir -p "$DD"
  n="$(ls "$DD" 2>/dev/null | sed -n 's/^d-\([0-9]*\)\.md$/\1/p' | sort -n | tail -n 1)"
  n=$(( ${n:-0} + 1 )); f="$DD/d-$n.md"; tmp="$DD/.d-$n.md.tmp"
  if [ -n "$new" ]; then
    [ -n "$rec" ] || d_bad 2 "decision open needs --recommend <one of the Operator's options>"
    dq="$q"
    if [ "$kind" = text ] && [ -z "$qgiven" ]; then
      dq="$(ask_get "$ask" role): $(jq -r '.payload.last_assistant_message // ""' "$ASK_D/$ask.json")"
    fi
    dialog="$(d_dialog "d-$n" "$ask" "$kind" "$dq" "$opts" "$rec" "$gate" "$notify")" || exit $?
  fi
  { echo "---"; echo "id: d-$n"; echo "status: pending"
    echo "stage: $(jq -r '.role // "-"' "$TD/session.json" 2>/dev/null || echo -)"
    echo "attempt: $(jq -r '.attempt // "-"' "$TD/session.json" 2>/dev/null || echo -)"
    echo "source: $src"; echo "created_at: $(team_utc)"; echo "notify: $notify"
    echo "touch_reason: $reason"
    [ -z "$gate" ] || echo "gate: $gate"
    [ -z "$bind" ] || printf '%s\n' "$bind"
    echo "---"; echo "## Question"; echo "$q"
    [ -z "$opts" ] || { echo; echo "## Options"; tr '|' '\n' <<<"$opts" | sed 's/^/- /'; }
    [ -z "$rec" ] || { echo; echo "## Recommendation"; echo "$rec"; }
    [ -z "$dialog" ] || { echo; echo "## Dialog"; echo "$dialog"; }
  } > "$tmp"
  [ ! -e "$f" ] || { rm -f "$tmp"; d_bad 1 "$f already exists"; }
  mv "$tmp" "$f"
  # From now on only the Operator's relay answers an escalated question or stop.
  if [ -n "$ask" ]; then
    case "$kind" in question|text)
      ask_lock && ask_set "$ask" '.requires_decision = $d' --arg d "d-$n"; ask_unlock ;;
    esac
  fi
  rel="${src#.agents/team/runs/"$RUN"/}"
  v="$( (cd "${TD%/.agents/team}" && bash "$LIB/team-verdict.sh" decision escalate --for "$rel" \
    --ref "$f" --notify "$notify" --message "d-$n: ${q:0:120}") )" \
    || d_bad 1 "decision d-$n written, but its escalate verdict was refused — see above"
  # The one-line question only, cut as in the verdict message — never a prompt or a file's content.
  notes_add "## Operator cases" "- d-$n ${q:0:120} — tuning: pending"
  echo "[d-$n] $q"
  [ -z "$reply" ] || echo "${reply//d-<n>/d-$n}"
  echo "file: $f"; echo "verdict: $v"
  [ -z "$dialog" ] || echo "ask-operator: $dialog"
}

# The Operator's message in the lead's own transcript: a typed user entry after created_at that is
# not a doorbell or a runner line, containing the answer text (an ask-bound reply: equal to it) →
# "<lead session> <uuid>[ legacy]". The session must be one the runner recorded for this run in the
# main checkout's anchor (team_lead_trusted, looked up from the checkout this script runs from);
# its config dir comes from there too. A message already used as another decision's evidence
# counts again only when it names this decision's id.
d_evidence() {
  local sid t f used="" x cfg leg="" uuid trust
  sid="$(jq -r '.session_id // empty' "$TD/teamlead.json" 2>/dev/null)"
  trust="$(cd "$LIB/../.." && pwd -P)"
  x="$(team_lead_trusted "$trust" "${TD%/.agents/team}" "$RUN" "$sid")" || return 3
  sid="$(cut -f1 <<<"$x")"; cfg="$(cut -f2 <<<"$x")"
  [ "$(cut -f3 <<<"$x")" != legacy ] || leg=" legacy"
  t="$(team_role_transcript "${TD%/.agents/team}" "${sid:--}" "$cfg")"
  [ "$t" != - ] && [ -f "$t" ] || return 1
  for f in "$DD"/d-*.md; do
    [ -f "$f" ] && [ "$f" != "$1" ] || continue
    used="$used $(dfm "$f" answered_via | sed -n 's/^teamlead-window //p')"
  done
  # A base without the matcher has no window evidence: the answer then needs the terminal.
  . "$LIB/team-evidence.sh" 2>/dev/null || return 1
  uuid="$(team_evidence_match "$t" "$2" "$(dfm "$1" created_at)" "$(basename "$1" .md)" "$used" "${3:-}")"
  [ -z "$uuid" ] || echo "$sid $uuid$leg"
}

# d_from_ask <file> <d-n> → "<session>\t<uuid>\t{reply, map}": the Operator's answer to the
# decision's own dialog in the current lead session's transcript. Only a session the anchor records
# (never the legacy teamlead.json fallback), whose launch snapshot is clean and still matches the
# registrations: any other AskUserQuestion hook could answer with no menu shown. The writer searches
# only the current session; an answer left in an earlier session is asked again after a relaunch.
d_from_ask() {
  local f="$1" id="$2" dlg sid trust clone x cfg t uuid r
  dlg="$(sed -n '/^## Dialog$/{n;p;q;}' "$f")"
  [ -n "$dlg" ] || d_bad 7 "$id was opened without a dialog — answer from the window or a terminal"
  . "$LIB/team-evidence.sh" 2>/dev/null && command -v team_evidence_provenance >/dev/null 2>&1 \
    || d_bad 7 "no dialog evidence — this checkout lacks the dialog reader; answer from a terminal"
  sid="$(jq -r '.session_id // empty' "$TD/teamlead.json" 2>/dev/null)"
  trust="$(cd "$LIB/../.." && pwd -P)"; clone="${TD%/.agents/team}"
  x="$(team_lead_trusted "$trust" "$clone" "$RUN" "$sid")" && [ -n "$x" ] && [ "$(cut -f3 <<<"$x")" != legacy ] \
    || d_bad 7 "no dialog evidence — the TeamLead session is not one the anchor records; answer from a terminal"
  sid="$(cut -f1 <<<"$x")"
  cfg="$(team_evidence_provenance "$trust" "$clone" "$RUN" "$sid")" \
    || d_bad 7 "no dialog evidence — $cfg; the Operator types the $id reply"
  t="$(team_role_transcript "$clone" "$sid" "$cfg")"
  uuid="$(team_evidence_dialog_find "$t" "$id" "$(dfm "$f" created_at)" "$dlg")"
  [ -n "$uuid" ] && r="$(team_evidence_dialog_read "$t" "$uuid" "$id" "$(dfm "$f" created_at)" "$dlg")" && [ -n "$r" ] \
    || d_bad 7 "no AskUserQuestion answer for $id after $(dfm "$f" created_at) matching its dialog"
  printf '%s\t%s\t%s\n' "$sid" "$uuid" "$r"
}

decision_answer() {
  local id="${1:-}" text="" outcome="" tuning="" why="" f how ev c fromask="" uuid="" r esid=""
  [ -n "$id" ] || usage; shift
  while [ $# -gt 0 ]; do
    [ "$1" != --from-ask ] || { fromask=1; shift; continue; }
    [ $# -ge 2 ] || usage
    case "$1" in --text) text="$2" ;; --outcome) outcome="$2" ;; --tuning) tuning="$2" ;;
      --why) why="$2" ;; *) usage ;; esac
    shift 2
  done
  if [ -n "$fromask" ]; then
    [ -z "$text" ] || d_bad 2 "decision answer takes --text or --from-ask, not both"
  else
    one_line "$text" || d_bad 2 "decision answer needs a one-line --text (or --from-ask)"
  fi
  case "$outcome" in ""|continue|close|more-revise|approve|allow|deny) ;;
    *) d_bad 2 "--outcome continue|close|more-revise|approve|allow|deny" ;; esac
  case "$tuning" in ""|rule|TeamLead|none) ;; *) d_bad 2 "--tuning rule|TeamLead|none" ;; esac
  # The tuning question (could a rule or the TeamLead have covered this?) is the lead's to answer.
  if team_lead_caller; then
    [ -n "$tuning" ] && one_line "$why" || d_bad 2 "the TeamLead records an answer with --tuning rule|TeamLead|none --why \"<line>\""
  fi
  [ -z "$tuning" ] || one_line "$why" || d_bad 2 "--tuning needs a one-line --why"
  f="$(d_file "$id")"
  if [ -n "$fromask" ]; then
    # "<session>\t<uuid>\t{reply, map}" of the Operator's dialog answer, or d_bad 7.
    r="$(d_from_ask "$f" "$id")" || exit $?
    esid="$(cut -f1 <<<"$r")"; uuid="$(cut -f2 <<<"$r")"; r="$(cut -f3- <<<"$r")"
    text="$(jq -r .reply <<<"$r")"
  fi
  # Trimmed once, so a padded verbatim reply reads the same here and in the hook.
  text="$(jq -rn --arg m "$text" '$m | sub("^\\s+"; "") | sub("\\s+$"; "")')"
  [ -n "$fromask" ] || one_line "$text" || d_bad 2 "decision answer needs a one-line --text"
  local ask kind p po aval="" amap="" nq ans labels
  ask="$(dfm "$f" bind_ask)"
  if [ -n "$ask" ]; then
    # The Operator's reply names the decision, so two pending decisions never share one reply.
    case "$text" in "$id "*) ;; *) d_bad 7 "reply must start with \"$id \"" ;; esac
    kind="$(dfm "$f" ask_kind)"
    ask_init "$TD" || d_bad 4 "no current run"
    nq="$(jq -r '.payload.tool_input.questions // [] | length' "$ASK_D/$ask.json" 2>/dev/null)"
    if [ -n "$fromask" ] && [ "${nq:-0}" -gt 1 ]; then
      # Several questions: the dialog's structured answers as they are, never a text round-trip,
      # so a ";" or ":" inside an answer survives.
      amap="$(jq -cS 'select(type == "object") | .map // empty' <<<"$r")"
      jq -e --slurpfile a "$ASK_D/$ask.json" '(keys | sort) == ($a[0].payload.tool_input.questions | map(.question) | sort)
        and all(.[]; type == "string" and length > 0)' <<<"${amap:-null}" >/dev/null 2>&1 \
        || d_bad 7 "the dialog answer of $id does not answer every question of $ask"
      [ -z "$outcome" ] || d_bad 7 "--outcome does not apply to a $kind ask"
      p='{"outcome":"","value":"","map":null}'
    # ask_parse_reply is the hook's parser too: a reply it refuses is never recorded as answered.
    elif ! p="$(ask_parse_reply "$ask" "$id" "$text")"; then
      case "$kind" in
        permission|plan) d_bad 7 "reply must read $id allow|deny" ;;
        *) d_bad 7 "reply must read $id $(if [ "$(jq -r '.payload.tool_input.questions // [] | length' "$ASK_D/$ask.json" 2>/dev/null)" -gt 1 ]; then d_reply_shape "$ask"; else echo '<answer>'; fi)" ;;
      esac
    fi
    po="$(jq -r .outcome <<<"$p")"
    if [ -n "$po" ]; then
      [ -n "$outcome" ] || outcome="$po"
      [ "$outcome" = "$po" ] || d_bad 7 "the reply reads $po, not --outcome $outcome"
    else
      [ -z "$outcome" ] || d_bad 7 "--outcome does not apply to a $kind ask"
    fi
    aval="$(jq -r .value <<<"$p")"; [ -n "$amap" ] || amap="$(jq -c '.map // empty' <<<"$p")"
  elif [ -n "$fromask" ]; then
    ans="${text#"$id "}"
    labels="$(sed -n '/^## Dialog$/{n;p;q;}' "$f" | jq -r '.questions[0].options[].label' 2>/dev/null)"
    if [ "$(dfm "$f" gate)" = plan ] || [ "$(dfm "$f" notify)" = abandon_decision ]; then
      # A control decision acts on its label alone: a free text could read as any outcome.
      grep -qxF -- "$ans" <<<"$labels" \
        || d_bad 7 "a free-text answer to a control decision is not recorded — the decision stays pending; ask again with the options"
    fi
    aval="$ans"
    case "$ans" in
      continue|close|more-revise|approve)
        if grep -qxF -- "$ans" <<<"$labels"; then
          [ -n "$outcome" ] || outcome="$ans"
          [ "$outcome" = "$ans" ] || d_bad 7 "the Operator chose $ans, not --outcome $outcome"
        fi ;;
    esac
    [ -z "$outcome" ] || [ "$outcome" = "$ans" ] || d_bad 7 "--outcome $outcome does not fit the Operator's free-text answer"
  fi
  if [ "$(dfm "$f" status)" = withdrawn ]; then
    notes_add "## Late answers" "- $id (withdrawn $(dfm "$f" withdrawn_at)): ${text:0:120}"
  fi
  [ "$(dfm "$f" status)" = pending ] || d_bad 4 "$id is $(dfm "$f" status), not pending — nothing applied"
  if [ -n "$fromask" ]; then
    how="teamlead-ask $uuid"
  elif [ -t 0 ] && [ -r /dev/tty ]; then
    printf 'Operator answer to %s: %s\nconfirm by typing %s: ' "$id" "$text" "$id" > /dev/tty
    IFS= read -r c < /dev/tty || c=""
    [ "$c" = "$id" ] || d_bad 7 "not confirmed — nothing applied"
    how="terminal"
  else
    local erc=0
    if [ -n "$ask" ]; then ev="$(d_evidence "$f" "$text" exact)" || erc=$?
    else ev="$(d_evidence "$f" "$text")" || erc=$?; fi
    [ "$erc" != 3 ] || d_bad 7 "the TeamLead session is not one the runner recorded — answer from a terminal"
    [ -n "$ev" ] || d_bad 7 "no Operator message in the TeamLead window after $(dfm "$f" created_at) contains this answer — answer from a terminal, or relay the Operator's own words"
    # "<session> <uuid>[ legacy]": a legacy pair came from teamlead.json, so no answered_session.
    set -- $ev; esid="$1"; how="teamlead-window $2"; [ "${3:-}" != legacy ] || esid=""
  fi
  dfm_set "$f" status answered; dfm_set "$f" answered_at "$(team_utc)"; dfm_set "$f" answered_via "$how"
  [ -z "${esid:-}" ] || dfm_set "$f" answered_session "$esid"
  [ -z "$outcome" ] || dfm_set "$f" answer_outcome "$outcome"
  if [ -n "$ask" ] || [ -n "$fromask" ]; then
    [ -z "$aval" ] || dfm_set "$f" answer_value "$aval"
    [ -z "$amap" ] || dfm_set "$f" answer_map "$amap"
  fi
  echo "$(team_utc) decision $id" >> "$TD/runs/$RUN/operator-touches"
  d_touch_log "$f" "$id" "$ask" "${kind:-}" "$outcome" "$aval" "${rest:-}" "$text"
  printf '\n## Answer\n%s\n' "$text" >> "$f"
  [ -z "$tuning" ] || notes_tune "$id" "$tuning" "$why"
  d_resolve "$f"
  echo "answered: $id${outcome:+ ($outcome)} via ${how%% *}"
}

decision_withdraw() {
  local id="${1:-}" why="" f
  [ -n "$id" ] || usage; shift
  [ $# -eq 2 ] && [ "$1" = --why ] && one_line "$2" || usage; why="$2"
  team_lead_caller || d_bad 3 "only this run's TeamLead withdraws decisions"
  f="$(d_file "$id")"
  [ "$(dfm "$f" status)" = pending ] || d_bad 4 "$id is $(dfm "$f" status), not pending"
  dfm_set "$f" status withdrawn; dfm_set "$f" withdrawn_at "$(team_utc)"
  printf '\n## Withdrawn\n%s\n' "$why" >> "$f"
  d_resolve "$f"
  echo "withdrawn: $id"
}

decision_list() {
  local f st
  for f in "$DD"/d-*.md; do
    [ -f "$f" ] || continue
    st="$(dfm "$f" status)"
    [ "${1:-}" != --pending ] || [ "$st" = pending ] || continue
    echo "$(dfm "$f" id) $st — $(sed -n '/^## Question$/{n;p;q;}' "$f")"
  done | sort -t- -k2,2n
}

decision_main() {  # decision_main <op> <team> …
  local op="${1:-}"; shift || true
  [ $# -ge 1 ] || usage
  resolve "$1"; shift
  [ -n "$RUN" ] || d_bad 4 "no current run"
  DD="$TD/runs/$RUN/decisions"
  case "$op" in
    open) decision_open "$@" ;; answer) decision_answer "$@" ;;
    withdraw) decision_withdraw "$@" ;; list) decision_list "$@" ;; *) usage ;;
  esac
}
