# Vendored from mrozmk/jarvis@c9c407c (tools/agent_mail/) — MIT, same terms and holder as LICENSE.
# Local delta and the re-sync procedure: tools/agent_mail/README.md → "Vendored copy".
"""
Offline unit tests for tools/agent_mail/agent_mail_deliver.py — Step 3.

NOTHING here may reach a live agent session: the `codex` / `claude` adapters are
only ever exercised through a stubbed `run=` callable, and the end-to-end paths use
the `exec` adapter with `true` / `false` / a throwaway python writer. stdlib
unittest, fresh box per test, mirroring tools/agent_mail/tests/test_mailbox.py.
"""

import json
import os
import shlex
import shutil
import subprocess
import sys
import tempfile
import unittest

# --- import agent_mail_* flat (dir on sys.path) ---
_PKG_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
if _PKG_DIR not in sys.path:
    sys.path.insert(0, _PKG_DIR)

import agent_mail_store as store       # noqa: E402
import agent_mail_deliver as deliver   # noqa: E402

CLI = os.path.join(_PKG_DIR, "agent_mail.py")


class StubRun(object):
    """Stand-in for `subprocess.run` — records argv, never starts a process."""

    def __init__(self, returncode=0, stdout="", stderr="", before=None):
        self.returncode = returncode
        self.stdout = stdout
        self.stderr = stderr
        self.before = before
        self.calls = []

    def __call__(self, cmd, **kwargs):
        self.calls.append(cmd)
        if self.before is not None:
            self.before(cmd)
        return subprocess.CompletedProcess(cmd, self.returncode, self.stdout, self.stderr)


