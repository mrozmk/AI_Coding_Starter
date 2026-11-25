"""The tier of a structured permission request (team_prompt_check.py --input-json, the stage hook).

Imported by the checker, never run: every function takes the checker module `c` (its Refuse,
parsers and rule matchers), so both share one Refuse class and one implementation of each check.

Egress first, by the real egress classifier (guard_team_egress.bash_reason / webfetch_reason).
Then the human-only causes — what only the Operator may approve: an Edit/Write (or a Bash command
naming) .claude/settings*.json or a guard profile .claude/team/sessions/*.settings.json, an egress
prompt or command (git remote add/set-url too), a recursive rm with a target outside the clone and
the temp roots, and an ask match whose rule is not in the starter's baseline
(.claude/team/baseline-ask.json — a project's added asks are its production rules; a missing or
unreadable baseline makes every ask production) — and the causes no authority waives (a deny
match, the SQL guard, an edit or path outside the clone, a recursive rm of the clone root or its
.git). Relative operands resolve against the payload's cwd; the clone root stays the boundary.

  class    — ask matches only, in one enabled team_prompt_classes.py class: the hook answers
  lead     — no human-only cause: the TeamLead allows or denies (also a prompt no rule explains —
             a hook's own ask leaves no trace in the payload — and an unevaluated tool type)
  operator — any human-only or never-waived cause: only an Operator decision answers, either way
`Edit(**/.env.*)` is a baseline ask, so the TeamLead may approve it (owner's decision, 2026-11-15);
`Edit(**/.env)` is a deny rule, never reaches the hook.
Contract: .agents/reference/team-lead.md §6
"""
import fnmatch
import glob
import hashlib
import json
import os
import re
import shlex
import stat
import subprocess
import tempfile

import guard_destructive_sql
import team_prompt_classes

HERE = os.path.dirname(os.path.abspath(__file__))
BASELINE = os.path.join(HERE, "..", "team", "baseline-ask.json")
PROFILE_PATH = re.compile(r"^\.claude/team/sessions/(.+/)?[^/]+\.settings\.json$", re.I)
PROFILE_TEXT = re.compile(r"\.claude/team/sessions/\S*\.settings\.json", re.I)
FILE_RULE = re.compile(r"^(Edit|Write|MultiEdit|NotebookEdit)\((.+)\)$")
EDITS = ("Edit file", "Write file", "Create file", "Overwrite file")


def path_scan(c, cmd, root, main, cwd=None):
    """[("settings", name) | ("outside", word)] in the order the canonical words name them; globs
    are expanded from <cwd> (default <root>), a $VAR or a path relative to a `cd` target is not
    resolved."""
    out, dirs, base = [], c.guarded_main(root, main), os.path.realpath(cwd or root)
    for words in c.canonical(cmd):
        for part in (p for w in words for p in w.split("=")):
            full = os.path.join(base, os.path.expanduser(part))
            hits = [part] + (glob.glob(full) if re.search(r"[*?[]", part) else [])
            out += [("settings", os.path.basename(h)) for h in hits
                    if os.path.basename(h).lower() in c.SETTINGS_NAMES]
            paths = [full] + hits[1:]
            if dirs and ("/" in part or part.startswith("~")) and any(
                    c.under(os.path.realpath(os.path.join(base, h)), dirs) for h in paths):
                out.append(("outside", part))
    return out


def temp_roots():
    """The system temp dir, /tmp, /private/tmp and $TMPDIR (the Claude scratchpad is under /tmp)."""
    roots = ["/tmp", "/private/tmp", tempfile.gettempdir(), os.environ.get("TMPDIR") or ""]
    return {os.path.realpath(r) for r in roots if r}


def git_dirs(clone):
    """The clone's git dirs: <clone>/.git, `git rev-parse --absolute-git-dir` and the common dir
    (a worktree's objects live there)."""
    out = {os.path.realpath(os.path.join(clone, ".git"))}
    for flag in ("--absolute-git-dir", "--git-common-dir"):
        try:
            r = subprocess.run(["git", "-C", clone, "rev-parse", flag], capture_output=True,
                               text=True, timeout=5)
        except (OSError, subprocess.SubprocessError):
            continue
        if r.returncode == 0 and r.stdout.strip():
            out.add(os.path.realpath(os.path.join(clone, r.stdout.strip())))
    return out


