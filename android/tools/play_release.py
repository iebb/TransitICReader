#!/usr/bin/env python3
"""Upload to Play internal or promote its existing latest AAB, without rebuilding,
and download Play's own signed universal APK of an internal build.

Uses the official Android Publisher v3 edits API. Credentials and response bodies
are never logged. Tests inject a session and do not load credentials or use NFC.
"""

from __future__ import annotations

import argparse
import base64
import binascii
import hashlib
import json
import os
from pathlib import Path
import re
import sys
from typing import Any
import unicodedata
from urllib.parse import quote

PACKAGE = "ad.neko.cardbal.android"
API = "https://androidpublisher.googleapis.com/androidpublisher/v3/applications"
UPLOAD_API = "https://androidpublisher.googleapis.com/upload/androidpublisher/v3/applications"
SCOPE = "https://www.googleapis.com/auth/androidpublisher"
MAX_VERSION_CODE = 2_100_000_000
MAX_APK_BYTES = 512 * 1024 * 1024
# Play allows up to 500 Unicode characters of release notes per language.
MAX_RELEASE_NOTES = 500
# Canonical BCP 47 language[-Script][-REGION] tags, as Play uses (en-US, es-419).
LANGUAGE_TAG = re.compile(r"[a-z]{2,3}(?:-[A-Z][a-z]{3})?(?:-(?:[A-Z]{2}|[0-9]{3}))?")


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


def release_notes_payload(value: Any) -> list[dict[str, str]]:
    """Convert a validated language -> text mapping to Play's releaseNotes list."""
    if not isinstance(value, dict) or not value:
        raise ReleaseError("release notes must be a nonempty JSON object mapping language tags to text")
    notes = []
    for language, text in value.items():
        if not isinstance(language, str) or not LANGUAGE_TAG.fullmatch(language):
            raise ReleaseError("release notes contain an invalid language tag; use canonical tags such as en-US")
        # Errors name only the validated tag, never the caller's text.
        if not isinstance(text, str) or not text.strip():
            raise ReleaseError(f"release notes for {language} must be nonempty plain text")
        if any(char != "\n" and unicodedata.category(char) in {"Cc", "Cs"} for char in text):
            raise ReleaseError(f"release notes for {language} contain control characters")
        if len(text) > MAX_RELEASE_NOTES:
            raise ReleaseError(f"release notes for {language} exceed {MAX_RELEASE_NOTES} characters")
        notes.append({"language": language, "text": text})
    return notes


