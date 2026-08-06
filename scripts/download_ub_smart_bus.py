#!/usr/bin/env python3
"""Download Ulaanbaatar routes and stations from the UB Smart Bus service.

The protocol implemented here is the one used by the Android application with
package name ``com.uscc.ubbus``.  It is a small CRC-protected binary protocol
over TCP.  The script deliberately uses only Python's standard library so that
the checked-in snapshot can be refreshed without installing dependencies.
"""

from __future__ import annotations

import argparse
import csv
import os
import socket
import sqlite3
import struct
import tempfile
import time
from collections import Counter, defaultdict
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable


REPO_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_OUTPUT_DIR = REPO_ROOT / "StationAssets"

MNS_5217_TRANSLITERATION = str.maketrans(
    {
        "А": "A", "а": "a", "Б": "B", "б": "b", "В": "V", "в": "v",
        "Г": "G", "г": "g", "Д": "D", "д": "d", "Е": "Ye", "е": "ye",
        "Ё": "Yo", "ё": "yo", "Ж": "Zh", "ж": "zh", "З": "Z", "з": "z",
        "И": "I", "и": "i", "Й": "J", "й": "j", "К": "K", "к": "k",
        "Л": "L", "л": "l", "М": "M", "м": "m", "Н": "N", "н": "n",
        "О": "O", "о": "o", "Ө": "Ö", "ө": "ö", "П": "P", "п": "p",
        "Р": "R", "р": "r", "С": "S", "с": "s", "Т": "T", "т": "t",
        "У": "U", "у": "u", "Ү": "Ü", "ү": "ü", "Ф": "F", "ф": "f",
        "Х": "Kh", "х": "kh", "Ц": "Ts", "ц": "ts", "Ч": "Ch", "ч": "ch",
        "Ш": "Sh", "ш": "sh", "Щ": "Sh", "щ": "sh", "Ъ": "I", "ъ": "i",
        "Ы": "Y", "ы": "y", "Ь": "I", "ь": "i", "Э": "E", "э": "e",
        "Ю": "Yu", "ю": "yu", "Я": "Ya", "я": "ya",
    }
)


class ProtocolError(RuntimeError):
    pass


def crc16_modbus(data: bytes) -> int:
    crc = 0xFFFF
    for value in data:
        crc ^= value
        for _ in range(8):
            crc = (crc >> 1) ^ 0xA001 if crc & 1 else crc >> 1
    return crc & 0xFFFF


def encode_packet(sequence: int, packet_type: int, opcode: int, body: bytes = b"") -> bytes:
    header = struct.pack("<BBBBBH", 0x02, sequence & 0xFF, 0x02, packet_type, opcode, len(body))
    payload = header + body
    return payload + struct.pack("<HB", crc16_modbus(payload), 0x03)


def read_exact(stream: socket.socket, length: int) -> bytes:
    chunks: list[bytes] = []
    remaining = length
    while remaining:
        chunk = stream.recv(remaining)
        if not chunk:
            raise ConnectionError("UB Smart Bus closed the connection")
        chunks.append(chunk)
        remaining -= len(chunk)
    return b"".join(chunks)


@dataclass(frozen=True)
class Packet:
    sequence: int
    packet_type: int
    opcode: int
    body: bytes


def decode_packet(header: bytes, tail: bytes) -> Packet:
    if len(header) != 7:
        raise ProtocolError(f"invalid header length: {len(header)}")
    stx, sequence, version, packet_type, opcode, body_length = struct.unpack("<BBBBBH", header)
    if stx != 0x02 or not 1 <= version <= 5:
        raise ProtocolError(f"invalid packet header: stx={stx:#x}, version={version:#x}")
    if len(tail) != body_length + 3:
        raise ProtocolError(f"invalid body length: expected {body_length + 3}, received {len(tail)}")
    body = tail[:body_length]
    expected_crc, etx = struct.unpack("<HB", tail[body_length:])
    actual_crc = crc16_modbus(header + body)
    # Production responses use zero as an omitted checksum.  Validate every
    # non-zero checksum while remaining compatible with the official client.
    if expected_crc not in (0, actual_crc):
        raise ProtocolError(f"CRC mismatch: expected {expected_crc:#06x}, calculated {actual_crc:#06x}")
    if etx != 0x03:
        raise ProtocolError(f"invalid packet terminator: {etx:#x}")
    return Packet(sequence=sequence, packet_type=packet_type, opcode=opcode, body=body)


