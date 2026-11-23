"""#268 helpers of the egress guard — judged by effect, not by shape: the read-only gh forms (and a
GET `gh api`), the isolating python3 flags, and the literal `NAME=<value>;` heads written into the
rest of a command; #272: inline Python judged by its code (py_code_safe, python_heredocs_judged) and
a `gh api graphql` query. Pure functions; every caller stays fail-closed."""
import ast
import re

# The read-only gh forms (#268): they only read from GitHub under the user's own login, so outside
# a host selector they are not egress — judged by effect, also without a local Bash(gh …) rule.
GH_READ_FORMS = (("pr", "view"), ("pr", "list"), ("pr", "status"), ("pr", "diff"), ("pr", "checks"),
                 ("issue", "view"), ("issue", "list"), ("issue", "status"), ("repo", "view"),
                 ("run", "list"), ("run", "view"), ("release", "view"), ("release", "list"),
                 ("label", "list"), ("project", "view"), ("project", "list"),
                 ("project", "item-list"), ("project", "field-list"), ("search", "issues"),
                 ("search", "prs"), ("search", "repos"), ("search", "code"), ("search", "commits"))
# What turns `gh api` into a write: a method, a field or a request body (a cluster too).
API_WRITE = re.compile(r"^(-X|--method|-f|-F|--field|--raw-field|--input)(=|$)|^-[A-Za-z]*[XfF]")


def gh_api_read(vals):
    """`gh api <path>` that stays a GET: no method, field or body option; `gh api graphql` only
    with literal fields (no `@file`, no --input/-X) and no `mutation` in any word (#272)."""
    if vals[1:3] == ["api", "graphql"]:
        return not any(re.search("mutation", v, re.I) or "=@" in v or v in ("-X", "--input")
                       or v.startswith(("--method", "--input=", "-X")) for v in vals[3:])
    return (vals[1:2] == ["api"] and len(vals) > 2
            and not any(API_WRITE.match(v) for v in vals[2:]))


GQL_FIELD = ("-f", "-F", "--field", "--raw-field")


def graphql_values(seg):
    """Indexes of `name='<literal>'` field values of a `gh api graphql` read: the query is data."""
    if [w.value for w in seg[1:3]] != ["api", "graphql"]:
        return set()
    return {i for i, w in enumerate(seg) if i > 3 and seg[i - 1].value in GQL_FIELD
            and len(w.parts) == 2 and w.parts[0][0] == "u" and w.parts[0][1].endswith("=")
            and w.parts[1][0] == "s"}


PY_FLAG = re.compile(r"-[IBEsSu]+")


def py_flags(vals):
    """Index of the first word after python3's isolating flags (#268: `-I -c` is judged as `-c`)."""
    j = 1
    while j < len(vals) and PY_FLAG.fullmatch(vals[j]):
        j += 1
    return j


# `NAME=<literal>` then `;`, `&&` or a newline: the literal holds only reader-safe characters (a
# leading `~/`, a double-quoted value may hold spaces — #272).
ASSIGN = re.compile(r"[ \t]*([A-Za-z_][A-Za-z0-9_]*)=(~?[A-Za-z0-9_./:,=+@%-]+|'[A-Za-z0-9_./:,=+@%-]*'"
                    r"|\"[A-Za-z0-9_./:,=+@%~ -]*\")[ \t]*(?:;|&&|\n)")
IDENT = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")
# A later use that rebinds the name: reassigned, read into, a loop variable, exported, unset.
REBIND = r"(?:^|[\s;&|(]){0}\+?=|\b(?:read|for|select|export|unset|local|declare|typeset|readonly|getopts)\b[^;&|\n]*\b{0}\b"


