"""Guarded cloud writes (opt-in kit): run an allow-listed write under a separate write profile.

    bash .claude/lib/guarded-writes/az-write.sh <az arguments...>
    bash .claude/lib/guarded-writes/ops-write.sh [--confirm WORD] <script> [script args...]
    bash .claude/lib/guarded-writes/sqlcmd-write.sh -S <server> -d <db> (-i <file.sql> | -Q "<sql>")

Contract and Operator setup: .agents/reference/guarded-writes.md.

The model: the default `az` login is a read-only identity, so a write that slips past a rule gets a
403; the only write path is this wrapper, which sits in the settings `ask` tier (every call is an
Operator click), switches to the write profile `$HOME/.azure-write`, and logs the call with secrets
masked. It refuses unless all of these hold:

- `.claude/project-profile.json` has `workflow.guarded_writes: true`;
- `.claude/guarded-writes.json` is tracked by git and byte-identical to its version on
  `origin/<Trunk>` (Trunk from CLAUDE.md on origin's default branch); when origin answers, the local
  `origin/<Trunk>` must also equal what origin has — widening the allow-list needs a change that
  reached trunk. The config is parsed from that trunk blob, not from the working tree;
- the operation and every option match the config's schema (ops-write: the script is listed and
  itself byte-identical to trunk; sqlcmd-write: server/database pinned, plain SQL only, the
  destructive-SQL classifier does not deny it).

Honest limits: this is a hurdle, not isolation. The same OS user can rewrite local refs offline, edit
CLAUDE.md, or push trunk where the project lets it. The real barriers are the read-only default
identity and the Operator's click on the ask rule. Exit codes: 2 refused · otherwise the tool's own.
"""
import os
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import time
import types
from urllib.parse import unquote, urlsplit


def _trust():
    """The shared trust code, compiled from its source: an import could pick up a planted .pyc."""
    path = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "trunk-trust", "trunk_trust.py")
    mod = types.ModuleType("trunk_trust")
    mod.__file__ = path
    with open(path, "rb") as f:
        exec(compile(f.read(), path, "exec"), mod.__dict__)
    return mod


_t = _trust()
Refused, at_trunk, config_at_trunk, repo_root, switch_on = (
    _t.Refused, _t.at_trunk, _t.config_at_trunk, _t.repo_root, _t.switch_on)

CONFIG = ".claude/guarded-writes.json"
CLASSIFIER = ".claude/hooks/lib/guard_destructive_sql.py"
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


def load_config(root):
    return config_at_trunk(root, CONFIG, validate)


def _strings(v, what):
    if not isinstance(v, list) or not all(isinstance(x, str) and x for x in v):
        raise ValueError("%s must be a list of strings" % what)
    return v


def validate(c):
    if not isinstance(c, dict) or c.get("v") != 1 \
            or {k for k in c if not k.startswith("_")} - {"v", "az", "ops", "sql"}:
        raise ValueError('top level must be {"v": 1, "az": {...}, "ops": {...}, "sql": {...}}')
    ops_cfg = c.get("ops") or {}
    if not isinstance(ops_cfg, dict) or set(ops_cfg) - {"scripts", "confirm_words", "deny_args"}:
        raise ValueError("ops takes scripts, confirm_words and deny_args")
    for k in ("scripts", "confirm_words", "deny_args"):
        _strings(ops_cfg.get(k, []), "ops %s" % k)
    if any(x.startswith("/") or ".." in x.split("/") for x in ops_cfg.get("scripts", [])):
        raise ValueError("ops scripts are repo-relative paths")
    sql = c.get("sql") or {}
    if not isinstance(sql, dict) or set(sql) - {"servers", "databases"}:
        raise ValueError("sql takes servers and databases")
    if sql and not _strings(sql.get("servers", []), "sql servers"):
        raise ValueError("sql needs at least one server")
    _strings(sql.get("databases", []), "sql databases")
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

    no_overrides(argv)
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


def write_env(home):
    """The clean environment for a write: the allow-list plus the write profile."""
    profile = os.path.join(home, ".azure-write")
    if not os.path.isfile(os.path.join(profile, "azureProfile.json")):
        raise Refused("no write profile at %s — Operator: AZURE_CONFIG_DIR=%s az login" % (profile, profile))
    env = {k: os.environ[k] for k in ENV_KEEP if k in os.environ}
    env["AZURE_EXTENSION_DIR"] = os.path.join(home, ".azure", "cliextensions")
    env["AZURE_CONFIG_DIR"] = profile
    return env


