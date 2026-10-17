"""SQLite store for the token-usage tool: schema, cursors, canonical usage (spec TT-813).

Python 3.9 stdlib only.
"""
import os
import sqlite3

import config

SCHEMA_VERSION = 2
COUNTERS = ("input", "cache_write", "cache_read", "output", "reasoning")
DDL = """
CREATE TABLE IF NOT EXISTS files(path TEXT PRIMARY KEY, provider TEXT, session TEXT,
  agent_id TEXT, inode INTEGER, size INTEGER, offset INTEGER, ordinal INTEGER,
  prefix_hash TEXT, skipped INTEGER DEFAULT 0, project TEXT, last_collect_at TEXT);
CREATE TABLE IF NOT EXISTS occurrences(provider TEXT, response_key TEXT, session TEXT,
  agent_id TEXT, project TEXT, source_file TEXT, line_ordinal INTEGER, byte_offset INTEGER,
  line_hash TEXT, ts TEXT, turn TEXT, model TEXT, effort TEXT, cwd TEXT, input INTEGER,
  cache_write INTEGER, cache_read INTEGER, output INTEGER, reasoning INTEGER,
  source_kind TEXT, is_copy INTEGER, owner_hint TEXT,
  UNIQUE(source_file, line_ordinal, source_kind));
CREATE INDEX IF NOT EXISTS occ_key ON occurrences(provider, response_key);
CREATE INDEX IF NOT EXISTS occ_file ON occurrences(source_file);
CREATE TABLE IF NOT EXISTS usage(provider TEXT, response_key TEXT, project TEXT, session TEXT,
  agent_id TEXT, turn TEXT, parent_session TEXT, ts TEXT, model TEXT, effort TEXT, cwd TEXT,
  input INTEGER, cache_write INTEGER, cache_read INTEGER, output INTEGER, reasoning INTEGER,
  source_kind TEXT, occurrence_count INTEGER, PRIMARY KEY(provider, response_key));
CREATE TABLE IF NOT EXISTS events(provider TEXT, project TEXT, session TEXT, agent_id TEXT,
  ts TEXT, turn TEXT, kind TEXT, name TEXT, args TEXT, tool_use_id TEXT, source_file TEXT,
  line_ordinal INTEGER, block INTEGER, UNIQUE(source_file, line_ordinal, block, kind));
CREATE TABLE IF NOT EXISTS sessions(provider TEXT, session TEXT, agent_id TEXT, project TEXT,
  agent_label TEXT, source_label TEXT, parent_session TEXT, cwd TEXT,
  history_start_ordinal INTEGER, first_ts TEXT, last_ts TEXT, coverage_reasons TEXT,
  provider_total_json TEXT, PRIMARY KEY(provider, session, agent_id));
CREATE TABLE IF NOT EXISTS subagents(session TEXT, agent_id TEXT, agent_type TEXT,
  tool_use_id TEXT, PRIMARY KEY(session, agent_id));
CREATE TABLE IF NOT EXISTS codex_turns(session TEXT, turn_id TEXT, ordinal INTEGER,
  model TEXT, effort TEXT, cwd TEXT, source_file TEXT, PRIMARY KEY(session, turn_id));
CREATE TABLE IF NOT EXISTS codex_counters(session TEXT, ordinal INTEGER, ts TEXT,
  turn_id TEXT, totals_json TEXT, source_file TEXT, PRIMARY KEY(session, ordinal));
CREATE TABLE IF NOT EXISTS bindings(id INTEGER PRIMARY KEY, ticket TEXT, provider TEXT,
  kind TEXT, session TEXT, turn TEXT, cwd TEXT, win_from TEXT, win_to TEXT, share REAL,
  basis TEXT, bound_by TEXT, bound_at TEXT, note TEXT);
CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT);
CREATE TABLE IF NOT EXISTS registrations(provider TEXT, session TEXT, source TEXT, name TEXT,
  ticket TEXT, team TEXT, role TEXT, run TEXT, attempt INTEGER, parent_session TEXT, cwd TEXT,
  at TEXT, source_file TEXT, line_ordinal INTEGER, PRIMARY KEY(provider, session, source));
CREATE TABLE IF NOT EXISTS stage_marks(session TEXT, ts TEXT, event TEXT, name TEXT,
  source TEXT, tool_use_id TEXT, source_file TEXT, line_ordinal INTEGER,
  UNIQUE(source_file, line_ordinal));
"""
DERIVED = ("first_ts", "last_ts", "coverage_reasons", "provider_total_json", "agent_label",
           "source_label", "parent_session", "history_start_ordinal")


