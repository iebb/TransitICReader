#!/usr/bin/env python3

import argparse
import json
import sqlite3
from collections import defaultdict
from contextlib import closing
from dataclasses import dataclass
from pathlib import Path

from tripreader_source import load_source_payload, station_line_code


REPO_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_DB = REPO_ROOT / "CardBal/Resources/tunion_stations.sqlite"
DEFAULT_SOURCE_CACHE = REPO_ROOT / "CardBal/Resources/tunion_tripreader_source.json"
DEFAULT_CITY_CODES = REPO_ROOT / "CardBal/Resources/TUnionCityCodes.json"


@dataclass(frozen=True)
class SourceStation:
    city_id: str
    code: str
    station_type: str
    line_name: str
    station_name: str
    city_folder: str
    csv_file: str

    @property
    def station_key(self) -> str:
        return f"{self.city_id}{self.code}"

    @property
    def line_code(self) -> str:
        return station_line_code(self.code)

    def to_json(self) -> dict:
        return {
            "city_id": self.city_id,
            "code": self.code,
            "line": self.line_name,
            "station": self.station_name,
            "type": self.station_type,
            "city_folder": self.city_folder,
            "csv_file": self.csv_file,
        }


@dataclass(frozen=True)
class SourceLine:
    city_id: str
    line_code: str
    line_name: str
    station_type: str
    city_folder: str
    csv_file: str
    source_count: int

    @property
    def key(self) -> str:
        return f"{self.city_id}|{self.line_code}|{self.line_name}|{self.station_type}"

    def to_json(self) -> dict:
        return {
            "city_id": self.city_id,
            "line_code": self.line_code,
            "line": self.line_name,
            "type": self.station_type,
            "city_folder": self.city_folder,
            "csv_file": self.csv_file,
            "station_count": self.source_count,
        }


def decode_sources(payload: dict) -> tuple[dict[str, SourceStation], dict[str, SourceLine]]:
    stations = {
        key: SourceStation(
            city_id=value["city_id"],
            code=value["code"],
            station_type=value["type"],
            line_name=value["line"],
            station_name=value["station"],
            city_folder=value["city_folder"],
            csv_file=value["csv_file"],
        )
        for key, value in payload.get("stations", {}).items()
    }
    lines = {
        key: SourceLine(
            city_id=value["city_id"],
            line_code=value["line_code"],
            line_name=value["line"],
            station_type=value["type"],
            city_folder=value["city_folder"],
            csv_file=value["csv_file"],
            source_count=int(value["station_count"]),
        )
        for key, value in payload.get("lines", {}).items()
    }
    return stations, lines


def load_city_names() -> dict[str, str]:
    return json.loads(DEFAULT_CITY_CODES.read_text(encoding="utf-8"))


def ensure_columns(connection: sqlite3.Connection) -> None:
    cursor = connection.cursor()
    cursor.execute("""
        CREATE TABLE IF NOT EXISTS cityunion_terminal_prefixes (
            terminal_prefix TEXT PRIMARY KEY, city_id TEXT NOT NULL,
            station_name TEXT NOT NULL, line_name TEXT NOT NULL,
            station_type TEXT NOT NULL, station_key TEXT,
            source_json TEXT NOT NULL
        ) WITHOUT ROWID
    """)
    existing = {row[1] for row in cursor.execute("PRAGMA table_info(tunion_stations)")}
    for column in ["source_code", "source_type", "source_line_name", "source_station_name", "source_tripreader_json"]:
        if column not in existing:
            cursor.execute(f"ALTER TABLE tunion_stations ADD COLUMN {column} TEXT")

    cursor.execute(
        """
        CREATE TABLE IF NOT EXISTS tunion_lines (
            city_id TEXT NOT NULL,
            line_code TEXT NOT NULL,
            line_name TEXT NOT NULL,
            station_type TEXT NOT NULL,
            source_count INTEGER NOT NULL,
            source_city_folder TEXT,
            source_csv_file TEXT,
            PRIMARY KEY (city_id, line_code, line_name, station_type)
        );
        """
    )
    cursor.execute(
        """
        CREATE TABLE IF NOT EXISTS tunion_terminal_stations (
            record_kind TEXT NOT NULL CHECK (record_kind IN ('18', '1e')),
            city_id TEXT NOT NULL,
            terminal_code TEXT NOT NULL,
            station_name TEXT NOT NULL,
            line_name TEXT NOT NULL,
            station_type TEXT NOT NULL,
            station_key TEXT REFERENCES tunion_stations(station_key),
            source_json TEXT NOT NULL,
            PRIMARY KEY (record_kind, city_id, terminal_code)
        ) WITHOUT ROWID
        """
    )
    connection.commit()


