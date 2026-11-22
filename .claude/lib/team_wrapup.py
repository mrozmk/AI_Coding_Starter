"""The wrapup's proposals under a per-run TeamLead, the lead's decision on them, and the standards writer.

Usage: python3 -I team_wrapup.py check <proposals.json>                 → item count, exit 0
       python3 -I team_wrapup.py decide <proposals.json> <decision.md> <T>,<M>[,<S>] <opinion dir>...
                                                                         → items JSON, exit 0
       python3 -I team_wrapup.py entry-sha <patterns file> "<heading line>"   → sha256 of the entry
       python3 -I team_wrapup.py standards-add <root> <item id> <verdict.json> <target_rev>
       python3 -I team_wrapup.py standards-verify <run dir> <std-base> <std-qa> <std-after>
                                                   <pat-base> <pat-qa> <pat-after>   (absent file: -)
       python3 -I team_wrapup.py standards-merged <run dir> <std-wrapup> <std-merged> <pat-merged>
  <T>,<M>,<S>: tickets, memory entries and standards items this run's earlier wrapup verdicts
  already accepted, so the cap and the one-standards-item limit count the whole run.
Exit 4 with the reason on stderr when a file breaks the contract; 2 usage.

proposals.json (the wrapup writes it): {"run", "attempt", "items": [...]}, one item per proposal:
  {"id": "create-<n>", "kind": "ticket", "title", "body"} — create-<n> is the draft key and the
  stable create intent id in wrapup-state.json;
  {"id": "memory-<n>", "kind": "memory", "group": "A"|"B", "target": ".agents/memory/<file>",
   "text", "czytelnik"[, "handoff": "<the acceptance ref>"]}. A target named decisions.md,
  patterns.md or index.md is group B whatever the item says. A hand-off its decider already
  accepted carries `handoff` and uses neither the cap nor an opinion.
  A standards item: target "docs/coding-standards.md" (always group B, never a hand-off, at most one
  per proposals file and one accepted per run), plus "section" (Rules | Shared helpers | One shape
  per problem | Open — pick one), "text" (Rules: the rule and the four lines `- Enforced by:`,
  `- Applies to:`, `- Example:`, `- Why:`; a table section: one `| a | b | c |` row; Open: one
  `- ` line), "evidence" (<path>:<line>) and, for a rule replacing a patterns.md entry, "promotes"
  (the entry's `## ` heading line) with "promotes_sha256" (entry-sha of that entry).
decision.md (the lead writes it), one line per item, in any order; '#' lines and blank lines aside:
  - <id> accept — needed because <why>[ — over cap because <why>]
    correction: <one line>          (optional, at most one, only under an accept, never a standards item)
  - <id> decline — <reason>
Every item is decided exactly once, every reason is non-empty. At most CAP_TICKETS tickets and
CAP_MEMORY memory entries (both groups together) per run are accepted without `over cap because`;
a group B accept names an existing opinion-<n>.md. There is no third answer: an item the lead
cannot judge is declined.
Contract: .agents/reference/team-lead.md §10 (Wrapup).
"""
import glob
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
sys.dont_write_bytecode = True

CAP_TICKETS = 1
CAP_MEMORY = 1
GROUP_B_FILES = ("decisions.md", "patterns.md", "index.md")
STD = "docs/coding-standards.md"
PATTERNS = ".agents/memory/patterns.md"
SECTIONS = ("Rules", "Shared helpers", "One shape per problem", "Open — pick one")
RULE_KEYS = ("- Enforced by:", "- Applies to:", "- Example:", "- Why:")
PAYLOAD = ("section", "text", "evidence", "promotes", "promotes_sha256")
ID = re.compile(r"(create|memory)-[1-9][0-9]*")
SEP = r"\s+(?:—|--)\s+"
ACCEPT = re.compile(r"- (\S+) accept" + SEP + r"needed because\s+(\S.*?)(?:" + SEP
                    + r"over cap because\s+(\S.*))?")
