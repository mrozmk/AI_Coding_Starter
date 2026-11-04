# Helpers for team-escalate.sh and team-snapshot.sh: ledger queries, payload,
# reply parsing.
# Sourced after team-lib.sh; contract: .agents/reference/team-mode.md §10 (mechanics 4).

ESC_REPING_CAP=2
# classes: only eligible ones may close on Reviewer's agreement (escalation-fallback.md).
ESC_ELIGIBLE="analysts-condition plan-variant borderline policy-deviation"
ESC_CRITICAL="ac contract schema sensitive harness-rule conflict"
# Written by team-escalate.sh try_fallback, matched by team-question.sh fallback_guard.
ESC_FALLBACK_WHY="fallback: Advisor no-reply — Reviewer #"

# Header fields sit above the first heading; the body below may hold arbitrary text.
esc_field() {
  awk -v k="$2: " '/^## /{exit} index($0, k) == 1 {print substr($0, length(k) + 1); exit}' "$1"
}

esc_lines() { awk '/^## /{sec = substr($0, 4); next} sec == "Escalation"' "$1"; }

# Old ledgers wrote `started:` without a tier; they were all tier 2.
esc_tier() {
  esc_lines "$1" | awk '
    /^started: / { t = ($3 == "tier") ? $4 : 2 }
    /^retier: /  { t = 3 }
    END { print t }'
}

esc_last_outcome() {
  esc_lines "$1" | awk '/^outcome: /{o = substr($0, 10)} END{print o}'
}

esc_asked() {
  esc_lines "$1" | awk '
    /^outcome: (answer|withdrawn)$/ { a = 0 }
    /^waiting: / { a = 1 }
    END { exit a ? 0 : 1 }'
}

esc_class() {
  esc_lines "$1" | awk '/^started: / { for (i = 1; i < NF; i++) if ($i == "class") c = $(i + 1)
    exit } END { print (c == "" ? "unclassified" : c) }'
}

esc_recommend() { esc_lines "$1" | sed -n 's/^recommend: //p' | tail -n 1; }

# The --text form a fallback is recorded and matched in: one line, whitespace collapsed.
esc_one_line() { tr '\t\r\n' '   ' <<<"$1" | tr -s ' ' | sed 's/ $//'; }

# The delivery try_fallback bound: "<send>\t<reviewer id>\t<text>" from the three lines after the
# last `outcome: reviewer-fallback`; nothing when that block is incomplete.
esc_fallback_block() {
  esc_lines "$1" | awk '
    /^outcome: reviewer-fallback$/ { k = 1; ok = 0; next }
    k == 1 && /^ended: /        { k = 2; next }
    k == 2 && /^    send: /     { s = substr($0, 11); k = 3; next }
    k == 3 && /^    reviewer: #/ { a = substr($0, 16); k = 4; next }
    k == 4 && /^    text: /     { t = substr($0, 11); ok = 1 }
    { k = 0 }
    END { if (ok) printf "%s\t%s\t%s\n", s, a, t }'
}

# Old `sent:` lines carry no id: no proof the request was delivered.
esc_first_sent_id() {
  esc_lines "$1" | awk '/^sent: / { for (i = 1; i < NF; i++) if ($i == "id") v = $(i + 1)
    exit } END { if (v ~ /^[0-9]+$/) print v }'
}

# esc_fallback_check <q> <tier> [advertise] → rc 0 eligible, else rc 1 + the reason. `advertise`
# skips the delivered-request rule: the payload is built before the send.
esc_fallback_check() {
  local q="$1" lines
  [ "$2" = 2 ] || { echo tier; return 1; }
  lines="$(esc_lines "$q")"
  ! grep -q '^retier: ' <<<"$lines" || { echo retier; return 1; }
  ! grep -q '^waiting: ' <<<"$lines" || { echo pending-operator; return 1; }
  ! grep -qE '^reply: [^ ]+ disagree$' <<<"$lines" || { echo analyst-disagree; return 1; }
  [ "$(esc_field "$q" kind)" != permission ] || { echo permission; return 1; }
  case " $ESC_ELIGIBLE " in *" $(esc_class "$q") "*) ;; *) echo class; return 1 ;; esac
  [ -n "$(esc_recommend "$q")" ] || { echo no-recommendation; return 1; }
  [ "${3:-}" = advertise ] || [ -n "$(esc_first_sent_id "$q")" ] \
    || { echo "no delivered request"; return 1; }
}

