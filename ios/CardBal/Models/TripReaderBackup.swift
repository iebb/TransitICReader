import Foundation
import SQLite3

/// Imports cards from a 读卡识途 (Trip Reader) Android backup.
///
/// The backup is the app's Room history database. `card_table` keeps each card's
/// SFI 0x15 issuer file and last balance per application; `tran_table` keeps the
/// accumulated raw records: `txCUResult` is a 23-byte PBOC ledger record from
/// file `txSFI`, `txTUResult` a 48-byte T-Union SFI 0x1E travel record. CardBal
/// replays those files through its own City Union and T-Union readers, so an
/// imported card decodes and merges exactly like a scan. Other card families
/// (Beijing, Shenzhen Tong, Lingnan Pass, Suzhou, Tianfu Tong) are skipped.
enum TripReaderBackup {
    struct Application {
        var file15: Data?
        var balanceCents: Int?
        /// Records by SFI, most recent first, as a card returns them.
        var records: [Int: [Data]] = [:]
        var recordCount: Int { records.values.reduce(0) { $0 + $1.count } }
    }

    struct Card {
        let rawNumber: String
        let lastUpdate: Date
        var applications: [String: Application]
    }

    struct ImportPlan {
        var snapshots: [TransitCardSnapshot] = []
        var recordCount = 0
        var skippedCards = 0
    }

    enum ImportError: LocalizedError {
        case notTripReaderBackup, unreadable(String)
        var errorDescription: String? {
            switch self {
            case .notTripReaderBackup: return String(localized: "This file is not a Trip Reader backup.")
            case .unreadable(let message): return message
            }
        }
    }

    /// Trip Reader's "no reading" sentinel for its balance columns.
    private static let unknownBalance = -99_999_999
    private static let requiredColumns: [String: Set<String>] = [
        "card_table": ["cdRawNo", "cdLastUpdate", "isTU", "isCU", "cdBalance", "cdCUBalance", "cdTUBalance",
                       "cdCURawInfo", "cdTURawInfo"],
        "tran_table": ["cdRawNo", "txCUResult", "txTUResult", "txSFI", "txCU", "txCUTopUp", "txCUForeign",
                       "txTU", "txTU18", "txTUTopUp"],
    ]

    /// Read a user-selected backup. The file is copied first: a picked document may be
    /// security-scoped or read-only, and SQLite may need a sidecar for a WAL database.
    static func importPlan(from url: URL) async throws -> ImportPlan {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tripreader-import-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let copy = directory.appendingPathComponent("backup.sqlite")
        let didAccess = url.startAccessingSecurityScopedResource()
        defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
        try FileManager.default.copyItem(at: url, to: copy)
        return await importPlan(cards: try readCards(databaseAt: copy))
    }

    static func importPlan(cards: [Card]) async -> ImportPlan {
        var plan = ImportPlan()
        for card in cards {
            guard let snapshot = await snapshot(for: card) else {
                plan.skippedCards += 1
                continue
            }
            plan.snapshots.append(snapshot)
            plan.recordCount += card.applications.values.reduce(0) { $0 + $1.recordCount }
        }
        return plan
    }

    /// Decode one backed-up card with the production readers, then attach its full
    /// history. A card file holds at most 30 records; the backup can hold more.
    static func snapshot(for card: Card) async -> TransitCardSnapshot? {
        guard !card.applications.isEmpty else { return nil }
        let tag = CardTag.iso7816(ReplayCard(applications: card.applications))
        var snapshots: [TransitCardSnapshot] = []
        if let local = try? await CityUnionDecoder.decode(tag: tag, scannedAt: card.lastUpdate) { snapshots.append(local) }
        if let national = try? await TUnionDecoder.decode(tag: tag, scannedAt: card.lastUpdate) { snapshots.append(national) }
        // The wallet identifies these cards by serial; the backup has no UID.
        snapshots = snapshots.filter { $0.realSerialNumber?.isEmpty == false }.map { snapshot in
            var snapshot = snapshot
            snapshot.applications = snapshot.applicationSnapshots.map { application in
                var application = application
                if let aid = application.selectedAID, let source = card.applications[aid] {
                    application.records = records(of: source)
                }
                return application
            }
            return snapshot
        }
        return TransitCardSnapshot.combining(snapshots)
    }

