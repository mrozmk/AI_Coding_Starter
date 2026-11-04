"""Jira comment: add/edit decision, ticket-exact marker, page limit, stable body."""
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
    def decide(self, comments, ticket="AB-1"):
        return jira_comment.decide(comments, ticket, "BODY")

    def save(self, root, payload):
        path = os.path.join(root, "c.json")
        with open(path, "w", encoding="utf-8") as fh:
            json.dump(payload, fh)
        return path

    def test_empty_read_is_refused(self):
        with self.assertRaises(SystemExit) as ctx:
            self.decide([])
        self.assertEqual(ctx.exception.code, 3)

    def test_missing_or_bad_keys_fail(self):
        bad = [{"body": "x"}, {"id": "", "body": "x"}, {"id": True, "body": "x"},
               {"id": "1"}, {"id": "1", "body": None}]
        with helpers.TempEnv() as env:
            for item in bad:
                path = self.save(env.root, [item])
                with self.assertRaises(SystemExit, msg=item) as ctx:
                    jira_comment.load_comments(path)
                self.assertEqual(ctx.exception.code, 2)
            ok = [{"id": 15023, "body": "x"}]
            self.assertEqual(jira_comment.load_comments(self.save(env.root, ok)), ok)

    def test_full_page_with_marker_edits(self):
        items = [comment(n, "x") for n in range(150)]
        items[120] = comment(120, "token-usage-report: AB-1\n\nreport")
        got = self.decide(items)
        self.assertEqual((got["action"], got["comment_id"]), ("edit", "120"))

    def test_mcp_shape_passes(self):
        def mcp(cid, text):
            return {"id": cid, "body": text, "created": "2026-10-06 19:07:18+00:00",
                    "updated": "2026-10-06 19:07:18+00:00",
                    "author": {"display_name": "Marek", "name": "Marek", "email": None}}
        wrapup = mcp("15100", "\\*\\*Wrap-up\\*\\* AB-1\n\n- merged\n\n"
                              "[wrapup alfa-20261006-190718 comment-1]")
        report_c = mcp("15101", "token-usage-report: AB-1\n\n# Token usage")
        with helpers.TempEnv() as env:
            for items, want in (([wrapup, report_c], ("edit", "15101")),
                                ([wrapup], ("add", None))):
                issue = {"key": "AB-1", "comments": items}
                path = self.save(env.root, {"result": json.dumps(issue)})
                loaded = jira_comment.load_comments(path)
                self.assertEqual(loaded, items)
                got = self.decide(loaded)
                self.assertEqual((got["action"], got["comment_id"]), want)

    def test_edits_newest_marker_and_lists_duplicates(self):
        got = self.decide([
            comment(15023, "token-usage-report: AB-1\n\nold", "2026-10-06T18:33:23.890+0200"),
            comment(15030, "unrelated"),
            comment(15041, "token-usage-report: AB-1\n\nnew", "2026-10-07T09:00:00.000+0200")])
        self.assertEqual((got["action"], got["comment_id"], got["duplicates"]),
                         ("edit", "15041", ["15023"]))

    def test_other_ticket_marker_does_not_match(self):
        others = [comment(n, f"token-usage-report: {t}\n\nx")
                  for n, t in enumerate(("AB-2", "AB-10", "AB-100"))]
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
            issue = {"key": "AB-1", "comments": items}
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
            bindings.add_binding(conn, cfg, "AB-1", session=S)
            bodies = []
            for now in ("2026-10-06T10:00:00.000Z", "2026-10-07T11:11:11.111Z"):
                with mock.patch.object(config, "now_ts", return_value=now):
                    data = report.build(conn, cfg, "AB-1", children=["AB-2"])
                    bodies.append(jira_comment.body(data))
            self.assertEqual(bodies[0], bodies[1])
            self.assertEqual(bodies[0].splitlines()[0], "token-usage-report: AB-1")
            self.assertNotIn("2026-10-07T11:11:11", bodies[1])
            self.assertIn("- Children: AB-2", bodies[0])


if __name__ == "__main__":
    unittest.main()
