#!/usr/bin/env python3
"""Build an auditable CardBal delta from the official Gyeonggi stop selector."""

import csv
import hashlib
import json
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
SOURCE_ROOT = REPO_ROOT / "cloudflare" / "korean-trip-visualizer" / "scripts" / "sources"
DATASET = REPO_ROOT / "datasets" / "korean-transit" / "korean-trips.json"
SOURCE_DIR = SOURCE_ROOT / "molit_gyeonggi_districts_20250801"
DISTRICTS = SOURCE_ROOT / "molit_gyeonggi_sgg_20250801.json"
ANNUAL = SOURCE_ROOT / "molit_settlement_stations_20250613.csv"
OUTPUT = SOURCE_ROOT / "molit_gyeonggi_20250801_delta_mappings.json"
REPORT = SOURCE_ROOT / "molit_gyeonggi_20250801_delta_validation.txt"

TARGETS = {
    "4170093001F4": ("41115", "4170093"),
    "001034100078": ("41210", "0010341"),
    "007384400073": ("41173", "0073844"),
    "410297600212": ("41650", "4102976"),
    "4106605001F4": ("41150", "4106605"),
}


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def aggregate_sha256(paths: list[Path]) -> str:
    digest = hashlib.sha256()
    for path in paths:
        digest.update(path.name.encode("utf-8"))
        digest.update(b"\0")
        digest.update(path.read_bytes())
        digest.update(b"\0")
    return digest.hexdigest()


def local_path(path: Path) -> str:
    try:
        return str(path.resolve().relative_to(REPO_ROOT))
    except ValueError:
        return str(path.resolve())


dataset = json.loads(DATASET.read_text(encoding="utf-8"))
locations = {item["code"]: item for item in dataset["locations"]}
district_names = json.loads(DISTRICTS.read_text(encoding="utf-8"))

source_files = sorted(SOURCE_DIR.glob("*.json"))
source_rows = 0
source_index: dict[tuple[str, str], list[dict]] = {}
for path in source_files:
    rows = json.loads(path.read_text(encoding="utf-8"))
    source_rows += len(rows)
    sgg_code = path.stem
    for index, row in enumerate(rows):
        source_index.setdefault((sgg_code, row["value"]), []).append(
            {"selectorIndex": index, "sourceRow": row}
        )

annual_ids: set[str] = set()
with ANNUAL.open(encoding="cp949", newline="") as handle:
    for row in csv.DictReader(handle):
        annual_ids.add(row["정류장아이디"])

mappings = []
for location_code, (sgg_code, station_id) in TARGETS.items():
    location = locations[location_code]
    matches = source_index.get((sgg_code, station_id), [])
    if len(matches) != 1:
        raise ValueError(f"Expected one selector row for {location_code}; got {len(matches)}")
    if location["stationIdCandidate"] != station_id:
        raise ValueError(f"Dataset candidate mismatch for {location_code}")
    match = matches[0]
    source_file = SOURCE_DIR / f"{sgg_code}.json"
    mappings.append(
        {
            "code": location_code,
            "locationCode": location_code,
            "stationToken": location["stationToken"],
            "transportModeCode": location["transportModeCode"],
            "systemDecimal": location["systemDecimal"],
            "systemOfficialNameKo": location["systemOfficialNameKo"],
            "name": match["sourceRow"]["text"],
            "mode": "bus",
            "provenance": "official_dataset_exact_match",
            "sourceID": "molit-settlement-stops-20250801",
            "sourceTitle": "국토교통부_버스정류장",
            "sourceStationID": station_id,
            "arsID": None,
            "ctpvName": "경기도",
            "sggName": district_names[sgg_code],
            "records": location["records"],
            "cards": location["cards"],
            "exactMatch": {
                "expression": "stationToken.slice(0, 7)",
                "derivedStationID": location["stationToken"][:7],
                "requirements": [
                    "official KOTRIS class B transport mode",
                    "eight decimal BCD station-token digits",
                    "station token ends in zero",
                    "exact unique selector value match",
                ],
            },
            "sourceRequest": {
                "method": "POST",
                "url": "https://tbo.stcis.go.kr/tsdw/open-api/getSttnOrRte/list",
                "form": {
                    "type": "sttn",
                    "ymd": "20250801",
                    "sido": "41",
                    "sgg": sgg_code,
                },
            },
            "sourceFile": local_path(source_file),
            "sourceFileSha256": sha256(source_file),
            "sourceSelectorIndex": match["selectorIndex"],
            "sourceRow": match["sourceRow"],
            "absentFromAnnual20250613": station_id not in annual_ids,
        }
    )

