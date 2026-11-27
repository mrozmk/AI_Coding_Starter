#!/usr/bin/env bash
# Pending human decisions of the per-run TeamLead: runs/<run>/decisions/d-<n>.md. Sourced by
# team-lead.sh after resolve (TD, RUN, MAIN, LIB set), never executed. Bash 3.2.
#   decision open <team> --source <run file|attention:<n>> --question "<text>" [--options "<a|b>"]
#     [--recommend "<text>"] [--notify human_decision|abandon_decision] [--gate plan]
#     [--reason human-only|no-rule|lead-unsure|channel-failed|guard]
#   decision open <team> --ask a-<n> [--question "<text>"] [--options "<a|b>"] [--recommend "<text>"]
#     [--reason human-only|no-rule|lead-unsure|channel-failed|guard]
#     (an operator-tier ask, or a workflow human gate in a question: bound to the ask; --question
#     is also the neutral dialog text of a single-question ask whose own text argues for an option)
#   decision answer <team> d-<n> --text "<Operator answer>" | --from-ask
#     [--outcome continue|close|more-revise|approve|allow|deny]
#     [--tuning rule|TeamLead|none --why "<line>"]   (both required when the lead records the answer)
#   decision relay <team> d-<n> --text "<team> d-<n> <reply>"   (the Supervisor, main checkout)
#   decision answer <team> d-<n> --delegated --run <run> --ask a-<n> --attempt <n> --session <sid>
#     --request <digest> --mandate m-<uuid> --class <class> --text "d-<n> <reply>" --why "<line>"
#   decision handback <team> d-<n> --why "<line>"     (both: the Supervisor, main checkout)
#   decision withdraw <team> d-<n> --why "<line>"     decision list <team> [--pending]
#   decision open <team> --batch <file> [--question "<line>"] [--recommend allow|deny] [--source …]
#     (#322: an Operator decision of kind batch — team_batch.py prepare copies the entries into
#     decisions/d-<n>.batch.json, its sha256 goes into batch_sha256 and the rendered entries into
#     the question and the dialog; the reply `d-<n> allow|deny` (d_batch_reply) sets answer_outcome;
#     each entry then answers its exact request once, team-ask-hook.sh)
#   decision revoke <team> d-<n> --why "<line>"       (lead or Supervisor: an answered batch grants no more)
# Delegation (team-mandate.sh, team-lead.md §7): open marks an ask-bound decision whose class the
# Operator's mandate covers `delegate: supervisor` and files it in the Supervisor's inbox; the
# runner holds its Operator notification while that stands. answer --delegated records the
# Supervisor's own answer as `answered_via: supervisor-delegated <uuid>` — never the Operator's:
# no operator touch, no touch-log entry, no dialog evidence — pinned once in
# <main>/.agents/team/delegated/<team>-<run>-d-<n>.json and re-verified by the stage hook.
# handback returns a delegated decision to the Operator.
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
# relay: the Operator typed `<team> d-<n> <reply>` in the Supervisor window; the Supervisor passes
# that exact message. It must be the newest such message in the Supervisor's own transcript (typed,
# no machine or [peer] line, after the decision opened and never before the run started); the
# answer is recorded as answer would (answered_via: supervisor-window <uuid>, relayed_by,
# relayed_session), pinned once in <main>/.agents/team/relays/<team>-<run>-d-<n>.json, and the lead
# is rung to apply it. A run whose lead prompt predates the relay is refused (answer in its window).
# Every decision write takes the run's ask lock (team-ask.sh ask_lock), as the runner's do.

dfm() { sed -n '/^---$/,/^---$/p' "$1" | sed -n "s/^$2: *//p" | head -n 1; }
dfm_set() {  # dfm_set <file> <key> <value> — replace or add one frontmatter key, atomically
  # ENVIRON, not -v: awk -v expands backslash escapes, so `C:\tmp` or `\"` would be mangled.
  FM_K="$2" FM_V="$3" awk '/^---$/ { n++; if (n == 2 && !done) print ENVIRON["FM_K"] ": " ENVIRON["FM_V"]; print; next }
    n == 1 && index($0, ENVIRON["FM_K"] ": ") == 1 { print ENVIRON["FM_K"] ": " ENVIRON["FM_V"]; done = 1; next } { print }' "$1" > "$1.tmp"
  mv "$1.tmp" "$1"
}
d_bad() { echo "error: $2" >&2; exit "$1"; }
# d_batch_reply <d-n> <text> → allow | deny (rc 0): the one reply of a batch decision, keyed by its
# id — exactly `d-<n> allow` or `d-<n> deny[: …]`; rc 1 for anything else (another decision too).
d_batch_reply() {
  local t; t="$(jq -rn --arg m "$2" '$m | sub("^\\s+"; "") | sub("\\s+$"; "")')"
  case "$t" in "$1 allow") echo allow ;; "$1 deny"|"$1 deny:"*) echo deny ;; *) return 1 ;; esac
}
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
# d_touch_log <file> <d-n> <ask> <ask kind> <outcome> <answer value> <reply rest> <text>
# [<relay session>] — the answered decision as one entry of the project's touch log (a relayed one
# names the Supervisor and its session); a failure warns, the answer stands.
d_touch_log() {
  local f="$1" kind=decision ans c a ws="" stage inp=()
  # A bound permission ask: its masked tool input goes into the entry (operator-touches.md → input).
  [ -n "$3" ] && [ "$4" = permission ] && [ -f "$ASK_D/$3.json" ] && inp=(--input-file "$ASK_D/$3.json")
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
    --answer "$ans" ${ws:+--wait-s "$ws"} ${9:+--relayed-by Supervisor --relayed-session "$9"} \
    ${inp[@]+"${inp[@]}"} >/dev/null 2>&1 || echo "warn: touch not recorded ($2)" >&2
}

# d_record <file> <d-n> <how> <outcome> <answer value> <answer map> <text> [<answered session>]
# [<relay session>] — publish the answered decision in one rename: the question part kept, every
# status/answered_*/answer_*/relayed_* key and any ## Answer body rewritten from the arguments, so
# `status: answered` never appears without its fields. The caller holds the ask lock.
d_record() {
  local tmp="$DD/.$2.md.rec.$$"
  R_HOW="$3" R_OUT="$4" R_VAL="$5" R_MAP="$6" R_TXT="$7" R_ES="${8:-}" R_RS="${9:-}" R_AT="$(team_utc)" awk '
    function e(k, v) { if (v != "") print k ": " v }
    /^---$/ && fm < 2 { fm++
      if (fm == 2) { print "status: answered"; e("answered_at", ENVIRON["R_AT"]); e("answered_via", ENVIRON["R_HOW"])
        e("answered_session", ENVIRON["R_ES"]); e("answer_outcome", ENVIRON["R_OUT"])
        e("answer_value", ENVIRON["R_VAL"]); e("answer_map", ENVIRON["R_MAP"])
        if (ENVIRON["R_RS"] != "") { print "relayed_by: Supervisor"; e("relayed_session", ENVIRON["R_RS"]) } }
      print; next }
    fm == 1 && /^(status|answered_[a-z_]*|answer_[a-z_]*|relayed_[a-z_]*):/ { next }
    fm == 2 && /^## Answer$/ { skip = 1; next }
    skip && /^## / { skip = 0 }
    skip { next }
    { print }
    END { printf "\n## Answer\n%s\n", ENVIRON["R_TXT"] }' "$1" > "$tmp" && mv "$tmp" "$1" \
    || { rm -f "$tmp"; return 1; }
}