class DeliverTestCase(unittest.TestCase):
    """Fresh box per test + a helper that drives `main` in-process."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="agent_mail_deliver_")
        self.box = os.path.join(self.tmp, "mail.sqlite")
        self.conn = store.open_box(self.box)

    def tearDown(self):
        self.conn.close()
        for handler in list(deliver.log.handlers):
            deliver.log.removeHandler(handler)
            handler.close()
        shutil.rmtree(self.tmp, ignore_errors=True)

    # -- helpers ---------------------------------------------------------
    def run_deliver(self, *argv, **kwargs):
        run = kwargs.pop("run", subprocess.run)
        recipient = kwargs.pop("recipient", "Reviewer")
        box = kwargs.pop("box", self.box)
        args = ["--box", box, "--recipient", recipient] + [str(a) for a in argv]
        return deliver.main(args, run=run)

    def state_of(self, message_id, recipient="Reviewer"):
        return store.delivery_row(self.conn, message_id, recipient)["state"]

    def delivery(self, message_id, recipient="Reviewer"):
        return store.delivery_row(self.conn, message_id, recipient)

    def attempt_rows(self, recipient="Reviewer"):
        return self.conn.execute(
            "SELECT * FROM attempt_log WHERE recipient=? AND actor='deliver' ORDER BY id",
            (recipient,)).fetchall()

    def log_text(self, recipient="Reviewer", box=None):
        path = os.path.join(os.path.dirname(box or self.box), "deliver-%s.log" % (recipient,))
        if not os.path.exists(path):
            return ""
        with open(path, "r", encoding="utf-8") as fh:
            return fh.read()

    def writer_cmd(self, out_path):
        """exec template that appends just the signal argument to `out_path`."""
        script = ("import sys\n"
                  "open(%r, 'a', encoding='utf-8').write(sys.argv[1] + '\\n')\n" % (out_path,))
        return "%s -c %s {signal}" % (shlex.quote(sys.executable), shlex.quote(script))


# ---------------------------------------------------------------------------
# happy path / signal shape
# ---------------------------------------------------------------------------

class TestDeliverBasics(DeliverTestCase):

    def test_delivers_pending_turn_and_marks_delivered(self):
        message_id = store.send(self.conn, "Advisor", ["Reviewer"], "turn", "your turn")
        out = os.path.join(self.tmp, "out.txt")
        rc = self.run_deliver("--adapter", "exec", "--cmd", self.writer_cmd(out), "--once")
        self.assertEqual(rc, 0)
        with open(out, "r", encoding="utf-8") as fh:
            signal = fh.read()
        self.assertIn("NEW id=%s" % (message_id,), signal)
        self.assertEqual(self.state_of(message_id), "delivered")
        self.assertEqual(self.delivery(message_id)["attempts"], 1)
        self.assertIn("delivered id=%s" % (message_id,), self.log_text())

    def test_signal_has_no_body(self):
        store.send(self.conn, "Advisor", ["Reviewer"], "turn", "SECRET-BODY-XYZ")
        out = os.path.join(self.tmp, "out.txt")
        self.assertEqual(
            self.run_deliver("--adapter", "exec", "--cmd", self.writer_cmd(out), "--once"), 0)
        with open(out, "r", encoding="utf-8") as fh:
            signal = fh.read()
        self.assertNotIn("SECRET-BODY-XYZ", signal)
        self.assertNotIn("SECRET-BODY-XYZ", self.log_text())

    def test_signal_single_line_and_quoted_box_path(self):
        spaced = os.path.join(self.tmp, "a b")
        os.makedirs(spaced)
        box = os.path.join(spaced, "mail.sqlite")
        conn = store.open_box(box)
        try:
            store.send(conn, "Advisor", ["Reviewer"], "turn", "spacey")
        finally:
            conn.close()
        out = os.path.join(spaced, "out.txt")
        self.assertEqual(
            self.run_deliver("--adapter", "exec", "--cmd", self.writer_cmd(out), "--once",
                             box=box), 0)
        with open(out, "r", encoding="utf-8") as fh:
            signal = fh.read().strip()
        self.assertNotIn("\n", signal)
        self.assertIn("--box %s" % (shlex.quote(box),), signal)
        read_part = signal.split(" | read: ")[1].split(" | then: ")[0]
        argv = shlex.split(read_part)
        self.assertIn(box, argv)   # the spaced path survived as ONE argument

    def test_info_and_ack_marked_delivered_without_adapter(self):
        info_id = store.send(self.conn, "Advisor", ["Reviewer"], "info", "fyi")
        stub = StubRun(returncode=1)
        self.assertEqual(self.run_deliver("--adapter", "exec", "--cmd", "false", "--once",
                                          run=stub), 0)
        self.assertEqual(self.state_of(info_id), "delivered")
        self.assertEqual(self.delivery(info_id)["note"], "no-wake-kind")
        self.assertEqual(stub.calls, [])


# ---------------------------------------------------------------------------
# retry / attempt budget
# ---------------------------------------------------------------------------

class TestAttempts(DeliverTestCase):

    def test_retry_then_failed_after_max_attempts(self):
        message_id = store.send(self.conn, "Advisor", ["Reviewer"], "turn", "nope")
        stub = StubRun(returncode=1, stderr="boom")
        for _ in range(store.MAX_ATTEMPTS):
            self.assertEqual(self.run_deliver("--adapter", "exec", "--cmd", "false",
                                              "--retry-backoff", "0", "--once", run=stub), 0)
        self.assertEqual(self.state_of(message_id), "failed")
        self.assertEqual(self.delivery(message_id)["attempts"], store.MAX_ATTEMPTS)
        self.assertEqual(len(stub.calls), store.MAX_ATTEMPTS)
        # a further pass must not touch the adapter again
        self.assertEqual(self.run_deliver("--adapter", "exec", "--cmd", "false",
                                          "--retry-backoff", "0", "--once", run=stub), 0)
        self.assertEqual(len(stub.calls), store.MAX_ATTEMPTS)

    def test_fifth_failed_attempt_fails_immediately(self):
        message_id = store.send(self.conn, "Advisor", ["Reviewer"], "turn", "nope")
        stub = StubRun(returncode=1)
        for _ in range(store.MAX_ATTEMPTS):
            self.run_deliver("--adapter", "exec", "--cmd", "false", "--retry-backoff", "0",
                             "--once", run=stub)
        rows = self.attempt_rows()
        self.assertEqual(len(rows), store.MAX_ATTEMPTS)
        self.assertEqual([row["ok"] for row in rows], [0] * store.MAX_ATTEMPTS)
        self.assertEqual(self.state_of(message_id), "failed")
        self.assertEqual(self.delivery(message_id)["note"], "attempts-exhausted")

    def test_redelivery_without_receive_caps_at_max_attempts(self):
        message_id = store.send(self.conn, "Advisor", ["Reviewer"], "turn", "again")
        stub = StubRun(returncode=0, stdout="ok")
        for _ in range(store.MAX_ATTEMPTS):
            self.assertEqual(self.run_deliver("--adapter", "exec", "--cmd", "true",
                                              "--redeliver-after", "0", "--once", run=stub), 0)
        self.assertEqual(self.delivery(message_id)["attempts"], store.MAX_ATTEMPTS)
        self.assertEqual(self.state_of(message_id), "delivered")
        rows = self.attempt_rows()
        self.assertEqual([row["ok"] for row in rows], [1] * store.MAX_ATTEMPTS)
        # budget spent: the next pass gives up instead of signalling a sixth time
        self.assertEqual(self.run_deliver("--adapter", "exec", "--cmd", "true",
                                          "--redeliver-after", "0", "--once", run=stub), 0)
        self.assertEqual(len(stub.calls), store.MAX_ATTEMPTS)
        self.assertEqual(len(self.attempt_rows()), store.MAX_ATTEMPTS)
        self.assertEqual(self.state_of(message_id), "failed")

    def test_reservation_survives_crash_before_result(self):
        message_id = store.send(self.conn, "Advisor", ["Reviewer"], "turn", "crash")

        def crash(cmd):
            raise KeyboardInterrupt()

        stub = StubRun(before=crash)
        self.assertEqual(self.run_deliver("--adapter", "exec", "--cmd", "true",
                                          "--max-per-hour", "1", "--once", run=stub), 0)
        self.assertEqual(self.delivery(message_id)["attempts"], 1)
        rows = self.attempt_rows()
        self.assertEqual(len(rows), 1)
        self.assertIsNone(rows[0]["ok"])
        # the unknown-outcome row still counts against the hourly budget
        ok_stub = StubRun(returncode=0)
        self.assertEqual(self.run_deliver("--adapter", "exec", "--cmd", "true",
                                          "--max-per-hour", "1", "--once", run=ok_stub), 0)
        self.assertEqual(ok_stub.calls, [])
        self.assertIn("RATE_LIMIT", self.log_text())

    def test_adapter_failure_after_lease_expiry_counts_attempts(self):
        message_id = store.send(self.conn, "Advisor", ["Reviewer"], "turn", "lease")
        self.run_deliver("--adapter", "exec", "--cmd", "true", "--once",
                         run=StubRun(returncode=0))
        self.assertEqual(self.state_of(message_id), "delivered")
        self.run_deliver("--adapter", "exec", "--cmd", "false", "--redeliver-after", "0",
                         "--retry-backoff", "0", "--once", run=StubRun(returncode=1))
        self.assertEqual(self.delivery(message_id)["attempts"], 2)
        self.assertEqual(self.state_of(message_id), "delivered")
        self.assertEqual(self.attempt_rows()[-1]["ok"], 0)

    def test_once_failure_does_not_starve_other_threads(self):
        """A failing first message must not eat the whole `--once` run (one try each)."""
        first = store.send(self.conn, "Advisor", ["Reviewer"], "turn", "a1", thread="a")
        second = store.send(self.conn, "Advisor", ["Reviewer"], "turn", "b1", thread="b")
        stub = StubRun(returncode=1, stderr="boom")
        self.assertEqual(self.run_deliver("--adapter", "exec", "--cmd", "false",
                                          "--retry-backoff", "0", "--once", run=stub), 0)
        self.assertEqual(len(stub.calls), 2)
        self.assertEqual(self.delivery(first)["attempts"], 1)
        self.assertEqual(self.delivery(second)["attempts"], 1)
        self.assertEqual(self.state_of(first), "pending")
        self.assertEqual(self.state_of(second), "pending")

    def test_once_gives_each_message_exactly_one_attempt(self):
        """Even with the lease disabled, `--once` never signals the same id twice."""
        message_id = store.send(self.conn, "Advisor", ["Reviewer"], "turn", "once")
        stub = StubRun(returncode=0)
        self.assertEqual(self.run_deliver("--adapter", "exec", "--cmd", "true",
                                          "--redeliver-after", "0", "--once", run=stub), 0)
        self.assertEqual(len(stub.calls), 1)
        self.assertEqual(self.delivery(message_id)["attempts"], 1)

    def test_requeue_after_failed_delivers_again(self):
        message_id = store.send(self.conn, "Advisor", ["Reviewer"], "turn", "retry me")
        for _ in range(store.MAX_ATTEMPTS):
            self.run_deliver("--adapter", "exec", "--cmd", "false", "--retry-backoff", "0",
                             "--once", run=StubRun(returncode=1))
        self.assertEqual(self.state_of(message_id), "failed")
        done = subprocess.run(
            [sys.executable, CLI, "--box", self.box, "requeue", str(message_id),
             "--for", "Reviewer", "--by", "Operator"], capture_output=True, text=True, timeout=30)
        self.assertEqual(done.returncode, 0, done.stderr)
        stub = StubRun(returncode=0)
        self.assertEqual(self.run_deliver("--adapter", "exec", "--cmd", "true", "--once",
                                          run=stub), 0)
        self.assertEqual(self.state_of(message_id), "delivered")
        self.assertEqual(self.delivery(message_id)["attempts"], 1)
        self.assertEqual(len(stub.calls), 1)


# ---------------------------------------------------------------------------
# governors: rate limit, pause, in-flight, lock
# ---------------------------------------------------------------------------

class TestGovernors(DeliverTestCase):

    def test_rate_limit_stops_delivery(self):
        first = store.send(self.conn, "Advisor", ["Reviewer"], "turn", "one", thread="a")
        second = store.send(self.conn, "Advisor", ["Reviewer"], "turn", "two", thread="b")
        stub = StubRun(returncode=0)
        self.assertEqual(self.run_deliver("--adapter", "exec", "--cmd", "true",
                                          "--max-per-hour", "1", "--once", run=stub), 0)
        self.assertEqual(self.state_of(first), "delivered")
        self.assertEqual(self.state_of(second), "pending")
        self.assertEqual(len(stub.calls), 1)
        self.assertIn("RATE_LIMIT", self.log_text())

    def test_rate_limit_counts_attempts_not_rows(self):
        store.send(self.conn, "Advisor", ["Reviewer"], "turn", "one")
        stub = StubRun(returncode=0)
        for _ in range(2):
            self.run_deliver("--adapter", "exec", "--cmd", "true", "--max-per-hour", "2",
                             "--redeliver-after", "0", "--once", run=stub)
        self.assertEqual(len(stub.calls), 2)
        self.run_deliver("--adapter", "exec", "--cmd", "true", "--max-per-hour", "2",
                         "--redeliver-after", "0", "--once", run=stub)
        self.assertEqual(len(stub.calls), 2)          # third attempt refused
        self.assertIn("RATE_LIMIT", self.log_text())

    def test_pause_skips(self):
        message_id = store.send(self.conn, "Advisor", ["Reviewer"], "turn", "later")
        store.set_paused(self.conn, "Reviewer", True)
        stub = StubRun(returncode=0)
        self.assertEqual(self.run_deliver("--adapter", "exec", "--cmd", "true", "--once",
                                          run=stub), 0)
        self.assertEqual(stub.calls, [])
        self.assertEqual(self.state_of(message_id), "pending")
        self.assertIn("paused", self.log_text())

    def test_in_flight_blocks_second_delivery_same_thread_only(self):
        first = store.send(self.conn, "Advisor", ["Reviewer"], "turn", "a1", thread="a")
        second = store.send(self.conn, "Advisor", ["Reviewer"], "turn", "a2", thread="a")
        third = store.send(self.conn, "Advisor", ["Reviewer"], "turn", "b1", thread="b")
        stub = StubRun(returncode=0)
        self.assertEqual(self.run_deliver("--adapter", "exec", "--cmd", "true", "--once",
                                          run=stub), 0)
        self.assertEqual(self.state_of(first), "delivered")
        self.assertEqual(self.state_of(third), "delivered")
        self.assertEqual(self.state_of(second), "pending")
        self.assertIn("IN_FLIGHT id=%s" % (second,), self.log_text())
        # closing the blocking message frees the thread
        store.ack(self.conn, first, "Reviewer")
        self.assertEqual(self.run_deliver("--adapter", "exec", "--cmd", "true", "--once",
                                          run=stub), 0)
        self.assertEqual(self.state_of(second), "delivered")

    def test_ack_during_adapter_not_overwritten(self):
        message_id = store.send(self.conn, "Advisor", ["Reviewer"], "turn", "racy")

        def ack_first(cmd):
            store.ack(self.conn, message_id, "Reviewer")

        stub = StubRun(returncode=0, before=ack_first)
        self.assertEqual(self.run_deliver("--adapter", "exec", "--cmd", "true", "--once",
                                          run=stub), 0)
        self.assertEqual(self.state_of(message_id), "processed")
        self.assertIn("already=processed", self.log_text())
        self.assertEqual(self.attempt_rows()[-1]["ok"], 1)

    def test_single_instance_lock(self):
        store.send(self.conn, "Advisor", ["Reviewer"], "turn", "locked")
        held = store.acquire_lock(store.lock_path(self.box, "deliver", "Reviewer"))
        self.assertIsNotNone(held)
        try:
            stub = StubRun(returncode=0)
            self.assertEqual(self.run_deliver("--adapter", "exec", "--cmd", "true", "--once",
                                              run=stub), 2)
            self.assertEqual(stub.calls, [])
        finally:
            held.close()

    def test_wait_lock_blocks_deliver(self):
        store.send(self.conn, "Advisor", ["Reviewer"], "turn", "waiting")
        held = store.acquire_lock(store.lock_path(self.box, "wait", "Reviewer"))
        self.assertIsNotNone(held)
        try:
            stub = StubRun(returncode=0)
            self.assertEqual(self.run_deliver("--adapter", "exec", "--cmd", "true", "--once",
                                              run=stub), 2)
            self.assertEqual(stub.calls, [])
        finally:
            held.close()


# ---------------------------------------------------------------------------
# configuration / adapters
# ---------------------------------------------------------------------------

class TestAdapterConfig(DeliverTestCase):

    def write_recipients(self, mapping):
        path = os.path.join(self.tmp, "recipients.json")
        with open(path, "w", encoding="utf-8") as fh:
            json.dump(mapping, fh)
        return path

    def test_refuses_monitor_recipient(self):
        self.write_recipients({"Advisor": {"adapter": "monitor"}})
        stub = StubRun(returncode=0)
        self.assertEqual(self.run_deliver("--once", recipient="Advisor", run=stub), 2)
        self.assertEqual(stub.calls, [])

    def test_claude_resume_requires_flag(self):
        store.send(self.conn, "Advisor", ["Reviewer"], "turn", "experimental")
        stub = StubRun(returncode=0)
        self.assertEqual(self.run_deliver("--adapter", "claude-resume", "--thread", "t1",
                                          "--once", run=stub), 1)
        self.assertEqual(stub.calls, [])

    def test_recipients_file_supplies_adapter(self):
        self.write_recipients({"Reviewer": {"adapter": "codex-queue", "thread": "01a0-uuid"}})
        message_id = store.send(self.conn, "Advisor", ["Reviewer"], "turn", "from file")
        stub = StubRun(returncode=0, stdout="Queued message abc for thread 01a0-uuid")
        self.assertEqual(self.run_deliver("--once", run=stub), 0)
        self.assertEqual(stub.calls[0][:4], ["codex", "queue", "--thread", "01a0-uuid"])
        self.assertEqual(self.state_of(message_id), "delivered")

    def test_codex_queue_command_shape(self):
        signal = "[agent-mail] NEW id=1 from=Advisor kind=turn"
        row = {"id": 1, "thread": "a"}
        self.assertEqual(
            deliver.build_command("codex-queue", "thread-uuid", None, signal, row, "Reviewer"),
            ["codex", "queue", "--thread", "thread-uuid", "--message", signal])
        ok = subprocess.CompletedProcess([], 0, "Queued message m for thread t", "")
        self.assertTrue(deliver._adapter_ok("codex-queue", ok))
        silent = subprocess.CompletedProcess([], 0, "", "")
        self.assertFalse(deliver._adapter_ok("codex-queue", silent))

    def test_codex_queue_without_confirmation_counts_as_failure(self):
        message_id = store.send(self.conn, "Advisor", ["Reviewer"], "turn", "quiet")
        stub = StubRun(returncode=0, stdout="")
        self.assertEqual(self.run_deliver("--adapter", "codex-queue", "--thread", "t1",
                                          "--retry-backoff", "0", "--once", run=stub), 0)
        self.assertEqual(self.state_of(message_id), "pending")
        self.assertEqual(self.attempt_rows()[-1]["ok"], 0)

    def test_exec_template_keeps_signal_as_one_argument(self):
        store.send(self.conn, "Advisor", ["Reviewer"], "turn", "one arg", thread="a")
        stub = StubRun(returncode=0)
        self.assertEqual(self.run_deliver("--adapter", "exec", "--cmd",
                                          "echo prefix {recipient} {id} {signal}", "--once",
                                          run=stub), 0)
        argv = stub.calls[0]
        self.assertEqual(argv[:4], ["echo", "prefix", "Reviewer", "1"])
        self.assertEqual(len(argv), 5)
        self.assertTrue(argv[4].startswith("[agent-mail] NEW id=1"))

    def test_adapter_timeout_counts_as_failed_attempt(self):
        message_id = store.send(self.conn, "Advisor", ["Reviewer"], "turn", "slow")

        def timeout(cmd):
            raise subprocess.TimeoutExpired(cmd, 60)

        stub = StubRun(before=timeout)
        self.assertEqual(self.run_deliver("--adapter", "exec", "--cmd", "true",
                                          "--retry-backoff", "0", "--once", run=stub), 0)
        self.assertEqual(self.state_of(message_id), "pending")
        self.assertEqual(self.delivery(message_id)["attempts"], 1)
        self.assertEqual(self.attempt_rows()[-1]["ok"], 0)


if __name__ == "__main__":
    unittest.main()
