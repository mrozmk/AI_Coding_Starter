#!/usr/bin/env bash
# #323 Supervisor clearance: the ledger, the switch and the helpers both carriers source
# (team-clearance-hook.sh — role profiles; team-ask-hook.sh — team stages).
# Usage: bash .claude/lib/team-clearance.sh show | grant | pause | pending
#        bash .claude/lib/team-clearance.sh answer <id> allow|deny|unsure
#   The switch IS the Operator's typed message in the registered Supervisor window — the whole
#   message, exactly:
#       clearance enforce <host>[,<host>] for <N>h|<N>d
#   (any case; at most 7 days; only trailing whitespace or one final period may follow). Hosts:
#   claude. Codex is refused: no hook decision there reaches approvals_reviewer, not a human. The
#   latest instruction governs: `revoke clearance` cancels for good, any other message starting
#   with `clearance` or `revoke clearance` that is no grant cancels too; a history that cannot be
#   read whole grants nothing.
#   grant: the Operator runs it after typing the switch. It reads that message and writes
#   <main>/.agents/team/clearance.json (mode 600, never in a clone) with the list version
#   (clearance-classes.json version + the policy digest of the trusted clearance code); refused
#   for a host with no shadow line under the current list version, and for a message older than
#   that version's first shadow line (#323 R1-7). show: the mode and the switch. pause: removes
#   the record (grant records the same message again). Every launch seals the record's sha256
#   into its hook command ({{SEAL}}): a switch typed after a launch enforces from the next launch;
#   a revoke, an expiry, a list change or a pause takes effect at once (shadow).
#   pending: every open request, rendered from the script's fields (masked). answer: the
#   Supervisor only, from the main checkout; it re-derives the class and the request hash from the
#   stored payload on the current tree and refuses a hard, none or changed class, a changed pin,
#   an expired, answered or used request, a switch that does not verify or a changed list. One
#   answer covers one exact request, once; the carrier claims it only with the Supervisor's own
#   `answer` call in its transcript.
# State: <main>/.agents/team/clearance/{requests,answers,used}/ (700, files 600), lock clearance/lock.
# Exit 0 ok · 1 refused / no switch · 2 usage · 4 state · 7 the Operator's switch is missing
# Limit: the same-account model (.agents/reference/security-egress.md → Supervisor clearance).
CLEARANCE_HOSTS="claude"
CLEARANCE_MAX_HOURS=168
CLEARANCE_CODEX="Codex: no hook decision reaches approvals_reviewer, not a human — shadow only (#323)"
CLEARANCE_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

clearance_file() { printf '%s/.agents/team/clearance.json' "$1"; }
clearance_dir() { printf '%s/.agents/team/clearance' "$1"; }
clearance_checker() { printf '%s/.claude/hooks/lib/guard_team_egress_clear.py' "$1"; }
clearance_sha() { shasum -a 256 < "$1" 2>/dev/null | cut -d' ' -f1; }
# clearance_seal <main> → the sha256 of the switch record, or off: what a launch seals into its
# hook command ({{SEAL}}) and what clearance_mode compares against.
clearance_seal() {
  local f s=""; f="$(clearance_file "$1")"
  [ ! -f "$f" ] || s="$(clearance_sha "$f")"
  echo "${s:-off}"
}
# clearance_fill_rules <main> <project> <profile> → the profile with {{RULES}} in every hook
# command replaced by the digest of that launch's rules (R2-8), or unknown when it cannot be computed.
clearance_fill_rules() {
  local d; d="$(python3 -I "$(clearance_checker "$1")" rules-digest --project "$2" --rules "$3" --main "$1" 2>/dev/null)" || d=""
  jq --arg d "${d:-unknown}" '.hooks |= map_values(map(.hooks |= map(if (.command | type) == "string"
    then .command |= gsub("\\{\\{RULES\\}\\}"; $d) else . end)))' "$3"
}

