"""Logic of guard-team-egress.sh: keep the egress prompt for team roles in auto mode.

WebFetch to a host outside the project's WebFetch(domain:...) allowlist -> ask; a Bash command whose
command-position word is an egress tool (curl wget ssh scp rsync nc ftp sftp) -> ask, also inside
bash -c, tmux arguments, eval, $(...) and here-doc lines. Never emits allow: no output leaves the
decision to Claude Code's own rules, so deny still wins. Unreadable input -> ask (fail-closed).
A loopback port probe (`nc -z [-v] [-w n] [-G n] localhost|127.0.0.1|::1 <ports>`) is not egress.
git push/fetch/pull/clone/ls-remote/submodule add/remote add|set-url whose repository argument is a
URL or `host:path` -> ask unless the host is in the same WebFetch allowlist; a bare remote name or
a local path passes (the remote's configured URL was itself set through this check or by a human).
"""
import json
import os
import re
import sys
from urllib.parse import urlsplit

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)  # python3 -I drops the script dir from sys.path

from guard_destructive_sql import (  # noqa: E402
    SHELL_C, commands, doc_heredocs_removed, strip_wrappers, tokenize)

EGRESS = {"curl", "wget", "ssh", "scp", "rsync", "nc", "ftp", "sftp"}
LOOPBACK = {"localhost", "127.0.0.1", "::1"}
SHELLS = {"bash", "sh", "zsh"}
MENTIONS_EGRESS = re.compile(r"\b(" + "|".join(sorted(EGRESS)) + r")\b")
SUBST = re.compile(r"\$\(|`|\)")
DOMAIN_RULE = re.compile(r"^WebFetch\(domain:([^)]*)\)$")
GIT_NET = {"push", "fetch", "pull", "clone", "ls-remote", "submodule", "remote"}
URL_SCHEME = re.compile(r"^[a-zA-Z][a-zA-Z0-9+.-]*://")
SCP_LIKE = re.compile(r"^(?:[^@/\s]+@)?([A-Za-z0-9.\-]+):(?!//)")


class Unreadable(Exception):
    pass


def verdict(reason):
    return {"hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": "ask",
        "permissionDecisionReason": "team egress: " + reason + " — Operator"}}


def loopback_probe(words):
    """True only for `nc` with -z (and -v/-w n/-G n), one loopback host, then port numbers."""
    if not words or os.path.basename(words[0]) != "nc":
        return False
    i, flags = 1, ""
    while i < len(words) and words[i].startswith("-"):
        if re.fullmatch(r"-[zv]+", words[i]):
            flags += words[i]
            i += 1
        elif words[i] in ("-w", "-G") and re.fullmatch(r"[0-9]+", "".join(words[i + 1:i + 2])):
            i += 2
        else:
            return False
    ports = words[i + 1:]
    return ("z" in flags and i < len(words) and words[i] in LOOPBACK and bool(ports)
            and all(re.fullmatch(r"[0-9]+(-[0-9]+)?", w) for w in ports))


def git_repo_arg(words):
    """The repository word of a network git command, or None (a bare remote name is returned too)."""
    i = 1
    while i < len(words) and words[i].startswith("-"):
        i += 2 if words[i] in ("-C", "-c") else 1
    if i >= len(words) or words[i] not in GIT_NET:
        return None
    sub, args = words[i], words[i + 1:]
    pos = [w for w in args if not w.startswith("-")]
    if sub == "remote":
        if not pos or pos[0] not in ("add", "set-url"):
            return None
        return pos[2] if len(pos) > 2 else None
    if sub == "submodule":
        return pos[1] if len(pos) > 1 and pos[0] == "add" else None
    return pos[0] if pos else None


def repo_host(arg):
    """The network host a git repository word names, '' for a remote name or a local path."""
    if URL_SCHEME.match(arg):
        if arg.lower().startswith("file://"):
            return ""
        try:
            return (urlsplit(arg).hostname or "?").rstrip(".").lower()
        except ValueError:
            return "?"
    if arg.startswith(("/", ".", "~")):
        return ""
    m = SCP_LIKE.match(arg)
    return m.group(1).lower() if m else ""


def git_host_ok(host):
    if host in LOOPBACK:
        return True
    try:
        return host_allowed(host, allowlist(os.environ.get("CLAUDE_PROJECT_DIR", "")))
    except Unreadable:
        return False


