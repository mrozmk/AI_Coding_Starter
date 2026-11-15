#!/usr/bin/env bash
# Role-session support of the supervision layer: role profiles, preflight, freeze, rollback, the
# tier-1 answer to a role session's own prompt. Starting, stopping and listing roles is roles.sh.
# Usage: bash .claude/lib/supervisor-sessions.sh materialize <role> | check | preflight | reviewer
#        bash .claude/lib/supervisor-sessions.sh freeze on <release> | freeze off | freeze status
#        bash .claude/lib/supervisor-sessions.sh answer TeamLead|Advisor --fp <fp> \
#          yes | no "<reason>" | pick <n> | other "<text>"
#        bash .claude/lib/supervisor-sessions.sh rollback   (Operator action)
#   materialize: .agents/team/watch/profiles/<Role>.settings.json from the role's template
#   (teams.sessions.<Role>.settings, a .claude/team/sessions/<name>.settings.json), env role = <Role>.
#   e.g. bash .claude/lib/supervisor-sessions.sh preflight
# Contract and runbook: .agents/reference/supervisor-sessions.md
set -euo pipefail

usage() { sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }
[ $# -ge 1 ] || usage
LIB="$(cd "$(dirname "$0")" && pwd)"
. "$LIB/team-watch-lib.sh"
. "$LIB/roles-lib.sh"
top="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "error: not inside a checkout" >&2; exit 1; }
tw_init "$top" || exit 3
cmd="$1"; shift
[ ! -f "$root/.agents/team/team.json" ] \
  || { echo "error: team clone — run supervisor-sessions.sh from the main checkout" >&2; exit 1; }
cd "$root"
FREEZE="$root/.agents/team/release-freeze"
KIT_SRC="$root/.claude/team/sessions/operator-kit"
VERIFIED_CLI=2.1.318
export ROLES_ROOT="$root"
refuse() { echo "refused: $*" >&2; exit 1; }
lc() { echo "$1" | tr '[:upper:]' '[:lower:]'; }

# The machine half of the channel (kit dir, codex home, mail key) loads once, on demand; a
# checkout without a configured channel still launches, without the kit's hooks.
CHAN=""
chan() {
  [ -z "$CHAN" ] || { [ "$CHAN" = ok ]; return; }
  if team_channel_load "$root" 2>/dev/null; then CHAN=ok; else CHAN=no; return 1; fi
}
kit_hooks_file() {  # → the installed kit's role-hooks.settings.json, or nothing
  chan || return 0
  [ ! -f "$TEAM_CHANNEL_KIT/hooks/role-hooks.settings.json" ] \
    || echo "$TEAM_CHANNEL_KIT/hooks/role-hooks.settings.json"
}

# Union of the role profile and the project + local deny/ask rules: whether `--settings` overrides
# or merges those keys is not documented, and the deny floor must survive both. The profile's
# named-read allow goes along with {{CLONES}} expanded: a `/path` rule in a --settings file anchors
# at that file's directory, so the clones need an absolute `//` path, from the one clone resolver.
# The TeamLead also gets the PR host's update verbs denied for the configured provider. One profile
# per role: the template is teams.sessions.<Role>.settings (a team-watch receiver without one uses its
# own name), and env.TEAM_SESSION_ROLE is the role, never the template's value. The kit
# file gives only `.hooks.Stop`: a PreToolUse or PermissionRequest hook could approve a tool call,
# and an old kit's Notification entry calls a removed hook, so nothing else is ever taken.
materialize() {
  local r="$1" d="$TW_DIR/profiles" loc="$root/.claude/settings.local.json" out kh=null c
  local prov pr='[]' kf t=""
  [[ "$r" =~ ^[A-Z][A-Za-z0-9]{1,23}$ ]] || { echo "error: materialize: '$r' is not a role name" >&2; exit 2; }
  if roles_is_declared "$r"; then t="$(roles_cfg "$r" settings)" || exit 2; fi
  [ -n "$t" ] || ! tw_role_ok "$r" || t="$r"
  [ -n "$t" ] || { echo "error: materialize: $r has no settings profile (teams.sessions.$r.settings)" >&2; exit 2; }
  c="$(team_clone_glob "$root")" || { echo "error: materialize $r needs the teams profile" >&2
    exit 2; }
  prov="$(team_profile_load "$root"; printf '%s' "$TEAM_PR_PROVIDER")"
  if [ "$r" = TeamLead ]; then
    case "$prov" in
      github) pr='["Bash(gh pr merge*)","Bash(gh pr edit*)"]' ;;
      azure-devops) pr='["Bash(az repos pr update*)"]' ;;
    esac
  fi
  kf="$(kit_hooks_file)"
  if [ -n "$kf" ]; then   # the operator kit is optional: without it nothing is merged, silently
    kh="$(jq -ce '.hooks // {} | {Stop} | with_entries(select(.value | arrays))
      | select(length > 0)' "$kf" 2>/dev/null)" || kh=null
  fi
  mkdir -p "$d" && chmod 700 "$d"
  [ -f "$loc" ] || loc=/dev/null
  out="$d/$r.settings.json"
  ( umask 077
    jq -s --arg c "/$c*" --argjson kh "$kh" --argjson pr "$pr" --arg r "$r" '
      (.[2] // {}) as $l | [.[0], .[1], $l] as $all
      | {env: ((.[0].env // {}) + {TEAM_SESSION_ROLE: $r}),
         permissions: {allow: [.[0].permissions.allow // [] | .[] | gsub("\\{\\{CLONES\\}\\}"; $c)],
                       deny: ([$all[] | .permissions.deny // [] | .[]] + $pr | unique),
                       ask: ([$all[] | .permissions.ask // [] | .[]] | unique)}}
      + (if .[0].hooks then {hooks: .[0].hooks} else {} end)
      + (if $kh then {hooks: $kh} else {} end)' \
      "$root/.claude/team/sessions/$t.settings.json" "$root/.claude/settings.json" "$loc" \
      | tw_put "$out" )
  jq -r --arg r "$r" '"profile \($r): \(.permissions.deny | length) deny,"
    + " \(.permissions.ask | length) ask, \(.permissions.allow | length) allow"' "$out"
}

ss_running() { pgrep -f -- "^claude --name $1( |\$)" >/dev/null 2>&1; }
role_running() {  # tmux session, or the Supervisor's `here` window
  team_tmux_alive "$(tw_tmux_name "$1")" || ss_running "$1$TEAM_CHANNEL_SUFFIX"
}

# answer <TeamLead|Advisor> --fp <fp> <action> [text] — the only tier-1 path into a role session's
# own prompt. Bound to the fingerprint of the block the Supervisor read; any refusal types nothing,
# and `yes` passes the same check as a team prompt against the role's materialised profile.
answer() {
  local r="${1:-}" fp="${3:-}" act="${4:-}" text="${5:-}" s cur sub cfp why rc=0
  local pf="$TW_DIR/profiles/${1:-x}.settings.json"
  [[ " $TW_PANE_ROLES " == *" $r "* ]] && [ "${2:-}" = --fp ] && [ -n "$fp" ] || usage
  case "$act" in
    yes) ;;
    no|other) [ -n "$text" ] || usage ;;
    pick) [[ "$text" =~ ^[1-9][0-9]?$ ]] || usage ;;
    *) usage ;;
  esac
  [[ " $TW_PANE_ROLES " != *" ${TEAM_SESSION_ROLE:-} "* ]] \
    || refuse "$TEAM_SESSION_ROLE never answers a role prompt — the Supervisor does"
  s="$(tw_session_name "$r")"
  team_tmux_alive "$r" || refuse "$s is not running"
  cur="$(tw_role_prompt "$r")"
  [ -n "$cur" ] || refuse "no prompt or menu open in $s"
  IFS=$'\t' read -r sub cfp _ <<<"$cur"
  [ "$cfp" = "$fp" ] || refuse "stale: the prompt changed — handle the newer ATTENTION"
  case "$act:$sub" in
    yes:menu|pick:permission|other:permission) refuse "$act does not fit a $sub in $s" ;;
  esac
  if [ "$act" = yes ]; then
    [ -f "$pf" ] || refuse "Operator action: no materialised profile (materialize $r)"
    why="$(team_pane_history "$r" 200 | python3 -I "$LIB/team_prompt_check.py" "$root" \
      --settings "$pf" 2>&1 >/dev/null)" || refuse "Operator action: $why"
  fi
  case "$act" in
    yes) sh_keys "$r" --main "$root" enter ;;
    no) sh_keys "$r" --main "$root" esc; sleep 1
      sh_type "$r" --main "$root" \
        "Rejected by the Supervisor: $text. Do not work around it — ask the Operator in this window." --enter \
        >/dev/null ;;
    pick|other)
      bash "$LIB/team-answer.sh" "$(sh_prefix "$root")" "$(lc "$r")" "$act" "$text" \
        --session "$r" || rc=$?
      [ "$rc" = 0 ] || exit "$rc" ;;
  esac
  echo "answered $r $act (fp $fp)"
}

freeze_line() {
  [ -f "$FREEZE" ] || { echo "freeze: off"; return 0; }
  jq -r '"freeze: on — \(.release // "?") (\(.by // "?"), \(.at // "?"))"' "$FREEZE" 2>/dev/null \
    || echo "freeze: on — unreadable $FREEZE"
}

freeze() {
  case "${1:-}" in
    on) [ -n "${2:-}" ] || usage
      mkdir -p "$(dirname "$FREEZE")"
      jq -n --arg r "$2" --arg by "${TEAM_SESSION_ROLE:-operator}" --arg at "$(team_utc)" \
        '{on: true, release: $r, by: $by, at: $at}' | tw_put "$FREEZE"
      freeze_line ;;
    off) rm -f "$FREEZE"; freeze_line ;;
    status) freeze_line ;;
    *) usage ;;
  esac
}

