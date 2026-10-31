import Foundation

/// CEPAS selects file 4000 in the card's default application before reading.
/// iPhones can expose the card through ISO7816 or raw MIFARE discovery;
/// both paths and external readers use the shared purse protocol.
struct CEPASDecoder: TransitCardDecoder {
    static func canDecode(tag: CardTag) async -> Bool {
        switch tag {
        case .iso7816: return true
        case .miFare(let mifare): return mifare.mifareFamily != .ultralight
        default: return false
        }
    }

    static func decode(tag: CardTag, scannedAt: Date) async throws -> TransitCardSnapshot {
        let identifier: Data
        let exchange: (Data) async throws -> Data
        switch tag {
        case .iso7816(let iso):
            identifier = iso.identifier
            exchange = { command in
                guard let apdu = CardAPDU(data: command) else { throw NFCTestError.unsupportedCard }
                let response = try await iso.sendCommand(apdu: apdu)
                return response.0 + Data([response.1, response.2])
            }
        case .miFare(let mifare) where mifare.mifareFamily != .ultralight:
            identifier = mifare.identifier
            // Core NFC's raw MIFARE path retains APDU status bytes. Do not use
            // an AID SELECT to work around discovery restrictions.
            exchange = { try await mifare.sendMiFareCommand(commandPacket: $0) }
        default: throw NFCTestError.unsupportedCard
        }
        guard let card = await CEPASProtocol.read(exchange: exchange) else { throw NFCTestError.unsupportedCard }
        let rawPurse = card.purse.raw.map { String(format: "%02X", $0) }.joined()
        let history = card.rawHistory.map { $0.map { String(format: "%02X", $0) }.joined() }
        let uid = identifier.map { String(format: "%02X", $0) }.joined()
        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.timeZone = TimeZone(identifier: CEPASProtocol.issuerTimeZone)
        dateFormatter.dateFormat = "yyyy-MM-dd"
        return TransitCardSnapshot(
            technology: "ISO7816", cardFamily: card.family == "EZ-Link" ? "EZLink" : card.family, identifierLabel: "CAN",
            identifierValue: card.serial, rawIdentifierValue: uid, pmm: nil, systemCode: nil,
            selectedAID: nil,
            balanceText: formatCurrency(amount: Decimal(card.balanceMinor) / 100, code: "SGD", fractionDigits: 2),
            balanceDetail: "On-card stored-value purse only. SimplyGo account balances are not read.",
            realSerialNumber: card.serial, region: card.family == "EZ-Link" ? "EZLink" : card.family,
            resultFields: [
                ResultField(title: "Brand", value: card.family), ResultField(title: "Card Number (CAN)", value: card.serial),
                ResultField(title: "Currency", value: "SGD"),
                ResultField(title: "CEPAS Version", value: "\(card.purse.version)"),
                ResultField(title: "Issue Date", value: dateFormatter.string(from: card.purse.creationDate)),
                ResultField(title: "Expiry Date", value: dateFormatter.string(from: card.purse.expiryDate)),
                ResultField(title: "Purse Status", value: String(format: "0x%02X", card.purse.status)),
                ResultField(title: "History", value: card.historyComplete ? "On-card records read" : "Some on-card records were unavailable")
            ],
            rawSections: [RawDataSection(title: "CEPAS Purse 3", fields: [RawDataField(title: "Read Purse", value: rawPurse)])],
            rawTransactions: history, rawTransitHistory: [], scannedAt: scannedAt
        )
    }
}
