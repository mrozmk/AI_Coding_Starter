"""Prompt replay harness: build | verify | sheet | run | worker. CLI and usage: prompt-replay.sh.

`run` verifies the corpus hashes, then replays it through each implementation root in its own
worker process (guard_team_egress, team_prompt_check and team_prompt_authority imported from that
root, never re-implemented) and prints the outcome counts; with two roots it lists every entry
whose raw decision (guard reason, tier, class, cause) or mapped outcome differs. Exit: 0 ok ·
1 runtime · 2 usage · 3 refused (hash or coverage). Stdlib only. Contract: the #321 spec.
#322: a root whose guard has the effect API (bash_effect / webfetch_effect) is replayed by effect
— a deny kind is the deny outcome — with an offline resolver stub (every lexically public name
resolves to a public address: no live DNS) and an isolated worker environment; the report adds
the effect view (the candidate's own decision, independent of the historical prompt bit) per
implementation and the pass → non-pass lists the acceptance counts come from."""
import argparse
import csv
import gzip
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
sys.dont_write_bytecode = True

HERE = os.path.dirname(os.path.abspath(__file__))
OUTCOMES = ("pass", "lead", "supervisor-clearable", "operator", "deny")
COLUMNS = OUTCOMES + ("not-replayable",)
SEVERITY = {o: i for i, o in enumerate(OUTCOMES)}
EFFECT_COLUMNS = ("pass", "lead", "native-prompt", "operator", "deny", "not-replayable")
EFFECT_SEVERITY = {o: i for i, o in enumerate(EFFECT_COLUMNS[:-1])}
STUB_ADDRESS = "93.184.216.34"
GIT_PUSH = re.compile(r"(?:^|[\s;&|(])git\b[^;&|\n]*\bpush\b")
CTX_ROLE = {"supervisor": "Supervisor", "teamlead": "TeamLead", "advisor": "Advisor"}
# guard-corpus.txt's documented policy: a main checkout with no local gh rules and the inline
# Python opt-ins (its header, lines 1-4).
CORPUS_POLICY = {"permissions": {"allow": ["Bash(python3 -)", "Bash(python3 -c *)"]}}
# The SQL guard inside the tier reads .sql files and the .sh scripts a command runs
# (guard_destructive_sql.py): the fixture has none of them.
FILE_DEP = re.compile(r"\bsqlcmd\b|\S\.(?:sql|sh)\b", re.I)
CHANGES_CAP = 200


def boundary(prefix):
    """A checkout path where a path component ends — shared with the builder's foreign()."""
    return re.compile(re.escape(prefix.rstrip("/")) + r"(?=/|$|[\s'\";:)|&])")