# esc_opinion_parse <file> — sets R_OID R_OPINION (agree|disagree|unmarked) R_OBODY; 1 = no body.
esc_opinion_parse() {
  local body m
  R_OID=-; R_OPINION=unmarked; R_OBODY=""
  m="$(sed -n '1s/^mail-id: //p' "$1")"; [ -z "$m" ] || R_OID="$m"
  body="$(awk 'NR == 1 && /^mail-id: /{next} {print}' "$1")"
  [ -n "$(tr -d '[:space:]' <<<"$body")" ] || return 1
  m="$(awk 'NF { gsub(/^[ \t]+|[ \t\r]+$/, ""); print; exit }' <<<"$body")"
  case "$m" in
    "opinion: agree"|"opinion: disagree") R_OPINION="${m#opinion: }"
      body="$(awk 'f {print; next} NF {f = 1}' <<<"$body")" ;;
  esac
  R_OBODY="$(awk 'NF {s = 1} s { l[++n] = $0; if (NF) last = n }
    END { for (i = 1; i <= last; i++) print l[i] }' <<<"$body")"
}

# esc_opinion_class <body> — the class Reviewer names on the first body line ("class: <c>"), any.
esc_opinion_class() {
  awk 'NF { gsub(/^[ \t]+|[ \t\r]+$/, ""); print; exit }' <<<"$1" \
    | sed -nE 's/^[Cc]lass: <?([A-Za-z-]+)>?.*$/\1/p' | tr '[:upper:]' '[:lower:]'
}

esc_staged_unconsumed() {  # oldest first
  local id qid
  qid="$(basename "$1" .md)"
  for id in $(ls -1 "$(dirname "$1")" | sed -n "s/^$qid\.reply-\(.*\)\.md\$/\1/p" | sort -n); do
    esc_seen_reply "$1" "$id" || echo "$id"
  done
}

esc_waiter() {  # esc_waiter <q> → none|dead|live
  local p
  [ -d "$1.wait" ] || { echo none; return 0; }
  p="$(cat "$1.wait/pid" 2>/dev/null || true)"
  if [ -n "$p" ] && kill -0 "$p" 2>/dev/null; then echo live; else echo dead; fi
}

esc_sent_count() { esc_lines "$1" | grep -c '^sent: ' || true; }
# Max allocated request seq + 1: a request answered without a receipt has no `sent:`, and a reused
# seq would hit the adapter's dedup key.
esc_next_seq() {
  esc_lines "$1" | awk '
    function seq(  i) { for (i = 1; i < NF; i++) if ($i == "seq") return $(i + 1); return "" }
    /^started: / { s = 1 }
    /^(reping|retier): / { s = seq() + 0 }
    s > m { m = s }
    END { print m + 1 }'
}

# Seq of the last request (started = 1, reping/retier = its seq) that has no `sent:` line.
esc_outstanding() {
  esc_lines "$1" | awk '
    function seq(  i) { for (i = 1; i < NF; i++) if ($i == "seq") return $(i + 1); return "" }
    /^started: / { last = 1 }
    /^(reping|retier): / { last = seq() }
    /^sent: / { sent[seq()] = 1 }
    END { if (last != "" && !(last in sent)) print last }'
}

# Incident of the outstanding seq → "<seq>\t<since>\t<failed|unsent>\t<reason>"; once a send of
# that seq failed it stays `failed`, so a retry never closes and reopens the alarm.
esc_unsent() {
  esc_lines "$1" | awk '
    function seq(  i) { for (i = 1; i < NF; i++) if ($i == "seq") return $(i + 1); return "" }
    function req(s) { if (!(s in since)) since[s] = $2; last = s; o = "" }
    /^started: / { req(1) }
    /^(reping|retier): / { req(seq()) }
    /^sent: / { sent[seq()] = 1 }
    /^outcome: / { o = substr($0, 10)
      if (last != "" && sub(/^outcome: no-reply — /, "")) { failed[last] = 1; why[last] = $0 } }
    END {
      if (last == "" || (last in sent) || o ~ /^(answer|withdrawn|cancelled)$/) exit
      if (last in failed) printf "%s\t%s\tfailed\t%s\n", last, since[last], why[last]
      else printf "%s\t%s\tunsent\t-\n", last, since[last]
    }'
}

