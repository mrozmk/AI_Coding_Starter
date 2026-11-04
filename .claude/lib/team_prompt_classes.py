"""Deterministic ask-tier classes the TeamLead may approve at tier 1.

Usage: python3 -I team_prompt_classes.py names              → one class name per line
       python3 -I team_prompt_classes.py switches <main>    → merge-line=on allow-offline=on …
Library: classify(clone, main, header, inp, cwd, matches, session) → (name, "") | (None, reason),
called only by team_prompt_check.py --classes. Trusted inputs come from <main>: the runner anchor
.agents/team/anchors/<team>.json, the CLAUDE.md Branch model, the committed profile
(.claude/project-profile.json → teams.branch_types, teams.policy.classes) and the watch/state.json
switches; clone files (team.json, records, refs) are only compared against them. Nothing is executed.

prod-diagnose is project policy: it exists only when the profile names its script directory —
teams.policy.classes.prod_diagnose = {"dir": "scripts/ops/", "privileged": "<regex>"} — where
`privileged` names the write wrappers a diagnose script must not mention. No config → no class.
"""
import hashlib
import json
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "hooks", "lib"))
sys.path.insert(0, HERE)
from guard_destructive_sql import SEPARATORS, commands, tokenize  # noqa: E402
from team_prompt_settings import (  # noqa: E402
    added_only, allow_paths, path_ok, settings_link, settings_target, simulate)

CLASSES = ("merge-line", "allow-offline", "add-ask", "prod-diagnose")
MERGE_MSG = re.compile(r"[A-Za-z0-9 ._:/#-]+")
TYPE_WORD = re.compile(r"[a-z][a-z0-9-]*")
DIAG_DIR = re.compile(r"[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*/")
DIAG_ARG = re.compile(r"[A-Za-z0-9._:/=,@+-]+")
CODE_SPAN = re.compile(r"`([^`\n]+)`")


def profile_teams(main):
    """The committed profile's `teams` block from <main>, or {}."""
    p = read_json(os.path.join(main, ".claude", "project-profile.json")) or {}
    t = p.get("teams")
    return t if isinstance(t, dict) else {}


def branch_types(main):
    """^(<type>|…)/ from teams.branch_types, or None when the profile names none."""
    types = profile_teams(main).get("branch_types")
    if not isinstance(types, list) or not types \
            or not all(isinstance(t, str) and TYPE_WORD.fullmatch(t) for t in types):
        return None
    return re.compile(r"^(%s)/" % "|".join(types))


def diagnose_config(main):
    """(dir, privileged regex) of the prod-diagnose class, or None when it is not configured."""
    c = ((profile_teams(main).get("policy") or {}).get("classes") or {}).get("prod_diagnose")
    if not isinstance(c, dict):
        return None
    d, priv = c.get("dir"), c.get("privileged")
    if not isinstance(d, str) or not DIAG_DIR.fullmatch(d) or d.startswith((".", "/")) \
            or ".." in d.split("/") or not isinstance(priv, str) or not priv:
        return None
    try:
        return d, re.compile(priv)
    except re.error:
        return None


def switch_on(main, name):
    """team_class_on semantics: absent file/classes/key → on; unreadable or not "on" → off."""
    f = os.path.join(main, ".agents", "team", "watch", "state.json")
    if not os.path.exists(f):
        return True
    try:
        with open(f, encoding="utf-8") as fh:
            st = json.load(fh)
    except (OSError, ValueError):
        return False
    if not isinstance(st, dict):
        return False
    if "classes" not in st:
        return True
    c = st["classes"]
    if not isinstance(c, dict):
        return False
    return name not in c or c[name] == "on"


def branch_model(main):
    """{Integration, Maintenance, Retired, Protected} names from <main>/CLAUDE.md, or None."""
    try:
        with open(os.path.join(main, "CLAUDE.md"), encoding="utf-8") as fh:
            text = fh.read().splitlines()
    except OSError:
        return None
    out = {}
    for key in ("Integration", "Maintenance", "Retired", "Protected"):
        line = next((l for l in text if l.startswith("**%s:**" % key)), "")
        if key != "Protected":
            line = line.split(" — ")[0]
        out[key] = CODE_SPAN.findall(line)
    return out if out["Integration"] and out["Protected"] else None


