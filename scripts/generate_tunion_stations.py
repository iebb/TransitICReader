#!/usr/bin/env python3

import argparse
import datetime as dt
import json
import sqlite3
import time
import urllib.parse
import urllib.request
from collections import defaultdict
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_STATIONS_JSON = REPO_ROOT / "CardBal/Resources/TUnionLineStations.json"
DEFAULT_CITIES_JSON = REPO_ROOT / "CardBal/Resources/TUnionCityCodes.json"
DEFAULT_CITY_CACHE_JSON = REPO_ROOT / "CardBal/Resources/tunion_osm_city_cache.json"
DEFAULT_BUS_CACHE_JSON = REPO_ROOT / "CardBal/Resources/tunion_osm_bus_city_cache.json"
DEFAULT_OUTPUT_DB = REPO_ROOT / "CardBal/Resources/tunion_stations.sqlite"
FILTER_SIGNATURE = "node|way:railway=station|station=subway"
BUS_FILTER_SIGNATURE = "node|way:bus_stop|bus_station|public_transport=platform|stop_position"


def station_sequence_length(station_key: str) -> int:
    return 4 if len(station_key) == 12 else 2


def parse_station_key(station_key: str) -> tuple[str, str, int]:
    sequence_length = station_sequence_length(station_key)
    return station_key[:4], station_key[:-sequence_length], int(station_key[-sequence_length:], 16)


def load_json(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def save_json(path: Path, value: dict) -> None:
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True), encoding="utf-8")


def normalize_station_name(value: str) -> str:
    normalized = value.strip().replace(" ", "").replace("　", "")
    for suffix in ("地铁站", "轻轨站", "有轨电车站", "公交站", "车站", "站"):
        if normalized.endswith(suffix) and len(normalized) > len(suffix):
            normalized = normalized[: -len(suffix)]
            break
    return normalized


def overpass_query(query: str, delay_seconds: float) -> dict:
    data = urllib.parse.urlencode({"data": query}).encode("utf-8")
    headers = {
        "User-Agent": "CardBal/1.1 (https://github.com/Seo-4d696b75/station_database; contact via repo)",
        "Content-Type": "application/x-www-form-urlencoded; charset=utf-8",
    }
    last_error: Exception | None = None
    for attempt in range(5):
        request = urllib.request.Request("https://overpass-api.de/api/interpreter", data=data, headers=headers)
        try:
            with urllib.request.urlopen(request, timeout=180) as response:
                payload = json.loads(response.read().decode("utf-8"))
            time.sleep(delay_seconds)
            return payload
        except Exception as error:
            last_error = error
            time.sleep(max(delay_seconds, 1.0) * (attempt + 1) * 3)
    raise last_error if last_error else RuntimeError("Overpass query failed")


def candidate_importance(tags: dict) -> float:
    if tags.get("railway") == "station":
        return 5.0
    if tags.get("station") == "subway":
        return 4.0
    return 0.5


def fetch_city_osm_candidates(city_name: str, delay_seconds: float) -> dict[str, dict]:
    query = f"""
[out:json][timeout:180];
area["boundary"="administrative"]["name"="{city_name}"]->.searchArea;
(
  node(area.searchArea)["name"]["railway"="station"];
  node(area.searchArea)["name"]["station"="subway"];
  way(area.searchArea)["name"]["railway"="station"];
  way(area.searchArea)["name"]["station"="subway"];
);
out center tags;
"""
    payload = overpass_query(query=query, delay_seconds=delay_seconds)
    candidates: dict[str, dict] = {}
    for element in payload.get("elements", []):
        tags = element.get("tags", {})
        display_name = tags.get("name:zh") or tags.get("name")
        if not display_name:
            continue
        latitude = element.get("lat") or element.get("center", {}).get("lat")
        longitude = element.get("lon") or element.get("center", {}).get("lon")
        if latitude is None or longitude is None:
            continue
        candidate = {
            "query": f"overpass:{city_name}",
            "lat": float(latitude),
            "lon": float(longitude),
            "display_name": display_name,
            "osm_type": element.get("type", ""),
            "osm_id": str(element.get("id", "")),
            "importance": candidate_importance(tags),
            "osm_name": tags.get("name"),
            "osm_name_zh": tags.get("name:zh"),
            "osm_name_en": tags.get("name:en"),
            "osm_name_ja": tags.get("name:ja"),
            "osm_names_json": json.dumps({key: value for key, value in tags.items() if key == "name" or key.startswith("name:")}, ensure_ascii=False, sort_keys=True),
        }
        normalized = normalize_station_name(display_name)
        existing = candidates.get(normalized)
        if existing is None or candidate["importance"] > existing["importance"]:
            candidates[normalized] = candidate
    return candidates


