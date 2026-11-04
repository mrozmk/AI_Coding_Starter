"""Settings-edit checks of the classes allow-offline and add-ask.

Imported by team_prompt_classes.py (classes) and team_prompt_check.py (the settings refusal).
Reads only: the edit is simulated on the clone's settings.json text, never written.
"""
import json
import os
import re

PATH = re.compile(r"[A-Za-z0-9._/-]+")
SETTINGS_NAMES = ("settings.json", "settings.local.json")


def settings_target(clone, path):
    """Identification only: any alias (symlink, `..`, letter case) of a clone settings file."""
    if not isinstance(path, str) or not path:
        return None
    real = os.path.realpath(os.path.join(clone, path))
    for name in SETTINGS_NAMES:
        target = os.path.join(clone, ".claude", name)
        if real.lower() == os.path.realpath(target).lower():
            return name
        try:
            if os.path.samefile(real, target):
                return name
        except OSError:
            pass
    return None


def settings_link(clone, path):
    """True when the path is not the plain clone settings.json: classes 2/3 then answer none."""
    plain = os.path.join(os.path.realpath(clone), ".claude", "settings.json")
    full = os.path.join(clone, path)
    return os.path.realpath(full) != plain or os.path.islink(full) \
        or os.path.islink(os.path.dirname(full))


def unique_pairs(pairs):
    keys = [k for k, _ in pairs]
    if len(keys) != len(set(keys)):
        raise ValueError("duplicate key")
    return dict(pairs)


def simulate(clone, tool, inp):
    """→ (old, new) parsed settings.json before and after the edit, or None."""
    try:
        with open(os.path.join(clone, ".claude", "settings.json"), encoding="utf-8") as fh:
            text = fh.read()
        old = json.loads(text, object_pairs_hook=unique_pairs)
    except (OSError, ValueError):
        return None
    if tool == "Edit":
        o, n, every = inp.get("old_string"), inp.get("new_string"), inp.get("replace_all") is True
        if not isinstance(o, str) or not isinstance(n, str) or not o:
            return None
        count = text.count(o)
        if count == 0 or (count > 1 and not every):
            return None
        new_text = text.replace(o, n) if every else text.replace(o, n, 1)
    else:
        new_text = inp.get("content")
        if not isinstance(new_text, str):
            return None
    try:
        new = json.loads(new_text, object_pairs_hook=unique_pairs)
    except ValueError:
        return None
    return (old, new) if isinstance(old, dict) and isinstance(new, dict) else None


def added_only(old, new, key):
    """Entries added to permissions.<key> when nothing else changed, else None."""
    def rest(d):
        d = json.loads(json.dumps(d))
        if isinstance(d.get("permissions"), dict):
            d["permissions"].pop(key, None)
        return json.dumps(d, sort_keys=True)
    lists = [((d.get("permissions") or {}) if isinstance(d.get("permissions"), dict) else None)
             for d in (old, new)]
    if None in lists or rest(old) != rest(new):
        return None
    was, now = lists[0].get(key, []), lists[1].get(key, [])
    if not isinstance(was, list) or not isinstance(now, list) \
            or not all(isinstance(e, str) for e in now) or len(set(now)) != len(now) \
            or any(e not in now for e in was):
        return None
    added = [e for e in now if e not in was]
    return added or None


def path_ok(p):
    return bool(PATH.fullmatch(p)) and ".." not in p and not p.startswith(("-", "/"))


def allow_paths(entry):
    """→ paths of an allow-offline entry, or None for any other form. Running a script is not
    offline-provable from its text, so `Bash(bash <script>)` is the Operator's (decision E)."""
    m = re.fullmatch(r"Bash\(bash -n (\S+)\)", entry)
    if m:
        return [m.group(1)]
    m = re.fullmatch(r"Bash\(shellcheck (?:-x )?(\S+(?: \S+)*)\)", entry)
    return m.group(1).split(" ") if m else None
