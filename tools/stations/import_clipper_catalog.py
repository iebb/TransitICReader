"""Convert FareBot's pinned Clipper MdST catalog to the app's JSON resource.

Usage: python3 tools/stations/import_clipper_catalog.py /path/to/farebot
Only the protobuf wire fields used by this catalog are decoded; no dependencies.
"""
import hashlib
import json
from pathlib import Path
import struct
import sys

REVISION = "dc09f6f014ea3675b64bcd38335b4b78d77fa374"
SOURCE = "base/src/commonMain/composeResources/files/clipper.mdst"
SOURCE_SHA256 = "e3b402e0c3bd2abc02dcd5959a309692f8b7e45d6d079701f5e8771608215f40"
ROOT = Path(__file__).resolve().parents[2]


def varint(data, offset):
    value = 0
    for shift in range(0, 70, 7):
        if offset >= len(data):
            raise ValueError("Truncated varint")
        byte = data[offset]
        offset += 1
        if shift == 63 and byte > 1:
            raise ValueError("Invalid varint")
        value |= (byte & 127) << shift
        if byte < 128:
            return value, offset
    raise ValueError("Invalid varint")


def message(data, offset):
    size, start = varint(data, offset)
    end = start + size
    if end > len(data):
        raise ValueError("Truncated message")
    return data[start:end], end


def fields(data):
    result = {}
    offset = 0
    while offset < len(data):
        tag, offset = varint(data, offset)
        if tag >> 3 == 0:
            raise ValueError("Invalid protobuf field number")
        wire = tag & 7
        if wire == 0:
            value, offset = varint(data, offset)
        elif wire == 2:
            value, offset = message(data, offset)
        elif wire == 5:
            if offset + 4 > len(data):
                raise ValueError("Truncated fixed32")
            value = struct.unpack_from("<f", data, offset)[0]
            offset += 4
        elif wire == 1:
            if offset + 8 > len(data):
                raise ValueError("Truncated fixed64")
            value = data[offset:offset + 8]
            offset += 8
        else:
            raise ValueError(f"Unsupported protobuf wire type {wire}")
        result.setdefault(tag >> 3, []).append(value)
    return result


def name(data):
    names = fields(data)
    return names.get(1, names.get(2, [b""]))[0].decode()


def convert(data):
    if len(data) < 13 or data[:8] != b"MdST\x00\x00\x00\x01":
        raise ValueError("Unsupported MdST header")
    stations_length = int.from_bytes(data[8:12], "big")
    header, offset = message(data, 12)
    header = fields(header)
    end = offset + stations_length
    if end > len(data):
        raise ValueError("Truncated station section")
    operators, lines, stations = {}, {}, {}
    for field, output in [(3, operators), (4, lines)]:
        for entry in header.get(field, []):
            entry = fields(entry)
            key, value = entry.get(1, [0])[0], fields(entry[2][0])
            output[str(key)] = {"name": name(value[3][0]), "mode": value.get(4, [0])[0]}
    while offset < end:
        station, offset = message(data[:end], offset)
        station = fields(station)
        identifier = station[1][0]
        stations[str(identifier)] = {
            "id": identifier, "name": name(station[8][0]),
            "latitude": station.get(4, [0])[0], "longitude": station.get(5, [0])[0],
        }
    if offset != end:
        raise ValueError("Invalid station section length")
    return {
        "version": 1, "sourceRevision": REVISION,
        "source": f"https://github.com/codebutler/farebot/blob/{REVISION}/{SOURCE}",
        "sourceSHA256": hashlib.sha256(data).hexdigest(),
        "notice": header.get(6, [b""])[0].decode(),
        "operators": operators, "lines": lines, "stations": stations,
    }


if __name__ == "__main__":
    import subprocess
    if len(sys.argv) != 2:
        raise SystemExit("Usage: python3 tools/stations/import_clipper_catalog.py /path/to/farebot")
    checkout = Path(sys.argv[1])
    revision = subprocess.check_output(["git", "-C", str(checkout), "rev-parse", "HEAD"], text=True).strip()
    if revision != REVISION:
        raise SystemExit(f"Expected FareBot {REVISION}, found {revision}")
    source_data = (checkout / SOURCE).read_bytes()
    if hashlib.sha256(source_data).hexdigest() != SOURCE_SHA256:
        raise SystemExit("Pinned FareBot catalog SHA-256 mismatch")
    catalog = convert(source_data)
    destination = ROOT / "data/stations/ClipperTransit.json"
    destination.write_text(json.dumps(catalog, ensure_ascii=True, indent=2, sort_keys=True) + "\n")
    print(f"Imported {len(catalog['stations'])} stations, {len(catalog['operators'])} operators, "
          f"{len(catalog['lines'])} lines into {destination}")
