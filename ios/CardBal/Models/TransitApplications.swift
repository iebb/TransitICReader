import Foundation

/// A record's file and application remain available after histories are combined.
struct TransitApplicationRecord: Codable, Hashable {
    enum Kind: String, Codable { case transaction, transit, auxiliary }
    let kind: Kind
    let sfi: Int
    let index: Int
    let hex: String

    var identity: String { "\(kind.rawValue):\(sfi):\(hex.uppercased())" }
    var data: Data { Data(hexString: hex) }
    var hasContent: Bool { !data.isEmpty && data.contains { $0 != 0 } }
    var isPurchase: Bool { data.count == 23 && [UInt8(0x06), 0x09].contains(data[9]) }
}

struct TransitApplication: Codable, Hashable, Identifiable {
    struct DiagnosticSection: Codable, Hashable {
        let title: String
        let fields: [RawDataField]
    }
    let technology: String
    let cardFamily: String
    let identifier: String
    let selectedAID: String?
    let systemCode: String?
    var serialNumber: String?
    var cityCode: String?
    var region: String?
    var balanceText: String?
    var balanceDetail: String?
    var balanceReadAt: Date?
    var fields: [SavedCardField]
    let diagnostics: [DiagnosticSection]
    var records: [TransitApplicationRecord]
    let scannedAt: Date

    var id: String { "\(technology):\(selectedAID ?? systemCode ?? cardFamily)" }
    var isCityUnion: Bool { selectedAID == "A00000000386980701" }
    var isTUnion: Bool { selectedAID == "A000000632010105" }
    var isOctopus: Bool { technology == "FeliCa" && systemCode == "8008" }
    var label: String { isCityUnion ? "City Union" : isTUnion ? "T-Union" : cardFamily }
    var identityAlias: String { "\(technology)|\(serialNumber?.isEmpty == false ? serialNumber! : identifier)" }
    var identityAliases: Set<String> {
        var aliases: Set<String> = identityAlias.hasSuffix("|") ? [] : [identityAlias]
        if isOctopus, !identifier.isEmpty {
            aliases.insert("FeliCa|\(identifier.uppercased())")
        }
        if (isCityUnion || isTUnion), !identifier.isEmpty,
           identifier.contains(where: { $0 != "0" && $0 != "F" }) {
            // A stable UID can match a partial read that could not recover the
            // serial. Do not extend this fallback to other ISO card families.
            aliases.insert("ISO7816UID|\(identifier.uppercased())")
        }
        return aliases
    }

    init(snapshot: TransitCardSnapshot, cityCode: String? = nil, records: [TransitApplicationRecord]? = nil) {
        technology = snapshot.technology
        cardFamily = snapshot.cardFamily
        identifier = snapshot.rawIdentifierValue
        selectedAID = snapshot.selectedAID?.uppercased()
        systemCode = snapshot.systemCode?.uppercased()
        serialNumber = snapshot.realSerialNumber
        self.cityCode = cityCode
        region = snapshot.region
        balanceText = snapshot.balanceText
        balanceDetail = snapshot.balanceDetail
        balanceReadAt = snapshot.balanceText == nil ? nil : snapshot.scannedAt
        fields = snapshot.resultFields.map(SavedCardField.init)
        diagnostics = snapshot.rawSections.map { DiagnosticSection(title: $0.title, fields: $0.fields) }
        self.records = (records ?? Self.legacyRecords(
            transactions: snapshot.rawTransactions, transit: snapshot.rawTransitHistory,
            technology: snapshot.technology, isCityUnion: snapshot.cardFamily.contains("City Union")
        )).filter(\.hasContent)
        scannedAt = snapshot.scannedAt
    }

    static func legacyRecords(transactions: [String], transit: [String], technology: String, isCityUnion: Bool) -> [TransitApplicationRecord] {
        let purchases = transactions.enumerated().map {
            TransitApplicationRecord(kind: .transaction, sfi: technology == "ISO7816" ? 0x18 : 0,
                                     index: $0.offset + 1, hex: $0.element.uppercased())
        }
        // CU previously duplicated its purchase records in rawTransitHistory.
        let trips = transit.filter { !isCityUnion || !transactions.contains($0) }.enumerated().map {
            TransitApplicationRecord(kind: isCityUnion ? .transaction : .transit,
                                     sfi: technology == "ISO7816" ? (isCityUnion ? 0x18 : 0x1E) : 0,
                                     index: $0.offset + 1, hex: $0.element.uppercased())
        }
        return (purchases + trips).filter(\.hasContent)
    }

