"""Decides whether the supervisor may press Enter on a team role's permission prompt.

Usage: team_prompt_check.py [<root>] [--settings <file>]... [--block] < pane history
       team_prompt_check.py [<root>] [--settings <file>]... --strict [--transcript <file>] < pane
       team_prompt_check.py <clone> --strict --transcript <file> --classes [--report]
         [--main <main checkout>] < pane
Exit 0 = tier 1 (no egress, nothing in the prompt matches an ask/deny rule of <root>'s settings or
a --settings file and the SQL guard stays quiet), exit 1 = the Operator must answer in the window,
with the reason on stderr. Default: the newest prompt in the history is the one checked.
--strict (the sender): team_prompt.py must read a complete active permission prompt;
--transcript also checks the original input of its unique pending tool_use.
Refused too: a prompt whose command cannot be read (never approve what was not read), a WebFetch
prompt or a Bash command naming an egress tool (an Operator action, team-mode.md §10) and an
unreadable policy, an Edit/Write of .claude/settings*.json or a Bash command naming one
and, with a --main other than <root>, an Edit/Write outside <root> or a Bash path under <main>
(the classes trust its .git, CLAUDE.md and .agents/team/). --block prints the
command block and exits 0, or 1 when there is none. --classes (the sender, tier 1 only): a refusal
whose only cause is ask-tier rule matches or the settings refusal is waived when the prompt is in
one enabled team_prompt_classes.py class — prints `policy-class: <name>`, exit 0; deny, egress, the
SQL guard and unreadable prompts are never waived. --report prints `class: <name>`, `class: not
needed — no ask/deny match` or `class: none — <refusal>` and exits 0.
"""
import fnmatch
import glob
import json
import os
import re
import shlex
import sys
sys.dont_write_bytecode = True  # local imports below; callers run python3 -I without -B

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "hooks", "lib"))
sys.path.insert(0, HERE)
import guard_destructive_sql  # noqa: E402
from guard_destructive_sql import doc_heredocs_removed, strip_shell_comments  # noqa: E402
import guard_team_egress  # noqa: E402
import team_prompt  # noqa: E402
import team_prompt_classes  # noqa: E402
import team_prompt_settings  # noqa: E402

END = re.compile(r"Do you want to (proceed|make this edit|create|overwrite|allow)|❯ *1\. Yes")
START = re.compile(r"^\s*(Bash command|Bash\(|Edit file|Write file|Create file|Overwrite file|"
                   r"Read file|WebFetch|Fetch)")
SEGMENT = re.compile(r"&&|\|\||\$\(|[;|&()`]")
# A path segment named like a tool (tools/curl/…) refuses too: its cost is one Operator action.
EGRESS = re.compile(r"(^|[^A-Za-z0-9_.-])(curl|wget|ssh|scp|rsync|nc)([^A-Za-z0-9_-]|$)")
EDITS = ("Edit file", "Write file", "Create file", "Overwrite file")
SETTINGS_TEXT = re.compile(r"\.claude/(settings\.json|settings\.local\.json)", re.I)
# Second layer under the word check: appsettings.json / local.settings.json are not this name.
SETTINGS_WORD = re.compile(r"(^|[^A-Za-z0-9_.-])(settings(\.local)?\.json)\b", re.I)
SETTINGS_NAMES = team_prompt_settings.SETTINGS_NAMES
PUNCT = set("();<>|&")
CONTINUATION = re.compile(r"\\\n")
# Global options before the subcommand: `git -C . rebase` must meet `Bash(git rebase*)`.
GIT_VALUE_OPTS = ("-C", "-c", "--git-dir", "--work-tree", "--namespace")
squash = team_prompt.squash


class Refuse(Exception):
    pass


def segments(line):
    """The line and each command in it: `echo ok && bash x.sh` must meet `Bash(bash x.sh*)`."""
    out = [line.strip()]
    for part in SEGMENT.split(line):
        # `env X=1 /bin/bash x.sh` must meet the same rule, or a prefix skips the ask tier.
        words = guard_team_egress.strip_wrappers(part.split())
        if words and os.path.basename(words[0]) in guard_team_egress.SHELLS:
            words = [os.path.basename(words[0])] + words[1:]
        for text in (re.sub(r"^\s*(\w+=\S*\s+)*", "", part).strip(), " ".join(words)):
            if text and text not in out:
                out.append(text)
    return out


