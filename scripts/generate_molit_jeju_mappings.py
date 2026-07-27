#!/usr/bin/env python3

"""Build the scoped Jeju CardBal-to-MOLIT exact station crosswalk.

The official selector supplies the station IDs and names.  CardBal's only
inference is that, for KOTRIS Jeju modes 990/994/995, the eighth decimal digit
of the four-byte token is a variant/direction digit.  This script drops that
one digit and accepts a mapping only when the remaining seven digits occur
exactly once across the two official Jeju district selector snapshots.
"""

from __future__ import annotations

import argparse
import hashlib
import json
from collections import Counter, defaultdict
from pathlib import Path
from typing import Any


REPO_ROOT = Path(__file__).resolve().parents[1]
SOURCE_ROOT = REPO_ROOT / "cloudflare" / "korean-trip-visualizer" / "scripts" / "sources"
DEFAULT_DATASET = REPO_ROOT / "datasets" / "korean-transit" / "korean-trips.json"
DEFAULT_SOURCES = {
    "50110": SOURCE_ROOT / "molit_jeju_50110_stops_20250801.json",
    "50130": SOURCE_ROOT / "molit_jeju_50130_stops_20250801.json",
}
DEFAULT_OUTPUT = SOURCE_ROOT / "molit_jeju_20250801_mappings.json"
DEFAULT_REPORT = SOURCE_ROOT / "molit_jeju_20250801_validation.txt"
DISTRICT_NAMES = {"50110": "제주시", "50130": "서귀포시"}
MODE_CODES = {"03DE", "03E2", "03E3"}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dataset", type=Path, default=DEFAULT_DATASET)
    parser.add_argument("--jeju-city", type=Path, default=DEFAULT_SOURCES["50110"])
    parser.add_argument("--seogwipo", type=Path, default=DEFAULT_SOURCES["50130"])
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument("--report", type=Path, default=DEFAULT_REPORT)
    return parser.parse_args()


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def local_path(path: Path) -> str:
    try:
        return str(path.resolve().relative_to(REPO_ROOT))
    except ValueError:
        return str(path.resolve())


def load_selector(path: Path) -> list[dict[str, str]]:
    rows = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(rows, list) or any(
        set(row) != {"value", "text"}
        or not isinstance(row["value"], str)
        or not isinstance(row["text"], str)
        for row in rows
    ):
        raise ValueError(f"Unexpected MOLIT selector schema: {path}")
    if len(rows) != len({row["value"] for row in rows}):
        raise ValueError(f"Duplicate station IDs inside MOLIT selector: {path}")
    return rows


