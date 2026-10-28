#!/usr/bin/env python3
"""Upload to Play internal or promote its existing latest AAB, without rebuilding.

Uses the official Android Publisher v3 edits API. Credentials and response bodies
are never logged. Tests inject a session and do not load credentials or use NFC.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import sys
from typing import Any
from urllib.parse import quote

PACKAGE = "ad.neko.cardbal.android"
API = "https://androidpublisher.googleapis.com/androidpublisher/v3/applications"
UPLOAD_API = "https://androidpublisher.googleapis.com/upload/androidpublisher/v3/applications"
SCOPE = "https://www.googleapis.com/auth/androidpublisher"
MAX_VERSION_CODE = 2_100_000_000


class ReleaseError(Exception):
    """An actionable error whose message is safe for CI logs."""


def version_code(value: Any) -> int:
    if isinstance(value, bool) or not re.fullmatch(r"[0-9]+", str(value)):
        raise ReleaseError("version code must be an integer between 1 and 2100000000")
    code = int(value)
    if not 1 <= code <= MAX_VERSION_CODE:
        raise ReleaseError("version code must be an integer between 1 and 2100000000")
    return code


def version_name(value: Any) -> str:
    # Numeric marketing versions are shared with the iOS workflow. They also
    # prevent arbitrary server-provided track names being copied into CI output.
    if not isinstance(value, str) or not re.fullmatch(r"[0-9]+(?:\.[0-9]+){1,2}", value):
        raise ReleaseError("release name must be the numeric marketing version (for example 1.2.3)")
    if len(value) > 64:
        raise ReleaseError("marketing version is too long")
    return value


def latest_internal(track: dict[str, Any]) -> dict[str, Any]:
    """Choose by version code, never by the API's unspecified release order."""
    if not isinstance(track, dict) or track.get("track") != "internal":
        raise ReleaseError("the internal track is missing or has an unexpected identity")
    releases = track.get("releases")
    if not isinstance(releases, list) or not releases:
        raise ReleaseError("the internal track has no release")
    candidates = []
    for release in releases:
        if not isinstance(release, dict):
            raise ReleaseError("the internal track contains malformed release metadata")
        codes = release.get("versionCodes")
        if not isinstance(codes, list) or not codes:
            raise ReleaseError("an internal release has no version code")
        candidates.append((max(version_code(code) for code in codes), release))
    highest = max(code for code, _ in candidates)
    matches = [release for code, release in candidates if code == highest]
    if len(matches) != 1:
        raise ReleaseError("the latest internal version code belongs to multiple releases")
    selected = matches[0]
    if len(selected["versionCodes"]) != 1:
        raise ReleaseError("the latest internal release contains multiple version codes; select it manually in Play Console")
    if selected.get("status") != "completed":
        raise ReleaseError("the latest internal release is not completed; resolve it in Play Console first")
    name = version_name(selected.get("name"))
    result = {"name": name, "versionCodes": [str(highest)], "status": "completed"}
    # Preserve reviewed release notes and immutable update priority, not testing
    # country targeting, rollout fractions or experimental track-only settings.
    if "releaseNotes" in selected:
        notes = selected["releaseNotes"]
        if not isinstance(notes, list) or any(
            not isinstance(note, dict) or not isinstance(note.get("language"), str)
            or not isinstance(note.get("text"), str) for note in notes
        ):
            raise ReleaseError("the internal release has malformed release notes")
        result["releaseNotes"] = [{"language": note["language"], "text": note["text"]} for note in notes]
    if "inAppUpdatePriority" in selected:
        priority = selected["inAppUpdatePriority"]
        if isinstance(priority, bool) or not isinstance(priority, int) or not 0 <= priority <= 5:
            raise ReleaseError("the internal release has an invalid in-app update priority")
        result["inAppUpdatePriority"] = priority
    return result