def rm_targets(words):
    """The targets of a recursive rm (-r/-R/--recursive in any spelling), else None."""
    if words[:1] != ["rm"]:
        return None
    opts, targets, ended = [], [], False
    for w in words[1:]:
        if not ended and w == "--":
            ended = True
        elif not ended and w.startswith("-") and w != "-":
            opts.append(w)
        else:
            targets.append(w)
    recursive = any(o == "--recursive" or (not o.startswith("--") and re.search("[rR]", o))
                    for o in opts)
    return targets if recursive else None


def delete_causes(c, root, cmd, cwd=None):
    """Human-only causes of a recursive rm whose target is not inside the clone or a temp root, or
    is inside a git dir; raises for the clone root, a git dir or an ancestor of either, which no
    authority deletes. A relative target resolves against <cwd> (default the clone root)."""
    clone, temps, out, gits = os.path.realpath(root), temp_roots(), [], None
    base = os.path.realpath(cwd or root)
    cmds = [c.argv_plain(w) for w in c.canonical(cmd)]
    moved = any(w[:1] in (["cd"], ["pushd"]) for w in cmds)  # a relative path the check can't follow
    for targets in (rm_targets(w) for w in cmds):
        for t in targets or []:
            if re.search(r"[$`]", t) or (moved and not t.startswith(("/", "~"))):
                out.append("irreversible delete outside the clone: %s (unresolved)" % t)
                continue
            full = os.path.join(base, os.path.expanduser(t))
            hits = glob.glob(full) if re.search(r"[*?[]", t) else [full]
            if not hits:
                out.append("irreversible delete outside the clone: %s (no match)" % t)
            for h in (os.path.realpath(h) for h in hits):
                gits = git_dirs(clone) if gits is None else gits
                # The root, a git dir, or an ancestor of either (`..`, a temp parent) — case-folded
                # like c.under, the volume being case-insensitive.
                # c.under compares against "<dir>/", which misses the filesystem root itself.
                if h == os.sep or any(c.under(x, [h]) for x in [clone] + sorted(gits)):
                    raise c.Refuse("refuse: rm -r of the clone root or its .git — never")
                if any(c.under(h, [g]) for g in gits):
                    out.append("irreversible delete inside the git dir: %s" % t)
                    continue
                inside = c.under(h, [clone])
                if not (inside or any(h.lower() != r.lower() and c.under(h, [r]) for r in temps)):
                    out.append("irreversible delete outside the clone: %s" % t)
    return out


def baseline():
    """The starter's ask rules, or None (every ask is then production)."""
    try:
        with open(BASELINE, encoding="utf-8") as fh:
            data = json.load(fh)
    except (OSError, ValueError):
        return None
    return set(data) if isinstance(data, list) and all(isinstance(r, str) for r in data) else None


def edit_rel(root, header, inp, text):
    """The clone-relative path an Edit/Write prompt targets, or None."""
    if header not in EDITS:
        return None
    path = (inp or {}).get("file_path") if inp else text.split("\n", 1)[0].strip()
    if not isinstance(path, str) or not path:
        return None
    return os.path.relpath(os.path.realpath(os.path.join(root, os.path.expanduser(path))),
                           os.path.realpath(root))


def profile_edit(root, header, inp, text):
    """True for an Edit/Write of a guard profile under .claude/team/sessions/."""
    rel = edit_rel(root, header, inp, text)
    return bool(rel and PROFILE_PATH.match(rel))


def file_asks(c, root, extra, header, inp, text):
    """[("ask", rule, path)] of the Edit/Write ask rules an Edit/Write prompt's path meets; the
    checker's rule list holds Bash rules only. `*` also crosses `/`: a wider match errs toward
    the Operator for a project rule."""
    rel = edit_rel(root, header, inp, text)
    if not rel:
        return []
    out = []
    for path in [os.path.join(root, ".claude", f) for f in c.SETTINGS_NAMES] + extra:
        try:
            with open(path, encoding="utf-8") as fh:
                asks = json.load(fh).get("permissions", {}).get("ask", [])
        except (OSError, ValueError, AttributeError):
            continue  # c.rules() already refused an unreadable policy
        for rule in asks if isinstance(asks, list) else []:
            m = FILE_RULE.match(rule) if isinstance(rule, str) else None
            pat = m.group(2).lstrip("/") if m else ""
            pat = pat[2:] if pat.startswith("./") else pat
            if pat and any(fnmatch.fnmatchcase(rel, p)
                           for p in (pat, pat[3:] if pat.startswith("**/") else pat)):
                out.append(("ask", rule, rel))
    return out