    static func merge(existing: [Self], incoming: [Self]) -> [Self] {
        var result = existing
        for app in incoming {
            guard let index = result.firstIndex(where: { $0.id == app.id }) else {
                result.append(app)
                continue
            }
            let old = result[index]
            var latest = app.scannedAt >= old.scannedAt ? app : old
            let other = app.scannedAt >= old.scannedAt ? old : app
            var seen = Set<String>()
            latest.records = (latest.records + other.records).filter { $0.hasContent && seen.insert($0.identity).inserted }
            latest.serialNumber = latest.serialNumber ?? other.serialNumber
            latest.cityCode = latest.cityCode ?? other.cityCode
            latest.region = latest.region ?? other.region
            let currentTitles = Set(latest.fields.map(\.title))
            latest.fields += other.fields.filter { !currentTitles.contains($0.title) }
            // An unavailable read is not a zero balance.
            if latest.balanceText == nil {
                latest.balanceText = other.balanceText
                latest.balanceDetail = other.balanceDetail
                latest.balanceReadAt = other.balanceReadAt ?? other.scannedAt
            }
            result[index] = latest
        }
        return result
    }

    static func primary(in apps: [Self]) -> Self? {
        apps.first(where: \.isOctopus) ?? apps.first(where: \.isTUnion) ?? apps.first
    }

    static func family(_ apps: [Self]) -> String {
        guard let primary = primary(in: apps) else { return "Unknown" }
        if apps.contains(where: \.isOctopus), let mainland = apps.first(where: { $0.isTUnion }) ?? apps.first(where: { $0.isCityUnion }) {
            return "Octopus + \(mainland.cardFamily)"
        }
        return primary.cardFamily
    }

    static func displayBalance(_ apps: [Self]) -> String? {
        if let octopus = apps.first(where: \.isOctopus) {
            // Modern Octopus T-Union cards share one HKD purse. Older dual-purse
            // products expose application readings in their separate details.
            return octopus.balanceText
        }
        return apps.filter { $0.balanceText != nil }.sorted {
            let lhsDate = $0.balanceReadAt ?? $0.scannedAt
            let rhsDate = $1.balanceReadAt ?? $1.scannedAt
            return lhsDate == rhsDate ? ($0.isTUnion && !$1.isTUnion) : lhsDate > rhsDate
        }.first?.balanceText
    }
}

extension TransitCardSnapshot {
    var applicationSnapshots: [TransitApplication] {
        applications ?? [TransitApplication(snapshot: self)]
    }

    var identityAliases: Set<String> { Set(applicationSnapshots.flatMap(\.identityAliases)) }

    static func combining(_ snapshots: [TransitCardSnapshot]) -> TransitCardSnapshot? {
        let apps = snapshots.reduce([TransitApplication]()) {
            TransitApplication.merge(existing: $0, incoming: $1.applicationSnapshots)
        }
        guard let primary = TransitApplication.primary(in: apps),
              let base = snapshots.first(where: { $0.applicationSnapshots.contains(where: { $0.id == primary.id }) }) else { return nil }
        let isCrossProtocol = Set(apps.map(\.technology)).count > 1
        var result = TransitCardSnapshot(
            technology: isCrossProtocol ? "Dual Mode" : base.technology,
            cardFamily: TransitApplication.family(apps),
            identifierLabel: base.identifierLabel, identifierValue: base.identifierValue,
            rawIdentifierValue: base.rawIdentifierValue, pmm: base.pmm, systemCode: base.systemCode,
            selectedAID: primary.selectedAID, balanceText: TransitApplication.displayBalance(apps),
            balanceDetail: apps.compactMap { app in app.balanceText.map { "\(app.label): \($0)" } }.joined(separator: "\n"),
            realSerialNumber: primary.serialNumber, region: primary.region,
            resultFields: base.resultFields + apps.filter { $0.id != primary.id }.flatMap { app in
                app.fields.map { ResultField(title: "\(app.label) · \($0.title)", value: $0.value) }
            },
            rawSections: apps.flatMap { app in app.diagnostics.map {
                RawDataSection(title: "\(app.label) · \($0.title)", fields: $0.fields)
            } },
            rawTransactions: apps.flatMap { $0.records.filter { $0.kind == .transaction }.map(\.hex) },
            rawTransitHistory: apps.flatMap { $0.records.filter { $0.kind == .transit }.map(\.hex) },
            scannedAt: snapshots.map(\.scannedAt).max() ?? base.scannedAt
        )
        result.applications = apps
        return result
    }
}

