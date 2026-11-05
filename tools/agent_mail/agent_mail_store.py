# Vendored from mrozmk/jarvis@c9c407c (tools/agent_mail/) — MIT, same terms and holder as LICENSE.
# Local delta and the re-sync procedure: tools/agent_mail/README.md → "Vendored copy".
"""
SQLite-backed mailbox for agent-to-agent messages (agent-mail channel, Step 1 core).

Replaces the append-only `mail.md` convention with a transactional store that can
answer the only question a wake-up adapter really needs: "is there a message this
recipient must act on right now?".

Design notes that are easy to get wrong later:

  * Delivery is a per-recipient state machine, not a flag on the message:
    ``pending -> delivered -> received -> processed | failed``. Transitions are
    monotonic and compare-and-set (`_transition`), so a late adapter callback can
    never downgrade a terminal state back to `delivered`.
  * `delivered` is a LEASE, not a consumption: it only protects the window between
    "wake-up line was emitted" and "the recipient's turn actually started". A turn
    that dies before `received` gets the message again after `redeliver_after`
    seconds, with a higher `attempt` — at-least-once, deduplicated by message id.
  * `received` is the recipient's CLAIM (`inbox --unread --ack` at the top of a
    turn): it stops redelivery but still counts as in-flight for the "one active
    handling per (recipient, thread)" rule, until the closing `ack` marks it
    `processed`.
  * Attempts are RESERVED before the attempt is made (`attempts + 1` and an
    `attempt_log` row with `ok IS NULL` in the same transaction), so a crash
    between the adapter call and the result write cannot lose an attempt. Rows
    with `ok IS NULL` count towards the limits exactly like finished ones.

Python 3.9 / stdlib only (runs on the system interpreter, not `.venv-research`).
"""

import fcntl
import json
import logging
import os
import re
import sqlite3
import time
from datetime import datetime, timezone
from typing import Any, Dict, List, Optional, Tuple

log = logging.getLogger(__name__)

_DIR = os.path.dirname(os.path.abspath(__file__))
_REPO = os.path.abspath(os.path.join(_DIR, "..", ".."))
DEFAULT_BOX = os.path.join(_REPO, ".agents", "agent-mail", "mail.sqlite")

KINDS = ("turn", "info", "ack", "report")
WAKE_KINDS = ("turn", "report")
DELIVERY_STATES = ("pending", "delivered", "received", "processed", "failed")
TERMINAL_STATES = ("processed", "failed")
OPEN_STATES = ("pending", "delivered", "received")

# Identifiers that end up on the single-line wake-up signal (Step 3): no spaces,
# no control characters, no leading '-' (would look like a CLI flag).
IDENT_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$")
# Imported history (`initial_state='processed'`) never reaches the signal, so the
# historical spellings are accepted there: spaces ("Wykonawca K5") and a
# parenthetical role ("Codex (wykonawca P07)"), both real in `mail.md`.
LEGACY_IDENT_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9 _.()-]{0,63}$")

MAX_ATTEMPTS = 5
DEFAULT_REDELIVER_AFTER = 600.0
DEFAULT_CLAIM_TIMEOUT = 7200.0
DEFAULT_MAX_PER_HOUR = 30
DEFAULT_POLL = 2.0

# Actors whose attempts are charged against the hourly wake-up budget. `requeue`
# is an explicit human/agent command, not a wake-up attempt, so it is excluded.
RATE_LIMITED_ACTORS = ("wait", "deliver")


class ConflictError(Exception):
    """Optimistic-lock failure on the shared `state` row."""

    def __init__(self, current_version):
        super(ConflictError, self).__init__(
            "state version conflict: current_version=%s" % (current_version,))
        self.current_version = current_version


# ---------------------------------------------------------------------------
# time
# ---------------------------------------------------------------------------

_TS_FMT = "%Y-%m-%dT%H:%M:%SZ"
# Lease / claim / rate-limit windows are sub-second in tests and second-resolution
# would round them away, so those columns carry microseconds. The format is fixed
# width, which keeps lexicographic ordering identical to chronological ordering.
_TS_US_FMT = "%Y-%m-%dT%H:%M:%S.%fZ"