DECLINE = re.compile(r"- (\S+) decline" + SEP + r"(\S.*)")
CORRECTION = re.compile(r"\s+correction:\s*(.*)")
OPINION = re.compile(r"(?<![A-Za-z0-9_.-])opinion-[0-9]+\.md(?![A-Za-z0-9_-])")
CS_HEAD = re.compile(r"### CS-([0-9]+)\b")
EVIDENCE = re.compile(r"\S+:[1-9][0-9]*")
SHA = re.compile(r"[0-9a-f]{64}")
VERDICT_NAME = re.compile(r"teamlead-wrapup-[0-9]+\.json")


class Bad(Exception):
    pass


def text(item, key):
    v = item.get(key)
    if not isinstance(v, str) or not v.strip():
        raise Bad("item %s has no %s" % (item.get("id", "?"), key))
    return v


def group(item):
    if item["target"] == STD:
        return "B"
    return "B" if os.path.basename(item["target"]) in GROUP_B_FILES else item["group"]


def split_cells(row):
    """Cells of a `| a | b | c |` row, split on unescaped `|` only (an escaped `\\|` stays in its cell)."""
    inner, cells, cur, i = row[1:-1], [], "", 0
    while i < len(inner):
        if inner[i] == "\\" and i + 1 < len(inner) and inner[i + 1] == "|":
            cur += "\\|"
            i += 2
            continue
        if inner[i] == "|":
            cells.append(cur)
            cur = ""
        else:
            cur += inner[i]
        i += 1
    cells.append(cur)
    return cells


def shape(section, body):
    """Checks a standards item's text against its section; returns its lines."""
    if section not in SECTIONS:
        raise Bad("section must be one of: " + ", ".join(SECTIONS))
    lines = body.split("\n") if isinstance(body, str) else []
    if section == "Rules":
        ok = len(lines) == 5 and lines[0].strip() and not lines[0].startswith("#")
        for key, line in zip(RULE_KEYS, lines[1:] if ok else []):
            ok = ok and line.startswith(key + " ") and line[len(key):].strip()
        if not ok:
            raise Bad("rule text must be the rule and the four lines " + ", ".join(RULE_KEYS))
        what = lines[1][len(RULE_KEYS[0]):].strip()
        if what != "review" and not re.fullmatch(r"tool \(\s*\S.*\)", what):
            raise Bad("Enforced by must be review or tool (<what>)")
    elif section == "Open — pick one":
        if len(lines) != 1 or not lines[0].startswith("- ") or not lines[0][2:].strip():
            raise Bad('an Open item is one line starting "- "')
    else:
        row = lines[0] if len(lines) == 1 else ""
        if not (len(row) > 1 and row.startswith("|") and row.endswith("|")) \
                or len(split_cells(row)) != 3 or not all(c.strip() for c in split_cells(row)):
            raise Bad("a table row must have exactly 3 non-empty cells")
    return lines


def check_standards_item(it):
    if "handoff" in it:
        raise Bad("a standards item is never a hand-off")
    shape(it.get("section"), it.get("text"))
    if not isinstance(it.get("evidence"), str) or not EVIDENCE.fullmatch(it["evidence"]):
        raise Bad("evidence must be <path>:<line>")
    has_p, has_s = "promotes" in it, "promotes_sha256" in it
    if has_p or has_s:
        if it.get("section") != "Rules":
            raise Bad("promotes needs section Rules")
        if not (has_p and has_s):
            raise Bad("promotes and promotes_sha256 go together")
        p = it["promotes"]
        if not isinstance(p, str) or not p.startswith("## ") or "\n" in p or not p[3:].strip():
            raise Bad("promotes must be one '## ' heading line of a patterns.md entry")
        if not isinstance(it["promotes_sha256"], str) or not SHA.fullmatch(it["promotes_sha256"]):
            raise Bad("promotes_sha256 must be 64 lowercase hex")


def proposals_root(path):
    a = os.path.abspath(path)
    i = a.find("/.agents/team/")
    return a[:i] if i >= 0 else os.getcwd()


