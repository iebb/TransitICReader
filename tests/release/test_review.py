"""Synthetic store fakes only: these tests never load credentials or contact Apple or Google."""

from contextlib import ExitStack, redirect_stderr, redirect_stdout
from copy import deepcopy
from io import StringIO
import json
import os
from pathlib import Path
import unittest
from unittest.mock import patch

from tools.release import review
from tools.release.app_store import ReleaseError as AppleError


play = review.load_play()
SECRET = "DO-NOT-PERSIST-CREDENTIAL"
ENV = {"ASC_APP_ID": "6760978958", "ASC_KEY_ID": SECRET, "ASC_ISSUER_ID": SECRET,
       "ASC_PRIVATE_KEY_PATH": "/private/" + SECRET, "GOOGLE_PLAY_SERVICE_ACCOUNT_JSON": SECRET}
NOTES = {"en-GB": "Added Clipper.", "ja": "Clipperに対応しました。"}
NOTES_PATH = review.ROOT / "docs/release-notes/2.5.0.json"
SELECTION, RESULT = Path("build/review/selection.json"), Path("build/review/result.json")


def plan(build_id="build-250", blockers=()):
    return {"app_id": "6760978958", "action": "submit_for_review", "blockers": list(blockers),
            "build": {"id": build_id, "version": "2.5.0", "build_number": "2130.1.5", "uploaded_at": "2026-10-31T00:00:00Z"}}


class Stores:
    """Records store calls in one ordered log instead of contacting either store."""

    def __init__(self):
        self.events, self.files = [], {}
        self.initial_plan, self.notes_plan = plan(), plan()
        self.internal = {"action": "inspect-latest-internal", "package": play.PACKAGE, "track": "internal",
                         "version": "2.5.0", "version_code": 3045060, "committed": False}
        self.submit_error = self.promote_error = None

    def app_store_api(self, *, allow_writes=False):
        self.events.append(("apple.api", allow_writes))
        return "writable-api" if allow_writes else "read-only-api"

    def inspect_release(self, api, app_id, *, notes=None):
        self.events.append(("apple.inspect", api, app_id, deepcopy(notes)))
        return deepcopy(self.notes_plan if notes else self.initial_plan)

    def submit_release(self, api, app_id, *, notes=None, expected_build_id=None):
        self.events.append(("apple.submit", api, app_id, deepcopy(notes), expected_build_id))
        if self.submit_error:
            raise self.submit_error
        return {**plan(), "result": "submitted_for_review"}

    def authorized_session(self, credentials_file):
        self.events.append(("play.session", credentials_file))
        return self

    def close(self):
        self.events.append(("play.close",))

    def PlayRelease(self, session):
        return self

    def inspect(self):
        self.events.append(("play.inspect",))
        return deepcopy(self.internal)

    def promote(self, expected_version=None, expected_code=None, release_notes=None):
        self.events.append(("play.promote", expected_version, expected_code, deepcopy(release_notes)))
        if self.promote_error:
            raise self.promote_error
        return {**self.internal, "action": "promote-latest-to-production", "track": "production", "committed": True}

    def read_text(self, path):
        return self.files.get(Path(path))

    def write_text(self, path, text):
        self.files[Path(path)] = text

    def json(self, path):
        return json.loads(self.files[path])

    def names(self):
        return [event[0] for event in self.events]


class ReviewCase(unittest.TestCase):
    def setUp(self):
        self.stores = stores = Stores()
        stack = ExitStack()
        self.addCleanup(stack.close)
        stack.enter_context(patch.dict(os.environ, ENV, clear=True))
        for name in ("AppStoreAPI", "inspect_release", "submit_release", "read_text", "write_text"):
            replacement = stores.app_store_api if name == "AppStoreAPI" else getattr(stores, name)
            stack.enter_context(patch.object(review, name, replacement))
        for name in ("authorized_session", "PlayRelease"):
            stack.enter_context(patch.object(play, name, getattr(stores, name)))
        stores.files[NOTES_PATH] = json.dumps(NOTES)

    def run_cli(self, *argv):
        stdout, stderr = StringIO(), StringIO()
        with redirect_stdout(stdout), redirect_stderr(stderr):
            code = review.main(list(argv))
        return code, stdout.getvalue() + stderr.getvalue()

    def select(self, platforms="both"):
        return self.run_cli("select", "--platforms", platforms, "--output", str(SELECTION))

    def submit(self):
        return self.run_cli("submit", "--selection-file", str(SELECTION), "--output", str(RESULT))


