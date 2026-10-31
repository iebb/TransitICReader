"""Promote an existing iOS TestFlight build without building or uploading binaries.

``select`` performs GET requests only. ``submit`` may create an App Store version
or rename one lower editable draft, associate the selected build, set automatic
release, and submit it for review.
Apple inherits listing metadata when creating a version; this command never
invents export-compliance, review, privacy, or advertising answers. Missing
requirements must be completed in App Store Connect, or supplied as explicit
localized release notes using --release-notes-file (JSON {"en-US": "..."}).

Authentication uses a team key by default (ASC_KEY_ID, ASC_ISSUER_ID,
ASC_PRIVATE_KEY_PATH). Set ASC_KEY_TYPE=individual for an individual key, which
signs as the key's user and needs no issuer ID.

API shapes checked against Apple's App Store Connect OpenAPI specification 4.5.1:
https://developer.apple.com/sample-code/app-store-connect/app-store-connect-openapi-specification.zip
https://developer.apple.com/help/app-store-connect/update-your-app/create-a-new-version
https://developer.apple.com/documentation/appstoreconnectapi/review-submissions
https://developer.apple.com/documentation/appstoreconnectapi/generating-tokens-for-api-requests
"""

from __future__ import annotations

import argparse
from collections import Counter
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import re
import sys
import time
from urllib.error import HTTPError, URLError
from urllib.parse import quote, urlencode, urlsplit
from urllib.request import HTTPRedirectHandler, Request, build_opener


API_ROOT = "https://api.appstoreconnect.apple.com"
EDITABLE_STATES = {
    "PREPARE_FOR_SUBMISSION", "DEVELOPER_REJECTED", "REJECTED",
    "METADATA_REJECTED", "INVALID_BINARY", "READY_FOR_REVIEW",
}
RENAMABLE_STATES = {"PREPARE_FOR_SUBMISSION", "DEVELOPER_REJECTED"}
IN_REVIEW_STATES = {"WAITING_FOR_REVIEW", "IN_REVIEW"}
PUBLISHING_STATES = {"PENDING_APPLE_RELEASE", "PROCESSING_FOR_DISTRIBUTION", "PROCESSING_FOR_APP_STORE"}
DISTRIBUTED_STATES = {"READY_FOR_DISTRIBUTION", "READY_FOR_SALE", "REPLACED_WITH_NEW_VERSION"}
REVIEW_FIELDS = ("contactFirstName", "contactLastName", "contactPhone", "contactEmail")
KEY_TYPES = {"team", "individual"}
TOKEN_LIFETIME = 600
ERROR_LIMIT, ERROR_DEPTH, ERROR_TEXT_LIMIT = 20, 4, 300


class ReleaseError(RuntimeError):
    """A release cannot safely proceed without operator action."""


class APIError(ReleaseError):
    def __init__(self, status: int, message: str):
        super().__init__(message)
        self.status = status


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        # Never forward the bearer token to a redirect destination.
        return None


def safe_text(value, limit: int = ERROR_TEXT_LIMIT) -> str:
    # Apple's text is untrusted: drop control characters so it cannot forge log lines.
    text = " ".join("".join(char if char.isprintable() else " " for char in str(value)).split())
    return text if len(text) <= limit else text[:limit - 3] + "..."