def now_utc() -> str:
    """Display timestamp, second resolution (`messages.ts_utc`, `updated_utc`)."""
    return datetime.now(timezone.utc).strftime(_TS_FMT)


def now_ts() -> str:
    """Lease timestamp, microsecond resolution (`delivered_utc`, `attempt_log`)."""
    return datetime.now(timezone.utc).strftime(_TS_US_FMT)


def _ts_ago(seconds) -> str:
    """Microsecond timestamp `seconds` in the past — a cutoff for string compare."""
    return datetime.fromtimestamp(time.time() - float(seconds), timezone.utc).strftime(_TS_US_FMT)


# ---------------------------------------------------------------------------
# schema
# ---------------------------------------------------------------------------

SCHEMA = """
CREATE TABLE IF NOT EXISTS messages(
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  ts_utc TEXT NOT NULL,
  project TEXT NOT NULL DEFAULT 'Jarvis',
  thread TEXT,
  sender TEXT NOT NULL,
  recipients TEXT NOT NULL,
  kind TEXT NOT NULL CHECK(kind IN ('turn','info','ack','report')),
  awaiting TEXT,
  reply_to INTEGER REFERENCES messages(id),
  refs TEXT NOT NULL DEFAULT '[]',
  body TEXT NOT NULL,
  legacy_id INTEGER,
  legacy_ts TEXT,
  legacy_awaiting TEXT,
  dedup_key TEXT UNIQUE
);
CREATE TABLE IF NOT EXISTS delivery(
  message_id INTEGER NOT NULL REFERENCES messages(id),
  recipient TEXT NOT NULL,
  state TEXT NOT NULL CHECK(state IN ('pending','delivered','received','processed','failed')),
  updated_utc TEXT NOT NULL,
  delivered_utc TEXT,
  received_utc TEXT,
  attempts INTEGER NOT NULL DEFAULT 0,
  note TEXT,
  PRIMARY KEY(message_id, recipient)
);
CREATE INDEX IF NOT EXISTS ix_delivery_rs ON delivery(recipient, state);
CREATE TABLE IF NOT EXISTS attempt_log(
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  message_id INTEGER NOT NULL,
  recipient TEXT NOT NULL,
  ts_utc TEXT NOT NULL,
  actor TEXT NOT NULL,
  ok INTEGER,
  note TEXT
);
CREATE INDEX IF NOT EXISTS ix_attempt_rt ON attempt_log(recipient, ts_utc);
CREATE TABLE IF NOT EXISTS state(
  project TEXT PRIMARY KEY,
  version INTEGER NOT NULL DEFAULT 0,
  stage TEXT,
  waiting_on TEXT,
  signed_docs TEXT,
  open_questions TEXT,
  updated_utc TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS control(
  recipient TEXT PRIMARY KEY,
  paused INTEGER NOT NULL DEFAULT 0,
  updated_utc TEXT NOT NULL
);
"""


def default_box_path(cli_box: Optional[str] = None) -> str:
    """`--box` > `AGENT_MAIL_BOX` > `.agents/agent-mail/mail.sqlite`."""
    if cli_box:
        return os.path.abspath(cli_box)
    env = os.environ.get("AGENT_MAIL_BOX")
    if env:
        return os.path.abspath(env)
    return DEFAULT_BOX


def _enable_wal(conn: sqlite3.Connection, attempts: int = 20, pause: float = 0.05) -> bool:
    """Best-effort `journal_mode=WAL`. Returns True when the mode is (or became) WAL.

    SQLite does NOT apply `busy_timeout` to a journal-mode change: when two processes
    open the same brand-new box at the same instant, the loser gets an immediate
    "database is locked" instead of waiting. WAL is a concurrency optimisation, not a
    correctness requirement, so retry briefly and fall back to the default journal
    rather than crashing the caller.
    """
    for i in range(attempts):
        try:
            row = conn.execute("PRAGMA journal_mode=WAL").fetchone()
        except sqlite3.OperationalError:
            time.sleep(pause)
            continue
        if row is not None and str(row[0]).lower() == "wal":
            return True
        time.sleep(pause)
    log.debug("journal_mode=WAL unavailable, continuing with the default journal")
    return False


