import json
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from tools.release import github_release
from tools.release.github_release import checksum_text, platforms_present, release_notes


class ReleaseNotesTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.notes = Path(directory.name)
        (self.notes / "macos-9.0.0.md").write_text("# CardBal 9.0.0 for Mac\n\nMac changes.\n")
        (self.notes / "9.0.0.json").write_text(json.dumps({"en-GB": "• English", "ja": "• 日本語"}))

    def test_both_platforms_share_one_body_in_a_fixed_order(self):
        text = release_notes(["android", "macos"], "9.0.0", self.notes)
        self.assertTrue(text.startswith("## CardBal 9.0.0 for Mac\n\nMac changes."))
        self.assertIn("## Android\n\n• English\n\n• 日本語\n\n### Which APK?", text)
        self.assertLess(text.index("Mac changes."), text.index("## Android"))
        self.assertTrue(text.endswith("`SHA256SUMS.txt` lists the SHA-256 checksum of every download.\n"))

    def test_android_alone_omits_the_mac_section(self):
        text = release_notes(["android"], "9.0.0", self.notes)
        self.assertNotIn("Mac", text)
        self.assertIn("CardBal-9.0.0-android-git-signed.apk", text)

    def test_android_notes_file_overrides_store_notes(self):
        (self.notes / "android-9.0.0.md").write_text("Android only.\n")
        text = release_notes(["android"], "9.0.0", self.notes)
        self.assertIn("## Android\n\nAndroid only.", text)
        self.assertNotIn("English", text)

    def test_mac_notes_are_required(self):
        (self.notes / "macos-9.0.0.md").unlink()
        with self.assertRaises(ValueError):
            release_notes(["macos"], "9.0.0", self.notes)


class ReleaseAssetTests(unittest.TestCase):
    def test_any_platform_file_marks_that_platform_present(self):
        names = ["CardBal-9.0.0-android-git-signed.apk", "SHA256SUMS.txt"]
        self.assertEqual(platforms_present(names, "9.0.0"), ["android"])
        self.assertEqual(platforms_present(names + ["CardBal-9.0.0-macOS.zip"], "9.0.0"), ["macos", "android"])

    def test_checksums_are_sorted_by_file_name(self):
        self.assertEqual(checksum_text({"b.apk": "22", "a.zip": "11"}), "11  a.zip\n22  b.apk\n")

    def test_legacy_platform_tag_counts_as_published(self):
        releases = {"macos-v2.6.3": {"assets": []}}
        with mock.patch.object(github_release, "fetch_release", side_effect=releases.get):
            self.assertTrue(github_release.published("macos", "2.6.3"))
            self.assertFalse(github_release.published("android", "2.6.3"))

    def test_publish_refuses_wrong_files_and_existing_platform(self):
        with self.assertRaises(ValueError):
            github_release.publish("macos", "9.0.0", "abc", [Path("CardBal-9.0.0-android.apk")])
        releases = {"v9.0.0": {"assets": [{"name": "CardBal-9.0.0-macOS.zip"}]}}
        with mock.patch.object(github_release, "fetch_release", side_effect=releases.get), \
                self.assertRaises(RuntimeError):
            github_release.publish("macos", "9.0.0", "abc", [Path("CardBal-9.0.0-macOS.zip")])


if __name__ == "__main__":
    unittest.main()
