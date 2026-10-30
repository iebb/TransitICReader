"""Prepare reviewable development samples from an explicitly supplied private export.

This is intentionally an allowlist for the documented wallet layouts, not a
general-purpose anonymizer. Unknown families/record sizes/fields fail closed.
Never commit the input export. See docs/development/sample-data.md.
"""
import argparse
import datetime as dt
import json
import re
from pathlib import Path
from zoneinfo import ZoneInfo

from tools.paths import ROOT

UTC = dt.timezone.utc
JAPANESE = {"Japan Transit IC", "Suica", "ICOCA", "Hayakaken", "SUGOCA", "Manaca", "Nimoca"}
COPY_FIELDS = {
    "cardFamily", "technology", "identifierLabel", "pmm", "selectedAID", "systemCode",
    "balanceText", "balanceDetail", "region", "enhancedFeliCaDecoded", "issuingCity", "cardTypeStr",
    "color", "markerColor", "markerOuterColor", "markerShape", "design",
}
PUBLIC_TITLES = {
    "Detected Type", "Brand", "Card Type", "Issuing City", "Points", "Product Type",
    "Loaded Tickets", "Ticket", "Ticket Family", "Product Code", "Remaining Trips", "Ticket Status", "Route",
}
IDENTITY_TITLES = {"Card Number", "Card Number (IDm)", "WAON Number", "nanaco Number", "Edy ID",
                   "Media Serial Number", "Media Unicity", "Contract Serial Number"}
DATE_TITLES = {"Issue Date", "Expiry Date", "Last Use Date", "Sold At", "Card Valid Until", "Last Ticket Event"}


def encoded_date(value):
    if not 2000 <= value.year <= 2127:
        raise ValueError("Shifted date is outside the FeliCa calendar")
    return ((value.year - 2000) << 9) | (value.month << 5) | value.day


def packed_date(raw):
    return dt.datetime(2000 + (raw >> 9), (raw >> 5) & 15, raw & 31)


def shift_packed(data, start, shift):
    value = int.from_bytes(data[start:start + 2], "big")
    try:
        date = packed_date(value)
    except ValueError:
        return  # Invalid/empty calendar sentinels remain invalid.
    data[start:start + 2] = encoded_date(date + shift).to_bytes(2, "big")


def shift_bcd(data, start, shift, size=7):
    raw = data[start:start + size].hex()
    try:
        date = dt.datetime.strptime(raw, "%Y%m%d%H%M%S" if size == 7 else "%Y%m%d")
    except ValueError:
        return False
    data[start:start + size] = bytes.fromhex((date + shift).strftime("%Y%m%d%H%M%S" if size == 7 else "%Y%m%d"))
    return True


def mybi_mode(code):
    return (code in {870, 877, 905, 909, 887, 936, 940, 770}
            or any(code in range(a, b) for a, b in [(600, 620), (632, 637), (641, 661),
                   (711, 714), (776, 800), (901, 905), (913, 917), (925, 928)]))


def shift_korean_clock(data, shift, reference_date):
    code = int.from_bytes(data[9:11], "big")
    # Match production precedence: Mybi-specific layouts first, otherwise BCD
    # before packed33. Keep both boarding/alighting clocks coherent.
    if mybi_mode(code) and (code != 770 or not shift_bcd(data, 11, shift)):
        reference = reference_date.astimezone(ZoneInfo("Asia/Seoul")).replace(tzinfo=None)
        for offset in (11, 14):
            raw = int.from_bytes(data[offset:offset + 3], "big")
            if raw in (0, 0xFBF000):
                continue
            year_nibble = raw >> 20
            date = None
            for year in range(reference.year, max(1999, reference.year - 48), -1):
                if year & 15 != year_nibble:
                    continue
                try:
                    candidate = dt.datetime(year, (raw >> 16) & 15, (raw >> 11) & 31, (raw >> 6) & 31, raw & 63)
                except ValueError:
                    break
                if candidate <= reference:
                    date = candidate + shift
                    break
            if date is None:
                continue
            changed = ((date.year & 15) << 20) | (date.month << 16) | (date.day << 11) | (date.hour << 6) | date.minute
            data[offset:offset + 3] = changed.to_bytes(3, "big")
    elif code == 770:
        pass  # The successful BCD attempt above has already shifted the date.
    elif not shift_bcd(data, 11, shift):
        shift_packed(data, 11, shift)