def read_release_notes(path: Path) -> dict[str, str]:
    def unique(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
        result = dict(pairs)
        if len(result) != len(pairs):
            raise ReleaseError("release notes repeat a language tag")
        return result

    try:
        value = json.loads(path.read_text(encoding="utf-8"), object_pairs_hook=unique)
    except OSError:
        raise ReleaseError("could not read the release notes file") from None
    except ValueError:
        raise ReleaseError("release notes file must be UTF-8 JSON mapping language tags to text") from None
    release_notes_payload(value)
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


def certificate_sha256(value: Any) -> str:
    """Play's signing-certificate hash as lowercase hex, whether sent as hex or base64."""
    if isinstance(value, str):
        compact = value.replace(":", "").strip()
        if re.fullmatch(r"[0-9A-Fa-f]{64}", compact):
            return compact.lower()
        try:
            padded = value.strip().replace("-", "+").replace("_", "/")
            raw = base64.b64decode(padded + "=" * (-len(padded) % 4), validate=True)
        except (binascii.Error, ValueError):
            raw = b""
        if len(raw) == 32:
            return raw.hex()
    raise ReleaseError("Play returned an invalid signing certificate hash")


def universal_apk(listing: dict[str, Any]) -> tuple[str, str]:
    """The download ID and certificate hash of the one Play-signed universal APK."""
    groups = listing.get("generatedApks", [])
    if not isinstance(groups, list):
        raise ReleaseError("Play returned malformed generated APK metadata")
    universal = [group for group in groups if isinstance(group, dict) and isinstance(group.get("generatedUniversalApk"), dict)]
    if not universal:
        raise ReleaseError("Play has not generated a universal APK for this build yet")
    if len(universal) != 1:
        raise ReleaseError("this build has universal APKs for several signing keys; choose one in Play Console")
    download = universal[0]["generatedUniversalApk"].get("downloadId")
    if not isinstance(download, str) or not re.fullmatch(r"[A-Za-z0-9_.=-]+", download):
        raise ReleaseError("Play returned an invalid universal APK download ID")
    return download, certificate_sha256(universal[0].get("certificateSha256Hash"))


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

    def promote(self, expected_version: str | None = None, expected_code: int | None = None, *,
                release_notes: dict[str, str] | None = None) -> dict[str, Any]:
        if expected_version is not None:
            expected_version = version_name(expected_version)
        if expected_code is not None:
            expected_code = version_code(expected_code)
        # Without supplied notes, the reviewed internal release notes are kept.
        notes = None if release_notes is None else release_notes_payload(release_notes)
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
            if notes is not None:
                release["releaseNotes"] = notes
            self.update_track(edit, "production", release)
            self.commit(edit)
            committed = True
            return {**self.metadata("promote-latest-to-production", release, "production", True),
                    "source_track": "internal",
                    "release_notes_source": "internal" if notes is None else "supplied"}
        finally:
            if not committed:
                self.discard(edit)

    def download_universal(self, version: str, output: Path, expected_code: int | None = None) -> dict[str, Any]:
        """Download the universal APK Play generated and signed with the app-signing key, as Play installs are."""
        name = version_name(version)
        edit = self.create_edit()
        try:
            release = self.get_internal(edit)
        finally:
            self.discard(edit)
        code = int(release["versionCodes"][0])
        if release["name"] != name:
            raise ReleaseError(f"the latest Play internal build is not version {name}; run the Google Play internal workflow first")
        if expected_code is not None and code != version_code(expected_code):
            raise ReleaseError("the latest Play internal version code differs from the requested one")
        generated = f"{API}/{PACKAGE}/generatedApks/{code}"
        download, certificate = universal_apk(self.request("GET", generated, operation="list generated APKs"))
        try:
            response = self.session.request("GET", f"{generated}/downloads/{quote(download, safe='')}:download",
                                            params={"alt": "media"}, stream=True, timeout=(15, 600))
        except Exception:
            raise ReleaseError("Play API transport or authentication failed during download universal APK") from None
        digest = hashlib.sha256()
        size = 0
        pending = output.with_name(output.name + ".part")
        try:
            if not 200 <= response.status_code < 300:
                raise ReleaseError(f"Play API download universal APK failed: HTTP {response.status_code}; check Play Console/API permissions")
            output.parent.mkdir(parents=True, exist_ok=True)
            with pending.open("wb") as stream:
                for chunk in response.iter_content(1024 * 1024):
                    size += len(chunk)
                    if size > MAX_APK_BYTES:
                        raise ReleaseError("the universal APK is unexpectedly large")
                    digest.update(chunk)
                    stream.write(chunk)
            if size == 0:
                raise ReleaseError("Play returned an empty universal APK")
            pending.replace(output)
        except ReleaseError:
            raise
        except Exception:
            raise ReleaseError("could not download or save the universal APK") from None
        finally:
            response.close()
            pending.unlink(missing_ok=True)
        return {**self.metadata("download-universal", release, "internal", False),
                "certificate_sha256": certificate, "apk_sha256": digest.hexdigest(), "apk_bytes": size}


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
    promote.add_argument("--release-notes-file", type=Path,
                         help="UTF-8 JSON mapping language tags to text; replaces the internal release notes")
    universal = sub.add_parser("download-universal", help="download Play's signed universal APK of the latest internal build; no commit")
    universal.add_argument("--version", required=True)
    universal.add_argument("--expected-version-code")
    universal.add_argument("--out", required=True, type=Path)
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
            args.release_notes = None if args.release_notes_file is None else read_release_notes(args.release_notes_file)
        elif args.command == "download-universal":
            args.version = version_name(args.version)
            if args.expected_version_code is not None:
                args.expected_version_code = version_code(args.expected_version_code)
        session = authorized_session(args.service_account_file)
        try:
            client = PlayRelease(session)
            if args.command == "upload-internal":
                result = client.upload(args.bundle, args.version, args.version_code)
            elif args.command == "inspect-latest-internal":
                result = client.inspect()
            elif args.command == "download-universal":
                result = client.download_universal(args.version, args.out, args.expected_version_code)
            else:
                result = client.promote(args.expected_version, args.expected_version_code,
                                        release_notes=args.release_notes)
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
