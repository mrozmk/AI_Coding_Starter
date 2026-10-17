"""Jira comment: add/edit decision, ticket-exact marker, page limit, stable body (TT-821)."""
import json
import os
import unittest
from unittest import mock

import bindings
import config
import jira_comment
import report
from tests import helpers

S = "sess-jira-0001"


def comment(cid, body, created="2026-10-06T18:33:23.890+0200"):
    return {"id": cid, "body": body, "created": created, "author": {"displayName": "x"}}


class JiraCommentTest(unittest.TestCase):
    def decide(self, comments, ticket="TT-1"):
        return jira_comment.decide(comments, ticket, "BODY")

    def test_no_comments_adds(self):
        self.assertEqual(self.decide([]), {"action": "add", "comment_id": None,
                                           "duplicates": [], "body": "BODY"})

    def test_edits_newest_marker_and_lists_duplicates(self):
        got = self.decide([
            comment(15023, "token-usage-report: TT-1\n\nold", "2026-10-06T18:33:23.890+0200"),
            comment(15030, "unrelated"),
            comment(15041, "token-usage-report: TT-1\n\nnew", "2026-10-07T09:00:00.000+0200")])
        self.assertEqual((got["action"], got["comment_id"], got["duplicates"]),
                         ("edit", "15041", ["15023"]))

    def test_other_ticket_marker_does_not_match(self):
        others = [comment(n, f"token-usage-report: {t}\n\nx")
                  for n, t in enumerate(("TT-2", "TT-10", "TT-100"))]
        self.assertEqual(self.decide(others)["action"], "add")

    def test_full_page_without_marker_is_refused(self):
        with self.assertRaises(SystemExit) as ctx:
            self.decide([comment(n, "x") for n in range(100)])
        self.assertEqual(ctx.exception.code, 3)
        self.assertEqual(self.decide([comment(n, "x") for n in range(99)])["action"], "add")

    def test_load_comments_wrappings(self):
        with helpers.TempEnv() as env:
            path = os.path.join(env.root, "c.json")
            items = [comment("1", "x")]
            issue = {"key": "TT-1", "comments": items}
            for payload in (items, issue, {"result": json.dumps(issue)}):
                with open(path, "w", encoding="utf-8") as fh:
                    json.dump(payload, fh)
                self.assertEqual(jira_comment.load_comments(path), items)
            for bad in ('{"x": 1}', "not json"):
                with open(path, "w", encoding="utf-8") as fh:
                    fh.write(bad)
                with self.assertRaises(SystemExit) as ctx:
                    jira_comment.load_comments(path)
                self.assertEqual(ctx.exception.code, 2)

    def test_body_is_stable_and_starts_with_marker(self):
        with helpers.TempEnv() as env:
            helpers.write_jsonl(env.claude_file(S), [
                helpers.claude_assistant(S, "2026-10-06T10:00:00Z", "req_1")])
            env.collect()
            conn, cfg = env.conn(), env.cfg()
            bindings.add_binding(conn, cfg, "TT-1", session=S)
            bodies = []
            for now in ("2026-10-06T10:00:00.000Z", "2026-10-07T11:11:11.111Z"):
                with mock.patch.object(config, "now_ts", return_value=now):
                    data = report.build(conn, cfg, "TT-1", children=["TT-2"])
                    bodies.append(jira_comment.body(data))
            self.assertEqual(bodies[0], bodies[1])
            self.assertEqual(bodies[0].splitlines()[0], "token-usage-report: TT-1")
            self.assertNotIn("2026-10-07T11:11:11", bodies[1])
            self.assertIn("- Children: TT-2", bodies[0])


if __name__ == "__main__":
    unittest.main()
