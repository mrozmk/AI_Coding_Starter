#!/bin/bash
# Hook (Notification | UserPromptSubmit | PostToolUse | Stop | SessionEnd) — the state file for the
# session-host driver (tmux backend). A session the driver started carries HARNESS_ADDRESS /
# HARNESS_REGISTRY / HARNESS_BACKEND in its launch environment; for it this hook writes
# <registry>/state/<address>.json {state, kind, at, session_id, transcript_path} (tmp + mv), and
# removes it on SessionEnd. `session-host.sh status` reads it; the tool and command of a permission
# prompt come from the transcript, never from the screen. A write from a session id other than the
# registry record's is dropped (a leftover of the replaced session). Without HARNESS_ADDRESS, or
# under the Herdr backend (the program reports its own status there), nothing is written. No jq, no
# python: it runs on every tool call.
#
# Must exit 0 always.

payload=$(cat)

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

exit 0
