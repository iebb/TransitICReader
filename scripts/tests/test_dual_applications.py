"""Run production Chinese readers, application history and wallet upserts.

Core NFC transport and platform UI are adapted for macOS. APDU replies are
synthetic; these tests do not substitute for RF testing on physical cards.
"""
import re
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def method(source, name):
    match = re.search(r"^    (?:private )?func " + name + r"\(.*?^    }", source, re.M | re.S)
    if not match:
        raise AssertionError(name)
    return match.group().replace("private func", "func", 1)


@unittest.skipUnless(shutil.which("swiftc"), "Requires Swift")
class DualApplicationTests(unittest.TestCase):
    def test_readers_history_and_partial_wallet_rescans(self):
        utils = (ROOT / "CardBal/NFC/NFCUtils.swift").read_text()
        models = utils[utils.index("struct ResultField:"):utils.index("struct TransactionDecoderRegistry")]
        models += utils[utils.index("struct TransitCardSnapshot:"):utils.index("enum StatusKind")]
        models += utils[utils.index("extension Data {"):utils.index("struct BERTLVNode")]
        saved = (ROOT / "CardBal/Models/SavedCardRecord.swift").read_text()
        models += saved[saved.index("struct SavedCardField:"):saved.index("struct SavedCardColor:")]
        decoder = (ROOT / "CardBal/NFC/Decoders/TUnionDecoder.swift").read_text().replace("import CoreNFC", "")
        decoder = decoder.replace("Bundle.main.url(", "resourceURL(")
        applications = (ROOT / "CardBal/Models/TransitApplications.swift").read_text()
        store = (ROOT / "CardBal/Models/CardWalletStore.swift").read_text()
        upsert = method(store, "upsert")
        content = (ROOT / "CardBal/ContentView.swift").read_text()
        storage_id = re.search(r"    var storageIdentifier: String \{.*?^    }", content, re.M | re.S).group()
        adapters = r'''
import Foundation
import SQLite3
func resourceURL(forResource name: String, withExtension ext: String) -> URL? {
    let root = URL(fileURLWithPath: CommandLine.arguments[1])
    return ["StationAssets", "CardBal/Resources"].map { root.appendingPathComponent($0 + "/" + name + "." + ext) }
        .first { FileManager.default.fileExists(atPath: $0.path) }
}
enum NFCTestError: Error { case unsupportedCard }
protocol TransitCardDecoder {
    static func canDecode(tag: NFCTag) async -> Bool
    static func decode(tag: NFCTag, scannedAt: Date) async throws -> TransitCardSnapshot
}
enum NFCTag { case iso7816(NFCISO7816Tag), other }
struct NFCISO7816APDU {
    let instructionClass: UInt8, instructionCode: UInt8, p1Parameter: UInt8, p2Parameter: UInt8
    let data: Data
    let expectedResponseLength: Int
}
struct NFCISO7816ResponseAPDU { let statusWord1: UInt8, statusWord2: UInt8; let payload: Data? }
final class NFCISO7816Tag {
    let identifier = Data(hexString: "01020304")
    var initialSelectedAID = CityUnionDecoder.applicationAID
    var available = Set([CityUnionDecoder.applicationAID, TUnionDecoder.applicationAID])
    var selected = ""
    var selectedAIDs: [String] = []
    var files: [String: [Int: [Data]]] = [:]
    var info: [String: Data] = [:]
    var failBalances = false
    var wrongLengthOnce = false
    var incorrectSuccessStatus = false
    var correctedLength: Int?
    func sendCommand(apdu: NFCISO7816APDU) async throws -> (Data, UInt8, UInt8) {
        if incorrectSuccessStatus { return (Data([1,2,3,4]), 0x90, 0x01) }
        if wrongLengthOnce {
            wrongLengthOnce = false
            return (Data(), 0x6C, 0)
        }
        correctedLength = apdu.expectedResponseLength
        if apdu.instructionCode == 0xA4 && apdu.p1Parameter == 4 {
            let aid = apdu.data.hexString
            selectedAIDs.append(aid)
            guard available.contains(aid) else { return (Data(), 0x6A, 0x82) }
            selected = aid
            return (Data(), 0x90, 0)
        }
        if apdu.instructionCode == 0x5C, !failBalances {
            if apdu.p1Parameter == 5 { return (Data(repeating: 0, count: 16), 0x90, 0) }
            return (apdu.p1Parameter == 0 ? Data(hexString: "00000C80") : Data(repeating: 0, count: 4), 0x90, 0)
        }
        if apdu.instructionCode == 0xB0, apdu.p1Parameter == 0x95, let data = info[selected] { return (data, 0x90, 0) }
        if apdu.instructionCode == 0xB2 {
            let sfi = Int(apdu.p2Parameter >> 3), index = Int(apdu.p1Parameter) - 1
            if let records = files[selected]?[sfi], records.indices.contains(index) { return (records[index], 0x90, 0) }
        }
        return (Data(), 0x6A, 0x83)
    }
}
enum ICCardBrand {
    case tUnion, octopus, other
    static func from(family: String) -> Self { family.contains("Octopus") ? .octopus : family.contains("Union") ? .tUnion : .other }
    var region: Region { Region(currencyCode: self == .octopus ? "HKD" : "CNY") }
}
struct Region { let currencyCode: String }
enum CardDateFormatting {
    static func parseCompactDateTime(_ text: String, format: String, brand: ICCardBrand) -> Date? {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "Asia/Shanghai"); f.dateFormat = format; f.isLenient = false
        return f.date(from: text)
    }
}
func formatCurrency(amount: Decimal, code: String, fractionDigits: Int) -> String { "\(code) \(amount)" }
struct TransactionDecoderRegistry {
    static func decode(raw: String, family: String, technology: String, context: [String], at index: Int,
                       kind: RawHistoryKind = .transactions, relatedContext: [String] = []) -> TransitTransaction? {
        let data = Data(hexString: raw)
        if technology == "FeliCa" {
            precondition(family == "Octopus", "Wrong family dispatched to FeliCa history")
            return TransitTransaction(date: nil, amount: -5, terminalID: nil, type: "Octopus", rawData: raw)
        }
        if data.count == 23 { return TUnionDecoder.decodePBOC(data: data, index: index) }
        return TUnionDecoder.decodeTravelRecord(data: data, index: index)
    }
}
struct SavedCardRecord: Codable {
    var id: String
    var technology: String, cardFamily: String, identifierLabel: String, identifierValue: String, rawIdentifierValue: String
    var pmm: String?, systemCode: String?, selectedAID: String?, balanceText: String?, balanceDetail: String?, realSerialNumber: String?, region: String?
    var resultFields: [SavedCardField], rawTransactions: [String], rawTransitHistory: [String]
    var scannedAt: Date
    var applications: [TransitApplication]?
    var enhancedFeliCaDecoded = false
    var issuingCity: String?, cardTypeStr: String?, issueDateStr: String?, expiryDateStr: String?
    var customTitle: String?
    init(snapshot: TransitCardSnapshot) {
        id = snapshot.storageIdentifier; technology = snapshot.technology; cardFamily = snapshot.cardFamily
        identifierLabel = snapshot.identifierLabel; identifierValue = snapshot.identifierValue; rawIdentifierValue = snapshot.rawIdentifierValue
        pmm = snapshot.pmm; systemCode = snapshot.systemCode; selectedAID = snapshot.selectedAID
        balanceText = snapshot.balanceText; balanceDetail = snapshot.balanceDetail; realSerialNumber = snapshot.realSerialNumber; region = snapshot.region
        resultFields = snapshot.resultFields.map(SavedCardField.init); rawTransactions = snapshot.rawTransactions; rawTransitHistory = snapshot.rawTransitHistory
        scannedAt = snapshot.scannedAt; applications = snapshot.applications
    }
}
final class Wallet {
    var cards: [SavedCardRecord] = []
    func autoApplyPresetIfMatching(id: String) {}
    func markMapDataChanged() {}
    func save() {}
    func mergeRawRecords(existing: [String], incoming: [String], family: String, technology: String, kind: RawHistoryKind) -> [String] { existing + incoming }
'''+upsert+'''\n}\nextension TransitCardSnapshot {\n'''+storage_id+'''\n}\n'''
        main = r'''
func check(_ condition: @autoclosure () -> Bool, _ message: String) { precondition(condition(), message) }
func record(_ data: Data, sfi: Int = 0x18, index: Int = 1, kind: TransitApplicationRecord.Kind = .transaction) -> TransitApplicationRecord {
    TransitApplicationRecord(kind: kind, sfi: sfi, index: index, hex: data.hexString)
}
func snapshot(_ aid: String?, serial: String?, date: Double = 100, balance: String? = "CNY 32", records: [TransitApplicationRecord] = []) -> TransitCardSnapshot {
    var snapshot = TransitCardSnapshot(technology: aid == nil ? "FeliCa" : "ISO7816", cardFamily: aid == nil ? "Octopus" : aid == CityUnionDecoder.applicationAID ? "City Union" : "China T-Union",
        identifierLabel: "UID", identifierValue: "01020304", rawIdentifierValue: aid == nil ? "0102030405060708" : "01020304", pmm: nil,
        systemCode: aid == nil ? "8008" : nil, selectedAID: aid, balanceText: balance, balanceDetail: nil, realSerialNumber: serial, region: nil,
        resultFields: [], rawSections: [], rawTransactions: records.filter { $0.kind == .transaction }.map(\.hex),
        rawTransitHistory: records.filter { $0.kind == .transit }.map(\.hex), scannedAt: Date(timeIntervalSince1970: date))
    snapshot.applications = [TransitApplication(snapshot: snapshot, records: records)]
    return snapshot
}
@main struct Tests {
    static func main() async throws {
        let cu = CityUnionDecoder.applicationAID, tu = TUnionDecoder.applicationAID
        var purchase = Data(repeating: 0, count: 23)
        purchase[1] = 1; purchase[8] = 200; purchase[9] = 6
        purchase.replaceSubrange(10..<16, with: Data(hexString: "200011011101"))
        purchase.replaceSubrange(16..<23, with: Data(hexString: "20260102120102"))
        var duplicate = purchase; duplicate[1] = 9
        var travel = Data(repeating: 0, count: 48)
        travel[0] = 3; travel[9] = 1; travel[20] = 200
        travel.replaceSubrange(1..<9, with: Data(hexString: "0000200011011101"))
        travel.replaceSubrange(10..<17, with: Data(hexString: "00010011000000"))
        travel.replaceSubrange(25..<32, with: Data(hexString: "20260102120102"))
        travel.replaceSubrange(32..<34, with: Data(hexString: "2900"))
        let local = snapshot(cu, serial: "12345", records: [record(purchase)])
        let national = snapshot(tu, serial: "3100000000000000001", records: [record(duplicate), record(travel, sfi: 0x1E, kind: .transit)])
        let dual = TransitCardSnapshot.combining([local, national])!
        check(dual.applications?.count == 2, "Two ISO applications collapsed")
        check(dual.balanceText == national.balanceText, "Shanghai purses added")
        check(dual.transactions.count == 1, "CU/TU duplicate purchase not reconciled")
        check(dual.transactions[0].entryStation == "莘庄", "Travel detail not joined to purchase")
        check(dual.transactions[0].sourceRecordIDs?.count == 2, "Duplicate evidence lost")
        check(dual.transitHistory.count == 1, "Travel and purchase shown twice")
        check(dual.transitHistory[0].sourceRecordIDs?.count == 3, "Correlated transit evidence lost")
        var ambiguous = national.applications![0]
        var anotherTravel = travel; anotherTravel[47] = 1
        ambiguous.records.append(record(anotherTravel, sfi: 0x1E, index: 2, kind: .transit))
        check(TransitApplicationHistory.decode([local.applications![0], ambiguous], kind: .transit).count == 3, "Ambiguous travel match guessed")
        var wrong = national.applications![0]
        var wrongAmount = travel; wrongAmount[20] = 199
        wrong.records = [record(wrongAmount, sfi: 0x1E, kind: .transit)]
        check(TransitApplicationHistory.decode([local.applications![0], wrong], kind: .transit).count == 2, "Different fares joined")
        var sameFile = local.applications![0]; sameFile.records.append(record(duplicate, index: 2))
        check(TransitApplicationHistory.decode([sameFile], kind: .transactions).count == 2, "Repeated real purchases lost")
        check(CityUnionStationDatabase.lookup(terminalID: "200011011101", date: Date(timeIntervalSince1970: 1_000_000_000)) == nil, "Pre-2017 bus mapped to metro")
        var aux = Data(repeating: 0, count: 16); aux[0] = 1
        aux.replaceSubrange(1..<6, with: purchase.subdata(in: 17..<22))
        aux.replaceSubrange(6..<9, with: purchase.subdata(in: 13..<16))
        let entryAux = record(aux, sfi: 0x11, kind: .auxiliary)
        let exitAux = record(aux, sfi: 0x11, index: 2, kind: .auxiliary)
        let entry = CityUnionDecoder.decodeTransitRecord(data: purchase, index: 0, auxiliary: [entryAux])!
        check(entry.entryStation == "莘庄" && entry.entryStationCode == "290000010011", "CU auxiliary entry station")
        check(CityUnionDecoder.decodeTransitRecord(data: purchase, index: 0, auxiliary: [entryAux, exitAux])?.entryStation == nil, "Conflicting CU direction guessed")
        let octopus = snapshot(nil, serial: nil, balance: "HKD 50", records: [record(Data(repeating: 1, count: 16), sfi: 0)])
        let mixed = TransitCardSnapshot.combining([octopus, national])!
        check(mixed.balanceText == "HKD 50", "HKD and CNY added")
        check(Set(mixed.transactions.compactMap(\.currencyCode)) == ["HKD", "CNY"], "Currency lost in dual history")
        check(mixed.storageIdentifier == octopus.storageIdentifier, "Dual scan created different Octopus wallet identity")
        let wallet = Wallet()
        wallet.upsert(snapshot: local)
        wallet.cards[0].customTitle = "My Shanghai card"
        wallet.upsert(snapshot: dual)
        wallet.upsert(snapshot: snapshot(cu, serial: "12345", date: 200, balance: "CNY 30"))
        check(wallet.cards.count == 1 && wallet.cards[0].customTitle == "My Shanghai card", "Alias rescan split or reset card")
        check(wallet.cards[0].applications?.count == 2, "Partial CU scan removed TU")
        check(wallet.cards[0].balanceText == "CNY 30", "Old TU balance replaced newer CU balance")
        wallet.upsert(snapshot: snapshot(tu, serial: "3100000000000000001", date: 300, balance: nil))
        check(wallet.cards[0].balanceText == "CNY 30", "Failed balance read became latest balance")
        check(wallet.cards[0].applications?.first(where: \.isTUnion)?.records.count == 2, "Partial scan removed TU history")
        wallet.upsert(snapshot: snapshot(tu, serial: nil, date: 350, balance: nil))
        check(wallet.cards.count == 1, "Stable UID failed to match a partial metadata read")
        check(wallet.cards[0].applications?.first(where: \.isTUnion)?.serialNumber == "3100000000000000001", "Partial metadata erased known application number")
        let encoded = try JSONEncoder().encode(wallet.cards[0])
        let restored = try JSONDecoder().decode(SavedCardRecord.self, from: encoded)
        check(restored.applications == wallet.cards[0].applications, "Application/file metadata missing after persistence")
        let merged = TransitApplication.merge(existing: snapshot(tu, serial: "X", date: 100, records: [record(purchase)]).applications!,
                                             incoming: snapshot(tu, serial: "X", date: 200, records: [record(duplicate)]).applications!)
        check(merged[0].records.count == 2, "Same ring slot erased older history")
        let octopusWallet = Wallet(); octopusWallet.upsert(snapshot: octopus); octopusWallet.upsert(snapshot: mixed)
        octopusWallet.upsert(snapshot: snapshot(nil, serial: nil, date: 400, balance: "HKD 45"))
        check(octopusWallet.cards.count == 1 && octopusWallet.cards[0].applications?.count == 2, "Octopus rescan removed mainland history")
        var legacyMixed = SavedCardRecord(snapshot: mixed)
        legacyMixed.applications = nil; legacyMixed.id = "Dual Mode|0102030405060708"
        legacyMixed.selectedAID = tu; legacyMixed.realSerialNumber = "3100000000000000001"
        let legacyWallet = Wallet(); legacyWallet.cards = [legacyMixed]
        legacyWallet.upsert(snapshot: octopus)
        check(legacyWallet.cards.count == 1 && legacyWallet.cards[0].applications?.count == 2, "Old flattened dual card was split on rescan")
        check(legacyWallet.cards[0].applications?.first(where: \.isTUnion)?.records.count == 2, "Old flattened mainland records lost")
        for initial in [cu, tu] {
            let transport = NFCISO7816Tag(); transport.initialSelectedAID = initial
            var infoCU = Data(repeating: 0, count: 30); infoCU.replaceSubrange(2..<4, with: Data(hexString: "2000")); infoCU[19] = 1
            var infoTU = infoCU; infoTU.replaceSubrange(2..<4, with: Data(hexString: "2900"))
            infoTU.replaceSubrange(10..<20, with: Data(hexString: "03100000000000000001"))
            transport.info = [cu: infoCU, tu: infoTU]
            transport.files = [cu: [0x18: [purchase], 0x06: [duplicate], 0x11: [aux]], tu: [0x18: [duplicate], 0x1E: [travel]]]
            let scanned = try await ChineseTransitDecoder.decode(tag: .iso7816(transport), scannedAt: Date())
            check(scanned.applications?.count == 2 && Set(transport.selectedAIDs) == [cu, tu], "Initial AID prevented second application read")
            check(scanned.applications?.first(where: \.isCityUnion)?.records.contains(where: { $0.sfi == 6 }) == true, "Shanghai extra file omitted")
            transport.available = [cu]; transport.selectedAIDs = []
            let partial = try await ChineseTransitDecoder.decode(tag: .iso7816(transport), scannedAt: Date())
            check(partial.applications?.count == 1 && partial.applications?[0].isCityUnion == true, "Unsupported TU prevented CU result")
        }
        let status = NFCISO7816Tag(); status.incorrectSuccessStatus = true
        let bad = await PBOCApplicationReader.select(status, aid: tu)
        check(bad == nil, "SW 9001 incorrectly accepted")
        status.incorrectSuccessStatus = false; status.wrongLengthOnce = true
        let corrected = await PBOCApplicationReader.select(status, aid: tu)
        check(corrected != nil && status.correctedLength == 256, "6C00 retry did not use 256 bytes")
        let noBalance = NFCISO7816Tag(); noBalance.failBalances = true
        noBalance.files = [tu: [0x18: [purchase]]]
        let missing = try await TUnionDecoder.decode(tag: .iso7816(noBalance), scannedAt: Date())
        check(missing.balanceText == nil && !missing.rawTransactions.isEmpty, "Unavailable balance became zero or discarded history")
        print("PASS: dual applications, strict correlation, currencies, partial rescans, persistence, and APDU selection/status")
    }
}
'''
        with tempfile.TemporaryDirectory(prefix="cardbal-dual-") as temporary:
            directory = Path(temporary)
            swift = directory / "test.swift"
            swift.write_text(adapters + models + decoder + applications + main)
            binary = directory / "test-dual"
            build = subprocess.run(["swiftc", "-parse-as-library", str(swift), "-o", str(binary)], capture_output=True, text=True)
            self.assertEqual(build.returncode, 0, build.stdout + build.stderr)
            run = subprocess.run([str(binary), str(ROOT)], capture_output=True, text=True)
            self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
            self.assertIn("PASS:", run.stdout)


if __name__ == "__main__":
    unittest.main()
