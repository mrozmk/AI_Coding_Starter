#!/usr/bin/env bash
# The Herdr half of team-answer.sh: typing and `other` through the session-host driver. Sourced by
# team-answer.sh (its globals: PANE_ID, KEYS, ATTEMPT, JOURNAL, T, name; its helpers: refuse, stop,
# send_key, type_text). Not run on its own.
# herdr_type <text> — hc send pastes and submits in one step (the driver prints typed+submitted), so
# there is no typed-text check and no Enter; delivery is confirmed from the transcript instead: a
# new user message holding the text (hc may wrap it in an <hc from=…> tag).
herdr_type() {
  local i=$((KEYS + 1)) out size=0 n=0 max
  [ -z "$JOURNAL" ] || echo "$ATTEMPT try $i type (herdr)" >> "$JOURNAL"
  [ "$T" = - ] || [ ! -f "$T" ] || size="$(wc -c < "$T" | tr -d ' ')"
  # Refused (9) on an open prompt or an empty status (a startup dialog may be open): the driver's
  # one-line reason lands in the refuse/stop message below.
  out="$(sh_herdr_type "$PANE_ID" "$1" "$(sh_record_get "$(team_main)" "$name" cli 2>/dev/null)" "$name" 2>&1)" || true
  if [ "$out" != typed+submitted ]; then
    [ "$KEYS" -gt 0 ] || refuse 6 "type failed: ${out:-no answer}"
    echo "error: type failed at key $i (${out:-no answer}) — $KEYS keys sent" >&2; exit 4
  fi
  KEYS=$i; [ -z "$JOURNAL" ] || echo "$ATTEMPT ok $i" >> "$JOURNAL"
  [ "$T" != - ] || { echo "typed+submitted (no transcript to confirm)"; return 0; }
  max=$(( ${TEAM_TYPED_SECS:-5} * 5 ))
  while [ "$n" -lt "$max" ]; do
    [ "$(python3 -I -c 'import json, sys
f = open(sys.argv[1], "rb"); f.seek(int(sys.argv[2])); t = sys.argv[3]; hit = "no"
for l in f:
    try: o = json.loads(l)
    except ValueError: continue
    if o.get("type") != "user": continue
    c = (o.get("message") or {}).get("content")
    s = c if isinstance(c, str) else " ".join(x.get("text", "") for x in c or [] if isinstance(x, dict))
    if t in s: hit = "yes"; break
print(hit)' "$T" "$size" "$1" 2>/dev/null)" != yes ] || { echo "typed+submitted (transcript)"; return 0; }
    sleep 0.2; n=$((n + 1))
  done
  stop 6 "typed text not in the transcript after submit"
}
# herdr_other <text> — `other` under herdr (owner, 2026-11-15): typing into the open menu is not
# possible, so deny it (esc, as `no`), wait until the prompt is gone, then the text on the idle input.
herdr_other() {
  local n=0 max=$(( ${TEAM_TYPED_SECS:-5} * 5 ))
  [ -z "$JOURNAL" ] || echo "$ATTEMPT other→deny+message (herdr)" >> "$JOURNAL"
  echo "other→deny+message (herdr)"
  send_key Escape
  while [ "$(sh_herdr_state "$PANE_ID")" = blocked ]; do
    n=$((n + 1)); [ "$n" -lt "$max" ] || stop 6 "prompt still open after Escape"
    sleep 0.2
  done
  type_text "$1"
}
