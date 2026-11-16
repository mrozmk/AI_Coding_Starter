"""The wrapup's proposals under a per-run TeamLead, and the lead's decision on them.

Usage: python3 -I team_wrapup.py check <proposals.json>                 → item count, exit 0
       python3 -I team_wrapup.py decide <proposals.json> <decision.md> <T>,<M> <opinion dir>...
                                                                         → items JSON, exit 0
  <T>,<M>: tickets and memory entries this run's earlier wrapup verdicts already accepted within
  the cap, so the cap counts the whole run, not one proposals file.
Exit 4 with the reason on stderr when a file breaks the contract; 2 usage.

proposals.json (the wrapup writes it): {"run", "attempt", "items": [...]}, one item per proposal:
  {"id": "create-<n>", "kind": "ticket", "title", "body"} — create-<n> is the draft key and the
  stable create intent id in wrapup-state.json;
  {"id": "memory-<n>", "kind": "memory", "group": "A"|"B", "target": ".agents/memory/<file>",
   "text", "czytelnik"[, "handoff": "<the acceptance ref>"]}. A target named decisions.md,
  patterns.md or index.md is group B whatever the item says. A hand-off its decider already
  accepted carries `handoff` and uses neither the cap nor an opinion.
decision.md (the lead writes it), one line per item, in any order; '#' lines and blank lines aside:
  - <id> accept — needed because <why>[ — over cap because <why>]
    correction: <one line>          (optional, at most one, only under an accept)
  - <id> decline — <reason>
Every item is decided exactly once, every reason is non-empty. At most CAP_TICKETS tickets and
CAP_MEMORY memory entries (both groups together) per run are accepted without `over cap because`;
a group B accept names an existing opinion-<n>.md. There is no third answer: an item the lead
cannot judge is declined.
Contract: .agents/reference/team-lead.md §10 (Wrapup).
"""
import json
import os
import re
import sys
sys.dont_write_bytecode = True

CAP_TICKETS = 1
CAP_MEMORY = 1
GROUP_B_FILES = ("decisions.md", "patterns.md", "index.md")
ID = re.compile(r"(create|memory)-[1-9][0-9]*")
SEP = r"\s+(?:—|--)\s+"
ACCEPT = re.compile(r"- (\S+) accept" + SEP + r"needed because\s+(\S.*?)(?:" + SEP
                    + r"over cap because\s+(\S.*))?")
DECLINE = re.compile(r"- (\S+) decline" + SEP + r"(\S.*)")
CORRECTION = re.compile(r"\s+correction:\s*(.*)")
OPINION = re.compile(r"(?<![A-Za-z0-9_.-])opinion-[0-9]+\.md(?![A-Za-z0-9_-])")


class Bad(Exception):
    pass


def text(item, key):
    v = item.get(key)
    if not isinstance(v, str) or not v.strip():
        raise Bad("item %s has no %s" % (item.get("id", "?"), key))
    return v


def group(item):
    return "B" if os.path.basename(item["target"]) in GROUP_B_FILES else item["group"]


def load_proposals(path):
    try:
        with open(path, encoding="utf-8") as f:
            doc = json.load(f)
    except (OSError, ValueError) as e:
        raise Bad("%s is not readable JSON (%s)" % (path, e))
    items = doc.get("items") if isinstance(doc, dict) else None
    if not isinstance(items, list) or not items:
        raise Bad("%s has no items — with nothing to propose there is no proposals file" % path)
    seen = set()
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
        if not t.startswith(".agents/memory/") or ".." in t.split("/") or t.endswith("/"):
            raise Bad("item %s: target must be a file under .agents/memory/" % it["id"])
        if it.get("group") not in ("A", "B"):
            raise Bad("item %s needs group A or B" % it["id"])
        if "handoff" in it:
            text(it, "handoff")
    return items


def parse_prior(arg):
    m = re.fullmatch(r"([0-9]+),([0-9]+)", arg)
    if not m:
        raise Bad("prior counts must be <tickets>,<memory>")
    return {"ticket": int(m.group(1)), "memory": int(m.group(2))}


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
        out[i] = last = d
    missing = [i for i in known if i not in out]
    if missing:
        raise Bad("not decided: %s" % ", ".join(missing))
    counts = dict(prior)
    caps = {"ticket": CAP_TICKETS, "memory": CAP_MEMORY}
    for d in (out[it["id"]] for it in items):
        if d["decision"] != "accept" or d.get("handoff"):
            continue
        counts[d["kind"]] += 1
        if counts[d["kind"]] > caps[d["kind"]] and "over_cap" not in d:
            raise Bad("%s: more than %d %s accepted in this run — add '— over cap because <why>'"
                      % (d["id"], caps[d["kind"]], "ticket" if d["kind"] == "ticket" else "memory entry"))
        if d.get("group") == "B":
            names = OPINION.findall(d["why"] + " " + d.get("over_cap", ""))
            if not any(os.path.isfile(os.path.join(o, x)) for x in names for o in opinion_dirs):
                raise Bad("%s: a group B accept names its Codex opinion-<n>.md (an existing file)" % d["id"])
    return [out[it["id"]] for it in items]


def main(argv):
    try:
        if len(argv) == 3 and argv[1] == "check":
            print(len(load_proposals(argv[2])))
            return 0
        if len(argv) >= 6 and argv[1] == "decide":
            print(json.dumps(decide(load_proposals(argv[2]), argv[3], parse_prior(argv[4]), argv[5:])))
            return 0
    except Bad as e:
        print("error: %s" % e, file=sys.stderr)
        return 4
    print(__doc__.strip().split("\n\n")[0], file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