# clearance_parse <message> → "<hosts>\t<hours>"; rc 1 unless the WHOLE message, trimmed, is the
# switch phrase (a host codex is refused with the recorded reason on stderr).
clearance_parse() {
  local lt re hosts h n unit hours
  case "$1" in *$'\n'*) return 1 ;; esac
  lt="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  lt="${lt#"${lt%%[![:space:]]*}"}"; lt="${lt%"${lt##*[![:space:]]}"}"
  re='^clearance[[:space:]]+enforce[[:space:]]+([a-z]+(,[a-z]+)*)[[:space:]]+for[[:space:]]+([1-9][0-9]{0,3})(h|d)\.?$'
  [[ "$lt" =~ $re ]] || return 1
  hosts="${BASH_REMATCH[1]}"; n="${BASH_REMATCH[3]}"; unit="${BASH_REMATCH[4]}"
  hours="$n"; [ "$unit" = h ] || hours=$(( n * 24 ))
  [ "$hours" -le "$CLEARANCE_MAX_HOURS" ] || return 1
  for h in ${hosts//,/ }; do
    [ "$h" != codex ] || { echo "$CLEARANCE_CODEX" >&2; return 1; }
    case " $CLEARANCE_HOSTS " in *" $h "*) ;; *) return 1 ;; esac
  done
  printf '%s\t%s\n' "$(printf '%s\n' ${hosts//,/ } | sort -u | paste -sd, -)" "$hours"
}

clearance_libs() {
  command -v mandate_history >/dev/null 2>&1 || . "$CLEARANCE_LIB/team-mandate.sh" 2>/dev/null || return 3
  command -v team_role_transcript >/dev/null 2>&1 || { . "$CLEARANCE_LIB/team-lib.sh" && . "$CLEARANCE_LIB/team-lead-lib.sh"; } >/dev/null 2>&1 || return 3
  command -v team_evidence_machine_line >/dev/null 2>&1 || . "$CLEARANCE_LIB/team-evidence.sh" 2>/dev/null || return 3
}

# clearance_list_version <main> → <version>-<16 hex of the policy digest>; rc 1 when it cannot be
# computed (a trusted module missing from the list fails closed).
clearance_list_version() { python3 -I "$(clearance_checker "$1")" digest --main "$1" 2>/dev/null; }

# clearance_derive <main> → the governing switch instruction as compact JSON {id, uuid,
# session_id, hosts, granted_at, expires_at, words}; rc 1 (reason on stderr) when there is none.
clearance_derive() {
  local rows last m p sid
  clearance_libs || { echo "team-lib.sh, team-lead-lib.sh, team-evidence.sh or team-mandate.sh missing" >&2; return 1; }
  rows="$(mandate_history "$1" "" clearance)" || return 1
  sid="$(jq -r '.session_id // empty' "$1/.agents/team/registry/Supervisor.json" 2>/dev/null || true)"
  last="$(tail -n 1 <<<"$rows")"
  [ -n "$last" ] && [ -n "$sid" ] || { echo "no clearance message in the Supervisor window" >&2; return 1; }
  m="$(jq -r .m <<<"$last")"
  p="$(clearance_parse "$m")" || { echo "the Operator's latest clearance instruction is no grant: $(printf '%s' "$m" | head -n 1 | cut -c1-120)" >&2; return 1; }
  jq -cen --argjson r "$last" --arg s "$sid" --arg h "$(cut -f1 <<<"$p")" --argjson n "$(cut -f2 <<<"$p")" '
    (($r.ts | fromdateiso8601) + $n * 3600) as $e | select($e > now)
    | {id: ("s-" + $r.uuid), uuid: $r.uuid, session_id: $s, hosts: ($h | split(",")), granted_at: $r.ts,
       expires_at: ($e | todateiso8601), words: $r.m}' 2>/dev/null \
    || { echo "the Operator's latest clearance switch has expired" >&2; return 1; }
}

