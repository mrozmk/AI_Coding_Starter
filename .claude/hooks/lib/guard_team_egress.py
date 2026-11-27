"""Logic of guard-team-egress.sh: keep the egress prompt for team roles in auto mode.

#322: every verdict comes from the effect classifier (guard_team_egress_classify: pass / deny /
operator / ask, the same for every role). pass -> no output; deny -> permissionDecision deny (a hard
deny class, a mechanical block: the Supervisor's touch log records it as kind block); operator and
ask -> permissionDecision ask. Never allows. bash_effect / webfetch_effect are the classifier's
entry points for other callers. The reading below (reading_reason_of) is the classifier's pass test: what it lets through is
a pass unless a deny or operator detector fires first.

A best-effort guard over Bash and WebFetch, not an allowlist (MCP tools and WebSearch are out of
scope). WebFetch to a host outside the project's WebFetch(domain:...) allowlist -> ask; a Bash command
whose command-position word is an egress-capable tool (curl wget ssh scp rsync nc ftp sftp gh npm npx
pip pip3 pipx uvx osascript; python/python3 with -c, -, no arguments or -m other than a local test
module, node with -e/-p/--eval/-) -> ask, also inside bash -c, tmux arguments, eval, $(...),
here-doc lines and the strings of flock -c / env -S; a command with a redirection before its verb
is also read from every later word (`</dev/null curl …`), and a brace-expanded verb (`{curl,} …`)
asks. The read-only gh forms (GH_READ_FORMS, #268) pass only as the simple command's own first word (also
in a string nested under no wrapper), with a plain OWNER/REPO repo value, no URL, --hostname, brace
expansion or option-shaped glob, and no $, backtick, #, backslash, GH_HOST or GH_REPO in the text
or its tokens (a quoted ';' does not hide an argument: the whole string is checked). Literal
`NAME=<value>;` heads are written into the rest first (inline_literals). #272: python3 -c code and
quoted-delimiter `python3 -` here-docs are judged by their code (py_code_safe: local-only modules,
no process/network/introspection API) — not egress when it passes, for every role; Python output
piped into a shell or interpreter asks; a `cat` data here-doc's body is not scanned. A /dev/tcp or
/dev/udp path (bash's sockets) -> deny (#322), whatever the verb, at every nesting level. Never emits
allow: no output leaves the decision to Claude Code's own rules, so deny still wins. Unreadable
input -> ask (fail-closed).
A loopback port probe (`nc -z [-v] [-w n] [-G n] localhost|127.0.0.1|::1 <ports>`) is not egress.
git push/fetch/pull/clone/ls-remote/submodule add/remote add|set-url whose repository argument is a
URL or `host:path` -> ask unless the host is in the same WebFetch allowlist; a bare remote name or
a local path passes (the remote's configured URL was itself set through this check or by a human);
#322: git fetch/pull/clone/ls-remote also pass toward a public host (classifier: lexical + address).
A URL set as git config — `git config remote.<n>.url|pushurl <url>`, `git -c remote.<n>.url=<url>`,
`url.<base>.insteadOf` — and `git push --repo[=]<url>` get the same host check.
On the gh pr|issue view read path a single-quoted --jq/--template value that gh's option layout
binds is data, not checked for taint. Every role passes compounds of built-in gh reads, inline
Python py_code_safe accepts, the #322 read forms and allowlisted companions (literal loops
unrolled); only the Supervisor in the main checkout (TEAM_SESSION_ROLE=Supervisor, no
TEAM_RUN_TEAM, neither .agents/team/session.json nor team.json) adds gh commands covered by a
Bash(gh ...) allow rule of settings.local.json (never settings.json) and inline Python under the
local Bash(python3 -) / Bash(python3 -c *) opt-in; gh output piped into a shell or interpreter
asks. Every Supervisor ask or deny is appended to .agents/touches/<yyyy-mm>.jsonl. All of it:
guard_team_egress_supervisor.py.
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
from guard_team_egress_effect import (  # noqa: E402
    GH_READ_FORMS, inline_literals, py_code_safe, python_heredocs_judged)
from guard_team_egress_loops import backstop  # noqa: E402
from guard_team_egress_supervisor import (  # noqa: E402
    BRACE, GH_READS_TAINT, allow_rules, compound_verdict, format_masked, gh_host_selector,
    record_touch)
from guard_team_egress_classify import (  # noqa: E402
    classify_bash, classify_webfetch, git_read_host_ok, git_runs_command)
from guard_team_egress_words import SHELLS, nested_texts  # noqa: E402

EGRESS = {"curl", "wget", "ssh", "scp", "rsync", "nc", "ftp", "sftp",
          "gh", "npm", "npx", "pip", "pip3", "pipx", "uvx", "osascript", "python", "python3",
          "node"}
# Interpreters are egress-capable only with inline code (-c, a module, stdin); a script file is the
# project's own code.
INLINE = {"python": {"-c", "-m", "-"}, "python3": {"-c", "-m", "-"},
          "node": {"-e", "-p", "--eval", "--print", "-"}}
# `python -m <module>` for these runs the project's own tests / stdlib tools, not a network client.
LOCAL_MODULES = {"pytest", "unittest", "doctest", "py_compile", "compileall", "json.tool"}
LOOPBACK = {"localhost", "127.0.0.1", "::1"}
MENTIONS_EGRESS = re.compile(r"\b(" + "|".join(sorted(EGRESS)) + r")\b")
DOMAIN_RULE = re.compile(r"^WebFetch\(domain:([^)]*)\)$")
# bash's socket pseudo-files: a redirection there is egress whatever the verb.
NET_DEV = re.compile(r"/dev/(tcp|udp)\b")
NET_FOUND = "network redirection (/dev/tcp or /dev/udp)"
UNPARSABLE = "unparsable command mentions an egress tool"
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
    the read-only gh forms (GH_READ_FORMS). <reads_ok> False: a gh read is egress too."""
    if verb in INLINE:
        # No arguments at all reads the program from stdin (`python3 <<EOF`).
        if len(words) == 1:
            return True
        for i, w in enumerate(words[1:], 1):
            short = w.startswith("-") and not w.startswith("--") and verb != "node"
            if w == "-m" or (short and w.endswith("m") and "c" not in w[1:]):
                return "".join(words[i + 1:i + 2]) not in LOCAL_MODULES
            if w in INLINE[verb] or (short and "c" in w[1:]):
                # #272: python3 [-I…] -c '<code>' whose code py_code_safe accepts is not egress.
                if verb != "node" and re.fullmatch(r"-[IBEsSu]*c", w) and i + 1 < len(words):
                    return not py_code_safe(words[i + 1])
                return True
        return False
    if verb == "gh":
        return not reads_ok or tuple(words[1:3]) not in GH_READ_FORMS
    return True


