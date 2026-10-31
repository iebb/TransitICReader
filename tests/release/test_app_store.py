"""Synthetic ASC fixtures only: these tests never use keys or contact Apple."""

from copy import deepcopy
from datetime import datetime, timezone
from io import BytesIO, StringIO
import json
import os
from pathlib import Path
import sys
from types import ModuleType
import unittest
from unittest.mock import Mock, patch
from urllib.error import HTTPError

from tools.release import app_store as release


NOW = datetime(2026, 10, 28, tzinfo=timezone.utc)
TEAM_ENV = {"ASC_KEY_ID": "SYNTHETICKID", "ASC_ISSUER_ID": "synthetic-issuer", "ASC_PRIVATE_KEY_PATH": "/synthetic/AuthKey.p8"}
INDIVIDUAL_ENV = {"ASC_KEY_TYPE": "individual", "ASC_KEY_ID": "SYNTHETICKID", "ASC_PRIVATE_KEY_PATH": "/synthetic/AuthKey.p8"}


def without(environ, name):
    return {key: value for key, value in environ.items() if key != name}


def resource(kind, resource_id, attributes=None, **relationships):
    return {"type": kind, "id": resource_id, "attributes": attributes or {}, "relationships": {
        name: {"data": {"type": target[0], "id": target[1]}} for name, target in relationships.items()
    }}


def build_fixture(build_id="build-10", marketing_version="1.10", uploaded="2026-10-27T12:00:00Z", **attributes):
    build = resource("builds", build_id, {
        "version": "10", "uploadedDate": uploaded, "expirationDate": "2027-01-01T00:00:00Z",
        "processingState": "VALID", "expired": False, "buildAudienceType": "APP_STORE_ELIGIBLE",
        "usesNonExemptEncryption": False, **attributes,
    }, preReleaseVersion=("preReleaseVersions", "pre-" + build_id), buildBetaDetail=("buildBetaDetails", "beta-" + build_id))
    included = [resource("preReleaseVersions", "pre-" + build_id, {"version": marketing_version, "platform": "IOS"}),
                resource("buildBetaDetails", "beta-" + build_id, {"internalBuildState": "IN_BETA_TESTING", "externalBuildState": "IN_BETA_TESTING"})]
    return build, included


def version_fixture(version_id="draft", marketing_version="1.10", current_state="PREPARE_FOR_SUBMISSION", build_id="build-10", release_type="MANUAL"):
    version = resource("appStoreVersions", version_id, {"versionString": marketing_version, "platform": "IOS",
        "appVersionState": current_state, "releaseType": release_type}, build=("builds", build_id))
    if build_id is None:
        version["relationships"]["build"]["data"] = None
    return version


class FakeAPI:
    def __init__(self):
        build, included = build_fixture()
        self.builds, self.included = [build], included
        self.versions = [version_fixture(), version_fixture("live", "1.9", "READY_FOR_DISTRIBUTION", "build-9")]
        self.submissions, self.items = [], {}
        self.localizations = [resource("appStoreVersionLocalizations", "en", {
            "locale": "en-US", "description": "An actual app description.", "supportUrl": "https://example.com/support", "whatsNew": "Actual changes for this version.",
        })]
        self.review = resource("appStoreReviewDetails", "review", {
            "contactFirstName": "Example", "contactLastName": "Reviewer", "contactPhone": "+10000000000",
            "contactEmail": "review@example.com", "demoAccountRequired": False,
            "notes": "DO NOT PRINT REVIEW DATA", "demoAccountPassword": "DO NOT PRINT PASSWORD",
        })
        self.calls = []

    def collection(self, path, params=None):
        self.calls.append(("GET", path, params))
        if path == "/v1/builds":
            return deepcopy(self.builds), deepcopy(self.included)
        if path.endswith("/appStoreVersions"):
            return deepcopy(self.versions), []
        if path.endswith("/appStoreVersionLocalizations"):
            return deepcopy(self.localizations), []
        if path == "/v1/reviewSubmissions":
            return deepcopy(self.submissions), []
        if path.endswith("/items"):
            return deepcopy(self.items[path.split("/")[-2]]), []
        raise AssertionError(path)

    def request(self, method, path, *, params=None, data=None):
        self.calls.append((method, path, deepcopy(data)))
        if method == "GET" and path == "/v1/apps/123":
            return {"data": resource("apps", "123", {"primaryLocale": "en-US"})}
        if method == "GET" and path.endswith("/appStoreReviewDetail"):
            return {"data": deepcopy(self.review)}
        if method == "POST" and path == "/v1/appStoreVersions":
            self.versions.insert(0, version_fixture("created"))
            return {"data": self.versions[0]}
        if method == "PATCH" and path.startswith("/v1/appStoreVersions/"):
            version = next(item for item in self.versions if item["id"] == path.split("/")[-1])
            version["attributes"].update(deepcopy(data["data"].get("attributes", {})))
            version["relationships"].update(deepcopy(data["data"].get("relationships", {})))
            return {"data": deepcopy(version)}
        if method == "POST" and path == "/v1/reviewSubmissions":
            return {"data": resource("reviewSubmissions", "new-submission")}
        if method in {"POST", "PATCH"}:
            return {"data": resource("synthetic", "result")}
        raise AssertionError((method, path))

    @property
    def writes(self):
        return [call for call in self.calls if call[0] != "GET"]


