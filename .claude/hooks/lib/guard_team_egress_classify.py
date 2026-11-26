"""#322: the one effect classifier of the team egress guard, its stage tier and (#323) the role hook.

classify_bash(cmd, project, cwd) / classify_webfetch(url, project) -> (kind, reason), kind one of
  pass      no egress effect, or a read the rules below pass mechanically;
  deny      a hard deny class (a request body or upload from a file or stdin, /dev/tcp|udp, a token
            in a URL, a download piped into a shell or interpreter, a write into
            .claude/settings*.json or a role profile, a stage's write into .claude/hooks outside its
            clone and its run's starter worktree) — never cleared by anyone; each detector judges
            the executed effect, never a mention of its shape (round 2);
  operator  a hard Operator-only class (a method other than GET/HEAD or a literal body, explicit
            credentials, GH_HOST/GH_REPO/--hostname, a gh write to another repo, a git push whose
            destination is not the verified origin, a private host, an unpinned install, a Bash
            write into .claude/hooks of an armed guard, an unparsable command naming an egress tool);
  ask       egress-capable and in neither list.
Order: deny > operator > pass > ask. Never allows: the caller maps pass to no output. No session
branch in a rule: the Supervisor's local grants (guard_team_egress_supervisor) and its touch log are
the only Supervisor-scoped parts; the hooks rule reads the session kind only to locate the armed
guard. Public host = a lexical rule plus a guard-time address check through RESOLVER (tests and the
replay swap it for an offline stub). Every detector raises on a bug: the callers fail closed.
Parts: guard_team_egress_words.py (readers), guard_team_egress_hard.py (write and operator classes).
Contract: .agents/reference/security-egress.md.
"""
import ipaddress
import os
import re
import socket
import sys
import threading
# Local imports below: never write __pycache__ into the project (callers run python3 -I, not -B).
sys.dont_write_bytecode = True
from urllib.parse import urlsplit

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)  # python3 -I drops the script dir from sys.path

from guard_destructive_sql import SEPARATORS, SHELL_C, commands, strip_wrappers, tokenize  # noqa: E402
from guard_team_egress_loops import (  # noqa: E402
    INTERP, MODIFIERS, SHELLS_I, backstop, first_word, scan, stdin_executor)
from guard_team_egress_words import (  # noqa: E402
    curl_options, data_heredocs_removed, plain_output, positional, texts_of, units)
from guard_team_egress_hard import (  # noqa: E402
    EGRESS_VERBS, URL_WORD, operator_reason, worst, write_class)

RESOLVER = socket.getaddrinfo
DNS_TIMEOUT = 2.0
URL_MAX = 160
RESERVED_TLDS = {"localhost", "local", "localdomain", "internal", "intranet", "lan", "home", "corp",
                 "private", "test", "example", "invalid", "onion", "arpa"}
CGNAT = ipaddress.ip_network("100.64.0.0/10")
# The high-confidence formats of leak-patterns.sh (LEAK_HIGH_RE), a credential key with a value in a
# URL's path or query, and a bearer token.
TOKEN = re.compile(
    r"-----BEGIN[A-Z ]*PRIVATE KEY-----|AKIA[0-9A-Z]{16}|ASIA[0-9A-Z]{16}|gh[pousr]_[0-9A-Za-z]{36}"
    r"|github_pat_[0-9A-Za-z_]{82}|xox[baprs]-[0-9A-Za-z-]{10,}|xapp-[0-9A-Za-z-]{10,}"
    r"|glpat-[0-9A-Za-z_-]{20}|AIza[0-9A-Za-z_-]{35}|sk-ant-[0-9A-Za-z_-]{20,}|sk-proj-[0-9A-Za-z_-]{20,}"
    r"|(?:sk|rk)_live_[0-9A-Za-z]{20,}|shp(?:at|ss)_[0-9a-fA-F]{32}|SG\.[0-9A-Za-z_-]{22}\.[0-9A-Za-z_-]{43}"
    r"|ATATT[0-9A-Za-z_=.-]{20,}|npm_[0-9A-Za-z]{36}"
    r"|eyJ[0-9A-Za-z_-]{8,}\.eyJ[0-9A-Za-z_-]{8,}\.[0-9A-Za-z_-]{8,}|SK[0-9a-f]{32}"
    r"|(?:postgres(?:ql)?|mysql|mongodb(?:\+srv)?|redis|amqps?|ftp)://[^:@/\s]+:[^@/\s]+@"
    r"|(?i:(?:^|[/?&;=])(?:token|access_token|api_key|apikey|key|sig|password|secret)=[^&/\s]+)"
    r"|(?i:\bBearer\s+\S)")
