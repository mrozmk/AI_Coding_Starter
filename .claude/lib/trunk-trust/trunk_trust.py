"""Trunk trust for the opt-in kits (guarded writes, local env runner): one copy of the rule.

A kit's config (and any script it vouches for) counts only when it is tracked by git and
byte-identical to its blob at a verified `origin/<Trunk>`. The Trunk name comes from the CLAUDE.md
Branch model **on origin's default branch**, parsed by that commit's own branch-model.sh — never from
the working tree, so declaring another Trunk needs a push to the default branch. When origin answers,
every local `origin/*` ref used must equal what origin has. Widening what an agent may do therefore
needs a change that reached trunk. Offline, local refs are trusted (origin/HEAD included) — same OS
user, so a hurdle, not isolation (each kit's reference doc states the limits).
"""
import json
import os
import re
import shutil
import signal
import subprocess
import tempfile

PROFILE_FILE = ".claude/project-profile.json"
# Caller GIT_* variables that only pick the ssh transport; every other one (GIT_DIR,
# GIT_OBJECT_DIRECTORY, GIT_CONFIG_*, GIT_REPLACE_REF_BASE ...) could point the check at other objects.
GIT_TRANSPORT = ("GIT_SSH", "GIT_SSH_COMMAND", "GIT_SSH_VARIANT")


class Refused(Exception):
    pass


def git_env():
    """The caller's env without repo-redirecting GIT_* variables; replace refs never apply."""
    env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_") or k in GIT_TRANSPORT}
    env["GIT_NO_REPLACE_OBJECTS"] = "1"
    return env


def git(*args):
    r = subprocess.run(["git", *args], capture_output=True, env=git_env())
    return r.returncode, r.stdout


def ls_remote(root, *args):
    """`git ls-remote origin <args>` output, or None when origin does not answer in time."""
    return _bounded(root, "ls-remote", *args)


def fetch_branch(root, branch):
    """Bring the local origin/<branch> up to date — that remote-tracking ref only, fast-forward only
    (a rewritten local ref stays rewritten and the check refuses it). A failure is not an error: the
    online/offline rule decides afterwards. For callers that run unattended."""
    _bounded(root, "fetch", "--quiet", "--no-tags", "--no-recurse-submodules", "origin",
             "refs/heads/%s:refs/remotes/origin/%s" % (branch, branch))


def _bounded(root, *args):
    """`git <args>` output, or None when it fails or does not finish in time.

    No prompts and a bounded wait (TRUNK_TRUST_LS_REMOTE_TIMEOUT, default 20 s): an unreachable host
    or a credential prompt falls back to the offline rule instead of hanging the caller."""
    try:
        timeout = float(os.environ.get("TRUNK_TRUST_LS_REMOTE_TIMEOUT", "20"))
    except ValueError:
        timeout = 20.0
    # A floor: 0, a negative or NaN would time out at once and pick the offline rule for the caller.
    if not timeout >= 1:
        timeout = 1.0 if timeout > 0 else 20.0
    env = dict(git_env(), GIT_TERMINAL_PROMPT="0")
    p = subprocess.Popen(["git", "-C", root, *args],
                         stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                         env=env, start_new_session=True)
    try:
        out, _ = p.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        # The whole group: a transport child (ssh) would otherwise hold the pipe open.
        os.killpg(p.pid, signal.SIGKILL)
        p.communicate()
        return None
    return out if p.returncode == 0 else None


def repo_root():
    rc, out = git("rev-parse", "--show-toplevel")
    if rc != 0:
        raise Refused("not inside a git repository")
    return out.decode().strip()


def switch_on(root, key, what):
    """Refuses unless `workflow.<key>` is literally true in the project profile."""
    try:
        with open(os.path.join(root, PROFILE_FILE), encoding="utf-8") as f:
            on = (json.load(f).get("workflow") or {}).get(key) is True
    except (OSError, ValueError, AttributeError):
        on = False
    if not on:
        raise Refused("%s is off — set workflow.%s: true in %s" % (what, key, PROFILE_FILE))


def _local_sha(root, branch):
    rc, out = git("-C", root, "rev-parse", "--verify", "--quiet", "refs/remotes/origin/%s^{commit}" % branch)
    return out.decode().strip() if rc == 0 else None


def default_branch(root, refresh=False):
    """(sha, name, online) of origin's default branch: origin's answer when it gives one, else the
    local origin/HEAD symref (the offline rule — local refs are trusted). `refresh` fetches a stale
    local origin/<default> once before comparing."""
    remote = ls_remote(root, "--symref", "origin", "HEAD")
    if remote is not None:
        name = re.search(rb"^ref: refs/heads/(\S+)\tHEAD$", remote, re.M)
        sha = re.search(rb"^([0-9a-f]{40,64})\tHEAD$", remote, re.M)
        if not name or not sha:
            raise Refused("origin does not report a default branch (HEAD)")
        d = name.group(1).decode()
        local = _local_sha(root, d)
        if refresh and local != sha.group(1).decode():
            fetch_branch(root, d)
            local = _local_sha(root, d)
        if local is None:
            raise Refused("no origin/%s ref (origin's default branch) — run: git fetch origin %s" % (d, d))
        if local != sha.group(1).decode():
            raise Refused("origin/%s does not match what origin has — fetch it, do not rewrite it" % d)
        return local, d, True
    rc, out = git("-C", root, "symbolic-ref", "-q", "refs/remotes/origin/HEAD")
    head = out.decode().strip()
    if rc != 0 or not head.startswith("refs/remotes/origin/"):
        raise Refused("origin does not answer and there is no local origin/HEAD — run: git remote set-head "
                      "origin --auto (online), or git remote set-head origin <default-branch>")
    d = head[len("refs/remotes/origin/"):]
    local = _local_sha(root, d)
    if local is None:
        raise Refused("origin/HEAD points to origin/%s, which does not exist locally — fetch it" % d)
    return local, d, False


