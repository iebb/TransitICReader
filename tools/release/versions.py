"""Resolve the release version and timestamp build numbers inside each store build job.

iOS builds use days-since-epoch.hour.minute, which stays within Apple's archived
4.2.2 digit guidance for CFBundleVersion. Android version codes count minutes since
the epoch. Both come from the same UTC minute, so the store uploads stay independent
but remain unique and monotonic while store jobs share one concurrency group.
"""
import argparse
import os
import re
from datetime import datetime, timedelta, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
EPOCH = datetime(2020, 1, 1, tzinfo=timezone.utc)
MAX_EPOCH_DAY = 9999
MAX_ANDROID_VERSION_CODE = 2100000000
VERSION_PATTERN = r"(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)"
IOS_PROJECT = Path("CardBal.xcodeproj/project.pbxproj")
ANDROID_BUILD_SCRIPT = Path("android/app/build.gradle.kts")


def build_numbers(now: datetime) -> dict[str, str]:
    if now.tzinfo is None or now.utcoffset() is None:
        raise ValueError("Build time must be timezone-aware.")
    minutes = (now.astimezone(timezone.utc) - EPOCH) // timedelta(minutes=1)
    day, minute_of_day = divmod(minutes, 24 * 60)
    if not 1 <= day <= MAX_EPOCH_DAY:
        raise ValueError(f"Build day {day} since 2020-01-01 UTC must be from 1 to {MAX_EPOCH_DAY}.")
    hour, minute = divmod(minute_of_day, 60)
    stamp = EPOCH + timedelta(minutes=minutes)
    return {"ios_build": f"{day}.{hour}.{minute}", "android_version_code": str(minutes),
            "build_timestamp": stamp.strftime("%Y-%m-%dT%H:%MZ")}


def ios_marketing_version(project: str) -> str:
    versions = set(re.findall(r'^\s*MARKETING_VERSION = "?([^";\s]*)"?;', project, re.MULTILINE))
    if len(versions) != 1:
        raise ValueError(f"The iOS project must define one MARKETING_VERSION; found {sorted(versions) or 'none'}.")
    return versions.pop()


def android_version_name(build_script: str) -> str:
    versions = re.findall(r'gradleProperty\("transitic\.versionName"\)\.orElse\("([^"]*)"\)', build_script)
    if len(versions) != 1:
        raise ValueError("The Android build script must define one transitic.versionName default.")
    return versions[0]


def repository_versions(root: Path = ROOT) -> dict[str, str]:
    return {"ios": ios_marketing_version((root / IOS_PROJECT).read_text(encoding="utf-8")),
            "android": android_version_name((root / ANDROID_BUILD_SCRIPT).read_text(encoding="utf-8"))}


def release_version(requested: str, repository: dict[str, str]) -> str:
    if repository["ios"] != repository["android"]:
        raise ValueError(f"Repository iOS version {repository['ios']} and Android version "
                         f"{repository['android']} differ. Align them before uploading.")
    version = repository["ios"]
    if not re.fullmatch(VERSION_PATTERN, version):
        raise ValueError(f"Repository version {version!r} must have three numeric components.")
    if requested.strip():
        if not re.fullmatch(VERSION_PATTERN, requested):
            raise ValueError("Version must have three numeric components, for example 2.5.0.")
        if requested != version:
            raise ValueError(f"Requested version {requested} does not match repository version {version}.")
    return version


def upload_versions(version: str = "", now: datetime | None = None, root: Path = ROOT) -> dict[str, str]:
    resolved = release_version(version, repository_versions(root))
    return {"version": resolved, **build_numbers(now or datetime.now(timezone.utc))}


def paired_store_builds(apple: dict, google: dict) -> dict[str, str]:
    build = apple["build"]
    if build["version"] != google["version"]:
        raise ValueError(f"Latest TestFlight version {build['version']} and Play internal version "
                         f"{google['version']} differ. Upload the same version to both before releasing.")
    code = google["version_code"]
    if isinstance(code, bool) or not re.fullmatch(r"[1-9][0-9]*", str(code)) or int(code) > MAX_ANDROID_VERSION_CODE:
        raise ValueError("Latest Play internal build has an invalid version code.")
    if not isinstance(build["id"], str) or not build["id"]:
        raise ValueError("Latest TestFlight build has no App Store Connect ID.")
    return {"version": build["version"], "ios_build_id": build["id"], "android_version_code": str(int(code))}


def main(argv: list[str] | None = None, now: datetime | None = None) -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.parse_args(argv)
    try:
        values = upload_versions(os.environ.get("RELEASE_VERSION", ""), now)
    except ValueError as error:
        parser.error(str(error))
    output = os.environ.get("GITHUB_OUTPUT")
    if output:
        with open(output, "a", encoding="utf-8") as file:
            for key, value in values.items():
                file.write(f"{key}={value}\n")
    print(f"Version {values['version']} at {values['build_timestamp']}: "
          f"iOS build {values['ios_build']}, Android code {values['android_version_code']}")


if __name__ == "__main__":
    main()
