import unittest

from tools.release.versions import paired_store_builds, upload_versions


class UploadVersionsTests(unittest.TestCase):
    def test_defaults_are_monotonic_on_new_runs_and_retries(self):
        a = upload_versions("2.5.0", "", "10", "1")
        retry = upload_versions("2.5.0", "", "10", "2")
        next_run = upload_versions("2.5.0", "", "11", "1")
        self.assertEqual(a["ios_build"], "1010.1")
        self.assertLess(int(a["android_version_code"]), int(retry["android_version_code"]))
        self.assertLess(int(retry["android_version_code"]), int(next_run["android_version_code"]))

    def test_manual_build_number(self):
        self.assertEqual(upload_versions("2.5.0", "45", "1", "1"),
                         {"version": "2.5.0", "ios_build": "45.1", "android_version_code": "4501"})

    def test_invalid_version_cannot_reach_shell_or_github_outputs(self):
        for version in ("v2.5.0", "2.5", "2.5.0-rc1", "2.5.0\nx=bad", "$(whoami)", "02.5.0", "2.５.0"):
            with self.subTest(version=version), self.assertRaises(ValueError):
                upload_versions(version, "", "1", "1")

    def test_limits_fail_instead_of_reusing_build_numbers(self):
        for build, run, attempt in (("0", "1", "1"), ("10000", "1", "1"), ("", "9000", "1"),
                                    ("", "1", "100"), ("", "0", "1")):
            with self.subTest(build=build, run=run, attempt=attempt), self.assertRaises(ValueError):
                upload_versions("2.5.0", build, run, attempt)

    def test_pair_matches_upload_attempt_not_only_marketing_version(self):
        apple = {"build": {"version": "2.5.0", "build_number": "1001.2", "id": "build-id"}}
        google = {"version": "2.5.0", "version_code": 100102}
        self.assertEqual(paired_store_builds(apple, google)["ios_build_id"], "build-id")
        google["version_code"] = 100201
        with self.assertRaisesRegex(ValueError, "different upload attempts"):
            paired_store_builds(apple, google)

    def test_different_versions_and_unpaired_legacy_builds_stop_before_mutation(self):
        apple = {"build": {"version": "2.5.0", "build_number": "46", "id": "build-id"}}
        with self.assertRaisesRegex(ValueError, "versions differ"):
            paired_store_builds(apple, {"version": "2.4.0", "version_code": 46})
        with self.assertRaisesRegex(ValueError, "different upload attempts"):
            paired_store_builds(apple, {"version": "2.5.0", "version_code": 46})


if __name__ == "__main__":
    unittest.main()