def inline_literals(cmd):
    """#268: `NAME=<literal>; …` at the head of a command — $NAME / ${NAME} in the rest are written
    in (outside single quotes), so a literal path in a variable reads as the literal. Unchanged when
    a name is rebound later, when a here-document is present, or when nothing follows."""
    names, i = {}, 0
    while (m := ASSIGN.match(cmd, i)):
        names[m.group(1)] = m.group(2).strip("'\"")
        i = m.end()
    rest = cmd[i:]
    if not names or not rest.strip() or "<<" in rest or any(
            re.search(REBIND.format(re.escape(n)), rest) for n in names):
        return cmd
    out, k, quote = [], 0, None
    while k < len(rest):
        c = rest[k]
        if quote == "'":
            quote = None if c == "'" else quote
        elif c == "\\":
            out.append(rest[k:k + 2])
            k += 2
            continue
        elif c in "'\"" and quote in (None, c):
            if not (c == "'" and quote == '"'):
                quote = None if quote else c
        elif c == "$":
            braced = rest.startswith("{", k + 1)
            m = IDENT.match(rest, k + 1 + braced)
            end = m.end() + braced if m else 0
            if m and m.group(0) in names and (not braced or rest.startswith("}", m.end())):
                out.append(names[m.group(0)])
                k = end
                continue
        out.append(c)
        k += 1
    return "".join(out)


# `python3 - <<DELIM` + newline, ASCII delimiter only (never `\w`: Unicode in Python 3); no `<<-`.
# Interpreter flags that only make the run stricter (-I isolated, -B no bytecode …) may precede it.
HEREDOC = re.compile(r"python3 (?:-[IBEsSu]+[ ]+)*-[ ]*<<[ ]*"
                     r"(?:'([A-Za-z0-9_]+)'|\"([A-Za-z0-9_]+)\"|([A-Za-z0-9_]+))\n")


def python_heredoc_ok(cmd, forms):
    """`python3 - <<DELIM` whose first delimiter line ends the command, the body literal (quoted
    delimiter, or no `$` / backquote / `\\`), under the local Bash(python3 -) opt-in (<forms>)."""
    m = HEREDOC.match(cmd)
    lines = cmd[m.end():].split("\n") if m else []
    delim = m and (m.group(1) or m.group(2) or m.group(3))
    if delim not in lines or lines[lines.index(delim) + 1:] not in ([], [""]):
        return False
    if m.group(3) and re.search(r"[$`\\]", "\n".join(lines[:lines.index(delim)])):
        return False
    return "-" in forms


def format_words(seg, fmt, layout):
    """Indexes of single-quoted words that directly follow -q/--jq/-t/--template (or glued
    `--jq='…'`) before any `--`: a read's formatting data, for the forms gh's layout table lacks
    (a form in it is bound by format_bindings alone). An option word that is itself the value of a
    formatting option (`--template --jq '<url>'`) binds nothing."""
    found, glued = set(), (("u", "--jq="), ("u", "--template="))
    if tuple(w.value for w in seg[1:3]) in layout:
        return found
    for i, w in enumerate(seg):
        if w.value == "--":
            break
        if (i > 1 and seg[i - 1].value in fmt and seg[i - 2].value not in fmt and len(w.parts) == 1
                and w.parts[0][0] == "s") or (
                len(w.parts) == 2 and w.parts[0] in glued and w.parts[1][0] == "s"):
            found.add(i)
    return found


# #272: inline Python is judged by its code. Modules whose import reaches no network and runs no
# process (logging, platform, uuid, pickle … are left out: handlers, subprocess, code loading).
PY_MODULES = {"argparse", "base64", "bisect", "calendar", "collections", "contextlib", "copy", "csv",
              "dataclasses", "datetime", "decimal", "difflib", "enum", "fnmatch", "fractions",
              "functools", "glob", "gzip", "hashlib", "heapq", "html", "io", "itertools", "json",
              "math", "os", "pathlib", "pprint", "random", "re", "shlex", "shutil", "statistics",
              "string", "struct", "sys", "tempfile", "textwrap", "time", "tomllib", "typing",
              "unicodedata", "zlib"}
# Builtins and attributes that run code, a process or a lookup by name; the import machinery.
PY_NAMES = {"eval", "exec", "compile", "getattr", "setattr", "delattr", "globals", "locals", "vars",
            "breakpoint", "help"}
PY_ATTR = re.compile(r"_|exec|spawn|posix_spawn|fork|popen|system$|startfile$|sys$|modules$"
                     r"|meta_path$|path_hooks$|settrace$|setprofile$|addaudithook$|load_module$")
# The only uses of `sys`: a module that may change sys.path (and so what a lazy import loads) is not.
SYS_OK = {"argv", "stdin", "stdout", "stderr", "exit", "version", "version_info", "platform",
          "maxsize", "getsizeof", "byteorder"}