DOWNLOADERS = ("curl", "wget")
EXEC_VERBS = SHELLS_I | INTERP | {"source", ".", "eval"}
# An interpreter option whose value is program text: python -c, node -e/-p/--eval, perl -e/-E,
# ruby -e, php -r, lua -e (a cluster such as perl's -ne too).
CODE_OPT = re.compile(r"^-[A-Za-z]*[ceEpr]$|^--(?:eval|print)$")
# A redirection operator, alone or glued to its target (`>`, `2>>`, `<`, `<>`, `&>`, `3<>`); `<<`
# and `<<<` feed text, they open nothing.
REDIR_ONLY = re.compile(r"(?:[0-9]+|\{\w+\}|&)?(?:<>|<|>>|>\||>)")
REDIR_HEAD = re.compile(r"^(?:[0-9]+|\{\w+\}|&)?(?:<>|>>|>\||>|<(?!<))")
# Option values that are data, not a destination: wget's and the common message/body/pattern ones.
WGET_VALUE = ("-O", "-o", "-a", "-P", "-U", "-e", "-i", "-B", "-t", "-T", "-w", "-Q", "-l", "-A",
              "-R", "-D", "-I", "-X", "--header", "--user-agent", "--referer")
DATA_VALUE = ("-m", "--message", "-b", "--body", "-t", "--title", "-F", "-f", "--field",
              "--raw-field", "-H", "--header", "-q", "--jq", "--template", "-d", "--data", "-X",
              "--method", "-l", "--label", "-e", "--search", "-S")
REGISTRY_OPTS = re.compile(r"^(?:--registry|-i|--index-url|--extra-index-url|--proxy|--https-proxy"
                           r"|--trusted-host|--userconfig|--globalconfig|--index|-c|--config)(?:=|$)")


# --- hosts ---------------------------------------------------------------------------------------

def ip_literal(host):
    """True for an IP literal in any spelling a resolver accepts (dotted, decimal, hex, octal, v6)."""
    h = host.strip("[]")
    try:
        ipaddress.ip_address(h)
        return True
    except ValueError:
        pass
    labels = h.split(".")
    return all(re.fullmatch(r"0[xX][0-9a-fA-F]*|[0-9]+", lab) for lab in labels if lab) and any(labels)


def ip_private(addr):
    a = ipaddress.ip_address(addr)
    if isinstance(a, ipaddress.IPv6Address) and a.ipv4_mapped:
        a = a.ipv4_mapped
    return (not a.is_global or a.is_multicast or a.is_private or a.is_loopback or a.is_link_local
            or a.is_reserved or a.is_unspecified or (a.version == 4 and a in CGNAT))


def public_name(host):
    """Lexical public host: >= 2 labels of [a-z0-9-], an alphabetic TLD not reserved, no IP literal."""
    h = (host or "").rstrip(".").lower()
    labels = h.split(".")
    return (len(labels) >= 2 and not ip_literal(h) and all(re.fullmatch(r"[a-z0-9-]+", lab) for lab in labels)
            and re.fullmatch(r"[a-z]{2,63}", labels[-1]) is not None and labels[-1] not in RESERVED_TLDS)


