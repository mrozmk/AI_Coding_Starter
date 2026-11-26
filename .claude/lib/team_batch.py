"""#322 batch binding: one Operator decision answers several exact network operations, each once.

python3 -I team_batch.py prepare --file <batch.json> --project <clone> --out-dir <decisions dir> --id d-<n>
    validate 1-20 entries {command, cwd, pins[], outputs[]}, write the immutable approval object
    d-<n>.batch.json (canonical JSON), print the rendered block and `sha256: <hex>`; exit 3 refused.
python3 -I team_batch.py candidates --dir <decisions dir> --input <{tool_name,tool_input,cwd} file> --now <utc>
    print `<d-n> <k>` per unused, unexpired, unrevoked entry of an allowed batch matching exactly.
python3 -I team_batch.py claim --dir <decisions dir> --id d-<n> --entry <k> --input <file> --now <utc>
    re-run every check for that entry, then record its use; exit 0 claimed, 1 not.
python3 -I team_batch.py revoke --dir <decisions dir> --id d-<n> --why "<line>"

Match: command and canonical cwd byte-identical, the stored copy's sha256 equal to the decision's
batch_sha256, every pin that existed at open unchanged, every pin absent at open existing now with
its creating entry used, every output still absent, no npm-shrinkwrap.json appearing beside a
pinned package.json. An entry expires 12 h after the answer (the run's end is the caller's check).
The caller holds the run's ask lock around claim (team-ask-hook.sh); this script never takes it and
never follows a symlink. Any read or parse failure is no match. Contract: the #322 spec §8.
"""
import argparse
import calendar
import hashlib
import json
import os
import re
import stat
import sys
import tempfile
import time

sys.dont_write_bytecode = True
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "hooks", "lib"))

MAX_ENTRIES = 20
EXPIRY_S = 12 * 3600


def canonical(obj):
    return json.dumps(obj, sort_keys=True, separators=(",", ":"), ensure_ascii=False)


def sha(data):
    return hashlib.sha256(data.encode("utf-8") if isinstance(data, str) else data).hexdigest()


def read_nofollow(path):
    """The bytes of a regular file, never through a symlink; None when absent or not regular."""
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC)
    except OSError:
        return None
    try:
        if not stat.S_ISREG(os.fstat(fd).st_mode):
            return None
        chunks = []
        while True:
            b = os.read(fd, 1 << 20)
            if not b:
                break
            chunks.append(b)
        return b"".join(chunks)
    finally:
        os.close(fd)


def file_digest(path):
    data = read_nofollow(path)
    return None if data is None else sha(data)


def utc_epoch(s):
    try:
        return calendar.timegm(time.strptime(s, "%Y-%m-%dT%H:%M:%SZ"))
    except (TypeError, ValueError):
        return None


def frontmatter(path):
    data = read_nofollow(path)
    if data is None:
        return None
    lines, fm, n = data.decode("utf-8", "replace").split("\n"), {}, 0
    for line in lines:
        if line == "---":
            n += 1
            if n == 2:
                break
            continue
        if n == 1 and ": " in line:
            k, v = line.split(": ", 1)
            fm.setdefault(k, v)
    return fm if n == 2 else None


def write_atomic(path, text):
    d = os.path.dirname(path)
    fd, tmp = tempfile.mkstemp(prefix=".batch.", dir=d)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(text)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


# --- prepare ------------------------------------------------------------------------------------

class Refused(Exception):
    pass


INSTALL_VERBS = {"npm", "pip", "pip3", "npx", "pipx", "uvx", "yarn", "pnpm", "gem", "cargo", "brew", "apt",
                 "apt-get"}


