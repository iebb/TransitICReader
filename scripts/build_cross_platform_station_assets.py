#!/usr/bin/env python3

import argparse
import datetime as dt
import hashlib
import json
import shutil
import sqlite3
import subprocess
import sys
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
SCRIPTS_DIR = REPO_ROOT / "scripts"
IOS_RESOURCES = REPO_ROOT / "CardBal/Resources"
ANDROID_ASSETS = REPO_ROOT / "android/app/src/main/assets"
PORTABLE_ASSETS = REPO_ROOT / "StationAssets"

JP_ASSETS = [
    "JPBusCodes.csv",
    "JPStationCodes.csv",
    "JPStationCodes.json",
    "jp_stations.sqlite",
    "jp_stations_coverage.json",
]

TUNION_ASSETS = [
    "TUnionCardNames.json",
    "TUnionCityCodes.json",
    "TUnionLineStations.json",
    "tunion_stations.sqlite",
    "tunion_tripreader_source.json",
]

TUNION_SOURCE_ASSETS = [
    "tunion_osm_city_cache.json",
    "tunion_osm_bus_city_cache.json",
]

KOREAN_ASSETS = [
    "KOTRISTransportModes.json",
]

ULAANBAATAR_ASSETS = [
    "ulaanbaatar_stations.tsv",
    "ulaanbaatar_routes.tsv",
    "ulaanbaatar_route_stations.tsv",
    "ulaanbaatar_transit.sqlite",
]

ULAANBAATAR_PLATFORM_ASSETS = [
    "ulaanbaatar_transit.sqlite",
]

# CardBal iOS vendors korean_stations.tsv and its derived East Asia boundary
# catalog directly. They are intentionally not copied into Android or portable
# asset trees.


def asset_names(target: str) -> list[str]:
    names: list[str] = []
    if target in ("all", "japanese"):
        names.extend(JP_ASSETS)
    if target in ("all", "tunion"):
        names.extend(TUNION_ASSETS + TUNION_SOURCE_ASSETS)
    if target in ("all", "korean"):
        names.extend(KOREAN_ASSETS)
    if target in ("all", "ulaanbaatar"):
        names.extend(ULAANBAATAR_ASSETS)
    return names


def platform_asset_names(target: str) -> list[str]:
    names: list[str] = []
    if target in ("all", "japanese"):
        names.extend(JP_ASSETS)
    if target in ("all", "tunion"):
        names.extend(TUNION_ASSETS)
    if target in ("all", "korean"):
        names.extend(KOREAN_ASSETS)
    if target in ("all", "ulaanbaatar"):
        names.extend(ULAANBAATAR_PLATFORM_ASSETS)
    return names


def run(command: list[str]) -> None:
    print("+ " + " ".join(command), flush=True)
    subprocess.run(command, cwd=REPO_ROOT, check=True)


def copy_assets(names: list[str], source_dir: Path, destination: Path) -> None:
    destination.mkdir(parents=True, exist_ok=True)
    for name in names:
        source = source_dir / name
        if not source.exists():
            raise FileNotFoundError(source)
        shutil.copy2(source, destination / name)


def seed_portable_assets(names: list[str], portable_assets: Path, ios_resources: Path) -> None:
    portable_assets.mkdir(parents=True, exist_ok=True)
    for name in names:
        destination = portable_assets / name
        if destination.exists():
            continue
        source = ios_resources / name
        if source.exists():
            shutil.copy2(source, destination)


