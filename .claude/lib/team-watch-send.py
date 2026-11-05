"""Push one message into a Claude Code session over its cross-session messaging socket.

Usage: python3 -I .claude/lib/team-watch-send.py <registration.json>   (message text on stdin)

Wire format (Claude Code binary, `[uds-messaging] Inject messages`): an auth line, then one user
line. No ack exists: exit 0 means written. No session id field is ever sent — the receiver drops
a message whose session id does not match. Exit 1 on socket error/deadline, 2 on usage, 3 when the
socket is not a socket file of mode 0600 owned by this uid: on the verified CLI the token is not
enforced, so that file mode is the only boundary and a wider one is refused, never used.
Verified per CLI version: .agents/reference/team-watch.md → Wire format.
"""
import json
import math
import os
import signal
import socket
import stat
import sys


def fail(code, reason):
    print("team-watch-send: " + reason, file=sys.stderr)
    sys.exit(code)


def socket_state(path):
    """'ok 0600' for a socket file of mode 0600 owned by this uid, else the refusal reason."""
    try:
        st = os.lstat(path)
    except OSError:
        return "missing"
    mode = "%04o" % stat.S_IMODE(st.st_mode)
    if not stat.S_ISSOCK(st.st_mode):
        return "refused not-a-socket"
    if st.st_uid != os.getuid():
        return "refused owner %d" % st.st_uid
    if mode != "0600":
        return "refused mode " + mode
    return "ok " + mode


def on_alarm(_sig, _frame):
    fail(1, "deadline exceeded")


def main():
    if len(sys.argv) != 2:
        fail(2, "usage: team-watch-send.py <registration.json>")
    try:
        with open(sys.argv[1], encoding="utf-8") as f:
            reg = json.load(f)
        path, tok = reg["socket"], reg["token"]
    except (OSError, ValueError, KeyError, TypeError) as e:
        fail(2, "unreadable registration (%s)" % type(e).__name__)
    state = socket_state(path)
    if state == "missing":
        fail(1, "socket %s missing" % path)
    if not state.startswith("ok "):
        fail(3, "socket %s %s — want mode 0600 owned by uid %d" % (path, state, os.getuid()))
    try:
        deadline = float(os.environ.get("TEAM_WATCH_SEND_SECS", "5"))
    except ValueError:
        deadline = 5.0
    text = sys.stdin.read()
    # The alarm bounds the whole exchange; settimeout alone resets on every partial send.
    signal.signal(signal.SIGALRM, on_alarm)
    signal.alarm(max(1, math.ceil(deadline)))
    auth = json.dumps({"type": "auth", "token": tok}) + "\n"
    msg = json.dumps({"type": "user", "message": {"role": "user", "content": text}}) + "\n"
    try:
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.settimeout(deadline)
        sock.connect(path)
        sock.sendall(auth.encode("utf-8"))
        sock.sendall(msg.encode("utf-8"))
        sock.shutdown(socket.SHUT_WR)
        sock.close()
    except OSError as e:
        fail(1, "%s (%s)" % (type(e).__name__, e.strerror or "timeout"))
    signal.alarm(0)


main()
