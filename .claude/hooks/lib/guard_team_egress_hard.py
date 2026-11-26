"""#322 hard-class detectors of the effect classifier (guard_team_egress_classify.py): the class of
every write target (settings and role profiles → deny; .claude/hooks → operator or deny by the
session's place, Operator decision d-2), the per-segment cwd, and the operator detectors (method,
body, credentials, GH_HOST/GH_REPO/--hostname, a gh write to another repo, a git push whose
destination is not the verified origin, a private host, an unpinned install). A detector raises on
a bug: the callers fail closed.
"""
import fnmatch
import functools
import json
import os
import re
import shlex
import subprocess
import sys
# Local imports below: never write __pycache__ into the project (callers run python3 -I, not -B).
sys.dont_write_bytecode = True
from urllib.parse import urlsplit

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)  # python3 -I drops the script dir from sys.path

from guard_destructive_sql import commands, strip_wrappers, tokenize  # noqa: E402
from guard_team_egress_effect import (  # noqa: E402
    GH_READ_FORMS, PY_DOC, gh_api_read, inline_literals, py_flags)
from guard_team_egress_words import (  # noqa: E402
    curl_options, data_heredocs_removed, positional, py_write_targets, redirect_targets, sub_masked,
    units, word_targets)

URL_WORD = re.compile(r"[a-zA-Z][a-zA-Z0-9+.-]*://[^\s'\"<>|;&()`]+")
EGRESS_VERBS = {"curl", "wget", "ssh", "scp", "rsync", "nc", "ftp", "sftp", "gh", "npm", "npx", "pip",
                "pip3", "pipx", "uvx", "git"}
CRED_ENV = re.compile(r"^(?:GH_TOKEN|GITHUB_TOKEN|GH_ENTERPRISE_TOKEN|NPM_TOKEN|NODE_AUTH_TOKEN"
                      r"|[A-Z0-9_]*(?:TOKEN|SECRET|PASSWORD|API_KEY|ACCESS_KEY))=")
CRED_HEADER = re.compile(r"^\s*(?:proxy-)?authorization\s*:|^\s*cookie\s*:|token|api[-_]?key", re.I)
WGET_OPERATOR = re.compile(r"^--(?:post-data|method|user|password|http-user|http-password|header"
                           r"|proxy-user|proxy-password)(?:=|$)")
EXACT_NPM = re.compile(r"^(?:@[^@/\s]+/)?[^@/\s]+@\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?$")
EXACT_PIP = re.compile(r"^[A-Za-z0-9_.\[\],-]+==[0-9A-Za-z.+!-]+$")
PROTECTED = ("*/.claude/settings*.json", "*/.claude/team/sessions/*.settings.json")
PROTECTED_BASE = ("settings*.json", "*.settings.json")
HOOKS = "*/.claude/hooks/*"
CD_LITERAL = re.compile(r"^(?:~(?=/|$))?[^$`*?\[\]{}~]*$")
GIT_TIMEOUT = 5
RANK = {"deny": 3, "operator": 2, "ask": 1, "pass": 0}


def worst(found):
    return max(found, key=lambda f: RANK[f[0]]) if found else None


# --- the session's places -----------------------------------------------------------------------

def team_stage(project):
    return bool(os.environ.get("TEAM_RUN_TEAM")) or (
        bool(project) and os.path.exists(os.path.join(project, ".agents", "team", "session.json")))


def _json(path):
    try:
        with open(path, encoding="utf-8") as fh:
            data = json.load(fh)
        return data if isinstance(data, dict) else {}
    except (OSError, ValueError):
        return {}


def starter_worktree(project):
    """realpath(<project>/<teams.starter_root>)-<team>-<ticket>, or None."""
    root = (_json(os.path.join(project, ".claude", "project-profile.json")).get("teams") or {})
    root = root.get("starter_root") if isinstance(root, dict) else None
    team = _json(os.path.join(project, ".agents", "team", "team.json"))
    if not (isinstance(root, str) and root and team.get("team") and team.get("ticket")):
        return None
    return os.path.realpath(os.path.join(project, root)) + "-" + str(team["team"]) + "-" + str(team["ticket"])


def inside(path, base):
    p, b = path.lower().rstrip(os.sep), os.path.realpath(base).lower().rstrip(os.sep)
    return p == b or p.startswith(b + os.sep)


