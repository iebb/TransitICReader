#!/usr/bin/env python3

import json
import re
import sqlite3
import time
import urllib.parse
import urllib.request
from collections import defaultdict
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_DB = REPO_ROOT / "CardBal/Resources/tunion_stations.sqlite"
DEFAULT_TRAIN_CACHE = REPO_ROOT / "CardBal/Resources/tunion_osm_city_cache.json"
DEFAULT_BUS_CACHE = REPO_ROOT / "CardBal/Resources/tunion_osm_bus_city_cache.json"
NOMINATIM_ENDPOINT = "https://nominatim.openstreetmap.org/search"

_CITY_VIEWBOX_CACHE: dict[str, str] = {}


def load_json(path: Path) -> dict:
    if not path.exists():
        return {}
    return json.loads(path.read_text(encoding="utf-8"))


def save_json(path: Path, value: dict) -> None:
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True), encoding="utf-8")


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
    if not parts:
        return None
    return max(parts, key=len)


def station_aliases(value: str) -> list[str]:
    pieces = re.split(r"[/／|、]", value)
    aliases = []
    for piece in pieces:
        cleaned = normalize_name(piece)
        if cleaned:
            aliases.append(cleaned)
    cleaned = normalize_name(value)
    if cleaned and cleaned not in aliases:
        aliases.insert(0, cleaned)
    return list(dict.fromkeys(aliases))


def candidate_name_fields(candidate: dict) -> list[str]:
    values = []
    for key in ("display_name", "osm_name", "osm_name_zh", "osm_name_en", "osm_name_ja"):
        value = candidate.get(key)
        if isinstance(value, str) and value:
            values.append(value)
    return values


def rehydrate_cached_candidates(cached: dict) -> dict[str, dict]:
    expanded = dict(cached)
    updated = False
    for alias, candidate in list(cached.items()):
        if not isinstance(candidate, dict):
            continue
        aliases = set()
        for value in candidate_name_fields(candidate):
            aliases.update(station_aliases(value))
            zh = extract_chinese_name(value)
            if zh:
                aliases.update(station_aliases(zh))
        if candidate.get("osm_name_zh"):
            aliases.update(station_aliases(candidate["osm_name_zh"]))
        for new_alias in aliases:
            if new_alias not in expanded:
                expanded[new_alias] = candidate
                updated = True
    return expanded if updated else cached


def partial_candidate_match(aliases: list[str], candidates: dict[str, dict]) -> dict | None:
    for alias in aliases:
        if len(alias) < 4:
            continue
        for candidate in candidates.values():
            for field in candidate_name_fields(candidate):
                if not field or len(field) < len(alias):
                    continue
                if alias in field:
                    return candidate
    return None