class Reader:
    def __init__(self, data: bytes):
        self.data = data
        self.offset = 0

    def _take(self, length: int) -> bytes:
        end = self.offset + length
        if end > len(self.data):
            raise ProtocolError(f"truncated body at byte {self.offset}: need {length} bytes")
        value = self.data[self.offset:end]
        self.offset = end
        return value

    def u8(self) -> int:
        return self._take(1)[0]

    def i16(self) -> int:
        return struct.unpack("<h", self._take(2))[0]

    def i32(self) -> int:
        return struct.unpack("<i", self._take(4))[0]

    def fixed_utf8(self, length: int) -> str:
        return self._take(length).split(b"\0", 1)[0].decode("utf-8")

    def utf16le(self) -> str:
        return self._take(self.u8()).decode("utf-16le")

    def finish(self) -> None:
        if self.offset != len(self.data):
            raise ProtocolError(f"unexpected {len(self.data) - self.offset} trailing body bytes")


@dataclass(frozen=True)
class RouteText:
    route_id: int
    route_name: str
    endpoint_name: str


@dataclass(frozen=True)
class StationText:
    station_id: int
    mobile_code: str
    station_name: str
    longitude: float
    latitude: float


@dataclass(frozen=True)
class RoutePage:
    total_routes: int
    total_stations: int
    routes: list[RouteText]
    stations: list[StationText]


@dataclass(frozen=True)
class StationPage:
    total_stations: int
    stations: list[StationText]


def read_route(reader: Reader) -> RouteText:
    return RouteText(reader.i32(), reader.utf16le(), reader.utf16le())


def read_station(reader: Reader) -> StationText:
    station_id = reader.i32()
    mobile_code = reader.fixed_utf8(6)
    station_name = reader.utf16le()
    longitude = reader.i32() / 1_000_000
    latitude = reader.i32() / 1_000_000
    return StationText(station_id, mobile_code, station_name, longitude, latitude)


def parse_search_response(data: bytes) -> RoutePage:
    reader = Reader(data)
    total_routes = reader.u8()
    total_stations = reader.u8()
    routes = [read_route(reader) for _ in range(reader.u8())]
    stations = [read_station(reader) for _ in range(reader.u8())]
    reader.finish()
    return RoutePage(total_routes, total_stations, routes, stations)


def parse_route_stations_response(data: bytes) -> StationPage:
    reader = Reader(data)
    total_stations = reader.i16()
    stations = [read_station(reader) for _ in range(reader.u8())]
    reader.finish()
    return StationPage(total_stations, stations)