class SelectTests(ReviewCase):
    def test_pins_both_builds_app_id_and_store_specific_notes_without_credentials(self):
        code, output = self.select()
        self.assertEqual(code, 0, output)
        selection = self.stores.json(SELECTION)
        self.assertEqual((selection["status"], selection["platforms"], selection["version"]), ("selected", ["ios", "android"], "2.5.0"))
        self.assertEqual(selection["release_notes_source"], "docs/release-notes/2.5.0.json")
        self.assertEqual({key: selection["ios"][key] for key in ("app_id", "build_id", "release_notes")},
                         {"app_id": "6760978958", "build_id": "build-250", "release_notes": NOTES})
        self.assertEqual(selection["android"], {"package": play.PACKAGE, "version": "2.5.0", "version_code": 3045060,
                                                "release_notes": {"en-US": "Added Clipper."}})
        self.assertEqual([event for event in self.stores.events if event[0] == "apple.inspect"],
                         [("apple.inspect", "read-only-api", "6760978958", None),
                          ("apple.inspect", "read-only-api", "6760978958", NOTES)])
        self.assertNotIn(("apple.api", True), self.stores.events)
        self.assertEqual([event for event in self.stores.events if event[0].startswith("play.")],
                         [("play.session", None), ("play.inspect",), ("play.close",)])
        self.assertNotIn(SECRET, self.stores.files[SELECTION])

    def test_notes_override_missing_file_and_missing_en_gb(self):
        cases = [({"RELEASE_NOTES_JSON": json.dumps({"en-GB": "Override."})}, True, "RELEASE_NOTES_JSON", {"en-US": "Override."}),
                 ({}, False, None, None), ({"RELEASE_NOTES_JSON": json.dumps({"ja": "日本語"})}, True, "RELEASE_NOTES_JSON", None)]
        for environ, file_exists, source, play_notes in cases:
            with self.subTest(environ=environ, file_exists=file_exists), patch.dict(os.environ, environ):
                self.stores.files = {NOTES_PATH: json.dumps(NOTES)} if file_exists else {}
                self.stores.events.clear()
                self.assertEqual(self.select()[0], 0)
                selection = self.stores.json(SELECTION)
                self.assertEqual(selection["release_notes_source"], source)
                self.assertEqual(selection["ios"]["release_notes"], json.loads(environ["RELEASE_NOTES_JSON"]) if source else None)
                self.assertEqual(selection["android"]["release_notes"], play_notes)
                # Existing App Store notes need no second inspection.
                self.assertEqual(self.stores.names().count("apple.inspect"), 2 if source else 1)

    def test_disabled_platform_reads_no_configuration_or_credentials(self):
        with patch.dict(os.environ, {"ASC_APP_ID": ""}):
            self.assertEqual(self.select("android")[0], 0)
        self.assertNotIn("ios", self.stores.json(SELECTION))
        self.assertFalse([name for name in self.stores.names() if name.startswith("apple.")])
        self.stores.events.clear()
        self.assertEqual(self.select("ios")[0], 0)
        self.assertNotIn("android", self.stores.json(SELECTION))
        self.assertFalse([name for name in self.stores.names() if name.startswith("play.")])

    def test_mismatched_versions_invalid_notes_and_changed_builds_abort_without_selection(self):
        def changed_version():
            self.stores.internal["version"] = "2.4.1"

        def changed_build():
            self.stores.notes_plan = plan("newer-build")

        cases = [(changed_version, {}, "differ"), (changed_build, {}, "changed during selection"),
                 (None, {"RELEASE_NOTES_JSON": "not json"}, "must be JSON"),
                 (None, {"RELEASE_NOTES_JSON": "{}"}, "nonempty"),
                 (None, {"RELEASE_NOTES_JSON": json.dumps({"en-GB": "x" * 501})}, "exceed 500")]
        for change, environ, message in cases:
            self.setUp()
            with self.subTest(message=message), patch.dict(os.environ, environ):
                if change:
                    change()
                code, output = self.select()
                self.assertEqual(code, 1)
                self.assertIn(message, output)
                self.assertNotIn(SELECTION, self.stores.files)

    def test_apple_blockers_are_recorded_but_cannot_be_submitted(self):
        self.stores.notes_plan = plan(blockers=["The ko localization needs actual What's New text."])
        code, output = self.select()
        self.assertEqual(code, 2)
        self.assertIn("ko localization", output)
        self.assertEqual(self.stores.json(SELECTION)["status"], "blocked")
        self.stores.events.clear()
        code, output = self.submit()
        self.assertEqual(code, 1)
        self.assertIn("unresolved blockers", output)
        self.assertFalse(self.stores.events)
        self.assertNotIn(RESULT, self.stores.files)

    def test_store_errors_fail_without_selection(self):
        self.stores.initial_plan = None
        with patch.object(review, "inspect_release", side_effect=AppleError("Missing environment variables: ASC_KEY_ID")):
            code, output = self.select()
        self.assertEqual(code, 1)
        self.assertIn("App Store Connect: Missing environment variables", output)
        self.assertNotIn(SELECTION, self.stores.files)


