"""Settings changes of a team PR for the auto-merge gate.

Usage: python3 -I team_settings_diff.py <clone> <main> <target-sha> <source-sha>
Compares .claude/settings.json at merge-base(target, source) and source inside the clone. Prints
nothing when no tracked .claude/**/*settings*.json changed, else one `settings.json: …` line.
Exit 0 pass · 1 needs the Operator (line ends ` — refuse: <reason>`) · 2 usage or a failed git
read. Only added allow-offline entries pass; added ask/deny and removed allow are reported.
Run from the main checkout's lib: every git read goes through the hardened git() (no replace
refs, hooks or fsmonitor), merge-base also ignores grafts and the commit-graph; <main> supplies
only the allow-offline class switch.
"""
import fnmatch
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "hooks", "lib"))
sys.path.insert(0, HERE)
from team_prompt_classes import git, switch_on  # noqa: E402
from team_prompt_settings import allow_paths, path_ok, unique_pairs  # noqa: E402

SETTINGS = ".claude/settings.json"
KEYS = ("allow", "ask", "deny")


class GitError(Exception):
    pass


class Refuse(Exception):
    pass


def is_settings(p):
    # Lowercased: a case variant is the same file on the main checkout's case-insensitive FS.
    q = p.lower()
    return q.startswith(".claude/") and fnmatch.fnmatchcase(os.path.basename(q), "*settings*.json")


def changed_paths(clone, base, src):
    # -z: without it git quotes a non-ASCII path and is_settings() would miss it.
    out = git(clone, "diff", "--no-ext-diff", "--no-textconv", "--no-renames", "--name-only",
              "-z", base, src)
    if out is None:
        raise GitError("cannot diff %s..%s" % (base, src))
    return {l for l in out.split("\0") if l}


def settings_text(clone, rev):
    """→ the settings.json text at rev, or None when the file is absent there."""
    listed = git(clone, "ls-tree", rev, "--", SETTINGS)
    if listed is None:
        raise GitError("cannot list %s" % rev)
    if not listed.strip():
        return None
    text = git(clone, "cat-file", "blob", "%s:%s" % (rev, SETTINGS))
    if text is None:
        raise GitError("cannot read %s:%s" % (rev, SETTINGS))
    return text


def parse(text):
    """→ settings dict; Refuse on an unreadable shape."""
    try:
        d = json.loads(text, object_pairs_hook=unique_pairs)
    except ValueError as e:
        raise Refuse("JSON unreadable (%s)" % e)
    if not isinstance(d, dict):
        raise Refuse("JSON is not an object")
    return d


def lists(d):
    """→ {allow|ask|deny: [str]}; Refuse on a wrong shape."""
    perms = d.get("permissions", {})
    if not isinstance(perms, dict):
        raise Refuse("permissions is not an object")
    out = {}
    for k in KEYS:
        v = perms.get(k, [])
        if not isinstance(v, list) or not all(isinstance(e, str) for e in v):
            raise Refuse("permissions.%s is not a list of strings" % k)
        out[k] = v
    return out


def rest_keys(old, new):
    """Names of the settings that differ outside permissions.allow/ask/deny."""
    def rest(d):
        d = json.loads(json.dumps(d))
        if isinstance(d.get("permissions"), dict):
            for k in KEYS:
                d["permissions"].pop(k, None)
        return d
    a, b = rest(old), rest(new)
    names = []
    for k in sorted(set(a) | set(b)):
        if json.dumps(a.get(k), sort_keys=True) == json.dumps(b.get(k), sort_keys=True):
            continue
        if k == "permissions" and isinstance(a.get(k), dict) and isinstance(b.get(k), dict):
            pa, pb = a[k], b[k]
            names += ["permissions.%s" % p for p in sorted(set(pa) | set(pb))
                      if json.dumps(pa.get(p), sort_keys=True)
                      != json.dumps(pb.get(p), sort_keys=True)]
        else:
            names.append(k)
    return names


def allow_problems(entries, changed, root):
    if entries and not switch_on(root, "allow-offline"):
        return ["class allow-offline is off"]
    out = []
    for e in entries:
        found = allow_paths(e)
        if found is None or not all(path_ok(p) for p in found):
            out.append("allow entry %s is not an offline check of one file" % e)
        elif not all(p in changed for p in found):
            out.append("allow entry %s names a file outside the PR diff" % e)
    return out


def summary(added, removed):
    counts = ["+%d %s" % (len(added[k]), k) for k in KEYS if added[k]]
    counts += ["−%d %s" % (len(removed[k]), k) for k in KEYS if removed[k]]
    entries = ["+%s %s" % (k, e) for k in KEYS for e in added[k]]
    entries += ["−%s %s" % (k, e) for k in KEYS for e in removed[k]]
    if not counts:
        return "settings.json: no permission change"
    return "settings.json: %s — %s" % (", ".join(counts), "; ".join(entries))


def compare(clone, root, base, src, changed):
    """→ (line, refusal reasons) for a PR that touched some tracked settings file."""
    problems = ["%s changed" % p for p in sorted(changed) if p != SETTINGS and is_settings(p)]
    empty = {k: [] for k in KEYS}
    if SETTINGS not in changed:
        return summary(empty, empty), problems
    old_text, new_text = settings_text(clone, base), settings_text(clone, src)
    if new_text is None:
        return "settings.json: deleted", problems + ["settings.json deleted"]
    try:
        old, new = parse(old_text or "{}"), parse(new_text)
        was, now = lists(old), lists(new)
    except Refuse as e:
        return "settings.json: unreadable", problems + [str(e)]
    added = {k: [e for e in now[k] if e not in was[k]] for k in KEYS}
    removed = {k: [e for e in was[k] if e not in now[k]] for k in KEYS}
    problems += ["%s entry removed: %s" % (k, e) for k in ("deny", "ask") for e in removed[k]]
    problems += allow_problems(added["allow"], changed, root)
    problems += ["%s changed" % k for k in rest_keys(old, new)]
    return summary(added, removed), problems


def main(argv):
    if len(argv) != 5:
        print(__doc__.strip().splitlines()[2], file=sys.stderr)
        return 2
    clone, root, tgt, src = argv[1:]
    # Grafts and a commit-graph in the clone are role-writable ancestry, like refs/replace.
    os.environ["GIT_GRAFT_FILE"] = os.devnull
    try:
        base = git(clone, "-c", "core.commitGraph=false", "merge-base", tgt, src)
        if not base:
            raise GitError("no merge-base of %s and %s" % (tgt, src))
        base = base.strip()
        changed = changed_paths(clone, base, src)
        if not any(is_settings(p) for p in changed):
            return 0
        line, problems = compare(clone, root, base, src, changed)
    except GitError as e:
        print("settings check: %s" % e, file=sys.stderr)
        return 2
    if problems:
        print("%s — refuse: %s" % (line, "; ".join(problems)))
        return 1
    print(line)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