def resolve(target, cwd):
    """The absolute realpath of a write target, or None when it is relative and <cwd> is unknown."""
    t = os.path.expanduser(target)
    if not os.path.isabs(t):
        if cwd is None:
            return None
        t = os.path.join(cwd, t)
    return os.path.realpath(t)


def claude_config_dir():
    d = os.environ.get("CLAUDE_CONFIG_DIR") or os.path.join(os.path.expanduser("~"), ".claude")
    return os.path.realpath(d)


def guard_layer(path, project):
    """True when a settings or role-profile path (PROTECTED) belongs to a live guard layer (#322
    round 2): the `.claude/` of the session's project, the `.claude/` at the root of a checkout
    (its parent holds `.git` — the clone, the main checkout, the starter and its worktrees), or the
    user's Claude config dir. A fixture project's `.claude/` inside a repository tree is not one."""
    low, cfg = path.lower(), claude_config_dir().lower()
    if low.startswith(cfg + os.sep) and any(
            fnmatch.fnmatch(low[len(cfg) + 1:], p) for p in ("settings*.json", "team/sessions/*.settings.json")):
        return True
    if not any(fnmatch.fnmatch(low, p) for p in PROTECTED):
        return False
    k = low.rfind("/.claude/")
    while k >= 0:
        rest = low[k + len("/.claude/"):]
        if fnmatch.fnmatch(rest, "settings*.json") or fnmatch.fnmatch(rest, "team/sessions/*.settings.json"):
            root = path[:k]
            return (bool(project) and root.lower() == os.path.realpath(project).lower()) or \
                os.path.exists(os.path.join(root, ".git"))
        k = low.rfind("/.claude/", 0, k)
    return False


def target_class(target, cwd, project):
    """(kind, reason) of one write target, or None."""
    path = resolve(target, cwd)
    if path is None:
        base = os.path.basename(target).lower()
        # TeamLead (Q1): only a protected name is classed; any other unresolvable target gets none.
        if any(fnmatch.fnmatch(base, p) for p in PROTECTED_BASE) or "hooks/" in target.lower():
            return "deny", "write into a protected path after an unresolvable cd (" + target + ")"
        return None
    low = path.lower()
    if guard_layer(path, project):
        return "deny", "write into settings or a role profile (" + os.path.basename(path) + ")"
    if fnmatch.fnmatch(low, HOOKS):
        # Operator decision d-4: a non-stage hooks write gets no class in this phase (#323 adds the
        # role-profile hook); the stage rules of d-2 stay.
        if not team_stage(project):
            return None
        wt = starter_worktree(project)
        if wt and inside(low, wt):
            return None
        if project and inside(low, project):
            return "operator", "write into this session's armed guard (.claude/hooks)"
        return "deny", "a stage writes hooks only in its own clone or its run's starter worktree"
    return None


def segment_cwds(cmd, base):
    """[(raw, words, cwd)] of the top-level simple commands of <cmd> in order; a `cd <literal>`
    moves the cwd, any other cd/pushd/popd makes it unknown (None)."""
    try:
        tokens = tokenize(sub_masked(data_heredocs_removed(cmd))[0])
    except ValueError:
        return []
    grouped = "(" in tokens or ")" in tokens
    out, cwd = [], base
    for raw in commands(tokens):
        try:
            words = strip_wrappers(raw)
        except ValueError:
            words = []
        out.append((raw, words, cwd))
        verb = words[0] if words else ""
        if verb in ("pushd", "popd") or (verb == "cd" and grouped):
            cwd = None
        elif verb == "cd":
            args = [a for a in words[1:] if a != "--"]
            if len(args) == 1 and args[0] != "-" and CD_LITERAL.match(args[0]) and cwd is not None:
                cwd = os.path.normpath(os.path.join(cwd, os.path.expanduser(args[0])))
            else:
                cwd = None
    return out


def python_c_writes(words, cwd, project):
    if not words or os.path.basename(words[0]) not in ("python3", "python"):
        return []
    j = py_flags(words)
    if words[j:j + 1] != ["-c"] or len(words) < j + 2:
        return []
    return [target_class(t, cwd, project) for t in py_write_targets(words[j + 1], words[j + 2:])]