mappings.sort(key=lambda item: (-item["records"], item["locationCode"]))
target_codes = set(TARGETS)
records = [record for record in dataset["records"] if record["locationCode"] in target_codes]

artifact = {
    "schemaVersion": 1,
    "generatedFrom": {
        "generator": local_path(Path(__file__)),
        "cardbalDataset": local_path(DATASET),
        "cardbalDatasetSha256": sha256(DATASET),
        "officialCatalogURL": "https://www.data.go.kr/data/15142032/openapi.do",
        "officialSamplePageURL": "https://tbo.stcis.go.kr/tsdw/open-api/api-search?gn=BusStop",
        "officialDistrictEndpoint": "https://tbo.stcis.go.kr/tsdw/open-api/41/sgg",
        "officialSelectorEndpoint": "https://tbo.stcis.go.kr/tsdw/open-api/getSttnOrRte/list",
        "publisher": "국토교통부",
        "datasetDate": "20250801",
        "portalModifiedDate": "2026-04-10",
        "catalogLicense": "이용허락범위 제한 없음",
        "access": "Anonymous official sample UI backend; no service key used",
        "districtMap": local_path(DISTRICTS),
        "districtMapSha256": sha256(DISTRICTS),
        "districtFiles": len(source_files),
        "selectorRows": source_rows,
        "districtCorpusSha256": aggregate_sha256(source_files),
        "annualComparison": local_path(ANNUAL),
        "annualComparisonSha256": sha256(ANNUAL),
    },
    "method": {
        "status": "exact official selector-row join",
        "scope": "CardBal locations whose KOTRIS system class is Bus",
        "stationIDExpression": "stationToken.slice(0, 7)",
        "constraints": "stationToken must contain eight decimal digits and end in zero; no fuzzy or geographic name matching",
        "deltaDefinition": "The five exact station IDs occur in the official 2025-08-01 Gyeonggi selector snapshot and are absent from the official annual 2025-06-13 inventory.",
        "caveat": "Dropping the final zero nibble is a corpus interpretation. Each resulting identifier is then joined exactly and uniquely to an official source row.",
    },
    "validation": {
        "mappedLocations": len(mappings),
        "mappedRecords": len(records),
        "mappedCards": len({record["cardHash"] for record in records}),
        "mappedStationIDs": len({mapping["sourceStationID"] for mapping in mappings}),
        "allLocationCodesExact": all(
            mapping["locationCode"] == mapping["stationToken"] + mapping["transportModeCode"]
            for mapping in mappings
        ),
        "allTokensEightDecimalDigitsEndingZero": all(
            len(mapping["stationToken"]) == 8
            and mapping["stationToken"].isdigit()
            and mapping["stationToken"].endswith("0")
            for mapping in mappings
        ),
        "allDerivedIDsExact": all(
            mapping["stationToken"][:7] == mapping["sourceStationID"]
            for mapping in mappings
        ),
        "allSelectorRowsUniqueWithinDistrict": all(
            len(source_index[(mapping["sourceRequest"]["form"]["sgg"], mapping["sourceStationID"])]) == 1
            for mapping in mappings
        ),
        "allAbsentFromAnnual20250613": all(mapping["absentFromAnnual20250613"] for mapping in mappings),
    },
    "knownLocations": mappings,
}

OUTPUT.write_text(json.dumps(artifact, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

REPORT.write_text(
    "\n".join(
        [
            "MOLIT Gyeonggi 2025-08-01 exact-match delta validation",
            f"artifact: {OUTPUT}",
            f"official snapshot: {len(source_files)} district files / {source_rows} selector rows",
            f"mapped: {len(mappings)} fingerprints / {len(records)} rows / {artifact['validation']['mappedCards']} cards",
            f"station IDs: {', '.join(mapping['sourceStationID'] for mapping in mappings)}",
            f"locationCode invariant: {artifact['validation']['allLocationCodesExact']}",
            f"token shape invariant: {artifact['validation']['allTokensEightDecimalDigitsEndingZero']}",
            f"exact unique selector joins: {artifact['validation']['allSelectorRowsUniqueWithinDistrict']}",
            f"absent from annual 2025-06-13 source: {artifact['validation']['allAbsentFromAnnual20250613']}",
            "provenance boundary: official selector rows; dropping the final zero nibble remains a corpus interpretation.",
        ]
    )
    + "\n",
    encoding="utf-8",
)

print(OUTPUT)
print(REPORT)
