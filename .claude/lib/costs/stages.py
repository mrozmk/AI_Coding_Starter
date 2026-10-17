"""Per-pipeline-stage split of allocated usage (spec TT-813, runtime markers TT-821).

Python 3.9 stdlib only.
"""
import collections
import math

import bindings

OUTSIDE = "outside-stage"
CODEX = "codex"
Context = collections.namedtuple("Context", "starts spawns links timelines first")


def stage_at(starts, ts, turn=None):
    """Last start before `ts`; the response that emits a stage call stays in the previous stage."""
    name = OUTSIDE
    for start in starts:
        if ts and start["ts"] < ts and not (turn is not None and start["turn"] == turn):
            name = start["name"]
    return name


def _starts(conn, skills):
    starts = collections.defaultdict(list)
    for ev in conn.execute("SELECT session, ts, turn, name FROM events WHERE provider = 'claude'"
                           " AND agent_id = '' AND kind IN ('skill', 'command') AND ts IS NOT"
                           " NULL ORDER BY ts, line_ordinal"):
        if ev["name"] in skills:
            starts[ev["session"]].append({"ts": ev["ts"], "turn": ev["turn"], "name": ev["name"]})
    return starts


def _replay(marks, turns):
    """Stack replay of one session's marks → (timeline in `_starts` shape, counts)."""
    stack, timeline, inferred, unmatched = [], [], 0, 0
    for mark in marks:
        name = mark["name"]
        if mark["event"] == "start":
            if name in stack:
                at = stack.index(name)
                inferred += len(stack) - at
                del stack[at:]
            stack.append(name)
        elif name in stack:
            at = stack.index(name)
            inferred += len(stack) - at - 1
            del stack[at:]
        else:
            # A stray end is no evidence of marker coverage, so it adds no timeline entry.
            unmatched += 1
            continue
        timeline.append({"ts": mark["ts"], "turn": turns.get(mark["tool_use_id"]),
                         "name": stack[-1] if stack else OUTSIDE})
    # Stages still open run to the session's last row on an inferred boundary.
    return timeline, {"inferred": inferred + len(stack), "unmatched": unmatched}


def _mark_timeline(conn, skills):
    """({session: timeline} for sessions with ≥1 applied mark, {session: counts})."""
    sub_ids = {r[0] for r in conn.execute(
        "SELECT tool_use_id FROM events WHERE provider = 'claude' AND kind IN ('skill',"
        " 'stage_end') AND agent_id != '' AND tool_use_id IS NOT NULL")}
    turns = {r[0]: r[1] for r in conn.execute(
        "SELECT tool_use_id, turn FROM events WHERE provider = 'claude' AND kind IN ('skill',"
        " 'stage_end') AND agent_id = '' AND tool_use_id IS NOT NULL")}
    marks = collections.defaultdict(list)
    for mark in conn.execute("SELECT session, ts, event, name, tool_use_id FROM stage_marks"
                             " ORDER BY session, ts, line_ordinal"):
        if mark["name"] in skills and mark["tool_use_id"] not in sub_ids:
            marks[mark["session"]].append(mark)
    timelines, counts = {}, {}
    for session, session_marks in marks.items():
        timeline, counts[session] = _replay(session_marks, turns)
        if timeline:
            timelines[session] = timeline
    return timelines, counts


def _context(conn, skills):
    spawns = {(e[0], e[1]): (e[2], e[3]) for e in conn.execute(
        "SELECT session, tool_use_id, ts, turn FROM events WHERE provider = 'claude'"
        " AND kind = 'agent_spawn' AND tool_use_id IS NOT NULL")}
    links = {(s[0], s[1]): s[2] for s in conn.execute(
        "SELECT session, agent_id, tool_use_id FROM subagents")}
    first = {(s[0], s[1]): s[2] for s in conn.execute(
        "SELECT session, agent_id, first_ts FROM sessions WHERE provider = 'claude'"
        " AND agent_id != ''")}
    timelines, counts = _mark_timeline(conn, skills)
    return Context(_starts(conn, skills), spawns, links, timelines, first), counts


def _stage_in(ctx, session, ts, turn):
    return stage_at(ctx.timelines.get(session) or ctx.starts.get(session, []), ts, turn)


def _stage(row, ctx):
    if row["provider"] == "codex":
        return CODEX
    session = row["session"]
    if not row["agent_id"]:
        return _stage_in(ctx, session, row["ts"], row["turn"])
    spawn = ctx.spawns.get((session, ctx.links.get((session, row["agent_id"]))))
    if spawn:
        return _stage_in(ctx, session, spawn[0], spawn[1])
    # Workflow sub-agents carry no spawn link; their first row says when they ran.
    first = ctx.first.get((session, row["agent_id"]))
    return _stage_in(ctx, session, first, None) if first else OUTSIDE


def _header(ctx, counts, items):
    # Only this report's sessions: stage_marks spans every ticket and project.
    sessions = {row["session"] for row, _, _ in items if row["provider"] == "claude"}
    marked = len(sessions & set(ctx.timelines))
    inferred = sum(counts[s]["inferred"] for s in sessions if s in counts)
    unmatched = sum(counts[s]["unmatched"] for s in sessions if s in counts)
    return (f"Stages: runtime markers for {marked} sessions, transcript approximation for"
            f" {len(sessions) - marked}; inferred ends {inferred}, unmatched ends {unmatched}.")


def build(conn, cfg, items, totals):
    """`items` = [(usage row, share, role)] → stage × role rows and the Σ check."""
    ctx, counts = _context(conn, set(cfg["stage_skills"]))
    order = list(cfg["stage_skills"]) + [OUTSIDE, CODEX]
    groups = {}
    for row, share, role in items:
        g = groups.setdefault((_stage(row, ctx), role or "-"),
                              dict.fromkeys(bindings.TOKENS, 0.0))
        for k, v in bindings.tokens(row, share).items():
            g[k] += v
    rows = [dict(stage=s, role=r, **c) for (s, r), c in
            sorted(groups.items(), key=lambda kv: (order.index(kv[0][0])
                                                   if kv[0][0] in order else len(order), kv[0]))]
    staged = sum(sum(r[k] for k in bindings.TOKENS) for r in rows)
    allocated = totals["total"]
    for k in bindings.TOKENS:
        actual = sum(r[k] for r in rows)
        assert math.isclose(actual, totals[k], rel_tol=1e-12, abs_tol=1e-9), \
            f"stages {k} {actual} != allocated {totals[k]}"
    # A mismatch means a row was dropped or counted twice — a bug, never a data condition.
    assert math.isclose(staged, allocated, rel_tol=1e-12, abs_tol=1e-9), \
        f"stages {staged} != allocated {allocated}"
    return {"header": _header(ctx, counts, items), "rows": rows,
            "check": {"stages": staged, "allocated": allocated}}
