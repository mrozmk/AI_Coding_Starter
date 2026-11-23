"""Logic of guard-team-egress.sh: keep the egress prompt for team roles in auto mode.

A best-effort guard over Bash and WebFetch, not an allowlist (MCP tools and WebSearch are out of
scope). WebFetch to a host outside the project's WebFetch(domain:...) allowlist -> ask; a Bash command
whose command-position word is an egress-capable tool (curl wget ssh scp rsync nc ftp sftp gh npm npx
pip pip3 pipx uvx osascript; python/python3 with -c, -, no arguments or -m other than a local test
module, node with -e/-p/--eval/-) -> ask, also inside bash -c, tmux arguments, eval, $(...),
here-doc lines and the strings of flock -c / env -S; a command with a redirection before its verb
is also read from every later word (`</dev/null curl …`), and a brace-expanded verb (`{curl,} …`)
asks. gh pr view / gh issue view pass only as the simple command's own first word (also
in a string nested under no wrapper), with a plain OWNER/REPO repo value, no URL, --hostname, brace
expansion or option-shaped glob, and no $, backtick, #, backslash, GH_HOST or GH_REPO in the text
or its tokens (a quoted ';' does not hide an argument: the whole string is checked). A /dev/tcp or
/dev/udp path (bash's sockets) -> ask, whatever the verb, at every nesting level. Never emits
allow: no output leaves the decision to Claude Code's own rules, so deny still wins. Unreadable
input -> ask (fail-closed).
A loopback port probe (`nc -z [-v] [-w n] [-G n] localhost|127.0.0.1|::1 <ports>`) is not egress.
git push/fetch/pull/clone/ls-remote/submodule add/remote add|set-url whose repository argument is a
URL or `host:path` -> ask unless the host is in the same WebFetch allowlist; a bare remote name or
a local path passes (the remote's configured URL was itself set through this check or by a human).
A URL set as git config — `git config remote.<n>.url|pushurl <url>`, `git -c remote.<n>.url=<url>`,
`url.<base>.insteadOf` — and `git push --repo[=]<url>` get the same host check.
On the gh pr|issue view read path a single-quoted --jq/--template value that gh's option layout
binds is data, not checked for taint. The Supervisor in the main checkout (TEAM_SESSION_ROLE=
Supervisor, no TEAM_RUN_TEAM, neither .agents/team/session.json nor team.json) passes compounds of
gh commands covered by a Bash(gh ...) allow rule of settings.local.json (never settings.json) and
allowlisted companions, and inline Python under the local Bash(python3 -) / Bash(python3 -c *)
opt-in; gh output piped into a shell or interpreter asks. Every Supervisor ask is appended to
.agents/touches/<yyyy-mm>.jsonl. All of it: guard_team_egress_supervisor.py.
"""
import json
import os
import re
import sys
# Local imports below: never write __pycache__ into the project (callers run python3 -I, not -B).
sys.dont_write_bytecode = True
from urllib.parse import urlsplit

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)  # python3 -I drops the script dir from sys.path

from guard_destructive_sql import (  # noqa: E402
    SHELL_C, base_comment_reading, comment_splits, commands, doc_heredocs_removed,
    needs_base_reading, redirection_led, split_spans, strip_wrappers, tokenize, unredirected)
from guard_team_egress_supervisor import (  # noqa: E402
    BRACE, GH_READS_TAINT, allow_rules, format_masked, gh_host_selector, record_touch,
    supervisor_verdict)

EGRESS = {"curl", "wget", "ssh", "scp", "rsync", "nc", "ftp", "sftp",
          "gh", "npm", "npx", "pip", "pip3", "pipx", "uvx", "osascript", "python", "python3",
          "node"}
# Interpreters are egress-capable only with inline code (-c, a module, stdin); a script file is the
# project's own code.
INLINE = {"python": {"-c", "-m", "-"}, "python3": {"-c", "-m", "-"},
          "node": {"-e", "-p", "--eval", "--print", "-"}}
# `python -m <module>` for these runs the project's own tests / stdlib tools, not a network client.
LOCAL_MODULES = {"pytest", "unittest", "doctest", "py_compile", "compileall", "json.tool"}
# The read-only gh forms /setup:teams puts on the roles' allow list.
GH_READS = (["pr", "view"], ["issue", "view"])
LOOPBACK = {"localhost", "127.0.0.1", "::1"}
SHELLS = {"bash", "sh", "zsh"}
MENTIONS_EGRESS = re.compile(r"\b(" + "|".join(sorted(EGRESS)) + r")\b")
SUBST = re.compile(r"\$\(|`|\)")
DOMAIN_RULE = re.compile(r"^WebFetch\(domain:([^)]*)\)$")
# bash's socket pseudo-files: a redirection there is egress whatever the verb.
NET_DEV = re.compile(r"/dev/(tcp|udp)\b")
NET_FOUND = "network redirection (/dev/tcp or /dev/udp)"
GIT_NET = {"push", "fetch", "pull", "clone", "ls-remote", "submodule", "remote"}
# Config keys that redirect where git connects: the value is a URL, or (insteadOf) the key holds it.
GIT_URL_KEY = re.compile(r"^remote\.[^=]+\.(url|pushurl)$", re.I)
GIT_INSTEADOF_KEY = re.compile(r"^url\.(.+)\.(insteadof|pushinsteadof)$", re.I)
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


