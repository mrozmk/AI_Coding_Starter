# Helpers for team-escalate.sh (TT-852): ledger queries, payload, reply parsing.
# Sourced after team-lib.sh; contract: .agents/reference/team-mode.md §10 (mechanics 4).

ESC_REPING_CAP=2

# Header fields sit above the first heading; the body below may hold arbitrary text.
esc_field() {
  awk -v k="$2: " '/^## /{exit} index($0, k) == 1 {print substr($0, length(k) + 1); exit}' "$1"
}

esc_lines() { awk '/^## /{sec = substr($0, 4); next} sec == "Escalation"' "$1"; }

# Pre-TT-852 ledgers wrote `started:` without a tier; they were all tier 2.
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

esc_sent_count() { esc_lines "$1" | grep -c '^sent: ' || true; }
esc_next_seq() { echo $(( $(esc_sent_count "$1") + 1 )); }

# Seq of the last request (started = 1, reping/retier = its seq) that has no `sent:` line.
esc_outstanding() {
  esc_lines "$1" | awk '
    function seq(  i) { for (i = 1; i < NF; i++) if ($i == "seq") return $(i + 1); return "" }
    /^started: / { last = 1 }
    /^(reping|retier): / { last = seq() }
    /^sent: / { sent[seq()] = 1 }
    END { if (last != "" && !(last in sent)) print last }'
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
esc_payload_build() {
  local q="$1" p="$2" ticket="$3" team="$4" tier="$5" thread="$6" seq="$7" blocks="$8"
  local options="$9" files="${10}" who=analysts
  [ "$tier" != 3 ] || who=operator
  {
    printf '# Escalation %s — %s\n' "$thread" "$ticket"
    printf 'ticket: %s\nteam: %s\nrole: %s\nattempt: %s\nrun: %s\nquestion: %s\nkind: %s\n' \
      "$ticket" "$team" "$(esc_field "$q" role)" "$(esc_field "$q" attempt)" \
      "$(esc_field "$q" run)" "$(basename "$q" .md)" "$(esc_field "$q" kind)"
    printf 'tier: %s\ndecision-needed-from: %s\nthread: %s\nseq: %s\n\n' \
      "$tier" "$who" "$thread" "$seq"
    printf '## Question\n'; esc_escape "$(esc_section "$q" Summary)"
    printf '## Options\n'; esc_escape "${options:--}"
    printf '## Blocks\n'; esc_escape "$blocks"
    printf '## Files\n'; esc_files "$q" "$files"
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