class UBSmartBusClient:
    def __init__(self, host: str, port: int, timeout: float, retries: int):
        self.host = host
        self.port = port
        self.timeout = timeout
        self.retries = retries
        self.stream: socket.socket | None = None
        self.sequence = 0

    def __enter__(self) -> "UBSmartBusClient":
        return self

    def __exit__(self, *_: object) -> None:
        self.close()

    def close(self) -> None:
        if self.stream is not None:
            self.stream.close()
            self.stream = None

    def _next_sequence(self) -> int:
        self.sequence = (self.sequence % 255) + 1
        return self.sequence

    def _exchange_once(self, packet_type: int, opcode: int, body: bytes, response_opcode: int) -> bytes:
        if self.stream is None:
            raise ConnectionError("UB Smart Bus socket is not connected")
        sequence = self._next_sequence()
        self.stream.sendall(encode_packet(sequence, packet_type, opcode, body))
        header = read_exact(self.stream, 7)
        body_length = struct.unpack_from("<H", header, 5)[0]
        response = decode_packet(header, read_exact(self.stream, body_length + 3))
        if response.packet_type != packet_type or response.opcode != response_opcode:
            raise ProtocolError(
                f"unexpected response {response.packet_type:#04x}/{response.opcode:#04x}; "
                f"wanted {packet_type:#04x}/{response_opcode:#04x}"
            )
        return response.body

    def connect(self) -> None:
        self.close()
        self.stream = socket.create_connection((self.host, self.port), timeout=self.timeout)
        self.stream.settimeout(self.timeout)
        self.sequence = 0
        device_id = b"CardBalDataCollector".ljust(50, b"\0")
        self._exchange_once(0x01, 0x01, device_id + b"04", 0x02)
        self._exchange_once(0x01, 0x05, b"", 0x06)

    def exchange(self, packet_type: int, opcode: int, body: bytes, response_opcode: int) -> bytes:
        failure: Exception | None = None
        for attempt in range(self.retries + 1):
            try:
                if self.stream is None:
                    self.connect()
                return self._exchange_once(packet_type, opcode, body, response_opcode)
            except (OSError, ProtocolError) as error:
                failure = error
                self.close()
                if attempt < self.retries:
                    time.sleep(min(2**attempt, 4))
        raise RuntimeError(f"UB Smart Bus request failed after {self.retries + 1} attempts") from failure

    def search(self, search_type: int, start: int, language: int, keyword: str = "") -> RoutePage:
        keyword_bytes = keyword.encode("utf-16le")
        if not 1 <= start <= 255:
            raise ValueError(f"search start must be between 1 and 255, got {start}")
        if len(keyword_bytes) > 255:
            raise ValueError("search keyword is too long")
        body = struct.pack("<BBBB", search_type, start, language, len(keyword_bytes)) + keyword_bytes
        return parse_search_response(self.exchange(0x05, 0x09, body, 0x10))

    def route_stations(self, route_id: int, start: int, language: int) -> StationPage:
        body = struct.pack("<ihB", route_id, start, language)
        return parse_route_stations_response(self.exchange(0x05, 0x13, body, 0x14))


def paginated_routes(client: UBSmartBusClient, language: int, delay: float) -> list[RouteText]:
    result: list[RouteText] = []
    total: int | None = None
    while total is None or len(result) < total:
        page = client.search(1, len(result) + 1, language)
        if total is None:
            total = page.total_routes
        elif page.total_routes != total:
            raise ProtocolError(f"route count changed during download: {total} -> {page.total_routes}")
        if not page.routes:
            raise ProtocolError(f"empty route page at row {len(result) + 1} of {total}")
        result.extend(page.routes)
        time.sleep(delay)
    return result[:total]


def capped_station_search(client: UBSmartBusClient, language: int, delay: float) -> list[StationText]:
    result: list[StationText] = []
    total: int | None = None
    while total is None or len(result) < total:
        page = client.search(2, len(result) + 1, language)
        if total is None:
            total = page.total_stations
        if not page.stations:
            break
        result.extend(page.stations)
        if len(result) >= 255:
            break
        time.sleep(delay)
    return result[: total or 0]


def paginated_route_stations(
    client: UBSmartBusClient,
    route_id: int,
    language: int,
    delay: float,
) -> list[StationText]:
    result: list[StationText] = []
    total: int | None = None
    while total is None or len(result) < total:
        page = client.route_stations(route_id, len(result) + 1, language)
        if total is None:
            total = page.total_stations
        elif page.total_stations != total:
            raise ProtocolError(
                f"station count for route {route_id} changed during download: {total} -> {page.total_stations}"
            )
        if not page.stations:
            raise ProtocolError(f"empty station page for route {route_id} at row {len(result) + 1} of {total}")
        result.extend(page.stations)
        time.sleep(delay)
    return result[:total]


