"""Operator touch log: one JSON line per human intervention for a session, per project and machine,
in <main checkout>/.agents/touches/<yyyy-mm>.jsonl. CLI and usage: .claude/lib/touches.sh (add |
block | report | hook). A `block` line (kind block, reason hook) records a hook that refused a call
with no human involved; it is never counted as an Operator touch. A touch with a tool call carries
the optional `input` object: the call's masked tool input, cut only to fit the line. Contract:
.agents/reference/operator-touches.md. Stdlib only and harness-free: the global opt-in copies this
one file as is."""
import argparse, calendar, collections, contextlib, json, os, re, stat, subprocess, sys, time  # noqa: E401

KEYS = ("at", "machine", "who", "where", "kind", "what", "reason", "answer", "wait_s")
HUMAN_KINDS = ("question", "permission", "plan", "text", "decision", "restart", "other")
HUMAN_REASONS = ("human-only", "no-rule", "lead-unsure", "channel-failed", "guard", "direct")
# A hook's automatic refusal: written only by `block`, reported apart from the Operator touches.
KINDS, REASONS = HUMAN_KINDS + ("block",), HUMAN_REASONS + ("hook",)
AT_RE = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$")
MONTH_RE, ASK_RE = re.compile(r"^\d{4}-\d{2}\.jsonl$"), re.compile(r"^a-\d+\.json$")
LINE_MAX, NEAR_S, TAIL_BYTES = 4000, 10, 65536
NO_MAIN = "main checkout unknown — pass --main or set HARNESS_MAIN"
DIR_FLAGS = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC
READ_FLAGS = os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC
APPEND_FLAGS = os.O_RDWR | os.O_APPEND | os.O_CREAT | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC

_KEY = (r"password|passwd|pwd|secret|token|sig|connectionstring|accountkey|sharedaccesskey"
        r"|api[_-]?key|apikey|access[_-]?key|secret[_-]?key|access[_-]?token|auth[_-]?token"
        r"|client[_-]?secret|private[_-]?key")
# A quoted value honours escapes and doubled quotes and may run to the end of a cut text.
_Q = r""""(?:\\.|""|[^"\\])*(?:"|$)|'(?:\\.|''|[^'\\])*(?:'|$)"""
_LABELLED = re.compile(r"""(["']?)(?<![A-Za-z0-9])([A-Za-z0-9_]*?(?:%s))\1(\s*[=:]\s*)(%s|[^\s;&,"'}]+)"""
                       % (_KEY, _Q), re.I)
_FLAGS = re.compile(r"""(--(?:password|secret|token|sas-token|connection-string|account-key))(\s*=\s*|\s+)(%s|\S+)""" % _Q, re.I)
_BEARER = re.compile(r"\b(Bearer\s+)\S+", re.I)
# The known-format tokens of hooks/lib/leak-patterns.sh, prefix kept and length relaxed: a token
# cut by an upstream truncation is still masked.
_HIGH = re.compile(
    r"(?:AKIA|ASIA)[0-9A-Z]{4,}|gh[pousr]_[0-9A-Za-z]{4,}|github_pat_[0-9A-Za-z_]{4,}"
    r"|xox[baprs]-[0-9A-Za-z-]{4,}|xapp-[0-9A-Za-z-]{4,}|glpat-[0-9A-Za-z_-]{4,}|AIza[0-9A-Za-z_-]{4,}"
    r"|sk-(?:ant|proj)-[0-9A-Za-z_-]{4,}|(?:sk|rk)_live_[0-9A-Za-z]{4,}|shp(?:at|ss)_[0-9a-fA-F]{4,}|SG\.[0-9A-Za-z_.-]{4,}"
    r"|ATATT[0-9A-Za-z_=.-]{4,}|npm_[0-9A-Za-z]{4,}|eyJ[0-9A-Za-z_-]{4,}(?:\.[0-9A-Za-z_-]*){0,2}|SK[0-9a-f]{32}"
    r"|(?:postgres(?:ql)?|mysql|mongodb(?:\+srv)?|redis|amqps?|ftp)://[^:@/\s]+:[^@/\s]+@")

