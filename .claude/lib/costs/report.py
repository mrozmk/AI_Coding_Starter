"""Per-ticket token report: allocation, rollup, coverage, reconciliation, render (spec TT-813).

Python 3.9 stdlib only.
"""
import collections
import json
import os
import re
import subprocess

import bindings
import config
import runtime
import stages
import store

ROLE_RE = re.compile(r"^([a-z0-9]+)-(planner|coder|qa|wrapup)$")
TOKEN_HEADER = "Input | Cache write | Cache read | Output | Total |"
Allocation = collections.namedtuple("Allocation",
                                    "groups items seen included unassigned conflicts")
COLUMNS = ("provider", "model", "effort", "agent", "team", "role", "basis")


class Labels:
    """Agent labels, team/role and coverage per usage row, cached per session."""

    def __init__(self, conn):
        self.sessions = {(r["provider"], r["session"], r["agent_id"]): r for r in
                         conn.execute("SELECT * FROM sessions")}
        self.types = {(r[0], r[1]): r[2] for r in
                      conn.execute("SELECT session, agent_id, agent_type FROM subagents")}
        self.roles = runtime.team_roles(conn)
        self.names = runtime.names(conn)

    def main(self, row):
        s = self.sessions.get((row["provider"], row["session"], ""))
        if row["provider"] == "codex":
            return f"{(s and s['source_label']) or 'codex'}:{row['session'][:8]}"
        return ((s and s["agent_label"]) or self.names.get(row["session"])
                or f"claude:{row['session'][:8]}")

    def agent(self, row):
        main = self.main(row)
        m = ROLE_RE.match(main)
        team, role = (m.group(1), m.group(2)) if m else (None, None)
        if row["provider"] == "claude" and row["session"] in self.roles:
            team, role = self.roles[row["session"]]
        if row["agent_id"]:
            main += "/" + (self.types.get((row["session"], row["agent_id"])) or "subagent")
        return main, team, role

    def partial(self, row):
        keys = [(row["provider"], row["session"], row["agent_id"] or "")]
        if row["agent_id"]:
            keys.append((row["provider"], row["session"], ""))
        return any(self.sessions.get(k) is not None and self.sessions[k]["coverage_reasons"]
                   for k in keys)


def _revision():
    tool_dir = os.path.dirname(os.path.abspath(__file__))
    try:
        out = subprocess.run(["git", "-C", tool_dir, "rev-parse", "--short", "HEAD"],
                             capture_output=True, text=True, check=False)
    except OSError:
        return "unknown"
    return out.stdout.strip() if out.returncode == 0 and out.stdout.strip() else "unknown"


def _bucket(store_, key, extra=None):
    return store_.setdefault(key, dict(extra or {}, **dict.fromkeys(bindings.TOKENS, 0.0)))


def _add(target, row, share):
    for k, v in bindings.tokens(row, share).items():
        target[k] += v


def _allocate(conn, tickets, with_ticket, labels):
    groups, items, seen, sessions, unassigned, conflicts = {}, [], set(), set(), {}, {}
    included = []
    allocs = bindings.allocate(conn, conn.execute("SELECT * FROM usage").fetchall())
    for a in allocs:
        row = a["row"]
        ours = [b for b in a["bindings"] if b["ticket"] in tickets]
        seen.update(b["id"] for b in ours)
        if a["conflict"] and ours:
            c = _bucket(conflicts, (row["provider"], row["session"]),
                        {"provider": row["provider"], "session": row["session"], "ids": set()})
            c["ids"].update(b["id"] for b in a["bindings"])
            _add(c, row, 1.0)
        mine = [] if a["conflict"] else ours
        if mine:
            sessions.add((row["provider"], row["session"]))
            included.append(row)
        agent, team, role = labels.agent(row)
        for b in mine:
            key = (b["ticket"] if with_ticket else None, row["provider"], row["model"],
                   row["effort"], agent, team, role, b["basis"])
            g = _bucket(groups, key, {"partial": False, "reasoning": 0.0})
            _add(g, row, b["share"])
            g["reasoning"] += (row["reasoning"] or 0) * b["share"]
            g["partial"] = g["partial"] or labels.partial(row)
            items.append((row, b["share"], role))
    for a in allocs:
        row = a["row"]
        if (row["provider"], row["session"]) in sessions and not a["conflict"] \
                and a["unassigned_share"] > bindings.EPS:
            u = _bucket(unassigned, (row["provider"], row["session"]),
                        {"provider": row["provider"], "session": row["session"]})
            _add(u, row, a["unassigned_share"])
    return Allocation(groups, items, seen, included, list(unassigned.values()),
                      list(conflicts.values()))