def python_doc_writes(cmd, project, base):
    """Writes of the quoted-delimiter `python3 [flags] - [args] <<'D'` here-docs; the cwd is the one
    the text before the header leaves."""
    out, lines = [], cmd.split("\n")
    for n, line in enumerate(lines):
        m = PY_DOC.search(line)
        if not m:
            continue
        delim = m.group(4)
        end = next((j for j in range(n + 1, len(lines)) if lines[j] == delim), None)
        if end is None:
            continue
        before = "\n".join(lines[:n] + [line[:m.start()]])
        segs = segment_cwds(before, base) if before.strip() else []
        here = segs[-1][2] if segs else base
        if (segs[-1][1] if segs else [])[:1] == ["cd"]:
            here = segment_cwds(before + "\ntrue", base)[-1][2]
        try:
            argv = shlex.split(m.group(2) or "")
        except ValueError:
            argv = []
        for t in py_write_targets("\n".join(lines[n + 1:end]), argv):
            out.append(target_class(t, here, project))
    return [o for o in out if o]


def write_class(cmd, project, cwd):
    """The most severe class of every write target in <cmd> (redirections, tee/cp/mv/install/ln,
    sed -i, dd of=, curl -o, inline Python writes); None when none."""
    found = []
    base = cwd if isinstance(cwd, str) and cwd else (project or None)
    cmd = inline_literals(cmd)  # `S=/x; cd $S/y && … > f`: the literal head resolves the cd
    top = segment_cwds(cmd, base)
    links = []  # (link path, its source): a later write through the link writes the source
    for raw, words, seg_cwd in top:
        for t in redirect_targets(raw) + word_targets(words):
            found.append(target_class(t, seg_cwd, project))
            p = resolve(t, seg_cwd)
            for link, src in links:
                if p and (p == link or p.startswith(link + os.sep)):
                    found.append(target_class(src + p[len(link):], None, project))
        found.extend(python_c_writes(words, seg_cwd, project))
        pos = positional(words[1:], ("-t", "-S", "--suffix")) if words[:1] == ["ln"] else []
        if len(pos) == 2 and seg_cwd:
            link = resolve(pos[1], seg_cwd)
            symbolic = any(re.match(r"^-[A-Za-z]*s|^--symbolic", a) for a in words[1:])
            src = resolve(pos[0], os.path.dirname(link) if symbolic else seg_cwd)
            links.append((link, src))
    # Nested commands (bash -c, $(…), eval): the cwd at their start is the payload's, or unknown
    # when a cd appears in the text.
    here = None if re.search(r"(?:^|[\s;&|(])(?:cd|pushd|popd)\s", cmd) else base
    seen = [r for r, _, _ in top]
    for raw, words in units(cmd):
        if raw in seen:
            continue
        for t in redirect_targets(raw) + word_targets(words):
            found.append(target_class(t, here, project))
        found.extend(python_c_writes(words, here, project))
    found.extend(python_doc_writes(cmd, project, base))
    return worst([f for f in found if f])


# --- operator -----------------------------------------------------------------------------------

def own_repo(project):
    prof = _json(os.path.join(project, ".claude", "project-profile.json")) if project else {}
    for block in ((prof.get("teams") or {}).get("github") if isinstance(prof.get("teams"), dict) else None,
                  prof.get("github")):
        if isinstance(block, dict) and isinstance(block.get("repo"), str) and block["repo"]:
            return block["repo"].lower()
    urls = git_lines(project, ("remote", "get-url", "origin")) if project else None
    m = re.search(r"github\.com[:/]+([^/\s]+/[^/\s]+?)(?:\.git)?/?$", (urls or [""])[0])
    return m.group(1).lower() if m else None


@functools.lru_cache(maxsize=256)
def git_lines(repo, args):
    """Lines git prints for `git -C <repo> <args>`, or None on any failure."""
    try:
        r = subprocess.run(["git", "-C", repo] + list(args), capture_output=True, text=True,
                           timeout=GIT_TIMEOUT)
    except (OSError, subprocess.SubprocessError, ValueError):
        return None
    if r.returncode != 0:
        return None
    return [ln.strip() for ln in r.stdout.splitlines() if ln.strip()]