def error_details(errors) -> str:
    """Render codes, details, and sources, including nested meta.associatedErrors,
    without echoing Apple's raw body, IDs, or headers."""
    rendered, total = [], 0

    def visit(items, depth: int, prefix: str) -> None:
        nonlocal total
        for item in items if isinstance(items, list) else []:
            if not isinstance(item, dict):
                continue
            total += 1
            if len(rendered) < ERROR_LIMIT:
                source = item.get("source") if isinstance(item.get("source"), dict) else {}
                location = source.get("pointer") or source.get("parameter")
                rendered.append(prefix + f"{safe_text(item.get('code', ''))}: {safe_text(item.get('detail') or item.get('title', ''))}"
                                + (f" [{safe_text(location)}]" if location else ""))
            meta = item.get("meta")
            associated = meta.get("associatedErrors") if isinstance(meta, dict) else None
            if depth >= ERROR_DEPTH:
                continue
            # Apple keys associated errors by resource path; accept a bare list too.
            if isinstance(associated, dict):
                for resource, nested in associated.items():
                    visit(nested, depth + 1, f"associated {safe_text(str(resource).removeprefix(API_ROOT), 200)}: ")
            else:
                visit(associated, depth + 1, "associated: ")

    visit(errors, 0, "")
    if total > len(rendered):
        rendered.append(f"{total - len(rendered)} more Apple errors omitted")
    return "; ".join(rendered) or "Apple returned no error details"


class AppStoreAPI:
    def __init__(self, *, allow_writes: bool = False):
        self.allow_writes = allow_writes
        self.opener = build_opener(NoRedirect())
        self._token = None
        self._token_expires = 0

    def token(self) -> str:
        if self._token and time.time() < self._token_expires - 60:
            return self._token
        key_type = os.environ.get("ASC_KEY_TYPE") or "team"
        if key_type not in KEY_TYPES:
            raise ReleaseError("ASC_KEY_TYPE must be team or individual.")
        required = ("ASC_KEY_ID", "ASC_PRIVATE_KEY_PATH") + (("ASC_ISSUER_ID",) if key_type == "team" else ())
        missing = [name for name in required if not os.environ.get(name)]
        if missing:
            raise ReleaseError("Missing environment variables: " + ", ".join(missing))
        try:
            import jwt
        except ImportError as error:
            raise ReleaseError("Install tools/release/requirements-appstore.txt before accessing Apple.") from error
        now = int(time.time())
        # Apple: team keys identify the team with iss; individual keys use
        # sub="user" and must omit iss.
        principal = {"iss": os.environ["ASC_ISSUER_ID"]} if key_type == "team" else {"sub": "user"}
        try:
            key = Path(os.environ["ASC_PRIVATE_KEY_PATH"]).read_bytes()
            self._token = jwt.encode(
                {**principal, "iat": now, "exp": now + TOKEN_LIFETIME, "aud": "appstoreconnect-v1"},
                key, algorithm="ES256", headers={"kid": os.environ["ASC_KEY_ID"], "typ": "JWT"},
            )
        except (OSError, ValueError, jwt.PyJWTError) as error:
            raise ReleaseError("Unable to read/sign the configured App Store Connect key.") from error
        self._token_expires = now + TOKEN_LIFETIME
        return self._token

    def request(self, method: str, path: str, *, params: dict | None = None, data: dict | None = None) -> dict:
        if method != "GET" and not self.allow_writes:
            raise ReleaseError("This command is read-only; only submit permits store changes.")
        url = path if path.startswith("https://") else API_ROOT + path
        parsed = urlsplit(url)
        if (parsed.scheme, parsed.netloc) != ("https", "api.appstoreconnect.apple.com") or not parsed.path.startswith("/v1/"):
            raise ReleaseError("Refusing an unexpected App Store Connect API URL.")
        if params:
            url += ("&" if parsed.query else "?") + urlencode(params)
        request = Request(url, method=method, headers={
            "Authorization": "Bearer " + self.token(), "Accept": "application/json",
            "Content-Type": "application/json", "User-Agent": "CardBal-release/1",
        }, data=json.dumps(data).encode() if data is not None else None)
        for attempt in range(3):
            try:
                with self.opener.open(request, timeout=60) as response:
                    body = response.read()
                    try:
                        return json.loads(body) if body else {}
                    except ValueError as error:
                        raise ReleaseError("Apple returned an invalid JSON response; rerun select to inspect the current state.") from error
            except HTTPError as error:
                if method == "GET" and error.code in {429, 500, 502, 503, 504} and attempt < 2:
                    delay = error.headers.get("Retry-After", "2")
                    error.close()
                    time.sleep(min(float(delay), 10) if delay.isdigit() else 2)
                    continue
                try:
                    details = error_details(json.loads(error.read()).get("errors", []))
                except (ValueError, AttributeError, TypeError, RecursionError):
                    details = "Apple did not return a JSON error."
                finally:
                    error.close()
                raise APIError(error.code,
                    f"Apple API {method} {parsed.path} failed ({error.code}): {details}. "
                    "Complete the indicated requirements in App Store Connect; rerun select before retrying."
                ) from error
            except (URLError, TimeoutError) as error:
                # Mutations are never retried: their outcome may already be committed.
                raise ReleaseError("Apple API connection failed; rerun select to inspect the current state.") from error
        raise AssertionError("unreachable")

    def collection(self, path: str, params: dict | None = None) -> tuple[list[dict], list[dict]]:
        resources, included = [], []
        seen = set()
        while path:
            if path in seen:
                raise ReleaseError("Apple returned a repeated pagination link.")
            seen.add(path)
            page = self.request("GET", path, params=params)
            resources.extend(page["data"])
            included.extend(page.get("included", []))
            path, params = page.get("links", {}).get("next"), None
        return resources, included


