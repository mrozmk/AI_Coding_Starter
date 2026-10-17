"""Incremental JSONL reader with a prefix-hash cursor (spec TT-813).

Python 3.9 stdlib only.
"""
import collections
import hashlib
import json
import os

import config
import store

CHUNK = 1 << 20
Read = collections.namedtuple("Read", "lines reset reset_keys pending_partial start")


def as_int(value):
    return value if isinstance(value, int) and not isinstance(value, bool) else 0


def has_counts(usage, *fields):
    """True when every named counter is an int; a usage missing one is partial, never 0."""
    return isinstance(usage, dict) and all(
        isinstance(usage.get(f), int) and not isinstance(usage.get(f), bool) for f in fields)


def _hash_prefix(path, offset):
    hasher = hashlib.sha256()
    remaining = offset
    with open(path, "rb") as fh:
        while remaining > 0:
            chunk = fh.read(min(CHUNK, remaining))
            if not chunk:
                break
            hasher.update(chunk)
            remaining -= len(chunk)
    return hasher


def _resume_point(conn, path, st):
    """(offset, ordinal, hasher, reset, reset_keys) — resume only on an unchanged prefix."""
    cur = conn.execute("SELECT inode, offset, ordinal, prefix_hash FROM files WHERE path = ?",
                       (path,)).fetchone()
    if cur is None:
        return 0, 0, hashlib.sha256(), False, set()
    if cur["inode"] == st.st_ino and st.st_size >= (cur["offset"] or 0):
        # Hashed every run by design: a rewrite anywhere in the consumed prefix must be caught.
        hasher = _hash_prefix(path, cur["offset"] or 0)
        if hasher.hexdigest() == cur["prefix_hash"]:
            return cur["offset"] or 0, cur["ordinal"] or 0, hasher, False, set()
    return 0, 0, hashlib.sha256(), True, store.delete_file_rows(conn, path)


def read_new(conn, path, provider, session=None, agent_id=None, project=None):
    st = os.stat(path)
    offset, ordinal, hasher, reset, reset_keys = _resume_point(conn, path, st)
    start = offset
    with open(path, "rb") as fh:
        fh.seek(offset)
        data = fh.read(max(st.st_size - offset, 0))
    parts = data.split(b"\n")
    fragment = parts.pop()
    lines = []
    for raw in parts:
        if raw.strip():
            lines.append((ordinal, offset, raw))
        hasher.update(raw + b"\n")
        offset += len(raw) + 1
        ordinal += 1
    conn.execute(
        "INSERT INTO files(path, provider, session, agent_id, inode, size, offset, ordinal,"
        " prefix_hash, skipped, project, last_collect_at) VALUES (?,?,?,?,?,?,?,?,?,0,?,?)"
        " ON CONFLICT(path) DO UPDATE SET provider = excluded.provider,"
        " session = COALESCE(excluded.session, files.session),"
        " agent_id = COALESCE(excluded.agent_id, files.agent_id), inode = excluded.inode,"
        " size = excluded.size, offset = excluded.offset, ordinal = excluded.ordinal,"
        " prefix_hash = excluded.prefix_hash, skipped = 0,"
        " project = COALESCE(excluded.project, files.project),"
        " last_collect_at = excluded.last_collect_at",
        (path, provider, session, agent_id, st.st_ino, st.st_size, offset, ordinal,
         hasher.hexdigest(), project, config.now_ts()))
    return Read(lines, reset, reset_keys, bool(fragment.strip()), start)


def parse(raw):
    try:
        rec = json.loads(raw)
    except (json.JSONDecodeError, UnicodeDecodeError):
        return None
    return rec if isinstance(rec, dict) else None
