#!/usr/bin/env bash
# Operator kit installer: copies (or renders) the templates of this directory to <kit_dir>, the
# machine path in .agents/team/channel.local.json. Operator action only — run it yourself with
# `! bash …`; an agent never installs, edits or rolls back these files.
#
# Usage: bash .claude/team/sessions/operator-kit/install.sh
#   --dry-run                  what would change; writes nothing
#   --apply                    first-install backup per live file (*.bak-team-kit, never replaced),
#                              copy/render, then render the escalation config (team-channel.sh
#                              render — it appears only once the adapter exists)
#   --verify                   exit 0 only when every live file equals its template / fresh render
#   --rollback                 restore every backup and delete it, remove files that were absent,
#                              remove a *generated* escalation.local.json (a hand-written one stays)
#   --print-scheduler launchd|cron   the health-check scheduler entry to install yourself
# Never touches the mailbox, recipients.json, delivery logs, locks or the decisions notes; never
# loads, writes or removes a launchd job or a crontab line. Exit: 0 ok · 1 drift / refused / error
# · 2 usage · 3 the channel is not configured.
# Bash 3.2 compatible (macOS /bin/bash).
set -euo pipefail

usage() { sed -n '/^set -euo/q;2,$p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
[ $# -ge 1 ] || usage
K="$(cd "$(dirname "$0")" && pwd)"
root="$(git -C "$K" rev-parse --show-toplevel 2>/dev/null)" || { echo "error: not inside a checkout" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "error: jq is required" >&2; exit 1; }
. "$root/.claude/lib/team-channel.sh"
team_channel_load "$root" || exit 3
KIT="$TEAM_CHANNEL_KIT"
BAK=.bak-team-kit
LABEL="team.$(printf '%s' "$TEAM_CHANNEL_CODE" | tr '[:upper:]' '[:lower:]').sessions-health"
P="$TEAM_CHANNEL_TMUX_PREFIX"
SESSIONS="$P-supervisor $P-teamlead $P-advisor $P-team-watch $P-team-watch-dog"
ESCF="$root/.agents/team/escalation.local.json"

refuse() { echo "error: $*" >&2; exit 1; }
[[ "$KIT" =~ $TEAM_CHANNEL_SAFE ]] || refuse "kit_dir '$KIT' has characters a hook command cannot carry"
case "$KIT/" in
  "$(dirname "$TEAM_CHANNEL_BOX")/") refuse "kit_dir is the mailbox directory — the kit needs its own (default <box dir>/kit)" ;;
  "$TEAM_CHANNEL_DECISIONS"/*) refuse "kit_dir is inside the decisions directory" ;;
esac

# <kind> <template, relative to this dir> <live, relative to KIT>
MAP="copy escalate.sh escalate.sh
copy notify.sh notify.sh
copy sessions-health.sh sessions-health.sh
copy hooks/mail-guard.sh hooks/mail-guard.sh
render hooks/role-hooks.settings.json.tmpl hooks/role-hooks.settings.json
render kit.conf.tmpl kit.conf"

refused() {  # the channel's state is never the kit's to change
  case "$(basename "$1")" in
    mail.sqlite*|recipients.json|agent_mail_deliver.py|deliver-*.log|*.lock) return 0 ;;
  esac
  case "$1" in "$TEAM_CHANNEL_DECISIONS"/*) return 0 ;; esac
  return 1
}
while read -r _ _ l; do
  ! refused "$KIT/$l" || refuse "refusing to touch $KIT/$l"
done <<<"$MAP"

render() {  # render <template> → the filled content on stdout
  local t="$K/$1"
  case "$1" in
    *.json.tmpl) jq --arg kit "$KIT" 'walk(if type == "string" then gsub("\\{\\{KIT_DIR\\}\\}"; $kit) else . end)' "$t" ;;
    *) local s; s="$(cat "$t")"
       s="${s//\{\{PROJECT_CODE\}\}/$TEAM_CHANNEL_CODE}"; s="${s//\{\{SUPERVISOR_NAME\}\}/$TEAM_CHANNEL_SUPERVISOR}"
       s="${s//\{\{NOTIFIER\}\}/$TEAM_CHANNEL_NOTIFIER}"; s="${s//\{\{SESSIONS\}\}/$SESSIONS}"
       s="${s//\{\{LABEL\}\}/$LABEL}"; s="${s//\{\{KIT_DIR\}\}/$KIT}"
       printf '%s\n' "$s" ;;
  esac
}
want() {  # want <kind> <template> <out file> — what the live file must contain
  if [ "$1" = copy ]; then cp "$K/$2" "$3"; else render "$2" > "$3"; fi
}

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

dry() {
  local kind="$1" t="$2" l="$KIT/$3" note
  want "$kind" "$t" "$TMP/w"
  if [ ! -e "$l" ]; then note="new"
  elif cmp -s "$TMP/w" "$l"; then note="identical"
  elif [ -e "$l$BAK" ] || [ -e "$l$BAK.absent" ]; then note="backup kept"
  else note="backup $l$BAK"; fi
  echo "$kind $t → $l ($note)"
}

apply_one() {
  local kind="$1" t="$2" l="$KIT/$3" tmp
  mkdir -p "$(dirname "$l")"
  # The first install's state wins: a later --apply never backs up a kit file over the original.
  if [ ! -e "$l$BAK" ] && [ ! -e "$l$BAK.absent" ]; then
    if [ -e "$l" ]; then cp -p "$l" "$l$BAK"; else : > "$l$BAK.absent"; fi
  fi
  tmp="$(mktemp "$(dirname "$l")/.kit.XXXXXX")"
  want "$kind" "$t" "$tmp"
  case "$l" in *.sh) chmod 755 "$tmp" ;; *) chmod 644 "$tmp" ;; esac
  mv "$tmp" "$l"
  echo "installed $l"
}

rollback_one() {
  local l="$KIT/$3"
  if [ -e "$l$BAK" ]; then mv "$l$BAK" "$l"; echo "restored $l"
  elif [ -e "$l$BAK.absent" ]; then rm -f "$l" "$l$BAK.absent"; echo "removed $l (was absent)"
  fi
}

bad=0
verify_one() {
  local l="$KIT/$3"
  want "$1" "$2" "$TMP/w"
  if [ ! -f "$l" ]; then echo "missing $l"; bad=1
  elif cmp -s "$TMP/w" "$l"; then echo "ok $l"
  else echo "differs $l"; bad=1; fi
}

each() { local k t l; while read -r k t l; do "$1" "$k" "$t" "$l"; done <<<"$MAP"; }

scheduler() {
  case "${1:-}" in
    launchd) cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array><string>/bin/bash</string><string>$KIT/sessions-health.sh</string></array>
  <key>StartInterval</key><integer>300</integer>
  <key>RunAtLoad</key><true/>
  <key>StandardOutPath</key><string>$KIT/sessions-health.log</string>
  <key>StandardErrorPath</key><string>$KIT/sessions-health.log</string>
</dict></plist>
EOF
      echo "# install it yourself: save the plist above as ~/Library/LaunchAgents/$LABEL.plist," >&2
      echo "#   then: launchctl load -w ~/Library/LaunchAgents/$LABEL.plist" >&2 ;;
    cron)
      echo "*/5 * * * * /bin/bash \"$KIT/sessions-health.sh\" >> \"$KIT/sessions-health.log\" 2>&1"
      echo "# install it yourself: crontab -e, and add the line above" >&2 ;;
    *) usage ;;
  esac
}

