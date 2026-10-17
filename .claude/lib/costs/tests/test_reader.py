"""Incremental reader: append, partial line, rewrite after 4096 bytes, truncation, rotation."""
import json
import os
import unittest

import reader
from tests import helpers

S = "sess-reader"


def _line(n, pad=0):
    return helpers.claude_assistant(S, f"2026-10-06T10:00:{n:02d}Z", request_id=f"req_{n}",
                                    content=[{"type": "text", "text": "x" * pad}])


class ReaderTest(unittest.TestCase):
    def setUp(self):
        self.env = helpers.TempEnv().__enter__()
        self.conn = self.env.conn()
        self.path = self.env.claude_file(S)

    def tearDown(self):
        self.env.__exit__(None, None, None)

    def read(self):
        return reader.read_new(self.conn, self.path, "claude", session=S, agent_id="")

    def test_append_only_returns_new_lines(self):
        helpers.write_jsonl(self.path, [_line(1), _line(2)])
        self.assertEqual(len(self.read().lines), 2)
        helpers.write_jsonl(self.path, [_line(3)], mode="a")
        second = self.read()
        self.assertFalse(second.reset)
        self.assertEqual([o for o, _, _ in second.lines], [2])
        self.assertEqual(len(self.read().lines), 0)

    def test_partial_line_waits_until_completed(self):
        partial = json.dumps(_line(2))
        helpers.write_jsonl(self.path, [_line(1)], trailing_partial=partial[:20])
        first = self.read()
        self.assertEqual(len(first.lines), 1)
        self.assertTrue(first.pending_partial)
        with open(self.path, "a") as fh:
            fh.write(partial[20:] + "\n")
        second = self.read()
        self.assertFalse(second.pending_partial)
        self.assertEqual(reader.parse(second.lines[0][2])["requestId"], "req_2")

    def test_same_size_rewrite_after_4096_resets(self):
        helpers.write_jsonl(self.path, [_line(1, pad=5000), _line(2)])
        self.read()
        size, inode = os.path.getsize(self.path), os.stat(self.path).st_ino
        with open(self.path, "r+b") as fh:
            data = fh.read()
            pos = data.index(b'"output_tokens": 10', 4096)
            fh.seek(pos)
            fh.write(b'"output_tokens": 99')
        self.assertEqual((os.path.getsize(self.path), os.stat(self.path).st_ino), (size, inode))
        again = self.read()
        self.assertTrue(again.reset)
        outputs = [reader.parse(r)["message"]["usage"]["output_tokens"] for _, _, r in again.lines]
        self.assertIn(99, outputs)

    def test_truncation_resets(self):
        helpers.write_jsonl(self.path, [_line(1), _line(2)])
        self.read()
        helpers.write_jsonl(self.path, [_line(1)])
        self.assertTrue(self.read().reset)

    def test_rotation_resets(self):
        helpers.write_jsonl(self.path, [_line(1)])
        self.read()
        tmp = self.path + ".tmp"
        helpers.write_jsonl(tmp, [_line(1), _line(2)])
        os.replace(tmp, self.path)
        rotated = self.read()
        self.assertTrue(rotated.reset)
        self.assertEqual(len(rotated.lines), 2)

    def test_reset_clears_old_flags_and_first_ts(self):
        os.makedirs(os.path.dirname(self.path))
        with open(self.path, "w") as fh:
            fh.write(json.dumps(_line(1)) + "\n{broken\n" + json.dumps(_line(3)) + "\n")
        self.assertEqual(self.env.collect(), 0)
        self.assertIn("bad-json", helpers.reasons(self.conn, "claude", S))
        first = self.conn.execute("SELECT first_ts FROM sessions WHERE session = ?",
                                  (S,)).fetchone()[0]
        self.assertEqual(first, "2026-10-06T10:00:01.000Z")
        tmp = self.path + ".tmp"
        helpers.write_jsonl(tmp, [_line(3)])
        os.replace(tmp, self.path)
        self.assertEqual(self.env.collect(), 0)
        self.assertNotIn("bad-json", helpers.reasons(self.conn, "claude", S))
        first = self.conn.execute("SELECT first_ts FROM sessions WHERE session = ?",
                                  (S,)).fetchone()[0]
        self.assertEqual(first, "2026-10-06T10:00:03.000Z")
        self.assertEqual(helpers.usage_sums(self.conn)[0], 1)


if __name__ == "__main__":
    unittest.main()