def fetch_station_fallback(city_name: str, station_name: str, kind: str, delay_seconds: float) -> dict[str, dict]:
    aliases = station_aliases(station_name)
    if not aliases:
        return {}
    if kind == "train":
        nominatim_candidates = fetch_nominatim_station_fallback(city_name, station_name, delay_seconds)
        if nominatim_candidates:
            print(f"station_fetch_ok city={city_name} station={station_name} candidates={len(nominatim_candidates)} source=nominatim")
            return nominatim_candidates
    regex = "^" + "|".join(re.escape(alias) for alias in aliases[:3]) + "$"
    print(f"station_fetch_start city={city_name} station={station_name} kind={kind} mode=global")
    if kind == "bus":
        query = f"""
[out:json][timeout:45];
(
  nwr["name"~"{regex}"];
  nwr["name:zh"~"{regex}"];
);
out center tags;
"""
    else:
        query = f"""
[out:json][timeout:45];
(
  nwr["name"~"{regex}"]["railway"~"station|stop|tram_stop|tram|halt"];
  nwr["name"~"{regex}"]["station"="subway"];
  nwr["name"~"{regex}"]["subway"="yes"];
  nwr["name"~"{regex}"]["tram"="yes"];
  nwr["name"~"{regex}"]["public_transport"~"stop_position|platform"];
  nwr["name:zh"~"{regex}"]["railway"~"station|stop|tram_stop|tram|halt"];
  nwr["name:zh"~"{regex}"]["station"="subway"];
  nwr["name:zh"~"{regex}"]["subway"="yes"];
  nwr["name:zh"~"{regex}"]["tram"="yes"];
  nwr["name:zh"~"{regex}"]["public_transport"~"stop_position|platform"];
);
out center tags;
"""
    try:
        payload = overpass_query(query, delay_seconds=delay_seconds)
    except Exception:
        print(f"station_fetch_retry city={city_name} station={station_name} kind={kind} mode=city")
        regex = "|".join(re.escape(alias) for alias in aliases[:3])
        if kind == "bus":
            query = f"""
[out:json][timeout:45];
area["boundary"="administrative"]["name"="{city_name}"]->.searchArea;
(
  nwr(area.searchArea)["name"~"^{regex}$"];
  nwr(area.searchArea)["name:zh"~"^{regex}$"];
);
out center tags;
"""
        else:
            query = f"""
[out:json][timeout:45];
area["boundary"="administrative"]["name"="{city_name}"]->.searchArea;
(
  nwr(area.searchArea)["name"~"^{regex}$"]["railway"~"station|stop|tram_stop|tram|halt"];
  nwr(area.searchArea)["name"~"^{regex}$"]["station"="subway"];
  nwr(area.searchArea)["name"~"^{regex}$"]["subway"="yes"];
  nwr(area.searchArea)["name"~"^{regex}$"]["tram"="yes"];
  nwr(area.searchArea)["name"~"^{regex}$"]["public_transport"~"stop_position|platform"];
  nwr(area.searchArea)["name:zh"~"^{regex}$"]["railway"~"station|stop|tram_stop|tram|halt"];
  nwr(area.searchArea)["name:zh"~"^{regex}$"]["station"="subway"];
  nwr(area.searchArea)["name:zh"~"^{regex}$"]["subway"="yes"];
  nwr(area.searchArea)["name:zh"~"^{regex}$"]["tram"="yes"];
  nwr(area.searchArea)["name:zh"~"^{regex}$"]["public_transport"~"stop_position|platform"];
);
out center tags;
"""
        payload = overpass_query(query, delay_seconds=delay_seconds)
    candidates: dict[str, dict] = {}
    for element in payload.get("elements", []):
        tags = element.get("tags", {})
        display_name = tags.get("name:zh") or extract_chinese_name(tags.get("name")) or tags.get("name")
        if not display_name:
            continue
        lat = element.get("lat") or element.get("center", {}).get("lat")
        lon = element.get("lon") or element.get("center", {}).get("lon")
        if lat is None or lon is None:
            continue
        candidate = {
            "query": f"overpass-station:{kind}:{city_name}",
            "lat": float(lat),
            "lon": float(lon),
            "display_name": display_name,
            "osm_type": element.get("type", ""),
            "osm_id": str(element.get("id", "")),
            "importance": 5.0 if tags.get("railway") in {"station", "stop", "tram_stop", "tram", "halt"} else 4.0,
            "osm_name": tags.get("name"),
            "osm_name_zh": tags.get("name:zh") or extract_chinese_name(tags.get("name")),
            "osm_name_en": tags.get("name:en"),
            "osm_name_ja": tags.get("name:ja"),
            "osm_names_json": json.dumps(
                {key: value for key, value in tags.items() if key == "name" or key.startswith("name:")},
                ensure_ascii=False,
                sort_keys=True,
            ),
        }
        for alias in station_aliases(display_name):
            existing = candidates.get(alias)
            if existing is None or candidate["importance"] > existing["importance"]:
                candidates[alias] = candidate
    print(f"station_fetch_ok city={city_name} station={station_name} candidates={len(candidates)}")
    return candidates


def nominatim_city_viewbox(city_name: str) -> str | None:
    cached = _CITY_VIEWBOX_CACHE.get(city_name)
    if cached:
        return cached
    query = city_name
    url = NOMINATIM_ENDPOINT + "?" + urllib.parse.urlencode(
        {
            "q": query,
            "format": "jsonv2",
            "limit": 1,
            "namedetails": 1,
            "addressdetails": 1,
            "countrycodes": "cn",
        }
    )
    request = urllib.request.Request(url, headers={"User-Agent": "CardBal/1.1 (Nominatim fallback)"})
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            payload = json.loads(response.read().decode("utf-8"))
    except Exception as error:
        print(f"nominatim_city_fail city={city_name} error={error!r}")
        return None
    if not payload:
        print(f"nominatim_city_empty city={city_name}")
        return None
    bbox = payload[0].get("boundingbox")
    if not bbox or len(bbox) != 4:
        print(f"nominatim_city_nobbox city={city_name}")
        return None
    south, north, west, east = bbox[0], bbox[1], bbox[2], bbox[3]
    viewbox = f"{west},{north},{east},{south}"
    _CITY_VIEWBOX_CACHE[city_name] = viewbox
    return viewbox