class Anonymizer:
    def __init__(self, shift_days):
        if shift_days == 0:
            raise ValueError("Choose a nonzero private date shift")
        self.shift = dt.timedelta(days=shift_days)
        self.identifiers = {}
        self.counters = {}
        self.opaque_records = {}

    def identifier(self, value):
        clean = re.sub(r"[^A-Za-z0-9]", "", str(value)).upper()
        if clean not in self.identifiers:
            n = len(self.identifiers) + 1
            if re.fullmatch(r"J[A-Z][0-9]{14}", clean):
                fake = clean[:2] + str(n).zfill(14)
            else:
                fake = str(n).zfill(max(len(clean), 8))
            self.identifiers[clean] = fake
        return self.identifiers[clean]

    def prime_counters(self, records, family, card_index):
        spec = ((12, 3, "big") if family in JAPANESE else {
            "China T-Union": (0, 2, "big"), "T-money": (6, 4, "big"),
            "EZL / Cashbee": (6, 4, "big"), "NAMANE": (6, 4, "big"),
            "Rakuten Edy": (2, 2, "big"), "nanaco": (13, 2, "big"), "WAON": (13, 2, "little"),
        }.get(family))
        if spec is None:
            return
        start, size, order = spec
        values = {bytes.fromhex(raw)[start:start + size] for raw in records}
        for rank, value in enumerate(sorted(values, key=lambda v: int.from_bytes(v, order)), 1):
            self.counters[(card_index, size, order, value)] = rank

    def counter(self, data, start, size, card_index, order="big"):
        original = bytes(data[start:start + size])
        key = (card_index, size, order, original)
        if key not in self.counters:
            self.counters[key] = len([k for k in self.counters if k[:3] == key[:3]]) + 1
        data[start:start + size] = self.counters[key].to_bytes(size, order)

    def record(self, raw, family, kind, card_index, reference_date):
        source = bytes.fromhex(raw)
        data = bytearray(source)
        size = len(data)
        sizes = ({"rawTransactions": {16}, "rawTransitHistory": {16}} if family in JAPANESE else {
            "China T-Union": {"rawTransactions": {23}, "rawTransitHistory": {48}},
            "T-money": {"rawTransactions": {46}, "rawTransitHistory": {52}},
            "EZL / Cashbee": {"rawTransactions": {26}, "rawTransitHistory": {52}},
            "NAMANE": {"rawTransactions": {27}}, "Octopus": {"rawTransactions": {16}},
            "WAON": {"rawTransactions": {32}}, "nanaco": {"rawTransactions": {16}},
            "Rakuten Edy": {"rawTransactions": {16}},
        }.get(family, {}))
        if size not in sizes.get(kind, set()):
            raise ValueError(f"Unreviewed record: {family}, {kind}, {size}")
        if not data or all(x == 0 for x in data) or all(x == 255 for x in data):
            return raw.upper()
        if family in JAPANESE and size == 16:
            if kind == "rawTransactions":
                shift_packed(data, 4, self.shift)
                data[2:4] = bytes(2)  # Uninterpreted fields are not public fixtures.
                self.counter(data, 12, 3, card_index)
            else:
                shift_packed(data, 6, self.shift)
                data[4:6] = bytes(2)  # Gate device number.
        elif family == "China T-Union" and size == (23 if kind == "rawTransactions" else 48):
            if kind == "rawTransactions":
                self.counter(data, 0, 2, card_index)
                shift_bcd(data, 16, self.shift)
            else:
                shift_bcd(data, 25, self.shift)
                data[34:] = bytes(size - 34)
        elif family in {"T-money", "EZL / Cashbee"}:
            if kind == "rawTransitHistory" and size == 52:
                shift_korean_clock(data, self.shift, reference_date)
                keep = set([2])
                for a, b in [(5, 18), (19, 21), (22, 24), (36, 38), (40, 42)]:
                    keep.update(range(a, b))
                data = bytearray(v if i in keep else 0 for i, v in enumerate(data))
            elif kind == "rawTransactions" and size in {26, 46}:
                self.counter(data, 6, 4, card_index)
                data[14:26] = bytes(12)  # SAM identifiers and terminal counters.
                if size >= 33:
                    shift_bcd(data, 26, self.shift)
                    data[33:] = bytes(size - 33)
            else:
                raise ValueError(f"Unreviewed Korean layout: {family}, {kind}, {size}")
        elif family == "NAMANE" and size == 27 and kind == "rawTransactions":
            self.counter(data, 6, 4, card_index)
            data[14:] = bytes(size - 14)
        elif family == "Octopus" and size == 16 and kind == "rawTransactions":
            # Only this balance is decoded; unknown clock/identity bytes stay out.
            data = bytearray(10) + data[10:14] + bytearray(2)
            # Keep different source records distinct even when balances match.
            # This is a synthetic marker, not a decoded on-card field.
            key = (card_index, source)
            if key not in self.opaque_records:
                self.opaque_records[key] = len(self.opaque_records) + 1
            data[:4] = self.opaque_records[key].to_bytes(4, "big")
        elif family == "Rakuten Edy" and size == 16 and kind == "rawTransactions":
            clock = int.from_bytes(data[4:8], "big")
            days, seconds = clock >> 17, clock & 0x1FFFF
            if seconds < 86400:
                days += self.shift.days
                if days < 0:
                    raise ValueError("Edy clock cannot represent shifted date")
                data[4:8] = ((days << 17) | seconds).to_bytes(4, "big")
            data[1] = 0
            self.counter(data, 2, 2, card_index)
        elif family == "nanaco" and size == 16 and kind == "rawTransactions":
            clock = int.from_bytes(data[9:13], "big")
            try:
                date = dt.datetime(2000 + (clock >> 21), (clock >> 17) & 15, (clock >> 12) & 31,
                                   (clock >> 6) & 63, clock & 63) + self.shift
                changed = ((date.year - 2000) << 21) | (date.month << 17) | (date.day << 12) | (date.hour << 6) | date.minute
                data[9:13] = changed.to_bytes(4, "big")
            except ValueError:
                pass
            self.counter(data, 13, 2, card_index)
            data[15] = 0
        elif family == "WAON" and size == 32 and kind == "rawTransactions":
            packed = int.from_bytes(data[18:29], "big")
            def bits(offset, count):
                return (packed >> (88 - offset - count)) & ((1 << count) - 1)
            try:
                date = dt.datetime(2005 + bits(0, 5), bits(5, 4), bits(9, 5), bits(14, 5), bits(19, 6)) + self.shift
                if not 2005 <= date.year <= 2036:
                    raise ValueError("WAON clock cannot represent shifted date")
                clock = ((date.year - 2005) << 20) | (date.month << 16) | (date.day << 11) | (date.hour << 6) | date.minute
                packed = (packed & (((1 << 53) - 1) << 10)) | (clock << 63)
                data[18:29] = packed.to_bytes(11, "big")
            except ValueError as error:
                raise ValueError("Invalid WAON capture clock; manual review required") from error
            data[:13] = bytes(13)
            self.counter(data, 13, 2, card_index, order="little")
            data[15:17] = bytes(2)
            data[29:] = bytes(3)
        else:
            raise ValueError(f"Unreviewed record: {family}, {kind}, {size}")
        return data.hex().upper()