def egress_in(cmd, depth=0):
    """Name of the first egress tool in command position, or ''. ValueError on unparsable text."""
    return verb_in(cmd, EGRESS, depth)


def verb_in(cmd, names, depth=0):
    """First of <names> in command position, also nested; a loopback probe is not `nc`."""
    for raw in commands(tokenize(cmd)):
        words = strip_wrappers(raw)
        verb = os.path.basename(words[0].lstrip("`")) if words else ""
        if verb in names and not (verb == "nc" and loopback_probe(words)):
            return verb
        if verb == "git" and names is EGRESS:
            host = repo_host(git_repo_arg(words) or "")
            if host and not git_host_ok(host):
                return "git to " + host
        if depth >= 3:
            continue
        # From the raw words: an assignment `x=$(curl …)` is stripped as a wrapper above.
        nested = [SUBST.sub(" ; ", w) for w in raw if "$(" in w or "`" in w]
        flag = next((i for i, w in enumerate(words[1:-1], 1) if SHELL_C.match(w)), 0)
        if verb in SHELLS and flag:
            nested.append(words[flag + 1])
        elif verb in ("tmux", "eval"):
            nested.extend(words[1:])
        for inner in nested:
            found = verb_in(inner, names, depth + 1)
            if found:
                return found
    return ""


def bash_reason(cmd):
    try:
        found = egress_in(cmd)
    except ValueError:
        try:
            found = egress_in(doc_heredocs_removed(cmd))
        except ValueError:
            # Unparsable: an egress tool cannot sit in command position without its name.
            if MENTIONS_EGRESS.search(cmd):
                return "unparsable command mentions an egress tool"
            return ""
    if found.startswith("git to "):
        return found + " (not in the WebFetch allowlist)"
    return found + " in command position" if found else ""


def allowlist(project):
    """Union of the WebFetch(domain:...) allow rules of settings.json + settings.local.json."""
    if not project:
        raise Unreadable("CLAUDE_PROJECT_DIR unset")
    rules = []
    for name, required in (("settings.json", True), ("settings.local.json", False)):
        path = os.path.join(project, ".claude", name)
        if not required and not os.path.exists(path):
            continue
        try:
            with open(path, encoding="utf-8") as fh:
                allow = (json.load(fh).get("permissions") or {}).get("allow") or []
        except (OSError, ValueError, AttributeError):
            raise Unreadable(name + " unreadable")
        rules.extend(r for r in allow if isinstance(r, str))
    domains = []
    for rule in rules:
        m = DOMAIN_RULE.match(rule)
        if not m:
            continue
        d = m.group(1).strip().lower().rstrip(".")
        # Never widened: bare wildcards are ignored, `*.x.y` covers true subdomains only.
        if d.startswith("*.") and "*" not in d[2:] and "." in d[2:]:
            domains.append(d[1:])
        elif d and "*" not in d:
            domains.append(d)
    return domains


def host_allowed(host, domains):
    return any(host.endswith(d) if d.startswith(".") else host == d for d in domains)


def webfetch_reason(url, project):
    try:
        host = (urlsplit(url).hostname or "").rstrip(".") if isinstance(url, str) else ""
    except ValueError:
        host = ""
    if not host:
        return "unparsable WebFetch URL"
    # WHATWG (WebFetch) reads `\` as `/` and urlsplit does not: `https://evil\@allowed/` differs.
    if "\\" in url or "@" in urlsplit(url).netloc:
        return "ambiguous WebFetch URL (" + host + ")"
    try:
        domains = allowlist(project)
    except Unreadable as e:
        return host + " not checked (" + str(e) + ")"
    return "" if host_allowed(host, domains) else host + " not in WebFetch allowlist"


def main():
    try:
        payload = json.load(sys.stdin)
        tool = payload.get("tool_name")
        tool_input = payload.get("tool_input") or {}
        if not isinstance(tool_input, dict):
            raise ValueError
    except (ValueError, AttributeError):
        print(json.dumps(verdict("unreadable hook payload")))
        return
    if tool == "WebFetch":
        reason = webfetch_reason(tool_input.get("url"), os.environ.get("CLAUDE_PROJECT_DIR", ""))
    elif tool == "Bash":
        cmd = tool_input.get("command")
        reason = bash_reason(cmd) if isinstance(cmd, str) else "unreadable Bash command"
    else:
        return
    if reason:
        print(json.dumps(verdict(reason)))


if __name__ == "__main__":
    main()