def fetch_nominatim_station_fallback(city_name: str, station_name: str, delay_seconds: float) -> dict[str, dict]:
    aliases = station_aliases(station_name)
    if not aliases:
        return {}
    viewbox = nominatim_city_viewbox(city_name)
    if not viewbox:
        return {}
    acceptable_types = {"tram_stop", "station", "stop", "stop_position", "platform"}
    candidates: dict[str, dict] = {}
    for alias in aliases[:3]:
        url = NOMINATIM_ENDPOINT + "?" + urllib.parse.urlencode(
            {
                "q": alias,
                "format": "jsonv2",
                "limit": 10,
                "namedetails": 1,
                "addressdetails": 1,
                "countrycodes": "cn",
                "viewbox": viewbox,
                "bounded": 1,
            }
        )
        print(f"nominatim_try city={city_name} station={station_name} alias={alias}")
        request = urllib.request.Request(url, headers={"User-Agent": "CardBal/1.1 (Nominatim fallback)"})
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                payload = json.loads(response.read().decode("utf-8"))
        except Exception as error:
            print(f"nominatim_fail city={city_name} station={station_name} alias={alias} error={error!r}")
            continue
        time.sleep(delay_seconds)
        for element in payload:
            category = element.get("category")
            osm_type = element.get("osm_type", "")
            osm_id = str(element.get("osm_id", ""))
            station_type = element.get("type", "")
            if category not in {"railway", "public_transport"}:
                continue
            if station_type not in acceptable_types:
                continue
            lat = element.get("lat")
            lon = element.get("lon")
            if lat is None or lon is None:
                continue
            tags = {
                "name": element.get("name"),
            }
            namedetails = element.get("namedetails", {})
            for key, value in namedetails.items():
                if key.startswith("name") and value:
                    tags[key] = value
            osm_name = tags.get("name")
            osm_name_zh = tags.get("name:zh") or extract_chinese_name(osm_name)
            display_name = element.get("name") or element.get("display_name") or station_name
            candidate = {
                "query": f"nominatim:{city_name}",
                "lat": float(lat),
                "lon": float(lon),
                "display_name": display_name,
                "osm_type": osm_type,
                "osm_id": osm_id,
                "importance": float(element.get("importance") or 0.0) + (1.0 if category == "railway" else 0.5),
                "osm_name": osm_name,
                "osm_name_zh": osm_name_zh,
                "osm_name_en": tags.get("name:en"),
                "osm_name_ja": tags.get("name:ja"),
                "osm_names_json": json.dumps(tags, ensure_ascii=False, sort_keys=True),
            }
            for candidate_alias in station_aliases(display_name):
                existing = candidates.get(candidate_alias)
                if existing is None or candidate["importance"] > existing.get("importance", 0):
                    candidates[candidate_alias] = candidate
        if candidates:
            print(f"nominatim_ok city={city_name} station={station_name} alias={alias} candidates={len(candidates)}")
            return candidates
    print(f"nominatim_miss city={city_name} station={station_name}")
    return {}