class BuildSelectionTests(unittest.TestCase):
    def test_numeric_marketing_version_then_newest_upload(self):
        fixtures = [build_fixture("older-version", "1.9", "2026-10-28T00:00:00Z"),
                    build_fixture("older-upload", "1.10", "2026-10-26T00:00:00Z"),
                    build_fixture("selected", "1.10", "2026-10-27T00:00:00Z")]
        chosen, _ = release.latest_build([item[0] for item in fixtures], sum([item[1] for item in fixtures], []), NOW)
        self.assertEqual(chosen["id"], "selected")

    def test_skips_processing_failed_invalid_internal_expired_rejected_and_other_platform(self):
        fixtures = [build_fixture()]
        for name, fields in [("processing", {"processingState": "PROCESSING"}), ("failed", {"processingState": "FAILED"}),
                             ("invalid", {"processingState": "INVALID"}), ("internal", {"buildAudienceType": "INTERNAL_ONLY"}),
                             ("expired", {"expired": True}), ("expired-date", {"expirationDate": "2026-10-01T00:00:00Z"}),
                             ("unknown-expiration", {"expirationDate": None})]:
            fixtures.append(build_fixture(name, "2.0", **fields))
        rejected = build_fixture("rejected", "3.0")
        rejected[1][1]["attributes"]["externalBuildState"] = "BETA_REJECTED"
        fixtures.append(rejected)
        mac = build_fixture("mac", "4.0")
        mac[1][0]["attributes"]["platform"] = "MAC_OS"
        fixtures.append(mac)
        chosen, skipped = release.latest_build([item[0] for item in fixtures], sum([item[1] for item in fixtures], []), NOW)
        self.assertEqual(chosen["id"], "build-10")
        self.assertEqual(sum(skipped.values()), len(fixtures) - 1)

    def test_invalid_or_absent_versions_fail_clearly(self):
        with self.assertRaisesRegex(release.ReleaseError, "No processed VALID"):
            release.latest_build([], [], NOW)
        build, included = build_fixture(marketing_version="1.2-beta")
        with self.assertRaisesRegex(release.ReleaseError, "nonnumeric"):
            release.latest_build([build], included, NOW)


