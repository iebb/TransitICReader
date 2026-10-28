"""Execute the production Swift station resolver and record decoders on macOS."""

import contextlib
import json
import re
import shutil
import sqlite3
import subprocess
import tempfile
import unittest
from pathlib import Path

from tools.paths import ROOT


@unittest.skipUnless(shutil.which("swiftc"), "Requires the Swift toolchain")
class TUnionStationRuntimeTests(unittest.TestCase):
    def test_exact_terminal_fallbacks_and_station_prefix_precedence(self):
        source = (ROOT / "ios/CardBal/NFC/Decoders/TUnionDecoder.swift").read_text()
        catalog = source[source.index("struct TUnionCityDatabase {"):].replace("Bundle.main.url(", "resourceURL(")
        methods = []
        for name in ("decodePBOC", "decodeTravelRecord", "decodePBOCType", "decodeTravelType", "formatBCDTime"):
            match = re.search(r"^    (?:private )?static func " + name + r"\(.*?^    }", source, re.M | re.S)
            self.assertIsNotNone(match, name)
            methods.append(match.group())
        adapters = r'''
import Foundation
import SQLite3
func resourceURL(forResource name: String, withExtension ext: String) -> URL? {
    let path = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent(name + "." + ext)
    return FileManager.default.fileExists(atPath: path.path) ? path : nil
}
enum TransactionCategory { case topUp, purchase, adjustment, refund, unknown, busOn, trainOn, busOff, trainOff, bus, train }
enum CardBrand { case tUnion }
enum CardDateFormatting {
    static func parseCompactDateTime(_ text: String, format: String, brand: CardBrand) -> Date? { nil }
}
struct TransitTransaction {
    let date: Date?
    let time: String?
    let amount: Decimal
    let terminalID: String
    let type: String
    let category: TransactionCategory
    let balanceAfter: Decimal?
    let location: String?
    var entryStation: String? = nil
    var exitStation: String? = nil
    var entryStationCode: String? = nil
    var exitStationCode: String? = nil
    let rawData: String
    let recordNumber: Int
}
extension Data {
    var hexString: String { map { String(format: "%02X", $0) }.joined() }
    init(hex: String) {
        self.init(stride(from: 0, to: hex.count, by: 2).map { offset in
            UInt8(hex[hex.index(hex.startIndex, offsetBy: offset)..<hex.index(hex.startIndex, offsetBy: offset + 2)], radix: 16)!
        })
    }
}
'''
        main = r'''
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    precondition(condition(), message)
}
check(TUnionCityDatabase.lookupStationKey(cityID: "3320", stationID: "01010000000000") == "33200101", "Ningbo short code")
check(TUnionCityDatabase.lookupStationName(cityID: "3450", stationID: "31130000000000") == "仙居南", "Taizhou missing rail code")
check(TUnionCityDatabase.lookupTerminalStation(recordKind: "18", terminalID: "413101784816")?.cityID == "3310", "PBOC exact lookup")
check(TUnionCityDatabase.lookupTerminalStation(recordKind: "18", terminalID: "413101784817") == nil, "Neighboring gate guessed")
check(TUnionCityDatabase.lookupTerminalStation(recordKind: "18", terminalID: "41310178481600") == nil, "Terminal prefix accepted")
check(TUnionCityDatabase.lookupTerminalStation(recordKind: "18", terminalID: "AABBCCDDEEFF") == nil, "Ambiguous city guessed")
check(TUnionCityDatabase.lookupTerminalStation(recordKind: "18", terminalID: "aabbccddeeff", cityID: "3310")?.name == "杭州市站", "City filtering or case normalization")
check(TUnionCityDatabase.lookupTerminalStation(recordKind: "18", terminalID: "413101784816", cityID: "3320") == nil, "Wrong city matched")
let brt = TUnionCityDatabase.lookupTravelStation(cityID: "3610", stationID: "FFFFFFFFFFFFFF", terminalID: "0000413106085352")
check(brt?.name == "铜陵新村" && brt?.stationKey == nil, "Terminal-only BRT invented a map code")
let priority = TUnionCityDatabase.lookupTravelStation(cityID: "3320", stationID: "01010000000000", terminalID: "0000413106085352")
check(priority?.name == "高桥西", "Terminal overrode exact station prefix")
check(TUnionCityDatabase.lookupTravelStation(cityID: "3310", stationID: "FFFFFFFFFFFFFF", terminalID: "0000413101784816")?.name == "市民中心", "Padded PBOC terminal fallback")
check(TUnionCityDatabase.lookupTravelStation(cityID: "3310", stationID: "FFFFFFFFFFFFFF", terminalID: "FFFF413101784816") == nil, "Nonzero terminal prefix truncated")
var pboc = Data(repeating: 0, count: 23)
pboc[9] = 0x06
pboc.replaceSubrange(10..<16, with: Data(hex: "413101784816"))
check(TUnionDecoder.decodePBOC(data: pboc, index: 0)?.location == "杭州市 • 市民中心", "PBOC station not surfaced")
check(TUnionDecoder.decodePBOC(data: pboc, index: 0, resolveTUnionTerminals: false)?.location == nil, "Another card family used T-Union terminals")
pboc[9] = 0x02
check(TUnionDecoder.decodePBOC(data: pboc, index: 0)?.location == nil, "Top-up mislabeled as station purchase")
var travel = Data(repeating: 0, count: 48)
travel[0] = 0x03
travel[9] = 0x02
travel.replaceSubrange(1..<9, with: Data(hex: "0000413106085352"))
travel.replaceSubrange(10..<17, with: Data(hex: "FFFFFFFFFFFFFF"))
travel.replaceSubrange(32..<34, with: Data(hex: "3610"))
let trip = TUnionDecoder.decodeTravelRecord(data: travel, index: 0)
check(trip?.entryStation == "铜陵新村" && trip?.entryStationCode == nil, "BRT decoder output")
print("PASS: production T-Union station and terminal decoding")
'''
        with tempfile.TemporaryDirectory(prefix="cardbal-tunion-") as temporary:
            directory = Path(temporary)
            (directory / "TUnionLineStations.json").write_text(json.dumps({"33200101": "高桥西", "34503113": "仙居南"}))
            (directory / "TUnionCityCodes.json").write_text(json.dumps({"3310": "杭州市", "3610": "合肥市"}))
            with contextlib.closing(sqlite3.connect(directory / "cardbal_transit.sqlite")) as connection, connection:
                connection.execute("CREATE TABLE tunion_terminal_stations (record_kind, city_id, terminal_code, station_name, station_key)")
                connection.executemany("INSERT INTO tunion_terminal_stations VALUES (?, ?, ?, ?, ?)", [
                    ("18", "3310", "413101784816", "市民中心", "331000040011"),
                    ("1e", "3610", "0000413106085352", "铜陵新村", None),
                    ("18", "3310", "AABBCCDDEEFF", "杭州市站", None),
                    ("18", "3320", "AABBCCDDEEFF", "宁波市站", None),
                ])
            swift = directory / "main.swift"
            swift.write_text(adapters + catalog + "\nstruct TUnionDecoder {\n" + "\n".join(methods) + "\n}\n" + main)
            binary = directory / "test-runtime"
            build = subprocess.run(["swiftc", str(swift), "-o", str(binary)], capture_output=True, text=True)
            self.assertEqual(build.returncode, 0, build.stdout + build.stderr)
            result = subprocess.run([str(binary), temporary], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("PASS:", result.stdout)


if __name__ == "__main__":
    unittest.main()
