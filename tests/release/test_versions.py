import io
import os
import unittest
from contextlib import redirect_stderr, redirect_stdout
from datetime import datetime, timedelta, timezone
from unittest import mock

from tools.release.versions import (EPOCH, MAX_ANDROID_VERSION_CODE, android_version_name, build_numbers,
                                    ios_marketing_version, main, paired_store_builds, release_version,
                                    repository_versions, upload_versions)

NOW = datetime(2026, 10, 31, 14, 30, 59, 999999, tzinfo=timezone.utc)


def ios_key(build: str) -> tuple[int, ...]:
    # App Store Connect orders CFBundleVersion by its numeric components.
    return tuple(int(part) for part in build.split("."))


class BuildNumberTests(unittest.TestCase):
    def test_ios_and_android_numbers_come_from_the_same_utc_minute(self):
        expected = {"ios_build": "2495.14.30", "android_version_code": str(2495 * 1440 + 14 * 60 + 30),
                    "build_timestamp": "2026-10-31T14:30Z"}
        self.assertEqual(build_numbers(NOW), expected)
        tokyo = NOW.astimezone(timezone(timedelta(hours=9)))
        self.assertEqual(build_numbers(tokyo), expected)
        self.assertEqual(build_numbers(NOW.replace(second=0, microsecond=0)), expected)

    def test_every_later_minute_is_a_new_higher_number_on_both_stores(self):
        # Store jobs share a concurrency group, so a rerun starts in a later minute.
        start = datetime(2026, 12, 31, 22, 0, tzinfo=timezone.utc)
        previous = build_numbers(start)
        for offset in range(1, 3 * 24 * 60):
            current = build_numbers(start + timedelta(minutes=offset))
            self.assertGreater(ios_key(current["ios_build"]), ios_key(previous["ios_build"]))
            self.assertGreater(int(current["android_version_code"]), int(previous["android_version_code"]))
            previous = current

    def test_ios_build_stays_within_archived_4_2_2_digit_guidance(self):
        for now in (EPOCH + timedelta(days=1), NOW, EPOCH + timedelta(days=9999, hours=23, minutes=59)):
            with self.subTest(now=now):
                parts = build_numbers(now)["ios_build"].split(".")
                self.assertEqual(len(parts), 3)
                for part, digits in zip(parts, (4, 2, 2)):
                    self.assertRegex(part, r"^(?:0|[1-9][0-9]*)$")
                    self.assertLessEqual(len(part), digits)

    def test_epoch_day_bounds(self):
        self.assertEqual(build_numbers(EPOCH + timedelta(days=1)),
                         {"ios_build": "1.0.0", "android_version_code": "1440", "build_timestamp": "2020-01-02T00:00Z"})
        last = build_numbers(EPOCH + timedelta(days=9999, hours=23, minutes=59, seconds=59))
        self.assertEqual(last["ios_build"], "9999.23.59")
        self.assertEqual(last["android_version_code"], "14399999")
        self.assertLess(int(last["android_version_code"]), MAX_ANDROID_VERSION_CODE)
        for now in (EPOCH - timedelta(minutes=1), EPOCH, EPOCH + timedelta(hours=23, minutes=59),
                    EPOCH + timedelta(days=10000)):
            with self.subTest(now=now), self.assertRaisesRegex(ValueError, "from 1 to 9999"):
                build_numbers(now)

    def test_naive_build_time_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "timezone-aware"):
            build_numbers(NOW.replace(tzinfo=None))

    def test_new_numbers_exceed_old_independently_generated_upload_codes(self):
        # Repository defaults used for hand uploads, then the run-number scheme: iOS (1000+run).attempt
        # and Android (1000+run)*100+attempt, whose ceiling was 999999.
        legacy_ios = ("45", "1001.1", "1001.99")
        legacy_android = (5, 45, 100101, 100199, 999999)
        current = build_numbers(datetime(2026, 10, 31, 0, 0, tzinfo=timezone.utc))
        for build in legacy_ios:
            with self.subTest(ios=build):
                self.assertGreater(ios_key(current["ios_build"]), ios_key(build))
        for code in legacy_android:
            with self.subTest(android=code):
                self.assertGreater(int(current["android_version_code"]), code)