    static func records(of application: Application) -> [TransitApplicationRecord] {
        application.records.keys.sorted().flatMap { sfi in
            application.records[sfi, default: []].enumerated().map { offset, data in
                TransitApplicationRecord(kind: sfi == 0x1E ? .transit : .transaction, sfi: sfi,
                                         index: offset + 1, hex: data.hexString.uppercased())
            }
        }
    }

    // MARK: - Backup database

    static func readCards(databaseAt url: URL) throws -> [Card] {
        var db: OpaquePointer?
        defer { sqlite3_close(db) }
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            throw ImportError.notTripReaderBackup
        }
        // Any other file, SQLite or not, lacks these columns.
        for (table, columns) in requiredColumns {
            let present = Set(((try? rows(db, "PRAGMA table_info(\(table))")) ?? []).compactMap { $0["name"]?.text })
            guard columns.isSubset(of: present) else { throw ImportError.notTripReaderBackup }
        }

        var cards: [String: Card] = [:]
        var order: [String] = []
        for row in try rows(db, "SELECT cdRawNo, cdLastUpdate, isTU, isCU, cdBalance, cdCUBalance, cdTUBalance, cdCURawInfo, cdTURawInfo FROM card_table") {
            guard let number = row["cdRawNo"]?.text, !number.isEmpty else { continue }
            let isTUnion = row["isTU"]?.integer == 1, isCityUnion = row["isCU"]?.integer == 1
            func balance(_ column: String) -> Int? {
                row[column]?.integer.flatMap { $0 == unknownBalance ? nil : $0 }
            }
            // A dual card stores each application's balance separately and their sum in
            // cdBalance. Without a separate reading, cdBalance is the last application read.
            let separate = isTUnion && isCityUnion && balance("cdTUBalance") != nil
            var applications: [String: Application] = [:]
            if isCityUnion {
                applications[CityUnionDecoder.applicationAID] = Application(
                    file15: data(row["cdCURawInfo"]?.text),
                    balanceCents: separate ? balance("cdCUBalance") : (isTUnion ? nil : balance("cdBalance")))
            }
            if isTUnion {
                applications[TUnionDecoder.applicationAID] = Application(
                    file15: data(row["cdTURawInfo"]?.text),
                    balanceCents: separate ? balance("cdTUBalance") : balance("cdBalance"))
            }
            let lastUpdate = row["cdLastUpdate"]?.integer.map { Date(timeIntervalSince1970: Double($0) / 1000) } ?? Date()
            if cards[number] == nil { order.append(number) }
            cards[number] = Card(rawNumber: number, lastUpdate: lastUpdate, applications: applications)
        }

