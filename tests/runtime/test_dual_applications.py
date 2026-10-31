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

from tools.paths import ROOT


def method(source, name):
    match = re.search(r"^    (?:private )?func " + name + r"\(.*?^    }", source, re.M | re.S)
    if not match:
        raise AssertionError(name)
    return match.group().replace("private func", "func", 1)


@unittest.skipUnless(shutil.which("swiftc"), "Requires Swift")
class DualApplicationTests(unittest.TestCase):
    def test_readers_history_and_partial_wallet_rescans(self):
        utils = (ROOT / "ios/CardBal/NFC/NFCUtils.swift").read_text()
        models = utils[utils.index("struct ResultField:"):utils.index("struct TransactionDecoderRegistry")]
        models += utils[utils.index("struct TransitCardSnapshot:"):utils.index("enum StatusKind")]
        models += utils[utils.index("extension Data {"):utils.index("struct BERTLVNode")]
        saved = (ROOT / "ios/CardBal/Models/SavedCardRecord.swift").read_text()
        models += saved[saved.index("struct SavedCardField:"):saved.index("struct SavedCardColor:")]
        decoder = (ROOT / "ios/CardBal/NFC/Decoders/TUnionDecoder.swift").read_text().replace("import CoreNFC", "")
        decoder = decoder.replace("Bundle.main.url(", "resourceURL(")
        applications = (ROOT / "ios/CardBal/Models/TransitApplications.swift").read_text()
        store = (ROOT / "ios/CardBal/Models/CardWalletStore.swift").read_text()
        upsert = "\n".join(method(store, name) for name in ["upsert", "mergeIncomingCard", "consolidateMatchingCards", "mergedCard", "deleteCard", "mergeDeletions"])
        content = (ROOT / "ios/CardBal/ContentView.swift").read_text()
        storage_id = re.search(r"    var storageIdentifier: String \{.*?^    }", content, re.M | re.S).group()
        reader = (ROOT / "ios/CardBal/NFC/NFCTransitReader.swift").read_text()
        reader = reader[:reader.index("extension NFCTransitReader {\n    private func performEnhancedFeliCaHandshake")]
        # Exercise the built-in reader state machine independently of UIKit and
        # the external-reader service. Hardware transports have separate tests.
        start = reader.index("    @Published private(set) var externalReaderNames")
        end = reader.index("    var statusSymbol:", start)
        reader = reader[:start] + '''
    var isNFCAvailable: Bool { true }
    func startScanning(options: NFCTagReaderSession.PollingOption = [.iso18092, .iso14443, .iso15693]) {
        startInternalScanning(options: options)
    }
''' + reader[end:]
        reader = reader.replace("CEPASDecoder.self, StoredValueDecoder.self, ", "")
        reader = "\n".join(line for line in reader.splitlines()
                           if not line.startswith("import ") and "logger" not in line
                           and not line.strip().startswith(("#if", "#endif")))
        reader = reader.replace(", ObservableObject", "").replace("@Published private(set) ", "").replace("private ", "")
        nfc_stubs = (ROOT / "tests/runtime/fixtures/nfc_reader_stubs.swift").read_text()
        adapters = r'''
import Foundation
import SQLite3
typealias CardTag = NFCTag
typealias CardAPDU = NFCISO7816APDU
typealias CardResponseAPDU = NFCISO7816ResponseAPDU
typealias ISO7816Card = NFCISO7816Tag
extension NFCTag { init?(_ tag: NFCTag) { self = tag } }
func resourceURL(forResource name: String, withExtension ext: String) -> URL? {
    let root = URL(fileURLWithPath: CommandLine.arguments[1])
    return ["build/stations", "ios/CardBal/Resources"].map { root.appendingPathComponent($0 + "/" + name + "." + ext) }
        .first { FileManager.default.fileExists(atPath: $0.path) }
}
enum NFCTestError: Error { case unsupportedCard }
protocol TransitCardDecoder {
    static func canDecode(tag: NFCTag) async -> Bool
    static func decode(tag: NFCTag, scannedAt: Date) async throws -> TransitCardSnapshot
}
enum NFCTag { case iso7816(NFCISO7816Tag), feliCa(any NFCFeliCaTag), other }
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
    var binaryFiles: [String: [Int: Data]] = [:]
    var balances: [String: Data] = [:]
    var commands: [NFCISO7816APDU] = []
    var failBalances = false
    var wrongLengthOnce = false
    var incorrectSuccessStatus = false
    var correctedLength: Int?
    func sendCommand(apdu: NFCISO7816APDU) async throws -> (Data, UInt8, UInt8) {
        commands.append(apdu)
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
            if let balance = balances[selected] { return (balance, 0x90, 0) }
            if apdu.p1Parameter == 5 { return (Data(repeating: 0, count: 16), 0x90, 0) }
            return (apdu.p1Parameter == 0 ? Data(hexString: "00000C80") : Data(repeating: 0, count: 4), 0x90, 0)
        }
        if apdu.instructionCode == 0xB0, apdu.p1Parameter == 0x95, let data = info[selected] { return (data, 0x90, 0) }
        if apdu.instructionCode == 0xB0, let data = binaryFiles[selected]?[Int(apdu.p1Parameter & 0x1F)] { return (data, 0x90, 0) }
        if apdu.instructionCode == 0xB2 {
            let sfi = Int(apdu.p2Parameter >> 3), index = Int(apdu.p1Parameter) - 1
            if let records = files[selected]?[sfi], records.indices.contains(index) { return (records[index], 0x90, 0) }
        }
        return (Data(), 0x6A, 0x83)
    }
}
enum ICCardBrand {
    case tUnion, tianfuTong, octopus, snapperPlus, other
    static func from(family: String) -> Self { family == "天府通" ? .tianfuTong : family.contains("Octopus") ? .octopus : family.contains("Union") ? .tUnion : .other }
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
        if family == "天府通" { return TianfuTongDecoder.decodeRecord(data: data, index: index) }
        if AdditionalCardHistory.handles(family) { return AdditionalCardHistory.decode(raw: raw, family: family, context: context) }
        if technology == "FeliCa" {
            precondition(family == "Octopus", "Wrong family dispatched to FeliCa history")
            return TransitTransaction(date: nil, amount: -5, terminalID: nil, type: "Octopus", rawData: raw)
        }
        if data.count == 23 { return TUnionDecoder.decodePBOC(data: data, index: index) }
        return TUnionDecoder.decodeTravelRecord(data: data, index: index)
    }
}
struct SavedCardRecord: Codable, Equatable {
    var id: String
    var technology: String, cardFamily: String, identifierLabel: String, identifierValue: String, rawIdentifierValue: String
    var pmm: String?, systemCode: String?, selectedAID: String?, balanceText: String?, balanceDetail: String?, realSerialNumber: String?, region: String?
    var resultFields: [SavedCardField], rawTransactions: [String], rawTransitHistory: [String]
    var scannedAt: Date
    var applications: [TransitApplication]?
    var mergedIdentifiers: [String]?
    var faceImageFileName: String?, isUsingImage: Bool?, customDisplaySerialNumber: String?
    var order = 0
    var isPinned: Bool?
    var enhancedFeliCaDecoded = false
    var issuingCity: String?, cardTypeStr: String?, issueDateStr: String?, expiryDateStr: String?
    var customTitle: String?
    var transactionsForTest: [TransitTransaction] { TransitApplicationHistory.decode(applicationSnapshots, kind: .transactions) }
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
    var deletedCards: [String: Date] = [:]
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
func snapshot(_ aid: String?, serial: String?, date: Double = 100, balance: String? = "CNY 32", records: [TransitApplicationRecord] = [], identifier: String? = nil) -> TransitCardSnapshot {
    var snapshot = TransitCardSnapshot(technology: aid == nil ? "FeliCa" : "ISO7816", cardFamily: aid == nil ? "Octopus" : aid == CityUnionDecoder.applicationAID ? "City Union" : "China T-Union",
        identifierLabel: "UID", identifierValue: "01020304", rawIdentifierValue: identifier ?? (aid == nil ? "0102030405060708" : "01020304"), pmm: nil,
        systemCode: aid == nil ? "8008" : nil, selectedAID: aid, balanceText: balance, balanceDetail: nil, realSerialNumber: serial, region: nil,
        resultFields: [], rawSections: [], rawTransactions: records.filter { $0.kind == .transaction }.map(\.hex),
        rawTransitHistory: records.filter { $0.kind == .transit }.map(\.hex), scannedAt: Date(timeIntervalSince1970: date))
    snapshot.applications = [TransitApplication(snapshot: snapshot, records: records)]
    return snapshot
}
func testDualCurrency(octopus: TransitCardSnapshot, plain: TransitCardSnapshot) throws {
    let result = Data(#"{"cardDataVO":{"balance":55.0,"status":"R30","motRate":"0.839","motExpiryDate":"202710311800","hasNewMotRate":false}}"#.utf8)
    let rate = OctopusExchangeRate.parse(result: result)
    check(rate?.rate == "0.839", "Exchange rate not read as returned")
    var hongKong = Calendar(identifier: .gregorian); hongKong.timeZone = TimeZone(identifier: "Asia/Hong_Kong")!
    check(rate?.validUntil == hongKong.date(from: DateComponents(year: 2027, month: 10, day: 31, hour: 18)), "Rate expiry not read in Hong Kong time")
    check(rate?.isExpired(at: hongKong.date(from: DateComponents(year: 2027, month: 11, day: 1))!) == true && rate?.isExpired() == false, "Rate expiry check")
    for missing in [#"{"cardDataVO":{"balance":2.2,"status":"R30"}}"#, #"{"cardDataVO":{"motRate":""}}"#, #"{"cardDataVO":{"motRate":"0"}}"#,
                    #"{"cardDataVO":{"motRate":true}}"#, #"{"cardDataVO":{"motRate":"1e9"}}"#, "not json"] {
        check(OctopusExchangeRate.parse(result: Data(missing.utf8)) == nil, "Invented a rate from " + missing)
    }
    check(OctopusExchangeRate.parse(result: Data(#"{"cardDataVO":{"motRate":0.84}}"#.utf8))?.validUntil == nil, "Numeric rate without expiry")
    for (text, expected) in [("CN¥46.15", "46.15"), ("¥46.15", "46.15"), ("46,15 CN¥", "46.15"), ("CN¥1,000.00", "1000.00"), ("-¥1.50", "-1.50"), ("CNY 32", "32.00")] {
        let yuan = DualCurrencyBalance.yuanText(fromBalanceText: text) ?? ""
        check(yuan.contains("CN¥") && yuan.filter { $0.isNumber || $0 == "-" } == expected.filter { $0.isNumber || $0 == "-" }, "Yuan balance \(text) became \(yuan)")
    }
    check(DualCurrencyBalance.yuanText(fromBalanceText: "N/A") == nil, "Yuan balance invented")
    var national = TransitCardSnapshot(technology: "ISO7816", cardFamily: "China T-Union", identifierLabel: "UID", identifierValue: "01020304",
        rawIdentifierValue: "01020304", pmm: nil, systemCode: nil, selectedAID: TUnionDecoder.applicationAID, balanceText: "¥46.15",
        balanceDetail: nil, realSerialNumber: "3100000000000000001", region: nil, resultFields: [], rawSections: [], rawTransactions: [],
        rawTransitHistory: [], scannedAt: octopus.scannedAt.addingTimeInterval(2))
    national.applications = [TransitApplication(snapshot: national)]
    let combined = TransitCardSnapshot.combining([national, octopus])!
    let dual = DualCurrencyBalance(applications: combined.applications)
    check(combined.exchangeRate?.rate == "0.839" && combined.balanceText == "HKD 50", "Combined card lost its rate or HKD balance")
    check(dual?.yuanBalance?.hasPrefix("CN¥") == true && dual?.rateText == "HK$1 = CN¥0.839", "Dual balance rows")
    check(DualCurrencyBalance(applications: TransitCardSnapshot.combining([national, plain])!.applications) == nil, "A plain Octopus card became dual")
    check(DualCurrencyBalance(applications: octopus.applications)?.yuanBalance == nil, "Missing T-Union side invented a yuan balance")
    var stale = national
    stale = TransitCardSnapshot(technology: stale.technology, cardFamily: stale.cardFamily, identifierLabel: stale.identifierLabel,
        identifierValue: stale.identifierValue, rawIdentifierValue: stale.rawIdentifierValue, pmm: nil, systemCode: nil,
        selectedAID: stale.selectedAID, balanceText: stale.balanceText, balanceDetail: nil, realSerialNumber: stale.realSerialNumber,
        region: nil, resultFields: [], rawSections: [], rawTransactions: [], rawTransitHistory: [], scannedAt: octopus.scannedAt.addingTimeInterval(-3600))
    stale.applications = [TransitApplication(snapshot: stale)]
    let old = DualCurrencyBalance(applications: TransitCardSnapshot.combining([stale, octopus])!.applications)
    check(old != nil && old?.yuanBalance == nil, "A yuan balance from an older scan was shown as current")
    let stored = try JSONDecoder().decode([TransitApplication].self, from: JSONEncoder().encode(combined.applications))
    check(stored == combined.applications, "Rate lost in storage")
    let legacy = try JSONDecoder().decode([TransitApplication].self, from: JSONEncoder().encode(plain.applications))
    check(legacy.first?.exchangeRate == nil, "Saved cards without a rate")
}
@main struct Tests {
    @MainActor static func main() async throws {
        try testChongqingHistory()
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
        check(dual.transactions[0].sourceRecordIDs?.count == 3, "Correlated payment evidence lost")
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
        var dualOctopus = octopus
        dualOctopus.exchangeRate = OctopusExchangeRate(rate: "0.839", validUntil: OctopusExchangeRate.parseExpiry("202710311800"))
        dualOctopus.applications = [TransitApplication(snapshot: dualOctopus, records: [record(Data(repeating: 1, count: 16), sfi: 0)])]
        try testDualCurrency(octopus: dualOctopus, plain: octopus)
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
        let split = Wallet()
        var savedMainland = SavedCardRecord(snapshot: national)
        savedMainland.customTitle = "Travel card"; savedMainland.faceImageFileName = "my-photo"
        savedMainland.order = 3; savedMainland.isPinned = true
        split.cards = [savedMainland, SavedCardRecord(snapshot: octopus)]
        split.upsert(snapshot: mixed)
        check(split.cards.count == 1, "Previously separate protocol entries were not coalesced")
        let unified = split.cards[0]
        check(unified.id == savedMainland.id && unified.customTitle == "Travel card", "Wallet identity or title lost")
        check(unified.faceImageFileName == "my-photo" && unified.order == 3 && unified.isPinned == true, "Appearance, pin or order lost")
        check(unified.applications?.count == 2 && unified.transactionsForTest.count == 2, "Merged history lost a protocol")
        check(unified.identityAliases.contains(octopus.storageIdentifier), "Removed protocol identity lost")
        split.upsert(snapshot: octopus)
        split.upsert(snapshot: national)
        check(split.cards.count == 1 && split.cards[0].applications?.count == 2, "Partial rescan split a dual card")
        let cloud = Wallet()
        cloud.cards = [savedMainland, SavedCardRecord(snapshot: octopus)]
        check(cloud.mergeIncomingCard(SavedCardRecord(snapshot: mixed)), "Combined backup did not merge")
        check(cloud.cards.count == 1, "Cloud restore left a second protocol entry")
        check(!cloud.mergeIncomingCard(SavedCardRecord(snapshot: octopus)), "Stale partial backup changed merged card")
        let reopened = Wallet()
        reopened.cards = try JSONDecoder().decode([SavedCardRecord].self, from: JSONEncoder().encode(cloud.cards))
        check(!reopened.mergeIncomingCard(SavedCardRecord(snapshot: national)), "Persisted aliases failed to match old backup")
        check(reopened.cards.count == 1 && reopened.cards[0].applications?.count == 2, "Reopen lost merged applications")
        reopened.deleteCard(reopened.cards[0].id)
        check(!reopened.mergeIncomingCard(SavedCardRecord(snapshot: octopus)), "Deleted dual card returned through FeliCa alias")
        check(!reopened.mergeIncomingCard(savedMainland), "Deleted dual card returned through ISO alias")
        let peer = Wallet(); peer.cards = [SavedCardRecord(snapshot: octopus)]
        check(peer.mergeDeletions(reopened.deletedCards) && peer.cards.isEmpty, "Cross-protocol cloud deletion failed")
        let legacySplit = Wallet()
        var oldFeliCa = SavedCardRecord(snapshot: octopus); oldFeliCa.id = "old-physical-card-id"
        var linked = SavedCardRecord(snapshot: mixed); linked.id = "legacy-dual-id"
        legacySplit.cards = [oldFeliCa, savedMainland, linked]
        check(legacySplit.consolidateMatchingCards() && legacySplit.cards.count == 1, "Transitive legacy aliases not consolidated")
        check(legacySplit.cards[0].identityAliases.contains("legacy-dual-id"), "Removed legacy ID not retained")
        let legacyRoundTrip = try JSONDecoder().decode(SavedCardRecord.self, from: JSONEncoder().encode(legacySplit.cards[0]))
        check(legacyRoundTrip.identityAliases.contains("legacy-dual-id"), "Removed legacy ID not persisted")
        let distinct = Wallet()
        let different = snapshot(nil, serial: "ANOTHER-CARD", identifier: "1112131415161718")
        distinct.cards = [SavedCardRecord(snapshot: octopus), SavedCardRecord(snapshot: different)]
        check(!distinct.consolidateMatchingCards() && distinct.cards.count == 2, "Unrelated Octopus cards were merged")
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
        for pair in [[dualOctopus, national], [national, octopus]] {
            let reader = NFCTransitReader(); reader.startScanning()
            let session = reader.session!
            reader.accept(pair[0], session: session)
            check(reader.isScanning && reader.latestSnapshot == nil, "Ordinary scan failed to check companion protocol")
            check(session.pollingOption == (pair[0].technology == "FeliCa" ? [.iso14443] : [.iso18092]), "Wrong companion protocol polled")
            reader.accept(pair[1], session: session)
            check(!reader.isScanning && session.invalidated, "Dual scan did not finish")
            check(session.alertMessage == ScanStep.done.message, "Finished scan sheet did not say the card was read")
            check(reader.latestSnapshot?.applications?.count == 2, "Automatic scan lost one interface")
        }
        let plainOctopus = NFCTransitReader(); plainOctopus.startScanning()
        plainOctopus.accept(octopus, session: plainOctopus.session!)
        check(!plainOctopus.isScanning && plainOctopus.secondSideTimeout == nil && plainOctopus.latestSnapshot?.applications?.count == 1,
              "An Octopus card without an exchange rate waited for a mainland side")
        let felicaOnly = NFCTransitReader(); felicaOnly.startScanning(options: [.iso18092])
        felicaOnly.accept(dualOctopus, session: felicaOnly.session!)
        check(!felicaOnly.isScanning && felicaOnly.latestSnapshot?.applications?.count == 1, "Protocol filter was ignored")
        let cancelled = NFCTransitReader(); cancelled.startScanning()
        let cancelledSession = cancelled.session!
        cancelled.accept(national, session: cancelledSession)
        cancelled.tagReaderSession(cancelledSession, didInvalidateWithError: NSError(domain: "NFC", code: 200))
        try await Task.sleep(for: .milliseconds(30))
        check(!cancelled.isScanning && cancelled.latestSnapshot?.storageIdentifier == national.storageIdentifier, "Cancellation lost the first application")
        let unsupported = NFCTransitReader(); unsupported.startScanning()
        let unsupportedSession = unsupported.session!
        unsupported.accept(national, session: unsupportedSession)
        unsupported.accept(national, session: unsupportedSession)
        check(unsupported.latestSnapshot?.applications?.count == 1, "Wrong companion family was paired")
        let discovery = NFCTransitReader(); discovery.startScanning()
        let discoverySession = discovery.session!
        discovery.tagReaderSession(discoverySession, didDetect: [.iso7816(NFCISO7816Tag()), .feliCa(TestFeliCaTag(dualOctopus))])
        try await Task.sleep(for: .milliseconds(30))
        check(discoverySession.pollingOption == [.iso14443] && discovery.pendingPrimary != nil, "Dual discovery was rejected as two cards")
        check(discoverySession.alertMessage == "Keep the same card near your iPhone while reading finishes.", "A reading step replaced the second-side line")
        discovery.accept(national, session: discoverySession)
        check(discovery.latestSnapshot?.applications?.count == 2, "Dual discovery did not produce one combined snapshot")
        let multiple = NFCTransitReader(); multiple.startScanning()
        let multipleSession = multiple.session!
        multiple.tagReaderSession(multipleSession, didDetect: [.feliCa(TestFeliCaTag(octopus)), .feliCa(TestFeliCaTag(different))])
        try await Task.sleep(for: .milliseconds(30))
        check(multiple.pendingPrimary == nil && multiple.latestSnapshot == nil && multipleSession.restarts == 1, "Two same-protocol cards were paired")
        multiple.fail("Test complete", session: multipleSession)
        let timedOut = NFCTransitReader(); timedOut.startScanning()
        timedOut.accept(dualOctopus, session: timedOut.session!)
        check(NFCTransitReader.secondSideWait == .seconds(2), "Single-interface cards wait too long for a second side")
        let waitStarted = ContinuousClock.now
        await timedOut.secondSideTimeout?.value
        check(ContinuousClock.now - waitStarted < .seconds(3), "Companion timeout took too long")
        check(!timedOut.isScanning && timedOut.latestSnapshot?.storageIdentifier == octopus.storageIdentifier, "Companion timeout lost the first application")
        let opalRaw = StoredValueProtocol.envelope(tag: 1, kind: 1, index: 0, data: Data(hexString: "785634F2479A60F0FF439CB0A4030000"))
        let opalSnapshot = TransitCardSnapshot(technology: "DESFire", cardFamily: "Opal", identifierLabel: "UID", identifierValue: "test", rawIdentifierValue: "test", pmm: nil, systemCode: nil, selectedAID: nil, balanceText: "AUD -1.25", balanceDetail: nil, realSerialNumber: nil, region: nil, resultFields: [], rawSections: [], rawTransactions: [opalRaw], rawTransitHistory: [], scannedAt: Date())
        let opalHistory = TransitApplicationHistory.decode([TransitApplication(snapshot: opalSnapshot)], kind: .transactions)
        check(opalHistory.count == 1 && opalHistory[0].currencyCode == "AUD", "Application wrapper replaced explicit currency")
        check(!opalHistory[0].amountKnown && opalHistory[0].issuerTimeZone == "Australia/Sydney", "Unavailable Opal fare became free travel or lost issuer timezone")
        let movedOpal = StoredValueProtocol.envelope(tag: 1, kind: 1, index: 3, data: Data(hexString: "785634F2479A60F0FF439CB0A4030000"))
        check(AdditionalCardHistory.merge([opalRaw, movedOpal]).count == 1, "Moving DESFire slot duplicated history")
        try await testTianfuTong()
        print("PASS: dual applications, strict correlation, currencies, partial rescans, persistence, and APDU selection/status")
    }
}
'''
        with tempfile.TemporaryDirectory(prefix="cardbal-dual-") as temporary:
            directory = Path(temporary)
            swift = directory / "test.swift"
            chongqing = (ROOT / "tests/runtime/fixtures/chongqing_history.swift").read_text()
            tianfu = (ROOT / "ios/CardBal/NFC/Decoders/TianfuTongDecoder.swift").read_text()
            tianfu_tests = (ROOT / "tests/runtime/fixtures/tianfutong.swift").read_text()
            swift.write_text(adapters + models + decoder + applications + nfc_stubs + reader + main + chongqing + tianfu + tianfu_tests)
            shutil.copy2(ROOT / "data/stations/SingaporeTransit.json", directory / "SingaporeTransit.json")
            binary = directory / "test-dual"
            build = subprocess.run(["swiftc", "-parse-as-library", str(swift), str(ROOT / "ios/CardBal/NFC/ScanProgress.swift"), str(ROOT / "ios/CardBal/Utils/DebugLog.swift"), str(ROOT / "ios/CardBal/Helpers/Localizer.swift"), str(ROOT / "ios/CardBal/Helpers/SingaporeTransitCatalog.swift"), str(ROOT / "ios/CardBal/NFC/Profiles/SnapperPlusProtocol.swift"), *[str(ROOT / "ios/CardBal/NFC/Profiles" / name) for name in ["AdditionalCardHistory.swift", "CEPASProtocol.swift", "CalypsoProtocol.swift", "StoredValueProtocol.swift"]], "-o", str(binary)], capture_output=True, text=True)
            self.assertEqual(build.returncode, 0, build.stdout + build.stderr)
            run = subprocess.run([str(binary), str(ROOT)], capture_output=True, text=True)
            self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
            self.assertIn("PASS:", run.stdout)


if __name__ == "__main__":
    unittest.main()
