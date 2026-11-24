"""gh-rule helpers and Supervisor policy beside guard_team_egress.py: the gh host/taint checks and
settings readers both share, a strict quote-aware reader of plain compounds (plain_segments), gh's
option layout for formatting values (format_bindings; format_masked serves every role's read path),
the Supervisor's compound and inline-Python exemption (supervisor_verdict), the touch-log writer
(record_touch). Never allows; every parser is fail-closed (None / False / "defer": today's path)."""
import collections
import json
import os
import re
import stat
import sys
import time
# Local imports below: never write __pycache__ into the project (callers run python3 -I, not -B).
sys.dont_write_bytecode = True

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)  # python3 -I drops the script dir from sys.path

from guard_destructive_sql import SEPARATORS  # noqa: E402
from guard_team_egress_effect import (  # noqa: E402
    GH_READ_FORMS, format_words, gh_api_read, graphql_values, py_code_safe, py_flags,
    python_heredoc_ok)
from guard_team_egress_loops import (  # noqa: E402
    SUB_MARK, backstop, companion_safe, loop_verdict, piped_verdict, substituted)

# Bash(gh <words>) exact, Bash(gh <words> *) / Bash(gh <words>:*) prefix; a `*`, `:`, quote or
# backslash anywhere else -> ignored (still asked).
GH_RULE = re.compile(r"^Bash\(gh ([^()*:\"'\\]+?)(:\*| \*)?\)$")
# What the unquoted text of a covered `gh ...` never needs (quoted text was vetted by read_word and
# is data, #287): any `$` (parameter or arithmetic expansion can assemble a `$(...)` at run time:
# `${a=$}${b=(}…$[x]`), backquotes, redirection (bash /dev/tcp), and the `#` / `\` that the shared
# comment stripper misreads (`x\ #; curl …` would hide the curl).
UNPLAIN = re.compile(r"[$`<>#\\]")
# gh reads `[HOST/]OWNER/REPO`; a third part, `git@…` or a scheme makes it pick another host.
GH_PLAIN_REPO = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")
# What an exempt gh read never carries: expansion or substitution, the `#` / `\` the shared comment
# stripper misreads (`x\ # -R host/o/r` hides the -R), the env names that select gh's host, or a
# `(` glued to a word (extglob / zsh grouping: `--@(repo)`, `--rep(o)` can match a file `--repo`).
GH_READS_TAINT = re.compile(r"[$`#\\]|GH_HOST|GH_REPO|[^\s;&|()<>]\(")
# Brace expansion rebuilds a word at run time: `--re{p..p}o=host/o/r` reaches gh as `--repo=…`.
BRACE = re.compile(r"\{[^{}]*(,|\.\.)[^{}]*\}")
# A glob that can match a file named like an option (`--rep[o]`, `[-]-repo` with a file `--repo`).
GLOB_OPTION = re.compile(r"^[-*?\[][^*?\[]*[*?\[]|^[*?\[]")
# The only unquoted word characters the reader accepts (ASCII; no glob, `~`, `$`, `\`, `#` …).
SAFE = re.compile(r"[A-Za-z0-9_./:,=+@%-]+")
# Where an unquoted word ends; any other character outside quotes is refused.
BOUNDARY = " \t;\n&|>"
DIGITS = "0123456789"
# Only one digit is an fd in both shells: zsh passes `12>&1`'s `1` on as an argument, bash does not.
FD_WORDS = [[("u", d)] for d in DIGITS]
Word = collections.namedtuple("Word", "value raw start end parts")


class Seg(list):
    """One simple command's words; .op is the operator that ended it (`|` `&&` `||` `;` newline)."""
    op = "end"