def fetch_city_bus_candidates(city_name: str, delay_seconds: float) -> dict[str, dict]:
    query = f"""
[out:json][timeout:180];
area["boundary"="administrative"]["name"="{city_name}"]->.searchArea;
(
  node(area.searchArea)["name"]["highway"="bus_stop"];
  node(area.searchArea)["name"]["amenity"="bus_station"];
  node(area.searchArea)["name"]["public_transport"="platform"];
  node(area.searchArea)["name"]["public_transport"="stop_position"];
  way(area.searchArea)["name"]["highway"="bus_stop"];
  way(area.searchArea)["name"]["amenity"="bus_station"];
  way(area.searchArea)["name"]["public_transport"="platform"];
  way(area.searchArea)["name"]["public_transport"="stop_position"];
);
out center tags;
"""
    payload = overpass_query(query=query, delay_seconds=delay_seconds)
    candidates: dict[str, dict] = {}
    for element in payload.get("elements", []):
        tags = element.get("tags", {})
        display_name = tags.get("name:zh") or tags.get("name")
        if not display_name:
            continue
        latitude = element.get("lat") or element.get("center", {}).get("lat")
        longitude = element.get("lon") or element.get("center", {}).get("lon")
        if latitude is None or longitude is None:
            continue
        candidate = {
            "query": f"overpass-bus:{city_name}",
            "lat": float(latitude),
            "lon": float(longitude),
            "display_name": display_name,
            "osm_type": element.get("type", ""),
            "osm_id": str(element.get("id", "")),
            "importance": candidate_importance(tags),
            "osm_name": tags.get("name"),
            "osm_name_zh": tags.get("name:zh"),
            "osm_name_en": tags.get("name:en"),
            "osm_name_ja": tags.get("name:ja"),
            "osm_names_json": json.dumps({key: value for key, value in tags.items() if key == "name" or key.startswith("name:")}, ensure_ascii=False, sort_keys=True),
        }
        normalized = normalize_station_name(display_name)
        existing = candidates.get(normalized)
        if existing is None or candidate["importance"] > existing["importance"]:
            candidates[normalized] = candidate
    return candidates


def ensure_database(path: Path) -> sqlite3.Connection:
    path.parent.mkdir(parents=True, exist_ok=True)
    connection = sqlite3.connect(path)
    cursor = connection.cursor()
    cursor.executescript(
        """
        CREATE TABLE IF NOT EXISTS tunion_stations (
            station_key TEXT PRIMARY KEY,
            city_id TEXT NOT NULL,
            city_name TEXT NOT NULL,
            line_key TEXT NOT NULL,
            sequence INTEGER NOT NULL,
            station_name TEXT NOT NULL,
            normalized_station_name TEXT NOT NULL,
            match_status TEXT NOT NULL,
            match_quality TEXT NOT NULL,
            match_source TEXT,
            match_query TEXT,
            latitude REAL,
            longitude REAL,
            display_name TEXT,
            osm_type TEXT,
            osm_id TEXT,
            importance REAL,
            osm_name TEXT,
            osm_name_zh TEXT,
            osm_name_en TEXT,
            osm_name_ja TEXT,
            osm_names_json TEXT,
            last_updated_at TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_tunion_station_name ON tunion_stations (station_name);
        CREATE INDEX IF NOT EXISTS idx_tunion_line_key ON tunion_stations (line_key);
        CREATE INDEX IF NOT EXISTS idx_tunion_match_status ON tunion_stations (match_status, match_quality);
        CREATE TABLE IF NOT EXISTS station_edges (
            line_code TEXT NOT NULL,
            from_station_code TEXT NOT NULL,
            to_station_code TEXT NOT NULL,
            distance_km REAL NOT NULL,
            PRIMARY KEY (line_code, from_station_code, to_station_code)
        );
        CREATE INDEX IF NOT EXISTS idx_tunion_edges_from ON station_edges (from_station_code);
        CREATE INDEX IF NOT EXISTS idx_tunion_edges_to ON station_edges (to_station_code);
        """
    )
    connection.commit()
    return connection


