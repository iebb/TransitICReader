#!/usr/bin/env python3

"""Generate CardBal's canonical local Korean transit research dataset.

The generator shares the same decoder and attribution pipeline as the Cloudflare
Pages visualizer, then stores the result in both JSON and queryable SQLite.  It
can refresh from the production D1 database, rebuild from a previous raw SQLite
snapshot, or rebuild from an attributed JSON snapshot.
"""

from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import os
import shlex
import sqlite3
import sys
import tempfile
from pathlib import Path
from typing import Any


REPO_ROOT = Path(__file__).resolve().parents[1]
SITE_ROOT = REPO_ROOT / "cloudflare" / "korean-trip-visualizer"
BUILDER_PATH = SITE_ROOT / "scripts" / "build_dataset.py"
DEFAULT_OUTPUT_DIR = REPO_ROOT / "datasets" / "korean-transit"
DEFAULT_SITE_OUTPUT = SITE_ROOT / "public" / "data" / "korean-trips.json"
DEFAULT_DATABASE = "cardbal-korean-trip-crowdsourcing"
DEFAULT_ACCOUNT_ID = "599ee1cd6c4d3dc453d290c4c0477e76"


def load_builder() -> Any:
    spec = importlib.util.spec_from_file_location("cardbal_korean_dataset_builder", BUILDER_PATH)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"Unable to import {BUILDER_PATH}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Generate the canonical local CardBal Korean transit dataset."
    )
    source = parser.add_mutually_exclusive_group()
    source.add_argument(
        "--source-sqlite",
        type=Path,
        help="Read korean_trip_records from an existing SQLite snapshot instead of D1.",
    )
    source.add_argument(
        "--source-json",
        type=Path,
        help="Rebuild from a previously generated Korean Trip Atlas JSON snapshot.",
    )
    parser.add_argument("--output-dir", type=Path, default=DEFAULT_OUTPUT_DIR)
    parser.add_argument("--site-output", type=Path, default=DEFAULT_SITE_OUTPUT)
    parser.add_argument("--no-site-sync", action="store_true")
    parser.add_argument("--database", default=DEFAULT_DATABASE)
    parser.add_argument(
        "--account-id",
        default=os.environ.get("CLOUDFLARE_ACCOUNT_ID", DEFAULT_ACCOUNT_ID),
    )
    parser.add_argument(
        "--generated-at",
        help="Override the ISO-8601 generation time for byte-for-byte reproducible builds.",
    )
    return parser.parse_args()


def rows_from_json(path: Path) -> list[dict[str, Any]]:
    payload = json.loads(path.read_text(encoding="utf-8"))
    rows = []
    for record in payload.get("records", []):
        created_at = record["createdAt"].removesuffix("Z").replace("T", " ")
        rows.append(
            {
                "dedup_hash": record["dedupHash"],
                "hashed_card_id": record["cardHash"],
                "card_id_last4": record.get("cardLast4", ""),
                "bytes_05_08": record["stationToken"],
                "bytes_09_0a": record["transportModeCode"],
                "all_bytes": record["raw"],
                "card_family": record["family"],
                "created_at": created_at,
            }
        )
    if not rows:
        raise RuntimeError(f"No records found in {path}")
    return sorted(rows, key=lambda row: (row["created_at"], row["dedup_hash"]))


def atomic_write(path: Path, data: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    temporary = Path(temporary_name)
    try:
        with os.fdopen(descriptor, "wb") as handle:
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
        temporary.replace(path)
    except BaseException:
        temporary.unlink(missing_ok=True)
        raise


def canonical_json(value: Any, pretty: bool = False) -> bytes:
    if pretty:
        rendered = json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True)
    else:
        rendered = json.dumps(value, ensure_ascii=False, separators=(",", ":"))
    return (rendered + "\n").encode("utf-8")


def insert_json_rows(
    connection: sqlite3.Connection,
    table: str,
    items: list[dict[str, Any]],
    key_columns: tuple[str, ...],
) -> None:
    columns = (*key_columns, "row_json")
    placeholders = ",".join("?" for _ in columns)
    connection.executemany(
        f"INSERT INTO {table} ({','.join(columns)}) VALUES ({placeholders})",
        [
            tuple(item[column] for column in key_columns)
            + (json.dumps(item, ensure_ascii=False, separators=(",", ":"), sort_keys=True),)
            for item in items
        ],
    )


