"""Reads the active prompt of a team role's pane and binds it to its transcript event.

Usage: python3 -I team_prompt.py parse [--transcript <file>|-]  < pane   → one JSON line, exit 0
       python3 -I team_prompt.py event <transcript> <kind>      [< parse JSON] → id|ambiguous|-
       python3 -I team_prompt.py result <transcript> <tool_use_id>           → yes|no
       python3 -I team_prompt.py pending <transcript> <tool_use_id>          → yes|no|unknown
       python3 -I team_prompt.py user-after <transcript> <uuid> <text>       → yes|no
       python3 -I team_prompt.py typed <text>                   < pane   → yes|no
       python3 -I team_prompt.py strip                          < pane   → pane without escapes
Usage errors exit 2. Only the bottom-most prompt whose footer is the last line counts; anything
the parser cannot read positively is `unreadable` — the sender then types nothing. A pane captured
with `capture-pane -e` is read without its escapes; on the input line a dim run is Claude Code's
prompt suggestion, not typed text, so it is dropped. A permission prompt whose header
scrolled off is read from the role's own transcript, else unreadable.
"""
import hashlib
import json
import os
import re
import sys
# Local imports below: never write __pycache__ into the project (callers run python3 -I, not -B).
sys.dont_write_bytecode = True

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
# Re-exported: callers keep reading the transcript through team_prompt.
from team_transcript import (  # noqa: E402,F401
    CONT_ROW, CONTEXT_ROW, EDIT_ROW, associated, diff_rows, entries, has_result, last_assistant,
    pending, squash, tool_cwd, user_after)

RULE = re.compile(r"^\s*─{20,}\s*$")
NAMED_RULE = re.compile(r"^\s*─{20,}(\s+[A-Za-z0-9._-]+\s+─)?\s*$")
BORDER = re.compile(r"^\s*─+\s+[A-Za-z0-9._-]+\s+─\s*$")
DASHED = re.compile(r"^\s*╌{10,}\s*$")
PERM_FOOTER = re.compile(r"^\s*Esc to cancel")
MENU_FOOTER = "Enter to select · ↑/↓ to navigate · Esc to cancel"
PERM_HEADER = re.compile(r"^\s*(Bash command|Edit file|Write file|Create file|Overwrite file|"
                         r"Read file|Fetch|WebFetch)\s*$")
MENU_HEADER = re.compile(r"^\s*([☐☒])\s+(\S.*)$")
TAB_HEADER = re.compile(r"^\s*←.*✔\s+Submit\s+→\s*$")
TAB_SINGLE = re.compile(r"^\s*←\s+[☐☒]\s+(.+\S)\s+✔\s+Submit\s+→\s*$")
QUESTION = re.compile(r"Do you want to (proceed|make this edit|create|overwrite|allow)")
# Claude Code's one auto-mode Tip under a permission header (cli bundle); it wraps on narrow panes.
TIP = squash('Tip: auto mode handles these prompts for you — choose "switch to auto mode" below')
OPTION = re.compile(r"^(\s*)(❯\s*)?(\d+)\.\s+(.*)$")
CHECK_ROW = re.compile(r"^\s*(❯\s*)?([1-9][0-9]?)\.\s+\[([ ✔])\]\s+(.+)$")
INPUT = re.compile(r"^\s*❯(\s.*)?$")
SPINNER = re.compile(r"^\s*\S\s+[A-Z][a-z]+…\s*\(")
GUTTER = re.compile(r"^\s*│ ?")
CSI = re.compile(r"\x1b\[[0-9;:?]*[ -/]*[@-~]")
OSC = re.compile(r"\x1b\][^\x07\x1b]*(\x07|\x1b\\)")
SGR = re.compile(r"\x1b\[([0-9;:]*)m")
# The cursor sits on the suggestion's first character as one inverse cell; tmux closes it with
# the next SGR (`\x1b[0;2m`), not with 27.
INVERSE_CELL = re.compile(r"\x1b\[(?:0;)?7m([^\x1b])(?:\x1b\[(?:0;)?27m)?(?=\x1b\[([0-9;:]*)m)")
MULTI = "multi-question menu — answer in the window (tier 3)"
RECOVER = {"Bash": ("Bash command", re.compile(r"^Do you want to proceed\?$")),
           "Edit": ("Edit file", re.compile(r"^Do you want to make this edit to (?P<n>.+)\?$")),
           "Write": ("Create file",
                     re.compile(r"^Do you want to (?P<v>create|overwrite) (?P<n>.+)\?$"))}
