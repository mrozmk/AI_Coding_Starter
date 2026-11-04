"""Logic of guard-team-egress.sh: keep the egress prompt for team roles in auto mode.

WebFetch to a host outside the project's WebFetch(domain:...) allowlist -> ask; a Bash command whose
command-position word is an egress tool (curl wget ssh scp rsync nc ftp sftp) -> ask, also inside
bash -c, tmux arguments, eval, $(...) and here-doc lines. Never emits allow: no output leaves the
decision to Claude Code's own rules, so deny still wins. Unreadable input -> ask (fail-closed).
A loopback port probe (`nc -z [-v] [-w n] [-G n] localhost|127.0.0.1|::1 <ports>`) is not egress.
"""
import json
import os
import re
import sys
from urllib.parse import urlsplit

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)  # python3 -I drops the script dir from sys.path

from guard_destructive_sql import commands, doc_heredocs_removed, tokenize  # noqa: E402

EGRESS = {"curl", "wget", "ssh", "scp", "rsync", "nc", "ftp", "sftp"}
LOOPBACK = {"localhost", "127.0.0.1", "::1"}
SHELLS = {"bash", "sh", "zsh"}
WRAPPERS = {"sudo", "time", "env", "nohup", "command", "exec", "xargs", "nice", "timeout"}
# commands() splits on `;`/newline, so `do curl …` / `then curl …` start a command with a keyword.
KEYWORDS = {"{", "(", "!", "if", "then", "else", "elif", "do", "while", "until"}
# Wrapper options whose value is a separate word: `env -u NAME curl` must not read NAME as the verb.
OPTION_VALUES = {
    "env": {"-u", "-C", "-S"}, "nice": {"-n"}, "timeout": {"-s", "-k"},
    "sudo": {"-u", "-g", "-h", "-p", "-C", "-D", "-r", "-t", "-U"},
    "xargs": {"-n", "-P", "-I", "-L", "-s", "-d", "-E", "-a"},
}
SHELL_C = re.compile(r"^-[a-zA-Z]*c[a-zA-Z]*$")  # -c, -lc, -ec
MENTIONS_EGRESS = re.compile(r"\b(" + "|".join(sorted(EGRESS)) + r")\b")
SUBST = re.compile(r"\$\(|`|\)")
DOMAIN_RULE = re.compile(r"^WebFetch\(domain:([^)]*)\)$")


class Unreadable(Exception):
    pass


def verdict(reason):
    return {"hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": "ask",
        "permissionDecisionReason": "team egress: " + reason + " — Operator"}}


def strip_wrappers(words):
    while words:
        head = os.path.basename(words[0])
        if words[0] in KEYWORDS:
            words = words[1:]
            continue
        if head not in WRAPPERS and not re.match(r"^\w+=", words[0]):
            break
        takes_value = OPTION_VALUES.get(head, set())
        words = words[1:]
        while words and (words[0].startswith("-") or re.match(r"^\w+=", words[0])):
            words = words[2:] if words[0] in takes_value else words[1:]
        if head == "timeout" and words and re.match(r"^\d", words[0]):
            words = words[1:]
    return words


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