# reviewer — read-only: is the Reviewer's deliver loop for THIS box running? The pattern comes from
# team-mail.sh (built from the escaped box path), so another project's same-name loop never counts.
reviewer() {
  local pat
  if [ "$TEAM_CHANNEL_ADVISOR" = solo ]; then echo "Reviewer: none (advisor solo)"; return 0; fi
  if ! chan; then
    echo "Reviewer: unknown — team channel not configured (/setup:teams → channel)"; return 0
  fi
  pat="$(bash "$LIB/team-mail.sh" "$TEAM_CHANNEL_KEY" pattern deliver "$TEAM_CHANNEL_REVIEWER" \
    2>/dev/null)" || pat=""
  if [ -n "$pat" ] && pgrep -f -- "$pat" >/dev/null 2>&1; then echo "Reviewer: deliver ok"
  else echo "Reviewer: deliver missing — restore per .agents/reference/agent-mail.md → Bring-up"; fi
}

rollback() {
  bash "$LIB/team-watch.sh" routing single Supervisor
  bash "$LIB/team-watch.sh" mode answering on
  cat <<'EOF'
Rollback: routing single Supervisor, answering on. Operator steps, in this order:
  1. ! bash .claude/team/sessions/operator-kit/install.sh --rollback
  2. start a plain `claude` in the main checkout (no TEAM_SESSION_ROLE)
  3. /monitor in that window — it registers the Supervisor receiver
Ownership is complete only when `team-watch.sh status` shows `receiver Supervisor: … active`;
until then the backlog waits on the Supervisor's cursor.
EOF
}