def canonical(cmd, depth=0):
    """Word lists of each command with shell quoting removed, so `bash "x.sh"` meets `bash x.sh*`;
    a `bash -c` / `eval` string is lexed as commands too."""
    text = CONTINUATION.sub("", cmd)
    if re.search(r"\$'[^']*\\", text):
        raise Refuse("refuse: ANSI-C escapes in $'…' cannot be checked")
    text = re.sub(r"\$(?=['\"])", "", text)
    for t in (text, doc_heredocs_removed(text)):
        lex = shlex.shlex(strip_shell_comments(t).replace("\n", " ; "), posix=True,
                          punctuation_chars=True)
        lex.whitespace_split, lex.commenters = True, ""
        try:
            toks = list(lex)
            break
        except ValueError:
            continue
    else:
        raise Refuse("refuse: command quoting cannot be parsed")
    out, operands, operand = [[]], [], False
    for t in toks:
        word = os.path.normpath(re.sub("/+", "/", t)) if "/" in t else t
        if operand:
            operands.append([word])
            operand = False
        elif set(t) <= PUNCT and re.search("[<>]", t) and not re.search("[()]", t):
            # `git > /dev/null merge` is still one argv: a redirection drops only its operand.
            if out[-1] and out[-1][-1].isdigit():
                out[-1].pop()
            operand = True
        elif set(t) <= PUNCT:
            out.append([])
        else:
            out[-1].append(word)
    out += operands
    nested = []
    for words in out if depth < 3 else []:
        w = shell_words(words)
        flag = next((i for i, x in enumerate(w[1:-1], 1)
                     if w[0] in guard_team_egress.SHELLS and guard_team_egress.SHELL_C.match(x)), 0)
        inner = w[flag + 1] if flag else " ".join(w[1:]) if w[:1] == ["eval"] else ""
        nested += canonical(inner, depth + 1) if inner else []
    return [w for w in out if w] + nested


def shell_words(words):
    """Wrappers and assignments stripped, a shell path as its basename: `env /bin/bash` → bash."""
    words = guard_team_egress.strip_wrappers(words)
    if words and os.path.basename(words[0]) in guard_team_egress.SHELLS:
        words = [os.path.basename(words[0])] + words[1:]
    return words


def argv_plain(words):
    """`/usr/bin/git x` → `git x`, `bash -e -- x.sh` → `bash x.sh`, git global options dropped."""
    w = shell_words(words)
    if w and "/" in w[0]:
        w = [os.path.basename(w[0])] + w[1:]
    if w[:1] and w[0] in guard_team_egress.SHELLS \
            and not any(guard_team_egress.SHELL_C.match(x) for x in w[1:]):
        i = 1
        while i < len(w) and w[i][:1] in ("-", "+"):
            i += 2 if w[i] in ("-o", "+o", "-O", "+O") else 1
        w = w[:1] + w[i:]
    return git_plain(w) or w


def git_plain(words):
    """`git <global options> sub …` → `git sub …`, or [] when there are no global options."""
    if words[:1] != ["git"] or len(words) < 2 or not words[1].startswith("-"):
        return []
    i = 1
    while i < len(words) and words[i].startswith("-"):
        i += 2 if words[i] in GIT_VALUE_OPTS else 1
    return ["git"] + words[i:]


def command_block(pane):
    """→ (header, body) of the newest prompt, or None. History keeps answered prompts above it."""
    lines = pane.splitlines()
    last = next((i for i in range(len(lines) - 1, -1, -1) if END.search(lines[i])), None)
    if last is None:
        return None
    first = last
    while first > 0 and (END.search(lines[first - 1]) or not lines[first - 1].strip()):
        first -= 1
    # An END above the newest prompt's own options belongs to an answered prompt: its header is
    # not this prompt's, so a non-START header (MCP tool, menu) is refused, never mis-bound.
    start = None
    for i in range(first - 1, -1, -1):
        if END.search(lines[i]):
            return None
        if START.search(lines[i]):
            start = i
            break
    if start is None:
        return None
    end = next(i for i in range(start + 1, last + 1) if END.search(lines[i]))
    body = [re.sub(r"^[\s│┃|>]+", "", l) for l in lines[start + 1:end]]
    return lines[start].strip(), "\n".join(l for l in body if l.strip())