def overpass_query(query: str, delay_seconds: float) -> dict:
    data = urllib.parse.urlencode({"data": query}).encode("utf-8")
    headers = {
        "User-Agent": "CardBal/1.1 (https://github.com/Seo-4d696b75/station_database; contact via repo)",
        "Content-Type": "application/x-www-form-urlencoded; charset=utf-8",
    }
    endpoints = [
        "https://overpass-api.de/api/interpreter",
        "https://lz4.overpass-api.de/api/interpreter",
        "https://overpass.kumi.systems/api/interpreter",
    ]
    last_error: Exception | None = None
    for attempt in range(5):
        endpoint = endpoints[attempt % len(endpoints)]
        request = urllib.request.Request(endpoint, data=data, headers=headers)
        print(f"overpass_try attempt={attempt + 1} endpoint={endpoint}")
        try:
            with urllib.request.urlopen(request, timeout=45) as response:
                payload = json.loads(response.read().decode("utf-8"))
            time.sleep(delay_seconds)
            print(f"overpass_ok endpoint={endpoint} elements={len(payload.get('elements', []))}")
            return payload
        except Exception as error:
            last_error = error
            print(f"overpass_fail endpoint={endpoint} error={error!r}")
            time.sleep(max(delay_seconds, 1.0) * (attempt + 1) * 2)
    raise last_error if last_error else RuntimeError("Overpass query failed")


def build_train_query(city_name: str) -> str:
    return f"""
[out:json][timeout:180];
area["boundary"="administrative"]["name"="{city_name}"]->.searchArea;
(
  node(area.searchArea)["name"]["railway"~"station|stop|tram_stop|tram|halt"];
  node(area.searchArea)["name"]["station"="subway"];
  node(area.searchArea)["name"]["subway"="yes"];
  node(area.searchArea)["name"]["tram"="yes"];
  node(area.searchArea)["name"]["public_transport"="stop_position"];
  way(area.searchArea)["name"]["railway"~"station|stop|tram_stop|tram|halt"];
  way(area.searchArea)["name"]["station"="subway"];
  way(area.searchArea)["name"]["subway"="yes"];
  way(area.searchArea)["name"]["tram"="yes"];
  way(area.searchArea)["name"]["public_transport"="stop_position"];
);
out center tags;
"""


def build_bus_query(city_name: str) -> str:
    return f"""
[out:json][timeout:180];
area["boundary"="administrative"]["name"="{city_name}"]->.searchArea;
(
  node(area.searchArea)["name"]["highway"="bus_stop"];
  node(area.searchArea)["name"]["amenity"="bus_station"];
  node(area.searchArea)["name"]["public_transport"~"platform|stop_position"];
  node(area.searchArea)["name"]["bus"="yes"];
  way(area.searchArea)["name"]["highway"="bus_stop"];
  way(area.searchArea)["name"]["amenity"="bus_station"];
  way(area.searchArea)["name"]["public_transport"~"platform|stop_position"];
  way(area.searchArea)["name"]["bus"="yes"];
);
out center tags;
"""


def fetch_candidates(city_name: str, kind: str, cache: dict, cache_path: Path, delay_seconds: float, force_refresh: bool = False) -> dict[str, dict]:
    cache_key = f"{kind}|{city_name}"
    cached = None
    if not force_refresh:
        cached = cache.get(cache_key)
        if not isinstance(cached, dict):
            for key, value in cache.items():
                if not isinstance(value, dict):
                    continue
                if not key.endswith(f"|{city_name}") and not key.endswith(f":{city_name}"):
                    continue
                if kind == "bus" and "bus" not in key:
                    continue
                if kind == "train" and "bus" in key:
                    continue
                cached = value
                break
    if isinstance(cached, dict):
        cached = rehydrate_cached_candidates(cached)
        if cached is not cache.get(cache_key):
            cache[cache_key] = cached
            save_json(cache_path, cache)
        print(f"cache_hit kind={kind} city={city_name} candidates={len(cached)}")
        return cached

    query = build_bus_query(city_name) if kind == "bus" else build_train_query(city_name)
    print(f"fetch_start kind={kind} city={city_name} refresh={force_refresh}")
    payload = overpass_query(query, delay_seconds=delay_seconds)
    candidates: dict[str, dict] = {}
    for element in payload.get("elements", []):
        tags = element.get("tags", {})
        display_name = tags.get("name:zh") or extract_chinese_name(tags.get("name")) or tags.get("name")
        if not display_name:
            continue
        lat = element.get("lat") or element.get("center", {}).get("lat")
        lon = element.get("lon") or element.get("center", {}).get("lon")
        if lat is None or lon is None:
            continue
        derived_zh = tags.get("name:zh") or extract_chinese_name(tags.get("name"))
        osm_names = {key: value for key, value in tags.items() if key == "name" or key.startswith("name:")}
        if derived_zh and "name:zh" not in osm_names:
            osm_names["name:zh"] = derived_zh
        osm_name_zh = tags.get("name:zh") or derived_zh
        if kind == "bus":
            importance = 4.0
            if tags.get("amenity") == "bus_station":
                importance = 5.0
        else:
            importance = 5.0 if tags.get("railway") in {"station", "stop", "tram_stop", "tram", "halt"} else 4.0
        candidate = {
            "query": f"overpass-{kind}:{city_name}",
            "lat": float(lat),
            "lon": float(lon),
            "display_name": display_name,
            "osm_type": element.get("type", ""),
            "osm_id": str(element.get("id", "")),
            "importance": importance,
            "osm_name": tags.get("name"),
            "osm_name_zh": osm_name_zh,
            "osm_name_en": tags.get("name:en"),
            "osm_name_ja": tags.get("name:ja"),
            "osm_names_json": json.dumps(
                osm_names,
                ensure_ascii=False,
                sort_keys=True,
            ),
        }
        candidate_aliases = set()
        for value in candidate_name_fields(candidate):
            candidate_aliases.update(station_aliases(value))
        if osm_name_zh:
            candidate_aliases.update(station_aliases(osm_name_zh))
        if not candidate_aliases:
            continue
        for alias in candidate_aliases:
            existing = candidates.get(alias)
            if existing is None or candidate["importance"] > existing["importance"]:
                candidates[alias] = candidate

    cache[cache_key] = candidates
    save_json(cache_path, cache)
    print(f"fetch_ok kind={kind} city={city_name} candidates={len(candidates)}")
    return candidates