def _git(cwd, *args):
    subprocess.run(["git", "-c", "user.name=replay", "-c", "user.email=replay@localhost", "-c",
                    "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null", "-c", "init.defaultBranch=main"]
                   + list(args), cwd=cwd, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def _write(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(data if isinstance(data, str) else json.dumps(data) + "\n")


class Evaluator:
    """Today's decision of one implementation root for one replay job, in temp fixtures."""

    def __init__(self, root, policy, tmp, ctx_override=None):
        self.root, self.tmp, self.ctx_override = os.path.realpath(root), os.path.realpath(tmp), ctx_override
        for p in (os.path.join(self.root, ".claude", "lib"), os.path.join(self.root, ".claude", "hooks", "lib")):
            sys.path.insert(0, p)
        import guard_team_egress
        import team_prompt_authority
        import team_prompt_check
        for m in (guard_team_egress, team_prompt_authority, team_prompt_check):
            if not os.path.realpath(m.__file__).startswith(self.root + os.sep):
                raise ImportError("%s not from %s" % (m.__name__, self.root))
        # The retry key is delivery state that opens files the input names; not part of a decision.
        team_prompt_authority.retry_key = lambda *a, **k: None
        self.g, self.a, self.c = guard_team_egress, team_prompt_authority, team_prompt_check
        self.effect_api = hasattr(guard_team_egress, "bash_effect")
        # #322: the classifier's resolver is an offline stub — no verdict depends on live DNS.
        cl = sys.modules.get("guard_team_egress_classify")
        if cl is not None and os.path.realpath(cl.__file__).startswith(self.root + os.sep):
            import socket
            cl.RESOLVER = lambda host, port, *a, **k: [
                (socket.AF_INET, socket.SOCK_STREAM, 6, "", (STUB_ADDRESS, port))]
        self.fx = self.fixtures(policy)

    def fixtures(self, policy):
        t, root = self.tmp, self.root
        settings = os.path.join(root, ".claude", "settings.json")
        fx = {k: os.path.join(t, k) for k in ("sup", "supc", "role", "main", "clone", "scratch", "jobs")}
        origin = os.path.join(t, "origin.git")
        _git(t, "init", "-q", "--bare", origin)
        for k, pol in (("sup", policy), ("supc", CORPUS_POLICY), ("role", None)):
            os.makedirs(os.path.join(fx[k], ".claude"))
            shutil.copyfile(settings, os.path.join(fx[k], ".claude", "settings.json"))
            if pol is not None:
                _write(os.path.join(fx[k], ".claude", "settings.local.json"), pol)
            # #322: a repository with an origin, so a non-stage push resolves its destination.
            _git(fx[k], "init", "-q")
            _git(fx[k], "remote", "add", "origin", origin)
        os.makedirs(fx["scratch"])
        os.makedirs(fx["jobs"])
        # The stage: a distinct main + clone pair with a runner anchor (team-smoke-12.sh fixture).
        main, clone = fx["main"], fx["clone"]
        os.makedirs(os.path.join(main, ".claude"))
        shutil.copyfile(settings, os.path.join(main, ".claude", "settings.json"))
        prof = os.path.join(root, ".claude", "project-profile.json")
        if os.path.isfile(prof):
            shutil.copyfile(prof, os.path.join(main, ".claude", "project-profile.json"))
        _write(os.path.join(main, "CLAUDE.md"), "### Branch model\n\n**Integration:** `main`\n**Protected:** `main`\n")
        _write(os.path.join(main, ".gitignore"), ".agents/team/\n")
        _git(main, "init", "-q")
        _git(main, "add", "-A")
        _git(main, "commit", "-q", "-m", "fixture")
        _git(main, "remote", "add", "origin", origin)
        _git(main, "push", "-q", "origin", "HEAD:refs/heads/main")
        _git(main, "fetch", "-q", "origin")
        _git(t, "clone", "-q", origin, clone)
        _git(clone, "checkout", "-q", "-b", "feat/replay")
        base = subprocess.run(["git", "-C", clone, "rev-parse", "HEAD"], stdout=subprocess.PIPE, text=True).stdout.strip()
        td, run = os.path.join(clone, ".agents", "team"), "replay-20260101-000000"
        _write(os.path.join(td, "team.json"), {"team": "replay", "ticket": "R-1", "branch": "feat/replay",
                                               "line": "main", "base_sha": base, "mode": "brainstorm"})
        _write(os.path.join(td, "run"), run + "\n")
        _write(os.path.join(td, "session.json"), {"team": "replay", "role": "coder", "run": run, "attempt": 1,
                                                  "ticket": "R-1", "session_id": "S-REPLAY"})
        _write(os.path.join(td, "teamlead.json"), {"run": run, "session_id": "S-LEAD", "main_root": main})
        subprocess.run(["bash", "-c", '. "$1/.claude/lib/team-anchor.sh" && team_anchor_launch "$2" replay "$3" "$4" coder 1 S-REPLAY',
                        "_", root, main, clone, run], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        return fx

    def _env(self, ctx, project):
        for k in ("TEAM_RUN_TEAM", "TEAM_SESSION_ROLE", "TEAM_RUN_ROLE", "HARNESS_MAIN"):
            os.environ.pop(k, None)
        os.environ["CLAUDE_PROJECT_DIR"] = project
        if ctx == "stage":
            os.environ["TEAM_RUN_TEAM"] = "replay"
        elif ctx in CTX_ROLE:
            os.environ["TEAM_SESSION_ROLE"] = CTX_ROLE[ctx]

    def project_of(self, ctx, fixture=None):
        return {"stage": self.fx["clone"], "supervisor": self.fx["supc" if fixture == "guard-corpus" else "sup"]}.get(ctx, self.fx["role"])

    def guard(self, ctx, tool, ti, fixture=None):
        return self.effect(ctx, tool, ti, fixture)[1]

    def effect(self, ctx, tool, ti, fixture=None, cwd=None):
        """(kind, reason): the effect API when the root has it, else today's reason as pass|ask."""
        project = self.project_of(ctx, fixture)
        self._env(ctx, project)
        try:
            if tool == "Bash":
                cmd = ti.get("command")
                if not isinstance(cmd, str):
                    return "ask", "unreadable Bash command"
                if self.effect_api:
                    return self.g.bash_effect(cmd, project, cwd)
                r = self.g.bash_reason(cmd, project)
            elif tool == "WebFetch":
                if self.effect_api:
                    return self.g.webfetch_effect(ti.get("url"), project)
                r = self.g.webfetch_reason(ti.get("url"), project)
            else:
                return "pass", ""
        except Exception as e:  # noqa: BLE001 — the wrapper turns a crash into its fail-closed ask
            return "ask", "guard-error:%s" % e.__class__.__name__
        return ("ask" if r else "pass"), r

    def tier(self, tool, ti, cwd):
        """(tier, class, cause, rest): rest is tier_full's tier without the egress cause (#322), or
        None for a root without tier_full."""
        self._env("stage", self.fx["clone"])
        f = os.path.join(self.fx["jobs"], "job.json")
        _write(f, {"tool_name": tool, "tool_input": ti, "cwd": cwd})
        try:
            line = self.a.input_tier(self.c, self.fx["clone"], self.fx["main"], [], f)
            rest = self.tier_rest(tool, ti, cwd) if hasattr(self.a, "tier_full") else None
        except Exception as e:  # noqa: BLE001
            return "error", None, e.__class__.__name__, None
        if not line:
            return "error", None, None, None
        first = line.split("\n", 1)[0]
        m = re.match(r"^tier: (class|lead|operator)(?: — (.*)| (.*))?$", first)
        if not m:
            return "error", None, self.norm(first), None
        return m.group(1), m.group(3) if m.group(1) == "class" else None, self.norm(m.group(2)), rest

    def tier_rest(self, tool, ti, cwd):
        inp = dict(ti)
        target = inp.get("file_path") or inp.get("notebook_path")
        if isinstance(target, str) and target:
            inp["file_path"] = os.path.join(cwd, os.path.expanduser(target))
        cmd = inp.get("command") if isinstance(inp.get("command"), str) else ""
        text = str(inp.get("file_path") or inp.get("url") or cmd.split("\n", 1)[0])
        r = self.a.tier_full(self.c, self.fx["clone"], self.fx["main"], [], tool, self.a.HEADERS.get(tool),
                             [cmd] if tool == "Bash" else [], inp, text, cwd)
        return list(r[3]) if r[3] else None

    def policy_match(self, project, cmd):
        """deny | ask | None: the strongest rule of the fixture's policy a Bash command meets."""
        try:
            found = self.c.matches(cmd, self.c.rules(project, []), True)
        except Exception:  # noqa: BLE001 — an unreadable policy counts as an ask
            return "ask"
        kinds = {f[0] for f in found}
        return "deny" if "deny" in kinds else "ask" if "ask" in kinds else None

    def norm(self, s):
        if not s:
            return s
        for k, tag in (("clone", "<clone>"), ("main", "<main>"), ("scratch", "<scratch>")):
            s = s.replace(self.fx[k], tag)
        return s.replace(self.tmp, "<tmp>")

    def remap(self, job):
        """(tool_input, cwd) inside the stage fixture, or None when the relation cannot be mapped."""
        base = {"main": self.fx["main"], "clone": self.fx["clone"], "scratch": self.fx["scratch"]}
        cls = job.get("cwd_class")
        if cls not in base:
            return None
        cwd = os.path.normpath(os.path.join(base[cls], job.get("cwd_rel") or "."))
        pats = [(boundary(p), base[c])
                for p, c in sorted(job.get("paths") or [], key=lambda pc: -len(pc[0])) if p and c in base]

        def sub(v):
            if isinstance(v, str):
                for pat, to in pats:
                    v = pat.sub(lambda m: to, v)
                return v
            if isinstance(v, dict):
                return {k: sub(x) for k, x in v.items()}
            return [sub(x) for x in v] if isinstance(v, list) else v
        return sub(job.get("input") or {}), cwd

    def remap_role(self, job, ti):
        """(tool_input, cwd, limit) of a non-stage job inside its fixture project (#322): every path
        the job's `paths` map names becomes the fixture dir; a git push whose repository or
        destination the fixture cannot represent gets the limit `origin not representable`."""
        project = self.project_of(job.get("ctx_eval"), job.get("fixture"))
        cmd = ti.get("command") if isinstance(ti.get("command"), str) else None
        if cmd is None:
            return ti, project, None
        for p, _ in sorted(job.get("paths") or [], key=lambda pc: -len(pc[0] or "")):
            if p:
                cmd = boundary(p).sub(lambda m: project, cmd)
        limit = None
        if GIT_PUSH.search(cmd):
            try:
                words = cmd.split()
            except ValueError:
                words = []
            after = words[words.index("push") + 1:] if "push" in words else []
            dest = next((w for w in after if not w.startswith("-")), "origin")
            dest = dest.rstrip(";&|)")
            # Another repository (`git -C <dir>`, a `cd` first) or a destination other than origin:
            # the fixture holds one repository and its origin, nothing else.
            other = re.search(r"\bgit\s+-C\s", cmd) or re.search(r"(?:^|[;&|(\n])\s*(?:cd|pushd)\s", cmd)
            if dest != "origin" or other:
                limit = "origin not representable"
        return dict(ti, command=cmd), project, limit

    def evaluate(self, job):
        ctx = job.get("ctx") or "unknown"
        if ctx == "unknown":
            ctx = self.ctx_override or "advisor"
        tool, ti, prompted = job.get("tool"), job.get("input") or {}, bool(job.get("prompted"))
        out = {"key": job.get("key"), "ctx": ctx, "guard": "", "tier": None, "class": None, "cause": None,
               "modeled": bool(job.get("modeled")), "modeled_why": job.get("modeled_why"), "effect": None,
               "effect_outcome": None, "limit": None}
        cwd = None
        if not out["modeled"] and ctx == "stage":
            m = self.remap(job)
            if m is None:
                out.update(modeled=True, modeled_why="cwd not mappable into the fixture")
            elif tool == "Bash" and FILE_DEP.search(str(m[0].get("command") or "")):
                out.update(modeled=True, modeled_why="file content unavailable")
            else:
                ti, cwd = m
        elif not out["modeled"] and ctx != "solo" and tool == "Bash" and self.effect_api:
            ti, cwd, out["limit"] = self.remap_role(dict(job, ctx_eval=ctx), ti)
        if out["modeled"]:
            out.update(outcome=None, decision=None)
            return out
        kind, rest = "pass", None
        if ctx != "solo" and tool in ("Bash", "WebFetch"):
            kind, out["guard"] = self.effect(ctx, tool, ti, job.get("fixture"), cwd)
        out["effect"] = kind
        guard_caused = bool(job.get("guard_caused"))
        if ctx == "stage":
            out["tier"], out["class"], out["cause"], rest = self.tier(tool, ti, cwd)
            esc = bool(out["guard"]) or prompted
            mapped = "operator" if out["tier"] in ("operator", "error") else "lead"
            out["outcome"] = "deny" if kind == "deny" else (mapped if esc else "pass")
            if kind == "deny":
                eo = "deny"
            elif kind != "pass" or (prompted and not guard_caused):
                eo = mapped
            elif prompted and rest and (rest[0] != "lead" or rest[1]):
                # The egress prompt is gone; an independent trigger the candidate still meets.
                eo = "operator" if rest[0] == "operator" else "lead"
            else:
                eo = "pass"
            out["effect_outcome"] = eo
        elif ctx == "solo":
            out["outcome"] = "operator" if prompted else "pass"
            out["effect_outcome"] = "native-prompt" if prompted else "pass"
        else:
            out["outcome"] = "deny" if kind == "deny" else ("operator" if out["guard"] or prompted else "pass")
            if kind == "deny":
                eo = "deny"
            elif kind != "pass":
                eo = "operator"
            elif prompted and not guard_caused:
                eo = "native-prompt"
            else:
                eo = "pass"
                pol = self.policy_match(self.project_of(ctx, job.get("fixture")), ti.get("command")) \
                    if prompted and tool == "Bash" and isinstance(ti.get("command"), str) else None
                if pol:
                    eo = "deny" if pol == "deny" else "native-prompt"
                    out["effect_cause"] = "policy %s rule" % pol
            out["effect_outcome"] = eo
        out["guard"] = self.norm(out["guard"])
        out["decision"] = [out["guard"] or "", out["tier"], out["class"], out["cause"]]
        return out


# ---- verify ------------------------------------------------------------------------------------
def _build():
    """The builder module of this checkout — parent process only: a worker evaluates another root
    and must never import this checkout's touches through it."""
    if HERE not in sys.path:
        sys.path.insert(0, HERE)
    import prompt_replay_build
    return prompt_replay_build


def verify(corpus, require_complete=False):
    """(None, manifest) when the corpus checks out, else (refusal line, None)."""
    b = _build()
    try:
        with open(os.path.join(corpus, "manifest.json"), encoding="utf-8") as fh:
            m = json.load(fh)
    except (OSError, ValueError):
        return "refused: manifest.json unreadable", None
    for name in b.CORPUS_FILES:
        want = (m.get("files") or {}).get(name)
        p = os.path.join(corpus, name)
        if not want:
            return "refused: %s has no hash in manifest.json" % name, None
        if not os.path.isfile(p) or b.file_sha(p) != want:
            return "refused: %s hash differs" % name, None
    if require_complete:
        why = b.completeness(m)
        if why:
            return "refused: corpus incomplete — " + "; ".join(why[:5]), None
    return None, m


# ---- run ---------------------------------------------------------------------------------------
def load(corpus):
    with open(os.path.join(corpus, "touched.jsonl"), encoding="utf-8") as fh:
        touched = [json.loads(l) for l in fh if l.strip()]
    with gzip.open(os.path.join(corpus, "replay.jsonl.gz"), "rt", encoding="utf-8") as fh:
        replay = [json.loads(l) for l in fh if l.strip()]
    return touched, replay


def guard_caused(r):
    """True when this record shows the historical prompt was the guard's own (#322): a touch row
    with reason guard, an ask filed on an egress cause, a guard-corpus row."""
    ev = r.get("evidence") or {}
    return (r.get("source") == "guard-corpus" or (r.get("source") == "touch" and ev.get("reason") == "guard")
            or (r.get("source") == "ask" and str(ev.get("tier_cause") or "").startswith("egress:")))


def jobs_of(touched, replay, layer):
    """(jobs, touched interventions {iid: {rep, members}}, replay occurrence index)."""
    jobs, inter, b = [], {}, _build()
    for r in touched:
        inter.setdefault(r["intervention"], []).append(r)
    reps = {}
    if layer in ("touched", "all"):
        for iid, ms in sorted(inter.items()):
            ms = b.members_sorted(ms)
            rep = b.representative(ms)
            reps[iid] = (rep, ms)
            if rep:
                jobs.append(dict(key=iid, tool=rep["tool"], input=(rep.get("input") or {}).get("tool_input") or {},
                                 ctx=rep["ctx"], prompted=rep.get("prompted", False), modeled=rep.get("modeled", False),
                                 modeled_why=rep.get("modeled_why"), fixture=rep.get("fixture"),
                                 guard_caused=any(guard_caused(r) for r in [rep] + list(ms)),
                                 **{k: rep.get(k) for k in ("cwd_class", "cwd_rel", "paths")}))
    occs = {}
    if layer in ("replay", "all"):
        for r in replay:
            for i, o in enumerate(r["occurrences"]):
                key = "%s#%d" % (r["id"], i)
                occs[key] = (r, o)
                jobs.append(dict(o, key=key, tool=r["tool"], input=r["input"]["tool_input"], prompted=False))
    return jobs, reps, occs


def run_worker(impl, policy, jobs, ctx):
    cmd = [sys.executable, "-I", os.path.abspath(__file__), "worker", "--impl", impl, "--policy", policy]
    if ctx:
        cmd += ["--ctx", ctx]
    data = "".join(json.dumps(j) + "\n" for j in jobs)
    # #322: no .curlrc or git config of the person running the report enters a verdict.
    home = tempfile.mkdtemp(prefix="replay-home-")
    env = dict(os.environ, HOME=home, XDG_CONFIG_HOME=home, CURL_HOME=home,
               GIT_CONFIG_GLOBAL="/dev/null", GIT_CONFIG_NOSYSTEM="1")
    try:
        p = subprocess.run(cmd, input=data, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=env)
    finally:
        shutil.rmtree(home, ignore_errors=True)
    if p.returncode != 0:
        raise RuntimeError("implementation %s: %s" % (impl, (p.stderr.strip().splitlines() or ["worker failed"])[-1]))
    res = {}
    for line in p.stdout.splitlines():
        r = json.loads(line)
        res[r["key"]] = r
    return res


def table(title, rows, out, columns=COLUMNS):
    out.append("### " + title)
    out.append("")
    out.append("| row | " + " | ".join(columns) + " |")
    out.append("|---" * (len(columns) + 1) + "|")
    for name in sorted(rows):
        out.append("| %s | %s |" % (name, " | ".join(str(rows[name].get(c, 0)) for c in columns)))
    out.append("")


def row_of(res, label, unknown, ctx_given):
    if res is None:
        return label
    if res.get("modeled"):
        return "modeled"
    if unknown and not ctx_given:
        return "unknown-as-advisor"
    return label


def fmt(d):
    if d is None:
        return "modeled"
    g, t, c, why = d
    s = "guard=%s" % (g or "silent")
    if t:
        s += " tier=%s%s" % (t, " " + c if c else "")
        if why:
            s += " cause=%s" % why
    return s


def bump(tbl, row, col, n=1):
    tbl.setdefault(row, {}).setdefault(col, 0)
    tbl[row][col] += n


def effect_col(res):
    return (res.get("effect_outcome") or "not-replayable") if res and not res.get("modeled") else "not-replayable"


def report_touched(touched, reps, first, labels, ctx_given, impl="A"):
    out, rows, obs, eff, b = [], {}, {}, {}, _build()
    for iid, (rep, ms) in sorted(reps.items()):
        res = first.get(iid) if rep else None
        name = row_of(res, labels.get(iid) or "unlabelled", rep is not None and rep["ctx"] == "unknown", ctx_given)
        col = (res.get("outcome") or "not-replayable") if res else "not-replayable"
        bump(rows, name, col)
        bump(obs, b.observed(ms), col)
        bump(eff, labels.get(iid) or "unlabelled", effect_col(res))
    out.append("## Layer touched — interventions (implementation %s)" % impl)
    out.append("")
    table("Outcome by label", rows, out)
    table("Observed handling × simulated outcome", obs, out)
    diff = [r["id"] for r in touched if r["source"] == "ask" and r.get("evidence", {}).get("tier")
            and r["intervention"] in first and reps[r["intervention"]][0] is r
            and first[r["intervention"]].get("tier") not in (None, r["evidence"]["tier"])]
    out.append("recorded vs simulated tier: %d differ%s" % (len(diff), (" — " + " ".join(diff[:50])) if diff else ""))
    gc = [(iid, rep) for iid, (rep, _) in reps.items() if rep and rep["source"] == "guard-corpus"]
    bad = []
    for iid, rep in sorted(gc):
        res = first.get(iid) or {}
        want = rep["evidence"].get("expected")
        # Any reason reduces to ask (the frozen rows); a live deny row expects the effect deny.
        got = "deny" if want == "deny" and res.get("effect") == "deny" else "ask" if res.get("guard") else "none"
        if res.get("modeled") or got != want:
            bad.append("- %s expected %s got %s: %s" % (rep["ref"], want, got,
                                                        rep["input"]["tool_input"].get("command", "")[:160]))
    if gc:
        out.append("guard-corpus expectations: " + ("all match" if not bad else "%d mismatch" % len(bad)))
        out += bad
    out.append("")
    if eff:
        table("Effect view — label × candidate outcome", eff, out, EFFECT_COLUMNS)
    return out


def report_replay(occs, first, ctx_given, impl="A"):
    out, uniq, weighted, per, eff = [], {}, {}, {}, {}
    for key, (r, o) in occs.items():
        per.setdefault(r["id"], []).append((o, first.get(key)))
    for rid, lst in sorted(per.items()):
        for o, res in lst:
            bump(weighted, row_of(res, "unlabelled", o["ctx"] == "unknown", ctx_given),
                 (res or {}).get("outcome") or "not-replayable", o["count"])
        live = [(o, res) for o, res in lst if res and not res.get("modeled")]
        if not live:
            name, col, ecol = "modeled", "not-replayable", "not-replayable"
        else:
            col = max((res["outcome"] for _, res in live), key=lambda x: SEVERITY[x])
            name = "unknown-as-advisor" if all(o["ctx"] == "unknown" for o, _ in live) and not ctx_given else "unlabelled"
            ecol = max((effect_col(res) for _, res in live), key=lambda x: EFFECT_SEVERITY.get(x, -1))
        bump(uniq, name, col)
        bump(eff, "calls", ecol)
    out.append("## Layer replay (implementation %s)" % impl)
    out.append("")
    table("Unique calls (most severe occurrence)", uniq, out)
    table("Occurrence-weighted", weighted, out)
    if eff:
        table("Effect view — unique calls × candidate outcome", eff, out, EFFECT_COLUMNS)
    return out


def report_changes(results, changes_out):
    dec, oc, pn, pd, lim = [], [], {"touched": [], "replay": []}, {"touched": [], "replay": []}, []
    for key in sorted(set(results[0]) | set(results[1])):
        x, y = results[0].get(key) or {}, results[1].get(key) or {}
        if x.get("decision") != y.get("decision"):
            dec.append("%s %s %s → %s" % (key, x.get("ctx") or y.get("ctx"), fmt(x.get("decision")), fmt(y.get("decision"))))
        if x.get("outcome") != y.get("outcome"):
            oc.append("%s %s %s → %s" % (key, x.get("ctx") or y.get("ctx"), x.get("outcome") or "modeled", y.get("outcome") or "modeled"))
        layer = "replay" if "#" in key else "touched"
        if y.get("limit"):
            lim.append("%s %s" % (key, y["limit"]))
            continue
        xa, yb = x.get("effect_outcome") or x.get("outcome"), y.get("effect_outcome")
        if xa == "pass" and yb in ("lead", "operator", "native-prompt"):
            pn[layer].append("%s %s pass → %s (%s)" % (key, y.get("ctx"), yb, y.get("guard") or y.get("cause") or y.get("effect_cause") or ""))
        elif xa == "pass" and yb == "deny":
            pd[layer].append("%s %s pass → deny (%s)" % (key, y.get("ctx"), y.get("guard") or ""))
    if changes_out:
        with open(changes_out, "w", encoding="utf-8") as fh:
            fh.write("Decision changes: %d\n%sOutcome changes: %d\n%s" % (
                len(dec), "".join(l + "\n" for l in dec), len(oc), "".join(l + "\n" for l in oc)))
    out = (["## A → B", "", "Decision changes: %d" % len(dec)] + dec[:CHANGES_CAP]
           + ["Outcome changes: %d" % len(oc)] + oc[:CHANGES_CAP])
    if any(r.get("effect_outcome") is not None for r in results[1].values()):
        for layer in ("touched", "replay"):
            out += ["Pass → non-pass (effect, %s): %d" % (layer, len(pn[layer]))] + pn[layer]
            out += ["Pass → deny (%s): %d" % (layer, len(pd[layer]))] + pd[layer]
        out += ["Replay limits: origin not representable: %d" % len(lim)] + lim
    return out


def report(a, m, touched, reps, occs, results, labels):
    b = _build()
    out = ["# Prompt replay report", "",
           "Corpus: manifest.json sha256 %s" % b.file_sha(os.path.join(a.corpus, "manifest.json")),
           "Corpus files: " + ", ".join("%s %s" % (k, v[:12]) for k, v in sorted(m["files"].items()))]
    out += ["Implementation %s: %s @ %s" % ("AB"[i], r, b.rev(r) or "?") for i, r in enumerate(a.impl)]
    out.append("")
    # #322: every implementation's tables, under its own revision.
    for i, res in enumerate(results):
        if i:
            out += ["## Implementation %s (%s)" % ("AB"[i], b.rev(a.impl[i]) or "?"), ""]
        if a.layer in ("touched", "all"):
            out += report_touched(touched, reps, res, labels, a.ctx, "AB"[i])
        if a.layer in ("replay", "all"):
            out += report_replay(occs, res, a.ctx, "AB"[i])
    if len(results) == 2:
        out += report_changes(results, a.changes_out)
    print("\n".join(out))


def read_labels(path, touched):
    known = {r["intervention"] for r in touched}
    labels = {}
    with open(path, encoding="utf-8", newline="") as fh:
        for row in csv.DictReader(fh):
            iid, lab = (row.get("intervention") or "").strip(), (row.get("label") or "").strip()
            if iid not in known:
                raise ValueError("unknown intervention %s" % iid)
            if iid in labels:
                raise ValueError("duplicated intervention %s" % iid)
            labels[iid] = lab or "unlabelled"
    return labels


def cmd_run(a):
    why, m = verify(a.corpus)
    if why:
        print(why, file=sys.stderr)
        return 3
    touched, replay = load(a.corpus)
    labels = {}
    if a.labels:
        try:
            labels = read_labels(a.labels, touched)
        except (OSError, ValueError) as e:
            print("error: --labels: %s" % e, file=sys.stderr)
            return 2
    jobs, reps, occs = jobs_of(touched, replay, a.layer)
    try:
        results = [run_worker(r, os.path.join(a.corpus, "policy.json"), jobs, a.ctx) for r in a.impl]
    except RuntimeError as e:
        print("error: %s" % e, file=sys.stderr)
        return 1
    report(a, m, touched, reps, occs, results, labels)
    return 0


def cmd_worker(a):
    tmp = tempfile.mkdtemp(prefix="replay-worker-")
    try:
        try:
            with open(a.policy, encoding="utf-8") as fh:
                ev = Evaluator(a.impl, json.load(fh), tmp, a.ctx)
        except Exception as e:  # noqa: BLE001
            print("error: cannot load %s: %s: %s" % (a.impl, e.__class__.__name__, e), file=sys.stderr)
            return 1
        for line in sys.stdin:
            if line.strip():
                r = ev.evaluate(json.loads(line))
                sys.stdout.write(json.dumps(r, sort_keys=True) + "\n")
        return 0
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def parser():
    ap = argparse.ArgumentParser(prog="prompt-replay.sh")
    sub = ap.add_subparsers(dest="cmd", required=True)
    b = sub.add_parser("build")
    b.add_argument("--sources", required=True)
    b.add_argument("--out", required=True)
    v = sub.add_parser("verify")
    v.add_argument("--corpus", required=True)
    v.add_argument("--require-complete", action="store_true")
    s = sub.add_parser("sheet")
    s.add_argument("--corpus", required=True)
    r = sub.add_parser("run")
    r.add_argument("--corpus", required=True)
    r.add_argument("--impl", action="append", required=True)
    r.add_argument("--labels")
    r.add_argument("--layer", choices=("touched", "replay", "all"), default="all")
    r.add_argument("--ctx", choices=("stage", "teamlead", "supervisor", "advisor", "solo"))
    r.add_argument("--changes-out")
    w = sub.add_parser("worker")
    w.add_argument("--impl", required=True)
    w.add_argument("--policy", required=True)
    w.add_argument("--ctx")
    return ap


def main(argv):
    try:
        a = parser().parse_args(argv)
    except SystemExit as e:
        return 0 if e.code == 0 else 2
    if a.cmd == "worker":
        return cmd_worker(a)
    if a.cmd == "run":
        if len(a.impl) > 2:
            print("error: at most two --impl roots", file=sys.stderr)
            return 2
        return cmd_run(a)
    if a.cmd == "verify":
        why, _ = verify(a.corpus, a.require_complete)
        print(why or "verified: %s" % a.corpus, file=sys.stderr if why else sys.stdout)
        return 3 if why else 0
    if a.cmd == "sheet":
        touched, _ = load(a.corpus)
        _build().write_sheet(a.corpus, touched)
        return 0
    # build
    if os.path.isdir(a.out) and os.listdir(a.out):
        print("error: --out %s exists and is not empty" % a.out, file=sys.stderr)
        return 2
    try:
        return _build().build(a.sources, a.out)
    except (OSError, ValueError, KeyError) as e:
        print("error: build: %s: %s" % (e.__class__.__name__, e), file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
