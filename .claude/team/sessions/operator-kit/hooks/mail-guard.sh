#!/usr/bin/env bash
# Stop hook of the supervision roles (the operator kit's): refuses to end a turn while this role
# has unread agent-mail turns. The role is the launcher's TEAM_SESSION_ROLE, never a transcript
# title; only the Supervisor is held (an Advisor reads its own mail by hand at bootstrap; a
# role-less window is silent).
# Every address comes from the channel config (team_channel_load). Fails open: no jq, no channel,
# a failing helper → nothing to hold. Prints {"decision":"block",…} only on the block path; always
# exits 0.
set -u
in="$(cat)"
command -v jq >/dev/null 2>&1 || exit 0
R="${CLAUDE_PROJECT_DIR:-$PWD}"
[ ! -f "$R/.agents/team/team.json" ] || exit 0
role="${TEAM_SESSION_ROLE:-}"
case "$role" in Supervisor) ;; *) exit 0 ;; esac
[ -f "$R/.claude/lib/team-channel.sh" ] || exit 0
. "$R/.claude/lib/team-channel.sh"
team_channel_load "$R" >/dev/null 2>&1 || exit 0
name="$(team_channel_role "$role")" || exit 0

bounded() { perl -e 'alarm shift; exec @ARGV' 10 "$@"; }

unread="$(cd "$R" && bounded bash .claude/lib/team-mail.sh "$TEAM_CHANNEL_KEY" inbox --for "$name" --unread --limit 0 2>/dev/null \
  | grep '^\[agent-mail\]' | grep ' kind=turn ' | grep -v ' thread=esc-' || true)"
[ -n "$unread" ] || exit 0
jq -n --arg r "Unread agent-mail turn for $name — read, handle and ack it:"$'\n'"$unread" '{decision: "block", reason: $r}'
exit 0
