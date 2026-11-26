"""Corpus builder of prompt-replay.sh (`build`): reads the sources a sources.json names, read-only
and each file once up to its size at open, masks every input through touches.py before anything is
written, links the records of one human intervention, joins touch rows to their transcript call,
and writes the two frozen layers (touched.jsonl, replay.jsonl.gz), policy.json, the labelling
sheet and manifest.json (sha256 + per-root coverage). Stdlib only; files are found by walking,
never passed on a command line. Contract: the #321 spec, .agents/reference/operator-touches.md."""
import bisect
import csv
import gzip
import hashlib
import json
import os
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import time
sys.dont_write_bytecode = True

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import touches  # noqa: E402

STAGE_ROLES = ("planner", "coder", "qa", "wrapup", "cli")
# The replayed tools and the tool_input field the guard reads for each.
REPLAY_FIELD = {"Bash": "command", "WebFetch": "url"}
REQUIRED = ("transcripts", "asks", "decisions", "touch-logs", "guard-corpus", "policy")
# Hashed in manifest.json; the labelling sheet too — the Advisors label from it (`sheet` rewrites
# the same bytes from touched.jsonl).
CORPUS_FILES = ("touched.jsonl", "replay.jsonl.gz", "policy.json", "labelling-sheet.csv")
TMP_ROOTS = ("/private/var/folders/", "/var/folders/", "/private/tmp/", "/tmp/")
POLICY_PREFIXES = ("Bash(gh", "Bash(python3", "WebFetch(domain:")
SHEET = ("intervention", "ids", "source", "project", "ctx", "tool", "exact", "observed", "evidence",
         "input", "label", "note")
DEC_NAME = re.compile(r"^d-\d+\.md$")
SIDE = re.compile(r"^(a-\d+)\.answer(\.rejected-[0-9-]+)?\.json$")
CHUNK = 1 << 20


def slug(path):
    """Claude Code's transcript dir name of a path (team-lib.sh team_project_slug)."""
    return re.sub(r"[^A-Za-z0-9]", "-", path)


def sha1(s, n=12):
    return hashlib.sha1(s.encode("utf-8")).hexdigest()[:n]


def utc(ts):
    m = re.match(r"^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})", ts) if isinstance(ts, str) else None
    return m.group(1) + "Z" if m else ""


def under(path, root):
    return isinstance(path, str) and bool(root) and (path == root or path.startswith(root.rstrip("/") + "/"))


CTX = dict({r: "stage" for r in STAGE_ROLES}, TeamLead="teamlead", lead="teamlead", **{"-": "teamlead"},
           Supervisor="supervisor", Advisor="advisor", solo="solo")


def ctx_of(role):
    return CTX.get(str(role or ""), "unknown")


def boundary(prefix):
    return re.compile(re.escape(prefix.rstrip("/")) + r"(?=/|$|[\s'\";:)|&])")


class Acq:
    """Acquisition boundary and coverage: one root entry per configured source path."""

    def __init__(self):
        self.roots = []

    def root(self, path, family, required=True):
        r = {"path": path, "family": family, "required": required, "present": os.path.exists(path),
             "files_discovered": 0, "files_read": 0, "bytes_read": 0, "parse_errors": 0,
             "skipped": [], "size_at_read": {}}
        self.roots.append(r)
        return r

    def _open(self, r, path):
        r["files_discovered"] += 1
        try:
            f = os.fdopen(os.open(path, touches.READ_FLAGS), "rb")
        except FileNotFoundError:
            r["skipped"].append({"path": path, "why": "vanished"})
            return None, 0
        except OSError as e:
            r["skipped"].append({"path": path, "why": "unreadable (%s)" % e.__class__.__name__})
            return None, 0
        st = os.fstat(f.fileno())
        if not stat.S_ISREG(st.st_mode):
            f.close()
            r["skipped"].append({"path": path, "why": "not a regular file"})
            return None, 0
        return f, st.st_size

    def _done(self, r, path, n):
        r["files_read"] += 1
        r["bytes_read"] += n
        r["size_at_read"][os.path.relpath(path, r["path"]) if os.path.isdir(r["path"]) else
                          os.path.basename(path)] = n

    def read(self, r, path):
        f, size = self._open(r, path)
        if f is None:
            return None
        with f:
            data = f.read(size)
        self._done(r, path, len(data))
        return data

    def lines(self, r, path):
        """(line number, bytes, terminated) up to the size at open, streamed; a grown file keeps
        those bytes. terminated is False only for a last line without its newline."""
        f, size = self._open(r, path)
        if f is None:
            return
        left, rest, no = size, b"", 0
        with f:
            while left > 0:
                buf = f.read(min(CHUNK, left))
                if not buf:
                    break
                left -= len(buf)
                parts = (rest + buf).split(b"\n")
                rest = parts.pop()
                for p in parts:
                    no += 1
                    yield no, p, True
            if rest:
                no += 1
                yield no, rest, False
        self._done(r, path, size - left)

    @staticmethod
    def bad_line(r, terminated):
        """Count a line that does not parse: a parse error, or — the unterminated last line of a
        file a writer was appending to at open — a partial tail, which costs no completeness."""
        k = "parse_errors" if terminated else "partial_tail"
        r[k] = r.get(k, 0) + 1


