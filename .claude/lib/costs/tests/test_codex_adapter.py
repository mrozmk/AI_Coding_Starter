"""Codex adapter: normalization, turns, fallback, replay, two-pass, scope (spec TT-813)."""
import unittest
import json
import os
from contextlib import closing, redirect_stdout
import io

import cost

from tests import helpers

T = "01a1-thread-parent"
C = "01a1-thread-child"


def _ts(n):
    return f"2026-10-06T10:{n // 60:02d}:{n % 60:02d}Z"


class CodexFixture(unittest.TestCase):
    def setUp(self):
        self.env = helpers.TempEnv().__enter__()
        self.conn = self.env.conn()

    def tearDown(self):
        self.env.__exit__(None, None, None)

    def write(self, name, records, mode="w"):
        helpers.write_jsonl(self.env.codex_file(name), records, mode=mode)

    def usage(self, session=None):
        sql = "SELECT * FROM usage" + (" WHERE session = ?" if session else "")
        return self.conn.execute(sql + " ORDER BY ts, response_key",
                                 (session,) if session else ()).fetchall()


class CodexAdapterTest(CodexFixture):
    def test_normalization(self):
        self.write("a", [helpers.codex_meta(T, _ts(0)), helpers.codex_turn("t1", _ts(1)),
                         helpers.codex_usage(T, "t1", "resp_1", _ts(2))])
        self.env.collect()
        row = self.usage()[0]
        self.assertEqual((row["input"], row["cache_read"], row["cache_write"], row["output"]),
                         (20506 - 4864, 4864, 0, 333))
        self.assertEqual(row["reasoning"], 267)
        self.assertEqual((row["model"], row["effort"], row["cwd"]),
                         ("gpt-6.1-sol", "high", helpers.PROJ))

    def test_incomplete_usage_flags_partial_and_adds_no_row(self):
        bad = helpers.codex_usage(T, "t1", "resp_2", _ts(3))
        del bad["payload"]["usage"]["output_tokens"]
        self.write("a", [helpers.codex_meta(T, _ts(0)), helpers.codex_turn("t1", _ts(1)),
                         helpers.codex_usage(T, "t1", "resp_1", _ts(2)), bad])
        self.env.collect()
        self.assertEqual([r["response_key"] for r in self.usage()], ["resp_1"])
        self.assertIn("missing-usage", helpers.reasons(self.conn, "codex", T))

    def test_model_switch_two_rows(self):
        self.write("a", [helpers.codex_meta(T, _ts(0)), helpers.codex_turn("t1", _ts(1)),
                         helpers.codex_usage(T, "t1", "resp_1", _ts(2)),
                         helpers.codex_turn("t2", _ts(3), model="gpt-6.1-mini", effort="low"),
                         helpers.codex_usage(T, "t2", "resp_2", _ts(4))])
        self.env.collect()
        self.assertEqual([(r["model"], r["effort"]) for r in self.usage()],
                         [("gpt-6.1-sol", "high"), ("gpt-6.1-mini", "low")])

    def test_records_win_over_token_count(self):
        self.write("a", [helpers.codex_meta(T, _ts(0)), helpers.codex_turn("t1", _ts(1)),
                         helpers.codex_usage(T, "t1", "resp_1", _ts(2)),
                         helpers.codex_token_count(_ts(3), 20506, 4864, 333)])
        self.env.collect()
        self.assertEqual([r["response_key"] for r in self.usage()], ["resp_1"])

    def test_token_count_fallback_deltas(self):
        self.write("a", [helpers.codex_meta(T, _ts(0)), helpers.codex_turn("t1", _ts(1)),
                         helpers.codex_token_count(_ts(2), 100, 0, 10),
                         helpers.codex_token_count(_ts(3), 100, 0, 10),
                         helpers.codex_token_count(_ts(4), 150, 0, 20),
                         helpers.codex_token_count(_ts(5), 30, 0, 5),
                         helpers.codex_token_count(_ts(6), 40, 0, 6),
                         helpers.codex_token_count(_ts(7), 0, info=False)])
        self.env.collect()
        rows = self.usage()
        self.assertEqual([(r["input"], r["output"]) for r in rows],
                         [(100, 10), (50, 10), (10, 1)])
        self.assertTrue(all(r["source_kind"] == "token_count" for r in rows))
        self.assertEqual(rows[0]["model"], "gpt-6.1-sol")
        self.assertTrue({"token-count-fallback", "counter-discontinuity"}
                        <= helpers.reasons(self.conn, "codex", T))

    def test_cache_write_flag(self):
        self.write("a", [helpers.codex_meta(T, _ts(0)),
                         helpers.codex_usage(T, "t1", "resp_1", _ts(2), cache_write=7)])
        self.env.collect()
        self.assertEqual(self.usage()[0]["cache_write"], 7)
        self.assertIn("codex-cache-write-unverified", helpers.reasons(self.conn, "codex", T))

    def test_out_of_scope_rollout_skipped(self):
        self.write("a", [helpers.codex_meta(T, _ts(0), cwd="/private/tmp/wt"),
                         helpers.codex_usage(T, "t1", "resp_1", _ts(2))])
        self.env.collect()
        self.assertEqual(len(self.usage()), 0)
        self.assertEqual(self.conn.execute("SELECT COUNT(*) FROM sessions").fetchone()[0], 0)
        self.assertEqual(self.conn.execute("SELECT skipped FROM files").fetchone()[0], 1)

    def test_subagent_replay_counted_once_owned_by_parent(self):
        self.write("parent", [helpers.codex_meta(T, _ts(0)),
                              helpers.codex_usage(T, "t1", "resp_1", _ts(1), ordinal=1),
                              helpers.codex_usage(T, "t2", "resp_2", _ts(2), ordinal=2)])
        self.write("child", [
            helpers.codex_meta(C, _ts(3), parent=T, start=3,
                               source={"subagent": {"other": "guardian"}}),
            helpers.codex_usage(T, "t1", "resp_1", _ts(1), ordinal=1),
            helpers.codex_usage(T, "t2", "resp_2", _ts(2), ordinal=2),
            helpers.codex_usage(C, "t3", "resp_3", _ts(4), ordinal=3)])
        self.env.collect()
        owners = {r["response_key"]: r["session"] for r in self.usage()}
        self.assertEqual(owners, {"resp_1": T, "resp_2": T, "resp_3": C})
        child = self.usage(C)[0]
        self.assertEqual(child["parent_session"], T)
        label = self.conn.execute("SELECT source_label FROM sessions WHERE session = ?",
                                  (C,)).fetchone()[0]
        self.assertEqual(label, "codex:subagent:guardian")

    def test_two_pass_append_keeps_session_state(self):
        self.write("a", [helpers.codex_meta(T, _ts(0)), helpers.codex_turn("t1", _ts(1)),
                         helpers.codex_usage(T, "t1", "resp_1", _ts(2))])
        self.env.collect()
        self.write("a", [helpers.codex_turn("t2", _ts(3), model="gpt-6.1-mini"),
                         helpers.codex_usage(T, "t2", "resp_2", _ts(4)),
                         helpers.codex_token_count(_ts(5), 1, 0, 1)], mode="a")
        self.env.collect()
        row = self.conn.execute("SELECT * FROM usage WHERE response_key = 'resp_2'").fetchone()
        self.assertEqual((row["session"], row["cwd"], row["model"]),
                         (T, helpers.PROJ, "gpt-6.1-mini"))
        occ = self.conn.execute("SELECT is_copy FROM occurrences WHERE response_key = 'resp_2'"
                                ).fetchone()[0]
        self.assertEqual(occ, 0)
        self.assertNotIn("history-starts-mid-session", helpers.reasons(self.conn, "codex", T))

    def test_representation_switch_drops_fallback_rows(self):
        self.write("a", [helpers.codex_meta(T, _ts(0)),
                         helpers.codex_token_count(_ts(1), 100, 0, 10)])
        self.env.collect()
        self.assertEqual(self.usage()[0]["response_key"][:3], "tc:")
        self.write("a", [helpers.codex_usage(T, "t1", "resp_1", _ts(2))], mode="a")
        self.env.collect()
        self.assertEqual([r["response_key"] for r in self.usage()], ["resp_1"])
        self.assertNotIn("token-count-fallback", helpers.reasons(self.conn, "codex", T))

    def test_fallback_replay_baseline(self):
        self.write("parent", [helpers.codex_meta(T, _ts(0)),
                              helpers.codex_token_count(_ts(1), 10, ordinal=1)])
        self.write("child", [helpers.codex_meta(C, _ts(2), parent=T, start=2),
                             helpers.codex_token_count(_ts(1), 10, ordinal=1),
                             helpers.codex_token_count(_ts(3), 15, ordinal=2)])
        self.env.collect()
        self.assertEqual(sum(r["input"] for r in self.usage(T)), 10)
        self.assertEqual(sum(r["input"] for r in self.usage(C)), 5)

    def test_config_change_ingests_skipped_rollout(self):
        self.write("a", [helpers.codex_meta(T, _ts(0), cwd="/work/other"),
                         helpers.codex_usage(T, "t1", "resp_1", _ts(2))])
        self.env.collect()
        self.assertEqual(len(self.usage()), 0)
        self.env.write_config(self.env.dirs + ["/work/other"])
        self.env.collect()
        self.assertEqual([r["response_key"] for r in self.usage()], ["resp_1"])


