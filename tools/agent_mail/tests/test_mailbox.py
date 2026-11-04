# Vendored from mrozmk/jarvis@c9c407c (tools/agent_mail/) — MIT, same terms and holder as LICENSE.
# Local delta and the re-sync procedure: tools/agent_mail/README.md → "Vendored copy".
"""
Offline unit tests for tools/agent_mail — no network, no MT5, no shared state.

stdlib unittest (class-based test_*), mirroring tools/ai_sl/tests/test_plumbing.py —
NOT pytest (not installed in any env here). Every test gets a fresh mailbox under
its own tempfile.mkdtemp(), so nothing touches a real box.

Coverage follows the Step 1 plan: send/validation, dedup, inbox/ack, the wake-up
lease (`wait_one`), the one-active-handling-per-thread rule, claim vs done,
attempt reservation, the hourly rate limit, requeue and the optimistic state lock.
"""

import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import unittest

# --- import agent_mail_* flat (dir on sys.path) ---
_PKG_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
if _PKG_DIR not in sys.path:
    sys.path.insert(0, _PKG_DIR)

import agent_mail                 # noqa: E402
import agent_mail_deliver as deliver   # noqa: E402
import agent_mail_store as store   # noqa: E402

CLI = os.path.join(_PKG_DIR, "agent_mail.py")


# Child for the concurrent-open regression: import first, then spin to a shared
# wall-clock tick, so N processes hit a brand-new box simultaneously.
RACE_CHILD = """
import sys, time
sys.path.insert(0, %r)
import agent_mail_store as store
path, start = sys.argv[1], float(sys.argv[2])
while time.time() < start:
    pass
store.open_box(path).close()
""" % (_PKG_DIR,)