def execute(tool, cmd, env, log_path, record, cwd=None, stdin=None):
    log(log_path, "cwd=%s\t%s" % (os.getcwd(), record))
    try:
        rc = subprocess.run(cmd, env=env, cwd=cwd, input=stdin).returncode
    except OSError as e:
        rc = 127
        print("%s: cannot run %s: %s" % (tool, cmd[0], e), file=sys.stderr)
    log(log_path, "rc=%s" % rc)
    return rc


def no_overrides(args):
    if any("AZURE_CONFIG_DIR" in a or "AZURE_EXTENSION_DIR" in a for a in args):
        raise Refused("profile overrides are not allowed")


def run_az(home, root, config, trusted, argv):
    az = config.get("az") or {}
    op_name, seen, aliases = parse(argv, az.get("ops") or {})
    if op_name == "rest":
        check_rest(seen, az.get("rest") or [])
    env = write_env(home)
    return execute("az-write", ["az", *argv], env, os.path.join(home, ".agent-ops", "az-write.log"),
                   "az %s" % masked(argv, aliases))


def run_ops(home, root, config, trusted, argv):
    ops = config.get("ops") or {}
    word = ""
    if argv[:1] == ["--confirm"]:
        if len(argv) < 2 or argv[1] not in ops.get("confirm_words", []):
            raise Refused("--confirm takes one of: %s" % (" ".join(ops.get("confirm_words", [])) or "(none configured)"))
        word, argv = argv[1], argv[2:]
    if not argv:
        raise Refused("usage: ops-write.sh [--confirm WORD] <script> [args...]")
    script, args = argv[0], argv[1:]
    if script not in ops.get("scripts", []):
        raise Refused("script not on the allow-list: %s" % script)
    # The script runs with the write profile, so it must be the reviewed trunk version too.
    at_trunk(root, trusted, script)
    no_overrides(args)
    for a in args:
        if a.startswith("@") or "=@" in a:
            raise Refused("file-prefixed values (@file) are not allowed")
        if any(a == d or a.startswith(d + "=") for d in ops.get("deny_args", [])):
            raise Refused("%s is not allowed here — the Operator runs it in their own terminal" % a.split("=")[0])
    env = write_env(home)
    return execute("ops-write", ["bash", script, *args], env, os.path.join(home, ".agent-ops", "ops-write.log"),
                   "%s %s confirm=%s" % (script, masked(args, ALIASES), word or "-"), cwd=root,
                   stdin=(word + "\n").encode() if word else b"")


# sqlcmd: plain SQL only. Directives (`:r`, `:setvar`, `:connect`, `!!`) and `$(var)` would run
# something the classifier never saw, so they are refused; -b makes a SQL error a non-zero exit.
SQL_VALUED = {"-S", "-d", "-i", "-Q", "-h", "-s", "-w"}
SQL_FLAGS = {"-W"}
SQL_LITERAL = re.compile(r"'(?:[^']|'')*'")
# A line sqlcmd reads as a command, not SQL: `:` directives, `!!`, and the colon-less `ED`.
SQL_DIRECTIVE = re.compile(r"(:|!!|ed\s*$)", re.I)
# Strings, quoted identifiers and comments, in sqlcmd's reading order; only identifiers survive.
SQL_TOKEN = re.compile(r"'(?:[^']|'')*'|\[(?:[^\]]|\]\])*\]|\"(?:[^\"]|\"\")*\"|/\*.*?\*/|--[^\n]*", re.S)
NAME_PART = r"(?:\[(?:[^\]]|\]\])*\]|\"(?:[^\"]|\"\")*\"|[A-Za-z_#][\w@#$]*)"
DOTTED = re.compile(r"(?<![\w@#$.\]\"])%s?(?:\s*\.\s*%s?){2,}" % (NAME_PART, NAME_PART))


def other_database(text, db):
    """A `USE` or a 3+-part name aiming past -d (a partial pin: dynamic SQL is not seen)."""
    code = SQL_TOKEN.sub(lambda m: m.group(0) if m.group(0)[0] in '["' else " ", text)
    if re.search(r"\buse\b", SQL_TOKEN.sub(" ", text), re.I):
        return "USE is not allowed — the statement must stay in -d %s" % db
    for m in DOTTED.finditer(code):
        names = [""]
        for tok in re.findall(NAME_PART + r"|\.", m.group(0)):
            if tok == ".":
                names.append("")
            else:
                names[-1] = tok
        first = names[0]
        if first[:1] in '["':
            first = first[1:-1].replace(first[0] * 2, first[0])
        if len(names) > 3 or first.lower() != db.lower():
            return "a multi-part name reaches past -d %s: %s" % (db, m.group(0).strip())
    return None