# A private-key block to its END line, or to the end of a value cut upstream.
_PEM = re.compile(r"-----BEGIN[A-Z ]*PRIVATE KEY-----(?:.*?-----END[A-Z ]*PRIVATE KEY-----|.*\Z)", re.S)
# A header value, also JSON-quoted ("Authorization": "…"); Authorization stops at a shell
# separator, a Cookie value holds `;` between its pairs.
_AUTHZ = re.compile(r"""((?:Proxy-)?Authorization["']?\s*:\s*["']?)[^\r\n"';|&]+""", re.I)
_COOKIE = re.compile(r"""(Cookie["']?\s*:\s*["']?)[^\r\n"'|&]+""", re.I)
# Scoped to curl: a bare `-u` is also `git push -u origin`; a cluster of curl's argument-less
# flags (-su) or an attached value (-uX:Y) is still the user flag, an attached argument of
# another flag (-Tup.txt) is not. A quoted argument before it may hold `&`, `;` or `|`.
_CURLU = re.compile(r"""(\bcurl\b(?:"[^"\n]*"|'[^'\n]*'|[^\n|;&"'])*?\s(?:-[sSkLvfiIjnNOqRgG0-9#]*u\s*|--user(?:\s+|=)))(%s|\S+)"""
                    % _Q)
_USERINFO = re.compile(r"(\b[a-zA-Z][a-zA-Z0-9+.-]*://)[^/\s@]+@")
# Never an scp-like remote (git@host:path): the egress guard reads its host. The lookbehind starts
# the local part only at a run's start (linear on a long run, not quadratic).
_EMAIL = re.compile(r"(?<![A-Za-z0-9._%+-])[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}\b"
                    r"(?![A-Za-z0-9.-]*:)")
_SECRET_KEY = re.compile(r"[A-Za-z0-9_-]*(?:%s)|(?:proxy-)?authorization|cookie" % _KEY, re.I)
FIELDS = ("command", "url", "file_path", "path", "notebook_path", "skill", "pattern")

def _mask(s):
    s = _LABELLED.sub(lambda m: m.group(1) + m.group(2) + m.group(1) + m.group(3) + "***", _PEM.sub("***", s))
    s = _USERINFO.sub(r"\1***@", _CURLU.sub(r"\1***", _COOKIE.sub(r"\1***", _AUTHZ.sub(r"\1***", s))))
    return _HIGH.sub("***", _BEARER.sub(r"\1***", _FLAGS.sub(r"\1\2***", _EMAIL.sub("***@***", s))))

def mask_value(v):
    """The masked full value: newlines and tabs kept, other control characters as spaces, no cap."""
    return _mask(re.sub(r"[\x00-\x08\x0b-\x1f\x7f]", " ", str(v)))

def mask_obj(o, key=None):
    """A tool_input masked leaf by leaf; a value under a secret-named key is masked whole."""
    if isinstance(o, dict):
        return {k: mask_obj(v, k) for k, v in o.items()}
    if isinstance(o, list):
        return [mask_obj(v, key) for v in o]
    if key is not None and o is not None and _SECRET_KEY.fullmatch(str(key)):
        return "***"
    return mask_value(o) if isinstance(o, str) else o

def _clean(s, cap=200):
    return re.sub(r" {2,}", " ", _mask(re.sub(r"[\x00-\x1f\x7f]", " ", str(s)))).strip()[:cap]

def _ident(s):
    return re.sub(r"[^A-Za-z0-9._-]", "", str(s or ""))[:100]

def _epoch(at):
    try:
        return calendar.timegm(time.strptime(at, "%Y-%m-%dT%H:%M:%SZ"))
    except (TypeError, ValueError):
        return None

def _git(cwd, *args):
    """(returncode, stripped stdout); (None, None) when git cannot run."""
    try:
        r = subprocess.run(["git", "-C", cwd] + list(args), stdout=subprocess.PIPE,
                           stderr=subprocess.DEVNULL, text=True, timeout=10)
        return r.returncode, r.stdout.strip()
    except (OSError, ValueError, TypeError, subprocess.SubprocessError):
        return None, None