def ensure_mail_home(box_dir: str) -> None:
    """A box under ~/.agent-mail keeps that home at mode 0700 (created now or earlier with a wider
    umask): boxes and decisions notes live there. The same rule as team-channel.sh."""
    home = os.path.join(os.path.expanduser("~"), ".agent-mail")
    if os.path.abspath(box_dir).startswith(home + os.sep):
        os.makedirs(home, mode=0o700, exist_ok=True)
        os.chmod(home, 0o700)


def open_box(path: Optional[str] = None) -> sqlite3.Connection:
    """Open (creating if needed) the mailbox and apply the schema idempotently."""
    path = default_box_path(path)
    parent = os.path.dirname(path)
    if parent:
        ensure_mail_home(parent)
        os.makedirs(parent, exist_ok=True)
    # isolation_level=None -> autocommit; every multi-statement unit below opens an
    # explicit BEGIN IMMEDIATE. With the default mode sqlite3 opens a transaction
    # implicitly and the explicit BEGIN raises "cannot start a transaction within
    # a transaction".
    conn = sqlite3.connect(path, timeout=5.0, isolation_level=None)
    conn.row_factory = sqlite3.Row
    _enable_wal(conn)
    conn.execute("PRAGMA foreign_keys=ON")
    conn.executescript(SCHEMA)
    return conn


# ---------------------------------------------------------------------------
# validation
# ---------------------------------------------------------------------------

def _check_ident(value, field, relaxed=False):
    rx = LEGACY_IDENT_RE if relaxed else IDENT_RE
    if not isinstance(value, str) or not rx.match(value):
        raise ValueError("invalid %s %r: must match %s" % (field, value, rx.pattern))


def check_ident(value, field="identifier") -> None:
    """Public strict identifier check — raises ValueError.

    Callers that interpolate an operator-supplied name into a filesystem path
    (`lock_path`) MUST run this first: `IDENT_RE` forbids `/` and `..`, so a
    validated ident can never escape the box directory.
    """
    _check_ident(value, field)


def validate_message(sender, recipients, kind, body, *, awaiting=None, thread=None,
                     project="Jarvis", relaxed=False) -> None:
    """Raise ValueError unless the message is safe to store and to signal."""
    if kind not in KINDS:
        raise ValueError("invalid kind %r: expected one of %s" % (kind, ",".join(KINDS)))
    if not isinstance(body, str) or not body.strip():
        raise ValueError("body must be a non-empty string")
    recipients = list(recipients)
    if not recipients:
        raise ValueError("recipients must not be empty")
    if len(set(recipients)) != len(recipients):
        raise ValueError("duplicate recipients: %r" % (recipients,))
    _check_ident(sender, "sender", relaxed)
    for r in recipients:
        _check_ident(r, "recipient", relaxed)
    if sender in recipients:
        raise ValueError("sender %r must not be among recipients" % (sender,))
    # These three always reach the single-line wake-up signal, so they stay strict
    # even for imported history.
    if awaiting is not None:
        _check_ident(awaiting, "awaiting")
    if thread is not None:
        _check_ident(thread, "thread")
    _check_ident(project, "project")


# ---------------------------------------------------------------------------
# send / inbox
# ---------------------------------------------------------------------------

