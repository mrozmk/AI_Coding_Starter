"""Compound helpers of the Supervisor's egress verdict beside guard_team_egress_supervisor.py: the
allowlisted companions (companion_safe), gh/python output piped into a stdin executor
(piped_verdict, backstop), a quote-aware scan of `$(…)` (scan), the literal `for` loop anywhere in a
compound (loop_verdict) and the `$(…)` of exempt reads inside an echo (substituted). Never allows;
any shape outside these returns None / "defer" (the caller's path decides)."""
import os
import re
import shlex

from guard_destructive_sql import SEPARATORS, tokenize

COMPANIONS = {"cd", "jq", "head", "tail", "sort", "uniq", "wc", "grep", "cut", "tr", "cat",
              "column", "tee", "echo", "printf", "true", "ls", "sleep", "rg", "git", "sed"}
SHELLS_I = {"bash", "sh", "zsh", "dash", "ksh", "fish"}
INTERP = {"python", "python3", "node", "perl", "ruby", "php", "lua"}
STDIN_CODE = {"xargs", "source", ".", "eval"}
STDIN_PATHS = {"-", "/dev/stdin", "/dev/fd/0", "/proc/self/fd/0"}  # script operands read stdin too
# What these run cannot be verified here.
MODIFIERS = {"noglob", "nocorrect", "builtin", "command", "exec", "env", "nohup", "sudo", "time",
             "nice", "timeout", "stdbuf", "caffeinate", "watch", "flock", "chrt", "ionice"}
# A printf format with only %s and %%: zsh evaluates numeric conversions' operands as arithmetic.
PRINTF_OK = re.compile(r"(?:[^%]|%[s%])*", re.S)
# #272: git subcommands that only read the repository; `-c`, `--output`, `-O` (a pager command) and
# every global option but -C / --no-pager are refused.
GIT_READS = {"log", "show", "diff", "status", "ls-files", "rev-parse", "blame", "grep", "shortlog",
             "describe", "ls-tree", "cat-file", "merge-base", "rev-list"}
GIT_BAD = re.compile(r"--output|-O|--open-files-in-pager|--ext-diff|--config-env|--exec")
SED_RANGE = re.compile(r"(?:[0-9]+|\$)(?:,(?:[0-9]+|\$))?p")
SUB_MARK = "@sub@"


def git_read(args):
    i = 0
    while i < len(args) and args[i].startswith("-"):
        if args[i] == "-C" and i + 1 < len(args):
            i += 2
        elif args[i] in ("--no-pager", "-P"):
            i += 1
        else:
            return False
    return (i < len(args) and args[i] in GIT_READS
            and not any(GIT_BAD.match(a) for a in args[i + 1:]))


def glob_ok(words):
    """A glob (`*`, `?`) only after a literal prefix that is no option: it expands to paths."""
    for w in words:
        raw = "".join(t if k != "g" else "\0" for k, t in w.parts)
        if "\0" in raw and (raw.startswith(("\0", "-")) or w.parts[0][0] != "u"):
            return False
    return True


def companion_safe(vals, egress_in, words=()):
    """True for an allowlisted companion that passes its option checks and the egress check."""
    if not vals or vals[0] not in COMPANIONS or not glob_ok(words[1:]):
        return False
    head, args = vals[0], vals[1:]
    # GNU/BSD sort accept abbreviated long options (an abbreviation of --compress-program).
    if (head == "cd" and len(args) > 1) or (head == "sort" and any(a[:2] == "--" for a in args)):
        return False
    if head == "printf" and args and (args[0].startswith("-") or not PRINTF_OK.fullmatch(args[0])
                                      or any(a.startswith("-v") for a in args[1:])):
        return False
    if ((head == "rg" and any(a.startswith(("--pre", "--hostname-bin")) for a in args))
            or (head == "git" and not git_read(args))
            or (head == "sed" and not (args[:1] == ["-n"] and len(args) > 1
                                       and SED_RANGE.fullmatch(args[1])
                                       and not any(a.startswith("-") for a in args[2:])))
            or (head == "sleep" and not all(re.fullmatch(r"[0-9.]+[smh]?", a) for a in args))):
        return False
    if SUB_MARK in " ".join(args) and head != "echo":
        return False
    try:
        return egress_in(shlex.join(vals)) == ""
    except ValueError:
        return False


