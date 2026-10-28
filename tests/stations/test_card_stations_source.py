from __future__ import annotations

import json
import io
import os
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch
from contextlib import redirect_stdout

import tools.stations.catalog as source


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

    def test_compiler_projection_keeps_build_inputs_without_publishing_unused_outputs(self):
        (self.checkout / "build.py").write_text('''
import json, sys
from pathlib import Path
output = Path(sys.argv[sys.argv.index("--output") + 1])
names = ["JPStationCodes.csv", "tunion_tripreader_source.json", "JPStationCodes.json",
         "jp_stations_coverage.json", "ulaanbaatar_stations.tsv"]
for name in names:
    (output / name).write_text("generated")
(output / "card-stations-manifest.json").write_text(json.dumps({
    "outputs": {name: "old-digest" for name in names}, "source_sha256": "fixture"
}))
''')
        output = self.root / "output"
        with patch("sys.argv", ["catalog", "--source", str(self.checkout), "--output", str(output)]), redirect_stdout(io.StringIO()):
            source.main()
        self.assertEqual({p.name for p in output.iterdir()}, {
            "JPStationCodes.csv", "tunion_tripreader_source.json", "card-stations-manifest.json",
        })
        manifest = json.loads((output / "card-stations-manifest.json").read_text())
        self.assertEqual(set(manifest["outputs"]), {"JPStationCodes.csv", "tunion_tripreader_source.json"})



if __name__ == "__main__":
    unittest.main()