def gh_host_selector(words, plain_values=False):
    """True when <words> could point gh at another host: a repo value that is not plain
    OWNER/REPO (any -R / --repo spelling, also a short-flag cluster), a URL, --hostname, or the
    gh auth -h shorthand in any short-flag cluster. Over-matching only asks more.
    <plain_values>: the words are plain_segments' decoded values (gh_covered, #287) — real
    redirections are already split off, so a `<`/`>` left in a word is quoted data and the word is
    judged whole, and a word starting `https://github.com/` names the default host."""
    auth = words[1:2] == ["auth"]
    # `gh repo view [HOST/]OWNER/REPO`: the repository is positional there.
    if words[1:3] == ["repo", "view"]:
        pos = [w for w in words[3:] if not w.startswith("-")]
        if pos and not GH_PLAIN_REPO.match(pos[0]):
            return True
    for i, w in enumerate(words):
        # A glued redirection stays in a read-path token: `--repo>/dev/null h/o/r` is --repo h/o/r.
        if not plain_values:
            w = re.split(r"[<>]", w, maxsplit=1)[0]
        url = "://" in w and not (plain_values and w.startswith("https://github.com/"))
        if (url or w == "--hostname" or w.startswith("--hostname=")
                or BRACE.search(w) or GLOB_OPTION.match(w)):
            return True
        short = w.startswith("-") and not w.startswith("--")
        if auth and short and "h" in w[1:]:
            return True
        if w == "--repo" or w.startswith("--repo="):
            value = w[len("--repo="):] if "=" in w else "".join(words[i + 1:i + 2])
        elif short and "R" in w[1:]:
            rest = w[w.index("R") + 1:]
            value = (rest[1:] if rest.startswith("=") else rest) or "".join(words[i + 1:i + 2])
        else:
            continue
        if not GH_PLAIN_REPO.match(value):
            return True
    return False


def allow_rules(path):
    """The str entries of permissions.allow in <path>; raises OSError/ValueError/AttributeError."""
    with open(path, encoding="utf-8") as fh:
        allow = (json.load(fh).get("permissions") or {}).get("allow") or []
    return [r for r in allow if isinstance(r, str)] if isinstance(allow, list) else []


def supervisor_main_checkout(project):
    """The Supervisor's own session in the main checkout: never a team run, a clone or the TeamLead."""
    team = os.path.join(project, ".agents", "team")
    return (bool(project) and os.environ.get("TEAM_SESSION_ROLE") == "Supervisor"
            and not os.environ.get("TEAM_RUN_TEAM")
            and not os.path.exists(os.path.join(team, "session.json"))
            and not os.path.exists(os.path.join(team, "team.json")))


def local_rules(project):
    """The str allow rules of the checkout's settings.local.json; [] when absent or malformed."""
    try:
        return allow_rules(os.path.join(project, ".claude", "settings.local.json"))
    except (OSError, ValueError, AttributeError):
        return []


def gh_rules_of(allow):
    """(words, prefix) of the Bash(gh ...) rules among <allow>."""
    found = [GH_RULE.match(rule) for rule in allow]
    return [(tuple(m.group(1).split()), bool(m.group(2))) for m in found if m and m.group(1).split()]


def python_forms_of(allow):
    """The inline-Python forms <allow> opts into: "-" for the exact Bash(python3 -), "-c" for
    Bash(python3 -c *) / Bash(python3 -c:*); nothing else counts (Bash(python3 *))."""
    forms = {"-"} if "Bash(python3 -)" in allow else set()
    return forms | ({"-c"} if set(allow) & {"Bash(python3 -c *)", "Bash(python3 -c:*)"} else set())


def read_word(cmd, i):
    """(parts, end) of the word starting at <i>; None for anything the reader does not model."""
    parts, n, start = [], len(cmd), i
    while i < n and cmd[i] not in BOUNDARY:
        c = cmd[i]
        # #272: a leading `~` (the home dir) and `*` / `?` globs (companion_safe and gh_covered
        # judge where a glob may stand; a redirection target refuses one).
        if (c == "~" and i == start and (i + 1 == n or cmd[i + 1] in "/" + BOUNDARY)) or c in "*?":
            parts.append(("g" if c in "*?" else "u", c))
            i += 1
            continue
        if c in "'\"":
            k = cmd.find(c, i + 1)
            # Inside double quotes bash still expands `$`, backquotes and reads `\`.
            if k < 0 or (c == '"' and re.search(r"[$`\\]", cmd[i + 1:k])):
                return None
            parts.append(("s" if c == "'" else "d", cmd[i + 1:k]))
            i = k + 1
            continue
        m = SAFE.match(cmd, i)
        if not m:
            return None
        parts.append(("u", m.group(0)))
        i = m.end()
    # zsh expands a leading `=cmd` to the command's path.
    if not parts or (parts[0][0] == "u" and parts[0][1].startswith("=")):
        return None
    return parts, i