# A file branch-model.sh would source is refused rather than read from the working tree.
# `source`/`.` in command position: at a line start or after ; & | ( { or then/do/else.
SOURCES = re.compile(rb"(?:^|[;&|({]|\b(?:then|do|else))[ \t]*(?:source|\.)[ \t]+(\S+)", re.M)


def trunk(root, sha, d):
    """The Trunk name in CLAUDE.md on origin's default branch, parsed by that commit's own
    branch-model.sh in a private temp dir — nothing of the working tree takes part."""
    blobs = {}
    for path in ("CLAUDE.md", ".claude/lib/branch-model.sh"):
        rc, blobs[path] = git("-C", root, "show", "%s:%s" % (sha, path))
        if rc != 0:
            raise Refused("%s is not on origin/%s (origin's default branch) — the Trunk name is read from there"
                          % (path, d))
    m = SOURCES.search(blobs[".claude/lib/branch-model.sh"])
    if m:
        raise Refused("branch-model.sh on origin/%s sources %s — refusing to read the Trunk name with it"
                      % (d, m.group(1).decode("utf-8", "replace")))
    try:
        tmp = tempfile.mkdtemp(prefix="trunk-trust-")  # 0700
    except OSError as e:
        raise Refused("cannot create a temp dir to read the Trunk name from origin/%s: %s" % (d, e))
    try:
        try:
            for name, path in (("CLAUDE.md", "CLAUDE.md"), ("branch-model.sh", ".claude/lib/branch-model.sh")):
                with open(os.path.join(tmp, name), "wb") as f:
                    f.write(blobs[path])
        except OSError as e:
            raise Refused("cannot write origin/%s's Branch model to a temp dir: %s" % (d, e))
        env = {k: os.environ[k] for k in ("PATH", "LANG", "LC_ALL", "LC_CTYPE") if k in os.environ}
        try:
            r = subprocess.run(["bash", "branch-model.sh", "fields"], cwd=tmp, env=env, stdin=subprocess.DEVNULL,
                               capture_output=True, text=True, timeout=30)
        except subprocess.TimeoutExpired:
            raise Refused("branch-model.sh on origin/%s did not finish" % d)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    if r.returncode == 0:
        for line in r.stdout.splitlines():
            if line.startswith("trunk=") and line[6:].strip():
                return line[6:].strip()
    raise Refused("CLAUDE.md on origin/%s (origin's default branch) has no Trunk in its Branch model" % d)


def verified_trunk(root, refresh=False):
    """(sha, label) of origin/<Trunk>, the Trunk name taken from origin's default branch; `label`
    names the ref used in every message. Online, each ref is checked against what origin has."""
    dsha, d, online = default_branch(root, refresh)
    t = trunk(root, dsha, d)
    if t == d:
        return dsha, "origin/%s" % t
    label = "origin/%s (Trunk per CLAUDE.md on origin/%s)" % (t, d)
    sha = _local_sha(root, t)
    if sha is None:
        raise Refused("no %s ref — fetch it first" % label)
    remote = ls_remote(root, "--heads", "origin", "refs/heads/%s" % t) if online else None
    if refresh and remote and remote.split()[:1] != [sha.encode()]:
        fetch_branch(root, t)
        sha = _local_sha(root, t) or sha
    if online and remote is None:
        # Origin answered for its default branch; a second query that fails is not "offline".
        raise Refused("origin did not answer for %s — retry when it does" % label)
    if remote == b"":
        raise Refused("%s is not on origin — it must be pushed first" % label)
    if remote is not None and remote.split()[:1] != [sha.encode()]:
        raise Refused("%s does not match what origin has — fetch it, do not rewrite it" % label)
    return sha, label


def at_trunk(root, trusted, path):
    """The bytes of a tracked `path` when the working tree equals its blob at the verified trunk sha."""
    sha, ref = trusted
    if git("-C", root, "ls-files", "--error-unmatch", "--", path)[0] != 0:
        raise Refused("%s is not tracked by git — it must be committed and reach %s" % (path, ref))
    # Read the blob from the verified sha, not "origin/<t>": a local branch or tag of that name wins
    # git's ref lookup over refs/remotes/origin/<Trunk>.
    rc, blob = git("-C", root, "show", "%s:%s" % (sha, path))
    if rc != 0:
        raise Refused("%s is not on %s — a change must reach trunk first" % (path, ref))
    try:
        with open(os.path.join(root, path), "rb") as f:
            work = f.read()
    except OSError:
        raise Refused("%s cannot be read" % path)
    if work != blob:
        raise Refused("%s differs from %s — a change must reach trunk first" % (path, ref))
    return blob


def config_at_trunk(root, path, validate, refresh=False):
    """(validate(parsed trunk blob of `path`), trusted) — the config is read from trunk, not the tree.
    `refresh`: fetch stale origin/<default> and origin/<Trunk> first (unattended callers)."""
    trusted = verified_trunk(root, refresh)
    blob = at_trunk(root, trusted, path)
    try:
        return validate(json.loads(blob.decode("utf-8"))), trusted
    except (ValueError, UnicodeDecodeError) as e:
        raise Refused("%s on %s is invalid: %s" % (path, trusted[1], e))
