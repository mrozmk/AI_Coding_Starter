"""Guarded cloud writes (opt-in kit): run an allow-listed write under a separate write profile.

    bash .claude/lib/guarded-writes/az-write.sh <az arguments...>

The model: the default `az` login is a read-only identity, so a write that slips past a rule gets a
403; the only write path is this wrapper, which sits in the settings `ask` tier (every call is an
Operator click), switches to the write profile `$HOME/.azure-write`, and logs the call with secrets
masked. It refuses unless all of these hold:

- `.claude/project-profile.json` has `workflow.guarded_writes: true`;
- `.claude/guarded-writes.json` is tracked by git and byte-identical to its version on
  `origin/<Trunk>` (Trunk from the CLAUDE.md Branch model); when origin answers, the local
  `origin/<Trunk>` must also equal what origin has — widening the allow-list needs a change that
  reached trunk. The config is parsed from that trunk blob, not from the working tree;
- the operation and every option match the config's schema.

Honest limits: this is a hurdle, not isolation. The same OS user can rewrite local refs offline, edit
CLAUDE.md, or push trunk where the project lets it. The real barriers are the read-only default
identity and the Operator's click on the ask rule. Exit codes: 2 refused · otherwise az's own.
"""
import json
import os
import re
import subprocess
import sys
import time
from urllib.parse import unquote, urlsplit

CONFIG = ".claude/guarded-writes.json"
PROFILE_FILE = ".claude/project-profile.json"
COMMON = {"--subscription", "--query", "--output", "--only-show-errors"}
ALIASES = {"-n": "--name", "-g": "--resource-group", "-p": "--project", "-m": "--method",
           "-u": "--url", "-r": "--resource", "-b": "--body", "-s": "--slot", "-o": "--output",
           "--uri": "--url", "--org": "--organization"}
# `rest` has a fixed schema; no --headers (a caller could replace the profile's auth) and no
# --output-file (a response could overwrite a local file).
REST_OPTIONS = {"--method", "--url", "--resource", "--body"}
# Only these reach az: no other credential source (e.g. a DevOps PAT variable) rides along.
# AZURE_EXTENSION_DIR is not taken from the caller: extension code runs with the write profile.
ENV_KEEP = ("PATH", "HOME", "USER", "LOGNAME", "LANG", "LC_ALL", "LC_CTYPE", "TMPDIR", "TERM")
SECRET_NAME = re.compile(r"pass(word)?|pwd|secret|token|connection[-_]?string|key|auth|value", re.I)
BEARER = re.compile(r"(bearer\s+)\S+", re.I)


class Refused(Exception):
    pass


def git(*args):
    r = subprocess.run(["git", *args], capture_output=True)
    return r.returncode, r.stdout


def repo_root():
    rc, out = git("rev-parse", "--show-toplevel")
    if rc != 0:
        raise Refused("not inside a git repository")
    return out.decode().strip()


def switch_on(root):
    try:
        with open(os.path.join(root, PROFILE_FILE), encoding="utf-8") as f:
            on = (json.load(f).get("workflow") or {}).get("guarded_writes") is True
    except (OSError, ValueError, AttributeError):
        on = False
    if not on:
        raise Refused("guarded writes are off — set workflow.guarded_writes: true in %s" % PROFILE_FILE)


def trunk(root):
    r = subprocess.run(["bash", os.path.join(root, ".claude", "lib", "branch-model.sh"), "fields"],
                       capture_output=True, text=True, cwd=root)
    if r.returncode == 0:
        for line in r.stdout.splitlines():
            if line.startswith("trunk=") and line[6:].strip():
                return line[6:].strip()
    raise Refused("no Trunk in the CLAUDE.md Branch model — the config is approved against origin/<Trunk>")