def identifier(value: str) -> str:
    return quote(value, safe="")


def relationship(resource: dict, name: str) -> dict | None:
    return resource.get("relationships", {}).get(name, {}).get("data")


def version_key(value: str) -> tuple[int, int, int]:
    if not re.fullmatch(r"\d+(?:\.\d+){0,2}", value):
        raise ReleaseError(f"Cannot rank nonnumeric Apple version {value!r}.")
    return tuple((list(map(int, value.split("."))) + [0, 0])[:3])


def timestamp(value: str) -> datetime:
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
        if parsed.tzinfo is None:
            raise ValueError("timezone missing")
        return parsed
    except (ValueError, AttributeError) as error:
        raise ReleaseError("Apple returned a missing/invalid build timestamp.") from error


def state(version: dict) -> str:
    attributes = version.get("attributes", {})
    return attributes.get("appVersionState") or attributes.get("appStoreState", "UNKNOWN")


def latest_build(builds: list[dict], included: list[dict], now: datetime) -> tuple[dict, Counter]:
    objects = {(item["type"], item["id"]): item for item in included}
    candidates, skipped = [], Counter()
    for build in builds:
        attributes = build["attributes"]
        link = relationship(build, "preReleaseVersion") or {}
        prerelease = objects.get((link.get("type"), link.get("id")), {}).get("attributes", {})
        detail = relationship(build, "buildBetaDetail") or {}
        beta = objects.get((detail.get("type"), detail.get("id")), {}).get("attributes", {})
        reason = None
        if prerelease.get("platform") != "IOS":
            reason = "non_iOS_or_missing_prerelease"
        elif attributes.get("processingState") != "VALID":
            reason = "not_VALID"
        elif attributes.get("buildAudienceType") != "APP_STORE_ELIGIBLE":
            reason = "not_App_Store_eligible"
        elif attributes.get("expired") is not False or not attributes.get("expirationDate") or timestamp(attributes["expirationDate"]) <= now:
            reason = "expired_or_unknown_expiration"
        elif beta.get("externalBuildState") == "BETA_REJECTED":
            reason = "TestFlight_rejected"
        if reason:
            skipped[reason] += 1
            continue
        candidates.append((version_key(prerelease["version"]), timestamp(attributes.get("uploadedDate")), build["id"], build, prerelease))
    if not candidates:
        raise ReleaseError("No processed VALID, unexpired, App Store eligible iOS TestFlight build exists.")
    _, _, _, build, prerelease = max(candidates, key=lambda item: item[:3])
    return {"id": build["id"], "version": prerelease["version"],
            "build_number": build["attributes"]["version"], "uploaded_at": build["attributes"]["uploadedDate"],
            "resource": build}, skipped