# ---- preflight: one verdict line per row, `ok|WARN|FAIL <row>[ — <detail>]`; exit 1 on any FAIL ----
PF_RC=0
pf() {  # pf <row> <ok|warn|fail> [detail]
  case "$2" in
    ok) echo "ok $1${3:+ — $3}" ;;
    warn) echo "WARN $1${3:+ — $3}" ;;
    *) echo "FAIL $1${3:+ — $3}"; PF_RC=1 ;;
  esac
}

# Row 1: every receiver live, its socket judged by team-watch-send.py --check (the send's own
# predicate and wording). A socket of a role that is not started yet is a WARN, a refused one a FAIL.
pf_receivers() {
  local r f sock st why bad="" warn=""
  for r in $TW_ROLES; do
    f="$(tw_receiver_file "$r")"
    sock="$(jq -r 'select(.active == true) | .socket // ""' "$f" 2>/dev/null || true)"
    if [ -z "$sock" ]; then
      if role_running "$r"; then bad="$bad; $r not registered"; else warn="$warn; $r not started"; fi
      continue
    fi
    why=""; st=0
    why="$(python3 -I "$LIB/team-watch-send.py" --check "$sock" 2>&1 >/dev/null)" || st=$?
    case "$st" in
      0) tw_live "$r" || bad="$bad; $r not live (pid gone)" ;;
      1) if role_running "$r"; then bad="$bad; $r socket $sock missing"
         else warn="$warn; $r not started (socket missing)"; fi ;;
      *) bad="$bad; ${why#team-watch-send: }" ;;
    esac
  done
  if [ -n "$bad" ]; then pf "receivers live" fail "${bad#; }${warn:+; $warn}"
  elif [ -n "$warn" ]; then pf "receivers live" warn "${warn#; }"
  else pf "receivers live" ok; fi
}

