"""Ticket bindings: validation, team-run windows, allocation, unassigned usage (spec TT-813).

Python 3.9 stdlib only.
"""
import glob
import json
import os
import re
import sys
from datetime import datetime

import config
import runtime
import store

RUN_TS_RE = re.compile(r"(\d{8}-\d{6})$")
RECORD_RE = re.compile(r"^[a-z]+-\d+-\d+\.json$")
EPS = 1e-9
PROVIDERS = ("claude", "codex")
TOKENS = ("input", "cache_write", "cache_read", "output")
LINEAGE_DEPTH = 5
TEAM_RUN_NOTE = "team-run "


def _in_partition(binding, provider):
    return binding["provider"] in (None, provider)


def _load(group):
    """(Σ share, ids) of one binding group."""
    return sum(b["share"] for b in group), [b["id"] for b in group]


def _heaviest(groups):
    """(Σ share, ids) of the heaviest binding group; (0.0, []) when there is none."""
    return max((_load(g) for g in groups), key=lambda load: load[0], default=(0.0, []))


def lineage_parents(conn):
    parents = {(r[0], r[1]): r[2] for r in conn.execute(
        "SELECT provider, session, parent_session FROM sessions WHERE agent_id = ''")}
    # Not setdefault: a collected top-level rollout already holds the key with a NULL parent.
    for thread, parent in runtime.codex_parents(conn).items():
        if not parents.get(("codex", thread)):
            parents[("codex", thread)] = parent
    return parents


def _matches(binding, row, parents):
    if not _in_partition(binding, row["provider"]):
        return False
    if binding["kind"] == "session":
        return binding["session"] in ancestors(parents, row["provider"], row["session"])
    if binding["kind"] == "turn":
        return binding["turn"] in (row["turn"], row["response_key"])
    return (config.under(row["cwd"], binding["cwd"]) and bool(row["ts"])
            and binding["win_from"] <= row["ts"] < binding["win_to"])


def _selected(binds, row, parents):
    matched = [b for b in binds if _matches(b, row, parents)]
    explicit = [b for b in matched if b["kind"] != "window"]
    return explicit or matched


def _probes(conn, binds, target, part):
    yield from conn.execute("SELECT * FROM usage WHERE provider = ?", (part,))
    blank = {"provider": part, "session": None, "turn": None, "response_key": None,
             "cwd": None, "ts": None}
    if target["kind"] == "session":
        sessions = {b["session"] for b in binds if b["kind"] == "session"}
        sessions |= {r[0] for r in conn.execute(
            "SELECT session FROM sessions WHERE provider = ?", (part,))}
        for session in sessions:
            yield dict(blank, session=session)
    elif target["kind"] == "turn":
        yield dict(blank, turn=target["turn"], response_key=target["turn"])
    else:
        windows = [b for b in binds if b["kind"] == "window" and _in_partition(b, part)]
        dirs = {target["cwd"]} | {b["cwd"] for b in windows
                                  if config.under(b["cwd"], target["cwd"])}
        times = {target["win_from"]} | {b["win_from"] for b in windows
                                        if target["win_from"] <= b["win_from"] < target["win_to"]}
        for cwd in dirs:
            for ts in times:
                yield dict(blank, cwd=cwd, ts=ts)


def _check_overlap(conn, target, share, provider):
    binds = list(conn.execute("SELECT * FROM bindings ORDER BY id"))
    candidate = dict(target, share=share, provider=provider, id=None)
    binds.append(candidate)
    parents = lineage_parents(conn)
    for part in (PROVIDERS if provider is None else (provider,)):
        groups = (_selected(binds, row, parents)
                  for row in _probes(conn, binds, candidate, part))
        load, ids = _heaviest([b for b in group if b is not candidate]
                             for group in groups if candidate in group)
        if load + share > 1 + EPS:
            config.fail(3, f"binding refused: {part} share would reach {load + share:.3f} > 1"
                           f" with binding(s) {', '.join('#' + str(i) for i in ids)}")