def rules(root, extra):
    """ask/deny Bash rules; refuses when <root> has no settings or any file cannot be parsed."""
    out, seen = [], 0
    own = [os.path.join(root, ".claude", f) for f in SETTINGS_NAMES]
    for path in own + extra:
        if not os.path.exists(path):
            continue
        try:
            with open(path, encoding="utf-8") as fh:
                perms = json.load(fh).get("permissions", {})
        except (OSError, ValueError, AttributeError):
            raise Refuse("refuse: clone policy unreadable (%s)" % os.path.relpath(path, root))
        seen += path in own
        for tier in ("deny", "ask"):
            for rule in perms.get(tier, []):
                m = re.match(r"^Bash\((.*)\)$", rule)
                if m:
                    pat = m.group(1)
                    pat = pat[:-2] + "*" if pat.endswith(":*") else pat
                    out.append((tier, rule, pat))
    if not seen:
        raise Refuse("refuse: clone policy unreadable (.claude/settings.json)")
    return out


def matches(cmd, tiered, bash):
    """[(tier, rule, text)] of every rule a line, command segment or canonical command meets."""
    texts = [t for line in CONTINUATION.sub("", cmd).splitlines() for t in segments(line)]
    for words in canonical(cmd) if bash else []:
        texts += [t for t in (" ".join(words), " ".join(shell_words(words)),
                              " ".join(argv_plain(words))) if t and t not in texts]
    out = []
    for text in texts:
        for tier, rule, pat in tiered:
            if fnmatch.fnmatchcase(text, pat) or fnmatch.fnmatchcase(text, pat + "*"):
                out.append((tier, rule, text))
    return out


def under(path, dirs):
    """Case-folded: the volume is case-insensitive APFS, so `.Agents/` is `.agents/`."""
    path = path.lower()
    return any(path == d.lower() or path.startswith(d.lower() + os.sep) for d in dirs)


def guarded_main(root, main):
    """[<main>] when it is a separate checkout (a team clone check), else []."""
    if not main or os.path.realpath(main) == os.path.realpath(root):
        return []
    return [os.path.realpath(main)]


def path_words(cmd, root, main):
    """Settings files and <main> paths among the canonical words, globs expanded from <root>;
    a $VAR or a path relative to a `cd` target is not resolved."""
    dirs, base = guarded_main(root, main), os.path.realpath(root)
    for words in canonical(cmd):
        for part in (p for w in words for p in w.split("=")):
            full = os.path.join(base, os.path.expanduser(part))
            hits = [part] + (glob.glob(full) if re.search(r"[*?[]", part) else [])
            for hit in hits:
                if os.path.basename(hit).lower() in SETTINGS_NAMES:
                    raise Refuse("refuse (settings): %s via Bash — Operator"
                                 % os.path.basename(hit))
            paths = [full] + hits[1:]
            if dirs and ("/" in part or part.startswith("~")) and any(
                    under(os.path.realpath(os.path.join(base, h)), dirs) for h in paths):
                raise Refuse("refuse (outside clone): %s — Operator" % part)


def unwaivable(cmd, bash, root, main):
    """Egress, the SQL guard, a Bash command naming a settings file or a <main> trust path."""
    if bash:
        path_words(cmd, root, main)
        m = SETTINGS_WORD.search(cmd)
        if m:
            raise Refuse("refuse (settings): %s via Bash — Operator" % m.group(2))
        for line in cmd.splitlines():
            for part in SEGMENT.split(line):
                m = EGRESS.search(part)
                if m and not guard_team_egress.loopback_probe(part.split()):
                    raise Refuse("refuse (egress): %s" % m.group(2))
    decision, reason = guard_destructive_sql.classify(cmd, root, root)
    if decision:
        raise Refuse("refuse (%s): %s" % (decision, reason))


def tier_refusal(tier, rule, text):
    return Refuse("refuse (%s-tier): %s matches %s" % (tier, text, rule))


def edit_lines(root, header, inp):
    """→ (removed, added) squashed whole lines the pending edit touches, or None."""
    try:
        with open(os.path.join(root, str(inp.get("file_path") or "")), encoding="utf-8") as fh:
            text = fh.read()
    except (OSError, ValueError):
        text = None
    if header != "Edit file":
        return squash(text or ""), squash(inp.get("content"))
    o, n = inp.get("old_string"), str(inp.get("new_string") or "")
    every = inp.get("replace_all") is True
    i = text.find(o) if text is not None and isinstance(o, str) and o else -1
    if i < 0:
        return None
    spans = []  # the whole lines of each replaced occurrence, never the rest of the file
    while i >= 0:
        a, b = text.rfind("\n", 0, i) + 1, text.find("\n", i + len(o))
        b = len(text) if b < 0 else b
        if spans and a <= spans[-1][1]:
            spans[-1][1] = max(spans[-1][1], b)
        else:
            spans.append([a, b])
        i = text.find(o, i + len(o)) if every else -1
    return (squash("".join(text[a:b] for a, b in spans)),
            squash("".join(text[a:b].replace(o, n, -1 if every else 1) for a, b in spans)))