def sqlite_count(path: Path, table: str) -> int | None:
    if not path.exists():
        return None
    with sqlite3.connect(path) as connection:
        return int(connection.execute(f"SELECT COUNT(*) FROM {table}").fetchone()[0])


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def write_manifest(portable_assets: Path) -> None:
    files = {}
    for path in sorted(portable_assets.iterdir()):
        if path.name == "manifest.json" or not path.is_file():
            continue
        files[path.name] = {
            "bytes": path.stat().st_size,
            "sha256": sha256(path),
        }

    manifest = {
        "format": "cardbal-portable-station-assets-v1",
        "generatedAt": dt.datetime.now(dt.timezone.utc).isoformat(),
        "files": files,
        "sqlite": {
            "jp_stations": sqlite_count(portable_assets / "jp_stations.sqlite", "jp_stations"),
            "jp_station_edges": sqlite_count(portable_assets / "jp_stations.sqlite", "station_edges"),
            "tunion_stations": sqlite_count(portable_assets / "tunion_stations.sqlite", "tunion_stations"),
            "tunion_station_edges": sqlite_count(portable_assets / "tunion_stations.sqlite", "station_edges"),
            "ulaanbaatar_stations": sqlite_count(portable_assets / "ulaanbaatar_transit.sqlite", "stations"),
            "ulaanbaatar_routes": sqlite_count(portable_assets / "ulaanbaatar_transit.sqlite", "routes"),
            "ulaanbaatar_route_stations": sqlite_count(
                portable_assets / "ulaanbaatar_transit.sqlite",
                "route_stations",
            ),
        },
    }
    (portable_assets / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def build_japanese(python: str, portable_assets: Path) -> None:
    run(
        [
            python,
            str(SCRIPTS_DIR / "generate_jp_stations.py"),
            "--codes-csv",
            str(portable_assets / "JPStationCodes.csv"),
            "--output-db",
            str(portable_assets / "jp_stations.sqlite"),
            "--report-json",
            str(portable_assets / "jp_stations_coverage.json"),
        ]
    )


def build_tunion(python: str, portable_assets: Path, delay_seconds: float, skip_osm: bool, offline_source: bool) -> None:
    if not skip_osm:
        run(
            [
                python,
                str(SCRIPTS_DIR / "generate_tunion_stations.py"),
                "--stations-json",
                str(portable_assets / "TUnionLineStations.json"),
                "--cities-json",
                str(portable_assets / "TUnionCityCodes.json"),
                "--city-cache-json",
                str(portable_assets / "tunion_osm_city_cache.json"),
                "--bus-cache-json",
                str(portable_assets / "tunion_osm_bus_city_cache.json"),
                "--output-db",
                str(portable_assets / "tunion_stations.sqlite"),
                "--delay-seconds",
                str(delay_seconds),
            ]
        )
    run(
        [
            python,
            str(SCRIPTS_DIR / "enrich_tunion_source.py"),
            "--db",
            str(portable_assets / "tunion_stations.sqlite"),
            "--source-cache",
            str(portable_assets / "tunion_tripreader_source.json"),
        ]
        + (["--offline"] if offline_source else [])
    )


def build_ulaanbaatar(python: str, portable_assets: Path, delay_seconds: float) -> None:
    run(
        [
            python,
            str(SCRIPTS_DIR / "download_ub_smart_bus.py"),
            "--output-dir",
            str(portable_assets),
            "--delay-seconds",
            str(delay_seconds),
        ]
    )


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Build portable CardBal station assets once, then sync the same outputs to iOS resources and Android assets.",
    )
    parser.add_argument(
        "--target",
        choices=["all", "japanese", "tunion", "korean", "ulaanbaatar"],
        default="all",
    )
    parser.add_argument("--portable-assets", type=Path, default=PORTABLE_ASSETS)
    parser.add_argument("--ios-resources", type=Path, default=IOS_RESOURCES)
    parser.add_argument("--android-assets", type=Path, default=ANDROID_ASSETS)
    parser.add_argument("--python", default=sys.executable)
    parser.add_argument("--copy-only", action="store_true", help="Only sync existing portable assets into iOS and Android.")
    parser.add_argument("--no-sync-ios", action="store_true", help="Do not copy portable outputs into CardBal/Resources.")
    parser.add_argument("--no-sync-android", action="store_true", help="Do not copy portable outputs into android/app/src/main/assets.")
    parser.add_argument("--skip-tunion-osm", action="store_true", help="Skip the OSM T-Union generator and only run source enrichment.")
    parser.add_argument("--offline-tunion-source", action="store_true", help="Use the checked-in T-Union source cache instead of fetching tripreader-data.")
    parser.add_argument("--tunion-delay-seconds", type=float, default=3.0)
    parser.add_argument("--ulaanbaatar-delay-seconds", type=float, default=0.05)
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    names = asset_names(args.target)
    platform_names = platform_asset_names(args.target)
    seed_portable_assets(names, args.portable_assets, args.ios_resources)
    if not args.copy_only:
        if args.target in ("all", "japanese"):
            build_japanese(args.python, args.portable_assets)
        if args.target in ("all", "tunion"):
            build_tunion(args.python, args.portable_assets, args.tunion_delay_seconds, args.skip_tunion_osm, args.offline_tunion_source)
        if args.target in ("all", "ulaanbaatar"):
            build_ulaanbaatar(args.python, args.portable_assets, args.ulaanbaatar_delay_seconds)

    write_manifest(args.portable_assets)
    if not args.no_sync_ios:
        copy_assets(platform_names, args.portable_assets, args.ios_resources)
    if not args.no_sync_android:
        copy_assets(platform_names + ["manifest.json"], args.portable_assets, args.android_assets)

    print(
        {
            "target": args.target,
            "portable_assets": str(args.portable_assets),
            "ios_resources": str(args.ios_resources),
            "android_assets": str(args.android_assets),
            "copy_only": args.copy_only,
        }
    )


if __name__ == "__main__":
    main()
