"""Exercise production brand, currency, history adapter and wallet merge in Swift."""
import re
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

from tools.paths import ROOT


@unittest.skipUnless(shutil.which("swiftc"), "Requires Swift")
class AdditionalCardIntegrationTests(unittest.TestCase):
    def test_currency_time_zone_persisted_history_and_ring_merge(self):
        source = (ROOT / "ios/CardBal/NFC/NFCUtils.swift").read_text()
        brands = source[source.index("public enum ICCardRegion"):source.index("enum DeveloperModePreferences")]
        models = source[source.index("struct ResultField:"):source.index("struct TransactionDecoderRegistry")]
        registry = source[source.index("struct TransactionDecoderRegistry"):source.index("extension TransitTransaction")]
        data = source[source.index("extension Data {"):source.index("struct BERTLVNode")]
        digits = re.search(r"func defaultFractionDigits\(.*?^}", source, re.M | re.S).group()
        store = (ROOT / "ios/CardBal/Models/CardWalletStore.swift").read_text()
        merge = re.search(r"    private func mergeRawRecords\(.*?^    }", store, re.M | re.S).group().replace("private func", "func", 1)
        stubs = r'''
import Foundation
import os
struct SavedCardRecord { static func rawRecordHasContent(_ raw: String) -> Bool { !raw.isEmpty } }
enum JapaneseICDecoder { static func decodeTransaction(block: Data, context: [Data], index: Int, family: String, kind: RawHistoryKind, relatedContext: [Data]) -> TransitTransaction? { fatalError("Japan fallback used") } }
enum CityUnionDecoder { static func decodeTransitRecord(data: Data, index: Int) -> TransitTransaction? { fatalError("China fallback used") } }
enum TUnionDecoder {
 static func decodeTravelRecord(data: Data, index: Int) -> TransitTransaction? { fatalError("China fallback used") }
 static func decodePBOC(data: Data, index: Int, resolveTUnionTerminals: Bool) -> TransitTransaction? { fatalError("China fallback used") }
}
enum KSX6924Decoder {
 static func parseTransitHistory(_ data: Data, sfi: Int, recordIndex: Int, brand: ICCardBrand, logger: Logger) -> TransitTransaction? { fatalError("Korean fallback used") }
 static func parseSingleTransaction(_ data: Data, sfi: Int, recordIndex: Int, brand: ICCardBrand, logger: Logger) -> TransitTransaction? { fatalError("Korean fallback used") }
}
enum NAMANEDecoder { static func parseNAMANELog(_ data: Data, sfi: Int, recordIndex: Int, isNAMANE: Bool, logger: Logger) -> TransitTransaction? { fatalError("Korean fallback used") } }
'''
        main = r'''
precondition(ICCardBrand.from(family: "Snapper+") == .snapperPlus)
precondition(ICCardBrand.from(family: "Kartu Multi Trip") == .kmt)
precondition(ICCardBrand.snapperPlus.region.currencyCode == "NZD")
precondition(ICCardBrand.kmt.region.currencyCode == "IDR")
precondition(!ICCardBrand.snapperPlus.isKorean && !ICCardBrand.kmt.isJapan)
precondition(defaultFractionDigits(for: "NZD") == 2 && defaultFractionDigits(for: "IDR") == 0)
precondition(CardDateFormatting.issuerTimeZone(for: .snapperPlus)?.identifier == "Pacific/Auckland")
precondition(CardDateFormatting.issuerTimeZone(for: .kmt)?.identifier == "Asia/Jakarta")
precondition(SnapperPlusProtocol.normalizedSerial("01020304a5b6c7d8") == "0102 0304 A5B6 C7D8")
precondition(SnapperPlusProtocol.normalizedSerial("0000 0000 0000 0000") == nil)
precondition(SnapperPlusProtocol.normalizedSerial("FFFF FFFF FFFF FFFF") == nil)
var tx = Data(repeating: 0, count: 46)
tx[0] = 1; tx[1] = 0x2C
tx.replaceSubrange(26..<46, with: Data(repeating: 0xFF, count: 20))
tx.replaceSubrange(2..<6, with: Data([0, 0, 0x30, 0x39]))
tx.replaceSubrange(6..<10, with: Data([0xFF, 0xFF, 0xFF, 0xFF]))
tx.replaceSubrange(10..<14, with: Data([0, 0, 1, 0x13]))
var trip = Data(repeating: 0, count: 52)
trip[0] = 1; trip[1] = 0x32; trip[51] = 0x10
trip.replaceSubrange(13..<20, with: Data([0x20, 0x26, 1, 0x15, 8, 0x30, 0]))
let old = SnapperPlusProtocol.encodeHistory(transaction: tx, trip: nil, recordNumber: 1)!.hexString
let complete = SnapperPlusProtocol.encodeHistory(transaction: tx, trip: trip, recordNumber: 3)!.hexString
let reloaded = try JSONDecoder().decode([String].self, from: JSONEncoder().encode([complete]))
let decoded = TransactionDecoderRegistry.decode(raw: reloaded[0], family: "Snapper+", technology: "ISO7816", context: reloaded, at: 0)!
precondition(decoded.amount == Decimal(string: "-2.75") && decoded.balanceAfter == Decimal(string: "123.45"))
precondition(decoded.currencyCode == "NZD" && decoded.recordNumber == 4294967295)
precondition(decoded.date != nil && decoded.entryStationCode == nil && decoded.exitStationCode == nil)
precondition(decoded.time == "08:30:00")
precondition(CardDateFormatting.resolution(forTimeText: decoded.time) == .second)
let wallet = Wallet()
precondition(wallet.mergeRawRecords(existing: [old], incoming: [complete], family: "Snapper+", technology: "ISO7816", kind: .transactions) == [complete])
precondition(wallet.mergeRawRecords(existing: [complete], incoming: [old], family: "Snapper+", technology: "ISO7816", kind: .transactions) == [complete])
tx.replaceSubrange(10..<14, with: Data([0xFF, 0xFF, 0xFE, 0xED]))
let reversed = SnapperPlusProtocol.encodeHistory(transaction: tx, trip: nil, recordNumber: 1)!.hexString
let credit = TransactionDecoderRegistry.decode(raw: reversed, family: "Snapper+", technology: "ISO7816", context: [reversed], at: 0)!
precondition(credit.amount == Decimal(string: "2.75") && credit.category == .payment)
precondition(TransactionDecoderRegistry.decode(raw: String(repeating: "01", count: 16), family: "KMT", technology: "FeliCa", context: [], at: 0) == nil)
let opal = StoredValueProtocol.envelope(tag: 1, kind: 1, index: 0, data: Data(hexString: "785634F2479A60F0FF439CB0A4030000"))
let movedOpal = StoredValueProtocol.envelope(tag: 1, kind: 1, index: 7, data: Data(hexString: "785634F2479A60F0FF439CB0A4030000"))
precondition(wallet.mergeRawRecords(existing: [opal], incoming: [movedOpal], family: "Opal", technology: "DESFire", kind: .transactions) == [movedOpal])
let opalEvent = TransactionDecoderRegistry.decode(raw: opal, family: "Opal", technology: "DESFire", context: [opal], at: 0)!
precondition(opalEvent.currencyCode == "AUD" && !opalEvent.amountKnown && opalEvent.balanceAfter == Decimal(string: "-1.25"))
precondition(opalEvent.issuerTimeZone == "Australia/Sydney")
print("PASS new-card production integration")
'''
        with tempfile.TemporaryDirectory(prefix="cardbal-additional-") as directory:
            directory = Path(directory)
            program = directory / "main.swift"
            program.write_text(stubs + brands + models + registry + data + digits + "\nclass Wallet {\n" + merge + "\n}\n" + main)
            binary = directory / "test"
            build = subprocess.run(["swiftc", str(program), str(ROOT / "ios/CardBal/NFC/Profiles/SnapperPlusProtocol.swift"), str(ROOT / "ios/CardBal/Utils/DateFormatting.swift"), *[str(ROOT / "ios/CardBal/NFC/Profiles" / name) for name in ["AdditionalCardHistory.swift", "CEPASProtocol.swift", "CalypsoProtocol.swift", "StoredValueProtocol.swift"]], "-o", str(binary)], capture_output=True, text=True)
            self.assertEqual(build.returncode, 0, build.stdout + build.stderr)
            result = subprocess.run([str(binary)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("PASS", result.stdout)