def send(conn, sender, recipients, kind, body, *, thread=None, awaiting=None,
         reply_to=None, refs=(), project="Jarvis", dedup_key=None,
         initial_state="pending", legacy_id=None, legacy_ts=None, legacy_awaiting=None,
         ts_utc=None, conn_in_tx=False) -> int:
    """Insert one message plus a delivery row per recipient. Returns the message id.

    `initial_state='processed'` is the history-import path (Step 2): the rows are
    created already handled, so they never wake anybody.

    The `legacy_*` / `ts_utc` arguments belong to that import only — a NEW message
    always takes the clock, never a caller-supplied time. `conn_in_tx=True` skips
    the BEGIN/COMMIT so the whole import can run as one all-or-nothing transaction
    owned by the caller (errors then propagate, for the caller to ROLLBACK).
    """
    recipients = list(recipients)
    if initial_state not in DELIVERY_STATES:
        raise ValueError("invalid initial_state %r" % (initial_state,))
    validate_message(sender, recipients, kind, body, awaiting=awaiting, thread=thread,
                     project=project, relaxed=(initial_state == "processed"))

    ts = ts_utc or now_utc()
    if not conn_in_tx:
        conn.execute("BEGIN IMMEDIATE")
    try:
        if reply_to is not None:
            parent = conn.execute("SELECT id FROM messages WHERE id=?", (reply_to,)).fetchone()
            if parent is None:
                raise ValueError("reply_to %r does not exist" % (reply_to,))
        cur = conn.execute(
            "INSERT INTO messages(ts_utc, project, thread, sender, recipients, kind, awaiting,"
            " reply_to, refs, body, legacy_id, legacy_ts, legacy_awaiting, dedup_key)"
            " VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
            (ts, project, thread, sender, json.dumps(recipients), kind, awaiting,
             reply_to, json.dumps(list(refs)), body, legacy_id, legacy_ts,
             legacy_awaiting, dedup_key))
        message_id = int(cur.lastrowid)
        for recipient in recipients:
            conn.execute(
                "INSERT INTO delivery(message_id, recipient, state, updated_utc, attempts)"
                " VALUES(?,?,?,?,0)", (message_id, recipient, initial_state, ts))
        if not conn_in_tx:
            conn.execute("COMMIT")
    except sqlite3.IntegrityError:
        if conn_in_tx:
            raise
        conn.execute("ROLLBACK")
        if dedup_key is not None:
            row = conn.execute("SELECT id FROM messages WHERE dedup_key=?", (dedup_key,)).fetchone()
            if row is not None:
                log.debug("dedup hit for key %r -> id=%s", dedup_key, row["id"])
                return int(row["id"])
        raise
    except Exception:
        if conn_in_tx:
            raise
        conn.execute("ROLLBACK")
        raise
    return message_id


def inbox(conn, recipient, *, unread=False, since_id=0, limit=50) -> List[sqlite3.Row]:
    """Messages addressed to `recipient`, oldest first.

    `unread` keeps everything the recipient has not finished with — including its
    own claim (`received`), which is still open work.
    """
    sql = ("SELECT m.*, d.state AS delivery_state, d.attempts AS attempts,"
           " d.delivered_utc AS delivered_utc, d.received_utc AS received_utc"
           " FROM messages m JOIN delivery d ON d.message_id = m.id AND d.recipient = ?"
           " WHERE m.id > ?")
    params: List[Any] = [recipient, int(since_id)]
    if unread:
        sql += " AND d.state IN ('pending','delivered','received')"
    sql += " ORDER BY m.id"
    if limit:
        sql += " LIMIT ?"
        params.append(int(limit))
    return conn.execute(sql, params).fetchall()


# ---------------------------------------------------------------------------
# delivery state machine
# ---------------------------------------------------------------------------

_UPDATABLE_COLS = ("delivered_utc", "received_utc", "attempts", "note")


def _transition(conn, message_id, recipient, from_states, to_state, **cols) -> bool:
    """Compare-and-set delivery transition. False when no row was in `from_states`."""
    if to_state not in DELIVERY_STATES:
        raise ValueError("invalid target state %r" % (to_state,))
    from_states = tuple(from_states)
    if not from_states:
        raise ValueError("from_states must not be empty")
    sets = ["state=?", "updated_utc=?"]
    params: List[Any] = [to_state, now_utc()]
    for key in sorted(cols):
        if key not in _UPDATABLE_COLS:
            raise ValueError("unknown delivery column %r" % (key,))
        sets.append(key + "=?")
        params.append(cols[key])
    placeholders = ",".join("?" for _ in from_states)
    params.extend([message_id, recipient])
    params.extend(from_states)
    cur = conn.execute(
        "UPDATE delivery SET %s WHERE message_id=? AND recipient=? AND state IN (%s)"
        % (", ".join(sets), placeholders), params)
    return cur.rowcount > 0