class SubmitTests(ReviewCase):
    def setUp(self):
        super().setUp()
        self.assertEqual(self.select()[0], 0)
        self.stores.events.clear()

    def test_submits_pinned_ios_build_then_promotes_pinned_play_build(self):
        code, output = self.submit()
        self.assertEqual(code, 0, output)
        self.assertEqual(self.stores.events, [
            ("play.session", None), ("play.inspect",), ("apple.api", True),
            ("apple.submit", "writable-api", "6760978958", NOTES, "build-250"),
            ("play.promote", "2.5.0", 3045060, {"en-US": "Added Clipper."}), ("play.close",),
        ])
        result = self.stores.json(RESULT)
        self.assertEqual((result["status"], result["ios"]["outcome"], result["android"]["outcome"]),
                         ("succeeded", "submitted_for_review", "promote-latest-to-production"))
        self.assertNotIn(SECRET, self.stores.files[RESULT])

    def test_without_notes_both_stores_keep_existing_notes(self):
        self.stores.files = {}
        self.assertEqual(self.select()[0], 0)
        self.stores.events.clear()
        self.assertEqual(self.submit()[0], 0)
        self.assertIn(("apple.submit", "writable-api", "6760978958", None, "build-250"), self.stores.events)
        self.assertIn(("play.promote", "2.5.0", 3045060, None), self.stores.events)

    def test_ios_failure_is_recorded_and_play_is_not_promoted(self):
        self.stores.submit_error = AppleError("Cannot release: App Review information is missing contactPhone.")
        code, output = self.submit()
        self.assertEqual(code, 1)
        self.assertIn("contactPhone", output)
        self.assertNotIn("play.promote", self.stores.names())
        result = self.stores.json(RESULT)
        self.assertEqual((result["status"], result["ios"]["status"], result["android"]["status"]), ("failed", "failed", "not_attempted"))

    def test_play_failure_after_ios_submission_is_recorded_as_partial(self):
        self.stores.promote_error = play.ReleaseError("Play API commit edit failed: HTTP 409 (FAILED_PRECONDITION)")
        self.assertEqual(self.submit()[0], 1)
        result = self.stores.json(RESULT)
        self.assertEqual((result["status"], result["ios"]["status"]), ("partial", "succeeded"))
        self.assertEqual(result["android"], {"status": "failed", "error": "Play API commit edit failed: HTTP 409 (FAILED_PRECONDITION)"})
        self.assertEqual(self.stores.names()[-1], "play.close")

    def test_unexpected_errors_are_recorded_without_details_then_raised(self):
        self.stores.promote_error = RuntimeError("detail that may contain " + SECRET)
        with self.assertRaises(RuntimeError):
            self.submit()
        result = self.stores.json(RESULT)
        self.assertEqual((result["status"], result["android"]["status"]), ("partial", "failed"))
        self.assertNotIn(SECRET, self.stores.files[RESULT])

    def test_changed_play_build_or_app_id_stops_before_any_store_change(self):
        self.stores.internal["version_code"] += 1
        self.assertEqual(self.submit()[0], 1)
        self.assertEqual(self.stores.names(), ["play.session", "play.inspect", "play.close"])
        result = self.stores.json(RESULT)
        self.assertEqual((result["ios"]["status"], result["android"]["status"]), ("not_attempted", "failed"))
        self.stores.events.clear()
        del self.stores.files[RESULT]
        with patch.dict(os.environ, {"ASC_APP_ID": "1"}):
            code, output = self.submit()
        self.assertEqual(code, 1)
        self.assertIn("ASC_APP_ID differs", output)
        self.assertFalse(self.stores.events)
        self.assertNotIn(RESULT, self.stores.files)

    def test_android_only_submission_skips_apple(self):
        with patch.dict(os.environ, {"ASC_APP_ID": ""}):
            self.assertEqual(self.select("android")[0], 0)
            self.stores.events.clear()
            self.assertEqual(self.submit()[0], 0)
        self.assertFalse([name for name in self.stores.names() if name.startswith("apple.")])
        self.assertEqual(self.stores.json(RESULT)["platforms"], ["android"])

    def test_malformed_selection_is_refused_before_credentials(self):
        selection = self.stores.json(SELECTION)
        broken = [{**selection, "schema": 2}, {**selection, "platforms": ["android", "ios"]},
                  {**selection, "ios": {**selection["ios"], "build_id": ""}},
                  {**selection, "android": {**selection["android"], "version_code": True}},
                  {**selection, "android": {**selection["android"], "release_notes": {"en-US": ""}}}]
        for document in broken:
            with self.subTest(document=document):
                self.stores.files[SELECTION] = json.dumps(document)
                self.assertEqual(self.submit()[0], 1)
                self.assertFalse(self.stores.events)
                self.assertNotIn(RESULT, self.stores.files)


if __name__ == "__main__":
    unittest.main()