pf_waiters() {  # an escalating / waiting-operator q needs a live team-escalate.sh waiter
  local d q st p bad=""
  for d in $(team_clone_dirs "$root"); do
    for q in "$d"/runs/"$(cat "$d/run" 2>/dev/null)"/questions/q-*.md; do
      case "$q" in *.payload.md|*.reply-*.md) continue ;; esac
      [ -f "$q" ] || continue
      st="$(team_q_state "$q" | cut -f1)"
      case "$st" in escalating|waiting-operator) ;; *) continue ;; esac
      p="$(cat "$q.wait/pid" 2>/dev/null || true)"
      [ -n "$p" ] && kill -0 "$p" 2>/dev/null \
        || bad="$bad $(jq -r .team "$d/team.json")/$(basename "$q" .md)($st)"
    done
  done
  if [ -z "$bad" ]; then pf "escalations have live waiters" ok
  else pf "escalations have live waiters" fail "${bad# }"; fi
}

pf_mail() {  # a mail probe per role in watch.local.json, and a picked ping per role
  local cfg="$root/.agents/team/watch.local.json" r miss="" unpicked="" why=""
  touch "$TW_DIR/events.jsonl" "$TW_DIR/deliveries.jsonl" "$TW_DIR/acks.jsonl"
  for r in $TW_ROLES; do
    [ -n "$(jq -r --arg r "$r" '.mail[$r] // ""' "$cfg" 2>/dev/null)" ] || miss="$miss $r"
    jq -en --arg r "$r" --slurpfile e "$TW_DIR/events.jsonl" \
      --slurpfile d "$TW_DIR/deliveries.jsonl" --slurpfile a "$TW_DIR/acks.jsonl" '
      [$e[] | select(.to == $r and (.text | startswith("PING \($r) "))) | .seq] as $p
      | [$d[] | select(.to == $r and any(.seqs[]; . as $s | $p | index($s))) | .batch] as $b
      | any($a[]; .to == $r and .state == "picked" and (.batch as $x | $b | index($x)))' \
      >/dev/null 2>&1 || unpicked="$unpicked $r"
  done
  [ -z "$miss" ] || why="missing .mail in watch.local.json for$miss"
  [ -z "$unpicked" ] || why="${why:+$why; }run team-watch.sh ping <role> and ack it in:$unpicked"
  if [ -z "$why" ]; then pf "mail probe and picked ping per role" ok
  else pf "mail probe and picked ping per role" fail "$why"; fi
}

pf_channel() {
  local e
  if e="$(team_channel_load "$root" 2>&1)"; then pf "team channel loads" ok
  else pf "team channel loads" fail "$(printf '%s' "$e" | tail -n 1)"; fi
}