def delivery_row(conn, message_id, recipient) -> Optional[sqlite3.Row]:
    return conn.execute("SELECT * FROM delivery WHERE message_id=? AND recipient=?",
                        (message_id, recipient)).fetchone()


def receive(conn, message_id, by) -> bool:
    """Recipient claims the message (`inbox --ack`): stops redelivery, not done yet."""
    return _transition(conn, message_id, by, ("pending", "delivered"), "received",
                       received_utc=now_ts())


def ack(conn, message_id, by, state="processed", note=None) -> bool:
    """Close a delivery. False when it was already terminal (never downgraded)."""
    if state not in TERMINAL_STATES:
        raise ValueError("ack state must be one of %s" % (",".join(TERMINAL_STATES),))
    row = delivery_row(conn, message_id, by)
    if row is None:
        raise KeyError("no delivery for message %s recipient %r" % (message_id, by))
    if row["state"] in TERMINAL_STATES:
        return False
    return _transition(conn, message_id, by, OPEN_STATES, state, note=note)


def requeue(conn, message_id, recipient, by) -> bool:
    """Explicit recovery from `failed` back to `pending` (the only non-monotonic move)."""
    conn.execute("BEGIN IMMEDIATE")
    try:
        ok = _transition(conn, message_id, recipient, ("failed",), "pending",
                         attempts=0, note="requeued by %s" % (by,))
        if ok:
            conn.execute(
                "INSERT INTO attempt_log(message_id, recipient, ts_utc, actor, ok, note)"
                " VALUES(?,?,?,?,?,?)",
                (message_id, recipient, now_ts(), "requeue", 1, "by %s" % (by,)))
        conn.execute("COMMIT")
    except Exception:
        conn.execute("ROLLBACK")
        raise
    return ok


# ---------------------------------------------------------------------------
# attempts
# ---------------------------------------------------------------------------

def attempts_last_hour(conn, recipient) -> int:
    """Wake-up attempts charged to `recipient` in the trailing hour (both actors)."""
    placeholders = ",".join("?" for _ in RATE_LIMITED_ACTORS)
    row = conn.execute(
        "SELECT COUNT(*) AS n FROM attempt_log WHERE recipient=? AND ts_utc > ?"
        " AND actor IN (%s)" % placeholders,
        [recipient, _ts_ago(3600)] + list(RATE_LIMITED_ACTORS)).fetchone()
    return int(row["n"])


def reserve_attempt(conn, message_id, recipient, actor) -> Tuple[int, int]:
    """Charge an attempt BEFORE making it. Returns `(attempt_log_id, attempts)`.

    Must run inside the caller's transaction: the increment and the `ok IS NULL`
    log row have to land together, so a crash before the result is written still
    leaves the attempt counted.
    """
    conn.execute("UPDATE delivery SET attempts = attempts + 1, updated_utc=?"
                 " WHERE message_id=? AND recipient=?", (now_utc(), message_id, recipient))
    cur = conn.execute(
        "INSERT INTO attempt_log(message_id, recipient, ts_utc, actor, ok, note)"
        " VALUES(?,?,?,?,NULL,NULL)", (message_id, recipient, now_ts(), actor))
    row = conn.execute("SELECT attempts FROM delivery WHERE message_id=? AND recipient=?",
                       (message_id, recipient)).fetchone()
    return int(cur.lastrowid), int(row["attempts"])


def mark_attempt(conn, attempt_log_id, ok, note=None) -> None:
    """Record the outcome of a reserved attempt (`ok IS NULL` means 'unknown')."""
    conn.execute("UPDATE attempt_log SET ok=?, note=? WHERE id=?",
                 (1 if ok else 0, note, attempt_log_id))


# ---------------------------------------------------------------------------
# wake-up selection
# ---------------------------------------------------------------------------