# esc_config_ok <template> — one bash/sh command ending in "$1".."$6", no shell metacharacters.
esc_config_ok() {
  local args='"$1" "$2" "$3" "$4" "$5" "$6"' rest re='^[A-Za-z0-9_./~@%+=:," -]*$'
  local adapter='^(bash|sh) +[^ +-]'
  [[ "$1" == *" $args" ]] || return 1
  rest="${1% "$args"}"
  [[ "$rest" =~ $re ]] || return 1
  # The adapter comes first: an option (`bash -c|+c "…"`) shifts the positionals to $0..$5 of a
  # string that drops them, and no adapter runs the payload file itself as a script.
  [[ "${rest//\"/}" =~ $adapter ]] || return 1
  case "$rest" in "bash "*|"sh "*) return 0 ;; esac
  return 1
}

# A reping line that re-sent a started/retier request carries that request's seq: not a re-ping.
esc_repings() {
  esc_lines "$1" | awk '
    function seq(  i) { for (i = 1; i < NF; i++) if ($i == "seq") return $(i + 1); return "" }
    /^started: / { own[1] = 1 }
    /^retier: /  { own[seq()] = 1 }
    /^reping: /  { rp[seq()] = 1 }
    /^sent: /    { sent[seq()] = 1 }
    END { for (n in rp) if ((n in sent) && !(n in own)) c++; print c + 0 }'
}

esc_seen_reply() {
  [ "$2" != - ] || return 1
  esc_lines "$1" | grep -qF "reply: $2 "
}

esc_section() {  # esc_section <file> <heading> — body up to the next heading, trailing blanks cut
  awk -v h="## $2" '$0 == h {s = 1; next} s && /^## /{exit}
    s { l[++n] = $0; if (NF) last = n } END { for (i = 1; i <= last; i++) print l[i] }' "$1"
}

esc_escape() { printf '%s\n' "$1" | sed 's/^## / ## /'; }

esc_files() {  # esc_files <q> <comma list>
  local f
  grep -E '^- (spec|plan): ' <<<"$(esc_section "$1" Context)" || true
  local IFS=,
  for f in $2; do
    f="$(printf '%s' "$f" | sed 's/^ *//; s/ *$//')"
    [ -z "$f" ] || esc_escape "- $f"
  done
}