def redirection(cmd, i):
    """End of the redirection whose `>` is at <i>: `>`/`>>` to one literal file word or `>&N`;
    None for every other form."""
    n, append = len(cmd), cmd.startswith(">>", i)
    i += 2 if append else 1
    if i < n and cmd[i] == "&":
        k = i + 1
        while k < n and cmd[k] in DIGITS:
            k += 1
        # bash reads the whole operand word: `>&1note` is a file, not a duplication.
        if append or k == i + 1 or (k < n and cmd[k] not in " \t;\n|&"):
            return None
        return k
    while i < n and cmd[i] in " \t":
        i += 1
    got = read_word(cmd, i) if i < n and cmd[i] not in BOUNDARY else None
    if not got or not "".join(t for _, t in got[0]) or any(k == "g" for k, _ in got[0]):
        return None
    return None if got[1] < n and cmd[got[1]] in "&>" else got[1]


def plain_segments(cmd):
    """The simple commands of <cmd> as Seg lists of Word, or None unless <cmd> holds only words,
    `;` `&&` `||` `|` newline, and output redirections to a literal file or fd (default-deny)."""
    segs, seg, i, n, touched = [], Seg(), 0, len(cmd), False
    while i < n:
        c = cmd[i]
        if c in " \t":
            i += 1
        elif c in ";\n|&" and not cmd.startswith("&>", i):
            op = cmd[i:i + 2] if cmd.startswith(("&&", "||"), i) else c
            if op == "&" or cmd.startswith("|&", i):
                return None
            if not seg:
                # Blank lines are layout; any other empty command is a slip the reader refuses.
                if op == "\n" and not touched:
                    i += 1
                    continue
                return None
            seg.op = op
            segs.append(seg)
            seg, touched, i = Seg(), False, i + len(op)
            while op in ("|", "&&", "||") and i < n and cmd[i] in " \t\n":
                i += 1
        elif c in ">&":
            if cmd.startswith(("&>&", "&>>"), i):
                return None
            i = redirection(cmd, i + 1 if c == "&" else i)
            if i is None:
                return None
            touched = True
        else:
            got = read_word(cmd, i)
            if got is None or (got[1] < n and cmd[got[1]] == "&"):
                return None
            parts, end = got
            if end < n and cmd[end] == ">":
                if parts not in FD_WORDS:
                    return None
                i = end  # the fd digit is dropped; the `>` branch reads the redirection
                continue
            seg.append(Word("".join(t for _, t in parts), cmd[i:end], i, end, parts))
            i = end
    if seg:
        segs.append(seg)
    elif touched or (segs and segs[-1].op in ("|", "&&", "||")):
        return None
    return segs or None


BASE_V = "--json -q --jq -t --template -R --repo"
FMT = {"-q", "--jq", "-t", "--template"}
_PROJ = "--format -q --jq -L --limit --owner -t --template"
# `gh <cmd>`: (value options, bool options) from `gh <cmd> --help`; -R/--repo is inherited by
# issue/pr/release/run/label, absent from project; --help is added to every bool set.
_FORMAT = {
    "issue view": (BASE_V, "-c --comments -w --web"), "pr view": (BASE_V, "-c --comments -w --web"),
    "issue status": (BASE_V, ""), "release view": (BASE_V, "-w --web"),
    "issue list": (BASE_V + " --app -a --assignee -A --author -l --label -L --limit --mention -m"
                   " --milestone -S --search -s --state --type", "-w --web"),
    "pr list": (BASE_V + " --app -a --assignee -A --author -B --base -H --head -l --label -L"
                " --limit -S --search -s --state", "-d --draft -w --web"),
    "pr status": (BASE_V, "-c --conflict-status"),
    "pr checks": (BASE_V + " -i --interval", "--fail-fast --required --watch -w --web"),
    "project view": ("--format -q --jq -t --template --owner", "-w --web"),
    "project list": (_PROJ, "--closed -w --web"),
    "project item-list": (_PROJ + " --field --field-id --query", ""),
    "project field-list": (_PROJ, ""),
    "run list": (BASE_V + " -b --branch -c --commit --created -e --event -L --limit -s --status"
                 " -u --user -w --workflow", "-a --all"),
    "run view": (BASE_V + " -a --attempt -j --job",
                 "--exit-status --log --log-failed -v --verbose -w --web"),
    "label list": (BASE_V + " -L --limit --order -S --search --sort", "-w --web"),
}
GH_FORMAT_CMDS = {tuple(k.split()): (set(v.split()), set(b.split()) | {"--help"})
                  for k, (v, b) in _FORMAT.items()}

GH_VIEWS = tuple(("gh",) + f for f in GH_READ_FORMS)


