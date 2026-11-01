import Foundation

struct ChineseLocalDecoder: TransitCardDecoder {
    static func canDecode(tag: CardTag) async -> Bool {
        guard case .iso7816 = tag else { return false }
        return true
    }
    static func decode(tag: CardTag, scannedAt: Date) async throws -> TransitCardSnapshot {
        guard case .iso7816(let iso) = tag else { throw NFCTestError.unsupportedCard }
        ScanProgress.report(.balance)
        guard let result = await ChineseLocalProtocol.read(exchange: { command in
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
