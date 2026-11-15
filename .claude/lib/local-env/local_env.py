"""Local env runner (opt-in kit): run a registered local test runner with one local dev secret.

    bash .claude/lib/local-env/with-local-env.sh <runner-id> [args...]
    bash .claude/lib/local-env/with-local-env.sh --setup-info | --validate-stdin   (local-env-init.sh)

Contract and Operator setup: .agents/reference/local-env-runner.md.

The Operator stores the secret once in ~/.config/<dir>/local.env (local-env-init.sh: TTY, no echo,
mode 600 in a 700 dir); an agent runs a runner the config registers, and the secret reaches only
that child, as one raw environment variable — never argv, never a log, never an error message —
and is masked in the child's stdout/stderr. It refuses unless `workflow.local_env` is true and
`.claude/local-env.json` plus the runner's script are byte-identical to `origin/<Trunk>`.

Exit: the child's code (130 on INT/TERM) · 64 usage / id / argument / BASH_ENV / TMPDIR · 65 file
format or secret charset · 66 file missing · 68 docker target not local · 69 docker service not
running or docker missing · 75 a pass-line runner ended 0 without its line · 77 file/dir owner,
mode, type or symlink · 78 switch off, config or script not approved on trunk.
"""
import errno
import json
import os
import re
import signal
import stat
import subprocess
import sys
import threading
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

CONFIG = ".claude/local-env.json"
# Printable ASCII without space and braces: braces are the mask's own bytes, so a mask can never
# complete a value from its neighbours.
SECRET_RE = re.compile(r"[!-z|~]{8,256}")
NAME_RE = re.compile(r"[A-Z_][A-Z0-9_]*")
ID_RE = re.compile(r"[A-Za-z0-9_][A-Za-z0-9_.-]{0,63}")
FLAG_RE = re.compile(r"--?[A-Za-z0-9][A-Za-z0-9-]*")
ENV_ALLOW = ("PATH", "HOME", "USER", "LOGNAME", "TMPDIR", "LANG", "LC_ALL", "LC_CTYPE", "TERM")
# Names a config may not set or pass: they change how the child's shell or interpreter starts.
ENV_FORBIDDEN = set(ENV_ALLOW) | {"BASH_ENV", "ENV", "SHELLOPTS", "BASHOPTS", "PS4", "IFS", "CDPATH",
                                  "GLOBIGNORE", "PYTHONPATH", "PYTHONHOME", "PYTHONSTARTUP",
                                  "NODE_OPTIONS", "PERL5OPT", "PERL5LIB", "RUBYOPT"}
ENV_FORBIDDEN_PREFIX = ("LD_", "DYLD_", "BASH_FUNC_")
LOCAL_BIND_HOSTS = {"0.0.0.0", "127.0.0.1", "[::]", "[::1]", "::", "::1"}
MAX_FILE = 65536
HIDDEN = b"{hidden}"


def die(code, msg):
    sys.stderr.write("with-local-env: %s\n" % msg)
    sys.stderr.flush()
    sys.exit(code)


# ---- config ----------------------------------------------------------------------------------------

def _env_name(n, what):
    if not isinstance(n, str) or not NAME_RE.fullmatch(n) or n in ENV_FORBIDDEN \
            or n.startswith(ENV_FORBIDDEN_PREFIX):
        raise ValueError("%s: %r is not an allowed environment name" % (what, n))
    return n


def _rel_path(p, what):
    if not isinstance(p, str) or not p or p.startswith("/") or ".." in p.split("/") or "\\" in p:
        raise ValueError("%s must be a repo-relative path without '..'" % what)
    return p


def _keys(d, allowed, what):
    if not isinstance(d, dict):
        raise ValueError("%s must be an object" % what)
    extra = [k for k in d if not k.startswith("_") and k not in allowed]
    if extra:
        raise ValueError("%s: unknown keys %s" % (what, ", ".join(sorted(extra))))


def _regex(rx, what, raw=False):
    # Compiled the way the run matches it (raw = against stdout bytes); re.error is not a ValueError.
    try:
        return re.compile(rx.encode() if raw else rx)
    except re.error as e:
        raise ValueError("%s: bad regex (%s)" % (what, e))