def _target(cfg, session, turn, window, cwd):
    if sum(x is not None for x in (session, turn, window)) != 1:
        config.fail(2, "bind needs exactly one of --session, --turn, --window, --team-run")
    if window is None:
        if cwd is not None:
            config.fail(2, "--cwd only goes with --window")
        return {"kind": "session" if session is not None else "turn", "session": session,
                "turn": turn}
    if cwd is None:
        config.fail(2, "--window needs --cwd")
    try:
        win_from, win_to = config.norm_ts(window[0]), config.norm_ts(window[1])
    except ValueError as err:
        config.fail(2, str(err))
    if win_from >= win_to:
        config.fail(3, f"binding refused: window {win_from} is not before {win_to}")
    return {"kind": "window", "cwd": config.resolve_cwd(cfg, cwd), "win_from": win_from,
            "win_to": win_to}


def _close_open_run(conn, cwd, at):
    """A newer team run ends the clone's open-ended run window at its own start."""
    conn.execute("UPDATE bindings SET win_to = ? WHERE kind = 'window' AND cwd = ? AND"
                 " win_to = ? AND win_from < ? AND note LIKE ?",
                 (at, cwd, config.OPEN_END, at, TEAM_RUN_NOTE + "%"))


def add_binding(conn, cfg, ticket, *, session=None, turn=None, window=None, cwd=None,
                share=1.0, provider=None, note=None, team_run=None, commit=True):
    if not config.TICKET_RE.match(ticket or ""):
        config.fail(3, f"binding refused: {ticket!r} is not a ticket key like TT-805")
    if not 0 < share <= 1:
        config.fail(3, f"binding refused: share {share} must be in (0, 1]")
    target = _target(cfg, session, turn, window, cwd)
    if team_run:
        note = TEAM_RUN_NOTE + team_run + (f" — {note}" if note else "")
        if target["kind"] == "window":
            _close_open_run(conn, target["cwd"], target["win_from"])
    try:
        _check_overlap(conn, target, share, provider)
    except SystemExit:
        conn.rollback()
        raise
    if share < 1:
        basis = "manual-share"
    else:
        basis = "inferred-window" if target["kind"] == "window" else "explicit"
    row = dict(target, ticket=ticket, provider=provider, share=share, basis=basis,
               bound_by=os.environ.get("USER"), bound_at=config.now_ts(), note=note)
    bid = store.insert_row(conn, "bindings", row, "INSERT").lastrowid
    if commit:
        conn.commit()
    return bid, basis


def _run_start(run_id):
    m = RUN_TS_RE.search(run_id)
    try:
        stamp = datetime.strptime(m.group(1), "%Y%m%d-%H%M%S") if m else None
    except ValueError:
        return None
    return config.norm_ts(stamp.strftime("%Y-%m-%dT%H:%M:%SZ")) if stamp else None


def team_run_window(clone_dir, run_id):
    clone = os.path.normpath(os.path.expanduser(clone_dir))
    team = os.path.join(clone, ".agents", "team")
    run_dirs = glob.glob(os.path.join(team, "runs", "*")) + \
        glob.glob(os.path.join(team, "archive", "*", "runs", "*"))
    matches = [d for d in run_dirs if os.path.basename(d) == run_id and os.path.isdir(d)]
    start = _run_start(run_id)
    if len(matches) != 1 or start is None:
        config.fail(2, f"run {run_id} not found (or ambiguous) under {team}")
    tickets = []
    for path in sorted(glob.glob(os.path.join(matches[0], "*.json"))):
        if RECORD_RE.match(os.path.basename(path)):
            try:
                with open(path, encoding="utf-8") as fh:
                    tickets.append(json.load(fh).get("ticket"))
            except (OSError, json.JSONDecodeError, AttributeError):
                continue
    if not tickets:
        config.fail(2, f"{matches[0]} holds no run record — not a team run")
    later = [s for s in (_run_start(os.path.basename(d)) for d in run_dirs) if s and s > start]
    return start, min(later) if later else config.OPEN_END, clone, tickets[0], matches[0]