def stdin_executor(vals):
    """True when this command runs what it reads on stdin: a shell or interpreter with no script
    operand (or `-`, /dev/stdin, a shell's -s), xargs / source / . / eval, or an unverifiable wrapper."""
    head = os.path.basename(vals[0]) if vals else ""
    if head not in SHELLS_I and head not in INTERP:
        return head in STDIN_CODE or head in MODIFIERS
    k, sh = 1, head in SHELLS_I
    while k < len(vals) and vals[k][:1] in ("-+" if sh else "-") and vals[k] not in ("-", "+"):
        w, k = vals[k], k + 1
        if w == "--":
            break
        if sh and re.fullmatch(r"-[A-Za-z]*s[A-Za-z]*", w):
            return True  # `bash -s x`: the script comes from stdin, x is $1
        if (sh and (w in ("--rcfile", "--init-file") or re.fullmatch(r"[-+][A-Za-z]*[oO]", w))
                or (not sh and w in ("-W", "-X"))):
            k += 1  # an option's value, no script: `-o pipefail`, `+O x`, `--rcfile f`, `-W x`
    return k >= len(vals) or vals[k] in STDIN_PATHS


def piped_verdict(cmds, ops, upstream=("gh",), tag=" (Supervisor)", executes=stdin_executor):
    """ask when a stdin executor reads a pipe from a chain with an <upstream> command, else defer."""
    src = ""
    for k, vals in enumerate(cmds):
        if not (k and ops[k - 1] == "|"):
            src = ""
        elif src and executes(vals):
            return "ask", src + " output piped into " + os.path.basename(vals[0]) + tag
        head = os.path.basename("".join(vals[:1]))
        src = src or (head if head in upstream else "")
    return "defer", ""


def backstop(cmd, upstream=("gh",), tag=" (Supervisor)", executes=stdin_executor):
    """For a layout the reader refuses: piped_verdict over today's token stream; defer if unparsable.
    <executes> judges a pipe consumer (the #322 deny passes a narrower one)."""
    try:
        tokens = tokenize(cmd)
    except ValueError:
        return "defer", ""
    cmds, ops, cur = [], [], []
    for t in tokens:
        s = t.strip("\n")
        if t == "{" and not cur:
            continue  # a group opener: its first command reads the same stdin
        if not (t and set(t) <= SEPARATORS) or (s[:1] == "&" and cur and cur[-1][-1:] in ("<", ">")):
            cur.append(t)  # `2>&1` tokenizes as `2>`, `&`, `1`: that `&` is the redirection's
            continue
        op = "|" if s[:1] == "|" and s[:2] != "||" else t  # `|`, `|&`, `|(` all pipe
        if cur:
            cmds.append(cur)
            ops.append(op)
            cur = []
        elif ops and s and not (ops[-1] == "|" and set(s) <= {"("}):
            ops[-1] = op  # `| (bash)`: the pipe reaches the group's first command
    return piped_verdict(cmds + [cur] if cur else cmds, ops, upstream, tag, executes)