def validate(c):
    _keys(c, {"v", "dir", "key", "docker", "pass_env", "runners"}, "config")
    if c.get("v") != 1:
        raise ValueError("v must be 1")
    if not isinstance(c.get("dir"), str) or not ID_RE.fullmatch(c["dir"]):
        raise ValueError("dir must be one name of [A-Za-z0-9_.-], not starting with a dot")
    if not isinstance(c.get("key"), str) or not NAME_RE.fullmatch(c["key"]):
        raise ValueError("key must match [A-Z_][A-Z0-9_]*")
    if "docker" in c:
        d = c["docker"]
        _keys(d, {"compose_file", "service", "port"}, "docker")
        _rel_path(d.get("compose_file"), "docker.compose_file")
        if not isinstance(d.get("service"), str) or not ID_RE.fullmatch(d["service"]):
            raise ValueError("docker.service must be a compose service name")
        if not isinstance(d.get("port"), int) or isinstance(d["port"], bool) or not 0 < d["port"] < 65536:
            raise ValueError("docker.port must be a port number")
    if not isinstance(c.get("pass_env", []), list):
        raise ValueError("pass_env must be a list")
    for n in c.get("pass_env", []):
        _env_name(n, "pass_env")
    runners = c.get("runners")
    if not isinstance(runners, dict) or not runners:
        raise ValueError("runners must be a non-empty object")
    for rid, r in runners.items():
        what = "runners.%s" % rid
        if not ID_RE.fullmatch(rid):
            raise ValueError("%s: runner ids are [A-Za-z0-9_.-]" % what)
        _keys(r, {"script", "args", "secret_env", "env", "pass_line", "results_line"}, what)
        _rel_path(r.get("script"), what + ".script")
        secret_env = _env_name(r.get("secret_env"), what + ".secret_env")
        args = r.get("args", {})
        _keys(args, set(args) if isinstance(args, dict) else set(), what + ".args")
        for flag, rx in args.items():
            if not FLAG_RE.fullmatch(flag) or not (rx is None or isinstance(rx, str)):
                raise ValueError("%s.args: %r needs null or a value regex" % (what, flag))
            if rx is not None:
                _regex(rx, "%s.args.%s" % (what, flag))
        env = r.get("env", {})
        _keys(env, set(env) if isinstance(env, dict) else set(), what + ".env")
        for n, v in env.items():
            if _env_name(n, what + ".env") == secret_env or not isinstance(v, str) or "\0" in v:
                raise ValueError("%s.env: %s must be a plain value, not the secret's name" % (what, n))
        if "pass_line" in r and (not isinstance(r["pass_line"], str) or not r["pass_line"]):
            raise ValueError("%s.pass_line must be a non-empty line" % what)
        if "results_line" in r and (not isinstance(r["results_line"], str)
                                    or _regex(r["results_line"], what + ".results_line", raw=True).groups != 1):
            raise ValueError("%s.results_line must be a regex with one group (the results dir)" % what)
    return c


def load(root):
    try:
        _t.switch_on(root, "local_env", "the local env runner")
        return _t.config_at_trunk(root, CONFIG, validate)
    except _t.Refused as e:
        die(78, str(e))


def validate_args(spec, args):
    allowed, seen, i = spec.get("args", {}), set(), 0
    while i < len(args):
        a = args[i]
        if a not in allowed:
            die(64, "argument not allowed for this runner: %s" % a)
        if a in seen:
            die(64, "%s given more than once" % a)
        seen.add(a)
        if allowed[a] is not None:
            if i + 1 >= len(args) or not re.fullmatch(allowed[a], args[i + 1]):
                die(64, "%s needs one value matching %s" % (a, allowed[a]))
            i += 1
        i += 1


# ---- docker preflight ------------------------------------------------------------------------------

def base_env(config=None):
    keep = ENV_ALLOW + tuple(config.get("pass_env", [])) if config else ENV_ALLOW
    return {k: os.environ[k] for k in keep if k in os.environ}


def docker(args):
    try:
        return subprocess.run(["docker", *args], env=base_env(), stdin=subprocess.DEVNULL,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=60)
    except FileNotFoundError:
        die(69, "docker not found")
    except subprocess.TimeoutExpired:
        die(69, "docker %s timed out" % args[0])


