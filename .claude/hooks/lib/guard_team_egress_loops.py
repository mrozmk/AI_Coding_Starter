"""The Supervisor's literal `for` loop beside guard_team_egress_supervisor.py: for_bodies unrolls a
command that is only `for NAME in <values>; do <body>; done` into one body per value, and
loop_verdict judges each body with the Supervisor's verdict. Never allows; any other shape returns
None (the caller's path decides)."""
import re

# The whole command is `for NAME in <words>; do <body>; done` (`;` or a newline before `do` and
# `done`). Anything around the loop (`| bash`, `> f`, a second command) does not match.
FOR_LOOP = re.compile(
    r"[ \t\n]*for ([A-Za-z_][A-Za-z0-9_]*) in ([^;\n]*)(?:;|\n)[ \t\n]*do[ \t\n](.*?)"
    r"(?:;|\n)[ \t\n]*done[ \t\n]*", re.S)
FOR_MAX = 64


def for_bodies(cmd, safe):
    """The bodies of a literal `for` loop that is all of <cmd>, one per value, the variable written
    in; None for any other shape. Values: 1..FOR_MAX words matching <safe> (the compound reader's
    plain-word pattern), none starting with `-` or `=`. `$NAME` / `${NAME}` is replaced outside
    single quotes only (bash and zsh expand it unquoted and in double quotes; a plain value has
    nothing to split or glob); a `\\` outside single quotes or an unclosed quote -> None. Every
    other `$` stays in the body for the checks."""
    m = FOR_LOOP.fullmatch(cmd)
    if not m:
        return None
    name, words, body = m.group(1), m.group(2).split(), m.group(3)
    if not 0 < len(words) <= FOR_MAX or not all(
            safe.fullmatch(w) and w[0] not in "-=" for w in words):
        return None
    ref = re.compile(r"\$(?:\{%s\}|%s(?![A-Za-z0-9_]))" % (name, name))
    pieces, state, i = [], None, 0  # (text, substitutable) runs of the body; state: None ' "
    for k, c in enumerate(body):
        if state == "'":
            if c == "'":
                pieces.append((body[i:k + 1], False))
                state, i = None, k + 1
        elif c == "\\":
            return None
        elif c == "'" and state is None:
            pieces.append((body[i:k], True))
            state, i = "'", k
        elif c == '"':
            state = None if state == '"' else '"'
    if state == "'" or state == '"':
        return None
    pieces.append((body[i:], True))
    return ["".join(ref.sub(w, t) if sub else t for t, sub in pieces) for w in words]


def loop_verdict(cmd, safe, judge, project, egress_in):
    """None unless <cmd> is a literal loop (for_bodies); else ("exempt", "") when
    judge(body, project, egress_in, loop=False) exempts every body, the first ask, or a defer —
    the whole loop then gets today's path."""
    bodies = for_bodies(cmd, safe)
    if bodies is None:
        return None
    verdicts = [judge(b, project, egress_in, loop=False) for b in bodies]
    if all(v[0] == "exempt" for v in verdicts):
        return "exempt", ""
    return next((v for v in verdicts if v[0] == "ask"), ("defer", ""))
