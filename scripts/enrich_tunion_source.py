#!/usr/bin/env python3

import argparse
import csv
import json
import sqlite3
import urllib.request
from collections import defaultdict
from dataclasses import dataclass
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_DB = REPO_ROOT / "CardBal/Resources/tunion_stations.sqlite"
DEFAULT_SOURCE_CACHE = REPO_ROOT / "CardBal/Resources/tunion_tripreader_source.json"
DEFAULT_CITY_CODES = REPO_ROOT / "CardBal/Resources/TUnionCityCodes.json"
TRIPREADER_API_ROOT = "https://api.github.com/repos/domosekai/tripreader-data/contents"


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
        return self.code[:4]

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


def fetch_json(url: str) -> object:
    req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0", "Accept": "application/vnd.github+json"})
    with urllib.request.urlopen(req, timeout=30) as response:
        return json.loads(response.read().decode("utf-8"))


def fetch_text(url: str) -> str:
    req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0"})
    with urllib.request.urlopen(req, timeout=30) as response:
        return response.read().decode("utf-8-sig", errors="replace")


def load_tripreader_sources_from_cache(source_cache_path: Path) -> tuple[dict[str, SourceStation], dict[str, SourceLine]]:
    payload = json.loads(source_cache_path.read_text(encoding="utf-8"))
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


def load_tripreader_sources() -> tuple[dict[str, SourceStation], dict[str, SourceLine]]:
    top_level = fetch_json(TRIPREADER_API_ROOT)
    station_rows: dict[str, SourceStation] = {}
    line_rows: dict[str, SourceLine] = {}
    line_station_counts: dict[tuple[str, str, str, str], int] = defaultdict(int)
    line_meta: dict[tuple[str, str, str, str], tuple[str, str]] = {}

    for entry in top_level:
        if entry.get("type") != "dir":
            continue
        city_folder = entry["name"]
        try:
            city_entries = fetch_json(entry["url"])
        except Exception:
            continue

        for file_entry in city_entries:
            name = file_entry.get("name", "")
            if not name.endswith("-tu.csv"):
                continue
            csv_text = fetch_text(file_entry["download_url"])
            for row in csv.DictReader(csv_text.splitlines()):
                city_id = row["City"].strip()
                code = row["Code"].strip()
                station_type = row["Type"].strip()
                line_name = row["Line"].strip()
                station_name = row["Station"].strip()
                if not code:
                    continue

                key = (city_id, code[:4], line_name, station_type)
                line_station_counts[key] += 1
                line_meta[key] = (city_folder, name)

                if not station_name:
                    continue

                station = SourceStation(
                    city_id=city_id,
                    code=code,
                    station_type=station_type,
                    line_name=line_name,
                    station_name=station_name,
                    city_folder=city_folder,
                    csv_file=name,
                )
                station_rows[station.station_key] = station

    for (city_id, line_code, line_name, station_type), count in line_station_counts.items():
        city_folder, csv_file = line_meta[(city_id, line_code, line_name, station_type)]
        line = SourceLine(
            city_id=city_id,
            line_code=line_code,
            line_name=line_name,
            station_type=station_type,
            city_folder=city_folder,
            csv_file=csv_file,
            source_count=count,
        )
        line_rows[line.key] = line

    return station_rows, line_rows


def load_city_names() -> dict[str, str]:
    return json.loads(DEFAULT_CITY_CODES.read_text(encoding="utf-8"))


def ensure_columns(connection: sqlite3.Connection) -> None:
    cursor = connection.cursor()
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
    for candidate in candidates:
        if candidate.line_name and candidate.station_type:
            return candidate
    return candidates[0]


def merge_into_database(db_path: Path, source_cache_path: Path, offline: bool = False) -> None:
    if offline:
        source_stations, source_lines = load_tripreader_sources_from_cache(source_cache_path)
    else:
        source_stations, source_lines = load_tripreader_sources()
    city_names = load_city_names()

    source_cache_path.write_text(
        json.dumps(
            {
                "stations": {key: station.to_json() for key, station in source_stations.items()},
                "lines": {key: line.to_json() for key, line in source_lines.items()},
            },
            ensure_ascii=False,
            indent=2,
            sort_keys=True,
        ),
        encoding="utf-8",
    )

    connection = sqlite3.connect(db_path)
    ensure_columns(connection)
    cursor = connection.cursor()

    db_columns = [row[1] for row in cursor.execute("PRAGMA table_info(tunion_stations)")]
    has_source_fields = {"source_code", "source_type", "source_line_name", "source_station_name", "source_tripreader_json"}.issubset(db_columns)

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
        merged_source_line_name = exact_station.line_name if exact_station else (line_source.line_name if line_source else source_line_name)
        merged_source_station_name = exact_station.station_name if exact_station else (source_station_name or station_name)
        merged_source_json = {
            "station": exact_station.to_json() if exact_station else None,
            "line": line_source.to_json() if line_source else None,
        }
        if not exact_station and not line_source and source_tripreader_json:
            try:
                merged_source_json["legacy"] = json.loads(source_tripreader_json)
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
                "sequence": 0,
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
                "source_line_name": line_source.line_name if line_source else source_station.line_name,
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

    connection.commit()
    connection.close()

    print(
        json.dumps(
            {
                "source_station_rows": len(source_stations),
                "source_line_rows": len(source_lines),
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
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    merge_into_database(args.db, args.source_cache, offline=args.offline)


if __name__ == "__main__":
    main()
