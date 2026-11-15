"""Authority decisions for team_prompt_check.py --authority class|teamlead|operator.

Imported by the checker, never run: every function takes the checker module `c` (its Refuse,
parsers and rule matchers), so both share one Refuse class and one implementation of each check.

The human-only check runs first, before any waiver. Its causes are what only the Operator may
approve: an Edit/Write (or a Bash command naming) .claude/settings*.json or a guard profile
.claude/team/sessions/*.settings.json, an egress prompt or command (git remote add/set-url too),
a recursive rm with a target outside the clone and the temp roots, and an ask match whose rule is
not in the starter's baseline (.claude/team/baseline-ask.json — a project's added asks are its
production rules; a missing or unreadable baseline makes every ask production). Never waived by
any authority: a deny match, the SQL guard, an unreadable or unbound prompt, a recovered prompt
(header off screen), no live session, an edit or path outside the clone, a recursive rm of the
clone root or its .git.

  class    — no human-only cause, then today's --classes flow (a class waives baseline asks only)
  teamlead — no human-only cause; baseline ask matches are waived
  operator — as teamlead (the lead relaying an Operator decision on a baseline ask); a human-only
             cause is refused at every authority: the Operator answers it in the stage's window
`Edit(**/.env.*)` is a baseline ask, so the TeamLead may approve it (owner's decision, 2026-11-15);
`Edit(**/.env)` is a deny rule, never waived.
Contract: .agents/reference/team-lead.md §6
"""
import fnmatch
import glob
import json
import os
import re
import subprocess
import tempfile

import guard_destructive_sql
import team_prompt
import team_prompt_classes

HERE = os.path.dirname(os.path.abspath(__file__))
BASELINE = os.path.join(HERE, "..", "team", "baseline-ask.json")
AUTHORITIES = ("class", "teamlead", "operator")
PROFILE_PATH = re.compile(r"^\.claude/team/sessions/(.+/)?[^/]+\.settings\.json$", re.I)
PROFILE_TEXT = re.compile(r"\.claude/team/sessions/\S*\.settings\.json", re.I)
FILE_RULE = re.compile(r"^(Edit|Write|MultiEdit|NotebookEdit)\((.+)\)$")
EDITS = ("Edit file", "Write file", "Create file", "Overwrite file")


def path_scan(c, cmd, root, main):
    """[("settings", name) | ("outside", word)] in the order the canonical words name them; globs
    are expanded from <root>, a $VAR or a path relative to a `cd` target is not resolved."""
    out, dirs, base = [], c.guarded_main(root, main), os.path.realpath(root)
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


def delete_causes(c, root, cmd):
    """Human-only causes of a recursive rm whose target is not inside the clone or a temp root, or
    is inside a git dir; raises for the clone root, a git dir or an ancestor of either, which no
    authority deletes."""
    clone, temps, out, gits = os.path.realpath(root), temp_roots(), [], None
    cmds = [c.argv_plain(w) for w in c.canonical(cmd)]
    moved = any(w[:1] in (["cd"], ["pushd"]) for w in cmds)  # a relative path the check can't follow
    for targets in (rm_targets(w) for w in cmds):
        for t in targets or []:
            if re.search(r"[$`]", t) or (moved and not t.startswith(("/", "~"))):
                out.append("irreversible delete outside the clone: %s (unresolved)" % t)
                continue
            full = os.path.join(clone, os.path.expanduser(t))
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


def human_causes(c, root, main, extra, header, cmds, inp, text):
    """→ (human-only causes, ask matches); raises every never-waived refusal."""
    human, found = [], []
    if re.match(r"(WebFetch|Fetch)\b", header):
        human.append("egress: %s prompt" % header)
    tiered, bash = c.rules(root, extra), header.startswith("Bash")
    for cmd in cmds:
        if bash:
            for kind, word in path_scan(c, cmd, root, main):
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
            human += delete_causes(c, root, cmd)
        decision, reason = guard_destructive_sql.classify(cmd, root, root)
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


def flow(c, root, main, pane, transcript, extra, authority):
    """→ class name (class), the authority (teamlead/operator), or None when nothing needed a
    waiver; else Refuse. A human-only refusal reads `human-only: <cause> — pending decision`."""
    if transcript is None:
        raise c.Refuse("refuse: could not read the command behind the prompt (no transcript)")
    header, cmds, inp, tid, text, recovered = c.strict_commands(pane, transcript, root)
    human, asks = human_causes(c, root, main, extra, header, cmds, inp, text)
    if not human and not asks:
        return None
    # The role's transcript is Bash-writable: a header off screen is never approved by a rule.
    if recovered:
        raise c.Refuse("refuse: recovered prompt — header off screen")
    session = c.session_id(root)
    if session is None:
        raise c.Refuse("refuse: no live session")
    if human:
        raise c.Refuse("human-only: %s — pending decision" % human[0])
    if authority in ("teamlead", "operator"):
        return authority
    name, why = team_prompt_classes.classify(
        root, main, header, inp, team_prompt.tool_cwd(transcript, tid),
        [(t, r) for t, r, _ in asks], session)
    if name is None:
        raise c.Refuse("%s; class: %s" % (c.tier_refusal(*asks[0]), why))
    return name