# d_record_post <file> <d-n> <ask> <ask kind> <outcome> <answer value> <reply rest> <text>
# [<relay session>] — after the lock: the Operator touch, the touch-log entry, the notification resolved.
d_record_post() {
  echo "$(team_utc) decision $2" >> "$TD/runs/$RUN/operator-touches"
  d_touch_log "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8" "${9:-}"
  d_resolve "$1"
}

# d_lock — the run's ask lock (one lock for its asks and decisions); exit 4 when it cannot be taken.
d_lock() { ask_init "$TD" && ask_lock || d_bad 4 "cannot take the ask lock of run $RUN"; }
# d_ask_state <a-n> — ask_state for a caller holding the lock (ask_state takes it, not reentrant).
d_ask_state() { [ ! -f "$ASK_D/$1.json" ] || ask_reconcile "$1"; ask_get "$1" state; }
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
# A stage question carries one recommendation, the lead's: the option goes first with the label
# suffix; the stage's own markers are stripped (ASK_LABEL_JQ unrec) and its pitch is attributed.
D_REC_SUFFIX=' (Recommended)'
D_RECQ='def recq($r; $s): (map(select(.label == $r)) | map(.label += $s)) + map(select(.label != $r));
  def marked: test("[\\[(]\\s*recommended\\s*[\\])]"; "i");'

