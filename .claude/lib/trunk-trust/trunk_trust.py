"""Trunk trust for the opt-in kits (guarded writes, local env runner): one copy of the rule.

A kit's config (and any script it vouches for) counts only when it is tracked by git and
byte-identical to its blob at a verified `origin/<Trunk>` (Trunk from the CLAUDE.md Branch model);
when origin answers, the local `origin/<Trunk>` must also equal what origin has. Widening what an
agent may do therefore needs a change that reached trunk. Offline, the local ref is trusted — same
OS user, so a hurdle, not isolation (each kit's reference doc states the limits).
"""
import json
import os
import signal
import subprocess

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


def ls_remote_head(root, t):
    """origin's sha line for refs/heads/<t>, or None when origin does not answer in time.

    No prompts and a bounded wait (TRUNK_TRUST_LS_REMOTE_TIMEOUT, default 20 s): an unreachable host
    or a credential prompt falls back to the offline rule instead of hanging the caller."""
    try:
        timeout = float(os.environ.get("TRUNK_TRUST_LS_REMOTE_TIMEOUT", "20"))
    except ValueError:
        timeout = 20.0
    env = dict(git_env(), GIT_TERMINAL_PROMPT="0")
    p = subprocess.Popen(["git", "-C", root, "ls-remote", "--heads", "origin", "refs/heads/%s" % t],
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


def trunk(root):
    r = subprocess.run(["bash", os.path.join(root, ".claude", "lib", "branch-model.sh"), "fields"],
                       capture_output=True, text=True, cwd=root)
    if r.returncode == 0:
        for line in r.stdout.splitlines():
            if line.startswith("trunk=") and line[6:].strip():
                return line[6:].strip()
    raise Refused("no Trunk in the CLAUDE.md Branch model — the config is approved against origin/<Trunk>")


def verified_trunk(root):
    """(sha, trunk) of the local origin/<Trunk>, checked against origin when origin answers."""
    t = trunk(root)
    rc, local_sha = git("-C", root, "rev-parse", "--verify", "--quiet", "refs/remotes/origin/%s^{commit}" % t)
    if rc != 0:
        raise Refused("no origin/%s ref — fetch it first" % t)
    remote = ls_remote_head(root, t)
    if remote is not None and remote.split()[:1] != [local_sha.strip()]:
        raise Refused("origin/%s does not match what origin has — fetch it, do not rewrite it" % t)
    return local_sha.decode().strip(), t


def at_trunk(root, trusted, path):
    """The bytes of a tracked `path` when the working tree equals its blob at the verified trunk sha."""
    sha, t = trusted
    if git("-C", root, "ls-files", "--error-unmatch", "--", path)[0] != 0:
        raise Refused("%s is not tracked by git — it must be committed and reach origin/%s" % (path, t))
    # Read the blob from the verified sha, not "origin/<t>": a local branch or tag of that name wins
    # git's ref lookup over refs/remotes/origin/<t>.
    rc, blob = git("-C", root, "show", "%s:%s" % (sha, path))
    if rc != 0:
        raise Refused("%s is not on origin/%s — a change must reach trunk first" % (path, t))
    try:
        with open(os.path.join(root, path), "rb") as f:
            work = f.read()
    except OSError:
        raise Refused("%s cannot be read" % path)
    if work != blob:
        raise Refused("%s differs from origin/%s — a change must reach trunk first" % (path, t))
    return blob


def config_at_trunk(root, path, validate):
    """(validate(parsed trunk blob of `path`), trusted) — the config is read from trunk, not the tree."""
    trusted = verified_trunk(root)
    blob = at_trunk(root, trusted, path)
    try:
        return validate(json.loads(blob.decode("utf-8"))), trusted
    except (ValueError, UnicodeDecodeError) as e:
        raise Refused("%s on origin/%s is invalid: %s" % (path, trusted[1], e))