def scan(text):
    """(states, spans) of <text>: per character "'" (single quotes), '"' (double quotes) or None
    (unquoted, also inside a `$(…)`, where quoting starts afresh), and the outermost `$(…)` spans as
    (index of `$`, index of `)`). None for a backquote, `$((`, a `\\` outside single quotes or
    unbalanced quotes and parentheses."""
    states, spans, stack, i = [], [], [], 0
    while i < len(text):
        c, top = text[i], (stack[-1][0] if stack else None)
        states.append(top if top in ("'", '"') else None)
        if top == "'":
            if c == "'":
                stack.pop()
        elif c in "\\`" or text.startswith("$((", i):
            return None
        elif text.startswith("$(", i):
            stack.append(("(", i))
            states.append(states[-1])
            i += 2
            continue
        elif c == '"':
            stack.pop() if top == '"' else stack.append(('"', i))
        elif top != '"' and c in "'(":
            stack.append((c if c == "'" else "p", i))
        elif top != '"' and c == ")":
            if not stack:
                return None
            kind, start = stack.pop()
            if kind == "(" and not any(k == "(" for k, _ in stack):
                spans.append((start, i))
        i += 1
    return None if stack else (states, spans)


# A literal `for NAME in <words>; do <body>; done` (`;` or a newline before `do` and `done`) after
# the start or a separator, followed by the end, a separator or a redirection.
FOR_LOOP = re.compile(
    r"(?:^|(?<=[;&|\n]))[ \t\n]*for ([A-Za-z_][A-Za-z0-9_]*) in ([^;\n]*)(?:;|\n)[ \t\n]*do[ \t\n]"
    r"(.*?)(?:;|\n)[ \t\n]*done(?=[ \t]*(?:$|[;&|\n<>0-9]))", re.S)
FOR_MAX = 64


def for_bodies(cmd, safe):
    """For the first literal `for` loop of <cmd>: the whole command once per value, the loop replaced
    by its body with the variable written in; None for no such loop. Values: 1..FOR_MAX words
    matching <safe> (the compound reader's plain-word pattern), none starting with `-` or `=`.
    `$NAME` / `${NAME}` is replaced outside single quotes only (bash and zsh expand it unquoted, in
    double quotes and inside `$(…)`; a plain value has nothing to split or glob). Every other `$`
    stays for the checks; a body scan() refuses -> None."""
    m = FOR_LOOP.search(cmd)
    if not m:
        return None
    name, words, body = m.group(1), m.group(2).split(), m.group(3)
    got = scan(body)
    if not got or not 0 < len(words) <= FOR_MAX or not all(
            safe.fullmatch(w) and w[0] not in "-=" for w in words):
        return None
    ref = re.compile(r"\$(?:\{%s\}|%s(?![A-Za-z0-9_]))" % (name, name))
    states = got[0]
    head, tail = cmd[:m.start()], cmd[m.end():]
    out = []
    for w in words:
        text, k = [], 0
        for r in ref.finditer(body):
            if states[r.start()] != "'":
                text += [body[k:r.start()], w]
                k = r.end()
        out.append(head + "".join(text) + body[k:] + tail)
    return out


def loop_verdict(cmd, safe, judge, width=1):
    """None unless <cmd> holds a literal loop (for_bodies); else ("exempt", "") when judge(text,
    width) exempts every unrolled text, the first ask, or a defer — the whole command then gets
    today's path. Unrolling stops (defer) past FOR_MAX texts in all."""
    texts = for_bodies(cmd, safe)
    if texts is None:
        return None
    if width * len(texts) > FOR_MAX:
        return "defer", ""
    verdicts = [judge(t, width * len(texts)) for t in texts]
    if all(v[0] == "exempt" for v in verdicts):
        return "exempt", ""
    return next((v for v in verdicts if v[0] == "ask"), ("defer", ""))


def substituted(cmd, judge):
    """<cmd> with each outermost `$(…)` that judge(inner) exempts replaced by SUB_MARK (companion_safe
    lets it stand only in an echo's arguments); <cmd> itself without `$(`; None when scan()
    refuses or any substitution is not exempt."""
    if "$(" not in cmd:
        return cmd
    got = scan(cmd)
    if not got or not got[1]:
        return None
    for start, end in reversed(got[1]):
        if judge(cmd[start + 2:end])[0] != "exempt":
            return None
        cmd = cmd[:start] + SUB_MARK + cmd[end + 1:]
    return cmd