def push_reason(words, cwd, project):
    """'' when this `git … push …` goes only to the verified origin, else the operator reason."""
    i, repo = 1, cwd or project
    while i < len(words) and words[i].startswith("-"):
        w = words[i]
        if w == "-c" or w.startswith("-c") and len(w) > 2:
            return "git push with a command-local config option"
        if w == "-C" and i + 1 < len(words):
            repo = resolve(words[i + 1], repo) if repo else None
            i += 2
            continue
        if w.startswith(("--git-dir", "--work-tree", "--config-env", "--exec-path")):
            return "git push with a repository option"
        i += 1
    if words[i:i + 1] != ["push"]:
        return ""
    args = words[i + 1:]
    if any(a == "--repo" or a.startswith("--repo=") for a in args):
        return "git push --repo"
    if not repo:
        return "git push destination unresolvable"
    origin = git_lines(repo, ("remote", "get-url", "--all", "origin"))
    if not origin:
        return "git push destination unresolvable (no origin)"
    pos = positional(args, ("-o", "--push-option", "--receive-pack", "--exec"))
    if pos:
        dest = pos[0]
        if "/" in dest or ":" in dest or dest.startswith("."):
            return "" if dest in origin else "git push to a URL other than origin's"
        remote = dest
    else:
        branch = (git_lines(repo, ("symbolic-ref", "--short", "-q", "HEAD")) or [""])[0]
        remote = None
        for key in (("branch." + branch + ".pushRemote") if branch else None, "remote.pushDefault",
                    ("branch." + branch + ".remote") if branch else None):
            if key:
                got = git_lines(repo, ("config", "--get", key))
                if got:
                    remote = got[0]
                    break
        remote = remote or "origin"
    if remote.startswith(".") or "/" in remote or ":" in remote:
        return "" if remote in origin else "git push to a URL other than origin's"
    dests = git_lines(repo, ("remote", "get-url", "--push", "--all", remote))
    if not dests:
        return "git push destination unresolvable (" + remote + ")"
    if all(d in origin for d in dests):
        return ""
    return "git push to a destination other than origin (" + remote + ")"


def install_reason(verb, args):
    if verb in ("npx", "uvx"):
        pos = positional(args, ("-p", "--package", "--from", "--with"))
        pinned = pos and (EXACT_NPM.match(pos[0]) if verb == "npx" else re.search(r"==|@\d", pos[0]))
        return "" if pinned else verb + " of an unpinned package"
    if verb == "pipx" and args[:1] and args[0] in ("run", "install"):
        pos = positional(args[1:], ("--spec", "--python", "--pip-args"))
        return "" if pos and "==" in pos[0] else "pipx " + args[0] + " of an unpinned package"
    i = 0  # npm's global options may come before its command: `npm --prefix P install x`
    while verb == "npm" and i < len(args) and args[i].startswith("-"):
        i += 2 if args[i] in ("--prefix", "-C", "-w", "--workspace", "--userconfig", "--registry") else 1
    if verb == "npm" and args[i:i + 1] and args[i] in ("i", "install", "add", "isntall", "in"):
        pos = positional(args[i + 1:], ("--prefix", "-w", "--workspace", "--tag", "--registry"))
        bad = [p for p in pos if "://" in p or p.startswith(("git+", "github:", "git@")) or not EXACT_NPM.match(p)]
        return "npm install of an unpinned or remote package (" + bad[0] + ")" if bad else ""
    if verb in ("pip", "pip3") and args[:1] == ["install"]:
        pos = positional(args[1:], ("-r", "--requirement", "-c", "--constraint", "-e", "--editable",
                                    "-t", "--target", "--prefix", "--root", "-i", "--index-url",
                                    "--extra-index-url", "-f", "--find-links"))
        bad = [p for p in pos if "://" in p or not EXACT_PIP.match(p)]
        return "pip install of an unpinned or remote package (" + bad[0] + ")" if bad else ""
    return ""