def run_sql(home, root, config, trusted, argv):
    sql = config.get("sql") or {}
    if not sql.get("servers"):
        raise Refused("sql is not configured — add sql.servers to %s" % CONFIG)
    no_overrides(argv)
    opts, i = {}, 0
    while i < len(argv):
        a = argv[i]
        if a in SQL_FLAGS:
            val = None
        elif a in SQL_VALUED and i + 1 < len(argv):
            val, i = argv[i + 1], i + 1
        else:
            raise Refused("sqlcmd option not accepted: %s (allowed: %s)" % (a, " ".join(sorted(SQL_VALUED | SQL_FLAGS))))
        if a in opts:
            raise Refused("option %s given twice" % a)
        opts[a] = val
        i += 1
    if opts.get("-S") not in sql["servers"]:
        raise Refused("-S must be one of: %s" % " ".join(sql["servers"]))
    if not opts.get("-d") or (sql.get("databases") and opts["-d"] not in sql["databases"]):
        raise Refused("-d is required%s" % (" and must be one of: " + " ".join(sql["databases"]) if sql.get("databases") else ""))
    if ("-i" in opts) == ("-Q" in opts):
        raise Refused("give the statement with exactly one of -i <file.sql> or -Q \"<sql>\"")
    if "-i" in opts:
        try:
            with open(os.path.abspath(opts["-i"]), "rb") as f:
                text = f.read().decode("utf-8")
        except (OSError, UnicodeDecodeError):
            raise Refused("cannot read %s as UTF-8" % opts["-i"])
    else:
        text = opts["-Q"]
    # sqlcmd drops a leading BOM, so `<BOM>:r file` must read as the directive it is.
    if text.startswith("\ufeff"):
        text = text[1:]
    if "$(" in text or any(SQL_DIRECTIVE.match(l.lstrip()) for l in text.splitlines()):
        raise Refused("sqlcmd directives (:r, :setvar, :connect, !!) and $(variables) are not allowed")
    reason = other_database(text, opts["-d"])
    if reason:
        raise Refused(reason)
    tmpdir = tempfile.mkdtemp(prefix="sqlcmd-write-")
    try:
        # Classify and run the same bytes: a private copy, not the caller's file.
        stmt = os.path.join(tmpdir, "statement.sql")
        with open(os.open(stmt, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), "w", encoding="utf-8") as f:
            f.write(text)
        try:
            # The classifier gates a write-profile run, so it must be the trunk version too: compiled
            # from that blob, never from the working tree or a cached .pyc beside it.
            cls = types.ModuleType("guard_destructive_sql")
            cls.__file__ = os.path.join(root, CLASSIFIER)
            exec(compile(at_trunk(root, trusted, CLASSIFIER), cls.__file__, "exec"), cls.__dict__)
            decision, reason = cls.classify(
                "sqlcmd -S %s -d %s -i %s" % (shlex.quote(opts["-S"]), shlex.quote(opts["-d"]), shlex.quote(stmt)),
                root, root)
        except Exception as e:  # fail closed: no verdict, no run
            raise Refused("the destructive-SQL classifier failed (%s) — refusing to run" % e)
        if decision == "deny":
            raise Refused("refused: %s" % reason)
        args = []
        for k, v in opts.items():
            if k == "-Q":
                continue
            args += [k, stmt if k == "-i" else v] if v is not None else [k]
        if "-Q" in opts:
            args += ["-i", stmt]
        env = write_env(home)
        record = "sqlcmd -S %s -d %s %s" % (opts["-S"], opts["-d"], SQL_LITERAL.sub("'<masked>'", text))
        return execute("sqlcmd-write", ["sqlcmd", "--authentication-method", "ActiveDirectoryAzCli", "-b", *args],
                       env, os.path.join(home, ".agent-ops", "sqlcmd-write.log"), record)
    finally:
        shutil.rmtree(tmpdir, ignore_errors=True)


TOOLS = {"az": ("az-write", run_az), "ops": ("ops-write", run_ops), "sql": ("sqlcmd-write", run_sql)}


def main(argv):
    if len(argv) < 2 or argv[0] not in TOOLS:
        print("usage: guarded_write.py az|ops|sql <arguments...>", file=sys.stderr)
        return 2
    name, run = TOOLS[argv[0]]
    try:
        home = os.path.expanduser("~")
        root = repo_root()
        switch_on(root, "guarded_writes", "guarded writes")
        config, trusted = load_config(root)
        return run(home, root, config, trusted, argv[1:])
    except Refused as e:
        print("%s: %s" % (name, e), file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
