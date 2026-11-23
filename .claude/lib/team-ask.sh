#!/usr/bin/env bash
# The per-run ask channel: every blocking stop of a stage in a run with a per-run TeamLead, filed
# by the stage hook (.claude/hooks/team-ask-hook.sh) and answered by the lead (team-answer.sh).
# Sourceable library (the hook, the sender, the runner, team-lead.sh) and a small CLI:
#   bash .claude/lib/team-ask.sh wait a-<n> [--secs N]   (a stage, after a Stop fallback; default 540)
#   bash .claude/lib/team-ask.sh list                    bash .claude/lib/team-ask.sh show a-<n>
# wait prints the answer's text form and marks the ask delivered, or `pending — run this again`;
# exit 0 either way (2 usage, 4 no such ask).
#
# File contract (the hook and the lead run the main checkout's copy; a lead on an older profile
# still runs the clone's: this is the format every copy shares). <clone>/.agents/team/runs/<run>/asks/ — every round of the run, each ask carries it:
#   a-<n>.json         {id, kind: question|permission|plan|text, role, attempt, round, session_id,
#                       hook_session_id?, agent_id, agent_type, payload, tier: class|lead|operator,
#                       tier_cause, retry_key?, fp, state, filed_at, waiter_pid?, claimed_by?,
#                       requires_decision?}
#                      payload: the hook's {tool_name, tool_input} ({tool_name, tool_input, cwd}
#                      for a permission, cwd canonical) or {text, source}; source `message` or
#                      `record:<path relative to runs/<run>/>` (the `acked` format).
#                      fp = sha1(kind + agent_id + canonical payload). retry_key: the checker's
#                      `retry:` line (sha1 of the input and the files it names, or none).
#   a-<n>.answer.json  {id, form, value, authority, why, decision, answered_at, lead_session_id};
#                      form allow|deny|answers|pick|text. Created once (ln, never over a file).
#   .lock/pid          the ask lock (mkdir; a dead holder is reclaimed).
#   .stop-<session>    epoch of the last Stop the hook saw for that session.
#   .rung-a-<n>        epoch of the runner's last ring for that ask.
# States: waiting (a live waiter_pid polls) → timed-out (the waiter returned its fallback) →
# answered (the answer file exists) → delivering (claimed_by one hook or wait) → delivered; or
# withdrawn. delivered and withdrawn are terminal. A permission ask is withdrawn at its waiter's
# deadline (its retry files a new ask) unless it is operator-tier with a retry key: that one times
# out, keeps its decision, and is claimed by the retry of the same session, hook session, attempt,
# agent, cwd, input and key — only when exactly one such ask exists (ask_retry_ok).
# Bash 3.2 + jq. Contract: .agents/reference/team-lead.md §6

ASK_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ASK_TD="${ASK_TD:-}"; ASK_RUN="${ASK_RUN:-}"; ASK_D="${ASK_D:-}"; ASK_ID=""; ASK_NEW=0

# ask_init <team dir> — ASK_TD, ASK_RUN (session.json run, else the run file), ASK_D.
ask_init() {
  ASK_TD="$1"
  ASK_RUN="$(jq -r '.run // empty' "$ASK_TD/session.json" 2>/dev/null || true)"
  [ -n "$ASK_RUN" ] || ASK_RUN="$(cat "$ASK_TD/run" 2>/dev/null || true)"
  [ -n "$ASK_RUN" ] || return 1
  ASK_D="$ASK_TD/runs/$ASK_RUN/asks"
}
ask_dir() { echo "$ASK_D"; }
ask_utc() { date -u +%Y-%m-%dT%H:%M:%SZ; }
ask_alive() { [ -n "${1:-}" ] && [ "$1" != null ] && kill -0 "$1" 2>/dev/null; }
ask_path() { echo "$ASK_D/$1.json"; }
ask_get() { jq -r --arg k "$2" '.[$k] // empty | tostring' "$ASK_D/$1.json" 2>/dev/null; }
ask_valid_id() { [[ "${1:-}" =~ ^a-[0-9]+$ ]]; }