class PlayRelease:
    def __init__(self, session: Any):
        self.session = session

    def request(self, method: str, url: str, *, operation: str, **kwargs: Any) -> dict[str, Any]:
        try:
            response = self.session.request(method, url, timeout=(15, 180), allow_redirects=False, **kwargs)
        except Exception:
            # Transport/authorization exceptions may include credential paths,
            # tokens or URLs; do not expose their string representation.
            raise ReleaseError(f"Play API transport or authentication failed during {operation}") from None
        if not 200 <= response.status_code < 300:
            status = ""
            try:
                label = response.json().get("error", {}).get("status", "")
                if isinstance(label, str) and re.fullmatch(r"[A-Z_]+", label):
                    status = f" ({label})"
            except (ValueError, AttributeError, TypeError):
                pass
            raise ReleaseError(f"Play API {operation} failed: HTTP {response.status_code}{status}; check Play Console/API permissions and review state")
        if method == "DELETE":
            return {}
        try:
            data = response.json()
        except ValueError:
            raise ReleaseError(f"Play API {operation} returned invalid JSON") from None
        if not isinstance(data, dict):
            raise ReleaseError(f"Play API {operation} returned malformed metadata")
        return data

    def create_edit(self) -> str:
        result = self.request("POST", f"{API}/{PACKAGE}/edits", operation="create edit", json={})
        edit = result.get("id")
        if not isinstance(edit, str) or not re.fullmatch(r"[A-Za-z0-9_-]+", edit):
            raise ReleaseError("Play API returned an invalid edit ID")
        return edit

    @staticmethod
    def edit_url(edit: str) -> str:
        return f"{API}/{PACKAGE}/edits/{quote(edit, safe='')}"

    def discard(self, edit: str) -> None:
        try:
            self.request("DELETE", self.edit_url(edit), operation="discard temporary edit")
        except ReleaseError:
            # Preserve the primary result/error. Edits expire server-side.
            print("Warning: the temporary Play edit could not be discarded; it will expire automatically.", file=sys.stderr)

    def get_internal(self, edit: str) -> dict[str, Any]:
        return latest_internal(self.request("GET", self.edit_url(edit) + "/tracks/internal", operation="inspect internal track"))

    def update_track(self, edit: str, track: str, release: dict[str, Any]) -> None:
        self.request("PUT", self.edit_url(edit) + f"/tracks/{track}", operation=f"update {track} track",
                     json={"track": track, "releases": [release]})

    def commit(self, edit: str) -> None:
        # The API's default can cancel another active review. Never retry with
        # that default or silently switch to changesNotSentForReview.
        self.request("POST", self.edit_url(edit) + ":commit", operation="commit edit",
                     params={"changesInReviewBehavior": "ERROR_IF_IN_REVIEW"})

    @staticmethod
    def metadata(action: str, release: dict[str, Any], track: str, committed: bool) -> dict[str, Any]:
        return {"action": action, "package": PACKAGE, "track": track,
                "version": release["name"], "version_code": int(release["versionCodes"][0]),
                "committed": committed}

    def inspect(self) -> dict[str, Any]:
        edit = self.create_edit()
        try:
            return self.metadata("inspect-latest-internal", self.get_internal(edit), "internal", False)
        finally:
            self.discard(edit)

    def upload(self, bundle: Path, version: str, code: int) -> dict[str, Any]:
        name, code = version_name(version), version_code(code)
        if not bundle.is_file() or bundle.stat().st_size == 0:
            raise ReleaseError("the Android App Bundle is missing or empty")
        digest = hashlib.sha256()
        with bundle.open("rb") as stream:
            for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                digest.update(chunk)
        edit = self.create_edit()
        committed = False
        try:
            with bundle.open("rb") as stream:
                result = self.request("POST", f"{UPLOAD_API}/{PACKAGE}/edits/{edit}/bundles",
                                      operation="upload bundle", params={"uploadType": "media"},
                                      headers={"Content-Type": "application/octet-stream"}, data=stream)
            if version_code(result.get("versionCode")) != code:
                raise ReleaseError("uploaded bundle version code does not match the requested build number")
            release = {"name": name, "versionCodes": [str(code)], "status": "completed"}
            self.update_track(edit, "internal", release)
            self.commit(edit)
            committed = True
            return {**self.metadata("upload-internal", release, "internal", True),
                    "bundle_sha256": digest.hexdigest()}
        finally:
            if not committed:
                self.discard(edit)

    def promote(self, expected_version: str | None = None, expected_code: int | None = None) -> dict[str, Any]:
        if expected_version is not None:
            expected_version = version_name(expected_version)
        if expected_code is not None:
            expected_code = version_code(expected_code)
        edit = self.create_edit()
        committed = False
        try:
            release = self.get_internal(edit)
            code = int(release["versionCodes"][0])
            if expected_version is not None and release["name"] != expected_version:
                raise ReleaseError("latest Play internal marketing version changed or differs from the selected iOS build")
            if expected_code is not None and code != expected_code:
                raise ReleaseError("latest Play internal version code changed after selection")
            production = self.request("GET", self.edit_url(edit) + "/tracks/production", operation="inspect production track")
            if production.get("track") != "production":
                raise ReleaseError("the production track has an unexpected identity")
            releases = production.get("releases", [])
            if not isinstance(releases, list):
                raise ReleaseError("the production track has malformed release metadata")
            for existing in releases:
                if not isinstance(existing, dict) or not isinstance(existing.get("versionCodes"), list):
                    raise ReleaseError("the production track has malformed version codes")
                existing_codes = [version_code(item) for item in existing["versionCodes"]]
                if existing_codes and max(existing_codes) >= code:
                    raise ReleaseError("production already contains this or a newer build; resolve it in Play Console before promotion")
                if existing.get("status") != "completed":
                    raise ReleaseError("production has an unfinished release; resolve it in Play Console before promotion")
            self.update_track(edit, "production", release)
            self.commit(edit)
            committed = True
            return {**self.metadata("promote-latest-to-production", release, "production", True),
                    "source_track": "internal"}
        finally:
            if not committed:
                self.discard(edit)