def human_causes(c, root, main, extra, header, cmds, inp, text, cwd=None):
    """→ (human-only causes, ask matches); raises every never-waived refusal. <cwd> (the hook
    payload's) is the base of relative operands; the clone root stays the containment boundary."""
    human, found = [], []
    if re.match(r"(WebFetch|Fetch)\b", header):
        human.append("egress: %s prompt" % header)
    tiered, bash = c.rules(root, extra), header.startswith("Bash")
    for cmd in cmds:
        if bash:
            for kind, word in path_scan(c, cmd, root, main, cwd):
                if kind == "outside":
                    raise c.Refuse("refuse (outside clone): %s — Operator" % word)
                human.append("settings edit: %s via Bash" % word)
            m = c.SETTINGS_WORD.search(cmd) or PROFILE_TEXT.search(cmd)
            if m:
                human.append("settings edit: %s via Bash" % m.group(0).strip())
            for line in cmd.splitlines():
                for part in c.SEGMENT.split(line):
                    m = c.EGRESS.search(part)
                    if m and not c.guard_team_egress.loopback_probe(part.split()):
                        human.append("egress: %s" % m.group(2))
            # A new remote plus the allowed git push sends the repository to an unapproved host.
            human += ["egress: git remote %s" % w[2] for w in map(c.argv_plain, c.canonical(cmd))
                      if w[:2] == ["git", "remote"] and w[2:3] in (["add"], ["set-url"])]
            human += delete_causes(c, root, cmd, cwd)
        # The live guard's argument order: (command, cwd, project).
        decision, reason = guard_destructive_sql.classify(cmd, cwd or root, root)
        if decision:
            raise c.Refuse("refuse (%s): %s" % (decision, reason))
        found += c.matches(cmd, tiered, bash)
    first = next((f for f in found if f[0] == "deny"), None)
    if first:
        raise c.tier_refusal(*first)
    c.outside_refusal(root, main, header, inp, text)
    if c.settings_refusal(root, header, inp, text) or profile_edit(root, header, inp, text):
        human.append("settings edit: %s" % ((inp or {}).get("file_path") or text.split("\n")[0]))
    base = baseline()
    asks = [f for f in found if f[0] == "ask"] + file_asks(c, root, extra, header, inp, text)
    human += ["production ask: %s" % r for _, r, _ in asks if base is None or r not in base]
    return human, asks


# Structured input (the stage hook's PermissionRequest): the tool types the checker evaluates in
# full. Any other tool is tiered by its ask rule alone and is never a class.
HEADERS = {"Bash": "Bash command", "Edit": "Edit file", "MultiEdit": "Edit file",
           "NotebookEdit": "Edit file", "Write": "Write file", "WebFetch": "Fetch"}


def rule_covers(rule, tool, inp):
    """True when ask rule <rule> covers this unevaluated tool call; an argument that cannot be
    judged counts as covered (the Operator decides)."""
    name, paren, arg = rule.partition("(")
    if not paren:
        # A bare server rule (mcp__srv) covers every tool of that server.
        return fnmatch.fnmatchcase(tool, rule) or (
            rule.startswith("mcp__") and rule.count("__") == 1 and tool.startswith(rule + "__"))
    if not fnmatch.fnmatchcase(tool, name):
        return False
    if name != "Skill" or not arg.endswith(")"):
        return True
    arg, skill = arg[:-1], (inp or {}).get("skill")
    if arg.endswith((":*", " *")):  # an argument suffix; the name itself is kept as written
        arg = arg[:-2]
    if not isinstance(skill, str) or not skill or not arg or re.search(r"[\s()]", arg):
        return True
    return fnmatch.fnmatchcase(skill, arg)


def tool_rule_tier(c, root, extra, tool, inp=None):
    """An unevaluated tool (MCP, Skill, Read, …): a project-added ask rule covering the call
    (rule_covers: a bare name or server, a parameterized rule — a Skill rule by its skill name,
    any other argument as covered) → operator, a baseline one or none → lead."""
    base = baseline()
    for path in [os.path.join(root, ".claude", f) for f in c.SETTINGS_NAMES] + extra:
        try:
            with open(path, encoding="utf-8") as fh:
                asks = json.load(fh).get("permissions", {}).get("ask", [])
        except (OSError, ValueError, AttributeError):
            continue
        for rule in asks if isinstance(asks, list) else []:
            if isinstance(rule, str) and rule_covers(rule, tool, inp):
                if base is None or rule not in base:
                    return ("operator", "production ask: %s" % rule)
    return ("lead", None)