def build_global_candidates(cache: dict) -> dict[str, dict]:
    global_candidates: dict[str, dict] = {}
    for cached in cache.values():
        if not isinstance(cached, dict):
            continue
        for alias, candidate in cached.items():
            existing = global_candidates.get(alias)
            if existing is None or candidate.get("importance", 0) > existing.get("importance", 0):
                global_candidates[alias] = candidate
    return global_candidates


def classify_row(source_type: str | None, source_line_name: str | None, station_name: str) -> str:
    text = " ".join(part for part in [source_type or "", source_line_name or "", station_name] if part)
    if any(token in text for token in ("公交", "BRT", "快速公交", "快速巴士", "巴士")):
        return "bus"
    return "train"


def interpolate_missing_by_line(connection: sqlite3.Connection) -> int:
    cursor = connection.cursor()
    matched_rows = cursor.execute(
        """
        SELECT line_key, sequence, station_key, latitude, longitude
        FROM tunion_stations
        WHERE latitude IS NOT NULL AND longitude IS NOT NULL
        ORDER BY line_key, sequence
        """
    ).fetchall()
    def line_order(sequence: int | str | None, station_key: str) -> int:
        try:
            seq = int(sequence or 0)
        except Exception:
            seq = 0
        if seq > 0:
            return seq
        digits = re.sub(r"\D", "", str(station_key))
        return int(digits) if digits else 0

    by_line: dict[str, list[tuple[int, float, float]]] = defaultdict(list)
    for line_key, sequence, station_key, latitude, longitude in matched_rows:
        by_line[line_key].append((line_order(sequence, station_key), float(latitude), float(longitude)))

    missing_rows = cursor.execute(
        """
        SELECT station_key, city_name, line_key, sequence, station_name, source_type, source_line_name
        FROM tunion_stations
        WHERE (latitude IS NULL OR longitude IS NULL)
          AND (match_status IS NULL OR match_status = 'unmatched')
        ORDER BY line_key, sequence, station_key
        """
    ).fetchall()

    updated = 0
    for station_key, city_name, line_key, sequence, station_name, source_type, source_line_name in missing_rows:
        line_points = by_line.get(line_key)
        if not line_points or len(line_points) < 2:
            continue
        seq = line_order(sequence, station_key)
        left = None
        right = None
        for point in line_points:
            if point[0] < seq:
                left = point
            elif point[0] > seq and right is None:
                right = point
                break
        if left and right:
            total = right[0] - left[0]
            if total <= 0:
                continue
            ratio = (seq - left[0]) / total
            lat = left[1] + (right[1] - left[1]) * ratio
            lon = left[2] + (right[2] - left[2]) * ratio
            source = "line-interpolate-between"
        elif left:
            prev = None
            for point in reversed(line_points):
                if point[0] < left[0]:
                    prev = point
                    break
            if prev is None:
                continue
            step = left[0] - prev[0]
            if step <= 0:
                continue
            lat_delta = left[1] - prev[1]
            lon_delta = left[2] - prev[2]
            ratio = (seq - left[0]) / step
            lat = left[1] + lat_delta * ratio
            lon = left[2] + lon_delta * ratio
            source = "line-interpolate-extrapolate"
        elif right:
            nxt = None
            for point in line_points:
                if point[0] > right[0]:
                    nxt = point
                    break
            if nxt is None:
                continue
            step = nxt[0] - right[0]
            if step <= 0:
                continue
            lat_delta = right[1] - nxt[1]
            lon_delta = right[2] - nxt[2]
            ratio = (right[0] - seq) / step
            lat = right[1] + lat_delta * ratio
            lon = right[2] + lon_delta * ratio
            source = "line-interpolate-extrapolate"
        else:
            continue

        cursor.execute(
            """
            UPDATE tunion_stations
            SET match_status = 'matched',
                match_quality = 'approximate_line',
                match_source = ?,
                match_query = 'line-interpolate',
                latitude = ?,
                longitude = ?,
                display_name = ?,
                osm_type = 'line-approx',
                osm_id = ?,
                importance = 0,
                osm_name = ?,
                osm_name_zh = ?,
                osm_name_en = NULL,
                osm_name_ja = NULL,
                osm_names_json = ?,
                last_updated_at = datetime('now')
            WHERE station_key = ?
            """,
            (
                f"{source}:{source_type or ''}:{source_line_name or ''}",
                lat,
                lon,
                station_name,
                station_key,
                station_name,
                station_name,
                json.dumps({"name": station_name}, ensure_ascii=False, sort_keys=True),
                station_key,
            ),
        )
        by_line[line_key].append((seq, lat, lon))
        by_line[line_key].sort(key=lambda item: item[0])
        updated += 1
        print(
            f"approx_line station_key={station_key} city={city_name} line={line_key} station={station_name} "
            f"-> {lat:.6f},{lon:.6f} source={source}"
        )

    connection.commit()
    return updated