def load_confirmed_matches(connection: sqlite3.Connection) -> dict[str, dict]:
    cursor = connection.cursor()
    results = {}
    for row in cursor.execute(
        """
        SELECT
            station_key, city_id, city_name, line_key, sequence, station_name, normalized_station_name,
            match_status, match_quality, match_source, match_query,
            latitude, longitude, display_name, osm_type, osm_id, importance,
            osm_name, osm_name_zh, osm_name_en, osm_name_ja, osm_names_json
        FROM tunion_stations
        WHERE match_status = 'matched' AND match_quality = 'good' AND latitude IS NOT NULL AND longitude IS NOT NULL
        """
    ):
        results[row[0]] = {
            "station_key": row[0],
            "city_id": row[1],
            "city_name": row[2],
            "line_key": row[3],
            "sequence": row[4],
            "station_name": row[5],
            "normalized_station_name": row[6],
            "match_status": row[7],
            "match_quality": row[8],
            "match_source": row[9],
            "match_query": row[10],
            "latitude": row[11],
            "longitude": row[12],
            "display_name": row[13],
            "osm_type": row[14],
            "osm_id": row[15],
            "importance": row[16],
            "osm_name": row[17],
            "osm_name_zh": row[18],
            "osm_name_en": row[19],
            "osm_name_ja": row[20],
            "osm_names_json": row[21],
        }
    return results


def upsert_station_rows(connection: sqlite3.Connection, rows: list[dict]) -> None:
    cursor = connection.cursor()
    cursor.executemany(
        """
        INSERT INTO tunion_stations (
            station_key, city_id, city_name, line_key, sequence, station_name, normalized_station_name,
            match_status, match_quality, match_source, match_query,
            latitude, longitude, display_name, osm_type, osm_id, importance,
            osm_name, osm_name_zh, osm_name_en, osm_name_ja, osm_names_json, last_updated_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
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
            last_updated_at = excluded.last_updated_at
        """
        ,
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
            )
            for row in rows
        ],
    )
    connection.commit()


