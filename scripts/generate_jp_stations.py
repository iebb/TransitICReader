#!/usr/bin/env python3

import argparse
import csv
import json
import math
import sqlite3
import unicodedata
from collections import Counter, defaultdict
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_CODES_CSV = REPO_ROOT / "CardBal/Resources/JPStationCodes.csv"
DEFAULT_LOCAL_STATIONS_CSV = REPO_ROOT / "station20240426.csv"
DEFAULT_STATION_DATABASE_DIR = REPO_ROOT / ".external/station_database/out/extra"
DEFAULT_OUTPUT_DB = REPO_ROOT / "CardBal/Resources/jp_stations.sqlite"
DEFAULT_REPORT = REPO_ROOT / "CardBal/Resources/jp_stations_coverage.json"
STATION_DATABASE_REVISION = "76d4d4dbf15aa1ef967fc137b4ddf892abe3f3f8"

NAME_OVERRIDES = {
    "奥中山": "奥中山高原",
    "空港第2ビル": "空港第２ビル（成田第２・第３ターミナル）",
    "成田空港": "成田空港（成田第１ターミナル）",
    "鹿島サッカースタジアム": "鹿島サッカースタジアム（臨）",
    "鷹ノ巣": "鷹ノ巣(鷹巣)",
    "鷹巣": "鷹ノ巣(鷹巣)",
    "宮島": "宮島口",
    "片町": "京橋",
    "京都鉄道博物館": "梅小路京都西",
    "* 京都鉄道博物館": "梅小路京都西",
    "文挾": "文挟",
    "狩湯沢": "狩場沢",
    "北一己": "北一已",
    "羽田空港国際線ビル": "羽田空港第3ターミナル",
    "羽田空港第1ビル": "羽田空港第1ターミナル",
    "羽田空港第2ビル": "羽田空港第2ターミナル",
    "押上": "押上(スカイツリー前)",
}

METHOD_CONFIDENCE = {
    "unique": 1.0,
    "scored": 0.9,
    "line_gap": 0.7,
    "manual_code": 0.75,
    "pseudo": 0.0,
}

AREA_CODE_PREFECTURES = {
    "000F0": [1],
    "000F1": [4],
    "000F2": [13],
    "000F3": [13],
    "000F4": [14],
    "000F6": [23],
    "000F7": [26],
    "000F8": [27],
    "000F9": [28],
    "000FB": [34],
    "000FD": [40],
    "000FE": [40],
}

PSEUDO_PREFECTURE_HINTS = {
    "000F0": [1],
    "000F1": [4],
    "000F2": [13],
    "000F3": [13],
    "000F4": [14],
    "000F6": [23],
    "000F7": [26],
    "000F8": [27],
    "000F9": [28],
    "000FB": [34],
    "000FD": [40],
    "000FE": [40],
    "002FC": [13],
    "002FD": [13],
    "002FE": [13],
    "002FF": [13],
    "05640": [13],
    "3D7F0": [40],
    "3E7F7": [40],
}

PSEUDO_ROW_EXTRAS = {
    "3D7F0": "nimocaポイント交換機",
}

PSEUDO_FORCE_CODES = {
    "08055",
    "0EE01",
    "0EE02",
    "0EE04",
    "0EE06",
    "1A57E",
    "1A5A2",
    "1AE16",
    "1AE2A",
    "1B12A",
    "1B508",
    "28F43",
    "2AB05",
    "2AD1F",
    "2B003",
    "3C103",
}

PSEUDO_NAME_HINTS = {
    "nimocaポイント交換機": [40],
}

PSEUDO_KEYWORDS = [
    "市内",
    "都区内",
    "山手線内",
    "全線",
    "回数券",
    "きっぷ",
    "乗車券",
    "フリー",
    "ポイント交換機",
    "端末",
    "本社",
    "営業所",
    "事務",
    "定期券",
    "株主優待",
    "社員家族",
    "業務用",
    "普通券",
    "手回り品",
    "インターネットサービス",
    "臨時窓口",
    "モバイルSuica",
    "携帯端末",
    "ATMJRE外",
    "神戸高速線",
    "東西線",
    "京津線",
    "博物館",
]


def normalize_text(value: str) -> str:
    return unicodedata.normalize("NFKC", value or "").strip()