ask_lock() {
  local i=0 p
  mkdir -p "$ASK_D"
  until mkdir "$ASK_D/.lock" 2>/dev/null; do
    p="$(cat "$ASK_D/.lock/pid" 2>/dev/null || true)"
    if [ -n "$p" ] && ! kill -0 "$p" 2>/dev/null; then
      rm -f "$ASK_D/.lock/pid"; rmdir "$ASK_D/.lock" 2>/dev/null || true; continue
    fi
    [ "$i" -lt 100 ] || { echo "error: ask lock $ASK_D/.lock held" >&2; return 1; }
    sleep 0.1; i=$((i + 1))
  done
  echo "$$" > "$ASK_D/.lock/pid"
}
ask_unlock() { rm -f "$ASK_D/.lock/pid"; rmdir "$ASK_D/.lock" 2>/dev/null || true; }

# ask_set <id> <jq filter> [jq args…] — rewrite the ask file (tmp + mv), under the lock.
ask_set() {
  local id="$1" f="$ASK_D/$1.json"; shift
  jq "$@" "$f" > "$ASK_D/.$id.json.tmp" && mv "$ASK_D/.$id.json.tmp" "$f"
}

# ask_retry_ok <id> — a permission ask that outlives its waiter's deadline: operator-tier with a
# retry key (the one eligibility rule of timeout, reconcile, claim and fallback).
ask_retry_ok() {
  [ "$(ask_get "$1" tier)" = operator ] || return 1
  case "$(ask_get "$1" retry_key)" in ""|none) return 1 ;; esac
}

# ask_reconcile <id> — under the lock: an answer file wins over waiting|timed-out; a dead waiter
# times out (a permission ask is withdrawn); a dead delivery claimer gives the answer back.
ask_reconcile() {
  local id="$1" st
  st="$(ask_get "$id" state)"
  if [ -f "$ASK_D/$id.answer.json" ]; then
    case "$st" in waiting|timed-out) ask_set "$id" '.state = "answered"'; st=answered ;; esac
  fi
  case "$st" in
    waiting) ask_alive "$(ask_get "$id" waiter_pid)" && return 0
      if [ "$(ask_get "$id" kind)" = permission ] && ! ask_retry_ok "$id"; then ask_set "$id" '.state = "withdrawn"'
      else ask_set "$id" '.state = "timed-out"'; fi ;;
    delivering) ask_alive "$(ask_get "$id" claimed_by)" \
      || ask_set "$id" '.state = "answered" | del(.claimed_by)' ;;
  esac
  return 0
}

# ask_cas <id> "<expected states>" <new state> [pid key] — the only state writer. 0 when moved.
# delivered and withdrawn are never left. With a pid key, that key records this process.
ask_cas() {
  local id="$1" exp="$2" new="$3" key="${4:-}" st rc=1
  ask_lock || return 1
  if [ -f "$ASK_D/$id.json" ]; then
    ask_reconcile "$id"; st="$(ask_get "$id" state)"
    case " $exp " in *" $st "*)
      case "$st" in delivered|withdrawn) ;; *)
        if [ -n "$key" ]; then ask_set "$id" '.state = $s | .[$k] = ($p | tonumber)' \
          --arg s "$new" --arg k "$key" --arg p "${ASK_PID:-$$}"
        else ask_set "$id" '.state = $s | if $s == "delivered" then .delivered_at = $at else . end' \
          --arg s "$new" --arg at "$(ask_utc)"; fi
        rc=0 ;;
      esac ;;
    esac
  fi
  ask_unlock; return "$rc"
}

# ask_state <id> → its state, reconciled under the lock.
ask_state() {
  ask_lock || return 1
  [ ! -f "$ASK_D/$1.json" ] || ask_reconcile "$1"
  ask_get "$1" state; ask_unlock
}

ask_fp() {  # ask_fp <kind> <agent_id> <payload json>
  printf '%s%s%s' "$1" "$2" "$(jq -cS . <<<"$3")" | shasum -a 1 | cut -d' ' -f1
}