def private_host(host):
    """The Operator class: a private/loopback/link-local/CGNAT/ULA/reserved IP literal, a reserved
    TLD, a single label or localhost."""
    h = (host or "").rstrip(".").lower().strip("[]")
    if not h:
        return False
    if ip_literal(h):
        try:
            return ip_private(h)
        except ValueError:
            return True  # a decimal/hex/octal spelling: never public
    labels = h.split(".")
    return len(labels) < 2 or labels[-1] in RESERVED_TLDS or h == "localhost"


def public_addresses(host):
    """Every address RESOLVER returns for <host> is public; a lookup that fails, stalls past
    DNS_TIMEOUT or answers nothing is False. getaddrinfo ignores socket timeouts: a daemon thread."""
    box = {}

    def look():
        try:
            box["r"] = RESOLVER(host, 443, proto=socket.IPPROTO_TCP)
        except Exception as e:  # a failed lookup is no pass, never a crash
            box["e"] = e
    t = threading.Thread(target=look, daemon=True)
    t.start()
    t.join(DNS_TIMEOUT)
    if t.is_alive() or "r" not in box or not box["r"]:
        return False
    try:
        return all(not ip_private(str(info[4][0]).split("%")[0]) for info in box["r"])
    except (ValueError, IndexError, TypeError):
        return False


def public_host(host, project):
    """Allowlisted, or lexically public and resolving only to public addresses."""
    import guard_team_egress as g
    h = (host or "").rstrip(".").lower()
    try:
        if g.host_allowed(h, g.allowlist(project)):
            return True
    except g.Unreadable:
        return False
    return public_name(h) and public_addresses(h)


def public_get(url, project):
    """A GET the guard passes: https, no userinfo, no backslash, no query, <= URL_MAX characters, no
    token, the host allowlisted or public."""
    if not isinstance(url, str) or len(url) > URL_MAX or "\\" in url or "?" in url or TOKEN.search(url):
        return False
    try:
        parts = urlsplit(url)
        host = parts.hostname or ""
    except ValueError:
        return False
    return (parts.scheme.lower() == "https" and "@" not in parts.netloc and bool(host)
            and not private_host(host) and public_host(host, project))


def git_read_host_ok(host, project):
    return public_host(host, project) and not private_host(host)


# Config keys that make a git read run a local command, load more config or move its traffic.
GIT_RUN_KEY = re.compile(r"(?i)^(?:core\.(?:sshcommand|gitproxy|askpass|fsmonitor|hookspath)"
                         r"|uploadpack\.packobjectshook|credential\..*helper|remote\..+\.(?:uploadpack|proxy)"
                         r"|url\..+\.insteadof|http\..*proxy|include\.path|includeif\..+\.path"
                         r"|protocol\..+\.allow)$")
GIT_RUN_ENV = re.compile(r"^(?:GIT_SSH_COMMAND|GIT_SSH|GIT_PROXY_COMMAND|GIT_EXEC_PATH|GIT_ASKPASS"
                         r"|SSH_ASKPASS|GIT_CONFIG_PARAMETERS|GIT_CONFIG_GLOBAL|GIT_CONFIG_SYSTEM|GIT_CONFIG)=")
GIT_RUN_OPTS = ("--upload-pack", "--exec", "--template")


def git_runs_command(words, tokens):
    """True when a git read (`fetch|pull|clone|ls-remote`) would run a local command chosen on the
    command line: a command-running `-c`/`--config` key, `--exec-path=`, `--upload-pack`/`--exec`/
    `--template`, clone's `-u`, or an env assignment anywhere in the text (`GIT_SSH_COMMAND=…`, a
    config file `GIT_CONFIG_GLOBAL=…`, `GIT_CONFIG_KEY_<n>=<such key>`). The host check never sees
    that command."""
    if any(GIT_RUN_ENV.match(t) or (re.match(r"^GIT_CONFIG_KEY_[0-9]+=", t)
                                    and GIT_RUN_KEY.match(t.split("=", 1)[1])) for t in tokens):
        return True
    i, sub = 1, None
    while i < len(words):
        w, config = words[i], sub in (None, "clone")
        if w.startswith("--config-env") or (sub is None and w.startswith("--exec-path=")):
            return True
        if config and w in ("-c", "--config") and i + 1 < len(words):
            if GIT_RUN_KEY.match(words[i + 1].split("=", 1)[0]):
                return True
            i += 1
        elif config and w.startswith("--config="):
            if GIT_RUN_KEY.match(w[len("--config="):].split("=", 1)[0]):
                return True
        elif sub is None and w == "-C":
            i += 1
        elif sub is None and not w.startswith("-"):
            sub = w
        elif sub is not None and (w.startswith(GIT_RUN_OPTS) or (sub == "clone" and w == "-u")):
            return True
        i += 1
    return False


