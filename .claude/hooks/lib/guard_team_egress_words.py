"""#322 word readers of the effect classifier (guard_team_egress_classify.py): every simple command
of a text at every nesting level (units), the texts its literal loops unroll to, curl's option
classes, positional words, and the write targets one command names (redirections, tee/cp/mv/
install/ln, sed -i, dd of=, curl -o, literal inline-Python writes). Pure readers: no verdict here.
"""
import os
import re
import sys
# Local imports below: never write __pycache__ into the project (callers run python3 -I, not -B).
sys.dont_write_bytecode = True

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)  # python3 -I drops the script dir from sys.path

from guard_destructive_sql import (  # noqa: E402
    SHELL_C, commands, strip_wrappers, tokenize, unredirected)
from guard_team_egress_loops import for_bodies, scan  # noqa: E402

SUB_WORD = "__SUB__"
# curl short options that take a value; the class each one carries.
CURL_VALUE = set("XdFuUHKEToberwxyzYCcDmPtQAe")
CURL_CLASS = {"X": "method", "d": "body", "F": "body", "u": "creds", "U": "creds", "K": "creds",
              "E": "creds", "b": "creds", "n": "creds", "H": "header", "o": "output", "T": "upload"}
CURL_LONG = {"--request": "method", "--data": "body", "--data-raw": "body", "--data-binary": "body",
             "--data-ascii": "body", "--data-urlencode": "body", "--json": "body", "--form": "body",
             "--form-string": "body", "--user": "creds", "--proxy-user": "creds", "--netrc": "creds",
             "--netrc-file": "creds", "--netrc-optional": "creds", "--config": "creds",
             "--cert": "creds", "--key": "creds", "--oauth2-bearer": "creds", "--cookie": "creds",
             "--header": "header", "--output": "output", "--upload-file": "upload"}
CURL_NOVALUE_LONG = {"--netrc", "--netrc-optional"}
REDIR_OP = re.compile(r"^(?:[0-9]+|\{\w+\})?(?:&>>?|>>?|>\|)$")
REDIR_GLUED = re.compile(r"(?:^|(?<=[^\\>]))(?:[0-9]+)?(?:>>?|>\|)([^>&|\s][^>\s]*)$")
# The only unquoted word characters the reader accepts (ASCII; no glob, `~`, `$`, `\`, `#` …).
LOOP_WORD = re.compile(r"[A-Za-z0-9_./:,=+@%-]+")


def sub_masked(text):
    """(<text> with each outermost `$(…)` replaced by one opaque word, the bodies): an option a
    substitution builds stays inside its command (`curl $(printf -- -d) @f …`)."""
    got = scan(text)
    if not got or not got[1]:
        return text, []
    bodies = [text[s + 2:e] for s, e in got[1]]
    for s, e in reversed(got[1]):
        text = text[:s] + SUB_WORD + text[e + 1:]
    return text, bodies


HEREDOC_OPEN = re.compile(r"<<-?[ \t]*(['\"]?)([A-Za-z0-9_]+)\1")
SHELL_READERS = {"bash", "sh", "zsh", "dash", "ksh", "eval", "source", ".", "xargs"}


def data_heredocs_removed(text):
    """<text> without the bodies of the here-documents a shell does not run (`cat > f <<EOF`,
    `python3 - <<EOF`: data or another reader's program — python writes are read apart); a body fed
    to a shell or `eval` stays, its lines are commands."""
    lines, out, i = text.split("\n"), [], 0
    while i < len(lines):
        line, i = lines[i], i + 1
        out.append(line)
        m = HEREDOC_OPEN.search(line)
        if not m:
            continue
        head = re.split(r"[;&|(]", line[:m.start()])[-1].split()
        verb = os.path.basename(head[0]) if head else ""
        end = next((j for j in range(i, len(lines)) if lines[j].strip() == m.group(2)), None)
        if end is None or verb in SHELL_READERS:
            continue
        out.append(lines[end])
        i = end + 1
    return "\n".join(out)