def build_station_rows(
    connection: sqlite3.Connection,
    stations: dict[str, str],
    cities: dict[str, str],
    city_cache: dict,
    bus_city_cache: dict,
    delay_seconds: float,
    city_cache_path: Path,
    bus_cache_path: Path,
) -> list[dict]:
    confirmed = load_confirmed_matches(connection)
    print(f"loaded_confirmed_matches={len(confirmed)}")

    city_names = sorted({cities.get(station_key[:4], station_key[:4]) for station_key in stations})
    city_matches: dict[str, dict[str, dict]] = {}
    bus_city_matches: dict[str, dict[str, dict]] = {}
    for index, city_name in enumerate(city_names, start=1):
        cache_key = f"{FILTER_SIGNATURE}|{city_name}"
        cached = city_cache.get(cache_key)
        if isinstance(cached, dict):
            city_matches[city_name] = cached
            print(f"city_cache_hit city={city_name} index={index}/{len(city_names)} candidates={len(cached)}")
            continue
        try:
            matches = fetch_city_osm_candidates(city_name=city_name, delay_seconds=delay_seconds)
            city_matches[city_name] = matches
            city_cache[cache_key] = matches
            save_json(city_cache_path, city_cache)
            print(f"city_fetch_ok city={city_name} index={index}/{len(city_names)} candidates={len(matches)}")
        except Exception as error:
            city_matches[city_name] = {}
            print(f"city_fetch_failed city={city_name} index={index}/{len(city_names)} error={error}")

    bus_city_names = sorted({cities.get(station_key[:4], station_key[:4]) for station_key, station_name in stations.items() if "公交" in station_name})
    for index, city_name in enumerate(bus_city_names, start=1):
        cache_key = f"{BUS_FILTER_SIGNATURE}|{city_name}"
        cached = bus_city_cache.get(cache_key)
        if isinstance(cached, dict):
            bus_city_matches[city_name] = cached
            print(f"bus_city_cache_hit city={city_name} index={index}/{len(bus_city_names)} candidates={len(cached)}")
            continue
        try:
            matches = fetch_city_bus_candidates(city_name=city_name, delay_seconds=delay_seconds)
            bus_city_matches[city_name] = matches
            bus_city_cache[cache_key] = matches
            save_json(bus_cache_path, bus_city_cache)
            print(f"bus_city_fetch_ok city={city_name} index={index}/{len(bus_city_names)} candidates={len(matches)}")
        except Exception as error:
            bus_city_matches[city_name] = {}
            print(f"bus_city_fetch_failed city={city_name} index={index}/{len(bus_city_names)} error={error}")

    timestamp = dt.datetime.now(dt.timezone.utc).isoformat()
    rows: list[dict] = []
    matched_now = 0
    skipped_confirmed = 0
    unmatched = 0
    per_city = defaultdict(lambda: {"matched": 0, "unmatched": 0, "skipped": 0})

    for station_key, station_name in sorted(stations.items()):
        city_id, line_key, sequence = parse_station_key(station_key)
        city_name = cities.get(city_id, city_id)
        normalized = normalize_station_name(station_name)

        if station_key in confirmed:
            row = dict(confirmed[station_key])
            row["last_updated_at"] = timestamp
            rows.append(row)
            skipped_confirmed += 1
            per_city[city_name]["skipped"] += 1
            print(
                f"station_skip_confirmed station_key={station_key} city={city_name} station={station_name} "
                f"lat={row['latitude']:.6f} lon={row['longitude']:.6f} osm_type={row['osm_type']} osm_id={row['osm_id']}"
            )
            continue

        geocode = city_matches.get(city_name, {}).get(normalized)
        if geocode is None and "公交" in station_name:
            geocode = bus_city_matches.get(city_name, {}).get(normalized)
        osm_name = geocode.get("osm_name") if geocode else None
        osm_name_zh = geocode.get("osm_name_zh") if geocode else None
        osm_name_en = geocode.get("osm_name_en") if geocode else None
        osm_name_ja = geocode.get("osm_name_ja") if geocode else None
        osm_names_json = geocode.get("osm_names_json") if geocode else None
        row = {
            "station_key": station_key,
            "city_id": city_id,
            "city_name": city_name,
            "line_key": line_key,
            "sequence": sequence,
            "station_name": station_name,
            "normalized_station_name": normalized,
            "match_status": "matched" if geocode else "unmatched",
            "match_quality": "good" if geocode else "none",
            "match_source": FILTER_SIGNATURE if geocode else None,
            "match_query": geocode["query"] if geocode else None,
            "latitude": geocode["lat"] if geocode else None,
            "longitude": geocode["lon"] if geocode else None,
            "display_name": geocode["display_name"] if geocode else None,
            "osm_type": geocode["osm_type"] if geocode else None,
            "osm_id": geocode["osm_id"] if geocode else None,
            "importance": geocode["importance"] if geocode else None,
            "osm_name": osm_name,
            "osm_name_zh": osm_name_zh,
            "osm_name_en": osm_name_en,
            "osm_name_ja": osm_name_ja,
            "osm_names_json": osm_names_json,
            "last_updated_at": timestamp,
        }
        rows.append(row)

        if geocode:
            matched_now += 1
            per_city[city_name]["matched"] += 1
            print(
                f"station_matched station_key={station_key} city={city_name} station={station_name} normalized={normalized} "
                f"display_name={geocode.get('display_name') or ''} osm_type={geocode.get('osm_type') or ''} osm_id={geocode.get('osm_id') or ''} "
                f"lat={geocode['lat']:.6f} lon={geocode['lon']:.6f} "
                f"name_en={osm_name_en or ''} name_ja={osm_name_ja or ''}"
            )
        else:
            unmatched += 1
            per_city[city_name]["unmatched"] += 1
            print(f"station_unmatched station_key={station_key} city={city_name} station={station_name} normalized={normalized}")

    for city_name in sorted(per_city):
        stats = per_city[city_name]
        print(
            f"city_summary city={city_name} matched={stats['matched']} "
            f"unmatched={stats['unmatched']} skipped_confirmed={stats['skipped']}"
        )
    print(
        f"overall_summary matched_now={matched_now} skipped_confirmed={skipped_confirmed} "
        f"unmatched={unmatched} total={len(rows)}"
    )
    return rows