extension SavedCardRecord {
    var applicationSnapshots: [TransitApplication] {
        if let applications { return applications }
        // Migrate the old flattened Octopus + ISO result using its recorded
        // protocol and AID. An ambiguous combined balance is left unavailable.
        if technology == "Dual Mode", systemCode == "8008",
           let aid = selectedAID?.uppercased(),
           [CityUnionDecoder.applicationAID, TUnionDecoder.applicationAID].contains(aid) {
            func legacy(_ felica: Bool) -> TransitApplication {
                let records = rawTransactions.filter { Data(hexString: $0).count == (felica ? 16 : 23) }
                let snapshot = TransitCardSnapshot(
                    technology: felica ? "FeliCa" : "ISO7816",
                    cardFamily: felica ? "Octopus" : aid == CityUnionDecoder.applicationAID ? "City Union" : "China T-Union",
                    identifierLabel: felica ? "IDm" : "UID", identifierValue: felica ? rawIdentifierValue : "",
                    rawIdentifierValue: felica ? rawIdentifierValue : "", pmm: felica ? pmm : nil,
                    systemCode: felica ? "8008" : nil, selectedAID: felica ? nil : aid,
                    balanceText: nil, balanceDetail: nil, realSerialNumber: felica ? nil : realSerialNumber,
                    region: nil, resultFields: [], rawSections: [], rawTransactions: records,
                    rawTransitHistory: felica ? [] : rawTransitHistory.filter { Data(hexString: $0).count >= 23 },
                    scannedAt: scannedAt)
                return TransitApplication(snapshot: snapshot)
            }
            return [legacy(true), legacy(false)]
        }
        guard technology == "ISO7816" && ICCardBrand.from(family: cardFamily) == .tUnion
                || technology == "FeliCa" && ICCardBrand.from(family: cardFamily) == .octopus else { return [] }
        let snapshot = TransitCardSnapshot(technology: technology, cardFamily: cardFamily,
            identifierLabel: identifierLabel, identifierValue: identifierValue,
            rawIdentifierValue: rawIdentifierValue, pmm: pmm, systemCode: systemCode,
            selectedAID: selectedAID, balanceText: balanceText, balanceDetail: balanceDetail,
            realSerialNumber: realSerialNumber, region: region,
            resultFields: resultFields.map { ResultField(title: $0.title, value: $0.value) }, rawSections: [],
            rawTransactions: rawTransactions, rawTransitHistory: rawTransitHistory, scannedAt: scannedAt)
        return [TransitApplication(snapshot: snapshot)]
    }

    var identityAliases: Set<String> {
        Set(applicationSnapshots.flatMap(\.identityAliases)).union([id]).union(mergedIdentifiers ?? [])
    }

    var cardsByApplication: [SavedCardRecord] {
        guard let applications, applications.count > 1 else { return [self] }
        return applications.map { application in
            var card = self
            card.applyApplications([application])
            return card
        }
    }

