"""Logging-only PermissionRequest probe: hook | claude-settings | codex-config.

`hook --log <file> [--sleep N]` appends one masked JSON line for the payload on stdin (written on
entry, before any sleep), prints nothing and exits 0 — it never decides, so the host's own dialog
still shows. `claude-settings` / `codex-config` print the fixture a throwaway session loads from
scratch: the probe on PermissionRequest and on PreToolUse (the PreToolUse line proves the fixture
loaded and the target call happened). Never install it in a real settings file or role profile.
Procedure: .agents/reference/permission-probes.md. Stdlib only."""
import argparse
import json
import os
import sys
import time
sys.dont_write_bytecode = True

HERE = os.path.dirname(os.path.abspath(__file__))


def _masker():
    try:
        sys.path.insert(0, HERE)
        import touches
        return touches.mask_obj
    except Exception:  # noqa: BLE001 — without the masker the input is never logged
        return None


def hook(log, sleep):
    raw = sys.stdin.read()
    at = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    try:
        p = json.loads(raw)
        if not isinstance(p, dict):
            raise ValueError
        mask = _masker()
        ti = mask(p.get("tool_input")) if mask else "<unmasked: touches.py missing>"
        line = {"at": at, "hook_event_name": p.get("hook_event_name"), "tool_name": p.get("tool_name"),
                "tool_input": ti, "session_id": p.get("session_id"), "agent_id": p.get("agent_id"),
                "agent_type": p.get("agent_type"), "permission_mode": p.get("permission_mode"),
                "cwd": p.get("cwd"), "keys": sorted(p)}
    except ValueError:
        line = {"at": at, "unreadable": True}
    with open(log, "a", encoding="utf-8") as fh:
        fh.write(json.dumps(line, ensure_ascii=False) + "\n")
        fh.flush()
    if sleep:
        time.sleep(sleep)


def _command(log, sleep):
    cmd = "python3 -I %s hook --log %s" % (json.dumps(os.path.abspath(__file__)), json.dumps(os.path.abspath(log)))
    return cmd + (" --sleep %d" % sleep if sleep else "")


def claude_settings(log, sleep, timeout):
    def entry(s):
        h = {"type": "command", "command": _command(log, s)}
        if timeout:
            h["timeout"] = timeout
        return [{"matcher": "", "hooks": [h]}]
    return {"hooks": {"PermissionRequest": entry(sleep), "PreToolUse": entry(0)}}


def codex_config(log, timeout):
    return claude_settings(log, 0, timeout)


def main(argv):
    ap = argparse.ArgumentParser(prog="permission_probe.py")
    sub = ap.add_subparsers(dest="cmd", required=True)
    for name in ("hook", "claude-settings", "codex-config"):
        p = sub.add_parser(name)
        p.add_argument("--log", required=True)
        if name != "codex-config":
            p.add_argument("--sleep", type=int, default=0)
        if name != "hook":
            p.add_argument("--timeout", type=int, default=0)
    if argv[:1] == ["hook"]:
        try:
            a = ap.parse_args(argv)
            hook(a.log, a.sleep)
        except BaseException:  # noqa: BLE001 — a probe never fails or disturbs its session
            pass
        return 0
    try:
        a = ap.parse_args(argv)
    except SystemExit as e:
        return 0 if e.code == 0 else 2
    out = claude_settings(a.log, a.sleep, a.timeout) if a.cmd == "claude-settings" else codex_config(a.log, a.timeout)
    print(json.dumps(out, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