class Reason(str):
    """Verdict of `next_wake_candidate` — a plain string that also carries its ids.

    It subclasses `str`, so every existing comparison (`reason == "OK"`,
    `reason == "RATE_LIMIT"`) keeps working unchanged. The extra attributes exist
    because "nothing to hand out" has two very different causes and a caller must
    be able to tell them apart *and* name the delivery involved:

      * `EMPTY`     — no wake-kind message is open for this recipient.
      * `IN_FLIGHT` — there is one, but it is already being handled: either its own
        lease is still alive, or another message in the same thread holds the
        one-active-handling slot. `message_id` is the candidate that was held back
        and `thread` its thread (None = own bucket) — together they are the
        `IN_FLIGHT id=… thread=…` line deliver logs.
      * `RATE_LIMIT` — a candidate exists but the hourly budget is spent.
    """

    def __new__(cls, text, message_id=None, thread=None):
        obj = str.__new__(cls, text)
        obj.message_id = message_id
        obj.thread = thread
        return obj


def next_wake_candidate(conn, recipient, wake_kinds=WAKE_KINDS,
                        redeliver_after=DEFAULT_REDELIVER_AFTER,
                        claim_timeout=DEFAULT_CLAIM_TIMEOUT,
                        max_per_hour=DEFAULT_MAX_PER_HOUR, exclude_ids=()
                        ) -> Tuple[Optional[sqlite3.Row], str]:
    """Pick the message that should wake `recipient` now — shared by `wait` and deliver.

    Returns `(row, reason)` where `reason` is a `Reason`: OK with a row, or None with
    EMPTY / IN_FLIGHT / RATE_LIMIT (see `Reason` for what the ids on it mean).
    Call inside `BEGIN IMMEDIATE`: step (3) expires dead leases as a side effect.

    `exclude_ids` skips message ids the caller has already handled in this run
    (deliver's `--once` budget), so one message cannot starve the other threads.
    """
    wake_kinds = tuple(wake_kinds)
    if not wake_kinds:
        return None, Reason("EMPTY")
    lease_cut = _ts_ago(redeliver_after)
    claim_cut = _ts_ago(claim_timeout)
    kind_ph = ",".join("?" for _ in wake_kinds)

    # (1) candidates: never-signalled, or signalled and the lease has run out.
    rows = conn.execute(
        "SELECT m.id AS id, m.ts_utc AS ts_utc, m.sender AS sender, m.kind AS kind,"
        " m.awaiting AS awaiting, m.thread AS thread, m.body AS body, m.refs AS refs,"
        " d.state AS state, d.delivered_utc AS delivered_utc, d.attempts AS attempts"
        " FROM messages m JOIN delivery d ON d.message_id = m.id AND d.recipient = ?"
        " WHERE m.kind IN (%s) AND d.state IN ('pending','delivered')"
        " ORDER BY m.id" % kind_ph, [recipient] + list(wake_kinds)).fetchall()
    if not rows:
        return None, Reason("EMPTY")

    # (2) in-flight scan: one active handling per (recipient, thread).
    busy = conn.execute(
        "SELECT m.id AS id, m.thread AS thread, d.state AS state,"
        " d.delivered_utc AS delivered_utc, d.received_utc AS received_utc"
        " FROM messages m JOIN delivery d ON d.message_id = m.id AND d.recipient = ?"
        " WHERE m.kind IN (%s) AND d.state IN ('delivered','received')" % kind_ph,
        [recipient] + list(wake_kinds)).fetchall()

    # First candidate that exists but cannot be handed out, as (id, thread).
    # `blocked_pending` wins when both are set: a pending message held back by someone
    # else's lease is what an operator needs to see, not the leased message itself.
    blocked = None
    blocked_pending = None
    exclude_ids = frozenset(exclude_ids or ())
    for row in rows:
        if row["id"] in exclude_ids:
            continue                          # caller already had its turn on this one
        if row["state"] == "delivered":
            delivered_utc = row["delivered_utc"] or ""
            if delivered_utc > lease_cut:
                # Lease still alive — not due yet, but the recipient IS handling it:
                # that is IN_FLIGHT, not EMPTY (the message blocking us is this one).
                if blocked is None:
                    blocked = (row["id"], row["thread"])
                continue
            # (3) lease expired and the budget is gone: give up on this delivery.
            # No new attempt_log row and no increment — the attempt already happened.
            if int(row["attempts"]) >= MAX_ATTEMPTS:
                _transition(conn, row["id"], recipient, ("delivered",), "failed",
                            note="attempts-exhausted")
                log.warning("delivery failed (attempts exhausted): id=%s recipient=%s",
                            row["id"], recipient)
                continue

        blocked_by = None
        for other in busy:
            if other["id"] == row["id"]:
                continue
            # NULL thread is its own bucket (compared in Python, so NULL == NULL).
            if other["thread"] != row["thread"]:
                continue
            if other["state"] == "delivered" and (other["delivered_utc"] or "") > lease_cut:
                blocked_by = other["id"]
                break
            if other["state"] == "received":
                received_utc = other["received_utc"] or ""
                if received_utc > claim_cut:
                    blocked_by = other["id"]
                    break
                log.warning("STALE_CLAIM: id=%s recipient=%s thread=%s no longer blocks",
                            other["id"], recipient, other["thread"])
        if blocked_by is not None:
            if blocked is None:
                blocked = (row["id"], row["thread"])
            if blocked_pending is None and row["state"] == "pending":
                blocked_pending = (row["id"], row["thread"])
            continue

        # (4) hourly budget — checked only once a real candidate exists.
        if max_per_hour is not None and attempts_last_hour(conn, recipient) >= int(max_per_hour):
            return None, Reason("RATE_LIMIT")
        return row, Reason("OK")

    held = blocked_pending or blocked
    if held is None:
        return None, Reason("EMPTY")
    return None, Reason("IN_FLIGHT", message_id=held[0], thread=held[1])