def create_sqlite(
    output: Path,
    rows: list[dict[str, Any]],
    payload: dict[str, Any],
    system_codes: dict[int, dict[str, Any]],
) -> None:
    output.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(
        prefix=f".{output.name}.", suffix=".sqlite", dir=output.parent
    )
    os.close(descriptor)
    temporary = Path(temporary_name)
    try:
        connection = sqlite3.connect(temporary)
        try:
            connection.executescript(
                """
                PRAGMA journal_mode = DELETE;
                PRAGMA synchronous = FULL;
                PRAGMA foreign_keys = ON;

                CREATE TABLE metadata (
                    key TEXT PRIMARY KEY,
                    value TEXT NOT NULL
                );

                CREATE TABLE korean_trip_records (
                    dedup_hash TEXT PRIMARY KEY,
                    hashed_card_id TEXT NOT NULL,
                    card_id_last4 TEXT NOT NULL,
                    bytes_05_08 TEXT NOT NULL,
                    bytes_09_0a TEXT NOT NULL,
                    all_bytes TEXT NOT NULL,
                    card_family TEXT NOT NULL,
                    created_at TEXT NOT NULL
                );

                CREATE TABLE attributed_records (
                    id TEXT PRIMARY KEY,
                    hashed_card_id TEXT NOT NULL,
                    card_last4 TEXT NOT NULL,
                    card_family TEXT NOT NULL,
                    collected_at TEXT NOT NULL,
                    event TEXT NOT NULL,
                    event_raw INTEGER NOT NULL,
                    trip_counter INTEGER NOT NULL,
                    station_token TEXT NOT NULL,
                    transport_mode_code TEXT NOT NULL,
                    system_decimal INTEGER NOT NULL,
                    system_official_name_ko TEXT,
                    system_area TEXT,
                    location_code TEXT NOT NULL,
                    known_name TEXT,
                    known_provenance TEXT,
                    known_source_id TEXT,
                    trip_timestamp TEXT,
                    timestamp_layout TEXT NOT NULL,
                    timestamp_plausible INTEGER NOT NULL,
                    distance_meters INTEGER NOT NULL,
                    selected_fare INTEGER,
                    fare_layout TEXT NOT NULL,
                    record_json TEXT NOT NULL
                );

                CREATE TABLE transport_modes (
                    decimalCode INTEGER PRIMARY KEY,
                    row_json TEXT NOT NULL
                );

                CREATE TABLE station_aliases (
                    code TEXT PRIMARY KEY,
                    row_json TEXT NOT NULL
                );

                CREATE TABLE locations (code TEXT PRIMARY KEY, row_json TEXT NOT NULL);
                CREATE TABLE networks (code TEXT PRIMARY KEY, row_json TEXT NOT NULL);
                CREATE TABLE cards (hash TEXT PRIMARY KEY, row_json TEXT NOT NULL);
                CREATE TABLE journeys (id TEXT PRIMARY KEY, row_json TEXT NOT NULL);
                CREATE TABLE flows (
                    fromCode TEXT NOT NULL,
                    toCode TEXT NOT NULL,
                    row_json TEXT NOT NULL,
                    PRIMARY KEY (fromCode, toCode)
                );
                CREATE TABLE known_evidence (
                    sampleId TEXT NOT NULL,
                    locationCode TEXT NOT NULL,
                    row_json TEXT NOT NULL,
                    PRIMARY KEY (sampleId, locationCode)
                );
                CREATE TABLE field_stats (offset INTEGER PRIMARY KEY, row_json TEXT NOT NULL);
                CREATE TABLE sources (
                    source_index INTEGER PRIMARY KEY,
                    title TEXT NOT NULL,
                    url TEXT,
                    note TEXT NOT NULL,
                    row_json TEXT NOT NULL
                );
                """
            )
            connection.executemany(
                """
                INSERT INTO korean_trip_records
                    (dedup_hash, hashed_card_id, card_id_last4, bytes_05_08,
                     bytes_09_0a, all_bytes, card_family, created_at)
                VALUES
                    (:dedup_hash, :hashed_card_id, :card_id_last4, :bytes_05_08,
                     :bytes_09_0a, :all_bytes, :card_family, :created_at)
                """,
                rows,
            )
            connection.executemany(
                """
                INSERT INTO attributed_records VALUES
                    (:id, :cardHash, :cardLast4, :family, :createdAt, :event, :eventRaw,
                     :tripCounter, :stationToken, :transportModeCode, :systemDecimal,
                     :systemOfficialNameKo, :systemArea, :locationCode, :knownName,
                     :knownProvenance, :knownSourceID, :timestamp, :timestampLayout,
                     :timestampPlausible, :distanceMeters, :selectedFare, :fareLayout,
                     :record_json)
                """,
                [
                    {
                        **record,
                        "cardLast4": record.get("cardLast4", ""),
                        "timestampPlausible": int(record["timestampPlausible"]),
                        "record_json": json.dumps(
                            record,
                            ensure_ascii=False,
                            separators=(",", ":"),
                            sort_keys=True,
                        ),
                    }
                    for record in payload["records"]
                ],
            )
            mode_rows = [
                {"decimalCode": code, **mode} for code, mode in sorted(system_codes.items())
            ]
            insert_json_rows(connection, "transport_modes", mode_rows, ("decimalCode",))
            insert_json_rows(connection, "station_aliases", payload["knownLocations"], ("code",))
            insert_json_rows(connection, "locations", payload["locations"], ("code",))
            insert_json_rows(connection, "networks", payload["networks"], ("code",))
            insert_json_rows(connection, "cards", payload["cards"], ("hash",))
            insert_json_rows(connection, "journeys", payload["journeys"], ("id",))
            insert_json_rows(connection, "flows", payload["flows"], ("fromCode", "toCode"))
            insert_json_rows(
                connection,
                "known_evidence",
                payload["knownEvidence"],
                ("sampleId", "locationCode"),
            )
            insert_json_rows(connection, "field_stats", payload["fieldStats"], ("offset",))
            connection.executemany(
                """
                INSERT INTO sources (source_index, title, url, note, row_json)
                VALUES (?, ?, ?, ?, ?)
                """,
                [
                    (
                        index,
                        source["title"],
                        source.get("url"),
                        source["note"],
                        json.dumps(source, ensure_ascii=False, separators=(",", ":"), sort_keys=True),
                    )
                    for index, source in enumerate(payload["sources"])
                ],
            )
            metadata = {
                "format": "cardbal-korean-transit-sqlite-v1",
                "generated_at": payload["meta"]["generatedAt"],
                "source_first_seen": payload["meta"]["sourceFirstSeen"],
                "source_last_seen": payload["meta"]["sourceLastSeen"],
                "record_count": str(payload["summary"]["records"]),
                "summary_json": json.dumps(
                    payload["summary"], ensure_ascii=False, separators=(",", ":"), sort_keys=True
                ),
            }
            connection.executemany(
                "INSERT INTO metadata (key, value) VALUES (?, ?)", sorted(metadata.items())
            )
            connection.executescript(
                """
                CREATE INDEX idx_raw_card ON korean_trip_records (hashed_card_id);
                CREATE INDEX idx_raw_mode ON korean_trip_records (bytes_09_0a);
                CREATE INDEX idx_attributed_card_time
                    ON attributed_records (hashed_card_id, trip_timestamp);
                CREATE INDEX idx_attributed_location
                    ON attributed_records (location_code);
                CREATE INDEX idx_attributed_mode
                    ON attributed_records (system_decimal);
                CREATE INDEX idx_attributed_known_name
                    ON attributed_records (known_name);
                CREATE INDEX idx_attributed_timestamp_layout
                    ON attributed_records (timestamp_layout, timestamp_plausible);
                ANALYZE;
                """
            )
            connection.commit()
            connection.execute("VACUUM")
        finally:
            connection.close()
        temporary.replace(output)
    except BaseException:
        temporary.unlink(missing_ok=True)
        raise


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        while chunk := handle.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def relative(path: Path) -> str:
    try:
        return str(path.resolve().relative_to(REPO_ROOT))
    except ValueError:
        return str(path.resolve())


