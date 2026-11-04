"""Binds a parsed team prompt to its role transcript event (split from team_prompt.py).

Library only, imported by team_prompt.py: entries/pending read the role's JSONL transcript,
associated finds the one pending tool_use a visible prompt belongs to.
"""
import json
import os
import re

TOOLS = {"Bash command": "Bash", "Edit file": "Edit", "Write file": "Write", "Create file": "Write",
         "Overwrite file": "Write", "Read file": "Read", "Fetch": "WebFetch",
         "WebFetch": "WebFetch"}
FILE_QUESTION = re.compile(r"^Do you want to (make this edit to|create|overwrite) (?P<n>.+)\?$")
EDIT_ROW = re.compile(r"^\s*\d+\s([+-])(.*)$")
# A blank context row is its number alone once the parser strips the line's trailing spaces.
CONTEXT_ROW = re.compile(r"^\s*\d+(\s\s|\s*$)")
# Ink wraps a long diff row without its line number and repeats the +/- marker.
CONT_ROW = re.compile(r"^\s+([+-])(.*)$")


def entries(path):
    """Transcript entries of type assistant/user; None when any line is not JSON."""
    out = []
    try:
        with open(path, encoding="utf-8") as fh:
            for line in fh:
                if not line.strip():
                    continue
                e = json.loads(line)
                if isinstance(e, dict) and e.get("type") in ("assistant", "user"):
                    out.append(e)
    except (OSError, ValueError):
        return None
    return out


def content(e):
    c = (e.get("message") or {}).get("content")
    return c if isinstance(c, list) else []


def pending(es):
    open_calls = {}
    for e in es:
        for item in content(e):
            if not isinstance(item, dict):
                continue
            if e["type"] == "assistant" and item.get("type") == "tool_use":
                open_calls[item.get("id")] = (item.get("name"), item.get("input") or {})
            elif e["type"] == "user" and item.get("type") == "tool_result":
                open_calls.pop(item.get("tool_use_id"), None)
    return open_calls


def squash(s):
    return "".join(str(s or "").split())


def diff_rows(rows):
    """→ [(side, text)] of visible diff rows in display order, None for a row that is not one."""
    out, side = [], None
    for row in rows:
        m, ctx, cont = EDIT_ROW.match(row), CONTEXT_ROW.match(row), CONT_ROW.match(row)
        if m:
            side, text = m.group(1), m.group(2)
        elif ctx:
            side, text = " ", row[ctx.end():]
        elif cont:
            if side != cont.group(1):
                return None
            text = cont.group(2)
        # A dim `...` row separates hunks: the rows between them are hidden.
        elif side == " " and row[:1].isspace() and row.strip() not in ("...", "…"):
            text = row
        else:
            return None
        out.append((side, text))
    return out


def diff_sides(rows):
    """→ (old, new) squashed text of visible diff rows in display order, None for another row."""
    parsed = diff_rows(rows)
    if parsed is None:
        return None
    return ("".join(squash(t) for s, t in parsed if s in "- "),
            "".join(squash(t) for s, t in parsed if s in "+ "))


def in_order(parts, text):
    at = 0
    for part in parts:
        i = text.find(part, at)
        if i < 0:
            return False
        at = i + len(part)
    return True


def shown_edits(p, es, cands):
    """Candidates whose file is the screen's path line and whose whole edit lies in the diff;
    another candidate the visible changed rows also fit leaves the full list (ambiguous)."""
    rows = diff_rows(p.get("body") or [])
    if rows is None:
        return cands
    sides = diff_sides(p["body"])
    changed = [[squash(t) for s, t in rows if s == k] for k in "-+"]
    cwds = {i.get("id"): e.get("cwd") for e in es if e["type"] == "assistant"
            for i in content(e) if isinstance(i, dict) and i.get("type") == "tool_use"}

    def same_file(tid, inp):
        shown = os.path.expanduser(p.get("desc") or "")
        if not os.path.isabs(shown):
            if not cwds.get(tid):
                return False
            shown = os.path.join(cwds[tid], shown)
        return os.path.normpath(shown) == os.path.normpath(str(inp.get("file_path") or ""))
    # A longer edit shown only in part fits the screen as well as a short one shown whole.
    fits = [(i, inp) for i, inp in cands if same_file(i, inp)
            and in_order(changed[0], squash(inp.get("old_string")))
            and in_order(changed[1], squash(inp.get("new_string")))]
    full = [(i, inp) for i, inp in fits if squash(inp.get("old_string")) in sides[0]
            and squash(inp.get("new_string")) in sides[1]]
    return full if len(full) == len(fits) else cands


def associated(p, path):
    """(token, tool input) of the pending tool_use the visible prompt belongs to."""
    es = entries(path)
    if es is None:
        return "-", None
    calls = pending(es)
    if p.get("kind") == "permission":
        tool = TOOLS.get(p.get("header"))
        cands = [(i, inp) for i, (n, inp) in calls.items() if n == tool]
        if tool == "Bash":
            cands = [(i, inp) for i, inp in cands if squash(inp.get("command")) == squash(p["command"])
                     and (not inp.get("description") or not p.get("desc")
                          or squash(inp.get("description")) == squash(p["desc"]))]
        elif tool in ("Edit", "Write"):
            m = FILE_QUESTION.match((p.get("question") or [""])[0])
            cands = [(i, inp) for i, inp in cands if m
                     and m.group("n") == os.path.basename(str(inp.get("file_path") or ""))]
            if tool == "Edit" and len(cands) > 1:
                # Parallel tool_uses can edit one file: only the shown path and diff decide.
                cands = shown_edits(p, es, cands)
    elif p.get("kind") in ("menu", "checkbox"):
        want = squash(" ".join(p.get("question") or []))
        cands = []
        for i, (n, inp) in calls.items():
            qs = inp.get("questions") if n == "AskUserQuestion" else None
            if qs and isinstance(qs[0], dict) and squash(qs[0].get("question")) == want:
                cands.append((i, inp))
    else:
        return "-", None
    if len(cands) != 1:
        return "ambiguous", None
    return cands[0]


def tool_cwd(path, tid):
    """The shell cwd Claude Code recorded on the entry that holds tool_use <tid>, or None."""
    for e in entries(path) or []:
        if e["type"] == "assistant" and any(isinstance(i, dict) and i.get("type") == "tool_use"
                                            and i.get("id") == tid for i in content(e)):
            return e.get("cwd")
    return None


def last_assistant(path):
    es = entries(path)
    uid = next((e.get("uuid") for e in reversed(es or []) if e["type"] == "assistant"), None)
    return uid or "-"


def has_result(path, tid):
    return any(item.get("type") == "tool_result" and item.get("tool_use_id") == tid
               for e in entries(path) or [] if e["type"] == "user"
               for item in content(e) if isinstance(item, dict))


def user_after(path, uid, text):
    want, seen = text[:40], False
    for e in entries(path) or []:
        if seen and e["type"] == "user":
            c = (e.get("message") or {}).get("content")
            texts = [c] if isinstance(c, str) else [i.get("text", "") for i in content(e)
                                                    if isinstance(i, dict) and i.get("type") == "text"]
            if any(t.startswith(want) for t in texts):
                return True
        seen = seen or e.get("uuid") == uid
    return False