WRITE_ROW = re.compile(r"^\s*\d+\s(.*)$")
STATUS_LINES = 6
# The scrollback keeps old spinner text; only the live bottom of the pane can say "busy".
BUSY_LINES = 12


class Unreadable(Exception):
    pass


def header_kind(line):
    if PERM_HEADER.match(line):
        return "permission"
    if TAB_HEADER.match(line):
        return "checkbox"
    if MENU_HEADER.match(line):
        return "menu"
    return None


def tops(lines, end):
    """Indexes of rules followed by a known header, nearest first, above line `end`."""
    return [i for i in range(end - 1, -1, -1)
            if RULE.match(lines[i]) and i + 1 < len(lines) and header_kind(lines[i + 1])]


def gutter(line):
    return GUTTER.sub("", line).rstrip()


def options(rows):
    """Option rows with their deeper-indented description lines; rule lines are skipped."""
    out, cursors = [], []
    for line in rows:
        if RULE.match(line):
            continue
        m = OPTION.match(line)
        if m:
            if m.group(2):
                cursors.append(int(m.group(3)))
            out.append({"n": int(m.group(3)), "label": m.group(4).rstrip(), "desc": [],
                        "checked": None, "_col": len(m.group(1)) + len(m.group(2) or "")})
        elif out and len(line) - len(line.lstrip()) > out[-1]["_col"]:
            out[-1]["desc"].append(line.strip())
        else:
            raise Unreadable("unknown option row")
    if len(cursors) != 1:
        raise Unreadable("cursor not found")
    for o in out:
        del o["_col"]
    return out, cursors[0]


def tip_lines(body):
    """How many lines under the header are the Tip block; a Tip line of unknown extent refuses."""
    if not body or not body[0].strip().startswith("Tip:"):
        return 0
    seen = ""
    for i, line in enumerate(body):
        seen += squash(line)
        if seen == TIP:
            return i + 1
        if not TIP.startswith(seen):
            break
    raise Unreadable("unknown Tip block")


def parse_permission(p, body):
    q = next((i for i, l in enumerate(body) if QUESTION.search(l)), None)
    if q is None:
        raise Unreadable("question not found")
    text = body[tip_lines(body[:q]):q]
    if not text:
        raise Unreadable("description not found")
    dashed = [i for i, l in enumerate(text) if DASHED.match(l)]
    if p["header"] == "Bash command":
        if len(dashed) < 2:
            raise Unreadable("command block not found")
        # A long description wraps; the tool_use carries it whole.
        p["desc"] = " ".join(l.strip() for l in text[:dashed[0]] if l.strip())
        p["body"] = [gutter(l) for l in text[dashed[0] + 1:dashed[1]]]
        p["command"] = "\n".join(p["body"])
        p["reason_lines"] = [l.strip() for l in text[dashed[1] + 1:]]
    else:
        p["desc"] = text[0].strip()
        p["body"] = [gutter(l) for l in text[1:] if not DASHED.match(l)]
        p["command"] = "\n".join(p["body"])
    p["question"] = [body[q].strip()]
    p["options"], p["cursor"] = options(body[q + 1:])


def parse_menu(p, body):
    first = next((i for i, l in enumerate(body) if OPTION.match(l)), None)
    if first is None:
        raise Unreadable("no option rows")
    p["question"] = [gutter(l) for l in body[:first]]
    p["options"], p["cursor"] = options(body[first:])
    p["other"] = next((o["n"] for o in p["options"]
                       if o["label"] in ("Type something.", "Type something")), None)


def tab_title(line):
    if len(re.findall(r"[☐☒]", line)) > 1:
        raise Unreadable(MULTI)
    m = TAB_SINGLE.match(line)
    if not m:
        raise Unreadable("not a single-question checkbox menu")
    return m.group(1)


