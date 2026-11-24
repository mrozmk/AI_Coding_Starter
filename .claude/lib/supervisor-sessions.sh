#!/usr/bin/env bash
# Role-session support of the supervision layer: role profiles, preflight, freeze, rollback.
# Starting, stopping and listing roles is roles.sh.
# Usage: bash .claude/lib/supervisor-sessions.sh materialize <role> | check | preflight | reviewer
#        bash .claude/lib/supervisor-sessions.sh freeze on <release> | freeze off | freeze status
#        bash .claude/lib/supervisor-sessions.sh rollback   (Operator action)
#   materialize: .agents/team/watch/profiles/<Role>.settings.json from the role's template
#   (teams.sessions.<Role>.settings, a .claude/team/sessions/<name>.settings.json), env role = <Role>.
#   e.g. bash .claude/lib/supervisor-sessions.sh preflight
# Contract and runbook: .agents/reference/supervisor-sessions.md
set -euo pipefail

usage() { sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }
[ $# -ge 1 ] || usage
LIB="$(cd "$(dirname "$0")" && pwd)"
. "$LIB/team-lib.sh"
. "$LIB/team-channel.sh"
. "$LIB/roles-lib.sh"
root="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "error: not inside a checkout" >&2; exit 1; }
team_channel_names "$root" \
  || { echo "error: supervisor-sessions.sh needs a valid teams.channel block" >&2; exit 3; }
PROFILES="$root/.agents/team/watch/profiles"
cmd="$1"; shift
[ ! -f "$root/.agents/team/team.json" ] \
  || { echo "error: team clone — run supervisor-sessions.sh from the main checkout" >&2; exit 1; }
cd "$root"
FREEZE="$root/.agents/team/release-freeze"
KIT_SRC="$root/.claude/team/sessions/operator-kit"
VERIFIED_CLI=2.1.318
export ROLES_ROOT="$root"
refuse() { echo "refused: $*" >&2; exit 1; }
# tmp + mv in the target dir: a reader never sees a half-written file.
ss_put() { cat > "$1.tmp.$$" && mv "$1.tmp.$$" "$1"; }

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
# One profile per role: the template is teams.sessions.<Role>.settings (an undeclared Supervisor uses its
# own name), and env.TEAM_SESSION_ROLE is the role, never the template's value. The kit
# file gives only `.hooks.Stop`: a PreToolUse or PermissionRequest hook could approve a tool call,
# and an old kit's Notification entry calls a removed hook, so nothing else is ever taken.
materialize() {
  local r="$1" d="$PROFILES" loc="$root/.claude/settings.local.json" out kh=null c
  local kf t=""
  [[ "$r" =~ ^[A-Z][A-Za-z0-9]{1,23}$ ]] || { echo "error: materialize: '$r' is not a role name" >&2; exit 2; }
  # A teams.sessions.TeamLead declaration would still resolve a template below.
  [ "$r" != TeamLead ] || { echo "error: materialize: the global TeamLead is retired — the per-run" \
    "lead's profile is team-lead.sh materialize" >&2; exit 2; }
  if roles_is_declared "$r"; then t="$(roles_cfg "$r" settings)" || exit 2; fi
  [ -n "$t" ] || [ "$r" != Supervisor ] || t="$r"
  [ -n "$t" ] || { echo "error: materialize: $r has no settings profile (teams.sessions.$r.settings)" >&2; exit 2; }
  c="$(team_clone_glob "$root")" || { echo "error: materialize $r needs the teams profile" >&2
    exit 2; }
  kf="$(kit_hooks_file)"
  if [ -n "$kf" ]; then   # the operator kit is optional: without it nothing is merged, silently
    kh="$(jq -ce '.hooks // {} | {Stop} | with_entries(select(.value | arrays))
      | select(length > 0)' "$kf" 2>/dev/null)" || kh=null
  fi
  mkdir -p "$d" && chmod 700 "$d"
  [ -f "$loc" ] || loc=/dev/null
  out="$d/$r.settings.json"
  ( umask 077
    jq -s --arg c "/$c*" --argjson kh "$kh" --arg r "$r" '
      (.[2] // {}) as $l | [.[0], .[1], $l] as $all
      | {env: ((.[0].env // {}) + {TEAM_SESSION_ROLE: $r}),
         permissions: {allow: [.[0].permissions.allow // [] | .[] | gsub("\\{\\{CLONES\\}\\}"; $c)],
                       deny: ([$all[] | .permissions.deny // [] | .[]] | unique),
                       ask: ([$all[] | .permissions.ask // [] | .[]] | unique)}}
      + (if .[0].hooks then {hooks: .[0].hooks} else {} end)
      + (if $kh then {hooks: $kh} else {} end)' \
      "$root/.claude/team/sessions/$t.settings.json" "$root/.claude/settings.json" "$loc" \
      | ss_put "$out" )
  jq -r --arg r "$r" '"profile \($r): \(.permissions.deny | length) deny,"
    + " \(.permissions.ask | length) ask, \(.permissions.allow | length) allow"' "$out"
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
        '{on: true, release: $r, by: $by, at: $at}' | ss_put "$FREEZE"
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
  cat <<'EOF'
Rollback: Operator steps, in this order:
  1. ! bash .claude/team/sessions/operator-kit/install.sh --rollback
  2. start a plain `claude` in the main checkout (no TEAM_SESSION_ROLE)
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
    row="Claude Code ${v:-unknown} — unverified: check the doorbell (session-host.sh send) by hand"
  fi
  case " ${TEAM_SESSIONS_CLAUDE_FLAGS:-} " in
    *bypassPermissions*)
      if ! jq -e '.crossSessionInbound == "accept"' "$cfg" >/dev/null 2>&1; then
        pf "$row" fail "bypassPermissions sessions drop doorbell messages; Operator action: add \"crossSessionInbound\": \"accept\" to $cfg"
        return 0
      fi ;;
  esac
  echo "ok $row"
}

preflight() {
  PF_RC=0
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
  *) usage ;;
esac