def units(cmd, depth=0):
    """(raw tokens, words) of every simple command of <cmd> at every nesting level: the commands,
    their unredirected readings, bash/sh -c strings, eval, tmux arguments, `$(…)` / backquote
    bodies and the strings of flock -c / env -S. Unparsable text yields what parsed. A data
    here-doc's body is no command (data_heredocs_removed)."""
    import guard_team_egress as g
    text, bodies = sub_masked(data_heredocs_removed(cmd))
    try:
        tokens = tokenize(text)
    except ValueError:
        try:
            tokens, bodies = tokenize(data_heredocs_removed(cmd)), []
        except ValueError:
            return []
    out, seen = [], set()
    if depth < 3:
        for body in bodies:
            out.extend(units(body, depth + 1))
    for raw in list(commands(tokens)) + unredirected(tokens, True):
        if tuple(raw) in seen:
            continue
        seen.add(tuple(raw))
        strings = []
        try:
            words = strip_wrappers(raw, strings)
        except ValueError:
            words = []
        out.append((raw, words))
        if depth >= 3:
            continue
        nested = [g.SUBST.sub(" ; ", w) for w in raw if "$(" in w or "`" in w] + strings
        verb = os.path.basename(words[0]) if words else ""
        flag = next((i for i, w in enumerate(words[1:-1], 1) if SHELL_C.match(w)), 0)
        if verb in g.SHELLS and flag:
            nested.append(words[flag + 1])
        elif verb == "eval":
            nested.append(" ".join(words[1:]))
        elif verb == "tmux":
            nested.extend(words[1:])
        for inner in nested:
            out.extend(units(inner, depth + 1))
    return out


def texts_of(cmd):
    """<cmd> and every text its literal loops unroll to (bounded)."""
    out, todo = [], [cmd]
    while todo and len(out) < 64:
        t = todo.pop(0)
        out.append(t)
        try:
            more = for_bodies(t, LOOP_WORD)
        except Exception:
            more = None
        todo.extend(more or [])
    return out


def positional(args, value_opts=()):
    pos, i = [], 0
    while i < len(args):
        a = args[i]
        if a == "--":
            pos.extend(args[i + 1:])
            break
        if a.startswith("-") and a != "-":
            i += 2 if a in value_opts else 1
            continue
        pos.append(a)
        i += 1
    return pos


def curl_options(args):
    """(class, value) per curl option of <args>, clusters and glued values included; URL words are
    ("url", word)."""
    out, i = [], 0
    while i < len(args):
        a = args[i]
        if a.startswith("--"):
            name, eq, val = a.partition("=")
            cls = CURL_LONG.get(name)
            if cls and not eq and name not in CURL_NOVALUE_LONG:
                val, i = "".join(args[i + 1:i + 2]), i + 1
            out.append((cls or "long", val if cls else a))
        elif a.startswith("-") and len(a) > 1:
            for k, c in enumerate(a[1:], 1):
                if c in CURL_VALUE:
                    val = a[k + 1:]
                    if not val:
                        val, i = "".join(args[i + 1:i + 2]), i + 1
                    out.append((CURL_CLASS.get(c, "value"), val))
                    break
                out.append((CURL_CLASS.get(c, "flag"), c))
        else:
            out.append(("url", a))
        i += 1
    return out


def redirect_targets(raw):
    out, i = [], 0
    while i < len(raw):
        t = raw[i]
        if REDIR_OP.match(t):
            j = i + 1
            if j < len(raw) and raw[j] == "|":
                j += 1
            if j < len(raw) and raw[j] not in ("&", "|", ";") and not raw[j].startswith("&"):
                out.append(raw[j])
            i = j + 1
            continue
        m = REDIR_GLUED.search(t) if ">" in t else None
        if m and not t.startswith(("<", "&")):
            out.append(m.group(1))
        elif t.startswith("&>") and len(t) > 2:
            out.append(t[2:].lstrip(">"))
        i += 1
    return out