# --- WebFetch -----------------------------------------------------------------------------------

def classify_webfetch(url, project):
    import guard_team_egress as g
    try:
        host = (urlsplit(url).hostname or "").rstrip(".") if isinstance(url, str) else ""
    except ValueError:
        host = ""
    if not host:
        return "ask", "unparsable WebFetch URL"
    if TOKEN.search(url):
        return "deny", "token in the WebFetch URL (" + host + ")"
    if "@" in urlsplit(url).netloc:
        return "operator", "ambiguous WebFetch URL (" + host + ")"
    # WHATWG (WebFetch) reads `\` as `/` and urlsplit does not: `https://evil\@allowed/` differs.
    if "\\" in url:
        return "ask", "ambiguous WebFetch URL (" + host + ")"
    try:
        domains = g.allowlist(project)
    except g.Unreadable as e:
        return ("operator" if private_host(host) else "ask"), host + " not checked (" + str(e) + ")"
    listed = g.host_allowed(host.lower(), domains)
    # Before the allowlist: an allowlisted private name is still Operator-only. Today's reason
    # text where the verdict does not change.
    if private_host(host):
        return "operator", (host + " is a private host" if listed else host + " not in WebFetch allowlist")
    if listed or public_get(url, project):
        return "pass", ""
    return "ask", host + " not in WebFetch allowlist"


# --- deny ---------------------------------------------------------------------------------------

def body_file(verb, args):
    """A request body or upload from a file or stdin, judged on one command's words."""
    if verb == "curl":
        # --data-raw / --form-string values are literal text, never a file (the operator tier's).
        literal = [args[k + 1] for k, a in enumerate(args[:-1]) if a in ("--data-raw", "--form-string")]
        for cls, val in curl_options(args):
            if cls == "body" and val in literal:
                literal.remove(val)
                continue
            if cls == "upload" or (cls in ("body", "url") and (val.startswith("@") or "=@" in val
                                                               or "=<" in val)):
                return True
        # --data-urlencode also reads a file as `name@file` (no `=` before the `@`).
        for k, a in enumerate(args):
            val = a[len("--data-urlencode="):] if a.startswith("--data-urlencode=") else \
                args[k + 1] if a == "--data-urlencode" and k + 1 < len(args) else None
            if val is not None and re.match(r"^[^=]*@", val):
                return True
    if verb == "wget":
        return any(a.startswith(("--post-file", "--body-file")) for a in args)
    if verb == "gh" and args[:1] == ["api"]:
        return any(a == "--input" or a.startswith("--input=") or "=@" in a for a in args[1:])
    return False


def destinations(verb, args):
    """The words an egress command contacts (#322 round 2): curl's URL operands, wget's and every
    other verb's positional words — never the value of a body, header, message or pattern option."""
    if verb == "curl":
        return [v for c, v in curl_options(args) if c == "url"]
    return positional(args, WGET_VALUE if verb == "wget" else DATA_VALUE)


def runs_input(vals):
    """True when this pipe consumer executes what it reads (stdin_executor), seen through a wrapper
    it can be read through (`command grep` reads data). xargs, and a wrapper that cannot be read,
    stay executors."""
    head = os.path.basename(vals[0]) if vals else ""
    if head in ("noglob", "nocorrect", "builtin"):
        return runs_input(vals[1:]) if len(vals) > 1 else True
    if head not in MODIFIERS:
        return stdin_executor(vals)
    try:
        inner = strip_wrappers(list(vals))
    except ValueError:
        return True
    if not inner or inner == list(vals) or os.path.basename(inner[0]) == "xargs":
        return True
    return runs_input(inner)


