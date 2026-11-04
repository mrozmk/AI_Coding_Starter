#!/usr/bin/env bash
# Binding v2 and delivery mapping of the question ledger. Sourced by team-question.sh
# after team-lib.sh; reads its globals TEAM CLONE TD RUN QD LIB.

newest_record() { team_newest_record "$TD" "$RUN" "$1" "$2"; }
# Header fields sit above the first heading; the summary below may hold arbitrary text.
field() {
  awk -v k="$2: " '/^## /{exit} index($0, k) == 1 {print substr($0, length(k) + 1); exit}' "$1"
}

# qb_capture <role> <kind> → QB_FP QB_UNREADABLE QB_PANE QB_SESSION QB_EVENT QB_BUSY QB_TRANSIENT
#   QB_TEXT
qb_capture() {
  local p kind complete reason fp busy t ev=permission
  QB_FP=-; QB_UNREADABLE=""; QB_EVENT=-; QB_BUSY=""; QB_TRANSIENT=""
  QB_PANE="$(team_pane_gen "$TEAM-$1" || true)"; QB_PANE="${QB_PANE:--}"
  if [ "$QB_PANE" != - ]; then
    QB_TEXT="$(team_pane_scroll "${QB_PANE%@*}")"
  else
    QB_TEXT="$(team_pane "$TEAM-$1" 40)"
  fi
  QB_SESSION="$(session_json session_id)"; QB_SESSION="${QB_SESSION:--}"
  t="$(team_role_transcript "$CLONE" "$QB_SESSION")"
  # Same transcript as the sender's parse, or a recovered prompt never matches its fingerprint.
  p="$(printf '%s\n' "$QB_TEXT" | python3 -I "$LIB/team_prompt.py" parse --transcript "$t")"
  IFS=$'\x1f' read -r kind complete reason fp busy <<<"$(jq -r '[.kind, .complete, .reason, .fp,
    .busy] | map(tostring) | join("\u001f")' <<<"$p")"
  [ "$busy" != true ] || QB_BUSY=1
  if [ "$complete" = true ]; then QB_FP="$fp"
  else QB_FP=v2:unreadable; QB_UNREADABLE="${reason#unreadable: }"
    case "$reason" in incomplete:*) QB_TRANSIENT=1 ;; esac
  fi
  case "$2" in
    menu|permission)
      [ "$kind" = permission ] || ev=menu
      if [ "$t" != - ] && [ "$complete" = true ]; then
        QB_EVENT="$(printf '%s' "$p" | python3 -I "$LIB/team_prompt.py" event "$t" "$ev")"
      fi ;;
    *) [ "$t" = - ] || QB_EVENT="$(python3 -I "$LIB/team_prompt.py" event "$t" blocked)" ;;
  esac
}

qb_set_binding() {  # qb_set_binding <q> — rewrites the header's binding lines from QB_*
  FP="$QB_FP" UR="$QB_UNREADABLE" PN="$QB_PANE" SS="$QB_SESSION" EV="$QB_EVENT" awk '
    /^## / { h = 1 }
    !h && /^(unreadable|pane|session|event): / { next }
    !h && !d && index($0, "fingerprint: ") == 1 {
      print "fingerprint: " ENVIRON["FP"]
      if (ENVIRON["UR"] != "") print "unreadable: " ENVIRON["UR"]
      print "pane: " ENVIRON["PN"]; print "session: " ENVIRON["SS"]; print "event: " ENVIRON["EV"]
      d = 1; next }
    { print }' "$1" > "$1.tmp.$$"
  mv "$1.tmp.$$" "$1"
}

# qb_find_existing <role> <attempt> <kind> <record> <anchor> — the q bound to the captured instance.
qb_find_existing() {
  local q
  for q in "$QD"/q-*.md; do
    [ -f "$q" ] || continue
    [ "$(field "$q" role)" = "$1" ] && [ "$(field "$q" attempt)" = "$2" ] \
      && [ "$(field "$q" kind)" = "$3" ] || continue
    case "$3" in
      blocked) [ "$(field "$q" record)" = "$4" ] || continue ;;
      idle) [ "$(field "$q" anchor)" = "$5" ] && [ "$(field "$q" pane)" = "$QB_PANE" ] \
              && [ "$(field "$q" event)" = "$QB_EVENT" ] || continue ;;
      *) [ "$(field "$q" fingerprint)" = "$QB_FP" ] && [ "$(field "$q" pane)" = "$QB_PANE" ] \
           && [ "$(field "$q" event)" = "$QB_EVENT" ] || continue
         [ "$QB_FP" != v2:unreadable ] || [ "$(field "$q" anchor)" = "$5" ] || continue ;;
    esac
    echo "$q"; return 0
  done
}