class PromotionTests(unittest.TestCase):
    def setUp(self):
        self.api = FakeAPI()
        clock_patch = patch.object(release, "datetime", wraps=datetime)
        clock = clock_patch.start()
        clock.now.return_value = NOW
        self.addCleanup(clock_patch.stop)

    def plan(self, **kwargs):
        return release.inspect_release(self.api, "123", now=NOW, **kwargs)

    def test_selection_is_read_only_and_does_not_output_review_credentials(self):
        plan = self.plan()
        self.assertFalse(plan["blockers"])
        self.assertEqual(plan["action"], "submit_for_review")
        self.assertFalse(self.api.writes)
        self.assertNotIn("DO NOT PRINT", json.dumps(plan))
        self.assertNotIn("review@example.com", json.dumps(plan))

    def test_submit_binds_existing_build_automatic_release_and_current_review_flow(self):
        plan = release.submit_release(self.api, "123", expected_build_id="build-10")
        self.assertEqual(plan["result"], "submitted_for_review")
        self.assertEqual([(call[0], call[1]) for call in self.api.writes], [
            ("PATCH", "/v1/appStoreVersions/draft"), ("POST", "/v1/reviewSubmissions"),
            ("POST", "/v1/reviewSubmissionItems"), ("PATCH", "/v1/reviewSubmissions/new-submission"),
        ])
        version_update = self.api.writes[0][2]["data"]
        self.assertEqual(version_update["attributes"], {"releaseType": "AFTER_APPROVAL"})
        self.assertEqual(version_update["relationships"]["build"]["data"]["id"], "build-10")
        self.assertEqual(self.api.writes[-1][2]["data"]["attributes"], {"submitted": True})

    def test_pending_review_and_live_builds_are_idempotent(self):
        for current_state, action in [("WAITING_FOR_REVIEW", "already_submitted"), ("IN_REVIEW", "already_submitted"),
                                      ("READY_FOR_DISTRIBUTION", "already_released"), ("READY_FOR_SALE", "already_released"),
                                      ("PENDING_APPLE_RELEASE", "release_in_progress"), ("PROCESSING_FOR_DISTRIBUTION", "release_in_progress")]:
            with self.subTest(state=current_state):
                api = FakeAPI()
                api.versions[0] = version_fixture(current_state=current_state, release_type="AFTER_APPROVAL")
                result = release.submit_release(api, "123")
                self.assertEqual(result["action"], action)
                self.assertFalse(api.writes)

    def test_pending_review_can_enable_automatic_release_without_resubmitting(self):
        self.api.versions[0] = version_fixture(current_state="IN_REVIEW")
        result = release.submit_release(self.api, "123")
        self.assertEqual(result["result"], "automatic_release_configured")
        self.assertEqual(len(self.api.writes), 1)
        self.assertEqual(self.api.writes[0][2]["data"]["attributes"], {"releaseType": "AFTER_APPROVAL"})

    def test_already_approved_manual_version_requests_release_only(self):
        self.api.versions[0] = version_fixture(current_state="PENDING_DEVELOPER_RELEASE")
        release.submit_release(self.api, "123")
        self.assertEqual([(call[0], call[1]) for call in self.api.writes], [("POST", "/v1/appStoreVersionReleaseRequests")])

    def test_cannot_replace_different_build_in_review_approved_or_live(self):
        for current_state in ["IN_REVIEW", "PENDING_DEVELOPER_RELEASE", "READY_FOR_DISTRIBUTION", "READY_FOR_REVIEW"]:
            with self.subTest(state=current_state):
                api = FakeAPI()
                api.versions[0] = version_fixture(current_state=current_state, build_id="different")
                with self.assertRaisesRegex(release.ReleaseError, "different build"):
                    release.submit_release(api, "123")
                self.assertFalse(api.writes)

    def test_missing_compliance_review_and_whats_new_are_not_fabricated(self):
        self.api.builds[0]["attributes"]["usesNonExemptEncryption"] = None
        self.api.localizations[0]["attributes"]["whatsNew"] = ""
        self.api.review["attributes"]["demoAccountRequired"] = True
        self.api.review["attributes"]["demoAccountName"] = ""
        plan = self.plan()
        self.assertTrue(any("export-compliance" in reason for reason in plan["blockers"]))
        self.assertTrue(any("What's New" in reason for reason in plan["blockers"]))
        self.assertTrue(any("demo account" in reason for reason in plan["blockers"]))
        with self.assertRaises(release.ReleaseError):
            release.submit_release(self.api, "123")
        self.assertFalse(self.api.writes)

    def test_non_exempt_encryption_requires_actual_linked_approved_declaration(self):
        self.api.builds[0]["attributes"]["usesNonExemptEncryption"] = True
        self.assertTrue(any("APPROVED encryption" in reason for reason in self.plan()["blockers"]))
        self.api.builds[0]["relationships"]["appEncryptionDeclaration"] = {"data": {"type": "appEncryptionDeclarations", "id": "declaration"}}
        self.api.included.append(resource("appEncryptionDeclarations", "declaration", {"appEncryptionDeclarationState": "IN_REVIEW"}))
        self.assertTrue(self.plan()["blockers"])
        self.api.included[-1]["attributes"]["appEncryptionDeclarationState"] = "APPROVED"
        self.assertFalse(self.plan()["blockers"])
        self.assertFalse(self.api.writes)

    def test_explicit_notes_update_only_whats_new(self):
        self.api.localizations[0]["attributes"]["whatsNew"] = ""
        release.submit_release(self.api, "123", notes={"en-US": "User-provided changes."})
        self.assertEqual(self.api.writes[0][:2], ("PATCH", "/v1/appStoreVersionLocalizations/en"))
        self.assertEqual(self.api.writes[0][2]["data"]["attributes"], {"whatsNew": "User-provided changes."})
        self.assertFalse(any("appStoreReviewDetails" in call[1] for call in self.api.writes))

    def test_unknown_notes_locale_is_blocked_without_writes(self):
        with self.assertRaisesRegex(release.ReleaseError, "unknown localization"):
            release.submit_release(self.api, "123", notes={"ja": "実際の変更"})
        self.assertFalse(self.api.writes)

    def test_ready_draft_review_item_is_reused_without_duplicate_post(self):
        self.api.submissions = [resource("reviewSubmissions", "existing", {"state": "READY_FOR_REVIEW"})]
        self.api.items["existing"] = [resource("reviewSubmissionItems", "item", {"state": "READY_FOR_REVIEW"}, appStoreVersion=("appStoreVersions", "draft"))]
        release.submit_release(self.api, "123")
        self.assertEqual([(call[0], call[1]) for call in self.api.writes], [
            ("PATCH", "/v1/appStoreVersions/draft"), ("PATCH", "/v1/reviewSubmissions/existing"),
        ])

    def test_unrelated_or_unresolved_review_submissions_are_not_submitted(self):
        for submission_state, item_kind, item_id in [("UNRESOLVED_ISSUES", "appStoreVersion", "draft"),
                                                     ("READY_FOR_REVIEW", "appEvent", "unrelated")]:
            with self.subTest(state=submission_state):
                api = FakeAPI()
                api.submissions = [resource("reviewSubmissions", "existing", {"state": submission_state})]
                api.items["existing"] = [resource("reviewSubmissionItems", "item", {"state": "READY_FOR_REVIEW"}, **{item_kind: ("appStoreVersions" if item_kind == "appStoreVersion" else "appEvents", item_id)})]
                with self.assertRaises(release.ReleaseError):
                    release.submit_release(api, "123")
                self.assertFalse(api.writes)

    def test_rejected_version_can_reuse_saved_metadata_when_previous_review_is_complete(self):
        self.api.versions[0] = version_fixture(current_state="REJECTED")
        self.api.submissions = [resource("reviewSubmissions", "previous", {"state": "COMPLETE"})]
        result = release.submit_release(self.api, "123")
        self.assertEqual(result["result"], "submitted_for_review")

    def test_newer_store_version_prevents_silent_fallback(self):
        self.api.versions.append(version_fixture("newer", "2.0"))
        plan = self.plan()
        self.assertTrue(any("rollback" in reason for reason in plan["blockers"]))

    def test_expected_build_guard_prevents_writes(self):
        with self.assertRaisesRegex(release.ReleaseError, "changed since selection"):
            release.submit_release(self.api, "123", expected_build_id="old-selection")
        self.assertFalse(self.api.writes)

    def test_create_version_rechecks_inherited_metadata_then_submits(self):
        self.api.versions.pop(0)
        result = release.submit_release(self.api, "123")
        self.assertEqual(self.api.writes[0][:2], ("POST", "/v1/appStoreVersions"))
        self.assertEqual(self.api.writes[0][2]["data"]["attributes"], {"platform": "IOS", "versionString": "1.10", "releaseType": "AFTER_APPROVAL"})
        self.assertEqual(result["app_store_version_id"], "created")
        self.assertEqual(result["result"], "submitted_for_review")

    def test_selection_of_future_version_defers_metadata_checks_until_creation(self):
        self.api.versions.pop(0)
        self.api.review = None
        self.api.localizations = []
        plan = self.plan()
        self.assertEqual(plan["action"], "create_version_and_submit")
        self.assertIsNone(plan["app_store_version_id"])
        self.assertFalse(plan["blockers"])
        self.assertTrue(plan["checks_after_create"])
        self.assertFalse(self.api.writes)

    def test_new_build_appearing_after_draft_creation_does_not_change_the_selected_release(self):
        self.api.versions.pop(0)
        original_request = self.api.request
        def request(method, path, **kwargs):
            result = original_request(method, path, **kwargs)
            if method == "POST" and path == "/v1/appStoreVersions":
                build, included = build_fixture("new-build", "1.10", "2026-10-28T00:00:00Z")
                self.api.builds.append(build)
                self.api.included.extend(included)
            return result
        with patch.object(self.api, "request", side_effect=request):
            with self.assertRaisesRegex(release.ReleaseError, "changed while preparing"):
                release.submit_release(self.api, "123", expected_build_id="build-10")
        self.assertEqual(len(self.api.writes), 1)

    def test_new_draft_with_missing_metadata_stops_before_binding_or_review(self):
        self.api.versions.pop(0)
        self.api.localizations[0]["attributes"]["whatsNew"] = ""
        with self.assertRaisesRegex(release.ReleaseError, "Created App Store draft created, but did not submit"):
            release.submit_release(self.api, "123")
        self.assertEqual(len(self.api.writes), 1)