def walk(d, suffix):
    out = []
    for top, dirs, files in os.walk(d):
        dirs.sort()
        out += [os.path.join(top, n) for n in sorted(files) if n.endswith(suffix)]
    return out


def completeness(m):
    """Why a manifest is not complete, recomputed from its accounting (verify uses it too)."""
    why = []
    for r in m.get("roots", []):
        if not r.get("required"):
            continue
        if not r.get("present"):
            why.append("missing %s root %s" % (r["family"], r["path"]))
        elif r["family"] == "transcripts" and not r.get("files_read"):
            why.append("transcript root %s read no file" % r["path"])
        if r.get("parse_errors"):
            # A record that does not parse is a record the corpus lost (a malformed policy would
            # otherwise become an empty allowlist).
            why.append("%d parse error(s) in %s root %s" % (r["parse_errors"], r["family"], r["path"]))
        why += ["skipped %s (%s)" % (s["path"], s["why"]) for s in r.get("skipped", [])
                if s.get("why") != "vanished"]
    for fam in REQUIRED:
        if not sum(r.get("files_read", 0) for r in m.get("roots", []) if r["family"] == fam):
            why.append("family %s read nothing" % fam)
    why += ["corpus file %s not hashed" % n for n in CORPUS_FILES if n not in m.get("files", {})]
    return why


class Sources:
    def __init__(self, path):
        with open(path, encoding="utf-8") as fh:
            s = json.load(fh)
        def ex(p):
            return os.path.expanduser(p) if isinstance(p, str) else p
        self.checkouts = [dict(c, path=os.path.realpath(ex(c["path"]))) for c in s.get("checkouts", [])]
        self.former = {ex(k).rstrip("/"): os.path.realpath(ex(v)) for k, v in (s.get("former_paths") or {}).items()}
        self.transcripts = [dict(t, dir=ex(t["dir"])) for t in s.get("transcript_roots", [])]
        self.touch_logs = [dict(t, path=ex(t["path"])) for t in s.get("touch_logs", [])]
        self.teamlead_logs = [dict(t, path=ex(t["path"])) for t in s.get("teamlead_logs", [])]
        self.guard_corpus = ex(s.get("guard_corpus"))
        self.policy = ex(s.get("policy"))
        self.cutoff = s.get("cutoff")
        # Every prefix a listed checkout was seen under: (prefix, checkout).
        self.prefixes = [(c["path"], c) for c in self.checkouts]
        self.prefixes += [(old, c) for old, new in self.former.items() for c in self.checkouts if c["path"] == new]
        self.prefixes.sort(key=lambda pc: -len(pc[0]))

    def checkout_of(self, path):
        return next(((p, c) for p, c in self.prefixes if under(path, p)), (None, None))


def mapped(src, co, home):
    """[[prefix, class]] the worker maps into its fixture: the call's own checkout and the main
    checkout(s) of its project; any other listed checkout cannot be mapped."""
    if co is None:
        return [[home, "main"]] if home else []
    own = [[p, co.get("role_hint") or "main"] for p, c in src.prefixes if c is co]
    mains = [[p, "main"] for p, c in src.prefixes if c is not co and c.get("role_hint") == "main"
             and c.get("project") == co.get("project")]
    return own + mains


def place(src, cwd, co, home):
    """(cwd_class, cwd_rel, paths) of a call: its cwd relative to a mapped checkout or scratch."""
    paths = mapped(src, co, home)
    if isinstance(cwd, str) and cwd:
        for p, cls in sorted(paths, key=lambda pc: -len(pc[0])):
            if under(cwd, p):
                return (cls, os.path.relpath(cwd, p), paths)
        for t in TMP_ROOTS:
            if cwd.startswith(t):
                return ("scratch", cwd[len(t):], paths)
    return ("other", "", paths)


def foreign(src, text, paths):
    """True when text names a listed checkout the worker cannot map (another clone)."""
    known = [p for p, _ in paths]
    for p, _ in src.prefixes:
        if any(p == k or under(k, p) for k in known):
            continue
        if boundary(p).search(text):
            return True
    return False


def summary(tool, ti):
    """The Notification hook's historical what: `<tool>: <first line>`, unmasked and uncapped — the
    writer masked before its 200 cap, so a masked secret can let `what` reach past raw char 200;
    wild() reads a capped what as a prefix."""
    d = next((ti[k] for k in ("command", "file_path", "url", "path") if isinstance(ti.get(k), str)), "")
    s = "%s: %s" % (tool, (d.splitlines() or [""])[0])
    return re.sub(r" {2,}", " ", re.sub(r"[\x00-\x1f\x7f]", " ", s)).strip()


