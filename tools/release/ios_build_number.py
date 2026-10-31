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


def next_ios_build(existing: Iterable[str]) -> str:
    plain = [int(value) for value in existing if isinstance(value, str) and PLAIN_BUILD.fullmatch(value)]
    return str(max(plain, default=0) + 1)


def uploaded_build_numbers(api, app_id: str) -> list[str]:
    builds, _ = api.collection("/v1/builds", {"filter[app]": app_id, "fields[builds]": "version", "limit": 200})
    return [build.get("attributes", {}).get("version", "") for build in builds]


def app_id_from(environ) -> str:
    value = environ.get("ASC_APP_ID", "")
    if not value.isdecimal():
        raise ReleaseError("ASC_APP_ID must be the numeric App Store Connect app ID.")
    return value


def resolve(environ) -> str:
    app_id = app_id_from(environ)
    if environ.get("ASC_PRIVATE_KEY_PATH"):
        return next_ios_build(uploaded_build_numbers(AppStoreAPI(), app_id))
    if not environ.get("ASC_PRIVATE_KEY"):
        raise ReleaseError("Missing environment variables: ASC_PRIVATE_KEY or ASC_PRIVATE_KEY_PATH")
    with tempfile.TemporaryDirectory(prefix="cardbal-build-number-", dir=environ.get("RUNNER_TEMP")) as directory:
        key = Path(directory) / "AuthKey.p8"
        key.write_text(environ["ASC_PRIVATE_KEY"], encoding="utf-8")
        key.chmod(0o600)
        os.environ["ASC_PRIVATE_KEY_PATH"] = str(key)
        try:
            return next_ios_build(uploaded_build_numbers(AppStoreAPI(), app_id))
        finally:
            os.environ.pop("ASC_PRIVATE_KEY_PATH", None)


def main(argv: list[str] | None = None) -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.parse_args(argv)
    try:
        build = resolve(os.environ)
    except ReleaseError as error:
        parser.error(str(error))
    output = os.environ.get("GITHUB_OUTPUT")
    if output:
        with open(output, "a", encoding="utf-8") as file:
            file.write(f"ios_build={build}\n")
    print(f"Next iOS build number: {build}")


if __name__ == "__main__":
    main()