def py_code_safe(code, shell_text=True):
    """True when <code> parses, imports only PY_MODULES (every import at the top), names no
    PY_NAMES / dunder, no attribute matching PY_ATTR and uses `sys` only for SYS_OK. File writes
    are not egress (Operator 2026-11-23: the guard asks only for the network or a process). Known
    limit: without -I a written `<module>.py` in the cwd could be imported lazily by a stdlib call.
    <shell_text>: the code came through a shell word, so a `$` or backquote (an expansion) refuses it."""
    if shell_text and re.search(r"[$`]", code):
        return False
    try:
        tree = ast.parse(code)
    except (SyntaxError, ValueError):
        return False
    lead, sys_ok = set(), set()
    for node in tree.body:
        if not isinstance(node, (ast.Import, ast.ImportFrom)):
            break
        lead.add(id(node))
    nodes = list(ast.walk(tree))
    for node in nodes:
        if (isinstance(node, ast.Attribute) and isinstance(node.value, ast.Name)
                and node.value.id == "sys" and node.attr in SYS_OK):
            sys_ok.add(id(node.value))
    for node in nodes:
        if isinstance(node, ast.Import):
            if id(node) not in lead or any(a.name.split(".")[0] not in PY_MODULES
                                           or (a.name == "sys" and a.asname) for a in node.names):
                return False
        elif isinstance(node, ast.ImportFrom):
            if (id(node) not in lead or node.level or (node.module or "").split(".")[0] not in PY_MODULES
                    or any(a.name in PY_NAMES or PY_ATTR.match(a.name)
                           or (node.module == "sys" and a.name not in SYS_OK) for a in node.names)):
                return False
        elif isinstance(node, ast.Name):
            if node.id in PY_NAMES or node.id.startswith("__") or (node.id == "sys"
                                                                   and id(node) not in sys_ok):
                return False
        elif isinstance(node, ast.Attribute) and PY_ATTR.match(node.attr):
            return False
    return True


# `python3 [flags] - [args] <<'D'` (quoted delimiter: the body is the program, never expanded) and
# `cat [> f] <<'D' [> f]` (the body is data, unless `(` comes before). Nothing may follow on the header line but a redirection.
PY_DOC = re.compile(r"(?:^|(?<=[;&|(\s]))python3((?:[ \t]+-[IBEsSu]+)*)[ \t]+-((?:[ \t][^\n<>|;&]*?)?)"
                    r"[ \t]*<<[ \t]*(['\"])([A-Za-z0-9_]+)\3((?:[ \t]*\d?>>?[ \t]*[^\s<>|;&]+)*)"
                    r"(?=[ \t]*(?:$|;|&&|\|\||\n))")
CAT_DOC = re.compile(r"(?:^|(?<=[;&|(\s]))cat((?:[ \t]+>>?[ \t]*[^\s<>|;&]+)?)[ \t]*<<[ \t]*(['\"])"
                     r"([A-Za-z0-9_]+)\2((?:[ \t]+>>?[ \t]*[^\s<>|;&]+)?)[ \t]*$")


def python_heredocs_judged(cmd):
    """<cmd> with each quoted-delimiter Python here-doc whose body py_code_safe accepts written as
    `true <args>` and each `cat` data here-doc as `cat <redirections>`, the bodies and delimiter
    lines dropped. Every other here-doc (unquoted delimiter, `<<-`, `| bash` after it, a body
    the check refuses, no closing line) stays as it is: today's path reads it."""
    lines, out, i = cmd.split("\n"), [], 0
    while i < len(lines):
        line, i = lines[i], i + 1
        py, cat = PY_DOC.search(line), CAT_DOC.search(line)
        m = py or cat
        delim = m and (m.group(4) if py else m.group(3))
        end = next((j for j in range(i, len(lines)) if lines[j] == delim), None) if m else None
        # A `cat` here-doc read by `<(…)` / `$(…)` is a program, not data.
        if (end is None or (py and not py_code_safe("\n".join(lines[i:end]), shell_text=False))
                or (cat and line[:m.start()].rstrip().endswith("("))):
            out.append(line)
            continue
        keep = ("true" + m.group(2) + m.group(5)) if py else ("cat" + m.group(1) + m.group(4))
        out.append(line[:m.start()] + keep + line[m.end():])
        i = end + 1
    return "\n".join(out)