class CodexScopeTest(CodexFixture):
    def projects(self, mapping, env=None):
        path = os.path.join((env or self.env).root, "config.json")
        with open(path) as fh:
            cfg = json.load(fh)
        cfg["projects"] = mapping
        with open(path, "w") as fh:
            json.dump(cfg, fh)

    def test_scope_reassign_remove_and_reenter_without_appends(self):
        self.write("a", [helpers.codex_meta(T, _ts(0)),
                         helpers.codex_usage(T, "t1", "resp_1", _ts(1))])
        self.env.collect()
        self.projects({"renamed": [helpers.PROJ]})
        self.env.collect()
        for table in ("files", "sessions", "occurrences", "usage"):
            self.assertEqual(self.conn.execute(f"SELECT project FROM {table}").fetchone()[0],
                             "renamed")
        self.projects({"other": ["/work/outside"]})
        self.env.collect()
        self.assertEqual(len(self.usage()), 0)
        self.assertEqual(self.conn.execute("SELECT COUNT(*) FROM occurrences").fetchone()[0], 0)
        self.projects({"back": [helpers.PROJ]})
        self.env.collect()
        self.assertEqual(self.usage()[0]["project"], "back")

    def test_rotation_and_rewrite_recheck_header_scope(self):
        for rotate in (False, True):
            for cwd, project in (("/work/other", "other"), ("/work/outside", None)):
                with self.subTest(rotate=rotate, cwd=cwd), helpers.TempEnv() as env:
                    self.projects({"proj": [helpers.PROJ], "other": ["/work/other"]}, env)
                    path = env.codex_file("a")
                    helpers.write_jsonl(path, [helpers.codex_meta(T, _ts(0)),
                                              helpers.codex_usage(T, "t1", "old", _ts(1))])
                    env.collect()
                    replacement = path + ".tmp" if rotate else path
                    helpers.write_jsonl(replacement, [helpers.codex_meta(C, _ts(2), cwd=cwd),
                                                       helpers.codex_usage(C, "t2", "new", _ts(3))])
                    if rotate:
                        os.replace(replacement, path)
                    env.collect()
                    with closing(env.conn()) as conn:
                        self.assertIsNone(conn.execute(
                            "SELECT 1 FROM usage WHERE response_key = 'old'").fetchone())
                        rows = conn.execute("SELECT project FROM usage").fetchall()
                        self.assertEqual([r[0] for r in rows], [project] if project else [])

    def test_scoped_collect_preserves_reassigned_other_project(self):
        for change in ("config", "header"):
            with self.subTest(change=change), helpers.TempEnv() as env:
                self.projects({"target": ["/work/target"], "old": ["/work/old"],
                               "new": ["/work/new"]}, env)
                path = env.codex_file("a")
                helpers.write_jsonl(path, [helpers.codex_meta(T, _ts(0), cwd="/work/old"),
                                          helpers.codex_usage(T, "t1", "old", _ts(1))])
                env.collect()
                if change == "config":
                    self.projects({"target": ["/work/target"], "new": ["/work/old"]}, env)
                else:
                    helpers.write_jsonl(path, [helpers.codex_meta(C, _ts(2), cwd="/work/new"),
                                              helpers.codex_usage(C, "t2", "new", _ts(3))])
                with redirect_stdout(io.StringIO()):
                    self.assertEqual(cost.main(["collect", "--project", "target"]), 0)
                with closing(env.conn()) as conn:
                    rows = conn.execute("SELECT project, response_key FROM usage").fetchall()
                    self.assertEqual([tuple(r) for r in rows],
                                     [("new", "old" if change == "config" else "new")])

    def test_unchanged_skipped_rollout_does_not_mutate_cursor(self):
        self.write("a", [helpers.codex_meta(T, _ts(0), cwd="/work/outside"),
                         helpers.codex_usage(T, "t1", "resp_1", _ts(1))])
        self.env.collect()
        self.conn.executescript("""
            CREATE TABLE mutations(kind TEXT);
            CREATE TRIGGER cursor_insert AFTER INSERT ON files BEGIN
              INSERT INTO mutations VALUES ('insert'); END;
            CREATE TRIGGER cursor_delete AFTER DELETE ON files BEGIN
              INSERT INTO mutations VALUES ('delete'); END;
            CREATE TRIGGER cursor_update AFTER UPDATE ON files BEGIN
              INSERT INTO mutations VALUES ('update'); END;
        """)
        self.env.collect()
        self.env.collect()
        self.assertEqual(self.conn.execute("SELECT COUNT(*) FROM mutations").fetchone()[0], 0)
        self.assertEqual(self.conn.execute("SELECT skipped FROM files").fetchone()[0], 1)

    def test_fallback_unchanged_and_partial_collects_do_not_rewrite(self):
        self.write("a", [helpers.codex_meta(T, _ts(0)),
                         helpers.codex_token_count(_ts(1), 10)])
        self.env.collect()
        self.conn.executescript("""
            CREATE TABLE mutations(kind TEXT);
            CREATE TRIGGER tc_insert AFTER INSERT ON occurrences
            WHEN NEW.source_kind = 'token_count' BEGIN
              INSERT INTO mutations VALUES ('insert'); END;
            CREATE TRIGGER tc_delete AFTER DELETE ON occurrences
            WHEN OLD.source_kind = 'token_count' BEGIN
              INSERT INTO mutations VALUES ('delete'); END;
        """)
        self.env.collect()
        record = json.dumps(helpers.codex_token_count(_ts(2), 20))
        with open(self.env.codex_file("a"), "a") as fh:
            fh.write(record[:20])
        self.env.collect()
        self.assertEqual(self.conn.execute("SELECT COUNT(*) FROM mutations").fetchone()[0], 0)
        with open(self.env.codex_file("a"), "a") as fh:
            fh.write(record[20:] + "\n")
        self.env.collect()
        self.assertGreater(self.conn.execute("SELECT COUNT(*) FROM mutations").fetchone()[0], 0)
        self.assertEqual(sum(r["input"] for r in self.usage()), 20)

    def test_reset_clears_history_boundary(self):
        self.write("a", [helpers.codex_meta(T, _ts(0), start=5),
                         helpers.codex_token_count(_ts(1), 10, ordinal=1),
                         helpers.codex_token_count(_ts(2), 20, ordinal=5)])
        self.env.collect()
        self.write("a", [helpers.codex_meta(T, _ts(0)),
                         helpers.codex_token_count(_ts(1), 7, ordinal=1)])
        self.env.collect()
        self.assertIsNone(self.conn.execute("SELECT history_start_ordinal FROM sessions"
                                             " WHERE session = ?", (T,)).fetchone()[0])
        self.assertEqual(sum(r["input"] for r in self.usage()), 7)


if __name__ == "__main__":
    unittest.main()
