import contextlib
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest import mock


MODULE_PATH = Path(__file__).resolve().parents[1] / "play_release.py"
SPEC = importlib.util.spec_from_file_location("play_release", MODULE_PATH)
play = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(play)


def release(code=1234, name="1.2.3", **extra):
    return {"name": name, "versionCodes": [str(code)], "status": "completed", **extra}


def internal(*releases):
    return {"track": "internal", "releases": list(releases)}


class Response:
    def __init__(self, value=None, status=200):
        self.value = {} if value is None else value
        self.status_code = status

    def json(self):
        if isinstance(self.value, Exception):
            raise self.value
        return self.value


class Session:
    def __init__(self, *responses):
        self.responses = list(responses)
        self.calls = []
        self.closed = False

    def request(self, method, url, **kwargs):
        # Do not retain an already closed bundle stream in test evidence.
        call = {"method": method, "url": url, **kwargs}
        if "data" in call:
            call["data"] = call["data"].read()
        self.calls.append(call)
        response = self.responses.pop(0)
        if isinstance(response, Exception):
            raise response
        return response

    def close(self):
        self.closed = True


class SelectionTests(unittest.TestCase):
    def test_latest_uses_numeric_codes_not_list_order(self):
        selected = play.latest_internal(internal(release(100), release(1100), release(999)))
        self.assertEqual(selected["versionCodes"], ["1100"])

    def test_missing_or_ambiguous_latest_fails(self):
        invalid = [
            {}, {"track": "production", "releases": [release()]}, internal(),
            internal({"name": "1.2.3", "status": "completed"}),
            internal(release(), release()),
            internal(release(versionCodes=["1234", "1235"])),
            internal(release(1234), release(1235, status="draft")),
            internal(release(name="unreviewed release name")),
            internal(release(versionCodes=["0"])),
            internal(release(versionCodes=[True])),
        ]
        for track in invalid:
            with self.subTest(track=track), self.assertRaises(play.ReleaseError):
                play.latest_internal(track)

    def test_release_metadata_has_no_testing_rollout_or_targeting(self):
        selected = play.latest_internal(internal(release(
            releaseNotes=[{"language": "en-US", "text": "Reviewed notes"}],
            inAppUpdatePriority=2, userFraction=0.25,
            countryTargeting={"countries": ["JP"]}, unknown="do not copy")))
        self.assertEqual(set(selected), {"name", "versionCodes", "status", "releaseNotes", "inAppUpdatePriority"})

    def test_malformed_notes_and_priority_fail(self):
        for extra in [{"releaseNotes": [{"language": "en-US"}]},
                      {"inAppUpdatePriority": True}, {"inAppUpdatePriority": 6}]:
            with self.subTest(extra=extra), self.assertRaises(play.ReleaseError):
                play.latest_internal(internal(release(**extra)))

    def test_numeric_build_bounds(self):
        for value in [0, -1, True, "1.0", " 123", "2e3", 2_100_000_001, None]:
            with self.subTest(value=value), self.assertRaises(play.ReleaseError):
                play.version_code(value)
        self.assertEqual(play.version_code("2100000000"), 2_100_000_000)


class ReleaseNotesTests(unittest.TestCase):
    def test_mapping_converts_to_play_list_in_order(self):
        notes = {"en-US": "Line one\nLine two \u2728", "ja-JP": "\u99c5" * 500, "es-419": "Hola", "zh-Hant-TW": "x"}
        self.assertEqual(play.release_notes_payload(notes),
                         [{"language": language, "text": text} for language, text in notes.items()])

    def test_invalid_mapping_fails_without_echoing_text(self):
        invalid = [
            None, [], "en-US", {}, {"en_US": "x"}, {"en-us": "x"}, {"english": "x"}, {"": "x"},
            {"en-US-": "x"}, {" en-US": "x"}, {"en-US": ""}, {"en-US": " \n "}, {"en-US": 5},
            {"en-US": None}, {"en-US": ["x"]}, {"en-US": {"text": "x"}}, {"en-US": "secret" + "x" * 495},
            {"en-US": "secret\x00"}, {"en-US": "secret\r\n"}, {"en-US": "secret\ud800"},
        ]
        for notes in invalid:
            with self.subTest(notes=notes), self.assertRaises(play.ReleaseError) as error:
                play.release_notes_payload(notes)
            self.assertNotIn("secret", str(error.exception))

    def test_file_requires_unique_utf8_json_object(self):
        for content in ['{"en-US": "a", "en-US": "b"}', "not json", '["en-US", "a"]', '{"en-US": "a"} trailing']:
            with self.subTest(content=content), mock.patch.object(play.Path, "read_text", return_value=content), \
                    self.assertRaises(play.ReleaseError):
                play.read_release_notes(Path("notes.json"))
        with mock.patch.object(play.Path, "read_text", side_effect=UnicodeDecodeError("utf-8", b"\xff", 0, 1, "bad")), \
                self.assertRaisesRegex(play.ReleaseError, "UTF-8 JSON"):
            play.read_release_notes(Path("notes.json"))
        with self.assertRaisesRegex(play.ReleaseError, "could not read the release notes file"):
            play.read_release_notes(Path("/nonexistent/notes.json"))