def tier(c, root, main, extra, tool, header, cmds, inp, text, cwd):
    """→ ("class", name) | ("lead", None) | ("operator", cause) for one structured permission.
    Egress first, by the real egress classifier; then the human-only causes and every never-waived
    refusal (operator); a prompt no rule explains keeps a checkpoint (lead, never automatic: a
    hook's own ask leaves no trace in the payload); ask matches in an enabled class → class."""
    try:
        if tool == "Bash":
            for cmd in cmds:
                r = c.guard_team_egress.bash_reason(cmd, root)
                if r:
                    return ("operator", "egress: %s" % r)
        elif tool == "WebFetch":
            r = c.guard_team_egress.webfetch_reason((inp or {}).get("url"), root)
            if r:
                return ("operator", "egress: %s" % r)
    except Exception as e:  # noqa: BLE001 — the egress guard asks the Operator when it fails
        return ("operator", "egress: guard failed (%s)" % e.__class__.__name__)
    if header is None:
        return tool_rule_tier(c, root, extra, tool, inp)
    try:
        human, asks = human_causes(c, root, main, extra, header, cmds, inp, text, cwd)
    except c.Refuse as e:
        return ("operator", str(e))
    if human:
        return ("operator", human[0])
    if not asks:
        return ("lead", None)
    session = c.session_id(root)
    if session is None or tool == "WebFetch":
        return ("lead", None)
    name, _ = team_prompt_classes.classify(root, main, header, inp, cwd,
                                           [(t, r) for t, r, _ in asks], session)
    return ("class", name) if name else ("lead", None)


# The retry key of an operator-tier permission: what an Operator approval is bound to, so a retry
# of the same call after the hook's deadline can claim the decided answer (team-lead.md §6).
TREE_MAX = 20000
UNPINNED = re.compile(r"[$`]|<\(|>\(")
FILE_TOOLS = ("Read", "Edit", "MultiEdit", "Write", "NotebookEdit")


class Unpinned(Exception):
    """The request names an input the checker cannot know."""


TEAM_STATE = re.compile(r"/\.agents/team(/|$)")