# ask_file <ask json file> — {kind, role, attempt, round, session_id, agent_id, agent_type,
# payload, tier, tier_cause[, requires_decision]} → prints a-<n> and sets ASK_ID, ASK_NEW (1 for
# a new ask, 0 for a claim; call it without a subshell to read them). Claims (question/plan/text)
# the first ask of the same session and fp that is timed-out, or answered with no live waiter;
# never a waiting one. A permission claims only under ask_retry_ok's rule (see the header): one
# match → claimed, several → all withdrawn; the same call with another key withdraws its old ask.
# Else files a-<max+1>. The ask is published with its tier already set.
# ask_retry_claim <sid> <hook sid> <attempt> <agent id> <fp> <retry key> — under the lock: prints
# the one timed-out (or answered, waiter gone) operator-tier permission ask this call repeats; rc 1
# when none. An ask of the same call with another key is superseded, several matches are ambiguous.
ask_retry_claim() {
  local id st cands=""
  for id in $(ask_ids); do
    jq -e --arg sid "$1" --arg hs "$2" --arg att "$3" --arg aid "$4" --arg fp "$5" '
      def g($k): [.[$k] // empty | tostring][0] // "";
      g("kind") == "permission" and g("session_id") == $sid and g("hook_session_id") == $hs
      and g("attempt") == $att and g("agent_id") == $aid and g("fp") == $fp
      and g("tier") == "operator" and (.payload | has("cwd"))' "$ASK_D/$id.json" >/dev/null 2>&1 \
      || continue
    ask_reconcile "$id"; st="$(ask_get "$id" state)"
    if [ "$(ask_get "$id" retry_key)" != "$6" ]; then
      # Superseded: the same call, but a file it names changed — that approval cannot apply.
      [ "$st" != timed-out ] || ask_set "$id" '.state = "withdrawn"'
      continue
    fi
    case "$st" in
      timed-out) cands="$cands $id" ;;
      answered) ask_alive "$(ask_get "$id" waiter_pid)" || cands="$cands $id" ;;
    esac
  done
  case "$(wc -w <<<"$cands" | tr -d ' ')" in
    0) return 1 ;;
    1) printf '%s\n' "${cands# }" ;;
    # Ambiguous: no guess. Each is withdrawn (the runner withdraws its decision), a new ask filed.
    *) for id in $cands; do ask_set "$id" '.state = "withdrawn"'; done; return 1 ;;
  esac
}

ask_file() {
  local in="$1" kind sid fp id n st w rk
  ASK_ID=""; ASK_NEW=0
  kind="$(jq -r .kind "$in")"; sid="$(jq -r '.session_id // ""' "$in")"
  fp="$(ask_fp "$kind" "$(jq -r '.agent_id // ""' "$in")" "$(jq -c '.payload' "$in")")"
  ask_lock || return 1
  if [ "$kind" != permission ]; then
    for id in $(ask_ids); do
      [ "$(ask_get "$id" session_id)" = "$sid" ] && [ "$(ask_get "$id" fp)" = "$fp" ] || continue
      ask_reconcile "$id"; st="$(ask_get "$id" state)"; w="$(ask_get "$id" waiter_pid)"
      case "$st" in
        timed-out) ask_set "$id" '.state = "waiting" | .waiter_pid = ($p | tonumber)' --arg p "${ASK_PID:-$$}" ;;
        answered) ask_alive "$w" && continue
          ask_set "$id" '.waiter_pid = ($p | tonumber)' --arg p "${ASK_PID:-$$}" ;;
        *) continue ;;
      esac
      ask_unlock; ASK_ID="$id"; echo "$id"; return 0
    done
  elif [ "$(jq -r '.tier // ""' "$in")" = operator ] && rk="$(jq -r '.retry_key // ""' "$in")" \
      && [ -n "$rk" ] && [ "$rk" != none ]; then
    # An operator-tier permission retried after its deadline claims the one ask it repeats.
    if id="$(ask_retry_claim "$sid" "$(jq -r '.hook_session_id // ""' "$in")" \
        "$(jq -r '.attempt | tostring' "$in")" "$(jq -r '.agent_id // ""' "$in")" "$fp" "$rk")"; then
      if [ "$(ask_get "$id" state)" = timed-out ]; then
        ask_set "$id" '.state = "waiting" | .waiter_pid = ($p | tonumber)' --arg p "${ASK_PID:-$$}"
      else ask_set "$id" '.waiter_pid = ($p | tonumber)' --arg p "${ASK_PID:-$$}"; fi
      ask_unlock; ASK_ID="$id"; echo "$id"; return 0
    fi
  fi
  n="$(ls "$ASK_D" 2>/dev/null | sed -n 's/^a-\([0-9]*\)\.json$/\1/p' | sort -n | tail -n 1)"
  n=$(( ${n:-0} + 1 )); id="a-$n"
  jq --arg id "$id" --arg fp "$fp" --arg at "$(ask_utc)" --arg p "${ASK_PID:-$$}" \
    '{id: $id} + . + {fp: $fp, state: "waiting", filed_at: $at, waiter_pid: ($p | tonumber)}' \
    "$in" > "$ASK_D/.$id.json.tmp" && mv "$ASK_D/.$id.json.tmp" "$ASK_D/$id.json" \
    || { ask_unlock; return 1; }
  ask_unlock; ASK_ID="$id"; ASK_NEW=1; echo "$id"
}