def wild(what, text):
    """what (an older writer's masked text) matches text, each *** read as a wildcard; a what cut
    at 200 (or at 60 by the line budget) matches a prefix."""
    pat = ".*?".join(re.escape(p) for p in what.split("***"))
    return bool(re.fullmatch(pat, text, re.S) or (len(what) in (60, 200) and re.match(pat, text, re.S)))


WORD_WINDOW = 10


def word_hits(what, at, window):
    """The calls a guard reason names by its word — `<tool> in command position`, `git to <host>
    (…)`, `<host> not in WebFetch allowlist` — within WORD_WINDOW s of the row: the nearest one,
    or every call tied nearest (ambiguous). Another reason shape names no call."""
    m = re.match(r"^(\S+) in command position$", what)
    g = re.match(r"^git to (\S+) \(not in the WebFetch allowlist\)$", what)
    h = re.match(r"^(\S+) not in WebFetch allowlist$", what)

    def names(c):
        text = c["ti"].get(REPLAY_FIELD[c["tool"]])
        if not isinstance(text, str):
            return False
        if m:
            return c["tool"] == "Bash" and bool(re.search(r"(?<![\w./-])%s(?![\w-])" % re.escape(m.group(1)), text))
        if g:
            return c["tool"] == "Bash" and bool(re.search(r"\bgit\b", text)) and g.group(1) in text
        return bool(h) and h.group(1) in text

    near = sorted((abs(x - at), c["ref"], c) for x, _, c in window if abs(x - at) <= WORD_WINDOW and names(c))
    return [c for d, _, c in near if d == near[0][0]] if near else []


def frontmatter(text):
    fm, body = {}, text
    m = re.match(r"^---\n(.*?)\n---\n?(.*)$", text, re.S)
    if m:
        for line in m.group(1).splitlines():
            k, _, v = line.partition(":")
            if _ and k.strip() not in fm:
                fm[k.strip()] = v.strip()
        body = m.group(2)
    q = re.search(r"^## Question\n(.*)$", body, re.M)
    return fm, (q.group(1) if q else "")


def masked_text(tool, ti):
    v = ti.get(REPLAY_FIELD[tool])
    return touches.mask_value(v) if isinstance(v, str) else None