case "$1" in
  --dry-run)
    each dry
    # The render sees no adapter yet and says skip; --apply installs it first and then writes the
    # file, so the dry-run reports what --apply will do.
    (cd "$root" && bash .claude/lib/team-channel.sh render --dry-run) \
      | sed 's|^skip	\.agents/team/escalation\.local\.json	no adapter at .*|plan	.agents/team/escalation.local.json	written by --apply, after it installs escalate.sh|' \
      || true ;;
  --apply)
    mkdir -p "$KIT"; chmod 700 "$KIT"
    each apply_one
    (cd "$root" && bash .claude/lib/team-channel.sh render) ;;
  --verify)
    each verify_one
    exit "$bad" ;;
  --rollback)
    each rollback_one
    if [ -f "$ESCF" ]; then
      case "$(jq -r '._generated // empty | strings' "$ESCF" 2>/dev/null || true)" in
        "$TEAM_CHANNEL_MARK"*) rm -f "$ESCF"; echo "removed $ESCF (generated; its adapter is gone)" ;;
        *) echo "kept $ESCF (hand-written — it may point at the removed adapter)" ;;
      esac
    fi
    echo "scheduler: remove it yourself if installed — launchd $LABEL or the crontab line naming $KIT/sessions-health.sh" ;;
  --print-scheduler) scheduler "${2:-}" ;;
  *) usage ;;
esac