def read_notes(path: Path | None) -> dict[str, str]:
    if not path:
        return {}
    try:
        notes = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        raise ReleaseError("Release notes must be a UTF-8 JSON object mapping locale to actual release notes.") from error
    if not isinstance(notes, dict) or not notes or any(
        not isinstance(locale, str) or not locale.strip() or not isinstance(text, str) or not text.strip()
        for locale, text in notes.items()
    ):
        raise ReleaseError("Release notes must map nonempty locale strings to nonempty text.")
    return notes


def metadata_check(api, version_id: str, primary_locale: str, *, needs_whats_new: bool, notes: dict) -> tuple[list[str], list[dict]]:
    localizations, _ = api.collection(f"/v1/appStoreVersions/{identifier(version_id)}/appStoreVersionLocalizations", {"limit": 200})
    blockers = []
    by_locale = {item["attributes"]["locale"]: item for item in localizations}
    primary = by_locale.get(primary_locale, {}).get("attributes", {})
    if not primary:
        blockers.append(f"The matching version is missing its primary localization ({primary_locale}).")
    for field in ("description", "supportUrl"):
        if not primary.get(field):
            blockers.append(f"The primary localization is missing {field}.")
    for locale in notes.keys() - by_locale.keys():
        blockers.append(f"Release notes specify unknown localization {locale}; create it in App Store Connect first.")
    if needs_whats_new:
        for locale, item in by_locale.items():
            if not notes.get(locale) and not (item["attributes"].get("whatsNew") or "").strip():
                blockers.append(f"The {locale} localization needs actual What's New text (App Store Connect or --release-notes-file).")
    try:
        review = api.request("GET", f"/v1/appStoreVersions/{identifier(version_id)}/appStoreReviewDetail").get("data")
    except APIError as error:
        if error.status != 404:
            raise
        review = None
    if not review:
        blockers.append("App Review contact/sign-in information is missing; complete it in App Store Connect.")
    else:
        attributes = review.get("attributes", {})
        for field in REVIEW_FIELDS:
            if not attributes.get(field):
                blockers.append(f"App Review information is missing {field}.")
        if attributes.get("demoAccountRequired") not in {True, False}:
            blockers.append("App Review sign-in requirement has not been answered.")
        if attributes.get("demoAccountRequired") is True and any(not attributes.get(field) for field in ("demoAccountName", "demoAccountPassword")):
            blockers.append("App Review requires sign-in but the demo account is incomplete.")
    return blockers, localizations