def load_config(root):
    t = trunk(root)
    if git("-C", root, "ls-files", "--error-unmatch", "--", CONFIG)[0] != 0:
        raise Refused("%s is not tracked by git — an allow-list must be committed and reach origin/%s"
                      % (CONFIG, t))
    rc, local_sha = git("-C", root, "rev-parse", "--verify", "--quiet", "refs/remotes/origin/%s^{commit}" % t)
    if rc != 0:
        raise Refused("no origin/%s ref — fetch it first" % t)
    rc, remote = git("-C", root, "ls-remote", "--heads", "origin", "refs/heads/%s" % t)
    if rc == 0 and remote.split()[:1] != [local_sha.strip()]:
        raise Refused("origin/%s does not match what origin has — fetch it, do not rewrite it" % t)
    # Read the blob from the verified sha, not "origin/<t>": a local branch or tag of that name wins
    # git's ref lookup over refs/remotes/origin/<t>.
    rc, blob = git("-C", root, "show", "%s:%s" % (local_sha.decode().strip(), CONFIG))
    if rc != 0:
        raise Refused("%s is not on origin/%s — an allow-list change must reach trunk first" % (CONFIG, t))
    try:
        with open(os.path.join(root, CONFIG), "rb") as f:
            work = f.read()
    except OSError:
        raise Refused("%s cannot be read" % CONFIG)
    if work != blob:
        raise Refused("%s differs from origin/%s — an allow-list change must reach trunk first" % (CONFIG, t))
    try:
        return validate(json.loads(blob.decode("utf-8")))
    except (ValueError, UnicodeDecodeError) as e:
        raise Refused("%s on origin/%s is invalid: %s" % (CONFIG, t, e))


def _strings(v, what):
    if not isinstance(v, list) or not all(isinstance(x, str) and x for x in v):
        raise ValueError("%s must be a list of strings" % what)
    return v


def validate(c):
    if not isinstance(c, dict) or c.get("v") != 1 or {k for k in c if not k.startswith("_")} - {"v", "az"}:
        raise ValueError('top level must be {"v": 1, "az": {...}}')
    az = c.get("az") or {}
    if not isinstance(az, dict) or set(az) - {"ops", "rest"}:
        raise ValueError("az takes ops and rest only")
    ops = az.get("ops") or {}
    if not isinstance(ops, dict):
        raise ValueError("az.ops must be an object")
    for name, op in ops.items():
        if name == "rest" or not isinstance(op, dict) or set(op) - {"options", "multi", "pin", "required", "aliases"}:
            raise ValueError("az.ops[%r] is malformed" % name)
        opts = set(_strings(op.get("options", []), "%s options" % name))
        for k in ("multi", "required"):
            if not set(_strings(op.get(k, []), "%s %s" % (name, k))) <= opts:
                raise ValueError("%s %s names an option outside its options" % (name, k))
        pin = op.get("pin", {})
        if not isinstance(pin, dict) or not set(pin) <= opts:
            raise ValueError("%s pin names an option outside its options" % name)
        for k, vals in pin.items():
            _strings(vals, "%s pin %s" % (name, k))
        al = op.get("aliases", {})
        if not isinstance(al, dict) or not all(a in ALIASES and v in opts for a, v in al.items()):
            raise ValueError("%s aliases must map a known short alias to one of its options" % name)
    rest = az.get("rest", [])
    if not isinstance(rest, list):
        raise ValueError("az.rest must be a list")
    for r in rest:
        if not isinstance(r, dict) or set(r) != {"url_prefix", "methods"} \
                or not str(r["url_prefix"]).startswith("https://") or not str(r["url_prefix"]).endswith("/"):
            raise ValueError('az.rest entries are {"url_prefix": "https://host/…/", "methods": [...]}')
        _strings(r["methods"], "rest methods")
    return c


def parse(argv, ops):
    words = []
    for a in argv:
        if a.startswith("-") or len(words) == 5:
            break
        words.append(a)
    op_name = " ".join(words)
    if op_name == "rest":
        schema = {"options": sorted(REST_OPTIONS)}
    elif op_name in ops:
        schema = ops[op_name]
    else:
        raise Refused("operation not on the write allow-list: %s" % (op_name or "(none)"))
    allowed = set(schema.get("options", [])) | COMMON
    multi = set(schema.get("multi", []))
    aliases = dict(ALIASES, **schema.get("aliases", {}))
    seen, last_multi, i = {}, None, len(words)

    def put(key, val):
        nonlocal last_multi
        key = aliases.get(key, key)
        if not key.startswith("--") or (len(key) == 2):
            raise Refused("option form not accepted: %s" % key)
        if key not in allowed:
            raise Refused("option %s is not in the schema of '%s'" % (key, op_name))
        if key in seen:
            raise Refused("option %s given twice" % key)
        seen[key] = [] if val is None else [val]
        last_multi = key if key in multi else None

    if any("AZURE_CONFIG_DIR" in a or "AZURE_EXTENSION_DIR" in a for a in argv):
        raise Refused("profile overrides are not allowed")
    while i < len(argv):
        a = argv[i]
        if a == "--ids" or a.startswith("--ids="):
            raise Refused("--ids is not allowed; name the target with its options")
        if a.startswith("--") and "=" in a:
            put(a.split("=", 1)[0], a.split("=", 1)[1])
        elif a.startswith("-") and len(a) > 1:
            if i + 1 < len(argv) and not argv[i + 1].startswith("-"):
                put(a, argv[i + 1])
                i += 1
            else:
                put(a, None)
        elif last_multi:
            seen[last_multi].append(a)
        else:
            raise Refused("unexpected positional argument: %s" % a)
        i += 1
    for vals in seen.values():
        for v in vals:
            if v.startswith("@"):
                raise Refused("file-prefixed values (@file) are not allowed")
    for key in schema.get("required", []):
        if not seen.get(key):
            raise Refused("'%s' requires %s" % (op_name, key))
    for key, ok in schema.get("pin", {}).items():
        for v in seen.get(key, []):
            if v not in ok:
                raise Refused("%s %s is not allowed for '%s'" % (key, v, op_name))
    return op_name, seen, aliases


