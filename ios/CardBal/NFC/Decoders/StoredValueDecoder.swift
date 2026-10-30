import Foundation
import CoreNFC

/// Public-file DESFire reader. No ISO SELECT AID, authentication or card writes.
struct StoredValueDecoder: TransitCardDecoder {
    static func canDecode(tag: NFCTag) async -> Bool {
        switch tag {
        case .miFare(let card): return card.mifareFamily == .desfire
        case .iso7816: return true
        default: return false
        }
    }

    static func decode(tag: NFCTag, scannedAt: Date) async throws -> TransitCardSnapshot {
        let uid: Data
        let exchange: (Data) async throws -> Data
        switch tag {
        case .miFare(let card) where card.mifareFamily == .desfire:
            uid = card.identifier
            // DESFire 90-INS APDUs go through the raw MiFare transport; these
            // select native three-byte applications, not ISO7816 A4 names.
            exchange = { try await card.sendMiFareCommand(commandPacket: $0) }
        case .iso7816(let card):
            uid = card.identifier
            exchange = { request in
                guard let apdu = NFCISO7816APDU(data: request) else { throw DesfireReadError.malformedResponse }
                let reply = try await card.sendCommand(apdu: apdu)
                return reply.0 + Data([reply.1, reply.2])
            }
        default: throw NFCTestError.unsupportedCard
        }
        guard let card = try await StoredValueProtocol.readFirst(mode: .wrapped, exchange: exchange) else {
            throw NFCTestError.unsupportedCard
        }
        let identifier = uid.map { String(format: "%02X", $0) }.joined()
        var fields = [ResultField(title: "Detected Type", value: card.family)]
        if let serial = card.serial { fields.append(ResultField(title: "Card Number", value: serial)) }
        for (index, pass) in card.passes.enumerated() {
            fields.append(ResultField(title: "\(pass.label) \(index + 1)", value: "Product \(pass.productCode), zone \(pass.zoneCode)"))
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "Europe/Helsinki")
            formatter.dateFormat = pass.label == "Season pass" ? "yyyy-MM-dd" : "yyyy-MM-dd HH:mm"
            if let start = pass.validFromEpochSeconds {
                fields.append(ResultField(title: "Pass \(index + 1) Valid From", value: formatter.string(from: Date(timeIntervalSince1970: start))))
            }
            if let end = pass.validToEpochSeconds {
                fields.append(ResultField(title: "Pass \(index + 1) Valid To", value: formatter.string(from: Date(timeIntervalSince1970: end))))
            }
        }
        return TransitCardSnapshot(
            technology: "DESFire", cardFamily: card.family, identifierLabel: "UID",
            identifierValue: identifier, rawIdentifierValue: identifier,
            pmm: nil, systemCode: nil, selectedAID: nil,
            balanceText: card.balanceMinor.map { formatCurrency(amount: Decimal($0) / 100, code: card.currencyCode, fractionDigits: 2) },
            balanceDetail: card.metadata["scope"], realSerialNumber: card.serial, region: nil,
            resultFields: fields,
            rawSections: [RawDataSection(title: "DESFire", fields: card.metadata.sorted { $0.key < $1.key }.map { RawDataField(title: $0.key, value: $0.value) })],
            rawTransactions: card.rawTransactions, rawTransitHistory: [], scannedAt: scannedAt
        )
    }
}
