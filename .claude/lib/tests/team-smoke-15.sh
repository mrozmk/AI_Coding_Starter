#!/usr/bin/env bash
# The doorbell's socket sender (team-watch-send.py: deadline, 0666 refusal with no bytes sent, 0600
# delivery) and the snapshot fields. Cases (41), (47).
# It spawns socket servers and waits on time windows, so the runner keeps it out of a parallel batch.
# team-smoke: serial
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/team-smoke-lib.sh"
. "$(dirname "${BASH_SOURCE[0]}")/team-smoke-sessions-lib.sh"
smoke_init
smoke_team AB-1098 chore/AB-1098-sender
sessions_init

# ---- (41) snapshot fields ------------------------------------------------------------------------
session coder 1 "$BASE"
echo "2026-10-19T10:00:00Z permission_prompt Claude needs your permission" >> "$RD/attention"
rm -rf "$TD/lock" "$RD/attention"
printf 'Which one?\n❯ 1. A\n  2. Type something.\nEnter to select · ↑/↓ to navigate\n' > "$WORK/pane-menu"
STUB_PANE="$WORK/pane-menu" snap "menu pane" 'coder | .status == "attention" and .menu_open
  and .live and (.screen | length > 0)'
R=$(record --verdict blocked --message "which endpoint?")
basename "$R" > "$TD/acked"; mkdir "$TD/lock"; echo $$ > "$TD/lock/pid"
snap "acked blocker, runner up" 'coder | .record_open == false and .prompt_open'
rm -rf "$TD/acked" "$TD/lock"
STUB_TMUX_ALIVE=1 snap "blocker, absent pane" 'coder | .status == "stopped" and .record_open'
rm -f "$R"
echo "team-smoke-15: (41) snapshot fields OK"

# ---- (47) socket sender: deadline, socket-mode refusal, delivery ---------------------------------
cat > "$WORK/srv5.py" <<'EOF'
import os, socket, sys
path, mode, out = sys.argv[1:4]
if os.path.exists(path):
    os.unlink(path)
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.bind(path)
os.chmod(path, 0o600 if mode != "wide" else 0o666)
s.listen(16)
held = []
while True:
    c, _ = s.accept()
    if mode == "stall":
        held.append(c)
        continue
    c.settimeout(5)
    data = b""
    try:
        while True:
            b = c.recv(65536)
            if not b:
                break
            data += b
    except OSError:
        pass
    c.close()
    with open(out, "ab") as f:
        f.write(data)
EOF
serve() {  # serve <socket> <read|stall|wide> → SRV
  python3 -I "$WORK/srv5.py" "$1" "$2" "$WORK/recv" & SRV=$!; PIDS="$PIDS $SRV"
  for _ in $(seq 1 50); do [ -S "$1" ] && return 0; sleep 0.1; done
  fail "stub server did not bind $1"
}
recv_count() {  # recv_count <text> → messages whose content contains it
  [ -f "$WORK/recv" ] || { echo 0; return 0; }
  jq -nR --arg x "$1" '[inputs | fromjson? | select(.type == "user") | .message.content
    | select(contains($x))] | length' "$WORK/recv"
}
wait_r() {  # wait_r <text> <secs> [count]
  local end=$((SECONDS + $2))
  until [ "$(recv_count "$1")" -ge "${3:-1}" ]; do
    if [ "$SECONDS" -ge "$end" ]; then
      { echo "--- recv"; cat "$WORK/recv" 2>/dev/null || true; } > "$WORK/out"
      fail "not received within $2s: $1 (x${3:-1})"
    fi
    sleep 0.5
  done
}

serve "$SD/stall.sock" stall
jq -n --arg s "$SD/stall.sock" '{socket: $s, token: "t0k"}' > "$WORK/stall.json"
T0=$SECONDS
set +e
head -c 4194304 /dev/zero | TEAM_WATCH_SEND_SECS=1 python3 -I "$SRC/.claude/lib/team-watch-send.py" \
  "$WORK/stall.json" 2> "$WORK/out"
RC=$?; set -e
[ "$RC" = 1 ] || fail "(47) sender into a stalled socket: exit $RC, expected 1"
[ $((SECONDS - T0)) -le 3 ] || fail "(47) sender deadline not enforced ($((SECONDS - T0))s)"
kill "$SRV" 2>/dev/null || true

# The token is not enforced by the CLI: a socket file wider than 0600 is refused (exit 3), never used.
rm -f "$WORK/recv"; serve "$SD/wide.sock" wide
jq -n --arg s "$SD/wide.sock" '{socket: $s, token: "t0k"}' > "$WORK/wide.json"
set +e; printf 'WIDE' | python3 -I "$SRC/.claude/lib/team-watch-send.py" "$WORK/wide.json" 2> "$WORK/out"
RC=$?; set -e
[ "$RC" = 3 ] && has "socket $SD/wide.sock refused mode 0666 — want mode 0600 owned by uid $(id -u)" "$WORK/out" \
  || fail "(47) a 0666 socket was not refused with exit 3 (exit $RC)"
sleep 0.5
# The auth line is written on its own, so a parsed-message count of 0 would not prove that no byte
# reached the socket: the raw receive file must be empty.
[ ! -s "$WORK/recv" ] || fail "(47) bytes reached a 0666 socket (raw)"
chmod 600 "$SD/wide.sock"
set +e; printf 'NARROW' | python3 -I "$SRC/.claude/lib/team-watch-send.py" "$WORK/wide.json" 2> "$WORK/out"
RC=$?; set -e
[ "$RC" = 0 ] || fail "(47) a 0600 socket was refused (exit $RC)"
wait_r NARROW 5
jq -nR '[inputs | fromjson? | select(.type == "auth")] | length > 0 and all(.token == "t0k")' "$WORK/recv" \
  | grep -qx true || fail "(47) the auth line does not carry the token"
! has session_id "$WORK/recv" || fail "(47) a message carries a session_id"
kill "$SRV" 2>/dev/null || true; rm -f "$WORK/recv"
echo "team-smoke-15: (47) socket sender OK"

echo "team-smoke-15: OK"