    mutating func applyApplications(_ apps: [TransitApplication]) {
        guard let primary = TransitApplication.primary(in: apps) else { return }
        applications = apps
        cardFamily = TransitApplication.family(apps)
        technology = Set(apps.map(\.technology)).count > 1 ? "Dual Mode" : primary.technology
        selectedAID = primary.selectedAID
        systemCode = primary.systemCode
        realSerialNumber = primary.serialNumber
        if !primary.identifier.isEmpty {
            rawIdentifierValue = primary.identifier
            identifierValue = primary.identifier
            identifierLabel = primary.technology == "FeliCa" ? "IDm" : "UID"
        }
        region = primary.region
        issuingCity = primary.fields.first(where: { $0.title == "Issuing City" })?.value
        cardTypeStr = primary.fields.first(where: { $0.title == "Card Type" })?.value
        issueDateStr = primary.fields.first(where: { $0.title == "Issue Date" })?.value
        expiryDateStr = primary.fields.first(where: { $0.title == "Expiry Date" })?.value
        balanceText = TransitApplication.displayBalance(apps)
        balanceDetail = apps.compactMap { app in app.balanceText.map { "\(app.label): \($0)" } }.joined(separator: "\n")
        resultFields = primary.fields + apps.filter { $0.id != primary.id }.flatMap { app in
            app.fields.map { SavedCardField(ResultField(title: "\(app.label) · \($0.title)", value: $0.value)) }
        }
        rawTransactions = apps.flatMap { $0.records.filter { $0.kind == .transaction }.map(\.hex) }
        rawTransitHistory = apps.flatMap { app in app.records.filter {
            $0.kind == .transit || (app.isCityUnion && $0.isPurchase)
        }.map(\.hex) }
    }
}

enum TransitApplicationHistory {
    private struct Item {
        let app: TransitApplication
        let record: TransitApplicationRecord
        var transaction: TransitTransaction
    }

    static func decode(_ apps: [TransitApplication], kind: RawHistoryKind) -> [TransitTransaction] {
        var purchases: [Item] = []
        var trips: [Item] = []
        for app in apps {
            let originalLedger = app.records.filter { $0.kind == .transaction }
            let ledger: [TransitApplicationRecord]
            if ICCardBrand.from(family: app.cardFamily) == .snapperPlus {
                let records = Dictionary(originalLedger.map { ($0.hex, $0) }, uniquingKeysWith: { first, _ in first })
                ledger = SnapperPlusProtocol.mergeHistory(originalLedger.map(\.hex)).compactMap { records[$0] }
            } else {
                ledger = originalLedger
            }
            let travel = app.records.filter { $0.kind == .transit }
            for record in ledger + travel {
                let context = record.kind == .transit ? travel : ledger
                let index = context.firstIndex(of: record) ?? 0
                let decoded: TransitTransaction?
                if app.isCityUnion && record.data.count == 23 {
                    decoded = CityUnionDecoder.decodeTransitRecord(data: record.data, index: index,
                                                                    auxiliary: app.records.filter { $0.kind == .auxiliary })
                } else {
                    decoded = TransactionDecoderRegistry.decode(raw: record.hex, family: app.cardFamily,
                        technology: app.technology, context: context.map(\.hex), at: index,
                        kind: record.kind == .transit ? .transit : .transactions, relatedContext: ledger.map(\.hex))
                }
                guard var tx = decoded else { continue }
                tx.sourceApplicationID = app.id
                tx.sourceCardFamily = app.cardFamily
                tx.currencyCode = ICCardBrand.from(family: app.cardFamily).region.currencyCode
                tx.sourceRecordIDs = ["\(app.id)|\(record.identity)"]
                let item = Item(app: app, record: record, transaction: tx)
                if record.kind == .transaction { purchases.append(item) } else { trips.append(item) }
            }
        }
        // Match full transaction evidence, never a ring-buffer position. Preserve
        // multiplicity if one source contains two otherwise identical purchases.
        let groups = Dictionary(grouping: purchases) { item -> String in
            guard (item.app.isCityUnion || item.app.isTUnion), item.record.data.count == 23,
                  item.transaction.date != nil else { return "unique:\(item.app.id):\(item.record.identity)" }
            return "pboc:\(item.record.data.subdata(in: 5..<23).hexString)"
        }
        purchases = groups.values.flatMap { group -> [Item] in
            let sources = group.map { "\($0.app.id):\($0.record.sfi)" }
            guard group.count > 1, Set(sources).count == group.count else { return group }
            var best = group.sorted {
                let lhsQuality = quality($0.transaction), rhsQuality = quality($1.transaction)
                return lhsQuality == rhsQuality ? $0.app.id < $1.app.id : lhsQuality > rhsQuality
            }[0]
            best.transaction.sourceRecordIDs = group.flatMap { $0.transaction.sourceRecordIDs ?? [] }.sorted()
            return [best]
        }

        // Evaluate both sides' candidates before enrichment changes provenance.
        // A payment and a gate record must form a unique one-to-one pair.
        let matchesByTrip = trips.map { trip in
            purchases.indices.filter { matchesTravel(purchases[$0], trip) }
        }
        var matchedPurchases = Set<Int>()
        for tripIndex in trips.indices {
            let trip = trips[tripIndex]
            let matches = matchesByTrip[tripIndex]
            guard matches.count == 1, let purchaseIndex = matches.first,
                  matchesByTrip.filter({ $0.contains(purchaseIndex) }).count == 1 else { continue }
            let merged = enriched(purchases[purchaseIndex].transaction, with: trip.transaction)
            purchases[purchaseIndex].transaction = merged
            trips[tripIndex].transaction.sourceRecordIDs = merged.sourceRecordIDs
            matchedPurchases.insert(purchaseIndex)
        }
        if kind == .transactions { return sortTransactionsByRecency(purchases.map(\.transaction)) }
        let fallback = purchases.enumerated().compactMap { index, item -> TransitTransaction? in
            guard !matchedPurchases.contains(index), item.record.isPurchase,
                  item.app.isCityUnion || item.app.isTUnion else { return nil }
            return item.transaction
        }
        return sortTransactionsByRecency(trips.map(\.transaction) + fallback)
    }