class Builder:
    def __init__(self, src, out):
        self.src, self.out, self.acq = src, out, Acq()
        self.touched, self.calls, self.session_roles = [], [], {}
        self.counts = {"touch_block_rows": 0, "after_cutoff": 0}
        self.ev, self.policy = None, None
        self.cut = touches._epoch(utc(src.cutoff)) if src.cutoff else None

    def late(self, at):
        """True (and counted) when a record's time is after the sources' cutoff: a rebuild with the
        same cutoff admits nothing newer. A record without a readable time is kept."""
        x = touches._epoch(utc(at)) if self.cut is not None else None
        if x is not None and x > self.cut:
            self.counts["after_cutoff"] += 1
            return True
        return False

    # ---- readers ------------------------------------------------------------------------------
    def read_transcripts(self):
        for t in self.src.transcripts:
            r = self.acq.root(t["dir"], "transcripts")
            if not r["present"]:
                continue
            if t.get("checkouts", "listed") == "listed":
                names = {}
                for p, c in self.src.prefixes:
                    names.setdefault(slug(p), c)
            else:
                names = {n: None for n in sorted(os.listdir(t["dir"])) if os.path.isdir(os.path.join(t["dir"], n))}
            for name in sorted(names):
                d = os.path.join(t["dir"], name)
                if os.path.isdir(d):
                    for f in walk(d, ".jsonl"):
                        self.read_transcript(r, t, name, names[name], f)

    def read_transcript(self, r, t, name, co, f):
        project = (co or {}).get("project") or t.get("project") or name
        home, rel = None, os.path.relpath(f, t["dir"])
        for no, raw, term in self.acq.lines(r, f):
            if b'"tool_use"' not in raw:
                continue
            try:
                e = json.loads(raw)
            except ValueError:
                self.acq.bad_line(r, term)
                continue
            if not isinstance(e, dict):
                self.acq.bad_line(r, term)
                continue
            c = (e.get("message") or {}).get("content")
            if e.get("type") != "assistant" or not isinstance(c, list):
                continue
            for item in c:
                if not (isinstance(item, dict) and item.get("type") == "tool_use"
                        and item.get("name") in REPLAY_FIELD and isinstance(item.get("input"), dict)):
                    continue
                cwd = e.get("cwd") if isinstance(e.get("cwd"), str) else ""
                home = home or (cwd if co is None else None)
                if self.late(e.get("timestamp")):
                    continue
                self.calls.append({"ref": "%s:%d#%s" % (rel, no, item.get("id") or ""), "at": utc(e.get("timestamp")),
                                   "session": str(e.get("sessionId") or os.path.basename(f)[:-6]),
                                   "cwd": cwd, "tool": item["name"], "ti": item["input"], "project": project,
                                   "co": co, "home": home, "checkout": os.path.basename((co or {}).get("path") or name)})

    def read_runs(self):
        asks, decs = [], []
        for co in self.src.checkouts:
            td = os.path.join(co["path"], ".agents", "team")
            # A checkout marked `removed` is gone from disk: its transcripts and path mapping stay,
            # its run roots are recorded absent without failing completeness.
            req = not co.get("removed")
            ra, rd = self.acq.root(td, "asks", required=req), self.acq.root(td, "decisions", required=req)
            ra["sessions"] = 0
            # (run dir, its team dir, the archive entry name or None): an archived run's ticket is
            # its archive entry's prefix (team-next.sh: archive/<ticket>-<UTC>/).
            runs = []
            live, arch = os.path.join(td, "runs"), os.path.join(td, "archive")
            if os.path.isdir(live):
                runs += [(os.path.join(live, n), td, None) for n in sorted(os.listdir(live))]
            if os.path.isdir(arch):
                for a in sorted(os.listdir(arch)):
                    rr = os.path.join(arch, a, "runs")
                    if os.path.isdir(rr):
                        runs += [(os.path.join(rr, n), os.path.join(arch, a), a) for n in sorted(os.listdir(rr))]
            for rdir, tdir, archive in runs:
                if os.path.isdir(rdir):
                    self.read_run(co, rdir, tdir, archive, ra, rd, asks, decs)
        return asks, decs

    def read_run(self, co, rdir, tdir, archive, ra, rd, asks, decs):
        run = os.path.basename(rdir)
        tj = {}
        try:
            with open(os.path.join(tdir, "team.json"), encoding="utf-8") as fh:
                tj = json.load(fh)
        except (OSError, ValueError):
            pass
        team = run.split("-", 1)[0]
        ticket = str(tj.get("ticket") or (archive.split("-", 1)[0] if archive else "?"))
        dirs = [rdir] + [os.path.join(rdir, n) for n in sorted(os.listdir(rdir)) if re.match(r"^r\d+$", n)]
        for d in dirs:
            for n in sorted(os.listdir(d)):
                if n.endswith(".session") and os.path.isfile(os.path.join(d, n)):
                    data = self.acq.read(ra, os.path.join(d, n))
                    sid = (data or b"").decode("utf-8", "replace").strip()
                    stem = n[:-8].rsplit("-", 1)[0]
                    if sid:
                        self.session_roles[sid] = "TeamLead" if stem == "lead" else stem
            ad, dd = os.path.join(d, "asks"), os.path.join(d, "decisions")
            side = {}
            if os.path.isdir(ad):
                for n in sorted(os.listdir(ad)):
                    m = SIDE.match(n)
                    if m:
                        data = self.acq.read(ra, os.path.join(ad, n))
                        try:
                            side.setdefault(m.group(1), []).append((bool(m.group(2)), json.loads(data or b"null")))
                        except ValueError:
                            ra["parse_errors"] += 1
                for n in sorted(os.listdir(ad)):
                    if touches.ASK_RE.match(n):
                        data = self.acq.read(ra, os.path.join(ad, n))
                        try:
                            a = json.loads(data or b"null")
                        except ValueError:
                            ra["parse_errors"] += 1
                            continue
                        if isinstance(a, dict) and not self.late(a.get("filed_at")):
                            asks.append(self.ask_record(co, run, n[:-5], a, side.get(n[:-5], [])))
            if os.path.isdir(dd):
                for n in sorted(os.listdir(dd)):
                    if DEC_NAME.match(n):
                        data = self.acq.read(rd, os.path.join(dd, n))
                        text = data.decode("utf-8", "replace") if data is not None else None
                        fm = frontmatter(text)[0] if text is not None else {}
                        # A decision opened before the cutoff stays, even when answered after it.
                        if text is not None and not self.late(fm.get("created_at") or fm.get("answered_at")):
                            decs.append(self.dec_record(co, run, team, ticket, n[:-3], text))

    def ask_record(self, co, run, aid, a, side):
        p = a.get("payload") if isinstance(a.get("payload"), dict) else {}
        tool, ti = p.get("tool_name"), p.get("tool_input") if isinstance(p.get("tool_input"), dict) else {}
        good = [s for rej, s in side if not rej and isinstance(s, dict)]
        if good:
            observed = str(good[0].get("authority") or "unknown")
        elif a.get("state") in ("waiting", "timeout", "timed_out", "withdrawn") or side:
            observed = "unanswered"
        else:
            observed = "unknown"
        rec = self.record("ask", "%s/%s/%s" % (os.path.basename(co["path"]), run, aid), utc(a.get("filed_at")),
                          co.get("project"), a.get("role"), tool if isinstance(tool, str) else None)
        rec.update(observed=observed, prompted=True,
                   # A tier cause can quote the command it judged: masked like the input.
                   evidence={k: touches.mask_value(a[k]) if isinstance(a[k], str) else a[k]
                             for k in ("kind", "tier", "tier_cause", "state") if a.get(k) is not None},
                   _run=(co["path"], run), _aid=aid, _kind=a.get("kind"))
        if a.get("kind") == "permission" and isinstance(tool, str) and tool:
            self.set_input(rec, tool, ti, p.get("cwd"), co, None)
        else:
            rec["input"] = {"text": touches.mask_value(p.get("text") or "")} if p.get("text") else {}
        return rec

    def dec_record(self, co, run, team, ticket, did, text):
        fm, q = frontmatter(text)
        stage = fm.get("stage") or "-"
        via = fm.get("answered_via", "")
        observed = ("supervisor" if via.startswith("supervisor-delegated") else "operator") if via else \
            ("unanswered" if fm.get("status") == "pending" else "unknown")
        rec = self.record("decision", "%s/%s/%s" % (os.path.basename(co["path"]), run, did),
                          fm.get("answered_at") or fm.get("created_at") or "", co.get("project"),
                          "TeamLead" if stage in ("-", "") else stage, None)
        rec.update(observed=observed, prompted=True, input={"text": touches.mask_value(q)},
                   evidence={k: touches.mask_value(fm[k]) for k in ("touch_reason", "answer_outcome", "answer_value", "gate")
                             if fm.get(k)},
                   _run=(co["path"], run), _bind=fm.get("bind_ask"), _gate=fm.get("gate"),
                   _where="team %s / %s / %s" % (team, ticket, "TeamLead" if stage in ("-", "") else stage), _q=q)
        return rec

    def read_touch_logs(self):
        rows = []
        for t in self.src.touch_logs:
            r = self.acq.root(t["path"], "touch-logs")
            if not r["present"]:
                continue
            files = [os.path.join(t["path"], n) for n in sorted(os.listdir(t["path"])) if touches.MONTH_RE.match(n)] \
                if os.path.isdir(t["path"]) else [t["path"]]
            for f in files:
                data = self.acq.read(r, f) or b""
                lines = data.decode("utf-8", "replace").splitlines()
                for no, raw in enumerate(lines, 1):
                    e, why = touches._parse_entry(raw) if raw.strip() else (None, None)
                    if why:
                        self.acq.bad_line(r, no < len(lines) or data.endswith(b"\n"))
                    if not e:
                        continue
                    if self.late(e["at"]):
                        continue
                    if e["kind"] == "block":
                        self.counts["touch_block_rows"] += 1
                        continue
                    rows.append(self.touch_record(t, f, no, e))
        return rows

    def touch_record(self, t, f, no, e):
        project = t.get("project") or "?"
        where = e["where"]
        m = re.match(r"^team \S+ / \S+ / (\S+)$", where)
        inp = e.get("input") if isinstance(e.get("input"), dict) else None
        role = "Supervisor" if e["reason"] == "guard" else (m.group(1) if m else (inp or {}).get("role") or "")
        rec = self.record("touch", "%s:touches/%s:%d" % (project, os.path.basename(f), no), e["at"], project,
                          role, (inp or {}).get("tool"))
        if not role or (role == "solo" and not inp):
            rec["ctx"] = "unknown"
        rec.update(observed="operator", prompted=True,
                   evidence={"reason": e["reason"], "kind": e["kind"], "what": touches.mask_value(e["what"]),
                             "answer": touches.mask_value(e["answer"])},
                   # `join_project`: the transcripts' project whose sessions write this log, when the
                   # log's own label differs (DTS sessions of every checkout write the MQL5 log).
                   # `match: word`: the log's guard rows came from another project's guard and policy,
                   # which the corpus does not hold, so their reason is matched by its word, not
                   # recomputed (word_hits).
                   _row=e, _join=t.get("join_project") or project, _match=t.get("match") or "reason", join="none")
        if inp:
            ti = {k: v for k, v in (inp.get("fields") or {}).items() if isinstance(v, str)}
            rec.update(input=dict(tool_input=ti, cwd=inp.get("cwd", "")), exact=not inp.get("cut") and "keys" not in inp,
                       replayable=bool(ti), join="input")
            co_p, co = self.src.checkout_of(inp.get("cwd") or "")
            rec.update(zip(("cwd_class", "cwd_rel", "paths"), place(self.src, inp.get("cwd"), co, None)))
            if inp.get("cut"):
                # A decision on the surviving prefix is not the original call's decision.
                rec.update(modeled=True, modeled_why="input cut to the line budget")
            elif rec["ctx"] == "stage" and foreign(self.src, json.dumps(ti, ensure_ascii=False), rec["paths"]):
                rec.update(modeled=True, modeled_why="path into another checkout")
        return rec

    def read_teamlead_logs(self):
        out = []
        for t in self.src.teamlead_logs:
            r = self.acq.root(t["path"], "teamlead-log", required=False)
            if not r["present"]:
                continue
            data = self.acq.read(r, t["path"])
            for no, line in enumerate((data or b"").decode("utf-8", "replace").splitlines(), 1):
                if "Operator" in line:
                    rec = self.record("teamlead-log", "%s:teamlead-log.md:%d" % (t.get("project") or "?", no), "",
                                      t.get("project"), "TeamLead", None)
                    rec.update(input={"text": touches.mask_value(line)}, observed="unknown", prompted=True)
                    out.append(rec)
        return out

    def read_guard_corpus(self):
        out = []
        r = self.acq.root(self.src.guard_corpus or "", "guard-corpus")
        data = self.acq.read(r, self.src.guard_corpus) if r["present"] else None
        for no, line in enumerate((data or b"").decode("utf-8", "replace").splitlines(), 1):
            want, sep, cmd = line.partition("|")
            if not sep or want not in ("ask", "none"):
                continue
            rec = self.record("guard-corpus", "guard-corpus.txt:%d" % no, "", "fixture", "Supervisor", "Bash")
            rec.update(prompted=False, observed="unknown", evidence={"expected": want}, fixture="guard-corpus",
                       _orig={"command": cmd}, input={"tool_input": {"command": touches.mask_value(cmd)}, "cwd": ""},
                       exact=True, replayable=True, cwd_class="main", cwd_rel=".", paths=[])
            out.append(rec)
        return out

    def read_policy(self):
        r = self.acq.root(self.src.policy or "", "policy")
        data = self.acq.read(r, self.src.policy) if r["present"] else None
        try:
            allow = (json.loads(data or b"{}").get("permissions") or {}).get("allow") or []
        except (ValueError, AttributeError):
            r["parse_errors"] += 1
            allow = []
        keep = sorted(a for a in allow if isinstance(a, str) and a.startswith(POLICY_PREFIXES))
        return {"permissions": {"allow": keep}}

    # ---- records ------------------------------------------------------------------------------
    def record(self, source, ref, at, project, role, tool):
        return {"id": "t-" + sha1(source + "\n" + ref), "source": source, "ref": ref, "at": at or "",
                "project": project or "?", "role": str(role or ""), "ctx": ctx_of(role), "tool": tool or "",
                "input": {}, "exact": False, "replayable": False, "prompted": False, "observed": "unknown",
                "evidence": {}, "modeled": False, "label": ""}

    def set_input(self, rec, tool, ti, cwd, co, home):
        rec["_orig"] = ti
        rec["input"] = {"tool_input": touches.mask_obj(ti), "cwd": touches.mask_value(cwd) if isinstance(cwd, str) else ""}
        rec.update(exact=True, replayable=True, tool=tool)
        rec.update(zip(("cwd_class", "cwd_rel", "paths"), place(self.src, cwd, co, home)))
        if rec["ctx"] == "stage" and foreign(self.src, json.dumps(ti, ensure_ascii=False), rec["paths"]):
            rec.update(modeled=True, modeled_why="path into another checkout")

    # ---- linking and joins --------------------------------------------------------------------
    def link(self, asks, decs, rows):
        parent = {}

        def find(x):
            while parent.get(x, x) != x:
                x = parent[x]
            return x

        def union(a, b):
            parent[find(a)] = find(b)

        by_ask = {(a["_run"], a["_aid"]): a for a in asks}
        for d in decs:
            a = by_ask.get((d["_run"], d["_bind"])) if d.get("_bind") else None
            if a:
                union(d["id"], a["id"])
                d["_kind_bound"] = a.get("_kind")
        cand = {}
        for d in decs:
            kind = d.get("_kind_bound") or ("plan" if d.get("_gate") == "plan" else "decision")
            de = touches._epoch(d["at"])
            for r in rows:
                e, re_ = r["_row"], touches._epoch(r["at"])
                if e["where"] == d["_where"] and e["kind"] == kind and de is not None and re_ is not None \
                        and abs(de - re_) <= 60 and wild(e["what"], touches._clean(d["_q"])):
                    cand.setdefault(("d", d["id"]), []).append(r)
                    cand.setdefault(("r", r["id"]), []).append(d)
        linked = set()
        for d in decs:
            rs = cand.get(("d", d["id"]), [])
            if len(rs) == 1 and len(cand.get(("r", rs[0]["id"]), [])) == 1:
                union(rs[0]["id"], d["id"])
                rs[0]["join"] = "decision " + d["ref"]
                linked.add(rs[0]["id"])
        return find, linked

    def join_rows(self, rows, linked):
        idx = {}
        for c in self.calls:
            x = touches._epoch(c["at"])
            if x is not None:
                idx.setdefault(c["project"], []).append((x, c["ref"], c))
        for v in idx.values():
            v.sort(key=lambda t: (t[0], t[1]))
        for r in rows:
            if r["id"] in linked or r["join"] == "input":
                continue
            e, at = r["_row"], touches._epoch(r["at"])
            lst = idx.get(r["_join"], [])
            if at is None or e["kind"] != "permission" or e["reason"] not in ("guard", "direct", "channel-failed"):
                continue
            lo, hi = bisect.bisect_left(lst, (at - 120,)), bisect.bisect_right(lst, (at + 5, "￿"))
            if e["reason"] == "guard" and r["_match"] == "word":
                hits = word_hits(e["what"], at, lst[lo:hi])
            elif e["reason"] == "guard":
                hits = []
                for _, _, c in lst[lo:hi]:
                    reason = self.evaluator().guard("supervisor", c["tool"], c["ti"])
                    if reason[:200] == e["what"] or (len(e["what"]) == 60 and reason.startswith(e["what"])):
                        hits.append(c)
            else:
                hits = [c for _, _, c in lst[lo:hi] if wild(e["what"], summary(c["tool"], c["ti"]))]
            if len(hits) == 1:
                c = hits[0]
                r["join"] = "inferred " + c["ref"]
                if r["ctx"] == "unknown" and self.session_roles.get(c["session"]):
                    r["ctx"], r["role"] = ctx_of(self.session_roles[c["session"]]), self.session_roles[c["session"]]
                self.set_input(r, c["tool"], c["ti"], c["cwd"], c["co"], c["home"])
            else:
                r["join"] = "ambiguous" if hits else "none"

    def evaluator(self):
        if self.ev is None:
            import prompt_replay
            self.ev = prompt_replay.Evaluator(os.path.dirname(os.path.dirname(HERE)), self.policy,
                                              tempfile.mkdtemp(prefix="replay-build-"))
        return self.ev

    def masking_changes_decision(self, tool, prompted, ctx, occ, ti_orig, ti_masked):
        """True when masking changes the decision under today's implementation."""
        if json.dumps(ti_orig, sort_keys=True) == json.dumps(ti_masked, sort_keys=True):
            return False
        ev = self.evaluator()
        job = dict(occ, tool=tool, ctx=ctx, prompted=prompted)
        return ev.evaluate(dict(job, input=ti_orig))["decision"] != ev.evaluate(dict(job, input=ti_masked))["decision"]

    # ---- the two layers -----------------------------------------------------------------------
    def replay_layer(self):
        groups, origs = {}, {}
        for c in self.calls:
            text = masked_text(c["tool"], c["ti"])
            if text is None:
                continue
            key = (c["tool"], text)
            role = self.session_roles.get(c["session"], "")
            cls, rel, paths = place(self.src, c["cwd"], c["co"], c["home"])
            ctx = ctx_of(role) if role else "unknown"
            occ = (ctx, c["project"], c["checkout"], cls, rel, tuple(tuple(p) for p in paths))
            g = groups.setdefault(key, {"refs": [], "occ": {}})
            g["refs"].append(c["ref"])
            g["occ"][occ] = g["occ"].get(occ, 0) + 1
            orig = c["ti"].get(REPLAY_FIELD[c["tool"]])
            if orig != text:
                origs.setdefault((key, occ), set()).add(orig)
        out = []
        for (tool, text), g in groups.items():
            fld = REPLAY_FIELD[tool]
            rec = {"id": "r-" + sha1("transcript\n%s\n%s" % (tool, text)), "source": "transcript", "tool": tool,
                   "input": {"tool_input": {fld: text}}, "refs": sorted(g["refs"]), "occurrences": []}
            for occ, n in sorted(g["occ"].items()):
                o = dict(zip(("ctx", "project", "checkout", "cwd_class", "cwd_rel"), occ[:5]),
                         paths=[list(p) for p in occ[5]], count=n)
                if o["ctx"] == "stage" and o["cwd_class"] == "other":
                    o.update(modeled=True, modeled_why="cwd outside the session's checkout")
                elif o["ctx"] == "stage" and foreign(self.src, text, o["paths"]):
                    o.update(modeled=True, modeled_why="path into another checkout")
                for orig in sorted(origs.get(((tool, text), occ), ())):
                    if o.get("modeled"):
                        break
                    if self.masking_changes_decision(tool, False, o["ctx"], o, {fld: orig}, {fld: text}):
                        o.update(modeled=True, modeled_why="masking changed the guard verdict")
                rec["occurrences"].append(o)
            out.append(rec)
        return sorted(out, key=lambda r: r["id"])

    def build(self):
        os.makedirs(self.out, exist_ok=True)
        self.policy = self.read_policy()
        try:
            self.collect()
        finally:
            if self.ev:
                shutil.rmtree(self.ev.tmp, ignore_errors=True)
        return 0

    def collect(self):
        self.read_transcripts()
        asks, decs = self.read_runs()
        rows = self.read_touch_logs()
        tl = self.read_teamlead_logs()
        gc = self.read_guard_corpus()
        find, linked = self.link(asks, decs, rows)
        self.join_rows(rows, linked)
        recs = asks + decs + rows + tl + gc
        for r in recs:
            if r.get("replayable") and not r.get("modeled") and "_orig" in r and self.masking_changes_decision(
                    r["tool"], r.get("prompted", False), r["ctx"], r, r["_orig"], r["input"].get("tool_input", {})):
                r.update(modeled=True, modeled_why="masking changed the guard verdict")
        groups = {}
        for r in recs:
            groups.setdefault(find(r["id"]), []).append(r)
        for members in groups.values():
            first = min(members, key=lambda r: (r["at"] or "~", r["ref"]))
            iid = "i-" + sha1(first["ref"])
            for r in members:
                r["intervention"] = iid
        clean = [{k: v for k, v in r.items() if not k.startswith("_")} for r in recs]
        clean.sort(key=lambda r: r["id"])
        replay = self.replay_layer()
        self.write(clean, replay, self.policy)

    # ---- writers ------------------------------------------------------------------------------
    def write(self, recs, replay, policy):
        def p(n):
            return os.path.join(self.out, n)
        with open(p("touched.jsonl"), "w", encoding="utf-8") as fh:
            for r in recs:
                fh.write(json.dumps(r, sort_keys=True, ensure_ascii=False) + "\n")
        with open(p("replay.jsonl.gz"), "wb") as raw, gzip.GzipFile(filename="", mode="wb", fileobj=raw, mtime=0) as gz:
            for r in replay:
                gz.write((json.dumps(r, sort_keys=True, ensure_ascii=False) + "\n").encode("utf-8"))
        with open(p("policy.json"), "w", encoding="utf-8") as fh:
            json.dump(policy, fh, indent=2, sort_keys=True)
            fh.write("\n")
        write_sheet(self.out, recs)
        m = {"files": {n: file_sha(p(n)) for n in CORPUS_FILES}, "roots": self.acq.roots,
             "families": {}, "cutoff": self.src.cutoff or time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
             "built_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "builder_rev": rev(HERE),
             "counts": dict(self.counts, touched=len(recs), interventions=len({r["intervention"] for r in recs}),
                            replay_unique=len(replay), replay_calls=len(self.calls),
                            by_source={s: sum(r["source"] == s for r in recs) for s in sorted({r["source"] for r in recs})})}
        for r in self.acq.roots:
            f = m["families"].setdefault(r["family"], {"discovered": 0, "read": 0, "skipped": [], "required": r["required"]})
            f["discovered"] += r["files_discovered"]
            f["read"] += r["files_read"]
            f["skipped"] += r["skipped"]
        m["complete"] = not completeness(m)
        with open(p("manifest.json"), "w", encoding="utf-8") as fh:
            json.dump(m, fh, indent=1, sort_keys=True)
            fh.write("\n")


