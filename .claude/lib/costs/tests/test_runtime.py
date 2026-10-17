"""Runtime log ingest: cursor, rewrite, validation, name resolution, v1→v2 upgrade (TT-821)."""
import os
import sqlite3
import unittest

import config
import runtime
import store
from tests import helpers

S1 = "0a1b2c3d-0000-4000-8000-000000000001"
S2 = "0a1b2c3d-0000-4000-8000-000000000002"
AT = "2026-10-06T10:00:00.123Z"


def reg(session=S1, source="mail-tt", name="OpusTT", provider="claude", **extra):
    return dict({"v": 1, "type": "session", "provider": provider, "session": session,
                 "source": source, "name": name, "at": AT}, **extra)


def mark(event="start", name="prime", session=S1, at=AT):
    return {"v": 1, "type": "stage", "session": session, "event": event, "name": name,
            "source": "hook-skill", "tool_use_id": "toolu_1", "at": at}


class RuntimeTest(unittest.TestCase):
    def setUp(self):
        self.env = helpers.TempEnv().__enter__()
        self.conn = self.env.conn()
        self.path = config.runtime_path()

    def tearDown(self):
        self.env.__exit__(None, None, None)

    def count(self, table):
        return self.conn.execute(f"SELECT COUNT(*) FROM {table}").fetchone()[0]

    def ingest(self, records, mode="w", partial=None):
        helpers.write_jsonl(self.path, records, trailing_partial=partial, mode=mode)
        return runtime.ingest(self.conn)

    def test_lines_land_in_tables(self):
        self.assertEqual(self.ingest([reg(), mark()]), 2)
        self.assertEqual((self.count("registrations"), self.count("stage_marks")), (1, 1))
        row = self.conn.execute("SELECT * FROM stage_marks").fetchone()
        self.assertEqual((row["ts"], row["event"], row["name"], row["tool_use_id"]),
                         (AT, "start", "prime", "toolu_1"))

    def test_cursor_append_and_partial_line(self):
        self.ingest([mark()])
        self.assertEqual(runtime.ingest(self.conn), 0)
        self.assertEqual(self.count("stage_marks"), 1)
        self.ingest([mark("end")], mode="a", partial='{"v": 1, "type": "st')
        self.assertEqual(self.count("stage_marks"), 2)
        with open(self.path, "a", encoding="utf-8") as fh:
            fh.write('age"}\n')
        self.ingest([mark("start", "execute")], mode="a")
        self.assertEqual(self.count("stage_marks"), 3)

    def test_rewrite_replaces_rows(self):
        self.ingest([mark(), mark("end")])
        self.ingest([mark("start", "execute", at="2026-10-06T11:00:00.000Z")])
        self.assertEqual([r[0] for r in self.conn.execute("SELECT name FROM stage_marks")],
                         ["execute"])

    def test_invalid_lines_skipped(self):
        self.ingest([dict(mark(), session="not-a-uuid"), dict(mark(), type="other"),
                     dict(mark(), event="pause"), dict(reg(), source="x"),
                     dict(mark(), at="yesterday"), mark()])
        self.assertEqual((self.count("registrations"), self.count("stage_marks")), (0, 1))

    def test_resolve_name(self):
        self.ingest([reg(source="start-team"), reg(source="mail-tt"),
                     reg(session=S2, name="AstraTT"), reg(session=S2, name="Twin", source="x")])
        self.assertEqual(runtime.resolve_name(self.conn, "OpusTT"), S1)
        self.assertEqual(runtime.resolve_name(self.conn, S2), S2)
        for value in ("missing", "Twin"):
            with self.assertRaises(SystemExit) as ctx:
                runtime.resolve_name(self.conn, value)
            self.assertEqual(ctx.exception.code, 2)
        self.ingest([reg(session=S2, name="OpusTT")], mode="a")
        with self.assertRaises(SystemExit) as ctx:
            runtime.resolve_name(self.conn, "OpusTT")
        self.assertEqual(ctx.exception.code, 2)

    def test_v1_db_upgrades(self):
        path = os.path.join(self.env.root, "v1.sqlite")
        conn = sqlite3.connect(path)
        conn.executescript("CREATE TABLE files(path TEXT PRIMARY KEY, provider TEXT);"
                           "CREATE TABLE usage(provider TEXT, response_key TEXT,"
                           " PRIMARY KEY(provider, response_key));"
                           "PRAGMA user_version = 1;")
        conn.close()
        conn = store.connect(path)
        store.migrate(conn)
        tables = {r[0] for r in conn.execute("SELECT name FROM sqlite_master WHERE type='table'")}
        self.assertTrue({"registrations", "stage_marks"} <= tables)
        self.assertEqual(conn.execute("PRAGMA user_version").fetchone()[0], 2)


if __name__ == "__main__":
    unittest.main()
