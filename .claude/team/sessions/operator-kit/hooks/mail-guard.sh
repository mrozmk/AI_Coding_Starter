#!/usr/bin/env bash
# Stop hook of the supervision roles (the operator kit's): refuses to end a turn while this role
# has unread agent-mail turns or unacked team-watch batches. The role is the launcher's
# TEAM_SESSION_ROLE, never a transcript title; only Supervisor and TeamLead are held (the Advisor's
# wake loop covers its mail; a role-less window is silent — the UNPICKED alarm covers it).
# A paused role (/monitoring stop) is held only to its pause.pass.mail_threads; a paused
# Supervisor also to the batches delivered since its pause. The TeamLead is also held while team
# runners are alive and team-watch is unhealthy.
# Every address comes from the channel config (team_channel_load). Fails open: no jq, no channel,
# a failing helper → nothing to hold. Prints {"decision":"block",…} only on the block path; always
# exits 0.
set -u
in="$(cat)"
command -v jq >/dev/null 2>&1 || exit 0
R="${CLAUDE_PROJECT_DIR:-$PWD}"
[ ! -f "$R/.agents/team/team.json" ] || exit 0
role="${TEAM_SESSION_ROLE:-}"
case "$role" in Supervisor|TeamLead) ;; *) exit 0 ;; esac
[ -f "$R/.claude/lib/team-channel.sh" ] || exit 0
. "$R/.claude/lib/team-channel.sh"
team_channel_load "$R" >/dev/null 2>&1 || exit 0
name="$(team_channel_role "$role")" || exit 0
W="$R/.claude/lib/team-watch.sh"
problems=()

# The team-watch daemon's subcommands exist only once that layer is installed; an older
# team-watch.sh takes any word as a team name and polls forever. So a subcommand runs only when
# the script's usage names it, and always under a time bound.
bounded() { perl -e 'alarm shift; exec @ARGV' 10 "$@"; }
tw() {  # tw <sub> [args…]
  grep -qE "team-watch\.sh .*\b$1\b" "$W" 2>/dev/null || return 1
  (cd "$R" && bounded bash "$W" "$@")
}

live_teams() {  # names of teams whose runner lock holds a live pid
  local d pid out=""
  for d in $( (cd "$R" && . .claude/lib/team-lib.sh && team_clone_dirs "$R") 2>/dev/null); do
    pid="$(grep -oE '[0-9]+' -m1 "$d/lock/pid" 2>/dev/null | head -n 1)"
    [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null || continue
    out="$out $(jq -r '.team // empty' "$d/team.json" 2>/dev/null)"
  done
  echo "${out# }"
}

watch_unhealthy() {
  local live
  live="$(live_teams)"
  [ -n "$live" ] && grep -qE 'team-watch\.sh .*\bstatus\b' "$W" 2>/dev/null \
    && ! tw status >/dev/null 2>&1 \
    && problems+=("Team runner(s) alive ($live) but team-watch is not healthy — run /team-watch.")
}

paused_pass() {  # the lines of an unread list a paused role must still handle
  local t lines
  lines="$(cat)"
  for t in $(jq -r --arg r "$role" '.roles[$r].pause.pass.mail_threads // [] | .[]' \
    "$R/.claude/team/sessions/monitoring.json" 2>/dev/null); do
    printf '%s\n' "$lines" | grep -F " thread=$t" || true
  done
}

unread="$(cd "$R" && bounded bash .claude/lib/team-mail.sh "$TEAM_CHANNEL_KEY" inbox --for "$name" --unread --limit 0 2>/dev/null \
  | grep '^\[agent-mail\]' | grep ' kind=turn ' | grep -v ' thread=esc-' || true)"
if [ -f "$R/.claude/lib/monitoring.sh" ] \
  && paused="$(cd "$R" && bounded bash .claude/lib/monitoring.sh paused "$role" 2>/dev/null)"; then
  unread="$(printf '%s\n' "$unread" | paused_pass)"
  [ -z "$unread" ] || problems+=("Unread pass-through turn for paused $name — handle and ack it:"$'\n'"$unread")
  if [ "$role" = Supervisor ]; then
    since="${paused%% *}"
    # A pause from an unreadable state file has no since: hold to every unacked batch.
    [[ "$since" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$ ]] || since=""
    pending="$(tw pending "$role" $since 2>/dev/null || true)"
    [ -z "$pending" ] || problems+=("Unacked team-watch message(s) for paused $role: $(echo $pending) — ack, handle, done.")
  fi
else
  [ -z "$unread" ] || problems+=("Unread agent-mail turn for $name — read, handle and ack it:"$'\n'"$unread")
  pending="$(tw pending "$role" 2>/dev/null || true)"
  [ -z "$pending" ] || problems+=("Unacked team-watch message(s) for $role: $(echo $pending) — run team-watch.sh ack <n>, handle, then done <n>.")
  [ "$role" != TeamLead ] || watch_unhealthy
fi
[ ${#problems[@]} -eq 0 ] && exit 0
jq -n --arg r "$(printf '%s\n' "${problems[@]}")" '{decision: "block", reason: $r}'
exit 0