def rows_differ(root, header, inp, body):
    """True when a visible diff row of a full Edit/Write header is not in the pending edit."""
    want, seen, cur = edit_lines(root, header, inp), 0, None
    if want is None:
        return True
    for row in body:
        # A new file's preview row `1 ---` is content, never a removed line.
        m = team_prompt.EDIT_ROW.match(row) if header != "Create file" else None
        c = team_prompt.CONT_ROW.match(row) if not m and header != "Create file" else None
        if c and (not cur or cur[0] != c.group(1)):
            return True
        cur = (m.group(1), squash(m.group(2))) if m else (cur[0], cur[1] + squash(c.group(2))) \
            if c else None
        if cur and cur[1] not in want[cur[0] == "+"]:
            return True
        w = team_prompt.WRITE_ROW.match(row) if not m and not c and header != "Edit file" else None
        if w and squash(w.group(1)) not in want[1]:
            return True
        seen += bool(m)
    return header == "Edit file" and not seen


def edit_bound(root, p, inp, cwd):
    """Refuses unless the screen's path line and diff rows are the pending edit's own."""
    shown = os.path.join(cwd or root, os.path.expanduser(p["desc"]))
    target = os.path.join(root, str(inp.get("file_path") or ""))
    if not under(os.path.realpath(shown), [os.path.realpath(target)]):
        raise Refuse("refuse: could not read the command behind the prompt"
                     " (screen path differs from the pending edit)")
    if rows_differ(root, p["header"], inp, p["body"]):
        raise Refuse("refuse: could not read the command behind the prompt"
                     " (screen rows differ from the pending edit)")


def strict_commands(pane, transcript, root):
    """→ (header, [commands], input, tool_use id, path line, recovered); the transcript input is
    what actually runs."""
    p = team_prompt.parse(pane, transcript)
    if p["kind"] != "permission" or not p["complete"]:
        raise Refuse("refuse: could not read the command behind the prompt (%s)"
                     % (p["reason"] or "no permission prompt"))
    cmds, inp, tid = [p["command"]], None, None
    if transcript is not None and p["header"] not in ("Fetch", "WebFetch"):
        tid, inp = team_prompt.associated(p, transcript)
        if inp is None:
            raise Refuse("refuse: could not read the command behind the prompt (no prompt event)")
        # recover() already bound a clipped prompt's rows; a full header is bound here.
        if p["header"] in EDITS and not p["recovered"]:
            edit_bound(root, p, inp, team_prompt.tool_cwd(transcript, tid))
        # The screen soft-wraps inside tokens, so a displayed `cu`/`rl` split would pass alone.
        cmds.append(str(inp.get("command") or ""))
    # The path line only: diff rows that merely mention a settings file are not its edit.
    return (p["header"], cmds, inp, tid, p["desc"] or "\n".join(p["body"][:1]),
            bool(p["recovered"]))


def outside_refusal(root, main, header, inp, text):
    """An Edit/Write outside the clone, raised: the classes trust <main> files."""
    path = inp.get("file_path") if inp else text.split("\n", 1)[0].strip()
    if header not in EDITS or not guarded_main(root, main) or not isinstance(path, str):
        return
    real = os.path.realpath(os.path.join(root, os.path.expanduser(path)))
    if not under(real, [os.path.realpath(root)]):
        raise Refuse("refuse (outside clone): %s — Operator" % path)


def settings_refusal(root, header, inp, text):
    """The Edit/Write of a clone settings file as a Refuse, or None."""
    if header not in EDITS:
        return None
    name = team_prompt_settings.settings_target(root, (inp or {}).get("file_path"))
    m = None if inp else SETTINGS_TEXT.search(text)
    if name or m:
        return Refuse("refuse (settings): %s edit — Operator" % (name or m.group(1)))
    return None


def session_id(root):
    try:
        with open(os.path.join(root, ".agents", "team", "session.json"), encoding="utf-8") as fh:
            return str(json.load(fh).get("session_id") or "") or None
    except (OSError, ValueError, AttributeError):
        return None


