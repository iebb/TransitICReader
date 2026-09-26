"""Read the pinned Trip Reader CSV tree without mixing station and terminal IDs."""

from __future__ import annotations

import csv
import hashlib
import io
import json
import re
import subprocess
import urllib.request
from collections import Counter
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path


REVISION = "c5584d6b8d9a39d7162b7b9781134be52db66186"
REPOSITORY = "https://github.com/domosekai/tripreader-data"
SUPPLEMENT = Path(__file__).resolve().parent / "data/tripreader-apk-stations.json"
CITY_UNION_FILES = {"Shanghai/cu.csv"}

# These fields are documented in each city's upstream README. They are not
# interchangeable with the line/station field of an SFI 1E record.
TERMINAL_FILES = {
    "Anhui/Hefei/brt-tu.csv": "1e",
    "Liaoning/Dalian/brt-tu.csv": "1e",
    "Jiangsu/Nanjing/bike-tu.csv": "18",
    "Zhejiang/Hangzhou/metro-tu.csv": "18",
    "Zhejiang/Jiaxing/metro-tu.csv": "18",
    "Zhejiang/Shaoxing/metro-tu.csv": "18",
    "Zhejiang/Shaoxing/train-tu.csv": "18",
}


def fetch(url: str) -> bytes:
    request = urllib.request.Request(url, headers={"User-Agent": "CardBal station data importer"})
    with urllib.request.urlopen(request, timeout=60) as response:
        return response.read()


def source_files(directory: Path | None = None) -> dict[str, bytes]:
    if directory is not None:
        revision = subprocess.run(
            ["git", "-C", str(directory), "rev-parse", "HEAD"], check=True, capture_output=True, text=True
        ).stdout.strip()
        if revision != REVISION:
            raise ValueError(f"Trip Reader checkout must be pinned to {REVISION}, got {revision}")
        files = {
            path.relative_to(directory).as_posix(): path.read_bytes()
            for path in sorted(directory.rglob("*-tu.csv"))
            if path.name != "cardname-tu.csv"
        }
        files.update({path: (directory / path).read_bytes() for path in CITY_UNION_FILES})
        for path, content in files.items():
            original = subprocess.run(
                ["git", "-C", str(directory), "show", f"{REVISION}:{path}"], check=True, capture_output=True
            ).stdout
            if content != original:
                raise ValueError(f"Trip Reader source file has local edits: {path}")
        return files
    tree = json.loads(fetch(
        f"https://api.github.com/repos/domosekai/tripreader-data/git/trees/{REVISION}?recursive=1"
    ))
    if tree.get("truncated"):
        raise ValueError("Trip Reader source tree is truncated")
    paths = sorted(
        entry["path"] for entry in tree["tree"]
        if entry["type"] == "blob" and (entry["path"].endswith("-tu.csv") or entry["path"] in CITY_UNION_FILES)
        and entry["path"] != "cardname-tu.csv"
    )
    with ThreadPoolExecutor(max_workers=4) as pool:
        contents = pool.map(
            lambda path: fetch(f"https://raw.githubusercontent.com/domosekai/tripreader-data/{REVISION}/{path}"),
            paths,
        )
        return dict(zip(paths, contents))


def station_line_code(code: str) -> str:
    return code[:-4] if len(code) == 8 else code[:-2]


def parse_sources(files: dict[str, bytes]) -> dict:
    stations, lines, terminals, city_union = {}, {}, {}, {}
    skipped = Counter()
    for path, content in sorted(files.items()):
        reader = csv.DictReader(io.StringIO(content.decode("utf-8-sig")))
        if not {"City", "Code", "Type", "Line", "Station"}.issubset(reader.fieldnames or []):
            raise ValueError(f"Unsupported Trip Reader CSV header: {path}")
        for row in reader:
            city, code, kind, line, name = (row[field].strip() for field in ("City", "Code", "Type", "Line", "Station"))
            code = code.upper()
            if not code:
                continue
            if not re.fullmatch(r"[0-9]{4}", city) or not re.fullmatch(r"[0-9A-F]+", code):
                raise ValueError(f"Invalid Trip Reader identifier in {path}: {city}/{code}")
            source = {
                "city_id": city, "code": code, "type": kind, "line": line,
                "station": name, "city_folder": str(Path(path).parent), "csv_file": Path(path).name,
            }
            if path in CITY_UNION_FILES:
                if city != "2000":
                    raise ValueError(f"Unreviewed City Union city: {city}")
                if name:
                    if len(code) not in (4, 6, 8):
                        raise ValueError(f"Unreviewed City Union terminal prefix: {code}")
                    key = city + code
                    if key in city_union and city_union[key] != source:
                        raise ValueError(f"Conflicting City Union prefix: {key}")
                    city_union[key] = source
                continue
            if path in TERMINAL_FILES:
                record = TERMINAL_FILES[path]
                expected_length = 12 if record == "18" else 16
                if len(code) != expected_length or not name:
                    raise ValueError(f"Invalid terminal station in {path}: {code}")
                key = f"{record}:{city}:{code}"
                if key in terminals and terminals[key] != source:
                    raise ValueError(f"Conflicting terminal mapping: {key}")
                terminals[key] = source
                continue
            # Xi'an's four-digit values come from characters 9-12 of the
            # terminal ID, not from the station field. Retain their provenance
            # separately until that city's record discriminator is supported.
            if path == "Shaanxi/Xi'an/metro-tu.csv" and len(code) <= 4:
                skipped["xian_terminal_subfield"] += bool(name)
                continue
            # Dalian's named bus records identify operators, not physical stops.
            if kind == "公交":
                skipped["bus_route_or_operator"] += 1
                name = ""
            if name and len(code) not in (4, 6, 8):
                raise ValueError(f"Unreviewed station code width in {path}: {code}")
            line_code = station_line_code(code) if name else code
            line_key = f"{city}|{line_code}|{line}|{kind}"
            if line_key not in lines:
                lines[line_key] = {
                    "city_id": city, "line_code": line_code, "line": line, "type": kind,
                    "city_folder": source["city_folder"], "csv_file": source["csv_file"], "station_count": 0,
                }
            if name:
                key = city + code
                if key in stations and stations[key] != source:
                    raise ValueError(f"Conflicting station mapping: {key}")
                stations[key] = source
                lines[line_key]["station_count"] += 1
    if not stations:
        raise ValueError("Trip Reader source contains no stations")
    return {
        "stations": stations, "lines": lines, "terminal_stations": terminals,
        "city_union_stations": city_union,
        "sources": [{
            "url": REPOSITORY, "revision": REVISION, "license": "CC-BY-4.0",
            "attribution": "Domosekai Limited and Trip Reader data contributors",
            "files": {path: hashlib.sha256(content).hexdigest() for path, content in sorted(files.items())},
        }],
        "excluded_rows": dict(sorted(skipped.items())),
    }


def load_source_payload(directory: Path | None = None) -> dict:
    payload = parse_sources(source_files(directory))
    supplement = json.loads(SUPPLEMENT.read_text(encoding="utf-8"))
    payload["sources"].append(supplement["source"])
    for key, station in supplement["stations"].items():
        if key in payload["stations"] and payload["stations"][key]["station"] != station["station"]:
            raise ValueError(f"APK supplement conflicts with public source: {key}")
        payload["stations"][key] = station
    for key, station_key in supplement.get("terminal_station_keys", {}).items():
        if key not in payload["terminal_stations"]:
            raise ValueError(f"APK terminal alias has no public source: {key}")
        payload["terminal_stations"][key]["station_key"] = station_key
    return payload