def _git_out(cwd, *args):
    rc, out = _git(cwd, *args)
    return out if rc == 0 and out else None

def _json(path):
    try:
        with open(path, encoding="utf-8") as f:
            d = json.load(f)
        return d if isinstance(d, dict) else {}
    except (OSError, ValueError):
        return {}

def _has_agents(d):
    return isinstance(d, str) and bool(d) and os.path.isdir(os.path.join(d, ".agents"))

def resolve_main(explicit, cwd, redirects=True):
    """--main → HARNESS_MAIN → a clone's teamlead.json main_root (never the clone) → primary worktree."""
    if redirects:
        for d in (explicit, os.environ.get("HARNESS_MAIN")):
            if _has_agents(d):
                return os.path.realpath(d)
    top = _git_out(cwd, "rev-parse", "--show-toplevel")
    if not top:
        return None
    if redirects and os.path.isfile(os.path.join(top, ".agents/team/team.json")):
        m = _json(os.path.join(top, ".agents/team/teamlead.json")).get("main_root")
        return os.path.realpath(m) if _has_agents(m) else None
    common = _git_out(cwd, "rev-parse", "--path-format=absolute", "--git-common-dir")
    return os.path.realpath(os.path.dirname(common) if common and common.endswith("/.git") else top)

def _team(project, session_id):
    """(team, ticket, role) of the session in project's repository: the lead's from team.json, a
    stage's from session.json; None outside a clone or with neither."""
    td = os.path.join(_git_out(project, "rev-parse", "--show-toplevel") or project, ".agents/team")
    if not os.path.isfile(os.path.join(td, "team.json")):
        return None
    tj, tl = _json(os.path.join(td, "team.json")), _json(os.path.join(td, "teamlead.json"))
    sj = _json(os.path.join(td, "session.json"))
    run = (_read_regular(os.path.join(td, "run")) or b"").decode("utf-8", "replace").strip()
    lead = bool(session_id and session_id == tl.get("session_id") and tl.get("run") and tl.get("run") == run)
    if lead or (not sj and os.environ.get("TEAM_SESSION_ROLE") == "TeamLead"):
        return tj.get("team", "?"), tj.get("ticket", "?"), "TeamLead"
    return (sj.get("team", "?"), sj.get("ticket", "?"), sj.get("role", "?")) if sj else None

_UNSET = object()

def default_where(main, project, cwd, session_id, team=_UNSET):
    """Team files come from project's repository; cwd only names the solo path. team: an
    already resolved _team() result."""
    t = _team(project, session_id) if team is _UNSET else team
    if t:
        return "team %s / %s / %s" % t
    rel = os.path.relpath(os.path.realpath(cwd), os.path.realpath(main))
    return "solo " + ("?" if rel.startswith("..") else rel)

def _role(project, session_id, team=_UNSET):
    """The role of input: like default_where, else $TEAM_SESSION_ROLE, else solo."""
    t = _team(project, session_id) if team is _UNSET else team
    if t:
        return _ident(t[2]) or "?"
    return _ident(os.environ.get("TEAM_SESSION_ROLE")) or "solo"

def make_input(tool, tool_input, cwd, role, session):
    """The masked projection of a tool call the guard and the tier read; key names for the rest."""
    ti = tool_input if isinstance(tool_input, dict) else {}
    out = {"tool": _clean(tool or "", 100),
           "fields": {k: mask_value(ti[k]) for k in FIELDS if isinstance(ti.get(k), str)}}
    if any(k not in out["fields"] for k in ti):
        out["keys"] = sorted(str(k) for k in ti)
    out.update(cwd=mask_value(cwd) if isinstance(cwd, str) else "", role=_ident(role), session=_ident(session))
    return out

