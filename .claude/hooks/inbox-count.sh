#!/bin/bash
# UserPromptSubmit hook — the third inbox check (the doorbell and start/restore are the others; no
# wake loop): on every prompt, when this session's inbox holds messages, one line
#   inbox: N waiting — .agents/team/inbox/<address>/new
# and, at most once a minute, last_seen in its registry record (so a live ad-hoc conversation is
# never pruned). Two identities: the registry address (HARNESS_ADDRESS, else adhoc-<handle> from
# Herdr's HC_TERMINAL_ID or the tmux session) and the inbox address (the same, except a team's
# TeamLead <team>-lead reads the team's inbox <team>). Runs on every prompt, so it stays cheap: no
# git, no hc, one jq write at most. For the Supervisor with a teams.batch_gate block, once a day
# while today has no accepted day plan: `day plan: none for <date>` (one jq read, a stamp file).
# Silent otherwise; always exits 0.

cat >/dev/null 2>&1
ROOT="${CLAUDE_PROJECT_DIR:-$PWD}"
MAIN="" ra=""
if [ -n "${HARNESS_ADDRESS:-}" ]; then
  ra="$HARNESS_ADDRESS"
  MAIN="${HARNESS_MAIN:-}"
  [ -n "$MAIN" ] || { [ -z "${HARNESS_REGISTRY:-}" ] || MAIN="${HARNESS_REGISTRY%/.agents/team/registry}"; }
elif [ "${TEAM_SESSION_ROLE:-}" = TeamLead ] && [ -f "$ROOT/.agents/team/team.json" ]; then
  # A per-run TeamLead launched before the driver: its team, the main checkout from teamlead.json.
  command -v jq >/dev/null 2>&1 || exit 0
  t="$(jq -r '.team // empty' "$ROOT/.agents/team/team.json" 2>/dev/null)"
  [ -n "$t" ] && ra="$t-lead"
  MAIN="$(jq -r '.main_root // empty' "$ROOT/.agents/team/teamlead.json" 2>/dev/null)"
elif [ ! -f "$ROOT/.agents/team/team.json" ] && [ -z "${TEAM_SESSION_ROLE:-}" ]; then
  h=""
  if [ -n "${HC_TERMINAL_ID:-}" ]; then h="$HC_TERMINAL_ID"
  elif [ -n "${TMUX:-}" ] && [ -n "${TMUX_PANE:-}" ]; then
    # Direct, never the driver: sourcing session-host-lib.sh on every prompt costs (part host (35)).
    h="$(tmux -S "${TMUX%%,*}" display-message -p -t "$TMUX_PANE" '#S' 2>/dev/null)"
  fi
  [ -z "$h" ] || ra="adhoc-$(printf '%s' "$h" | tr -c 'A-Za-z0-9_-' '-')"
  MAIN="$ROOT"
fi
[ -n "$ra" ] && [ -n "$MAIN" ] && [[ "$ra" =~ ^[A-Za-z0-9:_-]+$ ]] || exit 0

# last_seen, skipped while the record changed within the last minute.
rec="$MAIN/.agents/team/registry/$ra.json"
if [ -f "$rec" ] && [ -z "$(find "$rec" -mmin -1 2>/dev/null)" ] && command -v jq >/dev/null 2>&1; then
  ( umask 077
    jq --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '.last_seen = $at' "$rec" > "$rec.tmp.$$" 2>/dev/null \
      && mv "$rec.tmp.$$" "$rec" || rm -f "$rec.tmp.$$" )
fi

# The Supervisor's first prompt of a day without an accepted day plan (the regression cadence),
# once a day; only where the profile has a teams.batch_gate block.
if [ "$ra" = Supervisor ] && command -v jq >/dev/null 2>&1 \
  && jq -e '(.teams | type == "object") and (.teams | has("batch_gate"))' "$MAIN/.claude/project-profile.json" >/dev/null 2>&1; then
  d="$(date +%F)" p="$MAIN/.agents/team/day-plan.md" s="$MAIN/.agents/team/day-plan.nudged"
  if ! { grep -qx "date: $d" "$p" 2>/dev/null && grep -q '^accepted:' "$p" 2>/dev/null; } \
    && [ "$(cat "$s" 2>/dev/null)" != "$d" ]; then
    echo "day plan: none for $d"
    { mkdir -p "$MAIN/.agents/team" && printf '%s\n' "$d" > "$s"; } 2>/dev/null
  fi
fi

ia="$ra"
# Only a team address <team>-lead maps (roles carry no dash; helper: and adhoc- never map).
if [[ "$ra" == *-lead && "$ra" != *:* && "$ra" != adhoc-* ]]; then ia="${ra%-lead}"; fi
n=0
for m in "$MAIN/.agents/team/inbox/$ia/new"/*.md; do [ -f "$m" ] && n=$((n + 1)); done
[ "$n" -eq 0 ] || echo "inbox: $n waiting — .agents/team/inbox/$ia/new"
exit 0