def build_manifest(
    args: argparse.Namespace,
    payload: dict[str, Any],
    json_output: Path,
    sqlite_output: Path,
) -> dict[str, Any]:
    summary = payload["summary"]
    networks = sorted(payload["networks"], key=lambda row: (-row["records"], row["code"]))
    source_mode = (
        f"sqlite:{relative(args.source_sqlite)}"
        if args.source_sqlite
        else f"json:{relative(args.source_json)}"
        if args.source_json
        else f"d1:{args.database}"
    )
    return {
        "format": "cardbal-korean-transit-manifest-v1",
        "generatedAt": payload["meta"]["generatedAt"],
        "generator": relative(Path(__file__)),
        "source": source_mode,
        "rebuildCommands": {
            "online": "python3 scripts/generate_korean_transit_dataset.py",
            "offline": (
                "python3 scripts/generate_korean_transit_dataset.py "
                "--source-sqlite datasets/korean-transit/cardbal-korean-transit.sqlite"
            ),
        },
        "privacy": {
            "cardIdentifiers": "SHA-256 hashes supplied by the collector; no plaintext card ID is stored.",
            "lastFourDigits": "Retained because the user explicitly authorized the public dataset.",
            "rawRecords": "Full 52-byte records retained for reproducible protocol research.",
        },
        "files": {
            json_output.name: {
                "path": relative(json_output),
                "bytes": json_output.stat().st_size,
                "sha256": sha256(json_output),
            },
            sqlite_output.name: {
                "path": relative(sqlite_output),
                "bytes": sqlite_output.stat().st_size,
                "sha256": sha256(sqlite_output),
            },
        },
        "coverage": {
            "records": summary["records"],
            "cards": summary["cards"],
            "transportModeCodesObserved": summary["transportModeCodes"],
            "officialModeRows": summary["officialSystemRows"],
            "officialModePercent": summary["officialSystemCoverage"],
            "namedStationRows": summary["confirmedRows"],
            "namedStationPercent": summary["confirmedCoverage"],
            "plausibleTimestampRows": summary["plausibleTimestamps"],
            "plausibleTimestampPercent": summary["timestampCoverage"],
            "exactEventRows": summary["exactEvents"],
            "exactEventPercent": summary["eventCoverage"],
            "pairedJourneyCandidates": summary["pairedJourneys"],
        },
        "observedModes": [
            {
                "decimalCode": network["decimalCode"],
                "hexCode": network["code"],
                "officialNameKo": network["officialNameKo"],
                "area": network["area"],
                "matchStatus": network["matchStatus"],
                "records": network["records"],
                "locations": network["locations"],
                "namedLocations": len(network["knownLocations"]),
                "timestampLayouts": network["timestampLayouts"],
            }
            for network in networks
        ],
        "sources": payload["sources"],
    }


