#!/usr/bin/env bash
# Role sessions of the supervision layer: launcher, status, profiles, preflight, freeze, rollback,
# tier-1 answers to a role session's own prompt, the after-restart launcher `up`.
# Usage: bash .claude/lib/supervisor-sessions.sh start <role>|all | stop <role> | status | up
#        bash .claude/lib/supervisor-sessions.sh materialize <role> | check | preflight | reviewer
#        bash .claude/lib/supervisor-sessions.sh freeze on <release> | freeze off | freeze status
#        bash .claude/lib/supervisor-sessions.sh answer TeamLead|Advisor --fp <fp> \
#          yes | no "<reason>" | pick <n> | other "<text>"
#        bash .claude/lib/supervisor-sessions.sh rollback | here Supervisor   (Operator actions)
#   roles: Supervisor TeamLead Advisor · tmux: <tmux_prefix>-supervisor|-teamlead|-advisor
#   model/effort: teams.sessions.<Role>.{model,effort}, else opus · medium (Supervisor) / high;
#   TEAM_SESSIONS_CLAUDE_FLAGS adds claude flags to every launch.
#   e.g. bash .claude/lib/supervisor-sessions.sh start all   (then: tmux attach -t <prefix>-teamlead)
# Contract and runbook: .agents/reference/supervisor-sessions.md
set -euo pipefail

usage() { sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }
[ $# -ge 1 ] || usage
LIB="$(cd "$(dirname "$0")" && pwd)"
. "$LIB/team-watch-lib.sh"
top="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "error: not inside a checkout" >&2; exit 1; }
tw_init "$top" || exit 3
cmd="$1"; shift
[ ! -f "$root/.agents/team/team.json" ] \
  || { echo "error: team clone — run supervisor-sessions.sh from the main checkout" >&2; exit 1; }
cd "$root"
FREEZE="$root/.agents/team/release-freeze"
KIT_SRC="$root/.claude/team/sessions/operator-kit"
VERIFIED_CLI=2.1.318
# A tmux server started from a Claude session would give every later session CLAUDECODE=1.
CLEAN="env -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT -u CLAUDE_CODE_MESSAGING_SOCKET"
CLEAN="$CLEAN -u CLAUDE_CODE_MESSAGING_TOKEN"
# The launch prompt: the SessionStart directive only adds context and starts no turn.
boot() { printf '%q' "/session-role $1"; }
refuse() { echo "refused: $*" >&2; exit 1; }
lc() { echo "$1" | tr '[:upper:]' '[:lower:]'; }

need_tw_role() {  # the team-watch receivers: profiles, here
  tw_role_ok "${1:-}" || { echo "error: role must be one of: $TW_ROLES" >&2; exit 2; }
}
need_role() {
  tw_session_role_ok "${1:-}" \
    || { echo "error: role must be one of: $TW_SESSION_ROLES" >&2; exit 2; }
}
roles_of() {
  if [ "${1:-}" = all ]; then echo "$TW_SESSION_ROLES"; else need_role "${1:-}"; echo "$1"; fi
}

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

MODEL_RE='^[A-Za-z0-9][A-Za-z0-9._:-]{0,63}(\[[0-9a-z]+\])?$'
sess_cfg() {  # sess_cfg <role> model|effort → teams.sessions value or the code default
  local v d
  case "$2" in model) d=opus ;; *) d=high; [ "$1" != Supervisor ] || d=medium ;; esac
  v="$(jq -r --arg r "$1" --arg f "$2" '.teams.sessions[$r][$f] // empty | strings' \
    "$root/.claude/project-profile.json" 2>/dev/null || true)"
  v="${v:-$d}"
  case "$2" in
    model) [[ "$v" =~ $MODEL_RE ]] \
      || { echo "error: teams.sessions.$1.model=$v is not a model name" >&2; return 2; } ;;
    effort) case "$v" in low|medium|high|xhigh|max) ;;
      *) echo "error: teams.sessions.$1.effort=$v must be low|medium|high|xhigh|max" >&2
         return 2 ;; esac ;;
  esac
  echo "$v"
}

new_sid() {
  local s
  s="$(uuidgen 2>/dev/null | tr '[:upper:]' '[:lower:]')" || s=""
  [ -n "$s" ] || s="$(python3 -I -c 'import uuid; print(uuid.uuid4())')"
  echo "$s"
}
# session.json of a role session — team-answer.sh --session binds its keys to this transcript; the
# session-role hook rewrites session_id after /clear or resume.
write_session() {  # write_session <role> <session id>
  local d="$TW_DIR/sessions/$1"
  mkdir -p "$d"
  jq -n --arg r "$1" --arg s "$2" --arg at "$(team_utc)" \
    '{team: "-", role: $r, run: "-", attempt: 1, session_id: $s, launched_at: $at}' \
    | tw_put "$d/session.json"
}

