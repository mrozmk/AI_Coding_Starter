#!/usr/bin/env bash
# Install, update or remove the iMessage channel's flush job (launchd, macOS): at quiet.end it runs
# `notify.sh flush`, which sends the events held overnight as one message.
# Usage: bash .claude/team/notify-kit/install.sh [--dry-run | --rollback]
#   install / update: renders flush.plist.tmpl to ~/Library/LaunchAgents/harness.notify-flush.plist
#     (marked as the harness's) and loads it (launchctl bootout, then bootstrap gui/<uid>). It runs
#     this checkout's notify.sh — run it from the main checkout, not a team clone. One job serves
#     every project on the machine (the outbox is per user): a second install replaces the path.
#   --rollback: unloads the job and removes the plist, only when it carries the harness marker.
#   --dry-run: prints the plist and the commands; writes and loads nothing.
# Reads only imessage.quiet.end / .tz from ~/.agent-comms/notify.json — never the recipient — and
# never changes that file: switching the channel on (imessage.enabled) is the user's edit.
# Re-run it after changing quiet.end or moving the checkout (`notify.sh --check` says stale).
# Exit 0 done · 2 usage · 3 a foreign plist, no switch file or a bad quiet.end · 1 a write or load failed.
set -euo pipefail

K="$(cd "$(dirname "$0")" && pwd)"
NOTIFY="$(cd "$K/../../lib" && pwd)/notify.sh"
CONF="$HOME/.agent-comms/notify.json"
LABEL="harness.notify-flush"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="$HOME/.agent-comms/outbox/flush.log"
MARK="installed-by-harness"
LCTL="${LAUNCHCTL_BIN:-launchctl}"   # tests: a stub
DOM="gui/$(id -u)"

usage() { sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }
mode=install
case "${1:-}" in "") ;; --dry-run) mode=dry ;; --rollback) mode=rollback ;; *) usage ;; esac
[ $# -le 1 ] || usage
if [ -e "$PLIST" ] && ! grep -qF "$MARK" "$PLIST"; then
  echo "error: $PLIST exists and was not installed by the harness — left as it is" >&2; exit 3
fi

if [ "$mode" = rollback ]; then
  [ -e "$PLIST" ] || { echo "nothing to remove: $PLIST is absent"; exit 0; }
  "$LCTL" bootout "$DOM/$LABEL" 2>/dev/null || true
  rm -f "$PLIST"; echo "removed $PLIST (job $LABEL unloaded)"; exit 0
fi

[ -f "$CONF" ] || { echo "error: no $CONF — write the switch file first (see the README)" >&2; exit 3; }
end="$(jq -r '.imessage.quiet.end // empty' "$CONF" 2>/dev/null || true)"
tz="$(jq -r '.imessage.quiet.tz // empty' "$CONF" 2>/dev/null || true)"
[[ "$end" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] || { echo "error: imessage.quiet.end '${end}' is not HH:MM" >&2; exit 3; }
# The plist carries the paths as XML text: refuse the characters it would need escaped.
case "$NOTIFY$HOME" in *[\&\<\>\"\']*) echo "error: a path holds & < > or a quote — not written into a plist" >&2; exit 3 ;; esac
jq_dir="$(dirname "$(command -v jq)")"   # launchd's PATH lacks Homebrew's jq
t="$(cat "$K/flush.plist.tmpl")"
t="${t//@LABEL@/$LABEL}"; t="${t//@NOTIFY@/$NOTIFY}"; t="${t//@LOG@/$LOG}"
t="${t//@HOUR@/$((10#${end%:*}))}"; t="${t//@MINUTE@/$((10#${end#*:}))}"
t="${t//@PATH@/$jq_dir:/usr/bin:/bin:/usr/sbin:/sbin}"

stz="${NOTIFY_SYSTEM_TZ:-$(readlink /etc/localtime 2>/dev/null | sed 's|.*/zoneinfo/||')}"
warn() {
  [ -z "$tz" ] || [ -z "$stz" ] || [ "$tz" = "$stz" ] \
    || echo "warning: quiet.tz $tz is not the system zone $stz — launchd fires at $end system time"
}
old=""; [ ! -e "$PLIST" ] || old="$(sed -n 's|.*<string>\(.*notify\.sh\)</string>.*|\1|p' "$PLIST" | head -1)"

if [ "$mode" = dry ]; then
  if [ -e "$PLIST" ]; then echo "would update $PLIST${old:+ (it runs $old)}"; else echo "would install $PLIST"; fi
  printf '%s\n' "$t"
  echo "$LCTL bootout $DOM/$LABEL"; echo "$LCTL bootstrap $DOM $PLIST"
  warn; exit 0
fi

verb=installed; [ ! -e "$PLIST" ] || verb=updated
mkdir -p "$HOME/Library/LaunchAgents" "$HOME/.agent-comms/outbox"
chmod 700 "$HOME/.agent-comms" "$HOME/.agent-comms/outbox"   # launchd opens the log before notify.sh runs
printf '%s\n' "$t" > "$PLIST.tmp.$$" && mv "$PLIST.tmp.$$" "$PLIST" \
  || { rm -f "$PLIST.tmp.$$"; echo "error: cannot write $PLIST" >&2; exit 1; }
"$LCTL" bootout "$DOM/$LABEL" 2>/dev/null || true
# bootout can finish after it returns; a bootstrap of the same label right after it may fail once.
i=0; until "$LCTL" bootstrap "$DOM" "$PLIST"; do
  i=$((i + 1)); [ "$i" -lt 3 ] || { echo "error: launchctl bootstrap $PLIST failed" >&2; exit 1; }; sleep 1
done
echo "$verb $PLIST — flush at $end system time, runs $NOTIFY"
[ -z "$old" ] || [ "$old" = "$NOTIFY" ] || echo "replaced the path $old"
warn
echo "check: bash .claude/lib/notify.sh --check   ·   switch on: imessage.enabled in ~/.agent-comms/notify.json"