# clearance_verified <main> → the switch in force: the governing instruction, the local record
# naming that very message, and the record's list version the current one.
clearance_verified() {
  local d f lv; f="$(clearance_file "$1")"
  d="$(clearance_derive "$1")" || return 1
  lv="$(clearance_list_version "$1")" && [ -n "$lv" ] || { echo "the list version cannot be computed" >&2; return 1; }
  [ -f "$f" ] && [ ! -L "$f" ] && [ "$(jq -r '.id // ""' "$f" 2>/dev/null)" = "$(jq -r .id <<<"$d")" ] \
    || { echo "the switch is not recorded (bash .claude/lib/team-clearance.sh grant) or is paused" >&2; return 1; }
  [ "$(jq -r '.list_version // ""' "$f" 2>/dev/null)" = "$lv" ] \
    || { echo "the class list or the trusted clearance code changed since the grant (list $lv)" >&2; return 1; }
  jq -c --arg lv "$lv" '. + {list_version: $lv}' <<<"$d"
}

# clearance_mode <host> <seal> <main> → enforce | shadow. Enforce only for host claude, a switch
# that verifies now and names the host, and a record whose sha256 is the seal of this launch.
clearance_mode() {
  local f="$(clearance_file "$3")" v
  if [ "$1" = claude ] && [ -n "$2" ] && [ "$2" != off ] && [ -f "$f" ] && [ ! -L "$f" ] \
      && [ "$(clearance_seal "$3")" = "$2" ] && v="$(clearance_verified "$3" 2>/dev/null)" \
      && jq -e --arg h "$1" '.hosts | index($h) != null' <<<"$v" >/dev/null 2>&1; then
    echo enforce
  else
    echo shadow
  fi
}