# Union of the role profile and the project + local deny/ask rules: whether `--settings` overrides
# or merges those keys is not documented, and the deny floor must survive both. The profile's
# named-read allow goes along with {{CLONES}} expanded: a `/path` rule in a --settings file anchors
# at that file's directory, so the clones need an absolute `//` path, from the one clone resolver.
# The TeamLead also gets the PR host's update verbs denied for the configured provider. The kit
# file gives only `.hooks.Notification` and `.hooks.Stop`: a PreToolUse or PermissionRequest hook
# could approve a tool call, so no other event — and none of its permissions — is ever taken.
materialize() {
  local r="$1" d="$TW_DIR/profiles" loc="$root/.claude/settings.local.json" out kh=null c
  local prov pr='[]' kf
  need_tw_role "$r"
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
  if [ -n "$kf" ]; then
    kh="$(jq -ce '.hooks // {} | {Notification, Stop} | with_entries(select(.value | arrays))
      | select(length > 0)' "$kf" 2>/dev/null)" || kh=null
  else
    echo "warning: operator kit role-hooks.settings.json not installed —" \
      "$r without platform notifications" >&2
  fi
  mkdir -p "$d" && chmod 700 "$d"
  [ -f "$loc" ] || loc=/dev/null
  out="$d/$r.settings.json"
  ( umask 077
    jq -s --arg c "/$c*" --argjson kh "$kh" --argjson pr "$pr" '
      (.[2] // {}) as $l | [.[0], .[1], $l] as $all
      | {env: .[0].env,
         permissions: {allow: [.[0].permissions.allow // [] | .[] | gsub("\\{\\{CLONES\\}\\}"; $c)],
                       deny: ([$all[] | .permissions.deny // [] | .[]] + $pr | unique),
                       ask: ([$all[] | .permissions.ask // [] | .[]] | unique)}}
      + (if .[0].hooks then {hooks: .[0].hooks} else {} end)
      + (if $kh then {hooks: $kh} else {} end)' \
      "$root/.claude/team/sessions/$r.settings.json" "$root/.claude/settings.json" "$loc" \
      | tw_put "$out" )
  jq -r --arg r "$r" '"profile \($r): \(.permissions.deny | length) deny,"
    + " \(.permissions.ask | length) ask, \(.permissions.allow | length) allow"' "$out"
}

# check_roles <role...> — the profile check of freshly materialised profiles; a leak or a failure
# launches nothing.
check_roles() {
  local out rc=0
  [ $# -gt 0 ] || return 0
  out="$(python3 -I "$LIB/session_profile_check.py" "$root" "$@" 2>&1)" || rc=$?
  case "$rc" in
    0) return 0 ;;
    3) printf '%s\n' "$out" | grep ' LEAK: ' >&2
       echo "refused: local allow leak in settings.local.json — nothing launched" >&2; exit 3 ;;
    *) printf '%s\n' "$out" | grep -v ' note: ' >&2
       echo "refused: role profile check failed (exit $rc) — nothing launched" >&2; exit 1 ;;
  esac
}

ss_running() { pgrep -f -- "^claude --name $1( |\$)" >/dev/null 2>&1; }
role_running() {  # tmux session, or the Supervisor's `here` window
  team_tmux_alive "$(tw_tmux_name "$1")" || ss_running "$1$TEAM_CHANNEL_SUFFIX"
}

launch() {  # launch <role> — tmux session with the role env and a fresh session id
  local r="$1" s m e set="" flags="${TEAM_SESSIONS_CLAUDE_FLAGS:-}" sid name kf ch c
  s="$(tw_tmux_name "$r")"
  m="$(sess_cfg "$r" model)" || exit 2
  e="$(sess_cfg "$r" effort)" || exit 2
  if [ "$r" = Advisor ]; then
    # The Advisor has no repo profile: agent-mail is its channel, the kit's hooks its settings.
    kf="$(kit_hooks_file)"
    if [ -n "$kf" ]; then set=" --settings $(printf '%q' "$kf")"
    else echo "warning: Advisor without platform notifications (operator kit not installed)" >&2; fi
  else
    set=" --settings .agents/team/watch/profiles/$r.settings.json"
  fi
  ch=""; ! chan || ch="$TEAM_CHANNEL_CODEX_HOME"
  ch="${ch:-${CODEX_HOME:-}}"
  sid="$(new_sid)"; write_session "$r" "$sid"
  name="$r$TEAM_CHANNEL_SUFFIX"
  c="$CLEAN claude --name $name --session-id $sid --model $m --effort $e$set $flags $(boot "$r"); read"
  # Per-session -e only: `tmux set-environment -g` would leak into every session.
  $CLEAN tmux new-session -d -s "$s" -c "$root" -e "TEAM_SESSION_ROLE=$r" \
    ${ch:+-e "CODEX_HOME=$ch"} ${CLAUDE_CONFIG_DIR:+-e "CLAUDE_CONFIG_DIR=$CLAUDE_CONFIG_DIR"} "$c"
  echo "$s: started ($name, $m, effort $e)"
}

start() {
  local role s todo="" prof=""
  for role in $(roles_of "${1:-}"); do
    team_tmux_alive "$(tw_tmux_name "$role")" && continue
    todo="$todo $role"
    [ "$role" = Advisor ] || { materialize "$role"; prof="$prof $role"; }
  done
  # shellcheck disable=SC2086
  check_roles $prof
  for role in $(roles_of "${1:-}"); do
    s="$(tw_tmux_name "$role")"
    case " $todo " in *" $role "*) launch "$role" ;; *) echo "$s: already running" ;; esac
    echo "  tmux attach -t $s"
  done
}

# here Supervisor — the Operator's own terminal instead of tmux: identity and the SessionStart
# hooks (register, ack, /clear bootstrap) come from this env, as tmux -e gives the other windows.
here() {
  local p=".agents/team/watch/profiles/Supervisor.settings.json" m e sid
  local flags="${TEAM_SESSIONS_CLAUDE_FLAGS:-}" name="Supervisor$TEAM_CHANNEL_SUFFIX"
  [ "${1:-}" = Supervisor ] || usage
  ! team_tmux_alive "$(tw_tmux_name Supervisor)" \
    || refuse "$(tw_tmux_name Supervisor) runs in tmux — stop Supervisor first"
  ! ss_running "$name" || refuse "a claude --name $name already runs"
  m="$(sess_cfg Supervisor model)" || exit 2
  e="$(sess_cfg Supervisor effort)" || exit 2
  materialize Supervisor
  check_roles Supervisor
  sid="$(new_sid)"; write_session Supervisor "$sid"
  # shellcheck disable=SC2086
  exec $CLEAN TEAM_SESSION_ROLE=Supervisor \
    claude --name "$name" --session-id "$sid" --model "$m" --effort "$e" --settings "$p" $flags
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
  s="$(tw_tmux_name "$r")"
  team_tmux_alive "$s" || refuse "$s is not running"
  cur="$(tw_role_prompt "$r")"
  [ -n "$cur" ] || refuse "no prompt or menu open in $s"
  IFS=$'\t' read -r sub cfp _ <<<"$cur"
  [ "$cfp" = "$fp" ] || refuse "stale: the prompt changed — handle the newer ATTENTION"
  case "$act:$sub" in
    yes:menu|pick:permission|other:permission) refuse "$act does not fit a $sub in $s" ;;
  esac
  if [ "$act" = yes ]; then
    [ -f "$pf" ] || refuse "Operator action: no materialised profile (materialize $r)"
    why="$(team_pane_history "$s" 200 | python3 -I "$LIB/team_prompt_check.py" "$root" \
      --settings "$pf" 2>&1 >/dev/null)" || refuse "Operator action: $why"
  fi
  case "$act" in
    yes) tmux send-keys -t "=$s:" Enter ;;
    no) tmux send-keys -t "=$s:" Escape; sleep 1
      tmux send-keys -t "=$s:" -l -- \
        "Rejected by the Supervisor: $text. Do not work around it — ask the Operator in this window."
      tmux send-keys -t "=$s:" Enter ;;
    pick|other)
      bash "$LIB/team-answer.sh" "$TEAM_CHANNEL_TMUX_PREFIX" "$(lc "$r")" "$act" "$text" \
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

status() {
  local r s l
  for r in $TW_SESSION_ROLES; do
    s="$(tw_tmux_name "$r")"
    echo "$r: tmux $s $(team_tmux_alive "$s" && echo alive || echo down)"
    if [ "$r" = Advisor ]; then
      echo "  receiver: n/a (agent-mail)"
      echo "  $(reviewer)"
      continue
    fi
    l="$(tw_receiver_line "$r")" || l="receiver $r: none registered"
    echo "  $l"
  done
  echo "team-watch: $(tw_loops_ok && echo works || echo "not working")"
  echo "routing: $(tw_routing)"
  echo "tiers: $(tw_tiers)"
  echo "answering: $(tw_answering)"
  freeze_line
  echo "teams: $(for d in $(team_clone_dirs "$root"); do jq -r .team "$d/team.json"; done \
    | tr '\n' ' ')"
}

rollback() {
  bash "$LIB/team-watch.sh" routing single Supervisor
  bash "$LIB/team-watch.sh" mode answering on
  cat <<'EOF'
Rollback: routing single Supervisor, answering on. Operator steps, in this order:
  1. ! bash .claude/team/sessions/operator-kit/install.sh --rollback
  2. start a plain `claude` in the main checkout (no TEAM_SESSION_ROLE), then /mail-role Supervisor
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

pf_notifier() {  # the notifier's own --check line; `none` is an informed choice, not a block
  local l
  l="$(bash "$KIT_SRC/notify.sh" --check --backend "$TEAM_CHANNEL_NOTIFIER" 2>/dev/null)" \
    || l=""
  case "$l" in
    "notifier: none"*|"notifier: $TEAM_CHANNEL_NOTIFIER ok"*) echo "ok $l" ;;
    "") pf "notifier: $TEAM_CHANNEL_NOTIFIER" fail "operator-kit/notify.sh --check printed nothing" ;;
    *) echo "FAIL $l"; PF_RC=1 ;;
  esac
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
  local v cfg="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json" row
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
  pf_notifier
  pf_health
  pf_cli
  return "$PF_RC"
}

