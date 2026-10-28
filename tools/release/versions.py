"""Validate manual upload inputs before either store job receives credentials."""
import argparse
import os
import re


def upload_versions(version: str, build_number: str, run_number: str, run_attempt: str) -> dict[str, str]:
    if not re.fullmatch(r"(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)", version):
        raise ValueError("Version must have three numeric components, for example 2.5.0.")
    if not re.fullmatch(r"[1-9][0-9]?", run_attempt):
        raise ValueError("The workflow attempt must be from 1 to 99.")
    if build_number:
        if not re.fullmatch(r"[1-9][0-9]{0,3}", build_number):
            raise ValueError("An explicit build number must be an integer from 1 to 9999.")
        major = int(build_number)
    else:
        if not re.fullmatch(r"[1-9][0-9]*", run_number):
            raise ValueError("Automatic build numbers require a positive workflow run.")
        major = 1000 + int(run_number)
    if major > 9999:
        raise ValueError("Specify a build number: automatic iOS build numbers have reached 9999.")
    code = major * 100 + int(run_attempt)
    if code > 2100000000:
        raise ValueError("Automatic Android version code exceeds Google Play's limit.")
    return {"version": version, "ios_build": f"{major}.{int(run_attempt)}", "android_version_code": str(code)}


def paired_store_builds(apple: dict, google: dict) -> dict[str, str]:
    build = apple["build"]
    if build["version"] != google["version"]:
        raise ValueError("Latest TestFlight and Play internal versions differ. Finish both uploads before releasing.")
    match = re.fullmatch(r"([1-9][0-9]{0,3})\.([1-9][0-9]?)", build["build_number"])
    if not match or int(google["version_code"]) != int(match[1]) * 100 + int(match[2]):
        raise ValueError("Latest TestFlight and Play internal builds are from different upload attempts. Wait for both matching Upload builds to finish processing.")
    return {"version": build["version"], "ios_build_id": build["id"],
            "android_version_code": str(google["version_code"])}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.parse_args()
    try:
        values = upload_versions(os.environ.get("RELEASE_VERSION", ""), os.environ.get("RELEASE_BUILD_NUMBER", ""),
                                 os.environ.get("GITHUB_RUN_NUMBER", ""), os.environ.get("GITHUB_RUN_ATTEMPT", ""))
    except ValueError as error:
        parser.error(str(error))
    output = os.environ.get("GITHUB_OUTPUT")
    if output:
        with open(output, "a", encoding="utf-8") as file:
            for key, value in values.items():
                file.write(f"{key}={value}\n")
    print(f"Version {values['version']}: iOS build {values['ios_build']}, Android code {values['android_version_code']}")


if __name__ == "__main__":
    main()