def rebuild_edges(connection: sqlite3.Connection) -> int:
    cursor = connection.cursor()
    rows = cursor.execute(
        """
        SELECT station_key, line_key, sequence, latitude, longitude
        FROM tunion_stations
        WHERE latitude IS NOT NULL AND longitude IS NOT NULL
        ORDER BY line_key, sequence, station_key
        """
    ).fetchall()
    grouped: dict[str, list[tuple[str, int, float, float]]] = defaultdict(list)
    for station_key, line_key, sequence, latitude, longitude in rows:
        grouped[line_key].append((station_key, sequence, latitude, longitude))

    edges = []
    for line_key, stations in grouped.items():
        for left, right in zip(stations, stations[1:]):
            _, _, left_lat, left_lon = left
            right_key, _, right_lat, right_lon = right
            distance_km = (((left_lat - right_lat) ** 2 + (left_lon - right_lon) ** 2) ** 0.5) * 111
            edges.append((line_key, left[0], right_key, round(distance_km, 3)))

    cursor.execute("DELETE FROM station_edges")
    cursor.executemany(
        "INSERT OR REPLACE INTO station_edges (line_code, from_station_code, to_station_code, distance_km) VALUES (?, ?, ?, ?)",
        edges,
    )
    connection.commit()
    return len(edges)