# ---- up: after a machine restart — fresh sessions only, never a resume ----
up_loops() {
  if $CLEAN bash "$LIB/team-watch.sh" start --no-register >/dev/null 2>&1; then
    echo "team-watch: works"
  else
    echo "team-watch: not working — bash .claude/lib/team-watch.sh start"
  fi
}

# up_role <role> — a tmux session without its claude is the `; read` pane of a dead session.
up_role() {
  local r="$1" s
  s="$(tw_tmux_name "$r")"
  if team_tmux_alive "$s"; then
    if ss_running "$r$TEAM_CHANNEL_SUFFIX"; then echo "$r: already running"; return 0; fi
    tmux kill-session -t "=$s"
    start "$r" >/dev/null; echo "$r: restarted (dead pane)"
  elif [ "$r" = Supervisor ] && ss_running "$r$TEAM_CHANNEL_SUFFIX"; then
    echo "$r: running (here)"
  else
    start "$r" >/dev/null; echo "$r: started"
  fi
}

up_runs() {  # interrupted team runs are only listed: resuming one is the Operator's /start-team
  local t="$TW_DIR/up-snap.$$.json" out
  mkdir -p "$TW_DIR/cache"
  if ! TEAM_DASH_CACHE="$TW_DIR/cache" bash "$LIB/team-snapshot.sh" --out "$t" >/dev/null 2>&1; then
    rm -f "$t"; echo "interrupted runs: unknown (team-snapshot.sh failed)"; return 0
  fi
  out="$(jq -r '.teams[]? | select(.run != null and .runner != "up" and .finished != true)
    | "interrupted run \(.team) (\(.run)) — resume: /start-team \(.team)"' "$t" 2>/dev/null)" \
    || out=""
  rm -f "$t"
  if [ -n "$out" ]; then echo "$out"; else echo "interrupted runs: none"; fi
}