    private static func quality(_ tx: TransitTransaction) -> Int {
        (tx.entryStation == nil && tx.exitStation == nil ? 0 : 4) +
        (tx.location?.contains("Terminal ") == false ? 2 : 0)
    }

    private static func matchesTravel(_ purchase: Item, _ trip: Item) -> Bool {
        guard trip.app.isTUnion, purchase.record.isPurchase,
              purchase.app.isCityUnion || purchase.app.isTUnion,
              let date = purchase.transaction.date, date == trip.transaction.date,
              purchase.transaction.amount == trip.transaction.amount,
              purchase.transaction.currencyCode == trip.transaction.currencyCode else { return false }
        // SFI 18 payment terminals and SFI 1E gates can use different namespaces
        // (for example Chongqing's 413180... payments and 0912... metro gates).
        // Equal time and fare can correlate records from the same application.
        // Include all mirrored sources, even if CU won the representative row.
        if purchase.transaction.sourceRecordIDs?.contains(where: { $0.hasPrefix("\(trip.app.id)|") }) == true {
            return true
        }
        // Without shared application evidence, retain the stricter terminal rule.
        guard let terminal = purchase.transaction.terminalID, terminal.count == 12,
              terminal.contains(where: { $0 != "0" }),
              let travelTerminal = trip.transaction.terminalID else { return false }
        return travelTerminal == "0000" + terminal
    }

    private static func enriched(_ purchase: TransitTransaction, with trip: TransitTransaction) -> TransitTransaction {
        var result = TransitTransaction(date: purchase.date, time: purchase.time, amount: purchase.amount,
            terminalID: purchase.terminalID, type: trip.type, category: trip.category,
            balanceAfter: trip.balanceAfter, location: trip.location ?? purchase.location,
            entryStation: trip.entryStation, exitStation: trip.exitStation,
            entryStationCode: trip.entryStationCode, exitStationCode: trip.exitStationCode,
            rawData: purchase.rawData, recordNumber: purchase.recordNumber)
        result.sourceApplicationID = purchase.sourceApplicationID
        result.sourceCardFamily = purchase.sourceCardFamily
        result.currencyCode = purchase.currencyCode
        result.sourceRecordIDs = Array(Set((purchase.sourceRecordIDs ?? []) + (trip.sourceRecordIDs ?? []))).sorted()
        return result
    }
}