class MailboxTestCase(unittest.TestCase):
    """Fresh box per test + helpers for driving the CLI as a real subprocess."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="agent_mail_test_")
        self.box = os.path.join(self.tmp, "mail.sqlite")
        self.conn = store.open_box(self.box)
        self.procs = []

    def tearDown(self):
        for proc in self.procs:
            if proc.poll() is None:
                proc.kill()
                proc.wait(timeout=10)
        self.conn.close()
        shutil.rmtree(self.tmp, ignore_errors=True)

    def cli(self, *argv, **kwargs):
        cmd = [sys.executable, CLI, "--box", self.box] + [str(a) for a in argv]
        return subprocess.run(cmd, capture_output=True, text=True,
                              timeout=kwargs.pop("timeout", 30), **kwargs)

    def popen(self, *argv):
        cmd = [sys.executable, CLI, "--box", self.box] + [str(a) for a in argv]
        proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        self.procs.append(proc)
        return proc

    def state_of(self, message_id, recipient):
        return store.delivery_row(self.conn, message_id, recipient)["state"]


class TestSend(MailboxTestCase):

    def test_send_assigns_sequential_ids_and_delivery_rows(self):
        first = store.send(self.conn, "Advisor", ["Reviewer", "Tester"], "turn", "one")
        second = store.send(self.conn, "Advisor", ["Reviewer"], "info", "two")
        self.assertEqual([first, second], [1, 2])
        rows = self.conn.execute(
            "SELECT recipient, state FROM delivery WHERE message_id=1 ORDER BY recipient").fetchall()
        self.assertEqual([r["recipient"] for r in rows], ["Reviewer", "Tester"])
        self.assertEqual({r["state"] for r in rows}, {"pending"})
        self.assertEqual(
            self.conn.execute("SELECT COUNT(*) AS n FROM delivery").fetchone()["n"], 3)

    def test_send_rejects_self_and_bad_kind(self):
        with self.assertRaises(ValueError):
            store.send(self.conn, "Advisor", ["Advisor"], "turn", "self")
        with self.assertRaises(ValueError):
            store.send(self.conn, "Advisor", ["Reviewer"], "gossip", "bad kind")
        with self.assertRaises(ValueError):
            store.send(self.conn, "Advisor", ["Reviewer"], "turn", "   ")
        with self.assertRaises(ValueError):
            store.send(self.conn, "Advisor", [], "turn", "no recipients")
        with self.assertRaises(ValueError):
            store.send(self.conn, "Advisor", ["Reviewer"], "turn", "bad parent", reply_to=99)
        self.assertEqual(
            self.conn.execute("SELECT COUNT(*) AS n FROM messages").fetchone()["n"], 0)

    def test_dedup_key_returns_existing_id(self):
        first = store.send(self.conn, "Advisor", ["Reviewer"], "turn", "body", dedup_key="k1")
        again = store.send(self.conn, "Advisor", ["Reviewer"], "turn", "resent", dedup_key="k1")
        self.assertEqual(first, again)
        self.assertEqual(
            self.conn.execute("SELECT COUNT(*) AS n FROM messages").fetchone()["n"], 1)
        other = store.send(self.conn, "Advisor", ["Reviewer"], "turn", "body", dedup_key="k2")
        self.assertNotEqual(first, other)

    def test_send_rejects_unsafe_identifiers(self):
        # These fields go onto the one-line wake-up signal, so no newlines/spaces.
        with self.assertRaises(ValueError):
            store.send(self.conn, "A\nB", ["Reviewer"], "turn", "body")
        with self.assertRaises(ValueError):
            store.send(self.conn, "Advisor", ["Reviewer"], "turn", "body", thread="x y")
        with self.assertRaises(ValueError):
            store.send(self.conn, "Advisor", ["Reviewer"], "turn", "body", awaiting="-Reviewer")
        with self.assertRaises(ValueError):
            store.send(self.conn, "Advisor", ["As tra"], "turn", "body")
        # Imported history is never signalled, so the historical spelling is allowed.
        legacy = store.send(self.conn, "Wykonawca K5", ["Reviewer"], "report", "history",
                            initial_state="processed")
        self.assertEqual(self.state_of(legacy, "Reviewer"), "processed")
        with self.assertRaises(ValueError):
            store.send(self.conn, "Wykonawca\nK5", ["Reviewer"], "report", "history",
                       initial_state="processed")

    def test_concurrent_send_no_id_collision(self):
        driver = (
            "import sys; sys.path.insert(0, sys.argv[1]); import agent_mail;"
            " [agent_mail.main(['--box', sys.argv[2], 'send', '--from', sys.argv[3],"
            " '--to', 'Reviewer', '--kind', 'info', '--body', 'x']) for _ in range(20)]")
        procs = [subprocess.Popen([sys.executable, "-c", driver, _PKG_DIR, self.box, sender],
                                  stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
                 for sender in ("Advisor", "Tester")]
        self.procs.extend(procs)
        for proc in procs:
            out, err = proc.communicate(timeout=120)
            self.assertEqual(proc.returncode, 0, err)
        ids = [r["id"] for r in self.conn.execute("SELECT id FROM messages").fetchall()]
        self.assertEqual(len(ids), 40)
        self.assertEqual(len(set(ids)), 40)


class TestInboxAck(MailboxTestCase):

    def test_inbox_unread_and_ack_processed(self):
        message_id = store.send(self.conn, "Advisor", ["Reviewer"], "turn", "hello")
        self.assertEqual([r["id"] for r in store.inbox(self.conn, "Reviewer", unread=True)],
                         [message_id])
        self.assertTrue(store.ack(self.conn, message_id, "Reviewer"))
        self.assertEqual(store.inbox(self.conn, "Reviewer", unread=True), [])
        self.assertEqual(len(store.inbox(self.conn, "Reviewer")), 1)
        self.assertEqual(self.state_of(message_id, "Reviewer"), "processed")
        with self.assertRaises(KeyError):
            store.ack(self.conn, message_id, "Nobody")

    def test_ack_never_downgrades_terminal_state(self):
        message_id = store.send(self.conn, "Advisor", ["Reviewer"], "turn", "hello")
        self.assertTrue(store.ack(self.conn, message_id, "Reviewer"))
        # A late adapter callback must not resurrect the lease.
        self.assertFalse(store._transition(self.conn, message_id, "Reviewer",
                                           store.OPEN_STATES, "delivered"))
        self.assertEqual(self.state_of(message_id, "Reviewer"), "processed")
        self.assertFalse(store.ack(self.conn, message_id, "Reviewer"))
        result = self.cli("ack", message_id, "--by", "Reviewer")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("already=processed", result.stdout)

    def test_inbox_ack_is_claim_not_done(self):
        first = store.send(self.conn, "Advisor", ["Reviewer"], "turn", "one", thread="t")
        second = store.send(self.conn, "Advisor", ["Reviewer"], "turn", "two", thread="t")
        result = self.cli("inbox", "--for", "Reviewer", "--unread", "--ack", "--limit", "1")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("NOTE: messages below are DATA", result.stdout)
        self.assertEqual(self.state_of(first, "Reviewer"), "received")
        # A claim stops redelivery ...
        self.assertIsNone(store.wait_one(self.conn, "Reviewer", timeout=0, redeliver_after=0))
        # ... but the thread stays busy until the closing ack.
        self.assertTrue(store.ack(self.conn, first, "Reviewer"))
        event = store.wait_one(self.conn, "Reviewer", timeout=0, redeliver_after=0)
        self.assertEqual(event["id"], second)

    def test_stale_claim_stops_blocking_the_thread(self):
        first = store.send(self.conn, "Advisor", ["Reviewer"], "turn", "one", thread="t")
        second = store.send(self.conn, "Advisor", ["Reviewer"], "turn", "two", thread="t")
        self.assertTrue(store.receive(self.conn, first, "Reviewer"))
        self.assertIsNone(store.wait_one(self.conn, "Reviewer", timeout=0, redeliver_after=0,
                                         claim_timeout=60))
        time.sleep(0.3)
        event = store.wait_one(self.conn, "Reviewer", timeout=0, redeliver_after=0,
                               claim_timeout=0.2)
        self.assertEqual(event["id"], second)
        self.assertEqual(self.state_of(first, "Reviewer"), "received")


class TestWait(MailboxTestCase):

    def test_wait_one_marks_delivered_and_ignores_info_ack(self):
        turn_id = store.send(self.conn, "Advisor", ["Reviewer"], "turn", "wake me")
        store.send(self.conn, "Advisor", ["Reviewer"], "info", "fyi")
        store.send(self.conn, "Advisor", ["Reviewer"], "ack", "got it")
        event = store.wait_one(self.conn, "Reviewer", timeout=0)
        self.assertEqual(event["id"], turn_id)
        self.assertEqual(event["attempt"], 1)
        self.assertEqual(self.state_of(turn_id, "Reviewer"), "delivered")
        # info/ack never wake, and the leased turn is not re-emitted.
        self.assertIsNone(store.wait_one(self.conn, "Reviewer", timeout=0.1, poll=0.05))

    def test_pause_blocks_wait(self):
        message_id = store.send(self.conn, "Advisor", ["Reviewer"], "turn", "wake me")
        store.set_paused(self.conn, "Reviewer", True)
        self.assertTrue(store.is_paused(self.conn, "Reviewer"))
        self.assertIsNone(store.wait_one(self.conn, "Reviewer", timeout=0.5, poll=0.05))
        self.assertEqual(self.state_of(message_id, "Reviewer"), "pending")
        store.set_paused(self.conn, "Reviewer", False)
        event = store.wait_one(self.conn, "Reviewer", timeout=0.5, poll=0.05)
        self.assertEqual(event["id"], message_id)

    def test_wait_redelivers_after_crash_before_ack(self):
        message_id = store.send(self.conn, "Advisor", ["Reviewer"], "turn", "wake me")
        first = store.wait_one(self.conn, "Reviewer", timeout=0)
        self.assertEqual((first["id"], first["attempt"]), (message_id, 1))
        # No ack: the turn died before claiming it, so the lease must expire.
        second = store.wait_one(self.conn, "Reviewer", timeout=1, poll=0.05, redeliver_after=0.2)
        self.assertEqual((second["id"], second["attempt"]), (message_id, 2))
        self.assertTrue(store.ack(self.conn, message_id, "Reviewer"))
        self.assertIsNone(store.wait_one(self.conn, "Reviewer", timeout=0, redeliver_after=0))

    def test_wait_one_in_flight_blocks_next(self):
        first = store.send(self.conn, "Advisor", ["Reviewer"], "turn", "one")
        second = store.send(self.conn, "Advisor", ["Reviewer"], "turn", "two")
        self.assertEqual(store.wait_one(self.conn, "Reviewer", timeout=0)["id"], first)
        self.assertIsNone(store.wait_one(self.conn, "Reviewer", timeout=0.5, poll=0.05,
                                         redeliver_after=60))
        self.assertTrue(store.ack(self.conn, first, "Reviewer"))
        event = store.wait_one(self.conn, "Reviewer", timeout=0.5, poll=0.05, redeliver_after=60)
        self.assertEqual(event["id"], second)

    def test_in_flight_scoped_per_thread(self):
        a1 = store.send(self.conn, "Advisor", ["Reviewer"], "turn", "a1", thread="a")
        b1 = store.send(self.conn, "Advisor", ["Reviewer"], "turn", "b1", thread="b")
        a2 = store.send(self.conn, "Advisor", ["Reviewer"], "turn", "a2", thread="a")
        self.assertEqual(store.wait_one(self.conn, "Reviewer", timeout=0)["id"], a1)
        # Another thread is free ...
        self.assertEqual(store.wait_one(self.conn, "Reviewer", timeout=0)["id"], b1)
        # ... but thread 'a' is busy until a1 is acked.
        self.assertIsNone(store.wait_one(self.conn, "Reviewer", timeout=0))
        # NULL thread is its own bucket, not a shared one.
        n1 = store.send(self.conn, "Advisor", ["Reviewer"], "turn", "n1")
        store.send(self.conn, "Advisor", ["Reviewer"], "turn", "n2")
        self.assertEqual(store.wait_one(self.conn, "Reviewer", timeout=0)["id"], n1)
        self.assertIsNone(store.wait_one(self.conn, "Reviewer", timeout=0))
        self.assertTrue(store.ack(self.conn, a1, "Reviewer"))
        self.assertEqual(store.wait_one(self.conn, "Reviewer", timeout=0)["id"], a2)

    def test_attempt_log_reserved_before_emit(self):
        message_id = store.send(self.conn, "Advisor", ["Reviewer"], "turn", "wake me")
        store.wait_one(self.conn, "Reviewer", timeout=0, redeliver_after=0)
        store.wait_one(self.conn, "Reviewer", timeout=0, redeliver_after=0)
        rows = self.conn.execute(
            "SELECT actor, ok FROM attempt_log WHERE message_id=?", (message_id,)).fetchall()
        self.assertEqual([r["actor"] for r in rows], ["wait", "wait"])
        # wait_one only RESERVES: the caller marks ok after the line is on stdout.
        self.assertEqual([r["ok"] for r in rows], [None, None])
        self.assertEqual(
            store.delivery_row(self.conn, message_id, "Reviewer")["attempts"], 2)
        # Unknown-outcome rows still count towards the hourly budget.
        self.assertEqual(store.attempts_last_hour(self.conn, "Reviewer"), 2)

    def test_wait_rate_limit_counts_both_actors(self):
        store.send(self.conn, "Advisor", ["Reviewer"], "turn", "a", thread="a")
        store.send(self.conn, "Advisor", ["Reviewer"], "turn", "b", thread="b")
        store.send(self.conn, "Advisor", ["Reviewer"], "turn", "c", thread="c")
        self.assertIsNotNone(store.wait_one(self.conn, "Reviewer", timeout=0, max_per_hour=2))
        self.assertIsNotNone(store.wait_one(self.conn, "Reviewer", timeout=0, max_per_hour=2))
        self.assertIsNone(store.wait_one(self.conn, "Reviewer", timeout=0.3, poll=0.05,
                                         max_per_hour=2))
        # A deliver-side attempt is charged to the same budget.
        row, reason = store.next_wake_candidate(self.conn, "Reviewer", max_per_hour=4)
        self.assertEqual(reason, "OK")
        self.conn.execute(
            "INSERT INTO attempt_log(message_id, recipient, ts_utc, actor, ok)"
            " VALUES(?,?,?,?,1)", (row["id"], "Reviewer", store.now_ts(), "deliver"))
        self.conn.execute(
            "INSERT INTO attempt_log(message_id, recipient, ts_utc, actor, ok)"
            " VALUES(?,?,?,?,1)", (row["id"], "Reviewer", store.now_ts(), "deliver"))
        self.assertEqual(store.attempts_last_hour(self.conn, "Reviewer"), 4)
        self.assertEqual(store.next_wake_candidate(self.conn, "Reviewer", max_per_hour=4)[1],
                         "RATE_LIMIT")

    def test_two_waiters_one_message(self):
        waiters = [self.popen("wait", "--for", "Advisor", "--timeout", "5", "--poll", "0.1")
                   for _ in range(2)]
        time.sleep(1.0)
        sent = self.cli("send", "--from", "Reviewer", "--to", "Advisor", "--kind", "turn",
                        "--body", "your turn")
        self.assertEqual(sent.returncode, 0, sent.stderr)
        results = []
        for proc in waiters:
            out, err = proc.communicate(timeout=30)
            results.append((proc.returncode, out, err))
        new_lines = [line for _, out, _ in results for line in out.splitlines()
                     if line.startswith("NEW id=")]
        self.assertEqual(len(new_lines), 1, results)
        self.assertIn("attempt=1", new_lines[0])
        # Prove WHY there is only one line: the loser refused on the wait lock
        # (rc 2), it did not die on an open/lock error (rc 1) or exit cleanly.
        winners = [r for r in results if r[1].splitlines()]
        losers = [r for r in results if not r[1].splitlines()]
        self.assertEqual(len(winners), 1, results)
        self.assertEqual(winners[0][0], 0, results)
        self.assertEqual(len(losers), 1, results)
        self.assertEqual(losers[0][0], 2, results)
        # Either lock can be the one that refuses it (the deliver lock is held for
        # a moment by the winner), but it must be a lock refusal naming Advisor.
        self.assertRegex(losers[0][2], r"(wait already running|deliver running) for Advisor")

    def test_wait_refuses_when_deliver_lock_held(self):
        held = store.acquire_lock(store.lock_path(self.box, "deliver", "Advisor"))
        self.assertIsNotNone(held)
        try:
            result = self.cli("wait", "--for", "Advisor", "--timeout", "1")
            self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
            self.assertIn("deliver running for Advisor", result.stderr)
            self.assertEqual(result.stdout, "")
        finally:
            held.close()
        result = self.cli("wait", "--for", "Advisor", "--timeout", "0.2", "--poll", "0.1")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "TIMEOUT")


class TestRequeue(MailboxTestCase):

    def test_requeue_only_from_failed(self):
        message_id = store.send(self.conn, "Advisor", ["Reviewer"], "turn", "wake me")
        for expected in range(1, store.MAX_ATTEMPTS + 1):
            event = store.wait_one(self.conn, "Reviewer", timeout=0, redeliver_after=0)
            self.assertEqual(event["attempt"], expected)
        # Budget spent and the lease expired without a claim -> give up, no new attempt.
        self.assertIsNone(store.wait_one(self.conn, "Reviewer", timeout=0, redeliver_after=0))
        self.assertEqual(self.state_of(message_id, "Reviewer"), "failed")
        self.assertEqual(self.conn.execute(
            "SELECT COUNT(*) AS n FROM attempt_log WHERE actor='wait'").fetchone()["n"],
            store.MAX_ATTEMPTS)

        result = self.cli("requeue", message_id, "--for", "Reviewer", "--by", "Operator")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("REQUEUED id=%s for=Reviewer" % message_id, result.stdout)
        row = store.delivery_row(self.conn, message_id, "Reviewer")
        self.assertEqual((row["state"], row["attempts"]), ("pending", 0))
        self.assertEqual(self.conn.execute(
            "SELECT COUNT(*) AS n FROM attempt_log WHERE actor='requeue'").fetchone()["n"], 1)

        self.assertTrue(store.ack(self.conn, message_id, "Reviewer"))
        result = self.cli("requeue", message_id, "--for", "Reviewer", "--by", "Operator")
        self.assertEqual(result.returncode, 1)
        self.assertIn("cannot requeue", result.stderr)


class TestState(MailboxTestCase):

    def test_state_optimistic_lock(self):
        self.assertEqual(store.state_set(self.conn, "Jarvis", 0, stage="design"), 1)
        with self.assertRaises(store.ConflictError) as ctx:
            store.state_set(self.conn, "Jarvis", 0, stage="build")
        self.assertEqual(ctx.exception.current_version, 1)
        self.assertEqual(store.state_get(self.conn, "Jarvis")["stage"], "design")
        self.assertEqual(store.state_set(self.conn, "Jarvis", 1, stage="build",
                                         waiting_on="Reviewer"), 2)

        result = self.cli("state", "set", "--expect-version", "0", "--stage", "x")
        self.assertEqual(result.returncode, 3, result.stdout)
        self.assertIn("CONFLICT current_version=2", result.stderr)
        result = self.cli("state", "get")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("version=2 stage=build waiting_on=Reviewer", result.stdout)


class TestCli(MailboxTestCase):

    def test_send_inbox_ack_roundtrip_via_cli(self):
        sent = self.cli("send", "--from", "Reviewer", "--to", "Advisor", "--kind", "turn",
                        "--awaiting", "Advisor", "--thread", "kanal", "--ref", "docs/PRD.md",
                        "--body", "please review")
        self.assertEqual(sent.returncode, 0, sent.stderr)
        self.assertIn("SENT id=1 to=Advisor kind=turn awaiting=Advisor", sent.stdout)

        listed = self.cli("inbox", "--for", "Advisor", "--unread")
        self.assertIn("[agent-mail] #1", listed.stdout)
        self.assertIn("thread=kanal", listed.stdout)
        self.assertIn("refs=docs/PRD.md", listed.stdout)
        self.assertIn("please review", listed.stdout)

        acked = self.cli("ack", "1", "--by", "Advisor")
        self.assertEqual(acked.returncode, 0, acked.stderr)
        self.assertIn("ACK id=1 by=Advisor state=processed", acked.stdout)
        self.assertEqual(self.state_of(1, "Advisor"), "processed")

        result = self.cli("send", "--from", "Reviewer", "--to", "Reviewer", "--kind", "turn",
                          "--body", "self")
        self.assertEqual(result.returncode, 1)
        self.assertIn("ERROR:", result.stderr)

    def test_pause_resume_cli(self):
        self.assertIn("PAUSED Advisor", self.cli("pause", "--for", "Advisor").stdout)
        self.assertTrue(store.is_paused(self.conn, "Advisor"))
        self.assertIn("RESUMED Advisor", self.cli("resume", "--for", "Advisor").stdout)
        self.assertFalse(store.is_paused(self.conn, "Advisor"))

    def test_concurrent_first_open_of_fresh_box_does_not_crash(self):
        """Regression: `PRAGMA journal_mode=WAL` ignores busy_timeout.

        Several processes creating the SAME not-yet-existing box on the same tick
        used to make the losers raise sqlite3.OperationalError("database is locked")
        as an uncaught traceback (rc 1 + absolute paths on stderr). The children
        spin on a shared wall-clock start so they really collide -- plain staggered
        spawns are too slow -- and setUp already created the box for every other test.
        """
        fresh = os.path.join(self.tmp, "fresh", "mail.sqlite")
        os.makedirs(os.path.dirname(fresh), exist_ok=True)
        start = time.time() + 2.0
        procs = [subprocess.Popen([sys.executable, "-c", RACE_CHILD, fresh, str(start)],
                                  stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
                 for _ in range(10)]
        for proc in procs:
            out, err = proc.communicate(timeout=60)
            self.assertEqual(proc.returncode, 0, err)
            self.assertEqual(err, "")

    def test_inbox_json_and_body_stdin(self):
        cmd = [sys.executable, CLI, "--box", self.box, "send", "--from", "Reviewer",
               "--to", "Advisor", "--kind", "info", "--body", "-"]
        sent = subprocess.run(cmd, input="from stdin", capture_output=True, text=True, timeout=30)
        self.assertEqual(sent.returncode, 0, sent.stderr)
        listed = self.cli("inbox", "--for", "Advisor", "--json")
        self.assertEqual(listed.returncode, 0, listed.stderr)
        import json as _json
        rows = _json.loads(listed.stdout)
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["body"], "from stdin")
        self.assertEqual(rows[0]["delivery_state"], "pending")


class TestRegister(MailboxTestCase):
    """`register` writes the local recipients.json the deliver loop reads."""

    def registry(self):
        with open(os.path.join(self.tmp, "recipients.json"), encoding="utf-8") as handle:
            return json.load(handle)

    def test_register_writes_recipients_json(self):
        done = self.cli("register", "--as", "Reviewer", "--adapter", "codex-queue",
                        "--thread", "01a0a3b0-a8ea-71c0-9574-8102e0b7c829")
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertIn("REGISTERED Reviewer adapter=codex-queue", done.stdout)
        self.assertEqual(self.registry()["Reviewer"],
                         {"adapter": "codex-queue",
                          "thread": "01a0a3b0-a8ea-71c0-9574-8102e0b7c829"})

    def test_register_replaces_entry_of_same_name(self):
        """A new session re-registers under the same name; the stale thread must go."""
        self.cli("register", "--as", "Reviewer", "--adapter", "codex-queue", "--thread", "old-uuid")
        self.cli("register", "--as", "Advisor", "--adapter", "monitor")
        done = self.cli("register", "--as", "Reviewer", "--adapter", "codex-queue",
                        "--thread", "new-uuid")
        self.assertEqual(done.returncode, 0, done.stderr)
        registry = self.registry()
        self.assertEqual(registry["Reviewer"], {"adapter": "codex-queue", "thread": "new-uuid"})
        self.assertEqual(registry["Advisor"], {"adapter": "monitor"})   # untouched

    def test_register_rejects_missing_thread_and_unsafe_name(self):
        no_thread = self.cli("register", "--as", "Reviewer", "--adapter", "codex-queue")
        self.assertEqual(no_thread.returncode, 1)
        self.assertIn("requires --thread", no_thread.stderr)
        traversal = self.cli("register", "--as", "../../evil", "--adapter", "monitor")
        self.assertEqual(traversal.returncode, 1)
        self.assertIn("invalid name", traversal.stderr)
        self.assertFalse(os.path.exists(os.path.join(self.tmp, "recipients.json")))

    def test_recipients_lists_and_json(self):
        empty = self.cli("recipients")
        self.assertEqual(empty.returncode, 0, empty.stderr)
        self.assertIn("no recipients registered", empty.stdout)
        self.cli("register", "--as", "Reviewer", "--adapter", "codex-queue", "--thread", "u1")
        listed = self.cli("recipients")
        self.assertIn("Reviewer adapter=codex-queue thread=u1", listed.stdout)
        as_json = self.cli("recipients", "--json")
        self.assertEqual(json.loads(as_json.stdout)["Reviewer"]["thread"], "u1")

    def test_recipients_rejects_a_malformed_entry(self):
        """The registry is hand-editable: a non-object entry must not crash the listing."""
        with open(os.path.join(self.tmp, "recipients.json"), "w", encoding="utf-8") as handle:
            handle.write('{"Reviewer": "codex-queue"}')
        listed = self.cli("recipients")
        self.assertEqual(listed.returncode, 1)
        self.assertIn("must be a JSON object", listed.stderr)

    def test_register_adapter_lists_track_the_deliver_module(self):
        """REGISTER_ADAPTERS/THREAD_ADAPTERS are hand-copied from deliver — catch drift here."""
        self.assertEqual(set(agent_mail.REGISTER_ADAPTERS),
                         set(deliver.ADAPTERS) | {deliver.MONITOR})
        for adapter in deliver.ADAPTERS:
            needs_thread = adapter in agent_mail.THREAD_ADAPTERS
            try:
                deliver.build_command(adapter, None, "echo {signal}", "sig",
                                      {"id": 1, "thread": ""})
            except deliver.ConfigError as exc:
                self.assertTrue(needs_thread, "%s rejected without a thread: %s" % (adapter, exc))
                self.assertIn("thread", str(exc))
            else:
                self.assertFalse(needs_thread, "%s built a command without a thread" % (adapter,))


if __name__ == "__main__":
    unittest.main()