SOURCE_RANK = {"ask": 0, "touch": 1, "decision": 2, "guard-corpus": 3, "teamlead-log": 4}


def members_sorted(ms):
    """An intervention's members in representative order: by source rank, then id."""
    return sorted(ms, key=lambda r: (SOURCE_RANK.get(r["source"], 9), r["id"]))


def representative(ms):
    """The replayed member of a sorted intervention: the first replayable one, else None."""
    return next((m for m in ms if m.get("replayable")), None)


def observed(ms):
    """Who acted on a sorted intervention: the first member that knows, else unknown."""
    return next((m["observed"] for m in ms if m["observed"] != "unknown"), "unknown")


def write_sheet(out, recs):
    """One row per intervention; label and note empty — the Advisors fill a separate file."""
    by = {}
    for r in recs:
        by.setdefault(r["intervention"], []).append(r)
    with open(os.path.join(out, "labelling-sheet.csv"), "w", encoding="utf-8", newline="") as fh:
        w = csv.writer(fh)
        w.writerow(SHEET)
        for iid in sorted(by):
            ms = members_sorted(by[iid])
            rep = representative(ms) or ms[0]
            ti = rep["input"].get("tool_input")
            text = ti.get("command") or ti.get("url") or json.dumps(ti, ensure_ascii=False, sort_keys=True) \
                if isinstance(ti, dict) else rep["input"].get("text", "")
            w.writerow([iid, " ".join(m["id"] for m in ms), "+".join(sorted({m["source"] for m in ms})), rep["project"],
                        rep["ctx"], rep["tool"], str(rep["exact"]).lower(), observed(ms),
                        json.dumps({m["id"]: m["evidence"] for m in ms}, ensure_ascii=False, sort_keys=True), text, "", ""])


def file_sha(path):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(CHUNK), b""):
            h.update(chunk)
    return h.hexdigest()


def rev(root):
    """`git rev-parse HEAD` of root; "" when git cannot tell."""
    try:
        return subprocess.run(["git", "-C", root, "rev-parse", "HEAD"], stdout=subprocess.PIPE,
                              stderr=subprocess.DEVNULL, text=True, timeout=10).stdout.strip()
    except (OSError, subprocess.SubprocessError):
        return ""


def build(sources_path, out_dir):
    return Builder(Sources(sources_path), out_dir).build()