def shift_text(text, shift):
    def replace(match):
        date = dt.date.fromisoformat(match.group()) + shift
        return date.isoformat()
    return re.sub(r"\b20\d{2}-\d{2}-\d{2}\b", replace, text)


def base_card(index, family, technology, origin):
    return {
        "id": f"sample:{origin}:{index:02d}", "cardFamily": family, "technology": technology,
        "identifierLabel": "Sample identifier", "rawIdentifierValue": f"02FE{index:012d}",
        "identifierValue": f"02FE{index:012d}", "markerColor": {"red": 0.19, "green": 0.38, "blue": 0.73},
        "markerOuterColor": {"red": 1, "green": 1, "blue": 1}, "markerShape": "circle",
        "color": {"red": 0.19, "green": 0.38, "blue": 0.73}, "design": "classic",
        "imageFaceEnhancer": "none", "autoImageTextColors": False, "isUsingImage": False,
        "rawTransactions": [], "rawTransitHistory": [], "resultFields": [],
        "scannedAt": "2025-10-31T12:00:00Z", "order": index,
    }


def owner_wallet(source, *, shift_days):
    anonymizer = Anonymizer(shift_days)
    cards = []
    for index, original in enumerate(source["cards"], 1):
        family = original["cardFamily"]
        if family not in JAPANESE | {"China T-Union", "T-money", "EZL / Cashbee", "NAMANE", "Octopus", "WAON", "nanaco", "Rakuten Edy", "Lignes d'Azur card"}:
            raise ValueError(f"Unreviewed family: {family}")
        card = base_card(index, family, original["technology"], "owner")
        card.update({key: original[key] for key in COPY_FIELDS if key in original})
        for key in ("identifierValue", "rawIdentifierValue", "realSerialNumber"):
            if original.get(key):
                card[key] = anonymizer.identifier(original[key])
        for key in ("issueDateStr", "expiryDateStr"):
            if original.get(key):
                card[key] = shift_text(original[key], anonymizer.shift)
        scan = original["scannedAt"]
        date = (dt.datetime.fromtimestamp(978307200 + scan, UTC) if isinstance(scan, (int, float))
                else dt.datetime.fromisoformat(scan.replace("Z", "+00:00")))
        card["scannedAt"] = (date + anonymizer.shift).isoformat().replace("+00:00", "Z")
        for field in original.get("resultFields", []):
            title, value = field["title"], field["value"]
            if title in IDENTITY_TITLES:
                value = anonymizer.identifier(value)
            elif title in DATE_TITLES:
                value = shift_text(value, anonymizer.shift)
            elif title not in PUBLIC_TITLES:
                raise ValueError(f"Unreviewed field: {title}")
            card["resultFields"].append({"id": f"{title}|{value}", "title": title, "value": value})
        transactions = original.get("rawTransactions") or [r["rawData"] for r in original.get("transactions", [])]
        anonymizer.prime_counters(transactions, family, index)
        for kind, legacy in [("rawTransactions", "transactions"), ("rawTransitHistory", "transitHistory")]:
            records = original.get(kind, [])
            if not records and original.get(legacy):
                records = [row["rawData"] for row in original[legacy]]
            card[kind] = [anonymizer.record(raw, family, kind, index, date) for raw in records]
        cards.append(card)
    return {"version": 2, "cards": cards, "faceAssets": {}}