def make_entry(kind, what, reason, answer="", wait_s=None, where=""):
    return {"at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "machine": _ident(os.uname().nodename.split(".")[0]),
            "who": _ident(os.environ.get("USER", "")), "where": _clean(where), "kind": kind,
            "what": _clean(what), "reason": reason, "answer": _clean(answer), "wait_s": wait_s}

def _encode(entry):
    return (json.dumps(entry, ensure_ascii=False) + "\n").encode("utf-8")

def _line(entry):
    line = _encode(entry)
    inp = entry.get("input")
    if len(line) > LINE_MAX and isinstance(inp, dict):
        # The longest input field is cut first; optional evidence never costs the legacy record.
        fields = inp.get("fields") if isinstance(inp.get("fields"), dict) else {}
        while len(line) > LINE_MAX and fields:
            k = max(sorted(fields), key=lambda f: len(fields[f]))
            if len(fields[k]) <= 60:
                break
            inp.setdefault("cut", {}).setdefault(k, len(fields[k]))
            fields[k] = fields[k][:max(60, len(fields[k]) - (len(line) - LINE_MAX))]
            line = _encode(entry)
        if len(line) > LINE_MAX:
            del entry["input"]
            line = _encode(entry)
    if len(line) > LINE_MAX:
        entry.update((k, entry[k][:60]) for k in ("where", "what", "answer"))
        line = _encode(entry)
    return line if len(line) <= LINE_MAX else None

def _err(msg, rc):
    print("error: " + msg, file=sys.stderr)
    return rc

def _pin(base, names, fds, mode=None):
    """Pin base/names... through directory fds (a symlink fails the open), creating with mode."""
    fds.append(os.open(base, os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC))
    for name in names:
        if mode is not None:
            with contextlib.suppress(FileExistsError):
                os.mkdir(name, mode, dir_fd=fds[-1])
        fds.append(os.open(name, DIR_FLAGS, dir_fd=fds[-1]))
    return fds[-1]

def _open_append(dfd, name, mode, fds):
    # O_RDWR for the caller's pread; macOS can fail a concurrent first O_CREAT with ENOENT.
    for attempt in range(3):
        try:
            fds.append(os.open(name, APPEND_FLAGS, mode, dir_fd=dfd))
            break
        except FileNotFoundError:
            if attempt == 2:
                raise
    st = os.fstat(fds[-1])
    return st if stat.S_ISREG(st.st_mode) and st.st_nlink == 1 else None

def append(main, entry):
    """0 written, 1 refused (not a regular single-link file) or failed. Mirrors egress record_touch."""
    line = _line(entry)
    if line is None:
        return 1
    fds, old = [], os.umask(0o077)
    try:
        st = _open_append(_pin(main, (".agents", "touches"), fds, 0o700),
                          entry["at"][:7] + ".jsonl", 0o600, fds)
        if st is None:
            return 1
        # An earlier short write left a fragment: keep it one malformed line, this record whole.
        if st.st_size > 0 and os.pread(fds[-1], 1, st.st_size - 1) != b"\n":
            line = b"\n" + line
        os.write(fds[-1], line)
        return 0
    except (OSError, ValueError, TypeError):
        return 1
    finally:
        os.umask(old)
        list(map(os.close, fds))

def _read_regular(name, dir_fd=None):
    """The bytes of a regular file opened without following a symlink or blocking; else None."""
    try:
        with os.fdopen(os.open(name, READ_FLAGS, dir_fd=dir_fd), "rb") as f:
            return f.read() if stat.S_ISREG(os.fstat(f.fileno()).st_mode) else None
    except OSError:
        return None

def _parse_entry(line):
    """(entry, None) for a valid line, else (None, why)."""
    try:
        e = json.loads(line)
    except ValueError:
        e = None
    if not isinstance(e, dict):
        return None, "bad json"
    bad = ["missing " + k for k in KEYS if k not in e]
    bad += ["bad type " + k for k in KEYS[:-1] if k in e and not isinstance(e[k], str)]
    w = e.get("wait_s")
    bad += [] if w is None or (type(w) is int and w >= 0) else ["bad type wait_s"]
    bad += [] if bad or e["kind"] in KINDS else ["bad kind"]
    bad += [] if bad or e["reason"] in REASONS else ["bad reason"]
    bad += [] if bad or AT_RE.match(e["at"]) else ["bad at"]
    bad += [] if bad or "input" not in e or isinstance(e["input"], dict) else ["bad type input"]
    return (None, bad[0]) if bad else (e, None)