def main() -> None:
    connection = sqlite3.connect(DEFAULT_DB)
    cursor = connection.cursor()
    rows = cursor.execute(
        """
        SELECT station_key, city_id, city_name, line_key, sequence, COALESCE(source_station_name, station_name), source_type, source_line_name
        FROM tunion_stations
        WHERE match_status = 'unmatched'
        """
    ).fetchall()

    train_cache = load_json(DEFAULT_TRAIN_CACHE)
    bus_cache = load_json(DEFAULT_BUS_CACHE)
    train_global_candidates = build_global_candidates(train_cache)
    bus_global_candidates = build_global_candidates(bus_cache)
    matched = 0
    per_kind = defaultdict(int)
    per_city = defaultdict(int)
    per_quality = defaultdict(int)

    by_city_kind: dict[tuple[str, str], list[tuple]] = defaultdict(list)
    for row in rows:
        by_city_kind[(row[2], classify_row(row[6], row[7], row[5]))].append(row)

    for (city_name, kind), group in sorted(by_city_kind.items()):
        candidates = fetch_candidates(
            city_name,
            kind,
            bus_cache if kind == "bus" else train_cache,
            DEFAULT_BUS_CACHE if kind == "bus" else DEFAULT_TRAIN_CACHE,
            delay_seconds=3.0,
            force_refresh=False,
        )
        print(f"group city={city_name} kind={kind} rows={len(group)} candidates={len(candidates)}")
        for station_key, city_id, city_name, line_key, sequence, station_name, source_type, source_line_name in group:
            aliases = station_aliases(station_name)
            candidate = None
            match_quality = "good"
            for alias in aliases:
                candidate = candidates.get(alias)
                if candidate:
                    break
            if not candidate:
                source_aliases = station_aliases(source_line_name or "")
                for alias in source_aliases:
                    candidate = candidates.get(alias)
                    if candidate:
                        break
            if not candidate:
                candidate = partial_candidate_match(aliases, candidates)
                if candidate:
                    match_quality = "partial"
            if not candidate:
                source_aliases = station_aliases(source_line_name or "")
                candidate = partial_candidate_match(source_aliases, candidates)
                if candidate:
                    match_quality = "partial"
            if not candidate and kind == "train" and max((len(alias) for alias in aliases), default=0) >= 3:
                station_candidates = fetch_station_fallback(city_name, station_name, kind, delay_seconds=2.0)
                for alias in aliases:
                    candidate = station_candidates.get(alias)
                    if candidate:
                        match_quality = "good"
                        break
                if not candidate:
                    candidate = partial_candidate_match(aliases, station_candidates)
                    if candidate:
                        match_quality = "partial"
            if not candidate:
                print(f"unmatched station_key={station_key} city={city_name} kind={kind} station={station_name} source_type={source_type} source_line={source_line_name}")
                continue

            cursor.execute(
                """
                UPDATE tunion_stations
                SET match_status = 'matched',
                    match_quality = ?,
                    match_source = ?,
                    match_query = ?,
                    latitude = ?,
                    longitude = ?,
                    display_name = ?,
                    osm_type = ?,
                    osm_id = ?,
                    importance = ?,
                    osm_name = ?,
                    osm_name_zh = ?,
                    osm_name_en = ?,
                    osm_name_ja = ?,
                    osm_names_json = ?,
                    last_updated_at = datetime('now')
                WHERE station_key = ?
                """,
                (
                    match_quality,
                    f"{kind}:{source_type or ''}:{source_line_name or ''}:{'global' if match_quality != 'good' else 'city'}",
                    candidate["query"],
                    candidate["lat"],
                    candidate["lon"],
                    candidate["display_name"],
                    candidate["osm_type"],
                    candidate["osm_id"],
                    candidate["importance"],
                    candidate.get("osm_name"),
                    candidate.get("osm_name_zh"),
                    candidate.get("osm_name_en"),
                    candidate.get("osm_name_ja"),
                    candidate.get("osm_names_json"),
                    station_key,
                ),
            )
            matched += 1
            per_kind[kind] += 1
            per_city[city_name] += 1
            per_quality[match_quality] += 1
            print(
                f"matched station_key={station_key} city={city_name} kind={kind} station={station_name} "
                f"-> {candidate['display_name']} ({candidate['osm_type']} {candidate['osm_id']}) "
                f"{candidate['lat']:.6f},{candidate['lon']:.6f} quality={match_quality}"
            )

    approx = interpolate_missing_by_line(connection)
    edges = rebuild_edges(connection)
    connection.commit()
    connection.close()

    print(json.dumps(
        {
            "matched": matched,
            "by_kind": dict(per_kind),
            "by_city": dict(per_city),
            "by_quality": dict(per_quality),
            "approx_line": approx,
            "edges": edges,
            "train_cache_path": str(DEFAULT_TRAIN_CACHE),
            "bus_cache_path": str(DEFAULT_BUS_CACHE),
        },
        ensure_ascii=False,
    ))


if __name__ == "__main__":
    main()