def inspect_release(api, app_id: str, *, notes: dict | None = None, now: datetime | None = None) -> dict:
    notes = notes or {}
    app = api.request("GET", f"/v1/apps/{identifier(app_id)}")["data"]
    builds, included = api.collection("/v1/builds", {
        "filter[app]": app_id, "include": "preReleaseVersion,buildBetaDetail,appEncryptionDeclaration", "limit": 200,
        "fields[appEncryptionDeclarations]": "appEncryptionDeclarationState",
    })
    chosen, skipped = latest_build(builds, included, now or datetime.now(timezone.utc))
    versions, _ = api.collection(f"/v1/apps/{identifier(app_id)}/appStoreVersions", {
        "filter[platform]": "IOS", "include": "build", "limit": 200,
    })
    matching = [item for item in versions if item["attributes"]["versionString"] == chosen["version"]]
    if len(matching) > 1:
        raise ReleaseError("Multiple iOS App Store versions match the selected marketing version.")
    version = matching[0] if matching else None
    selected_key = version_key(chosen["version"])
    rename_candidates = [] if version else [
        item for item in versions if state(item) in RENAMABLE_STATES
        and version_key(item["attributes"]["versionString"]) < selected_key
    ]
    if len(rename_candidates) == 1:
        version = rename_candidates[0]
    plan = {"app_id": app_id, "build": {k: v for k, v in chosen.items() if k != "resource"},
            "app_store_version_id": version["id"] if version else None,
            "app_store_state": state(version) if version else None,
            "action": "submit_for_review" if version else "create_version_and_submit",
            "release_type": "AFTER_APPROVAL", "blockers": [], "skipped_builds": dict(skipped),
            "metadata": "Preserve the matching version's metadata" if version else "Apple transfers current listing metadata when creating the version; validate before submitting",
            "review_submission_id": None}
    blockers = plan["blockers"]
    if len(rename_candidates) == 1:
        plan["action"] = "rename_version_and_submit"
        plan["rename_from_version"] = version["attributes"]["versionString"]
    elif rename_candidates:
        blockers.append("Multiple lower editable iOS App Store drafts exist; resolve them in App Store Connect first.")
    for other in versions:
        if other is version:
            continue
        other_state = state(other)
        if version_key(other["attributes"]["versionString"]) >= selected_key:
            blockers.append("A newer or equivalent App Store version already exists; refusing a version rollback.")
        if other_state not in DISTRIBUTED_STATES | {"DEVELOPER_REMOVED_FROM_SALE", "REMOVED_FROM_SALE"}:
            blockers.append(f"Another iOS App Store version is {other_state}; resolve it before promoting this build.")
    if version:
        current_state = state(version)
        attached = relationship(version, "build") or {}
        same_build = attached.get("id") == chosen["id"]
        if current_state in DISTRIBUTED_STATES:
            plan["action"] = "already_released"
            if not same_build:
                blockers.append("The selected marketing version was released with a different build. Upload a higher marketing version.")
        elif current_state in IN_REVIEW_STATES:
            plan["action"] = "already_submitted"
            if not same_build:
                blockers.append("This version is already in App Review with a different build; the helper will not replace it.")
            elif version["attributes"].get("releaseType") != "AFTER_APPROVAL":
                plan["action"] = "set_automatic_release"
        elif current_state == "PENDING_DEVELOPER_RELEASE":
            plan["action"] = "release_approved_version"
            if not same_build:
                blockers.append("The approved version contains a different build; it will not be released.")
        elif current_state in PUBLISHING_STATES:
            plan["action"] = "release_in_progress"
            if not same_build:
                blockers.append("The version is already being published with a different build; the helper will not replace it.")
        elif current_state not in EDITABLE_STATES:
            blockers.append(f"The matching App Store version is {current_state}; no automatic state transition is safe.")
        elif current_state == "READY_FOR_REVIEW" and not same_build:
            blockers.append("The draft is already added for review with a different build; remove it from the draft review submission in App Store Connect first.")
    if plan["action"] in {"submit_for_review", "create_version_and_submit", "rename_version_and_submit"}:
        build_attributes = chosen["resource"]["attributes"]
        if build_attributes.get("usesNonExemptEncryption") is None:
            blockers.append("The selected build has unanswered export-compliance questions; complete them in App Store Connect.")
        beta_link = relationship(chosen["resource"], "buildBetaDetail") or {}
        objects = {(item["type"], item["id"]): item for item in included}
        if build_attributes.get("usesNonExemptEncryption") is True:
            declaration_link = relationship(chosen["resource"], "appEncryptionDeclaration") or {}
            declaration = objects.get((declaration_link.get("type"), declaration_link.get("id")), {}).get("attributes", {})
            if declaration.get("appEncryptionDeclarationState") != "APPROVED":
                blockers.append("The selected build uses non-exempt encryption but has no linked APPROVED encryption declaration; complete export compliance in App Store Connect.")
        beta = objects.get((beta_link.get("type"), beta_link.get("id")), {}).get("attributes", {})
        if beta.get("internalBuildState") in {"MISSING_EXPORT_COMPLIANCE", "IN_EXPORT_COMPLIANCE_REVIEW", "PROCESSING", "PROCESSING_EXCEPTION", "EXPIRED"}:
            blockers.append(f"The selected build is {beta['internalBuildState']}; complete processing/export compliance first.")
        if version:
            metadata_blockers, _ = metadata_check(api, version["id"], app["attributes"]["primaryLocale"], needs_whats_new=len(versions) > 1, notes=notes)
            blockers.extend(metadata_blockers)
        else:
            plan["checks_after_create"] = ["Inherited localizations/What's New", "App Review contact and sign-in information", "Apple's complete submission validation"]
        submissions, _ = api.collection("/v1/reviewSubmissions", {"filter[app]": app_id, "filter[platform]": "IOS", "limit": 200})
        active = [item for item in submissions if item["attributes"]["state"] != "COMPLETE"]
        if len(active) > 1:
            blockers.append("Multiple active iOS review submissions exist; resolve them in App Store Connect first.")
        elif active:
            submission = active[0]
            items, _ = api.collection(f"/v1/reviewSubmissions/{identifier(submission['id'])}/items", {"include": "appStoreVersion", "limit": 200})
            live_items = [item for item in items if item["attributes"].get("state") != "REMOVED"]
            only_target = bool(version) and len(live_items) == 1 and (relationship(live_items[0], "appStoreVersion") or {}).get("id") == version["id"]
            if submission["attributes"]["state"] != "READY_FOR_REVIEW":
                blockers.append(f"An iOS review submission is {submission['attributes']['state']}; resolve its review issues first.")
            elif plan["action"] == "rename_version_and_submit" and any(
                (relationship(item, "appStoreVersion") or {}).get("id") == version["id"] for item in live_items
            ):
                blockers.append("The lower draft is already in an active iOS review submission; the helper will not rename it.")
            elif live_items and not only_target:
                blockers.append("The existing draft review submission contains other items; the helper will not submit unrelated content.")
            elif only_target and live_items[0]["attributes"].get("state") != "READY_FOR_REVIEW":
                blockers.append("The existing review item is not ready for review; resolve its rejection in App Store Connect first.")
            else:
                plan["review_submission_id"] = submission["id"]
                plan["review_item_exists"] = only_target
    return plan