up() {
  local r
  up_loops
  for r in $TW_SESSION_ROLES; do up_role "$r"; done
  reviewer
  up_runs
  # The launcher is the authorised all-role path from any session.
  env -u TEAM_SESSION_ROLE bash "$LIB/monitoring.sh" start all \
    || echo "monitoring: start all failed — /monitoring start all in the Supervisor"
  for r in $TW_SESSION_ROLES; do
    if team_tmux_alive "$(tw_tmux_name "$r")"; then echo "  tmux attach -t $(tw_tmux_name "$r")"; fi
  done
  echo "Close this bootstrap session if it is not a role session."
}

case "$cmd" in
  materialize) materialize "${1:-}" ;;
  up) up ;;
  reviewer) reviewer ;;
  start) start "${1:-}" ;;
  stop)
    need_role "${1:-}"
    s="$(tw_tmux_name "$1")"
    if team_tmux_alive "$s"; then tmux kill-session -t "=$s"; echo "$s: stopped"
    else echo "$s: not running"; fi ;;
  status) status ;;
  check) python3 -I "$LIB/session_profile_check.py" "$root" --hooks ;;
  preflight) preflight ;;
  freeze) freeze "$@" ;;
  rollback) rollback ;;
  answer) answer "$@" ;;
  here) here "${1:-}" ;;
  *) usage ;;
esac