def load(main, since_month=None, only=None):
    """(valid entries, files read, malformed lines, any month file); stderr names every skip."""
    fds, entries, files, bad = [], [], 0, 0
    try:
        try:
            dfd = _pin(main, (".agents", "touches"), fds)
        except OSError:
            return entries, 0, 0, False
        names = sorted(n for n in os.listdir(dfd) if MONTH_RE.match(n))
        for name in names:
            if (since_month and name[:7] < since_month) or (only and name != only):
                continue
            data = _read_regular(name, dfd)
            if data is None:
                print("skipped: %s — not a regular file" % name, file=sys.stderr)
                continue
            files += 1
            for no, raw in enumerate(data.decode("utf-8", errors="replace").splitlines(), 1):
                e, why = _parse_entry(raw) if raw.strip() else (None, None)
                if why:
                    bad += 1
                    print("skipped: %s:%d — %s" % (name, no, why), file=sys.stderr)
                elif e:
                    entries.append(e)
    finally:
        list(map(os.close, fds))
    return entries, files, bad, bool(names)

def norm(what):
    s = re.sub(r"[\"'`]", "", what.lower())
    return re.sub(r"\s+", " ", re.sub(r"\d+", "#", s)).strip()[:48]

def touches_only(entries):
    """The Operator touches: every entry but a hook block (no human acted on it)."""
    return [e for e in entries if e["kind"] != "block"]

def ranked_clusters(entries):
    """[((reason, norm what), entries)] by size, then newest; the hook's generic what never clusters."""
    out = {}
    for e in entries:
        n = norm(e["what"])
        if n and n != "permission prompt" and not n.startswith("claude needs your permission"):
            out.setdefault((e["reason"], n), []).append(e)
    for v in out.values():
        v.sort(key=lambda e: e["at"])
    return sorted(out.items(), key=lambda kv: (len(kv[1]), kv[1][-1]["at"]), reverse=True)

def report(a, main):
    m = re.fullmatch(r"(\d+)d", a.since or "30d")
    since = (time.strftime("%Y-%m-%d", time.gmtime(time.time() - int(m.group(1)) * 86400))
             if m else a.since)
    if not re.fullmatch(r"\d{4}-\d{2}-\d{2}", since):
        return _err("--since YYYY-MM-DD or <n>d", 2)
    entries, files, bad, present = load(main, since[:7])
    if not present:
        print("Operator touches — none recorded")
        return 0
    period = [e for e in entries if e["at"][:10] >= since and a.who in (None, e["who"])]
    sel = [e for e in touches_only(period) if a.reason in (None, e["reason"])]
    print("Operator touches — %d since %s (%d files%s)"
          % (len(sel), since, files, ", %d malformed skipped" % bad if bad else ""))
    groups = {}
    for e in sel:
        groups.setdefault((e["reason"], e["kind"], e["where"]), []).append(e["at"])
    for (r, k, w), ats in sorted(groups.items(), key=lambda kv: max(kv[1]), reverse=True):
        print("  %d  %s  %s  %s  last %s" % (len(ats), r, k, w, max(ats)))
    rec = [kv for kv in ranked_clusters(sel) if len(kv[1]) >= 2][:5]
    if rec:
        print("Recurring")
    for (r, _), v in rec:
        print('  %d× %s — "%s"' % (len(v), r, v[-1]["what"]))
    blocks = [e for e in period if e["kind"] == "block" and a.reason in (None, "hook")]
    if blocks:
        print("Hook blocks (no human) — %d" % len(blocks))
        for (_, _), v in [kv for kv in ranked_clusters(blocks) if len(kv[1]) >= 2][:5]:
            print('  %d× — "%s"' % (len(v), v[-1]["what"]))
    return 0