def authorized_session(credentials_file: str | None) -> Any:
    try:
        from google.auth.transport.requests import AuthorizedSession
        from google.oauth2 import service_account
    except ImportError:
        raise ReleaseError("install Android Play dependencies from android/tools/requirements-play.txt") from None
    try:
        if credentials_file:
            info = json.loads(Path(credentials_file).read_text(encoding="utf-8"))
        else:
            raw = os.environ.get("GOOGLE_PLAY_SERVICE_ACCOUNT_JSON")
            if not raw:
                raise ReleaseError("provide GOOGLE_PLAY_SERVICE_ACCOUNT_JSON or --service-account-file")
            info = json.loads(raw)
        if not isinstance(info, dict) or info.get("type") != "service_account":
            raise ReleaseError("Google Play credentials must be a service-account JSON document")
        credentials = service_account.Credentials.from_service_account_info(info, scopes=[SCOPE])
        return AuthorizedSession(credentials)
    except ReleaseError:
        raise
    except Exception:
        raise ReleaseError("could not load Google Play service-account credentials") from None


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    upload = sub.add_parser("upload-internal", help="upload a signed AAB to internal testing only")
    upload.add_argument("--bundle", required=True, type=Path)
    upload.add_argument("--version", required=True)
    upload.add_argument("--version-code", required=True)
    sub.add_parser("inspect-latest-internal", help="inspect the highest completed internal version; no commit")
    promote = sub.add_parser("promote-latest-to-production", help="promote the existing latest internal AAB without rebuilding")
    promote.add_argument("--expected-version")
    promote.add_argument("--expected-version-code")
    for command in sub.choices.values():
        command.add_argument("--service-account-file", help="private JSON file; otherwise use GOOGLE_PLAY_SERVICE_ACCOUNT_JSON")
        command.add_argument("--metadata-out", type=Path, help="write sanitized release metadata as JSON")
    args = parser.parse_args(argv)
    try:
        # Validate caller inputs before creating an authenticated session.
        if args.command == "upload-internal":
            args.version = version_name(args.version)
            args.version_code = version_code(args.version_code)
        elif args.command == "promote-latest-to-production":
            if args.expected_version is not None:
                args.expected_version = version_name(args.expected_version)
            if args.expected_version_code is not None:
                args.expected_version_code = version_code(args.expected_version_code)
        session = authorized_session(args.service_account_file)
        try:
            client = PlayRelease(session)
            if args.command == "upload-internal":
                result = client.upload(args.bundle, args.version, args.version_code)
            elif args.command == "inspect-latest-internal":
                result = client.inspect()
            else:
                result = client.promote(args.expected_version, args.expected_version_code)
        finally:
            session.close()
        encoded = json.dumps(result, indent=2, sort_keys=True) + "\n"
        if args.metadata_out:
            args.metadata_out.parent.mkdir(parents=True, exist_ok=True)
            args.metadata_out.write_text(encoded, encoding="utf-8")
        print(encoded, end="")
        return 0
    except ReleaseError as error:
        print(f"Error: {error}", file=sys.stderr)
        return 1
    except OSError:
        print("Error: could not read the bundle or write release metadata", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