def mock_wallet():
    vectors = json.loads((ROOT / "tests/runtime/fixtures/card-parity.json").read_text())
    cards = []
    for index, (key, family) in enumerate([("ryuto", "Ryuto"), ("edy", "Rakuten Edy"), ("nanaco", "nanaco")], 1):
        row = vectors[key]
        card = base_card(index, family, "FeliCa", "mock")
        card.update(balanceText=f"JPY {row['balance']:,}", systemCode="8B5D" if key == "ryuto" else "FE00",
                    rawTransactions=[row["raw"]], customTitle=f"Mock {family}", scannedAt="2026-10-31T23:59:59Z")
        cards.append(card)
    return {"version": 2, "cards": cards, "faceAssets": {}}


def write_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + "\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", nargs="?", type=Path, help="Private owner wallet JSON; never copied into the repository")
    parser.add_argument("--shift-days-file", type=Path, help="Private text file containing a nonzero calendar-day offset; do not publish it")
    parser.add_argument("--output", type=Path, default=ROOT / "build/samples", help="Review directory (default: ignored build/samples)")
    args = parser.parse_args()
    if args.source:
        if not args.shift_days_file:
            parser.error("--shift-days-file is required with a private export")
        shift_days = int(args.shift_days_file.read_text().strip())
        write_json(args.output / "owner-wallet.json", owner_wallet(json.loads(args.source.read_text()), shift_days=shift_days))
    write_json(args.output / "mock-wallet.json", mock_wallet())


if __name__ == "__main__":
    main()