def gh_reason(words, args, project):
    if any(a == "--hostname" or a.startswith("--hostname=") for a in args):
        return "gh --hostname"
    if args[:1] == ["api"] and not gh_api_read(words):
        return "gh api write"
    if tuple(args[:2]) in GH_READ_FORMS or args[:1] == ["api"]:
        return ""
    repo = None
    for k, a in enumerate(args):
        if a in ("-R", "--repo") and k + 1 < len(args):
            repo = args[k + 1]
        elif a.startswith("--repo="):
            repo = a.split("=", 1)[1]
        elif re.match(r"^-R.+", a):
            repo = a[2:].lstrip("=")
    # A host-qualified repo (HOST/OWNER/REPO) on another host than the project's (github.com) is
    # gh on another host, like --hostname — whatever owner/repo follows (#322 round 2).
    if repo is not None and repo.count("/") >= 2 and repo.split("/", 1)[0].lower() != "github.com":
        return "gh write to another host (" + repo + ")"
    # No known own repo (no profile, no origin): "another repo" cannot be told — no class.
    own = own_repo(project) if repo is not None else None
    if own is not None and repo.lower().split("/", repo.count("/") - 1)[-1] != own:
        return "gh write to another repo (" + repo + ")"
    return ""


def operator_words(raw, words, cwd, project):
    """The operator reason of one simple command, or ''."""
    from guard_team_egress_classify import private_host
    if not words:
        return ""
    verb, args = os.path.basename(words[0]), words[1:]
    prefix = raw[:len(raw) - len(words)] if raw[len(raw) - len(words):] == words else raw
    if verb in EGRESS_VERBS and any(CRED_ENV.match(w) for w in prefix):
        return "credentials in the environment of " + verb
    if verb in EGRESS_VERBS and any(re.match(r"^GH_(?:HOST|REPO)=", w) for w in prefix):
        return "GH_HOST/GH_REPO before " + verb
    for w in words if verb in ("curl", "wget", "git") else []:
        for m in URL_WORD.finditer(w):
            try:
                parts = urlsplit(m.group(0))
                host = parts.hostname or ""
            except ValueError:
                return "unparsable URL " + m.group(0)[:60]
            # A local file URL, or a host an expansion builds at run time: no host to class here
            # (the reading judges the word).
            if parts.scheme.lower() == "file" or "$" in parts.netloc:
                continue
            if private_host(host):
                return "private host " + host
            if "@" in parts.netloc:
                return "credentials in a URL"
    if verb == "curl":
        for cls, val in curl_options(args):
            if cls == "method" and val.upper() not in ("GET", "HEAD"):
                return "curl method " + val
            if cls == "body":
                return "curl request body"
            if cls == "creds":
                return "curl explicit credentials"
            if cls == "header" and CRED_HEADER.search(val):
                return "curl credential header"
    if verb == "wget" and any(WGET_OPERATOR.match(a) for a in args):
        return "wget method, body or credentials"
    if verb == "gh":
        return gh_reason(words, args, project)
    if verb == "git":
        return push_reason(words, cwd, project) if "push" in words else ""
    if verb in ("npm", "npx", "pip", "pip3", "pipx", "uvx"):
        return install_reason(verb, args)
    if verb in ("python3", "python") and args[:2] == ["-m", "pip"]:
        return install_reason("pip", args[2:])
    return ""


def operator_reason(cmd, project, cwd):
    base = cwd if isinstance(cwd, str) and cwd else (project or None)
    top = {tuple(r): c for r, _, c in segment_cwds(cmd, base)}
    found = units(cmd)
    verbs = {os.path.basename(w[0]) for _, w in found if w}
    if "gh" in verbs and any(w[:1] and w[0] in ("export", "declare", "typeset", "local", "readonly")
                             and any(re.match(r"^GH_(?:HOST|REPO)=", a) for a in w[1:]) for _, w in found):
        return "GH_HOST/GH_REPO with gh"
    for raw, words in found:
        why = operator_words(raw, words, top.get(tuple(raw), base), project)
        if why:
            return why
    return ""


if __name__ == "__main__":
    # team-ask-hook.sh: `guard-layer <path> <project>` → exit 0 (a live guard layer), 1 (not), 2 (a
    # bug or bad argv: the hook refuses — a raised exception must never read as "not").
    try:
        if sys.argv[1:2] != ["guard-layer"] or len(sys.argv) != 4:
            raise ValueError("usage: guard-layer <path> <project>")
        sys.exit(0 if guard_layer(sys.argv[2], sys.argv[3]) else 1)
    except Exception as e:  # fail closed
        print("guard_team_egress_hard: " + str(e), file=sys.stderr)
        sys.exit(2)
