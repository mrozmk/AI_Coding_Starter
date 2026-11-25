#!/bin/bash
# Notification hook (async) — records a permission prompt that waits for a human in the
# project's Operator touch log (.claude/lib/touches.py hook), with the masked tool input of the
# pending call. Acts only on
# `notification_type: permission_prompt`; in a lead-run stage only on a prompt no ask covers.
# Never blocks or fails the session: always exit 0, no output.
# Contract: .agents/reference/operator-touches.md

command -v python3 >/dev/null 2>&1 || exit 0
python3 -I "$(cd "$(dirname "$0")/../lib" && pwd)/touches.py" hook >/dev/null 2>&1
exit 0
