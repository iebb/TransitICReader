"""Drive the production retail FeliCa decoders with invented RF callbacks."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

from tools.paths import ROOT


@unittest.skipUnless(shutil.which("swiftc"), "Requires Swift")
class RetailFeliCaOptionalMetadataTests(unittest.TestCase):
    def test_balance_guards_optional_fields_and_addressed_waon_pairs(self):
        stubs = r'''
import Foundation
enum PollRequest { case systemCode }
enum PollSlot { case max1 }
protocol NFCFeliCaTag {
    var currentIDm: Data { get }
    func polling(systemCode: Data, requestCode: PollRequest, timeSlot: PollSlot) async throws -> (Data, Data)
    func readWithoutEncryption(serviceCodeList: [Data], blockList: [Data]) async throws -> (Int, Int, [Data])
}
enum NFCTag { case feliCa(NFCFeliCaTag), other }
protocol TransitCardDecoder {
    static func canDecode(tag: NFCTag) async -> Bool
    static func decode(tag: NFCTag, scannedAt: Date) async throws -> TransitCardSnapshot
}
enum NFCTestError: Error { case unsupportedCard }
struct ResultField { let title: String; let value: String }
struct RawDataField { let title: String; let value: String }
struct RawDataSection { let title: String; let fields: [RawDataField] }
struct TransitCardSnapshot {
    let technology: String; let cardFamily: String; let identifierLabel: String; let identifierValue: String
    let rawIdentifierValue: String; let pmm: String?; let systemCode: String?; let selectedAID: String?
    let balanceText: String?; let balanceDetail: String?; let realSerialNumber: String?; let region: String?
    let resultFields: [ResultField]; let rawSections: [RawDataSection]
    let rawTransactions: [String]; let rawTransitHistory: [String]; let scannedAt: Date
}
extension Data { var hexString: String { map { String(format: "%02X", $0) }.joined() } }
func formatFeliCaIDm(_ idm: String) -> String { idm }
func formatCurrency(amount: Decimal, code: String, fractionDigits: Int) -> String { "\(code) \(amount)" }
final class TestTag: NFCFeliCaTag {
    let currentIDm = Data([1,2,3,4,5,6,7,8])
    var responses: [String: (Int, Int, [Data])] = [:]
    var selected = Data([0xFE, 0])
    var failPoll = false
    var requests: [String] = []
    func polling(systemCode: Data, requestCode: PollRequest, timeSlot: PollSlot) async throws -> (Data, Data) {
        precondition(systemCode == Data([0xFE, 0]))
        if failPoll { throw NFCTestError.unsupportedCard }
        return (Data(repeating: 0, count: 8), selected)
    }
    func readWithoutEncryption(serviceCodeList: [Data], blockList: [Data]) async throws -> (Int, Int, [Data]) {
        // Every service must be independently addressed, never a metadata batch.
        precondition(serviceCodeList.count == 1 && blockList.count == 1)
        precondition(blockList[0].count == 2 && blockList[0][0] == 0x80)
        let key = "\(serviceCodeList[0].hexString):\(blockList[0][1])"
        requests.append(key)
        guard let response = responses[key] else { throw NFCTestError.unsupportedCard }
        return response
    }
}
func block(_ first: UInt8 = 0) -> Data { var data = Data(repeating: 0, count: 16); data[0] = first; return data }
func fixture(_ service: String) -> TestTag {
    let tag = TestTag(); tag.responses["\(service):0"] = (0, 0, [block(123)]); return tag
}
func snapshot(_ decoder: TransitCardDecoder.Type, _ tag: TestTag) async throws -> TransitCardSnapshot {
    try await decoder.decode(tag: .feliCa(tag), scannedAt: Date(timeIntervalSince1970: 0))
}
func reject(_ decoder: TransitCardDecoder.Type, _ tag: TestTag) async {
    do { _ = try await snapshot(decoder, tag); preconditionFailure("Invalid balance or poll accepted") }
    catch {}
}
func field(_ card: TransitCardSnapshot, _ title: String) -> String? {
    card.resultFields.first(where: { $0.title == title })?.value
}
'''
        harness = r'''
@main struct Run {
static func main() async throws {
    let decoders: [(TransitCardDecoder.Type, String, String)] = [
        (EdyDecoder.self, "1713", "Edy ID"),
        (NanacoDecoder.self, "9755", "nanaco Number"),
        (WAONDecoder.self, "1768", "WAON Number")
    ]
    for (decoder, service, numberTitle) in decoders {
        let tag = fixture(service)
        let card = try await snapshot(decoder, tag)
        precondition(card.balanceText == "JPY 123" && card.rawTransactions.isEmpty)
        precondition(card.realSerialNumber == nil && card.identifierValue == tag.currentIDm.hexString)
        precondition(field(card, numberTitle) == nil && field(card, "Points") == nil)
        precondition(field(card, "Issue Date") == nil && field(card, "Last Use Date") == nil)
        for response in [(1, 0, [block()]), (0, 1, [block()]),
                         (0, 0, [Data(repeating: 0, count: 15)]),
                         (0, 0, [Data(repeating: 0, count: 17)]),
                         (0, 0, [block(), block()])] {
            let bad = fixture(service); bad.responses["\(service):0"] = response
            await reject(decoder, bad)
        }
        let wrongSystem = fixture(service); wrongSystem.selected = Data([0, 3])
        await reject(decoder, wrongSystem); precondition(wrongSystem.requests.isEmpty)
        let noPoll = fixture(service); noPoll.failPoll = true
        await reject(decoder, noPoll); precondition(noPoll.requests.isEmpty)
        // A readable but zero/FF/non-BCD number must never become a stable ID.
        let numberService = service == "1713" ? "0B11" : service == "9755" ? "8B55" : "4F68"
        for value: UInt8 in [0, 0xFF, 0xAB] {
            let missingID = fixture(service)
            missingID.responses["\(numberService):0"] = (0, 0, [Data(repeating: value, count: 16)])
            let partial = try await snapshot(decoder, missingID)
            precondition(partial.realSerialNumber == nil && field(partial, numberTitle) == nil)
        }
    }
    // Metadata succeeds independently without a number. A real zero-point
    // block remains zero points, while an impossible date is omitted.
    let nanaco = fixture("9755")
    nanaco.responses["0B56:1"] = (0, 0, [block()])
    var meta = block()
    let valid: UInt16 = UInt16((26 << 9) | (2 << 5) | 28)
    let invalid: UInt16 = UInt16((26 << 9) | (2 << 5) | 30)
    meta[0] = UInt8(valid >> 8); meta[1] = UInt8(valid & 255)
    meta[4] = UInt8(invalid >> 8); meta[5] = UInt8(invalid & 255)
    nanaco.responses["CB55:0"] = (0, 0, [meta])
    let nc = try await snapshot(NanacoDecoder.self, nanaco)
    precondition(field(nc, "Points") == "0 pts" && field(nc, "Last Use Date") == "2026-02-28")
    precondition(field(nc, "Issue Date") == nil && nc.realSerialNumber == nil)
    // Valid BCD metadata and the original big-endian packed Edy issue clock.
    let edy = fixture("1713")
    var number = block()
    number.replaceSubrange(2..<10, with: [0x12,0x34,0x56,0x78,0x90,0x12,0x34,0x56])
    let clock: UInt32 = (1 << 17) | 3
    for i in 0..<4 { number[10+i] = UInt8((clock >> ((3-i)*8)) & 255) }
    edy.responses["0B11:0"] = (0, 0, [number])
    let ec = try await snapshot(EdyDecoder.self, edy)
    precondition(ec.realSerialNumber == "1234567890123456")
    precondition(field(ec, "Issue Date") == "2000-01-02 00:00:03 JST")
    number[11] |= 1; number[12] = 0xFF; number[13] = 0xFF // invalid seconds of day
    edy.responses["0B11:0"] = (0, 0, [number])
    let edyInvalid = try await snapshot(EdyDecoder.self, edy)
    precondition(field(edyInvalid, "Issue Date") == nil && edyInvalid.realSerialNumber != nil)
    // Edy and nanaco retain their original six/five history record limits.
    for (decoder, balance, history, limit) in [(EdyDecoder.self as TransitCardDecoder.Type, "1713", "0F17", 6),
                                               (NanacoDecoder.self as TransitCardDecoder.Type, "9755", "4F56", 5)] {
        let tag = fixture(balance)
        for index in 0..<limit { tag.responses["\(history):\(index)"] = (0, 0, [block(UInt8(index+1))]) }
        let card = try await snapshot(decoder, tag)
        precondition(card.rawTransactions.count == limit)
        precondition(tag.requests.filter { $0.hasPrefix(history + ":") }.count == limit)
    }
    // Read all three addressed WAON pairs; missing/short partners do not shift
    // the surviving halves into a fabricated 32-byte transaction.
    let waon = fixture("1768")
    waon.responses["0B68:0"] = (0, 0, [block(0xAA)])
    waon.responses["0B68:1"] = (0, 1, [block(0xBB)])
    waon.responses["0B68:2"] = (0, 0, [block(0xCC)])
    waon.responses["0B68:3"] = (0, 0, [block(0xDD)])
    waon.responses["0B68:4"] = (0, 0, [block(0xEE)])
    waon.responses["0B68:5"] = (0, 0, [Data(repeating: 0xFF, count: 15)])
    let wc = try await snapshot(WAONDecoder.self, waon)
    precondition(wc.rawTransactions == [(block(0xCC) + block(0xDD)).hexString])
    precondition(waon.requests.filter { $0.hasPrefix("0B68:") } == (0..<6).map { "0B68:\($0)" })
    print("PASS retail FeliCa optional metadata and exact addressed read guards")
}
}
'''
        files = [
            "ios/CardBal/NFC/Profiles/RetailFeliCaRead.swift",
            "ios/CardBal/NFC/Decoders/EdyDecoder.swift",
            "ios/CardBal/NFC/Decoders/NanacoDecoder.swift",
            "ios/CardBal/NFC/Decoders/WAONDecoder.swift",
        ]
        production = "\n".join((ROOT / name).read_text().replace("import CoreNFC", "").replace("CardTag", "NFCTag").replace("FeliCaCard", "NFCFeliCaTag") for name in files)
        with tempfile.TemporaryDirectory(prefix="cardbal-retail-felica-") as directory:
            path = Path(directory)
            source = path / "main.swift"
            source.write_text(stubs + production + harness)
            build = subprocess.run(["swiftc", "-parse-as-library", str(source), "-o", str(path / "test")], capture_output=True, text=True)
            self.assertEqual(build.returncode, 0, build.stdout + build.stderr)
            result = subprocess.run([str(path / "test")], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("PASS", result.stdout)
