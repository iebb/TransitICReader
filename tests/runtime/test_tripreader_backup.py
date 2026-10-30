"""Import synthetic 读卡识途 (Trip Reader) backups through the production readers.

The fixture is a WAL-mode SQLite file with Trip Reader's Room schema and synthetic
card files; it contains no real card data. Set CARDBAL_TRIPREADER_BACKUP to a
local backup to also print a masked summary of its import. Never commit one.
"""
import os
import re
import shutil
import sqlite3
import subprocess
import tempfile
import unittest
from pathlib import Path

from tools.paths import ROOT

CARD_TABLE = (
    "CREATE TABLE `card_table` (`cdRawNo` TEXT NOT NULL, `cdLastUpdate` INTEGER NOT NULL, `cdNo` TEXT NOT NULL, "
    "`cdNo2` TEXT NOT NULL, `cdCUExpiry` INTEGER, `cdTUExpiry` INTEGER, `cdTitle` TEXT NOT NULL, `isTU` INTEGER NOT NULL, "
    "`isCU` INTEGER NOT NULL, `isBJ` INTEGER NOT NULL, `isSZT` INTEGER NOT NULL, `isYCT` INTEGER NOT NULL, "
    "`isSUZ` INTEGER NOT NULL, `isTFT` INTEGER NOT NULL, `cdBalance` INTEGER NOT NULL, `cdCUBalance` INTEGER NOT NULL, "
    "`cdTUBalance` INTEGER NOT NULL, `cdTripBalance` INTEGER NOT NULL DEFAULT 0, `cdTripBalance2` INTEGER NOT NULL DEFAULT 0, "
    "`cdTripExpiry` INTEGER, `cdTripExpiry2` INTEGER, `cdOverdrawLimit` INTEGER NOT NULL, `cdTUCity` INTEGER NOT NULL, "
    "`cdTU17City` INTEGER NOT NULL DEFAULT 0, `cdCUCity` INTEGER NOT NULL, `cdYCTCity` INTEGER NOT NULL, "
    "`cdIssuer` TEXT NOT NULL, `cdTimeZone` TEXT NOT NULL, `cdCURawInfo` TEXT NOT NULL, `cdTURawInfo` TEXT NOT NULL, "
    "`cdTransactions` INTEGER NOT NULL, `cdComment` TEXT NOT NULL, `cdColor` INTEGER NOT NULL, `cdUserChanged` INTEGER NOT NULL, "
    "`cdCURoaming` INTEGER NOT NULL DEFAULT 0, `cdTURoaming` INTEGER NOT NULL DEFAULT 0, `cdCUCardType` INTEGER NOT NULL DEFAULT 0, "
    "`cdTUCardType` INTEGER NOT NULL DEFAULT 0, PRIMARY KEY(`cdRawNo`))"
)
TRAN_TABLE = (
    "CREATE TABLE `tran_table` (`cdRawNo` TEXT NOT NULL, `txNo` INTEGER NOT NULL, `txID` INTEGER NOT NULL, "
    "`txCUType` INTEGER NOT NULL, `txCUSubtype` INTEGER NOT NULL, `txTUType` INTEGER NOT NULL, `txTUSubtype` INTEGER NOT NULL, "
    "`txECType` INTEGER NOT NULL, `txCarrier` INTEGER NOT NULL, `txCUResult` TEXT NOT NULL, `txTUResult` TEXT NOT NULL, "
    "`txECResult` TEXT NOT NULL, `txTitle` TEXT NOT NULL, `txAmount` INTEGER NOT NULL, `txBalance` INTEGER NOT NULL, "
    "`txDate` INTEGER NOT NULL, `txCUPOS` TEXT NOT NULL, `txTUPOS` TEXT NOT NULL, `txCUCity` INTEGER NOT NULL, "
    "`txTUCity` INTEGER NOT NULL, `txSFI` INTEGER NOT NULL, `txCU` INTEGER NOT NULL, `txCUTopUp` INTEGER NOT NULL, "
    "`txCUForeign` INTEGER NOT NULL, `txTU` INTEGER NOT NULL, `txTU18` INTEGER NOT NULL, `txTUTopUp` INTEGER NOT NULL, "
    "`txEC` INTEGER NOT NULL, `txTrip` INTEGER NOT NULL DEFAULT 0, `txTrip2` INTEGER NOT NULL DEFAULT 0, "
    "`txYCT` INTEGER NOT NULL, `txLine` TEXT NOT NULL, `isOn` INTEGER NOT NULL, `isOff` INTEGER NOT NULL, "
    "`isTransfer` INTEGER NOT NULL, `isMan` INTEGER NOT NULL, `isFree` INTEGER NOT NULL, `isDiscount` INTEGER NOT NULL, "
    "`isTravel` INTEGER NOT NULL, `isNight` INTEGER NOT NULL, `isDawn` INTEGER NOT NULL, `isNew` INTEGER NOT NULL, "
    "`isFinished` INTEGER NOT NULL, `isCurrentStart` INTEGER NOT NULL, `txComment` TEXT NOT NULL, "
    "`txUserChanged` INTEGER NOT NULL, PRIMARY KEY(`cdRawNo`, `txCUResult`, `txTUResult`))"
)
UNKNOWN = -99999999
# City Union in a non-Shanghai city (little-endian serial 123456789); T-Union
# card numbers at bytes 10-20, as in the SFI 0x15 issuer file.
CU_INFO = "00004510" + "00" * 12 + "15CD5B07" + "20230101" + "20331231" + "0000"