# esc_payload_build <q> <payload> <ticket> <team> <tier> <thread> <seq> <blocks> <options> <files>
#   <class> <recommend> <eligible|no>
esc_payload_build() {
  local q="$1" p="$2" ticket="$3" team="$4" tier="$5" thread="$6" seq="$7" blocks="$8"
  local options="$9" files="${10}" class="${11:-}" rec="${12:-}" elig="${13:-no}" who=analysts
  [ "$tier" != 3 ] || who=operator
  {
    printf '# Escalation %s — %s\n' "$thread" "$ticket"
    printf 'ticket: %s\nteam: %s\nrole: %s\nattempt: %s\nrun: %s\nquestion: %s\nkind: %s\n' \
      "$ticket" "$team" "$(esc_field "$q" role)" "$(esc_field "$q" attempt)" \
      "$(esc_field "$q" run)" "$(basename "$q" .md)" "$(esc_field "$q" kind)"
    printf 'tier: %s\n' "$tier"
    [ "$tier" != 2 ] || printf 'class: %s\nfallback: %s\n' "${class:-unclassified}" "$elig"
    printf 'decision-needed-from: %s\nthread: %s\nseq: %s\n\n' "$who" "$thread" "$seq"
    printf '## Question\n'; esc_escape "$(esc_section "$q" Summary)"
    printf '## Options\n'; esc_escape "${options:--}"
    [ -z "$rec" ] || { printf '## Recommendation\n'; esc_escape "$rec"; }
    printf '## Blocks\n'; esc_escape "$blocks"
    printf '## Files\n'; esc_files "$q" "$files"
    if [ "$elig" = eligible ]; then
      printf '## Reviewer\n'
      printf 'Reviewer: reply on this thread to Advisor with the sender in copy.\n'
      printf 'The first line of your reply must be exactly "opinion: agree" (you accept the '
      printf 'Recommendation; conditions go below it) or "opinion: disagree".\n'
      printf 'Your newest message here counts. If Advisor does not answer within the timeout, '
      printf '"opinion: agree" lets TeamLead deliver the Recommendation with your conditions.\n'
      printf '"opinion: agree" also attests that you checked this Question and Recommendation and '
      printf 'found no critical ground: an AC change, a contract (route, DTO, enum, SignalR, AF '
      printf 'queue message), a schema or migration, a sensitive path or prod boundary, a harness '
      printf 'rule, or an analyst conflict. The class above is TeamLead'"'"'s label; you vouch '
      printf 'for it.\n'
      printf 'If you find such a ground, reply "opinion: disagree" with the next line '
      printf '"class: <%s> — <why>". Unsure or a mixed scope counts as a ground.\n' \
        "$(tr ' ' '|' <<<"$ESC_CRITICAL")"
      printf 'With "opinion: agree" write no class line: every line below it is a condition.\n'
    fi
    printf '## Screen\n'; esc_section "$q" Screen
  } > "$p.tmp.$$"
  mv "$p.tmp.$$" "$p"
}

# esc_payload_header <payload> <tier> <seq> <reping reason or ""> <reping-kind or "">
esc_payload_header() {
  local who=analysts
  [ "$2" != 3 ] || who=operator
  awk -v t="$2" -v w="$who" -v s="$3" -v r="$4" -v k="$5" '
    /^## / { b = 1 }
    !b && /^(reping|reping-kind): / { next }
    !b && /^tier: / { print "tier: " t; next }
    !b && /^decision-needed-from: / { print "decision-needed-from: " w; next }
    !b && t == 3 && /^fallback: / { print "fallback: no"; next }
    !b && /^seq: / { print "seq: " s
      if (r != "") print "reping: " r
      if (k != "") print "reping-kind: " k
      next }
    { print }' "$1" > "$1.tmp.$$"
  mv "$1.tmp.$$" "$1"
}

esc_payload_recommend() {
  ! grep -qx "## Analysts' recommendation" "$1" || return 0
  { printf "## Analysts' recommendation\n"; esc_escape "$2"; } >> "$1"
}

# The reply recorded under the last `outcome: answer`, de-indented.
esc_last_answer() {
  esc_lines "$1" | awk '
    /^outcome: answer$/ { n = 0; on = 1; next }
    on && /^ended: / { next }
    on && (/^    / || /^$/) { l[++n] = substr($0, 5); next }
    on { on = 0 }
    END { for (i = 1; i <= n; i++) print l[i] }'
}

# esc_parse <reply file> — sets R_ID R_STATUS R_AUTHOR R_DECIDED R_REF R_ETA; 1 = no status line.
esc_parse() {
  local line first=1 re='^status: ([a-z-]+)$'
  R_ID=-; R_STATUS=""; R_AUTHOR=""; R_DECIDED=analysts; R_REF=""; R_ETA=""
  while IFS= read -r line || [ -n "$line" ]; do
    if [ "$first" = 1 ] && [[ "$line" == "mail-id: "* ]]; then
      R_ID="${line#mail-id: }"; continue
    fi
    if [ "$first" = 1 ]; then
      [[ "$line" =~ $re ]] || return 1
      R_STATUS="${BASH_REMATCH[1]}"; first=0; continue
    fi
    [ -n "$line" ] || break
    case "$line" in
      "author: "*) R_AUTHOR="${line#author: }" ;;
      "decided-by: "*) R_DECIDED="${line#decided-by: }" ;;
      "operator-ref: "*) R_REF="${line#operator-ref: }" ;;
      "eta: "*) R_ETA="${line#eta: }" ;;
    esac
  done < "$1"
  [ -n "$R_STATUS" ]
}