def is_blank_name(name: str) -> bool:
    return not normalize_text(name)


def is_pseudo_name(name: str) -> bool:
    value = normalize_text(name)
    return value.startswith("*") or any(keyword in value for keyword in PSEUDO_KEYWORDS)


def city_name_from_label(name: str) -> str | None:
    value = normalize_text(name)
    if value.endswith("市内"):
        return value.removesuffix("市内")
    return None


def name_forms(name: str) -> set[str]:
    base = normalize_text(name).lstrip("* ").strip()
    if not base:
        return set()

    values = {base, base.replace("〈", "(").replace("〉", ")")}
    for _ in range(2):
        expanded = set(values)
        for value in values:
            expanded |= {
                value.replace("ヶ", "ケ").replace("ヵ", "ケ"),
                value.replace("ケ", "ヶ"),
                value.replace("ノ", "の"),
                value.replace("の", "ノ"),
                value.replace("ＪＲ", "JR"),
                value.replace("JR", "ＪＲ"),
                value.replace("第2", "第２").replace("第3", "第３").replace("第1", "第１"),
                value.replace("第２", "第2").replace("第３", "第3").replace("第１", "第1"),
                value.replace("挾", "挟").replace("已", "己"),
            }
            for left, right in (("(", ")"), ("（", "）")):
                if left in value and right in value:
                    before = value[: value.index(left)].strip()
                    inside = value[value.index(left) + 1 : value.rindex(right)]
                    if before:
                        expanded.add(before)
                    for part in [item.strip() for item in inside.replace("・", "/").replace("、", "/").split("/") if item.strip()]:
                        expanded.add(part)
                        if before:
                            expanded.add(before + part)
        values = expanded
    return {item for item in values if item}


