"""Remote build check (opt-in kit): run the project's build/test command on a remote node, never here.

    teams.build_check: "bash \"$HARNESS_MAIN/.claude/lib/remote-build/remote-build-check.sh\""   (no arguments)

The team harness exports HARNESS_MAIN (the main checkout) to the merge check and the role sessions;
the kit refuses to run from inside the repository it checks, so a branch cannot replace this code.

Contract and Operator setup: .agents/reference/remote-build.md.

Runs from the clone checked out at the commit under test: ships HEAD to the node as an incremental
git bundle (only what the node lacks), runs the configured argv there in a throwaway detached
worktree, streams the output and returns the command's exit code. It refuses unless
`workflow.remote_build` is true and both `.claude/remote-build.json` and the node script are
byte-identical to `origin/<Trunk>` in the main checkout the kit lies in — the node is chosen only
through trunk, never by a branch; nothing but HEAD and objects is read from the checked clone.

Exit: the command's code · 124 the command timed out · 75 node unreachable, transfer or node-side
setup failed (no command ran; an ssh failure, 255, also reads 75) · 78 switch off, config or node
script not approved on trunk · 64 called with arguments.
"""
import os
import re
import shlex
import signal
import subprocess
import sys
import tempfile
import types


def _trust():
    """The shared trust code, compiled from its source: an import could pick up a planted .pyc."""
    path = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "trunk-trust", "trunk_trust.py")
    mod = types.ModuleType("trunk_trust")
    mod.__file__ = path
    with open(path, "rb") as f:
        exec(compile(f.read(), path, "exec"), mod.__dict__)
    return mod


_t = _trust()

CONFIG = ".claude/remote-build.json"
NODE_SCRIPT = ".claude/lib/remote-build/remote-build-node.sh"
HOST_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,252}")
PATH_RE = re.compile(r"[A-Za-z0-9_][A-Za-z0-9._/-]*")
NAME_RE = re.compile(r"[A-Z_][A-Z0-9_]*")
# Fixed options only: host-key checking stays as the Operator configured it, and nothing from the
# config becomes an ssh option. `--` ends the options, so the alias can never be read as one.
SSH = ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10",
       "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=4"]


def die(code, msg):
    sys.stderr.write("remote-build: %s\n" % msg)
    sys.stderr.flush()
    sys.exit(code)


def _rel(p, what):
    if not isinstance(p, str) or not PATH_RE.fullmatch(p) or ".." in p.split("/"):
        raise ValueError("%s must be a relative path of [A-Za-z0-9._/-] without '..'" % what)
    return p.rstrip("/") or "."


def validate(c):
    if not isinstance(c, dict):
        raise ValueError("config must be an object")
    allowed = {"v", "host", "repo", "runs", "cwd", "command", "env", "nice", "timeout_s"}
    extra = [k for k in c if not k.startswith("_") and k not in allowed]
    if extra:
        raise ValueError("unknown keys %s" % ", ".join(sorted(extra)))
    if c.get("v") != 1:
        raise ValueError("v must be 1")
    if not isinstance(c.get("host"), str) or not HOST_RE.fullmatch(c["host"]):
        raise ValueError("host must be one ssh alias of [A-Za-z0-9._-] (user, port, key: ~/.ssh/config)")
    c["repo"], c["runs"] = _rel(c.get("repo"), "repo"), _rel(c.get("runs"), "runs")
    if c["repo"] == c["runs"]:
        raise ValueError("runs must differ from repo")
    c["cwd"] = _rel(c.get("cwd", "."), "cwd")
    cmd = c.get("command")
    if not isinstance(cmd, list) or not cmd or not all(isinstance(a, str) and a and "\0" not in a for a in cmd):
        raise ValueError("command must be a non-empty list of strings (an argv, not a shell line)")
    env = c.get("env", {})
    if not isinstance(env, dict) or not all(isinstance(k, str) and NAME_RE.fullmatch(k)
                                            and isinstance(v, str) and "\0" not in v for k, v in env.items()):
        raise ValueError("env must map [A-Z_][A-Z0-9_]* names to strings")
    if not isinstance(c.get("nice", True), bool):
        raise ValueError("nice must be true or false")
    t = c.get("timeout_s", 3600)
    if not isinstance(t, int) or isinstance(t, bool) or not 0 < t <= 86400:
        raise ValueError("timeout_s must be 1..86400")
    return c


def ssh(host, remote, **kw):
    return subprocess.run([*SSH, "--", host, remote], **kw)


def git(*args, **kw):
    # The trust check's env: a caller's GIT_DIR & co. must not swap the repo whose HEAD is shipped.
    return subprocess.run(["git", *args], env=_t.git_env(), **kw)


def drop_remote_bundle(host, path):
    """Best effort: a bundle the node script never ran on would otherwise stay in <runs>."""
    try:
        ssh(host, "rm -f %s" % shlex.quote(path), stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL, timeout=60)
    except subprocess.TimeoutExpired:
        pass


def inside(path, root):
    """True when a parent directory of `path` is `root` — compared by inode, not by name: a symlink or
    a differently cased path on a case-insensitive file system names the same directory."""
    top = os.stat(root)
    p = os.path.dirname(os.path.realpath(path))
    while True:
        if os.path.samestat(os.stat(p), top):
            return True
        parent = os.path.dirname(p)
        if parent == p:
            return False
        p = parent