def main() -> None:
    args = parse_args()
    source_paths = {"50110": args.jeju_city, "50130": args.seogwipo}
    dataset = json.loads(args.dataset.read_text(encoding="utf-8"))

    selector_rows: dict[str, list[dict[str, str]]] = {}
    station_index: defaultdict[str, list[tuple[str, int, dict[str, str]]]] = defaultdict(list)
    for district, path in source_paths.items():
        rows = load_selector(path)
        selector_rows[district] = rows
        for index, row in enumerate(rows):
            station_index[row["value"]].append((district, index, row))

    locations = [
        location for location in dataset["locations"]
        if location["transportModeCode"] in MODE_CODES
    ]
    record_counts = Counter(
        record["locationCode"] for record in dataset["records"]
        if record["transportModeCode"] in MODE_CODES
    )
    mappings: list[dict[str, Any]] = []
    for location in locations:
        token = location["stationToken"]
        if len(token) != 8 or not token.isdecimal():
            raise ValueError(f"Jeju token is not eight decimal digits: {location['code']}")
        station_id = token[:7]
        matches = station_index.get(station_id, [])
        if len(matches) != 1:
            raise ValueError(
                f"Jeju station ID is not a unique official selector join: "
                f"{location['code']} -> {station_id} ({len(matches)} matches)"
            )
        district, selector_index, source_row = matches[0]
        source_path = source_paths[district]
        mappings.append(
            {
                "code": location["code"],
                "locationCode": location["code"],
                "stationToken": token,
                "transportModeCode": location["transportModeCode"],
                "systemDecimal": location["systemDecimal"],
                "systemOfficialNameKo": location["systemOfficialNameKo"],
                "name": source_row["text"],
                "mode": "bus",
                "provenance": "official_dataset_transformed_exact_match",
                "sourceID": "molit-settlement-stops-jeju-20250801",
                "sourceTitle": "국토교통부_버스정류장",
                "sourceStationID": station_id,
                "arsID": None,
                "ctpvName": "제주특별자치도",
                "sggName": DISTRICT_NAMES[district],
                "records": record_counts[location["code"]],
                "cards": location["cards"],
                "transform": {
                    "id": "jeju_station_variant_digit_v1",
                    "expression": "stationToken.slice(0, 7)",
                    "derivedStationID": station_id,
                    "discardedFinalDigit": token[7],
                    "scope": "transportModeCode 03DE/03E2/03E3 (decimal 990/994/995)",
                },
                "sourceRequest": {
                    "method": "POST",
                    "url": "https://tbo.stcis.go.kr/tsdw/open-api/getSttnOrRte/list",
                    "form": {
                        "type": "sttn",
                        "ymd": "20250801",
                        "sido": "50",
                        "sgg": district,
                    },
                },
                "sourceFile": local_path(source_path),
                "sourceFileSha256": sha256(source_path),
                "sourceSelectorIndex": selector_index,
                "sourceRow": source_row,
            }
        )

    mappings.sort(
        key=lambda item: (
            item["transportModeCode"],
            -item["records"],
            item["locationCode"],
        )
    )
    mapping_codes = {item["locationCode"] for item in mappings}
    records = [record for record in dataset["records"] if record["locationCode"] in mapping_codes]
    by_mode = {
        mode: {
            "locations": sum(item["transportModeCode"] == mode for item in mappings),
            "records": sum(
                item["records"] for item in mappings if item["transportModeCode"] == mode
            ),
        }
        for mode in sorted(MODE_CODES)
    }
    source_files = [
        {
            "sggCode": district,
            "sggName": DISTRICT_NAMES[district],
            "path": local_path(source_paths[district]),
            "sha256": sha256(source_paths[district]),
            "selectorRows": len(selector_rows[district]),
        }
        for district in sorted(source_paths)
    ]
    artifact = {
        "schemaVersion": 1,
        "generatedFrom": {
            "generator": local_path(Path(__file__)),
            "cardbalDataset": local_path(args.dataset),
            "cardbalDatasetSha256": sha256(args.dataset),
            "officialCatalogURL": "https://www.data.go.kr/data/15142032/openapi.do",
            "officialSamplePageURL": "https://tbo.stcis.go.kr/tsdw/open-api/api-search?gn=BusStop",
            "officialDistrictEndpoint": "https://tbo.stcis.go.kr/tsdw/open-api/50/sgg",
            "officialSelectorEndpoint": "https://tbo.stcis.go.kr/tsdw/open-api/getSttnOrRte/list",
            "publisher": "국토교통부",
            "datasetDate": "20250801",
            "portalModifiedDate": "2026-04-10",
            "catalogLicense": "이용허락범위 제한 없음",
            "access": "Anonymous official sample UI backend; no service key used",
            "sourceFiles": source_files,
            "selectorRows": sum(len(rows) for rows in selector_rows.values()),
        },
        "method": {
            "status": "corpus-derived final-digit transform followed by exact official-row join",
            "transportModeConstraint": "03DE/990 제주시외버스; 03E2/994 제주시내일반; 03E3/995 제주시내좌석",
            "stationIDExpression": "stationToken.slice(0, 7)",
            "officialJoin": "exact unique selector value; no fuzzy/name/geographic matching",
            "caveat": "The selector rows are official. The interpretation of token digit 8 as a discarded variant/direction digit is a corpus inference, not a published wire-format statement.",
        },
        "validation": {
            "observedLocations": len(locations),
            "observedRecords": sum(record_counts.values()),
            "mappedLocations": len(mappings),
            "mappedRecords": len(records),
            "mappedCards": len({record["cardHash"] for record in records}),
            "byMode": by_mode,
            "allLocationCodesExact": all(
                item["locationCode"]
                == item["stationToken"] + item["transportModeCode"]
                for item in mappings
            ),
            "allTokensEightDecimalDigits": all(
                len(item["stationToken"]) == 8 and item["stationToken"].isdecimal()
                for item in mappings
            ),
            "allExactUniqueOfficialJoins": all(
                len(station_index[item["sourceStationID"]]) == 1 for item in mappings
            ),
        },
        "knownLocations": mappings,
    }
    if artifact["validation"]["observedRecords"] != artifact["validation"]["mappedRecords"]:
        raise ValueError("Not every observed Jeju record was mapped")

    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(
        json.dumps(artifact, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    args.report.write_text(
        "\n".join(
            [
                "MOLIT Jeju 2025-08-01 transformed exact-match validation",
                f"artifact: {local_path(args.output)}",
                f"official snapshot: 2 district files / {artifact['generatedFrom']['selectorRows']} selector rows",
                f"mapped: {len(mappings)} fingerprints / {len(records)} rows / {artifact['validation']['mappedCards']} cards",
                f"by mode: {json.dumps(by_mode, ensure_ascii=False)}",
                f"locationCode invariant: {artifact['validation']['allLocationCodesExact']}",
                f"exact unique selector joins: {artifact['validation']['allExactUniqueOfficialJoins']}",
                "provenance boundary: official selector rows; final token digit interpretation remains a corpus inference.",
            ]
        )
        + "\n",
        encoding="utf-8",
    )
    print(json.dumps(artifact["validation"], ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