def egress_capable(verb, words, reads_ok=True):
    """False for the forms of an egress verb that are not egress: an interpreter running a file,
    the read-only gh views the roles are allowed. <reads_ok> False: a gh read is egress too."""
    if verb in INLINE:
        # No arguments at all reads the program from stdin (`python3 <<EOF`).
        if len(words) == 1:
            return True
        for i, w in enumerate(words[1:], 1):
            short = w.startswith("-") and not w.startswith("--") and verb != "node"
            if w == "-m" or (short and w.endswith("m") and "c" not in w[1:]):
                return "".join(words[i + 1:i + 2]) not in LOCAL_MODULES
            if w in INLINE[verb] or (short and "c" in w[1:]):
                return True
        return False
    if verb == "gh":
        return not reads_ok or words[1:3] not in GH_READS
    return True


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


def git_config_urls(words):
    """URL words that git config in this command would make git connect to: `-c k=v` options,
    `git config [set] [--opts] <key> <value>` and `git push --repo[=]<url>`."""
    pairs, i = [], 1
    while i < len(words) and words[i].startswith("-"):
        if words[i] == "-c" and i + 1 < len(words):
            pairs.append(words[i + 1].split("=", 1) + [""])
        i += 2 if words[i] in ("-C", "-c") else 1
    rest = words[i:]
    if rest[:1] == ["config"]:
        pos = [w for w in rest[1:] if not w.startswith("-")]
        if pos[:1] == ["set"]:
            pos = pos[1:]
        if pos:
            pairs.append([pos[0], pos[1] if len(pos) > 1 else ""])
    urls = []
    for key, value, *_ in pairs:
        if GIT_URL_KEY.match(key):
            urls.append(value)
        m = GIT_INSTEADOF_KEY.match(key)
        if m:
            urls.append(m.group(1))
    if rest[:1] == ["push"]:
        urls.extend(w[len("--repo="):] for w in rest[1:] if w.startswith("--repo="))
    return [u for u in urls if u]


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


def egress_in(cmd, depth=0, reads_ok=True):
    """Name of the first egress tool in command position, or ''. ValueError on unparsable text."""
    return verb_in(cmd, EGRESS, depth, reads_ok)


def verb_in(cmd, names, depth=0, reads_ok=True):
    """First of <names> in command position, also nested; a loopback probe is not `nc`.
    <reads_ok> turns False for good once this string or an enclosing one could point a gh read at
    another host. Readings are only ever added (the tokens have lost quotes and spacing): a command
    with a redirection before its verb is read on from every later word, and every command is also
    read with its redirections dropped. An unparsable part stops nothing: ValueError only when no
    other part names one."""
    tokens = tokenize(cmd)
    if names is EGRESS and net_device(cmd, tokens):
        return NET_FOUND
    reads_ok = reads_ok and not gh_read_tainted(cmd, tokens)
    # (words, expand, plain): a suffix is never expanded again — every suffix of its source is
    # queued — and never plain: it may have cut a wrapper off, so it keeps no gh read exemption.
    todo = [(c, True, True) for c in commands(tokens)]
    todo += [(s[k:], False, False) for s in split_spans(tokens) for k in range(1, len(s))]
    todo += [(c, False, True) for fds in (True, False) for c in unredirected(tokens, fds)]
    done, inners, broken = set(), set(), False
    while todo:
        raw, expand, plain = todo.pop(0)
        if (tuple(raw), plain) in done:
            continue
        done.add((tuple(raw), plain))
        strings = []
        try:
            words = strip_wrappers(raw, strings)
        except ValueError:
            # The strings collected so far and the raw substitutions are still scanned below.
            broken, words = True, []
        if expand and redirection_led(raw, words):
            todo += [(r[k:], False, False) for r in (raw, words) for k in range(1, len(r))]
        plain = reads_ok and plain and words == raw
        # strip_wrappers re-splits `flock -c "<cmd>"` / `env -S "<cmd>"`: check what it produced too.
        if names is EGRESS and net_device("", words):
            return NET_FOUND
        if names is EGRESS and words and BRACE.search(words[0]):
            return "brace expansion " + words[0]
        verb = os.path.basename(words[0].lstrip("`")) if words else ""
        if verb in names and not (verb == "nc" and loopback_probe(words)) and not (
                names is EGRESS and not egress_capable(verb, words, plain)):
            return verb
        if verb == "git" and names is EGRESS:
            for arg in [git_repo_arg(words) or ""] + git_config_urls(words):
                host = repo_host(arg)
                if host and not git_host_ok(host):
                    return "git to " + host
        if depth >= 3:
            continue
        # From the raw words: an assignment `x=$(curl …)` is stripped as a wrapper above.
        nested = [SUBST.sub(" ; ", w) for w in raw if "$(" in w or "`" in w] + strings
        flag = next((i for i, w in enumerate(words[1:-1], 1) if SHELL_C.match(w)), 0)
        if verb in SHELLS and flag:
            nested.append(words[flag + 1])
        elif verb == "eval":
            # eval joins its arguments into one command: `eval 'gh issue view 1' '--repo h/o/r'`.
            nested.append(" ".join(words[1:]))
        elif verb == "tmux":
            nested.extend(words[1:])
        # A wrapper rewrites a nested string too: `xargs -I o bash -c 'gh … -R o/r'`.
        for inner in nested:
            if (inner, plain) in inners:
                continue
            inners.add((inner, plain))
            try:
                found = verb_in(inner, names, depth + 1, plain)
            except ValueError:
                broken = True
                continue
            if found:
                return found
    if broken:
        raise ValueError("an unparsable part names no egress tool")
    return ""