def parse_checkbox(p, body):
    """The checkbox rules: 1..n without gaps, `Type something` last and unchecked."""
    if sum(1 for l in body if re.match(r"^\s*Submit\s*$", l)) != 1:
        raise Unreadable("missing unique Submit row")
    first = next((i for i, l in enumerate(body) if CHECK_ROW.match(l)), None)
    if first is None:
        raise Unreadable("incomplete option list")
    p["question"] = [gutter(l) for l in body[:first]]
    opts, other, expected, cursor = [], 0, 1, None
    for line in body[first:]:
        if re.match(r"^\s*Submit\s*$", line):
            break
        m = CHECK_ROW.match(line)
        if m:
            n = int(m.group(2))
            if n != expected or other:
                raise Unreadable("incomplete option list")
            if m.group(1):
                cursor = n
            opts.append({"n": n, "label": m.group(4).rstrip(), "desc": [],
                         "checked": m.group(3) == "✔"})
            expected += 1
            if m.group(4).rstrip() == "Type something":
                other = n
                if m.group(3) != " ":
                    raise Unreadable("Other is already selected")
        elif re.match(r"^\s*(❯\s*)?[0-9]+\.", line):
            raise Unreadable("unknown option row")
        elif opts:
            opts[-1]["desc"].append(line.strip())
    if other <= 1:
        raise Unreadable("missing final Type something option")
    if sum(l.count("❯") for l in body) != 1:
        cursor = None
    p["options"], p["cursor"], p["other"] = opts, cursor, other


def is_review(body):
    """A checkbox can quote the review title; only a body without checkbox rows is the review."""
    return any(l.strip() == "Review your answers" for l in body) \
        and not any(CHECK_ROW.match(l) for l in body)


def parse_review(p, lines, top):
    p["title"] = tab_title(lines[top + 1])
    body = lines[top + 2:]
    answers = [l.strip()[2:] for l in body if l.strip().startswith("→ ")]
    p["review"] = {"title": p["title"], "answers": answers,
                   "ready": any("Ready to submit your answers?" in l for l in body),
                   "submit_cursor": any(re.match(r"^\s*❯\s*1\. Submit answers\s*$", l) for l in body),
                   "bullets": sum(1 for l in body if l.strip().startswith("● ")),
                   "unanswered": any("You have not answered all questions" in l for l in body)}
    p["question"] = [l.strip() for l in body]


def idle_surface(lines):
    """Index of the input line when the bottom is the idle input box, else None."""
    for k in range(len(lines) - 1, max(len(lines) - 2 - STATUS_LINES, 1), -1):
        if RULE.match(lines[k]) and INPUT.match(lines[k - 1]) and NAMED_RULE.match(lines[k - 2]):
            # A rule or prompt header below the box is a newer prompt still rendering.
            below = lines[k + 1:]
            if any(NAMED_RULE.match(l) or header_kind(l) or QUESTION.search(l) for l in below):
                return None
            return k - 1
    return None


def input_box(rows):
    """True when the rows hold the input box's top rule over its `❯` line (not an option cursor)."""
    return any(NAMED_RULE.match(rows[i]) and INPUT.match(rows[i + 1])
               and not OPTION.match(rows[i + 1]) for i in range(len(rows) - 1))