def team_run_sessions(run_dir):
    """(sorted role session uuids, None) for a complete run, else ([], why not)."""
    keys = sorted(os.path.basename(p)[:-len(".prompt.md")]
                  for p in glob.glob(os.path.join(run_dir, "*.prompt.md")))
    if not keys:
        return [], "no session files"
    sessions = set()
    for key in keys:
        try:
            with open(os.path.join(run_dir, key + ".session"), encoding="utf-8") as fh:
                sid = fh.read().strip().lower()
        except OSError:
            sid = ""
        if not runtime.UUID_RE.match(sid):
            return [], f"{key} has no session file"
        sessions.add(sid)
    return sorted(sessions), None


def bind_team_run(conn, cfg, ticket, clone_dir, run_id, note=None):
    """Explicit role-session bindings plus a Codex-only run window; the run window otherwise.

    Returns ([(id, kind, provider, basis)], run ticket). Nothing is committed unless every
    binding of the batch passes the overlap check (add_binding rolls back on refusal).
    """
    start, end, clone, run_ticket, run_dir = team_run_window(clone_dir, run_id)
    sessions, reason = team_run_sessions(run_dir)
    if not sessions:
        print(f"cost: team-run {run_id}: {reason} — using the run window", file=sys.stderr)
        bid, basis = add_binding(conn, cfg, ticket, window=(start, end), cwd=clone,
                                 team_run=run_id, note=note)
        return [(bid, "window", None, basis)], run_ticket
    _close_open_run(conn, clone, start)
    created = []
    for sid in sessions:
        bid, basis = add_binding(conn, cfg, ticket, session=sid, team_run=run_id, note=note,
                                 commit=False)
        created.append((bid, "session", None, basis))
    # Safety net for Codex threads with no registered parent (older clone, lost registration).
    bid, basis = add_binding(conn, cfg, ticket, window=(start, end), cwd=clone,
                             provider="codex", team_run=run_id, note=note, commit=False)
    created.append((bid, "window", "codex", basis))
    conn.commit()
    return created, run_ticket


def ancestors(parents, provider, session):
    chain = [session]
    for _ in range(LINEAGE_DEPTH):
        parent = parents.get((provider, chain[-1]))
        if not parent or parent in chain:
            break
        chain.append(parent)
    return chain


def allocate(conn, rows):
    binds = conn.execute("SELECT * FROM bindings ORDER BY id").fetchall()
    parents = lineage_parents(conn)
    out = []
    for row in rows:
        chosen = _selected(binds, row, parents)
        total = sum(b["share"] for b in chosen)
        conflict = total > 1 + EPS
        out.append({"row": row, "conflict": conflict, "bindings": chosen,
                    "unassigned_share": 1.0 if conflict else max(1.0 - total, 0.0)})
    return out


def tokens(row, share=1.0):
    return {k: (row[k] or 0) * share for k in TOKENS}


def unassigned(conn, since, project=None):
    sql, args = "SELECT * FROM usage WHERE ts >= ?", [since]
    if project:
        sql, args = sql + " AND project = ?", args + [project]
    labels = {(r[0], r[1]): r[2] or r[3] for r in conn.execute(
        "SELECT provider, session, agent_label, source_label FROM sessions WHERE agent_id = ''")}
    groups = {}
    for alloc in allocate(conn, conn.execute(sql, args).fetchall()):
        row = alloc["row"]
        if alloc["unassigned_share"] <= EPS:
            continue
        key = (row["provider"], row["session"])
        g = groups.setdefault(key, {"provider": key[0], "session": key[1],
                                    "label": labels.get(key), "first_ts": row["ts"],
                                    "last_ts": row["ts"], **{k: 0.0 for k in TOKENS}})
        g["first_ts"], g["last_ts"] = min(g["first_ts"], row["ts"]), max(g["last_ts"], row["ts"])
        for k, v in tokens(row, alloc["unassigned_share"]).items():
            g[k] += v
    return sorted(groups.values(), key=lambda g: -sum(g[k] for k in TOKENS))