def connect(path):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    conn = sqlite3.connect(path)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA foreign_keys=ON")
    return conn


def migrate(conn):
    version = conn.execute("PRAGMA user_version").fetchone()[0]
    if version > SCHEMA_VERSION:
        config.fail(2, f"DB schema v{version} is newer than this tool (v{SCHEMA_VERSION})")
    if version < SCHEMA_VERSION:
        conn.executescript(DDL)
        conn.execute(f"PRAGMA user_version = {SCHEMA_VERSION}")
        conn.commit()


def insert_row(conn, table, row, verb="INSERT OR IGNORE"):
    cols = ", ".join(row)
    marks = ", ".join("?" for _ in row)
    return conn.execute(f"{verb} INTO {table}({cols}) VALUES ({marks})", tuple(row.values()))


def add_occurrence(conn, row):
    return insert_row(conn, "occurrences", row).rowcount


def add_event(conn, row):
    return insert_row(conn, "events", row).rowcount


def replace_row(conn, table, row):
    return insert_row(conn, table, row, "INSERT OR REPLACE").rowcount


def upsert_session(conn, provider, session, agent_id, **fields):
    conn.execute("INSERT OR IGNORE INTO sessions(provider, session, agent_id) VALUES (?, ?, ?)",
                 (provider, session, agent_id))
    where = " WHERE provider = ? AND session = ? AND agent_id = ?"
    pk = (provider, session, agent_id)
    for name, value in fields.items():
        if value is None:
            continue
        if name == "first_ts":
            sql = "first_ts = CASE WHEN first_ts IS NULL OR ? < first_ts THEN ? ELSE first_ts END"
            args = (value, value)
        elif name == "last_ts":
            sql = "last_ts = CASE WHEN last_ts IS NULL OR ? > last_ts THEN ? ELSE last_ts END"
            args = (value, value)
        elif name == "agent_label_if_empty":
            sql, args = "agent_label = COALESCE(agent_label, ?)", (value,)
        else:
            sql, args = f"{name} = ?", (value,)
        conn.execute("UPDATE sessions SET " + sql + where, args + pk)


def _reasons(conn, provider, session, agent_id):
    row = conn.execute("SELECT coverage_reasons FROM sessions WHERE provider = ? AND session = ?"
                       " AND agent_id = ?", (provider, session, agent_id)).fetchone()
    return set(filter(None, ((row and row[0]) or "").split(",")))


def _set_reasons(conn, provider, session, agent_id, reasons):
    upsert_session(conn, provider, session, agent_id)
    conn.execute("UPDATE sessions SET coverage_reasons = ? WHERE provider = ? AND session = ?"
                 " AND agent_id = ?", (",".join(sorted(reasons)) or None, provider, session,
                                       agent_id))


def flag(conn, provider, session, agent_id, reason):
    _set_reasons(conn, provider, session, agent_id,
                 _reasons(conn, provider, session, agent_id) | {reason})


def clear_flag(conn, provider, session, agent_id, reason):
    _set_reasons(conn, provider, session, agent_id,
                 _reasons(conn, provider, session, agent_id) - {reason})


def delete_file_rows(conn, path):
    keys = {(r[0], r[1]) for r in conn.execute(
        "SELECT DISTINCT provider, response_key FROM occurrences WHERE source_file = ?", (path,))}
    for table in ("occurrences", "events", "codex_turns", "codex_counters", "registrations",
                  "stage_marks"):
        conn.execute(f"DELETE FROM {table} WHERE source_file = ?", (path,))
    row = conn.execute("SELECT provider, session, agent_id FROM files WHERE path = ?",
                       (path,)).fetchone()
    if row and row["session"]:
        # Every file feeds exactly one session row, and the re-read re-derives these fields.
        sets = ", ".join(f"{name} = NULL" for name in DERIVED)
        conn.execute(f"UPDATE sessions SET {sets} WHERE provider = ? AND session = ?"
                     " AND agent_id = ?", (row["provider"], row["session"], row["agent_id"] or ""))
    return keys