        var collected: [String: [String: [Int: [Data]]]] = [:]
        for row in try rows(db, "SELECT cdRawNo, txCUResult, txTUResult, txSFI, txCU, txCUTopUp, txCUForeign, txTU, txTU18, txTUTopUp FROM tran_table") {
            guard let number = row["cdRawNo"]?.text, let card = cards[number] else { continue }
            func flag(_ column: String) -> Bool { row[column]?.integer == 1 }
            // Trip Reader reads City Union before T-Union and keeps the first copy of a
            // record both applications mirror, so City Union owns a dual-flagged row.
            let ledgerAID = flag("txCU") || flag("txCUTopUp") || flag("txCUForeign")
                ? CityUnionDecoder.applicationAID
                : flag("txTU18") || flag("txTUTopUp") ? TUnionDecoder.applicationAID : nil
            if let ledgerAID, card.applications[ledgerAID] != nil,
               let ledger = data(row["txCUResult"]?.text), ledger.count >= 23 {
                let sfi = row["txSFI"]?.integer.flatMap { (1...30).contains($0) ? $0 : nil } ?? 0x18
                collected[number, default: [:]][ledgerAID, default: [:]][sfi, default: []].append(ledger.prefix(23))
            }
            if flag("txTU"), card.applications[TUnionDecoder.applicationAID] != nil,
               let travel = data(row["txTUResult"]?.text), travel.count >= 48 {
                collected[number, default: [:]][TUnionDecoder.applicationAID, default: [:]][0x1E, default: []].append(travel.prefix(48))
            }
        }
        for (number, applications) in collected {
            for (aid, files) in applications {
                cards[number]?.applications[aid]?.records = files.mapValues(newestFirst)
            }
        }
        return order.compactMap { cards[$0] }
    }

    /// Most recent first by the record's own BCD timestamp, then transaction counter.
    private static func newestFirst(_ records: [Data]) -> [Data] {
        var seen = Set<Data>()
        func key(_ record: Data) -> String {
            let start = record.startIndex
            if record.count == 48 { return record[(start + 25)..<(start + 32)].hexString }
            return record[(start + 16)..<(start + 23)].hexString + record[start..<(start + 2)].hexString
        }
        return records.map { Data($0) }.filter { $0.contains { $0 != 0 } && seen.insert($0).inserted }
            .sorted { key($0) > key($1) }
    }

    private static func data(_ hex: String?) -> Data? {
        guard let hex, !hex.isEmpty, hex.count.isMultiple(of: 2),
              hex.allSatisfy(\.isHexDigit) else { return nil }
        let data = Data(hexString: hex)
        return data.contains { $0 != 0 } ? data : nil
    }

    private enum Value {
        case integer(Int), text(String), null
        var integer: Int? { if case .integer(let value) = self { return value }; return nil }
        var text: String? { if case .text(let value) = self { return value }; return nil }
    }

    private static func rows(_ db: OpaquePointer?, _ sql: String) throws -> [[String: Value]] {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw ImportError.unreadable(String(cString: sqlite3_errmsg(db)))
        }
        var result: [[String: Value]] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { throw ImportError.unreadable(String(cString: sqlite3_errmsg(db))) }
            var row: [String: Value] = [:]
            for column in 0..<sqlite3_column_count(statement) {
                let name = String(cString: sqlite3_column_name(statement, column))
                switch sqlite3_column_type(statement, column) {
                case SQLITE_INTEGER: row[name] = .integer(Int(sqlite3_column_int64(statement, column)))
                case SQLITE_TEXT: row[name] = .text(String(cString: sqlite3_column_text(statement, column)))
                default: row[name] = .null
                }
            }
            result.append(row)
        }
        return result
    }

    // MARK: - Replay

    /// Answers the readers' read-only commands from the backed-up files. Unavailable
    /// files return the card's not-found status, as on a partial physical read.
    final class ReplayCard: ISO7816Card {
        let identifier = Data()
        let initialSelectedAID = ""
        let applicationData: Data? = nil
        private let applications: [String: Application]
        private var selectedAID: String?
        private var selected: Application? { selectedAID.flatMap { applications[$0] } }

        init(applications: [String: Application]) {
            self.applications = applications
        }

        func sendCommand(apdu: CardAPDU) async throws -> (Data, UInt8, UInt8) {
            let notFound = (Data(), UInt8(0x6A), UInt8(0x82))
            switch (apdu.instructionClass, apdu.instructionCode) {
            case (0x00, 0xA4):
                // Only applications were backed up. A failed SELECT keeps the current one.
                let aid = (apdu.data ?? Data()).hexString.uppercased()
                guard apdu.p1Parameter == 0x04, applications[aid] != nil else { return notFound }
                selectedAID = aid
                return (Data(), 0x90, 0x00)
            case (0x00, 0xB0):
                guard apdu.p1Parameter == 0x95, let file = selected?.file15 else { return notFound }
                return (file, 0x90, 0x00)
            case (0x00, 0xB2):
                let sfi = Int(apdu.p2Parameter >> 3), index = Int(apdu.p1Parameter)
                guard apdu.p2Parameter & 0x07 == 0x04, let records = selected?.records[sfi],
                      index >= 1, index <= records.count else { return (Data(), 0x6A, 0x83) }
                return (records[index - 1], 0x90, 0x00)
            case (0x80, 0x5C):
                // P1 0 is the purse; T-Union reports overdraft debt at P1 1.
                guard apdu.p2Parameter == 0x02, apdu.expectedResponseLength == 4,
                      let cents = selected?.balanceCents else { return notFound }
                let isTUnion = selectedAID == TUnionDecoder.applicationAID
                let value: Int
                switch apdu.p1Parameter {
                case 0 where cents >= 0 || isTUnion: value = max(cents, 0)
                case 1 where isTUnion: value = max(-cents, 0)
                default: return notFound
                }
                return (withUnsafeBytes(of: UInt32(value).bigEndian) { Data($0) }, 0x90, 0x00)
            default:
                return (Data(), 0x6D, 0x00)
            }
        }
    }
}