def word_targets(words):
    """Write targets of one simple command's words (after its wrappers)."""
    if not words:
        return []
    verb, args = os.path.basename(words[0]), words[1:]
    if verb == "tee":
        return positional(args)
    if verb in ("cp", "mv", "install", "ln"):
        out = []
        for i, a in enumerate(args):
            if a in ("-t", "--target-directory") and i + 1 < len(args):
                out.append(args[i + 1])
            elif a.startswith("--target-directory="):
                out.append(a.split("=", 1)[1])
        pos = positional(args, ("-t", "-S", "--suffix", "-m", "--mode", "-o", "-g", "--owner", "--group"))
        return out + pos[-1:] if len(pos) >= 2 or out else out
    if verb in ("sed", "gsed") and any(re.match(r"^-[A-Za-z]*i|^--in-place", a) for a in args):
        # The first operand is the script only when no -e/-f (or --expression/--file) gave one.
        script = any(a in ("-e", "-f") or re.match(r"^(-[ef].|--expression|--file)", a) for a in args)
        pos = positional([a for a in args if a != "''"], ("-e", "-f", "--expression", "--file"))
        return pos if script else pos[1:]
    if verb in ("perl", "ruby") and any(re.match(r"^-[A-Za-z]*i", a) for a in args):
        # In-place edit: every operand after the code (`-e CODE`, or the script when there is none).
        files, code, skip = [], False, False
        for a in args:
            if skip:
                skip, code = False, True
            elif re.match(r"^-[A-Za-z]*[eE]$", a):
                skip = True
            elif not a.startswith("-"):
                files.append(a)
        return files if code else files[1:]
    if verb == "dd":
        return [a[3:] for a in args if a.startswith("of=")]
    if verb == "curl":
        return [v for c, v in curl_options(args) if c == "output" and v]
    return []


def py_write_targets(code, argv):
    """Literal write targets of inline Python code: open(<t>, 'w'|'a'|'x'|'+'), Path(<t>).write_*,
    shutil.copy*/move(_, <t>); <t> a str literal, sys.argv[k] (from <argv>) or a name bound to one."""
    import ast
    try:
        tree = ast.parse(code)
    except (SyntaxError, ValueError):
        return []
    names = {}

    def value(node):
        if isinstance(node, ast.Constant) and isinstance(node.value, str):
            return node.value
        if (isinstance(node, ast.Subscript) and isinstance(node.value, ast.Attribute)
                and node.value.attr == "argv" and isinstance(node.slice, ast.Constant)
                and isinstance(node.slice.value, int) and 0 < node.slice.value < len(argv) + 1):
            return argv[node.slice.value - 1]
        if isinstance(node, ast.Name):
            return names.get(node.id)
        return None
    for node in ast.walk(tree):
        if isinstance(node, ast.Assign) and len(node.targets) == 1 and isinstance(node.targets[0], ast.Name):
            v = value(node.value)
            if v is not None:
                names[node.targets[0].id] = v
    out = []
    for node in ast.walk(tree):
        if not isinstance(node, ast.Call):
            continue
        f = node.func
        fname = f.id if isinstance(f, ast.Name) else f.attr if isinstance(f, ast.Attribute) else ""
        if fname == "open" and node.args:
            mode = node.args[1] if len(node.args) > 1 else next(
                (k.value for k in node.keywords if k.arg == "mode"), None)
            m = mode.value if isinstance(mode, ast.Constant) and isinstance(mode.value, str) else ""
            if re.search(r"[wax+]", m):
                out.append(value(node.args[0]))
        elif fname in ("write_text", "write_bytes") and isinstance(f, ast.Attribute):
            inner = f.value
            if isinstance(inner, ast.Call) and inner.args:
                out.append(value(inner.args[0]))
        elif fname in ("copy", "copy2", "copyfile", "move", "copytree") and len(node.args) > 1:
            out.append(value(node.args[1]))
    return [t for t in out if isinstance(t, str) and t]