def audit(root, main, extra, header, cmds, inp, text):
    """Raises egress, unwaivable, deny and outside-clone; → (ask matches, settings refusal|None)."""
    if re.match(r"(WebFetch|Fetch)\b", header):
        raise Refuse("refuse (egress): %s prompt" % header)
    tiered, bash, found = rules(root, extra), header.startswith("Bash"), []
    for cmd in cmds:
        unwaivable(cmd, bash, root, main)
        found += matches(cmd, tiered, bash)
    first = next((f for f in found if f[0] == "deny"), None)
    if first:
        raise tier_refusal(*first)
    outside_refusal(root, main, header, inp, text)
    return found, settings_refusal(root, header, inp, text)


def classes_flow(root, main, pane, transcript, extra):
    """→ class name, or None when no ask/deny rule or settings refusal needs one; else Refuse."""
    if transcript is None:
        raise Refuse("refuse: could not read the command behind the prompt (no transcript)")
    header, cmds, inp, tid, text, recovered = strict_commands(pane, transcript, root)
    found, refusal = audit(root, main, extra, header, cmds, inp, text)
    if not found and refusal is None:
        return None
    first = refusal or tier_refusal(*found[0])
    # The role's transcript is Bash-writable: a header off screen was an Operator click before.
    if recovered:
        raise Refuse("%s; class: recovered prompt — header off screen" % first)
    session = session_id(root)
    if session is None:
        raise Refuse("%s; class: no live session" % first)
    name, why = team_prompt_classes.classify(
        root, main, header, inp, team_prompt.tool_cwd(transcript, tid),
        [(t, r) for t, r, _ in found], session)
    if name is None:
        raise Refuse("%s; class: %s" % (first, why))
    return name


def bash_block(header, body):
    """A Bash block's command between its dashed rules: description text is not shell."""
    lines = body.split("\n")
    dashed = [i for i, l in enumerate(lines) if team_prompt.DASHED.match(l)]
    if not header.startswith("Bash") or len(dashed) < 2:
        return body
    return "\n".join(lines[dashed[0] + 1:dashed[1]])


def run_checks(root, main, extra, pane, strict, transcript, block_only):
    """The old checks plus the settings refusal; True when --block printed the block."""
    if strict:
        header, cmds, inp, _, text, _ = strict_commands(pane, transcript, root)
    else:
        found = command_block(pane)
        if found is None:
            raise Refuse("refuse: could not read the command behind the prompt")
        header, cmds, inp, text = found[0], [found[1]], None, found[1].split("\n", 1)[0]
        if block_only:
            print(cmds[0])
            return True
        cmds = [bash_block(header, found[1])]
    found, refusal = audit(root, main, extra, header, cmds, inp, text)
    if found:
        raise tier_refusal(*found[0])
    if refusal:
        raise refusal
    return False


def args(argv):
    o = {"root": os.getcwd(), "extra": [], "block": False, "strict": False, "transcript": None,
         "classes": False, "report": False, "main": None}
    flags = {"--block": "block", "--strict": "strict", "--classes": "classes", "--report": "report"}
    while argv:
        a = argv.pop(0)
        if a in flags:
            o[flags[a]] = True
        elif a == "--settings" and argv:
            o["extra"].append(argv.pop(0))
        elif a in ("--transcript", "--main") and argv:
            o[a[2:]] = argv.pop(0)
        elif a.startswith("-"):
            return None
        else:
            o["root"] = a
    if o["transcript"] == "-":
        o["transcript"] = None
    return o


def main(argv):
    o = args(argv)
    if o is None or ((o["classes"] or o["report"]) and not o["strict"]):
        print("usage: team_prompt_check.py [<root>] [--settings <file>]... [--block]"
              " [--strict [--transcript <file>] [--classes [--report] [--main <root>]]]",
              file=sys.stderr)
        return 2
    pane = sys.stdin.read()
    try:
        if o["classes"] or o["report"]:
            name = classes_flow(o["root"], o["main"] or o["root"], pane, o["transcript"],
                                o["extra"])
            if o["report"]:
                print("class: %s" % (name or "not needed — no ask/deny match"))
            elif name:
                print("policy-class: %s" % name)
            return 0
        run_checks(o["root"], o["main"], o["extra"], pane, o["strict"], o["transcript"],
                   o["block"])
    except Refuse as e:
        if o["report"]:
            print("class: none — %s" % e)
            return 0
        print(str(e), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