# clearance_shadow_first <main> <host> <list version> → the time of the first shadow line of that
# host under that list version in the touch log, or nothing.
clearance_shadow_first() {
  local f
  for f in "$1"/.agents/touches/*.jsonl; do
    [ -f "$f" ] && [ ! -L "$f" ] || continue
    jq -r --arg h "$2" --arg v "$3" 'select(type == "object" and .kind == "shadow"
      and (.clearance.host // "") == $h and (.clearance.list_version // "") == $v) | .at' "$f" 2>/dev/null || true
  done | sort | head -n 1
}

clearance_lock() {
  local d i=0 p; d="$(clearance_dir "$1")"
  ( umask 077; mkdir -p "$d/requests" "$d/answers" "$d/used" ) || return 1
  chmod 700 "$d" "$d/requests" "$d/answers" "$d/used" 2>/dev/null
  until mkdir "$d/lock" 2>/dev/null; do
    p="$(cat "$d/lock/pid" 2>/dev/null || true)"
    if [ -n "$p" ] && ! kill -0 "$p" 2>/dev/null; then rm -f "$d/lock/pid"; rmdir "$d/lock" 2>/dev/null || true; continue; fi
    [ "$i" -lt 100 ] || { echo "error: clearance lock $d/lock held" >&2; return 1; }
    sleep 0.1; i=$((i + 1))
  done
  echo "$$" > "$d/lock/pid"
}
clearance_unlock() { local d; d="$(clearance_dir "$1")"; rm -f "$d/lock/pid"; rmdir "$d/lock" 2>/dev/null || true; }

# clearance_classify <main> <payload file> <request or who json> [<binding json>] → the checker's lines
# for that payload, with the asking session's project, ctx, rules and role (from the request, or
# from the caller's CL_* values).
clearance_classify() {
  local m="$1" p="$2" w="${3:-}" proj ctx rules role team lr b="${4:-}"
  [ -n "$w" ] || w='{}'
  proj="$(jq -r .project <<<"$w")"; ctx="$(jq -r .ctx <<<"$w")"; rules="$(jq -r '.rules // ""' <<<"$w")"
  role="$(jq -r '.role // ""' <<<"$w")"; team="$(jq -r '.team // ""' <<<"$w")"; lr="$(jq -r '.launch_rules // ""' <<<"$w")"
  [ "$ctx" = stage ] || team=""
  ( cd "$(jq -r '.cwd // empty' "$p" 2>/dev/null || echo "$proj")" 2>/dev/null || cd "$proj" || exit 1
    env -u TEAM_SESSION_ROLE -u TEAM_RUN_TEAM ${role:+TEAM_SESSION_ROLE=$role} ${team:+TEAM_RUN_TEAM=$team} \
      CLAUDE_PROJECT_DIR="$proj" python3 -I "$(clearance_checker "$m")" classify --input-json "$p" --project "$proj" \
      --ctx "$ctx" --main "$m" ${rules:+--rules "$rules"} ${lr:+--launch-rules "$lr"} ${b:+--binding "$b"} 2>/dev/null )
}

# clearance_open <main> <payload file> <who json> → the id of a filed request (rc 0), rc 1 when the
# switch does not verify or the payload is no clearable class for that session. who: {ctx,
# project, rules, launch_rules, role, session_id, team, run, attempt, ticket, host, wait,
# agent_id, agent_type}. The binding (session, role, team, run, attempt, switch, list version) is
# hashed into the request: the id the Supervisor types names exactly this payload and requester.
clearance_open() {
  local m="$1" sw b out meta
  sw="$(clearance_verified "$m" 2>/dev/null)" || return 1
  b="$(jq -c --argjson s "$sw" '{session_id: (.session_id // ""), role: (.role // ""), team: (.team // ""),
    run: (.run // ""), attempt: (.attempt // "" | tostring), switch_id: $s.id, list_version: $s.list_version}' <<<"$3")" || return 1
  out="$(clearance_classify "$m" "$2" "$3" "$b")"
  [ "$(sed -n 's/^result: //p' <<<"$out")" = clearable ] && [ -n "$(sed -n 's/^hash: //p' <<<"$out")" ] || return 1
  meta="$(jq -c --arg c "$(sed -n 's/^class: //p' <<<"$out")" --argjson pins "$(sed -n 's/^pins: //p' <<<"$out")" \
    --arg dest "$(sed -n 's/^dest: //p' <<<"$out")" --arg h "$(sed -n 's/^hash: //p' <<<"$out")" --argjson b "$b" \
    '. + {class: $c, pins: $pins, dest: $dest, hash: $h, binding: $b}' <<<"$3")" || return 1
  clearance_request "$m" "$2" "$meta"
}

# clearance_request <main> <payload file> <meta json> → the id of a new request. meta: {class,
# pins, dest, hash, binding, role, session_id, agent_id, agent_type, team, run, ticket, host,
# project, ctx, rules, wait}. The id is content-bound: c-<n>-<first 16 hex of the request hash>.
clearance_request() {
  local m="$1" d n id now exp
  d="$(clearance_dir "$m")"
  clearance_lock "$m" || return 1
  n="$(ls "$d/requests" 2>/dev/null | sed -n 's/^c-\([0-9]*\)-.*\.json$/\1/p' | sort -n | tail -n 1)"
  n=$(( ${n:-0} + 1 )); id="c-$n-$(jq -r '.hash[0:16]' <<<"$3")"
  now="$(team_utc)"; exp="$(jq -rn --arg t "$now" --argjson w "$(jq -r '.wait // 285' <<<"$3")" '($t | fromdateiso8601) + $w | todateiso8601')"
  ( umask 077
    jq -n --arg id "$id" --slurpfile p "$2" --argjson x "$3" --arg now "$now" --arg exp "$exp" '
      {id: $id, payload: $p[0], class_id: $x.class, pins: $x.pins, dest: $x.dest, request_hash: $x.hash,
       binding: $x.binding, list_version: $x.binding.list_version, switch_id: $x.binding.switch_id,
       project: $x.project, ctx: $x.ctx, rules: ($x.rules // ""), launch_rules: ($x.launch_rules // ""),
       host: ($x.host // "claude"), role: ($x.role // ""),
       session_id: ($x.session_id // ""), agent_id: ($x.agent_id // ""), agent_type: ($x.agent_type // ""),
       team: ($x.team // ""), run: ($x.run // ""), ticket: ($x.ticket // ""), created_at: $now, expires_at: $exp}' \
      > "$d/requests/.$id.tmp" && mv "$d/requests/.$id.tmp" "$d/requests/$id.json" ) || { clearance_unlock "$m"; return 1; }
  clearance_unlock "$m"
  echo "$id"
}

# clearance_ring <main> <id> <from> — the Supervisor's inbox doorbell (never the exit).
clearance_ring() {
  local r; r="$(cat "$(clearance_dir "$1")/requests/$2.json" 2>/dev/null)" || return 0
  bash "$CLEARANCE_LIB/team-inbox.sh" --main "$1" write Supervisor clearance --from "$3" \
    --ticket "$(jq -r '.ticket // ""' <<<"$r")" --run "$(jq -r '.run // ""' <<<"$r")" \
    --ref "clearance/requests/$2.json" --message "$2 $(jq -r '"\(.class_id) \(.dest // "")"' <<<"$r")" >/dev/null 2>&1 || true
}

# clearance_evidence <main> <id> <verdict> <since> → 0 when the registered Supervisor session's
# transcript holds its own Bash call `bash .claude/lib/team-clearance.sh answer <id> <verdict>` (or
# the main checkout's absolute path) after <since>, with a tool result that is no error.
clearance_evidence() {
  local t
  clearance_libs || return 1
  t="$(mandate_transcript "$1" 2>/dev/null)" || return 1
  jq -rs --arg since "$4" --arg rel "bash .claude/lib/team-clearance.sh answer $2 $3" \
    --arg abs "bash $1/.claude/lib/team-clearance.sh answer $2 $3" '
    [.[] | select(type == "object")] as $all
    | [$all[] | select(.type == "assistant" and ((.isSidechain // false) | not) and ((.timestamp // "") >= $since))
        | (.message.content // []) | if type == "array" then .[] else empty end
        | select(type == "object" and .type == "tool_use" and .name == "Bash")
        | select((.input.command // "" | tostring | sub("^\\s+"; "") | sub("\\s+$"; "")) as $c | $c == $rel or $c == $abs)
        | .id] as $ids
    | [$all[] | select(.type == "user") | (.message.content // []) | if type == "array" then .[] else empty end
        | select(type == "object" and .type == "tool_result" and (.tool_use_id as $i | $ids | index($i) != null)
            and ((.is_error // false) | not))] | length > 0' "$t" 2>/dev/null | grep -qx true
}

# clearance_rederive <main> <id> <payload file> <request json> → rc 0 when the payload, classified
# now on the current tree with the request's binding, is still that request's clearable class and
# hash and the id is bound to that hash; else rc 1 and the reason on stdout (claim and answer).
clearance_rederive() {
  local id="$2" r="$4" out res
  out="$(clearance_classify "$1" "$3" "$r" "$(jq -c .binding <<<"$r")")"
  res="$(sed -n 's/^result: //p' <<<"$out")"
  [ "$res" = clearable ] \
    || { echo "$id re-derives to $res ($(sed -n 's/^reason: //p' <<<"$out")) — only a clearable class is answered"; return 1; }
  [ "$(sed -n 's/^class: //p' <<<"$out")" = "$(jq -r .class_id <<<"$r")" ] || { echo "$id re-derives to another class"; return 1; }
  [ "$(sed -n 's/^hash: //p' <<<"$out")" = "$(jq -r .request_hash <<<"$r")" ] && [ "${id##*-}" = "$(jq -r '.request_hash[0:16]' <<<"$r")" ] \
    || { echo "$id: the request changed (a pin, the payload or the binding)"; return 1; }
}

# clearance_claim <main> <id> <live payload file> → the answered verdict, once (rc 0); rc 1 for
# anything else. Under the lock: the request and its answer, unused and unexpired, the switch and
# the list still the ones it was asked and answered under, the live payload reclassified on the
# current tree to the same class and hash, the Supervisor's own `answer` call in its transcript;
# then `used/<id>.json` by a link that never overwrites (single use, R2-7).
clearance_claim() {
  local m="$1" id="$2" d r a v now sw
  d="$(clearance_dir "$m")"
  [[ "$id" =~ ^c-[0-9]+-[0-9a-f]{16}$ ]] || return 1
  r="$(cat "$d/requests/$id.json" 2>/dev/null)" && a="$(cat "$d/answers/$id.json" 2>/dev/null)" || return 1
  v="$(jq -r '.verdict // ""' <<<"$a")"
  case "$v" in allow|deny) ;; *) return 1 ;; esac
  now="$(date +%s)"
  [ "$now" -lt "$(team_epoch "$(jq -r .expires_at <<<"$r")")" ] || return 1
  [ "$(jq -r .id <<<"$a")" = "$id" ] && [ "$(jq -r .request_hash <<<"$a")" = "$(jq -r .request_hash <<<"$r")" ] || return 1
  sw="$(clearance_verified "$m" 2>/dev/null)" || return 1
  [ "$(jq -r .id <<<"$sw")" = "$(jq -r .switch_id <<<"$r")" ] && [ "$(jq -r .id <<<"$sw")" = "$(jq -r .switch_id <<<"$a")" ] \
    && [ "$(jq -r .list_version <<<"$sw")" = "$(jq -r .list_version <<<"$r")" ] \
    && [ "$(jq -r .list_version <<<"$sw")" = "$(jq -r .list_version <<<"$a")" ] || return 1
  clearance_rederive "$m" "$id" "$3" "$r" >/dev/null || return 1
  clearance_evidence "$m" "$id" "$v" "$(jq -r .created_at <<<"$r")" || return 1
  clearance_lock "$m" || return 1
  if [ -e "$d/used/$id.json" ] || ! ln "$d/answers/$id.json" "$d/used/$id.json" 2>/dev/null; then
    clearance_unlock "$m"; return 1
  fi
  clearance_unlock "$m"
  echo "$v"
}

# clearance_wait <main> <id> <deadline epoch> <live payload file> → allow | deny (a claimed
# answer, rc 0), unsure (rc 1), none (no claimable answer by the deadline, rc 1). An answer whose
# transcript evidence has not arrived yet keeps the wait going. (Carrier B runs its own loop: its
# precedence re-check sits under the stage's ask lock, before the claim.)
clearance_wait() {
  local d v; d="$(clearance_dir "$1")"
  while :; do
    if [ -f "$d/answers/$2.json" ]; then
      [ "$(jq -r '.verdict // ""' "$d/answers/$2.json" 2>/dev/null)" != unsure ] || { echo unsure; return 1; }
      if v="$(clearance_claim "$1" "$2" "$4")"; then echo "$v"; return 0; fi
    fi
    [ "$(date +%s)" -lt "$3" ] || { echo none; return 1; }
    sleep "${TEAM_CLEARANCE_POLL:-2}"
  done
}

# clearance_what <payload file> → the touch line's `what`: `<tool>: <first line of the command,
# URL or path>`, cut at 160 characters (both carriers).
clearance_what() {
  jq -r '"\(.tool_name // ""): " + ((.tool_input.command // .tool_input.url // .tool_input.file_path
    // .tool_input.notebook_path // "") | tostring | split("\n")[0] | .[0:160])' "$1" 2>/dev/null
}

# clearance_supervisor_live <main> → 0 when a Supervisor session is registered and alive (no
# request is filed for an absent one: the normal path goes on at once).
clearance_supervisor_live() {
  [ -f "$1/.agents/team/registry/Supervisor.json" ] \
    && bash "$CLEARANCE_LIB/session-host.sh" alive Supervisor --main "$1" >/dev/null 2>&1
}

# clearance_entry <main> <result> <class> <host> [<id>] [<authority>] → the touch line's
# `clearance` object: result, class, the current list version and host, plus the id and its
# request hash when one is given, plus the authority (both carriers).
clearance_entry() {
  local lv rh=""; lv="$(clearance_list_version "$1" || echo unknown)"
  [ -z "${5:-}" ] || rh="$(jq -r '.request_hash // ""' "$(clearance_dir "$1")/requests/$5.json" 2>/dev/null)"
  jq -nc --arg r "$2" --arg c "$3" --arg v "${lv:-unknown}" --arg h "$4" --arg id "${5:-}" --arg rh "$rh" --arg a "${6:-}" \
    '{result: $r, class: $c, list_version: $v, host: $h} + (if $id == "" then {} else {id: $id, request_hash: $rh} end)
      + (if $a == "" then {} else {authority: $a} end)'
}

# clearance_log <main> <kind> <who> <what> <answer> <clearance json> — one touch-log line
# (cleared | shadow); never fails.
clearance_log() {
  bash "$CLEARANCE_LIB/touches.sh" clear --kind "$2" --who "$3" --what "$4" --answer "$5" --clearance "$6" \
    --main "$1" >/dev/null 2>&1 || true
}

[ "${BASH_SOURCE[0]}" = "$0" ] || return 0
set -euo pipefail

usage() { sed -n '2,31p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }
die() { echo "error: $2" >&2; exit "$1"; }
[ $# -ge 1 ] || usage
MAIN="$(git rev-parse --show-toplevel 2>/dev/null)" || die 2 "not inside a git checkout"
[ ! -f "$MAIN/.agents/team/team.json" ] || die 1 "team clone — the clearance ledger lives in the main checkout"
clearance_libs || die 4 "team-lib.sh, team-lead-lib.sh, team-evidence.sh or team-mandate.sh missing"
F="$(clearance_file "$MAIN")"; D="$(clearance_dir "$MAIN")"
NEED="the Operator types, as a whole message in the Supervisor window: clearance enforce <host>[,<host>] for <N>h|<N>d (hosts: $CLEARANCE_HOSTS; at most $(( CLEARANCE_MAX_HOURS / 24 )) days)"

cmd="$1"; shift
case "$cmd" in
  grant)
    [ $# -eq 0 ] || usage
    d="$(clearance_derive "$MAIN" 2> "${TMPDIR:-/tmp}/clearance-why.$$")" || {
      why="$(cat "${TMPDIR:-/tmp}/clearance-why.$$" 2>/dev/null)"; rm -f "${TMPDIR:-/tmp}/clearance-why.$$"
      die 7 "no switch written — $why. $NEED"; }
    rm -f "${TMPDIR:-/tmp}/clearance-why.$$"
    lv="$(clearance_list_version "$MAIN")" && [ -n "$lv" ] || die 4 "the list version cannot be computed"
    for h in $(jq -r '.hosts[]' <<<"$d"); do
      first="$(clearance_shadow_first "$MAIN" "$h" "$lv")"
      [ -n "$first" ] || die 1 "no switch written — no shadow line of host $h under list version $lv yet: a real session must log in shadow first"
      [[ "$(jq -r .granted_at <<<"$d")" > "$first" ]] \
        || die 1 "no switch written — the message predates the first shadow line of list version $lv ($first): the Operator types the switch again"
    done
    ( umask 077; mkdir -p "$(dirname "$F")"
      jq --arg lv "$lv" --arg at "$(team_utc)" '{id, words, hosts, granted_at, expires_at, list_version: $lv, recorded_at: $at}' \
        <<<"$d" > "$F.tmp.$$" && mv "$F.tmp.$$" "$F" )
    jq -r '"clearance \(.id): enforce \(.hosts | join(",")) until \(.expires_at) (list \(.list_version))\nwords: \(.words)"' "$F" ;;
  show)
    [ $# -eq 0 ] || usage
    lv="$(clearance_list_version "$MAIN" || echo unknown)"
    if v="$(clearance_verified "$MAIN" 2> "${TMPDIR:-/tmp}/clearance-why.$$")"; then
      jq -r '"clearance: enforcing \(.hosts | join(",")) until \(.expires_at) — switch \(.id), list \(.list_version)\nwords: \(.words)"' <<<"$v"
    else
      echo "clearance: shadow — $(cat "${TMPDIR:-/tmp}/clearance-why.$$" 2>/dev/null | head -n 1) (list $lv)"
    fi
    rm -f "${TMPDIR:-/tmp}/clearance-why.$$" ;;
  pause)
    [ $# -eq 0 ] || usage
    rm -f "$F"
    echo "clearance paused — the local record is removed; grant records the Operator's message again. Only the Operator's typed \"revoke clearance\" cancels it for good." ;;
  pending)
    [ $# -eq 0 ] || usage
    now="$(date +%s)"; any=""
    for f in "$D"/requests/c-*.json; do
      [ -f "$f" ] || continue
      id="$(basename "$f" .json)"
      [ ! -e "$D/answers/$id.json" ] && [ ! -e "$D/used/$id.json" ] || continue
      [ "$now" -lt "$(team_epoch "$(jq -r .expires_at "$f")")" ] || continue
      python3 -I "$(clearance_checker "$MAIN")" render --request "$f" --now "$now" || echo "$id: unreadable request"
      any=1
    done
    [ -n "$any" ] || echo "no open clearance request" ;;
  answer)
    [ $# -eq 2 ] || usage
    id="$1"; verdict="$2"
    case "$verdict" in allow|deny|unsure) ;; *) usage ;; esac
    [[ "$id" =~ ^c-[0-9]+-[0-9a-f]{16}$ ]] || die 2 "$id is not a clearance id (c-<n>-<16 hex>)"
    [ "${TEAM_SESSION_ROLE:-}" = Supervisor ] || die 1 "only the Supervisor answers a clearance request"
    [ "$(cd "$PWD" && pwd -P)" = "$(cd "$MAIN" && pwd -P)" ] || die 1 "answer from the main checkout's root"
    r="$(cat "$D/requests/$id.json" 2>/dev/null)" || die 1 "no request $id"
    [ ! -e "$D/answers/$id.json" ] && [ ! -e "$D/used/$id.json" ] || die 1 "$id is answered already"
    [ "$(date +%s)" -lt "$(team_epoch "$(jq -r .expires_at <<<"$r")")" ] || die 1 "$id has expired"
    sw="$(clearance_verified "$MAIN" 2>&1)" || die 1 "no switch in force — $sw"
    [ "$(jq -r .id <<<"$sw")" = "$(jq -r .switch_id <<<"$r")" ] && [ "$(jq -r .list_version <<<"$sw")" = "$(jq -r .list_version <<<"$r")" ] \
      || die 1 "$id was asked under another switch or list version"
    jq -c .payload <<<"$r" > "$D/.answer-$$.json"
    why="$(clearance_rederive "$MAIN" "$id" "$D/.answer-$$.json" "$r")" && rc=0 || rc=$?; rm -f "$D/.answer-$$.json"
    [ "$rc" = 0 ] || die 1 "$why"
    clearance_lock "$MAIN" || die 4 "clearance lock"
    [ ! -e "$D/answers/$id.json" ] && [ ! -e "$D/used/$id.json" ] || { clearance_unlock "$MAIN"; die 1 "$id is answered already"; }
    ( umask 077
      jq -n --arg id "$id" --arg h "$(jq -r .request_hash <<<"$r")" --arg v "$verdict" --arg lv "$(jq -r .list_version <<<"$sw")" \
        --arg s "$(jq -r .id <<<"$sw")" --arg at "$(team_utc)" \
        --arg sid "$(jq -r '.session_id // ""' "$MAIN/.agents/team/registry/Supervisor.json" 2>/dev/null || true)" \
        '{id: $id, request_hash: $h, verdict: $v, list_version: $lv, switch_id: $s, answered_at: $at, session_id: $sid}' \
        > "$D/answers/.$id.tmp" && ln "$D/answers/.$id.tmp" "$D/answers/$id.json"; rm -f "$D/answers/.$id.tmp" ) \
      || { clearance_unlock "$MAIN"; die 1 "$id is answered already"; }
    clearance_unlock "$MAIN"
    echo "answered $id: $verdict" ;;
  *) usage ;;
esac