def resource_payload(kind: str, *, resource_id: str | None = None, attributes: dict | None = None, relationships: dict | None = None) -> dict:
    data = {"type": kind}
    if resource_id:
        data["id"] = resource_id
    if attributes:
        data["attributes"] = attributes
    if relationships:
        data["relationships"] = {name: {"data": {"type": target[0], "id": target[1]}} for name, target in relationships.items()}
    return {"data": data}


def submit_release(api, app_id: str, *, notes: dict | None = None, expected_build_id: str | None = None) -> dict:
    notes = notes or {}
    plan = inspect_release(api, app_id, notes=notes)
    if expected_build_id and plan["build"]["id"] != expected_build_id:
        raise ReleaseError("The latest eligible build changed since selection; rerun select and review it.")
    if plan["blockers"]:
        raise ReleaseError("Cannot release: " + " ".join(plan["blockers"]))
    action, version_id = plan["action"], plan["app_store_version_id"]
    if action in {"already_released", "already_submitted", "release_in_progress"}:
        return plan
    if action == "release_approved_version":
        api.request("POST", "/v1/appStoreVersionReleaseRequests", data=resource_payload(
            "appStoreVersionReleaseRequests", relationships={"appStoreVersion": ("appStoreVersions", version_id)},
        ))
        return {**plan, "result": "approved_version_release_requested"}
    if action == "set_automatic_release":
        api.request("PATCH", f"/v1/appStoreVersions/{identifier(version_id)}", data=resource_payload(
            "appStoreVersions", resource_id=version_id, attributes={"releaseType": "AFTER_APPROVAL"},
        ))
        return {**plan, "result": "automatic_release_configured"}
    if action == "rename_version_and_submit" or not version_id:
        selected_build_id = plan["build"]["id"]
        if action == "rename_version_and_submit":
            api.request("PATCH", f"/v1/appStoreVersions/{identifier(version_id)}", data=resource_payload(
                "appStoreVersions", resource_id=version_id, attributes={"versionString": plan["build"]["version"]},
            ))
            prepared = "Renamed"
        else:
            response = api.request("POST", "/v1/appStoreVersions", data=resource_payload(
                "appStoreVersions", attributes={"platform": "IOS", "versionString": plan["build"]["version"], "releaseType": "AFTER_APPROVAL"},
                relationships={"app": ("apps", app_id)},
            ))
            version_id = response["data"]["id"]
            prepared = "Created"
        # Re-read metadata, state, and the selected build before binding or
        # creating a review submission. Reruns reuse this draft.
        plan = inspect_release(api, app_id, notes=notes)
        if plan["blockers"]:
            raise ReleaseError(f"{prepared} App Store draft {version_id}, but did not submit: " + " ".join(plan["blockers"]))
        if plan["app_store_version_id"] != version_id or plan["action"] != "submit_for_review":
            raise ReleaseError("The App Store version changed while preparing the draft; rerun select.")
        if plan["build"]["id"] != selected_build_id:
            raise ReleaseError("The latest eligible build changed while preparing the draft; rerun select.")
    if notes:
        localizations, _ = api.collection(f"/v1/appStoreVersions/{identifier(version_id)}/appStoreVersionLocalizations", {"limit": 200})
        for localization in localizations:
            locale = localization["attributes"]["locale"]
            if locale in notes:
                api.request("PATCH", f"/v1/appStoreVersionLocalizations/{identifier(localization['id'])}", data=resource_payload(
                    "appStoreVersionLocalizations", resource_id=localization["id"], attributes={"whatsNew": notes[locale]},
                ))
    api.request("PATCH", f"/v1/appStoreVersions/{identifier(version_id)}", data=resource_payload(
        "appStoreVersions", resource_id=version_id, attributes={"releaseType": "AFTER_APPROVAL"},
        relationships={"build": ("builds", plan["build"]["id"])},
    ))
    submission_id = plan.get("review_submission_id")
    if not submission_id:
        response = api.request("POST", "/v1/reviewSubmissions", data=resource_payload(
            "reviewSubmissions", attributes={"platform": "IOS"}, relationships={"app": ("apps", app_id)},
        ))
        submission_id = response["data"]["id"]
    if not plan.get("review_item_exists"):
        api.request("POST", "/v1/reviewSubmissionItems", data=resource_payload(
            "reviewSubmissionItems", relationships={"reviewSubmission": ("reviewSubmissions", submission_id), "appStoreVersion": ("appStoreVersions", version_id)},
        ))
    api.request("PATCH", f"/v1/reviewSubmissions/{identifier(submission_id)}", data=resource_payload(
        "reviewSubmissions", resource_id=submission_id, attributes={"submitted": True},
    ))
    return {**plan, "app_store_version_id": version_id, "review_submission_id": submission_id, "result": "submitted_for_review"}


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("command", choices=("select", "submit"), help="select is GET-only; submit changes App Store Connect.")
    parser.add_argument("--app-id", required=True, help="Numeric App Store Connect app ID (not the bundle identifier).")
    parser.add_argument("--release-notes-file", type=Path, help="Explicit UTF-8 JSON mapping existing locale names to actual What's New text.")
    parser.add_argument("--expected-build-id", help="For submit, refuse if the latest eligible build differs from this previously selected ID.")
    args = parser.parse_args(argv)
    if not args.app_id.isdecimal():
        parser.error("--app-id must be numeric")
    if args.expected_build_id and args.command != "submit":
        parser.error("--expected-build-id is valid only with submit")
    try:
        notes = read_notes(args.release_notes_file)
        api = AppStoreAPI(allow_writes=args.command == "submit")
        result = (inspect_release(api, args.app_id, notes=notes) if args.command == "select"
                  else submit_release(api, args.app_id, notes=notes, expected_build_id=args.expected_build_id))
        print(json.dumps(result, ensure_ascii=False, indent=2))
        return 2 if result.get("blockers") else 0
    except ReleaseError as error:
        print(f"App Store release failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