def read_json(path):
    try:
        with open(path, encoding="utf-8") as fh:
            v = json.load(fh)
    except (OSError, ValueError):
        return None
    return v if isinstance(v, dict) else None


def git(repo, *args, raw=False):
    """stdout of a git read that cannot run clone-configured code or honour replace refs."""
    r = subprocess.run(["git", "--no-replace-objects", "-c", "core.fsmonitor=false",
                        "-c", "core.hooksPath=/dev/null", "-C", repo, *args],
                       capture_output=True, text=not raw, check=False,
                       env={**os.environ, "GIT_NO_REPLACE_OBJECTS": "1"})
    return r.stdout if r.returncode == 0 else None


def replace_refs(clone):
    out = git(clone, "for-each-ref", "refs/replace")
    return out is None or out.strip() != ""


def line_rev(main, line):
    """The trusted line revision: the clone's origin/<line> is rewritable by `git fetch .`."""
    out = git(main, "rev-parse", "--verify", "--quiet", "origin/%s^{commit}" % line)
    return out.strip() if out else None


def diff_set(clone, main, line):
    """→ (merge-base, staged ∪ untracked paths), or None; in_ticket adds the unstaged edits."""
    rev = line_rev(main, line)
    base = git(clone, "merge-base", "HEAD", rev) if rev else None
    if not base:
        return None
    # --cached never reads the working tree, so no clone-configured clean filter can run.
    d = git(clone, "diff", "--cached", "--no-ext-diff", "--no-textconv", "--name-only",
            base.strip())
    o = git(clone, "ls-files", "--others", "--exclude-standard")
    if d is None or o is None:
        return None
    return base.strip(), {l for l in d.splitlines() + o.splitlines() if l}


def in_ticket(clone, diff, rel):
    """rel is in the diff, or its bytes on disk differ from the merge-base (hashed here)."""
    base, paths = diff
    if rel in paths:
        return True
    full = os.path.join(os.path.realpath(clone), rel)
    if not os.path.lexists(full):
        return False
    row = (git(clone, "ls-tree", base, "--", rel) or "").split()
    try:
        with open(full, "rb") as fh:
            return len(row) < 3 or blob_id(fh.read()) != row[2]
    except OSError:
        return True


def simple_words(cmd):
    """Words of exactly one simple command, judged on the raw text before any normalisation."""
    if not isinstance(cmd, str) or any(ord(c) < 0x20 or ord(c) == 0x7f for c in cmd):
        return None
    try:
        toks = tokenize(cmd)
    except ValueError:
        return None
    # commands() drops separator tokens, so `git merge … &` would yield the same words.
    if any((t and set(t) <= SEPARATORS | {"<"}) or t.startswith(">") or "$(" in t or "`" in t
           for t in toks):
        return None
    cmds = list(commands(toks))
    return cmds[0] if len(cmds) == 1 else None


def same_dir(a, b):
    return isinstance(a, str) and bool(a) and os.path.realpath(a) == os.path.realpath(b)


def anchor_team(clone, main):
    """The team whose runner anchor records this clone's path (teams.clone_name is a template, so
    the clone's directory name alone does not name the team); "" when no anchor claims it."""
    d = os.path.join(main, ".agents", "team", "anchors")
    real = os.path.realpath(clone)
    try:
        names = sorted(n for n in os.listdir(d) if n.endswith(".json"))
    except OSError:
        return ""
    hits = [n[:-5] for n in names if (read_json(os.path.join(d, n)) or {}).get("clone") == real]
    return hits[0] if len(hits) == 1 else ""


def context(clone, main, session):
    """→ (ctx, "") when the clone's state agrees with the runner anchor, else (None, reason)."""
    team = anchor_team(clone, main)
    tj = read_json(os.path.join(clone, ".agents", "team", "team.json"))
    try:
        with open(os.path.join(clone, ".agents", "team", "run"), encoding="utf-8") as fh:
            run = fh.read().strip()
    except OSError:
        run = None
    if tj is None or not run:
        return None, "clone team state unreadable"
    a = read_json(os.path.join(main, ".agents", "team", "anchors", team + ".json")) if team else None
    if a is None:
        return None, "no runner anchor"
    if a.get("mismatch") or tj.get("team") != team \
            or any(a.get(k) != tj.get(k) for k in ("ticket", "branch", "line")):
        return None, "clone team.json differs from the runner anchor"
    if a.get("run") != run or not session or a.get("session_id") != session:
        return None, "run or session differs from the runner anchor"
    model = branch_model(main)
    if model is None:
        return None, "Branch model unreadable"
    return {"team": team, "line": a["line"], "branch": a["branch"], "run": run,
            "anchor": a, "model": model}, ""