def install_inputs(command, cwd):
    """(kind, required pins, lock paths) of an install form batch matching supports; kind None for a
    command that is no install; raises Refused for an install form with no recognised inputs."""
    words = command.split()
    if not words:
        return None, [], []
    verb = os.path.basename(words[0])
    args = words[1:]
    # Only a leading installer has its inputs read; one behind `cd … &&`, a wrapper or a pipe would
    # run with no pin at all, so it is refused here.
    rest = args[2:] if verb in ("python3", "python") and args[:2] == ["-m", "pip"] else args
    if any(os.path.basename(w.lstrip("(")) in INSTALL_VERBS for w in rest):
        raise Refused("an installer that is not the entry's first word is not batched — give it its own entry")
    if verb in ("python3", "python") and args[:2] == ["-m", "pip"]:
        verb, args = "pip", args[2:]
    i = 0  # npm's global options may come before its command: `npm --prefix P ci`
    while verb == "npm" and i < len(args) and args[i].startswith("-"):
        i += 2 if args[i] in ("--prefix", "-C", "-w", "--workspace", "--userconfig") else 1
    sub = args[i] if i < len(args) else ""
    if verb == "npm" and sub in ("i", "install", "add", "ci", "in"):
        prefix = cwd
        for i, a in enumerate(args):
            if a == "--prefix" and i + 1 < len(args):
                prefix = os.path.join(cwd, args[i + 1])
            elif a.startswith("--prefix="):
                prefix = os.path.join(cwd, a.split("=", 1)[1])
        prefix = os.path.realpath(prefix)
        locks = [os.path.join(prefix, "package-lock.json")]
        if os.path.lexists(os.path.join(prefix, "npm-shrinkwrap.json")):
            locks = [os.path.join(prefix, "npm-shrinkwrap.json")]
        return "npm", [os.path.join(prefix, "package.json")], locks
    if verb in ("pip", "pip3") and args[:1] == ["install"]:
        req = []
        for i, a in enumerate(args):
            if a in ("-r", "--requirement", "-c", "--constraint") and i + 1 < len(args):
                req.append(os.path.realpath(os.path.join(cwd, args[i + 1])))
            elif re.match(r"^--(requirement|constraint)=", a):
                req.append(os.path.realpath(os.path.join(cwd, a.split("=", 1)[1])))
        if not req:
            raise Refused("an install form with no recognised inputs is not batched (pin a -r or --constraint file)")
        return "pip", req, []
    if verb in ("npx", "pipx", "uvx", "yarn", "pnpm", "gem", "cargo", "brew", "apt", "apt-get"):
        raise Refused("an install form with no recognised inputs is not batched (%s)" % verb)
    return None, [], []


