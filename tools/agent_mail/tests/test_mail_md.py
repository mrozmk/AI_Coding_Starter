# Vendored from mrozmk/jarvis@c9c407c (tools/agent_mail/) — MIT, same terms and holder as LICENSE.
# Local delta and the re-sync procedure: tools/agent_mail/README.md → "Vendored copy".
"""
Offline unit tests for the `mail.md` bridge (parser, renderer, `import-md`/`export-md`).

The fixture is an INLINE string, never the legacy `mail.md` board: that file is the
Operator's live local board, gitignored and absent on a clean clone (patterns.md
2026-07-08, "tests OFFLINE"). It reproduces every header shape counted on the real
board — both arrows, the four time spellings, a multi-recipient address, a
`Wykonawca` sender, a repeated message number and the KONIEC TURY marker.
"""

import os
import shutil
import subprocess
import sys
import tempfile
import unittest

_PKG_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
if _PKG_DIR not in sys.path:
    sys.path.insert(0, _PKG_DIR)

import agent_mail_store as store   # noqa: E402
import mail_md                     # noqa: E402

CLI = os.path.join(_PKG_DIR, "agent_mail.py")

FIXTURE = u"""# mail.md — tablica ogloszen

Preambula z zasadami: ta sekcja nie jest wiadomoscia i musi zostac pominieta.

## MSG-001 | Reviewer → Advisor | 2026-09-15 08:42

Otwieram uzgodnienia.

--- KONIEC TURY MSG-001 · czekam na Advisor ---

## MSG-002 | Advisor → Reviewer | 2026-09-15

Odpowiadam bez godziny w naglowku.

--- KONIEC TURY MSG-002 · czekam na Reviewer ---

## MSG-003 | Reviewer -> Advisor | 2026-09-16 10:00 UTC

Naglowek ze strzalka ASCII.

## MSG-004 | Wykonawca K5 → Reviewer i Advisor | 2026-09-16 11:32 (zegar systemowy)

Raport wykonawcy.

--- KONIEC TURY MSG-004 · czekam na Advisor / raport P07 ---

## MSG-005 | Codex → Reviewer + Advisor | 2026-09-16 12:00

Adresaci rozdzieleni plusem, w naglowku spacja koncowa.

## MSG-143 | Advisor → Reviewer | 2026-09-17 00:44

Pierwsze cialo o powtorzonym numerze.

## MSG-143 | Advisor → Reviewer | 2026-09-17 02:34

Drugie cialo o tym samym numerze.
"""

BROKEN_HEADER = u"\n## MSG-9 | zepsuty\n\nCialo wiadomosci bez adresata.\n"
EMPTY_BODY = u"\n## MSG-006 | Reviewer → Advisor | 2026-09-17 09:00\n\n"