class DraftRenameTests(unittest.TestCase):
    def setUp(self):
        self.api = FakeAPI()
        build, included = build_fixture(marketing_version="2.5.0")
        self.api.builds, self.api.included = [build], included
        self.api.versions = [
            version_fixture(marketing_version="2.4.1", build_id=None),
            version_fixture("live", "2.4.0", "READY_FOR_DISTRIBUTION", "build-9"),
        ]
        clock_patch = patch.object(release, "datetime", wraps=datetime)
        clock = clock_patch.start()
        clock.now.return_value = NOW
        self.addCleanup(clock_patch.stop)

    def test_selection_plans_one_lower_editable_draft_rename_without_writes(self):
        for current_state in ("PREPARE_FOR_SUBMISSION", "DEVELOPER_REJECTED"):
            with self.subTest(state=current_state):
                self.api.versions[0]["attributes"]["appVersionState"] = current_state
                plan = release.inspect_release(self.api, "123", now=NOW)
                self.assertEqual(plan["action"], "rename_version_and_submit")
                self.assertEqual(plan["app_store_version_id"], "draft")
                self.assertEqual(plan["app_store_state"], current_state)
                self.assertEqual(plan["rename_from_version"], "2.4.1")
                self.assertEqual(plan["build"]["version"], "2.5.0")
                self.assertFalse(plan["blockers"])
                self.assertNotIn("checks_after_create", plan)
                self.assertFalse(self.api.writes)

    def test_submit_renames_same_draft_then_binds_build_preserving_metadata(self):
        for current_state in ("PREPARE_FOR_SUBMISSION", "DEVELOPER_REJECTED"):
            for attached_build in (None, "old-build"):
                with self.subTest(state=current_state, attached_build=attached_build):
                    self.api.versions[0] = version_fixture(marketing_version="2.4.1",
                        current_state=current_state, build_id=attached_build)
                    self.api.calls.clear()
                    before = deepcopy((self.api.versions[1], self.api.localizations, self.api.review))
                    result = release.submit_release(self.api, "123", expected_build_id="build-10")
                    self.assertEqual(result["result"], "submitted_for_review")
                    self.assertEqual(result["app_store_version_id"], "draft")
                    self.assertEqual(self.api.versions[0]["attributes"]["versionString"], "2.5.0")
                    self.assertEqual(self.api.versions[0]["relationships"]["build"]["data"]["id"], "build-10")
                    self.assertEqual([(call[0], call[1]) for call in self.api.writes], [
                        ("PATCH", "/v1/appStoreVersions/draft"),
                        ("PATCH", "/v1/appStoreVersions/draft"),
                        ("POST", "/v1/reviewSubmissions"),
                        ("POST", "/v1/reviewSubmissionItems"),
                        ("PATCH", "/v1/reviewSubmissions/new-submission"),
                    ])
                    self.assertEqual(self.api.writes[0][2], {"data": {
                        "type": "appStoreVersions", "id": "draft", "attributes": {"versionString": "2.5.0"},
                    }})
                    self.assertEqual(before, (self.api.versions[1], self.api.localizations, self.api.review))

    def test_target_version_is_used_instead_of_renaming_another_draft(self):
        self.api.versions.insert(0, version_fixture("target", "2.5.0", build_id=None))
        plan = release.inspect_release(self.api, "123", now=NOW)
        self.assertEqual(plan["action"], "submit_for_review")
        self.assertEqual(plan["app_store_version_id"], "target")
        self.assertNotIn("rename_from_version", plan)
        with self.assertRaisesRegex(release.ReleaseError, "Another iOS App Store version"):
            release.submit_release(self.api, "123")
        self.assertFalse(self.api.writes)

    def test_multiple_lower_editable_drafts_are_ambiguous_and_never_renamed(self):
        self.api.versions.append(version_fixture("other-draft", "2.4.2", "DEVELOPER_REJECTED", None))
        plan = release.inspect_release(self.api, "123", now=NOW)
        self.assertNotEqual(plan["action"], "rename_version_and_submit")
        self.assertIsNone(plan["app_store_version_id"])
        with self.assertRaisesRegex(release.ReleaseError, "Multiple lower editable"):
            release.submit_release(self.api, "123")
        self.assertFalse(self.api.writes)

    def test_equivalent_and_higher_versions_are_never_renamed(self):
        for marketing_version in ("2.5", "2.5.1", "2.6.0"):
            with self.subTest(version=marketing_version):
                self.api.versions[0]["attributes"]["versionString"] = marketing_version
                plan = release.inspect_release(self.api, "123", now=NOW)
                self.assertNotEqual(plan["action"], "rename_version_and_submit")
                with self.assertRaisesRegex(release.ReleaseError, "rollback"):
                    release.submit_release(self.api, "123")
                self.assertFalse(self.api.writes)

    def test_review_rejected_approved_and_unknown_states_are_never_renamed(self):
        for current_state in (
            "WAITING_FOR_REVIEW", "IN_REVIEW", "READY_FOR_REVIEW", "REJECTED", "METADATA_REJECTED",
            "INVALID_BINARY", "PENDING_DEVELOPER_RELEASE", "PENDING_APPLE_RELEASE",
            "PROCESSING_FOR_DISTRIBUTION", "PROCESSING_FOR_APP_STORE", "UNKNOWN",
        ):
            with self.subTest(state=current_state):
                self.api.versions[0]["attributes"]["appVersionState"] = current_state
                plan = release.inspect_release(self.api, "123", now=NOW)
                self.assertNotEqual(plan["action"], "rename_version_and_submit")
                with self.assertRaisesRegex(release.ReleaseError, "Another iOS App Store version"):
                    release.submit_release(self.api, "123")
                self.assertFalse(self.api.writes)

    def test_another_version_in_review_blocks_renaming_the_editable_draft(self):
        for current_state in ("WAITING_FOR_REVIEW", "IN_REVIEW", "READY_FOR_REVIEW"):
            with self.subTest(state=current_state):
                self.api.versions.append(version_fixture("in-review", "2.4.2", current_state))
                with self.assertRaisesRegex(release.ReleaseError, "Another iOS App Store version"):
                    release.submit_release(self.api, "123")
                self.assertFalse(self.api.writes)
                self.api.versions.pop()

    def test_existing_requirements_block_before_renaming(self):
        for requirement in ("whats_new", "review", "compliance", "active_submission"):
            with self.subTest(requirement=requirement):
                api = deepcopy(self.api)
                if requirement == "whats_new":
                    api.localizations[0]["attributes"]["whatsNew"] = ""
                elif requirement == "review":
                    api.review = None
                elif requirement == "compliance":
                    api.builds[0]["attributes"]["usesNonExemptEncryption"] = None
                else:
                    api.submissions = [resource("reviewSubmissions", "active", {"state": "IN_REVIEW"})]
                    api.items["active"] = []
                with self.assertRaises(release.ReleaseError):
                    release.submit_release(api, "123")
                self.assertFalse(api.writes)

    def test_candidate_in_ready_review_submission_is_never_renamed(self):
        self.api.submissions = [resource("reviewSubmissions", "existing", {"state": "READY_FOR_REVIEW"})]
        self.api.items["existing"] = [resource("reviewSubmissionItems", "item", {"state": "READY_FOR_REVIEW"}, appStoreVersion=("appStoreVersions", "draft"))]
        plan = release.inspect_release(self.api, "123", now=NOW)
        self.assertTrue(any("active iOS review submission" in reason for reason in plan["blockers"]))
        with self.assertRaisesRegex(release.ReleaseError, "will not rename"):
            release.submit_release(self.api, "123")
        self.assertFalse(self.api.writes)

    def test_expected_build_guard_blocks_before_renaming(self):
        with self.assertRaisesRegex(release.ReleaseError, "changed since selection"):
            release.submit_release(self.api, "123", expected_build_id="old-selection")
        self.assertFalse(self.api.writes)

    def test_missing_metadata_after_rename_stops_before_binding_or_review(self):
        original_request = self.api.request
        def request(method, path, **kwargs):
            result = original_request(method, path, **kwargs)
            if method == "PATCH" and "versionString" in kwargs.get("data", {}).get("data", {}).get("attributes", {}):
                self.api.localizations[0]["attributes"]["whatsNew"] = ""
            return result
        with patch.object(self.api, "request", side_effect=request):
            with self.assertRaisesRegex(release.ReleaseError, "Renamed App Store draft draft, but did not submit"):
                release.submit_release(self.api, "123")
        self.assertEqual(len(self.api.writes), 1)
        self.assertEqual(self.api.versions[0]["attributes"]["versionString"], "2.5.0")

    def test_build_change_after_rename_stops_before_binding_or_review(self):
        original_request = self.api.request
        def request(method, path, **kwargs):
            result = original_request(method, path, **kwargs)
            if method == "PATCH" and "versionString" in kwargs.get("data", {}).get("data", {}).get("attributes", {}):
                build, included = build_fixture("new-build", "2.5.0", "2026-10-28T00:00:00Z")
                self.api.builds.append(build)
                self.api.included.extend(included)
            return result
        with patch.object(self.api, "request", side_effect=request):
            with self.assertRaisesRegex(release.ReleaseError, "changed while preparing"):
                release.submit_release(self.api, "123", expected_build_id="build-10")
        self.assertEqual(len(self.api.writes), 1)

    def test_active_review_after_rename_stops_before_binding_or_review(self):
        original_request = self.api.request
        def request(method, path, **kwargs):
            result = original_request(method, path, **kwargs)
            if method == "PATCH" and "versionString" in kwargs.get("data", {}).get("data", {}).get("attributes", {}):
                self.api.versions[0]["attributes"]["appVersionState"] = "IN_REVIEW"
            return result
        with patch.object(self.api, "request", side_effect=request):
            with self.assertRaisesRegex(release.ReleaseError, "Renamed App Store draft draft, but did not submit"):
                release.submit_release(self.api, "123")
        self.assertEqual(len(self.api.writes), 1)