def brief(a, main):
    m = re.search(r"-(\d{8})-(\d{6})$", a.run or "")
    if not (m and a.team and a.ticket):
        return _err("--brief needs --team, --ticket and --run <name>-<YYYYMMDD>-<HHMMSS>", 2)
    start = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.strptime(m.group(1) + m.group(2), "%Y%m%d%H%M%S"))
    prefix = "team %s / %s / " % (a.team, a.ticket)
    entries = touches_only(load(main)[0])
    mine = [e for e in entries if e["where"].startswith(prefix) and e["at"] >= start]
    pairs = collections.Counter((e["reason"], e["kind"]) for e in mine).most_common()
    tail = ", ".join("%d× %s (%s)" % (n, r, k) for (r, k), n in pairs)
    print("Operator touches: %d%s" % (len(mine), " — " + tail if tail else ""))
    ids = set(id(e) for e in mine)
    for (r, _), v in ranked_clusters(entries):
        if len(v) >= 3 and any(id(e) in ids for e in v):
            print('Recurring: %d× %s — "%s"' % (len(v), r, v[-1]["what"]))
    return 0

def _pending(transcript, msg):
    """(tool, detail, tool_input) of the one pending call (team_transcript.py semantics) the prompt names."""
    if not isinstance(transcript, str) or not transcript:
        return None
    with os.fdopen(os.open(transcript, os.O_RDONLY | os.O_NONBLOCK | os.O_CLOEXEC), "rb") as f:
        st = os.fstat(f.fileno())
        if not stat.S_ISREG(st.st_mode):
            return None
        off = max(0, st.st_size - TAIL_BYTES)
        lines = os.pread(f.fileno(), st.st_size - off, off).decode("utf-8", "replace").split("\n")
    uses = {}
    for raw in lines[1:] if off else lines:
        try:
            e = json.loads(raw)
        except ValueError:
            continue
        c = (e.get("message") or {}).get("content") if isinstance(e, dict) else None
        for item in c if isinstance(c, list) else []:
            if isinstance(item, dict) and e.get("type") == "assistant" and item.get("type") == "tool_use":
                uses[item.get("id")] = (str(item.get("name") or ""), item.get("input") or {})
            elif isinstance(item, dict) and e.get("type") == "user" and item.get("type") == "tool_result":
                uses.pop(item.get("tool_use_id"), None)
    m = re.search(r"permission to use (\S+)", msg)
    name = m.group(1).strip(".,;:") if m else None
    cand = [u for u in uses.values() if name is None or u[0] == name]
    if len(cand) != 1:
        return None
    tool, inp = cand[0][0], cand[0][1] if isinstance(cand[0][1], dict) else {}
    detail = next((inp[k] for k in ("command", "file_path", "url", "path") if isinstance(inp.get(k), str)), "")
    return tool, (detail.splitlines() or [""])[0], inp

def _covered(td, sj, sid, t0, tool):
    """lead_ask_near (team-run-asks.sh) narrowed: only a permission ask of this stage covers."""
    d = os.path.join(td, "runs", str(sj.get("run")), "asks")
    try:
        names = [n for n in os.listdir(d) if ASK_RE.match(n)]
    except OSError:
        return False
    for n in names:
        try:
            a = json.loads(_read_regular(os.path.join(d, n)) or b"null")
        except ValueError:
            continue
        if not isinstance(a, dict) or a.get("kind") != "permission" or a.get("session_id") != sid \
                or str(a.get("role")) != str(sj.get("role")) or str(a.get("attempt")) != str(sj.get("attempt")):
            continue
        p = a.get("payload") if isinstance(a.get("payload"), dict) else {}
        if tool and p.get("tool_name") and p.get("tool_name") != tool:
            continue
        near = [_epoch(a.get(k)) for k in ("filed_at", "delivered_at")]
        if a.get("state") == "waiting" or any(x is not None and abs(x - t0) <= NEAR_S for x in near):
            return True
    return False

