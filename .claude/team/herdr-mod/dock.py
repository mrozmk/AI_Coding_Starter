"""Dock or undock the harness-notify strip in one Herdr layout file (called by install.sh).

Usage: python3 -I dock.py dock|undock|check <layout.json> → the new layout JSON on stdout
  exit 0 a new layout on stdout · 4 nothing to do (already docked / nothing to undock), stdout
  empty · 3 refused (unparsable, not a layout, our block not found unambiguously), the reason on
  stderr. check: 0 docked · 4 not docked · 3 ambiguous. Never writes a file.

A root column gets the strip as its last child. Any other root is wrapped in a new root column
whose first child is the old root; the root-only and look keys (Herdr reads them from the root
only) stay on the new root, so the window keeps its own title bar setting and its look. Herdr's
own first-load dock moved them into the inner node, which showed the system title band.
Undock removes exactly that: the strip block, and the wrapper when it is still ours with one
other child (its keys go back onto that child). An owner's edit around it is kept (an owner's node
left without children stays, with a note; a wrapper the owner gave another child stays too, silently,
as theirs now); a strip that cannot be found exactly once, a wrapper whose keys clash with the
layout inside, or a wrapper that would be left empty, is refused.
"""
import json
import sys

STRIP = "harness-notify-strip"
WRAP = "harness-notify-dock"
MOD = "harness-notify"
# Herdr reads these from the root only (titlebar, traffic_lights, preview, menus) or applies the
# root's look only ("today only the root's look applies").
ROOT_KEYS = ("titlebar", "traffic_lights", "preview", "terminal_menu", "toast", "cloned_from",
             "theme", "colors", "font", "font_size", "ui_font", "terminal_padding",
             "terminal_opacity", "background", "movable")


class Refuse(Exception):
    pass


def strips(node, parent=None, out=None):
    """Every (node, parent) whose block is our strip, by id or by mod."""
    out = [] if out is None else out
    if isinstance(node, dict):
        content = node.get("content") if isinstance(node.get("content"), dict) else {}
        if node.get("id") == STRIP or content.get("mod") == MOD:
            out.append((node, parent))
        for k in ("children", "floating"):
            for c in node.get(k) or []:
                strips(c, node, out)
    return out


def load(path):
    try:
        with open(path, encoding="utf-8") as f:
            data = json.load(f)
    except OSError as e:
        raise Refuse("cannot read %s: %s" % (path, e.strerror))
    except ValueError as e:
        raise Refuse("%s is not valid JSON (%s) — left as it is" % (path, e))
    if not isinstance(data, dict) or data.get("type") not in ("row", "column", "stack", "block"):
        raise Refuse("%s is not a Herdr layout (no root type) — left as it is" % path)
    return data


def dock(root):
    if strips(root):
        return None
    block = {"type": "block", "id": STRIP, "size": {"px": 26}, "content": {"mod": MOD}}
    if root.get("type") == "column":
        root.setdefault("children", []).append(block)
        return root
    inner = {k: v for k, v in root.items() if k not in ROOT_KEYS}
    outer = {"type": "column", "id": WRAP, "resizable": False}
    outer.update({k: root[k] for k in ROOT_KEYS if k in root})
    outer["children"] = [inner, block]
    return outer


def undock(root):
    found = strips(root)
    if not found:
        return None
    if len(found) > 1:
        raise Refuse("the strip appears %d times — remove the extra ones by hand" % len(found))
    node, parent = found[0]
    if parent is None:
        raise Refuse("the strip is the whole layout — left as it is")
    if node in (parent.get("children") or []):
        parent["children"].remove(node)
    else:
        parent["floating"].remove(node)
    if not parent.get("children") and not parent.get("floating") and parent is not root:
        # Not ours (it may have been empty before the dock too): kept, and said.
        print("note: %s has no children now — it is yours, left in place"
              % (parent.get("id") or "a node"), file=sys.stderr)
    if root.get("id") == WRAP:
        kids = root.get("children") or []
        if len(kids) == 1 and isinstance(kids[0], dict):
            inner = kids[0]
            moved = {k: v for k, v in root.items() if k not in ("type", "id", "resizable", "children")}
            clash = [k for k in moved if k in inner and inner[k] != moved[k]]
            if clash:
                raise Refuse("the wrapper and the layout inside both set %s — undock by hand"
                             % ", ".join(sorted(clash)))
            inner.update(moved)
            return inner
        if not kids:
            raise Refuse("the wrapper %s would be left empty — undock by hand" % WRAP)
    elif not root.get("children") and not root.get("floating"):
        raise Refuse("removing the strip would leave the layout empty — undock by hand")
    return root


def main(argv):
    if len(argv) != 3 or argv[1] not in ("dock", "undock", "check"):
        print(__doc__.strip().split("\n\n")[0], file=sys.stderr)
        return 2
    try:
        root = load(argv[2])
        if argv[1] == "check":
            n = len(strips(root))
            if n > 1:
                raise Refuse("the strip appears %d times" % n)
            return 0 if n == 1 else 4
        new = dock(root) if argv[1] == "dock" else undock(root)
    except Refuse as e:
        print("error: %s" % e, file=sys.stderr)
        return 3
    if new is None:
        return 4
    json.dump(new, sys.stdout, indent=2, ensure_ascii=False)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