def merge_line(ctx, words, cwd, clone, main):
    line, m = ctx["line"], ctx["model"]
    rest = words[4:]
    if words[:4] != ["git", "merge", "--no-ff", "origin/" + line] or not (
            rest in ([], ["--no-edit"])
            or (len(rest) == 2 and rest[0] == "-m" and MERGE_MSG.fullmatch(rest[1]))):
        return "not git merge --no-ff origin/%s [--no-edit|-m <msg>]" % line
    if line not in m["Integration"] + m["Maintenance"]:
        return "%s is not an integration or maintenance line" % line
    types = branch_types(main)
    if types is None:
        return "teams.branch_types unreadable"
    branch = (git(clone, "branch", "--show-current") or "").strip()
    if branch != ctx["branch"] or branch == line or not types.match(branch) \
            or branch in m["Protected"] + m["Retired"]:
        return "branch %s is not the team's working branch" % (branch or "(detached)")
    if not same_dir(cwd, clone):
        return "shell cwd is not the clone root"
    trusted = line_rev(main, line)
    got = git(clone, "rev-parse", "--verify", "--quiet", "origin/%s^{commit}" % line)
    if not trusted or (got or "").strip() != trusted:
        return "clone origin/%s differs from the main checkout" % line
    if replace_refs(clone):
        return "clone has replace refs"
    return ""


def allow_offline(clone, main, ctx, old, new):
    added = added_only(old, new, "allow")
    if added is None:
        return "not an allow-only edit"
    diff = diff_set(clone, main, ctx["line"])
    if diff is None:
        return "ticket diff unreadable"
    for entry in added:
        found = allow_paths(entry)
        if found is None or not all(path_ok(p) for p in found):
            return "allow entry %s is not an offline check of one file" % entry
        if not all(in_ticket(clone, diff, p) for p in found):
            return "allow entry %s names a file outside the ticket diff" % entry
    return ""


def blob_id(data):
    return hashlib.sha1(b"blob %d\0" % len(data) + data).hexdigest()


def provenance(clone, main, rev, mon):
    """"" when the diagnose directory in the clone is byte-identical to the trusted line."""
    tree = git(main, "ls-tree", "-r", rev, mon)
    if tree is None:
        return "diagnose tree unreadable"
    want = {}
    for row in tree.splitlines():
        meta, _, name = row.partition("\t")
        want[name] = meta.split()[-1]
    # Every file on disk, git-ignored ones too: the clone's ignore files are role-writable.
    root = os.path.realpath(clone)
    have = {os.path.relpath(os.path.join(d, f), root)
            for d, dirs, files in os.walk(os.path.join(root, mon)) for f in files
            + [x for x in dirs if os.path.islink(os.path.join(d, x))]}
    if set(want) != have:
        return "diagnose files differ from the line"
    for name, oid in want.items():
        full = os.path.join(root, name)
        try:
            if os.path.realpath(full) != full:
                return "%s is a link" % name
            with open(full, "rb") as fh:
                if blob_id(fh.read()) != oid:
                    return "%s differs from the line" % name
        except OSError:
            return "%s unreadable" % name
    return ""


def planned(clone, ctx, command):
    """True when the command is a code span or fenced line of the accepted planner artifacts."""
    a = ctx["anchor"]
    pl = a.get("planner")
    if not isinstance(pl, dict) or pl.get("run") != a.get("run") or not pl.get("output_rev"):
        return False
    for path in pl.get("artifacts") or []:
        if not isinstance(path, str) or path.startswith("-"):
            continue
        text = git(clone, "cat-file", "blob", "%s:%s" % (pl["output_rev"], path))
        fenced = False
        for line in (text or "").splitlines():
            if line.strip().startswith("```"):
                fenced = not fenced
            elif (fenced and line.strip() == command) or command in CODE_SPAN.findall(line):
                return True
    return False


