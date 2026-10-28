from __future__ import annotations

import importlib.util
import json
import os
import subprocess
import sqlite3
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch
from contextlib import closing

SCRIPT = Path(__file__).resolve().parents[1] / "card_stations_source.py"
SPEC = importlib.util.spec_from_file_location("card_stations_source", SCRIPT)
source = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(source)


class PinnedSourceTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.checkout = self.root / "catalog"
        subprocess.run(["git", "init", "-q", "-b", "master", str(self.checkout)], check=True)
        (self.checkout / "build.py").write_text("# compiler\n")
        (self.checkout / "schema.json").write_text("{}\n")
        source.git(self.checkout, "add", ".")
        source.git(self.checkout, "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-qm", "catalog")
        self.revision = source.git(self.checkout, "rev-parse", "HEAD")
        source.git(self.checkout, "remote", "add", "origin", "https://github.com/iebb/card-stations.git")
        self.lock = self.root / "lock.json"
        self.lock.write_text(json.dumps({"repository": "https://github.com/iebb/card-stations.git", "revision": self.revision}))
        self.patches = [patch.object(source, "LOCK_PATH", self.lock), patch.object(source, "DEFAULT_CHECKOUT", self.checkout), patch.dict(os.environ)]
        for item in self.patches:
            item.start()
            self.addCleanup(item.stop)
        os.environ.pop("CARDBAL_STATIONS_SOURCE", None)

    def test_existing_pinned_commit_works_offline_with_url_rewrite(self):
        source.git(self.checkout, "config", "url.git@github.com:.insteadOf", "https://github.com/")
        self.assertEqual(source.resolve_source(), self.checkout)
        self.assertEqual(source.git(self.checkout, "rev-parse", "HEAD"), self.revision)

    def test_dirty_implicit_checkout_is_rejected_without_overwriting(self):
        path = self.checkout / "schema.json"
        path.write_text('{"local":true}')
        with self.assertRaisesRegex(RuntimeError, "local changes"):
            source.resolve_source()
        self.assertEqual(path.read_text(), '{"local":true}')

    def test_explicit_development_checkout_allows_local_edits(self):
        (self.checkout / "schema.json").write_text('{"local":true}')
        self.assertEqual(source.resolve_source(self.checkout), self.checkout.resolve())

    def test_short_pin_is_rejected(self):
        self.lock.write_text(json.dumps({"revision": self.revision[:7]}))
        with self.assertRaisesRegex(RuntimeError, "full commit SHA"):
            source.resolve_source()



if __name__ == "__main__":
    unittest.main()