def tu_info(number):
    return "00001000" + "00" * 6 + number + "20240101" + "20341231" + "0000"


def ledger(counter, day, kind="06"):
    return f"{counter:04X}" + "000000" + "00000064" + kind + "100000000001" + f"202601{day:02d}120000"


def travel(day):
    return "02" + "00" * 24 + f"202601{day:02d}130000" + "1000" + "00" * 14


def create_backup(path, cards=(), rows=()):
    db = sqlite3.connect(path)
    db.execute("PRAGMA journal_mode=WAL")
    db.execute("CREATE TABLE android_metadata (locale TEXT)")
    db.execute(CARD_TABLE)
    db.execute(TRAN_TABLE)
    db.execute("CREATE TABLE room_master_table (id INTEGER PRIMARY KEY,identity_hash TEXT)")
    card_columns = [row[1] for row in db.execute("PRAGMA table_info(card_table)")]
    tran_columns = [row[1] for row in db.execute("PRAGMA table_info(tran_table)")]
    for values in cards:
        row = {name: "" for name in card_columns} | {name: 0 for name in card_columns if name.startswith(("is", "cd")) and name not in (
            "cdRawNo", "cdNo", "cdNo2", "cdTitle", "cdIssuer", "cdTimeZone", "cdCURawInfo", "cdTURawInfo", "cdComment")} | values
        db.execute(f"INSERT INTO card_table VALUES ({','.join('?' * len(card_columns))})", [row[name] for name in card_columns])
    for values in rows:
        row = {name: 0 for name in tran_columns} | {name: "" for name in (
            "txCUResult", "txTUResult", "txECResult", "txTitle", "txCUPOS", "txTUPOS", "txLine", "txComment")} | values
        db.execute(f"INSERT INTO tran_table VALUES ({','.join('?' * len(tran_columns))})", [row[name] for name in tran_columns])
    db.commit()
    db.close()


def fixture_backup(path):
    stamp = 1790000000000
    cards = [
        dict(cdRawNo="DUAL", cdLastUpdate=stamp, isTU=1, isCU=1, cdBalance=1084, cdCUBalance=1234, cdTUBalance=-150,
             cdCURawInfo=CU_INFO, cdTURawInfo=tu_info("3104100012345678901F")),
        dict(cdRawNo="TUONLY", cdLastUpdate=stamp, isTU=1, cdBalance=200, cdCUBalance=UNKNOWN, cdTUBalance=UNKNOWN,
             cdTURawInfo=tu_info("3104100099990000111F")),
        dict(cdRawNo="BEIJING", cdLastUpdate=stamp, isBJ=1, cdBalance=500, cdCUBalance=UNKNOWN, cdTUBalance=UNKNOWN),
    ]
    rows = [dict(cdRawNo="DUAL", txCUResult=ledger(i + 1, 1 + i % 28), txSFI=0x18, txCU=1) for i in range(35)]
    rows += [dict(cdRawNo="DUAL", txCUResult=ledger(100 + i, i), txTUResult=travel(i), txSFI=0x18, txTU18=1, txTU=1) for i in (1, 2, 3)]
    rows += [dict(cdRawNo="DUAL", txCUResult=ledger(200, 28), txSFI=0x18, txCU=1, txTU18=1),
             dict(cdRawNo="DUAL", txCUResult=ledger(201, 27, "02"), txSFI=0x10, txCUTopUp=1)]
    rows += [dict(cdRawNo="TUONLY", txCUResult=ledger(i, i), txTUResult="" if i == 3 else travel(i), txSFI=0x18, txTU18=1,
                  txTU=0 if i == 3 else 1) for i in range(1, 6)]
    rows += [dict(cdRawNo="BEIJING", txCUResult=ledger(1, 1), txSFI=0x18)]
    create_backup(path, cards, rows)