def load_proposals(path):
    try:
        with open(path, encoding="utf-8") as f:
            doc = json.load(f)
    except (OSError, ValueError) as e:
        raise Bad("%s is not readable JSON (%s)" % (path, e))
    items = doc.get("items") if isinstance(doc, dict) else None
    if not isinstance(items, list) or not items:
        raise Bad("%s has no items — with nothing to propose there is no proposals file" % path)
    seen, standards = set(), 0
    for it in items:
        if not isinstance(it, dict) or not ID.fullmatch(str(it.get("id", ""))):
            raise Bad("an item id must be create-<n> or memory-<n>")
        if it["id"] in seen:
            raise Bad("item %s appears twice" % it["id"])
        seen.add(it["id"])
        want = "ticket" if it["id"].startswith("create-") else "memory"
        if it.get("kind") != want:
            raise Bad("item %s must have kind %s" % (it["id"], want))
        if want == "ticket":
            text(it, "title"), text(it, "body")
            continue
        text(it, "text"), text(it, "czytelnik")
        t = text(it, "target")
        if t != STD and (not t.startswith(".agents/memory/") or ".." in t.split("/") or t.endswith("/")):
            raise Bad("item %s: target must be a file under .agents/memory/ or %s" % (it["id"], STD))
        if it.get("group") not in ("A", "B"):
            raise Bad("item %s needs group A or B" % it["id"])
        if t == STD:
            check_standards_item(it)
            standards += 1
            if standards > 1:
                raise Bad("one standards item per proposals file")
        elif "handoff" in it:
            text(it, "handoff")
    if standards and not os.path.isfile(os.path.join(proposals_root(path), STD)):
        raise Bad("%s is absent — the standards feature is off" % STD)
    return items


def parse_prior(arg):
    m = re.fullmatch(r"([0-9]+),([0-9]+)(?:,([0-9]+))?", arg)
    if not m:
        raise Bad("prior counts must be <tickets>,<memory>[,<standards>]")
    return {"ticket": int(m.group(1)), "memory": int(m.group(2)), "standards": int(m.group(3) or 0)}


def decide(items, decision, prior, opinion_dirs):
    try:
        with open(decision, encoding="utf-8") as f:
            lines = f.read().splitlines()
    except OSError as e:
        raise Bad("%s is not readable (%s)" % (decision, e))
    known = {it["id"]: it for it in items}
    out, last = {}, None
    for n, line in enumerate(lines, 1):
        if not line.strip() or line.startswith("#"):
            continue
        m = CORRECTION.fullmatch(line)
        if m:
            if last is None or last["decision"] != "accept":
                raise Bad("line %d: a correction belongs under an accept" % n)
            if last.get("target") == STD:
                raise Bad("a standards item takes no correction — decline it with the reason")
            if "correction" in last:
                raise Bad("line %d: one correction line per item — decline a draft that needs more" % n)
            if not m.group(1).strip():
                raise Bad("line %d: an empty correction" % n)
            last["correction"] = m.group(1).strip()
            continue
        m = ACCEPT.fullmatch(line)
        d = {"decision": "accept", "why": m.group(2).strip()} if m else None
        if m and m.group(3):
            d["over_cap"] = m.group(3).strip()
        if not m:
            m = DECLINE.fullmatch(line)
            d = {"decision": "decline", "why": m.group(2).strip()} if m else None
        # An empty `over cap because` leaves the phrase inside the needed-because reason.
        if not m or not d["why"] or re.search(SEP + r"over cap because", " " + d["why"]):
            raise Bad("line %d is neither '- <id> accept — needed because <why>' nor '- <id> decline — "
                      "<reason>' with a non-empty reason: %s" % (n, line[:120]))
        i = m.group(1)
        if i not in known:
            raise Bad("line %d: %s is not a proposed item" % (n, i))
        if i in out:
            raise Bad("line %d: %s is decided twice" % (n, i))
        it = known[i]
        d.update(id=i, kind=it["kind"])
        if it["kind"] == "memory":
            d.update(group=group(it), target=it["target"])
            if "handoff" in it:
                d["handoff"] = True
            if it["target"] == STD:
                # The decided text travels with the decision: the writer and the runner read it here.
                d.update((k, it[k]) for k in PAYLOAD if k in it)
        out[i] = last = d
    missing = [i for i in known if i not in out]
    if missing:
        raise Bad("not decided: %s" % ", ".join(missing))
    counts = dict(prior)
    caps = {"ticket": CAP_TICKETS, "memory": CAP_MEMORY}
    for d in (out[it["id"]] for it in items):
        if d["decision"] != "accept" or d.get("handoff"):
            continue
        if d.get("target") == STD:
            if counts["standards"] >= 1:
                raise Bad("%s: one standards item per run — %d already accepted" % (d["id"], counts["standards"]))
            counts["standards"] += 1
        counts[d["kind"]] += 1
        if counts[d["kind"]] > caps[d["kind"]] and "over_cap" not in d:
            raise Bad("%s: more than %d %s accepted in this run — add '— over cap because <why>'"
                      % (d["id"], caps[d["kind"]], "ticket" if d["kind"] == "ticket" else "memory entry"))
        if d.get("group") == "B":
            names = OPINION.findall(d["why"] + " " + d.get("over_cap", ""))
            if not any(os.path.isfile(os.path.join(o, x)) for x in names for o in opinion_dirs):
                raise Bad("%s: a group B accept names its Codex opinion-<n>.md (an existing file)" % d["id"])
    return [out[it["id"]] for it in items]