def verb_of(raw):
    """The basename of the command a wrapper chain runs, '' when unreadable (a wrapper `sudo …`
    whose string does not parse runs nothing this reader can name)."""
    try:
        words = strip_wrappers(list(raw))
    except ValueError:
        return ""
    return os.path.basename(words[0]) if words else ""


def fetches(text):
    """True when <text> runs curl or wget in command position."""
    return any(w[:1] and os.path.basename(w[0]) in DOWNLOADERS for _, w in units(text))


def code_words(words):
    """The program text a shell or interpreter command runs from its own words: a shell's -c
    string, an interpreter's -c/-e/-r/--eval value, eval's words."""
    verb = os.path.basename(words[0]) if words else ""
    if verb == "eval":
        return [" ".join(words[1:])]
    if verb not in SHELLS_I and verb not in INTERP:
        return []
    opt = SHELL_C if verb in SHELLS_I else CODE_OPT
    return [words[k + 1] for k in range(1, len(words) - 1) if opt.match(words[k])]


def download_run(text, depth=0):
    """The deny reason when downloaded content is executed (#322 round 2), or '': curl/wget output
    piped (through any data filter, the downloader read through its wrappers: `timeout 9 curl`)
    into a consumer that runs its input (runs_input), a process
    substitution `<(curl …)` read by a shell, interpreter or source, and `-c`/`-e`/eval code built
    by `$(curl …)` — at every nesting level a shell executes. A consumer that reads the download as
    data (jq, grep, sed, tar, `python3 -c '<own code>'`) is no such effect."""
    plain = data_heredocs_removed(text)
    piped, why = backstop(plain, DOWNLOADERS, "", runs_input,
                          lambda vals: verb_of(vals) if verb_of(vals) in DOWNLOADERS else first_word(vals))
    if piped == "ask":
        return "downloaded content piped into a shell or interpreter (" + why + ")"
    try:
        tokens = tokenize(plain)
    except ValueError:
        return ""
    for i, t in enumerate(tokens):
        if t != "<(":
            continue
        k = i
        while k > 0 and not set(tokens[k - 1]) <= SEPARATORS:
            k -= 1
        try:
            head = strip_wrappers([w for w in tokens[k:i] if w != "<"])
        except ValueError:
            head = tokens[k:i]
        depth_in, j = 1, i + 1
        while j < len(tokens) and depth_in:
            depth_in += tokens[j].endswith("(") - (tokens[j] == ")")
            j += 1
        if head and os.path.basename(head[0]) in EXEC_VERBS and any(
                verb_of(c) in DOWNLOADERS for c in commands(tokens[i + 1:j - 1])):
            return "downloaded content run by " + os.path.basename(head[0]) + " (process substitution)"
    if depth >= 3:
        return ""
    for raw in commands(tokens):
        try:
            words = strip_wrappers(raw)
        except ValueError:
            continue
        for code in code_words(words):
            got = scan(code)
            bodies = [code[s + 2:e] for s, e in got[1]] if got else []
            bodies += re.findall(r"(?<!\\)`([^`]*)`", code)
            if any(fetches(b) for b in bodies):
                return "downloaded content run by " + os.path.basename(words[0])
            why = download_run(code, depth + 1)
            if why:
                return why
    got = scan(plain)
    for s, e in (got[1] if got else []):
        why = download_run(plain[s + 2:e], depth + 1)
        if why:
            return why
    return ""


def net_opened(text):
    """True when a shell opens /dev/tcp or /dev/udp (#322 round 2): a redirection target, or the
    operand of exec / source / . / a shell, in any command at any nesting level (units). A mention
    in a quoted argument, a pattern, a message or a data here-doc body is no such effect."""
    import guard_team_egress as g
    for raw, words in units(text):
        for k, t in enumerate(raw):
            m = REDIR_HEAD.match(t)
            if (m and m.end() and g.NET_DEV.match(t[m.end():])) or (
                    k and REDIR_ONLY.fullmatch(raw[k - 1]) and g.NET_DEV.match(t)):
                return True
        verb = os.path.basename(words[0]) if words else ""
        if (verb in ("exec", "source", ".") or verb in SHELLS_I) and any(
                g.NET_DEV.match(w) for w in words[1:]):
            return True
    return False