def method(source, name):
    match = re.search(r"^    (?:private )?func " + name + r"\(.*?^    }", source, re.M | re.S)
    if not match:
        raise AssertionError(name)
    return match.group().replace("private func", "func", 1)


@unittest.skipUnless(shutil.which("swiftc"), "Requires Swift")
class TripReaderBackupTests(unittest.TestCase):
    def test_backup_replays_through_readers_and_merges_without_rollback(self):
        transport = (ROOT / "ios/CardBal/NFC/CardTransport.swift").read_text()
        transport = transport[:transport.index("enum ExternalReaderError")]
        utils = (ROOT / "ios/CardBal/NFC/NFCUtils.swift").read_text()
        models = utils[utils.index("struct ResultField:"):utils.index("struct TransactionDecoderRegistry")]
        models += utils[utils.index("struct TransitCardSnapshot:"):utils.index("enum StatusKind")]
        models += utils[utils.index("extension Data {"):utils.index("struct BERTLVNode")]
        saved = (ROOT / "ios/CardBal/Models/SavedCardRecord.swift").read_text()
        models += saved[saved.index("struct SavedCardField:"):saved.index("struct SavedCardColor:")]
        decoder = (ROOT / "ios/CardBal/NFC/Decoders/TUnionDecoder.swift").read_text().replace("Bundle.main.url(", "resourceURL(")
        applications = (ROOT / "ios/CardBal/Models/TransitApplications.swift").read_text()
        importer = (ROOT / "ios/CardBal/Models/TripReaderBackup.swift").read_text()
        store = (ROOT / "ios/CardBal/Models/CardWalletStore.swift").read_text()
        merge = "\n".join(method(store, name) for name in ["importSnapshots", "consolidateMatchingCards", "mergedCard"])
        merge = merge.replace("    func importSnapshots", "    @discardableResult func importSnapshots")
        merge = merge.replace("    func consolidateMatchingCards", "    @discardableResult func consolidateMatchingCards")
        result_type = re.search(r"^struct CardBackupImportResult \{.*?^}", store, re.M | re.S).group()
        content = (ROOT / "ios/CardBal/ContentView.swift").read_text()
        storage_id = re.search(r"    var storageIdentifier: String \{.*?^    }", content, re.M | re.S).group()
        adapters = r'''
func resourceURL(forResource name: String, withExtension ext: String) -> URL? {
    let root = URL(fileURLWithPath: CommandLine.arguments[1])
    return ["build/stations", "ios/CardBal/Resources"].map { root.appendingPathComponent($0 + "/" + name + "." + ext) }
        .first { FileManager.default.fileExists(atPath: $0.path) }
}
enum NFCTestError: Error { case unsupportedCard }
protocol TransitCardDecoder {
    static func canDecode(tag: CardTag) async -> Bool
    static func decode(tag: CardTag, scannedAt: Date) async throws -> TransitCardSnapshot
}
enum ICCardBrand {
    case tUnion, octopus, snapperPlus, other
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
    var deletedCards: [String: Date] = [:]
    func autoApplyPresetIfMatching(id: String) {}
    func markMapDataChanged() {}
    func save() -> Bool { true }
    func mergeRawRecords(existing: [String], incoming: [String], family: String, technology: String, kind: RawHistoryKind) -> [String] {
        var seen = Set<String>(); return (incoming + existing).filter { seen.insert($0).inserted }
    }
''' + merge + '''\n}\nextension TransitCardSnapshot {\n''' + storage_id + '''\n}\n''' + result_type + "\n"
        main = r'''
func check(_ condition: @autoclosure () -> Bool, _ message: String) { precondition(condition(), message) }
func masked(_ value: String?) -> String { value.map { String(repeating: "•", count: max($0.count - 4, 0)) + $0.suffix(4) } ?? "none" }
@main struct Tests {
    @MainActor static func main() async throws {
        let arguments = CommandLine.arguments
        let cu = CityUnionDecoder.applicationAID, tu = TUnionDecoder.applicationAID
        let plan = try await TripReaderBackup.importPlan(from: URL(fileURLWithPath: arguments[2]))
        check(plan.snapshots.count == 2 && plan.skippedCards == 1, "Unsupported or supported cards were miscounted")
        check(plan.recordCount == 36 + 1 + 3 + 3 + 5 + 4, "Backup records were lost or misassigned: \(plan.recordCount)")

        guard let dual = plan.snapshots.first(where: { $0.realSerialNumber == "3104100012345678901" }),
              let single = plan.snapshots.first(where: { $0.realSerialNumber == "3104100099990000111" }) else {
            preconditionFailure("A T-Union serial was not decoded from file 0x15")
        }
        check(dual.storageIdentifier == "ISO7816|3104100012345678901", "Imported card is not stored by serial")
        let apps = Dictionary(uniqueKeysWithValues: dual.applicationSnapshots.map { ($0.selectedAID ?? "", $0) })
        check(apps[cu]?.serialNumber == "123456789", "City Union serial was not decoded")
        check(apps[cu]?.balanceText?.contains("12.34") == true, "City Union balance: \(apps[cu]?.balanceText ?? "nil")")
        check(apps[tu]?.balanceText?.contains("1.50") == true && apps[tu]?.balanceText?.contains("-") == true,
              "T-Union overdraft was not read as debt: \(apps[tu]?.balanceText ?? "nil")")
        check(dual.balanceText == apps[tu]?.balanceText, "Equal-time applications must prefer the T-Union balance")
        let ledger = apps[cu]?.records.filter { $0.sfi == 0x18 } ?? []
        check(ledger.count == 36 && ledger.map(\.index) == Array(1...36), "Full City Union history beyond 30 records was not kept")
        check(ledger.first?.hex.hasSuffix("20260128120000") == true, "History is not newest first")
        check(apps[cu]?.records.contains { $0.sfi == 0x10 } == true, "Top-up file was not kept")
        check(apps[tu]?.records.filter { $0.kind == .transit }.count == 3, "T-Union travel records were not kept")
        check(dual.rawTransactions.count == 40 && dual.rawTransitHistory.count == 3, "Card history was not rebuilt from applications")
        check(single.balanceText?.contains("2.00") == true, "Single-application balance: \(single.balanceText ?? "nil")")
        check(single.rawTransactions.count == 5 && single.rawTransitHistory.count == 4, "Single-application history")
        check(single.scannedAt == Date(timeIntervalSince1970: 1_790_000_000), "Backup update time was not used as the reading time")

        // Invalid database integers cannot overflow the four-byte purse or debt response.
        for balance in [Int.min, Int.max, -0x1_0000_0000, 0x1_0000_0000] {
            let replay = TripReaderBackup.ReplayCard(applications: [tu: .init(balanceCents: balance)])
            _ = try await replay.sendCommand(apdu: CardAPDU(data: Data(hexString: "00A4040008" + tu))!)
            for command in ["805C000204", "805C010204"] {
                let (payload, sw1, sw2) = try await replay.sendCommand(apdu: CardAPDU(data: Data(hexString: command))!)
                check(payload.isEmpty && sw1 == 0x6A && sw2 == 0x82, "Invalid balance was replayed: \(balance)")
            }
        }

        // A newer local reading keeps its balance, UID, title and place; the backup adds history.
        let wallet = Wallet()
        var local = SavedCardRecord(snapshot: single)
        let later = Date(timeIntervalSince1970: 1_800_000_000)
        var app = local.applications![0]
        app.identifier = "01020304"; app.balanceText = "LOCAL"; app.balanceReadAt = later
        app.records = [TransitApplicationRecord(kind: .transaction, sfi: 0x18, index: 1, hex: "0009" + String(repeating: "0", count: 42))]
        local.applications = [TransitApplication(copying: app, scannedAt: later)]
        local.applyApplications(local.applications!)
        local.scannedAt = later; local.customTitle = "Commute"; local.order = 3
        wallet.cards = [local]
        wallet.deletedCards = ["ISO7816|3104100012345678901": .distantPast]
        let result = try wallet.importSnapshots(plan.snapshots)
        check(result.imported == 2 && result.replaced == 1 && wallet.cards.count == 2, "Matching card was duplicated")
        check(wallet.deletedCards.isEmpty, "An explicit import did not restore a deleted card")
        let kept = wallet.cards.first { $0.customTitle == "Commute" }!
        check(kept.id == local.id && kept.order == 3, "Import replaced the local card's identity or place")
        check(kept.balanceText == "LOCAL" && kept.scannedAt == later, "An older backup rolled back the balance")
        check(kept.applications?.first?.identifier == "01020304", "A scanned UID was lost")
        check(kept.applications?.first?.records.count == 10, "Backup history was not added to the local card")

        // A newer backup reading replaces an older local one, still keeping the card.
        let older = Wallet()
        var stale = local
        stale.scannedAt = .distantPast
        stale.applications = [TransitApplication(copying: app, scannedAt: .distantPast, balanceReadAt: .distantPast, balance: "OLD")]
        stale.applyApplications(stale.applications!)
        older.cards = [stale]
        try older.importSnapshots([single])
        check(older.cards.count == 1 && older.cards[0].balanceText?.contains("2.00") == true, "Newer backup balance was ignored")
        check(older.cards[0].order == 3 && older.cards[0].customTitle == "Commute", "Newer backup replaced the card's appearance")

        let empty = try await TripReaderBackup.importPlan(from: URL(fileURLWithPath: arguments[3]))
        check(empty.snapshots.isEmpty && empty.skippedCards == 0, "Empty backup")
        for path in arguments[4...5] {
            do {
                _ = try await TripReaderBackup.importPlan(from: URL(fileURLWithPath: path))
                preconditionFailure("Accepted a file that is not a Trip Reader backup")
            } catch TripReaderBackup.ImportError.notTripReaderBackup {}
        }
        if arguments.count > 6 {
            let local = try await TripReaderBackup.importPlan(from: URL(fileURLWithPath: arguments[6]))
            print("LOCAL BACKUP: \(local.snapshots.count) cards, \(local.recordCount) records, \(local.skippedCards) skipped")
            for card in local.snapshots {
                let apps = card.applicationSnapshots.map { "\($0.label) \($0.balanceText ?? "unavailable") \($0.records.count) records" }
                print("  \(card.cardFamily) \(masked(card.realSerialNumber)) · \(card.balanceText ?? "unavailable") · \(apps.joined(separator: "; "))")
            }
        }
        print("PASS: Trip Reader backup replay, full history, balances, wallet merge and file validation")
    }
}
extension TransitApplication {
    init(copying app: TransitApplication, scannedAt: Date, balanceReadAt: Date? = nil, balance: String? = nil) {
        let data = try! JSONEncoder().encode(app)
        var json = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
        json["scannedAt"] = scannedAt.timeIntervalSinceReferenceDate
        if let balanceReadAt { json["balanceReadAt"] = balanceReadAt.timeIntervalSinceReferenceDate }
        if let balance { json["balanceText"] = balance }
        self = try! JSONDecoder().decode(TransitApplication.self, from: JSONSerialization.data(withJSONObject: json))
    }
}
'''
        with tempfile.TemporaryDirectory(prefix="cardbal-tripreader-") as temporary:
            directory = Path(temporary)
            backup, empty, junk, other = (directory / name for name in ["backup.sqlite", "empty.sqlite", "junk.sqlite", "other.sqlite"])
            fixture_backup(backup)
            create_backup(empty)
            junk.write_bytes(b"not a database" * 100)
            sqlite3.connect(other).execute("CREATE TABLE card_table (cdRawNo TEXT)").connection.close()
            swift = directory / "test.swift"
            swift.write_text("import Foundation\nimport SQLite3\n" + transport + adapters + models + decoder + applications
                             + importer.replace("import Foundation\nimport SQLite3\n", "") + main)
            shutil.copy2(ROOT / "data/stations/SingaporeTransit.json", directory / "SingaporeTransit.json")
            binary = directory / "test-tripreader"
            build = subprocess.run(["swiftc", "-parse-as-library", str(swift), str(ROOT / "ios/CardBal/Helpers/SingaporeTransitCatalog.swift"),
                                    *[str(ROOT / "ios/CardBal/NFC/Profiles" / name) for name in ["SnapperPlusProtocol.swift", "AdditionalCardHistory.swift",
                                      "CEPASProtocol.swift", "CalypsoProtocol.swift", "StoredValueProtocol.swift"]], "-o", str(binary)],
                                   capture_output=True, text=True)
            self.assertEqual(build.returncode, 0, build.stdout + build.stderr)
            arguments = [str(binary), str(ROOT), str(backup), str(empty), str(junk), str(other)]
            if os.environ.get("CARDBAL_TRIPREADER_BACKUP"):
                arguments.append(os.environ["CARDBAL_TRIPREADER_BACKUP"])
            run = subprocess.run(arguments, capture_output=True, text=True)
            self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
            self.assertIn("PASS:", run.stdout)
            print(run.stdout.strip())


if __name__ == "__main__":
    unittest.main()