# ---- the standards document and the patterns.md entries -------------------------------------

def split_doc(doc):
    """(lines, trailing newline?) — the renderer works on lines and restores the file's last newline."""
    if doc.endswith("\n"):
        return doc[:-1].split("\n"), True
    return doc.split("\n"), False


def join_doc(lines, nl):
    return "\n".join(lines) + ("\n" if nl else "")


def section_span(lines, name):
    heads = [i for i, l in enumerate(lines) if l.rstrip() == "## " + name]
    if len(heads) != 1:
        raise Bad("section %s appears %d times" % (name, len(heads)))
    s = heads[0]
    e = next((j for j in range(s + 1, len(lines)) if lines[j].startswith("## ")), len(lines))
    return s, e


def last_nonblank(lines, s, e):
    return max(j for j in range(s, e) if lines[j].strip())


def next_cs(lines):
    return 1 + max([int(m.group(1)) for m in (CS_HEAD.match(l) for l in lines) if m] or [0])


def rule_ids(lines, s, e, rule, bullets):
    """CS ids of every `### CS-<k> — <rule>` heading in lines[s:e] followed by the 4 bullet lines verbatim."""
    found = []
    for j in range(s, e):
        m = CS_HEAD.match(lines[j])
        if m and lines[j] == "### CS-%s — %s" % (m.group(1), rule) and lines[j + 1:j + 5] == bullets:
            found.append(int(m.group(1)))
    return found


def render(doc, item):
    """(new text, what, cs id or None, already applied?) — the one renderer of writer and verifier."""
    if doc is None:
        raise Bad("%s is absent" % STD)
    body = shape(item.get("section"), item.get("text"))
    lines, nl = split_doc(doc)
    s, e = section_span(lines, item["section"])
    if item["section"] == "Rules":
        rule, bullets = body[0], body[1:]
        have = rule_ids(lines, s, e, rule, bullets)
        if have:
            return doc, "CS-%d" % have[0], have[0], True
        cs = next_cs(lines)
        at = last_nonblank(lines, s, e) + 1
        lines[at:at] = ["", "### CS-%d — %s" % (cs, rule)] + bullets
        return join_doc(lines, nl), "CS-%d" % cs, cs, False
    line = body[0]
    what = "open" if item["section"] == "Open — pick one" else "row"
    if line in lines[s + 1:e]:
        return doc, what, None, True
    if what == "row":
        rows = [j for j in range(s + 1, e) if lines[j].startswith("|")]
        if not rows:
            raise Bad("section %s has no table" % item["section"])
        lines.insert(rows[-1] + 1, line)
    else:
        at = last_nonblank(lines, s, e)
        lines[at + 1:at + 1] = [line] if at > s else ["", line]
    return join_doc(lines, nl), what, None, False


def entries(doc):
    """[(start, end)] of every patterns.md entry: a `## ` heading outside fences after `## Format`,
    up to the next entry heading or EOF, trailing blank lines dropped."""
    lines, _ = split_doc(doc)
    heads, fence, after_format = [], False, not any(l.rstrip() == "## Format" for l in lines)
    for i, l in enumerate(lines):
        if l.startswith("```"):
            fence = not fence
            continue
        if fence or not l.startswith("## "):
            continue
        if l.rstrip() == "## Format":
            after_format = True
            continue
        if after_format:
            heads.append(i)
    spans = []
    for k, s in enumerate(heads):
        e = heads[k + 1] if k + 1 < len(heads) else len(lines)
        while e > s + 1 and not lines[e - 1].strip():
            e -= 1
        spans.append((s, e))
    return lines, spans