class ReleaseVersionTests(unittest.TestCase):
    def test_repository_ios_and_android_versions_agree(self):
        versions = repository_versions()
        self.assertEqual(versions["ios"], versions["android"])
        self.assertEqual(release_version("", versions), versions["ios"])

    def test_blank_version_defaults_to_repository_version(self):
        version = repository_versions()["ios"]
        for requested in ("", "  "):
            with self.subTest(requested=requested):
                self.assertEqual(upload_versions(requested, now=NOW), {"version": version, **build_numbers(NOW)})
        self.assertEqual(upload_versions(version=version, now=NOW)["version"], version)

    def test_explicit_version_must_match_repository_version(self):
        repository = {"ios": "2.5.0", "android": "2.5.0"}
        self.assertEqual(release_version("2.5.0", repository), "2.5.0")
        for requested in ("2.5.1", "2.4.1", "0.0.0"):
            with self.subTest(requested=requested), self.assertRaisesRegex(ValueError, "does not match"):
                release_version(requested, repository)

    def test_invalid_version_cannot_reach_shell_or_github_outputs(self):
        repository = {"ios": "2.5.0", "android": "2.5.0"}
        for requested in ("v2.5.0", "2.5", "2.5.0-rc1", "2.5.0\nx=bad", "$(whoami)", "02.5.0", "2.５.0", " 2.5.0"):
            with self.subTest(requested=requested), self.assertRaisesRegex(ValueError, "three numeric"):
                release_version(requested, repository)

    def test_repository_platform_versions_must_agree(self):
        for requested in ("", "2.5.0", "2.4.1"):
            with self.subTest(requested=requested), self.assertRaisesRegex(ValueError, "differ"):
                release_version(requested, {"ios": "2.5.0", "android": "2.4.1"})

    def test_repository_version_must_have_three_numeric_components(self):
        for version in ("2.5", "2.5.0-beta", ""):
            with self.subTest(version=version), self.assertRaisesRegex(ValueError, "three numeric"):
                release_version("", {"ios": version, "android": version})

    def test_ios_marketing_version_requires_one_value_across_configurations(self):
        debug = "\t\t\t\tMARKETING_VERSION = 2.5.0;\n"
        self.assertEqual(ios_marketing_version(debug + debug), "2.5.0")
        self.assertEqual(ios_marketing_version('\t\t\t\tMARKETING_VERSION = "2.5.0";\n'), "2.5.0")
        for project in (debug + "\t\t\t\tMARKETING_VERSION = 2.4.1;\n", "CURRENT_PROJECT_VERSION = 45;\n"):
            with self.subTest(project=project), self.assertRaisesRegex(ValueError, "one MARKETING_VERSION"):
                ios_marketing_version(project)

    def test_android_version_name_reads_the_gradle_default(self):
        line = 'val appVersionName = providers.gradleProperty("transitic.versionName").orElse("2.5.0").get()\n'
        self.assertEqual(android_version_name(line), "2.5.0")
        for script in ("", line + line):
            with self.subTest(script=script), self.assertRaisesRegex(ValueError, "transitic.versionName"):
                android_version_name(script)


class PairedStoreBuildTests(unittest.TestCase):
    def test_independent_uploads_pair_by_marketing_version_only(self):
        cases = (("2495.14.30", 3593702),  # separate TestFlight and Play workflow runs
                 ("45", 5),               # repository defaults uploaded by hand
                 ("1001.2", 100201))      # old run-number codes from different attempts
        for ios_build, android_code in cases:
            with self.subTest(ios_build=ios_build, android_code=android_code):
                apple = {"build": {"version": "2.5.0", "build_number": ios_build, "id": "build-id"}}
                google = {"version": "2.5.0", "version_code": android_code}
                self.assertEqual(paired_store_builds(apple, google), {
                    "version": "2.5.0", "ios_build_id": "build-id", "android_version_code": str(android_code)})

    def test_different_versions_stop_before_mutation(self):
        apple = {"build": {"version": "2.5.0", "build_number": "2495.14.30", "id": "build-id"}}
        with self.assertRaisesRegex(ValueError, "2.5.0 and Play internal version 2.4.1 differ"):
            paired_store_builds(apple, {"version": "2.4.1", "version_code": 3593670})

    def test_invalid_expected_pins_stop_before_mutation(self):
        apple = {"build": {"version": "2.5.0", "build_number": "2495.14.30", "id": "build-id"}}
        for code in (0, -1, True, None, "0123", "12a", MAX_ANDROID_VERSION_CODE + 1):
            with self.subTest(code=code), self.assertRaisesRegex(ValueError, "invalid version code"):
                paired_store_builds(apple, {"version": "2.5.0", "version_code": code})
        for build_id in ("", None):
            apple["build"]["id"] = build_id
            with self.subTest(build_id=build_id), self.assertRaisesRegex(ValueError, "no App Store Connect ID"):
                paired_store_builds(apple, {"version": "2.5.0", "version_code": 3593670})


class CommandTests(unittest.TestCase):
    def run_main(self, release_version: str, opened: mock.MagicMock) -> str:
        stdout = io.StringIO()
        environ = {"RELEASE_VERSION": release_version, "GITHUB_OUTPUT": "github-output"}
        with mock.patch.dict(os.environ, environ), \
                mock.patch("tools.release.versions.open", opened, create=True), \
                redirect_stdout(stdout), redirect_stderr(io.StringIO()):
            main([], now=NOW)
        return stdout.getvalue()

    def test_writes_step_outputs_for_blank_dispatch_input(self):
        opened = mock.mock_open()
        stdout = self.run_main("", opened)
        opened.assert_called_once_with("github-output", "a", encoding="utf-8")
        written = "".join(call.args[0] for call in opened().write.call_args_list)
        self.assertEqual(written, f"version={repository_versions()['ios']}\nios_build=2495.14.30\n"
                                  "android_version_code=3593670\nbuild_timestamp=2026-10-31T14:30Z\n")
        self.assertIn("2026-10-31T14:30Z", stdout)

    def test_rejected_version_writes_no_outputs(self):
        opened = mock.mock_open()
        with self.assertRaises(SystemExit) as raised:
            self.run_main("9.9.9", opened)
        self.assertEqual(raised.exception.code, 2)
        opened.assert_not_called()


if __name__ == "__main__":
    unittest.main()