def wait_one(conn, recipient, *, timeout=None, poll=DEFAULT_POLL, wake_kinds=WAKE_KINDS,
             redeliver_after=DEFAULT_REDELIVER_AFTER, claim_timeout=DEFAULT_CLAIM_TIMEOUT,
             max_per_hour=DEFAULT_MAX_PER_HOUR) -> Optional[Dict[str, Any]]:
    """Block until one message is due for `recipient`, then LEASE it (not consume it).

    Returns a dict with the message fields plus `attempt` and `attempt_log_id`, or
    None on timeout. The caller emits its wake-up line and only then calls
    `mark_attempt(conn, attempt_log_id, True)` — the line on stdout IS the attempt,
    so a crash before it leaves `ok IS NULL`, which still counts towards the limits.
    """
    deadline = None if timeout is None else time.time() + float(timeout)
    while True:
        if is_paused(conn, recipient):
            if deadline is not None and time.time() >= deadline:
                return None
            time.sleep(_nap(poll, deadline))
            continue

        conn.execute("BEGIN IMMEDIATE")
        try:
            row, reason = next_wake_candidate(
                conn, recipient, wake_kinds=wake_kinds, redeliver_after=redeliver_after,
                claim_timeout=claim_timeout, max_per_hour=max_per_hour)
            if row is None:
                conn.execute("COMMIT")
            else:
                attempt_log_id, attempts = reserve_attempt(conn, row["id"], recipient, "wait")
                # Marking `delivered` in the same transaction as the read is what stops
                # a second concurrent waiter from getting the same message inside the
                # lease window.
                _transition(conn, row["id"], recipient, ("pending", "delivered"), "delivered",
                            delivered_utc=now_ts())
                conn.execute("COMMIT")
                result = {key: row[key] for key in row.keys()}
                result["state"] = "delivered"
                result["attempt"] = attempts
                result["attempt_log_id"] = attempt_log_id
                return result
        except Exception:
            conn.execute("ROLLBACK")
            raise

        if reason == "RATE_LIMIT":
            log.warning("RATE_LIMIT: recipient=%s max_per_hour=%s", recipient, max_per_hour)
        if deadline is not None and time.time() >= deadline:
            return None
        time.sleep(_nap(poll, deadline))