# ask_answer_write <id> <answer json> — durable, once: refuses (6) when the answer exists.
ask_answer_write() {
  local id="$1" f="$ASK_D/$1.answer.json" tmp="$ASK_D/.$1.answer.$$.tmp"
  [ ! -e "$f" ] || { echo "error: ask $id already answered" >&2; return 6; }
  printf '%s\n' "$2" > "$tmp" || return 1
  if ! ln "$tmp" "$f" 2>/dev/null; then
    rm -f "$tmp"; echo "error: ask $id already answered" >&2; return 6
  fi
  rm -f "$tmp"
}

# ask_reject <id> — an answer the hook could not verify moves aside (kept for the audit as
# a-<n>.answer.rejected-<epoch>-<pid>.json) and the ask times out: else ask_reconcile would revive
# it as answered on every retry, and the lead could neither see nor re-answer the ask.
ask_reject() {
  local id="$1"
  ask_lock || return 1
  [ ! -f "$ASK_D/$id.answer.json" ] \
    || mv "$ASK_D/$id.answer.json" "$ASK_D/$id.answer.rejected-$(date +%s)-$$.json"
  case "$(ask_get "$id" state)" in answered|delivering) ask_set "$id" '.state = "timed-out"' ;; esac
  ask_unlock
}

# ask_poll <id> <deadline epoch> → prints the answer JSON (0), 1 on the deadline, 2 withdrawn.
ask_poll() {
  while :; do
    if [ -f "$ASK_D/$1.answer.json" ]; then cat "$ASK_D/$1.answer.json"; return 0; fi
    [ "$(ask_get "$1" state)" != withdrawn ] || return 2
    [ "$(date +%s)" -lt "$2" ] || return 1
    sleep 1
  done
}

# ask_claim_delivery <id> → 0 when this process now delivers it (answered → delivering).
ask_claim_delivery() { ask_cas "$1" "answered" delivering claimed_by; }
ask_delivered() { ask_cas "$1" "delivering" delivered; }

# ask_timeout <id> → prints the state after the waiter's deadline: answered (deliver after all),
# timed-out, or withdrawn (a permission ask that ask_retry_ok refuses).
ask_timeout() {
  local st
  ask_lock || return 1
  ask_reconcile "$1"; st="$(ask_get "$1" state)"
  if [ "$st" = waiting ]; then
    if [ "$(ask_get "$1" kind)" = permission ] && ! ask_retry_ok "$1"; then st=withdrawn; else st=timed-out; fi
    ask_set "$1" '.state = $s' --arg s "$st"
  fi
  ask_unlock; echo "$st"
}

# ask_open_for_record <ref> — the ask whose source is record:<ref>, any state, or nothing.
ask_open_for_record() {
  local id
  for id in $(ask_ids); do
    [ "$(jq -r '.payload.source // empty' "$ASK_D/$id.json")" = "record:$1" ] && { echo "$id"; return 0; }
  done
  return 0
}