def check_rest(seen, rules):
    url = (seen.get("--url") or [""])[0]
    method = (seen.get("--method") or [""])[0].lower()
    if not url or not method:
        raise Refused("rest needs --url and --method")
    # The HTTP client normalizes dot segments, so "<prefix>../" would escape the prefix.
    if "\\" in url or any(s in (".", "..") for s in unquote(urlsplit(url).path).split("/")):
        raise Refused("rest url must not hold dot segments or backslashes: %s" % url)
    for r in rules:
        if url.startswith(r["url_prefix"]) and method in [m.lower() for m in r["methods"]]:
            return
    raise Refused("rest %s %s is not allowed by az.rest" % (method, url))


def masked(argv, aliases):
    out, key = [], None
    for a in argv:
        if a.startswith("--") and "=" in a:
            k, v = a.split("=", 1)
            out.append("%s=%s" % (k, mask_value(k, v)))
            key = k
            continue
        if a.startswith("-"):
            out.append(a)
            key = aliases.get(a, a)
            continue
        out.append(mask_value(key, a) if key else a)
    return " ".join(out)


def mask_value(key, v):
    if key == "--body" or (key and SECRET_NAME.search(key.lstrip("-"))) or v.lstrip()[:1] in ("{", "["):
        return "<masked>"
    if "=" in v:
        name, val = v.split("=", 1)
        if (key and key.endswith("settings")) or SECRET_NAME.search(name):
            return "%s=<masked>" % name
    return BEARER.sub(r"\1<masked>", v)


def log(path, line):
    os.makedirs(os.path.dirname(path), mode=0o700, exist_ok=True)
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
    with os.fdopen(fd, "a", encoding="utf-8") as f:
        # One record per line: a value carrying a newline cannot start a forged record.
        line = line.replace("\\", "\\\\").replace("\n", "\\n").replace("\r", "\\r")
        f.write("%s\t%s\n" % (time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), line))


def run_az(argv):
    home = os.path.expanduser("~")
    root = repo_root()
    switch_on(root)
    config = load_config(root)
    az = config.get("az") or {}
    op_name, seen, aliases = parse(argv, az.get("ops") or {})
    if op_name == "rest":
        check_rest(seen, az.get("rest") or [])
    profile = os.path.join(home, ".azure-write")
    if not os.path.isfile(os.path.join(profile, "azureProfile.json")):
        raise Refused("no write profile at %s — Operator: AZURE_CONFIG_DIR=%s az login" % (profile, profile))
    env = {k: os.environ[k] for k in ENV_KEEP if k in os.environ}
    env["AZURE_EXTENSION_DIR"] = os.path.join(home, ".azure", "cliextensions")
    env["AZURE_CONFIG_DIR"] = profile
    path = os.path.join(home, ".agent-ops", "az-write.log")
    log(path, "cwd=%s\taz %s" % (os.getcwd(), masked(argv, aliases)))
    try:
        rc = subprocess.run(["az", *argv], env=env).returncode
    except OSError as e:
        rc = 127
        print("az-write: cannot run az: %s" % e, file=sys.stderr)
    log(path, "rc=%s" % rc)
    return rc


def main(argv):
    if len(argv) < 2 or argv[0] != "az":
        print("usage: guarded_write.py az <az arguments...>", file=sys.stderr)
        return 2
    try:
        return run_az(argv[1:])
    except Refused as e:
        print("az-write: %s" % e, file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