def run(argv):
    if argv:
        die(64, "takes no arguments — the command lives in %s" % CONFIG)
    try:
        # Two roles. checked: the repository under test (cwd, a team clone — agent ground): only its
        # HEAD and objects are read. trust: the repository this kit lies in (the main checkout): the
        # switch, the config and the node script come from there, checked against its origin/<Trunk>.
        root = _t.repo_root()
        here = os.path.dirname(os.path.abspath(__file__))
        # This code decides which node runs what; taken from the commit under test, a branch could
        # rewrite it. So it must come from outside the checked repository: the main checkout.
        if inside(here, root):
            raise _t.Refused("this kit lies inside the repository it checks — run it from the main checkout: "
                             'bash "$HARNESS_MAIN/.claude/lib/remote-build/remote-build-check.sh"')
        r = git("-C", here, "rev-parse", "--show-toplevel", capture_output=True, text=True)
        if r.returncode != 0:
            raise _t.Refused("this kit is not inside a git checkout — it reads its config from the main checkout")
        trust = r.stdout.strip()
        _t.switch_on(trust, "remote_build", "the remote build check")
        # Unattended: a merge into the default branch since the main checkout's last fetch must not
        # read as a rewritten ref, so stale remote-tracking refs are fetched once (bounded) first.
        c, trusted = _t.config_at_trunk(trust, CONFIG, validate, refresh=True)
        node_script = _t.at_trunk(trust, trusted, NODE_SCRIPT)
    except _t.Refused as e:
        die(78, str(e))
    host, q = c["host"], shlex.quote
    sha = git("-C", root, "rev-parse", "HEAD", capture_output=True, text=True).stdout.strip()
    if not sha:
        die(75, "cannot read HEAD")
    tag = "mc-%s-%d" % (sha[:12], os.getpid())

    if ssh(host, "exit", stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
           timeout=60).returncode != 0:
        die(75, "node %s unreachable over ssh — no command ran (it never runs locally)" % host)

    # What the node already has: its refs and worktree HEADs, so the bundle carries only the rest.
    have = ssh(host, "git -C %s for-each-ref --format='%%(objectname)' 2>/dev/null; "
                     "git -C %s worktree list --porcelain 2>/dev/null | sed -n 's/^HEAD //p'" % (q(c["repo"]), q(c["repo"])),
               stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=120).stdout
    hs = sorted(set(re.findall(r"^[0-9a-f]{40,64}", have.replace("\r", ""), re.M)))
    # One git for all of them: a line per input, "commit" when it peels to a commit we have.
    types_ = git("-C", root, "cat-file", "--batch-check=%(objecttype)", capture_output=True, text=True,
                 input="".join(h + "^{commit}\n" for h in hs)).stdout.splitlines() if hs else []
    excl = ["^" + h for h, ty in zip(hs, types_) if ty == "commit"]

    ref = "refs/mc/" + tag
    tmp = tempfile.mkdtemp(prefix="remote-build-")
    bundle = os.path.join(tmp, tag + ".bundle")
    remote_bundle = "%s/%s.bundle" % (c["runs"], tag)
    try:
        git("-C", root, "update-ref", ref, sha, check=True)
        r = git("-C", root, "bundle", "create", "-q", bundle, ref, *excl, capture_output=True, text=True)
        if r.returncode != 0:
            if "empty bundle" not in r.stderr:
                die(75, "git bundle failed: %s" % r.stderr.strip())
            open(bundle, "wb").close()  # the node already has the commit
        size = os.path.getsize(bundle)
        with open(bundle, "rb") as f:
            try:
                sent = ssh(host, "mkdir -p %s && cat > %s" % (q(c["runs"]), q(remote_bundle)),
                           stdin=f, timeout=1800).returncode == 0
            except subprocess.TimeoutExpired:
                sent = False
            if not sent:
                drop_remote_bundle(host, remote_bundle)
                die(75, "sending the bundle to %s failed" % host)
        print("remote-build: commit %s -> %s (bundle %d bytes)" % (sha, host, size), flush=True)
        env = ["%s=%s" % kv for kv in sorted(c.get("env", {}).items())]
        args = [c["repo"], c["runs"], tag, sha, c["cwd"], "1" if c.get("nice", True) else "0",
                str(c.get("timeout_s", 3600)), str(len(env)), *env, "--", *c["command"]]
        rc = ssh(host, "bash -s -- " + " ".join(q(a) for a in args), input=node_script,
                 timeout=c.get("timeout_s", 3600) + 300).returncode
        if rc == 255:  # ssh failed, maybe before the node script (and its cleanup trap) started
            drop_remote_bundle(host, remote_bundle)
    finally:
        git("-C", root, "update-ref", "-d", ref, capture_output=True)
        for name in os.listdir(tmp):
            os.unlink(os.path.join(tmp, name))
        os.rmdir(tmp)
    print("remote-build: node exit %d" % rc, flush=True)
    return 75 if rc == 255 or rc < 0 else rc


def _stop(signum, _frame):
    raise SystemExit(128 + signum)  # unwinds through `finally`: the local temp ref and dir go too


def main(argv):
    signal.signal(signal.SIGTERM, _stop)
    signal.signal(signal.SIGHUP, _stop)
    try:
        return run(argv)
    except subprocess.TimeoutExpired as e:
        die(75, "ssh did not finish within %ds — the node's own trap cleans up a started run" % e.timeout)
    except (subprocess.CalledProcessError, OSError) as e:
        die(75, "a local git or file step failed: %s" % e)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