class AuthTokenTests(unittest.TestCase):
    """PyJWT, the key file, and the clock are synthetic; nothing is signed for real."""

    def setUp(self):
        self.encode = Mock(side_effect=lambda claims, *args, **kwargs: f"token-{claims['iat']}")
        fake_jwt = ModuleType("jwt")
        fake_jwt.encode, fake_jwt.PyJWTError = self.encode, type("PyJWTError", (Exception,), {})
        self.clock = Mock(return_value=1_000)
        read_bytes = patch.object(Path, "read_bytes", autospec=True, return_value=b"synthetic private key")
        for active in (patch.dict(sys.modules, {"jwt": fake_jwt}), patch.object(release.time, "time", self.clock)):
            active.start()
            self.addCleanup(active.stop)
        self.read_bytes = read_bytes.start()
        self.addCleanup(read_bytes.stop)

    def token(self, environ, api=None):
        with patch.dict(os.environ, environ, clear=True):
            return (api or release.AppStoreAPI()).token()

    def assert_signed(self, claims):
        self.encode.assert_called_once_with(claims, b"synthetic private key", algorithm="ES256",
                                            headers={"kid": "SYNTHETICKID", "typ": "JWT"})
        self.read_bytes.assert_called_once_with(Path("/synthetic/AuthKey.p8"))

    def test_team_key_is_default_and_signs_issuer_claims(self):
        for key_type in (None, "", "team"):
            with self.subTest(key_type=key_type):
                self.encode.reset_mock()
                self.read_bytes.reset_mock()
                environ = TEAM_ENV if key_type is None else {**TEAM_ENV, "ASC_KEY_TYPE": key_type}
                self.assertEqual(self.token(environ), "token-1000")
                self.assert_signed({"iss": "synthetic-issuer", "iat": 1_000, "exp": 1_600, "aud": "appstoreconnect-v1"})

    def test_individual_key_signs_user_subject_and_never_issuer(self):
        # A leftover team issuer secret must not be added to an individual token.
        for environ in (INDIVIDUAL_ENV, {**INDIVIDUAL_ENV, "ASC_ISSUER_ID": "synthetic-issuer"}):
            with self.subTest(issuer_set="ASC_ISSUER_ID" in environ):
                self.encode.reset_mock()
                self.read_bytes.reset_mock()
                self.assertEqual(self.token(environ), "token-1000")
                self.assert_signed({"sub": "user", "iat": 1_000, "exp": 1_600, "aud": "appstoreconnect-v1"})

    def test_invalid_key_type_or_missing_variables_fail_before_reading_the_key(self):
        for name, environ, message in [
            ("capitalized type", {**TEAM_ENV, "ASC_KEY_TYPE": "Individual"}, "ASC_KEY_TYPE must be team or individual"),
            ("unknown type", {**TEAM_ENV, "ASC_KEY_TYPE": "enterprise"}, "ASC_KEY_TYPE must be team or individual"),
            ("team without issuer", without(TEAM_ENV, "ASC_ISSUER_ID"), "Missing environment variables: ASC_ISSUER_ID$"),
            ("individual without key ID", without(INDIVIDUAL_ENV, "ASC_KEY_ID"), "Missing environment variables: ASC_KEY_ID$"),
            ("individual without key path", without(INDIVIDUAL_ENV, "ASC_PRIVATE_KEY_PATH"), "Missing environment variables: ASC_PRIVATE_KEY_PATH$"),
        ]:
            with self.subTest(name):
                with self.assertRaisesRegex(release.ReleaseError, message):
                    self.token(environ)
        self.read_bytes.assert_not_called()
        self.encode.assert_not_called()

    def test_token_is_reused_until_one_minute_before_expiry_then_renewed(self):
        api = release.AppStoreAPI()
        self.assertEqual(self.token(INDIVIDUAL_ENV, api), "token-1000")
        self.clock.return_value = 1_539
        self.assertEqual(self.token(INDIVIDUAL_ENV, api), "token-1000")
        self.assertEqual(self.encode.call_count, 1)
        self.clock.return_value = 1_540
        self.assertEqual(self.token(INDIVIDUAL_ENV, api), "token-1540")
        self.assertEqual(self.encode.call_count, 2)
        self.assertEqual(self.encode.call_args.args[0], {"sub": "user", "iat": 1_540, "exp": 2_140, "aud": "appstoreconnect-v1"})


