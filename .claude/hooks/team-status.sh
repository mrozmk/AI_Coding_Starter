#!/bin/bash
# Hook (Notification | UserPromptSubmit | Stop | SessionEnd) — forwards this session's agent
# state to the terminal that shows it, when the session runs inside tmux.
#
# Problem it solves: Claude Code reports its state with OSC 7501 (working / blocked / idle),
# which terminals such as Herdr turn into a tab/space status and a "needs you" signal. tmux
# never forwards that sequence (nor the terminal's reply to Claude's probe), so a role session
# attached from Herdr looks like a plain program and a permission prompt goes unnoticed.
# This hook writes the same sequence straight to the tty of every tmux client attached to
# this session — the pty of the preview pane — so tmux is not in the path.
#
# No-op outside tmux, without attached clients, or when the event maps to no state. Harmless
# for terminals that ignore OSC 7501. Must exit 0 always.

[ -n "$TMUX" ] && [ -n "$TMUX_PANE" ] || exit 0
command -v tmux >/dev/null 2>&1 || exit 0

payload=$(cat)
event=$(printf '%s' "$payload" | sed -n 's/.*"hook_event_name" *: *"\([^"]*\)".*/\1/p' | head -1)
kind=$(printf '%s' "$payload" | sed -n 's/.*"notification_type" *: *"\([^"]*\)".*/\1/p' | head -1)

case "$event" in
  UserPromptSubmit) state=working ;;
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