def choose_text(values: Iterable[str]) -> str:
    counts = Counter(" ".join(value.split()) for value in values if value.strip())
    if not counts:
        return ""
    return sorted(counts, key=lambda value: (-counts[value], value.casefold(), value))[0]


def romanize_mongolian(value: str) -> str:
    """Apply the deterministic MNS 5217:2012 character mapping."""
    return value.translate(MNS_5217_TRANSLITERATION)


def localized_english(value: str, mongolian_fallback: str) -> str:
    candidate = " ".join(value.split()) or " ".join(mongolian_fallback.split())
    return romanize_mongolian(candidate)


def choose_station(values: Iterable[StationText]) -> StationText:
    rows = list(values)
    if not rows:
        raise ValueError("cannot choose from an empty station list")
    first = rows[0]
    coordinates = Counter((row.longitude, row.latitude) for row in rows)
    longitude, latitude = sorted(coordinates, key=lambda value: (-coordinates[value], value))[0]
    return StationText(
        station_id=first.station_id,
        mobile_code=choose_text(row.mobile_code for row in rows),
        station_name=choose_text(row.station_name for row in rows),
        longitude=longitude,
        latitude=latitude,
    )


def write_tsv(path: Path, fieldnames: list[str], rows: Iterable[dict[str, object]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile("w", encoding="utf-8", newline="", dir=path.parent, delete=False) as handle:
        writer = csv.DictWriter(handle, fieldnames=fieldnames, dialect="excel-tab", lineterminator="\n")
        writer.writeheader()
        writer.writerows(rows)
        temporary = Path(handle.name)
    os.replace(temporary, path)


def write_database(
    path: Path,
    stations: list[dict[str, object]],
    routes: list[dict[str, object]],
    route_stations: list[dict[str, object]],
) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    handle, temporary_name = tempfile.mkstemp(dir=path.parent, suffix=".sqlite")
    os.close(handle)
    temporary = Path(temporary_name)
    try:
        with sqlite3.connect(temporary) as connection:
            connection.executescript(
                """
                PRAGMA user_version = 1;
                CREATE TABLE stations (
                    station_id INTEGER PRIMARY KEY,
                    station_name_mn TEXT NOT NULL,
                    station_name_en TEXT NOT NULL,
                    latitude REAL NOT NULL,
                    longitude REAL NOT NULL
                );
                CREATE TABLE routes (
                    route_id INTEGER PRIMARY KEY,
                    route_name_mn TEXT NOT NULL,
                    route_name_en TEXT NOT NULL,
                    endpoint_name_mn TEXT NOT NULL,
                    endpoint_name_en TEXT NOT NULL
                );
                CREATE TABLE route_stations (
                    route_id INTEGER NOT NULL REFERENCES routes(route_id),
                    station_sequence INTEGER NOT NULL,
                    station_id INTEGER NOT NULL REFERENCES stations(station_id),
                    PRIMARY KEY (route_id, station_sequence)
                );
                CREATE INDEX route_stations_station_id_idx ON route_stations(station_id);
                """
            )
            connection.executemany(
                "INSERT INTO stations VALUES (:station_id, :station_name_mn, :station_name_en, :latitude, :longitude)",
                stations,
            )
            connection.executemany(
                "INSERT INTO routes VALUES (:route_id, :route_name_mn, :route_name_en, :endpoint_name_mn, :endpoint_name_en)",
                routes,
            )
            connection.executemany(
                "INSERT INTO route_stations VALUES (:route_id, :station_sequence, :station_id)",
                route_stations,
            )
            result = connection.execute("PRAGMA integrity_check").fetchone()[0]
            if result != "ok":
                raise RuntimeError(f"SQLite integrity check failed: {result}")
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def collect(client: UBSmartBusClient, delay: float) -> tuple[list[dict[str, object]], list[dict[str, object]], list[dict[str, object]]]:
    routes_by_language = {language: paginated_routes(client, language, delay) for language in (0, 1)}
    route_maps = {language: {route.route_id: route for route in rows} for language, rows in routes_by_language.items()}
    if set(route_maps[0]) != set(route_maps[1]):
        raise ProtocolError("Mongolian and English route IDs do not match")

    station_candidates: dict[int, dict[int, list[StationText]]] = {
        0: defaultdict(list),
        1: defaultdict(list),
    }
    for language in (0, 1):
        for station in capped_station_search(client, language, delay):
            station_candidates[language][station.station_id].append(station)

    route_stations: list[dict[str, object]] = []
    for index, route_id in enumerate(sorted(route_maps[0]), start=1):
        localized: dict[int, list[StationText]] = {}
        for language in (0, 1):
            localized[language] = paginated_route_stations(client, route_id, language, delay)
            for station in localized[language]:
                station_candidates[language][station.station_id].append(station)
        mn_ids = [station.station_id for station in localized[0]]
        en_ids = [station.station_id for station in localized[1]]
        if mn_ids != en_ids:
            raise ProtocolError(f"Mongolian and English station sequences differ for route {route_id}")
        route_stations.extend(
            {
                "route_id": route_id,
                "station_sequence": sequence,
                "station_id": station_id,
            }
            for sequence, station_id in enumerate(mn_ids, start=1)
        )
        print(f"routes {index}/{len(route_maps[0])}: {route_id} ({len(mn_ids)} stations)", flush=True)

    station_ids = set(station_candidates[0]) | set(station_candidates[1])
    stations: list[dict[str, object]] = []
    for station_id in sorted(station_ids):
        mn = choose_station(station_candidates[0].get(station_id) or station_candidates[1][station_id])
        en = choose_station(station_candidates[1].get(station_id) or station_candidates[0][station_id])
        preferred = mn if (mn.longitude, mn.latitude) != (0.0, 0.0) else en
        stations.append(
            {
                "station_id": station_id,
                "station_name_mn": mn.station_name,
                "station_name_en": localized_english(en.station_name, mn.station_name),
                "latitude": f"{preferred.latitude:.6f}",
                "longitude": f"{preferred.longitude:.6f}",
            }
        )

    routes = [
        {
            "route_id": route_id,
            "route_name_mn": route_maps[0][route_id].route_name,
            "route_name_en": localized_english(route_maps[1][route_id].route_name, route_maps[0][route_id].route_name),
            "endpoint_name_mn": route_maps[0][route_id].endpoint_name,
            "endpoint_name_en": localized_english(
                route_maps[1][route_id].endpoint_name,
                route_maps[0][route_id].endpoint_name,
            ),
        }
        for route_id in sorted(route_maps[0])
    ]
    return stations, routes, route_stations


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", default="app.uscc.mn")
    parser.add_argument("--port", type=int, default=63002)
    parser.add_argument("--timeout", type=float, default=10.0)
    parser.add_argument("--retries", type=int, default=3)
    parser.add_argument("--delay-seconds", type=float, default=0.05)
    parser.add_argument("--output-dir", type=Path, default=DEFAULT_OUTPUT_DIR)
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    with UBSmartBusClient(args.host, args.port, args.timeout, args.retries) as client:
        stations, routes, route_stations = collect(client, args.delay_seconds)

    write_tsv(
        args.output_dir / "ulaanbaatar_stations.tsv",
        ["station_id", "station_name_mn", "station_name_en", "latitude", "longitude"],
        stations,
    )
    write_tsv(
        args.output_dir / "ulaanbaatar_routes.tsv",
        ["route_id", "route_name_mn", "route_name_en", "endpoint_name_mn", "endpoint_name_en"],
        routes,
    )
    write_tsv(
        args.output_dir / "ulaanbaatar_route_stations.tsv",
        ["route_id", "station_sequence", "station_id"],
        route_stations,
    )
    write_database(args.output_dir / "ulaanbaatar_transit.sqlite", stations, routes, route_stations)
    print(
        {
            "stations": len(stations),
            "routes": len(routes),
            "route_stations": len(route_stations),
            "output_dir": str(args.output_dir),
        }
    )


if __name__ == "__main__":
    main()
