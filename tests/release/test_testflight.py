import contextlib
import io
import os
from pathlib import Path
from types import SimpleNamespace
import tempfile
import unittest
from unittest.mock import patch

from tools.release import testflight

# Option lists from installed altool help text: current Xcode, an older --upload-package
# release without individual keys, and the legacy --upload-app tool with and without them.
CURRENT_HELP = "--upload-package <file>\n--api-key <string>\n--api-issuer <id>\n--api-key-subject <string>\n"
NO_SUBJECT_HELP = "--upload-package <file>\n--api-key <string>\n--api-issuer <id>\n"
LEGACY_HELP = "--upload-app -f <file>\n--apiKey <api_key>\n--apiIssuer <issuer_id>\n"
LEGACY_SUBJECT_HELP = LEGACY_HELP + "--api-key-subject <string>\n"
TEAM = {"ASC_KEY_ID": "TEAMKEY123", "ASC_ISSUER_ID": "test-issuer", "ASC_PRIVATE_KEY": "synthetic private key"}
INDIVIDUAL = {"ASC_KEY_TYPE": "individual", "ASC_KEY_ID": "USERKEY123", "ASC_PRIVATE_KEY": "synthetic private key"}


class TestFlightUploadTests(unittest.TestCase):
    def upload(self, environ, help_text):
        """Run the uploader against a synthetic IPA and return the upload command."""
        with tempfile.TemporaryDirectory() as directory:
            ipa = Path(directory) / "CardBal.ipa"
            ipa.write_bytes(b"synthetic ipa")
            uploads = []

            def run(command, **kwargs):
                if command[-1] == "--help":
                    return SimpleNamespace(stdout=help_text, stderr="", returncode=0)
                key = Path(kwargs["env"]["API_PRIVATE_KEYS_DIR"]) / f"AuthKey_{environ['ASC_KEY_ID']}.p8"
                self.assertEqual(key.read_text(), "synthetic private key")
                self.assertEqual(key.stat().st_mode & 0o777, 0o600)
                self.assertNotIn("synthetic private key", command)
                uploads.append((command, key))
                return SimpleNamespace(returncode=0)

            with patch.dict(os.environ, environ, clear=True), patch("sys.argv", ["testflight", "--ipa", str(ipa)]), \
                    patch.object(testflight.subprocess, "run", side_effect=run), contextlib.redirect_stdout(io.StringIO()):
                testflight.main()
            self.assertEqual(len(uploads), 1)
            command, key = uploads[0]
            self.assertFalse(key.exists())
            return [str(ipa), str(key)], command

    def rejected(self, environ, help_text=CURRENT_HELP) -> tuple[list, str]:
        """Run an upload expected to stop before temp key files or upload; return calls and error."""
        with tempfile.TemporaryDirectory() as directory:
            ipa = Path(directory) / "CardBal.ipa"
            ipa.write_bytes(b"synthetic ipa")
            calls, stderr = [], io.StringIO()

            def run(command, **kwargs):
                calls.append(command)
                return SimpleNamespace(stdout=help_text, stderr="", returncode=0)

            with patch.dict(os.environ, environ, clear=True), patch("sys.argv", ["testflight", "--ipa", str(ipa)]), \
                    patch.object(testflight.subprocess, "run", side_effect=run), \
                    patch.object(testflight.tempfile, "TemporaryDirectory", side_effect=AssertionError("temp key")), \
                    contextlib.redirect_stderr(stderr), self.assertRaises(SystemExit) as raised:
                testflight.main()
            self.assertEqual(raised.exception.code, 2)
            self.assertTrue(all(command[-1] == "--help" for command in calls))
            return calls, stderr.getvalue()

    def test_team_key_is_the_default_and_keeps_current_upload_command(self):
        for key_type in (None, "", "team"):
            environ = TEAM if key_type is None else {**TEAM, "ASC_KEY_TYPE": key_type}
            with self.subTest(key_type=key_type):
                (ipa, key), command = self.upload(environ, CURRENT_HELP)
                self.assertEqual(command, ["xcrun", "altool", "--upload-package", ipa, "--api-key", "TEAMKEY123",
                                           "--api-issuer", "test-issuer", "--p8-file-path", key])

    def test_team_key_keeps_legacy_upload_command(self):
        (ipa, _), command = self.upload(TEAM, LEGACY_HELP)
        self.assertEqual(command, ["xcrun", "altool", "--upload-app", "-f", ipa, "--type", "ios",
                                   "--apiKey", "TEAMKEY123", "--apiIssuer", "test-issuer"])

    def test_individual_key_uses_user_subject_without_an_issuer(self):
        (ipa, key), command = self.upload(INDIVIDUAL, CURRENT_HELP)
        self.assertEqual(command, ["xcrun", "altool", "--upload-package", ipa, "--api-key", "USERKEY123",
                                   "--api-issuer", "", "--api-key-subject", "user", "--p8-file-path", key])

    def test_individual_key_on_legacy_upload_app_with_subject_support(self):
        (ipa, _), command = self.upload(INDIVIDUAL, LEGACY_SUBJECT_HELP)
        self.assertEqual(command, ["xcrun", "altool", "--upload-app", "-f", ipa, "--type", "ios",
                                   "--apiKey", "USERKEY123", "--apiIssuer", "", "--api-key-subject", "user"])

    def test_individual_key_requires_altool_subject_support_instead_of_a_team_token(self):
        for help_text in (NO_SUBJECT_HELP, LEGACY_HELP):
            with self.subTest(help_text=help_text):
                calls, error = self.rejected(INDIVIDUAL, help_text)
                self.assertEqual(len(calls), 1)
                self.assertIn("requires an altool that supports --api-key-subject", error)

    def test_invalid_key_type_stops_before_altool_or_key_files(self):
        for key_type in ("Individual", "TEAM", " team", "both", "user"):
            with self.subTest(key_type=key_type):
                calls, error = self.rejected({**TEAM, "ASC_KEY_TYPE": key_type})
                self.assertEqual(calls, [])
                self.assertIn("ASC_KEY_TYPE must be team or individual", error)

    def test_credentials_match_the_key_type_before_altool_or_key_files(self):
        cases = (({k: v for k, v in TEAM.items() if k != "ASC_ISSUER_ID"}, "ASC_ISSUER_ID is required for team"),
                 ({**TEAM, "ASC_ISSUER_ID": ""}, "ASC_ISSUER_ID is required for team"),
                 ({**INDIVIDUAL, "ASC_KEY_ID": ""}, "ASC_KEY_ID is required for individual"),
                 ({k: v for k, v in INDIVIDUAL.items() if k != "ASC_PRIVATE_KEY"}, "ASC_PRIVATE_KEY is required"))
        for environ, message in cases:
            with self.subTest(message=message):
                calls, error = self.rejected(environ)
                self.assertEqual(calls, [])
                self.assertIn(message, error)

    def test_individual_key_ignores_blank_or_stale_team_issuer_from_the_workflow(self):
        # The workflow always passes the ASC_ISSUER_ID secret, which may still hold the old team issuer.
        for issuer in ("", "stale-team-issuer"):
            with self.subTest(issuer=issuer):
                (ipa, key), command = self.upload({**INDIVIDUAL, "ASC_ISSUER_ID": issuer}, CURRENT_HELP)
                self.assertEqual(command, ["xcrun", "altool", "--upload-package", ipa, "--api-key", "USERKEY123",
                                           "--api-issuer", "", "--api-key-subject", "user", "--p8-file-path", key])
        (ipa, _), command = self.upload({**INDIVIDUAL, "ASC_ISSUER_ID": "stale-team-issuer"}, LEGACY_SUBJECT_HELP)
        self.assertNotIn("stale-team-issuer", command)
        self.assertEqual(command[-4:], ["--apiIssuer", "", "--api-key-subject", "user"])


if __name__ == "__main__":
    unittest.main()