def find_entry(doc, heading):
    lines, spans = entries(doc)
    hit = [sp for sp in spans if lines[sp[0]] == heading]
    return lines, hit


def entry_sha(doc, heading):
    lines, hit = find_entry(doc, heading)
    if len(hit) != 1:
        raise Bad("promotes is not a patterns.md entry heading found exactly once")
    s, e = hit[0]
    return hashlib.sha256("\n".join(lines[s:e]).encode("utf-8")).hexdigest()


def pointer(item, cs):
    return "%s — promoted to %s CS-%d" % (item["promotes"], STD, cs)


def pointer_lines(doc, item):
    pre = "%s — promoted to %s CS-" % (item["promotes"], STD)
    return [l for l in split_doc(doc)[0] if l.startswith(pre) and l[len(pre):].isdigit()] if doc else []


def promote(doc, item, cs):
    """patterns.md with the promoted entry replaced by its one-line pointer (unchanged when done)."""
    if doc is None:
        raise Bad("promoted entry not found and no pointer present")
    lines, hit = find_entry(doc, item["promotes"])
    _, nl = split_doc(doc)
    if not hit:
        if pointer(item, cs) in lines:
            return doc
        raise Bad("promoted entry not found and no pointer present")
    if len(hit) != 1:
        raise Bad("promotes is not a patterns.md entry heading found exactly once")
    if entry_sha(doc, item["promotes"]) != item["promotes_sha256"]:
        raise Bad("the promoted entry no longer matches promotes_sha256")
    s, e = hit[0]
    lines[s:e] = [pointer(item, cs)]
    return join_doc(lines, nl)


# ---- the writer (standards-add) ---------------------------------------------------------------

def read_json(path):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError) as e:
        raise Bad("%s is not readable JSON (%s)" % (path, e))


def safe_dest(root, rel):
    real_root = os.path.realpath(root)
    p, parts = root, rel.split("/")
    for part in parts:
        p = os.path.join(p, part)
        if os.path.islink(p):
            raise Bad("refuses a symlinked destination: %s" % rel)
    rp = os.path.realpath(p)
    if not os.path.isfile(p) or not rp.startswith(real_root + os.sep):
        raise Bad("destination is not a regular file inside the clone: %s" % rel)
    return p


def wrapup_identity(root):
    sp = os.path.join(root, ".agents", "team", "session.json")
    if os.environ.get("TEAM_SESSION_ROLE") == "TeamLead" or not os.path.isfile(sp):
        raise Bad("standards-add is the wrapup's")
    s = read_json(sp)
    if not isinstance(s, dict) or s.get("role") != "wrapup" or not s.get("run"):
        raise Bad("standards-add is the wrapup's")
    return s