class MailMdTestCase(unittest.TestCase):
    """Fresh box + a fixture file per test; the CLI runs as a real subprocess."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="agent_mail_md_test_")
        self.box = os.path.join(self.tmp, "mail.sqlite")
        self.conn = store.open_box(self.box)

    def tearDown(self):
        self.conn.close()
        shutil.rmtree(self.tmp, ignore_errors=True)

    def write(self, text, name="mail.md"):
        path = os.path.join(self.tmp, name)
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(text)
        return path

    def cli(self, *argv):
        cmd = [sys.executable, CLI, "--box", self.box] + [str(a) for a in argv]
        return subprocess.run(cmd, capture_output=True, text=True, timeout=30)

    def message_count(self):
        return int(self.conn.execute("SELECT COUNT(*) FROM messages").fetchone()[0])

    # -- parser ------------------------------------------------------------

    def test_parse_counts_and_fields(self):
        parsed = mail_md.parse_mail_md(FIXTURE)
        self.assertEqual(len(parsed), 7)
        self.assertEqual(len(parsed), mail_md.count_headers(FIXTURE))
        self.assertEqual([m.legacy_id for m in parsed],
                         ["1", "2", "3", "4", "5", "143", "143"])

        first = parsed[0]
        self.assertEqual((first.sender, first.recipients, first.kind), ("Reviewer", ["Advisor"], "turn"))
        self.assertEqual(first.awaiting, "Advisor")
        self.assertNotIn("Preambula", first.body)

        ascii_arrow = parsed[2]
        self.assertEqual((ascii_arrow.sender, ascii_arrow.recipients), ("Reviewer", ["Advisor"]))

        report = parsed[3]
        self.assertEqual((report.sender, report.recipients, report.kind),
                         ("Wykonawca K5", ["Reviewer", "Advisor"], "report"))

        plus = parsed[4]
        self.assertEqual(plus.recipients, ["Reviewer", "Advisor"])
        self.assertEqual(plus.legacy_ts, "2026-09-16 12:00")

    def test_report_sender_prefix_is_a_parameter(self):
        # The source board's executor name is only the default; another board names its own.
        board = ("## MSG-001 | Executor A → Reviewer | 2026-09-16 11:00\n\nreport body\n"
                 "## MSG-002 | Wykonawca K5 → Reviewer | 2026-09-16 11:05\n\nother\n")
        default = mail_md.parse_mail_md(board)
        self.assertEqual([m.kind for m in default], ["turn", "report"])
        custom = mail_md.parse_mail_md(board, report_prefix="Executor")
        self.assertEqual([m.kind for m in custom], ["report", "turn"])
        res = self.cli("import-md", self.write(board), "--report-sender-prefix", "Executor")
        self.assertEqual(res.returncode, 0, res.stderr)
        kinds = [r[0] for r in self.conn.execute("SELECT kind FROM messages ORDER BY id")]
        self.assertEqual(kinds, ["report", "turn"])

    def test_unparsed_header_blocks_import(self):
        path = self.write(FIXTURE + BROKEN_HEADER)
        self.assertEqual(mail_md.count_headers(FIXTURE + BROKEN_HEADER), 8)
        self.assertEqual(mail_md.unparsed_headers(FIXTURE + BROKEN_HEADER),
                         ["## MSG-9 | zepsuty"])
        result = self.cli("import-md", path)
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("MSG-9", result.stderr)
        self.assertEqual(self.message_count(), 0)

    def test_ts_variants(self):
        parsed = mail_md.parse_mail_md(FIXTURE)
        self.assertEqual(parsed[0].ts_utc, "2026-09-15T08:42:00Z")
        self.assertEqual(parsed[1].ts_utc, "2026-09-15T00:00:00Z")   # no time -> midnight
        self.assertEqual(parsed[2].ts_utc, "2026-09-16T10:00:00Z")   # trailing " UTC"
        self.assertEqual(parsed[3].ts_utc, "2026-09-16T11:32:00Z")   # "(zegar systemowy)"
        self.assertEqual(parsed[3].legacy_ts, "2026-09-16 11:32 (zegar systemowy)")
        self.assertEqual([m.note for m in parsed], [None] * 7)

    def test_duplicate_legacy_id_two_records_and_reimport_idempotent(self):
        path = self.write(FIXTURE)
        first = self.cli("import-md", path)
        self.assertEqual(first.returncode, 0, first.stderr)
        self.assertEqual(first.stdout.strip(),
                         "IMPORTED new=7 skipped=0 unparsed_ts=0 total_headers=7")

        again = self.cli("import-md", path)
        self.assertEqual(again.stdout.strip(),
                         "IMPORTED new=0 skipped=7 unparsed_ts=0 total_headers=7")
        self.assertEqual(self.message_count(), 7)
        # Same number, different body -> two distinct records.
        dupes = self.conn.execute("SELECT body FROM messages WHERE legacy_id=143").fetchall()
        self.assertEqual(len(dupes), 2)
        self.assertNotEqual(dupes[0]["body"], dupes[1]["body"])

    def test_dry_run_reports_without_writing(self):
        path = self.write(FIXTURE)
        result = self.cli("import-md", path, "--dry-run")
        self.assertEqual(result.stdout.strip(),
                         "IMPORTED new=7 skipped=0 unparsed_ts=0 total_headers=7")
        self.assertEqual(self.message_count(), 0)

    def test_import_never_creates_pending(self):
        self.cli("import-md", self.write(FIXTURE))
        states = set(row[0] for row in self.conn.execute("SELECT DISTINCT state FROM delivery"))
        self.assertEqual(states, {"processed"})
        for recipient in ("Reviewer", "Advisor"):
            self.assertIsNone(store.wait_one(self.conn, recipient, timeout=0.2, poll=0.05))

    def test_import_all_or_nothing(self):
        path = self.write(FIXTURE + EMPTY_BODY)
        result = self.cli("import-md", path)
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("MSG-6", result.stderr)
        self.assertEqual(self.message_count(), 0)

    def test_awaiting_normalized_or_null(self):
        parsed = mail_md.parse_mail_md(FIXTURE)
        plain, prose = parsed[0], parsed[3]
        self.assertEqual((plain.awaiting, plain.legacy_awaiting), ("Advisor", None))
        self.assertEqual((prose.awaiting, prose.legacy_awaiting), (None, "Advisor / raport P07"))
        # The marker stays part of the body; nothing synthetic is added to it.
        self.assertIn("KONIEC TURY MSG-004", prose.body)
        self.assertNotIn("agent-mail", prose.body)

    # -- renderer ----------------------------------------------------------

    def test_export_roundtrip_headers(self):
        self.cli("import-md", self.write(FIXTURE))
        rows = self.conn.execute("SELECT * FROM messages ORDER BY id").fetchall()
        fields = ("legacy_id", "legacy_ts", "legacy_awaiting", "sender", "recipients",
                  "kind", "awaiting", "ts_utc", "body", "dedup_key")

        expected = [tuple(getattr(m, f) for f in fields) for m in mail_md.parse_mail_md(FIXTURE)]
        cycle = mail_md.render_md(rows, box=self.box)
        self.assertIn("## MSG-001 | Reviewer → Advisor | 2026-09-15 08:42", cycle)
        self.assertIn('legacy_awaiting="Advisor / raport P07"', cycle)
        for _ in range(2):   # two full render -> parse cycles must be stable
            parsed = mail_md.parse_mail_md(cycle)
            self.assertEqual([tuple(getattr(m, f) for f in fields) for m in parsed], expected)
            cycle = mail_md.render_md(parsed, box=self.box)

    def test_export_md_to_file_reimports_as_noop(self):
        self.cli("import-md", self.write(FIXTURE))
        out = os.path.join(self.tmp, "export.md")
        result = self.cli("export-md", "--out", out)
        self.assertEqual(result.stdout.strip(), "WROTE %s messages=7" % (out,))
        again = self.cli("import-md", out)
        self.assertEqual(again.stdout.strip(),
                         "IMPORTED new=0 skipped=7 unparsed_ts=0 total_headers=7")
        self.assertEqual(self.message_count(), 7)

    def test_export_md_since_and_stdout(self):
        self.cli("import-md", self.write(FIXTURE))
        result = self.cli("export-md", "--since", 5)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(mail_md.parse_mail_md(result.stdout)), 2)
        self.assertIn("since=5", result.stdout.splitlines()[0])


if __name__ == "__main__":
    unittest.main()
