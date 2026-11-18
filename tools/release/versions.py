"""Resolve the release version and the Android version code inside each store build job.

Android version codes count minutes since the epoch, so Play uploads stay unique
and monotonic while store jobs share one concurrency group. iOS build numbers are
simple counters picked from App Store Connect by tools.release.ios_build_number.
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
    day = minutes // (24 * 60)
    if not 1 <= day <= MAX_EPOCH_DAY:
        raise ValueError(f"Build day {day} since 2020-01-01 UTC must be from 1 to {MAX_EPOCH_DAY}.")
    stamp = EPOCH + timedelta(minutes=minutes)
    return {"android_version_code": str(minutes), "build_timestamp": stamp.strftime("%Y-%m-%dT%H:%MZ")}


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


def write_repository_version(version: str, root: Path = ROOT) -> bool:
    if not re.fullmatch(VERSION_PATTERN, version):
        raise ValueError("Version must have three numeric components, for example 2.5.0.")
    ios_path = root / IOS_PROJECT
    android_path = root / ANDROID_BUILD_SCRIPT
    ios_before = ios_path.read_text(encoding="utf-8")
    android_before = android_path.read_text(encoding="utf-8")
    ios_after = re.sub(
        r'^(\s*MARKETING_VERSION = )"[^";\s]*"(;)$|^(\s*MARKETING_VERSION = )[^";\s]+(;)$',
        lambda m: f'{m.group(1)}"{version}"{m.group(2)}' if m.group(1) else f"{m.group(3)}{version}{m.group(4)}",
        ios_before,
        flags=re.MULTILINE,
    )
    android_after = re.sub(
        r'(gradleProperty\("transitic\.versionName"\)\.orElse\(")([^"]*)("\))',
        rf"\g<1>{version}\g<3>",
        android_before,
    )
    if ios_marketing_version(ios_after) != version or android_version_name(android_after) != version:
        raise ValueError(f"Could not update both repository version declarations to {version}.")
    changed = (ios_after != ios_before) or (android_after != android_before)
    if ios_after != ios_before:
        ios_path.write_text(ios_after, encoding="utf-8")
    if android_after != android_before:
        android_path.write_text(android_after, encoding="utf-8")
    return changed


def main(argv: list[str] | None = None, now: datetime | None = None) -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--write-version", help="Update iOS and Android repository marketing versions")
    args = parser.parse_args(argv)
    try:
        if args.write_version is not None:
            write_repository_version(args.write_version)
            print(f"Updated iOS and Android repository versions to {args.write_version}")
            return
        values = upload_versions(os.environ.get("RELEASE_VERSION", ""), now)
    except ValueError as error:
        parser.error(str(error))
    output = os.environ.get("GITHUB_OUTPUT")
    if output:
        with open(output, "a", encoding="utf-8") as file:
            for key, value in values.items():
                file.write(f"{key}={value}\n")
    print(f"Version {values['version']} at {values['build_timestamp']}: "
          f"Android code {values['android_version_code']}")


if __name__ == "__main__":
    main()