def running_container(raw, service):
    text = raw.decode("utf-8", "replace").strip()
    try:
        entries = json.loads(text) if text.startswith("[") else \
            [json.loads(line) for line in text.splitlines() if line.strip()]
    except ValueError:
        return None
    for e in entries if isinstance(entries, list) else []:
        if isinstance(e, dict) and e.get("Service") == service and e.get("State") == "running" \
                and isinstance(e.get("Name"), str) and ID_RE.fullmatch(e["Name"]):
            return e["Name"]
    return None


def port_line_ok(line, port):
    host, _, p = line.strip().rpartition(":")
    return p == str(port) and host in LOCAL_BIND_HOSTS


def check_docker(root, d):
    """The engine is a local unix socket and the service publishes its port only on this machine.

    This proves where the infrastructure runs, not where the runner connects: each runner checks
    its own connection target (local-env-runner.md §3)."""
    r = docker(["context", "show"])
    ctx = r.stdout.decode("utf-8", "replace").strip()
    if r.returncode != 0 or not ID_RE.fullmatch(ctx):
        die(68, "cannot resolve a safe docker context name")
    r = docker(["--context", ctx, "context", "inspect", ctx, "--format", "{{.Endpoints.docker.Host}}"])
    if r.returncode != 0 or not r.stdout.decode("utf-8", "replace").strip().startswith("unix://"):
        die(68, "docker context %s is not a local unix socket" % ctx)
    r = docker(["--context", ctx, "compose", "-f", os.path.join(root, d["compose_file"]),
                "ps", "--format", "json", d["service"]])
    name = running_container(r.stdout, d["service"]) if r.returncode == 0 else None
    if not name:
        die(69, "compose service %s is not running — run: docker --context %s compose -f %s up -d"
            % (d["service"], ctx, d["compose_file"]))
    r = docker(["--context", ctx, "port", name, "%d/tcp" % d["port"]])
    lines = [ln for ln in r.stdout.decode("utf-8", "replace").splitlines() if ln.strip()]
    if r.returncode != 0 or not lines:
        die(68, "%s does not publish %d/tcp" % (name, d["port"]))
    for line in lines:
        if not port_line_ok(line, d["port"]):
            die(68, "%s %d/tcp is published on %s, not a local bind" % (name, d["port"], line.strip()))


# ---- the secret file -------------------------------------------------------------------------------

def read_secret(config):
    home = os.environ.get("HOME")
    if not home:
        die(66, "HOME is not set")
    d = os.path.join(home, ".config", config["dir"])
    path = os.path.join(d, "local.env")
    try:
        st = os.lstat(d)
    except FileNotFoundError:
        die(66, "missing %s — run .claude/lib/local-env/local-env-init.sh in your own terminal" % d)
    if not stat.S_ISDIR(st.st_mode) or st.st_uid != os.getuid() or st.st_mode & 0o022:
        die(77, "%s must be a real directory owned by you, not group/other writable" % d)
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC | os.O_NONBLOCK)
    except FileNotFoundError:
        die(66, "missing %s — run .claude/lib/local-env/local-env-init.sh in your own terminal" % path)
    except OSError as e:
        die(77, "%s is a symlink — refused" % path if e.errno == errno.ELOOP
            else "cannot open %s (%s)" % (path, e.strerror))
    try:
        st = os.fstat(fd)
        if not stat.S_ISREG(st.st_mode) or st.st_uid != os.getuid() or stat.S_IMODE(st.st_mode) != 0o600:
            die(77, "%s must be a regular file owned by you with mode 600" % path)
        data = os.read(fd, MAX_FILE + 1)
    finally:
        os.close(fd)
    if len(data) > MAX_FILE:
        die(65, "local.env: larger than 64 KiB")
    try:
        text = data.decode("ascii")
    except UnicodeDecodeError:
        die(65, "local.env: non-ASCII content")
    return parse_env(text, config["key"])


def parse_env(text, key):
    # No message here may quote a line: any of them can hold the value.
    if "\r" in text or "\0" in text:
        die(65, "local.env: CR or NUL byte in the file")
    value = None
    for n, line in enumerate(text.split("\n"), 1):
        if not line or line.startswith("#"):
            continue
        m = re.fullmatch(r"([A-Z_][A-Z0-9_]*)=(.*)", line)
        if not m:
            die(65, "local.env line %d: malformed" % n)
        if m.group(1) != key:
            die(65, "local.env line %d: not the key %s" % (n, key))
        if value is not None:
            die(65, "local.env line %d: duplicate %s" % (n, key))
        value = m.group(2)
    if not value:
        die(65, "local.env: %s is missing or empty" % key)
    if not SECRET_RE.fullmatch(value):
        die(65, "%s: outside the allowed charset/length (see local-env-runner.md)" % key)
    return value