def parse_line_context(line_key: str, city_id: str) -> str:
    if line_key.startswith(city_id):
        return line_key[len(city_id) :]
    return line_key


def choose_line_source(
    city_id: str,
    line_code: str,
    source_lines_by_code: dict[tuple[str, str], list[SourceLine]],
) -> SourceLine | None:
    candidates = source_lines_by_code.get((city_id, line_code), [])
    if not candidates:
        return None
    if len(candidates) == 1:
        return candidates[0]
    # A shared code can represent more than one line. Do not pick one arbitrarily.
    return None


def merge_into_database(
    db_path: Path, source_cache_path: Path, offline: bool = False,
    source_directory: Path | None = None,
) -> None:
    if offline:
        payload = json.loads(source_cache_path.read_text(encoding="utf-8"))
    else:
        payload = load_source_payload(source_directory)
    source_stations, source_lines = decode_sources(payload)
    city_names = load_city_names()

    with closing(sqlite3.connect(db_path)) as connection, connection:
        ensure_columns(connection)
        cursor = connection.cursor()

        source_lines_by_code: dict[tuple[str, str], list[SourceLine]] = defaultdict(list)
        for line in source_lines.values():
            source_lines_by_code[(line.city_id, line.line_code)].append(line)

        rows = cursor.execute(
            """
            SELECT
                station_key, city_id, city_name, line_key, sequence, station_name, normalized_station_name,
                match_status, match_quality, match_source, match_query,
                latitude, longitude, display_name, osm_type, osm_id, importance,
                osm_name, osm_name_zh, osm_name_en, osm_name_ja, osm_names_json, last_updated_at,
                source_code, source_type, source_line_name, source_station_name, source_tripreader_json
            FROM tunion_stations
            """
        ).fetchall()

        merged_rows = []
        matched_exact = 0
        filled_from_line = 0

        for row in rows:
            (
                station_key, city_id, city_name, line_key, sequence, station_name, normalized_station_name,
                match_status, match_quality, match_source, match_query,
                latitude, longitude, display_name, osm_type, osm_id, importance,
                osm_name, osm_name_zh, osm_name_en, osm_name_ja, osm_names_json, last_updated_at,
                source_code, source_type, source_line_name, source_station_name, source_tripreader_json,
            ) = row

            line_code = parse_line_context(line_key, city_id)
            line_source = choose_line_source(city_id, line_code, source_lines_by_code)
            exact_station = source_stations.get(station_key)

            if exact_station:
                matched_exact += 1

            if line_source:
                filled_from_line += 1

            merged_source_code = exact_station.code if exact_station else source_code
            merged_source_type = exact_station.station_type if exact_station else (line_source.station_type if line_source else source_type)
            merged_source_line_name = source_line_name or (exact_station.line_name if exact_station else (line_source.line_name if line_source else None))
            merged_source_station_name = exact_station.station_name if exact_station else (source_station_name or station_name)
            merged_source_json = {
                "station": exact_station.to_json() if exact_station else None,
                "line": line_source.to_json() if line_source else None,
            }
            if not exact_station and not line_source and source_tripreader_json:
                try:
                    merged_source_json = json.loads(source_tripreader_json)
                except Exception:
                    merged_source_json["legacy"] = source_tripreader_json

            merged_rows.append(
                {
                    "station_key": station_key,
                    "city_id": city_id,
                    "city_name": city_names.get(city_id, city_name),
                    "line_key": line_key,
                    "sequence": sequence,
                    "station_name": station_name,
                    "normalized_station_name": normalized_station_name,
                    "match_status": match_status,
                    "match_quality": match_quality,
                    "match_source": match_source,
                    "match_query": match_query,
                    "latitude": latitude,
                    "longitude": longitude,
                    "display_name": display_name,
                    "osm_type": osm_type,
                    "osm_id": osm_id,
                    "importance": importance,
                    "osm_name": osm_name,
                    "osm_name_zh": osm_name_zh,
                    "osm_name_en": osm_name_en,
                    "osm_name_ja": osm_name_ja,
                    "osm_names_json": osm_names_json,
                    "last_updated_at": last_updated_at,
                    "source_code": merged_source_code,
                    "source_type": merged_source_type,
                    "source_line_name": merged_source_line_name,
                    "source_station_name": merged_source_station_name,
                    "source_tripreader_json": json.dumps(merged_source_json, ensure_ascii=False, sort_keys=True),
                }
            )

        existing_keys = {row["station_key"] for row in merged_rows}
        geocoded_by_name = defaultdict(list)
        for row in merged_rows:
            if row["latitude"] is not None and row["longitude"] is not None:
                geocoded_by_name[(row["city_id"], row["station_name"], row["source_type"])].append(row)
        inserted = 0
        for station_key, source_station in source_stations.items():
            if station_key in existing_keys:
                continue
            line_source = choose_line_source(source_station.city_id, source_station.line_code, source_lines_by_code)
            merged_rows.append(
                {
                    "station_key": station_key,
                    "city_id": source_station.city_id,
                    "city_name": city_names.get(source_station.city_id, source_station.city_id),
                    "line_key": f"{source_station.city_id}{source_station.line_code}",
                    "sequence": int(source_station.code[len(source_station.line_code):], 16),
                    "station_name": source_station.station_name,
                    "normalized_station_name": source_station.station_name,
                    "match_status": "unmatched",
                    "match_quality": "none",
                    "match_source": None,
                    "match_query": None,
                    "latitude": None,
                    "longitude": None,
                    "display_name": None,
                    "osm_type": None,
                    "osm_id": None,
                    "importance": None,
                    "osm_name": None,
                    "osm_name_zh": None,
                    "osm_name_en": None,
                    "osm_name_ja": None,
                    "osm_names_json": None,
                    "last_updated_at": "source-only",
                    "source_code": source_station.code,
                    "source_type": source_station.station_type,
                    "source_line_name": source_station.line_name,
                    "source_station_name": source_station.station_name,
                    "source_tripreader_json": json.dumps(
                        {
                            "station": source_station.to_json(),
                            "line": line_source.to_json() if line_source else None,
                        },
                        ensure_ascii=False,
                        sort_keys=True,
                    ),
                }
            )
            candidates = geocoded_by_name.get(
                (source_station.city_id, source_station.station_name, source_station.station_type), []
            )
            identities = {(row["latitude"], row["longitude"], row["osm_type"], row["osm_id"]) for row in candidates}
            if len(identities) == 1:
                for column in (
                    "match_status", "match_quality", "match_source", "match_query",
                    "latitude", "longitude", "display_name", "osm_type", "osm_id", "importance",
                    "osm_name", "osm_name_zh", "osm_name_en", "osm_name_ja", "osm_names_json",
                ):
                    merged_rows[-1][column] = candidates[0][column]
            inserted += 1

        cursor.executemany(
            """
            INSERT INTO tunion_stations (
                station_key, city_id, city_name, line_key, sequence, station_name, normalized_station_name,
                match_status, match_quality, match_source, match_query,
                latitude, longitude, display_name, osm_type, osm_id, importance,
                osm_name, osm_name_zh, osm_name_en, osm_name_ja, osm_names_json, last_updated_at,
                source_code, source_type, source_line_name, source_station_name, source_tripreader_json
            ) VALUES (
                ?, ?, ?, ?, ?, ?, ?,
                ?, ?, ?, ?,
                ?, ?, ?, ?, ?, ?,
                ?, ?, ?, ?, ?, ?,
                ?, ?, ?, ?, ?
            )
            ON CONFLICT(station_key) DO UPDATE SET
                city_id = excluded.city_id,
                city_name = excluded.city_name,
                line_key = excluded.line_key,
                sequence = excluded.sequence,
                station_name = excluded.station_name,
                normalized_station_name = excluded.normalized_station_name,
                match_status = excluded.match_status,
                match_quality = excluded.match_quality,
                match_source = excluded.match_source,
                match_query = excluded.match_query,
                latitude = excluded.latitude,
                longitude = excluded.longitude,
                display_name = excluded.display_name,
                osm_type = excluded.osm_type,
                osm_id = excluded.osm_id,
                importance = excluded.importance,
                osm_name = excluded.osm_name,
                osm_name_zh = excluded.osm_name_zh,
                osm_name_en = excluded.osm_name_en,
                osm_name_ja = excluded.osm_name_ja,
                osm_names_json = excluded.osm_names_json,
                last_updated_at = excluded.last_updated_at,
                source_code = excluded.source_code,
                source_type = excluded.source_type,
                source_line_name = excluded.source_line_name,
                source_station_name = excluded.source_station_name,
                source_tripreader_json = excluded.source_tripreader_json
            """,
            [
                (
                    row["station_key"],
                    row["city_id"],
                    row["city_name"],
                    row["line_key"],
                    row["sequence"],
                    row["station_name"],
                    row["normalized_station_name"],
                    row["match_status"],
                    row["match_quality"],
                    row["match_source"],
                    row["match_query"],
                    row["latitude"],
                    row["longitude"],
                    row["display_name"],
                    row["osm_type"],
                    row["osm_id"],
                    row["importance"],
                    row["osm_name"],
                    row["osm_name_zh"],
                    row["osm_name_en"],
                    row["osm_name_ja"],
                    row["osm_names_json"],
                    row["last_updated_at"],
                    row["source_code"],
                    row["source_type"],
                    row["source_line_name"],
                    row["source_station_name"],
                    row["source_tripreader_json"],
                )
                for row in merged_rows
            ],
        )

        cursor.execute("DELETE FROM tunion_lines")
        cursor.executemany(
            """
            INSERT OR REPLACE INTO tunion_lines (
                city_id, line_code, line_name, station_type, source_count, source_city_folder, source_csv_file
            ) VALUES (?, ?, ?, ?, ?, ?, ?)
            """,
            [
                (
                    line.city_id,
                    line.line_code,
                    line.line_name,
                    line.station_type,
                    line.source_count,
                    line.city_folder,
                    line.csv_file,
                )
                for line in source_lines.values()
            ],
        )

        # Gate IDs remain separate from station prefixes. Link only an unambiguous
        # same-city name and mode; a bicycle dock must not inherit a metro stop.
        stations_by_name = defaultdict(list)
        stations_by_key = {row["station_key"]: row for row in merged_rows}
        for row in merged_rows:
            stations_by_name[(row["city_id"], row["station_name"], row["source_type"])].append(row["station_key"])
        cursor.execute("DELETE FROM tunion_terminal_stations")
        for key, terminal in sorted(payload.get("terminal_stations", {}).items()):
            record_kind, city_id, terminal_code = key.split(":")
            candidates = stations_by_name.get((city_id, terminal["station"], terminal["type"]), [])
            station_key = candidates[0] if len(candidates) == 1 else None
            station_name = terminal["station"]
            if terminal.get("station_key"):
                station_key = terminal["station_key"]
                canonical = stations_by_key.get(station_key)
                if canonical is None or canonical["city_id"] != city_id:
                    raise ValueError(f"Invalid reviewed terminal station alias: {key} -> {station_key}")
                station_name = canonical["station_name"]
            cursor.execute(
                "INSERT INTO tunion_terminal_stations VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
                (record_kind, city_id, terminal_code, station_name, terminal["line"],
                 terminal["type"], station_key, json.dumps(terminal, ensure_ascii=False, sort_keys=True)),
            )

        # CU terminal prefixes have their own namespace. Only a unique match on
        # city, station, transport mode AND line may reuse a TU station identity.
        cu_candidates = defaultdict(list)
        for row in merged_rows:
            cu_candidates[(row["city_id"], row["station_name"], row["source_type"],
                           row["source_line_name"])].append(row["station_key"])
        cursor.execute("DELETE FROM cityunion_terminal_prefixes")
        for prefix, station in sorted(payload.get("city_union_stations", {}).items()):
            candidates = cu_candidates.get(("2900", station["station"], station["type"], station["line"]), [])
            station_key = candidates[0] if len(candidates) == 1 else None
            cursor.execute("INSERT INTO cityunion_terminal_prefixes VALUES (?, ?, ?, ?, ?, ?, ?)", (
                prefix, station["city_id"], station["station"], station["line"], station["type"],
                station_key, json.dumps(station, ensure_ascii=False, sort_keys=True),
            ))

        connection.commit()
    source_cache_path.write_text(
        json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )

    # The decoder uses the prefix registry as well as the map's unified SQLite.
    # Publish every canonical station key, preserving existing display names.
    registry_path = db_path.parent / "TUnionLineStations.json"
    registry = json.loads(registry_path.read_text(encoding="utf-8")) if registry_path.exists() else {}
    for row in merged_rows:
        registry.setdefault(row["station_key"], row["station_name"])
    registry_path.write_text(json.dumps(registry, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8")

    print(
        json.dumps(
            {
                "source_station_rows": len(source_stations),
                "source_line_rows": len(source_lines),
                "terminal_station_rows": len(payload.get("terminal_stations", {})),
                "merged_rows": len(merged_rows),
                "updated_or_preserved": len(rows),
                "inserted_source_only": inserted,
                "exact_station_matches": matched_exact,
                "line_metadata_fills": filled_from_line,
                "db_path": str(db_path),
                "source_cache_path": str(source_cache_path),
            },
            ensure_ascii=False,
        )
    )


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Merge tripreader T-Union source metadata into tunion_stations SQLite.")
    parser.add_argument("--db", type=Path, default=DEFAULT_DB)
    parser.add_argument("--source-cache", type=Path, default=DEFAULT_SOURCE_CACHE)
    parser.add_argument("--offline", action="store_true", help="Use the existing source cache instead of fetching tripreader-data.")
    parser.add_argument("--source-directory", type=Path, help="Read a local checkout of the pinned Trip Reader CSV tree.")
    args = parser.parse_args()
    if args.offline and args.source_directory:
        parser.error("--offline and --source-directory are mutually exclusive")
    return args


def main() -> None:
    args = parse_args()
    merge_into_database(args.db, args.source_cache, offline=args.offline, source_directory=args.source_directory)


if __name__ == "__main__":
    main()