def build_edges(rows: list[dict]) -> list[dict]:
    grouped: dict[str, list[dict]] = defaultdict(list)
    for row in rows:
        grouped[row["line_key"]].append(row)

    edges = []
    for line_key, stations in grouped.items():
        ordered = sorted(stations, key=lambda item: item["sequence"])
        for left, right in zip(ordered, ordered[1:]):
            if left["latitude"] is None or right["latitude"] is None:
                continue
            distance_km = (((left["latitude"] - right["latitude"]) ** 2 + (left["longitude"] - right["longitude"]) ** 2) ** 0.5) * 111
            edges.append(
                {
                    "line_key": line_key,
                    "from_station_code": left["station_key"],
                    "to_station_code": right["station_key"],
                    "distance_km": round(distance_km, 3),
                }
            )
    return edges


def write_edges(connection: sqlite3.Connection, edges: list[dict]) -> None:
    cursor = connection.cursor()
    cursor.execute("DELETE FROM station_edges")
    cursor.executemany(
        "INSERT OR REPLACE INTO station_edges (line_code, from_station_code, to_station_code, distance_km) VALUES (?, ?, ?, ?)",
        [(edge["line_key"], edge["from_station_code"], edge["to_station_code"], edge["distance_km"]) for edge in edges],
    )
    connection.commit()


def main() -> None:
    parser = argparse.ArgumentParser(description="Generate tunion_stations SQLite using strict OpenStreetMap station matches.")
    parser.add_argument("--stations-json", type=Path, default=DEFAULT_STATIONS_JSON)
    parser.add_argument("--cities-json", type=Path, default=DEFAULT_CITIES_JSON)
    parser.add_argument("--city-cache-json", type=Path, default=DEFAULT_CITY_CACHE_JSON)
    parser.add_argument("--bus-cache-json", type=Path, default=DEFAULT_BUS_CACHE_JSON)
    parser.add_argument("--output-db", type=Path, default=DEFAULT_OUTPUT_DB)
    parser.add_argument("--delay-seconds", type=float, default=3.0, help="Delay between remote OpenStreetMap requests.")
    args = parser.parse_args()

    stations = load_json(args.stations_json)
    cities = load_json(args.cities_json)
    city_cache = load_json(args.city_cache_json) if args.city_cache_json.exists() else {}
    bus_city_cache = load_json(args.bus_cache_json) if args.bus_cache_json.exists() else {}

    connection = ensure_database(args.output_db)
    rows = build_station_rows(
        connection=connection,
        stations=stations,
        cities=cities,
        city_cache=city_cache,
        bus_city_cache=bus_city_cache,
        delay_seconds=args.delay_seconds,
        city_cache_path=args.city_cache_json,
        bus_cache_path=args.bus_cache_json,
    )
    upsert_station_rows(connection, rows)
    save_json(args.city_cache_json, city_cache)
    save_json(args.bus_cache_json, bus_city_cache)

    edges = build_edges(rows)
    write_edges(connection, edges)

    print(
        json.dumps(
            {
                "station_count": len(rows),
                "geocoded_count": sum(1 for row in rows if row["latitude"] is not None and row["longitude"] is not None),
                "edge_count": len(edges),
                "output_db": str(args.output_db),
                "city_cache_json": str(args.city_cache_json),
                "bus_cache_json": str(args.bus_cache_json),
                "filter_signature": FILTER_SIGNATURE,
            },
            ensure_ascii=False,
        )
    )
    connection.close()


if __name__ == "__main__":
    main()