class APIAndCLITests(unittest.TestCase):
    def setUp(self):
        clock_patch = patch.object(release, "datetime", wraps=datetime)
        clock = clock_patch.start()
        clock.now.return_value = NOW
        self.addCleanup(clock_patch.stop)

    def test_read_only_guard_and_host_guard_do_not_even_request_a_token(self):
        api = release.AppStoreAPI()
        with patch.object(api, "token") as token:
            with self.assertRaisesRegex(release.ReleaseError, "read-only"):
                api.request("POST", "/v1/reviewSubmissions", data={})
            with self.assertRaisesRegex(release.ReleaseError, "unexpected"):
                api.request("GET", "https://example.com/v1/builds")
            token.assert_not_called()

    def test_pagination_preserves_included_prereleases_across_every_page(self):
        api = release.AppStoreAPI()
        pages = [{"data": [{"id": "a"}], "included": [{"id": "pre-a"}], "links": {"next": release.API_ROOT + "/v1/builds?cursor=next"}},
                 {"data": [{"id": "b"}], "included": [{"id": "pre-b"}]}]
        with patch.object(api, "request", side_effect=pages) as request:
            items, included = api.collection("/v1/builds", {"limit": 200})
        self.assertEqual([item["id"] for item in items], ["a", "b"])
        self.assertEqual([item["id"] for item in included], ["pre-a", "pre-b"])
        self.assertIsNone(request.call_args_list[1].kwargs["params"])

    def test_mutations_are_not_retried_and_errors_explain_missing_apple_fields(self):
        api = release.AppStoreAPI(allow_writes=True)
        body = json.dumps({"errors": [{"code": "ENTITY_ERROR", "detail": "Missing app privacy answers", "source": {"pointer": "/data/attributes/privacy"}}]}).encode()
        error = HTTPError(release.API_ROOT + "/v1/reviewSubmissions/one", 409, "Conflict", {}, BytesIO(body))
        with patch.object(api, "token", return_value="synthetic-token"), patch.object(api.opener, "open", side_effect=error) as request:
            with self.assertRaisesRegex(release.ReleaseError, "Missing app privacy answers"):
                api.request("PATCH", "/v1/reviewSubmissions/one", data={})
        request.assert_called_once()

    def test_cli_selection_is_get_only_and_missing_requirements_exit_two(self):
        api = FakeAPI()
        api.review = None
        with patch.object(release, "AppStoreAPI", return_value=api) as constructor, patch("sys.stdout", new_callable=StringIO) as output:
            status = release.main(["select", "--app-id", "123"])
        self.assertEqual(status, 2)
        self.assertTrue(json.loads(output.getvalue())["blockers"])
        constructor.assert_called_once_with(allow_writes=False)
        self.assertFalse(api.writes)

    def test_missing_review_record_404_is_reported_as_a_requirement(self):
        api = FakeAPI()
        original = api.request
        def request(method, path, **kwargs):
            if path.endswith("/appStoreReviewDetail"):
                raise release.APIError(404, "not found")
            return original(method, path, **kwargs)
        with patch.object(api, "request", side_effect=request):
            plan = release.inspect_release(api, "123", now=NOW)
        self.assertTrue(any("App Review contact" in message for message in plan["blockers"]))
        self.assertFalse(api.writes)

    def test_note_file_requires_actual_locale_text(self):
        path = Path("notes.json")
        for value in [[], {}, {"en-US": ""}, {"en-US": False}]:
            with patch.object(Path, "read_text", return_value=json.dumps(value)):
                with self.assertRaises(release.ReleaseError):
                    release.read_notes(path)
        with patch.object(Path, "read_text", return_value=json.dumps({"en-US": "Actual release changes."})):
            self.assertEqual(release.read_notes(path), {"en-US": "Actual release changes."})


if __name__ == "__main__":
    unittest.main()
