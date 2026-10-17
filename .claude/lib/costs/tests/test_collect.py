"""End-to-end collect: idempotence, order-independent owner, partial line (spec TT-813)."""
import json
import unittest
import store

from tests import helpers

A, B = "sess-aaaa-orig", "sess-bbbb-fork"


def _session(session, base_minute, outputs):
    return [helpers.claude_assistant(session, f"2026-10-06T10:{base_minute + i:02d}:00Z",
                                     request_id=f"req_{i}", output=out)
            for i, out in enumerate(outputs)]


class CollectTest(unittest.TestCase):
    def test_collect_twice_is_idempotent(self):
        with helpers.TempEnv() as env:
            helpers.write_jsonl(env.claude_file(A), _session(A, 0, [10, 20, 30]))
            helpers.write_jsonl(env.codex_file("x"), [
                helpers.codex_meta("thr", "2026-10-06T10:00:00Z"),
                helpers.codex_usage("thr", "t1", "resp_1", "2026-10-06T10:00:01Z")])
            env.collect()
            conn = env.conn()
            first = helpers.usage_sums(conn)
            self.assertEqual(env.collect(), 0)
            self.assertEqual(helpers.usage_sums(conn), first)
            self.assertEqual(first[0], 4)

    def _fork_run(self, order):
        with helpers.TempEnv() as env:
            # The fork starts later, rewrites sessionId to its own and has a longer last chunk.
            files = {A: (env.claude_file(A), _session(A, 0, [10, 20, 30])),
                     B: (env.claude_file(B), _session(B, 5, [10, 20, 99]))}
            for session in order:
                helpers.write_jsonl(*files[session])
                env.collect()
            conn = env.conn()
            rows = conn.execute("SELECT response_key, session, output, occurrence_count FROM"
                                " usage ORDER BY response_key").fetchall()
            return [tuple(r) for r in rows], helpers.reasons(conn, "claude", A)

    def test_fork_same_owner_whatever_the_order(self):
        ab, flags_ab = self._fork_run([A, B])
        ba, flags_ba = self._fork_run([B, A])
        self.assertEqual(ab, ba)
        self.assertEqual({r[1] for r in ab}, {A})
        self.assertEqual([r[2] for r in ab], [10, 20, 99])
        self.assertTrue(all(r[3] == 2 for r in ab))
        self.assertIn("ambiguous-owner", flags_ab)
        self.assertIn("ambiguous-owner", flags_ba)

    def test_partial_line_completed_adds_exactly_that_response(self):
        with helpers.TempEnv() as env:
            last = json.dumps(helpers.claude_assistant(A, "2026-10-06T10:09:00Z", "req_9",
                                                       output=77, inp=3, cache_write=5))
            helpers.write_jsonl(env.claude_file(A), _session(A, 0, [10, 20]),
                                trailing_partial=last[:30])
            env.collect()
            conn = env.conn()
            before = helpers.usage_sums(conn)
            self.assertIn("pending-partial-line", helpers.reasons(conn, "claude", A))
            with open(env.claude_file(A), "a") as fh:
                fh.write(last[30:] + "\n")
            env.collect()
            after = helpers.usage_sums(conn)
            self.assertEqual(tuple(a - b for a, b in zip(after, before)), (1, 3, 5, 0, 77))
            self.assertNotIn("pending-partial-line", helpers.reasons(conn, "claude", A))


    def test_ambiguity_cleared_only_when_all_remaining_keys_resolve(self):
        with helpers.TempEnv() as env:
            for session, minute in ((A, 0), (B, 5)):
                helpers.write_jsonl(env.claude_file(session), _session(session, minute, [10, 20]))
            env.collect()
            conn = env.conn()
            conn.execute("DELETE FROM occurrences WHERE session = ? AND response_key = ?",
                         (B, "req_0"))
            store.recompute(conn, {("claude", "req_0")})
            self.assertIn("ambiguous-owner", helpers.reasons(conn, "claude", A))
            conn.execute("DELETE FROM occurrences WHERE session = ?", (B,))
            store.recompute(conn, {("claude", "req_1")})
            self.assertNotIn("ambiguous-owner", helpers.reasons(conn, "claude", A))


if __name__ == "__main__":
    unittest.main()