def unquoted(text):
    """<text> without quotes and backslashes: a name split by quotes at any nesting depth
    (`eval "export GH_''HOST=x"`, `bash -c "… /dev/t''cp/…"`) reads whole again."""
    return re.sub(r"[\"'\\]", "", text)


def net_device(cmd, tokens):
    """A bash /dev/tcp or /dev/udp path in the text or in a token (quotes joined: /dev/t''cp)."""
    return bool(NET_DEV.search(cmd)) or any(NET_DEV.search(w) for w in tokens)


def gh_read_tainted(cmd, tokens=()):
    """True when <cmd> could point a gh read at another host. The whole string, not one command:
    a quoted ';' splits `gh … --template ';' -R host/o/r`. A single-quoted bound formatting value
    of a gh view is data: masked first."""
    masked = format_masked(cmd, egress_in)
    if masked != cmd:
        try:
            cmd, tokens = masked, tokenize(masked)
        except ValueError:
            pass
    return bool(GH_READS_TAINT.search(cmd) or gh_host_selector(list(tokens))
                or GH_READS_TAINT.search(unquoted(cmd))
                or any(GH_READS_TAINT.search(t) for t in tokens))


def bash_reason(cmd, project):
    mark = comment_splits()
    reason = reading_reason(cmd, project)
    if reason or not needs_base_reading(mark):
        return reason
    # The pre-#230 reading must not lose a verdict either (QA: a `git push <remote>` before a line
    # whose uncovered quote breaks or hides the rest).
    with base_comment_reading():
        return reading_reason(cmd, project)


def reading_reason(cmd, project):
    # Raw text first: an unparsable command never reaches verb_in's per-level check.
    if net_device(cmd, [unquoted(cmd)]):
        return NET_FOUND
    decision, why = supervisor_verdict(cmd, project, egress_in)
    if decision != "defer":
        return why
    try:
        found = egress_in(cmd)
    except ValueError:
        try:
            # The taint comes from the raw text: the doc-heredoc strip blanks out backquotes.
            found = egress_in(doc_heredocs_removed(cmd), reads_ok=not gh_read_tainted(cmd))
        except ValueError:
            # Unparsable: an egress tool cannot sit in command position without its name.
            if MENTIONS_EGRESS.search(cmd):
                return "unparsable command mentions an egress tool"
            return ""
    if found == NET_FOUND:
        return found
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
            rules.extend(allow_rules(path))
        except (OSError, ValueError, AttributeError):
            raise Unreadable(name + " unreadable")
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
    project = os.environ.get("CLAUDE_PROJECT_DIR", "")
    try:
        payload = json.load(sys.stdin)
        tool = payload.get("tool_name")
        tool_input = payload.get("tool_input") or {}
        if not isinstance(tool_input, dict):
            raise ValueError
    except (ValueError, AttributeError):
        print(json.dumps(verdict("unreadable hook payload")))
        record_touch(project, None, "unreadable hook payload")
        return
    if tool == "WebFetch":
        reason = webfetch_reason(tool_input.get("url"), project)
    elif tool == "Bash":
        cmd = tool_input.get("command")
        reason = bash_reason(cmd, project) if isinstance(cmd, str) else "unreadable Bash command"
    else:
        return
    if reason:
        print(json.dumps(verdict(reason)))
        record_touch(project, payload.get("cwd"), reason)


if __name__ == "__main__":
    main()
