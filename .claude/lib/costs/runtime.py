"""Runtime log (`runtime.jsonl`) → registrations, stage marks; lookups (spec TT-821).

Python 3.9 stdlib only.
"""
import os
import re

import config
import reader
import store

UUID_RE = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")
NAME_RE = re.compile(r"^[A-Za-z0-9._:-]{1,64}$")
RUN_RE = re.compile(r"^[a-z0-9]+-[0-9]{8}-[0-9]{6}$")
TOOL_USE_RE = re.compile(r"^[A-Za-z0-9_]{1,128}$")
SOURCES = ("team-run", "start-team", "mail-tt", "codex-bg")
MARK_SOURCES = ("hook-skill", "hook-prompt", "skill-end")
PROVIDERS = ("claude", "codex")


def _str(rec, key, regex):
    """The field when it is a string matching `regex`, else None."""
    value = rec.get(key)
    return value if isinstance(value, str) and regex.match(value) else None


def _session_row(rec, at):
    if rec.get("provider") not in PROVIDERS or rec.get("source") not in SOURCES:
        return None
    attempt = rec.get("attempt")
    return {"provider": rec["provider"], "session": rec["session"], "source": rec["source"],
            "name": _str(rec, "name", NAME_RE), "ticket": _str(rec, "ticket", config.TICKET_RE),
            "team": _str(rec, "team", NAME_RE), "role": _str(rec, "role", NAME_RE),
            "run": _str(rec, "run", RUN_RE),
            "attempt": attempt if isinstance(attempt, int) and not isinstance(attempt, bool)
            else None,
            "parent_session": _str(rec, "parent_session", UUID_RE),
            "cwd": rec["cwd"] if isinstance(rec.get("cwd"), str) and rec["cwd"].startswith("/")
            else None, "at": at}


def _mark_row(rec, at):
    if rec.get("event") not in ("start", "end") or rec.get("source") not in MARK_SOURCES:
        return None
    name = _str(rec, "name", NAME_RE)
    if name is None:
        return None
    return {"session": rec["session"], "ts": at, "event": rec["event"], "name": name,
            "source": rec["source"], "tool_use_id": _str(rec, "tool_use_id", TOOL_USE_RE)}


def _row(rec):
    """(table, row) for a valid line, else None — the log may be hand-edited."""
    at = config.safe_ts(rec.get("at"))
    if rec.get("v") != 1 or at is None or _str(rec, "session", UUID_RE) is None:
        return None
    if rec.get("type") == "session":
        row = _session_row(rec, at)
        return ("registrations", row) if row else None
    if rec.get("type") == "stage":
        row = _mark_row(rec, at)
        return ("stage_marks", row) if row else None
    return None


def ingest(conn):
    """Consume new runtime lines; returns the count of lines read. The caller commits."""
    path = config.runtime_path()
    if not os.path.exists(path):
        return 0
    result = reader.read_new(conn, path, "runtime")
    for ordinal, _, raw in result.lines:
        rec = reader.parse(raw)
        parsed = _row(rec) if rec is not None else None
        if parsed is None:
            continue
        table, row = parsed
        row.update(source_file=path, line_ordinal=ordinal)
        if table == "registrations":
            store.replace_row(conn, table, row)
        else:
            store.insert_row(conn, table, row)
    return len(result.lines)


def resolve_name(conn, value):
    """A session uuid, or the one Claude session registered under `value`."""
    if UUID_RE.match(value or ""):
        return value
    rows = conn.execute("SELECT session, source, at FROM registrations WHERE provider = 'claude'"
                        " AND name = ? ORDER BY at", (value,)).fetchall()
    sessions = {r["session"] for r in rows}
    if len(sessions) == 1:
        return rows[0]["session"]
    if not sessions:
        config.fail(2, f"no registered session named {value}")
    listing = "\n".join(f"  {r['session']}  {r['source']}  {r['at']}" for r in rows)
    config.fail(2, f"{value} names {len(sessions)} sessions — pass a uuid:\n{listing}")


def team_roles(conn):
    return {r[0]: (r[1], r[2]) for r in conn.execute(
        "SELECT session, team, role FROM registrations WHERE source = 'team-run'"
        " AND provider = 'claude'")}


def names(conn):
    return {r[0]: r[1] for r in conn.execute(
        "SELECT session, name FROM registrations WHERE provider = 'claude' AND name IS NOT NULL"
        " ORDER BY at")}


def codex_parents(conn):
    return {r[0]: r[1] for r in conn.execute(
        "SELECT session, parent_session FROM registrations WHERE provider = 'codex'"
        " AND parent_session IS NOT NULL ORDER BY at")}