def deny_units(text):
    """The deny reason of one text's commands (command positions only: a quoted mention of a tool
    in an argument is data), or ''."""
    for raw, words in units(text):
        if not words:
            continue
        verb, args = os.path.basename(words[0]), words[1:]
        if body_file(verb, args):
            return verb + (" api" if verb == "gh" else "") + " request body or upload from a file or stdin"
        if verb in EGRESS_VERBS and any(TOKEN.search(m.group(0)) for w in destinations(verb, args)
                                        for m in URL_WORD.finditer(w)):
            return "token in a URL"
    return download_run(text)


def deny_text(text):
    import guard_team_egress as g
    if net_opened(text):
        return g.NET_FOUND
    return deny_units(text)


# --- pass forms (segments of the compound reader) ------------------------------------------------

def curl_config_present():
    """curl reads these unless -q comes first (man curl): a config may add any option."""
    home, env = os.environ.get("HOME", ""), os.environ.get
    paths = [os.path.join(env("CURL_HOME"), ".curlrc") if env("CURL_HOME") else "",
             os.path.join(env("XDG_CONFIG_HOME"), "curlrc") if env("XDG_CONFIG_HOME") else "",
             os.path.join(home, ".curlrc") if home else "", os.path.join(home, ".config", "curlrc") if home else ""]
    return any(p and os.path.exists(p) for p in paths)


def curl_get_ok(vals, project):
    """`curl` with only -s/-S/-f clusters, at most one `-o <plain_output>`, exactly one URL passing
    public_get, and no curl config file read implicitly."""
    urls, outs, i = [], 0, 1
    while i < len(vals):
        a = vals[i]
        if re.fullmatch(r"-[sSf]+", a):
            i += 1
        elif a == "-o" and i + 1 < len(vals) and plain_output(vals[i + 1]):
            outs, i = outs + 1, i + 2
        elif a.startswith("-"):
            return False
        else:
            urls.append(a)
            i += 1
    return (len(urls) == 1 and outs <= 1 and public_get(urls[0], project) and not curl_config_present())


def net_read(vals, project):
    """True for a new mechanical read form (#322): npm view|ls, pip list|show, the curl public GET.
    git fetch|pull|clone|ls-remote are judged in verb_in (public hosts pass there)."""
    if not vals:
        return False
    verb, args = vals[0], vals[1:]
    if verb == "npm" and args[:1] and args[0] in ("view", "ls"):
        return not any(REGISTRY_OPTS.match(a) for a in args)
    if verb in ("pip", "pip3") and args[:1] and args[0] in ("list", "show"):
        return not any(REGISTRY_OPTS.match(a) for a in args)
    if verb == "curl":
        return curl_get_ok(vals, project)
    return False


# --- the classifier -----------------------------------------------------------------------------

def classify_bash(cmd, project, cwd=None):
    import guard_team_egress as g
    if not isinstance(cmd, str):
        return "ask", "unreadable Bash command"
    texts = texts_of(cmd)
    for text in texts:
        why = deny_text(text)
        if why:
            return "deny", why
    wrote = worst([w for w in (write_class(t, project, cwd) for t in texts) if w])
    if wrote and wrote[0] == "deny":
        return wrote
    base = g.reading_reason_of(cmd, project)
    op = operator_reason(cmd, project, cwd)
    # Today's reason where the verdict (ask) does not change; the class decides the kind.
    if op or (wrote and wrote[0] == "operator"):
        return "operator", base or op or wrote[1]
    if base == g.UNPARSABLE:
        return "operator", base
    if base:
        return "ask", base
    if wrote:
        return wrote
    return "pass", ""
