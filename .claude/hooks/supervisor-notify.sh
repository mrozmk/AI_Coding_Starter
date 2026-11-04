#!/bin/bash
# Notification hook: one platform notification when a supervision role session waits for the
# Operator (a permission prompt or an elicitation dialog), often in a window nobody watches.
# Wired by the operator kit's role-hooks.settings.json; the role is $1 or TEAM_SESSION_ROLE.
# Not gated by TEAM_NOTIFY: the Operator is needed. The backend is teams.channel.notifier
# (none when the channel config does not load). Silent in a team clone, for any other role and
# for any other notification type. Always exits 0.

PAYLOAD=$(cat)
command -v jq >/dev/null 2>&1 || exit 0
ROOT="${CLAUDE_PROJECT_DIR:-$PWD}"
[ ! -f "$ROOT/.agents/team/team.json" ] || exit 0

ROLE="${1:-${TEAM_SESSION_ROLE:-}}"
case "$ROLE" in Supervisor|TeamLead|Advisor) ;; *) exit 0 ;; esac

# The matcher already filters; this keeps a misconfigured matcher from notifying on idle.
KIND=$(printf '%s' "$PAYLOAD" | jq -r '.notification_type // ""' 2>/dev/null)
case "$KIND" in permission_prompt|elicitation_dialog) ;; *) exit 0 ;; esac
MSG=$(printf '%s' "$PAYLOAD" | jq -r '.message // ""' 2>/dev/null)

NOTIFIER=none NAME="$ROLE"
if out=$(cd "$ROOT" && bash .claude/lib/team-channel.sh show 2>/dev/null); then
  NOTIFIER=$(printf '%s\n' "$out" | sed -n 's/^TEAM_CHANNEL_NOTIFIER=//p')
  SUFFIX=$(printf '%s\n' "$out" | sed -n 's/^TEAM_CHANNEL_SUFFIX=//p')
  NAME="$ROLE$SUFFIX"
fi
bash "$ROOT/.claude/team/sessions/operator-kit/notify.sh" --backend "${NOTIFIER:-none}" --alarm \
  "$NAME" "$MSG" >/dev/null 2>&1 || true
exit 0