def path_digest(p):
    """A file → (realpath, size, mtime_ns, sha1); a directory → a tree digest of its entries
    (no symlink following); a missing path → (realpath, absent). Unpinned for a tree holding a
    team state dir (the hook writes the ask there, so its key would never match again) and for
    anything but a regular file or a directory (a device or FIFO never reads to an end), except
    /dev/null, which gets a fixed digest without a read."""
    real = os.path.realpath(p)
    if not os.path.lexists(p):
        return [real, "absent"]
    if real == "/dev/null":
        return [real, "null"]
    if os.path.isdir(real):
        if TEAM_STATE.search(real):
            raise Unpinned("state")
        rows, n = [], 0
        for top, dirs, files in os.walk(real):
            for name in sorted(dirs) + sorted(files):
                n += 1
                if n > TREE_MAX:
                    raise Unpinned("tree")
                full = os.path.join(top, name)
                if TEAM_STATE.search(full):
                    raise Unpinned("state")
                st = os.lstat(full)
                kind = "l" if os.path.islink(full) else "d" if os.path.isdir(full) else "f"
                rows.append([os.path.relpath(full, real), kind, st.st_size, st.st_mtime_ns])
        return [real, "tree", hashlib.sha1(json.dumps(sorted(rows)).encode()).hexdigest()]
    st = os.stat(real)
    if not stat.S_ISREG(st.st_mode):
        raise Unpinned("special")
    h = hashlib.sha1()
    with open(real, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return [real, st.st_size, st.st_mtime_ns, h.hexdigest()]


def bash_paths(cmd, cwd):
    """Every existing path a Bash command names: each word, each word's part after @, < or = (up to
    a `;`), an attached short option's value (redirection targets included), joined to cwd. Unpinned for $, a backtick, $(…), a process
    substitution, a glob or ~user."""
    if UNPINNED.search(cmd):
        raise Unpinned("expansion")
    lex = shlex.shlex(cmd, posix=True, punctuation_chars=True)
    lex.whitespace_split = True
    out = []
    for word in lex:
        if not word or set(word) <= set("();<>|&"):
            continue
        if re.search(r"[*?\[]", word) or re.match(r"~[^/]", word):
            raise Unpinned("glob")
        parts = [word] + [word.split(s, 1)[1] for s in "@<=" if s in word]
        # curl's `@file;type=…` / `<file;filename=…`, and an attached short option (`-Tfile`).
        parts += [p.split(";", 1)[0] for p in parts if ";" in p]
        if re.match(r"-[A-Za-z].", word):
            parts.append(word[2:])
        for part in parts:
            if not part:
                continue
            full = os.path.join(cwd, os.path.expanduser(part))
            if os.path.lexists(full):
                out.append(path_digest(full))
    return out


def retry_key(tool, inp, cwd):
    """sha1 over the canonical {tool_name, tool_input, cwd} and a digest of every path the request
    names, or None when its inputs cannot be pinned (any failure counts as that)."""
    try:
        if tool == "Bash":
            paths = bash_paths(inp.get("command") or "", cwd)
        elif tool in FILE_TOOLS:
            target = inp.get("file_path") or inp.get("notebook_path")
            paths = [path_digest(os.path.join(cwd, os.path.expanduser(target)))] \
                if isinstance(target, str) and target else []
        else:
            paths = []
        blob = json.dumps({"tool_name": tool, "tool_input": inp, "cwd": cwd, "paths": paths},
                          sort_keys=True, separators=(",", ":"))
        return hashlib.sha1(blob.encode()).hexdigest()
    except Exception:  # noqa: BLE001 — an unknown input never carries an approval
        return None


def input_tier(c, root, main, extra, path, causes=False):
    """team_prompt_check.py --input-json: the tier line of one structured permission
    ({tool_name, tool_input, cwd}) and a second line `retry: <key>|none` (retry_key, operator tier
    only), or None when the file cannot be read. With <causes> (--causes) an operator tier adds a
    third line `causes: <JSON list>` — every cause (all_causes), for the Operator's mandate."""
    try:
        with open(path, encoding="utf-8") as fh:
            data = json.load(fh)
        tool, inp = data.get("tool_name"), data.get("tool_input") or {}
        if not isinstance(tool, str) or not isinstance(inp, dict):
            return None
    except (OSError, ValueError, AttributeError):
        return None
    cwd = data.get("cwd") if isinstance(data.get("cwd"), str) and data.get("cwd") else root
    inp = dict(inp)
    target = inp.get("file_path") or inp.get("notebook_path")
    if isinstance(target, str) and target:
        inp["file_path"] = os.path.join(cwd, os.path.expanduser(target))
    cmd = inp.get("command") if isinstance(inp.get("command"), str) else ""
    text = str(inp.get("file_path") or inp.get("url") or cmd.split("\n", 1)[0])
    raw = dict(data.get("tool_input") or {})
    kind, why = tier(c, root, main, extra, tool, HEADERS.get(tool), [cmd] if tool == "Bash" else [],
                     inp, text, cwd)
    key = None
    if kind == "operator" and not str(why).startswith("egress: guard failed"):
        key = retry_key(tool, raw, cwd)
    line = "tier: class %s" % why if kind == "class" else "tier: lead" if kind == "lead" \
        else "tier: operator — %s" % why
    out = "%s\nretry: %s" % (line, key or "none")
    if causes and kind == "operator":
        # Every cause, not only the first one the tier names: a mandate must cover them all.
        out += "\ncauses: %s" % json.dumps(all_causes(
            c, root, main, extra, tool, HEADERS.get(tool), [cmd] if tool == "Bash" else [],
            inp, text, cwd))
    return out


def all_causes(c, root, main, extra, tool, header, cmds, inp, text, cwd):
    """Every operator-tier cause of one structured permission, in tier()'s order: the egress
    reason, then each human-only cause, or the never-waived refusal that ends the evaluation.
    tier() names the first one only; the Operator's mandate (team-mandate.sh) needs them all."""
    out = []
    try:
        if tool == "Bash":
            for cmd in cmds:
                r = c.guard_team_egress.bash_reason(cmd, root)
                if r:
                    out.append("egress: %s" % r)
        elif tool == "WebFetch":
            r = c.guard_team_egress.webfetch_reason((inp or {}).get("url"), root)
            if r:
                out.append("egress: %s" % r)
    except Exception as e:  # noqa: BLE001 — as in tier(): a failing guard is the Operator's
        out.append("egress: guard failed (%s)" % e.__class__.__name__)
    if header is None:
        kind, why = tool_rule_tier(c, root, extra, tool, inp)
        return out + ([why] if kind == "operator" else [])
    try:
        human, _ = human_causes(c, root, main, extra, header, cmds, inp, text, cwd)
        out += human
    except c.Refuse as e:
        out.append(str(e))
    return out