qb_answer_count() { grep -c '^## Answer$' "$1" || true; }

qb_block_field() {  # qb_block_field <q> <n> <key> — <key> of the n-th ## Answer block
  awk -v n="$2" -v k="$3: " '
    /^## / { if ($0 == "## Answer") { c++; a = (c == n) } else a = 0; next }
    a && index($0, k) == 1 { print substr($0, length(k) + 1); exit }' "$1"
}

qb_chain() {  # qb_chain <q> <first answered> — attempts of one decision, its retries included
  awk -v f="$2" '
    /^## / { a = ($0 == "## Answer"); next }
    a && /^answered: / { ans = substr($0, 11) }
    a && $0 == "retry-of: " f { n++; a = 0 }
    a && /^delivery: / { if (ans == f) n++; a = 0 }
    END { print n + 0 }' "$1"
}

# qb_identity <q> — checks that need no screen; prints the stale reason, rc 1.
qb_identity() {
  local q="$1" fp s
  [ -f "$TD/session.json" ] && [ "$(session_json role)" = "$(field "$q" role)" ] \
    && [ "$(session_json attempt)" = "$(field "$q" attempt)" ] \
    || { echo "role or attempt changed"; return 1; }
  fp="$(field "$q" fingerprint)"
  [ "$fp" != - ] || { echo "fingerprint not recorded (role was busy at open) — open again"; return 1; }
  case "$fp" in v2:*) ;; *) echo "legacy binding v1 — open again"; return 1 ;; esac
  s="$(session_json session_id)"
  [ "${s:--}" = "$(field "$q" session)" ] || { echo "session changed"; return 1; }
  if [ "$(field "$q" kind)" = blocked ]; then
    [ "$(newest_record "$(field "$q" role)" "$(field "$q" attempt)")" = "$(field "$q" record)" ] \
      || { echo "a newer record exists"; return 1; }
  fi
}

# qb_outcome <rc> <sender output> <q> <id> <attempt> <role> → QB_DELIVERY QB_CONFIRMED
qb_outcome() {
  local rc="$1" q="$3" att="$5" line reason="" n pid
  QB_CONFIRMED=""
  while IFS= read -r line; do
    case "$line" in
      "error: "*" — nothing sent") reason="${line#error: }"; reason="${reason% — nothing sent}" ;;
      "error: "*" keys sent") reason="${line#error: }"; reason="${reason% — * keys sent}" ;;
    esac
  done <<<"$2"
  n="$(grep -c "^$att ok " "$q.keys" 2>/dev/null || true)"; n="${n:-0}"
  case "$rc" in
    0) QB_DELIVERY=sent
       QB_CONFIRMED="$(grep -m 1 '^confirmed: ' <<<"$2" || true)"
       [ -n "$QB_CONFIRMED" ] || QB_CONFIRMED="confirmed: no — sender gave no confirmation" ;;
    3) QB_DELIVERY="not sent — stale ($reason)" ;;
    5) QB_DELIVERY="not sent — unreadable ($reason)" ;;
    6) QB_DELIVERY="not sent — changed ($reason)" ;;
    7) QB_DELIVERY="not sent — policy ($reason)" ;;
    8) QB_DELIVERY="not sent — mode ($reason)" ;;
    4) QB_DELIVERY="unknown — $n keys ($reason)" ;;
    *) if grep -q "^$att try " "$q.keys" 2>/dev/null; then QB_DELIVERY="unknown — $n keys (rc $rc)"
       else QB_DELIVERY="failed (rc $rc)"; fi ;;
  esac
  line="$(grep "^stop-during-send .* q=$4 attempt=$att pid=" "$TD/send-$6.log" 2>/dev/null \
    | tail -n 1 || true)"
  if [ -n "$line" ]; then
    pid="${line##*pid=}"
    QB_DELIVERY="unknown — stop while sender lock held by pid $pid"; QB_CONFIRMED=""
  fi
}

qb_exit() {
  case "$1" in
    sent|consumed|recorded) echo 0 ;; not-sent-stale) echo 3 ;; unknown|pending) echo 4 ;;
    *) echo 5 ;;
  esac
}