def _guard_recent(main, entry):
    """Best-effort dedup: the egress guard logged this same stop within NEAR_S seconds."""
    now = time.time()
    for e in reversed(load(main, only=entry["at"][:7] + ".jsonl")[0][-200:]):
        x = _epoch(e["at"])
        if x is not None and abs(now - x) <= NEAR_S and e["reason"] == "guard" \
                and e["machine"] == entry["machine"] and e["where"] == entry["where"]:
            return True
    return False

def _ensure_ignored(main, rel):
    """--global writes only an untracked, ignored file; adds the ignore line to info/exclude."""
    if _git(main, "ls-files", "--error-unmatch", rel)[0] == 0:
        return False
    rc = _git(main, "check-ignore", "-q", rel)[0]
    common = _git_out(main, "rev-parse", "--path-format=absolute", "--git-common-dir")
    if rc == 0 or rc != 1 or not common:
        return rc == 0
    fds = []
    try:
        st = _open_append(_pin(common, ("info",), fds, 0o755), "exclude", 0o644, fds)
        if st is None:
            return False
        body = os.pread(fds[-1], st.st_size, 0).decode("utf-8", errors="replace") if st.st_size else ""
        if ".agents/touches/" not in body.splitlines():
            os.write(fds[-1], (("\n" if body and not body.endswith("\n") else "") + ".agents/touches/\n").encode())
    except OSError:
        return False
    finally:
        list(map(os.close, fds))
    return _git(main, "check-ignore", "-q", rel)[0] == 0

def hook(glob):
    t0 = time.time()
    p = json.loads(sys.stdin.read())  # invalid → main()'s catch-all
    if not isinstance(p, dict) or p.get("notification_type") != "permission_prompt":
        return 0
    project = os.environ.get("CLAUDE_PROJECT_DIR") or p.get("cwd") or os.getcwd()
    cwd = p.get("cwd") or project
    msg, sid = str(p.get("message") or ""), str(p.get("session_id") or "")
    # Before any sleep: after the grace the prompted call may be answered and another pending.
    try:
        pend = _pending(p.get("transcript_path"), msg)
    except (OSError, ValueError):
        pend = None
    top = _git_out(project, "rev-parse", "--show-toplevel")
    if glob and (not top or os.path.exists(os.path.join(project, ".claude/hooks/touch-notify.sh"))):
        return 0
    td, reason = os.path.join(top or project, ".agents/team"), "direct"
    if os.path.isfile(os.path.join(td, "team.json")):
        sj, tl = _json(os.path.join(td, "session.json")), _json(os.path.join(td, "teamlead.json"))
        if sj and tl.get("run") and tl.get("run") == sj.get("run") and sid != tl.get("session_id"):
            # A lead-run stage: its PermissionRequest hook files the ask meanwhile.
            time.sleep(int(os.environ.get("TOUCHES_GRACE_S", "15")))
            if _covered(td, sj, sid, t0, pend[0] if pend else None):
                return 0
            reason = "channel-failed"
    main = resolve_main(None, project, redirects=not glob)
    if not main:
        return 0
    what = "%s: %s" % pend[:2] if pend else (msg or "permission prompt")
    team = _team(project, sid)
    entry = make_entry("permission", what, reason, where=default_where(main, project, cwd, sid, team))
    if pend:
        entry["input"] = make_input(pend[0], pend[2], cwd, _role(project, sid, team), sid)
    if reason == "direct" and _guard_recent(main, entry):
        return 0
    if glob and not _ensure_ignored(main, ".agents/touches/%s.jsonl" % entry["at"][:7]):
        return 0
    append(main, entry)
    return 0

def _input_file(path, cwd):
    """(input, None) from an ask file (its payload) or a hook payload; (None, why) otherwise."""
    data = _read_regular(path)
    if data is None:
        return None, "unreadable file"
    try:
        d = json.loads(data)
    except ValueError:
        return None, "not JSON"
    if not isinstance(d, dict):
        return None, "not a JSON object"
    if isinstance(d.get("payload"), dict):
        p, role = d["payload"], d.get("role")
    else:
        p, role = d, _role(cwd, d.get("session_id"))
    if not isinstance(p.get("tool_name"), str) or not p["tool_name"]:
        return None, "no tool_name"
    return make_input(p["tool_name"], p.get("tool_input"), p.get("cwd"), role, d.get("session_id")), None