class Resolver:
    def __init__(self, station_database_dir: Path, local_stations_csv: Path):
        self.station_database_dir = station_database_dir
        self.local_stations_csv = local_stations_csv
        self.entities: dict[str, dict] = {}
        self.line_sequences: dict[str, list[tuple[int, str]]] = defaultdict(list)
        self.name_index: dict[str, set[str]] = defaultdict(set)
        self.prefecture_entities: dict[int, list[str]] = defaultdict(list)
        self.city_entities: dict[str, list[str]] = defaultdict(list)
        self._load_station_database()
        self._load_local_supplements()
        for entity_id, entity in self.entities.items():
            for alias in entity["aliases"]:
                self.name_index[alias].add(entity_id)
            self.prefecture_entities[entity["prefecture"]].append(entity_id)
            city_name = self._city_name(entity["address"])
            if city_name:
                self.city_entities[city_name].append(entity_id)

    @staticmethod
    def _city_name(address: str) -> str | None:
        value = normalize_text(address)
        for marker in ("市", "区", "町", "村"):
            index = value.find(marker)
            if index >= 0:
                return value[: index + 1]
        return None

    def _load_station_database(self) -> None:
        stations_path = self.station_database_dir / "station.csv"
        register_path = self.station_database_dir / "register.csv"

        with stations_path.open(encoding="utf-8-sig", newline="") as handle:
            for row in csv.DictReader(handle):
                entity_id = f"sdb:{row['code']}"
                entity = {
                    "entity_id": entity_id,
                    "source": "station_database",
                    "station_code": row["code"],
                    "station_name": row["name"],
                    "station_original_name": row["original_name"],
                    "lat": float(row["lat"]),
                    "lon": float(row["lng"]),
                    "prefecture": int(row["prefecture"]),
                    "address": row["address"],
                    "closed": row["closed"] in {"1", "true", "True"},
                    "lines": set(),
                    "positions": defaultdict(list),
                    "aliases": set(),
                }
                for name in {row["name"], row["original_name"]}:
                    if name and name != "NULL":
                        entity["aliases"].update(name_forms(name))
                self.entities[entity_id] = entity

        with register_path.open(encoding="utf-8-sig", newline="") as handle:
            for row in csv.DictReader(handle):
                entity_id = f"sdb:{row['station_code']}"
                entity = self.entities.get(entity_id)
                if not entity:
                    continue
                line_code = row["line_code"]
                index = int(row["index"])
                entity["lines"].add(line_code)
                entity["positions"][line_code].append(index)
                self.line_sequences[line_code].append((index, entity_id))

        for line_code in self.line_sequences:
            self.line_sequences[line_code].sort()

    def _load_local_supplements(self) -> None:
        if not self.local_stations_csv.exists():
            return
        existing_aliases = {alias for entity in self.entities.values() for alias in entity["aliases"]}
        with self.local_stations_csv.open(encoding="utf-8-sig", newline="") as handle:
            for row in csv.DictReader(handle):
                if row["e_status"] != "0":
                    continue
                if row["station_name"] in existing_aliases:
                    continue
                entity_id = f"local:{row['station_g_cd']}"
                entity = self.entities.setdefault(
                    entity_id,
                    {
                        "entity_id": entity_id,
                        "source": "station20240426",
                        "station_code": row["station_g_cd"],
                        "station_name": row["station_name"],
                        "station_original_name": row["station_name"],
                        "lat": float(row["lat"]),
                        "lon": float(row["lon"]),
                        "prefecture": int(row["pref_cd"]),
                        "address": row["address"],
                        "closed": False,
                        "lines": set(),
                        "positions": defaultdict(list),
                        "aliases": name_forms(row["station_name"]),
                    },
                )
                entity["lines"].add(row["line_cd"])
                entity["positions"][row["line_cd"]].append(int(row["e_sort"]))

    def candidates_for_name(self, name: str) -> list[str]:
        candidates = set()
        names = [name]
        if name in NAME_OVERRIDES:
            names.insert(0, NAME_OVERRIDES[name])
        if "、" in name or "," in name:
            names.extend(part.strip() for part in name.replace(",", "、").split("、") if part.strip())

        for candidate_name in names:
            candidate_name = NAME_OVERRIDES.get(candidate_name, candidate_name)
            for form in name_forms(candidate_name):
                candidates |= self.name_index.get(form, set())
        return list(candidates)

    def nearest_assignment(self, assignments: list[str | None], index: int, direction: int) -> tuple[int | None, dict | None]:
        cursor = index + direction
        while 0 <= cursor < len(assignments):
            entity_id = assignments[cursor]
            if entity_id:
                return cursor, self.entities[entity_id]
            cursor += direction
        return None, None

    def score_candidate(self, assignments: list[str | None], index: int, entity_id: str) -> float:
        candidate = self.entities[entity_id]
        score = 0.0
        _, prev_entity = self.nearest_assignment(assignments, index, -1)
        _, next_entity = self.nearest_assignment(assignments, index, +1)

        if prev_entity:
            shared_lines = candidate["lines"] & prev_entity["lines"]
            if shared_lines:
                best_delta = min(
                    abs(a - b)
                    for line_code in shared_lines
                    for a in candidate["positions"][line_code]
                    for b in prev_entity["positions"][line_code]
                )
                score += 100 + max(0, 20 - best_delta)
            score -= math.hypot(candidate["lat"] - prev_entity["lat"], candidate["lon"] - prev_entity["lon"]) * 5

        if next_entity:
            shared_lines = candidate["lines"] & next_entity["lines"]
            if shared_lines:
                best_delta = min(
                    abs(a - b)
                    for line_code in shared_lines
                    for a in candidate["positions"][line_code]
                    for b in next_entity["positions"][line_code]
                )
                score += 100 + max(0, 20 - best_delta)
            score -= math.hypot(candidate["lat"] - next_entity["lat"], candidate["lon"] - next_entity["lon"]) * 5

        if prev_entity and next_entity:
            for line_code in candidate["lines"] & prev_entity["lines"] & next_entity["lines"]:
                candidate_pos = min(candidate["positions"][line_code])
                prev_pos = min(prev_entity["positions"][line_code])
                next_pos = min(next_entity["positions"][line_code])
                if prev_pos <= candidate_pos <= next_pos or next_pos <= candidate_pos <= prev_pos:
                    score += 300
        return score

    def resolve_rows(self, rows: list[dict]) -> tuple[list[str | None], list[str]]:
        assignments: list[str | None] = [None] * len(rows)
        methods: list[str] = [""] * len(rows)

        for index, row in enumerate(rows):
            name = row["name"]
            if is_blank_name(name) or is_pseudo_name(name) or row["code"] in PSEUDO_FORCE_CODES:
                continue
            candidates = self.candidates_for_name(name)
            if len(candidates) == 1:
                assignments[index] = candidates[0]
                methods[index] = "unique"

        for _ in range(4):
            changed = False
            for index, row in enumerate(rows):
                if assignments[index] or is_blank_name(row["name"]) or is_pseudo_name(row["name"]) or row["code"] in PSEUDO_FORCE_CODES:
                    continue
                candidates = self.candidates_for_name(row["name"])
                if not candidates:
                    continue
                assignments[index] = max(candidates, key=lambda entity_id: self.score_candidate(assignments, index, entity_id))
                methods[index] = "scored"
                changed = True
            if not changed:
                break

        for _ in range(4):
            changed = False
            cursor = 0
            while cursor < len(rows):
                if assignments[cursor] or is_blank_name(rows[cursor]["name"]) or is_pseudo_name(rows[cursor]["name"]) or rows[cursor]["code"] in PSEUDO_FORCE_CODES:
                    cursor += 1
                    continue
                start = cursor
                while cursor < len(rows) and not assignments[cursor] and not is_blank_name(rows[cursor]["name"]) and not is_pseudo_name(rows[cursor]["name"]) and rows[cursor]["code"] not in PSEUDO_FORCE_CODES:
                    cursor += 1
                end = cursor - 1

                prev_index = start - 1 if start > 0 and assignments[start - 1] else None
                next_index = end + 1 if end + 1 < len(rows) and assignments[end + 1] else None
                if prev_index is None or next_index is None:
                    continue

                prev_entity = self.entities[assignments[prev_index]]
                next_entity = self.entities[assignments[next_index]]
                gap_size = end - start + 1
                best_segment = None

                for line_code in prev_entity["lines"] & next_entity["lines"]:
                    for prev_pos in prev_entity["positions"][line_code]:
                        for next_pos in next_entity["positions"][line_code]:
                            if prev_pos == next_pos:
                                continue
                            low, high = sorted((prev_pos, next_pos))
                            segment = [entity_id for position, entity_id in self.line_sequences[line_code] if low < position < high]
                            if prev_pos > next_pos:
                                segment.reverse()
                            if len(segment) < gap_size:
                                continue
                            segment = segment[:gap_size]
                            score = 0
                            valid = True
                            for offset, entity_id in enumerate(segment):
                                if entity_id in self.candidates_for_name(rows[start + offset]["name"]):
                                    score += 20
                                else:
                                    valid = False
                                    break
                            if valid and (best_segment is None or score > best_segment[0]):
                                best_segment = (score, segment)

                if best_segment:
                    for offset, entity_id in enumerate(best_segment[1]):
                        assignments[start + offset] = entity_id
                        methods[start + offset] = "line_gap"
                    changed = True
            if not changed:
                break

        for index, row in enumerate(rows):
            if assignments[index] or is_blank_name(row["name"]) or is_pseudo_name(row["name"]) or row["code"] in PSEUDO_FORCE_CODES:
                continue
            candidates = self.candidates_for_name(row["name"])
            if candidates:
                assignments[index] = max(candidates, key=lambda entity_id: self.score_candidate(assignments, index, entity_id))
                methods[index] = "manual_code" if row["code"] in AREA_CODE_PREFECTURES else "scored"

        unresolved = [
            rows[index]["code"]
            for index, entity_id in enumerate(assignments)
            if not entity_id
            and not is_blank_name(rows[index]["name"])
            and not is_pseudo_name(rows[index]["name"])
            and rows[index]["code"] not in PSEUDO_FORCE_CODES
        ]
        if unresolved:
            raise RuntimeError(f"Failed to resolve non-pseudo rows. First unresolved codes: {unresolved[:10]}")

        return assignments, methods

    def prefecture_circle(self, prefectures: list[int]) -> tuple[float, float, float]:
        entity_ids = [entity_id for prefecture in prefectures for entity_id in self.prefecture_entities.get(prefecture, [])]
        if not entity_ids:
            return 0.0, 0.0, 0.0
        lats = [self.entities[entity_id]["lat"] for entity_id in entity_ids]
        lons = [self.entities[entity_id]["lon"] for entity_id in entity_ids]
        center_lat = sum(lats) / len(lats)
        center_lon = sum(lons) / len(lons)
        radius_km = max(math.hypot(lat - center_lat, lon - center_lon) * 111 for lat, lon in zip(lats, lons))
        return center_lat, center_lon, round(radius_km, 3)

    def city_circle(self, city_name: str) -> tuple[float, float, float] | None:
        lookup_keys = {city_name}
        if not city_name.endswith("市"):
            lookup_keys.add(f"{city_name}市")
        entity_ids = []
        for key in lookup_keys:
            entity_ids.extend(self.city_entities.get(key, []))
        if not entity_ids:
            return None
        lats = [self.entities[entity_id]["lat"] for entity_id in entity_ids]
        lons = [self.entities[entity_id]["lon"] for entity_id in entity_ids]
        center_lat = sum(lats) / len(lats)
        center_lon = sum(lons) / len(lons)
        radius_km = max(math.hypot(lat - center_lat, lon - center_lon) * 111 for lat, lon in zip(lats, lons))
        return center_lat, center_lon, round(radius_km, 3)

    def graph_edges(self) -> list[dict]:
        seen = set()
        edges = []
        for line_code, sequence in self.line_sequences.items():
            for (_, from_entity), (_, to_entity) in zip(sequence, sequence[1:]):
                from_station = self.entities[from_entity]["station_code"]
                to_station = self.entities[to_entity]["station_code"]
                if from_station == "0" or to_station == "0":
                    continue
                key = (line_code, min(from_station, to_station), max(from_station, to_station))
                if key in seen:
                    continue
                seen.add(key)
                distance_km = math.hypot(
                    self.entities[from_entity]["lat"] - self.entities[to_entity]["lat"],
                    self.entities[from_entity]["lon"] - self.entities[to_entity]["lon"],
                ) * 111
                edges.append(
                    {
                        "line_code": line_code,
                        "from_station_code": from_station,
                        "to_station_code": to_station,
                        "distance_km": round(distance_km, 3),
                    }
                )
        return edges


