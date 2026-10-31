import io
import os
import unittest
from pathlib import Path
from contextlib import redirect_stderr, redirect_stdout
from unittest import mock

from tools.release import ios_build_number
from tools.release.app_store import ReleaseError
from tools.release.ios_build_number import next_ios_build, uploaded_build_numbers


class NextBuildTests(unittest.TestCase):
    def test_counts_up_from_the_highest_plain_build(self):
        self.assertEqual(next_ios_build(["50", "52", "53", "2495.1.8", "2495.3.4"]), "54")
        self.assertEqual(next_ios_build(["9", "10"]), "11")

    def test_dotted_and_malformed_numbers_are_ignored(self):
        self.assertEqual(next_ios_build(["45", "1001.1", "1001.99", "2495.14.30", "053", "0", "", "54a", None]), "46")

    def test_first_build_of_an_app_is_one(self):
        self.assertEqual(next_ios_build([]), "1")
        self.assertEqual(next_ios_build(["2495.3.4"]), "1")


class AppStoreReadTests(unittest.TestCase):
    def test_reads_every_build_version_with_one_get_collection(self):
        api = mock.Mock()
        api.collection.return_value = ([{"attributes": {"version": "53"}}, {"attributes": {"version": "2495.3.4"}}, {}], [])
        self.assertEqual(uploaded_build_numbers(api, "6760978958"), ["53", "2495.3.4", ""])
        api.collection.assert_called_once_with(
            "/v1/builds", {"filter[app]": "6760978958", "fields[builds]": "version", "limit": 200})

    def test_app_id_must_be_numeric(self):
        for value in ("", "ad.neko.cardbal", "123 4"):
            with self.subTest(value=value), self.assertRaisesRegex(ReleaseError, "numeric"):
                ios_build_number.app_id_from({"ASC_APP_ID": value})


class CommandTests(unittest.TestCase):
    def test_writes_the_step_output_and_removes_the_temporary_key(self):
        seen = {}

        def fake_numbers(api, app_id):
            path = os.environ["ASC_PRIVATE_KEY_PATH"]
            seen["key"] = Path(path).read_text(encoding="utf-8")
            seen["mode"] = os.stat(path).st_mode & 0o777
            seen["path"] = path
            return ["52", "53", "2495.3.4"]

        opened = mock.mock_open()
        environ = {"ASC_APP_ID": "6760978958", "ASC_PRIVATE_KEY": "-----BEGIN PRIVATE KEY-----",
                   "GITHUB_OUTPUT": "github-output"}
        with mock.patch.dict(os.environ, environ, clear=False), \
                mock.patch.object(ios_build_number, "uploaded_build_numbers", fake_numbers), \
                mock.patch("tools.release.ios_build_number.open", opened, create=True), \
                redirect_stdout(io.StringIO()) as stdout:
            os.environ.pop("ASC_PRIVATE_KEY_PATH", None)
            ios_build_number.main([])
            self.assertNotIn("ASC_PRIVATE_KEY_PATH", os.environ)
        self.assertEqual(seen["key"], "-----BEGIN PRIVATE KEY-----")
        self.assertEqual(seen["mode"], 0o600)
        self.assertFalse(os.path.exists(seen["path"]))
        opened().write.assert_called_once_with("ios_build=54\n")
        self.assertIn("54", stdout.getvalue())

    def test_missing_credentials_write_no_output(self):
        opened = mock.mock_open()
        with mock.patch.dict(os.environ, {"ASC_APP_ID": "6760978958", "GITHUB_OUTPUT": "github-output"}), \
                mock.patch("tools.release.ios_build_number.open", opened, create=True), \
                redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as raised:
            os.environ.pop("ASC_PRIVATE_KEY", None)
            os.environ.pop("ASC_PRIVATE_KEY_PATH", None)
            ios_build_number.main([])
        self.assertEqual(raised.exception.code, 2)
        opened.assert_not_called()


if __name__ == "__main__":
    unittest.main()
