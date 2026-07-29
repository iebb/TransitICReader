#!/usr/bin/env python3
"""Sync CardBal iOS's pinned iebb/korean-stations consumer export."""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
import shutil
import subprocess
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_SOURCE_ROOT = REPO_ROOT / ".external/korean-stations"
DEFAULT_DESTINATION = REPO_ROOT / "CardBal/Resources/korean_stations.tsv"
SOURCE_REPOSITORY = "iebb/korean-stations"
SOURCE_COMMIT = "82a9e4aeb534a710717056d704972a0fc1baafc9"
SOURCE_SHA256 = "42b9053314acbae86374871aa76938b979f966b0d3e25198b789990823e0d5bf"
EXPECTED_ALIAS_COUNT = 832
EXPECTED_COLUMNS = [
    "location_code",
    "station_id",
    "transport_mode_code",
    "transport_mode_name_ko",
    "transport_mode_name_en",
    "transport_mode_name_ja",
    "transport_mode_name_hanja",
    "transport_mode_name_zh_hans",
    "transport_mode_name_zh_hant",
    "transport_class",
    "station_name_ko",
    "canonical_name_ko",
    "station_name_en",
    "station_name_ja",
    "station_name_hanja",
    "station_name_zh_hans",
    "station_name_zh_hant",
    "operator_name",
    "line_name",
    "latitude",
    "longitude",
    "province_code",
    "province_name",
    "district_code",
    "district_name",
]


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def git_output(source_root: Path, *arguments: str) -> str:
    return subprocess.run(
        ["git", "-C", str(source_root), *arguments],
        check=True,
        capture_output=True,
        text=True,
    ).stdout.strip()


def verify_export(path: Path) -> None:
    if sha256(path) != SOURCE_SHA256:
        raise RuntimeError(f"Unexpected korean-stations SHA-256: {path}")
    with path.open(encoding="utf-8", newline="") as handle:
        reader = csv.DictReader(handle, delimiter="\t")
        if reader.fieldnames != EXPECTED_COLUMNS:
            raise RuntimeError(f"Unexpected korean-stations columns: {path}")
        rows = list(reader)
    if len(rows) != EXPECTED_ALIAS_COUNT:
        raise RuntimeError(f"Unexpected korean-stations alias count: {len(rows)}")
    location_codes = {row["location_code"] for row in rows}
    if len(location_codes) != EXPECTED_ALIAS_COUNT:
        raise RuntimeError("Duplicate korean-stations location code")
    for row in rows:
        location_code = row["location_code"]
        station_id = row["station_id"]
        try:
            mode_hex = f"{int(row['transport_mode_code']):04X}"
        except ValueError as error:
            raise RuntimeError(f"Invalid transport mode for {location_code}") from error
        if (
            len(location_code) != 12
            or location_code != location_code.upper()
            or any(character not in "0123456789ABCDEF" for character in location_code)
            or location_code[:8] != station_id
            or location_code[8:] != mode_hex
        ):
            raise RuntimeError(f"Invalid korean-stations location code: {location_code}")
        latitude_text = row["latitude"]
        longitude_text = row["longitude"]
        if bool(latitude_text) != bool(longitude_text):
            raise RuntimeError(f"Incomplete coordinates for {location_code}")
        if latitude_text:
            try:
                latitude = float(latitude_text)
                longitude = float(longitude_text)
            except ValueError as error:
                raise RuntimeError(f"Invalid coordinates for {location_code}") from error
            if not (32.0 <= latitude <= 40.0 and 123.0 <= longitude <= 133.0):
                raise RuntimeError(f"Out-of-range coordinates for {location_code}")


def sync(source_root: Path, destination: Path, check_only: bool) -> None:
    source_root = source_root.resolve()
    source_export = source_root / "dist/korean_stations.tsv"
    source_manifest = source_root / "dist/manifest.json"

    if git_output(source_root, "rev-parse", "HEAD") != SOURCE_COMMIT:
        raise RuntimeError(f"{SOURCE_REPOSITORY} is not at pinned commit {SOURCE_COMMIT}")
    remote = git_output(source_root, "remote", "get-url", "origin")
    if SOURCE_REPOSITORY.lower() not in remote.lower():
        raise RuntimeError(f"Unexpected korean-stations origin: {remote}")

    manifest = json.loads(source_manifest.read_text(encoding="utf-8"))
    if manifest.get("tsv", {}).get("sha256") != SOURCE_SHA256:
        raise RuntimeError("korean-stations manifest does not match the pinned export SHA-256")
    verify_export(source_export)

    if check_only:
        verify_export(destination)
        return

    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source_export, destination)
    verify_export(destination)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-root", type=Path, default=DEFAULT_SOURCE_ROOT)
    parser.add_argument("--destination", type=Path, default=DEFAULT_DESTINATION)
    parser.add_argument("--check", action="store_true", help="Verify the existing iOS resource without copying")
    args = parser.parse_args()
    sync(args.source_root, args.destination, args.check)
    print(
        {
            "repository": SOURCE_REPOSITORY,
            "commit": SOURCE_COMMIT,
            "destination": str(args.destination),
            "sha256": SOURCE_SHA256,
            "checked": args.check,
        }
    )


if __name__ == "__main__":
    main()
