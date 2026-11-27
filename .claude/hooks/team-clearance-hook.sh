#!/usr/bin/env bash
# #323 carrier A: the PermissionRequest hook of every role profile (Advisor, Supervisor, TeamLead;
# Codex through .codex/hooks.json) and the Advisor/Supervisor PreToolUse write guard of the guard
# layer. Registered by the materialised profile with an absolute main-checkout path ({{MAIN}}), the
# seal of the switch record at launch (TEAM_CLEARANCE_SEAL) and the digest of the launch rules
# (TEAM_CLEARANCE_RULES), so a ticket that edits this file cannot change its own run.
#   PreToolUse Edit|Write|MultiEdit|NotebookEdit (fails closed, exit 2): the clearance ledger
#     (.agents/team/clearance*) → deny; settings, role profiles, .claude/hooks/**, .codex/hooks.json,
#     a team ledger or the main checkout's trusted clearance code → ask (the human dialog).
#   PermissionRequest (fails open: any error → no output, the normal dialog): the checker
#     (guard_team_egress_clear.py) sorts the request into pass | hard | clearable | none.
#     shadow (the default; Codex always): one `shadow` touch line, no output, for every result.
#     enforce (the Operator's switch verifies now, names host claude, and equals the seal): pass →
#     allow; hard or none → no output; clearable in the Supervisor's own session → no output, logged
#     `own`; clearable with no live registered Supervisor → no output; otherwise a request in the
#     main checkout and a `clearance` doorbell, then the wait until 15 s before the 300 s timeout:
#     a claimed Supervisor allow → allow, a claimed deny → deny, anything else → no output.
#   Never a rewritten input or a permission update, never an allow on a timeout or in shadow.
# Bash 3.2 + jq. Contract: .agents/reference/security-egress.md → Supervisor clearance (#323).
set -o pipefail
ENTRY=$(date +%s)
HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
MAIN="$(cd "$HOOK_DIR/../.." && pwd)"
PROJECT="${CLAUDE_PROJECT_DIR:-$PWD}"
HOST="${TEAM_CLEARANCE_HOST:-claude}"
SEAL="${TEAM_CLEARANCE_SEAL:-off}"
WAIT="${TEAM_CLEARANCE_WAIT:-285}"; [[ "$WAIT" =~ ^[0-9]+$ ]] || WAIT=285
CHECKER="$MAIN/.claude/hooks/lib/guard_team_egress_clear.py"
PAYLOAD="$(cat)"

# --- the write guard (fail closed) -----------------------------------------------------------
guard_refuse() { echo "team clearance write guard: $1" >&2; exit 2; }
out_pre() { jq -n --arg d "$1" --arg r "$2" '{hookSpecificOutput: {hookEventName: "PreToolUse",
  permissionDecision: $d, permissionDecisionReason: $r}}'; }
if ! command -v jq >/dev/null 2>&1; then
  case "$PAYLOAD" in *'"PreToolUse"'*) guard_refuse "jq missing — refused" ;; esac
  exit 0
fi
EV="$(jq -r '.hook_event_name // ""' <<<"$PAYLOAD" 2>/dev/null)"
TOOL="$(jq -r '.tool_name // ""' <<<"$PAYLOAD" 2>/dev/null)"
if [ "$EV" = PreToolUse ]; then
  case "$TOOL" in Edit|Write|MultiEdit|NotebookEdit)
    FILE="$(jq -r '.tool_input.file_path // .tool_input.notebook_path // ""' <<<"$PAYLOAD" 2>/dev/null)"
    [ -n "$FILE" ] || guard_refuse "no file path in the tool call — refused"
    case "$FILE" in /*) ;; *) FILE="$PROJECT/$FILE" ;; esac
    P="$(python3 -I -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$FILE")" && [ -n "$P" ] \
      || guard_refuse "cannot resolve $FILE — refused"
    case "$(tr '[:upper:]' '[:lower:]' <<<"$P")" in
      */.agents/team/clearance|*/.agents/team/clearance/*|*/.agents/team/clearance.json*)
        out_pre deny "the clearance ledger is written by team-clearance.sh only"; exit 0 ;;
    esac
    why="$(python3 -I "$CHECKER" protected --path "$P" --project "$PROJECT" --main "$MAIN")" \
      || guard_refuse "the guard layer check failed — refused"
    [ -z "$why" ] || out_pre ask "team clearance guard: a write into $why — the Operator decides (#323)"
    exit 0 ;;
  esac
  exit 0
fi

# --- the PermissionRequest flow (fail open) --------------------------------------------------
[ "$EV" = PermissionRequest ] || exit 0
case "$TOOL" in Bash|WebFetch|Edit|Write|MultiEdit|NotebookEdit) ;; *) exit 0 ;; esac
LIB="$MAIN/.claude/lib"
{ . "$LIB/team-lib.sh" && . "$LIB/team-lead-lib.sh" && . "$LIB/team-evidence.sh" && . "$LIB/team-clearance.sh"; } \
  >/dev/null 2>&1 || exit 0