def validate_sqlite(
    path: Path,
    payload: dict[str, Any],
    transport_mode_count: int,
) -> None:
    connection = sqlite3.connect(path)
    try:
        integrity = connection.execute("PRAGMA integrity_check").fetchone()[0]
        if integrity != "ok":
            raise RuntimeError(f"SQLite integrity check failed: {integrity}")
        expected = {
            "korean_trip_records": payload["summary"]["records"],
            "attributed_records": payload["summary"]["records"],
            "transport_modes": transport_mode_count,
            "station_aliases": len(payload["knownLocations"]),
            "locations": len(payload["locations"]),
            "networks": len(payload["networks"]),
            "cards": len(payload["cards"]),
            "journeys": len(payload["journeys"]),
            "flows": len(payload["flows"]),
        }
        actual = {
            table: connection.execute(f"SELECT COUNT(*) FROM {table}").fetchone()[0]
            for table in expected
        }
        if actual != expected:
            raise RuntimeError(f"SQLite row-count mismatch: expected {expected}, found {actual}")
    finally:
        connection.close()


def main() -> None:
    args = parse_args()
    builder = load_builder()
    system_codes = builder.read_system_codes(builder.DEFAULT_SYSTEM_CODES)
    known, evidence = builder.read_known_locations(
        builder.DEFAULT_KNOWN, builder.DEFAULT_STATION_ALIASES, system_codes
    )
    if args.source_json:
        rows = rows_from_json(args.source_json)
    elif args.source_sqlite:
        rows = builder.read_rows_from_sqlite(args.source_sqlite)
    else:
        rows = builder.read_rows_from_d1(
            args.database, args.account_id, builder.WORKER_ROOT
        )
    if not rows:
        raise RuntimeError("No Korean trip rows were returned")

    # The public builder intentionally does not query or emit plaintext card
    # suffixes. Keep the legacy SQLite columns populated with an empty string
    # so older local readers remain schema-compatible without reintroducing the
    # discarded identifier fragment.
    rows = [{**row, "card_id_last4": row.get("card_id_last4", "")} for row in rows]

    payload = builder.build_payload(rows, known, evidence, system_codes)
    if args.generated_at:
        payload["meta"]["generatedAt"] = args.generated_at
    payload["meta"]["generator"] = relative(Path(__file__))
    payload["meta"]["localDataset"] = "datasets/korean-transit/cardbal-korean-transit.sqlite"

    output_dir = args.output_dir.resolve()
    json_output = output_dir / "korean-trips.json"
    sqlite_output = output_dir / "cardbal-korean-transit.sqlite"
    json_bytes = canonical_json(payload)
    atomic_write(json_output, json_bytes)
    create_sqlite(sqlite_output, rows, payload, system_codes)
    validate_sqlite(sqlite_output, payload, len(system_codes))

    if not args.no_site_sync:
        atomic_write(args.site_output.resolve(), json_bytes)

    manifest = build_manifest(args, payload, json_output, sqlite_output)
    manifest_output = output_dir / "manifest.json"
    atomic_write(manifest_output, canonical_json(manifest, pretty=True))

    command = " ".join(shlex.quote(value) for value in sys.argv)
    print(
        json.dumps(
            {
                "command": command,
                "records": payload["summary"]["records"],
                "cards": payload["summary"]["cards"],
                "namedStationRows": payload["summary"]["confirmedRows"],
                "officialModeRows": payload["summary"]["officialSystemRows"],
                "plausibleTimestampRows": payload["summary"]["plausibleTimestamps"],
                "json": manifest["files"][json_output.name],
                "sqlite": manifest["files"][sqlite_output.name],
                "siteSynced": not args.no_site_sync,
            },
            ensure_ascii=False,
            indent=2,
        )
    )


if __name__ == "__main__":
    main()