def secret_forms(secret):
    xml = secret.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
    full = xml.replace('"', "&quot;").replace("'", "&apos;")
    return sorted({s.encode("ascii") for s in (secret, xml, full)}, key=len, reverse=True)


# ---- the run ---------------------------------------------------------------------------------------

def mask(buf, secrets):
    for s in secrets:
        buf = buf.replace(s, HIDDEN)
    return buf


class Redactor:
    """Boundary-safe literal masking of a byte stream."""

    def __init__(self, secrets):
        self.secrets = secrets
        self.keep = max(map(len, secrets)) - 1 if secrets else 0
        self.carry = b""

    def feed(self, chunk):
        if not self.keep:
            return chunk
        buf = mask(self.carry + chunk, self.secrets)
        if len(buf) > self.keep:
            out, self.carry = buf[:-self.keep], buf[-self.keep:]
        else:
            out, self.carry = b"", buf
        return out

    def flush(self):
        out, self.carry = mask(self.carry, self.secrets), b""
        return out


class LineWatcher:
    """The first complete raw stdout line matching `regex`; .found = group 1 or the line."""

    def __init__(self, regex):
        self.regex, self.line, self.overflow, self.found = regex, b"", False, None

    def __call__(self, chunk):
        if chunk is None:
            self._match(self.line)
            self.line = b""
            return
        *lines, rest = (self.line + chunk).split(b"\n")
        for line in lines:
            self._match(line)
            self.overflow = False
        self.line = rest
        if len(self.line) > 4096:
            self.line, self.overflow = b"", True

    def _match(self, line):
        if self.found is not None or self.overflow:
            return
        m = self.regex.fullmatch(line.rstrip(b"\r"))
        if m:
            self.found = m.group(1) if self.regex.groups else m.group(0)


def emit(dst, data):
    # A closed consumer (`| head`) must not stop the drain, or the child blocks on a full pipe.
    if dst is None:
        return None
    try:
        dst.write(data)
        dst.flush()
        return dst
    except OSError:
        null = os.open(os.devnull, os.O_WRONLY)
        os.dup2(null, dst.fileno())
        os.close(null)
        return None


def pump(src, dst, secrets, watchers):
    redactor = Redactor(secrets)
    try:
        while True:
            chunk = os.read(src.fileno(), 65536)
            if not chunk:
                break
            for w in watchers:
                w(chunk)
            dst = emit(dst, redactor.feed(chunk))
        emit(dst, redactor.flush())
    except OSError:
        pass
    finally:
        for w in watchers:
            w(None)


def scrub_note(reason):
    sys.stderr.write("with-local-env: results dir not scrubbed — %s\n" % reason)
    sys.stderr.flush()


def scrub(dir_bytes, secrets, tmp_root):
    # Never name the path in a note: it may itself hold the value.
    path = os.fsdecode(dir_bytes)
    if not os.path.isabs(path):
        return scrub_note("path is not absolute")
    if not os.path.realpath(path).startswith(tmp_root + os.sep):
        return scrub_note("not under the temp dir")
    try:
        st = os.lstat(path)
    except OSError:
        return scrub_note("cannot stat it")
    if not stat.S_ISDIR(st.st_mode) or st.st_uid != os.getuid():
        return scrub_note("not a real directory owned by you")
    for d, _, files in os.walk(path, followlinks=False):
        for f in files:
            try:
                fd = os.open(os.path.join(d, f), os.O_RDWR | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC)
            except OSError as e:
                if e.errno != errno.ELOOP:
                    scrub_note("cannot open a file (%s)" % e.strerror)
                continue
            with os.fdopen(fd, "r+b") as h:
                st = os.fstat(fd)
                if not stat.S_ISREG(st.st_mode) or st.st_uid != os.getuid():
                    continue
                data = h.read()
                new = mask(data, secrets)
                if new != data:
                    h.seek(0)
                    h.write(new)
                    h.truncate()


