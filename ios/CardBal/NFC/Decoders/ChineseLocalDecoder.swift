import Foundation

struct ChineseLocalDecoder: TransitCardDecoder {
    static func canDecode(tag: CardTag) async -> Bool {
        guard case .iso7816 = tag else { return false }
        return true
    }
    static func decode(tag: CardTag, scannedAt: Date) async throws -> TransitCardSnapshot {
        guard case .iso7816(let iso) = tag else { throw NFCTestError.unsupportedCard }
        ScanProgress.report(.balance)
        // Beijing's OC/PBOC names are not in Info.plist; Core NFC cannot select them.
        let kinds: [ChineseLocalProtocol.Kind] = iso.selectsUnlistedApplications ? ChineseLocalProtocol.Kind.allCases : [.shenzhen, .wuhan]
        guard let result = await ChineseLocalProtocol.read(kinds: kinds, exchange: { command in
            guard let apdu = CardAPDU(data: command) else { throw NFCTestError.unsupportedCard }
            return try await iso.sendCommand(apdu: apdu)
        }), !iso.identifier.isEmpty || result.serial != nil else { throw NFCTestError.unsupportedCard }
        var fields = [ResultField(title: "Brand", value: result.kind.family),
                      ResultField(title: "Issuing City", value: result.kind.city), ResultField(title: "Currency", value: "CNY")]
        if let serial = result.serial { fields.append(ResultField(title: "Card Number", value: serial)) }
        if let date = result.issueDate { fields.append(ResultField(title: "Issue Date", value: date)) }
        if let date = result.expiryDate { fields.append(ResultField(title: "Expiry Date", value: date)) }
        let records = result.records.map { TransitApplicationRecord(kind: .transaction, sfi: 0x18, index: $0.number, hex: $0.data.hexString) }
        var snapshot = TransitCardSnapshot(
            technology: "ISO7816", cardFamily: result.kind.family, identifierLabel: "UID", identifierValue: iso.identifier.hexString,
            rawIdentifierValue: iso.identifier.hexString, pmm: nil, systemCode: nil, selectedAID: result.aid,
            balanceText: formatCurrency(amount: Decimal(result.balanceMinor) / 100, code: "CNY", fractionDigits: 2),
            balanceDetail: nil, realSerialNumber: result.serial, region: result.kind.city, resultFields: fields,
            rawSections: [RawDataSection(title: "Application", fields: [
                RawDataField(title: "AID", value: result.aid), RawDataField(title: "SELECT", value: result.selection.hexString),
                RawDataField(title: "Balance", value: result.balance.hexString)
            ])] + result.files.map { RawDataSection(title: String(format: "SFI %02X", $0.sfi), fields: [RawDataField(title: "Payload", value: $0.data.hexString)]) },
            rawTransactions: records.map(\.hex), rawTransitHistory: [], scannedAt: scannedAt
        )
        snapshot.applications = [TransitApplication(snapshot: snapshot, records: records)]
        return snapshot
    }
    /// Adds the local application of a card that also has City Union / T-Union. Runs only after
    /// that read succeeded, so these SELECTs cannot disturb it; the City Union / T-Union side stays primary.
    static func addingLocalApplication(to snapshot: TransitCardSnapshot, tag: CardTag) async -> TransitCardSnapshot {
        guard case .iso7816 = tag, snapshot.applicationSnapshots.contains(where: { $0.isCityUnion || $0.isTUnion }),
              let local = try? await decode(tag: tag, scannedAt: snapshot.scannedAt),
              let combined = TransitCardSnapshot.combining([snapshot, local]) else { return snapshot }
        // The snapshot's fields already list its own applications; add only the local one's.
        let added = local.applicationSnapshots.filter { app in !snapshot.applicationSnapshots.contains { $0.id == app.id } }
        var result = TransitCardSnapshot(
            technology: combined.technology, cardFamily: combined.cardFamily, identifierLabel: combined.identifierLabel,
            identifierValue: combined.identifierValue, rawIdentifierValue: combined.rawIdentifierValue, pmm: combined.pmm,
            systemCode: combined.systemCode, selectedAID: combined.selectedAID, balanceText: combined.balanceText,
            balanceDetail: combined.balanceDetail, realSerialNumber: combined.realSerialNumber, region: combined.region,
            resultFields: snapshot.resultFields + added.flatMap { app in
                app.fields.map { ResultField(title: "\(app.label) · \($0.title)", value: $0.value) }
            },
            rawSections: combined.rawSections, rawTransactions: combined.rawTransactions,
            rawTransitHistory: combined.rawTransitHistory, scannedAt: combined.scannedAt)
        result.applications = combined.applications
        result.exchangeRate = combined.exchangeRate
        return result
    }
    static func decodeRecord(data: Data) -> TransitTransaction? {
        guard let history = ChineseLocalProtocol.history(data) else { return nil }
        let formatter = DateFormatter(); formatter.timeZone = TimeZone(identifier: "Asia/Shanghai"); formatter.dateFormat = "HH:mm:ss"
        var transaction = TransitTransaction(date: history.date, time: formatter.string(from: history.date),
            amount: Decimal(history.amountMinor ?? 0) / 100, terminalID: history.terminal,
            type: history.type == 2 ? "Top-up" : history.amountMinor != nil ? "Payment" : String(format: "Transaction 0x%02X", history.type),
            category: history.type == 2 ? .topUp : history.amountMinor != nil ? .payment : .unknown,
            rawData: data.hexString, recordNumber: history.counter)
        transaction.currencyCode = "CNY"; transaction.issuerTimeZone = "Asia/Shanghai"
        transaction.amountKnown = history.amountMinor != nil; transaction.amountIsSigned = true
        return transaction
    }
}