def fingerprint(p):
    canon = {"v": 2, "kind": p["kind"], "header": p["header"], "title": p["title"],
             "desc": p["desc"], "body": p["body"], "reason_lines": p["reason_lines"],
             "question": p["question"],
             "options": [[o["n"], o["label"], o["desc"]] for o in p["options"]]}
    blob = json.dumps(canon, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
    return "v2:" + hashlib.sha256(blob.encode()).hexdigest()


def visible_rows(tool, content, overwrite=False):
    """→ [(input key, text)] of the command lines a clipped prompt still shows; an overwrite's
    `-` and context rows are the old file, so only its `+` rows are checked."""
    if tool == "Edit" or overwrite:
        parsed = diff_rows(content)
        if parsed is None:
            raise Unreadable("prompt header not on screen")
        key = {"+": "new_string", "-": "old_string"} if tool == "Edit" else {"+": "content"}
        return [(key[s], t) for s, t in parsed if s in key and squash(t)]
    out = []
    for line in content:
        if tool == "Bash":
            if not GUTTER.match(line):
                raise Unreadable("prompt header not on screen")
            out.append(("command", gutter(line)))
        else:
            m = WRITE_ROW.match(line)
            if not m:
                raise Unreadable("prompt header not on screen")
            out.append(("content", m.group(1)))
    return [(k, t) for k, t in out if squash(t)]


def recover(p, lines, path):
    """A clipped permission prompt bound to the role's unique pending Bash/Edit/Write call."""
    es = entries(path)
    calls = [(n, inp) for n, inp in pending(es or []).values() if n in RECOVER]
    if es is None or len(calls) != 1 or not isinstance(calls[0][1], dict):
        raise Unreadable("prompt header not on screen")
    tool, inp = calls[0]
    q = max((i for i, l in enumerate(lines) if QUESTION.search(l)), default=None)
    m = RECOVER[tool][1].match(lines[q].strip()) if q is not None else None
    if not m or (tool != "Bash"
                 and m.group("n") != os.path.basename(str(inp.get("file_path") or ""))):
        raise Unreadable("prompt header not on screen")
    opts, cursor = options(lines[q + 1:-1])
    dashed = [i for i in range(q) if DASHED.match(lines[i])]
    if not dashed:
        raise Unreadable("prompt header not on screen")
    d = dashed[-1]
    over = tool == "Write" and m.group("v") == "overwrite"
    rows = visible_rows(tool, lines[dashed[-2] + 1 if len(dashed) > 1 else 0:d], over)
    offsets = {}
    for key, text in rows:
        i = squash(inp.get(key)).find(squash(text), offsets.get(key, 0))
        if i < 0:
            raise Unreadable("prompt header not on screen")
        offsets[key] = i + len(squash(text))
    if not rows:
        raise Unreadable("prompt header not on screen")
    command = str(inp.get("command") or "")
    p.update(kind="permission", header="Overwrite file" if over else RECOVER[tool][0], desc="",
             body=command.splitlines() if tool == "Bash" else [str(inp.get("file_path"))],
             command=command, reason_lines=[l.strip() for l in lines[d + 1:q]],
             question=[lines[q].strip()], options=opts, cursor=cursor, recovered="transcript")
    p["fp"] = fingerprint(p)


def classify(p, lines, transcript=None):
    last = lines[-1]
    footer = "permission" if PERM_FOOTER.match(last) else "menu" if MENU_FOOTER in last else None
    if footer:
        top = next(iter(tops(lines, len(lines) - 1)), None)
        kind = header_kind(lines[top + 1]) if top is not None else None
        body = lines[top + 2:-1] if top is not None else []
        # A footer inside the span means the nearest header belongs to an older, quoted prompt.
        if top is None or (footer == "permission") != (kind == "permission") \
                or any(PERM_FOOTER.match(l) or MENU_FOOTER in l for l in body):
            if footer == "permission" and transcript:
                recover(p, lines, transcript)
                return
            raise Unreadable("prompt header not on screen")
        if kind == "checkbox" and is_review(body):
            kind = "review"
        p["kind"], p["header"] = kind, lines[top + 1].strip()
        if kind == "permission":
            parse_permission(p, body)
        elif kind == "menu":
            p["title"] = MENU_HEADER.match(lines[top + 1]).group(2).strip()
            parse_menu(p, body)
        elif kind == "review":
            # Without the footer, so a footered review fingerprints like an unfootered one.
            parse_review(p, lines[:-1], top)
        else:
            p["title"] = tab_title(lines[top + 1])
            parse_checkbox(p, body)
        p["fp"] = fingerprint(p)
        return
    found = tops(lines, len(lines))
    if found and header_kind(lines[found[0] + 1]) == "checkbox" and OPTION.match(last) \
            and is_review(lines[found[0] + 2:]):
        p["kind"], p["header"] = "review", lines[found[0] + 1].strip()
        parse_review(p, lines, found[0])
        p["fp"] = fingerprint(p)
        return
    k = idle_surface(lines)
    if k is not None:
        p["kind"], p["fp"] = "none", "v2:none"
        p["input"] = re.sub(r"^❯\s*", "", lines[k].strip())
        p["input_empty"] = p["input"] == ""
        above = next((l for l in reversed(lines[:k - 1]) if l.strip()), "")
        p["busy"] = p["busy"] or bool(SPINNER.match(above))
        return
    if found:
        # Output or an input box below the header: an old prompt in the scrollback, not a new one.
        after = lines[found[0] + 2:]
        if any(l.lstrip().startswith("⏺") for l in after) or input_box(after):
            raise Unreadable("no idle input surface")
        p["kind"], p["complete"] = header_kind(lines[found[0] + 1]), False
        p["reason"], p["fp"] = "incomplete: prompt still rendering", "v2:unreadable"
        return
    raise Unreadable("no idle input surface")


def strip_ansi(line):
    return CSI.sub("", OSC.sub("", line))


def sgr_dim(params, dim):
    """Dim state after one SGR; extended colour arguments (38;5;2) are not attributes."""
    ps, i = (params.replace(":", ";").split(";") if params else ["0"]), 0
    while i < len(ps):
        p = ps[i] or "0"
        if p in ("38", "48", "58"):
            i += 3 if i + 1 < len(ps) and ps[i + 1] == "5" else 5
            continue
        if p == "2":
            dim = True
        elif p in ("0", "22"):
            dim = False
        i += 1
    return dim


def drop_dim(line):
    line = INVERSE_CELL.sub(lambda m: "" if sgr_dim(m.group(2), False) else m.group(0), line)
    out, dim, pos = [], False, 0
    for m in SGR.finditer(line):
        if not dim:
            out.append(line[pos:m.start()])
        dim, pos = sgr_dim(m.group(1), dim), m.end()
    if not dim:
        out.append(line[pos:])
    return "".join(out)


def normalise(line):
    if "\x1b" not in line:
        return line
    plain = strip_ansi(line)
    if INPUT.match(plain) and not OPTION.match(plain):
        return strip_ansi(drop_dim(line))
    return plain


def screen_lines(text):
    """Non-blank, escape-free lines; blanks are filtered after stripping (escape-only lines)."""
    return [l for l in (normalise(l) for l in text.splitlines()) if l.strip()]


def unbordered(lines):
    return lines[:-1] if lines and BORDER.match(lines[-1]) else lines


def field_text(p, lines):
    """What the active field holds: the menu row under the cursor, or the input box's content."""
    if p["kind"] == "menu" and p["complete"]:
        o = next((o for o in p["options"] if o["n"] == p["cursor"]), None)
        return "" if o is None else squash(o["label"]) + "".join(squash(d) for d in o["desc"])
    if p["kind"] in ("permission", "checkbox", "review"):
        return ""
    # Menus returned above, so a numbered answer ("❯ 1. …") here is typed text, not a cursor row.
    top = next((i for i in range(len(lines) - 2, -1, -1) if NAMED_RULE.match(lines[i])
                and INPUT.match(lines[i + 1])), None)
    end = next((k for k in range(top + 2, len(lines)) if RULE.match(lines[k])), None) \
        if top is not None else None
    if end is None:
        return ""
    return re.sub(r"^❯", "", "".join(squash(gutter(l)) for l in lines[top + 1:end]))


def typed(text, pane):
    """True when the active field holds exactly the text; Ink hard-wraps long input."""
    want = squash(text)
    return bool(want) and field_text(parse(pane), unbordered(screen_lines(pane))) == want


def parse(text, transcript=None):
    lines = screen_lines(text)
    p = {"v": 2, "kind": "unreadable", "complete": True, "reason": "", "fp": "v2:unreadable",
         "header": "", "title": "", "desc": "", "body": [], "reason_lines": [], "question": [],
         "command": "", "options": [], "cursor": None, "other": None,
         "busy": any("esc to interrupt" in l for l in lines[-BUSY_LINES:]), "review": None,
         "input_empty": None, "input": None, "recovered": None}
    lines = unbordered(lines)
    try:
        if not lines:
            raise Unreadable("empty capture")
        classify(p, lines, transcript)
    except Unreadable as e:
        p.update(kind="unreadable", complete=False, reason="unreadable: %s" % e,
                 fp="v2:unreadable")
    return p


def main():
    a = sys.argv[1:]
    if a == ["parse"] or (len(a) == 3 and a[:2] == ["parse", "--transcript"]):
        t = a[2] if len(a) == 3 and a[2] != "-" else None
        print(json.dumps(parse(sys.stdin.read(), t), ensure_ascii=False))
        return 0
    if len(a) == 3 and a[0] == "event" and a[2] in ("permission", "menu", "blocked", "idle"):
        if a[2] in ("blocked", "idle"):
            print(last_assistant(a[1]))
        else:
            print(associated(json.loads(sys.stdin.read()), a[1])[0])
        return 0
    if len(a) == 3 and a[0] == "result":
        print("yes" if has_result(a[1], a[2]) else "no")
        return 0
    if len(a) == 3 and a[0] == "pending":
        es = entries(a[1])
        print("unknown" if es is None else "yes" if a[2] in pending(es) else "no")
        return 0
    if len(a) == 4 and a[0] == "user-after":
        print("yes" if user_after(a[1], a[2], a[3]) else "no")
        return 0
    if len(a) == 2 and a[0] == "typed":
        print("yes" if typed(a[1], sys.stdin.read()) else "no")
        return 0
    if a == ["strip"]:
        sys.stdout.write("".join(strip_ansi(l) for l in sys.stdin.read().splitlines(True)))
        return 0
    print(__doc__.strip().split("\n\n")[1], file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())