# d_dialog <d-n> <ask|""> <kind> <dialog question> <options> <recommend> <gate> <notify>
# [<neutral question>] — the Operator's AskUserQuestion input of a new-path decision, built from
# the filed ask payload (never the shortened one-line summary); d_bad 2, nothing written, when it
# does not validate. The neutral question is the lead's own --question of a single-question ask.
d_dialog() {
  local d="$1" ask="$2" kind="$3" dq="$4" opts="$5" rec="$6" gate="$7" notify="$8" nq="${9:-}" j
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
      # One recommendation, the lead's: stage markers leave the labels, the text after the question
      # that argues for an option (or, with a neutral --question, the stage's whole text) moves to
      # a "<stage> recommends: …" line, and only the lead's option gets the suffix.
      j="$(jq -c --arg d "$d" --arg r "$rec" --arg nq "$nq" --arg s "$D_REC_SUFFIX" "$ASK_LABEL_JQ$D_RECQ"'
        .role as $role | (.payload.tool_input.questions // []) as $qs
        | [$qs | to_entries[] | .key as $k | .value as $q
            | (if $nq != "" and ($qs | length) == 1 then {h: $nq, p: ($q.question // "")}
               else (($q.question // "") | pitchcut) end) as $c
            | [($q.options // [])[] | .label | select(unrec != .) | unrec] as $m
            | (if $c.p == "" and ($m | length) == 0 then ""
               else "\n\n\($role) "
                 + (if ($m | length) > 0 or ($c.p | argues) then "recommends: " else "adds: " end)
                 + ([($m | join(" / ")), $c.p] | map(select(. != "")) | join(" — ")) end) as $line
            | {head: $c.h,
               q: {question: ("\($d) " + (if ($qs | length) == 1 then "\($role): " else "" end) + $c.h + $line),
                 header: (if ($qs | length) == 1 then $d else ($q.header // "\($d)/\($k + 1)") end),
                 multiSelect: ($q.multiSelect // false),
                 options: ([($q.options // [])[] | {label: (.label | unrec), description: (.description // "")}]
                   | if $k == 0 then recq($r; $s) else . end)}}]
        | {questions: map(.q), heads: map(.head)}' "$ASK_D/$ask.json")" ;;
    *)
      if [ -z "$opts" ]; then
        if [ "$notify" = abandon_decision ]; then opts="continue|close"
        elif [ "$gate" = plan ]; then opts="approve|revise|close"
        else d_bad 2 "decision open needs --options \"a|b\" (the Operator's dialog choices)"; fi
      fi
      j="$(jq -cn --arg d "$d" --arg q "$dq" --arg o "$opts" --arg r "$rec" "$D_RECFIRST"'
        def desc: {continue: "keep the run going", close: "close the run without a merge",
          approve: "approve the plan", revise: "send the plan back for a revision",
          "more-revise": "grant one more plan revision past the limit"}[.] // "answer \(.)";
        {questions: [{question: "\($d) \($q)", header: $d, multiSelect: false,
          options: ([$o | split("|")[] | sub("^\\s+"; "") | sub("\\s+$"; "") | select(. != "")
            | {label: ., description: desc}] | recfirst($r))}]}')" ;;
  esac
  [ -n "$j" ] || d_bad 2 "the dialog of $d could not be built"
  if [ "$kind" = question ]; then
    jq -e --arg r "$rec$D_REC_SUFFIX" 'any(.questions[0].options[]; .label == $r)' <<<"$j" >/dev/null 2>&1 \
      || d_bad 2 "--recommend must name one of: $(jq -r '[.questions[0].options[].label] | sort | join("|")' <<<"$j")"
    # The rendered dialog, before anything is written or notified: exactly one recommended option
    # — the lead's, first — and a single question's text no longer argues for one.
    jq -e --arg r "$rec$D_REC_SUFFIX" "$D_RECQ"'
      ([.questions[].options[].label | select(marked)] == [$r]) and .questions[0].options[0].label == $r' \
      <<<"$j" >/dev/null 2>&1 \
      || d_bad 2 "the dialog of $d must carry exactly one recommended option, the lead's, first — its labels: $(jq -r '[.questions[].options[].label] | join("|")' <<<"$j")"
    jq -e "$ASK_LABEL_JQ"'all(.heads[]; argues | not)' <<<"$j" >/dev/null 2>&1 \
      || d_bad 2 "a question text of $ask argues for an option — $(if [ "$(jq -r '.heads | length' <<<"$j")" = 1 ]; then
        echo "pass a neutral one-line --question (the stage's own text moves to its \"recommends:\" line)"
      else echo "several questions take no --question: answer the ask with --text, asking the stage to ask again with the question text free of a recommendation"; fi)"
    j="$(jq -c 'del(.heads)' <<<"$j")"
  else
    jq -e --arg r "$rec" 'any(.questions[0].options[]; .label == $r)' <<<"$j" >/dev/null 2>&1 \
      || d_bad 2 "--recommend must name one of: $(jq -r '[.questions[0].options[].label] | sort | join("|")' <<<"$j")"
  fi
  jq -e '(.questions | length) >= 1 and (.questions | length) <= 4
    and all(.questions[]; (.options | length) >= 2 and (.options | length) <= 4
      and ((.header // "") | length) <= 12 and ((.options | map(.label) | unique | length) == (.options | length)))' \
    <<<"$j" >/dev/null 2>&1 \
    || d_bad 2 "the dialog of $d does not validate (1–4 questions, 2–4 distinct options each, a header of at most 12 characters)"
  printf '%s\n' "$j"
}

# d_lead_knows <marker> — the newest lead prompt of the run carries that rule (a lead launched
# before a rule existed cannot apply an answer that depends on it).
d_lead_knows() {
  local rd="$TD/runs/$RUN" pl
  pl="$(ls "$rd" 2>/dev/null | sed -n 's/^lead-\([0-9]*\)\.prompt\.md$/\1/p' | sort -n | tail -n 1 || true)"
  [ -n "$pl" ] && grep -q "$1" "$rd/lead-$pl.prompt.md" 2>/dev/null
}

# d_route <a-n> <touch reason> → "<class>\t<mandate id>" when the Operator's mandate in force
# covers a decision on that ask; rc 1 otherwise (no mandate, no class, an older lead) — the
# decision then goes to the Operator as before.
d_route() {
  local c m
  [ -n "$1" ] && [ -n "${MAIN:-}" ] && command -v mandate_ask_class >/dev/null 2>&1 || return 1
  d_lead_knows 'Delegated to the Supervisor' || return 1
  # An ask the Supervisor handed back is the Operator's for good.
  [ -z "$(ask_get "$1" no_delegate)" ] || return 1
  c="$(mandate_ask_class "$MAIN" "${TD%/.agents/team}" "$ASK_D/$1.json" "$2")"
  [ -n "$c" ] || return 1
  m="$(mandate_covers "$MAIN" "$c" "$(jq -r .team "$TD/team.json")" "$RUN")" && [ -n "$m" ] || return 1
  printf '%s\t%s\n' "$c" "$m"
}

decision_open() {
  local src="" q="" opts="" rec="" notify=human_decision gate="" ask="" n f tmp v rel bind="" kind=""
  local reply="" reason="" new="" qgiven="" dq="" dialog="" dl="" dcls="" dman="" batch="" bo="" bsha="" block=""
  while [ $# -gt 0 ]; do
    [ $# -ge 2 ] || usage
    case "$1" in
      --source) src="$2" ;; --question) q="$2" ;; --options) opts="$2" ;; --recommend) rec="$2" ;;
      --notify) notify="$2" ;; --gate) gate="$2" ;; --ask) ask="$2" ;;
      --reason) reason="$2" ;; --batch) batch="$2" ;;
      *) usage ;;
    esac
    shift 2
  done
  team_lead_caller || d_bad 3 "only this run's TeamLead opens decisions"
  if [ -n "$batch" ]; then
    [ -z "$ask$gate" ] || d_bad 2 "--batch goes without --ask and --gate"
    [ -f "$batch" ] || d_bad 2 "no batch file $batch"
    kind=batch; opts="${opts:-allow|deny}"; [ "$opts" = "allow|deny" ] || d_bad 2 "a batch's options are allow|deny"
    [ -n "$q" ] || q="batch of $(jq -r '.entries | length' "$batch" 2>/dev/null || echo '?') network operations — allow each once?"
    src="${src:-batch}"
  fi
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
    # An answer stored for this ask (a relay whose ring was lost) is applied, never asked again.
    for v in "$DD"/d-*.md; do
      if [ -f "$v" ] && [ "$(dfm "$v" bind_ask)" = "$ask" ] && [ "$(dfm "$v" status)" = answered ]; then
        d_bad 4 "$(dfm "$v" id) already answers ask $ask — relay it"
      fi
    done
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
  if [ -n "$batch" ]; then
    # The stored copy is the decision's own, validated before anything is published.
    d_lock
    bo="$(python3 -I "$LIB/team_batch.py" prepare --file "$batch" --project "${TD%/.agents/team}" \
      --out-dir "$DD" --id "d-$n" 2> "$DD/.d-$n.batch.err")" \
      || { v="$(cat "$DD/.d-$n.batch.err" 2>/dev/null)"; rm -f "$DD/.d-$n.batch.err"; ask_unlock; d_bad 3 "${v:-the batch was refused}"; }
    rm -f "$DD/.d-$n.batch.err"; ask_unlock
    bsha="$(sed -n 's/^sha256: //p' <<<"$bo")"; block="$(sed '/^sha256: /d' <<<"$bo")"
    [ -n "$bsha" ] || d_bad 1 "the batch copy has no sha256"
    [ "$src" != batch ] || src="decisions/d-$n.batch.json"
  fi
  if [ -n "$new" ]; then
    [ -n "$rec" ] || d_bad 2 "decision open needs --recommend <one of the Operator's options>"
    dq="$q"
    [ "$kind" != batch ] || dq="$q"$'\n'"$block"
    if [ "$kind" = text ] && [ -z "$qgiven" ]; then
      dq="$(ask_get "$ask" role): $(jq -r '.payload.text // ""' "$ASK_D/$ask.json")"
    fi
    # A stage question is recommended by its clean label; ## Recommendation stores that one.
    [ "$kind" != question ] || rec="$(jq -rn --arg r "$rec" "$ASK_LABEL_JQ"'$r | unrec')"
    dialog="$(d_dialog "d-$n" "$ask" "$kind" "$dq" "$opts" "$rec" "$gate" "$notify" "$qgiven")" || exit $?
  fi
  # A class the Operator's mandate covers goes to the Supervisor first (never a gate or an
  # abandon decision: those have no ask to bind the answer to).
  if dl="$(d_route "$ask" "$reason")"; then dcls="${dl%%$'\t'*}"; dman="${dl#*$'\t'}"; fi
  { echo "---"; echo "id: d-$n"; echo "status: pending"
    echo "stage: $(jq -r '.role // "-"' "$TD/session.json" 2>/dev/null || echo -)"
    echo "attempt: $(jq -r '.attempt // "-"' "$TD/session.json" 2>/dev/null || echo -)"
    echo "source: $src"; echo "created_at: $(team_utc)"; echo "notify: $notify"
    echo "touch_reason: $reason"
    [ -z "$dcls" ] || { echo "delegate: supervisor"; echo "delegate_class: $dcls"; echo "delegate_mandate: $dman"; }
    [ -z "$gate" ] || echo "gate: $gate"
    [ -z "$bind" ] || printf '%s\n' "$bind"
    [ -z "$batch" ] || { echo "kind: batch"; echo "batch_sha256: $bsha"; }
    echo "---"; echo "## Question"; echo "$q"
    [ -z "$batch" ] || { echo; echo "$block"; }
    [ -z "$opts" ] || { echo; echo "## Options"; tr '|' '\n' <<<"$opts" | sed 's/^/- /'; }
    [ -z "$rec" ] || { echo; echo "## Recommendation"; echo "$rec"; }
    [ -z "$dialog" ] || { echo; echo "## Dialog"; echo "$dialog"; }
  } > "$tmp"
  if [ -n "$ask" ] && [ "$kind" = permission ]; then
    # #322: one locked section with the lead's own egress deny (team-answer.sh) — the ask still
    # open and unanswered, then the decision published.
    d_lock
    case "$(d_ask_state "$ask")" in waiting|timed-out) ;;
      *) ask_unlock; rm -f "$tmp"; d_bad 4 "ask $ask is $(ask_get "$ask" state), not open" ;; esac
    [ ! -e "$ASK_D/$ask.answer.json" ] || { ask_unlock; rm -f "$tmp"; d_bad 4 "ask $ask is already answered"; }
    [ ! -e "$f" ] || { ask_unlock; rm -f "$tmp"; d_bad 1 "$f already exists"; }
    mv "$tmp" "$f"; ask_unlock
  else
    [ ! -e "$f" ] || { rm -f "$tmp"; d_bad 1 "$f already exists"; }
    mv "$tmp" "$f"
  fi
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
  # The Supervisor's inbox instead of the Operator: a message that cannot be filed hands the
  # decision straight back, so it is never left waiting on nobody.
  if [ -n "$dcls" ]; then
    if ! bash "$MAIN/.claude/lib/team-inbox.sh" --main "$MAIN" write Supervisor delegated \
        --from "$(jq -r .team "$TD/team.json")" --ticket "$(jq -r '.ticket // ""' "$TD/team.json")" \
        --run "$RUN" --ref "$f" --message "d-$n [$dcls, mandate $dman]: ${q:0:120} — answer, from the main checkout, as one standalone command: bash .claude/lib/team-lead.sh $(team_delegate_args "$(jq -r .team "$TD/team.json")" "d-$n" "$RUN" "$ask" "$(ask_get "$ask" attempt)" "$(ask_get "$ask" session_id)" "$(d_request_digest "$ASK_D/$ask.json")" "d-$n <reply>" "$dman" "$dcls")<line>\"" >/dev/null 2>&1; then
      dfm_set "$f" delegate lapsed; dcls=""
    fi
  fi
  echo "[d-$n] $q"
  [ -z "$reply" ] || echo "${reply//d-<n>/d-$n}"
  echo "file: $f"; echo "verdict: $v"
  if [ -n "$dcls" ]; then
    echo "delegated: d-$n — to the Supervisor under the Operator's mandate $dman (class $dcls); raise no dialog, wait for \"relayed: d-$n\""
  else
    [ -z "$dialog" ] || echo "ask-operator: $dialog"
  fi
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
    || d_bad 7 "no dialog evidence — $cfg. Ask for no typed reply: the Operator answers from a terminal — print this as a line to copy: $(team_evidence_terminal "$(jq -r .team "$TD/team.json")" "$f" "$id") (fix: $(team_evidence_fix "$cfg"))"
  t="$(team_role_transcript "$clone" "$sid" "$cfg")"
  uuid="$(team_evidence_dialog_find "$t" "$id" "$(dfm "$f" created_at)" "$dlg")"
  [ -n "$uuid" ] && r="$(team_evidence_dialog_read "$t" "$uuid" "$id" "$(dfm "$f" created_at)" "$dlg")" && [ -n "$r" ] \
    || d_bad 7 "no AskUserQuestion answer for $id after $(dfm "$f" created_at) matching its dialog"
  printf '%s\t%s\t%s\n' "$sid" "$uuid" "$r"
}

decision_answer() {
  local id="${1:-}" text="" outcome="" tuning="" why="" f how ev c fromask="" uuid="" r esid=""
  local delegated="" drun="" dask="" datt="" dsess="" dreq="" dmand="" dclass=""
  [ -n "$id" ] || usage; shift
  while [ $# -gt 0 ]; do
    [ "$1" != --from-ask ] || { fromask=1; shift; continue; }
    [ "$1" != --delegated ] || { delegated=1; shift; continue; }
    [ $# -ge 2 ] || usage
    case "$1" in --text) text="$2" ;; --outcome) outcome="$2" ;; --tuning) tuning="$2" ;;
      --why) why="$2" ;; --run) drun="$2" ;; --ask) dask="$2" ;; --attempt) datt="$2" ;;
      --session) dsess="$2" ;; --request) dreq="$2" ;; --mandate) dmand="$2" ;; --class) dclass="$2" ;;
      *) usage ;; esac
    shift 2
  done
  if [ -n "$delegated" ]; then
    # The Supervisor's own answer under the Operator's mandate: its own path, none of the
    # Operator's evidence forms.
    [ -z "$fromask$outcome$tuning" ] || d_bad 2 "decision answer --delegated takes only its bindings, --text and --why"
    decision_delegated "$id" "$text" "$why" "$drun" "$dask" "$datt" "$dsess" "$dreq" "$dmand" "$dclass"; return
  fi
  [ -z "$drun$dask$datt$dsess$dreq$dmand$dclass" ] || d_bad 2 "--run, --ask, --attempt, --session, --request, --mandate and --class go with --delegated"
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
    r="$(d_from_ask "$f" "$id")" || exit $?
    esid="$(cut -f1 <<<"$r")"; uuid="$(cut -f2 <<<"$r")"; r="$(cut -f3- <<<"$r")"
    text="$(jq -r .reply <<<"$r")"
  fi
  # Trimmed once, so a padded verbatim reply reads the same here and in the hook.
  text="$(jq -rn --arg m "$text" '$m | sub("^\\s+"; "") | sub("\\s+$"; "")')"
  # A multi-line dialog answer would not survive the one-line frontmatter: nothing is written.
  if [ -n "$fromask" ]; then
    one_line "$text" || d_bad 7 "the dialog answer of $id spans several lines — the decision stays pending; ask again, or the Operator types the $id reply"
  else
    one_line "$text" || d_bad 2 "decision answer needs a one-line --text"
  fi
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
      # The dialog's map is keyed by the dialog's question texts and labels; the stage reads its
      # own, so each entry is re-keyed by position and its label read back (stagelabel).
      amap="$(ask_dialog_map "$ask" "$id" "$(sed -n '/^## Dialog$/{n;p;q;}' "$f")" \
        "$(jq -c 'select(type == "object") | .map // empty' <<<"$r")")" || amap=""
      jq -e --slurpfile a "$ASK_D/$ask.json" '(keys | sort) == ($a[0].payload.tool_input.questions | map(.question) | sort)
        and all(.[]; type == "string" and length > 0)' <<<"${amap:-null}" >/dev/null 2>&1 \
        || d_bad 7 "the dialog answer of $id does not answer every question of $ask"
      [ -z "$outcome" ] || d_bad 7 "--outcome does not apply to a $kind ask"
      p='{"outcome":"","value":"","map":null}'
    # ask_parse_reply is the hook's parser too: a reply it refuses is never recorded as answered.
    elif ! p="$(ask_parse_reply "$ask" "$id" "$text")"; then
      case "$kind" in
        permission|plan) d_bad 7 "reply must read $id allow|deny" ;;
        *) d_bad 7 "reply must read $id $(if [ "${nq:-0}" -gt 1 ]; then d_reply_shape "$ask"; else echo '<answer>'; fi)" ;;
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
  elif [ "$(dfm "$f" kind)" = batch ]; then
    # #322: one reply parser for a batch, typed or from the dialog: `d-<n> allow|deny[: …]`.
    po="$(d_batch_reply "$id" "$text")" || d_bad 7 "reply must read $id allow|deny"
    [ -z "$outcome" ] || [ "$outcome" = "$po" ] || d_bad 7 "the reply reads $po, not --outcome $outcome"
    outcome="$po"; aval="${text#"$id deny"}"; aval="${aval#:}"; aval="${aval#"${aval%%[![:space:]]*}"}"
    [ "$po" = deny ] || aval=""
  elif [ -n "$fromask" ]; then
    ans="${text#"$id "}"
    labels="$(sed -n '/^## Dialog$/{n;p;q;}' "$f" | jq -r '.questions[0].options[].label' 2>/dev/null)"
    if [ "$(dfm "$f" gate)" = plan ] || [ "$(dfm "$f" notify)" = abandon_decision ]; then
      # A control decision acts on its label alone: a free text could read as any outcome.
      grep -qxF -- "$ans" <<<"$labels" \
        || d_bad 7 "a free-text answer to a control decision is not recorded — the decision stays pending; ask again with the options"
    fi
    aval="$ans"
    # An outcome comes only from an offered label in the outcome enum: never from free text.
    local onmenu=""; ! grep -qxF -- "$ans" <<<"$labels" || onmenu=1
    case "$ans" in continue|close|more-revise|approve) [ -z "$onmenu" ] || outcome="${outcome:-$ans}" ;; esac
    [ -z "$outcome" ] || { [ -n "$onmenu" ] && [ "$outcome" = "$ans" ]; } \
      || d_bad 7 "--outcome $outcome does not fit the Operator's answer: $ans"
  fi
  if [ "$(dfm "$f" status)" = withdrawn ]; then
    notes_add "## Late answers" "- $id (withdrawn $(dfm "$f" withdrawn_at)): ${text:0:120}"
  fi
  [ "$(dfm "$f" status)" = pending ] || d_bad 4 "$id is $(dfm "$f" status), not pending — nothing applied"
  if [ -n "$fromask" ]; then
    how="teamlead-ask $uuid"
  elif [ -t 0 ] && [ -r /dev/tty ]; then
    # A run that has been under the Operator's mandate at any point can hold delegated answers:
    # for the rest of it a terminal answer, which leaves no evidence a hook can read back, is not
    # taken as the Operator's.
    # The same when that cannot be ruled out (no Supervisor session on record, a rotated one, an
    # unreadable history, no mandate library).
    command -v mandate_run_ever >/dev/null 2>&1 \
        && ! mandate_run_ever "$MAIN" "$(jq -r .team "$TD/team.json")" "$RUN" \
      || d_bad 7 "run $RUN is, was or may have been under the Operator's mandate — an Operator answer needs evidence here: answer in the TeamLead's dialog or window, or relay it through the Supervisor (a terminal answer is refused)"
    printf 'Operator answer to %s: %s\nconfirm by typing %s: ' "$id" "$text" "$id" > /dev/tty
    IFS= read -r c < /dev/tty || c=""
    [ "$c" = "$id" ] || d_bad 7 "not confirmed — nothing applied"
    how="terminal"
  else
    local erc=0
    if [ -n "$ask" ] || [ "$(dfm "$f" kind)" = batch ]; then ev="$(d_evidence "$f" "$text" exact)" || erc=$?
    else ev="$(d_evidence "$f" "$text")" || erc=$?; fi
    [ "$erc" != 3 ] || d_bad 7 "the TeamLead session is not one the runner recorded — answer from a terminal"
    [ -n "$ev" ] || d_bad 7 "no Operator message in the TeamLead window after $(dfm "$f" created_at) contains this answer — answer from a terminal, or relay the Operator's own words"
    # "<session> <uuid>[ legacy]": a legacy pair came from teamlead.json, so no answered_session.
    set -- $ev; esid="$1"; how="teamlead-window $2"; [ "${3:-}" != legacy ] || esid=""
  fi
  # The confirmation and the evidence ran outside the lock; the state is re-checked under it.
  d_lock
  [ "$(dfm "$f" status)" = pending ] || { ask_unlock; d_bad 4 "$id is $(dfm "$f" status), not pending — nothing applied"; }
  if [ -n "$ask" ]; then
    case "$(d_ask_state "$ask")" in waiting|timed-out) ;;
      *) ask_unlock; d_bad 4 "ask $ask is $(ask_get "$ask" state), not open — nothing applied" ;; esac
  fi
  d_record "$f" "$id" "$how" "$outcome" "$aval" "$amap" "$text" "${esid:-}" \
    || { ask_unlock; d_bad 1 "$id could not be written"; }
  ask_unlock
  d_record_post "$f" "$id" "$ask" "${kind:-}" "$outcome" "$aval" "${rest:-}" "$text"
  [ -z "$tuning" ] || notes_tune "$id" "$tuning" "$why"
  echo "answered: $id${outcome:+ ($outcome)} via ${how%% *}"
}