def load_rows(csv_path: Path) -> list[dict]:
    rows = []
    with csv_path.open(encoding="utf-8-sig", newline="") as handle:
        for code, name, *_ in csv.reader(handle):
            rows.append({"code": code, "name": normalize_text(name)})
    return rows


def build_pseudo_record(code: str, name: str, resolver: Resolver, assigned_entity_id: str | None) -> dict:
    if code == "3D7F0":
        tenjin_candidates = [
            resolver.entities[entity_id]
            for entity_id in resolver.candidates_for_name("天神")
            if resolver.entities[entity_id]["prefecture"] == 40
        ]
        tenjin_entity = next(
            (entity for entity in tenjin_candidates if entity["station_name"] == "天神"),
            tenjin_candidates[0] if tenjin_candidates else None,
        )
        city_circle = resolver.city_circle("福岡")
        if tenjin_entity and city_circle is not None:
            _, _, radius_km = city_circle
            center_lat = tenjin_entity["lat"]
            center_lon = tenjin_entity["lon"]
            return {
                "hex_code": code,
                "code_integer": int(code, 16),
                "csv_names": [name],
                "csv_primary_name": name,
                "station_name": name,
                "station_original_name": name,
                "station_source": "pseudo",
                "station_code": "0",
                "prefecture": 40,
                "latitude": center_lat,
                "longitude": center_lon,
                "address": "",
                "line_codes": [],
                "match_method": "pseudo",
                "confidence": METHOD_CONFIDENCE["pseudo"],
                "is_pseudo": True,
                "pseudo_id": f"pseudo:{code}",
                "error_center_latitude": center_lat,
                "error_center_longitude": center_lon,
                "error_radius_km": radius_km,
            }

    prefectures = PSEUDO_PREFECTURE_HINTS.get(code) or PSEUDO_NAME_HINTS.get(name)
    if not prefectures and assigned_entity_id:
        prefectures = [resolver.entities[assigned_entity_id]["prefecture"]]
    if not prefectures:
        prefectures = [13]
    city_name = city_name_from_label(name)
    city_circle = resolver.city_circle(city_name) if city_name else None
    if city_circle is not None:
        center_lat, center_lon, radius_km = city_circle
    else:
        center_lat, center_lon, radius_km = resolver.prefecture_circle(prefectures)
    return {
        "hex_code": code,
        "code_integer": int(code, 16),
        "csv_names": [name],
        "csv_primary_name": name,
        "station_name": name,
        "station_original_name": name,
        "station_source": "pseudo",
        "station_code": "0",
        "prefecture": prefectures[0],
        "latitude": center_lat,
        "longitude": center_lon,
        "address": "",
        "line_codes": [],
        "match_method": "pseudo",
        "confidence": METHOD_CONFIDENCE["pseudo"],
        "is_pseudo": True,
        "pseudo_id": f"pseudo:{code}",
        "error_center_latitude": center_lat,
        "error_center_longitude": center_lon,
        "error_radius_km": radius_km,
    }


