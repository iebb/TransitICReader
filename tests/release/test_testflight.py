import contextlib
import io
import os
from pathlib import Path
from types import SimpleNamespace
import tempfile
import unittest
from unittest.mock import patch

from tools.release import testflight


class TestFlightUploadTests(unittest.TestCase):
    def check_upload(self, modern):
        with tempfile.TemporaryDirectory() as directory:
            ipa = Path(directory) / "CardBal.ipa"
            ipa.write_bytes(b"synthetic ipa")
            keys = []

            def run(command, **kwargs):
                if command[-1] == "--help":
                    return SimpleNamespace(stdout="--upload-package" if modern else "--upload-app", stderr="", returncode=0)
                key = Path(kwargs["env"]["API_PRIVATE_KEYS_DIR"]) / "AuthKey_test-key-id.p8"
                self.assertEqual(key.read_text(), "synthetic private key")
                self.assertEqual(key.stat().st_mode & 0o777, 0o600)
                self.assertNotIn("synthetic private key", command)
                self.assertIn("--upload-package" if modern else "--upload-app", command)
                keys.append(key)
                return SimpleNamespace(returncode=0)

            with patch.dict(os.environ, {"ASC_KEY_ID": "test-key-id", "ASC_ISSUER_ID": "test-issuer", "ASC_PRIVATE_KEY": "synthetic private key"}), \
                    patch("sys.argv", ["testflight", "--ipa", str(ipa)]), \
                    patch.object(testflight.subprocess, "run", side_effect=run), contextlib.redirect_stdout(io.StringIO()):
                testflight.main()
            self.assertEqual(len(keys), 1)
            self.assertFalse(keys[0].exists())

    def test_current_apple_upload_cli_and_key_cleanup(self):
        self.check_upload(True)

    def test_legacy_apple_upload_cli_and_key_cleanup(self):
        self.check_upload(False)


if __name__ == "__main__":
    unittest.main()