pf_kit() {
  local rc=0
  if [ ! -f "$KIT_SRC/install.sh" ]; then pf "operator kit installed" fail "not shipped"; return 0; fi
  bash "$KIT_SRC/install.sh" --verify >/dev/null 2>&1 || rc=$?
  case "$rc" in
    0) pf "operator kit installed" ok ;;
    3) pf "operator kit installed" fail "team channel not configured (install.sh exit 3)" ;;
    *) pf "operator kit installed" fail \
         "install.sh --verify exit $rc (Operator: ! bash .claude/team/sessions/operator-kit/install.sh --apply)" ;;
  esac
}

pf_profiles() {
  local rc=0
  python3 -I "$LIB/session_profile_check.py" "$root" >/dev/null 2>&1 || rc=$?
  case "$rc" in
    0) pf "role profiles" ok ;;
    3) pf "role profiles" fail "local allow leak (Operator: settings.local.json)" ;;
    *) pf "role profiles" fail "supervisor-sessions.sh check (exit $rc)" ;;
  esac
}

pf_notify() {  # notify.sh --check on one row; both channels off is an informed choice, not a block
  local l rc=0
  l="$(bash "$root/.claude/lib/notify.sh" --check 2>&1 | paste -sd ';' - | sed 's/;/ · /g')" || rc=$?
  if [ "$rc" = 0 ] && [ -n "$l" ]; then echo "ok notifications: $l"
  else pf "notifications" fail "notify.sh --check exit $rc: ${l:-no output}"; fi
}

pf_health() {  # the installed copy knows the scheduler label (kit.conf); else the template
  local h="$KIT_SRC/sessions-health.sh" l
  if chan && [ -f "$TEAM_CHANNEL_KIT/sessions-health.sh" ]; then h="$TEAM_CHANNEL_KIT/sessions-health.sh"; fi
  if [ -f "$h" ] && l="$(bash "$h" --scheduled 2>/dev/null)"; then
    echo "ok health check: scheduled (${l#scheduled: })"
  else
    echo "ok health check: none — declared loss: a dead tmux server is noticed by nobody"
  fi
}

pf_cli() {  # the messaging socket is an observed interface, verified per CLI version
  local v cfg row
  # The settings the launched sessions will read: the project's Claude profile, else this process's.
  cfg="$(team_claude_home "$root")" || cfg="${CLAUDE_CONFIG_DIR:-}"
  cfg="${cfg:-$HOME/.claude}/settings.json"
  v="$(claude --version 2>/dev/null | awk 'NR == 1 {print $1}')" || v=""
  if [ "$v" = "$VERIFIED_CLI" ]; then
    row="Claude Code $v — socket wire format verified on $VERIFIED_CLI"
  else
    row="Claude Code ${v:-unknown} — unverified: run team-watch.sh ping <role>"
  fi
  case " ${TEAM_SESSIONS_CLAUDE_FLAGS:-} " in
    *bypassPermissions*)
      if ! jq -e '.crossSessionInbound == "accept"' "$cfg" >/dev/null 2>&1; then
        pf "$row" fail "bypassPermissions sessions drop team-watch messages; Operator action: add \"crossSessionInbound\": \"accept\" to $cfg"
        return 0
      fi ;;
  esac
  echo "ok $row"
}

preflight() {
  PF_RC=0
  pf_receivers
  if tw_loops_ok; then pf "team-watch loops beating" ok
  else pf "team-watch loops beating" fail "beat or dog.beat stale — bash .claude/lib/team-watch.sh start"; fi
  pf_waiters
  pf_mail
  pf_channel
  pf_kit
  pf_profiles
  pf_notify
  pf_health
  pf_cli
  return "$PF_RC"
}

case "$cmd" in
  materialize) materialize "${1:-}" ;;
  reviewer) reviewer ;;
  check) python3 -I "$LIB/session_profile_check.py" "$root" --hooks ;;
  preflight) preflight ;;
  freeze) freeze "$@" ;;
  rollback) rollback ;;
  answer) answer "$@" ;;
  *) usage ;;
esac