def _reconcile(conn, included):
    out = []
    for session in sorted({r["session"] for r in included if r["provider"] == "codex"}):
        srow = conn.execute("SELECT provider_total_json, history_start_ordinal FROM sessions"
                            " WHERE provider = 'codex'"
                            " AND session = ? AND agent_id = ''", (session,)).fetchone()
        raw = srow[0] if srow else None
        if raw is None:
            last = conn.execute("SELECT totals_json FROM codex_counters WHERE session = ?"
                                " ORDER BY ordinal DESC LIMIT 1", (session,)).fetchone()
            raw = last[0] if last else None
        if raw is None:
            continue
        total = json.loads(raw)
        if srow and srow[0] is None and srow[1] is not None:
            baseline = conn.execute("SELECT totals_json FROM codex_counters WHERE session = ?"
                                    " AND ordinal < ? ORDER BY ordinal DESC LIMIT 1",
                                    (session, srow[1])).fetchone()
            if baseline:
                previous = json.loads(baseline[0])
                total = {k: v - previous.get(k, 0) for k, v in total.items()}
        sums = conn.execute("SELECT COALESCE(SUM(input + cache_read), 0), COALESCE(SUM(output),"
                            " 0) FROM usage WHERE provider = 'codex' AND session = ?",
                            (session,)).fetchone()
        for field, ingested in (("input_tokens", sums[0]), ("output_tokens", sums[1])):
            if total.get(field) != ingested:
                out.append({"session": session, "field": field, "provider": total.get(field),
                            "ingested": ingested})
    return out


def _rows(groups, with_ticket):
    rows = []
    for key, g in sorted(groups.items(), key=lambda kv: tuple(str(x) for x in kv[0])):
        row = dict(zip(("ticket",) + COLUMNS, key))
        if not with_ticket:
            row.pop("ticket")
        row["coverage"] = "partial" if g["partial"] else "observed"
        row.update({k: g[k] for k in bindings.TOKENS + ("reasoning",)})
        row["total"] = sum(g[k] for k in bindings.TOKENS)
        rows.append(row)
    return rows


def _unknown(conn, tickets, seen):
    rows = [b for b in conn.execute("SELECT * FROM bindings ORDER BY id")
            if b["ticket"] in tickets]
    seen_notes = {b["note"] for b in rows if b["id"] in seen}
    # An idle Codex safety net of a team run is the normal case once its sessions matched.
    idle = {b["id"] for b in rows if b["kind"] == "window" and b["provider"] == "codex"
            and (b["note"] or "").startswith(bindings.TEAM_RUN_NOTE) and b["note"] in seen_notes}
    return [{"id": b["id"], "ticket": b["ticket"], "kind": b["kind"],
             "target": b["session"] or b["turn"] or f"{b['cwd']} {b['win_from']}..{b['win_to']}"}
            for b in rows if b["id"] not in seen and b["id"] not in idle]


def build(conn, cfg, ticket, children=(), by_stage=False):
    tickets = [ticket] + list(children)
    labels = Labels(conn)
    alloc = _allocate(conn, tickets, bool(children), labels)
    rows = _rows(alloc.groups, bool(children))
    unknown = _unknown(conn, tickets, alloc.seen)
    for c in alloc.conflicts:
        c["ids"] = sorted(c["ids"])
    header = {"ticket": ticket, "children": list(children),
              "children_as_of": config.now_ts() if children else None,
              "as_of": max((r["ts"] for r in alloc.included if r["ts"]), default=None),
              "last_collect_at": store.get_meta(conn, "last_collect_at"),
              "revision": f"{_revision()} schema v{store.SCHEMA_VERSION}",
              "coverage": {c: sum(r["coverage"] == c for r in rows)
                           for c in ("observed", "partial")}}
    data = {"header": header, "rows": rows,
            "totals": {k: sum(r[k] for r in rows) for k in bindings.TOKENS + ("total",)},
            "unassigned": alloc.unassigned, "conflicts": alloc.conflicts, "unknown": unknown,
            "reconciliation": _reconcile(conn, alloc.included)}
    if by_stage:
        data["stages"] = stages.build(conn, cfg, alloc.items, data["totals"])
    return data


