import json
import tempfile
import unittest
from pathlib import Path

from modules.repo_auto_update import manifest


class UpdateManifestTest(unittest.TestCase):
    def parse(self, value):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "rollout.json"
            path.write_text(json.dumps(value), encoding="utf-8")
            return manifest.parse_manifest(path)

    def test_paused_manifest_needs_no_target(self):
        self.assertEqual(
            self.parse({
                "schema": 1,
                "enabled": False,
                "target": "",
                "activation": "automatic",
                "sequence": 0,
                "allow_rollback": False,
            }),
            (False, "", "automatic", 0, False),
        )

    def test_enabled_manifest_requires_full_commit(self):
        target = "a" * 40
        self.assertEqual(
            self.parse({
                "schema": 1,
                "enabled": True,
                "target": target,
                "activation": "automatic",
                "sequence": 1,
                "allow_rollback": False,
            }),
            (True, target, "automatic", 1, False),
        )
        with self.assertRaisesRegex(ValueError, "full lowercase"):
            self.parse({
                "schema": 1,
                "enabled": True,
                "target": "main",
                "activation": "automatic",
                "sequence": 1,
                "allow_rollback": False,
            })

    def test_nonautomatic_activation_is_refused(self):
        with self.assertRaisesRegex(ValueError, "automatic"):
            self.parse({
                "schema": 1,
                "enabled": True,
                "target": "b" * 40,
                "activation": "next-restart",
                "sequence": 1,
                "allow_rollback": False,
            })

    def test_enabled_manifest_may_be_armed_without_target(self):
        self.assertEqual(
            self.parse({
                "schema": 1,
                "enabled": True,
                "target": "",
                "activation": "automatic",
                "sequence": 0,
                "allow_rollback": False,
            }),
            (True, "", "automatic", 0, False),
        )

    def test_enabled_rollout_requires_positive_sequence(self):
        with self.assertRaisesRegex(ValueError, "positive sequence"):
            self.parse({
                "schema": 1,
                "enabled": True,
                "target": "c" * 40,
                "activation": "automatic",
                "sequence": 0,
                "allow_rollback": False,
            })


if __name__ == "__main__":
    unittest.main()
