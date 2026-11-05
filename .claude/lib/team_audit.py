"""Deterministic process audit of one team run: stages, contract steps, counts, flags.

Usage: python3 -I team_audit.py audit --team-dir <dir> --clone <dir> --run <id> --out <dir>
           --config <json> --roles "<space list>" [--runner-exit N] [--final ready|archived]
           [--title T] [--transcript <role>-<attempt>=<path>]...
       python3 -I team_audit.py mark-retro --out <dir> --run <id> --value <text>
`--team-dir` is a clone's .agents/team or an archive dir (same layout). Material only: the
audit never changes a verdict. Unexpected errors exit 1; callers turn them into one warning.
"""
import argparse
import copy
import datetime as dt
import fcntl
import json
import os
import re
import subprocess
import sys

DEFAULTS = {
    "typical_minutes": {"planner": 60, "coder": 180, "qa": 120, "wrapup": 45, "cli": 180},
    "flags": {"questions_min": 3, "qa_rounds_min": 2},
    # Off unless the project opts in (profile teams.audit.retro: true, passed as --retro on): a
    # retro starts a detached Claude session, a cost no project should get by default.
    "retro": {"enabled": False, "on_flag": True, "sample_every_clean": 5,
              "model": "sonnet", "effort": "medium", "max_minutes": 60},
}
QA_KEYS = ("run", "attempt", "output_rev", "Verdict", "Gate code", "Gate design",
           "Gate cross-model", "Gate final-build", "Tests", "Warnings", "Rethink signals")
RECORD = re.compile(r"^([a-z]+)-(\d+)-(\d+)\.json$")
QUESTION = re.compile(r"^q-\d+\.md$")
ITERATIONS = re.compile(r"(\d+)(?: of \d+)? iterations?")
TESTS = re.compile(r"passed=(\d+) failed=(\d+) skipped=(\d+) baseline=(\d+)")
RUN_DATE = re.compile(r"-(\d{8})-\d{6}$")


def now_utc():
    return dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def parse_utc(s):
    try:
        return dt.datetime.strptime(s, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=dt.timezone.utc)
    except (TypeError, ValueError):
        return None


def mtime_utc(path):
    return dt.datetime.fromtimestamp(os.path.getmtime(path), dt.timezone.utc)


def fmt(t):
    return t.strftime("%Y-%m-%dT%H:%M:%SZ") if t else "-"