class ApiTests(unittest.TestCase):
    def test_inspection_discards_without_update_or_commit(self):
        session = Session(Response({"id": "edit-1"}), Response(internal(release())), Response())
        result = play.PlayRelease(session).inspect()
        self.assertEqual(result["version"], "1.2.3")
        self.assertEqual(result["version_code"], 1234)
        self.assertFalse(result["committed"])
        self.assertEqual([c["method"] for c in session.calls], ["POST", "GET", "DELETE"])
        self.assertFalse(any(":commit" in c["url"] for c in session.calls))

    def test_inspection_missing_track_still_discards(self):
        session = Session(Response({"id": "edit-1"}), Response(internal()), Response())
        with self.assertRaises(play.ReleaseError):
            play.PlayRelease(session).inspect()
        self.assertEqual(session.calls[-1]["method"], "DELETE")

    def test_upload_is_internal_only_checks_bundle_code_and_safe_commit(self):
        session = Session(Response({"id": "edit-1"}), Response({"versionCode": 1234}), Response(), Response())
        with tempfile.TemporaryDirectory() as folder:
            bundle = Path(folder) / "app.aab"
            bundle.write_bytes(b"synthetic AAB payload")
            result = play.PlayRelease(session).upload(bundle, "1.2.3", 1234)
        self.assertEqual(result["bundle_sha256"], hashlib.sha256(b"synthetic AAB payload").hexdigest())
        self.assertTrue(result["committed"])
        upload = session.calls[1]
        self.assertTrue(upload["url"].startswith(play.UPLOAD_API))
        self.assertEqual(upload["data"], b"synthetic AAB payload")
        self.assertEqual(upload["params"], {"uploadType": "media"})
        self.assertEqual(session.calls[2]["json"], {"track": "internal", "releases": [release()]})
        self.assertEqual(session.calls[-1]["params"], {"changesInReviewBehavior": "ERROR_IF_IN_REVIEW"})
        self.assertNotIn("json", session.calls[-1])
        self.assertFalse(any("production" in c["url"] for c in session.calls))

    def test_upload_wrong_version_never_updates_track(self):
        session = Session(Response({"id": "edit-1"}), Response({"versionCode": 5}), Response())
        with tempfile.TemporaryDirectory() as folder:
            bundle = Path(folder) / "app.aab"
            bundle.write_bytes(b"payload")
            with self.assertRaisesRegex(play.ReleaseError, "does not match"):
                play.PlayRelease(session).upload(bundle, "1.2.3", 1234)
        self.assertEqual([c["method"] for c in session.calls], ["POST", "POST", "DELETE"])

    def test_upload_missing_bundle_creates_no_edit(self):
        session = Session()
        with self.assertRaises(play.ReleaseError):
            play.PlayRelease(session).upload(Path("/nonexistent/app.aab"), "1.2.3", 1234)
        self.assertEqual(session.calls, [])

    def test_promotion_reuses_existing_code_and_notes_without_upload(self):
        selected = release(releaseNotes=[{"language": "en-US", "text": "Reviewed notes"}], inAppUpdatePriority=2)
        session = Session(Response({"id": "edit-1"}), Response(internal(selected)),
                          Response({"track": "production", "releases": [release(1230)]}), Response(), Response())
        result = play.PlayRelease(session).promote("1.2.3", 1234)
        self.assertEqual(result["source_track"], "internal")
        self.assertEqual(result["release_notes_source"], "internal")
        self.assertEqual(session.calls[3]["json"], {"track": "production", "releases": [selected]})
        self.assertEqual(session.calls[-1]["params"], {"changesInReviewBehavior": "ERROR_IF_IN_REVIEW"})
        self.assertFalse(any("/bundles" in c["url"] for c in session.calls))
        self.assertFalse(any("/tracks/internal" in c["url"] and c["method"] == "PUT" for c in session.calls))

    def test_promotion_replaces_notes_and_keeps_selected_build(self):
        selected = release(releaseNotes=[{"language": "en-US", "text": "Old"}, {"language": "de-DE", "text": "Alt"}],
                           inAppUpdatePriority=2)
        session = Session(Response({"id": "edit-1"}), Response(internal(selected)),
                          Response({"track": "production", "releases": [release(1230)]}), Response(), Response())
        result = play.PlayRelease(session).promote("1.2.3", 1234, release_notes={"en-US": "New notes"})
        self.assertEqual(result["release_notes_source"], "supplied")
        self.assertEqual(result["version_code"], 1234)
        self.assertEqual(session.calls[3]["method"], "PUT")
        self.assertEqual(session.calls[3]["json"], {"track": "production", "releases": [
            release(releaseNotes=[{"language": "en-US", "text": "New notes"}], inAppUpdatePriority=2)]})
        self.assertEqual(sum(":commit" in c["url"] for c in session.calls), 1)

    def test_invalid_promotion_notes_create_no_edit(self):
        session = Session()
        with self.assertRaises(play.ReleaseError):
            play.PlayRelease(session).promote("1.2.3", 1234, release_notes={"en-US": "x" * 501})
        self.assertEqual(session.calls, [])

    def test_promotion_notes_are_not_applied_when_selection_checks_fail(self):
        session = Session(Response({"id": "edit-1"}), Response(internal(release())), Response())
        with self.assertRaises(play.ReleaseError):
            play.PlayRelease(session).promote("1.2.3", 1235, release_notes={"en-US": "New notes"})
        self.assertEqual([c["method"] for c in session.calls], ["POST", "GET", "DELETE"])

    def test_promotion_first_release_works_with_empty_production(self):
        session = Session(Response({"id": "edit-1"}), Response(internal(release())),
                          Response({"track": "production"}), Response(), Response())
        self.assertTrue(play.PlayRelease(session).promote()["committed"])

    def test_changed_pin_fails_before_production_update(self):
        for version, code in [("1.2.4", 1234), ("1.2.3", 1235)]:
            session = Session(Response({"id": "edit-1"}), Response(internal(release())), Response())
            with self.subTest(version=version, code=code), self.assertRaises(play.ReleaseError):
                play.PlayRelease(session).promote(version, code)
            self.assertEqual([c["method"] for c in session.calls], ["POST", "GET", "DELETE"])

    def test_production_equal_newer_or_unfinished_fails(self):
        for prior in [release(1234), release(1235), release(1200, status="inProgress"),
                      release(1200, status="halted"), release(1200, status="draft")]:
            session = Session(Response({"id": "edit-1"}), Response(internal(release())),
                              Response({"track": "production", "releases": [prior]}), Response())
            with self.subTest(prior=prior), self.assertRaises(play.ReleaseError):
                play.PlayRelease(session).promote()
            self.assertFalse(any(c["method"] == "PUT" for c in session.calls))

    def test_commit_review_rejection_is_not_retried_or_downgraded(self):
        session = Session(Response({"id": "edit-1"}), Response(internal(release())),
                          Response({"track": "production"}), Response(),
                          Response({"error": {"status": "FAILED_PRECONDITION", "message": "secret payload"}}, 400), Response())
        with self.assertRaisesRegex(play.ReleaseError, "HTTP 400") as error:
            play.PlayRelease(session).promote()
        self.assertNotIn("secret payload", str(error.exception))
        self.assertEqual(sum(":commit" in c["url"] for c in session.calls), 1)
        self.assertEqual(session.calls[-1]["method"], "DELETE")

    def test_network_exception_and_cleanup_failures_are_redacted(self):
        session = Session(Response({"id": "edit-1"}), RuntimeError("private_token"), RuntimeError("private_key"))
        with contextlib.redirect_stderr(io.StringIO()) as warnings:
            with self.assertRaises(play.ReleaseError) as error:
                play.PlayRelease(session).inspect()
        self.assertNotIn("private", str(error.exception))
        self.assertNotIn("private", warnings.getvalue())

    def test_http_redirect_is_rejected(self):
        session = Session(Response({}, 302))
        with self.assertRaisesRegex(play.ReleaseError, "HTTP 302"):
            play.PlayRelease(session).inspect()
        self.assertFalse(session.calls[0]["allow_redirects"])

    def test_cli_writes_sanitized_metadata(self):
        session = Session(Response({"id": "edit-1"}), Response(internal(release())), Response())
        with tempfile.TemporaryDirectory() as folder:
            output = Path(folder) / "metadata.json"
            with mock.patch.object(play, "authorized_session", return_value=session), contextlib.redirect_stdout(io.StringIO()) as stdout:
                self.assertEqual(play.main(["inspect-latest-internal", "--metadata-out", str(output)]), 0)
            self.assertEqual(json.loads(output.read_text()), json.loads(stdout.getvalue()))
        self.assertTrue(session.closed)

    def test_cli_invalid_inputs_do_not_load_credentials(self):
        with mock.patch.object(play, "authorized_session") as auth, contextlib.redirect_stderr(io.StringIO()):
            result = play.main(["upload-internal", "--bundle", "ignored", "--version", "1.2.3", "--version-code", "0"])
        self.assertEqual(result, 1)
        auth.assert_not_called()

    def test_cli_promotion_applies_release_notes_file(self):
        selected = release(releaseNotes=[{"language": "en-US", "text": "Old"}])
        for argv, notes, source in [
            (["--release-notes-file", "notes.json"], [{"language": "en-US", "text": "Improved station names."}], "supplied"),
            ([], selected["releaseNotes"], "internal"),
        ]:
            session = Session(Response({"id": "edit-1"}), Response(internal(selected)),
                              Response({"track": "production"}), Response(), Response())
            with self.subTest(argv=argv), mock.patch.object(play, "authorized_session", return_value=session), \
                    mock.patch.object(play.Path, "read_text", autospec=True,
                                      return_value='{"en-US": "Improved station names."}') as read, \
                    contextlib.redirect_stdout(io.StringIO()) as stdout:
                self.assertEqual(play.main(["promote-latest-to-production", "--expected-version", "1.2.3",
                                            "--expected-version-code", "1234", *argv]), 0)
                self.assertEqual(session.calls[3]["json"]["releases"][0]["releaseNotes"], notes)
                self.assertEqual(json.loads(stdout.getvalue())["release_notes_source"], source)
                self.assertEqual(read.call_args_list,
                                 [mock.call(Path("notes.json"), encoding="utf-8")] if argv else [])
                self.assertTrue(session.closed)

    def test_cli_invalid_release_notes_do_not_load_credentials(self):
        for content in ['{"en-US": ""}', '{"en_US": "Notes"}', '{"en-US": "%s"}' % ("x" * 501), "{"]:
            with self.subTest(content=content), mock.patch.object(play, "authorized_session") as auth, \
                    mock.patch.object(play.Path, "read_text", return_value=content), \
                    contextlib.redirect_stderr(io.StringIO()) as stderr:
                self.assertEqual(play.main(["promote-latest-to-production", "--release-notes-file", "notes.json"]), 1)
            auth.assert_not_called()
            self.assertIn("release notes", stderr.getvalue())
        with mock.patch.object(play, "authorized_session") as auth, contextlib.redirect_stderr(io.StringIO()) as stderr:
            self.assertEqual(play.main(["promote-latest-to-production", "--release-notes-file", "/nonexistent/notes.json"]), 1)
        auth.assert_not_called()
        self.assertIn("could not read the release notes file", stderr.getvalue())


if __name__ == "__main__":
    unittest.main()
