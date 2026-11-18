"""Pick the next iOS build number: one above the highest plain-number build in App Store Connect.

iOS build numbers are simple counters (52, 53, 54, ...). Earlier dotted numbers
(timestamp builds such as 2495.3.4 and old run-number builds such as 1001.2)
are ignored, so counting continues from the last plain number. App Store
Connect only requires a higher build number within one marketing version, so a
new version may start below an older version's dotted build.

Reads builds with GET requests only. Authentication uses the same App Store
Connect key as the TestFlight upload: ASC_KEY_ID, ASC_ISSUER_ID (team keys),
ASC_PRIVATE_KEY (the .p8 text, written to a private temporary file for this
command only) or ASC_PRIVATE_KEY_PATH, and the numeric ASC_APP_ID.

A build appears in App Store Connect shortly after its upload finishes. Store
workflows share one concurrency group, so a later run sees earlier uploads.
"""

from __future__ import annotations

import argparse
from collections.abc import Iterable
import os
from pathlib import Path
import re
import tempfile

from tools.release.app_store import AppStoreAPI, ReleaseError

PLAIN_BUILD = re.compile(r"[1-9][0-9]{0,8}")
VERSION_RE = re.compile(r"(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)")
CLOSED_STATES = {
    "ACCEPTED", "PENDING_APPLE_RELEASE", "PENDING_DEVELOPER_RELEASE", "PENDING_CONTRACT",
    "PROCESSING_FOR_DISTRIBUTION", "PROCESSING_FOR_APP_STORE", "READY_FOR_DISTRIBUTION",
    "READY_FOR_SALE", "PREORDER_READY_FOR_SALE", "REPLACED_WITH_NEW_VERSION",
    "DEVELOPER_REMOVED_FROM_SALE", "REMOVED_FROM_SALE",
}


def next_ios_build(existing: Iterable[str]) -> str:
    plain = [int(value) for value in existing if isinstance(value, str) and PLAIN_BUILD.fullmatch(value)]
    return str(max(plain, default=0) + 1)


def _version_tuple(value: str) -> tuple[int, int, int] | None:
    parts = value.strip().split(".")
    if len(parts) not in (2, 3) or not all(p.isdecimal() for p in parts):
        return None
    nums = [int(p) for p in parts]
    if len(nums) == 2:
        nums.append(0)
    return (nums[0], nums[1], nums[2])


def open_ios_version(requested: str, store_versions: Iterable[dict]) -> str:
    if not VERSION_RE.fullmatch(requested):
        raise ReleaseError(f"Marketing version {requested!r} must have three numeric components.")
    candidates = [_version_tuple(requested)]
    for item in store_versions:
        attrs = item.get("attributes") if isinstance(item, dict) and "attributes" in item else item
        if not isinstance(attrs, dict):
            continue
        if attrs.get("platform") not in (None, "IOS"):
            continue
        ver = _version_tuple(str(attrs.get("versionString", "")))
        if ver is None:
            continue
        state = attrs.get("appVersionState") or attrs.get("appStoreState")
        if state in CLOSED_STATES:
            ver = (ver[0], ver[1], ver[2] + 1)
        candidates.append(ver)
    chosen = max(c for c in candidates if c is not None)
    return f"{chosen[0]}.{chosen[1]}.{chosen[2]}"


def uploaded_build_numbers(api, app_id: str) -> list[str]:
    builds, _ = api.collection("/v1/builds", {"filter[app]": app_id, "fields[builds]": "version", "limit": 200})
    return [build.get("attributes", {}).get("version", "") for build in builds]


def ios_app_store_versions(api, app_id: str) -> list[dict]:
    versions, _ = api.collection(f"/v1/apps/{app_id}/appStoreVersions", {"filter[platform]": "IOS", "limit": 200})
    return list(versions)


def app_id_from(environ) -> str:
    value = environ.get("ASC_APP_ID", "")
    if not value.isdecimal():
        raise ReleaseError("ASC_APP_ID must be the numeric App Store Connect app ID.")
    return value


def _with_api(environ, callback):
    app_id = app_id_from(environ)
    if environ.get("ASC_PRIVATE_KEY_PATH"):
        return callback(AppStoreAPI(), app_id)
    if not environ.get("ASC_PRIVATE_KEY"):
        raise ReleaseError("Missing environment variables: ASC_PRIVATE_KEY or ASC_PRIVATE_KEY_PATH")
    with tempfile.TemporaryDirectory(prefix="cardbal-build-number-", dir=environ.get("RUNNER_TEMP")) as directory:
        key = Path(directory) / "AuthKey.p8"
        key.write_text(environ["ASC_PRIVATE_KEY"], encoding="utf-8")
        key.chmod(0o600)
        os.environ["ASC_PRIVATE_KEY_PATH"] = str(key)
        try:
            return callback(AppStoreAPI(), app_id)
        finally:
            os.environ.pop("ASC_PRIVATE_KEY_PATH", None)


def resolve(environ) -> str:
    return _with_api(environ, lambda api, app_id: next_ios_build(uploaded_build_numbers(api, app_id)))


def resolve_with_version(environ, requested_version: str, allow_bump: bool) -> tuple[str, str]:
    def query(api, app_id: str) -> tuple[str, str]:
        build = next_ios_build(uploaded_build_numbers(api, app_id))
        selected = open_ios_version(requested_version, ios_app_store_versions(api, app_id))
        if selected != requested_version and not allow_bump:
            raise ReleaseError(
                f"Version {requested_version} is closed in App Store Connect; next open version is {selected}."
            )
        return build, selected

    return _with_api(environ, query)


def main(argv: list[str] | None = None) -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--version", help="Check whether this marketing version train is open in App Store Connect")
    parser.add_argument("--allow-bump", action="store_true", help="Advance to the next patch version when closed")
    args = parser.parse_args(argv)
    try:
        if args.version is not None:
            build, selected = resolve_with_version(os.environ, args.version, args.allow_bump)
        else:
            build, selected = resolve(os.environ), None
    except ReleaseError as error:
        parser.error(str(error))
    output = os.environ.get("GITHUB_OUTPUT")
    if output:
        with open(output, "a", encoding="utf-8") as file:
            file.write(f"ios_build={build}\n")
            if selected is not None:
                bumped = "true" if selected != args.version else "false"
                file.write(f"ios_version={selected}\nversion_bumped={bumped}\n")
    if selected is not None and selected != args.version:
        print(f"Version {args.version} is closed in App Store Connect; bumped to {selected} (build {build})")
    else:
        print(f"Next iOS build number: {build}")


if __name__ == "__main__":
    main()