def build_records(rows: list[dict], assignments: list[str | None], methods: list[str], resolver: Resolver) -> tuple[list[dict], list[str]]:
    grouped = defaultdict(list)
    for index, row in enumerate(rows):
        grouped[row["code"]].append((row, assignments[index], methods[index]))

    records = []
    skipped_blank_codes = []

    for code, items in grouped.items():
        nonblank_names = [item[0]["name"] for item in items if not is_blank_name(item[0]["name"])]
        if not nonblank_names:
            skipped_blank_codes.append(code)
            continue

        primary_name = nonblank_names[0]
        assigned_entity_id = next((item[1] for item in items if item[1]), None)
        if is_pseudo_name(primary_name) or code in AREA_CODE_PREFECTURES or code in PSEUDO_FORCE_CODES:
            records.append(build_pseudo_record(code, primary_name, resolver, assigned_entity_id))
            continue

        entity = resolver.entities[assigned_entity_id]
        method_counts = Counter(item[2] for item in items if item[2])
        method = method_counts.most_common(1)[0][0]
        records.append(
            {
                "hex_code": code,
                "code_integer": int(code, 16),
                "csv_names": nonblank_names,
                "csv_primary_name": primary_name,
                "station_name": entity["station_name"],
                "station_original_name": entity["station_original_name"],
                "station_source": entity["source"],
                "station_code": entity["station_code"],
                "prefecture": entity["prefecture"],
                "latitude": entity["lat"],
                "longitude": entity["lon"],
                "address": entity["address"],
                "line_codes": sorted(entity["lines"]),
                "match_method": method,
                "confidence": METHOD_CONFIDENCE.get(method, 0.5),
                "is_pseudo": False,
                "pseudo_id": None,
                "error_center_latitude": None,
                "error_center_longitude": None,
                "error_radius_km": None,
            }
        )

    for code, name in PSEUDO_ROW_EXTRAS.items():
        records.append(build_pseudo_record(code, name, resolver, None))

    records.sort(key=lambda record: record["code_integer"])
    return records, sorted(skipped_blank_codes)