def _nap(poll, deadline) -> float:
    """Sleep step that never overshoots the deadline (poll defaults to 2 s)."""
    step = float(poll)
    if deadline is not None:
        step = min(step, max(0.01, deadline - time.time()))
    return max(0.0, step)


# ---------------------------------------------------------------------------
# shared project state
# ---------------------------------------------------------------------------

_STATE_FIELDS = ("stage", "waiting_on", "signed_docs", "open_questions")


def state_get(conn, project="Jarvis") -> Optional[sqlite3.Row]:
    return conn.execute("SELECT * FROM state WHERE project=?", (project,)).fetchone()


def state_set(conn, project, expect_version, **fields) -> int:
    """Optimistic-lock update. Returns the new version, raises ConflictError on a race."""
    for key in fields:
        if key not in _STATE_FIELDS:
            raise ValueError("unknown state field %r" % (key,))
    expect_version = int(expect_version)
    conn.execute("BEGIN IMMEDIATE")
    try:
        current = conn.execute("SELECT version FROM state WHERE project=?", (project,)).fetchone()
        if current is None:
            if expect_version != 0:
                conn.execute("COMMIT")
                raise ConflictError(0)
            columns = ["project", "version", "updated_utc"]
            values: List[Any] = [project, 1, now_utc()]
            for key in _STATE_FIELDS:
                columns.append(key)
                values.append(fields.get(key))
            conn.execute("INSERT INTO state(%s) VALUES(%s)"
                         % (",".join(columns), ",".join("?" for _ in columns)), values)
            conn.execute("COMMIT")
            return 1

        if int(current["version"]) != expect_version:
            conn.execute("COMMIT")
            raise ConflictError(int(current["version"]))

        sets = ["version=version+1", "updated_utc=?"]
        params: List[Any] = [now_utc()]
        for key in _STATE_FIELDS:
            if key in fields:
                sets.append(key + "=?")
                params.append(fields[key])
        params.extend([project, expect_version])
        cur = conn.execute("UPDATE state SET %s WHERE project=? AND version=?" % (", ".join(sets)),
                           params)
        if cur.rowcount == 0:
            row = conn.execute("SELECT version FROM state WHERE project=?", (project,)).fetchone()
            conn.execute("COMMIT")
            raise ConflictError(int(row["version"]) if row else 0)
        conn.execute("COMMIT")
    except ConflictError:
        raise
    except Exception:
        conn.execute("ROLLBACK")
        raise
    return expect_version + 1


# ---------------------------------------------------------------------------
# pause / resume
# ---------------------------------------------------------------------------

def set_paused(conn, recipient, paused: bool) -> None:
    _check_ident(recipient, "recipient")
    conn.execute(
        "INSERT INTO control(recipient, paused, updated_utc) VALUES(?,?,?)"
        " ON CONFLICT(recipient) DO UPDATE SET paused=excluded.paused,"
        " updated_utc=excluded.updated_utc",
        (recipient, 1 if paused else 0, now_utc()))


def is_paused(conn, recipient) -> bool:
    row = conn.execute("SELECT paused FROM control WHERE recipient=?", (recipient,)).fetchone()
    return bool(row and int(row["paused"]))


# ---------------------------------------------------------------------------
# locks — mirrors tools/ai_sl/ai_sl_lock.acquire
# ---------------------------------------------------------------------------

def acquire_lock(path) -> Optional[Any]:
    """Exclusive non-blocking flock. Returns the held handle, or None if taken.

    Keep the returned handle alive for the process lifetime — closing it (or letting
    it be garbage collected) releases the lock.
    """
    parent = os.path.dirname(os.path.abspath(path))
    if parent:
        os.makedirs(parent, exist_ok=True)
    fh = open(path, "w")
    try:
        fcntl.flock(fh, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        fh.close()
        return None
    return fh


def lock_path(box_path, role, recipient) -> str:
    """`<box>.wait.<recipient>.lock` / `<box>.deliver.<recipient>.lock`."""
    return "%s.%s.%s.lock" % (box_path, role, recipient)