def kill_group(proc, sig):
    try:
        os.killpg(proc.pid, sig)
    except ProcessLookupError:
        pass


def group_alive(proc):
    try:
        os.killpg(proc.pid, 0)
        return True
    except ProcessLookupError:
        return False


def wait_child(proc, got):
    # After a signal the whole group gets the grace period, not just the leader: a descendant that
    # ignores TERM still holds the secret in its env.
    rc, waited = None, 0
    while rc is None or (got and group_alive(proc)):
        if rc is None:
            try:
                rc = proc.wait(timeout=0.5)
            except subprocess.TimeoutExpired:
                pass
        else:
            threading.Event().wait(0.5)
        if got:
            waited += 1
            if waited >= 60:
                kill_group(proc, signal.SIGKILL)
                return proc.wait() if rc is None else rc
    return rc


def run(root, rid, spec, args, env, secrets, tmp_root):
    got, holder = [], []
    env["TMPDIR"] = tmp_root

    def on_signal(sig, _frame):
        got.append(sig)
        if holder and holder[0].poll() is None:
            kill_group(holder[0], sig)

    signal.signal(signal.SIGINT, on_signal)
    signal.signal(signal.SIGTERM, on_signal)
    try:
        proc = subprocess.Popen(["bash", os.path.join(root, spec["script"]), *args], cwd=root, env=env,
                                stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                start_new_session=True)
    except OSError:
        die(69, "cannot start %s" % spec["script"])
    holder.append(proc)
    if got:
        kill_group(proc, got[0])
    passed = LineWatcher(re.compile(re.escape(spec["pass_line"]).encode())) if "pass_line" in spec else None
    results = LineWatcher(re.compile(spec["results_line"].encode())) if "results_line" in spec else None
    watchers = [w for w in (passed, results) if w]
    pumps = [threading.Thread(target=pump, daemon=True, args=(proc.stdout, sys.stdout.buffer, secrets, watchers)),
             threading.Thread(target=pump, daemon=True, args=(proc.stderr, sys.stderr.buffer, secrets, []))]
    for t in pumps:
        t.start()
    try:
        rc = wait_child(proc, got)
        for t in pumps:
            t.join(timeout=5)
    finally:
        if results and results.found:
            scrub(results.found, secrets, tmp_root)
    if got:
        return 130
    if passed and rc == 0 and passed.found is None:
        sys.stderr.write("with-local-env: %s did not report its pass line (skipped or incomplete) — not a pass\n" % rid)
        sys.stderr.flush()
        return 75
    return 128 - rc if rc < 0 else rc


def tmp_root():
    raw = os.environ.get("TMPDIR") or "/tmp"
    if not os.path.isabs(raw) or not os.path.isdir(raw):
        die(64, "TMPDIR must be an existing absolute directory")
    return os.path.realpath(raw)


def validate_stdin():
    data = sys.stdin.buffer.read(258)
    if data.endswith(b"\n"):
        data = data[:-1]
    try:
        ok = bool(SECRET_RE.fullmatch(data.decode("ascii")))
    except UnicodeDecodeError:
        ok = False
    if not ok:
        die(65, "the value must be 8-256 printable ASCII chars, without space and braces")
    sys.exit(0)


def main(argv):
    if argv == ["--validate-stdin"]:
        validate_stdin()
    try:
        root = _t.repo_root()
    except _t.Refused as e:
        die(78, str(e))
    config, trusted = load(root)
    if argv == ["--setup-info"]:
        print("dir=%s\nkey=%s" % (config["dir"], config["key"]))
        sys.exit(0)
    if not argv or argv[0] not in config["runners"]:
        die(64, "usage: with-local-env.sh <%s> [args]" % "|".join(sorted(config["runners"])))
    rid, args = argv[0], argv[1:]
    spec = config["runners"][rid]
    validate_args(spec, args)
    try:
        _t.at_trunk(root, trusted, spec["script"])
    except _t.Refused as e:
        die(78, str(e))
    tmp = tmp_root()
    if "docker" in config:
        check_docker(root, config["docker"])
    secret = read_secret(config)
    env = base_env(config)
    env.update(spec.get("env", {}))
    env[spec["secret_env"]] = secret
    sys.exit(run(root, rid, spec, args, env, secret_forms(secret), tmp))


if __name__ == "__main__":
    main(sys.argv[1:])