def git_sub_index(words):
    """Index of git's subcommand word: past the global options (`-C` and `-c` take a value)."""
    i = 1
    while i < len(words) and words[i].startswith("-"):
        i += 2 if words[i] in ("-C", "-c") else 1
    return i


def git_repo_arg(words):
    """The repository word of a network git command, or None (a bare remote name is returned too)."""
    i = git_sub_index(words)
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


def git_host_ok(host, read=False):
    """<read>: fetch/pull/clone/ls-remote, which also pass toward a public host (#322)."""
    if host in LOOPBACK:
        return True
    project = os.environ.get("CLAUDE_PROJECT_DIR", "")
    try:
        if host_allowed(host, allowlist(project)):
            return True
    except Unreadable:
        return False
    return read and git_read_host_ok(host, project)


def git_sub(words):
    i = git_sub_index(words)
    return "".join(words[i:i + 1])


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
            read = git_sub(words) in ("fetch", "pull", "clone", "ls-remote")
            if read and git_runs_command(words, tokens):
                return "git %s with an option that runs a local command" % git_sub(words)
            cfg = git_config_urls(words)
            # Every URL word too: a value option (`clone --branch main <url>`) can stand before it.
            urls = [w for w in words[1:] if URL_SCHEME.match(w) and w not in cfg]
            for k, arg in enumerate([git_repo_arg(words) or ""] + cfg + urls):
                host = repo_host(arg)
                if host and not git_host_ok(host, read and (k == 0 or k > len(cfg))):
                    return "git to " + host
        if depth >= 3:
            continue
        # A wrapper rewrites a nested string too: `xargs -I o bash -c 'gh … -R o/r'`.
        for inner in nested_texts(raw, words, strings, verb):
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


def bash_effect(cmd, project, cwd=None):
    """(kind, reason) of a Bash command — the classifier (#322)."""
    return classify_bash(cmd, project, cwd)


def webfetch_effect(url, project):
    return classify_webfetch(url, project)


def reading_reason_of(cmd, project):
    """The reading's reason ('' = no egress the reading cannot pass): the classifier's pass test."""
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
    # #272: a safe Python here-doc is `true <args>`, a `cat` data here-doc loses its body; then the
    # literal heads (inline_literals keeps a command with any other here-doc as it is).
    cmd = inline_literals(python_heredocs_judged(cmd))
    decision, why = compound_verdict(cmd, project, egress_in)
    if decision != "defer":
        return why
    # Python judged safe above still never feeds a shell or interpreter through a pipe.
    piped, why = backstop(cmd, ("python3", "python"), "")
    if piped == "ask":
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
                return UNPARSABLE
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


def deny_verdict(reason):
    return {"hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": "deny",
        "permissionDecisionReason": "team egress: " + reason + " — denied"}}


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
    cwd = payload.get("cwd") if isinstance(payload.get("cwd"), str) else None
    if tool == "WebFetch":
        kind, reason = webfetch_effect(tool_input.get("url"), project)
    elif tool == "Bash":
        cmd = tool_input.get("command")
        kind, reason = (bash_effect(cmd, project, cwd) if isinstance(cmd, str)
                        else ("ask", "unreadable Bash command"))
    else:
        return
    if kind == "deny":
        print(json.dumps(deny_verdict(reason)))
        record_touch(project, cwd, reason, payload, kind="block", why="hook")
    elif kind != "pass":
        print(json.dumps(verdict(reason)))
        record_touch(project, cwd, reason, payload)


if __name__ == "__main__":
    main()
