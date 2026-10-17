"""Smoke test: the temp env isolates AGENT_COSTS_HOME (spec TT-813)."""
import os
import unittest

import config
from tests import helpers


class TempEnvTest(unittest.TestCase):
    def test_isolates_home(self):
        before = os.environ.get("AGENT_COSTS_HOME")
        with helpers.TempEnv() as env:
            self.assertEqual(config.home(), env.root)
            self.assertTrue(config.db_path().startswith(env.root))
        self.assertEqual(os.environ.get("AGENT_COSTS_HOME"), before)


if __name__ == "__main__":
    unittest.main()