def set_file_session(conn, path, session, agent_id=""):
    conn.execute("UPDATE files SET session = ?, agent_id = ? WHERE path = ?",
                 (session, agent_id, path))


def set_meta(conn, key, value):
    conn.execute("INSERT OR REPLACE INTO meta(key, value) VALUES (?, ?)", (key, value))


def get_meta(conn, key):
    row = conn.execute("SELECT value FROM meta WHERE key = ?", (key,)).fetchone()
    return row[0] if row else None


def _occurrences(conn, provider, key):
    return conn.execute(
        "SELECT o.*, s.first_ts AS session_first FROM occurrences o LEFT JOIN sessions s"
        " ON s.provider = o.provider AND s.session = o.session AND s.agent_id = o.agent_id"
        " WHERE o.provider = ? AND o.response_key = ?", (provider, key)).fetchall()


def _resolve_owner(occ):
    """Return the provenance-based owner and whether competing sessions remain unresolved."""
    def earliest(rows):
        return min(rows, key=lambda o: (o["session_first"] or "~", o["session"], o["agent_id"]))
    hints = {o["owner_hint"] for o in occ if o["owner_hint"]}
    hinted = [o for o in occ if o["session"] in hints]
    if hinted:
        return earliest([o for o in hinted if not o["is_copy"]] or hinted), False
    candidates = [o for o in occ if not o["is_copy"]] or occ
    return earliest(candidates), len({o["session"] for o in candidates}) > 1


def _turn(conn, session, turn):
    return conn.execute("SELECT model, effort, cwd FROM codex_turns WHERE session = ?"
                        " AND turn_id = ?", (session, turn)).fetchone()


def _canonical(conn, occ, owner):
    best = max(occ, key=lambda o: (o["output"] or 0, o["ts"] or "", o["source_file"],
                                   o["line_ordinal"]))
    model, effort, cwd = best["model"], best["effort"], best["cwd"]
    if best["provider"] == "codex":
        turn = _turn(conn, owner["session"], best["turn"]) or _turn(conn, best["session"],
                                                                    best["turn"])
        if turn:
            model, effort, cwd = model or turn[0], effort or turn[1], turn[2] or cwd
    parent = conn.execute("SELECT parent_session FROM sessions WHERE provider = ? AND"
                          " session = ? AND agent_id = ''",
                          (owner["provider"], owner["session"])).fetchone()
    row = {"provider": best["provider"], "response_key": best["response_key"],
           "project": owner["project"], "session": owner["session"],
           "agent_id": owner["agent_id"], "turn": best["turn"],
           "parent_session": parent[0] if parent else None, "ts": best["ts"], "model": model,
           "effort": effort, "cwd": cwd, "source_kind": best["source_kind"],
           "occurrence_count": len(occ)}
    row.update({c: best[c] or 0 for c in COUNTERS})
    return row


def recompute(conn, keys):
    for provider, key in sorted(keys):
        occ = _occurrences(conn, provider, key)
        if not occ:
            conn.execute("DELETE FROM usage WHERE provider = ? AND response_key = ?",
                         (provider, key))
            continue
        owner, _ = _resolve_owner(occ)
        replace_row(conn, "usage", _canonical(conn, occ, owner))
    _refresh_ambiguity(conn)


def _refresh_ambiguity(conn):
    ambiguous = set()
    keys = conn.execute("SELECT provider, response_key FROM occurrences GROUP BY provider,"
                        " response_key HAVING COUNT(DISTINCT session) > 1").fetchall()
    for provider, key in keys:
        occ = _occurrences(conn, provider, key)
        owner, is_ambiguous = _resolve_owner(occ)
        if is_ambiguous:
            ambiguous.add((provider, owner["session"], owner["agent_id"]))
    flagged = {tuple(r) for r in conn.execute(
        "SELECT provider, session, agent_id FROM sessions WHERE coverage_reasons"
        " LIKE '%ambiguous-owner%'")}
    for pk in flagged - ambiguous:
        clear_flag(conn, *pk, "ambiguous-owner")
    for pk in ambiguous - flagged:
        flag(conn, *pk, "ambiguous-owner")
