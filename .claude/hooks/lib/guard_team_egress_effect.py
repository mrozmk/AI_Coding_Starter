"""#268 helpers of the egress guard — judged by effect, not by shape: the read-only gh forms (and a
GET `gh api`), the isolating python3 flags, and the literal `NAME=<value>;` heads written into the
rest of a command. Pure functions; every caller stays fail-closed."""
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
    """`gh api <path>` that stays a GET: no method, field or body option, never graphql."""
    return (vals[1:2] == ["api"] and len(vals) > 2 and vals[2] != "graphql"
            and not any(API_WRITE.match(v) for v in vals[2:]))


PY_FLAG = re.compile(r"-[IBEsSu]+")


def py_flags(vals):
    """Index of the first word after python3's isolating flags (#268: `-I -c` is judged as `-c`)."""
    j = 1
    while j < len(vals) and PY_FLAG.fullmatch(vals[j]):
        j += 1
    return j


# `NAME=<literal>` then `;`, `&&` or a newline: the literal holds only reader-safe characters.
ASSIGN = re.compile(r"[ \t]*([A-Za-z_][A-Za-z0-9_]*)=([A-Za-z0-9_./:,=+@%-]+|'[A-Za-z0-9_./:,=+@%-]*')"
                    r"[ \t]*(?:;|&&|\n)")
IDENT = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")
# A later use that rebinds the name: reassigned, read into, a loop variable, exported, unset.
REBIND = r"(?:^|[\s;&|(]){0}\+?=|\b(?:read|for|select|export|unset|local|declare|typeset|readonly|getopts)\b[^;&|\n]*\b{0}\b"


def inline_literals(cmd):
    """#268: `NAME=<literal>; …` at the head of a command — $NAME / ${NAME} in the rest are written
    in (outside single quotes), so a literal path in a variable reads as the literal. Unchanged when
    a name is rebound later, when a here-document is present, or when nothing follows."""
    names, i = {}, 0
    while (m := ASSIGN.match(cmd, i)):
        names[m.group(1)] = m.group(2).strip("'")
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