# ask_one_line <id> — 160 characters at most: first question / tool + command / plan / text.
ask_one_line() {
  jq -r '.kind as $k | .payload as $p
    | (if (.agent_id // "") != "" then "(sub-agent \(.agent_type // "?")) " else "" end)
    + (if $k == "question" then ($p.tool_input.questions[0].question // "question")
       elif $k == "permission" then "\($p.tool_name // "tool") \($p.tool_input.command // $p.tool_input.file_path // $p.tool_input.notebook_path // $p.tool_input.url // "" | tostring | .[0:120])"
       elif $k == "plan" then ($p.tool_input.plan // "plan" | split("\n") | map(select(length > 0)) | .[0] // "plan")
       else ($p.text // "" | .[0:120]) end)
    | gsub("[\n\r\t]"; " ") | .[0:160]' "$ASK_D/$1.json" 2>/dev/null
}

# ask_ring_line <id> — the lead's doorbell line of an ask (the hook and the runner both ring it):
# `ask <role> a-<n>[ operator]: <one line>`.
ask_ring_line() {
  local op=""
  [ "$(ask_get "$1" tier)" != operator ] || op=" operator"
  echo "ask $(ask_get "$1" role) $1$op: $(ask_one_line "$1")"
}

ask_ids() {  # ask_ids — every ask id, by n
  [ -d "$ASK_D" ] || return 0
  { ls "$ASK_D" 2>/dev/null || true; } | sed -n 's/^\(a-[0-9]*\)\.json$/\1/p' | sort -t- -k2,2n
}

# ask_list — one line per ask not delivered|withdrawn.
ask_list() {
  local id st
  for id in $(ask_ids); do
    st="$(ask_get "$id" state)"
    case "$st" in delivered|withdrawn) continue ;; esac
    echo "$id $(ask_get "$id" role) $(ask_get "$id" kind) $(ask_get "$id" tier) $st — $(ask_one_line "$id")"
  done
}
ask_show() { cat "$ASK_D/$1.json"; [ ! -f "$ASK_D/$1.answer.json" ] || cat "$ASK_D/$1.answer.json"; }

# ask_answers_line <id> — the answers.md line of an answered ask (the sender and the runner both
# write it, so it is built once, here). The value is never cut: a tracker reconciliation's
# id@sha256 tokens are read back from it.
ask_answers_line() {
  local a="$ASK_D/$1.answer.json" v
  v="$(jq -r 'if .form == "answers" then (.value | to_entries | map("\(.key) → \(.value)") | join("; "))
    else (.value // "" | tostring) end | gsub("[\n\r]"; " ")' "$a")"
  printf -- '- %s [%s %s] ask %s %s → %s%s — %s [authority %s]%s\n' \
    "$(jq -r .answered_at "$a")" "$(ask_get "$1" role)" "$(ask_get "$1" attempt)" "$1" \
    "$(ask_one_line "$1")" "$(jq -r .form "$a")" "${v:+: $v}" "$(jq -r '.why // ""' "$a")" \
    "$(jq -r .authority "$a")" "$(jq -r 'if (.decision // "") != "" then " [decision \(.decision)]" else "" end' "$a")"
}

# ask_follow_up <id> — from the answer file: the answers.md line (once per ask) and, for an ask
# whose source is a record, that record's .answered marker. Safe to repeat in any order.
ask_follow_up() {
  local id="$1" rd="$ASK_TD/runs/$ASK_RUN" src
  [ -f "$ASK_D/$id.answer.json" ] || return 0
  grep -qF "] ask $id " "$rd/answers.md" 2>/dev/null || ask_answers_line "$id" >> "$rd/answers.md"
  src="$(jq -r '.payload.source // empty' "$ASK_D/$id.json" 2>/dev/null || true)"
  case "$src" in record:*)
    [ ! -f "$rd/${src#record:}" ] || [ -e "$rd/${src#record:}.answered" ] \
      || touch "$rd/${src#record:}.answered" ;;
  esac
  return 0
}

# ask_reply_map <id> <reply> — a multi-question reply `<header>: <label>; …` → the canonical
# {question: label} map, or rc≠0: a fragment that is no `<header>: <label>`, an unknown or repeated
# header, or a key set other than the ask's questions — what the sender would refuse anyway.
ask_reply_map() {
  jq -cS --arg r "$2" '[.payload.tool_input.questions[] | {k: (.header // .question), q: .question}] as $qs
    | ($r | split(";") | map(capture("^\\s*(?<h>[^:]+?)\\s*:\\s*(?<l>.+?)\\s*$") // error("fragment"))) as $ps
    | if ($ps | map(.h) | unique | length) != ($ps | length) then error("duplicate") else . end
    | if ($ps | length) != ($qs | length) then error("count") else . end
    | [$ps[] | . as $p | ($qs | map(select(.k == $p.h)) | .[0]) as $m
        | if $m == null then error("header") else {key: $m.q, value: $p.l} end] | from_entries
    | if (keys | sort) != ($qs | map(.q) | sort) then error("keys") else . end' \
    "$ASK_D/$1.json" 2>/dev/null
}

# ask_parse_reply <id> <d-id> <message> — the Operator's whole reply to a decision bound to ask
# <id> → {"outcome","value","map"} (compact), or rc≠0. One parser for decision answer (the lead's
# call) and the stage hook's re-verification (main checkout): the message, trimmed, must start
# with "<d-id> "; permission|plan read `allow` | `deny[: <what instead>]`; several questions read
# `<header>: <label>; …` (ask_reply_map); anything else is the answer text.
ask_parse_reply() {
  local id="$1" did="$2" m rest out="" val="" map=null
  m="$(jq -rn --arg m "$3" '$m | sub("^\\s+"; "") | sub("\\s+$"; "")')" || return 1
  case "$m" in "$did "*) rest="${m#"$did "}" ;; *) return 1 ;; esac
  # Left-trim like the frontmatter readers (dfm, dfm_h) so the recorded answer and the hook's
  # re-parse hold the same string.
  rest="${rest#"${rest%%[![:space:]]*}"}"
  case "$(ask_get "$id" kind)" in
    permission|plan)
      case "$rest" in
        allow) out=allow ;;
        deny|"deny:"*) out=deny; val="${rest#deny}"; val="${val#:}"; val="${val#"${val%%[![:space:]]*}"}" ;;
        *) return 1 ;;
      esac ;;
    *) if [ "$(jq -r '.payload.tool_input.questions // [] | length' "$ASK_D/$id.json")" -gt 1 ]; then
         map="$(ask_reply_map "$id" "$rest")" || return 1
       else val="$rest"; fi ;;
  esac
  jq -cn --arg o "$out" --arg v "$val" --argjson m "$map" '{outcome: $o, value: $v, map: $m}'
}

