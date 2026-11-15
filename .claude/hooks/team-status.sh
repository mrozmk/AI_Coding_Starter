#!/bin/bash
# Hook (Notification | UserPromptSubmit | PostToolUse | Stop | SessionEnd) — two jobs:
#
# 1. State file for the session-host driver (tmux backend). A session the driver started carries
#    HARNESS_ADDRESS / HARNESS_REGISTRY / HARNESS_BACKEND in its launch environment; for it this
#    hook writes <registry>/state/<address>.json {state, kind, at, session_id, transcript_path}
#    (tmp + mv), and removes it on SessionEnd. `session-host.sh status` reads it; the tool and
#    command of a permission prompt come from the transcript, never from the screen. A write from
#    a session id other than the registry record's is dropped (a leftover of the replaced
#    session). Without HARNESS_ADDRESS nothing is written. No jq, no python: it runs on every
#    tool call.
#
# 2. OSC 7501 to attached tmux clients (until the Herdr-over-tmux layering goes). Claude Code
#    reports its state with OSC 7501 (working / blocked / idle), which terminals such as Herdr
#    turn into a tab/space status and a "needs you" signal. tmux never forwards that sequence (nor
#    the terminal's reply to Claude's probe), so a role session attached from Herdr looks like a
#    plain program and a permission prompt goes unnoticed. This writes the same sequence straight
#    to the tty of every tmux client attached to this session — the pty of the preview pane — so
#    tmux is not in the path. No-op outside tmux, without attached clients, or when the event maps
#    to no state. Harmless for terminals that ignore OSC 7501.
#
# Must exit 0 always.

payload=$(cat)
event=$(printf '%s' "$payload" | sed -n 's/.*"hook_event_name" *: *"\([^"]*\)".*/\1/p' | head -1)
kind=$(printf '%s' "$payload" | sed -n 's/.*"notification_type" *: *"\([^"]*\)".*/\1/p' | head -1)

# ---- 1. state file -------------------------------------------------------------------------------
jstr() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }
# field <key> <json> → the FIRST "key": "value" (the hook's top-level fields come before
# tool_input/tool_response, whose own keys must not win; escaped quotes inside strings never match).
field() { printf '%s' "$2" | grep -o "\"$1\" *: *\"[^\"]*\"" | head -1 | sed 's/.*: *"//; s/"$//'; }
if [ -n "${HARNESS_ADDRESS:-}" ] && [ -n "${HARNESS_REGISTRY:-}" ] \
  && [ "${HARNESS_BACKEND:-tmux}" = tmux ] && [[ "$HARNESS_ADDRESS" =~ ^[A-Za-z0-9:_-]+$ ]]; then
  fstate="" fkind="" fevent="$(field hook_event_name "$payload")" fntype="$(field notification_type "$payload")"
  case "$fevent" in
    UserPromptSubmit|PostToolUse) fstate=working ;;
    Stop) fstate=done ;;
    SessionEnd) fstate=end ;;
    Notification)
      case "$fntype" in
        permission_prompt) fstate=blocked fkind=permission ;;
        elicitation_dialog) fstate=blocked fkind=question ;;
        agent_needs_input) fstate=blocked fkind=input ;;
        idle_prompt) fstate=idle ;;
      esac ;;
  esac
  sid="$(field session_id "$payload")"
  rec="$(cat "$HARNESS_REGISTRY/$HARNESS_ADDRESS.json" 2>/dev/null || true)"
  rsid="$(field session_id "$rec")"
  f="$HARNESS_REGISTRY/state/$HARNESS_ADDRESS.json"
  if [ -n "$fstate" ] && { [ -z "$rsid" ] || [ "$rsid" = "$sid" ]; }; then
    if [ "$fstate" = end ]; then
      cur="$(field session_id "$(cat "$f" 2>/dev/null || true)")"
      [ -n "$cur" ] && [ "$cur" != "$sid" ] || rm -f "$f"
    else
      tp="$(field transcript_path "$payload")"
      k="null"; [ -z "$fkind" ] || k="\"$fkind\""
      { mkdir -p "$HARNESS_REGISTRY/state" \
        && printf '{"state": "%s", "kind": %s, "at": "%s", "session_id": "%s", "transcript_path": "%s"}\n' \
          "$fstate" "$k" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(jstr "$sid")" "$(jstr "$tp")" \
          > "$f.tmp.$$" && mv "$f.tmp.$$" "$f"; } 2>/dev/null || rm -f "$f.tmp.$$"
    fi
  fi
fi

# ---- 2. OSC 7501 ---------------------------------------------------------------------------------
[ -n "$TMUX" ] && [ -n "$TMUX_PANE" ] || exit 0
command -v tmux >/dev/null 2>&1 || exit 0

case "$event" in
  UserPromptSubmit) state=working ;;
  PostToolUse)      state=working ;;   # answered question / granted permission: the turn runs again
  Stop)             state=idle ;;
  SessionEnd)       state=clear ;;
  Notification)
    case "$kind" in
      permission_prompt|elicitation_dialog|agent_needs_input) state=blocked ;;
      idle_prompt) state=idle ;;
      *) exit 0 ;;
    esac ;;
  *) exit 0 ;;
esac

sock="${TMUX%%,*}"
session=$(tmux -S "$sock" display-message -p -t "$TMUX_PANE" '#S' 2>/dev/null) || exit 0
[ -n "$session" ] || exit 0

tmux -S "$sock" list-clients -t "=$session" -F '#{client_tty}' 2>/dev/null | while IFS= read -r tty; do
  [ -n "$tty" ] && [ -w "$tty" ] || continue
  printf '\033]7501;state=%s\007' "$state" > "$tty" 2>/dev/null || true
done
exit 0
