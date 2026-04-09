#!/usr/bin/env python3

import json
import re
import sqlite3
import time
import urllib.parse
import urllib.request
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
DB_PATH = REPO_ROOT / "CardBal/Resources/tunion_stations.sqlite"
BBOX = (43.70, 44.05, 87.25, 87.85)


def normalize_name(value: str) -> str:
    text = value.strip().replace(" ", "").replace("　", "")
    text = re.sub(r"[（(][^)）]*[)）]", "", text)
    for suffix in ("地铁站", "轻轨站", "有轨电车站", "公交站", "车站", "站"):
        if text.endswith(suffix) and len(text) > len(suffix):
            text = text[: -len(suffix)]
            break
    return text


def extract_chinese_name(value: str | None) -> str | None:
    if not value:
        return None
    parts = re.findall(r"[\u3400-\u4dbf\u4e00-\u9fff·]+", value)
    return max(parts, key=len) if parts else None


def overpass(query: str) -> dict:
    data = urllib.parse.urlencode({"data": query}).encode("utf-8")
    endpoints = [
        "https://overpass-api.de/api/interpreter",
        "https://lz4.overpass-api.de/api/interpreter",
        "https://overpass.kumi.systems/api/interpreter",
    ]
    last_error: Exception | None = None
    for endpoint in endpoints:
        print(f"query endpoint={endpoint}")
        req = urllib.request.Request(endpoint, data=data, headers={"User-Agent": "CardBal/1.1"})
        try:
            with urllib.request.urlopen(req, timeout=90) as response:
                payload = json.loads(response.read().decode("utf-8"))
            print(f"query ok elements={len(payload.get('elements', []))}")
            return payload
        except Exception as error:
            last_error = error
            print(f"query fail endpoint={endpoint} error={error!r}")
            time.sleep(2)
    raise last_error if last_error else RuntimeError("Overpass query failed")


def chunked(values: list[str], size: int) -> list[list[str]]:
    return [values[i : i + size] for i in range(0, len(values), size)]


def in_bbox(lat: float, lon: float) -> bool:
    min_lat, max_lat, min_lon, max_lon = BBOX
    return min_lat <= lat <= max_lat and min_lon <= lon <= max_lon


def main() -> None:
    conn = sqlite3.connect(DB_PATH)
    cur = conn.cursor()
    rows = cur.execute(
        """
        SELECT station_key, station_name
        FROM tunion_stations
        WHERE city_name='乌鲁木齐市'
          AND (latitude IS NULL OR longitude IS NULL)
          AND (match_status IS NULL OR match_status='unmatched')
        ORDER BY line_key, sequence
        """
    ).fetchall()

    aliases = [normalize_name(station_name) for _, station_name in rows]
    alias_to_keys: dict[str, list[tuple[str, str]]] = {}
    for station_key, station_name in rows:
        alias_to_keys.setdefault(normalize_name(station_name), []).append((station_key, station_name))

    updated = 0
    for group in chunked(sorted(set(aliases)), 5):
        regex = "|".join(re.escape(alias) for alias in group)
        query = f"""
[out:json][timeout:60];
(
  nwr["name"~"{regex}"]({BBOX[0]},{BBOX[2]},{BBOX[1]},{BBOX[3]});
  nwr["name:zh"~"{regex}"]({BBOX[0]},{BBOX[2]},{BBOX[1]},{BBOX[3]});
);
out center tags;
"""
        print(f"chunk aliases={group}")
        payload = overpass(query)
        for element in payload.get("elements", []):
            tags = element.get("tags", {})
            display_name = tags.get("name:zh") or extract_chinese_name(tags.get("name")) or tags.get("name")
            if not display_name:
                continue
            matched_aliases = set()
            for raw in (tags.get("name"), tags.get("name:zh"), tags.get("name:en"), tags.get("name:ja"), display_name):
                if not raw:
                    continue
                raw_alias = normalize_name(raw)
                if raw_alias in alias_to_keys:
                    matched_aliases.add(raw_alias)
            if not matched_aliases:
                continue
            lat = element.get("lat") or element.get("center", {}).get("lat")
            lon = element.get("lon") or element.get("center", {}).get("lon")
            if lat is None or lon is None:
                continue
            lat = float(lat)
            lon = float(lon)
            if not in_bbox(lat, lon):
                continue
            osm_names = {key: value for key, value in tags.items() if key == "name" or key.startswith("name:")}
            if "name:zh" not in osm_names:
                derived = extract_chinese_name(tags.get("name"))
                if derived:
                    osm_names["name:zh"] = derived
            for alias in matched_aliases:
                for station_key, station_name in alias_to_keys[alias]:
                    cur.execute(
                        """
                        UPDATE tunion_stations
                        SET match_status = 'matched',
                            match_quality = 'partial',
                            match_source = ?,
                            match_query = 'overpass-urumqi-polyglot',
                            latitude = ?,
                            longitude = ?,
                            display_name = ?,
                            osm_type = ?,
                            osm_id = ?,
                            importance = 4.0,
                            osm_name = ?,
                            osm_name_zh = ?,
                            osm_name_en = ?,
                            osm_name_ja = ?,
                            osm_names_json = ?,
                            last_updated_at = datetime('now')
                        WHERE station_key = ?
                        """,
                        (
                            f"overpass-urumqi-polyglot:{alias}",
                            float(lat),
                            float(lon),
                            display_name,
                            element.get("type", ""),
                            str(element.get("id", "")),
                            tags.get("name"),
                            tags.get("name:zh") or extract_chinese_name(tags.get("name")) or display_name,
                            tags.get("name:en"),
                            tags.get("name:ja"),
                            json.dumps(osm_names, ensure_ascii=False, sort_keys=True),
                            station_key,
                        ),
                    )
                    updated += 1
                    print(
                        f"matched station_key={station_key} station={station_name} -> "
                        f"{display_name} ({element.get('type')} {element.get('id')}) {float(lat):.6f},{float(lon):.6f}"
                    )

        conn.commit()

    conn.close()
    print(f"updated={updated}")


if __name__ == "__main__":
    main()