# ask_text_form <answer json> — the answer as the stage reads it (wait, Stop block reason).
ask_text_form() {
  jq -r 'if .form == "allow" then "The TeamLead allowed it."
    elif .form == "deny" then "The TeamLead denied it: \(.value // "")"
    elif .form == "answers" then "The TeamLead answered: " + (.value | to_entries | map("\"\(.key)\" → \(.value)") | join("; "))
    else "The TeamLead answered: \(.value // "")" end' <<<"$1"
}

ask_main() {
  local op="${1:-}" id secs=540 root
  case "$op" in wait|list|show) ;; *)
    sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//' >&2; echo "usage: team-ask.sh wait a-<n> [--secs N] | list | show a-<n>" >&2; return 2 ;;
  esac
  shift
  root="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
  ask_init "$root/.agents/team" || { echo "error: no team run in $root" >&2; return 4; }
  case "$op" in
    list) ask_list; return 0 ;;
    show) ask_valid_id "${1:-}" && [ -f "$ASK_D/$1.json" ] || { echo "error: no ask ${1:-}" >&2; return 4; }
      ask_show "$1"; return 0 ;;
  esac
  id="${1:-}"; shift || true
  ask_valid_id "$id" || { echo "usage: team-ask.sh wait a-<n> [--secs N]" >&2; return 2; }
  if [ "${1:-}" = --secs ]; then [[ "${2:-}" =~ ^[0-9]+$ ]] || return 2; secs="$2"; fi
  [ -f "$ASK_D/$id.json" ] || { echo "error: no ask $id" >&2; return 4; }
  # Only this stage's own Stop ask: every other kind is delivered by its hook.
  [ "$(ask_get "$id" kind)" = text ] \
    && [ "$(ask_get "$id" session_id)" = "$(jq -r '.session_id // ""' "$ASK_TD/session.json" 2>/dev/null)" ] \
    || { echo "error: $id is not this stage's Stop ask" >&2; return 4; }
  local ans
  if ans="$(ask_poll "$id" $(( $(date +%s) + secs )))"; then
    if [ -e "$ASK_TD/cancel" ] || [ -e "$ASK_TD/closing" ]; then
      echo "withdrawn — the team was stopped; write nothing more"; return 0
    fi
    # An Operator-bound answer is verified by the Stop hook (main-checkout code), never here.
    if [ "$(jq -r .authority <<<"$ans")" = operator ] || [ "$(ask_get "$id" tier)" = operator ] \
        || [ -n "$(ask_get "$id" requires_decision)" ]; then
      echo "answered — end your turn now; the Stop hook checks and delivers the answer"; return 0
    fi
    if ask_claim_delivery "$id"; then
      ask_text_form "$ans"; ask_delivered "$id" || true; return 0
    fi
    [ "$(ask_state "$id")" != delivered ] || { echo "already delivered: $(ask_text_form "$ans")"; return 0; }
  fi
  [ "$(ask_get "$id" state)" != withdrawn ] || { echo "withdrawn — the team was stopped; write nothing more"; return 0; }
  echo "pending — run this again"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  set -uo pipefail
  ask_main "$@"; exit $?
fi