def prod_diagnose(ctx, words, cwd, clone, main):
    cfg = diagnose_config(main)
    if cfg is None:
        return "prod-diagnose not configured (teams.policy.classes.prod_diagnose)"
    mon, privileged = cfg
    script = re.compile(re.escape(mon) + r"[a-z0-9-]+-diagnose\.sh")
    if len(words) < 2 or words[0] != "bash" or not script.fullmatch(words[1]) \
            or not all(DIAG_ARG.fullmatch(w) for w in words[2:]):
        return "not bash %s<name>-diagnose.sh <plain args>" % mon
    if not same_dir(cwd, clone):
        return "shell cwd is not the clone root"
    if replace_refs(clone):
        return "clone has replace refs"
    rev = line_rev(main, ctx["line"])
    why = provenance(clone, main, rev, mon) if rev else "line revision unreadable"
    if why:
        return why
    root = os.path.realpath(clone)
    lib = os.path.join(mon, "lib")
    names = [os.path.join(lib, n) for n in sorted(os.listdir(os.path.join(root, lib)))] \
        if os.path.isdir(os.path.join(root, lib)) else []
    for name in [words[1]] + names:
        try:
            with open(os.path.join(root, name), encoding="utf-8", errors="replace") as fh:
                if privileged.search(fh.read()):
                    return "%s names a write wrapper" % name
        except OSError:
            return "%s unreadable" % name
    if not planned(clone, ctx, " ".join(words)):
        return "command not in the accepted planner artifacts"
    return ""


def edit_class(clone, main, ctx, header, inp):
    """→ (name, "") for an allow-only or ask-only settings.json edit, else (None, reason)."""
    path = inp.get("file_path")
    if settings_target(clone, path) != "settings.json":
        return None, "not a .claude/settings.json edit"
    if settings_link(clone, path):
        return None, "settings path is a link or alias"
    sim = simulate(clone, "Edit" if header == "Edit file" else "Write", inp)
    if sim is None:
        return None, "edit cannot be simulated"
    allow = allow_offline(clone, main, ctx, *sim)
    ask = "" if added_only(*sim, "ask") else "not an ask-only edit"
    if not allow and not ask:
        return None, "more than one class"
    if not allow:
        return "allow-offline", ""
    if not ask:
        return "add-ask", ""
    return None, "%s; %s" % (allow, ask)


def classify(clone, main, header, inp, cwd, matches, session):
    """matches: [(tier, rule)] the checker found; each must be the class's waived ask rule."""
    ctx, why = context(clone, main, session)
    if ctx is None:
        return None, why
    rule = None
    if header == "Bash command":
        words = simple_words(inp.get("command"))
        if words is None:
            return None, "not one simple command"
        if words[:2] == ["git", "merge"]:
            name, why, rule = "merge-line", merge_line(ctx, words, cwd, clone, main), \
                "Bash(git merge --no-ff*)"
        elif words[:1] == ["bash"] and len(words) > 1 and diagnose_config(main) \
                and words[1].startswith(diagnose_config(main)[0]):
            name, why = "prod-diagnose", prod_diagnose(ctx, words, cwd, clone, main)
            rule = "Bash(bash %s*)" % words[1]
        else:
            return None, "no class for this command"
    elif header in ("Edit file", "Write file", "Create file", "Overwrite file"):
        name, why = edit_class(clone, main, ctx, header, inp)
    else:
        return None, "no class for a %s prompt" % header
    if why or name is None:
        return None, why
    # An edit's screen text is JSON, not a command: its ask matches mean nothing (deny refused).
    if any(tuple(m) != ("ask", rule) if rule else m[0] != "ask" for m in matches):
        return None, "a rule other than %s matches" % (rule or "an ask rule")
    if not switch_on(main, name):
        return None, "class %s off" % name
    return name, ""


def main(argv):
    if argv == ["names"]:
        print("\n".join(CLASSES))
        return 0
    if len(argv) == 2 and argv[0] == "switches":
        print(" ".join("%s=%s" % (n, "on" if switch_on(argv[1], n) else "off") for n in CLASSES))
        return 0
    print("usage: team_prompt_classes.py names | switches <main>", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