def write_sqlite(output_path: Path, records: list[dict], edges: list[dict]) -> None:
    output_path.parent.mkdir(parents=True, exist_ok=True)
    if output_path.exists():
        output_path.unlink()

    connection = sqlite3.connect(output_path)
    try:
        connection.executescript(
            """
            PRAGMA journal_mode=WAL;
            CREATE TABLE jp_stations (
                hex_code TEXT PRIMARY KEY,
                code_integer INTEGER NOT NULL,
                csv_names_json TEXT NOT NULL,
                csv_primary_name TEXT NOT NULL,
                station_name TEXT NOT NULL,
                station_original_name TEXT NOT NULL,
                station_source TEXT NOT NULL,
                station_code TEXT NOT NULL,
                prefecture INTEGER NOT NULL,
                latitude REAL NOT NULL,
                longitude REAL NOT NULL,
                address TEXT NOT NULL,
                line_codes_json TEXT NOT NULL,
                match_method TEXT NOT NULL,
                confidence REAL NOT NULL,
                is_pseudo INTEGER NOT NULL,
                pseudo_id TEXT,
                error_center_latitude REAL,
                error_center_longitude REAL,
                error_radius_km REAL
            );
            CREATE INDEX idx_jp_stations_code_integer ON jp_stations (code_integer);
            CREATE INDEX idx_jp_stations_station_name ON jp_stations (station_name);
            CREATE TABLE station_edges (
                line_code TEXT NOT NULL,
                from_station_code TEXT NOT NULL,
                to_station_code TEXT NOT NULL,
                distance_km REAL NOT NULL
            );
            CREATE INDEX idx_station_edges_from ON station_edges (from_station_code);
            CREATE INDEX idx_station_edges_to ON station_edges (to_station_code);
            """
        )
        connection.executemany(
            """
            INSERT INTO jp_stations (
                hex_code,
                code_integer,
                csv_names_json,
                csv_primary_name,
                station_name,
                station_original_name,
                station_source,
                station_code,
                prefecture,
                latitude,
                longitude,
                address,
                line_codes_json,
                match_method,
                confidence,
                is_pseudo,
                pseudo_id,
                error_center_latitude,
                error_center_longitude,
                error_radius_km
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [
                (
                    record["hex_code"],
                    record["code_integer"],
                    json.dumps(record["csv_names"], ensure_ascii=False),
                    record["csv_primary_name"],
                    record["station_name"],
                    record["station_original_name"],
                    record["station_source"],
                    record["station_code"],
                    record["prefecture"],
                    record["latitude"],
                    record["longitude"],
                    record["address"],
                    json.dumps(record["line_codes"], ensure_ascii=False),
                    record["match_method"],
                    record["confidence"],
                    1 if record["is_pseudo"] else 0,
                    record["pseudo_id"],
                    record["error_center_latitude"],
                    record["error_center_longitude"],
                    record["error_radius_km"],
                )
                for record in records
            ],
        )
        connection.executemany(
            """
            INSERT INTO station_edges (
                line_code,
                from_station_code,
                to_station_code,
                distance_km
            ) VALUES (?, ?, ?, ?)
            """,
            [
                (
                    edge["line_code"],
                    edge["from_station_code"],
                    edge["to_station_code"],
                    edge["distance_km"],
                )
                for edge in edges
            ],
        )
        connection.commit()
    finally:
        connection.close()


def write_report(report_path: Path, records: list[dict], rows: list[dict], skipped_blank_codes: list[str]) -> None:
    report_path.parent.mkdir(parents=True, exist_ok=True)
    method_counts = Counter(record["match_method"] for record in records)
    report = {
        "csv_rows": len(rows),
        "output_rows": len(records),
        "skipped_blank_codes": skipped_blank_codes,
        "skipped_blank_code_count": len(skipped_blank_codes),
        "pseudo_row_count": sum(1 for record in records if record["is_pseudo"]),
        "real_station_row_count": sum(1 for record in records if not record["is_pseudo"]),
        "method_counts": dict(method_counts),
    }
    report_path.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Generate jp_stations SQLite from JPStationCodes.csv and station_database.")
    parser.add_argument("--codes-csv", type=Path, default=DEFAULT_CODES_CSV)
    parser.add_argument("--local-stations-csv", type=Path, default=DEFAULT_LOCAL_STATIONS_CSV)
    parser.add_argument(
        "--station-database-dir",
        type=Path,
        default=DEFAULT_STATION_DATABASE_DIR,
        help="Path to station_database/out/extra (kept outside this repository)",
    )
    parser.add_argument("--output-db", type=Path, default=DEFAULT_OUTPUT_DB)
    parser.add_argument("--report-json", type=Path, default=DEFAULT_REPORT)
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    required_station_files = ("station.csv", "register.csv")
    missing_station_files = [
        name for name in required_station_files if not (args.station_database_dir / name).is_file()
    ]
    if missing_station_files:
        raise FileNotFoundError(
            "station_database input is missing: "
            + ", ".join(missing_station_files)
            + ". Clone https://github.com/Seo-4d696b75/station_database.git into "
            + str(REPO_ROOT / ".external/station_database")
            + f" and check out {STATION_DATABASE_REVISION}, or pass --station-database-dir."
        )
    rows = load_rows(args.codes_csv)
    resolver = Resolver(args.station_database_dir, args.local_stations_csv)
    assignments, methods = resolver.resolve_rows(rows)
    records, skipped_blank_codes = build_records(rows, assignments, methods, resolver)
    edges = resolver.graph_edges()
    write_sqlite(args.output_db, records, edges)
    write_report(args.report_json, records, rows, skipped_blank_codes)
    summary = {
        "output_rows": len(records),
        "skipped_blank_code_count": len(skipped_blank_codes),
        "pseudo_row_count": sum(1 for record in records if record["is_pseudo"]),
        "edge_count": len(edges),
        "method_counts": Counter(record["match_method"] for record in records),
    }
    print(json.dumps(summary, ensure_ascii=False))


if __name__ == "__main__":
    main()