def git(root, *args):
    r = subprocess.run(["git", "-C", root] + list(args), stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    return r.returncode, r.stdout


def blob(root, rev, rel):
    rc, out = git(root, "show", "%s:%s" % (rev, rel))
    return out.decode("utf-8") if rc == 0 else None


def render_base(root, rel, cur, qa_rev, base_sha, target_rev):
    """The writer's refresh rule: start from <target_rev>'s version only for a file still at QA that
    the line changed since the team base; otherwise from the worktree file."""
    if cur != blob(root, qa_rev, rel):
        return cur
    rc, _ = git(root, "diff", "--quiet", base_sha, target_rev, "--", rel)
    t = blob(root, target_rev, rel) if rc == 1 else None
    return t if t is not None else cur


def verdict_item(verdict_path, vdoc, item_id):
    it = next((x for x in vdoc.get("items") or [] if isinstance(x, dict) and x.get("id") == item_id), None)
    if it is None or it.get("decision") != "accept":
        raise Bad("%s is not accepted in %s" % (item_id, verdict_path))
    if it.get("target") != STD:
        raise Bad("%s is not a standards item" % item_id)
    if "section" not in it or "text" not in it:
        raise Bad("verdict lacks the standards payload — written by an older clone")
    return it


def write_all(changes):
    """Stage every changed file beside its destination, then replace them in order."""
    temps = []
    try:
        for dest, content in changes:
            fd, tmp = tempfile.mkstemp(dir=os.path.dirname(dest), prefix="." + os.path.basename(dest) + ".")
            temps.append(tmp)
            os.fchmod(fd, os.stat(dest).st_mode & 0o7777)
            with os.fdopen(fd, "w", encoding="utf-8", newline="") as f:
                f.write(content)
        for (dest, _), tmp in zip(changes, temps):
            os.replace(tmp, dest)
    finally:
        for tmp in temps:
            if os.path.exists(tmp):
                os.remove(tmp)


def standards_add(root, item_id, verdict, target_rev):
    sess = wrapup_identity(root)
    run_dir = os.path.join(root, ".agents", "team", "runs", sess["run"])
    vreal = os.path.realpath(verdict)
    if os.path.dirname(vreal) != os.path.realpath(run_dir) or not VERDICT_NAME.fullmatch(os.path.basename(vreal)):
        raise Bad("the verdict is not this run's: %s" % verdict)
    vdoc = read_json(vreal)
    if vdoc.get("run") != sess["run"]:
        raise Bad("the verdict is not this run's: %s" % verdict)
    item = verdict_item(verdict, vdoc, item_id)
    prop_path = os.path.join(run_dir, str(vdoc.get("for", "")))
    prop = read_json(prop_path)
    pit = next((x for x in prop.get("items") or [] if isinstance(x, dict) and x.get("id") == item_id), None)
    with open(prop_path, "rb") as f:
        psha = hashlib.sha256(f.read()).hexdigest()
    if pit is None or any(pit.get(k) != item.get(k) for k in PAYLOAD) \
            or (vdoc.get("proposals_sha256") and vdoc["proposals_sha256"] != psha):
        raise Bad("%s changed after the TeamLead decided it" % os.path.basename(prop_path))
    std = safe_dest(root, STD)
    pat = safe_dest(root, PATTERNS) if "promotes" in item else None
    team = read_json(os.path.join(root, ".agents", "team", "team.json"))
    qa_rev, base_sha = sess.get("input_rev", ""), team.get("base_sha", "")
    with open(std, encoding="utf-8", newline="") as f:
        std_cur = f.read()
    new_std, what, cs, already = render(render_base(root, STD, std_cur, qa_rev, base_sha, target_rev), item)
    changes = [(std, new_std)] if new_std != std_cur else []
    std_changed = bool(changes)
    if pat:
        with open(pat, encoding="utf-8", newline="") as f:
            pat_cur = f.read()
        new_pat = promote(render_base(root, PATTERNS, pat_cur, qa_rev, base_sha, target_rev), item, cs)
        if new_pat != pat_cur:
            changes.append((pat, new_pat))
    write_all(changes)
    if already and not changes:
        return "already applied %s" % what
    if already and not std_changed:
        return "already applied %s (pointer written)" % what
    return "applied %s" % what


# ---- the runner's checks (standards-verify, standards-merged) --------------------------------

def read_opt(path):
    if path == "-":
        return None
    with open(path, encoding="utf-8", newline="") as f:
        return f.read()


def accepted_standards(run_dir):
    """([(label, item)], another accepted memory item targets patterns.md?) over this run's verdicts."""
    def seq(p):
        return int(re.search(r"([0-9]+)\.json$", p).group(1))
    out, other_pat = [], False
    for v in sorted(glob.glob(os.path.join(run_dir, "teamlead-wrapup-*.json")), key=seq):
        for it in read_json(v).get("items") or []:
            if not isinstance(it, dict) or it.get("decision") != "accept":
                continue
            if it.get("target") == STD:
                if "section" not in it or "text" not in it:
                    raise Bad("verdict lacks the standards payload — written by an older clone")
                out.append(("%s:%s" % (os.path.basename(v), it.get("id")), it))
            elif it.get("kind") == "memory" and it.get("target") == PATTERNS:
                other_pat = True
    return out, other_pat


def first_diff(a, b):
    la, lb = (a or "").split("\n"), (b or "").split("\n")
    return next((i + 1 for i, (x, y) in enumerate(zip(la, lb)) if x != y), min(len(la), len(lb)) + 1)


def standards_verify(run_dir, std_base, std_qa, std_after, pat_base, pat_qa, pat_after):
    items, other_pat = accepted_standards(run_dir)
    exp_std, exp_pat, promoted, applied = std_base, pat_base, [], []
    for label, item in items:
        try:
            nstd, _, cs, _ = render(exp_std, item)
            npat = promote(exp_pat, item, cs) if "promotes" in item else exp_pat
        except Bad as why:
            # A refusal the writer would hit on these pinned inputs: permitted only when nothing moved.
            head_kept = "promotes" not in item or pat_qa is None \
                or item["promotes"] not in split_doc(pat_qa)[0] or item["promotes"] in split_doc(pat_after or "")[0]
            if std_after == std_qa and not pointer_lines(pat_after, item) and head_kept:
                exp_std = std_qa
                continue
            raise Bad("%s cannot apply (%s) but the files changed" % (label, why))
        exp_std, exp_pat = nstd, npat
        applied.append(label)
        if "promotes" in item:
            promoted.append((label, item, cs))
    if std_after is None and std_qa is not None:
        raise Bad("%s removed" % STD)
    if std_after != exp_std:
        if std_after == std_qa and applied:
            raise Bad("accepted standards item %s not applied" % applied[-1])
        raise Bad("%s differs from the accepted item rendered at line %d" % (STD, first_diff(exp_std, std_after)))
    if not promoted:
        return
    if not other_pat:
        if pat_after != exp_pat:
            raise Bad("patterns.md differs from the promotion of %s at line %d"
                      % (promoted[-1][0], first_diff(exp_pat, pat_after)))
        return
    # Another accepted memory item may change patterns.md too: the pointer and no promoted entry suffice.
    for label, item, cs in promoted:
        if pat_after is None or pointer(item, cs) not in split_doc(pat_after)[0] \
                or find_entry(pat_after, item["promotes"])[1]:
            raise Bad("patterns.md lacks the pointer of %s or keeps the promoted entry" % label)


def applied_at(doc, item):
    """How often the item stands applied in doc, and the CS id of a rule (None for a row)."""
    lines, _ = split_doc(doc)
    s, e = section_span(lines, item["section"])
    body = shape(item["section"], item["text"])
    if item["section"] == "Rules":
        ids = rule_ids(lines, s, e, body[0], body[1:])
        return len(ids), (ids[0] if ids else None)
    return lines[s + 1:e].count(body[0]), None


def standards_merged(run_dir, std_wrapup, std_merged, pat_merged):
    items, _ = accepted_standards(run_dir)
    for label, item in items:
        if std_wrapup is None or applied_at(std_wrapup, item)[0] == 0:
            continue
        if std_merged is None:
            raise Bad("%s: %s absent after the merge" % (label, STD))
        n, cs = applied_at(std_merged, item)
        if n != 1:
            raise Bad("%s: found %d times after the merge, not once" % (label, n))
        if "promotes" in item:
            ptrs = pointer_lines(pat_merged, item)
            if ptrs != [pointer(item, cs)] or find_entry(pat_merged or "", item["promotes"])[1]:
                raise Bad("%s: patterns.md does not hold exactly the pointer to CS-%d" % (label, cs))


def main(argv):
    try:
        if len(argv) == 3 and argv[1] == "check":
            print(len(load_proposals(argv[2])))
            return 0
        if len(argv) >= 6 and argv[1] == "decide":
            print(json.dumps(decide(load_proposals(argv[2]), argv[3], parse_prior(argv[4]), argv[5:])))
            return 0
        if len(argv) == 4 and argv[1] == "entry-sha":
            print(entry_sha(read_opt(argv[2]), argv[3]))
            return 0
        if len(argv) == 6 and argv[1] == "standards-add":
            print(standards_add(*argv[2:6]))
            return 0
        if len(argv) == 9 and argv[1] == "standards-verify":
            standards_verify(argv[2], *[read_opt(p) for p in argv[3:9]])
            return 0
        if len(argv) == 6 and argv[1] == "standards-merged":
            standards_merged(argv[2], *[read_opt(p) for p in argv[3:6]])
            return 0
    except Bad as e:
        print("error: %s" % e, file=sys.stderr)
        return 4
    except OSError as e:
        print("error: %s" % e, file=sys.stderr)
        return 4
    print(__doc__.strip().split("\n\n")[0], file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