def format_bindings(values):
    """Indexes of the words gh reads as a --jq / --template value. The walk binds nothing more after
    `--`, an unknown option, a glued short value or a cluster — the rest is checked as text."""
    spec = GH_FORMAT_CMDS.get(tuple(values[1:3])) if values[:1] == ["gh"] else None
    vopts, bopts = spec or (set(), set())
    bound, i = set(), 3
    while spec and i < len(values):
        w = values[i]
        if w == "--":
            break
        if w.startswith("--") and "=" in w:
            name = w.split("=", 1)[0]
            if name not in vopts:
                break
            if name in FMT:
                bound.add(i)
            i += 1
        elif w.startswith("--") or (w.startswith("-") and len(w) == 2):
            if w in vopts and i + 1 < len(values):
                if w in FMT:
                    bound.add(i + 1)
                i += 2
            elif w in bopts:
                i += 1
            else:
                break
        elif w.startswith("-"):
            break
        else:
            i += 1
    return bound


def bound_words(seg):
    """Indexes of <seg>'s bound formatting values that are one single-quoted word (also glued
    `--jq='…'`): pure data."""
    bound, glued = format_bindings([w.value for w in seg]), (("u", "--jq="), ("u", "--template="))
    return {i for i in bound for p in [seg[i].parts]
            if (len(p) == 1 and p[0][0] == "s") or (len(p) == 2 and p[0] in glued and p[1][0] == "s")}


def py_code_word(seg):
    """Index of the single-quoted code of a `python3 [flags] -c '<code>'` that py_code_safe accepts."""
    vals = [w.value for w in seg]
    j = py_flags(vals)
    if vals[:1] != ["python3"] or vals[j:j + 1] != ["-c"] or len(seg) < j + 2:
        return None
    code = seg[j + 1].parts
    return j + 1 if len(code) == 1 and code[0][0] == "s" and py_code_safe(code[0][1]) else None


def format_masked(cmd, egress_in):
    """<cmd> with each single-quoted bound --jq/--template value of a gh pr|issue view replaced by
    `_`, so the read-path taint checks skip data. Unchanged unless every simple command is such a
    view or a safe companion — never masked toward an interpreter (`… -q '\\(.x)' | bash`). The code
    of a safe `python3 -c` filter is masked the same way (#272)."""
    segs = plain_segments(cmd) or []
    views = [tuple(w.value for w in s[:3]) in GH_VIEWS for s in segs]
    pys = [py_code_word(s) for s in segs]
    if not any(views) or not all(v or k is not None
                                 or companion_safe([w.value for w in s], egress_in, s)
                                 for s, v, k in zip(segs, views, pys)):
        return cmd
    words = [s[k] for s, k in zip(segs, pys) if k is not None]
    for s in (s for s, v in zip(segs, views) if v):
        words += [s[i] for i in bound_words(s)]
    for w in sorted(words, key=lambda w: w.start, reverse=True):
        keep = w.parts[0][1] if w.parts[0][0] == "u" else ""
        cmd = cmd[:w.start] + keep + "_" + cmd[w.end:]
    return cmd


def gh_covered(seg, vals, rules):
    """A locally covered gh command — or a built-in read (GH_READ_FORMS, a GET `gh api`, a graphql
    query) — by #148's plain test, no stricter (no GH_READS_TAINT): no unplain character in the
    unquoted text outside single-quoted formatting values or query fields (quoted text is data,
    #287), no glob, no word of separators only (`'()'`), no host selector (plain values, so a
    github.com URL passes)."""
    rest = tuple(vals[1:])
    builtin = rest[:2] in GH_READ_FORMS or gh_api_read(vals)
    if not builtin and not any(rest[:len(w)] == w if prefix else rest == w for w, prefix in rules):
        return False
    if any(k == "g" for w in seg for k, _ in w.parts):
        return False
    ok = bound_words(seg) | (format_words(seg, FMT, GH_FORMAT_CMDS) | graphql_values(seg)
                             if builtin else set())
    text = " ".join(t for i, w in enumerate(seg) if i not in ok for k, t in w.parts if k == "u")
    return not (UNPLAIN.search(text) or any(set(v) <= SEPARATORS for v in vals)
                or gh_host_selector(["_" if i in ok else v for i, v in enumerate(vals)],
                                    plain_values=True))