SID="$(jq -r '.session_id // ""' <<<"$PAYLOAD")"
ROLE="${TEAM_SESSION_ROLE:-}"
TL="$PROJECT/.agents/team/teamlead.json"
if [ -z "$ROLE" ] && [ -f "$TL" ] && [ -n "$SID" ] && [ "$(jq -r '.session_id // ""' "$TL" 2>/dev/null)" = "$SID" ]; then
  ROLE=TeamLead
fi
case "$ROLE" in Supervisor) CTX=supervisor ;; TeamLead) CTX=teamlead ;; *) CTX=advisor ;; esac
TEAM=""; RUN=""; TICKET=""; RULES=""; LAUNCH=""
if [ "$HOST" = claude ]; then
  if [ "$ROLE" = TeamLead ]; then
    RULES="$PROJECT/.agents/team/teamlead.settings.json"
    TEAM="$(jq -r '.team // ""' "$PROJECT/.agents/team/team.json" 2>/dev/null)"
    TICKET="$(jq -r '.ticket // ""' "$PROJECT/.agents/team/team.json" 2>/dev/null)"
    RUN="$(jq -r '.run // ""' "$TL" 2>/dev/null)"
  else
    RULES="$MAIN/.agents/team/watch/profiles/${ROLE:-none}.settings.json"
  fi
  LAUNCH="${TEAM_CLEARANCE_RULES:-missing}"
fi
TMPF="$(mktemp "${TMPDIR:-/tmp}/clearance-hook.XXXXXX")" || exit 0
trap 'rm -f "$TMPF"' EXIT
c="$(jq -r '.cwd // ""' <<<"$PAYLOAD")"; c="$( (cd "$c" 2>/dev/null && pwd -P) || printf '%s' "${c:-$PROJECT}")"
jq -c --arg c "$c" '{tool_name, tool_input, cwd: $c}' <<<"$PAYLOAD" > "$TMPF" 2>/dev/null || exit 0
WHO="$(jq -nc --arg ctx "$CTX" --arg p "$PROJECT" --arg r "$RULES" --arg lr "$LAUNCH" --arg role "$ROLE" --arg s "$SID" \
  --arg t "$TEAM" --arg run "$RUN" --arg k "$TICKET" --arg h "$HOST" --argjson w "$WAIT" \
  --arg aid "$(jq -r '.agent_id // ""' <<<"$PAYLOAD")" --arg aty "$(jq -r '.agent_type // ""' <<<"$PAYLOAD")" \
  '{ctx: $ctx, project: $p, rules: $r, launch_rules: $lr, role: $role, session_id: $s, team: $t, run: $run,
    attempt: "", ticket: $k, host: $h, wait: $w, agent_id: $aid, agent_type: $aty}')" || exit 0
out="$(clearance_classify "$MAIN" "$TMPF" "$WHO")" || exit 0
res="$(sed -n 's/^result: //p' <<<"$out")"; cls="$(sed -n 's/^class: //p' <<<"$out")"
[ -n "$res" ] || exit 0
MODE="$(clearance_mode "$HOST" "$SEAL" "$MAIN")"
WHAT="$(clearance_what "$TMPF")"
logline() {  # logline <kind> <result> [<id>] [<answer>]
  clearance_log "$MAIN" "$1" "${ROLE:-session} $SID" "$WHAT" "${4:-}" \
    "$(clearance_entry "$MAIN" "$2" "$cls" "$HOST" "${3:-}" "$([ "$1" = cleared ] && echo "supervisor (cleared)")")"
}
shadow_of() { case "$res" in pass) echo would-pass ;; clearable) [ "$CTX" = supervisor ] && echo own || echo would-clear ;; *) echo "$res" ;; esac; }
if [ "$MODE" != enforce ]; then
  logline shadow "$(shadow_of)"
  exit 0
fi
case "$res" in
  pass) jq -n '{hookSpecificOutput: {hookEventName: "PermissionRequest", decision: {behavior: "allow"}}}'; exit 0 ;;
  clearable) ;;
  *) exit 0 ;;
esac
if [ "$CTX" = supervisor ]; then logline shadow own; exit 0; fi
clearance_supervisor_live "$MAIN" || exit 0
id="$(clearance_open "$MAIN" "$TMPF" "$WHO")" && [ -n "$id" ] || exit 0
clearance_ring "$MAIN" "$id" "$([ -n "$TEAM" ] && echo "$TEAM" || echo "${ROLE:-adhoc-session}")"
v="$(clearance_wait "$MAIN" "$id" $(( ENTRY + WAIT )) "$TMPF")"
case "$v" in
  allow)
    logline cleared clearable "$id" allow
    jq -n '{hookSpecificOutput: {hookEventName: "PermissionRequest", decision: {behavior: "allow"}}}' ;;
  deny)
    logline cleared clearable "$id" deny
    jq -n --arg m "the Supervisor denied this request ($id)" '{hookSpecificOutput: {hookEventName: "PermissionRequest",
      decision: {behavior: "deny", message: $m}}}' ;;
esac
exit 0