def read_text(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            return f.read()
    except OSError:
        return None


def load_config(path):
    cfg = copy.deepcopy(DEFAULTS)
    try:
        with open(path, encoding="utf-8") as f:
            data = json.load(f)
        if not isinstance(data, dict):
            raise ValueError("not an object")
    except (OSError, ValueError) as e:
        print(f"warn: audit config {path} unreadable ({e}) — using defaults", file=sys.stderr)
        return cfg
    for section, values in cfg.items():
        if isinstance(data.get(section), dict):
            values.update(data[section])
    return cfg


def load_records(run_dir, roles):
    recs = []
    for name in sorted(os.listdir(run_dir)):
        m = RECORD.match(name)
        if not m or m.group(1) not in roles:
            continue
        try:
            with open(os.path.join(run_dir, name), encoding="utf-8") as f:
                doc = json.load(f)
        except (OSError, ValueError):
            continue
        doc["_file"] = name
        doc["_role"], doc["_attempt"], doc["_seq"] = m.group(1), int(m.group(2)), int(m.group(3))
        doc["_accepted"] = os.path.exists(os.path.join(run_dir, name + ".accepted"))
        recs.append(doc)
    return recs


def stage(run_dir, role, recs, typical):
    mine = sorted((r for r in recs if r["_role"] == role), key=lambda r: (r["_attempt"], r["_seq"]))
    accepted = [r for r in mine if r["_accepted"]]
    prompts = [os.path.join(run_dir, f) for f in os.listdir(run_dir)
               if re.match(rf"^{role}-\d+\.prompt\.md$", f)]
    start = min((mtime_utc(p) for p in prompts), default=None)
    last = accepted[-1] if accepted else (mine[-1] if mine else None)
    end = parse_utc(last.get("written_at")) if last else None
    minutes = round((end - start).total_seconds() / 60) if start and end else None
    verdicts = {}
    for r in mine:
        verdicts[r.get("verdict", "?")] = verdicts.get(r.get("verdict", "?"), 0) + 1
    status = "accepted" if accepted else "pending"
    return {"role": role, "status": status, "records": len(mine), "verdicts": verdicts,
            "attempts": max((r["_attempt"] for r in mine), default=0),
            "accepted": accepted[-1]["_file"] if accepted else None,
            "start": fmt(start), "end": fmt(end), "minutes": minutes,
            "slow": minutes is not None and minutes > typical.get(role, 10 ** 6),
            "_rec": accepted[-1] if accepted else None}


def section(text, heading):
    out, inside = [], False
    for line in text.splitlines():
        if line.startswith("## "):
            inside = line.strip() == heading
            continue
        if inside:
            out.append(line)
    return out


def codex_review(clone, rec):
    plan = next((a for a in rec.get("artifacts") or [] if a.startswith(".agents/plans/")), None)
    if not plan:
        return "unknown"
    try:
        text = subprocess.run(["git", "-C", clone, "show", f"{rec.get('output_rev')}:{plan}"],
                              capture_output=True, text=True, check=True).stdout
    except (OSError, subprocess.CalledProcessError):
        return "unknown"
    line = next((l for l in section(text, "## NOTES") if re.match(r"^\s*[-*]?\s*\**Codex", l)),
                None)
    if line is None:
        return "missing"
    return "no-opinion" if "brak opinii" in line else "present"


def planner_steps(clone, rec, mode):
    arts = rec.get("artifacts") or []

    def has(prefix):
        return "present" if any(a.startswith(prefix) for a in arts) else "missing"

    if mode == "quick":
        return {"plan-artifact": has(".agents/plans/"), "codex-plan-review": codex_review(clone, rec)}
    return {"spec-artifact": has(".agents/specs/"), "plan-artifact": has(".agents/plans/active/")}


def qa_steps(run_dir, rec):
    text = read_text(os.path.join(run_dir, f"qa-report-{rec['_attempt']}.md"))
    if text is None:
        return {"qa-report": "missing"}
    lines = text.splitlines()

    def value(key):
        return next((l[len(key) + 2:].strip() for l in lines if l.startswith(key + ": ")), None)

    keys = "present" if all(value(k) is not None for k in QA_KEYS) else "missing"
    build = value("Gate final-build")
    tests = TESTS.search(value("Tests") or "")
    iters = next((ITERATIONS.search(l) for l in lines
                  if l.startswith(("/check-implementation:", "Check-implementation:"))), None)
    ac = sum(1 for l in lines if re.search(r"\bAC\d+", l))
    return {"qa-report-keys": keys,
            "final-build": build.split()[0] if build else "missing",
            "tests": ("passed={} failed={} skipped={} baseline={}".format(*tests.groups())
                      if tests else "unknown"),
            "iterations": int(iters.group(1)) if iters else "unknown",
            "ac-lines": ac or "unknown"}


def contract_steps(run_dir, clone, mode, stages):
    steps = {}
    for s in stages:
        rec, role = s["_rec"], s["role"]
        if rec is None:
            continue
        pr = "present" if rec.get("pr_id") else "missing"
        if role == "planner":
            steps.update(planner_steps(clone, rec, mode))
        elif role == "coder":
            steps["coder-pr"] = pr
        elif role == "qa":
            steps.update(qa_steps(run_dir, rec))
        elif role == "wrapup":
            text = read_text(os.path.join(run_dir, f"wrapup-{rec['_attempt']}.md")) or ""
            ok = re.search(r"^target_rev: \S+", text, re.M)
            steps["wrapup-target-rev"] = "present" if ok else "missing"
        elif role == "cli":
            steps["cli-pr"] = pr
            ok = os.path.exists(os.path.join(run_dir, f"cli-{rec['_attempt']}.md"))
            steps["cli-summary"] = "present" if ok else "missing"
            steps["cli-tests"] = "unknown"
    return steps


def question_counts(qdir):
    c = {"questions": 0, "by_kind": {}, "by_tier": {}, "escalations": 0, "operator_escalations": 0}
    names = sorted(os.listdir(qdir)) if os.path.isdir(qdir) else []
    for name in (n for n in names if QUESTION.match(n)):
        text = read_text(os.path.join(qdir, name)) or ""
        c["questions"] += 1
        kind = re.search(r"^kind: (\S+)", text, re.M)
        k = kind.group(1) if kind else "unknown"
        c["by_kind"][k] = c["by_kind"].get(k, 0) + 1
        tiers = [l.split(":", 1)[1].strip() for l in section(text, "## Answer")
                 if l.startswith("tier:")]
        if tiers:
            c["by_tier"][tiers[-1]] = c["by_tier"].get(tiers[-1], 0) + 1
        if re.search(r"^## Escalation", text, re.M):
            c["escalations"] += 1
        if (tiers and tiers[-1] == "3") or re.search(r"^waiting: operator", text, re.M):
            c["operator_escalations"] += 1
    return c


def run_counts(run_dir, recs):
    c = question_counts(os.path.join(run_dir, "questions"))
    attention = read_text(os.path.join(run_dir, "attention")) or ""
    c["attention"] = len([l for l in attention.splitlines() if l.strip()])
    c["qa_rounds"] = sum(1 for r in recs if r["_role"] == "qa")
    c["records"] = {}
    for r in recs:
        c["records"][r.get("verdict", "?")] = c["records"].get(r.get("verdict", "?"), 0) + 1
    return c


def flags_for(stages, steps, counts, cfg, final):
    flags = [f"missing-stage:{s['role']}" for s in stages if final and s["status"] == "missing"]
    flags += [f"missing-step:{k}" for k, v in steps.items() if v == "missing" and k != "final-build"]
    if steps.get("codex-plan-review") == "no-opinion":
        flags.append("codex-no-opinion")
    build = steps.get("final-build")
    if build is not None and build != "passed":
        flags.append(f"final-build:{build}")
    flags += [f"slow:{s['role']}" for s in stages if s["slow"]]
    if counts["questions"] >= cfg["flags"]["questions_min"]:
        flags.append(f"questions:{counts['questions']}")
    if counts["qa_rounds"] >= cfg["flags"]["qa_rounds_min"]:
        flags.append(f"qa-rounds:{counts['qa_rounds']}")
    return flags


def run_state(stages, recs):
    if stages and all(s["status"] == "accepted" for s in stages):
        return "done"
    newest = max(recs, key=lambda r: r.get("written_at") or "", default=None)
    if newest and newest.get("verdict") in ("blocked", "failed"):
        return newest["verdict"]
    return "in-progress"


def header(a):
    try:
        with open(os.path.join(a.team_dir, "team.json"), encoding="utf-8") as f:
            tj = json.load(f)
    except (OSError, ValueError):
        tj = {}
    h = {k: tj.get(k) or "-" for k in ("team", "ticket", "branch", "line", "base_sha")}
    h.update({"mode": tj.get("mode") or "brainstorm", "run": a.run, "title": a.title or "-",
              "runner_exit": a.runner_exit if a.runner_exit is not None else "-",
              "audited_at": now_utc()})
    return h


def out_base(a, h):
    m = RUN_DATE.search(a.run)
    day = m.group(1) if m else dt.datetime.now(dt.timezone.utc).strftime("%Y%m%d")
    return os.path.join(a.out, f"{day}-{h['team']}-{h['ticket']}-{a.run}")


def collect(a, cfg, h, prev_final):
    run_dir = os.path.join(a.team_dir, "runs", a.run)
    roles = a.roles.split()
    if not os.path.isdir(run_dir):
        return {"state": "no-run-dir", "info": [f"run dir missing: {run_dir}"], "stages": [],
                "steps": {}, "counts": {}, "flags": [], "final": prev_final}
    recs = load_records(run_dir, roles)
    stages = [stage(run_dir, r, recs, cfg["typical_minutes"]) for r in roles]
    state, info = run_state(stages, recs), []
    final = prev_final
    if not final and a.final == "ready" and state != "done":
        info.append(f"--final ready ignored: state {state}")
    elif not final and a.final:
        final = a.final
    for s in stages:
        if final and s["status"] == "pending":
            s["status"] = "missing"
    steps = contract_steps(run_dir, a.clone, h["mode"], stages)
    counts = run_counts(run_dir, recs)
    prs = [r for r in recs if r["_role"] in ("coder", "cli") and r.get("pr_id")]
    h["pr"] = str(max(prs, key=lambda r: r.get("written_at") or "")["pr_id"]) if prs else "-"
    starts = [s["start"] for s in stages if s["start"] != "-"]
    h["started"] = min(starts, default="-")
    h["ended"] = max((r.get("written_at") or "" for r in recs), default="") or "-"
    for s in stages:
        s.pop("_rec")
    return {"state": state, "info": info, "stages": stages, "steps": steps, "counts": counts,
            "flags": flags_for(stages, steps, counts, cfg, final), "final": final}


def retro_decision(cfg, data, prev, entries, run):
    if prev and prev.get("final"):
        return prev.get("retro"), "no already-final"
    if data["state"] == "no-run-dir":
        return None, "no no-run-dir"
    if not data["final"]:
        return None, "no not-final"
    r = cfg["retro"]
    if not r.get("enabled", False):
        return "no disabled", "no disabled"
    if data["flags"]:
        d = "due flags" if r.get("on_flag", True) else "no on-flag-off"
        return d, d
    n = int(r.get("sample_every_clean") or 0)
    clean = sum(1 for e in entries if e.get("final") and not e.get("flags") and e["run"] != run)
    d = "due sample" if n > 0 and (clean + 1) % n == 0 else "no sample"
    return d, d


def read_index(path):
    entries = []
    for line in (read_text(path) or "").splitlines():
        try:
            entries.append(json.loads(line))
        except ValueError:
            continue
    return entries


def write_index(path, entries):
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        for e in entries:
            f.write(json.dumps(e, ensure_ascii=False) + "\n")
    os.replace(tmp, path)


def write_json(path, doc):
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(doc, f, ensure_ascii=False, indent=2)
        f.write("\n")
    os.replace(tmp, path)


def table(rows, cols):
    out = ["| " + " | ".join(cols) + " |", "|" + "---|" * len(cols)]
    out += ["| " + " | ".join(str(r.get(c, "-")) for c in cols) + " |" for r in rows]
    return out


def render_md(doc):
    h = doc["header"]
    keys = ("team", "ticket", "title", "mode", "run", "branch", "line", "pr", "state", "final",
            "runner_exit", "started", "ended", "audited_at")
    vals = dict(h, state=doc["state"], final=doc["final"] or "-")
    out = [f"# Team run audit: {h['ticket']} {h['run']}", "", "| Field | Value |", "|---|---|"]
    out += [f"| {k} | {vals.get(k, '-')} |" for k in keys]
    out += ["", "## Stages", ""]
    out += table(doc["stages"], ("role", "status", "records", "attempts", "accepted", "start",
                                 "end", "minutes", "slow"))
    out += ["", "## Steps", ""] + ([f"- {k}: {v}" for k, v in doc["steps"].items()] or ["- none"])
    out += ["", "## Counts", ""] + [f"- {k}: {json.dumps(v)}" for k, v in doc["counts"].items()]
    out += ["", "## Flags", ""] + ([f"- {f}" for f in doc["flags"]] or ["- none"])
    out += ["", "## Transcripts", ""]
    out += [f"- {t['role']} attempt {t['attempt']}: {t['path']}" for t in doc["transcripts"]]
    out += ["", "## Info", ""] + ([f"- {i}" for i in doc["info"]] or ["- none"])
    out += ["", f"Retro: {doc['retro'] or '-'}"]
    return "\n".join(out) + "\n"


def transcripts(specs):
    out = []
    for s in specs or []:
        key, _, path = s.partition("=")
        role, _, attempt = key.rpartition("-")
        out.append({"role": role, "attempt": attempt, "path": path,
                    "exists": os.path.isfile(path)})
    return out


def cmd_audit(a):
    cfg = load_config(a.config)
    # The project profile is the only switch (team-audit.sh reads teams.audit.retro).
    cfg["retro"]["enabled"] = a.retro == "on"
    os.makedirs(a.out, exist_ok=True)
    index = os.path.join(a.out, "index.jsonl")
    with open(os.path.join(a.out, "index.lock"), "w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        entries = read_index(index)
        prev = next((e for e in entries if e.get("run") == a.run), None)
        h = header(a)
        if prev and not a.title and prev.get("title"):
            h["title"] = prev["title"]
        data = collect(a, cfg, h, prev.get("final") if prev else None)
        stored, said = retro_decision(cfg, data, prev, entries, a.run)
        base = out_base(a, h)
        doc = dict(data, header=h, transcripts=transcripts(a.transcript), retro=stored,
                   retro_cfg=cfg["retro"])
        write_json(base + ".json", doc)
        with open(base + ".md", "w", encoding="utf-8") as f:
            f.write(render_md(doc))
        entry = {"run": a.run, "team": h["team"], "ticket": h["ticket"], "title": h["title"],
                 "mode": h["mode"], "branch": h["branch"], "pr": h.get("pr", "-"),
                 "state": data["state"], "final": data["final"], "flags": data["flags"],
                 "audit": base + ".md", "retro": stored, "info": data["info"],
                 "updated_at": now_utc()}
        write_index(index, [e for e in entries if e.get("run") != a.run] + [entry])
    print(f"audit: {base}.md")
    print(f"pr: {h.get('pr', '-')}")
    print(f"retro: {said}")
    return 0


def cmd_mark_retro(a):
    index = os.path.join(a.out, "index.jsonl")
    with open(os.path.join(a.out, "index.lock"), "w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        entries = read_index(index)
        entry = next((e for e in entries if e.get("run") == a.run), None)
        if entry is None:
            print(f"error: run {a.run} not in {index}", file=sys.stderr)
            return 1
        entry["retro"], entry["updated_at"] = a.value, now_utc()
        write_index(index, entries)
        doc_path = entry["audit"][:-3] + ".json"
        with open(doc_path, encoding="utf-8") as f:
            doc = json.load(f)
        doc["retro"] = a.value
        write_json(doc_path, doc)
    print(f"retro: {a.value}")
    return 0


def parser():
    p = argparse.ArgumentParser(prog="team_audit.py")
    sub = p.add_subparsers(dest="cmd", required=True)
    au = sub.add_parser("audit")
    for k in ("--team-dir", "--clone", "--run", "--out", "--config", "--roles"):
        au.add_argument(k, required=True)
    au.add_argument("--runner-exit", type=int)
    au.add_argument("--final", choices=("ready", "archived"))
    au.add_argument("--title")
    au.add_argument("--retro", choices=("on", "off"), default="off")
    au.add_argument("--transcript", action="append")
    mr = sub.add_parser("mark-retro")
    for k in ("--out", "--run", "--value"):
        mr.add_argument(k, required=True)
    return p


def main():
    a = parser().parse_args()
    try:
        return cmd_audit(a) if a.cmd == "audit" else cmd_mark_retro(a)
    except Exception as e:  # noqa: BLE001 — the audit is material only; callers warn and go on
        print(f"error: team audit: {type(e).__name__}: {e}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
