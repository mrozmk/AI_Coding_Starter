"""Config load, slug, cwd matching and timestamp normalization (spec TT-813)."""
import os
import unittest

import config
from tests import helpers


class ConfigTest(unittest.TestCase):
    def test_missing_config_exits_2(self):
        with helpers.TempEnv() as env:
            os.remove(os.path.join(env.root, "config.json"))
            with self.assertRaises(SystemExit) as ctx:
                config.load_config()
            self.assertEqual(ctx.exception.code, 2)

    def test_empty_projects_exits_2(self):
        with helpers.TempEnv() as env:
            with open(os.path.join(env.root, "config.json"), "w") as fh:
                fh.write('{"projects": {}}')
            with self.assertRaises(SystemExit) as ctx:
                config.load_config()
            self.assertEqual(ctx.exception.code, 2)

    def test_defaults_filled(self):
        with helpers.TempEnv() as env:
            with open(os.path.join(env.root, "config.json"), "w") as fh:
                fh.write('{"projects": {"p": ["~/x"]}}')
            cfg = config.load_config()
        self.assertEqual(cfg["stage_skills"], config.DEFAULT_STAGE_SKILLS)
        self.assertEqual(len(cfg["codex_homes"]), 1)
        self.assertFalse(cfg["projects"]["p"][0].startswith("~"))

    def test_slug_of_alfa_clone(self):
        self.assertEqual(config.slug("/Users/mrozo/Desktop/TakeTask/TakeTask.DN-alfa"),
                         "-Users-mrozo-Desktop-TakeTask-TakeTask-DN-alfa")

    def test_project_for_cwd_boundary_and_longest(self):
        cfg = {"projects": {"main": ["/w/TakeTask.DN"], "alfa": ["/w/TakeTask.DN-alfa"],
                            "deep": ["/w/TakeTask.DN/sub"]}}
        self.assertEqual(config.project_for_cwd(cfg, "/w/TakeTask.DN-alfa/x"), "alfa")
        self.assertEqual(config.project_for_cwd(cfg, "/w/TakeTask.DN"), "main")
        self.assertEqual(config.project_for_cwd(cfg, "/w/TakeTask.DN/sub/y"), "deep")
        self.assertIsNone(config.project_for_cwd(cfg, "/w/TakeTask.DNX"))
        self.assertIsNone(config.project_for_cwd(cfg, "/private/tmp"))

    def test_norm_ts(self):
        cases = {
            "2026-10-06T10:00:00Z": "2026-10-06T10:00:00.000Z",
            "2026-10-06T12:00:00+02:00": "2026-10-06T10:00:00.000Z",
            "2026-10-06T10:00:00.5Z": "2026-10-06T10:00:00.500Z",
            "2026-10-06T10:00:00.123456Z": "2026-10-06T10:00:00.123Z",
            "2026-10-06": "2026-10-06T00:00:00.000Z",
        }
        for raw, want in cases.items():
            self.assertEqual(config.norm_ts(raw), want)
            self.assertEqual(len(config.norm_ts(raw)), 24)
        chrono = ["2026-10-06", "2026-10-06T10:00:00Z", "2026-10-06T10:00:00.5Z",
                  "2026-10-06T10:00:01.123456Z", "2026-10-06T12:30:00+02:00"]
        normed = [config.norm_ts(x) for x in chrono]
        self.assertEqual(sorted(normed), normed)
        with self.assertRaises(ValueError):
            config.norm_ts("yesterday")


    def test_slug_maps_each_non_alphanumeric_character(self):
        self.assertEqual(config.slug("/work/a_b c.d-é!"), "-work-a-b-c-d---")
        self.assertEqual(config.slug("ABC123"), "ABC123")

    def test_zoneless_clock_rejected_but_date_and_offsets_preserved(self):
        for raw in ("2026-10-06T12:00:00", "2026-10-06 12:00:00.5"):
            with self.subTest(raw=raw), self.assertRaises(ValueError):
                config.norm_ts(raw)
        self.assertEqual(config.norm_ts("2026-10-06T12:00:00+0200"),
                         "2026-10-06T10:00:00.000Z")


if __name__ == "__main__":
    unittest.main()
