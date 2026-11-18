import json
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from tools.release import github_release
from tools.release.github_release import assets_present, checksum_text, release_notes

ALL = ["macos", "android-play", "android-git-signed"]


class ReleaseNotesTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.notes = Path(directory.name)
        (self.notes / "macos-9.0.0.md").write_text("# CardBal 9.0.0 for Mac\n\nMac changes.\n")
        (self.notes / "9.0.0.json").write_text(json.dumps({"en-GB": "• English", "ja": "• 日本語"}))

    def test_all_downloads_share_one_body_in_a_fixed_order(self):
        text = release_notes(list(reversed(ALL)), "9.0.0", self.notes)
        self.assertTrue(text.startswith("## CardBal 9.0.0 for Mac\n\nMac changes."))
        self.assertIn("## Android\n\n• English\n\n• 日本語\n\n### Which APK?", text)
        self.assertLess(text.index("android.apk"), text.index("android-git-signed.apk"))
        self.assertTrue(text.endswith("`SHA256SUMS.txt` lists the SHA-256 checksum of every download.\n"))

    def test_git_signed_apk_alone_omits_mac_and_play(self):
        text = release_notes(["android-git-signed"], "9.0.0", self.notes)
        self.assertNotIn("Mac", text)
        self.assertNotIn("CardBal-9.0.0-android.apk", text)
        self.assertIn("### APK\n\n- `CardBal-9.0.0-android-git-signed.apk`", text)

    def test_android_notes_file_overrides_store_notes(self):
        (self.notes / "android-9.0.0.md").write_text("Android only.\n")
        text = release_notes(["android-git-signed"], "9.0.0", self.notes)
        self.assertIn("## Android\n\nAndroid only.", text)
        self.assertNotIn("English", text)

    def test_mac_without_notes_uses_store_notes_and_requirements(self):
        (self.notes / "macos-9.0.0.md").unlink()
        text = release_notes(["macos"], "9.0.0", self.notes)
        self.assertTrue(text.startswith("## macOS\n\n• English"))
        self.assertIn("macOS 13", text)
        self.assertIn("CardBal-9.0.0-macOS.zip", text)

    def test_no_notes_files_still_describe_the_downloads(self):
        text = release_notes(ALL, "8.0.0", self.notes)
        self.assertIn("## macOS\n\nCardBal requires macOS 13", text)
        self.assertIn("## Android\n\n### Which APK?", text)


class ReleaseAssetTests(unittest.TestCase):
    def test_each_download_is_tracked_separately(self):
        names = ["CardBal-9.0.0-android-git-signed.apk", "SHA256SUMS.txt"]
        self.assertEqual(assets_present(names, "9.0.0"), ["android-git-signed"])
        self.assertEqual(assets_present(names + ["CardBal-9.0.0-macOS.zip"], "9.0.0"),
                         ["macos", "android-git-signed"])

    def test_checksums_are_sorted_by_file_name(self):
        self.assertEqual(checksum_text({"b.apk": "22", "a.zip": "11"}), "11  a.zip\n22  b.apk\n")

    def test_legacy_platform_tag_counts_as_published(self):
        releases = {"macos-v2.6.3": {"assets": []}, "android-v2.6.1": {"assets": []}}
        with mock.patch.object(github_release, "fetch_release", side_effect=releases.get):
            self.assertTrue(github_release.published("macos", "2.6.3"))
            self.assertFalse(github_release.published("android-git-signed", "2.6.3"))
            self.assertTrue(github_release.published("android-play", "2.6.1"))
            self.assertTrue(github_release.published("android-git-signed", "2.6.1"))

    def test_play_apk_can_join_a_release_with_the_git_signed_apk(self):
        releases = {"v9.0.0": {"assets": [{"name": "CardBal-9.0.0-android-git-signed.apk"}]}}
        with mock.patch.object(github_release, "fetch_release", side_effect=releases.get):
            self.assertTrue(github_release.published("android-git-signed", "9.0.0"))
            self.assertFalse(github_release.published("android-play", "9.0.0"))

    def test_publish_refuses_unknown_and_existing_files(self):
        with self.assertRaises(ValueError):
            github_release.publish("9.0.0", "abc", [Path("CardBal-8.0.0-macOS.zip")])
        releases = {"v9.0.0": {"assets": [{"name": "CardBal-9.0.0-macOS.zip"}]}}
        with mock.patch.object(github_release, "fetch_release", side_effect=releases.get), \
                self.assertRaises(RuntimeError):
            github_release.publish("9.0.0", "abc", [Path("CardBal-9.0.0-macOS.zip")])


if __name__ == "__main__":
    unittest.main()