def nums(d):
    vals = [round(d[k]) for k in bindings.TOKENS]
    return " | ".join(str(n) for n in vals) + f" | {sum(vals)}"


def render_md(data, stable=False):
    """`stable` drops the collect and children-lookup times so re-runs render identically."""
    h = data["header"]
    as_of = f"- As of: {h['as_of']}" + ("" if stable else
                                        f" · last collect: {h['last_collect_at']}")
    out = [f"## Token usage — {h['ticket']}", "", as_of,
           f"- Revision: {h['revision']}",
           f"- Coverage: {h['coverage']['observed']} observed, {h['coverage']['partial']} partial"]
    if h["children"]:
        when = "" if stable else f" ({h['children_as_of']})"
        out.append(f"- Children{when}: {', '.join(h['children'])}")
    lead = "| Ticket " if h["children"] else ""
    out += ["", lead + "| Provider | Model | Effort | Agent | Team/Role | Basis | Coverage | "
            + TOKEN_HEADER,
            ("|---" if lead else "") + "|---|---|---|---|---|---|---|---:|---:|---:|---:|---:|"]
    for r in data["rows"]:
        team_role = f"{r['team']}/{r['role']}" if r["team"] else "-"
        cells = ([r["ticket"]] if lead else []) + [r["provider"], r["model"] or "-",
                                                   r["effort"] or "-", r["agent"], team_role,
                                                   r["basis"], r["coverage"]]
        out.append("| " + " | ".join(str(c) for c in cells) + f" | {nums(r)} |")
    pad = "| " * (7 if lead else 6)
    out.append(f"| **Total** {pad}| {nums(data['totals'])} |")
    out += _sections(data)
    if "stages" in data:
        out += _stages_md(data["stages"])
    return "\n".join(out) + "\n"


def _stages_md(data):
    out = ["", "### By stage", "", data["header"], "", "| Stage | Role | " + TOKEN_HEADER,
           "|---|---|---:|---:|---:|---:|---:|"]
    out += [f"| {r['stage']} | {r['role']} | {nums(r)} |" for r in data["rows"]]
    check = data["check"]
    out.append(f"| **Σ stages = Σ allocated** | | | | | | {round(check['stages'])} = "
               f"{round(check['allocated'])} |")
    return out


def render_unassigned_md(groups):
    out = ["| Provider | Session | Agent | First | Last | " + TOKEN_HEADER,
           "|---|---|---|---|---|---:|---:|---:|---:|---:|"]
    out += [f"| {g['provider']} | {g['session']} | {g['label'] or '-'} | {g['first_ts']} |"
            f" {g['last_ts']} | {nums(g)} |" for g in groups]
    return "\n".join(out) + "\n"


def _sections(data):
    out = ["", "### Unassigned (bound sessions)"]
    out += [f"- {u['provider']} {u['session']}: {nums(u)}" for u in data["unassigned"]] or \
        ["- none"]
    out += ["", "### Conflicts"]
    out += [f"- {c['provider']} {c['session']}: {nums(c)} — bindings "
            + ", ".join(f"#{i}" for i in c["ids"]) for c in data["conflicts"]] or ["- none"]
    out += ["", "### Unknown coverage"]
    out += [f"- #{u['id']} {u['ticket']} {u['kind']} {u['target']}: no data"
            for u in data["unknown"]] or ["- none"]
    out += ["", "### Reconciliation", "- claude: n/a (no provider counter)"]
    out += [f"- codex {m['session']} {m['field']}: provider {m['provider']} ≠ ingested"
            f" {m['ingested']}" for m in data["reconciliation"]] or ["- codex: no mismatch"]
    return out


def render_json(data):
    return json.dumps(data, indent=2, sort_keys=True, default=list) + "\n"