def prepare(a):
    import guard_team_egress as g
    from guard_team_egress_effect import inline_literals
    try:
        with open(a.file, encoding="utf-8") as fh:
            data = json.load(fh)
    except (OSError, ValueError) as e:
        raise Refused("the batch file is unreadable (%s)" % e.__class__.__name__)
    entries = data.get("entries") if isinstance(data, dict) else None
    if not isinstance(entries, list) or not 1 <= len(entries) <= MAX_ENTRIES:
        raise Refused("a batch holds 1-%d entries" % MAX_ENTRIES)
    out, outputs_by = [], {}
    for k, e in enumerate(entries, 1):
        if not isinstance(e, dict) or not isinstance(e.get("command"), str) or not e["command"].strip() \
                or not isinstance(e.get("cwd"), str) or not os.path.isabs(e["cwd"]):
            raise Refused("entry %d needs a command and an absolute cwd" % k)
        cmd, cwd = e["command"], os.path.realpath(e["cwd"])
        if "\n" in cmd or re.search(r"[$`]", inline_literals(cmd)):
            raise Refused("entry %d holds an expansion the Operator cannot read as literal text" % k)
        kind, why = g.bash_effect(cmd, a.project, cwd)
        if kind == "deny":
            raise Refused("entry %d is a hard deny class (%s)" % (k, why))
        outs = []
        for p in e.get("outputs") or []:
            if not isinstance(p, str):
                raise Refused("entry %d: an output is a path" % k)
            full = os.path.realpath(os.path.join(cwd, p))
            if os.path.lexists(full):
                raise Refused("entry %d: output %s exists already" % (k, full))
            outs.append(full)
            outputs_by[full] = k
        pins = []
        for p in e.get("pins") or []:
            path, created = (p.get("path"), p.get("created_by")) if isinstance(p, dict) else (p, None)
            if not isinstance(path, str):
                raise Refused("entry %d: a pin is a path" % k)
            full = os.path.realpath(os.path.join(cwd, path))
            if os.path.isdir(full):
                raise Refused("entry %d: pin %s is a directory — pin regular files" % (k, full))
            digest = file_digest(full)
            if digest is None:
                if os.path.lexists(full):
                    raise Refused("entry %d: pin %s is not a regular file" % (k, full))
                created = created if isinstance(created, int) else outputs_by.get(full)
                if not isinstance(created, int) or not 1 <= created < k:
                    raise Refused("entry %d: pin %s is absent and no earlier entry creates it" % (k, full))
                pins.append({"path": full, "sha256": "absent", "created_by": created})
            else:
                pins.append({"path": full, "sha256": digest, "created_by": None})
        ikind, required, locks = install_inputs(cmd, cwd)
        pinned = {p["path"] for p in pins}
        for r in required:
            if r not in pinned:
                raise Refused("entry %d must pin %s" % (k, r))
        if ikind == "npm" and not any(l in pinned or l in outs for l in locks):
            raise Refused("entry %d must pin %s (or create it as an output)" % (k, locks[0]))
        out.append({"command": cmd, "cwd": cwd, "pins": pins, "outputs": outs})
    obj = {"entries": out}
    text = canonical(obj)
    path = os.path.join(a.out_dir, a.id + ".batch.json")
    # A copy left by an open that failed before publishing its decision may be replaced; never one
    # a published decision owns.
    if os.path.lexists(os.path.join(a.out_dir, a.id + ".md")):
        raise Refused("%s is published already" % a.id)
    write_atomic(path, text + "\n")
    digest = sha(text)
    print(render(a.id, obj, digest))
    print("sha256: " + digest)


def render(did, obj, digest):
    lines = ["%s batch — %d entries (copy sha256 %s):" % (did, len(obj["entries"]), digest[:12])]
    for k, e in enumerate(obj["entries"], 1):
        lines.append("  %d. %s" % (k, e["command"]))
        lines.append("     cwd: %s" % e["cwd"])
        for p in e["pins"]:
            lines.append("     pin: %s %s" % (p["path"], "absent (created by entry %d)" % p["created_by"]
                                              if p["sha256"] == "absent" else "sha256 " + p["sha256"][:12]))
        for o in e["outputs"]:
            lines.append("     creates: %s" % o)
    return "\n".join(lines)


# --- match --------------------------------------------------------------------------------------

def load_batch(d, did):
    """(approval object, state, frontmatter) of an allowed batch decision whose stored copy is its
    own, else None."""
    fm = frontmatter(os.path.join(d, did + ".md"))
    if not fm or fm.get("kind") != "batch" or fm.get("status") not in ("answered", "dispatched") \
            or fm.get("answer_outcome") != "allow" or fm.get("revoked_at"):
        return None
    raw = read_nofollow(os.path.join(d, did + ".batch.json"))
    if raw is None:
        return None
    text = raw.decode("utf-8", "replace").rstrip("\n")
    if not fm.get("batch_sha256") or sha(text) != fm["batch_sha256"]:
        return None
    try:
        obj = json.loads(text)
    except ValueError:
        return None
    st_raw = read_nofollow(os.path.join(d, did + ".batch-state.json"))
    try:
        state = json.loads(st_raw.decode("utf-8")) if st_raw else {}
    except ValueError:
        return None
    if not isinstance(state, dict) or state.get("revoked_at"):
        return None
    return obj, state, fm