d_relay_ring() {
  team_session_doorbell "$TD" lead "relayed: $1 — the Operator answered through the Supervisor; apply it"
}

decision_relay() {
  local id="${1:-}" text f team re reply rest="" ask kind lf rd u pl sid cwd cfg tx floor sel uuid
  local p outcome="" aval="" amap="" w tmp x
  [ -n "$id" ] || usage; shift
  [ $# -eq 2 ] && [ "$1" = --text ] || usage; text="$2"
  [ "${TEAM_SESSION_ROLE:-}" = Supervisor ] && [ ! -f "$(team_root)/.agents/team/team.json" ] \
    || d_bad 3 "decision relay is the Supervisor's, from the main checkout"
  one_line "$text" || d_bad 2 "decision relay needs a one-line --text"
  text="$(jq -rn --arg m "$text" '$m | sub("^\\s+"; "") | sub("\\s+$"; "")')"
  one_line "$text" || d_bad 2 "decision relay needs a one-line --text"
  f="$(d_file "$id")"
  team="$(jq -r .team "$TD/team.json")"
  re="^${team}[[:space:]]+${id}([[:space:]]|\$)"
  [[ "$text" =~ $re ]] || d_bad 7 "reply must start with \"$team $id \""
  reply="${text#"$team"}"; reply="${reply#"${reply%%[![:space:]]*}"}"
  rest="${reply#"$id"}"; rest="${rest#"${rest%%[![:space:]]*}"}"
  [ -n "$rest" ] || d_bad 7 "reply must say something after \"$team $id\""
  # Every ask read and the lock use the run this team is on, never another session's.
  ask_init "$TD" && [ "$ASK_RUN" = "$RUN" ] || d_bad 4 "team $team's session is not on run $RUN"
  ask="$(dfm "$f" bind_ask)"; kind="$(dfm "$f" ask_kind)"
  lf="$MAIN/.agents/team/relays/$team-$RUN-$id.json"
  # A committed relay retried (a lost ring, an interrupted bookkeeping step): no transcript read.
  u="$(dfm "$f" answered_via)"
  if [ "$(dfm "$f" status)" = answered ] && [ "${u%% *}" = supervisor-window ] \
      && team_relay_pins "$lf" "$team" "$RUN" "$id" "$ask" "${u#supervisor-window }"; then
    pl="$(jq -r .reply "$lf")"
    [ "$text" = "$pl" ] || d_bad 4 "$id is already answered with \"$pl\" — a new answer needs a new decision"
    if ! grep -q " decision $id\$" "$TD/runs/$RUN/operator-touches" 2>/dev/null; then
      echo "$(team_utc) decision $id" >> "$TD/runs/$RUN/operator-touches"
      d_touch_log "$f" "$id" "$ask" "$kind" "$(dfm "$f" answer_outcome)" "$(dfm "$f" answer_value)" "$rest" \
        "$text" "$(dfm "$f" relayed_session)"
    fi
    d_resolve "$f"; d_relay_ring "$id"
    x="$(dfm "$f" answer_outcome)"; echo "answered: $id${x:+ ($x)} via supervisor-window"; return 0
  fi
  # The lead applies the stored answer by its prompt; a lead launched before the relay has no rule.
  rd="$TD/runs/$RUN"
  pl="$(ls "$rd" 2>/dev/null | sed -n 's/^lead-\([0-9]*\)\.prompt\.md$/\1/p' | sort -n | tail -n 1 || true)"
  [ -n "$pl" ] && grep -q 'Relayed by the Supervisor' "$rd/lead-$pl.prompt.md" 2>/dev/null \
    || d_bad 4 "team $team's TeamLead was launched before the Supervisor relay existed — the Operator answers in its window ($team-lead, \"$id …\"), or end it and then relaunch it (a relaunch of a running lead strips its authority): bash .claude/lib/team-lead.sh end $team, then bash .claude/lib/team-lead.sh relaunch $team"
  # The Supervisor's own transcript: the registry's session, the declared Claude profile (never the
  # caller's environment).
  sid="$(jq -r '.session_id // empty' "$MAIN/.agents/team/registry/Supervisor.json" 2>/dev/null || true)"
  cwd="$(jq -r '.cwd // empty' "$MAIN/.agents/team/registry/Supervisor.json" 2>/dev/null || true)"; cwd="${cwd:-$MAIN}"
  cfg="$(team_supervisor_home "$MAIN")" || cfg=""
  tx="$(team_role_transcript "$cwd" "$sid" "$cfg")"
  [ -n "$sid" ] && [ -n "$cfg" ] && [ -f "$tx" ] \
    || d_bad 7 "no Supervisor session recorded — answer from a terminal or in the TeamLead window"
  x="$(team_anchor_team "$MAIN" "${TD%/.agents/team}")" && [ "$x" = "$team"$'\t'"$RUN" ] \
    || d_bad 4 "team $team is not on run $RUN"
  floor="$(team_run_floor "$RUN" "$(dfm "$f" created_at)")"
  . "$LIB/team-evidence.sh" || d_bad 7 "no evidence matcher (team-evidence.sh)"
  # The reply's meaning: the ask's parser for a bound decision, else a control word or plain text.
  if [ -n "$ask" ]; then
    if ! p="$(ask_parse_reply "$ask" "$id" "$reply")"; then
      case "$kind" in
        permission|plan) d_bad 7 "reply must read $team $id allow|deny" ;;
        *) d_bad 7 "reply must read $team $id $(if [ "$(jq -r '.payload.tool_input.questions // [] | length' "$ASK_D/$ask.json" 2>/dev/null)" -gt 1 ]; then d_reply_shape "$ask"; else echo '<answer>'; fi)" ;;
      esac
    fi
    outcome="$(jq -r .outcome <<<"$p")"; aval="$(jq -r .value <<<"$p")"; amap="$(jq -c '.map // empty' <<<"$p")"
  elif [ "$(dfm "$f" kind)" = batch ]; then
    outcome="$(d_batch_reply "$id" "$reply")" || d_bad 7 "reply must read $team $id allow|deny"
  else
    w="${rest%%[[:space:]]*}"; w="${w%:}"
    case "$w" in continue|close|more-revise|approve) outcome="$w" ;; esac
  fi
  d_lock
  if [ "$(dfm "$f" status)" = withdrawn ]; then
    notes_add "## Late answers" "- $id (withdrawn $(dfm "$f" withdrawn_at)): ${text:0:120}"
  fi
  [ "$(dfm "$f" status)" = pending ] || { ask_unlock; d_bad 4 "$id is $(dfm "$f" status), not pending — nothing applied"; }
  if [ -n "$ask" ]; then
    case "$(d_ask_state "$ask")" in waiting|timed-out) ;;
      *) ask_unlock; d_bad 4 "ask $ask is $(ask_get "$ask" state), not open — nothing applied" ;; esac
  fi
  # Selected under the lock: a correction typed while the relay waited wins.
  sel="$(team_evidence_latest "$tx" "$team" "$id" "$floor" || true)"
  uuid="$(cut -f1 <<<"$sel")"
  [ -n "$sel" ] && [ "$(cut -f2- <<<"$sel")" = "$text" ] \
    || { ask_unlock; d_bad 7 "the newest Supervisor-window reply to $team $id is not this text"; }
  for x in "$MAIN"/.agents/team/relays/*.json; do
    [ -f "$x" ] && [ "$x" != "$lf" ] || continue
    ! jq -e --arg u "$uuid" '.uuid == $u' "$x" >/dev/null 2>&1 \
      || { ask_unlock; d_bad 7 "that Supervisor message already answered another decision ($(basename "$x" .json))"; }
  done
  if [ -e "$lf" ]; then
    # An interrupted attempt is completed only with its own pinned values.
    team_relay_pins "$lf" "$team" "$RUN" "$id" "$ask" "$uuid" && [ "$(jq -r .reply "$lf")" = "$text" ] \
      || { ask_unlock; d_bad 4 "relay ledger already holds $id ($(jq -r '.ask // ""' "$lf"), $(jq -r '.uuid // ""' "$lf")) — a different answer needs a new decision"; }
  else
    mkdir -p "$(dirname "$lf")"; tmp="$lf.tmp.$$"
    jq -n --arg t "$team" --arg r "$RUN" --arg d "$id" --arg a "$ask" --arg s "$sid" --arg c "$cwd" \
      --arg cf "$cfg" --arg u "$uuid" --arg p "$text" --arg fl "$floor" --arg at "$(team_utc)" \
      '{team: $t, run: $r, decision: $d, ask: $a, session_id: $s, cwd: $c, config_dir: $cf, uuid: $u,
        reply: $p, created_at: $fl, relayed_at: $at}' > "$tmp" && ln "$tmp" "$lf" 2>/dev/null
    x=$?; rm -f "$tmp"
    [ "$x" = 0 ] || { ask_unlock; d_bad 4 "relay ledger $lf could not be written once"; }
  fi
  d_record "$f" "$id" "supervisor-window $uuid" "$outcome" "$aval" "$amap" "$text" "" "$sid" \
    || { ask_unlock; d_bad 1 "$id could not be written"; }
  ask_unlock
  d_record_post "$f" "$id" "$ask" "$kind" "$outcome" "$aval" "$rest" "$text" "$sid"
  d_relay_ring "$id"
  echo "answered: $id${outcome:+ ($outcome)} via supervisor-window"
}

# d_supervisor_caller — the Supervisor role, from the main checkout (never a team clone).
d_supervisor_caller() {
  [ "${TEAM_SESSION_ROLE:-}" = Supervisor ] && [ ! -f "$(team_root)/.agents/team/team.json" ]
}

# d_request_digest <ask file> → the sha256 of the ask's filed request, canonical (sorted keys): what
# a delegated answer names in its own argv and the stage hook recomputes from its live input.
d_request_digest() {
  . "$LIB/team-evidence.sh" 2>/dev/null || return 1
  jq -cS .payload "$1" 2>/dev/null | team_evidence_sha
}

# decision_delegated <d-n> <text> <why> <run> <ask> <attempt> <stage session> <request digest> —
# the Supervisor answers a decision the Operator's mandate covers, as a delegate. Its own call
# carries every binding in its argv, and each is checked or the answer is refused: the caller is
# the registered Supervisor session and its transcript holds this very call, standalone; the team
# is on the run named; the decision is pending, routed to the Supervisor and bound to the ask
# named, an open ask of the stage's active session and attempt, whose filed request has the digest
# named; the mandate the decision was routed under is in force (derived from the Operator's
# message now) and names the class, the team and this run; the reply is one the ask's parser
# accepts. Pinned once in <main>/.agents/team/delegated/ (never replaced), so a replayed, stale
# or conflicting answer is refused here and by the stage hook.
decision_delegated() {
  local id="$1" text="$2" why="$3" run="$4" aask="$5" aatt="$6" asess="$7" areq="$8" aman="$9" acls="${10}"
  local f team ask kind lf u sid cwd cfg tx floor uuid="" p cls m x i=0 tmp args mainp
  local outcome="" aval="" amap="" wait="${TEAM_DELEGATE_WAIT_SECS:-6}"
  d_supervisor_caller || d_bad 3 "a delegated answer is the Supervisor's, from the main checkout"
  one_line "$text" && one_line "$why" || d_bad 2 "decision answer --delegated needs a one-line --text and --why"
  # The call's own text is the evidence, so every value is passed exactly as typed: nothing a
  # shell would rewrite, no padding.
  for x in "$text" "$why"; do
    case "$x" in *'"'*|*'$'*|*'`'*|*'\'*|" "*|*" ") d_bad 2 "--text and --why of a delegated answer take no quotes, \$, backticks or backslashes and no padding" ;; esac
  done
  [ -n "$run" ] && [ -n "$aask" ] && [ -n "$aatt" ] && [ -n "$asess" ] && [ -n "$areq" ] && [ -n "$aman" ] && [ -n "$acls" ] \
    || d_bad 2 "decision answer --delegated needs --run, --ask, --attempt, --session, --request, --mandate and --class (the delegated inbox message prints the command)"
  # The run the inbox message named: a d-<n> of the team's next run is never answered by an
  # answer meant for the last one.
  [ "$run" = "$RUN" ] || d_bad 4 "team $(jq -r .team "$TD/team.json") is on run $RUN, not $run — nothing applied"
  f="$(d_file "$id")"
  team="$(jq -r .team "$TD/team.json")"
  case "$text" in "$id "*) ;; *) d_bad 7 "reply must start with \"$id \"" ;; esac
  ask_init "$TD" && [ "$ASK_RUN" = "$RUN" ] || d_bad 4 "team $team's session is not on run $RUN"
  x="$(team_anchor_team "$MAIN" "${TD%/.agents/team}")" && [ "$x" = "$team"$'\t'"$RUN" ] \
    || d_bad 4 "team $team is not on run $RUN"
  ask="$(dfm "$f" bind_ask)"; kind="$(dfm "$f" ask_kind)"
  [ -n "$ask" ] && [ -f "$ASK_D/$ask.json" ] \
    || d_bad 7 "$id is bound to no ask — only the Operator answers it"
  [ "$aask" = "$ask" ] || d_bad 7 "$id is bound to ask $ask, not $aask — nothing applied"
  lf="$MAIN/.agents/team/delegated/$team-$RUN-$id.json"
  # A committed answer retried (a lost ring): no new evidence, the same text only.
  u="$(dfm "$f" answered_via)"
  case "$(dfm "$f" status)" in answered|dispatched)
    if [ "${u%% *}" = supervisor-delegated ] && team_relay_pins "$lf" "$team" "$RUN" "$id" "$ask" "${u#supervisor-delegated }"; then
      [ "$text" = "$(jq -r .reply "$lf")" ] \
        || d_bad 4 "$id is already answered with \"$(jq -r .reply "$lf")\" — a new answer needs a new decision"
      d_delegated_ring "$id" "$(jq -r .mandate "$lf")"
      x="$(dfm "$f" answer_outcome)"; echo "answered: $id${x:+ ($x)} via supervisor-delegated"; return 0
    fi ;;
  esac
  [ "$(dfm "$f" status)" = pending ] || d_bad 4 "$id is $(dfm "$f" status), not pending — nothing applied"
  [ "$(dfm "$f" delegate)" = supervisor ] \
    || d_bad 7 "$id is not delegated to the Supervisor — the Operator answers it"
  d_lead_knows 'Delegated to the Supervisor' \
    || d_bad 4 "team $team's TeamLead was launched before delegation existed — hand $id back: bash .claude/lib/team-lead.sh decision handback $team $id --why \"<line>\""
  # The ask's session and attempt: the ones the call names, the ones the decision recorded at
  # open, and still the stage's active ones (a replaced attempt is not answered).
  [ "$aatt" = "$(ask_get "$ask" attempt)" ] && [ "$asess" = "$(ask_get "$ask" session_id)" ] \
    && [ "$aatt" = "$(dfm "$f" bind_attempt)" ] && [ "$asess" = "$(dfm "$f" bind_session_id)" ] \
    || d_bad 7 "$id is not bound to session $asess, attempt $aatt of ask $ask — nothing applied"
  [ "$asess" = "$(jq -r '.session_id // ""' "$TD/session.json" 2>/dev/null)" ] \
    && [ "$aatt" = "$(jq -r '.attempt // "" | tostring' "$TD/session.json" 2>/dev/null)" ] \
    || d_bad 4 "ask $ask belongs to a replaced session or attempt — nothing applied"
  # The request the answer is for: the digest the call names is the filed request's.
  [ "$areq" = "$(d_request_digest "$ASK_D/$ask.json")" ] \
    || d_bad 7 "--request is not the digest of ask $ask's request — nothing applied"
  # The class (the main checkout's checker, now) and the mandate: the very one the decision was
  # routed under, derived again from the Operator's message, naming the class, the team and this run.
  cls="$(mandate_ask_class "$MAIN" "${TD%/.agents/team}" "$ASK_D/$ask.json" "$(d_touch_reason "$f")")"
  [ -n "$cls" ] || d_bad 7 "no mandate can cover $id — hand it back to the Operator"
  [ "$cls" = "$(dfm "$f" delegate_class)" ] \
    || d_bad 7 "$id was routed as class $(dfm "$f" delegate_class) but now reads $cls — hand it back"
  m="$(mandate_covers "$MAIN" "$cls" "$team" "$RUN" "$(dfm "$f" delegate_mandate)")" && [ -n "$m" ] \
    || d_bad 7 "the mandate $id was routed under ($(dfm "$f" delegate_mandate)) is no longer in force for class $cls, team $team, run $RUN (bash .claude/lib/team-mandate.sh show) — hand $id back"
  # The mandate and the class the call itself names: the Supervisor's own argv attests which
  # grant it answers under, and it is the governing one.
  [ "$aman" = "$m" ] && [ "$acls" = "$cls" ] \
    || d_bad 7 "--mandate $aman --class $acls are not the mandate in force ($m) and the class ($cls) of $id — nothing applied"
  # The permitted resolution: only a reply the ask's own parser accepts.
  if ! p="$(ask_parse_reply "$ask" "$id" "$text")"; then
    case "$kind" in
      permission|plan) d_bad 7 "reply must read $id allow|deny" ;;
      *) d_bad 7 "reply must read $id $(if [ "$(jq -r '.payload.tool_input.questions // [] | length' "$ASK_D/$ask.json" 2>/dev/null)" -gt 1 ]; then d_reply_shape "$ask"; else echo '<answer>'; fi)" ;;
    esac
  fi
  outcome="$(jq -r .outcome <<<"$p")"; aval="$(jq -r .value <<<"$p")"; amap="$(jq -c '.map // empty' <<<"$p")"
  # The sender: the registered Supervisor session, and this very call in its own transcript under
  # the declared Claude profile (never the caller's environment).
  sid="$(jq -r '.session_id // empty' "$MAIN/.agents/team/registry/Supervisor.json" 2>/dev/null || true)"
  cwd="$(jq -r '.cwd // empty' "$MAIN/.agents/team/registry/Supervisor.json" 2>/dev/null || true)"; cwd="${cwd:-$MAIN}"
  [ -n "$sid" ] && [ "${CLAUDE_CODE_SESSION_ID:-}" = "$sid" ] \
    || d_bad 7 "the caller is not the registered Supervisor session — nothing applied"
  cfg="$(team_supervisor_home "$MAIN")" || cfg=""
  tx="$(team_role_transcript "$cwd" "$sid" "$cfg")"
  [ -n "$cfg" ] && [ -f "$tx" ] || d_bad 7 "no Supervisor transcript to bind the answer to — nothing applied"
  floor="$(team_run_floor "$RUN" "$(dfm "$f" created_at)")"
  [ -n "$floor" ] || d_bad 7 "$id has no creation time to bind the answer to — nothing applied"
  . "$LIB/team-evidence.sh" && command -v team_evidence_tool_call >/dev/null 2>&1 \
    || d_bad 7 "no evidence matcher (team-evidence.sh)"
  args="$(team_delegate_args "$team" "$id" "$RUN" "$ask" "$aatt" "$asess" "$areq" "$text" "$m" "$cls")"
  # The call is written to the transcript as it starts; a short wait covers a late flush.
  while :; do
    uuid="$(team_evidence_tool_call "$tx" "$floor" "$MAIN" "$args")"
    [ -z "$uuid" ] && [ "$i" -lt $(( wait * 5 )) ] || break
    sleep 0.2; i=$((i + 1))
  done
  [ -n "$uuid" ] || d_bad 7 "the Supervisor session's transcript holds no standalone call that reads exactly: bash .claude/lib/team-lead.sh $args<line>\" — run it from the main checkout as one command, nothing before or after it — nothing applied"
  d_lock
  [ "$(dfm "$f" status)" = pending ] && [ "$(dfm "$f" delegate)" = supervisor ] \
    || { ask_unlock; d_bad 4 "$id is $(dfm "$f" status), no longer delegated — nothing applied"; }
  case "$(d_ask_state "$ask")" in waiting|timed-out) ;;
    *) ask_unlock; d_bad 4 "ask $ask is $(ask_get "$ask" state), not open — nothing applied" ;; esac
  for x in "$MAIN"/.agents/team/delegated/*.json; do
    [ -f "$x" ] && [ "$x" != "$lf" ] || continue
    ! jq -e --arg u "$uuid" '.uuid == $u' "$x" >/dev/null 2>&1 \
      || { ask_unlock; d_bad 7 "that call already answered another decision ($(basename "$x" .json))"; }
  done
  if [ -e "$lf" ]; then
    # An interrupted attempt is completed only with its own pinned answer.
    team_relay_pins "$lf" "$team" "$RUN" "$id" "$ask" && [ "$(jq -r .reply "$lf")" = "$text" ] \
      && [ "$(jq -r .mandate "$lf")" = "$m" ] && [ "$(jq -r .request "$lf")" = "$areq" ] \
      || { ask_unlock; d_bad 4 "the delegation ledger already holds $id with another answer — a different answer needs a new decision"; }
    uuid="$(jq -r .uuid "$lf")"
  else
    ( umask 077; mkdir -p "$(dirname "$lf")" ); tmp="$lf.tmp.$$"
    ( umask 077
      jq -n --arg t "$team" --arg r "$RUN" --arg d "$id" --arg a "$ask" --arg at "$aatt" --arg as "$asess" \
        --arg c "$cls" --arg m "$m" --arg s "$sid" --arg u "$uuid" --arg p "$text" --arg w "$why" \
        --arg q "$areq" --arg now "$(team_utc)" \
        '{team: $t, run: $r, decision: $d, ask: $a, attempt: $at, ask_session: $as, class: $c, mandate: $m,
          session_id: $s, uuid: $u, reply: $p, why: $w, request: $q, answered_at: $now}' > "$tmp" ) \
      && ln "$tmp" "$lf" 2>/dev/null
    x=$?; rm -f "$tmp"
    [ "$x" = 0 ] || { ask_unlock; d_bad 4 "delegation ledger $lf could not be written once"; }
  fi
  d_record "$f" "$id" "supervisor-delegated $uuid" "$outcome" "$aval" "$amap" "$text" \
    || { ask_unlock; d_bad 1 "$id could not be written"; }
  dfm_set "$f" delegated_by Supervisor; dfm_set "$f" delegated_session "$sid"
  dfm_set "$f" delegate_why "$why"
  ask_unlock
  # Never the Operator's answer: no operator touch and no touch-log entry. Its held notification
  # (none was sent while it was delegated) is resolved all the same.
  d_resolve "$f"
  d_delegated_ring "$id" "$m"
  echo "answered: $id${outcome:+ ($outcome)} via supervisor-delegated"
}

d_delegated_ring() {
  team_session_doorbell "$TD" lead "relayed: $1 — the Supervisor answered under the Operator's mandate $2; apply it with --authority delegated"
}

# decision_handback <d-n> --why <line> — the Supervisor returns a delegated decision to the
# Operator. The delegated decision is withdrawn for good and its ask is marked never to be
# delegated again: the lead opens a fresh decision on that ask, with a new id, which only human
# evidence answers.
decision_handback() {
  local id="${1:-}" why="" f ask
  [ -n "$id" ] || usage; shift
  [ $# -eq 2 ] && [ "$1" = --why ] && one_line "$2" || usage; why="$2"
  d_supervisor_caller || d_bad 3 "decision handback is the Supervisor's, from the main checkout"
  f="$(d_file "$id")"
  d_lock
  [ "$(dfm "$f" status)" = pending ] && [ "$(dfm "$f" delegate)" = supervisor ] \
    || { ask_unlock; d_bad 4 "$id is not a pending decision delegated to the Supervisor"; }
  ask="$(dfm "$f" bind_ask)"
  [ -z "$ask" ] || [ ! -f "$ASK_D/$ask.json" ] || ask_set "$ask" '.no_delegate = $d' --arg d "$id"
  dfm_set "$f" status withdrawn; dfm_set "$f" withdrawn_at "$(team_utc)"; dfm_set "$f" delegate handed-back
  printf '\n## Handed back\n%s\n' "$why" >> "$f"
  ask_unlock
  d_resolve "$f"
  team_session_doorbell "$TD" lead "handed back: $id — the Supervisor returns it to the Operator; open a new decision on ${ask:-its source} and raise its dialog"
  echo "handed back: $id — withdrawn; the lead opens a new decision for the Operator"
}

decision_withdraw() {
  local id="${1:-}" why="" f
  [ -n "$id" ] || usage; shift
  [ $# -eq 2 ] && [ "$1" = --why ] && one_line "$2" || usage; why="$2"
  team_lead_caller || d_bad 3 "only this run's TeamLead withdraws decisions"
  f="$(d_file "$id")"
  d_lock
  [ "$(dfm "$f" status)" = pending ] || { ask_unlock; d_bad 4 "$id is $(dfm "$f" status), not pending"; }
  dfm_set "$f" status withdrawn; dfm_set "$f" withdrawn_at "$(team_utc)"
  printf '\n## Withdrawn\n%s\n' "$why" >> "$f"
  ask_unlock
  d_resolve "$f"
  echo "withdrawn: $id"
}

decision_revoke() {  # #322: an answered batch grants no more uses (revoking only removes a grant)
  local id="${1:-}" why="" f
  [ -n "$id" ] || usage; shift
  [ $# -eq 2 ] && [ "$1" = --why ] && one_line "$2" || usage; why="$2"
  team_lead_caller || [ "${TEAM_SESSION_ROLE:-}" = Supervisor ] \
    || d_bad 3 "only this run's TeamLead or the Supervisor revokes a batch"
  f="$(d_file "$id")"
  [ "$(dfm "$f" kind)" = batch ] || d_bad 7 "$id is no batch decision"
  d_lock
  case "$(dfm "$f" status)" in answered|dispatched) ;;
    *) ask_unlock; d_bad 4 "$id is $(dfm "$f" status), not answered" ;; esac
  python3 -I "$LIB/team_batch.py" revoke --dir "$DD" --id "$id" --why "$why" \
    || { ask_unlock; d_bad 1 "$id could not be revoked"; }
  dfm_set "$f" revoked_at "$(team_utc)"
  printf '\n## Revoked\n%s\n' "$why" >> "$f"
  ask_unlock
  echo "revoked: $id"
}

decision_list() {
  local f st
  for f in "$DD"/d-*.md; do
    [ -f "$f" ] || continue
    st="$(dfm "$f" status)"
    [ "${1:-}" != --pending ] || [ "$st" = pending ] || continue
    # A delegated answer is listed as the Supervisor's, never as the Operator's.
    case "$(dfm "$f" answered_via)" in supervisor-delegated*) st="$st [supervisor (delegated)]" ;; esac
    [ "$st" != pending ] || [ "$(dfm "$f" delegate)" != supervisor ] || st="pending [delegated to the Supervisor]"
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
    open) decision_open "$@" ;; answer) decision_answer "$@" ;; relay) decision_relay "$@" ;;
    withdraw) decision_withdraw "$@" ;; list) decision_list "$@" ;; handback) decision_handback "$@" ;;
    revoke) decision_revoke "$@" ;;
    *) usage ;;
  esac
}