def supervisor_verdict(cmd, project, egress_in, width=0):
    """("exempt" | "ask" | "defer", reason). exempt: every simple command is a locally covered gh or
    built-in gh read, a python3 -c whose code py_code_safe accepts (or under the local opt-in) or
    a safe companion, `$(…)` of such reads standing in an echo; ask: gh output piped into a stdin
    executor; defer (also for every session but the Supervisor's in the main checkout): today's
    path. A literal loop anywhere is unrolled (loop_verdict); <width>: texts unrolled so far."""
    if not supervisor_main_checkout(project):
        return "defer", ""
    def judge(text, w=width or 1):
        return supervisor_verdict(text, project, egress_in, w)
    if (judged := loop_verdict(cmd, SAFE, judge, width or 1)):
        return judged
    allow = local_rules(project)
    py = python_forms_of(allow)
    if python_heredoc_ok(cmd, py):
        return "exempt", ""
    plain = substituted(cmd, judge)
    segs = plain_segments(plain) if plain is not None else None
    if segs is None:
        return backstop(cmd)
    gh_rules = gh_rules_of(allow)
    kinds = ["gh"] if plain != cmd else []
    for seg in segs:
        vals = [w.value for w in seg]
        if SUB_MARK in " ".join(vals) and vals[0] != "echo":
            kinds.append("other")  # a substitution's output never reaches gh, python or a filter
        elif vals[0] == "gh":
            kinds.append("gh" if gh_covered(seg, vals, gh_rules) else "other")
        elif vals[:1] == ["python3"] and vals[py_flags(vals):][:1] == ["-c"]:
            j = py_flags(vals)
            # Words after the code are its sys.argv (the reader already refused any expansion).
            code = seg[j + 1].parts if len(seg) >= j + 2 else []
            quoted = len(code) == 1 and code[0][0] in "sd"
            safe = quoted and py_code_safe(code[0][1])
            kinds.append("py" if quoted and ("-c" in py or safe) else "other")
        else:
            kinds.append("safe" if companion_safe(vals, egress_in, seg) else "other")
    if "other" not in kinds and ("gh" in kinds or "py" in kinds):
        return "exempt", ""
    return piped_verdict([[w.value for w in s] for s in segs], [s.op for s in segs])


def record_touch(project, cwd, reason):
    """Append one Operator touch-log line for a Supervisor ask to .agents/touches/<yyyy-mm>.jsonl
    through pinned directory fds (no symlinked dir, FIFO or hard-linked file); a no-op for every
    other session. Never raises."""
    if not supervisor_main_checkout(project):
        return
    fds = []
    try:
        rel = (os.path.relpath(os.path.realpath(cwd), os.path.realpath(project))
               if isinstance(cwd, str) and cwd else "..")
        entry = {"at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                 "machine": os.uname().nodename.split(".")[0][:100],
                 "who": os.environ.get("USER", "")[:100],
                 "where": ("solo " + ("?" if rel.startswith("..") else rel))[:200],
                 "kind": "permission", "what": str(reason)[:200], "reason": "guard",
                 "answer": "", "wait_s": None}
        line = (json.dumps(entry, ensure_ascii=False) + "\n").encode("utf-8")
        if len(line) > 4000:
            entry["where"], entry["what"] = entry["where"][:60], entry["what"][:60]
            line = (json.dumps(entry, ensure_ascii=False) + "\n").encode("utf-8")
            if len(line) > 4000:
                return
        fds.append(os.open(project, os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC))
        for name in (".agents", "touches"):
            try:
                os.mkdir(name, 0o700, dir_fd=fds[-1])
            except FileExistsError:
                pass
            # The open re-verifies: a symlink fails with ELOOP / ENOTDIR.
            fds.append(os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC,
                               dir_fd=fds[-1]))
        # O_RDWR, not O_WRONLY: the fragment check below preads the last byte. macOS can fail a
        # concurrent first O_CREAT with ENOENT: the retry finds the file the other writer made.
        for attempt in range(3):
            try:
                fds.append(os.open(time.strftime("%Y-%m", time.gmtime()) + ".jsonl",
                                   os.O_RDWR | os.O_APPEND | os.O_CREAT | os.O_NOFOLLOW
                                   | os.O_NONBLOCK | os.O_CLOEXEC, 0o600, dir_fd=fds[-1]))
                break
            except FileNotFoundError:
                if attempt == 2:
                    raise
        st = os.fstat(fds[-1])
        if not stat.S_ISREG(st.st_mode) or st.st_nlink != 1:
            return
        # An earlier short write left a fragment: keep it one malformed line, this record whole.
        if st.st_size > 0 and os.pread(fds[-1], 1, st.st_size - 1) != b"\n":
            line = b"\n" + line
        os.write(fds[-1], line)
    except (OSError, ValueError, TypeError):
        return
    finally:
        for fd in fds:
            try:
                os.close(fd)
            except OSError:
                pass