def add(a):
    if not _clean(a.what):
        return _err("--what is empty", 2)
    if a.wait_s is not None and not re.fullmatch(r"\d+", a.wait_s):
        return _err("--wait-s must be a non-negative integer", 2)
    cwd = os.getcwd()
    main = resolve_main(a.main, cwd)
    if not main:
        return _err(NO_MAIN, 1)
    entry = make_entry(a.kind, a.what, a.reason, a.answer, None if a.wait_s is None else int(a.wait_s),
                       a.where or default_where(main, cwd, cwd, None))
    # A decision the Supervisor relayed (team-lead.sh decision relay): who relayed it, after wait_s.
    if a.relayed_by is not None:
        entry["relayed_by"] = _clean(a.relayed_by, 60)
    if a.relayed_session is not None:
        entry["relayed_session"] = _ident(a.relayed_session)
    if a.input_file is not None:
        inp, why = _input_file(a.input_file, cwd)
        if inp is not None:
            entry["input"] = inp
        else:
            print("warn: input not recorded (%s)" % why, file=sys.stderr)
    if append(main, entry):
        return _err("touch not written — unsafe or unwritable %s/.agents/touches" % main, 1)
    return 0

def block(argv):
    """`block --source <hook> --what <text> [--main DIR]`: one kind-block line; always silent, 0."""
    opts, i = {}, 0
    while i + 1 < len(argv) and argv[i] in ("--source", "--what", "--main"):
        opts[argv[i]] = argv[i + 1]
        i += 2
    src, what = _clean(opts.get("--source", ""), 60), _clean(opts.get("--what", ""))
    # TOUCHES_BLOCK_OFF: test fixtures point main_root at the real checkout — never log there.
    if i != len(argv) or not src or not what or os.environ.get("TOUCHES_BLOCK_OFF"):
        return 0
    project = os.environ.get("CLAUDE_PROJECT_DIR") or os.getcwd()
    main = resolve_main(opts.get("--main"), project)
    if main:
        where = default_where(main, project, os.getcwd(), None)
        append(main, make_entry("block", "%s: %s" % (src, what), "hook", where=where))
    return 0

def _parser():
    ap = argparse.ArgumentParser(prog="touches.sh")
    sub = ap.add_subparsers(dest="cmd", required=True)
    ad, rp = sub.add_parser("add"), sub.add_parser("report")
    for f, choices in (("--kind", HUMAN_KINDS), ("--reason", HUMAN_REASONS), ("--what", None)):
        ad.add_argument(f, required=True, choices=choices)
    for f in ("--answer", "--wait-s", "--where", "--main", "--relayed-by", "--relayed-session", "--input-file"):
        ad.add_argument(f, default="" if f == "--answer" else None)
    for f in ("--since", "--who", "--team", "--ticket", "--run", "--main"):
        rp.add_argument(f)
    rp.add_argument("--reason", choices=REASONS)
    rp.add_argument("--brief", action="store_true")
    return ap

def main(argv):
    if argv[:1] == ["block"]:
        try:
            return block(argv[1:])
        except Exception:  # a refusing hook calls this fire-and-forget: never fail, never print
            return 0
    if argv[:1] == ["hook"]:
        try:
            return hook("--global" in argv[1:])
        except Exception:  # the hook never fails or disturbs its session
            return 0
    try:
        a = _parser().parse_args(argv)
    except SystemExit as e:
        return 0 if e.code == 0 else 2
    if a.cmd == "add":
        return add(a)
    root = resolve_main(a.main, os.getcwd())
    if not root:
        return _err(NO_MAIN, 1)
    return brief(a, root) if a.brief else report(a, root)

if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