def entry_matches(obj, state, fm, k, inp, now):
    entries = obj.get("entries") or []
    if not 1 <= k <= len(entries):
        return False
    e = entries[k - 1]
    used = {u.get("entry") for u in state.get("used") or [] if isinstance(u, dict)}
    at = utc_epoch(fm.get("answered_at"))
    if k in used or at is None or now is None or now - at > EXPIRY_S or now < at:
        return False
    ti = inp.get("tool_input") or {}
    if inp.get("tool_name") != "Bash" or ti.get("command") != e["command"]:
        return False
    cwd = inp.get("cwd")
    if not isinstance(cwd, str) or os.path.realpath(cwd) != e["cwd"]:
        return False
    for p in e["pins"]:
        if p["sha256"] == "absent":
            if file_digest(p["path"]) is None or p["created_by"] not in used:
                return False
        elif file_digest(p["path"]) != p["sha256"]:
            return False
        # npm lockfile precedence: a shrinkwrap appearing beside a pinned manifest changes the input.
        if os.path.basename(p["path"]) == "package.json":
            sw = os.path.join(os.path.dirname(p["path"]), "npm-shrinkwrap.json")
            if os.path.lexists(sw) and sw not in {q["path"] for q in e["pins"]}:
                return False
    return not any(os.path.lexists(o) for o in e["outputs"])


def read_input(path):
    try:
        with open(path, encoding="utf-8") as fh:
            data = json.load(fh)
        return data if isinstance(data, dict) else None
    except (OSError, ValueError):
        return None


def batch_ids(d):
    try:
        names = os.listdir(d)
    except OSError:
        return []
    ids = [n[:-len(".batch.json")] for n in names if re.fullmatch(r"d-[0-9]+\.batch\.json", n)]
    return sorted(ids, key=lambda x: int(x[2:]))


def candidates(a):
    inp, now = read_input(a.input), utc_epoch(a.now)
    if inp is None:
        return 0
    for did in batch_ids(a.dir):
        got = load_batch(a.dir, did)
        if not got:
            continue
        obj, state, fm = got
        for k in range(1, len(obj.get("entries") or []) + 1):
            if entry_matches(obj, state, fm, k, inp, now):
                print("%s %d" % (did, k))
    return 0


def claim(a):
    inp, now = read_input(a.input), utc_epoch(a.now)
    got = load_batch(a.dir, a.id) if inp is not None and re.fullmatch(r"d-[0-9]+", a.id) else None
    if not got or not entry_matches(got[0], got[1], got[2], a.entry, inp, now):
        return 1
    state = got[1]
    used = list(state.get("used") or [])
    used.append({"entry": a.entry, "at": a.now, "digest": sha(canonical(inp))})
    state = dict(state, used=used)
    write_atomic(os.path.join(a.dir, a.id + ".batch-state.json"), canonical(state) + "\n")
    return 0


def revoke(a):
    path = os.path.join(a.dir, a.id + ".batch-state.json")
    raw = read_nofollow(path)
    try:
        state = json.loads(raw.decode("utf-8")) if raw else {}
    except ValueError:
        state = {}
    state = dict(state if isinstance(state, dict) else {}, revoked_at=time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                 why=a.why)
    write_atomic(path, canonical(state) + "\n")
    return 0


def main(argv):
    ap = argparse.ArgumentParser(prog="team_batch.py")
    sub = ap.add_subparsers(dest="op", required=True)
    p = sub.add_parser("prepare")
    for f in ("--file", "--project", "--out-dir", "--id"):
        p.add_argument(f, required=True)
    c = sub.add_parser("candidates")
    for f in ("--dir", "--input", "--now"):
        c.add_argument(f, required=True)
    k = sub.add_parser("claim")
    for f in ("--dir", "--id", "--input", "--now"):
        k.add_argument(f, required=True)
    k.add_argument("--entry", type=int, required=True)
    r = sub.add_parser("revoke")
    for f in ("--dir", "--id", "--why"):
        r.add_argument(f, required=True)
    try:
        a = ap.parse_args(argv)
    except SystemExit as e:
        return 0 if e.code == 0 else 2
    if a.op == "prepare":
        try:
            prepare(a)
        except Refused as e:
            print("refused: %s" % e, file=sys.stderr)
            return 3
        return 0
    return {"candidates": candidates, "claim": claim, "revoke": revoke}[a.op](a)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
